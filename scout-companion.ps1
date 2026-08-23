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
    activeWindowSeconds = 150
    pollIntervalMs      = 700
    # A full rescan of every session folder is expensive on machines with a long
    # session history, so the resolved session is cached and only re-resolved
    # this often. Between rescans the companion just stats the file it is tailing.
    sessionRescanMs     = 5000
    # Mascot frame interval. 80 ms (12.5 fps) is smooth enough for a bob and a
    # typing paw, and costs roughly half of the old 50 ms (20 fps).
    animIntervalMs      = 80
    # Mascot animation can be switched off entirely from the tray or settings.
    animationEnabled    = $true
    # Which mascot the toast shows. See $Mascots for the available ids.
    mascot              = 'quokka'
    maxSteps            = 4
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
# ---------------------------------------------------------------------------
$State = [pscustomobject]@{
    SessionDir      = $null
    EventsPath      = $null
    Offset          = [long]0
    Saying          = $null                       # latest assistant narrative
    Steps           = New-Object System.Collections.ArrayList   # recent tool steps
    TurnActive      = $false
    LastEventUtc    = [datetime]::MinValue
    PendingPerms    = [ordered]@{}
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
    if (-not $name) { return 'Working' }
    switch -Regex ($name) {
        '^report_intent$'              { if ($a.intent) { return [string]$a.intent } ; return 'Planning' }
        '^(powershell|bash|shell|run_command)$' {
            $c = $a.command; if (-not $c) { $c = $a.script }
            if ($c) { $first = ($c -split "`n" | Where-Object { $_.Trim() } | Select-Object -First 1)
                      return "Running: $(Truncate $first 64)" }
            return 'Running a command'
        }
        '^view$'                       { return "Reading $(Leaf $a.path)" }
        '^edit$'                       { return "Editing $(Leaf $a.path)" }
        '^create$'                     { return "Creating $(Leaf $a.path)" }
        '^grep$'                       { return "Searching `"$(Truncate $a.pattern 40)`"" }
        '^glob$'                       { return "Finding files: $(Truncate $a.pattern 40)" }
        '^task$'                       { if ($a.description) { return "Delegating: $(Truncate $a.description 50)" } ; return 'Delegating a subtask' }
        '^web_fetch$'                  { return "Fetching $(Truncate $a.url 50)" }
        '^web_search$'                 { return "Web search: $(Truncate $a.query 44)" }
        '^m_filesystem_(list|tree)$'   { return "Listing $(Leaf $a.path)" }
        '^m_filesystem_stat$'          { return "Checking $(Leaf $a.path)" }
        '^m_filesystem_mkdir$'         { return "New folder $(Leaf $a.path)" }
        '^m_filesystem_move$'          { return "Moving $(Leaf $a.source)" }
        '^sql$'                        { if ($a.description) { return "DB: $(Truncate $a.description 46)" } ; return 'Querying database' }
        '^workiq_list_emails$'         { return 'Checking emails' }
        '^workiq_(search_emails|get_email)$' { return "Email: $(Truncate $a.query 40)" }
        '^workiq_(send_email|reply_to_email|create_draft).*' { return 'Composing email' }
        '^workiq_.*chat.*'             { return 'Teams chat' }
        '^workiq_.*event.*'            { return 'Calendar' }
        '^workiq_.*(people|profile|manager).*' { return 'Looking up people' }
        '^workiq_.*file.*'             { return 'OneDrive files' }
        '^m_remember$'                 { return 'Saving a memory' }
        '^m_recall$'                   { return 'Recalling memory' }
        '^skill$'                      { if ($a.skill) { return "Skill: $($a.skill)" } ; return 'Using a skill' }
        '^browser_'                    { return 'Browsing the web' }
        default                        { return (($name -replace '^m_','') -replace '_',' ') }
    }
}

function Add-Step([string]$id, [string]$reqId, [string]$text) {
    if (-not $text) { return }
    $rec = [pscustomobject]@{ Id = $id; ReqId = $reqId; Text = $text; Done = $false }
    [void]$State.Steps.Add($rec)
    while ($State.Steps.Count -gt [int]$Config.maxSteps) { $State.Steps.RemoveAt(0) }
}

function Complete-Step([string]$id, [string]$reqId) {
    for ($i = $State.Steps.Count - 1; $i -ge 0; $i--) {
        $s = $State.Steps[$i]
        if (($id -and $s.Id -eq $id) -or ($reqId -and $s.ReqId -eq $reqId)) { $s.Done = $true; break }
    }
}

function Get-AgentWindow {
    # Fast path: the handle found last time is almost always still valid, so a
    # cheap IsWindow check replaces a full process enumeration on most ticks.
    if ($script:WinCache -and [ScoutNative]::IsWindow($script:WinCache.Hwnd)) {
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

function Test-LiveLock {
    # A session lock is only meaningful if the PID embedded in its name
    # (inuse.<pid>.lock) belongs to a process that is still running. Stale lock
    # files from crashed/closed sessions are ignored so we never latch onto an
    # ancient session and report it as "active".
    #
    # $seen memoises PID liveness for the duration of one scan: most machines
    # accumulate dozens of stale locks and many repeat the same dead PID.
    param([string]$dir, [hashtable]$seen)
    foreach ($lock in [System.IO.Directory]::EnumerateFiles($dir, 'inuse.*.lock')) {
        if ([System.IO.Path]::GetFileName($lock) -match 'inuse\.(\d+)') {
            $procId = [int]$Matches[1]
            if ($seen -and $seen.ContainsKey($procId)) {
                if ($seen[$procId]) { return $true } else { continue }
            }
            $alive = $false
            try { $p = [System.Diagnostics.Process]::GetProcessById($procId); $p.Dispose(); $alive = $true } catch { }
            if ($seen) { $seen[$procId] = $alive }
            if ($alive) { return $true }
        }
    }
    return $false
}

function Find-ActiveSession {
    if (-not [System.IO.Directory]::Exists($SessionRoot)) { return $null }

    # Collect candidates with raw .NET calls - Get-ChildItem/Get-Item allocate a
    # PSObject wrapper per entry, which dominates the cost once a machine has
    # accumulated a few hundred session folders.
    $candidates = New-Object System.Collections.ArrayList
    foreach ($dir in [System.IO.Directory]::EnumerateDirectories($SessionRoot)) {
        $ev = [System.IO.Path]::Combine($dir, 'events.jsonl')
        $fi = New-Object System.IO.FileInfo $ev
        if (-not $fi.Exists) { continue }
        [void]$candidates.Add([pscustomobject]@{ Dir = $dir; Events = $ev; Mtime = $fi.LastWriteTimeUtc })
    }
    if ($candidates.Count -eq 0) { return $null }

    # Prefer a session with a live lock, then the most recently written events
    # file. Walking newest-first and returning the first live lock gives the same
    # answer as ranking every folder, but normally only tests a single lock.
    $sorted = $candidates | Sort-Object -Property Mtime -Descending
    $seen = @{}
    foreach ($c in $sorted) {
        if (Test-LiveLock $c.Dir $seen) { return $c }
    }
    # Nothing holds a live lock - fall back to plain recency so we still track
    # the newest session.
    return $sorted[0]
}

function Read-NewEvents {
    # Between full rescans, keep tailing the file we already latched onto. This
    # turns the common tick into a single file stat instead of a walk over every
    # session folder on the machine.
    $sess = $null
    $needScan = $true
    if ($State.EventsPath) {
        $cur = New-Object System.IO.FileInfo $State.EventsPath
        if ($cur.Exists -and ([datetime]::UtcNow - $script:SessionScanUtc).TotalMilliseconds -lt [double]$Config.sessionRescanMs) {
            $needScan = $false
            $sess = [pscustomobject]@{ Dir = $State.SessionDir; Events = $State.EventsPath }
            $len = $cur.Length
        }
    }

    if ($needScan) {
        $script:SessionScanUtc = [datetime]::UtcNow
        $sess = Find-ActiveSession
        if (-not $sess) { return }

        if ($State.EventsPath -ne $sess.Events) {
            $State.SessionDir = $sess.Dir
            $State.EventsPath = $sess.Events
            $State.Offset     = (New-Object System.IO.FileInfo $sess.Events).Length
            $State.PendingPerms = [ordered]@{}
            $State.Steps.Clear()
            $State.Saying = $null
            $State.TurnActive = $false
            return
        }
        $len = (New-Object System.IO.FileInfo $sess.Events).Length
    }

    if ($len -lt $State.Offset) { $State.Offset = 0 }
    if ($len -eq $State.Offset) { return }

    $fs = [System.IO.File]::Open($sess.Events, 'Open', 'Read', 'ReadWrite')
    try {
        $fs.Seek($State.Offset, 'Begin') | Out-Null
        $sr = New-Object System.IO.StreamReader($fs)
        $chunk = $sr.ReadToEnd()
        $State.Offset = $fs.Position
    } finally { $fs.Dispose() }

    foreach ($line in ($chunk -split "`n")) {
        $line = $line.Trim()
        if (-not $line) { continue }
        try { $evt = $line | ConvertFrom-Json } catch { continue }
        Handle-Event $evt
    }
}

function Handle-Event($evt) {
    $State.LastEventUtc = [datetime]::UtcNow
    switch ($evt.type) {
        'assistant.turn_start' { $State.TurnActive = $true }
        'assistant.turn_end'   { $State.TurnActive = $false }
        'assistant.message' {
            $txt = $evt.data.content; if (-not $txt) { $txt = $evt.data.text }
            if ($txt) { $State.Saying = Truncate $txt 200 }
        }
        'tool.execution_start' {
            $desc = Describe-Tool $evt.data.toolName $evt.data.arguments
            Add-Step $evt.data.toolCallId $null $desc
        }
        'tool.execution_complete' {
            Complete-Step $evt.data.toolCallId $null
        }
        'external_tool.requested' {
            $desc = Describe-Tool $evt.data.toolName $evt.data.arguments
            Add-Step $evt.data.toolCallId $evt.data.requestId $desc
        }
        'external_tool.completed' {
            Complete-Step $null $evt.data.requestId
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
            $State.PendingPerms[$id] = @{ text = (Truncate $text 280); kind = $kind }
        }
        'permission.completed' {
            $id = $evt.data.requestId
            if ($State.PendingPerms.Contains($id)) { $State.PendingPerms.Remove($id) }
        }
    }
}

function Wake-AgentA11y([IntPtr]$hwnd) {
    if ($hwnd -eq [IntPtr]::Zero) { return }
    [void][ScoutNative]::SendMessage($hwnd, 0x003D, [IntPtr]::Zero, [IntPtr](-25))
}

function Invoke-AgentButton([string[]]$labels) {
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
              <TranslateTransform x:Name="BodyT"/>
            </TransformGroup>
          </Canvas.RenderTransform>
          <!-- head is inserted here at index 0 -->
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
          <TextBlock x:Name="PermTitle" Text="&#x26A0; Permission requested" Foreground="#FF6A4A00" FontWeight="Bold" FontSize="13"/>
          <TextBlock x:Name="PermText" Margin="0,5,0,0" Foreground="#FFD6CFC2" FontSize="11.5"
                     TextWrapping="Wrap" MaxHeight="90" TextTrimming="CharacterEllipsis"/>
          <StackPanel Orientation="Horizontal" Margin="0,10,0,0" HorizontalAlignment="Right">
            <Button x:Name="DenyBtn" Content="Deny" Width="74" Height="28" Margin="0,0,8,0"
                    Background="#FF3A2730" Foreground="#FFF0B4B4" BorderThickness="0" Cursor="Hand"/>
            <Button x:Name="AllowBtn" Content="Allow" Width="90" Height="28"
                    Background="#FF2E7D46" Foreground="#FFFFFFFF" BorderThickness="0" FontWeight="SemiBold" Cursor="Hand"/>
          </StackPanel>
        </StackPanel>
      </Border>
    </StackPanel>
    </Border>
  </Grid>
</Window>
'@

$reader = New-Object System.Xml.XmlNodeReader $xaml
$Window = [Windows.Markup.XamlReader]::Load($reader)

$HeaderText   = $Window.FindName('HeaderText')
$SayingText   = $Window.FindName('SayingText')
$Dot          = $Window.FindName('Dot')
$StepsPanel   = $Window.FindName('StepsPanel')
$StepsText    = $Window.FindName('StepsText')
$PermPanel    = $Window.FindName('PermPanel')
$PermText     = $Window.FindName('PermText')
$AllowBtn     = $Window.FindName('AllowBtn')
$DenyBtn      = $Window.FindName('DenyBtn')
$OpenBtn      = $Window.FindName('OpenBtn')
$CloseBtn     = $Window.FindName('CloseBtn')
$SettingsBtn  = $Window.FindName('SettingsBtn')
$BodyT        = $Window.FindName('BodyT')
$BodyS        = $Window.FindName('BodyS')
$LeftPawT     = $Window.FindName('LeftPawT')
$RightPawT    = $Window.FindName('RightPawT')
$RootBorder   = $Window.FindName('RootBorder')
$GlowBorder   = $Window.FindName('GlowBorder')
$MascotHost   = $Window.FindName('MascotHost')
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
    PermBgNormal  = B '#FF2A2030'; PermBdNormal  = B '#FFB4843C'; PermTxtNormal = B '#FFD6CFC2'
    PermBgAlert   = B '#FFFFFFFF'; PermBdAlert   = B '#FFFF7A00'; PermTxtAlert  = B '#FF3A2E10'
}
$script:ThemeState = $null

# state: 'alert' (approval), 'working' (busy), 'idle' (default/dim)
function Set-Theme([string]$state) {
    if ($state -eq 'alert') {
        $RootBorder.Background  = $Theme.AlertBg
        $RootBorder.BorderBrush = $Theme.AlertBorder
        $RootBorder.BorderThickness = 2
        $HeaderText.Foreground  = $Theme.AlertHeader
        $PermPanel.Background   = $Theme.PermBgAlert
        $PermPanel.BorderBrush  = $Theme.PermBdAlert
        $PermText.Foreground    = $Theme.PermTxtAlert
        $RootGlow.Color         = [System.Windows.Media.Color]::FromRgb(255, 176, 0)
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
$script:Pending = $false
$script:AgentGoneSince = $null
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
$OpenBtn.Add_Click({ Focus-Agent })
$CloseBtn.Add_Click({ $script:Hidden = $true; $Window.Hide() })
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
function New-CatHead($p) {
    $patches = ''
    if ($p.patchA) {
        # Calico-style patches: one over an ear and eye, one on the opposite cheek.
        $patches = @"
      <Path Fill="$($p.patchA)" Data="M12,12 Q22,6 27,14 Q20,24 11,22 Z"/>
      <Path Fill="$($p.patchB)" Data="M46,16 Q50,26 42,32 Q36,26 39,17 Z"/>
"@
    }
    $mask = ''
    if ($p.mask) {
        # Siamese-style points: a darker mask around the muzzle.
        $mask = "      <Ellipse Canvas.Left=`"17`" Canvas.Top=`"22`" Width=`"24`" Height=`"20`" Fill=`"$($p.mask)`"/>"
    }
    @"
      <Polygon Points="9,20 13,2 25,13"  Fill="$($p.ear)" Stroke="$($p.shade)" StrokeThickness="1"/>
      <Polygon Points="49,20 45,2 33,13" Fill="$($p.ear)" Stroke="$($p.shade)" StrokeThickness="1"/>
      <Polygon Points="13,17 15,7 21,14"  Fill="$($p.earInner)"/>
      <Polygon Points="45,17 43,7 37,14" Fill="$($p.earInner)"/>
      <Ellipse Canvas.Left="5" Canvas.Top="10" Width="48" Height="38" Fill="$($p.fur)" Stroke="$($p.shade)" StrokeThickness="1"/>
$patches
$mask
      <Ellipse Canvas.Left="12" Canvas.Top="22" Width="11" Height="12" Fill="$($p.eye)"/>
      <Ellipse Canvas.Left="35" Canvas.Top="22" Width="11" Height="12" Fill="$($p.eye)"/>
      <Ellipse Canvas.Left="15.5" Canvas.Top="24" Width="4" Height="9" Fill="#FF1E1A18"/>
      <Ellipse Canvas.Left="38.5" Canvas.Top="24" Width="4" Height="9" Fill="#FF1E1A18"/>
      <Ellipse Canvas.Left="16.6" Canvas.Top="25" Width="2.6" Height="2.6" Fill="#FFFFFFFF"/>
      <Ellipse Canvas.Left="39.6" Canvas.Top="25" Width="2.6" Height="2.6" Fill="#FFFFFFFF"/>
      <Polygon Points="26,34 32,34 29,38" Fill="$($p.nose)"/>
      <Path Stroke="$($p.shade)" StrokeThickness="1.4" StrokeStartLineCap="Round" StrokeEndLineCap="Round"
            Data="M29,38 Q25,42 22,38 M29,38 Q33,42 36,38"/>
      <Path Stroke="$($p.shade)" StrokeThickness="0.9" Opacity="0.75"
            Data="M4,31 L15,33 M4,36 L15,36 M54,31 L43,33 M54,36 L43,36"/>
"@
}

function New-QuokkaHead($p) {
    @"
      <Ellipse Canvas.Left="8"  Canvas.Top="1"  Width="16" Height="18" Fill="$($p.ear)"/>
      <Ellipse Canvas.Left="32" Canvas.Top="1"  Width="16" Height="18" Fill="$($p.ear)"/>
      <Ellipse Canvas.Left="12" Canvas.Top="5"  Width="8"  Height="10" Fill="$($p.earInner)"/>
      <Ellipse Canvas.Left="36" Canvas.Top="5"  Width="8"  Height="10" Fill="$($p.earInner)"/>
      <Ellipse Canvas.Left="6"  Canvas.Top="9"  Width="44" Height="43" Fill="$($p.fur)" Stroke="$($p.shade)" StrokeThickness="1"/>
      <Ellipse Canvas.Left="15" Canvas.Top="25" Width="26" Height="25" Fill="$($p.muzzle)"/>
      <Ellipse Canvas.Left="11" Canvas.Top="30" Width="9"  Height="7"  Fill="#66F2A0A0"/>
      <Ellipse Canvas.Left="36" Canvas.Top="30" Width="9"  Height="7"  Fill="#66F2A0A0"/>
      <Line X1="8"  Y1="21" X2="14" Y2="26" Stroke="#FF2B2B2B" StrokeThickness="1.8"/>
      <Line X1="48" Y1="21" X2="42" Y2="26" Stroke="#FF2B2B2B" StrokeThickness="1.8"/>
      <Ellipse Canvas.Left="13" Canvas.Top="20" Width="15" Height="15" Fill="#0FEAF7FF"/>
      <Ellipse Canvas.Left="28" Canvas.Top="20" Width="15" Height="15" Fill="#0FEAF7FF"/>
      <Ellipse Canvas.Left="17" Canvas.Top="23" Width="7" Height="10" Fill="#FF2B1A12"/>
      <Ellipse Canvas.Left="32" Canvas.Top="23" Width="7" Height="10" Fill="#FF2B1A12"/>
      <Ellipse Canvas.Left="18.4" Canvas.Top="24.6" Width="3.2" Height="3.2" Fill="#FFFFFFFF"/>
      <Ellipse Canvas.Left="33.4" Canvas.Top="24.6" Width="3.2" Height="3.2" Fill="#FFFFFFFF"/>
      <Ellipse Canvas.Left="13" Canvas.Top="20" Width="15" Height="15" Stroke="#FF242424" StrokeThickness="2.2" Fill="Transparent"/>
      <Ellipse Canvas.Left="28" Canvas.Top="20" Width="15" Height="15" Stroke="#FF242424" StrokeThickness="2.2" Fill="Transparent"/>
      <Line X1="26.5" Y1="25.5" X2="29.5" Y2="25.5" Stroke="#FF242424" StrokeThickness="2.2"/>
      <Ellipse Canvas.Left="15" Canvas.Top="22" Width="4" Height="3" Fill="#66FFFFFF"/>
      <Ellipse Canvas.Left="30" Canvas.Top="22" Width="4" Height="3" Fill="#66FFFFFF"/>
      <Ellipse Canvas.Left="24" Canvas.Top="30" Width="8"  Height="5"  Fill="$($p.nose)"/>
      <Path Stroke="$($p.nose)" StrokeThickness="2" StrokeStartLineCap="Round" StrokeEndLineCap="Round"
            Data="M20,35 Q28,42 36,35"/>
"@
}

function New-DogHead($p) {
    @"
      <Path Fill="$($p.ear)" Stroke="$($p.shade)" StrokeThickness="1" Data="M8,22 L11,3 L24,14 Z"/>
      <Path Fill="$($p.ear)" Stroke="$($p.shade)" StrokeThickness="1" Data="M50,22 L47,3 L34,14 Z"/>
      <Path Fill="$($p.earInner)" Data="M12,18 L14,8 L20,15 Z"/>
      <Path Fill="$($p.earInner)" Data="M46,18 L44,8 L38,15 Z"/>
      <Ellipse Canvas.Left="5"  Canvas.Top="11" Width="48" Height="37" Fill="$($p.fur)" Stroke="$($p.shade)" StrokeThickness="1"/>
      <Ellipse Canvas.Left="14" Canvas.Top="26" Width="30" Height="21" Fill="$($p.muzzle)"/>
      <Ellipse Canvas.Left="10" Canvas.Top="20" Width="12" Height="9" Fill="$($p.muzzle)" Opacity="0.85"/>
      <Ellipse Canvas.Left="36" Canvas.Top="20" Width="12" Height="9" Fill="$($p.muzzle)" Opacity="0.85"/>
      <Ellipse Canvas.Left="15" Canvas.Top="21" Width="7" Height="9" Fill="#FF231C18"/>
      <Ellipse Canvas.Left="36" Canvas.Top="21" Width="7" Height="9" Fill="#FF231C18"/>
      <Ellipse Canvas.Left="16.3" Canvas.Top="22.4" Width="2.8" Height="2.8" Fill="#FFFFFFFF"/>
      <Ellipse Canvas.Left="37.3" Canvas.Top="22.4" Width="2.8" Height="2.8" Fill="#FFFFFFFF"/>
      <Ellipse Canvas.Left="24" Canvas.Top="30" Width="10" Height="7" Fill="$($p.nose)"/>
      <Path Stroke="$($p.shade)" StrokeThickness="1.5" StrokeStartLineCap="Round" StrokeEndLineCap="Round"
            Data="M29,37 L29,40 M29,40 Q24,44 21,39 M29,40 Q34,44 37,39"/>
"@
}

function New-FoxHead($p) {
    @"
      <Path Fill="$($p.ear)" Stroke="$($p.shade)" StrokeThickness="1" Data="M7,21 L10,1 L25,13 Z"/>
      <Path Fill="$($p.ear)" Stroke="$($p.shade)" StrokeThickness="1" Data="M51,21 L48,1 L33,13 Z"/>
      <Path Fill="#FF2E2A28" Data="M10,10 L10,1 L17,7 Z"/>
      <Path Fill="#FF2E2A28" Data="M48,10 L48,1 L41,7 Z"/>
      <Path Fill="$($p.earInner)" Data="M12,17 L14,7 L21,14 Z"/>
      <Path Fill="$($p.earInner)" Data="M46,17 L44,7 L37,14 Z"/>
      <Ellipse Canvas.Left="5" Canvas.Top="11" Width="48" Height="36" Fill="$($p.fur)" Stroke="$($p.shade)" StrokeThickness="1"/>
      <Path Fill="$($p.muzzle)" Data="M16,28 Q29,24 42,28 Q40,46 29,47 Q18,46 16,28 Z"/>
      <Ellipse Canvas.Left="14" Canvas.Top="22" Width="8" Height="9" Fill="#FF2B211C"/>
      <Ellipse Canvas.Left="36" Canvas.Top="22" Width="8" Height="9" Fill="#FF2B211C"/>
      <Ellipse Canvas.Left="15.4" Canvas.Top="23.4" Width="2.8" Height="2.8" Fill="#FFFFFFFF"/>
      <Ellipse Canvas.Left="37.4" Canvas.Top="23.4" Width="2.8" Height="2.8" Fill="#FFFFFFFF"/>
      <Ellipse Canvas.Left="25" Canvas.Top="33" Width="8" Height="6" Fill="$($p.nose)"/>
      <Path Stroke="$($p.shade)" StrokeThickness="1.4" StrokeStartLineCap="Round" StrokeEndLineCap="Round"
            Data="M29,39 Q25,43 22,39 M29,39 Q33,43 36,39"/>
"@
}

function New-BunnyHead($p) {
    @"
      <Ellipse Canvas.Left="13" Canvas.Top="0"  Width="11" Height="24" Fill="$($p.ear)" Stroke="$($p.shade)" StrokeThickness="1"/>
      <Ellipse Canvas.Left="34" Canvas.Top="0"  Width="11" Height="24" Fill="$($p.ear)" Stroke="$($p.shade)" StrokeThickness="1"/>
      <Ellipse Canvas.Left="15.6" Canvas.Top="3" Width="6" Height="18" Fill="$($p.earInner)"/>
      <Ellipse Canvas.Left="36.6" Canvas.Top="3" Width="6" Height="18" Fill="$($p.earInner)"/>
      <Ellipse Canvas.Left="7"  Canvas.Top="17" Width="44" Height="33" Fill="$($p.fur)" Stroke="$($p.shade)" StrokeThickness="1"/>
      <Ellipse Canvas.Left="16" Canvas.Top="24" Width="9" Height="11" Fill="#FF2A2320"/>
      <Ellipse Canvas.Left="33" Canvas.Top="24" Width="9" Height="11" Fill="#FF2A2320"/>
      <Ellipse Canvas.Left="17.6" Canvas.Top="25.6" Width="3" Height="3" Fill="#FFFFFFFF"/>
      <Ellipse Canvas.Left="34.6" Canvas.Top="25.6" Width="3" Height="3" Fill="#FFFFFFFF"/>
      <Ellipse Canvas.Left="25" Canvas.Top="35" Width="8" Height="6" Fill="$($p.nose)"/>
      <Path Stroke="$($p.shade)" StrokeThickness="1.4" StrokeStartLineCap="Round" StrokeEndLineCap="Round"
            Data="M29,41 L29,43 M29,43 Q25,46 23,43 M29,43 Q33,46 35,43"/>
      <Path Stroke="$($p.shade)" StrokeThickness="0.9" Opacity="0.7" Data="M6,36 L17,37 M52,36 L41,37"/>
"@
}

function New-PenguinHead($p) {
    @"
      <Ellipse Canvas.Left="6"  Canvas.Top="8"  Width="46" Height="42" Fill="$($p.fur)" Stroke="$($p.shade)" StrokeThickness="1"/>
      <Path Fill="$($p.muzzle)" Data="M15,20 Q29,12 43,20 Q45,42 29,48 Q13,42 15,20 Z"/>
      <Ellipse Canvas.Left="16" Canvas.Top="21" Width="9" Height="11" Fill="#FF17171A"/>
      <Ellipse Canvas.Left="33" Canvas.Top="21" Width="9" Height="11" Fill="#FF17171A"/>
      <Ellipse Canvas.Left="17.6" Canvas.Top="22.6" Width="3" Height="3" Fill="#FFFFFFFF"/>
      <Ellipse Canvas.Left="34.6" Canvas.Top="22.6" Width="3" Height="3" Fill="#FFFFFFFF"/>
      <Path Fill="$($p.nose)" Data="M22,34 L36,34 L29,43 Z"/>
      <Path Fill="$($p.ear)" Opacity="0.55" Data="M11,28 Q6,22 9,16 Q14,20 15,27 Z"/>
      <Path Fill="$($p.ear)" Opacity="0.55" Data="M47,28 Q52,22 49,16 Q44,20 43,27 Z"/>
"@
}

function New-TunaHead($p) {
    @"
      <Path Fill="$($p.ear)" Stroke="$($p.shade)" StrokeThickness="1" Data="M4,18 L14,29 L4,40 Q1,29 4,18 Z"/>
      <Path Fill="$($p.ear)" Stroke="$($p.shade)" StrokeThickness="1" Data="M54,18 L44,29 L54,40 Q57,29 54,18 Z"/>
      <Path Fill="$($p.ear)" Stroke="$($p.shade)" StrokeThickness="1" Data="M23,9 Q29,1 35,9 Z"/>
      <Ellipse Canvas.Left="9" Canvas.Top="9" Width="40" Height="38" Fill="$($p.fur)" Stroke="$($p.shade)" StrokeThickness="1"/>
      <Path Fill="$($p.muzzle)" Data="M13,30 Q29,24 45,30 Q42,47 29,48 Q16,47 13,30 Z"/>
      <Path Stroke="$($p.shade)" StrokeThickness="1.2" Opacity="0.8" Data="M14,17 Q29,13 44,17 M12,23 Q29,19 46,23"/>
      <Ellipse Canvas.Left="14" Canvas.Top="21" Width="12" Height="12" Fill="#FFFFFFFF" Stroke="$($p.shade)" StrokeThickness="1"/>
      <Ellipse Canvas.Left="32" Canvas.Top="21" Width="12" Height="12" Fill="#FFFFFFFF" Stroke="$($p.shade)" StrokeThickness="1"/>
      <Ellipse Canvas.Left="17" Canvas.Top="24" Width="6.5" Height="6.5" Fill="#FF14181F"/>
      <Ellipse Canvas.Left="35" Canvas.Top="24" Width="6.5" Height="6.5" Fill="#FF14181F"/>
      <Ellipse Canvas.Left="18.4" Canvas.Top="25" Width="2.4" Height="2.4" Fill="#FFFFFFFF"/>
      <Ellipse Canvas.Left="36.4" Canvas.Top="25" Width="2.4" Height="2.4" Fill="#FFFFFFFF"/>
      <Path Stroke="$($p.nose)" StrokeThickness="2" StrokeStartLineCap="Round" StrokeEndLineCap="Round"
            Data="M24,39 Q29,44 34,39"/>
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
}

# Ordered so the picker reads sensibly: the original mascot, then the cats with
# white first as requested, then everyone else.
$Mascots = [ordered]@{
    'quokka' = @{ Label = 'Quokka'; Species = 'quokka'; Palette = @{
        fur='#FFC58A5E'; shade='#FF8A5A38'; ear='#FFB87A50'; earInner='#FFE3A6A6'
        muzzle='#FFF0DBBC'; nose='#FF5A3A2A'; eye='#FF2B1A12'; paw='#FFB87A50' } }

    'cat-white' = @{ Label = 'Cat - White'; Species = 'cat'; Palette = @{
        fur='#FFF6F3EE'; shade='#FFB9B0A4'; ear='#FFF0EBE3'; earInner='#FFF3BFC1'
        muzzle='#FFFFFFFF'; nose='#FFE79AA4'; eye='#FF7FC4E8'; paw='#FFF0EBE3' } }

    'cat-siamese' = @{ Label = 'Cat - Siamese'; Species = 'cat'; Palette = @{
        fur='#FFEFE2CB'; shade='#FF7A6045'; ear='#FF5B4636'; earInner='#FF8C6B58'
        muzzle='#FFEFE2CB'; nose='#FF6E5346'; eye='#FF6FC0E4'; paw='#FF7A6049'
        mask='#FF6B5343' } }

    'cat-calico' = @{ Label = 'Cat - Calico'; Species = 'cat'; Palette = @{
        fur='#FFF7F2EA'; shade='#FFA9968A'; ear='#FFEDE4D8'; earInner='#FFF0B7B7'
        muzzle='#FFFFFFFF'; nose='#FFE08E96'; eye='#FFD7A03C'; paw='#FFEDE4D8'
        patchA='#FFE49A47'; patchB='#FF44392F' } }

    'cat-black' = @{ Label = 'Cat - Black'; Species = 'cat'; Palette = @{
        fur='#FF3A3634'; shade='#FF171514'; ear='#FF322E2C'; earInner='#FF7A5A5A'
        muzzle='#FF3A3634'; nose='#FF262220'; eye='#FFD9CE59'; paw='#FF322E2C' } }

    'cat-russian' = @{ Label = 'Cat - Russian Blue'; Species = 'cat'; Palette = @{
        fur='#FF97A3B2'; shade='#FF5F6C7C'; ear='#FF8B98A8'; earInner='#FFCBAEB2'
        muzzle='#FF97A3B2'; nose='#FF6E7A88'; eye='#FF7FC98A'; paw='#FF8B98A8' } }

    'tuna' = @{ Label = 'Tuna'; Species = 'tuna'; Palette = @{
        fur='#FF4E7FA6'; shade='#FF2E4E68'; ear='#FF3F6C90'; earInner='#FF3F6C90'
        muzzle='#FFDCE6EE'; nose='#FF2E4E68'; eye='#FF14181F'; paw='#FF3F6C90' } }

    'shiba' = @{ Label = 'Shiba'; Species = 'dog'; Palette = @{
        fur='#FFD9A15C'; shade='#FF9A6B34'; ear='#FFCE9553'; earInner='#FFE9C79A'
        muzzle='#FFF6EBDC'; nose='#FF2E2724'; eye='#FF231C18'; paw='#FFE4C39B' } }

    'fox' = @{ Label = 'Fox'; Species = 'fox'; Palette = @{
        fur='#FFDE7F3E'; shade='#FF9E4F1C'; ear='#FFD2743A'; earInner='#FFF0B48A'
        muzzle='#FFF7EFE6'; nose='#FF2B2320'; eye='#FF2B211C'; paw='#FFF2E9DF' } }

    'bunny' = @{ Label = 'Bunny'; Species = 'bunny'; Palette = @{
        fur='#FFF3EEE9'; shade='#FFB6ABA0'; ear='#FFF0EAE4'; earInner='#FFF2B9BE'
        muzzle='#FFFFFFFF'; nose='#FFE894A0'; eye='#FF2A2320'; paw='#FFF0EAE4' } }

    'penguin' = @{ Label = 'Penguin'; Species = 'penguin'; Palette = @{
        fur='#FF2C3038'; shade='#FF15181D'; ear='#FF3A4049'; earInner='#FF3A4049'
        muzzle='#FFF7F5F2'; nose='#FFF0A63C'; eye='#FF17171A'; paw='#FFF0A63C' } }
}

$script:MascotHead = $null

function Set-Mascot([string]$id) {
    if (-not $Mascots.Contains($id)) { $id = 'quokka' }
    $def = $Mascots[$id]
    $build = $MascotBuilders[$def.Species]
    if (-not $build) { return }

    $inner = & $build $def.Palette
    $frag = "<Canvas xmlns=`"http://schemas.microsoft.com/winfx/2006/xaml/presentation`" Width=`"58`" Height=`"60`">$inner</Canvas>"
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

    $pawBrush = B $def.Palette.paw
    $LeftPaw.Fill  = $pawBrush
    $RightPaw.Fill = $pawBrush
    $script:MascotId = $id
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
function New-TrayIcon([string]$hex) {
    # Drawn at runtime rather than shipped as a .ico, so the project stays a
    # single script with no binary assets to keep in sync.
    $fill = [System.Drawing.ColorTranslator]::FromHtml($hex)
    $edge = [System.Drawing.Color]::FromArgb(200,
        [Math]::Max(0, $fill.R - 70), [Math]::Max(0, $fill.G - 70), [Math]::Max(0, $fill.B - 70))

    $bmp = New-Object System.Drawing.Bitmap 32, 32
    $g   = [System.Drawing.Graphics]::FromImage($bmp)
    $g.SmoothingMode = [System.Drawing.Drawing2D.SmoothingMode]::AntiAlias
    $g.Clear([System.Drawing.Color]::Transparent)

    $brush = New-Object System.Drawing.SolidBrush $fill
    $pen   = New-Object System.Drawing.Pen $edge, 2.0
    try {
        # A quokka head: two ears over a round face. Recognisable at 16 px and
        # distinct from the many other round tray icons.
        foreach ($x in 4, 18) {
            $g.FillEllipse($brush, $x, 2, 10, 11)
            $g.DrawEllipse($pen,   $x, 2, 10, 11)
        }
        $g.FillEllipse($brush, 3, 8, 26, 22)
        $g.DrawEllipse($pen,   3, 8, 26, 22)

        # Eyes, in the edge colour so they read on any taskbar background.
        $dark = New-Object System.Drawing.SolidBrush $edge
        try {
            $g.FillEllipse($dark, 10, 15, 5, 6)
            $g.FillEllipse($dark, 18, 15, 5, 6)
        } finally { $dark.Dispose() }
    } finally {
        $brush.Dispose(); $pen.Dispose(); $g.Dispose()
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

# Pre-built once per state: swapping a cached icon costs nothing, and nothing
# is allocated on the hot path.
$TrayIcons = @{
    idle    = New-TrayIcon '#5B6780'
    working = New-TrayIcon '#4ADE80'
    alert   = New-TrayIcon '#FFD23D'
}

$Tray = New-Object System.Windows.Forms.NotifyIcon
$Tray.Icon = $TrayIcons.idle
$Tray.Text = 'Scout Companion - idle'
$Tray.Visible = $true

function Set-TrayState([string]$state, [string]$detail) {
    if ($TrayIcons.ContainsKey($state)) { $Tray.Icon = $TrayIcons[$state] }
    # NotifyIcon.Text is capped at 63 characters and throws above it.
    $t = "Scout Companion - $detail"
    if ($t.Length -gt 63) { $t = $t.Substring(0, 60) + '...' }
    $Tray.Text = $t
}

function Stop-Companion {
    # Every exit path funnels through here: an orphaned NotifyIcon lingers in
    # the tray until the user hovers over it, which looks like a crash.
    try { $timer.Stop() } catch { }
    try { $anim.Stop() }  catch { }
    try { if ($script:SettingsWindow) { $script:SettingsWindow.Close() } } catch { }
    try {
        $Tray.Visible = $false
        $Tray.Dispose()
        foreach ($i in $TrayIcons.Values) { $i.Dispose() }
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
    $script:SettingsAutoHint.Text = 'Could not update the Startup folder. Check that you can write to it.'
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

    $sw = [Windows.Markup.XamlReader]::Load((New-Object System.Xml.XmlNodeReader $settingsXaml))

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
    $closeBtn                 = $sw.FindName('CloseSettingsBtn')

    # Reflect reality, not a remembered flag. Set before the handlers are
    # attached so priming the controls cannot fire them.
    $script:SettingsAutoCheck.IsChecked = Test-AutoStart
    if (-not (Test-Path $WatcherPath)) {
        $script:SettingsAutoCheck.IsEnabled = $false
        $script:SettingsAutoHint.Text = "Watch-Scout.ps1 is missing from $ScriptDir, so this cannot be turned on."
    }
    $script:SettingsAnimCheck.IsChecked = $script:AnimEnabled

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
            $TrayIcons.idle.Handle,
            [System.Windows.Int32Rect]::Empty,
            [System.Windows.Media.Imaging.BitmapSizeOptions]::FromEmptyOptions())
    } catch { }

    $sw.Show()
    $sw.Activate()
}

$MenuShow  = New-Object System.Windows.Forms.ToolStripMenuItem 'Show toast'
$MenuOpen  = New-Object System.Windows.Forms.ToolStripMenuItem 'Open Scout'
$MenuPause = New-Object System.Windows.Forms.ToolStripMenuItem 'Pause animation'
$MenuSet   = New-Object System.Windows.Forms.ToolStripMenuItem 'Settings...'
$MenuExit  = New-Object System.Windows.Forms.ToolStripMenuItem 'Exit'
$MenuPause.CheckOnClick = $true
$MenuPause.Checked = -not $script:AnimEnabled

$MenuShow.Add_Click({ $script:Hidden = $false })
$MenuOpen.Add_Click({ Focus-Agent })
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
$Tray.Add_MouseDoubleClick({ Focus-Agent })

# ---------------------------------------------------------------------------
# Quokka animation: a dedicated timer drives the mascot frame-by-frame.
# Working => bobbing body + alternating "typing" paws. Idle => slow breathing.
#
# The timer is started and stopped with the toast (see the poll loop below):
# animating a window nobody can see costs real CPU for nothing.
# ---------------------------------------------------------------------------
$script:Phase = 0.0
$script:Busy  = $false
$script:PrevBusy = $false

function Reset-Mascot {
    # Neutral pose, used when the animation is paused or switched off.
    $BodyT.Y = 0; $BodyT.X = 0
    $BodyS.ScaleX = 1.0; $BodyS.ScaleY = 1.0
    $LeftPawT.Y = 0; $RightPawT.Y = 0
}

$anim = New-Object System.Windows.Threading.DispatcherTimer
$anim.Interval = [TimeSpan]::FromMilliseconds([int]$Config.animIntervalMs)
# Phase steps are scaled so the mascot moves at the same speed regardless of the
# configured frame rate.
$script:PhaseScale = [double]$Config.animIntervalMs / 50.0
$anim.Add_Tick({
    if ($script:Pending) {
        # gentle attention pulse on the yellow alert glow
        $script:Phase += 0.20 * $script:PhaseScale
        $puls = ([Math]::Sin($script:Phase * 3.0) + 1.0) / 2.0
        $RootGlow.BlurRadius = 16 + $puls * 18
        $RootGlow.Opacity    = 0.55 + $puls * 0.4
        # the quokka peeks up, waiting
        $BodyT.Y = [Math]::Sin($script:Phase) * 0.8
        $BodyT.X = 0
        $BodyS.ScaleX = 1.0; $BodyS.ScaleY = 1.0
        $LeftPawT.Y = 0; $RightPawT.Y = 0
    }
    elseif ($script:Busy) {
        $script:Phase += 0.32 * $script:PhaseScale
        $BodyT.Y     = [Math]::Sin($script:Phase * 2.0) * 1.6
        $BodyT.X     = [Math]::Sin($script:Phase) * 0.6
        $BodyS.ScaleX = 1.0
        $BodyS.ScaleY = 1.0
        $LeftPawT.Y  = -[Math]::Max(0, [Math]::Sin($script:Phase * 6.0)) * 2.4
        $RightPawT.Y = -[Math]::Max(0, [Math]::Sin($script:Phase * 6.0 + [Math]::PI)) * 2.4
    } else {
        $script:Phase += 0.04 * $script:PhaseScale
        $breathe = 1.0 + [Math]::Sin($script:Phase) * 0.035
        $BodyS.ScaleX = $breathe
        $BodyS.ScaleY = $breathe
        $BodyT.Y = [Math]::Sin($script:Phase) * 0.6
        $BodyT.X = 0
        $LeftPawT.Y = 0
        $RightPawT.Y = 0
    }
})

# ---------------------------------------------------------------------------
# Main loop: poll events + decide visibility + render.
# ---------------------------------------------------------------------------
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
    $ageSec = ([datetime]::UtcNow - $State.LastEventUtc).TotalSeconds
    $running = ($State.Steps | Where-Object { -not $_.Done } | Measure-Object).Count -gt 0
    $isActive = $hasPending -or $running -or ($State.TurnActive) -or ($State.EventsPath -and $ageSec -le [double]$Config.activeWindowSeconds)

    $script:Busy = (-not $hasPending) -and ($State.TurnActive -or $running -or ($ageSec -le 6))
    $script:Pending = $hasPending

    # The ✕ button only dismisses the CURRENT burst. Re-show automatically when a
    # new approval arrives, or when a fresh working turn begins (idle -> busy edge),
    # so closing it once doesn't mute the companion forever.
    if ($script:Hidden -and $hasPending) { $script:Hidden = $false }
    if ($script:Hidden -and $script:Busy -and -not $script:PrevBusy) { $script:Hidden = $false }
    $script:PrevBusy = $script:Busy

    # pick the visual state: approval > working > idle, swap only on change
    $desiredState = if ($hasPending) { 'alert' } elseif ($script:Busy -and $agentRunning) { 'working' } else { 'idle' }
    if ($desiredState -ne $script:ThemeState) {
        Set-Theme $desiredState
        $script:ThemeState = $desiredState
        $detail = switch ($desiredState) {
            'alert'   { 'approval needed' }
            'working' { 'Scout is working' }
            default   { if ($agentRunning) { 'idle' } else { 'agent not detected' } }
        }
        Set-TrayState $desiredState $detail
    }

    # content
    if ($hasPending) {
        $first = $State.PendingPerms[ @($State.PendingPerms.Keys)[0] ]
        $extra = if ($State.PendingPerms.Count -gt 1) { " (+$($State.PendingPerms.Count - 1))" } else { '' }
        $HeaderText.Text = "Approval needed$extra"
        $PermText.Text = $first.text
        $PermPanel.Visibility = 'Visible'
        $Dot.Fill = '#FFB45309'
        # keep the yellow alert focused: hide the step list and narration
        $SayingText.Visibility = 'Collapsed'
        $StepsPanel.Visibility = 'Collapsed'
    } else {
        $PermPanel.Visibility = 'Collapsed'
        if (-not $agentRunning) { $HeaderText.Text = 'Agent not detected'; $Dot.Fill = '#FF8A93A6' }
        elseif ($script:Busy)   { $HeaderText.Text = 'Working hard...';     $Dot.Fill = '#FF4ADE80' }
        else                    { $HeaderText.Text = 'Idle';                $Dot.Fill = '#FF8A93A6' }

        if ($State.Saying) { $SayingText.Text = $State.Saying; $SayingText.Visibility = 'Visible' }
        else { $SayingText.Visibility = 'Collapsed' }

        Render-Steps
    }

    # visibility policy
    $shouldShow = $false
    if ($hasPending) { $shouldShow = $true }
    elseif ($isActive -and $agentRunning -and ($isMinimized -or -not $isForeground)) { $shouldShow = $true }
    if ($script:Hidden) { $shouldShow = $false }

    if ($env:SCOUT_COMPANION_DEBUG -or (Test-Path (Join-Path $env:TEMP 'scout-companion-debug.on'))) {
        try {
            $dbg = "{0} show={1} pend={2} active={3} run={4} agent={5} fg={6} min={7} hidden={8} age={9} hwnd='{10}'" -f `
                (Get-Date -Format 'HH:mm:ss'), $shouldShow, $hasPending, $isActive, $running, $agentRunning, $isForeground, $isMinimized, $script:Hidden, [int]$ageSec, ($win.Hwnd)
            Add-Content -Path (Join-Path $env:TEMP 'scout-companion-debug.log') -Value $dbg
        } catch { }
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
})

# prime to current end of the active session
$initial = Find-ActiveSession
if ($initial) {
    $fi = New-Object System.IO.FileInfo $initial.Events
    $State.SessionDir = $initial.Dir
    $State.EventsPath = $initial.Events
    $State.Offset     = $fi.Length
    $State.LastEventUtc = $fi.LastWriteTimeUtc
}
$script:SessionScanUtc = [datetime]::UtcNow

# Draw the configured mascot. This has to run after the mascot functions are
# defined, so it deliberately lives here rather than next to Set-Theme.
Set-Mascot ([string]$Config.mascot)

# The mascot timer is driven by the poll loop and only runs while the toast is
# on screen, so it deliberately does not start here.
$timer.Start()

$Window.Visibility = 'Hidden'
# Make sure the tray icon never outlives the process, however it ends.
$Window.Add_Closed({
    try { $Tray.Visible = $false; $Tray.Dispose() } catch { }
})
$app = New-Object System.Windows.Application
# The toast is the app: closing it exits, and any settings window opened from
# the tray is free to come and go without taking the companion down with it.
$app.ShutdownMode = [System.Windows.ShutdownMode]::OnMainWindowClose
$app.Run($Window) | Out-Null
