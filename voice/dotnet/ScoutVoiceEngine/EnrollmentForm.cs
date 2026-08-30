namespace ScoutVoiceEngine;

internal sealed class EnrollmentForm : Form
{
    private readonly EnrollmentOptions _options;
    private readonly BoundedLogger _logger;
    private readonly LanguageResources _text;
    private readonly ProgressBar _progress;
    private readonly Label _stepLabel;
    private readonly Label _phraseLabel;
    private readonly Label _resultLabel;
    private readonly Button _recordButton;
    private readonly List<float[]> _embeddings = [];
    private readonly CancellationTokenSource _closing = new();
    private readonly object _modelGate = new();
    private VoiceModels? _models;
    private int _modelUsers;
    private bool _closingRequested;
    private int _index;

    public EnrollmentForm(EnrollmentOptions options, BoundedLogger logger)
    {
        _options = options;
        _logger = logger;
        _text = LanguageResources.All[options.Language];
        Text = _text.Title;
        ClientSize = new Size(720, 500);
        MinimumSize = new Size(620, 440);
        Font = new Font("Segoe UI", 10);
        StartPosition = FormStartPosition.CenterScreen;

        var heading = new Label
        {
            Text = _text.Heading,
            Font = new Font("Segoe UI", 22, FontStyle.Bold),
            AutoSize = true,
            Location = new Point(28, 24),
        };
        var intro = NewWrappedLabel(_text.Intro, 28, 76, 650);
        _progress = new ProgressBar
        {
            Location = new Point(28, 130),
            Size = new Size(650, 20),
            Maximum = _text.Phrases.Length,
        };
        _stepLabel = NewWrappedLabel(_text.Loading, 28, 170, 650);
        _phraseLabel = NewWrappedLabel("", 28, 210, 650);
        _phraseLabel.Font = new Font(options.Language == "ko" ? "Malgun Gothic" : "Segoe UI",
            17, FontStyle.Bold);
        _resultLabel = NewWrappedLabel("", 28, 290, 650);
        _resultLabel.ForeColor = Color.DimGray;
        _recordButton = new Button
        {
            Text = _text.Record,
            Location = new Point(28, 350),
            AutoSize = true,
            Enabled = false,
        };
        _recordButton.Click += RecordClicked;
        var privacy = NewWrappedLabel(_text.Privacy, 28, 420, 650);
        privacy.ForeColor = Color.DimGray;

        Controls.AddRange([heading, intro, _progress, _stepLabel, _phraseLabel, _resultLabel,
            _recordButton, privacy]);
        FormClosing += OnFormClosing;
        Shown += async (_, _) => await LoadModelsAsync();
    }

    public bool Completed { get; private set; }

    private static Label NewWrappedLabel(string text, int x, int y, int width) => new()
    {
        Text = text,
        Location = new Point(x, y),
        Size = new Size(width, 60),
        AutoEllipsis = false,
    };

    private async Task LoadModelsAsync()
    {
        try
        {
            await Task.Run(() =>
            {
                var loaded = new VoiceModels(
                    _options.RuntimeDirectory, _text.ModelLanguage, 35);
                lock (_modelGate)
                {
                    if (_closingRequested)
                    {
                        loaded.Dispose();
                        return;
                    }
                    _models = loaded;
                }
            });
            if (_closingRequested || IsDisposed)
                return;
            ShowPhrase();
        }
        catch (Exception exception)
        {
            _logger.Error("Enrollment initialization failed", exception);
            if (_closingRequested || IsDisposed)
                return;
            MessageBox.Show(this, exception.Message, _text.InitFailed,
                MessageBoxButtons.OK, MessageBoxIcon.Error);
            Close();
        }
    }

