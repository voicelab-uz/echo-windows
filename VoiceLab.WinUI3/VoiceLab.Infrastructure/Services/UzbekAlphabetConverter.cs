using System.Reflection;
using System.Text.RegularExpressions;

namespace VoiceLab.Infrastructure.Services;

/// <summary>
/// Conservative Uzbek Latin spelling conversion for inserted text. The account's
/// canonical server transcript is kept unchanged.
/// </summary>
public static class UzbekAlphabetConverter
{
    private const string Apostrophes = "'ʼʻ‘’‛`´′＇";
    private static readonly TimeSpan RegexBudget = TimeSpan.FromMilliseconds(200);
    private static readonly Regex Protected = new(
        @"(?<![\p{L}\p{N}])```[\s\S]*?(?:```|\z)|(?<![\p{L}\p{N}])`[^`\r\n]*(?:`|$)|(?i:(?:https?://|www\.)[^\s<>]+)|[A-Za-z0-9.!#$%&'*+/=?^_`{|}~-]+@[A-Za-z0-9-]+(?:\.[A-Za-z0-9-]+)+|(?i:\b(?:[a-z0-9](?:[a-z0-9-]*[a-z0-9])?\.)+[a-z]{2,63}(?:/[^\s<>]*)?)",
        RegexOptions.Compiled | RegexOptions.CultureInvariant, RegexBudget);
    private static readonly Regex Words = new(
        @"[\p{L}\p{M}\p{N}_]+(?:['ʼʻ‘’‛`´′＇][\p{L}\p{M}\p{N}_]+)*(?:(?<=[OoGg])['ʼʻ‘’‛`´′＇])?",
        RegexOptions.Compiled | RegexOptions.CultureInvariant, RegexBudget);
    private static readonly Regex Letters = new(
        @"[OoGg]['ʼʻ‘’‛`´′＇]|[Ss][Hh]|[Cc][Hh]",
        RegexOptions.Compiled | RegexOptions.CultureInvariant, RegexBudget);
    private static readonly Lazy<HashSet<string>> UzbekWords = new(() => ReadLexicon("uzbek"));
    private static readonly Lazy<HashSet<string>> EnglishWords = new(() => ReadLexicon("english"));
    private static readonly Regex NominalEnding;
    private static readonly Regex VerbalEnding;

    static UzbekAlphabetConverter()
    {
        var possession = "(?:im|ing|i|si|imiz|ingiz|lari)";
        var grammaticalCase = "(?:ni|ning|ga|ka|qa|da|dan)";
        var person = "(?:man|san|miz|siz|lar|m|ng|k|ngiz)";
        var noun = $"(?:lar)?{possession}?{grammaticalCase}?(?:mi)?";
        var verb = "(?:tir|dir|t|il|in|ish|sh|n)?(?:ma)?(?:"
            + "(?:yap|ayap)(?:ti|man|san|miz|siz|tilar)"
            + $"|(?:moqda|yotir){person}?"
            + "|(?:a|y)(?:man|san|di|miz|siz|dilar)"
            + "|di(?:m|ng|k|ngiz|lar)?"
            + $"|(?:gan|kan|qan)(?:{person}|{noun})?"
            + "|(?:gan|kan|qan)di(?:m|ng|k|ngiz|lar)?"
            + $"|(?:moq|moqchi|sa){person}?"
            + $"|(?:ish|sh){noun}"
            + "|(?:ib|b)|(?:ing|sin|ay|aylik))"
            + "(?:mi)?";
        NominalEnding = new Regex($"\\A{noun}\\z", RegexOptions.Compiled | RegexOptions.CultureInvariant, RegexBudget);
        VerbalEnding = new Regex($"\\A{verb}\\z", RegexOptions.Compiled | RegexOptions.CultureInvariant, RegexBudget);
    }

