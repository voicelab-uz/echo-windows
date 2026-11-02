import SwiftUI

/// One artwork travels between measured endpoints. Only presentation sleeps;
/// completion is already durable and cloud synchronization remains independent.
struct OnboardingCompletionView: View {
    let source: CGRect?
    let destination: CGRect?
    let canvasSize: CGSize
    let onRevealHome: () -> Void
    let onFinished: () -> Void
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var latestSource: CGRect?
    @State private var latestDestination: CGRect?
    @State private var logoFrame = CGRect.zero
    @State private var logoVisible = false
    @State private var backdropVisible = false
    @State private var captionVisible = false
    @State private var sparksVisible = false
    @State private var burst = false
    @State private var landing = false

    private var centerFrame: CGRect {
        CGRect(x: canvasSize.width / 2 - 52, y: canvasSize.height / 2 - 92, width: 104, height: 104)
    }

    var body: some View {
        ZStack(alignment: .topLeading) {
            OnboardingTheme.canvas.opacity(backdropVisible ? 1 : 0)
            if !reduceMotion { sparks }
            VStack(spacing: 12) {
                Text(AppLocalization.text("Hammasi tayyor."))
                    .font(.system(size: 34, weight: .semibold)).tracking(-0.8)
                    .accessibilityAddTraits(.isHeader)
                Text(AppLocalization.text("Fikr sizdan. So‘zlar Echo’dan."))
                    .font(.system(size: 16)).foregroundStyle(OnboardingTheme.muted)
            }
            .foregroundStyle(OnboardingTheme.ink)
            .multilineTextAlignment(.center)
            .frame(width: min(560, canvasSize.width - 48))
            .position(x: centerFrame.midX, y: centerFrame.maxY + 76)
            .opacity(captionVisible ? 1 : 0)
            AppBrandIcon()
                .frame(width: logoFrame.width, height: logoFrame.height)
                .position(x: logoFrame.midX, y: logoFrame.midY)
                .opacity(logoVisible ? 1 : 0)
                .accessibilityHidden(true)
        }
        .frame(width: canvasSize.width, height: canvasSize.height)
        .contentShape(Rectangle())
        .clipped()
        .onChange(of: source, initial: true) { _, value in
            if let value { latestSource = value }
        }
        .onChange(of: destination, initial: true) { _, value in
            latestDestination = value
            if landing, let value {
                withAnimation(.smooth(duration: 0.3)) { logoFrame = value }
            }
        }
        .onChange(of: canvasSize) { _, _ in
            if logoVisible && !landing {
                withAnimation(.smooth(duration: 0.25)) { logoFrame = centerFrame }
            }
        }
        .task { await play() }
    }

    @MainActor private func play() async {
        do {
            // Preferences resolve after layout; never guess either logo's coordinates.
            for _ in 0..<20 where latestSource == nil {
                try await Task.sleep(for: .milliseconds(16))
            }
            var initial = Transaction(animation: nil)
            initial.disablesAnimations = true
            withTransaction(initial) {
                logoFrame = reduceMotion ? centerFrame : latestSource ?? centerFrame
                logoVisible = true
            }
            try await Task.sleep(for: .milliseconds(32))
            withAnimation(reduceMotion ? .easeOut(duration: 0.2) : .spring(duration: 1.1, bounce: 0.08)) {
                logoFrame = centerFrame
                backdropVisible = true
            }
            try await Task.sleep(for: .milliseconds(reduceMotion ? 200 : 1050))
            withAnimation(.easeOut(duration: reduceMotion ? 0.2 : 0.55)) { captionVisible = true }
            if !reduceMotion {
                sparksVisible = true
                try await Task.sleep(for: .milliseconds(16))
                withAnimation(.easeOut(duration: 1.7)) { burst = true }
            }
            try await Task.sleep(for: .milliseconds(reduceMotion ? 1000 : 2100))
            onRevealHome()
            // Home lays out beneath this overlay before the destination is used.
            for _ in 0..<60 where latestDestination == nil {
                try await Task.sleep(for: .milliseconds(16))
            }
            landing = true
            withAnimation(reduceMotion ? .easeOut(duration: 0.2) : .easeInOut(duration: 1.15)) {
                backdropVisible = false
                captionVisible = false
                if let latestDestination, !reduceMotion {
                    logoFrame = latestDestination
                } else {
                    logoVisible = false
                }
            }
            try await Task.sleep(for: .milliseconds(reduceMotion ? 220 : 1200))
            try Task.checkCancellation()
            onFinished()
        } catch { /* Window teardown cancels only this finite presentation. */  }
    }

    private var sparks: some View {
        ZStack {
            ForEach(0..<2) { index in
                Circle()
                    .strokeBorder(
                        LinearGradient(
                            colors: [OnboardingTheme.glow, .purple.opacity(0.5), .pink.opacity(0.3)],
                            startPoint: .topLeading, endPoint: .bottomTrailing), lineWidth: 1
                    )
                    .frame(width: CGFloat(150 + index * 42), height: CGFloat(150 + index * 42))
                    .scaleEffect(burst ? 1.8 : 0.7)
                    .opacity(sparksVisible && !burst ? 0.45 : 0)
            }
            ForEach(0..<18) { index in
                let angle = Double(index) * .pi * 2 / 18
                let distance = burst ? CGFloat(140 + (index % 4) * 24) : 42
                Capsule()
                    .fill([OnboardingTheme.glow, Color.purple, Color.pink.opacity(0.7)][index % 3])
                    .frame(width: index.isMultiple(of: 3) ? 5 : 3, height: index.isMultiple(of: 2) ? 12 : 5)
                    .rotationEffect(.radians(angle + (burst ? 1 : 0)))
                    .offset(x: cos(angle) * distance, y: sin(angle) * distance + (burst ? 24 : 0))
                    .opacity(sparksVisible && !burst ? 0.85 : 0)
            }
        }
        .position(x: centerFrame.midX, y: centerFrame.midY)
        .accessibilityHidden(true)
    }
}
