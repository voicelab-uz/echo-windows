import Foundation
import Testing

@testable import VoiceLabCore

@Test func transcriptEditSendsExpectedRevisionAndPreservesConflict() async throws {
    let transport = StubTransport([
        (200, tokenJSON()),
        (409, #"{"error":{"message":"Transcript changed on another device"}}"#),
    ])
    let http = HTTPClient(transport: transport)
    let auth = try await restoredAuth(http: http, secrets: MemorySecrets())
    let api = DesktopAPI(http: http, auth: auth)
    let original = Transcript(
        id: "dst_example", text: "Original", language: "uz", durationMS: 1000, revision: 3)

    await #expect(throws: VoiceLabError.self) {
        try await api.update(original, text: "Edited")
    }
    let requests = await transport.requests
    #expect(requests.count == 2)
    let request = try #require(requests.last)
    let body = try #require(request.httpBody)
    let fields = try JSONSerialization.jsonObject(with: body) as? [String: Any]
    #expect(request.httpMethod == "PATCH")
    #expect(fields?["expected_revision"] as? Int == 3)
    #expect(fields?["transcript"] as? String == "Edited")
    #expect(original.text == "Original")
}

final class MemorySecrets: SecretStore, @unchecked Sendable {
    private let lock = NSLock()
    private var values: [String: Data] = [:]
    func read(_ key: String) throws -> Data? { lock.withLock { values[key] } }
    func write(_ data: Data, key: String) throws { lock.withLock { values[key] = data } }
    func remove(_ key: String) throws { lock.withLock { values[key] = nil } }
}

actor StubTransport: HTTPTransport {
    struct Reply: Sendable {
        let status: Int
        let data: Data
    }
    private var replies: [Reply]
    private(set) var requests: [URLRequest] = []
    private(set) var uploads: [Data] = []
    init(_ responses: [(Int, String)]) {
        replies = responses.map { Reply(status: $0.0, data: Data($0.1.utf8)) }
    }
    func send(_ request: URLRequest, uploadFile: URL?) async throws -> (Data, HTTPURLResponse) {
        requests.append(request)
        if let uploadFile { uploads.append(try Data(contentsOf: uploadFile)) }
        guard !replies.isEmpty else { throw VoiceLabError.invalidResponse }
        let reply = replies.removeFirst()
        try await Task.sleep(for: .milliseconds(15))
        return (
            reply.data,
            HTTPURLResponse(url: request.url!, statusCode: reply.status, httpVersion: nil, headerFields: nil)!
        )
    }
}

func tokenJSON(refresh: String = "drt_rotated_123456789", access: String = "access_123456789012345")
    -> String
{
    """
    {"access_token":"\(access)","refresh_token":"\(refresh)","token_type":"Bearer","expires_in":900,"refresh_expires_in":2592000,
     "user":{"id":"account-a","email":"test@example.com","full_name":"Test User"}}
    """
}

func restoredAuth(
    http: HTTPClient, secrets: MemorySecrets,
    refreshRetryClock: @escaping @Sendable () -> Date = { .now }
) async throws -> Authentication {
    struct Session: Encodable {
        let refreshToken: String
        let refreshExpiresAt: Date
        let account: Account
    }
    try secrets.write(
        JSONEncoder().encode(
            Session(
                refreshToken: "drt_initial_123456789", refreshExpiresAt: .now.addingTimeInterval(3600),
                account: Account(id: "account-a", email: "test@example.com", name: "Test"))), key: "session")
    let auth = Authentication(http: http, secrets: secrets, refreshRetryClock: refreshRetryClock)
    _ = try await auth.restore()
    return auth
}

@Test func pkceMatchesRFC7636() {
    #expect(
        PKCE.challenge(verifier: "dBjftJeZ4CVP-mB92K27uhbUJU1p1r_wW1gFWFOEjXk")
            == "E9Melhoa2OwvFrEMTJguCHaoeK1t8URWbuGJSstw-cM")
}

@Test func callbackRejectsWrongStateDuplicateParametersAndForeignRoutes() throws {
    let valid = URL(string: "voicelab://auth/callback?code=dac_abc&state=expected")!
    #expect(try PKCE.callbackCode(valid, state: "expected") == "dac_abc")
    for raw in [
        "voicelab://auth/callback?code=dac_abc&state=wrong",
        "voicelab://auth/callback?code=dac_abc&state=expected&state=expected",
        "voicelab://evil/callback?code=dac_abc&state=expected",
        "voicelab://auth/callback?code=dac_abc&state=expected#fragment",
        "https://auth/callback?code=dac_abc&state=expected",
        "voicelab://auth/callback?code=other&state=expected",
    ] {
        #expect(throws: VoiceLabError.self) { try PKCE.callbackCode(URL(string: raw)!, state: "expected") }
    }
}

