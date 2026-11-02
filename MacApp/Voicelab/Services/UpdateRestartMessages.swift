import Foundation
import VoiceLabCore

extension UpdateRestartBlocker {
    @MainActor var message: String {
        let key = switch self {
        case .startup: "Echo is still starting. Try again in a moment."
        case .onboarding: "Finish your current setup task before restarting Echo."
        case .dictation: "Finish your recording before restarting Echo."
        case .retryableRecording: "Retry or discard your unfinished recording before restarting Echo."
        case .authentication: "Finish signing in or out before restarting Echo."
        case .shortcutEditing: "Finish changing your shortcut before restarting Echo."
        case .textInsertion: "Echo is inserting your text. Try again in a moment."
        case .unsavedChanges: "Save or cancel your edits before restarting Echo."
        case .saving: "Echo is saving your work. Try again in a moment."
        case .installation: "Echo is preparing to restart."
        }
        return AppLocalization.text(key)
    }
}
