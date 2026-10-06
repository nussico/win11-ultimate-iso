# Source detection (own ISOs) and UUP dump downloads.

$UupApi = 'https://api.uupdump.net'
# Editions UUP dump can produce: retail ones directly, the rest as virtual editions built from Pro.
$UupEditions = [ordered]@{
    'Windows 11 Home'       = @{ Uup = 'CORE' }
    'Windows 11 Pro'        = @{ Uup = 'PROFESSIONAL' }
    'Windows 11 Education'  = @{ Virtual = 'Education' }
    'Windows 11 Enterprise' = @{ Virtual = 'Enterprise' }
}
$LpPattern = 'LanguagePack-Package|LanguageFeatures-(Basic|Handwriting|OCR)-'

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
    "$(($img | Get-Volume).DriveLetter):"
}

function Get-IsoInfo($Path) {
    try {
        $wim = Get-InstallImage (Mount-Iso $Path)
        ConvertTo-IsoInfo $Path (Get-WindowsImage -ImagePath $wim) (Get-WindowsImage -ImagePath $wim -Index 1)
    } finally { Dismount-DiskImage -ImagePath $Path | Out-Null }
}

function Get-SourceIsos($Folder) {
    foreach ($iso in Get-ChildItem $Folder -Filter *.iso -ErrorAction SilentlyContinue) {
        try { Get-IsoInfo $iso.FullName } catch { Write-Warning "$($iso.Name): $_" }
    }
}

function Get-UupBuilds {
    $b = (Invoke-RestMethod "$UupApi/listid.php?search=Windows%2011%2C%20version&sortByDate=1").response.builds
    @($b.PSObject.Properties.Value | Where-Object arch -eq 'amd64')
}

# Newest "Windows 11, version ..." build with the given major build number (e.g. 26200).
function Select-UupBuild($Builds, $Major) {
    $Builds | Where-Object { $_.title -like 'Windows 11, version*' -and $_.build -like "$Major.*" } |
        Sort-Object { [version]"10.0.$($_.build)" } -Descending | Select-Object -First 1
}

# Newest general release: highest "Windows 11, version YYH2" build, newest revision.
# ponytail: H2-only rule skips hardware-only releases like 26H1; revisit if Microsoft ships a general H1 again.
function Select-NewestUupBuild($Builds) {
    $Builds | Where-Object { $_.title -match '^Windows 11, version \d\dH2 ' } |
        Sort-Object { [version]"10.0.$($_.build)" } -Descending | Select-Object -First 1
}

function Get-UupLanguages($Uuid) {
    @((Invoke-RestMethod "$UupApi/listlangs.php?id=$Uuid").response.langList | Where-Object { $_ -ne 'neutral' } | Sort-Object)
}

function Save-Url($Url, $Out, $Sha1) {
    $ErrorActionPreference = 'Continue'
    if ((Test-Path $Out) -and (Get-FileHash $Out -Algorithm SHA1).Hash -eq $Sha1) { return }
    curl.exe -sSL --retry 3 -o $Out $Url
    if ($LASTEXITCODE) { throw "Download failed: $Out" }
    if ($Sha1 -and (Get-FileHash $Out -Algorithm SHA1).Hash -ne $Sha1) { throw "Checksum mismatch: $Out" }
}

