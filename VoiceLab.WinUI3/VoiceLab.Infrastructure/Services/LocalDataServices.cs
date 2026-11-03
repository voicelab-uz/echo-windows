using System.Text.Json;
using VoiceLab.Infrastructure.Storage;

using System.Text;

namespace VoiceLab.Infrastructure.Services;

public interface ITranscriptionService
{
    Task<string> TranscribeAudioAsync(byte[] audioData, string language = "auto", DesktopUsageContext? usage = null,
        bool saveHistory = true);
    Task<Transcription> TranscribeAudioRecordAsync(byte[] audioData, string language = "auto", bool saveHistory = true,
        CancellationToken cancellationToken = default);
    Task<string> TranscribeFileAsync(string filePath, string language = "auto", bool saveHistory = true,
        CancellationToken cancellationToken = default);
    Task<Transcription> SaveTranscriptionAsync(string text, string language = "auto", int audioDurationMs = 0, DesktopUsageContext? usage = null, string? remoteId = null, int? revision = null);
    Task<List<Transcription>> GetHistoryAsync();
    Task DeleteTranscriptionAsync(string id);
    Task ClearHistoryAsync();
    Task UpdateTranscriptionTextAsync(string id, string text, int? revision = null);
    Task AttachUsageContextAsync(string id, DesktopUsageContext usage, string? expectedOwnerId = null);
    Task MarkUsageSyncedAsync(string id);
}

public interface INotesService
{
    Task<List<Note>> GetNotesAsync();
    Task<int> SyncAsync(CancellationToken cancellationToken = default);
    Task<Note> CreateNoteAsync(string title, string content, string? folderId = null, bool isPinned = false);
    Task UpdateNoteAsync(Note note);
    Task DeleteNoteAsync(string id);
    Task<List<NoteFolder>> GetFoldersAsync();
    Task<NoteFolder> CreateFolderAsync(string name);
    Task RenameFolderAsync(string id, string name);
    Task DeleteFolderAsync(string id);
}

public interface IVocabularyService
{
    Task<List<VocabularyWord>> GetWordsAsync();
    Task AddWordAsync(string word);
    Task<VocabularyWord> SaveWordAsync(string? id, string word, string replacement = "",
        string language = "und", bool isCorrection = false);
    Task<int> ImportWordsAsync(string text, string language = "und");
    Task DeleteWordAsync(string id);
}

public interface ISnippetsService
{
    Task<List<Snippet>> GetSnippetsAsync();
    Task<Snippet> CreateSnippetAsync(string name, string text);
    Task UpdateSnippetAsync(string id, string name, string text);
    Task DeleteSnippetAsync(string id);
}

public interface IStatisticsService
{
    Task<UsageStats> GetStatsAsync();
}

public interface ISettingsService
{
    T GetSetting<T>(string key, T defaultValue);
    void SaveSetting<T>(string key, T value);
}

public sealed class TranscriptionService : ITranscriptionService
{
    private static readonly System.Text.RegularExpressions.Regex WordCountPattern = new(
        @"[\p{L}\p{N}]+(?:['’‘ʻʼ][\p{L}\p{N}]+)*",
        System.Text.RegularExpressions.RegexOptions.Compiled |
        System.Text.RegularExpressions.RegexOptions.CultureInvariant);
    private readonly JsonDataStore _store;
    private readonly SemaphoreSlim _gate = new(1, 1);
    private readonly HttpClient _httpClient;
    private readonly IAuthenticationService _authService;
    private readonly ISettingsService _settings;
    private readonly IVocabularyService _vocabulary;
    private readonly ISnippetsService _snippets;

    public TranscriptionService(JsonDataStore store, IAuthenticationService authService, ISettingsService settings, IVocabularyService vocabulary, ISnippetsService snippets, HttpClient httpClient)
    {
        _store = store;
        _authService = authService;
        _httpClient = httpClient;
        _settings = settings;
        _vocabulary = vocabulary;
        _snippets = snippets;
    }

    public async Task<string> TranscribeAudioAsync(byte[] audioData, string language = "auto", DesktopUsageContext? usage = null,
        bool saveHistory = true)
    {
        if (audioData is null || audioData.Length == 0) throw new ArgumentException("No microphone audio was captured.", nameof(audioData));
        var durationMs = (int)Math.Min(int.MaxValue, audioData.Length * 1000L / (16000L * 2));
        var record = await TranscribeEncodedAudioAsync(BuildPcmWave(audioData), "audio/wav", "audio.wav", language, durationMs,
            usage, saveHistory).ConfigureAwait(false);
        return record.Text;
    }

    public async Task<Transcription> TranscribeAudioRecordAsync(byte[] audioData, string language = "auto", bool saveHistory = true,
        CancellationToken cancellationToken = default)
    {
        if (audioData is null || audioData.Length == 0) throw new ArgumentException("No microphone audio was captured.", nameof(audioData));
        var durationMs = (int)Math.Min(int.MaxValue, audioData.Length * 1000L / (16000L * 2));
        return await TranscribeEncodedAudioAsync(BuildPcmWave(audioData), "audio/wav", "audio.wav", language, durationMs,
            saveHistory: saveHistory, cancellationToken: cancellationToken).ConfigureAwait(false);
    }

    public async Task<string> TranscribeFileAsync(string filePath, string language = "auto", bool saveHistory = true,
        CancellationToken cancellationToken = default)
    {
        if (!File.Exists(filePath)) throw new FileNotFoundException("The selected audio file was not found.", filePath);
        var info = new FileInfo(filePath);
        if (info.Length is <= 0 or > 500L * 1024 * 1024) throw new InvalidOperationException("Choose an audio file smaller than 500 MB.");
        var mime = Path.GetExtension(filePath).ToLowerInvariant() switch
        {
            ".mp3" => "audio/mpeg", ".wav" => "audio/wav", ".m4a" or ".mp4" => "audio/mp4",
            ".aac" => "audio/aac", ".ogg" => "audio/ogg", ".webm" => "audio/webm",
            ".flac" => "audio/flac", ".aiff" => "audio/aiff", ".amr" => "audio/amr",
            ".3gp" => "audio/3gpp", ".caf" => "audio/caf", ".wma" => "audio/x-ms-wma",
            _ => throw new InvalidOperationException("This audio file format is not supported by VoiceLab.")
        };
        var record = await TranscribeMultipartAsync(
            () => new StreamContent(new FileStream(filePath, FileMode.Open, FileAccess.Read, FileShare.Read,
                64 * 1024, useAsync: true)), mime, Path.GetFileName(filePath), language, 0,
            saveHistory: saveHistory, cancellationToken: cancellationToken).ConfigureAwait(false);
        return record.Text;
    }

