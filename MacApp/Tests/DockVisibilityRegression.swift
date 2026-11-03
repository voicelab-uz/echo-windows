import AppKit
import Foundation

@main
struct DockVisibilityRegression {
    @MainActor
    static func main() async throws {
        let app = NSApplication.shared
        app.setActivationPolicy(.regular)
        app.finishLaunching()
        let suite = "VoiceLab.DockRegression.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let preferences = Preferences(defaults: defaults)
        var policy: NSApplication.ActivationPolicy = .prohibited
        let presenter = MainWindowPresenter { policy = $0 }
        presenter.configureDockVisibility(preferences: preferences)
        precondition(policy == .regular, "Default retains Dock icon without a window")

        preferences.alwaysShowDockIcon = false
        try await settle()
        precondition(policy == .accessory, "Changing the preference updates a windowless app")
        presenter.show()
        precondition(policy == .regular, "Promote before SwiftUI creates the window")
        presenter.prepareForBackgroundLaunch()
        precondition(policy == .accessory, "Login launch remains menu-bar-only")

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 120, height: 80),
            styleMask: [.titled, .closable, .miniaturizable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        presenter.attach(window)
        try await settle()
        precondition(!window.isVisible && policy == .accessory)
        presenter.show()
        precondition(window.isVisible && policy == .regular)

        // Closing a recording overlay or another window must not hide the main app.
        NotificationCenter.default.post(name: NSWindow.willCloseNotification, object: NSPanel())
        try await settle()
        precondition(policy == .regular)
        window.miniaturize(nil)
        try await Task.sleep(for: .milliseconds(500))
        precondition(window.isMiniaturized && policy == .regular)
        presenter.show()
        precondition(!window.isMiniaturized && window.isVisible && policy == .regular)
        window.close()
        try await settle()
        precondition(policy == .accessory, "Closing the main window hides the Dock icon")

        // A reopen arriving before the deferred close callback must win.
        presenter.show()
        window.close()
        presenter.show()
        try await settle()
        precondition(window.isVisible && policy == .regular)

        preferences.alwaysShowDockIcon = true
        try await settle()
        window.close()
        try await settle()
        precondition(policy == .regular, "Always-show keeps the Dock icon after close")
        preferences.alwaysShowDockIcon = false
        try await settle()
        precondition(policy == .accessory, "Preference observation remains active after multiple changes")

        print("PASS: Dock policy follows preferences, login launch, main-window close/reopen, and minimization; panels are ignored.")
    }

    private static func settle() async throws {
        try await Task.sleep(for: .milliseconds(50))
    }
}
