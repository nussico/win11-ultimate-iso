# Pure-logic self-checks. Run: powershell -File tests\SelfTest.ps1
$ErrorActionPreference = 'Stop'
$root = Split-Path $PSScriptRoot
. "$root\lib\Patches.ps1"; . "$root\lib\Unattend.ps1"; . "$root\lib\Source.ps1"
$script:fails = 0
function Assert($Cond, $Msg) { if ($Cond) { Write-Host "ok   $Msg" } else { Write-Host "FAIL $Msg" -ForegroundColor Red; $script:fails++ } }

# Presets
Assert (-not (Compare-Object $Presets.Basic.Patches @('hwchecks', 'localaccount', 'skipprivacy', 'nobitlocker'))) 'Basic = setup bypasses'
Assert ('xboxapp' -notin $Presets.Recommended.Patches -and 'edge' -notin $Presets.Recommended.Patches) 'Recommended has no Xbox/Edge removal'
Assert ('xboxapp' -in $Presets.Extreme.Patches -and 'defender' -in $Presets.Extreme.Patches) 'Extreme has aggressive + Xbox'
Assert ('drivers' -notin $Presets.Extreme.Patches) 'Extreme skips drivers (needs a folder)'
Assert (-not ($Presets.Values | Where-Object { $_.Unattend.AutoInstall })) 'No preset sets AutoInstall'
Assert (-not ($Presets.Values.Patches | Where-Object { -not $Patches.Contains($_) })) 'Preset ids exist in catalog'

# Protected apps
Assert (-not ($ProtectedApps | Where-Object { $_ -notlike '*`**' -and -not (Test-ProtectedApp $_) })) 'Every protected name is protected'
Assert (Test-ProtectedApp 'Microsoft.VCLibs.140.00.UWPDesktop') 'Wildcard protects VCLibs'
Assert (-not ($RemoveApps | Where-Object { Test-ProtectedApp $_ })) 'Removal list has no protected app'
$r = Get-AppsToRemove @('Microsoft.WindowsStore', 'Clipchamp.Clipchamp', 'Microsoft.GetHelp') @('Microsoft.WindowsStore', 'Clipchamp.Clipchamp', 'Microsoft.GetHelp', 'Microsoft.BingNews')
Assert (($r -join ',') -eq 'Clipchamp.Clipchamp') 'Get-AppsToRemove skips protected and not-provisioned'

# Registry
Assert ((Convert-RegPath 'SYSTEM\Setup\LabConfig') -eq 'HKLM\WIM_SYSTEM\Setup\LabConfig') 'Convert-RegPath'
Assert (-not ($Patches.Values.Reg | Where-Object { $_ -and $_ -notmatch '^(SYSTEM|SOFTWARE|DEFAULT)\\[^|]+\|([^|@][^|]*\|(\d+|-)|@\|)$' })) 'All reg entries well-formed'
Assert (-not ($Patches.Values | Where-Object { -not $_.Desc })) 'Every patch has a description'

$reg = Get-PatchReg $Presets.Recommended.Patches
Assert ($reg.Count -gt 0 -and -not ($reg | Where-Object { -not $_ -or $_ -notmatch '\|' })) 'Get-PatchReg: no empty entries for patches without Reg (bloatapps)'

function Write-Log($Msg) { $script:logged += "$Msg`n" }
$tmp = New-Item -ItemType Directory -Force "$env:TEMP\w11rmtest"; 'x' | Set-Content "$tmp\file.exe"; New-Item -ItemType Directory -Force "$tmp\dir\sub" | Out-Null
$script:logged = ''; Remove-ImagePath "$tmp\file.exe"; Remove-ImagePath "$tmp\dir"
Assert (-not (Test-Path "$tmp\file.exe") -and -not (Test-Path "$tmp\dir") -and $script:logged -notmatch 'not a valid directory') 'Remove-ImagePath: single file and folder'
Remove-Item $tmp -Recurse -Force

# Unattend
$u = @{ UserName = 'User'; Password = 'p<w'; Admin = $true; AutoLogon = $true; ComputerName = ''; TimeZone = 'W. Europe Standard Time'
    Keyboard = 'de-DE'; Locale = 'de-DE'; SkipOobe = $true; Edition = 'Windows 11 Pro'; AutoInstall = 'Off'; RunWinUtil = $true; CustomScript = ''; EnableAdmin = $false }
