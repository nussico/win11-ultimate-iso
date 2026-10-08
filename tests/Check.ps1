# Everything CI runs on each push (.github/workflows/check.yml). Run locally: powershell -File tests\Check.ps1
# The builder only offers an update once this passed for that commit.
$ErrorActionPreference = 'Stop'
$root = Split-Path $PSScriptRoot
$bad = 0
function Fail($Msg) { Write-Host "FAIL $Msg" -ForegroundColor Red; $script:bad++ }

$code = Get-ChildItem $root -Recurse -File -Include *.ps1, *.xaml, *.js | Where-Object FullName -notmatch '\\\.git\\'
foreach ($f in $code) {
    $rel = $f.FullName.Substring($root.Length + 1)
    # ASCII only: Windows PowerShell 5.1 reads BOM-less files as ANSI and mangles anything else
    $bytes = [IO.File]::ReadAllBytes($f.FullName)
    if ($bytes | Where-Object { $_ -gt 127 } | Select-Object -First 1) { Fail "$rel has non-ASCII characters" }
    if ($f.Extension -eq '.ps1') {
        $errs = $null
        [Management.Automation.Language.Parser]::ParseFile($f.FullName, [ref]$null, [ref]$errs) | Out-Null
        foreach ($e in $errs) { Fail "$rel line $($e.Extent.StartLineNumber): $($e.Message)" }
    }
}
Write-Host "ok   $(@($code).Count) files parsed, all ASCII"

# Load the window the same way Builder.ps1 does (catches bad XAML before anyone's builder fails to open)
Add-Type -AssemblyName PresentationFramework
try {
    $xaml = [xml](Get-Content "$root\lib\Window.xaml" -Raw)
    [Windows.Markup.XamlReader]::Load((New-Object Xml.XmlNodeReader $xaml)) | Out-Null
    Write-Host 'ok   Window.xaml loads'
} catch { Fail "Window.xaml: $($_.Exception.InnerException.Message) $_" }

& powershell.exe -NoProfile -ExecutionPolicy Bypass -File "$root\tests\SelfTest.ps1"
if ($LASTEXITCODE) { Fail 'SelfTest.ps1' }

if ($bad) { Write-Host "$bad problem(s)" -ForegroundColor Red; exit 1 }
Write-Host 'all checks passed' -ForegroundColor Green
