import AppKit
import Observation
import VoiceLabCore

@MainActor @Observable
final class DictationModel {
    enum Phase: Equatable { case idle, preparing, recording, transcribing, failed }
    private(set) var phase: Phase = .idle
    private(set) var result: String?
    private(set) var message: String?
    private(set) var error: String?
    private(set) var needsPlanUpgrade = false
    /// The recording reached the server but contained no speech; shown as a gentle hint, not an error.
    private(set) var heardNothing = false
    /// The finished text went to the clipboard because no text field took it.
    private(set) var copiedToClipboard = false
    private(set) var warning: String?
    private(set) var resultDurationMS: Int?
    let recorder: AudioRecorder
    @ObservationIgnored private let captureTarget: () -> TextInsertion.Target?
    @ObservationIgnored private let insertText: (String, TextInsertion.Target?, Bool) async -> String
    @ObservationIgnored private let api: any DesktopServing
    @ObservationIgnored private let library: LibraryModel
    @ObservationIgnored private let preferences: Preferences
    @ObservationIgnored private var operation: Task<Void, Never>?
    @ObservationIgnored private var recordingFile: URL?
    @ObservationIgnored private var insertionTarget: TextInsertion.Target?
    @ObservationIgnored private var ownerID: String?
    @ObservationIgnored private var operationID = UUID()
    @ObservationIgnored private var uzbekAlphabet: UzbekAlphabet = .current
    @ObservationIgnored private var isPractice = false
    /// Set when a held shortcut is released before the microphone finished starting.
    @ObservationIgnored private var stopsWhenReady = false
    var isPracticeSession: Bool { isPractice }
    /// STT may settle usage even if its response is lost. Reconcile with the server;
    /// never subtract elapsed time locally or resend audio to refresh the balance.
    @ObservationIgnored var onUsageMayHaveChanged: ((String) -> Void)?
    /// The update handoff closes this gate before its first asynchronous flush.
    @ObservationIgnored var canStartWork: () -> Bool = { true }
    var isBusy: Bool { [.preparing, .recording, .transcribing].contains(phase) }
    var canRetry: Bool { phase == .failed && recordingFile != nil }

    init(
        api: any DesktopServing, library: LibraryModel, preferences: Preferences,
        recorder: AudioRecorder = AudioRecorder(),
        captureTarget: @escaping () -> TextInsertion.Target? = { TextInsertion.captureTarget() },
        insertText: ((String, TextInsertion.Target?, Bool) async -> String)? = nil
    ) {
        self.api = api
        self.library = library
        self.preferences = preferences
        self.recorder = recorder
        self.captureTarget = captureTarget
        self.insertText =
            insertText ?? { text, target, autoPaste in
                await TextInsertion.insert(
                    text, into: target, autoPaste: autoPaste, method: preferences.textInsertionMethod)
            }
        recorder.onLimit = { [weak self] in self?.stop() }
        recorder.onFailure = { [weak self] error in self?.captureFailed(error) }
    }
    private func captureFailed(_ error: MicrophoneCaptureError) {
        if phase == .recording {
            warning = AppLocalization.text(
                "%@ Yozilgan qism matnga aylantirilmoqda.", AppLocalization.error(error))
            stop()
        } else if phase == .preparing {
            discard()
            self.error = AppLocalization.error(error)
            phase = .failed
        }
    }
    func toggle() {
        if phase == .recording { stop() } else if !isBusy { start() }
    }
    func togglePractice() {
        if phase == .recording { stop() } else if !isBusy { start(practice: true) }
    }
    private func start(practice: Bool = false) {
        guard canStartWork() else { return }
        guard library.isReady, let owner = library.accountID else {
            error = "Yozishni boshlash uchun akkauntga kiring."
            return
        }
        discard()
        isPractice = practice
        ownerID = owner
        uzbekAlphabet = preferences.uzbekAlphabet
        insertionTarget = captureTarget()
        phase = .preparing
        error = nil
        result = nil
        message = nil
        let id = operationID
        operation = Task {
            do {
                try await recorder.start(deviceID: preferences.microphoneID)
                guard id == operationID, owner == library.accountID else {
                    recorder.discard()
                    return
                }
                phase = .recording
                // A single light pulse confirms capture is ready, including Fn and onboarding practice.
                NSHapticFeedbackManager.defaultPerformer.perform(.alignment, performanceTime: .now)
                if stopsWhenReady { stop() }
            } catch {
                guard id == operationID else { return }
                self.error = AppLocalization.error(error)
                phase = .failed
            }
        }
    }
    /// Ends a recording now, or as soon as it starts if the microphone is still preparing.
    func stopWhenReady() {
        if phase == .preparing { stopsWhenReady = true } else { stop() }
    }
    func stop() {
        guard phase == .recording else { return }
        stopsWhenReady = false
        phase = .transcribing
        let id = operationID
        operation = Task {
            do {
                let file = try await recorder.stop()
                guard id == operationID, !Task.isCancelled else {
                    AudioRecorder.removeRecording(file)
                    return
                }
                recordingFile = file
                submit()
            } catch {
                guard id == operationID else { return }
                self.error = AppLocalization.error(error)
                phase = .failed
            }
        }
    }

