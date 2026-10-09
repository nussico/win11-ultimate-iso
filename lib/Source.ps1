# Source detection (own ISOs) and UUP dump downloads.

$UupApi = 'https://api.uupdump.net'
# Editions UUP dump can produce: retail ones directly, the rest as virtual editions built from Pro.
$UupEditions = [ordered]@{
    'Windows 11 Home'       = @{ Uup = 'CORE' }
    'Windows 11 Pro'        = @{ Uup = 'PROFESSIONAL' }
    'Windows 11 Education'  = @{ Virtual = 'Education' }
    'Windows 11 Enterprise' = @{ Virtual = 'Enterprise' }
}

# $Images: Get-WindowsImage list output; $Detail: Get-WindowsImage -Index output.
function ConvertTo-IsoInfo($Path, $Images, $Detail) {
    [pscustomobject]@{
        Path     = $Path
        Lang     = ([string]@($Detail.Languages)[0]).ToLower()
        Build    = ([version]$Detail.Version).Build.ToString()
        Editions = @($Images | ForEach-Object { [pscustomobject]@{ Index = $_.ImageIndex; Name = $_.ImageName } })
    }
}

function Get-InstallImage($Root) {
    foreach ($n in 'install.wim', 'install.esd') { if (Test-Path "$Root\sources\$n") { return "$Root\sources\$n" } }
    throw "No install.wim/esd under $Root\sources"
}

function Mount-Iso($Path) {
    $img = Get-DiskImage -ImagePath $Path
    if (-not $img.Attached) { $img = Mount-DiskImage -ImagePath $Path -PassThru }
    # The letter can show up a moment after mounting; none at all means automount is off on this PC.
    for ($i = 0; $i -lt 10 -and -not ($letter = (Get-DiskImage -ImagePath $Path | Get-Volume).DriveLetter); $i++) { Start-Sleep -Milliseconds 500 }
    if (-not $letter) { throw "$(Split-Path $Path -Leaf) mounted without a drive letter (automount off? run 'mountvol /e' as admin)" }
    "${letter}:"
}

function Get-IsoInfo($Path) {
    try {
        $wim = Get-InstallImage (Mount-Iso $Path)
        ConvertTo-IsoInfo $Path (Get-WindowsImage -ImagePath $wim) (Get-WindowsImage -ImagePath $wim -Index 1)
    } finally { Dismount-DiskImage -ImagePath $Path | Out-Null }
}

function Get-SourceIsos($Folder) {
    foreach ($iso in Get-ChildItem $Folder -Filter *.iso -ErrorAction SilentlyContinue) {
        try {
            $info = Get-IsoInfo $iso.FullName
            # UUP ISOs from the old Fast mode hold the base build without updates (e.g. 26100.1, no inbox apps);
            # the sidecar records the release they came from. Fast = the image is older than that release.
            $release = if (Test-Path "$($iso.FullName).build") { (Get-Content "$($iso.FullName).build").Split('.')[0] } else { $info.Build }
            $info | Add-Member Fast ($release -ne $info.Build) -PassThru | Add-Member Build $release -Force -PassThru
        } catch { Write-Warning "$($iso.Name): $_" }
    }
}

# A Fast-mode ISO holds the old base image (e.g. 24H2 for a 26H2 download): with UUP on, a full download replaces it
# instead of mixing its editions and setup files into the build. Without UUP it's all there is.
function Test-UsableIso($Iso, $Cfg) { -not ($Iso.Fast -and $Cfg.UseUup) }

# Microsoft's ISO always holds Home, Pro and Education. Fewer of them ticked (e.g. only Pro) -> UUP dump gets an image
# with just those. Editions Microsoft doesn't have (Enterprise) stay an error in Get-MicrosoftPlan.
function Test-MsSubset($Editions) {
    $want = @(Get-DownloadEditions $Editions)
    -not ($want | Where-Object { $_ -notin $MsIsoEditions }) -and $want.Count -lt $MsIsoEditions.Count
}

