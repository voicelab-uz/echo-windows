using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Media;
using Windows.ApplicationModel.DataTransfer;
using VoiceLab.Infrastructure.Services;

namespace VoiceLab.App.Views;

public sealed partial class HistoryPage : Page
{
    public void FocusSearch() => SearchBox.Focus(FocusState.Programmatic);
    private readonly ITranscriptionService _service = (ITranscriptionService)App.Services.GetService(typeof(ITranscriptionService))!;
    private readonly IAccountHistoryService _accountHistory = (IAccountHistoryService)App.Services.GetService(typeof(IAccountHistoryService))!;
    private readonly IAuthenticationService _authentication = (IAuthenticationService)App.Services.GetService(typeof(IAuthenticationService))!;
    private readonly ISettingsService _settings = (ISettingsService)App.Services.GetService(typeof(ISettingsService))!;
    private List<Transcription> _localItems = new();
    private readonly List<Transcription> _cloudItems = new();
    private List<Transcription> _allItems = new();
    private CancellationTokenSource? _loadCts;
    private string? _accountId;
    private int _cloudPage;
    private bool _hasMoreCloud;
    private bool _loadingCloud;
    private bool _cloudLoadFailed;

    public HistoryPage()
    {
        InitializeComponent();
        Loaded += async (_, _) => await LoadHistoryAsync();
        Unloaded += (_, _) => { _loadCts?.Cancel(); _loadCts?.Dispose(); _loadCts = null; };
    }

    private async Task LoadHistoryAsync()
    {
        _loadCts?.Cancel();
        _loadCts?.Dispose();
        _loadCts = new CancellationTokenSource();
        try
        {
            _accountId = (await _authentication.GetCurrentUserAsync())?.Id;
            _cloudItems.Clear();
            _cloudPage = 0;
            _hasMoreCloud = _accountId is not null;
            _cloudLoadFailed = false;
            await RefreshLocalAsync();
            if (_hasMoreCloud) await LoadMoreCloudAsync();
        }
        catch (Exception ex) { ShowStatus(ex.Message, InfoBarSeverity.Error); }
    }

    private async Task RefreshLocalAsync()
    {
        _localItems = await _service.GetHistoryAsync();
        MergeHistory();
    }

    private void MergeHistory()
    {
        var merged = new List<Transcription>(_localItems);
        var ids = new HashSet<string>(_localItems.Select(item => item.Id), StringComparer.Ordinal);
        foreach (var remote in _cloudItems)
        {
            if (!ids.Add(remote.Id)) continue;
            merged.Add(remote);
        }
        _allItems = merged.OrderByDescending(item => item.CreatedAt).ToList();
        ApplyFilters();
    }

    private async Task LoadMoreCloudAsync()
    {
        var requestCts = _loadCts;
        if (_loadingCloud || !_hasMoreCloud || requestCts is null) return;
        _loadingCloud = true;
        CloudLoadMoreButton.IsEnabled = false;
        CloudLoadMoreButton.Content = "Loading account history…";
        try
        {
            var owner = _accountId;
            var page = await _accountHistory.GetPageAsync(_cloudPage + 1, requestCts.Token);
            if (requestCts.IsCancellationRequested || requestCts != _loadCts ||
                owner != (await _authentication.GetCurrentUserAsync())?.Id) return;
            var refreshedLocal = false;
            foreach (var remote in page.Items)
            {
                var local = _localItems.FirstOrDefault(item => item.Id == remote.Id);
                if (local is null || remote.Revision.GetValueOrDefault() <= local.Revision.GetValueOrDefault()) continue;
                await _service.UpdateTranscriptionTextAsync(local.Id, remote.Text, remote.Revision);
                refreshedLocal = true;
            }
            if (requestCts.IsCancellationRequested || requestCts != _loadCts ||
                owner != (await _authentication.GetCurrentUserAsync())?.Id) return;
            if (refreshedLocal) _localItems = await _service.GetHistoryAsync();
            var known = new HashSet<string>(_cloudItems.Select(item => item.Id), StringComparer.Ordinal);
            _cloudItems.AddRange(page.Items.Where(item => known.Add(item.Id)));
            _cloudPage = page.Page;
            _hasMoreCloud = page.HasMore;
            if (_cloudLoadFailed) StatusBar.IsOpen = false;
            _cloudLoadFailed = false;
            MergeHistory();
        }
        catch (OperationCanceledException) { }
        catch (Exception ex)
        {
            _cloudLoadFailed = true;
            ShowStatus($"Account history could not load. Retry when connected: {ex.Message}", InfoBarSeverity.Warning);
        }
        finally
        {
            _loadingCloud = false;
            CloudLoadMoreButton.Content = _cloudLoadFailed ? "Retry account history" : "Load more from account";
            CloudLoadMoreButton.IsEnabled = _hasMoreCloud;
            CloudLoadMoreButton.Visibility = _hasMoreCloud ? Visibility.Visible : Visibility.Collapsed;
        }
    }

