import SwiftUI

/// Eight measured frequency groups, mirrored around the bass band for balance.
/// The capture meter supplies attack/release smoothing; silence rests at small dots.
struct SetupLevelWaveform: View {
    let levels: [Double]
    let active: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        HStack(spacing: 7) {
            ForEach(0..<15) { index in
                let band = abs(index - 7)
                let level = levels.indices.contains(band) ? levels[band] : 0
                Capsule()
                    .fill(WelcomePalette.ink.opacity(active ? 0.85 : 0.16))
                    .frame(width: 7, height: 7 + 65 * min(1, max(0, level)))
            }
        }
        .frame(maxWidth: .infinity)
        .animation(reduceMotion ? nil : .linear(duration: 0.07), value: levels)
        .animation(.easeOut(duration: 0.2), value: active)
        .accessibilityHidden(true)
    }
}

struct SetupBackdrop: View {
    var body: some View {
        LinearGradient(
            colors: [WelcomePalette.lavender.opacity(0.6), WelcomePalette.warm],
            startPoint: .topLeading, endPoint: .bottomTrailing)
    }
}
