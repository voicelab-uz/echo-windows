using Microsoft.Extensions.DependencyInjection;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using VoiceLab.Infrastructure.Services;

namespace VoiceLab.App.Views;

public sealed partial class SnippetsPage : Page
{
    private readonly ISnippetsService _service = App.Services.GetRequiredService<ISnippetsService>();
    private List<Snippet> _snippets = new();

    public SnippetsPage()
    {
        InitializeComponent();
        Loaded += async (_, _) => await LoadSnippetsAsync();
    }

    private async Task LoadSnippetsAsync()
    {
        try { _snippets = await _service.GetSnippetsAsync(); ApplySearch(); }
        catch (Exception ex) { ShowStatus(ex.Message, InfoBarSeverity.Error); }
    }

    private void OnPageSizeChanged(object sender, SizeChangedEventArgs e)
    {
        var compact = e.NewSize.Width < 600;
        PageGrid.Padding = new Thickness(compact ? 12 : 20);
        SnippetEntryGrid.ColumnDefinitions[1].Width = compact ? new GridLength(0) : new GridLength(2, GridUnitType.Star);
        Grid.SetColumn(TextBox, compact ? 0 : 1);
        Grid.SetRow(TextBox, compact ? 1 : 0);
        Grid.SetColumnSpan(SaveSnippetButton, compact ? 1 : 2);
    }

    private void OnSearchChanged(object sender, TextChangedEventArgs e) => ApplySearch();

    private void ApplySearch()
    {
        if (SnippetsList is null || EmptyState is null) return;
        var query = SearchBox.Text.Trim();
        var visible = _snippets.Where(item => item.Name.Contains(query, StringComparison.CurrentCultureIgnoreCase)
            || item.Text.Contains(query, StringComparison.CurrentCultureIgnoreCase)).ToList();
        SnippetsList.ItemsSource = visible;
        SnippetCountText.Text = $"{visible.Count} {(visible.Count == 1 ? "snippet" : "snippets")}";
        EmptyText.Text = query.Length > 0 ? "No matching snippets" : "Save time with your first snippet";
        EmptyState.Visibility = visible.Count == 0 ? Visibility.Visible : Visibility.Collapsed;
    }

    private async void OnAddClick(object sender, RoutedEventArgs e)
    {
        try
        {
            await _service.CreateSnippetAsync(NameBox.Text, TextBox.Text);
            NameBox.Text = string.Empty;
            TextBox.Text = string.Empty;
            ShowStatus("Snippet saved.", InfoBarSeverity.Success);
            await LoadSnippetsAsync();
        }
        catch (Exception ex) { ShowStatus(ex.Message, InfoBarSeverity.Warning); }
    }

    private async void OnDeleteClick(object sender, RoutedEventArgs e)
    {
        if (sender is not Button { Tag: string id }) return;
        try
        {
            await _service.DeleteSnippetAsync(id);
            ShowStatus("Snippet deleted.", InfoBarSeverity.Success);
            await LoadSnippetsAsync();
        }
        catch (Exception ex) { ShowStatus(ex.Message, InfoBarSeverity.Error); }
    }

    private async void OnEditClick(object sender, RoutedEventArgs e)
    {
        if (sender is not Button { Tag: string id }) return;
        var snippet = _snippets.FirstOrDefault(item => item.Id == id);
        if (snippet is null) return;
        var trigger = new TextBox { Header = "Spoken trigger", Text = snippet.Name, MaxLength = 100 };
        var replacement = new TextBox { Header = "Replacement text", Text = snippet.Text,
            AcceptsReturn = true, TextWrapping = TextWrapping.Wrap, MinHeight = 130, MaxLength = 10_000 };
        var form = new StackPanel { Spacing = 14, Children = { trigger, replacement } };
        var dialog = new ContentDialog { XamlRoot = XamlRoot, Title = "Edit snippet", Content = form,
            PrimaryButtonText = "Save", CloseButtonText = "Cancel" };
        if (await dialog.ShowAsync() != ContentDialogResult.Primary) return;
        try
        {
            await _service.UpdateSnippetAsync(id, trigger.Text, replacement.Text);
            await LoadSnippetsAsync();
            ShowStatus("Snippet updated.", InfoBarSeverity.Success);
        }
        catch (Exception ex) { ShowStatus(ex.Message, InfoBarSeverity.Warning); }
    }

    private async void OnCopyClick(object sender, RoutedEventArgs e)
    {
        if (sender is not Button { Tag: string text } button) return;
        try { await VoiceLab.App.Services.ClipboardFeedback.CopyAsync(button, text); }
        catch (Exception ex) { ShowStatus(ex.Message, InfoBarSeverity.Error); }
    }

    private void ShowStatus(string message, InfoBarSeverity severity)
    {
        StatusBar.Message = message;
        StatusBar.Severity = severity;
        StatusBar.IsOpen = true;
    }
}