    private async void OnLoadMoreClick(object sender, RoutedEventArgs e) => await LoadMoreCloudAsync();

    private void ApplyFilters()
    {
        if (HistoryList is null || EmptyText is null || SearchBox is null || RangeFilter is null) return;
        IEnumerable<Transcription> filtered = _allItems;
        var query = SearchBox.Text.Trim();
        if (query.Length > 0)
            filtered = filtered.Where(item => item.Text.Contains(query, StringComparison.CurrentCultureIgnoreCase));

        var range = (RangeFilter.SelectedItem as ComboBoxItem)?.Tag?.ToString();
        var start = range switch
        {
            "today" => DateTimeOffset.Now.Date,
            "week" => DateTimeOffset.Now.AddDays(-7),
            "month" => DateTimeOffset.Now.AddMonths(-1),
            _ => DateTimeOffset.MinValue
        };
        if (range != "all" && start != DateTimeOffset.MinValue)
            filtered = filtered.Where(item => item.CreatedAt.LocalDateTime >= start.LocalDateTime);

        var result = filtered.OrderByDescending(item => item.CreatedAt).ToList();
        HistoryList.ItemsSource = result;
        var shortcut = _settings.GetSetting("Shortcut", "win-alt-space") switch
        {
            "ctrl-alt-space" => "Ctrl+Alt+Space", "ctrl-shift-space" => "Ctrl+Shift+Space", _ => "Win+Alt+Space"
        };
        EmptyText.Text = _allItems.Count == 0
            ? $"No transcriptions yet. Start dictating with {shortcut}."
            : "No transcriptions match these filters.";
        EmptyText.Visibility = result.Count == 0 ? Visibility.Visible : Visibility.Collapsed;
    }

    private void OnSearchChanged(object sender, TextChangedEventArgs e) => ApplyFilters();
    private void OnFilterChanged(object sender, SelectionChangedEventArgs e) => ApplyFilters();

    private void OnHistorySizeChanged(object sender, SizeChangedEventArgs e)
    {
        HistoryGrid.Padding = new Thickness(e.NewSize.Width < 560 ? 16 : 28);
        var narrow = e.NewSize.Width < 470;
        FilterActions.Orientation = narrow ? Orientation.Vertical : Orientation.Horizontal;
        foreach (var control in FilterActions.Children.OfType<Control>())
            control.HorizontalAlignment = narrow ? HorizontalAlignment.Stretch : HorizontalAlignment.Left;
    }

    private async void OnDeleteClick(object sender, RoutedEventArgs e)
    {
        if (sender is not Button { Tag: string id }) return;
        if (_localItems.All(item => item.Id != id || !item.CanDelete)) return;
        try
        {
            await _service.DeleteTranscriptionAsync(id);
            await RefreshLocalAsync();
            ShowStatus("Transcription deleted.", InfoBarSeverity.Success);
        }
        catch (Exception ex) { ShowStatus(ex.Message, InfoBarSeverity.Error); }
    }

