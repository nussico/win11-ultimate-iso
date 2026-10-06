# One-line install / update:
#   irm https://raw.githubusercontent.com/nussico/win11-ultimate-iso/main/install.ps1 | iex
& {
    $ErrorActionPreference = 'Stop'; $ProgressPreference = 'SilentlyContinue'
    [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
    $repo = 'nussico/win11-ultimate-iso'

    # Builds need ~60 GB next to the builder: use the fixed drive with the most free space.
    $drive = [IO.DriveInfo]::GetDrives() | Where-Object { $_.DriveType -eq 'Fixed' -and $_.IsReady } |
        Sort-Object AvailableFreeSpace -Descending | Select-Object -First 1
    $dir = Join-Path $drive.RootDirectory 'Win11UltimateBuilder'
    Write-Host "Win11 Ultimate ISO Builder -> $dir ($([math]::Round($drive.AvailableFreeSpace / 1GB)) GB free)" -ForegroundColor Cyan

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
    # Shortcut inside the install folder only (nothing in Start menu or desktop), so the irm line is only needed once.
    $s = (New-Object -ComObject WScript.Shell).CreateShortcut("$dir\Win11 Ultimate ISO Builder.lnk")
    $s.TargetPath = "$env:SystemRoot\System32\conhost.exe"; $s.Arguments = $launch
    $s.WorkingDirectory = $dir; $s.IconLocation = "$dir\lib\app.ico"; $s.Save()
    Write-Host "Start it next time with: $dir\Win11 Ultimate ISO Builder" -ForegroundColor Cyan
    Start-Process conhost.exe -Verb RunAs -ArgumentList $launch
}
