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
foreach ($name in 'VoiceCommandCheck', 'VoiceReplyCheck', 'VoiceLanguageHint',
        'VoiceSensitivitySlider', 'NoiseSensitivitySlider', 'VoiceEnrollButton') {
    Assert-True ($Text -match "x:Name=`"$name`"") "$name exists"
}
Assert-True ($Text -match 'x:Name="LanguagePicker"') 'language picker exists'
foreach ($language in "'en'", "'zh-Hans'", "'zh-Hant'", "'fr'", "'de'", "'it'",
        "'es'", "'ja'", "'ko'", "'ru'", "'pt-BR'", "'tr'", "'pl'", "'cs'", "'hu'") {
    Assert-True ($Text -match [regex]::Escape("Id = $language")) "$language is selectable"
}
Assert-True ($Text -match "\`$script:VoiceLanguages = @\('en', 'ko', 'ja', 'zh-Hans'\)") 'voice languages remain explicit'
Assert-True ($Text -match "\`$script:Lang -notin \`$script:VoiceLanguages") 'unsupported voice languages show their fallback'
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
Assert-True ($Text -match 'Wait-VoiceCommandSubmission \$win\.Hwnd \$request\.Command') 'confirms Scout consumed the voice command'
Assert-True ($Text -match 'kept the voice command as a draft') 'does not report an unsent draft as submitted'
Assert-True ($Text -match '(?s)SendEnter\(\).*?Find-AgentButton \$win\.Hwnd @\(''Send''\).*?Invoke\(\)') 'falls back to invoking Send directly'
Assert-True ($Text -match 'function Set-AgentMessageFocus') 'focus acquisition is guarded'
Assert-True ($Text -match 'AttachThreadInput') 'foreground focus locks are handled'
Assert-True ($Text -match '\$attempt -lt 3') 'focus acquisition is retried'
Assert-True ($Text -match '(?s)IsIconic\(\$hwnd\).*?ShowWindow\(\$hwnd, 9\)') 'maximized windows are not restored'
Assert-True ($Text -match '(?s)function Submit-VoiceUiRequest.*?ShowWindow\(\$win\.Hwnd, 3\).*?Find-AgentButton') 'voice commands maximize Scout before finding controls'
Assert-True ($Text -notmatch 'ShowWindow\(\$win\.Hwnd, 6\)') 'voice commands leave Scout maximized'
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
    'voice\Ensure-VoiceModels.ps1',
    'voice\Prepare-DotNetVoiceRuntime.ps1',
    'voice\dotnet\ScoutVoiceEngine\ScoutVoiceEngine.csproj',
    'voice\dotnet\ScoutVoiceEngine\VoiceEngine.cs',
    'voice\dotnet\ScoutVoiceEngine\EnrollmentForm.cs',
    'voice\dotnet\ScoutVoiceEngine\LanguageResources.cs',
    'voice\dotnet\ScoutVoiceEngine\scout-listening.wav',
    'voice\dotnet\ScoutVoiceEngine\scout-called-en.wav',
    'voice\dotnet\ScoutVoiceEngine\scout-called-ko.wav',
    'voice\dotnet\ScoutVoiceEngine\scout-called-ja.wav',
    'voice\dotnet\ScoutVoiceEngine\scout-called-zh-Hans.wav'
)
foreach ($relative in $required) {
    Assert-True (Test-Path (Join-Path $Root $relative)) "$relative is packaged"
}
$Enrollment = Get-Content (Join-Path $Root 'voice\dotnet\ScoutVoiceEngine\LanguageResources.cs') -Raw
foreach ($language in '["en"]', '["ko"]', '["ja"]', '["zh-Hans"]') {
    Assert-True ($Enrollment -match [regex]::Escape($language)) "voice enrollment supports $language"
}
Assert-True ($Text -match "'--language', \`$enrollmentLanguage") 'Companion passes its language to enrollment'
$Build = Get-Content (Join-Path $Root 'Build-Release.ps1') -Raw
Assert-True ($Build -match "'voice'") 'release zip includes voice'
$Prepare = Get-Content (Join-Path $Root 'voice\Prepare-DotNetVoiceRuntime.ps1') -Raw
$ModelSetup = Get-Content (Join-Path $Root 'voice\Ensure-VoiceModels.ps1') -Raw
Assert-True ($ModelSetup -match 'SHA-256') 'model downloads are verified'
Assert-True ($ModelSetup -match "tokens\.txt") 'SenseVoice companion files are required'
Assert-True ($ModelSetup -match "\.sensevoice-") 'SenseVoice extracts through a temporary directory'
Assert-True ($Prepare -match "\[string\]\`$InstallDir") 'custom runtime directory is accepted'
Assert-True ($Prepare -match "\[string\]\`$EngineDll") 'engine probe path is accepted'
Assert-True ($Prepare -match 'windowsdesktop-runtime-8\.0\.30-win-arm64\.zip') 'ARM64 private runtime is pinned'
Assert-True ($Prepare -match 'windowsdesktop-runtime-8\.0\.30-win-x64\.zip') 'x64 private runtime is pinned'
Assert-True ($Prepare -match 'SHA512') 'private runtime download is verified'
Assert-True ($Prepare -match '--probe') 'the .NET engine probes models before migration cleanup'
Assert-True (-not $Config.PSObject.Properties['voiceEngine']) 'there is only one product voice engine'
Assert-True ($Text -notmatch 'VoiceEnginePicker') 'no engine selector remains'
Assert-True ($Text -match 'Get-DotNetVoiceEngineDirectory') 'architecture-specific .NET engine is resolved'
Assert-True ($Build -match "'win-arm64', 'win-x64'") 'both Windows architectures are published'
Assert-True ($Build -match 'voice package is incomplete') 'release build verifies engine assets'
$Engine = Get-Content (Join-Path $Root 'voice\dotnet\ScoutVoiceEngine\VoiceEngine.cs') -Raw -Encoding UTF8
Assert-True ($Engine -match 'Rejected unverified command') 'unregistered speakers are rejected'
Assert-True ($Engine -match 'Explicit wake phrase interrupted TTS') 'only wake speech interrupts answers'
Assert-True ($Engine -match 'Speaker-verified wake phrase mixed with playback interrupted TTS') 'speaker-backed mixed wake interrupts online playback'
Assert-True ($Engine -match 'DetectTtsInterrupt') 'TTS interruption distinguishes clean and mixed wake speech'
Assert-True ($Engine -match 'speaking \? 0\.30 : 0\.65') 'short standalone wake is processed during TTS'
Assert-True ($Engine -match 'scout-listening\.wav') 'accepted commands play the original sound'
$Processing = Get-Content (Join-Path $Root 'voice\dotnet\ScoutVoiceEngine\TextProcessing.cs') -Raw -Encoding UTF8
Assert-True ($Processing -match '一-鿿') 'Chinese enrollment text survives normalization'
$Tts = Get-Content (Join-Path $Root 'voice\dotnet\ScoutVoiceEngine\WindowsTts.cs') -Raw -Encoding UTF8
Assert-True ($Tts -match 'Kill\(entireProcessTree: true\)') 'TTS playback is stopped as a process tree'
Assert-True ($Tts -match 'ClientWebSocket') 'online neural TTS uses an architecture-neutral .NET client'
Assert-True ($Tts -match 'ko-KR-SunHiNeural') 'online Korean TTS uses the approved neural voice'
Assert-True ($Tts -match 'WaveOutEvent') 'online MP3 playback remains interruptible'
Assert-True ($Tts -match 'using Windows offline voice') 'online failures fall back to Windows TTS'
Assert-True ($Tts -match 'public void Pause\(\)') 'spoken answers can pause without losing position'
Assert-True ($Tts -match 'public void Resume\(\)') 'declined calls resume the original answer'
Assert-True ($Tts -match 'PlayCalledPromptAsync') 'call confirmation uses a pre-generated prompt'
$Project = Get-Content (Join-Path $Root 'voice\dotnet\ScoutVoiceEngine\ScoutVoiceEngine.csproj') -Raw -Encoding UTF8
Assert-True ($Project -match 'org\.k2fsa\.sherpa\.onnx') 'Sherpa ONNX is the .NET speech backend'
Assert-True ($Project -match 'NAudio') 'NAudio is the Windows microphone backend'
$EnrollmentForm = Get-Content (Join-Path $Root 'voice\dotnet\ScoutVoiceEngine\EnrollmentForm.cs') -Raw -Encoding UTF8
$VoiceApp = Get-Content (Join-Path $Root 'voice\dotnet\ScoutVoiceEngine\App.cs') -Raw -Encoding UTF8
Assert-True ($Project -match '<UseWPF>true</UseWPF>') 'enrollment uses the same WPF UI framework as settings'
Assert-True ($EnrollmentForm -match 'SizeToContent = SizeToContent\.Height') 'enrollment window grows to fit localized text'
Assert-True ($EnrollmentForm -match 'TextWrapping = TextWrapping\.Wrap') 'enrollment text wraps without clipping'
Assert-True ($EnrollmentForm -match '#FF1B1F2A') 'enrollment uses the settings window background'
Assert-True ($EnrollmentForm -match '#FFE6EAF2') 'enrollment uses the settings window foreground'
Assert-True ($EnrollmentForm -match 'Segoe UI, Malgun Gothic, Yu Gothic UI, Microsoft YaHei UI') 'WPF enrollment has CJK font fallback'
Assert-True ($EnrollmentForm -match 'ScoutCompanion", "scout-companion\.ico"') 'enrollment reuses the Companion icon'
Assert-True ($EnrollmentForm -match 'DwmSetWindowAttribute\(handle, 20') 'enrollment uses the settings dark title bar'
Assert-True ($VoiceApp -match 'SetApartmentState\(ApartmentState\.STA\)') 'WPF enrollment runs on an STA thread'
Assert-True ($Text -match '\$startInfo\.CreateNoWindow = \$true') 'voice enrollment does not open a console'
$Installer = Get-Content (Join-Path $Root 'Install.ps1') -Raw
foreach ($launcher in 'Start-ScoutCompanion.vbs', 'Watch-Scout.vbs') {
    Assert-True (Test-Path (Join-Path $Root $launcher)) "$launcher is packaged"
}
$Shortcuts = Get-Content (Join-Path $Root 'Add-ToStartMenu.ps1') -Raw
Assert-True ($Shortcuts -match 'System32\\wscript\.exe') 'shortcuts use the no-console WScript host'
Assert-True ($Installer -match 'Stop-ProcessTree') 'installer stops the voice process tree'
Assert-True ($Installer -match 'Stop-ProcessTree\(\[int\]\$RootId, \[int\]\$ExcludeId = \$PID\)') 'installer excludes itself from in-app update cleanup'
Assert-True ($Installer -match '\$child\.ProcessId -eq \$ExcludeId') 'installer does not traverse through its own process'
Assert-True ($Installer -match 'Remove-UpgradePath') 'installer retries locked upgrade files'
Assert-True ($Installer -match 'Voice engine installation is incomplete') 'installer verifies the selected engine'
Assert-True ($Text -match 'Stop-OwnedProcessTree') 'Companion stops setup and enrollment children'

$dotnet = Get-Command dotnet -ErrorAction SilentlyContinue
if ($dotnet) {
    $projectPath = Join-Path $Root 'voice\dotnet\ScoutVoiceEngine\ScoutVoiceEngine.csproj'
    & $dotnet.Source build $projectPath -c Release --nologo | Out-Null
    Assert-True ($LASTEXITCODE -eq 0) '.NET engine builds'
    $engineExe = Join-Path $Root 'voice\dotnet\ScoutVoiceEngine\bin\Release\net8.0-windows\ScoutVoiceEngine.exe'
    & $engineExe --self-test | Out-Null
    Assert-True ($LASTEXITCODE -eq 0) '.NET engine self-tests pass'
} else {
    Write-Host '  skip .NET build (SDK not installed)'
}

if ($failed) { throw "$failed voice control test(s) failed" }
Write-Host ''
Write-Host 'Voice control tests passed'
