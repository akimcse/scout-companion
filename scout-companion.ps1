<#
.SYNOPSIS
    Scout Companion - a floating overlay for the Microsoft Scout / OpenClaw desktop agent.

.DESCRIPTION
    Shows a small always-on-top toast in the corner of your screen whenever the agent
    is working in the background (window minimized or not focused). It streams the
    agent's live progress as readable steps, shows a cheerful animated quokka mascot
    that works hard while the agent is busy, and - when the agent asks for a permission
    ("Allow") - lets you approve or deny it with a single click, without switching back
    to the agent window.

    The app discovers everything at runtime. It hardcodes no user data:
      - the agent home folder defaults to %USERPROFILE%\.copilot
      - the active session is auto-detected from the session-state folder
      - the agent window is auto-detected from the running process list

    Override defaults with a config.json next to this script (see config.sample.json),
    or with the SCOUT_COMPANION_HOME environment variable.

.NOTES
    Unofficial, community project. Not affiliated with or endorsed by Microsoft.
    MIT licensed. Requires Windows + PowerShell 5+ (run with -STA).
#>

#Requires -Version 5.0

Add-Type -AssemblyName PresentationFramework
Add-Type -AssemblyName PresentationCore
Add-Type -AssemblyName WindowsBase
Add-Type -AssemblyName UIAutomationClient
Add-Type -AssemblyName UIAutomationTypes
Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing

# ---------------------------------------------------------------------------
# Native interop: foreground/minimize detection, focus, and a11y wake.
# ---------------------------------------------------------------------------
if (-not ('ScoutNative' -as [type])) {
    Add-Type -Namespace '' -Name 'ScoutNative' -MemberDefinition @'
        [System.Runtime.InteropServices.DllImport("user32.dll")]
        public static extern System.IntPtr GetForegroundWindow();

        [System.Runtime.InteropServices.DllImport("user32.dll")]
        public static extern bool IsIconic(System.IntPtr hWnd);

        [System.Runtime.InteropServices.DllImport("user32.dll")]
        public static extern bool IsWindow(System.IntPtr hWnd);

        [System.Runtime.InteropServices.DllImport("user32.dll")]
        public static extern bool SetForegroundWindow(System.IntPtr hWnd);

        [System.Runtime.InteropServices.DllImport("user32.dll")]
        public static extern bool ShowWindow(System.IntPtr hWnd, int nCmdShow);

        [System.Runtime.InteropServices.DllImport("user32.dll")]
        public static extern System.IntPtr SendMessage(System.IntPtr hWnd, uint Msg, System.IntPtr wParam, System.IntPtr lParam);

        [System.Runtime.InteropServices.DllImport("user32.dll")]
        public static extern bool DestroyIcon(System.IntPtr hIcon);

        [System.Runtime.InteropServices.DllImport("dwmapi.dll")]
        public static extern int DwmSetWindowAttribute(System.IntPtr hwnd, int attr, ref int value, int size);

        // Electron keeps several top-level windows inside one process, and
        // Process.MainWindowHandle only ever names one of them. Counting
        // processes therefore says "one window" while two are on screen, which
        // is exactly the case the Allow/Deny guard exists to catch.
        public delegate bool EnumProc(System.IntPtr hWnd, System.IntPtr lParam);

        [System.Runtime.InteropServices.DllImport("user32.dll")]
        public static extern bool EnumWindows(EnumProc cb, System.IntPtr lParam);

        [System.Runtime.InteropServices.DllImport("user32.dll")]
        public static extern bool IsWindowVisible(System.IntPtr hWnd);

        [System.Runtime.InteropServices.DllImport("user32.dll")]
        public static extern int GetWindowTextLength(System.IntPtr hWnd);

        [System.Runtime.InteropServices.DllImport("user32.dll")]
        public static extern uint GetWindowThreadProcessId(System.IntPtr hWnd, out uint pid);

        public static System.Collections.Generic.List<System.IntPtr> TopLevelWindows(
                System.Collections.Generic.HashSet<uint> pids) {
            var found = new System.Collections.Generic.List<System.IntPtr>();
            EnumWindows(delegate (System.IntPtr h, System.IntPtr l) {
                if (!IsWindowVisible(h)) return true;
                if (GetWindowTextLength(h) == 0) return true;
                uint owner;
                GetWindowThreadProcessId(h, out owner);
                if (pids.Contains(owner)) found.Add(h);
                return true;
            }, System.IntPtr.Zero);
            return found;
        }
'@
}

# ---------------------------------------------------------------------------
# Configuration (with sane defaults; overridable via config.json or env var).
# ---------------------------------------------------------------------------
$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path

$Config = [ordered]@{
    home          = $null
    processNames  = @('scout', 'Microsoft Scout', 'OpenClaw', 'Clawpilot', 'Claw')
    windowHints   = @('Microsoft Scout', 'Clawpilot', 'OpenClaw')
    # Browser processes are excluded from window-title matching so a browser tab
    # whose title happens to contain a hint (e.g. an Edge tab named "Scout, ...")
    # is never mistaken for the agent window.
    browserProcs  = @('msedge', 'chrome', 'firefox', 'brave', 'opera', 'iexplore', 'vivaldi')
    # Order matters: first match is clicked, so the safest one-time "Allow" wins.
    allowLabels   = @('Allow', 'Allow for session', 'Allow everywhere', 'Always allow', 'Allow once', 'Approve', 'Accept', 'Continue', 'Yes')
    denyLabels    = @('Deny', 'Reject', 'Decline', 'Block', 'Cancel', 'No')
    # External tools that mean "the agent is waiting for you to answer something".
    # These block the turn exactly like an approval does, but the companion cannot
    # answer them for you - it can only tell you they are waiting.
    askToolNames  = @('m_ask_user', 'ask_user')
    activeWindowSeconds = 150
    pollIntervalMs      = 700
    # How many concurrently active sessions to follow. Each one costs a file
    # stat per tick, so this is a guard against pathological session counts
    # rather than a limit anyone should hit.
    maxSessions         = 6
    # A full rescan of every session folder is expensive on machines with a long
    # session history, so the resolved session is cached and only re-resolved
    # this often. Between rescans the companion just stats the file it is tailing.
    sessionRescanMs     = 5000
    # Mascot frame interval. 80 ms (12.5 fps) is smooth enough for a bob and a
    # typing paw, and costs roughly half of the old 50 ms (20 fps).
    animIntervalMs      = 80
    # Mascot animation can be switched off entirely from the tray or settings.
    animationEnabled    = $true
    # Toast opacity, 0.35 to 1.0. Floored deliberately: a toast faded to nothing
    # is one you cannot find again to turn back up.
    opacity             = 1.0
    # Which mascot the toast shows. See $Mascots for the available ids.
    mascot              = 'quokka'
    # UI language. 'auto' follows the Windows display language; set a tag from
    # lang/ (e.g. 'ko', 'ja', 'pt-BR') to pin it. Windows keeps display language
    # and regional format separate, so auto-detection is right for most people
    # but wrong for anyone running, say, an English UI with Korean formats.
    language            = 'auto'
    maxSteps            = 4
    # Open, Answer and the tray try to land on the chat that raised the prompt
    # rather than just whatever Scout was last showing. Turn this off to get the
    # older behaviour of only bringing the window forward.
    openMatchingSession = $true
    # Show the toast for a moment at startup, whatever the rules would say.
    # Launching the companion otherwise produces no visible sign that it worked:
    # the toast hides while Scout has focus - which it does, because you just
    # launched something - and Windows files a new tray icon into the hidden
    # overflow flyout. Set to 0 to start silently.
    startupGreetingSeconds = 5
    exitWhenAgentGone   = $true
    exitGraceSeconds    = 30
}

$cfgPath = Join-Path $ScriptDir 'config.json'
if (Test-Path $cfgPath) {
    try {
        $userCfg = Get-Content $cfgPath -Raw | ConvertFrom-Json
        foreach ($k in $Config.Keys.Clone()) {
            if ($null -ne $userCfg.$k) { $Config[$k] = $userCfg.$k }
        }
    } catch {
        Write-Warning "Could not parse config.json: $($_.Exception.Message)"
    }
}

# ---------------------------------------------------------------------------
# Language.
#
# English lives in the script and every other language is a file in lang/, so a
# missing or malformed translation degrades to English instead of breaking the
# app, and a translator only has to touch one JSON file. Any key absent from a
# translation falls back to English individually, which means a partial
# translation is useful immediately rather than all-or-nothing.
#
# Detection reads CurrentUICulture and walks its parent chain: zh-CN resolves to
# zh-Hans, pt-BR to pt-BR then pt, and so on. It is deliberately overridable,
# because UI language and regional format are independent settings in Windows
# and the machine this was written on runs an English UI with Korean formats --
# guessing from either one alone would be wrong half the time.
# ---------------------------------------------------------------------------
$script:Strings = @{}

function Import-Language([string]$pref) {
    $dir = Join-Path $ScriptDir 'lang'
    if (-not (Test-Path $dir)) { return 'en' }

    $order = @()
    if ($pref -and $pref -ne 'auto') {
        $order += $pref
    } else {
        $ci = [System.Globalization.CultureInfo]::CurrentUICulture
        while ($ci -and $ci.Name) { $order += $ci.Name; $ci = $ci.Parent }
    }

    foreach ($tag in $order) {
        $file = Join-Path $dir "$tag.json"
        if (-not (Test-Path $file)) { continue }
        try {
            $json = Get-Content $file -Raw -Encoding UTF8 | ConvertFrom-Json
            $map = @{}
            foreach ($p in $json.PSObject.Properties) {
                # Keys starting with _ are notes for translators, not strings.
                if ($p.Name -notlike '_*') { $map[$p.Name] = [string]$p.Value }
            }
            $script:Strings = $map
            return $tag
        } catch {
            Write-Warning "Could not parse lang/$tag.json, falling back to English: $($_.Exception.Message)"
        }
    }
    return 'en'
}

# T for "translate". Takes the English string as the key, so the script stays
# readable and an untranslated build is still correct English. Optional -f
# arguments are applied after lookup, because word order differs between
# languages and the translation has to own the whole sentence.
function T([string]$key) {
    $s = $script:Strings[$key]
    if (-not $s) { $s = $key }
    if ($args.Count -gt 0) {
        try { return [string]::Format($s, $args) } catch { return $s }
    }
    return $s
}

# Translates the user-facing attributes of a XAML document in place. Doing it
# here rather than interpolating T into the markup keeps the XAML a plain
# single-quoted here-string, and means a string added to the markup later is
# picked up automatically instead of being quietly left in English.
#
# Only Text, Content, ToolTip and Title are touched, and bindings, glyph escapes
# and pure format placeholders are skipped -- translating "{TemplateBinding
# SelectionBoxItem}" would break the control it belongs to.
function Convert-XamlText([xml]$doc) {
    if ($script:Strings.Count -eq 0) { return $doc }
    $attrs = 'Text', 'Content', 'ToolTip', 'Title'
    foreach ($node in $doc.SelectNodes('//*')) {
        foreach ($a in $attrs) {
            $v = $node.GetAttribute($a)
            if (-not $v) { continue }
            if ($v -match '^\{' -or $v -match '^&#x' -or $v -match '^\s*$') { continue }
            $t = $script:Strings[$v]
            if ($t) { $node.SetAttribute($a, $t) }
        }
    }
    return $doc
}

$script:Lang = Import-Language $Config.language

# Writes a subset of settings back to config.json, preserving anything the user
# put there by hand. Used by the settings window and the tray menu.
function Save-Setting([hashtable]$changes) {
    $merged = [ordered]@{}
    if (Test-Path $cfgPath) {
        try {
            $existing = Get-Content $cfgPath -Raw | ConvertFrom-Json
            foreach ($prop in $existing.PSObject.Properties) { $merged[$prop.Name] = $prop.Value }
        } catch { }
    }
    foreach ($key in $changes.Keys) {
        $merged[$key] = $changes[$key]
        $Config[$key] = $changes[$key]
    }
    try {
        ($merged | ConvertTo-Json -Depth 6) | Set-Content -Path $cfgPath -Encoding UTF8
        return $true
    } catch {
        Write-Warning "Could not write config.json: $($_.Exception.Message)"
        return $false
    }
}

# The opacity slider coalesces its writes behind a timer, so any path that ends
# the process or closes the settings window has to drain it first. Without this
# a value set in the last 600 ms before quitting was lost, which reads to the
# user as "settings don't save at all".
$script:OpacitySaveTimer = $null
$script:OpacityPendingValue = $null
function Save-PendingOpacity {
    if (-not $script:OpacitySaveTimer) { return }
    if (-not $script:OpacitySaveTimer.IsEnabled) { return }
    $script:OpacitySaveTimer.Stop()
    if ($null -ne $script:OpacityPendingValue) {
        [void](Save-Setting @{ opacity = $script:OpacityPendingValue })
    }
}

if ($env:SCOUT_COMPANION_HOME) { $Config.home = $env:SCOUT_COMPANION_HOME }

# Auto-detect the agent home. Different Scout/Clawpilot builds store their session
# state in different roots (newer builds use %USERPROFILE%\.scout\copilot, older
# ones used %USERPROFILE%\.copilot). If home isn't pinned via config/env, pick the
# candidate whose session-state has the most recently written events.jsonl so we
# always follow the build the user is actually running.
if (-not $Config.home) {
    $candidates = @(
        (Join-Path $env:USERPROFILE '.scout\copilot'),
        (Join-Path $env:USERPROFILE '.copilot')
    )
    $best = $null; $bestTime = [datetime]::MinValue
    foreach ($c in $candidates) {
        $sr = Join-Path $c 'session-state'
        if (-not (Test-Path $sr)) { continue }
        $newest = Get-ChildItem $sr -Directory -ErrorAction SilentlyContinue |
            ForEach-Object { Join-Path $_.FullName 'events.jsonl' } |
            Where-Object { Test-Path $_ } |
            ForEach-Object { (Get-Item $_).LastWriteTimeUtc } |
            Sort-Object -Descending | Select-Object -First 1
        if ($newest -and $newest -gt $bestTime) { $bestTime = $newest; $best = $c }
    }
    if ($best) { $Config.home = $best }
    elseif (Test-Path (Join-Path $env:USERPROFILE '.scout\copilot')) { $Config.home = Join-Path $env:USERPROFILE '.scout\copilot' }
    else { $Config.home = Join-Path $env:USERPROFILE '.copilot' }
}

$SessionRoot = Join-Path $Config.home 'session-state'

# ---------------------------------------------------------------------------
# Shared mutable state.
#
# $Sessions holds one record per session being followed. $State is the view the
# UI renders: steps and narration from whichever session moved most recently,
# and approvals and questions merged from all of them, because the whole point
# of following several is that a prompt in a window you are not looking at
# still reaches you.
# ---------------------------------------------------------------------------
$Sessions = [ordered]@{}

function New-SessionRecord([string]$dir, [string]$events) {
    [pscustomobject]@{
        Dir          = $dir
        Events       = $events
        Label        = $null
        BaseLabel    = $null
        Topic        = $null
        Subject      = $null      # the latest thing asked for, used as a title
        ChatTitle    = $null      # Scout's own name for this chat, once learnt
        Offset       = [long]0
        Saying       = $null
        Steps        = New-Object System.Collections.ArrayList
        TurnActive   = $false
        LastEventUtc = [datetime]::UtcNow
        PendingPerms = [ordered]@{}
        PendingAsks  = [ordered]@{}
    }
}

$State = [pscustomobject]@{
    SessionDir      = $null
    EventsPath      = $null
    Saying          = $null                       # latest assistant narrative
    Steps           = New-Object System.Collections.ArrayList   # recent tool steps
    TurnActive      = $false
    LastEventUtc    = [datetime]::MinValue
    PendingPerms    = [ordered]@{}
    PendingAsks     = [ordered]@{}                # questions waiting on the user
    AgentHwnd       = [IntPtr]::Zero
}

# Caches that keep the poll loop off the expensive code paths.
$script:WinCache          = $null                  # last known agent window
$script:LastTitleScanUtc  = [datetime]::MinValue   # throttle for the full process scan
$script:SessionScanUtc    = [datetime]::MinValue   # throttle for the full session scan
$script:StepSignature     = $null                  # last rendered step list

# ---------------------------------------------------------------------------
# Helpers.
# ---------------------------------------------------------------------------
function Truncate([string]$s, [int]$n) {
    if ($null -eq $s) { return '' }
    $s = $s -replace '\s+', ' '
    $s = $s.Trim()
    if ($s.Length -le $n) { return $s }
    return $s.Substring(0, $n).TrimEnd() + '...'
}

function Leaf([string]$p) {
    if (-not $p) { return '' }
    try { return Split-Path $p -Leaf } catch { return $p }
}

function Describe-Tool([string]$name, $a) {
    # Turn a tool call into a short, human-readable action.
    #
    # Labels with a value in them go through T with a {0} placeholder rather than
    # being built by interpolation, because word order is not universal: the file
    # name comes after the verb in English and before it in Korean and Japanese,
    # so the translation has to own the whole sentence.
    if (-not $name) { return T 'Working' }
    switch -Regex ($name) {
        '^report_intent$'              { if ($a.intent) { return [string]$a.intent } ; return T 'Planning' }
        '^(powershell|bash|shell|run_command)$' {
            $c = $a.command; if (-not $c) { $c = $a.script }
            if ($c) { $first = ($c -split "`n" | Where-Object { $_.Trim() } | Select-Object -First 1)
                      return T 'Running: {0}' (Truncate $first 64) }
            return T 'Running a command'
        }
        '^view$'                       { return T 'Reading {0}' (Leaf $a.path) }
        '^edit$'                       { return T 'Editing {0}' (Leaf $a.path) }
        '^create$'                     { return T 'Creating {0}' (Leaf $a.path) }
        '^grep$'                       { return T 'Searching "{0}"' (Truncate $a.pattern 40) }
        '^glob$'                       { return T 'Finding files: {0}' (Truncate $a.pattern 40) }
        '^task$'                       { if ($a.description) { return T 'Delegating: {0}' (Truncate $a.description 50) } ; return T 'Delegating a subtask' }
        '^web_fetch$'                  { return T 'Fetching {0}' (Truncate $a.url 50) }
        '^web_search$'                 { return T 'Web search: {0}' (Truncate $a.query 44) }
        '^m_filesystem_(list|tree)$'   { return T 'Listing {0}' (Leaf $a.path) }
        '^m_filesystem_stat$'          { return T 'Checking {0}' (Leaf $a.path) }
        '^m_filesystem_mkdir$'         { return T 'New folder {0}' (Leaf $a.path) }
        '^m_filesystem_move$'          { return T 'Moving {0}' (Leaf $a.source) }
        '^sql$'                        { if ($a.description) { return T 'DB: {0}' (Truncate $a.description 46) } ; return T 'Querying database' }
        '^workiq_list_emails$'         { return T 'Checking emails' }
        '^workiq_(search_emails|get_email)$' { return T 'Email: {0}' (Truncate $a.query 40) }
        '^workiq_(send_email|reply_to_email|create_draft).*' { return T 'Composing email' }
        '^workiq_.*chat.*'             { return T 'Teams chat' }
        '^workiq_.*event.*'            { return T 'Calendar' }
        '^workiq_.*(people|profile|manager).*' { return T 'Looking up people' }
        '^workiq_.*file.*'             { return T 'OneDrive files' }
        '^m_remember$'                 { return T 'Saving a memory' }
        '^m_recall$'                   { return T 'Recalling memory' }
        '^skill$'                      { if ($a.skill) { return T 'Skill: {0}' $a.skill } ; return T 'Using a skill' }
        '^browser_'                    { return T 'Browsing the web' }
        default                        { return (($name -replace '^m_','') -replace '_',' ') }
    }
}

