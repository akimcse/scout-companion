# Covers how a session comes to be called by Scout's own name for its chat:
# the match, the refusal to look while someone is watching, the refusal to
# guess between two candidates, and the store that keeps a learned title from
# evaporating.
#
# Drives the real Update-SessionTitles end to end by standing in for the one
# thing that cannot be staged here - what Scout's sidebar hands back.
#
#   powershell -NoProfile -ExecutionPolicy Bypass -File Test-TitleLearning.ps1
$src = Join-Path $PSScriptRoot 'scout-companion.ps1'
if (-not (Test-Path $src)) { Write-Host "scout-companion.ps1 not found next to this script"; exit 1 }

# Lifted out of the app, not copied, so the test cannot drift from the code.
$ast = [System.Management.Automation.Language.Parser]::ParseFile($src, [ref]$null, [ref]$null)
$funcs = $ast.FindAll({ param($n) $n -is [System.Management.Automation.Language.FunctionDefinitionAst] }, $true)
foreach ($n in @('Truncate','ConvertTo-AgeMinutes','Select-ChatRow','Select-TitleAssignments',
                 'Get-LastMessageUtc','Import-TitleStore','Save-TitleStore',
                 'Set-LearnedTitle','Update-SessionTitles')) {
    $f = $funcs | Where-Object { $_.Name -eq $n } | Select-Object -First 1
    if (-not $f) { Write-Host "MISSING FUNCTION: $n"; exit 1 }
    Invoke-Expression $f.Extent.Text
}

# Everything that needs a live Scout window, stubbed. $Searches records what was
# typed, so the test can assert the sidebar was left alone when it should be.
$script:Unobserved = $true
$script:Searches   = @()
$script:Answers    = @()
function Resolve-SessionLabels { }
function Test-AgentUnobserved { return $script:Unobserved }
function Select-SearchWindow { return [IntPtr]1 }
function Get-SessionQuery($rec) { return $rec.Query }
function Invoke-ChatSearch([IntPtr]$hwnd, [string[]]$queries) {
    $script:Searches += ,@($queries)
    return $script:Answers
}

$tmp = Join-Path ([System.IO.Path]::GetTempPath()) ("titletest-{0}" -f ([guid]::NewGuid().ToString('N')))
New-Item -ItemType Directory -Force -Path $tmp | Out-Null
$TitleStorePath = Join-Path $tmp 'titles.json'
$script:TitleStore = @{}

function NewSession([string]$name, [int]$minutesAgo, [string]$query) {
    $d = Join-Path $tmp $name
    New-Item -ItemType Directory -Force -Path $d | Out-Null
    $ev = Join-Path $d 'events.jsonl'
    $ts = [datetime]::UtcNow.AddMinutes(-$minutesAgo).ToString('o')
    Set-Content -Path $ev -Encoding UTF8 -Value ('{{"type":"user.message","data":{{"content":"hi"}},"timestamp":"{0}"}}' -f $ts)
    return [pscustomobject]@{
        Dir = $d; Events = $ev; ChatTitle = $null; Query = $query
        LastEventUtc = [datetime]::UtcNow.AddMinutes(-$minutesAgo)
    }
}
function Row([string]$title, [string]$when) { [pscustomobject]@{ Title = $title; When = $when } }

$script:Pass = 0
$script:Fail = 0
function Same($n, $got, $want) {
    $g = if ($null -eq $got) { '<null>' } else { [string]$got }
    $w = if ($null -eq $want) { '<null>' } else { [string]$want }
    if ($g -eq $w) { $script:Pass++; Write-Host ("  ok   {0,-44} -> {1}" -f $n, $g) }
    else { $script:Fail++; Write-Host ("  FAIL {0,-44} -> {1}  expected {2}" -f $n, $g, $w) }
}

