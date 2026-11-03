import Foundation
import Observation
import VoiceLabCore

/// File-backed dictation uses the same selected input as the onboarding live test.
@MainActor @Observable
final class AudioRecorder {
    private(set) var level: Double = 0
    private(set) var islandLevels = [Double](repeating: 0, count: 8)
    private(set) var elapsed: TimeInterval = 0
    @ObservationIgnored private var capture: (any MicrophoneCapturing)?
    @ObservationIgnored private var file: URL?
    @ObservationIgnored private var generation = UUID()
    @ObservationIgnored private var teardown: Task<Void, Never>?
    @ObservationIgnored private let makeCapture: () -> any MicrophoneCapturing
    var onLimit: (() -> Void)?
    var onFailure: ((MicrophoneCaptureError) -> Void)?
    static let maximumDuration: TimeInterval = 600

    init(makeCapture: @escaping () -> any MicrophoneCapturing = { MicrophoneCapture() }) {
        self.makeCapture = makeCapture
    }

    func start(deviceID: String = "") async throws {
        discard()
        let id = generation
        await teardown?.value
        try Task.checkCancellation()
        guard generation == id else { throw CancellationError() }
        teardown = nil
        let capture = makeCapture()
        self.capture = capture
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
            "VoiceLab-\(UUID().uuidString)", isDirectory: true)
        let url = directory.appendingPathComponent("recording.wav")
        file = url
        elapsed = 0
        do {
            try FileManager.default.createDirectory(
                at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            _ = try await capture.start(
                deviceID: deviceID, recordingURL: url,
                onFrame: { [weak self] frame in
                    Task { @MainActor in
                        guard let self, self.generation == id else { return }
                        self.level = frame.level
                        self.islandLevels = frame.dictationLevels
                        self.elapsed = frame.elapsed
                        if frame.elapsed >= Self.maximumDuration { self.onLimit?() }
                    }
                },
                onFailure: { [weak self] error in
                    Task { @MainActor in
                        guard let self, self.generation == id else { return }
                        self.onFailure?(error)
                    }
                })
            try Task.checkCancellation()
            guard generation == id else { throw CancellationError() }
        } catch {
            await capture.stop()
            Self.removeRecording(url)
            if generation == id {
                self.capture = nil
                file = nil
            }
            throw error
        }
    }
    func stop() async throws -> URL {
        guard let capture, let file else { throw VoiceLabError.emptyAudio }
        let id = generation
        await capture.stop()  // Flush and close the WAV before handing it to the uploader.
        guard id == generation else { throw CancellationError() }
        self.capture = nil
        self.file = nil
        generation = UUID()
        level = 0
        islandLevels = [Double](repeating: 0, count: 8)
        return file
    }
    func discard() {
        generation = UUID()
        let previous = capture
        let previousFile = file
        capture = nil
        file = nil
        level = 0
        islandLevels = [Double](repeating: 0, count: 8)
        if previous != nil || previousFile != nil {
            let previousTeardown = teardown
            teardown = Task {
                await previousTeardown?.value
                await previous?.stop()
                if let previousFile { Self.removeRecording(previousFile) }
            }
        }
    }
    static func removeRecording(_ url: URL) {
        guard url.deletingLastPathComponent().lastPathComponent.hasPrefix("VoiceLab-") else { return }
        try? FileManager.default.removeItem(at: url.deletingLastPathComponent())
    }
}
