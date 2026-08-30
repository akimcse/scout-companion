<#
.SYNOPSIS
    Downloads and verifies the local speech models shared by both voice engines.
#>

#Requires -Version 5.0
[CmdletBinding()]
param([Parameter(Mandatory = $true)][string]$InstallDir)

$ErrorActionPreference = 'Stop'
$ModelsDir = Join-Path $InstallDir 'models'
$newInstall = -not (Test-Path $InstallDir)
New-Item -ItemType Directory -Path $InstallDir, $ModelsDir -Force | Out-Null
if ($newInstall) {
    Set-Content (Join-Path $InstallDir '.managed-by-scout-companion') `
        -Value 'Scout Companion optional voice runtime' -Encoding Ascii
}

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
$senseTokens = Join-Path $senseFolder 'tokens.txt'
if (-not (Test-Path $senseModel) -or -not (Test-Path $senseTokens)) {
    if (Test-Path $senseFolder) {
        Remove-Item $senseFolder -Recurse -Force
    }
    $archive = Join-Path $ModelsDir 'sensevoice-int8.tar.bz2'
    Get-Model `
        'https://github.com/k2-fsa/sherpa-onnx/releases/download/asr-models/sherpa-onnx-sense-voice-zh-en-ja-ko-yue-int8-2024-07-17.tar.bz2' `
        $archive 'multilingual speech recognition model (about 156 MB)' `
        '7D1EFA2138A65B0B488DF37F8B89E3D91A60676E416F515B952358D83DFD347E'
    $extractRoot = Join-Path $ModelsDir (
        '.sensevoice-' + [guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory -Path $extractRoot | Out-Null
    & tar.exe -xjf $archive -C $extractRoot
    $extracted = Join-Path $extractRoot (
        'sherpa-onnx-sense-voice-zh-en-ja-ko-yue-int8-2024-07-17')
    if ($LASTEXITCODE -ne 0 -or
            -not (Test-Path (Join-Path $extracted 'model.int8.onnx')) -or
            -not (Test-Path (Join-Path $extracted 'tokens.txt'))) {
        Remove-Item $extractRoot -Recurse -Force -ErrorAction SilentlyContinue
        throw 'Could not extract the speech recognition model.'
    }
    Move-Item $extracted $senseFolder
    Remove-Item $extractRoot -Recurse -Force -ErrorAction SilentlyContinue
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