    private Task<Transcription> TranscribeEncodedAudioAsync(byte[] encodedAudio, string mime, string filename,
        string language, int durationMs, DesktopUsageContext? usage = null, bool saveHistory = true,
        CancellationToken cancellationToken = default) =>
        TranscribeMultipartAsync(() => new ByteArrayContent(encodedAudio), mime, filename, language, durationMs, usage,
            saveHistory, cancellationToken);

    private async Task<Transcription> TranscribeMultipartAsync(Func<HttpContent> audioFactory, string mime,
        string filename, string language, int durationMs, DesktopUsageContext? usage = null, bool saveHistory = true,
        CancellationToken cancellationToken = default)
    {
        if (!new[] { "auto", "uz", "en", "ru" }.Contains(language, StringComparer.OrdinalIgnoreCase))
            throw new ArgumentException("Choose Uzbek, English, Russian, or automatic language detection.", nameof(language));

        var owner = (await _authService.GetCurrentUserAsync().ConfigureAwait(false))?.Id;
        if (string.IsNullOrWhiteSpace(owner)) throw new InvalidOperationException("Sign in to VoiceLab before dictating.");
        var accountScope = _store.CurrentAccountScope;
        var token = await _authService.GetAccessTokenAsync().ConfigureAwait(false);
        if (string.IsNullOrWhiteSpace(token)) throw new InvalidOperationException("Sign in to VoiceLab before dictating.");

        var authRetries = 0;
        var busyRetries = 0;
        var busyDeadline = DateTimeOffset.UtcNow.AddSeconds(10);
        while (true)
        {
            cancellationToken.ThrowIfCancellationRequested();
            using var form = new MultipartFormDataContent();
            var audio = audioFactory();
            audio.Headers.ContentType = new System.Net.Http.Headers.MediaTypeHeaderValue(mime);
            form.Add(audio, "audio", filename);
            // Mac Echo always lets the desktop STT endpoint detect speech independently of UI preferences.
            form.Add(new StringContent("auto"), "language");

            using var request = new HttpRequestMessage(HttpMethod.Post, "https://api.voicelab.uz/v1/desktop/stt") { Content = form };
            request.Headers.Authorization = new System.Net.Http.Headers.AuthenticationHeaderValue("Bearer", token);
            request.Headers.Accept.ParseAdd("application/json");
            using var response = await _httpClient.SendAsync(request, cancellationToken).ConfigureAwait(false);
            var payload = await response.Content.ReadAsStringAsync(cancellationToken).ConfigureAwait(false);

            var errorCode = ReadErrorCode(payload);
            if ((int)response.StatusCode == 401 && authRetries == 0 && errorCode == "invalid_desktop_token"
                && await _authService.RefreshTokenAsync().ConfigureAwait(false))
            {
                token = await _authService.GetAccessTokenAsync().ConfigureAwait(false) ?? "";
                if (token.Length == 0) throw new InvalidOperationException("Your VoiceLab session expired. Sign in again.");
                authRetries++;
                continue;
            }
            if ((int)response.StatusCode == 429 && errorCode is "concurrent_dictation" or "stt_overloaded"
                && busyRetries < 3)
            {
                var retryAfter = response.Headers.RetryAfter?.Delta?.TotalSeconds ??
                    (response.Headers.RetryAfter?.Date - DateTimeOffset.UtcNow)?.TotalSeconds ?? 0;
                var seconds = Math.Max(Math.Max(0, retryAfter), Math.Pow(2, busyRetries))
                    + Random.Shared.Next(100, 301) / 1000d;
                if (DateTimeOffset.UtcNow.AddSeconds(seconds) <= busyDeadline)
                {
                    busyRetries++;
                    await Task.Delay(TimeSpan.FromSeconds(seconds), cancellationToken).ConfigureAwait(false);
                    continue;
                }
            }
            if (!response.IsSuccessStatusCode) throw new InvalidOperationException(ReadTranscriptionError(payload, (int)response.StatusCode));

            await EnsureAccountAsync(owner, accountScope).ConfigureAwait(false);
            cancellationToken.ThrowIfCancellationRequested();
            var result = ReadTranscription(payload);
            var formattedText = await FormatTextAsync(result.Text, result.Language).ConfigureAwait(false);
            await EnsureAccountAsync(owner, accountScope).ConfigureAwait(false);
            cancellationToken.ThrowIfCancellationRequested();
            if (!saveHistory)
                return new Transcription
                {
                    Id = result.RemoteId ?? Guid.NewGuid().ToString("N"), Text = formattedText,
                    Language = result.Language, AudioDurationMs = result.DurationMs > 0 ? result.DurationMs : durationMs,
                    WordCount = CountWords(formattedText), CreatedAt = DateTimeOffset.UtcNow,
                    Revision = result.Revision
                };
            var saved = await SaveTranscriptionCoreAsync(result.RemoteId is null ? formattedText : result.Text, result.Language,
                result.DurationMs > 0 ? result.DurationMs : durationMs,
                usage, result.RemoteId, result.Revision, accountScope).ConfigureAwait(false);
            // Match Mac Echo: the account's canonical transcript stays unchanged,
            // while local formatting controls only the text inserted into an app.
            saved.Text = formattedText;
            return saved;
        }
    }

    private async Task EnsureAccountAsync(string owner, string accountScope)
    {
        if ((await _authService.GetCurrentUserAsync().ConfigureAwait(false))?.Id != owner ||
            !string.Equals(_store.CurrentAccountScope, accountScope, StringComparison.OrdinalIgnoreCase))
            throw new InvalidOperationException("The VoiceLab account changed during transcription. Return to the original account to find your result.");
    }

    private static string ReadErrorCode(string payload)
    {
        try
        {
            using var document = JsonDocument.Parse(payload);
            return document.RootElement.TryGetProperty("error", out var error) && error.ValueKind == JsonValueKind.Object
                ? GetString(error, "code") : "";
        }
        catch { return ""; }
    }

