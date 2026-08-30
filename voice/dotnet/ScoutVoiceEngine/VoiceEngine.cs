using System.Diagnostics;

namespace ScoutVoiceEngine;

internal sealed class VoiceEngine
{
    private readonly RunOptions _options;
    private readonly BoundedLogger _logger;
    private readonly VoiceState _state;
    private readonly ResponseBridge _bridge;
    private readonly LanguageResources _text;
    private readonly object _gate = new();
    private readonly List<Task> _backgroundTasks = [];
    private DateTimeOffset _awaitingCommandUntil;
    private DateTimeOffset _pendingUntil;
    private string? _pendingCommand;
    private CancellationTokenSource? _commandCancellation;
    private CancellationTokenSource? _speechCancellation;
    private volatile bool _speaking;
    private bool _awaitingWithRelaxedSpeakerThreshold;

    public VoiceEngine(RunOptions options, BoundedLogger logger)
    {
        _options = options;
        _logger = logger;
        _text = LanguageResources.All[options.Language];
        _state = new VoiceState(options.StateFile, _text.Runtime);
        _bridge = new ResponseBridge(options.RequestFile, options.ResponseFile, options.StopFile);
    }

    public async Task RunAsync()
    {
        using var cancellation = new CancellationTokenSource();
        Console.CancelKeyPress += OnCancel;
        void OnCancel(object? sender, ConsoleCancelEventArgs eventArgs)
        {
            eventArgs.Cancel = true;
            cancellation.Cancel();
        }

        VoiceModels? models = null;
        MicrophoneCapture? microphone = null;
        WindowsTts? tts = null;
        try
        {
            _state.Publish();
            var profile = VoiceProfile.Load(_options.RuntimeDirectory);
            var liveThreshold = Math.Min(profile.Threshold, 0.45f);
            models = new VoiceModels(
                _options.RuntimeDirectory, _text.ModelLanguage, _options.NoiseSensitivity);
            tts = new WindowsTts(_logger, _text.TtsCulture);
            microphone = new MicrophoneCapture(_logger);
            _logger.Info($"Voice engine ready threshold={profile.Threshold:F3}, liveThreshold={liveThreshold:F3}, " +
                         $"device='{microphone.DeviceName}'.");
            _state.Status(_text.Runtime.Waiting);
            microphone.Start();

            var monitor = MonitorLifetimeAsync(cancellation);
            var pending = new List<float>(models.VadWindowSize * 4);
            await foreach (var block in microphone.Blocks.ReadAllAsync(cancellation.Token))
            {
                pending.AddRange(block);
                while (pending.Count >= models.VadWindowSize)
                {
                    var window = pending.GetRange(0, models.VadWindowSize).ToArray();
                    pending.RemoveRange(0, models.VadWindowSize);
                    models.AcceptVad(window);
                }
                while (models.HasVadSegment)
                {
                    var segment = models.PopVadSegment();
                    if (segment.Length >= 0.65 * VoiceModels.SampleRate)
                        HandleSegment(segment, models, profile, liveThreshold, tts, cancellation.Token);
                }
                microphone.ThrowIfFailed();
            }
            await monitor;
        }
        catch (OperationCanceledException) when (cancellation.IsCancellationRequested)
        {
            _logger.Info("Voice engine stopping.");
        }
        catch (Exception exception)
        {
            _logger.Error("Voice engine failed", exception);
            throw;
        }
        finally
        {
            _logger.Info("Shutdown phase: canceling work.");
            Console.CancelKeyPress -= OnCancel;
            cancellation.Cancel();
            lock (_gate)
            {
                _commandCancellation?.Cancel();
                _speechCancellation?.Cancel();
            }
            tts?.Stop();
            Task[] tasks;
            lock (_gate)
                tasks = _backgroundTasks.ToArray();
            try
            {
                _logger.Info($"Shutdown phase: awaiting {tasks.Length} background task(s).");
                await Task.WhenAll(tasks);
            }
            catch (OperationCanceledException)
            {
            }
            _logger.Info("Shutdown phase: stopping microphone.");
            if (microphone is not null)
                await microphone.ShutdownAsync(TimeSpan.FromSeconds(2));
            _logger.Info("Shutdown phase: disposing TTS.");
            tts?.Dispose();
            _logger.Info("Shutdown phase: disposing voice models.");
            models?.Dispose();
            _logger.Info("Shutdown phase: cleaning bridge files.");
            CleanupBridgeFiles();
            _logger.Info("Shutdown complete.");
        }
    }

    private async Task MonitorLifetimeAsync(CancellationTokenSource cancellation)
    {
        Process? parent = null;
        try
        {
            parent = Process.GetProcessById(_options.ParentPid);
        }
        catch (ArgumentException)
        {
            cancellation.Cancel();
            return;
        }
        using (parent)
        {
            while (!cancellation.IsCancellationRequested)
            {
                _state.Expire();
                if (File.Exists(_options.StopFile) || parent.HasExited)
                {
                    cancellation.Cancel();
                    return;
                }
                try
                {
                    await Task.Delay(250, cancellation.Token);
                }
                catch (OperationCanceledException)
                {
                    return;
                }
            }
        }
    }

