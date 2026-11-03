using System.Reflection;
using System.Text.Json;
using VoiceLab.Core.Models;
using VoiceLab.Infrastructure.Services;
using VoiceLab.Infrastructure.Storage;

var tempRoot = Path.Combine(Path.GetTempPath(), "VoiceLabEchoSmokeTests", Guid.NewGuid().ToString("N"));
Directory.CreateDirectory(tempRoot);
try
{
    var store = new JsonDataStore(tempRoot);
    store.SetAccountId("account-a");
    await store.WriteListAsync("storage-proof", new[] { "private dictation" });
    var protectedPath = Path.Combine(store.CurrentAccountScope, "storage-proof.json");
    var protectedBytes = await File.ReadAllBytesAsync(protectedPath);
    Assert(protectedBytes.AsSpan().StartsWith("VLE1"u8) &&
        !System.Text.Encoding.UTF8.GetString(protectedBytes).Contains("private dictation", StringComparison.Ordinal) &&
        (await store.ReadListAsync<string>("storage-proof")).Single() == "private dictation",
        "Account data was not encrypted and readable with the current Windows user.");
    var legacyPath = Path.Combine(store.CurrentAccountScope, "legacy.json");
    await File.WriteAllTextAsync(legacyPath, "[\"earlier preview\"]");
    Assert((await store.ReadListAsync<string>("legacy")).Single() == "earlier preview" &&
        (await File.ReadAllBytesAsync(legacyPath)).AsSpan().StartsWith("VLE1"u8),
        "An older plaintext account file was not migrated without losing data.");
    var bomPath = Path.Combine(store.CurrentAccountScope, "legacy-bom.json");
    await File.WriteAllTextAsync(bomPath, "[\"earlier Windows history\"]", new System.Text.UTF8Encoding(true));
    Assert((await store.ReadListAsync<string>("legacy-bom")).Single() == "earlier Windows history" &&
        (await File.ReadAllBytesAsync(bomPath)).AsSpan().StartsWith("VLE1"u8) &&
        (await store.ReadListAsync<string>("legacy-bom")).Single() == "earlier Windows history",
        "UTF-8 BOM history must remain readable before and after encrypted migration.");
    await File.WriteAllTextAsync(Path.Combine(store.RootDirectory, "bom-preferences.json"),
        "{\"Shortcut\":\"ctrl-alt-space\"}", new System.Text.UTF8Encoding(true));
    Assert(store.ReadGlobalObject<Dictionary<string, string>>("bom-preferences")?["Shortcut"] == "ctrl-alt-space" &&
        store.ReadGlobalObject<Dictionary<string, string>>("bom-preferences")?["Shortcut"] == "ctrl-alt-space",
        "UTF-8 BOM preferences must remain readable after encrypted migration.");
    var remoteNotes = new FakeNotesService();
    var notes = new NotesService(store, remoteNotes);
    var folder = await notes.CreateFolderAsync("Projects");
    var note = await notes.CreateNoteAsync("Planning", "First draft", folder.Id);
    Assert((await notes.GetNotesAsync()).Single().FolderId == folder.Id, "Note was not placed in its folder.");
    await notes.RenameFolderAsync(folder.Id, "Work");
    Assert((await notes.GetFoldersAsync()).Single().Name == "Work", "Folder rename failed.");
    await notes.DeleteFolderAsync(folder.Id);
    Assert((await notes.GetNotesAsync()).Single().FolderId is null, "Deleting a folder did not move its notes to Unfiled.");
    Assert(await notes.SyncAsync() == 0 && remoteNotes.Records.Count == 1,
        "A pending local note was not uploaded to the account.");
    remoteNotes.ExternalEdit(Guid.Parse(note.Id), "Updated on Mac", "Cloud draft");
    note.Title = "Edited on Windows";
    note.Content = "Local draft";
    await notes.UpdateNoteAsync(note);
    Assert(await notes.SyncAsync() == 1, "A concurrent note edit did not report a conflict.");
    var conflicted = await notes.GetNotesAsync();
    Assert(conflicted.Any(item => item.Title == "Updated on Mac") &&
        conflicted.Any(item => item.Title == "Edited on Windows (copy)"),
        "A concurrent note edit lost one side of the conflict.");
    var offline = await notes.CreateNoteAsync("Offline note", "Survives restart", isPinned: true);
    var restartedNotes = new NotesService(store, remoteNotes);
    Assert(await restartedNotes.SyncAsync() == 0 && remoteNotes.Records.ContainsKey(Guid.Parse(offline.Id)),
        "A pending note did not survive service restart.");
    Assert((await restartedNotes.GetNotesAsync()).First().Id == offline.Id,
        "Pinned notes were not sorted first.");

    var snippets = new SnippetsService(store);
    var snippet = await snippets.CreateSnippetAsync("sign off", "Best regards,\nAhror");
    await File.WriteAllTextAsync(Path.Combine(store.RootDirectory, "settings.json"),
        "{\"Shortcut\":\"ctrl-alt-space\"}");
    var settings = new SettingsService(store);
    Assert(settings.GetSetting("Shortcut", "") == "ctrl-alt-space" &&
        (await File.ReadAllBytesAsync(Path.Combine(store.RootDirectory, "settings.json"))).AsSpan().StartsWith("VLE1"u8),
        "Earlier plaintext settings were not migrated without losing values.");
    settings.SaveSetting("Shortcut", "win-alt-space");
    var settingsBytes = await File.ReadAllBytesAsync(Path.Combine(store.RootDirectory, "settings.json"));
    Assert(settingsBytes.AsSpan().StartsWith("VLE1"u8) &&
        new SettingsService(store).GetSetting("Shortcut", "") == "win-alt-space",
        "Global settings were not encrypted or restored.");
    settings.SaveSetting("Theme", 17);
    Assert(settings.GetSetting("Theme", "system") == "system" &&
        new SettingsService(store).GetSetting("Theme", "system") == "system",
        "An older mistyped preference should not prevent Settings from opening.");
    var service = new TranscriptionService(store, new NoAuth(), settings,
        new VocabularyService(store), snippets, new HttpClient());
    var formatter = typeof(TranscriptionService).GetMethod("FormatTextAsync", BindingFlags.Instance | BindingFlags.NonPublic)
        ?? throw new Exception("Formatter missing.");
    async Task<string> Format(string input) => await (Task<string>)formatter.Invoke(service, [input, "auto"])!;
    Assert(await Format("sign off.") == "Best regards,\nAhror", "Exact spoken snippet expansion failed.");
    Assert((await Format("Please use sign off today.")).Contains("Best regards,\nAhror"), "Inline snippet expansion failed.");
    await snippets.UpdateSnippetAsync(snippet.Id, "closing", "Thank you");
    Assert(await Format("closing") == "Thank you", "Edited snippet did not expand.");
    var dictionary = new VocabularyService(store);
    var correction = await dictionary.SaveWordAsync(null, "teh", "the", "en-Latn", true);
    Assert(correction.IsCorrection && await Format("teh cat") == "The cat.",
        "A spoken dictionary correction was not applied to dictation.");
    Assert(await dictionary.ImportWordsAsync("Echo, VoiceLab, Echo", "en-Latn") == 2,
        "Dictionary import did not skip duplicate words in one batch.");
    Assert((await dictionary.GetWordsAsync()).Count == 3,
        "Dictionary corrections or imported words were lost.");
    Assert(UzbekAlphabetConverter.Convert("O‘zbek, g‘oya, shahar, chiroyli") ==
        "Özbek, ğoya, şahar, çiroyli", "Modern Uzbek alphabet conversion failed.");
    Assert(UzbekAlphabetConverter.Convert("shahar https://shop.uz/ch `show('ch')` chiroq") ==
        "şahar https://shop.uz/ch `show('ch')` çiroq",
        "Modern alphabet conversion changed a link or code span.");
    Assert(UzbekAlphabetConverter.Convert("shahar chat shopda chiroq") ==
        "şahar chat shopda çiroq", "Modern alphabet conversion changed ambiguous English text.");
    settings.SaveSetting("UzbekAlphabet", "modern");
    var modernOutput = await (Task<string>)formatter.Invoke(service, ["Chiroyli shablon va g‘oya", "uz"])!;
    Assert(modernOutput == "Çiroyli şablon va ğoya.",
        $"The selected alphabet was not applied to dictation output. Actual: {modernOutput}");
    await snippets.CreateSnippetAsync("shablon", "Best wishes, Shavkat\nhttps://shop.uz/ch");
    Assert(await (Task<string>)formatter.Invoke(service, ["Chiroyli shablon va g‘oya", "uz"])! ==
        "Çiroyli Best wishes, Shavkat\nhttps://shop.uz/ch va ğoya.",
        "A snippet expansion was altered by Uzbek alphabet conversion.");
    Assert(await (Task<string>)formatter.Invoke(service, ["Show character O'zbek", "en"])! ==
        "Show character O'zbek.", "English dictation was converted as Uzbek.");
    settings.SaveSetting("UzbekAlphabet", "current");
    var sttHandler = new FakeSttHandler();
    using var sttHttp = new HttpClient(sttHandler);
    var realSttContract = new TranscriptionService(store, new FakeAuth(), settings, dictionary, snippets, sttHttp);
    var sttRecord = await realSttContract.TranscribeAudioRecordAsync(new byte[3_200], "uz");
    Assert(sttRecord.Text == "The cat." && sttRecord.Id == "dst_contract_stt" && sttHandler.RequestCount == 2,
        "Desktop STT did not use automatic detection or retry the typed pre-inference busy response.");
    Assert((await realSttContract.GetHistoryAsync()).Single().Text == "teh cat",
        "A formatted insertion overwrote the canonical account transcript in local History.");
    var audioUploadPath = Path.Combine(tempRoot, "upload.wav");
    await File.WriteAllBytesAsync(audioUploadPath, new byte[3_200]);
    Assert(await realSttContract.TranscribeFileAsync(audioUploadPath, "en") == "The cat."
        && sttHandler.RequestCount == 3, "File upload did not use the desktop STT request path.");
    Assert(await realSttContract.TranscribeAudioAsync(new byte[3_200], "uz", saveHistory: false) == "The cat." &&
        (await realSttContract.GetHistoryAsync()).Count == 1,
        "Onboarding practice was added to History despite being a temporary exercise.");
    var privateDictation = await realSttContract.TranscribeAudioRecordAsync(new byte[3_200], "uz", saveHistory: false);
    Assert(privateDictation.Text == "The cat." && privateDictation.Id == "dst_contract_stt" &&
        (await realSttContract.GetHistoryAsync()).Count == 1,
        "A dictation with device History saving disabled added a local History row or lost its account ID.");

    store.SetAccountId("account-b");
    Assert((await notes.GetNotesAsync()).Count == 0, "Notes leaked into another account.");
    Assert((await snippets.GetSnippetsAsync()).Count == 0, "Snippets leaked into another account.");
    store.SetAccountId("account-a");
    Assert((await notes.GetNotesAsync()).Count >= 3, "Original account notes were lost.");
    var day = new DateOnly(2026, 11, 2);
    var metrics = StatisticsMetrics.FromRows([
        new StatisticsDay(day.AddDays(-2), 20, 1, 20_000),
        new StatisticsDay(day.AddDays(-1), 40, 1, 40_000)
    ], day);
    Assert(metrics.Days.Count == 182 && metrics.ActiveDays == 2, "Statistics period or active-day count is wrong.");
    Assert(metrics.CurrentStreak == 2 && metrics.LongestStreak == 2, "Yesterday's streak should remain active.");
    Assert(Math.Abs(metrics.WordsPerMinute!.Value - 60) < .01, "Dictation speed calculation is wrong.");
    Assert(Math.Abs(metrics.SecondsSaved(40) - 30) < .01, "Time saved must use actual speaking duration.");
    var unicodeWords = StatisticsMetrics.FromLocalHistory([
        new Transcription
        {
            Id = "unicode-words", Text = "O‘zbekiston, g'oya va ko‘z. Привет мир! Hello-world… 😀 ' ’",
            WordCount = 99, CreatedAt = DateTimeOffset.Now, AudioDurationMs = 1000
        }
    ], DateOnly.FromDateTime(DateTime.Today));
    Assert(unicodeWords.Words == 8,
        "Local statistics did not use the Mac word count for Unicode text and older saved rows.");

    var sttParser = typeof(TranscriptionService).GetMethod("ReadTranscription", BindingFlags.Static | BindingFlags.NonPublic)
        ?? throw new Exception("STT response parser missing.");
    var currentStt = sttParser.Invoke(null, ["{\"id\":\"dst_test1\",\"text\":\"Hello\",\"language\":\"en\",\"durationMs\":1200,\"revision\":1}"])!;
    Assert((string?)currentStt.GetType().GetField("Item4")?.GetValue(currentStt) == "dst_test1",
        "The Mac STT response identity was discarded.");
    var legacyStt = sttParser.Invoke(null, ["{\"operation\":{\"result\":{\"text\":\"Hello\",\"language\":\"en\",\"duration_ms\":1200,\"request_id\":\"req_test\"}}}"])!;
    Assert((string?)legacyStt.GetType().GetField("Item1")?.GetValue(legacyStt) == "Hello",
        "The existing nested STT response stopped working.");

    using var cloudHttp = new HttpClient(new FakeHistoryHandler());
    var accountHistory = new AccountHistoryService(cloudHttp, new FakeAuth());
    var first = await accountHistory.GetPageAsync(1);
    Assert(first.Items.Count == 1 && first.Items[0].Id == "dst_test1" && first.Items[0].Revision == 1 && first.HasMore,
        "The first account History page did not match the Mac API contract.");
    var second = await accountHistory.GetPageAsync(2);
    Assert(second.Items.Count == 0 && !second.HasMore, "Account History pagination did not end.");
    var edited = await accountHistory.UpdateAsync(first.Items[0], "Edited transcript");
    Assert(edited.Text == "Edited transcript" && edited.Revision == 2,
        "Account transcript editing did not preserve the server revision.");
    var notificationHandler = new FakeNotificationHandler();
    using var notificationHttp = new HttpClient(notificationHandler);
    var notifications = new AccountNotificationService(notificationHttp, new FakeAuth());
    var inbox = await notifications.GetPageAsync();
    Assert(inbox.Items.Count == 1 && inbox.Items[0].Destination == "notes" && inbox.Unread == 1
        && inbox.NextCursor == 41 && inbox.ThroughCursor == 42,
        "The account notification page did not match the Mac API contract.");
    Assert((await notifications.GetPageAsync(inbox.NextCursor)).Items.Count == 0,
        "Account notification pagination did not end.");
    await notifications.MarkReadAsync(id: inbox.Items[0].Id);
    await notifications.MarkReadAsync(throughCursor: inbox.ThroughCursor);
    Assert(notificationHandler.ReadById && notificationHandler.ReadThrough,
        "Notification read requests did not carry the expected identity and cursor.");
    // The Mac desktop contract does not require request_id/session_id in auth replies.
    var authType = typeof(AuthenticationService);
    var tokenType = authType.GetNestedType("TokenResponse", BindingFlags.NonPublic)
        ?? throw new Exception("Desktop token parser missing.");
    using var tokenDocument = JsonDocument.Parse("""
        {"access_token":"access_rotated_123456789","refresh_token":"refresh_rotated_123456789",
         "token_type":"Bearer","expires_in":900,"refresh_expires_in":2592000,
         "refresh_retry_supported":true}
        """);
    var tokenReply = tokenType.GetMethod("From", BindingFlags.Public | BindingFlags.Static)!
        .Invoke(null, [tokenDocument.RootElement])!;
    var storedSession = (StoredDesktopSession)authType.GetMethod("ReadSession", BindingFlags.NonPublic | BindingFlags.Static)!
        .Invoke(null, [tokenReply, "installation-test", new User { Id = "account-a", Email = "user@example.com" }, null])!;
    Assert(storedSession.RefreshToken == "refresh_rotated_123456789" && storedSession.RefreshRetrySupported == true,
        "A valid Mac-compatible token rotation was rejected or lost retry support.");
    using var authorizationHttp = new HttpClient(new FakeAuthorizationHandler());
    var authContract = new AuthenticationService(authorizationHttp, new FakeSecureStore());
    var createAuthorization = authType.GetMethod("CreateAuthorizationAsync", BindingFlags.NonPublic | BindingFlags.Instance)!;
    var authorizationTask = (Task)createAuthorization.Invoke(authContract,
        ["http://127.0.0.1:49152/callback", "challenge", "state", "installation-test"])!;
    await authorizationTask;
    var authorizationReply = authorizationTask.GetType().GetProperty("Result")!.GetValue(authorizationTask)!;
    var authorizationUrl = authorizationReply.GetType().GetProperty("AuthorizationUrl")!.GetValue(authorizationReply)?.ToString();
    Assert(authorizationUrl?.Contains("desktop_auth_id=dau_test", StringComparison.Ordinal) == true,
        "A valid Mac-compatible authorization response was rejected.");
    var readCallbackCode = authType.GetMethod("ReadCallbackCode", BindingFlags.NonPublic | BindingFlags.Static)
        ?? throw new Exception("Desktop callback validator missing.");
    var redirectUri = new Uri("http://127.0.0.1:49152/callback");
    string? CallbackCode(string url, params string[] hosts) => (string?)readCallbackCode.Invoke(null,
        [new Uri(url), hosts, redirectUri, "expected-state"]);
    Assert(CallbackCode("http://127.0.0.1:49152/callback?code=dac_valid_123&state=expected-state",
        "127.0.0.1:49152") == "dac_valid_123", "A valid loopback callback was rejected.");
    Assert(CallbackCode("http://127.0.0.1:49152/callback?code=dac_valid_123&state=expected-state",
        "localhost:49152") is null &&
        CallbackCode("http://127.0.0.1:49152/callback?code=dac_valid_123&code=dac_second&state=expected-state",
        "127.0.0.1:49152") is null &&
        CallbackCode("http://127.0.0.1:49152/callback?code=dac_invalid!&state=expected-state",
        "127.0.0.1:49152") is null &&
        CallbackCode("http://127.0.0.1:49152/other?code=dac_valid_123&state=expected-state",
        "127.0.0.1:49152") is null,
        "A malformed or unexpected localhost callback was accepted.");
    var rotatingStore = new FakeSecureStore
    {
        Session = new StoredDesktopSession
        {
            RefreshToken = "refresh_before_123456789", InstallationId = "installation-test",
            RefreshExpiresAt = DateTimeOffset.UtcNow.AddDays(1), RefreshRetrySupported = true,
            User = new User { Id = "account-a", Email = "user@example.com" }
        }
    };
    var rotatingHandler = new FakeRotationHandler();
    using var rotatingHttp = new HttpClient(rotatingHandler);
    var rotatingAuth = new AuthenticationService(rotatingHttp, rotatingStore);
    Assert(!await rotatingAuth.RefreshTokenAsync() && rotatingStore.Session?.PendingRefreshId is not null,
        "An ambiguous refresh lost its durable retry ID.");
    Assert(await rotatingAuth.RefreshTokenAsync() && rotatingHandler.IdempotencyKeys.Count == 2 &&
        rotatingHandler.IdempotencyKeys[0] == rotatingHandler.IdempotencyKeys[1] &&
        rotatingStore.Session?.RefreshToken == "refresh_after_123456789" &&
        rotatingStore.Session.PendingRefreshId is null,
        "A retry did not reuse the same refresh operation or persist its rotated token.");
    await rotatingAuth.SignOutAsync();
    Assert(rotatingStore.Session is null && rotatingHandler.LogoutRequestValid,
        "Desktop sign-out did not remove the device credential and revoke the Mac-compatible server session.");
    var offlineStore = new FakeSecureStore
    {
        Session = new StoredDesktopSession
        {
            RefreshToken = "refresh_offline_123456789", InstallationId = "installation-test",
            RefreshExpiresAt = DateTimeOffset.UtcNow.AddDays(1),
            User = new User { Id = "account-a", Email = "user@example.com" }
        }
    };
    using var offlineHttp = new HttpClient(new FakeOfflineAuthHandler());
    var offlineAuth = new AuthenticationService(offlineHttp, offlineStore);
    var remoteFailureReported = false;
    try { await offlineAuth.SignOutAsync(); }
    catch (RemoteSessionRevocationException) { remoteFailureReported = true; }
    Assert(remoteFailureReported && offlineStore.Session is null,
        "Offline sign-out retained the device credential or hid the failed server revocation.");
    var attributed = await service.SaveTranscriptionAsync("Hello Aisha", "en", 1200,
        remoteId: "dst_usage1", revision: 1);
    await service.AttachUsageContextAsync(attributed.Id, new DesktopUsageContext("win:notepad", "Notepad", "documents"));
    var usageHandler = new FakeUsageHandler();
    using var usageHttp = new HttpClient(usageHandler);
    var usageSync = new AccountUsageSyncService(new FakeAuth(), service, usageHttp, store);
    Assert(await usageSync.SyncAsync() == 1 && usageHandler.RequestCount == 1,
        "Desktop usage was not sent to the account API.");
    Assert((await service.GetHistoryAsync()).Single(item => item.Id == attributed.Id).UsageSynced,
        "A completed desktop usage event was not marked as synced.");
    Assert(await usageSync.SyncAsync() == 0 && usageHandler.RequestCount == 1,
        "Synced desktop usage was sent twice.");
    await usageSync.QueueAsync("dst_usage_without_local_history", new DesktopUsageContext("win:notepad", "Notepad", "documents"));
    store.SetAccountId("account-b");
    Assert((await store.ReadListAsync<UsageOutboxItem>("usage-outbox")).Count == 0,
        "Pending usage attribution leaked into another account.");
    store.SetAccountId("account-a");
    Assert((await store.ReadListAsync<UsageOutboxItem>("usage-outbox")).Count == 1 &&
        await usageSync.SyncAsync() == 1 && usageHandler.RequestCount == 2 &&
        (await store.ReadListAsync<UsageOutboxItem>("usage-outbox")).Count == 0,
        "Usage attribution was lost when local History retention was disabled.");
    using var contextHttp = new HttpClient(new FakeContextHandler());
    var contextService = new OnboardingContextService(new FakeAuth(), store, contextHttp);
    Assert(await contextService.GetAsync() is null, "A new account should have no questionnaire context.");
    var answer = new OnboardingContextAnswer { Choices = ["dictation"] };
    var submission = new OnboardingContextSubmission
    {
        ExpectedRevision = 0,
        Answers = new Dictionary<string, OnboardingContextAnswer> { ["intent"] = answer }
    };
    await contextService.SaveDraftAsync(new OnboardingContextDraft
    {
        OwnerId = "account-a", Index = 1, Answers = submission.Answers, Pending = submission
    });
    Assert((await contextService.LoadDraftAsync())?.Pending?.MutationId == submission.MutationId,
        "Questionnaire retry lost its idempotency key.");
    var contextSaved = await contextService.SaveAsync(submission);
    Assert(contextSaved.Revision == 1 && contextSaved.Answers["intent"].Choices.Single() == "dictation",
        "The account questionnaire save did not match the Mac API contract.");
    await contextService.CompleteAsync();
    Console.WriteLine("Smoke tests passed: notes sync/conflicts, local storage, snippets, statistics, STT, History, notifications, auth contracts, usage, questionnaire and completion APIs.");
}
finally
{
    var expectedParent = Path.GetFullPath(Path.Combine(Path.GetTempPath(), "VoiceLabEchoSmokeTests")) + Path.DirectorySeparatorChar;
    var actual = Path.GetFullPath(tempRoot);
    if (actual.StartsWith(expectedParent, StringComparison.OrdinalIgnoreCase) && Directory.Exists(actual))
        Directory.Delete(actual, recursive: true);
}