    private async Task<string> FormatTextAsync(string text, string detectedLanguage)
    {
        text = text.Trim();
        if (text.Length == 0) return text;
        var modernAlphabet = _settings.GetSetting("UzbekAlphabet", "current") == "modern";
        var protectedExpansions = new List<string>();
        var replacementMarker = "\uE000" + Guid.NewGuid().ToString("N") + ":";
        List<VocabularyWord> words = [];
        try
        {
            var snippets = await _snippets.GetSnippetsAsync().ConfigureAwait(false);
            var exactTrigger = text.TrimEnd(' ', '\t', '.', '!', '?');
            var exact = snippets.FirstOrDefault(item =>
                string.Equals(item.Name.Trim(), exactTrigger, StringComparison.OrdinalIgnoreCase));
            if (exact is not null) return exact.Text;
            words = await _vocabulary.GetWordsAsync().ConfigureAwait(false);
            var corrections = words
                .Where(item => item.IsCorrection && item.Replacement.Length > 0)
                .Select(item => (Trigger: item.Word, Text: item.Replacement));
            var replacements = snippets.Select(item => (Trigger: item.Name, Text: item.Text))
                .Concat(corrections)
                .Where(item => item.Trigger.Trim().Length is > 0 and <= 200 && item.Text.Length <= 10_000)
                .GroupBy(item => item.Trigger.Trim(), StringComparer.OrdinalIgnoreCase)
                .Select(group => group.First())
                .Take(200)
                .OrderByDescending(item => item.Trigger.Length)
                .ToList();
            if (replacements.Count > 0)
            {
                var pattern = string.Join("|", replacements.Select(item => System.Text.RegularExpressions.Regex.Escape(item.Trigger.Trim())));
                text = UzbekAlphabetConverter.TransformProse(text, prose =>
                    System.Text.RegularExpressions.Regex.Replace(prose,
                        $@"(?<![\p{{L}}\p{{N}}])(?:{pattern})(?![\p{{L}}\p{{N}}])",
                        match =>
                        {
                            var expansion = replacements.First(item =>
                                string.Equals(item.Trigger.Trim(), match.Value, StringComparison.OrdinalIgnoreCase)).Text;
                            if (!modernAlphabet) return expansion;
                            var marker = replacementMarker + protectedExpansions.Count + "\uE001";
                            protectedExpansions.Add(expansion);
                            return marker;
                        },
                        System.Text.RegularExpressions.RegexOptions.IgnoreCase | System.Text.RegularExpressions.RegexOptions.CultureInvariant,
                        TimeSpan.FromMilliseconds(100)));
            }
        }
        catch { /* A damaged snippet store must not discard successful dictation. */ }
        if (modernAlphabet)
        {
            try { text = UzbekAlphabetConverter.Convert(text, detectedLanguage, words); }
            catch (Exception ex)
            {
                System.Diagnostics.Debug.WriteLine($"Uzbek alphabet conversion unavailable; keeping original transcript: {ex}");
            }
            for (var index = 0; index < protectedExpansions.Count; index++)
                text = text.Replace(replacementMarker + index + "\uE001", protectedExpansions[index], StringComparison.Ordinal);
        }
        if (_settings.GetSetting("AutoCapitalize", true)) text = char.ToUpperInvariant(text[0]) + text[1..];
        if (_settings.GetSetting("SmartPunctuation", true) && !".!?…".Contains(text[^1])) text += ".";
        if (text.Length <= 100_000)
        {
            try
            {
                var canonicalWords = await _vocabulary.GetWordsAsync().ConfigureAwait(false);
                foreach (var canonical in canonicalWords.Where(item => !item.IsCorrection).Select(item => item.Word)
                    .Where(value => value.Length is > 0 and <= 80).Take(64))
                    text = System.Text.RegularExpressions.Regex.Replace(text,
                        $@"(?<!\p{{L}}){System.Text.RegularExpressions.Regex.Escape(canonical)}(?!\p{{L}})",
                        _ => canonical, System.Text.RegularExpressions.RegexOptions.IgnoreCase | System.Text.RegularExpressions.RegexOptions.CultureInvariant,
                        TimeSpan.FromMilliseconds(100));
            }
            catch { /* A damaged dictionary must not discard a successful transcript. */ }
        }
        return text;
    }

    public Task<Transcription> SaveTranscriptionAsync(string text, string language = "auto", int audioDurationMs = 0,
        DesktopUsageContext? usage = null, string? remoteId = null, int? revision = null)
        => SaveTranscriptionCoreAsync(text, language, audioDurationMs, usage, remoteId, revision, null);

    private async Task<Transcription> SaveTranscriptionCoreAsync(string text, string language, int audioDurationMs,
        DesktopUsageContext? usage, string? remoteId, int? revision, string? expectedAccountScope)
    {
        if (string.IsNullOrWhiteSpace(text)) throw new ArgumentException("Transcription text is required.", nameof(text));
        if (remoteId is not null && (!AccountHistoryService.IsRemoteId(remoteId) || revision is null or <= 0))
            throw new ArgumentException("Invalid server transcription identity.", nameof(remoteId));
        await _gate.WaitAsync().ConfigureAwait(false);
        try
        {
            if (expectedAccountScope is not null &&
                !string.Equals(_store.CurrentAccountScope, expectedAccountScope, StringComparison.OrdinalIgnoreCase))
                throw new InvalidOperationException("The VoiceLab account changed before the transcript could be saved.");
            var items = await _store.ReadListAsync<Transcription>("transcriptions",
                expectedAccountScope: expectedAccountScope).ConfigureAwait(false);
            var item = new Transcription
            {
                Id = remoteId ?? Guid.NewGuid().ToString("N"), Text = text.Trim(), Language = language,
                AudioDurationMs = Math.Max(0, audioDurationMs), CreatedAt = DateTimeOffset.UtcNow,
                WordCount = CountWords(text), SourceAppId = usage?.AppId, SourceAppName = usage?.AppName,
                SourceCategory = usage?.Category, Revision = revision
            };
            if (remoteId is not null) items.RemoveAll(existing => existing.Id == remoteId);
            items.Insert(0, item);
            if (expectedAccountScope is not null &&
                !string.Equals(_store.CurrentAccountScope, expectedAccountScope, StringComparison.OrdinalIgnoreCase))
                throw new InvalidOperationException("The VoiceLab account changed before the transcript could be saved.");
            await _store.WriteListAsync("transcriptions", items,
                expectedAccountScope: expectedAccountScope).ConfigureAwait(false);
            return item;
        }
        finally { _gate.Release(); }
    }

    public Task<List<Transcription>> GetHistoryAsync() => _store.ReadListAsync<Transcription>("transcriptions");

