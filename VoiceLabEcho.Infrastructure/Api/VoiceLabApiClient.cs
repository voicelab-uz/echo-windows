using System.Text.Json;
using VoiceLabEcho.Core.Models;

namespace VoiceLabEcho.Infrastructure.Api;

public class VoiceLabApiClient
{
    private readonly HttpClient _httpClient;
    private string? _accessToken;

    public VoiceLabApiClient(HttpClient httpClient)
    {
        _httpClient = httpClient;
        _httpClient.BaseAddress = new Uri("https://api.voicelab.uz");
    }

    public void SetAccessToken(string accessToken)
    {
        _accessToken = accessToken;
    }

    // Authentication
    public async Task<AuthorizationResponse> StartAuthorizationAsync(string redirectUri, string codeChallenge)
    {
        var request = new
        {
            redirect_uri = redirectUri,
            code_challenge = codeChallenge,
            code_challenge_method = "S256"
        };

        var response = await PostAsync<AuthorizationResponse>("/api/v2/auth/desktop/authorizations", request);
        return response ?? throw new Exception("Failed to start authorization");
    }

    public async Task<TokenResponse> ExchangeCodeAsync(string code, string codeVerifier, string redirectUri)
    {
        var request = new
        {
            grant_type = "authorization_code",
            code,
            code_verifier = codeVerifier,
            redirect_uri = redirectUri
        };

        var response = await PostAsync<TokenResponse>("/api/v2/auth/desktop/token", request);
        return response ?? throw new Exception("Failed to exchange code");
    }

    public async Task<TokenResponse> RefreshTokenAsync(string refreshToken)
    {
        var request = new
        {
            grant_type = "refresh_token",
            refresh_token = refreshToken
        };

        var response = await PostAsync<TokenResponse>("/api/v2/auth/desktop/token", request);
        return response ?? throw new Exception("Failed to refresh token");
    }

    public async Task<bool> LogoutAsync(string accessToken, string refreshToken)
    {
        var request = new
        {
            access_token = accessToken,
            refresh_token = refreshToken
        };

        try
        {
            await PostAsync<object>("/api/v2/auth/desktop/logout", request);
            return true;
        }
        catch
        {
            return false;
        }
    }

    // Transcription
    public async Task<TranscriptionResponse> TranscribeAsync(string audioFilePath, string language = "auto")
    {
        using var content = new MultipartFormDataContent();

        var audioBytes = await File.ReadAllBytesAsync(audioFilePath);
        var audioContent = new ByteArrayContent(audioBytes);
        audioContent.Headers.ContentType = new System.Net.Http.Headers.MediaTypeHeaderValue("audio/wav");
        content.Add(audioContent, "audio", Path.GetFileName(audioFilePath));
        content.Add(new StringContent(language), "language");

        var request = new HttpRequestMessage(HttpMethod.Post, "/v1/desktop/stt")
        {
            Content = content
        };

        if (_accessToken != null)
            request.Headers.Authorization = new System.Net.Http.Headers.AuthenticationHeaderValue("Bearer", _accessToken);

        var response = await _httpClient.SendAsync(request);
        response.EnsureSuccessStatusCode();

        var json = await response.Content.ReadAsStringAsync();
        return JsonSerializer.Deserialize<TranscriptionResponse>(json, new JsonSerializerOptions
        {
            PropertyNameCaseInsensitive = true
        }) ?? throw new Exception("Failed to deserialize transcription response");
    }

    // Usage
    public async Task<UsageResponse> GetUsageAsync()
    {
        return await GetAsync<UsageResponse>("/v1/desktop/usage")
            ?? throw new Exception("Failed to get usage");
    }

    // History
    public async Task<HistoryResponse> GetHistoryAsync(int page = 1, int pageSize = 20)
    {
        return await GetAsync<HistoryResponse>($"/v1/desktop/transcriptions?page={page}&page_size={pageSize}")
            ?? throw new Exception("Failed to get history");
    }

    public async Task<TranscriptionResponse> UpdateTranscriptionAsync(string transcriptionId, string newText)
    {
        var request = new { text = newText };
        return await PatchAsync<TranscriptionResponse>($"/v1/desktop/transcriptions/{transcriptionId}", request)
            ?? throw new Exception("Failed to update transcription");
    }

    // Notes
    public async Task<List<NoteResponse>> GetNotesAsync()
    {
        return await GetAsync<List<NoteResponse>>("/v1/desktop/notes") ?? new List<NoteResponse>();
    }

    public async Task<NoteResponse> GetNoteAsync(string noteId)
    {
        return await GetAsync<NoteResponse>($"/v1/desktop/notes/{noteId}")
            ?? throw new Exception("Failed to get note");
    }

    public async Task<NoteResponse> SaveNoteAsync(string noteId, Note note)
    {
        var request = new
        {
            title = note.Title,
            content = note.Content,
            is_pinned = note.IsPinned
        };

        return await PutAsync<NoteResponse>($"/v1/desktop/notes/{noteId}", request)
            ?? throw new Exception("Failed to save note");
    }

