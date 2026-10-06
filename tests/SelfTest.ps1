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
Assert (-not ($Patches.Values.Reg | Where-Object { $_ -and $_ -notmatch '^(SYSTEM|SOFTWARE|DEFAULT)\\[^|]+\|[^|]+\|(\d+|-)$' })) 'All reg entries well-formed'

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

if ($fails) { Write-Host "$fails failed" -ForegroundColor Red; exit 1 } else { Write-Host 'all passed' -ForegroundColor Green }
