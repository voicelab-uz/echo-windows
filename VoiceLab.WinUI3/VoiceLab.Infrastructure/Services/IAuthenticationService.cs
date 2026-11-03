using VoiceLab.Core.Models;

namespace VoiceLab.Infrastructure.Services;

public interface IAuthenticationService
{
    Task<bool> IsAuthenticatedAsync();
    Task<AuthResult> SignInWithBrowserAsync(CancellationToken cancellationToken = default);
    Task<User?> GetCurrentUserAsync();
    Task<bool> RefreshTokenAsync();
    Task SignOutAsync();
    Task<string?> GetAccessTokenAsync();
}

public class AuthResult
{
    public bool Success { get; set; }
    public User? User { get; set; }
    public string? Error { get; set; }
}
