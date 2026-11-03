import SwiftUI
import UIKit

/// Full keyboard with a mic in the top bar. While dictating, a voice panel replaces the keys:
/// cancel, live dots that follow the voice, and ✓ to stop and insert the transcript.
struct KeyboardView: View {
    let model: KeyboardModel

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        ZStack {
            if model.showsPreferences {
                KeyboardPreferencesPanel(model: model)
                    .transition(.opacity)
            } else if model.showsVoicePanel {
                VoicePanel(model: model, reduceMotion: reduceMotion)
                    .transition(.opacity)
            } else {
                VStack(spacing: 0) {
                    AccessoryBar(model: model)
                        .frame(height: 44)
                    KeyGrid(model: model)
                }
                .transition(.opacity)
            }
        }
        .padding(.horizontal, 3)
        .padding(.top, 2)
        .padding(.bottom, 2)
        .background(Color.clear)
        .animation(reduceMotion ? nil : .snappy(duration: 0.25), value: model.showsVoicePanel)
        .animation(reduceMotion ? nil : .easeOut(duration: 0.18), value: model.showsPreferences)
    }
}

/// Language, predictions and dictation share one compact accessory row.
private struct AccessoryBar: View {
    let model: KeyboardModel

    var body: some View {
        HStack(spacing: 2) {
            Button { model.showsPreferences = true } label: {
                Image(systemName: "line.3.horizontal")
                    .font(.system(size: 20, weight: .medium))
                    .foregroundStyle(.primary)
                    .frame(width: 56, height: 44)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Klaviatura menyusi va sozlamalar")

            if let message {
                Text(message)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    .frame(maxWidth: .infinity, alignment: .leading)
            } else if model.showsSuggestions && !model.suggestions.isEmpty {
                HStack(spacing: 0) {
                    ForEach(Array(model.suggestions.enumerated()), id: \.offset) { index, word in
                        if index > 0 {
                            Rectangle().fill(Color.primary.opacity(0.12)).frame(width: 0.5, height: 20)
                        }
                        Button { model.chooseSuggestion?(word) } label: {
                            Text(word == model.typedWord ? "“\(word)”" : word)
                                .font(.system(size: 15))
                                .lineLimit(1)
                                .minimumScaleFactor(0.7)
                                .frame(maxWidth: .infinity, minHeight: 44)
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel(word == model.typedWord ? "Asl yozuvni saqlash: \(word)" : "Tavsiya: \(word)")
                    }
                }
                .frame(maxWidth: .infinity)
            } else {
                Spacer(minLength: 4)
            }

            Button(action: model.micTapped) {
                HStack(spacing: 7) {
                    if !model.showsSuggestions || model.suggestions.isEmpty {
                        Text("Boshlash")
                            .font(.system(size: 15, weight: .semibold))
                    }
                    Image("EchoLogo")
                        .resizable()
                        .scaledToFit()
                        .frame(width: 27, height: 27)
                        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                }
                .padding(.horizontal, 11)
                .frame(height: 36)
                .foregroundStyle(Color(uiColor: .systemBackground))
                .background(Color.primary, in: Capsule())
                .frame(minWidth: 44, minHeight: 44)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Start dictation with Echo")
            .disabled(!model.hasFullAccess || model.isBusy)
            .opacity(model.hasFullAccess ? 1 : 0.4)
        }
        .padding(.horizontal, 2)
    }

    private var message: LocalizedStringKey? {
        if !model.hasFullAccess {
            return "Turn on Full Access: Settings › General › Keyboard › Keyboards › Echo"
        }
        switch model.notice {
        case .openingApp: return "Opening Echo… then tap ◀ in the top corner to come back."
        case .openAppManually: return "Open the Echo app once, then come back and tap the mic."
        case .none: break
        }
        switch model.snapshot.failure {
        case .permissionDenied: return "Allow microphone access in the Echo app."
        case .unavailable: return "Couldn't start the microphone. Try again."
        case .offline: return "No internet connection."
        case .noCredits: return "Out of VoiceLab credits."
        case .noSpeech: return "Didn't catch that. Try again."
        case .recognitionFailed: return "Couldn't transcribe that. Try again."
        case nil: return nil
        }
    }
}

/// Settings stay inside the keyboard bounds; ABC restores typing immediately.
private struct KeyboardPreferencesPanel: View {
    let model: KeyboardModel

    private var sessionTitle: String {
        model.isSessionAlive ? "Mikrofon sessiyasini o‘chirish" : "5 daqiqaga faollashtirish"
    }

    private var sessionDetail: String {
        if model.isSessionAlive {
            return "Mikrofon darhol qo‘yib yuboriladi. Keyingi diktovkada Echo’ni qayta ochish kerak bo‘ladi."
        }
        return "Echo’ni qayta ochmasdan gapiring. Mikrofon belgisi yonib turadi; diktovkalar orasidagi ovoz saqlanmaydi. Klaviatura yopilgach, 5 daqiqa ishlatilmasa o‘chadi."
    }

    private var sessionButton: some View {
        Button {
            if model.isSessionAlive {
                model.endSessionTapped()
            } else {
                model.activateSessionTapped()
            }
        } label: {
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 8) {
                    Image(systemName: model.isSessionAlive ? "mic.slash" : "mic.fill")
                    Text(sessionTitle)
                }
                .font(.system(size: 14, weight: .semibold))
                Text(sessionDetail)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, minHeight: 48, alignment: .leading)
            .padding(.vertical, 8)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(Text(sessionTitle))
        .accessibilityHint(Text(sessionDetail))
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Button { model.showsPreferences = false } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 17, weight: .medium))
                        .frame(width: 44, height: 44)
                }
                .accessibilityLabel("Sozlamalarni yopish")
                Spacer()
                Text("Klaviatura sozlamalari").font(.system(size: 14, weight: .semibold))
                Spacer()
                Button("ABC") { model.showsPreferences = false }
                    .font(.system(size: 14, weight: .semibold))
                    .frame(width: 56, height: 44)
                    .background(Color(uiColor: .keyCharacter), in: Capsule())
                    .accessibilityLabel("Klaviaturaga qaytish")
            }
            .buttonStyle(.plain)
            .frame(height: 44)
            .padding(.horizontal, 6)

            ScrollView(.vertical, showsIndicators: true) {
                VStack(spacing: 0) {
                    sessionButton
                    Divider()
                    Picker("Mikrofonni o‘chirish", selection: Binding(
                        get: { model.microphoneMode }, set: { model.setMicrophoneMode($0) })) {
                        Text("5 daqiqa ishlatilmaganda").tag(VoiceBridge.MicrophoneMode.readySession)
                        Text("Har yozuvdan keyin").tag(VoiceBridge.MicrophoneMode.recordingOnly)
                    }
                    .pickerStyle(.menu)
                    .frame(minHeight: 48)
                    Divider()
                    HStack {
                        Label("Til", systemImage: "globe")
                        Spacer()
                        Picker("Klaviatura tili", selection: Binding(get: { model.layout }, set: { model.selectLayout($0) })) {
                            Text("O‘zbekcha").tag(KeyboardModel.Layout.uzbek)
                            Text("English").tag(KeyboardModel.Layout.english)
                            Text("Русский").tag(KeyboardModel.Layout.russian)
                        }
                        .labelsHidden().pickerStyle(.menu)
                    }
                    .frame(minHeight: 48)
                    Divider()
                    if model.layout == .uzbek {
                        HStack {
                            Label("Alifbo", systemImage: "character")
                            Spacer()
                            Picker("O‘zbek alifbosi", selection: Binding(get: { model.usesModernUzbekAlphabet }, set: { value in
                                if model.usesModernUzbekAlphabet != value { model.toggleUzbekAlphabet() }
                            })) {
                                Text("Amaldagi — Oʻ, Gʻ").tag(false)
                                Text("Yangi — Ö, Ğ, Ş, Ç").tag(true)
                            }
                            .labelsHidden().pickerStyle(.menu)
                        }
                        .frame(minHeight: 48)
                        Divider()
                    }
                    Toggle(isOn: Binding(get: { model.suggestionsEnabled }, set: { model.setSuggestionsEnabled($0) })) {
                        Label("So‘z tavsiyalari", systemImage: "text.bubble")
                    }
                    .frame(minHeight: 48)
                    Divider()
                    Toggle(isOn: Binding(get: { model.autocorrectEnabled }, set: { model.setAutocorrectEnabled($0) })) {
                        Label("Avtomatik tuzatish", systemImage: "checkmark.circle")
                    }
                    .frame(minHeight: 48)
                    Divider()
                    Button(action: model.openSubscription) {
                        HStack {
                            Label("Tariflar / Pro", systemImage: "sparkles")
                            Spacer()
                            Image(systemName: "chevron.right").font(.footnote)
                        }
                        .frame(maxWidth: .infinity, minHeight: 48)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    Divider()
                    Button(action: model.openSettings) {
                        HStack {
                            Label("Echo sozlamalari", systemImage: "gearshape")
                            Spacer()
                            Image(systemName: "chevron.right").font(.footnote)
                        }
                        .frame(maxWidth: .infinity, minHeight: 48)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
                .font(.system(size: 14))
                .padding(.horizontal, 12)
                .disabled(!model.hasFullAccess)
                if !model.hasFullAccess {
                    Text("Sozlamalarni saqlash uchun Full Access’ni yoqing.")
                        .font(.footnote).foregroundStyle(.secondary).padding(8)
                }
            }
            .frame(height: 216)
        }
        .tint(Color(red: 0.45, green: 0.34, blue: 0.76))
        .foregroundStyle(.primary)
    }
}

