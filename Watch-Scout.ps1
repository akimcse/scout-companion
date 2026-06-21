<#
.SYNOPSIS
    Tiny supervisor that ties Scout Companion to the agent's lifecycle.

.DESCRIPTION
    Runs quietly in the background (e.g. from the Startup folder). Every few
    seconds it checks whether the Microsoft Scout / OpenClaw agent is running.
    When the agent appears and no companion is running yet, it launches the
    companion. It never kills anything: the companion shuts *itself* down a few
    seconds after the agent closes (see exitWhenAgentGone in scout-companion.ps1).

    This keeps the footprint to a single cheap Get-Process poll while the agent
    is closed, and nothing heavier than that.
#>

#Requires -Version 5.0
$ErrorActionPreference = 'SilentlyContinue'

$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$Companion = Join-Path $ScriptDir 'scout-companion.ps1'

# Mirror the companion's process names (and honor config.json if present).
$processNames = @('Microsoft Scout', 'OpenClaw', 'Claw', 'Copilot')
$cfgPath = Join-Path $ScriptDir 'config.json'
if (Test-Path $cfgPath) {
    try {
        $u = Get-Content $cfgPath -Raw | ConvertFrom-Json
        if ($u.processNames) { $processNames = $u.processNames }
    } catch { }
}

function Test-Agent {
    $all = Get-Process -ErrorAction SilentlyContinue
    foreach ($n in $processNames) {
        if ($all | Where-Object { $_.ProcessName -ieq $n -or $_.ProcessName -like "*$n*" } | Select-Object -First 1) { return $true }
    }
    return $false
}

function Test-Companion {
    $c = Get-CimInstance Win32_Process -Filter "Name='powershell.exe'" -ErrorAction SilentlyContinue |
         Where-Object { $_.CommandLine -match 'scout-companion\.ps1' }
    return [bool]$c
}

function Start-Companion {
    # Pass a single, explicitly-quoted argument string. Passing -File via an
    # array (@('-File',$path)) mangles paths that contain spaces or non-ASCII
    # characters (e.g. the Korean "문서" folder), so the script is never found.
    $argline = "-NoProfile -ExecutionPolicy Bypass -STA -WindowStyle Hidden -File `"$Companion`""
    Start-Process -FilePath 'powershell.exe' -ArgumentList $argline -WindowStyle Hidden
}

while ($true) {
    try {
        if (Test-Agent) {
            if (-not (Test-Companion)) { Start-Companion }
        }
    } catch { }
    Start-Sleep -Seconds 5
}
