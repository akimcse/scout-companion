<#
.SYNOPSIS
    Installs Scout Companion for the current user.

.DESCRIPTION
    Copies the app to %LOCALAPPDATA%\Programs\ScoutCompanion, adds the Start
    Menu shortcuts, and registers an entry in Add/Remove Programs so it can be
    uninstalled the way anything else is.

    Per-user throughout: no admin rights, no writes outside your own profile,
    nothing in Program Files and nothing in HKLM.

    Installing over an existing copy keeps your settings - config.json and the
    learned chat titles are carried across rather than replaced.

.PARAMETER Uninstall
    Removes the shortcuts, the installed copy and the Add/Remove Programs entry.
    Stops the companion first if it is running.

.PARAMETER Run
    Start the companion once the install finishes.

.EXAMPLE
    powershell -ExecutionPolicy Bypass -File .\Install.ps1
.EXAMPLE
    powershell -ExecutionPolicy Bypass -File .\Install.ps1 -Run
.EXAMPLE
    powershell -ExecutionPolicy Bypass -File .\Install.ps1 -Uninstall
#>

#Requires -Version 5.0
[CmdletBinding()]
param(
    [switch]$Uninstall,
    [switch]$Run
)

$ErrorActionPreference = 'Stop'

$AppName    = 'Scout Companion'
$InstallDir = Join-Path $env:LOCALAPPDATA 'Programs\ScoutCompanion'
$RegKey     = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Uninstall\ScoutCompanion'
$IconPath   = Join-Path $env:LOCALAPPDATA 'ScoutCompanion\scout-companion.ico'
$VoiceDir   = Join-Path $env:LOCALAPPDATA 'ScoutVoiceAssistant'
$SourceDir  = Split-Path -Parent $MyInvocation.MyCommand.Path
$installedConfig = Join-Path $InstallDir 'config.json'
if (Test-Path $installedConfig) {
    try {
        $configured = (Get-Content $installedConfig -Raw | ConvertFrom-Json).voiceRuntimeDir
        if ($configured) {
            $VoiceDir = [Environment]::ExpandEnvironmentVariables([string]$configured)
        }
    } catch { }
}

# Carried across an upgrade rather than overwritten: these are the user's, not
# ours. They live beside the script because that is where the app looks for
# them.
$UserState = 'config.json', 'titles.json'

# What actually has to be there to run. Tests, screenshots and the git
# machinery are not part of an installation.
$Payload = @(
    'scout-companion.ps1'
    'Start-ScoutCompanion.cmd'
    'Start-ScoutCompanion.vbs'
    'Watch-Scout.ps1'
    'Watch-Scout.vbs'
    'Add-ToStartMenu.ps1'
    'voice'
    'config.sample.json'
    'LICENSE'
    'README.md'
)

function Get-CompanionVersion {
    $f = Join-Path $SourceDir 'scout-companion.ps1'
    if (-not (Test-Path $f)) { return '0.0.0' }
    $m = [regex]::Match((Get-Content $f -Raw), "(?m)^\`$CompanionVersion\s*=\s*'([^']+)'")
    if ($m.Success) { return $m.Groups[1].Value }
    return '0.0.0'
}

# The companion has no taskbar button, so "is it running" is a process
# question. Matched on the script path rather than the name, because every
# PowerShell window is powershell.exe.
function Stop-ProcessTree([int]$RootId, [int]$ExcludeId = $PID) {
    try { $all = @(Get-CimInstance Win32_Process -ErrorAction Stop) }
    catch { $all = @() }
    $pending = @($RootId)
    $owned = New-Object System.Collections.Generic.List[int]
    while ($pending.Count) {
        $parent = $pending[0]
        $pending = @($pending | Select-Object -Skip 1)
        foreach ($child in @($all | Where-Object { $_.ParentProcessId -eq $parent })) {
            # An in-app update launches this installer as a descendant of the
            # Companion it must replace. Do not let tree cleanup kill the
            # installer that is performing the cleanup.
            if ($child.ProcessId -eq $ExcludeId) { continue }
            [void]$owned.Add([int]$child.ProcessId)
            $pending += [int]$child.ProcessId
        }
    }
    $ids = $owned.ToArray()
    [array]::Reverse($ids)
    foreach ($id in $ids) {
        Stop-Process -Id $id -Force -ErrorAction SilentlyContinue
    }
    Stop-Process -Id $RootId -Force -ErrorAction SilentlyContinue
    foreach ($id in @($ids) + $RootId) {
        for ($attempt = 0; $attempt -lt 20; $attempt++) {
            if (-not (Get-Process -Id $id -ErrorAction SilentlyContinue)) { break }
            Start-Sleep -Milliseconds 100
        }
    }
}

