# Live check of the UUP dump API and download package the builder depends on (needs internet, no admin).
# Run weekly by .github/workflows/uup-watch.yml. Run locally: powershell -File tests\Check-Uup.ps1
$ErrorActionPreference = 'Stop'
$root = Split-Path $PSScriptRoot
. "$root\lib\Patches.ps1"; . "$root\lib\Unattend.ps1"; . "$root\lib\Source.ps1"
$script:fails = 0
function Check($Cond, $Msg) { if ($Cond) { Write-Host "ok   $Msg" } else { Write-Host "FAIL $Msg" -ForegroundColor Red; $script:fails++ } }
function Set-Output($Name, $Value) { if ($env:GITHUB_OUTPUT) { "$Name=$Value" | Add-Content $env:GITHUB_OUTPUT } }

$tmp = Join-Path ([IO.Path]::GetTempPath()) "uupcheck-$([guid]::NewGuid().ToString('N').Substring(0, 8))"
try {
    $builds = Get-UupBuilds
    Check ($builds.Count -gt 0) "listid.php returns builds ($($builds.Count) amd64)"
    $newest = Select-NewestUupBuild $builds
    Check $newest "Newest general release found: $($newest.title)"
    if (-not $newest) { return }
    Check ($newest.uuid -match '^[0-9a-f-]{36}$') 'Build has a uuid'

    $skipped = Get-SkippedNewerRelease $builds $newest
    if ($skipped) {
        Write-Host "NOTE newer release skipped by Test-GeneralRelease: $($skipped.title) - add it to `$NewPcOnlyReleases or change the rule" -ForegroundColor Yellow
        Set-Output 'skipped' $skipped.title
    }

    $langs = Get-UupLanguages $newest.uuid
    Check ('en-us' -in $langs) "listlangs.php returns languages ($($langs.Count), en-us included)"

    # The same package request a Pro build makes; the builder edits these ConvertConfig.ini keys
    $req = Get-UupRequest @('Windows 11 Pro')
    New-Item -ItemType Directory -Force $tmp | Out-Null
    Invoke-WebRequest -UseBasicParsing -Method Post -Body $req.Body -ContentType 'application/x-www-form-urlencoded' -OutFile "$tmp\uup.zip" `
        "https://uupdump.net/get.php?id=$($newest.uuid)&pack=en-us&edition=$($req.Edition)"
    Expand-Archive "$tmp\uup.zip" $tmp -Force
    Check (Test-Path "$tmp\uup_download_windows.cmd") 'Package has uup_download_windows.cmd'
    $ini = if (Test-Path "$tmp\ConvertConfig.ini") { Get-Content "$tmp\ConvertConfig.ini" }
    Check $ini 'Package has ConvertConfig.ini'
    foreach ($key in 'AutoExit', 'AddUpdates', 'ResetBase', 'vAutoEditions') {
        Check ($ini -match "^$key\s*=") "ConvertConfig.ini has $key"
    }
    # Download source Microsoft: the official ISO link (one request; the API rate-limits repeated ones)
    # Cloud runner IPs often get refused; that is Microsoft's rate limit, not a changed API.
    try {
        $ms = Get-MicrosoftIso 'en-us'
        Check ($ms.Url -match '^https://.+\.iso' -and $ms.Build -match '^\d{5}$') "Microsoft ISO link: $($ms.File) (build $($ms.Build))"
    } catch {
        if ("$_" -match 'refused') { Write-Host "NOTE Microsoft ISO link refused (rate limit): $_" -ForegroundColor Yellow } else { throw }
    }
} catch {
    Check $false "Unexpected error: $_"
} finally {
    Remove-Item $tmp -Recurse -Force -ErrorAction SilentlyContinue
}
if ($script:fails) { Write-Host "$script:fails problem(s)" -ForegroundColor Red; exit 1 }
Write-Host 'UUP dump checks passed' -ForegroundColor Green
