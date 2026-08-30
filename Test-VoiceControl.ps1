$ErrorActionPreference = 'Stop'
$Root = Split-Path -Parent $MyInvocation.MyCommand.Path
$App = Join-Path $Root 'scout-companion.ps1'
$Config = Get-Content (Join-Path $Root 'config.sample.json') -Raw | ConvertFrom-Json
$Text = Get-Content $App -Raw
$failed = 0

function Assert-True([bool]$Value, [string]$Name) {
    if ($Value) { Write-Host "  ok   $Name"; return }
    Write-Host "  FAIL $Name"
    $script:failed++
}

Write-Host 'voice settings'
Assert-True ($Config.voiceCommandEnabled -eq $false) 'command input defaults off'
Assert-True ($Config.voiceReplyEnabled -eq $true) 'spoken replies default on'
Assert-True ($Config.voiceWakeSensitivity -eq 65) 'wake sensitivity has a default'
Assert-True ($Config.voiceNoiseSensitivity -eq 35) 'noise sensitivity has a default'
foreach ($name in 'VoiceCommandCheck', 'VoiceReplyCheck', 'VoiceSensitivitySlider',
        'NoiseSensitivitySlider', 'VoiceEnrollButton') {
    Assert-True ($Text -match "x:Name=`"$name`"") "$name exists"
}
Assert-True ($Text -match 'x:Name="LanguagePicker"') 'language picker exists'
foreach ($language in "'en'", "'ko'", "'ja'", "'zh-Hans'") {
    Assert-True ($Text -match [regex]::Escape("Id = $language")) "$language is selectable"
}
Assert-True ($Text -match 'Restart-CompanionForLanguage') 'language changes restart Companion'
Assert-True ($Text -match "placeholder.Content = T 'Choose language'") 'unsupported current languages are not shown as English'
foreach ($label in 'VOICE CONTROL', 'Run commands by voice', 'Receive spoken answers',
        '&quot;Hey Scout&quot; wake sensitivity', 'Noise sensitivity',
        'Set up voice recognition') {
    Assert-True ($Text -match [regex]::Escape($label)) "$label is shown in English"
}

Write-Host 'settings translations'
$settingsMatch = [regex]::Match(
    $Text, "(?s)\[xml\]\`$settingsXaml\s*=\s*@'(.*?)'@")
Assert-True $settingsMatch.Success 'settings XAML can be audited'
[xml]$settingsXml = $settingsMatch.Groups[1].Value
$settingsKeys = New-Object 'System.Collections.Generic.HashSet[string]'
foreach ($node in $settingsXml.SelectNodes('//*')) {
    foreach ($attribute in 'Text', 'Content', 'ToolTip', 'Title') {
        $value = $node.GetAttribute($attribute)
        if ($value -and $value -notmatch '^\{|^&#x|^\s*$|^-?$|^\d+%?$') {
            [void]$settingsKeys.Add($value)
        }
    }
}
foreach ($tooltip in $settingsXml.SelectNodes('//*[local-name()="ToolTip"]')) {
    if ($tooltip.InnerText.Trim()) {
        [void]$settingsKeys.Add($tooltip.InnerText.Trim())
    }
}
$dynamicSettingsKeys = @(
    'English', 'Korean', 'Japanese', 'Chinese (Simplified)',
    'Choose language', 'Voice profile ready', 'Voice profile required',
    'Recording 5 phrases...', 'Voice setup canceled',
    'Preparing voice runtime...', 'Voice runtime setup failed',
    'Voice runtime setup is missing', 'Could not prepare voice runtime',
    'Could not open voice setup', 'Enable voice control',
    'Disable voice control',
    'The prepared Scout Voice runtime or voice profile was not found.'
)
foreach ($tag in 'ko', 'ja', 'zh-Hans') {
    $translation = Get-Content (Join-Path $Root "lang\$tag.json") -Raw |
        ConvertFrom-Json
    $translationKeys = @($translation.PSObject.Properties.Name)
    $missing = @($settingsKeys + $dynamicSettingsKeys |
        Where-Object { $translationKeys -notcontains $_ } |
        Sort-Object -Unique)
    Assert-True ($missing.Count -eq 0) "$tag covers every settings label"
}

$allUiKeys = New-Object 'System.Collections.Generic.HashSet[string]'
foreach ($match in [regex]::Matches(
        $Text, "(?:^|[^A-Za-z])T\s+'((?:[^']|'')*)'")) {
    [void]$allUiKeys.Add($match.Groups[1].Value.Replace("''", "'"))
}
foreach ($name in 'xaml', 'settingsXaml') {
    $uiMatch = [regex]::Match(
        $Text, "(?s)\[xml\]\`$$name\s*=\s*@'(.*?)'@")
    if (-not $uiMatch.Success) { continue }
    [xml]$uiXml = $uiMatch.Groups[1].Value
    foreach ($node in $uiXml.SelectNodes('//*')) {
        foreach ($attribute in 'Text', 'Content', 'ToolTip', 'Title') {
            $value = $node.GetAttribute($attribute)
            if ($value -and $value -notmatch '^\{|^&#x|^\s*$|^-?$|^\d+%?$') {
                [void]$allUiKeys.Add($value)
            }
        }
        if ($node.LocalName -eq 'ToolTip' -and $node.InnerText.Trim()) {
            [void]$allUiKeys.Add($node.InnerText.Trim())
        }
    }
}
foreach ($value in $dynamicSettingsKeys) { [void]$allUiKeys.Add($value) }
$notLocalized = @('Scout Companion', 'MIC', '✕', '⚠ Permission requested')
foreach ($tag in 'ko', 'ja', 'zh-Hans') {
    $translation = Get-Content (Join-Path $Root "lang\$tag.json") -Raw |
        ConvertFrom-Json
    $translationKeys = @($translation.PSObject.Properties.Name)
    $missing = @($allUiKeys |
        Where-Object {
            $notLocalized -notcontains $_ -and
            $_.Length -gt 1 -and
            $_ -notmatch 'Permission requested$' -and
            $translationKeys -notcontains $_
        } |
        Sort-Object -Unique)
    if ($missing.Count) {
        Write-Host "       missing: $($missing -join ' | ')"
    }
    Assert-True ($missing.Count -eq 0) "$tag covers every localizable UI label"
}

Write-Host 'current conversation bridge'
Assert-True ($Text -match 'SendUnicodeText\(\$request\.Command\)') 'types into Scout'
Assert-True ($Text -match 'function Set-AgentMessageFocus') 'focus acquisition is guarded'
Assert-True ($Text -match 'AttachThreadInput') 'foreground focus locks are handled'
Assert-True ($Text -match '\$attempt -lt 3') 'focus acquisition is retried'
Assert-True ($Text -match 'Set-AgentMessageFocus \$previous \$null') 'previous app focus is restored safely'
Assert-True ($Text -match '(?s)IsIconic\(\$hwnd\).*?ShowWindow\(\$hwnd, 9\)') 'maximized windows are not restored'
$tokens = $null
$parseErrors = $null
$ast = [System.Management.Automation.Language.Parser]::ParseFile(
    $App, [ref]$tokens, [ref]$parseErrors)
$focusFunction = $ast.Find({
    param($node)
    $node -is [System.Management.Automation.Language.FunctionDefinitionAst] -and
        $node.Name -eq 'Set-AgentMessageFocus'
}, $true)
$insideFunction = $false
$parent = $focusFunction.Parent
while ($parent) {
    if ($parent -is [System.Management.Automation.Language.FunctionDefinitionAst]) {
        $insideFunction = $true
        break
    }
    $parent = $parent.Parent
}
Assert-True (-not $insideFunction) 'focus helper is script-scoped'
Assert-True ($Text -match '\$request\.SawTurnEnd') 'waits for the turn boundary'
Assert-True ($Text -match 'assistant\.turn_end') 'reads the authoritative end event'
Assert-True ($Text -match 'AgentRunning -and \$IsMinimized') 'stays visible when minimized'
Assert-True ($Text -match 'voice bridge exited code=') 'unexpected bridge exits are detected'
Assert-True ($Text -match 'VoiceRestartAfter') 'persisted voice input restarts after failure'
Assert-True ($Text -match 'if \(\$script:VoiceReady\) \{ 2 \} else \{ 30 \}') 'startup failures back off'
Assert-True ($Text -match '\$script:VoiceReady = \$true') 'published state marks the bridge ready'

Write-Host 'portable runtime'
$required = @(
    'voice\companion_voice_host.py',
    'voice\Prepare-VoiceRuntime.ps1',
    'voice\runtime\agent.py',
    'voice\runtime\voice_runtime.py',
    'voice\runtime\enrollment_gui.py',
    'voice\runtime\requirements.txt',
    'voice\runtime\scout-listening.wav'
)
foreach ($relative in $required) {
    Assert-True (Test-Path (Join-Path $Root $relative)) "$relative is packaged"
}
$Enrollment = Get-Content (Join-Path $Root 'voice\runtime\enrollment_gui.py') -Raw
foreach ($language in '"en"', '"ko"', '"ja"', '"zh-Hans"') {
    Assert-True ($Enrollment -match [regex]::Escape($language)) "voice enrollment supports $language"
}
Assert-True ($Text -match "'--language', \`$enrollmentLanguage") 'Companion passes its language to enrollment'
$Build = Get-Content (Join-Path $Root 'Build-Release.ps1') -Raw
Assert-True ($Build -match "'voice'") 'release zip includes voice'
$Prepare = Get-Content (Join-Path $Root 'voice\Prepare-VoiceRuntime.ps1') -Raw
Assert-True ($Prepare -match 'SHA-256') 'model downloads are verified'
Assert-True ($Prepare -match "param\(\[string\]\`$InstallDir\)") 'custom runtime directory is accepted'
Assert-True ($Prepare -match "Python 3\.11 or later") 'supported Python version is enforced'
$Agent = Get-Content (Join-Path $Root 'voice\runtime\agent.py') -Raw
Assert-True ($Agent -match 'Rejected unverified command') 'unregistered speakers are rejected'
Assert-True ($Agent -notmatch 'Executing verified M365 command with omitted wake word') 'wake word cannot be omitted'
$VoiceRuntime = Get-Content (Join-Path $Root 'voice\runtime\voice_runtime.py') -Raw
Assert-True ($VoiceRuntime -match '\\u4e00-\\u9fff') 'Chinese enrollment text survives normalization'
Assert-True ($Agent -match 'cut = self\._snap_to_sentence') 'interrupted answers resume at a sentence'
$Runtime = Get-Content (Join-Path $Root 'voice\runtime\voice_runtime.py') -Raw
Assert-True ($Runtime -match 'def start_windows_speech') 'Windows TTS playback is tracked'
Assert-True ($Runtime -match '(?s)def close\(self\).*?self\.stop\(\)') 'speaker close stops playback'
$HostText = Get-Content (Join-Path $Root 'voice\companion_voice_host.py') -Raw
Assert-True ($HostText -match 'agent_module\.WorkIQSession =') 'WorkIQ is not required'
$Installer = Get-Content (Join-Path $Root 'Install.ps1') -Raw
Assert-True ($Installer -match 'Stop-ProcessTree') 'installer stops the voice process tree'
Assert-True ($Text -match 'Stop-OwnedProcessTree') 'Companion stops setup and enrollment children'

$python = Get-Command python -ErrorAction SilentlyContinue
if ($python) {
    & python -m py_compile `
        (Join-Path $Root 'voice\companion_voice_host.py') `
        (Join-Path $Root 'voice\runtime\agent.py') `
        (Join-Path $Root 'voice\runtime\voice_runtime.py') `
        (Join-Path $Root 'voice\runtime\enrollment_gui.py')
    Assert-True ($LASTEXITCODE -eq 0) 'Python sources compile'
} else {
    Write-Host '  skip Python compile (python not installed)'
}

if ($failed) { throw "$failed voice control test(s) failed" }
Write-Host ''
Write-Host 'Voice control tests passed'
