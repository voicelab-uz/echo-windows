using System.Diagnostics;
using System.Net;
using System.Net.Sockets;
using System.Net.Http.Headers;
using System.Security.Cryptography;
using System.Text;
using System.Text.Json;
using System.Text.Json.Serialization;
using VoiceLab.Core.Models;
using VoiceLab.Infrastructure.Storage;

namespace VoiceLab.Infrastructure.Services;

/// <summary>VoiceLab desktop OAuth using PKCE and a one-time loopback callback.</summary>
public sealed class AuthenticationService : IAuthenticationService
{
    private const string ApiOrigin = "https://api.voicelab.uz";
    private const string AuthOrigin = "https://voicelab.uz";
    private const string ClientId = "voicelab-desktop";
    private static readonly TimeSpan RequestTimeout = TimeSpan.FromSeconds(20);
    private readonly HttpClient _httpClient;
    private readonly ISecureStorageService _secureStorage;
    private readonly SemaphoreSlim _authGate = new(1, 1);
    private string? _accessToken;
    private DateTimeOffset _accessExpiresAt;
    private StoredDesktopSession? _session;
    private bool _needsSessionPersistence;

    public AuthenticationService(HttpClient httpClient, ISecureStorageService secureStorage)
    {
        _httpClient = httpClient;
        _httpClient.Timeout = RequestTimeout;
        _secureStorage = secureStorage;
    }

    public async Task<bool> IsAuthenticatedAsync()
    {
        if (_session is not null && !string.IsNullOrWhiteSpace(_accessToken) && _accessExpiresAt > DateTimeOffset.UtcNow.AddMinutes(1))
            return true;
        return await RefreshTokenAsync().ConfigureAwait(false);
    }

    public async Task<AuthResult> SignInWithBrowserAsync(CancellationToken cancellationToken = default)
    {
        await _authGate.WaitAsync(cancellationToken).ConfigureAwait(false);
        try
        {
            cancellationToken.ThrowIfCancellationRequested();
            var installationId = await _secureStorage.GetOrCreateInstallationIdAsync().ConfigureAwait(false);
            var verifier = Base64Url(RandomNumberGenerator.GetBytes(32));
            var challenge = Base64Url(SHA256.HashData(Encoding.ASCII.GetBytes(verifier)));
            var state = Base64Url(RandomNumberGenerator.GetBytes(32));
            var callbackUri = StartCallbackListener(out var listener);
            using (listener)
            {
                    var authorization = await CreateAuthorizationAsync(callbackUri.ToString(), challenge, state, installationId).ConfigureAwait(false);
                    cancellationToken.ThrowIfCancellationRequested();
                    Process.Start(new ProcessStartInfo(authorization.AuthorizationUrl) { UseShellExecute = true });
                    var callback = await WaitForCallbackAsync(listener, callbackUri, state, authorization.ExpiresAt, cancellationToken).ConfigureAwait(false);
                    try
                    {
                        var newSession = await ExchangeAuthorizationCodeAsync(callback.Code, verifier, callbackUri.ToString(), installationId).ConfigureAwait(false);
                        await _secureStorage.SaveSessionAsync(newSession).ConfigureAwait(false);
                        _session = newSession;
                    }
                    catch
                    {
                        try { await WriteCallbackResponseAsync(callback.Context.Response, 400, "Sign-in failed", "Return to Echo and try again.").ConfigureAwait(false); }
                        catch { /* The browser may have closed while the token exchange was running. */ }
                        throw;
                    }
                    try { await WriteCallbackResponseAsync(callback.Context.Response, 200, "Sign-in complete", "You can close this tab and return to Echo.").ConfigureAwait(false); }
                    catch { /* A closed browser tab must not undo a completed sign-in. */ }
                    return new AuthResult { Success = true, User = _session.User };
            }
        }
        catch (Exception ex)
        {
            _accessToken = null;
            return new AuthResult { Success = false, Error = PublicError(ex) };
        }
        finally { _authGate.Release(); }
    }

