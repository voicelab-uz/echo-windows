import SwiftUI

private struct DictationShortcutKey: EnvironmentKey {
    static let defaultValue = DictationShortcut.fn
}
extension EnvironmentValues {
    var dictationShortcut: DictationShortcut {
        get { self[DictationShortcutKey.self] }
        set { self[DictationShortcutKey.self] = newValue }
    }
}
