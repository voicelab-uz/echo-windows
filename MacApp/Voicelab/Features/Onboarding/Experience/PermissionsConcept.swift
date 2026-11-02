import SwiftUI

extension PermissionKind {

    func title(in copy: PermissionsCopy) -> String {
        self == .microphone ? copy.microphone : copy.accessibility
    }
    func detail(in copy: PermissionsCopy) -> String {
        self == .microphone ? copy.microphoneDetail : copy.accessibilityDetail
    }
}

struct PermissionsConcept: View {
    @Binding var language: WelcomeLanguage
    @Binding var allowed: Set<PermissionKind>
    let onBack: () -> Void
    let onContinue: () -> Void
    let onRequest: (PermissionKind) -> Void
    var microphoneNeedsSettings = false
    var accessibilityNeedsSettings = false
    var requesting = false
    var notice: String? = nil
    var onRevealApp: (() -> Void)? = nil
    var onRecheckAccessibility: (() -> Void)? = nil
    var accessibilityRecheckFailed = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var appeared = false
    @State private var showingAccessibilityHelp = false

    private var copy: PermissionsCopy { language.permissionsCopy }
    private var ready: Bool { allowed.count == PermissionKind.allCases.count }
    private var highlighted: PermissionKind {
        allowed.contains(.microphone) ? .accessibility : .microphone
    }

    var body: some View {
        GeometryReader { geometry in
            let compact = geometry.size.width < 980
            HStack(spacing: 0) {
                VStack(spacing: 0) {
                    ScrollView {
                        content(compact: compact)
                            .frame(maxWidth: 340, alignment: .leading)
                            .padding(.vertical, 24)
                            .frame(maxWidth: .infinity, minHeight: max(0, geometry.size.height - OnboardingNavigationBar.height - OnboardingFooter.height))
                    }
                    .scrollIndicators(.hidden)
                    .scrollBounceBehavior(.basedOnSize)
                    OnboardingFooter(language: language, backIdentifier: "permissions-back", onBack: onBack,
                                     nextTitle: copy.continueTitle, nextEnabled: ready,
                                     nextIdentifier: "permissions-continue", onNext: onContinue, inset: 0)
                }
                .padding(.top, OnboardingNavigationBar.height)
                .padding(.horizontal, compact ? 32 : 56)
                .frame(width: geometry.size.width * 0.44)
                .background(WelcomePalette.canvas)
                PermissionSettingsDemo(language: language, focus: highlighted, isGranted: ready, microphoneNeedsSettings: microphoneNeedsSettings)
                    .id(language)
                    .id(highlighted)
                    .id(microphoneNeedsSettings)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            .overlay(alignment: .top) {
                OnboardingNavigationBar(language: $language, backIdentifier: "permissions-back", onBack: onBack)
            }
        }
        .onAppear {
            withAnimation(.easeOut(duration: reduceMotion ? 0.15 : 0.4)) { appeared = true }
        }
        .onChange(of: accessibilityRecheckFailed) { _, failed in
            if failed { showingAccessibilityHelp = true }
        }
    }

    private func content(compact: Bool) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 10) {
                Image("EchoLogo").resizable().scaledToFit().frame(width: 30, height: 30)
                    .accessibilityHidden(true)
                Text("Echo").font(WelcomeType.font(size: 25, weight: .semibold)).tracking(-0.7)
            }
            .padding(.bottom, 24)
            Text(copy.heading)
                .font(WelcomeType.font(size: compact ? 32 : 38, weight: .semibold))
                .tracking(language.usesLatin ? -1.1 : 0)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityAddTraits(.isHeader)
                .padding(.bottom, 28)
            VStack(spacing: 24) {
                permissionRow(.microphone)
                permissionRow(.accessibility)
            }
            .padding(.bottom, 28)
            if !allowed.contains(.accessibility), let onRevealApp, let onRecheckAccessibility {
                DisclosureGroup(copy.accessibilityHelpTitle, isExpanded: $showingAccessibilityHelp) {
                    VStack(alignment: .leading, spacing: 12) {
                        Text(copy.accessibilityHelp)
                            .fixedSize(horizontal: false, vertical: true)
                        ViewThatFits(in: .horizontal) {
                            HStack(spacing: 16) {
                                recoveryActions(reveal: onRevealApp, recheck: onRecheckAccessibility)
                            }
                            VStack(alignment: .leading, spacing: 12) {
                                recoveryActions(reveal: onRevealApp, recheck: onRecheckAccessibility)
                            }
                        }
                        if accessibilityRecheckFailed {
                            Text(copy.accessibilityStillDenied)
                                .foregroundStyle(WelcomePalette.coral)
                                .fixedSize(horizontal: false, vertical: true)
                                .accessibilityIdentifier("permissions-recheck-result")
                        }
                    }
                    .padding(.top, 8)
                }
                .font(WelcomeType.font(size: 12))
                .foregroundStyle(WelcomePalette.muted)
                .padding(.bottom, 20)
                .accessibilityIdentifier("permissions-accessibility-help")
            }
            if let notice {
                Text(notice).font(WelcomeType.font(size: 12))
                    .foregroundStyle(WelcomePalette.coral).padding(.bottom, 12)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Text(copy.privacy)
                .font(WelcomeType.font(size: 11))
                .foregroundStyle(WelcomePalette.muted)
                .lineSpacing(3)
                .fixedSize(horizontal: false, vertical: true)
        }
        .opacity(appeared ? 1 : 0)
        .offset(y: appeared || reduceMotion ? 0 : 8)
    }

    @ViewBuilder private func recoveryActions(reveal: @escaping () -> Void, recheck: @escaping () -> Void) -> some View {
        Button(copy.showApp, action: reveal)
            .accessibilityIdentifier("permissions-show-app")
        Button(copy.checkAgain, action: recheck)
            .accessibilityIdentifier("permissions-recheck")
    }

    private func permissionRow(_ kind: PermissionKind) -> some View {
        let granted = allowed.contains(kind)
        return HStack(spacing: 20) {
            VStack(alignment: .leading, spacing: 5) {
                Text(kind.title(in: copy))
                    .font(WelcomeType.font(size: 14, weight: .semibold))
                    .fixedSize(horizontal: false, vertical: true)
                Text(kind.detail(in: copy))
                    .font(WelcomeType.font(size: 12))
                    .foregroundStyle(WelcomePalette.muted)
                    .lineSpacing(3)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            Button {
                guard !allowed.contains(kind) else { return }
                onRequest(kind)
            } label: {
                HStack(spacing: 5) {
                    if granted { Image(systemName: "checkmark").font(.system(size: 10, weight: .semibold)) }
                    Text(granted ? copy.allowed :
                        ((kind == .microphone && microphoneNeedsSettings) ||
                         (kind == .accessibility && accessibilityNeedsSettings) ? copy.settings.systemSettings : copy.allow))
                        .font(WelcomeType.font(size: 12, weight: .semibold))
                        .contentTransition(.opacity)
                }
                .padding(.horizontal, 12)
                .frame(minWidth: 64, minHeight: 32)
                .fixedSize(horizontal: true, vertical: false)
            }
            .buttonStyle(PermissionButtonStyle(prominent: highlighted == kind, granted: granted))
            .disabled(granted || requesting)
            .accessibilityLabel("\(kind.title(in: copy)) · \(granted ? copy.allowed : copy.allow)")
            .accessibilityIdentifier("permissions-allow-\(kind.rawValue)")
        }
    }
}

