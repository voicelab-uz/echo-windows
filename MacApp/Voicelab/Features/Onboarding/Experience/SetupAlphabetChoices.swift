import SwiftUI

/// Compares the app's two Uzbek Latin alphabets; selection remains local to Setup.
struct SetupAlphabetChoices: View {
    let language: WelcomeLanguage
    @Binding var usesNewAlphabet: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var copy: SetupCopy { language.setupCopy }
    private var example: String {
        usesNewAlphabet ? "Özbekiston, ğoya, şahar, çiroyli" : "Oʻzbekiston, gʻoya, shahar, chiroyli"
    }

    var body: some View {
        VStack(spacing: 28) {
            Text(copy.alphabetHint)
                .font(WelcomeType.font(size: 14))
                .foregroundStyle(WelcomePalette.muted)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)

            HStack(spacing: 16) {
                choice(modern: false, title: copy.currentAlphabet)
                choice(modern: true, title: copy.newAlphabet)
            }

            Text(example)
                .font(WelcomeType.font(size: 15, weight: .medium))
                .foregroundStyle(WelcomePalette.muted)
                .multilineTextAlignment(.center)
                // One fixed line: a longer or shorter example must never resize the page.
                .lineLimit(1).minimumScaleFactor(0.7)
                .frame(maxWidth: .infinity).frame(height: 24)
                .contentTransition(.opacity)
                .environment(\.layoutDirection, .leftToRight)
                .accessibilityIdentifier("setup-alphabet-example")
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("setup-alphabet")
    }

    private func choice(modern: Bool, title: String) -> some View {
        let selected = usesNewAlphabet == modern
        return Button {
            guard !selected else { return }
            withAnimation(.easeOut(duration: 0.18)) {
                usesNewAlphabet = modern
            }
            OnboardingHaptics.play(.selection)
        } label: {
            VStack(spacing: 20) {
                HStack(alignment: .top, spacing: 10) {
                    Text(title)
                        .font(WelcomeType.font(size: 14, weight: .semibold))
                        .multilineTextAlignment(.leading)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    ZStack {
                        Circle().strokeBorder(WelcomePalette.ink.opacity(selected ? 0 : 0.18))
                        Circle().fill(WelcomePalette.control).opacity(selected ? 1 : 0)
                        Image(systemName: "checkmark")
                            .font(.system(size: 9, weight: .bold))
                            .foregroundStyle(.white)
                            .opacity(selected ? 1 : 0)
                    }
                    .frame(width: 18, height: 18)
                }
                .frame(minHeight: 36, alignment: .top)

                VStack(spacing: 12) {
                    Text(modern ? "Ö" : "Oʻ")
                        .font(WelcomeType.font(size: 72, weight: .light))
                        .tracking(-3)
                        .frame(height: 80)
                    HStack(spacing: 24) {
                        ForEach(modern ? ["Ğ", "Ş", "Ç"] : ["Gʻ", "Sh", "Ch"], id: \.self) { letter in
                            Text(letter).font(WelcomeType.font(size: 21, weight: .regular))
                        }
                    }
                    .foregroundStyle(WelcomePalette.muted)
                }
                // The specimens remain Uzbek Latin in every interface language.
                .environment(\.layoutDirection, .leftToRight)
                .frame(maxWidth: .infinity)
                .padding(.bottom, 8)
            }
            .padding(20)
            .background(WelcomePalette.canvas.opacity(selected ? 1 : 0.65), in: .rect(cornerRadius: 16))
            .overlay {
                RoundedRectangle(cornerRadius: 16)
                    .strokeBorder(WelcomePalette.ink.opacity(selected ? 0.5 : 0.08), lineWidth: 1)
            }
            .shadow(color: WelcomePalette.ink.opacity(selected ? 0.055 : 0), radius: 18, y: 8)
            .contentShape(.rect(cornerRadius: 16))
        }
        .buttonStyle(SetupAlphabetButtonStyle())
        .accessibilityLabel(title)
        .accessibilityValue(modern ? "Ö, Ğ, Ş, Ç" : "Oʻ, Gʻ, Sh, Ch")
        .accessibilityAddTraits(selected ? .isSelected : [])
        .accessibilityIdentifier(modern ? "setup-alphabet-new" : "setup-alphabet-current")
    }
}

/// Hover tint only: pressing must not scale the card, which read as a bounce.
private struct SetupAlphabetButtonStyle: ButtonStyle {
    @State private var hovered = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .foregroundStyle(WelcomePalette.ink)
            .overlay {
                RoundedRectangle(cornerRadius: 16)
                    .fill(WelcomePalette.ink.opacity(hovered ? 0.025 : 0))
                    .allowsHitTesting(false)
            }
            .animation(.easeOut(duration: 0.16), value: hovered)
            .onHover { hovered = $0 }
    }
}
