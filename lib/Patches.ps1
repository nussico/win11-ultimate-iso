# Patch catalog, app lists and presets.
# Reg entries: 'HIVE\Key|Name|Value'  (HIVE = SYSTEM, SOFTWARE or DEFAULT; Value '-' deletes the value)

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
    hwchecks     = @{ Group = 'Setup bypasses'; Label = 'Skip TPM/SecureBoot/RAM/CPU checks'; Boot = $true; Reg = @(
            'SYSTEM\Setup\LabConfig|BypassTPMCheck|1', 'SYSTEM\Setup\LabConfig|BypassSecureBootCheck|1',
            'SYSTEM\Setup\LabConfig|BypassRAMCheck|1', 'SYSTEM\Setup\LabConfig|BypassCPUCheck|1',
            'SYSTEM\Setup\LabConfig|BypassStorageCheck|1', 'SYSTEM\Setup\MoSetup|AllowUpgradesWithUnsupportedTPMOrCPU|1') }
    localaccount = @{ Group = 'Setup bypasses'; Label = 'Local account (BypassNRO)'; Reg = @(
            'SOFTWARE\Microsoft\Windows\CurrentVersion\OOBE|BypassNRO|1') }
    skipprivacy  = @{ Group = 'Setup bypasses'; Label = 'Skip privacy screens'; Reg = @(
            'SOFTWARE\Policies\Microsoft\Windows\OOBE|DisablePrivacyExperience|1') }
    nobitlocker  = @{ Group = 'Setup bypasses'; Label = 'No automatic BitLocker'; Reg = @(
            'SYSTEM\ControlSet001\Control\BitLocker|PreventDeviceEncryption|1') }

    bloatapps    = @{ Group = 'Debloat'; Label = 'Remove bloat apps'; Action = { param($m, $c) Remove-Apps $m $RemoveApps } }
    xboxapp      = @{ Group = 'Debloat'; Label = 'Remove Xbox app'; Action = { param($m, $c) Remove-Apps $m @('Microsoft.GamingApp') } }
    telemetry    = @{ Group = 'Debloat'; Label = 'Disable telemetry'; Reg = @(
            'SOFTWARE\Policies\Microsoft\Windows\DataCollection|AllowTelemetry|0',
            'SYSTEM\ControlSet001\Services\DiagTrack|Start|4', 'SYSTEM\ControlSet001\Services\dmwappushservice|Start|4') }
    adscopilot   = @{ Group = 'Debloat'; Label = 'Disable ads, tips and Copilot'; Reg = @(
            'SOFTWARE\Policies\Microsoft\Windows\CloudContent|DisableWindowsConsumerFeatures|1',
            'SOFTWARE\Policies\Microsoft\Windows\WindowsCopilot|TurnOffWindowsCopilot|1',
            'DEFAULT\Software\Policies\Microsoft\Windows\WindowsCopilot|TurnOffWindowsCopilot|1',
            'DEFAULT\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced|Start_IrisRecommendations|0') + $CdmOff }
    onedrive     = @{ Group = 'Debloat'; Label = 'Remove OneDrive'; Reg = @(
            'DEFAULT\Software\Microsoft\Windows\CurrentVersion\Run|OneDriveSetup|-')
        Action = { param($m, $c) Remove-ImagePath "$m\Windows\System32\OneDriveSetup.exe" } }

    edge         = @{ Group = 'Aggressive'; Label = 'Remove Edge (keeps WebView2)'; Reg = @(
            'SOFTWARE\Policies\Microsoft\EdgeUpdate|DoNotUpdateToEdgeWithChromium|1')
        Action = { param($m, $c) 'Edge', 'EdgeUpdate', 'EdgeCore' | ForEach-Object { Remove-ImagePath "$m\Program Files (x86)\Microsoft\$_" } } }
    defender     = @{ Group = 'Aggressive'; Label = 'Disable Defender'; Reg = @(
            'WinDefend', 'WdNisSvc', 'WdFilter', 'WdBoot', 'Sense' | ForEach-Object { "SYSTEM\ControlSet001\Services\$_|Start|4" }) + @(
            'SOFTWARE\Policies\Microsoft\Windows Defender|DisableAntiSpyware|1') + (
            'DisableRealtimeMonitoring', 'DisableBehaviorMonitoring', 'DisableOnAccessProtection', 'DisableScanOnRealtimeEnable' |
            ForEach-Object { "SOFTWARE\Policies\Microsoft\Windows Defender\Real-Time Protection|$_|1" }) }
    recall       = @{ Group = 'Aggressive'; Label = 'Disable Recall/AI'; Reg = @(
            'SOFTWARE\Policies\Microsoft\Windows\WindowsAI|DisableAIDataAnalysis|1')
        Action = { param($m, $c)
            if (Get-WindowsOptionalFeature -Path $m | Where-Object FeatureName -eq 'Recall') {
                Disable-WindowsOptionalFeature -Path $m -FeatureName Recall -Remove | Out-Null } } }

    drivers      = @{ Group = 'Extras'; Label = 'Add drivers from folder'
        Action = { param($m, $c) Add-WindowsDriver -Path $m -Driver $c.DriversPath -Recurse | Out-Null } }
    winutil      = @{ Group = 'Extras'; Label = 'CTT WinUtil shortcut on desktop'
        Action = { param($m, $c)
            $lnk = "$m\Users\Public\Desktop\CTT WinUtil.lnk"
            New-Item -ItemType Directory -Force (Split-Path $lnk) | Out-Null
            $s = (New-Object -ComObject WScript.Shell).CreateShortcut($lnk)
            $s.TargetPath = 'C:\Windows\System32\WindowsPowerShell\v1.0\powershell.exe'
            $s.Arguments = '-NoProfile -ExecutionPolicy Bypass -Command "irm christitus.com/win | iex"'
            $s.Save() } }
}

$Presets = [ordered]@{
    Basic       = @{ Patches = 'hwchecks', 'localaccount', 'skipprivacy', 'nobitlocker' }
    Recommended = @{ Patches = 'hwchecks', 'localaccount', 'skipprivacy', 'nobitlocker', 'bloatapps', 'telemetry', 'adscopilot', 'onedrive' }
    CTT         = @{ Patches = 'hwchecks', 'localaccount', 'skipprivacy', 'nobitlocker', 'bloatapps', 'telemetry', 'adscopilot', 'onedrive', 'winutil'
        Unattend = @{ Enabled = $true; SkipOobe = $true; RunWinUtil = $true } }
    Extreme     = @{ Patches = @($Patches.Keys | Where-Object { $_ -ne 'drivers' })
        Unattend = @{ Enabled = $true; SkipOobe = $true; RunWinUtil = $true } }
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
    takeown /f $Path /r /d y /a 2>&1 | Out-Null
    icacls $Path /grant '*S-1-5-32-544:F' /t /c /q 2>&1 | Out-Null
    Remove-Item $Path -Recurse -Force -ErrorAction Stop
    Write-Log "  deleted $Path"
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
        else { reg add $key /v $name /t REG_DWORD /d $value /f 2>&1 | Out-Null; if ($LASTEXITCODE) { throw "reg add failed: $e" }; Write-Log "  reg $path\$name = $value" }
        if ($script:Report) { $script:Report.Reg++ }
    }
}

# Order inside an edition: app removal -> registry -> files/drivers (LPs are added before this by Build).
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
