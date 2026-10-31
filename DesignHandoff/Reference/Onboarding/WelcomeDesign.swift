import SwiftUI
import AppKit
import CoreText

enum WelcomePalette {
    static let ink = Color("OnboardingInk")
    static let canvas = Color("OnboardingCanvas")
    static let surface = Color("OnboardingSurface")
    static let warm = Color("OnboardingWarm")
    // Inverted controls and recording capsules retain white labels in either appearance.
    static let control = Color(red: 0.11, green: 0.11, blue: 0.13)
    static let muted = Color("OnboardingMuted")
    static let coral = Color(red: 0.91, green: 0.45, blue: 0.39)
    static let lavender = Color("OnboardingLavender")
}



struct WelcomeLanguagePicker: View {
    @Binding var language: WelcomeLanguage
    @State private var hovered = false

    var body: some View {
        Menu {
            ForEach(WelcomeLanguage.allCases) { option in
                Button {
                    guard language != option else { return }
                    language = option
                    OnboardingHaptics.play(.selection)
                } label: {
                    if option == language {
                        Label(option.nativeName, systemImage: "checkmark")
                    } else {
                        Text(option.nativeName)
                    }
                }
            }
        } label: {
            Text(language.nativeName)
        }
        .menuStyle(.borderlessButton)
        .font(WelcomeType.font(size: 13, weight: .medium))
        .foregroundStyle(WelcomePalette.ink)
        .fixedSize()
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(WelcomePalette.ink.opacity(hovered ? 0.055 : 0.025), in: .rect(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(WelcomePalette.ink.opacity(hovered ? 0.18 : 0.1)))
        .accessibilityLabel(language.copy.language)
        .accessibilityValue(language.nativeName)
        .accessibilityIdentifier("welcome-language-picker")
        .onHover { hovered = $0 }
        .animation(.easeOut(duration: 0.15), value: hovered)
    }
}

struct WelcomePrimaryButton: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        WelcomePrimaryButtonBody(configuration: configuration)
    }
}

/// Dark on light, light on dark: the primary action always has the strongest contrast.
private struct WelcomePrimaryButtonBody: View {
    let configuration: ButtonStyleConfiguration
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var hovered = false

    private var dark: Bool { colorScheme == .dark }

    var body: some View {
        configuration.label
            .foregroundStyle(dark ? WelcomePalette.control : .white)
            .background((dark ? Color.white : WelcomePalette.control).opacity(hovered ? 0.9 : 1),
                        in: .rect(cornerRadius: 12))
            .shadow(color: dark ? .white.opacity(hovered ? 0.12 : 0.06) : .clear, radius: 12)
            .scaleEffect(configuration.isPressed && !reduceMotion ? 0.98 : 1)
            .onHover { hovered = $0 }
            .animation(.easeOut(duration: 0.15), value: configuration.isPressed)
            .animation(.easeOut(duration: 0.15), value: hovered)
    }
}

// All seven official Manrope weights are bundled with their OFL licence.
// Core Text supplies native fallback glyphs for scripts outside this family.
@MainActor
enum WelcomeType {
    private static var names: [String: String] = [:]

    static func registerBundledFonts() {
        let urls = ["otf", "ttf"].flatMap {
            (Bundle.main.urls(forResourcesWithExtension: $0, subdirectory: "Fonts") ?? []) + (Bundle.main.urls(forResourcesWithExtension: $0, subdirectory: nil) ?? [])
        }
        for url in urls {
            guard let descriptors = CTFontManagerCreateFontDescriptorsFromURL(url as CFURL) as? [CTFontDescriptor] else { continue }
            CTFontManagerRegisterFontsForURL(url as CFURL, .process, nil)
            for descriptor in descriptors {
                if let name = CTFontDescriptorCopyAttribute(descriptor, kCTFontNameAttribute) as? String,
                   let style = CTFontDescriptorCopyAttribute(descriptor, kCTFontStyleNameAttribute) as? String,
                   name.lowercased().contains("manrope") {
                    names[style.replacingOccurrences(of: " ", with: "").lowercased()] = name
                }
            }
        }
    }

