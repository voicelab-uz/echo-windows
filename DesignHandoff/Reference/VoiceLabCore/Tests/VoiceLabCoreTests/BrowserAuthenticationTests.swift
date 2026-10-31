import Foundation
import Testing

@testable import VoiceLabCore

private let authorizationJSON = """
    {"authorization_url":"https://voicelab.uz/app/sign-in?desktop_auth_id=dau_test",
     "authorization_request_id":"dau_test","expires_in":300}
    """

@Test func loopbackRedirectMustBeLocalAndCallbackMustMatchExactPortAndState() throws {
    let redirect = URL(string: "http://127.0.0.1:49152/callback")!
    let valid = URL(string: "\(redirect)?code=dac_example&state=expected")!
    #expect(try PKCE.callbackCode(valid, state: "expected", redirectURI: redirect) == "dac_example")
    for address in [
        "http://localhost:49152/callback", "http://192.168.1.10:49152/callback",
        "https://example.com/callback", "http://127.0.0.1:80/callback",
        "http://127.0.0.1:49152/other", "http://127.0.0.1:49152/callback?extra=1",
        "http://user@127.0.0.1:49152/callback", "http://127.0.0.1:49152/callback#fragment",
    ] {
        #expect(!PKCE.isAllowedRedirectURI(URL(string: address)!))
    }
    for address in [
        "http://127.0.0.1:49153/callback?code=dac_example&state=expected",
        "http://localhost:49152/callback?code=dac_example&state=expected",
        "http://127.0.0.1:49152/callback?code=dac_example&state=wrong",
        "http://127.0.0.1:49152/callback?code=dac_example&state=expected&code=dac_duplicate",
        "voicelab://auth/callback?code=dac_example&state=expected",
    ] {
        #expect(throws: VoiceLabError.self) {
            try PKCE.callbackCode(URL(string: address)!, state: "expected", redirectURI: redirect)
        }
    }
}

@Test func authorizationAndExchangeUseSameLoopbackRedirectAndRejectReplay() async throws {
    let transport = StubTransport([(201, authorizationJSON), (200, tokenJSON())])
    let auth = Authentication(http: HTTPClient(transport: transport), secrets: MemorySecrets())
    let redirect = URL(string: "http://127.0.0.1:49152/callback")!
    let attempt = try await auth.beginAuthorization(redirectURI: redirect)
    let callback = URL(string: "\(redirect)?code=dac_test&state=\(attempt.state)")!
    try attempt.validate(callback: callback)
    let account = try await auth.completeAuthorization(callback: callback)
    #expect(account.id == "account-a")
    await #expect(throws: VoiceLabError.self) { try await auth.completeAuthorization(callback: callback) }
    let requests = await transport.requests
    #expect(requests.count == 2)
    let bodies = try requests.map {
        try JSONSerialization.jsonObject(with: #require($0.httpBody)) as! [String: String]
    }
    #expect(bodies.allSatisfy { $0["redirect_uri"] == redirect.absoluteString })
    #expect(bodies[0]["code_challenge"] == PKCE.challenge(verifier: bodies[1]["code_verifier"]!))
}

@Test func invalidCallbackDoesNotConsumePendingAuthorization() async throws {
    let transport = StubTransport([(201, authorizationJSON), (200, tokenJSON())])
    let auth = Authentication(http: HTTPClient(transport: transport), secrets: MemorySecrets())
    let attempt = try await auth.beginAuthorization()
    let invalid = URL(string: "\(attempt.redirectURI)?code=dac_test&state=wrong")!
    await #expect(throws: VoiceLabError.self) { try await auth.completeAuthorization(callback: invalid) }
    let callback = URL(string: "\(attempt.redirectURI)?code=dac_test&state=\(attempt.state)")!
    _ = try await auth.completeAuthorization(callback: callback)
    #expect(await transport.requests.count == 2)
}

@Test func canceledAndExpiredAttemptsCannotComplete() async throws {
    let transport = StubTransport([(201, authorizationJSON)])
    let auth = Authentication(http: HTTPClient(transport: transport), secrets: MemorySecrets())
    let attempt = try await auth.beginAuthorization()
    let callback = URL(string: "\(attempt.redirectURI)?code=dac_test&state=\(attempt.state)")!
    let expired = AuthorizationAttempt(
        url: attempt.url, redirectURI: attempt.redirectURI, expiresAt: .distantPast,
        verifier: attempt.verifier, state: attempt.state)
    #expect(throws: VoiceLabError.self) { try expired.validate(callback: callback) }
    await auth.cancelAuthorization()
    await #expect(throws: VoiceLabError.self) { try await auth.completeAuthorization(callback: callback) }
    #expect(await transport.requests.count == 1)
}

@Test(arguments: ["2.0.0", "2.1.0-beta.3+104", " 2.0.1 "])
func authorizationReportsAppVersion(_ version: String) async throws {
    let transport = StubTransport([(201, authorizationJSON)])
    let auth = Authentication(
        http: HTTPClient(transport: transport), secrets: MemorySecrets(), appVersion: version)
    _ = try await auth.beginAuthorization()
    let request = try #require(await transport.requests.first)
    let body = try JSONSerialization.jsonObject(with: #require(request.httpBody)) as! [String: String]
    #expect(body["app_version"] == version.trimmingCharacters(in: .whitespacesAndNewlines))
}

@Test(arguments: [nil, "", " ", "$(MARKETING_VERSION)", "2.0.0\nforged", String(repeating: "1", count: 33)] as [String?])
func authorizationUsesSafeVersionForMissingOrInvalidBundleMetadata(_ version: String?) async throws {
    let transport = StubTransport([(201, authorizationJSON)])
    let auth = Authentication(
        http: HTTPClient(transport: transport), secrets: MemorySecrets(), appVersion: version)
    _ = try await auth.beginAuthorization()
    let request = try #require(await transport.requests.first)
    let body = try JSONSerialization.jsonObject(with: #require(request.httpBody)) as! [String: String]
    #expect(body["app_version"] == "0.0.0")
}

@Test func authorizationDefaultsToMainBundleVersion() async throws {
    let transport = StubTransport([(201, authorizationJSON)])
    let auth = Authentication(http: HTTPClient(transport: transport), secrets: MemorySecrets())
    _ = try await auth.beginAuthorization()
    let request = try #require(await transport.requests.first)
    let body = try JSONSerialization.jsonObject(with: #require(request.httpBody)) as! [String: String]
    let bundledVersion = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
    #expect(body["app_version"] == (bundledVersion ?? "0.0.0"))
}