$x = [xml](New-UnattendXml $u)
$s = $x.OuterXml
Assert ($s -match '<Name>User</Name>' -and $s -match 'Administrators') 'Unattend user + admin group'
Assert ($s -notmatch 'p&lt;w' -and $s -notmatch 'p<w') 'Password not stored in plain text'
Assert ($s -notmatch 'WillWipeDisk') 'No disk wipe when AutoInstall Off'
Assert ($s -match 'VK7JG-NPHTM-C97JM-9MPGT-3V66T') 'Edition Pro -> generic Pro key'
Assert ($s -match 'HideOnlineAccountScreens' -and $s -match 'christitus') 'SkipOobe + WinUtil'
Assert ($s -match '<ComputerName>\*</ComputerName>') 'Empty computer name -> random'
$u.AutoInstall = 'Disk0'; $u.SkipOobe = $false; $u.Edition = ''; $u.Password = ''
$s = ([xml](New-UnattendXml $u)).OuterXml
Assert ($s -match 'WillWipeDisk' -and $s -notmatch 'HideOnlineAccountScreens' -and $s -notmatch 'ProductKey') 'Disk0 wipe, OOBE shown, no key'
$u.Edition = 'Windows 11 Pro'; $u.ProductKey = 'AAAAA-BBBBB-CCCCC-DDDDD-EEEEE'
$s = ([xml](New-UnattendXml $u)).OuterXml
Assert ($s -match 'AAAAA-BBBBB' -and $s -notmatch 'VK7JG') 'Own product key overrides generic key'
$u.AutoInstall = 'BestSsd'
$s = ([xml](New-UnattendXml $u)).OuterXml
Assert ($s -match 'autoinstall.ps1' -and $s -notmatch 'WillWipeDisk') 'BestSsd runs script, no fixed-disk wipe'
$s = ([xml](New-LocalAccountXml)).OuterXml
Assert ($s -match 'HideOnlineAccountScreens>true' -and $s -notmatch 'windowsPE|LocalAccounts') 'Local-account-only XML: hides MS account, setup stays interactive'

# Disk picking (autoinstall.ps1)
. "$root\lib\autoinstall.ps1"
function D($n, $bus, $media, $gb) { [pscustomobject]@{ Number = $n; BusType = $bus; MediaType = $media; Size = [int64]$gb * 1GB } }
Assert ((Select-TargetDisk @((D 0 'SATA' 'HDD' 2000), (D 1 'NVMe' 'SSD' 1000))).Number -eq 1) 'NVMe beats HDD'
Assert ((Select-TargetDisk @((D 0 'SATA' 'HDD' 2000), (D 1 'SATA' 'SSD' 500))).Number -eq 1) 'SATA SSD beats HDD'
Assert ((Select-TargetDisk @((D 0 'NVMe' 'SSD' 1000), (D 1 'SATA' 'SSD' 500))).Number -eq 0) 'NVMe beats SATA SSD'
Assert ($null -eq (Select-TargetDisk @((D 0 'NVMe' 'SSD' 1000), (D 1 'NVMe' 'SSD' 2000)))) 'Two NVMe -> ambiguous, no pick'
Assert ($null -eq (Select-TargetDisk @((D 0 'SATA' 'HDD' 1000), (D 1 'SATA' 'HDD' 2000)))) 'Two HDDs -> no pick'
Assert ((Select-TargetDisk @((D 0 'USB' 'SSD' 1000), (D 1 'SATA' 'HDD' 500))).Number -eq 1) 'USB never picked'
Assert ($null -eq (Select-TargetDisk @((D 0 'NVMe' 'SSD' 32)))) 'Disk < 64 GB never picked'
Assert ((Select-TargetDisk @((D 0 'NVMe' 'SSD' 1000), (D 1 'SATA' 'SSD' 500)) -Exclude 0).Number -eq 1) 'Install-media disk excluded'
Assert ((Select-TargetDisk @((D 0 'SCSI' 'Unspecified' 127))).Number -eq 0) 'Single Hyper-V disk picked'

# Source
$info = ConvertTo-IsoInfo 'x.iso' @([pscustomobject]@{ ImageIndex = 1; ImageName = 'Windows 11 Home' }, [pscustomobject]@{ ImageIndex = 6; ImageName = 'Windows 11 Pro' }) ([pscustomobject]@{ Languages = @('de-DE'); Version = '10.0.26200.6584' })
Assert ($info.Lang -eq 'de-de' -and $info.Build -eq '26200' -and $info.Editions[1].Index -eq 6) 'ConvertTo-IsoInfo'
$builds = @(
    [pscustomobject]@{ title = 'Windows 11, version 25H2 (26200.7985)'; build = '26200.7985'; uuid = 'a' }
    [pscustomobject]@{ title = 'Windows 11, version 25H2 (26200.9106)'; build = '26200.9106'; uuid = 'b' }
    [pscustomobject]@{ title = 'Preview Update for Windows 11 (26200.9550)'; build = '26200.9550'; uuid = 'c' }
    [pscustomobject]@{ title = 'Windows 11, version 26H1 (28000.3086)'; build = '28000.3086'; uuid = 'd' })
