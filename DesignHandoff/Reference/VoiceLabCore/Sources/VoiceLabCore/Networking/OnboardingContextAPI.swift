import Foundation

public protocol OnboardingContextServing: Sendable {
    func onboardingContext() async throws -> OnboardingContext?
    func saveOnboardingContext(_ submission: ContextSubmission) async throws -> OnboardingContext
}
extension DesktopAPI: OnboardingContextServing {
    public func onboardingContext() async throws -> OnboardingContext? {
        try await onboardingContext(forAccount: nil)
    }
    public func onboardingContext(forAccount accountID: String?) async throws -> OnboardingContext? {
        // A missing deployment is an error, not an empty profile that can be skipped.
        let data = try await request("/v1/desktop/onboarding/context", accountID: accountID)
        return try contextEnvelope(data).context
    }
    public func saveOnboardingContext(_ submission: ContextSubmission) async throws -> OnboardingContext {
        try await saveOnboardingContext(submission, forAccount: nil)
    }
    public func saveOnboardingContext(_ submission: ContextSubmission, forAccount accountID: String?) async throws -> OnboardingContext {
        let encoder = JSONEncoder(); encoder.keyEncodingStrategy = .convertToSnakeCase
        let data = try await request("/v1/desktop/onboarding/context", method: "PUT", body: encoder.encode(submission), accountID: accountID)
        guard let profile = try contextEnvelope(data).context,
              profile.revision == submission.expectedRevision + 1,
              profile.answers == submission.answers,
              (profile.completedAt != nil) == submission.completed
        else { throw VoiceLabError.invalidResponse }
        return profile
    }
    private func contextEnvelope(_ data: Data) throws -> ContextEnvelope {
        let envelope = try HTTPClient.decode(ContextEnvelope.self, data: data)
        if let profile = envelope.context {
            guard profile.revision > 0, profile.questionnaireVersion == 1, !profile.userId.isEmpty,
                  Set(profile.answers.keys).isSubset(of: Set(ContextQuestion.allCases.map(\.rawValue)))
            else { throw VoiceLabError.invalidResponse }
        }
        return envelope
    }
}
private struct ContextEnvelope: Decodable {
    let context: OnboardingContext?
    enum CodingKeys: String, CodingKey { case context }
    init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        guard values.contains(.context) else { throw VoiceLabError.invalidResponse }
        context = try values.decodeIfPresent(OnboardingContext.self, forKey: .context)
    }
}

public protocol OnboardingFinishing: Sendable {
    func completeOnboarding(forAccount accountID: String) async throws
}

/// Account-bound capabilities used by the production onboarding session.
public protocol OnboardingExperienceServing: OnboardingFinishing {
    func onboardingContext(forAccount accountID: String?) async throws -> OnboardingContext?
    func saveOnboardingContext(_ submission: ContextSubmission, forAccount accountID: String?) async throws -> OnboardingContext
    func transcribe(file: URL, language: DictationLanguage, forAccount accountID: String?) async throws -> Transcript
}

extension DesktopAPI: OnboardingExperienceServing {}

extension DesktopAPI: OnboardingFinishing {
    public func completeOnboarding(forAccount accountID: String) async throws {
        let data = try await request("/v1/desktop/onboarding/completion", method: "PUT",
                                     body: Data("{}".utf8), accountID: accountID)
        guard let profile = try contextEnvelope(data).context,
              profile.userId == accountID, let finished = profile.finishedAt,
              ISO8601DateFormatter().date(from: finished) != nil ||
              Self.fractionalDate(finished) != nil else { throw VoiceLabError.invalidResponse }
    }
    private static func fractionalDate(_ value: String) -> Date? {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.date(from: value)
    }
}
