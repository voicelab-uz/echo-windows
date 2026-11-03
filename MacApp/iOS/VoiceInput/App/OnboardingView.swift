import AuthenticationServices
import CryptoKit
import Security
import GoogleSignIn
import GoogleSignInSwift
import AVFoundation
import Observation
import SwiftUI
import UIKit

/// The iPhone setup follows Echo's desktop journey, with iOS keyboard permissions in
/// place of the Mac accessibility and shortcut steps.
struct OnboardingView: View {
    @AppStorage("echo.onboarding.completed") private var completed = false
    @AppStorage("echo.onboarding.step") private var savedStep = Step.welcome.rawValue
    @AppStorage("echo.dictation.language") private var preferredLanguage = DictationLanguage.auto.rawValue
    @AppStorage("echo.app.language") private var appLanguage = EchoAppLanguage.uzbek.rawValue
    @AppStorage("echo.uzbek.alphabet") private var uzbekAlphabet = "modern"
    @AppStorage("echo.onboarding.backendCompletionPending") private var backendCompletionPending = false

    @State private var account = EchoOnboardingAccount()
    @State private var questionnaire = EchoQuestionnaire()
    @State private var microphoneAllowed = false
    @AppStorage("echo.onboarding.keyboardConfirmed") private var keyboardConfirmed = false
    @State private var showsSettings = false
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @Environment(\.colorScheme) private var colorScheme
    @ScaledMetric(relativeTo: .headline) private var authButtonHeight = 56

    private var step: Step { Step(rawValue: savedStep) ?? .welcome }
    private var ui: EchoAppLanguage { EchoAppLanguage(rawValue: appLanguage) ?? .uzbek }
    private var questionCopy: EchoQuestionnaireCopy { EchoQuestionnaireCopy.forLanguage(appLanguage) }

