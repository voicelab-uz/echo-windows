import Foundation
import Testing

@testable import VoiceLabCore

private actor CaptureTransport: HTTPTransport {
    private(set) var requests: [URLRequest] = []
    private let waitForCancellation: Bool
    private let response: Data

    init(response: Data = Data(#"{"text":"speech","language":"en","duration_ms":1000}"#.utf8), waitForCancellation: Bool = false) {
        self.response = response
        self.waitForCancellation = waitForCancellation
    }

    func send(_ request: URLRequest, uploadFile: URL?) async throws -> (Data, HTTPURLResponse) {
        requests.append(request)
        if waitForCancellation { try await Task.sleep(for: .seconds(60)) }
        return (response, HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
    }
}

@Suite struct STTTransportTests {
    @Test func sttUsesLongSessionConfigurationOnlyForExactPostRoute() async throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try Data("audio".utf8).write(to: file)
        defer { try? FileManager.default.removeItem(at: file) }
        let transport = CaptureTransport()
        _ = try await HTTPClient(transport: transport).request(
            "/v1/desktop/stt", method: "POST", contentType: "multipart/form-data", uploadFile: file)
        let request = try #require(await transport.requests.first)
        #expect(request.timeoutInterval == HTTPTransportPolicy.stt.requestTimeout)

        let selected = HTTPTransportPolicy.profile(method: request.httpMethod, path: request.url?.path)
        #expect(selected == HTTPTransportPolicy.stt)
        let sttConfiguration = URLSessionTransport.makeConfiguration(for: selected)
        #expect(sttConfiguration.timeoutIntervalForRequest == 15 * 60)
        #expect(sttConfiguration.timeoutIntervalForResource == 15 * 60)

        let ordinaryConfiguration = URLSessionTransport.makeConfiguration(for: HTTPTransportPolicy.profile(
            method: "PATCH", path: "/v1/desktop/stt"))
        #expect(ordinaryConfiguration.timeoutIntervalForRequest == 30)
        #expect(ordinaryConfiguration.timeoutIntervalForResource == 150)
        #expect(HTTPTransportPolicy.profile(method: "GET", path: "/v1/desktop/stt") == HTTPTransportPolicy.ordinary)
        #expect(HTTPTransportPolicy.ordinary.maximumResponseBytes == 2 * 1_024 * 1_024)
        #expect(HTTPTransportPolicy.stt.maximumResponseBytes == 8 * 1_024 * 1_024)
    }

    @Test func requestIDLoggingAcceptsOnlyServerFormat() {
        #expect(HTTPClient.sanitizedRequestIDForLogging("req_Abc_123-x") == "req_Abc_123-x")
        #expect(HTTPClient.sanitizedRequestIDForLogging("req_") == "unknown")
        #expect(HTTPClient.sanitizedRequestIDForLogging("req_abc\nforged") == "unknown")
        #expect(HTTPClient.sanitizedRequestIDForLogging(String(repeating: "x", count: 81)) == "unknown")
        #expect(HTTPClient.sanitizedRequestIDForLogging("arbitrary-id") == "unknown")
    }

    @Test func validLargeTranscriptDecodesAboveOldLimitAndStaysWithinBound() async throws {
        let text = String(repeating: "漢", count: 800_000) + " END"
        #expect(text.unicodeScalars.count < 1_000_000)
        #expect(text.utf8.count < 4 * 1_024 * 1_024)
        let responseData = try JSONEncoder().encode(STTEnvelope(text: text))
        #expect(responseData.count > 2 * 1_024 * 1_024)
        #expect(responseData.count < HTTPTransportPolicy.stt.maximumResponseBytes)
        let url = URL(string: "https://api.voicelab.uz/v1/desktop/stt")!
        let response = HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil)!
        _ = try URLSessionTransport.validateResponse(responseData, response: response, profile: HTTPTransportPolicy.stt)

        let transport = StubTransport([
            (200, tokenJSON()), (200, String(decoding: responseData, as: UTF8.self)),
        ])
        let http = HTTPClient(transport: transport)
        let auth = try await restoredAuth(http: http, secrets: MemorySecrets())
        let audio = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".wav")
        try Data("audio".utf8).write(to: audio)
        defer { try? FileManager.default.removeItem(at: audio) }
        let transcript = try await DesktopAPI(http: http, auth: auth).transcribe(file: audio, language: .auto)
        #expect(transcript.text == text)
        #expect(transcript.text.hasSuffix(" END"))
    }

    @Test func worstCaseEscapedTranscriptFitsSTTEnvelope() throws {
        let text = String(repeating: "\0", count: 1_000_000)
        let data = try JSONEncoder().encode(STTEnvelope(text: text))
        #expect(data.count > 6_000_000)
        #expect(data.count < HTTPTransportPolicy.stt.maximumResponseBytes)
        let response = HTTPURLResponse(
            url: URL(string: "https://api.voicelab.uz/v1/desktop/stt")!, statusCode: 200,
            httpVersion: nil, headerFields: nil)!
        _ = try URLSessionTransport.validateResponse(data, response: response, profile: HTTPTransportPolicy.stt)

        let overBound = Data(repeating: 0, count: HTTPTransportPolicy.stt.maximumResponseBytes + 1)
        #expect(throws: VoiceLabError.self) {
            try URLSessionTransport.validateResponse(overBound, response: response, profile: HTTPTransportPolicy.stt)
        }
    }

    @Test func multipartAudioLimitMatchesServerAndRejectsOversizeBeforeCopy() throws {
        #expect(MultipartAudio.maximumFileBytes == 500 * 1024 * 1024)
        let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".wav")
        #expect(FileManager.default.createFile(atPath: file.path, contents: Data()))
        defer { try? FileManager.default.removeItem(at: file) }
        let handle = try FileHandle(forWritingTo: file)
        try handle.truncate(atOffset: UInt64(MultipartAudio.maximumFileBytes + 1))
        try handle.close()
        do {
            _ = try MultipartAudio(file: file, language: .auto)
            Issue.record("Expected oversized sparse audio file to be rejected before copying")
        } catch let error as VoiceLabError {
            #expect(error == .audioTooLarge)
            #expect(error.errorDescription?.contains("500 MiB") == true)
        }
    }

    @Test func ordinaryUploadKeepsShortDeadline() async throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try Data("audio".utf8).write(to: file)
        defer { try? FileManager.default.removeItem(at: file) }
        let transport = CaptureTransport()
        _ = try await HTTPClient(transport: transport).request(
            "/v1/desktop/transcriptions/dst_example", method: "PATCH", contentType: "application/json", uploadFile: file)
        let request = try #require(await transport.requests.first)
        #expect(request.timeoutInterval == 120)
    }

    @Test func sttFailureIsNotRetried() async throws {
        let transport = FailingTransport()
        await #expect(throws: URLError.self) {
            try await HTTPClient(transport: transport).request("/v1/desktop/stt", method: "POST", uploadFile: nil)
        }
        #expect(await transport.calls == 1)
    }

    @Test func callerCancellationStopsSTTTransport() async throws {
        let transport = CaptureTransport(waitForCancellation: true)
        let task = Task { try await HTTPClient(transport: transport).request("/v1/desktop/stt", method: "POST") }
        while await transport.requests.isEmpty { await Task.yield() }
        task.cancel()
        await #expect(throws: CancellationError.self) { try await task.value }
        #expect(await transport.requests.count == 1)
    }
}

private actor FailingTransport: HTTPTransport {
    private(set) var calls = 0
    func send(_ request: URLRequest, uploadFile: URL?) async throws -> (Data, HTTPURLResponse) {
        calls += 1
        throw URLError(.timedOut)
    }
}

private struct STTEnvelope: Encodable {
    let text: String
    let language = "en"
    let durationMS = 1_000
    enum CodingKeys: String, CodingKey {
        case text, language
        case durationMS = "duration_ms"
    }
}
