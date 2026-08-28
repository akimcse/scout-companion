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

# Bumped by hand, and the tag that goes with it is what a release is cut from.
# Semantic versioning, read from the user's side of the app: MAJOR when
# something they rely on changes shape, MINOR for a new capability, PATCH for a
# fix that only ever makes an existing one behave.
#
# Deliberately below 1.0. Under semver that says the shape of this thing is
# still settling, which is the honest position: it is finding and fixing its
# own significant faults faster than it is gaining features. 1.0 is a claim
# about stability, and it has not earned one yet.
$CompanionVersion = '0.9.0'

Add-Type -AssemblyName PresentationFramework
Add-Type -AssemblyName PresentationCore
Add-Type -AssemblyName WindowsBase
Add-Type -AssemblyName UIAutomationClient
Add-Type -AssemblyName UIAutomationTypes
Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing

# ---------------------------------------------------------------------------
# One companion at a time.
#
# Nothing stopped a second one starting, and nothing on screen said one was
# already running: the toast sets ShowInTaskbar="False" so it never appears in
# the taskbar, and Windows files a new tray icon into the hidden overflow
# flyout. Two Start Menu entries ship - "Scout Companion" and the "(auto)"
# watcher - and either can be launched again on top of a copy already there.
#
# The duplicates are invisible as duplicates, and present as unrelated faults:
#
#   - the toasts stack exactly on top of each other, and since each is drawn at
#     the configured opacity the pile is opaque however far the slider goes;
#   - every instance finds the Allow button and invokes it, so one approval is
#     answered several times;
#   - each writes titles.json on its own schedule, and the interleaved
#     read-modify-write loses learned chat names.
#
# A named mutex in the Local\ namespace is per-session and needs no cleanup on
# a crash - Windows releases it with the process. The second instance hands its
# request to the first and leaves: launching it again pins the toast, so the
# launch has a visible result, which is what the user wanted by launching it.
$script:InstanceMutex = $null
$script:ShowRequest   = $null
try {
    $script:ShowRequest = New-Object System.Threading.EventWaitHandle(
        $false, [System.Threading.EventResetMode]::AutoReset, 'Local\ScoutCompanion.Show')
    $created = $false
    $script:InstanceMutex = New-Object System.Threading.Mutex($true, 'Local\ScoutCompanion.Instance', [ref]$created)
    if (-not $created) {
        try { [void]$script:ShowRequest.Set() } catch { }
        try { $script:InstanceMutex.Dispose() } catch { }
        exit 0
    }
} catch {
    # A lock we cannot take is not a reason to refuse to run: a possible
    # duplicate is better than no companion at all.
    Write-Warning "Could not take the single-instance lock: $($_.Exception.Message)"
}

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

        [System.Runtime.InteropServices.StructLayout(System.Runtime.InteropServices.LayoutKind.Sequential)]
        public struct INPUT {
            public uint type;
            public INPUTUNION U;
        }

        [System.Runtime.InteropServices.StructLayout(System.Runtime.InteropServices.LayoutKind.Explicit)]
        public struct INPUTUNION {
            [System.Runtime.InteropServices.FieldOffset(0)] public MOUSEINPUT mi;
            [System.Runtime.InteropServices.FieldOffset(0)] public KEYBDINPUT ki;
        }

        [System.Runtime.InteropServices.StructLayout(System.Runtime.InteropServices.LayoutKind.Sequential)]
        public struct MOUSEINPUT {
            public int dx, dy;
            public uint mouseData, dwFlags, time;
            public System.UIntPtr dwExtraInfo;
        }

        [System.Runtime.InteropServices.StructLayout(System.Runtime.InteropServices.LayoutKind.Sequential)]
        public struct KEYBDINPUT {
            public ushort wVk, wScan;
            public uint dwFlags, time;
            public System.UIntPtr dwExtraInfo;
        }

        [System.Runtime.InteropServices.DllImport("user32.dll", SetLastError=true)]
        private static extern uint SendInput(uint count, INPUT[] inputs, int size);

        private const uint INPUT_KEYBOARD = 1;
        private const uint KEYEVENTF_KEYUP = 0x0002;
        private const uint KEYEVENTF_UNICODE = 0x0004;

        private static void SendKey(ushort virtualKey, bool keyUp) {
            var input = new INPUT {
                type = INPUT_KEYBOARD,
                U = new INPUTUNION {
                    ki = new KEYBDINPUT {
                        wVk = virtualKey,
                        dwFlags = keyUp ? KEYEVENTF_KEYUP : 0
                    }
                }
            };
            if (SendInput(1, new INPUT[] { input },
                    System.Runtime.InteropServices.Marshal.SizeOf(typeof(INPUT))) != 1) {
                throw new System.ComponentModel.Win32Exception();
            }
        }

        public static void SendUnicodeText(string text) {
            foreach (char ch in text) {
                var down = new INPUT {
                    type = INPUT_KEYBOARD,
                    U = new INPUTUNION {
                        ki = new KEYBDINPUT {
                            wScan = ch,
                            dwFlags = KEYEVENTF_UNICODE
                        }
                    }
                };
                var up = down;
                up.U.ki.dwFlags = KEYEVENTF_UNICODE | KEYEVENTF_KEYUP;
                if (SendInput(2, new INPUT[] { down, up },
                        System.Runtime.InteropServices.Marshal.SizeOf(typeof(INPUT))) != 2) {
                    throw new System.ComponentModel.Win32Exception();
                }
            }
        }

        public static void SendEnter() {
            SendKey(0x0D, false);
            SendKey(0x0D, true);
        }

        public static System.Collections.Generic.List<System.IntPtr> TopLevelWindows(
                System.Collections.Generic.HashSet<uint> pids) {
            var found = new System.Collections.Generic.List<System.IntPtr>();
            EnumWindows(delegate (System.IntPtr h, System.IntPtr l) {
                // Minimised counts. Scout minimises to the tray, which clears
                // IsWindowVisible, and that is precisely when the companion
                // matters most - so skipping those windows would blind it to
                // the app exactly when it is being relied on. A minimised
                // window keeps its whole accessibility tree: measured at 173
                // buttons and 58 chat rows on one.
                if (!IsWindowVisible(h) && !IsIconic(h)) return true;
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
    # How often to look for Scout's own chat titles in a sidebar that is
    # already open. Only ever a read - nothing is clicked, typed or focused -
    # and it is skipped entirely once every session has a name. Set to 0 to
    # never look.
    chatTitleScanMs     = 15000
    # Reading a sidebar means walking an accessibility tree with hundreds of
    # nodes in it, and most of the time there is nothing there to learn, so the
    # interval doubles on every fruitless look up to this ceiling. It drops
    # back to chatTitleScanMs as soon as a conversation turns up without a name.
    chatTitleScanMaxMs  = 300000
    # How many fruitless looks a conversation gets before it is left alone.
    # Two sessions started inside the same minute cannot be told apart by
    # whole-minute sidebar rows, so some are unnameable and were being retried
    # for as long as the companion ran. A new request resets the count, since
    # that is the one thing that can change the answer.
    chatTitleScanTries  = 3
    # Mascot frame interval. 80 ms (12.5 fps) is smooth enough for a bob and a
    # typing paw, and costs roughly half of the old 50 ms (20 fps).
    animIntervalMs      = 80
    # Mascot animation can be switched off entirely from the tray or settings.
    animationEnabled    = $true
    # Reuse the local Scout Voice runtime as a headless child process. This only
    # follows the companion's lifetime. Both choices are persisted in config.
    voiceCommandEnabled = $false
    voiceReplyEnabled   = $true
    voiceWakeSensitivity = 65
    voiceNoiseSensitivity = 35
    voiceRuntimeDir     = $null
    # Which name to show for a conversation on the toast: $false shows what you
    # actually asked (the session's own first message / latest request), $true
    # shows Scout's own sidebar title for the chat. The chat title is still
    # learned either way and always used to switch to the right conversation -
    # this only controls the label you read.
    showChatTitle       = $false
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
    # Put the toast back where you last dragged it, rather than in the corner.
    # The position is checked against the screens that exist at the time: an
    # undocked laptop or a changed resolution falls back to the corner rather
    # than restoring the toast somewhere unreachable - it has no taskbar button
    # to get it back with.
    rememberPosition    = $true
    windowLeft          = $null
    windowTop           = $null
    # Say so when a long turn finishes. Measured over three days of real use: 83
    # turns ran over two minutes and 8 over ten, and while one of those is going
    # you are looking at something else with no way to know it ended.
    #
    # Only when the toast is not on screen and the agent is not in front -
    # otherwise it is telling you what you are already looking at.
    notifyOnFinish      = $true
    notifyAfterSeconds  = 60
    # Check GitHub for a newer release and say so in the tray. The check is
    # cheap and infrequent; installing is a click, not automatic, because
    # replacing a running process mid-approval is not a good surprise.
    updateCheck         = $true
    updateCheckHours    = 6
    updateRepo          = 'akimcse/scout-companion'
    # Set true to install as soon as one is found, without asking. Only takes
    # effect for an installed copy, never a source checkout.
    autoUpdate          = $false
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
    # Explicit <ToolTip> elements carry their text as inner content rather than a
    # ToolTip="..." attribute, so translate that too. They exist because a tooltip
    # placed reliably (Placement set on the ToolTip itself) needs to be a real
    # element, not the string form WPF turns into one with its own defaults.
    foreach ($tt in $doc.SelectNodes('//*[local-name()="ToolTip"]')) {
        $v = $tt.InnerText
        if (-not $v) { continue }
        if ($v -match '^\s*$') { continue }
        $t = $script:Strings[$v.Trim()]
        if ($t) { $tt.InnerText = $t }
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
        TurnStartUtc = $null      # when the current turn began, for its duration
        LastEventUtc = [datetime]::UtcNow
        # When this session first appeared. The multi-session list is ordered by
        # this and never by activity: sorting by what moved last would put the
        # lines themselves in motion, which is the churn the list exists to
        # remove. A new session joins the bottom and the others stay put.
        FirstSeenUtc = [datetime]::UtcNow
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
    # The session the step list and narration belong to, so the toast can name
    # it. Merged from whichever session moved last, alongside its steps.
    Primary         = $null
    AgentHwnd       = [IntPtr]::Zero
}

# Caches that keep the poll loop off the expensive code paths.
$script:WinCache          = $null                  # last known agent window
$script:LastTitleScanUtc  = [datetime]::MinValue   # throttle for the full process scan
$script:SessionScanUtc    = [datetime]::MinValue   # throttle for the full session scan
$script:StepSignature     = $null                  # last rendered step list
$script:ChatScanUtc       = [datetime]::MinValue   # throttle for the sidebar read
$script:ChatScanEvery     = 0                      # current backoff interval, ms
$script:ChatScanSig       = $null                  # which sessions were still unnamed
$script:ChatScanKnown     = @()                    # ...and which had already been seen
$script:ChatScanTries     = @{}                    # fruitless looks, per session
$script:ChatScanLooked    = $false                 # did the last scan get as far as searching
$script:AutomationCache   = @{}                    # dir -> is this a scheduled-automation run (never changes)

# ---------------------------------------------------------------------------
# Learned chat titles.
#
# Scout's own name for a chat costs a sidebar read to work out, and without
# somewhere to keep it that work is thrown away almost immediately: the title
# lives on the session record, and the record is dropped as soon as the session
# goes quiet - and again on every restart. A title learned once should stay
# learned, so it is written next to the config, keyed by session folder.
#
# A title belongs to exactly one session. Several sessions working in the same
# folder at the same time all match the freshest sidebar row, so without that
# rule they each claim the same chat and the label stops identifying anything -
# which is the only reason it is on the toast. Observed for real: two
# automations and a chat session, all three named "Scout Companion".
# ---------------------------------------------------------------------------
$TitleStorePath = Join-Path $ScriptDir 'titles.json'
$script:TitleStore = @{}

function Import-TitleStore {
    if (-not (Test-Path $TitleStorePath)) { return }
    $raw = @{}
    try {
        $o = Get-Content $TitleStorePath -Raw | ConvertFrom-Json
        foreach ($p in $o.PSObject.Properties) {
            # Sessions are deleted eventually, and their titles would otherwise
            # accumulate forever in a file nobody ever prunes.
            if ($p.Value -and (Test-Path $p.Name)) { $raw[$p.Name] = [string]$p.Value }
        }
    } catch { return }

    # Repair on the way in. A store written before the one-title-one-session
    # rule can hold the same name against several folders, and there is nothing
    # in it to say which one was right - so none of them keep it.
    $count = @{}
    foreach ($k in $raw.Keys) {
        $t = $raw[$k]
        if ($count.ContainsKey($t)) { $count[$t]++ } else { $count[$t] = 1 }
    }
    $dropped = $false
    foreach ($k in $raw.Keys) {
        if ($count[$raw[$k]] -gt 1) { $dropped = $true; continue }
        $script:TitleStore[$k] = $raw[$k]
    }
    if ($dropped) { Save-TitleStore }
}

function Save-TitleStore {
    try {
        $o = [ordered]@{}
        foreach ($k in ($script:TitleStore.Keys | Sort-Object)) { $o[$k] = $script:TitleStore[$k] }
        ($o | ConvertTo-Json -Depth 3) | Set-Content -Path $TitleStorePath -Encoding UTF8
    } catch { }
}

function Set-LearnedTitle([string]$dir, [string]$title) {
    if (-not $dir -or -not $title) { return }
    if ($script:TitleStore[$dir] -eq $title) { return }
    $script:TitleStore[$dir] = $title
    Save-TitleStore
}

function Remove-LearnedTitle([string]$dir) {
    if (-not $dir) { return }
    if (-not $script:TitleStore.ContainsKey($dir)) { return }
    $script:TitleStore.Remove($dir)
    Save-TitleStore
}

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

    # 1b) Minimised to the tray. MainWindowHandle goes to zero when Scout is
    #     minimised, so the step above finds nothing and the toast would say
    #     "agent not detected" about an app that is running and working - while
    #     minimised is exactly when the companion is what you are watching.
    #     The enumeration knows about those windows, so ask it.
    $mins = @(Get-AgentWindows)
    if ($mins.Count -gt 0) {
        $owner = [uint32]0
        try { [void][ScoutNative]::GetWindowThreadProcessId($mins[0], [ref]$owner) } catch { }
        $script:WinCache = @{ Hwnd = $mins[0]; Pid = [int]$owner }
        return $script:WinCache
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

function Test-AutomationSession([string]$dir, [string]$events) {
    # A scheduled automation run, not a conversation you can open. Scout injects
    # a fixed runner reminder into the first user turn of an automation - "in a
    # scheduled automation. The step instruction is provided as the user
    # message" - and nothing like it appears in a chat you typed yourself. So the
    # test reads only as far as the first user.message and looks for that phrase.
    #
    # Deliberately not a bare substring over the whole file: a chat that merely
    # talks about automations (this project's own does) carries the phrase deep
    # in its history, so matching anywhere would wrongly hide it. The first user
    # turn is where a real automation run - and only a real one - has it.
    #
    # Cached because a session's nature never changes, and the scan runs on every
    # candidate every rescan otherwise.
    if ($script:AutomationCache.ContainsKey($dir)) { return $script:AutomationCache[$dir] }
    $marker = 'in a scheduled automation. The step instruction is provided as the user message'
    $isAuto = $false
    try {
        $fs = [System.IO.File]::Open($events, 'Open', 'Read', 'ReadWrite')
        try {
            $sr = New-Object System.IO.StreamReader($fs)
            for ($i = 0; $i -lt 400; $i++) {
                $line = $sr.ReadLine()
                if ($null -eq $line) { break }
                if ($line -notmatch '"type":"user\.message"') { continue }
                # The first user turn: an automation declares itself here, an
                # interactive chat does not. Either way the search is over.
                $isAuto = $line.Contains($marker)
                break
            }
        } finally { $fs.Dispose() }
    } catch { }
    $script:AutomationCache[$dir] = $isAuto
    return $isAuto
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
        # Scheduled automations run headless and cannot be opened - clicking a row
        # for one would search the sidebar with its giant injected instruction and
        # land nowhere. They are not conversations you are having, so they are left
        # off the toast entirely.
        if (Test-AutomationSession $dir $ev) { continue }
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
    # The chat title is learned for matching regardless, but which name is shown
    # is the user's choice: by default the toast shows what you actually asked,
    # not Scout's summarised sidebar title, so a prompt you just sent is not
    # replaced by a title the moment it is learned.
    if ($Config.showChatTitle) {
        if ($rec.ChatTitle) { return $rec.ChatTitle }
        if ($rec.Subject)   { return $rec.Subject }
    } else {
        if ($rec.Subject)   { return $rec.Subject }
        if ($rec.ChatTitle) { return $rec.ChatTitle }
    }
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
        # Scout's own title for the chat is already the name the user reads in
        # the sidebar, so it needs no disambiguating of its own - a title
        # belongs to one session by construction, enforced where titles are
        # assigned. The final sweep below is the belt to that braces, because
        # Get-RaisingSession finds a session by matching this label and would
        # hand back the wrong one if two ever collided.
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
    }
    # One sweep over everything, titles included. Two sessions can land on the
    # same text by truncating alike, and a duplicate label does not merely read
    # badly - it makes Open land on whichever session was seen first.
    $seen = @{}
    foreach ($dir in $Sessions.Keys) {
        $rec = $Sessions[$dir]
        if (-not $rec.Label) { $rec.Label = $rec.BaseLabel }
        if ($seen.ContainsKey($rec.Label)) {
            $rec.Label = "$($rec.Label) - $((Split-Path $rec.Dir -Leaf).Substring(0,6))"
        }
        $seen[$rec.Label] = $true
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
        # A title learned on an earlier run, or before this session last went
        # quiet. Cheaper and steadier than working it out again, and it means
        # the name on the toast survives a restart.
        $t = $script:TitleStore[$s.Dir]
        if ($t) { $rec.ChatTitle = $t }
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

    # Separate throttle: a sidebar read is much more expensive than a file stat,
    # and unlike the session scan it is usually pointless - it can only learn
    # anything while a sidebar is open in front of it, with its search field
    # open too. Measured at half again the companion's whole CPU cost when run
    # flat out, so a fruitless look backs off and an unnamed conversation
    # turning up brings it straight back.
    # Learning what Scout calls a chat means typing into its search box, because
    # the sidebar only puts timestamps on rows once a query has been typed - and
    # a timestamp is the only thing that can match a chat to a session folder,
    # the two being different namespaces joined by an encrypted index.
    #
    # That is intrusive, so it only happens when the answer is actually wanted.
    # showChatTitle defaulted to off in 0.8.0 and this was not revisited, so the
    # companion went on typing into the search box every fifteen seconds to
    # learn a name it then did not display. Nothing else needs it either: Open
    # finds the chat by topic overlap and learns the title as a side effect, and
    # session labels fall back to the working directory plus topic.
    $base = if ($Config.showChatTitle) { [double]$Config.chatTitleScanMs } else { 0 }
    if ($base -gt 0) {
        # A session that cannot be named stays unnamed forever - two sessions
        # started within the same minute cannot be told apart by whole-minute
        # rows, by design - and without a limit it is retried for as long as the
        # companion runs. Attempts are per session and reset when that session
        # is asked something new, which is the one thing that can change the
        # answer.
        $unnamed = @($Sessions.Keys | Where-Object {
            -not $Sessions[$_].ChatTitle -and
            [int]$script:ChatScanTries[$_] -lt [int]$Config.chatTitleScanTries
        } | Sort-Object)
        $sig = ($unnamed -join '|')
        # Reset the backoff only when the set gains a session, never when it
        # loses one. Comparing the whole set meant that giving up on a session,
        # or naming one, shrank the set and so reset the interval to its
        # shortest - measured going straight back to 15s the moment a session
        # was set aside, which is the opposite of what giving up should do.
        $fresh = @($unnamed | Where-Object { $_ -notin $script:ChatScanKnown })
        if ($fresh.Count) {
            $script:ChatScanEvery = $base
        }
        $script:ChatScanKnown = $unnamed
        $script:ChatScanSig   = $sig
        if ($script:ChatScanEvery -le 0) { $script:ChatScanEvery = $base }
        if ($sig -and ([datetime]::UtcNow - $script:ChatScanUtc).TotalMilliseconds -ge $script:ChatScanEvery) {
            $script:ChatScanUtc = [datetime]::UtcNow
            $got = $false
            try { $got = Update-SessionTitles } catch { }
            if ($got) { $script:ChatScanEvery = $base }
            elseif ($script:ChatScanLooked) {
                # Looked and found nothing: worth trying less often, and worth
                # counting against the sessions that were looked for so they are
                # not retried forever.
                foreach ($d in $unnamed) { $script:ChatScanTries[$d] = [int]$script:ChatScanTries[$d] + 1 }
                $cap = [double]$Config.chatTitleScanMaxMs
                $script:ChatScanEvery = [Math]::Min($script:ChatScanEvery * 2, $cap)
            }
            # Otherwise it never got to look - almost always because a Scout
            # window was in front - which says nothing about whether there is
            # anything to find, so the interval stays where it is. Backing off
            # for that reason is what stopped it ever learning anything while
            # the app was being used.
        }
    }
}

# Names the conversation a prompt came from. Always, now that it can say
# something worth reading: Scout's own chat title once it has been read off the
# sidebar, and until then the latest thing that session was asked to do. Only a
# bare folder name stays behind the "more than one session" rule it always had,
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
        # Shaped like a pending prompt so the same naming rule covers both.
        $State.Primary      = @{ session = $primary.Label; title = (Get-SessionSubject $primary) }
    }
}

# An event's own timestamp, falling back to now when it has none or it will not
# parse. Kept separate because getting this wrong is silent: the companion reads
# a session's whole backlog on its first pass, so dating those events "now"
# would collapse hours of history into the instant the app started.
function ConvertTo-EventTime($evt) {
    if ($evt.timestamp) {
        try { return ([datetime]$evt.timestamp).ToUniversalTime() } catch { }
    }
    return [datetime]::UtcNow
}

# A total, as opposed to an age. Format-Idle deliberately shows one unit because
# it sits at the end of a narrow line - but "17h" for 17 hours 40 minutes throws
# away the part someone actually wants when reading a day's total, so this keeps
# two.
function Format-Duration([double]$seconds) {
    if ($seconds -lt 1) { return '-' }
    if ($seconds -lt 60) { return ('{0:N0}s' -f $seconds) }
    $ts = [TimeSpan]::FromSeconds($seconds)
    # .Hours and .Minutes, not [int]$ts.TotalHours. PowerShell's [int] cast
    # rounds rather than truncating, so 17h40m came out as "18h 40m" - an hour
    # that does not exist alongside a minute count that does.
    if ($ts.TotalHours -ge 1) { return ('{0}h {1}m' -f ([int][Math]::Floor($ts.TotalHours)), $ts.Minutes) }
    return ('{0}m {1}s' -f $ts.Minutes, $ts.Seconds)
}

# One completed turn. Feeds both the day's totals and the "it finished" notice.
#
# Turns are kept only for today, and only as a count and a sum: a companion that
# accumulates a row per turn would grow without bound in a process meant to sit
# in the tray all day.
$script:TurnsToday    = 0
$script:TurnSecsToday = 0.0
$script:TurnDay       = [datetime]::Now.Date
$script:LongTurn      = $null    # the one worth mentioning, picked up by the tick

function Add-TurnRecord($sess, [datetime]$startUtc, [datetime]$endUtc, [double]$secs) {
    # Local date, because "today" is the user's day, not UTC's.
    $day = $endUtc.ToLocalTime().Date
    if ($day -ne $script:TurnDay) {
        $script:TurnDay = $day
        $script:TurnsToday = 0
        $script:TurnSecsToday = 0.0
    }
    $script:TurnsToday++
    $script:TurnSecsToday += $secs

    if (-not $Config.notifyOnFinish) { return }
    if ($secs -lt [double]$Config.notifyAfterSeconds) { return }
    # Only turns that just happened. On startup the backlog is read in one pass,
    # and announcing a turn that ended yesterday would be worse than useless.
    if (([datetime]::UtcNow - $endUtc).TotalSeconds -gt 30) { return }

    # Decided on the tick, not here: whether to show it depends on where the
    # windows are, and this runs from the file reader.
    $script:LongTurn = [pscustomobject]@{
        Name = (Get-SessionSubject $sess)
        Secs = $secs
    }
}

# Scout describes every permission request twice: once for a machine - the
# command, the path, the argument object - and once for a person, in `intention`
# (present on four requests in five) or `toolTitle`. Only the machine half was
# ever shown, so an approval arrived reading
#
#   $s="$env:USERPROFILE\.copilot\session-state\6c8d..\files" $m="$env:USER...
#
# and answering it meant parsing shell first. The readable half was in the event
# the whole time.
#
# So: a headline in prose, and the literal request underneath for anyone who
# wants to check it - which is the point of the prompt, and the reason the
# detail is kept rather than replaced. Monospace only where the detail is code;
# a path or a URL reads better in the UI font.
function Format-PermissionRequest($req) {
    $summary = $null
    $detail  = $null
    $mono    = $false
    if (-not $req) { return @{ Summary = (T 'Approval requested'); Detail = ''; Mono = $false } }

    $intent = if ($req.intention) { [string]$req.intention } else { $null }

    switch ([string]$req.kind) {
        'shell' {
            $summary = if ($intent) { $intent } else { T 'Run a shell command' }
            $detail  = if ($req.fullCommandText) { [string]$req.fullCommandText }
                       elseif ($req.commandText) { [string]$req.commandText } else { '' }
            $mono    = $true
            # Worth saying out loud: it is the difference between a command that
            # reads and one that overwrites, and it is not obvious from a glance
            # at a long pipeline.
            if ($req.hasWriteFileRedirection) { $summary = $summary + '  ' + (T '(writes to a file)') }
        }
        'read' {
            $summary = T 'Read a file'
            $detail  = [string]$req.path
        }
        'write' {
            # intention distinguishes a new file from a change to one that
            # exists, which matters more here than anywhere else.
            $summary = if ($intent) { $intent } else { T 'Write to a file' }
            $detail  = [string]$req.fileName
        }
        'url' {
            $summary = if ($intent) { $intent } else { T 'Fetch a web page' }
            $detail  = [string]$req.url
        }
        'mcp' {
            # The server is the part that says whose code is about to run, so it
            # leads. toolTitle is already prose where it exists.
            $title = if ($req.toolTitle) { [string]$req.toolTitle }
                     elseif ($intent)    { $intent }
                     else                { [string]$req.toolName }
            $summary = if ($req.serverName) { '{0}: {1}' -f $req.serverName, $title } else { $title }
            $detail  = Format-PermissionArgs $req.args
            $mono    = $true
        }
        'custom-tool' {
            $summary = if ($intent) { $intent } else { [string]$req.toolName }
            $detail  = Format-PermissionArgs $req.args
            $mono    = $true
        }
        'memory' {
            $summary = if ($intent) { $intent } else { T 'Save a memory' }
            $detail  = if ($req.fact) { [string]$req.fact } else { [string]$req.subject }
        }
        default {
            $summary = if ($intent) { $intent } else { T 'Approval requested' }
            $detail  = if ($req.fullCommandText) { [string]$req.fullCommandText }
                       elseif ($req.path)        { [string]$req.path }
                       elseif ($req.toolName)    { [string]$req.toolName }
                       else                      { '' }
        }
    }

    if (-not $summary) { $summary = T 'Approval requested' }
    if ($null -eq $detail) { $detail = '' }
    # A detail that only repeats the headline is noise. Common for reads, where
    # intention is already "Read file: C:\...".
    if ($detail -and $summary.Contains($detail)) { $detail = '' }
    return @{ Summary = $summary; Detail = $detail; Mono = $mono }
}

# Tool arguments arrive as an object of arbitrary shape. One line per argument
# reads far better than the JSON would, and the values that matter - a url, a
# path, a query - are usually scalars.
function Format-PermissionArgs($argObj) {
    if (-not $argObj) { return '' }
    $lines = @()
    foreach ($p in $argObj.PSObject.Properties) {
        $v = $p.Value
        if ($null -eq $v) { continue }
        $s = if ($v -is [string]) { $v }
             elseif ($v -is [bool] -or $v -is [int] -or $v -is [long] -or $v -is [double]) { [string]$v }
             else { try { ($v | ConvertTo-Json -Depth 3 -Compress) } catch { [string]$v } }
        $lines += '{0}: {1}' -f $p.Name, (Truncate $s 400)
    }
    return ($lines -join "`n")
}

function Handle-Event($sess, $evt) {
    $sess.LastEventUtc = [datetime]::UtcNow
    switch ($evt.type) {
        # Turn timing, which two things depend on: the notification when a long
        # turn finishes, and the day's totals in Settings.
        #
        # The time comes from the event, never from the clock. The companion is
        # often started after a session has been running, and it reads the whole
        # backlog on first pass - dating those turns "now" would report hours of
        # work as having happened in the second the app launched.
        'assistant.turn_start' {
            $sess.TurnActive = $true
            $sess.TurnStartUtc = ConvertTo-EventTime $evt
        }
        'assistant.turn_end'   {
            $sess.TurnActive = $false
            $endUtc = ConvertTo-EventTime $evt
            # A turn whose start was never seen cannot be timed. This is the
            # normal case for the first turn of every session the companion
            # attaches to mid-flight: reading begins at the end of the file, so
            # that turn_start is already behind the offset. Counting it as
            # zero-length, or as starting when the companion launched, would
            # both be inventions - so it is skipped, and the hint under the
            # totals says they begin when the companion did.
            if ($sess.TurnStartUtc) {
                $secs = ($endUtc - $sess.TurnStartUtc).TotalSeconds
                # A clock change or an out-of-order write can produce nonsense;
                # a negative or day-long turn is not worth recording or ringing
                # a bell about.
                if ($secs -gt 0 -and $secs -lt 86400) {
                    Add-TurnRecord $sess $sess.TurnStartUtc $endUtc $secs
                }
                $sess.TurnStartUtc = $null
            }
        }
        'user.message' {
            # Keeps the session's name current as the conversation moves on,
            # without re-reading the file.
            $txt = $evt.data.content
            if ($txt) {
                $sess.Subject = Truncate $txt 40
                # A new request can change what the chat search returns, so it
                # is worth one more look - but only one. Clearing the count
                # outright meant that in an active conversation the scan reset
                # to its shortest interval on every message you sent, so a
                # session that could never be named was retried indefinitely.
                # Decaying instead lets repeated failure still converge.
                if (-not $sess.ChatTitle) {
                    $n = [int]$script:ChatScanTries[$sess.Dir]
                    if ($n -gt 0) { $script:ChatScanTries[$sess.Dir] = $n - 1 }
                }
            }
        }
        'assistant.message' {
            $txt = $evt.data.content; if (-not $txt) { $txt = $evt.data.text }
            if ($txt) {
                $sess.Saying = Truncate $txt 200
            }
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
            $fmt = Format-PermissionRequest $req
            $kind = if ($req) { $req.kind } else { 'permission' }
            # Caps are a guard against a pathological payload, not a display
            # budget - the panel scrolls.
            $sess.PendingPerms[$id] = @{
                summary = (Truncate $fmt.Summary 300)
                text    = (Truncate $fmt.Detail 4000)
                mono    = $fmt.Mono
                kind    = $kind
                session = $sess.Label
            }
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

function Find-AgentButton([IntPtr]$hwnd, [string[]]$labels) {
    # The button with one of these captions in this window, but only if it is
    # actually on screen. Being on screen is the whole signal: Scout keeps its
    # approval buttons in the automation tree whether or not a prompt is up, so
    # mere presence would name every window equally.
    $root = $null
    try { $root = [System.Windows.Automation.AutomationElement]::FromHandle($hwnd) } catch { return $null }
    if (-not $root) { return $null }

    $btnCond = New-Object System.Windows.Automation.PropertyCondition(
        [System.Windows.Automation.AutomationElement]::ControlTypeProperty,
        [System.Windows.Automation.ControlType]::Button)
    $buttons = $null
    try { $buttons = $root.FindAll([System.Windows.Automation.TreeScope]::Descendants, $btnCond) } catch { return $null }
    if (-not $buttons) { return $null }

    # Exact caption first, so a plain "Allow" is taken over "Allow everywhere"
    # when Scout offers both.
    foreach ($label in $labels) {
        foreach ($b in $buttons) {
            $n = $b.Current.Name
            if ($n -and ($n.Trim().ToLower() -eq $label.ToLower()) -and -not $b.Current.IsOffscreen) { return $b }
        }
    }
    foreach ($label in $labels) {
        foreach ($b in $buttons) {
            $n = $b.Current.Name
            if ($n -and ($n -ilike "*$label*") -and -not $b.Current.IsOffscreen) { return $b }
        }
    }
    return $null
}

function Invoke-AgentButton([string[]]$labels) {
    # Which window raised a pending approval cannot be read from the session
    # state - the lock names a backend process, not a UI one - but it can be
    # seen. The window showing the prompt is the window with the button on
    # screen, so look in all of them and act only when exactly one qualifies.
    #
    # Counting windows and refusing above one, as this did before, meant that
    # simply having a second Scout window open turned Allow and Deny into
    # nothing at all - and three windows is an ordinary way to work. The safety
    # property is unchanged: two windows both showing a prompt is genuinely
    # ambiguous, and that still refuses rather than guessing.
    $wins = @(Get-AgentWindows)
    if ($wins.Count -eq 0) {
        $w = Get-AgentWindow
        if (-not $w) { return $false }
        $wins = @($w.Hwnd)
    }

    # Wake them all before reading any, so one sleep covers the set.
    foreach ($h in $wins) { Wake-AgentA11y $h }
    Start-Sleep -Milliseconds 350

    $hits = @()
    foreach ($h in $wins) {
        $b = Find-AgentButton $h $labels
        if ($b) { $hits += $b }
    }
    if ($hits.Count -ne 1) { return $false }

    try {
        $hits[0].GetCurrentPattern([System.Windows.Automation.InvokePattern]::Pattern).Invoke()
        return $true
    } catch { return $false }
}

function Focus-Agent {
    $win = Get-AgentWindow
    if (-not $win) { return }
    # SW_RESTORE, and only for a window that is actually minimized. It used to be
    # called unconditionally, which is the one case where "restore" does harm:
    # against a maximized window that is merely behind something, SW_RESTORE
    # un-maximizes it. So answering a prompt from the toast - which lands here
    # whenever the Allow button cannot be found and pressed directly - shrank
    # Scout to whatever size it last had before being maximized. The approval
    # worked; the window it belonged to came back the wrong size.
    #
    # A window minimized from a maximized state is restored to maximized by
    # SW_RESTORE, so the minimized case needs no special handling.
    if ([ScoutNative]::IsIconic($win.Hwnd)) {
        [void][ScoutNative]::ShowWindow($win.Hwnd, 9)
    }
    [void][ScoutNative]::SetForegroundWindow($win.Hwnd)
}

function Get-AgentMessageBox([IntPtr]$hwnd) {
    $root = $null
    try { $root = [System.Windows.Automation.AutomationElement]::FromHandle($hwnd) } catch { return $null }
    if (-not $root) { return $null }
    $edit = New-Object System.Windows.Automation.PropertyCondition(
        [System.Windows.Automation.AutomationElement]::ControlTypeProperty,
        [System.Windows.Automation.ControlType]::Edit)
    $name = New-Object System.Windows.Automation.PropertyCondition(
        [System.Windows.Automation.AutomationElement]::NameProperty, 'Message')
    try {
        return $root.FindFirst(
            [System.Windows.Automation.TreeScope]::Descendants,
            (New-Object System.Windows.Automation.AndCondition($edit, $name)))
    } catch { return $null }
}

function Get-AgentMessageText($box) {
    if (-not $box) { return $null }
    try {
        $p = $box.GetCurrentPattern([System.Windows.Automation.TextPattern]::Pattern)
        return $p.DocumentRange.GetText(-1).TrimEnd("`r", "`n")
    } catch { return $null }
}

function Get-VoiceEventSnapshot {
    $offsets = @{}
    foreach ($dir in @(Get-ChildItem $SessionRoot -Directory -ErrorAction SilentlyContinue)) {
        $path = Join-Path $dir.FullName 'events.jsonl'
        if (Test-Path $path) {
            try { $offsets[$path] = (New-Object System.IO.FileInfo $path).Length } catch { }
        }
    }
    return $offsets
}

function Read-VoiceEventChunk([string]$path, [long]$offset) {
    $fi = New-Object System.IO.FileInfo $path
    if (-not $fi.Exists -or $fi.Length -le $offset) {
        return [pscustomobject]@{ Offset = $offset; Events = @() }
    }
    if ($fi.Length -lt $offset) { $offset = 0 }
    $fs = [System.IO.File]::Open($path, 'Open', 'Read', 'ReadWrite')
    try {
        $fs.Seek($offset, 'Begin') | Out-Null
        $sr = New-Object System.IO.StreamReader($fs)
        $chunk = $sr.ReadToEnd()
    } finally { $fs.Dispose() }
    # events.jsonl is append-only. Do not commit a partial final line: otherwise
    # the first half and second half both fail JSON parsing and the event is lost.
    $lastNewline = $chunk.LastIndexOf("`n")
    if ($lastNewline -lt 0) {
        return [pscustomobject]@{ Offset = $offset; Events = @() }
    }
    $complete = $chunk.Substring(0, $lastNewline + 1)
    $next = $offset + [System.Text.Encoding]::UTF8.GetByteCount($complete)
    $events = @()
    foreach ($line in ($complete -split "`n")) {
        $line = $line.Trim()
        if (-not $line) { continue }
        try { $events += ($line | ConvertFrom-Json) } catch { }
    }
    return [pscustomobject]@{ Offset = $next; Events = $events }
}

function Write-VoiceUiResponse([string]$id, [string]$answer, [string]$errorText) {
    $value = [ordered]@{ id = $id; answer = $answer; error = $errorText }
    $temporary = $script:VoiceResponsePath + '.tmp'
    ($value | ConvertTo-Json -Compress) | Set-Content $temporary -Encoding UTF8
    Move-Item $temporary $script:VoiceResponsePath -Force
}

function Clear-VoiceUiRequest {
    if ($script:VoiceUiRequest) {
        $script:VoiceLastRequestId = $script:VoiceUiRequest.Id
    }
    $script:VoiceUiRequest = $null
}

function Read-VoiceUiRequest {
    if (-not $script:VoiceEnabled -or $script:VoiceUiRequest -or
            -not (Test-Path $script:VoiceRequestPath)) { return }
    try { $request = Get-Content $script:VoiceRequestPath -Raw -Encoding UTF8 | ConvertFrom-Json } catch { return }
    if (-not $request.id -or -not $request.command -or $request.id -eq $script:VoiceLastRequestId) { return }
    $script:VoiceUiRequest = [pscustomobject]@{
        Id          = [string]$request.id
        Command     = [string]$request.command
        StartedUtc  = [datetime]::UtcNow
        Submitted   = $false
        Hwnd        = [IntPtr]::Zero
        EventPath   = $null
        EventOffset = [long]0
        Offsets     = $null
        Answer      = $null
        SawTurnStart = $false
        SawTurnEnd  = $false
    }
}

function Submit-VoiceUiRequest {
    $request = $script:VoiceUiRequest
    if (-not $request -or $request.Submitted) { return }
    $win = Get-AgentWindow
    if (-not $win) { return }
    Wake-AgentA11y $win.Hwnd
    $send = Find-AgentButton $win.Hwnd @('Send')
    if (-not $send) { return }
    $box = Get-AgentMessageBox $win.Hwnd
    if (-not $box) { return }
    $draft = Get-AgentMessageText $box
    if ($null -eq $draft) { return }
    if ($draft.Trim().Length -gt 0) {
        Write-VoiceUiResponse $request.Id '' 'Scout has an unsent draft. Send or clear it before using voice control.'
        Clear-VoiceUiRequest
        return
    }

    $request.Offsets = Get-VoiceEventSnapshot
    $previous = [ScoutNative]::GetForegroundWindow()
    try {
        [void][ScoutNative]::ShowWindow($win.Hwnd, 9)
        [void][ScoutNative]::SetForegroundWindow($win.Hwnd)
        $box.SetFocus()
        Start-Sleep -Milliseconds 75
        $focused = [System.Windows.Automation.AutomationElement]::FocusedElement
        if (-not $focused -or
                (($focused.GetRuntimeId() -join ',') -ne ($box.GetRuntimeId() -join ','))) {
            throw 'Scout did not accept keyboard focus.'
        }
        [ScoutNative]::SendUnicodeText($request.Command)
        Start-Sleep -Milliseconds 150
        $box = Get-AgentMessageBox $win.Hwnd
        if ((Get-AgentMessageText $box) -ne $request.Command) {
            throw 'Scout did not accept the voice command text.'
        }
        [ScoutNative]::SendEnter()
        $request.Submitted = $true
        $request.Hwnd = $win.Hwnd
    } catch {
        Write-VoiceUiResponse $request.Id '' $_.Exception.Message
        Clear-VoiceUiRequest
    } finally {
        Start-Sleep -Milliseconds 100
        if ($previous -ne [IntPtr]::Zero -and $previous -ne $win.Hwnd) {
            [void][ScoutNative]::SetForegroundWindow($previous)
        }
    }
}

function Read-VoiceUiEvents {
    $request = $script:VoiceUiRequest
    if (-not $request -or -not $request.Submitted) { return }

    $paths = if ($request.EventPath) {
        @($request.EventPath)
    } else {
        @(Get-ChildItem $SessionRoot -Directory -ErrorAction SilentlyContinue |
            ForEach-Object { Join-Path $_.FullName 'events.jsonl' } |
            Where-Object { Test-Path $_ } |
            Sort-Object { (Get-Item $_).LastWriteTimeUtc } -Descending |
            Select-Object -First 8)
    }
    foreach ($path in $paths) {
        $offset = if ($request.EventPath -eq $path) {
            [long]$request.EventOffset
        } elseif ($request.Offsets.ContainsKey($path)) {
            [long]$request.Offsets[$path]
        } else { [long]0 }
        $chunk = Read-VoiceEventChunk $path $offset
        if (-not $request.EventPath) { $request.Offsets[$path] = $chunk.Offset }
        foreach ($evt in $chunk.Events) {
            if (-not $request.EventPath -and $evt.type -eq 'user.message' -and
                    ([string]$evt.data.content).Trim() -eq $request.Command.Trim()) {
                $request.EventPath = $path
                $request.EventOffset = $chunk.Offset
            } elseif ($request.EventPath -eq $path -and $evt.type -eq 'assistant.turn_start') {
                $request.SawTurnStart = $true
            } elseif ($request.EventPath -eq $path -and $evt.type -eq 'assistant.message') {
                $text = $evt.data.content
                if (-not $text) { $text = $evt.data.text }
                if ($text) { $request.Answer = [string]$text }
            } elseif ($request.EventPath -eq $path -and $evt.type -eq 'assistant.turn_end') {
                $request.SawTurnEnd = $true
            }
        }
        if ($request.EventPath -eq $path) {
            $request.EventOffset = $chunk.Offset
        }
    }
}

function Complete-VoiceUiRequest {
    Read-VoiceUiRequest
    $request = $script:VoiceUiRequest
    if (-not $request) { return }
    if (([datetime]::UtcNow - $request.StartedUtc).TotalSeconds -gt 600) {
        Write-VoiceUiResponse $request.Id '' 'Timed out waiting for Scout.'
        Clear-VoiceUiRequest
        return
    }
    if (-not $request.Submitted) {
        Submit-VoiceUiRequest
        return
    }
    Read-VoiceUiEvents
    # Session events continue while Scout is minimized or behind another app.
    # Use the authoritative turn boundary instead of an on-screen Send button.
    if ($request.Answer -and $request.SawTurnStart -and $request.SawTurnEnd) {
        Write-VoiceUiResponse $request.Id $request.Answer ''
        Clear-VoiceUiRequest
    }
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

# Expand or collapse an element that carries the ExpandCollapse pattern, e.g. the
# chat-search toggle in newer Scout builds where "Search chats" is a button that
# reveals the field rather than the field itself.
function Set-UiaExpand($el, [bool]$expand) {
    if (-not $el) { return $false }
    try {
        $p = $el.GetCurrentPattern([System.Windows.Automation.ExpandCollapsePattern]::Pattern)
        if ($expand) { $p.Expand() } else { $p.Collapse() }
        return $true
    } catch { return $false }
}

# Bring up the chat-search field and return it, coping with both shapes Scout has
# shipped: an older one where "Search chats" is the Edit directly (optionally
# behind a "Show chat search" button), and a newer one where "Search chats" is a
# button carrying ExpandCollapse that reveals the Edit. Returns the Edit element
# and whether this call was the one that opened it, so the caller can put it back.
function Show-ChatSearchBox($root, [IntPtr]$hwnd) {
    # Already open?
    $box = Find-UiaByName $root 'Search chats' $UiaType::Edit
    if ($box) { return [pscustomobject]@{ Box = $box; Opened = $false; Root = $root } }

    $opened = $false
    # Newer UI: a "Search chats" *button* that expands to reveal the field.
    $btn = Find-UiaByName $root 'Search chats' $UiaType::Button
    if ($btn) {
        if (Set-UiaExpand $btn $true) { $opened = $true }
        else { [void](Invoke-UiaElement $btn); $opened = $true }
    } else {
        # Older UI: a "Show chat search" button next to the field.
        if (Invoke-UiaElement (Find-UiaByName $root 'Show chat search' $UiaType::Button)) { $opened = $true }
    }
    if (-not $opened) { return $null }

    # The field is created asynchronously; poll briefly for it.
    for ($i = 0; $i -lt 8; $i++) {
        Start-Sleep -Milliseconds 120
        $root = $UiaEl::FromHandle($hwnd)
        $box = Find-UiaByName $root 'Search chats' $UiaType::Edit
        if ($box) { return [pscustomobject]@{ Box = $box; Opened = $true; Root = $root } }
    }
    return $null
}

# Put the chat search away again, whichever shape opened it.
function Hide-ChatSearchBox([IntPtr]$hwnd) {
    $root = $UiaEl::FromHandle($hwnd)
    # Newer UI: collapse the toggle button.
    $btn = Find-UiaByName $root 'Search chats' $UiaType::Button
    if ($btn) { if (Set-UiaExpand $btn $false) { return } }
    # Older UI: a dedicated hide button.
    [void](Invoke-UiaElement (Find-UiaByName $root 'Hide chat search' $UiaType::Button))
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
        # A chat row is a wide button near the left edge. Newer Scout builds
        # widened the sidebar (rows measured at 403px where they were ~300), so
        # the width band is generous - the real discriminator is that it is much
        # wider than the little 43px "More actions" overflow button that shares
        # the same name suffix, and that it carries a title, not just the suffix.
        if ($r.X -gt ($win.X + 520)) { continue }
        if ($r.Width -lt 200 -or $r.Width -gt 900) { continue }
        if ($r.Height -lt 36 -or $r.Height -gt 140) { continue }
        if (-not $c.Name -or $c.Name -notmatch 'More actions$') { continue }
        # The bare overflow button is named exactly "More actions" with no title.
        if ($c.Name -eq 'More actions') { continue }
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

# How much of a chat title is accounted for by words the session has used. Word
# overlap, not similarity of meaning: the sidebar title is Scout's own summary of
# the conversation, so it usually shares concrete words with what was asked -
# "KT Summit deck" against a session about "KT-MS Tech Summit". Scored as the
# fraction of the title's words that appear in the topic, so a short exact-ish
# title scores high and a long unrelated one scores zero.
function Get-TitleTopicOverlap([string]$topic, [string]$title) {
    if (-not $topic -or -not $title) { return 0.0 }
    $split = { param($s) ($s.ToLower() -replace '[^\p{L}\p{Nd}]', ' ') -split '\s+' | Where-Object { $_.Length -ge 2 } }
    $tt = @(& $split $topic)
    $ct = @(& $split $title)
    if ($ct.Count -eq 0) { return 0.0 }
    $common = @($ct | Where-Object { $tt -contains $_ }).Count
    return [double]$common / $ct.Count
}

# Picks the chat row for a specific session, using two signals in order:
# word overlap between the session's topic and each title first, and how recently
# each row moved as the tiebreak. Overlap is what lets two equally-fresh sessions
# be told apart - the reason timestamp alone opened whichever was freshest - while
# the timestamp still decides when no title shares words with the topic (a title
# summarised into something the topic never literally said). Returns nothing when
# no row is even plausibly this session, so the caller can leave the sidebar be.
function Select-ChatRowForSession($rows, [string]$topic, [double]$age) {
    $rows = @($rows)
    if ($rows.Count -eq 0) { return $null }
    if ($age -lt 0) { $age = 0 }
    # A generous window: timestamps only ever lag, so allow a lot above and a
    # little below. Its job is to rule out the clearly-unrelated, not to choose.
    $lo = [Math]::Max(0.0, $age * 0.5 - 2.0)
    $hi = $age + [Math]::Max(30.0, $age)

    $cands = New-Object System.Collections.ArrayList
    for ($i = 0; $i -lt $rows.Count; $i++) {
        $m = ConvertTo-AgeMinutes $rows[$i].When
        if ($null -eq $m) { continue }
        if ($m -lt $lo -or $m -gt $hi) { continue }
        $ov = Get-TitleTopicOverlap $topic $rows[$i].Title
        [void]$cands.Add([pscustomobject]@{ Row = $rows[$i]; Age = $m; Overlap = [Math]::Round($ov, 3); Rank = $i })
    }
    if ($cands.Count -eq 0) { return $null }
    # Best overlap first; among equal overlap the freshest, and the search's own
    # order breaks any remaining tie.
    return (@($cands | Sort-Object @{ E = 'Overlap'; D = $true }, @{ E = 'Age'; D = $false }, @{ E = 'Rank'; D = $false }))[0].Row
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
    $rows = @($rows)
    if ($rows.Count -eq 0) { return $null }
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

# True when no Scout window is in front. Anything done to a window nobody is
# looking at leaves no trace on screen, and that is the only condition under
# which the sidebar gets touched: the alternative is making the user's own
# window flicker to read a label off it.
function Test-AgentUnobserved {
    $fg = [ScoutNative]::GetForegroundWindow()
    if ($fg -eq [IntPtr]::Zero) { return $true }
    $owner = [uint32]0
    try { [void][ScoutNative]::GetWindowThreadProcessId($fg, [ref]$owner) } catch { return $false }
    $pids = Get-AgentPids
    return (-not $pids.Contains([uint32]$owner))
}

# Reads Scout's chat list, with the timestamps that make a row identifiable.
#
# Typing is unavoidable, which took measuring to establish. A sidebar sitting
# open lists 22 chats and not one carries a timestamp; put a query in the search
# box and every row that comes back has one. The timestamp is the only thing
# tying a row to a session - there is no selection marker to read, and the title
# appears nowhere else in the window - so without typing there is nothing to
# match on and nothing can be learned.
#
# Hence the rule the caller enforces: this only ever runs while no Scout window
# is in front, so the search that gets typed and cleared is never on screen.
# Whatever was open is put back, and a query the user left in the box is put
# back with it.
function Invoke-ChatSearch([IntPtr]$hwnd, [string[]]$queries) {
    # Returns one row list per query, in order. An empty list means that query
    # produced nothing usable.
    $results = @()
    Wake-AgentA11y $hwnd
    Start-Sleep -Milliseconds 250
    $root = $null
    try { $root = $UiaEl::FromHandle($hwnd) } catch { return @() }
    if (-not $root) { return @() }

    $openedSidebar = $false
    $openedSearch  = $false
    $original      = $null
    try {
        if (-not (Find-UiaByName $root 'Hide sidebar' $UiaType::Button)) {
            if (-not (Invoke-UiaElement (Find-UiaByName $root 'Show sidebar' $UiaType::Button))) { return @() }
            $openedSidebar = $true
            Start-Sleep -Milliseconds 350
            $root = $UiaEl::FromHandle($hwnd)
        }

        $opened = Show-ChatSearchBox $root $hwnd
        if (-not $opened) { return @() }
        $box = $opened.Box
        $root = $opened.Root
        if ($opened.Opened) { $openedSearch = $true }

        # A query the user typed themselves is theirs; note it so it can go back.
        try { $original = $box.GetCurrentPattern([System.Windows.Automation.ValuePattern]::Pattern).Current.Value } catch { }

        foreach ($q in $queries) {
            if (-not $q) { $results += ,@(); continue }
            # No SetFocus. The field takes a value without the caret, and taking
            # the caret would pull it out of whatever the user was typing in.
            try { $box.GetCurrentPattern([System.Windows.Automation.ValuePattern]::Pattern).SetValue($q) }
            catch { $results += ,@(); continue }

            # Wait for the list to settle, not for the first row to appear.
            # Reading as soon as anything is timestamped catches the list
            # mid-render - measured returning a single row where a settled read
            # returns nine - and a lone row wins its session by default. That
            # is how a session came to be named after a chat it has nothing to
            # do with.
            $rows = @()
            $stable = 0
            $lastCount = -1
            for ($i = 0; $i -lt 20; $i++) {
                Start-Sleep -Milliseconds 150
                $rows = @(Get-ChatRows ($UiaEl::FromHandle($hwnd)))
                $n = @($rows | Where-Object { $_.When }).Count
                if ($n -gt 0 -and $n -eq $lastCount) {
                    $stable++
                    if ($stable -ge 2) { break }
                } else {
                    $stable = 0
                }
                $lastCount = $n
            }
            $results += ,$rows
        }
        return $results
    } catch { return $results } finally {
        try {
            $root2 = $UiaEl::FromHandle($hwnd)
            $b2 = Find-UiaByName $root2 'Search chats' $UiaType::Edit
            if ($b2) {
                $back = if ($original) { $original } else { '' }
                try { $b2.GetCurrentPattern([System.Windows.Automation.ValuePattern]::Pattern).SetValue($back) } catch { }
            }
            Start-Sleep -Milliseconds 250
            if ($openedSearch) { Hide-ChatSearchBox $hwnd }
            if ($openedSidebar) {
                [void](Invoke-UiaElement (Find-UiaByName ($UiaEl::FromHandle($hwnd)) 'Hide sidebar' $UiaType::Button))
            }
        } catch { }
    }
}

# The window to do that in: one that already has its sidebar open, so there is
# less to disturb, and otherwise whichever comes first.
function Select-SearchWindow {
    $wins = @(Get-AgentWindows)
    if ($wins.Count -eq 0) { return [IntPtr]::Zero }
    foreach ($h in $wins) {
        $r = $null
        try { $r = $UiaEl::FromHandle($h) } catch { continue }
        if (-not $r) { continue }
        if (Find-UiaByName $r 'Hide sidebar' $UiaType::Button) { return $h }
    }
    return $wins[0]
}

# Pairs sessions to chat rows, one row each.
#
# Every session picking independently makes them all reach for the freshest
# row, and then the one-title-one-session rule refuses the lot - so several
# sessions running at once produced no names at all. They are pairs to be
# assigned, not a race to be won.
#
# Both sides are ordered by how recently they moved and matched in that order:
# the session that moved most recently takes the freshest row it could
# plausibly be, the next takes the freshest of what is left, and so on. Where a
# session has no plausible row left it simply goes unnamed.
#
#   $sessions : objects with .Dir and .Age (minutes since its last message)
#   $rows     : objects with .Title and .When
# Returns objects with .Dir and .Title.
function Select-SessionRowPairs($sessions, $rows) {
    $cands = New-Object System.Collections.ArrayList
    for ($i = 0; $i -lt @($rows).Count; $i++) {
        $m = ConvertTo-AgeMinutes $rows[$i].When
        if ($null -eq $m) { continue }
        if (-not $rows[$i].Title) { continue }
        [void]$cands.Add([pscustomobject]@{ Title = $rows[$i].Title; Age = $m; Rank = $i })
    }
    if ($cands.Count -eq 0) { return @() }
    # Freshest first, ties broken by the order the search put them in.
    $pool = New-Object System.Collections.ArrayList
    foreach ($c in @($cands | Sort-Object Age, Rank)) { [void]$pool.Add($c) }

    $out = New-Object System.Collections.ArrayList
    $ordered = @($sessions | Where-Object { $null -ne $_.Age -and [double]$_.Age -ge 0 } | Sort-Object Age)
    for ($k = 0; $k -lt $ordered.Count; $k++) {
        $s = $ordered[$k]
        $age = [double]$s.Age
        # Two sessions less than a minute apart cannot be ordered against rows
        # that are only stamped to the minute, and this whole pairing rests on
        # that order being real. Rather than let a coin toss hand out a name,
        # neither is named. The lag is what makes the order usable at all: it
        # runs at much the same size across chats, so it shifts every row by a
        # similar amount and leaves their sequence intact.
        $tooClose = $false
        if ($k -gt 0 -and [Math]::Abs($age - [double]$ordered[$k-1].Age) -lt 1.0) { $tooClose = $true }
        if ($k -lt $ordered.Count - 1 -and [Math]::Abs([double]$ordered[$k+1].Age - $age) -lt 1.0) { $tooClose = $true }
        if ($tooClose) { continue }

        # The same lopsided window as a lone pick: a little slack below for
        # rounding, a lot above because Scout's timestamps lag and never lead.
        $lo = [Math]::Max(0.0, $age * 0.5 - 2.0)
        $hi = $age + [Math]::Max(20.0, $age * 0.5)
        $take = $null
        foreach ($c in $pool) {
            if ($c.Age -lt $lo -or $c.Age -gt $hi) { continue }
            $take = $c; break
        }
        if (-not $take) { continue }
        [void]$pool.Remove($take)
        [void]$out.Add([pscustomobject]@{ Dir = $s.Dir; Title = $take.Title })
    }
    return @($out)
}

# Which of a set of proposed namings are safe to apply, given what other
# sessions already answer to.
#
# A title identifies exactly one conversation, so it can belong to exactly one
# session. Two sessions wanting the same row is not a tie to be broken - the
# whole value of a real chat title is that it picks out one conversation, and
# one hung on the wrong session is worse than none at all.
#
# Contested titles are also taken back off whoever already holds them. That
# looks harsh, and it is the point: nothing here says which claimant was right,
# and leaving the incumbent named on "first come, first served" would keep a
# name that has just been shown to be unreliable. Observed for real - two
# automations and a chat session in one folder, all three answering to
# "Scout Companion" because each was scanned while it was the only one without
# a name.
#
# Takes and returns plain data so the rule can be tested without a sidebar.
#   $proposals : objects with .Dir and .Title
#   $taken     : title -> dir, for titles already held
# Returns .Assign (dir -> title) and .Revoke (dirs that must lose theirs).
function Select-TitleAssignments($proposals, $taken) {
    if (-not $taken) { $taken = @{} }

    $byTitle = @{}
    foreach ($p in @($proposals)) {
        if (-not $p -or -not $p.Dir -or -not $p.Title) { continue }
        if ($byTitle.ContainsKey($p.Title)) { $byTitle[$p.Title] = $null; continue }
        $byTitle[$p.Title] = $p.Dir
    }

    $assign = @{}
    $revoke = New-Object System.Collections.ArrayList
    foreach ($t in @($byTitle.Keys)) {
        $dir    = $byTitle[$t]
        $holder = $taken[$t]
        # Contested inside this pass. Whoever holds it loses it too.
        if (-not $dir) {
            if ($holder) { [void]$revoke.Add($holder) }
            continue
        }
        # Already correctly held by this very session.
        if ($holder -eq $dir) { continue }
        # Held by a different session: neither can keep it.
        if ($holder) { [void]$revoke.Add($holder); continue }
        $assign[$dir] = $t
    }
    return [pscustomobject]@{ Assign = $assign; Revoke = @($revoke) }
}

# Puts Scout's own name to the sessions being followed, read off its own chat
# sidebar. Runs only when some session is still unnamed.
#
# Refuses outright while a Scout window is in front. Learning a title means
# typing into the chat search and clearing it again, and doing that to a window
# someone is looking at would be exactly the overreach an earlier version of
# this file had to walk back.
#
# Returns whether anything was learned, and sets $script:ChatScanLooked to say
# whether it actually got as far as searching - the caller needs to tell "I
# looked and there was nothing" from "I never got to look", because only the
# first is a reason to try less often.
function Update-SessionTitles {
    $script:ChatScanLooked = $false
    $want = @()
    foreach ($dir in $Sessions.Keys) {
        if (-not $Sessions[$dir].ChatTitle) { $want += $dir }
    }
    if ($want.Count -eq 0) { return $false }

    $unobserved = $false
    try { $unobserved = Test-AgentUnobserved } catch { }
    if (-not $unobserved) { return $false }

    $hwnd = [IntPtr]::Zero
    try { $hwnd = Select-SearchWindow } catch { }
    if ($hwnd -eq [IntPtr]::Zero) { return $false }
    # One query per unnamed session, all in a single visit: opening and closing
    # the sidebar once is less disturbance than doing it per session.
    $queries = @()
    $dirs    = @()
    foreach ($dir in $want) {
        $rec = $Sessions[$dir]
        if (-not $rec) { continue }
        $q = $null
        try { $q = Get-SessionQuery $rec } catch { }
        if (-not $q) { continue }
        $queries += $q
        $dirs    += $dir
    }
    if ($queries.Count -eq 0) { return $false }

    $lists = @()
    try { $lists = @(Invoke-ChatSearch $hwnd $queries) } catch { return $false }
    $script:ChatScanLooked = $true
    if ($lists.Count -eq 0) { return $false }

    # The rows are much the same list whichever query fetched them - measured:
    # five very different queries returned the same nine chats in nearly the
    # same order, so the search barely narrows anything and the timestamp is
    # doing all the work. Still, a query can surface a chat the others miss, so
    # the lists are merged rather than one being picked: one entry per title,
    # carrying the freshest time any query showed for it.
    $merged = [ordered]@{}
    foreach ($l in $lists) {
        foreach ($r in @($l)) {
            if (-not $r -or -not $r.Title -or -not $r.When) { continue }
            $m = ConvertTo-AgeMinutes $r.When
            if ($null -eq $m) { continue }
            $prev = $merged[$r.Title]
            if ($prev -and (ConvertTo-AgeMinutes $prev.When) -le $m) { continue }
            $merged[$r.Title] = $r
        }
    }
    $rows = @($merged.Values)
    if ($rows.Count -eq 0) { return $false }

    $wanting = @()
    for ($i = 0; $i -lt $dirs.Count; $i++) {
        $rec = $Sessions[$dirs[$i]]
        if (-not $rec -or $rec.ChatTitle) { continue }
        # Measured from the last message, because that is the kind of thing the
        # sidebar's own "when" is measuring.
        $stamp = Get-LastMessageUtc $rec.Events
        if (-not $stamp) { $stamp = $rec.LastEventUtc }
        if (-not $stamp) { continue }
        $wanting += [pscustomobject]@{
            Dir = $dirs[$i]
            Age = [double]([datetime]::UtcNow - $stamp).TotalMinutes
        }
    }
    if ($wanting.Count -eq 0) { return $false }

    $proposals = @(Select-SessionRowPairs $wanting $rows)

    $learned = $false
    # Everything already answering to a name, so a proposal cannot quietly take
    # a title off another conversation. Both the sessions being followed and the
    # store, since a session that has gone quiet still owns its name.
    $taken = @{}
    foreach ($d in $script:TitleStore.Keys) { $taken[$script:TitleStore[$d]] = $d }
    foreach ($d in $Sessions.Keys) {
        $t = $Sessions[$d].ChatTitle
        if ($t) { $taken[$t] = $d }
    }

    $decision = Select-TitleAssignments $proposals $taken
    foreach ($dir in @($decision.Assign.Keys)) {
        $Sessions[$dir].ChatTitle = $decision.Assign[$dir]
        Set-LearnedTitle $dir $decision.Assign[$dir]
        $learned = $true
    }
    # A name two conversations both answer to identifies neither, so it goes
    # back to being nameless rather than being left on whoever got there first.
    foreach ($dir in @($decision.Revoke)) {
        if ($Sessions.Contains($dir)) { $Sessions[$dir].ChatTitle = $null }
        Remove-LearnedTitle $dir
        $learned = $true
    }
    if ($learned) { try { Resolve-SessionLabels } catch { } }
    return $learned
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

function Open-AgentSession($rec, [switch]$Exact) {
    # Returns $true only when the sidebar was actually driven to this session.
    if (-not $rec) { return $false }
    if (-not $Config.openMatchingSession) { return $false }
    # Search Scout's own name for the chat when it is already known - the one
    # signal that tells two equally-fresh sessions apart. Otherwise search the
    # session's topic, which both finds the chat and teaches us its name for
    # next time (the same learn-on-open the Open button has always done).
    $query = if ($rec.ChatTitle) { Truncate $rec.ChatTitle 40 } else { Get-SessionQuery $rec }
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

        $opened = Show-ChatSearchBox $root $win.Hwnd
        if (-not $opened) { return $false }
        $box = $opened.Box
        $root = $opened.Root
        if ($opened.Opened) { $openedSearch = $true }

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
        $rows = @($rows)

        # Two ways to choose the row. When the chat's name is known the query was
        # that exact name, so the row carrying it is this session and no other -
        # which is what tells two equally-fresh sessions apart, and stops a
        # hand-picked row opening whichever chat happened to be freshest. When the
        # name is not known yet the query was the topic, so choose by how much each
        # title's words overlap that topic, with recency only as a tiebreak, and
        # learn the name below.
        $pick = $null
        if ($rec.ChatTitle) {
            $pick = @($rows | Where-Object { $_.Title -eq $rec.ChatTitle })[0]
        }
        if (-not $pick -and -not $Exact) {
            $stamp = Get-LastMessageUtc $rec.Events
            if (-not $stamp) { $stamp = $rec.LastEventUtc }
            $topicText = $rec.Topic
            if (-not $topicText) { $topicText = $query }
            $pick = Select-ChatRowForSession $rows $topicText ([double]([datetime]::UtcNow - $stamp).TotalMinutes)
        }
        if (-not $pick) { return $false }

        # Now that the chat has been identified, remember what Scout calls it so
        # the toast can name it from here on without looking again.
        if ($pick.Title) {
            $rec.ChatTitle = $pick.Title
            Set-LearnedTitle $rec.Dir $pick.Title
            try { Resolve-SessionLabels } catch { }
        }
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
            if ($openedSearch) { Hide-ChatSearchBox $win.Hwnd }
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

# A conversation picked by hand from the multi-session list. The window comes
# forward first and never fails. The chat switch prefers the chat's known name
# and matches it exactly; the first time a session is opened its name is not
# known yet, so it is found by the session's own topic and its name learned from
# the row - so every click after the first is an exact, unambiguous match.
function Focus-AgentSessionByDir([string]$dir) {
    Focus-Agent
    if (-not $dir -or -not $Sessions.Contains($dir)) { return }
    try { [void](Open-AgentSession $Sessions[$dir]) } catch { }
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
        <Canvas x:Name="MascotHost" Width="58" Height="60" DockPanel.Dock="Left" Margin="8,0,14,0"
                RenderTransformOrigin="0.5,0.6" VerticalAlignment="Center">
          <!-- Shrinks the mascot's reserved layout box (LayoutTransform, unlike the
               RenderTransform below, actually shortens the space it takes) so the
               header row is no taller than its text needs, killing the empty band
               above and below the title. -->
          <Canvas.LayoutTransform><ScaleTransform ScaleX="0.85" ScaleY="0.85"/></Canvas.LayoutTransform>
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

        <Button x:Name="CloseBtn" Content="&#x2715;" DockPanel.Dock="Right" Width="24" Height="24"
                Background="Transparent" Foreground="#FF8A93A6" BorderThickness="0" FontSize="12"
                VerticalAlignment="Top" Cursor="Hand" ToolTip="Close"/>
        <Button x:Name="SettingsBtn" DockPanel.Dock="Right" Width="28" Height="24"
                Background="Transparent" BorderThickness="0"
                VerticalAlignment="Top" Cursor="Hand" ToolTip="Settings">
          <!-- A drawn gear rather than the U+2699 glyph, which renders as a
               flower in some font fallbacks. Twelve teeth around a ring with a
               hollow centre; Fill follows the same grey the other header icons
               use, brightening on hover. -->
          <Path Width="15" Height="15" Stretch="Uniform" Fill="#FF9AA6BE"
                Data="M8,5.2 A2.8,2.8 0 1 0 8,10.8 A2.8,2.8 0 1 0 8,5.2 Z M7,0 L9,0 L9.4,2.1 A6,6 0 0 1 11,2.75 L12.8,1.55 L14.2,2.95 L13,4.75 A6,6 0 0 1 13.65,6.35 L15.75,6.75 L15.75,8.75 L13.65,9.15 A6,6 0 0 1 13,10.75 L14.2,12.55 L12.8,13.95 L11,12.75 A6,6 0 0 1 9.4,13.4 L9,15.5 L7,15.5 L6.6,13.4 A6,6 0 0 1 5,12.75 L3.2,13.95 L1.8,12.55 L3,10.75 A6,6 0 0 1 2.35,9.15 L0.25,8.75 L0.25,6.75 L2.35,6.35 A6,6 0 0 1 3,4.75 L1.8,2.95 L3.2,1.55 L5,2.75 A6,6 0 0 1 6.6,2.1 Z">
            <Path.Style>
              <Style TargetType="Path">
                <Style.Triggers>
                  <DataTrigger Binding="{Binding IsMouseOver, RelativeSource={RelativeSource AncestorType=Button}}" Value="True">
                    <Setter Property="Fill" Value="#FFE6EAF2"/>
                  </DataTrigger>
                </Style.Triggers>
              </Style>
            </Path.Style>
          </Path>
        </Button>
        <Button x:Name="VoiceToggleBtn" Content="MIC" DockPanel.Dock="Right"
                Width="38" Height="24" Margin="0,0,2,0"
                Background="Transparent" Foreground="#FF9AA6BE" BorderThickness="0"
                FontSize="9.5" FontWeight="SemiBold" VerticalAlignment="Top"
                Cursor="Hand" ToolTip="Enable voice control"/>

        <StackPanel x:Name="HeaderArea" VerticalAlignment="Center" Background="Transparent" Cursor="Hand" ToolTip="Open">
          <DockPanel LastChildFill="True">
            <Ellipse x:Name="Dot" Width="9" Height="9" Fill="#FF4ADE80" VerticalAlignment="Center" Margin="0,0,7,0" DockPanel.Dock="Left"/>
            <!-- How long the current turn has been going. Measured over three
                 days of real use: the median turn is 11 seconds, but the 90th
                 percentile is 36 and the worst was ten minutes. Below about a
                 minute this is noise, so it only appears once a turn is long
                 enough that you would start wondering.
                 Docked Right and declared before HeaderText: DockPanel fills
                 with its last child, so a header docked last would take the
                 whole width and leave nothing for this. -->
            <TextBlock x:Name="ElapsedText" Text="" Foreground="#FF8A93A6" FontSize="11.5"
                       VerticalAlignment="Center" Margin="8,1,0,0" DockPanel.Dock="Right"
                       Visibility="Collapsed"/>
            <TextBlock x:Name="HeaderText" Text="Scout is working" Foreground="#FFE6EAF2" FontSize="13.5" FontWeight="SemiBold" VerticalAlignment="Center" TextTrimming="CharacterEllipsis"/>
          </DockPanel>
          <!-- Which conversation the steps and narration below belong to. Its
               own line, aligned under the header text rather than beside it: a
               chat title is a sentence more often than a word. -->
          <TextBlock x:Name="HeaderFrom" Margin="16,2,0,0" Text="" Foreground="#FF9AA6BE" FontSize="10.5"
                     Opacity="0.85" TextTrimming="CharacterEllipsis" Visibility="Collapsed"/>
          <TextBlock x:Name="SayingText" Margin="0,4,0,0" Text="" Foreground="#FF9AA6BE" FontSize="11"
                     FontStyle="Italic" TextWrapping="Wrap" MaxHeight="44" TextTrimming="CharacterEllipsis"/>
        </StackPanel>
      </DockPanel>

      <!-- The session row(s): one per active conversation, or just one when a
           single session is running. Always on top, so single and multi share the
           same top-line language - a green accent bar, the conversation's name,
           and a chevron that opens it. -->
      <Border x:Name="SessionsPanel" Margin="0,10,0,0" Padding="10,8" CornerRadius="9" Background="#FF232838" Visibility="Collapsed">
        <StackPanel x:Name="SessionsList"/>
      </Border>

      <Border x:Name="VoicePanel" Margin="0,10,0,0" Padding="10,9" CornerRadius="9"
              Background="#FF2A2030" BorderBrush="#FFFD8EA1" BorderThickness="1"
              Visibility="Collapsed">
        <StackPanel>
          <DockPanel>
            <Ellipse Width="9" Height="9" Fill="#FFFD8EA1" Margin="0,0,8,0"
                     VerticalAlignment="Center" DockPanel.Dock="Left"/>
            <TextBlock x:Name="VoiceStatus" Text="Listening" Foreground="#FFFFD7DF"
                       FontWeight="SemiBold" FontSize="12.5"/>
          </DockPanel>
          <TextBlock x:Name="VoiceCommand" Margin="17,6,0,0" Foreground="#FFE6EAF2"
                     FontSize="11.5" TextWrapping="Wrap" MaxHeight="48"
                     TextTrimming="CharacterEllipsis"/>
          <TextBlock x:Name="VoiceAnswer" Margin="17,5,0,0" Foreground="#FFB9C2D6"
                     FontSize="11" TextWrapping="Wrap" MaxHeight="64"
                     TextTrimming="CharacterEllipsis"/>
        </StackPanel>
      </Border>

      <!-- The detailed step list, shown under the single-session row. It carries
           the fuller ✓/▸ trace that a one-line row cannot; several sessions show
           a row each instead of this. -->
      <Border x:Name="StepsPanel" Margin="0,6,0,0" Padding="10,8" CornerRadius="9" Background="#FF1E2431" Visibility="Collapsed">
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
          <!-- What is being asked, in prose. Scout supplies this itself; the
               companion used to drop it and show only the literal request. -->
          <TextBlock x:Name="PermSummary" Margin="0,6,0,0" Foreground="#FFD6CFC2" FontSize="12.5"
                     FontWeight="SemiBold" TextWrapping="Wrap"/>
          <!-- The literal request, kept because checking it is the whole point of
               a prompt. Ellipsising it was a real hazard rather than a cosmetic
               one: what gets cut is the tail, and the tail of a shell command is
               where the destructive part of it tends to live, so "Allow" was
               being offered on text the reader could not finish. Scrolls instead
               of trimming - the toast keeps its size, and the whole request is
               reachable. -->
          <ScrollViewer Margin="0,4,0,0" MaxHeight="132" VerticalScrollBarVisibility="Auto"
                        HorizontalScrollBarVisibility="Disabled">
            <TextBlock x:Name="PermText" Foreground="#FFD6CFC2" FontSize="11"
                       TextWrapping="Wrap"/>
          </ScrollViewer>
          <!-- MinWidth, not Width. Fixed widths were fine in English and clipped
               the moment the captions were translated: "??克剋棘戟龜??" and
               "Odm챠tnout" both overrun a 74 px Deny button. MinWidth keeps the
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
$HeaderFrom   = $Window.FindName('HeaderFrom')
$ElapsedText  = $Window.FindName('ElapsedText')
$Dot          = $Window.FindName('Dot')
$StepsPanel   = $Window.FindName('StepsPanel')
$StepsText    = $Window.FindName('StepsText')
$SessionsPanel = $Window.FindName('SessionsPanel')
$SessionsList  = $Window.FindName('SessionsList')
$VoicePanel    = $Window.FindName('VoicePanel')
$VoiceStatus   = $Window.FindName('VoiceStatus')
$VoiceCommand  = $Window.FindName('VoiceCommand')
$VoiceAnswer   = $Window.FindName('VoiceAnswer')
$PermPanel    = $Window.FindName('PermPanel')
$PermText     = $Window.FindName('PermText')
$PermSummary  = $Window.FindName('PermSummary')
# Held rather than rebuilt: the prompt card swaps between them on every render,
# and a FontFamily parsed from a string each time is a needless allocation on
# the UI thread. The mono list mirrors the one the step panel uses.
$script:MonoFont = New-Object System.Windows.Media.FontFamily 'Consolas, Cascadia Mono, monospace'
$script:UiFont   = $PermText.FontFamily
$PermFrom     = $Window.FindName('PermFrom')
$AllowBtn     = $Window.FindName('AllowBtn')
$DenyBtn      = $Window.FindName('DenyBtn')
$AnswerBtn    = $Window.FindName('AnswerBtn')
$HeaderArea   = $Window.FindName('HeaderArea')
$CloseBtn     = $Window.FindName('CloseBtn')
$SettingsBtn  = $Window.FindName('SettingsBtn')
$VoiceToggleBtn = $Window.FindName('VoiceToggleBtn')
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
    VoiceBg       = B '#FF241C2A'; VoiceBorder   = B '#FFFD8EA1'; VoiceHeader   = B '#FFFFE8ED'
    PermBgNormal  = B '#FF2A2030'; PermBdNormal  = B '#FFB4843C'; PermTxtNormal = B '#FFD6CFC2'
    PermBgAlert   = B '#FFFFFFFF'; PermBdAlert   = B '#FFFF7A00'; PermTxtAlert  = B '#FF3A2E10'
    PermBgAsk     = B '#FFFFFFFF'; PermBdAsk     = B '#FF0E7FB8'; PermTxtAsk    = B '#FF10303F'
}
$script:ThemeState = $null

# state: 'alert' (approval), 'ask' (question), 'working' (busy), 'idle' (default/dim)
function Set-Theme([string]$state) {
    if ($state -eq 'voice') {
        $RootBorder.Background  = $Theme.VoiceBg
        $RootBorder.BorderBrush = $Theme.VoiceBorder
        $RootBorder.BorderThickness = 2
        $HeaderText.Foreground  = $Theme.VoiceHeader
        $RootGlow.Color         = [System.Windows.Media.Color]::FromRgb(253, 142, 161)
        $RootGlow.BlurRadius    = 25
        $RootGlow.Opacity       = 0.72
    } elseif ($state -eq 'alert') {
        $RootBorder.Background  = $Theme.AlertBg
        $RootBorder.BorderBrush = $Theme.AlertBorder
        $RootBorder.BorderThickness = 2
        $HeaderText.Foreground  = $Theme.AlertHeader
        $PermPanel.Background   = $Theme.PermBgAlert
        $PermPanel.BorderBrush  = $Theme.PermBdAlert
        $PermText.Foreground    = $Theme.PermTxtAlert
        $PermSummary.Foreground = $Theme.PermTxtAlert
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
        $PermSummary.Foreground = $Theme.PermTxtAsk
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
        $PermSummary.Foreground = $Theme.PermTxtNormal
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
        $PermSummary.Foreground = $Theme.PermTxtNormal
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

# Where the toast should sit, given a remembered position and the screens that
# actually exist right now.
#
# Returns $null when there is nothing usable to restore, and the caller falls
# back to the bottom-right corner.
#
# A remembered position cannot be trusted on sight: the monitor it was on may be
# gone, the laptop may have been undocked, or the resolution may have changed.
# Restoring onto a screen that no longer exists puts the toast somewhere nobody
# can reach it, and it has no taskbar button to get it back with.
#
# Pure, so the rules can be tested without a desktop. Rectangles are
# [pscustomobject] with Left/Top/Right/Bottom.
function Get-RestoredPosition($saved, $screens, [double]$width, [double]$height) {
    if (-not $saved) { return $null }
    if ($null -eq $saved.Left -or $null -eq $saved.Top) { return $null }
    $l = [double]$saved.Left
    $t = [double]$saved.Top
    if ([double]::IsNaN($l) -or [double]::IsNaN($t)) { return $null }

    $all = @($screens)
    if ($all.Count -eq 0) { return $null }

    # Enough of the title area has to land on a screen to grab it with the
    # mouse. Checking only the top-left corner would accept a window one pixel
    # onto the desktop; checking the whole rectangle would reject one hanging
    # slightly off the bottom, which is harmless and something people do.
    $need = 80
    foreach ($s in $all) {
        $visibleW = [Math]::Min($l + $width, $s.Right) - [Math]::Max($l, $s.Left)
        $visibleH = [Math]::Min($t + $height, $s.Bottom) - [Math]::Max($t, $s.Top)
        if ($visibleW -ge $need -and $visibleH -ge 24) {
            return [pscustomobject]@{ Left = $l; Top = $t }
        }
    }
    return $null
}

function Place-BottomRight {
    $wa = [System.Windows.SystemParameters]::WorkArea
    $Window.Left = $wa.Right - $Window.ActualWidth - 16
    $Window.Top  = $wa.Bottom - $Window.ActualHeight - 16
}

# The screens as plain rectangles, for Get-RestoredPosition. WinForms reports
# these in device pixels while WPF positions in device-independent ones, so they
# have to be scaled or a remembered position is judged against the wrong
# coordinate space on any display that is not at 100%.
function Get-ScreenRects {
    $out = @()
    try {
        $src = [System.Windows.PresentationSource]::FromVisual($Window)
        $sx = 1.0; $sy = 1.0
        if ($src -and $src.CompositionTarget) {
            $m = $src.CompositionTarget.TransformFromDevice
            $sx = $m.M11; $sy = $m.M22
        }
        foreach ($s in [System.Windows.Forms.Screen]::AllScreens) {
            $b = $s.Bounds
            $out += [pscustomobject]@{
                Left   = $b.Left   * $sx
                Top    = $b.Top    * $sy
                Right  = $b.Right  * $sx
                Bottom = $b.Bottom * $sy
            }
        }
    } catch { }
    return $out
}

# Put the toast back where it was last left, or in the corner if that position
# is no longer reachable.
function Restore-Position {
    $pos = $null
    if ($Config.rememberPosition) {
        $pos = Get-RestoredPosition $script:SavedPosition (Get-ScreenRects) $Window.ActualWidth $Window.ActualHeight
    }
    if ($pos) {
        $Window.Left = $pos.Left
        $Window.Top  = $pos.Top
    } else {
        Place-BottomRight
    }
}

# Moving the toast is how the position is chosen, so remember where it was let
# go of. Coalesced behind a timer like the opacity slider: a drag raises
# LocationChanged continuously, and writing config.json on every pixel would be
# both wasteful and a good way to corrupt it.
$script:SavedPosition   = $null
# What was in config.json from last time. Loaded rather than assumed, and only
# when both halves are there - a file with one of the two is not a position.
if ($null -ne $Config.windowLeft -and $null -ne $Config.windowTop) {
    try {
        $script:SavedPosition = [pscustomobject]@{
            Left = [double]$Config.windowLeft
            Top  = [double]$Config.windowTop
        }
    } catch { }
}
$script:PositionTimer   = $null
$script:SuppressPosSave = $false

function Save-PendingPosition {
    if (-not $script:PositionTimer) { return }
    $script:PositionTimer.Stop()
    if (-not $Config.rememberPosition) { return }
    $l = $Window.Left; $t = $Window.Top
    if ([double]::IsNaN($l) -or [double]::IsNaN($t)) { return }
    $script:SavedPosition = [pscustomobject]@{ Left = $l; Top = $t }
    [void](Save-Setting @{ windowLeft = [Math]::Round($l); windowTop = [Math]::Round($t) })
}

$Window.Add_Loaded({
    # SizeChanged fires during layout before ActualWidth settles, so the first
    # placement happens here where the size is real.
    $script:SuppressPosSave = $true
    try { Restore-Position } finally { $script:SuppressPosSave = $false }
})

$Window.Add_SizeChanged({
    # Only re-place a toast that is still in its default corner. Re-placing
    # unconditionally is what made a moved toast snap back: the window is
    # SizeToContent, so every step line, session row and approval card changes
    # its height, and each one dragged it home again.
    if ($script:SavedPosition) { return }
    $script:SuppressPosSave = $true
    try { Place-BottomRight } finally { $script:SuppressPosSave = $false }
})

$Window.Add_LocationChanged({
    if ($script:SuppressPosSave) { return }
    if (-not $Config.rememberPosition) { return }
    if (-not $script:PositionTimer) {
        $script:PositionTimer = New-Object System.Windows.Threading.DispatcherTimer
        $script:PositionTimer.Interval = [TimeSpan]::FromMilliseconds(500)
        $script:PositionTimer.Add_Tick({ Save-PendingPosition })
    }
    $script:PositionTimer.Stop()
    $script:PositionTimer.Start()
})

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
$script:VoiceState = $null
$script:VoiceWasActive = $false
$script:VoiceProcess = $null
$script:VoiceEnabled = $false
$script:VoiceActivationUntil = [datetime]::MinValue
$script:VoiceStatePath = Join-Path $env:TEMP "scout-companion-voice-$PID.json"
$script:VoiceStopPath = Join-Path $env:TEMP "scout-companion-voice-$PID.stop"
$script:VoiceRequestPath = Join-Path $env:TEMP "scout-companion-voice-$PID.request.json"
$script:VoiceResponsePath = Join-Path $env:TEMP "scout-companion-voice-$PID.response.json"
$script:VoiceUiRequest = $null
$script:VoiceLastRequestId = $null
$script:VoiceRuntimeDir = if ($Config.voiceRuntimeDir) {
    [Environment]::ExpandEnvironmentVariables([string]$Config.voiceRuntimeDir)
} else {
    Join-Path $env:LOCALAPPDATA 'ScoutVoiceAssistant'
}

function Start-VoiceBridge {
    if ($script:VoiceProcess) {
        try {
            $script:VoiceProcess.Refresh()
            if (-not $script:VoiceProcess.HasExited) { return $true }
        } catch { }
    }
    $python = Join-Path $script:VoiceRuntimeDir '.venv\Scripts\pythonw.exe'
    $voiceProfile = Join-Path $script:VoiceRuntimeDir 'voice-profile.dat'
    $bridge = Join-Path $ScriptDir 'voice\companion_voice_host.py'
    if (-not (Test-Path $python) -or -not (Test-Path $voiceProfile) -or -not (Test-Path $bridge)) {
        Write-CompanionLog "voice unavailable: runtime, profile, or bridge is missing"
        return $false
    }
    Remove-Item $script:VoiceStatePath -Force -ErrorAction SilentlyContinue
    Remove-Item $script:VoiceStopPath -Force -ErrorAction SilentlyContinue
    Remove-Item $script:VoiceRequestPath -Force -ErrorAction SilentlyContinue
    Remove-Item $script:VoiceResponsePath -Force -ErrorAction SilentlyContinue
    $arguments = @(
        "`"$bridge`"",
        '--runtime-dir', "`"$script:VoiceRuntimeDir`"",
        '--state-file', "`"$script:VoiceStatePath`"",
        '--stop-file', "`"$script:VoiceStopPath`"",
        '--request-file', "`"$script:VoiceRequestPath`"",
        '--response-file', "`"$script:VoiceResponsePath`"",
        '--reply-enabled', $(if ([bool]$Config.voiceReplyEnabled) { 'true' } else { 'false' }),
        '--wake-sensitivity', ([int]$Config.voiceWakeSensitivity),
        '--noise-sensitivity', ([int]$Config.voiceNoiseSensitivity),
        '--parent-pid', "$PID"
    )
    try {
        $script:VoiceProcess = Start-Process $python -ArgumentList $arguments `
            -WorkingDirectory $script:VoiceRuntimeDir -WindowStyle Hidden -PassThru
        $script:VoiceEnabled = $true
        $script:VoiceActivationUntil = [datetime]::UtcNow.AddSeconds(5)
        Write-CompanionLog "voice bridge started pid=$($script:VoiceProcess.Id)"
        return $true
    } catch {
        Write-CompanionLog "voice bridge failed to start: $_"
        $script:VoiceEnabled = $false
        return $false
    }
}

function Stop-VoiceBridge {
    $p = $script:VoiceProcess
    if ($p) {
        try {
            if (-not $p.HasExited) {
                Set-Content -Path $script:VoiceStopPath -Value 'stop' -Encoding Ascii
                if (-not $p.WaitForExit(1000)) {
                    # If graceful shutdown stalls, stop only the bridge's known
                    # process tree, children first, so none survive Companion.
                    $all = @(Get-CimInstance Win32_Process -ErrorAction Stop)
                    $pending = @($p.Id)
                    $owned = New-Object System.Collections.Generic.List[int]
                    while ($pending.Count) {
                        $parent = $pending[0]
                        $pending = @($pending | Select-Object -Skip 1)
                        foreach ($child in @($all | Where-Object { $_.ParentProcessId -eq $parent })) {
                            [void]$owned.Add([int]$child.ProcessId)
                            $pending += [int]$child.ProcessId
                        }
                    }
                    $ownedArray = $owned.ToArray()
                    [array]::Reverse($ownedArray)
                    foreach ($id in $ownedArray) {
                        Stop-Process -Id $id -Force -ErrorAction SilentlyContinue
                    }
                    Stop-Process -Id $p.Id -Force -ErrorAction SilentlyContinue
                }
            }
        } catch { }
    }
    Remove-Item $script:VoiceStatePath -Force -ErrorAction SilentlyContinue
    Remove-Item ($script:VoiceStatePath + '.tmp') -Force -ErrorAction SilentlyContinue
    Remove-Item $script:VoiceStopPath -Force -ErrorAction SilentlyContinue
    Remove-Item $script:VoiceRequestPath -Force -ErrorAction SilentlyContinue
    Remove-Item ($script:VoiceRequestPath + '.tmp') -Force -ErrorAction SilentlyContinue
    Remove-Item $script:VoiceResponsePath -Force -ErrorAction SilentlyContinue
    Remove-Item ($script:VoiceResponsePath + '.tmp') -Force -ErrorAction SilentlyContinue
    $script:VoiceProcess = $null
    $script:VoiceState = $null
    $script:VoiceUiRequest = $null
    $script:VoiceEnabled = $false
    $script:VoiceActivationUntil = [datetime]::MinValue
}

function Read-VoiceState {
    if ($script:VoiceProcess) {
        try {
            $script:VoiceProcess.Refresh()
            if ($script:VoiceProcess.HasExited) {
                $script:VoiceProcess = $null
                $script:VoiceEnabled = $false
            }
        } catch { }
    }
    if (-not (Test-Path $script:VoiceStatePath)) {
        $script:VoiceState = $null
        return
    }
    try {
        $script:VoiceState = Get-Content $script:VoiceStatePath -Raw -Encoding UTF8 |
            ConvertFrom-Json
    } catch { }
}

function Sync-VoiceControls {
    $on = [bool]$script:VoiceEnabled
    if ($VoiceToggleBtn) {
        $VoiceToggleBtn.Content = if ($on) { 'MIC ON' } else { 'MIC' }
        $VoiceToggleBtn.Foreground = if ($on) { '#FFFFD7DF' } else { '#FF9AA6BE' }
        $VoiceToggleBtn.ToolTip = if ($on) { 'Disable voice control' } else { 'Enable voice control' }
    }
    if ($MenuVoice) {
        $MenuVoice.Text = if ($on) { 'Disable voice control' } else { 'Enable voice control' }
        $MenuVoice.Checked = $on
    }
}

function Set-VoiceCommandEnabled([bool]$on, [switch]$Persist) {
    $Config.voiceCommandEnabled = $on
    if ($Persist) {
        [void](Save-Setting @{ voiceCommandEnabled = $on })
    }
    if ($on) {
        if (-not (Start-VoiceBridge)) {
            [System.Windows.Forms.MessageBox]::Show(
                'The prepared Scout Voice runtime or voice profile was not found.',
                'Scout Companion',
                [System.Windows.Forms.MessageBoxButtons]::OK,
                [System.Windows.Forms.MessageBoxIcon]::Warning
            ) | Out-Null
        } else {
            $script:Hidden = $false
        }
    } else {
        Stop-VoiceBridge
    }
    Sync-VoiceControls
}

function Set-VoiceReplyEnabled([bool]$on, [switch]$Persist) {
    $Config.voiceReplyEnabled = $on
    if ($Persist) {
        [void](Save-Setting @{ voiceReplyEnabled = $on })
    }
    if ($script:VoiceEnabled) {
        Stop-VoiceBridge
        if ([bool]$Config.voiceCommandEnabled) { [void](Start-VoiceBridge) }
    }
    Sync-VoiceControls
}

function Toggle-VoiceControl {
    if ($script:VoiceEnabled) {
        Set-VoiceCommandEnabled $false -Persist
    } else {
        Set-VoiceCommandEnabled $true -Persist
    }
}

# The whole visibility policy, in one place and with no side effects, so the
# ordering of the rules is reviewable and testable rather than buried in the
# poll loop. Order matters and is the point:
#   1. anything waiting on the user is worth showing,
#   2. a minimized agent always leaves the companion visible,
#   3. otherwise show only while the agent is working out of sight,
#   4. a dismissal suppresses all automatic display rules,
#   5. an explicit pin overrides everything, including the dismissal.
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
    elseif ($AgentRunning -and $IsMinimized) { $show = $true }
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
$HeaderArea.Add_MouseLeftButtonDown({ $args[1].Handled = $true; Focus-AgentSession })
$AnswerBtn.Add_Click({ Focus-AgentSession })
$CloseBtn.Add_Click({ $script:Hidden = $true; $script:Pinned = $false; $Window.Hide() })
$SettingsBtn.Add_Click({ Show-SettingsWindow })
$VoiceToggleBtn.Add_Click({ Toggle-VoiceControl })

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

# Toggle which name the toast shows for a conversation, persist it, and force the
# session rows to rebuild so the change is visible at once rather than on the next
# time the list happens to change.
function Set-ShowChatTitle([bool]$on) {
    $Config.showChatTitle = $on
    [void](Save-Setting @{ showChatTitle = $on })
    $script:SessionSignature = $null
    $script:StepSignature = $null
    # Asking for the names is a reason to go and get them now, rather than at
    # whatever point the backoff had reached while the setting was off. Clear
    # the attempt counts too: a session given up on earlier deserves another
    # look now that the answer is wanted.
    if ($on) {
        $script:ChatScanUtc   = [datetime]::MinValue
        $script:ChatScanEvery = [double]$Config.chatTitleScanMs
        $script:ChatScanTries = @{}
    }
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
    try { Save-PendingPosition } catch { }
    try { Save-PendingVoiceSensitivity } catch { }
    try { Save-PendingNoiseSensitivity } catch { }
    try { Stop-VoiceEnrollment } catch { }
    try { Stop-VoiceBridge } catch { }
    try { $timer.Stop() } catch { }
    try { $anim.Stop() }  catch { }
    try { if ($script:SettingsWindow) { $script:SettingsWindow.Close() } } catch { }
    try {
        $Tray.Visible = $false
        $Tray.Dispose()
        if ($script:TrayIcons) { foreach ($i in $script:TrayIcons.Values) { $i.Dispose() } }
    } catch { }
    try { $Window.Close() } catch { }
    # Released explicitly so a relaunch during a slow shutdown is not refused.
    try { if ($script:InstanceMutex) { $script:InstanceMutex.ReleaseMutex(); $script:InstanceMutex.Dispose(); $script:InstanceMutex = $null } } catch { }
    try { if ($script:ShowRequest) { $script:ShowRequest.Dispose(); $script:ShowRequest = $null } } catch { }
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
$script:SettingsChatTitleCheck = $null
$script:SettingsSuppress  = $false
$script:OpacitySaveTimer  = $null
$script:OpacityPendingValue = 1.0
$script:VoiceSensitivityTimer = $null
$script:VoiceSensitivityPending = $null
$script:NoiseSensitivityTimer = $null
$script:NoiseSensitivityPending = $null
$script:VoiceEnrollmentProcess = $null
$script:VoiceEnrollmentTimer = $null
$script:VoiceEnrollmentRestart = $false
$script:SelfProc          = [System.Diagnostics.Process]::GetCurrentProcess()

function Save-PendingVoiceSensitivity {
    if (-not $script:VoiceSensitivityTimer -or
            -not $script:VoiceSensitivityTimer.IsEnabled) { return }
    $script:VoiceSensitivityTimer.Stop()
    if ($null -eq $script:VoiceSensitivityPending) { return }
    $value = [int]$script:VoiceSensitivityPending
    [void](Save-Setting @{ voiceWakeSensitivity = $value })
    if ($script:VoiceEnabled) {
        Stop-VoiceBridge
        if ([bool]$Config.voiceCommandEnabled) { [void](Start-VoiceBridge) }
        Sync-VoiceControls
    }
}

function Save-PendingNoiseSensitivity {
    if (-not $script:NoiseSensitivityTimer -or
            -not $script:NoiseSensitivityTimer.IsEnabled) { return }
    $script:NoiseSensitivityTimer.Stop()
    if ($null -eq $script:NoiseSensitivityPending) { return }
    $value = [int]$script:NoiseSensitivityPending
    [void](Save-Setting @{ voiceNoiseSensitivity = $value })
    if ($script:VoiceEnabled) {
        Stop-VoiceBridge
        if ([bool]$Config.voiceCommandEnabled) { [void](Start-VoiceBridge) }
        Sync-VoiceControls
    }
}

function Complete-VoiceEnrollment {
    $process = $script:VoiceEnrollmentProcess
    if (-not $process) { return }
    try {
        $process.Refresh()
        if (-not $process.HasExited) { return }
    } catch { return }

    if ($script:VoiceEnrollmentTimer) { $script:VoiceEnrollmentTimer.Stop() }
    $completed = $process.ExitCode -eq 0 -and
        (Test-Path (Join-Path $script:VoiceRuntimeDir 'voice-profile.dat'))
    $script:VoiceEnrollmentProcess = $null

    if ($script:SettingsVoiceEnrollButton) {
        $script:SettingsVoiceEnrollButton.IsEnabled = $true
    }
    if ($script:SettingsVoiceEnrollStatus) {
        $script:SettingsVoiceEnrollStatus.Text = if ($completed) {
            'Voice profile ready'
        } else {
            'Voice setup canceled'
        }
    }
    if ($script:VoiceEnrollmentRestart -and [bool]$Config.voiceCommandEnabled) {
        [void](Start-VoiceBridge)
        Sync-VoiceControls
    }
    $script:VoiceEnrollmentRestart = $false
}

function Start-VoiceEnrollment {
    if ($script:VoiceEnrollmentProcess) {
        try {
            $script:VoiceEnrollmentProcess.Refresh()
            if (-not $script:VoiceEnrollmentProcess.HasExited) { return }
        } catch { }
    }
    $pythonw = Join-Path $script:VoiceRuntimeDir '.venv\Scripts\pythonw.exe'
    $enrollment = Join-Path $script:VoiceRuntimeDir 'enrollment_gui.py'
    if (-not (Test-Path $pythonw) -or -not (Test-Path $enrollment)) {
        if ($script:SettingsVoiceEnrollStatus) {
            $script:SettingsVoiceEnrollStatus.Text = 'Voice setup is not installed'
        }
        return
    }

    $script:VoiceEnrollmentRestart = [bool]$script:VoiceEnabled
    if ($script:VoiceEnabled) {
        Stop-VoiceBridge
        Sync-VoiceControls
    }
    if ($script:SettingsVoiceEnrollButton) {
        $script:SettingsVoiceEnrollButton.IsEnabled = $false
    }
    if ($script:SettingsVoiceEnrollStatus) {
        $script:SettingsVoiceEnrollStatus.Text = 'Recording 5 phrases...'
    }
    try {
        $script:VoiceEnrollmentProcess = Start-Process $pythonw `
            -ArgumentList "`"$enrollment`"" `
            -WorkingDirectory $script:VoiceRuntimeDir -PassThru
        if (-not $script:VoiceEnrollmentTimer) {
            $script:VoiceEnrollmentTimer = New-Object System.Windows.Threading.DispatcherTimer
            $script:VoiceEnrollmentTimer.Interval = [TimeSpan]::FromMilliseconds(300)
            $script:VoiceEnrollmentTimer.Add_Tick({ Complete-VoiceEnrollment })
        }
        $script:VoiceEnrollmentTimer.Start()
    } catch {
        $script:VoiceEnrollmentProcess = $null
        $script:VoiceEnrollmentRestart = $false
        if ($script:SettingsVoiceEnrollButton) {
            $script:SettingsVoiceEnrollButton.IsEnabled = $true
        }
        if ($script:SettingsVoiceEnrollStatus) {
            $script:SettingsVoiceEnrollStatus.Text = 'Could not open voice setup'
        }
        if ([bool]$Config.voiceCommandEnabled) {
            [void](Start-VoiceBridge)
            Sync-VoiceControls
        }
    }
}

function Stop-VoiceEnrollment {
    if ($script:VoiceEnrollmentTimer) { $script:VoiceEnrollmentTimer.Stop() }
    $process = $script:VoiceEnrollmentProcess
    if ($process) {
        try {
            $process.Refresh()
            if (-not $process.HasExited) {
                Stop-Process -Id $process.Id -Force -ErrorAction SilentlyContinue
            }
        } catch { }
    }
    $script:VoiceEnrollmentProcess = $null
    $script:VoiceEnrollmentRestart = $false
}

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
    $script:SettingsAutoHint.Visibility = 'Visible'
}

[xml]$settingsXaml = @'
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
        xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        Title="Scout Companion settings" Width="440" SizeToContent="Height"
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
    <!-- Every tooltip in the window: capped width with wrapping so a sentence
         becomes a small block instead of a screen-wide strip, themed to match
         the dark surface. -->
    <Style TargetType="ToolTip">
      <Setter Property="Background" Value="#FF232838"/>
      <Setter Property="Foreground" Value="#FFDDE3EE"/>
      <Setter Property="BorderBrush" Value="#FF3A4358"/>
      <Setter Property="BorderThickness" Value="1"/>
      <Setter Property="Padding" Value="9,6"/>
      <Setter Property="HasDropShadow" Value="True"/>
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="ToolTip">
            <Border Background="{TemplateBinding Background}" BorderBrush="{TemplateBinding BorderBrush}"
                    BorderThickness="{TemplateBinding BorderThickness}" CornerRadius="6"
                    Padding="{TemplateBinding Padding}" MaxWidth="260">
              <TextBlock Text="{TemplateBinding Content}" Foreground="{TemplateBinding Foreground}"
                         FontSize="11.5" TextWrapping="Wrap"/>
            </Border>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>
    <!-- A small round "i" that shows its explanation on hover. Replaces the grey
         hint lines under each control, so the same information is one hover away
         without the height six paragraphs of it cost. ToolTipService opens it on
         hover with no delay and keeps it up long enough to read. -->
    <Style x:Key="Info" TargetType="Border">
      <Setter Property="Width" Value="15"/>
      <Setter Property="Height" Value="15"/>
      <Setter Property="CornerRadius" Value="7.5"/>
      <Setter Property="Background" Value="#FF2E3648"/>
      <Setter Property="Margin" Value="7,0,0,0"/>
      <Setter Property="VerticalAlignment" Value="Center"/>
      <Setter Property="Cursor" Value="Hand"/>
      <Setter Property="ToolTipService.InitialShowDelay" Value="200"/>
      <Setter Property="ToolTipService.ShowDuration" Value="20000"/>
      <Style.Triggers>
        <Trigger Property="IsMouseOver" Value="True">
          <Setter Property="Background" Value="#FF3D4964"/>
        </Trigger>
      </Style.Triggers>
    </Style>
    <Style x:Key="InfoGlyph" TargetType="TextBlock">
      <Setter Property="Text" Value="i"/>
      <Setter Property="Foreground" Value="#FFB9C2D6"/>
      <Setter Property="FontSize" Value="10"/>
      <Setter Property="FontWeight" Value="Bold"/>
      <Setter Property="FontStyle" Value="Italic"/>
      <Setter Property="HorizontalAlignment" Value="Center"/>
      <Setter Property="VerticalAlignment" Value="Center"/>
    </Style>
  </Window.Resources>

  <StackPanel Margin="18,16,18,14">

    <TextBlock Style="{StaticResource Section}" Text="STARTUP"/>
    <DockPanel LastChildFill="False">
      <CheckBox x:Name="AutoStartCheck" Content="Start automatically with Scout" DockPanel.Dock="Left" VerticalAlignment="Center"/>
      <Border Style="{StaticResource Info}" DockPanel.Dock="Left">
        <Border.ToolTip><ToolTip>Adds a shortcut to your Startup folder. The watcher launches the companion when Scout starts, and the companion closes itself shortly after Scout quits.</ToolTip></Border.ToolTip>
        <TextBlock Style="{StaticResource InfoGlyph}"/>
      </Border>
    </DockPanel>
    <!-- Kept as a named element because the code swaps its text to explain when
         the watcher is missing; it just carries no standing hint line now. -->
    <TextBlock x:Name="AutoStartHint" Style="{StaticResource Hint}" Visibility="Collapsed"/>

    <Border Height="1" Background="#FF2A3142" Margin="0,14,0,14"/>

    <TextBlock Style="{StaticResource Section}" Text="&#xC74C;&#xC131;&#xC73C;&#xB85C; &#xC81C;&#xC5B4;"/>
    <DockPanel LastChildFill="False">
      <CheckBox x:Name="VoiceCommandCheck"
                Content="&#xC74C;&#xC131;&#xC73C;&#xB85C; &#xBA85;&#xB839; &#xC2E4;&#xD589;&#xD558;&#xAE30;"
                DockPanel.Dock="Left" VerticalAlignment="Center"/>
      <Border Style="{StaticResource Info}" DockPanel.Dock="Left">
        <Border.ToolTip><ToolTip>Listens for Hey Scout and types recognized commands into the current Scout conversation. The choice is saved locally.</ToolTip></Border.ToolTip>
        <TextBlock Style="{StaticResource InfoGlyph}"/>
      </Border>
    </DockPanel>
    <DockPanel LastChildFill="False" Margin="0,10,0,0">
      <CheckBox x:Name="VoiceReplyCheck"
                Content="&#xC74C;&#xC131;&#xC73C;&#xB85C; &#xB2F5;&#xBCC0;&#xBC1B;&#xAE30;"
                DockPanel.Dock="Left" VerticalAlignment="Center"/>
      <Border Style="{StaticResource Info}" DockPanel.Dock="Left">
        <Border.ToolTip><ToolTip>Reads the final answer from that Scout conversation aloud. The choice is saved locally.</ToolTip></Border.ToolTip>
        <TextBlock Style="{StaticResource InfoGlyph}"/>
      </Border>
    </DockPanel>
    <StackPanel Margin="0,12,0,0">
      <DockPanel>
        <TextBlock Text="&quot;&#xD5E4;&#xC774; &#xC2A4;&#xCE74;&#xC6C3;&quot; &#xBD80;&#xB974;&#xAE30; &#xBBFC;&#xAC10;&#xB3C4;"
                   Foreground="#FF9AA6BE" VerticalAlignment="Center"/>
        <TextBlock x:Name="VoiceSensitivityValue" Text="65"
                   Foreground="#FFE6EAF2" VerticalAlignment="Center"
                   TextAlignment="Right" DockPanel.Dock="Right"/>
      </DockPanel>
      <Grid Margin="0,6,0,0">
        <Grid.ColumnDefinitions>
          <ColumnDefinition Width="Auto"/>
          <ColumnDefinition Width="*"/>
          <ColumnDefinition Width="Auto"/>
        </Grid.ColumnDefinitions>
        <TextBlock Grid.Column="0" Text="&#xC815;&#xD655;" Foreground="#FF8A93A6"
                   FontSize="11" VerticalAlignment="Center" Margin="0,0,8,0"/>
        <Slider x:Name="VoiceSensitivitySlider" Grid.Column="1"
                Minimum="0" Maximum="100" Value="65" TickFrequency="1"
                IsSnapToTickEnabled="True" SmallChange="1" LargeChange="10"
                VerticalAlignment="Center" Cursor="Hand"/>
        <TextBlock Grid.Column="2" Text="&#xC624;&#xCC28;&#xD5C8;&#xC6A9;"
                   Foreground="#FF8A93A6" FontSize="11"
                   VerticalAlignment="Center" Margin="8,0,0,0"/>
      </Grid>
    </StackPanel>
    <StackPanel Margin="0,12,0,0">
      <DockPanel>
        <TextBlock Text="&#xC18C;&#xC74C; &#xBBFC;&#xAC10;&#xB3C4;"
                   Foreground="#FF9AA6BE" VerticalAlignment="Center"/>
        <TextBlock x:Name="NoiseSensitivityValue" Text="35"
                   Foreground="#FFE6EAF2" VerticalAlignment="Center"
                   TextAlignment="Right" DockPanel.Dock="Right"/>
      </DockPanel>
      <Grid Margin="0,6,0,0">
        <Grid.ColumnDefinitions>
          <ColumnDefinition Width="Auto"/>
          <ColumnDefinition Width="*"/>
          <ColumnDefinition Width="Auto"/>
        </Grid.ColumnDefinitions>
        <TextBlock Grid.Column="0" Text="&#xC18C;&#xC74C; &#xCC28;&#xB2E8;"
                   Foreground="#FF8A93A6" FontSize="11"
                   VerticalAlignment="Center" Margin="0,0,8,0"/>
        <Slider x:Name="NoiseSensitivitySlider" Grid.Column="1"
                Minimum="0" Maximum="100" Value="35" TickFrequency="1"
                IsSnapToTickEnabled="True" SmallChange="1" LargeChange="10"
                VerticalAlignment="Center" Cursor="Hand"/>
        <TextBlock Grid.Column="2" Text="&#xC791;&#xC740; &#xC18C;&#xB9AC; &#xAC10;&#xC9C0;"
                   Foreground="#FF8A93A6" FontSize="11"
                   VerticalAlignment="Center" Margin="8,0,0,0"/>
      </Grid>
    </StackPanel>
    <DockPanel Margin="0,12,0,0">
      <Button x:Name="VoiceEnrollButton"
              Content="&quot;&#xD5E4;&#xC774; &#xC2A4;&#xCE74;&#xC6C3;&quot; &#xC74C;&#xC131; &#xC778;&#xC2DD;&#xD558;&#xAE30;"
              MinWidth="190" Height="28" Padding="10,0"
              Background="#FF2F6FBF" Foreground="#FFFFFFFF"
              BorderThickness="0" Cursor="Hand" DockPanel.Dock="Left"/>
      <TextBlock x:Name="VoiceEnrollStatus" Text=""
                 Foreground="#FF9AA6BE" FontSize="11"
                 Margin="10,0,0,0" VerticalAlignment="Center"
                 TextTrimming="CharacterEllipsis"/>
    </DockPanel>

    <Border Height="1" Background="#FF2A3142" Margin="0,14,0,14"/>

    <TextBlock Style="{StaticResource Section}" Text="APPEARANCE"/>
    <DockPanel LastChildFill="False">
      <CheckBox x:Name="AnimCheck" Content="Animate the mascot" DockPanel.Dock="Left" VerticalAlignment="Center"/>
      <Border Style="{StaticResource Info}" DockPanel.Dock="Left">
        <Border.ToolTip><ToolTip>Turning this off leaves the mascot in a resting pose and stops its timer entirely.</ToolTip></Border.ToolTip>
        <TextBlock Style="{StaticResource InfoGlyph}"/>
      </Border>
    </DockPanel>
    <DockPanel LastChildFill="False" Margin="0,10,0,0">
      <CheckBox x:Name="ChatTitleCheck" Content="Show the chat-list name" DockPanel.Dock="Left" VerticalAlignment="Center"/>
      <Border Style="{StaticResource Info}" DockPanel.Dock="Left">
        <Border.ToolTip><ToolTip>Off shows what you asked; on shows the name defined in Scout's chat list. Turning this on lets the companion type into Scout's chat search now and then - that is the only way the sidebar reveals the timestamps needed to tell which chat is which, and it only does it while no Scout window is in front. Either way, clicking a session still switches to the right conversation.</ToolTip></Border.ToolTip>
        <TextBlock Style="{StaticResource InfoGlyph}"/>
      </Border>
    </DockPanel>
    <DockPanel Margin="0,12,0,0" LastChildFill="True">
      <TextBlock Text="Mascot" Width="120" Foreground="#FF9AA6BE" VerticalAlignment="Center" DockPanel.Dock="Left"/>
      <ComboBox x:Name="MascotPicker" Height="26" Cursor="Hand"/>
    </DockPanel>
    <DockPanel Margin="0,10,0,0" LastChildFill="True">
      <TextBlock Text="Opacity" Width="120" Foreground="#FF9AA6BE" VerticalAlignment="Center" DockPanel.Dock="Left"/>
      <TextBlock x:Name="OpacityValue" Text="100%" Width="46" Foreground="#FFE6EAF2" VerticalAlignment="Center"
                 TextAlignment="Right" DockPanel.Dock="Right"/>
      <!-- SmallChange and LargeChange are set explicitly because the defaults
           are wrong for a range this narrow: LargeChange defaults to 1.0, which
           is larger than the whole 0.35-1.0 range, so a click on the track
           slammed the value to whichever end was clicked instead of stepping. -->
      <Slider x:Name="OpacitySlider" Minimum="0.35" Maximum="1.0" Value="1.0"
              TickFrequency="0.05" IsSnapToTickEnabled="True"
              SmallChange="0.05" LargeChange="0.05"
              VerticalAlignment="Center" Cursor="Hand"/>
    </DockPanel>
    <DockPanel LastChildFill="False" Margin="0,12,0,0">
      <CheckBox x:Name="RememberPosCheck" Content="Remember where I put it" DockPanel.Dock="Left" VerticalAlignment="Center"/>
      <Border Style="{StaticResource Info}" DockPanel.Dock="Left">
        <Border.ToolTip><ToolTip>Drag the toast anywhere and it comes back there, instead of the bottom-right corner. If the screen it was on has gone - undocked, or a display switched off - it returns to the corner rather than opening somewhere you cannot reach it, since it has no taskbar button. Turning this off forgets the saved position.</ToolTip></Border.ToolTip>
        <TextBlock Style="{StaticResource InfoGlyph}"/>
      </Border>
    </DockPanel>

    <Border Height="1" Background="#FF2A3142" Margin="0,14,0,14"/>

    <!-- The agent's activity and the companion's own overhead sit side by side:
         two labelled columns, each keeping its own heading, so the section is
         short without either losing what it is. -->
    <Grid>
      <Grid.ColumnDefinitions>
        <ColumnDefinition Width="*"/>
        <ColumnDefinition Width="20"/>
        <ColumnDefinition Width="*"/>
      </Grid.ColumnDefinitions>

      <!-- Left: the agent today -->
      <StackPanel Grid.Column="0">
        <DockPanel LastChildFill="False" Margin="0,0,0,8">
          <TextBlock Style="{StaticResource Section}" Text="THE AGENT TODAY" Margin="0" DockPanel.Dock="Left"/>
          <Border Style="{StaticResource Info}" DockPanel.Dock="Left" Margin="6,0,0,8">
            <Border.ToolTip><ToolTip>Counted from when the companion started, not from the whole day, so a companion launched at lunchtime will not know about the morning.</ToolTip></Border.ToolTip>
            <TextBlock Style="{StaticResource InfoGlyph}"/>
          </Border>
        </DockPanel>
        <Grid>
          <Grid.ColumnDefinitions>
            <ColumnDefinition Width="Auto"/><ColumnDefinition Width="*"/>
          </Grid.ColumnDefinitions>
          <Grid.RowDefinitions>
            <RowDefinition Height="Auto"/><RowDefinition Height="Auto"/><RowDefinition Height="Auto"/>
          </Grid.RowDefinitions>
          <TextBlock Grid.Row="0" Grid.Column="0" Text="Working time" Foreground="#FF9AA6BE" Margin="0,0,10,0"/>
          <TextBlock Grid.Row="0" Grid.Column="1" x:Name="AgentTimeText" Text="-" TextAlignment="Right"/>
          <TextBlock Grid.Row="1" Grid.Column="0" Text="Turns" Foreground="#FF9AA6BE" Margin="0,5,10,0"/>
          <TextBlock Grid.Row="1" Grid.Column="1" x:Name="AgentTurnsText" Text="-" TextAlignment="Right" Margin="0,5,0,0"/>
          <TextBlock Grid.Row="2" Grid.Column="0" Text="Conversations" Foreground="#FF9AA6BE" Margin="0,5,10,0"/>
          <TextBlock Grid.Row="2" Grid.Column="1" x:Name="AgentSessText" Text="-" TextAlignment="Right" Margin="0,5,0,0"/>
        </Grid>
      </StackPanel>

      <!-- Right: this process -->
      <StackPanel Grid.Column="2">
        <TextBlock Style="{StaticResource Section}" Text="THIS PROCESS"/>
        <Grid>
          <Grid.ColumnDefinitions>
            <ColumnDefinition Width="Auto"/><ColumnDefinition Width="*"/>
          </Grid.ColumnDefinitions>
          <Grid.RowDefinitions>
            <RowDefinition Height="Auto"/><RowDefinition Height="Auto"/><RowDefinition Height="Auto"/>
          </Grid.RowDefinitions>
          <TextBlock Grid.Row="0" Grid.Column="0" Text="Memory" Foreground="#FF9AA6BE" Margin="0,0,10,0"/>
          <TextBlock Grid.Row="0" Grid.Column="1" x:Name="MemText" Text="-" TextAlignment="Right"/>
          <TextBlock Grid.Row="1" Grid.Column="0" Text="CPU (of one core)" Foreground="#FF9AA6BE" Margin="0,5,10,0"/>
          <TextBlock Grid.Row="1" Grid.Column="1" x:Name="CpuText" Text="-" TextAlignment="Right" Margin="0,5,0,0"/>
          <TextBlock Grid.Row="2" Grid.Column="0" Text="Uptime" Foreground="#FF9AA6BE" Margin="0,5,10,0"/>
          <TextBlock Grid.Row="2" Grid.Column="1" x:Name="UpText" Text="-" TextAlignment="Right" Margin="0,5,0,0"/>
        </Grid>
      </StackPanel>
    </Grid>
    <!-- Long-turn notification lives with the agent stats it belongs to, on its
         own row under the two columns so it can span the full width. -->
    <DockPanel LastChildFill="False" Margin="0,12,0,0">
      <CheckBox x:Name="NotifyFinishChk" Content="Tell me when a long turn finishes" DockPanel.Dock="Left" VerticalAlignment="Center"/>
    </DockPanel>
    <!-- Kept named for the code path that referenced it; hint is a tooltip now. -->
    <TextBlock x:Name="AgentStatsHint" Style="{StaticResource Hint}" Visibility="Collapsed"/>

    <Border Height="1" Background="#FF2A3142" Margin="0,14,0,14"/>

    <TextBlock Style="{StaticResource Section}" Text="UPDATES"/>
    <DockPanel Margin="0,0,0,10">
      <TextBlock Text="Current version" Width="120" Foreground="#FF9AA6BE" DockPanel.Dock="Left"/>
      <TextBlock x:Name="VerText" Text="-"/>
    </DockPanel>
    <DockPanel LastChildFill="False">
      <CheckBox x:Name="UpdateCheckChk" Content="Check for new versions automatically" DockPanel.Dock="Left" VerticalAlignment="Center"/>
      <Border Style="{StaticResource Info}" DockPanel.Dock="Left">
        <Border.ToolTip><ToolTip>Whether to check GitHub for a newer release on a timer, a few times a day. Off makes no network calls. The 'Check now' button below always works regardless.</ToolTip></Border.ToolTip>
        <TextBlock Style="{StaticResource InfoGlyph}"/>
      </Border>
    </DockPanel>
    <DockPanel LastChildFill="False" Margin="0,6,0,0">
      <CheckBox x:Name="AutoUpdateChk" Content="Install them automatically" DockPanel.Dock="Left" VerticalAlignment="Center"/>
      <Border Style="{StaticResource Info}" DockPanel.Dock="Left">
        <Border.ToolTip><ToolTip>Off by default on purpose: this companion clicks Allow on security prompts, and replacing it the moment a release lands would restart it at a moment you did not choose. It never touches a copy running from a source checkout.</ToolTip></Border.ToolTip>
        <TextBlock Style="{StaticResource InfoGlyph}"/>
      </Border>
    </DockPanel>
    <TextBlock x:Name="AutoUpdateHint" Style="{StaticResource Hint}" Visibility="Collapsed"/>
    <DockPanel Margin="0,10,0,0">
      <Button x:Name="CheckUpdateBtn" Content="Check now" Width="96" Height="26" DockPanel.Dock="Left"
              Background="#FF2A3142" Foreground="#FFE6EAF2" BorderThickness="0" Cursor="Hand"/>
      <!-- The answer to "and now what?". Checking happened here, so installing
           has to be possible here too - it was only in the tray menu, which
           meant finding out an update existed and then having to go somewhere
           else to act on it. Hidden until there is something to install. -->
      <Button x:Name="InstallUpdateBtn" Content="Install" Width="96" Height="26" DockPanel.Dock="Left"
              Margin="8,0,0,0" Background="#FF2F6FBF" Foreground="#FFFFFFFF" BorderThickness="0"
              Cursor="Hand" Visibility="Collapsed"/>
      <TextBlock x:Name="UpdateStatus" Text="" Foreground="#FF9AA6BE" Margin="10,0,0,0"
                 VerticalAlignment="Center" TextTrimming="CharacterEllipsis"/>
    </DockPanel>

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
    $script:SettingsChatTitleCheck = $sw.FindName('ChatTitleCheck')
    $script:SettingsVoiceCommand = $sw.FindName('VoiceCommandCheck')
    $script:SettingsVoiceReply = $sw.FindName('VoiceReplyCheck')
    $script:SettingsVoiceSensitivity = $sw.FindName('VoiceSensitivitySlider')
    $script:SettingsVoiceSensitivityText = $sw.FindName('VoiceSensitivityValue')
    $script:SettingsNoiseSensitivity = $sw.FindName('NoiseSensitivitySlider')
    $script:SettingsNoiseSensitivityText = $sw.FindName('NoiseSensitivityValue')
    $script:SettingsVoiceEnrollButton = $sw.FindName('VoiceEnrollButton')
    $script:SettingsVoiceEnrollStatus = $sw.FindName('VoiceEnrollStatus')
    $script:SettingsMemText   = $sw.FindName('MemText')
    $script:SettingsCpuText   = $sw.FindName('CpuText')
    $script:SettingsUpText    = $sw.FindName('UpText')
    $script:SettingsAgentTime = $sw.FindName('AgentTimeText')
    $script:SettingsAgentTurns = $sw.FindName('AgentTurnsText')
    $script:SettingsAgentSess = $sw.FindName('AgentSessText')
    $script:SettingsNotifyChk = $sw.FindName('NotifyFinishChk')
    $script:SettingsRememberPos = $sw.FindName('RememberPosCheck')
    $script:SettingsMascot    = $sw.FindName('MascotPicker')
    $script:SettingsOpacity   = $sw.FindName('OpacitySlider')
    $script:SettingsOpacityText = $sw.FindName('OpacityValue')
    $script:SettingsUpdateChk   = $sw.FindName('UpdateCheckChk')
    $script:SettingsAutoUpdChk  = $sw.FindName('AutoUpdateChk')
    $script:SettingsUpdStatus   = $sw.FindName('UpdateStatus')
    $script:SettingsInstallBtn  = $sw.FindName('InstallUpdateBtn')
    $checkUpdBtn                = $sw.FindName('CheckUpdateBtn')
    $verText                    = $sw.FindName('VerText')
    if ($verText) { $verText.Text = $CompanionVersion }
    $closeBtn                 = $sw.FindName('CloseSettingsBtn')

    # Reflect reality, not a remembered flag. Set before the handlers are
    # attached so priming the controls cannot fire them.
    $script:SettingsAutoCheck.IsChecked = Test-AutoStart
    if (-not (Test-Path $WatcherPath)) {
        $script:SettingsAutoCheck.IsEnabled = $false
        $script:SettingsAutoHint.Text = T 'Watch-Scout.ps1 is missing from {0}, so this cannot be turned on.' $ScriptDir
        $script:SettingsAutoHint.Visibility = 'Visible'
    }
    $script:SettingsAnimCheck.IsChecked = $script:AnimEnabled
    $script:SettingsChatTitleCheck.IsChecked = [bool]$Config.showChatTitle
    $script:SettingsVoiceCommand.IsChecked = [bool]$Config.voiceCommandEnabled
    $script:SettingsVoiceReply.IsChecked = [bool]$Config.voiceReplyEnabled
    $sensitivity = [Math]::Max(0, [Math]::Min(100, [int]$Config.voiceWakeSensitivity))
    $script:SettingsVoiceSensitivity.Value = $sensitivity
    $script:SettingsVoiceSensitivityText.Text = [string]$sensitivity
    $noiseSensitivity = [Math]::Max(0, [Math]::Min(100, [int]$Config.voiceNoiseSensitivity))
    $script:SettingsNoiseSensitivity.Value = $noiseSensitivity
    $script:SettingsNoiseSensitivityText.Text = [string]$noiseSensitivity
    $voiceProfilePath = Join-Path $script:VoiceRuntimeDir 'voice-profile.dat'
    $script:SettingsVoiceEnrollStatus.Text = if (Test-Path $voiceProfilePath) {
        'Voice profile ready'
    } else {
        'Voice profile required'
    }
    if ($script:VoiceEnrollmentProcess) {
        try {
            $script:VoiceEnrollmentProcess.Refresh()
            if (-not $script:VoiceEnrollmentProcess.HasExited) {
                $script:SettingsVoiceEnrollButton.IsEnabled = $false
                $script:SettingsVoiceEnrollStatus.Text = 'Recording 5 phrases...'
            }
        } catch { }
    }

    # Updates. Primed under suppression: with Checked/Unchecked handlers, simply
    # setting IsChecked fires them, and opening the window would write config.
    # Auto-install is meaningless without the check, and a checkbox you can tick
    # that then does nothing is worse than one that is visibly unavailable.
    $script:SettingsSuppress = $true
    try {
        $script:SettingsUpdateChk.IsChecked  = [bool]$Config.updateCheck
        $script:SettingsAutoUpdChk.IsChecked = [bool]$Config.autoUpdate
        $script:SettingsAutoUpdChk.IsEnabled = [bool]$Config.updateCheck
        $script:SettingsNotifyChk.IsChecked  = [bool]$Config.notifyOnFinish
        $script:SettingsRememberPos.IsChecked = [bool]$Config.rememberPosition
    } finally { $script:SettingsSuppress = $false }
    Sync-UpdateStatusText

    # Checked/Unchecked, matching every other checkbox here.
    $onRememberPos = {
        if ($script:SettingsSuppress) { return }
        $on = [bool]$script:SettingsRememberPos.IsChecked
        $Config.rememberPosition = $on
        if ($on) {
            # Start from where it is now, rather than from a position saved
            # before the setting was turned off.
            Save-PendingPosition
            if (-not $script:SavedPosition) {
                $script:SavedPosition = [pscustomobject]@{ Left = $Window.Left; Top = $Window.Top }
                [void](Save-Setting @{ rememberPosition = $on; windowLeft = [Math]::Round($Window.Left); windowTop = [Math]::Round($Window.Top) })
                return
            }
        } else {
            # Turning it off forgets, and puts the toast back in the corner so
            # the change is visible rather than taking effect at some later
            # restart.
            $script:SavedPosition = $null
            [void](Save-Setting @{ rememberPosition = $on; windowLeft = $null; windowTop = $null })
            Place-BottomRight
            return
        }
        [void](Save-Setting @{ rememberPosition = $on })
    }
    $script:SettingsRememberPos.Add_Checked($onRememberPos)
    $script:SettingsRememberPos.Add_Unchecked($onRememberPos)

    # Checked/Unchecked, matching every other checkbox here - see the note on
    # the update ones below.
    $onNotify = {
        if ($script:SettingsSuppress) { return }
        $on = [bool]$script:SettingsNotifyChk.IsChecked
        $Config.notifyOnFinish = $on
        Save-Setting @{ notifyOnFinish = $on }
    }
    $script:SettingsNotifyChk.Add_Checked($onNotify)
    $script:SettingsNotifyChk.Add_Unchecked($onNotify)

    # Checked/Unchecked, not Click. Click fires only for an actual mouse press,
    # so a keyboard toggle or an accessibility tool would flip the box and save
    # nothing - the control would show one thing and config.json another.
    $onUpdateCheck = {
        if ($script:SettingsSuppress) { return }
        $on = [bool]$script:SettingsUpdateChk.IsChecked
        $Config.updateCheck = $on
        $script:SettingsAutoUpdChk.IsEnabled = $on
        # Turning it back on should look now, not in six hours.
        if ($on) { $script:UpdateCheckUtc = [datetime]::MinValue }
        Save-Setting @{ updateCheck = $on }
        Sync-UpdateStatusText
    }
    $script:SettingsUpdateChk.Add_Checked($onUpdateCheck)
    $script:SettingsUpdateChk.Add_Unchecked($onUpdateCheck)

    $onAutoUpdate = {
        if ($script:SettingsSuppress) { return }
        $on = [bool]$script:SettingsAutoUpdChk.IsChecked
        $Config.autoUpdate = $on
        Save-Setting @{ autoUpdate = $on }
        # If one is already waiting, honour the new setting immediately rather
        # than leaving it sitting there after being told to install it.
        if ($on -and $script:UpdateAvail) { Install-CompanionUpdate }
    }
    $script:SettingsAutoUpdChk.Add_Checked($onAutoUpdate)
    $script:SettingsAutoUpdChk.Add_Unchecked($onAutoUpdate)
    if ($script:SettingsInstallBtn) {
        $script:SettingsInstallBtn.Add_Click({
            Install-CompanionUpdate
        })
    }
    if ($checkUpdBtn) {
        $checkUpdBtn.Add_Click({
            Write-CompanionLog 'update check requested from settings'
            $script:UpdateCheckUtc = [datetime]::MinValue
            $script:UpdateAvail = $null      # so an already-known one is re-announced
            $script:UpdateAnnounce = $true   # and so it looks even if checking is off
            $script:UpdateError = $null      # a fresh attempt, not last time's failure
            $script:SettingsUpdStatus.Text = T 'Checking...'
            Update-CheckForRelease
        })
    }

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
    $script:SettingsChatTitleCheck.Add_Checked({
        if (-not $script:SettingsSuppress) { Set-ShowChatTitle $true }
    })
    $script:SettingsChatTitleCheck.Add_Unchecked({
        if (-not $script:SettingsSuppress) { Set-ShowChatTitle $false }
    })
    $onVoiceCommand = {
        if ($script:SettingsSuppress) { return }
        $on = [bool]$script:SettingsVoiceCommand.IsChecked
        Set-VoiceCommandEnabled $on -Persist
    }
    $script:SettingsVoiceCommand.Add_Checked($onVoiceCommand)
    $script:SettingsVoiceCommand.Add_Unchecked($onVoiceCommand)
    $onVoiceReply = {
        if ($script:SettingsSuppress) { return }
        Set-VoiceReplyEnabled ([bool]$script:SettingsVoiceReply.IsChecked) -Persist
    }
    $script:SettingsVoiceReply.Add_Checked($onVoiceReply)
    $script:SettingsVoiceReply.Add_Unchecked($onVoiceReply)
    $script:SettingsVoiceSensitivity.Add_ValueChanged({
        $value = [int]$script:SettingsVoiceSensitivity.Value
        $script:SettingsVoiceSensitivityText.Text = [string]$value
        $Config.voiceWakeSensitivity = $value
        $script:VoiceSensitivityPending = $value
        if (-not $script:VoiceSensitivityTimer) {
            $script:VoiceSensitivityTimer = New-Object System.Windows.Threading.DispatcherTimer
            $script:VoiceSensitivityTimer.Interval = [TimeSpan]::FromMilliseconds(700)
            $script:VoiceSensitivityTimer.Add_Tick({ Save-PendingVoiceSensitivity })
        }
        $script:VoiceSensitivityTimer.Stop()
        $script:VoiceSensitivityTimer.Start()
    })
    $script:SettingsNoiseSensitivity.Add_ValueChanged({
        $value = [int]$script:SettingsNoiseSensitivity.Value
        $script:SettingsNoiseSensitivityText.Text = [string]$value
        $Config.voiceNoiseSensitivity = $value
        $script:NoiseSensitivityPending = $value
        if (-not $script:NoiseSensitivityTimer) {
            $script:NoiseSensitivityTimer = New-Object System.Windows.Threading.DispatcherTimer
            $script:NoiseSensitivityTimer.Interval = [TimeSpan]::FromMilliseconds(700)
            $script:NoiseSensitivityTimer.Add_Tick({ Save-PendingNoiseSensitivity })
        }
        $script:NoiseSensitivityTimer.Stop()
        $script:NoiseSensitivityTimer.Start()
    })
    $script:SettingsVoiceEnrollButton.Add_Click({ Start-VoiceEnrollment })

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
            # Same trap as Format-Duration: [int] rounds, so an uptime of 2h50m
            # displayed as "3h 50m". Floor it.
            $script:SettingsUpText.Text = if ($up.TotalHours -ge 1) {
                '{0}h {1}m' -f ([int][Math]::Floor($up.TotalHours)), $up.Minutes
            } else {
                '{0}m {1}s' -f $up.Minutes, $up.Seconds
            }

            # What the agent did, as opposed to what this process cost. Read
            # from the same turn timings the finish notice uses.
            $script:SettingsAgentTime.Text  = Format-Duration $script:TurnSecsToday
            $script:SettingsAgentTurns.Text = '{0:N0}' -f $script:TurnsToday
            # Sessions followed right now, not all day: the companion only keeps
            # the active set, so a count of "conversations today" would be a
            # number it cannot honestly produce.
            $script:SettingsAgentSess.Text  = '{0:N0}' -f $Sessions.Count
        } catch { }
    })
    $script:SettingsResTimer.Start()

    $closeBtn.Add_Click({ if ($script:SettingsWindow) { $script:SettingsWindow.Close() } })
    $sw.Add_Closed({
        # Drain the debounced opacity write before the window goes: closing the
        # settings window right after moving the slider otherwise dropped it.
        try { Save-PendingOpacity } catch { }
        try { Save-PendingPosition } catch { }
        try { Save-PendingVoiceSensitivity } catch { }
        try { Save-PendingNoiseSensitivity } catch { }
        try { $script:SettingsResTimer.Stop() } catch { }
        $script:SettingsWindow    = $null
        $script:SettingsAnimCheck = $null
        $script:SettingsChatTitleCheck = $null
        $script:SettingsRememberPos = $null
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
# ---------------------------------------------------------------------------
# Updates
#
# Deliberately notify-first. Silently replacing a running process whose job is
# to click Allow on security prompts is not a default worth having: the restart
# would land at an unpredictable moment and could drop an approval that was
# already on screen. So the check is automatic, the install is a click. Anyone
# who wants it hands-off sets autoUpdate in config.
# ---------------------------------------------------------------------------

function Write-CompanionLog([string]$msg) {
    # Same file the tick's own debug line uses, so update activity lands in
    # sequence with everything else rather than in a log of its own.
    try {
        Add-Content -Path (Join-Path $env:TEMP 'scout-companion-debug.log') `
            -Value ("{0} {1}" -f (Get-Date -Format 'HH:mm:ss'), $msg)
    } catch { }
}

# Compare two dotted versions. Returns -1, 0, 1 like a comparer.
#
# [version] alone will not do: it throws on a leading "v", on a pre-release
# suffix, and on a bare "1", all three of which appear in real release tags.
function Compare-CompanionVersion([string]$a, [string]$b) {
    function Split-V([string]$v) {
        if (-not $v) { return @(0, 0, 0) }
        $v = ([string]$v).Trim().TrimStart('v', 'V')
        $v = ($v -split '[-+]')[0]          # drop -beta.1 / +build
        $parts = @($v -split '\.' | ForEach-Object {
            $n = 0
            if ([int]::TryParse(($_ -replace '\D', ''), [ref]$n)) { $n } else { 0 }
        })
        while ($parts.Count -lt 3) { $parts += 0 }
        return $parts
    }
    $x = Split-V $a
    $y = Split-V $b
    for ($i = 0; $i -lt 3; $i++) {
        if ($x[$i] -gt $y[$i]) { return 1 }
        if ($x[$i] -lt $y[$i]) { return -1 }
    }
    return 0
}

# Whether an update may be installed over this copy.
#
# The installer overwrites its target wholesale, so pointing it at a git
# checkout would throw away someone's uncommitted work. A checkout is also
# exactly where a developer runs from, so this is not a rare case.
function Test-UpdatableInstall([string]$scriptDir, [string]$installDir) {
    if (-not $scriptDir -or -not $installDir) { return $false }
    if ([System.IO.Directory]::Exists([System.IO.Path]::Combine($scriptDir, '.git'))) { return $false }
    $a = $scriptDir.TrimEnd('\', '/')
    $b = $installDir.TrimEnd('\', '/')
    return [string]::Equals($a, $b, [StringComparison]::OrdinalIgnoreCase)
}

$script:InstallDir     = [System.IO.Path]::Combine($env:LOCALAPPDATA, 'Programs', 'ScoutCompanion')
$script:UpdateAvail    = $null      # the tag, once one is found
$script:UpdateCheckUtc = [datetime]::MinValue
$script:UpdateBusy     = $false
$script:UpdateFailed   = $false
$script:UpdateChecked  = $false   # a check has completed at least once
$script:UpdateInstalling = $false # an install was launched and has not failed
$script:UpdateError    = $null    # why the last install attempt did not start
$script:UpdateAnnounce = $false   # set for a check the user asked for explicitly
$script:UpdatePs       = $null
$script:UpdateHandle   = $null

# What to say about updates in the settings window. One function, because the
# state is asked about from three places - opening the window, finishing a
# check, and toggling the checkbox - and three ways of phrasing it would drift.
#
# The result of the last check outranks "Not checking.". Letting the setting
# speak first meant pressing Check now with periodic checks turned off ran the
# check, got an answer, and then overwrote it with "Not checking." - so the
# button appeared to do nothing at all.
function Sync-UpdateStatusText {
    if (-not $script:SettingsUpdStatus) { return }
    try {
        $t = if ($script:UpdateInstalling) { T 'Installing...' }
             elseif ($script:UpdateError)  { (T 'Update failed:') + ' ' + $script:UpdateError }
             elseif ($script:UpdateBusy)   { T 'Checking...' }
             elseif ($script:UpdateAvail) {
                 if (Test-UpdatableInstall $PSScriptRoot $script:InstallDir) {
                     (T '{0} is available.' $script:UpdateAvail)
                 } else {
                     # Say why, rather than offering a button that would refuse.
                     (T '{0} is available, but this copy runs from a source checkout.' $script:UpdateAvail)
                 }
             }
             elseif ($script:UpdateFailed) { T 'Could not reach GitHub.' }
             elseif ($script:UpdateChecked) { T 'Up to date.' }
             elseif (-not $Config.updateCheck) { T 'Not checking.' }
             else { '' }
        $script:SettingsUpdStatus.Text = $t

        # The Install button appears exactly when installing is possible: an
        # update found, this copy replaceable, and nothing already under way.
        if ($script:SettingsInstallBtn) {
            $can = [bool]$script:UpdateAvail -and
                   (Test-UpdatableInstall $PSScriptRoot $script:InstallDir) -and
                   -not $script:UpdateInstalling
            $want = if ($can) { 'Visible' } else { 'Collapsed' }
            if ($script:SettingsInstallBtn.Visibility -ne $want) { $script:SettingsInstallBtn.Visibility = $want }
        }
    } catch { }
}

function Update-CheckForRelease {
    # An explicit ask overrides both the setting and the timer. Refusing to look
    # because the periodic check is off would make the menu item and the button
    # do nothing at all, which reads as broken rather than as disabled.
    if (-not $Config.updateCheck -and -not $script:UpdateAnnounce) { return }
    if ($script:UpdateBusy) { return }
    if (-not $script:UpdateAnnounce) {
        $due = $script:UpdateCheckUtc.AddHours([double]$Config.updateCheckHours)
        if ([datetime]::UtcNow -lt $due) { return }
    }
    $script:UpdateCheckUtc = [datetime]::UtcNow

    # The network call blocks, and this runs on the UI thread, so a slow or
    # unreachable github would freeze the toast. Do it on a runspace and pick
    # the answer up on a later tick.
    $script:UpdateBusy = $true
    $ps = [powershell]::Create()
    [void]$ps.AddScript({
        param($repo)
        try {
            $ProgressPreference = 'SilentlyContinue'
            try { [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12 } catch { }
            $r = Invoke-RestMethod -Uri "https://api.github.com/repos/$repo/releases/latest" `
                -Headers @{ 'User-Agent' = 'scout-companion' } -TimeoutSec 15
            if ($r -and $r.tag_name) { return [string]$r.tag_name }
        } catch { }
        return $null
    }).AddArgument([string]$Config.updateRepo)
    $script:UpdatePs     = $ps
    $script:UpdateHandle = $ps.BeginInvoke()
}

function Complete-UpdateCheck {
    if (-not $script:UpdateBusy -or -not $script:UpdateHandle) { return }
    if (-not $script:UpdateHandle.IsCompleted) { return }
    $tag = $null
    try { $tag = @($script:UpdatePs.EndInvoke($script:UpdateHandle))[0] } catch { }
    try { $script:UpdatePs.Dispose() } catch { }
    $script:UpdatePs = $null; $script:UpdateHandle = $null; $script:UpdateBusy = $false

    # Every path from here has to end at Sync-UpdateStatusText. An early return
    # left the settings window saying "Checking..." for the rest of the session,
    # which is exactly what someone who just pressed the button would read as a
    # hang - and a failed check is the most likely reason to be looking.
    try {
        if (-not $tag) {
            Write-CompanionLog 'update check failed (offline or rate-limited)'
            $script:UpdateFailed = $true
            if ($script:UpdateAnnounce) { Show-TrayBalloon (T 'Update check failed') (T 'Could not reach GitHub.') }
            return
        }
        $script:UpdateFailed = $false
        $script:UpdateChecked = $true
        Write-CompanionLog "update check: latest=$tag running=$CompanionVersion"

        if ((Compare-CompanionVersion $tag $CompanionVersion) -le 0) {
            $script:UpdateAvail = $null
            if ($script:UpdateAnnounce) { Show-TrayBalloon (T 'Up to date.') "$CompanionVersion" }
            return
        }
        if ($script:UpdateAvail -eq $tag -and -not $script:UpdateAnnounce) { return }   # already told them
        $script:UpdateAvail = $tag

        if (-not (Test-UpdatableInstall $PSScriptRoot $script:InstallDir)) {
            # Still worth saying, because a developer wants to know a release went
            # out - but do not offer to install over their checkout.
            Write-CompanionLog "update $tag available; not installable from $PSScriptRoot"
            if ($script:UpdateAnnounce) { Show-TrayBalloon (T 'Update available') $tag }
            return
        }
        # Unattended install is for the background check, not for a button the
        # user just pressed. "Check for updates" asks a question; answering it
        # by silently replacing the running program is not what was asked, and
        # when that install then failed there was nothing on screen to say so.
        if ($Config.autoUpdate -and -not $script:UpdateAnnounce) { Install-CompanionUpdate; return }
        Show-TrayBalloon (T 'Update available') "$CompanionVersion -> $($tag.TrimStart('v'))"
    } finally {
        $script:UpdateAnnounce = $false
        Sync-UpdateStatusText
    }
}

# One place that raises a tray balloon. Was Show-UpdateBalloon until the finish
# notice needed it too - a name that says what it does rather than who calls it.
function Show-TrayBalloon([string]$title, [string]$text) {
    try {
        $Tray.BalloonTipTitle = $title
        $Tray.BalloonTipText  = $text
        $Tray.ShowBalloonTip(8000)
    } catch { }
}

function Install-CompanionUpdate {
    if (-not (Test-UpdatableInstall $PSScriptRoot $script:InstallDir)) {
        try {
            [System.Windows.Forms.MessageBox]::Show(
                (T 'This copy runs from a source checkout, so it will not be replaced automatically.'),
                'Scout Companion') | Out-Null
        } catch { }
        return
    }
    # The installer stops the running companion, so the companion cannot be the
    # thing that runs it. Hand it to a detached shell and get out of the way.
    #
    # No tag is passed: web-install defaults to the latest release, which is
    # exactly what was detected. Setting $Tag beforehand would not work anyway -
    # the downloaded script opens with param(), so iex binds nothing and the
    # parameter's own empty default would win.
    $cmd = "`$ProgressPreference='SilentlyContinue'; " +
           "[Net.ServicePointManager]::SecurityProtocol=[Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12; " +
           "iex ((New-Object Net.WebClient).DownloadString('https://raw.githubusercontent.com/$($Config.updateRepo)/main/web-install.ps1'))"
    try {
        Write-CompanionLog "installing update $($script:UpdateAvail)"
        $script:UpdateInstalling = $true
        Sync-UpdateStatusText
        Start-Process powershell -ArgumentList '-NoProfile', '-ExecutionPolicy', 'Bypass', '-WindowStyle', 'Hidden', '-Command', $cmd -ErrorAction Stop
    } catch {
        # Silence here was the whole problem. An update that could not start
        # left the tray item sitting there, the status saying an update was
        # available, and nothing anywhere saying the attempt had failed - so
        # pressing the button appeared to do nothing at all.
        Write-CompanionLog "update launch failed: $_"
        $script:UpdateInstalling = $false
        $script:UpdateError = $_.Exception.Message
        Sync-UpdateStatusText
        Show-TrayBalloon (T 'Update failed') ("{0}" -f $_.Exception.Message)
    }
}

$MenuOpen  = New-Object System.Windows.Forms.ToolStripMenuItem (T 'Open Scout')
$MenuVoice = New-Object System.Windows.Forms.ToolStripMenuItem 'Enable voice control'
$MenuPause = New-Object System.Windows.Forms.ToolStripMenuItem (T 'Pause animation')
$MenuSet   = New-Object System.Windows.Forms.ToolStripMenuItem (T 'Settings...')
$MenuExit  = New-Object System.Windows.Forms.ToolStripMenuItem (T 'Exit')
$MenuPause.CheckOnClick = $true
$MenuPause.Checked = -not $script:AnimEnabled
$MenuVoice.CheckOnClick = $false

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
$MenuVoice.Add_Click({ Toggle-VoiceControl })
$MenuPause.Add_Click({
    # CheckOnClick has already flipped Checked by the time this runs.
    Sync-AnimationEnabled (-not $MenuPause.Checked) -Persist
})
$MenuSet.Add_Click({ Show-SettingsWindow })
$MenuExit.Add_Click({ Stop-Companion })

$MenuUpdate = New-Object System.Windows.Forms.ToolStripMenuItem (T 'Install update')
$MenuUpdate.Available = $false
$MenuUpdate.Add_Click({ Install-CompanionUpdate })

# Always present, unlike the item above. Without it the whole feature was
# invisible until it had something to say, so there was no way to ask.
$MenuCheck = New-Object System.Windows.Forms.ToolStripMenuItem (T 'Check for updates')
$MenuCheck.Add_Click({
    $script:UpdateCheckUtc = [datetime]::MinValue
    $script:UpdateAvail = $null
    # An explicit ask deserves an answer even when the answer is "nothing new" -
    # otherwise a silent check is indistinguishable from a broken menu item.
    $script:UpdateAnnounce = $true
    Update-CheckForRelease
})

$TrayMenu = New-Object System.Windows.Forms.ContextMenuStrip
[void]$TrayMenu.Items.Add($MenuShow)
[void]$TrayMenu.Items.Add($MenuOpen)
[void]$TrayMenu.Items.Add($MenuVoice)
[void]$TrayMenu.Items.Add((New-Object System.Windows.Forms.ToolStripSeparator))
[void]$TrayMenu.Items.Add($MenuPause)
[void]$TrayMenu.Items.Add($MenuSet)
[void]$TrayMenu.Items.Add((New-Object System.Windows.Forms.ToolStripSeparator))
[void]$TrayMenu.Items.Add($MenuUpdate)
[void]$TrayMenu.Items.Add($MenuCheck)
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
# Puts the name of a conversation on a line of its own, or hides the line when
# there is nothing worth saying. Used for both the prompt card and the header,
# so a session is named the same way whichever part of the toast is showing it.
function Set-FromLine($block, $item) {
    $from = (Where-From $item) -replace '^\s*-\s*',''
    if ($from) {
        $block.Text = $from.Trim()
        $block.Visibility = 'Visible'
    } else {
        $block.Text = ''
        $block.Visibility = 'Collapsed'
    }
}

# Fills the prompt card: a prose headline, and the literal request under it.
# The detail collapses when it would only repeat the headline, so a plain "Read
# a file" prompt does not leave an empty box under it.
function Set-PermBody([string]$summary, [string]$detail, [bool]$mono) {
    $PermSummary.Text = $summary
    $PermSummary.Visibility = if ($summary) { 'Visible' } else { 'Collapsed' }
    $PermText.Text = $detail
    $PermText.Visibility = if ($detail) { 'Visible' } else { 'Collapsed' }
    # A command reads as code and belongs in a mono face; a path or a sentence
    # does not, and setting one for everything made prose look like a log line.
    $PermText.FontFamily = if ($mono) { $script:MonoFont } else { $script:UiFont }
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

# Order and group the sessions for display.
#
# The toast hands its whole body to whichever session moved most recently, which
# is fine for one and useless for several: measured with two working at once,
# the body changed owner 21 times in 30 seconds. What was on screen was two
# unrelated jobs interleaved - not merely uninformative, but untrustworthy,
# because it reads as one coherent list.
#
# Working sessions come first, and that is not the churn this was meant to
# avoid. Sorting by last-event time would reorder every second or two; running
# versus idle is a binary that changes only when a session actually starts or
# stops, which is exactly the event worth reacting to. Within each group the
# order is by when the session appeared, so nothing shuffles.
#
# Pure, so the arrangement can be tested without a toast.
function Group-SessionRows($sessions) {
    $items = @($sessions)
    if ($items.Count -eq 0) { return @() }
    $busy = @($items | Where-Object { $_.Busy })
    $rest = @($items | Where-Object { -not $_.Busy })
    return @($busy + $rest)
}

# Short enough to sit at the end of a line, and never a bare number of seconds
# once it is minutes old - "idle 3m" is the useful shape, "idle 187s" is not.
#
# Floor, not [int]: PowerShell's cast rounds, so 90 seconds reported as "2m" and
# 7,100 as "2h" - both claiming more time had passed than actually had, on a
# value that sits on screen next to every idle session.
function Format-Idle([int]$seconds) {
    if ($seconds -lt 60)   { return "${seconds}s" }
    if ($seconds -lt 3600) { return ("{0}m" -f [int][Math]::Floor($seconds / 60)) }
    return ("{0}h" -f [int][Math]::Floor($seconds / 3600))
}

# There are two panels that show what the agent is doing - the step list for a
# single session, and the per-session rows for several - and exactly one of them
# may be on screen at a time.
#
# This exists because adding the second panel left the prompt paths still hiding
# only the first. With two sessions and an approval up, the old step list and
# the new rows were both visible at once, one above the other, showing the same
# work twice. Anything that clears the body has to clear both, so there is one
# place that does it.
function Hide-ActivityPanels {
    if ($StepsPanel.Visibility -ne 'Collapsed') { $StepsPanel.Visibility = 'Collapsed' }
    if ($SessionsPanel.Visibility -ne 'Collapsed') {
        $SessionsPanel.Visibility = 'Collapsed'
        # Force a rebuild next time: the signature is what suppresses redundant
        # work, and leaving it set would skip the rebuild after the panel had
        # been emptied by something else.
        $script:SessionSignature = $null
    }
    # The elapsed counter belongs to a running turn. A prompt means the turn has
    # stopped and is waiting on you, so leaving the number up would have it
    # counting time that is now yours rather than the agent's.
    if ($ElapsedText.Visibility -ne 'Collapsed') { $ElapsedText.Visibility = 'Collapsed' }
}

# Build the rows. Real elements, so colour and weight can say what a single
# monospace block could not: which session is running, and which activity line
# belongs to which name.
#
# Three signals, because one was not enough. A left accent bar ties a name and
# its activity together as one object and marks the running ones green. The
# name is brighter and heavier while working. The activity sits inside the bar
# so it cannot be read as belonging to the row above.
$script:SessionSignature = $null
function Render-SessionRows($rows) {
    # Rebuilding a StackPanel is far more expensive than setting a string, and
    # this runs every poll, so skip it entirely when nothing has changed.
    $sig = ($rows | ForEach-Object { "$($_.Dir)|$($_.Busy)|$($_.Name)|$($_.Activity)|$($_.HideActivity)|$(Format-Idle ([int]$_.IdleSeconds))" }) -join "`n"
    if ($sig -ne $script:SessionSignature) {
        $script:SessionSignature = $sig
        $SessionsList.Children.Clear()

        # A faint wash behind a row the pointer is over, so an openable row reads
        # as clickable. Built once and kept at script scope so the hover handlers
        # can see it.
        if (-not $script:RowHoverBrush) {
            $script:RowHoverBrush = (New-Object System.Windows.Media.BrushConverter).ConvertFromString('#22FFFFFF')
        }

        $accentOn   = '#FF4ADE80'   # same green the header dot uses while working
        $accentOff  = '#FF39415A'
        $nameOn     = '#FFEDF2FA'
        $nameOff    = '#FF8A93A6'
        $actOn      = '#FFC7D0E2'
        $actOff     = '#FF6C7488'

        $first = $true
        foreach ($r in $rows) {
            $busy = [bool]$r.Busy

            $bar = New-Object System.Windows.Controls.Border
            $bar.Width = 3
            $bar.CornerRadius = New-Object System.Windows.CornerRadius 2
            $bar.Background = (New-Object System.Windows.Media.BrushConverter).ConvertFromString($(if ($busy) { $accentOn } else { $accentOff }))
            $bar.VerticalAlignment = 'Stretch'

            $texts = New-Object System.Windows.Controls.StackPanel
            $texts.Margin = New-Object System.Windows.Thickness 8, 0, 0, 0

            $nameTb = New-Object System.Windows.Controls.TextBlock
            $nameTb.Text = if ($r.Name) { [string]$r.Name } else { '(unnamed)' }
            $nameTb.FontSize = 12.5
            $nameTb.FontWeight = if ($busy) { 'SemiBold' } else { 'Normal' }
            $nameTb.Foreground = (New-Object System.Windows.Media.BrushConverter).ConvertFromString($(if ($busy) { $nameOn } else { $nameOff }))
            # Let WPF measure. Counting characters is wrong for anything but
            # Latin - Consolas renders Hangul at 1.82x a Latin glyph, so a
            # Korean title was being cut a third short of its actual room.
            $nameTb.TextTrimming = 'CharacterEllipsis'
            $nameTb.TextWrapping = 'NoWrap'
            [void]$texts.Children.Add($nameTb)

            # A single session hides its busy one-liner here because the step list
            # below repeats it; an idle one still shows how long it has been quiet,
            # which the step list does not say.
            $act = if ($busy) { if ($r.HideActivity) { '' } else { [string]$r.Activity } }
                   elseif ($null -ne $r.IdleSeconds) { (T 'Idle') + ' ' + (Format-Idle ([int]$r.IdleSeconds)) }
                   else { '' }
            if ($act) {
                $actTb = New-Object System.Windows.Controls.TextBlock
                $actTb.FontSize = 10.5
                $actTb.FontFamily = New-Object System.Windows.Media.FontFamily 'Consolas, Cascadia Mono, monospace'
                $actTb.Margin = New-Object System.Windows.Thickness 0, 5, 0, 0
                # Same visual language as the step list below: a small ▸ marker
                # carries the "in progress" sense so the verb label ("Running:")
                # no longer has to shout it. Running rows get the marker; an idle
                # "idle 3m" line is a status, not a step, so it stays plain.
                if ($busy) {
                    $mk = New-Object System.Windows.Documents.Run ([string][char]0x25B8 + '  ')
                    $mk.Foreground = (New-Object System.Windows.Media.BrushConverter).ConvertFromString($accentOn)
                    [void]$actTb.Inlines.Add($mk)
                    $tx = New-Object System.Windows.Documents.Run ([string]$act)
                    $tx.Foreground = (New-Object System.Windows.Media.BrushConverter).ConvertFromString($actOn)
                    [void]$actTb.Inlines.Add($tx)
                    $actTb.TextWrapping = 'Wrap'
                    $actTb.MaxHeight = 30
                } else {
                    $actTb.Text = $act
                    $actTb.Foreground = (New-Object System.Windows.Media.BrushConverter).ConvertFromString($actOff)
                    $actTb.TextWrapping = 'NoWrap'
                }
                $actTb.TextTrimming = 'CharacterEllipsis'
                [void]$texts.Children.Add($actTb)
            }

            $row = New-Object System.Windows.Controls.DockPanel
            $row.LastChildFill = $true
            [System.Windows.Controls.DockPanel]::SetDock($bar, 'Left')

            # Every row is a place you can go: a chevron marks it, and the whole
            # row - not a small button - is the click target so a glance-and-click
            # lands. Clicking opens that conversation; the first open of a session
            # also teaches the companion Scout's name for it, so it is exact from
            # then on.
            $chev = New-Object System.Windows.Controls.TextBlock
            $chev.Text = [string][char]0x203A   # >
            $chev.FontSize = 13
            $chev.Foreground = (New-Object System.Windows.Media.BrushConverter).ConvertFromString($(if ($busy) { $actOn } else { $actOff }))
            $chev.VerticalAlignment = 'Center'
            $chev.Margin = New-Object System.Windows.Thickness 6, 0, 2, 0
            $chev.Opacity = 0.55
            [System.Windows.Controls.DockPanel]::SetDock($chev, 'Right')
            [void]$row.Children.Add($chev)
            [void]$row.Children.Add($bar)
            [void]$row.Children.Add($texts)

            $rowHost = New-Object System.Windows.Controls.Border
            $rowHost.CornerRadius = New-Object System.Windows.CornerRadius 6
            $rowHost.Padding = New-Object System.Windows.Thickness 4, 3, 4, 3
            $rowHost.Background = [System.Windows.Media.Brushes]::Transparent
            $rowHost.Cursor = [System.Windows.Input.Cursors]::Hand
            $rowHost.ToolTip = (T 'Open')
            # The session's folder rides on Tag, not a captured loop variable, so
            # the handler reads it off the row it actually fired on.
            $rowHost.Tag = [string]$r.Dir
            $rowHost.Child = $row
            if (-not $first) { $rowHost.Margin = New-Object System.Windows.Thickness 0, 4, 0, 0 }
            $rowHost.Add_MouseEnter({ $args[0].Background = $script:RowHoverBrush })
            $rowHost.Add_MouseLeave({ $args[0].Background = [System.Windows.Media.Brushes]::Transparent })
            # Handled on the way down so it never reaches the window's DragMove,
            # which would otherwise swallow the click.
            $rowHost.Add_MouseLeftButtonDown({
                $args[1].Handled = $true
                $d = [string]$args[0].Tag
                if ($d) { try { Focus-AgentSessionByDir $d } catch { } }
            })

            [void]$SessionsList.Children.Add($rowHost)
            $first = $false
        }
    }
    if ($SessionsPanel.Visibility -ne 'Visible') { $SessionsPanel.Visibility = 'Visible' }
}

# Whether a finished turn is worth a tray balloon.
#
# Two ways it is not. The agent is in front, so you are looking at the thing
# that just finished. Or the toast is on screen already saying so, and a balloon
# would repeat it. Pulled out as a function because the rule is easy to state
# and easy to get subtly wrong inside a tick full of other conditions.
function Test-ShouldNotifyFinish([bool]$isForeground, [bool]$shouldShow, [bool]$isVisible) {
    if ($isForeground) { return $false }
    return (-not $shouldShow) -or (-not $isVisible)
}

# How long the running turn has been going, or nothing when that is not worth
# saying. Pure, so the threshold behaviour can be tested without a toast.
#
# Silent below the threshold on purpose. The median turn is 11 seconds; a
# counter ticking through every one of those would be motion carrying no
# information, and would train the eye to ignore the one place that later has
# something to say.
function Get-ElapsedLabel($startUtc, [datetime]$nowUtc, [int]$afterSeconds = 20) {
    if (-not $startUtc) { return '' }
    $secs = ($nowUtc - $startUtc).TotalSeconds
    if ($secs -lt $afterSeconds) { return '' }
    # A wrong clock or an out-of-order write should show nothing rather than a
    # negative or a number of days.
    if ($secs -lt 0 -or $secs -ge 86400) { return '' }
    return Format-Idle ([int]$secs)
}

function Render-Steps {
    # One visual language for one session or many: always draw the session
    # row(s) - a green bar, the conversation name, a chevron that opens it - and,
    # when only one session is running, add its fuller step list underneath. The
    # header line above carries the state ("Working hard...") and no longer the
    # conversation name, which now lives on its own row.
    $single = $Sessions.Count -le 1

    # Build a row per session (usually one). Same shape Render-SessionRows expects.
    $rows = @()
    $ordered = @($Sessions.Keys | Sort-Object @{ E = { $Sessions[$_].FirstSeenUtc } }, @{ E = { $_ } })
    foreach ($dir in $ordered) {
        $rec = $Sessions[$dir]
        $idleSec = [int]([datetime]::UtcNow - $rec.LastEventUtc).TotalSeconds
        # Quiet for long enough is quiet, whatever the step list says. A session
        # interrupted mid-tool keeps an unfinished step forever, and taking that
        # at face value left it showing a green "Running:" hours after it stopped.
        $recent = $idleSec -le [double]$Config.activeWindowSeconds
        $busy = $recent -and [bool]$rec.TurnActive
        $act = ''
        if ($rec.Steps.Count) {
            $live = @($rec.Steps | Where-Object { -not $_.Done })
            if ($live.Count -and $recent) { $act = $live[-1].Text; $busy = $true }
            else { $act = $rec.Steps[$rec.Steps.Count - 1].Text }
        }
        $name = Get-SessionSubject $rec
        if (-not $name) { $name = $rec.Label }
        $rows += [pscustomobject]@{
            Dir         = $dir
            Name        = $name
            Busy        = $busy
            Activity    = $act
            IdleSeconds = $idleSec
            # A single session hides its one-line activity here: the detailed
            # step list below carries it, so repeating it on the row would say
            # the same thing twice.
            HideActivity = $single
        }
    }

    if ($rows.Count -gt 0) {
        Render-SessionRows (Group-SessionRows $rows)
    } else {
        if ($SessionsPanel.Visibility -ne 'Collapsed') {
            $SessionsPanel.Visibility = 'Collapsed'
            $script:SessionSignature = $null
        }
    }

    # The detailed step list belongs to the single-session case only.
    if (-not $single) {
        if ($StepsPanel.Visibility -ne 'Collapsed') {
            $StepsPanel.Visibility = 'Collapsed'
            $script:StepSignature = $null
        }
        return
    }

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
    try { Read-VoiceState } catch { }
    try { Read-NewEvents } catch { }
    try { Merge-SessionState } catch { }
    try { Complete-VoiceUiRequest } catch {
        Write-CompanionLog "voice UI request failed: $_"
    }
    # Both are cheap no-ops nearly every tick: the check is rate-limited to
    # hours, and completion only touches a handle that is usually null.
    try { Update-CheckForRelease } catch { }
    try { Complete-UpdateCheck } catch { }
    try {
        $showUpd = [bool]$script:UpdateAvail -and (Test-UpdatableInstall $PSScriptRoot $script:InstallDir)
        # Available, not Visible. A ToolStripItem's Visible getter reports false
        # whenever its menu is closed - which is nearly always - so comparing
        # against it would re-set the property on every single tick.
        if ($MenuUpdate.Available -ne $showUpd) { $MenuUpdate.Available = $showUpd }
        if ($showUpd) {
            $want = (T 'Install update') + " $($script:UpdateAvail)"
            if ($MenuUpdate.Text -ne $want) { $MenuUpdate.Text = $want }
        }
    } catch { }

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
    $voiceActive = [bool]($script:VoiceState -and $script:VoiceState.active)
    $voiceVisible = $voiceActive -or (
        $script:VoiceEnabled -and [datetime]::UtcNow -lt $script:VoiceActivationUntil
    )
    $ageSec = ([datetime]::UtcNow - $State.LastEventUtc).TotalSeconds
    $running = ($State.Steps | Where-Object { -not $_.Done } | Measure-Object).Count -gt 0
    $isActive = $hasPending -or $hasAsk -or $running -or ($State.TurnActive) -or ($Sessions.Count -gt 0 -and $ageSec -le [double]$Config.activeWindowSeconds)

    # A question parks the turn just like an approval does, so neither counts as
    # "busy" - the mascot should be waiting, not typing.
    $voiceBusy = $voiceActive -and $script:VoiceState.stage -in @('processing', 'speaking')
    $script:Busy = $voiceBusy -or ((-not $hasPending) -and (-not $hasAsk) -and ($State.TurnActive -or $running -or ($ageSec -le 6)))
    $script:Pending = $hasPending
    $script:Asking  = $hasAsk

    # The ??button only dismisses the CURRENT burst. Re-show automatically when a
    # new approval or question arrives, or when a fresh working turn begins
    # (idle -> busy edge), so closing it once doesn't mute the companion forever.
    if ($script:Hidden -and ($hasPending -or $hasAsk)) { $script:Hidden = $false }
    if ($voiceActive -and -not $script:VoiceWasActive) { $script:Hidden = $false }
    $script:VoiceWasActive = $voiceActive
    if ($script:Hidden -and $script:Busy -and -not $script:PrevBusy) { $script:Hidden = $false }
    $script:PrevBusy = $script:Busy

    # pick the visual state: approval > question > working > idle, swap only on
    # change. Approval outranks a question because the toast can act on it.
    $desiredState = if ($hasPending) { 'alert' }
                    elseif ($hasAsk) { 'ask' }
                    elseif ($voiceVisible) { 'voice' }
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
            'voice'   { 'Voice control active' }
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
        $VoicePanel.Visibility = 'Collapsed'
        $first = $State.PendingPerms[ @($State.PendingPerms.Keys)[0] ]
        $HeaderText.Text = (T 'Approval needed') + $extra
        $PermTitle.Text  = [char]0x26A0 + ' ' + (T 'Permission requested')
        Set-FromLine $PermFrom $first
        # The card already names the asking conversation, and it need not be the
        # one the header was following a moment ago.
        $HeaderFrom.Visibility = 'Collapsed'
        Set-PermBody $first.summary $first.text ([bool]$first.mono)
        $AllowBtn.Visibility  = 'Visible'
        $DenyBtn.Visibility   = 'Visible'
        $AnswerBtn.Visibility = 'Collapsed'
        $PermPanel.Visibility = 'Visible'
        $Dot.Fill = '#FFB45309'
        # keep the yellow alert focused: hide the step list and narration
        $SayingText.Visibility = 'Collapsed'
        Hide-ActivityPanels
    }
    elseif ($hasAsk) {
        $VoicePanel.Visibility = 'Collapsed'
        $first = $State.PendingAsks[ @($State.PendingAsks.Keys)[0] ]
        $HeaderText.Text = (T 'Waiting on you') + $extra
        $PermTitle.Text  = [char]0x2753 + ' ' + (T 'The agent asked you a question')
        Set-FromLine $PermFrom $first
        $HeaderFrom.Visibility = 'Collapsed'
        # The question leads and the choices follow it, which is the same split
        # the permission card uses: what is being asked, then the specifics.
        $choices = ''
        if ($first.choices -and $first.choices.Count) {
            $choices = ($first.choices | ForEach-Object { [char]0x2022 + " $_" }) -join "`n"
        }
        Set-PermBody (Truncate $first.text 300) (Truncate $choices 1200) $false
        # The companion cannot answer for you, so it offers the one useful action.
        $AllowBtn.Visibility  = 'Collapsed'
        $DenyBtn.Visibility   = 'Collapsed'
        $AnswerBtn.Visibility = 'Visible'
        $PermPanel.Visibility = 'Visible'
        $Dot.Fill = '#FF0E7FB8'
        $SayingText.Visibility = 'Collapsed'
        Hide-ActivityPanels
    }
    elseif ($voiceVisible) {
        $PermPanel.Visibility = 'Collapsed'
        $HeaderText.Text = 'Scout Voice'
        $HeaderFrom.Visibility = 'Collapsed'
        $SayingText.Visibility = 'Collapsed'
        $ElapsedText.Visibility = 'Collapsed'
        Hide-ActivityPanels
        $VoiceStatus.Text = if ($script:VoiceState) {
            [string]$script:VoiceState.status
        } else {
            'Preparing the voice engine'
        }
        $command = if ($script:VoiceState) { [string]$script:VoiceState.command } else { '' }
        $answer = if ($script:VoiceState) { [string]$script:VoiceState.answer } else { '' }
        $VoiceCommand.Text = if ($command) { "You  $command" } else { 'Say a command...' }
        $VoiceAnswer.Text = if ($answer) { "Scout  $answer" } else { '' }
        $VoiceAnswer.Visibility = if ($answer) { 'Visible' } else { 'Collapsed' }
        $VoicePanel.Visibility = 'Visible'
        $Dot.Fill = '#FFFD8EA1'
    }
    else {
        $VoicePanel.Visibility = 'Collapsed'
        $PermPanel.Visibility = 'Collapsed'
        $many = $Sessions.Count -gt 1
        if (-not $agentRunning) { $HeaderText.Text = T 'Agent not detected'; $Dot.Fill = '#FF8A93A6' }
        elseif ($script:Busy)   { $HeaderText.Text = T 'Working hard...';    $Dot.Fill = '#FF4ADE80' }
        else                    { $HeaderText.Text = T 'Idle';               $Dot.Fill = '#FF8A93A6' }
        # How many are being followed, once that is more than one. Without it
        # the list below has no heading and reads as one session's steps.
        if ($many) { $HeaderText.Text = "$($HeaderText.Text)  ($($Sessions.Count))" }

        # How long this turn has been going. Only for a single session: with
        # several, "how long" has no single answer and each row carries its own
        # state already.
        $elapsed = ''
        if (-not $many -and $script:Busy -and $State.SessionDir) {
            # SessionDir, not Primary.Dir - Primary is a display shape holding a
            # label and a title, and has no directory on it.
            $rec = $Sessions[$State.SessionDir]
            if ($rec) { $elapsed = Get-ElapsedLabel $rec.TurnStartUtc ([datetime]::UtcNow) }
        }
        if ($elapsed) {
            if ($ElapsedText.Text -ne $elapsed) { $ElapsedText.Text = $elapsed }
            if ($ElapsedText.Visibility -ne 'Visible') { $ElapsedText.Visibility = 'Visible' }
        } elseif ($ElapsedText.Visibility -ne 'Collapsed') {
            $ElapsedText.Visibility = 'Collapsed'
        }

        # The conversation's name now lives on its own session row (single and
        # multi alike), so the header no longer repeats it - the header line is
        # the state, the row is the name.
        $HeaderFrom.Visibility = 'Collapsed'

        # Narration is folded away for both single and multi now: the session row
        # names the conversation and the step list (single) or activity line
        # (multi) says what it is doing, so a separate italic sentence above them
        # was the one thing that made a single session look unlike several.
        $SayingText.Visibility = 'Collapsed'

        Render-Steps
    }

    # A second launch asks the running copy to show itself rather than starting
    # a rival. Checked here because the poll loop is the one thing guaranteed to
    # be running; WaitOne(0) does not block and costs nothing when unsignalled.
    if ($script:ShowRequest) {
        try {
            if ($script:ShowRequest.WaitOne(0)) {
                $script:Pinned = $true
                $script:Hidden = $false
            }
        } catch { }
    }

    # visibility policy
    $greeting = [datetime]::UtcNow -lt $script:GreetUntil
    $shouldShow = Get-ShouldShow -HasPending $hasPending -HasAsk $hasAsk `
        -IsActive $isActive -AgentRunning $agentRunning -IsMinimized $isMinimized `
        -IsForeground $isForeground -Hidden $script:Hidden -Pinned $script:Pinned `
        -Greeting $greeting
    if ($voiceVisible) { $shouldShow = $true }

    # A long turn just finished. Worth saying only when it is not already on
    # screen: a balloon telling you what the visible toast is telling you is
    # noise, and so is one for a window you are looking at.
    if ($script:LongTurn) {
        $t = $script:LongTurn
        $script:LongTurn = $null
        if (Test-ShouldNotifyFinish $isForeground $shouldShow $Window.IsVisible) {
            # Naming the conversation is the whole point when several are
            # running. Where there is no name yet, say what finished rather than
            # a bare product name that answers nothing.
            $body = if ($t.Name) { "{0} - {1}" -f (Truncate $t.Name 60), (Format-Idle ([int]$t.Secs)) }
                    else { "{0} {1}" -f (T 'Ran for'), (Format-Idle ([int]$t.Secs)) }
            Show-TrayBalloon (T 'Finished') $body
        }
    }

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
Import-TitleStore
Sync-Sessions
$script:SessionScanUtc = [datetime]::UtcNow
Merge-SessionState

# Draw the configured mascot. This has to run after the mascot functions are
# defined, so it deliberately lives here rather than next to Set-Theme.
Set-Mascot ([string]$Config.mascot)
if ([bool]$Config.voiceCommandEnabled) { [void](Start-VoiceBridge) }
Sync-VoiceControls

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
    try { Save-PendingPosition } catch { }
    try { Save-PendingVoiceSensitivity } catch { }
    try { Save-PendingNoiseSensitivity } catch { }
    try { Stop-VoiceEnrollment } catch { }
    try { Stop-VoiceBridge } catch { }
    try { $Tray.Visible = $false; $Tray.Dispose() } catch { }
    try { if ($script:InstanceMutex) { $script:InstanceMutex.ReleaseMutex(); $script:InstanceMutex.Dispose(); $script:InstanceMutex = $null } } catch { }
    try { if ($script:ShowRequest) { $script:ShowRequest.Dispose(); $script:ShowRequest = $null } } catch { }
})
$app = New-Object System.Windows.Application
# The toast is the app: closing it exits, and any settings window opened from
# the tray is free to come and go without taking the companion down with it.
$app.ShutdownMode = [System.Windows.ShutdownMode]::OnMainWindowClose
$app.Run($Window) | Out-Null
