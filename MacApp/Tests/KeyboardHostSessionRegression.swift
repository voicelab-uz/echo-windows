import Foundation

// UIKit and audio are the only platform boundaries replaced here. The script
// compiles the production KeyboardSessionHost and VoiceBridge, with isolated defaults.
enum DictationLanguage { case auto }
enum DictationError: Error {
    case microphoneDenied, noMicrophone, audioUnavailable, notConfigured
    case serviceUnavailable, offline, noCredits, noSpeech, recognitionFailed
}
enum SpeechEvent { case level(Float), finished(String), failed(DictationError) }
@MainActor final class EchoLiveActivityController {
    static let shared = EchoLiveActivityController()
    static var requestedSessions: [String] = []
    static var activeSessionID: String?
    func cleanupStaleActivitiesAtLaunch() -> Bool { Self.activeSessionID == nil }
    func end(sessionID: String) {
        if Self.activeSessionID == sessionID { Self.activeSessionID = nil }
    }
    func beginForegroundSession(snapshot: VoiceBridge.Snapshot, keepsReady: Bool) {
        precondition(UIApplication.shared.applicationState == .active)
        precondition(!SpeechPermissions.denied)
        precondition(snapshot.phase == .starting)
        Self.requestedSessions.append(snapshot.sessionID!)
        Self.activeSessionID = snapshot.sessionID
    }
    func synchronize(snapshot: VoiceBridge.Snapshot, keepsReady: Bool, canStartActivity: Bool) {
        if canStartActivity {
            precondition(UIApplication.shared.applicationState == .active)
            precondition(snapshot.sessionID != nil)
            precondition(snapshot.phase == .recording || snapshot.phase == .ready && keepsReady)
        }
    }
}
let AVAudioSessionInterruptionTypeKey = "test.interruptionType"
final class AVAudioSession: NSObject, @unchecked Sendable {
    static let interruptionNotification = Notification.Name("test.echo.audio.interruption")
    private static let shared = AVAudioSession()
    static func sharedInstance() -> AVAudioSession { shared }
    enum InterruptionType: UInt { case ended = 0, began = 1 }
}
@MainActor final class AVAudioApplication {
    static let shared = AVAudioApplication()
    enum RecordPermission { case granted, denied }
    var recordPermission: RecordPermission { SpeechPermissions.denied ? .denied : .granted }
}
@MainActor enum SpeechPermissions {
    static var denied = false
    static func request() async throws(DictationError) {
        if denied { throw .microphoneDenied }
    }
}
struct UIBackgroundTaskIdentifier: Equatable {
    let rawValue: Int
    static let invalid = Self(rawValue: -1)
}
@MainActor final class UIApplication {
    static let shared = UIApplication()
    enum State { case active, inactive, background }
    var applicationState = State.active
    private var nextTask = 0
    func beginBackgroundTask(withName: String, expirationHandler: @escaping () -> Void) -> UIBackgroundTaskIdentifier {
        nextTask += 1
        return .init(rawValue: nextTask)
    }
    func endBackgroundTask(_ id: UIBackgroundTaskIdentifier) {}
}
@MainActor final class SpeechSession {
    static var initializations = 0
    static var begins = 0
    static var primes = 0
    static var closes = 0
    static var failNextBegin = false
    static var microphoneActive = false
    static var foregroundPrimesOnly = true
    static var holdNextCancel = false
    static var cancelBarrier: CheckedContinuation<Void, Never>?
    static var finishes = 0
    static var releases = 0
    static var holdNextTranscription = false
    static var pendingTranscription: SpeechSession?
    let keepsReady: Bool
    private var continuation: AsyncStream<SpeechEvent>.Continuation?
    init(keepMicrophoneReady: Bool) throws(DictationError) {
        Self.initializations += 1
        keepsReady = keepMicrophoneReady
    }
    func open() async throws(DictationError) -> AsyncStream<SpeechEvent> {
        precondition(EchoLiveActivityController.requestedSessions.last == VoiceBridge.Store()?.snapshot().sessionID,
                     "Host crossed into audio setup before its foreground Live Activity request")
        let (stream, continuation) = AsyncStream.makeStream(of: SpeechEvent.self)
        self.continuation = continuation
        return stream
    }
    func prepareKeyboardSession() async throws(DictationError) {
        Self.foregroundPrimesOnly = Self.foregroundPrimesOnly && UIApplication.shared.applicationState == .active
        Self.primes += 1
        Self.microphoneActive = true
    }
    func beginUtterance(language: DictationLanguage) async throws(DictationError) {
        Self.begins += 1
        Self.microphoneActive = true
        // A suspension exposes duplicate Start races in the real host.
        try? await Task.sleep(for: .milliseconds(40))
        if Self.failNextBegin {
            Self.failNextBegin = false
            throw .audioUnavailable
        }
    }
    func finishUtterance() async {
        Self.finishes += 1
        if !keepsReady { Self.microphoneActive = false }
        if Self.holdNextTranscription {
            Self.holdNextTranscription = false
            Self.pendingTranscription = self
            return
        }
        continuation?.yield(.finished("Salom dunyo"))
    }
    static func completePendingTranscription() {
        let pending = pendingTranscription
        pendingTranscription = nil
        pending?.continuation?.yield(.finished("Salom dunyo"))
    }
    func releaseMicrophone() async {
        Self.releases += 1
        Self.microphoneActive = false
    }
    func cancelUtterance() async {
        if Self.holdNextCancel {
            Self.holdNextCancel = false
            await withCheckedContinuation { Self.cancelBarrier = $0 }
        }
        if !keepsReady { Self.microphoneActive = false }
    }
    static func releaseCancel() {
        let pending = cancelBarrier
        cancelBarrier = nil
        pending?.resume()
    }
    func close() async {
        Self.closes += 1
        Self.microphoneActive = false
        continuation?.finish()
    }
}

