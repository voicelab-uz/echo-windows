using Microsoft.Extensions.DependencyInjection;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Media;
using Microsoft.UI.Xaml.Shapes;
using VoiceLab.App.Services;
using VoiceLab.Infrastructure.Services;

namespace VoiceLab.App.Views;

public sealed partial class StatisticsPage : Page
{
    private readonly ISettingsService _settings = App.Services.GetRequiredService<ISettingsService>();
    private readonly CancellationTokenSource _loading = new();
    private StatisticsMetrics _metrics = StatisticsMetrics.FromRows([]);
    private List<Transcription> _localHistory = [];
    private IReadOnlyList<UsageOutboxItem> _pendingAttribution = [];
    private AccountStatisticsSnapshot? _remote;
    private bool _ready;

    public StatisticsPage()
    {
        InitializeComponent();
        Loaded += async (_, _) =>
        {
            TypingSpeedBox.Value = Math.Clamp(_settings.GetSetting("TypingWordsPerMinute", 40), 10, 200);
            _ready = true;
            await Task.WhenAll(LoadStatisticsAsync(), LoadCloudUsageAsync());
        };
        Unloaded += (_, _) => _loading.Cancel();
        ActualThemeChanged += (_, _) => RenderAll();
    }

    private async Task LoadStatisticsAsync()
    {
        try
        {
            _localHistory = await App.Services.GetRequiredService<ITranscriptionService>().GetHistoryAsync();
            _metrics = StatisticsMetrics.FromLocalHistory(_localHistory);
            DataSourceText.Text = "Local history · six months";
            RenderAll();
        }
        catch (Exception ex)
        {
            EmptyText.Text = $"Local statistics could not be loaded: {ex.Message}";
            EmptyText.Visibility = Visibility.Visible;
            return;
        }

        try
        {
            await App.Services.GetRequiredService<IAccountUsageSyncService>().SyncAsync(_loading.Token);
            _pendingAttribution = await App.Services.GetRequiredService<IAccountUsageSyncService>()
                .GetPendingAsync(_loading.Token);
            _remote = await App.Services.GetRequiredService<IAccountStatisticsService>().GetAsync(_loading.Token);
            if (_loading.IsCancellationRequested) return;
            _metrics = StatisticsMetrics.FromRows(_remote.Days.Select(day =>
                new StatisticsDay(DateOnly.Parse(day.Day), day.Words, day.Recordings, day.DurationMs, day.Platform)));
            DataSourceText.Text = "Account history · six months";
            RenderAll();
        }
        catch (OperationCanceledException) { }
        catch (Exception ex)
        {
            System.Diagnostics.Debug.WriteLine($"Account statistics unavailable; using local history: {ex.Message}");
            DataSourceText.Text = "Local history · six months · account data unavailable";
            RenderDesktopUsage();
        }
    }

    private async Task LoadCloudUsageAsync()
    {
        try
        {
            var cloud = await App.Services.GetRequiredService<ICloudUsageService>().GetUsageAsync();
            if (_loading.IsCancellationRequested) return;
            CloudPlanText.Text = cloud.Enabled ? cloud.PlanName : "VoiceLab Cloud is not enabled for this account.";
            CloudUsageProgress.Value = cloud.LimitSeconds > 0 ? Math.Clamp(cloud.UsedSeconds * 100d / cloud.LimitSeconds, 0, 100) : 0;
            CloudRemainingText.Text = cloud.Enabled ? $"{TimeSpan.FromSeconds(cloud.RemainingSeconds):hh\\:mm\\:ss} remaining" : "";
        }
        catch { if (!_loading.IsCancellationRequested) CloudPlanText.Text = "Cloud usage is temporarily unavailable."; }
    }

