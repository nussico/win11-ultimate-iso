# Build pipeline. Runs in a background runspace; talks to the GUI via $Sync (synchronized hashtable):
#   Log (ConcurrentQueue[string]), Step (int), Cancel (bool), Done (bool), Error (string)

$script:BuildSync = $null
$script:LogFile = $null
$script:MountedIsos = @()
$script:Report = $null   # Start, Steps (@{Name; Start}), Images, Apps, Reg, Warnings - for the summary

function Write-Log($Msg) {
    $line = '[{0:HH:mm:ss}] {1}' -f (Get-Date), $Msg
    if ($script:Report -and $Msg -match '^\s*(WARN|NOTE)') { $script:Report.Warnings += $Msg.Trim() }
    if ($script:BuildSync) { $script:BuildSync.Log.Enqueue($line) } else { Write-Host $line }
    if ($script:LogFile) { Add-Content $script:LogFile $line }
}

function Enter-Step($N, $Name) {
    if ($script:BuildSync.Cancel) { throw 'Cancelled by user' }
    $script:BuildSync.Step = $N
    $script:Report.Steps += @{ Name = "$N $Name"; Start = Get-Date }
    Write-Log "== Step $N/9: $Name"
}

function Format-Duration([timespan]$T) { '{0}m {1:00}s' -f [int][math]::Floor($T.TotalMinutes), $T.Seconds }

function Write-BuildHeader($Cfg) {
    $u = $Cfg.Unattend
    Write-Log "Win11 Ultimate Builder $($Cfg.ToolVersion) - build started $(Get-Date -Format 'yyyy-MM-dd HH:mm')"
    Write-Log "Host:           $((Get-CimInstance Win32_OperatingSystem).Caption) $([Environment]::OSVersion.Version), PowerShell $($PSVersionTable.PSVersion)"
    Write-Log "Editions:       $($Cfg.Editions -join ', ')"
    Write-Log "Base language:  $($Cfg.BaseLang)"
    Write-Log "Patches:        $(if ($Cfg.Patches) { ($Cfg.Patches | ForEach-Object { $Patches[$_].Label }) -join '; ' } else { 'none' })"
    Write-Log "Source:         ISO folder $($Cfg.IsoFolder); UUP dump $(if ($Cfg.UseUup) { 'on' } else { 'off' }); always newest $(if ($Cfg.Newest) { 'on' } else { 'off' }); fast mode $(if ($Cfg.Fast) { 'on' } else { 'off' })"
    Write-Log "Unattended:     $(if ($u.Enabled) { "user '$($u.UserName)', auto-install $($u.AutoInstall), edition '$($u.Edition)', $(if ($u.ProductKey) { 'own product key' } else { 'generic key' }), skip OOBE $($u.SkipOobe)" } else { 'off' })"
    Write-Log "Output:         $($Cfg.Output)$(if ($Cfg.Split) { ' (install.wim split for FAT32)' })"
    Write-Log "Speed:          Defender exclusion $(if ($Cfg.DefenderExclude) { 'on' } else { 'off' }); compression $(if ($Cfg.QuickCompress) { 'quick' } else { 'max' })"
}

function Write-BuildSummary($Cfg) {
    $r = $script:Report; $end = Get-Date
    Write-Log '== Summary'
    $result = if ($script:BuildSync.Error) { "FAILED in step $($script:BuildSync.Step): $($script:BuildSync.Error)" }
    else { "OK - $($Cfg.Output) ($([math]::Round((Get-Item $Cfg.Output).Length/1GB,2)) GB)" }
    Write-Log "Result:   $result"
    Write-Log "Total:    $(Format-Duration ($end - $r.Start))"
    for ($i = 0; $i -lt $r.Steps.Count; $i++) {
        $next = if ($i + 1 -lt $r.Steps.Count) { $r.Steps[$i + 1].Start } else { $end }
        Write-Log ('  {0,-30} {1}' -f $r.Steps[$i].Name, (Format-Duration ($next - $r.Steps[$i].Start)))
    }
    foreach ($img in $r.Images) { Write-Log "Image:    $img" }
    Write-Log "Changes:  $($r.Apps) apps removed, $($r.Reg) registry values changed (all editions)"
    $warnings = @($r.Warnings)
    Write-Log "Warnings: $($warnings.Count)"
    foreach ($w in $warnings) { Write-Log "  $w" }
}

