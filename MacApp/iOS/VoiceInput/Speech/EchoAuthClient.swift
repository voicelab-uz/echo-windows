import CryptoKit
import Foundation
import Security

struct EchoAccount: Codable, Equatable, Sendable {
    let id: String
    let email: String
    let name: String
    let avatarURL: URL?

    private enum CodingKeys: String, CodingKey {
        case id, email, name, fullName, displayName, firstName, avatarUrl
    }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        if let text = try? values.decode(String.self, forKey: .id) {
            id = text
        } else {
            id = String(try values.decode(Int.self, forKey: .id))
        }
        email = try values.decode(String.self, forKey: .email)
        name = (try? values.decode(String.self, forKey: .fullName))
            ?? (try? values.decode(String.self, forKey: .displayName))
            ?? (try? values.decode(String.self, forKey: .name))
            ?? (try? values.decode(String.self, forKey: .firstName))
            ?? email
        let avatar = try? values.decode(String.self, forKey: .avatarUrl)
        avatarURL = avatar.flatMap(URL.init(string:)).flatMap { $0.scheme == "https" && $0.host != nil ? $0 : nil }
    }

    init(id: String, email: String, name: String, avatarURL: URL? = nil) {
        self.id = id
        self.email = email
        self.name = name
        self.avatarURL = avatarURL
    }

    func encode(to encoder: Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(id, forKey: .id)
        try values.encode(email, forKey: .email)
        try values.encode(name, forKey: .name)
        try values.encodeIfPresent(avatarURL?.absoluteString, forKey: .avatarUrl)
    }
}

/// Account dictation quota, separate from website credit balances.
struct EchoUsageSnapshot: Decodable, Sendable {
    let enabled: Bool
    let planName: String?
    let remainingSeconds: Int?
    let usedSeconds: Int?
    let usageLimitSeconds: Int?
    let resetsAt: String?

    private enum CodingKeys: String, CodingKey {
        case enabled, planName, remainingSeconds, usedSeconds, usageLimitSeconds, resetsAt
    }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        enabled = try values.decode(Bool.self, forKey: .enabled)
        planName = try values.decodeIfPresent(String.self, forKey: .planName)
        usageLimitSeconds = try values.decodeIfPresent(Int.self, forKey: .usageLimitSeconds)
        resetsAt = try values.decodeIfPresent(String.self, forKey: .resetsAt)
        // Go omitempty drops zero counters; an exhausted active quota is still zero.
        let zeroDefault: Int? = enabled && (usageLimitSeconds ?? 0) > 0 ? 0 : nil
        remainingSeconds = try values.decodeIfPresent(Int.self, forKey: .remainingSeconds) ?? zeroDefault
        usedSeconds = try values.decodeIfPresent(Int.self, forKey: .usedSeconds) ?? zeroDefault
    }
}

struct EchoSubscription: Decodable, Sendable {
    let active: Bool
    let packageName: String?
    let status: String?
    let dailySeconds: Int
    let maxRequestSeconds: Int
    let periodEndsAt: String?
    let cancelAtPeriodEnd: Bool
}

struct EchoContextAnswer: Codable, Equatable, Sendable {
    var choices: [String]
    var other: String
    var skipped: Bool

    init(choices: [String] = [], other: String = "", skipped: Bool = false) {
        self.choices = choices
        self.other = other
        self.skipped = skipped
    }
}

struct EchoOnboardingContext: Decodable, Sendable {
    let userId: String
    let revision: Int
    let questionnaireVersion: Int
    let answers: [String: EchoContextAnswer]
    let completedAt: String?
    let finishedAt: String?
}

struct EchoStatistics: Decodable, Sendable {
    struct Day: Decodable, Sendable {
        let day: String
        let language: String
        let platform: String?
        let words: Int
        let recordings: Int
        let durationMs: Int
        let estimatedTimeSavedMs: Int64?
    }

    struct Summary: Decodable, Sendable {
        let words: Int64
        let recordings: Int64
        let durationMs: Int64
        let estimatedTimeSavedMs: Int64
        let typingBaselineWpm: Int
        let estimationMethod: String

        var isTrusted: Bool {
            words >= 0 && recordings >= 0 && durationMs >= 0 && estimatedTimeSavedMs >= 0
                && typingBaselineWpm == 40 && estimationMethod == "per_recording_clamped"
        }
    }
    struct SavedTime: Equatable, Sendable {
        let hours: Int64
        let minutes: Int64
        let isLessThanOneMinute: Bool
    }

    /// Display the server estimate rounded to the nearest minute. A positive
    /// sub-minute estimate stays visibly below one minute rather than becoming zero.
    static func savedTime(milliseconds: Int64) -> SavedTime? {
        guard milliseconds >= 0 else { return nil }
        let roundedMinutes = milliseconds / 60_000 + (milliseconds % 60_000 >= 30_000 ? 1 : 0)
        return SavedTime(hours: roundedMinutes / 60, minutes: roundedMinutes % 60,
                         isLessThanOneMinute: milliseconds > 0 && roundedMinutes == 0)
    }
    let summary: Summary?
    var trustedSummary: Summary? { summary.flatMap { $0.isTrusted ? $0 : nil } }
    var estimatedSavedTime: SavedTime? {
        trustedSummary.flatMap { Self.savedTime(milliseconds: $0.estimatedTimeSavedMs) }
    }

    let days: [Day]
    // The API keeps daily totals separate from the additive device breakdown.
    // Missing platform data on older servers must not be interpreted as Mac.
    let platformDays: [Day]?
    let from: String
    let through: String
    let timeZone: String
}

/// Account dictations persisted by the STT API, separate from manually saved notes.
struct EchoDictationHistory: Decodable, Sendable {
    struct Item: Decodable, Identifiable, Sendable {
        let id: String
        let transcript: String
        let revision: Int
        let language: String
        let durationMs: Int
        let audioAvailable: Bool
        let createdAt: Date
        let updatedAt: Date

        private enum CodingKeys: String, CodingKey {
            case id, transcript, revision, language, durationMs, audioAvailable, createdAt, updatedAt
        }

