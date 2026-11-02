import AppKit

/// Brief feedback for deliberate onboarding actions, never for looping artwork.
@MainActor
enum OnboardingHaptics {
    enum Event { case selection, confirmation, navigation }
    private static var lastFeedbackTime = -Double.infinity

    static func play(_ event: Event) {
        guard NSApp.isActive, NSApp.keyWindow != nil else { return }
        let now = ProcessInfo.processInfo.systemUptime
        guard now - lastFeedbackTime >= 0.15 else { return }
        lastFeedbackTime = now
        let pattern: NSHapticFeedbackManager.FeedbackPattern =
            event == .selection ? .alignment : .generic
        // Resolve each time so macOS can honor the current device and user preferences.
        NSHapticFeedbackManager.defaultPerformer.perform(pattern, performanceTime: .drawCompleted)
    }
}
