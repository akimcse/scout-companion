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
    home          = $null
    processNames  = @('Microsoft Scout', 'OpenClaw', 'Claw', 'Copilot')
    windowHints   = @('Scout', 'Clawpilot', 'OpenClaw', 'Copilot')
    # Order matters: first match is clicked, so the safest one-time "Allow" wins.
    allowLabels   = @('Allow', 'Allow for session', 'Allow everywhere', 'Always allow', 'Allow once', 'Approve', 'Accept', 'Continue', 'Yes')
    denyLabels    = @('Deny', 'Reject', 'Decline', 'Block', 'Cancel', 'No')
    activeWindowSeconds = 150
    pollIntervalMs      = 700
    maxSteps            = 4
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
    if (-not (Test-Path $SessionRoot)) { return $null }
    $candidates = Get-ChildItem $SessionRoot -Directory -ErrorAction SilentlyContinue | ForEach-Object {
        $ev = Join-Path $_.FullName 'events.jsonl'
        if (Test-Path $ev) {
            $locked = (Get-ChildItem $_.FullName -Filter 'inuse.*.lock' -ErrorAction SilentlyContinue | Measure-Object).Count -gt 0
            [pscustomobject]@{ Dir = $_.FullName; Events = $ev; Mtime = (Get-Item $ev).LastWriteTimeUtc; Locked = $locked }
        }
    }
    if (-not $candidates) { return $null }
    return $candidates | Sort-Object @{ Expression = 'Locked'; Descending = $true }, @{ Expression = 'Mtime'; Descending = $true } | Select-Object -First 1
}

