import Foundation
import Testing

@testable import VoiceLabCore

private let oldAccess = "access_cached_123456789"
private let newAccess = "access_rotated_123456789"
private let oldRefresh = "drt_cached_123456789"
private let newRefresh = "drt_next_123456789"
private let authResponse = """
    {"authorization_url":"https://voicelab.uz/app/sign-in?desktop_auth_id=dau_test",
     "authorization_request_id":"dau_test","expires_in":300}
    """
private let accessRejected = #"{"error":{"code":"invalid_desktop_token","message":"Expired access"}}"#
private let refreshRejected = #"{"error":{"code":"invalid_refresh_token","message":"Revoked refresh"}}"#
private let limited = #"{"error":{"code":"rate_limited","message":"Wait"}}"#
private let usageResponse = #"{"desktop_stt":{"enabled":true,"remaining_seconds":600}}"#
private let transcriptResponse = #"{"text":"Salom","language":"uz","duration_ms":1000}"#

private struct StoredSession: Codable {
    var pendingRefreshID: String?
    var refreshRetrySupported: Bool?
    let refreshToken: String
    let refreshExpiresAt: Date
    let account: Account
    let accessToken: String?
    let accessExpiresAt: Date?
}

private final class TestSecrets: SecretStore, @unchecked Sendable {
    private let lock = NSLock()
    private var data: [String: Data] = [:]
    private var failingWrites = 0
    private var failingReads = false
    private var failingRemovals = 0
    func failWrites(_ count: Int) { lock.withLock { failingWrites = count } }
    func failReads(_ fail: Bool) { lock.withLock { failingReads = fail } }
    func failRemovals(_ count: Int) { lock.withLock { failingRemovals = count } }
    func read(_ key: String) throws -> Data? {
        try lock.withLock {
            if failingReads { throw VoiceLabError.storage("locked") }
            return data[key]
        }
    }
    func write(_ value: Data, key: String) throws {
        try lock.withLock {
            if failingWrites > 0 {
                failingWrites -= 1
                throw VoiceLabError.storage("locked")
            }
            data[key] = value
        }
    }
    func remove(_ key: String) throws {
        try lock.withLock {
            if failingRemovals > 0 {
                failingRemovals -= 1
                throw VoiceLabError.storage("locked")
            }
            data[key] = nil
        }
    }
}

private actor ResponseGate {
    private var opened = false
    private var waiters: [CheckedContinuation<Void, Never>] = []
    func wait() async {
        if opened { return }
        await withCheckedContinuation { waiters.append($0) }
    }
    func open() {
        opened = true
        let pending = waiters
        waiters.removeAll()
        pending.forEach { $0.resume() }
    }
}

private struct TestReply: Sendable {
    var status: Int = 200
    var body: String = ""
    var headers: [String: String] = [:]
    var failure: URLError.Code?
    var gate: ResponseGate?
}

private actor AuthTransport: HTTPTransport {
    struct Call: Sendable {
        let request: URLRequest
        let upload: Data?
        let date: Date
    }
    private let reply: @Sendable (URLRequest, Int) -> TestReply
    private(set) var calls: [Call] = []
    private var waiters: [(Int, CheckedContinuation<Void, Never>)] = []
    init(_ reply: @escaping @Sendable (URLRequest, Int) -> TestReply) { self.reply = reply }
    func waitForCalls(_ count: Int) async {
        if calls.count >= count { return }
        await withCheckedContinuation { waiters.append((count, $0)) }
    }
    func send(_ request: URLRequest, uploadFile: URL?) async throws -> (Data, HTTPURLResponse) {
        calls.append(
            Call(request: request, upload: try uploadFile.map { try Data(contentsOf: $0) }, date: .now))
        let response = reply(request, calls.count)
        let ready = waiters.filter { calls.count >= $0.0 }
        waiters.removeAll { calls.count >= $0.0 }
        ready.forEach { $0.1.resume() }
        if let gate = response.gate { await gate.wait() }
        if let failure = response.failure { throw URLError(failure) }
        return (
            Data(response.body.utf8),
            HTTPURLResponse(
                url: request.url!, statusCode: response.status, httpVersion: nil,
                headerFields: response.headers)!
        )
    }
}

private func rotation() -> String {
    // Production refresh responses omit `user`; preserve the saved account.
    """
    {"access_token":"\(newAccess)","refresh_token":"\(newRefresh)","token_type":"Bearer",
     "expires_in":900,"refresh_expires_in":2592000}
    """
}

private func seed(
    _ secrets: TestSecrets, expiry: Date = .distantPast, refreshExpiry: Date = .now.addingTimeInterval(3600),
    retrySupported: Bool = false
) throws {
    try secrets.write(Data("installation-test".utf8), key: "installation")
    try secrets.write(
        JSONEncoder().encode(
            StoredSession(
                pendingRefreshID: nil, refreshRetrySupported: retrySupported,
                refreshToken: oldRefresh, refreshExpiresAt: refreshExpiry,
                account: Account(id: "account-a", email: "test@example.com", name: "Test"),
                accessToken: oldAccess, accessExpiresAt: expiry)), key: "session")
}

