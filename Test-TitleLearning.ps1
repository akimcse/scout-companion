# Covers how a session comes to be called by Scout's own name for its chat:
# the match, the refusal to guess, and the store that keeps a learned title
# from evaporating.
#
# Drives the real Update-SessionTitles end to end by standing in for the one
# thing that cannot be staged here - what a sidebar happens to be showing.
#
#   powershell -NoProfile -ExecutionPolicy Bypass -File Test-TitleLearning.ps1
$src = Join-Path $PSScriptRoot 'scout-companion.ps1'
if (-not (Test-Path $src)) { Write-Host "scout-companion.ps1 not found next to this script"; exit 1 }

# Lifted out of the app, not copied, so the test cannot drift from the code.
$ast = [System.Management.Automation.Language.Parser]::ParseFile($src, [ref]$null, [ref]$null)
$funcs = $ast.FindAll({ param($n) $n -is [System.Management.Automation.Language.FunctionDefinitionAst] }, $true)
foreach ($n in @('ConvertTo-AgeMinutes','Select-ChatRow','Select-TitleAssignments',
                 'Get-LastMessageUtc','Import-TitleStore','Save-TitleStore',
                 'Set-LearnedTitle','Update-SessionTitles')) {
    $f = $funcs | Where-Object { $_.Name -eq $n } | Select-Object -First 1
    if (-not $f) { Write-Host "MISSING $n"; exit 1 }
    Invoke-Expression $f.Extent.Text
}
function Resolve-SessionLabels { }

$tmp = Join-Path ([System.IO.Path]::GetTempPath()) ("titletest-{0}" -f ([guid]::NewGuid().ToString('N')))
New-Item -ItemType Directory -Force -Path $tmp | Out-Null
$TitleStorePath = Join-Path $tmp 'titles.json'
$script:TitleStore = @{}

function NewSession([string]$name, [int]$minutesAgo) {
    $d = Join-Path $tmp $name
    New-Item -ItemType Directory -Force -Path $d | Out-Null
    $ev = Join-Path $d 'events.jsonl'
    $ts = [datetime]::UtcNow.AddMinutes(-$minutesAgo).ToString('o')
    Set-Content -Path $ev -Encoding UTF8 -Value ('{{"type":"user.message","data":{{"content":"hi"}},"timestamp":"{0}"}}' -f $ts)
    return [pscustomobject]@{ Dir = $d; Events = $ev; ChatTitle = $null }
}
function Row([string]$title, [string]$when) { [pscustomobject]@{ Title = $title; When = $when } }

$pass = 0; $fail = 0
function Same($n, $got, $want) {
    $g = if ($null -eq $got) { '<null>' } else { [string]$got }
    $w = if ($null -eq $want) { '<null>' } else { [string]$want }
    if ($g -eq $w) { $script:pass++; Write-Host ("  ok   {0,-44} -> {1}" -f $n, $g) }
    else { $script:fail++; Write-Host ("  FAIL {0,-44} -> {1}  expected {2}" -f $n, $g, $w) }
}

# --- a sidebar with no timestamps teaches nothing -------------------------
$Sessions = [ordered]@{}
$a = NewSession 'sess-a' 1
$Sessions[$a.Dir] = $a
function Read-VisibleChatRows { return @(, @( (Row 'AI Governance v1.5' $null), (Row 'Team 1on1' $null) )) }
Update-SessionTitles
Write-Host "sidebar open, search closed"
Same 'titles without a timestamp are ignored' $a.ChatTitle $null
Same 'and nothing is written to the store'    (Test-Path $TitleStorePath) $false

# --- with timestamps, the right row is learned and persisted --------------
function Read-VisibleChatRows { return @(, @( (Row 'Scout Companion' 'Just now'), (Row 'AI Governance v1.5' '6d ago') )) }
Update-SessionTitles
Write-Host "`nsidebar open, search open"
Same 'learns the row that matches the session' $a.ChatTitle 'Scout Companion'
Same 'and persists it'                         (Test-Path $TitleStorePath) $true
$onDisk = Get-Content $TitleStorePath -Raw | ConvertFrom-Json
Same 'the store holds the same title'          $onDisk.$($a.Dir) 'Scout Companion'

# --- a restart reads it back ----------------------------------------------
$script:TitleStore = @{}
Import-TitleStore
Same 'a fresh run loads it again'              $script:TitleStore[$a.Dir] 'Scout Companion'

# --- a session whose folder is gone is pruned -----------------------------
$script:TitleStore['C:\gone\forever'] = 'Ghost'
Save-TitleStore
$script:TitleStore = @{}
Import-TitleStore
Same 'a vanished session is dropped on load'   $script:TitleStore['C:\gone\forever'] $null
Same 'the surviving one is kept'               $script:TitleStore[$a.Dir] 'Scout Companion'

# --- two sessions of the same age name nobody -----------------------------
$b = NewSession 'sess-b' 1
$c = NewSession 'sess-c' 1
$Sessions = [ordered]@{}
$Sessions[$b.Dir] = $b
$Sessions[$c.Dir] = $c
function Read-VisibleChatRows { return @(, @( (Row 'RoB Automation' 'Just now') )) }
Update-SessionTitles
Write-Host "`ntwo sessions, one plausible row"
Same 'neither is named (b)'                    $b.ChatTitle $null
Same 'neither is named (c)'                    $c.ChatTitle $null

Remove-Item $tmp -Recurse -Force -ErrorAction SilentlyContinue
Write-Host ("`n{0} passed, {1} failed" -f $pass, $fail)
if ($fail -gt 0) { exit 1 }
