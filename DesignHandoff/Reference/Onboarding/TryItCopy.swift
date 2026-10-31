import Foundation

struct TryItCopy: Decodable {
    let heading, instruction, placeholder, ready, signingIn, completingSignIn, retryIn: String
    let successHeading, successHint, stopHint, next: String
    let signInTitle, signInSubtitle, signInButton, restoringSession: String
    let listening, transcribing, success, cancel: String
    let signInError, connectionError, quotaError, rateLimitError, emptyError, serviceError: String

    /// Copy mentions the shortcut by name, so it follows the user's current shortcut.
    static var catalog: [String: TryItCopy] {
        guard let catalog = OnboardingShortcutName.catalog("TryItLanguages", as: TryItCopy.self),
              WelcomeLanguage.allCases.allSatisfy({ catalog[$0.rawValue] != nil })
        else { fatalError("Missing Try it translations.") }
        return catalog
    }
}
