import SwiftUI
import VoiceLabCore

/// Remaining time and its proportion share the same server-provided balance.
struct UsageBalanceView: View {
    let usage: Usage
    var compact = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        VStack(alignment: .leading, spacing: compact ? 6 : 8) {
            Text(
                usage.enabled
                    ? AppLocalization.text(
                        "%@ · %d min qoldi", usage.planName ?? "Echo", usage.remaining / 60)
                    : AppLocalization.text("%@ · Faol emas", usage.planName ?? "Echo")
            )
            .font(.system(size: compact ? 10.5 : 12)).monospacedDigit()
            .foregroundStyle(.secondary).lineLimit(1).truncationMode(.tail)
            if let remainingFraction = usage.remainingFraction {
                ProgressView(value: remainingFraction)
                    .progressViewStyle(.linear).tint(Design.accent)
                    .frame(height: 4)
                    .accessibilityLabel(AppLocalization.text("Qolgan vaqt"))
                    .accessibilityValue(AppLocalization.text("%d daqiqa", usage.remaining / 60))
                    .animation(
                        reduceMotion ? nil : .smooth(duration: 0.25), value: remainingFraction)
            }
        }
        .help(
            usage.enabled
                ? AppLocalization.text("Tarif bo‘yicha qolgan vaqt")
                : AppLocalization.text("Faol tarif kerak"))
    }
}

extension Usage {
    /// An unknown or unlimited allowance has no meaningful percentage.
    var remainingFraction: Double? {
        guard enabled, let total = usageLimitSeconds, total > 0 else { return nil }
        return min(1, max(0, Double(remaining) / Double(total)))
    }
}
