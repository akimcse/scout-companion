<#
.SYNOPSIS
    Packages a release zip.

.DESCRIPTION
    Builds ScoutCompanion-<version>.zip containing only what is needed to run
    and install the app. GitHub's own source archive carries the test suites and
    the documentation screenshots too, which is most of its size and none of its
    use to somebody who just wants to run this.

    The version comes from scout-companion.ps1, so the zip cannot disagree with
    what the app reports about itself.

.PARAMETER OutDir
    Where to write the zip. Defaults to dist\ beside this script.

.EXAMPLE
    powershell -ExecutionPolicy Bypass -File .\Build-Release.ps1
#>

#Requires -Version 5.0
[CmdletBinding()]
param([string]$OutDir)

$ErrorActionPreference = 'Stop'
$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
if (-not $OutDir) { $OutDir = Join-Path $ScriptDir 'dist' }

# Everything a user needs and nothing they do not. Install.ps1 is in here as
# well as being the thing that installs: it is also the uninstaller, so it has
# to travel with the app.
$Payload = @(
    'scout-companion.ps1'
    'Start-ScoutCompanion.cmd'
    'Watch-Scout.ps1'
    'Add-ToStartMenu.ps1'
    'Install.ps1'
    'Install.cmd'
    'config.sample.json'
    'LICENSE'
    'README.md'
)

$verFile = Join-Path $ScriptDir 'scout-companion.ps1'
$m = [regex]::Match((Get-Content $verFile -Raw), "(?m)^\`$CompanionVersion\s*=\s*'([^']+)'")
if (-not $m.Success) { throw 'Could not read $CompanionVersion from scout-companion.ps1' }
$version = $m.Groups[1].Value

foreach ($f in $Payload) {
    if (-not (Test-Path (Join-Path $ScriptDir $f))) { throw "$f is missing" }
}
$langDir = Join-Path $ScriptDir 'lang'
if (-not (Test-Path $langDir)) { throw 'lang folder is missing' }

# Staged in a temp folder so the zip has a single top-level directory - one
# that unzips into a folder rather than spraying files wherever it was opened.
$stageRoot = Join-Path ([System.IO.Path]::GetTempPath()) ("scpkg-{0}" -f ([guid]::NewGuid().ToString('N')))
$stage = Join-Path $stageRoot 'ScoutCompanion'
New-Item -ItemType Directory -Path $stage -Force | Out-Null
try {
    foreach ($f in $Payload) { Copy-Item (Join-Path $ScriptDir $f) (Join-Path $stage $f) -Force }
    Copy-Item $langDir $stage -Recurse -Force

    New-Item -ItemType Directory -Path $OutDir -Force | Out-Null
    $zip = Join-Path $OutDir ("ScoutCompanion-{0}.zip" -f $version)
    if (Test-Path $zip) { Remove-Item $zip -Force }
    Compress-Archive -Path $stage -DestinationPath $zip -CompressionLevel Optimal

    $files = (Get-ChildItem $stage -Recurse -File).Count
    $size  = (Get-Item $zip).Length
    Write-Host ''
    Write-Host ("built  {0}" -f $zip)
    Write-Host ("       {0} files, {1:N0} KB" -f $files, ($size / 1KB))
    Write-Host ''
    return $zip
} finally {
    Remove-Item $stageRoot -Recurse -Force -ErrorAction SilentlyContinue
}
