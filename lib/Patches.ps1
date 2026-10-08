# Patch catalog, app lists and presets.
# Reg entries: 'HIVE\Key|Name|Value'  (HIVE = SYSTEM, SOFTWARE or DEFAULT; DWORD values; 'sz:text' = string value;
#   Value '-' deletes the value; Name '@' with no value = empty default value)

$RemoveApps = @(
    'Clipchamp.Clipchamp', 'Microsoft.BingNews', 'Microsoft.BingWeather', 'Microsoft.Getstarted',
    'Microsoft.MicrosoftOfficeHub', 'Microsoft.MicrosoftSolitaireCollection', 'Microsoft.People',
    'Microsoft.PowerAutomateDesktop', 'Microsoft.Todos', 'Microsoft.WindowsFeedbackHub',
    'Microsoft.WindowsMaps', 'MSTeams', 'Microsoft.OutlookForWindows', 'Microsoft.Copilot',
    'Microsoft.Windows.DevHome', 'MicrosoftCorporationII.MicrosoftFamily'
)

# Never removed, even if a removal list names them. Wildcards allowed.
$ProtectedApps = @(
    'Microsoft.WindowsStore', 'Microsoft.DesktopAppInstaller', 'Microsoft.VCLibs.*', 'Microsoft.UI.Xaml.*',
    'Microsoft.NET.Native.*', 'Microsoft.WebView2*', 'Microsoft.EdgeWebView*', 'Microsoft.SecHealthUI',
    'Microsoft.StorePurchaseApp', 'Microsoft.HEIFImageExtension', 'Microsoft.VP9VideoExtensions',
    'Microsoft.WebpImageExtension', 'Microsoft.AV1VideoExtension', 'Microsoft.LanguageExperiencePack*',
    'Microsoft.WindowsCalculator', 'Microsoft.Windows.Photos', 'Microsoft.WindowsNotepad',
    'Microsoft.WindowsTerminal', 'Microsoft.Paint', 'Microsoft.ScreenSketch', 'Microsoft.WindowsCamera',
    'Microsoft.WindowsSoundRecorder', 'Microsoft.XboxIdentityProvider', 'Microsoft.Xbox.TCUI',
    'Microsoft.XboxGamingOverlay', 'Microsoft.GetHelp'
)

$CdmOff = 'ContentDeliveryAllowed', 'SilentInstalledAppsEnabled', 'SystemPaneSuggestionsEnabled', 'SoftLandingEnabled',
    'PreInstalledAppsEnabled', 'OemPreInstalledAppsEnabled', 'SubscribedContent-338388Enabled',
    'SubscribedContent-338389Enabled', 'SubscribedContent-353694Enabled', 'SubscribedContent-353696Enabled' |
    ForEach-Object { "DEFAULT\Software\Microsoft\Windows\CurrentVersion\ContentDeliveryManager|$_|0" }

