import CryptoKit
import Foundation
import Security

public struct AuthorizationAttempt: Sendable {
    public let url: URL
    public let redirectURI: URL
    public let expiresAt: Date
    let verifier: String
    let state: String

    public func validate(callback: URL) throws {
        guard expiresAt > .now else { throw VoiceLabError.invalidCallback }
        _ = try PKCE.callbackCode(callback, state: state, redirectURI: redirectURI)
    }
}

public enum PKCE {
    public static func challenge(verifier: String) -> String {
        base64URL(Data(SHA256.hash(data: Data(verifier.utf8))))
    }
    public static func randomValue() throws -> String {
        var bytes = [UInt8](repeating: 0, count: 32)
        guard SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) == errSecSuccess else {
            throw VoiceLabError.storage("Tasodifiy xavfsizlik kalitini yaratib bo‘lmadi.")
        }
        return base64URL(Data(bytes))
    }
    public static func base64URL(_ data: Data) -> String {
        data.base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(
            of: "/", with: "_"
        ).replacingOccurrences(of: "=", with: "")
    }
    public static let defaultRedirectURI = URL(string: "voicelab://auth/callback")!

    public static func isAllowedRedirectURI(_ url: URL) -> Bool {
        if url == defaultRedirectURI { return true }
        return url.scheme == "http" && url.host == "127.0.0.1"
            && (1024...65535).contains(url.port ?? 0) && url.path == "/callback"
            && url.user == nil && url.password == nil && url.query == nil && url.fragment == nil
    }

    public static func callbackCode(
        _ url: URL, state: String, redirectURI: URL = defaultRedirectURI
    ) throws -> String {
        guard isAllowedRedirectURI(redirectURI),
            url.absoluteString.count <= 4096, url.scheme == redirectURI.scheme, url.host == redirectURI.host,
            url.path == redirectURI.path, url.user == nil, url.password == nil, url.port == redirectURI.port,
            url.fragment == nil,
            let parts = URLComponents(url: url, resolvingAgainstBaseURL: false),
            let items = parts.queryItems, items.count == 2,
            items.filter({ $0.name == "state" }).count == 1,
            items.filter({ $0.name == "code" }).count == 1,
            let received = items.first(where: { $0.name == "state" })?.value,
            constantTimeEqual(received, state),
            let code = items.first(where: { $0.name == "code" })?.value,
            code.range(of: "^dac_[A-Za-z0-9_-]{1,1020}$", options: .regularExpression) != nil
        else {
            throw VoiceLabError.invalidCallback
        }
        return code
    }
    private static func constantTimeEqual(_ a: String, _ b: String) -> Bool {
        let left = Array(a.utf8)
        let right = Array(b.utf8)
        guard left.count == right.count else { return false }
        return zip(left, right).reduce(UInt8(0)) { $0 | ($1.0 ^ $1.1) } == 0
    }
}

private struct SavedSession: Codable, Sendable {
    var pendingRefreshID: String?
    var refreshRetrySupported: Bool?
    let refreshToken: String
    let refreshExpiresAt: Date
    let account: Account
    // Optional for compatibility with sessions saved before access-token caching.
    let accessToken: String?
    let accessExpiresAt: Date?
}
private struct TokenResponse: Decodable, Sendable {
    let refreshRetrySupported: Bool?
    let accessToken: String
    let refreshToken: String
    let tokenType: String
    let expiresIn: Int
    let refreshExpiresIn: Int
    let user: Account?
}
private struct AuthorizationResponse: Decodable {
    let authorizationUrl: URL
    let authorizationRequestId: String
    let expiresIn: Int
}

