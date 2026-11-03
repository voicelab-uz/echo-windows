using System.ComponentModel;
using System.Runtime.InteropServices;

namespace VoiceLab.Infrastructure.Hotkeys;

public interface IGlobalHotkeyService : IDisposable
{
    event EventHandler? HotkeyPressed;
    event EventHandler<ShortcutReleasedEventArgs>? HotkeyReleased;
    event EventHandler? PasteHotkeyPressed;
    bool RegisterHotkey(IntPtr windowHandle, ModifierKeys modifiers, VirtualKey key);
    void UnregisterHotkey();
    bool IsRegistered { get; }
    bool IsReleaseTrackingAvailable { get; }
    bool IsPassiveFallback { get; }
    bool IsPasteRegistered { get; }
}

public sealed class ShortcutReleasedEventArgs(TimeSpan heldDuration) : EventArgs
{
    public TimeSpan HeldDuration { get; } = heldDuration;
}

[Flags]
public enum ModifierKeys : uint
{
    None = 0,
    Alt = 0x0001,
    Control = 0x0002,
    Shift = 0x0004,
    Win = 0x0008
}

public enum VirtualKey : uint { Space = 0x20 }

public sealed class GlobalHotkeyService : IGlobalHotkeyService
{
    private const int HotkeyId = 9000;
    private const int PasteHotkeyId = 9002;
    private const uint WmHotkey = 0x0312;
    private const uint WmShortcutReleased = 0x8000 + 42;
    private const uint WmShortcutPressed = 0x8000 + 43;
    private const uint WmKeyDown = 0x0100, WmSysKeyDown = 0x0104;
    private const uint WmKeyUp = 0x0101, WmSysKeyUp = 0x0105;
    private const uint ModNoRepeat = 0x4000;
    private readonly SubclassProcedure _subclassProcedure;
    private readonly KeyboardProcedure _keyboardProcedure;
    private IntPtr _windowHandle;
    private IntPtr _keyboardHook;
    private ModifierKeys _modifiers;
    private long _pressedAt;
    private volatile bool _pressed;
    private bool _isRegistered;
    private bool _nativeRegistered;
    private bool _passiveFallback;
    private bool _pasteRegistered;

    public GlobalHotkeyService()
    {
        _subclassProcedure = WindowSubclassProc;
        _keyboardProcedure = KeyboardHookProc;
    }

    public event EventHandler? HotkeyPressed;
    public event EventHandler<ShortcutReleasedEventArgs>? HotkeyReleased;
    public event EventHandler? PasteHotkeyPressed;
    public bool IsRegistered => _isRegistered;
    public bool IsReleaseTrackingAvailable => _keyboardHook != IntPtr.Zero;
    public bool IsPassiveFallback => _passiveFallback;
    public bool IsPasteRegistered => _pasteRegistered;

    [DllImport("user32.dll", SetLastError = true)]
    private static extern bool RegisterHotKey(IntPtr hWnd, int id, uint modifiers, uint virtualKey);

    [DllImport("user32.dll", SetLastError = true)]
    private static extern bool UnregisterHotKey(IntPtr hWnd, int id);

    [DllImport("comctl32.dll", SetLastError = true)]
    private static extern bool SetWindowSubclass(IntPtr hWnd, SubclassProcedure callback, UIntPtr subclassId, IntPtr referenceData);

    [DllImport("comctl32.dll", SetLastError = true)]
    private static extern bool RemoveWindowSubclass(IntPtr hWnd, SubclassProcedure callback, UIntPtr subclassId);

    [DllImport("comctl32.dll")]
    private static extern IntPtr DefSubclassProc(IntPtr hWnd, uint message, IntPtr wParam, IntPtr lParam);

    [DllImport("user32.dll", EntryPoint = "SetWindowsHookExW", SetLastError = true)]
    private static extern IntPtr SetWindowsHookEx(int hookType, KeyboardProcedure callback, IntPtr module, uint threadId);
    [DllImport("user32.dll", SetLastError = true)]
    private static extern bool UnhookWindowsHookEx(IntPtr hook);
    [DllImport("user32.dll")]
    private static extern IntPtr CallNextHookEx(IntPtr hook, int code, IntPtr wParam, IntPtr lParam);
    [DllImport("user32.dll", EntryPoint = "PostMessageW", SetLastError = true)]
    private static extern bool PostMessage(IntPtr window, uint message, IntPtr wParam, IntPtr lParam);
    [DllImport("user32.dll")]
    private static extern short GetAsyncKeyState(int virtualKey);
    [DllImport("kernel32.dll", EntryPoint = "GetModuleHandleW", CharSet = CharSet.Unicode)]
    private static extern IntPtr GetModuleHandle(string? moduleName);

