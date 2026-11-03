using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Windows.ApplicationModel.DataTransfer;
using VoiceLab.Infrastructure.Services;

namespace VoiceLab.App.Views;

public sealed partial class SnippetsPage : Page
{
    private readonly ISnippetsService _service = (ISnippetsService)App.Services.GetService(typeof(ISnippetsService))!;
    private List<Snippet> _snippets = new();

    public SnippetsPage()
    {
        InitializeComponent();
        Loaded += async (_, _) => await LoadSnippetsAsync();
    }

    private async Task LoadSnippetsAsync()
    {
        try { _snippets = await _service.GetSnippetsAsync(); SnippetsList.ItemsSource = _snippets; EmptyText.Visibility = _snippets.Count == 0 ? Visibility.Visible : Visibility.Collapsed; }
        catch (Exception ex) { ShowStatus(ex.Message, InfoBarSeverity.Error); }
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

    private void OnCopyClick(object sender, RoutedEventArgs e)
    {
        if (sender is not Button { Tag: string text }) return;
        var package = new DataPackage();
        package.SetText(text);
        try { Clipboard.SetContent(package); Clipboard.Flush(); ShowStatus("Copied to clipboard.", InfoBarSeverity.Success); }
        catch (Exception ex) { ShowStatus(ex.Message, InfoBarSeverity.Error); }
    }

    private void ShowStatus(string message, InfoBarSeverity severity)
    {
        StatusBar.Message = message;
        StatusBar.Severity = severity;
        StatusBar.IsOpen = true;
    }
}
