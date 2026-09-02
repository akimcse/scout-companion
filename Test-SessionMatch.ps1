# Tests for the sidebar row picker - the one piece of "Open goes to the right
# chat" that has to make a judgement call, and the only place a wrong answer
# would drop someone into the wrong conversation.
#
# The row lists below were copied out of Scout's own sidebar while the feature
# was being built, so these are the shapes it really produces, including the
# awkward one: a chat that is genuinely live but whose timestamp lags because
# it is not the chat currently on screen.
#
#   powershell -NoProfile -ExecutionPolicy Bypass -File Test-SessionMatch.ps1
#
$ErrorActionPreference = 'Stop'

$src = Join-Path $PSScriptRoot 'scout-companion.ps1'
if (-not (Test-Path $src)) { Write-Host "scout-companion.ps1 not found next to this script"; exit 1 }

# Lift the functions under test out of the app rather than copying them, so the
# tests can never drift from the code they claim to cover.
$ast = [System.Management.Automation.Language.Parser]::ParseFile($src, [ref]$null, [ref]$null)
$funcs = $ast.FindAll({ param($n) $n -is [System.Management.Automation.Language.FunctionDefinitionAst] }, $true)
foreach ($n in @('Truncate', 'Split-ChatRow', 'ConvertTo-AgeMinutes', 'Select-ChatRow',
                 'Get-LastUserMessage', 'Get-SessionSubject', 'Where-From', 'Get-QueueSuffix',
                 'Get-ShouldShow', 'Select-SessionRowPairs', 'Select-TitleAssignments',
                 'Format-Idle', 'Group-SessionRows',
                 'Compare-CompanionVersion', 'Test-UpdatableInstall',
                 'ConvertTo-EventTime', 'Format-Duration', 'Get-ElapsedLabel',
                 'Test-ShouldNotifyFinish', 'Get-RestoredPosition',
                 'Test-OwnReleaseTag', 'Select-LatestTag',
                 'Test-NearEdge', 'Get-ClampedPosition', 'Get-CurrentWorkArea',
                 'Get-SnappedPosition', 'Get-ResizedPosition', 'Get-BottomRightPosition',
                 'Get-EdgeGap')) {
    $f = $funcs | Where-Object { $_.Name -eq $n } | Select-Object -First 1
    if (-not $f) { Write-Host "MISSING FUNCTION: $n"; exit 1 }
    Invoke-Expression $f.Extent.Text
}

$script:Pass = 0
$script:Fail = 0

function Rows([string[]]$raw) { $raw | ForEach-Object { Split-ChatRow $_ } }

function Check([string]$name, $rows, [double]$age, [string]$expect) {
    $got = Select-ChatRow $rows $age
    $title = if ($got) { $got.Title } else { '<none>' }
    if ($title -eq $expect) {
        $script:Pass++
        Write-Host ("  ok   {0,-42} age={1,-5} -> {2}" -f $name, [int]$age, $title)
    } else {
        $script:Fail++
        Write-Host ("  FAIL {0,-42} age={1,-5} -> {2}   expected {3}" -f $name, [int]$age, $title, $expect)
    }
}

Write-Host 'Split-ChatRow'
$cases = @(
    @{ Raw = 'Pinned: AI Governance v1.5 6d ago More actions';                     Title = 'AI Governance v1.5';    When = '6d ago' },
    @{ Raw = 'Pinned: Scout Companion Just now More actions';                      Title = 'Scout Companion';       When = 'Just now' },
    @{ Raw = 'Outlook 일정 아이콘 자동 지정 5h ago Automation run More actions';    Title = 'Outlook 일정 아이콘 자동 지정'; When = '5h ago' },
    @{ Raw = 'AI Governance v1.5 sub 8/15/2026 More actions';                      Title = 'AI Governance v1.5 sub'; When = '8/15/2026' },
    @{ Raw = 'Shared Links 페이지 업데이트 (평일 매시간) Automation run More actions'; Title = 'Shared Links 페이지 업데이트 (평일 매시간)'; When = $null }
)
foreach ($c in $cases) {
    $p = Split-ChatRow $c.Raw
    if ($p.Title -eq $c.Title -and $p.When -eq $c.When) {
        $script:Pass++; Write-Host ("  ok   '{0}' / '{1}'" -f $p.Title, $p.When)
    } else {
        $script:Fail++; Write-Host ("  FAIL '{0}' / '{1}'   expected '{2}' / '{3}'" -f $p.Title, $p.When, $c.Title, $c.When)
    }
}

Write-Host "`nSelect-ChatRow"

# The case that matters most: the session is live, but Scout still shows its
# chat as eleven minutes old because the window is sitting on another chat.
Check 'live session, lagging timestamp' (Rows @(
    '메모리 정리 (WorkloadsSessionHost 누수 잡기) 28m ago More actions',
    'Pinned: AI Governance v1.5 6d ago More actions',
    'Pinned: AI Governance v1.5 sub 8/15/2026 More actions',
    'Pinned: FY27 Account Planning 4d ago More actions',
    'Pinned: Pipeline-Based Account and ABS Planning 8/12/2026 More actions',
    'Pinned: Scout Companion 11m ago More actions',
    'Opus 5 Benchmark Rerun 7/30/2026 More actions',
    'Pinned: Go Plus Cowork Account Tracking 7h ago More actions',
    'Pinned: RoB Automation 8/7/2026 More actions',
    '팀즈 심사 일정 작성 4d ago More actions')) 0 'Scout Companion'

# The search is semantic, so the right chat is often not the first row.
Check 'target not top-ranked' (Rows @(
    'Editing Open Loop Test Plan 7/15/2026 More actions',
    'Pinned: AI Governance v1.5 6d ago More actions',
    'Pinned: Scout Companion 12m ago More actions',
    'Pinned: AI Governance v1.5 sub 8/15/2026 More actions',
    'Pinned: Shared Document Links Dashboard 3d ago More actions')) 0 'Scout Companion'

# An older session must not be dragged to whatever moved most recently.
Check 'old session ignores fresher chats' (Rows @(
    'Pinned: Scout Companion Just now More actions',
    'Pinned: AI Governance v1.5 6d ago More actions',
    'Pinned: AI Governance v1.5 sub 8/15/2026 More actions',
    '아웃룩 일정 아이콘 일괄 변경 11h ago More actions',
    'Outlook 일정 아이콘 자동 지정 5h ago Automation run More actions')) 660 '아웃룩 일정 아이콘 일괄 변경'

Check 'no plausible row -> declines' (Rows @(
    'Pinned: AI Governance v1.5 6d ago More actions',
    'Opus 5 Benchmark Rerun 7/30/2026 More actions')) 0 '<none>'

# Without the search field open the rows carry no timestamp, so there is
# nothing to match on and nothing should be clicked.
Check 'no timestamps -> declines' (Rows @(
    'Pinned: AI Governance v1.5 More actions',
    'Pinned: Scout Companion More actions')) 0 '<none>'

Check 'tie broken by search rank' (Rows @(
    'Pinned: Scout Companion 3m ago More actions',
    '메모리 정리 (WorkloadsSessionHost 누수 잡기) 3m ago More actions')) 0 'Scout Companion'

Check 'fresher wins over better rank' (Rows @(
    '메모리 정리 (WorkloadsSessionHost 누수 잡기) 3m ago More actions',
    'Pinned: Scout Companion 2m ago More actions')) 0 'Scout Companion'

# A chat cannot really be newer than the session's own last message, so a row
# far fresher than that is some other conversation.
Check 'far-fresher row rejected' (Rows @(
    'Some Automation Just now More actions',
    'Pinned: Scout Companion 40m ago More actions')) 45 'Scout Companion'

Check 'hour-scale rounding absorbed' (Rows @(
    'Pinned: Expense 3h ago More actions',
    '아웃룩 일정 아이콘 일괄 변경 7h ago More actions',
    'Pinned: AI Governance v1.5 6d ago More actions')) 420 '아웃룩 일정 아이콘 일괄 변경'

function Same([string]$name, $got, $expect) {
    $g = if ($null -eq $got) { '<null>' } else { [string]$got }
    $e = if ($null -eq $expect) { '<null>' } else { [string]$expect }
    if ($g -eq $e) { $script:Pass++; Write-Host ("  ok   {0,-42} -> {1}" -f $name, $g) }
    else { $script:Fail++; Write-Host ("  FAIL {0,-42} -> {1}   expected {2}" -f $name, $g, $e) }
}

Write-Host "`nGet-LastUserMessage"
# A session that opens with "carry on" and only says what it wants later is the
# case the old first-message topic got wrong, so it is the case worth pinning.
$tmp = Join-Path ([System.IO.Path]::GetTempPath()) ("companion-events-{0}.jsonl" -f ([guid]::NewGuid().ToString('N')))
$lines = @(
    '{"type":"session.start","data":{"context":{"cwd":"C:\\work\\payments-api"}}}',
    '{"type":"user.message","data":{"content":"carry on"}}',
    '{"type":"assistant.message","data":{"content":"ok"}}',
    '{"type":"tool.execution_start","data":{"toolName":"powershell"}}',
    '{"type":"user.message","data":{"content":"fix the retry loop in the payment worker"}}',
    '{"type":"assistant.message","data":{"content":"looking"}}'
)
Set-Content -Path $tmp -Value $lines -Encoding UTF8
try {
    Same 'takes the latest message, not the first' (Get-LastUserMessage $tmp) 'fix the retry loop in the payment worker'

    Set-Content -Path $tmp -Value @(
        '{"type":"session.start","data":{}}',
        '{"type":"assistant.message","data":{"content":"working"}}'
    ) -Encoding UTF8
    Same 'no user message at all -> nothing' (Get-LastUserMessage $tmp) $null
    Same 'missing file -> nothing' (Get-LastUserMessage (Join-Path $tmp 'nope')) $null
} finally { Remove-Item $tmp -Force -ErrorAction SilentlyContinue }

