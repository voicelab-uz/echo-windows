namespace VoiceLab.Infrastructure.Services;

public static class ShortcutSettingsExtensions
{
    public static string GetShortcutLabel(this ISettingsService settings) =>
        settings.GetSetting("Shortcut", "win-alt-space") switch
        {
            "ctrl-shift-space" => "Ctrl+Shift+Space",
            "ctrl-alt-space" => "Ctrl+Alt+Space",
            _ => "Win+Alt+Space"
        };
}
