import Foundation
import VoiceLabCore

/// The preview owns a separate session so it never rotates the running app's credentials.
@MainActor
final class TryItSession: TryItServing, OnboardingContextServing {
    private let authentication: Authentication
    private let api: DesktopAPI
    private let browser = BrowserAuthentication()

    init() {
        let http = HTTPClient(persistAuthenticationCooldown: true)
        let authentication = Authentication(
            http: http, secrets: KeychainStore(service: "dev.echo.onboarding-preview"))
        self.authentication = authentication
        api = DesktopAPI(http: http, auth: authentication)
    }

    func restore() async throws -> Bool { try await authentication.restore() != nil }

    func signIn() async throws {
        do {
            let callback = try await browser.authenticate(using: authentication)
            try Task.checkCancellation()
            _ = try await authentication.completeAuthorization(callback: callback)
        } catch {
            await authentication.cancelAuthorization()
            throw error
        }
    }

    func onboardingContext() async throws -> OnboardingContext? { try await api.onboardingContext() }
    func saveOnboardingContext(_ submission: ContextSubmission) async throws -> OnboardingContext {
        try await api.saveOnboardingContext(submission)
    }

    func transcribe(file: URL) async throws -> Transcript {
        try await api.transcribe(file: file, language: .auto)
    }
}
