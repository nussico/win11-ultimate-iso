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
# Launcher shortcut in the install folder, rewritten on every start: a .lnk holds full paths, so after the folder
# is moved, starting Builder.ps1 once makes it work again. Not for a git checkout.
if (-not (Test-Path "$root\.git")) {
    $lnk = (New-Object -ComObject WScript.Shell).CreateShortcut("$root\Win11 Ultimate ISO Builder.lnk")
    $lnk.TargetPath = "$env:SystemRoot\System32\conhost.exe"
    $lnk.Arguments = "--headless powershell.exe -NoProfile -ExecutionPolicy Bypass -STA -File `"$root\Builder.ps1`""
    $lnk.WorkingDirectory = $root; $lnk.IconLocation = "$root\lib\app.ico"; $lnk.Save()
}
. "$root\lib\Patches.ps1"; . "$root\lib\Unattend.ps1"; . "$root\lib\Source.ps1"; . "$root\lib\Build.ps1"

$xaml = [xml](Get-Content "$root\lib\Window.xaml" -Raw)
$win = [Windows.Markup.XamlReader]::Load((New-Object Xml.XmlNodeReader $xaml))
# Fit small or scaled screens (e.g. laptops at 125-150%).
$wa = [Windows.SystemParameters]::WorkArea
$win.Width = [math]::Min($win.Width, $wa.Width - 40); $win.Height = [math]::Min($win.Height, $wa.Height - 40)
$ui = @{}
$xaml.SelectNodes('//*[@*[local-name()="Name"]]') | ForEach-Object { $n = $_.GetAttribute('Name', 'http://schemas.microsoft.com/winfx/2006/xaml'); $ui[$n] = $win.FindName($n) }

function New-Check($Text, $Style, $Checked = $false) {
    $c = New-Object Windows.Controls.CheckBox
    $c.Content = $Text; $c.Style = $win.FindResource($Style); $c.IsChecked = $Checked; $c
}
function Select-Folder($Box) { $d = New-Object Windows.Forms.FolderBrowserDialog; if ($d.ShowDialog() -eq 'OK') { $Box.Text = $d.SelectedPath } }
function Show-Msg($Text, $Icon = 'Information', $Buttons = 'OK') { [Windows.MessageBox]::Show($win, $Text, 'Win11 Ultimate', $Buttons, $Icon) }
function Write-Log($Msg) { }   # lib helpers log during builds; nothing to log in the GUI thread

# Taskbar progress + flash when a build ends (until the window is focused).
$win.TaskbarItemInfo = New-Object Windows.Shell.TaskbarItemInfo
$win.Icon = $win.FindResource('Logo')
Add-Type -Namespace W11 -Name Native -MemberDefinition @'
[StructLayout(LayoutKind.Sequential)] public struct FLASHWINFO { public uint cbSize; public IntPtr hwnd; public uint dwFlags; public uint uCount; public uint dwTimeout; }
[DllImport("user32.dll")] static extern bool FlashWindowEx(ref FLASHWINFO f);
public static void Flash(IntPtr h) { var f = new FLASHWINFO(); f.cbSize = (uint)Marshal.SizeOf(f); f.hwnd = h; f.dwFlags = 15; f.uCount = uint.MaxValue; FlashWindowEx(ref f); }
'@

# --- Navigation ---
# Narrow window: drop the summary from the top bar so all tabs stay visible.
$win.Add_SizeChanged({ $ui.Summary.Visibility = if ($win.ActualWidth -lt 1150) { 'Collapsed' } else { 'Visible' } })
$ui.Nav.Add_SelectionChanged({
        foreach ($i in $ui.Nav.Items) { $ui[$i.Tag].Visibility = if ($i.IsSelected) { 'Visible' } else { 'Collapsed' } }
        if ($ui.Nav.SelectedItem.Tag -eq 'PageBuild') { Update-Plan }
    })

# --- UUP data (best effort; offline still works with own ISOs) ---
$script:UupBuilds = @()
$langs = @('ar-sa', 'cs-cz', 'da-dk', 'de-de', 'en-gb', 'en-us', 'es-es', 'fr-fr', 'it-it', 'ja-jp', 'ko-kr', 'nl-nl', 'pl-pl', 'pt-br', 'ru-ru', 'sv-se', 'tr-tr', 'uk-ua', 'zh-cn')
try {
    $script:UupBuilds = Get-UupBuilds
    $langs = Get-UupLanguages (Select-NewestUupBuild $script:UupBuilds).uuid
} catch { }
$script:IsoInfos = @()
# The 5 newest updates of every version, general (H2) releases first; H1 ships only on new hardware.
$buildList = @($script:UupBuilds | Where-Object title -like 'Windows 11, version*' |
    Sort-Object @{ e = { $_.title -match ' \d\dH2 ' }; Descending = $true }, @{ e = { [version]"10.0.$($_.build)" }; Descending = $true } |
    Group-Object { $_.title -replace '^Windows 11, version (\S+).*', '$1' } |
    Sort-Object @{ e = { $_.Name -like '*H2' }; Descending = $true }, @{ e = { [version]"10.0.$($_.Group[0].build)" }; Descending = $true } |
    ForEach-Object { $_.Group | Select-Object -First 5 })
$ui.Build.Items.Add('Auto - newest build matching your ISO') | Out-Null
foreach ($b in $buildList) { $ui.Build.Items.Add($b.title + $(if ($b.title -match ' \d\dH1 ') { '  - new PCs only' })) | Out-Null }
$ui.Build.SelectedIndex = 0

# --- Updates: install.ps1 writes the installed commit to version.txt ---
$repo = 'nussico/win11-ultimate-iso'
try {
    $have = (Get-Content "$root\version.txt" -ErrorAction Stop).Trim()
    $latest = Invoke-RestMethod "https://api.github.com/repos/$repo/commits/main" -Headers @{ Accept = 'application/vnd.github.sha' } -TimeoutSec 5
    if ($latest -and $latest.Trim() -ne $have) { $ui.UpdateBtn.Visibility = 'Visible' }
} catch { }   # manual install, offline or rate-limited: no button
# --- Info page ---
# Short commit from install.ps1, stamped on every ISO (label, Win11Ultimate.txt, log); 'dev' for a git checkout.
$toolVersion = if (Test-Path "$root\version.txt") { (Get-Content "$root\version.txt" -Raw).Trim() -replace '^(.{7}).*', '$1' } else { 'dev' }
$ui.InfoVersion.Text = if ($toolVersion -eq 'dev') { 'dev copy (not installed with install.ps1)' } else { $toolVersion }
$ui.InfoFolder.Text = $root
$ui.OpenGitHub.Add_Click({ Start-Process "https://github.com/$repo" })
$ui.OpenFolder.Add_Click({ Start-Process explorer.exe $root })
$ui.UpdateBtn.Add_Click({
        if ($script:job) { Show-Msg 'A build is running. Update when it is done.' | Out-Null; return }
        if ((Show-Msg 'Download the newest builder and restart it? Your ISOs and output are kept.' 'Question' 'YesNo') -ne 'Yes') { return }
        $env:W11UB_DIR = $root   # installer updates this folder instead of asking for a drive
        Start-Process powershell.exe -ArgumentList "-NoProfile -ExecutionPolicy Bypass -Command `"Start-Sleep 2; irm https://raw.githubusercontent.com/$repo/main/install.ps1 | iex`""
        $win.Close()
    })