    public async Task AttachUsageContextAsync(string id, DesktopUsageContext usage, string? expectedOwnerId = null)
    {
        if (string.IsNullOrWhiteSpace(id) || string.IsNullOrWhiteSpace(usage.AppId)
            || string.IsNullOrWhiteSpace(usage.AppName)) return;
        if (expectedOwnerId is not null &&
            (await _authService.GetCurrentUserAsync().ConfigureAwait(false))?.Id != expectedOwnerId) return;
        var scope = _store.CurrentAccountScope;
        await _gate.WaitAsync().ConfigureAwait(false);
        try
        {
            if (_store.CurrentAccountScope != scope ||
                (expectedOwnerId is not null &&
                    (await _authService.GetCurrentUserAsync().ConfigureAwait(false))?.Id != expectedOwnerId)) return;
            var items = await _store.ReadListAsync<Transcription>("transcriptions",
                expectedAccountScope: scope).ConfigureAwait(false);
            var item = items.FirstOrDefault(row => row.Id == id);
            if (item is null) return;
            item.SourceAppId = usage.AppId;
            item.SourceAppName = usage.AppName;
            item.SourceCategory = usage.Category;
            item.UsageSynced = false;
            if (_store.CurrentAccountScope != scope ||
                (expectedOwnerId is not null &&
                    (await _authService.GetCurrentUserAsync().ConfigureAwait(false))?.Id != expectedOwnerId)) return;
            await _store.WriteListAsync("transcriptions", items,
                expectedAccountScope: scope).ConfigureAwait(false);
        }
        finally { _gate.Release(); }
    }

    public async Task MarkUsageSyncedAsync(string id)
    {
        await _gate.WaitAsync().ConfigureAwait(false);
        try
        {
            var items = await _store.ReadListAsync<Transcription>("transcriptions").ConfigureAwait(false);
            var item = items.FirstOrDefault(row => row.Id == id);
            if (item is null || item.UsageSynced) return;
            item.UsageSynced = true;
            await _store.WriteListAsync("transcriptions", items).ConfigureAwait(false);
        }
        finally { _gate.Release(); }
    }

    public async Task DeleteTranscriptionAsync(string id)
    {
        await _gate.WaitAsync().ConfigureAwait(false);
        try
        {
            var items = await _store.ReadListAsync<Transcription>("transcriptions").ConfigureAwait(false);
            if (items.RemoveAll(item => item.Id == id) > 0)
                await _store.WriteListAsync("transcriptions", items).ConfigureAwait(false);
        }
        finally { _gate.Release(); }
    }

    public async Task ClearHistoryAsync()
    {
        await _gate.WaitAsync().ConfigureAwait(false);
        try { await _store.WriteListAsync("transcriptions", Array.Empty<Transcription>()).ConfigureAwait(false); }
        finally { _gate.Release(); }
    }

    public async Task UpdateTranscriptionTextAsync(string id, string text, int? revision = null)
    {
        text = text.Trim();
        if (text.Length == 0 || text.Length > 1_000_000) throw new ArgumentException("Enter transcription text before saving.", nameof(text));
        await _gate.WaitAsync().ConfigureAwait(false);
        try
        {
            var items = await _store.ReadListAsync<Transcription>("transcriptions").ConfigureAwait(false);
            var item = items.FirstOrDefault(item => item.Id == id) ?? throw new InvalidOperationException("Transcription not found.");
            item.Text = text;
            item.WordCount = CountWords(text);
            if (revision is > 0) item.Revision = revision;
            await _store.WriteListAsync("transcriptions", items).ConfigureAwait(false);
        }
        finally { _gate.Release(); }
    }

    public static int CountWords(string text) => WordCountPattern.Count(text);

    private static byte[] BuildPcmWave(byte[] pcm)
    {
        const int sampleRate = 16000;
        const short channels = 1;
        const short bitsPerSample = 16;
        var wave = new byte[44 + pcm.Length];
        using var stream = new MemoryStream(wave, writable: true);
        using var writer = new BinaryWriter(stream);
        writer.Write(Encoding.ASCII.GetBytes("RIFF"));
        writer.Write(36 + pcm.Length);
        writer.Write(Encoding.ASCII.GetBytes("WAVEfmt "));
        writer.Write(16);
        writer.Write((short)1);
        writer.Write(channels);
        writer.Write(sampleRate);
        writer.Write(sampleRate * channels * bitsPerSample / 8);
        writer.Write((short)(channels * bitsPerSample / 8));
        writer.Write(bitsPerSample);
        writer.Write(Encoding.ASCII.GetBytes("data"));
        writer.Write(pcm.Length);
        writer.Write(pcm);
        return wave;
    }

    private static (string Text, string Language, int DurationMs, string? RemoteId, int? Revision) ReadTranscription(string payload)
    {
        using var document = JsonDocument.Parse(payload);
        var root = document.RootElement;
        if (root.TryGetProperty("operation", out var operation) && operation.ValueKind == JsonValueKind.Object && operation.TryGetProperty("result", out var nested))
            root = nested;
        var text = GetString(root, "text");
        var language = GetString(root, "language");
        var durationMs = GetInt(root, "duration_ms");
        if (durationMs == 0) durationMs = GetInt(root, "durationMs");
        var requestId = GetString(root, "request_id");
        if (requestId.Length == 0) requestId = GetString(root, "requestId");
        var remoteId = GetString(root, "id");
        var revision = GetInt(root, "revision");
        if (string.IsNullOrWhiteSpace(text) || text.Length > 1_000_000 || text.Contains('\0') ||
            !System.Text.RegularExpressions.Regex.IsMatch(language, "^[a-z]{2,3}$") || durationMs < 0 ||
            (requestId.Length > 0 && !requestId.StartsWith("req_", StringComparison.Ordinal)) ||
            (remoteId.Length > 0 && (!AccountHistoryService.IsRemoteId(remoteId) || revision <= 0)) ||
            (remoteId.Length == 0 && revision > 0))
            throw new InvalidOperationException("VoiceLab returned an invalid transcription response.");
        return (text, language, durationMs, remoteId.Length == 0 ? null : remoteId,
            revision == 0 ? null : revision);
    }

    private static string ReadTranscriptionError(string payload, int statusCode)
    {
        try
        {
            using var document = JsonDocument.Parse(payload);
            var root = document.RootElement;
            if (root.TryGetProperty("error", out var error) && error.ValueKind == JsonValueKind.Object)
            {
                var message = GetString(error, "message");
                if (message.Length > 0) return message;
            }
            var topMessage = GetString(root, "message");
            if (topMessage.Length > 0) return topMessage;
            var detail = GetString(root, "detail");
            if (detail.Length > 0) return detail;
        }
        catch { }
        return statusCode switch
        {
            402 or 403 => "Your VoiceLab account needs an active desktop transcription plan.",
            413 => "This recording is too large. Record a shorter dictation and try again.",
            422 => "VoiceLab could not read this audio recording.",
            429 => "You have reached the current transcription limit. Try again later.",
            _ => $"VoiceLab transcription failed ({statusCode}). Please try again."
        };
    }

