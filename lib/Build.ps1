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
    Write-Log "Win11 Ultimate Builder - build started $(Get-Date -Format 'yyyy-MM-dd HH:mm')"
    Write-Log "Host:           $((Get-CimInstance Win32_OperatingSystem).Caption) $([Environment]::OSVersion.Version), PowerShell $($PSVersionTable.PSVersion)"
    Write-Log "Editions:       $($Cfg.Editions -join ', ')"
    Write-Log "Base language:  $($Cfg.BaseLang)"
    Write-Log "Patches:        $(if ($Cfg.Patches) { ($Cfg.Patches | ForEach-Object { $Patches[$_].Label }) -join '; ' } else { 'none' })"
    Write-Log "Source:         ISO folder $($Cfg.IsoFolder); UUP dump $(if ($Cfg.UseUup) { 'on' } else { 'off' }); always newest $(if ($Cfg.Newest) { 'on' } else { 'off' }); fast mode $(if ($Cfg.Fast) { 'on' } else { 'off' })"
    Write-Log "Unattended:     $(if ($u.Enabled) { "user '$($u.UserName)', auto-install $($u.AutoInstall), edition '$($u.Edition)', $(if ($u.ProductKey) { 'own product key' } else { 'generic key' }), skip OOBE $($u.SkipOobe)" } else { 'off' })"
    Write-Log "Output:         $($Cfg.Output)$(if ($Cfg.Split) { ' (install.wim split for FAT32)' })"
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

function Get-WinPEOcs {
    $p = "${env:ProgramFiles(x86)}\Windows Kits\10\Assessment and Deployment Kit\Windows Preinstallation Environment\amd64\WinPE_OCs"
    if (Test-Path "$p\WinPE-PowerShell.cab") { return $p }
    $ErrorActionPreference = 'Continue'
    Write-Log 'WinPE add-on not found, installing via winget (about 1 GB)...'
    winget install -e --id Microsoft.WindowsADK.WinPEAddon --accept-package-agreements --accept-source-agreements --override '/quiet /norestart /features OptionId.WindowsPreinstallationEnvironment' | Out-Null
    if (Test-Path "$p\WinPE-PowerShell.cab") { return $p }
    throw 'WinPE add-on missing. Install "Windows ADK WinPE add-on" and retry.'
}