try {
    # --- someone is looking: do not touch the sidebar at all ---------------
    Write-Host "a Scout window is in front"
    $Sessions = [ordered]@{}
    $a = NewSession 'sess-a' 1 'scout companion'
    $Sessions[$a.Dir] = $a
    $script:Unobserved = $false
    $script:Answers = @(, @( (Row 'Scout Companion' 'Just now') ))
    Same 'reports it learned nothing'           (Update-SessionTitles) $false
    Same 'and never opened the search'          $script:Searches.Count 0
    Same 'so the session stays unnamed'         $a.ChatTitle $null
    # Being watched says nothing about whether there is a title to find, so it
    # must not read as a fruitless look - that is what stopped this ever
    # learning anything while the app was in use.
    Same 'and it does not count as a look'      $script:ChatScanLooked $false

    # --- nobody is looking: search, match, learn, persist ------------------
    Write-Host "`nno Scout window in front"
    $script:Unobserved = $true
    Same 'learns the row that matches'          (Update-SessionTitles) $true
    Same "the title is Scout's own"             $a.ChatTitle 'Scout Companion'
    Same 'it searched once'                     $script:Searches.Count 1
    Same 'for what the session is about'        $script:Searches[0][0] 'scout companion'
    Same 'and persisted it'                     (Test-Path $TitleStorePath) $true
    $onDisk = Get-Content $TitleStorePath -Raw | ConvertFrom-Json
    Same 'the store holds the same title'       $onDisk.$($a.Dir) 'Scout Companion'

    # --- a named session is not searched for again -------------------------
    $script:Searches = @()
    Same 'nothing left to learn'                (Update-SessionTitles) $false
    Same 'so it does not search again'          $script:Searches.Count 0

    # --- a restart reads it back -------------------------------------------
    $script:TitleStore = @{}
    Import-TitleStore
    Same 'a fresh run loads it again'           $script:TitleStore[$a.Dir] 'Scout Companion'

    # --- a session whose folder is gone is pruned --------------------------
    $script:TitleStore['C:\gone\forever'] = 'Ghost'
    Save-TitleStore
    $script:TitleStore = @{}
    Import-TitleStore
    Same 'a vanished session is dropped'        $script:TitleStore['C:\gone\forever'] $null
    Same 'the surviving one is kept'            $script:TitleStore[$a.Dir] 'Scout Companion'

    # --- rows without timestamps teach nothing -----------------------------
    Write-Host "`nsearch returned rows with no timestamps"
    $b = NewSession 'sess-b' 1 'invoice export'
    $Sessions = [ordered]@{}
    $Sessions[$b.Dir] = $b
    $script:Answers = @(, @( (Row 'AI Governance v1.5' $null), (Row 'Team 1on1' $null) ))
    Same 'unmatchable rows are ignored'         (Update-SessionTitles) $false
    Same 'and name nobody'                      $b.ChatTitle $null
    Same 'but it did look, so back off'         $script:ChatScanLooked $true

    # --- two sessions, one plausible row -----------------------------------
    Write-Host "`ntwo sessions land on the same row"
    $c = NewSession 'sess-c' 1 'rob automation'
    $d = NewSession 'sess-d' 1 'rob automation too'
    $Sessions = [ordered]@{}
    $Sessions[$c.Dir] = $c
    $Sessions[$d.Dir] = $d
    $script:Answers = @( @( (Row 'RoB Automation' 'Just now') ), @( (Row 'RoB Automation' 'Just now') ) )
    Same 'the clash is refused'                 (Update-SessionTitles) $false
    Same 'neither is named (c)'                 $c.ChatTitle $null
    Same 'neither is named (d)'                 $d.ChatTitle $null

    # --- each session gets its own query -----------------------------------
    Write-Host "`ntwo sessions, two different chats"
    $script:Searches = @()
    $e = NewSession 'sess-e' 1   'expense'
    $f = NewSession 'sess-f' 400 'governance'
    $Sessions = [ordered]@{}
    $Sessions[$e.Dir] = $e
    $Sessions[$f.Dir] = $f
    $script:Answers = @(
        @( (Row 'Expense' 'Just now'), (Row 'AI Governance v1.5' '7h ago') ),
        @( (Row 'Expense' 'Just now'), (Row 'AI Governance v1.5' '7h ago') )
    )
    Same 'both are named'                       (Update-SessionTitles) $true
    Same 'the fresh session gets the fresh row' $e.ChatTitle 'Expense'
    Same 'the old session gets the old row'     $f.ChatTitle 'AI Governance v1.5'
    Same 'one visit, both queries'              $script:Searches.Count 1
    Same '  query 1'                            $script:Searches[0][0] 'expense'
    Same '  query 2'                            $script:Searches[0][1] 'governance'
} finally {
    Remove-Item $tmp -Recurse -Force -ErrorAction SilentlyContinue
}

Write-Host ("`n{0} passed, {1} failed" -f $script:Pass, $script:Fail)
if ($script:Fail -gt 0) { exit 1 }
