import Foundation

public protocol DesktopServing: Sendable {
    func usage() async throws -> Usage
    func history(page: Int) async throws -> HistoryPage
    func transcribe(file: URL, language: DictationLanguage) async throws -> Transcript
    func update(_ transcript: Transcript, text: String) async throws -> Transcript
}

public struct HistoryPage: Sendable {
    public let items: [Transcript]
    public let hasMore: Bool
}

public struct DesktopAPI: DesktopServing {
    private let http: HTTPClient
    private let auth: Authentication
    let appVersion: String
    public init(http: HTTPClient, auth: Authentication, appVersion: String = "1.0") {
        self.http = http
        self.auth = auth
        self.appVersion = appVersion
    }

    func request(
        _ path: String, method: String = "GET", body: Data? = nil,
        contentType: String = "application/json", file: URL? = nil, accountID: String? = nil
    ) async throws -> Data {
        let token = try await auth.token(forAccount: accountID)
        try Task.checkCancellation()
        // A typed auth rejection occurs before processing/billing. Retry it once
        // with fresh credentials; never replay ambiguous failures or generic 401s.
        do {
            return try await http.request(
                path, method: method, token: token, body: body, contentType: contentType, uploadFile: file)
        } catch VoiceLabError.invalidAccessToken {
            let replacement = try await auth.token(forAccount: accountID, replacing: token)
            try Task.checkCancellation()
            return try await http.request(
                path, method: method, token: replacement, body: body,
                contentType: contentType, uploadFile: file)
        }
    }
    public func usage() async throws -> Usage {
        struct Envelope: Decodable { let desktopStt: Usage }
        return try HTTPClient.decode(Envelope.self, data: await request("/v1/desktop/usage")).desktopStt
    }
    public func history(page: Int) async throws -> HistoryPage {
        guard page > 0 else { throw VoiceLabError.invalidResponse }
        let response = try HTTPClient.decode(
            HistoryResponse.self, data: await request("/v1/desktop/transcriptions?page=\(page)&page_size=50"))
        return try HistoryPage(items: response.records.map { try $0.asTranscript() }, hasMore: response.more)
    }
    public func transcribe(file: URL, language: DictationLanguage) async throws -> Transcript {
        try await transcribe(file: file, language: language, forAccount: nil)
    }
    public func transcribe(file: URL, language: DictationLanguage, forAccount accountID: String?) async throws -> Transcript {
        // The STT endpoint authoritatively checks the plan and reserves quota.
        // A separate usage GET doubles requests and can block valid dictation
        // when only the profile/usage request is temporarily unavailable.
        // Desktop dictation always detects speech independently of UI/alphabet
        // preferences, including callers restoring an old language selection.
        let multipart = try MultipartAudio(file: file, language: .auto)
        defer { try? FileManager.default.removeItem(at: multipart.url) }
        let data = try await request(
            "/v1/desktop/stt", method: "POST", contentType: multipart.contentType, file: multipart.url, accountID: accountID)
        let result = try HTTPClient.decode(STTResponse.self, data: data)
        guard !result.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
            result.durationMs >= 0,
            result.language.range(of: "^[a-z]{2,3}$", options: .regularExpression) != nil,
            (result.id == nil) == (result.revision == nil)
        else { throw VoiceLabError.invalidResponse }
        return Transcript(
            id: result.id ?? UUID().uuidString, text: result.text, language: result.language,
            durationMS: result.durationMs, revision: result.revision)
    }
    public func update(_ transcript: Transcript, text: String) async throws -> Transcript {
        guard transcript.isRemote, let revision = transcript.revision, revision > 0,
            transcript.id.range(of: "^dst_[A-Za-z0-9_-]+$", options: .regularExpression) != nil,
            !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else { throw VoiceLabError.invalidResponse }
        struct Edit: Encodable {
            let transcript: String
            let expectedRevision: Int

            enum CodingKeys: String, CodingKey {
                case transcript
                case expectedRevision = "expected_revision"
            }
        }
        let body = try JSONEncoder().encode(Edit(transcript: text, expectedRevision: revision))
        let data = try await request(
            "/v1/desktop/transcriptions/\(transcript.id)", method: "PATCH", body: body)
        let record = try HTTPClient.decode(RecordEnvelope.self, data: data).record
        return try record.asTranscript()
    }
}

private struct STTResponse: Decodable {
    let id: String?
    let text: String
    let language: String
    let durationMs: Int
    let revision: Int?
}
private struct RemoteTranscript: Decodable {
    let id: String
    let transcript: String?
    let text: String?
    let language: String?
    let durationMs: Int?
    let createdAt: String?
    let timestamp: String?
    let revision: Int
    func asTranscript() throws -> Transcript {
        guard id.range(of: "^dst_[A-Za-z0-9_-]+$", options: .regularExpression) != nil,
            let content = transcript ?? text, !content.isEmpty, revision > 0
        else { throw VoiceLabError.invalidResponse }
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let rawDate = createdAt ?? timestamp ?? ""
        let date = formatter.date(from: rawDate) ?? ISO8601DateFormatter().date(from: rawDate) ?? .distantPast
        return Transcript(
            id: id, text: content, language: language ?? "und", durationMS: durationMs ?? 0, createdAt: date,
            revision: revision)
    }
}
private struct RecordEnvelope: Decodable {
    let record: RemoteTranscript
    private enum CodingKeys: CodingKey { case transcription, data }
    init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        record =
            try c.decodeIfPresent(RemoteTranscript.self, forKey: .transcription)
            ?? c.decodeIfPresent(RemoteTranscript.self, forKey: .data) ?? RemoteTranscript(from: decoder)
    }
}
private struct HistoryResponse: Decodable {
    struct Pagination: Decodable {
        let hasMore: Bool?
        let nextPage: Int?
    }
    let records: [RemoteTranscript]
    let more: Bool
    private enum CodingKeys: CodingKey { case transcriptions, items, data, hasMore, nextPage, pagination }
    init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        records =
            try c.decodeIfPresent([RemoteTranscript].self, forKey: .transcriptions)
            ?? c.decodeIfPresent([RemoteTranscript].self, forKey: .items)
            ?? c.decode([RemoteTranscript].self, forKey: .data)
        let pagination = try c.decodeIfPresent(Pagination.self, forKey: .pagination)
        more =
            try c.decodeIfPresent(Bool.self, forKey: .hasMore) ?? pagination?.hasMore
            ?? (c.decodeIfPresent(Int.self, forKey: .nextPage) != nil || pagination?.nextPage != nil)
    }
}
