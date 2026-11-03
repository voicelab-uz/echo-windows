import Foundation
import os

private let logger = Logger(subsystem: "uz.voicelab.echo.ios", category: "speech-api")

/// Echo's account-bound desktop STT endpoint returns a transcript in one response.
/// The backend checks plan and quota; no API key is shipped in the app.
struct VoiceLabClient: Sendable {
    static let minimumDuration: TimeInterval = 0.5
    private static let endpoint = EchoAuthClient.apiOrigin.appendingPathComponent("v1/desktop/stt")
    private let session: URLSession

    init?() {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 120
        configuration.timeoutIntervalForResource = 150
        session = URLSession(configuration: configuration, delegate: EchoSTTRedirectBlocker(), delegateQueue: nil)
    }

    func transcribe(audio: URL, duration: TimeInterval, language: String) async throws(DictationError) -> String {
        _ = duration
        let script = UzbekTranscriptScript.preferredScript(shared: UserDefaults(suiteName: VoiceBridge.appGroup))
        let form: EchoAudioForm
        do { form = try EchoAudioForm(audio: audio, language: language) }
        catch { throw .recognitionFailed }
        defer { try? FileManager.default.removeItem(at: form.url) }

        let token: String
        do { token = try await EchoAuthClient.shared.accessToken() }
        catch {
            EchoAuthDiagnostics.recordFailure(phase: "stt_access_token", error: error)
            throw .notConfigured
        }

        let first = try await upload(form, token: token)
        if first.statusCode == 401, first.errorCode == "invalid_desktop_token" {
            // A typed token rejection happened before billing; refresh once.
            let replacement: String
            do { replacement = try await EchoAuthClient.shared.accessToken(replacing: token) }
            catch {
                EchoAuthDiagnostics.recordFailure(phase: "stt_access_token", error: error)
                throw .notConfigured
            }
            let second = try await upload(form, token: replacement)
            return try interpret(second, script: script)
        }
        return try interpret(first, script: script)
    }

    private func upload(_ form: EchoAudioForm, token: String) async throws(DictationError) -> EchoSTTReply {
        var request = URLRequest(url: Self.endpoint)
        request.httpMethod = "POST"
        request.timeoutInterval = 120
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue(form.contentType, forHTTPHeaderField: "Content-Type")

        do {
            let (data, response) = try await session.upload(for: request, fromFile: form.url)
            guard let response = response as? HTTPURLResponse else { throw DictationError.recognitionFailed }
            // Only the existing diagnostics allowlist (status, Retry-After,
            // sanitized error code/request ID) sees this reply. Never log audio,
            // multipart fields, transcript content, credentials or endpoint URLs.
            EchoAuthDiagnostics.recordHTTP(path: "/v1/desktop/stt", response: response,
                                           data: data.count <= 2_097_152 ? data : Data())
            guard data.count <= 2_097_152 else { throw DictationError.recognitionFailed }
            let decoder = JSONDecoder()
            decoder.keyDecodingStrategy = .convertFromSnakeCase
            let transcript = try? decoder.decode(EchoTranscriptReply.self, from: data)
            let failure = try? decoder.decode(EchoErrorReply.self, from: data)
            return EchoSTTReply(statusCode: response.statusCode, transcript: transcript,
                                errorCode: failure?.error?.code)
        } catch let error as URLError {
            EchoAuthDiagnostics.recordFailure(phase: "stt_transcribe", error: error)
            logger.error("STT network error: \(error.code.rawValue, privacy: .public)")
            switch error.code {
            case .notConnectedToInternet, .networkConnectionLost, .cannotFindHost,
                 .cannotConnectToHost, .dnsLookupFailed, .timedOut, .dataNotAllowed:
                throw .offline
            default: throw .recognitionFailed
            }
        } catch {
            throw .recognitionFailed
        }
    }