    public async Task<User?> GetCurrentUserAsync()
    {
        _session ??= await _secureStorage.GetSessionAsync().ConfigureAwait(false);
        return _session?.User;
    }

    public async Task<bool> RefreshTokenAsync()
    {
        await _authGate.WaitAsync().ConfigureAwait(false);
        try
        {
            _session ??= await _secureStorage.GetSessionAsync().ConfigureAwait(false);
            if (_session is null || string.IsNullOrWhiteSpace(_session.RefreshToken)) return false;
            if (_session.RefreshExpiresAt <= DateTimeOffset.UtcNow) return false;
            if (_needsSessionPersistence)
            {
                await _secureStorage.SaveSessionAsync(_session).ConfigureAwait(false);
                _needsSessionPersistence = false;
            }
            var previous = _session;
            var oldRefreshToken = previous.RefreshToken;
            string? retryId = null;
            if (previous.RefreshRetrySupported == true)
            {
                retryId = previous.PendingRefreshId ?? Guid.NewGuid().ToString("D").ToLowerInvariant();
                previous.PendingRefreshId = retryId;
                // Persist the operation ID before sending a rotating refresh request.
                // A retry after an ambiguous response must use the same ID.
                await _secureStorage.SaveSessionAsync(previous).ConfigureAwait(false);
            }
            var response = await PostJsonAsync("/api/v2/auth/desktop/token", new
            {
                grant_type = "refresh_token",
                client_id = ClientId,
                refresh_token = oldRefreshToken,
                installation_id = previous.InstallationId
            }, headers: retryId is null ? null : new Dictionary<string, string> { ["Idempotency-Key"] = retryId }).ConfigureAwait(false);
            var refreshed = ReadSession(response, previous.InstallationId, previous.User, previous.RefreshRetrySupported);
            if (FixedTimeEquals(oldRefreshToken, refreshed.RefreshToken))
                throw new InvalidOperationException("VoiceLab did not rotate the refresh token.");
            if (refreshed.User.Id != previous.User.Id)
                throw new InvalidOperationException("VoiceLab returned a different account during refresh.");
            _session = refreshed;
            _accessToken = response.AccessToken;
            _accessExpiresAt = DateTimeOffset.UtcNow.AddSeconds(response.ExpiresIn);
            _needsSessionPersistence = true;
            await _secureStorage.SaveSessionAsync(refreshed).ConfigureAwait(false);
            _needsSessionPersistence = false;
            return true;
        }
        catch (HttpRequestException ex) when (ex.StatusCode == HttpStatusCode.Unauthorized)
        {
            _accessToken = null;
            _session = null;
            _needsSessionPersistence = false;
            await _secureStorage.RemoveTokenAsync().ConfigureAwait(false);
            return false;
        }
        catch
        {
            _accessToken = null;
            return false;
        }
        finally { _authGate.Release(); }
    }

    public async Task SignOutAsync()
    {
        // Obtain a current bearer token before taking the gate: refreshing one
        // while holding it would deadlock, and logout must use the latest rotated
        // refresh token from the session that is actually removed below.
        var revocationToken = await GetAccessTokenAsync().ConfigureAwait(false);
        StoredDesktopSession? previous;
        await _authGate.WaitAsync().ConfigureAwait(false);
        try
        {
            previous = _session ?? await _secureStorage.GetSessionAsync().ConfigureAwait(false);
            // If credential removal fails, retain the in-memory session and
            // report failure instead of claiming that device sign-out succeeded.
            await _secureStorage.RemoveTokenAsync().ConfigureAwait(false);
            _session = null;
            _accessToken = null;
            _accessExpiresAt = default;
            _needsSessionPersistence = false;
        }
        finally { _authGate.Release(); }

        if (previous is null || previous.RefreshExpiresAt <= DateTimeOffset.UtcNow) return;
        if (string.IsNullOrWhiteSpace(revocationToken))
            throw new RemoteSessionRevocationException("Signed out on this device, but Echo could not reach the server to end the session.");
        try
        {
            using var request = new HttpRequestMessage(HttpMethod.Post, ApiOrigin + "/api/v2/auth/desktop/logout")
            {
                Content = System.Net.Http.Json.JsonContent.Create(new
                {
                    refresh_token = previous.RefreshToken,
                    installation_id = previous.InstallationId
                })
            };
            request.Headers.Authorization = new AuthenticationHeaderValue("Bearer", revocationToken);
            using var response = await _httpClient.SendAsync(request).ConfigureAwait(false);
            response.EnsureSuccessStatusCode();
        }
        catch (Exception ex)
        {
            throw new RemoteSessionRevocationException("Signed out on this device, but Echo could not end the server session.", ex);
        }
    }

