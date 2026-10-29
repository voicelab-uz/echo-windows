using CommunityToolkit.Mvvm.ComponentModel;
using CommunityToolkit.Mvvm.Input;
using VoiceLabEcho.Core.Interfaces;
using VoiceLabEcho.Core.Models;

namespace VoiceLabEcho.App.ViewModels;

public partial class MainViewModel : ObservableObject
{
    private readonly IAuthenticationService _authService;
    private readonly IStatisticsService _statisticsService;
    private readonly IKeyboardShortcutService _shortcutService;

    [ObservableProperty]
    private string _userName = "Loading...";

    [ObservableProperty]
    private string _remainingMinutes = "-- minutes remaining";

    [ObservableProperty]
    private double _usageProgress;

    [ObservableProperty]
    private bool _isAuthenticated;

    public MainViewModel(
        IAuthenticationService authService,
        IStatisticsService statisticsService,
        IKeyboardShortcutService shortcutService)
    {
        _authService = authService;
        _statisticsService = statisticsService;
        _shortcutService = shortcutService;
    }

    public async Task InitializeAsync()
    {
        IsAuthenticated = await _authService.IsAuthenticatedAsync();

        if (IsAuthenticated)
        {
            await LoadUserInfoAsync();
            await RegisterShortcutAsync();
        }
    }

    private async Task LoadUserInfoAsync()
    {
        try
        {
            var usage = await _statisticsService.GetUsageInfoAsync();
            RemainingMinutes = $"{usage.RemainingMinutes} minutes remaining";
            UsageProgress = 100 - usage.UsagePercentage;

            var authState = await _authService.GetAuthenticationStateAsync();
            UserName = authState.User?.Email ?? "User";
        }
        catch
        {
            UserName = "Error loading profile";
        }
    }

    private async Task RegisterShortcutAsync()
    {
        var shortcut = new KeyboardShortcut
        {
            Key = "Space",
            Ctrl = true,
            Alt = true,
            Shift = false
        };

        await _shortcutService.RegisterShortcutAsync(shortcut, () =>
        {
            StartRecordingCommand.Execute(null);
        });
    }

    [RelayCommand]
    private void StartRecording()
    {
        // TODO: Show recording overlay
    }
}

public partial class HistoryViewModel : ObservableObject
{
    private readonly IHistoryService _historyService;

    [ObservableProperty]
    private List<Transcription> _transcriptions = new();

    [ObservableProperty]
    private string _searchQuery = string.Empty;

    [ObservableProperty]
    private bool _isLoading;

    public HistoryViewModel(IHistoryService historyService)
    {
        _historyService = historyService;
    }

    public async Task LoadHistoryAsync()
    {
        IsLoading = true;
        try
        {
            Transcriptions = await _historyService.GetHistoryAsync();
        }
        finally
        {
            IsLoading = false;
        }
    }

    [RelayCommand]
    private async Task SearchAsync()
    {
        if (string.IsNullOrWhiteSpace(SearchQuery))
        {
            await LoadHistoryAsync();
        }
        else
        {
            IsLoading = true;
            try
            {
                Transcriptions = await _historyService.SearchHistoryAsync(SearchQuery);
            }
            finally
            {
                IsLoading = false;
            }
        }
    }

    [RelayCommand]
    private void CopyText(string text)
    {
        System.Windows.Clipboard.SetText(text);
    }

    [RelayCommand]
    private async Task DeleteTranscription(string transcriptionId)
    {
        await _historyService.DeleteTranscriptionAsync(transcriptionId);
        await LoadHistoryAsync();
    }
}

public partial class RecordingViewModel : ObservableObject
{
    private readonly IAudioRecordingService _audioService;
    private readonly ITranscriptionService _transcriptionService;

    [ObservableProperty]
    private bool _isRecording;

    [ObservableProperty]
    private TimeSpan _duration;

    [ObservableProperty]
    private double _audioLevel;

    [ObservableProperty]
    private string _statusText = "Ready";

    public RecordingViewModel(
        IAudioRecordingService audioService,
        ITranscriptionService transcriptionService)
    {
        _audioService = audioService;
        _transcriptionService = transcriptionService;

        _audioService.AudioLevelChanged += OnAudioLevelChanged;
        _audioService.RecordingDurationChanged += OnDurationChanged;
    }

    [RelayCommand]
    private async Task StartRecordingAsync()
    {
        var devices = await _audioService.GetAvailableDevicesAsync();
        var defaultDevice = devices.FirstOrDefault(d => d.IsDefault);

        if (defaultDevice != null)
        {
            var tempPath = Path.Combine(Path.GetTempPath(), $"recording_{Guid.NewGuid()}.wav");
            IsRecording = await _audioService.StartRecordingAsync(defaultDevice.Id, tempPath);
            StatusText = "Recording...";
        }
    }