static void Assert(bool condition, string message)
{
    if (!condition) throw new Exception(message);
}

sealed class NoAuth : IAuthenticationService
{
    public Task<bool> IsAuthenticatedAsync() => Task.FromResult(false);
    public Task<AuthResult> SignInWithBrowserAsync(CancellationToken cancellationToken = default) => Task.FromResult(new AuthResult { Success = false });
    public Task<User?> GetCurrentUserAsync() => Task.FromResult<User?>(null);
    public Task<bool> RefreshTokenAsync() => Task.FromResult(false);
    public Task SignOutAsync() => Task.CompletedTask;
    public Task<string?> GetAccessTokenAsync() => Task.FromResult<string?>(null);
}

sealed class FakeAuth : IAuthenticationService
{
    public Task<bool> IsAuthenticatedAsync() => Task.FromResult(true);
    public Task<AuthResult> SignInWithBrowserAsync(CancellationToken cancellationToken = default) => throw new NotSupportedException();
    public Task<User?> GetCurrentUserAsync() => Task.FromResult<User?>(new User { Id = "account-a", Email = "user@example.com" });
    public Task<bool> RefreshTokenAsync() => Task.FromResult(false);
    public Task SignOutAsync() => Task.CompletedTask;
    public Task<string?> GetAccessTokenAsync() => Task.FromResult<string?>("test-access-token");
}

