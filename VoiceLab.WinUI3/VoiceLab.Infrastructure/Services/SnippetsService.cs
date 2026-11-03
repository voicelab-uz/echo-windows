using VoiceLab.Infrastructure.Storage;

namespace VoiceLab.Infrastructure.Services;

public interface ISnippetsService
{
    Task<List<Snippet>> GetSnippetsAsync();
    Task<Snippet> CreateSnippetAsync(string name, string text);
    Task UpdateSnippetAsync(string id, string name, string text);
    Task DeleteSnippetAsync(string id);
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
