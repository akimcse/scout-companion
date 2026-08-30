using System.Buffers.Binary;
using System.Threading.Channels;
using NAudio.CoreAudioApi;
using NAudio.Wave;

namespace ScoutVoiceEngine;

internal sealed class MicrophoneCapture : IDisposable
{
    private readonly WasapiCapture _capture;
    private readonly Channel<float[]> _blocks = Channel.CreateBounded<float[]>(
        new BoundedChannelOptions(64)
        {
            SingleReader = true,
            SingleWriter = true,
            FullMode = BoundedChannelFullMode.DropOldest,
        });
    private readonly StreamingResampler _resampler;
    private readonly BoundedLogger _logger;
    private readonly TaskCompletionSource _recordingStopped =
        new(TaskCreationOptions.RunContinuationsAsynchronously);
    private Task<bool>? _shutdownTask;
    private Exception? _captureError;
    private volatile bool _shuttingDown;

    public MicrophoneCapture(BoundedLogger logger)
    {
        _logger = logger;
        using var enumerator = new MMDeviceEnumerator();
        var devices = enumerator.EnumerateAudioEndPoints(DataFlow.Capture, DeviceState.Active);
        var defaultId = enumerator.GetDefaultAudioEndpoint(DataFlow.Capture, Role.Communications).ID;
        var selected = devices
            .Select(device => (Device: device, Score: Score(device, defaultId)))
            .OrderByDescending(item => item.Score)
            .ThenBy(item => item.Device.FriendlyName, StringComparer.OrdinalIgnoreCase)
            .FirstOrDefault();
        if (selected.Device is null)
            throw new InvalidOperationException("No active microphone was found.");

        DeviceName = selected.Device.FriendlyName;
        _capture = new WasapiCapture(selected.Device);
        _resampler = new StreamingResampler(_capture.WaveFormat);
        _capture.DataAvailable += OnDataAvailable;
        _capture.RecordingStopped += OnRecordingStopped;
        logger.Info($"Selected WASAPI microphone '{DeviceName}', format={_capture.WaveFormat}.");
    }

    public string DeviceName { get; }
    public ChannelReader<float[]> Blocks => _blocks.Reader;

    public void Start() => _capture.StartRecording();

    public void RequestStop()
    {
        _shuttingDown = true;
        _blocks.Writer.TryComplete();
        if (_capture.CaptureState != CaptureState.Stopped)
            _capture.StopRecording();
        else
            _recordingStopped.TrySetResult();
    }

    public Task<bool> ShutdownAsync(TimeSpan timeout)
    {
        lock (_capture)
            return _shutdownTask ??= ShutdownCoreAsync(timeout);
    }

    private async Task<bool> ShutdownCoreAsync(TimeSpan timeout)
    {
        RequestStop();
        if (!await Lifecycle.WaitWithinAsync(_recordingStopped.Task, timeout))
        {
            _logger.Warning(
                $"WASAPI microphone did not stop within {timeout.TotalSeconds:F1}s; " +
                "skipping NAudio Dispose to avoid its unbounded capture-thread join.");
            _capture.DataAvailable -= OnDataAvailable;
            _capture.RecordingStopped -= OnRecordingStopped;
            return false;
        }

        _capture.DataAvailable -= OnDataAvailable;
        _capture.RecordingStopped -= OnRecordingStopped;
        _capture.Dispose();
        return true;
    }

    private void OnRecordingStopped(object? sender, StoppedEventArgs eventArgs)
    {
        if (eventArgs.Exception is not null)
            _captureError = eventArgs.Exception;
        _blocks.Writer.TryComplete(eventArgs.Exception);
        _recordingStopped.TrySetResult();
    }

    private static int Score(MMDevice device, string defaultId)
    {
        var name = device.FriendlyName;
        var score = 100;
        if (name.Contains("Microphone Array", StringComparison.OrdinalIgnoreCase))
            score += 30;
        if (name.Contains("Qualcomm", StringComparison.OrdinalIgnoreCase) ||
            name.Contains("Aqstic", StringComparison.OrdinalIgnoreCase))
            score += 20;
        if (name.Contains("Headset", StringComparison.OrdinalIgnoreCase))
            score -= 20;
        if (device.ID == defaultId)
            score += 5;
        return score;
    }

    private void OnDataAvailable(object? sender, WaveInEventArgs args)
    {
        if (_shuttingDown)
            return;
        try
        {
            var samples = _resampler.Convert(args.Buffer.AsSpan(0, args.BytesRecorded));
            const int blockSize = 1_600;
            for (var offset = 0; offset < samples.Length; offset += blockSize)
            {
                var length = Math.Min(blockSize, samples.Length - offset);
                var block = new float[length];
                Array.Copy(samples, offset, block, 0, length);
                _blocks.Writer.TryWrite(block);
            }
        }
        catch (Exception exception)
        {
            _captureError = exception;
            _blocks.Writer.TryComplete(exception);
        }
    }