$Patches = [ordered]@{
    hwchecks     = @{ Group = 'Setup'; Label = 'Skip TPM/CPU/RAM checks'; Boot = $true
        Desc = 'Installs on PCs without TPM 2.0, Secure Boot, 4 GB RAM or a supported CPU.'; Reg = @(
            'SYSTEM\Setup\LabConfig|BypassTPMCheck|1', 'SYSTEM\Setup\LabConfig|BypassSecureBootCheck|1',
            'SYSTEM\Setup\LabConfig|BypassRAMCheck|1', 'SYSTEM\Setup\LabConfig|BypassCPUCheck|1',
            'SYSTEM\Setup\LabConfig|BypassStorageCheck|1', 'SYSTEM\Setup\MoSetup|AllowUpgradesWithUnsupportedTPMOrCPU|1') }
    localaccount = @{ Group = 'Setup'; Label = 'Local account (BypassNRO)'
        Desc = 'Setup works without internet and without a Microsoft account. You create a local user during setup.'; Reg = @(
            'SOFTWARE\Microsoft\Windows\CurrentVersion\OOBE|BypassNRO|1') }
    skipprivacy  = @{ Group = 'Setup'; Label = 'Skip privacy screens'
        Desc = 'Skips the privacy settings questions (location, ads ID, diagnostics) during setup.'; Reg = @(
            'SOFTWARE\Policies\Microsoft\Windows\OOBE|DisablePrivacyExperience|1') }
    nobitlocker  = @{ Group = 'Setup'; Label = 'No automatic BitLocker'
        Desc = 'Windows does not encrypt the drive on its own. You can still turn BitLocker on later.'; Reg = @(
            'SYSTEM\ControlSet001\Control\BitLocker|PreventDeviceEncryption|1') }

    bloatapps    = @{ Group = 'Apps'; Label = 'Remove bloat apps'
        Desc = 'Removes: ' + (($RemoveApps | ForEach-Object { $_.Split('.')[-1] }) -join ', ') + '. Store, Calculator, Photos, Xbox login and Game Bar are always kept.'
        Action = { param($m, $c) Remove-Apps $m $RemoveApps } }
    xboxapp      = @{ Group = 'Apps'; Label = 'Remove Xbox app'
        Desc = 'Removes only the Xbox app. Xbox login and Game Bar stay, so games keep working.'
        Action = { param($m, $c) Remove-Apps $m @('Microsoft.GamingApp') } }
    onedrive     = @{ Group = 'Apps'; Label = 'Remove OneDrive'
        Desc = 'OneDrive is not installed for new users. You can still get it from the Store later.'; Reg = @(
            'DEFAULT\Software\Microsoft\Windows\CurrentVersion\Run|OneDriveSetup|-')
        Action = { param($m, $c) Remove-ImagePath "$m\Windows\System32\OneDriveSetup.exe" } }

    telemetry    = @{ Group = 'Privacy'; Label = 'Disable telemetry'
        Desc = 'Turns off diagnostic data and the tracking services (DiagTrack, WAP push).'; Reg = @(
            'SOFTWARE\Policies\Microsoft\Windows\DataCollection|AllowTelemetry|0',
            'SYSTEM\ControlSet001\Services\DiagTrack|Start|4', 'SYSTEM\ControlSet001\Services\dmwappushservice|Start|4') }
    adscopilot   = @{ Group = 'Privacy'; Label = 'Disable ads, tips and Copilot'
        Desc = 'Turns off Copilot, Start menu recommendations, suggested apps, tips, silently installed apps and the "Let''s finish setting up" nag.'; Reg = @(
            'DEFAULT\Software\Microsoft\Windows\CurrentVersion\UserProfileEngagement|ScoobeSystemSettingEnabled|0',
            'SOFTWARE\Policies\Microsoft\Windows\CloudContent|DisableWindowsConsumerFeatures|1',
            'SOFTWARE\Policies\Microsoft\Windows\WindowsCopilot|TurnOffWindowsCopilot|1',
            'DEFAULT\Software\Policies\Microsoft\Windows\WindowsCopilot|TurnOffWindowsCopilot|1',
            'DEFAULT\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced|Start_IrisRecommendations|0') + $CdmOff }
    activity     = @{ Group = 'Privacy'; Label = 'Disable activity history'
        Desc = 'Windows stops recording which apps and files you used and does not upload that history.'; Reg = @(
            'EnableActivityFeed', 'PublishUserActivities', 'UploadUserActivities' |
            ForEach-Object { "SOFTWARE\Policies\Microsoft\Windows\System|$_|0" }) }
    adid         = @{ Group = 'Privacy'; Label = 'Disable advertising ID'
        Desc = 'Apps cannot use an advertising ID to show you personalized ads.'; Reg = @(
            'SOFTWARE\Policies\Microsoft\Windows\AdvertisingInfo|DisabledByGroupPolicy|1') }
    noerrorrep   = @{ Group = 'Privacy'; Label = 'Disable error reporting'
        Desc = 'Crash reports are no longer sent to Microsoft.'; Reg = @(
            'SOFTWARE\Policies\Microsoft\Windows\Windows Error Reporting|Disabled|1') }
    nobing       = @{ Group = 'Privacy'; Label = 'No Bing in Start search'
        Desc = 'Start menu search only finds apps, files and settings on your PC, no web results.'; Reg = @(
            'DEFAULT\Software\Policies\Microsoft\Windows\Explorer|DisableSearchBoxSuggestions|1') }
    notyping     = @{ Group = 'Privacy'; Label = 'Disable typing/inking data'
        Desc = 'Windows stops collecting what you type and write to "improve" suggestions and does not harvest your contacts.'; Reg = @(
            'SOFTWARE\Policies\Microsoft\InputPersonalization|AllowInputPersonalization|0',
            'DEFAULT\Software\Microsoft\InputPersonalization|RestrictImplicitInkCollection|1',
            'DEFAULT\Software\Microsoft\InputPersonalization|RestrictImplicitTextCollection|1',
            'DEFAULT\Software\Microsoft\InputPersonalization\TrainedDataStore|HarvestContacts|0') }
    notailored   = @{ Group = 'Privacy'; Label = 'Disable tailored experiences'
        Desc = 'Microsoft no longer uses your diagnostic data for personalized tips, ads and recommendations.'; Reg = @(
            'DEFAULT\Software\Policies\Microsoft\Windows\CloudContent|DisableTailoredExperiencesWithDiagnosticData|1',
            'DEFAULT\Software\Microsoft\Windows\CurrentVersion\Privacy|TailoredExperiencesWithDiagnosticDataEnabled|0') }

    taskbarleft  = @{ Group = 'Taskbar & Start'; Label = 'Taskbar icons on the left'
        Desc = 'Start button and taskbar icons on the left like Windows 10, instead of centered.'; Reg = @(
            'DEFAULT\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced|TaskbarAl|0') }
    endtask      = @{ Group = 'Taskbar & Start'; Label = '"End task" in taskbar menu'
        Desc = 'Right-click a frozen app on the taskbar and choose End task, no Task Manager needed.'; Reg = @(
            'DEFAULT\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced\TaskbarDeveloperSettings|TaskbarEndTask|1') }
    nosearchbox  = @{ Group = 'Taskbar & Start'; Label = 'Hide taskbar search box'
        Desc = 'Removes the search box from the taskbar. Press Start and type to search as usual.'; Reg = @(
            'DEFAULT\Software\Microsoft\Windows\CurrentVersion\Search|SearchboxTaskbarMode|0') }
    notaskview   = @{ Group = 'Taskbar & Start'; Label = 'Hide Task View button'
        Desc = 'Removes the Task View button from the taskbar. Win+Tab still works.'; Reg = @(
            'DEFAULT\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced|ShowTaskViewButton|0') }
    nowidgets    = @{ Group = 'Taskbar & Start'; Label = 'Disable widgets'
        Desc = 'Removes the news and weather widgets board from the taskbar.'; Reg = @(
            'SOFTWARE\Policies\Microsoft\Dsh|AllowNewsAndInterests|0') }
    startpins    = @{ Group = 'Taskbar & Start'; Label = 'More pins in Start'
        Desc = 'Start menu shows an extra row of pinned apps and fewer recommendations.'; Reg = @(
            'DEFAULT\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced|Start_Layout|1') }
    clockseconds = @{ Group = 'Taskbar & Start'; Label = 'Seconds in the taskbar clock'
        Desc = 'The clock shows seconds, e.g. 14:05:37. Uses a tiny bit more power on laptops.'; Reg = @(
            'DEFAULT\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced|ShowSecondsInSystemClock|1') }

    classicmenu  = @{ Group = 'Explorer'; Label = 'Classic right-click menu'
        Desc = 'The full Windows 10 style context menu, without clicking "Show more options".'; Reg = @(
            'DEFAULT\Software\Classes\CLSID\{86ca1aa0-34aa-4e8b-a509-50c905bae2a2}\InprocServer32|@|') }
    fileext      = @{ Group = 'Explorer'; Label = 'Show file extensions'
        Desc = 'Shows .exe, .pdf, .jpg and so on in Explorer. Makes fake files like "photo.jpg.exe" easy to spot.'; Reg = @(
            'DEFAULT\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced|HideFileExt|0') }
    hiddenfiles  = @{ Group = 'Explorer'; Label = 'Show hidden files'
        Desc = 'Explorer shows hidden files and folders like AppData.'; Reg = @(
            'DEFAULT\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced|Hidden|1') }
    thispc       = @{ Group = 'Explorer'; Label = 'Explorer opens "This PC"'
        Desc = 'Explorer starts on your drives instead of Home.'; Reg = @(
            'DEFAULT\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced|LaunchTo|1') }
    compactview  = @{ Group = 'Explorer'; Label = 'Compact view'
        Desc = 'Less space between files and folders, like Windows 10. More fits on the screen.'; Reg = @(
            'DEFAULT\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced|UseCompactMode|1') }
    nogallery    = @{ Group = 'Explorer'; Label = 'Hide Gallery'
        Desc = 'Removes the Gallery entry from the Explorer sidebar. Your pictures stay in the Pictures folder.'; Reg = @(
            'DEFAULT\Software\Classes\CLSID\{e88865ea-0e1c-4e20-9aa6-edcd0212c87c}|System.IsPinnedToNameSpaceTree|0') }

    darkmode     = @{ Group = 'System'; Label = 'Dark mode'
        Desc = 'Windows and apps use the dark theme from the first login.'; Reg = @(
            'DEFAULT\Software\Microsoft\Windows\CurrentVersion\Themes\Personalize|AppsUseLightTheme|0',
            'DEFAULT\Software\Microsoft\Windows\CurrentVersion\Themes\Personalize|SystemUsesLightTheme|0') }
    nofaststart  = @{ Group = 'System'; Label = 'Disable Fast Startup'
        Desc = 'Shut down really shuts down. Fixes driver glitches and dual-boot problems; boot is a few seconds slower.'; Reg = @(
            'SYSTEM\ControlSet001\Control\Session Manager\Power|HiberbootEnabled|0') }
    nohibernate  = @{ Group = 'System'; Label = 'Disable hibernation'
        Desc = 'No hiberfil.sys, which frees several GB on the system drive. Also turns off Fast Startup. Sleep still works.'; Reg = @(
            'SYSTEM\ControlSet001\Control\Power|HibernateEnabled|0',
            'SYSTEM\ControlSet001\Control\Power|HibernateEnabledDefault|0') }
    longpaths    = @{ Group = 'System'; Label = 'Allow long file paths'
        Desc = 'Removes the old 260 character limit for file paths. Helps with deep folders, games mods and dev tools.'; Reg = @(
            'SYSTEM\ControlSet001\Control\FileSystem|LongPathsEnabled|1') }
    # Same as CTT WinUtil "Services - Set to Manual". CTT sets the svchost threshold to the PC's RAM;
    # the RAM isn't known offline, so the max value gives the same result on any PC (services stay grouped).
    services     = @{ Group = 'System'; Label = 'Services to manual (CTT)'
        Desc = 'Like CTT WinUtil: Maps and Storage Service start only when needed; Offline Files, telemetry and Internet Connection Sharing are off; fewer svchost processes. Mobile hotspot stops working.'; Reg = @(
            'MapsBroker', 'StorSvc' | ForEach-Object { "SYSTEM\ControlSet001\Services\$_|Start|3" }) + @(
            'CscService', 'DiagTrack', 'SharedAccess' | ForEach-Object { "SYSTEM\ControlSet001\Services\$_|Start|4" }) + @(
            'SYSTEM\ControlSet001\Control|SvcHostSplitThresholdInKB|4294967295') }

    nop2p        = @{ Group = 'Updates'; Label = 'No update sharing (P2P)'
        Desc = 'Windows Update downloads only from Microsoft and does not upload updates to other PCs.'; Reg = @(
            'SOFTWARE\Policies\Microsoft\Windows\DeliveryOptimization|DODownloadMode|0') }
    nodriverupdates = @{ Group = 'Updates'; Label = 'No driver updates'
        Desc = 'Windows Update no longer replaces your drivers, e.g. a newer GPU driver from NVIDIA or AMD. Install drivers yourself.'; Reg = @(
            'SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate|ExcludeWUDriversInQualityUpdate|1') }
    noautoreboot = @{ Group = 'Updates'; Label = 'No automatic restart'
        Desc = 'Windows does not restart by itself for updates while you are logged in, e.g. during a game or download.'; Reg = @(
            'SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate\AU|NoAutoRebootWithLoggedOnUsers|1') }

    gamedvr      = @{ Group = 'Gaming'; Label = 'Disable background recording'
        Desc = 'Stops Game DVR from recording gameplay in the background (saves FPS). Game Bar itself stays.'; Reg = @(
            'DEFAULT\System\GameConfigStore|GameDVR_Enabled|0',
            'DEFAULT\Software\Microsoft\Windows\CurrentVersion\GameDVR|AppCaptureEnabled|0') }
    hags         = @{ Group = 'Gaming'; Label = 'Hardware GPU scheduling'
        Desc = 'Lets the graphics card manage its own memory. Can lower input lag; needs a newer GPU and driver.'; Reg = @(
            'SYSTEM\ControlSet001\Control\GraphicsDrivers|HwSchMode|2') }
    nothrottle   = @{ Group = 'Gaming'; Label = 'Disable power throttling'
        Desc = 'Windows no longer slows down background apps to save power. Uses more battery on laptops.'; Reg = @(
            'SYSTEM\ControlSet001\Control\Power\PowerThrottling|PowerThrottlingOff|1') }
    gamepriority = @{ Group = 'Gaming'; Label = 'Game network/CPU priority'
        Desc = 'Removes network throttling for media apps and gives games more CPU time.'; Reg = @(
            'SOFTWARE\Microsoft\Windows NT\CurrentVersion\Multimedia\SystemProfile|NetworkThrottlingIndex|4294967295',
            'SOFTWARE\Microsoft\Windows NT\CurrentVersion\Multimedia\SystemProfile|SystemResponsiveness|10') }
    mouseaccel   = @{ Group = 'Gaming'; Label = 'Disable mouse acceleration'
        Desc = 'Turns off "Enhance pointer precision": the cursor moves exactly as far as your mouse, better for aiming.'; Reg = @(
            'MouseSpeed', 'MouseThreshold1', 'MouseThreshold2' | ForEach-Object { "DEFAULT\Control Panel\Mouse|$_|sz:0" }) }
    stickykeys   = @{ Group = 'Gaming'; Label = 'No Sticky Keys popup'
        Desc = 'Pressing Shift five times in a game no longer opens the Sticky Keys question.'; Reg = @(
            'DEFAULT\Control Panel\Accessibility\StickyKeys|Flags|sz:506') }

    edge         = @{ Group = 'Aggressive'; Label = 'Remove Edge (keeps WebView2)'
        Desc = 'Deletes Microsoft Edge. WebView2 stays so apps keep working. You need another browser; Windows Update may bring Edge back.'; Reg = @(
            'SOFTWARE\Policies\Microsoft\EdgeUpdate|DoNotUpdateToEdgeWithChromium|1')
        Action = { param($m, $c) 'Edge', 'EdgeUpdate', 'EdgeCore' | ForEach-Object { Remove-ImagePath "$m\Program Files (x86)\Microsoft\$_" } } }
    defender     = @{ Group = 'Aggressive'; Label = 'Disable Defender'
        Desc = 'Turns off Microsoft Defender antivirus completely. Only use this with another antivirus.'; Reg = @(
            'WinDefend', 'WdNisSvc', 'WdFilter', 'WdBoot', 'Sense' | ForEach-Object { "SYSTEM\ControlSet001\Services\$_|Start|4" }) + @(
            'SOFTWARE\Policies\Microsoft\Windows Defender|DisableAntiSpyware|1') + (
            'DisableRealtimeMonitoring', 'DisableBehaviorMonitoring', 'DisableOnAccessProtection', 'DisableScanOnRealtimeEnable' |
            ForEach-Object { "SOFTWARE\Policies\Microsoft\Windows Defender\Real-Time Protection|$_|1" }) }
    recall       = @{ Group = 'Aggressive'; Label = 'Disable Recall/AI'
        Desc = 'Removes Recall (screenshots of your activity) and turns off AI data analysis.'; Reg = @(
            'SOFTWARE\Policies\Microsoft\Windows\WindowsAI|DisableAIDataAnalysis|1')
        Action = { param($m, $c)
            if (Get-WindowsOptionalFeature -Path $m | Where-Object FeatureName -eq 'Recall') {
                Disable-WindowsOptionalFeature -Path $m -FeatureName Recall -Remove | Out-Null } } }

    drivers      = @{ Group = 'Extras'; Label = 'Add drivers from folder'
        Desc = 'Adds every driver in the folder below, e.g. network or storage drivers setup does not have.'
        Action = { param($m, $c) Add-WindowsDriver -Path $m -Driver $c.DriversPath -Recurse | Out-Null } }
    winutil      = @{ Group = 'Extras'; Label = 'CTT WinUtil shortcut on desktop'
        Desc = 'Puts a Chris Titus Tech WinUtil shortcut on the desktop for more tweaks after setup.'
        Action = { param($m, $c)
            $lnk = "$m\Users\Public\Desktop\CTT WinUtil.lnk"
            New-Item -ItemType Directory -Force (Split-Path $lnk) | Out-Null
            $s = (New-Object -ComObject WScript.Shell).CreateShortcut($lnk)
            $s.TargetPath = 'C:\Windows\System32\WindowsPowerShell\v1.0\powershell.exe'
            $s.Arguments = '-NoProfile -ExecutionPolicy Bypass -Command "irm christitus.com/win | iex"'
            $s.Save() } }
}

