# One-line install / update:
#   irm https://raw.githubusercontent.com/nussico/win11-ultimate-iso/main/install.ps1 | iex
& {
    $ErrorActionPreference = 'Stop'; $ProgressPreference = 'SilentlyContinue'
    [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
    $repo = 'nussico/win11-ultimate-iso'

    Write-Host @'

                           _
 _ __   _   _  ___   ___  (_)   ___    ___
| '_ \ | | | |/ __| / __| | |  / __|  / _ \
| | | || |_| |\__ \ \__ \ | | | (__  | (_) |
|_| |_| \__,_||___/ |___/ |_|  \___|  \___/

'@ -ForegroundColor Blue
    Write-Host "  Win11 Ultimate ISO Builder - github.com/$repo`n" -ForegroundColor DarkGray

    # Not admin: rerun this installer in an elevated Windows PowerShell (UAC prompt). The elevated process doesn't
    # inherit our environment, so W11UB_DIR from the Update button is passed along in the command.
    $isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
    if (-not $isAdmin -and $env:W11UB_ELEVATED) { throw 'Still no admin rights after the UAC prompt.' }   # never loop
    if (-not $isAdmin) {
        Write-Host 'Win11 Ultimate ISO Builder needs admin rights - confirm the UAC prompt.' -ForegroundColor Cyan
        $cmd = "try { `$env:W11UB_ELEVATED = '1'; $(if ($env:W11UB_DIR) { "`$env:W11UB_DIR = '$($env:W11UB_DIR -replace "'", "''")'; " })irm https://raw.githubusercontent.com/$repo/main/install.ps1 | iex } " +
            "catch { Write-Host `$_ -ForegroundColor Red; Read-Host 'Install failed. Press Enter to close' }"
        $enc = [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($cmd))
        try { Start-Process powershell.exe -Verb RunAs -ArgumentList "-NoProfile -ExecutionPolicy Bypass -EncodedCommand $enc" }
        catch { Write-Host 'Admin rights were declined; nothing was installed.' -ForegroundColor Yellow }
        return
    }

    # Builds need ~60 GB next to the builder. The Update button passes its folder; otherwise ask for a drive or folder
    # (Enter = the drive that already has the builder, else the one with the most free space).
    $dir = $env:W11UB_DIR
    if (-not $dir) {
        $drives = @([IO.DriveInfo]::GetDrives() | Where-Object { $_.DriveType -eq 'Fixed' -and $_.IsReady } | Sort-Object AvailableFreeSpace -Descending)
        $def = @($drives | Where-Object { Test-Path (Join-Path $_.RootDirectory 'Win11UltimateBuilder\Builder.ps1') }) + $drives | Select-Object -First 1
        Write-Host 'Win11 Ultimate ISO Builder - pick where to install (builds need about 60 GB free):' -ForegroundColor Cyan
        for ($i = 0; $i -lt $drives.Count; $i++) {
            $d = $drives[$i]; $note = ''
            if (Test-Path (Join-Path $d.RootDirectory 'Win11UltimateBuilder\Builder.ps1')) { $note += '  (installed here)' }
            if ($d.AvailableFreeSpace -lt 60GB) { $note += '  (not enough space)' }
            Write-Host ('  [{0}] {1}  {2} GB free{3}' -f ($i + 1), $d.Name, [math]::Round($d.AvailableFreeSpace / 1GB), $note)
        }
        Write-Host '  [B] Browse for a folder (or type a folder path)'
        # A picked folder gets a Win11UltimateBuilder folder inside it, unless it already is the builder folder.
        while (-not $dir) {
            $pick = (Read-Host "Number, B, a folder path, or Enter for $($def.Name)").Trim().Trim('"')
            if (-not $pick) { $dir = Join-Path $def.RootDirectory 'Win11UltimateBuilder' }
            elseif ($pick -match '^\d+$' -and [int]$pick -ge 1 -and [int]$pick -le $drives.Count) { $dir = Join-Path $drives[[int]$pick - 1].RootDirectory 'Win11UltimateBuilder' }
            else {
                if ($pick -eq 'b') {
                    Add-Type -AssemblyName System.Windows.Forms
                    $fb = New-Object Windows.Forms.FolderBrowserDialog
                    $fb.Description = 'Pick where to install the builder (a Win11UltimateBuilder folder is created inside it)'
                    if ($fb.ShowDialog((New-Object Windows.Forms.Form -Property @{ TopMost = $true })) -ne 'OK') { continue }   # TopMost: not hidden behind the console
                    $pick = $fb.SelectedPath
                }
                if (-not ([IO.Path]::IsPathRooted($pick) -and $pick -match '^[a-zA-Z]:\\|^\\\\')) { Write-Host '  Not a full folder path, e.g. D:\Tools' -ForegroundColor Yellow; continue }
                $pick = [IO.Path]::GetFullPath($pick).TrimEnd('\')
                if ((Test-Path "$pick\Builder.ps1") -or (Split-Path $pick -Leaf) -eq 'Win11UltimateBuilder') { $dir = $pick }
                else { $dir = Join-Path $pick 'Win11UltimateBuilder' }
                $free = try { (New-Object IO.DriveInfo ([IO.Path]::GetPathRoot($pick))).AvailableFreeSpace } catch { 0 }
                if ($free -and $free -lt 60GB) { Write-Host "  Only $([math]::Round($free / 1GB)) GB free there; builds need about 60 GB." -ForegroundColor Yellow }
            }
        }
    }
    Write-Host "Installing to $dir" -ForegroundColor Cyan

    # Pin the download to one commit so version.txt matches it (the builder compares it to offer updates).
    # The builder's Update passes the commit that passed CI; a fresh install looks for the newest one that passed
    # (.github/workflows/check.yml). Offline, rate-limited or none passed yet: the newest commit, as before.
    $sha = $env:W11UB_SHA
    if ($sha -notmatch '^[0-9a-f]{40}$') {
        $sha = try { @((Invoke-RestMethod "https://api.github.com/repos/$repo/actions/workflows/check.yml/runs?branch=main&event=push&status=success&per_page=1").workflow_runs)[0].head_sha } catch { $null }
        if ($sha -notmatch '^[0-9a-f]{40}$') {
            $sha = try { (Invoke-RestMethod "https://api.github.com/repos/$repo/commits/main" -Headers @{ Accept = 'application/vnd.github.sha' }).Trim() } catch { 'main' }
        }
    }
    # The builder runs elevated and loads its code from $dir: only admins may change files there, or any program could
    # plant code that runs as admin (a new folder on C:\ lets every user modify it). Everyone can still read
    # (copy ISOs from out\) and drop ISOs into sources\. Not for a git checkout; FAT/exFAT drives have no permissions.
    New-Item -ItemType Directory -Force "$dir\lib", "$dir\sources", "$dir\presets" | Out-Null
    if (-not (Test-Path "$dir\.git")) {
        $ErrorActionPreference = 'Continue'   # icacls stderr (e.g. TrustedInstaller leftovers in work\) must not stop the install
        icacls $dir /setowner '*S-1-5-32-544' /T /C /Q 2>&1 | Out-Null
        icacls $dir /inheritance:r /grant:r '*S-1-5-32-544:(OI)(CI)F' '*S-1-5-18:(OI)(CI)F' '*S-1-5-32-545:(OI)(CI)RX' /C /Q 2>&1 | Out-Null
        icacls "$dir\sources" /grant '*S-1-5-32-545:(OI)(CI)M' /C /Q 2>&1 | Out-Null
        $ErrorActionPreference = 'Stop'
    }

    # Downloaded and unpacked in a new folder only admins can write to, so nothing can swap files before they run.
    $stage = Join-Path $env:TEMP "w11ub-$([guid]::NewGuid().ToString('N'))"
    $sec = New-Object Security.AccessControl.DirectorySecurity
    $sec.SetAccessRuleProtection($true, $false)
    $admins = New-Object Security.Principal.SecurityIdentifier 'S-1-5-32-544'
    foreach ($sid in $admins, (New-Object Security.Principal.SecurityIdentifier 'S-1-5-18')) {
        $sec.AddAccessRule((New-Object Security.AccessControl.FileSystemAccessRule($sid, 'FullControl', 'ContainerInherit, ObjectInherit', 'None', 'Allow')))
    }
    $sec.SetOwner($admins)
    [IO.Directory]::CreateDirectory($stage, $sec) | Out-Null
    $zip = "$stage\w11ub.zip"; $tmp = "$stage\files"
    Invoke-WebRequest "https://github.com/$repo/archive/$sha.zip" -OutFile $zip -UseBasicParsing
    Expand-Archive $zip $tmp
    # Unblock before copying: work\ in $dir can hold TrustedInstaller-owned leftovers that can't even be listed.
    Get-ChildItem $tmp -Recurse -File | Unblock-File
    # Only what the builder runs on (no docs, tests or repo files). Overwrites program files only;
    # your sources\, presets\, out\ and cache\ stay.
    $src = (Get-ChildItem $tmp)[0].FullName
    Copy-Item "$src\Builder.ps1", "$src\LICENSE" $dir -Force
    Copy-Item "$src\lib\*" "$dir\lib" -Recurse -Force
    # Older versions copied the whole repo: remove those extras (never in a git checkout).
    if (-not (Test-Path "$dir\.git")) {
        foreach ($x in 'docs', 'tests', '.claude', 'README.md', 'install.ps1', '.gitignore', '.gitattributes', 'sources\.gitkeep') {
            Remove-Item "$dir\$x" -Recurse -Force -ErrorAction SilentlyContinue
        }
    }
    Remove-Item -LiteralPath $stage -Recurse -Force
    if ($sha -ne 'main') { Set-Content "$dir\version.txt" $sha } else { Remove-Item "$dir\version.txt" -ErrorAction SilentlyContinue }

    # conhost --headless: the builder opens without an extra console window
    $launch = "--headless powershell.exe -NoProfile -ExecutionPolicy Bypass -STA -File `"$dir\Builder.ps1`""
    # The builder creates its shortcut in $dir itself on start (nothing in Start menu or desktop).
    Write-Host "Start it next time with: $dir\Win11 Ultimate ISO Builder" -ForegroundColor Cyan
    Start-Process conhost.exe -Verb RunAs -ArgumentList $launch
}