private struct PermissionButtonStyle: ButtonStyle {
    let prominent: Bool
    var granted = false

    func makeBody(configuration: Configuration) -> some View {
        PermissionButtonBody(configuration: configuration, prominent: prominent, granted: granted)
    }
}

/// Clear affordances on either appearance: the primary action is the highest-contrast
/// surface, Allow buttons are outlined, and Allowed reads as a green confirmation pill.
private struct PermissionButtonBody: View {
    let configuration: ButtonStyleConfiguration
    let prominent: Bool
    let granted: Bool
    @Environment(\.isEnabled) private var isEnabled
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var hovered = false

    private static let green = Color(red: 0.30, green: 0.72, blue: 0.46)
    private var dark: Bool { colorScheme == .dark }

    private var foreground: Color {
        if granted { return dark ? Self.green : Color(red: 0.2, green: 0.5, blue: 0.32) }
        if !isEnabled { return WelcomePalette.muted.opacity(0.75) }
        if prominent { return dark ? WelcomePalette.control : .white }
        return WelcomePalette.ink
    }

    private var background: Color {
        if granted { return Self.green.opacity(dark ? 0.14 : 0.12) }
        if prominent && isEnabled { return (dark ? Color.white : WelcomePalette.control).opacity(hovered ? 0.9 : 1) }
        return WelcomePalette.ink.opacity(hovered && isEnabled ? 0.09 : 0.055)
    }

    private var border: Color {
        if granted { return Self.green.opacity(0.4) }
        if prominent && isEnabled { return .clear }
        return WelcomePalette.ink.opacity(0.16)
    }

    var body: some View {
        configuration.label
            .foregroundStyle(foreground)
            .background(background, in: .rect(cornerRadius: 9))
            .overlay(RoundedRectangle(cornerRadius: 9).strokeBorder(border, lineWidth: 1))
            .shadow(color: .black.opacity(prominent && isEnabled ? (dark ? 0.35 : 0.18) : 0.12),
                    radius: prominent ? 10 : 4, y: prominent ? 4 : 2)
            .scaleEffect(configuration.isPressed && !reduceMotion ? 0.98 : 1)
            .onHover { hovered = $0 }
            .animation(.easeOut(duration: 0.15), value: hovered)
            .animation(.easeOut(duration: 0.15), value: configuration.isPressed)
            .animation(.easeOut(duration: 0.2), value: granted)
    }
}

struct PermissionsCopy: Decodable {
    let heading, microphone, microphoneDetail, accessibility, accessibilityDetail: String
    let allow, allowed, continueTitle, back, privacy: String
    let microphoneInstruction, accessibilityInstruction: String
    let recovery, restricted, settingsUnavailable: String
    let accessibilityHelpTitle, accessibilityHelp, showApp, checkAgain, accessibilityStillDenied: String
    let dragInstruction, dragConfirmation, dragFinder, settingsAlias, closeHelp: String
    let settings: PermissionSettingsCopy

    static let catalog: [String: PermissionsCopy] = {
        guard let url = Bundle.main.url(forResource: "PermissionsLanguages", withExtension: "json"),
              let data = try? Data(contentsOf: url),
              let catalog = try? JSONDecoder().decode([String: PermissionsCopy].self, from: data),
              WelcomeLanguage.allCases.allSatisfy({ catalog[$0.rawValue] != nil })
        else { fatalError("The preview requires its complete PermissionsLanguages.json resource.") }
        return catalog
    }()
}

struct PermissionSettingsCopy: Decodable {
    let systemSettings, search, lockScreen, privacySecurity, touchIDPassword, usersGroups: String
    let gameCenter, internetAccounts, walletApplePay, keyboard, trackpad, controlAccess: String
    let microphoneDescription, accessibilityDescription, controlAccessDescription: String
    let microphoneRequest, microphoneReason, dontAllow: String
}

extension WelcomeLanguage {
    var permissionsCopy: PermissionsCopy { PermissionsCopy.catalog[rawValue]! }
}
