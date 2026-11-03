using Microsoft.Win32;

namespace VoiceLab.App.Services;

public interface IStartupService
{
    bool IsEnabled();
    void SetEnabled(bool enabled);
}

public sealed class StartupService : IStartupService
{
    private const string RunKey = @"Software\Microsoft\Windows\CurrentVersion\Run";
    private const string ValueName = "VoiceLab Echo";

    public bool IsEnabled()
    {
        using var key = Registry.CurrentUser.OpenSubKey(RunKey, writable: false);
        var configured = key?.GetValue(ValueName) as string;
        return string.Equals(configured, CommandLine(), StringComparison.OrdinalIgnoreCase);
    }

    public void SetEnabled(bool enabled)
    {
        using var key = enabled
            ? Registry.CurrentUser.CreateSubKey(RunKey, writable: true)
            : Registry.CurrentUser.OpenSubKey(RunKey, writable: true);
        if (key is null)
        {
            if (!enabled) return;
            throw new InvalidOperationException("Windows startup settings are unavailable.");
        }
        if (enabled) key.SetValue(ValueName, CommandLine(), RegistryValueKind.String);
        else key.DeleteValue(ValueName, throwOnMissingValue: false);
    }

    private static string CommandLine()
    {
        var executable = Environment.ProcessPath;
        if (string.IsNullOrWhiteSpace(executable) || !File.Exists(executable))
            throw new InvalidOperationException("Echo could not find its executable for startup.");
        return $"\"{executable}\"";
    }
}
