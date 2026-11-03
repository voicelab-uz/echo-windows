using Microsoft.Extensions.DependencyInjection;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Media;
using VoiceLab.Infrastructure.Audio;
using VoiceLab.Infrastructure.Services;
using VoiceLab.Infrastructure.Hotkeys;

namespace VoiceLab.App.Views.Onboarding;

public sealed partial class TryItMessageStepPage : TryItPracticePage
{
    public TryItMessageStepPage() : base("Send a message", "Speak a quick message to a friend or colleague.",
        "Hey! I’ll be there in ten minutes.", "Messages", typeof(TryItEmailStepPage), requiresVoiceTrial: true) { InitializeComponent(); }
}

public sealed partial class TryItEmailStepPage : TryItPracticePage
{
    public TryItEmailStepPage() : base("Write an email", "Dictate a useful email and see your words appear below.",
        "Hi, thanks for the update. I’ll review it today and get back to you.", "Email", typeof(TryItListStepPage)) { InitializeComponent(); }
}

public sealed partial class TryItListStepPage : TryItPracticePage
{
    public TryItListStepPage() : base("Make a list", "Try speaking a few tasks or shopping items.",
        "Buy milk, send the report, and call the team.", "Notes", typeof(TimeSavingsStepPage)) { InitializeComponent(); }
}

public abstract class TryItPracticePage : Page
{
    private readonly IAudioCaptureService _audio = App.Services.GetRequiredService<IAudioCaptureService>();
    private readonly ITranscriptionService _transcriptions = App.Services.GetRequiredService<ITranscriptionService>();
    private readonly ISettingsService _settings = App.Services.GetRequiredService<ISettingsService>();
    private readonly IAuthenticationService _authentication = App.Services.GetRequiredService<IAuthenticationService>();
    private readonly IGlobalHotkeyService _hotkeys = App.Services.GetRequiredService<IGlobalHotkeyService>();
    private readonly Type _next;
    private readonly TextBox _editor;
    private readonly TextBlock _status;
    private readonly Button _record;
    private readonly Button _nextButton;
    private bool _recording;
    private bool _busy;
    private readonly bool _requiresVoiceTrial;
    private string? _owner;
    private bool _trialCompleted;
    private CancellationTokenSource? _transcriptionCancellation;

