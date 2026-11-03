import Foundation
import VoiceLabCore

@main
struct TryItRegression {
    @MainActor static func main() async throws {
        let suite = "Echo.TrialIsland.\(UUID())"
        let defaults = UserDefaults(suiteName: suite)!
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer {
            defaults.removePersistentDomain(forName: suite)
            try? FileManager.default.removeItem(at: directory)
        }
        let workspace = DictationModel(api: UnusedWorkspaceAPI(),
            library: LibraryModel(store: LibraryStore(directory: directory)),
            preferences: Preferences(defaults: defaults),
            captureTarget: { fatalError("The trial must not capture a system-wide insertion target.") },
            insertText: { _, _, _ in fatalError("The trial must only update its editor.") })
        let island = IslandRecordingSession(dictation: workspace)
        precondition(!island.isTrial && island.recorder === workspace.recorder && !island.isBusy)
        let service = TrialService()
        let capture = TrialCapture()
        let model = TryItModel(service: service, recorder: AudioRecorder(makeCapture: { capture }))
        island.trial = model
        precondition(island.recorder === model.recorder && !island.isBusy,
                     "Attaching the island must not start another recorder.")
        model.restore()
        try await eventually { model.phase == .needsSignIn }
        model.receive(keyCode: 36, functionDown: true, isFocused: true, deviceID: "external", usesNewAlphabet: false)
        precondition(service.signIns == 0, "Return must not start authentication or recording.")
        press(model)
        precondition(service.signIns == 0 && model.requiresSignIn, "Fn must not replace the Sign In action.")
        model.signIn()
        model.signIn()
        try await eventually { service.signIns == 1 }
        model.receive(keyCode: 63, functionDown: true, isFocused: true, deviceID: "external", usesNewAlphabet: false)
        precondition(service.signIns == 1, "Repeated clicks and Fn must not start another sign-in.")
        model.receive(keyCode: 63, functionDown: false, isFocused: false, deviceID: "external", usesNewAlphabet: false)
        precondition(model.phase == .signingIn, "Opening the browser must not cancel sign-in.")
        service.finishSignIn()
        try await eventually { model.phase == .ready }
        precondition(!model.requiresSignIn, "Show the voice trial only after sign-in succeeds.")
        model.text = "Typed text is not a voice trial."
        precondition(!model.canContinue, "Signing in or typing must not unlock Next.")
        model.text = ""
        let startsBefore = await capture.starts
        precondition(startsBefore == 0, "Sign-in must not start the microphone automatically.")

        press(model)
        try await eventually { model.phase == .recording }
        precondition(island.phase == .recording && island.isBusy && workspace.phase == .idle)
        let selected = await capture.selectedID
        precondition(selected == "external", "Use the microphone selected in Setup.")
        await capture.emitSound()
        try await eventually { model.recorder.level > 0 }
        precondition(model.recorder.islandLevels.contains { $0 > 0 }, "Use actual capture frames for the waveform.")
        island.stop()
        island.stop()
        press(model)
        try await eventually { service.uploads == 1 }
        precondition(island.phase == .transcribing, "The island must track submission, not the idle workspace.")
        precondition(!model.canContinue, "Wait for successful transcription before showing Next.")
        let firstFile = service.lastFile!
        precondition(FileManager.default.fileExists(atPath: firstFile.path))
        press(model)
        precondition(service.uploads == 1, "Fn during transcription must not submit again.")
        model.text = "An edit while waiting."
        service.finishTranscript(Transcript(text: "Hello Aisha.", language: "en", durationMS: 900))
        try await eventually { model.successfulTrials == 1 }
        precondition(model.text == "An edit while waiting.\n\nHello Aisha.")
        precondition(model.canContinue, "A successful voice trial unlocks Next.")
        precondition(!island.isBusy && island.phase == .idle, "Success must retract the recording island.")
        let completedDraft = model.text
        model.text = ""
        precondition(model.canContinue, "Clearing the editor must not undo a completed trial.")
        model.text = completedDraft
        precondition(!FileManager.default.fileExists(atPath: firstFile.path), "Remove completed recordings.")

        press(model, modern: true)
        precondition(!model.canContinue, "A new capture must hide Next until it settles.")
        try await eventually { model.phase == .recording }
        press(model, modern: false) // Snapshot the alphabet when recording starts.
        try await eventually { service.uploads == 2 }
        service.finishTranscript(Transcript(
            text: "Oʻzbekiston, gʻoya, shahar. I am switching. Hozir o‘zgartiryapti, chopayapti.",
            language: "en", durationMS: 900)) // The provider may report the dominant English portion.
        try await eventually { model.successfulTrials == 2 }
        precondition(model.text.hasSuffix("Özbekiston, ğoya, şahar. I am switching. Hozir özgartiryapti, çopayapti."))
        press(model, modern: true)
        try await eventually { model.phase == .recording }
        press(model)
        try await eventually { service.uploads == 3 }
        service.finishTranscript(Transcript(text: "Share this choice.", language: "en", durationMS: 900))
        try await eventually { model.successfulTrials == 3 }
        precondition(model.text.hasSuffix("Share this choice."), "Do not convert other languages to Uzbek spelling.")

        let previousText = model.text
        press(model)
        try await eventually { model.phase == .recording }
        press(model)
        try await eventually { service.uploads == 4 }
        let failedFile = service.lastFile!
        service.failTranscript(VoiceLabError.server(status: 402, message: "quota", requestID: nil))
        try await eventually { model.failure == .quota }
        precondition(!model.canContinue, "An error must not be presented as a successful trial.")
        precondition(model.text == previousText && model.successfulTrials == 3)
        precondition(!FileManager.default.fileExists(atPath: failedFile.path))
        precondition(service.uploads == 4, "Never automatically retry a potentially billed request.")

        press(model)
        try await eventually { model.phase == .recording }
        let cancelledFile = await capture.recordingURL!
        model.receive(keyCode: 63, functionDown: false, isFocused: false, deviceID: "external", usesNewAlphabet: false)
        try await eventually { !FileManager.default.fileExists(atPath: cancelledFile.path) }
        precondition(model.phase == .ready && service.uploads == 4, "Focus loss discards capture without uploading.")

        // Ignore a service that completes after cancellation. Serialize the next capture after cleanup.
        press(model)
        try await eventually { model.phase == .recording }
        press(model)
        try await eventually { service.uploads == 5 }
        let staleFile = service.lastFile!
        island.cancel()
        precondition(!island.isBusy && workspace.phase == .idle)
        press(model)
        service.finishTranscript(Transcript(text: "Stale result", language: "en", durationMS: 900))
        try await eventually { model.phase == .recording }
        precondition(model.text == previousText && model.successfulTrials == 3)
        precondition(!FileManager.default.fileExists(atPath: staleFile.path))
        model.cancel()

        await capture.holdStartup()
        press(model)
        try await eventually { await capture.waitingToStart }
        let pendingFile = await capture.recordingURL!
        island.cancel()
        precondition(!island.isBusy, "Cancel during startup must retract immediately.")
        await capture.releaseStartup()
        try await eventually { !FileManager.default.fileExists(atPath: pendingFile.path) }
        precondition(model.phase == .ready && service.uploads == 5)

        await capture.denyNextStart()
        press(model)
        try await eventually { model.failure == .permission }
        precondition(model.phase == .ready && service.uploads == 5)
        model.cancel()

        let failedLoginService = TrialService()
        let failedLogin = TryItModel(service: failedLoginService, recorder: AudioRecorder(makeCapture: { capture }))
        failedLogin.restore()
        try await eventually { failedLogin.phase == .needsSignIn }
        failedLogin.signIn()
        try await eventually { failedLoginService.signIns == 1 }
        failedLoginService.failSignIn()
        try await eventually { failedLogin.failure == .signIn }
        precondition(failedLogin.requiresSignIn && failedLogin.phase == .needsSignIn)
        failedLogin.signIn()
        try await eventually { failedLoginService.signIns == 2 }
        failedLoginService.failSignIn(VoiceLabError.rateLimited(retryAt: .now.addingTimeInterval(60), requestID: nil))
        try await eventually { failedLogin.failure == .rateLimit }
        precondition(failedLogin.phase == .needsSignIn && failedLogin.requiresSignIn,
                     "HTTP 429 must end the spinner and present a recoverable cooldown.")
        failedLogin.signIn()
        try await eventually { failedLoginService.signIns == 3 }
        failedLogin.cancel()
        failedLoginService.finishSignIn()
        try await Task.sleep(for: .milliseconds(20))
        precondition(failedLogin.requiresSignIn, "A cancelled login must not reveal the voice trial.")

        let returningService = TrialService()
        returningService.restoredSession = true
        let returning = TryItModel(service: returningService, recorder: AudioRecorder(makeCapture: { capture }))
        returning.restore()
        try await eventually { returning.phase == .ready }
        precondition(!returning.requiresSignIn && returningService.signIns == 0,
                     "An existing session opens the trial without another browser sign-in.")
        returning.sessionExpired()
        precondition(returning.requiresSignIn && !returning.canContinue && returning.text.isEmpty,
                     "Expired questionnaire authentication returns to Sign In without old trial state.")
        returning.cancel()
        island.trial = nil
        precondition(!island.isTrial && island.recorder === workspace.recorder && !island.isBusy,
                     "Leaving practice must restore the workspace recording owner.")
        var temporaryTrial: TryItModel? = TryItModel(service: TrialService())
        island.trial = temporaryTrial
        temporaryTrial = nil
        precondition(!island.isTrial, "The panel must not retain a departed onboarding session.")
        print("PASS: shared island routes audio, stop and cancel to the trial; duplicate stop/Fn sends once; completion retracts; departure restores workspace without retaining the trial.")
        print("PASS: explicit Sign In, auth gating, duplicate clicks, failed/cancelled/restored login, Fn-only capture, selected device, measured waves, single upload, editable results, alphabet, cleanup, stale replies, and microphone denial.")
    }

