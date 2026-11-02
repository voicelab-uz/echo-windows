import SwiftUI
import VoiceLabCore

struct OnboardingPracticeIntro: View {
    @Environment(\.onboardingCompact) private var compact
    let onStart: () -> Void
    var body: some View {
        OnboardingPage(
            title: AppLocalization.text("Tugmalarni bosganingizda\nEcho tinglay boshlaydi"),
            subtitle: AppLocalization.text("Yana bosganingizda aytganlaringizni yozib qo‘yadi."), width: 512
        ) {
            OnboardingKeycaps(large: true)
                .frame(width: 320, height: compact ? 110 : 160)
                .background(OnboardingTheme.panel, in: Capsule())
                .overlay(Capsule().strokeBorder(OnboardingTheme.border))
            Button(AppLocalization.text("Sinab ko‘ring!"), action: onStart)
                .buttonStyle(OnboardingButtonStyle()).keyboardShortcut(.defaultAction)
                .padding(.top, 16)
            Text(
                AppLocalization.text(
                    "Mashqlar VoiceLab Cloud’dan foydalanadi va tarifingizdagi vaqtni sarflaydi. Ularni o‘tkazib yuborish mumkin."
                )
            )
            .font(.system(size: 12)).lineSpacing(4).foregroundStyle(OnboardingTheme.muted)
        }
    }
}

struct OnboardingPractice: View {
    @Environment(\.onboardingCompact) private var compact
    let model: OnboardingModel
    let dictation: DictationModel
    let step: OnboardingStep
    @Environment(\.dictationShortcut) private var shortcut
    @State private var confirmRetry = false

    var body: some View {
        OnboardingPage(
            title: title,
            subtitle: AppLocalization.text(
                "%@ tugmasini bosing, gapiring, tugatish uchun yana bosing.", shortcut.displayName),
            width: 576
        ) {
            practiceWindow.frame(maxWidth: 512)
            controls.frame(maxWidth: 512)
            Text(AppLocalization.text("Sinab ko‘ring: “%@”", sample))
                .font(.system(size: 12)).lineSpacing(4).foregroundStyle(OnboardingTheme.muted)
                .frame(maxWidth: 512)
            if let error = dictation.error {
                ErrorBanner(message: error)
                if dictation.canRetry {
                    HStack {
                        Button(AppLocalization.text("Audioni o‘chirish")) { dictation.discard() }
                        Button(AppLocalization.text("Qayta yuborish")) { confirmRetry = true }
                    }.buttonStyle(OnboardingButtonStyle(variant: .secondary, height: 32))
                }
            }
            Text(
                AppLocalization.text(
                    "Audio VoiceLab Cloud’ga yuboriladi. Tarif va tarixni saqlash sozlamalaringiz amal qiladi."
                )
            )
            .font(.system(size: 11)).foregroundStyle(OnboardingTheme.muted)
        }
        .confirmationDialog(AppLocalization.text("Audioni qayta yuborilsinmi?"), isPresented: $confirmRetry) {
            Button(AppLocalization.text("Qayta yuborish")) { dictation.retry() }
        } message: {
            Text(
                AppLocalization.text(
                    "Oldingi so‘rov bajarilgan bo‘lsa, qayta yuborish tarifingizdagi vaqtni yana sarflashi mumkin."
                )
            )
        }
    }

