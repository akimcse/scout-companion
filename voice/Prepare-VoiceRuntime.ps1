<#
.SYNOPSIS
    Prepares the optional local voice runtime for Scout Companion.

.DESCRIPTION
    Copies the bundled Python sources, creates a per-user virtual environment,
    installs the speech packages, and downloads the three on-device models used
    for Korean speech recognition, voice activity detection, and enrollment.
    It does not enable voice control or register any startup task.
#>

#Requires -Version 5.0
[CmdletBinding()]
param([string]$InstallDir)

$ErrorActionPreference = 'Stop'
$SourceDir = Join-Path (Split-Path -Parent $MyInvocation.MyCommand.Path) 'runtime'
if (-not $InstallDir) {
    $InstallDir = Join-Path $env:LOCALAPPDATA 'ScoutVoiceAssistant'
}
$ModelsDir = Join-Path $InstallDir 'models'
$VenvDir = Join-Path $InstallDir '.venv'
$Python = Join-Path $VenvDir 'Scripts\python.exe'

if (-not (Test-Path (Join-Path $SourceDir 'agent.py'))) {
    throw "Voice runtime sources are missing from $SourceDir."
}
if (-not (Get-Command python -ErrorAction SilentlyContinue)) {
    throw 'Python 3.11 or later is required for voice control.'
}
$pythonVersion = & python -c "import sys; print(f'{sys.version_info.major}.{sys.version_info.minor}')"
if ($LASTEXITCODE -ne 0 -or [version]$pythonVersion -lt [version]'3.11') {
    throw 'Python 3.11 or later is required for voice control.'
}

$newInstall = -not (Test-Path $InstallDir)
New-Item -ItemType Directory -Path $InstallDir, $ModelsDir -Force | Out-Null
if ($newInstall) {
    Set-Content (Join-Path $InstallDir '.managed-by-scout-companion') `
        -Value 'Scout Companion optional voice runtime' -Encoding Ascii
}
Copy-Item (Join-Path $SourceDir '*') $InstallDir -Recurse -Force

if (-not (Test-Path $Python)) {
    & python -m venv $VenvDir
    if ($LASTEXITCODE -ne 0) { throw 'Could not create the voice Python environment.' }
}

& $Python -m pip install --disable-pip-version-check --quiet `
    -r (Join-Path $InstallDir 'requirements.txt')
if ($LASTEXITCODE -ne 0) { throw 'Could not install the voice Python packages.' }

function Get-Model(
        [string]$Url, [string]$Destination, [string]$Description,
        [string]$Sha256) {
    if (Test-Path $Destination) {
        $existing = (Get-FileHash $Destination -Algorithm SHA256).Hash
        if ($existing -eq $Sha256) { return }
        Remove-Item $Destination -Force
    }
    Write-Host "Downloading $Description..."
    & curl.exe -L --fail --retry 3 $Url -o $Destination
    if ($LASTEXITCODE -ne 0) { throw "Could not download $Description." }
    $actual = (Get-FileHash $Destination -Algorithm SHA256).Hash
    if ($actual -ne $Sha256) {
        Remove-Item $Destination -Force -ErrorAction SilentlyContinue
        throw "$Description failed its SHA-256 check."
    }
}

$senseFolder = Join-Path $ModelsDir 'sherpa-onnx-sense-voice-zh-en-ja-ko-yue-int8-2024-07-17'
$senseModel = Join-Path $senseFolder 'model.int8.onnx'
if (-not (Test-Path $senseModel)) {
    $archive = Join-Path $ModelsDir 'sensevoice-int8.tar.bz2'
    Get-Model `
        'https://github.com/k2-fsa/sherpa-onnx/releases/download/asr-models/sherpa-onnx-sense-voice-zh-en-ja-ko-yue-int8-2024-07-17.tar.bz2' `
        $archive 'Korean speech recognition model (about 156 MB)' `
        '7D1EFA2138A65B0B488DF37F8B89E3D91A60676E416F515B952358D83DFD347E'
    & tar.exe -xjf $archive -C $ModelsDir
    if ($LASTEXITCODE -ne 0 -or -not (Test-Path $senseModel)) {
        throw 'Could not extract the Korean speech recognition model.'
    }
    Remove-Item $archive -Force
}

Get-Model `
    'https://github.com/k2-fsa/sherpa-onnx/releases/download/asr-models/silero_vad.int8.onnx' `
    (Join-Path $ModelsDir 'silero_vad.int8.onnx') `
    'voice activity model' `
    'C36D490AFF5AB924CA6C7AEEC4D8F6BD3D22DB6FA17611B9C5B17EAE58AC3A20'

Get-Model `
    'https://github.com/k2-fsa/sherpa-onnx/releases/download/speaker-recongition-models/3dspeaker_speech_eres2net_base_sv_zh-cn_3dspeaker_16k.onnx' `
    (Join-Path $ModelsDir '3dspeaker_speech_eres2net_base_sv_zh-cn_3dspeaker_16k.onnx') `
    'speaker enrollment model (about 38 MB)' `
    '1A331345F04805BADBB495C775A6DDFFCDD1A732567D5EC8B3D5749E3C7A5E4B'

Push-Location $InstallDir
try {
    & $Python -c "from voice_runtime import VoiceModels; VoiceModels(); print('Voice runtime ready')"
    if ($LASTEXITCODE -ne 0) { throw 'The prepared voice runtime failed its startup check.' }
} finally {
    Pop-Location
}