function Remove-UpgradePath([string]$Path) {
    for ($attempt = 0; $attempt -lt 10; $attempt++) {
        try {
            if (Test-Path $Path) {
                Remove-Item $Path -Recurse -Force -ErrorAction Stop
            }
            if (-not (Test-Path $Path)) { return }
        } catch {
            if ($attempt -eq 9) { throw }
        }
        Start-Sleep -Milliseconds 300
    }
    throw "Could not replace $Path because it is still in use."
}

function Stop-Companion {
    $stopped = 0
    $me = $PID
    try {
        $procs = Get-CimInstance Win32_Process -Filter "Name='powershell.exe' OR Name='pwsh.exe'" -ErrorAction Stop
    } catch { return 0 }
    foreach ($p in $procs) {
        if ($p.ProcessId -eq $me) { continue }
        if ($p.CommandLine -notlike '*scout-companion.ps1*') { continue }
        # Only ever the copy being operated on, so a checkout running from
        # somewhere else is left alone.
        if ($p.CommandLine -notlike "*$InstallDir*") { continue }
        try { Stop-ProcessTree $p.ProcessId; $stopped++ } catch { }
    }
    return $stopped
}

# ---------------------------------------------------------------------------
# Uninstall
# ---------------------------------------------------------------------------
if ($Uninstall) {
    Write-Host ''
    Write-Host "Removing $AppName..."

    $n = Stop-Companion
    if ($n -gt 0) { Write-Host "  stopped $n running instance(s)" }

    $shortcutRemover = Join-Path $InstallDir 'Add-ToStartMenu.ps1'
    if (Test-Path $shortcutRemover) {
        try {
            & $shortcutRemover -Remove 6>$null | Out-Null
            Write-Host '  removed the Start Menu shortcuts'
        } catch { Write-Warning "  could not remove the shortcuts: $($_.Exception.Message)" }
    }

    $startup = Join-Path ([Environment]::GetFolderPath('Startup')) 'Scout Companion.lnk'
    if (Test-Path $startup) {
        Remove-Item $startup -Force -ErrorAction SilentlyContinue
        Write-Host '  removed the start-with-Scout entry'
    }

    if (Test-Path $InstallDir) {
        # A file still mapped by a process that has not finished exiting will
        # refuse to delete, and one retry is cheaper than failing the uninstall.
        for ($i = 0; $i -lt 3; $i++) {
            try { Remove-Item $InstallDir -Recurse -Force -ErrorAction Stop; break }
            catch { Start-Sleep -Milliseconds 400 }
        }
        if (Test-Path $InstallDir) { Write-Warning "  could not remove $InstallDir - is something still using it?" }
        else { Write-Host "  removed $InstallDir" }
    }

    if (Test-Path $IconPath) { Remove-Item $IconPath -Force -ErrorAction SilentlyContinue }
    $iconDir = Split-Path $IconPath -Parent
    if ((Test-Path $iconDir) -and -not (Get-ChildItem $iconDir -Force)) {
        Remove-Item $iconDir -Force -ErrorAction SilentlyContinue
    }

    if (Test-Path $RegKey) {
        Remove-Item $RegKey -Recurse -Force -ErrorAction SilentlyContinue
        Write-Host '  removed the Add/Remove Programs entry'
    }

    if (Test-Path (Join-Path $VoiceDir '.managed-by-scout-companion')) {
        for ($i = 0; $i -lt 3 -and (Test-Path $VoiceDir); $i++) {
            Remove-Item $VoiceDir -Recurse -Force -ErrorAction SilentlyContinue
            if (Test-Path $VoiceDir) { Start-Sleep -Milliseconds 500 }
        }
        if (Test-Path $VoiceDir) {
            Write-Warning "  could not remove optional voice runtime at $VoiceDir"
        } else {
            Write-Host '  removed the optional voice runtime'
        }
    }

    Write-Host ''
    Write-Host "$AppName has been removed."
    Write-Host ''
    return
}

