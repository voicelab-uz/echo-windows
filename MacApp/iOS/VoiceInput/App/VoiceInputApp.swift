import SwiftUI
import GoogleSignIn

@main
struct VoiceInputApp: App {
    @AppStorage("echo.onboarding.completed") private var onboardingCompleted = false
    @State private var showsLaunchCover = true

    var body: some Scene {
        WindowGroup {
            Group {
                if onboardingCompleted {
                    ContentView()
                } else {
                    OnboardingView()
                }
            }
            .accessibilityHidden(showsLaunchCover)
            .overlay {
                if showsLaunchCover {
                    EchoLaunchCover { showsLaunchCover = false }
                        .transition(.opacity)
                        .zIndex(1)
                }
            }
            .onOpenURL { url in
                // Keyboard handoffs and sign-in callbacks should proceed immediately.
                showsLaunchCover = false
                _ = GIDSignIn.sharedInstance.handle(url)
            }
        }
    }
}

/// A short, local launch animation; the real screen loads underneath it.
struct EchoLaunchCover: View {
    let onFinished: () -> Void
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var isVisible = false

    var body: some View {
        ZStack {
            EchoMobileTheme.canvas.ignoresSafeArea()
            Image("EchoLogo")
                .resizable().scaledToFit()
                .frame(width: 88, height: 88)
                .clipShape(RoundedRectangle(cornerRadius: 26, style: .continuous))
                .scaleEffect(reduceMotion ? 1 : (isVisible ? 1 : 0.88))
                .opacity(isVisible ? 1 : 0)
                .accessibilityLabel("Echo")
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .ignoresSafeArea()
        .task {
            // Give the initial transparent logo a frame before starting its fade.
            if !reduceMotion {
                do { try await Task.sleep(for: .milliseconds(60)) }
                catch { return }
            }
            withAnimation(reduceMotion ? nil : .easeOut(duration: 0.75)) { isVisible = true }
            do { try await Task.sleep(for: .milliseconds(reduceMotion ? 200 : 1100)) }
            catch { return }
            withAnimation(reduceMotion ? nil : .easeOut(duration: 0.25)) { onFinished() }
        }
    }
}
