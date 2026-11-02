import AppKit
import Observation
import SwiftUI

/// Owns window presentation independently of authentication and onboarding state.
@MainActor
final class MainWindowPresenter {
    var openWindow: (() -> Void)? {
        didSet { if isAwaitingWindow { openWindow?() } }
    }
    private weak var window: NSWindow?
    private var isAwaitingWindow = false
    private var isBackgroundLaunch = false
    private var windowIsOpen = false
    private var preferences: Preferences?
    private let setActivationPolicy: (NSApplication.ActivationPolicy) -> Void
    // Registered and removed on the main actor; deinit only releases the token.
    nonisolated(unsafe) private var closeObserver: (any NSObjectProtocol)?

    init(setActivationPolicy: @escaping (NSApplication.ActivationPolicy) -> Void = { policy in
        if NSApp.activationPolicy() != policy { NSApp.setActivationPolicy(policy) }
    }) {
        self.setActivationPolicy = setActivationPolicy
    }

    deinit {
        if let closeObserver { NotificationCenter.default.removeObserver(closeObserver) }
    }

    func configureDockVisibility(preferences: Preferences) {
        self.preferences = preferences
        observeDockPreference()
    }

    private func observeDockPreference() {
        guard let preferences else { return }
        withObservationTracking {
            updateDockVisibility(alwaysShow: preferences.alwaysShowDockIcon)
        } onChange: { [weak self] in
            Task { @MainActor in self?.observeDockPreference() }
        }
    }

    private func updateDockVisibility(alwaysShow: Bool? = nil) {
        guard let preferences else { return }
        setActivationPolicy((alwaysShow ?? preferences.alwaysShowDockIcon) || windowIsOpen ? .regular : .accessory)
    }

    func attach(_ window: NSWindow) {
        if self.window !== window {
            if let closeObserver { NotificationCenter.default.removeObserver(closeObserver) }
            closeObserver = NotificationCenter.default.addObserver(
                forName: NSWindow.willCloseNotification, object: window, queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated {
                    self?.windowIsOpen = false
                    // Change policy after AppKit finishes closing the window.
                    Task { @MainActor [weak self] in self?.updateDockVisibility() }
                }
            }
        }
        self.window = window
        window.titleVisibility = .hidden
        window.isRestorable = false
        if isAwaitingWindow {
            restoreWindow()
        } else if isBackgroundLaunch {
            hideAutomaticWindow()
        }
    }

    func prepareForBackgroundLaunch() {
        isBackgroundLaunch = true
        isAwaitingWindow = false
        windowIsOpen = false
        updateDockVisibility()
        hideAutomaticWindow()
    }

    private func hideAutomaticWindow() {
        window?.orderOut(nil)
        // Also cover a window restored by an older build's saved state, unless
        // an explicit open request arrived during its initial ordering pass.
        Task { @MainActor [weak self] in
            await Task.yield()
            guard let self, self.isBackgroundLaunch, !self.isAwaitingWindow else { return }
            self.window?.orderOut(nil)
        }
    }

    func show() {
        isBackgroundLaunch = false
        isAwaitingWindow = true
        windowIsOpen = true
        updateDockVisibility()
        openWindow?()
        restoreWindow()
    }

    func returnFromBrowser() {
        show()
        // Reopen this exact app bundle through Launch Services. A bare activate()
        // request can leave the browser in front on macOS 14 and later.
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = true
        configuration.createsNewApplicationInstance = false
        configuration.allowsRunningApplicationSubstitution = false
        NSWorkspace.shared.openApplication(
            at: Bundle.main.bundleURL, configuration: configuration
        ) { @Sendable [weak self] _, error in
            Task { @MainActor in
                self?.show()
                if error != nil { NSApp.requestUserAttention(.informationalRequest) }
            }
        }
    }

    private func restoreWindow() {
        guard let window else { return }
        NSApp.unhide(nil)
        if window.isMiniaturized { window.deminiaturize(nil) }
        window.makeKeyAndOrderFront(nil)
        NSApp.activate()
        isAwaitingWindow = false
    }
}

/// Identifies the main SwiftUI window without relying on titles or NSApp.windows order.
struct MainWindowAttachment: NSViewRepresentable {
    let presenter: MainWindowPresenter

    func makeNSView(context: Context) -> WindowAttachmentView {
        WindowAttachmentView(presenter: presenter)
    }

    func updateNSView(_ nsView: WindowAttachmentView, context: Context) {}

    final class WindowAttachmentView: NSView {
        private let presenter: MainWindowPresenter

        init(presenter: MainWindowPresenter) {
            self.presenter = presenter
            super.init(frame: .zero)
        }

        required init?(coder: NSCoder) { nil }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if let window { presenter.attach(window) }
        }
    }
}
