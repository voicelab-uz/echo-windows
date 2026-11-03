using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Input;
using VoiceLab.Infrastructure.Services;
using Windows.Storage.Pickers;

namespace VoiceLab.App.Views;

public sealed partial class VocabularyPage : Page
{
    private readonly IVocabularyService _service = (IVocabularyService)App.Services.GetService(typeof(IVocabularyService))!;
    private List<VocabularyWord> _words = [];
    private string? _editingId;

    public VocabularyPage()
    {
        InitializeComponent();
        Loaded += async (_, _) => await LoadWordsAsync();
    }

    private async Task LoadWordsAsync()
    {
        try
        {
            _words = await _service.GetWordsAsync();
            ApplySearch();
        }
        catch (Exception ex) { ShowStatus(ex.Message, InfoBarSeverity.Error); }
    }

    private void OnPageSizeChanged(object sender, SizeChangedEventArgs e) =>
        PageGrid.Padding = new Thickness(e.NewSize.Width < 600 ? 16 : 28);

    private void OnSearchChanged(object sender, TextChangedEventArgs e) => ApplySearch();

    private void ApplySearch()
    {
        if (WordsList is null || EmptyText is null) return;
        var query = SearchBox?.Text?.Trim() ?? "";
        var visible = query.Length == 0 ? _words : _words.Where(item =>
            item.Word.Contains(query, StringComparison.CurrentCultureIgnoreCase) ||
            item.Replacement.Contains(query, StringComparison.CurrentCultureIgnoreCase)).ToList();
        WordsList.ItemsSource = visible;
        EmptyText.Text = _words.Count == 0 ? "Your dictionary is empty." : "No matching words.";
        EmptyText.Visibility = visible.Count == 0 ? Visibility.Visible : Visibility.Collapsed;
    }

    private async void OnAddClick(object sender, RoutedEventArgs e)
    {
        try
        {
            await _service.SaveWordAsync(_editingId, WordBox.Text, CorrectionCheckBox.IsChecked == true ? ReplacementBox.Text : "",
                (LanguageSelector.SelectedItem as ComboBoxItem)?.Tag?.ToString() ?? "und",
                CorrectionCheckBox.IsChecked == true);
            var edited = _editingId is not null;
            ResetEditor();
            ShowStatus(edited ? "Dictionary entry updated." : "Word added to your dictionary.", InfoBarSeverity.Success);
            await LoadWordsAsync();
        }
        catch (Exception ex) { ShowStatus(ex.Message, InfoBarSeverity.Warning); }
    }

    private void OnCorrectionChanged(object sender, RoutedEventArgs e) =>
        ReplacementBox.Visibility = CorrectionCheckBox.IsChecked == true ? Visibility.Visible : Visibility.Collapsed;

    private void OnEditClick(object sender, RoutedEventArgs e)
    {
        if (sender is not Button { Tag: string id }) return;
        var entry = _words.FirstOrDefault(item => item.Id == id);
        if (entry is null) return;
        _editingId = id;
        WordBox.Text = entry.Word;
        ReplacementBox.Text = entry.Replacement;
        CorrectionCheckBox.IsChecked = entry.IsCorrection;
        LanguageSelector.SelectedItem = LanguageSelector.Items.OfType<ComboBoxItem>()
            .FirstOrDefault(item => item.Tag?.ToString() == entry.Language) ?? LanguageSelector.Items[0];
        SaveWordButton.Content = "Save entry";
        CancelEditButton.Visibility = Visibility.Visible;
        WordBox.Focus(FocusState.Programmatic);
    }

    private void OnCancelEditClick(object sender, RoutedEventArgs e) => ResetEditor();

    private void ResetEditor()
    {
        _editingId = null;
        WordBox.Text = "";
        ReplacementBox.Text = "";
        CorrectionCheckBox.IsChecked = false;
        SaveWordButton.Content = "Add word";
        CancelEditButton.Visibility = Visibility.Collapsed;
    }

    private async void OnImportClick(object sender, RoutedEventArgs e)
    {
        var input = new TextBox
        {
            PlaceholderText = "Paste words separated by commas or new lines",
            AcceptsReturn = true, TextWrapping = TextWrapping.Wrap, MinHeight = 150
        };
        var dialog = new ContentDialog
        {
            XamlRoot = XamlRoot, Title = "Import dictionary words", Content = input,
            PrimaryButtonText = "Import", CloseButtonText = "Cancel"
        };
        if (await dialog.ShowAsync() != ContentDialogResult.Primary) return;
        try
        {
            var added = await _service.ImportWordsAsync(input.Text,
                (LanguageSelector.SelectedItem as ComboBoxItem)?.Tag?.ToString() ?? "und");
            ShowStatus($"Imported {added} new words.", InfoBarSeverity.Success);
            await LoadWordsAsync();
        }
        catch (Exception ex) { ShowStatus(ex.Message, InfoBarSeverity.Warning); }
    }

    private async void OnExportClick(object sender, RoutedEventArgs e)
    {
        if (_words.Count == 0) { ShowStatus("There are no dictionary words to export.", InfoBarSeverity.Informational); return; }
        try
        {
            var picker = new FileSavePicker { SuggestedStartLocation = PickerLocationId.DocumentsLibrary,
                SuggestedFileName = "dictionary" };
            picker.FileTypeChoices.Add("Text file", [".txt"]);
            WinRT.Interop.InitializeWithWindow.Initialize(picker,
                WinRT.Interop.WindowNative.GetWindowHandle(App.MainWindow!));
            var file = await picker.PickSaveFileAsync();
            if (file is null) return;
            await Windows.Storage.FileIO.WriteTextAsync(file,
                string.Join(Environment.NewLine, _words.Select(item => item.Word)));
            ShowStatus("Dictionary exported.", InfoBarSeverity.Success);
        }
        catch (Exception ex) { ShowStatus("Could not export dictionary: " + ex.Message, InfoBarSeverity.Error); }
    }

    private void OnWordKeyDown(object sender, KeyRoutedEventArgs e)
    {
        if (e.Key == Windows.System.VirtualKey.Enter)
        {
            e.Handled = true;
            OnAddClick(sender, new RoutedEventArgs());
        }
    }

    private async void OnDeleteClick(object sender, RoutedEventArgs e)
    {
        if (sender is not Button { Tag: string id }) return;
        try
        {
            await _service.DeleteWordAsync(id);
            if (_editingId == id) ResetEditor();
            ShowStatus("Word removed.", InfoBarSeverity.Success);
            await LoadWordsAsync();
        }
        catch (Exception ex) { ShowStatus(ex.Message, InfoBarSeverity.Error); }
    }

    private void ShowStatus(string message, InfoBarSeverity severity)
    {
        StatusBar.Message = message;
        StatusBar.Severity = severity;
        StatusBar.IsOpen = true;
    }
}