    [RelayCommand]
    private async Task StopRecordingAsync()
    {
        StatusText = "Transcribing...";
        var recording = await _audioService.StopRecordingAsync();
        IsRecording = false;

        try
        {
            var transcription = await _transcriptionService.TranscribeAsync(recording.FilePath);
            StatusText = "Complete";
            // TODO: Insert or display transcription
        }
        catch
        {
            StatusText = "Error";
        }
    }

    [RelayCommand]
    private async Task CancelRecordingAsync()
    {
        await _audioService.CancelRecordingAsync();
        IsRecording = false;
        StatusText = "Cancelled";
    }

    private void OnAudioLevelChanged(object? sender, AudioLevel level)
    {
        AudioLevel = level.Level * 100;
    }

    private void OnDurationChanged(object? sender, TimeSpan duration)
    {
        Duration = duration;
    }
}

public partial class VocabularyViewModel : ObservableObject
{
    private readonly IVocabularyService _vocabularyService;

    [ObservableProperty]
    private List<VocabularyWord> _words = new();

    [ObservableProperty]
    private List<Snippet> _snippets = new();

    [ObservableProperty]
    private string _newWord = string.Empty;

    [ObservableProperty]
    private string _newSnippetTrigger = string.Empty;

    [ObservableProperty]
    private string _newSnippetExpansion = string.Empty;

    public VocabularyViewModel(IVocabularyService vocabularyService)
    {
        _vocabularyService = vocabularyService;
    }

    public async Task LoadVocabularyAsync()
    {
        var data = await _vocabularyService.GetVocabularyAsync();
        Words = data.Words;
        Snippets = data.Snippets;
    }

    [RelayCommand]
    private async Task AddWordAsync()
    {
        if (!string.IsNullOrWhiteSpace(NewWord))
        {
            await _vocabularyService.AddWordAsync(NewWord, "all");
            NewWord = string.Empty;
            await LoadVocabularyAsync();
        }
    }

    [RelayCommand]
    private async Task DeleteWordAsync(string wordId)
    {
        await _vocabularyService.DeleteWordAsync(wordId);
        await LoadVocabularyAsync();
    }

    [RelayCommand]
    private async Task AddSnippetAsync()
    {
        if (!string.IsNullOrWhiteSpace(NewSnippetTrigger) && !string.IsNullOrWhiteSpace(NewSnippetExpansion))
        {
            await _vocabularyService.AddSnippetAsync(NewSnippetTrigger, NewSnippetExpansion);
            NewSnippetTrigger = string.Empty;
            NewSnippetExpansion = string.Empty;
            await LoadVocabularyAsync();
        }
    }

    [RelayCommand]
    private async Task DeleteSnippetAsync(string snippetId)
    {
        await _vocabularyService.DeleteSnippetAsync(snippetId);
        await LoadVocabularyAsync();
    }
}

public partial class NotesViewModel : ObservableObject
{
    private readonly INotesService _notesService;

    [ObservableProperty]
    private List<Note> _notes = new();

    [ObservableProperty]
    private Note? _selectedNote;

    public NotesViewModel(INotesService notesService)
    {
        _notesService = notesService;
    }

    public async Task LoadNotesAsync()
    {
        Notes = await _notesService.GetNotesAsync();
    }

    [RelayCommand]
    private async Task CreateNoteAsync()
    {
        var note = new Note { Title = "New Note" };
        await _notesService.CreateNoteAsync(note);
        await LoadNotesAsync();
        SelectedNote = note;
    }

    [RelayCommand]
    private async Task SaveNoteAsync()
    {
        if (SelectedNote != null)
        {
            await _notesService.UpdateNoteAsync(SelectedNote);
        }
    }

    [RelayCommand]
    private async Task DeleteNoteAsync(string noteId)
    {
        await _notesService.DeleteNoteAsync(noteId);
        await LoadNotesAsync();
    }
}

public partial class StatisticsViewModel : ObservableObject
{
    private readonly IStatisticsService _statisticsService;

    [ObservableProperty]
    private Statistics _statistics = new();

    public StatisticsViewModel(IStatisticsService statisticsService)
    {
        _statisticsService = statisticsService;
    }

    public async Task LoadStatisticsAsync()
    {
        Statistics = await _statisticsService.GetStatisticsAsync();
    }
}

public partial class SettingsViewModel : ObservableObject
{
    [ObservableProperty]
    private string _selectedTheme = "Light";

    [ObservableProperty]
    private bool _launchAtStartup;

    [RelayCommand]
    private void SaveSettings()
    {
        // TODO: Implement settings save
    }
}

public partial class OnboardingViewModel : ObservableObject
{
    [ObservableProperty]
    private int _currentStep;

    [ObservableProperty]
    private bool _isComplete;

    [RelayCommand]
    private void NextStep()
    {
        CurrentStep++;
    }

    [RelayCommand]
    private void PreviousStep()
    {
        if (CurrentStep > 0)
            CurrentStep--;
    }
}

public partial class GettingStartedViewModel : ObservableObject
{
    [ObservableProperty]
    private bool _hasMicrophoneAccess;

    [ObservableProperty]
    private bool _hasShortcutConfigured;
}
