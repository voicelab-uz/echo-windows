using VoiceLabEcho.Core.Models;

namespace VoiceLabEcho.Core.Interfaces;

public interface IAudioRecordingService
{
    Task<List<AudioDevice>> GetAvailableDevicesAsync();
    Task<bool> StartRecordingAsync(string deviceId, string outputPath);
    Task<Recording> StopRecordingAsync();
    Task CancelRecordingAsync();
    bool IsRecording { get; }
    event EventHandler<AudioLevel>? AudioLevelChanged;
    event EventHandler<TimeSpan>? RecordingDurationChanged;
}

public class AudioDevice
{
    public string Id { get; set; } = string.Empty;
    public string Name { get; set; } = string.Empty;
    public bool IsDefault { get; set; }
}

public class AudioLevel
{
    public double Level { get; set; }
    public double[] FrequencyBands { get; set; } = Array.Empty<double>();
}
