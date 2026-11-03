using System.Net;
using System.Globalization;
using System.Text.Json;
using Microsoft.Extensions.DependencyInjection;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Media;
using Microsoft.UI.Xaml.Media.Imaging;
using VoiceLab.Infrastructure.Services;

namespace VoiceLab.App.Views.Onboarding;

public sealed partial class QuestionnaireStepPage : Page
{
    private readonly IOnboardingContextService _context = App.Services.GetRequiredService<IOnboardingContextService>();
    private readonly IAuthenticationService _auth = App.Services.GetRequiredService<IAuthenticationService>();
    private readonly ISettingsService _settings = App.Services.GetRequiredService<ISettingsService>();
    private readonly CancellationTokenSource _lifetime = new();
    private readonly Dictionary<string, OnboardingContextAnswer> _answers = [];
    private readonly Dictionary<string, Button> _optionButtons = [];
    private readonly HashSet<string> _selected = [];
    private QuestionnaireCopy? _copy;
    private OnboardingContextSubmission? _pending;
    private string _owner = "";
    private int _revision;
    private string? _confirmedCompletedAt;
    private int _index;
    private bool _started;
    private bool _ready;
    private bool _busy;
    private bool _conflict;
    private bool _rendering;

    public QuestionnaireStepPage()
    {
        InitializeComponent();
        Loaded += OnLoaded;
        Unloaded += (_, _) => _lifetime.Cancel();
        ActualThemeChanged += (_, _) => { UpdateOptionVisuals(); UpdateIllustration(); };
    }

    private async void OnLoaded(object sender, RoutedEventArgs e)
    {
        if (_started) return;
        _started = true;
        await LoadAsync();
    }

    private async Task LoadAsync(bool discardDraft = false)
    {
        _ready = false;
        _conflict = false;
        SetBusy(true);
        ReloadButton.Visibility = Visibility.Collapsed;
        QuestionStatus.Text = _copy?.Loading ?? "Loading your answers…";
        try
        {
            _copy ??= QuestionnaireCopy.Load(_settings.GetSetting("PreferredLanguage", "auto"));
            _owner = (await _auth.GetCurrentUserAsync())?.Id ?? "";
            if (_owner.Length == 0) throw new InvalidOperationException("Sign in before continuing setup.");
            var server = await _context.GetAsync(_lifetime.Token);
            if (_lifetime.IsCancellationRequested) return;
            _confirmedCompletedAt = server?.CompletedAt;
            if (server is not null) ApplyLocalAnswers(server.Answers);
            if (server?.CompletedAt is not null)
            {
                _revision = server.Revision;
                _answers.Clear();
                foreach (var (key, value) in server.Answers) _answers[key] = Clone(value);
                _index = OnboardingQuestionCatalog.All.Length - 1;
                _pending = null;
                await SaveDraftAsync();
                if (_lifetime.IsCancellationRequested) return;
                Frame.Navigate(typeof(TryItIntroStepPage));
                return;
            }
            var draft = discardDraft ? null : await _context.LoadDraftAsync(_lifetime.Token);
            _revision = server?.Revision ?? 0;
            _answers.Clear();
            if (server is not null)
                foreach (var (key, value) in server.Answers) _answers[key] = Clone(value);
            _pending = null;
            _index = OnboardingQuestionCatalog.All
                .Select((question, position) => (question, position))
                .FirstOrDefault(pair => !_answers.ContainsKey(pair.question.Key), (null!, 0)).position;
            if (draft is { OwnerId: var owner } && owner == _owner)
            {
                if (draft.Pending is { } pending && _revision == pending.ExpectedRevision)
                {
                    _answers.Clear();
                    foreach (var (key, value) in draft.Answers) _answers[key] = Clone(value);
                    _index = Math.Clamp(draft.Index, 0, 5);
                    _pending = pending;
                    QuestionStatus.Text = "Your previous answer is saved locally. Retry sending it.";
                }
                else if (draft.Pending is { } acknowledged && _revision == acknowledged.ExpectedRevision + 1
                    && server is not null && SameAnswers(server.Answers, acknowledged.Answers))
                {
                    _index = Math.Clamp(draft.Index + 1, 0, 5);
                    QuestionStatus.Text = "Your previous answer was confirmed.";
                }
                else if (draft.Pending is not null)
                {
                    _conflict = true;
                    QuestionStatus.Text = _copy.Conflict;
                    ReloadButton.Content = _copy.Reload;
                    ReloadButton.Visibility = Visibility.Visible;
                }
                else if (draft.Revision == _revision)
                {
                    _answers.Clear();
                    foreach (var (key, value) in draft.Answers) _answers[key] = Clone(value);
                    _index = Math.Clamp(draft.Index, 0, 5);
                    QuestionStatus.Text = "";
                }
            }
            else QuestionStatus.Text = "";
            RenderQuestion();
        }
        catch (OperationCanceledException) when (_lifetime.IsCancellationRequested) { }
        catch (Exception ex)
        {
            // A previously confirmed questionnaire can resume practice when
            // the service is temporarily unreachable. Never use an unsent draft
            // or a draft from another account as proof of completion.
            if (!_lifetime.IsCancellationRequested && _owner.Length > 0 &&
                (ex is TaskCanceledException || ex is HttpRequestException request &&
                    (request.StatusCode is null || (int)request.StatusCode >= 500)))
            {
                try
                {
                    var confirmed = await _context.LoadDraftAsync(_lifetime.Token);
                    if (confirmed is { Pending: null } && confirmed.OwnerId == _owner &&
                        DateTimeOffset.TryParse(confirmed.ConfirmedCompletedAt, out _) &&
                        OnboardingQuestionCatalog.Keys.All(confirmed.Answers.ContainsKey))
                    {
                        ApplyLocalAnswers(confirmed.Answers);
                        Frame.Navigate(typeof(TryItIntroStepPage));
                        return;
                    }
                }
                catch (Exception draftError)
                {
                    System.Diagnostics.Debug.WriteLine($"Could not resume confirmed questionnaire: {draftError}");
                }
            }
            QuestionStatus.Text = (_copy?.LoadError ?? "Could not load your answers.") + " " + ex.Message;
            ReloadButton.Content = _copy?.Retry ?? "Retry";
            ReloadButton.Visibility = Visibility.Visible;
        }
        finally { SetBusy(false); }
    }

