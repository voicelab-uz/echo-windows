import Foundation
import Observation
import VoiceLabCore

@MainActor @Observable
final class MicrophoneTestModel {
    private(set) var bands = Array(repeating: 0.0, count: MicrophoneMeter.bandCount)
    private(set) var speechDetected = false
    private(set) var isRunning = false
    private(set) var isStarting = false
    private(set) var devices: [MicrophoneDevice] = []
    private(set) var error: MicrophoneCaptureError?
    private(set) var selectedDeviceID: String
    @ObservationIgnored private let preferences: Preferences
    @ObservationIgnored private let makeCapture: @Sendable () -> any MicrophoneCapturing
    @ObservationIgnored private var capture: (any MicrophoneCapturing)?
    @ObservationIgnored private var operation: Task<Void, Never>?
    @ObservationIgnored private var generation = UUID()
    @ObservationIgnored private var active = false

    init(
        preferences: Preferences,
        makeCapture: @escaping @Sendable () -> any MicrophoneCapturing = { MicrophoneCapture() }
    ) {
        self.preferences = preferences
        self.makeCapture = makeCapture
        selectedDeviceID = preferences.microphoneID
    }

    func start() {
        guard !isStarting && !isRunning else { return }
        restart()
    }
    func select(_ id: String) {
        guard id != selectedDeviceID else { return }
        selectedDeviceID = id
        preferences.microphoneID = id
        if active { restart() }
    }
    func refreshDevices() async {
        let id = generation
        let devices = await (capture ?? makeCapture()).devices()
        guard active, id == generation else { return }
        self.devices = devices
        if !selectedDeviceID.isEmpty && !devices.contains(where: { $0.id == selectedDeviceID }) {
            select("")
        } else if !isRunning && !isStarting {
            restart()
        }
    }
    func retry() { restart() }

    private func restart() {
        stop()
        active = true
        isStarting = true
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
                            guard let self, self.active, self.generation == id, self.error == nil else {
                                return
                            }
                            self.bands = frame.bands
                            self.speechDetected = frame.speechDetected
                        }
                    },
                    onFailure: { [weak self] error in
                        Task { @MainActor [weak self] in
                            guard let self, self.active, self.generation == id else { return }
                            self.failed(error)
                        }
                    })
                guard !Task.isCancelled, let self, self.active, self.generation == id else {
                    await capture.stop()
                    return
                }
                guard self.error == nil else {
                    await capture.stop()
                    return
                }
                self.selectedDeviceID = resolvedID
                self.preferences.microphoneID = resolvedID
                self.isStarting = false
                self.isRunning = true
                await self.refreshDevices()
            } catch {
                await capture.stop()
                guard let self, self.active, self.generation == id, !Task.isCancelled else { return }
                self.failed((error as? MicrophoneCaptureError) ?? .unavailable)
            }
        }
    }
    private func failed(_ error: MicrophoneCaptureError) {
        self.error = error
        isStarting = false
        isRunning = false
        speechDetected = false
        bands = Array(repeating: 0, count: MicrophoneMeter.bandCount)
    }
    func stop() {
        active = false
        generation = UUID()
        operation?.cancel()
        operation = nil
        if let capture { Task { await capture.stop() } }
        capture = nil
        isStarting = false
        isRunning = false
        speechDetected = false
        bands = Array(repeating: 0, count: MicrophoneMeter.bandCount)
    }
}
