using System.Runtime.InteropServices;
using System.Text;
using System.Text.Json;
using System.Text.Json.Serialization;

namespace ScoutVoiceEngine;

internal sealed class VoiceProfile
{
    [JsonPropertyName("version")]
    public int Version { get; init; } = 1;

    [JsonPropertyName("createdAt")]
    public string CreatedAt { get; init; } = DateTimeOffset.UtcNow.ToString("O");

    [JsonPropertyName("embedding")]
    public required float[] Embedding { get; init; }

    [JsonPropertyName("threshold")]
    public float Threshold { get; init; }

    [JsonPropertyName("enrollmentScores")]
    public required float[] EnrollmentScores { get; init; }

    [JsonPropertyName("phraseCount")]
    public int PhraseCount { get; init; }

    public static VoiceProfile Create(IReadOnlyList<float[]> embeddings)
    {
        if (embeddings.Count == 0)
            throw new ArgumentException("At least one embedding is required.", nameof(embeddings));
        var normalized = embeddings.Select(Normalize).ToArray();
        var centroid = Normalize(Enumerable.Range(0, normalized[0].Length)
            .Select(i => normalized.Average(item => item[i])).ToArray());
        var scores = normalized.Select(item => Cosine(item, centroid)).ToArray();
        return new VoiceProfile
        {
            Embedding = centroid,
            Threshold = Math.Min(0.60f, Math.Max(0.55f, scores.Min() - 0.25f)),
            EnrollmentScores = scores,
            PhraseCount = normalized.Length,
        };
    }

    public void Save(string runtimeDirectory)
    {
        Directory.CreateDirectory(runtimeDirectory);
        var plaintext = JsonSerializer.SerializeToUtf8Bytes(this);
        var encrypted = Dpapi.Protect(plaintext);
        AtomicFile.WriteBytes(Path.Combine(runtimeDirectory, "voice-profile.dat"), encrypted);
    }

    public static VoiceProfile Load(string runtimeDirectory)
    {
        var path = Path.Combine(runtimeDirectory, "voice-profile.dat");
        if (!File.Exists(path))
            throw new FileNotFoundException("Voice profile is not enrolled.", path);
        var profile = JsonSerializer.Deserialize<VoiceProfile>(Dpapi.Unprotect(File.ReadAllBytes(path)));
        if (profile is null || profile.Version != 1 || profile.Embedding.Length == 0)
            throw new InvalidDataException("The voice profile is invalid.");
        return profile;
    }

    public static float[] Normalize(IEnumerable<float> values)
    {
        var vector = values.ToArray();
        var norm = Math.Sqrt(vector.Sum(value => value * value));
        if (norm < 1e-12)
            throw new ArgumentException("The speaker embedding is empty.");
        for (var index = 0; index < vector.Length; index++)
            vector[index] = (float)(vector[index] / norm);
        return vector;
    }

    public static float Cosine(float[] left, float[] right)
    {
        if (left.Length != right.Length)
            throw new ArgumentException("Embedding dimensions differ.");
        var a = Normalize(left);
        var b = Normalize(right);
        return a.Zip(b, (x, y) => x * y).Sum();
    }
}

internal static class Dpapi
{
    [StructLayout(LayoutKind.Sequential)]
    private struct DataBlob
    {
        public int Size;
        public IntPtr Data;
    }

    [DllImport("crypt32.dll", SetLastError = true, CharSet = CharSet.Unicode)]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static extern bool CryptProtectData(
        ref DataBlob input, string description, IntPtr entropy, IntPtr reserved,
        IntPtr prompt, int flags, out DataBlob output);

    [DllImport("crypt32.dll", SetLastError = true)]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static extern bool CryptUnprotectData(
        ref DataBlob input, IntPtr description, IntPtr entropy, IntPtr reserved,
        IntPtr prompt, int flags, out DataBlob output);

    [DllImport("kernel32.dll")]
    private static extern IntPtr LocalFree(IntPtr memory);

    public static byte[] Protect(byte[] data) => Transform(data, true);
    public static byte[] Unprotect(byte[] data) => Transform(data, false);

    private static byte[] Transform(byte[] data, bool protect)
    {
        var inputPointer = Marshal.AllocHGlobal(data.Length);
        try
        {
            Marshal.Copy(data, 0, inputPointer, data.Length);
            var input = new DataBlob { Size = data.Length, Data = inputPointer };
            DataBlob output;
            var success = protect
                ? CryptProtectData(ref input, "Scout Voice Assistant speaker profile",
                    IntPtr.Zero, IntPtr.Zero, IntPtr.Zero, 0, out output)
                : CryptUnprotectData(ref input, IntPtr.Zero, IntPtr.Zero, IntPtr.Zero,
                    IntPtr.Zero, 0, out output);
            if (!success)
                throw new System.ComponentModel.Win32Exception(Marshal.GetLastWin32Error());
            try
            {
                var result = new byte[output.Size];
                Marshal.Copy(output.Data, result, 0, result.Length);
                return result;
            }
            finally
            {
                _ = LocalFree(output.Data);
            }
        }
        finally
        {
            Marshal.FreeHGlobal(inputPointer);
        }
    }
}

internal static class AtomicFile
{
    public static void WriteBytes(string path, byte[] content)
    {
        Directory.CreateDirectory(Path.GetDirectoryName(Path.GetFullPath(path))!);
        var temporary = path + ".tmp";
        File.WriteAllBytes(temporary, content);
        File.Move(temporary, path, true);
    }

    public static void WriteJson<T>(string path, T content) =>
        WriteBytes(path, JsonSerializer.SerializeToUtf8Bytes(content));
}