    public async Task<string?> GetAccessTokenAsync()
    {
        if (_accessToken is null || _accessExpiresAt <= DateTimeOffset.UtcNow.AddMinutes(1))
        {
            if (!await RefreshTokenAsync().ConfigureAwait(false)) return null;
        }
        return _accessToken;
    }

    private async Task<AuthorizationResponse> CreateAuthorizationAsync(string redirectUri, string codeChallenge, string state, string installationId)
    {
        var response = await PostJsonAsync("/api/v2/auth/desktop/authorizations", new
        {
            client_id = ClientId,
            redirect_uri = redirectUri,
            code_challenge = codeChallenge,
            code_challenge_method = "S256",
            state,
            installation_id = installationId,
            device_name = Environment.MachineName,
            app_version = typeof(AuthenticationService).Assembly.GetName().Version?.ToString() ?? "1.0.0",
            platform = "windows"
        }, HttpMethod.Post, new Dictionary<string, string> { ["X-Request-ID"] = Guid.NewGuid().ToString("D") }).ConfigureAwait(false);

        if (response.JsonRoot is not { } root) throw new InvalidOperationException("Authorization server returned an empty response.");
        var requestId = GetPropertyOrDefault(response.JsonRoot, "authorization_request_id");
        var url = GetPropertyOrDefault(response.JsonRoot, "authorization_url");
        var parsed = new Uri(url);
        var expected = new Uri(AuthOrigin);
        var query = System.Web.HttpUtility.ParseQueryString(parsed.Query);
        if (!string.Equals(parsed.Scheme, Uri.UriSchemeHttps, StringComparison.OrdinalIgnoreCase) ||
            !string.Equals(parsed.Host, expected.Host, StringComparison.OrdinalIgnoreCase) ||
            parsed.Port != expected.Port || parsed.AbsolutePath != "/app/sign-in" ||
            parsed.UserInfo.Length > 0 || parsed.Fragment.Length > 0 || parsed.Query.Length > 2048 ||
            !requestId.StartsWith("dau_", StringComparison.Ordinal) || requestId.Length > 260 ||
            !System.Text.RegularExpressions.Regex.IsMatch(requestId, "^dau_[A-Za-z0-9_-]+$") ||
            response.ExpiresIn is < 1 or > 600 ||
            query.AllKeys.Length != 1 || query.AllKeys[0] != "desktop_auth_id" ||
            query["desktop_auth_id"] != requestId)
            throw new InvalidOperationException("VoiceLab returned an untrusted sign-in URL.");
        return new AuthorizationResponse { AuthorizationUrl = parsed.ToString(), ExpiresAt = DateTimeOffset.UtcNow.AddSeconds(response.ExpiresIn) };
    }

    private async Task<StoredDesktopSession> ExchangeAuthorizationCodeAsync(string code, string verifier, string redirectUri, string installationId)
    {
        var response = await PostJsonAsync("/api/v2/auth/desktop/token", new
        {
            grant_type = "authorization_code",
            client_id = ClientId,
            redirect_uri = redirectUri,
            code,
            code_verifier = verifier,
            installation_id = installationId
        }).ConfigureAwait(false);
        var session = ReadSession(response, installationId, null);
        _accessToken = response.AccessToken;
        _accessExpiresAt = DateTimeOffset.UtcNow.AddSeconds(response.ExpiresIn);
        return session;
    }