    private void RenderQuestion()
    {
        if (_copy is null) return;
        _rendering = true;
        var question = OnboardingQuestionCatalog.All[_index];
        QuestionCount.Text = _copy.Stage + "  ·  " + (_index + 1) + " / " + OnboardingQuestionCatalog.All.Length;
        QuestionTitle.Text = _copy.Headings[_index];
        QuestionHint.Text = question.Limit == 1 ? _copy.Single : _copy.Multiple;
        OtherText.Header = _copy.OtherPrompt;
        SkipButton.Content = _copy.Skip;
        UpdateIllustration();
        QuestionBackButton.IsEnabled = _index > 0 && _pending is null;
        _selected.Clear();
        if (_answers.TryGetValue(question.Key, out var answer))
            foreach (var choice in answer.Choices) _selected.Add(choice);
        OtherText.Text = answer?.Other ?? "";
        OptionsList.Items.Clear();
        _optionButtons.Clear();
        var labels = _copy.Options[question.Key];
        for (var i = 0; i < question.Options.Length; i++)
        {
            var code = question.Options[i];
            var option = new Button
            {
                Content = labels[i],
                Tag = code,
                Width = 176,
                Height = 40,
                Margin = new Thickness(0, 3, 7, 3),
                Padding = new Thickness(10, 5, 10, 5),
                CornerRadius = new CornerRadius(8),
                BorderThickness = new Thickness(1),
                FontSize = 12,
                HorizontalContentAlignment = HorizontalAlignment.Left
            };
            option.Click += OnOptionClick;
            OptionsList.Items.Add(option);
            _optionButtons[code] = option;
        }
        _rendering = false;
        _ready = true;
        UpdateOptionVisuals();
    }

