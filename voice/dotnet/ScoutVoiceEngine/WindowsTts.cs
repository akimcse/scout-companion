using System.Diagnostics;
using System.Text;

namespace ScoutVoiceEngine;

internal sealed class WindowsTts : IDisposable
{
    private const string Script =
        "Add-Type -AssemblyName System.Speech;" +
        "$t=[Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($env:SCOUT_TTS_TEXT));" +
        "$c=[Globalization.CultureInfo]::GetCultureInfo($env:SCOUT_TTS_CULTURE);" +
        "$s=New-Object System.Speech.Synthesis.SpeechSynthesizer;" +
        "try{$s.SelectVoiceByHints([System.Speech.Synthesis.VoiceGender]::Female," +
        "[System.Speech.Synthesis.VoiceAge]::Adult,0," +
        "$c)}catch{try{$s.SelectVoiceByHints([System.Speech.Synthesis.VoiceGender]::NotSet," +
        "[System.Speech.Synthesis.VoiceAge]::NotSet,0,$c)}catch{}};" +
        "$s.Rate=1;$s.Speak($t);$s.Dispose()";

    private readonly BoundedLogger _logger;
    private readonly string _culture;
    private readonly object _lock = new();
    private Process? _process;

    public WindowsTts(BoundedLogger logger, string culture)
    {
        _logger = logger;
        _culture = culture;
    }

    public async Task SpeakAsync(string text, CancellationToken cancellationToken)
    {
        var cleaned = TextProcessing.CleanForSpeech(text);
        if (string.IsNullOrWhiteSpace(cleaned))
            return;
        var encodedScript = Convert.ToBase64String(Encoding.Unicode.GetBytes(Script));
        var encodedText = Convert.ToBase64String(Encoding.UTF8.GetBytes(cleaned));
        var startInfo = new ProcessStartInfo
        {
            FileName = "powershell.exe",
            UseShellExecute = false,
            CreateNoWindow = true,
            RedirectStandardError = true,
        };
        startInfo.ArgumentList.Add("-NoLogo");
        startInfo.ArgumentList.Add("-NoProfile");
        startInfo.ArgumentList.Add("-NonInteractive");
        startInfo.ArgumentList.Add("-EncodedCommand");
        startInfo.ArgumentList.Add(encodedScript);
        startInfo.Environment["SCOUT_TTS_TEXT"] = encodedText;
        startInfo.Environment["SCOUT_TTS_CULTURE"] = _culture;

        using var process = Process.Start(startInfo) ??
                            throw new InvalidOperationException("Windows TTS could not be started.");
        lock (_lock)
            _process = process;
        try
        {
            await process.WaitForExitAsync(cancellationToken);
            var error = await process.StandardError.ReadToEndAsync(cancellationToken);
            if (process.ExitCode != 0)
                throw new InvalidOperationException($"Windows TTS exited with code {process.ExitCode}: {error}");
        }
        catch (OperationCanceledException)
        {
            Stop();
            throw;
        }
        finally
        {
            lock (_lock)
            {
                if (ReferenceEquals(_process, process))
                    _process = null;
            }
        }
    }

    public void Stop()
    {
        Process? process;
        lock (_lock)
            process = _process;
        if (process is null || process.HasExited)
            return;
        try
        {
            process.Kill(entireProcessTree: true);
        }
        catch (InvalidOperationException)
        {
        }
        catch (Exception exception)
        {
            _logger.Error("Failed to stop TTS playback process", exception);
        }
    }

    public void Dispose() => Stop();
}
