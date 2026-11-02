import SwiftUI
import VoiceLabCore

struct OnboardingPermissions: View {
    let model: OnboardingModel
    private var ready: Bool { model.microphoneGranted && model.accessibilityGranted }
    var body: some View {
        OnboardingPage(
            title: ready
                ? AppLocalization.text("Ishonchingiz uchun rahmat.\nMaxfiyligingiz biz uchun muhim.")
                : AppLocalization.text("Echo’ga kompyuteringizda ruxsat bering"),
            subtitle: AppLocalization.text(
                "Mikrofon diktovka va ovoz testi uchun, Accessibility esa matn kiritish uchun kerak."),
            width: 512
        ) {
            VStack(spacing: 10) {
                permission(
                    AppLocalization.text("Mikrofondan foydalanish"), symbol: "mic",
                    granted: model.microphoneGranted,
                    detail: AppLocalization.text("Echo diktovka va mikrofon testi paytida tinglaydi."),
                    help: AppLocalization.text("Mikrofon faol bo‘lganda Echo buni ko‘rsatib turadi."),
                    success: AppLocalization.text("Endi Echo mikrofoningizdan foydalana oladi")
                ) {
                    Task { await model.requestMicrophone() }
                }
                permission(
                    AppLocalization.text("Ilovalarga matn kiritish"), symbol: "text.cursor",
                    granted: model.accessibilityGranted,
                    detail: AppLocalization.text(
                        "Natijani siz ishlayotgan matn maydoniga yozish imkonini beradi."),
                    help: AppLocalization.text(
                        "Accessibility ro‘yxatida Echo’ni yoqing va qaytib keling."),
                    success: AppLocalization.text("Endi Echo boshqa ilovalarga yoza oladi")
                ) {
                    model.requestAccessibility()
                }
            }
            Text(AppLocalization.text("Bularni keyinroq System Settings’da ham o‘zgartirishingiz mumkin."))
                .font(.system(size: 12)).foregroundStyle(OnboardingTheme.muted)
        }
    }

    private func permission(
        _ title: String, symbol: String, granted: Bool, detail: String, help: String,
        success: String, action: @escaping () -> Void
    ) -> some View {
        OnboardingCard(padding: 14) {
            HStack(spacing: 16) {
                OnboardingSymbol(name: granted ? "checkmark.circle.fill" : symbol, size: 22, active: granted)
                    .foregroundStyle(granted ? .white : OnboardingTheme.ink)
                    .frame(width: 44, height: 44)
                    .background(
                        granted ? OnboardingTheme.success : OnboardingTheme.panel,
                        in: RoundedRectangle(cornerRadius: 12))
                VStack(alignment: .leading, spacing: 4) {
                    Text(title).font(.system(size: 14, weight: .semibold))
                    Text(detail).font(.system(size: 12)).foregroundStyle(OnboardingTheme.muted)
                    Text(granted ? success : help).font(.system(size: 11)).lineSpacing(3)
                        .foregroundStyle(granted ? OnboardingTheme.success : OnboardingTheme.muted)
                }.frame(maxWidth: .infinity, alignment: .leading).multilineTextAlignment(.leading)
                if !granted {
                    Button(AppLocalization.text("Ruxsat berish"), action: action)
                        .buttonStyle(OnboardingButtonStyle(height: 32)).fixedSize()
                }
            }
        }
        .overlay(
            RoundedRectangle(cornerRadius: OnboardingTheme.radius).strokeBorder(
                granted ? OnboardingTheme.success.opacity(0.4) : .clear))
    }
}

struct OnboardingMicrophone: View {
    let model: OnboardingModel
    @State private var showMicrophones = false
    private var microphone: MicrophoneTestModel { model.microphone }

