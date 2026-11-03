import Foundation
import VoiceLabCore

@main
struct OnboardingCompletionRegression {
    @MainActor
    static func main() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("Echo-Completion-\(UUID())")
        let suite = "Echo.CompletionTest.\(UUID())"
        let defaults = UserDefaults(suiteName: suite)!
        defer {
            try? FileManager.default.removeItem(at: root)
            defaults.removePersistentDomain(forName: suite)
        }
        let preferences = Preferences(defaults: defaults)
        let secrets = CompletionSecrets()
        let store = LibraryStore(directory: root, secrets: secrets)
        let library = LibraryModel(store: store)
        try await library.open(accountID: "test-account")
        var progress = OnboardingProgress()
        progress.step = .finish
        progress.profileLoaded = true
        library.saveOnboarding(progress)
        try await library.flush()

        let api = OfflineCompletionAPI()
        let dictation = DictationModel(api: api, library: library, preferences: preferences)
        let model = OnboardingModel(
            api: api, library: library, preferences: preferences, dictation: dictation)
        await model.prepare(accountID: "test-account")
        await model.finish()
        precondition(model.isCelebratingCompletion && !model.isComplete && !model.canContinue)
        let persisted = try await store.load(accountID: "test-account")
        precondition(persisted.onboarding?.completedAt != nil && persisted.onboarding?.pendingSync == true)
        precondition(model.syncNotice != nil, "Offline profile sync must not block the celebration.")
        print("PASS: durable local completion precedes celebration; offline sync does not block it.")

        await model.finish()  // Double activation must not restart completion.
        model.finishCelebration()
        model.finishCelebration()
        precondition(model.isComplete && !model.isCelebratingCompletion)
        print("PASS: acknowledging the celebration opens home exactly once.")

        await model.prepare(accountID: "test-account")
        precondition(model.isComplete && !model.isCelebratingCompletion)
        print("PASS: restarting an already completed setup does not replay the celebration.")

        try await library.restartOnboarding()
        progress.step = .finish
        library.saveOnboarding(progress)
        await model.prepare(accountID: "test-account")
        await model.finish()
        precondition(model.isCelebratingCompletion)
        model.reset()
        model.finishCelebration()  // A stale animation callback after logout must do nothing.
        precondition(!model.isComplete && !model.isCelebratingCompletion && model.step == .welcome)
        print("PASS: reset cancels celebration and stale callbacks cannot open home.")

        try await library.restartOnboarding()
        let completionAPI = FinalCompletionAPI()
        let production = OnboardingModel(api: api, library: library, preferences: preferences,
            dictation: dictation, completionAPI: completionAPI, readPermissions: { (true, true) })
        await production.prepare(accountID: "test-account")
        let finished = await production.finishExperience()
        precondition(finished && production.isComplete)
        for _ in 0..<100 {
            if production.syncNotice != nil { break }
            try await Task.sleep(for: .milliseconds(5))
        }
        precondition(production.progress.pendingSync && production.progress.completionVersion == 2)
        let savedNew = try await store.load(accountID: "test-account")
        precondition(savedNew.onboarding?.completionVersion == 2)
        let relaunched = OnboardingModel(api: api, library: library, preferences: preferences,
            dictation: dictation, completionAPI: completionAPI, readPermissions: { (true, true) })
        await relaunched.prepare(accountID: "test-account")
        precondition(relaunched.isComplete && relaunched.progress.pendingSync)
        await completionAPI.setAvailable()
        await relaunched.syncPending()
        precondition(!relaunched.progress.pendingSync && relaunched.syncNotice == nil)
        let sentOwners = await completionAPI.owners
        precondition(sentOwners.allSatisfy { $0 == "test-account" } && sentOwners.count == 2)
        print("PASS: new completion endpoint, encrypted pending flag, offline launch recovery, and account-bound retry.")

        // A parent file prevents creating the encrypted library directory.
        let blockedDirectory = root.appendingPathComponent("blocked")
        try Data("file".utf8).write(to: blockedDirectory)
        let blockedLibrary = LibraryModel(store: LibraryStore(directory: blockedDirectory, secrets: secrets))
        try await blockedLibrary.open(accountID: "test-account")
        blockedLibrary.saveOnboarding(progress)
        let blockedDictation = DictationModel(api: api, library: blockedLibrary, preferences: preferences)
        let blockedModel = OnboardingModel(
            api: api, library: blockedLibrary, preferences: preferences, dictation: blockedDictation)
        await blockedModel.prepare(accountID: "test-account")
        await blockedModel.finish()
        precondition(
            !blockedModel.isComplete && !blockedModel.isCelebratingCompletion && blockedModel.error != nil)
        print("PASS: failed local save stays on onboarding without a false success animation.")
    }
}

private final class CompletionSecrets: SecretStore, @unchecked Sendable {
    private let lock = NSLock()
    private var values: [String: Data] = [:]
    func read(_ key: String) throws -> Data? { lock.withLock { values[key] } }
    func write(_ data: Data, key: String) throws { lock.withLock { values[key] = data } }
    func remove(_ key: String) throws { lock.withLock { values[key] = nil } }
}

private struct OfflineCompletionAPI: DesktopServing, OnboardingServing {
    func usage() async throws -> Usage { throw URLError(.notConnectedToInternet) }
    func history(page: Int) async throws -> HistoryPage { throw URLError(.notConnectedToInternet) }
    func transcribe(file: URL, language: DictationLanguage) async throws -> Transcript {
        throw URLError(.notConnectedToInternet)
    }
    func update(_ transcript: Transcript, text: String) async throws -> Transcript {
        throw URLError(.notConnectedToInternet)
    }
    func onboardingProfile() async throws -> OnboardingProfile? { throw URLError(.notConnectedToInternet) }
    func saveOnboarding(_ answers: OnboardingAnswers, completedAt: Date) async throws -> OnboardingProfile {
        throw URLError(.notConnectedToInternet)
    }
}

private actor FinalCompletionAPI: OnboardingFinishing {
    var available = false
    var owners: [String] = []
    func setAvailable() { available = true }
    func completeOnboarding(forAccount accountID: String) async throws {
        owners.append(accountID)
        if !available { throw URLError(.notConnectedToInternet) }
    }
}
