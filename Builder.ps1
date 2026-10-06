# Win11 Ultimate ISO Builder - GUI entry point.
$isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole('Administrators')
if (-not $isAdmin) {
    Start-Process powershell.exe -Verb RunAs -ArgumentList "-NoProfile -ExecutionPolicy Bypass -STA -File `"$PSCommandPath`""
    exit
}

$root = $PSScriptRoot
. "$root\lib\Patches.ps1"; . "$root\lib\Unattend.ps1"; . "$root\lib\Source.ps1"
Add-Type -AssemblyName System.Windows.Forms, System.Drawing
[Windows.Forms.Application]::EnableVisualStyles()

function New-Ctl($Type, $Props = @{}) {
    $c = New-Object "System.Windows.Forms.$Type"
    foreach ($k in $Props.Keys) { $c.$k = $Props[$k] }
    $c
}
function New-Row { $r = New-Ctl FlowLayoutPanel @{ AutoSize = $true; WrapContents = $false }; $r.Controls.AddRange(@($args)); $r }
function New-Lbl($Text, $W = 0) { if ($W) { New-Ctl Label @{ Text = $Text; Width = $W; TextAlign = 'MiddleLeft' } } else { New-Ctl Label @{ Text = $Text; AutoSize = $true } } }
function New-Page($Tabs, $Title) {
    $p = New-Ctl FlowLayoutPanel @{ FlowDirection = 'TopDown'; Dock = 'Fill'; AutoScroll = $true; WrapContents = $false; Padding = '8,8,8,8' }
    $t = New-Ctl TabPage @{ Text = $Title }; $t.Controls.Add($p); $Tabs.TabPages.Add($t); $p
}
function Select-Folder($Box) { $d = New-Ctl FolderBrowserDialog; if ($d.ShowDialog() -eq 'OK') { $Box.Text = $d.SelectedPath } }

# --- UUP data (best effort; offline still works with own ISOs) ---
$script:UupBuilds = @()
$langs = @('ar-sa', 'cs-cz', 'da-dk', 'de-de', 'en-gb', 'en-us', 'es-es', 'fr-fr', 'it-it', 'ja-jp', 'ko-kr', 'nl-nl', 'pl-pl', 'pt-br', 'ru-ru', 'sv-se', 'tr-tr', 'uk-ua', 'zh-cn')
try {
    $script:UupBuilds = Get-UupBuilds
    $langs = Get-UupLanguages (Select-UupBuild $script:UupBuilds '26200').uuid
} catch { }
$script:IsoInfos = @()

$form = New-Ctl Form @{ Text = 'Win11 Ultimate ISO Builder'; Size = '900,720'; StartPosition = 'CenterScreen'; Font = New-Object Drawing.Font('Segoe UI', 9) }
$top = New-Ctl FlowLayoutPanel @{ Dock = 'Top'; Height = 36; Padding = '8,6,0,0' }
$cmbPreset = New-Ctl ComboBox @{ DropDownStyle = 'DropDownList'; Width = 160 }
$cmbPreset.Items.AddRange(@($Presets.Keys) + 'Custom')
$top.Controls.AddRange(@((New-Lbl 'Preset:' 50), $cmbPreset))
$tabs = New-Ctl TabControl @{ Dock = 'Fill' }
$form.Controls.Add($tabs); $form.Controls.Add($top)

# --- Source & Languages ---
$p = New-Page $tabs 'Source & Languages'
$txtIso = New-Ctl TextBox @{ Width = 450; Text = "$root\sources" }
$btnIsoBrowse = New-Ctl Button @{ Text = 'Browse' }; $btnIsoBrowse.Add_Click({ Select-Folder $txtIso })
$btnScan = New-Ctl Button @{ Text = 'Scan ISOs' }
$lblScan = New-Ctl Label @{ AutoSize = $true; Text = 'Drop official ISOs into the folder and click Scan.' }
$chkUup = New-Ctl CheckBox @{ Text = 'Download missing parts via UUP dump'; AutoSize = $true; Checked = $true }
$cmbBuild = New-Ctl ComboBox @{ DropDownStyle = 'DropDownList'; Width = 330 }
$buildList = @($script:UupBuilds | Where-Object title -like 'Windows 11, version*' | Sort-Object { [version]"10.0.$($_.build)" } -Descending | Select-Object -First 15)
$cmbBuild.Items.Add('Auto (latest matching your ISO)') | Out-Null
foreach ($b in $buildList) { $cmbBuild.Items.Add($b.title) | Out-Null }
$cmbBuild.SelectedIndex = 0
$cmbBase = New-Ctl ComboBox @{ DropDownStyle = 'DropDownList'; Width = 120 }
$cmbBase.Items.AddRange($langs); $cmbBase.SelectedItem = $(if ($langs -contains 'de-de') { 'de-de' } else { $langs[0] })
$clbLangs = New-Ctl CheckedListBox @{ Width = 820; Height = 260; CheckOnClick = $true; MultiColumn = $true; ColumnWidth = 100 }
$clbLangs.Items.AddRange($langs)
if ($langs -contains 'en-us') { $clbLangs.SetItemChecked($clbLangs.Items.IndexOf('en-us'), $true) }
$p.Controls.AddRange(@(
        (New-Row (New-Lbl 'ISO folder' 80) $txtIso $btnIsoBrowse $btnScan), $lblScan,
        (New-Row $chkUup (New-Lbl 'Build:' 40) $cmbBuild),
        (New-Row (New-Lbl 'Base language' 100) $cmbBase),
        (New-Lbl 'Language packs (added to every edition, pick the language in Windows setup / Settings):'), $clbLangs))

# --- Editions ---
$p = New-Page $tabs 'Editions'
$clbEd = New-Ctl CheckedListBox @{ Width = 500; Height = 400; CheckOnClick = $true }
$p.Controls.AddRange(@((New-Lbl 'Editions from your ISO for the base language; "(UUP)" = built via UUP dump.'), $clbEd))
$defaultEditions = 'Windows 11 Home', 'Windows 11 Pro', 'Windows 11 Education'
function Get-EditionName($Item) { $Item -replace ' \(UUP\)$', '' }
function Update-Editions {
    $checked = @($clbEd.CheckedItems | ForEach-Object { Get-EditionName $_ })
    if (-not $clbEd.Items.Count) { $checked = $defaultEditions }
    $iso = $script:IsoInfos | Where-Object Lang -eq $cmbBase.SelectedItem | Select-Object -First 1
    $names = @($iso.Editions.Name | Where-Object { $_ })
    $items = @($names)
    if ($chkUup.Checked) { $items += $UupEditions.Keys | Where-Object { $_ -notin $names } | ForEach-Object { "$_ (UUP)" } }
    $clbEd.Items.Clear()
    foreach ($i in $items) { $clbEd.Items.Add($i, ((Get-EditionName $i) -in $checked)) | Out-Null }
    $cmbEdition.Items.Clear(); $cmbEdition.Items.AddRange(@($items | ForEach-Object { Get-EditionName $_ }))
}

# --- Patches ---
$p = New-Page $tabs 'Patches'
$p.FlowDirection = 'LeftToRight'; $p.WrapContents = $true
$patchBoxes = @{}
foreach ($g in 'Setup bypasses', 'Debloat', 'Aggressive', 'Extras') {
    $box = New-Ctl GroupBox @{ Text = $g; Width = 205; Height = 230 }
    $inner = New-Ctl FlowLayoutPanel @{ FlowDirection = 'TopDown'; Dock = 'Fill'; WrapContents = $false }
    foreach ($id in $Patches.Keys | Where-Object { $Patches[$_].Group -eq $g }) {
        $patchBoxes[$id] = New-Ctl CheckBox @{ Text = $Patches[$id].Label; Width = 190; Height = 34 }
        $inner.Controls.Add($patchBoxes[$id])
    }
    $box.Controls.Add($inner); $p.Controls.Add($box)
}
$txtDrivers = New-Ctl TextBox @{ Width = 450 }
$btnDrv = New-Ctl Button @{ Text = 'Browse' }; $btnDrv.Add_Click({ Select-Folder $txtDrivers })
$p.Controls.Add((New-Row (New-Lbl 'Driver folder' 90) $txtDrivers $btnDrv))
$p.Controls.Add((New-Lbl 'Note: newer builds may ignore BypassNRO - the unattended local account is the reliable route. Aggressive patches can break apps/updates.'))

# --- Unattended ---
$p = New-Page $tabs 'Unattended'
$chkUnattend = New-Ctl CheckBox @{ Text = 'Enable autounattend.xml'; AutoSize = $true }
$txtUser = New-Ctl TextBox @{ Width = 150; Text = 'User' }
$txtPw = New-Ctl TextBox @{ Width = 150; UseSystemPasswordChar = $true }
$chkAutoLogon = New-Ctl CheckBox @{ Text = 'Auto-login on first boot'; AutoSize = $true }
$chkAdminGrp = New-Ctl CheckBox @{ Text = 'Make user administrator'; AutoSize = $true; Checked = $true }
$txtComputer = New-Ctl TextBox @{ Width = 150 }
$cmbTz = New-Ctl ComboBox @{ DropDownStyle = 'DropDownList'; Width = 300 }
$cmbTz.Items.AddRange(@([TimeZoneInfo]::GetSystemTimeZones() | ForEach-Object Id)); $cmbTz.SelectedItem = 'W. Europe Standard Time'
$cmbKbd = New-Ctl ComboBox @{ Width = 120 }; $cmbKbd.Items.AddRange($langs); $cmbKbd.Text = $cmbBase.SelectedItem
$cmbLocale = New-Ctl ComboBox @{ Width = 120 }; $cmbLocale.Items.AddRange($langs); $cmbLocale.Text = $cmbBase.SelectedItem
$chkSkipOobe = New-Ctl CheckBox @{ Text = 'Skip all OOBE screens (EULA, privacy, Microsoft account, network)'; AutoSize = $true; Checked = $true }
$chkEdition = New-Ctl CheckBox @{ Text = 'Skip edition choice:'; AutoSize = $true }
$cmbEdition = New-Ctl ComboBox @{ DropDownStyle = 'DropDownList'; Width = 220 }
$txtKey = New-Ctl TextBox @{ Width = 260 }
$chkAutoPart = New-Ctl CheckBox @{ Text = 'Auto-partition disk 0  -  WIPES THE WHOLE DISK'; AutoSize = $true; ForeColor = 'Firebrick' }
$chkRunWinUtil = New-Ctl CheckBox @{ Text = 'Run CTT WinUtil after first login'; AutoSize = $true }
$txtScript = New-Ctl TextBox @{ Width = 400 }
$btnScript = New-Ctl Button @{ Text = 'Browse' }
$btnScript.Add_Click({ $d = New-Ctl OpenFileDialog @{ Filter = 'PowerShell (*.ps1)|*.ps1' }; if ($d.ShowDialog() -eq 'OK') { $txtScript.Text = $d.FileName } })
$chkEnableAdmin = New-Ctl CheckBox @{ Text = 'Activate hidden Administrator account'; AutoSize = $true }
$p.Controls.AddRange(@($chkUnattend,
        (New-Lbl 'Account'), (New-Row (New-Lbl 'Username' 90) $txtUser (New-Lbl 'Password' 70) $txtPw (New-Lbl '(empty = none)')),
        (New-Row $chkAutoLogon $chkAdminGrp),
        (New-Lbl 'Note: the password is stored base64-encoded in the ISO, which is NOT encryption.'),
        (New-Lbl 'Region'), (New-Row (New-Lbl 'Computer name' 90) $txtComputer (New-Lbl '(empty = random)')),
        (New-Row (New-Lbl 'Timezone' 90) $cmbTz), (New-Row (New-Lbl 'Keyboard' 90) $cmbKbd (New-Lbl 'Locale' 50) $cmbLocale),
        (New-Lbl 'First setup (OOBE)'), $chkSkipOobe, (New-Row $chkEdition $cmbEdition),
        (New-Row (New-Lbl 'Product key' 90) $txtKey (New-Lbl '(your own key; empty = digital license / enter later)')), $chkAutoPart,
        (New-Lbl 'Post-install'), $chkRunWinUtil, (New-Row (New-Lbl 'My script' 90) $txtScript $btnScript), $chkEnableAdmin))

# --- Build ---
$p = New-Page $tabs 'Build'
$txtOut = New-Ctl TextBox @{ Width = 600; Text = "$root\out\Win11.iso" }
$btnOut = New-Ctl Button @{ Text = 'Browse' }
$btnOut.Add_Click({ $d = New-Ctl SaveFileDialog @{ Filter = 'ISO (*.iso)|*.iso'; FileName = 'Win11.iso' }; if ($d.ShowDialog() -eq 'OK') { $txtOut.Text = $d.FileName } })
$chkSplit = New-Ctl CheckBox @{ Text = 'Split install.wim for FAT32 USB'; AutoSize = $true }
$btnBuild = New-Ctl Button @{ Text = 'Build ISO'; Width = 120; Height = 32 }
$bar = New-Ctl ProgressBar @{ Width = 840; Maximum = 9 }
$txtLog = New-Ctl TextBox @{ Multiline = $true; ReadOnly = $true; ScrollBars = 'Vertical'; Width = 840; Height = 430; Font = New-Object Drawing.Font('Consolas', 9) }
$p.Controls.AddRange(@((New-Row (New-Lbl 'Output' 60) $txtOut $btnOut), (New-Row $chkSplit $btnBuild), $bar, $txtLog))

# --- Presets ---
$script:applying = $false
function Set-Preset($Name) {
    if (-not $Presets.Contains($Name)) { return }
    $script:applying = $true
    $pr = $Presets[$Name]
    foreach ($id in $patchBoxes.Keys) { $patchBoxes[$id].Checked = $id -in $pr.Patches }
    $chkSkipOobe.Checked = [bool]$pr.Unattend.SkipOobe
    $chkRunWinUtil.Checked = [bool]$pr.Unattend.RunWinUtil
    if ($pr.Unattend.Enabled) { $chkUnattend.Checked = $true }
    $script:applying = $false
}
$cmbPreset.Add_SelectedIndexChanged({ Set-Preset $cmbPreset.SelectedItem })
$toCustom = { if (-not $script:applying) { $cmbPreset.SelectedItem = 'Custom' } }
foreach ($c in @($patchBoxes.Values) + $chkSkipOobe + $chkRunWinUtil) { $c.Add_CheckedChanged($toCustom) }

$btnScan.Add_Click({
        $form.Cursor = 'WaitCursor'
        $script:IsoInfos = @(Get-SourceIsos $txtIso.Text)
        $form.Cursor = 'Default'
        $lblScan.Text = if ($script:IsoInfos) { ($script:IsoInfos | ForEach-Object { "$($_.Lang) build $($_.Build): $($_.Editions.Count) editions  ($(Split-Path $_.Path -Leaf))" }) -join "`n" } else { 'No ISOs found.' }
        if ($script:IsoInfos -and $script:IsoInfos[0].Lang -in $langs) { $cmbBase.SelectedItem = $script:IsoInfos[0].Lang }
        Update-Editions
    })
