import Foundation
import VoiceLabCore

@main
struct AlphabetPreferencesRegression {
    @MainActor
    static func main() {
        let suite = "VoiceLab.AlphabetRegression.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        for oldLanguage in ["uz", "en", "ru"] {
            defaults.set(oldLanguage, forKey: "language")
            defaults.set("modern", forKey: "uzbekAlphabet")
            let preferences = Preferences(defaults: defaults)
            precondition(defaults.string(forKey: "language") == nil)
            precondition(preferences.uzbekAlphabet == .modern)
            precondition(
                DictationText.render(
                    "Show character", language: .en,
                    alphabet: preferences.uzbekAlphabet, vocabulary: []) == "Show character")
            precondition(
                DictationText.render(
                    "Shahar", language: .uz,
                    alphabet: preferences.uzbekAlphabet, vocabulary: []) == "Şahar")
            preferences.uzbekAlphabet = .current
            precondition(Preferences(defaults: defaults).uzbekAlphabet == .current)
        }
        defaults.set("unknown-future-value", forKey: "uzbekAlphabet")
        precondition(Preferences(defaults: defaults).uzbekAlphabet == .current)
        print("PASS: legacy language preferences are removed; alphabet choice persists independently.")

        let insertion = Preferences(defaults: defaults)
        precondition(insertion.textInsertionMethod == .automatic)
        insertion.textInsertionMethod = .typing
        precondition(Preferences(defaults: defaults).textInsertionMethod == .typing)
        defaults.set("future-mode", forKey: "textInsertionMethod")
        precondition(Preferences(defaults: defaults).textInsertionMethod == .automatic)
        print("PASS: insertion method persists and unknown values use automatic mode.")

        let dock = Preferences(defaults: defaults)
        precondition(dock.alwaysShowDockIcon)
        dock.alwaysShowDockIcon = false
        precondition(!Preferences(defaults: defaults).alwaysShowDockIcon)
        defaults.set(true, forKey: "alwaysShowDockIcon")
        dock.reloadFromStorage()
        precondition(dock.alwaysShowDockIcon)
        print("PASS: Dock visibility defaults to on, persists opt-out, and reloads changes.")

        let existing = Preferences(defaults: defaults)
        existing.microphoneID = "previous-device"
        existing.uzbekAlphabet = .modern
        existing.autoPaste = false
        existing.textInsertionMethod = .typing
        existing.retainHistory = false
        existing.appearance = "light"
        existing.alwaysShowDockIcon = false
        // Cleanup now happens after the observable model is constructed.
        defaults.removePersistentDomain(forName: suite)
        existing.reloadFromStorage()
        precondition(existing.microphoneID.isEmpty && existing.shortcut == .fn)
        precondition(existing.uzbekAlphabet == .current)
        precondition(existing.textInsertionMethod == .automatic)
        precondition(existing.autoPaste && existing.retainHistory && existing.appearance == "system")
        precondition(Preferences(defaults: defaults).appearance == "system")
        precondition(existing.alwaysShowDockIcon && Preferences(defaults: defaults).alwaysShowDockIcon)
        print("PASS: deferred startup cleanup reloads preferences without replacing the UI model.")
    }
}
