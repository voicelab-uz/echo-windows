import Foundation
import Testing
@testable import VoiceLabCore

private func contextJSON(revision: Int = 1) -> String {
    """
    {"context":{"user_id":"account-a","revision":\(revision),"questionnaire_version":1,
    "answers":{"discovery":{"choices":["friend"],"other":"","skipped":false}},
    "ui_language":"en","app_version":"1.0","platform":"darwin",
    "created_at":"2026-10-21T00:00:00Z","updated_at":"2026-10-21T00:00:00Z","completed_at":null}}
    """
}

@Test func onboardingContextDistinguishesAbsentFromUnavailable() async throws {
    let transport = StubTransport([(200, tokenJSON()), (200, #"{"context":null}"#), (404, #"{"message":"Not deployed"}"#), (200, "{}")])
    let http = HTTPClient(transport: transport)
    let auth = try await restoredAuth(http: http, secrets: MemorySecrets())
    let api = DesktopAPI(http: http, auth: auth)
    #expect(try await api.onboardingContext() == nil)
    await #expect(throws: VoiceLabError.self) { try await api.onboardingContext() }
    await #expect(throws: VoiceLabError.self) { try await api.onboardingContext() }
}

@Test func onboardingContextRetryKeepsMutationAndValidatesAcknowledgement() async throws {
    let transport = StubTransport([(200, tokenJSON()), (503, #"{"message":"Unavailable"}"#), (200, contextJSON()), (200, contextJSON(revision: 9)), (409, #"{"message":"Reload"}"#)])
    let http = HTTPClient(transport: transport)
    let auth = try await restoredAuth(http: http, secrets: MemorySecrets())
    let api = DesktopAPI(http: http, auth: auth)
    let submission = ContextSubmission(revision: 0, answers: ["discovery": ContextAnswer(choices: ["friend"])], language: "en", appVersion: "1.0", completed: false)
    await #expect(throws: VoiceLabError.self) { try await api.saveOnboardingContext(submission) }
    let saved = try await api.saveOnboardingContext(submission)
    #expect(saved.userId == "account-a" && saved.revision == 1)
    await #expect(throws: VoiceLabError.self) { try await api.saveOnboardingContext(submission) }
    do {
        _ = try await api.saveOnboardingContext(submission)
        Issue.record("A conflict must not be swallowed or retried automatically.")
    } catch VoiceLabError.server(let status, _, _) { #expect(status == 409) }
    let requests = await transport.requests
    #expect(requests.count == 5)
    for request in requests.dropFirst() {
        #expect(request.httpMethod == "PUT")
        #expect(request.url?.path == "/v1/desktop/onboarding/context")
        #expect(request.value(forHTTPHeaderField: "Authorization")?.hasPrefix("Bearer ") == true)
        let body = try #require(request.httpBody)
        let fields = try #require(JSONSerialization.jsonObject(with: body) as? [String: Any])
        #expect(fields["mutation_id"] as? String == submission.mutationId)
        #expect(fields["expected_revision"] as? Int == 0)
        #expect(fields["questionnaire_version"] as? Int == 1)
        #expect(fields["ui_language"] as? String == "en")
        #expect(fields["user_id"] == nil)
    }
}

@Test func onboardingCompletionRequiresOwnerAndServerTimestamp() async throws {
    let complete = contextJSON().replacingOccurrences(of: "\"completed_at\":null", with: "\"completed_at\":\"2026-10-21T00:00:00Z\",\"finished_at\":\"2026-10-21T00:01:00.123456Z\"")
    let wrongOwner = complete.replacingOccurrences(of: "account-a", with: "account-b")
    let transport = StubTransport([(200, tokenJSON()), (200, complete), (200, wrongOwner), (200, contextJSON())])
    let http = HTTPClient(transport: transport)
    let auth = try await restoredAuth(http: http, secrets: MemorySecrets())
    let api = DesktopAPI(http: http, auth: auth)
    try await api.completeOnboarding(forAccount: "account-a")
    await #expect(throws: VoiceLabError.self) { try await api.completeOnboarding(forAccount: "account-a") }
    await #expect(throws: VoiceLabError.self) { try await api.completeOnboarding(forAccount: "account-a") }
    await #expect(throws: VoiceLabError.self) { try await api.completeOnboarding(forAccount: "account-b") }
    let requests = await transport.requests
    #expect(requests.count == 4, "A stale account must fail before sending a completion request.")
    #expect(requests.last?.url?.path == "/v1/desktop/onboarding/completion")
    #expect(requests.last?.httpMethod == "PUT")
    #expect(requests.last?.httpBody == Data("{}".utf8))
}
