using System.Net;
using System.Net.Http.Headers;
using System.Net.Http.Json;
using System.Text.Json;

namespace VoiceLab.Infrastructure.Services;

public sealed record InboxNotification(Guid Id, string Title, string Body, string Destination,
    DateTimeOffset CreatedAt, bool Read, string Category)
{
    public string DisplayDate => CreatedAt.LocalDateTime.ToString("g");
    public string DisplayTitle => Read ? Title : "• " + Title;
};

public sealed record AccountNotificationPage(IReadOnlyList<InboxNotification> Items,
    long? NextCursor, long? ThroughCursor, int Unread);

public interface IAccountNotificationService
{
    Task<AccountNotificationPage> GetPageAsync(long? cursor = null, CancellationToken cancellationToken = default);
    Task MarkReadAsync(Guid? id = null, long? throughCursor = null, CancellationToken cancellationToken = default);
}

/// <summary>Account notification inbox, matching the current Mac Echo desktop endpoint.</summary>
public sealed class AccountNotificationService(HttpClient http, IAuthenticationService auth)
    : IAccountNotificationService
{
    private const string Origin = "https://api.voicelab.uz";
    private static readonly HashSet<string> Destinations = ["home", "notes", "vocabulary", "settings"];
    private static readonly HashSet<string> Categories = ["important", "news"];

    public async Task<AccountNotificationPage> GetPageAsync(long? cursor = null,
        CancellationToken cancellationToken = default)
    {
        if (cursor is <= 0) throw new ArgumentOutOfRangeException(nameof(cursor));
        var path = "/v1/desktop/notifications" + (cursor is null ? "" : "?cursor=" + cursor.Value);
        using var response = await SendAsync(HttpMethod.Get, path, null, cancellationToken);
        using var document = await ReadAsync(response, cancellationToken);
        var root = document.RootElement;
        if (root.ValueKind != JsonValueKind.Object ||
            !root.TryGetProperty("items", out var rows) || rows.ValueKind != JsonValueKind.Array ||
            rows.GetArrayLength() > 20 || !root.TryGetProperty("unread", out var unreadValue) ||
            !unreadValue.TryGetInt32(out var unread) || unread < 0)
            throw new InvalidDataException("VoiceLab returned an invalid notification page.");
        var items = rows.EnumerateArray().Select(ParseItem).ToList();
        if (items.Select(item => item.Id).Distinct().Count() != items.Count)
            throw new InvalidDataException("VoiceLab returned duplicate notifications.");
        return new AccountNotificationPage(items, Cursor(root, "next_cursor"),
            Cursor(root, "through_cursor"), unread);
    }

    public async Task MarkReadAsync(Guid? id = null, long? throughCursor = null,
        CancellationToken cancellationToken = default)
    {
        if ((id is null) == (throughCursor is null) || id == Guid.Empty || throughCursor is <= 0)
            throw new ArgumentException("Choose one notification or a valid read boundary.");
        var payload = id is not null
            ? new Dictionary<string, string> { ["id"] = id.Value.ToString("D").ToLowerInvariant() }
            : new Dictionary<string, string> { ["through_cursor"] = throughCursor!.Value.ToString() };
        using var response = await SendAsync(HttpMethod.Post, "/v1/desktop/notifications/read",
            payload, cancellationToken);
    }

    private async Task<HttpResponseMessage> SendAsync(HttpMethod method, string path, object? payload,
        CancellationToken cancellationToken)
    {
        var owner = (await auth.GetCurrentUserAsync())?.Id;
        if (string.IsNullOrWhiteSpace(owner)) throw new InvalidOperationException("Sign in to view notifications.");
        for (var attempt = 0; attempt < 2; attempt++)
        {
            var token = await auth.GetAccessTokenAsync();
            if (string.IsNullOrWhiteSpace(token)) throw new InvalidOperationException("Your VoiceLab session expired. Sign in again.");
            using var request = new HttpRequestMessage(method, Origin + path);
            request.Headers.Authorization = new AuthenticationHeaderValue("Bearer", token);
            request.Headers.Accept.ParseAdd("application/json");
            if (payload is not null) request.Content = JsonContent.Create(payload);
            var response = await http.SendAsync(request, cancellationToken).ConfigureAwait(false);
            if (response.StatusCode == HttpStatusCode.Unauthorized && attempt == 0 &&
                await auth.RefreshTokenAsync().ConfigureAwait(false)) { response.Dispose(); continue; }
            if ((await auth.GetCurrentUserAsync().ConfigureAwait(false))?.Id != owner)
            {
                response.Dispose();
                throw new InvalidOperationException("The VoiceLab account changed during notification loading.");
            }
            if (response.IsSuccessStatusCode) return response;
            var status = response.StatusCode;
            response.Dispose();
            throw new HttpRequestException($"VoiceLab notifications request failed (HTTP {(int)status}).", null, status);
        }
        throw new InvalidOperationException("Your VoiceLab session expired. Sign in again.");
    }

    private static async Task<JsonDocument> ReadAsync(HttpResponseMessage response,
        CancellationToken cancellationToken)
    {
        var bytes = await response.Content.ReadAsByteArrayAsync(cancellationToken);
        if (bytes.Length > 2_000_000) throw new InvalidDataException("VoiceLab returned an oversized notifications response.");
        return JsonDocument.Parse(bytes);
    }

    private static InboxNotification ParseItem(JsonElement root)
    {
        if (root.ValueKind != JsonValueKind.Object ||
            !Guid.TryParse(String(root, "id"), out var id) || id == Guid.Empty ||
            !DateTimeOffset.TryParse(String(root, "created_at"), out var createdAt) ||
            !root.TryGetProperty("read", out var readValue) ||
            readValue.ValueKind is not (JsonValueKind.True or JsonValueKind.False))
            throw new InvalidDataException("VoiceLab returned an invalid notification.");
        var destination = String(root, "destination");
        var category = String(root, "category");
        if (category.Length == 0) category = "important";
        if (!Destinations.Contains(destination) || !Categories.Contains(category))
            throw new InvalidDataException("VoiceLab returned an unsupported notification destination.");
        return new InboxNotification(id, String(root, "title"), String(root, "body"), destination,
            createdAt, readValue.GetBoolean(), category);
    }

    private static long? Cursor(JsonElement root, string name)
    {
        if (!root.TryGetProperty(name, out var value) || value.ValueKind == JsonValueKind.Null) return null;
        if (value.ValueKind != JsonValueKind.String || !long.TryParse(value.GetString(), out var parsed) || parsed <= 0)
        {
            if (value.ValueKind == JsonValueKind.String && value.GetString() == "") return null;
            throw new InvalidDataException("VoiceLab returned an invalid notification cursor.");
        }
        return parsed;
    }

    private static string String(JsonElement root, string name) =>
        root.TryGetProperty(name, out var value) && value.ValueKind == JsonValueKind.String
            ? value.GetString() ?? "" : "";
}