    private void HandleSegment(
        float[] samples,
        VoiceModels models,
        VoiceProfile profile,
        float liveThreshold,
        WindowsTts tts,
        CancellationToken stoppingToken)
    {
        var text = models.Transcribe(samples);
        if (string.IsNullOrWhiteSpace(text))
            return;
        var displayText = TextProcessing.CanonicalizeWakeForDisplay(
            text, _options.Language, _options.WakeSensitivity);
        var (verified, score) = Verify(samples, models, profile, liveThreshold);
        _logger.Info(
            $"Segment language={_options.Language}, speakerScore={score:F3}, " +
            $"verified={verified}, text='{Truncate(displayText, 100)}'.");
        _state.Transcript(displayText);
        var now = DateTimeOffset.UtcNow;

        if (_speaking)
        {
            var wake = TextProcessing.SplitWakeCommand(
                text, _options.WakeSensitivity, prefixOnly: true);
            if (wake.Detected)
            {
                _logger.Info("Explicit wake phrase interrupted TTS.");
                lock (_gate)
                    _speechCancellation?.Cancel();
                tts.Stop();
                _state.Wake();
                if (TextProcessing.HasMeaningfulCommand(wake.Command) &&
                    AcceptSpeaker(verified, score, afterInterrupt: true))
                {
                    _awaitingWithRelaxedSpeakerThreshold = false;
                    DispatchCommand(wake.Command, false, tts, stoppingToken);
                }
                else
                {
                    _awaitingWithRelaxedSpeakerThreshold = true;
                    _awaitingCommandUntil = now.AddSeconds(10);
                }
            }
            return;
        }

        if (_pendingCommand is not null && now <= _pendingUntil)
        {
            if (!verified)
            {
                _logger.Warning($"Rejected unverified confirmation score={score:F3}.");
                return;
            }
            if (TextProcessing.IsConfirmation(text))
            {
                var command = _pendingCommand;
                _pendingCommand = null;
                DispatchCommand(command, true, tts, stoppingToken);
            }
            else if (TextProcessing.IsCancellation(text))
            {
                _pendingCommand = null;
                Track(SpeakStatusAsync(_text.Runtime.Canceled, tts, stoppingToken));
            }
            return;
        }
        _pendingCommand = null;

        if (now <= _awaitingCommandUntil)
        {
            var wake = TextProcessing.SplitWakeCommand(text, _options.WakeSensitivity);
            if (wake.Detected && !TextProcessing.HasMeaningfulCommand(wake.Command))
            {
                _awaitingCommandUntil = now.AddSeconds(10);
                _state.Status(_text.Runtime.SpeakCommand, "listening");
                return;
            }
            _awaitingCommandUntil = DateTimeOffset.MinValue;
            if (!AcceptSpeaker(verified, score, _awaitingWithRelaxedSpeakerThreshold))
            {
                _logger.Warning($"Rejected unverified command score={score:F3}.");
                Track(SpeakStatusAsync(_text.Runtime.UnverifiedSpeaker, tts, stoppingToken));
                _awaitingWithRelaxedSpeakerThreshold = false;
                return;
            }
            _awaitingWithRelaxedSpeakerThreshold = false;
            DispatchCommand(wake.Detected ? wake.Command : text, false, tts, stoppingToken);
            return;
        }

        var detected = TextProcessing.SplitWakeCommand(text, _options.WakeSensitivity);
        if (!detected.Detected)
            return;
        _state.Wake();
        if (!TextProcessing.HasMeaningfulCommand(detected.Command))
        {
            _awaitingWithRelaxedSpeakerThreshold = true;
            _awaitingCommandUntil = now.AddSeconds(10);
            return;
        }
        if (!verified)
        {
            _logger.Warning($"Rejected unverified wake command score={score:F3}.");
            Track(SpeakStatusAsync(_text.Runtime.UnverifiedSpeaker, tts, stoppingToken));
            return;
        }
        DispatchCommand(detected.Command, false, tts, stoppingToken);
    }

    private static (bool Verified, float Score) Verify(
        float[] samples, VoiceModels models, VoiceProfile profile, float threshold)
    {
        try
        {
            var score = VoiceProfile.Cosine(models.Embedding(samples), profile.Embedding);
            return (score >= threshold, score);
        }
        catch (ArgumentException)
        {
            return (false, 0);
        }
    }

    internal static bool AcceptSpeaker(bool verified, float score, bool afterInterrupt) =>
        verified || (afterInterrupt && score >= 0.35f);