function Add-Step($sess, [string]$id, [string]$reqId, [string]$text) {
    if (-not $text) { return }
    $rec = [pscustomobject]@{ Id = $id; ReqId = $reqId; Text = $text; Done = $false }
    [void]$sess.Steps.Add($rec)
    while ($sess.Steps.Count -gt [int]$Config.maxSteps) { $sess.Steps.RemoveAt(0) }
}

function Complete-Step($sess, [string]$id, [string]$reqId) {
    for ($i = $sess.Steps.Count - 1; $i -ge 0; $i--) {
        $s = $sess.Steps[$i]
        if (($id -and $s.Id -eq $id) -or ($reqId -and $s.ReqId -eq $reqId)) { $s.Done = $true; break }
    }
}

function Get-AgentWindow {
    # Fast path: the handle found last time is almost always still valid, so a
    # cheap IsWindow check replaces a full process enumeration on most ticks.
    if ($script:WinCache -and [ScoutNative]::IsWindow($script:WinCache.Hwnd)) {
        # One process, several windows. If the window in front belongs to the
        # same process, that is the one the user is looking at, and holding on
        # to a stale sibling would make the toast think the agent is in the
        # background while it is filling the screen.
        $fg = [ScoutNative]::GetForegroundWindow()
        if ($fg -ne [IntPtr]::Zero -and $fg -ne $script:WinCache.Hwnd) {
            $owner = [uint32]0
            [void][ScoutNative]::GetWindowThreadProcessId($fg, [ref]$owner)
            if ($owner -eq [uint32]$script:WinCache.Pid) {
                $script:WinCache = @{ Hwnd = $fg; Pid = [int]$owner }
            }
        }
        return $script:WinCache
    }
    $script:WinCache = $null

    # 1) Match by process name first (most reliable - a browser tab can't spoof this).
    #    GetProcessesByName asks the OS for one name instead of materialising a
    #    Process object for every process on the machine.
    foreach ($name in $Config.processNames) {
        $ps = $null
        try { $ps = [System.Diagnostics.Process]::GetProcessesByName($name) } catch { continue }
        try {
            foreach ($p in $ps) {
                if ($p.MainWindowHandle -ne [IntPtr]::Zero) {
                    $script:WinCache = @{ Hwnd = $p.MainWindowHandle; Pid = $p.Id }
                    return $script:WinCache
                }
            }
        } finally { foreach ($p in $ps) { $p.Dispose() } }
    }

    # 2) Fall back to window-title hints. This one does need a full enumeration,
    #    so it is throttled - it only runs while no agent process is found at all.
    $sinceScan = ([datetime]::UtcNow - $script:LastTitleScanUtc).TotalMilliseconds
    if ($sinceScan -lt 3000) { return $null }
    $script:LastTitleScanUtc = [datetime]::UtcNow

    $procs = Get-Process | Where-Object { $_.MainWindowHandle -ne 0 -and $_.MainWindowTitle }
    #    Substring match on the process name first, so a partial name in
    #    config.json (e.g. "Claw" for "Clawpilot") keeps working.
    foreach ($name in $Config.processNames) {
        $p = $procs | Where-Object { $_.ProcessName -like "*$name*" } | Select-Object -First 1
        if ($p) {
            $script:WinCache = @{ Hwnd = $p.MainWindowHandle; Pid = $p.Id }
            return $script:WinCache
        }
    }
    #    Skip browser processes so a tab titled "Scout, ..." is never picked
    #    instead of the real app window.
    $nonBrowser = $procs | Where-Object { $_.ProcessName -notin $Config.browserProcs }
    foreach ($hint in $Config.windowHints) {
        $p = $nonBrowser | Where-Object { $_.MainWindowTitle -like "*$hint*" } | Select-Object -First 1
        if ($p) {
            $script:WinCache = @{ Hwnd = $p.MainWindowHandle; Pid = $p.Id }
            return $script:WinCache
        }
    }
    return $null
}

# Lightweight presence check (process only, no window). Used to decide when Scout
# has fully closed so the companion can shut itself down.
function Test-AgentProcess {
    foreach ($name in $Config.processNames) {
        $ps = $null
        try { $ps = [System.Diagnostics.Process]::GetProcessesByName($name) } catch { continue }
        try { if ($ps.Count -gt 0) { return $true } }
        finally { foreach ($p in $ps) { $p.Dispose() } }
    }
    # GetProcessesByName matches whole names, so fall back to a substring scan to
    # keep partial names in config.json working. This only runs when the agent
    # already looks gone, i.e. right before the companion would shut itself down.
    $all = Get-Process -ErrorAction SilentlyContinue
    foreach ($name in $Config.processNames) {
        if ($all | Where-Object { $_.ProcessName -like "*$name*" } | Select-Object -First 1) { return $true }
    }
    return $false
}

function Find-ActiveSessions {
    # Sessions that have actually been written to recently, newest first.
    #
    # Deliberately not keyed on the lock files. One backend process holds
    # inuse.<pid>.lock on every session it still has open, so on this machine
    # ten folders looked "live" while only two had seen an event in the last
    # hour. A live lock means a process still has the session open, not that
    # anyone is using it.
    #
    # It is not kept as a tiebreak either: mtime has 100 ns resolution, so two
    # sessions never tie in practice and the lock check would be dead weight on
    # every scan.
    if (-not [System.IO.Directory]::Exists($SessionRoot)) { return @() }

    $cutoff = [datetime]::UtcNow.AddSeconds(-[double]$Config.activeWindowSeconds)
    $candidates = New-Object System.Collections.ArrayList
    foreach ($dir in [System.IO.Directory]::EnumerateDirectories($SessionRoot)) {
        $ev = [System.IO.Path]::Combine($dir, 'events.jsonl')
        $fi = New-Object System.IO.FileInfo $ev
        if (-not $fi.Exists) { continue }
        [void]$candidates.Add([pscustomobject]@{ Dir = $dir; Events = $ev; Mtime = $fi.LastWriteTimeUtc })
    }
    if ($candidates.Count -eq 0) { return @() }

    $sorted = @($candidates | Sort-Object -Property Mtime -Descending)
    $fresh  = @($sorted | Where-Object { $_.Mtime -ge $cutoff })
    # Nothing recent: fall back to the single newest so the companion still has
    # something to show rather than going blank.
    if ($fresh.Count -eq 0) { $fresh = @($sorted[0]) }
    if ($fresh.Count -gt [int]$Config.maxSessions) {
        $fresh = @($fresh | Select-Object -First ([int]$Config.maxSessions))
    }
    return $fresh
}

function Get-SessionLabel([string]$dir, [string]$events) {
    # session.start is the first line of the file and carries the working
    # directory, which is the only human-readable handle on a session - the
    # folder name is a GUID. Read the head only; these files reach tens of MB.
    try {
        $fs = [System.IO.File]::Open($events, 'Open', 'Read', 'ReadWrite')
        try {
            $sr = New-Object System.IO.StreamReader($fs)
            for ($i = 0; $i -lt 5; $i++) {
                $line = $sr.ReadLine()
                if ($null -eq $line) { break }
                if ($line -notmatch '"session\.start"') { continue }
                $cwd = ($line | ConvertFrom-Json).data.context.cwd
                if ($cwd) { return (Split-Path $cwd -Leaf) }
            }
        } finally { $fs.Dispose() }
    } catch { }
    return (Split-Path $dir -Leaf).Substring(0, 8)
}

function Get-SessionTopic([string]$events) {
    # First thing the user actually asked for, used to tell apart two sessions
    # in the same folder - which is the normal case when you open a second
    # window on the same project.
    #
    # Only called when a collision exists, because it scans until it finds a
    # user message rather than reading a fixed head, and that message can sit
    # some way in. Bounded so a session that never got one cannot walk a
    # multi-megabyte file.
    try {
        $fs = [System.IO.File]::Open($events, 'Open', 'Read', 'ReadWrite')
        try {
            $sr = New-Object System.IO.StreamReader($fs)
            for ($i = 0; $i -lt 400; $i++) {
                $line = $sr.ReadLine()
                if ($null -eq $line) { break }
                if ($line -notmatch '"user\.message"') { continue }
                $txt = ($line | ConvertFrom-Json).data.content
                if (-not $txt) { continue }
                # Collapse newlines so a pasted block does not become a wall of
                # text in the panel title.
                $txt = ($txt -replace '\s+', ' ').Trim()
                if ($txt) { return (Truncate $txt 28) }
            }
        } finally { $fs.Dispose() }
    } catch { }
    return $null
}

# The latest thing the user asked this session for. That is what the
# conversation is about right now, and it is what makes a prompt on the toast
# recognisable - far more so than the folder the session runs in, which reads
# the same for every session on the same project.
#
# Taken from the tail rather than the head on purpose: a resumed session opens
# with "carry on", and naming it that would be worse than useless.
function Get-LastUserMessage([string]$events) {
    try {
        $fi = New-Object System.IO.FileInfo $events
        if (-not $fi.Exists) { return $null }
        $len = $fi.Length
        if ($len -le 0) { return $null }
        # A busy session buries the last thing the user said under megabytes of
        # tool output, so the tail is widened a few times before giving up -
        # rather than reading the whole file on a session that never had a
        # message in it at all. Read line by line: splitting sixteen megabytes
        # in one go would cost more memory than the rest of the app uses.
        foreach ($take in @(262144, 2097152, 16777216)) {
            $want = [Math]::Min($len, [long]$take)
            $best = $null
            $fs = [System.IO.File]::Open($events, 'Open', 'Read', 'ReadWrite')
            try {
                $fs.Seek($len - $want, 'Begin') | Out-Null
                $sr = New-Object System.IO.StreamReader($fs)
                while ($null -ne ($line = $sr.ReadLine())) {
                    if ($line -notmatch '"type":"user\.message"') { continue }
                    $o = $null
                    try { $o = $line | ConvertFrom-Json } catch { continue }
                    if ($o.data.content) { $best = $o.data.content }
                }
            } finally { $fs.Dispose() }
            if ($best) { return (Truncate $best 40) }
            if ($want -ge $len) { break }
        }
    } catch { }
    return $null
}

# What the toast calls a session. Scout's own chat title if that has been learnt
# - it only can be once Open has driven the sidebar - otherwise the latest
# request. Returns nothing when neither exists, so the caller falls back to the
# older folder-name rule rather than presenting a folder as a title.
function Get-SessionSubject($rec) {
    if ($rec.ChatTitle) { return $rec.ChatTitle }
    if ($rec.Subject)   { return $rec.Subject }
    return $null
}

function Resolve-SessionLabels {
    # Two windows on the same project produce the same cwd, and a label that
    # cannot tell them apart is worse than no label - it names a session
    # confidently and points at the wrong one. Where that happens, append what
    # each session was asked to do.
    $byLabel = @{}
    foreach ($dir in $Sessions.Keys) {
        $rec = $Sessions[$dir]
        # Scout's own title for the chat needs no disambiguating: it is the name
        # the user reads in the sidebar, and two sessions cannot share a chat.
        if ($rec.ChatTitle) { $rec.Label = $rec.ChatTitle; continue }
        if (-not $byLabel.ContainsKey($rec.BaseLabel)) { $byLabel[$rec.BaseLabel] = New-Object System.Collections.ArrayList }
        [void]$byLabel[$rec.BaseLabel].Add($rec)
    }
    foreach ($label in $byLabel.Keys) {
        $group = $byLabel[$label]
        if ($group.Count -eq 1) { $group[0].Label = $label; continue }
        foreach ($rec in $group) {
            if (-not $rec.Topic) { $rec.Topic = Get-SessionTopic $rec.Events }
            # A session with no user message yet has nothing to name it by, so
            # fall back to the GUID head rather than leaving it wearing the bare
            # cwd - which would read as "the payments-api session" while two
            # others are also payments-api.
            $rec.Label = if ($rec.Topic) { "$label - $($rec.Topic)" }
                         else { "$label - $((Split-Path $rec.Dir -Leaf).Substring(0,6))" }
        }
        # Two sessions can still land on the same text if their first messages
        # start alike and truncate to the same prefix.
        $seen = @{}
        foreach ($rec in $group) {
            if ($seen.ContainsKey($rec.Label)) {
                $rec.Label = "$($rec.BaseLabel) - $((Split-Path $rec.Dir -Leaf).Substring(0,6))"
            }
            $seen[$rec.Label] = $true
        }
    }
}

function Sync-Sessions {
    # Refresh which sessions are being followed. A session with something
    # pending is kept regardless of age: an approval does not expire just
    # because nobody has typed for a while, and dropping it would take the
    # prompt off the toast.
    $active = Find-ActiveSessions
    $keep = @{}
    foreach ($s in $active) { $keep[$s.Dir] = $true }

    foreach ($s in $active) {
        if ($Sessions.Contains($s.Dir)) { continue }
        $rec = New-SessionRecord $s.Dir $s.Events
        $rec.BaseLabel = Get-SessionLabel $s.Dir $s.Events
        $rec.Label     = $rec.BaseLabel
        # Seeded once from the file, then kept current by Handle-Event as the
        # user types. Without the seed a session already underway would have no
        # name until its next message.
        $rec.Subject   = Get-LastUserMessage $s.Events
        # Start at the end: replaying a whole history would re-raise approvals
        # that were answered long ago.
        $rec.Offset = (New-Object System.IO.FileInfo $s.Events).Length
        $rec.LastEventUtc = $s.Mtime
        $Sessions[$s.Dir] = $rec
    }

    foreach ($dir in @($Sessions.Keys)) {
        if ($keep.ContainsKey($dir)) { continue }
        $rec = $Sessions[$dir]
        if ($rec.PendingPerms.Count -gt 0 -or $rec.PendingAsks.Count -gt 0) { continue }
        $Sessions.Remove($dir)
    }

    Resolve-SessionLabels
}

function Read-SessionEvents($rec) {
    $fi = New-Object System.IO.FileInfo $rec.Events
    if (-not $fi.Exists) { return }
    $len = $fi.Length
    if ($len -lt $rec.Offset) { $rec.Offset = 0 }
    if ($len -eq $rec.Offset) { return }

    $fs = [System.IO.File]::Open($rec.Events, 'Open', 'Read', 'ReadWrite')
    try {
        $fs.Seek($rec.Offset, 'Begin') | Out-Null
        $sr = New-Object System.IO.StreamReader($fs)
        $chunk = $sr.ReadToEnd()
        $rec.Offset = $fs.Position
    } finally { $fs.Dispose() }

    foreach ($line in ($chunk -split "`n")) {
        $line = $line.Trim()
        if (-not $line) { continue }
        try { $evt = $line | ConvertFrom-Json } catch { continue }
        Handle-Event $rec $evt
    }
}

function Read-NewEvents {
    # Between full rescans, just tail the sessions already being followed. That
    # turns the common tick into one file stat per session instead of a walk
    # over every session folder on the machine.
    if (([datetime]::UtcNow - $script:SessionScanUtc).TotalMilliseconds -ge [double]$Config.sessionRescanMs -or
        $Sessions.Count -eq 0) {
        $script:SessionScanUtc = [datetime]::UtcNow
        Sync-Sessions
    }
    foreach ($dir in @($Sessions.Keys)) {
        try { Read-SessionEvents $Sessions[$dir] } catch { }
    }
}

# Names the conversation a prompt came from. Always, now that it can say
# something worth reading: Scout's own chat title once Open has taught it one,
# and until then the latest thing that session was asked to do. Only a bare
# folder name stays behind the "more than one session" rule it always had,
# because on its own it says almost nothing.
function Where-From($item) {
    if (-not $item) { return '' }
    if ($item.title) { return "  -  $($item.title)" }
    if ($Sessions.Count -le 1) { return '' }
    if (-not $item.session) { return '' }
    return "  -  $($item.session)"
}

function Merge-SessionState {
    # Collapse the per-session records into the single view the toast renders.
    $primary = $null
    foreach ($dir in $Sessions.Keys) {
        $rec = $Sessions[$dir]
        if (-not $primary -or $rec.LastEventUtc -gt $primary.LastEventUtc) { $primary = $rec }
    }

    $perms = [ordered]@{}
    $asks  = [ordered]@{}
    $turn  = $false
    foreach ($dir in $Sessions.Keys) {
        $rec = $Sessions[$dir]
        if ($rec.TurnActive) { $turn = $true }
        foreach ($k in $rec.PendingPerms.Keys) {
            $v = $rec.PendingPerms[$k]; $v.session = $rec.Label; $v.title = (Get-SessionSubject $rec); $perms[$k] = $v
        }
        foreach ($k in $rec.PendingAsks.Keys) {
            $v = $rec.PendingAsks[$k]; $v.session = $rec.Label; $v.title = (Get-SessionSubject $rec); $asks[$k] = $v
        }
    }

    $State.PendingPerms = $perms
    $State.PendingAsks  = $asks
    $State.TurnActive   = $turn
    if ($primary) {
        $State.SessionDir   = $primary.Dir
        $State.EventsPath   = $primary.Events
        $State.Saying       = $primary.Saying
        $State.Steps        = $primary.Steps
        $State.LastEventUtc = $primary.LastEventUtc
    }
}

function Handle-Event($sess, $evt) {
    $sess.LastEventUtc = [datetime]::UtcNow
    switch ($evt.type) {
        'assistant.turn_start' { $sess.TurnActive = $true }
        'assistant.turn_end'   { $sess.TurnActive = $false }
        'user.message' {
            # Keeps the session's name current as the conversation moves on,
            # without re-reading the file.
            $txt = $evt.data.content
            if ($txt) { $sess.Subject = Truncate $txt 40 }
        }
        'assistant.message' {
            $txt = $evt.data.content; if (-not $txt) { $txt = $evt.data.text }
            if ($txt) { $sess.Saying = Truncate $txt 200 }
        }
        'tool.execution_start' {
            $desc = Describe-Tool $evt.data.toolName $evt.data.arguments
            Add-Step $sess $evt.data.toolCallId $null $desc
        }
        'tool.execution_complete' {
            Complete-Step $sess $evt.data.toolCallId $null
        }
        'external_tool.requested' {
            # An "ask the user" tool is not progress, it is a stop: the turn is
            # parked until someone answers. Surface it like an approval rather
            # than burying it in the step list.
            if ($Config.askToolNames -contains $evt.data.toolName) {
                $q = $evt.data.arguments.question
                if (-not $q) { $q = $evt.data.arguments.prompt }
                if (-not $q) { $q = T 'The agent is waiting for your answer.' }
                $choices = @()
                foreach ($a in @($evt.data.arguments.answers)) {
                    if ($a -and $a.title) { $choices += $a.title }
                }
                $sess.PendingAsks[$evt.data.requestId] = @{
                    text    = (Truncate $q 280)
                    choices = $choices
                    session = $sess.Label
                }
            } else {
                $desc = Describe-Tool $evt.data.toolName $evt.data.arguments
                Add-Step $sess $evt.data.toolCallId $evt.data.requestId $desc
            }
        }
        'external_tool.completed' {
            $id = $evt.data.requestId
            if ($sess.PendingAsks.Contains($id)) { $sess.PendingAsks.Remove($id) }
            else { Complete-Step $sess $null $id }
        }
        'permission.requested' {
            $req = $evt.data.permissionRequest
            $id  = $evt.data.requestId
            $text = $null
            if ($req) {
                if ($req.fullCommandText) { $text = $req.fullCommandText }
                elseif ($req.commandText)  { $text = $req.commandText }
                elseif ($req.toolName)     { $text = $req.toolName }
                elseif ($req.path)         { $text = $req.path }
            }
            if (-not $text) { $text = '(approval requested)' }
            $kind = if ($req) { $req.kind } else { 'permission' }
            $sess.PendingPerms[$id] = @{ text = (Truncate $text 280); kind = $kind; session = $sess.Label }
        }
        'permission.completed' {
            $id = $evt.data.requestId
            if ($sess.PendingPerms.Contains($id)) { $sess.PendingPerms.Remove($id) }
        }
    }
}

