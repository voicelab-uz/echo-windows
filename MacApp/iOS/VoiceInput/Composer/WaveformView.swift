import SwiftUI

/// Live bars, newest on the right. Reads `levels` itself so only this view redraws per audio buffer.
struct WaveformView: View {
    let model: ComposerModel

    private let barWidth: CGFloat = 3
    private let spacing: CGFloat = 2

    var body: some View {
        Canvas { context, size in
            var x = size.width - barWidth
            for level in model.levels.reversed() {
                guard x >= 0 else { break }
                let height = max(3, CGFloat(level) * size.height)
                let bar = CGRect(x: x, y: (size.height - height) / 2, width: barWidth, height: height)
                context.fill(Path(roundedRect: bar, cornerRadius: barWidth / 2), with: .foreground)
                x -= barWidth + spacing
            }
            // Resting dots fill the rest of the track until speech scrolls in.
            while x >= 0 {
                let dot = CGRect(x: x, y: (size.height - 3) / 2, width: barWidth, height: 3)
                context.fill(Path(roundedRect: dot, cornerRadius: barWidth / 2), with: .color(.secondary.opacity(0.4)))
                x -= barWidth + spacing
            }
        }
        .accessibilityHidden(true)
    }
}
