import SwiftUI

/// Shown in the app while it holds the mic for the keyboard, so the orange mic indicator
/// always has a visible explanation and an off switch.
struct KeyboardSessionBanner: View {
    let host: KeyboardSessionHost

    @Environment(\.openURL) private var openURL

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: host.isOn ? "mic.fill" : "exclamationmark.triangle.fill")
                .font(.title3)
                .foregroundStyle(host.phase == .recording ? .red : (host.isOn ? .primary : .orange))
                .frame(width: 28)
                .symbolEffect(.pulse, isActive: host.phase == .recording)
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.subheadline.weight(.semibold))
                Text(detail)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            if host.isOn {
                Button("Turn off", action: host.stop)
                    .font(.footnote.weight(.semibold))
                    .buttonStyle(.bordered)
            } else if host.failure == .permissionDenied, let url = URL(string: UIApplication.openSettingsURLString) {
                Button("Settings") { openURL(url) }
                    .font(.footnote.weight(.semibold))
                    .buttonStyle(.bordered)
            } else {
                Button(action: host.dismissFailure) {
                    Image(systemName: "xmark")
                        .font(.footnote.weight(.semibold))
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Dismiss")
            }
        }
        .padding(12)
        .background(.thinMaterial, in: .rect(cornerRadius: 16, style: .continuous))
        .padding(.horizontal, 12)
        .accessibilityElement(children: .combine)
    }

    private var title: LocalizedStringKey {
        switch host.phase {
        case .off: "Voice keyboard couldn't start"
        case .starting: "Starting voice keyboard…"
        case .ready, .recording, .transcribing: "Voice keyboard is on"
        }
    }

    private var detail: LocalizedStringKey {
        switch host.phase {
        case .off:
            switch host.failure {
            case .permissionDenied: "Allow microphone access in Settings."
            case .unavailable, .offline, .noCredits, .noSpeech, .recognitionFailed, nil: "Try again from the keyboard."
            }
        case .starting: "Getting the microphone ready."
        case .recording: "Listening. Go back to your chat (◀ top left) and tap ✓ on the keyboard."
        case .transcribing: "Turning your speech into text."
        case .ready:
            if host.keepsMicrophoneReady {
                "Microphone ready for up to 5 idle minutes. Return to your chat, or turn off to release it."
            } else {
                "Return to your chat. The microphone turns off when this recording ends."
            }
        }
    }
}
