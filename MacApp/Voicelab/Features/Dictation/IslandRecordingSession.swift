import Observation

/// Routes the existing island to one recording owner. The onboarding trial owns
/// its audio and transcript; presenting it must never start a second recorder.
@MainActor @Observable
final class IslandRecordingSession {
    private let dictation: DictationModel
    weak var trial: TryItModel?

    init(dictation: DictationModel) { self.dictation = dictation }

    var isTrial: Bool { trial != nil }
    var recorder: AudioRecorder { trial?.recorder ?? dictation.recorder }
    var phase: DictationModel.Phase {
        guard let trial else { return dictation.phase }
        switch trial.phase {
        case .starting: return .preparing
        case .recording: return .recording
        case .transcribing: return .transcribing
        default: return .idle
        }
    }
    var isBusy: Bool { [.preparing, .recording, .transcribing].contains(phase) }

    func stop() {
        if let trial { trial.stop() } else { dictation.stop() }
    }
    func cancel() {
        if let trial { trial.cancel() } else { dictation.discard() }
    }
}
