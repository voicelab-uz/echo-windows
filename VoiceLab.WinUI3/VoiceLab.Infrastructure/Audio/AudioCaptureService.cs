using NAudio.Wave;
using NAudio.Wave.SampleProviders;

namespace VoiceLab.Infrastructure.Audio;

public interface IAudioCaptureService
{
    event EventHandler<AudioDataEventArgs>? AudioDataAvailable;
    event EventHandler? RecordingStopped;

    bool IsRecording { get; }
    void StartRecording();
    Task<byte[]> StopRecordingAsync();
    List<string> GetAvailableDevices();
    void SetDevice(int deviceIndex);
}

public class AudioDataEventArgs : EventArgs
{
    public byte[] Data { get; }
    public int BytesRecorded { get; }

    public AudioDataEventArgs(byte[] data, int bytesRecorded)
    {
        Data = data;
        BytesRecorded = bytesRecorded;
    }
}

public class AudioCaptureService : IAudioCaptureService
{
    private WaveInEvent? _waveIn;
    private MemoryStream? _audioStream;
    private bool _isRecording;
    private int _deviceIndex = 0;
    private TaskCompletionSource<bool>? _stoppedSource;
    private Exception? _recordingError;
    private int _captureSampleRate = 16000;

    public event EventHandler<AudioDataEventArgs>? AudioDataAvailable;
    public event EventHandler? RecordingStopped;

    public bool IsRecording => _isRecording;

    public List<string> GetAvailableDevices()
    {
        var devices = new List<string>();
        for (int i = 0; i < WaveInEvent.DeviceCount; i++)
        {
            var deviceInfo = WaveInEvent.GetCapabilities(i);
            devices.Add(deviceInfo.ProductName);
        }
        return devices;
    }

    public void SetDevice(int deviceIndex)
    {
        if (deviceIndex >= 0 && deviceIndex < WaveInEvent.DeviceCount)
        {
            _deviceIndex = deviceIndex;
        }
    }

    public void StartRecording()
    {
        if (_isRecording) return;
        if (WaveInEvent.DeviceCount == 0) throw new InvalidOperationException("No recording microphone is available.");
        _audioStream = new MemoryStream();
        _stoppedSource = new TaskCompletionSource<bool>(TaskCreationOptions.RunContinuationsAsynchronously);
        _recordingError = null;
        Exception? startError = null;
        foreach (var sampleRate in new[] { 16000, 48000, 44100, 32000 })
        {
            try
            {
                _waveIn = new WaveInEvent
                {
                    DeviceNumber = Math.Min(_deviceIndex, WaveInEvent.DeviceCount - 1),
                    WaveFormat = new WaveFormat(sampleRate, 16, 1)
                };
                _waveIn.DataAvailable += OnDataAvailable;
                _waveIn.RecordingStopped += OnRecordingStopped;
                _waveIn.StartRecording();
                _captureSampleRate = sampleRate;
                _isRecording = true;
                return;
            }
            catch (Exception ex)
            {
                startError = ex;
                _waveIn?.Dispose();
                _waveIn = null;
            }
        }
        _audioStream?.Dispose(); _audioStream = null;
        _stoppedSource = null;
        throw new InvalidOperationException("The selected microphone could not start recording.", startError);
    }

    public async Task<byte[]> StopRecordingAsync()
    {
        if (!_isRecording) return Array.Empty<byte>();

        try { _waveIn?.StopRecording(); }
        catch
        {
            _isRecording = false;
            _waveIn?.Dispose(); _waveIn = null;
            _audioStream?.Dispose(); _audioStream = null;
            _stoppedSource = null;
            throw;
        }
        _isRecording = false;
        Exception? stopError = null;
        if (_stoppedSource is not null)
            try { await _stoppedSource.Task.WaitAsync(TimeSpan.FromSeconds(3)); }
            catch (Exception ex) { stopError = ex; }

        var audioData = _audioStream?.ToArray() ?? Array.Empty<byte>();

        _audioStream?.Dispose();
        _audioStream = null;

        _waveIn?.Dispose();
        _waveIn = null;
        _stoppedSource = null;

        if (stopError is not null) throw new InvalidOperationException("The microphone did not finish recording cleanly.", stopError);
        if (_recordingError is not null) throw new InvalidOperationException("The microphone stopped unexpectedly.", _recordingError);

        if (_captureSampleRate == 16000) return audioData;
        using var input = new RawSourceWaveStream(new MemoryStream(audioData), new WaveFormat(_captureSampleRate, 16, 1));
        var resampler = new WdlResamplingSampleProvider(input.ToSampleProvider(), 16000);
        var outputProvider = new SampleToWaveProvider16(resampler);
        using var output = new MemoryStream();
        var buffer = new byte[8192];
        int bytesRead;
        while ((bytesRead = outputProvider.Read(buffer, 0, buffer.Length)) > 0)
            output.Write(buffer, 0, bytesRead);
        return output.ToArray();
    }

    private void OnDataAvailable(object? sender, WaveInEventArgs e)
    {
        _audioStream?.Write(e.Buffer, 0, e.BytesRecorded);
        AudioDataAvailable?.Invoke(this, new AudioDataEventArgs(e.Buffer, e.BytesRecorded));
    }

    private void OnRecordingStopped(object? sender, StoppedEventArgs e)
    {
        _recordingError = e.Exception;
        _stoppedSource?.TrySetResult(true);
        RecordingStopped?.Invoke(this, EventArgs.Empty);
    }
}
