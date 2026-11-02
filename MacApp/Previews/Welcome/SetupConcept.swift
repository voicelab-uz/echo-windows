import SwiftUI

struct SetupConcept: View {
    @Binding var language: WelcomeLanguage
    @Binding var showingTryIt: Bool
    @Binding var trialStage: OnboardingSessionStage
    let onBack: () -> Void
    @State private var step = SetupExperience.Step.microphone
    @State private var deviceID = ""
    @State private var usesNewAlphabet = false
    var body: some View {
        if showingTryIt {
            TryItConcept(language: $language, trialStage: $trialStage, deviceID: deviceID,
                         usesNewAlphabet: usesNewAlphabet) { showingTryIt = false }
        } else {
            SetupExperience(language: $language, onBack: onBack, step: $step,
                            usesNewAlphabet: $usesNewAlphabet, deviceID: $deviceID) {
                showingTryIt = true
            }
        }
    }
}
