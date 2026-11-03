using System.Runtime.InteropServices;
using Microsoft.UI.Windowing;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Media;
using Microsoft.UI.Xaml.Shapes;
using Microsoft.UI.Xaml.Input;
using Microsoft.UI.Xaml.Media.Imaging;
using VoiceLab.Infrastructure.Audio;

namespace VoiceLab.App.Services;

public interface IRecordingOverlayService : IDisposable
{
    void Attach();
    void ApplyTheme(ElementTheme theme);
}

public sealed class RecordingOverlayService(IRecordingCoordinator recording, IAudioCaptureService audio) : IRecordingOverlayService
{
    private Window? _window;
    private TextBlock? _statusText;
    private TextBlock? _elapsedText;
    private readonly Rectangle[] _waveBars = new Rectangle[7];
    private Button? _toggleButton;
    private Image? _toggleIcon;
    private Image? _settingsIcon;
    private RecordingState _displayState = RecordingState.Idle;
    private DispatcherTimer? _timer;
    private DateTimeOffset _startedAt;
    private double _level;
    private bool _attached;
    private bool _dismissed;
    private IntPtr _lastTargetWindow;
    private SubclassProcedure? _subclassProcedure;
    private SolidColorBrush? _backgroundBrush;
    private SolidColorBrush? _foregroundBrush;
    private SolidColorBrush? _accentBrush;
    private SolidColorBrush? _borderBrush;

    public void Attach()
    {
        if (_attached) return;
        _attached = true;
        recording.StateChanged += OnStateChanged;
        audio.AudioDataAvailable += OnAudioDataAvailable;
    }

    private void OnStateChanged(object? sender, RecordingStateChangedEventArgs e)
    {
        var dispatcher = App.MainWindow?.DispatcherQueue;
        dispatcher?.TryEnqueue(() => UpdateState(e));
    }

    private void UpdateState(RecordingStateChangedEventArgs e)
    {
        if (!_attached) return;
        try
        {
            if (_dismissed && e.State == RecordingState.Idle) return;
            _dismissed = false;
            EnsureWindow();
            _displayState = e.State;
            ApplyTheme((App.MainWindow?.Content as FrameworkElement)?.ActualTheme ?? ElementTheme.Light);
            if (_statusText is null || _elapsedText is null || _toggleButton is null) return;
            _statusText.Text = e.State switch
            {
                RecordingState.Recording => "Recording",
                RecordingState.Transcribing => "Working",
                RecordingState.Error => "Error",
                _ when e.Message.Contains("inserted", StringComparison.OrdinalIgnoreCase) => "Inserted",
                _ when e.Message.Contains("copied", StringComparison.OrdinalIgnoreCase) => "Copied",
                _ => e.Message.Contains("History", StringComparison.OrdinalIgnoreCase) ? "Saved" : "Ready"
            };
            ToolTipService.SetToolTip(_statusText, e.Message);
            Microsoft.UI.Xaml.Automation.AutomationProperties.SetName(_toggleButton,
                e.State == RecordingState.Recording ? "Stop dictation" : "Start dictation");
            _toggleButton.IsEnabled = e.State != RecordingState.Transcribing;
            if (e.State == RecordingState.Recording)
            {
                _startedAt = DateTimeOffset.UtcNow;
                _elapsedText.Text = "00:00";
                _timer?.Start();
            }
            else
            {
                _timer?.Stop();
                _level = 0;
                foreach (var bar in _waveBars) bar.Height = 5;
                if (e.State is RecordingState.Error or RecordingState.Idle)
                    _elapsedText.Text = e.State == RecordingState.Error ? "Open Settings"
                        : e.Message.StartsWith("Transcription inserted", StringComparison.Ordinal) ? "Pasted"
                        : e.Message.StartsWith("Last transcript inserted", StringComparison.Ordinal) ? "Pasted"
                        : e.Message.Contains("copied", StringComparison.OrdinalIgnoreCase) ? "Clipboard"
                        : e.Message.Contains("History", StringComparison.OrdinalIgnoreCase) ? "History" : "";
            }
            Show();
        }
        catch (Exception ex) { System.Diagnostics.Debug.WriteLine($"Recording overlay unavailable: {ex.Message}"); }
    }