@Test func apostrophesAndSmartSpacingMatchDesktop() {
    #expect(
        TextRules.normalizedKey("  O‘ZBEK   TILI ")
            == TextRules.normalizedKey("o'zbek tili").replacingOccurrences(of: "'", with: "ʻ"))
    #expect(TextRules.spaced("dunyo", precedingCharacter: "m") == " dunyo")
    #expect(TextRules.spaced(", dunyo", precedingCharacter: "m") == ", dunyo")
    #expect(TextRules.spaced("salom", precedingCharacter: "(") == "salom")
    #expect(TextRules.spaced("", precedingCharacter: "x") == "")
}

@Test func replacementsRespectUnicodeWordBoundariesAndLiteralTemplates() {
    let entries = [
        VocabularyEntry(word: "lab", replacement: "$1\\native"),
        VocabularyEntry(word: "salom", replacement: "Assalomu alaykum"),
    ]
    #expect(
        TextRules.applyingReplacements(to: "Laboratoriya lab; SALOM!", entries: entries)
            == "Laboratoriya $1\\native; Assalomu alaykum!")
}

@Test func libraryIsEncryptedAccountScopedAndRejectsTampering() async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    let secrets = MemorySecrets()
    let store = LibraryStore(directory: directory, secrets: secrets)
    var snapshot = LibrarySnapshot()
    snapshot.transcripts = [
        Transcript(text: "private phrase never plaintext", language: "uz", durationMS: 1200)
    ]
    try await store.save(snapshot, accountID: "account-a")
    #expect(try await store.load(accountID: "account-a").transcripts == snapshot.transcripts)
    #expect(try await store.load(accountID: "account-b").transcripts.isEmpty)
    let file = try #require(
        FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil).first)
    var data = try Data(contentsOf: file)
    #expect(data.range(of: Data("private phrase".utf8)) == nil)
    data[data.count - 1] ^= 0xFF
    try data.write(to: file)
    await #expect(throws: (any Error).self) { try await store.load(accountID: "account-a") }
    #expect(try Data(contentsOf: file) == data)
}

@Test func missingEncryptionKeyDoesNotOverwriteData() async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    let original = LibraryStore(directory: directory, secrets: MemorySecrets())
    try await original.save(LibrarySnapshot(), accountID: "a")
    let restarted = LibraryStore(directory: directory, secrets: MemorySecrets())
    await #expect(throws: VoiceLabError.self) { try await restarted.load(accountID: "a") }
}

@Test func concurrentTokenConsumersShareOneRotationAndPersistTheCompleteSession() async throws {
    let transport = StubTransport([(200, tokenJSON())])
    let secrets = MemorySecrets()
    let auth = try await restoredAuth(http: HTTPClient(transport: transport), secrets: secrets)
    let values = try await withThrowingTaskGroup(of: String.self) { group in
        for _ in 0..<12 { group.addTask { try await auth.token() } }
        var result: [String] = []
        for try await token in group { result.append(token) }
        return result
    }
    #expect(values.count == 12)
    #expect(Set(values).count == 1)
    #expect(await transport.requests.count == 1)
    let stored = try secrets.read("session")
    let saved = try #require(stored)
    #expect(String(decoding: saved, as: UTF8.self).contains("drt_rotated_123456789"))
    #expect(String(decoding: saved, as: UTF8.self).contains("access_123456789012345"))
}