sealed class FakeSecureStore : ISecureStorageService
{
    public StoredDesktopSession? Session { get; set; }
    public Task SaveTokenAsync(string token) => Task.CompletedTask;
    public Task<string?> GetTokenAsync() => Task.FromResult<string?>(null);
    public Task<string?> GetRefreshTokenAsync() => Task.FromResult(Session?.RefreshToken);
    public Task SaveSessionAsync(StoredDesktopSession session) { Session = session; return Task.CompletedTask; }
    public Task<StoredDesktopSession?> GetSessionAsync() => Task.FromResult(Session);
    public Task<string> GetOrCreateInstallationIdAsync() => Task.FromResult("installation-test");
    public Task RemoveTokenAsync() { Session = null; return Task.CompletedTask; }
}

sealed class FakeAuthorizationHandler : HttpMessageHandler
{
    protected override Task<HttpResponseMessage> SendAsync(HttpRequestMessage request, CancellationToken cancellationToken)
    {
        if (request.RequestUri?.AbsolutePath != "/api/v2/auth/desktop/authorizations")
            throw new InvalidOperationException("Unexpected authorization request.");
        return Task.FromResult(new HttpResponseMessage(System.Net.HttpStatusCode.OK)
        {
            Content = new StringContent("""
                {"authorization_url":"https://voicelab.uz/app/sign-in?desktop_auth_id=dau_test",
                 "authorization_request_id":"dau_test","expires_in":300}
                """, System.Text.Encoding.UTF8, "application/json")
        });
    }
}

