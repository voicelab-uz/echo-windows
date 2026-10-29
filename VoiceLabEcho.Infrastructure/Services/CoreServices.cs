using VoiceLabEcho.Core.Interfaces;
using VoiceLabEcho.Core.Models;
using VoiceLabEcho.Infrastructure.Api;

namespace VoiceLabEcho.Infrastructure.Services;

public class TranscriptionService : ITranscriptionService
{
    private readonly VoiceLabApiClient _apiClient;

    public TranscriptionService(VoiceLabApiClient apiClient)
    {
        _apiClient = apiClient;
    }

    public async Task<Transcription> TranscribeAsync(string audioFilePath, string language = "auto")
    {
        var response = await _apiClient.TranscribeAsync(audioFilePath, language);

        return new Transcription
        {
            Id = response.Id,
            Text = response.Text,
            DetectedLanguage = response.Language,
            WordCount = response.WordCount,
            CreatedAt = response.CreatedAt
        };
    }

    public async Task<Transcription?> GetTranscriptionAsync(string transcriptionId)
    {
        try
        {
            var response = await _apiClient.UpdateTranscriptionAsync(transcriptionId, string.Empty);
            return new Transcription
            {
                Id = response.Id,
                Text = response.Text,
                DetectedLanguage = response.Language,
                WordCount = response.WordCount,
                CreatedAt = response.CreatedAt
            };
        }
        catch
        {
            return null;
        }
    }

    public async Task<Transcription> UpdateTranscriptionAsync(string transcriptionId, string newText)
    {
        var response = await _apiClient.UpdateTranscriptionAsync(transcriptionId, newText);

        return new Transcription
        {
            Id = response.Id,
            Text = response.Text,
            DetectedLanguage = response.Language,
            WordCount = response.WordCount,
            CreatedAt = response.CreatedAt,
            IsEdited = true,
            EditedAt = DateTime.UtcNow
        };
    }
}

public class HistoryService : IHistoryService
{
    private readonly VoiceLabApiClient _apiClient;
    private readonly IStorageService _storageService;

    public HistoryService(VoiceLabApiClient apiClient, IStorageService storageService)
    {
        _apiClient = apiClient;
        _storageService = storageService;
    }

    public async Task<List<Transcription>> GetHistoryAsync(int page = 1, int pageSize = 20)
    {
        try
        {
            var response = await _apiClient.GetHistoryAsync(page, pageSize);
            return response.Transcriptions.Select(t => new Transcription
            {
                Id = t.Id,
                Text = t.Text,
                DetectedLanguage = t.Language,
                WordCount = t.WordCount,
                CreatedAt = t.CreatedAt
            }).ToList();
        }
        catch
        {
            // Return cached history if API fails
            return await _storageService.LoadAsync<List<Transcription>>("history") ?? new List<Transcription>();
        }
    }

    public async Task<List<Transcription>> SearchHistoryAsync(string query)
    {
        var history = await GetHistoryAsync();
        return history.Where(t => t.Text.Contains(query, StringComparison.OrdinalIgnoreCase)).ToList();
    }

    public async Task<bool> DeleteTranscriptionAsync(string transcriptionId)
    {
        // TODO: Implement API call when available
        return await Task.FromResult(true);
    }

    public async Task<bool> ClearHistoryAsync()
    {
        // TODO: Implement API call when available
        await _storageService.DeleteAsync("history");
        return true;
    }
}

public class NotesService : INotesService
{
    private readonly VoiceLabApiClient _apiClient;
    private readonly IStorageService _storageService;
    private List<Note> _localNotes = new();

    public NotesService(VoiceLabApiClient apiClient, IStorageService storageService)
    {
        _apiClient = apiClient;
        _storageService = storageService;
    }

    public async Task<List<Note>> GetNotesAsync()
    {
        _localNotes = await _storageService.LoadAsync<List<Note>>("notes") ?? new List<Note>();
        return _localNotes;
    }

    public Task<Note?> GetNoteAsync(string noteId)
    {
        var note = _localNotes.FirstOrDefault(n => n.Id == noteId);
        return Task.FromResult(note);
    }

    public async Task<Note> CreateNoteAsync(Note note)
    {
        _localNotes.Add(note);
        await SaveNotesAsync();
        return note;
    }

    public async Task<Note> UpdateNoteAsync(Note note)
    {
        var index = _localNotes.FindIndex(n => n.Id == note.Id);
        if (index >= 0)
        {
            note.UpdatedAt = DateTime.UtcNow;
            _localNotes[index] = note;
            await SaveNotesAsync();
        }
        return note;
    }

    public async Task<bool> DeleteNoteAsync(string noteId)
    {
        var note = _localNotes.FirstOrDefault(n => n.Id == noteId);
        if (note != null)
        {
            note.IsDeleted = true;
            await SaveNotesAsync();
            return true;
        }
        return false;
    }