# --- Source / languages ---
$ui.IsoFolder.Text = "$root\sources"
$ui.BrowseIso.Add_Click({ Select-Folder $ui.IsoFolder })
foreach ($l in $langs) { $ui.BaseLang.Items.Add($l) | Out-Null; $ui.Keyboard.Items.Add($l) | Out-Null; $ui.Locale.Items.Add($l) | Out-Null }
# Defaults follow this PC: Windows display language, then region/keyboard; en-us when not in the list.
function Get-DefaultLang($Tag) {
    $t = "$Tag".ToLower()
    @($t; $langs -like "$($t.Split('-')[0])-*"; 'en-us'; $langs[0]) | Where-Object { $_ -in $langs } | Select-Object -First 1
}
$ui.BaseLang.SelectedItem = Get-DefaultLang (Get-UICulture).Name
$region = Get-DefaultLang (Get-Culture).Name; $ui.Keyboard.SelectedItem = $region; $ui.Locale.SelectedItem = $region

# --- Editions ---
$script:edChecks = [ordered]@{}
function Update-Editions {
    # Keep ticks across rescans / language changes; none on start.
    $checked = @($script:edChecks.Keys | Where-Object { $script:edChecks[$_].IsChecked })
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
        $script:edChecks[$e].Add_Click({ Update-Summary; Update-BuildHint })
        $ui.EditionPanel.Children.Add($script:edChecks[$e]) | Out-Null
        $ui.Edition.Items.Add($e) | Out-Null
    }
    $ui.Edition.SelectedItem = if ($prevEdition -in $all) { $prevEdition } else { 'Windows 11 Pro' }
    if (-not $all) { $ui.EditionPanel.Children.Add((New-Object Windows.Controls.TextBlock -Property @{ Text = 'No editions yet - scan your ISOs or turn on UUP dump.' })) | Out-Null }
    Update-Summary; Update-BuildHint
}

# Spells out which build "Auto" resolves to (same logic as the build plan).
function Update-BuildHint {
    if ($ui.Build.SelectedIndex -gt 0) { $ui.BuildHint.Text = 'Downloads exactly this build when editions are missing.'; return }
    try {
        $p = Get-BuildPlan $script:IsoInfos $script:UupBuilds (Get-Config)
        $b = if ($p.Uup) { $p.Uup } elseif ($p.Base) { Select-UupBuild $script:UupBuilds $p.Base.Build } else { $p.Newest }
        $ui.BuildHint.Text = if (-not $b) { 'Auto: UUP dump not reachable, only your ISOs are used.' }
        elseif ($p.Base -and -not $p.Missing) { "Auto = $($b.title)  (not needed now: your ISO has all selected editions)" }
        else { "Auto = $($b.title)" }
    } catch { $ui.BuildHint.Text = 'Auto picks the newest build matching your ISO.' }
}

