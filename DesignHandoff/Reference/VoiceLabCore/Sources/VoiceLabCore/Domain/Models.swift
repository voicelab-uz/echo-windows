import Foundation

public enum DictationLanguage: String, Codable, CaseIterable, Sendable {
    case auto, uz, en, ru
    public var title: String {
        switch self {
        case .auto: "Avtomatik"
        case .uz: "O‘zbekcha"
        case .en: "English"
        case .ru: "Русский"
        }
    }
}

public struct Account: Codable, Equatable, Sendable {
    public let id: String
    public let email: String
    public let name: String
    public init(id: String, email: String, name: String) {
        self.id = id
        self.email = email
        self.name = name
    }
    private enum CodingKeys: String, CodingKey {
        case id, email, name, fullName, displayName, firstName, lastName
    }
    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        if let text = try? c.decode(String.self, forKey: .id) {
            id = text
        } else {
            id = String(try c.decode(Int.self, forKey: .id))
        }
        email = try c.decode(String.self, forKey: .email)
        name =
            try c.decodeIfPresent(String.self, forKey: .fullName)
            ?? c.decodeIfPresent(String.self, forKey: .displayName)
            ?? c.decodeIfPresent(String.self, forKey: .name)
            ?? c.decodeIfPresent(String.self, forKey: .firstName) ?? email
        guard !id.isEmpty, !email.isEmpty else { throw VoiceLabError.invalidResponse }
    }
    public func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(email, forKey: .email)
        try c.encode(name, forKey: .name)
    }
}

public struct Transcript: Identifiable, Codable, Equatable, Sendable {
    public var id: String
    public var text: String
    public var language: String
    /// Text-based code-switching evidence; optional for previously saved records.
    /// The original provider language remains intact in `language`.
    public var detectedLanguages: [String]?
    public var durationMS: Int
    public var createdAt: Date
    public var revision: Int?
    public var usageContext: DesktopUsageContext?
    public var isRemote: Bool { id.hasPrefix("dst_") }
    public init(
        id: String = UUID().uuidString, text: String, language: String, durationMS: Int,
        createdAt: Date = .now, revision: Int? = nil
    ) {
        self.id = id
        self.text = text
        self.language = language
        self.detectedLanguages = SpeechLanguages(text: text, reportedLanguage: language).codes
        self.durationMS = durationMS
        self.createdAt = createdAt
        self.revision = revision
    }
}

public struct Note: Identifiable, Codable, Equatable, Sendable {
    public var id: UUID = UUID()
    public var title: String = ""
    public var body: String = ""
    public var updatedAt: Date = .now
    public var isPinned: Bool = false
    public init() {}
    public var displayTitle: String {
        title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "Yangi qayd" : title
    }
}

public struct VocabularyEntry: Identifiable, Codable, Equatable, Sendable {
    public var id: UUID = UUID()
    public var word: String
    public var replacement: String
    public var language: VocabularyLanguage
    /// A dictionary fix: when `word` (the misspelling) is heard it is written as `replacement`.
    /// It uses the same replacement pass as snippets but is listed in the dictionary.
    public var isCorrection: Bool
    /// True for anything that rewrites text (snippets and corrections).
    public var isSnippet: Bool { !replacement.isEmpty }
    /// A snippet proper: shown on the Snippets tab.
    public var isPhrase: Bool { isSnippet && !isCorrection }
    public init(word: String, replacement: String = "", language: VocabularyLanguage = .all,
                isCorrection: Bool = false) {
        self.word = word
        self.replacement = replacement
        self.language = language
        self.isCorrection = isCorrection
    }
    private enum CodingKeys: CodingKey { case id, word, replacement, language, correction }
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        word = try container.decode(String.self, forKey: .word)
        replacement = try container.decodeIfPresent(String.self, forKey: .replacement) ?? ""
        // Preserve existing local dictionaries and replacements on upgrade.
        language = try container.decodeIfPresent(VocabularyLanguage.self, forKey: .language) ?? .all
        isCorrection = try container.decodeIfPresent(Bool.self, forKey: .correction) ?? false
    }
    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(word, forKey: .word)
        try container.encode(replacement, forKey: .replacement)
        try container.encode(language, forKey: .language)
        if isCorrection { try container.encode(true, forKey: .correction) }
    }
}

public struct LibrarySnapshot: Codable, Sendable {
    public var schemaVersion = 1
    public var transcripts: [Transcript] = []
    public var notes: [Note] = []
    public var pendingUsage: [String: DesktopUsageContext]?
    public var noteSync: NoteSyncState?
    public var vocabulary: [VocabularyEntry] = []
    public var onboarding: OnboardingProgress?
    public var questionnaireDraft: QuestionnaireDraft?
    /// Account-bound practice text retained across an update or ordinary restart.
    public var onboardingPracticeDraft: String?
    public init() {}
}

public struct Usage: Decodable, Sendable {
    public let enabled: Bool
    public let planName: String?
    public let usageLimitSeconds: Int?
    public let usedSeconds: Int?
    public let reservedSeconds: Int?
    public let remainingSeconds: Int?
    public var remaining: Int {
        max(0, remainingSeconds ?? ((usageLimitSeconds ?? 0) - (usedSeconds ?? 0) - (reservedSeconds ?? 0)))
    }
    public var fraction: Double {
        guard let limit = usageLimitSeconds, limit > 0 else { return 0 }
        return min(1, Double((usedSeconds ?? 0) + (reservedSeconds ?? 0)) / Double(limit))
    }
}

public enum VoiceLabError: LocalizedError, Sendable, Equatable {
    case signedOut, invalidAccessToken, invalidResponse, invalidCallback, sessionChanged, emptyAudio,
        audioTooLarge
    case server(status: Int, message: String, requestID: String?)
    case rateLimited(retryAt: Date, requestID: String?)
    case dictationLimitReached(requestID: String?)
    case storage(String)
    public var errorDescription: String? {
        switch self {
        case .signedOut: "Echo akkauntingizga kiring."
        case .invalidAccessToken: "Sessiyani tasdiqlab bo‘lmadi. Birozdan keyin qayta urinib ko‘ring."
        case .invalidResponse: "Server javobi kutilgan formatga mos kelmadi."
        case .invalidCallback: "Kirish havolasi yaroqsiz yoki muddati tugagan. Qayta urinib ko‘ring."
        case .sessionChanged: "Amal davomida akkaunt o‘zgardi. Qayta urinib ko‘ring."
        case .emptyAudio: "Audio bo‘sh yoki nutq aniqlanmadi."
        case .audioTooLarge: "Audio hajmi 500 MiB dan oshmasligi kerak."
        case .rateLimited(let retryAt, _):
            Self.rateLimitMessage(retryAt: retryAt)
        case .dictationLimitReached:
            "Ushbu davr uchun ovozli yozish limitingiz tugadi."
        case .server(_, let message, _):
            message
        case .storage(let message): message
        }
    }
    private static func rateLimitMessage(retryAt: Date) -> String {
        let time = retryAt.formatted(date: .omitted, time: .standard)
        return "Urinishlar vaqtincha cheklangan. \(time) dan keyin qayta urinib ko‘ring."
    }
}
