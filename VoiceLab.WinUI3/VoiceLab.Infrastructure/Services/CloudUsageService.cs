using System.Net.Http.Headers;
using System.Text.Json;

namespace VoiceLab.Infrastructure.Services;

public sealed record CloudUsage(bool Enabled, string PlanName, int LimitSeconds, int UsedSeconds, int RemainingSeconds);

public interface ICloudUsageService
{
    Task<CloudUsage> GetUsageAsync();
}

public sealed class CloudUsageService(IAuthenticationService authentication, HttpClient httpClient) : ICloudUsageService
{
    public async Task<CloudUsage> GetUsageAsync()
    {
        for (var attempt = 0; attempt < 2; attempt++)
        {
            var token = await authentication.GetAccessTokenAsync().ConfigureAwait(false)
                ?? throw new InvalidOperationException("Sign in to view VoiceLab usage.");
            using var request = new HttpRequestMessage(HttpMethod.Get, "https://api.voicelab.uz/v1/desktop/usage");
            request.Headers.Authorization = new AuthenticationHeaderValue("Bearer", token);
            using var response = await httpClient.SendAsync(request).ConfigureAwait(false);
            if (response.StatusCode == System.Net.HttpStatusCode.Unauthorized && attempt == 0 &&
                await authentication.RefreshTokenAsync().ConfigureAwait(false)) continue;
            response.EnsureSuccessStatusCode();
            using var document = JsonDocument.Parse(await response.Content.ReadAsStringAsync().ConfigureAwait(false));
            var root = document.RootElement;
            if (!root.TryGetProperty("desktop_stt", out var stt) || stt.ValueKind != JsonValueKind.Object ||
                !stt.TryGetProperty("enabled", out var enabled) || enabled.ValueKind is not (JsonValueKind.True or JsonValueKind.False))
                throw new InvalidOperationException("VoiceLab returned an invalid usage response.");
            if (!enabled.GetBoolean()) return new CloudUsage(false, "Unavailable", 0, 0, 0);
            var limit = Number(stt, "usage_limit_seconds");
            var used = Number(stt, "used_seconds");
            var remaining = Number(stt, "remaining_seconds");
            var plan = stt.TryGetProperty("plan_name", out var name) && name.ValueKind == JsonValueKind.String ? name.GetString() ?? "VoiceLab" : "VoiceLab";
            return new CloudUsage(true, plan, limit, used, remaining);
        }
        throw new InvalidOperationException("Your VoiceLab session expired.");
    }

    private static int Number(JsonElement root, string name) =>
        root.TryGetProperty(name, out var value) && value.ValueKind == JsonValueKind.Number && value.TryGetInt32(out var count) && count >= 0 ? count : 0;
}