private func stored(_ secrets: TestSecrets) throws -> StoredSession {
    try JSONDecoder().decode(StoredSession.self, from: #require(try secrets.read("session")))
}

private func fields(_ request: URLRequest) throws -> [String: String] {
    try JSONDecoder().decode([String: String].self, from: #require(request.httpBody))
}

private func callback(_ attempt: AuthorizationAttempt) -> URL {
    URL(string: "\(attempt.redirectURI)?code=dac_test&state=\(attempt.state)")!
}

@Suite(.timeLimit(.minutes(1)))
struct AuthenticationLifecycleTests {
    @Test func updateRelaunchPreventsNewRotationUntilCanceled() async throws {
        let secrets = TestSecrets()
        try seed(secrets, expiry: .now.addingTimeInterval(900))
        let transport = AuthTransport { _, _ in TestReply(body: rotation()) }
        let auth = Authentication(http: HTTPClient(transport: transport), secrets: secrets)
        _ = try await auth.restore()
        try await auth.prepareForRelaunch()
        await #expect(throws: CancellationError.self) { try await auth.token(forceRefresh: true) }
        await #expect(throws: CancellationError.self) { try await auth.beginAuthorization() }
        await #expect(throws: CancellationError.self) { try await auth.logout() }
        #expect(await transport.calls.isEmpty)
        await auth.cancelRelaunch()
        #expect(try await auth.token() == oldAccess)
        #expect(try stored(secrets).refreshToken == oldRefresh)
    }

    @Test func updateRelaunchDefersWhileRefreshIsInFlight() async throws {
        let secrets = TestSecrets()
        try seed(secrets)
        let gate = ResponseGate()
        let transport = AuthTransport { _, _ in TestReply(body: rotation(), gate: gate) }
        let auth = Authentication(http: HTTPClient(transport: transport), secrets: secrets)
        _ = try await auth.restore()
        let refresh = Task { try await auth.token() }
        await transport.waitForCalls(1)
        await #expect(throws: UpdateRestartError.blocked([.authentication])) { try await auth.prepareForRelaunch() }
        await gate.open()
        _ = try await refresh.value
        try await auth.prepareForRelaunch()
        #expect(try stored(secrets).refreshToken == newRefresh)
    }

    @Test func updateRelaunchMustPersistRotatedCredentialsAndCanRetryAfterKeychainUnlock() async throws {
        let secrets = TestSecrets()
        try seed(secrets)
        let transport = AuthTransport { _, _ in
            secrets.failWrites(2)
            return TestReply(body: rotation())
        }
        let auth = Authentication(http: HTTPClient(transport: transport), secrets: secrets)
        _ = try await auth.restore()
        await #expect(throws: VoiceLabError.self) { try await auth.token() }
        await #expect(throws: VoiceLabError.self) { try await auth.prepareForRelaunch() }
        #expect(try stored(secrets).refreshToken == oldRefresh)
        // No second network rotation; the successor held in memory must be saved.
        try await auth.prepareForRelaunch()
        #expect(try stored(secrets).refreshToken == newRefresh)
        #expect(await transport.calls.count == 1)
        await auth.cancelRelaunch()
        #expect(try await auth.token() == newAccess)
    }

    @Test func expiredSessionPublishesLoginRequirementEvenToLateObservers() async throws {
        let secrets = TestSecrets()
        try seed(secrets, refreshExpiry: .distantPast)
        let transport = AuthTransport { _, _ in TestReply(status: 500) }
        let auth = Authentication(http: HTTPClient(transport: transport), secrets: secrets)
        #expect(try await auth.restore() == nil)
        var events = await auth.sessionInvalidations().makeAsyncIterator()
        let event = try #require(await events.next())
        #expect(event.accountID == "account-a")
        #expect(await auth.sessionInvalidation == event)
        #expect(await transport.calls.isEmpty)
    }

    @Test func idleRefreshExpiryRequiresLoginEvenWithCachedAccess() async throws {
        let secrets = TestSecrets()
        try seed(secrets, expiry: .now.addingTimeInterval(900), refreshExpiry: .now.addingTimeInterval(0.2))
        let transport = AuthTransport { _, _ in TestReply(status: 500) }
        let auth = Authentication(http: HTTPClient(transport: transport), secrets: secrets)
        _ = try await auth.restore()
        var events = await auth.sessionInvalidations().makeAsyncIterator()
        #expect(await events.next()?.accountID == "account-a")
        await #expect(throws: VoiceLabError.signedOut) { try await auth.token() }
        #expect(try secrets.read("session") == nil)
        #expect(await transport.calls.isEmpty)
    }

    @Test func refreshRejectionSignalsLoginBeforeFailedKeychainDeletion() async throws {
        let secrets = TestSecrets()
        try seed(secrets)
        secrets.failRemovals(1)
        let transport = AuthTransport { _, _ in TestReply(status: 401, body: refreshRejected) }
        let auth = Authentication(http: HTTPClient(transport: transport), secrets: secrets)
        _ = try await auth.restore()
        await #expect(throws: VoiceLabError.self) { try await auth.token() }
        let event = try #require(await auth.sessionInvalidation)
        #expect(event.accountID == "account-a")
        await #expect(throws: VoiceLabError.signedOut) { try await auth.token() }
        #expect(await auth.sessionInvalidation == event)
        #expect(try secrets.read("session") == nil)
        #expect(await transport.calls.count == 1)
    }

    @Test func refreshResponseAfterAbsoluteExpiryCannotReopenSession() async throws {
        let secrets = TestSecrets()
        try seed(secrets, refreshExpiry: .now.addingTimeInterval(0.2))
        let gate = ResponseGate()
        let transport = AuthTransport { _, _ in TestReply(body: rotation(), gate: gate) }
        let auth = Authentication(http: HTTPClient(transport: transport), secrets: secrets)
        _ = try await auth.restore()
        var events = await auth.sessionInvalidations().makeAsyncIterator()
        let refresh = Task { try await auth.token() }
        await transport.waitForCalls(1)
        _ = await events.next()
        await gate.open()
        await #expect(throws: VoiceLabError.signedOut) { try await refresh.value }
        #expect(try secrets.read("session") == nil)
        #expect(await auth.sessionInvalidation != nil)
    }

    @Test func successfulLoginClearsPreviousInvalidation() async throws {
        let secrets = TestSecrets()
        try seed(secrets, refreshExpiry: .distantPast)
        let transport = AuthTransport { request, _ in
            TestReply(body: request.url?.path.hasSuffix("/authorizations") == true ? authResponse : tokenJSON())
        }
        let auth = Authentication(http: HTTPClient(transport: transport), secrets: secrets)
        _ = try await auth.restore()
        let previous = try #require(await auth.sessionInvalidation)
        let attempt = try await auth.beginAuthorization()
        _ = try await auth.completeAuthorization(callback: callback(attempt))
        #expect(await auth.sessionInvalidation == nil)
        #expect(await auth.sessionInvalidation != previous)
        #expect(!(try await auth.token()).isEmpty)
    }

    @Test(arguments: [403, 429, 500, 503])
    func genericRefreshErrorsDoNotForceLogin(status: Int) async throws {
        let secrets = TestSecrets()
        try seed(secrets)
        let transport = AuthTransport { _, _ in
            TestReply(status: status, body: "{}", headers: ["Retry-After": "300"])
        }
        let auth = Authentication(http: HTTPClient(transport: transport), secrets: secrets)
        _ = try await auth.restore()
        await #expect(throws: VoiceLabError.self) { try await auth.token() }
        #expect(await auth.sessionInvalidation == nil)
        #expect(try stored(secrets).refreshToken == oldRefresh)
    }

    @Test(arguments: ["", "{}", "<html>401 Unauthorized</html>",
                      #"{"error":{"code":"invalid_grant","message":"Rejected"}}"#,
                      refreshRejected])
    func everyRefresh401StopsConcurrentAndRepeatedRequests(body: String) async throws {
        let secrets = TestSecrets()
        try seed(secrets, retrySupported: true)
        let gate = ResponseGate()
        let transport = AuthTransport { _, _ in TestReply(status: 401, body: body, gate: gate) }
        let auth = Authentication(http: HTTPClient(transport: transport), secrets: secrets)
        _ = try await auth.restore()
        let tasks = (0..<100).map { _ in Task { try await auth.token() } }
        await transport.waitForCalls(1)
        await gate.open()
        for task in tasks {
            await #expect(throws: VoiceLabError.signedOut) { try await task.value }
        }
        for _ in 0..<100 {
            await #expect(throws: VoiceLabError.signedOut) { try await auth.token(forceRefresh: true) }
        }
        #expect(await transport.calls.count == 1)
        #expect(await auth.sessionInvalidation?.accountID == "account-a")
        #expect(try secrets.read("session") == nil)
        #expect(try await auth.restore() == nil)
    }

    @Test(arguments: [403, 500, 503])
    func failedRefreshCircuitBoundsSuccessiveConsumersAndRecovers(status: Int) async throws {
        let clock = RefreshTestClock()
        let secrets = TestSecrets()
        try seed(secrets)
        let transport = AuthTransport { _, index in
            index < 3 ? TestReply(status: status) : TestReply(body: rotation())
        }
        let auth = Authentication(http: HTTPClient(transport: transport), secrets: secrets,
                                  refreshRetryClock: { clock.now })
        _ = try await auth.restore()
        for _ in 0..<100 {
            await #expect(throws: VoiceLabError.self) { try await auth.token(forceRefresh: true) }
        }
        #expect(await transport.calls.count == 1)
        #expect(await auth.sessionInvalidation == nil)
        clock.advance(31)
        await #expect(throws: VoiceLabError.self) { try await auth.token() }
        #expect(await transport.calls.count == 2)
        clock.advance(31) // Second failure waits 60 seconds, not another immediate burst.
        await #expect(throws: VoiceLabError.self) { try await auth.token() }
        #expect(await transport.calls.count == 2)
        clock.advance(30)
        #expect(try await auth.token() == newAccess)
        #expect(await transport.calls.count == 3)
    }

    @Test func refresh429CircuitRespectsServerDeadlineAcrossConsumers() async throws {
        let secrets = TestSecrets()
        try seed(secrets)
        let clock = RefreshTestClock()
        let transport = AuthTransport { _, _ in
            TestReply(status: 429, body: limited, headers: ["Retry-After": "300"])
        }
        let auth = Authentication(http: HTTPClient(transport: transport), secrets: secrets,
                                  refreshRetryClock: { clock.now })
        _ = try await auth.restore()
        await #expect(throws: VoiceLabError.self) { try await auth.token() }
        clock.advance(60)
        for _ in 0..<100 {
            await #expect(throws: VoiceLabError.self) { try await auth.token(forceRefresh: true) }
        }
        #expect(await transport.calls.count == 1)
        #expect(await auth.sessionInvalidation == nil)
    }

    @Test func failedNetworkRefreshIsNotRetriedByEveryFeature() async throws {
        let secrets = TestSecrets()
        try seed(secrets, retrySupported: true)
        let transport = AuthTransport { _, _ in TestReply(failure: .networkConnectionLost) }
        let auth = Authentication(http: HTTPClient(transport: transport), secrets: secrets)
        _ = try await auth.restore()
        for _ in 0..<100 {
            await #expect(throws: URLError.self) { try await auth.token() }
        }
        #expect(await transport.calls.count == 3) // One bounded idempotent refresh operation.
        #expect(await auth.sessionInvalidation == nil)
    }

    @Test func rejectedAccessIsNotResentDuringRefreshCooldown() async throws {
        let secrets = TestSecrets()
        try seed(secrets, expiry: .now.addingTimeInterval(900))
        let transport = AuthTransport { request, _ in
            request.url?.path == "/api/v2/auth/desktop/token"
                ? TestReply(status: 503)
                : TestReply(status: 401, body: accessRejected)
        }
        let http = HTTPClient(transport: transport)
        let auth = Authentication(http: http, secrets: secrets)
        let api = DesktopAPI(http: http, auth: auth)
        _ = try await auth.restore()
        for _ in 0..<100 {
            await #expect(throws: VoiceLabError.self) { try await api.usage() }
        }
        let calls = await transport.calls
        #expect(calls.count == 2) // One rejected API request, one failed refresh.
        #expect(calls.first?.request.url?.path == "/v1/desktop/usage")
        #expect(calls.last?.request.url?.path == "/api/v2/auth/desktop/token")
        #expect(await auth.sessionInvalidation == nil)
    }

    @Test func legacySessionNegotiatesRecoveryOnNextSuccessfulRefresh() async throws {
        let secrets = TestSecrets()
        try seed(secrets)
        let transport = AuthTransport { _, index in
            if index == 1 {
                return TestReply(body: rotation().replacingOccurrences(
                    of: "\"token_type\"", with: "\"refresh_retry_supported\":true,\"token_type\""))
            }
            return TestReply(failure: .timedOut)
        }
        let auth = Authentication(http: HTTPClient(transport: transport), secrets: secrets)
        _ = try await auth.restore()
        _ = try await auth.token()
        #expect(try stored(secrets).refreshRetrySupported == true)
        let restarted = Authentication(http: HTTPClient(transport: transport), secrets: secrets)
        _ = try await restarted.restore()
        await #expect(throws: URLError.self) { try await restarted.token(forceRefresh: true) }
        let calls = await transport.calls
        #expect(calls.count == 4)
        #expect(calls[0].request.value(forHTTPHeaderField: "Idempotency-Key") == nil)
        let retryID = try #require(calls[1].request.value(forHTTPHeaderField: "Idempotency-Key"))
        #expect(calls.dropFirst().allSatisfy { $0.request.value(forHTTPHeaderField: "Idempotency-Key") == retryID })
        #expect(try stored(secrets).pendingRefreshID == retryID)
    }

    @Test func concurrentNegotiatedRefreshTimeoutRecoversForAllWaiters() async throws {
        let secrets = TestSecrets()
        try seed(secrets, retrySupported: true)
        let transport = AuthTransport { _, index in
            index == 1 ? TestReply(failure: .networkConnectionLost) : TestReply(body: rotation())
        }
        let auth = Authentication(http: HTTPClient(transport: transport), secrets: secrets)
        _ = try await auth.restore()
        try await withThrowingTaskGroup(of: String.self) { group in
            for _ in 0..<24 { group.addTask { try await auth.token() } }
            for try await token in group { #expect(token == newAccess) }
        }
        let calls = await transport.calls
        #expect(calls.count == 2)
        #expect(calls[0].request.value(forHTTPHeaderField: "Idempotency-Key") == calls[1].request.value(forHTTPHeaderField: "Idempotency-Key"))
        #expect(try stored(secrets).pendingRefreshID == nil)
    }

    @Test(arguments: [URLError.Code.timedOut, .networkConnectionLost, .notConnectedToInternet])
    func negotiatedRefreshRecoversLostResponseWithoutNewRotation(failure: URLError.Code) async throws {
        let secrets = TestSecrets()
        try seed(secrets, retrySupported: true)
        let transport = AuthTransport { request, index in
            let persisted = try? stored(secrets)
            #expect(request.value(forHTTPHeaderField: "Idempotency-Key") == persisted?.pendingRefreshID)
            return index == 1 ? TestReply(failure: failure) : TestReply(body: rotation())
        }
        let auth = Authentication(http: HTTPClient(transport: transport), secrets: secrets)
        _ = try await auth.restore()
        #expect(try await auth.token() == newAccess)
        let calls = await transport.calls
        #expect(calls.count == 2)
        let key = try #require(calls[0].request.value(forHTTPHeaderField: "Idempotency-Key"))
        #expect(UUID(uuidString: key) != nil)
        #expect(calls[1].request.value(forHTTPHeaderField: "Idempotency-Key") == key)
        #expect(calls[0].request.httpBody == calls[1].request.httpBody)
        #expect(try stored(secrets).pendingRefreshID == nil)
        #expect(try stored(secrets).refreshToken == newRefresh)
    }

    @Test func pendingRotationSurvivesRestartAfterBoundedTimeouts() async throws {
        let secrets = TestSecrets()
        try seed(secrets, retrySupported: true)
        let failures = AuthTransport { _, _ in TestReply(failure: .timedOut) }
        let first = Authentication(http: HTTPClient(transport: failures), secrets: secrets)
        _ = try await first.restore()
        await #expect(throws: URLError.self) { try await first.token() }
        let pending = try #require(stored(secrets).pendingRefreshID)
        #expect(await failures.calls.count == 3)
        #expect(try stored(secrets).refreshToken == oldRefresh)
        let recovery = AuthTransport { _, _ in TestReply(body: rotation()) }
        let restarted = Authentication(http: HTTPClient(transport: recovery), secrets: secrets)
        #expect(try await restarted.restore()?.id == "account-a")
        #expect(try await restarted.token() == newAccess)
        #expect(await recovery.calls.first?.request.value(forHTTPHeaderField: "Idempotency-Key") == pending)
        #expect(try stored(secrets).pendingRefreshID == nil)
    }

    @Test(arguments: [500, 502, 503, 504])
    func negotiatedRefreshRecoversServerFailures(status: Int) async throws {
        let secrets = TestSecrets()
        try seed(secrets, retrySupported: true)
        let transport = AuthTransport { _, count in
            count == 1 ? TestReply(status: status) : TestReply(body: rotation())
        }
        let auth = Authentication(http: HTTPClient(transport: transport), secrets: secrets)
        _ = try await auth.restore()
        #expect(try await auth.token() == newAccess)
        #expect(await transport.calls.count == 2)
    }

    @Test func legacyRefreshDoesNotRetryAnAmbiguousTimeout() async throws {
        let secrets = TestSecrets()
        try seed(secrets)
        let transport = AuthTransport { _, _ in TestReply(failure: .timedOut) }
        let auth = Authentication(http: HTTPClient(transport: transport), secrets: secrets)
        _ = try await auth.restore()
        await #expect(throws: URLError.self) { try await auth.token() }
        #expect(await transport.calls.count == 1)
        #expect(await transport.calls.first?.request.value(forHTTPHeaderField: "Idempotency-Key") == nil)
        #expect(try stored(secrets).refreshToken == oldRefresh)
    }

    @Test func pendingRotationMustBeDurableBeforeNetworkRequest() async throws {
        let secrets = TestSecrets()
        try seed(secrets, retrySupported: true)
        let transport = AuthTransport { _, _ in TestReply(body: rotation()) }
        let auth = Authentication(http: HTTPClient(transport: transport), secrets: secrets)
        _ = try await auth.restore()
        secrets.failWrites(1)
        await #expect(throws: VoiceLabError.self) { try await auth.token() }
        #expect(await transport.calls.isEmpty)
        #expect(try await auth.token() == newAccess)
        #expect(await transport.calls.count == 1)
    }

    @Test func negotiatedRotationWriteFailureKeepsSuccessorInMemory() async throws {
        let secrets = TestSecrets()
        try seed(secrets, retrySupported: true)
        let transport = AuthTransport { _, _ in
            secrets.failWrites(1)
            return TestReply(body: rotation())
        }
        let auth = Authentication(http: HTTPClient(transport: transport), secrets: secrets)
        _ = try await auth.restore()
        await #expect(throws: VoiceLabError.self) { try await auth.token() }
        #expect(try await auth.token() == newAccess)
        #expect(await transport.calls.count == 1)
        #expect(try stored(secrets).pendingRefreshID == nil)
    }

    @Test func offlineLogoutClearsLocalSessionButReportsRemoteRevocationFailure() async throws {
        let secrets = TestSecrets()
        try seed(secrets, retrySupported: true)
        let transport = AuthTransport { _, _ in TestReply(failure: .notConnectedToInternet) }
        let auth = Authentication(http: HTTPClient(transport: transport), secrets: secrets)
        _ = try await auth.restore()
        await #expect(throws: URLError.self) { try await auth.logout() }
        #expect(try secrets.read("session") == nil)
        await #expect(throws: VoiceLabError.signedOut) { try await auth.token() }
    }

    @Test func relaunchUsesCachedAccessWithoutRefresh() async throws {
        let secrets = TestSecrets()
        try seed(secrets, expiry: .now.addingTimeInterval(900))
        let transport = AuthTransport { _, _ in TestReply(status: 500) }
        for _ in 0..<3 {
            let auth = Authentication(http: HTTPClient(transport: transport), secrets: secrets)
            #expect(try await auth.restore()?.id == "account-a")
            #expect(try await auth.token() == oldAccess)
        }
        #expect(await transport.calls.isEmpty)
    }

    @Test(arguments: [Date.distantPast, Date.now.addingTimeInterval(30)])
    func expiredOrExpiringAccessRotatesWithoutLosingAccount(expiry: Date) async throws {
        let secrets = TestSecrets()
        try seed(secrets, expiry: expiry)
        let transport = AuthTransport { _, _ in TestReply(body: rotation()) }
        let auth = Authentication(http: HTTPClient(transport: transport), secrets: secrets)
        _ = try await auth.restore()
        #expect(try await auth.token() == newAccess)
        let session = try stored(secrets)
        #expect(session.refreshToken == newRefresh)
        #expect(session.accessToken == newAccess)
        #expect(session.account.id == "account-a")
        let restarted = Authentication(http: HTTPClient(transport: transport), secrets: secrets)
        #expect(try await restarted.restore()?.id == "account-a")
        #expect(try await restarted.token() == newAccess)
        #expect(await transport.calls.count == 1)
    }

    @Test func concurrentConsumersAndRestorationShareOneRotation() async throws {
        let secrets = TestSecrets()
        try seed(secrets)
        let gate = ResponseGate()
        let transport = AuthTransport { _, _ in TestReply(body: rotation(), gate: gate) }
        let auth = Authentication(http: HTTPClient(transport: transport), secrets: secrets)
        _ = try await auth.restore()
        let tasks = (0..<24).map { _ in Task { try await auth.token() } }
        await transport.waitForCalls(1)
        #expect(try await auth.restore()?.id == "account-a")
        await gate.open()
        for task in tasks { #expect(try await task.value == newAccess) }
        #expect(await transport.calls.count == 1)
        #expect(try stored(secrets).refreshToken == newRefresh)
    }

    @Test func lateUnauthorizedResponseUsesAlreadyRotatedToken() async throws {
        let secrets = TestSecrets()
        try seed(secrets)
        let transport = AuthTransport { _, _ in TestReply(body: rotation()) }
        let auth = Authentication(http: HTTPClient(transport: transport), secrets: secrets)
        _ = try await auth.restore()
        _ = try await auth.token()
        #expect(try await auth.token(replacing: oldAccess) == newAccess)
        #expect(await transport.calls.count == 1)
    }

    @Test func parallelUnauthorizedReadsRefreshOnce() async throws {
        let secrets = TestSecrets()
        try seed(secrets, expiry: .now.addingTimeInterval(900))
        let gate = ResponseGate()
        let transport = AuthTransport { request, _ in
            if request.url?.path == "/api/v2/auth/desktop/token" {
                return TestReply(body: rotation(), gate: gate)
            }
            return request.value(forHTTPHeaderField: "Authorization") == "Bearer \(oldAccess)"
                ? TestReply(status: 401, body: accessRejected)
                : TestReply(body: usageResponse)
        }
        let http = HTTPClient(transport: transport)
        let auth = Authentication(http: http, secrets: secrets)
        _ = try await auth.restore()
        let api = DesktopAPI(http: http, auth: auth)
        let tasks = (0..<12).map { _ in Task { try await api.usage() } }
        await transport.waitForCalls(2)
        await gate.open()
        for task in tasks { #expect(try await task.value.enabled) }
        #expect(
            await transport.calls.filter { $0.request.url?.path == "/api/v2/auth/desktop/token" }.count == 1)
    }

    @Test func explicitAccessRejectionRetriesIdenticalUploadOnce() async throws {
        let secrets = TestSecrets()
        try seed(secrets, expiry: .now.addingTimeInterval(900))
        let transport = AuthTransport { request, _ in
            if request.url?.path == "/api/v2/auth/desktop/token" { return TestReply(body: rotation()) }
            return request.value(forHTTPHeaderField: "Authorization") == "Bearer \(oldAccess)"
                ? TestReply(status: 401, body: accessRejected) : TestReply(body: transcriptResponse)
        }
        let http = HTTPClient(transport: transport)
        let auth = Authentication(http: http, secrets: secrets)
        _ = try await auth.restore()
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID()).wav")
        defer { try? FileManager.default.removeItem(at: file) }
        try Data("fake-audio".utf8).write(to: file)
        #expect(
            try await DesktopAPI(http: http, auth: auth).transcribe(file: file, language: .uz).text == "Salom"
        )
        let calls = await transport.calls
        let uploads = calls.filter { $0.upload != nil }
        #expect(calls.count == 3)
        #expect(uploads.count == 2)
        #expect(uploads.first?.upload == uploads.last?.upload)
        #expect(uploads.allSatisfy { $0.request.httpMethod == "POST" })
        #expect(
            uploads.first?.request.value(forHTTPHeaderField: "Content-Type")
                == uploads.last?.request.value(forHTTPHeaderField: "Content-Type"))
    }

    @Test func secondAccessRejectionStopsRetryAndPreservesRefresh() async throws {
        let secrets = TestSecrets()
        try seed(secrets, expiry: .now.addingTimeInterval(900))
        let transport = AuthTransport { request, _ in
            request.url?.path == "/api/v2/auth/desktop/token"
                ? TestReply(body: rotation()) : TestReply(status: 401, body: accessRejected)
        }
        let http = HTTPClient(transport: transport)
        let auth = Authentication(http: http, secrets: secrets)
        _ = try await auth.restore()
        await #expect(throws: VoiceLabError.invalidAccessToken) {
            try await DesktopAPI(http: http, auth: auth).usage()
        }
        #expect(await transport.calls.count == 3)
        #expect(try stored(secrets).refreshToken == newRefresh)
    }

    @Test(arguments: [401, 403, 500, 503])
    func ambiguousAPIErrorNeverRotates(status: Int) async throws {
        let secrets = TestSecrets()
        try seed(secrets, expiry: .now.addingTimeInterval(900))
        let transport = AuthTransport { _, _ in TestReply(status: status, body: #"{"message":"Failure"}"#) }
        let http = HTTPClient(transport: transport)
        let auth = Authentication(http: http, secrets: secrets)
        _ = try await auth.restore()
        await #expect(throws: VoiceLabError.self) { try await DesktopAPI(http: http, auth: auth).usage() }
        #expect(await transport.calls.count == 1)
        #expect(try stored(secrets).refreshToken == oldRefresh)
    }

    @Test(arguments: [URLError.timedOut, URLError.notConnectedToInternet, URLError.networkConnectionLost])
    func networkFailureNeverLogsOutOrReplaysRefresh(code: URLError.Code) async throws {
        let secrets = TestSecrets()
        try seed(secrets)
        let transport = AuthTransport { _, _ in TestReply(failure: code) }
        let auth = Authentication(http: HTTPClient(transport: transport), secrets: secrets)
        _ = try await auth.restore()
        await #expect(throws: URLError.self) { try await auth.token() }
        #expect(await transport.calls.count == 1)
        #expect(try stored(secrets).refreshToken == oldRefresh)
    }

    @Test(arguments: [403, 500, 503])
    func nonterminalRefreshErrorsPreserveSession(status: Int) async throws {
        let secrets = TestSecrets()
        try seed(secrets)
        let transport = AuthTransport { _, _ in TestReply(status: status, body: #"{"message":"Failure"}"#) }
        let auth = Authentication(http: HTTPClient(transport: transport), secrets: secrets)
        _ = try await auth.restore()
        await #expect(throws: VoiceLabError.self) { try await auth.token() }
        #expect(await transport.calls.count == 1)
        #expect(try stored(secrets).refreshToken == oldRefresh)
    }

    @Test func rateLimitedRefreshRecoversForAllWaitersWithoutLogin() async throws {
        let secrets = TestSecrets()
        try seed(secrets)
        let transport = AuthTransport { _, index in
            index == 1
                ? TestReply(status: 429, body: limited, headers: ["Retry-After": "0"])
                : TestReply(body: rotation())
        }
        let auth = Authentication(http: HTTPClient(transport: transport), secrets: secrets)
        _ = try await auth.restore()
        let tasks = (0..<12).map { _ in Task { try await auth.token() } }
        for task in tasks { #expect(try await task.value == newAccess) }
        let calls = await transport.calls
        #expect(calls.count == 2)
        #expect(try calls.allSatisfy { try fields($0.request)["refresh_token"] == oldRefresh })
        #expect(calls[1].date.timeIntervalSince(calls[0].date) >= 1)
        #expect(try stored(secrets).refreshToken == newRefresh)
    }

    @Test func repeatedRateLimitHasABoundedRetryCount() async throws {
        let secrets = TestSecrets()
        try seed(secrets)
        let transport = AuthTransport { _, _ in
            TestReply(status: 429, body: limited, headers: ["Retry-After": "0"])
        }
        let auth = Authentication(http: HTTPClient(transport: transport), secrets: secrets)
        _ = try await auth.restore()
        await #expect(throws: VoiceLabError.self) { try await auth.token() }
        #expect(await transport.calls.count == 4)
        #expect(try stored(secrets).refreshToken == oldRefresh)
    }

    @Test func longServerCooldownIsNotIgnored() async throws {
        let secrets = TestSecrets()
        try seed(secrets)
        let transport = AuthTransport { _, _ in
            TestReply(status: 429, body: limited, headers: ["Retry-After": "180"])
        }
        let auth = Authentication(http: HTTPClient(transport: transport), secrets: secrets)
        _ = try await auth.restore()
        await #expect(throws: VoiceLabError.self) { try await auth.token() }
        #expect(await transport.calls.count == 1)
        #expect(try stored(secrets).refreshToken == oldRefresh)
    }

    @Test(arguments: [false, true])
    func interactiveLoginReportsLongCooldownWithoutWaiting(exchange: Bool) async throws {
        let transport = AuthTransport { request, _ in
            if exchange && request.url?.path.hasSuffix("/authorizations") == true {
                return TestReply(body: authResponse)
            }
            return TestReply(status: 429, body: limited, headers: ["Retry-After": "60"])
        }
        let secrets = TestSecrets()
        let auth = Authentication(http: HTTPClient(transport: transport), secrets: secrets)
        let started = ContinuousClock.now
        do {
            let attempt = try await auth.beginAuthorization()
            _ = try await auth.completeAuthorization(callback: callback(attempt))
            Issue.record("Rate-limited login must return its cooldown")
        } catch VoiceLabError.rateLimited(let until, _) {
            #expect(until.timeIntervalSinceNow > 50)
        }
        #expect(started.duration(to: .now) < .seconds(2))
        #expect(await transport.calls.count == (exchange ? 2 : 1))
        #expect(try secrets.read("session") == nil)
    }

    @Test(arguments: [60, 600])
    func surfacedCooldownRetainsOnlyUnexpiredCallback(retryAfter: Int) async throws {
        let transport = AuthTransport { request, _ in
            if request.url?.path.hasSuffix("/authorizations") == true { return TestReply(body: authResponse) }
            return TestReply(status: 429, body: limited, headers: ["Retry-After": String(retryAfter)])
        }
        let secrets = TestSecrets()
        let auth = Authentication(http: HTTPClient(transport: transport), secrets: secrets)
        let attempt = try await auth.beginAuthorization()
        let url = callback(attempt)
        await #expect(throws: VoiceLabError.self) { try await auth.completeAuthorization(callback: url) }
        #expect(await auth.canResumeAuthorization(callback: url) == (retryAfter < 300))
        #expect(await auth.canResumeAuthorization(callback: URL(string: "http://127.0.0.1/callback?state=wrong&code=wrong")!) == false)
        // Cancelling an explicit retry must invalidate its retained code too.
        await auth.cancelAuthorization()
        #expect(await auth.canResumeAuthorization(callback: url) == false)
        await #expect(throws: VoiceLabError.invalidCallback) { try await auth.completeAuthorization(callback: url) }
        #expect(await transport.calls.count == 2)
        #expect(try secrets.read("session") == nil)
    }

    @Test func codeExchangeRetainsCodeAndVerifierAcross429() async throws {
        let transport = AuthTransport { request, index in
            if request.url?.path.hasSuffix("/authorizations") == true { return TestReply(body: authResponse) }
            return index == 2
                ? TestReply(status: 429, body: limited, headers: ["Retry-After": "0"])
                : TestReply(body: tokenJSON())
        }
        let secrets = TestSecrets()
        let auth = Authentication(http: HTTPClient(transport: transport), secrets: secrets)
        let attempt = try await auth.beginAuthorization()
        #expect(try await auth.completeAuthorization(callback: callback(attempt)).id == "account-a")
        let calls = await transport.calls
        #expect(calls.count == 3)
        #expect(calls[1].request.httpBody == calls[2].request.httpBody)
        #expect(try stored(secrets).account.id == "account-a")
    }

    @Test func authorization429RecoversWithoutChangingPKCE() async throws {
        let transport = AuthTransport { _, index in
            index == 1
                ? TestReply(status: 429, body: limited, headers: ["Retry-After": "0"])
                : TestReply(body: authResponse)
        }
        let auth = Authentication(http: HTTPClient(transport: transport), secrets: TestSecrets())
        _ = try await auth.beginAuthorization()
        let calls = await transport.calls
        #expect(calls.count == 2)
        #expect(calls[0].request.httpBody == calls[1].request.httpBody)
    }

    @Test func cancelingOneCallerDoesNotCancelSharedRefreshOrUpload() async throws {
        let secrets = TestSecrets()
        try seed(secrets)
        let gate = ResponseGate()
        let transport = AuthTransport { request, _ in
            request.url?.path == "/api/v2/auth/desktop/token"
                ? TestReply(body: rotation(), gate: gate) : TestReply(body: usageResponse)
        }
        let http = HTTPClient(transport: transport)
        let auth = Authentication(http: http, secrets: secrets)
        _ = try await auth.restore()
        let canceled = Task { try await DesktopAPI(http: http, auth: auth).usage() }
        await transport.waitForCalls(1)
        canceled.cancel()
        let survivor = Task { try await auth.token() }
        await gate.open()
        await #expect(throws: CancellationError.self) { try await canceled.value }
        #expect(try await survivor.value == newAccess)
        #expect(await transport.calls.count == 1)
    }

    @Test func logoutDrainsRotationAndRevokesNewestRefresh() async throws {
        let secrets = TestSecrets()
        try seed(secrets)
        let gate = ResponseGate()
        let transport = AuthTransport { request, _ in
            request.url?.path.hasSuffix("/logout") == true
                ? TestReply(status: 204)
                : TestReply(body: rotation(), gate: gate)
        }
        let auth = Authentication(http: HTTPClient(transport: transport), secrets: secrets)
        _ = try await auth.restore()
        let refresh = Task { try await auth.token() }
        await transport.waitForCalls(1)
        let logout = Task { try await auth.logout() }
        await gate.open()
        _ = try await refresh.value
        try await logout.value
        #expect(try secrets.read("session") == nil)
        let calls = await transport.calls
        #expect(calls.count == 2)
        #expect(try fields(calls[1].request)["refresh_token"] == newRefresh)
        #expect(calls[1].request.value(forHTTPHeaderField: "Authorization") == "Bearer \(newAccess)")
        #expect(try Set(fields(calls[1].request).keys) == ["refresh_token", "installation_id"])
        await #expect(throws: VoiceLabError.signedOut) { try await auth.token() }
    }

    @Test func keychainWriteFailureDoesNotReuseConsumedRefresh() async throws {
        let secrets = TestSecrets()
        try seed(secrets)
        let transport = AuthTransport { _, _ in TestReply(body: rotation()) }
        let auth = Authentication(http: HTTPClient(transport: transport), secrets: secrets)
        _ = try await auth.restore()
        secrets.failWrites(1)
        await #expect(throws: VoiceLabError.self) { try await auth.token() }
        #expect(try await auth.token() == newAccess)
        #expect(try stored(secrets).refreshToken == newRefresh)
        #expect(await transport.calls.count == 1)
    }

    @Test func keychainReadFailurePreservesSessionForRetry() async throws {
        let secrets = TestSecrets()
        try seed(secrets, expiry: .now.addingTimeInterval(900))
        secrets.failReads(true)
        let transport = AuthTransport { _, _ in TestReply(status: 500) }
        let auth = Authentication(http: HTTPClient(transport: transport), secrets: secrets)
        await #expect(throws: VoiceLabError.self) { try await auth.restore() }
        secrets.failReads(false)
        #expect(try await auth.restore()?.id == "account-a")
        #expect(try await auth.token() == oldAccess)
        #expect(await transport.calls.isEmpty)
    }

    @Test(arguments: [false, true])
    func onlyExplicitInvalidRefreshClearsSession(removalFails: Bool) async throws {
        let secrets = TestSecrets()
        try seed(secrets)
        if removalFails { secrets.failRemovals(1) }
        let transport = AuthTransport { _, _ in TestReply(status: 401, body: refreshRejected) }
        let auth = Authentication(http: HTTPClient(transport: transport), secrets: secrets)
        _ = try await auth.restore()
        await #expect(throws: VoiceLabError.self) { try await auth.token() }
        await #expect(throws: VoiceLabError.signedOut) { try await auth.token() }
        #expect(try secrets.read("session") == nil)
        #expect(await transport.calls.count == 1)
    }

    @Test func invalidRotatedAccountDoesNotReplaceSavedIdentity() async throws {
        let secrets = TestSecrets()
        try seed(secrets)
        let response = tokenJSON().replacingOccurrences(of: "account-a", with: "another-account")
        let transport = AuthTransport { _, _ in TestReply(body: response) }
        let auth = Authentication(http: HTTPClient(transport: transport), secrets: secrets)
        _ = try await auth.restore()
        await #expect(throws: VoiceLabError.invalidResponse) { try await auth.token() }
        #expect(try stored(secrets).account.id == "account-a")
        #expect(try stored(secrets).refreshToken == oldRefresh)
    }

    @Test func duplicateAuthorizationAndCanceledStartCannotReplacePendingAttempt() async throws {
        let gate = ResponseGate()
        let transport = AuthTransport { _, _ in TestReply(body: authResponse, gate: gate) }
        let auth = Authentication(http: HTTPClient(transport: transport), secrets: TestSecrets())
        let first = Task { try await auth.beginAuthorization() }
        await transport.waitForCalls(1)
        await #expect(throws: VoiceLabError.invalidCallback) { try await auth.beginAuthorization() }
        await auth.cancelAuthorization()
        await gate.open()
        await #expect(throws: CancellationError.self) { try await first.value }
        #expect(await transport.calls.count == 1)
        _ = try await auth.beginAuthorization()
        #expect(await transport.calls.count == 2)
    }

    @Test func cancellationAfterCodeConsumptionStillPersistsIssuedCredentials() async throws {
        let gate = ResponseGate()
        let secrets = TestSecrets()
        let transport = AuthTransport { request, _ in
            request.url?.path.hasSuffix("/authorizations") == true
                ? TestReply(body: authResponse)
                : TestReply(body: tokenJSON(), gate: gate)
        }
        let auth = Authentication(http: HTTPClient(transport: transport), secrets: secrets)
        let attempt = try await auth.beginAuthorization()
        let exchange = Task { try await auth.completeAuthorization(callback: callback(attempt)) }
        await transport.waitForCalls(2)
        exchange.cancel()
        await auth.cancelAuthorization()
        await gate.open()
        #expect(try await exchange.value.id == "account-a")
        #expect(try stored(secrets).account.id == "account-a")
        #expect(await transport.calls.count == 2)
    }

    @Test func cancelingExchangeDuringCooldownDoesNotReplayTheCode() async throws {
        let transport = AuthTransport { request, _ in
            request.url?.path.hasSuffix("/authorizations") == true
                ? TestReply(body: authResponse)
                : TestReply(status: 429, body: limited, headers: ["Retry-After": "0"])
        }
        let secrets = TestSecrets()
        let auth = Authentication(http: HTTPClient(transport: transport), secrets: secrets)
        let attempt = try await auth.beginAuthorization()
        let exchange = Task { try await auth.completeAuthorization(callback: callback(attempt)) }
        await transport.waitForCalls(2)
        exchange.cancel()
        await auth.cancelAuthorization()
        await #expect(throws: CancellationError.self) { try await exchange.value }
        #expect(await transport.calls.count == 2)
        #expect(try secrets.read("session") == nil)
    }

    @Test func freshLoginWaitsForOldRotationAndCannotBeOverwrittenByIt() async throws {
        let secrets = TestSecrets()
        try seed(secrets)
        let gate = ResponseGate()
        let loginRefresh = "drt_new_login_123456789"
        let transport = AuthTransport { request, _ in
            if request.url?.path.hasSuffix("/authorizations") == true { return TestReply(body: authResponse) }
            if (try? fields(request)["grant_type"]) == "refresh_token" {
                return TestReply(body: rotation(), gate: gate)
            }
            return TestReply(body: tokenJSON(refresh: loginRefresh))
        }
        let auth = Authentication(http: HTTPClient(transport: transport), secrets: secrets)
        _ = try await auth.restore()
        let attempt = try await auth.beginAuthorization()
        let refresh = Task { try await auth.token() }
        await transport.waitForCalls(2)
        let login = Task { try await auth.completeAuthorization(callback: callback(attempt)) }
        await gate.open()
        _ = try await refresh.value
        #expect(try await login.value.id == "account-a")
        #expect(try stored(secrets).refreshToken == loginRefresh)
        #expect(await transport.calls.count == 3)
    }

    @Test func callbackIsNotRetriedBeyondAuthorizationExpiry() async throws {
        let shortAttempt = authResponse.replacingOccurrences(
            of: "\"expires_in\":300", with: "\"expires_in\":1")
        let transport = AuthTransport { request, _ in
            request.url?.path.hasSuffix("/authorizations") == true
                ? TestReply(body: shortAttempt)
                : TestReply(status: 429, body: limited, headers: ["Retry-After": "10"])
        }
        let auth = Authentication(http: HTTPClient(transport: transport), secrets: TestSecrets())
        let attempt = try await auth.beginAuthorization()
        await #expect(throws: VoiceLabError.self) {
            try await auth.completeAuthorization(callback: callback(attempt))
        }
        #expect(await transport.calls.count == 2)
    }

    @Test func HTTPClientScopesAuthorizationAndRefreshCooldownsSeparately() async throws {
        let transport = AuthTransport { request, _ in
            request.url?.path.hasSuffix("/authorizations") == true
                ? TestReply(status: 429, body: limited, headers: ["Retry-After": "60"])
                : TestReply(body: rotation())
        }
        let http = HTTPClient(transport: transport)
        await #expect(throws: VoiceLabError.self) {
            try await http.request("/api/v2/auth/desktop/authorizations", method: "POST")
        }
        _ = try await http.request("/api/v2/auth/desktop/token", method: "POST")
        #expect(await transport.calls.count == 2)
    }

    @Test func expiredRefreshRequiresLoginButExpiredAccessDoesNotDeleteSession() async throws {
        let secrets = TestSecrets()
        try seed(secrets, refreshExpiry: .distantPast)
        let transport = AuthTransport { _, _ in TestReply(status: 500) }
        let auth = Authentication(http: HTTPClient(transport: transport), secrets: secrets)
        #expect(try await auth.restore() == nil)
        #expect(try secrets.read("session") == nil)
        #expect(await transport.calls.isEmpty)
    }

    @Test func corruptKeychainSessionIsNotSilentlyDeleted() async throws {
        let secrets = TestSecrets()
        let corrupt = Data("incomplete".utf8)
        try secrets.write(corrupt, key: "session")
        let auth = Authentication(
            http: HTTPClient(transport: AuthTransport { _, _ in TestReply() }), secrets: secrets)
        await #expect(throws: DecodingError.self) { try await auth.restore() }
        #expect(try secrets.read("session") == corrupt)
    }
}

@Suite struct NotesNetworkTests {
    private func response(_ note: Note, mutation: UUID, revision: Int = 1) -> String {
        let object: [String: Any] = [
            "id": note.id.uuidString, "title": note.title, "body": note.body,
            "is_pinned": note.isPinned, "deleted": false, "revision": revision,
            "mutation_id": mutation.uuidString, "updated_at": "2026-10-21T00:00:00.123456Z",
        ]
        return String(data: try! JSONSerialization.data(withJSONObject: object), encoding: .utf8)!
    }
    @Test func outboxCannotUseAnotherAccountsToken() async throws {
        let secrets = TestSecrets()
        try seed(secrets, expiry: .now.addingTimeInterval(900))
        let transport = AuthTransport { _, _ in TestReply(status: 500) }
        let http = HTTPClient(transport: transport)
        let auth = Authentication(http: http, secrets: secrets)
        _ = try await auth.restore()
        let api = DesktopAPI(http: http, auth: auth)
        let note = Note()
        await #expect(throws: VoiceLabError.sessionChanged) {
            try await api.saveNote(
                NoteMutation(id: note.id, note: note, expectedRevision: 0), accountID: "account-b")
        }
        await #expect(throws: VoiceLabError.sessionChanged) { try await api.notes(accountID: "account-b") }
        #expect(await transport.calls.isEmpty)
    }
    @Test func noteUploadRefreshesTokenWithoutChangingMutation() async throws {
        let secrets = TestSecrets()
        try seed(secrets, expiry: .now.addingTimeInterval(900))
        var note = Note()
        note.body = "O‘zbekcha 😊"
        note.isPinned = true
        let mutation = NoteMutation(id: note.id, note: note, expectedRevision: 0)
        let body = response(note, mutation: mutation.mutationID)
        let transport = AuthTransport { _, count in
            if count == 1 { return TestReply(status: 401, body: accessRejected) }
            if count == 2 { return TestReply(body: rotation()) }
            return TestReply(body: body)
        }
        let http = HTTPClient(transport: transport)
        let auth = Authentication(http: http, secrets: secrets)
        _ = try await auth.restore()
        let api = DesktopAPI(http: http, auth: auth)
        let saved = try await api.saveNote(mutation, accountID: "account-a")
        #expect(saved.body == note.body && saved.isPinned && saved.date != nil)
        let calls = await transport.calls
        #expect(calls.count == 3)
        #expect(calls[0].request.httpBody == calls[2].request.httpBody)
        #expect(calls[2].request.value(forHTTPHeaderField: "Authorization") == "Bearer \(newAccess)")
        let requestBody = try #require(calls[0].request.httpBody)
        let payload = try #require(JSONSerialization.jsonObject(with: requestBody) as? [String: Any])
        #expect(
            Set(payload.keys) == [
                "title", "body", "is_pinned", "deleted", "expected_revision", "mutation_id",
            ])
    }
    @Test func conflictingWriteFetchesRemoteWithoutOverwritingIt() async throws {
        let secrets = TestSecrets()
        try seed(secrets, expiry: .now.addingTimeInterval(900))
        var note = Note()
        note.body = "Other device"
        let body = response(note, mutation: UUID(), revision: 2)
        let transport = AuthTransport { _, count in
            count == 1
                ? TestReply(
                    status: 409, body: #"{"error":{"code":"note_revision_conflict","message":"Changed"}}"#)
                : TestReply(body: body)
        }
        let http = HTTPClient(transport: transport)
        let auth = Authentication(http: http, secrets: secrets)
        _ = try await auth.restore()
        let api = DesktopAPI(http: http, auth: auth)
        let result = try await api.saveNote(
            NoteMutation(id: note.id, note: note, expectedRevision: 1), accountID: "account-a")
        #expect(result.revision == 2)
        #expect(await transport.calls.map { $0.request.httpMethod } == ["PUT", "GET"])
    }
    @Test func notesPageDecodesContractAndRejectsInvalidCursor() async throws {
        let secrets = TestSecrets()
        try seed(secrets, expiry: .now.addingTimeInterval(900))
        let note = Note()
        let record = response(note, mutation: UUID())
        let body = "{\"notes\":[\(record)],\"next_cursor\":\"\(note.id.uuidString)\"}"
        let transport = AuthTransport { _, _ in TestReply(body: body) }
        let http = HTTPClient(transport: transport)
        let auth = Authentication(http: http, secrets: secrets)
        _ = try await auth.restore()
        let api = DesktopAPI(http: http, auth: auth)
        let page = try await api.notes(accountID: "account-a")
        #expect(page.notes.first?.id == note.id && page.nextCursor == note.id.uuidString)
        await #expect(throws: VoiceLabError.invalidResponse) {
            try await api.notes(cursor: "../other-account", accountID: "account-a")
        }
        #expect(await transport.calls.count == 1)
    }
}

final class RefreshTestClock: @unchecked Sendable {
    private let lock = NSLock()
    private var date = Date.now
    var now: Date { lock.withLock { date } }
    func advance(_ seconds: TimeInterval) { lock.withLock { date.addTimeInterval(seconds) } }
}
