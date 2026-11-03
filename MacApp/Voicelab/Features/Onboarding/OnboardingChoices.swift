import SwiftUI
import VoiceLabCore

struct OnboardingChoices: View {
    enum Kind { case role, useCases }
    let model: OnboardingModel
    let kind: Kind

    var body: some View {
        OnboardingPage(
            title: kind == .role
                ? AppLocalization.text("O‘zingiz haqingizda aytib bering")
                : AppLocalization.text("Ko‘proq qayerda yozasiz?"),
            subtitle: kind == .role
                ? AppLocalization.text("Nima ish bilan shug‘ullanasiz? O‘zingizga yaqin yo‘nalishni tanlang.")
                : AppLocalization.text(
                    "Bu Echo’ni ish joyingizga moslashga yordam beradi. Mos keladiganlarini tanlang."),
            width: 800
        ) {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 140), spacing: 12)], spacing: 12) {
                ForEach(options, id: \.id) { option in
                    OnboardingChoice(
                        title: option.title, symbol: option.symbol,
                        selected: kind == .role
                            ? model.progress.answers.role == option.id
                            : model.progress.answers.useCases.contains(option.id)
                    ) {
                        if kind == .role {
                            model.setAnswer(\.role, to: option.id)
                        } else {
                            model.toggleUseCase(option.id)
                        }
                    }
                }
            }
        }
    }

    private var options: [(id: String, title: String, symbol: String)] {
        if kind == .role {
            return [
                ("developer", AppLocalization.text("Dasturchi"), "chevron.left.forwardslash.chevron.right"),
                ("founder", AppLocalization.text("Tadbirkor"), "sparkles"),
                ("product", AppLocalization.text("Mahsulot"), "shippingbox"),
                ("marketing", AppLocalization.text("Marketing"), "megaphone"),
                ("sales", AppLocalization.text("Savdo"), "chart.line.uptrend.xyaxis"),
                ("operations", AppLocalization.text("Operatsiyalar"), "slider.horizontal.3"),
                ("student", AppLocalization.text("Talaba"), "graduationcap"),
                ("educator", AppLocalization.text("O‘qituvchi"), "book"),
                ("writer", AppLocalization.text("Yozuvchi"), "pencil.line"),
                ("creator", AppLocalization.text("Kontent yaratuvchi"), "video"),
                ("consultant", AppLocalization.text("Konsultant"), "briefcase"),
                ("legal", AppLocalization.text("Huquqshunos"), "scalemass"),
                ("healthcare", AppLocalization.text("Tibbiyot"), "stethoscope"),
                ("support", AppLocalization.text("Qo‘llab-quvvatlash"), "headphones"),
                ("other", AppLocalization.text("Boshqa"), "ellipsis"),
            ]
        }
        return [
            ("messages", AppLocalization.text("Xabarlar"), "message"),
            ("emails", AppLocalization.text("Email"), "envelope"),
            ("documents", AppLocalization.text("Hujjatlar"), "doc.text"),
            ("notes", AppLocalization.text("Qaydlar"), "note.text"),
            ("ai", AppLocalization.text("AI bilan suhbat"), "sparkles"),
            ("coding", AppLocalization.text("Dasturlash"), "curlybraces"),
            ("posts", AppLocalization.text("Postlar"), "text.bubble"),
            ("other", AppLocalization.text("Boshqa"), "ellipsis"),
        ]
    }
}

struct OnboardingChoice: View {
    @Environment(\.onboardingCompact) private var dense
    let title: String
    var symbol: String? = nil
    var detail: String? = nil
    let selected: Bool
    var compact = true
    let action: () -> Void
    @State private var hovered = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Group {
                        if let symbol {
                            OnboardingSymbol(name: symbol, size: 19, active: selected)
                        }
                    }
                    .frame(width: 32, height: 32).accessibilityHidden(true)
                    .foregroundStyle(selected ? OnboardingTheme.surface : OnboardingTheme.muted)
                    .background(
                        selected ? OnboardingTheme.ink : OnboardingTheme.panel,
                        in: RoundedRectangle(cornerRadius: 10))
                    Spacer(minLength: 0)
                    OnboardingSelectionMark(selected: selected).opacity(selected || hovered ? 1 : 0)
                }
                Text(title).font(.system(size: 14, weight: .semibold))
                    .lineLimit(2, reservesSpace: true)
                    .fixedSize(horizontal: false, vertical: true)
                if let detail {
                    Text(detail).font(.system(size: 12)).foregroundStyle(OnboardingTheme.muted)
                }
            }
            .multilineTextAlignment(.leading)
            .foregroundStyle(OnboardingTheme.ink)
            .padding(.horizontal, 12).padding(.vertical, dense ? 6 : compact ? 10 : 14)
            .frame(maxWidth: .infinity, minHeight: dense ? 66 : compact ? 80 : 100, alignment: .topLeading)
            .background(
                selected
                    ? OnboardingTheme.ink.opacity(0.07)
                    : hovered ? OnboardingTheme.panel : OnboardingTheme.surface,
                in: RoundedRectangle(cornerRadius: 12)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 12).strokeBorder(
                    selected ? OnboardingTheme.ink : OnboardingTheme.border)
            )
            .contentShape(RoundedRectangle(cornerRadius: 12))
        }
        .buttonStyle(.plain).onHover { hovered = $0 }
        .animation(reduceMotion ? nil : .smooth(duration: 0.2), value: selected)
        .animation(reduceMotion ? nil : .easeOut(duration: 0.15), value: hovered)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}

