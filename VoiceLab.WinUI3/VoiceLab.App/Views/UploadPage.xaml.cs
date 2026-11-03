using Microsoft.Extensions.DependencyInjection;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using VoiceLab.Infrastructure.Services;
using Windows.ApplicationModel.DataTransfer;
using Windows.Storage.Pickers;

namespace VoiceLab.App.Views;

public sealed partial class UploadPage : Page
{
    private string? _selectedPath;
    private readonly ITranscriptionService _transcriptions = App.Services.GetRequiredService<ITranscriptionService>();
    private readonly ISettingsService _settings = App.Services.GetRequiredService<ISettingsService>();
    private readonly INotesService _notes = App.Services.GetRequiredService<INotesService>();
    private CancellationTokenSource? _uploadCancellation;

    public UploadPage()
    {
        InitializeComponent();
        Unloaded += (_, _) => _uploadCancellation?.Cancel();
    }

    private async void OnChooseClick(object sender, RoutedEventArgs e)
    {
        try
        {
            var picker = new FileOpenPicker { SuggestedStartLocation = PickerLocationId.MusicLibrary };
            foreach (var extension in new[] { ".mp3", ".wav", ".m4a", ".mp4", ".aac", ".ogg", ".webm", ".flac", ".aiff", ".amr", ".3gp", ".caf", ".wma" })
                picker.FileTypeFilter.Add(extension);
            WinRT.Interop.InitializeWithWindow.Initialize(picker, WinRT.Interop.WindowNative.GetWindowHandle(App.MainWindow!));
            var file = await picker.PickSingleFileAsync();
            if (file is null) return;
            _selectedPath = file.Path;
            SelectedFileText.Text = file.Name;
            ResultText.Text = "";
            CopyButton.IsEnabled = false;
            SaveNoteButton.IsEnabled = false;
            TranscribeButton.IsEnabled = true;
            StatusBar.IsOpen = false;
        }
        catch (Exception ex) { ShowError(ex.Message); }
    }

    private async void OnTranscribeClick(object sender, RoutedEventArgs e)
    {
        if (_selectedPath is null || _uploadCancellation is not null) return;
        var cancellation = new CancellationTokenSource();
        _uploadCancellation = cancellation;
        TranscribeButton.IsEnabled = false;
        ChooseButton.IsEnabled = false;
        CancelButton.Visibility = Visibility.Visible;
        BusyRing.IsActive = true;
        StatusBar.IsOpen = false;
        ResultText.Text = "";
        CopyButton.IsEnabled = false;
        SaveNoteButton.IsEnabled = false;
        try
        {
            var saveHistory = _settings.GetSetting("RetainHistory", true);
            ResultText.Text = await _transcriptions.TranscribeFileAsync(_selectedPath,
                _settings.GetSetting("PreferredLanguage", "auto"), saveHistory, cancellation.Token);
            CopyButton.IsEnabled = true;
            SaveNoteButton.IsEnabled = true;
            StatusBar.Severity = InfoBarSeverity.Success;
            StatusBar.Message = saveHistory ? "Transcript saved to device History."
                : "Transcript ready. Device History saving is off.";
            StatusBar.IsOpen = true;
        }
        catch (OperationCanceledException) when (cancellation.IsCancellationRequested)
        {
            StatusBar.Severity = InfoBarSeverity.Informational;
            StatusBar.Message = "File transcription cancelled.";
            StatusBar.IsOpen = true;
        }
        catch (Exception ex) { ShowError(ex.Message); }
        finally
        {
            if (ReferenceEquals(_uploadCancellation, cancellation)) _uploadCancellation = null;
            cancellation.Dispose();
            BusyRing.IsActive = false;
            CancelButton.Visibility = Visibility.Collapsed;
            CancelButton.IsEnabled = true;
            ChooseButton.IsEnabled = true;
            TranscribeButton.IsEnabled = _selectedPath is not null;
        }
    }

    private void OnCancelClick(object sender, RoutedEventArgs e)
    {
        CancelButton.IsEnabled = false;
        _uploadCancellation?.Cancel();
    }

    private void OnCopyClick(object sender, RoutedEventArgs e)
    {
        if (ResultText.Text.Length == 0) return;
        try
        {
            var package = new DataPackage(); package.SetText(ResultText.Text); Clipboard.SetContent(package); Clipboard.Flush();
            StatusBar.Severity = InfoBarSeverity.Success;
            StatusBar.Message = "Transcript copied.";
            StatusBar.IsOpen = true;
        }
        catch (Exception ex) { ShowError($"Could not copy transcript: {ex.Message}"); }
    }

    private async void OnSaveNoteClick(object sender, RoutedEventArgs e)
    {
        if (string.IsNullOrWhiteSpace(ResultText.Text)) return;
        SaveNoteButton.IsEnabled = false;
        try
        {
            var title = _selectedPath is null ? "Audio transcription" : System.IO.Path.GetFileNameWithoutExtension(_selectedPath);
            await _notes.CreateNoteAsync(title, ResultText.Text);
            try
            {
                await _notes.SyncAsync();
                StatusBar.Severity = InfoBarSeverity.Success;
                StatusBar.Message = "Saved as an account note. Open Notes to edit it.";
            }
            catch
            {
                StatusBar.Severity = InfoBarSeverity.Warning;
                StatusBar.Message = "Saved on this PC. Echo will retry account sync when you open Notes.";
            }
            StatusBar.IsOpen = true;
        }
        catch (Exception ex) { SaveNoteButton.IsEnabled = true; ShowError(ex.Message); }
    }

    private void ShowError(string message)
    {
        StatusBar.Severity = InfoBarSeverity.Error;
        StatusBar.Message = message;
        StatusBar.IsOpen = true;
    }
}
