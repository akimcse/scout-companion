using System.Text.Json;

namespace ScoutVoiceEngine;

internal static class SelfTests
{
    public static async Task<int> RunAsync()
    {
        var tests = new (string Name, Func<Task> Run)[]
        {
            ("text normalization", () => Sync(() =>
                Equal("heyscout東京일정", TextProcessing.Normalize("<|ko|> Hey, Scout! 東京 일정")))),
            ("wake splitting and sensitivity", () => Sync(TestWake)),
            ("Korean command recognition correction", () => Sync(TestKoreanCommandCorrection)),
            ("cosine similarity and profile serialization", () => Sync(TestProfile)),
            ("risky command detection", () => Sync(TestRisk)),
            ("language resources completeness", () => Sync(TestLanguages)),
            ("run language configuration", () => Sync(TestRunLanguage)),
            ("localized voice state", () => Sync(TestLocalizedState)),
            ("interrupt speaker threshold", () => Sync(TestInterruptSpeakerThreshold)),
            ("audible TTS volume", () => Sync(TestTtsVolume)),
            ("bounded lifecycle shutdown", TestBoundedShutdownAsync),
            ("response bridge protocol", TestBridgeAsync),
        };

        var failures = 0;
        foreach (var test in tests)
        {
            try
            {
                await test.Run();
                Console.WriteLine($"PASS {test.Name}");
            }
            catch (Exception exception)
            {
                failures++;
                Console.Error.WriteLine($"FAIL {test.Name}: {exception.Message}");
            }
        }
        Console.WriteLine($"{tests.Length - failures}/{tests.Length} self-tests passed.");
        return failures == 0 ? 0 : 1;
    }

    private static Task Sync(Action action)
    {
        action();
        return Task.CompletedTask;
    }

    private static void TestWake()
    {
        var korean = TextProcessing.SplitWakeCommand("헤이 스카웃, 오늘 일정 알려줘", 65);
        True(korean.Detected && korean.Command == "오늘 일정 알려줘", "Korean wake");
        var english = TextProcessing.SplitWakeCommand("Hey Scout, weather", 65);
        True(english.Detected && english.Command == "weather", "English wake");
        True(TextProcessing.SplitWakeCommand("ヘイ スカウト、予定を教えて", 65).Detected,
            "Japanese wake");
        var mixed = TextProcessing.SplitWakeCommand("헤이스웃 다음 주 일정 알려줘", 85);
        True(mixed.Detected && mixed.Command.Contains("다음주일정알려줘"),
            $"mixed TTS wake: detected={mixed.Detected}, command={mixed.Command}");
        True(!TextProcessing.SplitWakeCommand(
            "월요일 일정 중 헤이스카웃 비슷한 소리", 85, prefixOnly: true).Detected,
            "mid-answer wake text");
        var mixedScriptWake = TextProcessing.SplitWakeCommand("ヘ이スカ웃？", 85);
        True(mixedScriptWake.Detected &&
             !TextProcessing.HasMeaningfulCommand(mixedScriptWake.Command),
            $"mixed-script wake residue: {mixedScriptWake.Command}");
        Equal("헤이 스카웃", TextProcessing.CanonicalizeWakeForDisplay(
            "へイスカ？", "ko", 85));
        Equal("へイスカ？", TextProcessing.CanonicalizeWakeForDisplay(
            "へイスカ？", "ja", 85));
        True(TextProcessing.SplitWakeCommand("嘿 Scout，查看日程", 65).Detected,
            "Chinese wake");
        True(!TextProcessing.SplitWakeCommand("heyscotx", 0).Detected, "strict fuzzy wake");
        True(TextProcessing.SplitWakeCommand("heyscotx", 100).Detected, "tolerant fuzzy wake");
        True(!TextProcessing.SplitWakeCommand("ambient conversation", 100).Detected,
            "ambient speech");
    }