    private static string GetString(JsonElement root, string name) => root.ValueKind == JsonValueKind.Object && root.TryGetProperty(name, out var value) && value.ValueKind == JsonValueKind.String ? value.GetString() ?? "" : "";
    private static int GetInt(JsonElement root, string name) => root.ValueKind == JsonValueKind.Object && root.TryGetProperty(name, out var value) && value.TryGetInt32(out var result) ? result : 0;
}

public sealed class NotesService(JsonDataStore store, IAccountNotesService remote) : INotesService
{
    private readonly SemaphoreSlim _gate = new(1, 1);
    private readonly SemaphoreSlim _syncGate = new(1, 1);
    public async Task<List<Note>> GetNotesAsync() => (await store.ReadListAsync<Note>("notes").ConfigureAwait(false))
        .OrderByDescending(note => note.IsPinned).ThenByDescending(note => note.UpdatedAt).ToList();

    public async Task<Note> CreateNoteAsync(string title, string content, string? folderId = null, bool isPinned = false)
    {
        var now = DateTimeOffset.UtcNow;
        var note = new Note { Id = Guid.NewGuid().ToString("N"), Title = title?.Trim() ?? "", Content = content ?? "", FolderId = folderId, IsPinned = isPinned, CreatedAt = now, UpdatedAt = now };
        await _gate.WaitAsync().ConfigureAwait(false);
        try
        {
            var notes = await store.ReadListAsync<Note>("notes").ConfigureAwait(false);
            var state = await store.ReadListAsync<NoteSyncEntry>("note-sync").ConfigureAwait(false);
            Queue(note, state);
            await store.WriteListAsync("note-sync", state).ConfigureAwait(false);
            notes.Insert(0, note);
            await store.WriteListAsync("notes", notes).ConfigureAwait(false);
        }
        finally { _gate.Release(); }
        return note;
    }

    public async Task UpdateNoteAsync(Note note)
    {
        ArgumentNullException.ThrowIfNull(note);
        await _gate.WaitAsync().ConfigureAwait(false);
        try
        {
            var notes = await store.ReadListAsync<Note>("notes").ConfigureAwait(false);
            var index = notes.FindIndex(item => item.Id == note.Id);
            if (index < 0) throw new KeyNotFoundException("The note no longer exists.");
            note.Title = note.Title?.Trim() ?? "";
            note.UpdatedAt = DateTimeOffset.UtcNow;
            var state = await store.ReadListAsync<NoteSyncEntry>("note-sync").ConfigureAwait(false);
            Queue(note, state);
            await store.WriteListAsync("note-sync", state).ConfigureAwait(false);
            notes[index] = note;
            await store.WriteListAsync("notes", notes).ConfigureAwait(false);
        }
        finally { _gate.Release(); }
    }

    public async Task DeleteNoteAsync(string id)
    {
        await _gate.WaitAsync().ConfigureAwait(false);
        try
        {
            var notes = await store.ReadListAsync<Note>("notes").ConfigureAwait(false);
            if (notes.RemoveAll(item => item.Id == id) > 0)
            {
                var state = await store.ReadListAsync<NoteSyncEntry>("note-sync").ConfigureAwait(false);
                var entry = Entry(id, state);
                entry.Pending = new NoteMutation(Guid.Parse(id), Guid.NewGuid(), "", "", false, true, entry.Revision);
                await store.WriteListAsync("note-sync", state).ConfigureAwait(false);
                await store.WriteListAsync("notes", notes).ConfigureAwait(false);
            }
        }
        finally { _gate.Release(); }
    }

    public async Task<int> SyncAsync(CancellationToken cancellationToken = default)
    {
        await _syncGate.WaitAsync(cancellationToken).ConfigureAwait(false);
        try { return await SyncCoreAsync(cancellationToken).ConfigureAwait(false); }
        finally { _syncGate.Release(); }
    }

    private async Task<int> SyncCoreAsync(CancellationToken cancellationToken)
    {
        var accountScope = store.CurrentAccountScope;
        // Persist a pending mutation for notes created before sync was introduced.
        await _gate.WaitAsync(cancellationToken).ConfigureAwait(false);
        List<NoteMutation> pending;
        try
        {
            var notes = await store.ReadListAsync<Note>("notes", cancellationToken).ConfigureAwait(false);
            var state = await store.ReadListAsync<NoteSyncEntry>("note-sync", cancellationToken).ConfigureAwait(false);
            var known = state.Select(item => item.Id).ToHashSet(StringComparer.OrdinalIgnoreCase);
            foreach (var note in notes.Where(note => !known.Contains(note.Id))) Queue(note, state);
            await store.WriteListAsync("note-sync", state, cancellationToken).ConfigureAwait(false);
            pending = state.Where(item => item.Pending is not null).Select(item => item.Pending!).ToList();
        }
        finally { _gate.Release(); }

        var conflicts = 0;
        foreach (var mutation in pending)
        {
            cancellationToken.ThrowIfCancellationRequested();
            EnsureAccountScope(accountScope);
            var saved = await remote.SaveAsync(mutation, cancellationToken).ConfigureAwait(false);
            if (await ReceiveAsync(saved, mutation.MutationId, accountScope, cancellationToken).ConfigureAwait(false)) conflicts++;
        }

        Guid? cursor = null;
        var seen = new HashSet<Guid>();
        for (var pageNumber = 0; pageNumber < 10_000; pageNumber++)
        {
            cancellationToken.ThrowIfCancellationRequested();
            EnsureAccountScope(accountScope);
            var page = await remote.GetPageAsync(cursor, cancellationToken).ConfigureAwait(false);
            foreach (var note in page.Notes)
            {
                if (!seen.Add(note.Id)) throw new InvalidDataException("VoiceLab repeated a note across pages.");
                if (await ReceiveAsync(note, null, accountScope, cancellationToken).ConfigureAwait(false)) conflicts++;
            }
            if (page.NextCursor is null)
            {
                // Conflicts create a new local copy; upload those copies in this sync pass.
                await _gate.WaitAsync(cancellationToken).ConfigureAwait(false);
                List<NoteMutation> followUp;
                try
                {
                    EnsureAccountScope(accountScope);
                    var state = await store.ReadListAsync<NoteSyncEntry>("note-sync", cancellationToken).ConfigureAwait(false);
                    var sent = pending.Select(item => item.MutationId).ToHashSet();
                    followUp = state.Where(item => item.Pending is not null && !sent.Contains(item.Pending.MutationId))
                        .Select(item => item.Pending!).ToList();
                }
                finally { _gate.Release(); }
                foreach (var mutation in followUp)
                {
                    EnsureAccountScope(accountScope);
                    var saved = await remote.SaveAsync(mutation, cancellationToken).ConfigureAwait(false);
                    if (await ReceiveAsync(saved, mutation.MutationId, accountScope, cancellationToken).ConfigureAwait(false)) conflicts++;
                }
                return conflicts;
            }
            if (page.NextCursor == cursor) throw new InvalidDataException("VoiceLab repeated the notes cursor.");
            cursor = page.NextCursor;
        }
        throw new InvalidDataException("VoiceLab returned too many notes pages.");
    }

