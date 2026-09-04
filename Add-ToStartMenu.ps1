<#
.SYNOPSIS
    Adds Scout Companion to the Start Menu.

.DESCRIPTION
    Creates two shortcuts under the current user's Start Menu:

      Scout Companion          - runs the companion now
      Scout Companion (auto)   - runs Watch-Scout.ps1, which starts the
                                 companion whenever Scout is running and lets
                                 it close itself when Scout quits

    Both get a mascot icon rather than the generic PowerShell one, so they are
    tellable apart at a glance. The icon is drawn here at runtime, the same way
    the tray icon is, so no binary asset needs to live in the repository.

    Per-user only: no registry writes, no admin rights, nothing outside your
    own profile. Run with -Remove to take the shortcuts away again.

.EXAMPLE
    powershell -ExecutionPolicy Bypass -File .\Add-ToStartMenu.ps1
.EXAMPLE
    powershell -ExecutionPolicy Bypass -File .\Add-ToStartMenu.ps1 -Remove
#>

#Requires -Version 5.0
[CmdletBinding()]
param([switch]$Remove)

Add-Type -AssemblyName System.Drawing

$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$StartMenu = Join-Path ([Environment]::GetFolderPath('Programs')) ''
$Links = @{
    Now  = Join-Path $StartMenu 'Scout Companion.lnk'
    Auto = Join-Path $StartMenu 'Scout Companion (auto).lnk'
}
$StartupLink = Join-Path ([Environment]::GetFolderPath('Startup')) 'Scout Companion.lnk'
$IconPath = Join-Path $env:LOCALAPPDATA 'ScoutCompanion\scout-companion.ico'

if ($Remove) {
    foreach ($l in $Links.Values) {
        if (Test-Path $l) { Remove-Item $l -Force; Write-Host "removed $(Split-Path $l -Leaf)" }
    }
    if (Test-Path $IconPath) { Remove-Item $IconPath -Force }
    return
}

foreach ($f in 'Start-ScoutCompanion.vbs', 'Watch-Scout.vbs') {
    if (-not (Test-Path (Join-Path $ScriptDir $f))) {
        throw "$f is missing from $ScriptDir - run this from the folder you cloned into."
    }
}