# ---------------------------------------------------------------------------
# Install
# ---------------------------------------------------------------------------
foreach ($f in $Payload) {
    if (-not (Test-Path (Join-Path $SourceDir $f))) {
        throw "$f is missing from $SourceDir. Run this from the folder you unzipped, or cloned, into."
    }
}
if (-not (Test-Path (Join-Path $SourceDir 'lang'))) {
    throw "The lang folder is missing from $SourceDir."
}

$version = Get-CompanionVersion
$existing = Test-Path (Join-Path $InstallDir 'scout-companion.ps1')

Write-Host ''
Write-Host "$AppName $version"
Write-Host ("  {0} {1}" -f $(if ($existing) { 'updating' } else { 'installing to' }), $InstallDir)

# Refuse to install a folder into itself - it would delete the source mid-copy.
$srcFull = [System.IO.Path]::GetFullPath($SourceDir).TrimEnd('\')
$dstFull = [System.IO.Path]::GetFullPath($InstallDir).TrimEnd('\')
if ($srcFull -eq $dstFull) {
    Write-Host ''
    Write-Host 'This is already the installed copy - nothing to do.'
    Write-Host ''
    return
}

$n = Stop-Companion
if ($n -gt 0) { Write-Host "  stopped $n running instance(s)" }

# Keep the user's settings across an upgrade.
$saved = @{}
foreach ($f in $UserState) {
    $p = Join-Path $InstallDir $f
    if (Test-Path $p) { $saved[$f] = Get-Content $p -Raw }
}

New-Item -ItemType Directory -Path $InstallDir -Force | Out-Null

# Clear out the old payload so a file dropped from a later version does not
# linger, but never touch anything held in $saved.
if ($existing) {
    Get-ChildItem $InstallDir -Force | Where-Object { $UserState -notcontains $_.Name } |
        ForEach-Object { Remove-UpgradePath $_.FullName }
}

foreach ($f in $Payload) {
    $source = Join-Path $SourceDir $f
    $destination = Join-Path $InstallDir $f
    if (Test-Path $source -PathType Container) {
        Copy-Item $source $destination -Recurse -Force
    } else {
        Copy-Item $source $destination -Force
    }
}
$dotnetSource = Join-Path $InstallDir 'voice\dotnet\ScoutVoiceEngine'
foreach ($developmentFolder in 'bin', 'obj') {
    $path = Join-Path $dotnetSource $developmentFolder
    if (Test-Path $path) { Remove-Item $path -Recurse -Force }
}
$publishTest = Join-Path $InstallDir 'voice\dotnet\publish-test'
if (Test-Path $publishTest) { Remove-Item $publishTest -Recurse -Force }
$installedDotNetRoot = Join-Path $InstallDir 'voice\dotnet'
Get-ChildItem $installedDotNetRoot -Directory -Filter 'publish-*' `
    -ErrorAction SilentlyContinue | Remove-Item -Recurse -Force
$publishRoot = Join-Path $InstallDir 'voice\dotnet\publish'
$architecture = [System.Runtime.InteropServices.RuntimeInformation]::OSArchitecture.ToString().ToLowerInvariant()
$keepRuntime = switch ($architecture) {
    'arm64' { 'win-arm64' }
    'x64'   { 'win-x64' }
    default { $null }
}
if ($keepRuntime -and (Test-Path $publishRoot)) {
    Get-ChildItem $publishRoot -Directory |
        Where-Object { $_.Name -ne $keepRuntime } |
        Remove-Item -Recurse -Force
    $engineRoot = Join-Path $publishRoot $keepRuntime
    foreach ($requiredFile in @(
            'ScoutVoiceEngine.exe',
            'ScoutVoiceEngine.dll',
            'ScoutVoiceEngine.deps.json',
            'ScoutVoiceEngine.runtimeconfig.json',
            'sherpa-onnx-c-api.dll',
            'scout-listening.wav')) {
        if (-not (Test-Path (Join-Path $engineRoot $requiredFile))) {
            throw "Voice engine installation is incomplete: $requiredFile is missing."
        }
    }
}
Copy-Item (Join-Path $SourceDir 'lang') $InstallDir -Recurse -Force
Write-Host ("  copied {0} files and {1} language files" -f $Payload.Count, (Get-ChildItem (Join-Path $InstallDir 'lang') -File).Count)

foreach ($f in $saved.Keys) {
    Set-Content -Path (Join-Path $InstallDir $f) -Value $saved[$f] -Encoding UTF8 -NoNewline
}
if ($saved.Count) { Write-Host ("  kept your {0}" -f (($saved.Keys | Sort-Object) -join ' and ')) }

# v0.13 has one voice engine. Remove the short-lived migration selector while
# preserving every other user setting.
$installedConfig = Join-Path $InstallDir 'config.json'
if (Test-Path $installedConfig) {
    try {
        $configObject = Get-Content $installedConfig -Raw | ConvertFrom-Json
        if ($configObject.PSObject.Properties['voiceEngine']) {
            $configObject.PSObject.Properties.Remove('voiceEngine')
            ($configObject | ConvertTo-Json -Depth 6) |
                Set-Content $installedConfig -Encoding UTF8
        }
    } catch {
        Write-Warning "  could not migrate voice settings: $($_.Exception.Message)"
    }
}

# Shortcuts, from the installed copy so they point at it rather than at the
# folder this was run from. 6> because that script reports with Write-Host,
# which does not go down the pipeline - without it its output interleaves with
# this one's and the two say the same thing twice.
try {
    & (Join-Path $InstallDir 'Add-ToStartMenu.ps1') 6>$null | Out-Null
    Write-Host '  added the Start Menu shortcuts'
} catch {
    Write-Warning "  could not add the Start Menu shortcuts: $($_.Exception.Message)"
}

# Add/Remove Programs. Per-user, so HKCU - this needs no admin and shows up in
# Settings > Apps like anything else.
$size = [int](((Get-ChildItem $InstallDir -Recurse -File | Measure-Object Length -Sum).Sum) / 1KB)
New-Item -Path $RegKey -Force | Out-Null
$props = @{
    DisplayName     = $AppName
    DisplayVersion  = $version
    Publisher       = 'Community project'
    InstallLocation = $InstallDir
    DisplayIcon     = $IconPath
    UninstallString = "powershell.exe -NoProfile -ExecutionPolicy Bypass -File `"$(Join-Path $InstallDir 'Install.ps1')`" -Uninstall"
    NoModify        = 1
    NoRepair        = 1
    EstimatedSize   = $size
    URLInfoAbout    = 'https://github.com/akimcse/scout-companion'
}
foreach ($k in $props.Keys) {
    $type = if ($props[$k] -is [int]) { 'DWord' } else { 'String' }
    New-ItemProperty -Path $RegKey -Name $k -Value $props[$k] -PropertyType $type -Force | Out-Null
}
# The uninstaller has to be there for the entry above to mean anything.
Copy-Item $MyInvocation.MyCommand.Path (Join-Path $InstallDir 'Install.ps1') -Force
Write-Host '  registered in Add/Remove Programs'

Write-Host ''
Write-Host "Installed. Search the Start Menu for `"scout`"."
Write-Host ''
Write-Host '  Scout Companion          run it now'
Write-Host '  Scout Companion (auto)   run it whenever Scout is running'
Write-Host ''
Write-Host 'To remove it: Settings > Apps > Scout Companion, or'
Write-Host "  powershell -ExecutionPolicy Bypass -File `"$(Join-Path $InstallDir 'Install.ps1')`" -Uninstall"
Write-Host ''

if ($Run) {
    Start-Process -FilePath (Join-Path $env:SystemRoot 'System32\wscript.exe') `
                  -ArgumentList "`"$(Join-Path $InstallDir 'Start-ScoutCompanion.vbs')`"" `
                  -WorkingDirectory $InstallDir -WindowStyle Hidden
    Write-Host 'Started. It stays hidden until Scout is working in the background.'
    Write-Host ''
}
