using Microsoft.UI.Xaml.Hosting;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Composition;
using System.Numerics;
using VoiceLab.Infrastructure.Audio;
using Microsoft.Extensions.DependencyInjection;
using NAudio.Wave;

namespace VoiceLab.App.Views.Onboarding;

public sealed partial class MicTestStepPage : Page
{
    private Compositor _compositor;
    private bool _isRecording = false;
    private readonly IAudioCaptureService _audio = App.Services.GetRequiredService<IAudioCaptureService>();
    private byte[] _samplePcm = [];
    private bool _speechDetected;
    private int _speechFrames;
    private WaveOutEvent? _playback;
    private RawSourceWaveStream? _playbackStream;

    public MicTestStepPage()
    {
        this.InitializeComponent();
        _compositor = ElementCompositionPreview.GetElementVisual(this).Compositor;
        _audio.AudioDataAvailable += OnAudioDataAvailable;
        _audio.RecordingStopped += OnRecordingStopped;
        Unloaded += OnUnloaded;
    }

    private void OnRecordingStopped(object? sender, EventArgs e)
    {
        DispatcherQueue.TryEnqueue(async () =>
        {
            // A normal button stop marks the page idle before NAudio raises this event.
            if (!_isRecording) return;
            _isRecording = false;
            TestButton.IsEnabled = false;
            StatusText.Text = "The microphone stopped unexpectedly. Check the device and try again.";
            StatusText.Foreground = new Microsoft.UI.Xaml.Media.SolidColorBrush(
                Windows.UI.Color.FromArgb(255, 239, 68, 68));
            try { if (_audio.IsRecording) await _audio.StopRecordingAsync(); }
            catch (Exception ex) { StatusText.Text = $"Microphone stopped unexpectedly: {ex.Message}"; }
            finally
            {
                _samplePcm = [];
                PlaybackButton.IsEnabled = false;
                ContinueButton.IsEnabled = false;
                TestButton.Content = "Test Microphone";
                TestButton.IsEnabled = true;
            }
        });
    }

    private async void OnTestClick(object sender, RoutedEventArgs e)
    {
        if (!_isRecording)
        {
            try
            {
                _audio.StartRecording();
                StatusText.Foreground = (Microsoft.UI.Xaml.Media.Brush)Application.Current.Resources["OnbInkMutedBrush"];
                _samplePcm = [];
                _speechDetected = false;
                _speechFrames = 0;
                PlaybackButton.IsEnabled = false;
                ContinueButton.IsEnabled = false;
                _isRecording = true;
                TestButton.Content = "Stop Test";
                StatusText.Text = "Speak into your microphone...";
            }
            catch (Exception ex) { StatusText.Text = $"Microphone unavailable: {ex.Message}"; }
        }
        else
        {
            _isRecording = false;
            try
            {
                _samplePcm = await _audio.StopRecordingAsync();
                PlaybackButton.IsEnabled = _samplePcm.Length >= 3200;
                ContinueButton.IsEnabled = PlaybackButton.IsEnabled && _speechDetected;
                StatusText.Text = ContinueButton.IsEnabled
                    ? "Speech detected. You can play your sample or continue."
                    : PlaybackButton.IsEnabled
                        ? "We heard the microphone, but not sustained speech. Speak clearly and try again."
                        : "Recording was too short. Speak for a moment and try again.";
                if (ContinueButton.IsEnabled) StatusText.Foreground = new Microsoft.UI.Xaml.Media.SolidColorBrush(
                    Windows.UI.Color.FromArgb(255, 16, 185, 129));
            }
            catch (Exception ex) { StatusText.Text = $"Microphone stopped unexpectedly: {ex.Message}"; }
            finally { TestButton.Content = "Test Microphone"; }
        }
    }