    private void RenderAll()
    {
        if (!_ready) return;
        var metrics = _metrics;
        TranscriptionCount.Text = metrics.Recordings.ToString("N0");
        ActiveDaysText.Text = $"{metrics.ActiveDays:N0} active days";
        WordCount.Text = metrics.Words.ToString("N0");
        SpeedValue.Text = metrics.WordsPerMinute is double speed ? Math.Round(speed).ToString("N0") : "—";
        TodayWords.Text = metrics.TodayWords.ToString("N0");
        TodayDetail.Text = $"{metrics.TodayRecordings:N0} recordings today";
        AverageWords.Text = metrics.Recordings > 0 ? metrics.AverageLength.ToString("N0") : "—";
        StreakText.Text = $"{metrics.CurrentStreak:N0} day streak";
        LongestStreakText.Text = $"Longest: {metrics.LongestStreak:N0} days";
        EmptyText.Visibility = metrics.Recordings == 0 ? Visibility.Visible : Visibility.Collapsed;
        RenderSavings();
        RenderSpeedArc();
        RenderMiniWeek();
        RenderHeatmap();
        RenderDesktopUsage();
        RenderDeviceSplit();
    }

    private void RenderSavings()
    {
        var seconds = _metrics.SecondsSaved(_settings.GetSetting("TypingWordsPerMinute", 40));
        TimeSaved.Text = FormatDuration(seconds);
    }

    private static string FormatDuration(double seconds)
    {
        if (seconds <= 0) return "0 min";
        if (seconds < 60) return "< 1 min";
        var time = TimeSpan.FromSeconds(seconds);
        return time.TotalHours >= 1 ? $"{(int)time.TotalHours}h {time.Minutes}m" : $"{(int)time.TotalMinutes} min";
    }

    private void OnTypingSpeedChanged(NumberBox sender, NumberBoxValueChangedEventArgs args)
    {
        if (!_ready || double.IsNaN(sender.Value)) return;
        _settings.SaveSetting("TypingWordsPerMinute", (int)Math.Clamp(Math.Round(sender.Value), 10, 200));
        RenderSavings();
    }

    private SolidColorBrush AccentBrush(double opacity = 1)
    {
        return new SolidColorBrush(App.GetAccentColor(ActualTheme == ElementTheme.Dark)) { Opacity = opacity };
    }

    private void RenderSpeedArc()
    {
        SpeedArcCanvas.Children.Clear();
        var progress = Math.Clamp((_metrics.WordsPerMinute ?? 0) / 200d, 0, 1);
        var baseBrush = new SolidColorBrush(ActualTheme == ElementTheme.Dark
            ? Windows.UI.Color.FromArgb(255, 66, 66, 66)
            : Windows.UI.Color.FromArgb(255, 236, 236, 236));
        var accent = AccentBrush();
        for (var index = 0; index < 40; index++) AddArcSegment(index, baseBrush);
        for (var index = 0; index < (int)Math.Round(progress * 40); index++) AddArcSegment(index, accent);
    }

    private void AddArcSegment(int index, Brush brush)
    {
        var start = Math.PI * (1 - index / 40d);
        var end = Math.PI * (1 - (index + 1) / 40d);
        SpeedArcCanvas.Children.Add(new Line
        {
            X1 = 80 + 70 * Math.Cos(start), Y1 = 78 - 70 * Math.Sin(start),
            X2 = 80 + 70 * Math.Cos(end), Y2 = 78 - 70 * Math.Sin(end),
            Stroke = brush, StrokeThickness = 10,
            StrokeStartLineCap = PenLineCap.Round, StrokeEndLineCap = PenLineCap.Round
        });
    }