    private static void TestProfile()
    {
        Equal(0f, VoiceProfile.Cosine([1, 0], [0, 1]), 0.0001f);
        Equal(1f, VoiceProfile.Cosine([2, 0], [1, 0]), 0.0001f);
        var profile = VoiceProfile.Create([[1, 0], [0.99f, 0.01f], [0.98f, 0.02f]]);
        Equal(3, profile.PhraseCount);
        True(profile.Threshold is >= 0.55f and <= 0.60f);

        var directory = Path.Combine(AppContext.BaseDirectory, $"self-test-{Guid.NewGuid():N}");
        try
        {
            profile.Save(directory);
            var loaded = VoiceProfile.Load(directory);
            Equal(profile.PhraseCount, loaded.PhraseCount);
            Equal(profile.Embedding.Length, loaded.Embedding.Length);
            Equal(profile.Threshold, loaded.Threshold, 0.0001f);
        }
        finally
        {
            if (Directory.Exists(directory))
                Directory.Delete(directory, true);
        }
    }

    private static void TestRisk()
    {
        True(TextProcessing.IsRiskyCommand("파일을 삭제해"));
        True(TextProcessing.IsRiskyCommand("send this email"));
        True(TextProcessing.IsRiskyCommand("予定をキャンセル"));
        True(TextProcessing.IsRiskyCommand("删除这个文件"));
        True(TextProcessing.IsRiskyCommand("请转账并发送"));
        True(TextProcessing.IsConfirmation("确认并执行"));
        True(TextProcessing.IsConfirmation("確認並執行"));
        True(TextProcessing.IsCancellation("取消"));
        True(!TextProcessing.IsRiskyCommand("오늘 일정 알려줘"));
    }

    private static void TestInterruptSpeakerThreshold()
    {
        True(!VoiceEngine.AcceptSpeaker(false, 0.42f, false),
            "normal commands keep the enrolled threshold");
        True(VoiceEngine.AcceptSpeaker(false, 0.384f, true),
            "barge-in commands allow speech mixed with TTS");
        True(!VoiceEngine.AcceptSpeaker(false, 0.34f, true),
            "barge-in still rejects low-confidence speakers");
    }

    private static void TestKoreanCommandCorrection()
    {
        Equal("지금 몇 시야?", TextProcessing.CorrectCommonRecognition("지금 몇.", "ko"));
        Equal("지금 몇 시야?", TextProcessing.CorrectCommonRecognition("지금 몇야?", "ko"));
        Equal("지금 몇 시야?", TextProcessing.CorrectCommonRecognition("지금 러시아.", "ko"));
        Equal("지금 러시아 상황 알려줘",
            TextProcessing.CorrectCommonRecognition("지금 러시아 상황 알려줘", "ko"));
        Equal("지금 러시아.", TextProcessing.CorrectCommonRecognition("지금 러시아.", "en"));
    }

    private static void TestTtsVolume()
    {
        Equal(70, WindowsTts.ConfiguredVolume);
    }

    private static void TestLanguages()
    {
        Equal(4, LanguageResources.All.Count);
        foreach (var key in new[] { "en", "ko", "ja", "zh-Hans" })
        {
            True(LanguageResources.All.TryGetValue(key, out var text));
            Equal(5, text!.Phrases.Length);
            True(!string.IsNullOrWhiteSpace(text.ModelLanguage));
            True(!string.IsNullOrWhiteSpace(text.TtsCulture));
            True(text.GetType().GetProperties()
                .Where(property => property.PropertyType == typeof(string))
                .All(property => !string.IsNullOrWhiteSpace((string?)property.GetValue(text))));
            True(text.Runtime.GetType().GetProperties()
                .All(property => !string.IsNullOrWhiteSpace(
                    (string?)property.GetValue(text.Runtime))));
        }
    }

