using System.Runtime.InteropServices;
using VoiceLab.Infrastructure.Hotkeys;

namespace VoiceLab.App.Services;

public interface ITrayService : IDisposable
{
    void Attach(IntPtr windowHandle);
    bool IsQuitting { get; }
}

public sealed class TrayService : ITrayService
{
    private const uint WmClose = 0x0010, WmNull = 0x0000, WmUser = 0x0400, WmTray = WmUser + 33;
    private const uint WmLButtonDblClk = 0x0203, WmRButtonUp = 0x0205;
    private const uint NimAdd = 0, NimDelete = 2, NifMessage = 1, NifIcon = 2, NifTip = 4;
    private const uint TpmRightButton = 2, TpmReturnCmd = 0x0100, TpmNonotify = 0x0080;
    private const uint MfString = 0, MfSeparator = 0x800;
    private const int IdOpen = 1, IdQuit = 2, IdCopyLast = 3, SwHide = 0, SwRestore = 9;
    private readonly SubclassProcedure _procedure;
    private readonly uint _taskbarCreatedMessage;
    private IntPtr _hwnd;
    private bool _added;
    private bool _allowClose;
    private IntPtr _icon;
    private bool _ownsIcon;

    public TrayService()
    {
        _procedure = WindowProc;
        _taskbarCreatedMessage = RegisterWindowMessage("TaskbarCreated");
    }
    public bool IsQuitting => _allowClose;

    public void Attach(IntPtr windowHandle)
    {
        if (_hwnd != IntPtr.Zero || windowHandle == IntPtr.Zero) return;
        _hwnd = windowHandle;
        _icon = ExtractIcon(IntPtr.Zero, Environment.ProcessPath ?? string.Empty, 0);
        _ownsIcon = _icon.ToInt64() > 1;
        if (!_ownsIcon) _icon = LoadIcon(IntPtr.Zero, new IntPtr(32512));
        if (!SetWindowSubclass(_hwnd, _procedure, new UIntPtr(0xECA0), IntPtr.Zero))
        {
            var error = Marshal.GetLastWin32Error();
            Dispose();
            throw new System.ComponentModel.Win32Exception(error, "Echo could not enable tray behavior.");
        }
        var data = CreateData(NifMessage | NifIcon | NifTip);
        if (!Shell_NotifyIcon(NimAdd, ref data))
        {
            var error = Marshal.GetLastWin32Error();
            Dispose();
            throw new System.ComponentModel.Win32Exception(error, "Echo could not add its notification-area icon.");
        }
        _added = true;
    }

    public void Dispose()
    {
        if (_hwnd != IntPtr.Zero) RemoveWindowSubclass(_hwnd, _procedure, new UIntPtr(0xECA0));
        if (_added) { var data = CreateData(0); Shell_NotifyIcon(NimDelete, ref data); }
        if (_ownsIcon) DestroyIcon(_icon);
        _hwnd = IntPtr.Zero;
        _added = false;
        _icon = IntPtr.Zero;
        _ownsIcon = false;
    }

    private IntPtr WindowProc(IntPtr hwnd, uint message, IntPtr wParam, IntPtr lParam, UIntPtr subclassId, IntPtr referenceData)
    {
        if (message == _taskbarCreatedMessage)
        {
            var data = CreateData(NifMessage | NifIcon | NifTip);
            _added = Shell_NotifyIcon(NimAdd, ref data);
            if (!_added) System.Diagnostics.Debug.WriteLine("Echo could not restore its tray icon after Explorer restarted.");
            return IntPtr.Zero;
        }
        if (message == WmClose && !_allowClose && _added) { ShowWindow(hwnd, SwHide); return IntPtr.Zero; }
        if (message == WmTray)
        {
            var eventCode = unchecked((uint)lParam.ToInt64());
            if (eventCode == WmLButtonDblClk) Restore();
            else if (eventCode == WmRButtonUp) ShowMenu();
            return IntPtr.Zero;
        }
        return DefSubclassProc(hwnd, message, wParam, lParam);
    }

    private void Restore()
    {
        ShowWindow(_hwnd, SwRestore);
        SetForegroundWindow(_hwnd);
    }

