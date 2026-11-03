namespace VoiceLab.Infrastructure.Services;

public sealed class Note
{
    public string Id { get; set; } = "";
    public string Title { get; set; } = "";
    [System.Text.Json.Serialization.JsonIgnore]
    public string DisplayTitle => string.IsNullOrWhiteSpace(Title) ? "New note" : Title;
    [System.Text.Json.Serialization.JsonIgnore]
    public string Preview => string.IsNullOrWhiteSpace(Content) ? "No text yet" : Content.ReplaceLineEndings(" ");
    public string Content { get; set; } = "";
    public bool IsPinned { get; set; }
    public string? FolderId { get; set; }
    public DateTimeOffset CreatedAt { get; set; }
    public DateTimeOffset UpdatedAt { get; set; }
}

public sealed class NoteSyncEntry
{
    public string Id { get; set; } = "";
    public int Revision { get; set; }
    public NoteMutation? Pending { get; set; }
}

public sealed class NoteFolder
{
    public string Id { get; set; } = "";
    public string Name { get; set; } = "";
    public DateTimeOffset CreatedAt { get; set; }
}