    var body: some View {
        ZStack {
            EchoMobileTheme.canvas.ignoresSafeArea()
            if step == .welcome {
                welcomeScreen
            } else {
            VStack(spacing: 0) {
                header
                ProgressView(value: Double(step.stage + 1), total: 6)
                    .tint(.primary)
                    .padding(.horizontal, 26)
                ScrollView {
                    VStack(spacing: 20) {
                        page
                    }
                    .frame(maxWidth: 520)
                    .frame(maxWidth: .infinity)
                    .padding(.horizontal, 24)
                    .padding(.vertical, 24)
                }
                footer
            }
            }
        }
        .tint(.primary)
        .onChange(of: account.signInRevision) { _, _ in
            if step == .welcome || step == .account { go(to: .microphone) }
        }
        .sheet(isPresented: $showsSettings) { EchoSettingsView() }
        .sheet(isPresented: Binding(get: { account.showsLinkConfirmation }, set: { account.setLinkConfirmationPresented($0) }),
               onDismiss: { account.dismissLinkConfirmation() }) {
            NavigationStack {
                VStack(spacing: 20) {
                    Image(systemName: "person.badge.key.fill").font(.largeTitle).accessibilityHidden(true)
                    Text(account.linkConfirmationTitle).font(.title2.weight(.semibold)).multilineTextAlignment(.center)
                    Text(account.linkConfirmationMessage).font(.body).foregroundStyle(.secondary).multilineTextAlignment(.center)
                    Button(ui.text(uz: "Ulash va kirish", en: "Link and sign in", ru: "Связать и войти")) { account.confirmIdentityLink() }
                        .buttonStyle(EchoSetupButtonStyle())
                    Spacer(minLength: 0)
                }
                .padding(24)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button(ui.text(uz: "Bekor qilish", en: "Cancel", ru: "Отмена")) { account.cancelIdentityLink() }
                    }
                }
            }
            .presentationDetents([.medium, .large])
            .presentationDragIndicator(.visible)
        }
        .onDisappear { account.cancelPendingIdentityLinkIfNeeded() }
        .task {
            let shared = UserDefaults(suiteName: VoiceBridge.appGroup)
            let script = UzbekTranscriptScript.preferredScript(shared: shared)
            if script != .cyrillic { uzbekAlphabet = script.rawValue }
            else if let value = shared?.string(forKey: "echo.uzbek.alphabet") { uzbekAlphabet = value }
            refreshMicrophone()
            #if DEBUG
            if account.configureAuthLayoutProbe() { return }
            #endif
            await account.restore()
            if step == .account, account.signedIn != nil { go(to: .microphone) }
        }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active { refreshMicrophone() }
        }
        .onChange(of: uzbekAlphabet) { _, alphabet in
            let shared = UserDefaults(suiteName: VoiceBridge.appGroup)
            shared?.set(alphabet, forKey: "echo.uzbek.alphabet")
            if UzbekTranscriptScript.preferredScript(shared: shared) != .cyrillic {
                shared?.set(alphabet, forKey: "echo.dictation.uzbekScript")
                UserDefaults.standard.set(alphabet, forKey: "echo.dictation.uzbekScript")
            }
        }
        .task(id: step) {
            if step == .questions { await questionnaire.load() }
        }
    }

    private var welcomeScreen: some View {
        GeometryReader { viewport in
            ScrollView {
                VStack(spacing: 0) {
                    ZStack {
                        HStack(spacing: 10) {
                            Image("EchoLogo")
                                .resizable().scaledToFit()
                                .frame(width: 36, height: 36)
                                .clipShape(RoundedRectangle(cornerRadius: 10))
                            Text("Echo").font(.title2.weight(.semibold))
                        }
                        .accessibilityElement(children: .combine)
                        HStack {
                            Spacer()
                            Button { showsSettings = true } label: {
                                Image(systemName: "gearshape")
                                    .font(.body).foregroundStyle(.secondary)
                                    .frame(width: 44, height: 44)
                            }
                            .accessibilityLabel(ui.text(uz: "Sozlamalar", en: "Settings", ru: "Настройки"))
                        }
                    }
                    .padding(.top, 12)

                    Spacer(minLength: 40)

                    VStack(spacing: 16) {
                        Text(ui.text(uz: "Fikrlaringizni ovoz bilan yozing.", en: "Turn your thoughts into words.", ru: "Превратите мысли в слова."))
                            .font(.largeTitle.weight(.semibold))
                            .foregroundStyle(EchoMobileTheme.ink)
                            .fixedSize(horizontal: false, vertical: true)
                            .accessibilityAddTraits(.isHeader)
                        Text(ui.text(uz: "Xabarlar, qaydlar va har kungi fikrlar uchun.", en: "For messages, notes, and everyday ideas.", ru: "Для сообщений, заметок и повседневных идей."))
                            .font(.body)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 420)

                    Spacer(minLength: 44)

                    VStack(spacing: 16) {
                        if let signedIn = account.signedIn {
                            Label(signedIn.name, systemImage: "checkmark.circle")
                                .font(.subheadline)
                            Button { go(to: .microphone) } label: {
                                Text(ui.text(uz: "Davom etish", en: "Continue", ru: "Продолжить"))
                                    .frame(maxWidth: .infinity, minHeight: authButtonHeight - 20)
                            }
                            .buttonStyle(EchoSetupButtonStyle())
                        } else {
                            signInOptions
                        }
                        Text(ui.text(uz: "Ovoz faqat diktovkada saqlanadi. Klaviatura seansi mikrofonni tayyor tutadi va 5 daqiqa ishlatilmasa o‘chadi.", en: "Only dictated audio is saved. Keyboard sessions keep the microphone ready and end after 5 idle minutes.", ru: "Сохраняется только звук диктовки. Сеанс клавиатуры держит микрофон готовым и завершается через 5 минут бездействия."))
                            .font(.footnote).foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                            .padding(.top, 6)
                    }
                    .multilineTextAlignment(.center)
                    .padding(.bottom, 12)
                }
                .padding(.horizontal, 24)
                .padding(.vertical, 20)
                .frame(maxWidth: 520)
                .frame(minHeight: viewport.size.height)
                .frame(maxWidth: .infinity)
            }
            .scrollBounceBehavior(.basedOnSize)
        }
    }

    private var signInOptions: some View {
        TimelineView(.periodic(from: .now, by: 1)) { context in
            signInButtons(at: context.date)
                .onChange(of: context.date, initial: true) { _, date in
                    account.clearExpiredRateLimit(at: date)
                    account.clearExpiredIdentityLink(at: date)
                }
        }
    }

    private func signInButtons(at date: Date) -> some View {
        let unavailable = account.isBusy || account.showsLinkConfirmation || (account.retryAfter.map { $0 > date } ?? false)
        return VStack(spacing: 12) {
            if let requirement = account.linkRequirement {
                VStack(alignment: .leading, spacing: 10) {
                    Label(ui.text(uz: "Mavjud hisobingizni tasdiqlang", en: "Confirm your existing account", ru: "Подтвердите существующий аккаунт"), systemImage: "person.badge.key")
                        .font(.subheadline.weight(.semibold))
                    Text(account.linkExplanation).font(.subheadline).foregroundStyle(.secondary)
                    Text(ui.text(uz: "Tasdiqlangach, \(requirement.providerToLink.name) orqali ham shu hisobga kira olasiz.", en: "Once confirmed, you can also use \(requirement.providerToLink.name) to sign in to this account.", ru: "После подтверждения вы сможете входить в этот аккаунт и через \(requirement.providerToLink.name)."))
                        .font(.caption).foregroundStyle(.secondary)
                    Button(ui.text(uz: "Bekor qilish", en: "Cancel linking", ru: "Отменить связывание")) { account.cancelIdentityLink() }
                        .frame(minHeight: 44).disabled(account.isBusy)
                }
                .frame(maxWidth: .infinity, alignment: .leading).padding(16)
                .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16))
            }
            if account.offersSignIn(.google) {
            if let googleIcon = EchoGoogleBrand.icon {
                Button(action: account.signInWithGoogle) {
                    EchoGoogleSignInLabel(icon: Image(uiImage: googleIcon), title: account.googleActionTitle,
                                          isBusy: account.isBusy, height: authButtonHeight)
                }
                .buttonStyle(EchoGoogleAuthButtonStyle())
                .disabled(unavailable)
            } else {
                // Preserve the SDK's official branding if its resource bundle moves.
                GoogleSignInButton(style: .wide, state: unavailable ? .disabled : .normal,
                                   action: { account.signInWithGoogle() })
                    .frame(maxWidth: .infinity).frame(height: authButtonHeight)
                    .disabled(unavailable)
            }
            }

            if account.offersSignIn(.apple) {
            SignInWithAppleButton(.continue) { request in
                account.prepareAppleSignIn(request)
            } onCompletion: { result in
                account.completeAppleSignIn(result)
            }
            .signInWithAppleButtonStyle(colorScheme == .dark ? .white : .black)
            .frame(maxWidth: .infinity)
            .frame(height: authButtonHeight)
            .clipShape(RoundedRectangle(cornerRadius: 16))
            .disabled(unavailable)
            .accessibilityLabel(account.appleActionTitle)
            if account.linkRequirement != nil {
                Text(account.appleActionTitle).font(.caption).foregroundStyle(.secondary)
            }
            }

            EchoAuthStatusRegion(isBusy: account.isBusy, error: account.error,
                                 loadingText: ui.text(uz: "Kirilmoqda…", en: "Signing in…", ru: "Выполняется вход…"))
        }
    }

    private var header: some View {
        HStack(spacing: 10) {
            Image("EchoLogo")
                .resizable()
                .scaledToFit()
                .frame(width: 28, height: 28)
                .clipShape(RoundedRectangle(cornerRadius: 8))
            Text("Echo")
                .font(.headline)
            Spacer()
            Button { showsSettings = true } label: {
                Image(systemName: "gearshape")
                    .font(.body)
                    .frame(width: 44, height: 44)
            }
            .accessibilityLabel(ui.text(uz: "Til va klaviatura sozlamalari", en: "Language and keyboard settings", ru: "Настройки языка и клавиатуры"))
            if step != .welcome {
                Text("\(step.stage + 1)/6")
                    .font(.subheadline.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 24)
        .frame(minHeight: 56)
    }

    @ViewBuilder private var page: some View {
        switch step {
        case .welcome:
            EmptyView()
        case .account:
            icon("person.crop.circle", color: .indigo)
            heading(ui.text(uz: "Echo hisobingizni ulang", en: "Connect your Echo account", ru: "Подключите аккаунт Echo"), subtitle: ui.text(uz: "Ovoz transkripsiyasi uchun Echo hisobiga kirish kerak.", en: "Sign in to transcribe speech.", ru: "Войдите, чтобы преобразовывать речь в текст."))
            card {
                if let signedIn = account.signedIn {
                    Label(signedIn.name, systemImage: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                        .frame(maxWidth: .infinity, alignment: .leading)
                } else {
                    signInOptions
                }
            }
        case .microphone:
            icon("mic", color: .indigo)
            heading(ui.text(uz: "Mikrofonga ruxsat bering", en: "Allow microphone access", ru: "Разрешите доступ к микрофону"), subtitle: ui.text(uz: "Klaviatura Echo’ni qayta ochmasdan ishlashi uchun mikrofon diktovkalar orasida tayyor turadi. Faqat diktovka ovozi saqlanadi. Seansni istalgan payt tugatishingiz yoki sozlamalarda har yozuvdan keyin o‘chirishni tanlashingiz mumkin.", en: "Keyboard sessions keep the microphone ready between dictations so Echo does not reopen for each one. Only dictated audio is saved. End the session anytime, or choose to turn the microphone off after each recording in Settings.", ru: "Сеанс держит микрофон готовым между диктовками, чтобы Echo не открывался каждый раз. Сохраняется только звук диктовки. Завершите сеанс в любой момент или выберите отключение после каждой записи в настройках."))
            card {
                Label(microphoneAllowed ? ui.text(uz: "Mikrofon tayyor", en: "Microphone ready", ru: "Микрофон готов") : ui.text(uz: "Mikrofon ruxsati kerak", en: "Microphone permission needed", ru: "Нужен доступ к микрофону"), systemImage: microphoneAllowed ? "checkmark.circle.fill" : "mic")
                    .foregroundStyle(microphoneAllowed ? Color.green : Color.primary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                if !microphoneAllowed {
                    Button(action: requestMicrophone) {
                        Text(ui.text(uz: "Mikrofonga ruxsat berish", en: "Allow microphone", ru: "Разрешить микрофон"))
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(EchoSetupButtonStyle())
                }
            }
        case .keyboard:
            icon("keyboard", color: .indigo)
            heading(ui.text(uz: "Echo klaviaturasini yoqing", en: "Enable the Echo keyboard", ru: "Включите клавиатуру Echo"), subtitle: ui.text(uz: "Boshqa ilovalarning matn maydoniga ovoz bilan yozish uchun klaviaturani tanlang.", en: "Select it to dictate into text fields in other apps.", ru: "Выберите её для диктовки в других приложениях."))
            card {
                instruction(1, "Settings → General → Keyboard → Keyboards")
                instruction(2, "Add New Keyboard → Echo")
                instruction(3, "Echo → Allow Full Access")
                Text(ui.text(uz: "Full Access klaviatura va Echo ilovasi orasida matn almashish uchun kerak. Uni yoqqach, Echo’ga qayting va pastdagi tasdiqni belgilang.", en: "Full Access lets the keyboard exchange text with Echo. After enabling it, return here and check the confirmation below.", ru: "Полный доступ нужен для обмена текстом с Echo. Включите его, вернитесь сюда и отметьте подтверждение ниже."))
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .padding(.top, 4)
                Button {
                    guard let url = URL(string: UIApplication.openSettingsURLString) else { return }
                    UIApplication.shared.open(url)
                } label: {
                    Text(ui.text(uz: "Sozlamalarni ochish", en: "Open Settings", ru: "Открыть настройки"))
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(EchoSetupButtonStyle(secondary: true))
                Toggle(ui.text(uz: "Klaviaturani yoqdim va Full Access berdim", en: "I enabled the keyboard and Full Access", ru: "Я включил клавиатуру и полный доступ"), isOn: $keyboardConfirmed)
                    .font(.subheadline)
                    .padding(.top, 4)
            }
        case .language:
            icon("globe", color: .indigo)
            heading(ui.text(uz: "Tilingizni tanlang", en: "Choose your languages", ru: "Выберите языки"), subtitle: ui.text(uz: "Echo o‘zbek, rus va ingliz tillaridagi nutqni taniydi. Keyin ham o‘zgartira olasiz.", en: "Echo recognizes Uzbek, Russian, and English. You can change these later.", ru: "Echo распознаёт узбекский, русский и английский. Вы сможете изменить выбор позже."))
            card {
                Picker(ui.text(uz: "Diktovka tili", en: "Dictation language", ru: "Язык диктовки"), selection: $preferredLanguage) {
                    Text(ui.text(uz: "Avtomatik", en: "Auto-detect", ru: "Автоопределение")).tag(DictationLanguage.auto.rawValue)
                    Text("O‘zbekcha").tag(DictationLanguage.uzbek.rawValue)
                    Text("Русский").tag(DictationLanguage.russian.rawValue)
                    Text("English").tag(DictationLanguage.english.rawValue)
                }
                .pickerStyle(.menu)
                .frame(maxWidth: .infinity, alignment: .leading)
                Divider()
                Text(ui.text(uz: "O‘zbekcha alifbo", en: "Uzbek alphabet", ru: "Узбекский алфавит"))
                    .font(.headline)
                Picker(ui.text(uz: "O‘zbekcha alifbo", en: "Uzbek alphabet", ru: "Узбекский алфавит"), selection: $uzbekAlphabet) {
                    Text(ui.text(uz: "Amaldagi: Oʻ, Gʻ, Sh, Ch", en: "Current: Oʻ, Gʻ, Sh, Ch", ru: "Текущий: Oʻ, Gʻ, Sh, Ch")).tag("current")
                    Text(ui.text(uz: "Yangi: Ö, Ğ, Ş, Ç", en: "New: Ö, Ğ, Ş, Ç", ru: "Новый: Ö, Ğ, Ş, Ç")).tag("modern")
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                Text(uzbekAlphabet == "modern" ? "Özbekiston, ğoya, şahar, çiroyli" : "Oʻzbekiston, gʻoya, shahar, chiroyli")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        case .questions:
            icon("list.clipboard", color: .indigo)
            heading(ui.text(uz: "Echo’ni sizga moslaymiz", en: "Make Echo yours", ru: "Настроим Echo для вас"), subtitle: ui.text(uz: "Ixtiyoriy savollar. Javob bering yoki qolganlarini bir marta o‘tkazib yuboring.", en: "Optional questions. Answer them or skip the remaining questions in one step.", ru: "Необязательные вопросы. Ответьте или пропустите оставшиеся одним нажатием."))
            if questionnaire.isBusy && !questionnaire.isLoaded {
                ProgressView(questionCopy.loading)
            } else if !questionnaire.isLoaded {
                card {
                    Text(questionnaire.error ?? questionCopy.loadError)
                        .font(.subheadline).foregroundStyle(.red)
                    Button { Task { await questionnaire.load() } } label: {
                        Text(questionCopy.retry).frame(maxWidth: .infinity)
                    }
                    .buttonStyle(EchoSetupButtonStyle(secondary: true))
                }
            } else if questionnaire.isFinished {
                card { Label(ui.text(uz: "Javoblar saqlandi", en: "Answers saved", ru: "Ответы сохранены"), systemImage: "checkmark.circle.fill").foregroundStyle(.green) }
            } else {
                card {
                    Text("\(questionnaire.index + 1)/\(EchoQuestionnaire.questions.count)")
                        .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                    Text(questionCopy.headings[questionnaire.index]).font(.headline)
                    ForEach(questionnaire.question.options, id: \.id) { option in
                        Button {
                            questionnaire.toggle(option.id)
                        } label: {
                            HStack {
                                Text(questionCopy.option(question: questionnaire.question.id, id: option.id, fallback: option.title))
                                Spacer()
                                Image(systemName: questionnaire.isSelected(option.id) ? "checkmark.circle.fill" : "circle")
                            }
                            .frame(maxWidth: .infinity, minHeight: 48)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .foregroundStyle(questionnaire.isSelected(option.id) ? .indigo : .primary)
                        .disabled(questionnaire.isBusy)
                    }
                    if questionnaire.isSelected("other") {
                        TextField(questionCopy.otherPrompt, text: $questionnaire.other)
                            .textFieldStyle(.roundedBorder)
                    }
                    if let error = questionnaire.error {
                        Text(error).font(.footnote).foregroundStyle(.red)
                    }
                }
            }
        case .practice:
            icon("checkmark", color: .green)
            heading(ui.text(uz: "Hammasi tayyor", en: "Ready to go", ru: "Всё готово"), subtitle: ui.text(uz: "Echo’ni sinab ko‘ring: Notes sahifasida mikrofonni bosing yoki boshqa ilovada Echo klaviaturasini tanlang.", en: "Try Echo in Notes or select the Echo keyboard in another app.", ru: "Попробуйте Echo в заметках или выберите клавиатуру Echo в другом приложении."))
            card {
                instruction(1, ui.text(uz: "Matn maydoniga bosing", en: "Tap a text field", ru: "Нажмите на текстовое поле"))
                instruction(2, ui.text(uz: "Echo klaviaturasidagi mikrofonni bosing", en: "Tap the microphone on the Echo keyboard", ru: "Нажмите на микрофон клавиатуры Echo"))
                instruction(3, ui.text(uz: "Gapiring va tayyor bo‘lgach ✓ ni bosing", en: "Speak, then tap ✓ when done", ru: "Говорите, затем нажмите ✓"))
            }
        }
    }

    private var footer: some View {
        let layout = dynamicTypeSize.isAccessibilitySize
            ? AnyLayout(VStackLayout(spacing: 12))
            : AnyLayout(HStackLayout(spacing: 12))
        return layout {
            if step != .welcome {
                Button(ui.text(uz: "Orqaga", en: "Back", ru: "Назад")) {
                    if step == .questions && questionnaire.index > 0 { questionnaire.back() }
                    else if step == .microphone && account.signedIn != nil { go(to: .welcome) }
                    else { go(to: Step.allCases[step.index - 1]) }
                }
                    .buttonStyle(EchoSetupButtonStyle(secondary: true))
                    .disabled(account.isBusy || questionnaire.isBusy)
            }
            if !dynamicTypeSize.isAccessibilitySize { Spacer(minLength: 0) }
            if step == .questions && !questionnaire.isFinished {
                Button(ui.text(uz: "O‘tkazish", en: "Skip", ru: "Пропустить")) {
                    Task {
                        await questionnaire.skipRemaining(uiLanguage: appLanguage)
                        if questionnaire.isFinished { go(to: .practice) }
                    }
                }
                .buttonStyle(EchoSetupButtonStyle(secondary: true))
                .disabled(questionnaire.isBusy || !questionnaire.isLoaded)
                .accessibilityLabel(ui.text(uz: "Qolgan ixtiyoriy savollarni o‘tkazib yuborish", en: "Skip remaining optional questions", ru: "Пропустить оставшиеся необязательные вопросы"))
            }
            Button(step == .practice ? ui.text(uz: "Sinab ko‘rish", en: "Try it", ru: "Попробовать") : ui.text(uz: "Davom etish", en: "Continue", ru: "Продолжить")) {
                if step == .practice {
                    backendCompletionPending = true
                    completed = true
                } else if step == .questions {
                    if questionnaire.isFinished { go(to: .practice) }
                    else { Task { await advanceQuestion(skipping: false) } }
                } else {
                    go(to: Step.allCases[step.index + 1])
                }
            }
            .buttonStyle(EchoSetupButtonStyle())
            .disabled(!canContinue || account.isBusy || questionnaire.isBusy)
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 16)
        .background(Color(uiColor: .systemBackground))
        .overlay(alignment: .top) { Divider() }
    }

    private var canContinue: Bool {
        switch step {
        case .account: account.signedIn != nil
        case .microphone: microphoneAllowed
        case .keyboard: keyboardConfirmed
        case .questions: questionnaire.isFinished || questionnaire.canAdvance
        default: true
        }
    }

    private func advanceQuestion(skipping: Bool) async {
        await questionnaire.advance(skipping: skipping, uiLanguage: appLanguage)
        if questionnaire.isFinished { go(to: .practice) }
    }

    private func go(to next: Step) { savedStep = next.rawValue }

    private func refreshMicrophone() {
        microphoneAllowed = AVCaptureDevice.authorizationStatus(for: .audio) == .authorized
    }

    private func requestMicrophone() {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .notDetermined:
            Task { @MainActor in
                _ = await AVCaptureDevice.requestAccess(for: .audio)
                refreshMicrophone()
            }
        case .denied, .restricted:
            guard let url = URL(string: UIApplication.openSettingsURLString) else { return }
            UIApplication.shared.open(url)
        case .authorized: refreshMicrophone()
        @unknown default: break
        }
    }

    private func heading(_ title: String, subtitle: String) -> some View {
        VStack(spacing: 10) {
            Text(title).font(.title2.weight(.semibold))
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityAddTraits(.isHeader)
                .multilineTextAlignment(.center)
            Text(subtitle).font(.subheadline).foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .accessibilityElement(children: .combine)
    }

    private func icon(_ name: String, color: Color) -> some View {
        Image(systemName: name)
            .font(.title2.weight(.medium))
            .foregroundStyle(color == .green ? Color.green : Color.primary)
            .frame(width: 48, height: 48)
            .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 14))
            .accessibilityHidden(true)
    }

    private func card<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 16, content: content)
            .padding(18)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(EchoMobileTheme.surface, in: RoundedRectangle(cornerRadius: 18))
            .overlay(RoundedRectangle(cornerRadius: 18).strokeBorder(Color.primary.opacity(0.08)))
    }

    private func instruction(_ number: Int, _ text: String) -> some View {
        HStack(alignment: .top, spacing: 14) {
            Text("\(number)")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.white)
                .frame(width: 28, height: 28)
                .background(.indigo, in: Circle())
            Text(text).font(.subheadline).frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private enum Step: String, CaseIterable {
        case welcome, account, microphone, keyboard, language, questions, practice
        var index: Int { Self.allCases.firstIndex(of: self)! }
        // Welcome and its optional account page share one stage.
        var stage: Int { max(0, index - 1) }
    }
}

/// Busy/error changes happen inside reserved slots rather than changing the
/// auth stack height and redistributing the welcome screen's flexible spacers.
private struct EchoAuthStatusRegion: View {
    let isBusy: Bool
    let error: String?
    let loadingText: String
    @ScaledMetric(relativeTo: .footnote) private var statusHeight = 22
    @ScaledMetric(relativeTo: .footnote) private var errorHeight = 72
    var body: some View {
        VStack(spacing: 8) {
            ZStack {
                Color.clear
                if isBusy {
                    HStack(spacing: 8) {
                        ProgressView().controlSize(.small)
                        Text(loadingText).font(.footnote).lineLimit(1)
                    }
                }
            }
            .frame(height: statusHeight)
            .accessibilityHidden(!isBusy)
            ScrollView(.vertical, showsIndicators: false) {
                Text(error ?? "").font(.footnote).foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity)
            }
            .frame(height: errorHeight)
            .scrollBounceBehavior(.basedOnSize)
            .accessibilityHidden(error == nil)
        }
    }
}

private struct EchoGoogleSignInLabel: View {
    let icon: Image
    let title: String
    let isBusy: Bool
    let height: CGFloat
    var body: some View {
        HStack(spacing: 12) {
            icon.renderingMode(.original).resizable().scaledToFit()
                .frame(width: 22, height: 22).accessibilityHidden(true)
            Text(title).font(.headline).lineLimit(2).minimumScaleFactor(0.85)
                .multilineTextAlignment(.center).frame(maxWidth: .infinity)
            ZStack {
                Color.clear
                if isBusy { ProgressView().controlSize(.small) }
            }.frame(width: 22, height: 22).accessibilityHidden(true)
        }
        .padding(.horizontal, 18).padding(.vertical, 8)
        .frame(maxWidth: .infinity).frame(height: height)
    }
}

/// Reuse Google's unmodified multicolor asset from the installed official SDK.
@MainActor
private enum EchoGoogleBrand {
    static let icon: UIImage? = {
        for parent in [Bundle.main, Bundle(for: GIDSignIn.self)] {
            for name in ["GoogleSignIn_GoogleSignIn", "GoogleSignIn"] {
                guard let url = parent.url(forResource: name, withExtension: "bundle"),
                      let bundle = Bundle(url: url) else { continue }
                if let icon = UIImage(named: "google", in: bundle, compatibleWith: nil) { return icon }
            }
        }
        return nil
    }()
}

private struct EchoGoogleAuthButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .foregroundStyle(EchoMobileTheme.ink)
            .background(Color(uiColor: .systemBackground), in: RoundedRectangle(cornerRadius: 16))
            .overlay(RoundedRectangle(cornerRadius: 16).strokeBorder(EchoMobileTheme.ink.opacity(0.28), lineWidth: 1))
            .contentShape(RoundedRectangle(cornerRadius: 16))
            .opacity(isEnabled ? (configuration.isPressed ? 0.72 : 1) : 0.45)
    }
}

private struct EchoSetupButtonStyle: ButtonStyle {
    var secondary = false
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.subheadline.weight(.semibold))
            .multilineTextAlignment(.center)
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            .frame(minHeight: 48)
            .foregroundStyle(secondary ? EchoMobileTheme.ink : Color(uiColor: .systemBackground))
            .background(secondary ? EchoMobileTheme.ink.opacity(isEnabled ? 0.025 : 0.045) : EchoMobileTheme.ink,
                        in: RoundedRectangle(cornerRadius: 12))
            .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(secondary ? EchoMobileTheme.ink.opacity(0.14) : .clear))
            .contentShape(RoundedRectangle(cornerRadius: 12))
            // Color-only feedback avoids moving adjacent controls or changing layout.
            .opacity(isEnabled ? (configuration.isPressed ? 0.72 : 1) : 0.55)
    }
}