Assert ((Select-UupBuild $builds '26200').uuid -eq 'b') 'Select-UupBuild: newest matching major, no previews'
$builds += [pscustomobject]@{ title = 'Windows 11, version 24H2 (26100.9448)'; build = '26100.9448'; uuid = 'e' }
Assert ((Select-NewestUupBuild $builds).uuid -eq 'b') 'Newest: 25H2 newest revision, skips 26H1 and previews'
$builds += [pscustomobject]@{ title = 'Windows 11, version 26H2 (26300.1000)'; build = '26300.1000'; uuid = 'f' }
Assert ((Select-NewestUupBuild $builds).uuid -eq 'f') 'Newest: switches to 26H2 once it exists'

# Build plan (shared by build + GUI)
function I($b, [string[]]$eds) { [pscustomobject]@{ Path = "x$b.iso"; Lang = 'de-de'; Build = "$b"; Editions = @($eds | ForEach-Object { [pscustomobject]@{ Name = $_ } }) } }
$c = @{ BaseLang = 'de-de'; Editions = @('Windows 11 Pro'); UseUup = $true; Newest = $true; UupBuild = ''; IsoFolder = 'src' }
$pl = Get-BuildPlan @(I 26300 'Windows 11 Pro') $builds $c
Assert ($pl.Base -and -not $pl.Missing -and -not $pl.Error) 'Plan: current ISO is reused, nothing downloaded'
$pl = Get-BuildPlan @(I 26100 'Windows 11 Pro') $builds $c
Assert (-not $pl.Base -and $pl.Missing -eq 'Windows 11 Pro' -and $pl.Uup.uuid -eq 'f' -and $pl.Note) 'Plan: older ISO -> download newest'
$c.UseUup = $false
$pl = Get-BuildPlan @(I 26100 'Windows 11 Pro') $builds $c
Assert ($pl.Base -and -not $pl.Error -and $pl.Note -match 'newer') 'Plan: older ISO kept when UUP is off, with a note'
Assert ((Get-BuildPlan @() $builds $c).Error -match 'No ISO') 'Plan: no ISO and no UUP -> error'
$c.UseUup = $true; $c.Editions = @('Windows 11 Home', 'Windows 11 Pro')
$pl = Get-BuildPlan @(I 26300 'Windows 11 Pro') $builds $c
Assert ($pl.Base -and $pl.Missing -eq 'Windows 11 Home' -and $pl.Uup.build -like '26300.*') 'Plan: missing edition downloaded for the ISO build'

$q = Get-UupRequest @('Windows 11 Pro') $true
Assert ($q.Body -match 'updates=0' -and $q.Updates -eq 0 -and $q.Edition -eq 'PROFESSIONAL' -and $q.Body -match 'autodl=2') 'Fast mode: no update integration'
$q = Get-UupRequest @('Windows 11 Home', 'Windows 11 Enterprise') $false
Assert ($q.Body -match 'updates=1' -and $q.Edition -eq 'CORE;PROFESSIONAL' -and $q.Body -match 'autodl=3' -and $q.Body -match 'virtualEditions\[\]=Enterprise') 'Normal mode + virtual edition adds Pro base'

# Background build wiring (same pattern as Builder.ps1). Cancel is preset, so nothing is built.
$sync = [hashtable]::Synchronized(@{ Log = New-Object 'System.Collections.Concurrent.ConcurrentQueue[string]'; Step = 0; Cancel = $true; Done = $false; Error = $null })
$ps = [powershell]::Create()
$ps.AddScript({
        param($root, $cfg, $sync)
        . "$root\lib\Patches.ps1"; . "$root\lib\Unattend.ps1"; . "$root\lib\Source.ps1"; . "$root\lib\Build.ps1"
        Invoke-Build $cfg $sync
    }).AddArgument($root).AddArgument(@{ Output = "$env:TEMP\w11selftest\x.iso"; WorkDir = "$env:TEMP\w11selftest\work"; Unattend = @{} }).AddArgument($sync) | Out-Null
$ps.Invoke() | Out-Null; $ps.Dispose()
Assert ($sync.Done -and $sync.Error -eq 'Cancelled by user' -and $sync.Log.Count -gt 0) 'Background build reports log + done to the GUI'

if ($fails) { Write-Host "$fails failed" -ForegroundColor Red; exit 1 } else { Write-Host 'all passed' -ForegroundColor Green }