function Read-NewEvents {
    $sess = Find-ActiveSession
    if (-not $sess) { return }

    if ($State.EventsPath -ne $sess.Events) {
        $State.SessionDir = $sess.Dir
        $State.EventsPath = $sess.Events
        $State.Offset     = (Get-Item $sess.Events).Length
        $State.PendingPerms = [ordered]@{}
        $State.Steps.Clear()
        $State.Saying = $null
        $State.TurnActive = $false
        return
    }

    $len = (Get-Item $sess.Events).Length
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
  <Border x:Name="RootBorder" CornerRadius="14" Background="#FF1B1F2A" BorderBrush="#FF3A4358" BorderThickness="1" Padding="14">
    <Border.Effect><DropShadowEffect x:Name="RootGlow" BlurRadius="20" ShadowDepth="3" Opacity="0.55" Color="#000000"/></Border.Effect>
    <StackPanel>
      <DockPanel LastChildFill="True">

        <!-- Quokka mascot -->
        <Canvas x:Name="Quokka" Width="58" Height="60" DockPanel.Dock="Left" Margin="0,0,12,0"
                RenderTransformOrigin="0.5,0.6" VerticalAlignment="Center">
          <Canvas.RenderTransform>
            <TransformGroup>
              <ScaleTransform x:Name="BodyS" ScaleX="1" ScaleY="1"/>
              <TranslateTransform x:Name="BodyT"/>
            </TransformGroup>
          </Canvas.RenderTransform>
          <!-- ears -->
          <Ellipse Canvas.Left="8"  Canvas.Top="1"  Width="16" Height="18" Fill="#FFB87A50"/>
          <Ellipse Canvas.Left="32" Canvas.Top="1"  Width="16" Height="18" Fill="#FFB87A50"/>
          <Ellipse Canvas.Left="12" Canvas.Top="5"  Width="8"  Height="10" Fill="#FFE3A6A6"/>
          <Ellipse Canvas.Left="36" Canvas.Top="5"  Width="8"  Height="10" Fill="#FFE3A6A6"/>
          <!-- head/body -->
          <Ellipse Canvas.Left="6"  Canvas.Top="9"  Width="44" Height="43" Fill="#FFC58A5E"/>
          <Ellipse Canvas.Left="15" Canvas.Top="25" Width="26" Height="25" Fill="#FFF0DBBC"/>
          <!-- cheeks -->
          <Ellipse Canvas.Left="11" Canvas.Top="30" Width="9"  Height="7"  Fill="#66F2A0A0"/>
          <Ellipse Canvas.Left="36" Canvas.Top="30" Width="9"  Height="7"  Fill="#66F2A0A0"/>
          <!-- glasses temples (behind) -->
          <Line X1="8"  Y1="21" X2="14" Y2="26" Stroke="#FF2B2B2B" StrokeThickness="1.8"/>
          <Line X1="48" Y1="21" X2="42" Y2="26" Stroke="#FF2B2B2B" StrokeThickness="1.8"/>
          <!-- big round lenses -->
          <Ellipse Canvas.Left="13" Canvas.Top="20" Width="15" Height="15" Fill="#0FEAF7FF"/>
          <Ellipse Canvas.Left="28" Canvas.Top="20" Width="15" Height="15" Fill="#0FEAF7FF"/>
          <!-- cute big eyes inside the lenses -->
          <Ellipse Canvas.Left="17" Canvas.Top="23" Width="7" Height="10" Fill="#FF2B1A12"/>
          <Ellipse Canvas.Left="32" Canvas.Top="23" Width="7" Height="10" Fill="#FF2B1A12"/>
          <Ellipse Canvas.Left="18.4" Canvas.Top="24.6" Width="3.2" Height="3.2" Fill="#FFFFFFFF"/>
          <Ellipse Canvas.Left="33.4" Canvas.Top="24.6" Width="3.2" Height="3.2" Fill="#FFFFFFFF"/>
          <!-- bold round frames on top -->
          <Ellipse Canvas.Left="13" Canvas.Top="20" Width="15" Height="15" Stroke="#FF242424" StrokeThickness="2.2" Fill="Transparent"/>
          <Ellipse Canvas.Left="28" Canvas.Top="20" Width="15" Height="15" Stroke="#FF242424" StrokeThickness="2.2" Fill="Transparent"/>
          <Line X1="26.5" Y1="25.5" X2="29.5" Y2="25.5" Stroke="#FF242424" StrokeThickness="2.2"/>
          <!-- lens shine -->
          <Ellipse Canvas.Left="15" Canvas.Top="22" Width="4" Height="3" Fill="#66FFFFFF"/>
          <Ellipse Canvas.Left="30" Canvas.Top="22" Width="4" Height="3" Fill="#66FFFFFF"/>
          <!-- nose + signature smile -->
          <Ellipse Canvas.Left="24" Canvas.Top="30" Width="8"  Height="5"  Fill="#FF5A3A2A"/>
          <Path Stroke="#FF5A3A2A" StrokeThickness="2" StrokeStartLineCap="Round" StrokeEndLineCap="Round"
                Data="M20,35 Q28,42 36,35"/>
          <!-- laptop: screen lid (seen from behind) -->
          <Border Canvas.Left="17" Canvas.Top="40" Width="24" Height="13" CornerRadius="2" Background="#FF3A4257"/>
          <Border Canvas.Left="19" Canvas.Top="42" Width="20" Height="9"  CornerRadius="1" Background="#FF5C6B86"/>
          <Ellipse Canvas.Left="27" Canvas.Top="45" Width="4" Height="4" Fill="#FF9DE7FF"/>
          <!-- laptop: keyboard base -->
          <Polygon Points="11,52 47,52 53,60 5,60" Fill="#FFC9D0DC"/>
          <Polygon Points="14,53 44,53 48,58 10,58" Fill="#FFA9B3C4"/>
          <!-- paws on the keyboard (animated typing) -->
          <Ellipse Canvas.Left="14" Canvas.Top="49" Width="11" Height="8" Fill="#FFB87A50">
            <Ellipse.RenderTransform><TranslateTransform x:Name="LeftPawT"/></Ellipse.RenderTransform>
          </Ellipse>
          <Ellipse Canvas.Left="32" Canvas.Top="49" Width="11" Height="8" Fill="#FFB87A50">
            <Ellipse.RenderTransform><TranslateTransform x:Name="RightPawT"/></Ellipse.RenderTransform>
          </Ellipse>
        </Canvas>

        <Button x:Name="CloseBtn" Content="&#x2715;" DockPanel.Dock="Right" Width="22" Height="22"
                Background="Transparent" Foreground="#FF8A93A6" BorderThickness="0" FontSize="12"
                VerticalAlignment="Top" Cursor="Hand"/>
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
$BodyT        = $Window.FindName('BodyT')
$BodyS        = $Window.FindName('BodyS')
$LeftPawT     = $Window.FindName('LeftPawT')
$RightPawT    = $Window.FindName('RightPawT')
$RootBorder   = $Window.FindName('RootBorder')
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

# ---------------------------------------------------------------------------
# Quokka animation: a dedicated fast timer drives the mascot frame-by-frame.
# Working => bobbing body + alternating "typing" paws. Idle => slow breathing.
# ---------------------------------------------------------------------------
$script:Phase = 0.0
$script:Busy  = $false
$anim = New-Object System.Windows.Threading.DispatcherTimer
$anim.Interval = [TimeSpan]::FromMilliseconds(50)
$anim.Add_Tick({
    if ($script:Pending) {
        # gentle attention pulse on the yellow alert glow
        $script:Phase += 0.20
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
        $script:Phase += 0.32
        $BodyT.Y     = [Math]::Sin($script:Phase * 2.0) * 1.6
        $BodyT.X     = [Math]::Sin($script:Phase) * 0.6
        $BodyS.ScaleX = 1.0
        $BodyS.ScaleY = 1.0
        $LeftPawT.Y  = -[Math]::Max(0, [Math]::Sin($script:Phase * 6.0)) * 2.4
        $RightPawT.Y = -[Math]::Max(0, [Math]::Sin($script:Phase * 6.0 + [Math]::PI)) * 2.4
    } else {
        $script:Phase += 0.04
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
    if ($State.Steps.Count -eq 0) { $StepsPanel.Visibility = 'Collapsed'; return }
    $sb = New-Object System.Text.StringBuilder
    foreach ($s in $State.Steps) {
        $mark = if ($s.Done) { [char]0x2713 } else { [char]0x25B8 }   # check / triangle
        [void]$sb.AppendLine("$mark  $($s.Text)")
    }
    $StepsText.Text = $sb.ToString().TrimEnd()
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

    $hasPending = $State.PendingPerms.Count -gt 0
    $ageSec = ([datetime]::UtcNow - $State.LastEventUtc).TotalSeconds
    $running = ($State.Steps | Where-Object { -not $_.Done } | Measure-Object).Count -gt 0
    $isActive = $hasPending -or $running -or ($State.TurnActive) -or ($State.EventsPath -and $ageSec -le [double]$Config.activeWindowSeconds)

    $script:Busy = (-not $hasPending) -and ($State.TurnActive -or $running -or ($ageSec -le 6))
    $script:Pending = $hasPending

    if ($script:Hidden -and $hasPending) { $script:Hidden = $false }

    # pick the visual state: approval > working > idle, swap only on change
    $desiredState = if ($hasPending) { 'alert' } elseif ($script:Busy -and $agentRunning) { 'working' } else { 'idle' }
    if ($desiredState -ne $script:ThemeState) { Set-Theme $desiredState; $script:ThemeState = $desiredState }

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

    if ($shouldShow) {
        if (-not $Window.IsVisible) { $Window.Show() }
        $Window.Topmost = $true
    } else {
        if ($Window.IsVisible) { $Window.Hide() }
    }
})

# prime to current end of the active session
$initial = Find-ActiveSession
if ($initial) {
    $State.SessionDir = $initial.Dir
    $State.EventsPath = $initial.Events
    $State.Offset     = (Get-Item $initial.Events).Length
    $State.LastEventUtc = (Get-Item $initial.Events).LastWriteTimeUtc
}

$anim.Start()
$timer.Start()

$Window.Visibility = 'Hidden'
$app = New-Object System.Windows.Application
$app.Run($Window) | Out-Null
