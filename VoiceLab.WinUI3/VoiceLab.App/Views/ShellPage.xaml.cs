using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using VoiceLab.App.Services;
using VoiceLab.Infrastructure.Hotkeys;
using Microsoft.Extensions.DependencyInjection;
using System.Runtime.InteropServices;
using Microsoft.UI.Xaml.Media;
using Microsoft.UI.Xaml.Input;
using Microsoft.UI.Xaml.Media.Imaging;
using VoiceLab.Infrastructure.Services;

namespace VoiceLab.App.Views;

public sealed partial class ShellPage : Page
{
    private readonly IRecordingCoordinator _recorder;
    private readonly IGlobalHotkeyService _hotkeys;
    private Button[] _navButtons = [];
    private bool _sidebarCollapsed;
    private bool _manualSidebarChoice;
    private string _currentTag = "Home";
    private readonly IAccountNotificationService _notifications = App.Services.GetRequiredService<IAccountNotificationService>();
    private readonly DispatcherTimer _inboxRefreshTimer = new() { Interval = TimeSpan.FromMinutes(1) };
    private readonly DispatcherTimer _usageSyncTimer = new() { Interval = TimeSpan.FromMinutes(5) };
    private readonly List<InboxNotification> _inboxItems = [];
    private long? _nextInboxCursor;
    private long? _throughInboxCursor;
    private int _unreadCount;
    private bool _inboxBusy;
    private bool _inboxRefreshAgain;
    private bool _shortcutReleasePending;
    private string _pressedShortcutMode = "toggle";

    public ShellPage()
    {
        this.InitializeComponent();

        _navButtons = [HistoryNav, VocabularyNav, NotesNav, UploadNav, HomeNav, SnippetsNav, StatisticsNav, SettingsNav];
        _inboxRefreshTimer.Tick += async (_, _) => await RefreshInboxAsync();
        _usageSyncTimer.Tick += async (_, _) =>
            await App.Services.GetRequiredService<IAccountUsageSyncService>().SyncAsync();
        Navigate("Home");
        ActualThemeChanged += (_, _) => { App.UpdateThemePalette(ActualTheme); App.Services.GetRequiredService<IRecordingOverlayService>().ApplyTheme(ActualTheme); ApplyIconTheme(); ApplySelection(); };
        Loaded += async (_, _) =>
        {
            App.UpdateThemePalette(ActualTheme);
            App.Services.GetRequiredService<IRecordingOverlayService>().ApplyTheme(ActualTheme);
            ApplyIconTheme();
            ApplySelection();
            _inboxRefreshTimer.Start();
            _usageSyncTimer.Start();
            _ = App.Services.GetRequiredService<IAccountUsageSyncService>().SyncAsync();
            await RefreshInboxAsync();
        };
        var searchAccelerator = new KeyboardAccelerator
        {
            Key = Windows.System.VirtualKey.K,
            Modifiers = Windows.System.VirtualKeyModifiers.Control
        };
        searchAccelerator.Invoked += (_, args) => { OnSearchClick(this, new RoutedEventArgs()); args.Handled = true; };
        KeyboardAccelerators.Add(searchAccelerator);
        Loaded += async (_, _) =>
        {
            var user = await App.Services.GetRequiredService<VoiceLab.Infrastructure.Services.IAuthenticationService>().GetCurrentUserAsync();
            AccountName.Text = user?.Name ?? user?.Email ?? "VoiceLab account";
            var display = user?.Name?.Trim();
            if (string.IsNullOrWhiteSpace(display)) display = user?.Email?.Trim();
            AccountInitialText.Text = string.IsNullOrWhiteSpace(display) ? "V" : display[..1].ToUpperInvariant();
        };
        _recorder = App.Services.GetRequiredService<IRecordingCoordinator>();
        _hotkeys = App.Services.GetRequiredService<IGlobalHotkeyService>();
        _recorder.StateChanged += OnRecordingStateChanged;
        _hotkeys.HotkeyPressed += OnGlobalHotkeyPressed;
        _hotkeys.HotkeyReleased += OnGlobalHotkeyReleased;
        _hotkeys.PasteHotkeyPressed += OnPasteHotkeyPressed;
        Unloaded += (_, _) =>
        {
            _inboxRefreshTimer.Stop();
            _usageSyncTimer.Stop();
            _recorder.StateChanged -= OnRecordingStateChanged;
            _hotkeys.HotkeyPressed -= OnGlobalHotkeyPressed;
            _hotkeys.HotkeyReleased -= OnGlobalHotkeyReleased;
            _hotkeys.PasteHotkeyPressed -= OnPasteHotkeyPressed;
        };
    }

