namespace VoiceLab.Infrastructure.Api;

public interface IVoiceLabApiClient
{
    Task<ApiResponse<T>> GetAsync<T>(string endpoint);
    Task<ApiResponse<T>> PostAsync<T>(string endpoint, object? data = null);
    Task<ApiResponse<T>> PatchAsync<T>(string endpoint, object? data = null);
    Task<ApiResponse<T>> DeleteAsync<T>(string endpoint);
}

public class ApiResponse<T>
{
    public bool Success { get; set; }
    public T? Data { get; set; }
    public string? Error { get; set; }
    public string? Code { get; set; }
    public int Status { get; set; }
}