struct OnboardingAlphabet: View {
    let model: OnboardingModel
    var body: some View {
        OnboardingPage(
            title: AppLocalization.text("Qaysi o‘zbek alifbosidan foydalanasiz?"),
            subtitle: AppLocalization.text("Faqat yangi o‘zbekcha diktovka matniga qo‘llanadi."),
            width: 512
        ) {
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 12), count: 2)) {
                ForEach(UzbekAlphabet.allCases) { alphabet in
                    OnboardingChoice(
                        title: AppLocalization.text(alphabet.title), symbol: "textformat.abc",
                        detail: alphabet.example, selected: model.uzbekAlphabet == alphabet,
                        compact: true
                    ) {
                        model.uzbekAlphabet = alphabet
                    }
                }
            }
            Text(AppLocalization.text("Buni istalgan vaqt Sozlamalarda o‘zgartirishingiz mumkin."))
                .font(.system(size: 12)).foregroundStyle(OnboardingTheme.muted).padding(.top, 4)
        }
    }
}

struct OnboardingPersonalize: View {
    let model: OnboardingModel
    private var styles: [(String, String, String, String)] {
        [
            (
                "casual", AppLocalization.text("Erkin"),
                AppLocalization.text("Kam tinish belgisi, erkin uslub"),
                AppLocalization.text("salom ertaga tushlikka bo‘shmisan? soat 12 bo‘lsa senga qulay")
            ),
            (
                "formal", AppLocalization.text("Rasmiy"),
                AppLocalization.text("To‘liq tinish belgilari, sayqallangan uslub"),
                AppLocalization.text("Salom, ertaga tushlikka bo‘shmisan? Soat 12 bo‘lsa senga qulay.")
            ),
            (
                "excited", AppLocalization.text("Hayajonli!"),
                AppLocalization.text("Ko‘proq undov belgilari!"),
                AppLocalization.text("Salom, ertaga tushlikka bo‘shmisan? Soat 12 bo‘lsa senga qulay!")
            ),
        ]
    }
    var body: some View {
        OnboardingPage(
            title: AppLocalization.text("Siz qanday yozasiz?"),
            subtitle: AppLocalization.text(
                "O‘zingizga yaqin yozish uslubini tanlang. Xohishingiz hisobingizda saqlanadi."),
            width: 768
        ) {
            HStack(alignment: .top, spacing: 12) {
                ForEach(styles, id: \.0) { style in
                    styleCard(style)
                }
            }
            Text(
                AppLocalization.text(
                    "Namunalar uslublar farqini ko‘rsatadi. Ushbu tanlov hozircha transkripsiyani avtomatik qayta yozmaydi."
                )
            )
            .font(.system(size: 11)).lineSpacing(3).foregroundStyle(OnboardingTheme.muted)
            HStack(spacing: 12) {
                Button(AppLocalization.text("Keyinroq sozlash")) { model.next() }
                    .buttonStyle(OnboardingButtonStyle(variant: .ghost))
                Button(AppLocalization.text("Davom etish")) { model.next() }
                    .buttonStyle(OnboardingButtonStyle()).keyboardShortcut(.defaultAction)
            }.padding(.top, 8).disabled(!model.canContinue)
        }
    }

    private func styleCard(_ style: (String, String, String, String)) -> some View {
        let selected = model.progress.answers.writingStyle == style.0
        return Button {
            model.setAnswer(\.writingStyle, to: style.0)
        } label: {
            VStack(alignment: .leading, spacing: 12) {
                HStack(alignment: .top, spacing: 8) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(style.1).font(.system(size: 16, weight: .semibold))
                        Text(style.2).font(.system(size: 12)).foregroundStyle(OnboardingTheme.muted)
                            .frame(minHeight: 32, alignment: .top)
                    }
                    Spacer(minLength: 0)
                    OnboardingSelectionMark(selected: selected)
                }
                Text(style.3).font(.system(size: 14)).lineSpacing(5)
                    .frame(maxWidth: .infinity, minHeight: 90, alignment: .topLeading).padding(12)
                    .background(OnboardingTheme.panel, in: RoundedRectangle(cornerRadius: 12))
            }
            .foregroundStyle(OnboardingTheme.ink).multilineTextAlignment(.leading)
            .padding(16).frame(maxWidth: .infinity, alignment: .topLeading)
            .background(
                selected ? OnboardingTheme.ink.opacity(0.07) : OnboardingTheme.surface,
                in: RoundedRectangle(cornerRadius: 12)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 12).strokeBorder(
                    selected ? OnboardingTheme.ink : OnboardingTheme.border))
        }.buttonStyle(.plain).accessibilityAddTraits(selected ? .isSelected : [])
    }
}
