import AppKit
import ApplicationServices
import OSLog
import VoiceLabCore

@MainActor
struct TextInsertion {
    private static let log = Logger(subsystem: "uz.voicelab.desktop", category: "text-insertion")
    /// Weak references cannot keep a closed note editor alive. Field editors are
    /// shared by AppKit, so their original delegate must still match as well.
    @MainActor final class Target {
        let processID: pid_t
        var external: ExternalTextTarget?
        var usageContext: DesktopUsageContext?
        weak var editor: NSTextView?
        weak var window: NSWindow?
        weak var fieldOwner: AnyObject?

        init(processID: pid_t, editor: NSTextView? = nil) {
            self.processID = processID
            self.editor = editor
            window = editor?.window
            fieldOwner = editor?.delegate
        }
    }

    static func captureTarget() -> Target? {
        guard let processID = NSWorkspace.shared.frontmostApplication?.processIdentifier else {
            return nil
        }
        let local = processID == ProcessInfo.processInfo.processIdentifier
        let editor = local ? NSApp.keyWindow?.firstResponder as? NSTextView : nil
        let target = Target(processID: processID, editor: editor)
        if !local { target.external = NativeTextInsertionEnvironment.capture(processID: processID) }
        if let app = NSRunningApplication(processIdentifier: processID), let bundleID = app.bundleIdentifier {
            target.usageContext = DesktopUsageContext.classify(
                bundleID: bundleID, appName: app.localizedName ?? bundleID,
                host: browserHost(bundleID: bundleID, target: target.external))
        }
        return target
    }

    /// Only inspect document URL attributes for the active browser target. Do not read
    /// address-bar text, titles, tab history, or arbitrary document contents.
    private static func browserHost(bundleID: String, target: ExternalTextTarget?) -> String? {
        let browsers = ["com.apple.Safari", "com.google.Chrome", "com.google.Chrome.canary",
                        "com.brave.Browser", "company.thebrowser.Browser", "org.mozilla.firefox",
                        "com.microsoft.edgemac", "com.operasoftware.Opera"]
        guard browsers.contains(bundleID), let target else { return nil }
        func host(_ element: AXUIElement) -> String? {
            var value: CFTypeRef?
            guard AXUIElementCopyAttributeValue(element, "AXDocument" as CFString, &value) == .success else { return nil }
            let url = (value as? URL) ?? (value as? String).flatMap(URL.init(string:))
            guard let url, ["https", "http"].contains(url.scheme?.lowercased() ?? "") else { return nil }
            return url.host
        }
        if let window = target.window, let host = host(window) { return host }
        var current = target.element
        for _ in 0..<8 {
            guard let element = current else { break }
            if let host = host(element) { return host }
            var parent: CFTypeRef?
            guard AXUIElementCopyAttributeValue(element, kAXParentAttribute as CFString, &parent) == .success,
                  let parent, CFGetTypeID(parent) == AXUIElementGetTypeID() else { break }
            current = (parent as! AXUIElement)
        }
        return nil
    }

    static var hasAccessibility: Bool { AccessibilityAccess.current.isGranted }
    static func requestAccessibility() {
        AccessibilityAccess.request()
    }
    static func copy(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }
    /// Native editors use their input client; external apps use the existing AX/paste path.
    static func insert(
        _ text: String, into target: Target?, autoPaste: Bool, method: TextInsertionMethod = .automatic
    ) async -> String {
        guard !Task.isCancelled else { return "" }
        guard autoPaste, let target,
            NSWorkspace.shared.frontmostApplication?.processIdentifier == target.processID
        else {
            if autoPaste {
                log.notice("Insertion kept on clipboard: original app is no longer frontmost or no target was captured")
            }
            copy(text)
            return "Matn nusxalandi"
        }
        if target.processID == ProcessInfo.processInfo.processIdentifier {
            if insertLocally(text, target: target) { return "Matn joylandi" }
            copy(text)
            return "Matn nusxalandi"
        }
        guard NativeTextInsertionEnvironment.focusedElementAcceptsText(processID: target.processID) else {
            log.notice("Insertion kept on clipboard: focused element does not accept text; pid=\(target.processID)")
            copy(text)
            return "Matn nusxalandi"
        }
        let outcome = await TextInsertionManager.shared.insert(
            text, into: target.external ?? ExternalTextTarget(processID: target.processID), method: method)
        return outcome.message
    }

    private static func insertLocally(_ text: String, target: Target) -> Bool {
        guard let editor = target.editor, let window = target.window,
            NSApp.keyWindow === window, window.firstResponder === editor,
            editor.window === window, editor.isEditable, !editor.hasMarkedText(),
            (editor.delegate as AnyObject?) === target.fieldOwner,
            !(editor.delegate is NSSecureTextField)
        else { return false }
        return replaceSelection(text, in: editor)
    }

    /// The native editing operation, shared with the Notes regression harness.
    /// Target/focus validation stays in insertLocally, before reaching this method.
    static func replaceSelection(_ text: String, in editor: NSTextView) -> Bool {
        guard editor.isEditable, !editor.hasMarkedText() else { return false }
        let range = editor.selectedRange()
        let value = editor.string as NSString
        guard range.location != NSNotFound, range.location <= value.length,
            range.length <= value.length - range.location
        else { return false }
        let insertion = InsertionTextSnapshot(value: value as String, selection: range)
            .fitting(text, protectedWords: TextInsertionManager.protectedWords)
        let expected = value.replacingCharacters(in: range, with: insertion)
        editor.breakUndoCoalescing()
        // Goes through NSTextView's editing notifications and SwiftUI's binding;
        // never replace textStorage directly or bypass the user's selection.
        editor.insertText(insertion, replacementRange: range)
        editor.breakUndoCoalescing()
        return editor.string == expected
    }

}
