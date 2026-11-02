import SwiftUI
import AVFoundation

/// Local microphone check. Audio is metered in memory and never recorded or uploaded.
struct SetupExperience: View {
    @Binding var language: WelcomeLanguage
    let onBack: () -> Void
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var monitor = SetupMicrophoneMonitor()
    @State private var appeared = false
    @State private var showingMicrophones = false
    enum Step: String, Codable { case microphone, shortcut, alphabet }
    @Binding var step: Step
    @State private var shortcutValidation = SetupShortcutValidation()
    @Binding var usesNewAlphabet: Bool
    @Binding var deviceID: String
    var shortcutError: String? = nil
    var onRetryShortcut: (() -> Void)? = nil
    var onOpenShortcutSettings: (() -> Void)? = nil
    /// The chosen dictation key; production maps it to the real shortcut.
    var keyChoice: Binding<OnboardingKeyChoice> = .constant(.fn)
    /// Shown under the keys when "Custom" is chosen; production supplies the recorder.
    var customRecorder: AnyView? = nil
    /// Key codes of the recorded custom shortcut, lit on the keyboard when Custom is chosen.
    var customKeys: Set<UInt16> = []
    let onContinue: () -> Void

    private var copy: SetupCopy { language.setupCopy }
    private var heading: String {
        switch step {
        case .microphone: copy.heading
        case .shortcut: copy.shortcutHeading
        case .alphabet: copy.alphabetHeading
        }
    }
    private var microphoneName: String {
        monitor.devices.first(where: { $0.id == monitor.selectedDeviceID })?.name ?? copy.systemDefault
    }
    private var status: String {
        if let error = monitor.error {
            switch error {
            case .permission: return copy.permissionError
            case .notFound: return copy.deviceError
            default: return copy.captureError
            }
        }
        switch monitor.state {
        case .idle: return copy.ready
        case .starting: return copy.connecting
        case .listening: return monitor.heardSound ? copy.complete : copy.speak
        case .stopped: return monitor.heardSound ? copy.complete : copy.noSound
        }
    }

    var body: some View { setupContent }

    /// The shortcut step sits beside a keyboard illustration; the others stay centred.
    private var isSplit: Bool { step == .shortcut }

    private func goBack() {
        withAnimation(.easeOut(duration: 0.2)) {
            switch step {
            case .microphone: onBack()
            case .shortcut: step = .microphone
            case .alphabet: step = .shortcut
            }
        }
    }

    private func goNext() {
        switch step {
        case .microphone:
            monitor.stop()
            OnboardingHaptics.play(.confirmation)
            withAnimation(.easeOut(duration: 0.2)) { step = .shortcut }
        case .shortcut:
            guard shortcutError == nil else { return }
            withAnimation(.easeOut(duration: 0.2)) { step = .alphabet }
        case .alphabet:
            onContinue()
        }
    }