$cmbBase.Add_SelectedIndexChanged({ Update-Editions })
$chkUup.Add_CheckedChanged({ Update-Editions })

# --- Build run ---
function Get-Config {
    $uuid = ''
    if ($cmbBuild.SelectedIndex -gt 0) { $uuid = $buildList[$cmbBuild.SelectedIndex - 1].uuid }
    @{
        IsoFolder = $txtIso.Text; UseUup = $chkUup.Checked; UupBuild = $uuid; BaseLang = [string]$cmbBase.SelectedItem
        LangPacks = @($clbLangs.CheckedItems | Where-Object { $_ -ne $cmbBase.SelectedItem })
        Editions = @($clbEd.CheckedItems | ForEach-Object { Get-EditionName $_ })
        Patches = @($Patches.Keys | Where-Object { $patchBoxes[$_].Checked }); DriversPath = $txtDrivers.Text
        Unattend = @{
            Enabled = $chkUnattend.Checked; UserName = $txtUser.Text; Password = $txtPw.Text; AutoLogon = $chkAutoLogon.Checked
            Admin = $chkAdminGrp.Checked; ComputerName = $txtComputer.Text; TimeZone = [string]$cmbTz.SelectedItem
            Keyboard = $cmbKbd.Text; Locale = $cmbLocale.Text; SkipOobe = $chkSkipOobe.Checked
            Edition = $(if ($chkEdition.Checked) { [string]$cmbEdition.SelectedItem } else { '' }); AutoPartition = $chkAutoPart.Checked
            ProductKey = $txtKey.Text.Trim().ToUpper(); RunWinUtil = $chkRunWinUtil.Checked; CustomScript = $txtScript.Text; EnableAdmin = $chkEnableAdmin.Checked
        }
        Output = $txtOut.Text; Split = $chkSplit.Checked; WorkDir = "$root\work"; CacheDir = "$root\cache"
    }
}

