# Win11 Ultimate ISO Builder - GUI entry point (WPF).
# Always runs in elevated Windows PowerShell 5.1 (STA, needed by WPF).
$isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole('Administrators')
if (-not $isAdmin -or $PSVersionTable.PSEdition -ne 'Desktop') {
    # conhost --headless: no console window, even when Windows Terminal is the default terminal
    Start-Process conhost.exe -Verb RunAs -ArgumentList "--headless powershell.exe -NoProfile -ExecutionPolicy Bypass -STA -File `"$PSCommandPath`""
    exit
}

Add-Type -AssemblyName PresentationFramework, System.Windows.Forms
# There is no console window, so show startup errors instead of failing silently.
trap { [Windows.MessageBox]::Show("The builder could not start:`n`n$_`n`n$($_.InvocationInfo.PositionMessage)", 'Win11 Ultimate', 'OK', 'Error') | Out-Null; exit 1 }

$root = $PSScriptRoot
. "$root\lib\Patches.ps1"; . "$root\lib\Unattend.ps1"; . "$root\lib\Source.ps1"

$xaml = [xml](Get-Content "$root\lib\Window.xaml" -Raw)
$win = [Windows.Markup.XamlReader]::Load((New-Object Xml.XmlNodeReader $xaml))
$ui = @{}
$xaml.SelectNodes('//*[@*[local-name()="Name"]]') | ForEach-Object { $n = $_.GetAttribute('Name', 'http://schemas.microsoft.com/winfx/2006/xaml'); $ui[$n] = $win.FindName($n) }

function New-Check($Text, $Style, $Checked = $false) {
    $c = New-Object Windows.Controls.CheckBox
    $c.Content = $Text; $c.Style = $win.FindResource($Style); $c.IsChecked = $Checked; $c
}
function Select-Folder($Box) { $d = New-Object Windows.Forms.FolderBrowserDialog; if ($d.ShowDialog() -eq 'OK') { $Box.Text = $d.SelectedPath } }
function Show-Msg($Text, $Icon = 'Information', $Buttons = 'OK') { [Windows.MessageBox]::Show($win, $Text, 'Win11 Ultimate', $Buttons, $Icon) }

# --- Navigation ---
$ui.Nav.Add_SelectionChanged({
        foreach ($i in $ui.Nav.Items) { $ui[$i.Tag].Visibility = if ($i.IsSelected) { 'Visible' } else { 'Collapsed' } }
    })

# --- UUP data (best effort; offline still works with own ISOs) ---
$script:UupBuilds = @()
$langs = @('ar-sa', 'cs-cz', 'da-dk', 'de-de', 'en-gb', 'en-us', 'es-es', 'fr-fr', 'it-it', 'ja-jp', 'ko-kr', 'nl-nl', 'pl-pl', 'pt-br', 'ru-ru', 'sv-se', 'tr-tr', 'uk-ua', 'zh-cn')
try {
    $script:UupBuilds = Get-UupBuilds
    $langs = Get-UupLanguages (Select-NewestUupBuild $script:UupBuilds).uuid
} catch { }
$script:IsoInfos = @()
$buildList = @($script:UupBuilds | Where-Object title -like 'Windows 11, version*' | Sort-Object { [version]"10.0.$($_.build)" } -Descending | Select-Object -First 15)
$ui.Build.Items.Add('Auto - newest build matching your ISO') | Out-Null
foreach ($b in $buildList) { $ui.Build.Items.Add($b.title) | Out-Null }
$ui.Build.SelectedIndex = 0
$newestBuild = Select-NewestUupBuild $script:UupBuilds
if ($newestBuild) { $ui.NewestText.Text = "Newest available: $($newestBuild.title)" }

# --- Source / languages ---
$ui.IsoFolder.Text = "$root\sources"
$ui.BrowseIso.Add_Click({ Select-Folder $ui.IsoFolder })
foreach ($l in $langs) { $ui.BaseLang.Items.Add($l) | Out-Null; $ui.Keyboard.Items.Add($l) | Out-Null; $ui.Locale.Items.Add($l) | Out-Null }
$defLang = if ($langs -contains 'de-de') { 'de-de' } else { $langs[0] }
$ui.BaseLang.SelectedItem = $defLang; $ui.Keyboard.SelectedItem = $defLang; $ui.Locale.SelectedItem = $defLang
$langChecks = [ordered]@{}
foreach ($l in $langs) {
    $langChecks[$l] = New-Check $l 'Chip' ($l -eq 'en-us')
    try { $langChecks[$l].ToolTip = [Globalization.CultureInfo]::GetCultureInfo($l).DisplayName } catch { }
    $ui.LangPanel.Children.Add($langChecks[$l]) | Out-Null
}

# --- Editions ---
$defaultEditions = 'Windows 11 Home', 'Windows 11 Pro', 'Windows 11 Education'
$script:edChecks = [ordered]@{}
function Update-Editions {
    $checked = @($script:edChecks.Keys | Where-Object { $script:edChecks[$_].IsChecked })
    if (-not $script:edChecks.Count) { $checked = $defaultEditions }
    $iso = $script:IsoInfos | Where-Object Lang -eq $ui.BaseLang.SelectedItem | Select-Object -First 1
    $names = @($iso.Editions.Name | Where-Object { $_ })
    $all = @($names)
    if ($ui.UseUup.IsChecked) { $all += @($UupEditions.Keys | Where-Object { $_ -notin $names }) }
    $ui.EditionPanel.Children.Clear(); $script:edChecks = [ordered]@{}
    $prevEdition = $ui.Edition.SelectedItem
    $ui.Edition.Items.Clear()
    foreach ($e in $all) {
        $label = if ($e -in $names) { $e } else { "$e  (UUP)" }
        $script:edChecks[$e] = New-Check $label 'Chip' ($e -in $checked)
        $script:edChecks[$e].Add_Click({ Update-Summary })
        $ui.EditionPanel.Children.Add($script:edChecks[$e]) | Out-Null
        $ui.Edition.Items.Add($e) | Out-Null
    }
    $ui.Edition.SelectedItem = if ($prevEdition -in $all) { $prevEdition } else { 'Windows 11 Pro' }
    if (-not $all) { $ui.EditionPanel.Children.Add((New-Object Windows.Controls.TextBlock -Property @{ Text = 'No editions yet - scan your ISOs or turn on UUP dump.' })) | Out-Null }
    Update-Summary
}

# --- Patches ---
$patchChecks = @{}
foreach ($g in 'Setup bypasses', 'Debloat', 'Aggressive', 'Extras') {
    $card = New-Object Windows.Controls.Border -Property @{ Style = $win.FindResource('Card'); Margin = '0,0,14,14' }
    $sp = New-Object Windows.Controls.StackPanel
    $h = New-Object Windows.Controls.TextBlock -Property @{ Text = $g.ToUpper(); Style = $win.FindResource('Section') }
    if ($g -eq 'Aggressive') { $h.Foreground = $win.FindResource('Danger'); $h.Text = 'AGGRESSIVE - CAN BREAK APPS/UPDATES' }
    $sp.Children.Add($h) | Out-Null
    foreach ($id in $Patches.Keys | Where-Object { $Patches[$_].Group -eq $g }) {
        $patchChecks[$id] = New-Check $Patches[$id].Label 'Toggle'
        $sp.Children.Add($patchChecks[$id]) | Out-Null
    }
    $card.Child = $sp; $ui.PatchPanel.Children.Add($card) | Out-Null
}
$ui.BrowseDrivers.Add_Click({ Select-Folder $ui.DriversPath })

# --- Unattended ---
foreach ($tz in [TimeZoneInfo]::GetSystemTimeZones()) { $ui.TimeZone.Items.Add($tz.Id) | Out-Null }
$ui.TimeZone.SelectedItem = 'W. Europe Standard Time'
function Set-UnattendBody { $on = [bool]$ui.UnattendOn.IsChecked; $ui.UnattendBody.IsEnabled = $on; $ui.UnattendBody.Opacity = if ($on) { 1 } else { 0.4 } }
Set-UnattendBody
$ui.UnattendOn.Add_Checked({ Set-UnattendBody }); $ui.UnattendOn.Add_Unchecked({ Set-UnattendBody })
$ui.UnattendOn.Add_Click({ Update-Summary })
$ui.BrowseScript.Add_Click({
        $d = New-Object Windows.Forms.OpenFileDialog -Property @{ Filter = 'PowerShell (*.ps1)|*.ps1' }
        if ($d.ShowDialog() -eq 'OK') { $ui.CustomScript.Text = $d.FileName } })

# --- Build page ---
$ui.Output.Text = "$root\out\Win11.iso"
$ui.BrowseOut.Add_Click({
        $d = New-Object Windows.Forms.SaveFileDialog -Property @{ Filter = 'ISO (*.iso)|*.iso'; FileName = 'Win11.iso' }
        if ($d.ShowDialog() -eq 'OK') { $ui.Output.Text = $d.FileName } })

# --- Presets ---
foreach ($p in @($Presets.Keys) + 'Custom') { $ui.Preset.Items.Add($p) | Out-Null }
$script:applying = $false
function Set-Preset($Name) {
    if (-not $Presets.Contains($Name)) { return }
    $script:applying = $true
    $pr = $Presets[$Name]
    foreach ($id in $patchChecks.Keys) { $patchChecks[$id].IsChecked = $id -in $pr.Patches }
    $ui.SkipOobe.IsChecked = [bool]$pr.Unattend.SkipOobe
    $ui.RunWinUtil.IsChecked = [bool]$pr.Unattend.RunWinUtil
    if ($pr.Unattend.Enabled) { $ui.UnattendOn.IsChecked = $true }
    $script:applying = $false
    Update-Summary
}
function Update-Summary {
    $ed = @($script:edChecks.Keys | Where-Object { $script:edChecks[$_].IsChecked }).Count
    $lp = @($langChecks.Keys | Where-Object { $langChecks[$_].IsChecked -and $_ -ne $ui.BaseLang.SelectedItem }).Count
    $pa = @($patchChecks.Values | Where-Object IsChecked).Count
    $ui.Summary.Text = "$ed editions, $($ui.BaseLang.SelectedItem) + $lp language packs, $pa patches" + $(if ($ui.UnattendOn.IsChecked) { ', unattended' } else { '' })
}
$ui.Preset.Add_SelectionChanged({ Set-Preset $ui.Preset.SelectedItem })
foreach ($c in @($patchChecks.Values) + $ui.SkipOobe + $ui.RunWinUtil) {
    $c.Add_Click({ if (-not $script:applying) { $ui.Preset.SelectedItem = 'Custom' }; Update-Summary })
}
foreach ($c in $langChecks.Values) { $c.Add_Click({ Update-Summary }) }

$ui.ScanIsos.Add_Click({
        $win.Cursor = 'Wait'
        $script:IsoInfos = @(Get-SourceIsos $ui.IsoFolder.Text)
        $win.Cursor = $null
        $ui.ScanResult.Text = if ($script:IsoInfos) {
            ($script:IsoInfos | ForEach-Object { "$($_.Lang)  -  build $($_.Build)  -  $($_.Editions.Count) editions  -  $(Split-Path $_.Path -Leaf)" }) -join "`n"
        } else { 'No ISOs found in this folder.' }
        if ($script:IsoInfos -and $script:IsoInfos[0].Lang -in $langs) { $ui.BaseLang.SelectedItem = $script:IsoInfos[0].Lang }
        Update-Editions
    })
