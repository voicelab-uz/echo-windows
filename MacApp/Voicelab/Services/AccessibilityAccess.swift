import AppKit
import ApplicationServices

/// One permission check for onboarding, shortcuts and text insertion. A stale
/// trust result must not disagree with access that macOS actually permits.
@MainActor
struct AccessibilityAccess {
    static let current = AccessibilityAccess()

    private let trusted: () -> Bool
    private let probe: () -> Bool

    init(trusted: @escaping () -> Bool = { AXIsProcessTrusted() },
         probe: @escaping () -> Bool = { probeApplication() }) {
        self.trusted = trusted
        self.probe = probe
    }

    var isGranted: Bool { trusted() || probe() }

    static func request() {
        // The answer arrives asynchronously; the return value is not a grant.
        _ = AXIsProcessTrustedWithOptions(["AXTrustedCheckOptionPrompt": true] as CFDictionary)
    }

    private static func probeApplication() -> Bool {
        // Query a real external AX endpoint, never our own UI (which is readable
        // without permission). Only window references are read, no user content.
        // Finder is reliable even when the frontmost app has no AX implementation.
        let candidates = [NSWorkspace.shared.frontmostApplication,
                          NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.finder").first]
        var checked = Set<pid_t>()
        for case let application? in candidates {
            let pid = application.processIdentifier
            guard pid != ProcessInfo.processInfo.processIdentifier,
                  !application.isTerminated, checked.insert(pid).inserted else { continue }
            let element = AXUIElementCreateApplication(pid)
            AXUIElementSetMessagingTimeout(element, 0.15)
            var windows: CFTypeRef?
            let result = AXUIElementCopyAttributeValue(element, kAXWindowsAttribute as CFString, &windows)
            if result == .success, let windows, CFGetTypeID(windows) == CFArrayGetTypeID() {
                return true
            }
            // Unsupported/unresponsive apps are inconclusive, not a grant.
            if result == .apiDisabled { return false }
        }
        return false
    }
}
