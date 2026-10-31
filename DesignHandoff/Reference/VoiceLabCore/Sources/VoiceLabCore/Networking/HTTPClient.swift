import Foundation
import OSLog

public protocol HTTPTransport: Sendable {
    func send(_ request: URLRequest, uploadFile: URL?) async throws -> (Data, HTTPURLResponse)
}

struct HTTPTransportProfile: Equatable, Sendable {
    let isSTT: Bool
    let requestTimeout: TimeInterval
    let resourceTimeout: TimeInterval
    let maximumResponseBytes: Int
}

enum HTTPTransportPolicy {
    static let ordinary = HTTPTransportProfile(
        isSTT: false, requestTimeout: 30, resourceTimeout: 150, maximumResponseBytes: 2 * 1_024 * 1_024)
    // The synchronous API has a 14-minute outer budget. Its transcript is
    // bounded to 1M Unicode scalars / 4 MiB; JSON escaping can require 6 MB.
    static let stt = HTTPTransportProfile(
        isSTT: true, requestTimeout: 15 * 60, resourceTimeout: 15 * 60, maximumResponseBytes: 8 * 1_024 * 1_024)

    static func profile(method: String?, path: String?) -> HTTPTransportProfile {
        method == "POST" && path == "/v1/desktop/stt" ? stt : ordinary
    }
}

private final class RedirectBlocker: NSObject, URLSessionTaskDelegate, Sendable {
    func urlSession(
        _ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void
    ) {
        completionHandler(nil)
    }
}

public final class URLSessionTransport: HTTPTransport, Sendable {
    private let ordinarySession: URLSession
    private let sttSession: URLSession
    public init() {
        ordinarySession = Self.makeSession(for: HTTPTransportPolicy.ordinary)
        sttSession = Self.makeSession(for: HTTPTransportPolicy.stt)
    }
    private static func makeSession(for profile: HTTPTransportProfile) -> URLSession {
        URLSession(configuration: makeConfiguration(for: profile), delegate: RedirectBlocker(), delegateQueue: nil)
    }
    static func makeConfiguration(for profile: HTTPTransportProfile) -> URLSessionConfiguration {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = profile.requestTimeout
        configuration.timeoutIntervalForResource = profile.resourceTimeout
        configuration.urlCache = nil
        configuration.httpCookieStorage = nil
        return configuration
    }
    public func send(_ request: URLRequest, uploadFile: URL? = nil) async throws -> (Data, HTTPURLResponse) {
        let profile = HTTPTransportPolicy.profile(method: request.httpMethod, path: request.url?.path)
        let session = profile.isSTT ? sttSession : ordinarySession
        let result: (Data, URLResponse)
        if let uploadFile {
            result = try await session.upload(for: request, fromFile: uploadFile)
        } else {
            result = try await session.data(for: request)
        }
        return try Self.validateResponse(result.0, response: result.1, profile: profile)
    }
    static func validateResponse(
        _ data: Data, response: URLResponse, profile: HTTPTransportProfile
    ) throws -> (Data, HTTPURLResponse) {
        guard let response = response as? HTTPURLResponse, data.count <= profile.maximumResponseBytes else {
            throw VoiceLabError.invalidResponse
        }
        return (data, response)
    }
}

public struct HTTPClient: Sendable {
    public static let productionOrigin = URL(string: "https://api.voicelab.uz")!
    private static let logger = Logger(subsystem: "uz.voicelab.desktop", category: "HTTP")
    private let transport: any HTTPTransport
    private let rateLimits: HTTPRateLimitGate
    public let environment: ServerEnvironment
    public init(
        transport: any HTTPTransport = URLSessionTransport(),
        persistAuthenticationCooldown: Bool = false,
        environment: ServerEnvironment = .production
    ) {
        self.transport = transport
        self.environment = environment
        rateLimits = HTTPRateLimitGate(persistAuthenticationCooldown: persistAuthenticationCooldown,
                                      namespace: environment.storageNamespace)
    }

