import SwiftUI

/// A continuous outline around a scrollable workspace or a group of history rows.
/// Clipping keeps hover fills and scrolling content inside the same rounded edge.
struct WorkspacePanel: ViewModifier {
    var radius: CGFloat = 20
    var fill: Color = Design.canvas
    @Environment(\.colorSchemeContrast) private var contrast

    func body(content: Content) -> some View {
        content
            .background(fill)
            .clipShape(RoundedRectangle(cornerRadius: radius, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: radius, style: .continuous)
                    .strokeBorder(
                        Design.accent.opacity(contrast == .increased ? 0.35 : 0.12), lineWidth: 1
                    )
                    .allowsHitTesting(false)
            }
    }
}
