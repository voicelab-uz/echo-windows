using VoiceLabEcho.Core.Interfaces;
using VoiceLabEcho.Core.Models;
using VoiceLabEcho.Infrastructure.Api;
using VoiceLabEcho.Infrastructure.Security;
using VoiceLabEcho.Infrastructure.Storage;
using System.Diagnostics;
using System.Net;
using System.Net.Sockets;
using System.Text;

namespace VoiceLabEcho.Infrastructure.Services;

public class AuthenticationService : IAuthenticationService
{
    private readonly VoiceLabApiClient _apiClient;
    private readonly ICredentialManager _credentialManager;
    private readonly IStorageService _storageService;
    private readonly PkceGenerator _pkceGenerator;
    private AuthenticationState _state = new();
    private HttpListener? _httpListener;
    private string? _codeVerifier;
    private string? _state_parameter;

    public event EventHandler<AuthenticationState>? AuthenticationStateChanged;

    public AuthenticationService(
        VoiceLabApiClient apiClient,
        ICredentialManager credentialManager,
        IStorageService storageService,
        PkceGenerator pkceGenerator)
    {
        _apiClient = apiClient;
        _credentialManager = credentialManager;
        _storageService = storageService;
        _pkceGenerator = pkceGenerator;
    }

    public async Task<bool> IsAuthenticatedAsync()
    {
        await LoadAuthenticationStateAsync();
        return _state.IsAuthenticated && _state.AccessToken != null;
    }

    public Task<AuthenticationState> GetAuthenticationStateAsync()
    {
        return Task.FromResult(_state);
    }

    public async Task<string> StartAuthorizationAsync()
    {
        // Generate PKCE codes
        var (codeVerifier, codeChallenge) = _pkceGenerator.Generate();
        _codeVerifier = codeVerifier;

        // Start local HTTP listener for callback
        var port = GetAvailablePort();
        var redirectUri = $"http://127.0.0.1:{port}/callback";

        _httpListener = new HttpListener();
        _httpListener.Prefixes.Add($"http://127.0.0.1:{port}/");
        _httpListener.Start();

        // Start authorization
        var response = await _apiClient.StartAuthorizationAsync(redirectUri, codeChallenge);
        _state_parameter = response.State;

        // Listen for callback in background
        _ = Task.Run(() => ListenForCallbackAsync(redirectUri));

        return response.AuthorizationUrl;
    }

    public async Task<bool> CompleteAuthorizationAsync(string authorizationCode)
    {
        if (_codeVerifier == null)
            return false;

        try
        {
            var port = GetAvailablePort();
            var redirectUri = $"http://127.0.0.1:{port}/callback";

            var tokenResponse = await _apiClient.ExchangeCodeAsync(
                authorizationCode,
                _codeVerifier,
                redirectUri);

            await SaveTokensAsync(tokenResponse);
            return true;
        }
        catch
        {
            return false;
        }
        finally
        {
            _httpListener?.Stop();
            _httpListener = null;
        }
    }

    public async Task<bool> RefreshTokenAsync()
    {
        if (_state.RefreshToken == null)
            return false;

        try
        {
            var tokenResponse = await _apiClient.RefreshTokenAsync(_state.RefreshToken);
            await SaveTokensAsync(tokenResponse);
            return true;
        }
        catch
        {
            return false;
        }
    }

    public async Task SignOutAsync()
    {
        if (_state.AccessToken != null && _state.RefreshToken != null)
        {
            try
            {
                await _apiClient.LogoutAsync(_state.AccessToken, _state.RefreshToken);
            }
            catch
            {
                // Ignore logout errors
            }
        }

        // Clear stored credentials
        if (_state.User?.Id != null)
        {
            await _credentialManager.DeleteCredentialAsync($"AccessToken:{_state.User.Id}");
            await _credentialManager.DeleteCredentialAsync($"RefreshToken:{_state.User.Id}");
        }

        _state = new AuthenticationState();
        AuthenticationStateChanged?.Invoke(this, _state);
    }

    private async Task LoadAuthenticationStateAsync()
    {
        // Try to load saved tokens
        var userId = await _credentialManager.GetCredentialAsync("LastUserId");
        if (userId != null)
        {
            var accessToken = await _credentialManager.GetCredentialAsync($"AccessToken:{userId}");
            var refreshToken = await _credentialManager.GetCredentialAsync($"RefreshToken:{userId}");

            if (accessToken != null && refreshToken != null)
            {
                _state = new AuthenticationState
                {
                    IsAuthenticated = true,
                    AccessToken = accessToken,
                    RefreshToken = refreshToken,
                    User = new User { Id = userId }
                };

                _apiClient.SetAccessToken(accessToken);
            }
        }
    }

    private async Task SaveTokensAsync(TokenResponse tokenResponse)
    {
        _state = new AuthenticationState
        {
            IsAuthenticated = true,
            AccessToken = tokenResponse.AccessToken,
            RefreshToken = tokenResponse.RefreshToken,
            TokenExpiry = DateTime.UtcNow.AddSeconds(tokenResponse.ExpiresIn),
            User = new User { Id = "user_" + Guid.NewGuid().ToString() } // TODO: Get from API
        };

        _apiClient.SetAccessToken(tokenResponse.AccessToken);

        // Save to credential manager
        if (_state.User != null)
        {
            await _credentialManager.SaveCredentialAsync("LastUserId", _state.User.Id);
            await _credentialManager.SaveCredentialAsync($"AccessToken:{_state.User.Id}", tokenResponse.AccessToken);
            await _credentialManager.SaveCredentialAsync($"RefreshToken:{_state.User.Id}", tokenResponse.RefreshToken);

            // Initialize storage for this account
            if (_storageService is EncryptedStorageService encryptedStorage)
            {
                await encryptedStorage.InitializeForAccountAsync(_state.User.Id);
            }
        }

        AuthenticationStateChanged?.Invoke(this, _state);
    }

    private async Task ListenForCallbackAsync(string redirectUri)
    {
        try
        {
            var context = await _httpListener!.GetContextAsync();
            var query = context.Request.QueryString;

            var code = query["code"];
            var state = query["state"];

            // Send response to browser
            var responseString = code != null
                ? "<html><body><h1>Authentication successful!</h1><p>You can close this window.</p></body></html>"
                : "<html><body><h1>Authentication failed</h1><p>Please try again.</p></body></html>";

            var buffer = Encoding.UTF8.GetBytes(responseString);
            context.Response.ContentLength64 = buffer.Length;
            await context.Response.OutputStream.WriteAsync(buffer, 0, buffer.Length);
            context.Response.OutputStream.Close();

            // Complete authorization
            if (code != null && state == _state_parameter)
            {
                await CompleteAuthorizationAsync(code);
            }
        }
        catch
        {
            // Handle listener errors
        }
        finally
        {
            _httpListener?.Stop();
        }
    }

    private int GetAvailablePort()
    {
        var listener = new TcpListener(IPAddress.Loopback, 0);
        listener.Start();
        var port = ((IPEndPoint)listener.LocalEndpoint).Port;
        listener.Stop();
        return port;
    }
}
