namespace VoiceLabEcho.Core.Models;

public class Recording
{
    public string Id { get; set; } = Guid.NewGuid().ToString();
    public DateTime CreatedAt { get; set; } = DateTime.UtcNow;
    public TimeSpan Duration { get; set; }
    public string FilePath { get; set; } = string.Empty;
    public RecordingStatus Status { get; set; } = RecordingStatus.Recording;
    public string? ErrorMessage { get; set; }
    public Transcription? Transcription { get; set; }
}

public enum RecordingStatus
{
    Recording,
    Processing,
    Completed,
    Failed,
    Cancelled
}

public class Transcription
{
    public string Id { get; set; } = string.Empty;
    public string Text { get; set; } = string.Empty;
    public string DetectedLanguage { get; set; } = string.Empty;
    public int WordCount { get; set; }
    public DateTime CreatedAt { get; set; } = DateTime.UtcNow;
    public DateTime? EditedAt { get; set; }
    public bool IsEdited { get; set; }
    public string? DestinationApp { get; set; }
    public TranscriptionMetadata Metadata { get; set; } = new();
}

public class TranscriptionMetadata
{
    public double Confidence { get; set; }
    public TimeSpan ProcessingTime { get; set; }
    public string? RequestId { get; set; }
}