$ui.BaseLang.Add_SelectionChanged({ Update-Editions })
$ui.UseUup.Add_Click({ Update-Editions })

# --- Config + validation ---
function Get-Config {
    $uuid = ''
    if ($ui.Build.SelectedIndex -gt 0) { $uuid = $buildList[$ui.Build.SelectedIndex - 1].uuid }
    @{
        IsoFolder = $ui.IsoFolder.Text; UseUup = [bool]$ui.UseUup.IsChecked; Newest = [bool]$ui.Newest.IsChecked; Fast = [bool]$ui.Fast.IsChecked; UupBuild = $uuid; BaseLang = [string]$ui.BaseLang.SelectedItem
        LangPacks = @($langChecks.Keys | Where-Object { $langChecks[$_].IsChecked -and $_ -ne $ui.BaseLang.SelectedItem })
        Editions = @($script:edChecks.Keys | Where-Object { $script:edChecks[$_].IsChecked })
        Patches = @($Patches.Keys | Where-Object { $patchChecks[$_].IsChecked }); DriversPath = $ui.DriversPath.Text
        Unattend = @{
            Enabled = [bool]$ui.UnattendOn.IsChecked; UserName = $ui.UserName.Text; Password = $ui.Password.Password
            AutoLogon = [bool]$ui.AutoLogon.IsChecked; Admin = [bool]$ui.AdminGroup.IsChecked; ComputerName = $ui.ComputerName.Text
            TimeZone = [string]$ui.TimeZone.SelectedItem; Keyboard = [string]$ui.Keyboard.SelectedItem; Locale = [string]$ui.Locale.SelectedItem
            SkipOobe = [bool]$ui.SkipOobe.IsChecked; Edition = $(if ($ui.SkipEdition.IsChecked) { [string]$ui.Edition.SelectedItem } else { '' })
            ProductKey = $ui.ProductKey.Text.Trim().ToUpper(); AutoInstall = [string]$ui.AutoInstall.SelectedItem.Tag
            RunWinUtil = [bool]$ui.RunWinUtil.IsChecked; CustomScript = $ui.CustomScript.Text; EnableAdmin = [bool]$ui.EnableAdmin.IsChecked
        }
        Output = $ui.Output.Text; Split = [bool]$ui.Split.IsChecked; WorkDir = "$root\work"; CacheDir = "$root\cache"
    }
}

