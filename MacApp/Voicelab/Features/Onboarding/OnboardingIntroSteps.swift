import SwiftUI

struct OnboardingWelcome: View {
    let onStart: () -> Void

    var body: some View {
        VStack(spacing: 32) {
            HStack(spacing: 24) {
                OnboardingSymbol(name: "mic", size: 28)
                    .frame(width: 56, height: 56)
                    .background(OnboardingTheme.surface, in: RoundedRectangle(cornerRadius: 18))
                waveform
                AppBrandIcon().frame(width: 80, height: 80)
                waveform
                OnboardingSymbol(name: "doc.text", size: 28)
                    .frame(width: 56, height: 56)
                    .background(OnboardingTheme.surface, in: RoundedRectangle(cornerRadius: 18))
            }
            .padding(28)
            .background {
                RoundedRectangle(cornerRadius: 28, style: .continuous)
                    .fill(OnboardingTheme.surface.opacity(0.55))
                RoundedRectangle(cornerRadius: 28, style: .continuous)
                    .strokeBorder(OnboardingTheme.border)
            }
            .accessibilityHidden(true)
            OnboardingPage(
                title: AppLocalization.text("Echo — har qanday ilovada\nishlaydigan ovozdan matn."),
                subtitle: AppLocalization.text(
                    "Oddiy gapiring. Echo so‘zlaringizni kursor turgan joyga toza matn qilib yozadi: xabarlar, xatlar, hujjatlar va boshqalar."
                ), width: 560
            ) {
                Button(action: onStart) {
                    HStack(spacing: 12) {
                        Text(AppLocalization.text("Sozlashni boshlash"))
                        AppIcon(systemName: "arrow.right", size: 14)
                    }.frame(minWidth: 180)
                }
                .buttonStyle(OnboardingButtonStyle(height: 48))
                .keyboardShortcut(.defaultAction)
            }
        }
    }

    private var waveform: some View {
        HStack(spacing: 3) {
            ForEach(Array([10.0, 20, 30, 18, 10].enumerated()), id: \.offset) { _, height in
                Capsule().fill(OnboardingTheme.ink.opacity(0.3)).frame(width: 3, height: height)
            }
        }
    }
}

