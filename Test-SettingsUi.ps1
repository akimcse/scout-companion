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

    # ------------------------------------------------------------------
    # The update checkboxes have to react to a toggle that did not come from a
    # mouse, and they have to do it the way the rest of this window does.
    #
    # They were first wired to Click. That turned out to still fire under WPF's
    # toggle peer - so the obvious behavioural test passes either way and proves
    # nothing. What Click does not cover is a programmatic change to IsChecked,
    # which is exactly what priming the window does, and it leaves these two
    # controls inconsistent with every other checkbox here. So this pins both:
    # the behaviour, and the convention the behaviour depends on.
    # ------------------------------------------------------------------
    Write-Host "`nthe update checkboxes answer to more than a mouse"
    foreach ($n in @('UpdateCheckChk', 'AutoUpdateChk', 'NotifyFinishChk', 'RememberPosCheck', 'BetaRingChk')) {
        $cb = $w.FindName($n)
        if (-not $cb) {
            $script:Fail++; Write-Host ("  FAIL missing control {0}" -f $n); continue
        }
        $script:Fired = 0
        $cb.Add_Checked({ $script:Fired++ })
        $cb.Add_Unchecked({ $script:Fired++ })

        # What UI Automation's TogglePattern does.
        $peer = [System.Windows.Automation.Peers.CheckBoxAutomationPeer]::new($cb)
        $tp = $peer.GetPattern([System.Windows.Automation.Peers.PatternInterface]::Toggle)
        $cb.IsChecked = $false; Settle
        $script:Fired = 0
        $tp.Toggle(); Settle
        Check "$n reacts to a non-mouse toggle" $script:Fired 1
        Check "$n actually changed"             ([int][bool]$cb.IsChecked) 1

        # And to code setting the value, which Click would miss entirely.
        $script:Fired = 0
        $cb.IsChecked = $false; Settle
        Check "$n reacts when code sets it"     $script:Fired 1
    }

    # The convention, checked against the source. AutoStartCheck and AnimCheck
    # both use Checked/Unchecked; a control that quietly used Click instead
    # would behave differently for reasons no reader could see.
    Write-Host "`nand are wired the same way as the rest of the window"
    foreach ($n in @('SettingsUpdateChk', 'SettingsAutoUpdChk', 'SettingsNotifyChk', 'SettingsRememberPos',
                     'SettingsBetaChk')) {
        $usesToggle = $text -match [regex]::Escape("`$script:$n.Add_Checked")
        $usesClick  = $text -match [regex]::Escape("`$script:$n.Add_Click")
        Check "$n subscribes to Checked"   ([int][bool]$usesToggle) 1
        Check "$n does not use Click"      ([int][bool]$usesClick)  0
    }

    # The controls the update code binds all exist, and the two activity panels
    # are never on screen together.
    Write-Host "`nthe controls the update code binds all exist"
    foreach ($n in @('UpdateCheckChk', 'AutoUpdateChk', 'CheckUpdateBtn', 'UpdateStatus', 'VerText',
                     'NotifyFinishChk', 'AgentTimeText', 'AgentTurnsText', 'AgentSessText',
                     'InstallUpdateBtn', 'BetaRingChk')) {
        Check "$n is present" ([int][bool]($w.FindName($n))) 1
    }

    # ------------------------------------------------------------------
    # Finding out an update exists has to be actionable where you found out.
    #
    # Install was only in the tray menu, so Settings could tell you a new
    # version was available and then offer nothing to do about it - which is
    # exactly how it was reported: "there is a Check now, but I don't know what
    # comes next".
    # ------------------------------------------------------------------
    Write-Host "`nSettings can act on what it just told you"
    $ib = $w.FindName('InstallUpdateBtn')
    Check 'the install button exists'    ([int][bool]$ib) 1
    # Hidden until there is something to install, or it is a button that lies.
    Check 'and starts hidden'            ([int]($ib.Visibility -eq 'Collapsed')) 1
    Check 'it sits beside Check now'     ([int]([System.Windows.Controls.DockPanel]::GetDock($ib) -eq 'Left')) 1
    # Wired, and to the same function the tray item uses.
    Check 'the handler is wired'         ([int][bool]($text -match 'SettingsInstallBtn\.Add_Click')) 1
    Check 'to the shared installer'      ([int][bool]($text -match 'SettingsInstallBtn\.Add_Click\(\{\s*\r?\n\s*Install-CompanionUpdate')) 1

    # ------------------------------------------------------------------
    # An install that cannot start has to say so. It used to swallow the error,
    # leaving the status claiming an update was available and the button still
    # sitting there - pressing it appeared to do nothing at all.
    # ------------------------------------------------------------------
    Write-Host "`na failed install is reported"
    Check 'the failure is recorded'      ([int][bool]($text -match '\$script:UpdateError = \$_\.Exception\.Message')) 1
    Check 'and raised to the tray'       ([int][bool]($text -match "Show-TrayBalloon \(T 'Update failed'\)")) 1
    Check 'and shown in settings'        ([int][bool]($text -match "\`$script:UpdateError\s*\)\s*\{ \(T 'Update failed:'\)")) 1
    # Without -ErrorAction Stop the launch failure never reaches the catch, so
    # the reporting above would be unreachable code.
    Check 'Start-Process can throw'      ([int][bool]($text -match "'-Command', \`$cmd -ErrorAction Stop")) 1

    # ------------------------------------------------------------------
    # Pressing "check" is not the same as saying "install". Unattended
    # installing belongs to the background check; when Check now triggered it,
    # the running program was replaced without being asked - and when that
    # failed, silently.
    # ------------------------------------------------------------------
    Write-Host "`nchecking on demand does not install on its own"
    Check 'autoUpdate defers to the user' ([int][bool]($text -match '\$Config\.autoUpdate -and -not \$script:UpdateAnnounce')) 1

    # ElapsedText lives on the toast, not here; checked with the toast markup
    # further down.

    # ------------------------------------------------------------------
    # One activity panel at a time.
    #
    # StepsPanel shows a single session's steps; SessionsPanel shows a row per
    # session when there are several. Adding the second one left the approval
    # and question paths still hiding only the first, so with two sessions and a
    # prompt up, both were on screen at once - the same work listed twice, one
    # block above the other. It looked like the multi-session view had been
    # reverted.
    #
    # Checked against the source: every place that puts the body away must clear
    # both, which is what Hide-ActivityPanels is for.
    # ------------------------------------------------------------------
    Write-Host "`nthe two activity panels are never shown together"
    $toast = [regex]::Match($text, "(?s)\[xml\]\`$xaml\s*=\s*@'\r?\n(.*?)\r?\n'@")
    Check 'the toast markup was found' ([int]$toast.Success) 1
    $tx = [xml]$toast.Groups[1].Value
    $names = @($tx.SelectNodes('//*') | ForEach-Object { $_.GetAttribute('x:Name') })
    Check 'StepsPanel exists'    ([int]($names -contains 'StepsPanel')) 1
    Check 'SessionsPanel exists' ([int]($names -contains 'SessionsPanel')) 1

    # The elapsed counter, which is the one thing the single-session view gained
    # - and it is 89% of the time this toast is on screen.
    Check 'ElapsedText exists'   ([int]($names -contains 'ElapsedText')) 1
    # Collapsed to begin with, or a toast with no turn running shows an empty
    # gap beside the header from the first frame.
    $ev = @($tx.SelectNodes('//*') | Where-Object { $_.GetAttribute('x:Name') -eq 'ElapsedText' } | ForEach-Object { $_.GetAttribute('Visibility') })
    Check 'and starts collapsed' ([int]($ev -contains 'Collapsed')) 1
    # Docked right and declared before the header: DockPanel fills with its last
    # child, so a header docked last would take the width and leave none for it.
    $ed = @($tx.SelectNodes('//*') | Where-Object { $_.GetAttribute('x:Name') -eq 'ElapsedText' } | ForEach-Object { $_.GetAttribute('DockPanel.Dock') })
    Check 'and is docked right'  ([int]($ed -contains 'Right')) 1

    # ------------------------------------------------------------------
    # The toast has to stay where it is put.
    #
    # It is SizeToContent, and the size handler re-ran the corner placement
    # unconditionally - so every step line, session row and approval card
    # dragged a moved toast back to the bottom right. The guard was to skip
    # the placement entirely once a position had been remembered.
    #
    # That guard was then the other half of a second fault: skipping every
    # resize meant a toast parked on the bottom edge kept its top and grew
    # downwards, straight under the taskbar. Measured at 275px of overlap
    # after one grow from 100 to 320. So the handler no longer skips - it
    # branches, and a moved toast holds the edge it is sitting against
    # instead of being re-placed or ignored.
    #
    # Both halves are pinned here, because either one alone is a bug that
    # ships: re-place unconditionally and it walks home, skip
    # unconditionally and it sinks.
    # ------------------------------------------------------------------
    Write-Host "`nthe toast stays where it is put"
    Check 'the position can be remembered' ([int][bool]($text -match 'rememberPosition\s+= \$true')) 1
    Check 'and there is a control for it'  ([int][bool]($w.FindName('RememberPosCheck'))) 1
    # The corner placement is reachable only when nothing has been remembered.
    Check 'the corner is only for an unmoved toast' `
        ([int][bool]($text -match '(?s)Add_SizeChanged\(\{.*?if \(-not \$script:SavedPosition\) \{ Place-BottomRight; return \}')) 1
    # And a moved one is anchored rather than left to grow under the taskbar.
    Check 'a moved one is anchored instead' `
        ([int][bool]($text -match '(?s)Add_SizeChanged\(\{.*?Get-ResizedPosition')) 1
    # Writes are coalesced, and a drag ending just before exit must not be lost.
    Check 'the write is debounced'         ([int][bool]($text -match 'PositionTimer')) 1
    Check 'and flushed on the way out'     ([int](([regex]::Matches($text, 'Save-PendingPosition')).Count -ge 4)) 1
    # A saved position is checked against the screens that exist now, because a
    # toast placed off-screen cannot be retrieved - it has no taskbar button.
    Check 'restore is screen-checked'      ([int][bool]($text -match 'Get-RestoredPosition \$script:SavedPosition \(Get-ScreenRects\)')) 1
    # WinForms reports device pixels, WPF positions in device-independent ones.
    Check 'and DPI is converted'           ([int][bool]($text -match 'TransformFromDevice')) 1

    # Both start collapsed, or the toast would flash a panel on the first frame.
    foreach ($p in @('StepsPanel', 'SessionsPanel')) {
        $vis = @($tx.SelectNodes('//*') | Where-Object { $_.GetAttribute('x:Name') -eq $p } | ForEach-Object { $_.GetAttribute('Visibility') })
        Check "$p starts collapsed" ([int]($vis -contains 'Collapsed')) 1
    }

    # The prompt paths must go through the helper rather than collapsing one
    # panel by hand - that is precisely the bug this pins.
    $handSet = [regex]::Matches($text, '\$SayingText\.Visibility\s*=\s*''Collapsed''\s*\r?\n\s*\$StepsPanel\.Visibility\s*=\s*''Collapsed''')
    Check 'no path hides only the step panel' $handSet.Count 0
    Check 'the shared helper exists'          ([int][bool]($text -match 'function Hide-ActivityPanels')) 1
    $calls = [regex]::Matches($text, 'Hide-ActivityPanels').Count
    Check 'and is used by both prompt paths'  ([int]($calls -ge 3)) 1
} finally {
    try { $w.Close() } catch { }
}

Write-Host ("`n{0} passed, {1} failed" -f $script:Pass, $script:Fail)
if ($script:Fail -gt 0) { exit 1 }
