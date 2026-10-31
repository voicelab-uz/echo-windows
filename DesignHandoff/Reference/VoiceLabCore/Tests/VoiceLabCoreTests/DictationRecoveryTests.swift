import Foundation
import Testing
@testable import VoiceLabCore

private actor DictationRecoveryTransport: HTTPTransport {
    enum Reply: Sendable {
        case rejected(Int, String, String?)
        case network(URLError.Code)
        case success
    }
    struct Attempt: Sendable {
        let request: URLRequest
        let file: URL?
        let bytes: Data?
        let time: ContinuousClock.Instant
    }
    private var replies: [Reply]
    private(set) var attempts: [Attempt] = []
    init(_ replies: [Reply]) { self.replies = replies }
    func send(_ request: URLRequest, uploadFile: URL?) async throws -> (Data, HTTPURLResponse) {
        attempts.append(Attempt(request: request, file: uploadFile,
                                bytes: try uploadFile.map { try Data(contentsOf: $0) }, time: .now))
        guard !replies.isEmpty else { throw URLError(.badServerResponse) }
        switch replies.removeFirst() {
        case .network(let code): throw URLError(code)
        case .success:
            return (Data("done".utf8), HTTPURLResponse(url: request.url!, statusCode: 200,
                                                      httpVersion: nil, headerFields: nil)!)
        case .rejected(let status, let code, let retryAfter):
            let data = try JSONSerialization.data(withJSONObject: [
                "error": ["code": code, "message": "Test rejection"], "request_id": "req_test",
            ])
            return (data, HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil,
                                         headerFields: retryAfter.map { ["Retry-After": $0] })!)
        }
    }
}

@Suite struct DictationRecoveryTests {
    @Test(arguments: ["concurrent_dictation", "stt_overloaded"])
    func briefBusyResponseRecoversWithSameAudioAndCredentials(_ code: String) async throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let audio = Data("multipart test audio".utf8)
        try audio.write(to: file)
        defer { try? FileManager.default.removeItem(at: file) }
        let transport = DictationRecoveryTransport([.rejected(429, code, "1"), .success])
        let result = try await HTTPClient(transport: transport).request(
            "/v1/desktop/stt", method: "POST", token: "test-token",
            contentType: "multipart/form-data; boundary=test", uploadFile: file)
        #expect(result == Data("done".utf8))
        let attempts = await transport.attempts
        #expect(attempts.count == 2)
        #expect(attempts[0].request == attempts[1].request)
        #expect(attempts.allSatisfy { $0.file == file && $0.bytes == audio })
        #expect(attempts[0].time.duration(to: attempts[1].time) >= .seconds(1))
    }

    @Test func repeatedContentionStopsAfterThreeRetriesAndKeepsCooldown() async {
        let transport = DictationRecoveryTransport(Array(repeating: .rejected(429, "concurrent_dictation", "1"), count: 5))
        let client = HTTPClient(transport: transport)
        for _ in 0..<2 {
            await #expect(throws: VoiceLabError.self) {
                try await client.request("/v1/desktop/stt", method: "POST")
            }
        }
        #expect(await transport.attempts.count == 4)
    }

    @Test(arguments: ["desktop_usage_limit_reached", "daily_dictation_limit_reached", "rate_limited", "unknown"])
    func other429ResponsesAreNotReplayed(_ code: String) async {
        let transport = DictationRecoveryTransport([.rejected(429, code, "1"), .success])
        await #expect(throws: VoiceLabError.self) {
            try await HTTPClient(transport: transport).request("/v1/desktop/stt", method: "POST")
        }
        #expect(await transport.attempts.count == 1)
    }

    @Test(arguments: ["desktop_usage_limit_reached", "daily_dictation_limit_reached"])
    func quotaRejectionOffersUpgradeWithoutBlockingNextRequest(_ code: String) async throws {
        let transport = DictationRecoveryTransport([.rejected(429, code, "60"), .success])
        let client = HTTPClient(transport: transport)
        await #expect(throws: VoiceLabError.dictationLimitReached(requestID: "req_test")) {
            try await client.request("/v1/desktop/stt", method: "POST")
        }
        // A user can upgrade immediately; quota is not a temporary cooldown.
        #expect(try await client.request("/v1/desktop/stt", method: "POST") == Data("done".utf8))
        #expect(await transport.attempts.count == 2)
    }

    @Test func genericRateLimitDoesNotOfferPlanUpgrade() async {
        let transport = DictationRecoveryTransport([.rejected(429, "rate_limited", "60")])
        do {
            _ = try await HTTPClient(transport: transport).request("/v1/desktop/stt", method: "POST")
            Issue.record("Expected rate limit")
        } catch let error as VoiceLabError {
            guard case .rateLimited = error else {
                Issue.record("Unexpected error: \(error)")
                return
            }
        } catch { Issue.record("Unexpected error: \(error)") }
    }

    @Test(arguments: [nil, "invalid", "60"] as [String?])
    func missingInvalidOrLongWaitDoesNotCauseEarlyRetry(_ header: String?) async {
        let transport = DictationRecoveryTransport([.rejected(429, "stt_overloaded", header), .success])
        await #expect(throws: VoiceLabError.self) {
            try await HTTPClient(transport: transport).request("/v1/desktop/stt", method: "POST")
        }
        #expect(await transport.attempts.count == 1)
    }

    @Test(arguments: [URLError.timedOut, URLError.networkConnectionLost])
    func ambiguousFailureAfterBusyResponseIsNotReplayed(_ code: URLError.Code) async {
        let transport = DictationRecoveryTransport([.rejected(429, "stt_overloaded", "1"), .network(code), .success])
        await #expect(throws: URLError.self) {
            try await HTTPClient(transport: transport).request("/v1/desktop/stt", method: "POST")
        }
        #expect(await transport.attempts.count == 2)
    }

    @Test(arguments: [401, 500, 503])
    func statusMustBe429EvenIfErrorCodeMatches(_ status: Int) async {
        let transport = DictationRecoveryTransport([.rejected(status, "stt_overloaded", "1"), .success])
        await #expect(throws: VoiceLabError.self) {
            try await HTTPClient(transport: transport).request("/v1/desktop/stt", method: "POST")
        }
        #expect(await transport.attempts.count == 1)
    }

    @Test func unrelatedEndpointDoesNotReplayMatchingError() async {
        let transport = DictationRecoveryTransport([.rejected(429, "stt_overloaded", "1"), .success])
        await #expect(throws: VoiceLabError.self) {
            try await HTTPClient(transport: transport).request("/api/v2/auth/desktop/token", method: "POST")
        }
        #expect(await transport.attempts.count == 1)
    }

    @Test func cancellationWhileWaitingPreventsUpload() async {
        let transport = DictationRecoveryTransport([.rejected(429, "concurrent_dictation", "1"), .success])
        let task = Task { try await HTTPClient(transport: transport).request("/v1/desktop/stt", method: "POST") }
        while await transport.attempts.isEmpty { await Task.yield() }
        task.cancel()
        await #expect(throws: CancellationError.self) { try await task.value }
        #expect(await transport.attempts.count == 1)
    }
}
