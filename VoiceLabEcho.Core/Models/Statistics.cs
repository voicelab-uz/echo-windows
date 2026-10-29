namespace VoiceLabEcho.Core.Models;

public class Statistics
{
    public int TotalRecordings { get; set; }
    public int TotalWords { get; set; }
    public TimeSpan TotalDuration { get; set; }
    public double AverageWordsPerMinute { get; set; }
    public Dictionary<string, int> AppUsage { get; set; } = new();
    public Dictionary<DateTime, DailyActivity> DailyActivity { get; set; } = new();
    public int CurrentStreak { get; set; }
    public int LongestStreak { get; set; }
}

public class DailyActivity
{
    public DateTime Date { get; set; }
    public int RecordingCount { get; set; }
    public int WordCount { get; set; }
    public TimeSpan Duration { get; set; }
    public HashSet<string> Apps { get; set; } = new();
}

public class UsageInfo
{
    public int RemainingMinutes { get; set; }
    public int TotalMinutes { get; set; }
    public double UsagePercentage => TotalMinutes > 0 ? (double)(TotalMinutes - RemainingMinutes) / TotalMinutes * 100 : 0;
    public bool IsUnlimited => TotalMinutes == -1;
}
