import Accelerate
import AVFoundation
import os

enum DictationError: Error, Equatable, Sendable {
    case microphoneDenied
    case noMicrophone
    case audioUnavailable
    /// No active Echo account is available for transcription.
    case notConfigured
    case offline
    case noCredits
    case noSpeech
    case serviceUnavailable
    case recognitionFailed
}

enum SpeechEvent: Sendable {
    /// Normalized input loudness, 0...1.
    case level(Float)
    case finished(String)
    case failed(DictationError)
}

private let logger = Logger(subsystem: "uz.voicelab.echo", category: "speech")

enum SpeechPermissions {
    static func request() async throws(DictationError) {
        guard await AVAudioApplication.requestRecordPermission() else { throw .microphoneDenied }
    }
}

/// Records one utterance at a time and transcribes it with VoiceLab. The audio session is
/// active only while recording by default. An explicitly requested keyboard-ready session
/// keeps capture active between takes and discards idle buffers without saving or uploading.
/// An actor keeps audio setup off the main actor; the tap runs on an audio thread.
actor SpeechSession {
    private let keepMicrophoneReady: Bool
    private let engine = AVAudioEngine()
    private let recorder = UtteranceRecorder()
    private let client: VoiceLabClient?
    private let usesDemo = DemoSpeech.isRequested
    private var continuation: AsyncStream<SpeechEvent>.Continuation?
    private var language = DictationLanguage.auto
    private var transcription: Task<Void, Never>?
    private var demoLevels: Task<Void, Never>?
    private var tapInstalled = false
    private var audioActive = false

    init(keepMicrophoneReady: Bool = false) throws(DictationError) {
        self.keepMicrophoneReady = keepMicrophoneReady
        client = VoiceLabClient()
        guard client != nil || DemoSpeech.isRequested else {
            logger.error("Echo transcription client is unavailable")
            throw .notConfigured
        }
    }

    /// Opens an event stream without activating the microphone.
    func open() throws(DictationError) -> AsyncStream<SpeechEvent> {
        close()
        let (stream, continuation) = AsyncStream.makeStream(of: SpeechEvent.self, bufferingPolicy: .bufferingNewest(64))
        self.continuation = continuation
        return stream
    }

    /// Starts recording, dropping any utterance or transcription in progress.
    func beginUtterance(language: DictationLanguage) throws(DictationError) {
        try beginCapture(language: language, recording: true)
    }

    /// Activates an explicitly requested keyboard session without creating an audio file.
    /// The app must call this while foregrounded; idle input buffers are discarded.
    func prepareKeyboardSession() throws(DictationError) {
        guard keepMicrophoneReady else { throw .audioUnavailable }
        try beginCapture(language: .auto, recording: false)
    }

    private func beginCapture(language: DictationLanguage, recording: Bool) throws(DictationError) {
        cancelUtterance()
        guard let continuation else { throw .audioUnavailable }
        self.language = language
        // Explicit keyboard-ready mode keeps the same capture engine alive between
        // utterances. Idle buffers are dropped because the recorder has no take.
        if keepMicrophoneReady, engine.isRunning, tapInstalled {
            if recording {
                do { try recorder.begin(inputFormat: engine.inputNode.outputFormat(forBus: 0)) }
                catch { throw .audioUnavailable }
            }
            return
        }
        // An interrupted engine can retain its tap even though it is no longer running.
        stopCapture()

        let audioSession = AVAudioSession.sharedInstance()
        do {
            // Mixes with other apps so playback can continue while the keyboard records.
            try audioSession.setCategory(.playAndRecord, mode: .default, options: [.mixWithOthers, .defaultToSpeaker])
            try audioSession.setActive(true)
            audioActive = true
        } catch {
            logger.error("Audio session activation failed: \(error.localizedDescription, privacy: .public)")
            deactivateAudioSession()
            throw .audioUnavailable
        }

        let input = engine.inputNode
        let format = input.outputFormat(forBus: 0)
        guard format.sampleRate > 0, format.channelCount > 0 else {
            deactivateAudioSession()
            throw .noMicrophone
        }

        if recording {
            do {
                try recorder.begin(inputFormat: format)
            } catch {
                logger.error("Couldn't create the recording: \(error.localizedDescription, privacy: .public)")
                deactivateAudioSession()
                throw .audioUnavailable
            }
        }
        input.installTap(onBus: 0, bufferSize: 1024, format: format, block: Self.makeTap(TapSink(recorder: recorder, continuation: continuation)))
        tapInstalled = true
        engine.prepare()
        do {
            try engine.start()
        } catch {
            logger.error("Audio engine start failed: \(error.localizedDescription, privacy: .public)")
            if let url = recorder.discard() { Self.remove(url) }
            stopCapture()
            throw .audioUnavailable
        }
        if usesDemo && recording {
            // Simulator mics are often silent; keep the waveform moving.
            demoLevels = Task {
                while !Task.isCancelled {
                    continuation.yield(.level(Float.random(in: 0.25...0.9)))
                    try? await Task.sleep(for: .milliseconds(60))
                }
            }
        }
    }

    /// Stops recording and transcribes it; the transcript arrives on the stream as `.finished`.
    func finishUtterance() {
        demoLevels?.cancel()
        demoLevels = nil
        let recording = recorder.finish()
        if !keepMicrophoneReady { stopCapture() }
        guard let continuation, let recording else { return }
        guard recording.duration >= VoiceLabClient.minimumDuration else {
            Self.remove(recording.url)
            continuation.yield(.failed(.noSpeech))
            return
        }
        logger.info("Recorded \(recording.duration, format: .fixed(precision: 1), privacy: .public) s")

        let language = language.code
        let client = usesDemo ? nil : client
        transcription = Task {
            defer { Self.remove(recording.url) }
            do throws(DictationError) {
                let text: String
                if let client {
                    text = try await client.transcribe(audio: recording.url, duration: recording.duration, language: language)
                } else {
                    try? await Task.sleep(for: DemoSpeech.delay)
                    text = DemoSpeech.text
                }
                guard !Task.isCancelled else { return }
                continuation.yield(.finished(text))
            } catch {
                guard !Task.isCancelled else { return }
                continuation.yield(.failed(error))
            }
        }
    }

    /// Drops the utterance: stops recording, or abandons its transcription.
    func cancelUtterance() {
        demoLevels?.cancel()
        demoLevels = nil
        transcription?.cancel()
        transcription = nil
        if let url = recorder.discard() {
            Self.remove(url)
        }
        if !keepMicrophoneReady { stopCapture() }
    }

    /// Releases capture after a system interruption without deleting the captured
    /// take or canceling a transcription that is already in flight.
    func releaseMicrophone() {
        demoLevels?.cancel()
        demoLevels = nil
        stopCapture()
    }

    /// Ends the utterance and releases the mic.
    func close() {
        cancelUtterance()
        stopCapture()
        continuation?.finish()
        continuation = nil
    }

    private func stopCapture() {
        if engine.isRunning { engine.stop() }
        if tapInstalled {
            engine.inputNode.removeTap(onBus: 0)
            tapInstalled = false
        }
        deactivateAudioSession()
    }

    private func deactivateAudioSession() {
        guard audioActive else { return }
        audioActive = false
        do {
            try AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        } catch {
            logger.error("Audio session deactivation failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    private static func remove(_ url: URL) {
        try? FileManager.default.removeItem(at: url)
    }

    // Built in a nonisolated factory so the closure never inherits actor isolation:
    // AVAudioEngine calls it on its own thread.
    private nonisolated static func makeTap(_ sink: TapSink) -> @Sendable (AVAudioPCMBuffer, AVAudioTime) -> Void {
        { buffer, _ in
            sink.recorder.append(buffer)
            sink.continuation.yield(.level(normalizedLevel(of: buffer)))
        }
    }

    private nonisolated static func normalizedLevel(of buffer: AVAudioPCMBuffer) -> Float {
        guard let samples = buffer.floatChannelData?[0], buffer.frameLength > 0 else { return 0 }
        var rms: Float = 0
        vDSP_rmsqv(samples, 1, &rms, vDSP_Length(buffer.frameLength))
        let decibels = 20 * log10(max(rms, 0.000_001))
        return min(max((decibels + 50) / 50, 0), 1)
    }
}

/// A finished utterance on disk.
private struct Recording: Sendable {
    let url: URL
    let duration: TimeInterval
}

/// Writes what the open mic hears to a 16 kHz mono AAC file while an utterance is live.
/// Started and finished on the session actor, written from the audio tap thread, so every
/// access takes the lock.
private final class UtteranceRecorder: @unchecked Sendable {
    private struct Take {
        let url: URL
        let file: AVAudioFile
        let converter: AVAudioConverter
        var frames: AVAudioFramePosition = 0
    }

    private let take = OSAllocatedUnfairLock<Take?>(uncheckedState: nil)

    /// Speech needs no more; it keeps uploads small on cellular.
    private static let sampleRate: Double = 16_000

    func begin(inputFormat: AVAudioFormat) throws {
        let url = URL.temporaryDirectory.appending(path: "dictation-\(UUID().uuidString).m4a")
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVSampleRateKey: Self.sampleRate,
            AVNumberOfChannelsKey: 1,
        ]
        let file = try AVAudioFile(forWriting: url, settings: settings, commonFormat: .pcmFormatFloat32, interleaved: false)
        guard let converter = AVAudioConverter(from: inputFormat, to: file.processingFormat) else {
            throw CocoaError(.featureUnsupported)
        }
        converter.downmix = true
        let replaced = take.withLockUnchecked { take in
            defer { take = Take(url: url, file: file, converter: converter) }
            return take?.url
        }
        if let replaced {
            try? FileManager.default.removeItem(at: replaced)
        }
    }

    func append(_ buffer: AVAudioPCMBuffer) {
        take.withLockUnchecked { take in
            guard let current = take else { return }
            let output = current.file.processingFormat
            // Headroom for frames the sample-rate converter held back from the previous buffer.
            let capacity = AVAudioFrameCount((Double(buffer.frameLength) * output.sampleRate / buffer.format.sampleRate).rounded(.up)) + 64
            guard let converted = AVAudioPCMBuffer(pcmFormat: output, frameCapacity: capacity) else { return }
            var supplied = false
            var error: NSError?
            let status = current.converter.convert(to: converted, error: &error) { _, inputStatus in
                if supplied {
                    inputStatus.pointee = .noDataNow
                    return nil
                }
                supplied = true
                inputStatus.pointee = .haveData
                return buffer
            }
            guard status != .error, converted.frameLength > 0 else { return }
            do {
                try current.file.write(from: converted)
                take?.frames += AVAudioFramePosition(converted.frameLength)
            } catch {
                logger.error("Recording write failed: \(error.localizedDescription, privacy: .public)")
            }
        }
    }

    /// Stops recording and returns the finished file. Releasing the `AVAudioFile` here is
    /// what finalizes the m4a.
    func finish() -> Recording? {
        take.withLockUnchecked { take in
            defer { take = nil }
            return take.map { Recording(url: $0.url, duration: Double($0.frames) / Self.sampleRate) }
        }
    }

    /// Stops recording and returns the file to delete, if any.
    func discard() -> URL? {
        take.withLockUnchecked { take in
            defer { take = nil }
            return take?.url
        }
    }
}

private struct TapSink: Sendable {
    let recorder: UtteranceRecorder
    let continuation: AsyncStream<SpeechEvent>.Continuation
}