    @MainActor static func press(_ model: TryItModel, modern: Bool = false) {
        model.receive(keyCode: 63, functionDown: false, isFocused: true, deviceID: "external", usesNewAlphabet: modern)
        model.receive(keyCode: 63, functionDown: true, isFocused: true, deviceID: "external", usesNewAlphabet: modern)
    }

    @MainActor static func eventually(_ predicate: () async -> Bool) async throws {
        for _ in 0..<250 {
            if await predicate() { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        fatalError("Timed out waiting for the Try it flow.")
    }
}

@MainActor private final class TrialService: TryItServing {
    var signIns = 0
    var uploads = 0
    var lastFile: URL?
    var restoredSession = false
    private var login: CheckedContinuation<Void, Error>?
    private var transcript: CheckedContinuation<Transcript, Error>?
    func restore() async throws -> Bool { restoredSession }
    func signIn() async throws {
        signIns += 1
        try await withCheckedThrowingContinuation { login = $0 }
    }
    func transcribe(file: URL) async throws -> Transcript {
        precondition(FileManager.default.fileExists(atPath: file.path))
        lastFile = file
        uploads += 1
        return try await withCheckedThrowingContinuation { transcript = $0 }
    }
    func finishSignIn() { login?.resume(); login = nil }
    func failSignIn(_ error: Error = VoiceLabError.invalidCallback) { login?.resume(throwing: error); login = nil }
    func finishTranscript(_ result: Transcript) { transcript?.resume(returning: result); transcript = nil }
    func failTranscript(_ error: Error) { transcript?.resume(throwing: error); transcript = nil }
}

private actor TrialCapture: MicrophoneCapturing {
    var starts = 0
    var selectedID = ""
    var recordingURL: URL?
    var waitingToStart: Bool { pending != nil }
    private var frame: (@Sendable (MicrophoneMeterFrame) -> Void)?
    private var hold = false
    private var deny = false
    private var pending: CheckedContinuation<Void, Never>?
    func devices() async -> [MicrophoneDevice] { [] }
    func start(deviceID: String, recordingURL: URL?,
               onFrame: @escaping @Sendable (MicrophoneMeterFrame) -> Void,
               onFailure: @escaping @Sendable (MicrophoneCaptureError) -> Void) async throws -> String {
        starts += 1
        if deny { deny = false; throw MicrophoneCaptureError.permission }
        selectedID = deviceID
        self.recordingURL = recordingURL
        frame = onFrame
        try Data("test recording".utf8).write(to: recordingURL!)
        if hold {
            hold = false
            await withCheckedContinuation { pending = $0 }
        }
        return deviceID
    }
    func stop() async {}
    func emitSound() {
        let meter = MicrophoneMeter()
        for offset in 0..<8 {
            let samples: [Float] = (0..<320).map { index in
                Float(sin(Double(index + offset * 320) / 16000 * 2 * .pi * 440)) * 0.2
            }
            if let value = meter.process(samples, sampleRate: 16000) { frame?(value) }
        }
    }
    func holdStartup() { hold = true }
    func releaseStartup() { pending?.resume(); pending = nil }
    func denyNextStart() { deny = true }
}

private struct UnusedWorkspaceAPI: DesktopServing {
    func usage() async throws -> Usage { throw VoiceLabError.invalidResponse }
    func history(page: Int) async throws -> HistoryPage { throw VoiceLabError.invalidResponse }
    func transcribe(file: URL, language: DictationLanguage) async throws -> Transcript {
        fatalError("The island must submit through the onboarding service.")
    }
    func update(_ transcript: Transcript, text: String) async throws -> Transcript {
        throw VoiceLabError.invalidResponse
    }
}
