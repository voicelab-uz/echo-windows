import SwiftUI

struct WelcomeLanding: View {
    @Binding var language: WelcomeLanguage
    let onContinue: () -> Void
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    private let appeared = true
    private var copy: WelcomeCopy { language.copy }
    var body: some View {
        GeometryReader { geometry in
            let compact = geometry.size.width < 980
            HStack(spacing: 0) {
                VStack(alignment: .leading, spacing: 0) {
                    Spacer(minLength: 32)
                    VStack(alignment: .leading, spacing: 32) {
                        HStack(spacing: 10) {
                            Image("EchoLogo").resizable().scaledToFit().frame(width: 34, height: 34)
                                .accessibilityHidden(true)
                            Text("Echo").font(WelcomeType.font(size: 25, weight: .semibold)).tracking(-0.7)
                        }
                        VStack(alignment: .leading, spacing: 16) {
                            Text(copy.heading)
                                .font(WelcomeType.font(size: compact ? 38 : 46, weight: .semibold))
                                .tracking(language.usesLatin ? -1.5 : 0).lineSpacing(0)
                                .fixedSize(horizontal: false, vertical: true)
                                .accessibilityAddTraits(.isHeader)
                            Text(copy.subtitle)
                                .font(WelcomeType.font(size: 16)).lineSpacing(6)
                                .foregroundStyle(WelcomePalette.muted)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        Button(action: { onContinue() }) {
                            HStack {
                                Text(copy.start)
                                Spacer()
                                Image(systemName: "arrow.forward").font(WelcomeType.font(size: 14, weight: .medium))
                            }
                            .font(WelcomeType.font(size: 14, weight: .semibold))
                            .padding(.horizontal, 20).frame(height: 50)
                        }
                        .buttonStyle(WelcomePrimaryButton())
                        .keyboardShortcut(.defaultAction)
                        .padding(.top, 8)
                    }
                    .frame(maxWidth: 300, alignment: .leading)
                    .opacity(appeared ? 1 : 0)
                    .offset(y: appeared || reduceMotion ? 0 : 10)
                    Spacer(minLength: 32)
                }
                .padding(.horizontal, compact ? 36 : 56)
                .frame(width: geometry.size.width * 0.44)
                .background(WelcomePalette.canvas)
                WelcomeDemo(language: language)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            // Same spot as the other onboarding steps: the far right of the top bar.
            .overlay(alignment: .topTrailing) {
                WelcomeLanguagePicker(language: $language)
                    .padding(.top, 20).padding(.trailing, 36)
            }
        }
    }
}
