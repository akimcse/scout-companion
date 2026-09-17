#Requires -Version 5.0

function Get-CompanionProcessNames($Configuration) {
    if ($Configuration -and $Configuration.processNames) {
        return @($Configuration.processNames)
    }
    return @('scout', 'Microsoft Scout', 'OpenClaw', 'Clawpilot', 'Claw')
}

function Select-CompanionAgents([object[]]$Processes, [string[]]$ProcessNames) {
    $names = @($ProcessNames | ForEach-Object { $_ -replace '(?i)\.exe$', '' })
    foreach ($process in $Processes) {
        $name = [string]$process.Name -replace '(?i)\.exe$', ''
        if ($name -notin $names) { continue }
        if ($process.CommandLine -match '(?:^|\s)--type(?:=|\s)') { continue }
        if (-not $process.CommandLine -or -not $process.CreationDate) {
            throw "Cannot identify application instance $($process.ProcessId) ($name)."
        }
        $started = ([datetime]$process.CreationDate).ToUniversalTime().Ticks
        [pscustomobject]@{
            ProcessId = [int]$process.ProcessId
            Key = '{0}-{1}' -f $process.ProcessId, $started
        }
    }
}

function Get-CompanionAgentInstances([string[]]$ProcessNames, [switch]$Refresh) {
    $names = @($ProcessNames | ForEach-Object { $_ -replace '(?i)\.exe$', '' } | Sort-Object -Unique)
    if (-not $names.Count -or @($names | Where-Object { [string]::IsNullOrWhiteSpace($_) }).Count) {
        throw 'At least one exact application process name is required.'
    }
    $cacheKey = $names -join '|'
    if (-not $Refresh -and $script:CompanionAgentCache -and
            $script:CompanionAgentCache.Key -eq $cacheKey -and
            ([datetime]::UtcNow - $script:CompanionAgentCache.Time).TotalSeconds -lt 2) {
        return $script:CompanionAgentCache.Instances
    }
    $filters = foreach ($name in $names) {
        $escaped = $name.Replace('\', '\\').Replace("'", "\'")
        "Name = '$escaped.exe'"
    }
    $processes = @(Get-CimInstance Win32_Process -Filter ($filters -join ' OR ') -ErrorAction Stop)
    $instances = @(Select-CompanionAgents $processes $names)
    $script:CompanionAgentCache = @{
        Key = $cacheKey
        Time = [datetime]::UtcNow
        Instances = $instances
    }
    return $instances
}

function Get-CompanionStopPath([string]$StateDir, [ValidatePattern('^\d+-\d+$')][string]$Key) {
    Join-Path $StateDir "$Key.stop"
}

function Set-CompanionManualStop([string]$StateDir, [object[]]$Agents) {
    if (-not $Agents.Count) { return }
    [void][System.IO.Directory]::CreateDirectory($StateDir)
    foreach ($agent in $Agents) {
        # An empty, instance-specific file is also safe to read during a write.
        # Including the start time prevents a reused PID from inheriting a stop.
        [System.IO.File]::WriteAllText((Get-CompanionStopPath $StateDir $agent.Key), '')
    }
}

function Clear-CompanionManualStop([string]$StateDir, [object[]]$Agents) {
    foreach ($agent in $Agents) {
        $path = Get-CompanionStopPath $StateDir $agent.Key
        if (Test-Path -LiteralPath $path) { Remove-Item -LiteralPath $path -ErrorAction Stop }
    }
}

function Remove-StaleCompanionStops([string]$StateDir, [object[]]$Agents) {
    if (-not (Test-Path -LiteralPath $StateDir)) { return }
    $keys = @($Agents | ForEach-Object { $_.Key })
    foreach ($file in Get-ChildItem -LiteralPath $StateDir -Filter '*.stop' -File -ErrorAction Stop) {
        if ($file.BaseName -match '^\d+-\d+$' -and $file.BaseName -notin $keys) {
            Remove-Item -LiteralPath $file.FullName -ErrorAction Stop
        }
    }
}

function Test-CompanionAutoStart([string]$StateDir, [object[]]$Agents) {
    foreach ($agent in $Agents) {
        if (-not (Test-Path -LiteralPath (Get-CompanionStopPath $StateDir $agent.Key))) {
            return $true
        }
    }
    return $false
}

function Get-CompanionProcesses([string]$InstallDir, [string]$ScriptName = 'scout-companion.ps1') {
    $path = [regex]::Escape((Join-Path $InstallDir $ScriptName))
    $pattern = '(?i)(?:^|\s)-File\s+(?:"' + $path + '"|' + $path + ')\s*$'
    Get-CimInstance Win32_Process -Filter "Name = 'powershell.exe' OR Name = 'pwsh.exe'" -ErrorAction Stop |
        Where-Object { $_.ProcessId -ne $PID -and $_.CommandLine -match $pattern }
}
