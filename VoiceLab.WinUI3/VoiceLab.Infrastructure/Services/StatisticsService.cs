namespace VoiceLab.Infrastructure.Services;

public interface IStatisticsService
{
    Task<UsageStats> GetStatsAsync();
}

public sealed class StatisticsService(ITranscriptionService transcriptionService, ISettingsService settings) : IStatisticsService
{
    public async Task<UsageStats> GetStatsAsync()
    {
        var items = await transcriptionService.GetHistoryAsync().ConfigureAwait(false);
        var metrics = StatisticsMetrics.FromLocalHistory(items);
        var typingSpeed = settings.GetSetting("TypingWordsPerMinute", 40);
        return new UsageStats { TotalTranscriptions = metrics.Recordings, TotalWords = metrics.Words,
            HoursSaved = metrics.SecondsSaved(typingSpeed) / 3600d, AccuracyPercent = 0 };
    }
}