function Wake-AgentA11y([IntPtr]$hwnd) {
    if ($hwnd -eq [IntPtr]::Zero) { return }
    [void][ScoutNative]::SendMessage($hwnd, 0x003D, [IntPtr]::Zero, [IntPtr](-25))
}

function Get-AgentPids {
    $pids = New-Object 'System.Collections.Generic.HashSet[uint32]'
    $all = $null
    try { $all = Get-Process -ErrorAction SilentlyContinue } catch { return $pids }
    foreach ($name in $Config.processNames) {
        foreach ($p in @($all | Where-Object { $_.ProcessName -like "*$name*" })) {
            if ($Config.browserProcs -contains $p.ProcessName) { continue }
            [void]$pids.Add([uint32]$p.Id)
        }
    }
    return $pids
}

function Get-AgentWindows {
    # Every visible top-level agent window, not one per process. Electron keeps
    # several windows inside a single process, so asking the process for its
    # "main" window finds one of them and quietly ignores the rest.
    $pids = Get-AgentPids
    if ($pids.Count -eq 0) { return @() }
    try { return @([ScoutNative]::TopLevelWindows($pids)) } catch { return @() }
}

function Count-AgentWindows {
    # How many agent windows are on screen. Matters because a pending approval
    # cannot be traced back to the window that raised it: the session lock names
    # a backend process, not the UI one.
    $n = @(Get-AgentWindows).Count
    if ($n -gt 0) { return $n }
    # The enumeration can come back empty if the process list could not be read;
    # claiming zero windows would quietly re-enable one-click approvals, so fall
    # back to "one" and let the caller behave as it always did.
    return 1
}

function Invoke-AgentButton([string[]]$labels) {
    # Refuse to guess when several agent windows are open. Clicking Allow in the
    # wrong window would approve something the user never saw, which is a far
    # worse failure than making them click it themselves.
    if ((Count-AgentWindows) -gt 1) { return $false }

    $win = Get-AgentWindow
    if (-not $win) { return $false }
    Wake-AgentA11y $win.Hwnd
    Start-Sleep -Milliseconds 350
    try { $root = [System.Windows.Automation.AutomationElement]::FromHandle($win.Hwnd) } catch { return $false }
    if (-not $root) { return $false }

    $btnCond = New-Object System.Windows.Automation.PropertyCondition(
        [System.Windows.Automation.AutomationElement]::ControlTypeProperty,
        [System.Windows.Automation.ControlType]::Button)
    $buttons = $root.FindAll([System.Windows.Automation.TreeScope]::Descendants, $btnCond)

    foreach ($label in $labels) {
        foreach ($b in $buttons) {
            $n = $b.Current.Name
            if ($n -and ($n.Trim().ToLower() -eq $label.ToLower()) -and -not $b.Current.IsOffscreen) {
                try { $b.GetCurrentPattern([System.Windows.Automation.InvokePattern]::Pattern).Invoke(); return $true } catch { }
            }
        }
    }
    foreach ($label in $labels) {
        foreach ($b in $buttons) {
            $n = $b.Current.Name
            if ($n -and ($n -ilike "*$label*") -and -not $b.Current.IsOffscreen) {
                try { $b.GetCurrentPattern([System.Windows.Automation.InvokePattern]::Pattern).Invoke(); return $true } catch { }
            }
        }
    }
    return $false
}

function Focus-Agent {
    $win = Get-AgentWindow
    if (-not $win) { return }
    [void][ScoutNative]::ShowWindow($win.Hwnd, 9)
    [void][ScoutNative]::SetForegroundWindow($win.Hwnd)
}

# ---------------------------------------------------------------------------
# Opening the chat a prompt actually came from.
#
# Scout's chats and the folders this companion follows are two different id
# namespaces. A chat in the sidebar is keyed by an id that never appears in
# session-state, and the index that would bridge them is encrypted on disk, so
# there is no lookup to do - the session cannot be named from the outside.
#
# What the sidebar does hand over, once its search field is open, is every
# chat's title and how long ago it was last touched. So the chat is found the
# way a person would find it: type something the session has talked about,
# then take the row whose "when" agrees with when this session last moved.
#
# The search is semantic, so it is only trusted to bring the chat into view -
# a long sentence pulls back near-noise, while a couple of words pulls back
# the right handful. The timestamp is what decides, and when nothing agrees
# the switch is abandoned rather than guessed at: sending someone to the wrong
# conversation is worse than leaving them where they were.
# ---------------------------------------------------------------------------
$UiaEl   = [System.Windows.Automation.AutomationElement]
$UiaTree = [System.Windows.Automation.TreeScope]
$UiaType = [System.Windows.Automation.ControlType]

function Find-UiaByName($root, [string]$name, $type) {
    if (-not $root) { return $null }
    try {
        $cond = New-Object System.Windows.Automation.AndCondition(
            (New-Object System.Windows.Automation.PropertyCondition($UiaEl::ControlTypeProperty, $type)),
            (New-Object System.Windows.Automation.PropertyCondition($UiaEl::NameProperty, $name)))
        return $root.FindFirst($UiaTree::Descendants, $cond)
    } catch { return $null }
}

function Invoke-UiaElement($el) {
    if (-not $el) { return $false }
    try { $el.GetCurrentPattern([System.Windows.Automation.InvokePattern]::Pattern).Invoke(); return $true }
    catch { return $false }
}

# A row reads "Pinned: <title> <when> More actions", with an optional
# " Automation run" badge in between. Only <when> is load-bearing.
function Split-ChatRow([string]$raw) {
    $s = $raw -replace '^Pinned:\s*',''
    $s = $s -replace '\s*More actions\s*$',''
    $s = $s -replace '\s*Automation run\s*$',''
    $when = $null
    $pat = '\s+(Just now|\d+[smhd] ago|\d{1,2}/\d{1,2}/\d{4})$'
    if ($s -match $pat) { $when = $Matches[1]; $s = $s -replace $pat,'' }
    return [pscustomobject]@{ Title = $s.Trim(); When = $when }
}

function ConvertTo-AgeMinutes([string]$when) {
    if (-not $when) { return $null }
    if ($when -eq 'Just now')      { return 0.0 }
    if ($when -match '^(\d+)s ago$') { return [double]$Matches[1] / 60.0 }
    if ($when -match '^(\d+)m ago$') { return [double]$Matches[1] }
    if ($when -match '^(\d+)h ago$') { return [double]$Matches[1] * 60 }
    if ($when -match '^(\d+)d ago$') { return [double]$Matches[1] * 1440 }
    # A bare date means the chat is old enough that Scout stopped counting, and
    # it is parsed only so such rows can be ruled out rather than ignored.
    if ($when -match '^\d{1,2}/\d{1,2}/\d{4}$') {
        try { return ([datetime]::Now - [datetime]::Parse($when)).TotalMinutes } catch { return $null }
    }
    return $null
}

# Chat rows are the full-width buttons in the left column. Height is not fixed:
# a row grows a line once the search field is open and it has to carry a
# timestamp, which is exactly the state this runs in.
function Get-ChatRows($root) {
    $out = New-Object System.Collections.ArrayList
    if (-not $root) { return @() }
    $win = $root.Current.BoundingRectangle
    $cond = New-Object System.Windows.Automation.PropertyCondition($UiaEl::ControlTypeProperty, $UiaType::Button)
    foreach ($b in $root.FindAll($UiaTree::Descendants, $cond)) {
        $c = $null; try { $c = $b.Current } catch { continue }
        if ($c.IsOffscreen) { continue }
        $r = $c.BoundingRectangle
        # An element that was never laid out reports an infinite rect, which
        # would blow up the cast to int further down.
        if ([double]::IsInfinity($r.X) -or [double]::IsInfinity($r.Y)) { continue }
        if ($r.X -gt ($win.X + 340)) { continue }
        if ($r.Width -lt 260 -or $r.Width -gt 330) { continue }
        if ($r.Height -lt 40 -or $r.Height -gt 96) { continue }
        if (-not $c.Name -or $c.Name -notmatch 'More actions$') { continue }
        $p = Split-ChatRow $c.Name
        [void]$out.Add([pscustomobject]@{ Y = [int]$r.Y; Title = $p.Title; When = $p.When; El = $b })
    }
    return @($out | Sort-Object Y)
}

# Something the session has talked about, short enough that the search stays
# sharp. The first thing asked for is the best handle; where the session was
# resumed and opens with a bare "carry on", the project folder is the fallback.
function Get-SessionQuery($rec) {
    if (-not $rec) { return $null }
    if (-not $rec.Topic) { $rec.Topic = Get-SessionTopic $rec.Events }
    $q = $rec.Topic
    if ($q) { $q = ($q -replace '\.\.\.$','').Trim() }
    if (-not $q -or $q.Length -lt 3) { $q = $rec.BaseLabel }
    if (-not $q) { return $null }
    return (Truncate $q 40)
}

# The session a visible prompt belongs to, falling back to whichever session
# moved last so the tray and the Open button still do something sensible when
# nothing is pending.
# Scout stamps a chat when a message lands in it, not when a tool runs, so a
# session that has spent ten minutes grinding through tool calls still reads
# "10m ago" in the sidebar while the companion has seen events all along.
# Comparing those two clocks directly never matches, so the message clock is
# read straight out of the file instead - only on a click, and only from the
# tail, since these files reach tens of megabytes.
function Get-LastMessageUtc([string]$events) {
    try {
        $fi = New-Object System.IO.FileInfo $events
        if (-not $fi.Exists) { return $null }
        $len  = $fi.Length
        $take = [Math]::Min($len, 262144)
        $chunk = $null
        $fs = [System.IO.File]::Open($events, 'Open', 'Read', 'ReadWrite')
        try {
            $fs.Seek($len - $take, 'Begin') | Out-Null
            $sr = New-Object System.IO.StreamReader($fs)
            $chunk = $sr.ReadToEnd()
        } finally { $fs.Dispose() }
        if (-not $chunk) { return $null }

        $best = $null
        foreach ($line in ($chunk -split "`n")) {
            if ($line -notmatch '"(assistant|user)\.message"') { continue }
            # An event's own timestamp is the last one on the line; anything
            # earlier belongs to the payload it carries.
            $ms = [regex]::Matches($line, '"timestamp":"([^"]+)"')
            if ($ms.Count -eq 0) { continue }
            $t = $null
            try { $t = [datetime]::Parse($ms[$ms.Count - 1].Groups[1].Value).ToUniversalTime() } catch { continue }
            if (-not $best -or $t -gt $best) { $best = $t }
        }
        return $best
    } catch { return $null }
}

# Picks the chat that belongs to a session last heard from $age minutes ago,
# or nothing at all when the list holds no plausible candidate.
#
# The sidebar's timestamps lag, sometimes by ten minutes or more for a chat
# that is not the one on screen. Crucially they only ever lag: a chat can be
# shown as older than it really is, never younger. So the window is asymmetric
# - a little slack below to absorb rounding, a lot above to absorb the lag -
# and within it the freshest row wins, since the chat that raised the prompt is
# the one that moved most recently.
function Select-ChatRow($rows, [double]$age) {
    if ($age -lt 0) { $age = 0 }
    $lo = [Math]::Max(0.0, $age * 0.5 - 2.0)
    $hi = $age + [Math]::Max(20.0, $age * 0.5)

    $cands = New-Object System.Collections.ArrayList
    for ($i = 0; $i -lt @($rows).Count; $i++) {
        $m = ConvertTo-AgeMinutes $rows[$i].When
        if ($null -eq $m) { continue }
        if ($m -lt $lo -or $m -gt $hi) { continue }
        [void]$cands.Add([pscustomobject]@{ Row = $rows[$i]; Age = $m; Rank = $i })
    }
    # Nothing moved anywhere near when this session did. Rather than pick the
    # most plausible-looking row, give up: the caller has already brought the
    # window forward, which is what the user actually asked for.
    if ($cands.Count -eq 0) { return $null }

    # Freshest first, and where two chats share a timestamp the search's own
    # ordering breaks the tie: it was asked about this session's topic, so the
    # row it put higher is the one more likely to be this session.
    return (@($cands | Sort-Object Age, Rank))[0].Row
}

function Get-RaisingSession {
    foreach ($bag in @($State.PendingPerms, $State.PendingAsks)) {
        foreach ($k in $bag.Keys) {
            $label = $bag[$k].session
            if (-not $label) { continue }
            foreach ($dir in $Sessions.Keys) {
                if ($Sessions[$dir].Label -eq $label) { return $Sessions[$dir] }
            }
        }
    }
    $best = $null
    foreach ($dir in $Sessions.Keys) {
        $rec = $Sessions[$dir]
        if (-not $best -or $rec.LastEventUtc -gt $best.LastEventUtc) { $best = $rec }
    }
    return $best
}

function Open-AgentSession($rec) {
    # Returns $true only when the sidebar was actually driven to this session.
    if (-not $rec) { return $false }
    if (-not $Config.openMatchingSession) { return $false }
    $query = Get-SessionQuery $rec
    if (-not $query) { return $false }

    $win = Get-AgentWindow
    if (-not $win) { return $false }
    Wake-AgentA11y $win.Hwnd
    Start-Sleep -Milliseconds 300
    $root = $null
    try { $root = $UiaEl::FromHandle($win.Hwnd) } catch { return $false }
    if (-not $root) { return $false }

    # The sidebar and its search field are both collapsible, and whatever was
    # closed on the way in gets closed again on the way out - this is the
    # user's window, not ours.
    $openedSidebar = $false
    $openedSearch  = $false
    $typed         = $false
    $navigated     = $false
    try {
        if (-not (Find-UiaByName $root 'Hide sidebar' $UiaType::Button)) {
            if (Invoke-UiaElement (Find-UiaByName $root 'Show sidebar' $UiaType::Button)) {
                $openedSidebar = $true
                Start-Sleep -Milliseconds 350
                $root = $UiaEl::FromHandle($win.Hwnd)
            }
        }

        $box = Find-UiaByName $root 'Search chats' $UiaType::Edit
        if (-not $box) {
            if (Invoke-UiaElement (Find-UiaByName $root 'Show chat search' $UiaType::Button)) {
                $openedSearch = $true
                Start-Sleep -Milliseconds 400
                $root = $UiaEl::FromHandle($win.Hwnd)
                $box = Find-UiaByName $root 'Search chats' $UiaType::Edit
            }
        }
        if (-not $box) { return $false }

        # No SetFocus. The field takes a value without the caret, and taking the
        # caret would pull it out of whatever the user was typing in.
        try { $box.GetCurrentPattern([System.Windows.Automation.ValuePattern]::Pattern).SetValue($query) }
        catch { return $false }
        $typed = $true

        # Results arrive asynchronously; poll rather than sleep for a fixed
        # worst case, so the common fast answer is not paid for every time.
        $rows = @()
        for ($i = 0; $i -lt 12; $i++) {
            Start-Sleep -Milliseconds 200
            $rows = Get-ChatRows ($UiaEl::FromHandle($win.Hwnd))
            if (@($rows | Where-Object { $_.When }).Count -gt 0) { break }
        }

        # Measured from the last message, because that is the kind of thing the
        # sidebar's own "when" is measuring - a session grinding through tools
        # for ten minutes has not "just" done anything as far as Scout's chat
        # list is concerned.
        $stamp = Get-LastMessageUtc $rec.Events
        if (-not $stamp) { $stamp = $rec.LastEventUtc }
        $pick = Select-ChatRow $rows ([double]([datetime]::UtcNow - $stamp).TotalMinutes)
        if (-not $pick) { return $false }

        # Now that the chat has been identified, remember what Scout calls it so
        # the toast can name it from here on without looking again.
        if ($pick.Title) { $rec.ChatTitle = $pick.Title; try { Resolve-SessionLabels } catch { } }
        $navigated = Invoke-UiaElement $pick.El
        if ($navigated) { Start-Sleep -Milliseconds 500 }
        return $navigated
    } finally {
        # Put the sidebar back, but only touch what this function touched: a
        # query the user typed themselves is theirs, not ours to clear.
        try {
            if ($typed) {
                $root2 = $UiaEl::FromHandle($win.Hwnd)
                if (-not (Invoke-UiaElement (Find-UiaByName $root2 'Clear search' $UiaType::Button))) {
                    $b2 = Find-UiaByName $root2 'Search chats' $UiaType::Edit
                    if ($b2) {
                        try { $b2.SetFocus() } catch { }
                        try { $b2.GetCurrentPattern([System.Windows.Automation.ValuePattern]::Pattern).SetValue('') } catch { }
                    }
                }
                Start-Sleep -Milliseconds 250
            }
            if ($openedSearch) {
                [void](Invoke-UiaElement (Find-UiaByName ($UiaEl::FromHandle($win.Hwnd)) 'Hide chat search' $UiaType::Button))
            }
            if ($openedSidebar) {
                [void](Invoke-UiaElement (Find-UiaByName ($UiaEl::FromHandle($win.Hwnd)) 'Hide sidebar' $UiaType::Button))
            }
        } catch { }
    }
}

