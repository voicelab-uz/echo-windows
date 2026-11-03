namespace VoiceLab.Infrastructure.Services;

public sealed class VocabularyWord
{
    public string Id { get; set; } = "";
    public string Word { get; set; } = "";
    public string Replacement { get; set; } = "";
    public string Language { get; set; } = "und";
    public bool IsCorrection { get; set; }
    [System.Text.Json.Serialization.JsonIgnore]
    public string DisplayWord => IsCorrection && Replacement.Length > 0 ? Word + " → " + Replacement : Word;
    public DateTimeOffset AddedAt { get; set; }
}