# The UI tweaks CTT WinUtil applies (formerly the whole 'Tweaks' group).
$CttTweaks = 'classicmenu', 'taskbarleft', 'fileext', 'endtask', 'nobing', 'nowidgets', 'darkmode', 'hiddenfiles', 'thispc', 'nosearchbox', 'notaskview', 'nofaststart'
$Presets = [ordered]@{
    Basic       = @{ Patches = 'hwchecks', 'localaccount', 'skipprivacy', 'nobitlocker' }
    Recommended = @{ Patches = @('hwchecks', 'localaccount', 'skipprivacy', 'nobitlocker', 'bloatapps', 'telemetry', 'adscopilot', 'onedrive', 'activity', 'adid', 'nop2p', 'fileext', 'endtask', 'nobing', 'gamedvr', 'notyping', 'notailored', 'noautoreboot') }
    CTT         = @{ Patches = @('hwchecks', 'localaccount', 'skipprivacy', 'nobitlocker', 'bloatapps', 'telemetry', 'adscopilot', 'onedrive', 'services', 'winutil') + $CttTweaks
        Unattend = @{ Enabled = $true; SkipOobe = $true; RunWinUtil = $true } }
    Extreme     = @{ Patches = @($Patches.Keys | Where-Object { $_ -ne 'drivers' })
        Unattend = @{ Enabled = $true; SkipOobe = $true; RunWinUtil = $true } }
}