    static func font(size: CGFloat, weight: Font.Weight = .regular) -> Font {
        let style: String
        switch weight {
        case .ultraLight, .thin: style = "extralight"
        case .light: style = "light"
        case .medium: style = "medium"
        case .semibold: style = "semibold"
        case .bold: style = "bold"
        case .heavy, .black: style = "extrabold"
        default: style = "regular"
        }
        if let name = names[style] {
            return .custom(name, fixedSize: size)
        }
        if let regular = names["regular"] {
            return .custom(regular, fixedSize: size).weight(weight)
        }
        return .system(size: size, weight: weight)
    }
}

struct WelcomeCopy: Decodable {
    let stages: [String]
    let heading, subtitle, start, language: String
    let messageTitle, recipient, sentence, placeholder, ready, listening, processing, done: String
    let captions, demoSteps: [String]

    static let catalog: [String: WelcomeCopy] = {
        guard let url = Bundle.main.url(forResource: "WelcomeLanguages", withExtension: "json"),
              let data = try? Data(contentsOf: url),
              let catalog = try? JSONDecoder().decode([String: WelcomeCopy].self, from: data),
              WelcomeLanguage.allCases.allSatisfy({ language in
                  guard let copy = catalog[language.rawValue] else { return false }
                  return copy.stages.count == 6 && copy.captions.count == 4 && copy.demoSteps.count == 3
              }) else { fatalError("The preview requires its complete WelcomeLanguages.json resource.") }
        return catalog
    }()
}

enum WelcomeLanguage: String, CaseIterable, Identifiable {
    case english = "en", uzbek = "uz", russian = "ru", german = "de", korean = "ko", chinese = "zh-Hans"
    case hindi = "hi", spanish = "es", arabic = "ar", french = "fr", bengali = "bn"
    case portuguese = "pt", indonesian = "id", urdu = "ur", japanese = "ja", nigerianPidgin = "pcm"

    var id: String { rawValue }
    var copy: WelcomeCopy { WelcomeCopy.catalog[rawValue]! }
    var isRightToLeft: Bool { self == .arabic || self == .urdu }
    var usesLatin: Bool { [.english, .uzbek, .german, .spanish, .french, .portuguese, .indonesian, .nigerianPidgin].contains(self) }
    var nativeName: String {
        switch self {
        case .english: "English"
        case .uzbek: "Oʻzbekcha"
        case .russian: "Русский"
        case .german: "Deutsch"
        case .korean: "한국어"
        case .chinese: "简体中文"
        case .hindi: "हिन्दी"
        case .spanish: "Español"
        case .arabic: "العربية"
        case .french: "Français"
        case .bengali: "বাংলা"
        case .portuguese: "Português"
        case .indonesian: "Bahasa Indonesia"
        case .urdu: "اردو"
        case .japanese: "日本語"
        case .nigerianPidgin: "Naijá · Nigerian Pidgin"
        }
    }
}

struct WelcomeProgress: View {
    let stages: [String]
    var activeIndex = 0
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var appeared = false

    var body: some View {
        HStack(spacing: 18) {
            ForEach(Array(stages.enumerated()), id: \.offset) { index, stage in
                if index > 0 {
                    Capsule().fill(WelcomePalette.ink.opacity(0.12))
                        .frame(width: 22, height: 1)
                        .accessibilityHidden(true)
                }
                HStack(spacing: 7) {
                    if index == activeIndex {
                        Circle().fill(WelcomePalette.coral).frame(width: 5, height: 5)
                    }
                    Text(stage)
                        .font(WelcomeType.font(size: 12, weight: index == activeIndex ? .medium : .regular))
                        .fixedSize()
                }
                .foregroundStyle(index == activeIndex ? WelcomePalette.ink : WelcomePalette.muted)
                .padding(.horizontal, index == activeIndex ? 13 : 0)
                .frame(height: 30)
                .background(index == activeIndex ? WelcomePalette.ink.opacity(0.045) : .clear, in: Capsule())
                .accessibilityAddTraits(index == activeIndex ? .isSelected : [])
                .opacity(appeared ? 1 : 0)
                .offset(y: appeared || reduceMotion ? 0 : 4)
                .animation(reduceMotion ? nil : .easeOut(duration: 0.25).delay(Double(index) * 0.035), value: appeared)
            }
        }
        .padding(.horizontal, 24)
        .frame(maxWidth: .infinity)
        .frame(height: 52)
        .background(WelcomePalette.canvas)
        .overlay(alignment: .bottom) { Rectangle().fill(WelcomePalette.ink.opacity(0.055)).frame(height: 1) }
        .onAppear { appeared = true }
    }
}
