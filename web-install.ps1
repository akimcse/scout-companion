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

.PARAMETER NoRun
    Install without starting the companion afterwards.
#>

#Requires -Version 5.0
[CmdletBinding()]
param(
    [string]$Tag,
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

$api = if ($Tag) { "https://api.github.com/repos/$Repo/releases/tags/$Tag" }
       else      { "https://api.github.com/repos/$Repo/releases/latest" }

Write-Host ''
Write-Host 'Scout Companion'
Write-Host '  looking up the release...'
try {
    $release = Invoke-RestMethod -Uri $api -Headers @{ 'User-Agent' = 'scout-companion-installer' }
} catch {
    throw "Could not reach GitHub: $($_.Exception.Message)"
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