function Test-Config($c) {
    if (-not $c.Editions) { return 'Select at least one edition (Editions tab - click "Scan ISOs" or enable UUP dump).' }
    if (-not $c.BaseLang) { return 'Select a base language.' }
    if ($c.Output -notmatch '\.iso$') { return 'Output must be an .iso file.' }
    if ('drivers' -in $c.Patches -and -not (Test-Path $c.DriversPath)) { return 'Driver folder does not exist.' }
    $u = $c.Unattend
    if ($u.Enabled) {
        if (-not $u.UserName.Trim()) { return 'Username is empty.' }
        if ($u.CustomScript -and -not (Test-Path $u.CustomScript)) { return 'Custom script not found.' }
        if ($u.ProductKey -and $u.ProductKey -notmatch '^([A-Z0-9]{5}-){4}[A-Z0-9]{5}$') { return 'Product key must look like XXXXX-XXXXX-XXXXX-XXXXX-XXXXX.' }
        if ($u.Edition -and -not $u.ProductKey -and -not $GenericKeys[$u.Edition]) { return "No generic key for $($u.Edition); untick 'Skip edition choice'." }
    }
}

$script:job = $null
$timer = New-Ctl Timer @{ Interval = 300 }
$timer.Add_Tick({
        $line = $null
        while ($script:sync.Log.TryDequeue([ref]$line)) { $txtLog.AppendText("$line`r`n") }
        $bar.Value = [math]::Min(9, $script:sync.Step)
        if ($script:sync.Done) {
            $timer.Stop()
            try { $script:job.PS.EndInvoke($script:job.Handle) } catch { $txtLog.AppendText("$_`r`n") }
            $script:job.PS.Runspace.Close(); $script:job.PS.Dispose(); $script:job = $null
            $btnBuild.Text = 'Build ISO'; $btnBuild.Enabled = $true
            if ($script:sync.Error) { [Windows.Forms.MessageBox]::Show("Build failed:`n$($script:sync.Error)", 'Build', 'OK', 'Error') | Out-Null }
            else { [Windows.Forms.MessageBox]::Show("ISO ready:`n$($txtOut.Text)", 'Build', 'OK', 'Information') | Out-Null }
        }
    })

