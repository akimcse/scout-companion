# Tests the decisions that route a Companion row to Activity or Co-create.
$ErrorActionPreference = 'Stop'

$src = Join-Path $PSScriptRoot 'scout-companion.ps1'
if (-not (Test-Path $src)) { Write-Host "scout-companion.ps1 not found next to this script"; exit 1 }

$ast = [System.Management.Automation.Language.Parser]::ParseFile($src, [ref]$null, [ref]$null)
$funcs = $ast.FindAll({ param($node) $node -is [System.Management.Automation.Language.FunctionDefinitionAst] }, $true)
foreach ($name in @('Get-SessionWorkspace', 'Test-KnownWorkspace', 'Enter-ActivityView',
                    'Prepare-ActivitySidebar', 'Hide-AgentSidebar',
                    'Enter-CoCreateView', 'Open-AgentSession')) {
    $function = $funcs | Where-Object { $_.Name -eq $name } | Select-Object -First 1
    if (-not $function) { Write-Host "MISSING FUNCTION: $name"; exit 1 }
    Invoke-Expression $function.Extent.Text
}

Add-Type -TypeDefinition @'
public static class FakeAutomationElement {
    public static object Root = new object();
    public static object FromHandle(System.IntPtr hwnd) { return Root; }
}
public static class FakeControlType {
    public static string Button { get { return "Button"; } }
    public static string Edit { get { return "Edit"; } }
}
'@
$UiaEl = [FakeAutomationElement]
$UiaType = [FakeControlType]

$script:Pass = 0
$script:Fail = 0
function Check($name, $got, $want) {
    if ($got -eq $want) { $script:Pass++; Write-Host ("  ok   {0,-48} -> {1}" -f $name, $got) }
    else { $script:Fail++; Write-Host ("  FAIL {0,-48} -> {1}  expected {2}" -f $name, $got, $want) }
}

Write-Host 'Get-SessionWorkspace'
$oldProfile = $env:USERPROFILE
$temp = Join-Path ([System.IO.Path]::GetTempPath()) ("companion-cocreate-{0}" -f ([guid]::NewGuid().ToString('N')))
try {
    $env:USERPROFILE = $temp
    $registryDir = Join-Path $temp '.scout\m-sessions'
    $workspaceDir = Join-Path $temp 'Co-create Lab'
    $sessionDir = Join-Path $temp 'session'
    New-Item -ItemType Directory -Path $registryDir, $workspaceDir, $sessionDir -Force | Out-Null
    @{
        version = 3
        workspaces = @{
            lab = @{ displayName = 'Co-create Lab' }
        }
    } | ConvertTo-Json -Depth 5 | Set-Content (Join-Path $registryDir 'workspaces.json') -Encoding UTF8
    "cwd: $workspaceDir" | Set-Content (Join-Path $sessionDir 'workspace.yaml') -Encoding UTF8

    # A newly created workspace must be found even when the ten-minute cache
    # still holds an older registry snapshot.
    $script:WorkspaceNames = @{}
    $script:WorkspaceNamesUtc = [datetime]::UtcNow
    $record = [pscustomobject]@{ Dir = $sessionDir; Workspace = $null; WorkspaceRead = $false }
    Check 'known cwd is routed to its workspace' (Get-SessionWorkspace $record) 'Co-create Lab'

    $unknownDir = Join-Path $temp 'Not a workspace'
    $unknownSession = Join-Path $temp 'unknown-session'
    New-Item -ItemType Directory -Path $unknownDir, $unknownSession -Force | Out-Null
    "cwd: $unknownDir" | Set-Content (Join-Path $unknownSession 'workspace.yaml') -Encoding UTF8
    $unknown = [pscustomobject]@{ Dir = $unknownSession; Workspace = $null; WorkspaceRead = $false }
    Check 'unknown cwd remains an Activity chat' (Get-SessionWorkspace $unknown) $null
    Check 'unknown workspace result is not sticky' $unknown.WorkspaceRead $false
} finally {
    $env:USERPROFILE = $oldProfile
    Remove-Item $temp -Recurse -Force -ErrorAction SilentlyContinue
}

