namespace VoiceLab.Infrastructure.Storage;

using VoiceLab.Core.Models;

public interface ISecureStorageService
{
    Task SaveTokenAsync(string token);
    Task<string?> GetTokenAsync();
    Task<string?> GetRefreshTokenAsync();
    Task SaveSessionAsync(StoredDesktopSession session);
    Task<StoredDesktopSession?> GetSessionAsync();
    Task<string> GetOrCreateInstallationIdAsync();
    Task RemoveTokenAsync();
}