    private func interpret(_ reply: EchoSTTReply, script: UzbekTranscriptScript) throws(DictationError) -> String {
        guard (200..<300).contains(reply.statusCode) else {
            logger.error("STT HTTP \(reply.statusCode, privacy: .public), category \(reply.failureKind.rawValue, privacy: .public)")
            switch reply.failureKind {
            case .serviceUnavailable: throw .serviceUnavailable
            case .authentication: throw .notConfigured
            case .dailyQuota, .accountAllowance: throw .noCredits
            case .noSpeech: throw .noSpeech
            case .rateLimited, .concurrentDictation, .overloaded, .other: throw .recognitionFailed
            }
        }
        guard let transcript = reply.transcript,
              !transcript.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              transcript.durationMs >= 0,
              transcript.language.range(of: "^[a-z]{2,3}$", options: .regularExpression) != nil else {
            throw .recognitionFailed
        }
        return UzbekTranscriptScript.render(transcript.text, detectedLanguage: transcript.language, script: script)
    }
}

/// These categories deliberately separate retryable request throttling from
/// daily/account allowances. No classification automatically replays an upload.
private enum EchoSTTFailureKind: String {
    case rateLimited = "rate_limited"
    case concurrentDictation = "concurrent_dictation"
    case overloaded = "stt_overloaded"
    case dailyQuota = "daily_quota"
    case accountAllowance = "account_allowance"
    case authentication, serviceUnavailable = "service_unavailable", noSpeech = "no_speech", other
}

private struct EchoSTTReply {
    let statusCode: Int
    let transcript: EchoTranscriptReply?
    let errorCode: String?
    var failureKind: EchoSTTFailureKind {
        if statusCode == 401 { return .authentication }
        if statusCode == 503 { return .serviceUnavailable }
        if statusCode == 429 && errorCode == "daily_dictation_limit_reached" { return .dailyQuota }
        if statusCode == 402 || statusCode == 429 && errorCode == "desktop_usage_limit_reached" { return .accountAllowance }
        if statusCode == 429 && errorCode == "concurrent_dictation" { return .concurrentDictation }
        if statusCode == 429 && errorCode == "stt_overloaded" { return .overloaded }
        if statusCode == 429 { return .rateLimited }
        if ["no_speech_detected", "invalid_audio_duration"].contains(errorCode ?? "") { return .noSpeech }
        return .other
    }
}

private struct EchoTranscriptReply: Decodable {
    let text: String
    let language: String
    let durationMs: Int
}

private struct EchoErrorReply: Decodable {
    struct Detail: Decodable { let code: String? }
    let error: Detail?
}

private final class EchoSTTRedirectBlocker: NSObject, URLSessionTaskDelegate, Sendable {
    func urlSession(_ session: URLSession, task: URLSessionTask,
                    willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest,
                    completionHandler: @escaping (URLRequest?) -> Void) {
        completionHandler(nil)
    }
}

/// File-backed multipart upload keeps recorded audio out of a second in-memory copy.
private struct EchoAudioForm {
    let url: URL
    let contentType: String

    init(audio: URL, language: String) throws {
        let properties = try audio.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
        guard properties.isRegularFile == true,
              let size = properties.fileSize, size > 0, size <= 200 * 1024 * 1024,
              audio.pathExtension.lowercased() == "m4a",
              ["auto", "uz", "en", "ru", "ar", "tr"].contains(language) else {
            throw DictationError.recognitionFailed
        }
        let boundary = "Echo-\(UUID().uuidString)"
        contentType = "multipart/form-data; boundary=\(boundary)"
        url = URL.temporaryDirectory.appending(path: "\(UUID().uuidString).multipart")
        guard FileManager.default.createFile(atPath: url.path, contents: nil,
                                             attributes: [.posixPermissions: 0o600]) else {
            throw DictationError.recognitionFailed
        }
        do {
            let input = try FileHandle(forReadingFrom: audio)
            let output = try FileHandle(forWritingTo: url)
            defer { try? input.close(); try? output.close() }
            try output.write(contentsOf: Data("--\(boundary)\r\nContent-Disposition: form-data; name=\"language\"\r\n\r\n\(language)\r\n--\(boundary)\r\nContent-Disposition: form-data; name=\"audio\"; filename=\"audio.m4a\"\r\nContent-Type: audio/mp4\r\n\r\n".utf8))
            var copied = 0
            while let chunk = try input.read(upToCount: 64 * 1024), !chunk.isEmpty {
                copied += chunk.count
                guard copied <= 200 * 1024 * 1024 else { throw DictationError.recognitionFailed }
                try output.write(contentsOf: chunk)
            }
            try output.write(contentsOf: Data("\r\n--\(boundary)--\r\n".utf8))
        } catch {
            try? FileManager.default.removeItem(at: url)
            throw error
        }
    }
}
