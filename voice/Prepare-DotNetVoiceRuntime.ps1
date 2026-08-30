<#
.SYNOPSIS
    Prepares the private .NET runtime and speech models for voice control.

.DESCRIPTION
    Installs only the current Windows architecture under the user's local
    ScoutVoiceAssistant folder. Nothing is installed globally and no Python
    runtime, service, startup task, or PATH entry is created.
#>

#Requires -Version 5.0
[CmdletBinding()]
param(
    [string]$InstallDir,
    [string]$EngineDll
)

$ErrorActionPreference = 'Stop'
if (-not $InstallDir) {
    $InstallDir = Join-Path $env:LOCALAPPDATA 'ScoutVoiceAssistant'
}
$DotNetDir = Join-Path $InstallDir 'dotnet'
$Architecture = [System.Runtime.InteropServices.RuntimeInformation]::OSArchitecture.ToString().ToLowerInvariant()
$Runtime = switch ($Architecture) {
    'arm64' {
        @{
            Rid = 'win-arm64'
            CoreUrl = 'https://builds.dotnet.microsoft.com/dotnet/Runtime/8.0.30/dotnet-runtime-8.0.30-win-arm64.zip'
            CoreSha512 = 'D38B77FC3A87A0AB00BEA83B05A766DB643BDEA47EB70F47A347482E2021DCE26824C5B073C2FD418E5B324A0A0E06C39A674E19EA2BC62461F3529A674339E6'
            DesktopUrl = 'https://builds.dotnet.microsoft.com/dotnet/WindowsDesktop/8.0.30/windowsdesktop-runtime-8.0.30-win-arm64.zip'
            DesktopSha512 = '48E39FD47525B91556A306F6F5C360900265E05147AFB8AFACC570CA67207CA4E6E346EFD7EF030D1F18CB37218A228FB4783EBCE91C83634FA54FACD2EE3104'
        }
    }
    'x64' {
        @{
            Rid = 'win-x64'
            CoreUrl = 'https://builds.dotnet.microsoft.com/dotnet/Runtime/8.0.30/dotnet-runtime-8.0.30-win-x64.zip'
            CoreSha512 = '99E61C9A2D15DBB280DB98BFC3EE45DFEDA25FDB91E3D3C167789DD74328957A4F791C57AD13E8A3344DF64A27D6EF8332DD91A773072541789A1D11EE3B4439'
            DesktopUrl = 'https://builds.dotnet.microsoft.com/dotnet/WindowsDesktop/8.0.30/windowsdesktop-runtime-8.0.30-win-x64.zip'
            DesktopSha512 = '1AE0017B865E6E6FA405DAD204E6E56AEC5371C9412223128E1018AA7845FBF4B7F242A330AD594C61F7329A24FFECD61C9512FA46FC7926FD5CBD05C90BA07B'
        }
    }
    default { throw "Voice control supports Windows ARM64 and x64, not $Architecture." }
}

$newInstall = -not (Test-Path $InstallDir)
New-Item -ItemType Directory -Path $InstallDir -Force | Out-Null
if ($newInstall) {
    Set-Content (Join-Path $InstallDir '.managed-by-scout-companion') `
        -Value 'Scout Companion .NET voice runtime' -Encoding Ascii
}

$dotnet = Join-Path $DotNetDir 'dotnet.exe'
$desktop = Join-Path $DotNetDir 'shared\Microsoft.WindowsDesktop.App\8.0.30'
if (-not (Test-Path $dotnet) -or -not (Test-Path $desktop)) {
    $work = Join-Path ([IO.Path]::GetTempPath()) (
        'scout-dotnet-' + [guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory -Path $work | Out-Null
    try {
        $packages = @(
            @{
                Name = '.NET Runtime'
                File = 'dotnet-runtime.zip'
                Url = $Runtime.CoreUrl
                Hash = $Runtime.CoreSha512
            },
            @{
                Name = '.NET Desktop Runtime'
                File = 'windowsdesktop-runtime.zip'
                Url = $Runtime.DesktopUrl
                Hash = $Runtime.DesktopSha512
            }
        )
        $extract = Join-Path $work 'extract'
        New-Item -ItemType Directory -Path $extract | Out-Null
        foreach ($package in $packages) {
            $archive = Join-Path $work $package.File
            & curl.exe -L --fail --retry 3 $package.Url -o $archive
            if ($LASTEXITCODE -ne 0) { throw "Could not download $($package.Name)." }
            $actual = (Get-FileHash $archive -Algorithm SHA512).Hash
            if ($actual -ne $package.Hash) {
                throw "$($package.Name) failed its SHA-512 check."
            }
            Expand-Archive $archive $extract -Force
        }
        if (-not (Test-Path (Join-Path $extract 'dotnet.exe'))) {
            throw 'The private .NET runtime is invalid.'
        }
        if (Test-Path $DotNetDir) { Remove-Item $DotNetDir -Recurse -Force }
        Move-Item $extract $DotNetDir
    } finally {
        Remove-Item $work -Recurse -Force -ErrorAction SilentlyContinue
    }
}

& (Join-Path $PSScriptRoot 'Ensure-VoiceModels.ps1') -InstallDir $InstallDir

if ($EngineDll) {
    if (-not (Test-Path $EngineDll)) {
        throw "The .NET voice engine is missing from $EngineDll."
    }
    & $dotnet $EngineDll --probe $InstallDir
    if ($LASTEXITCODE -ne 0) {
        throw 'The .NET voice engine failed its model probe.'
    }
}

# The models and encrypted profile are shared, but the old Python interpreter,
# packages, source files, and TTS assets are no longer part of the product.
$managed = Test-Path (Join-Path $InstallDir '.managed-by-scout-companion')
if ($managed) {
    $legacyPaths = @(
        '.venv', 'tts', '__pycache__',
        'acp_client.py', 'agent.py', 'enrollment_gui.py', 'requirements.txt',
        'ring_app.py', 'voice_runtime.py', 'workiq_mcp.py', 'scout-listening.wav'
    )
    foreach ($relative in $legacyPaths) {
        $path = Join-Path $InstallDir $relative
        if (Test-Path $path) {
            Remove-Item $path -Recurse -Force -ErrorAction Stop
        }
    }
}

[pscustomobject]@{
    Runtime = '8.0.30'
    Architecture = $Runtime.Rid
    DotNet = $dotnet
} | ConvertTo-Json
