import SwiftUI

/// The same sign-in and voice trial interface is used by both preview entry points.
struct TryItExperience: View {
    @Binding var language: WelcomeLanguage
    let model: TryItModel
    var usesSystemIsland = false
    var isCompletingSignIn = false
    var signInRetryAt: Date?
    let onBack: () -> Void
    let onNext: () -> Void

    private var copy: TryItCopy { TryItCopy.catalog[language.rawValue]! }
    private var status: String {
        if let failure = model.failure {
            switch failure {
            case .permission: return language.setupCopy.permissionError
            case .device: return language.setupCopy.deviceError
            case .capture: return language.setupCopy.captureError
            case .signIn: return copy.signInError
            case .connection: return copy.connectionError
            case .quota: return copy.quotaError
            case .rateLimit: return copy.rateLimitError
            case .empty: return copy.emptyError
            case .service: return copy.serviceError
            }
        }
        switch model.phase {
        case .restoring: return copy.restoringSession
        case .starting: return language.setupCopy.connecting
        case .needsSignIn: return copy.signInSubtitle
        case .signingIn: return isCompletingSignIn ? copy.completingSignIn : copy.signingIn
        case .recording: return copy.listening
        case .transcribing: return copy.transcribing
        case .ready: return model.successfulTrials > 0 ? copy.success : copy.ready
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            OnboardingNavigationBar(language: $language, backIdentifier: "try-it-back", onBack: onBack)
            GeometryReader { viewport in
                ScrollView {
                    Group {
                        if model.requiresSignIn {
                            signInContent.transition(.opacity)
                        } else {
                            TryItPractice(
                                language: language, text: Binding(get: { model.text }, set: { model.text = $0 }),
                                phase: model.phase, failureMessage: model.failure == nil ? nil : status,
                                successfulTrials: model.successfulTrials, fnPressed: model.shortcut.isPressed,
                                levels: usesSystemIsland ? [] : model.recorder.islandLevels,
                                usesSystemIsland: usesSystemIsland, onCancel: model.cancel, onNext: onNext)
                                .transition(.opacity)
                        }
                    }
                    .frame(maxWidth: 560)
                    .padding(.horizontal, 32).padding(.vertical, 24)
                    .frame(maxWidth: .infinity, minHeight: viewport.size.height)
                }
                .scrollIndicators(.hidden)
                .scrollBounceBehavior(.basedOnSize)
            }
            OnboardingFooter(language: language, backIdentifier: "try-it-back", onBack: onBack)
        }
        .background(SetupBackdrop())
    }

    private var signInContent: some View {
        VStack(spacing: 28) {
            Image("EchoLogo").resizable().scaledToFit().frame(width: 48, height: 48)
                .accessibilityHidden(true)
            VStack(spacing: 14) {
                Text(copy.signInTitle)
                    .font(WelcomeType.font(size: 32, weight: .semibold))
                    .tracking(language.usesLatin ? -0.9 : 0)
                    .accessibilityAddTraits(.isHeader)
                Text(copy.signInSubtitle)
                    .font(WelcomeType.font(size: 15))
                    .foregroundStyle(WelcomePalette.muted)
            }
            .multilineTextAlignment(.center)
            .fixedSize(horizontal: false, vertical: true)
            TimelineView(.periodic(from: .now, by: 1)) { context in
                let remaining = max(0, Int(ceil(signInRetryAt?.timeIntervalSince(context.date) ?? 0)))
                Button { model.signIn() } label: {
                    HStack(spacing: 12) {
                        Text(remaining > 0 ? copy.retryIn.replacingOccurrences(of: "{time}", with: "\(remaining / 60):\(String(format: "%02d", remaining % 60))") : copy.signInButton)
                        Image(systemName: "arrow.up.right")
                    }
                    .font(WelcomeType.font(size: 14, weight: .semibold))
                    .padding(.horizontal, 24).frame(minWidth: 240, minHeight: 46)
                    .contentShape(.rect)
                }
                .buttonStyle(WelcomePrimaryButton())
                .disabled(model.phase != .needsSignIn || remaining > 0)
                .keyboardShortcut(.defaultAction)
                .accessibilityIdentifier("onboarding-sign-in")
            }
            VStack(spacing: 12) {
                if model.phase == .signingIn || model.phase == .restoring || model.failure != nil {
                    HStack(spacing: 8) {
                        if model.failure == nil { ProgressView().controlSize(.small) }
                        Text(status)
                            .foregroundStyle(model.failure == nil ? WelcomePalette.muted : WelcomePalette.coral)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .accessibilityIdentifier("onboarding-sign-in-status")
                }
                if model.phase == .signingIn {
                    Button(copy.cancel) { model.cancel() }
                        .buttonStyle(.plain)
                        .foregroundStyle(WelcomePalette.muted)
                }
            }
            .font(WelcomeType.font(size: 12))
            .multilineTextAlignment(.center)
            .frame(minHeight: 50, alignment: .top)
        }
        .frame(maxWidth: 380)
        .accessibilityElement(children: .contain)
    }

}
