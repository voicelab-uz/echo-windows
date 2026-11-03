namespace VoiceLab.Infrastructure.Services;

public sealed record StatisticsDay(DateOnly Day, int Words, int Recordings, int DurationMs, string? Platform = null);

/// <summary>Six months of dictation activity, calculated from account or local history.</summary>
public sealed class StatisticsMetrics
{
    public IReadOnlyList<StatisticsDay> Days { get; private init; } = [];
    public int Words { get; private init; }
    public int Recordings { get; private init; }
    public int DurationMs { get; private init; }
    public int ActiveDays { get; private init; }
    public int CurrentStreak { get; private init; }
    public int LongestStreak { get; private init; }
    public int TodayWords => Days.Count == 0 ? 0 : Days[^1].Words;
    public int TodayRecordings => Days.Count == 0 ? 0 : Days[^1].Recordings;
    public int AverageLength => Recordings == 0 ? 0 : (int)Math.Round(Words / (double)Recordings);
    public double? WordsPerMinute => DurationMs > 0 ? Words * 60_000d / DurationMs : null;

    public double SecondsSaved(int typingWordsPerMinute) =>
        Math.Max(0, Words * 60d / Math.Clamp(typingWordsPerMinute, 10, 200) - DurationMs / 1000d);

    public static StatisticsMetrics FromLocalHistory(IEnumerable<Transcription> history, DateOnly? today = null)
    {
        var rows = history.Where(item => !string.IsNullOrWhiteSpace(item.Id))
            .GroupBy(item => item.Id, StringComparer.Ordinal)
            .Select(group => group.First())
            .Select(item => new StatisticsDay(DateOnly.FromDateTime(item.CreatedAt.LocalDateTime),
                TranscriptionService.CountWords(item.Text), 1, Math.Max(0, item.AudioDurationMs)));
        return FromRows(rows, today);
    }

    public static StatisticsMetrics FromRows(IEnumerable<StatisticsDay> source, DateOnly? today = null)
    {
        var lastDay = today ?? DateOnly.FromDateTime(DateTime.Today);
        var firstDay = lastDay.AddDays(-181);
        var grouped = source.Where(row => row.Day >= firstDay && row.Day <= lastDay &&
                row.Words >= 0 && row.Recordings >= 0 && row.DurationMs >= 0)
            .GroupBy(row => row.Day)
            .ToDictionary(group => group.Key, group => new StatisticsDay(group.Key,
                group.Sum(row => row.Words), group.Sum(row => row.Recordings), group.Sum(row => row.DurationMs)));
        var days = Enumerable.Range(0, 182).Select(index =>
        {
            var day = firstDay.AddDays(index);
            return grouped.GetValueOrDefault(day) ?? new StatisticsDay(day, 0, 0, 0);
        }).ToArray();
        var running = 0;
        var longest = 0;
        foreach (var day in days)
        {
            running = day.Recordings > 0 ? running + 1 : 0;
            longest = Math.Max(longest, running);
        }
        var current = 0;
        for (var index = days.Length - (days[^1].Recordings == 0 ? 2 : 1); index >= 0 && days[index].Recordings > 0; index--)
            current++;
        return new StatisticsMetrics
        {
            Days = days,
            Words = days.Sum(day => day.Words),
            Recordings = days.Sum(day => day.Recordings),
            DurationMs = days.Sum(day => day.DurationMs),
            ActiveDays = days.Count(day => day.Recordings > 0),
            CurrentStreak = current,
            LongestStreak = longest
        };
    }
}
