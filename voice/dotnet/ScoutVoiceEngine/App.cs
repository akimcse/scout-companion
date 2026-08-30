using System.Diagnostics;
using System.Runtime.InteropServices;
using System.Text.Json;

namespace ScoutVoiceEngine;

internal static class App
{
    public static async Task<int> RunAsync(string[] args)
    {
        if (args.Length == 2 && args[0] == "--probe")
            return Probe(args[1]);

        if (args.Length == 1 && args[0] == "--self-test")
            return await SelfTests.RunAsync();

        if (args.Length >= 1 && args[0] == "--enroll")
        {
            var options = EnrollmentOptions.Parse(args[1..]);
            return RunEnrollment(options);
        }

        if (args.Length >= 1 && args[0] == "--run")
        {
            var options = RunOptions.Parse(args[1..]);
            Directory.CreateDirectory(options.RuntimeDirectory);
            using var logger = new BoundedLogger(Path.Combine(options.RuntimeDirectory, "dotnet-voice.log"));
            using var mutex = new Mutex(true, MutexName(options.RuntimeDirectory), out var acquired);
            if (!acquired)
            {
                logger.Info("Another .NET voice engine instance is already running.");
                return 2;
            }

            var engine = new VoiceEngine(options, logger);
            await engine.RunAsync();
            return 0;
        }

        Console.Error.WriteLine(
            "Usage:\n" +
            "  ScoutVoiceEngine --probe <runtime-directory>\n" +
            "  ScoutVoiceEngine --self-test\n" +
            "  ScoutVoiceEngine --enroll --runtime-dir <dir> --language en|ko|ja|zh-Hans\n" +
            "  ScoutVoiceEngine --run --runtime-dir <dir> --language en|ko|ja|zh-Hans " +
            "--state-file <file> --stop-file <file> " +
            "--request-file <file> --response-file <file> --reply-enabled true|false " +
            "--wake-sensitivity 0-100 --noise-sensitivity 0-100 --parent-pid <pid>");
        return 2;
    }

    private static int RunEnrollment(EnrollmentOptions options)
    {
        var result = 1;
        Exception? failure = null;
        var thread = new Thread(() =>
        {
            try
            {
                using var logger = new BoundedLogger(
                    Path.Combine(options.RuntimeDirectory, "dotnet-voice.log"));
                using var form = new EnrollmentForm(options, logger);
                var application = new System.Windows.Application
                {
                    ShutdownMode = System.Windows.ShutdownMode.OnMainWindowClose,
                };
                application.Run(form);
                result = form.Completed ? 0 : 1;
            }
            catch (Exception exception)
            {
                failure = exception;
            }
        });
        thread.SetApartmentState(ApartmentState.STA);
        thread.Start();
        thread.Join();
        if (failure is not null)
            System.Runtime.ExceptionServices.ExceptionDispatchInfo.Capture(failure).Throw();
        return result;
    }

    private static string MutexName(string runtimeDirectory)
    {
        var hash = Convert.ToHexString(
            System.Security.Cryptography.SHA256.HashData(
                System.Text.Encoding.UTF8.GetBytes(Path.GetFullPath(runtimeDirectory).ToUpperInvariant())));
        return $@"Local\ScoutVoiceEngine.DotNet.{hash[..16]}";
    }

    private static int Probe(string runtimeDirectory)
    {
        using var models = new VoiceModels(Path.GetFullPath(runtimeDirectory), "ko", 35);
        Console.WriteLine(JsonSerializer.Serialize(new
        {
            ok = true,
            architecture = RuntimeInformation.ProcessArchitecture.ToString(),
            recognizer = "SenseVoice",
            vad = "Silero",
            speakerDimension = models.SpeakerDimension,
        }));
        return 0;
    }
}

internal sealed record RunOptions(
    string RuntimeDirectory,
    string Language,
    string StateFile,
    string StopFile,
    string RequestFile,
    string ResponseFile,
    bool ReplyEnabled,
    int WakeSensitivity,
    int NoiseSensitivity,
    int ParentPid)
{
    public static RunOptions Parse(string[] args)
    {
        var values = Arguments.Parse(args);
        var language = Arguments.Required(values, "--language");
        if (!LanguageResources.All.ContainsKey(language))
            throw new ArgumentException("--language must be en, ko, ja, or zh-Hans.");
        return new(
            Arguments.RequiredPath(values, "--runtime-dir"),
            language,
            Arguments.RequiredPath(values, "--state-file"),
            Arguments.RequiredPath(values, "--stop-file"),
            Arguments.RequiredPath(values, "--request-file"),
            Arguments.RequiredPath(values, "--response-file"),
            bool.Parse(Arguments.Required(values, "--reply-enabled")),
            Arguments.Percent(values, "--wake-sensitivity"),
            Arguments.Percent(values, "--noise-sensitivity"),
            int.Parse(Arguments.Required(values, "--parent-pid"),
                System.Globalization.CultureInfo.InvariantCulture));
    }
}

internal sealed record EnrollmentOptions(string RuntimeDirectory, string Language)
{
    public static EnrollmentOptions Parse(string[] args)
    {
        var values = Arguments.Parse(args);
        var language = Arguments.Required(values, "--language");
        if (!LanguageResources.All.ContainsKey(language))
            throw new ArgumentException("--language must be en, ko, ja, or zh-Hans.");
        return new(Arguments.RequiredPath(values, "--runtime-dir"), language);
    }
}

internal static class Arguments
{
    public static Dictionary<string, string> Parse(string[] args)
    {
        if (args.Length % 2 != 0)
            throw new ArgumentException("Every option must have a value.");
        var result = new Dictionary<string, string>(StringComparer.Ordinal);
        for (var i = 0; i < args.Length; i += 2)
        {
            if (!args[i].StartsWith("--", StringComparison.Ordinal))
                throw new ArgumentException($"Unexpected argument: {args[i]}");
            result[args[i]] = args[i + 1];
        }
        return result;
    }

    public static string Required(IReadOnlyDictionary<string, string> values, string name) =>
        values.TryGetValue(name, out var value) && !string.IsNullOrWhiteSpace(value)
            ? value
            : throw new ArgumentException($"Missing required option {name}.");

    public static string RequiredPath(IReadOnlyDictionary<string, string> values, string name) =>
        Path.GetFullPath(Required(values, name));

    public static int Percent(IReadOnlyDictionary<string, string> values, string name)
    {
        var value = int.Parse(Required(values, name), System.Globalization.CultureInfo.InvariantCulture);
        if (value is < 0 or > 100)
            throw new ArgumentOutOfRangeException(name, "Sensitivity must be between 0 and 100.");
        return value;
    }
}