    private static StoredDesktopSession ReadSession(TokenResponse response, string installationId, User? fallbackUser,
        bool? fallbackRefreshRetrySupported = null)
    {
        if (!string.Equals(response.TokenType, "Bearer", StringComparison.OrdinalIgnoreCase) ||
            response.AccessToken.Length < 16 || response.RefreshToken.Length < 16 ||
            response.ExpiresIn is <= 0 or > 86400 || response.RefreshExpiresIn is <= 0 or > 2592000)
            throw new InvalidOperationException("VoiceLab returned an invalid authentication response.");
        var user = response.User ?? fallbackUser ?? throw new InvalidOperationException("VoiceLab did not return an account profile.");
        if (string.IsNullOrWhiteSpace(user.Id) || string.IsNullOrWhiteSpace(user.Email))
            throw new InvalidOperationException("VoiceLab returned an invalid account profile.");
        return new StoredDesktopSession
        {
            RefreshToken = response.RefreshToken,
            InstallationId = installationId,
            SessionId = response.SessionId,
            RefreshExpiresAt = DateTimeOffset.UtcNow.AddSeconds(response.RefreshExpiresIn),
            RefreshRetrySupported = response.RefreshRetrySupported ?? fallbackRefreshRetrySupported,
            User = user
        };
    }

    private async Task<TokenResponse> PostJsonAsync(string path, object body, HttpMethod? method = null, IReadOnlyDictionary<string, string>? headers = null)
    {
        using var request = new HttpRequestMessage(method ?? HttpMethod.Post, ApiOrigin + path)
        {
            Content = System.Net.Http.Json.JsonContent.Create(body)
        };
        if (headers is not null)
            foreach (var (key, value) in headers) request.Headers.TryAddWithoutValidation(key, value);
        using var response = await _httpClient.SendAsync(request).ConfigureAwait(false);
        var payload = await response.Content.ReadAsStringAsync().ConfigureAwait(false);
        if (!response.IsSuccessStatusCode)
            throw new HttpRequestException(ReadError(payload, (int)response.StatusCode), null, response.StatusCode);
        using var document = JsonDocument.Parse(payload);
        var root = document.RootElement;
        if (root.ValueKind != JsonValueKind.Object) throw new InvalidOperationException("VoiceLab returned malformed JSON.");
        return TokenResponse.From(root);
    }

    private static string ReadError(string payload, int statusCode)
    {
        try
        {
            using var document = JsonDocument.Parse(payload);
            var root = document.RootElement;
            if (root.TryGetProperty("message", out var message) && message.ValueKind == JsonValueKind.String)
                return message.GetString() ?? $"VoiceLab sign-in failed ({statusCode}).";
            if (root.TryGetProperty("detail", out var detail) && detail.ValueKind == JsonValueKind.String)
                return detail.GetString() ?? $"VoiceLab sign-in failed ({statusCode}).";
            if (root.TryGetProperty("error", out var error) && error.ValueKind == JsonValueKind.Object && error.TryGetProperty("message", out var nested))
                return nested.GetString() ?? $"VoiceLab sign-in failed ({statusCode}).";
        }
        catch { }
        return $"VoiceLab sign-in failed ({statusCode}).";
    }

    private static Uri StartCallbackListener(out HttpListener listener)
    {
        using var probe = new TcpListener(IPAddress.Loopback, 0);
        probe.Start();
        var port = ((IPEndPoint)probe.LocalEndpoint).Port;
        probe.Stop();
        var redirect = new Uri($"http://127.0.0.1:{port}/callback");
        listener = new HttpListener();
        listener.Prefixes.Add($"http://127.0.0.1:{port}/");
        listener.Start();
        return redirect;
    }