# What a build will use: base ISO, editions to download, UUP build. Shared by the build and the GUI's plan.
function Get-BuildPlan($Isos, $Builds, $Cfg) {
    $msSource = $Cfg.UseUup -and $Cfg.Download -eq 'Microsoft'
    $msSubset = $msSource -and $Builds -and (Test-MsSubset $Cfg.Editions)
    # The build picker is off for Microsoft: a build picked earlier under UUP dump must not pin this download.
    if ($msSubset) { $Cfg = $Cfg.Clone(); $Cfg.UupBuild = '' }
    $p = @{ Base = $null; Newest = (Select-NewestUupBuild $Builds); Missing = @(); Uup = $null; Microsoft = $false; Note = $null; Error = $null; Skipped = $null }
    if ($Cfg.Newest -and -not $Cfg.UupBuild) { $p.Skipped = Get-SkippedNewerRelease $Builds $p.Newest }
    $isos = @($Isos | Where-Object { $_.Lang -eq $Cfg.BaseLang -and (Test-UsableIso $_ $Cfg) })
    if ($msSource -and -not $msSubset) { return (Get-MicrosoftPlan $p $isos $Cfg) }
    # With UUP: an ISO with exactly the ticked editions (only Pro -> a Pro-only ISO, downloaded once and kept next to
    # the multi-edition one). Without UUP (or UUP unreachable) any of your ISOs.
    if ($Cfg.UseUup -and $Builds) {
        $want = Get-DownloadEditions $Cfg.Editions
        $fit = @($isos | Where-Object { -not (Compare-Object @($_.Editions.Name) $want) })
        if ($msSubset -and -not $fit) { $p.Note = "Smaller image but longer download: only $($Cfg.Editions -join ', ') from UUP dump, latest update built in (about 60 minutes instead of 10 from Microsoft, kept for next builds)" }
        elseif ($isos -and -not $fit) { $p.Note = "None of your ISOs has exactly $($Cfg.Editions -join ', '): downloading one with just these (kept for next builds)" }
        $isos = $fit
    }
    $p.Base = $isos | Sort-Object { [int]$_.Build } -Descending | Select-Object -First 1
    if ($Cfg.Newest -and $p.Base -and $p.Newest -and [int]$p.Base.Build -lt [int]$p.Newest.build.Split('.')[0]) {
        if ($Cfg.UseUup) { $p.Note = "Your ISO is build $($p.Base.Build) (older version): downloading the newest instead"; $p.Base = $null }
        else { $p.Note = "NOTE: a newer Windows version exists ($($p.Newest.title)); turn on UUP dump to use it" }
    }
    $p.Missing = @($Cfg.Editions | Where-Object { -not $p.Base -or $_ -notin $p.Base.Editions.Name })
    if (-not $p.Missing) { return $p }
    if (-not $Cfg.UseUup) {
        $p.Error = if (-not $p.Base) { "No ISO for language $($Cfg.BaseLang) in $($Cfg.IsoFolder). Add one or turn on UUP dump." }
        else { "Editions not in your ISO: $($p.Missing -join ', '). Turn on UUP dump or untick them." }
        return $p
    }
    $major = if ($p.Base) { $p.Base.Build } elseif ($p.Newest) { $p.Newest.build.Split('.')[0] }
    if (-not $major) { $p.Error = 'Could not reach UUP dump'; return $p }
    $p.Uup = if ($Cfg.UupBuild) { $Builds | Where-Object uuid -eq $Cfg.UupBuild } else { Select-UupBuild $Builds $major }
    if (-not $p.Uup) { $p.Error = "No UUP dump build found for build $major" }
    elseif ($p.Uup.build.Split('.')[0] -ne $major) { $p.Error = "UUP build $($p.Uup.build) does not match ISO build $major. Pick a $major build." }
    $p
}

