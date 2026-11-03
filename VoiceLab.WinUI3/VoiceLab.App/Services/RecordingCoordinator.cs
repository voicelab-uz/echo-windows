using System.Runtime.InteropServices;
using Microsoft.UI.Xaml;
using Windows.ApplicationModel.DataTransfer;
using VoiceLab.Infrastructure.Audio;
using VoiceLab.Infrastructure.Hotkeys;
using VoiceLab.Infrastructure.Services;

namespace VoiceLab.App.Services;

public enum RecordingState { Idle, Recording, Transcribing, Error }

public sealed class RecordingStateChangedEventArgs(RecordingState state, string message) : EventArgs
{
    public RecordingState State { get; } = state;
    public string Message { get; } = message;
}

public interface IRecordingCoordinator
{
    event EventHandler<RecordingStateChangedEventArgs>? StateChanged;
    RecordingState State { get; }
    bool CanRetry { get; }
    Task ToggleAsync(IntPtr targetWindow, bool fromShortcut = false);
    Task RetryAsync();
    Task PasteLastTranscriptAsync(IntPtr targetWindow);
    Task CancelAsync();
}

public sealed class RecordingCoordinator : IRecordingCoordinator
{
    private readonly IAudioCaptureService _audio;
    private readonly ITranscriptionService _transcriptions;
    private readonly ISettingsService _settings;
    private readonly IAccountUsageSyncService _usageSync;
    private readonly IAuthenticationService _authentication;
    private readonly SemaphoreSlim _gate = new(1, 1);
    private DateTimeOffset _startedAt;
    private IntPtr _targetWindow;
    private CancellationTokenSource? _recordingLimit;
    private string? _lastTranscript;
    private string? _lastTranscriptOwner;
    private DateTimeOffset _lastTranscriptAt;
    private byte[]? _retryAudio;
    private string? _retryOwner;
    private string _retryLanguage = "auto";
    private bool _retrySaveHistory;
    private IntPtr _retryTarget;
    private CancellationTokenSource? _transcriptionCancellation;

    public RecordingCoordinator(IAudioCaptureService audio, ITranscriptionService transcriptions, ISettingsService settings,
        IAccountUsageSyncService usageSync, IAuthenticationService authentication)
    {
        _audio = audio;
        _transcriptions = transcriptions;
        _settings = settings;
        _usageSync = usageSync;
        _authentication = authentication;
        _audio.RecordingStopped += OnAudioRecordingStopped;
    }

    private void OnAudioRecordingStopped(object? sender, EventArgs e)
    {
        // NAudio can stop after device removal without a button press. The
        // normal stop path has already moved to Transcribing before this event.
        if (State != RecordingState.Recording || !_audio.IsRecording) return;
        App.MainWindow?.DispatcherQueue.TryEnqueue(async () =>
        {
            await _gate.WaitAsync();
            try
            {
                if (State != RecordingState.Recording || !_audio.IsRecording) return;
                CancelRecordingLimit();
                try { await _audio.StopRecordingAsync(); }
                catch (Exception ex) { System.Diagnostics.Debug.WriteLine($"Microphone cleanup failed: {ex}"); }
                _targetWindow = IntPtr.Zero;
                SetState(RecordingState.Error, "The microphone stopped unexpectedly. Check the device and try again.");
            }
            finally { _gate.Release(); }
        });
    }

    public event EventHandler<RecordingStateChangedEventArgs>? StateChanged;
    public RecordingState State { get; private set; } = RecordingState.Idle;
    public bool CanRetry => State == RecordingState.Error && _retryAudio is { Length: > 0 } &&
        !string.IsNullOrWhiteSpace(_retryOwner);

    public async Task ToggleAsync(IntPtr targetWindow, bool fromShortcut = false)
    {
        if (!await _gate.WaitAsync(0)) return;
        try
        {
            if (State == RecordingState.Recording)
                await StopAndTranscribeAsync(targetWindow);
            else if (State is RecordingState.Idle or RecordingState.Error)
                Start(targetWindow, fromShortcut);
        }
        finally { _gate.Release(); }
    }

