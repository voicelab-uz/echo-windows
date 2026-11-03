using VoiceLab.Infrastructure.Storage;
using System.Text;

namespace VoiceLab.Infrastructure.Services;

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
