using VoiceLabEcho.Core.Models;

namespace VoiceLabEcho.Core.Interfaces;

public interface ITranscriptionService
{
    Task<Transcription> TranscribeAsync(string audioFilePath, string language = "auto");
    Task<Transcription?> GetTranscriptionAsync(string transcriptionId);
    Task<Transcription> UpdateTranscriptionAsync(string transcriptionId, string newText);
}

public interface IHistoryService
{
    Task<List<Transcription>> GetHistoryAsync(int page = 1, int pageSize = 20);
    Task<List<Transcription>> SearchHistoryAsync(string query);
    Task<bool> DeleteTranscriptionAsync(string transcriptionId);
    Task<bool> ClearHistoryAsync();
}

public interface INotesService
{
    Task<List<Note>> GetNotesAsync();
    Task<Note?> GetNoteAsync(string noteId);
    Task<Note> CreateNoteAsync(Note note);
    Task<Note> UpdateNoteAsync(Note note);
    Task<bool> DeleteNoteAsync(string noteId);
    Task SyncNotesAsync();
}

public interface IVocabularyService
{
    Task<VocabularyData> GetVocabularyAsync();
    Task<VocabularyWord> AddWordAsync(string word, string language);
    Task<bool> DeleteWordAsync(string wordId);
    Task<Snippet> AddSnippetAsync(string trigger, string expansion);
    Task<bool> DeleteSnippetAsync(string snippetId);
    Task<bool> ImportWordsAsync(string[] words, string language);
    Task<string> ExportWordsAsync();
    string ExpandSnippets(string text);
}

public interface IStatisticsService
{
    Task<Statistics> GetStatisticsAsync();
    Task<UsageInfo> GetUsageInfoAsync();
    Task RefreshUsageAsync();
}

public interface IStorageService
{
    Task<T?> LoadAsync<T>(string key) where T : class;
    Task SaveAsync<T>(string key, T data) where T : class;
    Task<bool> DeleteAsync(string key);
    Task<bool> ExistsAsync(string key);
}

public interface IKeyboardShortcutService
{
    Task<bool> RegisterShortcutAsync(KeyboardShortcut shortcut, Action callback);
    Task<bool> UnregisterShortcutAsync();
    KeyboardShortcut? CurrentShortcut { get; }
}