sealed class FakeRotationHandler : HttpMessageHandler
{
    public List<string?> IdempotencyKeys { get; } = [];
    public bool LogoutRequestValid { get; private set; }

    protected override async Task<HttpResponseMessage> SendAsync(HttpRequestMessage request, CancellationToken cancellationToken)
    {
        if (request.RequestUri?.AbsolutePath == "/api/v2/auth/desktop/logout")
        {
            var body = await request.Content!.ReadAsStringAsync(cancellationToken);
            LogoutRequestValid = request.Headers.Authorization?.Scheme == "Bearer" &&
                request.Headers.Authorization.Parameter == "access_after_123456789" &&
                body.Contains("refresh_after_123456789", StringComparison.Ordinal) &&
                body.Contains("installation-test", StringComparison.Ordinal);
            return new HttpResponseMessage(System.Net.HttpStatusCode.NoContent);
        }
        if (request.RequestUri?.AbsolutePath != "/api/v2/auth/desktop/token")
            throw new InvalidOperationException("Unexpected refresh request.");
        IdempotencyKeys.Add(request.Headers.TryGetValues("Idempotency-Key", out var keys) ? keys.Single() : null);
        if (IdempotencyKeys.Count == 1)
            return new HttpResponseMessage(System.Net.HttpStatusCode.ServiceUnavailable)
            {
                Content = new StringContent("""{"error":{"code":"unavailable","message":"Try again"}}""")
            };
        return new HttpResponseMessage(System.Net.HttpStatusCode.OK)
        {
            Content = new StringContent("""
                {"access_token":"access_after_123456789","refresh_token":"refresh_after_123456789",
                 "token_type":"Bearer","expires_in":900,"refresh_expires_in":2592000,
                 "refresh_retry_supported":true}
                """, System.Text.Encoding.UTF8, "application/json")
        };
    }
}