    public async Task CancelAsync()
    {
        try { _transcriptionCancellation?.Cancel(); }
        catch (ObjectDisposedException) { }
        await _gate.WaitAsync();
        try
        {
            CancelRecordingLimit();
            if (_audio.IsRecording) await _audio.StopRecordingAsync();
            ClearRetryAudio();
            _targetWindow = IntPtr.Zero;
            SetState(RecordingState.Idle, "Recording cancelled.");
        }
        finally { _gate.Release(); }
    }

    public async Task RetryAsync()
    {
        if (!await _gate.WaitAsync(0)) return;
        try
        {
            if (!CanRetry) return;
            if (_retryOwner != (await _authentication.GetCurrentUserAsync())?.Id)
            {
                ClearRetryAudio();
                SetState(RecordingState.Error, "Sign in to the original account before retrying this recording.");
                return;
            }
            await SubmitPendingAudioAsync();
        }
        finally { _gate.Release(); }
    }

    public async Task PasteLastTranscriptAsync(IntPtr targetWindow)
    {
        if (!await _gate.WaitAsync(0)) return;
        try
        {
            if (State is RecordingState.Recording or RecordingState.Transcribing) return;
            var owner = (await _authentication.GetCurrentUserAsync())?.Id;
            var recent = (await _transcriptions.GetHistoryAsync())
                .OrderByDescending(item => item.CreatedAt).FirstOrDefault();
            var text = _lastTranscriptOwner == owner && !string.IsNullOrWhiteSpace(_lastTranscript)
                && (recent is null || _lastTranscriptAt >= recent.CreatedAt)
                ? _lastTranscript : recent?.Text;
            if (string.IsNullOrWhiteSpace(text))
            {
                SetState(RecordingState.Idle, "No previous transcript to paste.");
                return;
            }
            var pasted = await CopyAndPasteAsync(text, targetWindow, forcePaste: true);
            SetState(RecordingState.Idle, pasted ? "Last transcript inserted."
                : "Last transcript copied. Select a text field and paste it there.");
        }
        catch (Exception ex) { SetState(RecordingState.Error, $"Could not paste the last transcript: {ex.Message}"); }
        finally { _gate.Release(); }
    }

    private void Start(IntPtr targetWindow, bool fromShortcut)
    {
        try
        {
            ClearRetryAudio();
            _targetWindow = targetWindow;
            _startedAt = DateTimeOffset.UtcNow;
            _audio.StartRecording();
            var limit = new CancellationTokenSource();
            _recordingLimit = limit;
            _ = StopAtLimitAsync(limit);
            if (_settings.GetSetting("SoundFeedback", false)) MessageBeep(0x40);
            var shortcut = _settings.GetShortcutLabel();
            var mode = _settings.GetSetting("ActivationMode", "toggle");
            var releaseAvailable = (App.Services.GetService(typeof(IGlobalHotkeyService)) as IGlobalHotkeyService)?
                .IsReleaseTrackingAvailable == true;
            var instruction = fromShortcut && releaseAvailable ? mode switch
            {
                "hold" => $"release {shortcut} to finish",
                "automatic" => $"release to finish, or tap for hands-free dictation",
                _ => $"press {shortcut} again to finish"
            } : $"press {shortcut} again to finish";
            SetState(RecordingState.Recording, $"Recording — {instruction}.");
        }
        catch (Exception ex)
        {
            CancelRecordingLimit();
            SetState(RecordingState.Error, $"Microphone could not start: {ex.Message}");
        }
    }

    private async Task StopAtLimitAsync(CancellationTokenSource limit)
    {
        var token = limit.Token;
        try { await Task.Delay(TimeSpan.FromMinutes(10), token); }
        catch (OperationCanceledException) { return; }
        App.MainWindow?.DispatcherQueue.TryEnqueue(async () =>
        {
            if (token.IsCancellationRequested || !ReferenceEquals(_recordingLimit, limit)
                || State != RecordingState.Recording) return;
            await ToggleAsync(IntPtr.Zero);
        });
    }

