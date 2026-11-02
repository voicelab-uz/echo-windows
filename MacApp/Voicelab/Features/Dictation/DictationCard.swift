import SwiftUI
import VoiceLabCore

struct DictationCard: View {
    let model: DictationModel
    @Bindable var preferences: Preferences
    @State private var confirmRetry = false
    var body: some View {
        Surface {
            VStack(alignment: .leading, spacing: 18) {
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: 20) {
                        identity
                        Spacer(minLength: 12)
                        controls.fixedSize()
                    }
                    VStack(alignment: .leading, spacing: 18) {
                        identity
                        controls
                    }
                }
                if !model.isBusy {
                    Divider().overlay(Design.border)
                    HStack(spacing: 12) {
                        Spacer()
                        Text(AppLocalization.text("Boshlash / tugatish")).font(.caption).foregroundStyle(
                            .secondary)
                        ShortcutLabel()
                    }
                }
                if let result = model.result, !model.isBusy {
                    Divider()
                    Text(result).font(.callout).lineSpacing(5).textSelection(.enabled).frame(
                        maxWidth: .infinity, alignment: .leading)
                    HStack {
                        AppLabel(
                            AppLocalization.text(model.message ?? "Tayyor"),
                            systemImage: "checkmark.circle.fill"
                        )
                        .foregroundStyle(Design.green).font(.caption)
                        Spacer()
                        Button {
                            TextInsertion.copy(result)
                        } label: {
                            AppLabel(AppLocalization.text("Nusxalash"), systemImage: "doc.on.doc")
                        }
                    }
                }
            }
        }
        .confirmationDialog(AppLocalization.text("Audioni qayta yuborilsinmi?"), isPresented: $confirmRetry) {
            Button(AppLocalization.text("Qayta yuborish")) { model.retry() }
        } message: {
            Text(
                AppLocalization.text(
                    "Oldingi so‘rov serverda bajarilgan bo‘lsa, qayta yuborish yana foydalanish vaqtini sarflashi mumkin."
                )
            )
        }
    }
    private var identity: some View {
        HStack(spacing: 16) {
            WorkspaceIcon(
                symbol: model.phase == .recording ? "waveform" : "mic",
                size: 54, tint: model.phase == .recording ? .red : Design.accent)
            VStack(alignment: .leading, spacing: 7) {
                Text(title).font(.system(size: 18, weight: .semibold)).tracking(-0.3)
                    .fixedSize(horizontal: false, vertical: true)
                if model.phase == .recording {
                    HStack(spacing: 10) {
                        Text(
                            Duration.seconds(model.recorder.elapsed).formatted(
                                .time(pattern: .minuteSecond))
                        ).monospacedDigit()
                        ProgressView(value: model.recorder.level).frame(width: 90).tint(.red)
                    }.font(.caption).foregroundStyle(.secondary)
                } else {
                    Text(subtitle).font(.system(size: 12)).foregroundStyle(.secondary)
                        .lineSpacing(3).fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    @ViewBuilder
    private var controls: some View {
        if model.phase == .transcribing || model.phase == .preparing {
            HStack(spacing: 12) {
                ProgressView().controlSize(.small)
                Button(AppLocalization.text("Bekor qilish")) { model.discard() }.controlSize(.large)
            }
        } else if model.canRetry {
            HStack(spacing: 8) {
                Button(AppLocalization.text("O‘chirish")) { model.discard() }
                Button(AppLocalization.text("Qayta yuborish")) { confirmRetry = true }
            }
        } else {
            Button {
                model.toggle()
            } label: {
                AppLabel(
                    model.phase == .recording
                        ? AppLocalization.text("Tugatish") : AppLocalization.text("Yozishni boshlash"),
                    systemImage: model.phase == .recording ? "stop.fill" : "mic.fill"
                )
                .font(.system(size: 13, weight: .semibold))
                .padding(.vertical, 3)
            }
            .buttonStyle(.borderedProminent).controlSize(.large)
            .tint(model.phase == .recording ? .red : Design.accent)
        }
    }
    private var title: String {
        switch model.phase {
        case .idle: AppLocalization.text("Ovozingiz bilan yozing")
        case .preparing: AppLocalization.text("Mikrofon tayyorlanmoqda")
        case .recording: AppLocalization.text("Tinglayapman…")
        case .transcribing: AppLocalization.text("Matnga aylantirilmoqda…")
        case .failed: AppLocalization.text("Ovozingiz bilan yozing")
        }
    }
    private var subtitle: String {
        model.phase == .transcribing
            ? AppLocalization.text("Natija tayyor bo‘lganda shu yerda ko‘rinadi.")
            : AppLocalization.text("Fikringizni tabiiy ayting. Qolganini Echo bajaradi.")
    }
}