# ---------------------------------------------------------------------------
# Icon, drawn at every size Windows asks for. Shipping a .ico would be simpler
# but the project deliberately carries no binary assets.
# ---------------------------------------------------------------------------
function New-IconFile([string]$path) {
    $sizes = 16, 24, 32, 48, 64, 128, 256
    $fill  = [System.Drawing.ColorTranslator]::FromHtml('#4ADE80')
    $edge  = [System.Drawing.Color]::FromArgb(210,
        [Math]::Max(0, $fill.R - 70), [Math]::Max(0, $fill.G - 70), [Math]::Max(0, $fill.B - 70))

    $frames = @()
    foreach ($s in $sizes) {
        $bmp = New-Object System.Drawing.Bitmap $s, $s
        $g = [System.Drawing.Graphics]::FromImage($bmp)
        $g.SmoothingMode = [System.Drawing.Drawing2D.SmoothingMode]::AntiAlias
        $g.Clear([System.Drawing.Color]::Transparent)
        $k = $s / 32.0
        $brush = New-Object System.Drawing.SolidBrush $fill
        $pen   = New-Object System.Drawing.Pen $edge, (2.0 * $k)
        $dark  = New-Object System.Drawing.SolidBrush $edge
        try {
            foreach ($x in 3.5, 18.5) {
                $g.FillEllipse($brush, ($x * $k), (1.5 * $k), (10 * $k), (11 * $k))
                $g.DrawEllipse($pen,   ($x * $k), (1.5 * $k), (10 * $k), (11 * $k))
            }
            $g.FillEllipse($brush, (3 * $k), (8 * $k), (26 * $k), (22 * $k))
            $g.DrawEllipse($pen,   (3 * $k), (8 * $k), (26 * $k), (22 * $k))
            $g.FillEllipse($dark, (9.2 * $k),  (15 * $k), (5.4 * $k), (6.4 * $k))
            $g.FillEllipse($dark, (17.4 * $k), (15 * $k), (5.4 * $k), (6.4 * $k))
        } finally { $brush.Dispose(); $pen.Dispose(); $dark.Dispose(); $g.Dispose() }

        $ms = New-Object System.IO.MemoryStream
        $bmp.Save($ms, [System.Drawing.Imaging.ImageFormat]::Png)
        $frames += ,$ms.ToArray()
        $bmp.Dispose()
    }

    # ICO container: 6-byte header, 16 bytes per entry, then the PNG payloads.
    $out = New-Object System.IO.MemoryStream
    $bw  = New-Object System.IO.BinaryWriter $out
    try {
        $bw.Write([uint16]0); $bw.Write([uint16]1); $bw.Write([uint16]$frames.Count)
        $offset = 6 + 16 * $frames.Count
        for ($i = 0; $i -lt $frames.Count; $i++) {
            # 256 is encoded as 0 in a directory entry.
            $dim = if ($sizes[$i] -ge 256) { 0 } else { $sizes[$i] }
            $bw.Write([byte]$dim); $bw.Write([byte]$dim)
            $bw.Write([byte]0); $bw.Write([byte]0)
            $bw.Write([uint16]1); $bw.Write([uint16]32)
            $bw.Write([uint32]$frames[$i].Length); $bw.Write([uint32]$offset)
            $offset += $frames[$i].Length
        }
        foreach ($f in $frames) { $bw.Write($f) }
        $bw.Flush()
        New-Item -ItemType Directory -Path (Split-Path $path) -Force | Out-Null
        [System.IO.File]::WriteAllBytes($path, $out.ToArray())
    } finally { $bw.Dispose(); $out.Dispose() }
}

New-IconFile $IconPath

$WScriptExe = Join-Path $env:SystemRoot 'System32\wscript.exe'
$shell = New-Object -ComObject WScript.Shell
try {
    # WScript avoids allocating a console when Windows Terminal is the default
    # terminal application.
    $now = $shell.CreateShortcut($Links.Now)
    $now.TargetPath       = $WScriptExe
    $now.Arguments        = "`"$(Join-Path $ScriptDir 'Start-ScoutCompanion.vbs')`""
    $now.WorkingDirectory = $ScriptDir
    $now.IconLocation     = "$IconPath,0"
    $now.Description      = 'Floating overlay showing what the Scout agent is doing'
    $now.WindowStyle      = 7
    $now.Save()

    $auto = $shell.CreateShortcut($Links.Auto)
    $auto.TargetPath       = $WScriptExe
    $auto.Arguments        = "`"$(Join-Path $ScriptDir 'Watch-Scout.vbs')`""
    $auto.WorkingDirectory = $ScriptDir
    $auto.IconLocation     = "$IconPath,0"
    $auto.Description      = 'Launches Scout Companion whenever Microsoft Scout is running'
    $auto.WindowStyle      = 7
    $auto.Save()

    if (Test-Path $StartupLink) {
        $startup = $shell.CreateShortcut($StartupLink)
        $startup.TargetPath = $WScriptExe
        $startup.Arguments = "`"$(Join-Path $ScriptDir 'Watch-Scout.vbs')`""
        $startup.WorkingDirectory = $ScriptDir
        $startup.IconLocation = "$IconPath,0"
        $startup.Description = 'Starts Scout Companion when Microsoft Scout is running'
        $startup.WindowStyle = 7
        $startup.Save()
    }
} finally {
    [void][System.Runtime.InteropServices.Marshal]::ReleaseComObject($shell)
}

Write-Host ''
Write-Host 'Added to the Start Menu:'
Write-Host '  Scout Companion          - run it now'
Write-Host '  Scout Companion (auto)   - run it whenever Scout is running'
Write-Host ''
Write-Host 'Search the Start Menu for "scout"; right-click to pin.'
Write-Host 'Run this script with -Remove to take them away again.'
