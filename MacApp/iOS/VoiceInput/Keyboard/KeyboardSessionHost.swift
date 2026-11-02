import Foundation
import Observation
import UIKit
import AVFAudio

/// App side of the voice keyboard. The keyboard extension can't record, so the app records
/// while an utterance is active and publishes transcripts for the keyboard. Explicit
/// keyboard-ready sessions keep the microphone active between takes; idle audio is discarded.
@MainActor
@Observable
final class KeyboardSessionHost {
    static let shared = KeyboardSessionHost()
    private(set) var phase: VoiceBridge.Phase = .off
    private(set) var failure: VoiceBridge.Failure?
    private(set) var keepsMicrophoneReady = false
    private(set) var successfulDictations = 0
    var language: DictationLanguage = .auto

    var isOn: Bool { phase != .off }

    @ObservationIgnored private var isActivated = false
    @ObservationIgnored private let store = VoiceBridge.Store()
    @ObservationIgnored private var snapshot = VoiceBridge.Snapshot()
    @ObservationIgnored private var session: SpeechSession?
    @ObservationIgnored private var listener: Task<Void, Never>?
    @ObservationIgnored private var heartbeat: Task<Void, Never>?
    @ObservationIgnored private var pendingClose: Task<Void, Never>?
    @ObservationIgnored private var uploadBackgroundTask: UIBackgroundTaskIdentifier = .invalid
    @ObservationIgnored private var generation = 0
    @ObservationIgnored private var commandObserver: VoiceBridge.Observer?
    @ObservationIgnored private var interruptionObserver: KeyboardAudioInterruptionObserver?
    @ObservationIgnored private var endsAfterCurrentUtterance = false
    @ObservationIgnored private var handledCommandID: Int
    @ObservationIgnored private var lastTranscriptID: Int
    @ObservationIgnored private var lastActivity = Date.now
    @ObservationIgnored private var lastLevelWrite = ContinuousClock.now

    private static let recordingTimeout: TimeInterval = 5 * 60
    private static let levelInterval = Duration.milliseconds(120)

    init() {
        // Commands and transcripts left by an earlier run must not replay.
        handledCommandID = store?.command()?.id ?? 0
        lastTranscriptID = max(store?.snapshot().transcript?.id ?? 0, store?.acknowledgedTranscriptID ?? 0)

    }

    /// Only the installed app-lifetime host activates. Constructing an unused
    /// SwiftUI State default must not write off or stop another live session.
    func activate() {
        guard !isActivated else { return }
        isActivated = true
        commandObserver = VoiceBridge.Observer(name: VoiceBridge.commandNotification) { [weak self] in
            self?.handleCommand()
        }
        interruptionObserver = KeyboardAudioInterruptionObserver { [weak self] in
            self?.audioInterrupted()
        }
        if phase == .off, snapshot.sessionID == nil,
           EchoLiveActivityController.shared.cleanupStaleActivitiesAtLaunch() { publish() }
    }

    /// Handles `voicelab-echo://dictate` from the keyboard: open the mic and start listening.
    func open(_ url: URL) -> Bool {
        guard url.scheme == VoiceBridge.urlScheme else { return false }
        Task { await start(listening: true) }
        return true
    }

    /// Start is always user initiated. Ready mode keeps the same capture session between
    /// takes; recording-only mode releases it after each take. App launch never calls this.
    func start(listening: Bool, keepMicrophoneReady: Bool? = nil) async {
        activate()
        let requestedMode = keepMicrophoneReady
            ?? (session != nil ? keepsMicrophoneReady : store?.microphoneMode == .readySession)
        if session != nil, requestedMode != keepsMicrophoneReady {
            // A mode change must not discard an active take or upload. Recreate only an
            // idle session; the setup below waits for its microphone to close first.
            guard phase == .ready else { return }
            stop()
        }
        lastActivity = .now
        if session == nil {
            guard phase != .starting else { return }
            let requestGeneration = generation
            failure = nil
            snapshot.failure = nil
            endsAfterCurrentUtterance = false
            setPhase(.starting)
            do throws(DictationError) {
                // A keyboard URL can arrive before iOS finishes foregrounding Echo.
                // Audio activation is rejected during that transition.
                for _ in 0..<30 where UIApplication.shared.applicationState != .active {
                    try? await Task.sleep(for: .milliseconds(100))
                    guard generation == requestGeneration, !Task.isCancelled else { return }
                }
                guard UIApplication.shared.applicationState == .active else { throw DictationError.audioUnavailable }
                if AVAudioApplication.shared.recordPermission != .granted {
                    try await SpeechPermissions.request()
                }
                guard generation == requestGeneration else { return }
                keepsMicrophoneReady = requestedMode
                snapshot.sessionID = UUID().uuidString
                // Request the honest Starting panel before audio setup can suspend
                // and the user returns to the keyboard in another app.
                EchoLiveActivityController.shared.beginForegroundSession(
                    snapshot: snapshot, keepsReady: keepsMicrophoneReady)
                publish()
                await pendingClose?.value
                guard generation == requestGeneration else { return }
                let session = try SpeechSession(keepMicrophoneReady: keepsMicrophoneReady)
                let events = try await session.open()
                if keepsMicrophoneReady && !listening {
                    do {
                        try await session.prepareKeyboardSession()
                    } catch {
                        await session.close()
                        throw error
                    }
                }
                guard generation == requestGeneration else {
                    await session.close()
                    return
                }
                self.session = session
                listener = Task { [weak self] in
                    for await event in events {
                        guard let self, self.session === session else { return }
                        self.handle(event)
                    }
                }
                startHeartbeat()
                setPhase(.ready)
            } catch {
                guard generation == requestGeneration else { return }
                fail(Self.failure(for: error))
                if let ending = snapshot.sessionID { EchoLiveActivityController.shared.end(sessionID: ending) }
                snapshot.sessionID = nil
                keepsMicrophoneReady = false
                setPhase(.off)
                return
            }
        }
        if listening {
            await beginUtterance()
        }
    }