@MainActor @Observable
private final class EchoOnboardingAccount {
    private(set) var signedIn: EchoAccount?
    private(set) var signInRevision = 0
    private(set) var isBusy = false
    private(set) var error: String?
    private(set) var retryAfter: Date?
    @ObservationIgnored private var rateLimitWarning: String?
    private(set) var linkRequirement: EchoIdentityLinkRequirement?
    private(set) var showsLinkConfirmation = false
    @ObservationIgnored private var authAttempt = UUID()
    @ObservationIgnored private var pendingApple: (nonce: String, state: String, linking: UUID?, attempt: UUID)?
    @ObservationIgnored private var linkConfirmation: (provider: EchoIdentityProvider, token: String, nonce: String?, name: String?, requirementID: UUID)?

    private var ui: EchoAppLanguage {
        EchoAppLanguage(rawValue: UserDefaults.standard.string(forKey: "echo.app.language") ?? "uz") ?? .uzbek
    }

    func offersSignIn(_ provider: EchoIdentityProvider) -> Bool {
        linkRequirement.map { $0.existingProviders.contains(provider) } ?? true
    }
    var googleActionTitle: String {
        guard let linkRequirement else { return ui.text(uz: "Google bilan davom etish", en: "Continue with Google", ru: "Продолжить с Google") }
        return ui.text(uz: "Google bilan kirish va \(linkRequirement.providerToLink.name)’ni ulash", en: "Sign in with Google and link \(linkRequirement.providerToLink.name)", ru: "Войти с Google и подключить \(linkRequirement.providerToLink.name)")
    }
    var appleActionTitle: String {
        guard let linkRequirement else { return ui.text(uz: "Apple bilan davom etish", en: "Continue with Apple", ru: "Продолжить с Apple") }
        return ui.text(uz: "Apple bilan kirish va \(linkRequirement.providerToLink.name)’ni ulash", en: "Sign in with Apple and link \(linkRequirement.providerToLink.name)", ru: "Войти с Apple и подключить \(linkRequirement.providerToLink.name)")
    }
    var linkExplanation: String {
        let methods = linkRequirement?.existingProviders.map(\.name).joined(separator: " / ") ?? ""
        return ui.text(uz: "Avval ishlatgan \(methods) hisobingiz bilan kiring. Kirish usulini ulashdan oldin tasdiqlashingizni so‘raymiz.", en: "Sign in with the \(methods) account you used before. You will confirm before the second sign-in method is linked.", ru: "Войдите через ранее использованный аккаунт \(methods). Перед подключением второго способа входа мы попросим подтверждение.")
    }
    var linkConfirmationTitle: String {
        let name = linkRequirement?.providerToLink.name ?? ""
        return ui.text(uz: "\(name)’ni shu hisobga ulaysizmi?", en: "Link \(name) to this account?", ru: "Подключить \(name) к этому аккаунту?")
    }
    var linkConfirmationMessage: String {
        let existing = linkConfirmation?.provider.name ?? ""
        let incoming = linkRequirement?.providerToLink.name ?? ""
        return ui.text(uz: "\(existing) bilan tasdiqlangan hisobga \(incoming) kirish usuli qo‘shiladi.", en: "\(incoming) will be added as a sign-in method to the account confirmed with \(existing).", ru: "\(incoming) будет добавлен к аккаунту, подтверждённому через \(existing), как способ входа.")
    }
    func clearExpiredIdentityLink(at now: Date = .now) {
        guard !isBusy, linkRequirement?.isExpired(at: now) == true else { return }
        cancelIdentityLink()
        error = identityLinkMessage(.expired)
    }
    // SwiftUI may set presentation=false before invoking a button action.
    // Only onDismiss clears an unconsumed proof; confirmation consumes it first.
    func setLinkConfirmationPresented(_ value: Bool) { showsLinkConfirmation = value }
    func dismissLinkConfirmation() {
        if !isBusy && linkConfirmation != nil { cancelIdentityLink() }
    }
    func cancelPendingIdentityLinkIfNeeded() {
        if linkRequirement != nil || linkConfirmation != nil { cancelIdentityLink() }
    }
    func cancelIdentityLink() {
        let id = linkRequirement?.id
        authAttempt = UUID()
        linkRequirement = nil; linkConfirmation = nil; showsLinkConfirmation = false; pendingApple = nil
        isBusy = false; error = nil
        if let id { Task { await EchoAuthClient.shared.cancelIdentityLink(id) } }
    }
    func confirmIdentityLink() {
        guard !isBusy, let proof = linkConfirmation, let requirement = linkRequirement,
              requirement.id == proof.requirementID else { return }
        guard !requirement.isExpired() else { clearExpiredIdentityLink(); return }
        linkConfirmation = nil; showsLinkConfirmation = false; isBusy = true; error = nil
        authAttempt = UUID()
        let attempt = authAttempt
        Task { @MainActor in
            defer {
                if authAttempt == attempt { isBusy = false; linkRequirement = nil; linkConfirmation = nil; showsLinkConfirmation = false }
                Task { await EchoAuthClient.shared.cancelIdentityLink(proof.requirementID) }
            }
            do {
                let account: EchoAccount
                switch proof.provider {
                case .google:
                    account = try await EchoAuthClient.shared.signInWithGoogle(idToken: proof.token, linking: proof.requirementID)
                case .apple:
                    account = try await EchoAuthClient.shared.signInWithApple(idToken: proof.token, nonce: proof.nonce ?? "", fullName: proof.name, linking: proof.requirementID)
                }
                guard authAttempt == attempt else { return }
                signedIn = account; signInRevision += 1
            } catch {
                guard authAttempt == attempt else { return }
                self.error = rateLimitMessage(for: error) ?? (error as? EchoIdentityLinkError).map(identityLinkMessage)
                    ?? ui.text(uz: "Hisobni ulash yakunlanmadi. Qayta kirib urinib ko‘ring.", en: "Linking could not be completed. Sign in and try again.", ru: "Не удалось связать способы входа. Войдите и повторите.")
            }
        }
    }
    private func handleLinkRequirement(_ failure: Error) -> Bool {
        guard let required = failure as? EchoIdentityLinkRequired else { return false }
        linkRequirement = required.requirement; error = nil
        return true
    }
    private func identityLinkMessage(_ failure: EchoIdentityLinkError) -> String {
        switch failure {
        case .expired, .invalidProof:
            ui.text(uz: "Xavfsiz ulash so‘rovi eskirgan. Kirishni boshidan qayta boshlang.", en: "The secure linking request expired. Start sign-in again.", ru: "Запрос безопасного связывания истёк. Начните вход заново.")
        case .identityAlreadyLinked:
            ui.text(uz: "Bu kirish usuli boshqa hisobga ulangan. O‘sha hisob orqali kiring yoki yordam xizmatiga murojaat qiling.", en: "This sign-in identity belongs to another account. Use that account or contact support.", ru: "Этот способ входа связан с другим аккаунтом. Войдите в него или обратитесь в поддержку.")
        case .unsupportedProvider:
            ui.text(uz: "Mavjud hisobning kirish usulini ilovada tasdiqlab bo‘lmadi. Yordam xizmatiga murojaat qiling.", en: "This account’s existing sign-in method cannot be confirmed in the app. Contact support.", ru: "Существующий способ входа нельзя подтвердить в приложении. Обратитесь в поддержку.")
        case .canceled:
            ui.text(uz: "Ulash bekor qilindi. Qayta boshlashingiz mumkin.", en: "Linking was canceled. You can start again.", ru: "Связывание отменено. Можно начать заново.")
        }
    }