    public void ThrowIfFailed()
    {
        if (_captureError is not null)
            throw new InvalidOperationException("Microphone capture failed.", _captureError);
    }

    public void Dispose()
    {
        _ = ShutdownAsync(TimeSpan.FromSeconds(2)).GetAwaiter().GetResult();
    }
}

internal sealed class StreamingResampler
{
    private readonly WaveFormat _format;
    private readonly List<float> _source = [];
    private double _position;

    public StreamingResampler(WaveFormat format)
    {
        if (format.Channels <= 0 || format.SampleRate <= 0)
            throw new ArgumentException("The microphone format is invalid.", nameof(format));
        _format = format;
    }

    public float[] Convert(ReadOnlySpan<byte> bytes)
    {
        var bytesPerSample = _format.BitsPerSample / 8;
        var bytesPerFrame = bytesPerSample * _format.Channels;
        var frames = bytes.Length / bytesPerFrame;
        for (var frame = 0; frame < frames; frame++)
        {
            double sum = 0;
            for (var channel = 0; channel < _format.Channels; channel++)
            {
                var offset = (frame * bytesPerFrame) + (channel * bytesPerSample);
                sum += ReadSample(bytes.Slice(offset, bytesPerSample));
            }
            _source.Add((float)(sum / _format.Channels));
        }

        var output = new List<float>((int)(frames * (VoiceModels.SampleRate / (double)_format.SampleRate)) + 2);
        var step = _format.SampleRate / (double)VoiceModels.SampleRate;
        while (_position + 1 < _source.Count)
        {
            var lower = (int)_position;
            var fraction = _position - lower;
            output.Add((float)(_source[lower] + ((_source[lower + 1] - _source[lower]) * fraction)));
            _position += step;
        }
        var consumed = Math.Max(0, Math.Min((int)_position, _source.Count - 1));
        if (consumed > 0)
        {
            _source.RemoveRange(0, consumed);
            _position -= consumed;
        }
        return output.ToArray();
    }

    private float ReadSample(ReadOnlySpan<byte> bytes)
    {
        var isFloat = _format.Encoding == WaveFormatEncoding.IeeeFloat ||
                      (_format.Encoding == WaveFormatEncoding.Extensible && _format.BitsPerSample == 32);
        if (isFloat && bytes.Length == 4)
            return BitConverter.Int32BitsToSingle(BinaryPrimitives.ReadInt32LittleEndian(bytes));
        return bytes.Length switch
        {
            2 => BinaryPrimitives.ReadInt16LittleEndian(bytes) / 32768f,
            3 => ReadInt24(bytes) / 8388608f,
            4 => BinaryPrimitives.ReadInt32LittleEndian(bytes) / 2147483648f,
            _ => throw new NotSupportedException($"Unsupported microphone format: {_format}"),
        };
    }

    private static int ReadInt24(ReadOnlySpan<byte> bytes)
    {
        var value = bytes[0] | (bytes[1] << 8) | (bytes[2] << 16);
        return (value & 0x800000) != 0 ? value | unchecked((int)0xFF000000) : value;
    }
}

internal static class UtteranceRecorder
{
    public static async Task<float[]> RecordAsync(
        BoundedLogger logger,
        CancellationToken cancellationToken,
        double maxSeconds = 10,
        double minSeconds = 1.4,
        double silenceSeconds = 0.9)
    {
        var microphone = new MicrophoneCapture(logger);
        var preRoll = new Queue<float[]>();
        var captured = new List<float>();
        var speechStarted = false;
        var silentSamples = 0;
        microphone.Start();
        try
        {
            var deadline = DateTimeOffset.UtcNow.AddSeconds(maxSeconds);
            await foreach (var block in microphone.Blocks.ReadAllAsync(cancellationToken))
            {
                if (DateTimeOffset.UtcNow >= deadline)
                    break;
                var rms = Math.Sqrt(block.Select(value => value * value).Average() + 1e-12);
                if (!speechStarted)
                {
                    preRoll.Enqueue(block);
                    while (preRoll.Count > 3)
                        preRoll.Dequeue();
                    if (rms >= 0.012)
                    {
                        speechStarted = true;
                        foreach (var item in preRoll)
                            captured.AddRange(item);
                    }
                }
                else
                {
                    captured.AddRange(block);
                    silentSamples = rms < 0.009 ? silentSamples + block.Length : 0;
                    if (captured.Count >= minSeconds * VoiceModels.SampleRate &&
                        silentSamples >= silenceSeconds * VoiceModels.SampleRate)
                        break;
                }
            }
        }
        finally
        {
            await microphone.ShutdownAsync(TimeSpan.FromSeconds(2));
        }
        microphone.ThrowIfFailed();
        if (!speechStarted)
            throw new InvalidOperationException("No speech was detected.");
        if (captured.Count < minSeconds * VoiceModels.SampleRate)
            throw new InvalidOperationException("The recording is too short.");
        return captured.ToArray();
    }
}