    private async void OnRecordClick(object sender, RoutedEventArgs e)
    {
        await App.Services.GetRequiredService<IRecordingCoordinator>().ToggleAsync(GetForegroundWindow());
    }

    private async void OnRetryClick(object sender, RoutedEventArgs e) => await _recorder.RetryAsync();

    private async void OnGlobalHotkeyPressed(object? sender, EventArgs e)
    {
        var mode = App.Services.GetRequiredService<ISettingsService>().GetSetting("ActivationMode", "automatic");
        if (mode is not ("automatic" or "hold") || !_hotkeys.IsReleaseTrackingAvailable)
        {
            _shortcutReleasePending = false;
            await _recorder.ToggleAsync(GetForegroundWindow(), fromShortcut: true);
            return;
        }
        if (_recorder.State is RecordingState.Idle or RecordingState.Error)
        {
            _pressedShortcutMode = mode;
            _shortcutReleasePending = true;
            await _recorder.ToggleAsync(GetForegroundWindow(), fromShortcut: true);
        }
        else if (_recorder.State == RecordingState.Recording)
        {
            // A second press ends hands-free dictation and is also a recovery
            // path if Windows did not deliver a release notification.
            _shortcutReleasePending = false;
            await _recorder.ToggleAsync(GetForegroundWindow(), fromShortcut: true);
        }
    }

    private async void OnGlobalHotkeyReleased(object? sender, ShortcutReleasedEventArgs e)
    {
        if (!_shortcutReleasePending) return;
        _shortcutReleasePending = false;
        if (_recorder.State != RecordingState.Recording) return;
        if (_pressedShortcutMode == "automatic" && e.HeldDuration < TimeSpan.FromMilliseconds(300))
            return; // A short tap leaves the microphone on until the next press.
        if (_pressedShortcutMode == "hold" && e.HeldDuration < TimeSpan.FromMilliseconds(250))
            await _recorder.CancelAsync(); // Ignore an accidental tap in hold mode.
        else
            await _recorder.ToggleAsync(GetForegroundWindow());
    }

    private async void OnPasteHotkeyPressed(object? sender, EventArgs e) =>
        await _recorder.PasteLastTranscriptAsync(GetForegroundWindow());

    private void OnRecordingStateChanged(object? sender, RecordingStateChangedEventArgs e)
    {
        DispatcherQueue.TryEnqueue(() =>
        {
            if (e.State is RecordingState.Idle or RecordingState.Error) _shortcutReleasePending = false;
            RecordingIndicator.Visibility = e.State == RecordingState.Idle ? Visibility.Collapsed : Visibility.Visible;
            RecordingStatusText.Text = e.Message;
            RecordButtonText.Text = e.State == RecordingState.Recording ? "Finish dictation" : "Start dictation";
            RetryButton.Visibility = e.State == RecordingState.Error && _recorder.CanRetry
                ? Visibility.Visible : Visibility.Collapsed;
            ApplyRecordIcon();
        });
    }

    [DllImport("user32.dll")] private static extern IntPtr GetForegroundWindow();

    private void OnNavClick(object sender, RoutedEventArgs e)
    {
        if (sender is Button { Tag: string tag }) Navigate(tag);
    }

    private void OnSidebarToggleClick(object sender, RoutedEventArgs e)
    {
        _manualSidebarChoice = true;
        SetSidebarCollapsed(!_sidebarCollapsed);
    }

    private void OnShellSizeChanged(object sender, SizeChangedEventArgs e)
    {
        if (!_manualSidebarChoice || e.NewSize.Width < 680) SetSidebarCollapsed(e.NewSize.Width < 780);
        RecordButtonText.Visibility = e.NewSize.Width < 650 ? Visibility.Collapsed : Visibility.Visible;
        RecordingStatusText.MaxWidth = e.NewSize.Width < 900 ? 110 : 280;
    }