    private void ShowMenu()
    {
        if (!GetCursorPos(out var point)) return;
        var menu = CreatePopupMenu();
        if (menu == IntPtr.Zero) return;
        AppendMenu(menu, MfString, new UIntPtr(IdOpen), "Open Echo");
        AppendMenu(menu, MfString, new UIntPtr(IdCopyLast), "Copy last transcript");
        AppendMenu(menu, MfSeparator, UIntPtr.Zero, null);
        AppendMenu(menu, MfString, new UIntPtr(IdQuit), "Quit Echo");
        SetForegroundWindow(_hwnd);
        var selected = TrackPopupMenu(menu, TpmRightButton | TpmReturnCmd | TpmNonotify, point.X, point.Y, 0, _hwnd, IntPtr.Zero);
        DestroyMenu(menu);
        if (selected == IdOpen) Restore();
        else if (selected == IdCopyLast) CopyLastTranscript();
        else if (selected == IdQuit)
        {
            var hwnd = _hwnd;
            _allowClose = true;
            Dispose();
            PostMessage(hwnd, WmClose, IntPtr.Zero, IntPtr.Zero);
        }
        else PostMessage(_hwnd, WmNull, IntPtr.Zero, IntPtr.Zero);
    }

    private async void CopyLastTranscript()
    {
        try
        {
            if (App.Services.GetService(typeof(IRecordingCoordinator)) is IRecordingCoordinator recording)
                await recording.PasteLastTranscriptAsync(IntPtr.Zero);
        }
        catch (Exception ex) { System.Diagnostics.Debug.WriteLine($"Could not copy last transcript: {ex}"); }
    }

    private NOTIFYICONDATA CreateData(uint flags) => new()
    {
        cbSize = (uint)Marshal.SizeOf<NOTIFYICONDATA>(), hWnd = _hwnd, uID = 1,
        uFlags = flags, uCallbackMessage = WmTray,
        hIcon = _icon, szTip = "VOICE4LAB ECHO"
    };

    [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
    private struct NOTIFYICONDATA
    {
        public uint cbSize; public IntPtr hWnd; public uint uID, uFlags, uCallbackMessage; public IntPtr hIcon;
        [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 128)] public string szTip;
        public uint dwState, dwStateMask; [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 256)] public string szInfo;
        public uint uVersion; [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 64)] public string szInfoTitle;
        public uint dwInfoFlags; public Guid guidItem; public IntPtr hBalloonIcon;
    }
    [StructLayout(LayoutKind.Sequential)] private struct POINT { public int X, Y; }
    private delegate IntPtr SubclassProcedure(IntPtr hwnd, uint message, IntPtr wParam, IntPtr lParam, UIntPtr subclassId, IntPtr referenceData);

    [DllImport("shell32.dll", CharSet = CharSet.Unicode, SetLastError = true)] private static extern bool Shell_NotifyIcon(uint message, ref NOTIFYICONDATA data);
    [DllImport("user32.dll", CharSet = CharSet.Unicode)] private static extern uint RegisterWindowMessage(string message);
    [DllImport("user32.dll", CharSet = CharSet.Unicode)] private static extern IntPtr LoadIcon(IntPtr instance, IntPtr iconName);
    [DllImport("shell32.dll", CharSet = CharSet.Unicode)] private static extern IntPtr ExtractIcon(IntPtr instance, string fileName, uint iconIndex);
    [DllImport("user32.dll")] private static extern bool DestroyIcon(IntPtr icon);
    [DllImport("user32.dll", CharSet = CharSet.Unicode)] private static extern IntPtr CreatePopupMenu();
    [DllImport("user32.dll", CharSet = CharSet.Unicode)] private static extern bool AppendMenu(IntPtr menu, uint flags, UIntPtr id, string? text);
    [DllImport("user32.dll")] private static extern uint TrackPopupMenu(IntPtr menu, uint flags, int x, int y, int reserved, IntPtr hwnd, IntPtr rect);
    [DllImport("user32.dll")] private static extern bool DestroyMenu(IntPtr menu);
    [DllImport("user32.dll")] private static extern bool GetCursorPos(out POINT point);
    [DllImport("user32.dll")] private static extern bool ShowWindow(IntPtr hwnd, int command);
    [DllImport("user32.dll")] private static extern bool SetForegroundWindow(IntPtr hwnd);
    [DllImport("user32.dll")] private static extern bool PostMessage(IntPtr hwnd, uint message, IntPtr wParam, IntPtr lParam);
    [DllImport("comctl32.dll", SetLastError = true)] private static extern bool SetWindowSubclass(IntPtr hwnd, SubclassProcedure callback, UIntPtr subclassId, IntPtr referenceData);
    [DllImport("comctl32.dll", SetLastError = true)] private static extern bool RemoveWindowSubclass(IntPtr hwnd, SubclassProcedure callback, UIntPtr subclassId);
    [DllImport("comctl32.dll")] private static extern IntPtr DefSubclassProc(IntPtr hwnd, uint message, IntPtr wParam, IntPtr lParam);
}
