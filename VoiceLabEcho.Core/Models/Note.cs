namespace VoiceLabEcho.Core.Models;

public class Note
{
    public string Id { get; set; } = Guid.NewGuid().ToString();
    public string Title { get; set; } = string.Empty;
    public string Content { get; set; } = string.Empty;
    public DateTime CreatedAt { get; set; } = DateTime.UtcNow;
    public DateTime UpdatedAt { get; set; } = DateTime.UtcNow;
    public bool IsPinned { get; set; }
    public bool IsDeleted { get; set; }
    public string? ServerVersion { get; set; }
    public SyncStatus SyncStatus { get; set; } = SyncStatus.NotSynced;
}

public enum SyncStatus
{
    NotSynced,
    Syncing,
    Synced,
    Conflict,
    Error
}