    protected TryItPracticePage(string title, string description, string example, string windowTitle, Type next,
        bool requiresVoiceTrial = false)
    {
        FontFamily = (FontFamily)Application.Current.Resources["OnbFontFamily"];
        _next = next;
        _requiresVoiceTrial = requiresVoiceTrial;
        var root = new Grid { Padding = new Thickness(24), Background = (Brush)Application.Current.Resources["OnbBgBrush"] };
        var panel = new StackPanel { Spacing = 20, MaxWidth = 600, HorizontalAlignment = HorizontalAlignment.Stretch, VerticalAlignment = VerticalAlignment.Center };
        panel.Children.Add(new TextBlock { Text = title, Style = (Style)Application.Current.Resources["OnbTitle"] });
        panel.Children.Add(new TextBlock { Text = description, TextWrapping = TextWrapping.Wrap, Style = (Style)Application.Current.Resources["OnbSubtitle"] });
        panel.Children.Add(new TextBlock { Text = $"Try saying: “{example}”", TextWrapping = TextWrapping.Wrap, Opacity = .7 });
        _editor = new TextBox { PlaceholderText = "Your words appear here", AcceptsReturn = true, TextWrapping = TextWrapping.Wrap, Height = 145, MaxWidth = 520, HorizontalAlignment = HorizontalAlignment.Stretch };
        var card = new Border { Style = (Style)Application.Current.Resources["OnbCard"], MaxWidth = 560, HorizontalAlignment = HorizontalAlignment.Stretch };
        var cardBody = new StackPanel { Spacing = 14 };
        var cardHeader = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 7 };
        foreach (var color in new[] { 0xFFFF5F57u, 0xFFFEBc2Eu, 0xFF28C840u })
            cardHeader.Children.Add(new Microsoft.UI.Xaml.Shapes.Ellipse { Width = 10, Height = 10,
                Fill = new SolidColorBrush(Windows.UI.Color.FromArgb((byte)(color >> 24), (byte)(color >> 16), (byte)(color >> 8), (byte)color)) });
        cardHeader.Children.Add(new TextBlock { Text = windowTitle, FontSize = 13, Margin = new Thickness(10, 0, 0, 0), Opacity = .7 });
        cardBody.Children.Add(cardHeader);
        if (windowTitle == "Email") cardBody.Children.Add(new TextBlock { Text = "To: team@example.com     Subject: Quick update", Opacity = .6, FontSize = 12 });
        if (windowTitle == "Notes") cardBody.Children.Add(new TextBlock { Text = "My list", FontSize = 17, FontWeight = Microsoft.UI.Text.FontWeights.SemiBold });
        cardBody.Children.Add(_editor);
        card.Child = cardBody;
        panel.Children.Add(card);
        _status = new TextBlock { Text = "Press Record, speak, then press Finish.", TextWrapping = TextWrapping.Wrap, Opacity = .75 };
        panel.Children.Add(_status);
        _record = new Button { Content = "Record", Style = (Style)Application.Current.Resources["OnbPrimaryButton"] };
        _record.Click += OnRecordClick;
        _hotkeys.HotkeyPressed += OnHotkeyPressed;
        var copy = new Button { Content = "Copy text", Style = (Style)Application.Current.Resources["OnbSecondaryButton"] };
        copy.Click += async (_, _) =>
        {
            if (string.IsNullOrWhiteSpace(_editor.Text)) return;
            try
            {
                await VoiceLab.App.Services.ClipboardFeedback.CopyAsync(copy, _editor.Text);
            }
            catch (Exception ex) { _status.Text = $"Could not copy text: {ex.Message}"; }
        };
        _nextButton = new Button
        {
            Content = requiresVoiceTrial ? "Record once to continue" : "Skip for now",
            Style = (Style)Application.Current.Resources["OnbSecondaryButton"],
            IsEnabled = !requiresVoiceTrial
        };
        _nextButton.Click += async (_, _) =>
        {
            if (_busy || (_requiresVoiceTrial && !_trialCompleted)) return;
            if (_recording)
            {
                try { _recording = false; await _audio.StopRecordingAsync(); }
                catch (Exception ex) { _status.Text = $"Microphone could not stop: {ex.Message}"; return; }
            }
            Frame.Navigate(_next);
        };
        var actions = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 12 };
        actions.Children.Add(_record); actions.Children.Add(copy); actions.Children.Add(_nextButton);
        root.SizeChanged += (_, e) =>
        {
            var compact = e.NewSize.Width < 510;
            actions.Orientation = compact ? Orientation.Vertical : Orientation.Horizontal;
            foreach (var button in new[] { _record, copy, _nextButton })
                button.HorizontalAlignment = compact ? HorizontalAlignment.Stretch : HorizontalAlignment.Center;
        };
        panel.Children.Add(actions);
        root.Children.Add(new ScrollViewer
        {
            VerticalScrollBarVisibility = ScrollBarVisibility.Auto,
            HorizontalScrollBarVisibility = ScrollBarVisibility.Disabled,
            Content = panel
        });
        Content = root;
        Loaded += async (_, _) =>
        {
            _owner = (await _authentication.GetCurrentUserAsync())?.Id;
            _trialCompleted = _owner is not null && _settings
                .GetSetting("PracticeCompletedAccountIds", new List<string>()).Contains(_owner);
            if (_requiresVoiceTrial)
            {
                _nextButton.IsEnabled = _trialCompleted;
                _nextButton.Content = _trialCompleted ? "Continue" : "Record once to continue";
            }
        };
        Unloaded += async (_, _) =>
        {
            _hotkeys.HotkeyPressed -= OnHotkeyPressed;
            _transcriptionCancellation?.Cancel();
            if (_recording)
            {
                _recording = false;
                try { await _audio.StopRecordingAsync(); }
                catch { /* The next capture attempt will report the device error. */ }
            }
        };
    }

    private void OnHotkeyPressed(object? sender, EventArgs e) =>
        DispatcherQueue.TryEnqueue(async () =>
        {
            if (IsLoaded && ReferenceEquals(Frame?.Content, this))
                await ToggleRecordingAsync();
        });
    private async void OnRecordClick(object sender, RoutedEventArgs e) => await ToggleRecordingAsync();

    public Task BeginFromShortcutAsync() => ToggleRecordingAsync();

    private async Task ToggleRecordingAsync()
    {
        if (_busy) return;
        _busy = true;
        _record.IsEnabled = false;
        try
        {
            if (!_recording)
            {
                _audio.StartRecording();
                _recording = true;
                _record.Content = "Finish";
                _status.Text = "Listening…";
            }
            else
            {
                _recording = false;
                _record.Content = "Record again";
                _status.Text = "Transcribing…";
                var pcm = await _audio.StopRecordingAsync();
                if (pcm.Length < 3200) { _status.Text = "Recording was too short. Please try again."; return; }
                if (!IsLoaded) return;
                using var cancellation = new CancellationTokenSource();
                _transcriptionCancellation = cancellation;
                string transcript;
                try
                {
                    var record = await _transcriptions.TranscribeAudioRecordAsync(pcm,
                        _settings.GetSetting("PreferredLanguage", "auto"), saveHistory: false,
                        cancellationToken: cancellation.Token);
                    if (cancellation.IsCancellationRequested || !IsLoaded) return;
                    transcript = record.Text;
                }
                finally
                {
                    if (ReferenceEquals(_transcriptionCancellation, cancellation)) _transcriptionCancellation = null;
                }
                if (string.IsNullOrWhiteSpace(transcript))
                {
                    _status.Text = "No words were recognized. Speak clearly and try again.";
                    return;
                }
                _editor.Text = transcript;
                var owner = (await _authentication.GetCurrentUserAsync())?.Id;
                if (string.IsNullOrWhiteSpace(owner) || (_owner is not null && owner != _owner))
                    throw new InvalidOperationException("Your account changed during practice. Sign in and try again.");
                var completedAccounts = _settings.GetSetting("PracticeCompletedAccountIds", new List<string>());
                if (!completedAccounts.Contains(owner))
                {
                    completedAccounts.Add(owner);
                    _settings.SaveSetting("PracticeCompletedAccountIds", completedAccounts);
                }
                _trialCompleted = true;
                _settings.SaveSetting("PracticeWords", TranscriptionService.CountWords(_editor.Text));
                _settings.SaveSetting("PracticeSeconds", pcm.Length / 32_000d);
                _status.Text = "Ready. You can edit or copy this text.";
                _nextButton.Content = "Continue";
                _nextButton.IsEnabled = true;
            }
        }
        catch (OperationCanceledException) when (!IsLoaded) { }
        catch (Exception ex) { if (IsLoaded) _status.Text = ex.Message; _recording = false; _record.Content = "Try again"; }
        finally { _record.IsEnabled = true; _busy = false; }
    }
}
