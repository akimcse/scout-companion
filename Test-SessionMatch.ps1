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
                 'Test-ShouldNotifyFinish')) {
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
Same 'a pre-release suffix is ignored' (Compare-CompanionVersion 'v0.4.0-beta.1' '0.4.0') 0
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