# What Open, Answer and the tray all mean: show me the thing that is asking.
# Bringing the window forward is the part that must never fail, so it happens
# first and the chat switch is a bonus on top of it.
function Focus-AgentSession {
    Focus-Agent
    $rec = $null
    try { $rec = Get-RaisingSession } catch { }
    if (-not $rec) { return }
    try { [void](Open-AgentSession $rec) } catch { }
}
# ---------------------------------------------------------------------------
# WPF overlay UI (with animated quokka mascot).
# ---------------------------------------------------------------------------
[xml]$xaml = @'
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
        xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        Title="Scout Companion"
        Width="380" SizeToContent="Height"
        WindowStyle="None" AllowsTransparency="True" Background="Transparent"
        Topmost="True" ShowInTaskbar="False" ResizeMode="NoResize">
  <Grid>
    <!-- Glow layer. The drop shadow lives here, on a plain rounded rectangle with
         no animating content, so a moving mascot never forces the whole toast
         back through the blur shader. Measured at ~1.9 points of CPU when the
         shadow sat on the content border instead. -->
    <Border x:Name="GlowBorder" CornerRadius="14" Background="#FF1B1F2A">
      <Border.Effect><DropShadowEffect x:Name="RootGlow" BlurRadius="20" ShadowDepth="3" Opacity="0.55" Color="#000000"/></Border.Effect>
    </Border>
    <Border x:Name="RootBorder" CornerRadius="14" Background="#FF1B1F2A" BorderBrush="#FF3A4358" BorderThickness="1" Padding="14">
    <StackPanel>
      <DockPanel LastChildFill="True">

        <!-- Mascot. The head is swapped in at runtime (see Set-Mascot); the
             laptop and paws are shared by every mascot and carry the animated
             transforms, so switching mascot never has to rebind them. -->
        <Canvas x:Name="MascotHost" Width="58" Height="60" DockPanel.Dock="Left" Margin="0,0,12,0"
                RenderTransformOrigin="0.5,0.6" VerticalAlignment="Center">
          <Canvas.RenderTransform>
            <TransformGroup>
              <ScaleTransform x:Name="BodyS" ScaleX="1" ScaleY="1"/>
              <RotateTransform x:Name="BodyR" Angle="0" CenterX="29" CenterY="52"/>
              <TranslateTransform x:Name="BodyT"/>
            </TransformGroup>
          </Canvas.RenderTransform>
          <!-- head is inserted here at index 0 -->
          <!-- The desk furniture, grouped so a mascot that does not type can hide
               it in one move. Positions are unchanged: a nested Canvas at 0,0
               keeps every Canvas.Left/Top in the same coordinate space. -->
          <Canvas x:Name="Desk" Width="58" Height="60">
            <!-- laptop: screen lid (seen from behind) -->
            <Border Canvas.Left="17" Canvas.Top="40" Width="24" Height="13" CornerRadius="2" Background="#FF3A4257"/>
            <Border Canvas.Left="19" Canvas.Top="42" Width="20" Height="9"  CornerRadius="1" Background="#FF5C6B86"/>
            <Ellipse Canvas.Left="27" Canvas.Top="45" Width="4" Height="4" Fill="#FF9DE7FF"/>
            <!-- laptop: keyboard base -->
            <Polygon Points="11,52 47,52 53,60 5,60" Fill="#FFC9D0DC"/>
            <Polygon Points="14,53 44,53 48,58 10,58" Fill="#FFA9B3C4"/>
            <!-- paws on the keyboard (animated typing); recoloured per mascot -->
            <Ellipse x:Name="LeftPaw" Canvas.Left="14" Canvas.Top="49" Width="11" Height="8" Fill="#FFB87A50">
              <Ellipse.RenderTransform><TranslateTransform x:Name="LeftPawT"/></Ellipse.RenderTransform>
            </Ellipse>
            <Ellipse x:Name="RightPaw" Canvas.Left="32" Canvas.Top="49" Width="11" Height="8" Fill="#FFB87A50">
              <Ellipse.RenderTransform><TranslateTransform x:Name="RightPawT"/></Ellipse.RenderTransform>
            </Ellipse>
          </Canvas>
        </Canvas>

        <Button x:Name="CloseBtn" Content="&#x2715;" DockPanel.Dock="Right" Width="22" Height="22"
                Background="Transparent" Foreground="#FF8A93A6" BorderThickness="0" FontSize="12"
                VerticalAlignment="Top" Cursor="Hand"/>
        <Button x:Name="SettingsBtn" Content="&#x2699;" DockPanel.Dock="Right" Width="22" Height="22"
                Background="Transparent" Foreground="#FF8A93A6" BorderThickness="0" FontSize="13"
                VerticalAlignment="Top" Cursor="Hand" ToolTip="Settings"/>
        <Button x:Name="OpenBtn" Content="Open" DockPanel.Dock="Right" Height="22" Margin="0,0,6,0"
                Background="#FF2A3142" Foreground="#FFB9C2D6" BorderThickness="0" Padding="8,0" FontSize="11"
                VerticalAlignment="Top" Cursor="Hand"/>

        <StackPanel VerticalAlignment="Center">
          <DockPanel LastChildFill="True">
            <Ellipse x:Name="Dot" Width="9" Height="9" Fill="#FF4ADE80" VerticalAlignment="Center" Margin="0,0,7,0" DockPanel.Dock="Left"/>
            <TextBlock x:Name="HeaderText" Text="Scout is working" Foreground="#FFE6EAF2" FontSize="13.5" FontWeight="SemiBold" VerticalAlignment="Center"/>
          </DockPanel>
          <TextBlock x:Name="SayingText" Margin="0,4,0,0" Text="" Foreground="#FF9AA6BE" FontSize="11"
                     FontStyle="Italic" TextWrapping="Wrap" MaxHeight="44" TextTrimming="CharacterEllipsis"/>
        </StackPanel>
      </DockPanel>

      <!-- live step list -->
      <Border x:Name="StepsPanel" Margin="0,10,0,0" Padding="10,8" CornerRadius="9" Background="#FF232838" Visibility="Collapsed">
        <TextBlock x:Name="StepsText" Text="" Foreground="#FFC7D0E2" FontSize="11.5" FontFamily="Consolas, Cascadia Mono, monospace"
                   TextWrapping="NoWrap" TextTrimming="CharacterEllipsis"/>
      </Border>

      <!-- permission prompt -->
      <Border x:Name="PermPanel" Margin="0,12,0,0" Padding="10" CornerRadius="9"
              Background="#FF2A2030" BorderBrush="#FFB4843C" BorderThickness="1" Visibility="Collapsed">
        <StackPanel>
          <TextBlock x:Name="PermTitle" Text="&#x26A0; Permission requested" Foreground="#FF6A4A00" FontWeight="Bold" FontSize="13"
                     TextTrimming="CharacterEllipsis"/>
          <!-- Which conversation is asking. Its own line, because a chat title
               is a sentence more often than a word and would push the header
               off the toast if it were appended to it. -->
          <TextBlock x:Name="PermFrom" Margin="0,2,0,0" Text="" Foreground="#FFD6CFC2" FontSize="10.5"
                     Opacity="0.85" TextTrimming="CharacterEllipsis" Visibility="Collapsed"/>
          <TextBlock x:Name="PermText" Margin="0,5,0,0" Foreground="#FFD6CFC2" FontSize="11.5"
                     TextWrapping="Wrap" MaxHeight="90" TextTrimming="CharacterEllipsis"/>
          <!-- MinWidth, not Width. Fixed widths were fine in English and clipped
               the moment the captions were translated: "Отклонить" and
               "Odmítnout" both overrun a 74 px Deny button. MinWidth keeps the
               English layout identical while letting a longer caption push the
               button out instead of truncating it. -->
          <StackPanel Orientation="Horizontal" Margin="0,10,0,0" HorizontalAlignment="Right">
            <Button x:Name="DenyBtn" Content="Deny" MinWidth="74" Height="28" Margin="0,0,8,0" Padding="10,0"
                    Background="#FF3A2730" Foreground="#FFF0B4B4" BorderThickness="0" Cursor="Hand"/>
            <Button x:Name="AllowBtn" Content="Allow" MinWidth="90" Height="28" Padding="10,0"
                    Background="#FF2E7D46" Foreground="#FFFFFFFF" BorderThickness="0" FontWeight="SemiBold" Cursor="Hand"/>
            <Button x:Name="AnswerBtn" Content="Answer in Scout" MinWidth="140" Height="28" Padding="10,0"
                    Background="#FF0E7FB8" Foreground="#FFFFFFFF" BorderThickness="0" FontWeight="SemiBold"
                    Cursor="Hand" Visibility="Collapsed"/>
          </StackPanel>
        </StackPanel>
      </Border>
    </StackPanel>
    </Border>
  </Grid>
</Window>
'@

$reader = New-Object System.Xml.XmlNodeReader (Convert-XamlText $xaml)
$Window = [Windows.Markup.XamlReader]::Load($reader)

$HeaderText   = $Window.FindName('HeaderText')
$SayingText   = $Window.FindName('SayingText')
$Dot          = $Window.FindName('Dot')
$StepsPanel   = $Window.FindName('StepsPanel')
$StepsText    = $Window.FindName('StepsText')
$PermPanel    = $Window.FindName('PermPanel')
$PermText     = $Window.FindName('PermText')
$PermFrom     = $Window.FindName('PermFrom')
$AllowBtn     = $Window.FindName('AllowBtn')
$DenyBtn      = $Window.FindName('DenyBtn')
$AnswerBtn    = $Window.FindName('AnswerBtn')
$OpenBtn      = $Window.FindName('OpenBtn')
$CloseBtn     = $Window.FindName('CloseBtn')
$SettingsBtn  = $Window.FindName('SettingsBtn')
$BodyT        = $Window.FindName('BodyT')
$BodyS        = $Window.FindName('BodyS')
$BodyR        = $Window.FindName('BodyR')
$LeftPawT     = $Window.FindName('LeftPawT')
$RightPawT    = $Window.FindName('RightPawT')
$RootBorder   = $Window.FindName('RootBorder')
$GlowBorder   = $Window.FindName('GlowBorder')
$MascotHost   = $Window.FindName('MascotHost')
$Desk         = $Window.FindName('Desk')
$LeftPaw      = $Window.FindName('LeftPaw')
$RightPaw     = $Window.FindName('RightPaw')
$RootGlow     = $Window.FindName('RootGlow')
$PermTitle    = $Window.FindName('PermTitle')

# Brushes for the three states: idle (dark), working (muted green), alert (yellow).
function B([string]$hex) { (New-Object System.Windows.Media.BrushConverter).ConvertFromString($hex) }
$Theme = @{
    NormalBg      = B '#FF1B1F2A'; NormalBorder  = B '#FF3A4358'; NormalHeader  = B '#FFE6EAF2'
    WorkingBg     = B '#FF18261D'; WorkingBorder = B '#FF3C6B4C'; WorkingHeader = B '#FFE6F2EA'
    AlertBg       = B '#FFFFD23D'; AlertBorder   = B '#FFFF7A00'; AlertHeader   = B '#FF3A2600'
    # Questions get their own colour rather than sharing the approval yellow:
    # an approval can be answered from the toast, a question cannot, so telling
    # them apart from across the room decides whether you have to walk over.
    AskBg         = B '#FF5CC8F5'; AskBorder     = B '#FF0E7FB8'; AskHeader     = B '#FF06263A'
    PermBgNormal  = B '#FF2A2030'; PermBdNormal  = B '#FFB4843C'; PermTxtNormal = B '#FFD6CFC2'
    PermBgAlert   = B '#FFFFFFFF'; PermBdAlert   = B '#FFFF7A00'; PermTxtAlert  = B '#FF3A2E10'
    PermBgAsk     = B '#FFFFFFFF'; PermBdAsk     = B '#FF0E7FB8'; PermTxtAsk    = B '#FF10303F'
}
$script:ThemeState = $null

# state: 'alert' (approval), 'ask' (question), 'working' (busy), 'idle' (default/dim)
function Set-Theme([string]$state) {
    if ($state -eq 'alert') {
        $RootBorder.Background  = $Theme.AlertBg
        $RootBorder.BorderBrush = $Theme.AlertBorder
        $RootBorder.BorderThickness = 2
        $HeaderText.Foreground  = $Theme.AlertHeader
        $PermPanel.Background   = $Theme.PermBgAlert
        $PermPanel.BorderBrush  = $Theme.PermBdAlert
        $PermText.Foreground    = $Theme.PermTxtAlert
        $PermFrom.Foreground    = $Theme.PermTxtAlert
        $PermTitle.Foreground   = $Theme.AlertHeader
        $RootGlow.Color         = [System.Windows.Media.Color]::FromRgb(255, 176, 0)
        $RootGlow.BlurRadius    = 20
        $RootGlow.Opacity       = 0.55
    }
    elseif ($state -eq 'ask') {
        $RootBorder.Background  = $Theme.AskBg
        $RootBorder.BorderBrush = $Theme.AskBorder
        $RootBorder.BorderThickness = 2
        $HeaderText.Foreground  = $Theme.AskHeader
        $PermPanel.Background   = $Theme.PermBgAsk
        $PermPanel.BorderBrush  = $Theme.PermBdAsk
        $PermText.Foreground    = $Theme.PermTxtAsk
        $PermFrom.Foreground    = $Theme.PermTxtAsk
        $PermTitle.Foreground   = $Theme.AskHeader
        $RootGlow.Color         = [System.Windows.Media.Color]::FromRgb(0, 150, 210)
        $RootGlow.BlurRadius    = 20
        $RootGlow.Opacity       = 0.55
    }
    elseif ($state -eq 'working') {
        $RootBorder.Background  = $Theme.WorkingBg
        $RootBorder.BorderBrush = $Theme.WorkingBorder
        $RootBorder.BorderThickness = 1
        $HeaderText.Foreground  = $Theme.WorkingHeader
        $PermPanel.Background   = $Theme.PermBgNormal
        $PermPanel.BorderBrush  = $Theme.PermBdNormal
        $PermText.Foreground    = $Theme.PermTxtNormal
        $PermFrom.Foreground    = $Theme.PermTxtNormal
        $PermTitle.Foreground   = $Theme.PermBdNormal
        $RootGlow.Color         = [System.Windows.Media.Color]::FromRgb(56, 170, 100)
        $RootGlow.BlurRadius    = 22
        $RootGlow.Opacity       = 0.40
    }
    else {
        $RootBorder.Background  = $Theme.NormalBg
        $RootBorder.BorderBrush = $Theme.NormalBorder
        $RootBorder.BorderThickness = 1
        $HeaderText.Foreground  = $Theme.NormalHeader
        $PermPanel.Background   = $Theme.PermBgNormal
        $PermPanel.BorderBrush  = $Theme.PermBdNormal
        $PermText.Foreground    = $Theme.PermTxtNormal
        $PermFrom.Foreground    = $Theme.PermTxtNormal
        $PermTitle.Foreground   = $Theme.PermBdNormal
        $RootGlow.Color         = [System.Windows.Media.Color]::FromRgb(0, 0, 0)
        $RootGlow.BlurRadius    = 20
        $RootGlow.Opacity       = 0.55
    }
    # The glow layer sits behind the content and only exists to cast the shadow,
    # so keep its fill matched to the content border.
    $GlowBorder.Background = $RootBorder.Background
}

function Place-BottomRight {
    $wa = [System.Windows.SystemParameters]::WorkArea
    $Window.Left = $wa.Right - $Window.ActualWidth - 16
    $Window.Top  = $wa.Bottom - $Window.ActualHeight - 16
}
$Window.Add_Loaded({ Place-BottomRight })
$Window.Add_SizeChanged({ Place-BottomRight })
$Window.Add_MouseLeftButtonDown({ try { $Window.DragMove() } catch { } })

$script:Hidden = $false
# Set by the tray toggle only. The automatic rules decide when the toast is
# worth showing; this is the user overriding them, so it outranks both the
# rules and $Hidden and stays on until it is switched off again.
$script:Pinned = $false
$script:Pending = $false
$script:Asking = $false
$script:AgentGoneSince = $null
# WPF's idea of whether the toast is on screen, and the window's real state,
# start out disagreeing - see the reconciliation on the first tick.
$script:VisibilityReconciled = $false
# Until when the startup greeting keeps the toast up. Set once the poll loop is
# about to start, so the greeting covers the moment the app becomes usable
# rather than the moment the script began parsing.
$script:GreetUntil = [datetime]::MinValue

# The whole visibility policy, in one place and with no side effects, so the
# ordering of the rules is reviewable and testable rather than buried in the
# poll loop. Order matters and is the point:
#   1. anything waiting on the user is worth showing,
#   2. otherwise show only while the agent is working out of sight,
#   3. a dismissal suppresses both of those,
#   4. an explicit pin overrides everything, including the dismissal.
function Get-ShouldShow {
    param(
        [bool]$HasPending, [bool]$HasAsk, [bool]$IsActive,
        [bool]$AgentRunning, [bool]$IsMinimized, [bool]$IsForeground,
        [bool]$Hidden, [bool]$Pinned, [bool]$Greeting
    )
    $show = $false
    if ($HasPending -or $HasAsk) { $show = $true }
    # Ranked above the activity rule and below $Hidden on purpose: the greeting
    # only has to survive the rule that would otherwise hide it at startup, and
    # closing the toast has to still mean closed.
    elseif ($Greeting) { $show = $true }
    elseif ($IsActive -and $AgentRunning -and ($IsMinimized -or -not $IsForeground)) { $show = $true }
    if ($Hidden) { $show = $false }
    if ($Pinned) { $show = $true }
    return $show
}

# Applied to the whole toast. Clamped rather than trusted: a hand-edited config
# with 0 in it would leave an invisible window that still takes clicks.
function Set-ToastOpacity([double]$v) {    if ($v -lt 0.35) { $v = 0.35 }
    if ($v -gt 1.0)  { $v = 1.0 }
    $Window.Opacity = $v
    return $v
}
$Config.opacity = Set-ToastOpacity ([double]$Config.opacity)
Set-Theme 'idle'

$AllowBtn.Add_Click({
    if (Invoke-AgentButton $Config.allowLabels) {
        foreach ($k in @($State.PendingPerms.Keys)) { $State.PendingPerms.Remove($k) }
    } else { Focus-Agent }
})
$DenyBtn.Add_Click({
    if (Invoke-AgentButton $Config.denyLabels) {
        foreach ($k in @($State.PendingPerms.Keys)) { $State.PendingPerms.Remove($k) }
    } else { Focus-Agent }
})
$OpenBtn.Add_Click({ Focus-AgentSession })
$AnswerBtn.Add_Click({ Focus-AgentSession })
$CloseBtn.Add_Click({ $script:Hidden = $true; $script:Pinned = $false; $Window.Hide() })
$SettingsBtn.Add_Click({ Show-SettingsWindow })

# ---------------------------------------------------------------------------
# Mascots.
#
# Each mascot is a species (the geometry) plus a palette (the colours), so the
# five cats share one drawing and differ only in fur, markings and eye colour.
# Only the head is swapped at runtime: the laptop and the typing paws live in
# the host canvas and carry the animated transforms, so switching mascot never
# rebinds anything the animation touches.
#
# Every head carries a thin stroke in its own shade colour, otherwise pale
# mascots vanish against the bright yellow approval background.
# ---------------------------------------------------------------------------
# Shared "cute face" kit. The proportions matter more than the species: big
# eyes set low on the head, a bright highlight plus a small secondary one, soft
# blush, and a small mouth kept above y=40 so the laptop never covers it. Every
# mascot uses the same eyes, which is what makes them read as a family.
function New-CuteEyes($p) {
    # Dark rim, coloured iris, dark pupil, one big highlight and one small: the
    # layering that reads as a glossy eye even at 14 px across.
    #
    # Wrapped in a named group so the animation can squash it for a blink and
    # open it wider when the agent needs something. The pivot sits on the eye
    # centre line so the lids meet in the middle rather than sliding down.
    @"
      <Canvas x:Name="EyeGroup" Width="58" Height="60">
        <Canvas.RenderTransform>
          <ScaleTransform x:Name="BlinkS" ScaleX="1" ScaleY="1" CenterX="29" CenterY="22.5"/>
        </Canvas.RenderTransform>
        <Ellipse Canvas.Left="10.5" Canvas.Top="14.5" Width="14"   Height="16"   Fill="#FF241D1F"/>
        <Ellipse Canvas.Left="33.5" Canvas.Top="14.5" Width="14"   Height="16"   Fill="#FF241D1F"/>
        <Ellipse Canvas.Left="11.7" Canvas.Top="18.2" Width="11.6" Height="11.6" Fill="$($p.eye)"/>
        <Ellipse Canvas.Left="34.7" Canvas.Top="18.2" Width="11.6" Height="11.6" Fill="$($p.eye)"/>
        <Ellipse Canvas.Left="14.3" Canvas.Top="20.4" Width="6.4"  Height="7.4"  Fill="#FF201A1B"/>
        <Ellipse Canvas.Left="37.3" Canvas.Top="20.4" Width="6.4"  Height="7.4"  Fill="#FF201A1B"/>
        <Ellipse Canvas.Left="12.9" Canvas.Top="18.6" Width="4.8"  Height="4.8"  Fill="#FFFFFFFF"/>
        <Ellipse Canvas.Left="35.9" Canvas.Top="18.6" Width="4.8"  Height="4.8"  Fill="#FFFFFFFF"/>
        <Ellipse Canvas.Left="19.4" Canvas.Top="25.6" Width="2.4"  Height="2.4"  Fill="#CCFFFFFF"/>
        <Ellipse Canvas.Left="42.4" Canvas.Top="25.6" Width="2.4"  Height="2.4"  Fill="#CCFFFFFF"/>
      </Canvas>
"@
}

function New-Blush($p) {
    @"
      <Ellipse Canvas.Left="3.5" Canvas.Top="27.5" Width="11.5" Height="7" Fill="$($p.blush)" Opacity="0.5"/>
      <Ellipse Canvas.Left="43"  Canvas.Top="27.5" Width="11.5" Height="7" Fill="$($p.blush)" Opacity="0.5"/>
"@
}

# A small rounded muzzle: nose plus the little curved mouth under it. Kept above
# y=39 so the laptop never swallows the expression.
function New-Snout($p, [double]$noseW = 8, [double]$noseY = 30.5) {
    $x = 29 - $noseW / 2
    $m = $noseY + 5
    @"
      <Ellipse Canvas.Left="$x" Canvas.Top="$noseY" Width="$noseW" Height="5" Fill="$($p.nose)"/>
      <Path Stroke="$($p.nose)" StrokeThickness="1.7" StrokeStartLineCap="Round" StrokeEndLineCap="Round"
            Data="M29,$m Q25,$($m + 3.2) 22.5,$m M29,$m Q33,$($m + 3.2) 35.5,$m"/>
"@
}