# Download source Microsoft, all of its editions ticked: your newest ISO if it has them, else the official ISO (all consumer
# editions in one). $p.Microsoft = ask Microsoft; the build only downloads when editions are missing or Microsoft's
# build is newer than yours (its build is only known then), so an older Microsoft ISO never loops.
function Get-MicrosoftPlan($p, $Isos, $Cfg) {
    $p.Base = @($Isos | Where-Object { $iso = $_; -not (@($Cfg.Editions) | Where-Object { $_ -notin $iso.Editions.Name }) } |
        Sort-Object { [int]$_.Build } -Descending)[0]
    $p.Missing = @($Cfg.Editions | Where-Object { -not $p.Base -or $_ -notin $p.Base.Editions.Name })
    $older = $Cfg.Newest -and $p.Base -and $p.Newest -and [int]$p.Base.Build -lt [int]$p.Newest.build.Split('.')[0]
    if (-not $p.Missing -and -not $older) { return $p }
    $bad = @($p.Missing | Where-Object { $_ -notin $MsIsoEditions })
    if ($bad) { $p.Error = "Not in Microsoft's ISO: $($bad -join ', '). Pick UUP dump as the download source for these."; return $p }
    if (-not $MsIsoLanguages[$Cfg.BaseLang]) { $p.Error = "Microsoft has no ISO in $($Cfg.BaseLang). Pick UUP dump as the download source."; return $p }
    $p.Microsoft = $true
    if ($older -and -not $p.Missing) { $p.Note = "Your ISO is build $($p.Base.Build) (older version): getting the newest from Microsoft" }
    $p
}

# When Microsoft refuses the link (rate limit, VPN): the same build planned with UUP dump as the source.
function Get-UupFallbackPlan($Isos, $Builds, $Cfg) {
    $c = $Cfg.Clone(); $c.Download = 'Uup'
    Get-BuildPlan $Isos $Builds $c
}

function Get-UupBuilds {
    $b = (Invoke-RestMethod "$UupApi/listid.php?search=Windows%2011%2C%20version&sortByDate=1" -TimeoutSec 20).response.builds
    @($b.PSObject.Properties.Value | Where-Object arch -eq 'amd64')
}

# Newest "Windows 11, version ..." build with the given major build number (e.g. 26200).
function Select-UupBuild($Builds, $Major) {
    $Builds | Where-Object { $_.title -like 'Windows 11, version*' -and $_.build -like "$Major.*" } |
        Sort-Object { [version]"10.0.$($_.build)" } -Descending | Select-Object -First 1
}

# Releases that ship only on specific new PCs. Microsoft lists them as "General Availability Channel" too, so no
# data says so: checked by hand on learn.microsoft.com/windows/release-health/windows11-release-information.
$NewPcOnlyReleases = @('26H1')

# Version of a released build ("25H2"), $null for previews, updates and other titles.
function Get-ReleaseVersion($Build) { if ($Build.title -match '^Windows 11, version (\d\dH\d) \(') { $Matches[1] } }

# General release = every PC gets it. Rule: H2 releases (yearly, for everyone), never the known new-PC-only ones.
# Fails safe: an unknown general H1 is skipped (older but working), and Get-SkippedNewerRelease reports it.
function Test-GeneralRelease($Build) { ($v = Get-ReleaseVersion $Build) -and $v -like '*H2' -and $v -notin $NewPcOnlyReleases }

# Newest general release: highest build, newest revision.
function Select-NewestUupBuild($Builds) {
    $Builds | Where-Object { Test-GeneralRelease $_ } |
        Sort-Object { [version]"10.0.$($_.build)" } -Descending | Select-Object -First 1
}

# A newer release the rule skipped and nobody has checked yet (e.g. a general 27H1): shown in the plan and the log
# instead of being ignored. Add it to $NewPcOnlyReleases or change Test-GeneralRelease once it's clear what it is.
function Get-SkippedNewerRelease($Builds, $Newest) {
    if (-not $Newest) { return }
    $Builds | Where-Object { ($v = Get-ReleaseVersion $_) -and $v -notin $NewPcOnlyReleases -and -not (Test-GeneralRelease $_) -and
        [int]$_.build.Split('.')[0] -gt [int]$Newest.build.Split('.')[0] } |
        Sort-Object { [version]"10.0.$($_.build)" } -Descending | Select-Object -First 1
}