    private void RenderMiniWeek()
    {
        MiniWeekGrid.Children.Clear();
        MiniWeekGrid.ColumnDefinitions.Clear();
        var days = _metrics.Days.TakeLast(7).ToArray();
        var peak = Math.Max(1, days.Max(day => day.Words));
        for (var index = 0; index < days.Length; index++)
        {
            MiniWeekGrid.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
            var column = new Grid { RowSpacing = 4 };
            column.RowDefinitions.Add(new RowDefinition { Height = new GridLength(1, GridUnitType.Star) });
            column.RowDefinitions.Add(new RowDefinition { Height = GridLength.Auto });
            var bar = new Border { Height = Math.Max(4, days[index].Words * 50d / peak), CornerRadius = new CornerRadius(3),
                Background = AccentBrush(days[index].Words == 0 ? .1 : index == 6 ? 1 : .55),
                VerticalAlignment = VerticalAlignment.Bottom, HorizontalAlignment = HorizontalAlignment.Stretch };
            ToolTipService.SetToolTip(bar, $"{days[index].Day:ddd, MMM d}: {days[index].Words:N0} words");
            column.Children.Add(bar);
            var label = new TextBlock { Text = days[index].Day.ToString("ddd")[..1], FontSize = 10,
                Opacity = .7, TextAlignment = TextAlignment.Center };
            Grid.SetRow(label, 1); column.Children.Add(label);
            Grid.SetColumn(column, index); MiniWeekGrid.Children.Add(column);
        }
    }

    private void RenderHeatmap()
    {
        HeatmapGrid.Children.Clear();
        HeatmapGrid.ColumnDefinitions.Clear();
        HeatmapGrid.RowDefinitions.Clear();
        for (var column = 0; column < 26; column++) HeatmapGrid.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
        for (var row = 0; row < 7; row++) HeatmapGrid.RowDefinitions.Add(new RowDefinition { Height = new GridLength(1, GridUnitType.Star) });
        var peak = Math.Max(1, _metrics.Days.Max(day => day.Recordings));
        for (var index = 0; index < _metrics.Days.Count; index++)
        {
            var day = _metrics.Days[index];
            var intensity = day.Recordings == 0 ? .08 : .25 + .75 * day.Recordings / peak;
            var cell = new Border { Background = AccentBrush(intensity), CornerRadius = new CornerRadius(2),
                MinWidth = 4, MinHeight = 4 };
            ToolTipService.SetToolTip(cell, $"{day.Day:ddd, MMM d}: {day.Recordings:N0} recordings, {day.Words:N0} words");
            Grid.SetColumn(cell, index / 7); Grid.SetRow(cell, index % 7);
            HeatmapGrid.Children.Add(cell);
        }
    }