// This test-only extension shares the generated compilation unit with the real
// host. Aging its private activity timestamp tests the actual heartbeat without
// sleeping five minutes or adding clock mutation hooks to the production app.
@MainActor private extension KeyboardSessionHost {
    func ageActivityForRegression() { lastActivity = .now.addingTimeInterval(-301) }
}

@main struct KeyboardHostSessionRegression {
    @MainActor static func settle() async {
        try? await Task.sleep(for: .milliseconds(150))
    }

    @MainActor static func checkCancellationBarrier(_ host: KeyboardSessionHost,
                                                   store: VoiceBridge.Store) async {
        UIApplication.shared.applicationState = .active
        store.microphoneMode = .readySession
        await host.start(listening: true)
        let beginsBeforeCancel = SpeechSession.begins
        SpeechSession.holdNextCancel = true
        store.send(.cancel)
        await settle()
        precondition(SpeechSession.cancelBarrier != nil, "Cancellation did not reach the controlled audio boundary")
        precondition(host.phase == .starting && store.snapshot().phase == .starting,
                     "Start was advertised before the previous cancellation completed")
        store.send(.start)
        await settle()
        precondition(host.phase == .starting && SpeechSession.begins == beginsBeforeCancel,
                     "A new take began while the previous recorder cancellation was pending")
        SpeechSession.releaseCancel()
        await settle()
        precondition(host.phase == .ready && SpeechSession.microphoneActive)
        store.send(.start)
        await settle()
        precondition(host.phase == .recording && SpeechSession.begins == beginsBeforeCancel + 1,
                     "A completed cancellation did not permit exactly one clean new take")
        await host.stopAndWait()

        await host.start(listening: true)
        let beginsBeforeEnd = SpeechSession.begins
        SpeechSession.holdNextCancel = true
        store.send(.cancel)
        await settle()
        precondition(host.phase == .starting && SpeechSession.cancelBarrier != nil)
        store.send(.endSession)
        await settle()
        precondition(host.phase == .off && !SpeechSession.microphoneActive)
        SpeechSession.releaseCancel()
        await settle()
        precondition(host.phase == .off && store.snapshot().phase == .off,
                     "A late cancellation resurrected a session after explicit End Session")
        precondition(!host.keepsMicrophoneReady && !SpeechSession.microphoneActive &&
                     SpeechSession.begins == beginsBeforeEnd)
        await host.stopAndWait()
    }

    @MainActor static func interrupt(_ type: AVAudioSession.InterruptionType) {
        NotificationCenter.default.post(name: AVAudioSession.interruptionNotification,
            object: AVAudioSession.sharedInstance(),
            userInfo: [AVAudioSessionInterruptionTypeKey: type.rawValue])
    }

