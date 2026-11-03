import AppKit

/// Persist physical key codes so a shortcut still works after switching keyboard layouts.
/// A binding is either a lone modifier key (fn, Right ⌥, Left ⌘…), an F-key, or a key combination.
struct DictationShortcut: Codable, Equatable, Sendable {
    let keyCode: UInt16
    let modifiers: UInt64
    let keyLabel: String

    static let fn = Self(keyCode: 63, modifiers: 0, keyLabel: "fn")
    static let modifierMask: NSEvent.ModifierFlags = [.control, .option, .shift, .command]

    /// A physical modifier key. `deviceFlag` is the device-specific bit that reports this exact key,
    /// which is how the left and right variants are told apart.
    struct ModifierKey: Equatable, Sendable {
        let keyCode: UInt16
        let deviceFlag: UInt64
        let flag: NSEvent.ModifierFlags
        let symbol: String
        let isRight: Bool
    }
    static let modifierKeys: [ModifierKey] = [
        .init(keyCode: 63, deviceFlag: UInt64(NSEvent.ModifierFlags.function.rawValue), flag: .function, symbol: "fn", isRight: false),
        .init(keyCode: 55, deviceFlag: 0x0008, flag: .command, symbol: "⌘", isRight: false),
        .init(keyCode: 54, deviceFlag: 0x0010, flag: .command, symbol: "⌘", isRight: true),
        .init(keyCode: 58, deviceFlag: 0x0020, flag: .option, symbol: "⌥", isRight: false),
        .init(keyCode: 61, deviceFlag: 0x0040, flag: .option, symbol: "⌥", isRight: true),
        .init(keyCode: 59, deviceFlag: 0x0001, flag: .control, symbol: "⌃", isRight: false),
        .init(keyCode: 62, deviceFlag: 0x2000, flag: .control, symbol: "⌃", isRight: true),
        .init(keyCode: 56, deviceFlag: 0x0002, flag: .shift, symbol: "⇧", isRight: false),
        .init(keyCode: 60, deviceFlag: 0x0004, flag: .shift, symbol: "⇧", isRight: true),
    ]
    /// F1–F19. These never type text, so they are allowed without a modifier.
    static let functionKeyCodes: Set<UInt16> = [
        122, 120, 99, 118, 96, 97, 98, 100, 101, 109, 103, 111, 105, 107, 113, 106, 64, 79, 80,
    ]
    static func modifierKey(for keyCode: UInt16) -> ModifierKey? {
        modifierKeys.first { $0.keyCode == keyCode }
    }

    var isFn: Bool { self == .fn }
    /// Non-nil when this binding is a modifier key pressed on its own.
    var modifierKey: ModifierKey? { modifiers == 0 ? Self.modifierKey(for: keyCode) : nil }
    var isValid: Bool {
        if Self.modifierKey(for: keyCode) != nil { return modifiers == 0 && !keyLabel.isEmpty }
        guard keyCode < 128, !keyLabel.isEmpty, modifiers & ~UInt64(Self.modifierMask.rawValue) == 0 else {
            return false
        }
        if Self.functionKeyCodes.contains(keyCode) { return true }
        return !NSEvent.ModifierFlags(rawValue: UInt(modifiers)).intersection([.control, .option, .command]).isEmpty
    }
    @MainActor var displayName: String {
        guard !isFn else { return "fn" }
        if let modifierKey {
            return AppLocalization.text(modifierKey.isRight ? "O‘ng %@" : "Chap %@", modifierKey.symbol)
        }
        let flags = NSEvent.ModifierFlags(rawValue: UInt(modifiers))
        return (flags.contains(.control) ? "⌃" : "")
            + (flags.contains(.option) ? "⌥" : "")
            + (flags.contains(.shift) ? "⇧" : "")
            + (flags.contains(.command) ? "⌘" : "") + keyLabel
    }

    /// A key-down event: a combination, or an F-key on its own.
    static func capture(_ event: NSEvent) -> Self? {
        let flags = event.modifierFlags.intersection(modifierMask)
        // Leave standard window, app and system navigation combinations available.
        let reserved =
            flags == .command && [0, 4, 6, 7, 8, 9, 12, 13, 46, 48, 49].contains(Int(event.keyCode))
            || flags == [.command, .option] && [48, 49, 53].contains(Int(event.keyCode))
            || flags == .control && [48, 49, 123, 124, 125, 126].contains(Int(event.keyCode))
        guard !reserved, event.keyCode != 53 else { return nil }
        let labels: [UInt16: String] = [
            36: "↩", 48: "⇥", 49: "Space", 51: "⌫", 117: "⌦",
            123: "←", 124: "→", 125: "↓", 126: "↑",
            122: "F1", 120: "F2", 99: "F3", 118: "F4", 96: "F5", 97: "F6",
            98: "F7", 100: "F8", 101: "F9", 109: "F10", 103: "F11", 111: "F12",
            105: "F13", 107: "F14", 113: "F15", 106: "F16", 64: "F17", 79: "F18", 80: "F19",
        ]
        let label = labels[event.keyCode] ?? event.charactersIgnoringModifiers?.uppercased() ?? ""
        let shortcut = Self(keyCode: event.keyCode, modifiers: UInt64(flags.rawValue), keyLabel: label)
        return shortcut.isValid ? shortcut : nil
    }

    /// A flags-changed event: a single modifier key going down while no other modifier is held.
    static func captureModifier(_ event: NSEvent) -> Self? {
        guard event.type == .flagsChanged, let key = modifierKey(for: event.keyCode) else { return nil }
        let flags = event.modifierFlags
        guard UInt64(flags.rawValue) & key.deviceFlag != 0 else { return nil }
        let others = flags.intersection(modifierMask.union(.function)).subtracting(key.flag)
        guard others.isEmpty else { return nil }
        return key.keyCode == 63 ? .fn : Self(keyCode: key.keyCode, modifiers: 0, keyLabel: key.symbol)
    }
}