    #if DEBUG
    /// UI geometry fixture only: no SDK calls, auth requests or stored credentials.
    func configureAuthLayoutProbe() -> Bool {
        let arguments = ProcessInfo.processInfo.arguments
        guard let index = arguments.firstIndex(of: "--echo-auth-layout-state"), index + 1 < arguments.count,
              ["idle", "busy", "error"].contains(arguments[index + 1]) else { return false }
        let state = arguments[index + 1]
        signedIn = nil
        isBusy = state == "busy"
        error = state == "error" ? ui.text(uz: "Urinishlar juda ko‘p. Biroz kutib, qayta urinib ko‘ring.", en: "Too many sign-in attempts. Wait a moment and try again.", ru: "Слишком много попыток входа. Подождите и попробуйте снова.") : nil
        retryAfter = state == "error" ? .now.addingTimeInterval(30) : nil
        return true
    }
    #endif

    func clearExpiredRateLimit(at date: Date = .now) {
        guard let deadline = retryAfter, deadline <= date else { return }
        retryAfter = nil
        if let rateLimitWarning, error == rateLimitWarning { error = nil }
        rateLimitWarning = nil
    }

    func restore() async {
        guard signedIn == nil, !isBusy else { return }
        let revision = signInRevision
        do {
            let restored = try await EchoAuthClient.shared.restore()
            guard !isBusy, signInRevision == revision else { return }
            signedIn = restored
        } catch {
            guard !isBusy, signInRevision == revision else { return }
            self.error = error.localizedDescription
        }
    }

