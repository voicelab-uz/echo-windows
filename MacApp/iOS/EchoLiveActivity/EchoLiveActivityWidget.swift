import ActivityKit
import AppIntents
import SwiftUI
import WidgetKit

@main
struct EchoLiveActivityBundle: WidgetBundle {
    var body: some Widget { EchoLiveActivityWidget() }
}

struct EchoLiveActivityWidget: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: EchoLiveActivityAttributes.self) { context in
            EchoLockScreenView(context: context)
                .activityBackgroundTint(Color.black.opacity(0.92))
                .activitySystemActionForegroundColor(.white)
        } dynamicIsland: { context in
            DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    HStack(spacing: 8) {
                        EchoIslandMark().frame(width: 26, height: 30)
                        Text("Echo").font(.headline)
                    }.padding(.top, 4)
                }
                DynamicIslandExpandedRegion(.trailing) {
                    EchoIslandStatus(state: context.echoState, compact: false)
                        .padding(.top, 4)
                }
                DynamicIslandExpandedRegion(.bottom) {
                    VStack(spacing: 12) {
                        HStack {
                            Text(context.echoState.status).font(.subheadline).foregroundStyle(.secondary)
                            Spacer(minLength: 8)
                            EchoIslandMeter(state: context.echoState).frame(width: 70, height: 22)
                        }
                        if !context.isStale { EchoIslandControls(context: context) }
                    }.padding(.top, 10)
                }
            } compactLeading: {
                EchoIslandMark().frame(width: 20, height: 22)
                    .accessibilityLabel("Echo")
            } compactTrailing: {
                EchoIslandStatus(state: context.echoState, compact: true)
            } minimal: {
                EchoIslandMark().frame(width: 20, height: 22)
                    .accessibilityLabel("Echo: " + context.echoState.status)
            }
            .keylineTint(Color(red: 0.49, green: 0.43, blue: 0.94))
        }
    }
}

/// The two overlapping capsules repeat Echo's existing logo using native shapes;
/// no large bitmap enters the constrained minimal/compact presentation.
private struct EchoIslandMark: View {
    var body: some View {
        GeometryReader { geometry in
            let width = geometry.size.width
            ZStack {
                Capsule().fill(LinearGradient(colors: [Color(red: 0.47, green: 0.66, blue: 1), Color(red: 0.20, green: 0.30, blue: 0.79)], startPoint: .top, endPoint: .bottom))
                    .frame(width: width * 0.57, height: geometry.size.height)
                    .offset(x: width * 0.19)
                Capsule().fill(LinearGradient(colors: [Color(red: 1, green: 0.87, blue: 0.76), Color(red: 0.75, green: 0.67, blue: 0.94)], startPoint: .topLeading, endPoint: .bottomTrailing))
                    .frame(width: width * 0.57, height: geometry.size.height * 0.79)
                    .offset(x: -width * 0.19, y: geometry.size.height * 0.06)
            }.frame(width: geometry.size.width, height: geometry.size.height)
        }
    }
}

private struct EchoIslandStatus: View {
    let state: EchoLiveActivityAttributes.ContentState
    let compact: Bool
    var body: some View {
        Group {
            if state.phase == .recording, let start = state.recordingStartedAt {
                Text(timerInterval: start...start.addingTimeInterval(300), countsDown: false)
                    .monospacedDigit().frame(width: compact ? 43 : 62, alignment: .trailing)
            } else if compact {
                Image(systemName: state.phase == .unavailable ? "exclamationmark" : (state.phase == .transcribing || state.phase == .starting) ? "ellipsis" : "checkmark")
                    .accessibilityLabel(state.status)
            } else {
                Text(state.phase == .unavailable
                     ? state.text(uz: "Tekshiring", en: "Check Echo", ru: "Откройте Echo")
                     : state.phase == .starting
                     ? state.text(uz: "Tayyorlanmoqda", en: "Getting ready", ru: "Подготовка")
                     : state.phase == .transcribing
                     ? state.text(uz: "Matnga", en: "Processing", ru: "Обработка")
                     : state.text(uz: "Tayyor", en: "Ready", ru: "Готов"))
            }
        }
        .font(compact ? .caption2.weight(.semibold) : .subheadline.weight(.semibold))
        .foregroundStyle(state.phase == .recording ? Color(red: 0.77, green: 0.73, blue: 1) : .white)
        .contentTransition(.numericText())
    }
}

/// A static sample of the measured audio level, refreshed at most once a second.
/// No looping animation suggests recording while Echo is only microphone-ready.
private struct EchoIslandMeter: View {
    let state: EchoLiveActivityAttributes.ContentState
    var body: some View {
        HStack(alignment: .center, spacing: 3) {
            ForEach(0..<9, id: \.self) { index in
                Capsule()
                    .fill(state.phase == .recording ? Color(red: 0.69, green: 0.62, blue: 1) : Color.white.opacity(0.22))
                    .frame(width: 4, height: height(index))
            }
        }
        .accessibilityLabel(state.phase == .recording ? state.text(uz: "Mikrofon ovoz darajasi", en: "Microphone audio level", ru: "Уровень звука микрофона") : state.status)
    }
    private func height(_ index: Int) -> CGFloat {
        guard state.phase == .recording else { return 3 }
        let envelope = 1 - abs(Double(index - 4)) / 5
        return 3 + 19 * min(1, max(0, state.audioLevel)) * envelope
    }
}

private struct EchoIslandControls: View {
    let context: ActivityViewContext<EchoLiveActivityAttributes>
    var body: some View {
        HStack(spacing: 10) {
            if context.echoState.phase == .recording {
                Button(intent: EchoStopRecordingIntent(sessionID: context.attributes.sessionID)) {
                    Label(context.echoState.text(uz: "To‘xtatish", en: "Stop recording", ru: "Стоп"), systemImage: "stop.fill")
                        .frame(maxWidth: .infinity, minHeight: 44)
                }
                .buttonStyle(.borderedProminent).tint(Color(red: 0.51, green: 0.43, blue: 0.89))
            }
            Button(intent: EchoEndSessionIntent(sessionID: context.attributes.sessionID)) {
                Label(context.echoState.text(uz: "Seansni tugatish", en: "End session", ru: "Завершить"), systemImage: "xmark")
                    .frame(maxWidth: .infinity, minHeight: 44)
            }
            .buttonStyle(.bordered).tint(.white)
        }
        .font(.subheadline.weight(.semibold))
    }
}

private struct EchoLockScreenView: View {
    let context: ActivityViewContext<EchoLiveActivityAttributes>
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 10) {
                EchoIslandMark().frame(width: 28, height: 32).accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 3) {
                    Text("Echo").font(.headline)
                    Text(context.echoState.status).font(.subheadline).foregroundStyle(.secondary)
                }
                Spacer(minLength: 8)
                EchoIslandStatus(state: context.echoState, compact: false)
            }
            EchoIslandMeter(state: context.echoState).frame(height: 22)
            if !context.isStale { EchoIslandControls(context: context) }
        }
        .foregroundStyle(.white)
        .padding(16)
    }
}

private extension ActivityViewContext where Attributes == EchoLiveActivityAttributes {
    var echoState: EchoLiveActivityAttributes.ContentState {
        guard isStale else { return state }
        var value = state
        value.phase = .unavailable
        value.audioLevel = 0
        value.recordingStartedAt = nil
        return value
    }
}
