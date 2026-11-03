using System.Net;
using System.Net.Http.Headers;
using System.Net.Http.Json;
using System.Text;
using System.Text.Json;

namespace VoiceLab.Infrastructure.Services;

public sealed record RemoteNote(Guid Id, string Title, string Body, bool IsPinned, bool Deleted,
    int Revision, Guid MutationId, DateTimeOffset UpdatedAt);

public sealed record RemoteNotesPage(IReadOnlyList<RemoteNote> Notes, Guid? NextCursor);

public sealed record NoteMutation(Guid Id, Guid MutationId, string Title, string Body, bool IsPinned,
    bool Deleted, int ExpectedRevision);

public interface IAccountNotesService
{
    Task<RemoteNotesPage> GetPageAsync(Guid? cursor = null, CancellationToken cancellationToken = default);
    Task<RemoteNote> SaveAsync(NoteMutation mutation, CancellationToken cancellationToken = default);
}

/// <summary>The current Echo desktop Notes API. A conflicting PUT returns the authoritative GET record.</summary>
public sealed class AccountNotesService(HttpClient http, IAuthenticationService auth) : IAccountNotesService
{
    private const string Origin = "https://api.voicelab.uz";

    public async Task<RemoteNotesPage> GetPageAsync(Guid? cursor = null, CancellationToken cancellationToken = default)
    {
        var path = "/v1/desktop/notes" + (cursor is null ? "" : "?cursor=" + cursor.Value.ToString("D").ToLowerInvariant());
        using var response = await SendAsync(HttpMethod.Get, path, null, cancellationToken);
        using var document = await ReadAsync(response, cancellationToken);
        var root = document.RootElement;
        if (!root.TryGetProperty("notes", out var array) || array.ValueKind != JsonValueKind.Array || array.GetArrayLength() > 20)
            throw new InvalidDataException("VoiceLab returned an invalid notes page.");
        var notes = array.EnumerateArray().Select(ParseNote).ToList();
        if (notes.Select(note => note.Id).Distinct().Count() != notes.Count)
            throw new InvalidDataException("VoiceLab returned duplicate notes.");
        Guid? next = null;
        if (root.TryGetProperty("next_cursor", out var cursorElement) && cursorElement.ValueKind == JsonValueKind.String)
        {
            var value = cursorElement.GetString();
            if (!string.IsNullOrEmpty(value))
            {
                if (!Guid.TryParse(value, out var parsed) || notes.Count == 0 || notes[^1].Id != parsed)
                    throw new InvalidDataException("VoiceLab returned an invalid notes cursor.");
                next = parsed;
            }
        }
        return new RemoteNotesPage(notes, next);
    }

    public async Task<RemoteNote> SaveAsync(NoteMutation mutation, CancellationToken cancellationToken = default)
    {
        if (mutation.Id == Guid.Empty || mutation.MutationId == Guid.Empty || mutation.ExpectedRevision < 0 ||
            Encoding.UTF8.GetByteCount(mutation.Title) > 4096 || Encoding.UTF8.GetByteCount(mutation.Body) > 524_288 ||
            mutation.Title.Contains('\0') || mutation.Body.Contains('\0'))
            throw new ArgumentException("This note is too large or contains invalid text.", nameof(mutation));
        var path = "/v1/desktop/notes/" + mutation.Id.ToString("D").ToLowerInvariant();
        var payload = new
        {
            title = mutation.Deleted ? "" : mutation.Title,
            body = mutation.Deleted ? "" : mutation.Body,
            is_pinned = !mutation.Deleted && mutation.IsPinned,
            deleted = mutation.Deleted,
            expected_revision = mutation.ExpectedRevision,
            mutation_id = mutation.MutationId.ToString("D").ToLowerInvariant()
        };
        using var response = await SendAsync(HttpMethod.Put, path, payload, cancellationToken, allowConflict: true);
        if (response.StatusCode == HttpStatusCode.Conflict)
        {
            using var get = await SendAsync(HttpMethod.Get, path, null, cancellationToken);
            using var conflict = await ReadAsync(get, cancellationToken);
            return RequireId(ParseNote(conflict.RootElement), mutation.Id);
        }
        using var document = await ReadAsync(response, cancellationToken);
        return RequireId(ParseNote(document.RootElement), mutation.Id);
    }