// MARK: - Voice panel

private struct VoicePanel: View {
    let model: KeyboardModel
    let reduceMotion: Bool

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                RoundButton(systemImage: "xmark", prominent: false, label: "Cancel dictation", action: model.cancelTapped)
                Spacer()
                if model.isRecording {
                    RoundButton(systemImage: "checkmark", prominent: true, label: "Stop and insert text", action: model.micTapped)
                } else {
                    ProgressView()
                        .frame(width: 44, height: 44)
                        .background(Color(uiColor: .keyCharacter).opacity(0.5), in: .circle)
                        .accessibilityLabel("Transcribing")
                }
            }
            .padding(.horizontal, 6)
            .frame(height: 48)

            Spacer()

            DictationDots(level: CGFloat(model.snapshot.level), isListening: model.isRecording, reduceMotion: reduceMotion)
                .frame(height: 40)

            Text(caption)
                .font(.callout)
                .foregroundStyle(.secondary)
                .padding(.top, 20)
                .contentTransition(.opacity)

            Spacer()
            Spacer()
        }
        .animation(reduceMotion ? nil : .easeInOut(duration: 0.2), value: model.isSlow)
    }

    private var caption: LocalizedStringKey {
        switch model.snapshot.phase {
        case .recording: "Listening…"
        case .transcribing: model.isSlow ? "Taking longer than usual…" : "Transcribing…"
        case .starting, .ready, .off: "Starting…"
        }
    }
}

