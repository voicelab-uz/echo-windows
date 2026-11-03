import SwiftUI
import VoiceLabCore

/// The camera silhouette grows sideways and down; its top edge never moves.
struct DictationIslandView: View {
    let model: DictationModel
    let recording: IslandRecordingSession
    let preferences: Preferences
    let notices: IslandNoticeCenter
    let presentation: IslandPresentation
    let openMain: () -> Void
    let hide: () -> Void
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        let layout = presentation.layout
        let openSize = layout.surfaceSize(notice: presentation.notice)
        let unfolded = presentation.expanded || reduceMotion
        let shape = CameraIslandShape(
            cameraWidth: layout.cameraWidth, cameraHeight: layout.cameraHeight,
            shoulder: unfolded ? 10 : 0, bottomRadius: unfolded ? 24 : 8)
        ZStack(alignment: .top) {
            IslandGlassSurface(shape: shape)
            VStack(spacing: 0) {
                Color.clear.frame(height: layout.cameraHeight)
                    .accessibilityHidden(true).allowsHitTesting(false)
                if let notice = presentation.notice {
                    if notice.kind == .startup {
                        startupCard(notice)
                    } else {
                        noticeCard(notice)
                    }
                } else {
                    recordingCapsule
                }
            }
            .frame(width: openSize.width, height: openSize.height, alignment: .top)
            .opacity(presentation.expanded ? 1 : 0)
            .animation(
                .easeInOut(duration: presentation.expanded ? 0.24 : 0.16)
                    .delay(presentation.expanded && !reduceMotion ? 0.08 : 0),
                value: presentation.expanded)
        }
        .frame(
            width: unfolded ? openSize.width : layout.foldedWidth,
            height: unfolded ? openSize.height : layout.foldedHeight,
            alignment: .top
        )
        .clipShape(shape)
        .contentShape(shape)
        .opacity(reduceMotion && !presentation.expanded ? 0 : 1)
        .allowsHitTesting(presentation.expanded)
        .accessibilityHidden(!presentation.expanded)
        .environment(\.locale, preferences.interfaceLanguage.locale)
        .foregroundStyle(.white)
        .preferredColorScheme(.dark)
        .frame(width: layout.panelSize.width, height: layout.panelSize.height, alignment: .top)
        .ignoresSafeArea(.container, edges: .top)
        .clipped()
        .animation(reduceMotion ? nil : .smooth(duration: 0.36), value: presentation.notice?.id)
    }

    private var recordingCapsule: some View {
        HStack(spacing: 10) {
            HStack(spacing: 7) {
                Circle()
                    .fill(
                        recording.phase == .recording
                            ? Color(red: 1, green: 0.48, blue: 0.42) : .white.opacity(0.4)
                    )
                    .frame(width: 4, height: 4)
                    .accessibilityHidden(true)
                Text(
                    Duration.seconds(recording.phase == .preparing ? 0 : recording.recorder.elapsed)
                        .formatted(.time(pattern: .minuteSecond(padMinuteToLength: 2)))
                )
                .font(.system(size: 12, weight: .medium, design: .rounded))
                .monospacedDigit()
                .foregroundStyle(.white.opacity(0.8))
                .lineLimit(1)
            }
            .frame(width: 62, alignment: .leading)
            DictationWaveform(recorder: recording.recorder, phase: recording.phase)
                .frame(maxWidth: .infinity)
            HStack(spacing: 6) {
                if recording.phase == .recording {
                    Button {
                        recording.stop()
                    } label: {
                        AppIcon(systemName: "stop.fill", size: 10)
                            .frame(width: 28, height: 28)
                            .background(.white.opacity(0.12), in: Circle())
                    }
                    .help(AppLocalization.text("Yozuvni tugatish · %@", recording.isTrial ? "fn" : preferences.shortcut.displayName))
                    .accessibilityLabel(AppLocalization.text("Yozuvni tugatish"))
                }
                Button {
                    recording.cancel()
                } label: {
                    AppIcon(systemName: "xmark", size: 10)
                        .foregroundStyle(.white.opacity(0.6))
                        .frame(width: 24, height: 28)
                        .contentShape(Rectangle())
                }
                .help(AppLocalization.text("Yozuvni bekor qilish"))
                .accessibilityLabel(AppLocalization.text("Yozuvni bekor qilish"))
            }
            .buttonStyle(.plain)
            .frame(width: 62, alignment: .trailing)
        }
        .padding(.horizontal, 22)
        .frame(
            width: presentation.layout.recordingWidth,
            height: presentation.layout.recordingHeight)
        .contextMenu {
            Button(AppLocalization.text("Echo’ni ochish"), action: openMain)
            if recording.isBusy { Button(AppLocalization.text("Bekor qilish")) { recording.cancel() } }
            if !recording.isTrial, let result = model.result {
                Button(AppLocalization.text("Matnni nusxalash")) { TextInsertion.copy(result) }
            }
            Divider()
            Button(AppLocalization.text("Hozircha yashirish"), action: hide)
            Button(AppLocalization.text("Echo’dan chiqish")) { NSApplication.shared.terminate(nil) }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(status)
    }

    private var status: String {
        switch recording.phase {
        case .recording: AppLocalization.text("Tinglayapman")
        case .preparing: AppLocalization.text("Tayyorlanmoqda")
        case .transcribing: AppLocalization.text("Matnga aylantirish")
        case .failed: AppLocalization.text("Yozuv to‘xtadi")
        case .idle: "Echo"
        }
    }

    private func startupCard(_ notice: IslandNotice) -> some View {
        HStack(spacing: 12) {
            Button {
                notices.dismiss()
                openMain()
            } label: {
                HStack(spacing: 12) {
                    AppBrandIcon()
                        .frame(width: 38, height: 38)
                        .clipShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
                        .accessibilityHidden(true)
                    VStack(alignment: .leading, spacing: 5) {
                        Text(AppLocalization.text(notice.title))
                            .font(.system(size: 13, weight: .semibold))
                        Text(AppLocalization.text(notice.message))
                            .font(.system(size: 12))
                            .foregroundStyle(.white.opacity(0.65))
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(AppLocalization.text("Echo’ni ochish"))
            dismissNoticeButton
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 12)
        .frame(width: 376, height: notice.height)
        .accessibilityElement(children: .contain)
    }

    private var dismissNoticeButton: some View {
        Button {
            notices.dismiss()
        } label: {
            TimelineView(
                .animation(minimumInterval: 0.05, paused: notices.deadline == nil || reduceMotion)
            ) { timeline in
                AppIcon(systemName: "xmark", size: 10)
                    .frame(width: 26, height: 26)
                    .background(Circle().stroke(.white.opacity(0.2), lineWidth: 1.5))
                    .overlay(
                        Circle().trim(from: 0, to: notices.progress(at: timeline.date))
                            .stroke(
                                .white.opacity(0.8),
                                style: StrokeStyle(lineWidth: 1.5, lineCap: .round)
                            )
                            .rotationEffect(.degrees(-90)))
            }
        }.buttonStyle(.plain).accessibilityLabel(AppLocalization.text("Xabarni yopish"))
    }

    private func noticeCard(_ notice: IslandNotice) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .center, spacing: 10) {
                if notice.kind == .upgrade {
                    AppBrandIcon()
                        .frame(width: 22, height: 22)
                        .accessibilityHidden(true)
                } else {
                    AppIcon(
                        systemName: notice.kind == .error
                            ? "exclamationmark.circle"
                            : notice.kind == .warning ? "exclamationmark.triangle" : "checkmark.circle"
                    )
                    .font(.system(size: 16, weight: .medium))
                    .frame(width: 18, height: 18)
                    .foregroundStyle(
                        notice.kind == .error ? Color.red : notice.kind == .warning ? .orange : .green
                    )
                }
                Text(AppLocalization.text(notice.title)).font(.system(size: 13, weight: .semibold))
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
                dismissNoticeButton
            }
            ScrollView {
                Text(AppLocalization.text(notice.message)).font(.system(size: 12)).lineSpacing(3)
                    .foregroundStyle(.white.opacity(0.65)).frame(maxWidth: .infinity, alignment: .leading)
            }.scrollIndicators(.hidden)
            if notice.action == .copyResult, let result = model.result {
                HStack {
                    Spacer()
                    Button(AppLocalization.text("Matnni nusxalash")) {
                        TextInsertion.copy(result)
                        notices.dismiss()
                    }.buttonStyle(.bordered).controlSize(.small)
                }
            } else if notice.action == .openPlans {
                Button {
                    if NSWorkspace.shared.open(RuntimeBackend.environment.desktopBillingURL) {
                        notices.dismiss()
                    }
                } label: {
                    HStack(spacing: 8) {
                        Text(AppLocalization.text("Tarifni oshirish"))
                        AppIcon(systemName: "arrow.up.right", size: 11)
                    }
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.black)
                    .frame(maxWidth: .infinity, minHeight: 32)
                    .background(.white, in: RoundedRectangle(cornerRadius: 9))
                    .contentShape(RoundedRectangle(cornerRadius: 9))
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 20).padding(.vertical, 12)
        .frame(width: 376, height: notice.height, alignment: .top)
        .accessibilityElement(children: .contain)
    }
}
