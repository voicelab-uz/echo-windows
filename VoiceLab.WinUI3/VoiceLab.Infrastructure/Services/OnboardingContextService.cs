using System.Net;
using System.Net.Http.Headers;
using System.Net.Http.Json;
using System.Text.Json;
using VoiceLab.Infrastructure.Storage;

namespace VoiceLab.Infrastructure.Services;

public sealed class OnboardingContextAnswer
{
    public List<string> Choices { get; set; } = [];
    public string Other { get; set; } = "";
    public bool Skipped { get; set; }
}

public sealed class OnboardingContextSnapshot
{
    public string OwnerId { get; set; } = "";
    public int Revision { get; set; }
    public Dictionary<string, OnboardingContextAnswer> Answers { get; set; } = [];
    public string? CompletedAt { get; set; }
    public string? FinishedAt { get; set; }
}

public sealed class OnboardingContextSubmission
{
    public int ExpectedRevision { get; set; }
    public string MutationId { get; set; } = Guid.NewGuid().ToString("D").ToLowerInvariant();
    public Dictionary<string, OnboardingContextAnswer> Answers { get; set; } = [];
    public bool Completed { get; set; }
    public string UiLanguage { get; set; } = "en";
}

public sealed class OnboardingContextDraft
{
    public string OwnerId { get; set; } = "";
    public int Index { get; set; }
    public int Revision { get; set; }
    public string? ConfirmedCompletedAt { get; set; }
    public Dictionary<string, OnboardingContextAnswer> Answers { get; set; } = [];
    public OnboardingContextSubmission? Pending { get; set; }
}

public interface IOnboardingContextService
{
    Task<OnboardingContextSnapshot?> GetAsync(CancellationToken cancellationToken = default);
    Task<OnboardingContextSnapshot> SaveAsync(OnboardingContextSubmission submission, CancellationToken cancellationToken = default);
    Task CompleteAsync(CancellationToken cancellationToken = default);
    Task CompleteForAccountAsync(string ownerId, CancellationToken cancellationToken = default);
    Task<OnboardingContextDraft?> LoadDraftAsync(CancellationToken cancellationToken = default);
    Task SaveDraftAsync(OnboardingContextDraft draft, CancellationToken cancellationToken = default);
}

