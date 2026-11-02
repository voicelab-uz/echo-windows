import AppKit
import ApplicationServices
import Carbon

@MainActor
final class ExternalTextTarget {
    let processID: pid_t
    private(set) var element: AXUIElement?
    let identity: InsertionFieldIdentity?
    let window: AXUIElement?
    let isTerminalSurface: Bool

    init(
        processID: pid_t, element: AXUIElement? = nil, window: AXUIElement? = nil,
        identity: InsertionFieldIdentity? = nil, isTerminalSurface: Bool = false
    ) {
        self.processID = processID
        self.element = element
        self.window = window
        self.identity = identity
        self.isTerminalSurface = isTerminalSurface
    }
    func rebind(_ element: AXUIElement, identity: InsertionFieldIdentity?) -> Bool {
        guard window != nil, let original = self.identity, let identity,
            original.matchesReplacement(identity)
        else { return false }
        self.element = element
        return true
    }

}

/// Terminal AX text is screen output, not the shell/TUI's editable input buffer.
/// Keep ordinary search/rename text fields in these apps on the editor path.
enum InsertionSurface {
    static func isTerminal(bundleID: String?, role: String?) -> Bool {
        let terminals: Set<String> = [
            "com.apple.Terminal", "com.googlecode.iterm2", "com.mitchellh.ghostty",
        ]
        return bundleID.map(terminals.contains) == true && role == kAXTextAreaRole
    }
}

struct InsertionFieldIdentity: Equatable {
    let identifier: String
    let role: String

    func matchesReplacement(_ candidate: Self) -> Bool {
        // Geometry or matching text alone cannot distinguish two fields.
        !identifier.isEmpty && self == candidate
    }
}

struct InsertionClipboardLease {
    let changeCount: Int
    // Nil means at least one promised type could not be materialized safely.
    let previousItems: [[NSPasteboard.PasteboardType: Data]]?
}

@MainActor
final class NativeTextInsertionEnvironment: TextInsertionEnvironment {
    private let source = CGEventSource(stateID: .privateState)

    static func capture(processID: pid_t) -> ExternalTextTarget {
        let app = application(processID)
        let focused = element(app, attribute: kAXFocusedUIElementAttribute)
        // Web areas and generic containers aren't stable editable-element IDs.
        // Their AX tree may be lazy while the actual browser caret is valid.
        let role = focused.flatMap { attribute($0, kAXRoleAttribute) as? String }
        let editable = role == kAXTextFieldRole || role == kAXTextAreaRole
        return ExternalTextTarget(
            processID: processID, element: editable ? focused : nil,
            window: element(app, attribute: kAXFocusedWindowAttribute),
            identity: editable ? focused.flatMap(fieldIdentity) : nil,
            isTerminalSurface: InsertionSurface.isTerminal(
                bundleID: NSRunningApplication(processIdentifier: processID)?.bundleIdentifier, role: role))
    }

    /// False only when the focused element clearly cannot take typed text (a file list,
    /// a button, an empty desktop). Sparse Electron/web fields stay eligible, because
    /// their caret is often valid even when Accessibility reports little.
    static func focusedElementAcceptsText(processID: pid_t) -> Bool {
        let app = application(processID)
        guard let focused = element(app, attribute: kAXFocusedUIElementAttribute) else {
            // Finder with nothing focused is the desktop or a file list, never a text box.
            return NSRunningApplication(processIdentifier: processID)?.bundleIdentifier != "com.apple.finder"
        }
        let role = attribute(focused, kAXRoleAttribute) as? String
        let textRoles: Set<String> = [kAXTextFieldRole, kAXTextAreaRole, kAXComboBoxRole, "AXSearchField"]
        if let role, textRoles.contains(role) { return true }
        if attribute(focused, "AXEditable") as? Bool == true { return true }
        if attribute(focused, kAXSelectedTextRangeAttribute) != nil { return true }
        if attribute(focused, "AXSelectedTextMarkerRange") != nil { return true }
        var settable = DarwinBoolean(false)
        if AXUIElementIsAttributeSettable(focused, kAXValueAttribute as CFString, &settable) == .success,
            settable.boolValue, role != kAXCheckBoxRole, role != kAXSliderRole
        {
            return true
        }
        return false
    }

    func focus(for target: ExternalTextTarget, readText: Bool) -> InsertionFocus {
        guard AccessibilityAccess.current.isGranted, !IsSecureEventInputEnabled() else { return .blocked }
        guard NSWorkspace.shared.frontmostApplication?.processIdentifier == target.processID else {
            return .changed
        }
        // Session state includes our own synthesized Cmd+V. Only physical key
        // state should delay the NEXT dictation after a rapid paste/delete cycle.
        let held = CGEventSource.flagsState(.hidSystemState)
        if !held.intersection([.maskCommand, .maskControl, .maskAlternate, .maskShift]).isEmpty {
            return .temporarilyUnavailable
        }
        let app = Self.application(target.processID)
        if let original = target.window {
            guard let window = Self.element(app, attribute: kAXFocusedWindowAttribute) else {
                return .temporarilyUnavailable
            }
            guard CFEqual(original, window) else { return .changed }
        }
        guard let focused = Self.element(app, attribute: kAXFocusedUIElementAttribute) else {
            // Accessibility can be sparse in Electron/contenteditable fields.
            // It must not be required when there was no readable field at capture.
            return target.element == nil ? .ready(nil) : .temporarilyUnavailable
        }
        if Self.attribute(focused, kAXSubroleAttribute) as? String == kAXSecureTextFieldSubrole {
            return .blocked
        }
        if let original = target.element, !CFEqual(original, focused) {
            // Some editors replace their accessibility object when their text is
            // cleared. Rebind only using a stable field ID in the SAME window.
            guard target.rebind(focused, identity: Self.fieldIdentity(focused)) else { return .changed }
        }
        // Do not read the entire document again for every typed character.
        return .ready(readText && !target.isTerminalSurface ? Self.snapshot(focused) : nil)
    }

