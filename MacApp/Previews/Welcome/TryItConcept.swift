import SwiftUI
import VoiceLabCore

enum OnboardingSessionStage: Int { case signIn = 3, aboutYou, practice }

struct TryItConcept: View {
    @Binding var language: WelcomeLanguage
    @Binding var trialStage: OnboardingSessionStage
    let deviceID: String
    let usesNewAlphabet: Bool
    let onBack: () -> Void
    @State private var model: TryItModel
    @State private var questionnaire: QuestionnaireModel
    @Environment(\.dismissWindow) private var dismissWindow

    init(language: Binding<WelcomeLanguage>, trialStage: Binding<OnboardingSessionStage>,
         deviceID: String, usesNewAlphabet: Bool, onBack: @escaping () -> Void) {
        _language = language; _trialStage = trialStage
        self.deviceID = deviceID; self.usesNewAlphabet = usesNewAlphabet; self.onBack = onBack
        let session = TryItSession()
        _model = State(initialValue: TryItModel(service: session))
        _questionnaire = State(initialValue: QuestionnaireModel(service: session))
    }
    private var stage: OnboardingSessionStage {
        model.requiresSignIn ? .signIn : questionnaire.isFinished ? .practice : .aboutYou
    }

    var body: some View {
        VStack(spacing: 0) {
            if stage == .aboutYou {
                QuestionnaireConcept(language: $language, model: questionnaire) {
                    if questionnaire.index > 0 { questionnaire.back() }
                    else { model.cancel(); questionnaire.cancel(); onBack() }
                }
            } else {
                TryItExperience(language: $language, model: model, onBack: {
                    if stage == .practice { model.cancel(); questionnaire.review() }
                    else { model.cancel(); questionnaire.cancel(); onBack() }
                }, onNext: finishOnboarding)
            }
        }
        .background(SetupBackdrop())
        .background {
            if stage == .practice {
                OnboardingFnInput { keyCode, pressed, focused in
                    model.receive(keyCode: keyCode, functionDown: pressed, isFocused: focused,
                                  deviceID: deviceID, usesNewAlphabet: usesNewAlphabet)
                }
                .frame(width: 0, height: 0)
            }
        }
        .task { model.restore() }
        .animation(.easeOut(duration: 0.2), value: stage)
        .onChange(of: stage, initial: true) { _, value in trialStage = value }
        .onChange(of: model.requiresSignIn, initial: true) { _, needsSignIn in
            if needsSignIn { questionnaire.reset() } else { questionnaire.load() }
        }
        .onChange(of: questionnaire.failure) { _, failure in
            if failure == .authentication { model.sessionExpired() }
        }
        .onChange(of: model.phase) { previous, current in
            if previous == .signingIn && current == .ready { OnboardingHaptics.play(.confirmation) }
        }
        .onDisappear { model.cancel(); questionnaire.cancel() }
        .onChange(of: model.successfulTrials) { _, _ in
            OnboardingHaptics.play(.confirmation)
        }
        .onChange(of: questionnaire.isFinished) { previous, current in
            if !previous && current { OnboardingHaptics.play(.navigation) }
        }
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.willCloseNotification)) { notification in
            if let window = notification.object as? NSWindow, window.canBecomeMain {
                model.cancel(); questionnaire.cancel()
            }
        }
        .onExitCommand { if model.canCancel { model.cancel() } }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("try-it-preview")
    }

    private func finishOnboarding() {
        guard questionnaire.isFinished, model.canContinue else { return }
        OnboardingHaptics.play(.navigation)
        model.cancel()
        dismissWindow(id: "welcome")
    }
}