/// <summary>The current Mac Echo questionnaire and completion API, scoped to the signed-in account.</summary>
public sealed class OnboardingContextService(
    IAuthenticationService auth,
    JsonDataStore store,
    HttpClient http) : IOnboardingContextService
{
    private const string ContextPath = "/v1/desktop/onboarding/context";
    private const string CompletionPath = "/v1/desktop/onboarding/completion";

    public async Task<OnboardingContextSnapshot?> GetAsync(CancellationToken cancellationToken = default)
    {
        var owner = await OwnerAsync().ConfigureAwait(false);
        var body = await RequestAsync(HttpMethod.Get, ContextPath, null, cancellationToken).ConfigureAwait(false);
        return Parse(body, owner);
    }

    public async Task<OnboardingContextSnapshot> SaveAsync(
        OnboardingContextSubmission submission, CancellationToken cancellationToken = default)
    {
        var owner = await OwnerAsync().ConfigureAwait(false);
        ValidateSubmission(submission);
        var payload = new
        {
            expected_revision = submission.ExpectedRevision,
            mutation_id = submission.MutationId,
            questionnaire_version = 1,
            answers = submission.Answers,
            ui_language = submission.UiLanguage,
            app_version = typeof(OnboardingContextService).Assembly.GetName().Version?.ToString() ?? "1.0.0",
            platform = "win32",
            completed = submission.Completed
        };
        var body = await RequestAsync(HttpMethod.Put, ContextPath, payload, cancellationToken).ConfigureAwait(false);
        var profile = Parse(body, owner) ?? throw new InvalidDataException("VoiceLab returned an empty questionnaire.");
        if (profile.Revision != submission.ExpectedRevision + 1
            || (profile.CompletedAt is not null) != submission.Completed
            || !SameAnswers(profile.Answers, submission.Answers))
            throw new InvalidDataException("VoiceLab returned a questionnaire that does not match this save.");
        return profile;
    }

    public async Task CompleteAsync(CancellationToken cancellationToken = default)
    {
        var owner = await OwnerAsync().ConfigureAwait(false);
        await CompleteForAccountAsync(owner, cancellationToken).ConfigureAwait(false);
    }

    public async Task CompleteForAccountAsync(string owner, CancellationToken cancellationToken = default)
    {
        if (string.IsNullOrWhiteSpace(owner)) throw new ArgumentException("An account is required.", nameof(owner));
        var body = await RequestAsync(HttpMethod.Put, CompletionPath, new { }, cancellationToken, owner).ConfigureAwait(false);
        var profile = Parse(body, owner) ?? throw new InvalidDataException("VoiceLab did not confirm onboarding completion.");
        if (!DateTimeOffset.TryParse(profile.FinishedAt, out _))
            throw new InvalidDataException("VoiceLab did not confirm onboarding completion.");
    }

    public async Task<OnboardingContextDraft?> LoadDraftAsync(CancellationToken cancellationToken = default)
    {
        var owner = await OwnerAsync().ConfigureAwait(false);
        var rows = await store.ReadListAsync<OnboardingContextDraft>("onboarding_context_draft", cancellationToken)
            .ConfigureAwait(false);
        return rows.FirstOrDefault(row => row.OwnerId == owner);
    }

    public async Task SaveDraftAsync(OnboardingContextDraft draft, CancellationToken cancellationToken = default)
    {
        var owner = await OwnerAsync().ConfigureAwait(false);
        if (draft.OwnerId != owner) throw new InvalidOperationException("The questionnaire belongs to a different account.");
        await store.WriteListAsync("onboarding_context_draft", new[] { draft }, cancellationToken).ConfigureAwait(false);
    }

    private async Task<string> OwnerAsync()
    {
        var owner = (await auth.GetCurrentUserAsync().ConfigureAwait(false))?.Id;
        return string.IsNullOrWhiteSpace(owner)
            ? throw new InvalidOperationException("Sign in before continuing setup.") : owner;
    }

    private async Task<string> RequestAsync(HttpMethod method, string path, object? payload,
        CancellationToken cancellationToken, string? expectedOwner = null)
    {
        var owner = await OwnerAsync().ConfigureAwait(false);
        if (expectedOwner is not null && owner != expectedOwner)
            throw new InvalidOperationException("The VoiceLab account changed during setup.");
        for (var attempt = 0; attempt < 2; attempt++)
        {
            var token = await auth.GetAccessTokenAsync().ConfigureAwait(false);
            if (string.IsNullOrWhiteSpace(token)) throw new InvalidOperationException("Your VoiceLab session expired. Sign in again.");
            if ((await auth.GetCurrentUserAsync().ConfigureAwait(false))?.Id != owner)
                throw new InvalidOperationException("The VoiceLab account changed during setup.");
            using var request = new HttpRequestMessage(method, "https://api.voicelab.uz" + path);
            request.Headers.Authorization = new AuthenticationHeaderValue("Bearer", token);
            request.Headers.Accept.ParseAdd("application/json");
            if (payload is not null) request.Content = JsonContent.Create(payload);
            using var response = await http.SendAsync(request, cancellationToken).ConfigureAwait(false);
            if (response.StatusCode == HttpStatusCode.Unauthorized && attempt == 0
                && await auth.RefreshTokenAsync().ConfigureAwait(false)) continue;
            var body = await response.Content.ReadAsStringAsync(cancellationToken).ConfigureAwait(false);
            if (!response.IsSuccessStatusCode)
                throw new HttpRequestException("VoiceLab questionnaire request failed (" + (int)response.StatusCode + ").",
                    null, response.StatusCode);
            if ((await auth.GetCurrentUserAsync().ConfigureAwait(false))?.Id != owner)
                throw new InvalidOperationException("The VoiceLab account changed during setup.");
            return body;
        }
        throw new InvalidOperationException("Your VoiceLab session expired. Sign in again.");
    }

    private static OnboardingContextSnapshot? Parse(string body, string expectedOwner)
    {
        using var document = JsonDocument.Parse(body);
        if (!document.RootElement.TryGetProperty("context", out var context))
            throw new InvalidDataException("VoiceLab returned an invalid questionnaire response.");
        if (context.ValueKind == JsonValueKind.Null) return null;
        if (context.ValueKind != JsonValueKind.Object)
            throw new InvalidDataException("VoiceLab returned an invalid questionnaire.");
        var profile = new OnboardingContextSnapshot
        {
            OwnerId = String(context, "user_id", "userId"),
            Revision = Number(context, "revision"),
            CompletedAt = OptionalString(context, "completed_at", "completedAt"),
            FinishedAt = OptionalString(context, "finished_at", "finishedAt")
        };
        var version = Number(context, "questionnaire_version", "questionnaireVersion");
        if (profile.OwnerId != expectedOwner || profile.Revision < 1 || version != 1
            || !context.TryGetProperty("answers", out var answers) || answers.ValueKind != JsonValueKind.Object)
            throw new InvalidDataException("VoiceLab returned a questionnaire for another account or version.");
        foreach (var property in answers.EnumerateObject())
        {
            if (!OnboardingQuestionCatalog.Keys.Contains(property.Name, StringComparer.Ordinal)
                || property.Value.ValueKind != JsonValueKind.Object)
                throw new InvalidDataException("VoiceLab returned an unknown questionnaire answer.");
            var choices = property.Value.TryGetProperty("choices", out var array) && array.ValueKind == JsonValueKind.Array
                ? array.EnumerateArray().Select(item => item.GetString() ?? "").ToList() : [];
            profile.Answers[property.Name] = new OnboardingContextAnswer
            {
                Choices = choices,
                Other = OptionalString(property.Value, "other") ?? "",
                Skipped = property.Value.TryGetProperty("skipped", out var skipped)
                    && skipped.ValueKind == JsonValueKind.True
            };
        }
        return profile;
    }

    private static void ValidateSubmission(OnboardingContextSubmission submission)
    {
        if (submission.ExpectedRevision < 0 || !Guid.TryParse(submission.MutationId, out _))
            throw new ArgumentException("Invalid questionnaire revision or mutation identity.");
        if (submission.UiLanguage.Length is < 2 or > 8 ||
            submission.UiLanguage.Any(character => !char.IsLetter(character) && character != '-'))
            throw new ArgumentException("Invalid questionnaire language.");
        foreach (var (key, answer) in submission.Answers)
        {
            var question = OnboardingQuestionCatalog.All.FirstOrDefault(item => item.Key == key)
                ?? throw new ArgumentException("Unknown questionnaire answer.");
            if (answer.Skipped)
            {
                if (answer.Choices.Count != 0 || answer.Other.Length != 0) throw new ArgumentException("A skipped answer must be empty.");
                continue;
            }
            if (answer.Choices.Count == 0 || answer.Choices.Count > question.Limit
                || answer.Choices.Distinct(StringComparer.Ordinal).Count() != answer.Choices.Count
                || (answer.Choices.Contains("none") && answer.Choices.Count > 1)
                || answer.Choices.Any(choice => !question.Options.Contains(choice, StringComparer.Ordinal))
                || (answer.Choices.Contains("other") && string.IsNullOrWhiteSpace(answer.Other))
                || answer.Other.Length > 280 || answer.Other.Any(char.IsControl))
                throw new ArgumentException("Invalid questionnaire answer.");
        }
    }

    private static bool SameAnswers(
        Dictionary<string, OnboardingContextAnswer> left, Dictionary<string, OnboardingContextAnswer> right) =>
        left.Count == right.Count && right.All(pair => left.TryGetValue(pair.Key, out var answer)
            && answer.Skipped == pair.Value.Skipped && answer.Other == pair.Value.Other
            && answer.Choices.Order(StringComparer.Ordinal).SequenceEqual(
                pair.Value.Choices.Order(StringComparer.Ordinal)));

    private static string String(JsonElement value, params string[] names) =>
        OptionalString(value, names) ?? "";
    private static string? OptionalString(JsonElement value, params string[] names)
    {
        foreach (var name in names)
            if (value.TryGetProperty(name, out var child) && child.ValueKind == JsonValueKind.String)
                return child.GetString();
        return null;
    }
    private static int Number(JsonElement value, params string[] names)
    {
        foreach (var name in names)
            if (value.TryGetProperty(name, out var child) && child.ValueKind == JsonValueKind.Number
                && child.TryGetInt32(out var number)) return number;
        return 0;
    }
}

public sealed record OnboardingQuestion(string Key, int Limit, string[] Options);

public static class OnboardingQuestionCatalog
{
    public static readonly OnboardingQuestion[] All =
    [
        new("discovery", 1, ["friend", "youtube", "instagram", "telegram", "tiktok", "linkedin", "x",
            "facebook", "search", "article", "podcast", "newsletter", "ai_chat", "other"]),
        new("intent", 5, ["dictation", "meeting_notes", "accessibility", "exploring", "other"]),
        new("work", 1, ["developer", "founder", "product", "marketing", "sales", "operations", "student",
            "educator", "writer", "creator", "consultant", "legal", "healthcare", "support",
            "recruiting", "data_analysis", "other"]),
        new("writing", 8, ["messages", "emails", "documents", "notes", "ai", "coding", "posts", "other"]),
        new("meeting_apps", 9, ["zoom", "google_meet", "teams", "slack", "facetime", "telegram",
            "discord", "in_person", "none", "other"]),
        new("meeting_problems", 8, ["preparation", "taking_notes", "focus", "action_items",
            "finding_notes", "sharing", "language", "none", "other"])
    ];
    public static IEnumerable<string> Keys => All.Select(item => item.Key);
}