    private void OnOptionClick(object sender, RoutedEventArgs e)
    {
        if (_busy || _pending is not null || sender is not Button { Tag: string code }) return;
        var question = OnboardingQuestionCatalog.All[_index];
        if (_selected.Contains(code)) _selected.Remove(code);
        else if (question.Limit == 1 || code == "none")
        {
            _selected.Clear();
            _selected.Add(code);
        }
        else
        {
            _selected.Remove("none");
            if (_selected.Count >= question.Limit)
            {
                QuestionStatus.Text = "Choose up to " + question.Limit + " options.";
                return;
            }
            _selected.Add(code);
        }
        QuestionStatus.Text = "";
        UpdateOptionVisuals();
    }

    private void OnOtherTextChanged(object sender, TextChangedEventArgs e)
    {
        if (!_rendering) UpdateOptionVisuals();
    }

    private void UpdateOptionVisuals()
    {
        if (_copy is null || !_ready)
        {
            ContinueButton.IsEnabled = false;
            SkipButton.IsEnabled = false;
            QuestionBackButton.IsEnabled = false;
            return;
        }
        var resources = Application.Current.Resources;
        foreach (var (code, button) in _optionButtons)
        {
            var selected = _selected.Contains(code);
            button.Background = (Brush)resources[selected ? "OnbPanelBrush" : "OnbCardBrush"];
            button.BorderBrush = (Brush)resources[selected ? "OnbInkBrush" : "OnbCardBorderBrush"];
            button.Foreground = (Brush)resources["OnbInkBrush"];
            button.IsEnabled = !_busy && !_conflict && _pending is null;
        }
        OtherText.Visibility = _selected.Contains("other") ? Visibility.Visible : Visibility.Collapsed;
        OtherText.IsEnabled = !_busy && !_conflict && _pending is null;
        var validOther = !_selected.Contains("other") || !string.IsNullOrWhiteSpace(OtherText.Text);
        ContinueButton.IsEnabled = !_busy && !_conflict && (_pending is not null || (_selected.Count > 0 && validOther));
        ContinueButton.Content = _pending is null ? "Continue" : _copy.Retry;
        SkipButton.IsEnabled = !_busy && !_conflict && _pending is null;
        QuestionBackButton.IsEnabled = !_busy && !_conflict && _pending is null && _index > 0;
    }

    private void UpdateIllustration()
    {
        var details = _index switch
        {
            0 => ("search", "Find your way to Echo.", "Tell us where you first heard about Echo."),
            1 => ("mic", "Speak naturally.", "Dictation, meetings, or exploration — choose what matters to you."),
            2 => ("developer", "Made for your work.", "Echo can fit into the tools you already use."),
            3 => ("doc", "Write anywhere.", "Messages, documents, notes and more can start with your voice."),
            4 => ("conversation", "Keep meetings moving.", "Choose the meeting tools in your day."),
            _ => ("notes", "Stay in the conversation.", "Tell us what makes meetings hard, so we can improve Echo.")
        };
        IllustrationTitle.Text = details.Item2;
        IllustrationDescription.Text = details.Item3;
        var variant = ActualTheme == ElementTheme.Dark ? ".dark" : "";
        IllustrationIcon.Source = new SvgImageSource(new Uri("ms-appx:///Assets/icons/" + details.Item1 + variant + ".svg"));
    }

    private async void OnContinueClick(object sender, RoutedEventArgs e) => await SaveAnswerAsync(skip: false);
    private async void OnSkipClick(object sender, RoutedEventArgs e) => await SaveAnswerAsync(skip: true);