function Get-UupLanguages($Uuid) {
    @((Invoke-RestMethod "$UupApi/listlangs.php?id=$Uuid" -TimeoutSec 20).response.langList | Where-Object { $_ -ne 'neutral' } | Sort-Object)
}

# Editions a UUP download of these contains: virtual editions are built from Pro, which stays in the ISO.
function Get-DownloadEditions([string[]]$Names) {
    @(@($Names) + @(if ($Names | Where-Object { $UupEditions[$_].Virtual }) { 'Windows 11 Pro' }) | Select-Object -Unique)
}

# UUP dump package request. Always integrates the latest cumulative update: the converter only adds the inbox apps
# (Store, winget, Calculator...) on that path, a base image without it has none.
function Get-UupRequest([string[]]$EditionNames) {
    $direct = @($EditionNames | ForEach-Object { $UupEditions[$_].Uup } | Where-Object { $_ })
    $virtual = @($EditionNames | ForEach-Object { $UupEditions[$_].Virtual } | Where-Object { $_ })
    if ($virtual -and 'PROFESSIONAL' -notin $direct) { $direct += 'PROFESSIONAL' }
    @{
        Edition = $direct -join ';'
        Virtual = $virtual
        # cleanup=1 (+ ResetBase in Save-UupIso): drop the files the update replaced, otherwise ~6 GB more per edition
        Body    = "autodl=$(if ($virtual) { 3 } else { 2 })&updates=1&cleanup=1" + (($virtual | ForEach-Object { "&virtualEditions[]=$_" }) -join '')
    }
}

# Builds an ISO with UUP dump's own download+convert package. Returns the ISO path.
# $Cancelled: returns $true when the user cancelled; the download (cmd + aria2c + converter) is then stopped.
function Save-UupIso($Uuid, $Lang, [string[]]$EditionNames, $Dest, [scriptblock]$Cancelled = { $false }) {
    $req = Get-UupRequest $EditionNames
    New-Item -ItemType Directory -Force $Dest | Out-Null
    $zip = "$Dest\uup.zip"
    Invoke-WebRequest -UseBasicParsing -Method Post -Body $req.Body -ContentType 'application/x-www-form-urlencoded' -OutFile $zip `
        "https://uupdump.net/get.php?id=$Uuid&pack=$Lang&edition=$($req.Edition)"
    Expand-Archive $zip $Dest -Force
    $ini = "$Dest\ConvertConfig.ini"
    (Get-Content $ini) -replace '^AutoExit\s*=.*', 'AutoExit    =1' -replace '^AddUpdates\s*=.*', 'AddUpdates   =1' `
        -replace '^ResetBase\s*=.*', 'ResetBase  =1' -replace '^vAutoEditions=.*', "vAutoEditions=$($req.Virtual -join ',')" | Set-Content $ini
    # stdin from NUL so any 'pause' returns immediately; .\ because NoDefaultCurrentDirectoryInExePath=1 hides the folder from cmd
    $p = Start-Process cmd.exe -ArgumentList '/c', '.\uup_download_windows.cmd < NUL' -WorkingDirectory $Dest -PassThru -WindowStyle Minimized
    $null = $p.Handle   # keeps ExitCode readable after the process ends
    while (-not $p.WaitForExit(1000)) {
        # try: under ErrorActionPreference Stop, taskkill's stderr would replace the cancel with a different error
        if (& $Cancelled) { try { taskkill /T /F /PID $p.Id 2>&1 | Out-Null } catch { }; throw 'Cancelled by user' }
    }
    $iso = Get-ChildItem $Dest -Filter *.iso | Select-Object -First 1
    if (-not $iso) { throw "UUP dump conversion produced no ISO (exit $($p.ExitCode)); see $Dest" }
    $iso.FullName
}

