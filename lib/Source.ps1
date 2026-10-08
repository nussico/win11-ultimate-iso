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
        try {
            $info = Get-IsoInfo $iso.FullName
            # Fast-mode UUP ISOs hold the older base build (e.g. 26100); the sidecar records the release they came from.
            if (Test-Path "$($iso.FullName).build") { $info.Build = (Get-Content "$($iso.FullName).build").Split('.')[0] }
            $info
        } catch { Write-Warning "$($iso.Name): $_" }
    }
}

# What a build will use: base ISO, editions to download, UUP build. Shared by the build and the GUI's plan.
function Get-BuildPlan($Isos, $Builds, $Cfg) {
    $p = @{ Base = $null; Newest = (Select-NewestUupBuild $Builds); Missing = @(); Uup = $null; Note = $null; Error = $null }
    $p.Base = $Isos | Where-Object Lang -eq $Cfg.BaseLang | Sort-Object { [int]$_.Build } -Descending | Select-Object -First 1
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

# Newest general release: highest "Windows 11, version YYH2" build, newest revision.
# ponytail: H2-only rule skips hardware-only releases like 26H1; revisit if Microsoft ships a general H1 again.
function Select-NewestUupBuild($Builds) {
    $Builds | Where-Object { $_.title -match '^Windows 11, version \d\dH2 ' } |
        Sort-Object { [version]"10.0.$($_.build)" } -Descending | Select-Object -First 1
}

function Get-UupLanguages($Uuid) {
    @((Invoke-RestMethod "$UupApi/listlangs.php?id=$Uuid" -TimeoutSec 20).response.langList | Where-Object { $_ -ne 'neutral' } | Sort-Object)
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