    private void CancelRecordingLimit()
    {
        var limit = _recordingLimit;
        _recordingLimit = null;
        if (limit is null) return;
        limit.Cancel();
        limit.Dispose();
    }

    private void ClearRetryAudio()
    {
        if (_retryAudio is not null) Array.Clear(_retryAudio);
        _retryAudio = null;
        _retryOwner = null;
        _retryLanguage = "auto";
        _retrySaveHistory = false;
        _retryTarget = IntPtr.Zero;
    }

    private async Task StopAndTranscribeAsync(IntPtr stopWindow)
    {
        try
        {
            CancelRecordingLimit();
            SetState(RecordingState.Transcribing, "Transcribing your dictation…");
            var pcm = await _audio.StopRecordingAsync();
            if (_settings.GetSetting("SoundFeedback", false)) MessageBeep(0x40);
            if (pcm.Length < 3200)
            {
                SetState(RecordingState.Error, "The recording was too short. Speak for a moment, then try again.");
                return;
            }

            _retryAudio = pcm;
            _retryLanguage = _settings.GetSetting("PreferredLanguage", "auto");
            _retryTarget = ResolveTarget(stopWindow);
            _retrySaveHistory = _settings.GetSetting("RetainHistory", true);
            _retryOwner = (await _authentication.GetCurrentUserAsync())?.Id;
            await SubmitPendingAudioAsync();
        }
        catch (OperationCanceledException)
        {
            SetState(RecordingState.Idle, "Transcription cancelled.");
        }
        catch (Exception ex)
        {
            SetState(RecordingState.Error, ex.Message);
        }
    }

    private async Task SubmitPendingAudioAsync()
    {
        var pcm = _retryAudio;
        if (pcm is null || pcm.Length == 0) return;
        var owner = _retryOwner;
        var saveHistory = _retrySaveHistory;
        using var cancellation = new CancellationTokenSource();
        _transcriptionCancellation = cancellation;
        SetState(RecordingState.Transcribing, "Transcribing your dictation…");
        try
        {
            var record = await _transcriptions.TranscribeAudioRecordAsync(pcm, _retryLanguage, saveHistory, cancellation.Token);
            cancellation.Token.ThrowIfCancellationRequested();
            // The user may have moved to a different editor while STT was running.
            var current = GetForegroundWindow();
            var target = IsExternalWindow(current) ? current
                : IsExternalWindow(_retryTarget) ? _retryTarget : ResolveTarget(IntPtr.Zero);
            ClearRetryAudio();
            var text = record.Text;
            _lastTranscript = text;
            _lastTranscriptOwner = owner;
            _lastTranscriptAt = record.CreatedAt;
            try
            {
                var pasted = await CopyAndPasteAsync(text, target);
                if (pasted && owner is not null &&
                    owner == (await _authentication.GetCurrentUserAsync())?.Id &&
                    GetUsageContext(target) is { } usage)
                {
                    try
                    {
                        if (saveHistory) await _transcriptions.AttachUsageContextAsync(record.Id, usage, owner);
                        else await _usageSync.QueueAsync(record.Id, usage, owner);
                        _ = _usageSync.SyncAsync();
                    }
                    catch (Exception ex) { System.Diagnostics.Debug.WriteLine($"Could not save dictation usage: {ex}"); }
                }
                SetState(RecordingState.Idle, saveHistory
                    ? pasted ? "Transcription inserted and saved to History."
                        : "Saved to History and copied. Paste it where you want to use it."
                    : pasted ? "Transcription inserted. Device History saving is off."
                        : "Copied to clipboard. Device History saving is off.");
            }
            catch (Exception ex)
            {
                System.Diagnostics.Debug.WriteLine($"Transcript saved but delivery failed: {ex}");
                SetState(RecordingState.Idle, saveHistory
                    ? "Transcription saved to History. Automatic delivery failed; check the clipboard."
                    : "Automatic delivery failed. Check the clipboard; device History saving is off.");
            }
        }
        catch (OperationCanceledException)
        {
            SetState(RecordingState.Idle, "Transcription cancelled.");
        }
        catch (Exception ex)
        {
            SetState(RecordingState.Error, ex.Message);
        }
        finally
        {
            if (ReferenceEquals(_transcriptionCancellation, cancellation)) _transcriptionCancellation = null;
        }
    }