Write-Host "`nGet-SessionSubject / Where-From"
$withTitle   = [pscustomobject]@{ ChatTitle = 'Scout Companion'; Subject = 'fix the retry loop'; BaseLabel = 'payments-api' }
$withSubject = [pscustomobject]@{ ChatTitle = $null;             Subject = 'fix the retry loop'; BaseLabel = 'payments-api' }
$bare        = [pscustomobject]@{ ChatTitle = $null;             Subject = $null;                BaseLabel = 'payments-api' }
# Which name is shown is a setting, so the test has to say which one it is
# asking about. Default off: the toast shows what you actually asked, so a
# prompt you just sent is not replaced by a summarised title the moment it is
# learned. This assertion still read the other way after that change shipped.
$Config = @{ showChatTitle = $false }
Same 'your own words win by default' (Get-SessionSubject $withTitle)   'fix the retry loop'
Same 'the title fills a gap'         (Get-SessionSubject ([pscustomobject]@{ ChatTitle = 'Scout Companion'; Subject = $null })) 'Scout Companion'
$Config = @{ showChatTitle = $true }
Same "Scout's own title wins"        (Get-SessionSubject $withTitle)   'Scout Companion'
Same 'and your words fill a gap'     (Get-SessionSubject $withSubject) 'fix the retry loop'
$Config = @{ showChatTitle = $false }
Same 'latest request when no title' (Get-SessionSubject $withSubject) 'fix the retry loop'
Same 'folder name is not a title'   (Get-SessionSubject $bare)        $null

# Where-From reads $Sessions to decide whether a bare folder name is worth
# showing, so the count has to be staged.
$Sessions = [ordered]@{ a = 1 }
Same 'title shows with one session' (Where-From @{ session='payments-api'; title='Scout Companion' }) '  -  Scout Companion'
Same 'folder stays quiet with one'  (Where-From @{ session='payments-api'; title=$null })             ''
$Sessions = [ordered]@{ a = 1; b = 2 }
Same 'folder shows with two'        (Where-From @{ session='payments-api'; title=$null })             '  -  payments-api'
Same 'nothing at all is safe'       (Where-From $null)                                                ''

Write-Host "`nGet-QueueSuffix"
# The count is over everything queued, not per kind. One approval standing in
# front of two questions is the case the old per-kind count got wrong: it read
# as a lone approval and the questions left no trace on screen.
Same 'nothing waiting'          (Get-QueueSuffix 0) ''
Same 'the one being shown'      (Get-QueueSuffix 1) ''
Same 'one approval, two asks'   (Get-QueueSuffix 3) ' (+2)'
Same 'two of the same kind'     (Get-QueueSuffix 2) ' (+1)'

Write-Host "`nGet-ShouldShow"
# Working, agent in front. The rule that hides the toast while you are looking
# at Scout is the whole reason a fresh launch looked like it had done nothing.
$busyFg = @{ HasPending=$false; HasAsk=$false; IsActive=$true; AgentRunning=$true
             IsMinimized=$false; IsForeground=$true; Hidden=$false; Pinned=$false; Greeting=$false }
Same 'busy but agent in front -> hidden'  (Get-ShouldShow @busyFg) $false
$greet = $busyFg.Clone(); $greet.Greeting = $true
Same 'greeting shows at startup'          (Get-ShouldShow @greet) $true
# The close button has to keep meaning closed, even mid-greeting.
$greetClosed = $greet.Clone(); $greetClosed.Hidden = $true
Same 'closing beats the greeting'         (Get-ShouldShow @greetClosed) $false
# A greeting must not suppress anything, and must not be needed to show a prompt.
$prompt = $busyFg.Clone(); $prompt.HasPending = $true
Same 'approval shows regardless'          (Get-ShouldShow @prompt) $true
# Idle with nothing happening stays quiet once the greeting lapses.
$idle = @{ HasPending=$false; HasAsk=$false; IsActive=$false; AgentRunning=$true
           IsMinimized=$false; IsForeground=$false; Hidden=$false; Pinned=$false; Greeting=$false }
Same 'idle and quiet -> hidden'           (Get-ShouldShow @idle) $false
$idleGreet = $idle.Clone(); $idleGreet.Greeting = $true
Same 'greeting shows even when idle'      (Get-ShouldShow @idleGreet) $true
# Background + working is the case the toast was written for.
$bg = $busyFg.Clone(); $bg.IsForeground = $false
Same 'busy in background -> shown'        (Get-ShouldShow @bg) $true

Write-Host "`nFormat-Idle"
Same 'seconds stay seconds'            (Format-Idle 42)   '42s'
Same 'a minute is minutes'             (Format-Idle 60)   '1m'
Same 'and not a big number of seconds' (Format-Idle 187)  '3m'
Same 'an hour is hours'                (Format-Idle 7200) '2h'
# PowerShell's [int] cast rounds rather than truncating, so these read as more
# time than had actually passed - 90 seconds announced itself as "2m", on a
# value that sits beside every idle session on screen.
Same 'ninety seconds is one minute'    (Format-Idle 90)   '1m'
Same 'and so is 119'                   (Format-Idle 119)  '1m'
Same 'just under two hours is one'     (Format-Idle 7100) '1h'
# The finished notice reuses this, so a long turn has to read as minutes. These
# are the real numbers from three days of use: the median turn, the 90th
# percentile, and the worst one seen.
Same 'the median turn measured'        (Format-Idle 11)   '11s'
Same 'the 90th percentile turn'        (Format-Idle 36)   '36s'
Same 'the worst turn measured'         (Format-Idle 607)  '10m'

Write-Host "`nFormat-Duration"
# A total, not an age. Format-Idle shows one unit because it sits at the end of
# a narrow line, but "17h" for a day's work throws away the part being asked
# about. The real measured figure was 1,060 minutes - 17.7 hours, which is
# 17h 40m, and 63,600 seconds is a different number entirely.
Same 'the measured day total'          (Format-Duration 63600) '17h 40m'
Same 'minutes keep their seconds'      (Format-Duration 125)   '2m 5s'
Same 'under a minute is seconds'       (Format-Duration 45)    '45s'
Same 'exactly an hour'                 (Format-Duration 3600)  '1h 0m'
# Nothing done yet has to read as nothing, not as "0s", which looks like a
# measurement that came back zero rather than an absence of one.
Same 'nothing yet reads as nothing'    (Format-Duration 0)     '-'

Write-Host "`nGet-ElapsedLabel"
# The single-session view is 89% of the time and said nothing about how long a
# turn had been running. Measured: the median turn is 11s, the 90th percentile
# 36s, the worst 10 minutes. So it stays silent through the ordinary ones and
# appears when a turn is long enough that you would start wondering.
$n = [datetime]::UtcNow
Same 'silent for a median turn'        (Get-ElapsedLabel $n.AddSeconds(-11) $n) ''
Same 'silent just under the threshold' (Get-ElapsedLabel $n.AddSeconds(-19) $n) ''
Same 'speaks at the threshold'         (Get-ElapsedLabel $n.AddSeconds(-20) $n) '20s'
Same 'the 90th percentile turn'        (Get-ElapsedLabel $n.AddSeconds(-36) $n) '36s'
Same 'a long turn reads as minutes'    (Get-ElapsedLabel $n.AddSeconds(-125) $n) '2m'
Same 'the worst turn measured'         (Get-ElapsedLabel $n.AddSeconds(-607) $n) '10m'
Same 'the threshold is adjustable'     (Get-ElapsedLabel $n.AddSeconds(-11) $n 5) '11s'

# No turn running means nothing to count.
Same 'no start, no label'              (Get-ElapsedLabel $null $n) ''
# A wrong clock should show nothing rather than a negative or a count of days.
Same 'a future start shows nothing'    (Get-ElapsedLabel $n.AddSeconds(60) $n) ''
Same 'and neither does a stale one'    (Get-ElapsedLabel $n.AddDays(-2) $n) ''

Write-Host "`nTest-ShouldNotifyFinish"
# 83 turns ran over two minutes in three days of real use, and while one of
# those is going you are somewhere else. But a balloon is only worth raising
# when it says something the screen does not.
Same 'dismissed and away: notify'      (Test-ShouldNotifyFinish $false $false $false) $true
Same 'hidden by the rules: notify'     (Test-ShouldNotifyFinish $false $true $false) $true
Same 'not shown but window up: notify' (Test-ShouldNotifyFinish $false $false $true) $true
# Already on screen saying the same thing.
Same 'toast already showing: silent'   (Test-ShouldNotifyFinish $false $true $true) $false
# You are looking at the agent that just finished.
Same 'agent in front: silent'          (Test-ShouldNotifyFinish $true $false $false) $false
Same 'in front, even if hidden'        (Test-ShouldNotifyFinish $true $true $false) $false
Same 'in front beats everything'       (Test-ShouldNotifyFinish $true $true $true) $false

Write-Host "`nGet-RestoredPosition"
# The toast would not stay where it was put. It is SizeToContent, and every
# step line, session row and approval card changes its height - and each of
# those re-ran the corner placement, dragging it home again.
#
# Restoring is not simply "use the saved numbers": the monitor it was on may be
# gone. A toast placed off-screen cannot be retrieved, because it has no taskbar
# button.
function Rect($l, $t, $r, $b) { [pscustomobject]@{ Left=$l; Top=$t; Right=$r; Bottom=$b } }
$one = @( (Rect 0 0 1920 1080) )
# A second monitor to the left, which is where negative coordinates come from.
$two = @( (Rect 0 0 1920 1080), (Rect -1920 0 0 1080) )
function Pos($l, $t) { [pscustomobject]@{ Left=$l; Top=$t } }

$ok = Get-RestoredPosition (Pos 800 400) $one 380 300
Same 'a position on screen is kept'    ($ok.Left) 800
Same 'both halves of it'               ($ok.Top)  400

# Nothing saved yet, or half a position, is not a position.
Same 'nothing saved, nothing restored' (Get-RestoredPosition $null $one 380 300) $null
Same 'a half position is refused'      (Get-RestoredPosition (Pos 800 $null) $one 380 300) $null
Same 'and so is a NaN'                 (Get-RestoredPosition (Pos ([double]::NaN) 400) $one 380 300) $null

