using System.ComponentModel;
using System.Runtime.InteropServices;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Interop;
using System.Windows.Media;
using System.Windows.Media.Imaging;

namespace ScoutVoiceEngine;

internal sealed class EnrollmentForm : Window, IDisposable
{
    private static readonly Brush WindowBackground = Brush("#FF1B1F2A");
    private static readonly Brush PrimaryText = Brush("#FFE6EAF2");
    private static readonly Brush MutedText = Brush("#FF9AA6BE");
    private static readonly Brush SubtleText = Brush("#FF8A93A6");
    private static readonly Brush ControlBorderBrush = Brush("#FF3A4358");
    private static readonly Brush AccentBrush = Brush("#FF2F6FBF");

    private readonly EnrollmentOptions _options;
    private readonly BoundedLogger _logger;
    private readonly LanguageResources _text;
    private readonly ProgressBar _progress;
    private readonly TextBlock _stepLabel;
    private readonly TextBlock _phraseLabel;
    private readonly TextBlock _resultLabel;
    private readonly Button _recordButton;
    private readonly List<float[]> _embeddings = [];
    private readonly CancellationTokenSource _closing = new();
    private readonly object _modelGate = new();
    private VoiceModels? _models;
    private int _modelUsers;
    private bool _closingRequested;
    private bool _skipCloseConfirmation;
    private int _index;

    public EnrollmentForm(EnrollmentOptions options, BoundedLogger logger)
    {
        _options = options;
        _logger = logger;
        _text = LanguageResources.All[options.Language];

        Title = _text.Title;
        Width = 720;
        MinWidth = 620;
        SizeToContent = SizeToContent.Height;
        ResizeMode = ResizeMode.NoResize;
        WindowStartupLocation = WindowStartupLocation.CenterScreen;
        Background = WindowBackground;
        Foreground = PrimaryText;
        FontFamily = new FontFamily("Segoe UI, Malgun Gothic, Yu Gothic UI, Microsoft YaHei UI");
        ShowInTaskbar = true;
        ApplyCompanionIcon();

        var content = new StackPanel { Margin = new Thickness(28, 24, 28, 24) };
        Content = content;

        content.Children.Add(NewText(_text.Heading, 22, FontWeights.Bold, PrimaryText,
            new Thickness(0, 0, 0, 10)));
        content.Children.Add(NewText(_text.Intro, 12.5, FontWeights.Normal, MutedText,
            new Thickness(0, 0, 0, 18)));

        _progress = new ProgressBar
        {
            Height = 8,
            Maximum = _text.Phrases.Length,
            Foreground = AccentBrush,
            Background = ControlBorderBrush,
            BorderThickness = new Thickness(0),
            Margin = new Thickness(0, 0, 0, 18),
        };
        content.Children.Add(_progress);

        _stepLabel = NewText(_text.Loading, 12.5, FontWeights.SemiBold, MutedText,
            new Thickness(0, 0, 0, 8));
        content.Children.Add(_stepLabel);

        var phraseSurface = new Border
        {
            Background = Brush("#FF232838"),
            BorderBrush = ControlBorderBrush,
            BorderThickness = new Thickness(1),
            CornerRadius = new CornerRadius(6),
            Padding = new Thickness(16, 14, 16, 14),
            MinHeight = 82,
            Margin = new Thickness(0, 0, 0, 14),
        };
        _phraseLabel = NewText("", 17, FontWeights.SemiBold, PrimaryText, new Thickness(0));
        _phraseLabel.VerticalAlignment = VerticalAlignment.Center;
        phraseSurface.Child = _phraseLabel;
        content.Children.Add(phraseSurface);

        _resultLabel = NewText("", 12, FontWeights.Normal, MutedText,
            new Thickness(0, 0, 0, 14));
        _resultLabel.MinHeight = 38;
        content.Children.Add(_resultLabel);

        _recordButton = new Button
        {
            Content = _text.Record,
            MinWidth = 150,
            Height = 32,
            Padding = new Thickness(14, 0, 14, 0),
            HorizontalAlignment = HorizontalAlignment.Left,
            Background = AccentBrush,
            Foreground = Brushes.White,
            BorderThickness = new Thickness(0),
            Cursor = System.Windows.Input.Cursors.Hand,
            IsEnabled = false,
            Margin = new Thickness(0, 0, 0, 18),
        };
        _recordButton.Click += RecordClicked;
        content.Children.Add(_recordButton);

        content.Children.Add(new Border
        {
            Height = 1,
            Background = Brush("#FF2A3142"),
            Margin = new Thickness(0, 0, 0, 12),
        });
        content.Children.Add(NewText(_text.Privacy, 11, FontWeights.Normal, SubtleText,
            new Thickness(0)));

        Closing += OnFormClosing;
        SourceInitialized += (_, _) => ApplyDarkTitleBar();
        Loaded += async (_, _) => await LoadModelsAsync();
    }