function New-CatHead($p) {
    $patches = ''
    if ($p.patchA) {
        # Calico-style patches: one over an ear, one on the opposite cheek.
        $patches = @"
      <Path Fill="$($p.patchA)" Data="M11,14 Q22,6 28,15 Q20,25 10,23 Z"/>
      <Path Fill="$($p.patchB)" Data="M47,17 Q52,27 44,33 Q38,26 41,18 Z"/>
"@
    }
    $mask = ''
    if ($p.mask) {
        # Siamese-style points.
        $mask = "      <Ellipse Canvas.Left=`"16`" Canvas.Top=`"23`" Width=`"26`" Height=`"22`" Fill=`"$($p.mask)`"/>"
    }
    @"
      <Polygon Points="11,20 16,2 27,13" Fill="$($p.ear)" Stroke="$($p.ear)" StrokeThickness="4" StrokeLineJoin="Round"/>
      <Polygon Points="47,20 42,2 31,13" Fill="$($p.ear)" Stroke="$($p.ear)" StrokeThickness="4" StrokeLineJoin="Round"/>
      <Polygon Points="14,17 17,7 22,13" Fill="$($p.earInner)" Stroke="$($p.earInner)" StrokeThickness="2.6" StrokeLineJoin="Round"/>
      <Polygon Points="44,17 41,7 36,13" Fill="$($p.earInner)" Stroke="$($p.earInner)" StrokeThickness="2.6" StrokeLineJoin="Round"/>
      <Ellipse Canvas.Left="3" Canvas.Top="4" Width="52" Height="39" Fill="$($p.fur)" Stroke="$($p.shade)" StrokeThickness="1"/>
$patches
$mask
$(New-Blush $p)
$(New-CuteEyes $p)
$(New-Snout $p 8 30.5)
      <Path Stroke="$($p.shade)" StrokeThickness="0.9" Opacity="0.5" StrokeStartLineCap="Round"
            Data="M1,25 L8,26.5 M1,31 L8,30.5 M57,25 L50,26.5 M57,31 L50,30.5"/>
"@
}

function New-QuokkaHead($p) {
    @"
      <Ellipse Canvas.Left="5"  Canvas.Top="1" Width="16" Height="17" Fill="$($p.ear)" Stroke="$($p.shade)" StrokeThickness="1"/>
      <Ellipse Canvas.Left="37" Canvas.Top="1" Width="16" Height="17" Fill="$($p.ear)" Stroke="$($p.shade)" StrokeThickness="1"/>
      <Ellipse Canvas.Left="8.5"  Canvas.Top="4.5" Width="9" Height="10" Fill="$($p.earInner)"/>
      <Ellipse Canvas.Left="40.5" Canvas.Top="4.5" Width="9" Height="10" Fill="$($p.earInner)"/>
      <Ellipse Canvas.Left="3" Canvas.Top="4" Width="52" Height="39" Fill="$($p.fur)" Stroke="$($p.shade)" StrokeThickness="1"/>
      <Ellipse Canvas.Left="17" Canvas.Top="25" Width="24" Height="17" Fill="$($p.muzzle)"/>
$(New-Blush $p)
$(New-CuteEyes $p)
      <Line X1="8.8" Y1="19.5" X2="3.5" Y2="16.5" Stroke="#FF33302E" StrokeThickness="1.6"/>
      <Line X1="49.2" Y1="19.5" X2="54.5" Y2="16.5" Stroke="#FF33302E" StrokeThickness="1.6"/>
      <Ellipse Canvas.Left="8.8"  Canvas.Top="13.8" Width="17.4" Height="17.4" Stroke="#FF33302E" StrokeThickness="1.9" Fill="#12EAF7FF"/>
      <Ellipse Canvas.Left="31.8" Canvas.Top="13.8" Width="17.4" Height="17.4" Stroke="#FF33302E" StrokeThickness="1.9" Fill="#12EAF7FF"/>
      <Line X1="26.2" Y1="22.5" X2="31.8" Y2="22.5" Stroke="#FF33302E" StrokeThickness="1.9"/>
$(New-Snout $p 8 30.5)
"@
}

function New-DogHead($p) {
    @"
      <Path Fill="$($p.ear)" Stroke="$($p.ear)" StrokeThickness="4" StrokeLineJoin="Round" Data="M9,21 L14,2 L26,13 Z"/>
      <Path Fill="$($p.ear)" Stroke="$($p.ear)" StrokeThickness="4" StrokeLineJoin="Round" Data="M49,21 L44,2 L32,13 Z"/>
      <Path Fill="$($p.earInner)" Stroke="$($p.earInner)" StrokeThickness="2.4" StrokeLineJoin="Round" Data="M13,17 L16,7 L21,13 Z"/>
      <Path Fill="$($p.earInner)" Stroke="$($p.earInner)" StrokeThickness="2.4" StrokeLineJoin="Round" Data="M45,17 L42,7 L37,13 Z"/>
      <Ellipse Canvas.Left="3" Canvas.Top="4" Width="52" Height="39" Fill="$($p.fur)" Stroke="$($p.shade)" StrokeThickness="1"/>
      <Ellipse Canvas.Left="15" Canvas.Top="23" Width="28" Height="19" Fill="$($p.muzzle)"/>
      <Ellipse Canvas.Left="7"  Canvas.Top="13" Width="14" Height="12" Fill="$($p.muzzle)" Opacity="0.55"/>
      <Ellipse Canvas.Left="37" Canvas.Top="13" Width="14" Height="12" Fill="$($p.muzzle)" Opacity="0.55"/>
$(New-Blush $p)
$(New-CuteEyes $p)
$(New-Snout $p 9 30)
"@
}

function New-FoxHead($p) {
    @"
      <Path Fill="$($p.ear)" Stroke="$($p.ear)" StrokeThickness="3.6" StrokeLineJoin="Round" Data="M8,20 L12,1 L26,12 Z"/>
      <Path Fill="$($p.ear)" Stroke="$($p.ear)" StrokeThickness="3.6" StrokeLineJoin="Round" Data="M50,20 L46,1 L32,12 Z"/>
      <Path Fill="#FF3A322E" Stroke="#FF3A322E" StrokeThickness="2.4" StrokeLineJoin="Round" Data="M11,9 L12,1 L18,6 Z"/>
      <Path Fill="#FF3A322E" Stroke="#FF3A322E" StrokeThickness="2.4" StrokeLineJoin="Round" Data="M47,9 L46,1 L40,6 Z"/>
      <Path Fill="$($p.earInner)" Stroke="$($p.earInner)" StrokeThickness="2.2" StrokeLineJoin="Round" Data="M13,16 L15,7 L21,12 Z"/>
      <Path Fill="$($p.earInner)" Stroke="$($p.earInner)" StrokeThickness="2.2" StrokeLineJoin="Round" Data="M45,16 L43,7 L37,12 Z"/>
      <Ellipse Canvas.Left="3" Canvas.Top="4" Width="52" Height="39" Fill="$($p.fur)" Stroke="$($p.shade)" StrokeThickness="1"/>
      <Path Fill="$($p.muzzle)" Data="M15,25 Q29,20 43,25 Q41,44 29,45 Q17,44 15,25 Z"/>
$(New-Blush $p)
$(New-CuteEyes $p)
$(New-Snout $p 8 30.5)
"@
}

function New-BunnyHead($p) {
    @"
      <Ellipse Canvas.Left="12" Canvas.Top="0" Width="12" Height="21" Fill="$($p.ear)" Stroke="$($p.shade)" StrokeThickness="1"/>
      <Ellipse Canvas.Left="34" Canvas.Top="0" Width="12" Height="21" Fill="$($p.ear)" Stroke="$($p.shade)" StrokeThickness="1"/>
      <Ellipse Canvas.Left="14.8" Canvas.Top="2.5" Width="6.4" Height="15.5" Fill="$($p.earInner)"/>
      <Ellipse Canvas.Left="36.8" Canvas.Top="2.5" Width="6.4" Height="15.5" Fill="$($p.earInner)"/>
      <Ellipse Canvas.Left="3" Canvas.Top="9" Width="52" Height="35" Fill="$($p.fur)" Stroke="$($p.shade)" StrokeThickness="1"/>
$(New-Blush $p)
$(New-CuteEyes $p)
      <Path Fill="$($p.nose)" Data="M25.5,30.5 Q29,29 32.5,30.5 Q29,35 25.5,30.5 Z"/>
      <Path Stroke="$($p.nose)" StrokeThickness="1.7" StrokeStartLineCap="Round" StrokeEndLineCap="Round"
            Data="M29,34 L29,35.6 M29,35.6 Q25.5,37.8 24,35.4 M29,35.6 Q32.5,37.8 34,35.4"/>
"@
}

function New-PenguinHead($p) {
    @"
      <Ellipse Canvas.Left="3" Canvas.Top="3" Width="52" Height="40" Fill="$($p.fur)" Stroke="$($p.shade)" StrokeThickness="1"/>
      <Path Fill="$($p.ear)" Opacity="0.6" Data="M8,28 Q2,20 6,12 Q12,17 13,27 Z"/>
      <Path Fill="$($p.ear)" Opacity="0.6" Data="M50,28 Q56,20 52,12 Q46,17 45,27 Z"/>
      <Path Fill="$($p.muzzle)" Data="M9,17 Q29,7 49,17 Q50,41 29,46 Q8,41 9,17 Z"/>
$(New-Blush $p)
$(New-CuteEyes $p)
      <Path Fill="$($p.nose)" Data="M23,30.5 L35,30.5 L29,37.5 Z"/>
"@
}

function New-TunaHead($p) {
    @"
      <Path Fill="$($p.ear)" Stroke="$($p.shade)" StrokeThickness="1" Data="M2,14 L13,26 L2,39 Q-1,26 2,14 Z"/>
      <Path Fill="$($p.ear)" Stroke="$($p.shade)" StrokeThickness="1" Data="M56,14 L45,26 L56,39 Q59,26 56,14 Z"/>
      <Path Fill="$($p.ear)" Stroke="$($p.shade)" StrokeThickness="1" Data="M21,5 Q29,-2 37,5 Z"/>
      <Ellipse Canvas.Left="5" Canvas.Top="3" Width="48" Height="40" Fill="$($p.fur)" Stroke="$($p.shade)" StrokeThickness="1"/>
      <Path Fill="$($p.muzzle)" Data="M9,26 Q29,18 49,26 Q47,43 29,45 Q11,43 9,26 Z"/>
      <Path Stroke="$($p.shade)" StrokeThickness="1.1" Opacity="0.5" Data="M9,12 Q29,7 49,12"/>
$(New-Blush $p)
$(New-CuteEyes $p)
      <Path Stroke="$($p.nose)" StrokeThickness="1.9" StrokeStartLineCap="Round" StrokeEndLineCap="Round"
            Data="M24,32.5 Q29,37 34,32.5"/>
"@
}

# Not an animal, and the only mascot that does not sit at the laptop: a ribbon
# of light that turns on the spot and drifts through its colours. Built from
# stroked arcs rather than a filled outline -- the top of one loop plus the
# bottom of the next is what reads as a helix, and a stroke keeps the band an
# even thickness at 58 px where a filled outline goes muddy.
#
# Everything the animation touches is named here: SpinS foreshortens it, SpinR
# adds the tilt, and the gradient stops are re-coloured in place. Measured
# against rotating the gradient axis and swapping pre-built frozen brushes; all
# three landed inside the run-to-run noise, so this one was picked for being the
# clearest to read.
function New-RibbonMascot($p) {
    @"
      <Canvas x:Name="RibbonRoot" Width="58" Height="60">
        <!-- The animals get visual mass from the laptop and paws they sit at.
             With those hidden the sash alone filled only about 60% of the
             canvas and read as small next to them, so the whole mark is scaled
             up to match. Applied here rather than baked into the coordinates so
             the traced geometry stays readable against the icon it came from. -->
        <Canvas.RenderTransform>
          <ScaleTransform ScaleX="1.18" ScaleY="1.18" CenterX="29" CenterY="33"/>
        </Canvas.RenderTransform>
        <Canvas.Resources>
          <!-- Three stops, not two: the mark runs magenta at the left edge,
               through a pale warm centre where the sash faces you, into purple
               where it turns away. A two-stop ramp lost the bright middle and
               the band stopped reading as a lit surface.
               The axis is 34 degrees, measured off the real icon by taking the
               centroid of its warm pixels and the centroid of its cool ones,
               rather than picked by eye. -->
          <LinearGradientBrush x:Key="RibbonBrush" StartPoint="0.08,0.22" EndPoint="0.92,0.78">
            <GradientStop x:Name="RibbonA" Color="$($p.warm)" Offset="0"/>
            <GradientStop x:Name="RibbonM" Color="$($p.spark)" Offset="0.42"/>
            <GradientStop x:Name="RibbonB" Color="$($p.cool)" Offset="1"/>
          </LinearGradientBrush>
          <!-- the cut end, running the other way so the back of the band reads
               as a face turned away from the light -->
          <LinearGradientBrush x:Key="RibbonBack" StartPoint="0,0" EndPoint="1,1">
            <GradientStop x:Name="RibbonC" Color="$($p.cool)" Offset="0"/>
            <GradientStop x:Name="RibbonD" Color="$($p.warm)" Offset="1"/>
          </LinearGradientBrush>
        </Canvas.Resources>
        <!-- The sphere sits behind the band and outside the turning group:
             carried along it swings out to the side and the mark reads as off
             balance, where a still sphere with the band turning past it reads
             as one thing moving in front of another. -->
        <Ellipse Canvas.Left="21" Canvas.Top="13" Width="16" Height="16">
          <Ellipse.Fill>
            <RadialGradientBrush GradientOrigin="0.34,0.28" Center="0.5,0.5" RadiusX="0.72" RadiusY="0.72">
              <GradientStop x:Name="OrbA" Color="$($p.spark)" Offset="0"/>
              <GradientStop x:Name="OrbB" Color="$($p.cool)" Offset="1"/>
            </RadialGradientBrush>
          </Ellipse.Fill>
        </Ellipse>
        <Canvas x:Name="RibbonGroup" Width="58" Height="60">
          <Canvas.RenderTransform>
            <TransformGroup>
              <ScaleTransform x:Name="SpinS" ScaleX="1" ScaleY="1" CenterX="29" CenterY="33"/>
              <RotateTransform x:Name="SpinR" Angle="0" CenterX="29" CenterY="33"/>
            </TransformGroup>
          </Canvas.RenderTransform>
          <!-- The Scout mark is a broad sash crossing the middle on the
               diagonal with a twist in it, and a sphere in the upper nook.

               Filled polygons with straight edges and a pinch at the twist,
               rather than a stroked centreline. A stroke has one width and
               round joins, so every version built that way read as a bent tube:
               what makes a ribbon look flat is straight edges and the pinch
               where it turns edge-on. Five earlier attempts are on the record:
               concentric loops read as a donut, a helix as a spring, two filled
               S outlines as crescents, and a single fat stroke as a tube.

               Coordinates come from tracing the real icon row by row and
               scoring candidates by silhouette overlap. This one sits at about
               three quarters, which is the point where chasing the number
               started making it look worse rather than better: the last of the
               difference is the internal fold, and a 58 px mascot cannot show
               that anyway. -->
          <!-- near half: facing you, so wide and bright -->
          <Path Fill="{StaticResource RibbonBrush}"
                Data="M 11,17 C 19,18 26,22 31,27 L 30,38 C 24,32 17,29 11,31 Z"/>
          <!-- far half, past the twist: turned away, so narrower and darker -->
          <Path Fill="{StaticResource RibbonBack}"
                Data="M 31,27 L 30,38 C 35,41 38,45 37,50 L 44,43
                      C 44,35 39,29 31,27 Z"/>
          <!-- the tail, dropping off the fold -->
          <Path Fill="{StaticResource RibbonBrush}"
                Data="M 37,50 C 37,45 35,41 30,38 L 27,46
                      C 30,48 31,51 30,54 Z"/>
          <!-- the cut end at the left, showing the back of the sash: it is what
               tells you this is a strip and not a solid shape -->
          <Path Fill="{StaticResource RibbonBack}"
                Data="M 11,17 C 8,19 8,29 11,31 C 13,29 13,19 11,17 Z"/>
        </Canvas>
        <!-- specular highlight, on top of everything -->
        <Ellipse Canvas.Left="25" Canvas.Top="15.5" Width="4.5" Height="3.5" Fill="#66FFFFFF"/>
      </Canvas>
"@
}

$MascotBuilders = @{
    quokka  = ${function:New-QuokkaHead}
    cat     = ${function:New-CatHead}
    dog     = ${function:New-DogHead}
    fox     = ${function:New-FoxHead}
    bunny   = ${function:New-BunnyHead}
    penguin = ${function:New-PenguinHead}
    tuna    = ${function:New-TunaHead}
    ribbon  = ${function:New-RibbonMascot}
}

# Ordered so the picker reads sensibly: the original mascot, then the cats with
# white first as requested, then everyone else.
$Mascots = [ordered]@{
    'quokka' = @{ Label = 'Quokka'; Species = 'quokka'; Palette = @{
        fur='#FFCE9163'; shade='#FF9A6440'; ear='#FFC0855A'; earInner='#FFF0B6B0'
        muzzle='#FFF6E4CA'; nose='#FF6B4433'; eye='#FF8A5A3C'; blush='#FFF08C8C'; paw='#FFC0855A' } }

    'cat-white' = @{ Label = 'Cat - White'; Species = 'cat'; Palette = @{
        fur='#FFFAF7F2'; shade='#FFC8BFB2'; ear='#FFF4EFE7'; earInner='#FFF8BFC4'
        muzzle='#FFFFFFFF'; nose='#FFEC9AA6'; eye='#FF7CC7EE'; blush='#FFF7A0AC'; paw='#FFF4EFE7' } }

    'cat-siamese' = @{ Label = 'Cat - Siamese'; Species = 'cat'; Palette = @{
        fur='#FFF3E7D2'; shade='#FF8A6C4E'; ear='#FF67503E'; earInner='#FFA07E68'
        muzzle='#FFF3E7D2'; nose='#FF7A5C4C'; eye='#FF6FC4EC'; blush='#FFE9A08E'; paw='#FF8A6C50'
        mask='#FF7A5F4A' } }

    'cat-calico' = @{ Label = 'Cat - Calico'; Species = 'cat'; Palette = @{
        fur='#FFFBF6ED'; shade='#FFBBA99A'; ear='#FFF4EBDD'; earInner='#FFF6BABA'
        muzzle='#FFFFFFFF'; nose='#FFEE94A0'; eye='#FFE8A93F'; blush='#FFF5A0A8'; paw='#FFF4EBDD'
        patchA='#FFF0A44E'; patchB='#FF4C4038' } }

    'cat-black' = @{ Label = 'Cat - Black'; Species = 'cat'; Palette = @{
        fur='#FF433D3A'; shade='#FF1E1B19'; ear='#FF3B3532'; earInner='#FF8E6A6A'
        muzzle='#FF433D3A'; nose='#FF2C2724'; eye='#FFE4D96A'; blush='#FF8A6470'; paw='#FF3B3532' } }

    'cat-russian' = @{ Label = 'Cat - Russian Blue'; Species = 'cat'; Palette = @{
        fur='#FFA3AFBE'; shade='#FF69768A'; ear='#FF97A3B4'; earInner='#FFD8B8BC'
        muzzle='#FFA3AFBE'; nose='#FF77838F'; eye='#FF84D394'; blush='#FFD79AA4'; paw='#FF97A3B4' } }

    'tuna' = @{ Label = 'Tuna'; Species = 'tuna'; Palette = @{
        fur='#FF5A8CB4'; shade='#FF33566F'; ear='#FF497BA0'; earInner='#FF497BA0'
        muzzle='#FFE4EEF6'; nose='#FF33566F'; eye='#FF9BD8E8'; blush='#FF7FB8D8'; paw='#FF497BA0' } }

    'shiba' = @{ Label = 'Shiba'; Species = 'dog'; Palette = @{
        fur='#FFE0A868'; shade='#FFA5703B'; ear='#FFD59B5C'; earInner='#FFF2CDA4'
        muzzle='#FFFAF1E3'; nose='#FF3A302B'; eye='#FF7A4F30'; blush='#FFF2A08E'; paw='#FFEDCFA8' } }

    'fox' = @{ Label = 'Fox'; Species = 'fox'; Palette = @{
        fur='#FFE8873F'; shade='#FFA85520'; ear='#FFDC7B36'; earInner='#FFF6BE96'
        muzzle='#FFFCF5EC'; nose='#FF3A302C'; eye='#FF8A4A22'; blush='#FFF2957F'; paw='#FFF7EEE3' } }

    'bunny' = @{ Label = 'Bunny'; Species = 'bunny'; Palette = @{
        fur='#FFF8F4EF'; shade='#FFC4B9AC'; ear='#FFF5F0E9'; earInner='#FFF8BCC2'
        muzzle='#FFFFFFFF'; nose='#FFEE93A2'; eye='#FF6B4A44'; blush='#FFF7A2AE'; paw='#FFF5F0E9' } }

    'penguin' = @{ Label = 'Penguin'; Species = 'penguin'; Palette = @{
        fur='#FF343945'; shade='#FF1A1D24'; ear='#FF464C5A'; earInner='#FF464C5A'
        muzzle='#FFFAF8F5'; nose='#FFF5AE44'; eye='#FF5E6B80'; blush='#FF8FA2C0'; paw='#FFF5AE44' } }

    # The odd one out, and deliberately so: no face, no laptop, no paws. Desk is
    # what tells Set-Mascot to hide the desk furniture the animals share.
    'ribbon' = @{ Label = 'Ribbon'; Species = 'ribbon'; Desk = $false; Palette = @{
        warm='#FFFF9E63'; cool='#FFB44BE0'; spark='#FFFFD9A8'; paw='#FFB44BE0' } }
}

