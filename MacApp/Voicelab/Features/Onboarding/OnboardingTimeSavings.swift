import SwiftUI

struct OnboardingTimeSavings: View {
    @Environment(\.onboardingCompact) private var compact
    let model: OnboardingModel
    @State private var hours = 2.0
    private var measuredRate: Double? {
        guard let words = model.practiceWords, let seconds = model.practiceSeconds, seconds > 0 else {
            return nil
        }
        let rate = Double(words) / seconds * 60
        return (1...260).contains(rate) ? rate : nil
    }
    private var voiceRate: Double { measuredRate ?? 130 }
    private var savings: Double { hours * 5 * max(0, 1 - 40 / voiceRate) }

    var body: some View {
        OnboardingPage(
            title: AppLocalization.text("Zo‘r!"),
            subtitle: measuredRate == nil
                ? AppLocalization.text("Ovoz bilan yozish uchun namunaviy hisobni ko‘ring.")
                : AppLocalization.text("Siz daqiqasiga %d so‘z gapirdingiz.", Int(voiceRate.rounded())),
            width: 512
        ) {
            VStack(spacing: 8) {
                Text("\(voiceRate / 40, specifier: "%.1f")×").font(.system(size: 32, weight: .semibold))
                    .tracking(-1)
                Text(AppLocalization.text("klaviatura taxminiga nisbatan tezlik")).font(.system(size: 14))
                    .foregroundStyle(
                        OnboardingTheme.muted)
            }
            OnboardingCard {
                VStack(spacing: 12) {
                    rate(
                        AppLocalization.text("Sizning ovozingiz"), symbol: "mic", value: voiceRate,
                        tint: OnboardingTheme.ink)
                    rate(
                        AppLocalization.text("Klaviaturada"), symbol: "keyboard", value: 40,
                        tint: OnboardingTheme.keyBorder)
                }
            }
            OnboardingCard {
                VStack(spacing: 12) {
                    HStack {
                        Text(AppLocalization.text("Kuniga yozishga ketadigan vaqt")).font(
                            .system(size: 14, weight: .medium))
                        Spacer()
                        Text(AppLocalization.text("%d soat", Int(hours))).font(
                            .system(size: 14, weight: .semibold)
                        )
                        .monospacedDigit()
                    }
                    Slider(value: $hours, in: 1...8, step: 1).accessibilityLabel(
                        AppLocalization.text("Kunlik yozish soatlari"))
                    Text(
                        AppLocalization.text(
                            "Echo bilan haftasiga %.1f soat tejashingiz mumkin.", savings)
                    )
                    .font(.system(size: 14)).frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            Text(
                AppLocalization.text(
                    "Hisob: klaviatura — 40 so‘z/daq; o‘lchov bo‘lmasa ovoz — 130 so‘z/daq. Tahrirlash va kutish vaqti hisobga olinmagan."
                )
            )
            .font(.system(size: 11)).lineSpacing(3).foregroundStyle(OnboardingTheme.muted)
        }
    }

    private func rate(_ title: String, symbol: String, value: Double, tint: Color) -> some View {
        HStack(spacing: 12) {
            AppLabel(title, systemImage: symbol).font(.system(size: 12, weight: .medium))
                .foregroundStyle(OnboardingTheme.muted).frame(width: 135, alignment: .leading)
            GeometryReader { geometry in
                RoundedRectangle(cornerRadius: 8).fill(tint)
                    .frame(width: geometry.size.width * value / max(voiceRate, 40))
            }.frame(height: compact ? 22 : 32).background(
                OnboardingTheme.panel, in: RoundedRectangle(cornerRadius: 8))
            Text(AppLocalization.text("%d so‘z/daq", Int(value.rounded()))).font(
                .system(size: 12, weight: .semibold)
            )
            .monospacedDigit().frame(width: 80, alignment: .trailing)
        }
    }
}