    /// Releases the mic; the keyboard falls back to opening the app on its next tap.
    func stop() {
        let endingSessionID = snapshot.sessionID
        endUploadBackgroundTask()
        generation += 1
        heartbeat?.cancel()
        heartbeat = nil
        listener?.cancel()
        listener = nil
        if let session {
            pendingClose = Task { await session.close() }
        }
        session = nil
        snapshot.sessionID = nil
        if let endingSessionID { EchoLiveActivityController.shared.end(sessionID: endingSessionID) }
        keepsMicrophoneReady = false
        endsAfterCurrentUtterance = false
        snapshot.level = 0
        setPhase(.off)
    }

    func stopAndWait() async {
        stop()
        await pendingClose?.value
    }

    func dismissFailure() {
        fail(nil)
        publish()
    }

    // MARK: Commands

    private func handleCommand() {
        guard let command = store?.command(), command.id > handledCommandID else { return }
        handledCommandID = command.id
        lastActivity = .now
        switch command.action {
        case .start: Task { await beginUtterance() }
        case .stop: finishUtterance()
        case .cancel: cancelUtterance()
        case .endSession: stop()
        }
    }

    private func beginUtterance() async {
        guard let session, phase == .ready else { return }
        let requestGeneration = generation
        fail(nil)
        // Reserve the transition before crossing the actor boundary. Repeated Start
        // notifications must not enqueue another take that cancels the first one.
        setPhase(.starting)
        do {
            try await session.beginUtterance(language: language)
            guard generation == requestGeneration, self.session === session else {
                await session.close()
                return
            }
            lastActivity = .now
            setPhase(.recording)
        } catch {
            guard generation == requestGeneration, self.session === session else { return }
            fail(Self.failure(for: error))
            // An interrupted or rejected audio activation isn't a usable background
            // session. Release it instead of publishing readiness that cannot record.
            stop()
        }
    }

    /// Stops recording; VoiceLab's transcript (or failure) arrives as a speech event.
    private func finishUtterance(releasingMicrophone: Bool = false) {
        guard phase == .recording, let session else { return }
        let requestGeneration = generation
        snapshot.level = 0
        setPhase(.transcribing)
        endUploadBackgroundTask()
        uploadBackgroundTask = UIApplication.shared.beginBackgroundTask(withName: "Echo keyboard transcription") { [weak self] in
            Task { @MainActor in
                guard let self else { return }
                self.stop()
                self.fail(.unavailable)
                self.publish()
            }
        }
        Task {
            guard generation == requestGeneration, self.session === session else { return }
            if releasingMicrophone {
                await session.releaseMicrophone()
                guard generation == requestGeneration, self.session === session else { return }
            }
            await session.finishUtterance()
        }
    }

    /// An interrupted AVAudioSession is no longer a usable keyboard-ready session.
    /// Preserve an existing take/upload, but never resume microphone capture from
    /// an interruption-ended notification while another app is in the foreground.
    private func audioInterrupted() {
        switch phase {
        case .off:
            return
        case .ready, .starting:
            fail(.unavailable)
            stop()
        case .recording:
            endsAfterCurrentUtterance = true
            keepsMicrophoneReady = false
            finishUtterance(releasingMicrophone: true)
        case .transcribing:
            endsAfterCurrentUtterance = true
            keepsMicrophoneReady = false
            snapshot.level = 0
            publish()
            guard let session else { return }
            let requestGeneration = generation
            Task {
                guard generation == requestGeneration, self.session === session else { return }
                await session.releaseMicrophone()
            }
        }
    }