function Get-Oscdimg {
    $p = "${env:ProgramFiles(x86)}\Windows Kits\10\Assessment and Deployment Kit\Deployment Tools\amd64\Oscdimg\oscdimg.exe"
    if (Test-Path $p) { return $p }
    $ErrorActionPreference = 'Continue'
    Write-Log 'oscdimg not found, installing ADK Deployment Tools via winget...'
    winget install -e --id Microsoft.WindowsADK --accept-package-agreements --accept-source-agreements --override '/quiet /norestart /features OptionId.DeploymentTools' | Out-Null
    if (Test-Path $p) { return $p }
    throw 'oscdimg missing. Install the Windows ADK "Deployment Tools" feature and retry.'
}

# Volume label W11U_<version> (letters/digits only; a short commit keeps it far below the 32-char limit).
function Get-IsoLabel($Version) {
    $v = "$Version" -replace '[^A-Za-z0-9]', ''
    "W11U_$(if ($v) { $v } else { 'dev' })".ToUpper()
}

# Name of the cached finished install.wim. Same source ISOs, editions, patches, compression and patch code
# = same image, so a rebuild that only changes Unattended/apps/output reuses it and skips steps 3, 4 and 7.
function Get-ImageCachePath($Cfg, $Sources) {
    # ponytail: no cache with 'drivers' (folder contents are not in the key); add a file list to the key if that matters.
    if ('drivers' -notin $Cfg.Patches) { Join-Path $Cfg.CacheDir (Get-ImageCacheKey $Cfg $Sources) }
}
# Free space a build needs (work folder, mounted image, ISO, cache). Measured peak is lower; this keeps headroom.
function Get-NeededGB([bool]$Cached) { if ($Cached) { 15 } else { 60 } }
function Assert-FreeSpace($Path, [bool]$Cached) {
    $need = Get-NeededGB $Cached; $free = (Get-PSDrive $Path.Substring(0, 1)).Free
    if ($free -lt $need * 1GB) { throw "Need $need GB free on $($Path.Substring(0,2)), have $([math]::Round($free/1GB)) GB" }
}
function Get-ImageCacheKey($Cfg, $Sources) {
    $parts = @($Sources | ForEach-Object { $f = Get-Item $_.Iso; "$($f.FullName)|$($f.Length)|$($f.LastWriteTimeUtc.Ticks)|$($_.Name)" }) +
        ($Cfg.Patches -join ',') + "$($Cfg.QuickCompress)" + (Get-Content "$PSScriptRoot\Patches.ps1", "$PSScriptRoot\Build.ps1" -Raw)
    $hash = [Security.Cryptography.SHA256]::Create().ComputeHash([Text.Encoding]::UTF8.GetBytes($parts -join "`n"))
    'install-' + (-join ($hash[0..7] | ForEach-Object { $_.ToString('x2') })) + '.wim'
}

# Text file in the ISO root: which builder version made it and with what. No password or product key.
function Get-IsoInfoText($Cfg) {
    @(
        "Built with Win11 Ultimate ISO Builder $($Cfg.ToolVersion) on $(Get-Date -Format 'yyyy-MM-dd HH:mm')"
        'https://github.com/nussico/win11-ultimate-iso'
        ''
        "Editions:   $($Cfg.Editions -join ', ')"
        "Language:   $($Cfg.BaseLang)"
        "Patches:    $(if ($Cfg.Patches) { $Cfg.Patches -join ', ' } else { 'none' })"
        "Unattended: $(if ($Cfg.Unattend.Enabled) { "yes, automatic install $($Cfg.Unattend.AutoInstall)" } else { 'no' })"
        "Apps:       $(if ($Cfg.Unattend.Enabled -and $Cfg.Unattend.Apps) { $Cfg.Unattend.Apps -join ', ' } else { 'none' })"
    ) -join "`r`n"
}

