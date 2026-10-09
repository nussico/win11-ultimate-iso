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
Assert (-not ($Patches.Values.Reg | Where-Object { $_ -and $_ -notmatch '^(SYSTEM|SOFTWARE|DEFAULT)\\[^|]+\|([^|@][^|]*\|(\d+|-|sz:[^|]*)|@\|)$' })) 'All reg entries well-formed'
Assert (-not ($Patches.Values | Where-Object { -not $_.Desc })) 'Every patch has a description'

$reg = Get-PatchReg $Presets.Recommended.Patches
Assert ($reg.Count -gt 0 -and -not ($reg | Where-Object { -not $_ -or $_ -notmatch '\|' })) 'Get-PatchReg: no empty entries for patches without Reg (bloatapps)'

function Write-Log($Msg) { $script:logged += "$Msg`n" }
$tmp = New-Item -ItemType Directory -Force "$env:TEMP\w11rmtest"; 'x' | Set-Content "$tmp\file.exe"; New-Item -ItemType Directory -Force "$tmp\dir\sub" | Out-Null
$script:logged = ''; Remove-ImagePath "$tmp\file.exe"; Remove-ImagePath "$tmp\dir"
Assert (-not (Test-Path "$tmp\file.exe") -and -not (Test-Path "$tmp\dir") -and $script:logged -notmatch 'not a valid directory') 'Remove-ImagePath: single file and folder'
Remove-Item $tmp -Recurse -Force

# Patch targets: during setup HKLM is the running system
$Online = $true
Assert ((Convert-RegPath 'SOFTWARE\X') -eq 'HKLM\SOFTWARE\X' -and (Convert-RegPath 'DEFAULT\Y') -eq 'HKLM\WIM_DEFAULT\Y' -and (Get-ImageArg 'C:').Online) 'Online: HKLM direct, default user hive loaded, DISM -Online'
$Online = $false
Assert ((Get-ImageArg 'X:\m').Path -eq 'X:\m') 'Offline: DISM -Path'

# During-setup script: parses, runs each patch on its own, quotes values safely
$ss = New-SetupPatchScript @('bloatapps', 'pinversion') @{ ReleaseVersion = "25H2'x" }
$e = $null; [Management.Automation.Language.Parser]::ParseInput($ss, [ref]$null, [ref]$e) | Out-Null
Assert (-not $e -and $ss -match "@\('bloatapps', 'pinversion'\)" -and $ss -match "'25H2''x'" -and $ss -match '\$Online = \$true') 'Setup patch script: valid, ids + quoted version'
$ux = [xml](Add-SetupPatchCommands (New-UnattendXml @{ UserName = 'U'; Password = ''; TimeZone = 'UTC'; Keyboard = 'de-DE'; Locale = 'de-DE'; Edition = 'Windows 11 Pro'; AutoInstall = 'BestSsd' }) $true)
$pe = @(($ux.unattend.settings | Where-Object pass -eq 'windowsPE').component | Where-Object name -eq 'Microsoft-Windows-Setup').RunSynchronous.RunSynchronousCommand
Assert ($pe[0].Path -match 'LabConfig' -and $pe[-1].Path -match 'autoinstall\.js' -and (($pe.Order) -join ',') -eq '1,2,3,4,5,6') 'Setup mode: TPM bypass runs before Best SSD install, orders renumbered'
$sp = @(($ux.unattend.settings | Where-Object pass -eq 'specialize').component | Where-Object name -eq 'Microsoft-Windows-Deployment').RunSynchronous.RunSynchronousCommand
Assert ($sp.Path -match 'Win11Ultimate-patches\.ps1' -and $ux.OuterXml -notmatch 'd\dp\d:') 'Setup mode: specialize runs the patch script, wcm prefix kept'
$ex = [xml](Add-SetupPatchCommands (New-EmptyUnattendXml) $false)
Assert (-not ($ex.unattend.settings | Where-Object pass -eq 'windowsPE') -and ($ex.unattend.settings | Where-Object pass -eq 'specialize')) 'Setup mode without Unattended: answer file with only the patch script'