# The case that matters: the screen it was on is gone.
Same 'a vanished monitor falls back'   (Get-RestoredPosition (Pos -1500 300) $one 380 300) $null
Same 'but is fine while it exists'     ((Get-RestoredPosition (Pos -1500 300) $two 380 300).Left) -1500
# No screens at all - a locked or disconnected session.
Same 'no screens, no restore'          (Get-RestoredPosition (Pos 800 400) @() 380 300) $null

# Below and to the right of everything.
Same 'past the bottom right falls back' (Get-RestoredPosition (Pos 3000 2000) $one 380 300) $null

# Hanging off an edge is fine as long as enough is left to grab. People do park
# the toast half off the bottom, and refusing that would be worse than allowing
# it - the corner is not where they left it.
$edge = Get-RestoredPosition (Pos 1700 1040) $one 380 300
Same 'hanging off the edge is allowed' ($edge.Left) 1700
# But a sliver is not enough to grab with a mouse.
Same 'a sliver is not'                 (Get-RestoredPosition (Pos 1890 400) $one 380 300) $null
Same 'nor a sliver at the bottom'      (Get-RestoredPosition (Pos 800 1070) $one 380 300) $null

Write-Host "`nedge snapping"
# Rectangles the way the app builds them.
function Rect([double]$l, [double]$t, [double]$w, [double]$h) {
    [pscustomobject]@{ Left = $l; Top = $t; Right = $l + $w; Bottom = $t + $h }
}
function Area([double]$l, [double]$t, [double]$r, [double]$b) {
    [pscustomobject]@{ Left = $l; Top = $t; Right = $r; Bottom = $b }
}

# This machine, measured: a 1843.2 x 1228.8 screen in WPF units with a 48-unit
# taskbar, so the work area stops at 1181.
$wa = Area 0 0 1843 1181

# --- the regression this exists for --------------------------------------
# The position that was actually in config.json - windowLeft 1463, windowTop 974
# - with the toast 207 tall, so its bottom sat exactly on the taskbar. Growing
# it to 320 used to leave the bottom at 1294, which is 113 units under the
# taskbar and climbing with every session row.
$parked = Rect 1463 974 380 207
Same 'a bottom-parked toast grows up'  (Get-ResizedPosition $parked 380 320 $wa).Top 861
# The point of the whole feature, stated as the thing that must be true.
Same 'and its bottom stays put'        ((Get-ResizedPosition $parked 380 320 $wa).Top + 320) 1181
# Shrinking again walks it back down rather than leaving a gap.
Same 'shrinking comes back down'       (Get-ResizedPosition $parked 380 120 $wa).Top 1061

# A toast near an edge keeps its distance from it rather than being pulled
# flush. Snapping flush is tidier and shorter, but the default corner sits
# exactly 16 units off both edges and the snap threshold is also 16 - so every
# toast that had never been moved got yanked hard into the corner of the screen
# the first time its content changed, shadow clipped. Found on a fresh install:
# placed at 3044,1072 and measured at 3060,1088.
$almost = Rect 1463 964 380 207
Same 'a near edge keeps its gap'       ((Get-ResizedPosition $almost 380 320 $wa).Top + 320) 1171
# The default corner is the case that matters: 16 off both edges, and it has to
# stay 16 off both edges however tall the toast gets.
$corner = Rect 1447 958 380 207
Same 'the default corner keeps its inset'  ((Get-ResizedPosition $corner 380 320 $wa).Top + 320) 1165
Same 'and its inset on the right too'      ((Get-ResizedPosition $corner 500 320 $wa).Left + 500) 1827
# A toast hanging over the edge is pulled back to it rather than kept there.
$over = Rect 1463 990 380 207
Same 'an overhang is pulled back'      ((Get-ResizedPosition $over 380 320 $wa).Top + 320) 1181
# The property that costs: the same input always gives the same answer, so
# repeated resizes cannot accumulate.
$once  = Get-ResizedPosition $almost 380 320 $wa
$twice = Get-ResizedPosition (Rect $once.Left $once.Top 380 320) 380 320 $wa
Same 'and resizing twice does not drift' $twice.Top $once.Top

# --- the other three edges ------------------------------------------------
$right = Rect 1463 400 380 207
Same 'a right-parked toast grows left' (Get-ResizedPosition $right 500 207 $wa).Left 1343
Same 'and its right edge stays put'    ((Get-ResizedPosition $right 500 207 $wa).Left + 500) 1843
$topLeft = Rect 0 0 380 207
Same 'a top-left toast holds its left' (Get-ResizedPosition $topLeft 500 320 $wa).Left 0
Same 'and holds its top'               (Get-ResizedPosition $topLeft 500 320 $wa).Top  0

# --- and the case that must not change ------------------------------------
# A toast in open space is not anchored to anything, so growing it must leave
# the top-left exactly where the user put it. Getting this wrong is the old bug
# coming back: a moved toast walking home on every content change.
$open = Rect 700 500 380 207
Same 'open space keeps its left'       (Get-ResizedPosition $open 380 320 $wa).Left 700
Same 'open space keeps its top'        (Get-ResizedPosition $open 380 320 $wa).Top  500

# --- a taskbar that is not at the bottom ----------------------------------
# Docking the taskbar left, right or top moves the work area's origin, and
# anything that assumed 0,0 would push the toast underneath it.
$topBar = Area 0 48 1843 1229
$underTop = Rect 700 48 380 207
Same 'a top taskbar is not covered'    (Get-ResizedPosition $underTop 380 400 $topBar).Top 48
$leftBar = Area 60 0 1843 1181
$atLeft = Rect 60 400 380 207
Same 'a left taskbar is not covered'   (Get-ResizedPosition $atLeft 500 207 $leftBar).Left 60
$rightBar = Area 0 0 1783 1181
$atRight = Rect 1403 400 380 207
Same 'a right taskbar is not covered'  ((Get-ResizedPosition $atRight 500 207 $rightBar).Left + 500) 1783

# --- dropping it ----------------------------------------------------------
# Let go within the threshold and it lines up; let go outside it and it stays
# exactly where it was put.
Same 'a near drop snaps flush'         (Get-SnappedPosition (Rect 1455 400 380 207) $wa).Left 1463
Same 'a near bottom drop snaps flush'  ((Get-SnappedPosition (Rect 700 966 380 207) $wa).Top + 207) 1181
Same 'exactly on the threshold snaps'  (Get-SnappedPosition (Rect 16 400 380 207) $wa).Left 0
Same 'one past it does not'            (Get-SnappedPosition (Rect 17 400 380 207) $wa).Left 17
Same 'a far drop is left alone'        (Get-SnappedPosition (Rect 700 500 380 207) $wa).Left 700
Same 'and keeps its top too'           (Get-SnappedPosition (Rect 700 500 380 207) $wa).Top  500

# --- nothing may be placed outside the work area --------------------------
# Dropping a toast half off the screen used to be allowed to persist; the snap
# pulls it back so the position that gets remembered is always one that can be
# reached again.
Same 'a drop off the right is pulled in' (Get-SnappedPosition (Rect 1700 400 380 207) $wa).Left 1463
Same 'a drop off the bottom too'         (Get-SnappedPosition (Rect 700 1100 380 207) $wa).Top 974
# A toast taller than the work area cannot fit. The clamp has to give up
# downwards, not upwards: overflowing the bottom loses the least useful part,
# while overflowing the top takes the drag area and the buttons off screen.
Same 'an oversized toast keeps its top' (Get-ClampedPosition 700 500 380 2000 $wa).Top 0
Same 'and is not pushed off the left'   (Get-ClampedPosition 700 500 4000 207 $wa).Left 0
Same 'oversized resize stays reachable' (Get-ResizedPosition (Rect 700 1100 380 207) 380 2000 $wa).Top 0

# --- the device pixel grid ------------------------------------------------
# WPF puts a window on the device pixel grid, rounding to the nearest, so a
# position that is correct in WPF units can still be applied one pixel out.
# Measured at 125% (one device pixel = 0.8 WPF units): a bottom-anchored toast
# computed a top of 975.8, WPF applied 976, and the bottom landed at device 1477
# with the taskbar starting at 1476. Small, but it is the same edge the whole
# feature exists to stay off.
$dpi125 = [pscustomobject]@{ X = 0.8; Y = 0.8 }
Same 'a top is put on the pixel grid'    (Get-ClampedPosition 700 975.8 380 205 $wa $dpi125).Top 975.2
Same 'and rounds towards the inside'     ([int]((Get-ClampedPosition 700 975.8 380 205 $wa $dpi125).Top -lt 975.8)) 1
# A value already on the grid must not be moved. 940.8 / 0.8 is
# 1175.9999999999998 in binary floating point, so a plain floor would walk it
# down a whole pixel every time this ran.
Same 'a value on the grid stays put'     (Get-ClampedPosition 700 940.8 380 240 $wa $dpi125).Top 940.8
Same 'and so does a work area edge'      (Get-ClampedPosition 0 0 380 205 $wa $dpi125).Top 0
# Without a scale the geometry is left in WPF units, which is what the rest of
# these tests measure.
Same 'no scale, no rounding'             (Get-ClampedPosition 700 975.8 380 205 $wa).Top 975.8
Same 'a zero scale is ignored too'       (Get-ClampedPosition 700 975.8 380 205 $wa ([pscustomobject]@{X=0;Y=0})).Top 975.8
# The anchor still holds after alignment: the bottom may move up by less than a
# pixel, never down.
$aligned = Get-ResizedPosition $parked 380 205 $wa $dpi125
Same 'an aligned anchor never overshoots' ([int](($aligned.Top + 205) -le 1181)) 1
Same 'and stays within a pixel of it'     ([int](($aligned.Top + 205) -gt (1181 - 0.8))) 1

