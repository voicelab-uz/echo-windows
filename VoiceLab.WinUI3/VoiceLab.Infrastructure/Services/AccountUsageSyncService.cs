using System.Net;
using System.Net.Http.Headers;
using System.Net.Http.Json;
using VoiceLab.Infrastructure.Storage;

namespace VoiceLab.Infrastructure.Services;

public interface IAccountUsageSyncService
{
    Task QueueAsync(string transcriptionId, DesktopUsageContext usage, string? expectedOwnerId = null,
        CancellationToken cancellationToken = default);
    Task<int> SyncAsync(CancellationToken cancellationToken = default);
    Task<IReadOnlyList<UsageOutboxItem>> GetPendingAsync(CancellationToken cancellationToken = default);
}

/// <summary>Retries destination attribution from local History or an encrypted outbox.</summary>
public sealed class AccountUsageSyncService(
    IAuthenticationService auth,
    ITranscriptionService transcriptions,
    HttpClient http,
    JsonDataStore store) : IAccountUsageSyncService
{
    private readonly SemaphoreSlim _gate = new(1, 1);
    private readonly SemaphoreSlim _outboxGate = new(1, 1);
    private DateTimeOffset _retryAfter;

    public async Task QueueAsync(string transcriptionId, DesktopUsageContext usage, string? expectedOwnerId = null,
        CancellationToken cancellationToken = default)
    {
        if (!AccountHistoryService.IsRemoteId(transcriptionId) || string.IsNullOrWhiteSpace(usage.AppId)
            || string.IsNullOrWhiteSpace(usage.AppName)) return;
        if (expectedOwnerId is not null && (await auth.GetCurrentUserAsync().ConfigureAwait(false))?.Id != expectedOwnerId)
            return;
        var scope = store.CurrentAccountScope;
        await _outboxGate.WaitAsync(cancellationToken).ConfigureAwait(false);
        try
        {
            if (store.CurrentAccountScope != scope ||
                (expectedOwnerId is not null && (await auth.GetCurrentUserAsync().ConfigureAwait(false))?.Id != expectedOwnerId)) return;
            var pending = await store.ReadListAsync<UsageOutboxItem>("usage-outbox", cancellationToken, scope).ConfigureAwait(false);
            pending.RemoveAll(item => item.Id == transcriptionId);
            pending.Add(new UsageOutboxItem
            {
                Id = transcriptionId, AppId = usage.AppId, AppName = usage.AppName,
                Category = usage.Category, CreatedAt = DateTimeOffset.UtcNow
            });
            if (store.CurrentAccountScope != scope ||
                (expectedOwnerId is not null && (await auth.GetCurrentUserAsync().ConfigureAwait(false))?.Id != expectedOwnerId)) return;
            await store.WriteListAsync("usage-outbox", pending, cancellationToken, scope).ConfigureAwait(false);
        }
        finally { _outboxGate.Release(); }
    }

    public async Task<int> SyncAsync(CancellationToken cancellationToken = default)
    {
        await _gate.WaitAsync(cancellationToken).ConfigureAwait(false);
        try
        {
            if (DateTimeOffset.UtcNow < _retryAfter) return 0;
            var owner = (await auth.GetCurrentUserAsync().ConfigureAwait(false))?.Id;
            if (string.IsNullOrWhiteSpace(owner)) return 0;
            var scope = store.CurrentAccountScope;
            var token = await auth.GetAccessTokenAsync().ConfigureAwait(false);
            if (string.IsNullOrWhiteSpace(token)) return 0;
            var pendingHistory = (await transcriptions.GetHistoryAsync().ConfigureAwait(false))
                .Where(row => row.IsRemote && !row.UsageSynced
                    && !string.IsNullOrWhiteSpace(row.SourceAppId)
                    && !string.IsNullOrWhiteSpace(row.SourceAppName))
                .OrderBy(row => row.CreatedAt)
                .Take(50)
                .ToList();
            var queued = await ReadOutboxAsync(scope, cancellationToken).ConfigureAwait(false);
            var historyIds = new HashSet<string>(pendingHistory.Select(row => row.Id), StringComparer.Ordinal);
            var pending = pendingHistory.Concat(queued.Where(item => !historyIds.Contains(item.Id))
                .Select(item => new Transcription
                {
                    Id = item.Id, SourceAppId = item.AppId, SourceAppName = item.AppName,
                    SourceCategory = item.Category, CreatedAt = item.CreatedAt
                })).OrderBy(row => row.CreatedAt).Take(50).ToList();
            var queuedIds = new HashSet<string>(queued.Select(item => item.Id), StringComparer.Ordinal);
            var completed = 0;
            foreach (var row in pending)
            {
                cancellationToken.ThrowIfCancellationRequested();
                if ((await auth.GetCurrentUserAsync().ConfigureAwait(false))?.Id != owner ||
                    store.CurrentAccountScope != scope) break;
                HttpStatusCode status;
                try
                {
                    status = await PutAsync(row, token, cancellationToken).ConfigureAwait(false);
                    if (status == HttpStatusCode.Unauthorized && await auth.RefreshTokenAsync().ConfigureAwait(false))
                    {
                        token = await auth.GetAccessTokenAsync().ConfigureAwait(false) ?? "";
                        if (token.Length == 0) break;
                        status = await PutAsync(row, token, cancellationToken).ConfigureAwait(false);
                    }
                }
                catch (OperationCanceledException) when (!cancellationToken.IsCancellationRequested)
                {
                    _retryAfter = DateTimeOffset.UtcNow.AddSeconds(30);
                    break;
                }
                catch (HttpRequestException ex)
                {
                    System.Diagnostics.Debug.WriteLine($"Account usage sync unavailable: {ex.Message}");
                    _retryAfter = DateTimeOffset.UtcNow.AddSeconds(30);
                    break;
                }
                if (status != HttpStatusCode.OK && status != HttpStatusCode.NoContent
                    && status != HttpStatusCode.Created && status != HttpStatusCode.Gone)
                {
                    _retryAfter = DateTimeOffset.UtcNow.AddSeconds(status == HttpStatusCode.NotFound ? 1800 : 30);
                    break;
                }
                if ((await auth.GetCurrentUserAsync().ConfigureAwait(false))?.Id != owner ||
                    store.CurrentAccountScope != scope) break;
                if (historyIds.Contains(row.Id)) await transcriptions.MarkUsageSyncedAsync(row.Id).ConfigureAwait(false);
                if (queuedIds.Contains(row.Id)) await RemoveOutboxAsync(row.Id, scope, cancellationToken).ConfigureAwait(false);
                completed++;
            }
            return completed;
        }
        catch (OperationCanceledException) when (!cancellationToken.IsCancellationRequested) { return 0; }
        catch (Exception ex)
        {
            System.Diagnostics.Debug.WriteLine($"Account usage sync failed: {ex}");
            return 0;
        }
        finally { _gate.Release(); }
    }

    public async Task<IReadOnlyList<UsageOutboxItem>> GetPendingAsync(CancellationToken cancellationToken = default)
    {
        var owner = (await auth.GetCurrentUserAsync().ConfigureAwait(false))?.Id;
        if (string.IsNullOrWhiteSpace(owner)) return [];
        var scope = store.CurrentAccountScope;
        var history = await transcriptions.GetHistoryAsync().ConfigureAwait(false);
        var outbox = await ReadOutboxAsync(scope, cancellationToken).ConfigureAwait(false);
        if ((await auth.GetCurrentUserAsync().ConfigureAwait(false))?.Id != owner ||
            store.CurrentAccountScope != scope) return [];
        var pending = history.Where(row => row.IsRemote && !row.UsageSynced &&
                !string.IsNullOrWhiteSpace(row.SourceAppId) && !string.IsNullOrWhiteSpace(row.SourceAppName))
            .GroupBy(row => row.Id, StringComparer.Ordinal)
            .Select(group => group.First())
            .Select(row => new UsageOutboxItem
            {
                Id = row.Id, AppId = row.SourceAppId!, AppName = row.SourceAppName!,
                Category = row.SourceCategory ?? "other", CreatedAt = row.CreatedAt
            })
            .ToDictionary(row => row.Id, StringComparer.Ordinal);
        foreach (var item in outbox) pending[item.Id] = item;
        return pending.Values.ToList();
    }

    private async Task<List<UsageOutboxItem>> ReadOutboxAsync(string scope, CancellationToken cancellationToken)
    {
        await _outboxGate.WaitAsync(cancellationToken).ConfigureAwait(false);
        try
        {
            if (store.CurrentAccountScope != scope) return [];
            return await store.ReadListAsync<UsageOutboxItem>("usage-outbox", cancellationToken, scope).ConfigureAwait(false);
        }
        finally { _outboxGate.Release(); }
    }

    private async Task RemoveOutboxAsync(string id, string scope, CancellationToken cancellationToken)
    {
        await _outboxGate.WaitAsync(cancellationToken).ConfigureAwait(false);
        try
        {
            if (store.CurrentAccountScope != scope) return;
            var pending = await store.ReadListAsync<UsageOutboxItem>("usage-outbox", cancellationToken, scope).ConfigureAwait(false);
            if (pending.RemoveAll(item => item.Id == id) > 0 && store.CurrentAccountScope == scope)
                await store.WriteListAsync("usage-outbox", pending, cancellationToken, scope).ConfigureAwait(false);
        }
        finally { _outboxGate.Release(); }
    }

    private async Task<HttpStatusCode> PutAsync(Transcription row, string token, CancellationToken cancellationToken)
    {
        using var request = new HttpRequestMessage(HttpMethod.Put,
            $"https://api.voicelab.uz/v1/desktop/transcriptions/{Uri.EscapeDataString(row.Id)}/usage")
        {
            Content = JsonContent.Create(new
            {
                app_id = row.SourceAppId,
                app_name = row.SourceAppName,
                category = row.SourceCategory ?? "other"
            })
        };
        request.Headers.Authorization = new AuthenticationHeaderValue("Bearer", token);
        using var response = await http.SendAsync(request, cancellationToken).ConfigureAwait(false);
        return response.StatusCode;
    }
}

public sealed class UsageOutboxItem
{
    public string Id { get; set; } = "";
    public string AppId { get; set; } = "";
    public string AppName { get; set; } = "";
    public string Category { get; set; } = "other";
    public DateTimeOffset CreatedAt { get; set; }
}
