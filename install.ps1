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

    $zip = Join-Path $env:TEMP 'w11ub.zip'; $tmp = Join-Path $env:TEMP 'w11ub'
    Invoke-WebRequest "https://github.com/$repo/archive/refs/heads/main.zip" -OutFile $zip -UseBasicParsing
    if (Test-Path $tmp) { Remove-Item $tmp -Recurse -Force }
    Expand-Archive $zip $tmp
    # Unblock before copying: work\ in $dir can hold TrustedInstaller-owned leftovers that can't even be listed.
    Get-ChildItem $tmp -Recurse -File | Unblock-File
    New-Item -ItemType Directory -Force $dir | Out-Null
    # Overwrites program files only; your sources\, out\ and cache\ stay.
    Copy-Item "$((Get-ChildItem $tmp)[0].FullName)\*" $dir -Recurse -Force
    Remove-Item $zip, $tmp -Recurse -Force

    # conhost --headless: the builder opens without an extra console window
    Start-Process conhost.exe -Verb RunAs -ArgumentList "--headless powershell.exe -NoProfile -ExecutionPolicy Bypass -STA -File `"$dir\Builder.ps1`""
}
