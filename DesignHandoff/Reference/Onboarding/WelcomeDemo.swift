import SwiftUI

private enum DemoPhase { case ready, listening, processing, complete }

struct WelcomeDemo: View {
    let language: WelcomeLanguage
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var phase = DemoPhase.ready
    @State private var islandExpanded = false
    @State private var simulatedKeyDown = false
    @State private var appeared = false
    @State private var recordingStartedAt: Date?
    @State private var recordedDuration: TimeInterval = 0

    private var copy: WelcomeCopy { language.copy }
    private var currentStep: Int {
        switch phase {
        case .ready: 0
        case .listening: 1
        case .processing, .complete: 2
        }
    }
    private var caption: String {
        switch phase {
        case .ready: copy.captions[0]
        case .listening: copy.captions[1]
        case .processing: copy.captions[2]
        case .complete: copy.captions[3]
        }
    }

    var body: some View {
        GeometryReader { geometry in
            let scale = min((geometry.size.width - 44) / 640, 1)
            VStack(spacing: 0) {
                Spacer(minLength: 40)
                VStack(spacing: 28) {
                    MacBookFrame {
                        desktop
                    }
                    .frame(width: 640, height: 400)
                    .scaleEffect(scale)
                    .frame(width: 640 * scale, height: 400 * scale)

                    HStack(spacing: 16) {
                        FnKeycap(pressed: simulatedKeyDown)
                            .accessibilityHidden(true)
                        Text(caption)
                            .font(WelcomeType.font(size: 13, weight: .medium))
                            .multilineTextAlignment(.leading)
                            .frame(maxWidth: 260, minHeight: 44, alignment: .leading)
                            .contentTransition(.opacity)
                    }
                    .padding(.horizontal, 28)
                }
                .opacity(appeared ? 1 : 0)
                .offset(y: appeared || reduceMotion ? 0 : 10)
                Spacer(minLength: 20)
                HStack(spacing: 12) {
                    ForEach(0..<3) { index in
                        if index > 0 {
                            Image(systemName: "chevron.forward")
                                .font(WelcomeType.font(size: 9))
                                .foregroundStyle(WelcomePalette.muted.opacity(0.5))
                                .accessibilityHidden(true)
                        }
                        demoStep(index)
                    }
                }
                .padding(.horizontal, 24).padding(.bottom, 32)
            }
            .frame(width: geometry.size.width, height: geometry.size.height)
        }
        .background {
            LinearGradient(colors: [WelcomePalette.lavender, WelcomePalette.warm], startPoint: .topLeading, endPoint: .bottomTrailing)
            RadialGradient(colors: [WelcomePalette.lavender.opacity(0.5), .clear], center: .init(x: 0.3, y: 0.3), startRadius: 0, endRadius: 350)
            RadialGradient(colors: [WelcomePalette.warm.opacity(0.4), .clear], center: .bottomTrailing, startRadius: 0, endRadius: 350)
        }
        .clipped()
        .onAppear {
            withAnimation(reduceMotion ? .easeOut(duration: 0.15) : .easeOut(duration: 0.45).delay(0.1)) {
                appeared = true
            }
        }
        // A single cancellable task repeats the demonstration while visible.
        .task(id: reduceMotion) { await play() }
    }

    private var desktop: some View {
        ZStack(alignment: .top) {
            VStack(spacing: 0) {
                desktopMenuBar
                Spacer(minLength: 54)
                message.frame(width: 380, height: 250)
                Spacer(minLength: 22)
            }
            recordingIsland
            // Keep the camera fixed while the same silhouette unfolds around it.
            UnevenRoundedRectangle(bottomLeadingRadius: 9, bottomTrailingRadius: 9)
                .fill(.black)
                .frame(width: 108, height: 19)
                .overlay(alignment: .trailing) {
                    Circle().fill(Color(red: 0.12, green: 0.16, blue: 0.19))
                        .frame(width: 4, height: 4).padding(.trailing, 13)
                }
                .accessibilityHidden(true)
        }
        .background {
            LinearGradient(colors: [Color(red: 0.78, green: 0.79, blue: 0.90), Color(red: 0.91, green: 0.88, blue: 0.91), Color(red: 0.94, green: 0.86, blue: 0.80)], startPoint: .topLeading, endPoint: .bottomTrailing)
            Ellipse().fill(.white.opacity(0.22))
                .frame(width: 640, height: 280).rotationEffect(.degrees(-28)).offset(x: -180, y: 220)
        }
        .clipped()
    }