    private void SetSidebarCollapsed(bool collapsed)
    {
        _sidebarCollapsed = collapsed;
        SidebarColumn.Width = new GridLength(collapsed ? 124 : 220);
        SidebarRootGrid.Padding = collapsed ? new Thickness(6, 12, 6, 14) : new Thickness(12, 12, 12, 14);
        AccountRow.ColumnSpacing = collapsed ? 2 : 4;
        AccountSection.Margin = collapsed ? new Thickness(0) : new Thickness(6, 0, 0, 0);
        AccountSection.HorizontalAlignment = collapsed ? HorizontalAlignment.Center : HorizontalAlignment.Left;
        foreach (var label in new[] { BrandName, SearchLabel, HomeLabel, HistoryLabel, VocabularyLabel,
            NotesLabel, UploadLabel, SnippetsLabel, StatisticsLabel, WorkspaceHeading, MoreHeading, AccountName })
            label.Visibility = collapsed ? Visibility.Collapsed : Visibility.Visible;
        SearchButton.HorizontalContentAlignment = collapsed ? HorizontalAlignment.Center : HorizontalAlignment.Left;
        foreach (var button in _navButtons.Where(button => button != SettingsNav))
            button.HorizontalContentAlignment = collapsed ? HorizontalAlignment.Center : HorizontalAlignment.Left;
        Microsoft.UI.Xaml.Automation.AutomationProperties.SetName(SidebarToggleButton, collapsed ? "Expand sidebar" : "Collapse sidebar");
        ApplyIconTheme();
    }

    private void ApplyIconTheme()
    {
        var suffix = ActualTheme == ElementTheme.Dark ? ".dark.svg" : ".svg";
        foreach (var (icon, file) in new (Image icon, string file)[]
        {
            (SearchIcon, "search"), (HomeIcon, "home"), (HistoryIcon, "history"),
            (VocabularyIcon, "knowledge"), (NotesIcon, "notes"), (UploadIcon, "upload"),
            (SnippetsIcon, "clipboard"), (StatisticsIcon, "statistics"), (SettingsIcon, "settings"),
            (NotificationsIcon, "notifications"),
            (SidebarToggleIcon, _sidebarCollapsed ? "sidebar-closed" : "sidebar-open")
        })
            icon.Source = new SvgImageSource(new Uri($"ms-appx:///Assets/icons/{file}{suffix}"));
        ApplyRecordIcon();
    }

    private void ApplyRecordIcon()
    {
        // The filled button inverts with the page theme: light artwork belongs
        // on its dark surface, and dark artwork on its light surface.
        var icon = _recorder?.State == RecordingState.Recording ? "pause" : "mic";
        var suffix = ActualTheme == ElementTheme.Dark ? ".svg" : ".dark.svg";
        RecordIcon.Source = new SvgImageSource(new Uri($"ms-appx:///Assets/icons/{icon}{suffix}"));
    }

    private async void OnNotificationsFlyoutOpened(object sender, object e) => await RefreshInboxAsync();

    private async Task RefreshInboxAsync()
    {
        if (_inboxBusy) { _inboxRefreshAgain = true; return; }
        _inboxBusy = true;
        InboxStatusText.Text = "Loading notifications…";
        try
        {
            var page = await _notifications.GetPageAsync();
            _inboxItems.Clear();
            _inboxItems.AddRange(page.Items);
            _nextInboxCursor = page.NextCursor;
            _throughInboxCursor = page.ThroughCursor;
            _unreadCount = page.Unread;
            UpdateInbox();
        }
        catch (Exception ex)
        {
            InboxStatusText.Text = "Could not load notifications. " + ex.Message;
        }
        finally
        {
            _inboxBusy = false;
            UpdateInboxControls();
            if (_inboxRefreshAgain)
            {
                _inboxRefreshAgain = false;
                await RefreshInboxAsync();
            }
        }
    }

    private async void OnLoadMoreNotificationsClick(object sender, RoutedEventArgs e)
    {
        if (_inboxBusy || _nextInboxCursor is not { } cursor) return;
        _inboxBusy = true;
        UpdateInboxControls();
        try
        {
            var page = await _notifications.GetPageAsync(cursor);
            var existing = _inboxItems.Select(item => item.Id).ToHashSet();
            _inboxItems.AddRange(page.Items.Where(item => existing.Add(item.Id)));
            _nextInboxCursor = page.NextCursor;
            _unreadCount = page.Unread;
            UpdateInbox();
        }
        catch (Exception ex) { InboxStatusText.Text = "Could not load more notifications. " + ex.Message; }
        finally
        {
            _inboxBusy = false;
            UpdateInboxControls();
            if (_inboxRefreshAgain)
            {
                _inboxRefreshAgain = false;
                await RefreshInboxAsync();
            }
        }
    }