    private static async Task<CallbackResult> WaitForCallbackAsync(HttpListener listener, Uri redirectUri, string expectedState,
        DateTimeOffset expiresAt, CancellationToken cancellationToken)
    {
        while (true)
        {
            cancellationToken.ThrowIfCancellationRequested();
            var remaining = expiresAt - DateTimeOffset.UtcNow;
            if (remaining <= TimeSpan.Zero) throw new TimeoutException("Sign-in timed out.");
            var context = await listener.GetContextAsync().WaitAsync(remaining, cancellationToken).ConfigureAwait(false);
            if (!IPAddress.IsLoopback(context.Request.RemoteEndPoint?.Address ?? IPAddress.None) ||
                !string.Equals(context.Request.HttpMethod, "GET", StringComparison.Ordinal))
            {
                try { await WriteCallbackResponseAsync(context.Response, 400, "Sign-in failed", "The callback was invalid.").ConfigureAwait(false); }
                catch { /* A rejected caller can disconnect without ending sign-in. */ }
                continue;
            }
            var code = ReadCallbackCode(context.Request.Url, context.Request.Headers.GetValues("Host"),
                redirectUri, expectedState);
            if (code is null)
            {
                try { await WriteCallbackResponseAsync(context.Response, 400, "Sign-in failed", "The sign-in verification could not be completed.").ConfigureAwait(false); }
                catch { /* A rejected caller can disconnect without ending sign-in. */ }
                continue;
            }
            return new CallbackResult(context, code);
        }
    }

    private static string? ReadCallbackCode(Uri? url, string[]? hostValues, Uri redirectUri, string expectedState)
    {
        var expectedHost = $"127.0.0.1:{redirectUri.Port}";
        if (url is null || url.OriginalString.Length > 4096 ||
            !string.Equals(url.Scheme, Uri.UriSchemeHttp, StringComparison.Ordinal) ||
            !string.Equals(url.Host, "127.0.0.1", StringComparison.Ordinal) ||
            url.Port != redirectUri.Port || url.AbsolutePath != redirectUri.AbsolutePath ||
            url.UserInfo.Length > 0 || url.Fragment.Length > 0 ||
            hostValues is not { Length: 1 } ||
            !string.Equals(hostValues[0], expectedHost, StringComparison.Ordinal)) return null;
        var query = System.Web.HttpUtility.ParseQueryString(url.Query);
        if (query.AllKeys.Length != 2 || query.GetValues("code") is not { Length: 1 } codes ||
            query.GetValues("state") is not { Length: 1 } states ||
            !FixedTimeEquals(expectedState, states[0])) return null;
        var code = codes[0];
        return System.Text.RegularExpressions.Regex.IsMatch(code, @"^dac_[A-Za-z0-9_-]{1,1020}$",
            System.Text.RegularExpressions.RegexOptions.CultureInvariant, TimeSpan.FromMilliseconds(100))
            ? code : null;
    }

    private static async Task WriteCallbackResponseAsync(HttpListenerResponse response, int statusCode, string title, string message)
    {
        var html = $"<!doctype html><html><head><meta charset=\"utf-8\"><meta name=\"viewport\" content=\"width=device-width,initial-scale=1\"><title>{WebUtility.HtmlEncode(title)}</title></head><body style=\"font:16px system-ui;background:#f7f7f5;color:#171717;display:grid;min-height:95vh;place-items:center\"><main style=\"background:white;border:1px solid #ddd;border-radius:18px;padding:30px;max-width:440px\"><h2>{WebUtility.HtmlEncode(title)}</h2><p>{WebUtility.HtmlEncode(message)}</p></main></body></html>";
        var bytes = Encoding.UTF8.GetBytes(html);
        response.StatusCode = statusCode;
        response.ContentType = "text/html; charset=utf-8";
        response.Headers["Cache-Control"] = "no-store";
        response.Headers["Referrer-Policy"] = "no-referrer";
        response.ContentLength64 = bytes.Length;
        await response.OutputStream.WriteAsync(bytes).ConfigureAwait(false);
        response.Close();
    }

    private static string Base64Url(byte[] bytes) => Convert.ToBase64String(bytes).TrimEnd('=').Replace('+', '-').Replace('/', '_');

    private static bool FixedTimeEquals(string left, string right)
    {
        var a = Encoding.UTF8.GetBytes(left);
        var b = Encoding.UTF8.GetBytes(right);
        return a.Length == b.Length && CryptographicOperations.FixedTimeEquals(a, b);
    }