    public bool RegisterHotkey(IntPtr windowHandle, ModifierKeys modifiers, VirtualKey key)
    {
        if (!OperatingSystem.IsWindows()) throw new PlatformNotSupportedException("Global shortcuts require Windows.");
        if (windowHandle == IntPtr.Zero) throw new ArgumentException("A valid window handle is required.", nameof(windowHandle));
        UnregisterHotkey();

        var nativeRegistered = RegisterHotKey(windowHandle, HotkeyId, (uint)modifiers | ModNoRepeat, (uint)key);
        var registrationError = nativeRegistered ? 0 : Marshal.GetLastWin32Error();
        // Windows reserves Win-key chords. If this one cannot be registered,
        // observe it without suppressing or changing the system's key handling.
        var passiveFallback = !nativeRegistered && modifiers == (ModifierKeys.Win | ModifierKeys.Alt)
            && key == VirtualKey.Space;
        if (!nativeRegistered && !passiveFallback)
            throw new Win32Exception(registrationError, "The Echo shortcut is already in use by another app.");
        if (passiveFallback)
            System.Diagnostics.Debug.WriteLine($"Echo is observing Win+Alt+Space because RegisterHotKey failed: {registrationError}");

        if (!SetWindowSubclass(windowHandle, _subclassProcedure, new UIntPtr(HotkeyId), IntPtr.Zero))
        {
            var error = Marshal.GetLastWin32Error();
            if (nativeRegistered) UnregisterHotKey(windowHandle, HotkeyId);
            throw new Win32Exception(error, "Echo could not listen for the global shortcut.");
        }

        _windowHandle = windowHandle;
        _isRegistered = true;
        _nativeRegistered = nativeRegistered;
        _passiveFallback = passiveFallback;
        _modifiers = modifiers;
        // The low-level hook tracks release after native registration and both
        // edges in fallback mode. It never suppresses input or does UI work.
        _keyboardHook = SetWindowsHookEx(13, _keyboardProcedure, GetModuleHandle(null), 0);
        if (_keyboardHook == IntPtr.Zero)
            _keyboardHook = SetWindowsHookEx(13, _keyboardProcedure, IntPtr.Zero, 0);
        if (_keyboardHook == IntPtr.Zero)
        {
            var hookError = Marshal.GetLastWin32Error();
            if (passiveFallback)
            {
                UnregisterHotkey();
                throw new Win32Exception(hookError, "Windows reserved Win+Alt+Space and Echo could not observe it.");
            }
            System.Diagnostics.Debug.WriteLine($"Echo shortcut release tracking unavailable: {hookError}");
        }
        // The extra Mac-style "paste last transcript" shortcut is optional: a
        // conflict must never disable the primary dictation shortcut.
        _pasteRegistered = RegisterHotKey(windowHandle, PasteHotkeyId,
            (uint)(ModifierKeys.Control | ModifierKeys.Win) | ModNoRepeat, (uint)'V');
        return true;
    }

    public void UnregisterHotkey()
    {
        if (_windowHandle == IntPtr.Zero) return;
        if (_keyboardHook != IntPtr.Zero) UnhookWindowsHookEx(_keyboardHook);
        _keyboardHook = IntPtr.Zero;
        _pressed = false;
        RemoveWindowSubclass(_windowHandle, _subclassProcedure, new UIntPtr(HotkeyId));
        if (_pasteRegistered) UnregisterHotKey(_windowHandle, PasteHotkeyId);
        if (_nativeRegistered) UnregisterHotKey(_windowHandle, HotkeyId);
        _windowHandle = IntPtr.Zero;
        _isRegistered = false;
        _nativeRegistered = false;
        _passiveFallback = false;
        _pasteRegistered = false;
    }