# --- Patches ---
$patchChecks = @{}
$patchCols = $ui.PatchCol0, $ui.PatchCol1, $ui.PatchCol2
$colRows = @(0, 0, 0)   # patches per column; each card goes to the shortest column
foreach ($g in $Patches.Values.Group | Select-Object -Unique) {   # catalog order
    $card = New-Object Windows.Controls.Border -Property @{ Style = $win.FindResource('Card'); Margin = '0,0,10,10'; Padding = '14,12' }
    $sp = New-Object Windows.Controls.StackPanel
    $h = New-Object Windows.Controls.TextBlock -Property @{ Text = $g.ToUpper(); Style = $win.FindResource('Section') }
    if ($g -eq 'Aggressive') { $h.Foreground = $win.FindResource('Danger'); $h.Text = 'AGGRESSIVE - CAN BREAK APPS/UPDATES' }
    $sp.Children.Add($h) | Out-Null
    # Aggressive gets its own full-width row under the columns so the risky patches stand apart.
    $wide = $g -eq 'Aggressive'
    $items = if ($wide) { New-Object Windows.Controls.Primitives.UniformGrid -Property @{ Columns = 3 } } else { $sp }
    foreach ($id in $Patches.Keys | Where-Object { $Patches[$_].Group -eq $g }) {
        $cell = New-Object Windows.Controls.StackPanel -Property @{ Margin = $(if ($wide) { '0,0,16,0' } else { '0' }) }
        $patchChecks[$id] = New-Check $Patches[$id].Label 'Toggle'
        $patchChecks[$id].Margin = '0,0,0,2'
        $cell.Children.Add($patchChecks[$id]) | Out-Null
        $cell.Children.Add((New-Object Windows.Controls.TextBlock -Property @{ Text = $Patches[$id].Desc; Style = $win.FindResource('Hint'); FontSize = 11; Margin = '50,0,0,8' })) | Out-Null
        if ($id -eq 'drivers') { $ui.DriverRow.Parent.Children.Remove($ui.DriverRow); $cell.Children.Add($ui.DriverRow) | Out-Null }
        $items.Children.Add($cell) | Out-Null
    }
    if ($wide) { $sp.Children.Add($items) | Out-Null; $card.Child = $sp; $ui.PatchWide.Children.Add($card) | Out-Null; continue }
    $i = [array]::IndexOf($colRows, [int]($colRows | Measure-Object -Minimum).Minimum)
    $colRows[$i] += @($Patches.Values | Where-Object Group -eq $g).Count
    $card.Child = $sp; $patchCols[$i].Children.Add($card) | Out-Null
}
$ui.BrowseDrivers.Add_Click({ Select-Folder $ui.DriversPath })

# --- Unattended ---
foreach ($tz in [TimeZoneInfo]::GetSystemTimeZones()) { $ui.TimeZone.Items.Add($tz.Id) | Out-Null }
$ui.TimeZone.SelectedItem = (Get-TimeZone).Id
function Set-UnattendBody { $on = [bool]$ui.UnattendOn.IsChecked; $ui.UnattendBody.IsEnabled = $on; $ui.UnattendBody.Opacity = if ($on) { 1 } else { 0.4 } }
Set-UnattendBody
$ui.UnattendOn.Add_Checked({ Set-UnattendBody }); $ui.UnattendOn.Add_Unchecked({ Set-UnattendBody })

# Apps: search winget on this PC, click a result to add it; click an added app (unchecks) to remove it.
function Add-App($Name, $Id) {
    if ($Id -in @($ui.AppPanel.Children | ForEach-Object Tag)) { return }
    $c = New-Check $(if ($Name -ne $Id) { "$Name  ($Id)" } else { $Id }) 'Chip' $true; $c.Tag = $Id
    $c.Add_Unchecked({ $ui.AppPanel.Children.Remove($this) })
    $ui.AppPanel.Children.Add($c) | Out-Null
}
function Search-Apps {
    $q = $ui.AppSearch.Text.Trim(); if (-not $q) { return }
    $ui.AppResults.Children.Clear()
    if (-not (Get-Command winget -ErrorAction SilentlyContinue)) { $ui.AppsHint.Text = 'winget is not installed on this PC, so search does not work here.'; return }
    $win.Cursor = 'Wait'; $win.Dispatcher.Invoke([action] {}, 'Render')
    $enc = [Console]::OutputEncoding; [Console]::OutputEncoding = [Text.Encoding]::UTF8
    try { $found = @(ConvertFrom-WingetSearch @(winget search $q --source winget --count 15 --accept-source-agreements --disable-interactivity 2>$null)) }
    finally { [Console]::OutputEncoding = $enc; $win.Cursor = $null }
    if (-not $found) { $ui.AppResults.Children.Add((New-Object Windows.Controls.TextBlock -Property @{ Text = "Nothing found for '$q'." })) | Out-Null }
    foreach ($f in $found) {
        $c = New-Check "+ $($f.Name)  ($($f.Id))" 'Chip'; $c.Tag = $f
        $c.Add_Checked({ Add-App $this.Tag.Name $this.Tag.Id; $ui.AppResults.Children.Clear(); $ui.AppSearch.Clear(); $ui.AppSearch.Focus() })
        $ui.AppResults.Children.Add($c) | Out-Null
    }
}
$ui.SearchApps.Add_Click({ Search-Apps })
$ui.AppSearch.Add_KeyDown({ if ($_.Key -eq 'Return') { Search-Apps } })
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
    $pa = @($patchChecks.Values | Where-Object IsChecked).Count
    $ui.Summary.Text = "$ed editions, $($ui.BaseLang.SelectedItem), $pa patches" + $(if ($ui.UnattendOn.IsChecked) { ', unattended' } else { '' })
}
$ui.Preset.Add_SelectionChanged({ Set-Preset $ui.Preset.SelectedItem })
foreach ($c in @($patchChecks.Values) + $ui.SkipOobe + $ui.RunWinUtil) {
    $c.Add_Click({ if (-not $script:applying) { $ui.Preset.SelectedItem = 'Custom' }; Update-Summary })
}

