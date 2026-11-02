import SwiftUI

private struct OnboardingCompactKey: EnvironmentKey { static let defaultValue = false }
extension EnvironmentValues {
    var onboardingCompact: Bool {
        get { self[OnboardingCompactKey.self] }
        set { self[OnboardingCompactKey.self] = newValue }
    }
}

/// Setup uses the same neutral, adaptive surfaces as the workspace.
enum OnboardingTheme {
    static let canvas = Design.canvas
    static let surface = Design.surface
    static let card = Design.canvas
    static let panel = Design.selection
    static let ink = Design.accent
    static let glow = Color(red: 0.48, green: 0.57, blue: 0.92)
    static let muted = Color.secondary
    static let border = ink.opacity(0.10)
    static let keyBorder = ink.opacity(0.18)
    static let success = Design.green
    static let radius: CGFloat = 22
}

struct OnboardingWordmark: View {
    var height: CGFloat = 28
    var body: some View {
        HStack(spacing: height * 0.3) {
            AppBrandIcon().frame(width: height, height: height)
                .modifier(EchoLogoEndpoint(location: .onboarding))
                .accessibilityHidden(true)
            Text("Echo").font(.system(size: height * 0.75, weight: .semibold))
                .tracking(-0.4)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Echo")
    }
}

struct OnboardingButtonStyle: ButtonStyle {
    enum Variant { case primary, secondary, ghost }
    var variant: Variant = .primary
    var height: CGFloat = 44
    @Environment(\.isEnabled) private var isEnabled
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var hovered = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 14, weight: .semibold))
            .padding(.horizontal, variant == .ghost ? 12 : 20)
            .frame(minHeight: height)
            .foregroundStyle(variant == .primary ? OnboardingTheme.surface : OnboardingTheme.ink)
            .background(
                variant == .primary
                    ? OnboardingTheme.ink
                    : variant == .secondary ? .clear : hovered ? OnboardingTheme.panel : .clear,
                in: Capsule()
            )
            .modifier(NativeGlass(radius: height / 2, interactive: true, enabled: variant == .secondary))
            .overlay {
                if variant == .secondary {
                    Capsule().strokeBorder(OnboardingTheme.border)
                }
            }
            .contentShape(Capsule())
            .opacity(isEnabled ? (configuration.isPressed ? 0.8 : 1) : 0.4)
            .scaleEffect(configuration.isPressed && !reduceMotion ? 0.98 : 1)
            .onHover { hovered = $0 }
            .animation(reduceMotion ? nil : .easeOut(duration: 0.16), value: configuration.isPressed)
            .animation(reduceMotion ? nil : .easeOut(duration: 0.16), value: hovered)
    }
}

struct OnboardingPage<Content: View>: View {
    @Environment(\.onboardingCompact) private var compact
    let title: String
    let subtitle: String
    var width: CGFloat = 672
    @ViewBuilder var content: Content

    var body: some View {
        VStack(spacing: 0) {
            Text(title)
                .font(.system(size: compact ? 26 : 30, weight: .semibold))
                .tracking(-0.8).foregroundStyle(OnboardingTheme.ink)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityAddTraits(.isHeader)
            if !subtitle.isEmpty {
                Text(subtitle).font(.system(size: 14))
                    .foregroundStyle(OnboardingTheme.muted).lineSpacing(5)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: compact ? 640 : 520).padding(.top, compact ? 8 : 12)
            }
            VStack(spacing: compact ? 10 : 16) { content }
                .frame(maxWidth: .infinity).padding(.top, compact ? 16 : 24)
        }
        .multilineTextAlignment(.center)
        .frame(maxWidth: width)
    }
}

struct OnboardingCard<Content: View>: View {
    @Environment(\.onboardingCompact) private var compact
    var padding: CGFloat = 20
    @ViewBuilder var content: Content
    var body: some View {
        content.padding(compact ? min(padding, 14) : padding)
            .frame(maxWidth: .infinity)
            .background(OnboardingTheme.surface, in: RoundedRectangle(cornerRadius: OnboardingTheme.radius))
            .overlay(
                RoundedRectangle(cornerRadius: OnboardingTheme.radius).strokeBorder(OnboardingTheme.border))
    }
}

struct OnboardingKeycaps: View {
    @Environment(\.dictationShortcut) private var shortcut
    var large = false
    var active = false
    var body: some View {
        HStack(spacing: large ? 12 : 5) {
            OnboardingSymbol(
                name: shortcut.isFn ? "globe" : "keyboard", size: large ? 24 : 12, active: active)
            Text(shortcut.displayName)
        }
        .font(.system(size: large ? 24 : 12, weight: .semibold))
        .padding(.horizontal, large ? 18 : 7)
        .frame(minWidth: large ? 80 : 44, minHeight: large ? 72 : 27)
        .foregroundStyle(active ? OnboardingTheme.surface : OnboardingTheme.ink)
        .background(
            active ? OnboardingTheme.ink : OnboardingTheme.surface,
            in: RoundedRectangle(cornerRadius: large ? 12 : 6)
        )
        .overlay(
            RoundedRectangle(cornerRadius: large ? 12 : 6)
                .strokeBorder(active ? OnboardingTheme.ink : OnboardingTheme.keyBorder)
        )
        .compositingGroup()
        .shadow(color: OnboardingTheme.keyBorder, radius: 0, y: active ? 0 : 2)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(shortcut.isFn ? "Fn / Globe" : shortcut.displayName)
    }
}

struct OnboardingSelectionMark: View {
    let selected: Bool
    var body: some View {
        OnboardingSymbol(
            name: selected ? "checkmark.circle.fill" : "circle", size: 20, active: selected
        )
        .foregroundStyle(selected ? OnboardingTheme.ink : OnboardingTheme.border)
        .frame(width: 20, height: 20).accessibilityHidden(true)
    }
}

/// Shared frontend artwork with a restrained native selection transition.
struct OnboardingSymbol: View {
    let name: String
    var size: CGFloat = 18
    var active = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        AppIcon(systemName: name, size: size)
            .symbolRenderingMode(.hierarchical)
            .contentTransition(.opacity)
            .scaleEffect(active ? 1.05 : 1)
            .animation(reduceMotion ? nil : .smooth(duration: 0.22), value: active)
    }
}