    public func request(
        _ path: String, method: String = "GET", token: String? = nil, body: Data? = nil,
        contentType: String = "application/json", uploadFile: URL? = nil, idempotencyKey: String? = nil
    ) async throws -> Data {
        guard path.hasPrefix("/"), !path.hasPrefix("//"),
            let url = URL(string: path, relativeTo: environment.apiOrigin)?.absoluteURL,
            url.host == environment.apiOrigin.host, url.scheme == environment.apiOrigin.scheme,
            url.port == environment.apiOrigin.port, url.user == nil, url.password == nil
        else { throw VoiceLabError.invalidResponse }
        let rateLimitKey =
            url.path.hasPrefix("/api/v2/auth/desktop/")
            ? "desktop-auth:\(url.lastPathComponent)" : "\(method):\(url.path)"
        try await rateLimits.check(rateLimitKey)
        var request = URLRequest(url: url)
        request.httpMethod = method
        let profile = HTTPTransportPolicy.profile(method: method, path: url.path)
        request.timeoutInterval = profile.isSTT ? profile.requestTimeout : (uploadFile == nil ? 25 : 120)
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if let token { request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization") }
        if body != nil || uploadFile != nil {
            request.setValue(contentType, forHTTPHeaderField: "Content-Type")
        }
        if let idempotencyKey { request.setValue(idempotencyKey, forHTTPHeaderField: "Idempotency-Key") }
        request.httpBody = body
        let (data, response) = try await sendWithDictationRecovery(
            request, uploadFile: uploadFile, rateLimitKey: rateLimitKey)
        guard (200..<300).contains(response.statusCode) else {
            let envelope = try? Self.decode(ErrorEnvelope.self, data: data)
            let failureID = envelope?.requestId ?? response.value(forHTTPHeaderField: "X-Request-ID")
            let logRequestID = Self.sanitizedRequestIDForLogging(failureID)
            Self.logger.error(
                "Request failed: \(method, privacy: .public) \(url.path, privacy: .public), HTTP \(response.statusCode), code=\(envelope?.error?.code ?? "unknown", privacy: .public), request_id=\(logRequestID, privacy: .public)"
            )
            if response.statusCode == 429 {
                if ["desktop_usage_limit_reached", "daily_dictation_limit_reached"].contains(
                    envelope?.error?.code ?? "")
                {
                    throw VoiceLabError.dictationLimitReached(requestID: failureID)
                }
                let retryAt = HTTPRateLimitGate.retryDate(response.value(forHTTPHeaderField: "Retry-After"))
                let requestID = envelope?.requestId ?? response.value(forHTTPHeaderField: "X-Request-ID")
                await rateLimits.record(rateLimitKey, retryAt: retryAt, requestID: requestID)
                throw VoiceLabError.rateLimited(retryAt: retryAt, requestID: requestID)
            }
            if url.path == "/api/v2/auth/desktop/token", response.statusCode == 401,
                ["invalid_refresh_token", "session_expired"].contains(envelope?.error?.code ?? "")
            {
                throw VoiceLabError.signedOut
            }
            if url.path.hasPrefix("/v1/desktop/"), response.statusCode == 401,
                envelope?.error?.code == "invalid_desktop_token"
            {
                throw VoiceLabError.invalidAccessToken
            }
            let message =
                envelope?.error?.message ?? envelope?.message
                ?? HTTPURLResponse.localizedString(forStatusCode: response.statusCode)
            throw VoiceLabError.server(
                status: response.statusCode, message: String(message.prefix(500)),
                requestID: envelope?.requestId)
        }
        return data
    }

    /// These two server rejections occur before inference and do not commit usage.
    /// Recover brief contention without replaying an ambiguous upload, quota error,
    /// proxy 429, or arbitrary server failure. The caller retains the audio throughout.
    private func sendWithDictationRecovery(
        _ request: URLRequest, uploadFile: URL?, rateLimitKey: String
    ) async throws -> (Data, HTTPURLResponse) {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: .seconds(10))
        var retries = 0
        while true {
            try Task.checkCancellation()
            let result = try await send(request, uploadFile: uploadFile)
            let (data, response) = result
            guard request.httpMethod == "POST", request.url?.path == "/v1/desktop/stt",
                response.statusCode == 429,
                let envelope = try? Self.decode(ErrorEnvelope.self, data: data),
                ["concurrent_dictation", "stt_overloaded"].contains(envelope.error?.code ?? "")
            else { return result }

            let retryAt = HTTPRateLimitGate.retryDate(response.value(forHTTPHeaderField: "Retry-After"))
            let requestID = envelope.requestId ?? response.value(forHTTPHeaderField: "X-Request-ID")
            await rateLimits.record(rateLimitKey, retryAt: retryAt, requestID: requestID)
            // Backoff and jitter avoid all waiting desktops resubmitting together.
            let delay = max(retryAt.timeIntervalSinceNow, pow(2, Double(retries)))
                + Double.random(in: 0.1...0.3)
            guard retries < 3, clock.now.advanced(by: .seconds(delay)) <= deadline else { return result }
            retries += 1
            Self.logger.info(
                "Dictation temporarily busy; retry \(retries), code=\(envelope.error?.code ?? "unknown", privacy: .public), request_id=\(Self.sanitizedRequestIDForLogging(requestID), privacy: .public)"
            )
            try await Task.sleep(for: .seconds(delay))
            try Task.checkCancellation()
            try await rateLimits.check(rateLimitKey)
        }
    }

    static func sanitizedRequestIDForLogging(_ value: String?) -> String {
        guard let value, (5...80).contains(value.utf8.count), value.hasPrefix("req_"),
            value.utf8.dropFirst(4).allSatisfy({
                (48...57).contains($0) || (65...90).contains($0) || (97...122).contains($0) || $0 == 95 || $0 == 45
            })
        else { return "unknown" }
        return value
    }

    private func send(_ request: URLRequest, uploadFile: URL?) async throws -> (Data, HTTPURLResponse) {
        let startedAt = ProcessInfo.processInfo.systemUptime
        do {
            return try await transport.send(request, uploadFile: uploadFile)
        } catch let error as URLError {
            let elapsedMilliseconds = Int((ProcessInfo.processInfo.systemUptime - startedAt) * 1_000)
            Self.logger.error(
                "Transport failed: \(request.httpMethod ?? "GET", privacy: .public) \(request.url?.path ?? "/", privacy: .public), url_error \(error.code.rawValue), elapsed_ms \(elapsedMilliseconds)"
            )
            // Only this read-only profile request is replayable after an ambiguous
            // network failure. Never replay STT, edits or rotating auth credentials.
            guard request.httpMethod == "GET", request.url?.path == "/v1/desktop/usage",
                request.httpBody == nil, uploadFile == nil,
                error.code == .timedOut || error.code == .networkConnectionLost
            else { throw error }
            try await Task.sleep(for: .milliseconds(600))
            try Task.checkCancellation()
            try await rateLimits.check("GET:/v1/desktop/usage")
            return try await transport.send(request, uploadFile: nil)
        }
    }
    public static func decode<T: Decodable>(_ type: T.Type, data: Data) throws -> T {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        return try decoder.decode(type, from: data)
    }
    public static func json(_ fields: [String: String]) throws -> Data { try JSONEncoder().encode(fields) }
}

private struct ErrorEnvelope: Decodable {
    struct Detail: Decodable {
        let code: String?
        let message: String?
    }
    let error: Detail?
    let message: String?
    let requestId: String?
}
