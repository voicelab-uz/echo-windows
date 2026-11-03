using Microsoft.Extensions.DependencyInjection;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using VoiceLab.App.Services;
using VoiceLab.Infrastructure.Services;

namespace VoiceLab.App.Views;

public sealed partial class HomePage : Page
{
    private readonly ITranscriptionService _transcriptions = App.Services.GetRequiredService<ITranscriptionService>();
    private readonly IStatisticsService _statistics = App.Services.GetRequiredService<IStatisticsService>();
    private readonly IAuthenticationService _authentication = App.Services.GetRequiredService<IAuthenticationService>();
    private readonly IAccountStatisticsService _accountStatistics = App.Services.GetRequiredService<IAccountStatisticsService>();
    private readonly IAccountHistoryService _accountHistory = App.Services.GetRequiredService<IAccountHistoryService>();
    private readonly ISettingsService _settings = App.Services.GetRequiredService<ISettingsService>();
    private int _loadVersion;

    public HomePage()
    {
        InitializeComponent();
        var shortcut = _settings.GetShortcutLabel();
        ShortcutHintText.Text = $"Your voice, ready when you are. Use {shortcut} to dictate anywhere.";
        EmptyHintText.Text = $"Use {shortcut} to begin. The floating control can stop your dictation.";
        Loaded += async (_, _) => await LoadDashboardAsync();
        Unloaded += (_, _) => _loadVersion++;
    }

    private static string GetGreeting(int hour) => hour switch
    {
        < 12 => "Good morning",
        < 17 => "Good afternoon",
        _ => "Good evening"
    };

    private async Task LoadDashboardAsync()
    {
        var version = ++_loadVersion;
        string? accountId = null;
        try
        {
            var user = await _authentication.GetCurrentUserAsync();
            if (version != _loadVersion) return;
            accountId = user?.Id;
            var firstName = user?.Name?.Split(' ', StringSplitOptions.RemoveEmptyEntries).FirstOrDefault() ?? Environment.UserName;
            GreetingText.Text = $"{GetGreeting(DateTime.Now.Hour)}, {firstName}";

            var stats = await _statistics.GetStatsAsync();
            if (version != _loadVersion) return;
            TranscriptionCount.Text = stats.TotalTranscriptions.ToString("N0");
            WordCount.Text = stats.TotalWords.ToString("N0");
            TimeSaved.Text = stats.HoursSaved >= 1
                ? $"{stats.HoursSaved:0.#} hr"
                : $"{stats.HoursSaved * 60:0} min";
            HomeDataSourceText.Text = "Saved on this device";

            var recent = (await _transcriptions.GetHistoryAsync())
                .OrderByDescending(item => item.CreatedAt)
                .Take(5)
                .ToList();
            if (version != _loadVersion) return;
            RecentList.ItemsSource = recent;
            EmptyState.Visibility = recent.Count == 0 ? Visibility.Visible : Visibility.Collapsed;
            if (accountId is not null)
                await Task.WhenAll(LoadAccountStatisticsAsync(accountId, version),
                    LoadAccountHistoryAsync(accountId, recent, version));
        }
        catch
        {
            if (version != _loadVersion) return;
            // Keep the dashboard usable if a local data file is temporarily unavailable.
            RecentList.ItemsSource = Array.Empty<Transcription>();
            EmptyState.Visibility = Visibility.Visible;
        }
    }

    private async Task<bool> IsCurrentAccountAsync(string accountId, int version) =>
        version == _loadVersion && accountId == (await _authentication.GetCurrentUserAsync())?.Id;

    private async Task LoadAccountStatisticsAsync(string accountId, int version)
    {
        try
        {
            await App.Services.GetRequiredService<IAccountUsageSyncService>().SyncAsync();
            var snapshot = await _accountStatistics.GetAsync();
            if (!await IsCurrentAccountAsync(accountId, version)) return;
            var metrics = StatisticsMetrics.FromRows(snapshot.Days.Select(day =>
                new StatisticsDay(DateOnly.Parse(day.Day), day.Words, day.Recordings, day.DurationMs, day.Platform)));
            TranscriptionCount.Text = metrics.Recordings.ToString("N0");
            WordCount.Text = metrics.Words.ToString("N0");
            var seconds = metrics.SecondsSaved(_settings.GetSetting("TypingWordsPerMinute", 40));
            TimeSaved.Text = seconds >= 3600 ? $"{seconds / 3600:0.#} hr" : $"{seconds / 60:0} min";
            HomeDataSourceText.Text = "Across your account · six months";
        }
        catch (Exception ex)
        {
            System.Diagnostics.Debug.WriteLine($"Home account statistics unavailable: {ex.Message}");
        }
    }