    private var setupContent: some View {
        VStack(spacing: 0) {
            OnboardingNavigationBar(language: $language, backIdentifier: "setup-back", onBack: goBack)
            GeometryReader { window in
            HStack(spacing: 0) {
            GeometryReader { geometry in
                ScrollView {
                    VStack(alignment: isSplit ? .leading : .center, spacing: 28) {
                        Text(heading)
                            .font(WelcomeType.font(size: 32, weight: .semibold))
                            .tracking(language.usesLatin ? -0.9 : 0)
                            .multilineTextAlignment(isSplit ? .leading : .center)
                            .fixedSize(horizontal: false, vertical: true)
                            .accessibilityAddTraits(.isHeader)
                        switch step {
                        case .microphone:
                            microphoneCheck.transition(.opacity)
                        case .shortcut:
                            SetupKeyChooser(language: language, choice: keyChoice, validation: $shortcutValidation,
                                            customRecorder: customRecorder, shortcutError: shortcutError,
                                            onRetry: onRetryShortcut, onOpenSettings: onOpenShortcutSettings)
                                .transition(.opacity)
                        case .alphabet:
                            SetupAlphabetChoices(language: language, usesNewAlphabet: $usesNewAlphabet)
                                .transition(.opacity)
                        }
                    }
                    .frame(maxWidth: step == .microphone ? 480 : isSplit ? 370 : 560,
                           alignment: isSplit ? .leading : .center)
                    .padding(.horizontal, isSplit ? 36 : 32).padding(.vertical, step == .alphabet ? 24 : 32)
                    .frame(maxWidth: .infinity, minHeight: geometry.size.height)
                    .opacity(appeared ? 1 : 0)
                    .offset(y: appeared || reduceMotion ? 0 : 8)
                }
                .scrollIndicators(.hidden)
                .scrollBounceBehavior(.basedOnSize)
            }
            .frame(width: isSplit ? window.size.width / 2 : nil)
            // Like Wispr: a keyboard filling the other half, with the chosen key lit.
            if isSplit {
                SetupKeyboard(highlighted: keyChoice.wrappedValue, pressed: shortcutValidation.isPressed,
                              customKeys: customKeys)
                    .clipShape(.rect(cornerRadius: 20, style: .continuous))
                    .padding(.trailing, 24).padding(.top, 4)
                    .frame(width: window.size.width / 2)
                    .transition(.opacity)
            }
            }
            }
            .animation(.easeOut(duration: 0.2), value: isSplit)
            OnboardingFooter(language: language, backIdentifier: "setup-back", onBack: goBack,
                             nextEnabled: step != .shortcut || shortcutError == nil,
                             nextIdentifier: "setup-next", onNext: goNext)
        }
        .background(SetupBackdrop())
        .onAppear {
            withAnimation(.easeOut(duration: reduceMotion ? 0.15 : 0.4)) { appeared = true }
        }
        .task { monitor.select(deviceID); await monitor.refreshDevices() }
        .task(id: step) { if step == .microphone && !monitor.active { monitor.start() } }
        .onChange(of: monitor.selectedDeviceID) { _, value in
            deviceID = value
            if step == .microphone { monitor.start() }
        }
        .onDisappear { monitor.stop() }
        .onReceive(NotificationCenter.default.publisher(for: Notification.Name("Echo.stopOnboarding"))) { _ in monitor.stop() }
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.willCloseNotification)) { notification in
            // The device popover also owns a window; closing it must not stop capture.
            if let window = notification.object as? NSWindow, window.canBecomeMain { monitor.stop() }
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            Task { await monitor.refreshDevices() }
        }
        .onReceive(NotificationCenter.default.publisher(for: AVCaptureDevice.wasConnectedNotification)) { _ in
            Task { await monitor.refreshDevices() }
        }
        .onReceive(NotificationCenter.default.publisher(for: AVCaptureDevice.wasDisconnectedNotification)) { _ in
            Task { await monitor.refreshDevices() }
        }
    }

    private var microphoneCheck: some View {
        VStack(spacing: 0) {
            microphonePicker
            SetupLevelWaveform(levels: monitor.displayLevels, active: monitor.active)
                .frame(height: 104).padding(.top, 28)
            HStack(spacing: 7) {
                if monitor.canContinue {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(Color(red: 0.27, green: 0.48, blue: 0.36))
                        .accessibilityHidden(true)
                }
                Text(status).contentTransition(.opacity)
            }
            .font(WelcomeType.font(size: 14, weight: .medium))
            .foregroundStyle(monitor.error != nil ? WelcomePalette.coral : WelcomePalette.muted)
            .multilineTextAlignment(.center)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, minHeight: 44)
            .accessibilityIdentifier("setup-test-status")
            .animation(.easeOut(duration: 0.2), value: monitor.canContinue)
            if monitor.error == .permission {
                Button(language.permissionsCopy.settings.systemSettings) {
                    guard let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone") else { return }
                    NSWorkspace.shared.open(url)
                }
                .buttonStyle(.plain)
                .font(WelcomeType.font(size: 12, weight: .semibold))
                .padding(.top, 8)
            }
            VStack(spacing: 12) {
                Text(copy.barsQuestion)
                    .font(WelcomeType.font(size: 15, weight: .semibold))
                    .multilineTextAlignment(.center).fixedSize(horizontal: false, vertical: true)
                Button(action: goNext) {
                    Text(copy.barsConfirm)
                        .font(WelcomeType.font(size: 14, weight: .semibold))
                        .frame(maxWidth: .infinity).frame(height: 44)
                        .contentShape(.rect)
                }
                .buttonStyle(WelcomePrimaryButton())
                .accessibilityIdentifier("setup-bars-confirm")
                if monitor.error != nil || monitor.state == .stopped {
                    Button(copy.tryAgain) { monitor.start() }
                        .buttonStyle(.plain)
                        .font(WelcomeType.font(size: 12, weight: .medium))
                        .foregroundStyle(WelcomePalette.muted)
                        .accessibilityIdentifier("setup-retry-microphone")
                }
            }
            .padding(.top, 24)
        }
        .padding(28)
        .background(WelcomePalette.canvas, in: .rect(cornerRadius: 16))
        .overlay(RoundedRectangle(cornerRadius: 16).strokeBorder(WelcomePalette.ink.opacity(0.06)))
        .shadow(color: WelcomePalette.ink.opacity(0.055), radius: 24, y: 10)
    }

    private var microphonePicker: some View {
        Button {
            showingMicrophones.toggle()
            Task { await monitor.refreshDevices() }
        } label: {
            HStack(spacing: 10) {
                Image(systemName: "mic").frame(width: 18)
                    .foregroundStyle(WelcomePalette.muted)
                Text(microphoneName)
                    .lineLimit(2).multilineTextAlignment(.leading)
                Spacer(minLength: 4)
                Image(systemName: "chevron.down").font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(WelcomePalette.muted)
            }
            .font(WelcomeType.font(size: 13, weight: .medium))
            .padding(.horizontal, 12).frame(minHeight: 44)
            .frame(maxWidth: .infinity)
            .background(WelcomePalette.ink.opacity(0.025), in: .rect(cornerRadius: 8))
            .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(WelcomePalette.ink.opacity(0.12)))
            .contentShape(.rect(cornerRadius: 8))
        }
        .buttonStyle(.plain)
        .popover(isPresented: $showingMicrophones, arrowEdge: .bottom) {
            VStack(alignment: .leading, spacing: 4) {
                Text(copy.availableDevices)
                    .font(WelcomeType.font(size: 11))
                    .foregroundStyle(WelcomePalette.muted)
                    .padding(.horizontal, 10).padding(.vertical, 6)
                ForEach([MicrophoneDevice(id: "", name: copy.systemDefault)] + monitor.devices) { device in
                    Button {
                        let changed = device.id != monitor.selectedDeviceID
                        let wasActive = monitor.active
                        monitor.select(device.id)
                        showingMicrophones = false
                        if changed && !wasActive { OnboardingHaptics.play(.selection) }
                    } label: {
                        HStack(spacing: 10) {
                            Image(systemName: "mic").frame(width: 18)
                            Text(device.name)
                            Spacer(minLength: 8)
                            Image(systemName: "checkmark")
                                .opacity(device.id == monitor.selectedDeviceID ? 1 : 0)
                        }
                        .font(WelcomeType.font(size: 13, weight: .medium))
                        .padding(.horizontal, 10).frame(minHeight: 38)
                        .contentShape(.rect)
                    }
                    .buttonStyle(SetupDeviceButtonStyle(selected: device.id == monitor.selectedDeviceID))
                    .accessibilityAddTraits(device.id == monitor.selectedDeviceID ? .isSelected : [])
                    .accessibilityIdentifier("setup-device-\(device.id)")
                }
            }
            .padding(8).frame(width: 300)
        }
        .accessibilityLabel(language.permissionsCopy.microphone)
        .accessibilityValue(microphoneName)
        .accessibilityIdentifier("setup-microphone-picker")
    }
}

