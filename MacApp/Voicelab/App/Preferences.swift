import Foundation
import Observation
import VoiceLabCore

@MainActor @Observable
final class Preferences {
    var interfaceLanguage: InterfaceLanguage {
        get { AppLocalization.shared.language }
        set { AppLocalization.shared.language = newValue }
    }
    var shortcut: DictationShortcut {
        didSet {
            if let data = try? JSONEncoder().encode(shortcut) {
                defaults.set(data, forKey: "dictationShortcut")
            }
        }
    }
    var microphoneID: String { didSet { defaults.set(microphoneID, forKey: "microphoneID") } }
    var uzbekAlphabet: UzbekAlphabet {
        didSet { defaults.set(uzbekAlphabet.rawValue, forKey: "uzbekAlphabet") }
    }
    var autoPaste: Bool { didSet { defaults.set(autoPaste, forKey: "autoPaste") } }
    var textInsertionMethod: TextInsertionMethod {
        didSet { defaults.set(textInsertionMethod.rawValue, forKey: "textInsertionMethod") }
    }
    var activationMode: DictationActivationMode {
        didSet { defaults.set(activationMode.rawValue, forKey: "activationMode") }
    }
    var retainHistory: Bool { didSet { defaults.set(retainHistory, forKey: "retainHistory") } }
    var appearance: String { didSet { defaults.set(appearance, forKey: "appearance") } }
    var alwaysShowDockIcon: Bool { didSet { defaults.set(alwaysShowDockIcon, forKey: "alwaysShowDockIcon") } }
    @ObservationIgnored private let defaults: UserDefaults
    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        if let data = defaults.data(forKey: "dictationShortcut"),
            let saved = try? JSONDecoder().decode(DictationShortcut.self, from: data), saved.isValid
        {
            shortcut = saved
        } else {
            shortcut = .fn
        }
        microphoneID = defaults.string(forKey: "microphoneID") ?? ""
        uzbekAlphabet = UzbekAlphabet(rawValue: defaults.string(forKey: "uzbekAlphabet") ?? "") ?? .current
        autoPaste = defaults.object(forKey: "autoPaste") as? Bool ?? true
        textInsertionMethod =
            TextInsertionMethod(rawValue: defaults.string(forKey: "textInsertionMethod") ?? "") ?? .automatic
        // Default: hold to talk, double-tap for hands-free. Earlier builds defaulted to
        // toggle, where releasing never stopped; move those installs over once.
        if defaults.object(forKey: "activationModeV2") == nil {
            if defaults.string(forKey: "activationMode") == DictationActivationMode.toggle.rawValue {
                defaults.set(DictationActivationMode.automatic.rawValue, forKey: "activationMode")
            }
            defaults.set(true, forKey: "activationModeV2")
        }
        activationMode =
            DictationActivationMode(rawValue: defaults.string(forKey: "activationMode") ?? "") ?? .automatic
        retainHistory = defaults.object(forKey: "retainHistory") as? Bool ?? true
        appearance = defaults.string(forKey: "appearance") ?? "system"
        alwaysShowDockIcon = defaults.object(forKey: "alwaysShowDockIcon") as? Bool ?? true
        // Old language choices must never constrain automatic recognition.
        defaults.removeObject(forKey: "language")
        defaults.removeObject(forKey: "uzbekAlphabetSelectionVersion")
    }

    /// Startup cleanup happens after the UI model exists; publish the cleared values in place.
    func reloadFromStorage() {
        let stored = Preferences(defaults: defaults)
        shortcut = stored.shortcut
        microphoneID = stored.microphoneID
        uzbekAlphabet = stored.uzbekAlphabet
        autoPaste = stored.autoPaste
        textInsertionMethod = stored.textInsertionMethod
        activationMode = stored.activationMode
        retainHistory = stored.retainHistory
        appearance = stored.appearance
        alwaysShowDockIcon = stored.alwaysShowDockIcon
    }
}
