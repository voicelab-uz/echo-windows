using VoiceLab.Infrastructure.Storage;
using System.Text;

namespace VoiceLab.Infrastructure.Services;

public interface IVocabularyService
{
    Task<List<VocabularyWord>> GetWordsAsync();
    Task AddWordAsync(string word);
    Task<VocabularyWord> SaveWordAsync(string? id, string word, string replacement = "",
        string language = "und", bool isCorrection = false);
    Task<int> ImportWordsAsync(string text, string language = "und");
    Task DeleteWordAsync(string id);
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
