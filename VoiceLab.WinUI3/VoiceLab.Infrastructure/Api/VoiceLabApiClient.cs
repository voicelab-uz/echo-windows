using System.Net.Http;
using System.Net.Http.Json;
using System.Text.Json;
using VoiceLab.Infrastructure.Services;

namespace VoiceLab.Infrastructure.Api;

public class VoiceLabApiClient : IVoiceLabApiClient
{
    private readonly HttpClient _httpClient;
    private readonly IAuthenticationService _authService;

    public VoiceLabApiClient(
        HttpClient httpClient,
        IAuthenticationService authService)
    {
        _httpClient = httpClient;
        _authService = authService;
    }

    public async Task<ApiResponse<T>> GetAsync<T>(string endpoint)
    {
        return await ExecuteWithRetryAsync(async () =>
        {
            var request = new HttpRequestMessage(HttpMethod.Get, endpoint);
            await AddAuthHeaderAsync(request);

            var response = await _httpClient.SendAsync(request);
            return await ParseResponseAsync<T>(response);
        });
    }

    public async Task<ApiResponse<T>> PostAsync<T>(string endpoint, object? data = null)
    {
        return await ExecuteWithRetryAsync(async () =>
        {
            var request = new HttpRequestMessage(HttpMethod.Post, endpoint);
            await AddAuthHeaderAsync(request);

            if (data != null)
            {
                request.Content = JsonContent.Create(data);
            }

            var response = await _httpClient.SendAsync(request);
            return await ParseResponseAsync<T>(response);
        });
    }

    public async Task<ApiResponse<T>> PatchAsync<T>(string endpoint, object? data = null)
    {
        return await ExecuteWithRetryAsync(async () =>
        {
            var request = new HttpRequestMessage(HttpMethod.Patch, endpoint);
            await AddAuthHeaderAsync(request);

            if (data != null)
            {
                request.Content = JsonContent.Create(data);
            }

            var response = await _httpClient.SendAsync(request);
            return await ParseResponseAsync<T>(response);
        });
    }

    public async Task<ApiResponse<T>> DeleteAsync<T>(string endpoint)
    {
        return await ExecuteWithRetryAsync(async () =>
        {
            var request = new HttpRequestMessage(HttpMethod.Delete, endpoint);
            await AddAuthHeaderAsync(request);

            var response = await _httpClient.SendAsync(request);
            return await ParseResponseAsync<T>(response);
        });
    }

    private async Task<ApiResponse<T>> ExecuteWithRetryAsync<T>(Func<Task<ApiResponse<T>>> operation)
    {
        try
        {
            return await operation();
        }
        catch (HttpRequestException ex) when (ex.StatusCode == System.Net.HttpStatusCode.Unauthorized)
        {
            // Try to refresh token
            var refreshed = await _authService.RefreshTokenAsync();

            if (refreshed)
            {
                // Retry operation
                return await operation();
            }

            return new ApiResponse<T>
            {
                Success = false,
                Error = "Session expired. Please sign in again.",
                Status = 401
            };
        }
    }

    private async Task AddAuthHeaderAsync(HttpRequestMessage request)
    {
        var token = await _authService.GetAccessTokenAsync();
        if (!string.IsNullOrEmpty(token))
        {
            request.Headers.Authorization =
                new System.Net.Http.Headers.AuthenticationHeaderValue("Bearer", token);
        }
    }

    private async Task<ApiResponse<T>> ParseResponseAsync<T>(HttpResponseMessage response)
    {
        var content = await response.Content.ReadAsStringAsync();

        if (response.IsSuccessStatusCode)
        {
            var data = JsonSerializer.Deserialize<T>(content, new JsonSerializerOptions
            {
                PropertyNameCaseInsensitive = true
            });

            return new ApiResponse<T>
            {
                Success = true,
                Data = data,
                Status = (int)response.StatusCode
            };
        }

        try
        {
            var error = JsonSerializer.Deserialize<ErrorResponse>(content);
            return new ApiResponse<T>
            {
                Success = false,
                Error = error?.Message ?? "Request failed",
                Code = error?.Code,
                Status = (int)response.StatusCode
            };
        }
        catch
        {
            return new ApiResponse<T>
            {
                Success = false,
                Error = content,
                Status = (int)response.StatusCode
            };
        }
    }

    private class ErrorResponse
    {
        public string? Message { get; set; }
        public string? Code { get; set; }
    }
}