/// Credentials are stored together in Keychain; refresh rotation is single-flight.
public actor Authentication {
    public struct SessionInvalidation: Sendable, Equatable {
        public let id: UUID
        public let accountID: String
    }

    public private(set) var sessionInvalidation: SessionInvalidation?
    private var invalidationObservers: [UUID: AsyncStream<SessionInvalidation>.Continuation] = [:]
    private var expirationTask: Task<Void, Never>?
    public static let callbackScheme = "voicelab"
    private let http: HTTPClient
    private let secrets: any SecretStore
    private let appVersion: String
    private var saved: SavedSession?
    private var accessToken: String?
    private var accessExpiry = Date.distantPast
    private var refreshTask: Task<String, Error>?
    private var refreshFailure: (error: any Error, retryAt: Date)?
    private var consecutiveRefreshFailures = 0
    private let refreshRetryClock: @Sendable () -> Date
    private var generation = UUID()
    private var pending: AuthorizationAttempt?
    private var exchanging = false
    private var needsPersistence = false
    private var needsSessionRemoval = false
    private var authorizationGeneration = UUID()
    private var authorizing: UUID?
    private var preparingForRelaunch = false
    public init(
        http: HTTPClient, secrets: any SecretStore = KeychainStore(),
        appVersion: String? = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String,
        refreshRetryClock: @escaping @Sendable () -> Date = { .now }
    ) {
        self.http = http
        self.secrets = secrets
        let version = appVersion?.trimmingCharacters(in: .whitespacesAndNewlines)
        // Command-line tools and tests may have no app bundle. Keep their fallback
        // valid for the API without reporting a real release that is not installed.
        if let version, version.range(of: "^[A-Za-z0-9][A-Za-z0-9._+-]{0,31}$", options: .regularExpression) != nil {
            self.appVersion = version
        } else {
            self.appVersion = "0.0.0"
        }
        self.refreshRetryClock = refreshRetryClock
    }

    /// Every feature shares this signal, even when its own error is caught locally.
    /// Replay the current invalidation so startup cannot miss an expired session.
    public func sessionInvalidations() -> AsyncStream<SessionInvalidation> {
        let id = UUID()
        let (stream, continuation) = AsyncStream<SessionInvalidation>.makeStream(bufferingPolicy: .bufferingNewest(1))
        invalidationObservers[id] = continuation
        if let sessionInvalidation { continuation.yield(sessionInvalidation) }
        continuation.onTermination = { [weak self] _ in
            Task { await self?.removeInvalidationObserver(id) }
        }
        return stream
    }

    private func removeInvalidationObserver(_ id: UUID) {
        invalidationObservers[id] = nil
    }

    private func invalidateSession(accountID: String) throws {
        expirationTask?.cancel()
        expirationTask = nil
        saved = nil
        accessToken = nil
        accessExpiry = .distantPast
        needsPersistence = false
        needsSessionRemoval = true
        refreshFailure = nil
        consecutiveRefreshFailures = 0
        if sessionInvalidation == nil {
            let event = SessionInvalidation(id: UUID(), accountID: accountID)
            sessionInvalidation = event
            invalidationObservers.values.forEach { $0.yield(event) }
        }
        // Routing must not depend on Keychain being writable at this instant.
        try persistIfNeeded()
    }

    private func scheduleExpiration(_ session: SavedSession) {
        expirationTask?.cancel()
        let expiry = session.refreshExpiresAt
        expirationTask = Task { [weak self] in
            do { try await Task.sleep(for: .seconds(max(0, expiry.timeIntervalSinceNow))) }
            catch { return }
            await self?.expireSessionIfNeeded()
        }
    }

    private func expireSessionIfNeeded() {
        guard let saved, saved.refreshExpiresAt <= .now else { return }
        // Failed deletion remains pending and is retried before the next login.
        try? invalidateSession(accountID: saved.account.id)
    }

    public func restore() throws -> Account? {
        try persistIfNeeded()
        // A second restoration must not overwrite a rotation/exchange in flight
        // with the older credential still on disk.
        if refreshTask != nil || exchanging { return saved?.account }
        guard let data = try secrets.read("session") else {
            saved = nil
            accessToken = nil
            accessExpiry = .distantPast
            return nil
        }
        let session = try JSONDecoder().decode(SavedSession.self, from: data)
        guard session.refreshExpiresAt > .now else {
            try invalidateSession(accountID: session.account.id)
            return nil
        }
        saved = session
        accessToken = session.accessToken
        accessExpiry = session.accessExpiresAt ?? .distantPast
        scheduleExpiration(session)
        return session.account
    }
    private func installationID() throws -> String {
        if let data = try secrets.read("installation"), let id = String(data: data, encoding: .utf8) {
            return id
        }
        let id = UUID().uuidString
        try secrets.write(Data(id.utf8), key: "installation")
        return id
    }
    public func beginAuthorization(redirectURI: URL = PKCE.defaultRedirectURI) async throws
        -> AuthorizationAttempt
    {
        guard !preparingForRelaunch else { throw CancellationError() }
        try persistIfNeeded()
        guard !exchanging, authorizing == nil else { throw VoiceLabError.invalidCallback }
        guard PKCE.isAllowedRedirectURI(redirectURI) else { throw VoiceLabError.invalidCallback }
        let attemptID = UUID()
        authorizationGeneration = attemptID
        authorizing = attemptID
        pending = nil
        defer { if authorizing == attemptID { authorizing = nil } }
        let epoch = generation
        let verifier = try PKCE.randomValue()
        let state = try PKCE.randomValue()
        let body = try HTTPClient.json([
            "client_id": "voicelab-desktop", "redirect_uri": redirectURI.absoluteString,
            "code_challenge": PKCE.challenge(verifier: verifier), "code_challenge_method": "S256",
            "state": state,
            "installation_id": try installationID(),
            "device_name": String((Host.current().localizedName ?? "Mac").prefix(100)),
            "app_version": appVersion, "platform": "darwin",
        ])
        let data = try await requestWithRateLimitRecovery(
            "/api/v2/auth/desktop/authorizations", body: body, epoch: epoch, attemptID: attemptID, maximumRateLimitWait: 5)
        try Task.checkCancellation()
        guard authorizationGeneration == attemptID else { throw CancellationError() }
        let response = try HTTPClient.decode(AuthorizationResponse.self, data: data)
        let url = response.authorizationUrl
        let query = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems
        guard epoch == generation,
            (1...600).contains(response.expiresIn),
            response.authorizationRequestId.hasPrefix("dau_"),
            http.environment.allowsAuthorizationURL(url),
            query?.count == 1, query?.first?.name == "desktop_auth_id",
            query?.first?.value == response.authorizationRequestId
        else {
            throw VoiceLabError.invalidResponse
        }
        let attempt = AuthorizationAttempt(
            url: url, redirectURI: redirectURI,
            expiresAt: .now.addingTimeInterval(Double(response.expiresIn)),
            verifier: verifier, state: state)
        pending = attempt
        return attempt
    }
    /// Checks whether an unconsumed callback still belongs to this live attempt.
    public func canResumeAuthorization(callback: URL) -> Bool {
        guard let pending, pending.expiresAt > .now, !exchanging else { return false }
        return (try? PKCE.callbackCode(callback, state: pending.state, redirectURI: pending.redirectURI)) != nil
    }

    public func completeAuthorization(callback: URL) async throws -> Account {
        guard !preparingForRelaunch else { throw CancellationError() }
        // An old rotating refresh must finish before installing a new login.
        if let refreshTask { _ = try? await refreshTask.value }
        try Task.checkCancellation()
        guard let pending, pending.expiresAt > .now, !exchanging else { throw VoiceLabError.invalidCallback }
        let code = try PKCE.callbackCode(callback, state: pending.state, redirectURI: pending.redirectURI)
        let epoch = generation
        let attemptID = authorizationGeneration
        exchanging = true
        var preserveAttempt = false
        defer {
            exchanging = false
            if !preserveAttempt { self.pending = nil }
        }
        let data: Data
        do {
            data = try await requestWithRateLimitRecovery(
                "/api/v2/auth/desktop/token",
                body: HTTPClient.json([
                    "grant_type": "authorization_code", "client_id": "voicelab-desktop",
                    "redirect_uri": pending.redirectURI.absoluteString, "code": code,
                    "code_verifier": pending.verifier,
                    "installation_id": try installationID(),
                ]), epoch: epoch, validUntil: pending.expiresAt, attemptID: attemptID, maximumRateLimitWait: 5)
        } catch VoiceLabError.rateLimited(let retryAt, let requestID) {
            // A definite 429 has not consumed the code. Allow an explicit retry
            // with this exact PKCE attempt once the server's cooldown ends.
            preserveAttempt = !Task.isCancelled && generation == epoch
                && authorizationGeneration == attemptID && pending.expiresAt > retryAt
            throw VoiceLabError.rateLimited(retryAt: retryAt, requestID: requestID)
        }
        guard generation == epoch else { throw VoiceLabError.sessionChanged }
        // The one-use code is already consumed. Persist its response even if the
        // caller cancelled while the server was issuing the credentials.
        let response = try HTTPClient.decode(TokenResponse.self, data: data)
        try install(response, fallback: nil)
        guard let saved else { throw VoiceLabError.invalidResponse }
        return saved.account
    }
    public func cancelAuthorization() {
        authorizationGeneration = UUID()
        authorizing = nil
        pending = nil
    }

    private func install(_ response: TokenResponse, fallback: SavedSession?) throws {
        guard response.tokenType.caseInsensitiveCompare("Bearer") == .orderedSame,
            (16...8192).contains(response.accessToken.count),
            (16...8192).contains(response.refreshToken.count),
            !response.accessToken.contains(where: \.isWhitespace),
            !response.refreshToken.contains(where: \.isWhitespace),
            (1...86400).contains(response.expiresIn), (1...2_592_000).contains(response.refreshExpiresIn),
            let account = response.user ?? fallback?.account,
            fallback == nil || response.refreshToken != fallback?.refreshToken,
            fallback == nil || account.id == fallback?.account.id
        else { throw VoiceLabError.invalidResponse }
        let next = SavedSession(
            pendingRefreshID: nil,
            refreshRetrySupported: response.refreshRetrySupported ?? fallback?.refreshRetrySupported,
            refreshToken: response.refreshToken,
            refreshExpiresAt: .now.addingTimeInterval(Double(response.refreshExpiresIn)), account: account,
            accessToken: response.accessToken,
            accessExpiresAt: .now.addingTimeInterval(Double(response.expiresIn)))
        saved = next
        refreshFailure = nil
        consecutiveRefreshFailures = 0
        sessionInvalidation = nil
        scheduleExpiration(next)
        accessToken = response.accessToken
        accessExpiry = next.accessExpiresAt ?? .distantPast
        needsPersistence = true
        try persistIfNeeded()
    }
    private func persistIfNeeded() throws {
        if needsSessionRemoval {
            try secrets.remove("session")
            needsSessionRemoval = false
        }
        guard needsPersistence, let saved else { return }
        // Keep the newly rotated credential in memory if Keychain is temporarily
        // unavailable. Retry this write, never the already-consumed old token.
        try secrets.write(JSONEncoder().encode(saved), key: "session")
        needsPersistence = false
    }

    /// Acquire only while credentials are stable. No network operation is started here.
    /// Persist a rotated credential before allowing its only in-memory copy to disappear.
    public func prepareForRelaunch() throws {
        guard refreshTask == nil, !exchanging, authorizing == nil, pending == nil else {
            throw UpdateRestartError.blocked([.authentication])
        }
        try persistIfNeeded()
        preparingForRelaunch = true
    }

    public func cancelRelaunch() { preparingForRelaunch = false }

    public func token(forceRefresh: Bool = false) async throws -> String {
        guard !preparingForRelaunch else { throw CancellationError() }
        if let saved, saved.refreshExpiresAt <= .now {
            try invalidateSession(accountID: saved.account.id)
            throw VoiceLabError.signedOut
        }
        try persistIfNeeded()
        guard !exchanging else { throw VoiceLabError.sessionChanged }
        if let refreshTask { return try await refreshTask.value }
        if !forceRefresh, let accessToken, accessExpiry.timeIntervalSinceNow > 60 { return accessToken }
        guard let saved, saved.refreshExpiresAt > .now else { throw VoiceLabError.signedOut }
        // Single-flight protects simultaneous callers. This circuit also protects
        // successive feature refreshes after that shared operation has failed.
        if let refreshFailure, refreshFailure.retryAt > refreshRetryClock() {
            throw refreshFailure.error
        }
        let epoch = generation
        let task = Task { try await self.refresh(saved, epoch: epoch) }
        refreshTask = task
        defer { if generation == epoch { refreshTask = nil } }
        return try await task.value
    }
    public func token(replacing rejectedToken: String) async throws -> String {
        // A late 401 may refer to the token another request already replaced.
        if let accessToken, accessToken != rejectedToken, accessExpiry.timeIntervalSinceNow > 60 {
            return try await token()
        }
        // Do not keep sending a known-rejected access token while refresh is
        // unavailable. Subsequent API callers must also respect its cooldown.
        if accessToken == rejectedToken { accessExpiry = .distantPast }
        return try await token(forceRefresh: true)
    }
    /// Bind background uploads to the account that owns their local outbox.
    /// Recheck after refresh because actor state may change while awaiting it.
    func token(forAccount accountID: String?, replacing rejectedToken: String? = nil) async throws -> String {
        if let accountID, saved?.account.id != accountID { throw VoiceLabError.sessionChanged }
        let value: String
        if let rejectedToken {
            value = try await token(replacing: rejectedToken)
        } else {
            value = try await token()
        }
        if let accountID, saved?.account.id != accountID { throw VoiceLabError.sessionChanged }
        return value
    }
    private func refresh(_ previous: SavedSession, epoch: UUID) async throws -> String {
        do {
            var retryID: String?
            if previous.refreshRetrySupported == true {
                var prepared = previous
                prepared.pendingRefreshID = previous.pendingRefreshID ?? UUID().uuidString.lowercased()
                saved = prepared
                needsPersistence = true
                // Persist BEFORE the server can consume this refresh credential.
                // A timeout or process restart must reuse the same operation ID.
                try persistIfNeeded()
                retryID = prepared.pendingRefreshID
            }
            let data = try await requestWithRateLimitRecovery(
                "/api/v2/auth/desktop/token",
                body: HTTPClient.json([
                    "grant_type": "refresh_token", "client_id": "voicelab-desktop",
                    "refresh_token": previous.refreshToken, "installation_id": try installationID(),
                ]), epoch: epoch, validUntil: previous.refreshExpiresAt, idempotencyKey: retryID)
            guard epoch == generation else { throw VoiceLabError.sessionChanged }
            guard previous.refreshExpiresAt > .now, sessionInvalidation == nil else {
                throw VoiceLabError.signedOut
            }
            try install(HTTPClient.decode(TokenResponse.self, data: data), fallback: previous)
            guard let accessToken else { throw VoiceLabError.invalidResponse }
            return accessToken
        } catch {
            guard generation == epoch else { throw VoiceLabError.sessionChanged }
            let rejected: Bool
            switch error {
            case VoiceLabError.signedOut, VoiceLabError.server(status: 401, message: _, requestID: _):
                rejected = true
            default: rejected = false
            }
            // A refresh-endpoint 401 is terminal even if a proxy/older server
            // returned HTML, an empty body, or an unfamiliar error code.
            // Do not apply this rule to arbitrary API calls or code exchange.
            if rejected {
                try? invalidateSession(accountID: previous.account.id)
                throw VoiceLabError.signedOut
            }
            if saved?.refreshToken == previous.refreshToken {
                throw recordRefreshFailure(error)
            }
            throw error
        }
    }

    private func recordRefreshFailure(_ error: any Error) -> any Error {
        let eligible: Bool
        switch error {
        case is URLError, is DecodingError,
             VoiceLabError.server, VoiceLabError.invalidResponse, VoiceLabError.rateLimited:
            eligible = true
        default: eligible = false
        }
        guard eligible else { return error }
        consecutiveRefreshFailures = min(consecutiveRefreshFailures + 1, 5)
        var retryAt = refreshRetryClock().addingTimeInterval(
            min(300, 30 * pow(2, Double(consecutiveRefreshFailures - 1))))
        let reportedError: any Error
        if case VoiceLabError.rateLimited(let serverDeadline, let requestID) = error {
            retryAt = max(retryAt, serverDeadline)
            reportedError = VoiceLabError.rateLimited(retryAt: retryAt, requestID: requestID)
        } else {
            reportedError = error
        }
        refreshFailure = (reportedError, retryAt)
        return reportedError
    }

    /// Codes and legacy refresh credentials retry only definite 429 rejections.
    /// Negotiated idempotent refresh operations also recover bounded transport/5xx
    /// failures using the SAME durable operation ID, never a new rotation.
    private func requestWithRateLimitRecovery(
        _ path: String, body: Data, epoch: UUID, validUntil: Date? = nil, attemptID: UUID? = nil,
        idempotencyKey: String? = nil, maximumRateLimitWait: TimeInterval = 120
    ) async throws -> Data {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: .seconds(maximumRateLimitWait))
        var retries = 0
        var transientRetries = 0
        while true {
            try Task.checkCancellation()
            guard generation == epoch else { throw VoiceLabError.sessionChanged }
            if let attemptID, authorizationGeneration != attemptID { throw CancellationError() }
            if let validUntil, validUntil <= .now {
                throw attemptID == nil ? VoiceLabError.signedOut : VoiceLabError.invalidCallback
            }
            do {
                return try await http.request(
                    path, method: "POST", body: body, idempotencyKey: idempotencyKey)
            } catch VoiceLabError.rateLimited(let retryAt, let requestID) {
                // All token consumers await the same refreshTask, including
                // while sleeping. Never let concurrent requests start a retry storm.
                let delay = max(1, retryAt.timeIntervalSinceNow) + Double.random(in: 0.2...0.8)
                // Interactive sign-in bounds automatic cooldown recovery instead of
                // displaying a browser-wait spinner for up to two minutes.
                // Background refresh still shares one bounded recovery operation.
                guard retries < 3, clock.now.advanced(by: .seconds(delay)) <= deadline,
                    validUntil.map({ $0.timeIntervalSinceNow > delay }) ?? true
                else {
                    throw VoiceLabError.rateLimited(retryAt: retryAt, requestID: requestID)
                }
                retries += 1
                try await Task.sleep(for: .seconds(delay))
            } catch {
                let recoverable: Bool
                if let network = error as? URLError {
                    recoverable = [.timedOut, .networkConnectionLost, .notConnectedToInternet].contains(
                        network.code)
                } else if case VoiceLabError.server(let status, _, _) = error {
                    recoverable = [500, 502, 503, 504].contains(status)
                } else {
                    recoverable = false
                }
                guard idempotencyKey != nil, recoverable, transientRetries < 2,
                    clock.now < deadline
                else { throw error }
                transientRetries += 1
                try await Task.sleep(for: .milliseconds(300 * transientRetries))
            }
        }
    }
    public func logout() async throws {
        guard !preparingForRelaunch else { throw CancellationError() }
        // Drain rotating credentials before revoking; a refresh token is single-use.
        if let refreshTask { _ = try? await refreshTask.value }
        var revocationToken: String?
        var revocationError: Error?
        if saved != nil {
            do {
                revocationToken = try await token()
            } catch VoiceLabError.signedOut {
                // Already expired or revoked on the server.
            } catch {
                revocationError = error
            }
        }
        let previous = saved
        let installation = try installationID()
        try secrets.remove("session")
        expirationTask?.cancel()
        expirationTask = nil
        sessionInvalidation = nil
        needsSessionRemoval = false
        generation = UUID()
        authorizationGeneration = UUID()
        authorizing = nil
        pending = nil
        saved = nil
        accessToken = nil
        accessExpiry = .distantPast
        needsPersistence = false
        refreshTask = nil
        refreshFailure = nil
        consecutiveRefreshFailures = 0
        // Local logout still completes offline; report failed remote revocation
        // rather than pretending the server session was revoked.
        if let revocationError { throw revocationError }
        if let previous, let revocationToken {
            _ = try await http.request(
                "/api/v2/auth/desktop/logout", method: "POST", token: revocationToken,
                body: HTTPClient.json([
                    "refresh_token": previous.refreshToken,
                    "installation_id": installation,
                ]))
        }
    }
}