# Preset file (Save/Load in the top bar): an allowlist of choices, so no password, product key or PC-specific paths.
function Get-PresetData($Cfg) {
    $p = [ordered]@{}
    foreach ($k in 'BaseLang', 'Editions', 'Patches', 'UseUup', 'Newest', 'Fast', 'Split', 'QuickCompress', 'DefenderExclude') { $p[$k] = $Cfg[$k] }
    $u = [ordered]@{}
    foreach ($k in 'Enabled', 'UserName', 'AutoLogon', 'Admin', 'ComputerName', 'TimeZone', 'Keyboard', 'Locale', 'SkipOobe', 'Edition', 'AutoInstall', 'RunWinUtil', 'EnableAdmin', 'Apps', 'WifiName') { $u[$k] = $Cfg.Unattend[$k] }
    $p.Unattend = $u; $p
}

function Test-ProtectedApp($Name) { [bool]($ProtectedApps | Where-Object { $Name -like $_ }) }

# Names from $Wanted that are provisioned and not protected.
function Get-AppsToRemove([string[]]$Provisioned, [string[]]$Wanted) {
    @($Wanted | Where-Object { $_ -in $Provisioned -and -not (Test-ProtectedApp $_) })
}

function Convert-RegPath($Path) {
    $hive, $rest = $Path -split '\\', 2
    "HKLM\WIM_$hive\$rest"
}

