import Foundation
import Observation
import VoiceLabCore

@main
struct LocalizationRegression {
    @MainActor
    static func main() throws {
        let bundle = Bundle(path: CommandLine.arguments[1])!
        let catalog = try JSONDecoder().decode(Catalog.self, from: Data(contentsOf: URL(fileURLWithPath: CommandLine.arguments[2])))
        let suite = "Echo.LocalizationRegression.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let localization = AppLocalization(defaults: defaults, bundle: bundle)
        let expectedSettings: [InterfaceLanguage: String] = [
            .uz: "Sozlamalar", .en: "Settings", .ru: "Настройки", .de: "Einstellungen",
            .ko: "설정", .hi: "सेटिंग", .es: "Ajustes", .ar: "الإعدادات", .fr: "Réglages",
            .bn: "সেটিংস", .pt: "Definições", .ur: "ترتیبات", .ja: "設定",
            .pcm: "Settings", .zhHans: "设置", .indonesian: "Pengaturan"
        ]
        for language in InterfaceLanguage.allCases {
            localization.language = language
            precondition(localization.localizedText("Sozlamalar") == expectedSettings[language], "Settings: \(language)")
            for (key, entry) in catalog.strings where entry.localizations?["en"] != nil {
                let expected = entry.localizations![language.rawValue]!.stringUnit.value
                precondition(localization.localizedText(key) == expected, "Bundle mismatch: \(language) / \(key)")
            }
            let formatted = localization.localizedText("%@ · %d min qoldi", arguments: ["Echo", 42])
            precondition(formatted.contains("Echo") && !formatted.contains("%@") && !formatted.contains("%d"))
            let hours = localization.localizedText("Echo bilan haftasiga %.1f soat tejashingiz mumkin.", arguments: [2.5])
            precondition(!hours.contains("%.1f"))
            let greeting = localization.localizedText("Salom, %@", arguments: ["Mardon"])
            precondition(greeting.contains("Mardon"))
            precondition(AppLocalization(defaults: defaults, bundle: bundle).language == language)
            precondition(defaults.string(forKey: "echo.onboarding.language") == language.rawValue)
        }
        // A mounted SwiftUI view observes the language read inside the lookup.
        // No .id(language) reset is needed, so editors keep focus and drafts.
        localization.language = .en
        let invalidations = Counter()
        withObservationTracking {
            _ = localization.localizedText("Sozlamalar")
        } onChange: {
            invalidations.increment()
        }
        localization.language = .pt
        precondition(invalidations.value == 1)
        precondition(localization.localizedText("Sozlamalar") == "Definições")
        precondition(InterfaceLanguage.ar.isRightToLeft && InterfaceLanguage.ur.isRightToLeft)
        precondition(!InterfaceLanguage.pt.isRightToLeft)
        let userText = "Mardon — 100%: original user note"
        precondition(localization.localizedText(userText) == userText)
        defaults.removeObject(forKey: AppLocalization.preferenceKey)
        defaults.set("ja", forKey: "echo.onboarding.language")
        precondition(AppLocalization(defaults: defaults, bundle: bundle).language == .ja)
        print("PASS: all 16 compiled language bundles, live switching, persistence, format values, RTL and unknown-text fallback.")
    }

    struct Catalog: Decodable {
        var strings: [String: Entry]
        struct Entry: Decodable {
            var localizations: [String: Translation]?
        }
        struct Translation: Decodable {
            var stringUnit: Unit
        }
        struct Unit: Decodable { var value: String }
    }

    final class Counter: @unchecked Sendable {
        private let lock = NSLock()
        private var count = 0
        func increment() { lock.withLock { count += 1 } }
        var value: Int { lock.withLock { count } }
    }
}
