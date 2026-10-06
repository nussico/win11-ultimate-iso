# Build pipeline. Runs in a background runspace; talks to the GUI via $Sync (synchronized hashtable):
#   Log (ConcurrentQueue[string]), Step (int), Cancel (bool), Done (bool), Error (string)

$script:BuildSync = $null
$script:LogFile = $null
$script:MountedIsos = @()

function Write-Log($Msg) {
    $line = '[{0:HH:mm:ss}] {1}' -f (Get-Date), $Msg
    if ($script:BuildSync) { $script:BuildSync.Log.Enqueue($line) } else { Write-Host $line }
    if ($script:LogFile) { Add-Content $script:LogFile $line }
}

function Enter-Step($N, $Name) {
    if ($script:BuildSync.Cancel) { throw 'Cancelled by user' }
    $script:BuildSync.Step = $N
    Write-Log "== Step $N/9: $Name"
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
    try {
        Enter-Step 1 'Preflight'
        $isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole('Administrators')
        if (-not $isAdmin) { throw 'Must run as administrator' }
        $free = (Get-PSDrive ($w.Substring(0, 1))).Free
        if ($free -lt 60GB) { throw "Need 60 GB free on $($w.Substring(0,2)), have $([math]::Round($free/1GB)) GB" }
        Clear-BuildState
        Clear-WindowsCorruptMountPoint | Out-Null
        if (Test-Path $w) { Remove-Item $w -Recurse -Force }
        foreach ($d in 'iso', 'mount', 'uup') { New-Item -ItemType Directory -Force "$w\$d" | Out-Null }
        $oscdimg = Get-Oscdimg
        $peOcs = if ($Cfg.Unattend.Enabled -and $Cfg.Unattend.AutoInstall -eq 'BestSsd') { Get-WinPEOcs }

        Enter-Step 2 'Sources'
        $base = Get-SourceIsos $Cfg.IsoFolder | Where-Object Lang -eq $Cfg.BaseLang | Sort-Object Build -Descending | Select-Object -First 1
        $builds = $null; $newest = $null
        if ($Cfg.UseUup -or $Cfg.LangPacks) {
            $builds = Get-UupBuilds
            $newest = Select-NewestUupBuild $builds
            if ($newest) { Write-Log "Newest Windows: $($newest.title)" }
        }
        if ($Cfg.Newest -and $base -and $newest -and [int]$base.Build -lt [int]$newest.build.Split('.')[0]) {
            if ($Cfg.UseUup) { Write-Log "Your ISO is build $($base.Build) (older version): downloading the newest instead"; $base = $null }
            else { Write-Log "NOTE: a newer Windows version exists ($($newest.title)); turn on UUP dump to use it" }
        }
        $missing = @($Cfg.Editions | Where-Object { -not $base -or $_ -notin $base.Editions.Name })
        if ($missing -and -not $Cfg.UseUup) {
            if (-not $base) { throw "No ISO for base language $($Cfg.BaseLang) in $($Cfg.IsoFolder). Add one or enable UUP dump." }
            throw "Editions not in your ISO: $($missing -join ', '). Enable UUP dump or untick them."
        }
        $major = if ($base) { $base.Build } elseif ($newest) { $newest.build.Split('.')[0] } else { throw 'Could not reach UUP dump' }
        $uup = $null
        if ($missing -or $Cfg.LangPacks) {
            $uup = if ($Cfg.UupBuild) { $builds | Where-Object uuid -eq $Cfg.UupBuild } else { Select-UupBuild $builds $major }
            if (-not $uup) { throw "No UUP dump build found for build $major" }
            if ($uup.build.Split('.')[0] -ne $major) { throw "UUP build $($uup.build) does not match ISO build $major. Pick a $major build." }
            Write-Log "UUP build: $($uup.title)"
        }
        $sources = @()   # @{ Iso; Name }
        if ($base) {
            Write-Log "Base ISO: $($base.Path)"
            $sources += $Cfg.Editions | Where-Object { $_ -in $base.Editions.Name } | ForEach-Object { @{ Iso = $base.Path; Name = $_ } }
        }
        if ($missing) {
            Write-Log "Downloading via UUP dump: $($missing -join ', ') (this takes a while)"
            if ($Cfg.Fast) { Write-Log 'Fast mode: latest update not integrated (Windows Update installs it after setup)' }
            $uupIso = Save-UupIso $uup.uuid $Cfg.BaseLang $missing "$w\uup" $Cfg.Fast
            # Keep it with your ISOs so the next build reuses it instead of downloading again.
            New-Item -ItemType Directory -Force $Cfg.IsoFolder | Out-Null
            $uupIso = (Move-Item $uupIso $Cfg.IsoFolder -Force -PassThru).FullName
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

        $lps = @()
        foreach ($lang in $Cfg.LangPacks | Where-Object { $_ -ne $Cfg.BaseLang }) {
            Write-Log "Language pack $lang"
            $lps += Save-UupLanguagePack $uup.uuid $lang "$($Cfg.CacheDir)\$($uup.uuid)"
        }

        Enter-Step 3 'Editions'
        foreach ($s in $sources) {
            $wim = Get-InstallImage (Mount-SourceIso $s.Iso)
            $idx = (Get-WindowsImage -ImagePath $wim | Where-Object ImageName -eq $s.Name).ImageIndex
            Write-Log "Export $($s.Name) (index $idx)"
            Export-WindowsImage -SourceImagePath $wim -SourceIndex $idx -DestinationImagePath "$w\install.wim" -CompressionType fast | Out-Null
        }
        Clear-BuildState

        Enter-Step 4 'Language packs + patches'
        $images = Get-WindowsImage -ImagePath "$w\install.wim"
        foreach ($img in $images) {
            if ($Sync.Cancel) { throw 'Cancelled by user' }
            Write-Log "Mount $($img.ImageName)"
            Mount-WindowsImage -ImagePath "$w\install.wim" -Index $img.ImageIndex -Path "$w\mount" | Out-Null
            foreach ($lp in $lps) {
                Write-Log " add LP $($lp.Lp)"
                Add-WindowsPackage -Path "$w\mount" -PackagePath $lp.Lp | Out-Null
                foreach ($cap in $lp.Capabilities) {
                    try { Add-WindowsCapability -Path "$w\mount" -Name $cap -Source $lp.FodDir -LimitAccess | Out-Null; Write-Log "  + $cap" }
                    catch { Write-Log "  WARN $cap not added (Windows installs it online later): $($_.Exception.Message.Split("`n")[0])" }
                }
            }
            Invoke-Patches "$w\mount" $Cfg.Patches $Cfg
            # ponytail: no StartComponentCleanup here (slow, small gain); the max-compression export in step 7 shrinks the image.
            Dismount-WindowsImage -Path "$w\mount" -Save | Out-Null
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

        Enter-Step 7 'Compress'
        foreach ($img in $images) {
            Write-Log "Export $($img.ImageName) (max compression)"
            Export-WindowsImage -SourceImagePath "$w\install.wim" -SourceIndex $img.ImageIndex -DestinationImagePath "$w\iso\sources\install.wim" -CompressionType max | Out-Null
        }
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
        & $oscdimg -m -o -u2 -udfver102 "-bootdata:$boot" -lWIN11_ULTIMATE "$w\iso" $Cfg.Output 2>&1 | Out-Null
        if ($LASTEXITCODE) { throw "oscdimg failed ($LASTEXITCODE)" }
        $ErrorActionPreference = 'Stop'

        Enter-Step 9 'Finish'
        $saved = $Cfg.Clone(); $saved.Unattend = $Cfg.Unattend.Clone(); $saved.Unattend.Password = ''; $saved.Unattend.ProductKey = ''   # never write secrets to disk
        $saved | ConvertTo-Json -Depth 5 | Set-Content (Join-Path (Split-Path $Cfg.Output) 'config.json')
        Remove-Item $w -Recurse -Force
        Write-Log "DONE: $($Cfg.Output) ($([math]::Round((Get-Item $Cfg.Output).Length/1GB,1)) GB)"
    } catch {
        $Sync.Error = "$_"
        Write-Log "ERROR in step $($Sync.Step): $_"
        Write-Log "Work folder kept for inspection: $w"
    } finally {
        try { Clear-BuildState } catch { Write-Log "Cleanup warning: $_" }
        $Sync.Done = $true
    }
}
