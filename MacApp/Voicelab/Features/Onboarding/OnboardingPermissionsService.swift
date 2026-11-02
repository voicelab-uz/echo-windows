import AVFoundation
import AppKit
import ApplicationServices
import Observation

/// The OS is the authority. No permission is inferred from an Allow click or saved progress.
@MainActor @Observable
final class OnboardingPermissionsService {
    private(set) var microphone: AVAuthorizationStatus
    private(set) var accessibility: Bool
    private(set) var requesting = false
    private(set) var settingsFailed = false
    private(set) var accessibilityRecheckFailed = false
    private(set) var accessibilityRequested = false
    @ObservationIgnored var canStartWork: () -> Bool = { true }

    @ObservationIgnored private let microphoneStatus: () -> AVAuthorizationStatus
    @ObservationIgnored private let accessibilityStatus: () -> Bool
    @ObservationIgnored private let requestAudio: () async -> Void
    @ObservationIgnored private let requestControl: () -> Void
    @ObservationIgnored private let openURL: (URL) -> Bool

    init(microphoneStatus: @escaping () -> AVAuthorizationStatus = { AVCaptureDevice.authorizationStatus(for: .audio) },
         accessibilityStatus: @escaping () -> Bool = { AccessibilityAccess.current.isGranted },
         requestAudio: @escaping () async -> Void = { _ = await AVCaptureDevice.requestAccess(for: .audio) },
         // kAXTrustedCheckOptionPrompt is imported as mutable global state in Swift 6.
         requestControl: @escaping () -> Void = { AccessibilityAccess.request() },
         openURL: @escaping (URL) -> Bool = { NSWorkspace.shared.open($0) }) {
        self.microphoneStatus = microphoneStatus; self.accessibilityStatus = accessibilityStatus
        self.requestAudio = requestAudio; self.requestControl = requestControl; self.openURL = openURL
        microphone = microphoneStatus(); accessibility = accessibilityStatus()
    }

    var allowed: Set<PermissionKind> {
        var value: Set<PermissionKind> = []
        if microphone == .authorized { value.insert(.microphone) }
        if accessibility { value.insert(.accessibility) }
        return value
    }
    var ready: Bool { microphone == .authorized && accessibility }

    func refresh() {
        microphone = microphoneStatus()
        accessibility = accessibilityStatus()
        if accessibility { accessibilityRecheckFailed = false }
    }
    func recheckAccessibility() {
        refresh()
        accessibilityRecheckFailed = !accessibility
    }
    func request(_ kind: PermissionKind) async {
        guard !requesting, canStartWork() else { return }
        requesting = true
        settingsFailed = false
        defer { requesting = false; refresh() }
        refresh()
        switch kind {
        case .microphone:
            if microphone == .notDetermined {
                await requestAudio()
            } else if microphone == .denied { openSettings(kind) }
        case .accessibility:
            guard !accessibility else { return }
            if accessibilityRequested {
                openSettings(kind)
            } else {
                accessibilityRequested = true
                // Let the native dialog open Settings itself. Opening both here
                // used to leave the permission dialog hidden behind Settings.
                requestControl()
            }
        }
    }
    func openSettings(_ kind: PermissionKind) {
        let pane = kind == .microphone ? "Microphone" : "Accessibility"
        guard let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_\(pane)") else { return }
        settingsFailed = !openURL(url)
    }
}