    private static string PublicError(Exception exception) => exception switch
    {
        TimeoutException => "Sign-in timed out. Please try again.",
        HttpRequestException http when http.StatusCode is not null => http.Message,
        HttpRequestException => "VoiceLab could not be reached. Check your internet connection and try again.",
        _ => exception.Message
    };

    private sealed class AuthorizationResponse { public string AuthorizationUrl { get; set; } = ""; public DateTimeOffset ExpiresAt { get; set; } }
    private sealed record CallbackResult(HttpListenerContext Context, string Code);

    private sealed class TokenResponse
    {
        public string AccessToken { get; set; } = "";
        public string RefreshToken { get; set; } = "";
        public string TokenType { get; set; } = "";
        public int ExpiresIn { get; set; }
        public int RefreshExpiresIn { get; set; }
        public bool? RefreshRetrySupported { get; set; }
        public string SessionId { get; set; } = "";
        public string RequestId { get; set; } = "";
        public User? User { get; set; }
        public JsonElement? JsonRoot { get; set; }

        public static TokenResponse From(JsonElement root)
        {
            var response = JsonSerializer.Deserialize<TokenResponse>(root.GetRawText(), new JsonSerializerOptions { PropertyNameCaseInsensitive = true }) ?? new TokenResponse();
            response.JsonRoot = root.Clone();
            response.AccessToken = GetString(root, "access_token");
            response.RefreshToken = GetString(root, "refresh_token");
            response.TokenType = GetString(root, "token_type");
            response.SessionId = GetString(root, "session_id");
            response.RequestId = GetString(root, "request_id");
            response.ExpiresIn = GetInt(root, "expires_in");
            response.RefreshExpiresIn = GetInt(root, "refresh_expires_in");
            response.RefreshRetrySupported = root.TryGetProperty("refresh_retry_supported", out var retrySupported) &&
                retrySupported.ValueKind is JsonValueKind.True or JsonValueKind.False ? retrySupported.GetBoolean() : null;
            response.User = ParseUser(root);
            return response;
        }

        private static string GetString(JsonElement element, string property) => element.TryGetProperty(property, out var value) && value.ValueKind == JsonValueKind.String ? value.GetString() ?? "" : "";
        private static int GetInt(JsonElement element, string property) => element.TryGetProperty(property, out var value) && value.TryGetInt32(out var number) ? number : 0;
        private static User? ParseUser(JsonElement root)
        {
            var candidates = new List<JsonElement> { root };
            foreach (var parent in new[] { "user", "profile", "result", "data" })
                if (root.TryGetProperty(parent, out var nested) && nested.ValueKind == JsonValueKind.Object)
                {
                    candidates.Add(nested);
                    if (nested.TryGetProperty("user", out var user) && user.ValueKind == JsonValueKind.Object) candidates.Add(user);
                }
            foreach (var candidate in candidates)
            {
                var id = GetAnyString(candidate, "id", "user_id", "uuid", "sub");
                var email = GetAnyString(candidate, "email", "username", "preferred_username");
                if (id.Length == 0 || email.Length == 0) continue;
                return new User { Id = id, Email = email, Name = GetAnyString(candidate, "name", "full_name", "display_name") is { Length: > 0 } name ? name : email, Image = GetAnyString(candidate, "image", "avatar_url", "picture") };
            }
            return null;
        }
        private static string GetAnyString(JsonElement element, params string[] names)
        {
            foreach (var name in names)
                if (element.TryGetProperty(name, out var value) && value.ValueKind == JsonValueKind.String) return value.GetString() ?? "";
            return "";
        }
    }

    private static string GetPropertyOrDefault(JsonElement? element, string property)
    {
        if (element is { ValueKind: JsonValueKind.Object } root && root.TryGetProperty(property, out var value) && value.ValueKind == JsonValueKind.String)
            return value.GetString() ?? "";
        return "";
    }
}

public sealed class RemoteSessionRevocationException : Exception
{
    public RemoteSessionRevocationException(string message, Exception? inner = null) : base(message, inner) { }
}
