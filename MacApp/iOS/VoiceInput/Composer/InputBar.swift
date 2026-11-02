import SwiftUI

/// Composer above the system keyboard. While dictating, a recording row (cancel, waveform,
/// timer, done) appears under the text view, and the transcript lands at the cursor.
struct InputBar: View {
    let model: ComposerModel
    let onSend: (String) -> Void

    @AppStorage("echo.app.language") private var appLanguage = EchoAppLanguage.uzbek.rawValue
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var ui: EchoAppLanguage { EchoAppLanguage(rawValue: appLanguage) ?? .uzbek }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let error = model.error {
                DictationErrorBanner(error: error, dismiss: model.dismissError)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
            VStack(alignment: .leading, spacing: 8) {
                if model.isKeyboardFocused || model.canSend || model.isDictating {
                HStack {
                    Text(ui.text(uz: "Qoralama", en: "Draft", ru: "Черновик"))
                        .font(.subheadline.weight(.semibold))
                    Spacer()
                    if model.isKeyboardFocused {
                        Button(action: model.dismissKeyboard) {
                            Image(systemName: "keyboard.chevron.compact.down")
                                .font(.body.weight(.medium))
                                .frame(width: 44, height: 44)
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .foregroundStyle(.secondary)
                        .accessibilityLabel(ui.text(uz: "Klaviaturani yopish", en: "Hide keyboard", ru: "Скрыть клавиатуру"))
                    }
                    if model.canSend && !model.isDictating {
                        Button {
                            if let text = model.takeDraft() { onSend(text) }
                        } label: {
                            Label(ui.text(uz: "Saqlash", en: "Save note", ru: "Сохранить"), systemImage: "checkmark")
                                .font(.subheadline.weight(.semibold))
                                .padding(.horizontal, 12)
                                .frame(minHeight: 44)
                        }
                        .buttonStyle(.borderedProminent)
                        .clipShape(Capsule())
                    }
                }
                .padding(.horizontal, 4)
                }
                HStack(alignment: .bottom, spacing: 6) {
                    ZStack(alignment: .topLeading) {
                        if model.draft.isEmpty {
                            Text(model.isDictating
                                 ? ui.text(uz: "Tinglanmoqda…", en: "Listening…", ru: "Слушаю…")
                                 : ui.text(uz: "Yozing yoki gapiring…", en: "Type or dictate…", ru: "Напишите или продиктуйте…"))
                                .foregroundStyle(.tertiary)
                                .padding(.top, 10)
                                .padding(.leading, 12)
                                .allowsHitTesting(false)
                                .accessibilityHidden(true)
                        }
                        VoiceTextView(model: model, text: model.draft, focusRequest: model.focusRequest)
                            .accessibilityLabel(ui.text(uz: "Qoralama matni", en: "Draft text", ru: "Текст черновика"))
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)

                    if !model.isDictating {
                        Button(action: model.startDictation) {
                            Image("EchoLogo")
                                .resizable()
                                .scaledToFit()
                                .frame(width: 40, height: 40)
                                .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                                .padding(3)
                                .background(EchoMobileTheme.accent.opacity(0.10), in: RoundedRectangle(cornerRadius: 17, style: .continuous))
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel(ui.text(uz: "Echo bilan diktovkani boshlash", en: "Start dictation with Echo", ru: "Начать диктовку с Echo"))

                    }
                }
                if model.isDictating {
                    RecordingRow(model: model, ui: ui)
                        .transition(.move(edge: .bottom).combined(with: .opacity))
                }
            }
            .padding(8)
            .composerBackground()
            .contentShape(Rectangle())
            .simultaneousGesture(
                DragGesture(minimumDistance: 24)
                    .onEnded { value in
                        if value.translation.height > 40,
                           value.translation.height > abs(value.translation.width) {
                            model.dismissKeyboard()
                        }
                    }
            )
        }
        .padding(.horizontal, 12)
        .padding(.bottom, 8)
        // Static fallback: with Reduce Motion the bar swaps states without animating.
        .animation(reduceMotion ? nil : .easeOut(duration: 0.18), value: model.phase)
        .animation(reduceMotion ? nil : .easeOut(duration: 0.18), value: model.canSend)
        .animation(reduceMotion ? nil : .easeOut(duration: 0.18), value: model.error)
        .sensoryFeedback(trigger: model.phase) { old, new in
            if case .recording = new { return .start }
            if new == .idle, old == .transcribing { return .success }
            return nil
        }
    }
}

private struct RecordingRow: View {
    let model: ComposerModel
    let ui: EchoAppLanguage

