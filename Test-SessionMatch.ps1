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
                 'Get-ShouldShow')) {
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
Same "Scout's own title wins"      (Get-SessionSubject $withTitle)   'Scout Companion'
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

Write-Host ("`n{0} passed, {1} failed" -f $script:Pass, $script:Fail)
if ($script:Fail -gt 0) { exit 1 }
