<#
                           _
 _ __   _   _  ___   ___  (_)   ___    ___
| '_ \ | | | |/ __| / __| | |  / __|  / _ \
| | | || |_| |\__ \ \__ \ | | | (__  | (_) |
|_| |_| \__,_||___/ |___/ |_|  \___|  \___/
#>
# Win11 Ultimate ISO Builder - GUI entry point (WPF).
# Always runs in elevated Windows PowerShell 5.1 (STA, needed by WPF).
$isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
if (-not $isAdmin -or $PSVersionTable.PSEdition -ne 'Desktop') {
    # conhost --headless: no console window, even when Windows Terminal is the default terminal
    Start-Process conhost.exe -Verb RunAs -ArgumentList "--headless powershell.exe -NoProfile -ExecutionPolicy Bypass -STA -File `"$PSCommandPath`""
    exit
}

Add-Type -AssemblyName PresentationFramework, System.Windows.Forms
# There is no console window, so show startup errors instead of failing silently.
trap { [Windows.MessageBox]::Show("The builder could not start:`n`n$_`n`n$($_.InvocationInfo.PositionMessage)", 'Win11 Ultimate', 'OK', 'Error') | Out-Null; exit 1 }

# One builder at a time: starting it again brings the open window to the front instead.
$instance = New-Object Threading.Mutex($false, 'Local\Win11UltimateBuilder')
$owned = try { $instance.WaitOne(0) } catch [Threading.AbandonedMutexException] { $true }   # abandoned = last builder crashed
if (-not $owned) {
    Add-Type -AssemblyName Microsoft.VisualBasic
    try { [Microsoft.VisualBasic.Interaction]::AppActivate('Win11 Ultimate ISO Builder') } catch { }
    exit
}

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
# Narrow window: drop the summary from the top bar when the tabs would be cut off.
function Update-TopBar {
    $ui.Summary.Visibility = 'Visible'; $win.UpdateLayout()
    $last = $ui.Nav.ItemContainerGenerator.ContainerFromIndex($ui.Nav.Items.Count - 1)
    if ($last -and $last.TranslatePoint((New-Object Windows.Point $last.ActualWidth, 0), $ui.Nav).X -gt $ui.Nav.ActualWidth) { $ui.Summary.Visibility = 'Collapsed' }
}
$win.Add_SizeChanged({ Update-TopBar })
$ui.Nav.Add_SelectionChanged({
        foreach ($i in $ui.Nav.Items) { $ui[$i.Tag].Visibility = if ($i.IsSelected) { 'Visible' } else { 'Collapsed' } }
        if ($ui.Nav.SelectedItem.Tag -eq 'PageBuild') { Update-Plan }
    })

# --- Background work: network calls and ISO scans run off the UI thread, so the window opens at once ---
# $Work runs in its own runspace with lib\Source.ps1 loaded, as param($root, $Arg); $Done gets its output (nothing on error)
# and the problems (errors and warnings as text, shown instead of a plain "nothing found") back on the UI thread.
# $Work goes over as text: a script block from this runspace would run on this (busy) thread.
$script:bgJobs = [Collections.ArrayList]@()
$AvBlockedText = 'Windows Defender blocked the builder (a false alarm from its cloud protection, gone again within minutes last time). Close the builder and start it again a bit later.'
# Defender (AMSI) refusing a script: ScriptContainedMaliciousContent somewhere in the exception chain, in any language.
function Test-AvBlocked($Err) {
    if ("$($Err.FullyQualifiedErrorId)" -match 'MaliciousContent') { return $true }
    for ($x = $Err.Exception; $x; $x = $x.InnerException) {
        if ("$($x.ErrorRecord.FullyQualifiedErrorId) $($x.Errors.ErrorId)" -match 'MaliciousContent') { return $true }
    }
    $false
}
$bgTimer = New-Object Windows.Threading.DispatcherTimer -Property @{ Interval = [TimeSpan]::FromMilliseconds(200) }
$bgTimer.Add_Tick({
        foreach ($j in @($script:bgJobs | Where-Object { $_.Handle.IsCompleted })) {
            $script:bgJobs.Remove($j)
            # @(...) outside the try: "$x = try {} catch { @() }" gives $null, and $null piped to ForEach-Object runs once.
            $out = @(try { $j.PS.EndInvoke($j.Handle) } catch { $j.PS.Streams.Error.Add($_) })
            $errs = @($j.PS.Streams.Error) + @($j.PS.Streams.Warning)
            foreach ($e in $errs) { try { Add-Content "$root\out\background-errors.txt" "$(Get-Date -Format s)  $e  $($e.InvocationInfo.PositionMessage)" } catch { } }
            $problems = @($errs | ForEach-Object { if (Test-AvBlocked $_) { $AvBlockedText } else { ("$_" -split "`n")[0].Trim() } } | Select-Object -Unique)
            if ($AvBlockedText -in $problems -and -not $script:avWarned) {
                $script:avWarned = $true   # every background job fails at once: one popup
                if ($win.IsLoaded) { Show-Msg $AvBlockedText 'Warning' | Out-Null } else { $win.Add_ContentRendered({ Show-Msg $AvBlockedText 'Warning' | Out-Null }) }
            }
            $j.PS.Runspace.Close(); $j.PS.Dispose()
            & $j.Done $out $problems
        }
        if (-not $script:bgJobs.Count) { $bgTimer.Stop() }
    })
function Start-Background([scriptblock]$Work, $Arg, [scriptblock]$Done) {
    $ps = [powershell]::Create()
    $ps.AddScript({ param($root, $work, $arg) . "$root\lib\Source.ps1"; & ([scriptblock]::Create($work)) $root $arg }).
        AddArgument($root).AddArgument("$Work").AddArgument($Arg) | Out-Null
    $script:bgJobs.Add(@{ PS = $ps; Handle = $ps.BeginInvoke(); Done = $Done }) | Out-Null
    $bgTimer.Start()
}

# --- UUP data (best effort; offline still works with own ISOs). Until it arrives: Auto only, built-in languages. ---
$script:UupBuilds = @(); $script:buildList = @(); $script:uupLoading = $true
$script:langs = @('ar-sa', 'cs-cz', 'da-dk', 'de-de', 'en-gb', 'en-us', 'es-es', 'fr-fr', 'it-it', 'ja-jp', 'ko-kr', 'nl-nl', 'pl-pl', 'pt-br', 'ru-ru', 'sv-se', 'tr-tr', 'uk-ua', 'zh-cn')
$script:IsoInfos = @()
$ui.Build.Items.Add('Auto - newest build matching your ISO') | Out-Null
$ui.Build.SelectedIndex = 0
Start-Background {
    $builds = Get-UupBuilds
    [pscustomobject]@{ Builds = $builds; Langs = @(try { Get-UupLanguages (Select-NewestUupBuild $builds).uuid } catch { }) }
} $null {
    param($out, $problems)
    $script:uupLoading = $false
    $script:uupProblem = $problems | Select-Object -First 1   # why the list is empty (offline, blocked, ...)
    if ($r = $out | Select-Object -First 1) {
        $script:UupBuilds = @($r.Builds)
        if ($r.Langs) { Set-Languages $r.Langs }
        # The 5 newest updates of every version, general releases first (Test-GeneralRelease decides, see lib\Source.ps1).
        $script:buildList = @($script:UupBuilds | Where-Object title -like 'Windows 11, version*' |
            Sort-Object @{ e = { [version]"10.0.$($_.build)" }; Descending = $true } |
            Group-Object { $_.title -replace '^Windows 11, version (\S+).*', '$1' } |
            Sort-Object @{ e = { Test-GeneralRelease $_.Group[0] }; Descending = $true }, @{ e = { [version]"10.0.$($_.Group[0].build)" }; Descending = $true } |
            ForEach-Object { $_.Group | Select-Object -First 5 })
        foreach ($b in $script:buildList) { $ui.Build.Items.Add($b.title + $(if ((Get-ReleaseVersion $b) -in $NewPcOnlyReleases) { '  - new PCs only' })) | Out-Null }
    }
    Update-BuildHint
    if ($ui.Nav.SelectedItem.Tag -eq 'PageBuild') { Update-Plan }
}