    var body: some View {
        HStack(spacing: 6) {
            CircleButton(systemImage: "xmark", prominent: false, label: ui.text(uz: "Diktovkani bekor qilish", en: "Cancel dictation", ru: "Отменить диктовку"), action: model.cancelDictation)

            Group {
                switch model.phase {
                case .idle, .preparing:
                    ProgressView()
                case .recording:
                    WaveformView(model: model)
                case .transcribing:
                    HStack(spacing: 8) {
                        ProgressView()
                        Text(ui.text(uz: "Matnga aylantirilmoqda…", en: "Transcribing…", ru: "Преобразование в текст…"))
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .frame(maxWidth: .infinity, minHeight: 44)

            if case .recording(let since) = model.phase {
                Text(since, style: .timer)
                    .font(.footnote.monospacedDigit())
                    .foregroundStyle(.secondary)
                    .accessibilityLabel(ui.text(uz: "Yozuv davomiyligi", en: "Recording time", ru: "Время записи"))
            }

            CircleButton(
                systemImage: "checkmark",
                prominent: true,
                fill: .red,
                label: ui.text(uz: "Diktovkani tugatish", en: "Finish dictation", ru: "Завершить диктовку"),
                action: model.finishDictation
            )
            .disabled(model.phase == .transcribing || model.phase == .preparing)
        }
    }
}

private struct CircleButton: View {
    let systemImage: String
    let prominent: Bool
    /// Fill for prominent buttons; nil uses the primary color with inverted icon.
    var fill: Color?
    let label: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.body.weight(.semibold))
                .frame(width: 44, height: 44)
                .foregroundStyle(prominent ? (fill == nil ? Color(uiColor: .systemBackground) : .white) : Color.primary)
                .background(prominent ? (fill ?? .primary) : Color.clear, in: .circle)
                .contentShape(.circle)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label)
    }
}

private struct DictationErrorBanner: View {
    let error: DictationError
    let dismiss: () -> Void

    @AppStorage("echo.app.language") private var appLanguage = EchoAppLanguage.uzbek.rawValue
    @Environment(\.openURL) private var openURL

    private var ui: EchoAppLanguage { EchoAppLanguage(rawValue: appLanguage) ?? .uzbek }

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
            Text(message)
                .font(.footnote)
                .frame(maxWidth: .infinity, alignment: .leading)
            if needsSettings, let url = URL(string: UIApplication.openSettingsURLString) {
                Button(ui.text(uz: "Sozlamalar", en: "Settings", ru: "Настройки")) { openURL(url) }
                    .frame(minHeight: 44)
                    .font(.footnote.weight(.semibold))
            }
            Button(action: dismiss) {
                Image(systemName: "xmark")
                    .font(.footnote.weight(.semibold))
                    .frame(width: 44, height: 44)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(ui.text(uz: "Yopish", en: "Dismiss", ru: "Закрыть"))
        }
        .padding(12)
        .background(.thinMaterial, in: .rect(cornerRadius: 16, style: .continuous))
    }

    private var message: String {
        switch error {
        case .microphoneDenied:
            ui.text(uz: "Sozlamalarda mikrofonga ruxsat bering.", en: "Allow microphone access in Settings.", ru: "Разрешите доступ к микрофону в настройках.")
        case .noMicrophone:
            ui.text(uz: "Mikrofon topilmadi.", en: "No microphone found.", ru: "Микрофон не найден.")
        case .audioUnavailable:
            ui.text(uz: "Yozuvni boshlab bo‘lmadi. Qayta urining.", en: "Couldn't start recording. Try again.", ru: "Не удалось начать запись. Попробуйте ещё раз.")
        case .notConfigured:
            ui.text(uz: "Diktovka uchun akkauntingizga qayta kiring.", en: "Sign in again to use dictation.", ru: "Войдите снова, чтобы использовать диктовку.")
        case .offline:
            ui.text(uz: "Internet aloqasi yo‘q. Ulangach qayta urining.", en: "No internet connection. Try again when you're online.", ru: "Нет подключения к интернету. Повторите после подключения.")
        case .noCredits:
            ui.text(uz: "VoiceLab kreditlari tugadi.", en: "Out of VoiceLab credits.", ru: "Кредиты VoiceLab закончились.")
        case .noSpeech:
            ui.text(uz: "Nutq aniqlanmadi. Qayta urining.", en: "Didn't catch that. Try again.", ru: "Речь не распознана. Попробуйте ещё раз.")
        case .serviceUnavailable:
            ui.text(uz: "Transkripsiya xizmati vaqtincha ishlamayapti. Birozdan so‘ng qayta urining.", en: "Transcription is temporarily unavailable. Try again shortly.", ru: "Распознавание временно недоступно. Попробуйте чуть позже.")
        case .recognitionFailed:
            ui.text(uz: "Matnga aylantirib bo‘lmadi. Qayta urining.", en: "Couldn't transcribe that. Try again.", ru: "Не удалось распознать речь. Попробуйте ещё раз.")
        }
    }

    private var needsSettings: Bool {
        switch error {
        case .microphoneDenied: true
        case .noMicrophone, .audioUnavailable, .notConfigured, .offline, .noCredits, .noSpeech, .serviceUnavailable, .recognitionFailed: false
        }
    }
}

private extension View {
    @ViewBuilder
    func composerBackground() -> some View {
        let shape = RoundedRectangle(cornerRadius: 26, style: .continuous)
        // Glass sits behind the controls so they keep their own colors and hit testing.
        if #available(iOS 26, *) {
            background { Color.clear.glassEffect(.regular, in: shape) }
        } else {
            background(.regularMaterial, in: shape)
        }
    }
}