    private func cancelUtterance() {
        endUploadBackgroundTask()
        guard let session, phase == .recording || phase == .transcribing else { return }
        snapshot.level = 0
        lastActivity = .now
        if keepsMicrophoneReady {
            // Do not expose Start until the old recorder/upload is actually gone.
            // A late cancellation must never discard the user's next utterance.
            let requestGeneration = generation
            setPhase(.starting)
            Task {
                await session.cancelUtterance()
                guard generation == requestGeneration, self.session === session else { return }
                lastActivity = .now
                setPhase(.ready)
            }
        } else {
            stop()
        }
    }

    // MARK: Speech events

    private func handle(_ event: SpeechEvent) {
        switch event {
        case .level(let level):
            guard phase == .recording else { return }
            let now = ContinuousClock.now
            guard now - lastLevelWrite >= Self.levelInterval else { return }
            lastLevelWrite = now
            snapshot.level = level
            publish()
        case .finished(let text):
            guard phase == .transcribing else { return }
            deliver(text)
        case .failed(let error):
            endUploadBackgroundTask()
            guard phase == .recording || phase == .transcribing else { return }
            fail(Self.failure(for: error))
            snapshot.level = 0
            lastActivity = .now
            if keepsMicrophoneReady && !endsAfterCurrentUtterance { setPhase(.ready) }
            else { stop() }
        }
    }

    private func deliver(_ text: String) {
        endUploadBackgroundTask()
        let heard = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if heard.isEmpty {
            fail(.noSpeech)
        } else {
            lastTranscriptID += 1
            snapshot.transcript = VoiceBridge.Transcript(id: lastTranscriptID, text: heard, createdAt: .now)
            successfulDictations += 1
        }
        snapshot.level = 0
        lastActivity = .now
        if keepsMicrophoneReady && !endsAfterCurrentUtterance { setPhase(.ready) }
        else { stop() }
    }

    private func endUploadBackgroundTask() {
        guard uploadBackgroundTask != .invalid else { return }
        UIApplication.shared.endBackgroundTask(uploadBackgroundTask)
        uploadBackgroundTask = .invalid
    }

    // MARK: Publishing

    private func startHeartbeat() {
        heartbeat?.cancel()
        heartbeat = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                let now = Date.now
                let appIsActive = UIApplication.shared.applicationState == .active
                let keyboardIsVisible = self.store?.keyboardIsVisible(at: now) == true
                if self.phase == .ready && (appIsActive || keyboardIsVisible) {
                    self.lastActivity = now
                }
                if self.phase == .ready && VoiceBridge.shouldEndKeyboardSession(
                    lastActivity: self.lastActivity, now: now,
                    appIsActive: appIsActive, keyboardIsVisible: keyboardIsVisible)
                    || self.phase == .recording && now.timeIntervalSince(self.lastActivity) > Self.recordingTimeout {
                    self.stop()
                    return
                }
                self.publish()
                try? await Task.sleep(for: VoiceBridge.heartbeatInterval)
            }
        }
    }

    private func setPhase(_ phase: VoiceBridge.Phase) {
        self.phase = phase
        snapshot.phase = phase
        publish()
    }

    private func fail(_ failure: VoiceBridge.Failure?) {
        self.failure = failure
        snapshot.failure = failure
    }

    private func publish() {
        guard isActivated, let store else { return }
        // Transcript text is kept only until the keyboard inserts it, or briefly if it never does.
        if let transcript = snapshot.transcript,
           store.acknowledgedTranscriptID >= transcript.id
            || Date.now.timeIntervalSince(transcript.createdAt) > VoiceBridge.transcriptLifetime {
            snapshot.transcript = nil
        }
        snapshot.heartbeat = .now
        store.write(snapshot)
        VoiceBridge.post(VoiceBridge.stateNotification)
        EchoLiveActivityController.shared.synchronize(
            snapshot: snapshot, keepsReady: keepsMicrophoneReady,
            canStartActivity: false)
    }

    private static func failure(for error: DictationError) -> VoiceBridge.Failure {
        switch error {
        case .microphoneDenied: .permissionDenied
        case .noMicrophone, .audioUnavailable, .notConfigured, .serviceUnavailable: .unavailable
        case .offline: .offline
        case .noCredits: .noCredits
        case .noSpeech: .noSpeech
        case .recognitionFailed: .recognitionFailed
        }
    }
}

/// Owns only the notification token; the callback never retains its session host.
/// Removing the observer on deinitialization avoids callbacks from retired hosts.
private final class KeyboardAudioInterruptionObserver {
    private let token: NSObjectProtocol

    @MainActor
    init(handler: @escaping @MainActor @Sendable () -> Void) {
        token = NotificationCenter.default.addObserver(
            forName: AVAudioSession.interruptionNotification,
            object: AVAudioSession.sharedInstance(), queue: .main
        ) { notification in
            guard let raw = notification.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt,
                  raw == AVAudioSession.InterruptionType.began.rawValue else { return }
            MainActor.assumeIsolated { handler() }
        }
    }

    deinit { NotificationCenter.default.removeObserver(token) }
}