$script:MascotHead = $null

function Set-Mascot([string]$id) {
    if (-not $Mascots.Contains($id)) { $id = 'quokka' }
    $def = $Mascots[$id]
    $build = $MascotBuilders[$def.Species]
    if (-not $build) { return }

    $inner = & $build $def.Palette
    # The x namespace has to be declared here or the x:Name on the animated
    # parts inside a head cannot be parsed.
    $frag = "<Canvas xmlns=`"http://schemas.microsoft.com/winfx/2006/xaml/presentation`" xmlns:x=`"http://schemas.microsoft.com/winfx/2006/xaml`" Width=`"58`" Height=`"60`">$inner</Canvas>"
    try {
        $head = [Windows.Markup.XamlReader]::Load((New-Object System.Xml.XmlNodeReader ([xml]$frag)))
    } catch {
        Write-Warning "Could not build mascot '$id': $($_.Exception.Message)"
        return
    }

    if ($script:MascotHead) { $MascotHost.Children.Remove($script:MascotHead) }
    $script:MascotHead = $head
    # Index 0 keeps the head behind the laptop and paws.
    $MascotHost.Children.Insert(0, $head)
    # The eye group is rebuilt with the head, so the animation's handle on it
    # has to be refreshed on every swap.
    $script:BlinkS = $head.FindName('BlinkS')
    # Same for the ribbon's own parts. These come back null for every animal,
    # which is exactly how the tick decides which body plan it is animating.
    $script:SpinR    = $head.FindName('SpinR')
    $script:SpinS    = $head.FindName('SpinS')
    $script:RibbonA  = $head.FindName('RibbonA')
    $script:RibbonM  = $head.FindName('RibbonM')
    $script:RibbonB  = $head.FindName('RibbonB')
    $script:RibbonC  = $head.FindName('RibbonC')
    $script:RibbonD  = $head.FindName('RibbonD')
    $script:OrbA     = $head.FindName('OrbA')
    $script:OrbB     = $head.FindName('OrbB')

    # A mascot that does not type has no use for the laptop or the paws. Default
    # is $true so every existing mascot keeps its desk without being edited.
    $wantsDesk = $true
    if ($def.Contains('Desk')) { $wantsDesk = [bool]$def.Desk }
    $Desk.Visibility = if ($wantsDesk) { 'Visible' } else { 'Collapsed' }

    $pawBrush = B $def.Palette.paw
    $LeftPaw.Fill  = $pawBrush
    $RightPaw.Fill = $pawBrush
    $script:MascotId = $id
    # Keep the tray silhouette in step with the toast. Guarded because the first
    # Set-Mascot runs during startup priming, before the tray exists.
    if ($script:TrayIcons) { Rebuild-TrayIcons $def.Species }
}

# ---------------------------------------------------------------------------
# Animation enable/disable, shared by the tray menu and the settings window.
# The guard stops the two controls bouncing updates off each other.
# ---------------------------------------------------------------------------
$script:AnimEnabled = [bool]$Config.animationEnabled
$script:SyncingAnim = $false
function Sync-AnimationEnabled([bool]$on, [switch]$Persist) {
    if ($script:SyncingAnim) { return }
    $script:SyncingAnim = $true
    try {
        $script:AnimEnabled = $on
        if (-not $on) {
            try { $anim.Stop() } catch { }
            try { Reset-Mascot } catch { }
        }
        if ($MenuPause -and $MenuPause.Checked -ne (-not $on)) { $MenuPause.Checked = -not $on }
        if ($script:SettingsAnimCheck -and $script:SettingsAnimCheck.IsChecked -ne $on) {
            $script:SettingsSuppress = $true
            try { $script:SettingsAnimCheck.IsChecked = $on }
            finally { $script:SettingsSuppress = $false }
        }
        if ($Persist) { [void](Save-Setting @{ animationEnabled = $on }) }
    } finally { $script:SyncingAnim = $false }
}

# ---------------------------------------------------------------------------
# Tray icon.
#
# The companion runs with no taskbar button and keeps its toast hidden most of
# the time, so without this there is no way to tell it is running at all. The
# icon doubles as the state indicator: it carries the same three colours as the
# toast, so a glance at the tray answers "is Scout busy?".
# ---------------------------------------------------------------------------
function New-TrayIcon([string]$hex, [string]$species = 'quokka') {
    # Drawn at runtime rather than shipped as a .ico, so the project stays a
    # single script with no binary assets to keep in sync.
    #
    # Colour carries the state, silhouette carries the mascot. At 16 px only the
    # outline survives, so each species is reduced to its most identifiable
    # feature - ear shape, or fins for the tuna.
    $fill = [System.Drawing.ColorTranslator]::FromHtml($hex)
    $edge = [System.Drawing.Color]::FromArgb(210,
        [Math]::Max(0, $fill.R - 70), [Math]::Max(0, $fill.G - 70), [Math]::Max(0, $fill.B - 70))

    $bmp = New-Object System.Drawing.Bitmap 32, 32
    $g   = [System.Drawing.Graphics]::FromImage($bmp)
    $g.SmoothingMode = [System.Drawing.Drawing2D.SmoothingMode]::AntiAlias
    $g.Clear([System.Drawing.Color]::Transparent)

    $brush = New-Object System.Drawing.SolidBrush $fill
    $pen   = New-Object System.Drawing.Pen $edge, 2.0
    $dark  = New-Object System.Drawing.SolidBrush $edge
    $pale  = New-Object System.Drawing.SolidBrush ([System.Drawing.Color]::FromArgb(235, 250, 250, 248))

    function Tri([single[]]$pts) {
        # Typed explicitly: an untyped @(...) is an Object[], and PowerShell 7
        # will not bind that to DrawPolygon's PointF[] overload the way 5.1
        # does. The launcher uses powershell.exe so this never fired in normal
        # use, but running the script under pwsh broke every species that draws
        # a polygon -- cat, fox, tuna and penguin all lost their tray icon.
        [System.Drawing.PointF[]]$poly = @(
            (New-Object System.Drawing.PointF $pts[0], $pts[1]),
            (New-Object System.Drawing.PointF $pts[2], $pts[3]),
            (New-Object System.Drawing.PointF $pts[4], $pts[5]))
        $g.FillPolygon($brush, $poly)
        $g.DrawPolygon($pen, $poly)
    }

    # head rect, then the eyes are placed relative to it
    $hx = 3.0; $hy = 8.0; $hw = 26.0; $hh = 22.0
    # The ribbon has no head and no eyes, so it opts out of the shared body plan
    # below rather than trying to squeeze into it.
    $faceless = ($species -eq 'ribbon')
    try {
        switch ($species) {
            'cat' {
                $hy = 9; $hh = 21
                Tri @(5,17, 9,2, 17,11)
                Tri @(27,17, 23,2, 15,11)
            }
            'dog' {
                $hy = 9; $hh = 21
                $g.FillEllipse($brush, 0.5, 8, 9, 15); $g.DrawEllipse($pen, 0.5, 8, 9, 15)
                $g.FillEllipse($brush, 22.5, 8, 9, 15); $g.DrawEllipse($pen, 22.5, 8, 9, 15)
            }
            'fox' {
                $hy = 10; $hh = 20
                Tri @(4,16, 7,1, 16,11)
                Tri @(28,16, 25,1, 16,11)
                $g.FillPolygon($dark, [System.Drawing.PointF[]]@(
                    (New-Object System.Drawing.PointF 6.2, 7.0),
                    (New-Object System.Drawing.PointF 7.0, 1.0),
                    (New-Object System.Drawing.PointF 11.0, 4.6)))
                $g.FillPolygon($dark, [System.Drawing.PointF[]]@(
                    (New-Object System.Drawing.PointF 25.8, 7.0),
                    (New-Object System.Drawing.PointF 25.0, 1.0),
                    (New-Object System.Drawing.PointF 21.0, 4.6)))
            }
            'bunny' {
                $hy = 13; $hh = 17
                $g.FillEllipse($brush, 8, 0, 6.5, 16); $g.DrawEllipse($pen, 8, 0, 6.5, 16)
                $g.FillEllipse($brush, 17.5, 0, 6.5, 16); $g.DrawEllipse($pen, 17.5, 0, 6.5, 16)
            }
            'penguin' {
                $hy = 5; $hh = 25
            }
            'tuna' {
                $hx = 6; $hy = 7; $hw = 20; $hh = 21
                Tri @(0.5,9, 8,17.5, 0.5,26)
                Tri @(31.5,9, 24,17.5, 31.5,26)
                Tri @(12,7, 16,0.5, 20,7)
            }
            'ribbon' {
                # The sash alone, filling the frame on the diagonal, with the
                # twist as a change of colour rather than a change of shape.
                # The sphere is dropped: at 16 px a circle above a body reads as
                # a head above shoulders no matter what the body is, and two
                # attempts at keeping it both came out looking like a generic
                # person icon. Tray glyphs are simplifications anyway -- the
                # tuna is fins, the penguin is a beak.
                $g.FillPolygon($brush, [System.Drawing.PointF[]]@(
                    (New-Object System.Drawing.PointF 1.0, 6.0),
                    (New-Object System.Drawing.PointF 18.0, 15.0),
                    (New-Object System.Drawing.PointF 17.0, 28.0),
                    (New-Object System.Drawing.PointF 1.0, 19.0)))
                $g.FillPolygon($dark, [System.Drawing.PointF[]]@(
                    (New-Object System.Drawing.PointF 18.0, 15.0),
                    (New-Object System.Drawing.PointF 17.0, 28.0),
                    (New-Object System.Drawing.PointF 30.0, 32.0),
                    (New-Object System.Drawing.PointF 31.0, 19.0)))
            }
            default {
                # quokka: soft round ears
                $g.FillEllipse($brush, 3.5, 1.5, 10, 11); $g.DrawEllipse($pen, 3.5, 1.5, 10, 11)
                $g.FillEllipse($brush, 18.5, 1.5, 10, 11); $g.DrawEllipse($pen, 18.5, 1.5, 10, 11)
            }
        }

        if (-not $faceless) {
            $g.FillEllipse($brush, $hx, $hy, $hw, $hh)
            $g.DrawEllipse($pen,   $hx, $hy, $hw, $hh)

            if ($species -eq 'penguin') {
                $g.FillEllipse($pale, ($hx + 4), ($hy + 4), ($hw - 8), ($hh - 5))
            }

            # Eyes, in the edge colour so they read on any taskbar background.
            $ey = $hy + $hh * 0.32
            $g.FillEllipse($dark, ($hx + $hw * 0.20), $ey, 5.4, 6.4)
            $g.FillEllipse($dark, ($hx + $hw * 0.60), $ey, 5.4, 6.4)

            if ($species -eq 'penguin') {
                $g.FillPolygon($dark, [System.Drawing.PointF[]]@(
                    (New-Object System.Drawing.PointF 13.0, 21.0),
                    (New-Object System.Drawing.PointF 19.0, 21.0),
                    (New-Object System.Drawing.PointF 16.0, 26.0)))
            }
        }
    } finally {
        $brush.Dispose(); $pen.Dispose(); $dark.Dispose(); $pale.Dispose(); $g.Dispose()
    }

    # GetHicon hands back an unmanaged handle; clone into a managed icon and
    # release it immediately so repeated calls cannot leak GDI handles.
    $h = $bmp.GetHicon()
    try {
        $icon = [System.Drawing.Icon]::FromHandle($h)
        return [System.Drawing.Icon]$icon.Clone()
    } finally {
        [void][ScoutNative]::DestroyIcon($h)
        $bmp.Dispose()
    }
}

# One icon per state for the current mascot. Switching mascot rebuilds the set
# and disposes the old one; switching state is just a cached swap.
$script:TrayIcons       = $null
$script:TrayIconSpecies = $null

function Rebuild-TrayIcons([string]$species) {
    if ($script:TrayIcons -and $script:TrayIconSpecies -eq $species) { return }
    $previous = $script:TrayIcons
    $script:TrayIcons = @{
        idle    = New-TrayIcon '#5B6780' $species
        working = New-TrayIcon '#4ADE80' $species
        alert   = New-TrayIcon '#FFD23D' $species
        ask     = New-TrayIcon '#5CC8F5' $species
    }
    $script:TrayIconSpecies = $species
    # Point the tray at the new set before freeing the old one.
    if ($Tray) {
        $state = if ($script:ThemeState) { $script:ThemeState } else { 'idle' }
        if (-not $script:TrayIcons.ContainsKey($state)) { $state = 'idle' }
        try { $Tray.Icon = $script:TrayIcons[$state] } catch { }
    }
    if ($previous) { foreach ($i in $previous.Values) { try { $i.Dispose() } catch { } } }
}

Rebuild-TrayIcons 'quokka'

$Tray = New-Object System.Windows.Forms.NotifyIcon
$Tray.Icon = $script:TrayIcons.idle
$Tray.Text = 'Scout Companion - ' + (T 'Idle')
$Tray.Visible = $true

function Set-TrayState([string]$state, [string]$detail) {
    if ($script:TrayIcons -and $script:TrayIcons.ContainsKey($state)) { $Tray.Icon = $script:TrayIcons[$state] }
    # NotifyIcon.Text is capped at 63 characters and throws above it.
    $t = "Scout Companion - $detail"
    if ($t.Length -gt 63) { $t = $t.Substring(0, 60) + '...' }
    $Tray.Text = $t
}

function Stop-Companion {
    # Every exit path funnels through here: an orphaned NotifyIcon lingers in
    # the tray until the user hovers over it, which looks like a crash.
    #
    # Flush first. The opacity slider coalesces its writes behind a 600 ms timer
    # so dragging it does not hammer the disk, which means a value set moments
    # before quitting was still sitting in that timer and died with the process.
    # From the outside that looks exactly like "settings don't save".
    try { Save-PendingOpacity } catch { }
    try { $timer.Stop() } catch { }
    try { $anim.Stop() }  catch { }
    try { if ($script:SettingsWindow) { $script:SettingsWindow.Close() } } catch { }
    try {
        $Tray.Visible = $false
        $Tray.Dispose()
        if ($script:TrayIcons) { foreach ($i in $script:TrayIcons.Values) { $i.Dispose() } }
    } catch { }
    try { $Window.Close() } catch { }
}

# ---------------------------------------------------------------------------
# Start-with-Scout.
#
# Watch-Scout.ps1 is the piece that ties the companion's lifetime to the agent,
# so "start automatically" means putting a shortcut to the watcher in the user's
# Startup folder. That is a per-user file with no registry writes and no admin
# rights, and the checkbox reads the real state of the folder rather than a
# remembered flag, so editing it by hand outside the app still works.
# ---------------------------------------------------------------------------
$WatcherPath = Join-Path $ScriptDir 'Watch-Scout.ps1'
$StartupLink = Join-Path ([Environment]::GetFolderPath('Startup')) 'Scout Companion.lnk'

function Test-AutoStart { return (Test-Path $StartupLink) }