    func prepareAppleSignIn(_ request: ASAuthorizationAppleIDRequest) {
        let wasLinking = linkRequirement != nil
        clearExpiredRateLimit(); clearExpiredIdentityLink()
        if wasLinking && linkRequirement == nil { return }
        guard !isBusy, !showsLinkConfirmation, retryAfter.map({ $0 <= .now }) ?? true else { return }
        error = nil
        pendingApple = nil
        do {
            let nonce = try Self.secureRandomToken()
            let state = try Self.secureRandomToken()
            authAttempt = UUID()
            pendingApple = (nonce, state, linkRequirement?.id, authAttempt)
            request.requestedScopes = [.fullName, .email]
            request.nonce = SHA256.hash(data: Data(nonce.utf8)).map { String(format: "%02x", $0) }.joined()
            request.state = state
            isBusy = true
        } catch {
            // With no pending challenge, any callback is rejected locally.
            self.error = ui.text(uz: "Xavfsiz kirishni boshlash imkoni bo‘lmadi. Qayta urinib ko‘ring.", en: "Could not start secure sign-in. Please try again.", ru: "Не удалось начать безопасный вход. Попробуйте снова.")
        }
    }

    func completeAppleSignIn(_ result: Result<ASAuthorization, Error>) {
        guard let pending = pendingApple, pending.attempt == authAttempt else { return }
        pendingApple = nil
        switch result {
        case .failure(let failure):
            isBusy = false
            let nsError = failure as NSError
            if nsError.domain == ASAuthorizationError.errorDomain,
               nsError.code == ASAuthorizationError.canceled.rawValue {
                cancelPendingIdentityLinkIfNeeded(); return
            }
            error = appleFailureMessage(failure)
        case .success(let authorization):
            guard let credential = authorization.credential as? ASAuthorizationAppleIDCredential,
                  credential.state == pending.state,
                  let data = credential.identityToken,
                  let token = String(data: data, encoding: .utf8), !token.isEmpty else {
                isBusy = false
                error = appleFailureMessage(EchoAuthError.invalidResponse)
                return
            }
            let name = credential.fullName.map {
                PersonNameComponentsFormatter.localizedString(from: $0, style: .default)
            }?.trimmingCharacters(in: .whitespacesAndNewlines)
            if let id = pending.linking {
                guard let requirement = linkRequirement, requirement.id == id, !requirement.isExpired() else {
                    isBusy = false; clearExpiredIdentityLink(); return
                }
                linkConfirmation = (.apple, token, pending.nonce, name?.isEmpty == false ? name : nil, id)
                showsLinkConfirmation = true
                isBusy = false
                return
            }
            Task { @MainActor in
                defer { if authAttempt == pending.attempt { isBusy = false } }
                do {
                    let authenticated = try await EchoAuthClient.shared.signInWithApple(
                        idToken: token, nonce: pending.nonce, fullName: name?.isEmpty == false ? name : nil
                    )
                    guard authAttempt == pending.attempt else { return }
                    signedIn = authenticated; signInRevision += 1
                } catch {
                    guard authAttempt == pending.attempt else { return }
                    if !handleLinkRequirement(error) {
                        self.error = (error as? EchoIdentityLinkError).map(identityLinkMessage) ?? appleFailureMessage(error)
                    }
                }
            }
        }
    }

