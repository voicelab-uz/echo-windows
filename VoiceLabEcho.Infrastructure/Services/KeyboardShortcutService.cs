using System.Runtime.InteropServices;
using VoiceLabEcho.Core.Interfaces;
using VoiceLabEcho.Core.Models;

namespace VoiceLabEcho.Infrastructure.Services;

public class KeyboardShortcutService : IKeyboardShortcutService
{
    private IntPtr _hookId = IntPtr.Zero;
    private LowLevelKeyboardProc? _hookCallback;
    private KeyboardShortcut? _currentShortcut;
    private Action? _callback;
    private bool _isKeyPressed = false;

    public KeyboardShortcut? CurrentShortcut => _currentShortcut;

    public Task<bool> RegisterShortcutAsync(KeyboardShortcut shortcut, Action callback)
    {
        UnregisterShortcutAsync();

        _currentShortcut = shortcut;
        _callback = callback;

        _hookCallback = HookCallback;
        _hookId = SetHook(_hookCallback);

        return Task.FromResult(_hookId != IntPtr.Zero);
    }

    public Task<bool> UnregisterShortcutAsync()
    {
        if (_hookId != IntPtr.Zero)
        {
            UnhookWindowsHookEx(_hookId);
            _hookId = IntPtr.Zero;
        }

        _currentShortcut = null;
        _callback = null;
        _hookCallback = null;

        return Task.FromResult(true);
    }

    private IntPtr SetHook(LowLevelKeyboardProc proc)
    {
        using var curProcess = System.Diagnostics.Process.GetCurrentProcess();
        using var curModule = curProcess.MainModule;
        return SetWindowsHookEx(WH_KEYBOARD_LL, proc, GetModuleHandle(curModule?.ModuleName), 0);
    }

    private IntPtr HookCallback(int nCode, IntPtr wParam, IntPtr lParam)
    {
        if (nCode >= 0 && _currentShortcut != null)
        {
            int vkCode = Marshal.ReadInt32(lParam);
            bool isKeyDown = wParam == (IntPtr)WM_KEYDOWN || wParam == (IntPtr)WM_SYSKEYDOWN;

            if (isKeyDown && !_isKeyPressed)
            {
                bool ctrlPressed = (GetKeyState(VK_CONTROL) & 0x8000) != 0;
                bool altPressed = (GetKeyState(VK_MENU) & 0x8000) != 0;
                bool shiftPressed = (GetKeyState(VK_SHIFT) & 0x8000) != 0;

                if (ctrlPressed == _currentShortcut.Ctrl &&
                    altPressed == _currentShortcut.Alt &&
                    shiftPressed == _currentShortcut.Shift &&
                    GetKeyName(vkCode) == _currentShortcut.Key)
                {
                    _isKeyPressed = true;
                    System.Windows.Application.Current?.Dispatcher.InvokeAsync(() => _callback?.Invoke());
                }
            }
            else if (!isKeyDown)
            {
                _isKeyPressed = false;
            }
        }

        return CallNextHookEx(_hookId, nCode, wParam, lParam);
    }

    private string GetKeyName(int vkCode)
    {
        return vkCode switch
        {
            VK_SPACE => "Space",
            >= 0x30 and <= 0x39 => ((char)vkCode).ToString(), // 0-9
            >= 0x41 and <= 0x5A => ((char)vkCode).ToString(), // A-Z
            VK_F1 => "F1",
            VK_F2 => "F2",
            VK_F3 => "F3",
            VK_F4 => "F4",
            VK_F5 => "F5",
            VK_F6 => "F6",
            VK_F7 => "F7",
            VK_F8 => "F8",
            VK_F9 => "F9",
            VK_F10 => "F10",
            VK_F11 => "F11",
            VK_F12 => "F12",
            _ => string.Empty
        };
    }

    #region Windows API

    private const int WH_KEYBOARD_LL = 13;
    private const int WM_KEYDOWN = 0x0100;
    private const int WM_SYSKEYDOWN = 0x0104;
    private const int VK_CONTROL = 0x11;
    private const int VK_MENU = 0x12;
    private const int VK_SHIFT = 0x10;
    private const int VK_SPACE = 0x20;
    private const int VK_F1 = 0x70;
    private const int VK_F2 = 0x71;
    private const int VK_F3 = 0x72;
    private const int VK_F4 = 0x73;
    private const int VK_F5 = 0x74;
    private const int VK_F6 = 0x75;
    private const int VK_F7 = 0x76;
    private const int VK_F8 = 0x77;
    private const int VK_F9 = 0x78;
    private const int VK_F10 = 0x79;
    private const int VK_F11 = 0x7A;
    private const int VK_F12 = 0x7B;

    private delegate IntPtr LowLevelKeyboardProc(int nCode, IntPtr wParam, IntPtr lParam);

    [DllImport("user32.dll", CharSet = CharSet.Auto, SetLastError = true)]
    private static extern IntPtr SetWindowsHookEx(int idHook, LowLevelKeyboardProc lpfn, IntPtr hMod, uint dwThreadId);

    [DllImport("user32.dll", CharSet = CharSet.Auto, SetLastError = true)]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static extern bool UnhookWindowsHookEx(IntPtr hhk);

    [DllImport("user32.dll", CharSet = CharSet.Auto, SetLastError = true)]
    private static extern IntPtr CallNextHookEx(IntPtr hhk, int nCode, IntPtr wParam, IntPtr lParam);

    [DllImport("kernel32.dll", CharSet = CharSet.Auto, SetLastError = true)]
    private static extern IntPtr GetModuleHandle(string? lpModuleName);

    [DllImport("user32.dll")]
    private static extern short GetKeyState(int nVirtKey);

    #endregion
}