# Preset files: Save writes Get-PresetData as JSON, Load puts the values back into the controls.
function Import-PresetFile($p) {
    $set = { param($name, $v) if ($null -eq $v) { return }; $c = $ui[$name]
        if ($c -is [Windows.Controls.Primitives.ToggleButton]) { $c.IsChecked = [bool]$v }
        elseif ($c -is [Windows.Controls.ComboBox]) { if ("$v" -in @($c.Items)) { $c.SelectedItem = "$v" } }
        else { $c.Text = "$v" } }
    $script:applying = $true
    foreach ($k in 'UseUup', 'Newest', 'Fast', 'Split', 'QuickCompress', 'DefenderExclude', 'BaseLang') { & $set $k $p.$k }
    Update-Editions
    if ($p.PSObject.Properties['Editions']) { foreach ($e in $script:edChecks.Keys) { $script:edChecks[$e].IsChecked = $e -in @($p.Editions) } }
    if ($p.PSObject.Properties['Patches']) { foreach ($id in $patchChecks.Keys) { $patchChecks[$id].IsChecked = $id -in @($p.Patches) } }
    if ($u = $p.Unattend) {
        foreach ($k in 'UserName', 'AutoLogon', 'ComputerName', 'TimeZone', 'Keyboard', 'Locale', 'SkipOobe', 'RunWinUtil', 'EnableAdmin', 'WifiName') { & $set $k $u.$k }
        & $set 'UnattendOn' $u.Enabled; & $set 'AdminGroup' $u.Admin
        $ui.SkipEdition.IsChecked = [bool]$u.Edition; & $set 'Edition' $u.Edition
        $ai = @($ui.AutoInstall.Items | Where-Object Tag -eq $u.AutoInstall); if ($ai) { $ui.AutoInstall.SelectedItem = $ai[0] }
        $ui.AppPanel.Children.Clear(); foreach ($id in @($u.Apps)) { if ("$id" -match $WingetIdPattern) { Add-App $id $id } }
    }
    $ui.Preset.SelectedItem = 'Custom'; $script:applying = $false
    Update-Summary; Update-BuildHint
}
$ui.SavePreset.Add_Click({
        $d = New-Object Windows.Forms.SaveFileDialog -Property @{ Filter = 'Preset (*.json)|*.json'; FileName = 'my-preset.json' }
        if ($d.ShowDialog() -eq 'OK') { Get-PresetData (Get-Config) | ConvertTo-Json -Depth 4 | Set-Content $d.FileName } })
function Import-PresetPath($Path) {
    try { Import-PresetFile (Get-Content $Path -Raw | ConvertFrom-Json) } catch { $script:applying = $false; Show-Msg "Could not load this preset:`n`n$_" 'Error' | Out-Null }
}
$ui.LoadPreset.Add_Click({
        $d = New-Object Windows.Forms.OpenFileDialog -Property @{ Filter = 'Preset (*.json)|*.json' }
        if ($d.ShowDialog() -eq 'OK') { Import-PresetPath $d.FileName } })
# Written on every build start; never loaded automatically (each start uses defaults).
$lastPreset = "$root\last-preset.json"
$ui.LoadLast.Add_Click({ if (Test-Path $lastPreset) { Import-PresetPath $lastPreset } else { Show-Msg 'No build yet.' | Out-Null } })

function Invoke-Scan {
    $win.Cursor = 'Wait'; $ui.ScanResult.Text = 'Scanning...'
    $win.Dispatcher.Invoke([action] {}, 'Render')
    $script:IsoInfos = @(Get-SourceIsos $ui.IsoFolder.Text)
    $win.Cursor = $null
    $ui.ScanResult.Text = if ($script:IsoInfos) {
        ($script:IsoInfos | ForEach-Object { "$($_.Lang)  -  build $($_.Build)  -  $($_.Editions.Count) editions  -  $(Split-Path $_.Path -Leaf)" }) -join "`n"
    } else { 'No ISOs found in this folder.' }
    if ($script:IsoInfos -and $script:IsoInfos[0].Lang -in $langs) { $ui.BaseLang.SelectedItem = $script:IsoInfos[0].Lang }
    Update-Editions; Update-Storage
}
$ui.ScanIsos.Add_Click({ Invoke-Scan })
$ui.BaseLang.Add_SelectionChanged({ Update-Editions })
$ui.UseUup.Add_Click({ Update-Editions })
$ui.Build.Add_SelectionChanged({ Update-BuildHint })
$ui.Newest.Add_Click({ Update-BuildHint })

