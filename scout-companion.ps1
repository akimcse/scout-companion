<#
.SYNOPSIS
    Scout Companion - a floating overlay for the Microsoft Scout / OpenClaw desktop agent.

.DESCRIPTION
    Shows a small always-on-top toast in the corner of your screen whenever the agent
    is working in the background (window minimized or not focused). It streams the
    agent's live progress and, when the agent asks for a permission ("Allow"), lets you
    approve or deny it with a single click - without switching back to the agent window.

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
        public static extern bool SetForegroundWindow(System.IntPtr hWnd);

        [System.Runtime.InteropServices.DllImport("user32.dll")]
        public static extern bool ShowWindow(System.IntPtr hWnd, int nCmdShow);

        [System.Runtime.InteropServices.DllImport("user32.dll")]
        public static extern System.IntPtr SendMessage(System.IntPtr hWnd, uint Msg, System.IntPtr wParam, System.IntPtr lParam);
'@
}

# ---------------------------------------------------------------------------
# Configuration (with sane defaults; overridable via config.json or env var).
# ---------------------------------------------------------------------------
$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path

$Config = [ordered]@{
    # Agent home folder. Both Scout and OpenClaw use ~/.copilot today.
    home          = $null
    # Candidate process names of the desktop agent window (matched case-insensitively).
    processNames  = @('Microsoft Scout', 'OpenClaw', 'Claw', 'Copilot')
    # Window-name candidates used as a secondary match if process name misses.
    windowHints   = @('Scout', 'Clawpilot', 'OpenClaw', 'Copilot')
    # Button labels to treat as "approve" / "deny" when auto-clicking the agent prompt.
    allowLabels   = @('Allow', 'Always allow', 'Allow once', 'Approve', 'Accept', 'Yes', 'Continue')
    denyLabels    = @('Deny', 'Reject', 'Decline', 'Block', 'No', 'Cancel')
    # Consider the session "active" if events.jsonl changed within this many seconds.
    activeWindowSeconds = 150
    # Polling interval for the event stream / visibility, in milliseconds.
    pollIntervalMs      = 700
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

if ($env:SCOUT_COMPANION_HOME) { $Config.home = $env:SCOUT_COMPANION_HOME }
if (-not $Config.home) { $Config.home = Join-Path $env:USERPROFILE '.copilot' }

$SessionRoot = Join-Path $Config.home 'session-state'

# ---------------------------------------------------------------------------
# Shared mutable state (single-threaded, driven by the UI dispatcher timer).
# ---------------------------------------------------------------------------
$State = [pscustomobject]@{
    SessionDir      = $null
    EventsPath      = $null
    Offset          = [long]0
    Activity        = 'Waiting for the agent to start working...'
    ToolName        = $null
    TurnActive      = $false
    LastEventUtc    = [datetime]::MinValue
    PendingPerms    = [ordered]@{}   # requestId -> @{ text; kind; toolCallId }
    AgentHwnd       = [IntPtr]::Zero
    AgentProcId     = 0
}

# ---------------------------------------------------------------------------
# Helpers.
# ---------------------------------------------------------------------------

function Get-AgentWindow {
    # Returns @{ Hwnd; Pid } for the agent's main window, or $null.
    $procs = Get-Process | Where-Object { $_.MainWindowHandle -ne 0 -and $_.MainWindowTitle }
    foreach ($name in $Config.processNames) {
        $p = $procs | Where-Object { $_.ProcessName -ieq $name -or $_.ProcessName -like "*$name*" } | Select-Object -First 1
        if ($p) { return @{ Hwnd = $p.MainWindowHandle; Pid = $p.Id } }
    }
    foreach ($hint in $Config.windowHints) {
        $p = $procs | Where-Object { $_.MainWindowTitle -like "*$hint*" } | Select-Object -First 1
        if ($p) { return @{ Hwnd = $p.MainWindowHandle; Pid = $p.Id } }
    }
    return $null
}

function Find-ActiveSession {
    # Pick the session whose events.jsonl was most recently written.
    # Prefer sessions that currently hold an inuse.*.lock file.
    if (-not (Test-Path $SessionRoot)) { return $null }

    $candidates = Get-ChildItem $SessionRoot -Directory -ErrorAction SilentlyContinue | ForEach-Object {
        $ev = Join-Path $_.FullName 'events.jsonl'
        if (Test-Path $ev) {
            $locked = (Get-ChildItem $_.FullName -Filter 'inuse.*.lock' -ErrorAction SilentlyContinue | Measure-Object).Count -gt 0
            [pscustomobject]@{
                Dir     = $_.FullName
                Events  = $ev
                Mtime   = (Get-Item $ev).LastWriteTimeUtc
                Locked  = $locked
            }
        }
    }
    if (-not $candidates) { return $null }

    $best = $candidates | Sort-Object @{ Expression = 'Locked'; Descending = $true }, @{ Expression = 'Mtime'; Descending = $true } | Select-Object -First 1
    return $best
}

function Read-NewEvents {
    # Reads newly appended JSON lines from the active session's events.jsonl.
    $sess = Find-ActiveSession
    if (-not $sess) { return }

    if ($State.EventsPath -ne $sess.Events) {
        # Switched to a different/newer session: jump to its end so we only
        # react to fresh activity, then reset per-session state.
        $State.SessionDir = $sess.Dir
        $State.EventsPath = $sess.Events
        $State.Offset     = (Get-Item $sess.Events).Length
        $State.PendingPerms = [ordered]@{}
        $State.TurnActive = $false
        return
    }

    $len = (Get-Item $sess.Events).Length
    if ($len -lt $State.Offset) { $State.Offset = 0 }   # file rotated/truncated
    if ($len -eq $State.Offset) { return }

    $fs = [System.IO.File]::Open($sess.Events, 'Open', 'Read', 'ReadWrite')
    try {
        $fs.Seek($State.Offset, 'Begin') | Out-Null
        $sr = New-Object System.IO.StreamReader($fs)
        $chunk = $sr.ReadToEnd()
        $State.Offset = $fs.Position
    } finally {
        $fs.Dispose()
    }

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
        'assistant.turn_start'    { $State.TurnActive = $true }
        'assistant.turn_end'      { $State.TurnActive = $false; $State.Activity = 'Done. Waiting for next step...'; $State.ToolName = $null }
        'assistant.message' {
            $txt = $null
            if ($evt.data.text) { $txt = $evt.data.text }
            elseif ($evt.data.message) { $txt = $evt.data.message }
            if ($txt) { $State.Activity = (Truncate $txt 240); $State.ToolName = $null }
        }
        'tool.execution_start' {
            $tn = $evt.data.toolName; if (-not $tn) { $tn = $evt.data.name }
            $State.ToolName = $tn
            if ($tn) { $State.Activity = "Running $tn" }
        }
        'tool.execution_complete' {
            $tn = $evt.data.toolName; if (-not $tn) { $tn = $evt.data.name }
            if ($tn) { $State.Activity = "Finished $tn" }
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
        'external_tool.requested' {
            # treated like a soft pending; show as activity only
            $State.Activity = 'Waiting on an external tool...'
        }
    }
}

function Truncate([string]$s, [int]$n) {
    if ($null -eq $s) { return '' }
    $s = $s -replace '\s+', ' '
    if ($s.Length -le $n) { return $s }
    return $s.Substring(0, $n) + '...'
}

function Wake-AgentA11y([IntPtr]$hwnd) {
    # WM_GETOBJECT with UiaRootObjectId (-25) nudges Chromium/Electron to expose
    # its accessibility tree so UI Automation can see (and invoke) the buttons.
    if ($hwnd -eq [IntPtr]::Zero) { return }
    [void][ScoutNative]::SendMessage($hwnd, 0x003D, [IntPtr]::Zero, [IntPtr](-25))
}

function Invoke-AgentButton([string[]]$labels) {
    # Best-effort: find a visible, enabled button in the agent window whose name
    # matches one of $labels and invoke it via UI Automation. Returns $true on click.
    $win = Get-AgentWindow
    if (-not $win) { return $false }
    Wake-AgentA11y $win.Hwnd
    Start-Sleep -Milliseconds 350

    try {
        $root = [System.Windows.Automation.AutomationElement]::FromHandle($win.Hwnd)
    } catch { return $false }
    if (-not $root) { return $false }

    $btnCond = New-Object System.Windows.Automation.PropertyCondition(
        [System.Windows.Automation.AutomationElement]::ControlTypeProperty,
        [System.Windows.Automation.ControlType]::Button)
    $buttons = $root.FindAll([System.Windows.Automation.TreeScope]::Descendants, $btnCond)

    foreach ($label in $labels) {
        foreach ($b in $buttons) {
            $n = $b.Current.Name
            if (-not $n) { continue }
            if ($n.Trim().ToLower() -eq $label.ToLower() -or $n -ieq $label) {
                if ($b.Current.IsOffscreen) { continue }
                try {
                    $ip = $b.GetCurrentPattern([System.Windows.Automation.InvokePattern]::Pattern)
                    $ip.Invoke()
                    return $true
                } catch { }
            }
        }
    }
    # Looser contains-match as a fallback.
    foreach ($label in $labels) {
        foreach ($b in $buttons) {
            $n = $b.Current.Name
            if ($n -and ($n -ilike "*$label*") -and -not $b.Current.IsOffscreen) {
                try {
                    $ip = $b.GetCurrentPattern([System.Windows.Automation.InvokePattern]::Pattern)
                    $ip.Invoke()
                    return $true
                } catch { }
            }
        }
    }
    return $false
}

function Focus-Agent {
    $win = Get-AgentWindow
    if (-not $win) { return }
    [void][ScoutNative]::ShowWindow($win.Hwnd, 9)   # SW_RESTORE
    [void][ScoutNative]::SetForegroundWindow($win.Hwnd)
}

# ---------------------------------------------------------------------------
# WPF overlay UI.
# ---------------------------------------------------------------------------
[xml]$xaml = @'
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
        xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        Title="Scout Companion"
        Width="360" SizeToContent="Height"
        WindowStyle="None" AllowsTransparency="True" Background="Transparent"
        Topmost="True" ShowInTaskbar="False" ResizeMode="NoResize">
  <Border CornerRadius="12" Background="#FF1B1F2A" BorderBrush="#FF3A4358" BorderThickness="1" Padding="14">
    <Border.Effect><DropShadowEffect BlurRadius="18" ShadowDepth="3" Opacity="0.5" Color="#000000"/></Border.Effect>
    <StackPanel>
      <DockPanel LastChildFill="True">
        <Ellipse x:Name="Dot" Width="9" Height="9" Fill="#FF4ADE80" VerticalAlignment="Center" Margin="0,0,8,0"/>
        <TextBlock x:Name="HeaderText" Text="Scout is working" Foreground="#FFE6EAF2" FontSize="13" FontWeight="SemiBold" VerticalAlignment="Center"/>
        <Button x:Name="CloseBtn" Content="&#x2715;" DockPanel.Dock="Right" Width="22" Height="22"
                Background="Transparent" Foreground="#FF8A93A6" BorderThickness="0" FontSize="12" Cursor="Hand"/>
        <Button x:Name="OpenBtn" Content="Open" DockPanel.Dock="Right" Height="22" Margin="0,0,6,0"
                Background="#FF2A3142" Foreground="#FFB9C2D6" BorderThickness="0" Padding="8,0" FontSize="11" Cursor="Hand"/>
      </DockPanel>

      <TextBlock x:Name="ActivityText" Margin="0,10,0,0" Text="..." Foreground="#FFB9C2D6"
                 FontSize="12" TextWrapping="Wrap" MaxHeight="80" TextTrimming="CharacterEllipsis"/>

      <Border x:Name="PermPanel" Margin="0,12,0,0" Padding="10" CornerRadius="8"
              Background="#FF2A2030" BorderBrush="#FFB4843C" BorderThickness="1" Visibility="Collapsed">
        <StackPanel>
          <TextBlock Text="Permission requested" Foreground="#FFF2C879" FontWeight="SemiBold" FontSize="12"/>
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
</Window>
'@

$reader = New-Object System.Xml.XmlNodeReader $xaml
$Window = [Windows.Markup.XamlReader]::Load($reader)

$HeaderText   = $Window.FindName('HeaderText')
$ActivityText = $Window.FindName('ActivityText')
$Dot          = $Window.FindName('Dot')
$PermPanel    = $Window.FindName('PermPanel')
$PermText     = $Window.FindName('PermText')
$AllowBtn     = $Window.FindName('AllowBtn')
$DenyBtn      = $Window.FindName('DenyBtn')
$OpenBtn      = $Window.FindName('OpenBtn')
$CloseBtn     = $Window.FindName('CloseBtn')

# Position bottom-right above the taskbar.
$Window.Add_Loaded({
    $wa = [System.Windows.SystemParameters]::WorkArea
    $Window.Left = $wa.Right - $Window.ActualWidth - 16
    $Window.Top  = $wa.Bottom - $Window.ActualHeight - 16
})

$Window.Add_SizeChanged({
    $wa = [System.Windows.SystemParameters]::WorkArea
    $Window.Left = $wa.Right - $Window.ActualWidth - 16
    $Window.Top  = $wa.Bottom - $Window.ActualHeight - 16
})

# Drag to reposition.
$Window.Add_MouseLeftButtonDown({ try { $Window.DragMove() } catch { } })

$script:Hidden = $false   # user manually dismissed for the current burst

$AllowBtn.Add_Click({
    $ok = Invoke-AgentButton $Config.allowLabels
    if ($ok) {
        # optimistic: clear pending so the panel hides immediately
        foreach ($k in @($State.PendingPerms.Keys)) { $State.PendingPerms.Remove($k) }
    } else {
        Focus-Agent
    }
})

$DenyBtn.Add_Click({
    $ok = Invoke-AgentButton $Config.denyLabels
    if ($ok) {
        foreach ($k in @($State.PendingPerms.Keys)) { $State.PendingPerms.Remove($k) }
    } else {
        Focus-Agent
    }
})

$OpenBtn.Add_Click({ Focus-Agent })
$CloseBtn.Add_Click({ $script:Hidden = $true; $Window.Hide() })

# ---------------------------------------------------------------------------
# Main loop: poll events + decide visibility.
# ---------------------------------------------------------------------------
$timer = New-Object System.Windows.Threading.DispatcherTimer
$timer.Interval = [TimeSpan]::FromMilliseconds([int]$Config.pollIntervalMs)
$timer.Add_Tick({
    try { Read-NewEvents } catch { }

    $win = Get-AgentWindow
    $agentRunning = $null -ne $win
    $fg = [ScoutNative]::GetForegroundWindow()
    $isForeground = $agentRunning -and ($fg -eq $win.Hwnd)
    $isMinimized  = $agentRunning -and [ScoutNative]::IsIconic($win.Hwnd)

    $hasPending = $State.PendingPerms.Count -gt 0
    $ageSec = ([datetime]::UtcNow - $State.LastEventUtc).TotalSeconds
    $isActive = $hasPending -or ($State.EventsPath -and $ageSec -le [double]$Config.activeWindowSeconds)

    # Re-arm after a manual dismiss when something new demands attention.
    if ($script:Hidden -and $hasPending) { $script:Hidden = $false }

    # Update content.
    if ($hasPending) {
        $first = $State.PendingPerms[ @($State.PendingPerms.Keys)[0] ]
        $extra = if ($State.PendingPerms.Count -gt 1) { " (+$($State.PendingPerms.Count - 1) more)" } else { '' }
        $HeaderText.Text = "Approval needed$extra"
        $PermText.Text = $first.text
        $PermPanel.Visibility = 'Visible'
        $Dot.Fill = '#FFF2C879'
    } else {
        $PermPanel.Visibility = 'Collapsed'
        if (-not $agentRunning) {
            $HeaderText.Text = 'Agent not detected'
            $Dot.Fill = '#FF8A93A6'
        } elseif ($State.TurnActive -or $isActive) {
            $HeaderText.Text = 'Working in the background'
            $Dot.Fill = '#FF4ADE80'
        } else {
            $HeaderText.Text = 'Idle'
            $Dot.Fill = '#FF8A93A6'
        }
    }
    $ActivityText.Text = $State.Activity

    # Visibility policy:
    #   - Always surface a pending approval.
    #   - Otherwise show only when the agent is active AND its window is
    #     minimized or not in the foreground (i.e. you've looked away).
    $shouldShow = $false
    if ($hasPending) {
        $shouldShow = $true
    } elseif ($isActive -and $agentRunning -and ($isMinimized -or -not $isForeground)) {
        $shouldShow = $true
    }

    if ($script:Hidden) { $shouldShow = $false }

    if ($shouldShow) {
        if (-not $Window.IsVisible) { $Window.Show() }
        $Window.Topmost = $true
    } else {
        if ($Window.IsVisible) { $Window.Hide() }
    }
})

# Prime state on first run (jump to current end of the active session).
$initial = Find-ActiveSession
if ($initial) {
    $State.SessionDir = $initial.Dir
    $State.EventsPath = $initial.Events
    $State.Offset     = (Get-Item $initial.Events).Length
    $State.LastEventUtc = (Get-Item $initial.Events).LastWriteTimeUtc
}

$timer.Start()

# Run hidden until the policy decides to show the toast.
$Window.Visibility = 'Hidden'
$app = New-Object System.Windows.Application
$app.Run($Window) | Out-Null