function Set-AutoStart([bool]$on) {
    try {
        if (-not $on) {
            if (Test-Path $StartupLink) { Remove-Item $StartupLink -Force }
            return $true
        }
        if (-not (Test-Path $WatcherPath)) { return $false }
        $shell = New-Object -ComObject WScript.Shell
        try {
            $lnk = $shell.CreateShortcut($StartupLink)
            $lnk.TargetPath = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
            $lnk.Arguments  = "-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File `"$WatcherPath`""
            $lnk.WorkingDirectory = $ScriptDir
            $lnk.Description = 'Starts Scout Companion when Microsoft Scout is running'
            $lnk.Save()
        } finally {
            [void][System.Runtime.InteropServices.Marshal]::ReleaseComObject($shell)
        }
        return (Test-Path $StartupLink)
    } catch {
        Write-Warning "Could not update the Startup shortcut: $($_.Exception.Message)"
        return $false
    }
}

# ---------------------------------------------------------------------------
# Settings window.
# ---------------------------------------------------------------------------
$script:SettingsWindow    = $null
$script:SettingsAnimCheck = $null
$script:SettingsSuppress  = $false
$script:OpacitySaveTimer  = $null
$script:OpacityPendingValue = 1.0
$script:SelfProc          = [System.Diagnostics.Process]::GetCurrentProcess()

# Applies the Startup checkbox, and snaps it back if the folder write failed so
# the control never claims something that did not happen.
function Apply-AutoStartFromUI {
    if ($script:SettingsSuppress) { return }
    if (-not $script:SettingsAutoCheck) { return }
    $want = [bool]$script:SettingsAutoCheck.IsChecked
    if (Set-AutoStart $want) { return }
    $script:SettingsSuppress = $true
    try { $script:SettingsAutoCheck.IsChecked = Test-AutoStart }
    finally { $script:SettingsSuppress = $false }
    $script:SettingsAutoHint.Text = T 'Could not update the Startup folder. Check that you can write to it.'
}

[xml]$settingsXaml = @'
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
        xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        Title="Scout Companion settings" Width="410" SizeToContent="Height"
        ResizeMode="NoResize" WindowStartupLocation="CenterScreen"
        Background="#FF1B1F2A" Foreground="#FFE6EAF2" ShowInTaskbar="True">
  <Window.Resources>
    <Style TargetType="TextBlock">
      <Setter Property="Foreground" Value="#FFE6EAF2"/>
      <Setter Property="FontSize" Value="12.5"/>
    </Style>
    <Style TargetType="CheckBox">
      <Setter Property="Foreground" Value="#FFE6EAF2"/>
      <Setter Property="FontSize" Value="12.5"/>
      <Setter Property="Cursor" Value="Hand"/>
    </Style>
    <!-- The stock ComboBox chrome is light and ignores a plain Background
         setter, which leaves near-white text on a near-white box. Templating
         both the box and its items is the only way to theme it without taking
         a dependency. -->
    <Style TargetType="ComboBox">
      <Setter Property="Foreground" Value="#FFE6EAF2"/>
      <Setter Property="FontSize" Value="12.5"/>
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="ComboBox">
            <Grid>
              <ToggleButton Focusable="False" ClickMode="Press"
                            IsChecked="{Binding IsDropDownOpen, Mode=TwoWay, RelativeSource={RelativeSource TemplatedParent}}">
                <ToggleButton.Template>
                  <ControlTemplate TargetType="ToggleButton">
                    <Border x:Name="Chrome" Background="#FF232838" BorderBrush="#FF3A4358"
                            BorderThickness="1" CornerRadius="4">
                      <Path HorizontalAlignment="Right" VerticalAlignment="Center" Margin="0,0,9,0"
                            Data="M0,0 L4,4.5 L8,0 Z" Fill="#FF9AA6BE"/>
                    </Border>
                    <ControlTemplate.Triggers>
                      <Trigger Property="IsMouseOver" Value="True">
                        <Setter TargetName="Chrome" Property="Background" Value="#FF2C3346"/>
                      </Trigger>
                    </ControlTemplate.Triggers>
                  </ControlTemplate>
                </ToggleButton.Template>
              </ToggleButton>
              <ContentPresenter Margin="9,0,26,0" VerticalAlignment="Center" IsHitTestVisible="False"
                                Content="{TemplateBinding SelectionBoxItem}"
                                ContentTemplate="{TemplateBinding SelectionBoxItemTemplate}"
                                TextElement.Foreground="{TemplateBinding Foreground}"/>
              <Popup IsOpen="{TemplateBinding IsDropDownOpen}" Placement="Bottom" Focusable="False"
                     AllowsTransparency="True" PopupAnimation="Fade">
                <Border Background="#FF232838" BorderBrush="#FF3A4358" BorderThickness="1"
                        CornerRadius="4" MinWidth="{TemplateBinding ActualWidth}" MaxHeight="260">
                  <ScrollViewer><StackPanel IsItemsHost="True"/></ScrollViewer>
                </Border>
              </Popup>
            </Grid>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>
    <Style TargetType="ComboBoxItem">
      <Setter Property="Foreground" Value="#FFE6EAF2"/>
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="ComboBoxItem">
            <Border x:Name="Row" Background="Transparent" Padding="9,5">
              <ContentPresenter TextElement.Foreground="{TemplateBinding Foreground}"/>
            </Border>
            <ControlTemplate.Triggers>
              <Trigger Property="IsHighlighted" Value="True">
                <Setter TargetName="Row" Property="Background" Value="#FF35405A"/>
              </Trigger>
              <Trigger Property="IsSelected" Value="True">
                <Setter TargetName="Row" Property="Background" Value="#FF2E7D46"/>
              </Trigger>
            </ControlTemplate.Triggers>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>
    <Style x:Key="Hint" TargetType="TextBlock">
      <Setter Property="Foreground" Value="#FF8A93A6"/>
      <Setter Property="FontSize" Value="11"/>
      <Setter Property="TextWrapping" Value="Wrap"/>
      <Setter Property="Margin" Value="24,3,0,0"/>
    </Style>
    <Style x:Key="Section" TargetType="TextBlock">
      <Setter Property="Foreground" Value="#FF6E7A94"/>
      <Setter Property="FontSize" Value="10.5"/>
      <Setter Property="FontWeight" Value="SemiBold"/>
      <Setter Property="Margin" Value="0,0,0,8"/>
    </Style>
  </Window.Resources>

  <StackPanel Margin="18,16,18,14">

    <TextBlock Style="{StaticResource Section}" Text="STARTUP"/>
    <CheckBox x:Name="AutoStartCheck" Content="Start automatically with Scout"/>
    <TextBlock x:Name="AutoStartHint" Style="{StaticResource Hint}"
               Text="Adds a shortcut to your Startup folder. The watcher launches the companion when Scout starts, and the companion closes itself shortly after Scout quits."/>

    <Border Height="1" Background="#FF2A3142" Margin="0,14,0,14"/>

    <TextBlock Style="{StaticResource Section}" Text="APPEARANCE"/>
    <CheckBox x:Name="AnimCheck" Content="Animate the mascot"/>
    <TextBlock Style="{StaticResource Hint}"
               Text="Turning this off leaves the mascot in a resting pose and stops its timer entirely."/>
    <DockPanel Margin="0,12,0,0" LastChildFill="True">
      <TextBlock Text="Mascot" Width="120" Foreground="#FF9AA6BE" VerticalAlignment="Center" DockPanel.Dock="Left"/>
      <ComboBox x:Name="MascotPicker" Height="26" Cursor="Hand"/>
    </DockPanel>
    <DockPanel Margin="0,12,0,0" LastChildFill="True">
      <TextBlock Text="Opacity" Width="120" Foreground="#FF9AA6BE" VerticalAlignment="Center" DockPanel.Dock="Left"/>
      <TextBlock x:Name="OpacityValue" Text="100%" Width="46" Foreground="#FFE6EAF2" VerticalAlignment="Center"
                 TextAlignment="Right" DockPanel.Dock="Right"/>
      <Slider x:Name="OpacitySlider" Minimum="0.35" Maximum="1.0" Value="1.0"
              TickFrequency="0.05" IsSnapToTickEnabled="True" VerticalAlignment="Center" Cursor="Hand"/>
    </DockPanel>

    <Border Height="1" Background="#FF2A3142" Margin="0,14,0,14"/>

    <TextBlock Style="{StaticResource Section}" Text="THIS PROCESS"/>
    <Grid Margin="0,0,0,0">
      <Grid.ColumnDefinitions>
        <ColumnDefinition Width="Auto"/>
        <ColumnDefinition Width="*"/>
      </Grid.ColumnDefinitions>
      <Grid.RowDefinitions>
        <RowDefinition Height="Auto"/>
        <RowDefinition Height="Auto"/>
        <RowDefinition Height="Auto"/>
      </Grid.RowDefinitions>
      <TextBlock Grid.Row="0" Grid.Column="0" Text="Memory" Width="120" Foreground="#FF9AA6BE"/>
      <TextBlock Grid.Row="0" Grid.Column="1" x:Name="MemText" Text="-"/>
      <TextBlock Grid.Row="1" Grid.Column="0" Text="CPU (of one core)" Width="120" Foreground="#FF9AA6BE" Margin="0,5,0,0"/>
      <TextBlock Grid.Row="1" Grid.Column="1" x:Name="CpuText" Text="-" Margin="0,5,0,0"/>
      <TextBlock Grid.Row="2" Grid.Column="0" Text="Uptime" Width="120" Foreground="#FF9AA6BE" Margin="0,5,0,0"/>
      <TextBlock Grid.Row="2" Grid.Column="1" x:Name="UpText" Text="-" Margin="0,5,0,0"/>
    </Grid>

    <StackPanel Orientation="Horizontal" HorizontalAlignment="Right" Margin="0,18,0,0">
      <Button x:Name="CloseSettingsBtn" Content="Close" Width="88" Height="28"
              Background="#FF2A3142" Foreground="#FFE6EAF2" BorderThickness="0" Cursor="Hand"/>
    </StackPanel>
  </StackPanel>
</Window>
'@

function Show-SettingsWindow {
    if ($script:SettingsWindow) {
        try { $script:SettingsWindow.Activate(); return } catch { $script:SettingsWindow = $null }
    }

    $sw = [Windows.Markup.XamlReader]::Load((New-Object System.Xml.XmlNodeReader (Convert-XamlText $settingsXaml)))

    # Every control the event handlers touch is held at script scope: a
    # PowerShell event handler runs long after its defining function has
    # returned, and cannot see that function's locals.
    $script:SettingsWindow    = $sw
    $script:SettingsAutoCheck = $sw.FindName('AutoStartCheck')
    $script:SettingsAutoHint  = $sw.FindName('AutoStartHint')
    $script:SettingsAnimCheck = $sw.FindName('AnimCheck')
    $script:SettingsMemText   = $sw.FindName('MemText')
    $script:SettingsCpuText   = $sw.FindName('CpuText')
    $script:SettingsUpText    = $sw.FindName('UpText')
    $script:SettingsMascot    = $sw.FindName('MascotPicker')
    $script:SettingsOpacity   = $sw.FindName('OpacitySlider')
    $script:SettingsOpacityText = $sw.FindName('OpacityValue')
    $closeBtn                 = $sw.FindName('CloseSettingsBtn')

    # Reflect reality, not a remembered flag. Set before the handlers are
    # attached so priming the controls cannot fire them.
    $script:SettingsAutoCheck.IsChecked = Test-AutoStart
    if (-not (Test-Path $WatcherPath)) {
        $script:SettingsAutoCheck.IsEnabled = $false
        $script:SettingsAutoHint.Text = T 'Watch-Scout.ps1 is missing from {0}, so this cannot be turned on.' $ScriptDir
    }
    $script:SettingsAnimCheck.IsChecked = $script:AnimEnabled

    # Opacity. Primed before the handler is attached so setting the initial
    # value does not fire a save.
    $script:SettingsOpacity.Value = [double]$Config.opacity
    $script:SettingsOpacityText.Text = '{0:N0}%' -f ([double]$Config.opacity * 100)
    $script:SettingsOpacity.Add_ValueChanged({
        $v = Set-ToastOpacity ([double]$script:SettingsOpacity.Value)
        $script:SettingsOpacityText.Text = '{0:N0}%' -f ($v * 100)
        # Dragging a slider fires this continuously, so coalesce the writes and
        # persist once the value has settled. Anything that ends the process has
        # to flush this first: see Save-PendingOpacity, called from both the
        # settings window's Closed handler and Stop-Companion.
        $script:OpacityPendingValue = $v
        if (-not $script:OpacitySaveTimer) {
            $script:OpacitySaveTimer = New-Object System.Windows.Threading.DispatcherTimer
            $script:OpacitySaveTimer.Interval = [TimeSpan]::FromMilliseconds(600)
            $script:OpacitySaveTimer.Add_Tick({ Save-PendingOpacity })
        }
        $script:OpacitySaveTimer.Stop()
        $script:OpacitySaveTimer.Start()
    })

    # Mascot picker. Tag carries the id so the label stays free to be prose.
    foreach ($key in $Mascots.Keys) {
        $item = New-Object System.Windows.Controls.ComboBoxItem
        $item.Content = $Mascots[$key].Label
        $item.Tag     = $key
        [void]$script:SettingsMascot.Items.Add($item)
        if ($key -eq $script:MascotId) { $script:SettingsMascot.SelectedItem = $item }
    }
    if (-not $script:SettingsMascot.SelectedItem -and $script:SettingsMascot.Items.Count) {
        $script:SettingsMascot.SelectedIndex = 0
    }
    $script:SettingsMascot.Add_SelectionChanged({
        if ($script:SettingsSuppress) { return }
        $sel = $script:SettingsMascot.SelectedItem
        if (-not $sel -or -not $sel.Tag) { return }
        if ($sel.Tag -eq $script:MascotId) { return }
        Set-Mascot ([string]$sel.Tag)
        [void](Save-Setting @{ mascot = [string]$sel.Tag })
    })

    # Checked/Unchecked rather than Click: UI Automation's TogglePattern sets
    # IsChecked directly without raising Click, so a screen reader or voice
    # control toggling the box would otherwise flip the visuals and silently
    # fail to apply the setting.
    $script:SettingsAutoCheck.Add_Checked({ Apply-AutoStartFromUI })
    $script:SettingsAutoCheck.Add_Unchecked({ Apply-AutoStartFromUI })
    $script:SettingsAnimCheck.Add_Checked({
        if (-not $script:SettingsSuppress) { Sync-AnimationEnabled $true -Persist }
    })
    $script:SettingsAnimCheck.Add_Unchecked({
        if (-not $script:SettingsSuppress) { Sync-AnimationEnabled $false -Persist }
    })

    # Live resource readout, refreshed only while this window is open.
    $script:SettingsLastCpu = $script:SelfProc.TotalProcessorTime
    $script:SettingsLastAt  = [datetime]::UtcNow
    $script:SettingsResTimer = New-Object System.Windows.Threading.DispatcherTimer
    $script:SettingsResTimer.Interval = [TimeSpan]::FromMilliseconds(1000)
    $script:SettingsResTimer.Add_Tick({
        try {
            $script:SelfProc.Refresh()
            $now    = [datetime]::UtcNow
            $cpuMs  = ($script:SelfProc.TotalProcessorTime - $script:SettingsLastCpu).TotalMilliseconds
            $wallMs = ($now - $script:SettingsLastAt).TotalMilliseconds
            $script:SettingsLastCpu = $script:SelfProc.TotalProcessorTime
            $script:SettingsLastAt  = $now

            $script:SettingsMemText.Text = '{0:N0} MB' -f ($script:SelfProc.WorkingSet64 / 1MB)
            if ($wallMs -gt 0) { $script:SettingsCpuText.Text = '{0:N2} %' -f ($cpuMs / $wallMs * 100) }
            $up = [datetime]::Now - $script:SelfProc.StartTime
            $script:SettingsUpText.Text = if ($up.TotalHours -ge 1) {
                '{0}h {1}m' -f [int]$up.TotalHours, $up.Minutes
            } else {
                '{0}m {1}s' -f $up.Minutes, $up.Seconds
            }
        } catch { }
    })
    $script:SettingsResTimer.Start()

    $closeBtn.Add_Click({ if ($script:SettingsWindow) { $script:SettingsWindow.Close() } })
    $sw.Add_Closed({
        # Drain the debounced opacity write before the window goes: closing the
        # settings window right after moving the slider otherwise dropped it.
        try { Save-PendingOpacity } catch { }
        try { $script:SettingsResTimer.Stop() } catch { }
        $script:SettingsWindow    = $null
        $script:SettingsAnimCheck = $null
    })

    # Match the dark body with a dark title bar instead of leaving a bright
    # strip above it. 20 is DWMWA_USE_IMMERSIVE_DARK_MODE on current Windows 11;
    # 19 was the pre-release attribute on older Windows 10 builds.
    $sw.Add_SourceInitialized({
        try {
            $hwnd = (New-Object System.Windows.Interop.WindowInteropHelper $script:SettingsWindow).Handle
            $on = 1
            if ([ScoutNative]::DwmSetWindowAttribute($hwnd, 20, [ref]$on, 4) -ne 0) {
                [void][ScoutNative]::DwmSetWindowAttribute($hwnd, 19, [ref]$on, 4)
            }
        } catch { }
    })

    # Reuse the tray artwork so the window carries the mascot rather than the
    # generic PowerShell icon.
    try {
        $sw.Icon = [System.Windows.Interop.Imaging]::CreateBitmapSourceFromHIcon(
            $script:TrayIcons.idle.Handle,
            [System.Windows.Int32Rect]::Empty,
            [System.Windows.Media.Imaging.BitmapSizeOptions]::FromEmptyOptions())
    } catch { }

    $sw.Show()
    $sw.Activate()
}

$MenuShow  = New-Object System.Windows.Forms.ToolStripMenuItem (T 'Show toast')
$MenuOpen  = New-Object System.Windows.Forms.ToolStripMenuItem (T 'Open Scout')
$MenuPause = New-Object System.Windows.Forms.ToolStripMenuItem (T 'Pause animation')
$MenuSet   = New-Object System.Windows.Forms.ToolStripMenuItem (T 'Settings...')
$MenuExit  = New-Object System.Windows.Forms.ToolStripMenuItem (T 'Exit')
$MenuPause.CheckOnClick = $true
$MenuPause.Checked = -not $script:AnimEnabled

$MenuShow.Add_Click({
    # A pin, not a nudge. "Show" has to work even when nothing is happening --
    # a click that silently did nothing because the automatic rules disagreed
    # would look broken. "Hide" clears the pin and dismisses, exactly like the
    # toast's own close button.
    if ($script:Pinned) {
        $script:Pinned = $false
        $script:Hidden = $true
        try { $Window.Hide() } catch { }
    } else {
        $script:Pinned = $true
        $script:Hidden = $false
    }
})
$MenuOpen.Add_Click({ Focus-AgentSession })
$MenuPause.Add_Click({
    # CheckOnClick has already flipped Checked by the time this runs.
    Sync-AnimationEnabled (-not $MenuPause.Checked) -Persist
})
$MenuSet.Add_Click({ Show-SettingsWindow })
$MenuExit.Add_Click({ Stop-Companion })

$TrayMenu = New-Object System.Windows.Forms.ContextMenuStrip
[void]$TrayMenu.Items.Add($MenuShow)
[void]$TrayMenu.Items.Add($MenuOpen)
[void]$TrayMenu.Items.Add((New-Object System.Windows.Forms.ToolStripSeparator))
[void]$TrayMenu.Items.Add($MenuPause)
[void]$TrayMenu.Items.Add($MenuSet)
[void]$TrayMenu.Items.Add((New-Object System.Windows.Forms.ToolStripSeparator))
[void]$TrayMenu.Items.Add($MenuExit)
$Tray.ContextMenuStrip = $TrayMenu

# Double-clicking the tray icon brings the agent forward, matching the toast's
# "Open" button.
$Tray.Add_MouseDoubleClick({ Focus-AgentSession })

# ---------------------------------------------------------------------------
# Mascot animation: a dedicated timer drives it frame-by-frame.
#
#   working  => bobbing body, alternating "typing" paws, focused eyes
#   waiting  => head tilts, eyes open wide, glow pulses
#   idle     => slow breathing, softer eyes
#
# Blinking runs on top of all three at randomised intervals, because a face
# that never blinks reads as a picture rather than a character.
#
# The timer is started and stopped with the toast (see the poll loop below):
# animating a window nobody can see costs real CPU for nothing.
# ---------------------------------------------------------------------------
$script:Phase = 0.0
$script:Busy  = $false
$script:PrevBusy = $false
$script:BlinkS = $null          # rebound by Set-Mascot on every mascot swap
$script:BlinkIn = 24            # frames until the next blink
$script:BlinkStep = -1          # index into the blink sequence, -1 when open
$script:EyeBase = 1.0           # openness the eyes return to for this state
# Get-Random is a cmdlet invocation; this runs inside a frame tick, so use the
# plain .NET generator instead.
$script:Rng = New-Object System.Random

# Handles on the ribbon mascot, null for every animal. Set-Mascot rebinds them.
$script:SpinR = $null; $script:SpinS = $null
$script:RibbonA = $null; $script:RibbonM = $null; $script:RibbonB = $null
$script:RibbonC = $null; $script:RibbonD = $null
$script:OrbA = $null; $script:OrbB = $null
$script:Hue = 0.06
$script:SpinPhase = 0.0

# HSV to Color, written out longhand because this runs four times a frame and
# System.Drawing's converter would mean a managed<->GDI hop for each one.
function Hue-Color([double]$h, [double]$s, [double]$v) {
    $h = $h - [Math]::Floor($h)          # wrap into 0..1
    $i = [int][Math]::Floor($h * 6) % 6
    $f = $h * 6 - [Math]::Floor($h * 6)
    $p = $v * (1 - $s)
    $q = $v * (1 - $f * $s)
    $t = $v * (1 - (1 - $f) * $s)
    switch ($i) {
        0 { $r=$v; $g=$t; $b=$p }
        1 { $r=$q; $g=$v; $b=$p }
        2 { $r=$p; $g=$v; $b=$t }
        3 { $r=$p; $g=$q; $b=$v }
        4 { $r=$t; $g=$p; $b=$v }
        default { $r=$v; $g=$p; $b=$q }
    }
    return [System.Windows.Media.Color]::FromRgb([byte]($r*255), [byte]($g*255), [byte]($b*255))
}

# Squash-and-open, held one frame at the bottom so the blink is visible at
# 12 fps without looking like a dropped frame.
$BlinkFrames = @(0.55, 0.10, 0.10, 0.60)

function Reset-Mascot {
    # Neutral pose, used when the animation is paused or switched off.
    $BodyT.Y = 0; $BodyT.X = 0
    $BodyS.ScaleX = 1.0; $BodyS.ScaleY = 1.0
    $BodyR.Angle = 0
    $LeftPawT.Y = 0; $RightPawT.Y = 0
    if ($script:BlinkS) { $script:BlinkS.ScaleY = 1.0 }
    # The ribbon parks facing forward rather than mid-turn, which would read as
    # a frozen frame rather than a resting pose.
    if ($script:SpinR) { $script:SpinR.Angle = 0 }
    if ($script:SpinS) { $script:SpinS.ScaleX = 1.0; $script:SpinS.ScaleY = 1.0 }
    $script:BlinkStep = -1
}

$anim = New-Object System.Windows.Threading.DispatcherTimer
$anim.Interval = [TimeSpan]::FromMilliseconds([int]$Config.animIntervalMs)
# Phase steps are scaled so the mascot moves at the same speed regardless of the
# configured frame rate.
$script:PhaseScale = [double]$Config.animIntervalMs / 50.0
# Frames per second, used to keep blink timing in real seconds rather than frames.
$script:Fps = 1000.0 / [double]$Config.animIntervalMs
$anim.Add_Tick({
    if ($script:Pending -or $script:Asking) {
        # gentle attention pulse on the glow, whichever colour it is wearing
        $script:Phase += 0.20 * $script:PhaseScale
        $puls = ([Math]::Sin($script:Phase * 3.0) + 1.0) / 2.0
        $RootGlow.BlurRadius = 16 + $puls * 18
        $RootGlow.Opacity    = 0.55 + $puls * 0.4
        # peeks up and tilts, waiting on you - eyes wide open
        $BodyT.Y = [Math]::Sin($script:Phase) * 0.8
        $BodyT.X = 0
        $BodyS.ScaleX = 1.0; $BodyS.ScaleY = 1.0
        $BodyR.Angle = if ($script:Asking) { [Math]::Sin($script:Phase * 0.6) * 5.0 } else { 0 }
        $LeftPawT.Y = 0; $RightPawT.Y = 0
        $script:EyeBase = 1.18
    }
    elseif ($script:Busy) {
        $script:Phase += 0.32 * $script:PhaseScale
        $BodyT.Y     = [Math]::Sin($script:Phase * 2.0) * 1.6
        $BodyT.X     = [Math]::Sin($script:Phase) * 0.6
        $BodyS.ScaleX = 1.0
        $BodyS.ScaleY = 1.0
        # nods along with the typing, a beat slower than the paws
        $BodyR.Angle = [Math]::Sin($script:Phase * 1.5) * 2.5
        $LeftPawT.Y  = -[Math]::Max(0, [Math]::Sin($script:Phase * 6.0)) * 2.4
        $RightPawT.Y = -[Math]::Max(0, [Math]::Sin($script:Phase * 6.0 + [Math]::PI)) * 2.4
        # slightly narrowed: concentrating rather than staring
        $script:EyeBase = 0.94
    } else {
        $script:Phase += 0.04 * $script:PhaseScale
        $breathe = 1.0 + [Math]::Sin($script:Phase) * 0.035
        $BodyS.ScaleX = $breathe
        $BodyS.ScaleY = $breathe
        $BodyT.Y = [Math]::Sin($script:Phase) * 0.6
        $BodyT.X = 0
        $BodyR.Angle = [Math]::Sin($script:Phase * 0.5) * 1.2
        $LeftPawT.Y = 0
        $RightPawT.Y = 0
        # relaxed, a touch sleepy
        $script:EyeBase = 0.86
    }

    # --- ribbon ---------------------------------------------------------------
    # Only the ribbon mascot binds these, so the animals skip the whole block.
    if ($script:SpinR) {
        # The desk transforms pivot on the laptop base at y=52, which swings a
        # mascot that has no laptop. Neutralise them and let the ribbon's own
        # transforms carry the motion.
        $BodyR.Angle = 0; $BodyT.X = 0
        $BodyS.ScaleX = 1.0; $BodyS.ScaleY = 1.0

        # Rates: spin is radians per frame, hue is turns of the colour wheel per
        # frame. Multiply either by PhaseScale * fps to read it in real time --
        # busy turns once every 3.5 seconds and comes round the wheel in 8, idle
        # takes 14 and 30. Note the band reads wide-narrow-wide twice per
        # revolution, since you see the front, the edge, the back, the edge.
        # The first pass ran the hue 25x faster than this and strobed through the
        # whole wheel in a second and a quarter, which was unpleasant to sit
        # next to.
        if ($script:Pending -or $script:Asking) { $spin = 0.052; $hueRate = 0.0100; $pin = $true }
        elseif ($script:Busy)                   { $spin = 0.090; $hueRate = 0.0060; $pin = $false }
        else                                    { $spin = 0.022; $hueRate = 0.0018; $pin = $false }

        $script:SpinPhase += $spin * $script:PhaseScale

        # A band turning about its own vertical axis does not rotate on screen --
        # it foreshortens. Projected into 2D that is exactly ScaleX = cos(theta),
        # which passes through zero and goes negative, mirroring the band as its
        # far side comes round. Driving a RotateTransform instead made it tumble
        # end over end like a steering wheel, which is a different object.
        #
        # The floor stops it collapsing to an invisible sliver when it is
        # edge-on: true in perspective, but a ribbon has thickness, and a live
        # screenshot caught it at 0.28 looking like a stray purple squiggle
        # rather than a mascot.
        $c = [Math]::Cos($script:SpinPhase)
        $mag = [Math]::Max(0.42, [Math]::Abs($c))
        $script:SpinS.ScaleX = if ($c -lt 0) { -$mag } else { $mag }
        # Just enough tilt to keep it from looking like a machine part.
        $script:SpinR.Angle = [Math]::Sin($script:SpinPhase * 0.5) * 6.0

        # The toast already says what state it is in through the glow colour, so
        # a free-running rainbow would argue with it. Left alone the hue drifts
        # wherever it likes; the moment something is waiting on you it is pinned
        # to a narrow shimmer around that state's own colour and reinforces the
        # signal instead of competing with it.
        $script:Hue += $hueRate * $script:PhaseScale
        $h = if (-not $pin) { $script:Hue }
             elseif ($script:Pending) { 0.11 + [Math]::Sin($script:Hue * 6.283) * 0.035 }   # amber
             else                     { 0.52 + [Math]::Sin($script:Hue * 6.283) * 0.035 }   # cyan

        # Every stop moves together, front face and back alike. Leaving the
        # middle stop and the back-face pair fixed while the outer two drifted
        # made the sash look like it was lit by two different lamps.
        $script:RibbonA.Color = Hue-Color $h            0.62 1.00
        $script:RibbonM.Color = Hue-Color ($h + 0.06)   0.34 1.00
        $script:RibbonB.Color = Hue-Color ($h + 0.17)   0.78 0.92
        # the back of the sash: same hues, run the other way and dimmer, because
        # it is the face turned away from the light
        $script:RibbonC.Color = Hue-Color ($h + 0.17)   0.80 0.72
        $script:RibbonD.Color = Hue-Color $h            0.66 0.82
        $script:OrbA.Color    = Hue-Color ($h - 0.04)   0.28 1.00
        $script:OrbB.Color    = Hue-Color ($h + 0.17)   0.72 0.95
    }

    # --- blink ---------------------------------------------------------------
    if ($script:BlinkS) {
        if ($script:BlinkStep -ge 0) {
            $script:BlinkS.ScaleY = $script:EyeBase * $BlinkFrames[$script:BlinkStep]
            $script:BlinkStep++
            if ($script:BlinkStep -ge $BlinkFrames.Count) { $script:BlinkStep = -1 }
        } else {
            $script:BlinkS.ScaleY = $script:EyeBase
            $script:BlinkIn--
            if ($script:BlinkIn -le 0) {
                $script:BlinkStep = 0
                # 2.5-6 s apart, so it never falls into a mechanical rhythm.
                $script:BlinkIn = [int]($script:Fps * (2.5 + $script:Rng.NextDouble() * 3.5))
            }
        }
    }
})

# ---------------------------------------------------------------------------
# Main loop: poll events + decide visibility + render.
# ---------------------------------------------------------------------------
# Puts the name of the asking conversation under the prompt's heading, or hides
# the line when there is nothing worth saying.
function Set-PermFrom($item) {
    $from = (Where-From $item) -replace '^\s*-\s*',''
    if ($from) {
        $PermFrom.Text = $from.Trim()
        $PermFrom.Visibility = 'Visible'
    } else {
        $PermFrom.Text = ''
        $PermFrom.Visibility = 'Collapsed'
    }
}

# The "(+2)" after the header. One card can only show one prompt, so the count
# has to speak for everything else still waiting - approvals and questions
# together. Counting only the shown prompt's own kind was worse than no count
# at all: an approval in front of two questions read as a lone approval, and
# the questions left no trace on screen to say they were there.
function Get-QueueSuffix([int]$total) {
    if ($total -gt 1) { return " (+$($total - 1))" }
    return ''
}

function Render-Steps {
    if ($State.Steps.Count -eq 0) {
        if ($null -ne $script:StepSignature) { $script:StepSignature = $null; $StepsPanel.Visibility = 'Collapsed' }
        return
    }
    # Rebuilding the string and re-setting the TextBlock forces a layout pass, so
    # skip it entirely while the step list is unchanged.
    $sb = New-Object System.Text.StringBuilder
    foreach ($s in $State.Steps) {
        $mark = if ($s.Done) { [char]0x2713 } else { [char]0x25B8 }   # check / triangle
        [void]$sb.AppendLine("$mark  $($s.Text)")
    }
    $text = $sb.ToString().TrimEnd()
    if ($text -eq $script:StepSignature) {
        # The panel is force-collapsed while an approval is showing, so make sure
        # it comes back even when the step text itself has not moved on.
        if ($StepsPanel.Visibility -ne 'Visible') { $StepsPanel.Visibility = 'Visible' }
        return
    }
    $script:StepSignature = $text
    $StepsText.Text = $text
    $StepsPanel.Visibility = 'Visible'
}

$timer = New-Object System.Windows.Threading.DispatcherTimer
$timer.Interval = [TimeSpan]::FromMilliseconds([int]$Config.pollIntervalMs)
$timer.Add_Tick({
    try { Read-NewEvents } catch { }
    try { Merge-SessionState } catch { }

    $win = Get-AgentWindow
    $agentRunning = $null -ne $win
    $fg = [ScoutNative]::GetForegroundWindow()
    $isForeground = $agentRunning -and ($fg -eq $win.Hwnd)
    $isMinimized  = $agentRunning -and [ScoutNative]::IsIconic($win.Hwnd)

    # Lifecycle: when Scout has fully closed, shut the companion down after a short
    # grace period (covers restarts / momentary window-title flaps).
    if ($agentRunning -or (Test-AgentProcess)) {
        $script:AgentGoneSince = $null
    } elseif ($Config.exitWhenAgentGone) {
        if (-not $script:AgentGoneSince) {
            $script:AgentGoneSince = [datetime]::UtcNow
        } elseif ((([datetime]::UtcNow - $script:AgentGoneSince).TotalSeconds) -ge [double]$Config.exitGraceSeconds) {
            Stop-Companion
            return
        }
    }

    $hasPending = $State.PendingPerms.Count -gt 0
    $hasAsk     = $State.PendingAsks.Count -gt 0
    $ageSec = ([datetime]::UtcNow - $State.LastEventUtc).TotalSeconds
    $running = ($State.Steps | Where-Object { -not $_.Done } | Measure-Object).Count -gt 0
    $isActive = $hasPending -or $hasAsk -or $running -or ($State.TurnActive) -or ($Sessions.Count -gt 0 -and $ageSec -le [double]$Config.activeWindowSeconds)

    # A question parks the turn just like an approval does, so neither counts as
    # "busy" - the mascot should be waiting, not typing.
    $script:Busy = (-not $hasPending) -and (-not $hasAsk) -and ($State.TurnActive -or $running -or ($ageSec -le 6))
    $script:Pending = $hasPending
    $script:Asking  = $hasAsk

    # The ✕ button only dismisses the CURRENT burst. Re-show automatically when a
    # new approval or question arrives, or when a fresh working turn begins
    # (idle -> busy edge), so closing it once doesn't mute the companion forever.
    if ($script:Hidden -and ($hasPending -or $hasAsk)) { $script:Hidden = $false }
    if ($script:Hidden -and $script:Busy -and -not $script:PrevBusy) { $script:Hidden = $false }
    $script:PrevBusy = $script:Busy

    # pick the visual state: approval > question > working > idle, swap only on
    # change. Approval outranks a question because the toast can act on it.
    $desiredState = if ($hasPending) { 'alert' }
                    elseif ($hasAsk) { 'ask' }
                    elseif ($script:Busy -and $agentRunning) { 'working' }
                    else { 'idle' }
    if ($desiredState -ne $script:ThemeState) {
        Set-Theme $desiredState
        $script:ThemeState = $desiredState
        # Same strings as the header, not lowercase variants. JSON object keys
        # are matched case-insensitively by ConvertFrom-Json, so "Idle" and
        # "idle" as separate keys made every language file fail to parse -- and
        # the loader's catch turned that into a silent fall back to English.
        $detail = switch ($desiredState) {
            'alert'   { T 'Approval needed' }
            'ask'     { T 'Waiting on you' }
            'working' { T 'Scout is working' }
            default   { if ($agentRunning) { T 'Idle' } else { T 'Agent not detected' } }
        }
        Set-TrayState $desiredState $detail
    }

    # content
    # Both branches share one count, so whichever prompt is in front, the
    # header still admits how much is queued behind it.
    $extra = Get-QueueSuffix ($State.PendingPerms.Count + $State.PendingAsks.Count)
    if ($hasPending) {
        $first = $State.PendingPerms[ @($State.PendingPerms.Keys)[0] ]
        $HeaderText.Text = (T 'Approval needed') + $extra
        $PermTitle.Text  = [char]0x26A0 + ' ' + (T 'Permission requested')
        Set-PermFrom $first
        $PermText.Text = $first.text
        $AllowBtn.Visibility  = 'Visible'
        $DenyBtn.Visibility   = 'Visible'
        $AnswerBtn.Visibility = 'Collapsed'
        $PermPanel.Visibility = 'Visible'
        $Dot.Fill = '#FFB45309'
        # keep the yellow alert focused: hide the step list and narration
        $SayingText.Visibility = 'Collapsed'
        $StepsPanel.Visibility = 'Collapsed'
    }
    elseif ($hasAsk) {
        $first = $State.PendingAsks[ @($State.PendingAsks.Keys)[0] ]
        $HeaderText.Text = (T 'Waiting on you') + $extra
        $PermTitle.Text  = [char]0x2753 + ' ' + (T 'The agent asked you a question')
        Set-PermFrom $first
        $body = $first.text
        if ($first.choices -and $first.choices.Count) {
            $body = $body + "`n" + (($first.choices | ForEach-Object { [char]0x2022 + " $_" }) -join "`n")
        }
        $PermText.Text = Truncate $body 320
        # The companion cannot answer for you, so it offers the one useful action.
        $AllowBtn.Visibility  = 'Collapsed'
        $DenyBtn.Visibility   = 'Collapsed'
        $AnswerBtn.Visibility = 'Visible'
        $PermPanel.Visibility = 'Visible'
        $Dot.Fill = '#FF0E7FB8'
        $SayingText.Visibility = 'Collapsed'
        $StepsPanel.Visibility = 'Collapsed'
    }
    else {
        $PermPanel.Visibility = 'Collapsed'
        if (-not $agentRunning) { $HeaderText.Text = T 'Agent not detected'; $Dot.Fill = '#FF8A93A6' }
        elseif ($script:Busy)   { $HeaderText.Text = T 'Working hard...';    $Dot.Fill = '#FF4ADE80' }
        else                    { $HeaderText.Text = T 'Idle';               $Dot.Fill = '#FF8A93A6' }

        if ($State.Saying) { $SayingText.Text = $State.Saying; $SayingText.Visibility = 'Visible' }
        else { $SayingText.Visibility = 'Collapsed' }

        Render-Steps
    }

    # visibility policy
    $greeting = [datetime]::UtcNow -lt $script:GreetUntil
    $shouldShow = Get-ShouldShow -HasPending $hasPending -HasAsk $hasAsk `
        -IsActive $isActive -AgentRunning $agentRunning -IsMinimized $isMinimized `
        -IsForeground $isForeground -Hidden $script:Hidden -Pinned $script:Pinned `
        -Greeting $greeting

    if ($env:SCOUT_COMPANION_DEBUG -or (Test-Path (Join-Path $env:TEMP 'scout-companion-debug.on'))) {
        try {
            $dbg = "{0} show={1} vis={2} pend={3} ask={4} sess={5} active={6} run={7} agent={8} fg={9} min={10} hidden={11} pin={12} greet={13} age={14}" -f `
                (Get-Date -Format 'HH:mm:ss'), $shouldShow, $Window.IsVisible, $hasPending, $hasAsk, $Sessions.Count, $isActive, $running, $agentRunning, $isForeground, $isMinimized, $script:Hidden, $script:Pinned, $greeting, [int]$ageSec
            Add-Content -Path (Join-Path $env:TEMP 'scout-companion-debug.log') -Value $dbg
        } catch { }
    }

    # Application.Run is handed a window whose Visibility was preset to Hidden,
    # and returns with WPF believing the toast is shown while its window never
    # was - IsVisible reads True with WS_VISIBLE off. Every later Show() is then
    # skipped as redundant and the toast never appears at all. Hiding it once,
    # explicitly, puts the two back in agreement before anything reads them.
    # Latent until now only because the first tick always wanted it hidden.
    if (-not $script:VisibilityReconciled) {
        $script:VisibilityReconciled = $true
        try { $Window.Hide() } catch { }
    }

    if ($shouldShow) {
        if (-not $Window.IsVisible) { $Window.Show() }
        $Window.Topmost = $true
        # Only animate while the toast is actually on screen.
        if (-not $anim.IsEnabled -and $script:AnimEnabled) { $anim.Start() }
    } else {
        if ($anim.IsEnabled) { $anim.Stop() }
        if ($Window.IsVisible) { $Window.Hide() }
    }

    # The tray item is a toggle, so its caption has to say what clicking it will
    # do rather than name a state.
    $wantCaption = if ($shouldShow) { T 'Hide toast' } else { T 'Show toast' }
    if ($MenuShow.Text -ne $wantCaption) { $MenuShow.Text = $wantCaption }
})

# Prime to the current end of every active session, so a fresh start does not
# replay approvals that were answered long ago.
Sync-Sessions
$script:SessionScanUtc = [datetime]::UtcNow
Merge-SessionState

# Draw the configured mascot. This has to run after the mascot functions are
# defined, so it deliberately lives here rather than next to Set-Theme.
Set-Mascot ([string]$Config.mascot)

# Say hello, so launching the companion has a visible result. Armed here rather
# than at the top of the script: everything above this line is setup, and a
# greeting that started counting before the window could be drawn would spend
# most of itself invisible.
$greetFor = 0.0
try { $greetFor = [double]$Config.startupGreetingSeconds } catch { $greetFor = 0.0 }
if ($greetFor -gt 0) { $script:GreetUntil = [datetime]::UtcNow.AddSeconds($greetFor) }

# The mascot timer is driven by the poll loop and only runs while the toast is
# on screen, so it deliberately does not start here.
$timer.Start()

$Window.Visibility = 'Hidden'
# Make sure the tray icon never outlives the process, however it ends.
$Window.Add_Closed({
    # Last line of defence: closing the toast ends the app, and a pending
    # opacity write has to survive that.
    try { Save-PendingOpacity } catch { }
    try { $Tray.Visible = $false; $Tray.Dispose() } catch { }
})
$app = New-Object System.Windows.Application
# The toast is the app: closing it exits, and any settings window opened from
# the tray is free to come and go without taking the companion down with it.
$app.ShutdownMode = [System.Windows.ShutdownMode]::OnMainWindowClose
$app.Run($Window) | Out-Null
