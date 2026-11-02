import Foundation
import Observation
import VoiceLabCore

/// Runs the actual app model without opening windows, recording, or accessing the network.
@main
struct OnboardingObservationRegression {
    @MainActor
    static func main() throws {
        let suite = "VoiceLab.ObservationRegression.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let preferences = Preferences(defaults: defaults)
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let library = LibraryModel(store: LibraryStore(directory: directory))
        let api = UnusedAPI()
        let dictation = DictationModel(api: api, library: library, preferences: preferences)
        let model = OnboardingModel(
            api: api, library: library, preferences: preferences, dictation: dictation)

        precondition(model.step == .welcome && model.canContinue)
        try expectObservedTransition(model, to: .signIn) { model.next() }
        precondition(!model.canContinue, "Sign-in must still gate the following step.")
        try expectObservedTransition(model, to: .welcome) { model.back() }
        try expectObservedTransition(model, to: .signIn) { model.next() }
        try expectObservedTransition(model, to: .welcome) { model.reset() }
        print("PASS: welcome → sign-in, back, repeat and reset all notify Observation.")
    }

    @MainActor
    private static func expectObservedTransition(
        _ model: OnboardingModel, to expected: OnboardingStep, action: () -> Void
    ) throws {
        let change = ChangeFlag()
        withObservationTracking {
            _ = model.step
        } onChange: {
            change.mark()
        }
        action()
        guard model.step == expected, change.didChange else {
            throw RegressionFailure(
                message:
                    "Expected observable transition to \(expected.rawValue); actual=\(model.step.rawValue), notified=\(change.didChange)"
            )
        }
    }
}

private struct RegressionFailure: Error { let message: String }

private final class ChangeFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var value = false
    var didChange: Bool { lock.withLock { value } }
    func mark() { lock.withLock { value = true } }
}

private struct UnusedAPI: DesktopServing, OnboardingServing {
    func usage() async throws -> Usage { throw VoiceLabError.invalidResponse }
    func history(page: Int) async throws -> HistoryPage { throw VoiceLabError.invalidResponse }
    func transcribe(file: URL, language: DictationLanguage) async throws -> Transcript {
        throw VoiceLabError.invalidResponse
    }
    func update(_ transcript: Transcript, text: String) async throws -> Transcript {
        throw VoiceLabError.invalidResponse
    }
    func onboardingProfile() async throws -> OnboardingProfile? { throw VoiceLabError.invalidResponse }
    func saveOnboarding(
        _ answers: OnboardingAnswers, completedAt: Date
    ) async throws -> OnboardingProfile { throw VoiceLabError.invalidResponse }
}