    private async Task SaveAnswerAsync(bool skip)
    {
        if (_busy || !_ready || _conflict) return;
        SetBusy(true);
        try
        {
            if (_pending is null)
            {
                var question = OnboardingQuestionCatalog.All[_index];
                if (!skip && (_selected.Count == 0
                    || (_selected.Contains("other") && string.IsNullOrWhiteSpace(OtherText.Text))))
                {
                    QuestionStatus.Text = "Choose an answer, add details for Other, or skip.";
                    return;
                }
                _answers[question.Key] = skip
                    ? new OnboardingContextAnswer { Skipped = true }
                    : new OnboardingContextAnswer
                    {
                        Choices = _selected.Order(StringComparer.Ordinal).ToList(),
                        Other = _selected.Contains("other") ? OtherText.Text.Trim() : ""
                    };
                _pending = new OnboardingContextSubmission
                {
                    ExpectedRevision = _revision,
                    Answers = _answers.ToDictionary(pair => pair.Key, pair => Clone(pair.Value)),
                    Completed = _index == OnboardingQuestionCatalog.All.Length - 1,
                    UiLanguage = _copy?.Language ?? "en"
                };
                await SaveDraftAsync();
            }
            QuestionStatus.Text = _copy?.Saving ?? "Saving…";
            var saved = await _context.SaveAsync(_pending, _lifetime.Token);
            if (_lifetime.IsCancellationRequested) return;
            _revision = saved.Revision;
            _confirmedCompletedAt = saved.CompletedAt;
            _answers.Clear();
            foreach (var (key, value) in saved.Answers) _answers[key] = Clone(value);
            ApplyLocalAnswers(saved.Answers);
            _pending = null;
            if (_index == OnboardingQuestionCatalog.All.Length - 1)
            {
                await SaveDraftAsync();
                Frame.Navigate(typeof(TryItIntroStepPage));
                return;
            }
            _index++;
            await SaveDraftAsync();
            QuestionStatus.Text = "";
            RenderQuestion();
        }
        catch (OperationCanceledException) when (_lifetime.IsCancellationRequested) { }
        catch (HttpRequestException ex) when (ex.StatusCode == HttpStatusCode.Conflict)
        {
            _conflict = true;
            QuestionStatus.Text = _copy?.Conflict ?? "Answers changed on another device.";
            ReloadButton.Content = _copy?.Reload ?? "Reload saved answers";
            ReloadButton.Visibility = Visibility.Visible;
        }
        catch (Exception ex)
        {
            QuestionStatus.Text = (_copy?.SaveError ?? "Could not confirm the save. Your answer is still here.") + " " + ex.Message;
        }
        finally { SetBusy(false); UpdateOptionVisuals(); }
    }

    private async void OnBackClick(object sender, RoutedEventArgs e)
    {
        if (_busy || !_ready || _conflict || _pending is not null || _index == 0) return;
        try
        {
            _index--;
            await SaveDraftAsync();
            QuestionStatus.Text = "";
            RenderQuestion();
        }
        catch (Exception ex) { QuestionStatus.Text = "Could not save your progress. " + ex.Message; }
    }

    private async void OnReloadClick(object sender, RoutedEventArgs e)
    {
        if (_busy) return;
        try
        {
            var discardDraft = _conflict;
            if (discardDraft) _pending = null;
            await LoadAsync(discardDraft);
            if (discardDraft && !_lifetime.IsCancellationRequested && _owner.Length > 0
                && ReloadButton.Visibility == Visibility.Collapsed) await SaveDraftAsync();
        }
        catch (Exception ex) { QuestionStatus.Text = "Could not reload your answers. " + ex.Message; }
    }

    private async Task SaveDraftAsync()
    {
        if (_owner.Length == 0) return;
        await _context.SaveDraftAsync(new OnboardingContextDraft
        {
            OwnerId = _owner,
            Index = _index,
            Revision = _revision,
            ConfirmedCompletedAt = _confirmedCompletedAt,
            Answers = _answers.ToDictionary(pair => pair.Key, pair => Clone(pair.Value)),
            Pending = _pending
        }, _lifetime.Token);
    }

    private void SetBusy(bool busy)
    {
        _busy = busy;
        UpdateOptionVisuals();
        ReloadButton.IsEnabled = !busy;
    }

    private void OnLayoutSizeChanged(object sender, SizeChangedEventArgs e)
    {
        var split = e.NewSize.Width >= 850;
        IllustrationPanel.Visibility = split ? Visibility.Visible : Visibility.Collapsed;
        QuestionColumn.Width = split ? new GridLength(5, GridUnitType.Star) : new GridLength(1, GridUnitType.Star);
        IllustrationColumn.Width = split ? new GridLength(6, GridUnitType.Star) : new GridLength(0);
        var questionWidth = split ? e.NewSize.Width * 5d / 11d : e.NewSize.Width;
        var compactFooter = questionWidth < 510;
        Grid.SetRow(ContinueButton, compactFooter ? 1 : 0);
        Grid.SetColumn(ContinueButton, compactFooter ? 0 : 3);
        Grid.SetColumnSpan(ContinueButton, compactFooter ? 4 : 1);
        ContinueButton.HorizontalAlignment = compactFooter ? HorizontalAlignment.Stretch : HorizontalAlignment.Center;
    }