@Test func transientRefreshFailurePreservesSessionAndTerminalFailureClearsIt() async throws {
    let transport = StubTransport([
        (503, #"{"error":{"message":"Unavailable"}}"#),
        (401, #"{"error":{"code":"invalid_refresh_token","message":"Expired"}}"#),
    ])
    let clock = RefreshTestClock()
    let secrets = MemorySecrets()
    let auth = try await restoredAuth(
        http: HTTPClient(transport: transport), secrets: secrets, refreshRetryClock: { clock.now })
    await #expect(throws: VoiceLabError.self) { try await auth.token() }
    #expect(try secrets.read("session") != nil)
    // The second consumer shares the cooldown; it must not send another request.
    await #expect(throws: VoiceLabError.self) { try await auth.token() }
    #expect(await transport.requests.count == 1)
    clock.advance(31)
    await #expect(throws: VoiceLabError.self) { try await auth.token() }
    #expect(await transport.requests.count == 2)
    #expect(try secrets.read("session") == nil)
}

@Test func usageDerivesOmittedCounters() throws {
    let usage = try HTTPClient.decode(
        Usage.self,
        data: Data(
            #"{"enabled":true,"usage_limit_seconds":600,"used_seconds":120,"reserved_seconds":30}"#.utf8))
    #expect(usage.remaining == 450)
    #expect(usage.fraction == 0.25)
}

@Test func sttUsesCanonicalMultipartAndDoesNotRetryBillableFailures() async throws {
    let transport = StubTransport([
        (200, tokenJSON()),
        (503, #"{"error":{"message":"Timed out"},"request_id":"req_test"}"#),
    ])
    let http = HTTPClient(transport: transport)
    let auth = try await restoredAuth(http: http, secrets: MemorySecrets())
    let api = DesktopAPI(http: http, auth: auth)
    let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".wav")
    defer { try? FileManager.default.removeItem(at: file) }
    try Data("RIFF-test-audio".utf8).write(to: file)
    await #expect(throws: VoiceLabError.self) { try await api.transcribe(file: file, language: .uz) }
    let requests = await transport.requests
    #expect(requests.count == 2)
    #expect(requests.last?.url?.path == "/v1/desktop/stt")
    #expect(requests.last?.value(forHTTPHeaderField: "Idempotency-Key") == nil)
    let multipart = String(decoding: try #require(await transport.uploads.first), as: UTF8.self)
    #expect(multipart.contains("name=\"audio\""))
    #expect(multipart.contains("name=\"language\"\r\n\r\nauto\r\n"))
    #expect(multipart.contains("audio/wav"))
    #expect(!multipart.contains("name=\"file\""))
}

@Test func historyDecodesEnvelopeAndRevision() async throws {
    let transport = StubTransport([
        (200, tokenJSON()),
        (
            200,
            #"{"transcriptions":[{"id":"dst_abc","transcript":"Salom","language":"uz","duration_ms":1500,"created_at":"2026-10-20T10:00:00.123Z","revision":2}],"pagination":{"has_more":true}}"#
        ),
    ])
    let http = HTTPClient(transport: transport)
    let auth = try await restoredAuth(http: http, secrets: MemorySecrets())
    let page = try await DesktopAPI(http: http, auth: auth).history(page: 1)
    #expect(page.hasMore)
    #expect(page.items.first?.revision == 2)
    #expect(page.items.first?.durationMS == 1500)
    #expect(page.items.first?.createdAt != .distantPast)
}

@Test func automaticAudioUploadDoesNotForceStoredLanguage() throws {
    let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".wav")
    try Data("RIFF-test-audio".utf8).write(to: file)
    defer { try? FileManager.default.removeItem(at: file) }
    let multipart = try MultipartAudio(file: file, language: .auto)
    defer { try? FileManager.default.removeItem(at: multipart.url) }
    let body = String(decoding: try Data(contentsOf: multipart.url), as: UTF8.self)
    #expect(body.contains("name=\"language\"\r\n\r\nauto\r\n"))
    #expect(body.contains("name=\"audio\""))
}

@Test func autoTranscriptionPreservesDetectedLanguage() async throws {
    let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".wav")
    try Data("RIFF-test-audio".utf8).write(to: file)
    defer { try? FileManager.default.removeItem(at: file) }
    for language in ["uz", "en", "ru", "de", "auto", ""] {
        let response = "{\"text\":\"Speech\",\"language\":\"\(language)\",\"duration_ms\":1000}"
        let transport = StubTransport([(200, tokenJSON()), (200, response)])
        let http = HTTPClient(transport: transport)
        let auth = try await restoredAuth(http: http, secrets: MemorySecrets())
        let api = DesktopAPI(http: http, auth: auth)
        if language == "auto" || language.isEmpty {
            await #expect(throws: VoiceLabError.self) { try await api.transcribe(file: file, language: .auto) }
        } else {
            let result = try await api.transcribe(file: file, language: .auto)
            #expect(result.language == language)
            #expect(result.text == "Speech")
        }
    }
}