# The drift this feature introduced and then had to fix. Rounding down on every
# resize loses up to a pixel each time, and if the next answer is derived from
# the last one those losses add up: measured live, 19 grow-and-shrink cycles
# walked the toast 7 device pixels up the screen. Anchoring to the work area
# instead of to the window's own edge makes each answer depend only on the
# height, so the same height always lands in the same place however many times
# it has been resized.
$heights = @(205, 242, 285, 335, 392, 456, 527, 605, 690, 782, 881)
$cur = $parked
$tops = @{}
for ($round = 1; $round -le 3; $round++) {
    foreach ($h in $heights) {
        $p = Get-ResizedPosition $cur 380 $h $wa $dpi125
        $cur = [pscustomobject]@{ Left = $p.Left; Top = $p.Top; Right = $p.Left + 380; Bottom = $p.Top + $h }
        if (-not $tops.ContainsKey($h)) { $tops[$h] = @() }
        $tops[$h] += $p.Top
    }
    foreach ($h in ($heights[($heights.Count - 1)..0])) {
        $p = Get-ResizedPosition $cur 380 $h $wa $dpi125
        $cur = [pscustomobject]@{ Left = $p.Left; Top = $p.Top; Right = $p.Left + 380; Bottom = $p.Top + $h }
        $tops[$h] += $p.Top
    }
}
$drifted = @($tops.Keys | Where-Object { (@($tops[$_] | Sort-Object -Unique)).Count -ne 1 })
Same 'sixty-six resizes do not drift'      ($drifted -join ',') ''
# ...and none of them ever crossed the edge on the way.
$over2 = @($tops.Keys | Where-Object { ($tops[$_][0] + $_) -gt 1181 })
Same 'and none of them crossed the edge'   ($over2 -join ',') ''

# The same, starting from the default corner rather than flush, because that is
# the gap that has to survive: 16 units off the edge, quantised onto the pixel
# grid and fed back in sixty-six times.
$cur2 = Rect 1447 958 380 207
$tops2 = @{}
for ($round = 1; $round -le 3; $round++) {
    foreach ($h in ($heights + $heights[($heights.Count - 1)..0])) {
        $p = Get-ResizedPosition $cur2 380 $h $wa $dpi125
        $cur2 = [pscustomobject]@{ Left = $p.Left; Top = $p.Top; Right = $p.Left + 380; Bottom = $p.Top + $h }
        if (-not $tops2.ContainsKey($h)) { $tops2[$h] = @() }
        $tops2[$h] += $p.Top
    }
}
$drifted2 = @($tops2.Keys | Where-Object { (@($tops2[$_] | Sort-Object -Unique)).Count -ne 1 })
Same 'the corner inset does not drift either' ($drifted2 -join ',') ''
# And it stays an inset rather than collapsing onto the screen edge. The gap is
# not exactly 16 every time - the pixel grid moves it by up to one device pixel
# depending on the height - but it never falls below the inset and never grows
# past it by a whole pixel, which is what "does not drift" means here.
$gaps = @($tops2.Keys | ForEach-Object { 1181 - ($tops2[$_][0] + $_) })
$badLow  = @($gaps | Where-Object { $_ -lt 16 - 0.001 })
$badHigh = @($gaps | Where-Object { $_ -gt 16 + 0.8 })
Same 'and it never touches the edge'          ($badLow.Count)  0
Same 'nor drifts a pixel away from it'        ($badHigh.Count) 0

# --- the default corner ---------------------------------------------------
Same 'the corner sits inside the edge' (Get-BottomRightPosition 380 207 $wa).Left 1447
Same 'and above the taskbar'           ((Get-BottomRightPosition 380 207 $wa).Top + 207) 1165
# The corner is measured from the work area, so a docked taskbar moves it - but
# only the two edges it is actually measured from. A taskbar on the left does
# not move a bottom-right corner, and claiming it did would be a test that
# passes without proving anything.
Same 'a right taskbar moves the corner' (Get-BottomRightPosition 380 207 $rightBar).Left 1387
Same 'a left one does not'              (Get-BottomRightPosition 380 207 $leftBar).Left 1447
Same 'a top taskbar moves it too'       (Get-BottomRightPosition 380 1200 $topBar).Top 48

Write-Host "`nGet-CurrentWorkArea"
# SystemParameters::WorkArea only ever describes the primary screen, so a toast
# on a second monitor would have been measured against the primary monitor's
# taskbar - which is somewhere else entirely, and usually not even on that
# screen. Two 1920x1080 monitors side by side, the right one with the taskbar.
$left1  = Area 0 0 1920 1080
$right1 = Area 1920 0 3840 1040
$two = @($left1, $right1)
Same 'a window picks the screen it is on' (Get-CurrentWorkArea (Rect 2000 100 380 207) $two).Left 1920
Same 'and the other one when it moves'    (Get-CurrentWorkArea (Rect 100 100 380 207) $two).Left 0
# Straddling both: most of it is on the right, so that is the one whose taskbar
# it has to respect.
Same 'straddling goes with the majority' (Get-CurrentWorkArea (Rect 1820 100 380 207) $two).Left 1920
Same 'and the other way round'           (Get-CurrentWorkArea (Rect 1720 100 380 207) $two).Left 0
# Overlapping neither - a monitor was unplugged while it was there - still has
# to answer with something, or the toast can never be placed again.
Same 'overlapping nothing still answers' (Get-CurrentWorkArea (Rect 100 5000 380 207) $two).Left 0
Same 'no rectangle yet takes the first'  (Get-CurrentWorkArea $null $two).Left 0
Same 'no screens, no answer'             (Get-CurrentWorkArea (Rect 0 0 380 207) @()) $null

Write-Host "`nthe handlers that use all of that"
# These are event handlers, not functions, so they cannot be lifted and called.
# What can be checked is that they still read the things they have to read - and
# each of these was a way for the feature to do nothing while looking correct.
#
# Comments are blanked out first. Matching raw source matches the comments too,
# and the comment warning that $e is null necessarily contains the word $args -
# so a check for $args passed while the code underneath used $e. Measured:
# reintroducing that exact bug left all 291 tests green. Same trap as a source
# check that matched the comment explaining why an endpoint is avoided.
$tokens = $null
$astT = [System.Management.Automation.Language.Parser]::ParseFile($src, [ref]$tokens, [ref]$null)

function Get-CodeOnly($extent) {
    $text = $extent.Text
    $start = $extent.StartOffset
    $sb = New-Object System.Text.StringBuilder $text
    foreach ($tk in $tokens) {
        if ($tk.Kind -ne 'Comment') { continue }
        $s = $tk.Extent.StartOffset - $start
        $e2 = $tk.Extent.EndOffset - $start
        if ($s -lt 0 -or $e2 -gt $text.Length) { continue }
        for ($i = $s; $i -lt $e2; $i++) { [void]$sb.Replace($sb[$i], ' ', $i, 1) }
    }
    return $sb.ToString()
}

# The handler body attached to $Window for a given event, comments stripped.
function Get-WindowHandler([string]$eventName) {
    $call = $astT.FindAll({ param($n)
        $n -is [System.Management.Automation.Language.InvokeMemberExpressionAst] -and
        $n.Member.Value -eq $eventName -and
        $n.Expression -is [System.Management.Automation.Language.VariableExpressionAst] -and
        $n.Expression.VariablePath.UserPath -eq 'Window'
    }, $true) | Select-Object -First 1
    if (-not $call -or $call.Arguments.Count -lt 1) { return '' }
    return Get-CodeOnly $call.Arguments[0].Extent
}

$sizeChanged = Get-WindowHandler 'Add_SizeChanged'
Same 'the SizeChanged handler was found' ([int][bool]$sizeChanged) 1

# $e does not exist in a PowerShell event handler. Measured: it is $null and the
# arguments arrive as $args. Written as $e.PreviousSize the previous rectangle
# would be zero-sized, no edge would ever test as near, and SizeChanged would
# hold nothing while appearing to hold everything.
Same 'SizeChanged reads the event args' ([int][bool]($sizeChanged -match '\$args\[1\]')) 1
Same 'and not a variable that is null'  ([int][bool]($sizeChanged -match '\$e\b')) 0
Same 'it holds the previous size'       ([int][bool]($sizeChanged -match 'PreviousSize')) 1

# The early return that stopped a moved toast walking home is also what left it
# growing under the taskbar: it skipped every resize once a position was saved.
# It has to branch now, not return.
Same 'it no longer skips a moved toast' `
    ([int][bool]($sizeChanged -match 'if \(\$script:SavedPosition\)\s*\{\s*return')) 0
Same 'it re-places an unmoved one'      ([int][bool]($sizeChanged -match 'Place-BottomRight')) 1
Same 'and anchors a moved one'          ([int][bool]($sizeChanged -match 'Get-ResizedPosition')) 1

# Dropping the toast is the only place a snap can be chosen deliberately.
$mouseDown = Get-WindowHandler 'Add_MouseLeftButtonDown'
Same 'the drag handler was found'       ([int][bool]$mouseDown) 1
Same 'a drop snaps to a near edge'      ([int][bool]($mouseDown -match 'Get-SnappedPosition')) 1
# rememberPosition off means the toast returns to the corner on the next content
# change anyway, so nothing here may invent a position behind the setting's back.
Same 'and respects rememberPosition'    ([int][bool]($mouseDown -match 'rememberPosition')) 1

# The grid alignment only happens if the real scale is handed to the geometry.
# It defaults to off so the pure tests can work in WPF units, which means a call
# site that forgot it would compile, pass every unit test, and quietly put the
# toast a pixel into the taskbar again.
$placeFn = Get-CodeOnly (($funcs | Where-Object { $_.Name -eq 'Place-BottomRight' } | Select-Object -First 1).Extent)
Same 'the corner is put on the grid'    ([int][bool]($placeFn -match 'Get-DeviceScale')) 1
Same 'and so is a resize'               ([int][bool]($sizeChanged -match 'Get-DeviceScale')) 1
Same 'and so is a drop'                 ([int][bool]($mouseDown -match 'Get-DeviceScale')) 1

# SystemParameters::WorkArea describes the primary screen and nothing else, so
# placement cannot be built on it. It survives in exactly one place - the
# fallback for when the DPI scale is not known yet - and nowhere else.
$primaryOnly = $funcs | Where-Object {
    $_.Name -in @('Place-BottomRight', 'Get-MonitorRects', 'Get-WorkAreaRects', 'New-WindowRect') -and
    $_.Extent.Text -match 'SystemParameters\]::WorkArea'
} | ForEach-Object { $_.Name }
Same 'placement is not primary-only'    ($primaryOnly -join ',') ''
$fallback = $funcs | Where-Object { $_.Name -eq 'Get-PlacementAreas' } | Select-Object -First 1
Same 'the documented fallback is there' ([int][bool]($fallback -and $fallback.Extent.Text -match 'SystemParameters\]::WorkArea')) 1

# WinForms measures in device pixels and WPF places in its own units, so a work
# area that skipped the transform would be 2304 wide where the window can only
# reach 1843 - no edge would ever be near, and the default corner would land off
# the screen. Measured on this machine at 125%.
#
# The conversion lives in Get-DeviceScale and Get-MonitorRects applies it, so
# both halves are checked rather than one function that happens to mention it.
$scaleFn = $funcs | Where-Object { $_.Name -eq 'Get-DeviceScale' } | Select-Object -First 1
Same 'there is a device-to-WPF scale' `
    ([int][bool]($scaleFn -and $scaleFn.Extent.Text -match 'TransformFromDevice')) 1