sealed class FakeOfflineAuthHandler : HttpMessageHandler
{
    protected override Task<HttpResponseMessage> SendAsync(HttpRequestMessage request, CancellationToken cancellationToken) =>
        Task.FromResult(new HttpResponseMessage(System.Net.HttpStatusCode.ServiceUnavailable));
}

sealed class FakeNotesService : IAccountNotesService
{
    public Dictionary<Guid, RemoteNote> Records { get; } = [];

    public Task<RemoteNotesPage> GetPageAsync(Guid? cursor = null, CancellationToken cancellationToken = default) =>
        Task.FromResult(new RemoteNotesPage(Records.Values.OrderBy(item => item.Id).ToList(), null));

    public Task<RemoteNote> SaveAsync(NoteMutation mutation, CancellationToken cancellationToken = default)
    {
        if (Records.TryGetValue(mutation.Id, out var current) && current.Revision != mutation.ExpectedRevision)
            return Task.FromResult(current);
        var next = new RemoteNote(mutation.Id, mutation.Deleted ? "" : mutation.Title,
            mutation.Deleted ? "" : mutation.Body, !mutation.Deleted && mutation.IsPinned,
            mutation.Deleted, (current?.Revision ?? 0) + 1, mutation.MutationId, DateTimeOffset.UtcNow);
        Records[mutation.Id] = next;
        return Task.FromResult(next);
    }