    private var desktopMenuBar: some View {
        HStack(spacing: 10) {
            Image(systemName: "apple.logo").font(WelcomeType.font(size: 11))
            Text("Echo").font(WelcomeType.font(size: 10, weight: .semibold))
            Spacer()
            Image(systemName: "wifi")
            Image(systemName: "battery.100percent")
            TimelineView(.everyMinute) { context in
                Text(context.date, format: .dateTime.hour(.twoDigits(amPM: .omitted)).minute(.twoDigits))
                    .font(WelcomeType.font(size: 10, weight: .medium))
                    .monospacedDigit()
            }
        }
        .font(WelcomeType.font(size: 10))
        .foregroundStyle(WelcomePalette.ink.opacity(0.75))
        .padding(.horizontal, 14).frame(height: 24)
        .background(WelcomePalette.canvas.opacity(0.24))
        .environment(\.layoutDirection, .leftToRight)
        .accessibilityHidden(true)
    }

    private var message: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 9) {
                Image(systemName: "bubble.left").foregroundStyle(WelcomePalette.muted)
                Text(copy.messageTitle)
                Spacer()
                Image(systemName: "ellipsis").foregroundStyle(WelcomePalette.muted.opacity(0.5))
                    .accessibilityHidden(true)
            }
            .font(WelcomeType.font(size: 12, weight: .medium))
            .padding(.horizontal, 22).frame(height: 43)
            Divider().opacity(0.6)
            HStack(spacing: 9) {
                Text(String(copy.recipient.prefix(1)))
                    .frame(width: 26, height: 26)
                    .background(WelcomePalette.lavender, in: Circle())
                Text(copy.recipient)
            }
            .font(WelcomeType.font(size: 12, weight: .medium))
            .padding(.horizontal, 22).padding(.top, 16)
            ZStack(alignment: .topLeading) {
                Text(copy.sentence)
                    .font(WelcomeType.font(size: 18)).lineSpacing(6)
                    .fixedSize(horizontal: false, vertical: true)
                    .opacity(phase == .complete ? 1 : 0)
                    .offset(y: phase == .complete || reduceMotion ? 0 : 4)
                    .accessibilityHidden(phase != .complete)
                if phase != .complete {
                    HStack(spacing: 6) {
                        RoundedRectangle(cornerRadius: 1).fill(WelcomePalette.ink.opacity(0.7))
                            .frame(width: 1.5, height: 21)
                        Text(copy.placeholder)
                            .font(WelcomeType.font(size: 17)).foregroundStyle(WelcomePalette.muted.opacity(0.5))
                            .lineLimit(1).minimumScaleFactor(0.8)
                    }
                }
            }
            .padding(.horizontal, 22).padding(.top, 16)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .padding(.bottom, 20)
        }
        .background(WelcomePalette.canvas, in: .rect(cornerRadius: 14))
        .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(.black.opacity(0.07)))
        .shadow(color: .black.opacity(0.09), radius: 18, y: 9)
        .accessibilityElement(children: .combine)
    }

    private var recordingIsland: some View {
        let shape = CameraIslandShape(
            cameraWidth: 108, cameraHeight: 19,
            shoulder: islandExpanded ? 10 : 0,
            bottomRadius: islandExpanded ? 24 : 9)
        return ZStack(alignment: .top) {
            shape.fill(.black)
                .overlay {
                    LinearGradient(colors: [.clear, .white.opacity(0.035)], startPoint: .top, endPoint: .bottom)
                        .clipShape(shape)
                }
            recordingContent
                .frame(width: 260, height: 46)
                .padding(.top, 19)
                .opacity(islandExpanded ? 1 : 0)
                .animation(.easeOut(duration: islandExpanded ? 0.24 : 0.12)
                    .delay(islandExpanded && !reduceMotion ? 0.08 : 0), value: islandExpanded)
        }
        .frame(width: islandExpanded ? 260 : 108, height: islandExpanded ? 65 : 19, alignment: .top)
        .clipShape(shape)
        .shadow(color: .black.opacity(islandExpanded ? 0.18 : 0), radius: 10, y: 5)
        .animation(reduceMotion ? nil : .smooth(duration: islandExpanded ? 0.52 : 0.44), value: islandExpanded)
        .foregroundStyle(.white)
        .allowsHitTesting(false)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(caption)
        .accessibilityHidden(!islandExpanded)
    }

    private var recordingContent: some View {
        HStack(spacing: 10) {
            HStack(spacing: 7) {
                Circle()
                    .fill(phase == .listening ? Color(red: 1, green: 0.48, blue: 0.42) : .white.opacity(0.4))
                    .frame(width: 4, height: 4)
                TimelineView(.animation(minimumInterval: 1, paused: phase != .listening)) { context in
                    let elapsed = phase == .listening
                        ? max(0, context.date.timeIntervalSince(recordingStartedAt ?? context.date))
                        : recordedDuration
                    Text(Duration.seconds(elapsed).formatted(.time(pattern: .minuteSecond(padMinuteToLength: 2))))
                        .font(.system(size: 12, weight: .medium, design: .rounded))
                        .monospacedDigit()
                        .foregroundStyle(.white.opacity(0.8))
                }
            }
            .frame(width: 62, alignment: .leading)

            DemoWaveform(phase: phase, startedAt: recordingStartedAt)
                .frame(maxWidth: .infinity)

            // Illustrative controls only: the demo never captures audio or focus.
            HStack(spacing: 6) {
                Image(systemName: "stop.fill")
                    .font(.system(size: 10, weight: .semibold))
                    .frame(width: 28, height: 28)
                    .background(.white.opacity(0.12), in: Circle())
                    .opacity(phase == .listening ? 1 : 0)
                Image(systemName: "xmark")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(.white.opacity(0.6))
                    .frame(width: 24, height: 28)
            }
            .frame(width: 62, alignment: .trailing)
        }
        .padding(.horizontal, 22)
        .environment(\.layoutDirection, .leftToRight)
    }

    private func demoStep(_ index: Int) -> some View {
        HStack(spacing: 6) {
            Text("\(index + 1)").font(WelcomeType.font(size: 10, weight: .medium))
                .frame(width: 18, height: 18)
                .background(currentStep == index ? WelcomePalette.ink.opacity(0.08) : .clear, in: Circle())
            Text(copy.demoSteps[index])
                .font(WelcomeType.font(size: 12, weight: currentStep == index ? .semibold : .regular))
                .fixedSize(horizontal: false, vertical: true)
        }
        .foregroundStyle(currentStep == index ? WelcomePalette.ink : WelcomePalette.muted)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(currentStep == index ? .isSelected : [])
    }

    private func setPhase(_ next: DemoPhase) {
        if next == .ready {
            recordingStartedAt = nil
            recordedDuration = 0
        } else if next == .listening {
            recordingStartedAt = .now
        } else if next == .processing, let recordingStartedAt {
            recordedDuration = max(0, Date.now.timeIntervalSince(recordingStartedAt))
        }
        withAnimation(.easeOut(duration: reduceMotion ? 0.15 : 0.24)) { phase = next }
    }

    private func finishMessage() async throws {
        try await Task.sleep(for: .seconds(0.65))
        try Task.checkCancellation()
        setPhase(.complete)
        islandExpanded = false
        try await Task.sleep(for: .seconds(1.2))
        try Task.checkCancellation()
    }

    private func play() async {
        defer { simulatedKeyDown = false }
        if reduceMotion {
            phase = .complete
            islandExpanded = false
            return
        }
        do {
            while !Task.isCancelled {
                setPhase(.ready)
                islandExpanded = false
                try await Task.sleep(for: .seconds(1.5))
                simulatedKeyDown = true
                try await Task.sleep(for: .seconds(0.16))
                setPhase(.listening)
                islandExpanded = true
                simulatedKeyDown = false
                try await Task.sleep(for: .seconds(2.8))
                simulatedKeyDown = true
                try await Task.sleep(for: .seconds(0.16))
                setPhase(.processing)
                simulatedKeyDown = false
                try await finishMessage()
                try await Task.sleep(for: .seconds(3.8))
            }
        } catch { /* SwiftUI cancels playback when the view disappears. */ }
    }
}