    private async Task<bool> CopyAndPasteAsync(string text, IntPtr targetWindow, bool forcePaste = false)
    {
        var package = new DataPackage();
        package.SetText(text);
        for (var attempt = 0; ; attempt++)
        {
            try { Clipboard.SetContent(package); Clipboard.Flush(); break; }
            catch when (attempt < 2) { await Task.Delay(75); }
        }

        if (!forcePaste && !_settings.GetSetting("AutoPaste", true)) return false;

        var appWindow = App.MainWindow is null ? IntPtr.Zero : WinRT.Interop.WindowNative.GetWindowHandle(App.MainWindow);
        if (targetWindow == IntPtr.Zero || targetWindow == appWindow || IsOwnWindow(targetWindow) || !IsWindow(targetWindow)) return false;
        SetForegroundWindow(targetWindow);
        await Task.Delay(100);
        // A short response can arrive before the dictation chord is released.
        // Do not send Ctrl+V or Unicode input while Win/Alt are still held.
        var releaseDeadline = Environment.TickCount64 + 1500;
        while (AreShortcutModifiersDown())
        {
            if (Environment.TickCount64 >= releaseDeadline) return false;
            await Task.Delay(25);
        }
        if (GetForegroundWindow() != targetWindow) return false;
        if (_settings.GetSetting("TextInsertionMethod", "paste") == "type")
            return await TypeTextAsync(text, targetWindow);
        var inputs = new[]
        {
            KeyInput(0x11, 0), KeyInput(0x56, 0), KeyInput(0x56, 2), KeyInput(0x11, 2)
        };
        return SendInput((uint)inputs.Length, inputs, GetNativeInputSize()) == inputs.Length;
    }

    private static bool AreShortcutModifiersDown() =>
        new[] { 0x10, 0x11, 0x12, 0x5B, 0x5C }.Any(key => (GetAsyncKeyState(key) & 0x8000) != 0);

    private static async Task<bool> TypeTextAsync(string text, IntPtr targetWindow)
    {
        // VK_PACKET handles the user's active keyboard layout and Unicode text.
        // Keep long transcripts on the clipboard instead of injecting thousands of keys.
        if (text.Length is 0 or > 20_000) return false;
        const int charactersPerBatch = 64;
        for (var offset = 0; offset < text.Length; offset += charactersPerBatch)
        {
            if (GetForegroundWindow() != targetWindow) return false;
            var count = Math.Min(charactersPerBatch, text.Length - offset);
            var inputs = new NativeInput[count * 2];
            for (var index = 0; index < count; index++)
            {
                var value = text[offset + index];
                inputs[index * 2] = UnicodeInput(value, keyUp: false);
                inputs[index * 2 + 1] = UnicodeInput(value, keyUp: true);
            }
            if (SendInput((uint)inputs.Length, inputs, GetNativeInputSize()) != inputs.Length)
                return false;
            await Task.Delay(2);
        }
        return true;
    }

    private void SetState(RecordingState state, string message)
    {
        State = state;
        StateChanged?.Invoke(this, new RecordingStateChangedEventArgs(state, message));
    }

    private static NativeInput KeyInput(ushort key, uint flags) => new()
    {
        Type = 1,
        Data = new NativeInputUnion { Keyboard = new NativeKeyboardInput { VirtualKey = key, Flags = flags } }
    };

