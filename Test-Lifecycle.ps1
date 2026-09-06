#Requires -Version 5.0
param([string]$AppDir = $PSScriptRoot)
$ErrorActionPreference = 'Stop'
. (Join-Path $AppDir 'Companion-Lifecycle.ps1')

$script:Pass = 0
$script:Fail = 0
function Same([string]$Name, $Actual, $Expected) {
    if ($Actual -ceq $Expected) {
        $script:Pass++
    } else {
        $script:Fail++
        Write-Host "FAIL $Name : expected '$Expected', got '$Actual'"
    }
}

function Read-Function([string]$Path, [string]$Name) {
    $errors = $null
    $ast = [System.Management.Automation.Language.Parser]::ParseFile($Path, [ref]$null, [ref]$errors)
    if ($errors.Count) { throw $errors[0].Message }
    $node = $ast.FindAll({
        param($n)
        $n -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -eq $Name
    }, $true) | Select-Object -First 1
    if (-not $node) { throw "Missing function: $Name" }
    return [scriptblock]::Create($node.Extent.Text)
}

$state = Join-Path $env:TEMP ('companion-lifecycle-test-' + [guid]::NewGuid().ToString('N'))
[void][System.IO.Directory]::CreateDirectory($state)
try {
    $names = @(Get-CompanionProcessNames @{})
    Same 'default identifies the actual Scout executable' ($names -contains 'scout') $true
    Same 'Copilot is not an application alias' ($names -contains 'Copilot') $false
    Same 'explicit custom names are retained' ((Get-CompanionProcessNames @{ processNames = @('Custom Scout') }) -join ',') 'Custom Scout'

    $started = [datetime]'2026-09-06T07:00:00Z'
    $records = @(
        [pscustomobject]@{ Name = 'scout.exe'; ProcessId = 10; CreationDate = $started; CommandLine = '"C:\Apps\scout.exe"' },
        [pscustomobject]@{ Name = 'scout.exe'; ProcessId = 11; CreationDate = $started; CommandLine = '"C:\Apps\scout.exe" --type=renderer' },
        [pscustomobject]@{ Name = 'scout.exe'; ProcessId = 12; CreationDate = $started; CommandLine = '"C:\Apps\scout.exe" --type gpu-process' },
        [pscustomobject]@{ Name = 'copilot.exe'; ProcessId = 20; CreationDate = $started; CommandLine = 'copilot.exe' },
        [pscustomobject]@{ Name = 'copilotapp.exe'; ProcessId = 21; CreationDate = $started; CommandLine = 'copilotapp.exe' },
        [pscustomobject]@{ Name = 'copilotapphost.exe'; ProcessId = 22; CreationDate = $started; CommandLine = 'copilotapphost.exe' },
        [pscustomobject]@{ Name = 'my-scout-tool.exe'; ProcessId = 23; CreationDate = $started; CommandLine = 'my-scout-tool.exe' }
    )
    $agents = @(Select-CompanionAgents $records $names)
    Same 'only the desktop application is selected' $agents.Count 1
    Same 'the primary application PID is selected' $agents[0].ProcessId 10
    Same 'Copilot and orphaned renderers do not keep Scout alive' @(Select-CompanionAgents $records[1..6] $names).Count 0
    Same 'executable names are case insensitive' @(Select-CompanionAgents $records @('SCOUT.EXE')).Count 1
    $denied = [pscustomobject]@{ Name = 'scout.exe'; ProcessId = 99; CreationDate = $started; CommandLine = $null }
    $threw = $false
    try { Select-CompanionAgents @($denied) $names | Out-Null } catch { $threw = $true }
    Same 'inaccessible identity is an error, not a stopped app' $threw $true

    $script:CimCalls = 0
    $script:CimRecords = $records
    $script:CimFails = $false
    function Get-CimInstance {
        [CmdletBinding()]
        param([string]$ClassName, [string]$Filter)
        $script:CimCalls++
        $script:LastFilter = $Filter
        if ($script:CimFails) { throw 'Simulated CIM failure' }
        return $script:CimRecords
    }
    $found = @(Get-CompanionAgentInstances $names -Refresh)
    Same 'the live discovery path selects only the application' $found.Count 1
    Same 'the query includes the real executable name' ($script:LastFilter.Contains("Name = 'scout.exe'")) $true
    Same 'the query does not use substring matching' ($script:LastFilter -match '(?i)\bLIKE\b') $false
    $calls = $script:CimCalls
    $script:CompanionAgentCache.Time = [datetime]::UtcNow
    $null = @(Get-CompanionAgentInstances $names)
    Same 'foreground polling reuses the short-lived cache' $script:CimCalls $calls
    $null = @(Get-CompanionAgentInstances $names -Refresh)
    Same 'manual exit can force a fresh identity read' $script:CimCalls ($calls + 1)
    $script:CimFails = $true
    $threw = $false
    try { Get-CompanionAgentInstances $names -Refresh | Out-Null } catch { $threw = $true }
    Same 'failed CIM discovery never becomes a false absent result' $threw $true
    $script:CimFails = $false
    $script:CimRecords = @()
    Same 'an empty process result is handled explicitly' @(Get-CompanionAgentInstances $names -Refresh).Count 0
    $script:CimRecords = @(
        [pscustomobject]@{ ProcessId = 101; CommandLine = 'powershell.exe -NoProfile -File "C:\Test App\scout-companion.ps1"' },
        [pscustomobject]@{ ProcessId = 102; CommandLine = 'powershell.exe -File "C:\Other App\scout-companion.ps1"' },
        [pscustomobject]@{ ProcessId = 103; CommandLine = 'powershell.exe -File "C:\Test App\Watch-Scout.ps1"' },
        [pscustomobject]@{ ProcessId = 104; CommandLine = 'powershell.exe -Command "Write-Host scout-companion.ps1"' }
    )
    Same 'process lookup is scoped to the installed script' @(Get-CompanionProcesses 'C:\Test App').Count 1
    Same 'watcher lookup is separate from Companion lookup' @(Get-CompanionProcesses 'C:\Test App' 'Watch-Scout.ps1').Count 1

    Same 'no Scout means no auto-start' (Test-CompanionAutoStart $state @()) $false
    Same 'new Scout permits auto-start' (Test-CompanionAutoStart $state $agents) $true
    Set-CompanionManualStop $state $agents
    Same 'manual exit suppresses auto-start' (Test-CompanionAutoStart $state $agents) $false
    Same 'a fresh watcher also sees the persisted stop' (Test-CompanionAutoStart $state @([pscustomobject]@{ Key = $agents[0].Key })) $false
    $reusedPid = [pscustomobject]@{ Name = 'scout.exe'; ProcessId = 10; CreationDate = $started.AddSeconds(1); CommandLine = 'scout.exe' }
    $newAgents = @(Select-CompanionAgents @($reusedPid) $names)
    Same 'PID reuse does not inherit a manual stop' (Test-CompanionAutoStart $state $newAgents) $true
    $twoAgents = @($agents[0], $newAgents[0])
    Set-CompanionManualStop $state $twoAgents
    Same 'manual exit covers all current Scout instances' (Test-CompanionAutoStart $state $twoAgents) $false
    Clear-CompanionManualStop $state $newAgents
    Same 'an explicitly started Companion resumes auto-start' (Test-CompanionAutoStart $state $newAgents) $true
    Same 'clearing a different instance preserves the old stop' (Test-CompanionAutoStart $state $agents) $false
    Remove-StaleCompanionStops $state $newAgents
    Same 'closed instance markers are removed' (Test-Path -LiteralPath (Get-CompanionStopPath $state $agents[0].Key)) $false

    . (Read-Function (Join-Path $AppDir 'Watch-Scout.ps1') 'Invoke-CompanionWatchTick')
    $ScriptDir = $state
    $StateDir = $state
    $script:FakeAgents = @()
    $script:FakeCompanions = @()
    $script:Starts = 0
    $script:DiscoveryFails = $false
    function Get-CompanionAgentInstances {
        param($ProcessNames, [switch]$Refresh)
        if ($script:DiscoveryFails) { throw 'Simulated discovery failure' }
        return $script:FakeAgents
    }
    function Get-CompanionProcesses { param($InstallDir) return $script:FakeCompanions }
    function Start-Companion { $script:Starts++ }

    Invoke-CompanionWatchTick
    Same 'watcher does not launch for other Copilot apps' $script:Starts 0
    $script:FakeAgents = $agents
    Invoke-CompanionWatchTick
    Same 'watcher launches for Scout' $script:Starts 1
    $script:FakeCompanions = @([pscustomobject]@{ ProcessId = 123 })
    Invoke-CompanionWatchTick
    Same 'watcher does not launch a duplicate' $script:Starts 1
    Set-CompanionManualStop $state $agents
    $script:FakeCompanions = @()
    Invoke-CompanionWatchTick
    Invoke-CompanionWatchTick
    Same 'manual exit stays stopped on successive watcher ticks' $script:Starts 1
    $script:FakeAgents = $newAgents
    Invoke-CompanionWatchTick
    Same 'a new Scout instance re-enables automatic startup' $script:Starts 2
    Invoke-CompanionWatchTick
    Same 'an unrequested process exit still permits crash recovery' $script:Starts 3
    $script:DiscoveryFails = $true
    $threw = $false
    try { Invoke-CompanionWatchTick } catch { $threw = $true }
    Same 'discovery failures propagate for logging' $threw $true
    Same 'discovery failure never launches a fallback app' $script:Starts 3
    $script:DiscoveryFails = $false

    . (Read-Function (Join-Path $AppDir 'scout-companion.ps1') 'Stop-Companion')
    $Config = @{ processNames = $names }
    $LifecycleStateDir = $state
    $script:FakeAgents = $agents
    $script:Closed = 0
    $script:Reported = 0
    $Window = [pscustomobject]@{}
    $Window | Add-Member -MemberType ScriptMethod -Name Close -Value { $script:Closed++ }
    function Write-CompanionLog { param($Message) }
    function Show-TrayBalloon { param($Title, $Text) $script:Reported++ }
    Stop-Companion
    Same 'automatic shutdown still closes the window' $script:Closed 1
    Same 'automatic shutdown does not suppress future launches' (Test-CompanionAutoStart $state $agents) $true
    Stop-Companion -Manual
    Same 'manual shutdown closes the window' $script:Closed 2
    Same 'manual shutdown writes its stop before closing' (Test-CompanionAutoStart $state $agents) $false
    $LifecycleStateDir = Get-CompanionStopPath $state $agents[0].Key
    Stop-Companion -Manual
    Same 'a failed stop write does not pretend to succeed' $script:Closed 2
    Same 'a failed stop write is reported to the user' $script:Reported 1

    $source = Get-Content -LiteralPath (Join-Path $AppDir 'scout-companion.ps1') -Raw -Encoding UTF8
    Same 'the actual Exit menu requests a manual shutdown' ($source.Contains('$MenuExit.Add_Click({ Stop-Companion -Manual })')) $true
    Same 'startup explicitly resumes only current application instances' ($source.Contains('Clear-CompanionManualStop $LifecycleStateDir @(Get-CompanionAgentInstances $Config.processNames -Refresh)')) $true
    Same 'application shutdown is independent of stale windows' ($source.Contains('$agentPresent = Test-AgentProcess')) $true
    Same 'an unknown presence result cannot advance the exit grace timer' ($source.Contains('if ($null -eq $agentPresent -or $agentPresent) {')) $true
    . (Read-Function (Join-Path $AppDir 'scout-companion.ps1') 'Test-AgentProcess')
    Same 'the application presence check uses the shared detector' (Test-AgentProcess) $true
    $script:FakeAgents = @()
    Same 'the application exits when Scout is gone' (Test-AgentProcess) $false

    $lifecycle = [regex]::Match($source, '(?s)(    \$agentPresent = \$null.*?)(?=\r?\n    \$hasPending =)')
    if (-not $lifecycle.Success) { throw 'Missing live lifecycle block' }
    $lifecycleBlock = [scriptblock]::Create($lifecycle.Groups[1].Value)
    $Config.exitWhenAgentGone = $true
    $Config.exitGraceSeconds = 30
    $closedBefore = $script:Closed
    $script:AgentGoneSince = [datetime]::UtcNow.AddMinutes(-1)
    $script:DiscoveryFails = $true
    & $lifecycleBlock
    Same 'a detection failure does not close the running app' $script:Closed $closedBefore
    Same 'a detection failure resets the absence grace timer' $script:AgentGoneSince $null
    $script:DiscoveryFails = $false
    & $lifecycleBlock
    Same 'confirmed absence starts a new grace period' ($null -ne $script:AgentGoneSince) $true
    Same 'the grace period does not exit immediately' $script:Closed $closedBefore
    $script:AgentGoneSince = [datetime]::UtcNow.AddMinutes(-1)
    & $lifecycleBlock
    Same 'confirmed absence eventually closes Companion' $script:Closed ($closedBefore + 1)

    $script:StoppedIds = @()
    function Get-CompanionProcesses {
        param($InstallDir, $ScriptName)
        if ($ScriptName -eq 'Watch-Scout.ps1') {
            return @([pscustomobject]@{ ProcessId = 201 }, [pscustomobject]@{ ProcessId = 202 })
        }
        throw 'Unexpected installer process lookup'
    }
    function Stop-Process {
        [CmdletBinding()]
        param([int]$Id, [switch]$Force)
        $script:StoppedIds += $Id
    }
    . (Read-Function (Join-Path $AppDir 'Install.ps1') 'Stop-CompanionWatchers')
    $InstallDir = $state
    Same 'installer stops all matching watcher instances' (Stop-CompanionWatchers) 2
    Same 'installer stops only explicitly discovered process IDs' ($script:StoppedIds -join ',') '201,202'

    foreach ($file in 'Build-Release.ps1', 'Install.ps1') {
        $path = Join-Path $AppDir $file
        $ast = [System.Management.Automation.Language.Parser]::ParseFile($path, [ref]$null, [ref]$null)
        $payload = $ast.FindAll({
            param($n)
            $n -is [System.Management.Automation.Language.AssignmentStatementAst] -and
                $n.Left.Extent.Text -eq '$Payload'
        }, $true) | Select-Object -First 1
        . ([scriptblock]::Create($payload.Extent.Text))
        Same "$file carries the runtime helper" ($Payload -contains 'Companion-Lifecycle.ps1') $true
    }
    $installer = Get-Content -LiteralPath (Join-Path $AppDir 'Install.ps1') -Raw
    Same 'upgrades preserve manual-stop state' ($installer.Contains("'config.json', 'titles.json', 'lifecycle-state'")) $true
    Same 'upgrades stop supervision before the application' ([bool]($installer -match '\$watchersStopped = Stop-CompanionWatchers\s+\$n = Stop-Companion')) $true
    Same 'uninstall also stops supervision' ([bool]($installer -match '\[void\]\(Stop-CompanionWatchers\)\s+\$n = Stop-Companion')) $true
    $workflow = Get-Content -LiteralPath (Join-Path $AppDir '.github\workflows\release.yml') -Raw
    Same 'release CI runs the lifecycle suite' ($workflow.Contains("'Test-Lifecycle.ps1'")) $true
} finally {
    foreach ($file in Get-ChildItem -LiteralPath $state -File) {
        Remove-Item -LiteralPath $file.FullName
    }
    Remove-Item -LiteralPath $state
}

Write-Host "$($script:Pass) passed, $($script:Fail) failed"
if ($script:Fail) { exit 1 }