    public async Task SyncNotesAsync()
    {
        try
        {
            var remoteNotes = await _apiClient.GetNotesAsync();

            foreach (var remoteNote in remoteNotes)
            {
                var localNote = _localNotes.FirstOrDefault(n => n.Id == remoteNote.Id);
                if (localNote == null)
                {
                    _localNotes.Add(new Note
                    {
                        Id = remoteNote.Id,
                        Title = remoteNote.Title,
                        Content = remoteNote.Content,
                        IsPinned = remoteNote.IsPinned,
                        CreatedAt = remoteNote.CreatedAt,
                        UpdatedAt = remoteNote.UpdatedAt,
                        ServerVersion = remoteNote.Version,
                        SyncStatus = SyncStatus.Synced
                    });
                }
            }

            // Upload local changes
            foreach (var localNote in _localNotes.Where(n => n.SyncStatus == SyncStatus.NotSynced))
            {
                try
                {
                    await _apiClient.SaveNoteAsync(localNote.Id, localNote);
                    localNote.SyncStatus = SyncStatus.Synced;
                }
                catch
                {
                    localNote.SyncStatus = SyncStatus.Error;
                }
            }

            await SaveNotesAsync();
        }
        catch
        {
            // Sync failed, continue with local notes
        }
    }

    private async Task SaveNotesAsync()
    {
        await _storageService.SaveAsync("notes", _localNotes);
    }
}

public class VocabularyService : IVocabularyService
{
    private readonly IStorageService _storageService;
    private VocabularyData _vocabulary = new();

    public VocabularyService(IStorageService storageService)
    {
        _storageService = storageService;
    }

    public async Task<VocabularyData> GetVocabularyAsync()
    {
        _vocabulary = await _storageService.LoadAsync<VocabularyData>("vocabulary") ?? new VocabularyData();
        return _vocabulary;
    }

    public async Task<VocabularyWord> AddWordAsync(string word, string language)
    {
        var vocabWord = new VocabularyWord
        {
            Word = word.Trim(),
            Language = language
        };

        _vocabulary.Words.Add(vocabWord);
        await SaveVocabularyAsync();
        return vocabWord;
    }

    public async Task<bool> DeleteWordAsync(string wordId)
    {
        var word = _vocabulary.Words.FirstOrDefault(w => w.Id == wordId);
        if (word != null)
        {
            _vocabulary.Words.Remove(word);
            await SaveVocabularyAsync();
            return true;
        }
        return false;
    }

    public async Task<Snippet> AddSnippetAsync(string trigger, string expansion)
    {
        var snippet = new Snippet
        {
            Trigger = trigger.Trim(),
            Expansion = expansion
        };

        _vocabulary.Snippets.Add(snippet);
        await SaveVocabularyAsync();
        return snippet;
    }

    public async Task<bool> DeleteSnippetAsync(string snippetId)
    {
        var snippet = _vocabulary.Snippets.FirstOrDefault(s => s.Id == snippetId);
        if (snippet != null)
        {
            _vocabulary.Snippets.Remove(snippet);
            await SaveVocabularyAsync();
            return true;
        }
        return false;
    }

    public async Task<bool> ImportWordsAsync(string[] words, string language)
    {
        foreach (var word in words.Where(w => !string.IsNullOrWhiteSpace(w)))
        {
            await AddWordAsync(word, language);
        }
        return true;
    }

    public async Task<string> ExportWordsAsync()
    {
        return string.Join(Environment.NewLine, _vocabulary.Words.Select(w => w.Word));
    }

    public string ExpandSnippets(string text)
    {
        var result = text;

        // Sort by trigger length descending to match longest first
        var snippets = _vocabulary.Snippets.OrderByDescending(s => s.Trigger.Length);

        foreach (var snippet in snippets)
        {
            result = result.Replace(snippet.Trigger, snippet.Expansion);
        }

        return result;
    }

    private async Task SaveVocabularyAsync()
    {
        await _storageService.SaveAsync("vocabulary", _vocabulary);
    }
}

public class StatisticsService : IStatisticsService
{
    private readonly VoiceLabApiClient _apiClient;

    public StatisticsService(VoiceLabApiClient apiClient)
    {
        _apiClient = apiClient;
    }

    public async Task<Statistics> GetStatisticsAsync()
    {
        // TODO: Implement when statistics API is available
        return await Task.FromResult(new Statistics());
    }

    public async Task<UsageInfo> GetUsageInfoAsync()
    {
        try
        {
            var response = await _apiClient.GetUsageAsync();
            return new UsageInfo
            {
                RemainingMinutes = response.RemainingSeconds / 60,
                TotalMinutes = response.TotalSeconds / 60
            };
        }
        catch
        {
            return new UsageInfo { RemainingMinutes = 0, TotalMinutes = 0 };
        }
    }

    public async Task RefreshUsageAsync()
    {
        await GetUsageInfoAsync();
    }
}
