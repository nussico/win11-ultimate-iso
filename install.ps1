# One-line install / update:
#   irm https://raw.githubusercontent.com/nussico/win11-ultimate-iso/main/install.ps1 | iex
& {
    $ErrorActionPreference = 'Stop'; $ProgressPreference = 'SilentlyContinue'
    [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
    $repo = 'nussico/win11-ultimate-iso'

    # Not admin: rerun this installer in an elevated Windows PowerShell (UAC prompt). The elevated process doesn't
    # inherit our environment, so W11UB_DIR from the Update button is passed along in the command.
    $isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole('Administrators')
    if (-not $isAdmin) {
        Write-Host 'Win11 Ultimate ISO Builder needs admin rights - confirm the UAC prompt.' -ForegroundColor Cyan
        $cmd = "try { $(if ($env:W11UB_DIR) { "`$env:W11UB_DIR = '$($env:W11UB_DIR -replace "'", "''")'; " })irm https://raw.githubusercontent.com/$repo/main/install.ps1 | iex } " +
            "catch { Write-Host `$_ -ForegroundColor Red; Read-Host 'Install failed. Press Enter to close' }"
        $enc = [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($cmd))
        try { Start-Process powershell.exe -Verb RunAs -ArgumentList "-NoProfile -ExecutionPolicy Bypass -EncodedCommand $enc" }
        catch { Write-Host 'Admin rights were declined; nothing was installed.' -ForegroundColor Yellow }
        return
    }

    # Builds need ~60 GB next to the builder. The Update button passes its folder; otherwise ask which drive
    # (Enter = the drive that already has the builder, else the one with the most free space).
    $dir = $env:W11UB_DIR
    if (-not $dir) {
        $drives = @([IO.DriveInfo]::GetDrives() | Where-Object { $_.DriveType -eq 'Fixed' -and $_.IsReady } | Sort-Object AvailableFreeSpace -Descending)
        $def = @($drives | Where-Object { Test-Path (Join-Path $_.RootDirectory 'Win11UltimateBuilder\Builder.ps1') }) + $drives | Select-Object -First 1
        Write-Host 'Win11 Ultimate ISO Builder - pick the drive to install to (builds need about 60 GB free):' -ForegroundColor Cyan
        for ($i = 0; $i -lt $drives.Count; $i++) {
            $d = $drives[$i]; $note = ''
            if (Test-Path (Join-Path $d.RootDirectory 'Win11UltimateBuilder\Builder.ps1')) { $note += '  (installed here)' }
            if ($d.AvailableFreeSpace -lt 60GB) { $note += '  (not enough space)' }
            Write-Host ('  [{0}] {1}  {2} GB free{3}' -f ($i + 1), $d.Name, [math]::Round($d.AvailableFreeSpace / 1GB), $note)
        }
        do { $pick = Read-Host "Number, or Enter for $($def.Name)" } until (-not $pick -or ($pick -match '^\d+$' -and [int]$pick -ge 1 -and [int]$pick -le $drives.Count))
        $drive = if ($pick) { $drives[[int]$pick - 1] } else { $def }
        $dir = Join-Path $drive.RootDirectory 'Win11UltimateBuilder'
    }
    Write-Host "Installing to $dir" -ForegroundColor Cyan

    # Pin the download to the newest commit so version.txt matches it (the builder compares it to offer updates).
    $sha = try { (Invoke-RestMethod "https://api.github.com/repos/$repo/commits/main" -Headers @{ Accept = 'application/vnd.github.sha' }).Trim() } catch { 'main' }
    $zip = Join-Path $env:TEMP 'w11ub.zip'; $tmp = Join-Path $env:TEMP 'w11ub'
    Invoke-WebRequest "https://github.com/$repo/archive/$sha.zip" -OutFile $zip -UseBasicParsing
    if (Test-Path $tmp) { Remove-Item $tmp -Recurse -Force }
    Expand-Archive $zip $tmp
    # Unblock before copying: work\ in $dir can hold TrustedInstaller-owned leftovers that can't even be listed.
    Get-ChildItem $tmp -Recurse -File | Unblock-File
    New-Item -ItemType Directory -Force $dir | Out-Null
    # Overwrites program files only; your sources\, out\ and cache\ stay.
    Copy-Item "$((Get-ChildItem $tmp)[0].FullName)\*" $dir -Recurse -Force
    Remove-Item $zip, $tmp -Recurse -Force
    if ($sha -ne 'main') { Set-Content "$dir\version.txt" $sha } else { Remove-Item "$dir\version.txt" -ErrorAction SilentlyContinue }

    # conhost --headless: the builder opens without an extra console window
    $launch = "--headless powershell.exe -NoProfile -ExecutionPolicy Bypass -STA -File `"$dir\Builder.ps1`""
    # The builder creates its shortcut in $dir itself on start (nothing in Start menu or desktop).
    Write-Host "Start it next time with: $dir\Win11 Ultimate ISO Builder" -ForegroundColor Cyan
    Start-Process conhost.exe -Verb RunAs -ArgumentList $launch
}
