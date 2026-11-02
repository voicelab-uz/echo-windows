import Foundation
import Observation

enum DictationLanguage: String, CaseIterable, Identifiable, Sendable {
    case auto, uzbek, english, russian, arabic, turkish

    var id: Self { self }

    /// VoiceLab STT language code.
    var code: String {
        switch self {
        case .auto: "auto"
        case .uzbek: "uz"
        case .english: "en"
        case .russian: "ru"
        case .arabic: "ar"
        case .turkish: "tr"
        }
    }
}

/// Where dictated text is written. The text view implements it so the transcript lands at
/// the cursor position the user dictated from.
@MainActor
protocol DictationTextTarget: AnyObject {
    func dismissKeyboard()
    func beginDictation()
    /// Writes `text` where dictation began, or writes nothing when nil.
    func endDictation(keeping text: String?)
}

@MainActor
@Observable
final class ComposerModel {
    enum Phase: Equatable {
        case idle
        case preparing
        case recording(since: Date)
        case transcribing
    }

    var draft = ""
    var language: DictationLanguage = .auto
    private(set) var phase: Phase = .idle
    /// Recent loudness samples for the waveform, oldest first.
    private(set) var levels: [Float] = []
    private(set) var error: DictationError?
    /// Bumped to ask the text view to become first responder (keyboard up).
    private(set) var focusRequest = 0
    private(set) var isKeyboardFocused = false
    /// Only actual recognized speech counts toward finishing first-run setup.
    private(set) var successfulDictations = 0
    @ObservationIgnored weak var textTarget: DictationTextTarget?

    var beforeRecording: (@MainActor () async -> Void)?
    private var pendingClose: Task<Void, Never>?
    private var session: SpeechSession?
    private var listener: Task<Void, Never>?
    private var lastBarAt = ContinuousClock.now
    private var isWritingToTarget = false

    private static let maxLevels = 160
    private static let barInterval = Duration.milliseconds(60)

    var isDictating: Bool { phase != .idle }

    var canSend: Bool { !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }

    func dismissKeyboard() {
        textTarget?.dismissKeyboard()
    }

    func keyboardFocusChanged(_ focused: Bool) {
        isKeyboardFocused = focused
    }

    func startDictation() {
        guard phase == .idle else { return }
        error = nil
        levels = []
        phase = .preparing
        focusRequest += 1
        listener = Task { await listen() }
    }

    func finishDictation() {
        guard case .recording = phase, let session else { return }
        phase = .transcribing
        Task { await session.finishUtterance() }
    }

    func cancelDictation() {
        guard phase != .idle else { return }
        end(keeping: nil)
    }

    func dismissError() {
        error = nil
    }

    /// Returns the trimmed draft and clears it, or nil when there is nothing to send.
    func takeDraft() -> String? {
        let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return nil }
        draft = ""
        return text
    }

    func cancelAndWait() async {
        cancelDictation()
        await pendingClose?.value
    }

    private func listen() async {
        do {
            await pendingClose?.value
            await beforeRecording?()
            guard !Task.isCancelled, phase == .preparing else { return }
            try await SpeechPermissions.request()
            let session = try SpeechSession()
            let events = try await session.open()
            guard !Task.isCancelled, phase == .preparing else {
                await session.close()
                return
            }
            self.session = session
            try await session.beginUtterance(language: language)
            guard !Task.isCancelled, self.session === session else {
                await session.close()
                return
            }
            phase = .recording(since: .now)
            if let textTarget {
                textTarget.beginDictation()
                isWritingToTarget = true
            }
            for await event in events {
                handle(event)
            }
        } catch {
            guard !Task.isCancelled else { return }
            self.error = error
            end(keeping: nil)
        }
    }

    private func handle(_ event: SpeechEvent) {
        switch event {
        case .level(let level):
            pushLevel(level)
        case .finished(let text):
            end(keeping: text)
        case .failed(let error):
            self.error = error
            end(keeping: nil)
        }
    }

    private func pushLevel(_ level: Float) {
        let now = ContinuousClock.now
        if let last = levels.indices.last, now - lastBarAt < Self.barInterval {
            levels[last] = max(levels[last], level)
            return
        }
        levels.append(level)
        lastBarAt = now
        if levels.count > Self.maxLevels {
            levels.removeFirst(levels.count - Self.maxLevels)
        }
    }

    /// Stops the session and settles the text: `nil` discards what was dictated.
    private func end(keeping text: String?) {
        let heard = text?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if !heard.isEmpty { successfulDictations += 1 }
        if isWritingToTarget, let textTarget {
            textTarget.endDictation(keeping: heard.isEmpty ? nil : heard)
        } else if !heard.isEmpty {
            draft = draft.isEmpty ? heard : draft + " " + heard
        }
        isWritingToTarget = false

        if let session {
            pendingClose = Task { await session.close() }
        }
        session = nil
        listener?.cancel()
        listener = nil
        phase = .idle
        levels = []
    }
}
