# Covers the Mini-mode path used when a conversation row raises Scout.
#
# Needs a desktop and an STA host:
#   powershell -NoProfile -ExecutionPolicy Bypass -STA -File Test-MiniMode.ps1
Add-Type -AssemblyName PresentationFramework, PresentationCore, WindowsBase, UIAutomationClient, UIAutomationTypes

if ([System.Threading.Thread]::CurrentThread.GetApartmentState() -ne 'STA') {
    Write-Host "This test needs -STA. Re-run with: powershell -NoProfile -ExecutionPolicy Bypass -STA -File Test-MiniMode.ps1"
    exit 1
}

$src = Join-Path $PSScriptRoot 'scout-companion.ps1'
if (-not (Test-Path $src)) { Write-Host "scout-companion.ps1 not found next to this script"; exit 1 }

$ast = [System.Management.Automation.Language.Parser]::ParseFile($src, [ref]$null, [ref]$null)
$funcs = $ast.FindAll({ param($n) $n -is [System.Management.Automation.Language.FunctionDefinitionAst] }, $true)
foreach ($name in @('Test-AgentPrimaryWindowTitle', 'Show-AgentFromMini')) {
    $function = $funcs | Where-Object { $_.Name -eq $name } | Select-Object -First 1
    if (-not $function) { Write-Host "MISSING FUNCTION: $name"; exit 1 }
    Invoke-Expression $function.Extent.Text
}

$script:Pass = 0
$script:Fail = 0
function Check($name, $got, $want) {
    if ($got -eq $want) { $script:Pass++; Write-Host ("  ok   {0,-48} -> {1}" -f $name, $got) }
    else { $script:Fail++; Write-Host ("  FAIL {0,-48} -> {1}  expected {2}" -f $name, $got, $want) }
}

Write-Host 'Test-AgentPrimaryWindowTitle'
Check 'main Scout window is eligible' (Test-AgentPrimaryWindowTitle 'Microsoft Scout (Internal)') $true
Check 'Mini indicator is auxiliary' (Test-AgentPrimaryWindowTitle 'Clawpilot Mini Mode') $false
Check 'renamed Mini indicator is auxiliary' (Test-AgentPrimaryWindowTitle 'Microsoft Scout Mini Mode') $false
Check 'Chromium input helper is auxiliary' (Test-AgentPrimaryWindowTitle 'Chrome Legacy Window') $false
Check 'untitled window is not eligible' (Test-AgentPrimaryWindowTitle '') $false

Write-Host "`nShow-AgentFromMini"
$clicked = $false
$window = New-Object System.Windows.Window
$window.Title = 'Clawpilot Mini Mode'
$window.Width = 120
$window.Height = 80
$button = New-Object System.Windows.Controls.Button
$button.Content = 'Show Clawpilot'
[System.Windows.Automation.AutomationProperties]::SetAutomationId($button, 'mini-button')
$button.Add_Click({ $script:clicked = $true })
$window.Content = $button
$window.Show()

$missing = New-Object System.Windows.Window
$missing.Title = 'Mini without button'
$missing.Width = 120
$missing.Height = 80
$missing.Show()

try {
    Start-Sleep -Milliseconds 300
    $handle = (New-Object System.Windows.Interop.WindowInteropHelper $window).Handle
    $missingHandle = (New-Object System.Windows.Interop.WindowInteropHelper $missing).Handle

    Check 'Mini button is invoked' (Show-AgentFromMini $handle) $true
    [System.Windows.Threading.Dispatcher]::CurrentDispatcher.Invoke(
        [action]{}, [System.Windows.Threading.DispatcherPriority]::Background)
    Check 'invocation reaches the click handler' $script:clicked $true
    Check 'window without Mini button is refused' (Show-AgentFromMini $missingHandle) $false
} finally {
    $window.Close()
    $missing.Close()
}

Write-Host ("`n{0} passed, {1} failed" -f $script:Pass, $script:Fail)
if ($script:Fail -gt 0) { exit 1 }
