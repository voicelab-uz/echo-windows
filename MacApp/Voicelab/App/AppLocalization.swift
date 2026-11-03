import Foundation
import Observation
import VoiceLabCore

enum InterfaceLanguage: String, CaseIterable, Identifiable {
    case uz, en, ru, de, ko, hi, es, ar, fr, bn, pt, ur, ja, pcm
    case zhHans = "zh-Hans", indonesian = "id"
    var id: String { rawValue }
    var isRightToLeft: Bool { self == .ar || self == .ur }
    var title: String {
        switch self {
        case .uz: "O‘zbekcha"
        case .en: "English"
        case .ru: "Русский"
        case .de: "Deutsch"
        case .ko: "한국어"
        case .zhHans: "简体中文"
        case .hi: "हिन्दी"
        case .es: "Español"
        case .ar: "العربية"
        case .fr: "Français"
        case .bn: "বাংলা"
        case .pt: "Português"
        case .indonesian: "Bahasa Indonesia"
        case .ur: "اردو"
        case .ja: "日本語"
        case .pcm: "Naijá · Nigerian Pidgin"
        }
    }
    var locale: Locale { Locale(identifier: rawValue) }
}

/// Observable language selection updates existing editors without recreating their view identity.
/// Native string catalogs hold translations; user text never passes through this lookup.
@MainActor @Observable
final class AppLocalization {
    static let preferenceKey = "interfaceLanguage"
    static let shared = AppLocalization()
    var language: InterfaceLanguage {
        didSet {
            defaults.set(language.rawValue, forKey: Self.preferenceKey)
            defaults.set(language.rawValue, forKey: "echo.onboarding.language")
        }
    }
    private let defaults: UserDefaults
    private let bundles: [InterfaceLanguage: Bundle]

    init(defaults: UserDefaults = .standard, bundle: Bundle = .main) {
        self.defaults = defaults
        bundles = Dictionary(uniqueKeysWithValues: InterfaceLanguage.allCases.compactMap { language in
            guard let path = bundle.path(forResource: language.rawValue, ofType: "lproj"),
                let localizedBundle = Bundle(path: path) else { return nil }
            return (language, localizedBundle)
        })
        language =
            InterfaceLanguage(rawValue: defaults.string(forKey: Self.preferenceKey)
                ?? defaults.string(forKey: "echo.onboarding.language") ?? "") ?? .uz
    }

    static func error(_ error: any Error) -> String {
        if let failure = error as? VoiceLabError, case .rateLimited(let retryAt, _) = failure {
            let time = retryAt.formatted(.dateTime.hour().minute().second().locale(shared.language.locale))
            return text("Urinishlar vaqtincha cheklangan. %@ dan keyin qayta urinib ko‘ring.", time)
        }
        return text(error.localizedDescription)
    }

    static func text(_ key: String, _ arguments: CVarArg...) -> String {
        shared.localizedText(key, arguments: arguments)
    }

    static func speechLanguage(_ transcript: Transcript) -> String {
        switch transcript.languageCodeForDisplay {
        case "mul": return text("Ko‘ptilli")
        case "und": return text("Til aniqlanmadi")
        case let code:
            return shared.language.locale.localizedString(forLanguageCode: code)
                ?? Locale(identifier: "en").localizedString(forLanguageCode: code) ?? code.uppercased()
        }
    }

    func localizedText(_ key: String, arguments: [CVarArg] = []) -> String {
        let language = self.language
        // All supported interface languages are bundled. Keep a fallback for
        // unknown server messages, without changing the user's language choice.
        let fallback = bundles[.en]?.localizedString(forKey: key, value: key, table: nil) ?? key
        let value = bundles[language]?.localizedString(forKey: key, value: fallback, table: nil) ?? fallback
        guard !arguments.isEmpty else { return value }
        return String(format: value, locale: language.locale, arguments: arguments)
    }
}