    @MainActor static func checkAudioInterruptions(_ host: KeyboardSessionHost,
                                                  store: VoiceBridge.Store) async {
        UIApplication.shared.applicationState = .active
        store.microphoneMode = .readySession
        await host.start(listening: false)
        let idleBegins = SpeechSession.begins
        interrupt(.began)
        await settle()
        precondition(host.phase == .off && host.failure == .unavailable && !SpeechSession.microphoneActive,
                     "An interrupted ready microphone was still advertised as usable")
        interrupt(.ended)
        await settle()
        precondition(host.phase == .off && SpeechSession.begins == idleBegins && !SpeechSession.microphoneActive,
                     "Interruption end must not reopen microphone capture")
        await host.stopAndWait()

        let starting = Task { await host.start(listening: true) }
        try? await Task.sleep(for: .milliseconds(10))
        precondition(host.phase == .starting)
        interrupt(.began)
        await starting.value
        await settle()
        precondition(host.phase == .off && !SpeechSession.microphoneActive,
                     "An interrupted pending activation resurrected a microphone session")
        await host.stopAndWait()

        await host.start(listening: true)
        let finishes = SpeechSession.finishes
        let successful = host.successfulDictations
        interrupt(.began)
        await settle()
        precondition(SpeechSession.finishes == finishes + 1 && host.successfulDictations == successful + 1,
                     "A recording interruption must finalize exactly one captured take")
        precondition(host.phase == .off && !SpeechSession.microphoneActive &&
                     store.snapshot().transcript?.text == "Salom dunyo",
                     "Ending interrupted capture discarded its completed transcript")
        await host.stopAndWait()

        await host.start(listening: true)
        SpeechSession.holdNextTranscription = true
        store.send(.stop)
        await settle()
        precondition(host.phase == .transcribing && SpeechSession.pendingTranscription != nil)
        let releases = SpeechSession.releases
        let closes = SpeechSession.closes
        let count = host.successfulDictations
        interrupt(.began)
        await settle()
        precondition(host.phase == .transcribing && SpeechSession.pendingTranscription != nil &&
                     SpeechSession.releases == releases + 1 && SpeechSession.closes == closes,
                     "An interruption canceled an upload instead of only releasing idle capture")
        precondition(!SpeechSession.microphoneActive && !host.keepsMicrophoneReady)
        interrupt(.ended)
        await settle()
        precondition(!SpeechSession.microphoneActive && host.phase == .transcribing)
        SpeechSession.completePendingTranscription()
        await settle()
        precondition(host.phase == .off && host.successfulDictations == count + 1 &&
                     store.snapshot().transcript?.text == "Salom dunyo" && !SpeechSession.microphoneActive,
                     "An already-running transcription was lost or restarted microphone capture")
        await host.stopAndWait()
    }
    @MainActor static func main() async {
        let preferences = UserDefaults(suiteName: VoiceBridge.appGroup)!
        preferences.removePersistentDomain(forName: VoiceBridge.appGroup)
        defer { preferences.removePersistentDomain(forName: VoiceBridge.appGroup) }
        let store = VoiceBridge.Store()!
        precondition(store.microphoneMode == .readySession, "Fresh install must use the approved ready-session default")
        let now = Date.now
        precondition(!VoiceBridge.shouldEndKeyboardSession(lastActivity: now.addingTimeInterval(-299.99), now: now, appIsActive: false, keyboardIsVisible: false))
        precondition(VoiceBridge.shouldEndKeyboardSession(lastActivity: now.addingTimeInterval(-300), now: now, appIsActive: false, keyboardIsVisible: false), "Five-minute boundary did not expire")
        precondition(!VoiceBridge.shouldEndKeyboardSession(lastActivity: now.addingTimeInterval(-600), now: now, appIsActive: true, keyboardIsVisible: false))
        precondition(!VoiceBridge.shouldEndKeyboardSession(lastActivity: now.addingTimeInterval(-600), now: now, appIsActive: false, keyboardIsVisible: true))
        precondition(!VoiceBridge.shouldEndKeyboardSession(lastActivity: now.addingTimeInterval(30), now: now, appIsActive: false, keyboardIsVisible: false))
        store.setKeyboardVisible(true, at: now)
        precondition(store.keyboardIsVisible(at: now.addingTimeInterval(VoiceBridge.staleAfter - 0.01)))
        precondition(!store.keyboardIsVisible(at: now.addingTimeInterval(VoiceBridge.staleAfter)), "Killed keyboard visibility did not expire")
        precondition(!store.keyboardIsVisible(at: now.addingTimeInterval(-1)), "Future visibility lease stayed valid")
        store.setKeyboardVisible(false, at: now)
        precondition(!store.keyboardIsVisible(at: now))
        let host = KeyboardSessionHost()
        await host.start(listening: true)
        precondition(host.phase == .recording && host.keepsMicrophoneReady)
        precondition(SpeechSession.primes == 0, "Starting a take must not separately prime idle audio")
        let liveSnapshot = store.snapshot()
        do {
            let unusedSwiftUIHost = KeyboardSessionHost()
            precondition(store.snapshot() == liveSnapshot, "Transient SwiftUI State host construction overwrote the active bridge")
            precondition(EchoLiveActivityController.activeSessionID == liveSnapshot.sessionID,
                         "Transient host construction ended the active Live Activity")
            unusedSwiftUIHost.stop()
        }
        precondition(store.snapshot() == liveSnapshot && EchoLiveActivityController.activeSessionID == liveSnapshot.sessionID,
                     "Unused host stop/deinit interfered with the installed owner")
        let initializations = SpeechSession.initializations
        let firstBegins = SpeechSession.begins
        store.send(.stop)
        await settle()
        precondition(host.phase == .ready && SpeechSession.microphoneActive)
        precondition(host.successfulDictations == 1 && store.snapshot().transcript?.text == "Salom dunyo")
        // This is the extension command, with Echo in the background: no URL open,
        // no host/session reconstruction, and no foreground activation round-trip.
        UIApplication.shared.applicationState = .background
        store.send(.start)
        await settle()
        precondition(host.phase == .recording && SpeechSession.begins == firstBegins + 1)
        precondition(SpeechSession.initializations == initializations, "Second take recreated the host audio session")
        store.send(.cancel)
        await settle()
        precondition(host.phase == .ready && SpeechSession.microphoneActive)
        store.send(.endSession)
        await settle()
        precondition(host.phase == .off && !host.keepsMicrophoneReady && !SpeechSession.microphoneActive)
        await host.stopAndWait()

        await checkCancellationBarrier(host, store: store)
        await checkAudioInterruptions(host, store: store)

        UIApplication.shared.applicationState = .active
        store.microphoneMode = .recordingOnly
        await host.start(listening: true)
        precondition(host.phase == .recording && !host.keepsMicrophoneReady, "Fresh session ignored the chosen microphone policy")
        store.send(.stop)
        await settle()
        precondition(host.phase == .off && !SpeechSession.microphoneActive, "Recording-only finish kept the microphone active")
        await host.stopAndWait()
        await host.start(listening: true)
        store.send(.cancel)
        await settle()
        precondition(host.phase == .off && !SpeechSession.microphoneActive, "Recording-only cancel kept the microphone active")
        await host.stopAndWait()

        store.microphoneMode = .readySession
        let beforeDuplicate = SpeechSession.begins
        let firstStart = Task { await host.start(listening: true) }
        try? await Task.sleep(for: .milliseconds(10))
        await host.start(listening: true)
        await firstStart.value
        precondition(host.phase == .recording && SpeechSession.begins == beforeDuplicate + 1, "Duplicate Start opened two takes")
        await host.stopAndWait()
        SpeechSession.failNextBegin = true
        await host.start(listening: true)
        await settle()
        precondition(host.phase == .off && host.failure == .unavailable && !SpeechSession.microphoneActive, "Failed activation advertised a usable session")
        await host.stopAndWait()
        SpeechPermissions.denied = true
        await host.start(listening: true)
        precondition(host.phase == .off && host.failure == .permissionDenied && !SpeechSession.microphoneActive)
        SpeechPermissions.denied = false
        await host.stopAndWait()

        let primesBefore = SpeechSession.primes
        await host.start(listening: false, keepMicrophoneReady: true)
        precondition(host.phase == .ready && SpeechSession.primes == primesBefore + 1)
        await host.stopAndWait()
        UIApplication.shared.applicationState = .background
        let blockedStart = Task { await host.start(listening: false, keepMicrophoneReady: true) }
        try? await Task.sleep(for: .milliseconds(20))
        await host.stopAndWait()
        await blockedStart.value
        precondition(SpeechSession.primes == primesBefore + 1 && !SpeechSession.microphoneActive, "Background activation primed the microphone")
        precondition(SpeechSession.foregroundPrimesOnly)

        UIApplication.shared.applicationState = .active
        await host.start(listening: false)
        UIApplication.shared.applicationState = .background
        store.setKeyboardVisible(false)
        host.ageActivityForRegression()
        try? await Task.sleep(for: .milliseconds(2200))
        precondition(host.phase == .off && !SpeechSession.microphoneActive, "Idle heartbeat did not release the expired ready session")
        await host.stopAndWait()

        UIApplication.shared.applicationState = .active
        await host.start(listening: true)
        store.setKeyboardVisible(true)
        host.ageActivityForRegression()
        try? await Task.sleep(for: .milliseconds(2200))
        precondition(host.phase == .off && !SpeechSession.microphoneActive, "Recording cap was incorrectly extended by foreground/visibility")
        await host.stopAndWait()
        print("Keyboard host session regression passed: ready reuse, transient-host isolation, cancellation barrier/end fencing, interruption capture/upload preservation, recording-only release, explicit end, duplicate Start, activation/permission failure, foreground-only priming, actual idle heartbeat, visibility leases, and separate recording cap")
    }
}
