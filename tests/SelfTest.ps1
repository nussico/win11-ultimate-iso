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
Assert (-not ($Presets.Values | Where-Object { $_.Unattend.AutoPartition })) 'No preset sets AutoPartition'
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
    Keyboard = 'de-DE'; Locale = 'de-DE'; SkipOobe = $true; Edition = 'Windows 11 Pro'; AutoPartition = $false; RunWinUtil = $true; CustomScript = ''; EnableAdmin = $false }
$x = [xml](New-UnattendXml $u)
$s = $x.OuterXml
Assert ($s -match '<Name>User</Name>' -and $s -match 'Administrators') 'Unattend user + admin group'
Assert ($s -notmatch 'p&lt;w' -and $s -notmatch 'p<w') 'Password not stored in plain text'
Assert ($s -notmatch 'WillWipeDisk') 'No disk wipe unless AutoPartition'
Assert ($s -match 'VK7JG-NPHTM-C97JM-9MPGT-3V66T') 'Edition Pro -> generic Pro key'
Assert ($s -match 'HideOnlineAccountScreens' -and $s -match 'christitus') 'SkipOobe + WinUtil'
Assert ($s -match '<ComputerName>\*</ComputerName>') 'Empty computer name -> random'
$u.AutoPartition = $true; $u.SkipOobe = $false; $u.Edition = ''; $u.Password = ''
$s = ([xml](New-UnattendXml $u)).OuterXml
Assert ($s -match 'WillWipeDisk' -and $s -notmatch 'HideOnlineAccountScreens' -and $s -notmatch 'ProductKey') 'AutoPartition on, OOBE shown, no key'
$u.Edition = 'Windows 11 Pro'; $u.ProductKey = 'AAAAA-BBBBB-CCCCC-DDDDD-EEEEE'
$s = ([xml](New-UnattendXml $u)).OuterXml
Assert ($s -match 'AAAAA-BBBBB' -and $s -notmatch 'VK7JG') 'Own product key overrides generic key'

# Source
$info = ConvertTo-IsoInfo 'x.iso' @([pscustomobject]@{ ImageIndex = 1; ImageName = 'Windows 11 Home' }, [pscustomobject]@{ ImageIndex = 6; ImageName = 'Windows 11 Pro' }) ([pscustomobject]@{ Languages = @('de-DE'); Version = '10.0.26200.6584' })
Assert ($info.Lang -eq 'de-de' -and $info.Build -eq '26200' -and $info.Editions[1].Index -eq 6) 'ConvertTo-IsoInfo'
$builds = @(
    [pscustomobject]@{ title = 'Windows 11, version 25H2 (26200.7985)'; build = '26200.7985'; uuid = 'a' }
    [pscustomobject]@{ title = 'Windows 11, version 25H2 (26200.9106)'; build = '26200.9106'; uuid = 'b' }
    [pscustomobject]@{ title = 'Preview Update for Windows 11 (26200.9550)'; build = '26200.9550'; uuid = 'c' }
    [pscustomobject]@{ title = 'Windows 11, version 26H1 (28000.3086)'; build = '28000.3086'; uuid = 'd' })
Assert ((Select-UupBuild $builds '26200').uuid -eq 'b') 'Select-UupBuild: newest matching major, no previews'

if ($fails) { Write-Host "$fails failed" -ForegroundColor Red; exit 1 } else { Write-Host 'all passed' -ForegroundColor Green }