    private static void TestRunLanguage()
    {
        var options = RunOptions.Parse(
        [
            "--runtime-dir", ".",
            "--language", "ja",
            "--state-file", "state.json",
            "--stop-file", "stop",
            "--request-file", "request.json",
            "--response-file", "response.json",
            "--reply-enabled", "false",
            "--wake-sensitivity", "65",
            "--noise-sensitivity", "35",
            "--parent-pid", "123",
        ]);
        Equal("ja", options.Language);
        Equal("ja", LanguageResources.All[options.Language].ModelLanguage);
        Equal("ja-JP", LanguageResources.All[options.Language].TtsCulture);

        var missingLanguage = false;
        try
        {
            _ = RunOptions.Parse(
            [
                "--runtime-dir", ".",
                "--state-file", "state.json",
                "--stop-file", "stop",
                "--request-file", "request.json",
                "--response-file", "response.json",
                "--reply-enabled", "false",
                "--wake-sensitivity", "65",
                "--noise-sensitivity", "35",
                "--parent-pid", "123",
            ]);
        }
        catch (ArgumentException)
        {
            missingLanguage = true;
        }
        True(missingLanguage);
    }

    private static void TestLocalizedState()
    {
        var directory = Path.Combine(AppContext.BaseDirectory, $"self-test-{Guid.NewGuid():N}");
        Directory.CreateDirectory(directory);
        var path = Path.Combine(directory, "state.json");
        try
        {
            var resources = LanguageResources.All["zh-Hans"].Runtime;
            var state = new VoiceState(path, resources);
            state.Publish();
            using (var initial = JsonDocument.Parse(File.ReadAllText(path)))
                Equal(resources.Starting, initial.RootElement.GetProperty("status").GetString()!);
            state.Wake();
            using var awake = JsonDocument.Parse(File.ReadAllText(path));
            Equal(resources.SpeakCommand, awake.RootElement.GetProperty("status").GetString()!);
        }
        finally
        {
            Directory.Delete(directory, true);
        }
    }

    private static async Task TestBridgeAsync()
    {
        var directory = Path.Combine(AppContext.BaseDirectory, $"self-test-{Guid.NewGuid():N}");
        Directory.CreateDirectory(directory);
        var request = Path.Combine(directory, "request.json");
        var response = Path.Combine(directory, "response.json");
        var stop = Path.Combine(directory, "stop");
        try
        {
            var bridge = new ResponseBridge(request, response, stop);
            var responder = Task.Run(async () =>
            {
                while (!File.Exists(request))
                    await Task.Delay(10);
                using var document = JsonDocument.Parse(await File.ReadAllTextAsync(request));
                var root = document.RootElement;
                AtomicFile.WriteJson(response, new
                {
                    id = root.GetProperty("id").GetString(),
                    answer = "**Hello** [Scout](https://example.com)",
                });
            });
            var answer = await bridge.AskAsync("test", TimeSpan.FromSeconds(5), CancellationToken.None);
            await responder;
            Equal("Hello Scout", answer);
        }

        finally
        {
            if (Directory.Exists(directory))
                Directory.Delete(directory, true);
        }
    }

    private static async Task TestBoundedShutdownAsync()
    {
        var neverCompletes = new TaskCompletionSource(
            TaskCreationOptions.RunContinuationsAsynchronously);
        var stopwatch = System.Diagnostics.Stopwatch.StartNew();
        var completed = await Lifecycle.WaitWithinAsync(
            neverCompletes.Task, TimeSpan.FromMilliseconds(75));
        stopwatch.Stop();
        True(!completed);
        True(stopwatch.Elapsed < TimeSpan.FromSeconds(1));

        completed = await Lifecycle.WaitWithinAsync(
            Task.CompletedTask, TimeSpan.FromSeconds(1));
        True(completed);
    }

    private static void True(bool value, string? message = null)
    {
        if (!value)
            throw new InvalidOperationException(message ?? "Assertion failed.");
    }

    private static void Equal<T>(T expected, T actual) where T : IEquatable<T>
    {
        if (!expected.Equals(actual))
            throw new InvalidOperationException($"Expected '{expected}', got '{actual}'.");
    }

    private static void Equal(float expected, float actual, float tolerance)
    {
        if (Math.Abs(expected - actual) > tolerance)
            throw new InvalidOperationException($"Expected '{expected}', got '{actual}'.");
    }
}