        init(from decoder: Decoder) throws {
            let values = try decoder.container(keyedBy: CodingKeys.self)
            id = try values.decode(String.self, forKey: .id)
            transcript = try values.decode(String.self, forKey: .transcript)
            revision = try values.decode(Int.self, forKey: .revision)
            language = try values.decode(String.self, forKey: .language)
            durationMs = try values.decode(Int.self, forKey: .durationMs)
            audioAvailable = try values.decode(Bool.self, forKey: .audioAvailable)
            let formatter = ISO8601DateFormatter()
            func date(_ key: CodingKeys) throws -> Date {
                let text = try values.decode(String.self, forKey: key)
                formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
                if let date = formatter.date(from: text) { return date }
                formatter.formatOptions = [.withInternetDateTime]
                guard let date = formatter.date(from: text) else { throw EchoAuthError.invalidResponse }
                return date
            }
            createdAt = try date(.createdAt)
            updatedAt = try date(.updatedAt)
            guard id.hasPrefix("dst_"), id.count <= 128, revision >= 1, durationMs >= 0 else {
                throw EchoAuthError.invalidResponse
            }
        }
    }

    struct Pagination: Decodable, Sendable {
        let totalTranscriptions: Int
        let totalPages: Int
        let page: Int
        let pageSize: Int
        let hasNext: Bool
        let nextPage: Int?
    }

    let items: [Item]
    let pagination: Pagination
    var total: Int { pagination.totalTranscriptions }
    // The backend uses page numbers. Treat this as an opaque continuation in UI.
    var nextCursor: String? { pagination.nextPage.map(String.init) }

    private enum CodingKeys: String, CodingKey { case transcriptions, pagination }
    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        items = try values.decode([Item].self, forKey: .transcriptions)
        pagination = try values.decode(Pagination.self, forKey: .pagination)
        guard (1...100_000).contains(pagination.page), (1...100).contains(pagination.pageSize),
              pagination.totalTranscriptions >= 0, pagination.totalPages >= 0,
              items.count <= pagination.pageSize, Set(items.map(\.id)).count == items.count,
              pagination.hasNext == (pagination.nextPage != nil),
              pagination.nextPage == nil || (pagination.nextPage == pagination.page + 1 && pagination.nextPage! <= 100_000) else {
            throw EchoAuthError.invalidResponse
        }
    }
}

struct EchoContextSubmission: Encodable, Sendable {
    let expectedRevision: Int
    let mutationId: String
    let questionnaireVersion = 1
    let answers: [String: EchoContextAnswer]
    let uiLanguage: String
    let appVersion: String
    let platform = "ios"
    let completed: Bool

    init(revision: Int, answers: [String: EchoContextAnswer], completed: Bool,
         uiLanguage: String = "uz") {
        expectedRevision = revision
        mutationId = UUID().uuidString.lowercased()
        self.answers = answers
        self.uiLanguage = uiLanguage
        appVersion = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0"
        self.completed = completed
    }
}

enum EchoAuthError: LocalizedError, Sendable {
    case signedOut
    case invalidCredentials
    case invalidLoginInput
    case accountDisabled
    case rateLimited
    case rateLimitedUntil(Date)
    case invalidCallback
    case invalidResponse
    case mobileUnsupported
    case server(Int)
    case storage

    var errorDescription: String? {
        switch self {
        case .signedOut: "Echo akkauntingizga kiring."
        case .invalidCredentials: "Email yoki parol noto‘g‘ri."
        case .invalidLoginInput: "Email va parolingizni kiriting."
        case .accountDisabled: "Bu akkauntga kirish cheklangan. Yordam xizmatiga murojaat qiling."
        case .rateLimited: "Juda ko‘p urinish bo‘ldi. Biroz kutib, qayta urinib ko‘ring."
        case .rateLimitedUntil(let date): "Juda ko‘p urinish bo‘ldi. \(date.formatted(date: .omitted, time: .standard)) dan keyin qayta urinib ko‘ring."
        case .invalidCallback: "Kirish havolasi yaroqsiz yoki muddati tugagan."
        case .invalidResponse: "Server javobi kutilgan formatga mos kelmadi."
        case .mobileUnsupported: "Echo serveri iPhone orqali kirishni hali qabul qilmayapti. Backendda iOS authni yoqish kerak."
        case .server(let status): "Server xatosi (\(status))."
        case .storage: "Sessiyani xavfsiz saqlab bo‘lmadi."
        }
    }
    /// Honor seconds or an HTTP date, without allowing malformed or excessive
    /// headers to disable sign-in indefinitely. Missing headers use 30 seconds.
    static func retryDeadline(from header: String?, now: Date = .now) -> Date {
        let value = header?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        var delay: TimeInterval = 30
        if !value.isEmpty, value.utf8.allSatisfy({ (48...57).contains($0) }),
           let seconds = TimeInterval(value), seconds.isFinite {
            delay = seconds
        } else if !value.isEmpty, value.utf8.count <= 128 {
            let formatter = DateFormatter()
            formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.timeZone = TimeZone(secondsFromGMT: 0)
            formatter.isLenient = false
            formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss 'GMT'"
            if let date = formatter.date(from: value) { delay = date.timeIntervalSince(now) }
        }
        return now.addingTimeInterval(min(max(delay, 1), 3_600))
    }

}