# Official ISO from microsoft.com/software-download/windows11: one 8 GB download, inbox apps included, the newest
# monthly update comes from Windows Update after setup. Consumer ISO, so no Enterprise.
$MsIsoEditions = @('Windows 11 Home', 'Windows 11 Pro', 'Windows 11 Education')
$MsIsoLanguages = @{
    'ar-sa' = 'Arabic'; 'pt-br' = 'Brazilian Portuguese'; 'bg-bg' = 'Bulgarian'; 'zh-cn' = 'Chinese (Simplified)'
    'zh-tw' = 'Chinese (Traditional)'; 'hr-hr' = 'Croatian'; 'cs-cz' = 'Czech'; 'da-dk' = 'Danish'; 'nl-nl' = 'Dutch'
    'en-us' = 'English'; 'en-gb' = 'English (United Kingdom)'; 'et-ee' = 'Estonian'; 'fi-fi' = 'Finnish'; 'fr-fr' = 'French'
    'fr-ca' = 'French Canadian'; 'de-de' = 'German'; 'el-gr' = 'Greek'; 'he-il' = 'Hebrew'; 'hu-hu' = 'Hungarian'
    'it-it' = 'Italian'; 'ja-jp' = 'Japanese'; 'ko-kr' = 'Korean'; 'lv-lv' = 'Latvian'; 'lt-lt' = 'Lithuanian'
    'nb-no' = 'Norwegian'; 'pl-pl' = 'Polish'; 'pt-pt' = 'Portuguese'; 'ro-ro' = 'Romanian'; 'ru-ru' = 'Russian'
    'sr-latn-rs' = 'Serbian Latin'; 'sk-sk' = 'Slovak'; 'sl-si' = 'Slovenian'; 'es-es' = 'Spanish'; 'es-mx' = 'Spanish (Mexico)'
    'sv-se' = 'Swedish'; 'th-th' = 'Thai'; 'tr-tr' = 'Turkish'; 'uk-ua' = 'Ukrainian'
}