private struct MacBookFrame<Content: View>: View {
    @ViewBuilder let content: Content

    var body: some View {
        VStack(spacing: 0) {
            content
                .frame(width: 580, height: 362)
                .clipShape(.rect(cornerRadius: 10))
                .padding(9)
                .background(Color(red: 0.055, green: 0.055, blue: 0.065), in: .rect(cornerRadius: 19))
                .overlay(RoundedRectangle(cornerRadius: 19).strokeBorder(
                    LinearGradient(colors: [.white.opacity(0.5), .black.opacity(0.8)], startPoint: .topLeading, endPoint: .bottomTrailing), lineWidth: 1.5))
                .overlay(RoundedRectangle(cornerRadius: 20).strokeBorder(.black.opacity(0.25), lineWidth: 1).padding(-1))
            UnevenRoundedRectangle(bottomLeadingRadius: 14, bottomTrailingRadius: 14)
                .fill(LinearGradient(colors: [Color(white: 0.82), Color(white: 0.66), Color(white: 0.49)], startPoint: .top, endPoint: .bottom))
                .frame(width: 640, height: 13)
                .overlay(alignment: .top) {
                    UnevenRoundedRectangle(bottomLeadingRadius: 5, bottomTrailingRadius: 5)
                        .fill(Color(white: 0.45)).frame(width: 92, height: 5)
                }
                .overlay(alignment: .top) { Rectangle().fill(.white.opacity(0.7)).frame(height: 1) }
                .accessibilityHidden(true)
        }
        .shadow(color: Color(red: 0.24, green: 0.21, blue: 0.32).opacity(0.16), radius: 20, y: 18)
    }
}