    var body: some View {
        OnboardingPage(
            title: AppLocalization.text("Mikrofoningizni tekshiring"),
            subtitle: AppLocalization.text("Odatdagi ovozingizda gapiring va ovoz ustunlarini kuzating."),
            width: 512
        ) {
            OnboardingCard(padding: 24) {
                VStack(alignment: .leading, spacing: 16) {
                    Text(AppLocalization.text("Gapirganingizda ustunlar harakatlanyaptimi?"))
                        .font(.system(size: 16, weight: .semibold))
                    OnboardingWaveform(
                        bands: microphone.bands, active: microphone.isRunning,
                        detected: microphone.speechDetected)
                    HStack {
                        AppLabel(
                            microphone.speechDetected
                                ? AppLocalization.text("Sizni eshityapmiz!")
                                : microphone.isStarting
                                    ? AppLocalization.text("Mikrofon ulanmoqda…")
                                    : AppLocalization.text("Davom etish uchun gapiring"),
                            systemImage: microphone.speechDetected ? "checkmark.circle.fill" : "mic"
                        )
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(
                            microphone.speechDetected ? OnboardingTheme.success : OnboardingTheme.muted)
                        Spacer()
                        if microphone.isRunning {
                            HStack(spacing: 5) {
                                Circle().fill(OnboardingTheme.success).frame(width: 6, height: 6)
                                Text(AppLocalization.text("Jonli")).font(.system(size: 11))
                            }
                        }
                    }
                    if let error = microphone.error {
                        Text(AppLocalization.error(error))
                            .font(.system(size: 12)).foregroundStyle(.red)
                            .multilineTextAlignment(.leading)
                        Button(
                            error == .permission
                                ? AppLocalization.text("Mikrofon ruxsatlari")
                                : AppLocalization.text("Qayta urinish")
                        ) {
                            if error == .permission {
                                Task {
                                    await model.requestMicrophone()
                                    if model.microphoneGranted { microphone.retry() }
                                }
                            } else {
                                microphone.retry()
                            }
                        }.buttonStyle(OnboardingButtonStyle(variant: .secondary, height: 32))
                    }
                    Rectangle().fill(OnboardingTheme.border).frame(height: 1)
                    HStack {
                        AppLabel(selectedName, systemImage: "mic")
                            .font(.system(size: 12)).foregroundStyle(OnboardingTheme.muted)
                            .lineLimit(1).help(selectedName)
                        Spacer()
                        Button(AppLocalization.text("Mikrofonni almashtirish")) {
                            showMicrophones.toggle()
                        }
                        .buttonStyle(OnboardingButtonStyle(variant: .secondary, height: 32))
                        .popover(isPresented: $showMicrophones, arrowEdge: .bottom) {
                            ScrollView {
                                VStack(spacing: 4) {
                                    ForEach(microphone.devices) { device in
                                        microphoneOption(device.name, id: device.id)
                                    }
                                }.padding(8)
                            }
                            .frame(
                                width: 280, height: min(280, CGFloat(max(1, microphone.devices.count)) * 40 + 12)
                            )
                            .task { await microphone.refreshDevices() }
                        }
                    }
                }
            }
            OnboardingCard(padding: 14) {
                HStack(alignment: .top, spacing: 12) {
                    AppIcon(systemName: "headphones", size: 16)
                    Text(
                        AppLocalization.text(
                            "Yaxshiroq ovoz uchun simli quloqchin mikrofonidan foydalaning. Bu testda audio saqlanmaydi va serverga yuborilmaydi."
                        )
                    )
                    .font(.system(size: 12)).lineSpacing(4).foregroundStyle(OnboardingTheme.muted)
                    .frame(maxWidth: .infinity, alignment: .leading).multilineTextAlignment(.leading)
                }
            }
        }
        .task { model.startMicrophoneTest() }
        .onDisappear { model.stopMicrophoneTest() }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) {
            _ in
            model.refreshPermissions()
            if microphone.error == .permission && model.microphoneGranted { microphone.retry() }
        }
    }

    private var effectiveSelectedID: String {
        let id = microphone.selectedDeviceID
        return id.isEmpty ? MicrophoneDevice.defaultDeviceID : id
    }

    private var selectedName: String {
        microphone.devices.first(where: { $0.id == effectiveSelectedID })?.name
            ?? AppLocalization.text("Ulanmagan mikrofon")
    }

    private func microphoneOption(_ name: String, id: String) -> some View {
        Button {
            showMicrophones = false
            microphone.select(id)
        } label: {
            HStack(spacing: 10) {
                Text(name).lineLimit(1)
                Spacer(minLength: 8)
                AppIcon(systemName: "checkmark")
                    .opacity(effectiveSelectedID == id ? 1 : 0)
            }
            .font(.system(size: 13))
            .foregroundStyle(OnboardingTheme.ink)
            .padding(.horizontal, 10)
            .frame(height: 36)
            .background(
                effectiveSelectedID == id ? OnboardingTheme.panel : .clear,
                in: RoundedRectangle(cornerRadius: 6)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(name)
        .accessibilityAddTraits(effectiveSelectedID == id ? .isSelected : [])
    }
}

struct OnboardingWaveform: View {
    @Environment(\.onboardingCompact) private var compact
    let bands: [Double]
    let active: Bool
    let detected: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    var body: some View {
        HStack(alignment: .bottom, spacing: 4) {
            ForEach(bands.indices, id: \.self) { index in
                Capsule()
                    .fill(
                        detected
                            ? OnboardingTheme.success
                            : active ? OnboardingTheme.ink : OnboardingTheme.keyBorder.opacity(0.5)
                    )
                    .frame(maxWidth: .infinity)
                    .frame(height: max(5, min(1, bands[index]) * (compact ? 48 : 80)))
            }
        }
        .frame(height: compact ? 48 : 80, alignment: .bottom).padding(compact ? 12 : 20)
        .background(OnboardingTheme.panel, in: RoundedRectangle(cornerRadius: 12))
        .animation(reduceMotion ? nil : .linear(duration: 0.05), value: bands)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(AppLocalization.text("Mikrofon ovoz darajasi"))
        .accessibilityValue(
            detected
                ? AppLocalization.text("Ovoz aniqlandi")
                : active ? AppLocalization.text("Tinglanmoqda") : AppLocalization.text("Mikrofon faol emas"))
    }
}

struct OnboardingShortcut: View {
    @Environment(\.onboardingCompact) private var compact
    @Environment(\.dictationShortcut) private var shortcut
    let app: AppModel
    var body: some View {
        OnboardingPage(
            title: AppLocalization.text("Diktovka tugmasini sinab ko‘ring"),
            subtitle: AppLocalization.text(
                "%@ tugmasini bosing, gapiring, tugatish uchun yana bosing.", shortcut.displayName),
            width: 512
        ) {
            OnboardingCard(padding: 24) {
                VStack(alignment: .leading, spacing: 16) {
                    Text(AppLocalization.text("Bosganingizda tugma yonyaptimi?")).font(
                        .system(size: 16, weight: .semibold))
                    VStack(spacing: 20) {
                        OnboardingKeycaps(large: true, active: app.onboarding.shortcutPressed)
                        AppLabel(
                            app.onboarding.shortcutDetected
                                ? AppLocalization.text("Ishlayapti!")
                                : AppLocalization.text("Klaviaturadagi tugmalarni bosing!"),
                            systemImage: app.onboarding.shortcutDetected ? "checkmark" : "keyboard"
                        )
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(
                            app.onboarding.shortcutDetected ? OnboardingTheme.success : OnboardingTheme.muted)
                    }
                    .frame(maxWidth: .infinity).frame(height: compact ? 112 : 160)
                    .background(OnboardingTheme.panel, in: RoundedRectangle(cornerRadius: 12))
                    HStack {
                        Button(AppLocalization.text("Shortcutni qayta ulash")) { app.registerShortcut() }
                            .buttonStyle(OnboardingButtonStyle(variant: .ghost, height: 32))
                        Spacer()
                        if app.onboarding.shortcutDetected {
                            AppLabel(
                                AppLocalization.text("Tugma aniqlandi"), systemImage: "checkmark.circle.fill"
                            )
                            .font(.system(size: 12)).foregroundStyle(OnboardingTheme.success)
                        }
                    }
                }
            }
            Text(AppLocalization.text("Bu qadamda faqat tugmalar tekshiriladi. Audio yozilmaydi."))
                .font(.system(size: 12)).foregroundStyle(OnboardingTheme.muted)
            VStack(spacing: 6) {
                if shortcut.isFn {
                    Text(
                        AppLocalization.text(
                            "Echo ishlayotganida Fn’ning emoji amali vaqtincha o‘chiriladi. Ilovadan chiqqanda oldingi sozlama qaytariladi."
                        )
                    )
                    .font(.system(size: 11)).foregroundStyle(OnboardingTheme.muted)
                }
                Button(AppLocalization.text("Klaviatura sozlamalari")) {
                    if let url = URL(
                        string: "x-apple.systempreferences:com.apple.Keyboard-Settings.extension")
                    {
                        NSWorkspace.shared.open(url)
                    }
                }.buttonStyle(OnboardingButtonStyle(variant: .ghost, height: 28))
            }
        }
    }
}
