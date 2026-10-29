using System.Windows.Forms;

namespace VoiceLabEcho.App.Services;

public class TrayIconService : IDisposable
{
    private NotifyIcon? _notifyIcon;
    private System.Windows.Window? _mainWindow;

    public void Initialize()
    {
        _notifyIcon = new NotifyIcon
        {
            Icon = new System.Drawing.Icon(SystemIcons.Application, 40, 40),
            Visible = true,
            Text = "Voice Lab Echo"
        };

        var contextMenu = new ContextMenuStrip();
        contextMenu.Items.Add("Show", null, OnShowClicked);
        contextMenu.Items.Add("Start Recording", null, OnRecordClicked);
        contextMenu.Items.Add("-");
        contextMenu.Items.Add("Settings", null, OnSettingsClicked);
        contextMenu.Items.Add("-");
        contextMenu.Items.Add("Exit", null, OnExitClicked);

        _notifyIcon.ContextMenuStrip = contextMenu;
        _notifyIcon.DoubleClick += OnTrayIconDoubleClick;
    }

    public void SetMainWindow(System.Windows.Window window)
    {
        _mainWindow = window;
    }

    private void OnShowClicked(object? sender, EventArgs e)
    {
        ShowMainWindow();
    }

    private void OnRecordClicked(object? sender, EventArgs e)
    {
        // TODO: Trigger recording
    }

    private void OnSettingsClicked(object? sender, EventArgs e)
    {
        ShowMainWindow();
        // TODO: Navigate to settings
    }

    private void OnExitClicked(object? sender, EventArgs e)
    {
        System.Windows.Application.Current.Shutdown();
    }

    private void OnTrayIconDoubleClick(object? sender, EventArgs e)
    {
        ShowMainWindow();
    }

    private void ShowMainWindow()
    {
        if (_mainWindow != null)
        {
            _mainWindow.Show();
            _mainWindow.WindowState = System.Windows.WindowState.Normal;
            _mainWindow.Activate();
        }
    }

    public void Dispose()
    {
        _notifyIcon?.Dispose();
    }
}

public class NavigationService
{
    public event EventHandler<string>? NavigationRequested;

    public void NavigateTo(string viewName)
    {
        NavigationRequested?.Invoke(this, viewName);
    }
}

public class WindowManager
{
    private readonly Dictionary<string, System.Windows.Window> _windows = new();

    public void RegisterWindow(string name, System.Windows.Window window)
    {
        _windows[name] = window;
    }

    public void ShowWindow(string name)
    {
        if (_windows.TryGetValue(name, out var window))
        {
            window.Show();
            window.Activate();
        }
    }

    public void HideWindow(string name)
    {
        if (_windows.TryGetValue(name, out var window))
        {
            window.Hide();
        }
    }
}

public class TextInsertionService
{
    public async Task<bool> InsertTextAsync(string text)
    {
        try
        {
            // Try clipboard method
            System.Windows.Clipboard.SetText(text);

            // Simulate Ctrl+V
            await Task.Delay(100);
            SendKeys.SendWait("^v");

            return true;
        }
        catch
        {
            return false;
        }
    }
}

public class StartupService
{
    private const string AppName = "VoiceLabEcho";

    public bool IsStartupEnabled()
    {
        using var key = Microsoft.Win32.Registry.CurrentUser.OpenSubKey(
            @"SOFTWARE\Microsoft\Windows\CurrentVersion\Run", false);
        return key?.GetValue(AppName) != null;
    }

    public bool EnableStartup()
    {
        try
        {
            using var key = Microsoft.Win32.Registry.CurrentUser.OpenSubKey(
                @"SOFTWARE\Microsoft\Windows\CurrentVersion\Run", true);

            var exePath = System.Diagnostics.Process.GetCurrentProcess().MainModule?.FileName;
            key?.SetValue(AppName, $"\"{exePath}\"");
            return true;
        }
        catch
        {
            return false;
        }
    }

    public bool DisableStartup()
    {
        try
        {
            using var key = Microsoft.Win32.Registry.CurrentUser.OpenSubKey(
                @"SOFTWARE\Microsoft\Windows\CurrentVersion\Run", true);
            key?.DeleteValue(AppName, false);
            return true;
        }
        catch
        {
            return false;
        }
    }
}

public class ThemeService
{
    public void SetTheme(string theme)
    {
        // TODO: Implement theme switching
    }

    public string GetCurrentTheme()
    {
        return "light";
    }
}