# Features: missing ones skipped (Home), a failure only warns, the source reaches DISM
Assert ('pinversion' -notin $Presets.Extreme.Patches -and -not ($Presets.Extreme.Patches | Where-Object { $Patches[$_].Group -eq 'Features' })) 'Extreme skips features and the version pin'
function Get-WindowsOptionalFeature { @([pscustomobject]@{ FeatureName = 'NetFx3' }, [pscustomobject]@{ FeatureName = 'Bad' }) }
function Enable-WindowsOptionalFeature { param($Path, $FeatureName, [switch]$All, $Source, [switch]$LimitAccess, [switch]$NoRestart); if ($FeatureName -eq 'Bad') { throw 'boom' }; $script:logged += "src=$Source`n" }
$script:logged = ''; Enable-ImageFeature 'X:\mount' 'Microsoft-Hyper-V-All', 'Bad', 'NetFx3' 'X:\iso\sources\sxs'
Assert ($script:logged -match 'skip feature Microsoft-Hyper-V-All' -and $script:logged -match 'WARN could not enable Bad' -and $script:logged -match 'src=X:\\iso\\sources\\sxs' -and $script:logged -match 'enable feature NetFx3') 'Enable-ImageFeature: skip, warn, source'
Remove-Item function:Get-WindowsOptionalFeature, function:Enable-WindowsOptionalFeature

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
Assert ($s -match 'International-Core-WinPE' -and $s -match '<SetupUILanguage><UILanguage>de-DE</UILanguage>') 'Setup language page skipped (windowsPE)'
Assert ($s -notmatch 'apps\.ps1') 'No apps -> no apps script'
$u.Apps = @('Discord.Discord'); $s = ([xml](New-UnattendXml $u)).OuterXml; $u.Apps = $null
Assert ($s -match 'apps\.ps1' -and $s.IndexOf('apps.ps1') -lt $s.IndexOf('christitus')) 'Apps installed at first login, before WinUtil'
Assert ($s -notmatch 'wifi\.xml') 'No Wi-Fi -> no Wi-Fi command'
$u.Apps = @('Discord.Discord'); $u.WifiName = 'Home'; $s = ([xml](New-UnattendXml $u)).OuterXml; $u.Apps = $null; $u.WifiName = $null
Assert ($s -match 'wlan add profile' -and $s.IndexOf('wifi.xml') -lt $s.IndexOf('apps.ps1') -and $s -match 'del C:\\Windows\\Setup\\Scripts\\wifi.xml') 'Wi-Fi joined before the apps, profile file deleted'
$w = [xml](New-WifiProfile 'Caf<e> & "Net"' 'p&ss<word>1')
Assert ($w.WLANProfile.name -eq 'Caf<e> & "Net"' -and $w.WLANProfile.MSM.security.sharedKey.keyMaterial -eq 'p&ss<word>1' -and $w.WLANProfile.connectionMode -eq 'auto') 'Wi-Fi profile: valid XML, name/password escaped, auto-connect'
Assert (([xml](New-WifiProfile 'Open' '')).WLANProfile.MSM.security.authEncryption.authentication -eq 'open') 'Wi-Fi profile: no password -> open network'
$found = @(ConvertFrom-WingetSearch @('   - ', 'Name            Id                            Version          Match                Source',
    '------------------------------------------------------------------------------------------',
    'Discord         Discord.Discord               1.0.9261         ProductCode: discord winget',
    'Discord (arm64) Discord.Discord.arm64         1.0.53           ProductCode: discord winget'))