    private async void OnClearHistoryClick(object sender, RoutedEventArgs e)
    {
        if (_localItems.Count == 0) { ShowStatus("Device history is already empty.", InfoBarSeverity.Informational); return; }
        var dialog = new ContentDialog
        {
            XamlRoot = XamlRoot, Title = "Clear transcription history?",
            Content = "This deletes all saved transcriptions for this VoiceLab account on this device.",
            PrimaryButtonText = "Delete all", CloseButtonText = "Cancel"
        };
        if (await dialog.ShowAsync() != ContentDialogResult.Primary) return;
        try { await _service.ClearHistoryAsync(); await RefreshLocalAsync(); ShowStatus("Device history cleared.", InfoBarSeverity.Success); }
        catch (Exception ex) { ShowStatus(ex.Message, InfoBarSeverity.Error); }
    }

    private async void OnEditClick(object sender, RoutedEventArgs e)
    {
        if (sender is not Button { Tag: string id }) return;
        var current = _allItems.FirstOrDefault(item => item.Id == id);
        if (current is null) return;
        var editor = new TextBox { Text = current.Text, AcceptsReturn = true, TextWrapping = TextWrapping.Wrap,
            Width = Math.Min(520, Math.Max(180, ActualWidth - 120)), MinHeight = 180 };
        var dialog = new ContentDialog { XamlRoot = XamlRoot, Title = "Edit transcription", Content = editor,
            PrimaryButtonText = "Save", CloseButtonText = "Cancel" };
        if (await dialog.ShowAsync() != ContentDialogResult.Primary) return;
        try
        {
            var serverVersion = current.IsRemote && current.Revision is > 0
                ? current : _cloudItems.FirstOrDefault(item => item.Id == id);
            if (serverVersion is { IsRemote: true, Revision: > 0 })
            {
                var updated = await _accountHistory.UpdateAsync(serverVersion, editor.Text);
                var cloudIndex = _cloudItems.FindIndex(item => item.Id == id);
                if (cloudIndex >= 0) _cloudItems[cloudIndex] = updated;
                if (_localItems.Any(item => item.Id == id))
                    await _service.UpdateTranscriptionTextAsync(id, updated.Text, updated.Revision);
            }
            else await _service.UpdateTranscriptionTextAsync(id, editor.Text);
            await RefreshLocalAsync();
            ShowStatus("Transcription updated.", InfoBarSeverity.Success);
        }
        catch (Exception ex) { ShowStatus(ex.Message, InfoBarSeverity.Error); }
    }

    private void OnCopyClick(object sender, RoutedEventArgs e)
    {
        if (sender is not Button { Tag: string text }) return;
        var package = new DataPackage();
        package.SetText(text);
        try { Clipboard.SetContent(package); Clipboard.Flush(); ShowStatus("Copied to clipboard.", InfoBarSeverity.Success); }
        catch (Exception ex) { ShowStatus(ex.Message, InfoBarSeverity.Error); }
    }

    private static void SetActionButtons(DependencyObject root, double opacity, bool hitTest)
    {
        var count = VisualTreeHelper.GetChildrenCount(root);
        for (var i = 0; i < count; i++)
        {
            var child = VisualTreeHelper.GetChild(root, i);
            if (child is Button button)
            {
                button.Opacity = opacity;
                button.IsHitTestVisible = hitTest;
            }
            else SetActionButtons(child, opacity, hitTest);
        }
    }

    private void OnCardPointerEntered(object sender, Microsoft.UI.Xaml.Input.PointerRoutedEventArgs e)
    {
        if (sender is DependencyObject root) SetActionButtons(root, 1, true);
    }

    private void OnCardPointerExited(object sender, Microsoft.UI.Xaml.Input.PointerRoutedEventArgs e)
    {
        if (sender is DependencyObject root) SetActionButtons(root, 0, false);
    }

    private void ShowStatus(string message, InfoBarSeverity severity)
    {
        StatusBar.Message = message;
        StatusBar.Severity = severity;
        StatusBar.IsOpen = true;
    }
}