    private void OnAudioDataAvailable(object? sender, AudioDataEventArgs e)
    {
        if (recording.State != RecordingState.Recording || e.BytesRecorded < 2) return;
        double sum = 0;
        for (var i = 0; i + 1 < e.BytesRecorded; i += 2)
        {
            var sample = BitConverter.ToInt16(e.Data, i) / 32768d;
            sum += sample * sample;
        }
        var level = Math.Clamp(Math.Sqrt(sum / (e.BytesRecorded / 2d)) * 3.5, 0, 1);
        App.MainWindow?.DispatcherQueue.TryEnqueue(() => _level = Math.Max(_level, level));
    }

    private void EnsureWindow()
    {
        if (_window is not null) return;
        _window = new Window { Title = "Echo recording" };
        var background = _backgroundBrush = new SolidColorBrush(Windows.UI.Color.FromArgb(255, 245, 244, 240));
        var foreground = _foregroundBrush = new SolidColorBrush(Windows.UI.Color.FromArgb(255, 26, 26, 26));
        var accent = _accentBrush = new SolidColorBrush(App.GetAccentColor(false));
        var border = _borderBrush = new SolidColorBrush(Windows.UI.Color.FromArgb(255, 226, 225, 221));
        var content = new Grid { RowSpacing = 2 };
        content.RowDefinitions.Add(new RowDefinition { Height = new GridLength(19) });
        content.RowDefinitions.Add(new RowDefinition { Height = new GridLength(25) });
        content.RowDefinitions.Add(new RowDefinition { Height = new GridLength(43) });
        content.RowDefinitions.Add(new RowDefinition { Height = new GridLength(17) });
        var header = new Grid();
        var grip = new Border { Background = new SolidColorBrush(Windows.UI.Color.FromArgb(255, 126, 135, 145)),
            Width = 31, Height = 3, CornerRadius = new CornerRadius(2), HorizontalAlignment = HorizontalAlignment.Center,
            VerticalAlignment = VerticalAlignment.Top, Margin = new Thickness(0, 4, 0, 0) };
        grip.PointerPressed += (_, _) =>
        {
            var handle = WinRT.Interop.WindowNative.GetWindowHandle(_window);
            ReleaseCapture();
            SendMessage(handle, 0x00A1, new IntPtr(2), IntPtr.Zero);
        };
        header.Children.Add(grip);
        var closeButton = new Button { Content = "×", Width = 23, Height = 23, Padding = new Thickness(0),
            HorizontalAlignment = HorizontalAlignment.Right, VerticalAlignment = VerticalAlignment.Top,
            Background = new SolidColorBrush(Windows.UI.Color.FromArgb(0, 0, 0, 0)), BorderThickness = new Thickness(0),
            Foreground = foreground, FontSize = 16 };
        Microsoft.UI.Xaml.Automation.AutomationProperties.SetName(closeButton, "Dismiss floating dictation control");
        closeButton.Click += async (_, _) => await DismissAsync();
        header.Children.Add(closeButton);
        content.Children.Add(header);

        var waveform = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 3,
            HorizontalAlignment = HorizontalAlignment.Center, VerticalAlignment = VerticalAlignment.Center };
        for (var i = 0; i < _waveBars.Length; i++)
        {
            _waveBars[i] = new Rectangle { Width = 3, Height = 5, RadiusX = 2, RadiusY = 2, Fill = accent,
                VerticalAlignment = VerticalAlignment.Center };
            waveform.Children.Add(_waveBars[i]);
        }
        Grid.SetRow(waveform, 1); content.Children.Add(waveform);

        var controls = new Grid();
        controls.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
        controls.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        controls.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
        _settingsIcon = new Image { Width = 17, Height = 17 };
        var settingsButton = new Button { Content = _settingsIcon,
            Width = 31, Height = 31, Padding = new Thickness(0), HorizontalAlignment = HorizontalAlignment.Center,
            VerticalAlignment = VerticalAlignment.Center, Background = new SolidColorBrush(Windows.UI.Color.FromArgb(0, 0, 0, 0)),
            BorderThickness = new Thickness(0), Foreground = foreground };
        Microsoft.UI.Xaml.Automation.AutomationProperties.SetName(settingsButton, "Open VoiceLab Echo settings");
        settingsButton.Click += (_, _) =>
        {
            App.MainWindow?.Activate();
            if (App.MainWindow?.Content is VoiceLab.App.Views.ShellPage shell) shell.NavigateToSettings();
        };
        controls.Children.Add(settingsButton);
        _toggleIcon = new Image { Width = 20, Height = 20 };
        _toggleButton = new Button { Content = _toggleIcon, Width = 43, Height = 43,
            Padding = new Thickness(0), CornerRadius = new CornerRadius(22), Background = background, Foreground = foreground,
            BorderBrush = border, BorderThickness = new Thickness(1) };
        Microsoft.UI.Xaml.Automation.AutomationProperties.SetName(_toggleButton, "Start dictation");
        _toggleButton.Click += async (_, _) =>
        {
            var current = GetForegroundWindow();
            var target = IsExternalWindow(current) ? current
                : IsExternalWindow(_lastTargetWindow) ? _lastTargetWindow : IntPtr.Zero;
            await recording.ToggleAsync(target);
        };
        Grid.SetColumn(_toggleButton, 1); controls.Children.Add(_toggleButton);
        Grid.SetRow(controls, 2); content.Children.Add(controls);