    public bool Completed { get; private set; }

    private static TextBlock NewText(
        string text, double size, FontWeight weight, Brush foreground, Thickness margin) =>
        new()
        {
            Text = text,
            FontSize = size,
            FontWeight = weight,
            Foreground = foreground,
            TextWrapping = TextWrapping.Wrap,
            TextTrimming = TextTrimming.None,
            LineStackingStrategy = LineStackingStrategy.MaxHeight,
            Margin = margin,
        };

    private static SolidColorBrush Brush(string color)
    {
        var brush = new SolidColorBrush((Color)ColorConverter.ConvertFromString(color));
        brush.Freeze();
        return brush;
    }

    private void ApplyCompanionIcon()
    {
        var iconPath = Path.Combine(
            Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData),
            "ScoutCompanion", "scout-companion.ico");
        if (!File.Exists(iconPath))
            return;
        Icon = BitmapFrame.Create(new Uri(iconPath), BitmapCreateOptions.PreservePixelFormat,
            BitmapCacheOption.OnLoad);
    }

    private void ApplyDarkTitleBar()
    {
        var handle = new WindowInteropHelper(this).Handle;
        var enabled = 1;
        if (DwmSetWindowAttribute(handle, 20, ref enabled, sizeof(int)) != 0)
            DwmSetWindowAttribute(handle, 19, ref enabled, sizeof(int));
    }

    [DllImport("dwmapi.dll")]
    private static extern int DwmSetWindowAttribute(
        nint windowHandle, int attribute, ref int value, int valueSize);

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
            if (_closingRequested)
                return;
            ShowPhrase();
        }
        catch (Exception exception)
        {
            _logger.Error("Enrollment initialization failed", exception);
            if (_closingRequested)
                return;
            MessageBox.Show(this, exception.Message, _text.InitFailed,
                MessageBoxButton.OK, MessageBoxImage.Error);
            _skipCloseConfirmation = true;
            Close();
        }
    }

    private async void RecordClicked(object sender, RoutedEventArgs eventArgs)
    {
        if (Completed)
        {
            Close();
            return;
        }
        if (!TryAcquireModels(out var models))
            return;
        var cancellationToken = _closing.Token;
        _recordButton.IsEnabled = false;
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
                _recordButton.Content = _text.Finish;
                _recordButton.IsEnabled = true;
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
            if (!_closingRequested)
            {
                _resultLabel.Text = exception.Message;
                _recordButton.Content = _text.Retry;
                _recordButton.IsEnabled = true;
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
        _recordButton.Content = _text.Record;
        _recordButton.IsEnabled = true;
    }

    private void OnFormClosing(object? sender, CancelEventArgs eventArgs)
    {
        if (!Completed && !_skipCloseConfirmation &&
            MessageBox.Show(this, _text.Cancel, _text.CancelTitle,
                MessageBoxButton.YesNo, MessageBoxImage.Question) != MessageBoxResult.Yes)
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

    public void Dispose()
    {
        _closing.Dispose();
    }
}
