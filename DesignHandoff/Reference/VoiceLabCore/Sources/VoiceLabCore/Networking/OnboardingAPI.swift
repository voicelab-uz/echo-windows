import Foundation

public protocol OnboardingServing: Sendable {
    func onboardingProfile() async throws -> OnboardingProfile?
    func saveOnboarding(_ answers: OnboardingAnswers, completedAt: Date) async throws -> OnboardingProfile
}

extension DesktopAPI: OnboardingServing {
    public func onboardingProfile() async throws -> OnboardingProfile? {
        do {
            let data = try await request("/v1/desktop/onboarding")
            return try decodeOnboarding(data)
        } catch VoiceLabError.server(let status, _, _) where status == 404 {
            return nil
        }
    }

    public func saveOnboarding(
        _ answers: OnboardingAnswers, completedAt: Date
    ) async throws -> OnboardingProfile {
        let payload = OnboardingPayload(
            answers: answers.validated(), completedAt: completedAt, appVersion: appVersion)
        let encoder = JSONEncoder()
        encoder.keyEncodingStrategy = .convertToSnakeCase
        let data = try await request(
            "/v1/desktop/onboarding", method: "PUT", body: encoder.encode(payload))
        return try decodeOnboarding(data)
    }

    private func decodeOnboarding(_ data: Data) throws -> OnboardingProfile {
        struct Envelope: Decodable { let onboarding: OnboardingProfile }
        let profile = try HTTPClient.decode(Envelope.self, data: data).onboarding
        guard profile.revision > 0, !profile.completedAt.isEmpty else { throw VoiceLabError.invalidResponse }
        return profile
    }
}

private struct OnboardingPayload: Encodable {
    let role: String
    let useCases: [String]
    let dictationLanguage: String
    let writingStyle: String
    let uiLanguage: String
    let theme: String
    let appVersion: String
    let platform = "darwin"
    let completedAt: String

    init(answers: OnboardingAnswers, completedAt: Date, appVersion: String) {
        role = answers.role
        useCases = answers.useCases
        dictationLanguage = answers.dictationLanguage
        writingStyle = answers.writingStyle
        uiLanguage = answers.uiLanguage
        theme = answers.theme
        self.appVersion = appVersion
        self.completedAt = ISO8601DateFormatter().string(from: completedAt)
    }
}
