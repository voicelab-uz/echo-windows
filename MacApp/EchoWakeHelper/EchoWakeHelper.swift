import AppKit
import OSLog

@main
struct EchoWakeHelper {
    @MainActor static func main() {
        let application = NSApplication.shared
        let delegate = WakeHelperDelegate()
        application.delegate = delegate
        application.setActivationPolicy(.prohibited)
        withExtendedLifetime(delegate) { application.run() }
    }
}

@MainActor
private final class WakeHelperDelegate: NSObject, NSApplicationDelegate {
    private var monitor: SessionReturnMonitor?
    private var opening = false
    private var delayedLaunch: Task<Void, Never>?
    private let logger = Logger(subsystem: "uz.voicelab.desktop.WakeHelper", category: "launch")

    func applicationDidFinishLaunching(_ notification: Notification) {
        let monitor = SessionReturnMonitor(onReturn: { [weak self] in self?.openEchoIfNeeded() })
        self.monitor = monitor
        monitor.start(announceInitial: true)
    }

    func applicationWillTerminate(_ notification: Notification) {
        delayedLaunch?.cancel()
        monitor?.stop()
    }

    private func openEchoIfNeeded() {
        guard !opening, SessionReturnMonitor.desktopAvailable,
              NSRunningApplication.runningApplications(withBundleIdentifier: "uz.voicelab.desktop").isEmpty else { return }
        // Resolve the enclosing app, never another installed copy or a URL supplied by IPC.
        let appURL = Bundle.main.bundleURL.deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        if UpdateInstallationLease.isActive(for: appURL) {
            // Do not launch the old app between Sparkle's quit and replacement. Retry
            // after the bounded lease so an interrupted installer cannot disable wake.
            if delayedLaunch == nil {
                delayedLaunch = Task { [weak self] in
                    do { try await Task.sleep(for: .seconds(2)) } catch { return }
                    guard let self else { return }
                    self.delayedLaunch = nil
                    self.openEchoIfNeeded()
                }
            }
            return
        }
        guard Bundle(url: appURL)?.bundleIdentifier == "uz.voicelab.desktop" else { return }
        opening = true
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = false
        configuration.addsToRecentItems = false
        configuration.arguments = ["--echo-background-return"]
        NSWorkspace.shared.openApplication(at: appURL, configuration: configuration) { [weak self] _, error in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.opening = false
                if let error { self.logger.error("Echo background launch failed: \(error.localizedDescription, privacy: .public)") }
            }
        }
    }
}
