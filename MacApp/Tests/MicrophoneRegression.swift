import AVFoundation
import Foundation
import VoiceLabCore

@main
struct MicrophoneRegression {
    @MainActor
    static func main() async throws {
        let suite = "VoiceLab.MicrophoneRegression.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let preferences = Preferences(defaults: defaults)
        let first = FakeCapture()
        let replacement = FakeCapture(holdStart: true)
        let fallback = FakeCapture()
        let captures = CaptureFactory([first, replacement, fallback])
        let model = MicrophoneTestModel(preferences: preferences, makeCapture: { captures.next() })

        model.start()
        model.start()
        try await eventually { model.isRunning }
        let starts = await first.starts
        let recordingURL = await first.recordingURL
        precondition(starts == 1 && recordingURL == nil, "Live testing must never record to disk.")
        precondition(!model.speechDetected && model.devices.count == 1)

        let frame = soundFrame()
        await first.emit(frame)
        try await eventually { model.speechDetected }
        precondition(model.bands == frame.bands)

        model.select("external")
        precondition(!model.speechDetected && model.isStarting)
        try await eventually { await replacement.starts == 1 }
        let selected = await replacement.selectedID
        precondition(selected == "external" && preferences.microphoneID == "external")
        await first.emit(frame)  // A callback already enqueued when the previous device stopped.
        try await Task.sleep(for: .milliseconds(20))
        precondition(!model.speechDetected, "Old-device frames must not unlock the new device.")

        model.stop()  // Leave the page while permission/device setup is still suspended.
        await replacement.releaseStart()
        await replacement.emit(frame)
        try await eventually { await replacement.stops > 0 }
        try await Task.sleep(for: .milliseconds(20))
        precondition(!model.isRunning && !model.isStarting && !model.speechDetected)

        model.start()  // The configured device has disappeared; the driver resolves system default.
        try await eventually { model.isRunning }
        precondition(model.selectedDeviceID.isEmpty && preferences.microphoneID.isEmpty)
        await fallback.fail(.interrupted)
        try await eventually { model.error == .interrupted }
        precondition(!model.isRunning && !model.speechDetected && model.bands.allSatisfy { $0 == 0 })
        model.stop()

        try verifyWAV()
        print(
            "PASS: live capture lifecycle, device preference/fallback, stale callbacks, cancellation, interruption and 16 kHz mono PCM WAV."
        )
    }

    @MainActor
    private static func eventually(_ condition: () async -> Bool) async throws {
        for _ in 0..<200 {
            if await condition() { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        fatalError("Timed out waiting for microphone state.")
    }

    private static func soundFrame() -> MicrophoneMeterFrame {
        let meter = MicrophoneMeter()
        var result: MicrophoneMeterFrame?
        for offset in 0..<8 {
            let samples: [Float] = (0..<320).map { i in
                let t = Double(i + offset * 320) / 16000
                return Float((1...8).reduce(0.0) { $0 + 0.04 * sin(2 * .pi * Double(197 * $1) * t) })
            }
            result = meter.process(samples, sampleRate: 16000)
        }
        precondition(result!.speechDetected)
        return result!
    }

    private static func verifyWAV() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("test.wav")
        let samples = (0..<1600).map { Float(sin(Double($0) * 0.1) * 0.5) }
        do {
            let writer = try PCMRecordingWriter(url: url)
            try writer.write(samples)
            try writer.write(samples)
        }
        let file = try AVAudioFile(forReading: url)
        precondition(file.length == 3200)
        precondition(file.fileFormat.sampleRate == 16000 && file.fileFormat.channelCount == 1)
        precondition(file.fileFormat.streamDescription.pointee.mBitsPerChannel == 16)
        let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: 3200)!
        try file.read(into: buffer)
        for i in samples.indices {
            precondition(abs(buffer.floatChannelData![0][i] - samples[i]) < 0.0001)
        }
        let data = try Data(contentsOf: url)
        precondition(data.prefix(4) == Data("RIFF".utf8))
    }
}

private actor FakeCapture: MicrophoneCapturing {
    private(set) var starts = 0
    private(set) var stops = 0
    private(set) var selectedID = ""
    private(set) var recordingURL: URL?
    private let holdStart: Bool
    private var continuation: CheckedContinuation<Void, Never>?
    private var onFrame: (@Sendable (MicrophoneMeterFrame) -> Void)?
    private var onFailure: (@Sendable (MicrophoneCaptureError) -> Void)?

    init(holdStart: Bool = false) { self.holdStart = holdStart }
    func devices() -> [MicrophoneDevice] { [MicrophoneDevice(id: "external", name: "External microphone")] }
    func start(
        deviceID: String, recordingURL: URL?,
        onFrame: @escaping @Sendable (MicrophoneMeterFrame) -> Void,
        onFailure: @escaping @Sendable (MicrophoneCaptureError) -> Void
    ) async throws -> String {
        starts += 1
        selectedID = deviceID
        self.recordingURL = recordingURL
        self.onFrame = onFrame
        self.onFailure = onFailure
        if holdStart { await withCheckedContinuation { continuation = $0 } }
        return ""
    }
    func stop() { stops += 1 }
    func releaseStart() {
        continuation?.resume()
        continuation = nil
    }
    func emit(_ frame: MicrophoneMeterFrame) { onFrame?(frame) }
    func fail(_ error: MicrophoneCaptureError) { onFailure?(error) }
}

private final class CaptureFactory: @unchecked Sendable {
    private let lock = NSLock()
    private var captures: [FakeCapture]
    init(_ captures: [FakeCapture]) { self.captures = captures }
    func next() -> FakeCapture { lock.withLock { captures.removeFirst() } }
}
