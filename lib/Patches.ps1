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
        # Not the AllowNewsAndInterests policy: Windows denies writing Policies\Microsoft\Dsh even to an offline image.
        Desc = 'Removes the news and weather widgets board (Windows Web Experience Pack). The Store can bring it back.'
        Action = { param($m, $c) Remove-Apps $m @('MicrosoftWindows.Client.WebExperience') } }
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
    noreserve    = @{ Group = 'System'; Label = 'No reserved storage'
        Desc = 'Windows no longer keeps about 7 GB of the system drive free for updates. Updates still work; with a nearly full drive they may need space freed first.'; Reg = @(
            'SOFTWARE\Microsoft\Windows\CurrentVersion\ReserveManager|ShippedWithReserves|0') }
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
    pinversion   = @{ Group = 'Updates'; Label = 'Stay on this Windows version'
        Desc = 'Windows Update keeps installing security updates but never moves to the next version (e.g. 25H2 to 26H2). Delete the TargetReleaseVersion policy later to upgrade.'
        Action = { param($m, $c)
            # The release the build was made from; the image's own DisplayVersion is older in Fast-mode UUP ISOs.
            $v = $c.ReleaseVersion
            if (-not $Online) { Mount-Hive SOFTWARE "$m\Windows\System32\config\SOFTWARE" }
            try {
                if (-not $v) { $v = Get-ItemPropertyValue "Registry::$(Convert-RegPath 'SOFTWARE\Microsoft\Windows NT\CurrentVersion')" DisplayVersion }
                if ($v -notmatch '^\d\dH\d$') { Write-Log "  WARN version not pinned: unknown version '$v'"; return }
                Write-Log "  pin Windows version $v"
                Set-OfflineReg ('TargetReleaseVersion|1', 'ProductVersion|sz:Windows 11', "TargetReleaseVersionInfo|sz:$v" |
                    ForEach-Object { "SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate|$_" })
            } finally { if (-not $Online) { Dismount-Hives } } } }

    wsl          = @{ Group = 'Features'; Label = 'WSL (Linux)'
        Desc = 'Turns on the Windows features WSL needs. After setup run "wsl --install" to get Ubuntu or another Linux.'
        Action = { param($m, $c) Enable-ImageFeature $m 'Microsoft-Windows-Subsystem-Linux', 'VirtualMachinePlatform' } }
    hyperv       = @{ Group = 'Features'; Label = 'Hyper-V'
        Desc = 'Virtual machines built into Windows. Pro, Education and Enterprise only; Home is skipped. Some other VM apps and anti-cheats run slower with it.'
        Action = { param($m, $c) Enable-ImageFeature $m 'Microsoft-Hyper-V-All' } }
    sandbox      = @{ Group = 'Features'; Label = 'Windows Sandbox'
        Desc = 'A throwaway Windows window for testing unknown programs; everything is gone when you close it. Pro, Education and Enterprise only.'
        Action = { param($m, $c) Enable-ImageFeature $m 'Containers-DisposableClientVM' } }
    netfx3       = @{ Group = 'Features'; Label = '.NET Framework 3.5'
        Desc = 'Older programs and games need it. Installed from the ISO, so no download after setup.'
        Action = { param($m, $c) Enable-ImageFeature $m 'NetFx3' $(if ($c.SxsPath) { $c.SxsPath } else { "$(Split-Path $m)\iso\sources\sxs" }) } }

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
            $ia = Get-ImageArg $m
            if (Get-WindowsOptionalFeature @ia | Where-Object FeatureName -eq 'Recall') {
                Disable-WindowsOptionalFeature @ia -FeatureName Recall -Remove -NoRestart | Out-Null } } }

    drivers      = @{ Group = 'Extras'; Label = 'Add drivers from folder'
        Desc = 'Adds every driver in the folder below, e.g. network or storage drivers setup does not have.'
        Action = { param($m, $c)
            if ($Online) { $ErrorActionPreference = 'Continue'; pnputil /add-driver "$($c.DriversPath)\*.inf" /subdirs /install 2>&1 | Out-Null; Write-Log "  pnputil exit $LASTEXITCODE" }
            else { Add-WindowsDriver -Path $m -Driver $c.DriversPath -Recurse | Out-Null } } }
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
    # Everything that removes or disables; not the opt-in extras, features or the version pin.
    Extreme     = @{ Patches = @($Patches.Keys | Where-Object { $_ -ne 'drivers' -and $_ -ne 'pinversion' -and $Patches[$_].Group -ne 'Features' })
        Unattend = @{ Enabled = $true; SkipOobe = $true; RunWinUtil = $true } }
}

