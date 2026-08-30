<#
.SYNOPSIS
    One-line installer for Scout Companion.

.DESCRIPTION
    Fetches the latest release, unpacks it to a temporary folder and runs the
    installer in it, so installing does not mean visiting a releases page,
    choosing a file, and finding somewhere to unzip it:

      irm https://raw.githubusercontent.com/akimcse/scout-companion/main/web-install.ps1 | iex

    This is the "pipe a script off the internet into your shell" pattern, and
    it deserves the suspicion it usually gets. Two things make it checkable
    here: what you are reading now is the whole of it, at the URL above, and
    everything it installs comes from a published release asset rather than
    from whatever happens to be on a branch.

    If you would rather not, the manual route is three steps and no worse:
    download the zip from the releases page, unzip it, double-click Install.cmd.

.PARAMETER Tag
    Install a specific release, e.g. -Tag v0.2.0. Defaults to the latest.

.PARAMETER Beta
    Also consider releases marked as pre-releases, and install one if it is
    newer than the newest finished release. Ignored when -Tag is given, since
    that names a release outright. Because a piped script cannot take
    parameters, this needs the scriptblock form - and the download has to go
    through WebClient rather than Invoke-RestMethod, which keeps a byte order
    mark that the parser then reads as the first token:

      & ([scriptblock]::Create((New-Object Net.WebClient).DownloadString('https://raw.githubusercontent.com/akimcse/scout-companion/main/web-install.ps1'))) -Beta

.PARAMETER NoRun
    Install without starting the companion afterwards.
#>

#Requires -Version 5.0
[CmdletBinding()]
param(
    [string]$Tag,
    [switch]$Beta,
    [switch]$NoRun
)

$ErrorActionPreference = 'Stop'
$Repo = 'akimcse/scout-companion'

