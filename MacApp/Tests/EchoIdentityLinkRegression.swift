import CryptoKit
import Foundation

// Only Keychain and network boundaries are replaced. The actual client source,
// provider-proof freshness, cancellation, PKCE and link sequencing are compiled.
final class IdentityMemoryKeychain: @unchecked Sendable {
    var values: [String: Data] = [:]
    func read(_ key: String) throws -> Data? { values[key] }
    func write(_ value: Data, key: String) throws { values[key] = value }
    func remove(_ key: String) throws { values.removeValue(forKey: key) }
}

private final class IdentityFixture: @unchecked Sendable {
    static let shared = IdentityFixture()
    enum Scenario { case appleIntoGoogle, googleIntoApple, foreignIdentity, canceledLogin, legacyConflict, normalGoogle }
    struct Response: Sendable { let status: Int; let body: Data; let delay: Double }
    private let lock = NSLock()
    private var scenario = Scenario.appleIntoGoogle
    private var incomingToken = ""
    private var nonce = ""
    private var state = ""
    private var challenge = ""
    private var paths: [String] = []
    private var linked = false
    private var ownerLoginSeen = false
    private var linkSawWebBearer = false
    private var throttleRefresh = false
    private var refreshCalls = 0
    let webAccess = "web_owner_access_fixture_123456789"
    func reset(_ scenario: Scenario, incoming: String, nonce: String) {
        lock.lock(); defer { lock.unlock() }
        self.scenario = scenario; incomingToken = incoming; self.nonce = nonce
        state = ""; challenge = ""; paths = []; linked = false; ownerLoginSeen = false; linkSawWebBearer = false
        throttleRefresh = false; refreshCalls = 0
    }
    func setRefreshThrottled(_ value: Bool) { lock.lock(); defer { lock.unlock() }; throttleRefresh = value }
    func snapshot() -> (paths: [String], linked: Bool, ownerLoginSeen: Bool, webBearer: Bool, refreshCalls: Int) {
        lock.lock(); defer { lock.unlock() }
        return (paths, linked, ownerLoginSeen, linkSawWebBearer, refreshCalls)
    }
    func response(_ request: URLRequest) throws -> Response {
        lock.lock(); defer { lock.unlock() }
        let path = request.url!.path
        paths.append(path)
        var data = request.httpBody ?? Data()
        if data.isEmpty, let stream = request.httpBodyStream {
            stream.open(); defer { stream.close() }
            var bytes = [UInt8](repeating: 0, count: 4096)
            while stream.hasBytesAvailable {
                let count = stream.read(&bytes, maxLength: bytes.count)
                if count <= 0 { break }
                data.append(contentsOf: bytes.prefix(count))
            }
        }
        let body = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
        func reply(_ status: Int, _ json: [String: Any], delay: Double = 0) throws -> Response {
            .init(status: status, body: try JSONSerialization.data(withJSONObject: json), delay: delay)
        }
        let incoming = scenario == .googleIntoApple ? "/api/auth/google/ios" : "/api/auth/apple"
        if path == incoming, body["link_account"] as? Bool == true {
            precondition(request.value(forHTTPHeaderField: "Authorization") == "Bearer " + webAccess,
                         "Link must use the temporary web owner bearer, never the native token")
            precondition(body["id_token"] as? String == incomingToken)
            if path == "/api/auth/apple" { precondition(body["nonce"] as? String == nonce, "Apple raw nonce changed") }
            linkSawWebBearer = true
            if scenario == .foreignIdentity {
                return try reply(409, ["error": ["code": "identity_already_linked"]])
            }
            linked = true
            return try reply(200, ["linked": true, "sign_in_methods": ["google": true, "apple": true, "password": false, "telegram": false, "passkeys": 2]])
        }
        if path == incoming, scenario != .normalGoogle {
            precondition(request.value(forHTTPHeaderField: "Authorization") == nil)
            let methods = scenario == .googleIntoApple ? "apple" : "google"
            let fields = scenario == .legacyConflict ? [:] : ["link_required": "true", "sign_in_methods": methods]
            return try reply(409, ["error": ["code": "apple_account_conflict", "fields": fields]])
        }
        if path == "/api/auth/google/ios" || path == "/api/auth/apple" {
            precondition(body["link_account"] == nil && request.value(forHTTPHeaderField: "Authorization") == nil)
            if path == "/api/auth/apple" { precondition((body["nonce"] as? String)?.count == 64) }
            ownerLoginSeen = true
            return try reply(200, ["access": webAccess], delay: scenario == .canceledLogin ? 0.2 : 0)
        }
        if path == "/api/v2/auth/desktop/authorizations" {
            precondition(linked || scenario == .normalGoogle, "PKCE began before the link was verified")
            precondition(body["platform"] as? String == "ios")
            state = body["state"] as! String
            challenge = body["code_challenge"] as! String
            return try reply(200, ["authorization_request_id": "dau_fixture", "authorization_url": "https://voicelab.uz/app/sign-in?desktop_auth_id=dau_fixture", "expires_in": 600])
        }
        if path == "/api/v2/auth/desktop/authorizations/dau_fixture/approve" {
            precondition(request.value(forHTTPHeaderField: "Authorization") == "Bearer " + webAccess)
            return try reply(200, ["redirect_url": "voicelab://auth/callback?state=\(state)&code=dac_fixture"])
        }
        if path == "/api/v2/auth/desktop/token" {
            if body["grant_type"] as? String == "refresh_token" {
                refreshCalls += 1
                if throttleRefresh { return try reply(429, ["error": ["code": "rate_limited"]]) }
                return try reply(200, ["access_token": "native_access_refreshed_fixture_123456789", "refresh_token": "native_refresh_refreshed_fixture_123456789", "token_type": "Bearer", "expires_in": 900, "refresh_expires_in": 86400,
                                       "user": ["id": "fixture-user", "email": "fixture@example.invalid", "name": "Fixture"]])
            }
            precondition(request.value(forHTTPHeaderField: "Authorization") == nil)
            let verifier = body["code_verifier"] as! String
            let hash = Data(SHA256.hash(data: Data(verifier.utf8))).base64EncodedString()
                .replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
            precondition(hash == challenge, "PKCE verifier/challenge mismatch")
            return try reply(200, ["access_token": "native_access_fixture_123456789", "refresh_token": "native_refresh_fixture_123456789", "token_type": "Bearer", "expires_in": 900, "refresh_expires_in": 86400,
                                   "user": ["id": "fixture-user", "email": "fixture@example.invalid", "name": "Fixture"]])
        }
        if path == "/api/v2/auth/logout" || path == "/api/v2/auth/desktop/logout" { return try reply(200, ["ok": true]) }
        preconditionFailure("Unexpected mock auth endpoint")
    }
}

