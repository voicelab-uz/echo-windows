using System.Net;
using System.Net.Http.Headers;
using System.Net.Http.Json;
using System.Text.Json;

namespace VoiceLab.Infrastructure.Services;

public sealed record AccountHistoryPage(IReadOnlyList<Transcription> Items, bool HasMore, int Page);

public interface IAccountHistoryService
{
    Task<AccountHistoryPage> GetPageAsync(int page, CancellationToken cancellationToken = default);
    Task<Transcription> UpdateAsync(Transcription current, string text, CancellationToken cancellationToken = default);
}

/// <summary>Reads and edits the account's server-backed dictations using the current Mac API contract.</summary>
public sealed class AccountHistoryService(HttpClient http, IAuthenticationService auth) : IAccountHistoryService
{
    private const string Origin = "https://api.voicelab.uz";

    public static bool IsRemoteId(string? id) => id is { Length: > 4 and <= 128 } &&
        id.StartsWith("dst_", StringComparison.Ordinal) &&
        id.AsSpan(4).IndexOfAnyExcept("abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789_-".AsSpan()) < 0;

    public async Task<AccountHistoryPage> GetPageAsync(int page, CancellationToken cancellationToken = default)
    {
        if (page is < 1 or > 100_000) throw new ArgumentOutOfRangeException(nameof(page));
        using var response = await SendAsync(HttpMethod.Get,
            $"/v1/desktop/transcriptions?page={page}&page_size=50", null, cancellationToken);
        using var document = await ReadJsonAsync(response, cancellationToken);
        var root = document.RootElement;
        var records = Property(root, "transcriptions", "items", "data");
        if (records.ValueKind != JsonValueKind.Array || records.GetArrayLength() > 50)
            throw new InvalidOperationException("VoiceLab returned an invalid history page.");
        var items = records.EnumerateArray().Select(record => ReadRecord(record)).ToList();
        var pagination = Property(root, "pagination");
        var hasMore = Boolean(root, "has_more", "hasMore", "has_next", "hasNext") ??
            Boolean(pagination, "has_more", "hasMore", "has_next", "hasNext") ??
            ((Integer(root, "next_page", "nextPage") ?? Integer(pagination, "next_page", "nextPage")) is > 0);
        return new AccountHistoryPage(items, hasMore, page);
    }

    public async Task<Transcription> UpdateAsync(Transcription current, string text, CancellationToken cancellationToken = default)
    {
        ArgumentNullException.ThrowIfNull(current);
        text = text.Trim();
        if (!IsRemoteId(current.Id) || current.Revision is null or <= 0 || text.Length is 0 or > 1_000_000)
            throw new ArgumentException("A saved account transcript and nonempty text are required.", nameof(current));
        using var content = JsonContent.Create(new { transcript = text, expected_revision = current.Revision.Value });
        using var response = await SendAsync(HttpMethod.Patch,
            "/v1/desktop/transcriptions/" + current.Id, content, cancellationToken);
        using var document = await ReadJsonAsync(response, cancellationToken);
        var root = document.RootElement;
        var record = Property(root, "transcription", "data");
        var updated = ReadRecord(record.ValueKind == JsonValueKind.Object ? record : root, current.CreatedAt);
        if (updated.Id != current.Id || updated.Revision <= current.Revision)
            throw new InvalidOperationException("VoiceLab returned a conflicting transcript revision.");
        return updated;
    }

    private async Task<HttpResponseMessage> SendAsync(HttpMethod method, string path, HttpContent? content,
        CancellationToken cancellationToken)
    {
        for (var attempt = 0; attempt < 2; attempt++)
        {
            var token = await auth.GetAccessTokenAsync();
            if (string.IsNullOrWhiteSpace(token)) throw new InvalidOperationException("Sign in to view account history.");
            using var request = new HttpRequestMessage(method, Origin + path);
            request.Headers.Authorization = new AuthenticationHeaderValue("Bearer", token);
            if (content is not null) request.Content = content;
            var response = await http.SendAsync(request, cancellationToken);
            if (response.StatusCode == HttpStatusCode.Unauthorized && attempt == 0 && method == HttpMethod.Get &&
                await auth.RefreshTokenAsync())
            {
                response.Dispose();
                continue;
            }
            if (!response.IsSuccessStatusCode)
            {
                var status = (int)response.StatusCode;
                response.Dispose();
                throw new InvalidOperationException(status switch
                {
                    401 => "Your VoiceLab session expired. Sign in again.",
                    403 => "This account cannot access saved history.",
                    409 => "This transcript changed on another device. Refresh History and try again.",
                    429 => "VoiceLab is receiving too many requests. Try again shortly.",
                    _ => $"Account history could not load (HTTP {status})."
                });
            }
            return response;
        }
        throw new InvalidOperationException("Your VoiceLab session expired. Sign in again.");
    }

    private static async Task<JsonDocument> ReadJsonAsync(HttpResponseMessage response, CancellationToken cancellationToken)
    {
        var payload = await response.Content.ReadAsByteArrayAsync(cancellationToken);
        if (payload.Length > 10_000_000) throw new InvalidOperationException("VoiceLab returned an oversized history response.");
        try { return JsonDocument.Parse(payload); }
        catch (JsonException ex) { throw new InvalidOperationException("VoiceLab returned invalid history data.", ex); }
    }

    private static Transcription ReadRecord(JsonElement root, DateTimeOffset? fallbackCreatedAt = null)
    {
        var id = String(root, "id");
        var text = String(root, "transcript", "text");
        var revision = Integer(root, "revision");
        var dateText = String(root, "created_at", "createdAt", "timestamp");
        var duration = Integer(root, "duration_ms", "durationMs") ?? 0;
        var hasDate = DateTimeOffset.TryParse(dateText, out var createdAt);
        if (!hasDate && fallbackCreatedAt is { } existingDate) createdAt = existingDate;
        if (!IsRemoteId(id) || string.IsNullOrWhiteSpace(text) || text.Length > 1_000_000 ||
            revision is null or <= 0 || duration < 0 || (!hasDate && fallbackCreatedAt is null))
            throw new InvalidOperationException("VoiceLab returned an invalid saved transcript.");
        return new Transcription
        {
            Id = id, Text = text, Language = String(root, "language") is { Length: > 0 } language ? language : "und",
            Revision = revision, AudioDurationMs = duration, CreatedAt = createdAt,
            WordCount = TranscriptionService.CountWords(text), IsCloudOnly = true
        };
    }

    private static JsonElement Property(JsonElement root, params string[] names)
    {
        if (root.ValueKind != JsonValueKind.Object) return default;
        foreach (var name in names)
            if (root.TryGetProperty(name, out var value)) return value;
        return default;
    }
    private static string String(JsonElement root, params string[] names)
    {
        var value = Property(root, names);
        return value.ValueKind == JsonValueKind.String ? value.GetString() ?? "" : "";
    }
    private static int? Integer(JsonElement root, params string[] names)
    {
        var value = Property(root, names);
        return value.ValueKind == JsonValueKind.Number && value.TryGetInt32(out var result) ? result : null;
    }
    private static bool? Boolean(JsonElement root, params string[] names)
    {
        var value = Property(root, names);
        return value.ValueKind is JsonValueKind.True or JsonValueKind.False ? value.GetBoolean() : null;
    }
}
