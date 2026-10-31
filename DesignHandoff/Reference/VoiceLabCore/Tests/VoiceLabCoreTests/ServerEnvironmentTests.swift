import Foundation
import Testing
@testable import VoiceLabCore

private actor OriginTransport: HTTPTransport {
    private(set) var requests: [URLRequest] = []
    let authorizationOrigin: String
    init(authorizationOrigin: String) { self.authorizationOrigin = authorizationOrigin }
    func send(_ request: URLRequest, uploadFile: URL?) async throws -> (Data, HTTPURLResponse) {
        requests.append(request)
        let data = try JSONSerialization.data(withJSONObject: [
            "authorization_url": authorizationOrigin + "/app/sign-in?desktop_auth_id=dau_test",
            "authorization_request_id": "dau_test", "expires_in": 300,
        ])
        return (data, HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
    }
}

private struct EnvironmentSecrets: SecretStore {
    func read(_ key: String) throws -> Data? { nil }
    func write(_ data: Data, key: String) throws {}
    func remove(_ key: String) throws {}
}

struct ServerEnvironmentTests {
    @Test func desktopBillingOpensPlansWithDesktopReturnContext() {
        #expect(ServerEnvironment.production.desktopBillingURL.absoluteString
            == "https://voicelab.uz/app/billing?source=desktop")
    }
    @Test func productionRejectsLocalAndLookalikeConsentOrigins() {
        let production = ServerEnvironment.production
        #expect(production.allowsAuthorizationURL(URL(string: "https://voicelab.uz/app/sign-in")!))
        for url in ["http://localhost:3000/app/sign-in", "http://voicelab.uz/app/sign-in",
                    "https://voicelab.uz:8081/app/sign-in", "https://voicelab.uz.attacker.test/app/sign-in",
                    "https://user@voicelab.uz/app/sign-in", "https://voicelab.uz/app/sign-in#fragment"] {
            #expect(!production.allowsAuthorizationURL(URL(string: url)!))
        }
    }

    @Test func defaultLoginUsesProductionAPIAndWebsite() async throws {
        let transport = OriginTransport(authorizationOrigin: "https://voicelab.uz")
        let http = HTTPClient(transport: transport)
        let auth = Authentication(http: http, secrets: EnvironmentSecrets())
        let attempt = try await auth.beginAuthorization()
        #expect(attempt.url.scheme == "https" && attempt.url.host == "voicelab.uz")
        let request = try #require(await transport.requests.first)
        #expect(request.url?.absoluteString == "https://api.voicelab.uz/api/v2/auth/desktop/authorizations")
        #expect(http.environment.storageNamespace.isEmpty)
    }

    @Test(arguments: ["http://localhost:3000", "https://voicelab.uz.attacker.test"])
    func loginRejectsUntrustedConsentOrigin(origin: String) async throws {
        let transport = OriginTransport(authorizationOrigin: origin)
        let http = HTTPClient(transport: transport)
        let auth = Authentication(http: http, secrets: EnvironmentSecrets())
        await #expect(throws: VoiceLabError.invalidResponse) { try await auth.beginAuthorization() }
    }
}
