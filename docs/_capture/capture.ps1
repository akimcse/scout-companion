# Offline screenshot harness for docs. Loads the app's head (every function,
# the window, the mascot) up to just before the poll timer starts, then injects
# fake session state and renders each visual state to a PNG. No real Scout is
# read. Run with: powershell -STA -File capture.ps1
$ErrorActionPreference = 'Stop'
$here  = Split-Path -Parent $MyInvocation.MyCommand.Path
$root  = Split-Path -Parent (Split-Path -Parent $here)   # repo root
$outDir = Join-Path $root 'docs'

# The head is regenerated from the live script every run, so it never goes
# stale: everything up to (but not including) the poll timer's start - all
# functions, the window, the mascot builders. Copied to the repo root so its
# $ScriptDir (and thus lang/, config.json) resolves as the real script's would.
$appPath = Join-Path $root 'scout-companion.ps1'
$appLines = Get-Content $appPath
$cut = ($appLines | Select-String -Pattern '^\$timer = New-Object System\.Windows\.Threading\.DispatcherTimer').LineNumber
$headRun = Join-Path $root '_caphead.ps1'
$bytes = [System.Text.Encoding]::UTF8.GetPreamble() + [System.Text.Encoding]::UTF8.GetBytes(($appLines[0..($cut-2)] -join "`r`n"))
[System.IO.File]::WriteAllBytes($headRun, $bytes)
. $headRun

# English UI, to match the README.
$script:Lang = Import-Language 'en'

Add-Type -AssemblyName PresentationCore, PresentationFramework, WindowsBase

function New-FakeSession([string]$dir, [string]$subject, [object[]]$steps, [bool]$turnActive) {
    $rec = New-SessionRecord $dir (Join-Path $dir 'events.jsonl')
    $rec.Subject = $subject
    $rec.TurnActive = $turnActive
    $rec.TurnStartUtc = [datetime]::UtcNow.AddSeconds(-8)
    $rec.LastEventUtc = [datetime]::UtcNow
    foreach ($s in $steps) {
        [void]$rec.Steps.Add([pscustomobject]@{ Id=[guid]::NewGuid().ToString(); ReqId=$null; Text=$s.Text; Done=$s.Done })
    }
    $rec
}

function Reset-Toast {
    $PermPanel.Visibility     = 'Collapsed'
    $SessionsPanel.Visibility = 'Collapsed'
    $StepsPanel.Visibility    = 'Collapsed'
    $ElapsedText.Visibility   = 'Collapsed'
    $SayingText.Visibility    = 'Collapsed'
    $HeaderFrom.Visibility    = 'Collapsed'
    $script:SessionSignature  = $null
    $script:StepSignature     = $null
    foreach ($k in @($Sessions.Keys)) { $Sessions.Remove($k) }
    $State.Steps.Clear()
    foreach ($k in @($State.PendingPerms.Keys)) { $State.PendingPerms.Remove($k) }
    foreach ($k in @($State.PendingAsks.Keys))  { $State.PendingAsks.Remove($k) }
}

function Save-Toast([string]$name) {
    $Window.UpdateLayout()
    $Window.Dispatcher.Invoke([action]{}, [System.Windows.Threading.DispatcherPriority]::Render)
    Start-Sleep -Milliseconds 250
    $Window.UpdateLayout()
    $scale = 2
    $w = [int][Math]::Ceiling($Window.ActualWidth)
    $h = [int][Math]::Ceiling($Window.ActualHeight)
    $rtb = New-Object System.Windows.Media.Imaging.RenderTargetBitmap ($w*$scale), ($h*$scale), (96*$scale), (96*$scale), ([System.Windows.Media.PixelFormats]::Pbgra32)
    $rtb.Render($Window)
    $enc = New-Object System.Windows.Media.Imaging.PngBitmapEncoder
    $enc.Frames.Add([System.Windows.Media.Imaging.BitmapFrame]::Create($rtb))
    $path = Join-Path $outDir $name
    $fs = [System.IO.File]::Open($path, 'Create')
    $enc.Save($fs); $fs.Close()
    Write-Host "saved $name  (${w}x${h} @${scale}x)"
}