    // Onboarding
    public async Task<OnboardingResponse> GetOnboardingAsync()
    {
        return await GetAsync<OnboardingResponse>("/v1/desktop/onboarding")
            ?? throw new Exception("Failed to get onboarding");
    }

    public async Task<bool> SaveOnboardingAsync(Dictionary<string, string> answers)
    {
        try
        {
            await PutAsync<object>("/v1/desktop/onboarding", answers);
            return true;
        }
        catch
        {
            return false;
        }
    }

    // Helper methods
    private async Task<T?> GetAsync<T>(string path)
    {
        var request = new HttpRequestMessage(HttpMethod.Get, path);
        if (_accessToken != null)
            request.Headers.Authorization = new System.Net.Http.Headers.AuthenticationHeaderValue("Bearer", _accessToken);

        var response = await _httpClient.SendAsync(request);
        response.EnsureSuccessStatusCode();

        var json = await response.Content.ReadAsStringAsync();
        return JsonSerializer.Deserialize<T>(json, new JsonSerializerOptions { PropertyNameCaseInsensitive = true });
    }

    private async Task<T?> PostAsync<T>(string path, object body)
    {
        var json = JsonSerializer.Serialize(body);
        var content = new StringContent(json, System.Text.Encoding.UTF8, "application/json");

        var request = new HttpRequestMessage(HttpMethod.Post, path) { Content = content };
        if (_accessToken != null)
            request.Headers.Authorization = new System.Net.Http.Headers.AuthenticationHeaderValue("Bearer", _accessToken);

        var response = await _httpClient.SendAsync(request);
        response.EnsureSuccessStatusCode();

        var responseJson = await response.Content.ReadAsStringAsync();
        return JsonSerializer.Deserialize<T>(responseJson, new JsonSerializerOptions { PropertyNameCaseInsensitive = true });
    }

    private async Task<T?> PutAsync<T>(string path, object body)
    {
        var json = JsonSerializer.Serialize(body);
        var content = new StringContent(json, System.Text.Encoding.UTF8, "application/json");

        var request = new HttpRequestMessage(HttpMethod.Put, path) { Content = content };
        if (_accessToken != null)
            request.Headers.Authorization = new System.Net.Http.Headers.AuthenticationHeaderValue("Bearer", _accessToken);

        var response = await _httpClient.SendAsync(request);
        response.EnsureSuccessStatusCode();

        var responseJson = await response.Content.ReadAsStringAsync();
        return JsonSerializer.Deserialize<T>(responseJson, new JsonSerializerOptions { PropertyNameCaseInsensitive = true });
    }

    private async Task<T?> PatchAsync<T>(string path, object body)
    {
        var json = JsonSerializer.Serialize(body);
        var content = new StringContent(json, System.Text.Encoding.UTF8, "application/json");

        var request = new HttpRequestMessage(HttpMethod.Patch, path) { Content = content };
        if (_accessToken != null)
            request.Headers.Authorization = new System.Net.Http.Headers.AuthenticationHeaderValue("Bearer", _accessToken);

        var response = await _httpClient.SendAsync(request);
        response.EnsureSuccessStatusCode();

        var responseJson = await response.Content.ReadAsStringAsync();
        return JsonSerializer.Deserialize<T>(responseJson, new JsonSerializerOptions { PropertyNameCaseInsensitive = true });
    }
}

// API Response Models
public class AuthorizationResponse
{
    public string AuthorizationUrl { get; set; } = string.Empty;
    public string State { get; set; } = string.Empty;
}

public class TokenResponse
{
    public string AccessToken { get; set; } = string.Empty;
    public string RefreshToken { get; set; } = string.Empty;
    public int ExpiresIn { get; set; }
    public string TokenType { get; set; } = "Bearer";
}

public class TranscriptionResponse
{
    public string Id { get; set; } = string.Empty;
    public string Text { get; set; } = string.Empty;
    public string Language { get; set; } = string.Empty;
    public int WordCount { get; set; }
    public DateTime CreatedAt { get; set; }
}

public class UsageResponse
{
    public int RemainingSeconds { get; set; }
    public int TotalSeconds { get; set; }
}

public class HistoryResponse
{
    public List<TranscriptionResponse> Transcriptions { get; set; } = new();
    public int Page { get; set; }
    public int PageSize { get; set; }
    public int TotalPages { get; set; }
}

public class NoteResponse
{
    public string Id { get; set; } = string.Empty;
    public string Title { get; set; } = string.Empty;
    public string Content { get; set; } = string.Empty;
    public bool IsPinned { get; set; }
    public DateTime CreatedAt { get; set; }
    public DateTime UpdatedAt { get; set; }
    public string? Version { get; set; }
}

public class OnboardingResponse
{
    public Dictionary<string, string> Answers { get; set; } = new();
    public bool IsComplete { get; set; }
}