$btnBuild.Add_Click({
        if ($script:job) {
            $script:sync.Cancel = $true; $btnBuild.Enabled = $false
            $txtLog.AppendText("Cancelling after the current operation...`r`n"); return
        }
        $cfg = Get-Config
        $err = Test-Config $cfg
        if ($err) { [Windows.Forms.MessageBox]::Show($err, 'Check settings', 'OK', 'Warning') | Out-Null; return }
        if ($cfg.Unattend.Enabled -and $cfg.Unattend.AutoPartition) {
            $a = [Windows.Forms.MessageBox]::Show("Auto-partition is ON.`n`nAny PC booted from this ISO/USB will have DISK 0 ERASED without asking.`n`nBuild anyway?", 'WARNING', 'YesNo', 'Warning')
            if ($a -ne 'Yes') { return }
        }
        $txtLog.Clear(); $bar.Value = 0
        $script:sync = [hashtable]::Synchronized(@{ Log = New-Object 'System.Collections.Concurrent.ConcurrentQueue[string]'; Step = 0; Cancel = $false; Done = $false; Error = $null })
        $ps = [powershell]::Create()
        $ps.AddScript({
                param($root, $cfg, $sync)
                . "$root\lib\Patches.ps1"; . "$root\lib\Unattend.ps1"; . "$root\lib\Source.ps1"; . "$root\lib\Build.ps1"
                Invoke-Build $cfg $sync
            }).AddArgument($root).AddArgument($cfg).AddArgument($script:sync) | Out-Null
        $script:job = @{ PS = $ps; Handle = $ps.BeginInvoke() }
        $btnBuild.Text = 'Cancel'
        $timer.Start()
    })

$form.Add_FormClosing({
        param($s, $e)
        if ($script:job) { $e.Cancel = $true; [Windows.Forms.MessageBox]::Show('A build is running. Cancel it first.', 'Build', 'OK', 'Information') | Out-Null }
    })

$cmbPreset.SelectedItem = 'Recommended'
Update-Editions
[Windows.Forms.Application]::Run($form)