        var status = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 4,
            HorizontalAlignment = HorizontalAlignment.Center, VerticalAlignment = VerticalAlignment.Center };
        _statusText = new TextBlock { Text = "Ready", Foreground = foreground,
            FontSize = 10, VerticalAlignment = VerticalAlignment.Center };
        _elapsedText = new TextBlock { Text = "", Foreground = foreground,
            FontSize = 10, VerticalAlignment = VerticalAlignment.Center, MaxWidth = 100,
            TextTrimming = TextTrimming.CharacterEllipsis };
        status.Children.Add(_statusText); status.Children.Add(_elapsedText);
        Grid.SetRow(status, 3); content.Children.Add(status);
        var root = new Border { Background = background, BorderBrush = border,
            BorderThickness = new Thickness(1), CornerRadius = new CornerRadius(13), Padding = new Thickness(8, 4, 8, 4), Child = content };
        root.KeyDown += async (_, e) => { if (e.Key == Windows.System.VirtualKey.Escape) { e.Handled = true; await DismissAsync(); } };
        var escape = new KeyboardAccelerator { Key = Windows.System.VirtualKey.Escape };
        escape.Invoked += async (_, e) => { e.Handled = true; await DismissAsync(); };
        root.KeyboardAccelerators.Add(escape);
        _window.Content = root;
        ApplyTheme((App.MainWindow?.Content as FrameworkElement)?.ActualTheme ?? ElementTheme.Light);
        var appWindow = _window.AppWindow;
        appWindow.Resize(new Windows.Graphics.SizeInt32(172, 118));
        var area = DisplayArea.GetFromWindowId(appWindow.Id, DisplayAreaFallback.Primary).WorkArea;
        appWindow.Move(new Windows.Graphics.PointInt32(area.X + (area.Width - 172) / 2, area.Y + area.Height - 144));
        if (appWindow.Presenter is OverlappedPresenter presenter)
        {
            presenter.SetBorderAndTitleBar(false, false);
            presenter.IsAlwaysOnTop = true;
            presenter.IsResizable = false;
            presenter.IsMaximizable = false;
            presenter.IsMinimizable = false;
        }
        var handle = WinRT.Interop.WindowNative.GetWindowHandle(_window);
        SetWindowLongPtr(handle, -20, new IntPtr(GetWindowLongPtr(handle, -20).ToInt64() | 0x00000080));
        _subclassProcedure = OverlaySubclassProc;
        SetWindowSubclass(handle, _subclassProcedure, new UIntPtr(9001), IntPtr.Zero);
        _timer = new DispatcherTimer { Interval = TimeSpan.FromMilliseconds(100) };
        _timer.Tick += (_, _) =>
        {
            var foreground = GetForegroundWindow();
            if (IsExternalWindow(foreground)) _lastTargetWindow = foreground;
            if (_elapsedText is not null) _elapsedText.Text = (DateTimeOffset.UtcNow - _startedAt).ToString(@"mm\:ss");
            for (var i = 0; i < _waveBars.Length; i++)
                _waveBars[i].Height = 5 + _level * (i is 2 or 4 ? 18 : i == 3 ? 23 : 12);
            _level *= .7;
        };
    }

    public void ApplyTheme(ElementTheme theme)
    {
        if (_window?.Content is FrameworkElement content) content.RequestedTheme = theme;
        var dark = theme == ElementTheme.Dark;
        if (_backgroundBrush is not null) _backgroundBrush.Color = dark
            ? Windows.UI.Color.FromArgb(255, 32, 32, 32) : Windows.UI.Color.FromArgb(255, 245, 244, 240);
        if (_foregroundBrush is not null) _foregroundBrush.Color = dark
            ? Windows.UI.Color.FromArgb(255, 233, 232, 225) : Windows.UI.Color.FromArgb(255, 26, 26, 26);
        if (_borderBrush is not null) _borderBrush.Color = dark
            ? Windows.UI.Color.FromArgb(255, 59, 59, 58) : Windows.UI.Color.FromArgb(255, 226, 225, 221);
        if (_accentBrush is not null) _accentBrush.Color = App.GetAccentColor(dark);
        var variant = dark ? ".dark.svg" : ".svg";
        if (_settingsIcon is not null)
            _settingsIcon.Source = new SvgImageSource(new Uri("ms-appx:///Assets/icons/settings" + variant));
        if (_toggleIcon is not null)
            _toggleIcon.Source = new SvgImageSource(new Uri("ms-appx:///Assets/icons/" +
                (_displayState == RecordingState.Recording ? "pause" : "mic") + variant));
    }

    private async Task DismissAsync()
    {
        _dismissed = true;
        if (recording.State == RecordingState.Recording) await recording.CancelAsync();
        Hide();
    }

    private IntPtr OverlaySubclassProc(IntPtr window, uint message, IntPtr wParam, IntPtr lParam,
        UIntPtr subclassId, IntPtr referenceData)
    {
        if (message == 0x0100 && wParam.ToInt32() == 27)
        {
            App.MainWindow?.DispatcherQueue.TryEnqueue(async () => await DismissAsync());
            return IntPtr.Zero;
        }
        return DefSubclassProc(window, message, wParam, lParam);
    }

    private void Show()
    {
        if (_window is null) return;
        var handle = WinRT.Interop.WindowNative.GetWindowHandle(_window);
        var foreground = GetForegroundWindow();
        if (IsExternalWindow(foreground)) _lastTargetWindow = foreground;
        ShowWindow(handle, 8);
        SetWindowPos(handle, new IntPtr(-1), 0, 0, 0, 0, 0x0001 | 0x0002 | 0x0010);
    }

    private void Hide()
    {
        if (_window is not null) ShowWindow(WinRT.Interop.WindowNative.GetWindowHandle(_window), 0);
    }

    private static bool IsExternalWindow(IntPtr window)
    {
        if (window == IntPtr.Zero || !IsWindow(window)) return false;
        GetWindowThreadProcessId(window, out var processId);
        return processId != Environment.ProcessId;
    }

    public void Dispose()
    {
        if (!_attached) return;
        _attached = false;
        recording.StateChanged -= OnStateChanged;
        audio.AudioDataAvailable -= OnAudioDataAvailable;
        _timer?.Stop();
        Hide();
        if (_window is not null && _subclassProcedure is not null)
            RemoveWindowSubclass(WinRT.Interop.WindowNative.GetWindowHandle(_window), _subclassProcedure, new UIntPtr(9001));
        _window?.Close();
        _window = null;
        _lastTargetWindow = IntPtr.Zero;
        _dismissed = false;
        _level = 0;
    }

    [DllImport("user32.dll")] private static extern bool ShowWindow(IntPtr window, int command);
    [DllImport("user32.dll")] private static extern IntPtr GetForegroundWindow();
    [DllImport("user32.dll")] private static extern bool IsWindow(IntPtr window);
    [DllImport("user32.dll")] private static extern uint GetWindowThreadProcessId(IntPtr window, out uint processId);
    [DllImport("user32.dll")] private static extern bool ReleaseCapture();
    [DllImport("user32.dll")] private static extern IntPtr SendMessage(IntPtr window, uint message, IntPtr wParam, IntPtr lParam);
    [DllImport("user32.dll")] private static extern bool SetWindowPos(IntPtr window, IntPtr insertAfter, int x, int y, int width, int height, uint flags);
    [DllImport("user32.dll", EntryPoint = "GetWindowLongPtrW")] private static extern IntPtr GetWindowLongPtr(IntPtr window, int index);
    [DllImport("user32.dll", EntryPoint = "SetWindowLongPtrW")] private static extern IntPtr SetWindowLongPtr(IntPtr window, int index, IntPtr value);
    [DllImport("comctl32.dll")] private static extern bool SetWindowSubclass(IntPtr window, SubclassProcedure callback, UIntPtr subclassId, IntPtr data);
    [DllImport("comctl32.dll")] private static extern bool RemoveWindowSubclass(IntPtr window, SubclassProcedure callback, UIntPtr subclassId);
    [DllImport("comctl32.dll")] private static extern IntPtr DefSubclassProc(IntPtr window, uint message, IntPtr wParam, IntPtr lParam);
    private delegate IntPtr SubclassProcedure(IntPtr window, uint message, IntPtr wParam, IntPtr lParam, UIntPtr subclassId, IntPtr data);
}
