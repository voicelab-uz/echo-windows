namespace VoiceLabEcho.Core.Models;

public class VocabularyWord
{
    public string Id { get; set; } = Guid.NewGuid().ToString();
    public string Word { get; set; } = string.Empty;
    public string Language { get; set; } = "all";
    public DateTime CreatedAt { get; set; } = DateTime.UtcNow;
}

public class Snippet
{
    public string Id { get; set; } = Guid.NewGuid().ToString();
    public string Trigger { get; set; } = string.Empty;
    public string Expansion { get; set; } = string.Empty;
    public DateTime CreatedAt { get; set; } = DateTime.UtcNow;
}

public class VocabularyData
{
    public List<VocabularyWord> Words { get; set; } = new();
    public List<Snippet> Snippets { get; set; } = new();
}
