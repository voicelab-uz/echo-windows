import Foundation

/// Work that must finish before an unattended update may restart the app.
public enum UpdateRestartBlocker: String, Sendable, Equatable, CaseIterable {
    case startup, onboarding, dictation, retryableRecording, authentication
    case shortcutEditing, textInsertion, unsavedChanges, saving, installation
}

public enum UpdateRestartError: Error, Sendable, Equatable {
    case blocked([UpdateRestartBlocker])
}