    private void EnsureAccountScope(string accountScope)
    {
        if (!string.Equals(store.CurrentAccountScope, accountScope, StringComparison.OrdinalIgnoreCase))
            throw new InvalidOperationException("The VoiceLab account changed during notes sync.");
    }

    private async Task<bool> ReceiveAsync(RemoteNote remoteNote, Guid? acknowledged, string accountScope,
        CancellationToken cancellationToken)
    {
        await _gate.WaitAsync(cancellationToken).ConfigureAwait(false);
        try
        {
            EnsureAccountScope(accountScope);
            var notes = await store.ReadListAsync<Note>("notes", cancellationToken).ConfigureAwait(false);
            var state = await store.ReadListAsync<NoteSyncEntry>("note-sync", cancellationToken).ConfigureAwait(false);
            EnsureAccountScope(accountScope);
            var id = remoteNote.Id.ToString("N");
            var entry = Entry(id, state);
            if (remoteNote.Revision < entry.Revision || remoteNote.Revision == entry.Revision && entry.Pending is null)
                return false;
            var conflict = false;
            if (entry.Pending is { } pending)
            {
                var acknowledgedThis = acknowledged == remoteNote.MutationId;
                if (acknowledgedThis && pending.MutationId != acknowledged && !remoteNote.Deleted)
                {
                    entry.Revision = remoteNote.Revision;
                    entry.Pending = pending with { ExpectedRevision = remoteNote.Revision };
                    await store.WriteListAsync("note-sync", state, cancellationToken).ConfigureAwait(false);
                    return false;
                }
                var matches = pending.Deleted == remoteNote.Deleted &&
                    (pending.Deleted || pending.Title == remoteNote.Title && pending.Body == remoteNote.Body &&
                        pending.IsPinned == remoteNote.IsPinned);
                if (acknowledgedThis && pending.MutationId == acknowledged || matches)
                    entry.Pending = null;
                else if (remoteNote.Revision > entry.Revision)
                {
                    if (!pending.Deleted)
                    {
                        var original = notes.FirstOrDefault(note => note.Id == id);
                        var suffix = " (copy)";
                        var title = pending.Title;
                        while (Encoding.UTF8.GetByteCount(title + suffix) > 4096 && title.Length > 0)
                            title = title[..^1];
                        var copy = new Note
                        {
                            Id = Guid.NewGuid().ToString("N"), Title = title + suffix, Content = pending.Body,
                            IsPinned = pending.IsPinned, FolderId = original?.FolderId,
                            CreatedAt = DateTimeOffset.UtcNow, UpdatedAt = DateTimeOffset.UtcNow
                        };
                        notes.Add(copy);
                        Queue(copy, state);
                    }
                    entry.Pending = null;
                    conflict = true;
                }
                else return false;
            }
            entry.Revision = remoteNote.Revision;
            var existing = notes.FirstOrDefault(note => note.Id == id);
            notes.RemoveAll(note => note.Id == id);
            if (!remoteNote.Deleted)
                notes.Add(new Note
                {
                    Id = id, Title = remoteNote.Title, Content = remoteNote.Body,
                    IsPinned = remoteNote.IsPinned, UpdatedAt = remoteNote.UpdatedAt,
                    CreatedAt = existing?.CreatedAt ?? remoteNote.UpdatedAt,
                    FolderId = existing?.FolderId
                });
            await store.WriteListAsync("notes", notes, cancellationToken).ConfigureAwait(false);
            await store.WriteListAsync("note-sync", state, cancellationToken).ConfigureAwait(false);
            return conflict;
        }
        finally { _gate.Release(); }
    }

    private static NoteSyncEntry Entry(string id, List<NoteSyncEntry> state)
    {
        var entry = state.FirstOrDefault(item => item.Id.Equals(id, StringComparison.OrdinalIgnoreCase));
        if (entry is not null) return entry;
        entry = new NoteSyncEntry { Id = id };
        state.Add(entry);
        return entry;
    }

    private static void Queue(Note note, List<NoteSyncEntry> state)
    {
        var entry = Entry(note.Id, state);
        entry.Pending = new NoteMutation(Guid.Parse(note.Id), Guid.NewGuid(), note.Title, note.Content,
            note.IsPinned, false, entry.Revision);
    }

    public Task<List<NoteFolder>> GetFoldersAsync() => store.ReadListAsync<NoteFolder>("note-folders");

    public async Task<NoteFolder> CreateFolderAsync(string name)
    {
        name = ValidateFolderName(name);
        await _gate.WaitAsync().ConfigureAwait(false);
        try
        {
            var folders = await store.ReadListAsync<NoteFolder>("note-folders").ConfigureAwait(false);
            if (folders.Any(folder => string.Equals(folder.Name, name, StringComparison.OrdinalIgnoreCase)))
                throw new InvalidOperationException("A folder with that name already exists.");
            var folder = new NoteFolder { Id = Guid.NewGuid().ToString("N"), Name = name, CreatedAt = DateTimeOffset.UtcNow };
            folders.Add(folder);
            await store.WriteListAsync("note-folders", folders).ConfigureAwait(false);
            return folder;
        }
        finally { _gate.Release(); }
    }

    public async Task RenameFolderAsync(string id, string name)
    {
        name = ValidateFolderName(name);
        await _gate.WaitAsync().ConfigureAwait(false);
        try
        {
            var folders = await store.ReadListAsync<NoteFolder>("note-folders").ConfigureAwait(false);
            var folder = folders.FirstOrDefault(item => item.Id == id) ?? throw new InvalidOperationException("Folder not found.");
            if (folders.Any(item => item.Id != id && string.Equals(item.Name, name, StringComparison.OrdinalIgnoreCase)))
                throw new InvalidOperationException("A folder with that name already exists.");
            folder.Name = name;
            await store.WriteListAsync("note-folders", folders).ConfigureAwait(false);
        }
        finally { _gate.Release(); }
    }