/// Local troubleshooting only. Never captures request fields, bodies, URLs or tokens.
enum EchoAuthDiagnostics {
    static func recordHTTP(path: String, response: HTTPURLResponse, data: Data, grantType: String? = nil) {
        #if DEBUG
        struct Reply: Decodable {
            struct Failure: Decodable { let code: String? }
            let error: Failure?
            let request_id: String?
        }
        let reply = try? JSONDecoder().decode(Reply.self, from: data)
        var event: [String: String] = ["phase": phase(for: path, grantType: grantType), "status": String(response.statusCode)]
        event["errorCode"] = identifier(reply?.error?.code)
        event["requestID"] = identifier(response.value(forHTTPHeaderField: "X-Request-ID") ?? reply?.request_id)
        if let header = response.value(forHTTPHeaderField: "Retry-After"), header.count <= 128,
           header.unicodeScalars.allSatisfy({ CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789 ,:-").contains($0) }) {
            event["retryAfter"] = header
        }
        Writer.shared.append(event)
        #endif
    }

    static func recordFailure(phase: String, error: Error) {
        #if DEBUG
        let failure = error as NSError
        var event = ["phase": identifier(phase) ?? "unknown", "domain": identifier(failure.domain) ?? "redacted", "code": String(failure.code)]
        if let underlying = failure.userInfo[NSUnderlyingErrorKey] as? NSError {
            event["underlyingDomain"] = identifier(underlying.domain) ?? "redacted"
            event["underlyingCode"] = String(underlying.code)
        }
        Writer.shared.append(event)
        #endif
    }

    static func phase(for path: String, grantType: String? = nil) -> String {
        // Classify the fixed grant kind, never retain or log request fields.
        if path == "/api/v2/auth/desktop/token", grantType == "refresh_token" { return "native_refresh" }
        switch path {
        case "/v1/desktop/stt": return "stt_transcribe"
        case "/api/v1/billing/pricing": return "billing_pricing"
        case "/api/v1/account/subscription": return "billing_account_subscription"
        case "/api/v1/billing/paylov/cards": return "billing_cards"
        case "/api/v1/billing/paylov/subscription": return "billing_card_subscription"
        case "/api/v1/billing/paylov/payments": return "billing_payments"
        case "/api/v1/billing/polar/checkout/pending": return "billing_checkout_pending"
        default: break
        }
        if path.hasPrefix("/api/v1/billing/") { return "billing_request" }
        if path == "/api/auth/google/ios" { return "google_token_login" }
        if path == "/api/auth/google" { return "google_web_login" }
        if path == "/api/auth/apple" { return "apple_token_login" }
        if path == "/api/v2/auth/login" { return "password_login" }
        if path.contains("approve") { return "pkce_approve" }
        if path.contains("logout") { return "logout" }
        if path.contains("refresh") { return "native_refresh" }
        if path.contains("token") { return "pkce_exchange" }
        if path.contains("authoriz") { return "pkce_start" }
        return "auth_post"
    }

    #if DEBUG
    private static func identifier(_ value: String?) -> String? {
        guard let value, !value.isEmpty, value.count <= 96,
              value.unicodeScalars.allSatisfy({ CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789_.-").contains($0) }) else { return nil }
        return value
    }

    private final class Writer: @unchecked Sendable {
        static let shared = Writer()
        private let lock = NSLock()
        func append(_ fields: [String: String]) {
            lock.lock()
            defer { lock.unlock() }
            guard let directory = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first else { return }
            let url = directory.appendingPathComponent("echo-auth-diagnostics.json")
            var events = [[String: String]]()
            if let size = try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize,
               size <= 32_768, let data = try? Data(contentsOf: url),
               let prior = try? JSONDecoder().decode([[String: String]].self, from: data) {
                events = Array(prior.suffix(39))
            }
            var event = fields
            event["timestamp"] = ISO8601DateFormatter().string(from: .now)
            events.append(event)
            guard let data = try? JSONEncoder().encode(events) else { return }
            try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try? data.write(to: url, options: .atomic)
            try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        }
    }
    #endif
}

enum EchoIdentityProvider: String, CaseIterable, Sendable {
    case google, apple
    var name: String { self == .google ? "Google" : "Apple" }
    var path: String { self == .google ? "/api/auth/google/ios" : "/api/auth/apple" }
}

/// UI metadata only. Provider proofs and temporary web credentials never leave
/// the actor or enter preferences, diagnostics, Keychain or this requirement.
struct EchoIdentityLinkRequirement: Identifiable, Equatable, Sendable {
    let id: UUID
    let providerToLink: EchoIdentityProvider
    let existingProviders: [EchoIdentityProvider]
    let expiresAt: Date
    func isExpired(at now: Date = .now) -> Bool { expiresAt <= now }
}
struct EchoIdentityLinkRequired: Error, Sendable {
    let requirement: EchoIdentityLinkRequirement
}
enum EchoIdentityLinkError: Error, Sendable {
    case expired, canceled, unsupportedProvider, invalidProof, identityAlreadyLinked
}
private struct EchoOAuthConflict: Error, Sendable {
    let methods: [EchoIdentityProvider]
}

/// The desktop backend's PKCE contract, with credentials kept in this app's Keychain.
actor EchoAuthClient {
    static let shared = EchoAuthClient()
    static let apiOrigin: URL = {
        #if ECHO_DEV_ENVIRONMENT
        return URL(string: "https://dev.voicelab.uz")!
        #else
        return URL(string: "https://api.voicelab.uz")!
        #endif
    }()
    static let callbackURL = URL(string: "voicelab://auth/callback")!

    private struct Authorization: Sendable {
        let verifier: String
        let state: String
        let expiresAt: Date
    }

    private struct Session: Codable, Sendable {
        let account: EchoAccount
        let accessToken: String
        let refreshToken: String
        let accessExpiresAt: Date
        let refreshExpiresAt: Date
    }

    private struct AuthorizationReply: Decodable {
        let authorizationUrl: URL
        let authorizationRequestId: String
        let expiresIn: Int
    }

    private struct TokenReply: Decodable {
        let accessToken: String
        let refreshToken: String
        let tokenType: String
        let expiresIn: Int
        let refreshExpiresIn: Int
        let user: EchoAccount?
    }

    private struct ErrorReply: Decodable {
        struct Detail: Decodable {
            let code: String?
            let fields: [String: String]?
        }
        let error: Detail?
    }

    private struct ContextEnvelope: Decodable {
        let context: EchoOnboardingContext?
    }

    private struct PendingIdentityLink: Sendable {
        let requirement: EchoIdentityLinkRequirement
        let fields: [String: String]
    }
    private var pendingIdentityLink: PendingIdentityLink?
    private var activeIdentityLinkID: UUID?
    private var identityLinkExpiry: Task<Void, Never>?
    private var sessionGeneration = UUID()
    private var pending: Authorization?
    private var session: Session?
    private var refreshTask: Task<String, Error>?
    private var refreshBlockedUntil: Date?
    private var refreshBlockedGeneration: UUID?
    private let transport: URLSession
    private let keychain = EchoKeychain()

    private init() {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 30
        config.timeoutIntervalForResource = 120
        transport = URLSession(configuration: config, delegate: EchoRedirectBlocker(), delegateQueue: nil)
    }

    func restore() throws -> EchoAccount? {
        if let session { return session.account }
        guard let data = try keychain.read("session") else { return nil }
        let saved = try JSONDecoder().decode(Session.self, from: data)
        guard saved.refreshExpiresAt > .now else {
            try keychain.remove("session")
            return nil
        }
        session = saved
        return saved.account
    }

    func beginAuthorization() async throws -> URL {
        try await createAuthorization().authorizationUrl
    }

    private func createAuthorization() async throws -> AuthorizationReply {
        pending = nil
        sessionGeneration = UUID()
        refreshTask?.cancel()
        refreshTask = nil
        let generation = sessionGeneration
        let verifier = try Self.randomValue()
        let state = try Self.randomValue()
        let challenge = Self.base64URL(Data(SHA256.hash(data: Data(verifier.utf8))))
        let payload = [
            "client_id": "voicelab-desktop",
            "redirect_uri": Self.callbackURL.absoluteString,
            "code_challenge": challenge,
            "code_challenge_method": "S256",
            "state": state,
            "installation_id": try installationID(),
            "device_name": "iPhone",
            "app_version": Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0",
            "platform": "ios",
        ]
        let data = try await post("/api/v2/auth/desktop/authorizations", payload)
        guard generation == sessionGeneration else { throw EchoAuthError.signedOut }
        let reply = try Self.decode(AuthorizationReply.self, data)
        guard (1...600).contains(reply.expiresIn),
              reply.authorizationRequestId.hasPrefix("dau_"),
              reply.authorizationUrl.scheme == "https",
              reply.authorizationUrl.host == (Self.apiOrigin.host == "dev.voicelab.uz" ? "dev.voicelab.uz" : "voicelab.uz"),
              reply.authorizationUrl.path == "/app/sign-in",
              let query = URLComponents(url: reply.authorizationUrl, resolvingAgainstBaseURL: false)?.queryItems,
              query.count == 1, query.first?.name == "desktop_auth_id",
              query.first?.value == reply.authorizationRequestId else {
            throw EchoAuthError.invalidResponse
        }
        pending = Authorization(verifier: verifier, state: state,
                                expiresAt: .now.addingTimeInterval(Double(reply.expiresIn)))
        return reply
    }

    /// Google proves identity; the existing PKCE exchange issues the app's scoped
    /// session. The temporary web session is isolated and never stored in Keychain.
    func signInWithGoogle(idToken: String, linking requirementID: UUID? = nil) async throws -> EchoAccount {
        guard !idToken.isEmpty, idToken.count <= 16_384 else { throw EchoAuthError.invalidResponse }
        return try await signInWithProvider(.google, fields: ["id_token": idToken], linking: requirementID)
    }

    func signInWithApple(idToken: String, nonce: String, fullName: String?, linking requirementID: UUID? = nil) async throws -> EchoAccount {
        guard !idToken.isEmpty, idToken.utf8.count <= 16_384,
              (32...128).contains(nonce.utf8.count),
              nonce.range(of: "^[A-Za-z0-9_-]+$", options: .regularExpression) != nil else {
            throw EchoAuthError.invalidResponse
        }
        var fields = ["id_token": idToken, "nonce": nonce]
        if let name = fullName?.trimmingCharacters(in: .whitespacesAndNewlines), !name.isEmpty {
            fields["full_name"] = String(name.prefix(120))
        }
        return try await signInWithProvider(.apple, fields: fields, linking: requirementID)
    }

    /// Passwords are sent only to the API and never persisted. As with Google,
    /// only the scoped native session from the PKCE exchange reaches Keychain.
    func signInWithPassword(email: String, password: String) async throws -> EchoAccount {
        let email = email.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !email.isEmpty, email.utf8.count <= 320, !password.isEmpty,
              password.utf8.count <= 16_384 else { throw EchoAuthError.invalidLoginInput }
        return try await signInNatively(path: "/api/v2/auth/login",
                                       fields: ["email": email, "password": password])
    }

    private func signInWithProvider(_ provider: EchoIdentityProvider, fields: [String: String],
                                    linking requirementID: UUID?) async throws -> EchoAccount {
        if let requirementID {
            guard let link = pendingIdentityLink, link.requirement.id == requirementID else {
                throw EchoIdentityLinkError.canceled
            }
            guard !link.requirement.isExpired() else {
                pendingIdentityLink = nil
                throw EchoIdentityLinkError.expired
            }
            guard provider != link.requirement.providerToLink,
                  link.requirement.existingProviders.contains(provider) else {
                throw EchoIdentityLinkError.unsupportedProvider
            }
            activeIdentityLinkID = requirementID
            defer {
                if pendingIdentityLink?.requirement.id == requirementID {
                    pendingIdentityLink = nil
                    identityLinkExpiry?.cancel(); identityLinkExpiry = nil
                }
                if activeIdentityLinkID == requirementID { activeIdentityLinkID = nil }
            }
            return try await signInNatively(path: provider.path, fields: fields, linking: link)
        }
        pendingIdentityLink = nil
        identityLinkExpiry?.cancel(); identityLinkExpiry = nil
        do {
            return try await signInNatively(path: provider.path, fields: fields)
        } catch let conflict as EchoOAuthConflict {
            let methods = conflict.methods.filter { $0 != provider }
            guard !methods.isEmpty else { throw EchoIdentityLinkError.unsupportedProvider }
            let deadline = try Self.providerProofDeadline(fields["id_token"] ?? "")
            let requirement = EchoIdentityLinkRequirement(id: UUID(), providerToLink: provider,
                                                         existingProviders: methods, expiresAt: deadline)
            pendingIdentityLink = PendingIdentityLink(requirement: requirement, fields: fields)
            identityLinkExpiry = Task { [weak self] in
                try? await Task.sleep(for: .seconds(max(0, deadline.timeIntervalSinceNow)))
                guard !Task.isCancelled else { return }
                await self?.cancelIdentityLink(requirement.id)
            }
            throw EchoIdentityLinkRequired(requirement: requirement)
        }
    }

    func cancelIdentityLink(_ requirementID: UUID) {
        guard pendingIdentityLink?.requirement.id == requirementID || activeIdentityLinkID == requirementID else { return }
        pendingIdentityLink = nil; activeIdentityLinkID = nil
        identityLinkExpiry?.cancel(); identityLinkExpiry = nil
        cancelAuthorization()
    }

    /// The server verifies the signature. These already-verified claim timestamps
    /// only shorten local retention; a cached proof never outlives nine minutes.
    private static func providerProofDeadline(_ token: String, now: Date = .now) throws -> Date {
        let parts = token.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 3 else { throw EchoIdentityLinkError.invalidProof }
        var payload = String(parts[1]).replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        payload += String(repeating: "=", count: (4 - payload.count % 4) % 4)
        guard let data = Data(base64Encoded: payload),
              let claims = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let issued = claims["iat"] as? NSNumber, let expiry = claims["exp"] as? NSNumber else {
            throw EchoIdentityLinkError.invalidProof
        }
        let issuedAt = Date(timeIntervalSince1970: issued.doubleValue)
        guard issuedAt <= now.addingTimeInterval(60) else { throw EchoIdentityLinkError.invalidProof }
        let deadline = min(now.addingTimeInterval(9 * 60), issuedAt.addingTimeInterval(10 * 60),
                           Date(timeIntervalSince1970: expiry.doubleValue))
        guard deadline > now else { throw EchoIdentityLinkError.expired }
        return deadline
    }

    private func signInNatively(path: String, fields: [String: String],
                                linking link: PendingIdentityLink? = nil) async throws -> EchoAccount {
        if link == nil {
            pendingIdentityLink = nil; activeIdentityLinkID = nil
            identityLinkExpiry?.cancel(); identityLinkExpiry = nil
        }
        pending = nil
        sessionGeneration = UUID()
        refreshTask?.cancel(); refreshTask = nil
        var generation = sessionGeneration
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 30
        let loginTransport = URLSession(configuration: config, delegate: EchoRedirectBlocker(), delegateQueue: nil)
        defer { loginTransport.invalidateAndCancel() }
        do {
            struct Login: Decodable { let access: String }
            struct Approval: Decodable { let redirectUrl: URL }
            let data = try await post(path, fields, clearsSessionOnFailure: false, using: loginTransport)
            let login = try Self.decode(Login.self, data)
            guard generation == sessionGeneration, !Task.isCancelled,
                  (16...8192).contains(login.access.count) else { throw EchoAuthError.signedOut }
            if let link {
                guard pendingIdentityLink?.requirement.id == link.requirement.id else { throw EchoIdentityLinkError.canceled }
                guard !link.requirement.isExpired() else { throw EchoIdentityLinkError.expired }
                var body: [String: Any] = link.fields.reduce(into: [:]) { $0[$1.key] = $1.value }
                body["link_account"] = true
                let encoded = try JSONSerialization.data(withJSONObject: body, options: .sortedKeys)
                let linkedData = try await post(link.requirement.providerToLink.path, [:], bearer: login.access,
                                                clearsSessionOnFailure: false, using: loginTransport,
                                                encodedBody: encoded)
                struct Linked: Decodable {
                    struct Methods: Decodable { let google: Bool; let apple: Bool }
                    let linked: Bool
                    let signInMethods: Methods
                }
                let reply = try Self.decode(Linked.self, linkedData)
                guard generation == sessionGeneration, !Task.isCancelled else { throw EchoAuthError.signedOut }
                guard reply.linked, reply.signInMethods.google, reply.signInMethods.apple else {
                    throw EchoAuthError.invalidResponse
                }
                pendingIdentityLink = nil
                identityLinkExpiry?.cancel(); identityLinkExpiry = nil
            }
            // Temporary web ownership and any explicit link must succeed before
            // creating/approving PKCE or storing a scoped native session.
            guard generation == sessionGeneration, !Task.isCancelled else { throw EchoAuthError.signedOut }
            let authorization = try await createAuthorization()
            generation = sessionGeneration
            let approvalData = try await post("/api/v2/auth/desktop/authorizations/\(authorization.authorizationRequestId)/approve",
                                              [:], bearer: login.access, clearsSessionOnFailure: false,
                                              using: loginTransport)
            guard generation == sessionGeneration, !Task.isCancelled else { throw EchoAuthError.signedOut }
            let callback = try Self.decode(Approval.self, approvalData).redirectUrl
            let account = try await completeAuthorization(callback: callback)
            _ = try? await post("/api/v2/auth/logout", [:], timeout: 5,
                                clearsSessionOnFailure: false, using: loginTransport)
            guard generation == sessionGeneration else { throw EchoAuthError.signedOut }
            return account
        } catch {
            _ = try? await post("/api/v2/auth/logout", [:], timeout: 5,
                                clearsSessionOnFailure: false, using: loginTransport)
            if generation == sessionGeneration { pending = nil }
            throw error
        }
    }

    func completeAuthorization(callback: URL) async throws -> EchoAccount {
        guard let pending, pending.expiresAt > .now,
              callback.scheme == Self.callbackURL.scheme,
              callback.host == Self.callbackURL.host,
              callback.path == Self.callbackURL.path,
              callback.user == nil, callback.password == nil,
              callback.fragment == nil, callback.absoluteString.count <= 4096,
              let items = URLComponents(url: callback, resolvingAgainstBaseURL: false)?.queryItems,
              items.count == 2,
              items.filter({ $0.name == "state" }).count == 1,
              items.filter({ $0.name == "code" }).count == 1,
              items.first(where: { $0.name == "state" })?.value == pending.state,
              let code = items.first(where: { $0.name == "code" })?.value,
              code.range(of: "^dac_[A-Za-z0-9_-]{1,1020}$", options: .regularExpression) != nil else {
            throw EchoAuthError.invalidCallback
        }
        self.pending = nil
        let generation = sessionGeneration
        let data = try await post("/api/v2/auth/desktop/token", [
            "grant_type": "authorization_code",
            "client_id": "voicelab-desktop",
            "redirect_uri": Self.callbackURL.absoluteString,
            "code": code,
            "code_verifier": pending.verifier,
            "installation_id": try installationID(),
        ])
        return try install(Self.decode(TokenReply.self, data), fallback: nil, generation: generation).account
    }

    func cancelAuthorization() {
        pendingIdentityLink = nil; activeIdentityLinkID = nil
        identityLinkExpiry?.cancel(); identityLinkExpiry = nil
        pending = nil
        sessionGeneration = UUID()
        refreshTask?.cancel()
        refreshTask = nil
        refreshBlockedUntil = nil; refreshBlockedGeneration = nil
    }

    func accessToken() async throws -> String {
        if session == nil { _ = try restore() }
        guard let session, session.refreshExpiresAt > .now else { throw EchoAuthError.signedOut }
        if session.accessExpiresAt.timeIntervalSinceNow > 60 { return session.accessToken }
        return try await refresh()
    }

    func accessToken(replacing rejected: String) async throws -> String {
        if session == nil { _ = try restore() }
        if let current = session, current.accessToken != rejected,
           current.accessExpiresAt.timeIntervalSinceNow > 60 { return current.accessToken }
        if let current = session, current.accessToken == rejected {
            let invalidated = Session(account: current.account, accessToken: current.accessToken,
                                      refreshToken: current.refreshToken, accessExpiresAt: .distantPast,
                                      refreshExpiresAt: current.refreshExpiresAt)
            // Ordinary callers must not reuse a known-rejected token while its
            // refresh is throttled, including after the next app launch.
            session = invalidated
            try keychain.write(try JSONEncoder().encode(invalidated), key: "session")
        }
        return try await refresh()
    }

    func signOut() async throws {
        if session == nil { _ = try restore() }
        let old = session
        // A storage failure leaves the current session usable and surfaces an error.
        try keychain.remove("session")
        sessionGeneration = UUID()
        refreshTask?.cancel()
        refreshTask = nil
        refreshBlockedUntil = nil; refreshBlockedGeneration = nil
        session = nil
        pending = nil
        guard let old, let installation = try? installationID() else { return }
        // Revoke best-effort in the background; local sign-out is immediate.
        Task {
            _ = try? await post("/api/v2/auth/desktop/logout", [
                "refresh_token": old.refreshToken,
                "installation_id": installation,
            ], bearer: old.accessToken, timeout: 5, clearsSessionOnFailure: false)
        }
    }

    func getProfile() async throws -> EchoAccount {
        if session == nil { _ = try restore() }
        guard let current = session else { throw EchoAuthError.signedOut }
        let generation = sessionGeneration
        struct Identity: Decodable { let id: String; let displayName: String; let avatarUrl: String }
        struct Envelope: Decodable { let user: Identity }
        let data = try await authenticatedRequest("/v1/desktop/me")
        let identity = try Self.decode(Envelope.self, data).user
        guard generation == sessionGeneration, let latest = session,
              identity.id == current.account.id, latest.account.id == identity.id else {
            throw EchoAuthError.signedOut
        }
        let avatar = URL(string: identity.avatarUrl).flatMap { $0.scheme == "https" && $0.host != nil ? $0 : nil }
        let account = EchoAccount(id: identity.id, email: latest.account.email,
                                  name: identity.displayName.isEmpty ? latest.account.name : identity.displayName,
                                  avatarURL: avatar)
        let next = Session(account: account, accessToken: latest.accessToken, refreshToken: latest.refreshToken,
                           accessExpiresAt: latest.accessExpiresAt, refreshExpiresAt: latest.refreshExpiresAt)
        try keychain.write(try JSONEncoder().encode(next), key: "session")
        session = next
        return account
    }

    func getUsage() async throws -> EchoUsageSnapshot {
        struct Envelope: Decodable { let desktopStt: EchoUsageSnapshot }
        let data = try await authenticatedRequest("/v1/desktop/usage")
        let result = try Self.decode(Envelope.self, data).desktopStt
        guard [result.remainingSeconds, result.usedSeconds, result.usageLimitSeconds]
            .allSatisfy({ $0 == nil || $0! >= 0 }) else { throw EchoAuthError.invalidResponse }
        return result
    }

    func getSubscription() async throws -> EchoSubscription {
        struct Envelope: Decodable { let entitlement: EchoSubscription }
        let data = try await authenticatedRequest("/api/v1/billing/desktop/subscription")
        let result = try Self.decode(Envelope.self, data).entitlement
        guard result.dailySeconds >= 0, result.maxRequestSeconds >= 0 else { throw EchoAuthError.invalidResponse }
        return result
    }

    func getOnboardingContext() async throws -> EchoOnboardingContext? {
        let data = try await authenticatedRequest("/v1/desktop/onboarding/context")
        let context = try Self.decode(ContextEnvelope.self, data).context
        guard context == nil || (context!.revision > 0 && context!.questionnaireVersion == 1) else {
            throw EchoAuthError.invalidResponse
        }
        return context
    }

    func getDictationHistory(cursor: String? = nil) async throws -> EchoDictationHistory {
        let page: Int
        if let cursor {
            guard let parsed = Int(cursor), (1...100_000).contains(parsed), String(parsed) == cursor else {
                throw EchoAuthError.invalidResponse
            }
            page = parsed
        } else { page = 1 }
        let generation = sessionGeneration
        let data = try await authenticatedRequest("/v1/desktop/transcriptions?page=\(page)&page_size=50")
        guard generation == sessionGeneration, !Task.isCancelled else { throw EchoAuthError.signedOut }
        let result = try Self.decode(EchoDictationHistory.self, data)
        guard result.pagination.page == page, result.pagination.pageSize == 50 else {
            throw EchoAuthError.invalidResponse
        }
        return result
    }

    func getStatistics() async throws -> EchoStatistics {
        var query = URLComponents()
        query.queryItems = [URLQueryItem(name: "time_zone", value: TimeZone.current.identifier)]
        let data = try await authenticatedRequest("/v1/desktop/statistics?" + (query.percentEncodedQuery ?? ""))
        let result = try Self.decode(EchoStatistics.self, data)
        guard result.timeZone == TimeZone.current.identifier,
              result.days.count <= 18_200,
              result.days.allSatisfy({ $0.day >= result.from && $0.day <= result.through &&
                  $0.words >= 0 && $0.recordings >= 0 && $0.durationMs >= 0 &&
                  ($0.platform == nil || $0.platform == "desktop" || $0.platform == "ios") }),
              (result.platformDays?.count ?? 0) <= 36_400,
              (result.platformDays ?? []).allSatisfy({ $0.day >= result.from && $0.day <= result.through &&
                  $0.words >= 0 && $0.recordings >= 0 && $0.durationMs >= 0 &&
                  ($0.platform == "desktop" || $0.platform == "ios") }) else {
            throw EchoAuthError.invalidResponse
        }
        return result
    }

    func saveOnboardingContext(_ submission: EchoContextSubmission) async throws -> EchoOnboardingContext {
        let encoder = JSONEncoder()
        encoder.keyEncodingStrategy = .convertToSnakeCase
        let body = try encoder.encode(submission)
        let data = try await authenticatedRequest("/v1/desktop/onboarding/context", method: "PUT", body: body)
        guard let context = try Self.decode(ContextEnvelope.self, data).context,
              context.revision == submission.expectedRevision + 1,
              context.answers == submission.answers,
              (context.completedAt != nil) == submission.completed else {
            throw EchoAuthError.invalidResponse
        }
        return context
    }

    func completeOnboarding() async throws {
        let data = try await authenticatedRequest("/v1/desktop/onboarding/completion",
                                                  method: "PUT", body: Data("{}".utf8))
        guard let context = try Self.decode(ContextEnvelope.self, data).context,
              context.finishedAt != nil else { throw EchoAuthError.invalidResponse }
    }

    func billingRequest(path: String, method: String = "GET", body: Data? = nil,
                        idempotencyKey: String? = nil) async throws -> Data {
        let supported = path == "/api/v1/billing/pricing" && method == "GET"
            || path.hasPrefix("/api/v1/billing/paylov/")
            || path == "/api/v1/billing/polar/checkout" && method == "POST"
            || path == "/api/v1/billing/polar/checkout/pending" && method == "GET"
            || path == "/api/v1/account/subscription" && method == "GET"
        guard supported,
              !path.contains(".."), !path.contains("%"), !path.contains("?"),
              ["GET", "POST", "PATCH", "DELETE"].contains(method) else { throw EchoAuthError.invalidResponse }
        if let key = idempotencyKey {
            guard key.range(of: "^[A-Za-z0-9._:-]{8,128}$", options: .regularExpression) != nil else {
                throw EchoAuthError.invalidResponse
            }
        }
        if path == "/api/v1/billing/pricing", method == "GET" {
            // This catalog is public. A signed-out/expired local session must not
            // prevent displaying server prices; mutations retain owner auth below.
            let (data, response) = try await transport.data(for: Self.publicBillingPricingRequest())
            guard let http = response as? HTTPURLResponse, data.count <= 2_097_152 else {
                throw EchoAuthError.invalidResponse
            }
            EchoAuthDiagnostics.recordHTTP(path: path, response: http, data: data)
            guard (200..<300).contains(http.statusCode) else { throw EchoAuthError.server(http.statusCode) }
            return data
        }
        return try await authenticatedRequest(path, method: method, body: body, idempotencyKey: idempotencyKey)
    }

    static func publicBillingPricingRequest() -> URLRequest {
        var request = URLRequest(url: apiOrigin.appendingPathComponent("api/v1/billing/pricing"),
                                 cachePolicy: .reloadIgnoringLocalCacheData)
        request.httpMethod = "GET"
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        return request
    }

    #if DEBUG
    /// Explicit local troubleshooting probe: fixed GET routes only, no provider
    /// enrollment, checkout or payment mutation and no credentials in diagnostics.
    func diagnoseBilling() async {
        let paths = ["/api/v1/billing/pricing", "/api/v1/account/subscription",
                     "/api/v1/billing/paylov/cards", "/api/v1/billing/paylov/subscription",
                     "/api/v1/billing/paylov/payments"]
        for path in paths {
            do {
                let data = try await billingRequest(path: path)
                // A 200 can still carry a contract mismatch. Record only the
                // decoder's numeric error domain/code, never payload values.
                do {
                    switch path {
                    case "/api/v1/billing/pricing": _ = try EchoBilling.decode(EchoBilling.Pricing.self, data: data)
                    case "/api/v1/account/subscription": _ = try EchoBilling.decode(EchoBilling.AccountReply.self, data: data)
                    case "/api/v1/billing/paylov/cards": _ = try EchoBilling.decode(EchoBilling.CardsReply.self, data: data)
                    case "/api/v1/billing/paylov/subscription": _ = try EchoBilling.decode(EchoBilling.SubscriptionReply.self, data: data)
                    case "/api/v1/billing/paylov/payments": _ = try EchoBilling.decode(EchoBilling.PaymentsReply.self, data: data)
                    default: break
                    }
                } catch {
                    EchoAuthDiagnostics.recordFailure(phase: EchoAuthDiagnostics.phase(for: path) + "_decode", error: error)
                }
            } catch {
                EchoAuthDiagnostics.recordFailure(phase: EchoAuthDiagnostics.phase(for: path), error: error)
            }
        }
    }
    #endif

    private func authenticatedRequest(_ path: String, method: String = "GET", body: Data? = nil,
                                      idempotencyKey: String? = nil) async throws -> Data {
        let token = try await accessToken()
        let first = try await sendAuthenticated(path, method: method, body: body, token: token, idempotencyKey: idempotencyKey)
        let errorCode = try? Self.decode(ErrorReply.self, first.data).error?.code
        let isBillingRequest = path.hasPrefix("/api/v1/billing/") || path == "/api/v1/account/subscription"
        if first.response.statusCode == 401,
           errorCode == "invalid_desktop_token" || (isBillingRequest && errorCode == "session_expired") {
            let replacement = try await accessToken(replacing: token)
            let second = try await sendAuthenticated(path, method: method, body: body, token: replacement, idempotencyKey: idempotencyKey)
            guard (200..<300).contains(second.response.statusCode) else {
                throw EchoAuthError.server(second.response.statusCode)
            }
            return second.data
        }
        guard (200..<300).contains(first.response.statusCode) else {
            throw EchoAuthError.server(first.response.statusCode)
        }
        return first.data
    }

    private func sendAuthenticated(_ path: String, method: String, body: Data?, token: String, idempotencyKey: String? = nil)
        async throws -> (data: Data, response: HTTPURLResponse) {
        guard path.hasPrefix("/"), !path.hasPrefix("//"),
              let url = URL(string: path, relativeTo: Self.apiOrigin)?.absoluteURL,
              url.scheme == "https", url.host == Self.apiOrigin.host else {
            throw EchoAuthError.invalidResponse
        }
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if let idempotencyKey { request.setValue(idempotencyKey, forHTTPHeaderField: "Idempotency-Key") }
        if let body {
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = body
        }
        let (data, response) = try await transport.data(for: request)
        guard let http = response as? HTTPURLResponse, data.count <= 2_097_152 else {
            throw EchoAuthError.invalidResponse
        }
        EchoAuthDiagnostics.recordHTTP(path: path, response: http, data: data)
        return (data, http)
    }

    private func refresh() async throws -> String {
        if refreshBlockedGeneration == sessionGeneration, let deadline = refreshBlockedUntil, deadline > .now {
            throw EchoAuthError.rateLimitedUntil(deadline)
        }
        refreshBlockedUntil = nil; refreshBlockedGeneration = nil
        if let refreshTask { return try await refreshTask.value }
        guard let old = session, old.refreshExpiresAt > .now else { throw EchoAuthError.signedOut }
        let generation = sessionGeneration
        let task = Task<String, Error> {
            let data = try await post("/api/v2/auth/desktop/token", [
                "grant_type": "refresh_token",
                "client_id": "voicelab-desktop",
                "refresh_token": old.refreshToken,
                "installation_id": try installationID(),
            ])
            return try install(Self.decode(TokenReply.self, data), fallback: old, generation: generation).accessToken
        }
        refreshTask = task
        defer { if generation == sessionGeneration { refreshTask = nil } }
        do {
            return try await task.value
        } catch {
            if generation == sessionGeneration, let failure = error as? EchoAuthError {
                let deadline: Date?
                switch failure {
                case .rateLimitedUntil(let value): deadline = value
                case .rateLimited, .server(429): deadline = .now.addingTimeInterval(30)
                default: deadline = nil
                }
                if let deadline {
                    refreshBlockedUntil = min(max(deadline, .now.addingTimeInterval(1)), .now.addingTimeInterval(3600))
                    refreshBlockedGeneration = generation
                }
            }
            throw error
        }
    }

    private func install(_ reply: TokenReply, fallback: Session?, generation: UUID) throws -> Session {
        guard generation == sessionGeneration, !Task.isCancelled else { throw EchoAuthError.signedOut }
        guard reply.tokenType.caseInsensitiveCompare("Bearer") == .orderedSame,
              (16...8192).contains(reply.accessToken.count),
              (16...8192).contains(reply.refreshToken.count),
              (1...86400).contains(reply.expiresIn),
              (1...2_592_000).contains(reply.refreshExpiresIn),
              let account = reply.user ?? session?.account ?? fallback?.account else { throw EchoAuthError.invalidResponse }
        let next = Session(account: account,
                           accessToken: reply.accessToken,
                           refreshToken: reply.refreshToken,
                           accessExpiresAt: .now.addingTimeInterval(Double(reply.expiresIn)),
                           refreshExpiresAt: .now.addingTimeInterval(Double(reply.refreshExpiresIn)))
        try keychain.write(try JSONEncoder().encode(next), key: "session")
        session = next
        refreshBlockedUntil = nil; refreshBlockedGeneration = nil
        return next
    }

    private func installationID() throws -> String {
        if let data = try keychain.read("installation"), let value = String(data: data, encoding: .utf8) {
            return value
        }
        let value = UUID().uuidString
        try keychain.write(Data(value.utf8), key: "installation")
        return value
    }

    private func post(_ path: String, _ fields: [String: String], bearer: String? = nil,
                      timeout: TimeInterval = 30, clearsSessionOnFailure: Bool = true,
                      using overrideTransport: URLSession? = nil, encodedBody: Data? = nil) async throws -> Data {
        let generation = sessionGeneration
        guard path.hasPrefix("/"), !path.hasPrefix("//"),
              let url = URL(string: path, relativeTo: Self.apiOrigin)?.absoluteURL,
              url.scheme == "https", url.host == Self.apiOrigin.host else {
            throw EchoAuthError.invalidResponse
        }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = timeout
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if let bearer { request.setValue("Bearer \(bearer)", forHTTPHeaderField: "Authorization") }
        request.httpBody = try encodedBody ?? JSONEncoder().encode(fields)
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await (overrideTransport ?? transport).data(for: request)
        } catch {
            EchoAuthDiagnostics.recordFailure(phase: EchoAuthDiagnostics.phase(for: path, grantType: fields["grant_type"]), error: error)
            throw error
        }
        if let http = response as? HTTPURLResponse {
            EchoAuthDiagnostics.recordHTTP(path: path, response: http,
                                           data: data.count <= 2_097_152 ? data : Data(), grantType: fields["grant_type"])
        }
        guard let http = response as? HTTPURLResponse, data.count <= 2_097_152 else {
            throw EchoAuthError.invalidResponse
        }
        guard (200..<300).contains(http.statusCode) else {
            if http.statusCode == 429 {
                throw EchoAuthError.rateLimitedUntil(
                    EchoAuthError.retryDeadline(from: http.value(forHTTPHeaderField: "Retry-After"))
                )
            }
            if path == "/api/v2/auth/login" {
                let code = try? Self.decode(ErrorReply.self, data).error?.code
                switch (http.statusCode, code) {
                case (401, "invalid_credentials"): throw EchoAuthError.invalidCredentials
                case (422, "validation_failed"): throw EchoAuthError.invalidLoginInput
                case (403, "account_disabled"): throw EchoAuthError.accountDisabled
                default: break
                }
            }
            if http.statusCode == 409, path == "/api/auth/google/ios" || path == "/api/auth/apple",
               let detail = try? Self.decode(ErrorReply.self, data).error {
                if encodedBody != nil, detail.code == "identity_already_linked" {
                    throw EchoIdentityLinkError.identityAlreadyLinked
                }
                if encodedBody == nil, detail.code == "apple_account_conflict",
                   detail.fields?["link_required"] == "true", let methods = detail.fields?["sign_in_methods"], methods.count <= 128 {
                    let available = Set(methods.split(separator: ",").compactMap { EchoIdentityProvider(rawValue: String($0)) })
                    throw EchoOAuthConflict(methods: EchoIdentityProvider.allCases.filter { available.contains($0) })
                }
            }
            if encodedBody != nil, http.statusCode == 401,
               path == "/api/auth/google/ios" || path == "/api/auth/apple" {
                throw EchoIdentityLinkError.invalidProof
            }
            if http.statusCode == 422,
               let detail = try? Self.decode(ErrorReply.self, data).error,
               detail.fields?["platform"] != nil {
                throw EchoAuthError.mobileUnsupported
            }
            if http.statusCode == 401 {
                let detail = try? Self.decode(ErrorReply.self, data).error?.code
                if clearsSessionOnFailure, generation == sessionGeneration,
                   detail == "invalid_refresh_token" || detail == "session_expired" {
                    sessionGeneration = UUID()
                    session = nil
                    try? keychain.remove("session")
                    throw EchoAuthError.signedOut
                }
            }
            throw EchoAuthError.server(http.statusCode)
        }
        return data
    }

    private static func decode<T: Decodable>(_ type: T.Type, _ data: Data) throws -> T {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        return try decoder.decode(type, from: data)
    }

    private static func randomValue() throws -> String {
        var bytes = [UInt8](repeating: 0, count: 32)
        guard SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) == errSecSuccess else {
            throw EchoAuthError.storage
        }
        return base64URL(Data(bytes))
    }

    private static func base64URL(_ data: Data) -> String {
        data.base64EncodedString().replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
    }
}

private final class EchoRedirectBlocker: NSObject, URLSessionTaskDelegate, Sendable {
    func urlSession(_ session: URLSession, task: URLSessionTask,
                    willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest,
                    completionHandler: @escaping (URLRequest?) -> Void) {
        completionHandler(nil)
    }
}

private struct EchoKeychain {
    private var service: String {
        let base = "uz.voicelab.echo.ios.auth"
        return EchoAuthClient.apiOrigin.host == "dev.voicelab.uz" ? base + ".dev" : base
    }

    func read(_ key: String) throws -> Data? {
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
                                    kSecAttrService as String: service,
                                    kSecAttrAccount as String: key,
                                    kSecReturnData as String: true,
                                    kSecMatchLimit as String: kSecMatchLimitOne]
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = result as? Data else { throw EchoAuthError.storage }
        return data
    }

    func write(_ data: Data, key: String) throws {
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
                                    kSecAttrService as String: service,
                                    kSecAttrAccount as String: key]
        let attributes: [String: Any] = [kSecValueData as String: data,
                                         kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly]
        let status = SecItemAdd(query.merging(attributes) { _, new in new } as CFDictionary, nil)
        if status == errSecDuplicateItem {
            guard SecItemUpdate(query as CFDictionary, attributes as CFDictionary) == errSecSuccess else {
                throw EchoAuthError.storage
            }
        } else if status != errSecSuccess { throw EchoAuthError.storage }
    }

    func remove(_ key: String) throws {
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
                                    kSecAttrService as String: service,
                                    kSecAttrAccount as String: key]
        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else { throw EchoAuthError.storage }
    }
}