    private static RemoteNote RequireId(RemoteNote note, Guid id) => note.Id == id
        ? note : throw new InvalidDataException("VoiceLab returned another note ID.");

    private async Task<HttpResponseMessage> SendAsync(HttpMethod method, string path, object? payload,
        CancellationToken cancellationToken, bool allowConflict = false)
    {
        var owner = (await auth.GetCurrentUserAsync())?.Id;
        if (string.IsNullOrWhiteSpace(owner)) throw new InvalidOperationException("Sign in to sync notes.");
        for (var attempt = 0; attempt < 2; attempt++)
        {
            var token = await auth.GetAccessTokenAsync();
            if (string.IsNullOrWhiteSpace(token)) throw new InvalidOperationException("Your VoiceLab session expired. Sign in again.");
            using var request = new HttpRequestMessage(method, Origin + path);
            request.Headers.Authorization = new AuthenticationHeaderValue("Bearer", token);
            request.Headers.Accept.ParseAdd("application/json");
            if (payload is not null) request.Content = JsonContent.Create(payload);
            var response = await http.SendAsync(request, cancellationToken);
            if (response.StatusCode == HttpStatusCode.Unauthorized && attempt == 0 &&
                await auth.RefreshTokenAsync()) { response.Dispose(); continue; }
            if ((await auth.GetCurrentUserAsync())?.Id != owner)
            {
                response.Dispose();
                throw new InvalidOperationException("The VoiceLab account changed during notes sync.");
            }
            if (response.IsSuccessStatusCode || allowConflict && response.StatusCode == HttpStatusCode.Conflict)
                return response;
            var status = (int)response.StatusCode;
            response.Dispose();
            throw new HttpRequestException($"VoiceLab notes request failed (HTTP {status}).", null, (HttpStatusCode)status);
        }
        throw new InvalidOperationException("Your VoiceLab session expired. Sign in again.");
    }

    private static async Task<JsonDocument> ReadAsync(HttpResponseMessage response, CancellationToken cancellationToken)
    {
        var bytes = await response.Content.ReadAsByteArrayAsync(cancellationToken);
        if (bytes.Length > 12_000_000) throw new InvalidDataException("VoiceLab returned an oversized notes response.");
        return JsonDocument.Parse(bytes);
    }

    private static RemoteNote ParseNote(JsonElement root)
    {
        if (root.ValueKind != JsonValueKind.Object ||
            !Guid.TryParse(String(root, "id"), out var id) || id == Guid.Empty ||
            !Guid.TryParse(String(root, "mutation_id"), out var mutationId) || mutationId == Guid.Empty ||
            !DateTimeOffset.TryParse(String(root, "updated_at"), out var updatedAt) ||
            !root.TryGetProperty("revision", out var revisionValue) || !revisionValue.TryGetInt32(out var revision) || revision <= 0)
            throw new InvalidDataException("VoiceLab returned an invalid note.");
        var title = String(root, "title");
        var body = String(root, "body");
        var pinned = Boolean(root, "is_pinned");
        var deleted = Boolean(root, "deleted");
        if (Encoding.UTF8.GetByteCount(title) > 4096 || Encoding.UTF8.GetByteCount(body) > 524_288 ||
            deleted && (title.Length > 0 || body.Length > 0 || pinned))
            throw new InvalidDataException("VoiceLab returned an invalid note body.");
        return new RemoteNote(id, title, body, pinned, deleted, revision, mutationId, updatedAt);
    }

    private static string String(JsonElement root, string name) => root.TryGetProperty(name, out var value) &&
        value.ValueKind == JsonValueKind.String ? value.GetString() ?? "" : "";

    private static bool Boolean(JsonElement root, string name) => root.TryGetProperty(name, out var value) &&
        value.ValueKind is JsonValueKind.True or JsonValueKind.False ? value.GetBoolean() :
        throw new InvalidDataException("VoiceLab returned an invalid note flag.");
}