$rects = $funcs | Where-Object { $_.Name -eq 'Get-MonitorRects' } | Select-Object -First 1
Same 'and the monitors are put through it' `
    ([int][bool]($rects -and $rects.Extent.Text -match 'Get-DeviceScale')) 1
Same 'every edge of them, not just some' `
    ([regex]::Matches($rects.Extent.Text, '\$scale\.[XY]')).Count 4
# ...and it is WorkingArea, not Bounds, that leaves the taskbar out.
Same 'and the work area excludes the taskbar' `
    ([int][bool]($rects -and $rects.Extent.Text -match 'WorkingArea')) 1



Write-Host "`nConvertTo-EventTime"
# Turn timing has to come from the event, never the clock. The companion reads a
# session's whole backlog on its first pass, so dating those events "now" would
# report hours of past work as having happened the instant the app started - and
# would ring the finished notice for every one of them.
$then = [datetime]::UtcNow.AddHours(-3)
$e1 = [pscustomobject]@{ timestamp = $then.ToString('o') }
Same 'the event time is used'          ([int]((ConvertTo-EventTime $e1) - $then).TotalSeconds) 0
Same 'and it is not now'               ((([datetime]::UtcNow) - (ConvertTo-EventTime $e1)).TotalMinutes -ge 179) $true

# Timestamps arrive with an offset; everything downstream compares in UTC.
$e2 = [pscustomobject]@{ timestamp = '2026-08-26T09:00:00+09:00' }
Same 'an offset is converted to UTC'   ((ConvertTo-EventTime $e2).Hour) 0
Same 'and it is marked UTC'            ((ConvertTo-EventTime $e2).Kind.ToString()) 'Utc'

# A missing or broken stamp must not throw - one bad line would otherwise stop
# the reader for that whole session.
$now = [datetime]::UtcNow
Same 'no stamp falls back to now'      ([int]((ConvertTo-EventTime ([pscustomobject]@{})) - $now).TotalSeconds) 0
Same 'junk falls back too'             ([int]((ConvertTo-EventTime ([pscustomobject]@{ timestamp = 'not-a-date' })) - $now).TotalSeconds) 0

Write-Host "`nGroup-SessionRows"
# Handing the whole body to whichever session moved last put two unrelated jobs
# on screen as though they were one list - measured at 21 changes of owner in 30
# seconds. Rows are grouped instead, running first.
function Sn($name, $busy, $act, $idle) {
    [pscustomobject]@{ Name = $name; Busy = $busy; Activity = $act; IdleSeconds = $idle }
}
$mixed = @( (Sn 'a' $false '' 5), (Sn 'b' $true 'x' 0), (Sn 'c' $false '' 9), (Sn 'd' $true 'y' 0) )
$g = @(Group-SessionRows $mixed)
Same 'nothing is lost'                 $g.Count 4
Same 'running comes first'             $g[0].Name 'b'
Same 'and the other running one next'  $g[1].Name 'd'
Same 'then the quiet ones'             $g[2].Name 'a'
Same 'in the order they were given'    $g[3].Name 'c'

# Grouping by running/idle is not the churn this was built to avoid: that is a
# binary which changes only when a session starts or stops, unlike a last-event
# time that moves every second.
$stable = @(Group-SessionRows @( (Sn 'a' $true 'x' 0), (Sn 'b' $true 'y' 0) ))
Same 'all busy keeps the given order'  ($stable.Name -join ',') 'a,b'
$idle = @(Group-SessionRows @( (Sn 'a' $false '' 1), (Sn 'b' $false '' 2) ))
Same 'all idle keeps it too'           ($idle.Name -join ',') 'a,b'
Same 'nothing in, nothing out'         (@(Group-SessionRows @())).Count 0

Write-Host "`nCompare-CompanionVersion"
Same 'newer is newer'                  (Compare-CompanionVersion '0.4.0' '0.3.0')  1
Same 'older is older'                  (Compare-CompanionVersion '0.3.0' '0.4.0') -1
Same 'same is same'                    (Compare-CompanionVersion '0.3.0' '0.3.0')  0
# Release tags carry a leading v; [version] throws on it, which would have made
# every check silently decide there was no update.
Same 'a v prefix is not a difference'  (Compare-CompanionVersion 'v0.3.0' '0.3.0') 0
Same 'and still compares'              (Compare-CompanionVersion 'v0.4.0' '0.3.0') 1
Same 'patch counts'                    (Compare-CompanionVersion '0.3.1' '0.3.0')  1
Same 'minor beats patch'               (Compare-CompanionVersion '0.4.0' '0.3.9')  1
Same 'major beats minor'               (Compare-CompanionVersion '1.0.0' '0.9.9')  1
# 10 > 9 only if these are numbers, not text.
Same 'numbers, not text'               (Compare-CompanionVersion '0.10.0' '0.9.0') 1
Same 'a short tag is padded'           (Compare-CompanionVersion '1' '1.0.0')      0
# A pre-release comes before the version it is heading for. This was stripped
# and treated as equal until a beta ring needed the order - at which point
# 0.13.0-beta.1 equalled both 0.13.0-beta.2 and 0.13.0, so a beta user would
# never have been offered the next beta nor the stable release superseding it.
Same 'a beta precedes its release'    (Compare-CompanionVersion 'v0.4.0-beta.1' '0.4.0') -1
Same 'and the release follows it'     (Compare-CompanionVersion '0.4.0' 'v0.4.0-beta.1') 1
Same 'betas order among themselves'   (Compare-CompanionVersion '0.4.0-beta.2' '0.4.0-beta.1') 1
# Numerically, so 10 comes after 9 rather than sorting as text.
Same 'and count past nine'            (Compare-CompanionVersion '0.4.0-beta.10' '0.4.0-beta.9') 1
Same 'a bare beta precedes beta.1'    (Compare-CompanionVersion '0.4.0-beta' '0.4.0-beta.1') -1
Same 'identical betas are equal'      (Compare-CompanionVersion '0.4.0-beta.1' '0.4.0-beta.1') 0
# Build metadata is not part of precedence.
Same 'build metadata is ignored'      (Compare-CompanionVersion '0.4.0+abc' '0.4.0') 0
# And the numbers still outrank any of it.
Same 'a newer beta beats an older release' (Compare-CompanionVersion '0.5.0-beta.1' '0.4.0') 1
Same 'junk does not throw'             (Compare-CompanionVersion 'not-a-version' '0.3.0') -1
Same 'nothing is not newer'            (Compare-CompanionVersion $null '0.3.0')   -1