    public void ExternalEdit(Guid id, string title, string body)
    {
        var old = Records[id];
        Records[id] = old with { Title = title, Body = body, Revision = old.Revision + 1,
            MutationId = Guid.NewGuid(), UpdatedAt = DateTimeOffset.UtcNow };
    }
}

sealed class FakeNotificationHandler : HttpMessageHandler
{
    public bool ReadById { get; private set; }
    public bool ReadThrough { get; private set; }

    protected override async Task<HttpResponseMessage> SendAsync(HttpRequestMessage request, CancellationToken cancellationToken)
    {
        if (request.Headers.Authorization?.Parameter != "test-access-token")
            throw new Exception("Notification request was unauthenticated.");
        var path = request.RequestUri!.AbsolutePath;
        if (path == "/v1/desktop/notifications/read" && request.Method == HttpMethod.Post)
        {
            var body = await request.Content!.ReadAsStringAsync(cancellationToken);
            ReadById |= body.Contains("\"id\":\"11111111-1111-1111-1111-111111111111\"", StringComparison.Ordinal);
            ReadThrough |= body.Contains("\"through_cursor\":\"42\"", StringComparison.Ordinal);
            return new HttpResponseMessage(System.Net.HttpStatusCode.NoContent);
        }
        if (path != "/v1/desktop/notifications" || request.Method != HttpMethod.Get)
            throw new Exception("Unexpected notification endpoint.");
        var payload = request.RequestUri.Query.Contains("cursor=41", StringComparison.Ordinal)
            ? "{\"items\":[],\"next_cursor\":\"\",\"through_cursor\":\"42\",\"unread\":1}"
            : "{\"items\":[{\"id\":\"11111111-1111-1111-1111-111111111111\",\"title\":\"New feature\",\"body\":\"Try Notes\",\"destination\":\"notes\",\"created_at\":\"2026-11-02T12:00:00Z\",\"read\":false,\"category\":\"news\"}],\"next_cursor\":\"41\",\"through_cursor\":\"42\",\"unread\":1}";
        return new HttpResponseMessage(System.Net.HttpStatusCode.OK)
        {
            Content = new StringContent(payload, System.Text.Encoding.UTF8, "application/json")
        };
    }
}