# Preset file (Save/Load in the top bar): an allowlist of choices, so no password, product key or PC-specific paths.
function Get-PresetData($Cfg) {
    $p = [ordered]@{}
    foreach ($k in 'BaseLang', 'Editions', 'Patches', 'PatchMode', 'UseUup', 'Download', 'Newest', 'Split', 'QuickCompress', 'SmallIso', 'DefenderExclude') { $p[$k] = $Cfg[$k] }
    $u = [ordered]@{}
    foreach ($k in 'Enabled', 'UserName', 'AutoLogon', 'Admin', 'ComputerName', 'TimeZone', 'Keyboard', 'Locale', 'SkipOobe', 'Edition', 'AutoInstall', 'RunWinUtil', 'EnableAdmin', 'Apps', 'WifiName') { $u[$k] = $Cfg.Unattend[$k] }
    $p.Unattend = $u; $p
}

function Test-ProtectedApp($Name) { [bool]($ProtectedApps | Where-Object { $Name -like $_ }) }

# Names from $Wanted that are provisioned and not protected.
function Get-AppsToRemove([string[]]$Provisioned, [string[]]$Wanted) {
    @($Wanted | Where-Object { $_ -in $Provisioned -and -not (Test-ProtectedApp $_) })
}

# Where patches write. In the build: an offline image, hives loaded as HKLM\WIM_SYSTEM etc. During Windows Setup
# ($Online, set by New-SetupPatchScript): the running system, only the default user's hive is loaded.
$Online = $false

function Convert-RegPath($Path) {
    $hive, $rest = $Path -split '\\', 2
    if ($Online -and $hive -ne 'DEFAULT') { "HKLM\$hive\$rest" } else { "HKLM\WIM_$hive\$rest" }
}

# DISM cmdlet target: the mounted image or the running Windows.
function Get-ImageArg($Mount) { if ($Online) { @{ Online = $true } } else { @{ Path = $Mount } } }

function Remove-Apps($Mount, [string[]]$Wanted) {
    $ia = Get-ImageArg $Mount
    $prov = Get-AppxProvisionedPackage @ia
    foreach ($w in $Wanted | Where-Object { Test-ProtectedApp $_ }) { Write-Log "  skip protected app $w" }
    foreach ($name in Get-AppsToRemove $prov.DisplayName $Wanted) {
        $prov | Where-Object DisplayName -eq $name | ForEach-Object {
            Write-Log "  remove app $name"
            Remove-AppxProvisionedPackage @ia -PackageName $_.PackageName | Out-Null
            if ($script:Report) { $script:Report.Apps++ }
        }
    }
}