function Mount-SourceIso($Path) { $script:MountedIsos += $Path; Mount-Iso $Path }

function Clear-BuildState {
    $ErrorActionPreference = 'Continue'
    Dismount-Hives
    Get-WindowsImage -Mounted -ErrorAction SilentlyContinue | ForEach-Object {
        Write-Log "Discarding mounted image $($_.Path)"
        Dismount-WindowsImage -Path $_.Path -Discard -ErrorAction SilentlyContinue | Out-Null
    }
    foreach ($iso in $script:MountedIsos) { Dismount-DiskImage -ImagePath $iso -ErrorAction SilentlyContinue | Out-Null }
    $script:MountedIsos = @()
}

# Optional speed-up: Defender scans every file DISM writes. Excludes only the work folder, only for this build.
function Add-DefenderExclusion($Path) {
    try {
        # Already there = left over from a killed build (the work folder is ours alone): reuse it, still remove it at the end.
        if ($Path -notin @((Get-MpPreference).ExclusionPath)) { Add-MpPreference -ExclusionPath $Path -ErrorAction Stop }
        $script:DefenderExcluded = $Path
        Write-Log "Defender exclusion added for $Path (removed when the build ends)"
    } catch { Write-Log "NOTE: could not add Defender exclusion ($_) - building without it" }
}

function Remove-DefenderExclusion {
    if (-not $script:DefenderExcluded) { return }
    try { Remove-MpPreference -ExclusionPath $script:DefenderExcluded -ErrorAction Stop; Write-Log 'Defender exclusion removed' }
    catch { Write-Log "WARN: could not remove the Defender exclusion for $($script:DefenderExcluded): $_" }
    $script:DefenderExcluded = $null
}