function Remove-Apps($Mount, [string[]]$Wanted) {
    $prov = Get-AppxProvisionedPackage -Path $Mount
    foreach ($w in $Wanted | Where-Object { Test-ProtectedApp $_ }) { Write-Log "  skip protected app $w" }
    foreach ($name in Get-AppsToRemove $prov.DisplayName $Wanted) {
        $prov | Where-Object DisplayName -eq $name | ForEach-Object {
            Write-Log "  remove app $name"
            Remove-AppxProvisionedPackage -Path $Mount -PackageName $_.PackageName | Out-Null
            if ($script:Report) { $script:Report.Apps++ }
        }
    }
}

function Remove-ImagePath($Path) {
    $ErrorActionPreference = 'Continue'   # native tools below write to stderr
    if (-not (Test-Path $Path)) { return }
    # takeown /r only accepts folders; on a file it fails and the delete is then denied.
    # The /d answer is localized (y, German j, French o, Spanish/Italian s): retry while it is rejected as a bad value.
    foreach ($yes in 'y', 'j', 'o', 's') {
        $own = if (Test-Path $Path -PathType Container) { @('/r', '/d', $yes) } else { @() }
        $out = takeown /f $Path @own /a 2>&1
        if (-not $LASTEXITCODE -or -not $own -or "$out" -notmatch "'$yes'") { break }
    }
    if ($LASTEXITCODE) { Write-Log "  WARN takeown failed for ${Path}: $out" }
    icacls $Path /grant '*S-1-5-32-544:F' /t /c /q 2>&1 | Out-Null
    # Leftover files are not worth failing a whole build over: warn and continue.
    try { Remove-Item $Path -Recurse -Force -ErrorAction Stop; Write-Log "  deleted $Path" }
    catch { Write-Log "  WARN could not delete ${Path}: $($_.Exception.Message)" }
}

