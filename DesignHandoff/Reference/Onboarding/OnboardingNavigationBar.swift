import SwiftUI

/// The top of each onboarding step: only the language picker, anchored to the window.
/// Back and Next live in `OnboardingFooter` at the bottom.
struct OnboardingNavigationBar: View {
    @Binding var language: WelcomeLanguage
    let backIdentifier: String
    var backDisabled = false
    let onBack: () -> Void

    static let height: CGFloat = 52

    var body: some View {
        HStack {
            Spacer()
            WelcomeLanguagePicker(language: $language)
        }
        .frame(height: 32)
        .padding(.horizontal, 36)
        .padding(.top, 20)
    }
}

/// Text-only Back (left) and Next (right) at the bottom of an onboarding step.
struct OnboardingFooter: View {
    let language: WelcomeLanguage
    let backIdentifier: String
    var backDisabled = false
    let onBack: () -> Void
    var nextTitle: String? = nil
    var nextEnabled = true
    var nextIdentifier = "onboarding-next"
    var onNext: (() -> Void)? = nil
    /// Split-layout steps already inset their column, so they pass 0.
    var inset: CGFloat = 36
    static let height: CGFloat = 80

    var body: some View {
        HStack(spacing: 12) {
            Button(language.permissionsCopy.back, action: onBack)
                .buttonStyle(OnboardingSecondaryButton())
                .disabled(backDisabled)
                .accessibilityIdentifier(backIdentifier)
            Spacer(minLength: 12)
            if let onNext {
                Button {
                    OnboardingHaptics.play(.navigation)
                    onNext()
                } label: {
                    Text(nextTitle ?? language.setupCopy.next)
                        .font(WelcomeType.font(size: 14, weight: .semibold))
                        .padding(.horizontal, 26).frame(minWidth: 96).frame(height: 40)
                        .contentShape(.rect)
                }
                .buttonStyle(WelcomePrimaryButton())
                .keyboardShortcut(.defaultAction)
                .disabled(!nextEnabled)
                .opacity(nextEnabled ? 1 : 0.45)
                .accessibilityIdentifier(nextIdentifier)
            }
        }
        .padding(.horizontal, inset)
        .padding(.bottom, 22).padding(.top, 18)
        // A hairline separates the navigation from the step's content.
        .overlay(alignment: .top) {
            Rectangle().fill(WelcomePalette.ink.opacity(0.09)).frame(height: 1)
                .accessibilityHidden(true)
        }
    }
}

/// A quiet, outlined button for secondary navigation such as Back.
struct OnboardingSecondaryButton: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        OnboardingSecondaryButtonBody(configuration: configuration)
    }
}

private struct OnboardingSecondaryButtonBody: View {
    let configuration: ButtonStyleConfiguration
    @Environment(\.isEnabled) private var isEnabled
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var hovered = false

    var body: some View {
        configuration.label
            .font(WelcomeType.font(size: 14, weight: .medium))
            .foregroundStyle(isEnabled ? WelcomePalette.ink : WelcomePalette.muted)
            .padding(.horizontal, 22).frame(minWidth: 88).frame(height: 40)
            .background(WelcomePalette.ink.opacity(hovered && isEnabled ? 0.09 : 0.05), in: .rect(cornerRadius: 12))
            .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(WelcomePalette.ink.opacity(0.14)))
            .contentShape(.rect(cornerRadius: 12))
            .opacity(isEnabled ? 1 : 0.5)
            .scaleEffect(configuration.isPressed && !reduceMotion ? 0.98 : 1)
            .onHover { hovered = $0 }
            .animation(.easeOut(duration: 0.15), value: hovered)
    }
}