    public async Task DeleteFolderAsync(string id)
    {
        await _gate.WaitAsync().ConfigureAwait(false);
        try
        {
            var folders = await store.ReadListAsync<NoteFolder>("note-folders").ConfigureAwait(false);
            if (folders.RemoveAll(folder => folder.Id == id) == 0) return;
            var notes = await store.ReadListAsync<Note>("notes").ConfigureAwait(false);
            foreach (var note in notes.Where(note => note.FolderId == id)) note.FolderId = null;
            await store.WriteListAsync("notes", notes).ConfigureAwait(false);
            await store.WriteListAsync("note-folders", folders).ConfigureAwait(false);
        }
        finally { _gate.Release(); }
    }

    private static string ValidateFolderName(string name)
    {
        name = name?.Trim() ?? "";
        if (name.Length is < 1 or > 80) throw new ArgumentException("Enter a folder name up to 80 characters.", nameof(name));
        return name;
    }
}

public sealed class VocabularyService(JsonDataStore store) : IVocabularyService
{
    private readonly SemaphoreSlim _gate = new(1, 1);
    private static readonly HashSet<string> Languages =
    ["und", "uz-Latn", "uz-Cyrl", "kk-Cyrl", "kk-Latn", "ky-Cyrl", "tg-Cyrl", "tk-Latn", "ru-Cyrl", "en-Latn"];
    public Task<List<VocabularyWord>> GetWordsAsync() => store.ReadListAsync<VocabularyWord>("vocabulary");

    public async Task AddWordAsync(string word) => await SaveWordAsync(null, word).ConfigureAwait(false);

    public async Task<VocabularyWord> SaveWordAsync(string? id, string word, string replacement = "",
        string language = "und", bool isCorrection = false)
    {
        word = CleanWord(word);
        replacement = replacement?.Trim() ?? "";
        Validate(word, replacement, language, isCorrection);
        await _gate.WaitAsync().ConfigureAwait(false);
        try
        {
            var words = await store.ReadListAsync<VocabularyWord>("vocabulary").ConfigureAwait(false);
            if (words.Any(item => item.Id != id && item.Language == language &&
                NormalizeKey(item.Word) == NormalizeKey(word)))
                throw new InvalidOperationException("That word is already in your dictionary.");
            var entry = id is null ? new VocabularyWord { Id = Guid.NewGuid().ToString("N"), AddedAt = DateTimeOffset.UtcNow }
                : words.FirstOrDefault(item => item.Id == id) ?? throw new KeyNotFoundException("Dictionary entry not found.");
            entry.Word = word;
            entry.Replacement = replacement;
            entry.Language = language;
            entry.IsCorrection = isCorrection;
            if (id is null) words.Insert(0, entry);
            await store.WriteListAsync("vocabulary", words).ConfigureAwait(false);
            return entry;
        }
        finally { _gate.Release(); }
    }

    public async Task<int> ImportWordsAsync(string text, string language = "und")
    {
        if (!Languages.Contains(language)) throw new ArgumentException("Choose a supported language.", nameof(language));
        var candidates = (text ?? "").Split([',', '\r', '\n'], StringSplitOptions.RemoveEmptyEntries)
            .Select(CleanWord).Where(value => value.Length > 0).ToList();
        if (candidates.Count > 10_000) throw new ArgumentException("Import up to 10,000 words at once.", nameof(text));
        foreach (var candidate in candidates) Validate(candidate, "", language, false);
        await _gate.WaitAsync().ConfigureAwait(false);
        try
        {
            var words = await store.ReadListAsync<VocabularyWord>("vocabulary").ConfigureAwait(false);
            var known = words.Where(item => item.Language == language)
                .Select(item => NormalizeKey(item.Word)).ToHashSet(StringComparer.Ordinal);
            var added = 0;
            foreach (var candidate in candidates)
            {
                if (!known.Add(NormalizeKey(candidate))) continue;
                words.Add(new VocabularyWord
                {
                    Id = Guid.NewGuid().ToString("N"), Word = candidate, Language = language,
                    AddedAt = DateTimeOffset.UtcNow
                });
                added++;
            }
            if (added > 0) await store.WriteListAsync("vocabulary", words).ConfigureAwait(false);
            return added;
        }
        finally { _gate.Release(); }
    }

    private static string CleanWord(string? word) => new string((word ?? "").Where(value => !char.IsControl(value)).ToArray()).Trim();

    private static string NormalizeKey(string value) => string.Join(' ', value.Normalize(NormalizationForm.FormKC)
        .Replace('‘', 'ʼ').Replace('’', 'ʼ').Replace('`', 'ʼ').Split(' ', StringSplitOptions.RemoveEmptyEntries))
        .ToLowerInvariant();

    private static void Validate(string word, string replacement, string language, bool isCorrection)
    {
        if (word.Length is < 1 or > 200) throw new ArgumentException("Enter a word up to 200 characters.");
        if (replacement.Length > 10_000 || replacement.Any(char.IsControl))
            throw new ArgumentException("Replacement text is invalid or too long.");
        if (isCorrection && replacement.Length == 0) throw new ArgumentException("A correction needs replacement text.");
        if (!Languages.Contains(language)) throw new ArgumentException("Choose a supported language.");
    }

    public async Task DeleteWordAsync(string id)
    {
        await _gate.WaitAsync().ConfigureAwait(false);
        try
        {
            var words = await store.ReadListAsync<VocabularyWord>("vocabulary").ConfigureAwait(false);
            if (words.RemoveAll(item => item.Id == id) > 0)
                await store.WriteListAsync("vocabulary", words).ConfigureAwait(false);
        }
        finally { _gate.Release(); }
    }
}

public sealed class SnippetsService(JsonDataStore store) : ISnippetsService
{
    private readonly SemaphoreSlim _gate = new(1, 1);
    public Task<List<Snippet>> GetSnippetsAsync() => store.ReadListAsync<Snippet>("snippets");

    public async Task<Snippet> CreateSnippetAsync(string name, string text)
    {
        if (string.IsNullOrWhiteSpace(name)) throw new ArgumentException("A snippet name is required.", nameof(name));
        if (string.IsNullOrWhiteSpace(text)) throw new ArgumentException("Snippet text is required.", nameof(text));
        if (name.Trim().Length > 100 || text.Trim().Length > 10_000) throw new ArgumentException("The trigger or replacement is too long.");
        var snippet = new Snippet { Id = Guid.NewGuid().ToString("N"), Name = name.Trim(), Text = text.Trim(), CreatedAt = DateTimeOffset.UtcNow };
        await _gate.WaitAsync().ConfigureAwait(false);
        try
        {
            var snippets = await store.ReadListAsync<Snippet>("snippets").ConfigureAwait(false);
            if (snippets.Any(item => string.Equals(item.Name, snippet.Name, StringComparison.OrdinalIgnoreCase)))
                throw new InvalidOperationException("That spoken trigger is already saved.");
            snippets.Insert(0, snippet);
            await store.WriteListAsync("snippets", snippets).ConfigureAwait(false);
        }
        finally { _gate.Release(); }
        return snippet;
    }

