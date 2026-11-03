namespace VoiceLab.Core.Models;

public sealed class StoredDesktopSession
{
    public string RefreshToken { get; set; } = string.Empty;
    public string InstallationId { get; set; } = string.Empty;
    public string SessionId { get; set; } = string.Empty;
    public DateTimeOffset RefreshExpiresAt { get; set; }
    public bool? RefreshRetrySupported { get; set; }
    public string? PendingRefreshId { get; set; }
    public User User { get; set; } = new();
}