    private async void OnMarkAllReadClick(object sender, RoutedEventArgs e)
    {
        if (_inboxBusy || _throughInboxCursor is not { } boundary || _unreadCount == 0) return;
        _inboxBusy = true;
        UpdateInboxControls();
        try
        {
            await _notifications.MarkReadAsync(throughCursor: boundary);
            _inboxBusy = false;
            _inboxRefreshAgain = false;
            await RefreshInboxAsync();
        }
        catch (Exception ex) { InboxStatusText.Text = "Could not mark notifications read. " + ex.Message; }
        finally
        {
            _inboxBusy = false;
            UpdateInboxControls();
            if (_inboxRefreshAgain)
            {
                _inboxRefreshAgain = false;
                await RefreshInboxAsync();
            }
        }
    }

    private async void OnNotificationItemClick(object sender, ItemClickEventArgs e)
    {
        if (e.ClickedItem is not InboxNotification item) return;
        NotificationsFlyout.Hide();
        var destination = item.Destination switch
        {
            "notes" => "Notes", "vocabulary" => "Vocabulary", "settings" => "Settings", _ => "Home"
        };
        if (!Navigate(destination)) return;
        if (item.Read) return;
        try
        {
            await _notifications.MarkReadAsync(id: item.Id);
            await RefreshInboxAsync();
        }
        catch (Exception ex) { InboxStatusText.Text = "Could not mark notification read. " + ex.Message; }
    }

    private void UpdateInbox()
    {
        NotificationList.ItemsSource = null;
        NotificationList.ItemsSource = _inboxItems.ToList();
        InboxStatusText.Text = _inboxItems.Count == 0 ? "No notifications yet" : "";
        UpdateInboxControls();
    }

    private void UpdateInboxControls()
    {
        UnreadDot.Visibility = _unreadCount > 0 ? Visibility.Visible : Visibility.Collapsed;
        UnreadCountText.Text = _unreadCount > 0 ? _unreadCount > 99 ? "99+ unread" : $"{_unreadCount} unread" : "";
        MarkAllReadButton.IsEnabled = !_inboxBusy && _unreadCount > 0 && _throughInboxCursor is not null;
        LoadMoreNotificationsButton.IsEnabled = !_inboxBusy && _nextInboxCursor is not null;
        LoadMoreNotificationsButton.Visibility = _nextInboxCursor is not null ? Visibility.Visible : Visibility.Collapsed;
    }

    private bool Navigate(string tag)
    {
        var page = tag switch
        {
            "Home" => typeof(HomePage), "History" => typeof(HistoryPage),
            "Upload" => typeof(UploadPage), "Notes" => typeof(NotesPage),
            "Vocabulary" => typeof(VocabularyPage), "Snippets" => typeof(SnippetsPage),
            "Statistics" => typeof(StatisticsPage), "Settings" => typeof(SettingsPage),
            _ => typeof(HistoryPage)
        };
        if (ContentFrame.CurrentSourcePageType != page && !ContentFrame.Navigate(page)) return false;
        HeaderText.Text = tag switch { "Home" => "Home", "Upload" => "Upload audio", _ => tag };
        _currentTag = tag;
        ApplySelection();
        return true;
    }

    private void ApplySelection()
    {
        var selection = (Brush)Application.Current.Resources["EchoSelectionBrush"];
        foreach (var button in _navButtons)
        {
            var selected = button.Tag?.ToString() == _currentTag;
            button.Background = selected ? selection : new SolidColorBrush(Windows.UI.Color.FromArgb(0, 0, 0, 0));
            button.FontWeight = selected ? Microsoft.UI.Text.FontWeights.SemiBold : Microsoft.UI.Text.FontWeights.Normal;
        }
    }

    private void OnSearchClick(object sender, RoutedEventArgs e)
    {
        Navigate("History");
        if (ContentFrame.Content is HistoryPage history) history.FocusSearch();
    }

    public void NavigateToHistory()
    {
        Navigate("History");
    }

    public void NavigateToSettings() => Navigate("Settings");

    public void NavigateToStatistics() => Navigate("Statistics");

    public void ShowHotkeyError() => HotkeyWarning.IsOpen = true;

    public void ClearHotkeyError() => HotkeyWarning.IsOpen = false;

}