    public static string Convert(string text, string reportedLanguage = "uz",
        IReadOnlyCollection<VocabularyWord>? vocabulary = null)
    {
        if (string.IsNullOrEmpty(text) || text.Length > 100_000) return text;
        var explicitUzbek = vocabulary?.Where(item => !item.IsCorrection && item.Language == "uz-Latn")
            .Select(item => Key(item.Word)).ToHashSet(StringComparer.Ordinal) ?? [];
        var preserved = vocabulary?.Where(item => !item.IsCorrection && item.Language != "uz-Latn")
            .Select(item => Key(item.Word)).ToHashSet(StringComparer.Ordinal) ?? [];
        try
        {
            var prose = Protected.Replace(text, " ");
            if (reportedLanguage != "uz" && Words.Matches(prose).Cast<Match>()
                .Count(match => ShouldConvert(match.Value, explicitUzbek, preserved)) < 2) return text;
            return TransformProse(text, value => ConvertProse(value, explicitUzbek, preserved));
        }
        catch (RegexMatchTimeoutException) { return text; }
    }

    internal static string TransformProse(string text, Func<string, string> transform)
    {
        var result = new System.Text.StringBuilder(text.Length);
        var cursor = 0;
        foreach (Match match in Protected.Matches(text))
        {
            if (match.Index < cursor) continue;
            result.Append(transform(text.Substring(cursor, match.Index - cursor)));
            result.Append(match.Value);
            cursor = match.Index + match.Length;
        }
        result.Append(transform(text[cursor..]));
        return result.ToString();
    }

    private static string ConvertProse(string prose, HashSet<string> explicitUzbek, HashSet<string> preserved) =>
        Words.Replace(prose, match => ShouldConvert(match.Value, explicitUzbek, preserved)
            ? Letters.Replace(match.Value, letter => letter.Value[0] switch
            {
                'o' => "ö", 'O' => "Ö", 'g' => "ğ", 'G' => "Ğ",
                's' => "ş", 'S' => "Ş", 'c' => "ç", 'C' => "Ç", _ => letter.Value
            }) : match.Value);

    private static bool ShouldConvert(string word, HashSet<string> explicitUzbek, HashSet<string> preserved)
    {
        if (word.Length > 64 || word.IndexOfAny(['_', '0', '1', '2', '3', '4', '5', '6', '7', '8', '9']) >= 0)
            return false;
        if (word != word.ToLowerInvariant() && word != word.ToUpperInvariant() &&
            word[1..] != word[1..].ToLowerInvariant()) return false;
        var normalized = Key(word);
        if (preserved.Contains(normalized)) return false;
        if (explicitUzbek.Contains(normalized)) return true;
        if (EnglishWords.Value.Contains(normalized)) return false;
        if (UzbekWords.Value.Contains(normalized)) return true;
        for (var boundary = 3; boundary < normalized.Length; boundary++)
        {
            var suffix = normalized[boundary..];
            if (suffix.Length > 24) continue;
            var stem = normalized[..boundary];
            if (!UzbekWords.Value.Contains(stem)) continue;
            if (!EnglishWords.Value.Contains(stem) && NominalEnding.IsMatch(suffix)) return true;
            if (VerbalEnding.IsMatch(suffix)) return true;
        }
        return false;
    }

    private static string Key(string word)
    {
        var lower = word.ToLowerInvariant();
        var normalized = new System.Text.StringBuilder(lower.Length);
        foreach (var letter in lower)
            normalized.Append(Apostrophes.Contains(letter) ? '\'' : letter);
        return normalized.ToString().Replace("ö", "o'", StringComparison.Ordinal)
            .Replace("ğ", "g'", StringComparison.Ordinal)
            .Replace("ş", "sh", StringComparison.Ordinal)
            .Replace("ç", "ch", StringComparison.Ordinal);
    }

    private static HashSet<string> ReadLexicon(string name)
    {
        var assembly = typeof(UzbekAlphabetConverter).Assembly;
        var resource = assembly.GetManifestResourceNames().Single(item =>
            item.EndsWith($".{name}-alphabet-lexicon.txt", StringComparison.Ordinal));
        using var stream = assembly.GetManifestResourceStream(resource)
            ?? throw new InvalidOperationException("The Uzbek alphabet lexicon is missing.");
        using var reader = new StreamReader(stream);
        var words = new HashSet<string>(StringComparer.Ordinal);
        while (reader.ReadLine() is { } line)
            if (line.Length > 0) words.Add(line);
        return words;
    }
}
