import SwiftUI

/// Only transcription has a timer. Recording is driven by real capture frames.
struct DictationWaveform: View {
    let recorder: AudioRecorder
    let phase: DictationModel.Phase
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    private let contour = [0.32, 0.58, 0.84, 1.0, 0.84, 0.58, 0.32]
    private let coral = Color(red: 1, green: 0.48, blue: 0.42)

    var body: some View {
        Group {
            switch phase {
            case .recording:
                let levels = recorder.islandLevels
                let peak = levels.max() ?? 0
                let presence = min(1, peak * 10)
                ZStack {
                    restingLine(coral).opacity(1 - presence)
                    HStack(spacing: 3) {
                        ForEach(contour.indices, id: \.self) { index in
                            // A stable centre-weighted silhouette follows real energy;
                            // spectral detail adds variation without sideways jitter.
                            let detail = levels.indices.contains(index) ? levels[index] : 0
                            let amplitude = (peak * 0.8 + detail * 0.2) * contour[index]
                            Capsule()
                                .fill(
                                    LinearGradient(
                                        colors: [Color(red: 1, green: 0.74, blue: 0.65), coral],
                                        startPoint: .top, endPoint: .bottom)
                                )
                                .frame(width: 3, height: 2 + amplitude * 21)
                        }
                    }
                    .opacity(presence)
                }
                .animation(reduceMotion ? nil : .smooth(duration: 0.14), value: levels)
            case .transcribing:
                TimelineView(.animation(minimumInterval: 1.0 / 24, paused: reduceMotion)) { context in
                    HStack(spacing: 3) {
                        ForEach(contour.indices, id: \.self) { index in
                            let pulse =
                                reduceMotion
                                ? 0.5
                                : 0.5 + 0.5
                                    * sin(
                                        context.date.timeIntervalSinceReferenceDate * 3 - Double(index) * 0.45
                                    )
                            Capsule()
                                .fill(.white.opacity(0.45 + pulse * 0.4))
                                .frame(width: 3, height: 2 + contour[index] * (3 + pulse * 5))
                        }
                    }
                }
            case .idle, .preparing, .failed:
                // Pressing Fn does not itself create a waveform or change its size.
                restingLine(phase == .failed ? .orange : .white)
            }
        }
        .frame(width: 42, height: 25)
        .accessibilityHidden(true)
    }

    private func restingLine(_ color: Color) -> some View {
        Capsule().fill(color).frame(width: 30, height: 2).opacity(0.65)
    }
}
