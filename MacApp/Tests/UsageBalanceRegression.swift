import Foundation
import VoiceLabCore

/// Real app/recording lifecycle and profile balance; capture and server are deterministic.
@main
struct UsageBalanceRegression {
    @MainActor static func main() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("Echo-Usage-\(UUID())")
        let suite = "Echo.Usage.\(UUID())"
        let defaults = UserDefaults(suiteName: suite)!
        defer {
            try? FileManager.default.removeItem(at: root)
            defaults.removePersistentDomain(forName: suite)
        }
        let secrets = BalanceSecrets()
        struct Session: Encodable {
            let refreshToken = "drt_balance_123456789"
            let refreshExpiresAt = Date.now.addingTimeInterval(3600)
            let account = Account(id: "balance-user", email: "test@example.com", name: "Test")
            let accessToken = "access_balance_123456789"
            let accessExpiresAt = Date.now.addingTimeInterval(900)
        }
        try secrets.write(JSONEncoder().encode(Session()), key: "session")
        let auth = Authentication(http: HTTPClient(), secrets: secrets)
        let api = BalanceAPI()
        let library = LibraryModel(store: LibraryStore(directory: root, secrets: secrets))
        try await library.open(accountID: "balance-user")
        var progress = OnboardingProgress()
        progress.completedAt = .now
        progress.profileLoaded = true
        library.saveOnboarding(progress)
        try await library.flush()
        let preferences = Preferences(defaults: defaults)
        preferences.retainHistory = false
        preferences.autoPaste = true
        let target = TextInsertion.Target(processID: 123)
        target.usageContext = DesktopUsageContext.classify(bundleID: "com.tinyspeck.slackmacgap", appName: "Slack")
        var insertionOutcome = "Matn joylandi"
        let dictation = DictationModel(
            api: api, library: library, preferences: preferences,
            recorder: AudioRecorder(makeCapture: { BalanceCapture() }), captureTarget: { target },
            insertText: { _, _, _ in insertionOutcome })
        let app = AppModel(auth: auth, api: api, preferences: preferences, library: library,
                           presentSignIn: {}, dictation: dictation)
        await app.restoreSession()
        try await eventually { app.usage?.remaining == 600 }
        try await record(dictation)
        try await eventually { app.usage?.remaining == 480 }
        precondition(app.usage?.remainingFraction == 0.8 && app.usage!.remaining / 60 == 8)
        precondition(library.snapshot.transcripts.isEmpty)
        precondition(library.snapshot.pendingUsage?["dst_120"]?.category == .work)
        print("PASS: confirmed insertion queues its captured app even with local history disabled")
        print("PASS: two-minute dictation updates 10 → 8 minutes and the ring, with history disabled")

        try await record(dictation, practice: true)
        try await eventually { app.usage?.remaining == 360 }
        precondition(library.snapshot.pendingUsage?.count == 1)
        print("PASS: onboarding practice never adds desktop usage")
        print("PASS: billable onboarding practice refreshes the same balance")
        insertionOutcome = "Matn nusxalandi"

        // A GET started before STT completes must never restore the old balance.
        let staleGate = BalanceGate()
        await api.blockNextRead(staleGate)
        let before = await api.readCount
        let staleRead = Task { await app.refreshUsage() }
        try await waitForRead(api, after: before)
        try await record(dictation)
        try await eventually { app.usage?.remaining == 240 }
        await staleGate.open()
        await staleRead.value
        precondition(app.usage?.remaining == 240)
        precondition(library.snapshot.pendingUsage?.count == 1)
        print("PASS: clipboard-only results do not count as application use")
        print("PASS: a late pre-recording response cannot overwrite the updated balance")

        let sharedGate = BalanceGate()
        await api.blockNextRead(sharedGate)
        let readCount = await api.readCount
        let reads = (0..<24).map { _ in Task { await app.refreshUsage() } }
        try await waitForRead(api, after: readCount)
        try await Task.sleep(for: .milliseconds(30))
        let concurrentReads = await api.readCount
        precondition(concurrentReads == readCount + 1)
        await sharedGate.open()
        for read in reads { await read.value }
        print("PASS: concurrent profile/foreground refreshes share one request")

        await api.failTranscription(commit: false)
        let priorReads = await api.readCount
        try await record(dictation, failure: true)
        try await waitForRead(api, after: priorReads)
        precondition(app.usage?.remaining == 240)
        print("PASS: failed unbilled audio does not reduce the balance locally")

        await api.failTranscription(commit: true)
        try await record(dictation, failure: true)
        try await eventually { app.usage?.remaining == 120 }
        print("PASS: response loss after settlement reconciles balance without resending audio")

        await api.setUsageUnavailable(true)
        await app.refreshUsage()
        precondition(app.usage?.remaining == 120 && app.usageRefreshError != nil && !app.needsSignIn)
        await api.setUsageUnavailable(false)
        await app.refreshUsage()
        precondition(app.usage?.remaining == 120 && app.usageRefreshError == nil)
        print("PASS: unavailable usage keeps the last balance and clears its warning after recovery")
        let onboarding = AppOnboardingSession(app: app)
        let sample = root.appendingPathComponent("onboarding.wav")
        await api.failTranscription(commit: false)
        let beforeTrial = await api.readCount
        do {
            _ = try await onboarding.transcribe(file: sample)
            preconditionFailure("Expected the trial transport to fail")
        } catch is URLError {}
        try await waitForRead(api, after: beforeTrial)
        precondition(app.usage?.remaining == 120)
        _ = try await onboarding.transcribe(file: sample)
        try await eventually { app.usage?.remaining == 0 }
        let boundOwner = await api.trialOwner
        precondition(boundOwner == "balance-user" && library.snapshot.pendingUsage?.count == 1)
        print("PASS: new onboarding binds speech to its account and reconciles usage after success or response failure")