    private func appleFailureMessage(_ failure: Error) -> String {
        if let message = rateLimitMessage(for: failure) { return message }
        if let failure = failure as? EchoAuthError {
            switch failure {
            case .accountDisabled:
                return ui.text(uz: "Bu hisobga kirish cheklangan. Yordam xizmatiga murojaat qiling.", en: "Access to this account is restricted. Contact support.", ru: "Доступ к аккаунту ограничен. Обратитесь в поддержку.")
            case .rateLimited:
                return ui.text(uz: "Urinishlar juda ko‘p. Biroz kutib, qayta urinib ko‘ring.", en: "Too many attempts. Wait a moment and try again.", ru: "Слишком много попыток. Подождите и попробуйте снова.")
            case .server(409):
                return ui.text(uz: "Bu email bilan hisob mavjud. Avval foydalangan Google hisobingiz orqali kiring.", en: "An account already uses this email. Sign in with the Google account you used before.", ru: "Аккаунт с этой почтой уже существует. Войдите через ранее использованный аккаунт Google.")
            case .server(503):
                return ui.text(uz: "Apple orqali kirish vaqtincha ishlamayapti. Keyinroq qayta urinib ko‘ring.", en: "Apple sign-in is temporarily unavailable. Please try again later.", ru: "Вход через Apple временно недоступен. Попробуйте позже.")
            default: break
            }
        }
        return ui.text(uz: "Apple orqali kirish yakunlanmadi. Internet aloqangizni tekshiring va qayta urinib ko‘ring.", en: "Apple sign-in could not be completed. Check your connection and try again.", ru: "Не удалось войти через Apple. Проверьте соединение и попробуйте снова.")
    }

