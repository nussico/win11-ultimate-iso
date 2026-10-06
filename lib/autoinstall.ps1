# Runs inside Windows Setup (WinPE) from <media>\sources\autoinstall.ps1, called by autounattend.xml.
# Picks the best internal disk (NVMe > SSD > HDD), but only if the choice is unambiguous.
# Picked -> wipe it, apply the image, make it bootable, reboot. Not picked -> exit; normal Setup UI continues.

# $Disks: objects with Number, BusType, MediaType, Size. $Exclude: disk numbers never to touch.
function Select-TargetDisk($Disks, [int[]]$Exclude = @()) {
    $cands = @($Disks | Where-Object {
            $_.BusType -notin 'USB', 'SD', 'MMC', 'File Backed Virtual' -and $_.Size -ge 64GB -and $_.Number -notin $Exclude })
    if (-not $cands) { return $null }
    $rank = { param($d) if ($d.BusType -eq 'NVMe') { 3 } elseif ($d.MediaType -eq 'SSD') { 2 } else { 1 } }
    $best = ($cands | ForEach-Object { & $rank $_ } | Measure-Object -Maximum).Maximum
    $top = @($cands | Where-Object { (& $rank $_) -eq $best })
    if ($top.Count -eq 1) { $top[0] } else { $null }
}

function Invoke-AutoInstall {
    $media = Split-Path $PSScriptRoot
    Start-Transcript X:\autoinstall.log | Out-Null
    $cfg = Get-Content "$PSScriptRoot\autoinstall.json" -Raw | ConvertFrom-Json

    $fw = (Get-ItemProperty HKLM:\SYSTEM\CurrentControlSet\Control).PEFirmwareType
    if ($fw -ne 2) { Write-Host 'Legacy BIOS: auto-install skipped, use the normal setup.'; return }

    $mediaDisk = @(Get-Partition -DriveLetter $media[0] -ErrorAction SilentlyContinue | ForEach-Object DiskNumber)
    $disk = Select-TargetDisk (Get-PhysicalDisk | Select-Object @{ n = 'Number'; e = { [int]$_.DeviceId } }, BusType, MediaType, Size, FriendlyName) $mediaDisk
    if (-not $disk) { Write-Host 'No single best disk found: continuing with the normal setup.'; return }

    $gb = [math]::Round($disk.Size / 1GB)
    Write-Host "`nInstalling to disk $($disk.Number): $($disk.FriendlyName) ($gb GB, $($disk.BusType)/$($disk.MediaType))" -ForegroundColor Yellow
    Write-Host 'ALL DATA ON THIS DISK WILL BE ERASED. Press any key within 10 seconds to cancel.' -ForegroundColor Red
    for ($i = 10; $i -gt 0; $i--) {
        try { if ([Console]::KeyAvailable) { Write-Host 'Cancelled: continuing with the normal setup.'; return } } catch { }
        Start-Sleep 1
    }

    @"
select disk $($disk.Number)
clean
convert gpt
create partition efi size=300
format quick fs=fat32 label=System
assign letter=S
create partition msr size=16
create partition primary
format quick fs=ntfs label=Windows
assign letter=W
"@ | Set-Content X:\diskpart.txt -Encoding ASCII
    diskpart /s X:\diskpart.txt
    if ($LASTEXITCODE) { throw "diskpart failed ($LASTEXITCODE)" }

    $wim = "$media\sources\install.wim"; $split = @{}
    if (-not (Test-Path $wim)) { $wim = "$media\sources\install.swm"; $split = @{ SplitImageFilePattern = "$media\sources\install*.swm" } }
    $idx = (Get-WindowsImage -ImagePath $wim | Where-Object ImageName -eq $cfg.Edition).ImageIndex
    if (-not $idx) { throw "Edition '$($cfg.Edition)' not in image" }
    Write-Host "Applying $($cfg.Edition)..."
    Expand-WindowsImage -ImagePath $wim -Index $idx -ApplyPath W:\ @split | Out-Null
    bcdboot W:\Windows /s S: /f UEFI
    if ($LASTEXITCODE) { throw "bcdboot failed ($LASTEXITCODE)" }
    New-Item -ItemType Directory -Force W:\Windows\Panther | Out-Null
    Copy-Item "$media\autounattend.xml" W:\Windows\Panther\unattend.xml
    if (Test-Path "$media\sources\`$OEM`$\`$`$") { Copy-Item "$media\sources\`$OEM`$\`$`$\*" W:\Windows -Recurse -Force }
    Write-Host 'Done, rebooting...'
    Stop-Transcript | Out-Null
    wpeutil reboot
}

if ($MyInvocation.InvocationName -ne '.') {
    try { Invoke-AutoInstall } catch { Write-Host "Auto-install failed: $_" -ForegroundColor Red; Start-Sleep 30; throw }
}