function Test-Config($c) {
    if (-not $c.Editions) { return 'Select at least one edition (Editions page - scan your ISOs or turn on UUP dump).' }
    if (-not $c.BaseLang) { return 'Select a base language.' }
    if ($c.Output -notmatch '\.iso$') { return 'Output must be an .iso file.' }
    if ('drivers' -in $c.Patches -and -not (Test-Path $c.DriversPath)) { return 'Driver folder does not exist.' }
    $u = $c.Unattend
    if ($u.Enabled) {
        if (-not $u.UserName.Trim()) { return 'Username is empty.' }
        if ($u.CustomScript -and -not (Test-Path $u.CustomScript)) { return 'Custom script not found.' }
        if ($u.ProductKey -and $u.ProductKey -notmatch '^([A-Z0-9]{5}-){4}[A-Z0-9]{5}$') { return 'Product key must look like XXXXX-XXXXX-XXXXX-XXXXX-XXXXX.' }
        if ($u.Edition -and -not $u.ProductKey -and -not $GenericKeys[$u.Edition]) { return "No generic key for $($u.Edition); turn off 'Skip edition choice' or enter a key." }
        if ($u.AutoInstall -eq 'BestSsd' -and -not $u.Edition) { return "'Best SSD' needs 'Skip edition choice' with an edition selected." }
        if ($u.Edition -and $u.Edition -notin $c.Editions) { return "'$($u.Edition)' (Skip edition choice) is not one of the selected editions." }
    }
}