    private void OnPlaybackClick(object sender, RoutedEventArgs e)
    {
        if (_samplePcm.Length == 0) return;
        try
        {
            _playback?.Stop();
            _playback?.Dispose();
            _playbackStream?.Dispose();
            _playbackStream = new RawSourceWaveStream(new MemoryStream(_samplePcm), new WaveFormat(16000, 16, 1));
            _playback = new WaveOutEvent();
            _playback.Init(_playbackStream);
            _playback.Play();
            StatusText.Text = "Playing your microphone sample.";
        }
        catch (Exception ex)
        {
            _playback?.Dispose(); _playback = null;
            _playbackStream?.Dispose(); _playbackStream = null;
            StatusText.Text = $"Playback unavailable: {ex.Message}";
        }
    }

    private void OnAudioDataAvailable(object? sender, AudioDataEventArgs e)
    {
        if (!_isRecording || e.BytesRecorded < 2) return;
        double sum = 0;
        for (var i = 0; i + 1 < e.BytesRecorded; i += 2)
        {
            var sample = BitConverter.ToInt16(e.Data, i) / 32768d;
            sum += sample * sample;
        }
        var rms = Math.Sqrt(sum / Math.Max(1, e.BytesRecorded / 2));
        _speechFrames = rms > .003 ? _speechFrames + 1 : 0;
        if (_speechFrames >= 3) _speechDetected = true;
        var level = Math.Clamp(rms * 9, .02, 1);
        DispatcherQueue.TryEnqueue(() =>
        {
            AnimateBar(Bar1, level * .65); AnimateBar(Bar2, level * .85); AnimateBar(Bar3, level);
            AnimateBar(Bar4, level * .8); AnimateBar(Bar5, level * .6);
        });
    }

    private void AnimateBar(Microsoft.UI.Xaml.Shapes.Rectangle bar, double level)
    {
        var visual = ElementCompositionPreview.GetElementVisual(bar);
        var targetScale = 0.35 + (level * 0.65); // 0.35 to 1.0

        var scaleAnimation = _compositor.CreateVector3KeyFrameAnimation();
        scaleAnimation.InsertKeyFrame(1.0f, new Vector3(1.0f, (float)targetScale, 1.0f));
        scaleAnimation.Duration = TimeSpan.FromMilliseconds(100);

        visual.CenterPoint = new Vector3((float)bar.ActualWidth / 2, (float)bar.ActualHeight, 0);
        visual.StartAnimation("Scale", scaleAnimation);
    }

    private void ResetBar(Microsoft.UI.Xaml.Shapes.Rectangle bar)
    {
        var visual = ElementCompositionPreview.GetElementVisual(bar);
        var scaleAnimation = _compositor.CreateVector3KeyFrameAnimation();
        scaleAnimation.InsertKeyFrame(1.0f, new Vector3(1.0f, 0.35f, 1.0f));
        scaleAnimation.Duration = TimeSpan.FromMilliseconds(300);

        visual.CenterPoint = new Vector3((float)bar.ActualWidth / 2, (float)bar.ActualHeight, 0);
        visual.StartAnimation("Scale", scaleAnimation);
    }

    private async void OnNextClick(object sender, RoutedEventArgs e)
    {
        if (!ContinueButton.IsEnabled) return;
        _isRecording = false;
        try
        {
            if (_audio.IsRecording) await _audio.StopRecordingAsync();
        }
        catch (Exception ex)
        {
            StatusText.Text = $"Microphone could not stop: {ex.Message}";
            return;
        }
        Frame.Navigate(typeof(ShortcutStepPage));
    }

    private async void OnUnloaded(object sender, RoutedEventArgs e)
    {
        _audio.AudioDataAvailable -= OnAudioDataAvailable;
        _audio.RecordingStopped -= OnRecordingStopped;
        try { _playback?.Stop(); _playback?.Dispose(); _playbackStream?.Dispose(); }
        catch { /* Playback cleanup must not interrupt navigation. */ }
        if (!_isRecording) return;
        _isRecording = false;
        try { if (_audio.IsRecording) await _audio.StopRecordingAsync(); }
        catch { /* The next microphone attempt will report a device error. */ }
    }
}
