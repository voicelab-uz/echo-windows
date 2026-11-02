import SwiftUI

/// Echo's push button: a soft rounded fill that lifts on hover and dips on press.
/// Motion is short and springy so the UI feels immediate, and respects Reduce Motion.
struct EchoButtonStyle: ButtonStyle {
    enum Kind { case secondary, prominent, plain }
    var kind: Kind = .secondary
    var fullWidth = false

    func makeBody(configuration: Configuration) -> some View {
        EchoButtonBody(configuration: configuration, kind: kind, fullWidth: fullWidth)
    }
}

private struct EchoButtonBody: View {
    let configuration: ButtonStyleConfiguration
    let kind: EchoButtonStyle.Kind
    let fullWidth: Bool
    @State private var hovering = false
    @Environment(\.isEnabled) private var isEnabled
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var pressed: Bool { configuration.isPressed }

    private var fill: Color {
        switch kind {
        case .prominent:
            Design.tint.opacity(pressed ? 0.8 : hovering ? 0.9 : 1)
        case .secondary:
            Color.primary.opacity(pressed ? 0.16 : hovering ? 0.11 : 0.065)
        case .plain:
            Color.primary.opacity(pressed ? 0.1 : hovering ? 0.065 : 0)
        }
    }

    var body: some View {
        configuration.label
            .font(.system(size: 13, weight: .medium))
            .foregroundStyle(kind == .prominent ? AnyShapeStyle(.white) : AnyShapeStyle(.foreground))
            .padding(.horizontal, kind == .plain ? 8 : 12)
            .frame(maxWidth: fullWidth ? .infinity : nil, minHeight: kind == .plain ? 24 : 28)
            .background(fill, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            .contentShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            .opacity(isEnabled ? 1 : 0.45)
            .scaleEffect(pressed && !reduceMotion ? 0.97 : 1)
            .onHover { hovering = isEnabled && $0 }
            .animation(reduceMotion ? nil : .snappy(duration: 0.16), value: hovering)
            .animation(reduceMotion ? nil : .snappy(duration: 0.12), value: pressed)
    }
}

extension ButtonStyle where Self == EchoButtonStyle {
    static var echo: EchoButtonStyle { EchoButtonStyle() }
    static var echoProminent: EchoButtonStyle { EchoButtonStyle(kind: .prominent) }
    static var echoPlain: EchoButtonStyle { EchoButtonStyle(kind: .plain) }
}