private final class IdentityMockProtocol: URLProtocol, @unchecked Sendable {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        do {
            let reply = try IdentityFixture.shared.response(request)
            let send: @Sendable () -> Void = { [self] in
                let response = HTTPURLResponse(url: request.url!, statusCode: reply.status, httpVersion: nil,
                    headerFields: ["Content-Type": "application/json", "Set-Cookie": "refresh=fixture; Path=/; Secure; HttpOnly", "Retry-After": "2"])!
                client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
                client?.urlProtocol(self, didLoad: reply.body)
                client?.urlProtocolDidFinishLoading(self)
            }
            if reply.delay > 0 { DispatchQueue.global().asyncAfter(deadline: .now() + reply.delay, execute: send) }
            else { send() }
        } catch { client?.urlProtocol(self, didFailWithError: error) }
    }
    override func stopLoading() {}
}

@main struct EchoIdentityLinkRegression {
    static let nonce = String(repeating: "a", count: 64)
    static func token(_ subject: String, age: TimeInterval = 0) throws -> String {
        let json: [String: Any] = ["sub": subject, "iat": Int(Date.now.addingTimeInterval(-age).timeIntervalSince1970), "exp": Int(Date.now.addingTimeInterval(3600).timeIntervalSince1970)]
        let payload = try JSONSerialization.data(withJSONObject: json).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
        return "fixture." + payload + ".signature"
    }
    static func client() -> EchoAuthClient {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [IdentityMockProtocol.self]
        return EchoAuthClient(identityTestTransport: URLSession(configuration: config))
    }
    static func conflict(_ client: EchoAuthClient, google: Bool = false, proof: String) async throws -> EchoIdentityLinkRequirement {
        do {
            if google { _ = try await client.signInWithGoogle(idToken: proof) }
            else { _ = try await client.signInWithApple(idToken: proof, nonce: nonce, fullName: "Fixture") }
            preconditionFailure("Conflict silently issued a native session")
        } catch let required as EchoIdentityLinkRequired { return required.requirement }
    }
    static func assertNoStoredProof(_ client: EchoAuthClient, proof: String) async {
        let entries = await client.identityStoredValuesForTesting()
        precondition(!entries.values.contains { String(decoding: $0, as: UTF8.self).contains(proof) })
        precondition(!entries.values.contains { String(decoding: $0, as: UTF8.self).contains(IdentityFixture.shared.webAccess) })
    }
    static func main() async throws {
        let incoming = try token("incoming")
        let owner = try token("owner")
        for google in [false, true] {
            IdentityFixture.shared.reset(google ? .googleIntoApple : .appleIntoGoogle, incoming: incoming, nonce: nonce)
            let auth = client()
            let requirement = try await conflict(auth, google: google, proof: incoming)
            precondition(requirement.providerToLink == (google ? .google : .apple))
            precondition(requirement.existingProviders == [google ? .apple : .google])
            precondition(!requirement.isExpired() && requirement.isExpired(at: requirement.expiresAt))
            precondition(requirement.expiresAt.timeIntervalSinceNow <= 9 * 60)
            let before = IdentityFixture.shared.snapshot()
            precondition(!before.linked && !before.paths.contains("/api/v2/auth/desktop/authorizations"))
            await assertNoStoredProof(auth, proof: incoming)
            let account: EchoAccount
            if google { account = try await auth.signInWithApple(idToken: owner, nonce: nonce, fullName: nil, linking: requirement.id) }
            else { account = try await auth.signInWithGoogle(idToken: owner, linking: requirement.id) }
            precondition(account.id == "fixture-user")
            let after = IdentityFixture.shared.snapshot()
            precondition(after.linked && after.webBearer && after.paths.last == "/api/v2/auth/logout")
            let restored = try await auth.restore()
            precondition(restored?.id == "fixture-user")
            await assertNoStoredProof(auth, proof: incoming)
        }

        IdentityFixture.shared.reset(.foreignIdentity, incoming: incoming, nonce: nonce)
        let foreign = client()
        let pending = try await conflict(foreign, proof: incoming)
        do { _ = try await foreign.signInWithGoogle(idToken: owner, linking: pending.id); preconditionFailure("Foreign identity linked") }
        catch EchoIdentityLinkError.identityAlreadyLinked {}
        precondition(!IdentityFixture.shared.snapshot().paths.contains("/api/v2/auth/desktop/authorizations"))
        let foreignSession = try await foreign.restore()
        precondition(foreignSession == nil)
        await assertNoStoredProof(foreign, proof: incoming)

        IdentityFixture.shared.reset(.appleIntoGoogle, incoming: incoming, nonce: nonce)
        let canceled = client()
        let canceledRequirement = try await conflict(canceled, proof: incoming)
        await canceled.cancelIdentityLink(canceledRequirement.id)
        let count = IdentityFixture.shared.snapshot().paths.count
        do { _ = try await canceled.signInWithGoogle(idToken: owner, linking: canceledRequirement.id); preconditionFailure("Canceled proof reused") }
        catch EchoIdentityLinkError.canceled {}
        precondition(IdentityFixture.shared.snapshot().paths.count == count)

        IdentityFixture.shared.reset(.canceledLogin, incoming: incoming, nonce: nonce)
        let interrupted = client()
        let interruptedRequirement = try await conflict(interrupted, proof: incoming)
        let task = Task { try await interrupted.signInWithGoogle(idToken: owner, linking: interruptedRequirement.id) }
        for _ in 0..<100 where !IdentityFixture.shared.snapshot().ownerLoginSeen { try? await Task.sleep(for: .milliseconds(2)) }
        await interrupted.cancelIdentityLink(interruptedRequirement.id)
        do { _ = try await task.value; preconditionFailure("Canceled login installed a native session") }
        catch EchoAuthError.signedOut {}
        precondition(!IdentityFixture.shared.snapshot().linked)
        let interruptedSession = try await interrupted.restore()
        precondition(interruptedSession == nil)

        let almostExpired = try token("expires-soon", age: 598)
        IdentityFixture.shared.reset(.googleIntoApple, incoming: almostExpired, nonce: nonce)
        let expiring = client()
        let expiringRequirement = try await conflict(expiring, google: true, proof: almostExpired)
        try? await Task.sleep(for: .milliseconds(2200))
        let beforeExpiredAttempt = IdentityFixture.shared.snapshot().paths.count
        do {
            _ = try await expiring.signInWithApple(idToken: owner, nonce: nonce, fullName: nil, linking: expiringRequirement.id)
            preconditionFailure("Expired in-memory proof replayed")
        } catch EchoIdentityLinkError.canceled {} catch EchoIdentityLinkError.expired {}
        precondition(IdentityFixture.shared.snapshot().paths.count == beforeExpiredAttempt,
                     "Expired recovery must stop before another provider login or link request")
        await assertNoStoredProof(expiring, proof: almostExpired)

        let old = try token("expired", age: 601)
        IdentityFixture.shared.reset(.googleIntoApple, incoming: old, nonce: nonce)
        let stale = client()
        do { _ = try await conflict(stale, google: true, proof: old); preconditionFailure("Old Google proof cached") }
        catch EchoIdentityLinkError.expired {}
        await assertNoStoredProof(stale, proof: old)

        IdentityFixture.shared.reset(.legacyConflict, incoming: incoming, nonce: nonce)
        let legacy = client()
        do { _ = try await legacy.signInWithApple(idToken: incoming, nonce: nonce, fullName: nil); preconditionFailure("Unverified legacy conflict offered linking") }
        catch EchoAuthError.server(409) {}

        IdentityFixture.shared.reset(.normalGoogle, incoming: incoming, nonce: nonce)
        let normal = client()
        let normalAccount = try await normal.signInWithGoogle(idToken: owner)
        precondition(normalAccount.id == "fixture-user")
        precondition(!IdentityFixture.shared.snapshot().linked)
        IdentityFixture.shared.setRefreshThrottled(true)
        let rejected = "native_access_fixture_123456789"
        let deadline: Date
        do { _ = try await normal.accessToken(replacing: rejected); preconditionFailure("Refresh429 unexpectedly succeeded") }
        catch EchoAuthError.rateLimitedUntil(let value) { deadline = value }
        for _ in 0..<4 {
            do { _ = try await normal.accessToken(); preconditionFailure("Rejected token reused during refresh cooldown") }
            catch EchoAuthError.rateLimitedUntil(let value) { precondition(abs(value.timeIntervalSince(deadline)) < 0.1) }
        }
        precondition(IdentityFixture.shared.snapshot().refreshCalls == 1, "Sequential feature calls repeated throttled refresh POST")
        let invalidatedStorage = await normal.identityStoredValuesForTesting()
        let saved = try JSONSerialization.jsonObject(with: invalidatedStorage["session"]!) as! [String: Any]
        precondition((saved["accessExpiresAt"] as? Double ?? 0) < 0, "Rejected access token expiry was not persisted")
        IdentityFixture.shared.setRefreshThrottled(false)
        try? await Task.sleep(for: .seconds(max(0, deadline.timeIntervalSinceNow + 0.05)))
        let replacement = try await normal.accessToken()
        precondition(replacement != rejected && IdentityFixture.shared.snapshot().refreshCalls == 2)
        let alreadyReplaced = try await normal.accessToken(replacing: rejected)
        precondition(alreadyReplaced == replacement && IdentityFixture.shared.snapshot().refreshCalls == 2)
        IdentityFixture.shared.setRefreshThrottled(true)
        do { _ = try await normal.accessToken(replacing: replacement); preconditionFailure("Second refresh429 unexpectedly succeeded") }
        catch EchoAuthError.rateLimitedUntil {}
        IdentityFixture.shared.setRefreshThrottled(false)
        _ = try await normal.signInWithGoogle(idToken: owner)
        let newSessionReplacement = try await normal.accessToken(replacing: rejected)
        precondition(newSessionReplacement != rejected, "New native installation inherited the previous generation cooldown")
        try await normal.signOut()
        do { _ = try await normal.accessToken(); preconditionFailure("Signout kept cached credentials") }
        catch EchoAuthError.signedOut {}
        print("Identity linking regression passed: explicit two-provider proof, temporary bearer, PKCE order, nonce, no persistence, cancel/expiry, normal sign-in, refresh cooldown and rejected-token invalidation")
    }
}
