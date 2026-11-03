namespace VoiceLab.Infrastructure.Services;

public sealed class Transcription
{
    public string Id { get; set; } = "";
    public string Text { get; set; } = "";
    public string Language { get; set; } = "auto";
    public DateTimeOffset CreatedAt { get; set; }
    [System.Text.Json.Serialization.JsonIgnore]
    public string DisplayDate => CreatedAt.ToLocalTime().ToString("g");
    public int AudioDurationMs { get; set; }
    public int WordCount { get; set; }
    public string? SourceAppId { get; set; }
    public string? SourceAppName { get; set; }
    public string? SourceCategory { get; set; }
    public bool UsageSynced { get; set; }
    public int? Revision { get; set; }
    [System.Text.Json.Serialization.JsonIgnore] public bool IsCloudOnly { get; set; }
    // The desktop API has no transcript DELETE operation. Removing a local
    // copy of a server row would only make the row reappear on the next sync.
    [System.Text.Json.Serialization.JsonIgnore] public bool CanDelete => !IsCloudOnly && !IsRemote;
    [System.Text.Json.Serialization.JsonIgnore] public bool IsRemote => Id.StartsWith("dst_", StringComparison.Ordinal);
}

public sealed record DesktopUsageContext(string AppId, string AppName, string Category);