# Downloads the language pack + basic FoDs. Returns @{ Build; Lp = <expanded folder>; Fods = <cab paths> }.
function Save-UupLanguagePack($Uuid, $Lang, $Dest) {
    $r = (Invoke-RestMethod "$UupApi/get.php?id=$Uuid&lang=$Lang&edition=professional").response
    $dir = New-Item -ItemType Directory -Force "$Dest\$Lang"
    $files = $r.files.PSObject.Properties | Where-Object Name -match $LpPattern
    if (-not ($files | Where-Object Name -match 'LanguagePack')) { throw "No language pack for $Lang in UUP build $($r.build)" }
    foreach ($f in $files) { Save-Url $f.Value.url "$dir\$($f.Name)" $f.Value.sha1 }
    # UUP ships the LP as .esd; DISM installs it from the expanded folder (update.mum).
    $esd = Get-ChildItem $dir -Filter '*LanguagePack*.esd' | Select-Object -First 1
    $lp = "$dir\lp"
    if (-not (Test-Path "$lp\update.mum")) {
        New-Item -ItemType Directory -Force $lp | Out-Null
        Expand-WindowsImage -ImagePath $esd.FullName -Index 1 -ApplyPath $lp | Out-Null
    }
    # FoDs install as capabilities from a source folder that uses the canonical repository file names.
    $fod = New-Item -ItemType Directory -Force "$dir\fod"
    $features = @()
    foreach ($feat in 'Basic', 'Handwriting', 'OCR') {
        $cab = Get-ChildItem $dir -Filter "*LanguageFeatures-$feat-*.cab" | Select-Object -First 1
        if (-not $cab) { continue }
        Copy-Item $cab.FullName "$fod\Microsoft-Windows-LanguageFeatures-$feat-$Lang-Package~31bf3856ad364e35~amd64~~.cab" -Force
        $features += "Language.$feat~~~$(Get-CapabilityLang $Lang)~0.0.1.0"
    }
    @{ Build = $r.build; Lp = $lp; FodDir = $fod.FullName; Capabilities = $features }
}

# 'en-us' -> 'en-US', 'sr-latn-rs' -> 'sr-Latn-RS' (casing used in capability names)
function Get-CapabilityLang($Lang) { [Globalization.CultureInfo]::GetCultureInfo($Lang).Name }

# UUP dump package request. Fast = skip integrating the latest cumulative update (Windows Update installs it later).
function Get-UupRequest([string[]]$EditionNames, [bool]$Fast) {
    $direct = @($EditionNames | ForEach-Object { $UupEditions[$_].Uup } | Where-Object { $_ })
    $virtual = @($EditionNames | ForEach-Object { $UupEditions[$_].Virtual } | Where-Object { $_ })
    if ($virtual -and 'PROFESSIONAL' -notin $direct) { $direct += 'PROFESSIONAL' }
    @{
        Edition = $direct -join ';'
        Virtual = $virtual
        Updates = [int](-not $Fast)
        Body    = "autodl=$(if ($virtual) { 3 } else { 2 })&updates=$([int](-not $Fast))&cleanup=0" + (($virtual | ForEach-Object { "&virtualEditions[]=$_" }) -join '')
    }
}

# Builds an ISO with UUP dump's own download+convert package. Returns the ISO path.
function Save-UupIso($Uuid, $Lang, [string[]]$EditionNames, $Dest, [bool]$Fast) {
    $req = Get-UupRequest $EditionNames $Fast
    New-Item -ItemType Directory -Force $Dest | Out-Null
    $zip = "$Dest\uup.zip"
    Invoke-WebRequest -UseBasicParsing -Method Post -Body $req.Body -ContentType 'application/x-www-form-urlencoded' -OutFile $zip `
        "https://uupdump.net/get.php?id=$Uuid&pack=$Lang&edition=$($req.Edition)"
    Expand-Archive $zip $Dest -Force
    $ini = "$Dest\ConvertConfig.ini"
    (Get-Content $ini) -replace '^AutoExit\s*=.*', 'AutoExit    =1' -replace '^AddUpdates\s*=.*', "AddUpdates   =$($req.Updates)" `
        -replace '^vAutoEditions=.*', "vAutoEditions=$($req.Virtual -join ',')" | Set-Content $ini
    # stdin from NUL so any 'pause' returns immediately
    $p = Start-Process cmd.exe -ArgumentList '/c', 'uup_download_windows.cmd < NUL' -WorkingDirectory $Dest -Wait -PassThru -WindowStyle Minimized
    $iso = Get-ChildItem $Dest -Filter *.iso | Select-Object -First 1
    if (-not $iso) { throw "UUP dump conversion produced no ISO (exit $($p.ExitCode)); see $Dest" }
    $iso.FullName
}
