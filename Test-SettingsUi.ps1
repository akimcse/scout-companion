# Covers the settings window's opacity slider - specifically that it steps
# rather than jumping to an end.
#
# The WPF defaults are wrong for a range this narrow: LargeChange defaults to
# 1.0 while the whole range is 0.65, so one click on the track moved further
# than the range itself and slammed the value to whichever end was clicked. It
# is the kind of thing that only shows up when someone tries to use the
# control, so it is pinned here.
#
# Builds the real settings XAML and raises the same commands a mouse click and
# an arrow key do. Needs a desktop and an STA host:
#   powershell -NoProfile -ExecutionPolicy Bypass -STA -File Test-SettingsUi.ps1
Add-Type -AssemblyName PresentationFramework, PresentationCore, WindowsBase

if ([System.Threading.Thread]::CurrentThread.GetApartmentState() -ne 'STA') {
    Write-Host "This test needs -STA. Re-run with: powershell -NoProfile -ExecutionPolicy Bypass -STA -File Test-SettingsUi.ps1"
    exit 1
}

$src = Join-Path $PSScriptRoot 'scout-companion.ps1'
if (-not (Test-Path $src)) { Write-Host "scout-companion.ps1 not found next to this script"; exit 1 }

# The real markup, lifted out of the app rather than copied.
$text = Get-Content $src -Raw
$m = [regex]::Match($text, '(?s)\[xml\]\$settingsXaml\s*=\s*@''\r?\n(.*?)\r?\n''@')
if (-not $m.Success) { Write-Host "settings XAML not found in scout-companion.ps1"; exit 1 }
$w = [Windows.Markup.XamlReader]::Load((New-Object System.Xml.XmlNodeReader ([xml]$m.Groups[1].Value)))
$s = $w.FindName('OpacitySlider')
if (-not $s) { Write-Host "MISSING CONTROL: OpacitySlider"; exit 1 }
$w.WindowStartupLocation = 'Manual'; $w.Left = 20; $w.Top = 20
$w.Show()
$null = [System.Windows.Threading.Dispatcher]::CurrentDispatcher.Invoke(
    [System.Windows.Threading.DispatcherPriority]::Loaded, [action]{})

$script:Pass = 0
$script:Fail = 0
function Check($n, $got, $want) {
    $g = [math]::Round([double]$got, 4); $wv = [math]::Round([double]$want, 4)
    if ($g -eq $wv) { $script:Pass++; Write-Host ("  ok   {0,-40} -> {1}" -f $n, $g) }
    else { $script:Fail++; Write-Host ("  FAIL {0,-40} -> {1}  expected {2}" -f $n, $g, $wv) }
}
function Settle {
    $null = [System.Windows.Threading.Dispatcher]::CurrentDispatcher.Invoke(
        [System.Windows.Threading.DispatcherPriority]::Background, [action]{})
}
# Exactly what clicking the track raises.
function Track([string]$dir) {
    $cmd = if ($dir -eq 'up') { [System.Windows.Controls.Slider]::IncreaseLarge }
           else { [System.Windows.Controls.Slider]::DecreaseLarge }
    $cmd.Execute($null, $s); Settle
}
# And what an arrow key raises.
function Key([string]$dir) {
    $cmd = if ($dir -eq 'up') { [System.Windows.Controls.Slider]::IncreaseSmall }
           else { [System.Windows.Controls.Slider]::DecreaseSmall }
    $cmd.Execute($null, $s); Settle
}

try {
    Write-Host "the control is set up to step"
    Check 'a track click is one tick'          $s.LargeChange $s.TickFrequency
    Check 'an arrow key is one tick'           $s.SmallChange $s.TickFrequency
    if ($s.LargeChange -ge ($s.Maximum - $s.Minimum)) {
        $script:Fail++
        Write-Host ("  FAIL a click moves {0}, the whole range is {1}" -f $s.LargeChange, ($s.Maximum - $s.Minimum))
    }

    Write-Host "`nclicking the track"
    $s.Value = 0.70
    Track 'down'; Check 'one click left steps down'   $s.Value 0.65
    Track 'down'; Check 'again'                       $s.Value 0.60
    Track 'up';   Check 'one click right steps up'    $s.Value 0.65
    Track 'up';   Check 'again'                       $s.Value 0.70

    Write-Host "`narrow keys land on the ticks"
    $s.Value = 0.70
    Key 'down';   Check 'left arrow steps one tick'   $s.Value 0.65
    Key 'up';     Check 'right arrow steps one tick'  $s.Value 0.70

    Write-Host "`nthe ends still clamp"
    $s.Value = 0.40
    Track 'down'; Check 'down to the floor'           $s.Value 0.35
    Track 'down'; Check 'and stays there'             $s.Value 0.35
    $s.Value = 0.95
    Track 'up';   Check 'up to the ceiling'           $s.Value 1.00
    Track 'up';   Check 'and stays there'             $s.Value 1.00
} finally {
    try { $w.Close() } catch { }
}

Write-Host ("`n{0} passed, {1} failed" -f $script:Pass, $script:Fail)
if ($script:Fail -gt 0) { exit 1 }
