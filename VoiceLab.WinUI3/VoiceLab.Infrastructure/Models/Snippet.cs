namespace VoiceLab.Infrastructure.Services;

public sealed class Snippet
{
    public string Id { get; set; } = "";
    public string Name { get; set; } = "";
    public string Text { get; set; } = "";
    public DateTimeOffset CreatedAt { get; set; }
}
