using SherpaOnnx;

namespace ScoutVoiceEngine;

internal sealed class VoiceModels : IDisposable
{
    public const int SampleRate = 16_000;
    private readonly OfflineRecognizer _recognizer;
    private readonly SpeakerEmbeddingExtractor _speaker;
    private readonly VoiceActivityDetector _vad;
    private readonly int _vadWindowSize;

    public VoiceModels(string runtimeDirectory, string language, int noiseSensitivity)
    {
        var modelsDirectory = Path.Combine(runtimeDirectory, "models");
        var senseDirectory = Directory.Exists(modelsDirectory)
            ? Directory.EnumerateDirectories(modelsDirectory, "sherpa-onnx-sense-voice-*").FirstOrDefault()
            : null;
        if (senseDirectory is null)
            throw new FileNotFoundException("SenseVoice model directory was not found.");

        var recognizerConfig = new OfflineRecognizerConfig();
        recognizerConfig.FeatConfig.SampleRate = SampleRate;
        recognizerConfig.FeatConfig.FeatureDim = 80;
        recognizerConfig.ModelConfig.Tokens = Path.Combine(senseDirectory, "tokens.txt");
        recognizerConfig.ModelConfig.SenseVoice.Model = Path.Combine(senseDirectory, "model.int8.onnx");
        recognizerConfig.ModelConfig.SenseVoice.Language = language;
        recognizerConfig.ModelConfig.SenseVoice.UseInverseTextNormalization = 1;
        recognizerConfig.ModelConfig.NumThreads = 2;
        recognizerConfig.ModelConfig.Provider = "cpu";
        recognizerConfig.ModelConfig.Debug = 0;
        _recognizer = new OfflineRecognizer(recognizerConfig);

        var speakerConfig = new SpeakerEmbeddingExtractorConfig
        {
            Model = Path.Combine(modelsDirectory,
                "3dspeaker_speech_eres2net_base_sv_zh-cn_3dspeaker_16k.onnx"),
            NumThreads = 2,
            Provider = "cpu",
            Debug = 0,
        };
        _speaker = new SpeakerEmbeddingExtractor(speakerConfig);

        var vadConfig = new VadModelConfig();
        vadConfig.SileroVad.Model = Path.Combine(modelsDirectory, "silero_vad.int8.onnx");
        vadConfig.SileroVad.Threshold = 0.80F - (Math.Clamp(noiseSensitivity, 0, 100) * 0.006F);
        vadConfig.SileroVad.MinSilenceDuration = 0.85F;
        vadConfig.SileroVad.MinSpeechDuration = 0.25F;
        vadConfig.SileroVad.MaxSpeechDuration = 12.0F;
        vadConfig.SileroVad.WindowSize = 512;
        vadConfig.SampleRate = SampleRate;
        vadConfig.Debug = 0;
        _vadWindowSize = vadConfig.SileroVad.WindowSize;
        _vad = new VoiceActivityDetector(vadConfig, 120);
    }

    public int SpeakerDimension => _speaker.Dim;
    public int VadWindowSize => _vadWindowSize;

    public void AcceptVad(float[] samples) => _vad.AcceptWaveform(samples);
    public bool HasVadSegment => !_vad.IsEmpty();
    public bool IsSpeechDetected => _vad.IsSpeechDetected();
    public float[] PopVadSegment()
    {
        var segment = _vad.Front().Samples;
        _vad.Pop();
        return segment;
    }
    public void ResetVad() => _vad.Reset();
    public void FlushVad() => _vad.Flush();

    public string Transcribe(float[] samples)
    {
        using var stream = _recognizer.CreateStream();
        stream.AcceptWaveform(SampleRate, samples);
        _recognizer.Decode(stream);
        return TextProcessing.StripModelTags(stream.Result.Text);
    }

    public float[] Embedding(float[] samples)
    {
        using var stream = _speaker.CreateStream();
        stream.AcceptWaveform(SampleRate, samples);
        stream.InputFinished();
        if (!_speaker.IsReady(stream))
            throw new ArgumentException("Please speak for at least one second.");
        return VoiceProfile.Normalize(_speaker.Compute(stream));
    }

    public void Dispose()
    {
        _vad.Dispose();
        _speaker.Dispose();
        _recognizer.Dispose();
    }
}
