import Foundation
import Testing

@testable import VoiceLabCore

private actor UsageTransport: HTTPTransport {
    enum Reply: Sendable {
        case failure(URLError.Code)
        case response(Int)
    }
    private var replies: [Reply]
    private(set) var requests: [URLRequest] = []
    init(_ replies: [Reply]) { self.replies = replies }

    func send(_ request: URLRequest, uploadFile: URL?) async throws -> (Data, HTTPURLResponse) {
        requests.append(request)
        guard !replies.isEmpty else { throw URLError(.badServerResponse) }
        switch replies.removeFirst() {
        case .failure(let code): throw URLError(code)
        case .response(let status):
            return (
                Data(#"{"desktop_stt":{"enabled":true,"remaining_seconds":600}}"#.utf8),
                HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!
            )
        }
    }
}

@Suite struct UsageRecoveryTests {
    @Test(arguments: [URLError.timedOut, URLError.networkConnectionLost])
    func usageRecoversOnceWithoutChangingCredentials(_ code: URLError.Code) async throws {
        let transport = UsageTransport([.failure(code), .response(200)])
        let result = try await HTTPClient(transport: transport).request(
            "/v1/desktop/usage", token: "fake-access-token")
        #expect(!result.isEmpty)
        let requests = await transport.requests
        #expect(requests.count == 2)
        #expect(requests[0] == requests[1])
    }

    @Test func repeatedTimeoutStopsAfterOneRetry() async {
        let transport = UsageTransport([.failure(.timedOut), .failure(.timedOut), .response(200)])
        await #expect(throws: URLError.self) {
            try await HTTPClient(transport: transport).request("/v1/desktop/usage")
        }
        #expect(await transport.requests.count == 2)
    }

    @Test(arguments: [URLError.notConnectedToInternet, URLError.cancelled, URLError.secureConnectionFailed])
    func offlineCancellationAndTLSFailureAreNotRetried(_ code: URLError.Code) async {
        let transport = UsageTransport([.failure(code), .response(200)])
        await #expect(throws: URLError.self) {
            try await HTTPClient(transport: transport).request("/v1/desktop/usage")
        }
        #expect(await transport.requests.count == 1)
    }

    @Test(arguments: [
        "/api/v2/auth/desktop/token",
        "/api/v2/auth/desktop/authorizations",
        "/v1/desktop/stt",
        "/v1/desktop/transcriptions/dst_example",
        "/v1/desktop/usage",
    ])
    func mutatingRequestsAreNeverReplayed(_ path: String) async {
        let transport = UsageTransport([.failure(.timedOut), .response(200)])
        await #expect(throws: URLError.self) {
            try await HTTPClient(transport: transport).request(
                path, method: path.contains("transcriptions") ? "PATCH" : "POST")
        }
        #expect(await transport.requests.count == 1)
    }

    @Test(arguments: [401, 429, 500, 503])
    func serverRejectionsDoNotTriggerNetworkRetry(_ status: Int) async {
        let transport = UsageTransport([.response(status), .response(200)])
        await #expect(throws: VoiceLabError.self) {
            try await HTTPClient(transport: transport).request("/v1/desktop/usage")
        }
        #expect(await transport.requests.count == 1)
    }

    @Test func cancellationDuringDelayPreventsRetry() async {
        let transport = UsageTransport([.failure(.timedOut), .response(200)])
        let task = Task { try await HTTPClient(transport: transport).request("/v1/desktop/usage") }
        while await transport.requests.isEmpty { await Task.yield() }
        task.cancel()
        await #expect(throws: CancellationError.self) { try await task.value }
        #expect(await transport.requests.count == 1)
    }
}