Write-Host "`nTest-UpdatableInstall"
# Only the installed copy may be replaced. The installer overwrites its target
# wholesale, so running it over a checkout would destroy uncommitted work - and
# a checkout is exactly where this gets developed.
$inst = 'C:\Users\x\AppData\Local\Programs\ScoutCompanion'
Same 'the installed copy updates'      (Test-UpdatableInstall $inst $inst) $true
Same 'a trailing slash is the same'    (Test-UpdatableInstall "$inst\" $inst) $true
Same 'case is not a difference'        (Test-UpdatableInstall $inst.ToUpper() $inst) $true
Same 'somewhere else does not'         (Test-UpdatableInstall 'C:\repos\scout-companion' $inst) $false
Same 'nothing does not'                (Test-UpdatableInstall $null $inst) $false

# The guard that matters: a .git folder means a working tree, even if someone
# has cloned into the install path.
$tmp = Join-Path $env:TEMP ('_upd_' + [guid]::NewGuid().ToString('N').Substring(0, 8))
New-Item -ItemType Directory -Path (Join-Path $tmp '.git') -Force | Out-Null
Same 'a checkout is refused'           (Test-UpdatableInstall $tmp $tmp) $false
Remove-Item -Recurse -Force $tmp -EA SilentlyContinue

Write-Host "`nthe version this build declares"
# A fourth component would be invisible: the comparison reads three, so 0.6.0.1
# and 0.6.0 are equal to it and the newer one would never be offered. Every copy
# already installed has that same three-part comparison baked in, so adopting a
# build number now would strand them silently. Pinned here rather than left to
# whoever edits the version next.
$verLine = Select-String -Path $src -Pattern "^\`$CompanionVersion\s*=\s*'([^']+)'" | Select-Object -First 1
Same 'the version is declared'         ([int][bool]$verLine) 1
$declared = if ($verLine) { $verLine.Matches[0].Groups[1].Value } else { '' }
Same 'it is three components'          ([bool]($declared -match '^\d+\.\d+\.\d+$')) $true
Same 'and not four'                    ([bool]($declared -match '^\d+\.\d+\.\d+\.\d+')) $false
# The guard is only worth having if a fourth component really does vanish.
Same 'a build number would be unseen'  (Compare-CompanionVersion "$declared.1" $declared) 0

Write-Host "`nTest-OwnReleaseTag"
# This repository now holds two companions: this one and a .NET rewrite, whose
# releases are tagged "net-v...". They share a releases list, so each has to
# ignore the other's - and this build owns the bare tags.
Same 'a plain tag is ours'             (Test-OwnReleaseTag 'v0.12.0') $true
Same 'without the v as well'           (Test-OwnReleaseTag '0.12.0')  $true
Same 'and a beta of ours'              (Test-OwnReleaseTag 'v0.13.0-beta.1') $true
Same 'a net- tag is not'               (Test-OwnReleaseTag 'net-v0.1.0') $false
Same 'nor a net- beta'                 (Test-OwnReleaseTag 'net-v0.2.0-beta.1') $false
# Any prefix at all belongs to somebody else, whatever it turns out to be.
Same 'nor any other prefix'            (Test-OwnReleaseTag 'cli-v1.0.0') $false
Same 'junk is not a tag'               (Test-OwnReleaseTag 'nightly') $false
Same 'nor is nothing'                  (Test-OwnReleaseTag '') $false

# The tag is text off the network, and Install-CompanionUpdate puts the chosen
# one inside a single-quoted PowerShell string. Git accepts a tag named
#   v1.0.0-'; <anything>; '
# which closes that quote. It was accepted here - the suffix pattern was ".*" -
# and the payload ran; measured with a stub installer that printed the tag it
# received, and the injected command executed after it. Anyone able to push a
# tag to the configured updateRepo had code execution on every machine that
# checked for an update, and updateRepo is documented as something you change
# to point at your own fork. The suffix is now semver's own alphabet.
Same 'a quote cannot ride in on a tag' (Test-OwnReleaseTag "v1.0.0-'; echo x; '") $false
Same 'nor a semicolon'                 (Test-OwnReleaseTag 'v1.0.0-a;b') $false
Same 'nor a space and a switch'        (Test-OwnReleaseTag 'v1.0.0- -NoRun') $false
Same 'nor a double quote'              (Test-OwnReleaseTag 'v1.0.0-a"b') $false
Same 'nor a subexpression'             (Test-OwnReleaseTag 'v1.0.0-$(calc)') $false
Same 'nor a backtick'                  (Test-OwnReleaseTag 'v1.0.0-a`b') $false
# ...while everything semver actually allows still passes.
Same 'dotted identifiers still pass'   (Test-OwnReleaseTag 'v1.0.0-beta.1') $true
Same 'hyphens in a suffix still pass'  (Test-OwnReleaseTag 'v1.0.0-rc-2') $true
Same 'build metadata still passes'     (Test-OwnReleaseTag 'v1.0.0+build.5') $true
Same 'both together still pass'        (Test-OwnReleaseTag 'v1.0.0-beta.1+build.5') $true

# And the interpolation itself doubles the quote, so the two guards are
# independent rather than one guard written twice.
$upd = Get-Content (Join-Path $PSScriptRoot 'scout-companion.ps1') -Raw
Same 'the tag is escaped where it is used' `
    ([int][bool]($upd -match "UpdateAvail\) -replace ""'"", ""''""")) 1

Write-Host "`nSelect-LatestTag"
function Rel($tag, $pre) { [pscustomobject]@{ tag_name = $tag; prerelease = $pre } }

# The case this exists for: a .NET release is newest, and /releases/latest would
# have returned it. Reading that, this build could parse no version out of it
# and would have believed itself up to date forever - and the one-line installer
# would have unpacked a .NET zip over a PowerShell install.
$mixed = @( (Rel 'net-v0.3.0' $false), (Rel 'v0.12.0' $false), (Rel 'net-v0.2.0' $false) )
Same 'the other build is ignored'      (Select-LatestTag $mixed) 'v0.12.0'

# Stable ring: prereleases do not count.
$ring = @( (Rel 'v0.13.0-beta.2' $true), (Rel 'v0.12.0' $false), (Rel 'v0.13.0-beta.1' $true) )
Same 'stable skips prereleases'        (Select-LatestTag $ring $false) 'v0.12.0'
Same 'beta ring takes the newest beta' (Select-LatestTag $ring $true)  'v0.13.0-beta.2'

# A stable release supersedes the betas that led to it, so a beta user moves on
# rather than being stranded on the last preview. Checked in both list orders:
# the first version of this passed only because the stable one happened to come
# first, back when the comparer called them equal.
$after = @( (Rel 'v0.13.0' $false), (Rel 'v0.13.0-beta.2' $true) )
Same 'stable wins once it exists'      (Select-LatestTag $after $true) 'v0.13.0'
$afterRev = @( (Rel 'v0.13.0-beta.2' $true), (Rel 'v0.13.0' $false) )
Same 'whatever order they arrive in'   (Select-LatestTag $afterRev $true) 'v0.13.0'

# By version, not by position. GitHub returns newest-published first, which is
# not the same thing - a patch to an older line published later would win.
$outOfOrder = @( (Rel 'v0.9.9' $false), (Rel 'v0.12.0' $false) )
Same 'order in the list does not win'  (Select-LatestTag $outOfOrder) 'v0.12.0'

Same 'nothing usable, nothing chosen'  (Select-LatestTag @( (Rel 'net-v1.0.0' $false) )) $null
Same 'an empty list is fine'           (Select-LatestTag @()) $null

# None of the above matters if the caller asks the wrong endpoint. /releases/latest
# returns a single release, and it is the wrong one twice over: it skips
# prereleases outright, so the beta ring can never see a beta; and it does not
# look at tag names at all, so a net- release published from the .NET rewrite
# comes back as "latest" and gets unpacked over a PowerShell install. Both call
# sites have to read the list and choose from it.
#
# Found by reintroducing the bug: every other regression here was caught, this
# one was not, and reverting the endpoint left all 211 tests green.
#
# Matched against the built URL, not any mention of it. The first version looked
# for the bare text and failed on the comments that explain why the endpoint is
# avoided - the same trap as a ${{ }} inside a workflow comment: what a file says
# about a thing is not the thing.
foreach ($f in @('scout-companion.ps1', 'web-install.ps1')) {
    $p = Join-Path $PSScriptRoot $f
    $s = if (Test-Path $p) { Get-Content $p -Raw } else { '' }
    Same "$f asks for the release list"  ([int][bool]($s -match 'repos/\$\w+/releases\?per_page=')) 1
    Same "$f does not ask for /latest"   ([int][bool]($s -match 'repos/\$\w+/releases/latest'))     0
}

# The installer is fetched and run on its own, so it cannot borrow the app's
# comparison and carries a second copy. Two copies drift; this is what stops
# them doing it quietly. Both were wrong the same way to begin with - suffix
# stripped - and fixing only the app would have left -Beta picking by list
# position while the app picked properly.
$wi = Join-Path $PSScriptRoot 'web-install.ps1'
if (Test-Path $wi) {
    $wiAst = [System.Management.Automation.Language.Parser]::ParseFile($wi, [ref]$null, [ref]$null)
    $cmp = $wiAst.FindAll({ param($n)
        $n -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -eq 'Compare-Tag'
    }, $true) | Select-Object -First 1
    Same 'the installer has a comparison'  ([int][bool]$cmp) 1
    if ($cmp) {
        Invoke-Expression $cmp.Extent.Text
        $pairs = @(
            @('v0.13.0',        'v0.13.0-beta.2'),
            @('v0.13.0-beta.2', 'v0.13.0'),
            @('0.13.0-beta.2',  '0.13.0-beta.1'),
            @('0.13.0-beta.10', '0.13.0-beta.9'),
            @('0.13.0-beta',    '0.13.0-beta.1'),
            @('0.5.0-beta.1',   '0.4.0'),
            @('0.4.0+abc',      '0.4.0'),
            @('v0.12.0',        '0.12.0'),
            @('1',              '0.9.9'),
            @('0.13.0-beta.1',  '0.13.0-beta.1')
        )
        $disagreed = @()
        foreach ($p in $pairs) {
            $app = Compare-CompanionVersion $p[0] $p[1]
            $ins = Compare-Tag $p[0] $p[1]
            if ($app -ne $ins) { $disagreed += ("{0}<>{1} app={2} installer={3}" -f $p[0], $p[1], $app, $ins) }
        }
        Same 'installer orders as the app does' ($disagreed -join '; ') ''
    }
}

Write-Host "`nbumping the version on merge"
# Releasing by hand meant the version and the work drifted apart: two pull
# requests landed on main while the declared version stayed at 0.8.2, so what
# was released and what was on main were different things. The workflow does it
# now, and this is the logic it uses - lifted from the same file it runs, so it
# cannot drift from what actually ships.
. (Join-Path $PSScriptRoot 'Bump-Version.ps1')

# The branch prefix is the signal because it is already the convention here, and
# it was the thing that was right when the version was wrong: v0.5.0 came from a
# branch named fix/ and should have been a patch.
Same 'feat earns a minor'        (Get-BumpKind 'Merge pull request #20 from akimcse/feat/turn-timing') 'minor'
Same 'fix earns a patch'         (Get-BumpKind 'Merge pull request #19 from akimcse/fix/one-activity-panel') 'patch'
Same 'chore earns a patch'       (Get-BumpKind 'Merge pull request #12 from akimcse/chore/start-at-0-1-0') 'patch'
Same 'docs earns a patch'        (Get-BumpKind 'Merge pull request #11 from akimcse/docs/version-and-readme') 'patch'
# Pull requests here come from forks, so the owner is somebody else and the
# branch still has to be found after it.
Same 'a fork is read the same'   (Get-BumpKind 'Merge pull request #29 from ltnalsxl/fix/one-companion-at-a-time') 'patch'
# A branch with slashes in its name must not lose them to the owner split.
Same 'a deep branch name works'  (Get-BumpKind 'Merge pull request #7 from someone/feat/a/b/c') 'minor'
# An unprefixed branch is not a reason to guess, but publishing nothing is worse
# than publishing conservatively.
Same 'no prefix is still a patch' (Get-BumpKind 'Merge pull request #3 from someone/just-a-branch') 'patch'

# A direct push to main releases nothing. Everything here goes through a pull
# request, so a bare push is an accident or work in progress, and neither should
# reach people running the auto-updater.
Same 'a direct push releases nothing' (Get-BumpKind 'Fix a typo in the readme') ''
Same 'and neither does nothing'       (Get-BumpKind '') ''
Same 'nor a near-miss subject'        (Get-BumpKind 'Merge branch main into feat/x') ''

# GitHub writes two different subjects for a merged pull request, and "Squash
# and merge" sits one click from "Merge pull request" in the same dropdown. The
# squash form keeps the number and drops the branch, and only the first shape
# was matched - so a squash merge released nothing while the step that decided
# so reported success. Measured on #48: merged, workflow green, no release, the
# version line untouched. Silence is the worst way for work not to ship.
Same 'a squash merge is a merge'     (Get-BumpKind 'Add a beta update ring (#48)' 'feat/beta-ring') 'minor'
Same 'and reads its branch too'      (Get-BumpKind 'Stop the flicker (#31)' 'fix/flicker') 'patch'
# Without a branch the shape is still a release - conservatively, as a patch -
# because a merge that reaches nobody is worse than one released too small.
Same 'no branch is still a patch'    (Get-BumpKind 'Add a beta update ring (#48)') 'patch'
# A supplied branch wins over one the subject names, since that is the case the
# parameter exists for; they agree anyway for a real merge commit.
Same 'a given branch is used'        (Get-BumpKind 'Merge pull request #20 from akimcse/fix/x' 'feat/y') 'minor'
# ...and a subject that merely mentions a number is not a merge.
Same 'a bare number is not a merge'  (Get-BumpKind 'Bump the timeout to 30 seconds') ''
Same 'nor is a number mid-sentence'  (Get-BumpKind 'Close (#12) properly later') ''

Same 'the merge-commit number'       (Get-MergedPrNumber 'Merge pull request #20 from akimcse/feat/x') '20'
Same 'the squash number'             (Get-MergedPrNumber 'Add a thing (#48)') '48'
Same 'no number, not a merge'        (Get-MergedPrNumber 'Just a commit') ''

Same 'a patch moves the last part'   (Get-NextVersion '0.8.2' 'patch') '0.8.3'
Same 'a minor moves the middle'      (Get-NextVersion '0.8.2' 'minor') '0.9.0'
Same 'and resets the patch'          (Get-NextVersion '0.8.9' 'minor') '0.9.0'
# Numbers, not text - 9 -> 10, not 9 -> 91 or a reset.
Same 'minors count past nine'        (Get-NextVersion '0.9.0' 'minor') '0.10.0'
Same 'patches count past nine'       (Get-NextVersion '0.8.9' 'patch') '0.8.10'
# major is never automated: it claims something people rely on changed shape,
# and no branch name can establish that. Even a branch that asks for one gets a
# patch.
Same 'a major is never inferred'     (Get-BumpKind 'Merge pull request #1 from x/major/rewrite') 'patch'
$majorThrew = $false
try { Get-NextVersion '0.8.2' 'major' } catch { $majorThrew = $true }
Same 'and cannot be asked for'       $majorThrew $true

Write-Host "`nthe release workflow"
# The workflow cannot be run from here, so what can be checked is checked: the
# things that made it fail, and the things that would make it dangerous.
$wf = Join-Path $PSScriptRoot '.github\workflows\release.yml'
Same 'the workflow exists'           ([int](Test-Path $wf)) 1
$wfText = if (Test-Path $wf) { Get-Content $wf -Raw } else { '' }

# GitHub evaluates every ${{ }} in a run block before pwsh ever sees it, so a
# PowerShell comment is no shelter - and an empty one is a syntax error that
# fails the run in zero seconds with only "workflow file issue" to go on. That
# is exactly how the first version of this broke, from a comment explaining
# why untrusted text is not interpolated.
$empties = @([regex]::Matches($wfText, '\$\{\{\s*\}\}'))
Same 'no empty expressions'          $empties.Count 0

# Pull requests here come from forks, so branch names and titles are written by
# people outside this repository. Interpolating them into a shell script that
# holds contents:write is a script-injection hole; git reads the same strings
# with no such path.
Same 'no untrusted text in a script' ([bool]($wfText -match 'run:[\s\S]*?\$\{\{\s*github\.event\.(head_commit|pull_request)')) $false

# It has to trigger on push. A fork's pull_request run gets a read-only token
# and could not push the version commit at all.
Same 'it triggers on a push'         ([bool]($wfText -match '(?m)^on:\s*$')) $true
Same 'to main'                       ([bool]($wfText -match '(?m)^\s*push:\s*\r?\n\s*branches:\s*\[main\]')) $true

# The bump is itself a push to main, so without a guard it would trigger itself
# forever.
Same 'the loop is guarded'           ([bool]($wfText -match '\[skip ci\]')) $true
Same 'and the guard is written too'  ([bool]($wfText -match "git commit -m .*\[skip ci\]")) $true

# A release must never carry contents newer than its own tag.
Same 'the tag pins the commit'       ([bool]($wfText -match '--target \$sha')) $true

# The notes have to be captured before the version is committed. After that,
# HEAD is the bot's own commit and its body is empty - which is how v0.8.3 came
# out with no notes at all.
Same 'notes are captured early'      ([bool]($wfText -match 'git log -1 --pretty=%b \| Out-File notes-body\.md')) $true
$bodyIdx  = $wfText.IndexOf('notes-body.md')
$commitIdx = $wfText.IndexOf('git commit -m')
Same 'and before the commit step'    ([bool]($bodyIdx -gt 0 -and $bodyIdx -lt $commitIdx)) $true

Write-Host "`nscripts survive a machine that is not this one"
# Windows PowerShell reads a script in the system ANSI codepage unless a BOM
# says otherwise. On this machine that happens to be compatible; on a US-locale
# runner the Korean test data came back as mojibake and the file would not
# parse - "Unexpected token '¬'". Reproduced by decoding the bytes as CP1252,
# and fixed by the BOM.
#
# Watch-Scout.ps1 matters more than the tests do: it ships, and it is what
# starts the companion at login.
$offenders = @()
foreach ($f in (Get-ChildItem $PSScriptRoot -Filter *.ps1)) {
    $bytes = [System.IO.File]::ReadAllBytes($f.FullName)
    $hasBom = $bytes.Length -ge 3 -and $bytes[0] -eq 0xEF -and $bytes[1] -eq 0xBB -and $bytes[2] -eq 0xBF
    $nonAscii = $false
    foreach ($b in $bytes) { if ($b -gt 127) { $nonAscii = $true; break } }
    if ($nonAscii -and -not $hasBom) { $offenders += $f.Name }
}
Same 'non-ASCII scripts carry a BOM' ($offenders -join ',') ''

# web-install.ps1 is the exception, and it has to be: it is fetched over HTTP
# and handed to the parser as a string, by the README's one-liner and by the
# companion's own update path. A leading U+FEFF is not skipped there the way it
# is when a file is opened - it becomes the first token.
#
# Measured, after a BOM was added to it in #48 and shipped in v0.12.1:
#   irm ... | iex          ->  The term '<#' is not recognized as a name of a cmdlet
#   [scriptblock]::Create  ->  the comment-based help block parses as code
# The headline install command in the README was broken for everyone installing
# fresh. Updates were not, only because Install-CompanionUpdate downloads with
# WebClient.DownloadString, which strips a BOM where Invoke-RestMethod keeps it.
#
# So the file must stay pure ASCII, which also keeps it out of the rule above.
$wiBytes = [System.IO.File]::ReadAllBytes((Join-Path $PSScriptRoot 'web-install.ps1'))
Same 'the installer has no BOM' `
    ([int]($wiBytes.Length -ge 3 -and $wiBytes[0] -eq 0xEF -and $wiBytes[1] -eq 0xBB -and $wiBytes[2] -eq 0xBF)) 0
$wiHigh = 0
foreach ($b in $wiBytes) { if ($b -gt 127) { $wiHigh++ } }
Same 'and no non-ASCII to need one' $wiHigh 0
# It must also survive being turned into a scriptblock from its own bytes,
# which is what both callers do.
$wiOk = $true
try { [void][scriptblock]::Create([System.Text.Encoding]::UTF8.GetString($wiBytes)) } catch { $wiOk = $false }
Same 'and parses when fetched as text' ([int]$wiOk) 1

# Invoke-RestMethod writes a JSON array to the pipeline as a single object, so
# @(Invoke-RestMethod ...) yields one element - the array - not its contents.
# Measured against the live API: 21 releases direct, 1 when wrapped. Wrapped,
# the sole element's tag_name is "System.Object[]", Test-OwnReleaseTag rejects
# it, Select-LatestTag returns nothing, and the companion reports no update
# available for ever without an error anywhere. Assign it, then wrap.
$wrapped = @()
foreach ($f in @('scout-companion.ps1', 'web-install.ps1')) {
    $p = Join-Path $PSScriptRoot $f
    if (-not (Test-Path $p)) { continue }
    if ((Get-Content $p -Raw) -match '@\(\s*Invoke-RestMethod') { $wrapped += $f }
}
Same 'no @() around Invoke-RestMethod' ($wrapped -join ',') ''

# ...and the release process must not undo that.
#
# Set-Content -Encoding UTF8 means "with a BOM" in Windows PowerShell and
# "without one" in PowerShell 7, and the workflow runs under 7. So the bump step
# stripped the BOM from scout-companion.ps1, which contains non-ASCII, and every
# automated release would have shipped an app that will not parse outside a
# codepage that happens to tolerate those bytes.
#
# Both directions are checked, so this fails under either host: the old code
# would strip a BOM under 7 and add one under 5.1, and neither is preserving.
$bomFile = Join-Path $env:TEMP ('_bom_' + [guid]::NewGuid().ToString('N').Substring(0,8) + '.ps1')
try {
    $body = "`$CompanionVersion = '1.2.3'`r`n# ok`r`n"
    [System.IO.File]::WriteAllText($bomFile, $body, (New-Object System.Text.UTF8Encoding($true)))
    Set-DeclaredVersion $bomFile '1.2.4'
    $b = [System.IO.File]::ReadAllBytes($bomFile)
    Same 'a BOM survives a bump'      ([bool]($b[0] -eq 0xEF -and $b[1] -eq 0xBB -and $b[2] -eq 0xBF)) $true
    Same 'and the version changed'    (Get-DeclaredVersion $bomFile) '1.2.4'

    [System.IO.File]::WriteAllText($bomFile, $body, (New-Object System.Text.UTF8Encoding($false)))
    Set-DeclaredVersion $bomFile '1.2.5'
    $b2 = [System.IO.File]::ReadAllBytes($bomFile)
    Same 'and no BOM is not invented' ([bool]($b2[0] -eq 0xEF)) $false
    Same 'with the version changed'   (Get-DeclaredVersion $bomFile) '1.2.5'
} finally { Remove-Item $bomFile -Force -ErrorAction SilentlyContinue }

