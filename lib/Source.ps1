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
            # Fast-mode UUP ISOs hold the older base build (e.g. 26100); the sidecar records the release they came from.
            # Fast = the image is older than the release (Windows Update finishes the job after setup).
            $release = if (Test-Path "$($iso.FullName).build") { (Get-Content "$($iso.FullName).build").Split('.')[0] } else { $info.Build }
            $info | Add-Member Fast ($release -ne $info.Build) -PassThru | Add-Member Build $release -Force -PassThru
        } catch { Write-Warning "$($iso.Name): $_" }
    }
}

# A Fast-mode ISO holds the old base image (e.g. 24H2 for a 26H2 download): with Fast mode off and UUP on, a full
# download replaces it instead of mixing its editions and setup files into a full build. Without UUP it's all there is.
function Test-UsableIso($Iso, $Cfg) { -not ($Iso.Fast -and $Cfg.UseUup -and -not $Cfg.Fast) }

# What a build will use: base ISO, editions to download, UUP build. Shared by the build and the GUI's plan.
function Get-BuildPlan($Isos, $Builds, $Cfg) {
    $p = @{ Base = $null; Newest = (Select-NewestUupBuild $Builds); Missing = @(); Uup = $null; Note = $null; Error = $null; Skipped = $null }
    if ($Cfg.Newest -and -not $Cfg.UupBuild) { $p.Skipped = Get-SkippedNewerRelease $Builds $p.Newest }
    $isos = @($Isos | Where-Object { $_.Lang -eq $Cfg.BaseLang -and (Test-UsableIso $_ $Cfg) })
    # With UUP: an ISO with exactly the ticked editions (only Pro -> a Pro-only ISO, downloaded once and kept next to
    # the multi-edition one). Without UUP (or UUP unreachable) any of your ISOs.
    if ($Cfg.UseUup -and $Builds) {
        $want = Get-DownloadEditions $Cfg.Editions
        $fit = @($isos | Where-Object { -not (Compare-Object @($_.Editions.Name) $want) })
        if ($isos -and -not $fit) { $p.Note = "None of your ISOs has exactly $($Cfg.Editions -join ', '): downloading one with just these (kept for next builds)" }
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

# UUP dump package request. Fast = skip integrating the latest cumulative update (Windows Update installs it later).
function Get-UupRequest([string[]]$EditionNames, [bool]$Fast) {
    $direct = @($EditionNames | ForEach-Object { $UupEditions[$_].Uup } | Where-Object { $_ })
    $virtual = @($EditionNames | ForEach-Object { $UupEditions[$_].Virtual } | Where-Object { $_ })
    if ($virtual -and 'PROFESSIONAL' -notin $direct) { $direct += 'PROFESSIONAL' }
    @{
        Edition = $direct -join ';'
        Virtual = $virtual
        Updates = [int](-not $Fast)
        # cleanup=1 (+ ResetBase in Save-UupIso): drop the files the update replaced, otherwise ~6 GB more per edition
        Body    = "autodl=$(if ($virtual) { 3 } else { 2 })&updates=$([int](-not $Fast))&cleanup=1" + (($virtual | ForEach-Object { "&virtualEditions[]=$_" }) -join '')
    }
}

# Builds an ISO with UUP dump's own download+convert package. Returns the ISO path.
# $Cancelled: returns $true when the user cancelled; the download (cmd + aria2c + converter) is then stopped.
function Save-UupIso($Uuid, $Lang, [string[]]$EditionNames, $Dest, [bool]$Fast, [scriptblock]$Cancelled = { $false }) {
    $req = Get-UupRequest $EditionNames $Fast
    New-Item -ItemType Directory -Force $Dest | Out-Null
    $zip = "$Dest\uup.zip"
    Invoke-WebRequest -UseBasicParsing -Method Post -Body $req.Body -ContentType 'application/x-www-form-urlencoded' -OutFile $zip `
        "https://uupdump.net/get.php?id=$Uuid&pack=$Lang&edition=$($req.Edition)"
    Expand-Archive $zip $Dest -Force
    $ini = "$Dest\ConvertConfig.ini"
    (Get-Content $ini) -replace '^AutoExit\s*=.*', 'AutoExit    =1' -replace '^AddUpdates\s*=.*', "AddUpdates   =$($req.Updates)" `
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