# PowerShell + storage/DISM cmdlets for autoinstall.ps1. Order matters (dependencies first).
function Add-WinPEPowerShell($Mount, $Ocs, $Lang) {
    foreach ($oc in 'WinPE-WMI', 'WinPE-NetFX', 'WinPE-Scripting', 'WinPE-PowerShell', 'WinPE-StorageWMI', 'WinPE-DismCmdlets') {
        Write-Log " add $oc"
        foreach ($cab in "$Ocs\$oc.cab", "$Ocs\$lang\${oc}_$lang.cab") {
            if (Test-Path $cab) { Add-WindowsPackage -Path $Mount -PackagePath $cab | Out-Null }
        }
    }
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
        $free = (Get-PSDrive ($w.Substring(0, 1))).Free
        if ($free -lt 60GB) { throw "Need 60 GB free on $($w.Substring(0,2)), have $([math]::Round($free/1GB)) GB" }
        Write-Log "Free space on $($w.Substring(0,2)): $([math]::Round($free/1GB)) GB"
        Clear-BuildState
        Clear-WindowsCorruptMountPoint | Out-Null
        if (Test-Path $w) {
            Write-Log "Removing old work folder $w"
            # Leftovers of an interrupted build are owned by TrustedInstaller; Remove-ImagePath takes ownership first.
            try { Remove-Item $w -Recurse -Force -ErrorAction Stop } catch { Remove-ImagePath $w }
            if (Test-Path $w) { throw "Could not delete the old work folder $w. Restart the PC and try again." }
        }
        foreach ($d in 'iso', 'mount', 'uup') { New-Item -ItemType Directory -Force "$w\$d" | Out-Null }
        $oscdimg = Get-Oscdimg
        $peOcs = if ($Cfg.Unattend.Enabled -and $Cfg.Unattend.AutoInstall -eq 'BestSsd') { Get-WinPEOcs }

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
        robocopy "$drive\" "$w\iso" /E /A-:R /NFL /NDL /NJH /NJS /NP | Out-Null
        if ($LASTEXITCODE -ge 8) { throw "robocopy failed ($LASTEXITCODE)" }
        $ErrorActionPreference = 'Stop'
        Remove-Item "$w\iso\sources\install.wim", "$w\iso\sources\install.esd" -ErrorAction SilentlyContinue


        Enter-Step 3 'Editions'
        foreach ($s in $sources) {
            $wim = Get-InstallImage (Mount-SourceIso $s.Iso)
            $idx = (Get-WindowsImage -ImagePath $wim | Where-Object ImageName -eq $s.Name).ImageIndex
            Write-Log "Export $($s.Name) (index $idx) - takes 1-3 minutes"
            Export-WindowsImage -SourceImagePath $wim -SourceIndex $idx -DestinationImagePath "$w\install.wim" -CompressionType fast | Out-Null
        }
        Clear-BuildState

        Enter-Step 4 'Patches'
        $images = Get-WindowsImage -ImagePath "$w\install.wim"
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
        $bestSsd = $Cfg.Unattend.Enabled -and $Cfg.Unattend.AutoInstall -eq 'BestSsd'
        if ($Cfg.Patches -contains 'hwchecks' -or $bestSsd) {
            $peLang = ([string]@((Get-WindowsImage -ImagePath "$w\iso\sources\boot.wim" -Index 2).Languages)[0]).ToLower()
            Mount-WindowsImage -ImagePath "$w\iso\sources\boot.wim" -Index 2 -Path "$w\mount" | Out-Null
            if ($Cfg.Patches -contains 'hwchecks') { Set-BootPatches "$w\mount" }
            if ($bestSsd) { Add-WinPEPowerShell "$w\mount" $peOcs $peLang }
            Dismount-WindowsImage -Path "$w\mount" -Save | Out-Null
        }

        Enter-Step 6 'Unattended'
        if ($Cfg.Unattend.Enabled) {
            if ($Cfg.Unattend.CustomScript) {
                $dir = New-Item -ItemType Directory -Force "$w\iso\sources\`$OEM`$\`$`$\Setup\Scripts"
                Copy-Item $Cfg.Unattend.CustomScript "$dir\custom.ps1"
            }
            [IO.File]::WriteAllText("$w\iso\autounattend.xml", (New-UnattendXml $Cfg.Unattend))
            if ($bestSsd) {
                Copy-Item "$PSScriptRoot\autoinstall.ps1" "$w\iso\sources\autoinstall.ps1"
                @{ Edition = $Cfg.Unattend.Edition } | ConvertTo-Json | Set-Content "$w\iso\sources\autoinstall.json"
            }
            Write-Log 'autounattend.xml written'
        }
        elseif ('localaccount' -in $Cfg.Patches) {
            [IO.File]::WriteAllText("$w\iso\autounattend.xml", (New-LocalAccountXml))
            Write-Log 'autounattend.xml written (only hides Microsoft account screens)'
        }

        Enter-Step 7 'Compress'
        foreach ($img in $images) {
            Write-Log "Export $($img.ImageName) (max compression) - takes 5-10 minutes"
            Export-WindowsImage -SourceImagePath "$w\install.wim" -SourceIndex $img.ImageIndex -DestinationImagePath "$w\iso\sources\install.wim" -CompressionType max | Out-Null
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
        $boot = "2#p0,e,b$w\iso\boot\etfsboot.com#pEF,e,b$w\iso\efi\microsoft\boot\efisys.bin"
        $ErrorActionPreference = 'Continue'   # oscdimg writes progress to stderr
        Write-Log "Writing $($Cfg.Output) - takes 1-3 minutes"
        & $oscdimg -m -o -u2 -udfver102 "-bootdata:$boot" -lWIN11_ULTIMATE "$w\iso" $Cfg.Output 2>&1 | Out-Null
        if ($LASTEXITCODE) { throw "oscdimg failed ($LASTEXITCODE)" }
        $ErrorActionPreference = 'Stop'

        Enter-Step 9 'Finish'
        $saved = $Cfg.Clone(); $saved.Unattend = $Cfg.Unattend.Clone(); $saved.Unattend.Password = ''; $saved.Unattend.ProductKey = ''   # never write secrets to disk
        $saved | ConvertTo-Json -Depth 5 | Set-Content (Join-Path (Split-Path $Cfg.Output) 'config.json')
        Remove-ImagePath $w
        Write-Log "DONE: $($Cfg.Output) ($([math]::Round((Get-Item $Cfg.Output).Length/1GB,1)) GB)"
    } catch {
        $Sync.Error = "$_"
        Write-Log "ERROR in step $($Sync.Step): $_"
        Write-Log "Work folder kept for inspection: $w"
    } finally {
        try { Clear-BuildState } catch { Write-Log "Cleanup warning: $_" }
        try { Write-BuildSummary $Cfg } catch { Write-Log "Summary failed: $_" }
        $Sync.Done = $true
    }
}
