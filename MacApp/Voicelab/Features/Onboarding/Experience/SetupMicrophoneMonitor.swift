import Foundation
import Observation
import VoiceLabCore

/// UI state for a local, meter-only capture. No audio URL is ever supplied.
@MainActor @Observable
final class SetupMicrophoneMonitor {
    enum State { case idle, starting, listening, stopped }
    private(set) var state = State.idle
    private(set) var devices: [MicrophoneDevice] = []
    private(set) var selectedDeviceID = ""
    private(set) var bands = Array(repeating: 0.0, count: MicrophoneMeter.bandCount)
    private(set) var displayLevels = Array(repeating: 0.0, count: 8)
    private(set) var level = 0.0
    private(set) var heardSound = false
    private(set) var error: MicrophoneCaptureError?
    @ObservationIgnored private let makeCapture: @Sendable () -> any MicrophoneCapturing
    @ObservationIgnored private var capture: (any MicrophoneCapturing)?
    @ObservationIgnored private var operation: Task<Void, Never>?
    @ObservationIgnored private var generation = UUID()
    @ObservationIgnored private var discoveryGeneration = UUID()

    var active: Bool { state == .starting || state == .listening }
    var canContinue: Bool { heardSound && error == nil }

    init(makeCapture: @escaping @Sendable () -> any MicrophoneCapturing = { MicrophoneCapture() }) {
        self.makeCapture = makeCapture
    }

    func refreshDevices() async {
        let discoveryID = UUID()
        discoveryGeneration = discoveryID
        let devices = await (capture ?? makeCapture()).devices()
        guard !Task.isCancelled, discoveryGeneration == discoveryID else { return }
        self.devices = devices
        if !selectedDeviceID.isEmpty && !devices.contains(where: { $0.id == selectedDeviceID }) {
            stop()
            selectedDeviceID = ""
            heardSound = false
            error = .notFound
        }
    }

    func select(_ id: String) {
        guard id != selectedDeviceID else { return }
        let wasActive = active
        stop()
        selectedDeviceID = id
        error = nil
        heardSound = false
        state = .idle
        if wasActive { start() }
    }

    func start() {
        guard !active else { return }
        stop()
        state = .starting
        heardSound = false
        error = nil
        let id = generation
        let capture = makeCapture()
        self.capture = capture
        let deviceID = selectedDeviceID
        operation = Task { [weak self] in
            do {
                let resolvedID = try await capture.start(
                    deviceID: deviceID, recordingURL: nil,
                    onFrame: { [weak self] frame in
                        Task { @MainActor [weak self] in
                            guard let self, self.generation == id, self.active, self.error == nil else { return }
                            self.bands = frame.bands
                            self.displayLevels = frame.dictationLevels
                            self.level = frame.level
                            self.heardSound = self.heardSound || frame.speechDetected
                        }
                    },
                    onFailure: { [weak self] error in
                        Task { @MainActor [weak self] in
                            guard let self, self.generation == id, self.active else { return }
                            self.fail(error)
                        }
                    })
                guard !Task.isCancelled, let self, self.generation == id, self.active else {
                    await capture.stop()
                    return
                }
                self.selectedDeviceID = resolvedID
                self.state = .listening
                await self.refreshDevices()
            } catch {
                await capture.stop()
                guard let self, self.generation == id, !Task.isCancelled else { return }
                self.fail((error as? MicrophoneCaptureError) ?? .unavailable)
            }
        }
    }

    func stop() {
        generation = UUID()
        operation?.cancel()
        operation = nil
        if let capture { Task { await capture.stop() } }
        capture = nil
        if state != .idle { state = .stopped }
        bands = Array(repeating: 0, count: MicrophoneMeter.bandCount)
        displayLevels = Array(repeating: 0, count: 8)
        level = 0
    }

    /// A failed or silent trial cannot advance. Release the mic before navigation.
    func finish() -> Bool {
        guard canContinue else { return false }
        stop()
        return true
    }

    private func fail(_ error: MicrophoneCaptureError) {
        stop()
        heardSound = false
        self.error = error
    }
}
