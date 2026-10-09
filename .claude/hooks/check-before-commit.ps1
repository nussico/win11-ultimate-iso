# Claude Code PreToolUse hook (.claude/settings.json): runs tests\Check.ps1 before Claude commits.
# Exit 2 blocks the commit and hands the failures back to Claude.
$root = Split-Path (Split-Path $PSScriptRoot)
$out = & powershell.exe -NoProfile -ExecutionPolicy Bypass -File "$root\tests\Check.ps1" 2>&1 | Out-String
if ($LASTEXITCODE) {
    [Console]::Error.WriteLine("tests\Check.ps1 failed - fix these before committing:`n" + (($out -split "`r?`n" | Where-Object { $_ -cmatch '^FAIL|problem\(s\)' }) -join "`n"))
    exit 2
}