# --- Build run (background runspace, polled by a timer) ---
$script:job = $null
$timer = New-Object Windows.Threading.DispatcherTimer -Property @{ Interval = [TimeSpan]::FromMilliseconds(300) }
$stepNames = 'Preflight', 'Sources', 'Editions', 'Language packs + patches', 'Setup (boot.wim)', 'Unattended', 'Compress', 'Create ISO', 'Finish'
$timer.Add_Tick({
        $line = $null
        while ($script:sync.Log.TryDequeue([ref]$line)) { $ui.Log.AppendText("$line`r`n"); $ui.Log.ScrollToEnd() }
        $s = [math]::Min(9, $script:sync.Step)
        $ui.Progress.Value = $s
        if ($s -gt 0) { $ui.StepText.Text = "Step $s of 9 - $($stepNames[$s - 1])" }
        if ($script:sync.Done -or $script:job.Handle.IsCompleted) {
            if (-not $script:sync.Done -and -not $script:sync.Error) { $script:sync.Error = 'The build stopped unexpectedly. See the log.' }
            foreach ($e in $script:job.PS.Streams.Error) { $ui.Log.AppendText("ERROR: $e`r`n") }
            $timer.Stop()
            try { $script:job.PS.EndInvoke($script:job.Handle) } catch { $ui.Log.AppendText("$_`r`n") }
            $script:job.PS.Runspace.Close(); $script:job.PS.Dispose(); $script:job = $null
            $ui.BuildBtn.Content = 'Build ISO'; $ui.BuildBtn.Tag = $null; $ui.BuildBtn.IsEnabled = $true
            if ($script:sync.Error) { $ui.StepText.Text = 'Failed'; Show-Msg "Build failed:`n$($script:sync.Error)`n`nDetails: build-log.txt next to the ISO." 'Error' | Out-Null }
            else { $ui.StepText.Text = 'Done'; Show-Msg "ISO ready:`n$($ui.Output.Text)" | Out-Null }
        }
    })