# The remaining tests replace only external dependencies. The functions under
# test still come directly from scout-companion.ps1.
function Start-Sleep { param([int]$Milliseconds) }
function Find-UiaByName($root, [string]$name, $type) {
    if ($name -in @('Activity', 'Co-create', 'Workspace Co-create Lab',
                    'Show sidebar', 'Hide sidebar') -and $type -ne 'Button') {
        throw "$name must be queried as a Button"
    }
    if ($name -eq 'Hide sidebar' -and $script:sidebarExpanded) { return 'hide-sidebar-button' }
    if ($name -eq 'Show sidebar' -and -not $script:sidebarExpanded) { return 'show-sidebar-button' }
    if ($name -eq 'Activity') { return 'activity-button' }
    if ($name -eq 'Co-create') { return 'cocreate-button' }
    if ($name -eq 'Workspace Co-create Lab' -and $script:workspaceSelected) { return 'workspace-button' }
    return $null
}
function Invoke-UiaElement($element) {
    if ($element -eq 'show-sidebar-button') { $script:sidebarExpanded = $true; return $true }
    if ($element -eq 'hide-sidebar-button') { $script:sidebarExpanded = $false; return $true }
    if ($element -eq 'activity-button') { $script:view = 'activity'; return $true }
    if ($element -eq 'cocreate-button') { $script:view = 'cocreate'; return $true }
    return $false
}
function Test-ChatSidebarPresent($root) {
    return $script:view -eq 'activity' -and $script:sidebarExpanded
}
function Get-CoCreateChatRows($root) {
    if ($script:view -eq 'cocreate') { return @([pscustomobject]@{ Title = 'row' }) }
    return @()
}

Write-Host "`nView transitions"
$script:sidebarExpanded = $true
$script:view = 'cocreate'
$activityRoot = Enter-ActivityView ([object]::new()) ([IntPtr]1)
Check 'normal chat returns from Co-create to Activity' $script:view 'activity'
Check 'Activity transition returns a root' ($null -ne $activityRoot) $true

$script:view = 'activity'
$coCreateRoot = Enter-CoCreateView ([IntPtr]1)
Check 'workspace chat enters Co-create' $script:view 'cocreate'
Check 'Co-create transition returns a root' ($null -ne $coCreateRoot) $true

Write-Host "`nCollapsed sidebar"
$script:view = 'activity'
$script:sidebarExpanded = $false
$prepared = Prepare-ActivitySidebar ([object]::new()) ([IntPtr]1)
Check 'collapsed Activity sidebar is expanded' $script:sidebarExpanded $true
Check 'collapsed Activity does not leave Activity' $script:view 'activity'
Check 'original collapsed state is remembered' $prepared.OpenedSidebar $true

$script:view = 'cocreate'
$script:sidebarExpanded = $false
$prepared = Prepare-ActivitySidebar ([object]::new()) ([IntPtr]1)
Check 'collapsed Co-create sidebar is expanded' $script:sidebarExpanded $true
Check 'collapsed Co-create returns to Activity' $script:view 'activity'
Check 'Co-create collapsed state is remembered' $prepared.OpenedSidebar $true

$script:view = 'cocreate'
$script:sidebarExpanded = $false
$script:activityAvailable = $false
function Find-UiaByName($root, [string]$name, $type) {
    if ($name -in @('Activity', 'Co-create', 'Workspace Co-create Lab',
                    'Show sidebar', 'Hide sidebar') -and $type -ne 'Button') {
        throw "$name must be queried as a Button"
    }
    if ($name -eq 'Hide sidebar' -and $script:sidebarExpanded) { return 'hide-sidebar-button' }
    if ($name -eq 'Show sidebar' -and -not $script:sidebarExpanded) { return 'show-sidebar-button' }
    if ($name -eq 'Activity' -and $script:activityAvailable) { return 'activity-button' }
    if ($name -eq 'Co-create') { return 'cocreate-button' }
    if ($name -eq 'Workspace Co-create Lab' -and $script:workspaceSelected) { return 'workspace-button' }
    return $null
}
$prepared = Prepare-ActivitySidebar ([object]::new()) ([IntPtr]1)
Check 'failed transition returns nothing' ($null -eq $prepared) $true
Check 'failed transition restores collapsed sidebar' $script:sidebarExpanded $false
$script:activityAvailable = $true

Write-Host "`nSession dispatch"
$script:route = ''
function Open-SidebarSession($rec, [switch]$Exact) { $script:route = 'activity'; return $true }
function Open-CoCreateSession($rec, [IntPtr]$hwnd, [switch]$Exact) { $script:route = 'cocreate'; return $true }
function Get-AgentWindow { return @{ Hwnd = [IntPtr]1 } }
function Select-Workspace([IntPtr]$hwnd, [string]$name) { $script:workspaceSelected = $true; return $true }

function Get-SessionWorkspace($rec) { return $null }
Check 'ordinary session uses Activity route' (Open-AgentSession ([pscustomobject]@{})) $true
Check 'ordinary route target' $script:route 'activity'

function Get-SessionWorkspace($rec) { return 'Co-create Lab' }
$script:view = 'cocreate'
$script:workspaceSelected = $true
$script:route = ''
Check 'workspace session uses Co-create route' (Open-AgentSession ([pscustomobject]@{})) $true
Check 'workspace route target' $script:route 'cocreate'

Write-Host ("`n{0} passed, {1} failed" -f $script:Pass, $script:Fail)
if ($script:Fail -gt 0) { exit 1 }