Assert ($found.Count -eq 2 -and $found[0].Id -eq 'Discord.Discord' -and $found[1].Name -eq 'Discord (arm64)') 'winget search output -> Name/Id'
Assert (-not (ConvertFrom-WingetSearch @('No package found matching input criteria.'))) 'winget search: nothing found'
$as = New-AppsScript @('Valve.Steam', "x'; Remove-Item C:\ -Recurse #")
$e = $null; [Management.Automation.Language.Parser]::ParseInput($as, [ref]$null, [ref]$e) | Out-Null
Assert ($as -match "'Valve.Steam'" -and $as -notmatch 'Remove-Item' -and -not $e) 'Apps script: valid PowerShell, bad IDs dropped'
Assert ($as -match 'winget install [^\r\n]*--source winget') 'Apps script installs from the winget source only (msstore fails on a fresh install)'
$u.AutoInstall = 'Disk0'; $u.SkipOobe = $false; $u.Edition = ''; $u.Password = ''
$s = ([xml](New-UnattendXml $u)).OuterXml
Assert ($s -match 'WillWipeDisk' -and $s -notmatch 'HideOnlineAccountScreens' -and $s -notmatch 'ProductKey') 'Disk0 wipe, OOBE shown, no key'
$u.Edition = 'Windows 11 Pro'; $u.ProductKey = 'AAAAA-BBBBB-CCCCC-DDDDD-EEEEE'
$s = ([xml](New-UnattendXml $u)).OuterXml
Assert ($s -match 'AAAAA-BBBBB' -and $s -notmatch 'VK7JG') 'Own product key overrides generic key'
$u.AutoInstall = 'BestSsd'
$s = ([xml](New-UnattendXml $u)).OuterXml
Assert ($s -match 'cscript //nologo %d:\\sources\\autoinstall.js "Windows 11 Pro"' -and $s -notmatch 'WillWipeDisk') 'BestSsd runs script with edition, no fixed-disk wipe'
$s = ([xml](New-LocalAccountXml)).OuterXml
Assert ($s -match 'HideOnlineAccountScreens>true' -and $s -notmatch 'windowsPE|LocalAccounts') 'Local-account-only XML: hides MS account, setup stays interactive'
Assert (-not (Get-AccountNameError 'Max Muster' 'GAMING-PC') -and -not (Get-AccountNameError 'User' '')) 'Normal user and computer names pass'
Assert ((Get-AccountNameError 'a/b' '') -and (Get-AccountNameError 'Administrator' '') -and (Get-AccountNameError ('x' * 21) '')) 'Bad, reserved and too long usernames are caught'
Assert ((Get-AccountNameError 'User' 'MY_PC') -and (Get-AccountNameError 'User' '12345') -and (Get-AccountNameError 'User' 'A-VERY-LONG-PC-NAME') -and (Get-AccountNameError 'Pc1' 'PC1')) 'Bad computer names are caught (chars, only digits, > 15, same as user)'

# Disk picking (autoinstall.js, run with cscript like Setup does), fed with real Win32_DiskDrive values.
$cases = [ordered]@{
    'NVMe beats HDD'                 = '[HDD(0,2000), NVME(1,1000)], [], 1'
    'SATA SSD beats HDD'             = '[HDD(0,2000), SSD(1,500)], [], 1'
    'NVMe beats SATA SSD'            = '[NVME(0,1000), SSD(1,500)], [], 0'
    'Two NVMe -> ambiguous, no pick' = '[NVME(0,1000), NVME(1,2000)], [], null'
    'Two HDDs -> no pick'            = '[HDD(0,1000), HDD(1,2000)], [], null'
    'USB never picked'               = '[USB(0,1000), HDD(1,500)], [], 1'
    'External USB HDD never picked'  = '[toDisk(0, "WD Elements", "SCSI", "SCSI\\DISK&VEN_WD", "External hard disk media", 2000 * GB), HDD(1,500)], [], 1'
    'Disk < 64 GB never picked'      = '[NVME(0,32)], [], null'
    'Install-media disk excluded'    = '[NVME(0,1000), SSD(1,500)], [0], 1'
    'Single Hyper-V disk picked'     = '[toDisk(0, "Microsoft Virtual Disk", "SCSI", "SCSI\\DISK&VEN_MSFT&PROD_VIRTUAL_DISK\\000000", "Fixed hard disk media", "85899345920")], [], 0'
}
$js = "var TESTING = true;`r`n" + (Get-Content "$root\lib\autoinstall.js" -Raw) + "`r`n" +
    'function NVME(n, gb) { return toDisk(n, "CT1000P5SSD8", "SCSI", "SCSI\\DISK&VEN_NVME&PROD_CT1000P5SSD8\\5&1", "Fixed hard disk media", gb * GB); }' + "`r`n" +
    'function SSD(n, gb) { return toDisk(n, "Samsung SSD 870 EVO 500GB", "IDE", "SCSI\\DISK&VEN_SAMSUNG&PROD_SSD_870\\4&1", "Fixed hard disk media", gb * GB); }' + "`r`n" +
    'function HDD(n, gb) { return toDisk(n, "ST4000DM004-2CV104", "IDE", "SCSI\\DISK&VEN_&PROD_ST4000DM004\\4&1", "Fixed hard disk media", gb * GB); }' + "`r`n" +
    'function USB(n, gb) { return toDisk(n, "SanDisk Extreme SSD", "USB", "USBSTOR\\DISK&VEN_SANDISK\\1", "Removable Media", gb * GB); }' + "`r`n" +
    'function t(disks, ex, want) { var d = selectTargetDisk(disks, ex); WScript.Echo((d ? d.Number : null) === want ? "ok" : "FAIL"); }' + "`r`n" +
    (($cases.Values | ForEach-Object { "t($_);" }) -join "`r`n")