    private async void RecordClicked(object? sender, EventArgs eventArgs)
    {
        if (Completed)
        {
            Close();
            return;
        }
        if (!TryAcquireModels(out var models))
            return;
        var cancellationToken = _closing.Token;
        _recordButton.Enabled = false;
        _stepLabel.Text = string.Format(_text.Listening, _index + 1);
        _resultLabel.Text = _text.Wait;
        try
        {
            var samples = await UtteranceRecorder.RecordAsync(_logger, cancellationToken);
            var transcript = await Task.Run(() => models.Transcribe(samples), cancellationToken);
            var embedding = await Task.Run(() => models.Embedding(samples), cancellationToken);
            var expected = TextProcessing.Normalize(_text.Phrases[_index]);
            var recognized = TextProcessing.Normalize(transcript);
            if (TextProcessing.Similarity(expected, recognized) < 0.30)
                throw new InvalidOperationException(string.Format(_text.NotRecognized,
                    string.IsNullOrWhiteSpace(transcript) ? _text.NoResult : transcript));
            if (_embeddings.Count > 0)
            {
                var centroid = VoiceProfile.Normalize(Enumerable.Range(0, embedding.Length)
                    .Select(i => _embeddings.Average(item => item[i])));
                if (VoiceProfile.Cosine(embedding, centroid) < 0.35f)
                    throw new InvalidOperationException(_text.VoiceMismatch);
            }

            _embeddings.Add(embedding);
            _index++;
            _progress.Value = _index;
            _resultLabel.Text = string.Format(_text.Recognized, transcript);
            if (_index == _text.Phrases.Length)
            {
                var profile = VoiceProfile.Create(_embeddings);
                profile.Save(_options.RuntimeDirectory);
                Completed = true;
                _stepLabel.Text = _text.Complete;
                _phraseLabel.Text = _text.Ready;
                _resultLabel.Text = string.Format(_text.Threshold, profile.Threshold);
                _recordButton.Text = _text.Finish;
                _recordButton.Enabled = true;
            }
            else
            {
                await Task.Delay(700, cancellationToken);
                ShowPhrase();
            }
        }
        catch (OperationCanceledException)
        {
        }
        catch (Exception exception)
        {
            _logger.Error("Enrollment recording rejected", exception);
            if (!_closingRequested && !IsDisposed)
            {
                _resultLabel.Text = exception.Message;
                _recordButton.Text = _text.Retry;
                _recordButton.Enabled = true;
            }
        }
        finally
        {
            ReleaseModels();
        }
    }

    private bool TryAcquireModels(out VoiceModels models)
    {
        lock (_modelGate)
        {
            if (_closingRequested || _models is null)
            {
                models = null!;
                return false;
            }
            _modelUsers++;
            models = _models;
            return true;
        }
    }

    private void ReleaseModels()
    {
        VoiceModels? dispose = null;
        lock (_modelGate)
        {
            _modelUsers--;
            if (_closingRequested && _modelUsers == 0)
            {
                dispose = _models;
                _models = null;
            }
        }
        dispose?.Dispose();
    }

    private void ShowPhrase()
    {
        _stepLabel.Text = string.Format(_text.Prompt, _index + 1);
        _phraseLabel.Text = _text.Phrases[_index];
        _recordButton.Text = _text.Record;
        _recordButton.Enabled = true;
    }

    private void OnFormClosing(object? sender, FormClosingEventArgs eventArgs)
    {
        if (!Completed && eCloseNeedsConfirmation(eventArgs.CloseReason) &&
            MessageBox.Show(this, _text.Cancel, _text.CancelTitle,
                MessageBoxButtons.YesNo, MessageBoxIcon.Question) != DialogResult.Yes)
        {
            eventArgs.Cancel = true;
            return;
        }
        VoiceModels? dispose = null;
        lock (_modelGate)
        {
            _closingRequested = true;
            if (_modelUsers == 0)
            {
                dispose = _models;
                _models = null;
            }
        }
        _closing.Cancel();
        dispose?.Dispose();
    }

    private static bool eCloseNeedsConfirmation(CloseReason reason) =>
        reason == CloseReason.UserClosing;

    protected override void Dispose(bool disposing)
    {
        if (disposing)
            _closing.Dispose();
        base.Dispose(disposing);
    }
}
