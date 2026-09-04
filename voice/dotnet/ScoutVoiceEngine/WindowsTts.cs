using System.Diagnostics;
using System.Globalization;
using System.Net.WebSockets;
using System.Security;
using System.Security.Cryptography;
using System.Text;
using NAudio.FileFormats.Mp3;
using NAudio.Wave;
using NAudio.Wave.SampleProviders;

namespace ScoutVoiceEngine;

internal sealed class WindowsTts : IDisposable
{
    internal const int ConfiguredVolume = 70;
    internal const int OnlineVolume = 45;
    private const string TrustedClientToken = "6A5AA1D4EAFF4E9FB37E23D68491D6F4";
    private const string ChromiumVersion = "143.0.3650.75";
    private const string UserAgent =
        "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 " +
        "(KHTML, like Gecko) Chrome/143.0.0.0 Safari/537.36 Edg/143.0.0.0";
    private static readonly string OfflineScript =
        "Add-Type -AssemblyName System.Speech;" +
        "$t=[Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($env:SCOUT_TTS_TEXT));" +
        "$c=[Globalization.CultureInfo]::GetCultureInfo($env:SCOUT_TTS_CULTURE);" +
        "$s=New-Object System.Speech.Synthesis.SpeechSynthesizer;" +
        "try{$s.SelectVoiceByHints([System.Speech.Synthesis.VoiceGender]::Female," +
        "[System.Speech.Synthesis.VoiceAge]::Adult,0," +
        "$c)}catch{try{$s.SelectVoiceByHints([System.Speech.Synthesis.VoiceGender]::NotSet," +
        "[System.Speech.Synthesis.VoiceAge]::NotSet,0,$c)}catch{}};" +
        "$s.Rate=1;$s.Volume=100;" +
        "$s.SetOutputToWaveFile($env:SCOUT_TTS_WAVE);$s.Speak($t);$s.Dispose()";

    private readonly BoundedLogger _logger;
    private readonly string _culture;
    private readonly object _lock = new();
    private CancellationTokenSource? _operation;
    private WaveOutEvent? _output;
    private System.Media.SoundPlayer? _promptPlayer;
    private Process? _process;
    private bool _paused;
    private TaskCompletionSource? _resumeSignal;

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