    public async Task UpdateSnippetAsync(string id, string name, string text)
    {
        name = name.Trim(); text = text.Trim();
        if (name.Length is < 1 or > 100 || text.Length is < 1 or > 10_000)
            throw new ArgumentException("Enter a trigger and replacement within their allowed lengths.");
        await _gate.WaitAsync().ConfigureAwait(false);
        try
        {
            var snippets = await store.ReadListAsync<Snippet>("snippets").ConfigureAwait(false);
            var snippet = snippets.FirstOrDefault(item => item.Id == id) ?? throw new InvalidOperationException("Snippet not found.");
            if (snippets.Any(item => item.Id != id && string.Equals(item.Name, name, StringComparison.OrdinalIgnoreCase)))
                throw new InvalidOperationException("That spoken trigger is already saved.");
            snippet.Name = name; snippet.Text = text;
            await store.WriteListAsync("snippets", snippets).ConfigureAwait(false);
        }
        finally { _gate.Release(); }
    }

    public async Task DeleteSnippetAsync(string id)
    {
        await _gate.WaitAsync().ConfigureAwait(false);
        try
        {
            var snippets = await store.ReadListAsync<Snippet>("snippets").ConfigureAwait(false);
            if (snippets.RemoveAll(item => item.Id == id) > 0)
                await store.WriteListAsync("snippets", snippets).ConfigureAwait(false);
        }
        finally { _gate.Release(); }
    }
}

public sealed class StatisticsService(ITranscriptionService transcriptionService, ISettingsService settings) : IStatisticsService
{
    public async Task<UsageStats> GetStatsAsync()
    {
        var items = await transcriptionService.GetHistoryAsync().ConfigureAwait(false);
        var metrics = StatisticsMetrics.FromLocalHistory(items);
        var typingSpeed = settings.GetSetting("TypingWordsPerMinute", 40);
        return new UsageStats { TotalTranscriptions = metrics.Recordings, TotalWords = metrics.Words,
            HoursSaved = metrics.SecondsSaved(typingSpeed) / 3600d, AccuracyPercent = 0 };
    }
}

public sealed class SettingsService(JsonDataStore store) : ISettingsService
{
    private readonly object _gate = new();
    private Dictionary<string, JsonElement> _settings = Load(store);

    public T GetSetting<T>(string key, T defaultValue)
    {
        lock (_gate)
        {
            if (!_settings.TryGetValue(key, out var value)) return defaultValue;
            try { return value.Deserialize<T>() ?? defaultValue; }
            catch (Exception ex) when (ex is JsonException or NotSupportedException or InvalidOperationException)
            { return defaultValue; }
        }
    }

    public void SaveSetting<T>(string key, T value)
    {
        lock (_gate)
        {
            _settings[key] = JsonSerializer.SerializeToElement(value);
            store.WriteGlobalObject("settings", _settings);
        }
    }

    private static Dictionary<string, JsonElement> Load(JsonDataStore store)
    {
        try { return store.ReadGlobalObject<Dictionary<string, JsonElement>>("settings") ??
            new Dictionary<string, JsonElement>(StringComparer.OrdinalIgnoreCase); }
        catch (Exception ex) when (ex is JsonException or IOException or UnauthorizedAccessException or System.ComponentModel.Win32Exception)
        { return new Dictionary<string, JsonElement>(StringComparer.OrdinalIgnoreCase); }
    }
}

public sealed class Transcription
{
    public string Id { get; set; } = "";
    public string Text { get; set; } = "";
    public string Language { get; set; } = "auto";
    public DateTimeOffset CreatedAt { get; set; }
    [System.Text.Json.Serialization.JsonIgnore]
    public string DisplayDate => CreatedAt.ToLocalTime().ToString("g");
    public int AudioDurationMs { get; set; }
    public int WordCount { get; set; }
    public string? SourceAppId { get; set; }
    public string? SourceAppName { get; set; }
    public string? SourceCategory { get; set; }
    public bool UsageSynced { get; set; }
    public int? Revision { get; set; }
    [System.Text.Json.Serialization.JsonIgnore] public bool IsCloudOnly { get; set; }
    // The desktop API has no transcript DELETE operation. Removing a local
    // copy of a server row would only make the row reappear on the next sync.
    [System.Text.Json.Serialization.JsonIgnore] public bool CanDelete => !IsCloudOnly && !IsRemote;
    [System.Text.Json.Serialization.JsonIgnore] public bool IsRemote => Id.StartsWith("dst_", StringComparison.Ordinal);
}

public sealed record DesktopUsageContext(string AppId, string AppName, string Category);

public sealed class Note
{
    public string Id { get; set; } = "";
    public string Title { get; set; } = "";
    [System.Text.Json.Serialization.JsonIgnore]
    public string DisplayTitle => string.IsNullOrWhiteSpace(Title) ? "New note" : Title;
    public string Content { get; set; } = "";
    public bool IsPinned { get; set; }
    public string? FolderId { get; set; }
    public DateTimeOffset CreatedAt { get; set; }
    public DateTimeOffset UpdatedAt { get; set; }
}

public sealed class NoteSyncEntry
{
    public string Id { get; set; } = "";
    public int Revision { get; set; }
    public NoteMutation? Pending { get; set; }
}

public sealed class NoteFolder
{
    public string Id { get; set; } = "";
    public string Name { get; set; } = "";
    public DateTimeOffset CreatedAt { get; set; }
}

public sealed class VocabularyWord
{
    public string Id { get; set; } = "";
    public string Word { get; set; } = "";
    public string Replacement { get; set; } = "";
    public string Language { get; set; } = "und";
    public bool IsCorrection { get; set; }
    [System.Text.Json.Serialization.JsonIgnore]
    public string DisplayWord => IsCorrection && Replacement.Length > 0 ? Word + " → " + Replacement : Word;
    public DateTimeOffset AddedAt { get; set; }
}

public sealed class Snippet
{
    public string Id { get; set; } = "";
    public string Name { get; set; } = "";
    public string Text { get; set; } = "";
    public DateTimeOffset CreatedAt { get; set; }
}

public sealed class UsageStats
{
    public int TotalTranscriptions { get; set; }
    public int TotalWords { get; set; }
    public double HoursSaved { get; set; }
    public double AccuracyPercent { get; set; }
}