# The window must be shown once for AllowsTransparency layout to settle; parked
# far off-screen so it never flashes in front of anything.
$Window.Opacity = 1
$Window.Left = -3000; $Window.Top = 200
$Window.Show()
Set-Mascot 'quokka'

$steps1 = @(
    [pscustomobject]@{ Text='Reading config file'; Done=$true },
    [pscustomobject]@{ Text='Running: npm run build'; Done=$true },
    [pscustomobject]@{ Text='Running tests'; Done=$false }
)

# --- working, single session ---
Reset-Toast
Set-Theme 'working'
$rec = New-FakeSession 'C:\s\11aa22bb' 'Website redesign' $steps1 $true
$Sessions['C:\s\11aa22bb'] = $rec
foreach ($s in $steps1) { [void]$State.Steps.Add([pscustomobject]@{ Text=$s.Text; Done=$s.Done }) }
$script:Busy = $true
$HeaderText.Text = (T 'Working hard...')
$Dot.Fill = (New-Object System.Windows.Media.BrushConverter).ConvertFromString('#FF4ADE80')
Render-Steps
Save-Toast 'state-working.png'

# --- approval ---
Reset-Toast
Set-Theme 'alert'
$rec = New-FakeSession 'C:\s\11aa22bb' 'Website redesign' @() $false
$Sessions['C:\s\11aa22bb'] = $rec
$item = [pscustomobject]@{ text="Allow running 'npm publish'?"; Dir='C:\s\11aa22bb'; Label=$rec.Subject; ChatTitle=$null; Subject=$rec.Subject }
$State.PendingPerms['p1'] = $item
$HeaderText.Text = (T 'Approval needed')
$PermTitle.Text  = [char]0x26A0 + ' ' + (T 'Permission requested')
Set-FromLine $PermFrom $item
$PermText.Text = $item.text
$AllowBtn.Visibility='Visible'; $DenyBtn.Visibility='Visible'; $AnswerBtn.Visibility='Collapsed'
$PermPanel.Visibility='Visible'
$Dot.Fill=(New-Object System.Windows.Media.BrushConverter).ConvertFromString('#FFB45309')
Hide-ActivityPanels
Save-Toast 'state-approval.png'

# --- question ---
Reset-Toast
Set-Theme 'ask'
$rec = New-FakeSession 'C:\s\11aa22bb' 'Website redesign' @() $false
$Sessions['C:\s\11aa22bb'] = $rec
$q = [pscustomobject]@{ text="How should I proceed?`n" + [char]0x2022 + " Proceed automatically`n" + [char]0x2022 + " Let me review first"; Dir='C:\s\11aa22bb'; Label=$rec.Subject; ChatTitle=$null; Subject=$rec.Subject; choices=@() }
$State.PendingAsks['a1'] = $q
$HeaderText.Text = (T 'Waiting on you')
$PermTitle.Text  = [char]0x2753 + ' ' + (T 'The agent asked you a question')
Set-FromLine $PermFrom $q
$PermText.Text = $q.text
$AllowBtn.Visibility='Collapsed'; $DenyBtn.Visibility='Collapsed'; $AnswerBtn.Visibility='Visible'
$PermPanel.Visibility='Visible'
$Dot.Fill=(New-Object System.Windows.Media.BrushConverter).ConvertFromString('#FF0E7FB8')
Hide-ActivityPanels
Save-Toast 'state-question.png'

# --- idle ---
Reset-Toast
Set-Theme 'idle'
$rec = New-FakeSession 'C:\s\11aa22bb' 'Website redesign' @(
    [pscustomobject]@{ Text='Running: npm run build'; Done=$true }) $false
$rec.LastEventUtc = [datetime]::UtcNow.AddSeconds(-180)
$Sessions['C:\s\11aa22bb'] = $rec
$script:Busy = $false
$HeaderText.Text = (T 'Idle')
$Dot.Fill=(New-Object System.Windows.Media.BrushConverter).ConvertFromString('#FF8A93A6')
Render-Steps
Save-Toast 'state-idle.png'

$Window.Close()
Remove-Item $headRun -Force -ErrorAction SilentlyContinue
Write-Host 'DONE'