        using var operation = CancellationTokenSource.CreateLinkedTokenSource(cancellationToken);
        lock (_lock)
            _operation = operation;
        try
        {
            try
            {
                var audio = await SynthesizeOnlineAsync(
                    cleaned, VoiceForCulture(_culture), operation.Token);
                await PlayMp3Async(audio, operation.Token);
                return;
            }
            catch (OperationCanceledException) when (operation.IsCancellationRequested)
            {
                throw;
            }
            catch (Exception exception)
            {
                _logger.Warning(
                    $"Online neural TTS unavailable; using Windows offline voice: {exception.Message}");
            }

            await SpeakOfflineAsync(cleaned, operation.Token);
        }
        finally
        {
            lock (_lock)
            {
                if (ReferenceEquals(_operation, operation))
                    _operation = null;
            }
        }
    }

    private async Task PlayMp3Async(byte[] audio, CancellationToken cancellationToken)
    {
        using var stream = new MemoryStream(audio, writable: false);
        using var reader = new Mp3FileReaderBase(
            stream, format => new DmoMp3FrameDecompressor(format));
        await PlayWaveStreamAsync(reader, OnlineVolume / 100f, cancellationToken);
    }

    private async Task PlayWaveStreamAsync(
        WaveStream reader, float volumeLevel, CancellationToken cancellationToken)
    {
        using var output = new WaveOutEvent();
        var volume = new VolumeSampleProvider(reader.ToSampleProvider())
        {
            Volume = volumeLevel,
        };
        var completed = new TaskCompletionSource(
            TaskCreationOptions.RunContinuationsAsynchronously);
        output.PlaybackStopped += (_, eventArgs) =>
        {
            if (eventArgs.Exception is not null)
                completed.TrySetException(eventArgs.Exception);
            else
                completed.TrySetResult();
        };
        try
        {
            output.Init(volume);
            lock (_lock)
            {
                _output = output;
                if (!_paused)
                    output.Play();
            }
            using var registration = cancellationToken.Register(output.Stop);
            await completed.Task.WaitAsync(cancellationToken);
        }
        finally
        {
            lock (_lock)
            {
                if (ReferenceEquals(_output, output))
                    _output = null;
            }
        }
    }

    public void Pause()
    {
        lock (_lock)
        {
            if (_paused)
                return;
            _paused = true;
            _resumeSignal = new TaskCompletionSource(
                TaskCreationOptions.RunContinuationsAsynchronously);
            try { _output?.Pause(); }
            catch (Exception exception)
            {
                _logger.Warning($"Could not pause TTS playback: {exception.Message}");
            }
        }
    }

    public void Resume()
    {
        TaskCompletionSource? signal;
        lock (_lock)
        {
            _paused = false;
            signal = _resumeSignal;
            _resumeSignal = null;
            try { _output?.Play(); }
            catch (Exception exception)
            {
                _logger.Warning($"Could not resume TTS playback: {exception.Message}");
            }
        }
        signal?.TrySetResult();
    }

    public async Task PlayCalledPromptAsync(string language, CancellationToken cancellationToken)
    {
        var suffix = language switch
        {
            "ko" => "ko",
            "ja" => "ja",
            "zh-Hans" => "zh-Hans",
            _ => "en",
        };
        var engineDirectory = Path.GetDirectoryName(typeof(WindowsTts).Assembly.Location)!;
        var path = Path.Combine(engineDirectory, $"scout-called-{suffix}.wav");
        if (!File.Exists(path))
            throw new FileNotFoundException("The pre-generated call prompt is missing.", path);
        using var player = new System.Media.SoundPlayer(path);
        lock (_lock)
            _promptPlayer = player;
        try
        {
            using var registration = cancellationToken.Register(player.Stop);
            await Task.Run(player.PlaySync, cancellationToken);
        }
        finally
        {
            lock (_lock)
            {
                if (ReferenceEquals(_promptPlayer, player))
                    _promptPlayer = null;
            }
        }
    }

    private async Task SpeakOfflineAsync(string text, CancellationToken cancellationToken)
    {
        await WaitUntilResumedAsync(cancellationToken);
        var wavePath = Path.Combine(
            Path.GetTempPath(), $"scout-windows-tts-{Guid.NewGuid():N}.wav");
        var encodedScript = Convert.ToBase64String(Encoding.Unicode.GetBytes(OfflineScript));
        var encodedText = Convert.ToBase64String(Encoding.UTF8.GetBytes(text));
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
        startInfo.Environment["SCOUT_TTS_WAVE"] = wavePath;
        try
        {
            using var process = Process.Start(startInfo) ??
                                throw new InvalidOperationException("Windows TTS could not be started.");
            lock (_lock)
                _process = process;
            try
            {
                await process.WaitForExitAsync(cancellationToken);
                var error = await process.StandardError.ReadToEndAsync(cancellationToken);
                if (process.ExitCode != 0)
                    throw new InvalidOperationException(
                        $"Windows TTS exited with code {process.ExitCode}: {error}");
            }
            catch (OperationCanceledException)
            {
                StopProcess(process);
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
            using var reader = new WaveFileReader(wavePath);
            await PlayWaveStreamAsync(reader, ConfiguredVolume / 100f, cancellationToken);
        }
        finally
        {
            try { File.Delete(wavePath); }
            catch (IOException exception)
            {
                _logger.Warning($"Could not remove temporary TTS audio: {exception.Message}");
            }
            catch (UnauthorizedAccessException exception)
            {
                _logger.Warning($"Could not remove temporary TTS audio: {exception.Message}");
            }
        }
    }

    private async Task WaitUntilResumedAsync(CancellationToken cancellationToken)
    {
        Task? resume;
        lock (_lock)
            resume = _paused ? _resumeSignal?.Task : null;
        if (resume is not null)
            await resume.WaitAsync(cancellationToken);
    }

    internal static string VoiceForCulture(string culture) =>
        culture.ToLowerInvariant() switch
        {
            "ko-kr" => "ko-KR-SunHiNeural",
            "ja-jp" => "ja-JP-NanamiNeural",
            "zh-cn" => "zh-CN-XiaoxiaoNeural",
            _ => "en-US-AriaNeural",
        };

    internal static string GenerateSecMsGec(DateTimeOffset now)
    {
        const long windowsEpochSeconds = 11_644_473_600;
        var seconds = now.ToUnixTimeSeconds() + windowsEpochSeconds;
        seconds -= seconds % 300;
        var ticks = seconds * 10_000_000;
        var input = Encoding.ASCII.GetBytes(
            ticks.ToString(CultureInfo.InvariantCulture) + TrustedClientToken);
        return Convert.ToHexString(SHA256.HashData(input));
    }

    private static async Task<byte[]> SynthesizeOnlineAsync(
        string text, string voice, CancellationToken cancellationToken)
    {
        using var timeout = CancellationTokenSource.CreateLinkedTokenSource(cancellationToken);
        timeout.CancelAfter(TimeSpan.FromSeconds(15));
        var token = timeout.Token;
        var connectionId = Guid.NewGuid().ToString("N");
        var uri = new Uri(
            "wss://speech.platform.bing.com/consumer/speech/synthesize/readaloud/edge/v1" +
            $"?TrustedClientToken={TrustedClientToken}" +
            $"&ConnectionId={connectionId}" +
            $"&Sec-MS-GEC={GenerateSecMsGec(DateTimeOffset.UtcNow)}" +
            $"&Sec-MS-GEC-Version=1-{ChromiumVersion}");
        using var socket = new ClientWebSocket();
        socket.Options.SetRequestHeader("User-Agent", UserAgent);
        socket.Options.SetRequestHeader("Pragma", "no-cache");
        socket.Options.SetRequestHeader("Cache-Control", "no-cache");
        socket.Options.SetRequestHeader(
            "Origin", "chrome-extension://jdiccldimpdaibmpdkjnbmckianbfold");
        socket.Options.SetRequestHeader(
            "Cookie", $"muid={Convert.ToHexString(RandomNumberGenerator.GetBytes(16))};");
        await socket.ConnectAsync(uri, token);

        var timestamp = Timestamp();
        await SendTextAsync(socket,
            $"X-Timestamp:{timestamp}\r\n" +
            "Content-Type:application/json; charset=utf-8\r\n" +
            "Path:speech.config\r\n\r\n" +
            "{\"context\":{\"synthesis\":{\"audio\":{\"metadataoptions\":{" +
            "\"sentenceBoundaryEnabled\":\"false\",\"wordBoundaryEnabled\":\"false\"}," +
            "\"outputFormat\":\"audio-24khz-48kbitrate-mono-mp3\"}}}}\r\n", token);

        var escaped = SecurityElement.Escape(text) ?? "";
        var ssml =
            "<speak version='1.0' xmlns='http://www.w3.org/2001/10/synthesis' xml:lang='en-US'>" +
            $"<voice name='{voice}'><prosody pitch='+0Hz' rate='+8%' volume='+0%'>" +
            escaped + "</prosody></voice></speak>";
        await SendTextAsync(socket,
            $"X-RequestId:{Guid.NewGuid():N}\r\n" +
            "Content-Type:application/ssml+xml\r\n" +
            $"X-Timestamp:{Timestamp()}Z\r\n" +
            "Path:ssml\r\n\r\n" + ssml, token);

        using var audio = new MemoryStream();
        while (socket.State == WebSocketState.Open)
        {
            var message = await ReceiveMessageAsync(socket, token);
            if (message.Type == WebSocketMessageType.Close)
                break;
            if (message.Type == WebSocketMessageType.Text)
            {
                var response = Encoding.UTF8.GetString(message.Data);
                if (response.Contains("Path:turn.end", StringComparison.OrdinalIgnoreCase))
                    break;
                continue;
            }
            if (TryGetAudioPayload(message.Data, out var payload))
                await audio.WriteAsync(payload, token);
        }
        if (audio.Length == 0)
            throw new InvalidOperationException("Online neural TTS returned no audio.");
        return audio.ToArray();
    }

    internal static bool TryGetAudioPayload(byte[] message, out ReadOnlyMemory<byte> payload)
    {
        payload = default;
        if (message.Length < 4)
            return false;
        var headerLength = (message[0] << 8) | message[1];
        var payloadStart = headerLength + 2;
        if (payloadStart > message.Length)
            return false;
        var headers = Encoding.UTF8.GetString(message, 2, headerLength);
        if (!headers.Contains("Path:audio", StringComparison.OrdinalIgnoreCase))
            return false;
        payload = message.AsMemory(payloadStart);
        return payload.Length > 0;
    }

    private static async Task SendTextAsync(
        ClientWebSocket socket, string text, CancellationToken cancellationToken)
    {
        var data = Encoding.UTF8.GetBytes(text);
        await socket.SendAsync(data, WebSocketMessageType.Text, true, cancellationToken);
    }

    private static async Task<(WebSocketMessageType Type, byte[] Data)> ReceiveMessageAsync(
        ClientWebSocket socket, CancellationToken cancellationToken)
    {
        var buffer = new byte[16 * 1024];
        using var message = new MemoryStream();
        WebSocketReceiveResult result;
        do
        {
            result = await socket.ReceiveAsync(buffer, cancellationToken);
            if (result.Count > 0)
                await message.WriteAsync(buffer.AsMemory(0, result.Count), cancellationToken);
        } while (!result.EndOfMessage);
        return (result.MessageType, message.ToArray());
    }

    private static string Timestamp() =>
        DateTime.UtcNow.ToString(
            "ddd MMM dd yyyy HH:mm:ss 'GMT+0000 (Coordinated Universal Time)'",
            CultureInfo.InvariantCulture);

    public void Stop()
    {
        CancellationTokenSource? operation;
        WaveOutEvent? output;
        System.Media.SoundPlayer? promptPlayer;
        Process? process;
        TaskCompletionSource? resumeSignal;
        lock (_lock)
        {
            operation = _operation;
            output = _output;
            promptPlayer = _promptPlayer;
            process = _process;
            _paused = false;
            resumeSignal = _resumeSignal;
            _resumeSignal = null;
        }
        resumeSignal?.TrySetResult();
        try { operation?.Cancel(); }
        catch (ObjectDisposedException) { }
        try { output?.Stop(); }
        catch (ObjectDisposedException) { }
        try { promptPlayer?.Stop(); }
        catch (ObjectDisposedException) { }
        if (process is not null)
            StopProcess(process);
    }

    private void StopProcess(Process process)
    {
        if (process.HasExited)
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
