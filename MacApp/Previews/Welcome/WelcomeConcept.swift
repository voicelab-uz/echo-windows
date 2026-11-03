import SwiftUI
import AppKit
import CoreText

// Standalone onboarding concept. Setup meters locally; Try it uses VoiceLab transcription.
@main
struct WelcomeConceptApp: App {
    init() { WelcomeType.registerBundledFonts() }
    var body: some Scene {
        Window("Echo — Welcome concept", id: "welcome") {
            WelcomeConcept()
        }
        .windowStyle(.hiddenTitleBar)
        .windowResizability(.contentMinSize)
        .defaultSize(width: 1080, height: 700)
    }
}

private struct WelcomeConcept: View {
    private enum Screen: Int { case welcome, permissions, setup }
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @AppStorage("welcome.preview.language") private var language = WelcomeLanguage.uzbek
    @State private var appeared = false
    @State private var screen = Screen.welcome
    @State private var showingTryIt = false
    @State private var trialStage = OnboardingSessionStage.signIn
    @State private var allowed: Set<PermissionKind> = []

    private var copy: WelcomeCopy { language.copy }

    var body: some View {
        VStack(spacing: 0) {
            WelcomeProgress(stages: copy.stages, activeIndex: showingTryIt ? trialStage.rawValue : screen.rawValue)
            switch screen {
            case .permissions:
                PermissionsConcept(language: $language, allowed: $allowed,
                    onBack: { allowed = []; navigate(to: .welcome) },
                    onContinue: { navigate(to: .setup) }, onRequest: { allowed.insert($0) })
                    .transition(.opacity)
            case .setup:
                SetupConcept(language: $language, showingTryIt: $showingTryIt, trialStage: $trialStage,
                    onBack: { navigate(to: .permissions) })
                    .transition(.opacity)
            case .welcome:
                welcomeContent.transition(.opacity)
            }
        }
        .frame(minWidth: 860, minHeight: 640)
        .environment(\.layoutDirection, language.isRightToLeft ? .rightToLeft : .leftToRight)
        .background(Color.white)
        .foregroundStyle(WelcomePalette.ink)
        .preferredColorScheme(.light)
        .task {
            withAnimation(reduceMotion ? .easeOut(duration: 0.15) : .easeOut(duration: 0.45)) {
                appeared = true
            }
        }
    }

    private func navigate(to destination: Screen) {
        if destination.rawValue > screen.rawValue { OnboardingHaptics.play(.navigation) }
        withAnimation(.easeInOut(duration: reduceMotion ? 0.15 : 0.25)) {
            screen = destination
        }
    }

    private var welcomeContent: some View {
        WelcomeLanding(language: $language) { navigate(to: .permissions) }
    }
}
