import Foundation

public enum OnboardingStep: String, Codable, CaseIterable, Sendable {
    case welcome
    case signIn = "signin"
    case aboutYou = "about-you"
    case typingPlaces = "typing-places"
    case permissions
    case microphone = "mic-test"
    case shortcut
    // Retain the stored identifier so existing onboarding progress still decodes.
    case alphabet = "language"
    case tryIntro = "try-it-intro"
    case tryMessage = "try-it-message"
    case tryEmail = "try-it-email"
    case tryList = "try-it-list"
    case timeSavings = "time-savings"
    case personalize, finish

    public var index: Int { Self.allCases.firstIndex(of: self) ?? 0 }
    public var next: Self { Self.allCases[min(index + 1, Self.allCases.count - 1)] }
    public var previous: Self { Self.allCases[max(index - 1, 0)] }
    public var isPractice: Bool { [.tryMessage, .tryEmail, .tryList].contains(self) }
    public var skippable: Bool { self == .microphone || isPractice }
    public var section: Int {
        switch self {
        case .welcome, .signIn, .aboutYou, .typingPlaces: 0
        case .permissions: 1
        case .microphone, .shortcut, .alphabet: 2
        case .tryIntro, .tryMessage, .tryEmail, .tryList, .timeSavings: 3
        case .personalize, .finish: 4
        }
    }
}

public enum OnboardingRole: String, CaseIterable, Sendable {
    case developer, founder, product, marketing, sales, operations, student, educator
    case writer, creator, consultant, legal, healthcare, support, other
}

public enum OnboardingUseCase: String, CaseIterable, Sendable {
    case messages, emails, documents, notes, ai, coding, posts, other
}

public struct OnboardingAnswers: Codable, Equatable, Sendable {
    public var role = ""
    public var useCases: [String] = []
    public var dictationLanguage = "auto"
    public var writingStyle = ""
    public var uiLanguage = "uz"
    public var theme = "auto"

    public init() {}

    public func validated() -> Self {
        var value = self
        if OnboardingRole(rawValue: role) == nil { value.role = "" }
        value.useCases = Array(Set(useCases.filter { OnboardingUseCase(rawValue: $0) != nil })).sorted()
        if !["auto", "uz", "en", "ru"].contains(dictationLanguage) { value.dictationLanguage = "auto" }
        if !["casual", "formal", "excited"].contains(writingStyle) { value.writingStyle = "" }
        if !["uz", "en", "ru"].contains(uiLanguage) { value.uiLanguage = "uz" }
        if !["auto", "light", "dark"].contains(theme) { value.theme = "auto" }
        return value
    }
}

/// This value lives inside the encrypted, account-scoped library snapshot.
/// Server completion prefills answers; it never grants permissions on a new Mac.
public struct OnboardingProgress: Codable, Equatable, Sendable {
    public var step: OnboardingStep = .aboutYou
    public var answers = OnboardingAnswers()
    public var completedAt: Date?
    public var completionVersion: Int?
    public var pendingSync = false
    public var profileLoaded = false
    public var completedExercises: [OnboardingStep] = []
    public init() {}

    public mutating func complete(at date: Date = .now) {
        completedAt = date
        pendingSync = true
        step = .finish
    }
}

public struct OnboardingProfile: Decodable, Sendable {
    public let role: String
    public let useCases: [String]
    public let dictationLanguage: String
    public let writingStyle: String
    public let uiLanguage: String
    public let theme: String
    public let revision: Int
    public let completedAt: String

    public var answers: OnboardingAnswers {
        var value = OnboardingAnswers()
        value.role = role
        value.useCases = useCases
        value.dictationLanguage = dictationLanguage
        value.writingStyle = writingStyle
        value.uiLanguage = uiLanguage
        value.theme = theme
        return value.validated()
    }
}

/// Readiness is derived from real permission/recording events, not from button taps.
public enum OnboardingPolicy {
    public static func canAdvance(
        step: OnboardingStep, signedIn: Bool, microphone: Bool, accessibility: Bool,
        heardMicrophone: Bool, shortcutDetected: Bool, practiceComplete: Bool
    ) -> Bool {
        switch step {
        case .welcome: true
        case .signIn, .finish: signedIn
        case .permissions: signedIn && microphone && accessibility
        case .microphone: signedIn && heardMicrophone
        case .shortcut: signedIn && shortcutDetected
        case .tryMessage, .tryEmail, .tryList: signedIn && practiceComplete
        default: signedIn
        }
    }
}
