import Foundation
import Observation
import VoiceLabCore

/// One explicit Fn press starts capture; the next submits exactly one recording.
@MainActor @Observable
final class TryItModel {
    enum Phase { case restoring, needsSignIn, signingIn, ready, starting, recording, transcribing }
    enum Failure { case permission, device, capture, signIn, connection, quota, rateLimit, empty, service }
    private(set) var phase = Phase.restoring
    private(set) var failure: Failure?
    private(set) var successfulTrials = 0
    private(set) var shortcut = SetupShortcutValidation()
    var text = ""
    let recorder: AudioRecorder
    @ObservationIgnored private let service: any TryItServing
    @ObservationIgnored private var operation: Task<Void, Never>?
    @ObservationIgnored private var generation = UUID()
    @ObservationIgnored private var signedIn = false
    @ObservationIgnored private var alphabet = UzbekAlphabet.current
    @ObservationIgnored var canStartWork: () -> Bool = { true }

    var canCancel: Bool {
        phase == .signingIn || phase == .starting || phase == .recording || phase == .transcribing
    }

    var requiresSignIn: Bool { phase == .restoring || phase == .needsSignIn || phase == .signingIn }

    // Editing or clearing the draft must not undo a real, successful voice trial.
    var canContinue: Bool { successfulTrials > 0 && phase == .ready && failure == nil }

    init(service: any TryItServing, recorder: AudioRecorder = AudioRecorder()) {
        self.service = service
        self.recorder = recorder
        recorder.onLimit = { [weak self] in self?.stop() }
        recorder.onFailure = { [weak self] error in
            guard let self, self.phase == .starting || self.phase == .recording else { return }
            self.cancel()
            self.failure = Self.failure(for: error)
        }
    }

    func restoreCompletedTrial(_ completed: Bool) {
        if completed { successfulTrials = max(1, successfulTrials) }
    }

    func restore() {
        guard phase == .restoring else { return }
        perform { model, id in
            do {
                let signedIn = try await model.service.restore()
                guard model.isCurrent(id) else { return }
                model.signedIn = signedIn
                model.phase = signedIn ? .ready : .needsSignIn
            } catch {
                guard model.isCurrent(id) else { return }
                model.phase = .needsSignIn
                model.failure = .signIn
            }
        }
    }

    func receive(keyCode: UInt16, functionDown: Bool, isFocused: Bool,
                 deviceID: String, usesNewAlphabet: Bool) {
        let pressed = shortcut.receive(keyCode: keyCode, functionDown: functionDown, isFocused: isFocused)
        if !isFocused {
            // Opening the sign-in browser is expected; it must not cancel authentication.
            if phase == .starting || phase == .recording { cancel() }
            return
        }
        guard pressed else { return }
        switch phase {
        case .ready: start(deviceID: deviceID, usesNewAlphabet: usesNewAlphabet)
        case .recording: stop()
        default: break
        }
    }

    func cancel() {
        generation = UUID()
        operation?.cancel()
        recorder.discard()
        shortcut.release()
        failure = nil
        phase = signedIn ? .ready : .needsSignIn
    }

    func signIn() {
        guard phase == .needsSignIn, canStartWork() else { return }
        failure = nil
        phase = .signingIn
        perform { model, id in
            do {
                try await model.service.signIn()
                guard model.isCurrent(id) else { return }
                model.signedIn = true
                // A fresh Fn press in the app is required before capturing any audio.
                model.phase = .ready
            } catch {
                guard model.isCurrent(id) else { return }
                model.phase = .needsSignIn
                model.failure = Self.failure(for: error)
            }
        }
    }

    func sessionExpired() {
        signedIn = false
        cancel()
        successfulTrials = 0
        text = ""
        failure = .signIn
    }

    private func start(deviceID: String, usesNewAlphabet: Bool) {
        guard canStartWork() else { return }
        failure = nil
        alphabet = usesNewAlphabet ? .modern : .current
        phase = .starting
        perform { model, id in
            do {
                try await model.recorder.start(deviceID: deviceID)
                guard model.isCurrent(id) else { return }
                model.phase = .recording
            } catch {
                guard model.isCurrent(id) else { return }
                model.recorder.discard()
                model.phase = .ready
                model.failure = Self.failure(for: error)
            }
        }
    }

    /// Fn and the real island's stop control submit the same recording once.
    func stop() {
        guard phase == .recording else { return }
        phase = .transcribing
        let alphabet = alphabet
        perform { model, id in
            do {
                let file = try await model.recorder.stop()
                defer { AudioRecorder.removeRecording(file) }
                guard model.isCurrent(id) else { return }
                let transcript = try await model.service.transcribe(file: file)
                guard model.isCurrent(id) else { return }
                let result = DictationText.render(
                transcript.text, detectedLanguage: transcript.language,
                    alphabet: alphabet, vocabulary: [])
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                guard !result.isEmpty else { throw VoiceLabError.emptyAudio }
                // Keep edits made while the upload was running. Each trial adds a paragraph.
                model.text += (model.text.isEmpty || model.text.hasSuffix("\n") ? "" : "\n\n") + result
                model.successfulTrials += 1
                model.phase = .ready
            } catch {
                guard model.isCurrent(id) else { return }
                model.recorder.discard()
                if let error = error as? VoiceLabError, error == .signedOut || error == .sessionChanged || error == .invalidAccessToken {
                    model.signedIn = false
                }
                model.phase = model.signedIn ? .ready : .needsSignIn
                model.failure = Self.failure(for: error)
            }
        }
    }

    /// Drain a cancelled operation before starting another auth/capture operation.
    private func perform(_ work: @escaping @MainActor (TryItModel, UUID) async -> Void) {
        let previous = operation
        let id = UUID()
        generation = id
        operation = Task { [weak self] in
            await previous?.value
            guard let self, self.isCurrent(id) else { return }
            await work(self, id)
        }
    }

    private func isCurrent(_ id: UUID) -> Bool { generation == id && !Task.isCancelled }

    private static func failure(for error: Error) -> Failure {
        if let error = error as? MicrophoneCaptureError {
            switch error {
            case .permission: return .permission
            case .notFound: return .device
            default: return .capture
            }
        }
        if error is URLError { return .connection }
        if let error = error as? VoiceLabError {
            switch error {
            case .signedOut, .sessionChanged, .invalidAccessToken, .invalidCallback: return .signIn
            case .rateLimited: return .rateLimit
            case .dictationLimitReached: return .quota
            case .emptyAudio: return .empty
            case .server(let status, _, _) where status == 402 || status == 403: return .quota
            default: break
            }
        }
        return .service
    }
}
