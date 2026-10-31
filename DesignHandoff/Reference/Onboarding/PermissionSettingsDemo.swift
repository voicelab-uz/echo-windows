import SwiftUI

/// A macOS Settings walkthrough only. Every control and pointer inside the window is drawn,
/// so playback never opens System Settings or changes a macOS permission.
struct PermissionSettingsDemo: View {
    let language: WelcomeLanguage
    let focus: PermissionKind
    let isGranted: Bool
    var microphoneNeedsSettings = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var visible = false
    @State private var promptVisible = false
    @State private var enabled = false
    @State private var pointerVisible = false
    @State private var pointerAtTarget = false
    @State private var pointerPressed = false
    @State private var ripple = false

    private var copy: PermissionsCopy { language.permissionsCopy }
    private var settings: PermissionSettingsCopy { copy.settings }
    private var instruction: String {
        if isGranted { return copy.allowed }
        if focus == .microphone && microphoneNeedsSettings { return copy.settingsUnavailable }
        return focus == .microphone ? copy.microphoneInstruction : copy.accessibilityInstruction
    }
    private var accent: Color { Color(red: 0.04, green: 0.48, blue: 0.98) }
    private var systemPermissionTitle: String {
        if focus == .microphone { return copy.microphone }
        return ProcessInfo.processInfo.operatingSystemVersion.majorVersion >= 27
            ? settings.controlAccess : copy.accessibility
    }
    private var systemPermissionDescription: String {
        if focus == .microphone {
            return settings.microphoneDescription
        }
        if ProcessInfo.processInfo.operatingSystemVersion.majorVersion >= 27 {
            return settings.controlAccessDescription
        }
        return settings.accessibilityDescription
    }

