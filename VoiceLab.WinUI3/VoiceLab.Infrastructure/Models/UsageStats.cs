namespace VoiceLab.Infrastructure.Services;

public sealed class UsageStats
{
    public int TotalTranscriptions { get; set; }
    public int TotalWords { get; set; }
    public double HoursSaved { get; set; }
    public double AccuracyPercent { get; set; }
}