# --- Config + validation ---
function Get-Config {
    $uuid = ''
    if ($ui.Build.SelectedIndex -gt 0) { $uuid = $buildList[$ui.Build.SelectedIndex - 1].uuid }
    @{
        IsoFolder = $ui.IsoFolder.Text; UseUup = [bool]$ui.UseUup.IsChecked; Newest = [bool]$ui.Newest.IsChecked; Fast = [bool]$ui.Fast.IsChecked; UupBuild = $uuid; BaseLang = [string]$ui.BaseLang.SelectedItem
        Editions = @($script:edChecks.Keys | Where-Object { $script:edChecks[$_].IsChecked })
        Patches = @($Patches.Keys | Where-Object { $patchChecks[$_].IsChecked }); DriversPath = $ui.DriversPath.Text
        Unattend = @{
            Enabled = [bool]$ui.UnattendOn.IsChecked; UserName = $ui.UserName.Text; Password = $ui.Password.Password
            AutoLogon = [bool]$ui.AutoLogon.IsChecked; Admin = [bool]$ui.AdminGroup.IsChecked; ComputerName = $ui.ComputerName.Text
            Language = [string]$ui.BaseLang.SelectedItem; TimeZone = [string]$ui.TimeZone.SelectedItem; Keyboard = [string]$ui.Keyboard.SelectedItem; Locale = [string]$ui.Locale.SelectedItem
            SkipOobe = [bool]$ui.SkipOobe.IsChecked; Edition = $(if ($ui.SkipEdition.IsChecked) { [string]$ui.Edition.SelectedItem } else { '' })
            ProductKey = $ui.ProductKey.Text.Trim().ToUpper(); AutoInstall = [string]$ui.AutoInstall.SelectedItem.Tag
            RunWinUtil = [bool]$ui.RunWinUtil.IsChecked; CustomScript = $ui.CustomScript.Text; EnableAdmin = [bool]$ui.EnableAdmin.IsChecked
            Apps = @($ui.AppPanel.Children | ForEach-Object Tag); WifiName = $ui.WifiName.Text.Trim(); WifiPassword = $ui.WifiPassword.Password
        }
        Output = $ui.Output.Text; Split = [bool]$ui.Split.IsChecked; QuickCompress = [bool]$ui.QuickCompress.IsChecked; DefenderExclude = [bool]$ui.DefenderExclude.IsChecked; WorkDir = "$root\work"; CacheDir = "$root\cache"; ToolVersion = $toolVersion
    }
}

# Returns the problem and the control to fix it in (Show-Field jumps there), or nothing if the config is fine.
function Test-Config($c) {
    if (-not $c.Editions) { return 'Select at least one edition (scan your ISOs or turn on UUP dump).', 'EditionPanel' }
    if (-not $c.BaseLang) { return 'Select a base language.', 'BaseLang' }
    if ($c.Output -notmatch '\.iso$') { return 'Output must be an .iso file.', 'Output' }
    if ('drivers' -in $c.Patches -and -not (Test-Path $c.DriversPath)) { return 'Driver folder does not exist.', 'DriversPath' }
    $u = $c.Unattend
    if ($u.Enabled) {
        if (-not $u.UserName.Trim()) { return 'Username is empty.', 'UserName' }
        if ($u.CustomScript -and -not (Test-Path $u.CustomScript)) { return 'Custom script not found.', 'CustomScript' }
        if ($u.WifiName -and $u.WifiPassword -and $u.WifiPassword.Length -notin 8..63) { return 'Wi-Fi password must be 8 to 63 characters (or empty for an open network).', 'WifiPassword' }
        if ($u.ProductKey -and $u.ProductKey -notmatch '^([A-Z0-9]{5}-){4}[A-Z0-9]{5}$') { return 'Product key must look like XXXXX-XXXXX-XXXXX-XXXXX-XXXXX.', 'ProductKey' }
        if ($u.Edition -and -not $u.ProductKey -and -not $GenericKeys[$u.Edition]) { return "No generic key for $($u.Edition); turn off 'Skip edition choice' or enter a key.", 'Edition' }
        if ($u.AutoInstall -eq 'BestSsd' -and -not $u.Edition) { return "'Best SSD' needs 'Skip edition choice' with an edition selected.", 'SkipEdition' }
        if ($u.Edition -and $u.Edition -notin $c.Editions) { return "'$($u.Edition)' (Skip edition choice) is not one of the selected editions.", 'Edition' }
    }
}

# Opens the page holding control $Name, scrolls to it and outlines its card red for 3 s.
function Show-Field($Name) {
    $el = $ui[$Name]; $card = $null
    for ($p = $el; $p; $p = [Windows.LogicalTreeHelper]::GetParent($p)) {
        if (-not $card -and $p -is [Windows.Controls.Border] -and $p.Style -eq $win.FindResource('Card')) { $card = $p }
        if ($p.Name -like 'Page*') { $ui.Nav.SelectedItem = @($ui.Nav.Items | Where-Object Tag -eq $p.Name)[0] }
    }
    $win.Dispatcher.BeginInvoke([action] { $el.BringIntoView(); $el.Focus() | Out-Null }.GetNewClosure(), 'Loaded') | Out-Null
    if ($card) {
        $old = $card.BorderBrush; $card.BorderBrush = $win.FindResource('Danger')
        $t = New-Object Windows.Threading.DispatcherTimer -Property @{ Interval = [TimeSpan]::FromSeconds(3) }
        $t.Add_Tick({ $t.Stop(); $card.BorderBrush = $old }.GetNewClosure()); $t.Start()
    }
}

