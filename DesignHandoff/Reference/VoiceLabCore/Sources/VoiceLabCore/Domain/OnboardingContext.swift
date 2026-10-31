import Foundation

public enum ContextQuestion: String, CaseIterable, Identifiable, Sendable {
    case discovery, intent, work, writing
    case meetingApps = "meeting_apps", meetingProblems = "meeting_problems"
    public var id: String { rawValue }
    public var limit: Int {
        switch self { case .discovery, .work: 1; case .intent: 5; case .writing, .meetingProblems: 8; case .meetingApps: 9 }
    }
    public var options: [String] {
        switch self {
        case .discovery: ["friend", "youtube", "instagram", "telegram", "tiktok", "linkedin", "x", "facebook", "search", "article", "podcast", "newsletter", "ai_chat", "other"]
        case .intent: ["dictation", "meeting_notes", "accessibility", "exploring", "other"]
        case .work: ["developer", "founder", "product", "marketing", "sales", "operations", "student", "educator", "writer", "creator", "consultant", "legal", "healthcare", "support", "recruiting", "data_analysis", "other"]
        case .writing: ["messages", "emails", "documents", "notes", "ai", "coding", "posts", "other"]
        case .meetingApps: ["zoom", "google_meet", "teams", "slack", "facetime", "telegram", "discord", "in_person", "none", "other"]
        case .meetingProblems: ["preparation", "taking_notes", "focus", "action_items", "finding_notes", "sharing", "language", "none", "other"]
        }
    }
}
public struct ContextAnswer: Codable, Equatable, Sendable {
    public var choices: [String]
    public var other: String
    public var skipped: Bool
    public init(choices: [String] = [], other: String = "", skipped: Bool = false) {
        self.choices = choices; self.other = other; self.skipped = skipped
    }
}
public struct OnboardingContext: Decodable, Equatable, Sendable {
    public let userId: String
    public let revision: Int
    public let questionnaireVersion: Int
    public let answers: [String: ContextAnswer]
    public let uiLanguage, appVersion, platform, createdAt, updatedAt: String
    public let completedAt: String?
    public let finishedAt: String?
}
public struct ContextSubmission: Codable, Equatable, Sendable {
    public let expectedRevision: Int
    public let mutationId: String
    public let questionnaireVersion: Int
    public let answers: [String: ContextAnswer]
    public let uiLanguage: String
    public let appVersion: String
    public let platform: String
    public let completed: Bool
    public init(revision: Int, answers: [String: ContextAnswer], language: String, appVersion: String, completed: Bool) {
        questionnaireVersion = 1; platform = "darwin"
        expectedRevision = revision; mutationId = UUID().uuidString.lowercased()
        self.answers = answers; uiLanguage = language; self.appVersion = appVersion; self.completed = completed
    }
}

/// Encrypted, account-scoped journal. A pending mutation keeps the exact idempotency key on relaunch.
public struct QuestionnaireDraft: Codable, Equatable, Sendable {
    public var revision: Int
    public var index: Int
    public var answers: [String: ContextAnswer]
    public var pending: ContextSubmission?
    public var reviewing: Bool?
    public init(revision: Int, index: Int, answers: [String: ContextAnswer], pending: ContextSubmission?, reviewing: Bool = false) {
        self.revision = revision; self.index = index; self.answers = answers; self.pending = pending; self.reviewing = reviewing
    }
}
