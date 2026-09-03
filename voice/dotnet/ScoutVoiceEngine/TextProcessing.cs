using System.Text;
using System.Text.RegularExpressions;

namespace ScoutVoiceEngine;

internal static partial class TextProcessing
{
    private static readonly string[] WakeVariants =
    [
        "헤이스카웃", "헤이스카우트", "헤이스카우", "에이스카웃", "에이스카우트",
        "해이스카웃", "헤이스웃", "헤이웃", "스카웃", "스카우트", "스카우", "heyscout",
        "へイスカウト", "へイスカ", "ヘイスカウト", "ヘイスカ", "嘿scout", "嗨scout"
    ];

    [GeneratedRegex(@"<\|.*?\|>", RegexOptions.CultureInvariant)]
    private static partial Regex ModelTagRegex();

    [GeneratedRegex(@"[^0-9a-zA-Z가-힣ぁ-んァ-ヶ一-鿿]+", RegexOptions.CultureInvariant)]
    private static partial Regex NonSpeechTextRegex();

    [GeneratedRegex(@"(?:헤이\s*)?스카(?:웃|우트|우)(?:아|야)?", RegexOptions.IgnoreCase)]
    private static partial Regex KoreanWakeRegex();

    [GeneratedRegex(@"^헤이\s*스카(?:웃|우트|우)(?:아|야)?", RegexOptions.IgnoreCase)]
    private static partial Regex ExplicitKoreanWakeRegex();

    [GeneratedRegex(@"hey\s+scout", RegexOptions.IgnoreCase)]
    private static partial Regex EnglishWakeRegex();

    [GeneratedRegex(@"(?:ヘイ|へイ)\s*スカウト", RegexOptions.IgnoreCase)]
    private static partial Regex JapaneseWakeRegex();

    [GeneratedRegex(@"(?:嘿|嗨)\s*scout", RegexOptions.IgnoreCase)]
    private static partial Regex ChineseWakeRegex();

    [GeneratedRegex(@"삭제|지워|송금|이체|결제|구매|주문|보내|전송|공유|취소|예약|승인|거절|설치|제거|종료|재부팅|권한|" +
                    @"\b(delete|erase|transfer|pay|purchase|buy|order|send|share|cancel|book|approve|reject|install|uninstall|shutdown|reboot|permission)\b|" +
                    @"削除|消して|送金|振込|支払|購入|注文|送信|共有|取消|キャンセル|予約|承認|拒否|インストール|終了|再起動|権限|" +
                    @"删除|清除|转账|汇款|支付|购买|下单|发送|分享|取消|预订|批准|拒绝|安装|卸载|关机|重启|权限",
        RegexOptions.IgnoreCase | RegexOptions.CultureInvariant)]
    private static partial Regex RiskyRegex();

    [GeneratedRegex(@"```.*?```", RegexOptions.Singleline)]
    private static partial Regex CodeBlockRegex();

    [GeneratedRegex(@"\[([^\]]+)\]\([^)]+\)")]
    private static partial Regex MarkdownLinkRegex();

    [GeneratedRegex(@"https?://\S+", RegexOptions.IgnoreCase)]
    private static partial Regex UrlRegex();

    [GeneratedRegex(@"(?m)^\s{0,3}#{1,6}\s*|(?m)^\s*[-*+]\s+|[*_`>|]")]
    private static partial Regex MarkdownRegex();

    [GeneratedRegex(@"\s+")]
    private static partial Regex WhitespaceRegex();

    public static string Normalize(string text)
    {
        text = ModelTagRegex().Replace(text, "");
        return NonSpeechTextRegex().Replace(text, "").ToLowerInvariant();
    }

    public static (bool Detected, string Command) SplitWakeCommand(
        string text, int sensitivity, bool prefixOnly = false)
    {
        foreach (var regex in new[]
                 {
                     KoreanWakeRegex(), EnglishWakeRegex(), JapaneseWakeRegex(), ChineseWakeRegex()
                 })
        {
            var match = regex.Match(text);
            if (match.Success &&
                (!prefixOnly || Normalize(text[..match.Index]).Length <= 1))
                return (true, text[(match.Index + match.Length)..].TrimStart(' ', ',', '.', '!', '?', '，', '。'));
        }

        var compact = Normalize(text);
        foreach (var variant in WakeVariants)
        {
            var index = compact.IndexOf(variant, StringComparison.Ordinal);
            if (index >= 0 && (!prefixOnly || index <= 1))
                return (true, compact[(index + variant.Length)..]);
        }

        // During TTS, the owner's wake phrase is often mixed with speaker echo
        // and loses one syllable (for example 헤이스웃). It still begins the
        // captured segment. Fuzzy-match only that prefix so similar words in
        // the answer body cannot interrupt playback.
        var fuzzyThreshold = Math.Max(
            0.60, 0.80 - (Math.Clamp(sensitivity, 0, 100) * 0.004));
        var bestScore = 0.0;
        var bestLength = 0;
        foreach (var variant in WakeVariants)
        {
            var lengths = new List<int> { variant.Length };
            // A shorter prefix is only valid when text remains as a command.
            // Otherwise a misspelled standalone wake phrase would become more
            // permissive merely because we discarded its final character.
            if (compact.Length > variant.Length)
                lengths.Add(variant.Length - 1);
            if (compact.Length > variant.Length + 1)
                lengths.Add(variant.Length + 1);
            foreach (var length in lengths.Distinct())
            {
                if (length < 2 || length > compact.Length)
                    continue;
                var score = Similarity(compact[..length], variant);
                if (score > bestScore)
                {
                    bestScore = score;
                    bestLength = length;
                }
            }
        }
        if (bestScore >= fuzzyThreshold)
            return (true, compact[bestLength..]);

        if (compact.Length is > 0 and <= 10)
        {
            var score = WakeVariants.Max(variant => Similarity(compact, variant));
            var threshold = 0.80 - (Math.Clamp(sensitivity, 0, 100) * 0.004);
            if (score >= threshold)
                return (true, "");
        }
        return (false, "");
    }

