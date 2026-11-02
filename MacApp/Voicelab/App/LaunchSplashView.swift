import SwiftUI

/// A finite brand reveal; authentication continues independently in AppModel.
struct LaunchSplashView: View {
    var onIntroFinished: () -> Void = {}
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var iconRevealed = false
    @State private var wordmarkRevealed = false

    var body: some View {
        VStack(spacing: 22) {
            AppBrandIcon()
                .frame(width: 104, height: 104)
                .scaleEffect(iconRevealed || reduceMotion ? 1 : 0.96)
                .offset(y: iconRevealed || reduceMotion ? 0 : 8)
                .blur(radius: iconRevealed || reduceMotion ? 0 : 2)
                .opacity(iconRevealed ? 1 : 0)

            Text("Echo")
                .font(.system(size: 25, weight: .semibold))
                .tracking(-0.7)
                .foregroundStyle(Design.accent)
                .offset(y: wordmarkRevealed || reduceMotion ? 0 : 4)
                .opacity(wordmarkRevealed ? 1 : 0)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Design.canvas)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(AppLocalization.text("Echo ochilmoqda"))
        .task(id: reduceMotion) { await reveal() }
    }

    @MainActor private func reveal() async {
        do {
            // Mount the initial pose before starting the single, non-bouncing motion.
            try await Task.sleep(for: .milliseconds(32))
            if reduceMotion {
                withAnimation(.easeOut(duration: 0.15)) {
                    iconRevealed = true
                    wordmarkRevealed = true
                }
                try await Task.sleep(for: .milliseconds(150))
            } else {
                withAnimation(.timingCurve(0.22, 1, 0.36, 1, duration: 0.85)) {
                    iconRevealed = true
                }
                try await Task.sleep(for: .milliseconds(180))
                withAnimation(.easeOut(duration: 0.6)) {
                    wordmarkRevealed = true
                }
                // Let the wordmark settle briefly before the screen crossfade.
                try await Task.sleep(for: .milliseconds(900))
            }
            try Task.checkCancellation()
            onIntroFinished()
        } catch {
            // Closing the window cancels presentation without advancing startup.
        }
    }
}

#Preview {
    LaunchSplashView().frame(width: 860, height: 600)
}