    func retry() {
        guard canRetry, canStartWork() else { return }
        submit()
    }
    private func submit() {
        guard let recordingFile, let ownerID else { return }
        phase = .transcribing
        error = nil
        needsPlanUpgrade = false
        heardNothing = false
        copiedToClipboard = false
        let id = operationID
        operation = Task {
            defer { onUsageMayHaveChanged?(ownerID) }
            do {
                var transcript = try await api.transcribe(file: recordingFile, language: .auto)
                try Task.checkCancellation()
                guard id == operationID, ownerID == library.accountID else { return }
                let output = DictationText.render(
                    // Convert only recognized Uzbek portions of mixed speech.
                    transcript.text, detectedLanguage: transcript.language,
                    alphabet: uzbekAlphabet, vocabulary: library.snapshot.vocabulary)
                // Keep canonical remote content/revision intact; replacements affect insertion only.
                if !transcript.isRemote { transcript.text = output }
                if preferences.retainHistory && !isPractice { library.merge([transcript]) }
                result = output
                resultDurationMS = transcript.durationMS
                if isPractice {
                    message = "Sinov matni tayyor"
                } else {
                    // Follow the user: if they moved to another app or field while speaking,
                    // insert where the cursor is now rather than where recording started.
                    if let current = captureTarget() { insertionTarget = current }
                    // Dictionary words keep their capital when the dictation is fitted mid-sentence.
                    TextInsertionManager.protectedWords = Set(library.snapshot.vocabulary.flatMap {
                        $0.isPhrase ? [] : [$0.word, $0.replacement].filter { !$0.isEmpty }
                    })
                    message = await insertText(output, insertionTarget, preferences.autoPaste)
                }
                guard id == operationID, ownerID == library.accountID else { return }
                if !isPractice, preferences.autoPaste,
                   message == TextInsertionManager.Outcome.confirmed.message
                    || message == TextInsertionManager.Outcome.sent.message,
                   let context = insertionTarget?.usageContext {
                    library.recordUsage(context, transcript: transcript, owner: ownerID)
                }
                if !isPractice, message == "Matn nusxalandi" { copiedToClipboard = true }
                if message == TextInsertionManager.Outcome.interrupted.message
                    || message == TextInsertionManager.Outcome.busy.message
                {
                    warning = message
                }
                phase = .idle
                AudioRecorder.removeRecording(recordingFile)
                self.recordingFile = nil
            } catch is CancellationError {} catch {
                guard id == operationID else { return }
                if let failure = error as? VoiceLabError, case .dictationLimitReached = failure {
                    needsPlanUpgrade = true
                }
                if let failure = error as? VoiceLabError, case .server(_, let message, _) = failure,
                    message == "No speech was detected in the recording."
                {
                    heardNothing = true
                    self.error = AppLocalization.text("Biroz balandroq gapirib, qayta urinib ko‘ring.")
                } else {
                    self.error = AppLocalization.error(error)
                }
                phase = .failed
            }
        }
    }
    func discard() {
        operationID = UUID()
        operation?.cancel()
        operation = nil
        recorder.discard()
        if let recordingFile { AudioRecorder.removeRecording(recordingFile) }
        recordingFile = nil
        ownerID = nil
        insertionTarget = nil
        isPractice = false
        stopsWhenReady = false
        heardNothing = false
        copiedToClipboard = false
        phase = .idle
        error = nil
        warning = nil
        needsPlanUpgrade = false
    }
    func clearResult() {
        result = nil
        resultDurationMS = nil
        message = nil
    }
}