private struct FnKeycap: View {
    let pressed: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.onboardingShortcutLabel) private var shortcut

    var body: some View {
        Text(shortcut)
            .font(WelcomeType.font(size: 19, weight: .medium))
            .lineLimit(1).minimumScaleFactor(0.5)
            .padding(.horizontal, 8)
            .frame(minWidth: 58).frame(height: 50)
            .foregroundStyle(WelcomePalette.ink)
            .background(WelcomePalette.canvas.opacity(0.85), in: .rect(cornerRadius: 11))
            .overlay(RoundedRectangle(cornerRadius: 11).strokeBorder(WelcomePalette.ink.opacity(0.14)))
            .shadow(color: .black.opacity(0.13), radius: 0, y: pressed ? 1 : 4)
            .offset(y: pressed && !reduceMotion ? 2 : 0)
            .scaleEffect(pressed && !reduceMotion ? 0.97 : 1)
            .animation(.easeOut(duration: 0.14), value: pressed)
    }
}

/// Simulated speech for the illustration, using the live island's seven-bar silhouette.
private struct DemoWaveform: View {
    let phase: DemoPhase
    let startedAt: Date?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    private let contour = [0.32, 0.58, 0.84, 1.0, 0.84, 0.58, 0.32]
    private let coral = Color(red: 1, green: 0.48, blue: 0.42)

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30,
                                paused: reduceMotion || phase == .ready || phase == .complete)) { context in
            let time = max(0, context.date.timeIntervalSince(startedAt ?? context.date))
            // Allow the island to unfold before the simulated speaker starts.
            let onset = min(1, max(0, (time - 0.35) * 4))
            let energy = reduceMotion ? 0.5 : onset * (0.5 + 0.5 * sin(time * 4.2))
            ZStack {
                Capsule().fill(coral.opacity(0.65))
                    .frame(width: 30, height: 2)
                    .opacity(phase == .listening ? 1 - onset : 0)
                HStack(spacing: 3) {
                    ForEach(contour.indices, id: \.self) { index in
                        let pulse = reduceMotion ? 0.5 : 0.5 + 0.5 * sin(time * 3 - Double(index) * 0.45)
                        Capsule()
                            .fill(LinearGradient(
                                colors: phase == .listening
                                    ? [Color(red: 1, green: 0.74, blue: 0.65), coral]
                                    : [.white.opacity(0.45 + pulse * 0.4)],
                                startPoint: .top, endPoint: .bottom))
                            .frame(width: 3, height: 2 + contour[index] *
                                   (phase == .listening ? energy * 21 : 3 + pulse * 5))
                    }
                }
                .opacity(phase == .listening ? onset : 1)
            }
            .frame(width: 42, height: 25)
        }
        .accessibilityHidden(true)
    }
}