    private void DispatchCommand(
        string command, bool confirmed, WindowsTts tts, CancellationToken stoppingToken)
    {
        command = TextProcessing.CorrectCommonRecognition(command, _options.Language).Trim();
        if (string.IsNullOrWhiteSpace(command))
        {
            Track(SpeakStatusAsync(_text.Runtime.NoCommand, tts, stoppingToken));
            return;
        }
        if (!confirmed && TextProcessing.IsRiskyCommand(command))
        {
            _pendingCommand = command;
            _pendingUntil = DateTimeOffset.UtcNow.AddSeconds(25);
            _state.Status(_text.Runtime.ConfirmationWaiting, "processing");
            Track(SpeakStatusAsync(
                string.Format(_text.Runtime.ConfirmationPrompt, command),
                tts, stoppingToken));
            return;
        }

        CancellationTokenSource commandCancellation;
        lock (_gate)
        {
            _commandCancellation?.Cancel();
            _commandCancellation?.Dispose();
            commandCancellation = CancellationTokenSource.CreateLinkedTokenSource(stoppingToken);
            _commandCancellation = commandCancellation;
        }
        Track(ExecuteCommandAsync(command, tts, commandCancellation));
    }

    private void Track(Task task)
    {
        lock (_gate)
            _backgroundTasks.Add(task);
        _ = task.ContinueWith(completed =>
        {
            lock (_gate)
                _backgroundTasks.Remove(completed);
        }, CancellationToken.None, TaskContinuationOptions.ExecuteSynchronously, TaskScheduler.Default);
    }

    private async Task ExecuteCommandAsync(
        string command, WindowsTts tts, CancellationTokenSource cancellation)
    {
        try
        {
            PlayCommandAcceptedSound();
            _state.Command(command);
            var answer = await _bridge.AskAsync(command, TimeSpan.FromMinutes(10), cancellation.Token);
            _state.Answer(answer);
            if (_options.ReplyEnabled)
                await SpeakAsync(answer, tts, cancellation.Token);
            else
                _state.Status(_text.Runtime.Waiting);
        }
        catch (OperationCanceledException) when (cancellation.IsCancellationRequested)
        {
            _logger.Info("Superseded or stopped command.");
        }
        catch (Exception exception)
        {
            _logger.Error("Voice command failed", exception);
            await SpeakStatusAsync(_text.Runtime.Failed, tts,
                cancellation.Token);
        }
    }

    private void PlayCommandAcceptedSound()
    {
        try
        {
            var soundPath = Path.Combine(AppContext.BaseDirectory, "scout-listening.wav");
            if (!File.Exists(soundPath))
                throw new FileNotFoundException("Command sound is missing.", soundPath);
            using var player = new System.Media.SoundPlayer(soundPath);
            player.PlaySync();
            _logger.Info("Played command accepted sound.");
        }
        catch (Exception exception)
        {
            _logger.Error("Command accepted sound failed", exception);
        }
    }

    private async Task SpeakStatusAsync(string text, WindowsTts tts, CancellationToken cancellationToken)
    {
        try
        {
            if (_options.ReplyEnabled)
                await SpeakAsync(text, tts, cancellationToken);
            else
                _state.Status(_text.Runtime.Waiting);
        }
        catch (OperationCanceledException)
        {
            _logger.Info("TTS status message interrupted.");
        }
        catch (Exception exception)
        {
            _logger.Error("TTS status message failed", exception);
            _state.Status(_text.Runtime.Waiting);
        }
    }

    private async Task SpeakAsync(string text, WindowsTts tts, CancellationToken cancellationToken)
    {
        CancellationTokenSource speechCancellation;
        lock (_gate)
        {
            _speechCancellation?.Cancel();
            _speechCancellation?.Dispose();
            speechCancellation = CancellationTokenSource.CreateLinkedTokenSource(cancellationToken);
            _speechCancellation = speechCancellation;
        }
        _speaking = true;
        _state.Status(_text.Runtime.Speaking, "speaking");
        try
        {
            await tts.SpeakAsync(text, speechCancellation.Token);
        }
        catch (OperationCanceledException) when (speechCancellation.IsCancellationRequested)
        {
            _logger.Info("TTS answer interrupted by wake phrase.");
        }
        finally
        {
            _speaking = false;
            if (!speechCancellation.IsCancellationRequested)
                _state.Status(_text.Runtime.Waiting);
        }
    }

    private void CleanupBridgeFiles()
    {
        foreach (var path in new[]
                 {
                     _options.StateFile, _options.StateFile + ".tmp",
                     _options.StopFile,
                     _options.RequestFile, _options.RequestFile + ".tmp",
                     _options.ResponseFile, _options.ResponseFile + ".tmp",
                 })
        {
            try
            {
                File.Delete(path);
            }
            catch (IOException exception)
            {
                _logger.Error($"Failed to remove bridge file '{path}'", exception);
            }
            catch (UnauthorizedAccessException exception)
            {
                _logger.Error($"Failed to remove bridge file '{path}'", exception);
            }
        }
    }

    private static string Truncate(string value, int length) =>
        value.Length <= length ? value : value[..length];
}
