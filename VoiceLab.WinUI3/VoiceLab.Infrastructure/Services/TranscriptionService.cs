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