    var body: some View {
        GeometryReader { geometry in
            let scale = min((geometry.size.width - 56) / 600, 1)
            VStack(spacing: 0) {
                Spacer(minLength: 32)
                VStack(spacing: 36) {
                    settingsWindow
                        .frame(width: 600, height: 412)
                        .scaleEffect(scale)
                        .frame(width: 600 * scale, height: 412 * scale)
                        .accessibilityElement(children: .ignore)
                        .accessibilityLabel("\(settings.systemSettings), \(settings.privacySecurity), \(systemPermissionTitle). \(instruction)")
                        .accessibilityValue(enabled ? copy.allowed : copy.allow)
                        .accessibilityIdentifier("permissions-settings-demo")
                    VStack(spacing: 9) {
                        Text(focus.title(in: copy))
                            .font(WelcomeType.font(size: 19, weight: .semibold))
                        Text(instruction)
                            .font(WelcomeType.font(size: 13))
                            .foregroundStyle(WelcomePalette.muted)
                            .lineSpacing(4)
                    }
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 320, minHeight: 80, alignment: .top)
                    .padding(.horizontal, 28)
                }
                .opacity(visible ? 1 : 0)
                .offset(y: visible || reduceMotion ? 0 : 6)
                Spacer(minLength: 24)
                HStack(spacing: 10) {
                    ForEach(PermissionKind.allCases, id: \.self) { kind in
                        Capsule()
                            .fill(kind == focus ? WelcomePalette.ink.opacity(0.65) : WelcomePalette.ink.opacity(0.14))
                            .frame(width: kind == focus ? 24 : 6, height: 6)
                    }
                }
                .accessibilityHidden(true)
                .padding(.bottom, 36)
            }
            .frame(width: geometry.size.width, height: geometry.size.height)
        }
        .background {
            LinearGradient(colors: [WelcomePalette.lavender, WelcomePalette.warm], startPoint: .topLeading, endPoint: .bottomTrailing)
            RadialGradient(colors: [WelcomePalette.lavender.opacity(0.5), .clear], center: .init(x: 0.3, y: 0.3), startRadius: 0, endRadius: 350)
            RadialGradient(colors: [WelcomePalette.warm.opacity(0.4), .clear], center: .bottomTrailing, startRadius: 0, endRadius: 350)
        }
        .clipped()
        .task(id: PlaybackState(isGranted: isGranted, reduceMotion: reduceMotion)) { await play() }
    }

    private var settingsWindow: some View {
        ZStack {
            HStack(spacing: 0) {
                settingsSidebar.frame(width: 188)
                Rectangle().fill(.black.opacity(0.08)).frame(width: 0.5)
                settingsPane
            }
            if promptVisible {
                Color.black.opacity(0.10).transition(.opacity)
                microphonePrompt
                    .transition(reduceMotion ? .opacity : .scale(scale: 0.96).combined(with: .opacity))
            }
        }
        .environment(\.layoutDirection, language.isRightToLeft ? .rightToLeft : .leftToRight)
        .background(WelcomePalette.surface, in: .rect(cornerRadius: 18))
        .clipShape(.rect(cornerRadius: 18))
        .overlay(RoundedRectangle(cornerRadius: 18).strokeBorder(.black.opacity(0.14)))
        .overlay(RoundedRectangle(cornerRadius: 17).strokeBorder(.white.opacity(0.7)).padding(1))
        .shadow(color: Color(red: 0.24, green: 0.21, blue: 0.32).opacity(0.17), radius: 24, y: 15)
        .allowsHitTesting(false)
    }

    private var settingsSidebar: some View {
        VStack(spacing: 0) {
            HStack(spacing: 7) {
                Circle().fill(Color(red: 1, green: 0.37, blue: 0.34))
                Circle().fill(Color(red: 1, green: 0.74, blue: 0.26))
                Circle().fill(Color(red: 0.22, green: 0.78, blue: 0.36))
            }
            .frame(width: 44, height: 10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 16).frame(height: 43)
            HStack(spacing: 5) {
                Image(systemName: "magnifyingglass")
                Text(settings.search)
                Spacer()
            }
            .font(.system(size: 12))
            .foregroundStyle(WelcomePalette.ink.opacity(0.4))
            .padding(.horizontal, 8).frame(height: 27)
            .background(.black.opacity(0.045), in: .capsule)
            .overlay(Capsule().strokeBorder(.black.opacity(0.06)))
            .padding(.horizontal, 10).padding(.bottom, 10)
            VStack(spacing: 2) {
                sidebarRow(settings.lockScreen, symbol: "lock.fill", color: .black)
                sidebarRow(settings.privacySecurity, symbol: "hand.raised.fill", color: .blue, selected: true)
                sidebarRow(settings.touchIDPassword, symbol: "touchid", color: .pink)
                sidebarRow(settings.usersGroups, symbol: "person.2.fill", color: .blue)
                Spacer().frame(height: 7)
                sidebarRow(settings.gameCenter, symbol: "gamecontroller.fill", color: .pink)
                sidebarRow("iCloud", symbol: "icloud.fill", color: .cyan)
                sidebarRow(settings.internetAccounts, symbol: "at", color: .blue)
                sidebarRow(settings.walletApplePay, symbol: "wallet.bifold.fill", color: .gray)
                Spacer().frame(height: 7)
                sidebarRow(settings.keyboard, symbol: "keyboard", color: .gray)
                sidebarRow(settings.trackpad, symbol: "rectangle", color: .gray)
            }
            .padding(.horizontal, 8)
            Spacer(minLength: 4)
        }
        .background {
            LinearGradient(colors: [WelcomePalette.surface, WelcomePalette.lavender], startPoint: .top, endPoint: .bottom)
        }
    }

    private func sidebarRow(_ title: String, symbol: String, color: Color, selected: Bool = false) -> some View {
        HStack(spacing: 7) {
            Image(systemName: symbol)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.white)
                .frame(width: 19, height: 19)
                .background(color.gradient, in: .rect(cornerRadius: 5))
                .overlay(RoundedRectangle(cornerRadius: 5).strokeBorder(.black.opacity(0.08)))
            Text(title).font(.system(size: 11, weight: selected ? .semibold : .regular))
                .lineLimit(2).minimumScaleFactor(0.85)
            Spacer(minLength: 0)
        }
        .foregroundStyle(selected ? .white : WelcomePalette.ink)
        .padding(.horizontal, 6).frame(height: 29)
        .background(selected ? accent : .clear, in: .rect(cornerRadius: 7))
    }

    private var settingsPane: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                HStack(spacing: 13) {
                    Image(systemName: "chevron.left")
                    Image(systemName: "chevron.right").opacity(0.25)
                }
                .font(.system(size: 13, weight: .medium))
                .padding(.horizontal, 11).frame(height: 29)
                .background(WelcomePalette.canvas.opacity(0.8), in: .capsule)
                .overlay(Capsule().strokeBorder(.black.opacity(0.07)))
                Text(systemPermissionTitle)
                    .font(.system(size: 14, weight: .semibold))
                    .lineLimit(2).minimumScaleFactor(0.85)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 15).frame(height: 52)
            VStack(spacing: 0) {
                Text(systemPermissionDescription)
                    .font(.system(size: 12))
                    .foregroundStyle(WelcomePalette.ink.opacity(0.6))
                    .lineSpacing(3)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(14)
                Rectangle().fill(.black.opacity(0.07)).frame(height: 0.5).padding(.horizontal, 14)
                HStack(spacing: 10) {
                    Image("EchoLogo").resizable().scaledToFit().frame(width: 27, height: 27)
                    Text("Echo").font(.system(size: 14))
                    Spacer()
                    simulatedSwitch.overlay {
                        if focus == .accessibility || microphoneNeedsSettings { pointer }
                    }
                }
                .padding(.horizontal, 14).frame(height: 57)
                if focus == .accessibility {
                    Rectangle().fill(.black.opacity(0.07)).frame(height: 0.5)
                    HStack(spacing: 17) {
                        Image(systemName: "plus")
                        Image(systemName: "minus").opacity(0.3)
                        Spacer()
                    }
                    .font(.system(size: 12))
                    .padding(.horizontal, 16).frame(height: 30)
                }
            }
            .background(WelcomePalette.canvas.opacity(0.8), in: .rect(cornerRadius: 10))
            .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(.black.opacity(0.06)))
            .padding(.horizontal, 16).padding(.top, 4)
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var simulatedSwitch: some View {
        Capsule().fill(enabled ? accent : Color(white: 0.78))
            .frame(width: 34, height: 20)
            .overlay(alignment: enabled ? .trailing : .leading) {
                Capsule().fill(.white).frame(width: 20, height: 16)
                    .shadow(color: .black.opacity(0.15), radius: 1, y: 1)
                    .padding(2)
            }
    }

    private var microphonePrompt: some View {
        VStack(spacing: 0) {
            Image("EchoLogo").resizable().scaledToFit().frame(width: 48, height: 48)
                .overlay(alignment: .bottomTrailing) {
                    Image(systemName: "mic.fill")
                        .font(.system(size: 10)).foregroundStyle(.white)
                        .frame(width: 19, height: 19)
                        .background(Color(white: 0.45), in: .circle)
                        .overlay(Circle().stroke(.white.opacity(0.8)))
                        .offset(x: 5, y: 4)
                }
                .padding(.bottom, 18)
            Text(settings.microphoneRequest)
                .font(.system(size: 13, weight: .semibold))
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
            Text(settings.microphoneReason)
                .font(.system(size: 11))
                .multilineTextAlignment(.center)
                .lineSpacing(2)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, 9)
            HStack(spacing: 8) {
                Text(settings.dontAllow)
                    .lineLimit(1).minimumScaleFactor(0.75)
                    .frame(maxWidth: .infinity).frame(height: 26)
                    .background(WelcomePalette.canvas, in: .capsule)
                    .overlay(Capsule().strokeBorder(.black.opacity(0.04)))
                Text(copy.allow)
                    .lineLimit(1).minimumScaleFactor(0.75)
                    .frame(maxWidth: .infinity).frame(height: 26)
                    .background(WelcomePalette.canvas, in: .capsule)
                    .overlay(Capsule().strokeBorder(.black.opacity(0.04)))
                    .scaleEffect(pointerPressed && !reduceMotion ? 0.97 : 1)
                    .overlay { pointer }
            }
            .font(.system(size: 11, weight: .medium))
            .padding(.top, 20)
        }
        .padding(20)
        .frame(width: 250)
        .background(WelcomePalette.surface, in: .rect(cornerRadius: 17))
        .overlay(RoundedRectangle(cornerRadius: 17).strokeBorder(.white.opacity(0.6)))
        .shadow(color: .black.opacity(0.23), radius: 20, y: 10)
    }

    private var pointer: some View {
        ZStack {
            Circle().stroke(accent.opacity(ripple ? 0 : 0.35), lineWidth: 2)
                .frame(width: 32, height: 32)
                .scaleEffect(ripple ? 1.8 : 0.7)
                .opacity(pointerVisible ? 1 : 0)
            PermissionDemoPointer()
                .fill(WelcomePalette.ink)
                .overlay(PermissionDemoPointer().stroke(.white, lineWidth: 1.5))
                .frame(width: 20, height: 28)
                .shadow(color: .black.opacity(0.18), radius: 2, y: 2)
                .scaleEffect(pointerPressed ? 0.88 : 1, anchor: .topLeading)
                // The tip arrives at the centre of the demonstrated control.
                .offset(x: pointerAtTarget ? 10 : 68, y: pointerAtTarget ? 14 : 64)
                .opacity(pointerVisible ? 1 : 0)
        }
        .accessibilityHidden(true)
    }

    @MainActor private func play() async {
        if isGranted {
            withAnimation(reduceMotion ? nil : .easeOut(duration: 0.2)) {
                visible = true
                enabled = true
                promptVisible = false
                pointerVisible = false
                pointerPressed = false
            }
            return
        }
        do {
            while !Task.isCancelled {
                withAnimation(.easeOut(duration: 0.2)) { visible = false }
                try await pause(0.22)
                enabled = false
                promptVisible = false
                pointerVisible = false
                pointerAtTarget = false
                pointerPressed = false
                ripple = false
                withAnimation(.easeOut(duration: reduceMotion ? 0.2 : 0.4)) { visible = true }
                try await pause(1)
                if focus == .microphone && !microphoneNeedsSettings {
                    withAnimation(.easeOut(duration: 0.25)) { promptVisible = true }
                }
                try await pause(1.4)
                if !reduceMotion {
                    withAnimation(.easeOut(duration: 0.2)) { pointerVisible = true }
                    withAnimation(.smooth(duration: 0.8)) { pointerAtTarget = true }
                    try await pause(0.9)
                    withAnimation(.easeOut(duration: 0.12)) { pointerPressed = true }
                    try await pause(0.15)
                }
                withAnimation(reduceMotion ? nil : .smooth(duration: 0.28)) {
                    enabled = true
                    pointerPressed = false
                }
                withAnimation(.easeOut(duration: 0.45)) { ripple = true }
                try await pause(0.35)
                withAnimation(.easeOut(duration: 0.25)) {
                    pointerVisible = false
                    promptVisible = false
                }
                try await pause(2.6)
            }
        } catch { /* SwiftUI cancels playback when this screen disappears. */ }
    }

    private struct PlaybackState: Hashable {
        let isGranted: Bool
        let reduceMotion: Bool
    }

    private func pause(_ seconds: Double) async throws {
        try await Task.sleep(for: .seconds(seconds))
        try Task.checkCancellation()
    }
}

private struct PermissionDemoPointer: Shape {
    func path(in rect: CGRect) -> Path {
        Path { path in
            path.move(to: .zero)
            let points = [
                CGPoint(x: 0, y: rect.height * 0.78),
                CGPoint(x: rect.width * 0.29, y: rect.height * 0.6),
                CGPoint(x: rect.width * 0.54, y: rect.height),
                CGPoint(x: rect.width * 0.76, y: rect.height * 0.89),
                CGPoint(x: rect.width * 0.52, y: rect.height * 0.53),
                CGPoint(x: rect.width, y: rect.height * 0.53)
            ]
            for point in points { path.addLine(to: point) }
            path.closeSubpath()
        }
    }
}