    private static NativeInput UnicodeInput(char value, bool keyUp) => new()
    {
        Type = 1,
        Data = new NativeInputUnion { Keyboard = new NativeKeyboardInput
        {
            VirtualKey = 0, ScanCode = value, Flags = keyUp ? 0x0006u : 0x0004u
        } }
    };

    [DllImport("user32.dll")] private static extern bool IsWindow(IntPtr handle);
    [DllImport("user32.dll")] private static extern short GetAsyncKeyState(int key);
    [DllImport("user32.dll")] private static extern uint GetWindowThreadProcessId(IntPtr handle, out uint processId);

    private static bool IsOwnWindow(IntPtr handle)
    {
        if (handle == IntPtr.Zero || !IsWindow(handle)) return false;
        GetWindowThreadProcessId(handle, out var processId);
        return processId == Environment.ProcessId;
    }

    private IntPtr ResolveTarget(IntPtr stopWindow)
    {
        if (IsExternalWindow(stopWindow))
            return stopWindow;
        if (IsExternalWindow(_targetWindow))
            return _targetWindow;
        return IntPtr.Zero;
    }

    private static bool IsExternalWindow(IntPtr window) =>
        window != IntPtr.Zero && IsWindow(window) && !IsOwnWindow(window);

    private static DesktopUsageContext? GetUsageContext(IntPtr target)
    {
        if (target == IntPtr.Zero || IsOwnWindow(target) || !IsWindow(target)) return null;
        try
        {
            GetWindowThreadProcessId(target, out var processId);
            var processName = System.Diagnostics.Process.GetProcessById((int)processId).ProcessName;
            var normalized = processName.ToLowerInvariant();
            var category = normalized switch
            {
                "telegram" or "whatsapp" or "discord" or "signal" => "personal",
                "slack" or "teams" or "msteams" => "work",
                "outlook" or "thunderbird" or "hxoutlook" => "email",
                "chatgpt" or "claude" or "perplexity" => "ai",
                "winword" or "notepad" or "onenote" or "obsidian" or "notion" or "code" => "documents",
                _ => "other"
            };
            return new DesktopUsageContext("win:" + normalized[..Math.Min(normalized.Length, 180)],
                processName[..Math.Min(processName.Length, 80)], category);
        }
        catch { return null; }
    }
    [DllImport("user32.dll")] private static extern bool MessageBeep(uint type);
    [DllImport("user32.dll")] private static extern bool SetForegroundWindow(IntPtr handle);
    [DllImport("user32.dll")] private static extern IntPtr GetForegroundWindow();
    [DllImport("user32.dll", SetLastError = true)] private static extern uint SendInput(uint count, NativeInput[] inputs, int size);

    private static int GetNativeInputSize()
    {
        var size = Marshal.SizeOf<NativeInput>();
        var expected = IntPtr.Size == 8 ? 40 : 28;
        if (size != expected)
            throw new InvalidOperationException($"Windows input layout is invalid ({size} bytes; expected {expected}).");
        return size;
    }

    [StructLayout(LayoutKind.Sequential)]
    private struct NativeInput { public uint Type; public NativeInputUnion Data; }
    [StructLayout(LayoutKind.Explicit)]
    private struct NativeInputUnion
    {
        [FieldOffset(0)] public NativeKeyboardInput Keyboard;
        [FieldOffset(0)] public NativeMouseInput Mouse;
    }
    [StructLayout(LayoutKind.Sequential)]
    private struct NativeKeyboardInput { public ushort VirtualKey; public ushort ScanCode; public uint Flags; public uint Time; public IntPtr ExtraInfo; }
    // INPUT's union is sized by MOUSEINPUT even when we send only KEYBDINPUT.
    [StructLayout(LayoutKind.Sequential)]
    private struct NativeMouseInput
    {
        public int X;
        public int Y;
        public uint MouseData;
        public uint Flags;
        public uint Time;
        public IntPtr ExtraInfo;
    }
}