# --- Updates: install.ps1 writes the installed commit to version.txt ---
$repo = 'nussico/win11-ultimate-iso'
function Start-Update {
    if ($script:job) { Show-Msg 'A build is running. Update when it is done.' | Out-Null; return }
    # Closing mid-scan is refused (an ISO would stay mounted) while the installer already runs: update when the scan ends.
    if ($script:scanning) { $script:updateAfterScan = $true; $ui.ScanResult.Text = 'Scanning your ISOs... the builder updates when done.'; return }
    # Saved and run from a file, not "irm | iex": a download-and-run pipe is what antivirus watches for.
    # In a new folder only admins can write to: it runs elevated, so a non-admin program must not swap it first.
    $stage = Join-Path $env:TEMP "w11ub-update-$([guid]::NewGuid().ToString('N'))"
    try {
        New-AdminFolder $stage
        Invoke-WebRequest "https://raw.githubusercontent.com/$repo/$($script:update.Latest)/install.ps1" -OutFile "$stage\install.ps1" -UseBasicParsing -TimeoutSec 20
    }
    catch {
        Remove-Item -LiteralPath $stage -Recurse -Force -ErrorAction SilentlyContinue
        Show-Msg "Could not download the update:`n`n$_" 'Error' | Out-Null; return
    }
    $script:updateStage = $stage   # the installer starts once the window has closed (end of this file)
    $script:updating = $true
    # Started from a popup while the window is already closing: that close goes on (Close now would throw).
    if (-not $script:closing) { $win.Close() }
}
# Creates a folder only Administrators and SYSTEM can open, with that ACL from the start (no gap to swap files in).
function New-AdminFolder($Path) {
    $sec = New-Object Security.AccessControl.DirectorySecurity
    $sec.SetAccessRuleProtection($true, $false)
    $admins = New-Object Security.Principal.SecurityIdentifier 'S-1-5-32-544'
    foreach ($sid in $admins, (New-Object Security.Principal.SecurityIdentifier 'S-1-5-18')) {
        $sec.AddAccessRule((New-Object Security.AccessControl.FileSystemAccessRule($sid, 'FullControl', 'ContainerInherit, ObjectInherit', 'None', 'Allow')))
    }
    $sec.SetOwner($admins)
    if (Test-Path -LiteralPath $Path) { throw "$Path already exists" }
    [IO.Directory]::CreateDirectory($Path, $sec) | Out-Null
}
# Popup once per new version (update-skip.txt remembers a "No"); the Update button stays either way.
function Show-UpdatePopup($Latest, $News) {
    $skip = try { (Get-Content "$root\update-skip.txt" -ErrorAction Stop).Trim() } catch { '' }
    if ($skip -eq $Latest -or $script:job) { return }
    $list = if ($News) { "What's new:`n" + (($News | Select-Object -First 8 | ForEach-Object { "  - $_" }) -join "`n") + $(if (@($News).Count -gt 8) { "`n  ... and $(@($News).Count - 8) more" }) + "`n`n" } else { '' }
    if ((Show-Msg "A new version of the builder is available.`n`n$($list)Update now? The builder restarts; your ISOs, presets and output are kept." 'Information' 'YesNo') -eq 'Yes') { Start-Update }
    else { try { Set-Content "$root\update-skip.txt" $Latest } catch { } }
}
Start-Background {
    param($root, $repo)
    $have = (Get-Content "$root\version.txt" -ErrorAction Stop).Trim()
    $latest = (Invoke-RestMethod "https://api.github.com/repos/$repo/commits/main" -Headers @{ Accept = 'application/vnd.github.sha' } -TimeoutSec 5).Trim()
    if (-not $latest -or $latest -eq $have) { return }
    # Only offer commits whose CI check passed (.github/workflows/check.yml): a broken push never reaches anyone
    $runs = (Invoke-RestMethod "https://api.github.com/repos/$repo/commits/$latest/check-runs?check_name=selftest" -TimeoutSec 5).check_runs
    if (-not @($runs | Where-Object conclusion -eq 'success')) { return }
    # Commit titles since the installed version, newest first (unknown base e.g. after a force push: no list)
    $news = @(try { $c = Invoke-RestMethod "https://api.github.com/repos/$repo/compare/$have...$latest" -TimeoutSec 5; [array]::Reverse($c.commits); $c.commits | ForEach-Object { ($_.commit.message -split "`n")[0] } } catch { })
    [pscustomobject]@{ Latest = $latest; News = $news }   # not a hashtable: $out[0] on one would look up key 0
} $repo {
    param($out)   # empty for a manual install, offline, rate-limited or up to date: no button, no popup
    if (-not ($out -and $out[0].Latest)) { return }   # no version, no button: Update would fetch an empty commit
    $ui.UpdateBtn.Visibility = 'Visible'; $ui.SubTitle.Visibility = 'Collapsed'
    $script:update = $out[0]
    if ($win.IsLoaded) { Show-UpdatePopup $script:update.Latest $script:update.News }
    else { $win.Add_ContentRendered({ Show-UpdatePopup $script:update.Latest $script:update.News }) }
}
# --- Info page ---
# Short commit from install.ps1, stamped on every ISO (label, Win11Ultimate.txt, log); 'dev' for a git checkout.
$toolVersion = if (Test-Path "$root\version.txt") { (Get-Content "$root\version.txt" -Raw).Trim() -replace '^(.{7}).*', '$1' } else { 'dev' }
$ui.InfoVersion.Text = if ($toolVersion -eq 'dev') { 'dev copy (not installed with install.ps1)' } else { $toolVersion }
$ui.InfoFolder.Text = $root
$ui.OpenGitHub.Add_Click({ Start-Process "https://github.com/$repo" })
$ui.OpenFolder.Add_Click({ Start-Process explorer.exe $root })
$ui.UpdateBtn.Add_Click({
        if ((Show-Msg 'Download the newest builder and restart it? Your ISOs and output are kept.' 'Question' 'YesNo') -eq 'Yes') { Start-Update }
    })

# --- Source / languages ---
$ui.IsoFolder.Text = "$root\sources"
$ui.BrowseIso.Add_Click({ Select-Folder $ui.IsoFolder })
# Defaults follow this PC: Windows display language, then region/keyboard; en-us when not in the list.
function Get-DefaultLang($Tag) {
    $t = "$Tag".ToLower()
    @($t; $script:langs -like "$($t.Split('-')[0])-*"; 'en-us'; $script:langs[0]) | Where-Object { $_ -in $script:langs } | Select-Object -First 1
}
# Fills the language lists; choices already made stay (or move to the closest language in the new list).
function Set-Languages($List) {
    $script:langs = @($List)
    foreach ($n in 'BaseLang', 'Keyboard', 'Locale') {
        $was = $ui[$n].SelectedItem; $ui[$n].Items.Clear()
        foreach ($l in $script:langs) { $ui[$n].Items.Add($l) | Out-Null }
        if ($was) { $ui[$n].SelectedItem = Get-DefaultLang $was }
    }
}
Set-Languages $script:langs
$ui.BaseLang.SelectedItem = Get-DefaultLang (Get-UICulture).Name
$region = Get-DefaultLang (Get-Culture).Name; $ui.Keyboard.SelectedItem = $region; $ui.Locale.SelectedItem = $region