struct OnboardingSignIn: View {
    @Environment(\.onboardingCompact) private var compact
    let app: AppModel
    var body: some View {
        OnboardingPage(
            title: AppLocalization.text("Echo hisobingizni ulang"),
            subtitle: AppLocalization.text(
                "Hisobingiz bulutli transkripsiyani ochadi va tarixingizni bir joyda saqlaydi."),
            width: 640
        ) {
            OnboardingCard(padding: 28) {
                VStack(spacing: compact ? 12 : 20) {
                    if !compact {
                        Text(AppLocalization.text("Echo’ga kirish")).font(
                            .system(size: 24, weight: .semibold)
                        ).tracking(-0.5)
                    }
                    Text(
                        app.isSigningIn
                            ? AppLocalization.text(
                                "Brauzerda kirishni yakunlang. Tasdiqlangach, shu oynada davom etamiz.")
                            : AppLocalization.text(
                                "Hisobingizga kirish yoki ro‘yxatdan o‘tish brauzeringizda amalga oshiriladi."
                            )
                    )
                    .font(.system(size: 14)).lineSpacing(5).foregroundStyle(OnboardingTheme.muted)
                    if app.isSigningIn {
                        ProgressView().controlSize(.small)
                        Button(AppLocalization.text("Kirishni bekor qilish")) { app.cancelSignIn() }
                            .buttonStyle(OnboardingButtonStyle(variant: .ghost))
                    } else if let retryAt = app.signInRetryAt {
                        TimelineView(.periodic(from: .now, by: 1)) { context in
                            let seconds = max(0, Int(ceil(retryAt.timeIntervalSince(context.date))))
                            VStack(spacing: 10) {
                                Button {
                                } label: {
                                    Text(
                                        AppLocalization.text(
                                            "Qayta urinish · %@",
                                            String(format: "%d:%02d", seconds / 60, seconds % 60))
                                    )
                                    .monospacedDigit().frame(maxWidth: .infinity)
                                }
                                .buttonStyle(OnboardingButtonStyle(height: 48))
                                .disabled(true)
                                Text(
                                    AppLocalization.text(
                                        "Server belgilagan kutish vaqti tugagach davom etishingiz mumkin.")
                                )
                                .font(.caption).foregroundStyle(OnboardingTheme.muted)
                                .multilineTextAlignment(.center)
                            }
                        }
                    } else {
                        Button {
                            app.signIn()
                        } label: {
                            Text(AppLocalization.text("Brauzerda davom etish")).frame(maxWidth: .infinity)
                        }
                        .buttonStyle(OnboardingButtonStyle(height: 48))
                        .keyboardShortcut(.defaultAction)
                    }
                }.frame(maxWidth: .infinity)
            }.frame(maxWidth: 384)
            HStack(alignment: .top, spacing: 10) {
                benefit(
                    "cloud", AppLocalization.text("O‘zbek, rus va ingliz tillarida bulutli transkripsiya"))
                benefit(
                    "clock.arrow.circlepath",
                    AppLocalization.text("Diktovka tarixingiz hisobingizda saqlanadi"))
                benefit(
                    "checkmark.shield",
                    AppLocalization.text("Parolingiz desktop ilovaga hech qachon kirmaydi"))
            }.frame(maxWidth: 448).padding(.top, 4)
        }
    }
    private func benefit(_ symbol: String, _ text: String) -> some View {
        OnboardingCard(padding: 12) {
            VStack(spacing: 8) {
                OnboardingSymbol(name: symbol, size: 18)
                Text(text).font(.system(size: 12)).lineSpacing(3)
                    .foregroundStyle(OnboardingTheme.muted)
            }.frame(maxWidth: .infinity, minHeight: 76, alignment: .top)
        }
    }
}

struct OnboardingFinish: View {
    @Environment(\.dictationShortcut) private var shortcut
    var body: some View {
        OnboardingPage(
            title: AppLocalization.text("Endi Echo’ni boshqa ilovada sinab ko‘ring"),
            subtitle: AppLocalization.text("Qo‘shimcha sozlash shart emas."), width: 512
        ) {
            AppIcon(systemName: "party.popper", size: 34)
                .frame(width: 80, height: 80).background(OnboardingTheme.panel, in: Circle())
                .overlay(Circle().strokeBorder(OnboardingTheme.border))
            VStack(spacing: 10) {
                instruction(1, AppLocalization.text("Istalgan ilovani oching"), symbol: "macwindow")
                instruction(2, AppLocalization.text("Matn maydoniga bosing"), symbol: "text.cursor")
                instruction(
                    3, AppLocalization.text("%@ tugmasini bosib gapiring", shortcut.displayName),
                    symbol: "keyboard")
            }.frame(maxWidth: 448).padding(.top, 8)
            Text(
                AppLocalization.text(
                    "Echo menyu panelida turadi. Tarix va sozlamalarni ko‘rish uchun istalgan vaqt oching."
                )
            )
            .font(.system(size: 12)).lineSpacing(4).foregroundStyle(OnboardingTheme.muted)
            .frame(maxWidth: 448)
        }
    }
    private func instruction(_ number: Int, _ text: String, symbol: String) -> some View {
        OnboardingCard(padding: 12) {
            HStack(spacing: 16) {
                Text("\(number)").font(.system(size: 14, weight: .semibold))
                    .frame(width: 36, height: 36)
                    .foregroundStyle(OnboardingTheme.surface).background(OnboardingTheme.ink, in: Circle())
                Text(text).font(.system(size: 14, weight: .medium))
                    .frame(maxWidth: .infinity, alignment: .leading).multilineTextAlignment(.leading)
                AppIcon(systemName: symbol).foregroundStyle(OnboardingTheme.muted)
            }
        }
    }
}