# Native tools: Windows PowerShell 5.1 turns their stderr into terminating errors under
# ErrorActionPreference=Stop, so these helpers use Continue locally and check exit codes.
function Mount-Hive($Name, $File) {
    $ErrorActionPreference = 'Continue'
    reg load "HKLM\WIM_$Name" $File 2>&1 | Out-Null
    if ($LASTEXITCODE) { throw "reg load $Name failed ($File)" }
}

function Mount-Hives($Mount) {
    Mount-Hive SYSTEM "$Mount\Windows\System32\config\SYSTEM"
    Mount-Hive SOFTWARE "$Mount\Windows\System32\config\SOFTWARE"
    Mount-Hive DEFAULT "$Mount\Users\Default\NTUSER.DAT"
}

function Dismount-Hives {
    $ErrorActionPreference = 'Continue'   # unloading a hive that is not loaded is fine
    [gc]::Collect()
    foreach ($h in 'SYSTEM', 'SOFTWARE', 'DEFAULT') { reg unload "HKLM\WIM_$h" 2>&1 | Out-Null }
}

function Set-OfflineReg([string[]]$Entries) {
    $ErrorActionPreference = 'Continue'
    foreach ($e in $Entries) {
        $path, $name, $value = $e -split '\|'
        $key = Convert-RegPath $path
        if ($value -eq '-') { reg delete $key /v $name /f 2>&1 | Out-Null; Write-Log "  reg delete $path\$name" }
        elseif ($name -eq '@') { reg add $key /ve /f 2>&1 | Out-Null; if ($LASTEXITCODE) { throw "reg add failed: $e" }; Write-Log "  reg $path\(Default) = (empty)" }   # empty default value
        else {
            $type, $data = if ($value -like 'sz:*') { 'REG_SZ', $value.Substring(3) } else { 'REG_DWORD', $value }
            reg add $key /v $name /t $type /d $data /f 2>&1 | Out-Null; if ($LASTEXITCODE) { throw "reg add failed: $e" }; Write-Log "  reg $path\$name = $value"
        }
        if ($script:Report) { $script:Report.Reg++ }
    }
}

