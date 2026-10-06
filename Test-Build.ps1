# Verifies a finished ISO against the config.json written next to it. Run as admin:
#   powershell -File Test-Build.ps1 [-Iso out\Win11.iso]
param([string]$Iso = "$PSScriptRoot\out\Win11.iso")
$ErrorActionPreference = 'Stop'
. "$PSScriptRoot\lib\Patches.ps1"; . "$PSScriptRoot\lib\Source.ps1"
function Write-Log($m) { }
$cfg = Get-Content (Join-Path (Split-Path $Iso) 'config.json') -Raw | ConvertFrom-Json
$script:fails = 0
function Check($Cond, $Msg) { if ($Cond) { Write-Host "ok   $Msg" } else { Write-Host "FAIL $Msg" -ForegroundColor Red; $script:fails++ } }

$mount = "$env:TEMP\w11test"
try {
    $drive = Mount-Iso $Iso
    if (Test-Path "$drive\sources\install.swm") { Write-Warning 'Split image (.swm): only checking files'; $wim = $null }
    else { $wim = Get-InstallImage $drive }
    Check (Test-Path "$drive\boot\etfsboot.com") 'BIOS boot file present'
    Check (Test-Path "$drive\efi\microsoft\boot\efisys.bin") 'UEFI boot file present'
    if ($cfg.Unattend.Enabled) {
        $ok = $true; try { [xml](Get-Content "$drive\autounattend.xml" -Raw) | Out-Null } catch { $ok = $false }
        Check $ok 'autounattend.xml is valid XML'
    }
    if ($wim) {
        $names = @((Get-WindowsImage -ImagePath $wim).ImageName)
        Check (-not (Compare-Object $names @($cfg.Editions))) "Editions = $($cfg.Editions -join ', ')"

        New-Item -ItemType Directory -Force $mount | Out-Null
        Mount-WindowsImage -ImagePath $wim -Index 1 -Path $mount -ReadOnly | Out-Null
        $pkgs = (Get-WindowsPackage -Path $mount).PackageName

        $prov = (Get-AppxProvisionedPackage -Path $mount).DisplayName
        foreach ($a in 'Microsoft.WindowsStore', 'Microsoft.DesktopAppInstaller', 'Microsoft.WindowsCalculator', 'Microsoft.Windows.Photos', 'Microsoft.WindowsNotepad', 'Microsoft.XboxIdentityProvider') {
            Check ($a -in $prov) "Essential app kept: $a"
        }
        if ('bloatapps' -in $cfg.Patches) { Check (-not ($RemoveApps | Where-Object { $_ -in $prov })) 'Bloat apps removed' }

        Mount-Hives $mount
        try {
            foreach ($id in $cfg.Patches) {
                foreach ($e in $Patches[$id].Reg) {
                    $path, $name, $value = $e -split '\|'
                    $out = reg query (Convert-RegPath $path) /v $name 2>$null
                    if ($value -eq '-') { Check (-not $out) "$id : $name deleted" }
                    else { Check ($out -match "0x$('{0:x}' -f [int]$value)\b") "$id : $name = $value" }
                }
            }
        } finally { Dismount-Hives }
    }
} finally {
    if (Get-WindowsImage -Mounted | Where-Object Path -eq $mount) { Dismount-WindowsImage -Path $mount -Discard | Out-Null }
    Dismount-DiskImage -ImagePath (Resolve-Path $Iso) | Out-Null
}
if ($fails) { Write-Host "$fails check(s) failed" -ForegroundColor Red; exit 1 } else { Write-Host 'ISO looks good' -ForegroundColor Green }