# --- Editions ---
$script:edChecks = [ordered]@{}
function Update-Editions {
    # Keep ticks across rescans / language changes; none on start.
    $checked = @($script:edChecks.Keys | Where-Object { $script:edChecks[$_].IsChecked })
    $use = @{ UseUup = [bool]$ui.UseUup.IsChecked }
    $isos = $script:IsoInfos | Where-Object { $_.Lang -eq $ui.BaseLang.SelectedItem -and (Test-UsableIso $_ $use) }
    $names = @($isos | ForEach-Object { $_.Editions.Name } | Where-Object { $_ } | Select-Object -Unique)
    $all = @($names)
    # Microsoft's ISO has the consumer editions only; UUP dump also builds Enterprise.
    $msSource = $ui.Download.SelectedItem.Tag -eq 'Microsoft'
    if ($ui.UseUup.IsChecked) { $all += @($(if ($msSource) { $MsIsoEditions } else { $UupEditions.Keys }) | Where-Object { $_ -notin $names }) }
    $ui.EditionPanel.Children.Clear(); $script:edChecks = [ordered]@{}
    $ui.UupOptions.IsEnabled = [bool]$ui.UseUup.IsChecked; $ui.UupOptions.Opacity = if ($ui.UseUup.IsChecked) { 1 } else { 0.45 }
    $ui.Build.IsEnabled = -not $msSource   # picking a build is UUP-only
    $prevEdition = $ui.Edition.SelectedItem
    $ui.Edition.Items.Clear()
    foreach ($e in $all) {
        $label = if ($e -in $names) { $e } else { "$e  (download)" }
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
    if ($ui.Download.SelectedItem.Tag -eq 'Microsoft') { $ui.BuildHint.Text = 'Microsoft: the newest release as on microsoft.com. Pick UUP dump to choose a build.'; return }
    if ($ui.Build.SelectedIndex -gt 0) { $ui.BuildHint.Text = 'Downloads exactly this build when editions are missing.'; return }
    if ($script:uupLoading) { $ui.BuildHint.Text = 'Loading the build list from UUP dump...'; return }
    try {
        $p = Get-BuildPlan $script:IsoInfos $script:UupBuilds (Get-Config)
        $b = if ($p.Uup) { $p.Uup } elseif ($p.Base) { Select-UupBuild $script:UupBuilds $p.Base.Build } else { $p.Newest }
        $ui.BuildHint.Text = if (-not $b -and $script:uupProblem) { "Auto: UUP dump could not be loaded, only your ISOs are used. $($script:uupProblem)" }
        elseif (-not $b) { 'Auto: UUP dump not reachable, only your ISOs are used.' }
        elseif ($p.Base -and -not $p.Missing) { "Auto = $($b.title)  (not needed now: your ISO has all selected editions)" }
        else { "Auto = $($b.title)" }
    } catch { $ui.BuildHint.Text = 'Auto picks the newest build matching your ISO.' }
}

# --- Patches ---
$patchChecks = @{}; $patchHeads = @{}; $patchHeadText = @{}   # section headers show "on/total"
$patchCols = $ui.PatchCol0, $ui.PatchCol1, $ui.PatchCol2
$colRows = @(0, 0, 0)   # patches per column; each card goes to the shortest column
foreach ($g in $Patches.Values.Group | Select-Object -Unique) {   # catalog order
    $card = New-Object Windows.Controls.Border -Property @{ Style = $win.FindResource('Card'); Margin = '0,0,10,10'; Padding = '14,12' }
    $sp = New-Object Windows.Controls.StackPanel
    $h = New-Object Windows.Controls.TextBlock -Property @{ Text = $g.ToUpper(); Style = $win.FindResource('Section') }
    if ($g -eq 'Aggressive') { $h.Foreground = $win.FindResource('Danger'); $h.Text = 'AGGRESSIVE - CAN BREAK APPS/UPDATES' }
    $patchHeads[$g] = $h; $patchHeadText[$g] = $h.Text
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
# Off: only the switch card shows. On: the options appear and the switch card gets an accent border.
function Set-UnattendBody {
    $on = [bool]$ui.UnattendOn.IsChecked
    $ui.UnattendBody.Visibility = if ($on) { 'Visible' } else { 'Collapsed' }
    $ui.UnattendCard.BorderBrush = $win.FindResource($(if ($on) { 'Accent' } else { 'Line' }))
}
Set-UnattendBody
$ui.UnattendOn.Add_Checked({ Set-UnattendBody }); $ui.UnattendOn.Add_Unchecked({ Set-UnattendBody })
# The install card only turns red while a disk-wiping option is picked.
$diskHintOff = 'Off: you pick the disk in setup as usual. Best SSD and Disk 0 install without asking and wipe that disk.'
$diskHintOn = $ui.DiskHint.Text
function Set-DiskWarning {
    $wipe = [string]$ui.AutoInstall.SelectedItem.Tag -ne 'Off'
    $ui.InstallCard.BorderBrush = $win.FindResource($(if ($wipe) { 'Danger' } else { 'Line' }))
    $ui.DiskHint.Foreground = $win.FindResource($(if ($wipe) { 'Danger' } else { 'Muted' }))
    $ui.DiskHint.Text = if ($wipe) { $diskHintOn } else { $diskHintOff }
}
Set-DiskWarning
$ui.AutoInstall.Add_SelectionChanged({ Set-DiskWarning })

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
    $win.Cursor = 'Wait'; $win.Dispatcher.Invoke([Windows.Threading.DispatcherPriority]::Render, [action] {})
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

# --- Presets: built-in ones, then every .json in the presets folder, then Custom ---
$presetDir = "$root\presets"
New-Item -ItemType Directory -Force $presetDir | Out-Null
$script:applying = $false
$script:filePresets = [ordered]@{}   # list name -> file
# Rebuilt when the list opens, so files dropped into the folder show up. Keeps the selection without re-applying it.
function Update-PresetList {
    $script:applying = $true
    $sel = $ui.Preset.SelectedItem
    $script:filePresets = [ordered]@{}
    foreach ($f in Get-ChildItem $presetDir -Filter *.json -File -ErrorAction SilentlyContinue | Sort-Object BaseName) {
        $n = if ($f.BaseName -in @($Presets.Keys) + 'Custom') { "$($f.BaseName) (file)" } else { $f.BaseName }
        $script:filePresets[$n] = $f.FullName
    }
    $ui.Preset.Items.Clear()
    foreach ($p in @($Presets.Keys) + @($script:filePresets.Keys) + 'Custom') { $ui.Preset.Items.Add($p) | Out-Null }
    $ui.Preset.SelectedItem = if ("$sel" -in @($ui.Preset.Items)) { $sel } else { 'Custom' }
    $script:applying = $false
}
# List name of a preset file, if it is in the presets folder.
function Get-PresetName($Path) { @($script:filePresets.Keys | Where-Object { $script:filePresets[$_] -eq $Path })[0] }
Update-PresetList
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
    foreach ($g in $patchHeads.Keys) { $ids = @($Patches.Keys | Where-Object { $Patches[$_].Group -eq $g }); $patchHeads[$g].Text = "$($patchHeadText[$g])   $(@($ids | Where-Object { $patchChecks[$_].IsChecked }).Count)/$($ids.Count)" }
    $ui.Summary.Text = "$ed editions, $($ui.BaseLang.SelectedItem), $pa patches" + $(if ($ui.UnattendOn.IsChecked) { ', unattended' } else { '' })
    if ($win.IsLoaded) { Update-TopBar }
}
$ui.Preset.Add_SelectionChanged({
        if ($script:applying) { return }
        $n = "$($ui.Preset.SelectedItem)"
        if ($script:filePresets.Contains($n)) { Import-PresetPath $script:filePresets[$n] $n } else { Set-Preset $n }
    })
$ui.Preset.Add_DropDownOpened({ Update-PresetList })
foreach ($c in @($patchChecks.Values) + $ui.SkipOobe + $ui.RunWinUtil) {
    $c.Add_Click({ if (-not $script:applying) { $ui.Preset.SelectedItem = 'Custom' }; Update-Summary })
}

# Preset files: Save writes Get-PresetData as JSON, Load puts the values back into the controls.
function Import-PresetFile($p, $Name) {
    $set = { param($name, $v) if ($null -eq $v) { return }; $c = $ui[$name]
        if ($c -is [Windows.Controls.Primitives.ToggleButton]) { $c.IsChecked = [bool]$v }
        elseif ($c -is [Windows.Controls.ComboBox]) { if ("$v" -in @($c.Items)) { $c.SelectedItem = "$v" } }
        else { $c.Text = "$v" } }
    $script:applying = $true
    foreach ($k in 'UseUup', 'Newest', 'Split', 'QuickCompress', 'DefenderExclude', 'BaseLang') { & $set $k $p.$k }
    $dl = @($ui.Download.Items | Where-Object Tag -eq $p.Download); if ($dl) { $ui.Download.SelectedItem = $dl[0] }   # older presets: keep the current source
    Update-Editions
    if ($p.PSObject.Properties['Editions']) { foreach ($e in $script:edChecks.Keys) { $script:edChecks[$e].IsChecked = $e -in @($p.Editions) } }
    if ($p.PSObject.Properties['Patches']) { foreach ($id in $patchChecks.Keys) { $patchChecks[$id].IsChecked = $id -in @($p.Patches) } }
    $pm = @($ui.PatchMode.Items | Where-Object Tag -eq $p.PatchMode); if ($pm) { $ui.PatchMode.SelectedItem = $pm[0] }   # older presets: keep the current mode
    if ($u = $p.Unattend) {
        foreach ($k in 'UserName', 'AutoLogon', 'ComputerName', 'TimeZone', 'Keyboard', 'Locale', 'SkipOobe', 'RunWinUtil', 'EnableAdmin', 'WifiName') { & $set $k $u.$k }
        & $set 'UnattendOn' $u.Enabled; & $set 'AdminGroup' $u.Admin
        $ui.SkipEdition.IsChecked = [bool]$u.Edition; & $set 'Edition' $u.Edition
        $ai = @($ui.AutoInstall.Items | Where-Object Tag -eq $u.AutoInstall); if ($ai) { $ui.AutoInstall.SelectedItem = $ai[0] }
        $ui.AppPanel.Children.Clear(); foreach ($id in @($u.Apps)) { if ("$id" -match $WingetIdPattern) { Add-App $id $id } }
    }
    $ui.Preset.SelectedItem = if ($Name) { $Name } else { 'Custom' }; $script:applying = $false
    Update-Summary; Update-BuildHint
}
$ui.SavePreset.Add_Click({
        $d = New-Object Windows.Forms.SaveFileDialog -Property @{ Filter = 'Preset (*.json)|*.json'; FileName = 'my-preset.json'; InitialDirectory = $presetDir }
        if ($d.ShowDialog() -ne 'OK') { return }
        Get-PresetData (Get-Config) | ConvertTo-Json -Depth 4 | Set-Content $d.FileName
        Update-PresetList
        if ($n = Get-PresetName $d.FileName) { $script:applying = $true; $ui.Preset.SelectedItem = $n; $script:applying = $false }
    })
function Import-PresetPath($Path, $Name) {
    try { Import-PresetFile (Get-Content $Path -Raw | ConvertFrom-Json) $Name }
    catch {
        $script:applying = $true; $ui.Preset.SelectedItem = 'Custom'; $script:applying = $false
        Show-Msg "Could not load this preset:`n`n$_" 'Error' | Out-Null
    }
}
$ui.LoadPreset.Add_Click({
        $d = New-Object Windows.Forms.OpenFileDialog -Property @{ Filter = 'Preset (*.json)|*.json'; InitialDirectory = $presetDir }
        if ($d.ShowDialog() -eq 'OK') { Update-PresetList; Import-PresetPath $d.FileName (Get-PresetName $d.FileName) } })
$ui.OpenPresets.Add_Click({ Start-Process explorer.exe $presetDir })
# Written on every build start; never loaded automatically (each start uses defaults).
$lastPreset = "$root\last-preset.json"
$ui.LoadLast.Add_Click({ if (Test-Path $lastPreset) { Import-PresetPath $lastPreset } else { Show-Msg 'No build yet.' | Out-Null } })

# Mounts every ISO in the folder, so it runs in the background; builds wait for it (they mount the same ISOs).
$script:scanning = $false
function Invoke-Scan {
    if ($script:scanning) { return }
    $script:scanning = $true; $ui.ScanIsos.IsEnabled = $false; $ui.ScanResult.Text = 'Scanning your ISOs...'
    Start-Background { param($root, $folder) Get-SourceIsos $folder } $ui.IsoFolder.Text {
        param($out, $problems)
        $script:scanning = $false; $ui.ScanIsos.IsEnabled = $true
        if ($script:updateAfterScan) {
            $script:updateAfterScan = $false; Start-Update
            if ($script:updating) { return }   # update failed to start: show this scan as usual
        }
        # Results without a path (a half-blocked scan) would crash the window: skipped, but said so.
        $script:IsoInfos = @($out | Where-Object { $_.Path })
        $skipped = @($out).Count - $script:IsoInfos.Count
        # An ISO that can't be read (or a blocked scan) is listed, never reported as "no ISOs".
        $lines = @($script:IsoInfos | ForEach-Object { "$($_.Lang)  -  build $($_.Build)  -  $($_.Editions.Count) editions  -  $(Split-Path $_.Path -Leaf)" }) +
            @($problems | ForEach-Object { if ($_ -eq $AvBlockedText) { $_ } else { "Could not read $_" } }) +
            @(if ($skipped) { "Skipped $skipped unexpected scan result(s) - scan again if an ISO is missing" })
        $ui.ScanResult.Text = if ($lines) { $lines -join "`n" } else { 'No ISOs found in this folder.' }
        if ($script:IsoInfos -and $script:IsoInfos[0].Lang -in $script:langs) { $ui.BaseLang.SelectedItem = $script:IsoInfos[0].Lang }
        Update-Editions; Update-Storage
        if ($ui.Nav.SelectedItem.Tag -eq 'PageBuild') { Update-Plan }
    }
}
$ui.ScanIsos.Add_Click({ if ($script:job) { Show-Msg 'Wait until the build is finished.' | Out-Null; return }; Invoke-Scan })
$ui.BaseLang.Add_SelectionChanged({ Update-Editions })
$ui.UseUup.Add_Click({ Update-Editions })
$ui.Download.Add_SelectionChanged({ Update-Editions })
$ui.Build.Add_SelectionChanged({ Update-BuildHint })
$ui.Newest.Add_Click({ Update-BuildHint })

# --- Config + validation ---
function Get-Config {
    $uuid = ''
    if ($ui.Build.SelectedIndex -gt 0) { $uuid = $script:buildList[$ui.Build.SelectedIndex - 1].uuid }
    @{
        IsoFolder = $ui.IsoFolder.Text; UseUup = [bool]$ui.UseUup.IsChecked; Newest = [bool]$ui.Newest.IsChecked; Download = [string]$ui.Download.SelectedItem.Tag; UupBuild = $uuid; BaseLang = [string]$ui.BaseLang.SelectedItem
        Editions = @($script:edChecks.Keys | Where-Object { $script:edChecks[$_].IsChecked })
        Patches = @($Patches.Keys | Where-Object { $patchChecks[$_].IsChecked }); PatchMode = [string]$ui.PatchMode.SelectedItem.Tag; DriversPath = $ui.DriversPath.Text
        Unattend = @{
            Enabled = [bool]$ui.UnattendOn.IsChecked; UserName = $ui.UserName.Text.Trim(); Password = $ui.Password.Password
            AutoLogon = [bool]$ui.AutoLogon.IsChecked; Admin = [bool]$ui.AdminGroup.IsChecked; ComputerName = $ui.ComputerName.Text.Trim()
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
        if ($bad = Get-AccountNameError $u.UserName $u.ComputerName) { return $bad, $(if ($bad -like 'Computer*') { 'ComputerName' } else { 'UserName' }) }
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
    # Priority first: with (action, 'Loaded') PowerShell picks BeginInvoke(Delegate, params object[]) -> "Parameter count mismatch".
    $win.Dispatcher.BeginInvoke([Windows.Threading.DispatcherPriority]::Loaded, [action] { $el.BringIntoView(); $el.Focus() | Out-Null }.GetNewClosure()) | Out-Null
    if ($card) {
        $old = $card.BorderBrush; $card.BorderBrush = $win.FindResource('Danger')
        $t = New-Object Windows.Threading.DispatcherTimer -Property @{ Interval = [TimeSpan]::FromSeconds(3) }
        $t.Add_Tick({ $t.Stop(); $card.BorderBrush = $old }.GetNewClosure()); $t.Start()
    }
}

# Minutes for steps 3-9 (Cached = whole image reused, Quick/Max = per edition). Defaults until a build on this PC measured them.
$timingFile = "$root\timing.json"
function Get-Timing {
    $t = @{ Cached = 2; Quick = 6; Max = 8; Setup = 2; Measured = @() }
    try { $j = Get-Content $timingFile -Raw -ErrorAction Stop | ConvertFrom-Json; foreach ($k in $j.PSObject.Properties.Name) { $t[$k] = [double]$j.$k; $t.Measured += $k } } catch { }
    $t
}
function Save-Timing($Key, [double]$Minutes) {
    $t = Get-Timing; $o = [ordered]@{}; foreach ($k in $t.Measured + $Key | Select-Object -Unique) { $o[$k] = $t[$k] }
    $o[$Key] = [math]::Round($Minutes, 1); $o | ConvertTo-Json | Set-Content $timingFile
}

# --- Plan (same decision logic as the build) ---
# Plan card pieces: a coloured notice, a big number with a caption, and a label/value row.
function Add-PlanNotice($Text, $Color) {
    $tb = New-Object Windows.Controls.TextBlock -Property @{ Text = $Text; TextWrapping = 'Wrap'; Foreground = $Color }
    $ui.PlanPanel.Children.Add((New-Object Windows.Controls.Border -Property @{
                Child = $tb; BorderBrush = $Color; BorderThickness = '3,0,0,0'; Padding = '10,6'; Margin = '0,0,0,10'; Background = $brush.Dark })) | Out-Null
}
function New-PlanStat($Value, $Caption, $Color) {
    $sp = New-Object Windows.Controls.StackPanel -Property @{ Margin = '0,0,0,14' }
    $sp.Children.Add((New-Object Windows.Controls.TextBlock -Property @{ Text = $Value; FontSize = 22; FontWeight = 'SemiBold'; Foreground = $Color })) | Out-Null
    $sp.Children.Add((New-Object Windows.Controls.TextBlock -Property @{ Text = $Caption; FontSize = 12; Foreground = $brush.Muted })) | Out-Null
    $sp
}
function Add-PlanRow($Label, $Value, $Hint) {
    $row = New-Object Windows.Controls.DockPanel -Property @{ Margin = '0,0,0,8' }
    $l = New-Object Windows.Controls.TextBlock -Property @{ Text = $Label; Width = 90; Foreground = $brush.Muted }
    [Windows.Controls.DockPanel]::SetDock($l, 'Left'); $row.Children.Add($l) | Out-Null
    $v = New-Object Windows.Controls.TextBlock -Property @{ TextWrapping = 'Wrap'; Foreground = $brush.Text }
    $v.Inlines.Add((New-Object Windows.Documents.Run $Value)) | Out-Null
    if ($Hint) { $v.Inlines.Add((New-Object Windows.Documents.Run "  $Hint" -Property @{ Foreground = $brush.Muted; FontSize = 12 })) | Out-Null }
    $row.Children.Add($v) | Out-Null
    $ui.PlanRows.Children.Add($row) | Out-Null
}

function Update-Plan {
    foreach ($c in $ui.PlanPanel, $ui.PlanRows, $ui.PlanStats) { $c.Children.Clear() }
    try {
        $cfg = Get-Config
        if (-not $cfg.Editions) { Add-PlanNotice 'Pick at least one edition on the Source page.' $brush.Warn; return }
        $p = Get-BuildPlan $script:IsoInfos $script:UupBuilds $cfg
        if ($p.Error) { Add-PlanNotice "Can't build yet: $($p.Error)" $brush.Danger }
        if ($p.Note) { Add-PlanNotice ($p.Note -replace '^NOTE: ', '') $brush.Warn }
        if ($p.Skipped) { Add-PlanNotice "$($p.Skipped.title) is newer than the version picked automatically, but it's not known whether every PC gets it. To use it, pick it under 'Windows version' on the Source page." $brush.Warn }
        if ($script:scanning) { Add-PlanNotice 'Still scanning your ISOs - the plan updates when done.' $brush.Muted }
        if ($script:uupLoading -and $cfg.UseUup) { Add-PlanNotice 'Still loading the Windows versions from UUP dump - the plan updates when done.' $brush.Muted }
        if ($script:uupProblem -and -not $script:UupBuilds -and $cfg.UseUup) { Add-PlanNotice "UUP dump could not be loaded: $($script:uupProblem)" $brush.Warn }

        # Same cache check as the build. Image time (steps 3-9) is measured on this PC after each build.
        $cachePath = if ($p.Base -and -not $p.Missing) { Get-ImageCachePath $cfg @($cfg.Editions | ForEach-Object { @{ Iso = $p.Base.Path; Name = $_ } }) }
        $cached = $cachePath -and (Test-Path $cachePath)
        $script:planKey = if ($cached) { 'Cached' } elseif ($cfg.PatchMode -eq 'Setup') { 'Setup' } elseif ($cfg.QuickCompress) { 'Quick' } else { 'Max' }; $script:planEds = $cfg.Editions.Count
        $t = Get-Timing
        $img = $t.($script:planKey) * $(if ($cached) { 1 } else { $script:planEds })   # steps 3-9
        $dl = if ($p.Microsoft) { 20 } elseif ($p.Missing) { 60 } else { 0 }          # step 2
        $min = 1 + [math]::Ceiling($img) + $dl
        # Minutes per step for the progress bar and the time left. Shares of steps 3-9 come from real builds:
        # patching is the longest step, compression only matters at max compression, a cached image mostly writes the ISO.
        $share = switch ($script:planKey) { Cached { 0.05, 0.05, 0.05, 0.05, 0.05, 0.6, 0.15 } Setup { 0.6, 0.01, 0.01, 0.03, 0.01, 0.3, 0.04 } Quick { 0.27, 0.5, 0.06, 0.01, 0.04, 0.1, 0.02 } default { 0.2, 0.37, 0.05, 0.01, 0.27, 0.08, 0.02 } }
        $script:planSteps = @(0.2, ($dl + 0.8)) + @($share | ForEach-Object { $_ * $img })
        $need = Get-NeededGB $cached; $free = [math]::Round((Get-PSDrive $root.Substring(0, 1)).Free / 1GB)

        $how = $(if ($cached) { 'reuses your last build' } elseif ($t.Measured -contains $script:planKey) { 'measured on this PC' } else { 'estimate' })
        $ui.PlanStats.Children.Add((New-PlanStat "~$min min" "build time, $how" $brush.Text)) | Out-Null
        $ui.PlanStats.Children.Add((New-PlanStat "$need GB" "disk space, $free GB free on $($root.Substring(0, 2))" $(if ($free -lt $need) { $brush.Danger } else { $brush.Text }))) | Out-Null
        if ($free -lt $need) { Add-PlanNotice "Not enough disk space: free up $($need - $free) GB on $($root.Substring(0, 2))." $brush.Danger }

        if ($p.Base) {
            $ver = Get-ReleaseVersion (Select-UupBuild $script:UupBuilds $p.Base.Build)
            Add-PlanRow 'Windows' "Your ISO, $(if ($ver) { "$ver, " })build $($p.Base.Build)" (Split-Path $p.Base.Path -Leaf)
        }
        if ($p.Missing -and $p.Uup) {
            Add-PlanRow 'Windows' "$($p.Uup.title)" 'download incl. the latest update'
        }
        if ($p.Microsoft) {
            Add-PlanRow 'Windows' "Official Microsoft ISO$(if ($v = Get-ReleaseVersion $p.Newest) { ", $v" })" $(if ($p.Missing) { 'download, the latest update installs after setup' } else { 'download if newer than your ISO' })
        }
        Add-PlanRow 'Editions' ($cfg.Editions -join ', ')
        Add-PlanRow 'Language' $cfg.BaseLang
        Add-PlanRow 'Patches' "$($cfg.Patches.Count) selected" $(if ($cfg.PatchMode -eq 'Setup') { 'applied during Windows setup' } else { 'applied into the image' })
        $setup = if (-not $cfg.Unattend.Enabled) { 'Normal Windows setup' } elseif ($cfg.Unattend.AutoInstall -eq 'BestSsd') { 'Installs by itself onto the best SSD' } elseif ($cfg.Unattend.AutoInstall -eq 'Disk0') { 'Installs by itself onto disk 0 (wipes it)' } else { 'Unattended: account and settings preset' }
        Add-PlanRow 'Setup' $setup
    } catch { Add-PlanNotice "Plan not available: $_" $brush.Danger }
}

# --- Storage ---
function Get-FolderGB($Path) {
    if (-not (Test-Path $Path)) { return 0 }
    [math]::Round(((Get-ChildItem $Path -Recurse -File -Force -ErrorAction SilentlyContinue | Measure-Object Length -Sum).Sum) / 1GB, 1)
}
# UUP downloads (they have a .build sidecar) replaced by a newer ISO of the same language and editions. Your own ISOs are never touched.
function Get-OldDownloads {
    $script:IsoInfos | Where-Object { Test-Path "$($_.Path).build" } | Where-Object {
        $i = $_; $script:IsoInfos | Where-Object { $_.Lang -eq $i.Lang -and [int]$_.Build -gt [int]$i.Build -and -not (Compare-Object @($_.Editions.Name) @($i.Editions.Name)) } }
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
# Same 9 steps as Enter-Step in lib\Build.ps1.
$steps = @(
    @{ Name = 'Preflight'; Desc = 'Checking admin rights, disk space and build tools' }
    @{ Name = 'Sources'; Desc = 'Reading your ISOs, downloading from UUP dump if needed' }
    @{ Name = 'Editions'; Desc = 'Exporting the selected editions' }
    @{ Name = 'Patches'; Desc = 'Mounting every edition and applying your patches' }
    @{ Name = 'Setup (boot.wim)'; Desc = 'Patching setup to skip the hardware checks' }
    @{ Name = 'Unattended'; Desc = 'Writing the answer file and setup scripts' }
    @{ Name = 'Compress'; Desc = 'Compressing the final image' }
    @{ Name = 'Create ISO'; Desc = 'Writing the bootable ISO' }
    @{ Name = 'Finish'; Desc = 'Saving your settings and cleaning up' })
function Format-Clock([timespan]$T) { if ($T.TotalHours -ge 1) { '{0:h\:mm\:ss}' -f $T } else { '{0:m\:ss}' -f $T } }
function New-Brush($Hex) { $b = [Windows.Media.BrushConverter]::new().ConvertFromString($Hex); $b.Freeze(); $b }
$brush = @{ Text = $win.FindResource('Text'); Muted = $win.FindResource('Muted'); Line = $win.FindResource('Line'); Card = $win.FindResource('CardBg')
    Accent = $win.FindResource('Accent'); Success = $win.FindResource('Success'); Danger = $win.FindResource('Danger'); Warn = $win.FindResource('Warn')
    Dark = New-Brush '#0E1014'; Dim = New-Brush '#5C6575'; LogText = New-Brush '#B9C2D0' }
$iconFont = New-Object Windows.Media.FontFamily 'Segoe Fluent Icons, Segoe MDL2 Assets'

# Step list: a dot per step (number, pulsing while active, check when done, cross when failed) joined by a line.
$script:stepRows = @()
for ($i = 1; $i -le 9; $i++) {
    $row = New-Object Windows.Controls.DockPanel
    $rail = New-Object Windows.Controls.Grid -Property @{ Width = 22 }
    $line = New-Object Windows.Shapes.Rectangle -Property @{ Width = 2; Fill = $brush.Line; Margin = '0,22,0,0'; Visibility = $(if ($i -eq 9) { 'Hidden' } else { 'Visible' }) }
    $scale = New-Object Windows.Media.ScaleTransform
    $halo = New-Object Windows.Shapes.Ellipse -Property @{ Width = 20; Height = 20; Fill = $brush.Accent; Opacity = 0; VerticalAlignment = 'Top'; RenderTransformOrigin = '0.5,0.5'; RenderTransform = $scale }
    $mark = New-Object Windows.Controls.TextBlock -Property @{ FontSize = 10; HorizontalAlignment = 'Center'; VerticalAlignment = 'Center' }
    $dot = New-Object Windows.Controls.Border -Property @{ Width = 20; Height = 20; CornerRadius = 10; BorderThickness = 1.5; VerticalAlignment = 'Top'; Child = $mark }
    foreach ($c in $line, $halo, $dot) { $rail.Children.Add($c) | Out-Null }
    [Windows.Controls.DockPanel]::SetDock($rail, 'Left')
    $time = New-Object Windows.Controls.TextBlock -Property @{ FontSize = 11; Margin = '8,2,0,0'; Foreground = $brush.Muted }
    [Windows.Controls.DockPanel]::SetDock($time, 'Right')
    $name = New-Object Windows.Controls.TextBlock -Property @{ Text = $steps[$i - 1].Name; Margin = '10,1,0,0'; TextTrimming = 'CharacterEllipsis'; TextWrapping = 'NoWrap' }
    foreach ($c in $rail, $time, $name) { $row.Children.Add($c) | Out-Null }
    $ui.StepList.Children.Add($row) | Out-Null
    $script:stepRows += @{ N = $i; Line = $line; Halo = $halo; Scale = $scale; Dot = $dot; Mark = $mark; Name = $name; Time = $time }
}
# The page fills the window, but the step/log row keeps room for 9 readable steps (26px each plus card header);
# below that the page gets a scrollbar instead of squeezing the steps.
function Set-BuildMinHeight {
    $min = [math]::Ceiling($ui.BuildBody.ActualHeight - $ui.BuildBottom.ActualHeight) + 9 * 26 + 70
    if ([math]::Abs($ui.BuildBody.MinHeight - $min) -gt 1) { $ui.BuildBody.MinHeight = $min }
}
$ui.BuildBody.Add_SizeChanged({ Set-BuildMinHeight })
$ui.BuildBottom.Add_SizeChanged({ Set-BuildMinHeight })
function Set-StepState($I, $State, $Time) {
    $r = $script:stepRows[$I - 1]
    $r.Halo.BeginAnimation([Windows.UIElement]::OpacityProperty, $null)
    foreach ($p in [Windows.Media.ScaleTransform]::ScaleXProperty, [Windows.Media.ScaleTransform]::ScaleYProperty) { $r.Scale.BeginAnimation($p, $null) }
    # dot fill, dot border, mark text, mark color, name color, line color
    $look = switch ($State) {
        'active' { $brush.Accent, $brush.Accent, "$I", $brush.Dark, $brush.Text, $brush.Line }
        'done' { $brush.Success, $brush.Success, [string][char]0xE73E, $brush.Dark, $brush.Text, $brush.Success }
        'failed' { $brush.Danger, $brush.Danger, [string][char]0xE711, $brush.Dark, $brush.Danger, $brush.Line }
        default { $brush.Card, $brush.Line, "$I", $brush.Muted, $brush.Muted, $brush.Line }
    }
    $r.Dot.Background = $look[0]; $r.Dot.BorderBrush = $look[1]; $r.Mark.Text = $look[2]; $r.Mark.Foreground = $look[3]
    $r.Mark.FontFamily = if ($State -in 'done', 'failed') { $iconFont } else { $win.FontFamily }
    $r.Name.Foreground = $look[4]; $r.Line.Fill = $look[5]
    $r.Name.FontWeight = if ($State -eq 'active') { 'SemiBold' } else { 'Normal' }
    if ($State -eq 'pending') { $r.Time.Text = '' } elseif ($Time) { $r.Time.Text = Format-Clock $Time }
    if ($State -eq 'active') {
        $r.Dot.BringIntoView()   # the list scrolls on small windows
        $d =[Windows.Duration][TimeSpan]::FromSeconds(1.6); $forever = [Windows.Media.Animation.RepeatBehavior]::Forever
        $r.Halo.BeginAnimation([Windows.UIElement]::OpacityProperty, (New-Object Windows.Media.Animation.DoubleAnimation ([double]0.5), ([double]0), $d -Property @{ RepeatBehavior = $forever }))
        foreach ($p in [Windows.Media.ScaleTransform]::ScaleXProperty, [Windows.Media.ScaleTransform]::ScaleYProperty) {
            $r.Scale.BeginAnimation($p, (New-Object Windows.Media.Animation.DoubleAnimation ([double]1), ([double]2), $d -Property @{ RepeatBehavior = $forever; DecelerationRatio = 1 }))
        }
    }
}
1..9 | ForEach-Object { Set-StepState $_ 'pending' }

# Log: dim time, step headers in blue, warnings amber, errors red, DONE green. Follows new lines unless scrolled up.
function Add-LogLine([string]$Text, $Color) {
    $atEnd = $ui.Log.VerticalOffset + $ui.Log.ViewportHeight -ge $ui.Log.ExtentHeight - 24
    $p = New-Object Windows.Documents.Paragraph
    $msg = $Text
    if ($Text -match '^(\[\d\d:\d\d:\d\d\]) (.*)$') {
        $p.Inlines.Add((New-Object Windows.Documents.Run "$($Matches[1])  " -Property @{ Foreground = $brush.Dim })); $msg = $Matches[2]
    }
    $run = New-Object Windows.Documents.Run $msg
    $run.Foreground = if ($Color) { $Color } elseif ($msg -match '^== ') { $brush.Accent } elseif ($msg -match '^\s*(ERROR|FAILED)|^Result:\s+FAILED') { $brush.Danger }
        elseif ($msg -match '^\s*(WARN|NOTE)') { $brush.Warn } elseif ($msg -match '^DONE|^Result:\s+OK') { $brush.Success } else { $brush.LogText }
    if ($msg -match '^== |^DONE') { $run.FontWeight = 'SemiBold'; $p.Margin = '0,10,0,2' }
    $p.Inlines.Add($run)
    $ui.Log.Document.Blocks.Add($p)
    if ($atEnd) { $ui.Log.ScrollToEnd() }
}

# nussico banner at the top of the log (GUI only, not written to build-log.txt).
$banner = @'
                           _
 _ __   _   _  ___   ___  (_)   ___    ___
| '_ \ | | | |/ __| / __| | |  / __|  / _ \
| | | || |_| |\__ \ \__ \ | | | (__  | (_) |
|_| |_| \__,_||___/ |___/ |_|  \___|  \___/
'@
function Show-Banner {
    foreach ($l in $banner -split "`r?`n") {
        $p = New-Object Windows.Documents.Paragraph -Property @{ Margin = '0'; LineHeight = 15; LineStackingStrategy = 'BlockLineHeight' }
        $p.Inlines.Add((New-Object Windows.Documents.Run $l -Property @{ Foreground = $brush.Accent; FontWeight = 'SemiBold' }))
        $ui.Log.Document.Blocks.Add($p)
    }
    Add-LogLine "Win11 Ultimate ISO Builder $toolVersion  -  github.com/$repo" $brush.Dim
}
Show-Banner

# Status card look: idle / running / done / failed / cancelled.
function Set-BuildStatus($State, $Title, $Text) {
    $ui.StepTitle.Text = $Title; $ui.StepText.Text = $Text
    $ui.StatusCard.BorderBrush = switch ($State) { 'running' { $brush.Accent } 'done' { $brush.Success } 'failed' { $brush.Danger } 'cancelled' { $brush.Warn } default { $brush.Line } }
    $ui.Progress.Tag = switch ($State) { 'running' { 'running' } 'done' { 'done' } { $_ -in 'failed', 'cancelled' } { 'error' } default { $null } }
    $ui.OpenResult.Visibility = if ($State -eq 'done') { 'Visible' } else { 'Collapsed' }
}
$ui.OpenResult.Add_Click({ if (Test-Path $script:buildOutput) { Start-Process explorer.exe "/select,`"$script:buildOutput`"" } })

$timer.Add_Tick({
        $line = $null
        while ($script:sync.Log.TryDequeue([ref]$line)) { Add-LogLine $line }
        $s = [math]::Min(9, $script:sync.Step); $now = Get-Date
        if ($s -ne $script:shownStep) {
            # The previous step (and any never shown in between) is done.
            for ($i = [math]::Max(1, $script:shownStep); $i -lt $s; $i++) { Set-StepState $i 'done' $(if ($script:stepStarts[$i]) { $now - $script:stepStarts[$i] }) }
            $script:shownStep = $s; $script:stepStarts[$s] = $now
            if ($s -eq 3) { $script:imageStart = $now }   # after the download, so the measured time is this PC's own speed
            Set-StepState $s 'active'
            Set-BuildStatus 'running' $steps[$s - 1].Name "Step $s of 9  -  $($steps[$s - 1].Desc)"
        }
        # Bar and time left both come from the planned minutes per step, so they agree: the bar is the share of the
        # planned time done, and a step that runs long stalls the bar near its end instead of counting down past zero.
        $elapsed = $now - $script:buildStart
        $ui.Elapsed.Text = Format-Clock $elapsed
        $v = 0
        if ($s -gt 0) {
            $inStep = ($now - $script:stepStarts[$s]).TotalMinutes
            $script:stepRows[$s - 1].Time.Text = Format-Clock ($now - $script:stepStarts[$s])
            $plan = $script:run.Steps; $total = ($plan | Measure-Object -Sum).Sum
            $done = ($plan[0..($s - 1)] | Measure-Object -Sum).Sum - $plan[$s - 1]
            $here = [math]::Min($inStep, 0.95 * $plan[$s - 1])
            $v = 9 * ($done + $here) / $total
            $left = $total - $done - $plan[$s - 1] + [math]::Max($plan[$s - 1] - $inStep, 0.1 * $plan[$s - 1])
            $ui.Eta.Text = if ($left -ge 1.5) { "elapsed  -  about $([math]::Round($left)) min left" } else { 'elapsed  -  almost done' }
        }
        $ui.Progress.Value = $v
        $win.TaskbarItemInfo.ProgressState = 'Normal'; $win.TaskbarItemInfo.ProgressValue = $v / 9
        if ($script:sync.Done -or $script:job.Handle.IsCompleted) {
            if (-not $script:sync.Done -and -not $script:sync.Error) { $script:sync.Error = 'The build stopped unexpectedly. See the log.' }
            while ($script:sync.Log.TryDequeue([ref]$line)) { Add-LogLine $line }
            foreach ($e in $script:job.PS.Streams.Error) { Add-LogLine "ERROR: $e" }
            $timer.Stop()
            try { $script:job.PS.EndInvoke($script:job.Handle) } catch { Add-LogLine "$_" $brush.Danger }
            $script:job.PS.Runspace.Close(); $script:job.PS.Dispose(); $script:job = $null
            $ui.BuildBtn.Content = 'Build ISO'; $ui.BuildBtn.Tag = $null; $ui.BuildBtn.IsEnabled = $true
            $win.TaskbarItemInfo.ProgressState = if ($script:sync.Error) { 'Error' } else { 'None' }; $win.TaskbarItemInfo.ProgressValue = 1
            if (-not $win.IsActive) { [W11.Native]::Flash((New-Object Windows.Interop.WindowInteropHelper $win).Handle) }
            $ui.Eta.Text = 'total time'
            Update-Storage
            if ($script:sync.Error -eq 'Cancelled by user') {
                if ($s -gt 0) { Set-StepState $s 'failed' ($now - $script:stepStarts[$s]) }
                Set-BuildStatus 'cancelled' 'Build cancelled' "Stopped in step $s. Click Build ISO to start again."
            } elseif ($script:sync.Error) {
                if ($s -gt 0) { Set-StepState $s 'failed' ($now - $script:stepStarts[$s]) }
                Set-BuildStatus 'failed' 'Build failed' "$($script:sync.Error)  -  details in build-log.txt next to the ISO."
                Show-Msg "Build failed:`n$($script:sync.Error)`n`nDetails: build-log.txt next to the ISO." 'Error' | Out-Null
            } else {
                if ($script:imageStart -and $script:run.Key) { Save-Timing $script:run.Key (((Get-Date) - $script:imageStart).TotalMinutes / $(if ($script:run.Key -eq 'Cached') { 1 } else { $script:run.Eds })) }
                Set-StepState 9 'done' ($now - $script:stepStarts[9]); $ui.Progress.Value = 9
                $size = try { " ($([math]::Round((Get-Item $script:buildOutput).Length / 1GB, 1)) GB)" } catch { '' }
                Set-BuildStatus 'done' 'ISO ready' "$script:buildOutput$size"
            }
        }
    })

# What the automatic install would erase if this PC booted the ISO: runs autoinstall.js itself (same rules), read-only.
function Get-WipePreview($Mode) {
    $f = Join-Path $env:TEMP 'w11-wipe-preview.js'
    try {
        Set-Content $f ("var PREVIEW = true;`r`n" + (Get-Content "$root\lib\autoinstall.js" -Raw)) -Encoding ASCII
        $out = @(cscript //nologo //E:jscript $f)
    } catch { return "On THIS PC: could not read the disks ($_)." } finally { Remove-Item $f -ErrorAction SilentlyContinue }
    $disks = @($out | Select-Object -Skip 1 | Sort-Object)
    $pick = if ($Mode -eq 'Disk0') { $disks -like 'Disk 0:*' } elseif ($out[0] -like 'PICK *') { $out[0].Substring(5) }
    $head = if ($pick) { "On THIS PC it would erase:`n  $pick" } else { 'On THIS PC: no single best disk, normal setup would open (nothing erased).' }
    "$head`n`nDisks in this PC:`n  $($disks -join "`n  ")`n(Disk numbers can differ when booted from the USB stick.)"
}

$ui.BuildBtn.Add_Click({
        if ($script:job) {
            $script:sync.Cancel = $true; $ui.BuildBtn.IsEnabled = $false
            Add-LogLine 'Cancelling after the current operation...' $brush.Warn
            $ui.StepText.Text = 'Cancelling after the current operation...'; return
        }
        if ($script:scanning) { Show-Msg 'Wait until the ISO scan is finished.' | Out-Null; return }
        $cfg = Get-Config
        $err, $field = Test-Config $cfg
        if ($err) { Show-Field $field; Show-Msg $err 'Warning' | Out-Null; return }
        if ($cfg.Unattend.Enabled -and $cfg.Unattend.AutoInstall -ne 'Off') {
            $what = if ($cfg.Unattend.AutoInstall -eq 'Disk0') { 'DISK 0 of any PC booted from this ISO will be ERASED without asking.' }
                    else { 'Any PC booted from this ISO with one clear best disk will have that disk ERASED after a 10 second countdown.' }
            if ((Show-Msg "Automatic install is ON.`n`n$what`n`n$(Get-WipePreview $cfg.Unattend.AutoInstall)`n`nBuild anyway?" 'Warning' 'YesNo') -ne 'Yes') { return }
        }
        Get-PresetData $cfg | ConvertTo-Json -Depth 4 | Set-Content $lastPreset
        try { Hyper-V\Get-VMDvdDrive -VMName $vmName -ErrorAction Stop | Where-Object Path -eq $cfg.Output | Hyper-V\Set-VMDvdDrive -Path $null } catch { }
        $ui.Log.Document.Blocks.Clear(); Show-Banner; $ui.Progress.Value = 0; $script:shownStep = 0; $script:stepStarts = @{}; $script:buildStart = Get-Date
        1..9 | ForEach-Object { Set-StepState $_ 'pending' }
        $script:buildOutput = $cfg.Output; $ui.Elapsed.Text = '0:00'; $ui.Eta.Text = ''
        Set-BuildStatus 'running' 'Starting...' 'Preparing the build'
        # Snapshot the plan: switching to this page re-plans, and once step 7 writes the cache the plan would say "Cached".
        $script:imageStart = $null; $script:planKey = $null; $script:planSteps = @(1) * 9; Update-Plan
        $script:run = @{ Key = $script:planKey; Eds = $script:planEds; Steps = $script:planSteps }
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

$script:closing = $false
$win.Add_Closing({
        param($s, $e)
        $script:closing = $true
        try {
            if ($script:job) { $e.Cancel = $true; Show-Msg 'A build is running. Cancel it first.' | Out-Null; return }
            # Closing mid-scan would leave an ISO mounted. If the scan ends while this message is open and starts a
            # pending update, close after all.
            if ($script:scanning) { $e.Cancel = $true; Show-Msg 'Scanning your ISOs. Close again in a moment.' | Out-Null; $e.Cancel = -not $script:updating; return }
        }
        finally { $script:closing = $false }
    })

$ui.Preset.SelectedItem = 'Basic'
Update-Editions
$win.Add_ContentRendered({ Invoke-Scan })
$win.ShowDialog() | Out-Null

if ($script:updating) {
    # Free the one-builder lock now, so the builder the installer starts is not taken for this one.
    try { $instance.ReleaseMutex() } catch { }
    # Paths go in through the environment, so no quoting can break the command. It waits for this process to end,
    # keeps a failure on screen, starts this (unchanged) builder again if the install failed, and cleans up.
    $env:W11UB_DIR = $root   # installer updates this folder instead of asking for a drive
    $env:W11UB_SHA = $script:update.Latest   # exactly the commit that passed CI, not whatever main is by now
    $env:W11UB_STAGE = $script:updateStage
    $env:W11UB_WAIT = $PID
    $run = 'Wait-Process -Id $env:W11UB_WAIT -Timeout 30 -ErrorAction SilentlyContinue; ' +
    'try { & (Join-Path $env:W11UB_STAGE install.ps1) } ' +
    'catch { Write-Host $_ -ForegroundColor Red; Write-Host ''Starting the old builder again.''; ' +
    'Start-Process conhost.exe -WorkingDirectory $env:W11UB_DIR -ArgumentList ''--headless powershell.exe -NoProfile -ExecutionPolicy Bypass -STA -File .\Builder.ps1''; ' +
    'Read-Host ''Update failed. Press Enter to close'' } ' +
    'finally { Remove-Item -LiteralPath $env:W11UB_STAGE -Recurse -Force -ErrorAction SilentlyContinue }'
    Start-Process powershell.exe -ArgumentList "-NoProfile -ExecutionPolicy Bypass -Command `"$run`""
}