    private func rateLimitMessage(for failure: Error) -> String? {
        guard let failure = failure as? EchoAuthError else { return nil }
        let deadline: Date
        switch failure {
        case .rateLimitedUntil(let date): deadline = date
        case .rateLimited: deadline = .now.addingTimeInterval(30)
        default: return nil
        }
        retryAfter = max(retryAfter ?? deadline, deadline)
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: ui == .uzbek ? "uz_UZ" : (ui == .russian ? "ru_RU" : "en_US"))
        formatter.dateStyle = .none
        formatter.timeStyle = .medium
        let time = formatter.string(from: retryAfter ?? deadline)
        let message = ui.text(uz: "Urinishlar juda ko‘p. \(time) dan keyin qayta urinishingiz mumkin.", en: "Too many sign-in attempts. You can try again after \(time).", ru: "Слишком много попыток входа. Повторите после \(time).")
        rateLimitWarning = message
        return message
    }

    private static func secureRandomToken() throws -> String {
        var bytes = [UInt8](repeating: 0, count: 32)
        guard SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) == errSecSuccess else {
            throw EchoAuthError.invalidResponse
        }
        return bytes.map { String(format: "%02x", $0) }.joined()
    }

    func signInWithGoogle() {
        let wasLinking = linkRequirement != nil
        clearExpiredRateLimit(); clearExpiredIdentityLink()
        if wasLinking && linkRequirement == nil { return }
        guard !isBusy, !showsLinkConfirmation, retryAfter.map({ $0 <= .now }) ?? true else { return }
        guard var presenter = UIApplication.shared.connectedScenes
            .compactMap({ $0 as? UIWindowScene })
            .filter({ $0.activationState == .foregroundActive })
            .flatMap(\.windows).first(where: \.isKeyWindow)?.rootViewController else {
            error = "Kirish oynasini ochib bo‘lmadi."
            return
        }
        while let presented = presenter.presentedViewController { presenter = presented }
        isBusy = true
        error = nil
        authAttempt = UUID()
        let attempt = authAttempt
        let linkingID = linkRequirement?.id
        Task { @MainActor in
            defer {
                if authAttempt == attempt { isBusy = false }
                // Echo owns the persistent session, not the Google SDK.
                GIDSignIn.sharedInstance.signOut()
            }
            var sdkCompleted = false
            do {
                let result = try await GIDSignIn.sharedInstance.signIn(withPresenting: presenter)
                sdkCompleted = true
                guard authAttempt == attempt else { return }
                guard let token = result.user.idToken?.tokenString else { throw EchoAuthError.invalidResponse }
                if let id = linkingID {
                    guard let requirement = linkRequirement, requirement.id == id, !requirement.isExpired() else {
                        clearExpiredIdentityLink(); return
                    }
                    linkConfirmation = (.google, token, nil, nil, id)
                    showsLinkConfirmation = true
                    return
                }
                let authenticated = try await EchoAuthClient.shared.signInWithGoogle(idToken: token)
                guard authAttempt == attempt else { return }
                signedIn = authenticated; signInRevision += 1
            } catch {
                guard authAttempt == attempt else { return }
                if !sdkCompleted, !(error is EchoAuthError) {
                    EchoAuthDiagnostics.recordFailure(phase: "google_sdk", error: error)
                }
                let failure = error as NSError
                if failure.domain == kGIDSignInErrorDomain && failure.code == GIDSignInError.canceled.rawValue {
                    cancelPendingIdentityLinkIfNeeded()
                } else if !handleLinkRequirement(error) {
                    self.error = rateLimitMessage(for: error) ?? (error as? EchoIdentityLinkError).map(identityLinkMessage) ?? error.localizedDescription
                }
            }
        }
    }


}

@MainActor @Observable
private final class EchoQuestionnaire {
    struct Option: Identifiable {
        let id: String
        let title: String
    }

    struct Question {
        let id: String
        let title: String
        let limit: Int
        let options: [Option]

        init(_ id: String, _ title: String, limit: Int, _ options: [(String, String)]) {
            self.id = id
            self.title = title
            self.limit = limit
            self.options = options.map { Option(id: $0.0, title: $0.1) }
        }
    }