sealed class FakeSttHandler : HttpMessageHandler
{
    public int RequestCount { get; private set; }

    protected override async Task<HttpResponseMessage> SendAsync(HttpRequestMessage request, CancellationToken cancellationToken)
    {
        RequestCount++;
        if (request.Method != HttpMethod.Post || request.RequestUri!.AbsolutePath != "/v1/desktop/stt" ||
            request.Headers.Authorization?.Parameter != "test-access-token")
            throw new Exception("Desktop STT request path, method, or authorization was wrong.");
        if (request.Content is not MultipartFormDataContent form)
            throw new Exception("Desktop STT did not send multipart form data.");
        var languagePart = form.FirstOrDefault(part =>
            part.Headers.ContentDisposition?.Name?.Trim('"') == "language");
        var audioPart = form.FirstOrDefault(part =>
            part.Headers.ContentDisposition?.Name?.Trim('"') == "audio");
        if (languagePart is null || audioPart is null ||
            await languagePart.ReadAsStringAsync(cancellationToken) != "auto" ||
            string.IsNullOrWhiteSpace(audioPart.Headers.ContentDisposition?.FileName?.Trim('"')))
            throw new Exception("Desktop STT multipart request did not match the Mac API contract.");
        if (RequestCount == 1)
            return new HttpResponseMessage(System.Net.HttpStatusCode.TooManyRequests)
            {
                Content = new StringContent("{\"error\":{\"code\":\"concurrent_dictation\",\"message\":\"Busy\"}}")
            };
        return new HttpResponseMessage(System.Net.HttpStatusCode.OK)
        {
            Content = new StringContent("{\"id\":\"dst_contract_stt\",\"text\":\"teh cat\",\"language\":\"en\",\"duration_ms\":100,\"revision\":1}")
        };
    }
}