# The three-component rule is enforced where the bump happens too, not only
# where the version is read.
$threw = $false
try { Get-NextVersion '0.8.2.1' 'patch' } catch { $threw = $true }
Same 'four components are refused'   $threw $true

# Every session picking on its own reaches for the freshest row, and then the
# one-title-one-session rule refuses the lot. They are pairs, not a race.
function Sess($d, $age) { [pscustomobject]@{ Dir = $d; Age = [double]$age } }
function Rw($t, $w)   { [pscustomobject]@{ Title = $t; When = $w } }

$p1 = @(Select-SessionRowPairs @( (Sess 'C:\s\a' 0.1), (Sess 'C:\s\b' 5.0) ) @( (Rw 'Scout Companion' '9m ago'), (Rw 'MSX Oppty' '11m ago') ))
Same 'the fresher session takes the fresher row' (($p1 | Where-Object { $_.Dir -eq 'C:\s\a' }).Title) 'Scout Companion'
Same 'the older one takes what is left'          (($p1 | Where-Object { $_.Dir -eq 'C:\s\b' }).Title) 'MSX Oppty'

# The lag is what makes the order usable: both rows read far older than either
# session, and the pairing still comes out right because the lag shifts them
# together rather than reshuffling them.
$p2 = @(Select-SessionRowPairs @( (Sess 'C:\s\a' 0.1) ) @( (Rw 'Scout Companion' '9m ago') ))
Same 'a lone session takes the lone row'         $p2[0].Title 'Scout Companion'

