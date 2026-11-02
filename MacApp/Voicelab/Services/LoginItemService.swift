import AppKit
import Observation
import ServiceManagement

/// Owns the system login-item state. A user's later opt-out is never overwritten.
@MainActor @Observable
final class LoginItemService {
    // ServiceManagement may validate signatures. Defer that work until launch,
    // rather than running it while SwiftUI is constructing the application.
    private(set) var status: SMAppService.Status = .notRegistered
    private(set) var error: String?
    @ObservationIgnored private let defaults: UserDefaults
    static let helperIdentifier = "uz.voicelab.desktop.WakeHelper"
    private var service: SMAppService { .loginItem(identifier: Self.helperIdentifier) }
    private static let configuredKey = "VoiceLab.launchAtLogin.configured"

    init(defaults: UserDefaults = .standard) { self.defaults = defaults }

    var isEnabled: Bool { status == .enabled }
    var needsApproval: Bool { status == .requiresApproval }
    var isInstalled: Bool {
        let app = Bundle.main.bundleURL.resolvingSymlinksInPath().standardizedFileURL.path
        let directories =
            FileManager.default.urls(for: .applicationDirectory, in: .localDomainMask)
            + FileManager.default.urls(for: .applicationDirectory, in: .userDomainMask)
        return directories.contains { directory in
            app.hasPrefix(directory.resolvingSymlinksInPath().standardizedFileURL.path + "/")
        }
    }

    func refresh() { status = service.status }

    func configureDefaultIfNeeded() {
        refresh()
        // Xcode and temporary validation builds must not become persistent login items.
        guard isInstalled else { return }
        // Migrate existing opt-in users to the unlock helper. Preserve opt-outs.
        let legacy = SMAppService.mainApp.status
        if status == .enabled {
            if legacy == .enabled { try? SMAppService.mainApp.unregister() }
            defaults.set(true, forKey: Self.configuredKey)
            return
        }
        if legacy == .enabled || legacy == .requiresApproval {
            setEnabled(true)
            return
        }
        guard !defaults.bool(forKey: Self.configuredKey) else { return }
        switch status {
        case .enabled, .requiresApproval:
            defaults.set(true, forKey: Self.configuredKey)
        case .notRegistered, .notFound:
            setEnabled(true)
        @unknown default:
            break
        }
    }

    func setEnabled(_ enabled: Bool) {
        error = nil
        refresh()
        guard !enabled || isInstalled else {
            error = "Avtomatik ishga tushish uchun Echo’ni Applications papkasiga o‘rnating."
            return
        }
        do {
            if enabled {
                if status != .enabled && status != .requiresApproval {
                    try service.register()
                }
                if service.status == .enabled, SMAppService.mainApp.status != .notRegistered {
                    try SMAppService.mainApp.unregister()
                }
            } else {
                if status != .notRegistered { try service.unregister() }
                if SMAppService.mainApp.status != .notRegistered { try SMAppService.mainApp.unregister() }
                NSRunningApplication.runningApplications(withBundleIdentifier: Self.helperIdentifier)
                    .forEach { $0.terminate() }
            }
            defaults.set(true, forKey: Self.configuredKey)
        } catch {
            self.error = AppLocalization.error(error)
        }
        refresh()
    }

    func openSystemSettings() { SMAppService.openSystemSettingsLoginItems() }
}
