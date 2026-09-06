<#
.SYNOPSIS
    Starts Companion with Scout, without undoing an explicit Exit.

.DESCRIPTION
    Matches exact desktop process names and excludes Electron helper processes.
    Manual stops last for the current Scout process instance, including across
    watcher restarts. A new Scout instance or an explicit Companion launch
    resumes automatic startup.
#>

#Requires -Version 5.0
$ErrorActionPreference = 'Stop'
$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
. (Join-Path $ScriptDir 'Companion-Lifecycle.ps1')

$StateDir = Join-Path $ScriptDir 'lifecycle-state'
$created = $false
$watcherMutex = New-Object System.Threading.Mutex($true, 'Local\ScoutCompanion.Watcher', [ref]$created)
if (-not $created) {
    $watcherMutex.Dispose()
    exit 0
}

function Start-Companion {
    $launcher = Join-Path $ScriptDir 'Start-ScoutCompanion.vbs'
    if (Test-Path -LiteralPath $launcher) {
        Start-Process -FilePath (Join-Path $env:SystemRoot 'System32\wscript.exe') `
            -ArgumentList "`"$launcher`"" -WindowStyle Hidden -ErrorAction Stop
        return
    }
    $companion = Join-Path $ScriptDir 'scout-companion.ps1'
    $arguments = "-NoProfile -ExecutionPolicy Bypass -STA -WindowStyle Hidden -File `"$companion`""
    Start-Process -FilePath 'powershell.exe' -ArgumentList $arguments -WindowStyle Hidden -ErrorAction Stop
}

function Invoke-CompanionWatchTick {
    $configuration = @{}
    $configPath = Join-Path $ScriptDir 'config.json'
    if (Test-Path -LiteralPath $configPath) {
        $configuration = Get-Content -LiteralPath $configPath -Raw -Encoding UTF8 -ErrorAction Stop |
            ConvertFrom-Json -ErrorAction Stop
    }
    $agents = @(Get-CompanionAgentInstances (Get-CompanionProcessNames $configuration) -Refresh)
    Remove-StaleCompanionStops $StateDir $agents
    if (-not $agents.Count) { return }
    if (@(Get-CompanionProcesses $ScriptDir).Count) { return }
    # Check suppression after checking the process: a manual exit writes its
    # stop marker before the process disappears.
    if (Test-CompanionAutoStart $StateDir $agents) { Start-Companion }
}

try {
    while ($true) {
        try {
            Invoke-CompanionWatchTick
        } catch {
            $message = '{0:o} {1}' -f [datetime]::UtcNow, $_.Exception.Message
            Add-Content -LiteralPath (Join-Path $ScriptDir 'watcher.log') -Value $message -Encoding UTF8
            Write-Warning $message
        }
        Start-Sleep -Seconds 5
    }
} finally {
    $watcherMutex.ReleaseMutex()
    $watcherMutex.Dispose()
}
