using NAudio.Wave;
using VoiceLabEcho.Core.Interfaces;
using VoiceLabEcho.Core.Models;

namespace VoiceLabEcho.Infrastructure.Audio;

public class AudioRecordingService : IAudioRecordingService
{
    private WaveInEvent? _waveIn;
    private WaveFileWriter? _waveFileWriter;
    private string? _outputPath;
    private DateTime _recordingStartTime;
    private System.Timers.Timer? _durationTimer;
    private const int MaxRecordingDurationSeconds = 600; // 10 minutes

    public bool IsRecording { get; private set; }

    public event EventHandler<AudioLevel>? AudioLevelChanged;
    public event EventHandler<TimeSpan>? RecordingDurationChanged;

    public Task<List<AudioDevice>> GetAvailableDevicesAsync()
    {
        var devices = new List<AudioDevice>();

        for (int i = 0; i < WaveInEvent.DeviceCount; i++)
        {
            var capabilities = WaveInEvent.GetCapabilities(i);
            devices.Add(new AudioDevice
            {
                Id = i.ToString(),
                Name = capabilities.ProductName,
                IsDefault = i == 0
            });
        }

        return Task.FromResult(devices);
    }

    public Task<bool> StartRecordingAsync(string deviceId, string outputPath)
    {
        if (IsRecording)
            return Task.FromResult(false);

        try
        {
            _outputPath = outputPath;
            var deviceNumber = int.Parse(deviceId);

            // Configure for 16kHz mono PCM
            _waveIn = new WaveInEvent
            {
                DeviceNumber = deviceNumber,
                WaveFormat = new WaveFormat(16000, 16, 1) // 16kHz, 16-bit, mono
            };

            _waveFileWriter = new WaveFileWriter(outputPath, _waveIn.WaveFormat);

            _waveIn.DataAvailable += OnDataAvailable;
            _waveIn.RecordingStopped += OnRecordingStopped;

            _waveIn.StartRecording();
            IsRecording = true;
            _recordingStartTime = DateTime.UtcNow;

            // Start duration timer
            _durationTimer = new System.Timers.Timer(100); // Update every 100ms
            _durationTimer.Elapsed += (s, e) =>
            {
                var duration = DateTime.UtcNow - _recordingStartTime;
                RecordingDurationChanged?.Invoke(this, duration);

                // Auto-stop after max duration
                if (duration.TotalSeconds >= MaxRecordingDurationSeconds)
                {
                    Task.Run(StopRecordingAsync);
                }
            };
            _durationTimer.Start();

            return Task.FromResult(true);
        }
        catch
        {
            Cleanup();
            return Task.FromResult(false);
        }
    }

    public async Task<Recording> StopRecordingAsync()
    {
        if (!IsRecording)
            throw new InvalidOperationException("Not currently recording");

        _waveIn?.StopRecording();

        // Wait for the recording to fully stop
        await Task.Delay(100);

        var duration = DateTime.UtcNow - _recordingStartTime;

        var recording = new Recording
        {
            CreatedAt = _recordingStartTime,
            Duration = duration,
            FilePath = _outputPath ?? string.Empty,
            Status = RecordingStatus.Completed
        };

        Cleanup();

        return recording;
    }

    public Task CancelRecordingAsync()
    {
        if (IsRecording)
        {
            _waveIn?.StopRecording();
            Cleanup();

            // Delete the recording file
            if (_outputPath != null && File.Exists(_outputPath))
            {
                try
                {
                    File.Delete(_outputPath);
                }
                catch
                {
                    // Ignore deletion errors
                }
            }
        }

        return Task.CompletedTask;
    }

    private void OnDataAvailable(object? sender, WaveInEventArgs e)
    {
        _waveFileWriter?.Write(e.Buffer, 0, e.BytesRecorded);

        // Calculate audio level for visualization
        var level = CalculateAudioLevel(e.Buffer, e.BytesRecorded);
        var frequencyBands = CalculateFrequencyBands(e.Buffer, e.BytesRecorded);

        AudioLevelChanged?.Invoke(this, new AudioLevel
        {
            Level = level,
            FrequencyBands = frequencyBands
        });
    }

    private void OnRecordingStopped(object? sender, StoppedEventArgs e)
    {
        if (e.Exception != null)
        {
            // Handle recording error
            System.Diagnostics.Debug.WriteLine($"Recording error: {e.Exception.Message}");
        }
    }

    private double CalculateAudioLevel(byte[] buffer, int bytesRecorded)
    {
        double sum = 0;
        int sampleCount = bytesRecorded / 2; // 16-bit samples

        for (int i = 0; i < bytesRecorded; i += 2)
        {
            if (i + 1 < bytesRecorded)
            {
                short sample = (short)((buffer[i + 1] << 8) | buffer[i]);
                double normalized = sample / 32768.0;
                sum += normalized * normalized;
            }
        }

        return sampleCount > 0 ? Math.Sqrt(sum / sampleCount) : 0;
    }

    private double[] CalculateFrequencyBands(byte[] buffer, int bytesRecorded)
    {
        // Simplified frequency band calculation
        // In production, you'd use FFT for proper spectrum analysis
        const int bandCount = 7;
        var bands = new double[bandCount];

        int samplesPerBand = (bytesRecorded / 2) / bandCount;

        for (int band = 0; band < bandCount; band++)
        {
            double sum = 0;
            int startSample = band * samplesPerBand * 2;
            int endSample = Math.Min(startSample + (samplesPerBand * 2), bytesRecorded);

            for (int i = startSample; i < endSample; i += 2)
            {
                if (i + 1 < bytesRecorded)
                {
                    short sample = (short)((buffer[i + 1] << 8) | buffer[i]);
                    double normalized = Math.Abs(sample / 32768.0);
                    sum += normalized;
                }
            }

            bands[band] = samplesPerBand > 0 ? sum / samplesPerBand : 0;
        }

        return bands;
    }

    private void Cleanup()
    {
        _durationTimer?.Stop();
        _durationTimer?.Dispose();
        _durationTimer = null;

        _waveFileWriter?.Dispose();
        _waveFileWriter = null;

        _waveIn?.Dispose();
        _waveIn = null;

        IsRecording = false;
        _outputPath = null;
    }
}
