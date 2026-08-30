using System.Diagnostics;
using System.Text;
using System.Text.Json;
using System.Text.Json.Serialization;

namespace ScoutVoiceEngine;

internal static class Lifecycle
{
    public static async Task<bool> WaitWithinAsync(Task task, TimeSpan timeout)
    {
        using var timeoutCancellation = new CancellationTokenSource(timeout);
        try
        {
            await task.WaitAsync(timeoutCancellation.Token);
            return true;
        }
        catch (OperationCanceledException) when (timeoutCancellation.IsCancellationRequested)
        {
            return false;
        }
    }
}

internal sealed class BoundedLogger : IDisposable
{
    private const long MaximumBytes = 1_000_000;
    private readonly string _path;
    private StreamWriter _writer;
    private readonly object _lock = new();

    public BoundedLogger(string path)
    {
        _path = path;
        Directory.CreateDirectory(Path.GetDirectoryName(Path.GetFullPath(_path))!);
        Rotate(_path);
        _writer = OpenWriter();
    }

    private StreamWriter OpenWriter() =>
        new(new FileStream(_path, FileMode.Append, FileAccess.Write, FileShare.ReadWrite),
            new UTF8Encoding(false)) { AutoFlush = true };

    private static void Rotate(string path)
    {
        if (!File.Exists(path) || new FileInfo(path).Length < MaximumBytes)
            return;
        for (var index = 2; index >= 1; index--)
        {
            var source = $"{path}.{index}";
            var destination = $"{path}.{index + 1}";
            if (File.Exists(source))
                File.Move(source, destination, true);
        }
        File.Move(path, path + ".1", true);
    }

    public void Info(string message) => Write("INFO", message);
    public void Warning(string message) => Write("WARN", message);
    public void Error(string message, Exception exception) => Write("ERROR", $"{message}: {exception}");

    private void Write(string level, string message)
    {
        lock (_lock)
        {
            if (_writer.BaseStream.Length >= MaximumBytes)
            {
                _writer.Dispose();
                Rotate(_path);
                _writer = OpenWriter();
            }
            _writer.WriteLine($"{DateTimeOffset.Now:O} {level} {message}");
        }
    }

    public void Dispose() => _writer.Dispose();
}

internal sealed class VoiceState
{
    private readonly string _path;
    private readonly RuntimeMessages _messages;
    private readonly object _lock = new();
    private readonly Dictionary<string, object?> _data;
    private DateTimeOffset _activeUntil;

    public VoiceState(string path, RuntimeMessages messages)
    {
        _path = path;
        _messages = messages;
        _data = new Dictionary<string, object?>
        {
            ["active"] = false,
            ["stage"] = "starting",
            ["status"] = messages.Starting,
            ["command"] = "",
            ["answer"] = "",
        };
    }

    public void Publish()
    {
        lock (_lock)
        {
            _data["updatedAt"] = DateTimeOffset.UtcNow.ToUnixTimeMilliseconds() / 1000.0;
            AtomicFile.WriteJson(_path, _data);
        }
    }

    public void Wake()
    {
        lock (_lock)
        {
            Activate(TimeSpan.FromSeconds(30));
            _data["stage"] = "listening";
            _data["status"] = _messages.SpeakCommand;
            _data["command"] = "";
            _data["answer"] = "";
            PublishLocked();
        }
    }

    public void Command(string command)
    {
        lock (_lock)
        {
            Activate(TimeSpan.FromSeconds(120));
            _data["stage"] = "processing";
            _data["status"] = _messages.Processing;
            _data["command"] = command;
            _data["answer"] = "";
            PublishLocked();
        }
    }

    public void Answer(string answer)
    {
        lock (_lock)
        {
            Activate(TimeSpan.FromSeconds(120));
            _data["stage"] = "speaking";
            _data["status"] = _messages.Speaking;
            _data["answer"] = answer;
            PublishLocked();
        }
    }

