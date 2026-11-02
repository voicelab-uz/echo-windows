import AppKit
import CoreServices

/// Read during the launch Apple event, before it leaves NSAppleEventManager.
@MainActor
enum ApplicationLaunch {
    static var isLoginItem: Bool {
        if ProcessInfo.processInfo.arguments.contains("--echo-background-return") { return true }
        guard let event = NSAppleEventManager.shared().currentAppleEvent,
            event.eventID == kAEOpenApplication
        else { return false }
        return event.paramDescriptor(forKeyword: keyAEPropData)?.enumCodeValue == keyAELaunchedAsLogInItem
    }
}
