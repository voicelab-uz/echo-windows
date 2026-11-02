import AppKit
import SwiftUI

/// A local shortcut exercise. It never starts dictation or installs a global key hook.
struct SetupShortcutDemo: View {
    let language: WelcomeLanguage
    @Binding var validation: SetupShortcutValidation
    var shortcutError: String? = nil
    var onRetry: (() -> Void)? = nil
    var onOpenSettings: (() -> Void)? = nil
    let onContinue: () -> Void
    @Environment(\.onboardingShortcutLabel) private var shortcut
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var activation = 0
    @State private var shimmering = false

    var body: some View {
        VStack(spacing: 30) {
            SetupFnKey(pressed: validation.isPressed, shimmering: shimmering, activation: activation)
                .allowsHitTesting(false)
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(shortcut)
                .accessibilityValue(validation.isValidated ? language.setupCopy.shortcutSuccess : language.setupCopy.shortcutHint)
                .accessibilityIdentifier("setup-fn-key")
            ZStack {
                Text(language.setupCopy.shortcutHint)
                    .opacity(validation.isValidated ? 0 : 1)
                    .accessibilityHidden(validation.isValidated)
                Label(language.setupCopy.shortcutSuccess, systemImage: "checkmark.circle.fill")
                    .foregroundStyle(Color(red: 0.27, green: 0.48, blue: 0.36))
                    .opacity(validation.isValidated ? 1 : 0)
                    .accessibilityHidden(!validation.isValidated)
                    .accessibilityIdentifier("setup-shortcut-success")
            }
            .font(WelcomeType.font(size: 15))
            .foregroundStyle(WelcomePalette.muted)
            .multilineTextAlignment(.center)
            .fixedSize(horizontal: false, vertical: true)
            .animation(.easeOut(duration: 0.18), value: validation.isValidated)
            ZStack {
                if validation.isValidated && shortcutError == nil {
                    Button {
                        guard validation.isValidated, shortcutError == nil else { return }
                        onContinue()
                    } label: {
                        HStack(spacing: 12) {
                            Text(language.permissionsCopy.continueTitle)
                            Image(systemName: "arrow.forward")
                        }
                        .font(WelcomeType.font(size: 14, weight: .semibold))
                        .frame(maxWidth: .infinity).frame(height: 44)
                        .contentShape(.rect)
                    }
                    .buttonStyle(WelcomePrimaryButton())
                    .keyboardShortcut(.defaultAction)
                    .accessibilityIdentifier("setup-shortcut-continue")
                    .transition(.opacity)
                }
            }
            .frame(width: 240, height: 44)
            .animation(.easeOut(duration: 0.2), value: validation.isValidated)
            if let shortcutError {
                VStack(spacing: 12) {
                    Text(shortcutError)
                        .font(WelcomeType.font(size: 12))
                        .foregroundStyle(WelcomePalette.muted)
                        .multilineTextAlignment(.center)
                        .fixedSize(horizontal: false, vertical: true)
                    HStack(spacing: 20) {
                        if let onRetry {
                            Button(language.permissionsCopy.checkAgain, action: onRetry)
                                .accessibilityIdentifier("setup-shortcut-retry")
                        }
                        if let onOpenSettings {
                            Button(language.permissionsCopy.settings.systemSettings, action: onOpenSettings)
                                .accessibilityIdentifier("setup-shortcut-settings")
                        }
                    }
                    .font(WelcomeType.font(size: 12, weight: .semibold))
                    .buttonStyle(.plain)
                }
            }
        }
        .padding(.vertical, 24)
        .background {
            OnboardingFnInput { keyCode, functionDown, isFocused in
                guard shortcutError == nil else { validation.release(); return }
                let wasValidated = validation.isValidated
                if validation.receive(keyCode: keyCode, functionDown: functionDown, isFocused: isFocused) {
                    if !wasValidated { OnboardingHaptics.play(.confirmation) }
                    activate()
                }
            }
            .frame(width: 0, height: 0)
        }
        .task(id: activation) {
            guard activation > 0 else { return }
            do { try await Task.sleep(for: .milliseconds(950)) } catch { return }
            shimmering = false
        }
        .onDisappear { validation.release() }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("setup-shortcut-preview")
    }

    private func activate() {
        shimmering = true
        activation += 1
    }
}

private struct SetupFnKey: View {
    let pressed: Bool
    let shimmering: Bool
    let activation: Int
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.onboardingShortcutLabel) private var shortcut

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 16)
                .fill(WelcomePalette.ink.opacity(0.12))
                .offset(y: 5)
            RoundedRectangle(cornerRadius: 16)
                .fill(pressed || shimmering ? WelcomePalette.lavender : WelcomePalette.canvas)
                .overlay {
                    RoundedRectangle(cornerRadius: 16)
                        .strokeBorder(WelcomePalette.ink.opacity(pressed ? 0.2 : 0.12))
                }
                .overlay {
                    Text(shortcut).font(WelcomeType.font(size: 40, weight: .medium))
                        .lineLimit(1).minimumScaleFactor(0.4).padding(.horizontal, 10)
                        .foregroundStyle(WelcomePalette.ink)
                }
                .offset(y: pressed && !reduceMotion ? 4 : 0)
        }
        .frame(width: 116, height: 108)
        .scaleEffect(pressed && !reduceMotion ? 0.97 : 1)
        .overlay {
            if shimmering && !reduceMotion {
                SetupKeyRipple().id(activation)
                    .frame(width: 360, height: 360)
                    .allowsHitTesting(false)
                    .accessibilityHidden(true)
            }
        }
        .animation(reduceMotion ? .easeOut(duration: 0.12) : .spring(response: 0.24, dampingFraction: 0.65), value: pressed)
        .animation(.easeOut(duration: 0.18), value: shimmering)
    }
}

/// A single soft ring starts at the key's center, expands outward, then dissolves.
private struct SetupKeyRipple: View {
    @State private var progress: CGFloat = 0

    var body: some View {
        ZStack {
            Circle().strokeBorder(.white.opacity(0.9), lineWidth: 14).blur(radius: 5)
            Circle().strokeBorder(Color(red: 0.72, green: 0.67, blue: 0.87).opacity(0.35), lineWidth: 1.5)
        }
        .scaleEffect(0.08 + 0.92 * progress)
        .opacity(Double(1 - progress))
        .onAppear {
            withAnimation(.easeOut(duration: 0.9)) { progress = 1 }
        }
    }
}