    private async Task LoadAccountHistoryAsync(string accountId, List<Transcription> local, int version)
    {
        try
        {
            var page = await _accountHistory.GetPageAsync(1);
            if (!await IsCurrentAccountAsync(accountId, version)) return;
            var merged = new List<Transcription>(local);
            var positions = new Dictionary<string, int>(StringComparer.Ordinal);
            for (var index = 0; index < merged.Count; index++)
                positions.TryAdd(merged[index].Id, index);
            foreach (var remote in page.Items)
            {
                if (positions.TryGetValue(remote.Id, out var index))
                {
                    if (remote.Revision.GetValueOrDefault() > merged[index].Revision.GetValueOrDefault())
                        merged[index] = remote;
                    continue;
                }
                positions.Add(remote.Id, merged.Count);
                merged.Add(remote);
            }
            var recent = merged.OrderByDescending(item => item.CreatedAt).Take(5).ToList();
            RecentList.ItemsSource = recent;
            EmptyState.Visibility = recent.Count == 0 ? Visibility.Visible : Visibility.Collapsed;
        }
        catch (Exception ex)
        {
            System.Diagnostics.Debug.WriteLine($"Home account history unavailable: {ex.Message}");
        }
    }

    private void OnHomeStatsSizeChanged(object sender, SizeChangedEventArgs e)
    {
        var columns = e.NewSize.Width >= 760 ? 3 : e.NewSize.Width >= 500 ? 2 : 1;
        HomeStatsGrid.ColumnDefinitions.Clear();
        HomeStatsGrid.RowDefinitions.Clear();
        for (var i = 0; i < columns; i++) HomeStatsGrid.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
        for (var i = 0; i < (3 + columns - 1) / columns; i++) HomeStatsGrid.RowDefinitions.Add(new RowDefinition { Height = GridLength.Auto });
        var cards = new[] { HomeTranscriptionsCard, HomeWordsCard, HomeTimeCard };
        for (var i = 0; i < cards.Length; i++) { Grid.SetColumn(cards[i], i % columns); Grid.SetRow(cards[i], i / columns); }
    }

    private void OnHomeScrollSizeChanged(object sender, SizeChangedEventArgs e)
    {
        HomeContent.Width = Math.Max(0, Math.Min(1080, e.NewSize.Width));
        var narrow = e.NewSize.Width < 520;
        HomeRecentHeader.ColumnDefinitions.Clear();
        HomeRecentHeader.RowDefinitions.Clear();
        HomeRecentHeader.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
        if (!narrow) HomeRecentHeader.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        HomeRecentHeader.RowDefinitions.Add(new RowDefinition { Height = GridLength.Auto });
        if (narrow) HomeRecentHeader.RowDefinitions.Add(new RowDefinition { Height = GridLength.Auto });
        Grid.SetColumn(ViewHistoryButton, narrow ? 0 : 1);
        Grid.SetRow(ViewHistoryButton, narrow ? 1 : 0);
        ViewHistoryButton.HorizontalAlignment = narrow ? HorizontalAlignment.Left : HorizontalAlignment.Right;
    }

    private void OnViewHistoryClick(object sender, RoutedEventArgs e)
    {
        if (App.MainWindow?.Content is ShellPage shell) shell.SearchHistory();
    }

    private async void OnDeleteClick(object sender, RoutedEventArgs e)
    {
        if (sender is not Button { Tag: string id }) return;
        try
        {
            await _transcriptions.DeleteTranscriptionAsync(id);
            await LoadDashboardAsync();
        }
        catch (Exception ex) { await ShowErrorAsync(ex.Message); }
    }

    private async void OnCopyClick(object sender, RoutedEventArgs e)
    {
        if (sender is not Button { Tag: string text } button) return;
        try { await ClipboardFeedback.CopyAsync(button, text); }
        catch (Exception ex) { await ShowErrorAsync(ex.Message); }
    }

    private async Task ShowErrorAsync(string message)
    {
        var dialog = new ContentDialog { XamlRoot = XamlRoot, Title = "Echo", Content = message, CloseButtonText = "OK" };
        await dialog.ShowAsync();
    }

}