    static let questions: [Question] = [
        Question("discovery", "Echo haqida qayerdan bildingiz?", limit: 1, [
            ("friend", "Do‘stimdan"), ("telegram", "Telegram"), ("instagram", "Instagram"),
            ("youtube", "YouTube"), ("search", "Qidiruvdan"), ("other", "Boshqa"),
        ]),
        Question("intent", "Echo’dan nima uchun foydalanasiz?", limit: 5, [
            ("dictation", "Ovozdan matn"), ("meeting_notes", "Uchrashuv qaydlari"),
            ("accessibility", "Qulaylik uchun"), ("exploring", "Sinab ko‘rish"), ("other", "Boshqa"),
        ]),
        Question("work", "Qaysi sohada ishlaysiz?", limit: 1, [
            ("developer", "Dasturlash"), ("founder", "Tadbirkorlik"),
            ("product", "Mahsulot"), ("marketing", "Marketing"),
            ("sales", "Savdo"), ("student", "Talaba"),
            ("educator", "Ta’lim"), ("writer", "Yozuvchilik"), ("other", "Boshqa"),
        ]),
        Question("writing", "Ko‘proq qayerda yozasiz?", limit: 8, [
            ("messages", "Xabarlar"), ("emails", "Email"),
            ("documents", "Hujjatlar"), ("notes", "Qaydlar"),
            ("ai", "AI chat"), ("coding", "Kod"), ("posts", "Postlar"), ("other", "Boshqa"),
        ]),
        Question("meeting_apps", "Uchrashuvlar uchun qaysi ilovalarni ishlatasiz?", limit: 9, [
            ("zoom", "Zoom"), ("google_meet", "Google Meet"),
            ("teams", "Teams"), ("slack", "Slack"),
            ("facetime", "FaceTime"), ("telegram", "Telegram"),
            ("in_person", "Yuzma-yuz"), ("none", "Ishlatmayman"), ("other", "Boshqa"),
        ]),
        Question("meeting_problems", "Uchrashuvlarda sizga nima qiyin?", limit: 8, [
            ("preparation", "Tayyorgarlik"), ("taking_notes", "Qayd olish"),
            ("focus", "Diqqatni jamlash"), ("action_items", "Vazifalarni ajratish"),
            ("finding_notes", "Qaydlarni topish"), ("sharing", "Ulashish"),
            ("language", "Til"), ("none", "Muammo yo‘q"), ("other", "Boshqa"),
        ]),
    ]

    private(set) var index = 0
    private(set) var isLoaded = false
    private(set) var isFinished = false
    private(set) var isBusy = false
    private(set) var error: String?
    var other = ""
    private var revision = 0
    private var answers: [String: EchoContextAnswer] = [:]
    private var selected: Set<String> = []

    var question: Question { Self.questions[index] }
    var canAdvance: Bool {
        isLoaded && !isBusy && !selected.isEmpty && selected.count <= question.limit &&
            (!selected.contains("other") || !other.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
    }

    func isSelected(_ option: String) -> Bool { selected.contains(option) }

    func load() async {
        guard !isLoaded, !isBusy else { return }
        isBusy = true
        error = nil
        defer { isBusy = false }
        do {
            let context = try await EchoAuthClient.shared.getOnboardingContext()
            revision = context?.revision ?? 0
            answers = context?.answers ?? [:]
            isFinished = context?.completedAt != nil
            index = Self.questions.firstIndex { answers[$0.id] == nil } ?? Self.questions.count - 1
            restoreSelection()
            isLoaded = true
        } catch {
            self.error = error.localizedDescription
        }
    }

    func toggle(_ option: String) {
        guard !isBusy else { return }
        if selected.contains(option) { selected.remove(option) }
        else if question.limit == 1 || option == "none" { selected = [option] }
        else {
            selected.remove("none")
            guard selected.count < question.limit else { return }
            selected.insert(option)
        }
        if !selected.contains("other") { other = "" }
    }

    func back() {
        guard index > 0, !isBusy else { return }
        index -= 1
        restoreSelection()
    }

    func advance(skipping: Bool, uiLanguage: String) async {
        guard isLoaded, !isBusy, skipping || canAdvance else { return }
        let choice = skipping ? EchoContextAnswer(skipped: true) : EchoContextAnswer(
            choices: selected.sorted(),
            other: other.trimmingCharacters(in: .whitespacesAndNewlines)
        )
        var nextAnswers = answers
        nextAnswers[question.id] = choice
        let submission = EchoContextSubmission(
            revision: revision, answers: nextAnswers,
            completed: index == Self.questions.count - 1,
            uiLanguage: uiLanguage
        )
        isBusy = true
        error = nil
        defer { isBusy = false }
        do {
            let context = try await EchoAuthClient.shared.saveOnboardingContext(submission)
            revision = context.revision
            answers = context.answers
            isFinished = context.completedAt != nil
            if !isFinished { index += 1; restoreSelection() }
        } catch {
            self.error = error.localizedDescription
        }
    }

    func skipRemaining(uiLanguage: String) async {
        guard isLoaded, !isBusy else { return }
        var nextAnswers = answers
        for question in Self.questions where nextAnswers[question.id] == nil {
            nextAnswers[question.id] = EchoContextAnswer(skipped: true)
        }
        isBusy = true
        error = nil
        defer { isBusy = false }
        do {
            let context = try await EchoAuthClient.shared.saveOnboardingContext(
                EchoContextSubmission(revision: revision, answers: nextAnswers,
                                      completed: true, uiLanguage: uiLanguage)
            )
            revision = context.revision
            answers = context.answers
            isFinished = context.completedAt != nil
        } catch {
            self.error = error.localizedDescription
        }
    }

    private func restoreSelection() {
        let answer = answers[question.id]
        selected = Set(answer?.choices ?? [])
        other = answer?.other ?? ""
    }
}

@MainActor private struct EchoQuestionnaireCopy: Decodable {
    let otherPrompt: String
    let loading: String
    let skip: String
    let retry: String
    let loadError: String
    let headings: [String]
    let options: [String: [String]]

    private static let optionIDs: [String: [String]] = [
        "discovery": ["friend", "youtube", "instagram", "telegram", "tiktok", "linkedin", "x", "facebook", "search", "article", "podcast", "newsletter", "ai_chat", "other"],
        "intent": ["dictation", "meeting_notes", "accessibility", "exploring", "other"],
        "work": ["developer", "founder", "product", "marketing", "sales", "operations", "student", "educator", "writer", "creator", "consultant", "legal", "healthcare", "support", "recruiting", "data_analysis", "other"],
        "writing": ["messages", "emails", "documents", "notes", "ai", "coding", "posts", "other"],
        "meeting_apps": ["zoom", "google_meet", "teams", "slack", "facetime", "telegram", "discord", "in_person", "none", "other"],
        "meeting_problems": ["preparation", "taking_notes", "focus", "action_items", "finding_notes", "sharing", "language", "none", "other"],
    ]

    static func forLanguage(_ language: String) -> Self {
        if let data = NSDataAsset(name: "QuestionnaireCopy")?.data,
           let copies = try? JSONDecoder().decode([String: Self].self, from: data),
           let copy = copies[language] ?? copies["uz"] {
            return copy
        }
        return Self(
            otherPrompt: "Batafsil yozing…", loading: "Yuklanmoqda…", skip: "O‘tkazib yuborish",
            retry: "Qayta urinish", loadError: "Javoblar yuklanmadi.",
            headings: EchoQuestionnaire.questions.map(\.title), options: [:]
        )
    }

    func option(question: String, id: String, fallback: String) -> String {
        guard let index = Self.optionIDs[question]?.firstIndex(of: id),
              let values = options[question], values.indices.contains(index) else { return fallback }
        return values[index]
    }
}