# Rows only carry whole minutes, so sessions closer together than that cannot
# be ordered against them - and this pairing is nothing but that order.
$p3 = @(Select-SessionRowPairs @( (Sess 'C:\s\a' 1.0), (Sess 'C:\s\b' 1.4) ) @( (Rw 'Scout Companion' 'Just now'), (Rw 'MSX Oppty' '2m ago') ))
Same 'sessions too close to order name nobody'   $p3.Count 0

# One row, two orderable sessions: the fresher takes it, the other goes without
# rather than being handed something already spoken for.
$p4 = @(Select-SessionRowPairs @( (Sess 'C:\s\a' 0.5), (Sess 'C:\s\b' 40.0) ) @( (Rw 'Scout Companion' 'Just now') ))
Same 'only one row to go round'                  $p4.Count 1
Same 'and the fresher session gets it'           $p4[0].Dir 'C:\s\a'

# A row outside the window is no more use than no row at all.
$p5 = @(Select-SessionRowPairs @( (Sess 'C:\s\a' 0.5) ) @( (Rw 'AI Governance v1.5' '6d ago') ))
Same 'an implausible row is not taken'           $p5.Count 0

Same 'no rows -> no pairs'                       (@(Select-SessionRowPairs @( (Sess 'C:\s\a' 1) ) @())).Count 0
Same 'undated rows are not candidates'           (@(Select-SessionRowPairs @( (Sess 'C:\s\a' 1) ) @( (Rw 'Scout Companion' $null) ))).Count 0

Write-Host "`nSelect-TitleAssignments"
# A real chat title is only worth showing because it identifies the
# conversation, so one hung on the wrong session is worse than none.
function Pair($d, $t) { [pscustomobject]@{ Dir = $d; Title = $t } }
$one = Select-TitleAssignments @( (Pair 'C:\s\a' 'AI Governance v1.5') ) $null
Same 'a single match is applied'          $one.Assign['C:\s\a'] 'AI Governance v1.5'
Same 'and nothing is taken away'          $one.Revoke.Count 0

$two = Select-TitleAssignments @( (Pair 'C:\s\a' 'AI Governance v1.5'), (Pair 'C:\s\b' 'Scout Companion') ) $null
Same 'two sessions, two titles (a)'       $two.Assign['C:\s\a'] 'AI Governance v1.5'
Same 'two sessions, two titles (b)'       $two.Assign['C:\s\b'] 'Scout Companion'

# Both sessions landed on the same row: genuinely ambiguous, so neither is named.
$clash = Select-TitleAssignments @( (Pair 'C:\s\a' 'RoB Automation'), (Pair 'C:\s\b' 'RoB Automation') ) $null
Same 'a contested title names nobody'     $clash.Assign.Count 0

# A third claimant must not un-contest a title the first two already spoiled.
$three = Select-TitleAssignments @( (Pair 'C:\s\a' 'RoB Automation'), (Pair 'C:\s\b' 'RoB Automation'), (Pair 'C:\s\c' 'RoB Automation') ) $null
Same 'still nobody with three claimants'  $three.Assign.Count 0

$mixed = Select-TitleAssignments @( (Pair 'C:\s\a' 'RoB Automation'), (Pair 'C:\s\b' 'RoB Automation'), (Pair 'C:\s\c' 'Team 1on1') ) $null
Same 'a clean match survives a clash'     $mixed.Assign['C:\s\c'] 'Team 1on1'
Same 'and only that one'                  $mixed.Assign.Count 1

Same 'nothing proposed -> nothing'        (Select-TitleAssignments @() $null).Assign.Count 0
Same 'junk proposals are dropped'         (Select-TitleAssignments @( (Pair 'C:\s\a' $null), (Pair $null 'x'), $null ) $null).Assign.Count 0

Write-Host "`nSelect-TitleAssignments: titles already spoken for"
# The case that actually happened: sessions named one at a time, each the only
# one without a name at the moment it was scanned, all ending up as the same
# conversation. Nothing catches that unless what others answer to is consulted.
$held = @{ 'Scout Companion' = 'C:\s\a' }
$steal = Select-TitleAssignments @( (Pair 'C:\s\b' 'Scout Companion') ) $held
Same 'a taken title is not handed out'    $steal.Assign.Count 0
Same 'and the holder loses it too'        ($steal.Revoke -join ',') 'C:\s\a'

# Re-proposing what a session already answers to is not a collision.
$same = Select-TitleAssignments @( (Pair 'C:\s\a' 'Scout Companion') ) $held
Same 'its own title is left alone'        $same.Assign.Count 0
Same 'and not revoked'                    $same.Revoke.Count 0

# A clash inside the pass, over a title someone else already holds.
$both = Select-TitleAssignments @( (Pair 'C:\s\b' 'Scout Companion'), (Pair 'C:\s\c' 'Scout Companion') ) $held
Same 'nobody gains it'                    $both.Assign.Count 0
Same 'the holder still loses it'          ($both.Revoke -join ',') 'C:\s\a'

# An unrelated title is unaffected by a collision elsewhere.
$mix2 = Select-TitleAssignments @( (Pair 'C:\s\b' 'Scout Companion'), (Pair 'C:\s\c' 'Expense') ) $held
Same 'the clean one still lands'          $mix2.Assign['C:\s\c'] 'Expense'
Same 'the contested one does not'         $mix2.Assign.ContainsKey('C:\s\b') $false

Write-Host "`nwhen the chat search is worth typing into"
# Learning a chat's name means typing into Scout's search box, because the
# sidebar only stamps rows with times once a query has been typed - and a time
# is the only thing that can match a chat to a session folder. That is
# intrusive, so it has to be earned.
$appSrc = Get-Content $src -Raw
# 0.8.0 made showChatTitle default to off and this was not revisited, so the
# companion kept typing into the search box to learn a name it did not display.
Same 'the scan is gated on the setting' ([bool]($appSrc -match '\$base = if \(\$Config\.showChatTitle\)')) $true
Same 'and off means never'              ([bool]($appSrc -match 'showChatTitle\) \{ \[double\]\$Config\.chatTitleScanMs \} else \{ 0 \}')) $true
Same 'the default is off'               ([bool]($appSrc -match 'showChatTitle\s+= \$false')) $true

# Some conversations can never be named - two started inside the same minute
# cannot be told apart by whole-minute rows - and were retried forever.
Same 'attempts are counted'             ([bool]($appSrc -match '\$script:ChatScanTries\[\$_\] -lt \[int\]\$Config\.chatTitleScanTries')) $true
Same 'and there is a limit'             ([bool]($appSrc -match 'chatTitleScanTries\s+= \d')) $true
# Giving up must not make it scan more often, which comparing the whole set did.
Same 'backoff resets only on new work'  ([bool]($appSrc -match '\$fresh = @\(\$unnamed \| Where-Object \{ \$_ -notin \$script:ChatScanKnown \}\)')) $true
# And a new message earns one more look, not a clean slate.
Same 'a new request decays the count'   ([bool]($appSrc -match 'if \(\$n -gt 0\) \{ \$script:ChatScanTries\[\$sess\.Dir\] = \$n - 1 \}')) $true

# Open must still learn the name as a side effect, or turning the setting on
# would have nothing to bootstrap from.
Same 'opening a chat still learns it'   ([bool]($appSrc -match 'Set-LearnedTitle \$rec\.Dir \$pick\.Title')) $true
# And the setting's tooltip has to admit what turning it on does, since being
# surprised by the typing is exactly what prompted this.
Same 'the tooltip says it will type'    ([bool]($appSrc -match "type into Scout's chat search")) $true

Write-Host ("`n{0} passed, {1} failed" -f $script:Pass, $script:Fail)
if ($script:Fail -gt 0) { exit 1 }

