import SwiftUI

/// The actual writing surface stays editable while the recorder reports its own state.
struct TryItPractice: View {
    let language: WelcomeLanguage
    @Binding var text: String
    let phase: TryItModel.Phase
    let failureMessage: String?
    let successfulTrials: Int
    let fnPressed: Bool
    let levels: [Double]
    var usesSystemIsland = false
    let onCancel: () -> Void
    let onNext: () -> Void
    @FocusState private var inputFocused: Bool
    @Environment(\.onboardingShortcutLabel) private var shortcut
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var completionGlow = false

    private var copy: TryItCopy { TryItCopy.catalog[language.rawValue]! }
    private var completed: Bool {
        successfulTrials > 0 && phase == .ready && failureMessage == nil
    }
    private var hint: String {
        switch phase {
        case .recording: copy.stopHint
        case .transcribing: ""
        default: completed ? copy.successHint : copy.instruction
        }
    }
    private var recorderStatus: String {
        switch phase {
        case .starting: language.setupCopy.connecting
        case .recording: copy.listening
        case .transcribing: copy.transcribing
        default: completed ? copy.success : copy.ready
        }
    }
    private var working: Bool { phase == .starting || phase == .transcribing }
    private var canCancel: Bool { working || phase == .recording }

    var body: some View {
        VStack(spacing: 0) {
            VStack(spacing: 12) {
                Text(completed ? copy.successHeading : copy.heading)
                    .font(WelcomeType.font(size: 32, weight: .semibold))
                    .tracking(language.usesLatin ? -0.9 : 0)
                    .accessibilityAddTraits(.isHeader)
                    .contentTransition(.opacity)
                Text(hint)
                    .font(WelcomeType.font(size: 14))
                    .foregroundStyle(WelcomePalette.muted)
                    .contentTransition(.opacity)
                    .frame(minHeight: 20)
                    .accessibilityHidden(hint.isEmpty)
            }
            .multilineTextAlignment(.center)
            .fixedSize(horizontal: false, vertical: true)
            .frame(minHeight: 82)
            .animation(.easeOut(duration: 0.2), value: completed)
            .animation(.easeOut(duration: 0.18), value: phase)

            writingArea.padding(.top, 28)

            if let failureMessage {
                Label(failureMessage, systemImage: "exclamationmark.circle")
                    .font(WelcomeType.font(size: 12, weight: .medium))
                    .foregroundStyle(WelcomePalette.coral)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, 16)
                    .accessibilityIdentifier("try-it-error")
                    .transition(.opacity)
            }

            Group {
                if completed {
                    Button(action: onNext) {
                        HStack(spacing: 12) {
                            Text(copy.next)
                            Image(systemName: "arrow.forward")
                        }
                        .font(WelcomeType.font(size: 14, weight: .semibold))
                        .frame(maxWidth: .infinity, minHeight: 54)
                        .contentShape(.rect)
                    }
                    .buttonStyle(WelcomePrimaryButton())
                    .frame(maxWidth: 340)
                    .accessibilityIdentifier("try-it-next")
                    .transition(.opacity)
                } else if usesSystemIsland {
                    keyboardCue
                        .opacity(canCancel ? 0 : 1)
                        .accessibilityHidden(canCancel)
                        .transition(.opacity)
                } else {
                    recorder.transition(.opacity)
                }
            }
            .frame(height: 54)
            .padding(.top, 20)
            .animation(.easeOut(duration: 0.2), value: completed)
        }
        .task { inputFocused = true }
        .onChange(of: successfulTrials) { _, _ in
            inputFocused = true
        }
        .task(id: successfulTrials) {
            guard successfulTrials > 0 else { return }
            completionGlow = true
            do { try await Task.sleep(for: .milliseconds(150)) } catch { return }
            withAnimation(.easeOut(duration: reduceMotion ? 0.2 : 0.85)) { completionGlow = false }
        }
    }

    private var writingArea: some View {
        ZStack(alignment: .topLeading) {
            if text.isEmpty {
                Text(copy.placeholder)
                    .foregroundStyle(WelcomePalette.muted.opacity(0.7))
                    .padding(.horizontal, 5).padding(.top, 1)
                    .allowsHitTesting(false)
                    .accessibilityHidden(true)
            }
            TextEditor(text: $text)
                .scrollContentBackground(.hidden)
                .focused($inputFocused)
                .accessibilityLabel(copy.placeholder)
                .accessibilityIdentifier("try-it-input")
        }
        .font(WelcomeType.font(size: 22))
        .lineSpacing(7)
        .frame(height: 124)
        .padding(28)
        .background(WelcomePalette.canvas, in: .rect(cornerRadius: 14))
        .overlay {
            RoundedRectangle(cornerRadius: 14)
                .strokeBorder(phase == .recording ? WelcomePalette.coral.opacity(0.3) : WelcomePalette.ink.opacity(0.1))
        }
        .overlay {
            RoundedRectangle(cornerRadius: 14)
                .strokeBorder(Color(red: 0.59, green: 0.55, blue: 0.75).opacity(completionGlow ? 0.5 : 0), lineWidth: 2)
                .allowsHitTesting(false)
                .accessibilityHidden(true)
        }
        .shadow(color: WelcomePalette.ink.opacity(0.035), radius: 12, y: 5)
        .animation(.easeOut(duration: 0.2), value: phase)
        .tint(WelcomePalette.ink)
    }

    /// Production uses the real screen-edge island. Keep only a quiet keyboard
    /// hint here, so capture levels and controls are never duplicated in the page.
    private var keyboardCue: some View {
        HStack(spacing: 10) {
            Text(shortcut)
                .font(WelcomeType.font(size: 14, weight: .semibold))
                .lineLimit(1).padding(.horizontal, 8)
                .frame(minWidth: 38).frame(height: 32)
                .background(WelcomePalette.ink.opacity(fnPressed ? 0.12 : 0.06), in: .rect(cornerRadius: 7))
                .overlay(RoundedRectangle(cornerRadius: 7).strokeBorder(WelcomePalette.ink.opacity(0.12)))
                .scaleEffect(fnPressed && !reduceMotion ? 0.95 : 1)
                .animation(reduceMotion ? nil : .easeOut(duration: 0.12), value: fnPressed)
                .accessibilityHidden(true)
            Text(recorderStatus)
                .font(WelcomeType.font(size: 12, weight: .medium))
                .foregroundStyle(WelcomePalette.muted)
                .accessibilityIdentifier("try-it-status")
        }
    }

    /// Standalone design previews retain a local recorder without a system panel.
    private var recorder: some View {
        HStack(spacing: 12) {
            Text(shortcut)
                .font(WelcomeType.font(size: 16, weight: .medium))
                .lineLimit(1).padding(.horizontal, 8)
                .frame(minWidth: 38).frame(height: 34)
                .background(.white.opacity(fnPressed ? 0.24 : 0.11), in: .rect(cornerRadius: 7))
                .overlay(RoundedRectangle(cornerRadius: 7).strokeBorder(.white.opacity(fnPressed ? 0.4 : 0.17)))
                .scaleEffect(fnPressed && !reduceMotion ? 0.95 : 1)
                .offset(y: fnPressed && !reduceMotion ? 1 : 0)
                .animation(reduceMotion ? nil : .easeOut(duration: 0.12), value: fnPressed)
                .accessibilityHidden(true)
            Text(recorderStatus)
                .font(WelcomeType.font(size: 12, weight: .medium))
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentTransition(.opacity)
                .accessibilityIdentifier("try-it-status")
            if phase == .recording {
                TryItVoiceLevels(levels: levels)
            } else if working {
                ProgressView().controlSize(.small).colorScheme(.dark)
                    .accessibilityHidden(true)
            } else if completed {
                Image(systemName: "checkmark")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Color(red: 0.64, green: 0.84, blue: 0.71))
                    .accessibilityHidden(true)
            }
            if canCancel {
                Button(action: onCancel) {
                    Image(systemName: "xmark")
                        .font(.system(size: 10, weight: .medium))
                        .frame(width: 28, height: 34)
                        .contentShape(.rect)
                }
                .buttonStyle(.plain)
                .foregroundStyle(.white.opacity(0.65))
                .accessibilityLabel(copy.cancel)
                .help(copy.cancel)
                .accessibilityIdentifier("try-it-cancel")
            }
        }
        .foregroundStyle(.white)
        .padding(.leading, 10).padding(.trailing, 16).padding(.vertical, 10)
        .frame(maxWidth: 340, minHeight: 54)
        .background(WelcomePalette.control, in: .rect(cornerRadius: 19))
        .shadow(color: WelcomePalette.ink.opacity(0.1), radius: 10, y: 5)
        .animation(.easeOut(duration: 0.18), value: phase)
        .accessibilityElement(children: .contain)
    }
}

private struct TryItVoiceLevels: View {
    let levels: [Double]
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    var body: some View {
        HStack(spacing: 3) {
            ForEach(0..<9) { index in
                let band = abs(index - 4)
                let level = levels.indices.contains(band) ? levels[band] : 0
                Capsule().fill(.white.opacity(0.9))
                    .frame(width: 3, height: 3 + 21 * min(1, max(0, level)))
            }
        }
        .frame(width: 51, height: 26)
        .animation(reduceMotion ? nil : .linear(duration: 0.07), value: levels)
        .accessibilityHidden(true)
    }
}
