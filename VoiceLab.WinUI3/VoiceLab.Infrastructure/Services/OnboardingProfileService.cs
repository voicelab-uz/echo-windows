using System.Net.Http.Headers;
using System.Net.Http.Json;

namespace VoiceLab.Infrastructure.Services;

public interface IOnboardingProfileService
{
    Task<bool> SaveAsync();
    Task RetryPendingAsync();
    Task PullAsync();
}

public sealed class OnboardingProfileService(
    IAuthenticationService authentication,
    ISettingsService settings,
    HttpClient httpClient) : IOnboardingProfileService
{
    public async Task<bool> SaveAsync()
    {
        var user = await authentication.GetCurrentUserAsync().ConfigureAwait(false);
        if (user is null) return false;
        settings.SaveSetting("OnboardingProfilePendingUserId", user.Id);
        try
        {
            var token = await authentication.GetAccessTokenAsync().ConfigureAwait(false);
            if (string.IsNullOrWhiteSpace(token)) return false;
            var role = settings.GetSetting("UserRole", "").ToLowerInvariant() switch
            {
                "product manager" or "product" => "product", "developer" => "developer", "founder" => "founder",
                "marketing" => "marketing", "sales" => "sales", "student" => "student",
                "writer" => "writer", "other" => "other", _ => ""
            };
            var useCases = settings.GetSetting("TypingPlaces", new List<string>())
                .Select(value => value switch
                {
                    "email" or "emails" => "emails", "team-chat" or "messages" => "messages", "documents" => "documents",
                    "notes" => "notes", "code" or "coding" => "coding", "social-media" or "posts" => "posts", _ => ""
                }).Where(value => value.Length > 0).Distinct().ToArray();
            var language = settings.GetSetting("PreferredLanguage", "auto");
            var writingStyle = settings.GetSetting("WritingStyle", "");
            var theme = settings.GetSetting("Theme", "system") switch
            {
                "light" => "light",
                "dark" => "dark",
                _ => "auto"
            };
            var payload = new
            {
                role, use_cases = useCases, dictation_language = language,
                writing_style = writingStyle, ui_language = "en", theme,
                app_version = typeof(OnboardingProfileService).Assembly.GetName().Version?.ToString() ?? "1.0.0",
                platform = "win32", completed_at = DateTimeOffset.UtcNow.ToString("O")
            };
            using var request = new HttpRequestMessage(HttpMethod.Put, "https://api.voicelab.uz/v1/desktop/onboarding")
            { Content = JsonContent.Create(payload) };
            request.Headers.Authorization = new AuthenticationHeaderValue("Bearer", token);
            using var response = await httpClient.SendAsync(request).ConfigureAwait(false);
            if (!response.IsSuccessStatusCode) return false;
            if ((await authentication.GetCurrentUserAsync().ConfigureAwait(false))?.Id != user.Id) return false;
            settings.SaveSetting("OnboardingProfilePendingUserId", "");
            return true;
        }
        catch { return false; }
    }

    public async Task RetryPendingAsync()
    {
        var user = await authentication.GetCurrentUserAsync().ConfigureAwait(false);
        if (user?.Id == settings.GetSetting("OnboardingProfilePendingUserId", "")) await SaveAsync().ConfigureAwait(false);
    }

    public async Task PullAsync()
    {
        var user = await authentication.GetCurrentUserAsync().ConfigureAwait(false);
        if (user is null || settings.GetSetting("OnboardingProfilePulledUserId", "") == user.Id) return;
        try
        {
            var token = await authentication.GetAccessTokenAsync().ConfigureAwait(false);
            if (string.IsNullOrWhiteSpace(token)) return;
            using var request = new HttpRequestMessage(HttpMethod.Get, "https://api.voicelab.uz/v1/desktop/onboarding");
            request.Headers.Authorization = new AuthenticationHeaderValue("Bearer", token);
            using var response = await httpClient.SendAsync(request).ConfigureAwait(false);
            if (response.StatusCode == System.Net.HttpStatusCode.NotFound)
            {
                settings.SaveSetting("OnboardingProfilePulledUserId", user.Id);
                return;
            }
            if (!response.IsSuccessStatusCode) return;
            using var document = System.Text.Json.JsonDocument.Parse(await response.Content.ReadAsStringAsync().ConfigureAwait(false));
            if (!document.RootElement.TryGetProperty("onboarding", out var profile) || profile.ValueKind != System.Text.Json.JsonValueKind.Object) return;
            if ((await authentication.GetCurrentUserAsync().ConfigureAwait(false))?.Id != user.Id) return;
            if (settings.GetSetting("UserRole", "").Length == 0 && profile.TryGetProperty("role", out var role) && role.ValueKind == System.Text.Json.JsonValueKind.String)
                settings.SaveSetting("UserRole", role.GetString() ?? "");
            if (settings.GetSetting("TypingPlaces", new List<string>()).Count == 0 && profile.TryGetProperty("use_cases", out var cases) && cases.ValueKind == System.Text.Json.JsonValueKind.Array)
                settings.SaveSetting("TypingPlaces", cases.EnumerateArray().Where(item => item.ValueKind == System.Text.Json.JsonValueKind.String).Select(item => item.GetString() ?? "").ToList());
            if (settings.GetSetting("PreferredLanguage", "auto") == "auto" && profile.TryGetProperty("dictation_language", out var language) && language.ValueKind == System.Text.Json.JsonValueKind.String)
            {
                var value = language.GetString();
                if (new[] { "auto", "uz", "en", "ru" }.Contains(value)) settings.SaveSetting("PreferredLanguage", value);
            }
            if (settings.GetSetting("WritingStyle", "").Length == 0 && profile.TryGetProperty("writing_style", out var style) && style.ValueKind == System.Text.Json.JsonValueKind.String)
            {
                var value = style.GetString();
                if (new[] { "casual", "formal", "excited" }.Contains(value)) settings.SaveSetting("WritingStyle", value);
            }
            settings.SaveSetting("OnboardingProfilePulledUserId", user.Id);
        }
        catch { /* Keep local answers and retry on the next sign-in. */ }
    }
}
