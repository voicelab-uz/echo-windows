using VoiceLabEcho.Core.Models;

namespace VoiceLabEcho.Core.Interfaces;

public interface IAuthenticationService
{
    Task<bool> IsAuthenticatedAsync();
    Task<AuthenticationState> GetAuthenticationStateAsync();
    Task<string> StartAuthorizationAsync();
    Task<bool> CompleteAuthorizationAsync(string authorizationCode);
    Task<bool> RefreshTokenAsync();
    Task SignOutAsync();
    event EventHandler<AuthenticationState>? AuthenticationStateChanged;
}