# Order inside an edition: app removal -> registry -> files/drivers.
# Registry entries of the selected patches. Patches without Reg must not add empty entries.
function Get-PatchReg([string[]]$Ids) { @($Ids | ForEach-Object { $Patches[$_].Reg } | Where-Object { $_ }) }

function Invoke-Patches($Mount, [string[]]$Ids, $Cfg) {
    foreach ($id in 'bloatapps', 'xboxapp' | Where-Object { $_ -in $Ids }) { Write-Log " patch $id - $($Patches[$id].Label)"; & $Patches[$id].Action $Mount $Cfg }
    Write-Log " registry: $(($Ids | Where-Object { $Patches[$_].Reg }) -join ', ')"
    Mount-Hives $Mount
    try { Set-OfflineReg (Get-PatchReg $Ids) } finally { Dismount-Hives }
    foreach ($id in $Ids | Where-Object { $_ -notin 'bloatapps', 'xboxapp' -and $Patches[$_].Action }) {
        Write-Log " patch $id - $($Patches[$id].Label)"; & $Patches[$id].Action $Mount $Cfg
    }
}

# boot.wim only gets the hardware-check bypass (SYSTEM hive only).
function Set-BootPatches($Mount) {
    Mount-Hive SYSTEM "$Mount\Windows\System32\config\SYSTEM"
    try { Set-OfflineReg ($Patches.hwchecks.Reg) } finally { Dismount-Hives }
}
