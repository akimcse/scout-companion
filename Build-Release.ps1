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
    'Start-ScoutCompanion.vbs'
    'Watch-Scout.ps1'
    'Watch-Scout.vbs'
    'Add-ToStartMenu.ps1'
    'Install.ps1'
    'Install.cmd'
    'voice'
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
    foreach ($f in $Payload) {
        $source = Join-Path $ScriptDir $f
        $destination = Join-Path $stage $f
        if (Test-Path $source -PathType Container) {
            Copy-Item $source $destination -Recurse -Force
        } else {
            Copy-Item $source $destination -Force
        }
    }
    Copy-Item $langDir $stage -Recurse -Force
    Get-ChildItem $stage -Directory -Filter '__pycache__' -Recurse |
        Remove-Item -Recurse -Force
    Get-ChildItem $stage -File -Filter '*.pyc' -Recurse |
        Remove-Item -Force
    Get-ChildItem $stage -Directory -Recurse |
        Where-Object { $_.Name -in @('bin', 'obj', 'publish-test') } |
        Remove-Item -Recurse -Force
    $stagedPublish = Join-Path $stage 'voice\dotnet\publish'
    if (Test-Path $stagedPublish) {
        Remove-Item $stagedPublish -Recurse -Force
    }
    Get-ChildItem (Join-Path $stage 'voice\dotnet') -Directory -Filter 'publish-*' `
        -ErrorAction SilentlyContinue | Remove-Item -Recurse -Force

    $voiceProject = Join-Path $ScriptDir 'voice\dotnet\ScoutVoiceEngine\ScoutVoiceEngine.csproj'
    if (-not (Test-Path $voiceProject)) {
        throw 'The .NET voice engine project is missing.'
    }
    foreach ($runtime in 'win-arm64', 'win-x64') {
        $publishDir = Join-Path $stage "voice\dotnet\publish\$runtime"
        & dotnet publish $voiceProject -c Release -r $runtime `
            --self-contained false -p:DebugType=None -o $publishDir
        if ($LASTEXITCODE -ne 0) {
            throw "Could not publish the .NET voice engine for $runtime."
        }
        foreach ($requiredFile in @(
                'ScoutVoiceEngine.exe',
                'ScoutVoiceEngine.dll',
                'ScoutVoiceEngine.deps.json',
                'ScoutVoiceEngine.runtimeconfig.json',
                'sherpa-onnx-c-api.dll',
                'scout-listening.wav')) {
            if (-not (Test-Path (Join-Path $publishDir $requiredFile))) {
                throw "The $runtime voice package is incomplete: $requiredFile is missing."
            }
        }
    }

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
