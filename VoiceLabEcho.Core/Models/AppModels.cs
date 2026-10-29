namespace VoiceLabEcho.Core.Models;

public class OnboardingProgress
{
    public bool IsComplete { get; set; }
    public int CurrentStep { get; set; }
    public Dictionary<string, string> Answers { get; set; } = new();
    public DateTime? CompletedAt { get; set; }
}

public class AuthenticationState
{
    public bool IsAuthenticated { get; set; }
    public string? AccessToken { get; set; }
    public string? RefreshToken { get; set; }
    public DateTime? TokenExpiry { get; set; }
    public User? User { get; set; }
}

public class KeyboardShortcut
{
    public string Key { get; set; } = string.Empty;
    public bool Ctrl { get; set; }
    public bool Alt { get; set; }
    public bool Shift { get; set; }

    public override string ToString()
    {
        var parts = new List<string>();
        if (Ctrl) parts.Add("Ctrl");
        if (Alt) parts.Add("Alt");
        if (Shift) parts.Add("Shift");
        parts.Add(Key);
        return string.Join("+", parts);
    }
}
