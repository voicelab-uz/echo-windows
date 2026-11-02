import AVFoundation
import SwiftUI
import VoiceLabCore

/// Native status-bar menu: a short list of actions instead of a floating panel.
/// The body stays side-effect free; mutating state while the menu opens can dismiss it.
struct MenuBarView: View {
    let model: AppModel
    @Environment(\.dictationShortcut) private var shortcut
    @State private var microphones = MenuBarMicrophoneSources()
    private var isReady: Bool { model.account != nil && model.onboarding.isComplete }
    private var lastTranscript: String? {
        model.library.snapshot.transcripts.max(by: { $0.createdAt < $1.createdAt })?.text
    }

    var body: some View {
        Text(statusTitle)
        Button(AppLocalization.text("Oxirgi yozuvni joylash")) { model.pasteLastTranscript() }
            .keyboardShortcut("v", modifiers: [.control, .command])
            .disabled(lastTranscript == nil || !isReady)
        Button(AppLocalization.text("Oxirgi matnni nusxalash")) {
            if let lastTranscript { TextInsertion.copy(lastTranscript) }
        }
        .disabled(lastTranscript == nil)
        Divider()
        Button(AppLocalization.text("Echo’ni ochish")) { openMainWindow() }
        Button(AppLocalization.text("Sozlamalar") + "…") { model.showSettings() }
            .keyboardShortcut(",", modifiers: .command)
            .disabled(model.needsSignIn)
        microphoneMenu
        if AppUpdateChecker.shared.hasUpdate {
            Text(AppUpdateChecker.shared.statusTitle)
        }
        Button(AppUpdateChecker.shared.actionTitle, action: AppUpdateChecker.shared.check)
            .disabled(!AppUpdateChecker.shared.canCheck || AppUpdateChecker.shared.isInstalling)
        Divider()
        Button(AppLocalization.text("Echo’dan chiqish")) { NSApp.terminate(nil) }
            .keyboardShortcut("q", modifiers: .command)
    }

    private var statusTitle: String {
        guard isReady else { return AppLocalization.text("Echo oynasida boshlang‘ich sozlashni yakunlang.") }
        switch model.dictation.phase {
        case .preparing: return AppLocalization.text("Tayyorlanmoqda…")
        case .recording: return AppLocalization.text("Yozilmoqda…")
        case .transcribing: return AppLocalization.text("Matnga aylantirilmoqda…")
        case .idle, .failed: return AppLocalization.text("Yozishga tayyor (%@)", shortcut.displayName)
        }
    }

    /// Input picker mirrored from onboarding; selection is persisted through the shared preference.
    private var microphoneMenu: some View {
        let selection = Binding(
            get: {
                let id = model.onboarding.microphone.selectedDeviceID
                return id.isEmpty ? MicrophoneDevice.defaultDeviceID : id
            },
            set: { model.onboarding.microphone.select($0) })
        let devices = microphones.devices
        let selectedID = selection.wrappedValue
        let isSelectedMissing = !selectedID.isEmpty && !devices.contains { $0.id == selectedID }
        return Menu(AppLocalization.text("Mikrofon")) {
            Picker(AppLocalization.text("Mikrofon"), selection: selection) {
                ForEach(devices) { device in
                    Text(device.name).tag(device.id)
                }
                if isSelectedMissing {
                    Text(AppLocalization.text("Ulanmagan mikrofon")).tag(selectedID)
                }
            }
            .pickerStyle(.inline)
            .labelsHidden()
        }
    }

    private func openMainWindow() {
        model.mainWindow.show()
        NSApp.activate(ignoringOtherApps: true)
    }
}

/// Keeps the audio input list current from device connect/disconnect notifications,
/// so the menu never has to enumerate hardware while it is opening.
@MainActor @Observable
private final class MenuBarMicrophoneSources {
    private(set) var devices: [MicrophoneDevice] = []
    @ObservationIgnored private var task: Task<Void, Never>?
    // Tokens are only written in init and read in deinit, so no concurrent access is possible.
    @ObservationIgnored nonisolated(unsafe) private var observers: [any NSObjectProtocol] = []

    init() {
        refresh()
        let center = NotificationCenter.default
        for name in [AVCaptureDevice.wasConnectedNotification, AVCaptureDevice.wasDisconnectedNotification] {
            observers.append(
                center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                    MainActor.assumeIsolated { self?.refresh() }
                })
        }
    }

    deinit {
        observers.forEach(NotificationCenter.default.removeObserver)
    }

    private func refresh() {
        task?.cancel()
        task = Task { [weak self] in
            let devices = await MicrophoneCapture().devices()
            guard !Task.isCancelled else { return }
            self?.devices = devices
        }
    }
}