function Invoke-Build($Cfg, $Sync) {
    $script:BuildSync = $Sync
    $ErrorActionPreference = 'Stop'
    $ProgressPreference = 'SilentlyContinue'
    $w = $Cfg.WorkDir
    New-Item -ItemType Directory -Force (Split-Path $Cfg.Output) | Out-Null
    $script:LogFile = Join-Path (Split-Path $Cfg.Output) 'build-log.txt'
    Set-Content $script:LogFile ''
    $script:Report = @{ Start = Get-Date; Steps = @(); Images = @(); Apps = 0; Reg = 0; Warnings = @() }
    try {
        Write-BuildHeader $Cfg
        Enter-Step 1 'Preflight'
        $isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole('Administrators')
        if (-not $isAdmin) { throw 'Must run as administrator' }
        Assert-FreeSpace $w $true   # full check once step 2 knows whether the cached image is reused
        Write-Log "Free space on $($w.Substring(0,2)): $([math]::Round((Get-PSDrive $w.Substring(0, 1)).Free/1GB)) GB"
        Clear-BuildState
        Clear-WindowsCorruptMountPoint | Out-Null
        if (Test-Path $w) {
            Write-Log "Removing old work folder $w"
            # Leftovers of an interrupted build are owned by TrustedInstaller; Remove-ImagePath takes ownership first.
            try { Remove-Item $w -Recurse -Force -ErrorAction Stop } catch { Remove-ImagePath $w }
            if (Test-Path $w) { throw "Could not delete the old work folder $w. Restart the PC and try again." }
        }
        foreach ($d in 'iso', 'mount', 'uup') { New-Item -ItemType Directory -Force "$w\$d" | Out-Null }
        if ($Cfg.DefenderExclude) { Add-DefenderExclusion $w }
        $oscdimg = Get-Oscdimg

        Enter-Step 2 'Sources'
        $found = @(Get-SourceIsos $Cfg.IsoFolder)
        foreach ($f in $found) { Write-Log "Found ISO $(Split-Path $f.Path -Leaf): build $($f.Build), $($f.Lang), $($f.Editions.Name -join ', ')" }
        if (-not $found) { Write-Log "No ISOs in $($Cfg.IsoFolder)" }
        $plan = Get-BuildPlan $found $(if ($Cfg.UseUup) { Get-UupBuilds } else { @() }) $Cfg
        if ($plan.Newest) { Write-Log "Newest Windows: $($plan.Newest.title)" }
        if ($plan.Note) { Write-Log $plan.Note }
        if ($plan.Error) { throw $plan.Error }
        $base = $plan.Base; $missing = $plan.Missing; $uup = $plan.Uup
        if ($uup) { Write-Log "UUP build: $($uup.title)" }
        $sources = @()   # @{ Iso; Name }
        if ($base) {
            Write-Log "Base ISO: $($base.Path)"
            $sources += $Cfg.Editions | Where-Object { $_ -in $base.Editions.Name } | ForEach-Object { @{ Iso = $base.Path; Name = $_ } }
        }
        if ($missing) {
            Assert-FreeSpace $w $false
            Write-Log "Downloading via UUP dump: $($missing -join ', ') (this takes a while)"
            if ($Cfg.Fast) { Write-Log 'Fast mode: latest update not integrated (Windows Update installs it after setup)' }
            $t = Get-Date
            $uupIso = Save-UupIso $uup.uuid $Cfg.BaseLang $missing "$w\uup" $Cfg.Fast
            Write-Log "UUP download + conversion took $(Format-Duration ((Get-Date) - $t))"
            # Keep it with your ISOs so the next build reuses it instead of downloading again.
            New-Item -ItemType Directory -Force $Cfg.IsoFolder | Out-Null
            $uupIso = (Move-Item $uupIso $Cfg.IsoFolder -Force -PassThru).FullName
            Set-Content "$uupIso.build" $uup.build
            Write-Log "Saved $(Split-Path $uupIso -Leaf) to $($Cfg.IsoFolder) for next builds"
            if (-not $base) { $base = Get-IsoInfo $uupIso }
            $sources += $missing | ForEach-Object { @{ Iso = $uupIso; Name = $_ } }
        }
        $drive = Mount-SourceIso $base.Path
        Write-Log "Copying $($base.Path)"
        $ErrorActionPreference = 'Continue'
        # Skip the install image (4-6 GB): step 3 exports the editions straight from the mounted ISO.
        robocopy "$drive\" "$w\iso" /E /A-:R /XF install.wim install.esd install*.swm /NFL /NDL /NJH /NJS /NP | Out-Null
        if ($LASTEXITCODE -ge 8) { throw "robocopy failed ($LASTEXITCODE)" }
        $ErrorActionPreference = 'Stop'


        $cacheWim = Get-ImageCachePath $Cfg $sources
        $cached = $cacheWim -and (Test-Path $cacheWim)
        if (-not $cached) { Assert-FreeSpace $w $false }

        Enter-Step 3 'Editions'
        if ($cached) { Write-Log 'Same source ISO, editions and patches as the last build: reusing the finished image (steps 3, 4 and 7 skipped)' }
        foreach ($s in $sources) {
            if ($cached) { break }
            $wim = Get-InstallImage (Mount-SourceIso $s.Iso)
            $idx = (Get-WindowsImage -ImagePath $wim | Where-Object ImageName -eq $s.Name).ImageIndex
            Write-Log "Export $($s.Name) (index $idx) - takes 1-3 minutes"
            Export-WindowsImage -SourceImagePath $wim -SourceIndex $idx -DestinationImagePath "$w\install.wim" -CompressionType fast | Out-Null
        }
        Clear-BuildState

        Enter-Step 4 'Patches'
        $images = if (-not $cached) { Get-WindowsImage -ImagePath "$w\install.wim" }
        foreach ($img in $images) {
            if ($Sync.Cancel) { throw 'Cancelled by user' }
            Write-Log "Mount $($img.ImageName) - takes 1-2 minutes"
            Mount-WindowsImage -ImagePath "$w\install.wim" -Index $img.ImageIndex -Path "$w\mount" | Out-Null
            Invoke-Patches "$w\mount" $Cfg.Patches $Cfg
            # ponytail: no StartComponentCleanup here (slow, small gain); the max-compression export in step 7 shrinks the image.
            Write-Log "Saving $($img.ImageName) - writing the image and cleaning up takes 3-5 minutes, no output meanwhile"
            Dismount-WindowsImage -Path "$w\mount" -Save | Out-Null
            Write-Log "Saved $($img.ImageName)"
        }

        Enter-Step 5 'Setup (boot.wim)'
        if ($Cfg.Patches -contains 'hwchecks') {
            Mount-WindowsImage -ImagePath "$w\iso\sources\boot.wim" -Index 2 -Path "$w\mount" | Out-Null
            Set-BootPatches "$w\mount"
            Dismount-WindowsImage -Path "$w\mount" -Save | Out-Null
        }

        Enter-Step 6 'Unattended'
        if ($Cfg.Unattend.Enabled) {
            $dir = "$w\iso\sources\`$OEM`$\`$`$\Setup\Scripts"   # copied to C:\Windows\Setup\Scripts
            if ($Cfg.Unattend.CustomScript -or $Cfg.Unattend.Apps -or $Cfg.Unattend.WifiName) { New-Item -ItemType Directory -Force $dir | Out-Null }
            if ($Cfg.Unattend.WifiName) { [IO.File]::WriteAllText("$dir\wifi.xml", (New-WifiProfile $Cfg.Unattend.WifiName $Cfg.Unattend.WifiPassword)); Write-Log "Wi-Fi: $($Cfg.Unattend.WifiName) (password in plain text on the ISO)" }
            if ($Cfg.Unattend.CustomScript) { Copy-Item $Cfg.Unattend.CustomScript "$dir\custom.ps1" }
            if ($Cfg.Unattend.Apps) { Set-Content "$dir\apps.ps1" (New-AppsScript $Cfg.Unattend.Apps); Write-Log "Apps: $($Cfg.Unattend.Apps -join ', ')" }
            [IO.File]::WriteAllText("$w\iso\autounattend.xml", (New-UnattendXml $Cfg.Unattend))
            if ($Cfg.Unattend.AutoInstall -eq 'BestSsd') { Copy-Item "$PSScriptRoot\autoinstall.js" "$w\iso\sources\autoinstall.js" }
            Write-Log 'autounattend.xml written'
        }
        elseif ('localaccount' -in $Cfg.Patches) {
            [IO.File]::WriteAllText("$w\iso\autounattend.xml", (New-LocalAccountXml))
            Write-Log 'autounattend.xml written (only hides Microsoft account screens)'
        }

        Enter-Step 7 'Compress'
        # Quick = XPRESS: a few minutes faster per edition, about 1 GB bigger ISO.
        $comp = if ($Cfg.QuickCompress) { 'fast' } else { 'max' }
        foreach ($img in $images) {
            Write-Log "Export $($img.ImageName) ($comp compression) - takes $(if ($Cfg.QuickCompress) { '1-3' } else { '5-10' }) minutes"
            Export-WindowsImage -SourceImagePath "$w\install.wim" -SourceIndex $img.ImageIndex -DestinationImagePath "$w\iso\sources\install.wim" -CompressionType $comp | Out-Null
        }
        if ($cached) { Write-Log 'Copying the cached image'; Copy-Item $cacheWim "$w\iso\sources\install.wim" }
        elseif ($cacheWim) {
            # Keep only the newest finished image (about 5 GB).
            New-Item -ItemType Directory -Force $Cfg.CacheDir | Out-Null
            Remove-Item "$($Cfg.CacheDir)\install-*.wim" -ErrorAction SilentlyContinue
            Copy-Item "$w\iso\sources\install.wim" "$cacheWim.tmp"; Move-Item "$cacheWim.tmp" $cacheWim -Force   # never a half-written cache
            Write-Log 'Finished image cached: the next build with the same editions and patches is much faster'
        }
        # Read back the final image so the report shows what actually ended up in it.
        foreach ($img in Get-WindowsImage -ImagePath "$w\iso\sources\install.wim") {
            $d = Get-WindowsImage -ImagePath "$w\iso\sources\install.wim" -Index $img.ImageIndex
            $script:Report.Images += "$($d.ImageName) - version $($d.Version), languages $($d.Languages -join ', '), $([math]::Round($d.ImageSize/1GB,1)) GB installed"
            Write-Log " $($script:Report.Images[-1])"
        }
        Write-Log "install.wim: $([math]::Round((Get-Item "$w\iso\sources\install.wim").Length/1GB,2)) GB"
        if ($Cfg.Split) {
            Split-WindowsImage -ImagePath "$w\iso\sources\install.wim" -SplitImagePath "$w\iso\sources\install.swm" -FileSize 3800 | Out-Null
            Remove-Item "$w\iso\sources\install.wim"
        } elseif ((Get-Item "$w\iso\sources\install.wim").Length -gt 4GB) {
            Write-Log 'NOTE: install.wim > 4 GB - use Rufus (NTFS) or tick "Split for FAT32 USB"'
        }

        Enter-Step 8 'Create ISO'
        if (Test-Path $Cfg.Output) { Remove-Item $Cfg.Output }
        # Mark the ISO with the builder version: volume label (shown in Explorer / on a Rufus stick) + info file.
        $label = Get-IsoLabel $Cfg.ToolVersion
        Set-Content "$w\iso\Win11Ultimate.txt" (Get-IsoInfoText $Cfg)
        Get-PresetData $Cfg | ConvertTo-Json -Depth 4 | Set-Content "$w\iso\Win11Ultimate-preset.json"   # Load it in the builder to rebuild this ISO
        Write-Log "ISO label $label, Win11Ultimate.txt + preset added"
        $boot = "2#p0,e,b$w\iso\boot\etfsboot.com#pEF,e,b$w\iso\efi\microsoft\boot\efisys.bin"
        $ErrorActionPreference = 'Continue'   # oscdimg writes progress to stderr
        Write-Log "Writing $($Cfg.Output) - takes 1-3 minutes"
        $out = & $oscdimg -m -o -u2 -udfver102 "-bootdata:$boot" "-l$label" "$w\iso" $Cfg.Output 2>&1
        if ($LASTEXITCODE) {
            $out | Where-Object { "$_" -notmatch '% complete' } | Select-Object -Last 5 | ForEach-Object { Write-Log " oscdimg: $_" }
            throw "oscdimg failed ($LASTEXITCODE)"
        }
        $ErrorActionPreference = 'Stop'

        Enter-Step 9 'Finish'
        $saved = $Cfg.Clone(); $saved.Unattend = $Cfg.Unattend.Clone(); $saved.Unattend.Password = ''; $saved.Unattend.ProductKey = ''; $saved.Unattend.WifiPassword = ''   # never write secrets to disk
        $saved | ConvertTo-Json -Depth 5 | Set-Content (Join-Path (Split-Path $Cfg.Output) 'config.json')
        Copy-Item "$w\iso\Win11Ultimate-preset.json" (Split-Path $Cfg.Output)   # same preset as on the ISO, for Load
        Remove-ImagePath $w
        Write-Log "DONE: $($Cfg.Output) ($([math]::Round((Get-Item $Cfg.Output).Length/1GB,1)) GB)"
    } catch {
        $Sync.Error = "$_"
        Write-Log "ERROR in step $($Sync.Step): $_"
        Write-Log "Work folder kept for inspection: $w"
    } finally {
        try { Clear-BuildState } catch { Write-Log "Cleanup warning: $_" }
        Remove-DefenderExclusion
        try { Write-BuildSummary $Cfg } catch { Write-Log "Summary failed: $_" }
        $Sync.Done = $true
    }
}