    private static OnboardingContextAnswer Clone(OnboardingContextAnswer answer) => new()
    {
        Choices = [..answer.Choices], Other = answer.Other, Skipped = answer.Skipped
    };

    private void ApplyLocalAnswers(Dictionary<string, OnboardingContextAnswer> answers)
    {
        if (answers.TryGetValue("work", out var work) && work.Choices.Count > 0)
            _settings.SaveSetting("UserRole", work.Choices[0]);
        if (answers.TryGetValue("writing", out var writing))
            _settings.SaveSetting("TypingPlaces", writing.Choices);
    }

    private static bool SameAnswers(
        Dictionary<string, OnboardingContextAnswer> left,
        Dictionary<string, OnboardingContextAnswer> right) =>
        left.Count == right.Count && right.All(pair => left.TryGetValue(pair.Key, out var answer)
            && answer.Skipped == pair.Value.Skipped && answer.Other == pair.Value.Other
            && answer.Choices.Order(StringComparer.Ordinal).SequenceEqual(
                pair.Value.Choices.Order(StringComparer.Ordinal)));

    private sealed class QuestionnaireCopy
    {
        public required string Language { get; init; }
        public required string Stage { get; init; }
        public required string Single { get; init; }
        public required string Multiple { get; init; }
        public required string OtherPrompt { get; init; }
        public required string Skip { get; init; }
        public required string Retry { get; init; }
        public required string Reload { get; init; }
        public required string Loading { get; init; }
        public required string Saving { get; init; }
        public required string LoadError { get; init; }
        public required string SaveError { get; init; }
        public required string Conflict { get; init; }
        public required string[] Headings { get; init; }
        public required Dictionary<string, string[]> Options { get; init; }

        public static QuestionnaireCopy Load(string preferredLanguage)
        {
            var path = Path.Combine(AppContext.BaseDirectory, "Assets", "QuestionnaireLanguages.json");
            using var document = JsonDocument.Parse(File.ReadAllText(path));
            var language = preferredLanguage == "auto" ? CultureInfo.CurrentUICulture.Name : preferredLanguage;
            if (language.StartsWith("zh-", StringComparison.OrdinalIgnoreCase) &&
                !language.Equals("zh-Hant", StringComparison.OrdinalIgnoreCase) &&
                !language.StartsWith("zh-TW", StringComparison.OrdinalIgnoreCase) &&
                !language.StartsWith("zh-HK", StringComparison.OrdinalIgnoreCase)) language = "zh-Hans";
            if (!document.RootElement.TryGetProperty(language, out var localized))
            {
                language = language.Split('-')[0];
                if (!document.RootElement.TryGetProperty(language, out localized))
                {
                    language = "en";
                    localized = document.RootElement.GetProperty(language);
                }
            }
            var headings = localized.GetProperty("headings").EnumerateArray()
                .Select(item => item.GetString() ?? "").ToArray();
            var options = new Dictionary<string, string[]>();
            var optionSource = localized.GetProperty("options");
            foreach (var question in OnboardingQuestionCatalog.All)
                options[question.Key] = optionSource.GetProperty(question.Key).EnumerateArray()
                    .Select(item => item.GetString() ?? "").ToArray();
            if (headings.Length != OnboardingQuestionCatalog.All.Length
                || OnboardingQuestionCatalog.All.Any(question => options[question.Key].Length != question.Options.Length))
                throw new InvalidDataException("The Mac Echo questionnaire labels are incomplete.");
            string Text(string key) => localized.GetProperty(key).GetString() ?? "";
            return new QuestionnaireCopy
            {
                Language = language, Stage = Text("stage"), Single = Text("single"),
                Multiple = Text("multiple"), OtherPrompt = Text("otherPrompt"),
                Skip = Text("skip"), Retry = Text("retry"), Reload = Text("reload"),
                Loading = Text("loading"), Saving = Text("saving"),
                LoadError = Text("loadError"), SaveError = Text("saveError"),
                Conflict = Text("conflict"), Headings = headings, Options = options
            };
        }
    }
}