# Optional features the edition doesn't have (Hyper-V on Home) are skipped. A failed feature only warns: not worth a whole build.
function Enable-ImageFeature($Mount, [string[]]$Names, $Source) {
    $ia = Get-ImageArg $Mount
    # Asking DISM for the list takes ~10 s: once per image (Invoke-Patches resets it).
    if ($null -eq $script:FeatureNames) { $script:FeatureNames = @(Get-WindowsOptionalFeature @ia).FeatureName }
    $have = $script:FeatureNames
    foreach ($n in $Names) {
        if ($n -notin $have) { Write-Log "  skip feature $n (not in this edition)"; continue }
        $src = if ($Source) { @{ Source = $Source; LimitAccess = $true } } else { @{} }
        try { Enable-WindowsOptionalFeature @ia -FeatureName $n -All -NoRestart @src -ErrorAction Stop | Out-Null; Write-Log "  enable feature $n" }
        catch { Write-Log "  WARN could not enable ${n}: $($_.Exception.Message)" }
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
    if ($Online) { Mount-Hive DEFAULT "$Mount\Users\Default\NTUSER.DAT"; return }
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
        elseif ($name -eq '@') { $out = reg add $key /ve /f 2>&1; if ($LASTEXITCODE) { throw "reg add failed: $e ($out)" }; Write-Log "  reg $path\(Default) = (empty)" }   # empty default value
        else {
            $type, $data = if ($value -like 'sz:*') { 'REG_SZ', $value.Substring(3) } else { 'REG_DWORD', $value }
            $out = reg add $key /v $name /t $type /d $data /f 2>&1; if ($LASTEXITCODE) { throw "reg add failed: $e ($out)" }; Write-Log "  reg $path\$name = $value"
        }
        if ($script:Report) { $script:Report.Reg++ }
    }
}

# Order inside an edition: app removal -> registry -> files/drivers.
# Registry entries of the selected patches. Patches without Reg must not add empty entries.
function Get-PatchReg([string[]]$Ids) { @($Ids | ForEach-Object { $Patches[$_].Reg } | Where-Object { $_ }) }

function Invoke-Patches($Mount, [string[]]$Ids, $Cfg) {
    $script:FeatureNames = $null   # new image, other edition
    foreach ($id in 'bloatapps', 'xboxapp' | Where-Object { $_ -in $Ids }) { Write-Log " patch $id - $($Patches[$id].Label)"; & $Patches[$id].Action $Mount $Cfg }
    $regIds = @($Ids | Where-Object { $Patches[$_].Reg }); if ($regIds) { Write-Log " registry: $($regIds -join ', ')" }
    Mount-Hives $Mount
    try { Set-OfflineReg (Get-PatchReg $Ids) } finally { Dismount-Hives }
    foreach ($id in $Ids | Where-Object { $_ -notin 'bloatapps', 'xboxapp' -and $Patches[$_].Action }) {
        Write-Log " patch $id - $($Patches[$id].Label)"; & $Patches[$id].Action $Mount $Cfg
    }
}

# "During setup" mode: this script and Patches.ps1 go to C:\Windows\Setup\Scripts; autounattend.xml runs it in the
# specialize pass as SYSTEM, before OOBE and before any user profile exists, so it reaches every user like the image
# patches do. One failed patch only logs: Setup must never stop because of a tweak.
function New-SetupPatchScript([string[]]$Ids, $Cfg) {
    $q = { param($s) "'" + "$s".Replace("'", "''") + "'" }
    $ids = ($Ids | ForEach-Object { & $q $_ }) -join ', '
    @"
`$dir = 'C:\Windows\Setup\Scripts'
`$ProgressPreference = 'SilentlyContinue'
function Write-Log(`$Msg) { Add-Content "`$dir\Win11Ultimate-patches.log" ('[{0:HH:mm:ss}] {1}' -f (Get-Date), `$Msg) }
Write-Log 'Win11 Ultimate patches (during setup) started'
. "`$dir\Patches.ps1"
`$Online = `$true
`$ErrorActionPreference = 'Stop'
`$cfg = @{ ReleaseVersion = $(& $q $Cfg.ReleaseVersion); DriversPath = "`$dir\drivers"; SxsPath = "`$dir\sxs" }
foreach (`$id in @($ids)) {
    try { Invoke-Patches `$env:SystemDrive @(`$id) `$cfg } catch { Write-Log "  WARN `$id failed: `$_" }
}
Remove-Item "`$dir\sxs", "`$dir\drivers" -Recurse -Force -ErrorAction SilentlyContinue
Write-Log 'done'
"@
}

# boot.wim only gets the hardware-check bypass (SYSTEM hive only).
function Set-BootPatches($Mount) {
    Mount-Hive SYSTEM "$Mount\Windows\System32\config\SYSTEM"
    try { Set-OfflineReg ($Patches.hwchecks.Reg) } finally { Dismount-Hives }
}