    private IntPtr KeyboardHookProc(int code, IntPtr wParam, IntPtr lParam)
    {
        if (code >= 0)
        {
            var message = (uint)wParam.ToInt64();
            var key = Marshal.PtrToStructure<KeyboardHookData>(lParam);
            if ((key.Flags & 0x10) == 0)
            {
                if (!_pressed && (message is WmKeyDown or WmSysKeyDown)
                    && key.VirtualKey == (uint)VirtualKey.Space && IsConfiguredChordDown())
                {
                    _pressed = true;
                    _pressedAt = Environment.TickCount64;
                    if (_passiveFallback &&
                        !PostMessage(_windowHandle, WmShortcutPressed, IntPtr.Zero, IntPtr.Zero)) _pressed = false;
                }
                else if (_pressed && (message is WmKeyUp or WmSysKeyUp) && IsShortcutReleaseKey(key.VirtualKey))
                {
                    _pressed = false;
                    var elapsed = (int)Math.Clamp(Environment.TickCount64 - _pressedAt, 0, 600_000);
                    PostMessage(_windowHandle, WmShortcutReleased, IntPtr.Zero, new IntPtr(elapsed));
                }
            }
        }
        return CallNextHookEx(_keyboardHook, code, wParam, lParam);
    }

    private bool IsConfiguredChordDown() =>
        ((_modifiers & ModifierKeys.Win) == 0 || IsKeyDown(0x5B) || IsKeyDown(0x5C)) &&
        ((_modifiers & ModifierKeys.Alt) == 0 || IsKeyDown(0xA4) || IsKeyDown(0xA5)) &&
        ((_modifiers & ModifierKeys.Control) == 0 || IsKeyDown(0xA2) || IsKeyDown(0xA3)) &&
        ((_modifiers & ModifierKeys.Shift) == 0 || IsKeyDown(0xA0) || IsKeyDown(0xA1));

    private static bool IsKeyDown(int virtualKey) => (GetAsyncKeyState(virtualKey) & 0x8000) != 0;

    private bool IsShortcutReleaseKey(uint key) => key == (uint)VirtualKey.Space ||
        ((_modifiers & ModifierKeys.Win) != 0 && key is 0x5B or 0x5C) ||
        ((_modifiers & ModifierKeys.Alt) != 0 && key is 0x12 or 0xA4 or 0xA5) ||
        ((_modifiers & ModifierKeys.Control) != 0 && key is 0x11 or 0xA2 or 0xA3) ||
        ((_modifiers & ModifierKeys.Shift) != 0 && key is 0x10 or 0xA0 or 0xA1);

    public void Dispose() => UnregisterHotkey();

    private IntPtr WindowSubclassProc(IntPtr hWnd, uint message, IntPtr wParam, IntPtr lParam, UIntPtr subclassId, IntPtr referenceData)
    {
        if (message == WmHotkey && wParam.ToInt32() == HotkeyId)
        {
            // The keyboard hook captured the physical key-down time already.
            // Replacing it here would make a quick hold look shorter than it was.
            if (_keyboardHook == IntPtr.Zero)
            {
                _pressed = true;
                _pressedAt = Environment.TickCount64;
            }
            HotkeyPressed?.Invoke(this, EventArgs.Empty);
            return IntPtr.Zero;
        }
        if (message == WmShortcutPressed && _passiveFallback)
        {
            HotkeyPressed?.Invoke(this, EventArgs.Empty);
            return IntPtr.Zero;
        }
        if (message == WmShortcutReleased)
        {
            HotkeyReleased?.Invoke(this,
                new ShortcutReleasedEventArgs(TimeSpan.FromMilliseconds(Math.Max(0, lParam.ToInt32()))));
            return IntPtr.Zero;
        }
        if (message == WmHotkey && wParam.ToInt32() == PasteHotkeyId)
        {
            PasteHotkeyPressed?.Invoke(this, EventArgs.Empty);
            return IntPtr.Zero;
        }
        return DefSubclassProc(hWnd, message, wParam, lParam);
    }

    private delegate IntPtr SubclassProcedure(IntPtr hWnd, uint message, IntPtr wParam, IntPtr lParam, UIntPtr subclassId, IntPtr referenceData);
    private delegate IntPtr KeyboardProcedure(int code, IntPtr wParam, IntPtr lParam);
    [StructLayout(LayoutKind.Sequential)]
    private struct KeyboardHookData
    {
        public uint VirtualKey;
        public uint ScanCode;
        public uint Flags;
        public uint Time;
        public UIntPtr ExtraInfo;
    }
}