    func copy(_ text: String) -> InsertionClipboardLease? {
        let board = NSPasteboard.general
        var complete = true
        let previous: [[NSPasteboard.PasteboardType: Data]] =
            board.pasteboardItems?.map { item in
                var values: [NSPasteboard.PasteboardType: Data] = [:]
                for type in item.types {
                    if let data = item.data(forType: type) { values[type] = data } else { complete = false }
                }
                return values
            } ?? []
        board.clearContents()
        guard board.setString(text, forType: .string) else { return nil }
        return InsertionClipboardLease(
            changeCount: board.changeCount, previousItems: complete ? previous : nil)
    }

    func owns(_ lease: InsertionClipboardLease) -> Bool {
        NSPasteboard.general.changeCount == lease.changeCount
    }

    func restore(_ lease: InsertionClipboardLease) {
        guard owns(lease), let previous = lease.previousItems else { return }
        let items = previous.map { values in
            let item = NSPasteboardItem()
            for (type, data) in values { item.setData(data, forType: type) }
            return item
        }
        let board = NSPasteboard.general
        board.clearContents()
        if !items.isEmpty { board.writeObjects(items) }
    }

    func postPaste() -> Bool {
        guard let source,
            let down = CGEvent(keyboardEventSource: source, virtualKey: 0x09, keyDown: true),
            let up = CGEvent(keyboardEventSource: source, virtualKey: 0x09, keyDown: false)
        else { return false }
        down.flags = .maskCommand
        up.flags = []
        down.post(tap: .cghidEventTap)
        up.post(tap: .cghidEventTap)
        return true
    }

    func postUnicode(_ units: [UInt16]) -> Bool {
        guard !units.isEmpty, units.count <= 20, let source,
            let down = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: true),
            let up = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: false)
        else { return false }
        down.flags = []
        up.flags = []
        units.withUnsafeBufferPointer { buffer in
            down.keyboardSetUnicodeString(stringLength: buffer.count, unicodeString: buffer.baseAddress)
            up.keyboardSetUnicodeString(stringLength: buffer.count, unicodeString: buffer.baseAddress)
        }
        down.post(tap: .cghidEventTap)
        up.post(tap: .cghidEventTap)
        return true
    }

    func pause(milliseconds: Int) async throws {
        try Task.checkCancellation()
        // DispatchQueue yields the main run loop; no blocking sleep or semaphore.
        await withCheckedContinuation { continuation in
            DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(milliseconds)) {
                continuation.resume()
            }
        }
        try Task.checkCancellation()
    }

    private static func application(_ processID: pid_t) -> AXUIElement {
        let app = AXUIElementCreateApplication(processID)
        AXUIElementSetMessagingTimeout(app, 0.08)
        return app
    }

    private static func attribute(_ element: AXUIElement, _ name: String) -> CFTypeRef? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success else { return nil }
        return value
    }

    private static func element(_ parent: AXUIElement, attribute name: String) -> AXUIElement? {
        guard let value = attribute(parent, name), CFGetTypeID(value) == AXUIElementGetTypeID() else {
            return nil
        }
        let element = unsafeDowncast(value, to: AXUIElement.self)
        AXUIElementSetMessagingTimeout(element, 0.08)
        return element
    }

    private static func fieldIdentity(_ element: AXUIElement) -> InsertionFieldIdentity? {
        guard let identifier = attribute(element, kAXIdentifierAttribute) as? String, !identifier.isEmpty,
            let role = attribute(element, kAXRoleAttribute) as? String,
            role == kAXTextFieldRole || role == kAXTextAreaRole
        else { return nil }
        return InsertionFieldIdentity(identifier: identifier, role: role)
    }

    private static func snapshot(_ element: AXUIElement) -> InsertionTextSnapshot? {
        guard let value = attribute(element, kAXValueAttribute) as? String,
            let raw = attribute(element, kAXSelectedTextRangeAttribute),
            CFGetTypeID(raw) == AXValueGetTypeID()
        else { return nil }
        var range = CFRange()
        guard AXValueGetValue(unsafeDowncast(raw, to: AXValue.self), .cfRange, &range),
            range.location >= 0, range.length >= 0,
            range.location <= (value as NSString).length,
            range.length <= (value as NSString).length - range.location
        else { return nil }
        return InsertionTextSnapshot(
            value: value, selection: NSRange(location: range.location, length: range.length))
    }
}