# Minutes for steps 3-9 (Cached = whole image reused, Quick/Max = per edition). Defaults until a build on this PC measured them.
$timingFile = "$root\timing.json"
function Get-Timing {
    $t = @{ Cached = 2; Quick = 6; Max = 8; Measured = @() }
    try { $j = Get-Content $timingFile -Raw -ErrorAction Stop | ConvertFrom-Json; foreach ($k in $j.PSObject.Properties.Name) { $t[$k] = [double]$j.$k; $t.Measured += $k } } catch { }
    $t
}
function Save-Timing($Key, [double]$Minutes) {
    $t = Get-Timing; $o = [ordered]@{}; foreach ($k in $t.Measured + $Key | Select-Object -Unique) { $o[$k] = $t[$k] }
    $o[$Key] = [math]::Round($Minutes, 1); $o | ConvertTo-Json | Set-Content $timingFile
}

# --- Plan (same decision logic as the build) ---
function Update-Plan {
    try {
        $cfg = Get-Config
        if (-not $cfg.Editions) { $ui.PlanText.Text = 'Pick at least one edition on the Source page.'; return }
        $p = Get-BuildPlan $script:IsoInfos $script:UupBuilds $cfg
        $lines = @()
        if ($p.Error) { $lines += "PROBLEM: $($p.Error)" }
        if ($p.Note) { $lines += $p.Note }
        if ($p.Base) { $lines += "Source: your ISO $(Split-Path $p.Base.Path -Leaf) (build $($p.Base.Build))" }
        if ($p.Missing -and $p.Uup) {
            $lines += "Download: $($p.Missing -join ', ') from UUP dump, $($p.Uup.title), " +
                $(if ($cfg.Fast) { 'fast mode (about 15 min, older base build)' } else { 'with the latest update (about 60 min)' })
        }
        $lines += "Editions: $($cfg.Editions -join ', ')  ($($cfg.BaseLang))"
        $lines += "Patches: $($cfg.Patches.Count) selected$(if ($cfg.Unattend.Enabled) { ', unattended setup' })"
        # Same cache check as the build. Image time (steps 3-9) is measured on this PC after each build.
        $cachePath = if ($p.Base -and -not $p.Missing) { Get-ImageCachePath $cfg @($cfg.Editions | ForEach-Object { @{ Iso = $p.Base.Path; Name = $_ } }) }
        $cached = $cachePath -and (Test-Path $cachePath)
        $script:planKey = if ($cached) { 'Cached' } elseif ($cfg.QuickCompress) { 'Quick' } else { 'Max' }; $script:planEds = $cfg.Editions.Count
        $t = Get-Timing
        $min = 1 + [math]::Ceiling($t.($script:planKey) * $(if ($cached) { 1 } else { $script:planEds }))
        $min += $(if ($p.Missing) { if ($cfg.Fast) { 15 } else { 60 } } else { 0 })
        $lines += "Time: about $min minutes$(if ($cached) { ' (reusing the finished image from the last build)' })" +
            $(if ($t.Measured -contains $script:planKey) { ', measured on this PC' } else { ', estimate until the first build on this PC' })
        $need = Get-NeededGB $cached; $free = [math]::Round((Get-PSDrive $root.Substring(0, 1)).Free / 1GB)
        $lines += "Disk: needs $need GB free on $($root.Substring(0, 2)), you have $free GB$(if ($free -lt $need) { '  - NOT ENOUGH' })"
        $ui.PlanText.Text = $lines -join "`n"
    } catch { $ui.PlanText.Text = "Plan not available: $_" }
}