    private var practiceWindow: some View {
        VStack(spacing: 0) {
            HStack(spacing: 7) {
                ForEach(
                    [
                        Color(red: 1, green: 0.37, blue: 0.34),
                        Color(red: 1, green: 0.74, blue: 0.18),
                        Color(red: 0.16, green: 0.78, blue: 0.25),
                    ], id: \.self
                ) { color in
                    Circle().fill(color).frame(width: 10, height: 10)
                }
                AppLabel(context, systemImage: symbol).font(.system(size: 12, weight: .medium))
                    .foregroundStyle(OnboardingTheme.muted).padding(.leading, 6)
                Spacer()
            }.padding(.horizontal, 16).padding(.vertical, compact ? 8 : 12)
            Rectangle().fill(OnboardingTheme.border).frame(height: 1)
            if step == .tryEmail {
                emailRow("Kimga:", "Jasur")
                emailRow("Mavzu:", AppLocalization.text("Uchrashuv rejasi"))
            } else if step == .tryMessage {
                HStack(alignment: .bottom, spacing: 8) {
                    AppIcon(systemName: "person.fill", size: 13)
                        .frame(width: 28, height: 28).foregroundStyle(OnboardingTheme.surface)
                        .background(OnboardingTheme.ink, in: Circle())
                    Text(AppLocalization.text("Salom, Echo ishlayaptimi?")).font(.system(size: 14))
                        .padding(.horizontal, 14).padding(.vertical, 10)
                        .background(OnboardingTheme.panel, in: RoundedRectangle(cornerRadius: 16))
                    Spacer(minLength: 20)
                }.padding(.horizontal, 16).padding(.top, 16)
            } else {
                Text(AppLocalization.text("Bugungi rejalar")).font(.system(size: 16, weight: .semibold))
                    .frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 16).padding(
                        .top, 16)
            }
            VStack(alignment: .leading, spacing: 10) {
                Text(
                    dictation.result
                        ?? AppLocalization.text("%@ bosing va biror narsa ayting…", shortcut.displayName)
                )
                .font(.system(size: 14)).lineSpacing(5).textSelection(.enabled)
                .foregroundStyle(dictation.result == nil ? OnboardingTheme.muted : OnboardingTheme.ink)
                .frame(maxWidth: .infinity, minHeight: compact ? 40 : 74, alignment: .topLeading)
                .padding(compact ? 10 : 14)
                .background(OnboardingTheme.panel.opacity(0.5), in: RoundedRectangle(cornerRadius: 12))
                .overlay(
                    RoundedRectangle(cornerRadius: 12)
                        .strokeBorder(
                            dictation.phase == .recording ? OnboardingTheme.ink : OnboardingTheme.border))
                if dictation.result != nil {
                    AppLabel(
                        AppLocalization.text("Ajoyib! Matningiz tayyor."),
                        systemImage: "checkmark.circle.fill"
                    )
                    .font(.system(size: 12, weight: .medium)).foregroundStyle(OnboardingTheme.success)
                }
            }.padding(compact ? 10 : 16)
        }
        .multilineTextAlignment(.leading)
        .background(OnboardingTheme.surface, in: RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(OnboardingTheme.border))
        .clipShape(RoundedRectangle(cornerRadius: 12))
    }

    private func emailRow(_ label: String, _ value: String) -> some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                Text(label).foregroundStyle(OnboardingTheme.muted).frame(width: 56, alignment: .leading)
                Text(value).fontWeight(.medium)
                Spacer()
            }.font(.system(size: 14)).padding(.horizontal, 16).padding(.vertical, compact ? 6 : 8)
            Rectangle().fill(OnboardingTheme.border).frame(height: 1)
        }
    }

    private var controls: some View {
        HStack(spacing: 12) {
            OnboardingKeycaps()
            Spacer()
            if dictation.phase == .recording {
                Circle().fill(.red).frame(width: 6, height: 6)
                Text(Duration.seconds(dictation.recorder.elapsed).formatted(.time(pattern: .minuteSecond)))
                    .font(.system(size: 12)).monospacedDigit()
            }
            if dictation.phase == .transcribing || dictation.phase == .preparing {
                ProgressView().controlSize(.small)
                Button(AppLocalization.text("Bekor qilish")) { dictation.discard() }
                    .buttonStyle(OnboardingButtonStyle(variant: .secondary, height: 32))
            } else {
                Button(
                    dictation.phase == .recording
                        ? AppLocalization.text("Tugatish") : AppLocalization.text("Gapirib ko‘rish")
                ) {
                    dictation.togglePractice()
                }.buttonStyle(OnboardingButtonStyle(height: 32))
            }
        }
    }

    private var title: String {
        switch step {
        case .tryEmail: AppLocalization.text("Echo bilan xat yozing")
        case .tryList: AppLocalization.text("Ro‘yxat aytib ko‘ring")
        default: AppLocalization.text("Echo bilan xabar yozing")
        }
    }
    private var context: String {
        switch step {
        case .tryEmail: AppLocalization.text("Yangi xat")
        case .tryList: AppLocalization.text("Eslatmalar")
        default: AppLocalization.text("Xabarlar")
        }
    }
    private var symbol: String {
        switch step {
        case .tryEmail: "envelope"
        case .tryList: "list.bullet"
        default: "message"
        }
    }
    private var sample: String {
        switch (AppLocalization.shared.language.rawValue, step) {
        case ("en", .tryEmail):
            "Hello, I have reviewed the proposal. Could we discuss the next steps tomorrow morning?"
        case ("en", .tryList):
            "Today I need to finish the report, send the email, and plan tomorrow’s meeting."
        case ("en", _): "Hey, I’ll be there in ten minutes. Could you grab a coffee for me?"
        case ("ru", .tryEmail):
            "Здравствуйте! Я ознакомился с предложением. Можем обсудить следующие шаги завтра утром?"
        case ("ru", .tryList): "Сегодня нужно закончить отчёт, отправить письмо и подготовиться к встрече."
        case ("ru", _): "Привет! Буду через десять минут. Можешь заказать мне кофе?"
        case (_, .tryEmail):
            "Assalomu alaykum. Taklifingiz bilan tanishib chiqdim. Keyingi qadamlarni ertaga ertalab muhokama qilsak bo‘ladimi?"
        case (_, .tryList):
            "Bugun hisobotni tugatishim, email yuborishim va ertangi uchrashuvga tayyorlanishim kerak."
        default: "Salom! Men o‘n daqiqada yetib boraman. Menga ham bir qahva buyurtma qilib tur."
        }
    }
}
