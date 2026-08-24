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
foreach ($n in @('Split-ChatRow', 'ConvertTo-AgeMinutes', 'Select-ChatRow')) {
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

Write-Host ("`n{0} passed, {1} failed" -f $script:Pass, $script:Fail)
if ($script:Fail -gt 0) { exit 1 }
