import Foundation
import VoiceLabCore

@main
struct SetupMicrophoneRegression {
    @MainActor static func main() async throws {
        let discovery = MeterCapture()
        let first = MeterCapture()
        let switching = MeterCapture(holdStart: true)
        let denied = MeterCapture(failure: .permission)
        let retry = MeterCapture()
        let pending = MeterCapture(holdStart: true)
        let factory = MeterCaptureFactory([discovery, first, switching, denied, retry, pending])
        let monitor = SetupMicrophoneMonitor(makeCapture: { factory.next() })

        await monitor.refreshDevices()
        let discoveryStarts = await discovery.starts
        precondition(monitor.devices.count == 1 && discoveryStarts == 0 && monitor.state == .idle)
        precondition(!monitor.finish(), "An untested microphone cannot advance.")
        monitor.start()
        monitor.start()
        try await eventually { monitor.state == .listening }
        let firstStarts = await first.starts
        let recordingURL = await first.recordingURL
        precondition(firstStarts == 1 && recordingURL == nil, "Testing must not create an audio file.")

        let silent = MicrophoneMeter().process(Array(repeating: 0, count: 320), sampleRate: 16000)!
        await first.emit(silent)
        try await Task.sleep(for: .milliseconds(30))
        precondition(monitor.bands.allSatisfy { $0 == 0 } && !monitor.heardSound)
        precondition(!monitor.finish() && monitor.active, "Silence must not unlock Continue or stop the trial.")
        let sound = soundFrame()
        await first.emit(sound)
        try await eventually { monitor.heardSound }
        precondition(monitor.bands == sound.bands && monitor.level == sound.level,
                     "The UI must receive the actual meter bands, not generated motion.")
        precondition(monitor.displayLevels == sound.dictationLevels && monitor.canContinue,
                     "The compact waveform must use the measured, smoothed voice levels.")
        await first.emit(silent)
        try await eventually { monitor.level == 0 }
        precondition(monitor.bands.allSatisfy { $0 == 0 }, "Silent input must flatten the waveform.")
        precondition(monitor.displayLevels.allSatisfy { $0 == 0 } && monitor.canContinue,
                     "Silence flattens the display but preserves a successful trial.")

        monitor.select("external")
        try await eventually { await switching.starts == 1 }
        precondition(monitor.state == .starting && !monitor.heardSound)
        precondition(!monitor.canContinue, "A different microphone needs its own trial.")
        let selected = await switching.selectedID
        precondition(selected == "external")
        await first.emit(sound)
        try await Task.sleep(for: .milliseconds(30))
        precondition(!monitor.heardSound && monitor.bands.allSatisfy { $0 == 0 })
        await switching.releaseStart()
        try await eventually { monitor.state == .listening }
        await switching.emit(sound)
        try await eventually { monitor.heardSound }
        precondition(monitor.finish(), "A successful trial can continue.")
        await switching.emit(sound)
        try await eventually { await switching.stops > 0 }
        precondition(monitor.state == .stopped && monitor.bands.allSatisfy { $0 == 0 })
        precondition(monitor.canContinue && monitor.displayLevels.allSatisfy { $0 == 0 },
                     "Continue releases capture and preserves the result when returning.")

        monitor.start()
        try await eventually { monitor.error == .permission }
        precondition(!monitor.active && !monitor.heardSound)
        precondition(!monitor.finish(), "Permission failure must not unlock Continue.")
        monitor.start()
        try await eventually { monitor.state == .listening }
        precondition(monitor.error == nil)
        await retry.disconnect()
        await monitor.refreshDevices()
        precondition(monitor.error == .notFound && !monitor.active && monitor.selectedDeviceID.isEmpty)

        monitor.start()
        try await eventually { await pending.starts == 1 }
        monitor.stop() // Leave/close while a permission or hardware startup is suspended.
        await pending.releaseStart()
        await pending.emit(sound)
        try await eventually { await pending.stops > 0 }
        try await Task.sleep(for: .milliseconds(30))
        precondition(!monitor.active && !monitor.heardSound && monitor.bands.allSatisfy { $0 == 0 })
        print("PASS: measured voice levels, silence, Continue gating, capture release, no recording, device switch, stale frames, permission retry, disconnect, and pending-start cancellation.")
    }

    @MainActor private static func eventually(_ predicate: () async -> Bool) async throws {
        for _ in 0..<200 {
            if await predicate() { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        fatalError("Timed out waiting for Setup microphone state.")
    }

    private static func soundFrame() -> MicrophoneMeterFrame {
        let meter = MicrophoneMeter()
        var result: MicrophoneMeterFrame?
        for offset in 0..<8 {
            let samples: [Float] = (0..<320).map { index in
                let time = Double(index + offset * 320) / 16000
                return Float((1...8).reduce(0.0) { $0 + 0.04 * sin(2 * .pi * Double(197 * $1) * time) })
            }
            result = meter.process(samples, sampleRate: 16000)
        }
        precondition(result!.speechDetected)
        return result!
    }
}

private actor MeterCapture: MicrophoneCapturing {
    private(set) var starts = 0
    private(set) var stops = 0
    private(set) var selectedID = ""
    private(set) var recordingURL: URL?
    private var connected = true
    private let holdStart: Bool
    private let failure: MicrophoneCaptureError?
    private var continuation: CheckedContinuation<Void, Never>?
    private var onFrame: (@Sendable (MicrophoneMeterFrame) -> Void)?

    init(holdStart: Bool = false, failure: MicrophoneCaptureError? = nil) {
        self.holdStart = holdStart
        self.failure = failure
    }
    func devices() -> [MicrophoneDevice] {
        connected ? [MicrophoneDevice(id: "external", name: "External microphone")] : []
    }
    func start(deviceID: String, recordingURL: URL?,
               onFrame: @escaping @Sendable (MicrophoneMeterFrame) -> Void,
               onFailure: @escaping @Sendable (MicrophoneCaptureError) -> Void) async throws -> String {
        starts += 1
        selectedID = deviceID
        self.recordingURL = recordingURL
        self.onFrame = onFrame
        if let failure { throw failure }
        if holdStart { await withCheckedContinuation { continuation = $0 } }
        return deviceID
    }
    func stop() { stops += 1 }
    func emit(_ frame: MicrophoneMeterFrame) { onFrame?(frame) }
    func disconnect() { connected = false }
    func releaseStart() { continuation?.resume(); continuation = nil }
}

private final class MeterCaptureFactory: @unchecked Sendable {
    private let lock = NSLock()
    private var captures: [MeterCapture]
    init(_ captures: [MeterCapture]) { self.captures = captures }
    func next() -> MeterCapture { lock.withLock { captures.removeFirst() } }
}