# Windows PowerShell 5 defaults to TLS 1.0 in some configurations, which
# GitHub refuses outright. Additive so nothing already enabled is turned off.
try {
    [Net.ServicePointManager]::SecurityProtocol =
        [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12
} catch { }

Write-Host ''
Write-Host 'Scout Companion'
Write-Host '  looking up the release...'

if ($Tag) {
    try {
        $release = Invoke-RestMethod -Uri "https://api.github.com/repos/$Repo/releases/tags/$Tag" `
            -Headers @{ 'User-Agent' = 'scout-companion-installer' }
    } catch {
        throw "Could not reach GitHub: $($_.Exception.Message)"
    }
} else {
    # /releases, not /releases/latest.
    #
    # This repository also holds a .NET rewrite, whose releases are tagged
    # "net-v...". /latest returns whichever release is newest whatever its tag,
    # so once one of those was newest this installer would have downloaded a
    # .NET build and unpacked it over a PowerShell install - a wrong success
    # rather than a failure, and every "irm ... | iex" would have hit it.
    #
    # This build owns bare "v0.12.0". Anything with a prefix is someone else's.
    try {
        $all = Invoke-RestMethod -Uri "https://api.github.com/repos/$Repo/releases?per_page=30" `
            -Headers @{ 'User-Agent' = 'scout-companion-installer' }
    } catch {
        throw "Could not reach GitHub: $($_.Exception.Message)"
    }

    # By version, not by position: the API orders by publication date, and a
    # patch to an older line published later would otherwise win.
    #
    # The pre-release suffix is part of that order, not noise to be stripped.
    # Stripping it made v0.13.0-beta.2 equal to v0.13.0, so with -Beta the
    # winner was whichever GitHub happened to list first - and someone asking
    # for previews could be handed the beta again after the release it led to
    # had shipped. This is deliberately a second copy of the comparison in
    # scout-companion.ps1: this file is fetched and run on its own, so it
    # cannot borrow anything. Test-SessionMatch.ps1 pins the two to agree.
    function Compare-Tag([string]$x, [string]$y) {
        function Nums([string]$v) {
            $v = ([string]$v).Trim().TrimStart('v', 'V')
            $p = @((($v -split '[-+]')[0]) -split '\.' | ForEach-Object {
                $n = 0
                if ([int]::TryParse(($_ -replace '\D', ''), [ref]$n)) { $n } else { 0 }
            })
            while ($p.Count -lt 3) { $p += 0 }
            return $p
        }
        function Pre([string]$v) {
            $v = (([string]$v).Trim().TrimStart('v', 'V') -split '\+')[0]
            $i = $v.IndexOf('-')
            if ($i -lt 0) { return '' }
            return $v.Substring($i + 1)
        }
        $a = Nums $x; $b = Nums $y
        for ($i = 0; $i -lt 3; $i++) {
            if ($a[$i] -gt $b[$i]) { return 1 }
            if ($a[$i] -lt $b[$i]) { return -1 }
        }
        $pa = Pre $x; $pb = Pre $y
        if ($pa -eq $pb) { return 0 }
        if (-not $pa) { return 1 }        # a release beats the betas leading to it
        if (-not $pb) { return -1 }
        $ax = $pa -split '\.'; $bx = $pb -split '\.'
        $n = [Math]::Max($ax.Count, $bx.Count)
        for ($i = 0; $i -lt $n; $i++) {
            if ($i -ge $ax.Count) { return -1 }   # beta precedes beta.1
            if ($i -ge $bx.Count) { return 1 }
            $ln = 0; $rn = 0
            $l = [int]::TryParse($ax[$i], [ref]$ln)
            $r = [int]::TryParse($bx[$i], [ref]$rn)
            if ($l -and $r) {
                if ($ln -ne $rn) { return [Math]::Sign($ln - $rn) }
            } elseif ($l) { return -1 }           # numeric identifiers rank lowest
            elseif ($r) { return 1 }
            else {
                $c = [string]::CompareOrdinal($ax[$i], $bx[$i])
                if ($c -ne 0) { return [Math]::Sign($c) }
            }
        }
        return 0
    }

    $release = $null
    foreach ($r in @($all)) {
        if (-not $r -or -not $r.tag_name) { continue }
        if ($r.tag_name -notmatch '^[vV]?\d+\.\d+\.\d+([-+][0-9A-Za-z.+-]*)?$') { continue }
        if ($r.prerelease -and -not $Beta) { continue }
        if (-not $release -or (Compare-Tag $r.tag_name $release.tag_name) -gt 0) { $release = $r }
    }
    if (-not $release) {
        $what = if ($Beta) { 'release' } else { 'stable release' }
        throw "No $what found for this build. See https://github.com/$Repo/releases"
    }
}

$asset = $release.assets | Where-Object { $_.name -like 'ScoutCompanion-*.zip' } | Select-Object -First 1
if (-not $asset) {
    throw "Release $($release.tag_name) has no ScoutCompanion zip attached. Install it from the source instead: https://github.com/$Repo/releases"
}
Write-Host ("  {0}, {1:N0} KB" -f $release.tag_name, ($asset.size / 1KB))

$work = Join-Path ([System.IO.Path]::GetTempPath()) ("scoutcompanion-{0}" -f ([guid]::NewGuid().ToString('N')))
New-Item -ItemType Directory -Path $work -Force | Out-Null
try {
    $zip = Join-Path $work $asset.name
    Write-Host '  downloading...'
    # Invoke-WebRequest with a progress bar is dramatically slower on Windows
    # PowerShell 5 - it repaints the console for every chunk.
    $prev = $ProgressPreference
    $ProgressPreference = 'SilentlyContinue'
    try {
        Invoke-WebRequest -Uri $asset.browser_download_url -OutFile $zip -UseBasicParsing
    } finally { $ProgressPreference = $prev }

    Expand-Archive -Path $zip -DestinationPath $work -Force
    $installer = Join-Path $work 'ScoutCompanion\Install.ps1'
    if (-not (Test-Path $installer)) {
        throw "The downloaded package does not look right - Install.ps1 is missing from it."
    }

    if ($NoRun) { & $installer } else { & $installer -Run }
} finally {
    Remove-Item $work -Recurse -Force -ErrorAction SilentlyContinue
}
