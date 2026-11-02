import Foundation
import VoiceLabCore

/// Uses the application's session, never the design preview's separate Keychain namespace.
@MainActor
final class AppOnboardingSession: TryItServing, OnboardingContextServing {
    private let app: AppModel
    init(app: AppModel) { self.app = app }
    func restore() async throws -> Bool { app.account != nil && !app.needsSignIn }
    func signIn() async throws { try await app.authenticateForOnboarding() }
    private func owner() throws -> String {
        guard let owner = app.account?.id, !app.needsSignIn, app.library.accountID == owner,
              app.library.isReady else { throw VoiceLabError.signedOut }
        return owner
    }
    func onboardingContext() async throws -> OnboardingContext? {
        let id = try owner()
        let context = try await app.onboardingAPI().onboardingContext(forAccount: id)
        guard app.account?.id == id, context == nil || context?.userId == id else { throw VoiceLabError.sessionChanged }
        return context
    }
    func saveOnboardingContext(_ submission: ContextSubmission) async throws -> OnboardingContext {
        let id = try owner()
        let context = try await app.onboardingAPI().saveOnboardingContext(submission, forAccount: id)
        guard app.account?.id == id, context.userId == id else { throw VoiceLabError.sessionChanged }
        return context
    }
    func transcribe(file: URL) async throws -> Transcript {
        let id = try owner()
        // The server may have charged for audio even if its response was lost.
        defer { app.reconcileUsageAfterDictation(owner: id) }
        let transcript = try await app.onboardingAPI().transcribe(file: file, language: .auto, forAccount: id)
        guard app.account?.id == id else { throw VoiceLabError.sessionChanged }
        if app.preferences.retainHistory { app.library.merge([transcript]) }
        return transcript
    }
}