sealed class FakeHistoryHandler : HttpMessageHandler
{
    protected override async Task<HttpResponseMessage> SendAsync(HttpRequestMessage request, CancellationToken cancellationToken)
    {
        if (request.Headers.Authorization?.Parameter != "test-access-token") throw new Exception("Account History request was unauthenticated.");
        string payload;
        if (request.Method == HttpMethod.Patch)
        {
            var body = await request.Content!.ReadAsStringAsync(cancellationToken);
            if (!request.RequestUri!.AbsolutePath.EndsWith("/dst_test1", StringComparison.Ordinal) ||
                !body.Contains("\"expected_revision\":1", StringComparison.Ordinal))
                throw new Exception("Account transcript edit did not carry the expected revision.");
            payload = "{\"data\":{\"id\":\"dst_test1\",\"transcript\":\"Edited transcript\",\"revision\":2,\"language\":\"en\",\"duration_ms\":1200}}";
        }
        else if (request.RequestUri!.Query.Contains("page=1&", StringComparison.Ordinal))
            payload = "{\"items\":[{\"id\":\"dst_test1\",\"transcript\":\"Hello\",\"revision\":1,\"language\":\"en\",\"duration_ms\":1200,\"created_at\":\"2026-11-02T12:00:00Z\"}],\"pagination\":{\"hasNext\":true,\"nextPage\":2}}";
        else payload = "{\"items\":[],\"pagination\":{\"hasNext\":false}}";
        return new HttpResponseMessage(System.Net.HttpStatusCode.OK)
        {
            Content = new StringContent(payload, System.Text.Encoding.UTF8, "application/json")
        };
    }
}

sealed class FakeUsageHandler : HttpMessageHandler
{
    public int RequestCount { get; private set; }

    protected override async Task<HttpResponseMessage> SendAsync(HttpRequestMessage request, CancellationToken cancellationToken)
    {
        RequestCount++;
        if (request.Method != HttpMethod.Put || request.RequestUri!.AbsolutePath is not
            ("/v1/desktop/transcriptions/dst_usage1/usage" or
             "/v1/desktop/transcriptions/dst_usage_without_local_history/usage")
            || request.Headers.Authorization?.Parameter != "test-access-token")
            throw new Exception("Desktop usage request path, method, or authorization was wrong.");
        var body = await request.Content!.ReadAsStringAsync(cancellationToken);
        if (!body.Contains("\"app_id\":\"win:notepad\"", StringComparison.Ordinal)
            || !body.Contains("\"app_name\":\"Notepad\"", StringComparison.Ordinal)
            || !body.Contains("\"category\":\"documents\"", StringComparison.Ordinal))
            throw new Exception("Desktop usage request did not match the Mac API body.");
        return new HttpResponseMessage(System.Net.HttpStatusCode.NoContent);
    }
}

sealed class FakeContextHandler : HttpMessageHandler
{
    protected override async Task<HttpResponseMessage> SendAsync(HttpRequestMessage request, CancellationToken cancellationToken)
    {
        if (request.Headers.Authorization?.Parameter != "test-access-token")
            throw new Exception("Questionnaire request was unauthenticated.");
        var path = request.RequestUri!.AbsolutePath;
        string payload;
        if (path == "/v1/desktop/onboarding/context" && request.Method == HttpMethod.Get)
            payload = "{\"context\":null}";
        else if (path == "/v1/desktop/onboarding/context" && request.Method == HttpMethod.Put)
        {
            var body = await request.Content!.ReadAsStringAsync(cancellationToken);
            if (!body.Contains("\"expected_revision\":0", StringComparison.Ordinal)
                || !body.Contains("\"questionnaire_version\":1", StringComparison.Ordinal)
                || !body.Contains("\"platform\":\"win32\"", StringComparison.Ordinal)
                || !body.Contains("\"intent\"", StringComparison.Ordinal))
                throw new Exception("Questionnaire request body did not match the Mac API.");
            payload = "{\"context\":{\"user_id\":\"account-a\",\"revision\":1,\"questionnaire_version\":1,\"answers\":{\"intent\":{\"choices\":[\"dictation\"],\"other\":\"\",\"skipped\":false}},\"completed_at\":null,\"finished_at\":null}}";
        }
        else if (path == "/v1/desktop/onboarding/completion" && request.Method == HttpMethod.Put)
            payload = "{\"context\":{\"user_id\":\"account-a\",\"revision\":2,\"questionnaire_version\":1,\"answers\":{},\"completed_at\":\"2026-11-02T12:00:00Z\",\"finished_at\":\"2026-11-02T12:01:00Z\"}}";
        else throw new Exception("Unexpected questionnaire endpoint.");
        return new HttpResponseMessage(System.Net.HttpStatusCode.OK)
        {
            Content = new StringContent(payload, System.Text.Encoding.UTF8, "application/json")
        };
    }
}