$ui.BuildBtn.Add_Click({
        if ($script:job) {
            $script:sync.Cancel = $true; $ui.BuildBtn.IsEnabled = $false
            $ui.Log.AppendText("Cancelling after the current operation...`r`n"); return
        }
        $cfg = Get-Config
        $err = Test-Config $cfg
        if ($err) { Show-Msg $err 'Warning' | Out-Null; return }
        if ($cfg.Unattend.Enabled -and $cfg.Unattend.AutoInstall -ne 'Off') {
            $what = if ($cfg.Unattend.AutoInstall -eq 'Disk0') { 'DISK 0 of any PC booted from this ISO will be ERASED without asking.' }
                    else { 'Any PC booted from this ISO with one clear best disk will have that disk ERASED after a 10 second countdown.' }
            if ((Show-Msg "Automatic install is ON.`n`n$what`n`nBuild anyway?" 'Warning' 'YesNo') -ne 'Yes') { return }
        }
        $ui.Log.Clear(); $ui.Progress.Value = 0; $ui.StepText.Text = 'Starting...'
        $script:sync = [hashtable]::Synchronized(@{ Log = New-Object 'System.Collections.Concurrent.ConcurrentQueue[string]'; Step = 0; Cancel = $false; Done = $false; Error = $null })
        $ps = [powershell]::Create()
        $ps.AddScript({
                param($root, $cfg, $sync)
                . "$root\lib\Patches.ps1"; . "$root\lib\Unattend.ps1"; . "$root\lib\Source.ps1"; . "$root\lib\Build.ps1"
                Invoke-Build $cfg $sync
            }).AddArgument($root).AddArgument($cfg).AddArgument($script:sync) | Out-Null
        $script:job = @{ PS = $ps; Handle = $ps.BeginInvoke() }
        $ui.BuildBtn.Content = 'Cancel'; $ui.BuildBtn.Tag = 'cancel'
        $timer.Start()
    })

$win.Add_Closing({
        param($s, $e)
        if ($script:job) { $e.Cancel = $true; Show-Msg 'A build is running. Cancel it first.' | Out-Null }
    })

$ui.Preset.SelectedItem = 'Recommended'
Update-Editions
$win.ShowDialog() | Out-Null