    public void Transcript(string transcript)
    {
        lock (_lock)
        {
            if (!Equals(_data["active"], true))
                return;
            _data["transcript"] = transcript;
            PublishLocked();
        }
    }

    public void Status(string status, string stage = "idle")
    {
        lock (_lock)
        {
            _data["status"] = status;
            _data["stage"] = stage;
            if (stage is "processing" or "speaking")
                Activate(TimeSpan.FromSeconds(120));
            else if (stage == "listening")
                Activate(TimeSpan.FromSeconds(30));
            else if (Equals(_data["active"], true))
                _activeUntil = DateTimeOffset.UtcNow.AddSeconds(8);
            PublishLocked();
        }
    }

    public void Expire()
    {
        lock (_lock)
        {
            if (Equals(_data["active"], true) && Equals(_data["stage"], "idle") &&
                DateTimeOffset.UtcNow >= _activeUntil)
            {
                _data["active"] = false;
                _data["command"] = "";
                _data["answer"] = "";
                PublishLocked();
            }
        }
    }

    private void Activate(TimeSpan duration)
    {
        _data["active"] = true;
        _activeUntil = DateTimeOffset.UtcNow.Add(duration);
    }

    private void PublishLocked()
    {
        _data["updatedAt"] = DateTimeOffset.UtcNow.ToUnixTimeMilliseconds() / 1000.0;
        AtomicFile.WriteJson(_path, _data);
    }
}

internal sealed class ResponseBridge
{
    private readonly string _requestFile;
    private readonly string _responseFile;
    private readonly string _stopFile;

    public ResponseBridge(string requestFile, string responseFile, string stopFile)
    {
        _requestFile = requestFile;
        _responseFile = responseFile;
        _stopFile = stopFile;
    }

    public async Task<string> AskAsync(string command, TimeSpan timeout, CancellationToken cancellationToken)
    {
        var id = Guid.NewGuid().ToString();
        TryDelete(_responseFile);
        AtomicFile.WriteJson(_requestFile, new
        {
            id,
            command,
            createdAt = DateTimeOffset.UtcNow.ToUnixTimeMilliseconds() / 1000.0,
        });

        var deadline = DateTimeOffset.UtcNow.Add(timeout);
        while (DateTimeOffset.UtcNow < deadline)
        {
            cancellationToken.ThrowIfCancellationRequested();
            if (File.Exists(_stopFile))
                throw new OperationCanceledException("Voice control stopped.", cancellationToken);
            if (File.Exists(_responseFile))
            {
                try
                {
                    using var document = JsonDocument.Parse(await File.ReadAllTextAsync(_responseFile, cancellationToken));
                    var root = document.RootElement;
                    if (!root.TryGetProperty("id", out var responseId) || responseId.GetString() != id)
                    {
                        await Task.Delay(100, cancellationToken);
                        continue;
                    }
                    if (root.TryGetProperty("error", out var error) &&
                        error.ValueKind is not JsonValueKind.Null &&
                        !string.IsNullOrWhiteSpace(error.ToString()))
                        throw new InvalidOperationException(error.ToString());
                    var raw = root.TryGetProperty("answer", out var answer) ? answer.ToString().Trim() : "";
                    var cleaned = TextProcessing.CleanForSpeech(raw);
                    if (string.IsNullOrWhiteSpace(cleaned))
                        throw new InvalidOperationException("Scout returned an empty response.");
                    return cleaned;
                }
                catch (JsonException)
                {
                    // The bridge may still be completing its atomic write.
                }
                catch (IOException)
                {
                    // Retry transient file sharing races.
                }
            }
            await Task.Delay(100, cancellationToken);
        }
        throw new TimeoutException("Timed out waiting for the current Scout conversation.");
    }

    public static void TryDelete(string path)
    {
        try
        {
            File.Delete(path);
        }
        catch (FileNotFoundException)
        {
        }
    }
}
