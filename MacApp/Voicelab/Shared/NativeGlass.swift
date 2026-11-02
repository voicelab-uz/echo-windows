import SwiftUI

/// Glass belongs on floating controls, not every content card.
struct NativeGlass: ViewModifier {
    var radius: CGFloat = 22
    var dark = false
    var interactive = false
    var enabled = true
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    @ViewBuilder
    func body(content: Content) -> some View {
        if !enabled {
            content
        } else if #available(macOS 26.0, *), !reduceTransparency {
            content.glassEffect(
                .regular.tint(dark ? Color.black.opacity(0.82) : nil).interactive(interactive),
                in: RoundedRectangle(cornerRadius: radius))
        } else {
            content.background(
                dark ? Color(white: 0.04) : Color(nsColor: .controlBackgroundColor),
                in: RoundedRectangle(cornerRadius: radius))
        }
    }
}
