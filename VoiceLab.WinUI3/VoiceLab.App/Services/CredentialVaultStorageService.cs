using System.Text.Json;
using VoiceLab.Core.Models;
using VoiceLab.Infrastructure.Storage;
using Windows.Security.Credentials;

namespace VoiceLab.App.Services;

/// <summary>Persists the rotating refresh credential in the Windows credential vault.</summary>
public sealed class CredentialVaultStorageService : ISecureStorageService
{
    private const string SessionResource = "VoiceLab.Echo.DesktopSession";
    private const string InstallationResource = "VoiceLab.Echo.InstallationId";
    private const string VersionedSessionPrefix = "session-";
    private const string InstallationUserName = "installation";
    private static readonly JsonSerializerOptions JsonOptions = new() { PropertyNameCaseInsensitive = true };
    private readonly object _gate = new();

    public Task SaveTokenAsync(string token) => throw new NotSupportedException("Echo stores rotating refresh credentials as a complete secure session.");

    public Task<string?> GetTokenAsync() => Task.FromResult<string?>(null);

    public async Task<string?> GetRefreshTokenAsync() => (await GetSessionAsync())?.RefreshToken;

    public Task SaveSessionAsync(StoredDesktopSession session)
    {
        ArgumentNullException.ThrowIfNull(session);
        if (string.IsNullOrWhiteSpace(session.RefreshToken))
            throw new ArgumentException("A refresh token is required.", nameof(session));
        lock (_gate)
        {
            var vault = new PasswordVault();
            // Add the replacement before removing the old rotating credential. A vault
            // failure must not erase the only persisted copy of the current session.
            var userName = VersionedSessionPrefix + DateTime.UtcNow.Ticks.ToString("D19") + "-" + Guid.NewGuid().ToString("N");
            vault.Add(new PasswordCredential(SessionResource, userName, JsonSerializer.Serialize(session)));
            try
            {
                foreach (var credential in vault.FindAllByResource(SessionResource))
                {
                    if (credential.UserName == userName) continue;
                    try { vault.Remove(credential); }
                    catch { /* The newer session is already saved; clean stale entries later. */ }
                }
            }
            catch { /* The newly added credential remains available. */ }
        }
        return Task.CompletedTask;
    }

    public Task<StoredDesktopSession?> GetSessionAsync()
    {
        lock (_gate)
        {
            try
            {
                var vault = new PasswordVault();
                var credential = vault.FindAllByResource(SessionResource)
                    .OrderByDescending(item => item.UserName, StringComparer.Ordinal)
                    .FirstOrDefault();
                if (credential is null) return Task.FromResult<StoredDesktopSession?>(null);
                credential.RetrievePassword();
                var session = JsonSerializer.Deserialize<StoredDesktopSession>(credential.Password, JsonOptions);
                return Task.FromResult(session is { RefreshToken.Length: > 0 } ? session : null);
            }
            catch
            {
                return Task.FromResult<StoredDesktopSession?>(null);
            }
        }
    }

    public Task<string> GetOrCreateInstallationIdAsync()
    {
        lock (_gate)
        {
            try
            {
                var vault = new PasswordVault();
                var existing = vault.Retrieve(InstallationResource, InstallationUserName);
                existing.RetrievePassword();
                if (Guid.TryParse(existing.Password, out var id)) return Task.FromResult(id.ToString("D").ToLowerInvariant());
            }
            catch (Exception ex) when (IsNotFound(ex)) { }

            var created = Guid.NewGuid().ToString("D").ToLowerInvariant();
            var store = new PasswordVault();
            RemoveResource(store, InstallationResource);
            store.Add(new PasswordCredential(InstallationResource, InstallationUserName, created));
            return Task.FromResult(created);
        }
    }

    public Task RemoveTokenAsync()
    {
        lock (_gate) RemoveResource(new PasswordVault(), SessionResource);
        return Task.CompletedTask;
    }

    private static void RemoveResource(PasswordVault vault, string resource)
    {
        IReadOnlyList<PasswordCredential> credentials;
        try
        {
            credentials = vault.FindAllByResource(resource);
        }
        catch (Exception ex) when (IsNotFound(ex))
        {
            return; // A missing resource is normal on first run or after logout.
        }
        foreach (var credential in credentials) vault.Remove(credential);
    }

    private static bool IsNotFound(Exception error) => error.HResult == unchecked((int)0x80070490);
}