        await api.rejectNextWithQuota()
        try await record(dictation, failure: true)
        precondition(dictation.needsPlanUpgrade && dictation.canRetry)
        print("PASS: quota failure offers a plan upgrade and retains the recording for explicit retry")
        dictation.retry()
        try await eventually { dictation.phase == .idle }
        precondition(!dictation.needsPlanUpgrade && dictation.error == nil)
        await api.rejectNextWithQuota()
        try await record(dictation, failure: true)
        dictation.discard()
        precondition(!dictation.needsPlanUpgrade && dictation.error == nil)
        await api.failTranscription(commit: false)
        try await record(dictation, failure: true)
        precondition(!dictation.needsPlanUpgrade)
        print("PASS: upgrade state clears after retry/discard and does not leak into network failures")
        _ = await app.shutdown()
    }

    @MainActor static func record(_ model: DictationModel, practice: Bool = false, failure: Bool = false) async throws {
        if practice { model.togglePractice() } else { model.toggle() }
        try await eventually { model.phase == .recording || model.phase == .failed }
        precondition(model.phase == .recording, model.error ?? "Recording did not start")
        model.stop()
        try await eventually { model.phase == .idle || model.phase == .failed }
        precondition(model.phase == (failure ? .failed : .idle), model.error ?? "Unexpected transcription state")
    }

    @MainActor static func eventually(_ condition: () -> Bool) async throws {
        for _ in 0..<200 {
            if condition() { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        preconditionFailure("Timed out waiting for balance")
    }

    private static func waitForRead(_ api: BalanceAPI, after count: Int) async throws {
        for _ in 0..<200 {
            if await api.readCount > count { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        preconditionFailure("Usage refresh was not requested")
    }
}

private actor BalanceGate {
    private var continuation: CheckedContinuation<Void, Never>?
    private var opened = false
    func wait() async {
        if opened { return }
        await withCheckedContinuation { continuation = $0 }
    }
    func open() { opened = true; continuation?.resume(); continuation = nil }
}

private actor BalanceAPI: DesktopServing, OnboardingServing, OnboardingExperienceServing {
    private var used = 0
    private var nextGate: BalanceGate?
    private var unavailable = false
    private var failureCommit: Bool?
    private var quotaRejection = false
    private(set) var readCount = 0
    private(set) var trialOwner: String?
    func transcribe(file: URL, language: DictationLanguage, forAccount accountID: String?) async throws -> Transcript {
        trialOwner = accountID
        return try await transcribe(file: file, language: language)
    }
    func onboardingContext(forAccount accountID: String?) async throws -> OnboardingContext? { nil }
    func saveOnboardingContext(_ submission: ContextSubmission, forAccount accountID: String?) async throws -> OnboardingContext { throw VoiceLabError.invalidResponse }
    func completeOnboarding(forAccount accountID: String) async throws {}
    func blockNextRead(_ gate: BalanceGate) { nextGate = gate }
    func failTranscription(commit: Bool) { failureCommit = commit }
    func rejectNextWithQuota() { quotaRejection = true }
    func setUsageUnavailable(_ value: Bool) { unavailable = value }
    func usage() async throws -> Usage {
        readCount += 1
        if unavailable { throw URLError(.notConnectedToInternet) }
        let snapshot = try HTTPClient.decode(Usage.self, data: Data("""
            {"enabled":true,"plan_name":"Pro","usage_limit_seconds":600,
             "used_seconds":\(used),"remaining_seconds":\(max(0,600-used)),"reserved_seconds":0}
            """.utf8))
        let gate = nextGate
        nextGate = nil
        if let gate { await gate.wait() } // Deliberately ignores cancellation.
        return snapshot
    }
    func transcribe(file: URL, language: DictationLanguage) async throws -> Transcript {
        if quotaRejection {
            quotaRejection = false
            throw VoiceLabError.dictationLimitReached(requestID: "quota-test")
        }
        let failure = failureCommit
        failureCommit = nil
        if failure != false { used += 120 }
        if failure != nil { throw URLError(.networkConnectionLost) }
        return Transcript(id: "dst_\(used)", text: "Salom", language: "uz", durationMS: 120_000, revision: 1)
    }
    func history(page: Int) async throws -> HistoryPage { throw VoiceLabError.invalidResponse }
    func update(_ transcript: Transcript, text: String) async throws -> Transcript { throw VoiceLabError.invalidResponse }
    func onboardingProfile() async throws -> OnboardingProfile? { nil }
    func saveOnboarding(_ answers: OnboardingAnswers, completedAt: Date) async throws -> OnboardingProfile { throw VoiceLabError.invalidResponse }
}

private actor BalanceCapture: MicrophoneCapturing {
    func devices() async -> [MicrophoneDevice] { [] }
    func start(deviceID: String, recordingURL: URL?, onFrame: @escaping @Sendable (MicrophoneMeterFrame) -> Void,
               onFailure: @escaping @Sendable (MicrophoneCaptureError) -> Void) async throws -> String {
        if let recordingURL { try Data("test audio".utf8).write(to: recordingURL) }
        return "test"
    }
    func stop() async {}
}

private final class BalanceSecrets: SecretStore, @unchecked Sendable {
    private let lock = NSLock()
    private var values: [String: Data] = [:]
    func read(_ key: String) throws -> Data? { lock.withLock { values[key] } }
    func write(_ data: Data, key: String) throws { lock.withLock { values[key] = data } }
    func remove(_ key: String) throws { lock.withLock { values[key] = nil } }
}
