import SwiftUI

/// Black at the camera seam, with restrained native glass across the extension.
/// A single surface avoids the detached card border and a bright inner camera rim.
struct IslandGlassSurface: View {
    let shape: CameraIslandShape
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    var body: some View {
        shape.fill(.black)
            .overlay {
                if !reduceTransparency {
                    glass.opacity(0.22)
                }
            }
            .overlay {
                LinearGradient(
                    colors: [.clear, .white.opacity(reduceTransparency ? 0 : 0.035)],
                    startPoint: .top, endPoint: .bottom
                )
                .clipShape(shape)
            }
            .allowsHitTesting(false)
    }

    @ViewBuilder
    private var glass: some View {
        if #available(macOS 26.0, *) {
            shape.fill(.clear).glassEffect(.regular.tint(.black), in: shape)
        } else {
            shape.fill(.ultraThinMaterial)
        }
    }
}