# --- Storage ---
function Get-FolderGB($Path) {
    if (-not (Test-Path $Path)) { return 0 }
    [math]::Round(((Get-ChildItem $Path -Recurse -File -Force -ErrorAction SilentlyContinue | Measure-Object Length -Sum).Sum) / 1GB, 1)
}
# UUP downloads (they have a .build sidecar) replaced by a newer ISO of the same language. Your own ISOs are never touched.
function Get-OldDownloads {
    $script:IsoInfos | Where-Object { Test-Path "$($_.Path).build" } | Where-Object {
        $i = $_; $script:IsoInfos | Where-Object { $_.Lang -eq $i.Lang -and [int]$_.Build -gt [int]$i.Build } }
}
function Update-Storage {
    $old = @(Get-OldDownloads)
    $left = (Get-FolderGB "$root\work") + (Get-FolderGB "$root\cache")
    $ui.StorageText.Text = "ISOs: $(Get-FolderGB $ui.IsoFolder.Text) GB   |   built: $(Get-FolderGB "$root\out") GB   |   temp leftovers: $left GB   |   test VM: $(Get-FolderGB "$root\vm") GB" +
        $(if ($old) { "   |   $($old.Count) outdated download(s)" })
}
$ui.CleanUp.Add_Click({
        if ($script:job) { Show-Msg 'Wait until the build is finished.' | Out-Null; return }
        $old = @(Get-OldDownloads)
        $list = @('Temporary build files (work, cache)') + @($old | ForEach-Object { "Outdated download: $(Split-Path $_.Path -Leaf)" })
        if ((Show-Msg "Delete:`n- $($list -join "`n- ")`n`nYour own ISOs, the newest downloads and built ISOs are kept." 'Question' 'YesNo') -ne 'Yes') { return }
        $win.Cursor = 'Wait'
        try {
            Get-WindowsImage -Mounted -ErrorAction SilentlyContinue | Where-Object Path -like "$root\work*" | ForEach-Object { Dismount-WindowsImage -Path $_.Path -Discard | Out-Null }
            foreach ($d in "$root\work", "$root\cache") { Remove-ImagePath $d }
            foreach ($o in $old) { Remove-Item $o.Path, "$($o.Path).build" -Force }
        } catch { Show-Msg "Clean up incomplete: $_" 'Warning' | Out-Null }
        $win.Cursor = $null
        Invoke-Scan
    })

# --- Test in VM (Hyper-V) ---
$vmName = 'Win11 Ultimate Test'
function Remove-TestVm {
    if (Get-Command Hyper-V\Get-VM -ErrorAction SilentlyContinue) {
        if (Hyper-V\Get-VM $vmName -ErrorAction SilentlyContinue) { Hyper-V\Stop-VM $vmName -TurnOff -Force -ErrorAction SilentlyContinue; Hyper-V\Remove-VM $vmName -Force }
    }
    if (Test-Path "$root\vm") { Remove-Item "$root\vm" -Recurse -Force }
}
$ui.RemoveVm.Add_Click({
        $hasVm = (Get-Command Hyper-V\Get-VM -ErrorAction SilentlyContinue) -and (Hyper-V\Get-VM $vmName -ErrorAction SilentlyContinue)
        if (-not $hasVm -and -not (Test-Path "$root\vm")) { Show-Msg 'There is no test VM to remove.' | Out-Null; return }
        if ((Show-Msg "Remove the test VM '$vmName' and delete its virtual disk ($(Get-FolderGB "$root\vm") GB)?" 'Question' 'YesNo') -ne 'Yes') { return }
        $win.Cursor = 'Wait'
        try { Remove-TestVm } catch { Show-Msg "Could not remove the VM:`n$_" 'Error' | Out-Null }
        finally { $win.Cursor = $null; Update-Storage }
    })
$ui.TestVm.Add_Click({
        $iso = $ui.Output.Text
        if (-not (Test-Path $iso)) { Show-Msg 'Build the ISO first.' 'Warning' | Out-Null; return }
        if (-not (Get-Command Hyper-V\New-VM -ErrorAction SilentlyContinue) -or -not (Get-Service vmms -ErrorAction SilentlyContinue)) {
            Show-Msg "Hyper-V is not turned on.`n`nOpen 'Turn Windows features on or off', tick Hyper-V (needs Windows Pro), restart and try again." 'Warning' | Out-Null; return
        }
        if (Hyper-V\Get-VM $vmName -ErrorAction SilentlyContinue) {
            if ((Show-Msg "Replace the existing test VM '$vmName'? Its virtual disk is deleted." 'Question' 'YesNo') -ne 'Yes') { return }
        }
        $win.Cursor = 'Wait'
        try {
            Remove-TestVm
            $vmArgs = @{ Name = $vmName; Generation = 2; MemoryStartupBytes = 4GB; Path = "$root\vm"; NewVHDPath = "$root\vm\disk.vhdx"; NewVHDSizeBytes = 80GB }
            if (Hyper-V\Get-VMSwitch 'Default Switch' -ErrorAction SilentlyContinue) { $vmArgs.SwitchName = 'Default Switch' }
            $vm = Hyper-V\New-VM @vmArgs
            Hyper-V\Set-VM $vm -ProcessorCount ([math]::Min(4, [Environment]::ProcessorCount)) -AutomaticCheckpointsEnabled $false
            $dvd = Hyper-V\Add-VMDvdDrive -VM $vm -Path $iso -Passthru
            # Disk first: empty at the start so the DVD boots; after the install Windows starts instead of setup again.
            Hyper-V\Set-VMFirmware -VM $vm -BootOrder @(@(Hyper-V\Get-VMHardDiskDrive -VM $vm) + $dvd + @(Hyper-V\Get-VMNetworkAdapter -VM $vm))
            Start-Process vmconnect.exe -ArgumentList 'localhost', "`"$vmName`""
            Show-Msg ("Test VM '$vmName' created (4 GB RAM, 80 GB disk, no TPM - that tests the hardware-check bypass).`n`n" +
                "In the VM window click Start, then quickly press a key when it says 'Press any key to boot from CD or DVD'. Only that first time: after setup reboots, Windows starts from the disk.") | Out-Null
        } catch { Show-Msg "Could not create the VM:`n$_" 'Error' | Out-Null }
        finally { $win.Cursor = $null; Update-Storage }
    })

# --- Build run (background runspace, polled by a timer) ---
$script:job = $null
$timer = New-Object Windows.Threading.DispatcherTimer -Property @{ Interval = [TimeSpan]::FromMilliseconds(300) }
$stepNames = 'Preflight', 'Sources', 'Editions', 'Patches', 'Setup (boot.wim)', 'Unattended', 'Compress', 'Create ISO', 'Finish'
$timer.Add_Tick({
        $line = $null
        while ($script:sync.Log.TryDequeue([ref]$line)) { $ui.Log.AppendText("$line`r`n"); $ui.Log.ScrollToEnd() }
        $s = [math]::Min(9, $script:sync.Step)
        if ($s -ne $script:shownStep) {   # glide to the new step instead of jumping
            $script:shownStep = $s; $script:stepStart = Get-Date
            if ($s -eq 3) { $script:imageStart = Get-Date }   # after the download, so the measured time is this PC's own speed
            $ui.Progress.BeginAnimation([Windows.Controls.ProgressBar]::ValueProperty, (New-Object Windows.Media.Animation.DoubleAnimation $s, ([Windows.Duration][TimeSpan]::FromMilliseconds(500))))
        }
        # Running clocks show the build is alive during long silent DISM operations.
        $win.TaskbarItemInfo.ProgressState = 'Normal'; $win.TaskbarItemInfo.ProgressValue = $s / 9
        if ($s -gt 0) { $ui.StepText.Text = "Step $s of 9 - $($stepNames[$s - 1])   |   {0:mm\:ss} in this step   |   {1:hh\:mm\:ss} total" -f ((Get-Date) - $script:stepStart), ((Get-Date) - $script:buildStart) }
        if ($script:sync.Done -or $script:job.Handle.IsCompleted) {
            if (-not $script:sync.Done -and -not $script:sync.Error) { $script:sync.Error = 'The build stopped unexpectedly. See the log.' }
            foreach ($e in $script:job.PS.Streams.Error) { $ui.Log.AppendText("ERROR: $e`r`n") }
            $timer.Stop()
            try { $script:job.PS.EndInvoke($script:job.Handle) } catch { $ui.Log.AppendText("$_`r`n") }
            $script:job.PS.Runspace.Close(); $script:job.PS.Dispose(); $script:job = $null
            $ui.BuildBtn.Content = 'Build ISO'; $ui.BuildBtn.Tag = $null; $ui.BuildBtn.IsEnabled = $true
            $win.TaskbarItemInfo.ProgressState = if ($script:sync.Error) { 'Error' } else { 'None' }; $win.TaskbarItemInfo.ProgressValue = 1
            if (-not $win.IsActive) { [W11.Native]::Flash((New-Object Windows.Interop.WindowInteropHelper $win).Handle) }
            Update-Storage
            if ($script:sync.Error) { $ui.StepText.Text = 'Failed'; Show-Msg "Build failed:`n$($script:sync.Error)`n`nDetails: build-log.txt next to the ISO." 'Error' | Out-Null }
            else {
                if ($script:imageStart -and $script:planKey) { Save-Timing $script:planKey (((Get-Date) - $script:imageStart).TotalMinutes / $(if ($script:planKey -eq 'Cached') { 1 } else { $script:planEds })) }
                $ui.StepText.Text = 'Done'; Show-Msg "ISO ready:`n$($ui.Output.Text)" | Out-Null }
        }
    })

$ui.BuildBtn.Add_Click({
        if ($script:job) {
            $script:sync.Cancel = $true; $ui.BuildBtn.IsEnabled = $false
            $ui.Log.AppendText("Cancelling after the current operation...`r`n"); return
        }
        $cfg = Get-Config
        $err, $field = Test-Config $cfg
        if ($err) { Show-Field $field; Show-Msg $err 'Warning' | Out-Null; return }
        if ($cfg.Unattend.Enabled -and $cfg.Unattend.AutoInstall -ne 'Off') {
            $what = if ($cfg.Unattend.AutoInstall -eq 'Disk0') { 'DISK 0 of any PC booted from this ISO will be ERASED without asking.' }
                    else { 'Any PC booted from this ISO with one clear best disk will have that disk ERASED after a 10 second countdown.' }
            if ((Show-Msg "Automatic install is ON.`n`n$what`n`nBuild anyway?" 'Warning' 'YesNo') -ne 'Yes') { return }
        }
        Get-PresetData $cfg | ConvertTo-Json -Depth 4 | Set-Content $lastPreset
        try { Hyper-V\Get-VMDvdDrive -VMName $vmName -ErrorAction Stop | Where-Object Path -eq $cfg.Output | Hyper-V\Set-VMDvdDrive -Path $null } catch { }
        $ui.Log.Clear(); $ui.Progress.BeginAnimation([Windows.Controls.ProgressBar]::ValueProperty, $null); $ui.Progress.Value = 0; $script:shownStep = 0; $script:buildStart = Get-Date; $ui.StepText.Text = 'Starting...'
        $script:imageStart = $null; $script:planKey = $null; Update-Plan   # sets planKey / planEds for the timing
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
        if ($script:job) { $e.Cancel = $true; Show-Msg 'A build is running. Cancel it first.' | Out-Null; return }
    })

$ui.Preset.SelectedItem = 'Recommended'
Update-Editions
$win.Add_ContentRendered({ Invoke-Scan })
$win.ShowDialog() | Out-Null