# Download link, build and file name of the official ISO in $Lang. Same requests as the download page (and Fido),
# minus its vlscppe.microsoft.com tracker call: ad blockers often block that host and the link works without it.
function Get-MicrosoftIso($Lang) {
    $name = $MsIsoLanguages[$Lang]
    if (-not $name) { throw "Microsoft has no Windows 11 ISO in $Lang; pick UUP dump as the download source" }
    $sid = [guid]::NewGuid(); $inst = '560dc9f3-1aa5-4a2f-b63c-9e18f8d0e175'
    $api = 'https://www.microsoft.com/software-download-connector/api'; $q = "profile=606624d44113&friendlyFileName=undefined&Locale=en-US&sessionID=$sid"
    # The session must pass the page's bot check (ov-df) before the API answers.
    $js = Invoke-RestMethod -UseBasicParsing -TimeoutSec 30 "https://ov-df.microsoft.com/mdt.js?instanceId=$inst&PageId=si&session_id=$sid"
    $w = [regex]::Match($js, '[?&]w=([A-F0-9]+)').Groups[1].Value; $rticks = [regex]::Match($js, 'rticks\="\+?(\d+)').Groups[1].Value
    Invoke-WebRequest -UseBasicParsing -TimeoutSec 30 "https://ov-df.microsoft.com/?session_id=$sid&CustomerId=$inst&PageId=si&w=$w&mdt=$([DateTimeOffset]::Now.ToUnixTimeMilliseconds())&rticks=$rticks" | Out-Null
    # 3813 = "Windows 11 Home/Pro/Edu" x64
    $r = Invoke-RestMethod -UseBasicParsing -TimeoutSec 30 "$api/getskuinformationbyproductedition?productEditionId=3813&SKU=undefined&$q"
    $sku = @($r.Skus) | Where-Object Language -eq $name | Select-Object -First 1
    if (-not $sku) { throw "Microsoft's download page has no $name ISO$(if ($r.Errors) { ": $(@($r.Errors)[0].Value)" })" }
    $r = Invoke-RestMethod -UseBasicParsing -TimeoutSec 30 -Headers @{ Referer = 'https://www.microsoft.com/software-download/windows11' } `
        "$api/GetProductDownloadLinksBySku?productEditionId=undefined&SKU=$($sku.Id)&$q"
    # Sentinel = Microsoft's rate limit: several link requests in a short time (or a VPN) get this IP blocked for a while.
    if ($r.Errors) { throw "Microsoft refused the download link ($(@($r.Errors)[0].Value)). Usually too many requests from this IP or a VPN: try again in a few hours or pick UUP dump as the download source." }
    $url = @($r.ProductDownloadOptions | ForEach-Object Uri | Where-Object { $_ -match 'x64' })[0]
    if (-not $url) { throw "Microsoft's download page returned no x64 link for $name" }
    [pscustomobject]@{ Url = $url; Build = [regex]::Match($sku.ProductDisplayName, 'Build (\d+)').Groups[1].Value; File = [regex]::Match($url, '[^/?]+\.iso').Value }
}

# Streams $Url to $Dest ($Dest.part until complete), logging every 10%. $Cancelled as in Save-UupIso.
# A dropped connection (hotspot, Wi-Fi) can leave a read hanging forever: no data for $StallSeconds counts
# as lost, and the download resumes where it stopped (HTTP Range), up to $Retries times in a row.
function Save-Download($Url, $Dest, [scriptblock]$Cancelled = { $false }, [int]$StallSeconds = 60, [int]$Retries = 5) {
    Add-Type -AssemblyName System.Net.Http
    $client = New-Object Net.Http.HttpClient
    $client.Timeout = [Threading.Timeout]::InfiniteTimeSpan
    $ms = $StallSeconds * 1000; $done = [long]0; $total = $null; $next = 10; $fails = 0
    try {
        $out = [IO.File]::Create("$Dest.part")
        $buf = New-Object byte[] (1MB)
        try {
            while ($true) {
                $resp = $null; $in = $null
                try {
                    $req = New-Object Net.Http.HttpRequestMessage ([Net.Http.HttpMethod]::Get), $Url
                    if ($done) { $req.Headers.Range = New-Object Net.Http.Headers.RangeHeaderValue $done, $null }
                    $t = $client.SendAsync($req, [Net.Http.HttpCompletionOption]::ResponseHeadersRead)
                    if (-not $t.Wait($ms)) { throw "no answer for $StallSeconds s" }
                    $resp = $t.Result
                    if (-not $resp.IsSuccessStatusCode) { throw "HTTP $([int]$resp.StatusCode) $($resp.ReasonPhrase)" }
                    if ([int]$resp.StatusCode -eq 206) { $total = $resp.Content.Headers.ContentRange.Length }
                    else {
                        # Server ignored the range: start over
                        if ($done) { $out.SetLength(0); $done = 0; $next = 10 }
                        $total = $resp.Content.Headers.ContentLength
                    }
                    $in = $resp.Content.ReadAsStreamAsync().GetAwaiter().GetResult()
                    while ($true) {
                        $rt = $in.ReadAsync($buf, 0, $buf.Length)
                        if (-not $rt.Wait($ms)) { throw "no data for $StallSeconds s" }
                        if (($n = $rt.Result) -le 0) { break }
                        $out.Write($buf, 0, $n); $done += $n; $fails = 0
                        if (& $Cancelled) { throw 'Cancelled by user' }
                        if ($total -and $done * 100 / $total -ge $next) { Write-Log "  $next% of $([math]::Round($total / 1GB, 1)) GB"; $next += 10 }
                    }
                    if ($total -and $done -lt $total) { throw "connection closed at $done of $total bytes" }
                    break
                } catch {
                    if (& $Cancelled) { throw 'Cancelled by user' }
                    $why = $_.Exception.GetBaseException().Message
                    if (++$fails -gt $Retries) { throw "Download failed after $Retries retries: $why" }
                    Write-Log "  connection lost ($why), resuming at $([math]::Round($done / 1GB, 2)) GB (try $fails of $Retries)"
                    Start-Sleep -Seconds ([math]::Min(5, $StallSeconds))
                } finally { if ($in) { $in.Dispose() }; if ($resp) { $resp.Dispose() } }
            }
        } finally { $out.Close() }
        if ($total -and $done -ne $total) { throw "Download incomplete: $done of $total bytes" }
        Move-Item "$Dest.part" $Dest -Force
    } catch { Remove-Item "$Dest.part" -Force -ErrorAction SilentlyContinue; throw }
    finally { $client.Dispose() }
}