    public static double Similarity(string left, string right)
    {
        if (left.Length == 0 || right.Length == 0)
            return left.Length == right.Length ? 1 : 0;
        var distance = Levenshtein(left, right);
        return 1.0 - ((double)distance / Math.Max(left.Length, right.Length));
    }

    private static int Levenshtein(string left, string right)
    {
        var previous = Enumerable.Range(0, right.Length + 1).ToArray();
        var current = new int[right.Length + 1];
        for (var i = 1; i <= left.Length; i++)
        {
            current[0] = i;
            for (var j = 1; j <= right.Length; j++)
                current[j] = Math.Min(Math.Min(current[j - 1] + 1, previous[j] + 1),
                    previous[j - 1] + (left[i - 1] == right[j - 1] ? 0 : 1));
            (previous, current) = (current, previous);
        }
        return previous[right.Length];
    }

    public static bool IsRiskyCommand(string text) => RiskyRegex().IsMatch(text);

    public static bool HasMeaningfulCommand(string text) => Normalize(text).Length >= 2;

    public static string CorrectCommonRecognition(string text, string language)
    {
        if (!language.Equals("ko", StringComparison.OrdinalIgnoreCase))
            return text;
        return Normalize(text) switch
        {
            "지금몇" or "지금몇야" or "지금러시아" => "지금 몇 시야?",
            _ => text,
        };
    }

    public static string CanonicalizeWakeForDisplay(
        string text, string language, int sensitivity)
    {
        if (!language.Equals("ko", StringComparison.OrdinalIgnoreCase))
            return text;
        var wake = SplitWakeCommand(text, sensitivity);
        if (!wake.Detected)
            return text;
        return HasMeaningfulCommand(wake.Command)
            ? $"헤이 스카웃 {wake.Command}"
            : "헤이 스카웃";
    }

    public static bool IsConfirmation(string text)
    {
        var compact = Normalize(text);
        return compact.Contains("확인하고실행해", StringComparison.Ordinal) ||
               compact.Contains("confirmandexecute", StringComparison.Ordinal) ||
               compact.Contains("確認して実行", StringComparison.Ordinal) ||
               compact.Contains("确认并执行", StringComparison.Ordinal) ||
               compact.Contains("確認並執行", StringComparison.Ordinal);
    }

    public static bool IsCancellation(string text)
    {
        var compact = Normalize(text);
        return compact is "취소" or "취소해" or "cancel" or "キャンセル" or "取消";
    }

    public static string CleanForSpeech(string text)
    {
        text = CodeBlockRegex().Replace(text, " ");
        text = MarkdownLinkRegex().Replace(text, "$1");
        text = UrlRegex().Replace(text, "");
        text = MarkdownRegex().Replace(text, "");
        return WhitespaceRegex().Replace(text, " ").Trim();
    }

    public static string StripModelTags(string text) => ModelTagRegex().Replace(text, "").Trim();

    internal static bool IsCallAffirmative(string text, string language)
    {
        if (IsCallNegative(text, language))
            return false;
        var value = CallResponse(text, language);
        return language switch
        {
            "ko" => StartsWithAny(value, "네", "예", "응", "그래", "그렇", "맞아", "불렀어"),
            "ja" => StartsWithAny(value, "はい", "うん", "そう"),
            "zh-Hans" => StartsWithAny(value, "是", "对", "嗯"),
            _ => StartsWithAny(value, "yes", "yeah", "yep", "correct"),
        };
    }

    internal static bool IsCallNegative(string text, string language)
    {
        var value = CallResponse(text, language);
        return language switch
        {
            "ko" => StartsWithAny(value, "아니", "됐어", "계속해"),
            "ja" => StartsWithAny(value, "いいえ", "違う", "そうじゃない", "続けて"),
            "zh-Hans" => StartsWithAny(value, "不", "没有", "继续"),
            _ => StartsWithAny(value, "no", "nope", "incorrect", "continue"),
        };
    }

    internal static bool HasExplicitWakePrefix(string text) =>
        ExplicitKoreanWakeRegex().IsMatch(text) ||
        EnglishWakeRegex().Match(text) is { Success: true, Index: 0 } ||
        JapaneseWakeRegex().Match(text) is { Success: true, Index: 0 } ||
        ChineseWakeRegex().Match(text) is { Success: true, Index: 0 };

    private static string CallResponse(string text, string language)
    {
        var value = Normalize(text);
        var prompt = Normalize(language switch
        {
            "ko" => "저를 부르셨나요",
            "ja" => "私を呼びましたか",
            "zh-Hans" => "您叫我了吗",
            _ => "Did you call me",
        });
        return value.StartsWith(prompt, StringComparison.OrdinalIgnoreCase)
            ? value[prompt.Length..]
            : value;
    }

    private static bool StartsWithAny(string value, params string[] choices) =>
        choices.Any(choice => value.StartsWith(choice, StringComparison.OrdinalIgnoreCase));
}
