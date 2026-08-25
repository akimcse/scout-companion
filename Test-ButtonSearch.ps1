# Covers the search that decides where Allow and Deny get clicked.
#
# Scout will not raise an approval on demand, and a wrong answer here is
# expensive in both directions - refusing means the buttons quietly do nothing,
# clicking the wrong window means approving something nobody read - so the
# search is exercised against real windows built for the purpose.
#
# Needs a desktop and an STA host:
#   powershell -NoProfile -ExecutionPolicy Bypass -STA -File Test-ButtonSearch.ps1
Add-Type -AssemblyName PresentationFramework, PresentationCore, WindowsBase, UIAutomationClient, UIAutomationTypes

if ([System.Threading.Thread]::CurrentThread.GetApartmentState() -ne 'STA') {
    Write-Host "This test needs -STA. Re-run with: powershell -NoProfile -ExecutionPolicy Bypass -STA -File Test-ButtonSearch.ps1"
    exit 1
}

$src = Join-Path $PSScriptRoot 'scout-companion.ps1'
if (-not (Test-Path $src)) { Write-Host "scout-companion.ps1 not found next to this script"; exit 1 }

# Lifted out of the app, not copied, so the test cannot drift from the code.
$ast = [System.Management.Automation.Language.Parser]::ParseFile($src, [ref]$null, [ref]$null)
$f = $ast.FindAll({ param($n) $n -is [System.Management.Automation.Language.FunctionDefinitionAst] }, $true) |
     Where-Object { $_.Name -eq 'Find-AgentButton' } | Select-Object -First 1
if (-not $f) { Write-Host "MISSING FUNCTION: Find-AgentButton"; exit 1 }
Invoke-Expression $f.Extent.Text

$script:Pass = 0
$script:Fail = 0
function Check($name, $got, $want) {
    if ($got -eq $want) { $script:Pass++; Write-Host ("  ok   {0,-46} -> {1}" -f $name, $got) }
    else { $script:Fail++; Write-Host ("  FAIL {0,-46} -> {1}  expected {2}" -f $name, $got, $want) }
}

# Staggered and topmost on purpose: overlapping windows make a perfectly
# present button read as offscreen, and the offscreen check is the thing under
# test - a false pass here would be worse than no test.
$script:NextLeft = 20
function New-Harness([string]$title, [string]$allowVisibility, [bool]$withDeny) {
    $w = New-Object System.Windows.Window
    $w.Title = $title; $w.Width = 240; $w.Height = 110; $w.Topmost = $true
    $w.WindowStartupLocation = 'Manual'; $w.Left = $script:NextLeft; $w.Top = 40
    $script:NextLeft += 260
    $sp = New-Object System.Windows.Controls.StackPanel
    if ($allowVisibility) {
        $b = New-Object System.Windows.Controls.Button
        $b.Content = 'Allow'; $b.Visibility = $allowVisibility
        $sp.Children.Add($b) | Out-Null
    }
    if ($withDeny) {
        $d = New-Object System.Windows.Controls.Button
        $d.Content = 'Deny'
        $sp.Children.Add($d) | Out-Null
    }
    $w.Content = $sp
    $w.Show()
    return $w
}
function Get-Handle($w) { (New-Object System.Windows.Interop.WindowInteropHelper $w).Handle }

$labels = @('Allow')
$shown  = New-Harness 'harness-shown'  'Visible' $true
$hidden = New-Harness 'harness-hidden' 'Hidden'  $true
$none   = New-Harness 'harness-none'   $null     $true
$second = $null
try {
    Start-Sleep -Milliseconds 1200

    Write-Host "Find-AgentButton"
    Check 'window showing Allow -> found'       ($null -ne (Find-AgentButton (Get-Handle $shown)  $labels)) $true
    # A window with the button in its tree but not rendered is every window
    # that is not asking; taking it would make the search meaningless.
    Check 'Allow present but not rendered'      ($null -ne (Find-AgentButton (Get-Handle $hidden) $labels)) $false
    Check 'window with no Allow at all'         ($null -ne (Find-AgentButton (Get-Handle $none)   $labels)) $false
    Check 'Deny is found independently'         ($null -ne (Find-AgentButton (Get-Handle $shown)  @('Deny'))) $true

    Write-Host "`nthe exactly-one rule"
    $hits = @()
    foreach ($w in @($shown, $hidden, $none)) { $b = Find-AgentButton (Get-Handle $w) $labels; if ($b) { $hits += $b } }
    Check 'three windows, one asking -> clicks'  $hits.Count 1

    # Two windows both asking is genuinely ambiguous. Refusing is the point.
    $second = New-Harness 'harness-shown-2' 'Visible' $true
    Start-Sleep -Milliseconds 1200
    $hits2 = @()
    foreach ($w in @($shown, $hidden, $none, $second)) { $b = Find-AgentButton (Get-Handle $w) $labels; if ($b) { $hits2 += $b } }
    Check 'two windows asking -> ambiguous'      $hits2.Count 2
    Check '  so it refuses'                      ($hits2.Count -eq 1) $false
} finally {
    foreach ($w in @($shown, $hidden, $none, $second)) { if ($w) { try { $w.Close() } catch { } } }
}

Write-Host ("`n{0} passed, {1} failed" -f $script:Pass, $script:Fail)
if ($script:Fail -gt 0) { exit 1 }