private struct SetupDeviceButtonStyle: ButtonStyle {
    let selected: Bool
    @State private var hovered = false
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .foregroundStyle(WelcomePalette.ink)
            .background(WelcomePalette.ink.opacity(configuration.isPressed ? 0.1 : hovered ? 0.075 : selected ? 0.045 : 0), in: .rect(cornerRadius: 6))
            .onHover { hovered = $0 }
    }
}

struct SetupCopy: Decodable {
    let heading, systemDefault, availableDevices: String
    let tryMicrophone, stop, tryAgain, complete, speak, ready: String
    let connecting, noSound, permissionError, deviceError, captureError: String
    let shortcutHeading, shortcutHint, shortcutSuccess: String
    let alphabetHeading, alphabetHint, currentAlphabet, newAlphabet: String
    let barsQuestion, barsConfirm, next, wellDone: String
    let keyIntro, keyFn, keyCommand, keyOption, keyCustom, behaviorNote: String

    /// Copy mentions the shortcut by name, so it follows the user's current shortcut.
    static var catalog: [String: SetupCopy] {
        guard let catalog = OnboardingShortcutName.catalog("SetupLanguages", as: SetupCopy.self),
              WelcomeLanguage.allCases.allSatisfy({ catalog[$0.rawValue] != nil })
        else { fatalError("The preview requires its complete SetupLanguages.json resource.") }
        return catalog
    }
}

extension WelcomeLanguage {
    var setupCopy: SetupCopy { SetupCopy.catalog[rawValue]! }
}
