import ActivityKit
import AppIntents
import Foundation

/// LiveActivityIntent runs in the app process without opening its UI. Commands
/// remain subject to the host's actual recording phase and microphone policy.
struct EchoStopRecordingIntent: LiveActivityIntent {
    static var title: LocalizedStringResource { "Stop Echo recording" }
    static var openAppWhenRun: Bool { false }
    static var isDiscoverable: Bool { false }
    @Parameter(title: "Session") var sessionID: String
    init() {}
    init(sessionID: String) { self.sessionID = sessionID }
    @MainActor
    func perform() async throws -> some IntentResult {
        guard let store = VoiceBridge.Store() else { return .result() }
        let snapshot = store.snapshot()
        guard snapshot.sessionID == sessionID, snapshot.isAlive(), snapshot.phase == .recording else { return .result() }
        store.send(.stop)
        return .result()
    }
}

struct EchoEndSessionIntent: LiveActivityIntent {
    static var title: LocalizedStringResource { "End Echo session" }
    static var openAppWhenRun: Bool { false }
    static var isDiscoverable: Bool { false }
    @Parameter(title: "Session") var sessionID: String
    init() {}
    init(sessionID: String) { self.sessionID = sessionID }
    @MainActor
    func perform() async throws -> some IntentResult {
        guard let store = VoiceBridge.Store() else { return .result() }
        let snapshot = store.snapshot()
        guard snapshot.sessionID == sessionID, snapshot.isAlive(), snapshot.phase != .off else { return .result() }
        store.send(.endSession)
        NotificationCenter.default.post(name: .echoLiveActivityEndRequested, object: sessionID)
        // If the app was terminated, there may be no host observer. Ending this
        // activity never fabricates a transcript or activates an audio session.
        for activity in Activity<EchoLiveActivityAttributes>.activities where activity.attributes.sessionID == sessionID {
            await activity.end(nil, dismissalPolicy: .immediate)
        }
        return .result()
    }
}
