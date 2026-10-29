namespace VoiceLabEcho.Core.Models;

public class User
{
    public string Id { get; set; } = string.Empty;
    public string Email { get; set; } = string.Empty;
    public string DisplayName { get; set; } = string.Empty;
    public string? Role { get; set; }
    public DateTime CreatedAt { get; set; }
    public UserPreferences Preferences { get; set; } = new();
}

public class UserPreferences
{
    public string InterfaceLanguage { get; set; } = "en";
    public string DictationLanguage { get; set; } = "auto";
    public string UzbekAlphabet { get; set; } = "modern"; // modern or classic
    public string Theme { get; set; } = "system"; // light, dark, system
    public string AccentColor { get; set; } = "voicelab"; // voicelab, system, or hex color
    public bool LaunchAtStartup { get; set; } = false;
    public bool ShowDockIcon { get; set; } = true;
    public bool HistoryEnabled { get; set; } = true;
    public TextInsertionMode InsertionMode { get; set; } = TextInsertionMode.Automatic;
}

public enum TextInsertionMode
{
    Automatic,
    Clipboard,
    Keyboard
}
