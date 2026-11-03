using System.Net;
using System.Net.Http.Headers;
using System.Text.Json;
using System.Text.Json.Serialization;
using VoiceLab.Infrastructure.Services;

namespace VoiceLab.App.Services;

public interface IAccountStatisticsService
{
    Task<AccountStatisticsSnapshot> GetAsync(CancellationToken cancellationToken = default);
}

public sealed class AccountStatisticsService(HttpClient http, IAuthenticationService auth) : IAccountStatisticsService
{
    private static readonly JsonSerializerOptions JsonOptions = new() { PropertyNameCaseInsensitive = true };

    public async Task<AccountStatisticsSnapshot> GetAsync(CancellationToken cancellationToken = default)
    {
        var zone = TimeZoneInfo.TryConvertWindowsIdToIanaId(TimeZoneInfo.Local.Id, out var iana)
            ? iana : TimeZoneInfo.Local.Id;
        for (var attempt = 0; attempt < 2; attempt++)
        {
            var token = await auth.GetAccessTokenAsync();
            if (string.IsNullOrWhiteSpace(token)) throw new InvalidOperationException("Sign in to view account statistics.");
            using var request = new HttpRequestMessage(HttpMethod.Get,
                "https://api.voicelab.uz/v1/desktop/statistics?time_zone=" + Uri.EscapeDataString(zone));
            request.Headers.Authorization = new AuthenticationHeaderValue("Bearer", token);
            using var response = await http.SendAsync(request, cancellationToken);
            if (response.StatusCode == HttpStatusCode.Unauthorized && attempt == 0 && await auth.RefreshTokenAsync()) continue;
            response.EnsureSuccessStatusCode();
            await using var body = await response.Content.ReadAsStreamAsync(cancellationToken);
            var result = await JsonSerializer.DeserializeAsync<AccountStatisticsSnapshot>(body, JsonOptions, cancellationToken)
                ?? throw new InvalidOperationException("Statistics response was empty.");
            Validate(result, zone);
            return result;
        }
        throw new InvalidOperationException("Your VoiceLab session expired. Sign in again.");
    }

    private static void Validate(AccountStatisticsSnapshot result, string zone)
    {
        if (result.TimeZone != zone || result.Days is null || result.Days.Count > 18_200 ||
            !DateOnly.TryParse(result.From, out var from) || !DateOnly.TryParse(result.Through, out var through) || from > through)
            throw new InvalidOperationException("Statistics response was invalid.");
        foreach (var day in result.Days.Concat(result.PlatformDays ?? []))
        {
            if (!DateOnly.TryParse(day.Day, out var date) || date < from || date > through ||
                day.Words is < 0 or > 1_000_000_000 || day.Recordings is < 0 or > 1_000_000 ||
                day.DurationMs < 0 || (day.Platform is not null and not "desktop" and not "ios"))
                throw new InvalidOperationException("Statistics response contained invalid activity.");
        }
        if (result.Applications is { Count: > 100_000 }) throw new InvalidOperationException("Statistics response was too large.");
    }
}

public sealed class AccountStatisticsSnapshot
{
    public List<AccountStatisticsDay> Days { get; set; } = [];
    [JsonPropertyName("platform_days")] public List<AccountStatisticsDay>? PlatformDays { get; set; }
    public List<AccountApplicationDay>? Applications { get; set; }
    public string From { get; set; } = "";
    public string Through { get; set; } = "";
    [JsonPropertyName("time_zone")] public string TimeZone { get; set; } = "";
}

public sealed class AccountStatisticsDay
{
    public string Day { get; set; } = "";
    public string Language { get; set; } = "";
    public string? Platform { get; set; }
    public int Words { get; set; }
    public int Recordings { get; set; }
    [JsonPropertyName("duration_ms")] public int DurationMs { get; set; }
}

public sealed class AccountApplicationDay
{
    public string Day { get; set; } = "";
    [JsonPropertyName("app_id")] public string AppId { get; set; } = "";
    [JsonPropertyName("app_name")] public string AppName { get; set; } = "";
    public string Category { get; set; } = "other";
    public int Words { get; set; }
    public int Recordings { get; set; }
}