$jsFile = Join-Path $env:TEMP 'w11-autoinstall-test.js'
Set-Content $jsFile $js -Encoding ASCII
$res = @(cscript //nologo //E:jscript $jsFile)
Remove-Item $jsFile
$i = 0; foreach ($name in $cases.Keys) { Assert ($res[$i++] -eq 'ok') $name }
# Builder's wipe preview: same script on this PC, read-only.
Set-Content $jsFile ("var PREVIEW = true;`r`n" + (Get-Content "$root\lib\autoinstall.js" -Raw)) -Encoding ASCII
$res = @(cscript //nologo //E:jscript $jsFile)
Remove-Item $jsFile
Assert ($res[0] -match '^(PICK Disk \d+: |NOPICK$)' -and ($res | Select-Object -Skip 1) -match '^Disk \d+: .+ GB, ') 'Wipe preview lists this PC''s disks'

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
Assert (-not (Get-SkippedNewerRelease $builds (Select-NewestUupBuild $builds))) 'Newest: known new-PC-only 26H1 is no warning'
$ins = @($builds) + [pscustomobject]@{ title = 'Windows 11, version 27H2 Insider Preview 10.0.29000.1 (rs_prerelease)'; build = '29000.1'; uuid = 'i' }
Assert ((Select-NewestUupBuild $ins).uuid -eq 'f' -and -not (Get-SkippedNewerRelease $ins (Select-NewestUupBuild $ins))) 'Newest: Insider previews are neither picked nor reported'
$h1 = @($builds) + [pscustomobject]@{ title = 'Windows 11, version 27H1 (28100.500)'; build = '28100.500'; uuid = 'g' }
Assert ((Select-NewestUupBuild $h1).uuid -eq 'f' -and (Get-SkippedNewerRelease $h1 (Select-NewestUupBuild $h1)).uuid -eq 'g') 'Newest: unknown 27H1 is skipped but reported'
$c = @{ BaseLang = 'de-de'; Editions = @('Windows 11 Pro'); UseUup = $true; Newest = $true; UupBuild = ''; IsoFolder = 'src' }
Assert ((Get-BuildPlan @() $h1 $c).Skipped.uuid -eq 'g') 'Plan: reports the skipped newer release'
$c.UupBuild = 'g'
Assert (-not (Get-BuildPlan @() $h1 $c).Skipped -and (Get-BuildPlan @() $h1 $c).Uup.uuid -eq 'g') 'Plan: picking it by hand uses it, no warning'

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
Assert (-not $pl.Base -and $pl.Missing.Count -eq 2 -and $pl.Uup.build -like '26300.*' -and $pl.Note) 'Plan: ISO without all ticked editions -> download one with exactly these'
$both = I 26300 'Windows 11 Home', 'Windows 11 Pro'; $pro = I 26300 'Windows 11 Pro'
Assert ((Get-BuildPlan @($pro, $both) $builds $c).Base -eq $both) 'Plan: Home+Pro ticked -> the Home+Pro ISO'
$c.Editions = @('Windows 11 Pro')
Assert ((Get-BuildPlan @($both) $builds $c).Missing -eq 'Windows 11 Pro') 'Plan: only Pro ticked, only a multi-edition ISO -> download a Pro ISO'
Assert ((Get-BuildPlan @($pro, $both) $builds $c).Base -eq $pro) 'Plan: only Pro ticked -> the Pro-only ISO'
Assert ((Get-BuildPlan @($both) @() $c).Base -eq $both) 'Plan: UUP unreachable -> multi-edition ISO is used'
Assert ((Get-DownloadEditions 'Windows 11 Enterprise') -join ',' -eq 'Windows 11 Enterprise,Windows 11 Pro') 'Download of a virtual edition contains Pro'
$c.Editions = @('Windows 11 Home', 'Windows 11 Pro')
$fastIso = I 26300 'Windows 11 Pro' | Add-Member Fast $true -PassThru
$pl = Get-BuildPlan @($fastIso) $builds $c
Assert (-not $pl.Base -and $pl.Missing.Count -eq 2) 'Plan: old Fast-mode ISO not mixed into a build'
$c.Editions = @('Windows 11 Pro')
Assert (-not (Get-BuildPlan @($fastIso) $builds $c).Base) 'Plan: old Fast-mode ISO replaced by a full download'
$c.UseUup = $false
Assert ((Get-BuildPlan @($fastIso) $builds $c).Base) 'Plan: Fast-mode ISO used when UUP is off (only source)'

# Download source Microsoft
$c = @{ BaseLang = 'de-de'; Editions = @('Windows 11 Pro'); UseUup = $true; Download = 'Microsoft'; Newest = $true; UupBuild = ''; IsoFolder = 'src' }
$pl = Get-BuildPlan @($both) $builds $c
Assert (-not $pl.Microsoft -and -not $pl.Base -and $pl.Missing -eq 'Windows 11 Pro' -and $pl.Uup.uuid -eq 'f' -and $pl.Note -match 'Smaller image but longer download') 'Microsoft: only Pro ticked, multi-edition ISO -> UUP download of a Pro image, with a note'
Assert ((Get-BuildPlan @($both) @() $c).Base -eq $both) 'Microsoft: only Pro ticked, UUP dump unreachable -> multi-edition ISO is used'
$c.UupBuild = 'a'
Assert ((Get-BuildPlan @($both) $builds $c).Uup.uuid -eq 'f' -and $c.UupBuild -eq 'a') 'Microsoft: only Pro ticked, a build picked earlier under UUP dump is ignored'
$c.UupBuild = ''
Assert ((Test-MsSubset 'Windows 11 Pro') -and -not (Test-MsSubset $MsIsoEditions) -and -not (Test-MsSubset 'Windows 11 Pro', 'Windows 11 Enterprise')) 'Microsoft: only fewer of its own editions go to UUP dump'
$c.Editions = $MsIsoEditions
$all = I 26300 $MsIsoEditions; $all100 = I 26100 $MsIsoEditions
$pl = Get-BuildPlan @() $builds $c
Assert ($pl.Microsoft -and $pl.Missing.Count -eq 3 -and -not $pl.Uup -and -not $pl.Error) 'Microsoft: no ISO -> official ISO download'
Assert ((Get-BuildPlan @() @() $c).Microsoft) 'Microsoft: works without UUP dump'
$pl = Get-UupFallbackPlan @() $builds $c
Assert ($pl.Uup.uuid -eq 'f' -and -not $pl.Microsoft -and $c.Download -eq 'Microsoft') 'Microsoft refused: fallback plans the UUP download, config unchanged'
Assert ((Get-UupFallbackPlan @() @() $c).Error) 'Microsoft refused and UUP dump unreachable: error'
$pl = Get-BuildPlan @($all) $builds $c
Assert ($pl.Base -eq $all -and -not $pl.Microsoft -and -not $pl.Missing) 'Microsoft: ISO with the ticked editions is reused'
$pl = Get-BuildPlan @($all100) $builds $c
Assert ($pl.Microsoft -and $pl.Base -and -not $pl.Missing -and $pl.Note) 'Microsoft: older ISO kept, download only if Microsoft has newer'
$c.Newest = $false
Assert (-not (Get-BuildPlan @($all100) $builds $c).Microsoft) 'Microsoft: older ISO used as-is when newest is off'
$c.Editions = @('Windows 11 Pro', 'Windows 11 Enterprise')
Assert ((Get-BuildPlan @() $builds $c).Error -match 'Enterprise') 'Microsoft: Enterprise is not in the official ISO -> error'
$c.Editions = $MsIsoEditions; $c.BaseLang = 'xx-xx'
Assert ((Get-BuildPlan @() $builds $c).Error -match 'no ISO in xx-xx') 'Microsoft: unknown language -> error'
Assert (-not ($MsIsoLanguages.Keys | Where-Object { $_ -cne $_.ToLower() }) -and $MsIsoLanguages.Count -ge 38) 'Microsoft: language map uses lower-case codes'
Assert (-not ($MsIsoEditions | Where-Object { -not $UupEditions.Contains($_) })) 'Microsoft: its editions are known editions'

# Save-Download: local server sends 2 of 3 MB then goes silent (dead hotspot), then serves the rest on a Range request
$data = New-Object byte[] (3MB); (New-Object Random 7).NextBytes($data)
$listener = New-Object Net.Sockets.TcpListener ([Net.IPAddress]::Loopback), 0
$listener.Start(); $port = $listener.LocalEndpoint.Port
$server = [powershell]::Create().AddScript({
    param($l, $data)
    $ranges = @(); $open = @(); $w = [Text.Encoding]::ASCII
    foreach ($i in 1, 2) {
        # Gives up after 15 s without a connection, so a broken client can't hang the test
        $end = (Get-Date).AddSeconds(15); while (-not $l.Pending() -and (Get-Date) -lt $end) { Start-Sleep -Milliseconds 50 }
        if (-not $l.Pending()) { break }
        $c = $l.AcceptTcpClient(); $open += $c; $s = $c.GetStream()
        $r = New-Object IO.StreamReader $s; $h = ''
        while (($line = $r.ReadLine())) { $h += "$line`n" }
        $from = [regex]::Match($h, '(?i)range: *bytes=(\d+)-').Groups[1].Value; $ranges += $from
        if ($i -eq 1) { $b = $w.GetBytes("HTTP/1.1 200 OK`r`nContent-Length: $($data.Length)`r`n`r`n"); $s.Write($b, 0, $b.Length); $s.Write($data, 0, 2MB) }
        else {
            $f = [int]$from
            $b = $w.GetBytes("HTTP/1.1 206 Partial Content`r`nContent-Length: $($data.Length - $f)`r`nContent-Range: bytes $f-$($data.Length - 1)/$($data.Length)`r`nConnection: close`r`n`r`n")
            $s.Write($b, 0, $b.Length); $s.Write($data, $f, $data.Length - $f)
        }
        $s.Flush()
    }
    Start-Sleep 1; $open | ForEach-Object { $_.Close() }
    $ranges
}).AddArgument($listener).AddArgument($data)
$job = $server.BeginInvoke()
$script:logged = ''
$tmp = New-Item -ItemType Directory -Force "$env:TEMP\w11dltest"
try { Save-Download "http://127.0.0.1:$port/a.iso" "$tmp\dl.iso" -StallSeconds 1 -Retries 2 } catch { Write-Host $_ }
$ranges = @($server.EndInvoke($job)); $server.Dispose(); $listener.Stop()
$sha = [Security.Cryptography.SHA256]::Create()
$same = (Test-Path "$tmp\dl.iso") -and [Convert]::ToBase64String($sha.ComputeHash([IO.File]::ReadAllBytes("$tmp\dl.iso"))) -eq [Convert]::ToBase64String($sha.ComputeHash($data))
Assert ($same -and [int]$ranges[1] -gt 0 -and $script:logged -match 'resuming at' -and -not (Test-Path "$tmp\dl.iso.part")) 'Save-Download: stalled connection resumes where it stopped'
Remove-Item $tmp -Recurse -Force

$q = Get-UupRequest @('Windows 11 Pro')
Assert ($q.Body -match 'updates=1' -and $q.Edition -eq 'PROFESSIONAL' -and $q.Body -match 'autodl=2') 'UUP request always integrates the latest update (inbox apps need it)'
$q = Get-UupRequest @('Windows 11 Home', 'Windows 11 Enterprise')
Assert ($q.Body -match 'updates=1' -and $q.Edition -eq 'CORE;PROFESSIONAL' -and $q.Body -match 'autodl=3' -and $q.Body -match 'cleanup=1' -and $q.Body -match 'virtualEditions\[\]=Enterprise') 'Virtual edition adds Pro base'

# Preset file: choices only, never secrets or paths
$pd = Get-PresetData @{ BaseLang = 'de-de'; Editions = @('Windows 11 Pro'); Patches = @('hwchecks'); IsoFolder = 'D:\isos'; Output = 'D:\out\x.iso'
    Unattend = @{ Enabled = $true; UserName = 'Max'; Password = 'secret1'; ProductKey = 'AAAAA-BBBBB-CCCCC-DDDDD-EEEEE'; CustomScript = 'D:\my.ps1'; Apps = @('Valve.Steam'); WifiName = 'HomeNet'; WifiPassword = 'wifisecret' } }
$pj = $pd | ConvertTo-Json -Depth 4
Assert ($pj -match 'Max' -and $pj -match 'Valve.Steam' -and $pj -match 'hwchecks' -and $pj -match 'HomeNet' -and $pj -notmatch 'secret1|AAAAA|wifisecret|D:\\\\') 'Preset file: choices kept, no secrets or paths'

# ISO version stamp (Build.ps1 loaded in a child scope so its Write-Log stays out of the way)
& {
    . "$root\lib\Build.ps1"
    $src = @(@{ Iso = $PSCommandPath; Name = 'Windows 11 Pro' })
    $k = { param($p, $u) Get-ImageCacheKey @{ Patches = $p; QuickCompress = $true; Unattend = @{ UserName = $u } } $src }
    Assert ((& $k @('hwchecks') 'A') -eq (& $k @('hwchecks') 'B') -and (& $k @('hwchecks') 'A') -ne (& $k @('hwchecks', 'telemetry') 'A') -and (& $k @('hwchecks') 'A') -match '^install-[0-9a-f]{16}\.wim$') 'Image cache: reused when only Unattended changes, new when patches change'
    Assert ((& $k @('hwchecks') 'A') -ne (Get-ImageCacheKey @{ Patches = @('hwchecks'); QuickCompress = $true; PatchMode = 'Setup' } $src)) 'Image cache: patch mode is part of the key'
    Assert ((Get-IsoLabel '99cfb89') -eq 'W11U_99CFB89' -and (Get-IsoLabel '') -eq 'W11U_DEV' -and (Get-IsoLabel 'a b-c!') -eq 'W11U_ABC') 'ISO label: W11U_<version>, safe characters only'
    $t = Get-IsoInfoText @{ ToolVersion = '99cfb89'; Editions = @('Windows 11 Pro'); BaseLang = 'de-de'; Patches = @('hwchecks')
        Unattend = @{ Enabled = $true; AutoInstall = 'BestSsd'; Apps = @('Valve.Steam'); Password = 'secret1'; ProductKey = 'AAAAA-BBBBB-CCCCC-DDDDD-EEEEE' } }
    Assert ($t -match 'Builder 99cfb89' -and $t -match 'Windows 11 Pro' -and $t -match 'Valve.Steam' -and $t -notmatch 'secret1|AAAAA') 'Win11Ultimate.txt: version + choices, no secrets'
}

# Start-Background wiring (same as Builder.ps1): Source.ps1 functions and both arguments reach $Work.
$ps = [powershell]::Create()
$ps.AddScript('param($root) . "$root\lib\Source.ps1"').AddArgument($root).
    AddStatement().AddScript("$({ param($root, $x) "$x $([bool](Get-Command Get-UupBuilds -ErrorAction SilentlyContinue)) $(Test-Path $root)" })").AddArgument($root).AddArgument('arg') | Out-Null
Assert ("$($ps.Invoke())" -eq 'arg True True') 'Start-Background: $Work gets $root, $Arg and the lib\Source.ps1 functions'
$ps.Dispose()

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
