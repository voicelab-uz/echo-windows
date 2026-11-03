import AppKit
import SwiftUI

/// Deliver local preview events and production shortcut events only to the focused onboarding window.
struct OnboardingFnInput: NSViewRepresentable {
    /// When another key is the dictation shortcut, a physical fn press must not count.
    var acceptsLocalFn = true
    let onPress: (UInt16, Bool, Bool) -> Void

    func makeNSView(context: Context) -> InputView {
        let view = InputView()
        view.onPress = onPress
        view.acceptsLocalFn = acceptsLocalFn
        return view
    }
    func updateNSView(_ view: InputView, context: Context) {
        view.onPress = onPress
        view.acceptsLocalFn = acceptsLocalFn
    }
    static func dismantleNSView(_ view: InputView, coordinator: ()) { view.stop() }

    final class InputView: NSView {
        var onPress: ((UInt16, Bool, Bool) -> Void)?
        var acceptsLocalFn = true
        private static let deviceFlags: [UInt16: UInt64] = [
            55: 0x0008, 54: 0x0010, 58: 0x0020, 61: 0x0040, 59: 0x0001, 62: 0x2000, 56: 0x0002, 60: 0x0004,
        ]
        private var monitor: Any?
        private var resignObserver: NSObjectProtocol?
        private var systemObserver: NSObjectProtocol?

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            stop()
            guard let window else { return }
            monitor = NSEvent.addLocalMonitorForEvents(matching: .flagsChanged) { [weak self] event in
                let keyCode = event.keyCode
                // Fn reports through its own flag; other modifiers through a device bit
                // that tells the left and right keys apart.
                let pressed = keyCode == 63 ? event.modifierFlags.contains(.function)
                    : Self.deviceFlags[keyCode].map { UInt64(event.modifierFlags.rawValue) & $0 != 0 } ?? false
                // AppKit delivers local event monitors on the main thread.
                MainActor.assumeIsolated {
                    guard let self, keyCode != 63 || self.acceptsLocalFn else { return }
                    self.onPress?(keyCode, pressed, self.window?.isKeyWindow == true)
                }
                return event
            }
            systemObserver = NotificationCenter.default.addObserver(
                forName: Notification.Name("Echo.onboardingFn"), object: nil, queue: .main
            ) { [weak self] notification in
                let pressed = notification.userInfo?["pressed"] as? Bool ?? false
                MainActor.assumeIsolated {
                    self?.onPress?(63, pressed, self?.window?.isKeyWindow == true)
                }
            }
            resignObserver = NotificationCenter.default.addObserver(
                forName: NSWindow.didResignKeyNotification, object: window, queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated { self?.onPress?(63, false, false) }
            }
        }

        func stop() {
            if let monitor { NSEvent.removeMonitor(monitor) }
            if let resignObserver { NotificationCenter.default.removeObserver(resignObserver) }
            if let systemObserver { NotificationCenter.default.removeObserver(systemObserver) }
            systemObserver = nil
            monitor = nil
            resignObserver = nil
        }
    }
}