    private void RenderDesktopUsage()
    {
        UsageCategories.Children.Clear();
        var remoteRows = _remote?.Applications;
        var attributedHistory = _localHistory.Where(item =>
            !string.IsNullOrWhiteSpace(item.SourceAppId) && !string.IsNullOrWhiteSpace(item.SourceAppName)).ToList();
        var pendingById = _pendingAttribution.ToDictionary(item => item.Id, StringComparer.Ordinal);
        var localRows = attributedHistory
            .Select(item => new AccountApplicationDay { AppId = pendingById.TryGetValue(item.Id, out var pending) ? pending.AppId : item.SourceAppId ?? "",
                AppName = pending?.AppName ?? item.SourceAppName ?? "",
                Category = pending?.Category ?? item.SourceCategory ?? "other", Recordings = 1,
                Words = TranscriptionService.CountWords(item.Text) }).ToList();
        var localIds = attributedHistory.Select(item => item.Id).ToHashSet(StringComparer.Ordinal);
        localRows.AddRange(_pendingAttribution.Where(item => !localIds.Contains(item.Id))
            .Select(item => new AccountApplicationDay { AppId = item.AppId, AppName = item.AppName,
                Category = item.Category, Recordings = 1 }));
        var rows = _pendingAttribution.Count == 0 && remoteRows is { Count: > 0 } ? remoteRows : localRows;
        var total = rows.Sum(row => row.Recordings);
        var apps = rows.Select(row => row.AppId).Where(id => id.Length > 0).Distinct(StringComparer.OrdinalIgnoreCase).Count();
        UsageSummaryText.Text = total == 0 ? "New dictations will show their destination apps here."
            : $"{apps:N0} apps · {total:N0} attributed recordings" +
                (_pendingAttribution.Count > 0 ? " · device data while account sync catches up" : "");
        foreach (var (key, label) in new[]
        {
            ("personal", "Personal messages"), ("work", "Work messages"), ("email", "Email"),
            ("ai", "AI prompts"), ("documents", "Documents"), ("other", "Other")
        })
        {
            var count = rows.Where(row => row.Category == key).Sum(row => row.Recordings);
            var row = new Grid { ColumnSpacing = 8 };
            row.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(112) });
            row.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
            row.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(36) });
            row.Children.Add(new TextBlock { Text = label, FontSize = 12, VerticalAlignment = VerticalAlignment.Center,
                TextTrimming = TextTrimming.CharacterEllipsis });
            var progress = new ProgressBar { Minimum = 0, Maximum = 100,
                Value = total > 0 ? count * 100d / total : 0, Foreground = AccentBrush(),
                VerticalAlignment = VerticalAlignment.Center };
            Grid.SetColumn(progress, 1); row.Children.Add(progress);
            var value = new TextBlock { Text = total > 0 ? $"{count * 100d / total:0}%" : "0%", FontSize = 12,
                TextAlignment = TextAlignment.Right, VerticalAlignment = VerticalAlignment.Center };
            Grid.SetColumn(value, 2); row.Children.Add(value);
            UsageCategories.Children.Add(row);
        }
    }

    private void RenderDeviceSplit()
    {
        if (_remote is { } remote)
        {
            // The Mac statistics API supplies platform on each daily row.
            // A separate platform_days collection is optional for newer servers.
            var split = remote.PlatformDays is { Count: > 0 } platformDays ? platformDays : remote.Days;
            DesktopCount.Text = split.Where(day => day.Platform is null or "desktop")
                .Sum(day => day.Recordings).ToString("N0");
            MobileCount.Text = split.Where(day => day.Platform == "ios").Sum(day => day.Recordings).ToString("N0");
            DeviceNote.Text = "Desktop includes Mac and Windows dictations. The current server does not separate them.";
        }
        else
        {
            DesktopCount.Text = _localHistory.Count.ToString("N0");
            MobileCount.Text = "—";
            DeviceNote.Text = "Only this Windows device's retained history is available. iPhone activity requires account statistics.";
        }
    }

    private void OnStatsGridSizeChanged(object sender, SizeChangedEventArgs e) =>
        ArrangeCards(StatsGrid, [SpeedCard, RecordingsCard, WordsCard], e.NewSize.Width >= 850 ? 3 : e.NewSize.Width >= 550 ? 2 : 1);

    private void OnSavingsGridSizeChanged(object sender, SizeChangedEventArgs e) =>
        ArrangeCards(SavingsGrid, [TimeCard, TodayCard, AverageCard], e.NewSize.Width >= 850 ? 3 : e.NewSize.Width >= 550 ? 2 : 1);

    private void OnInsightsGridSizeChanged(object sender, SizeChangedEventArgs e) =>
        ArrangeCards(InsightsGrid, [UsageCard, StreakCard], e.NewSize.Width >= 850 ? 2 : 1);

    private static void ArrangeCards(Grid grid, Border[] cards, int columns)
    {
        grid.ColumnDefinitions.Clear();
        grid.RowDefinitions.Clear();
        for (var index = 0; index < columns; index++) grid.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
        for (var index = 0; index < (cards.Length + columns - 1) / columns; index++) grid.RowDefinitions.Add(new RowDefinition { Height = GridLength.Auto });
        for (var index = 0; index < cards.Length; index++)
        {
            Grid.SetColumn(cards[index], index % columns);
            Grid.SetRow(cards[index], index / columns);
        }
    }

    private void OnStatisticsScrollSizeChanged(object sender, SizeChangedEventArgs e) =>
        StatisticsContent.Width = Math.Max(0, Math.Min(1280, e.NewSize.Width));
}
