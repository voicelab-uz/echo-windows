import SwiftUI
import VoiceLabCore

/// Local questionnaire answers for design review; authentication and speech are real.
struct QuestionnaireReview: View {
    @State private var language = WelcomeLanguage.english
    @State private var questionnaire = QuestionnaireModel(service: DesignContextService())
    @State private var trial = TryItModel(service: TryItSession())
    @Environment(\.dismissWindow) private var dismissWindow

    private var stage: Int {
        questionnaire.isFinished ? (trial.requiresSignIn ? 3 : 5) : 4
    }

    var body: some View {
        VStack(spacing: 0) {
            WelcomeProgress(stages: language.copy.stages, activeIndex: stage)
            if questionnaire.isFinished {
                TryItExperience(language: $language, model: trial, onBack: {
                    trial.cancel()
                    questionnaire.review()
                }, onNext: {
                    guard trial.canContinue else { return }
                    trial.cancel()
                    dismissWindow(id: "welcome")
                })
            } else {
                QuestionnaireConcept(language: $language, model: questionnaire, onBack: questionnaire.back)
            }
        }
        .frame(minWidth: 860, minHeight: 640)
        .foregroundStyle(WelcomePalette.ink)
        .preferredColorScheme(.light)
        .environment(\.layoutDirection, language.isRightToLeft ? .rightToLeft : .leftToRight)
        .background {
            if questionnaire.isFinished && !trial.requiresSignIn {
                OnboardingFnInput { keyCode, pressed, focused in
                    trial.receive(keyCode: keyCode, functionDown: pressed, isFocused: focused,
                                  deviceID: "", usesNewAlphabet: false)
                }
                .frame(width: 0, height: 0)
            }
        }
        .task { questionnaire.load() }
        .onChange(of: questionnaire.isFinished) { _, finished in
            if finished { trial.restore() }
        }
        .onChange(of: trial.successfulTrials) { _, _ in OnboardingHaptics.play(.confirmation) }
        .onExitCommand { if trial.canCancel { trial.cancel() } }
        .onDisappear { trial.cancel(); questionnaire.cancel() }
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.willCloseNotification)) { notification in
            if let window = notification.object as? NSWindow, window.canBecomeMain {
                trial.cancel(); questionnaire.cancel()
            }
        }
    }
}

@MainActor private final class DesignContextService: OnboardingContextServing {
    private var profile: OnboardingContext?

    func onboardingContext() async throws -> OnboardingContext? { profile }

    func saveOnboardingContext(_ value: ContextSubmission) async throws -> OnboardingContext {
        try Task.checkCancellation()
        let encoder = JSONEncoder()
        encoder.keyEncodingStrategy = .convertToSnakeCase
        var object = try JSONSerialization.jsonObject(with: encoder.encode(value)) as! [String: Any]
        object["user_id"] = "design-only"
        object["revision"] = value.expectedRevision + 1
        let now = ISO8601DateFormatter().string(from: Date())
        object["created_at"] = profile?.createdAt ?? now
        object["updated_at"] = now
        if value.completed { object["completed_at"] = now }
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        let saved = try decoder.decode(OnboardingContext.self, from: JSONSerialization.data(withJSONObject: object))
        profile = saved
        return saved
    }
}