/// A row of dots that rise into bars with the voice while listening, and a soft pulse that
/// runs across them while the transcript is on its way.
///
/// Plain capsules on a timer-driven timeline: in other apps' keyboards the extension got no
/// display-link frames, so a Canvas in `TimelineView(.animation)` never drew.
private struct DictationDots: View {
    let level: CGFloat
    let isListening: Bool
    let reduceMotion: Bool

    private let count = 10
    private let dot: CGFloat = 7
    private let spacing: CGFloat = 9
    private let maxHeight: CGFloat = 40

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1.0 / 20)) { timeline in
            let time = reduceMotion ? 0 : timeline.date.timeIntervalSinceReferenceDate
            HStack(spacing: spacing) {
                ForEach(0..<count, id: \.self) { index in
                    Capsule()
                        .fill(Color.primary.opacity(opacity(index, time: time)))
                        .frame(width: dot, height: height(index, time: time))
                }
            }
            .frame(height: maxHeight)
            // Eases between the few level samples per second the app sends.
            .animation(reduceMotion ? nil : .easeOut(duration: 0.12), value: level)
        }
        .accessibilityHidden(true)
    }

    private func position(_ index: Int) -> Double {
        (Double(index) + 0.5) / Double(count)
    }

    private func height(_ index: Int, time: TimeInterval) -> CGFloat {
        guard isListening, level.isFinite else { return dot }
        // Tallest in the middle; the wobble keeps steady speech moving.
        let envelope = sin(.pi * position(index))
        let wobble = reduceMotion ? 1 : 0.6 + 0.4 * sin(time * 9 + Double(index) * 1.3)
        return dot + min(max(level, 0), 1) * (maxHeight - dot) * envelope * wobble
    }

    private func opacity(_ index: Int, time: TimeInterval) -> Double {
        if isListening { return 0.75 }
        guard !reduceMotion else { return 0.45 }
        let wave = max(0, sin(time * 4 - position(index) * 2 * .pi))
        return 0.25 + 0.6 * wave * wave
    }
}

// MARK: - Keys

private struct KeyGrid: View {
    let model: KeyboardModel

    var body: some View {
        NativeKeySurface(model: model,
                         revision: "\(model.selectedEmojiCategory)-\(model.emojiRecents.joined())-\(model.page)-\(model.layout)-\(model.shift)-\(model.usesModernUzbekAlphabet)-\(model.needsGlobe)-\(model.returnKeyLabel)-\(model.returnKeySymbol ?? "-")")
    }
}

// MARK: - Styles

/// 44 pt circle: the black mic and ✓, or a light key-colored button.
private struct RoundButton: View {
    let systemImage: String
    let prominent: Bool
    let label: LocalizedStringKey
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.body.weight(.semibold))
                .foregroundStyle(prominent ? Color(uiColor: .systemBackground) : .primary)
                .frame(width: 44, height: 44)
                .background(prominent ? Color.primary : Color(uiColor: .keyCharacter), in: .circle)
                .shadow(color: .black.opacity(prominent ? 0 : 0.15), radius: 2, y: 1)
                .contentShape(.circle)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label)
    }
}

/// Approximates system keyboard keys: light keys for characters, darker for functions.
private struct KeyStyle: ButtonStyle {
    enum Kind { case character, function }
    let kind: Kind

    func makeBody(configuration: Configuration) -> some View {
        let lighter = (kind == .character) != configuration.isPressed
        configuration.label
            .foregroundStyle(.primary)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Color(uiColor: lighter ? .keyCharacter : .keyFunction), in: .rect(cornerRadius: 7, style: .continuous))
            .shadow(color: .black.opacity(configuration.isPressed ? 0.08 : 0.22), radius: 0, y: configuration.isPressed ? 0 : 1)
            // The gaps between keys still count as taps on the nearest key.
            .padding(.horizontal, 3)
            .padding(.vertical, 5)
            .contentShape(.rect)
    }
}

@MainActor
private extension UIColor {
    static var keyCharacter: UIColor { KeyboardAppearance.character }
    static var keyFunction: UIColor { KeyboardAppearance.function }
}
