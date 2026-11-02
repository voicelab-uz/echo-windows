import AVFoundation
import Foundation
import VoiceLabCore

struct MicrophoneDevice: Identifiable, Sendable, Equatable {
    let id: String
    let name: String

    static var defaultDeviceID: String {
        AVCaptureDevice.default(for: .audio)?.uniqueID ?? ""
    }
}

enum MicrophoneCaptureError: LocalizedError, Sendable, Equatable {
    case permission, notFound, unavailable, interrupted, unsupportedFormat
    var errorDescription: String? {
        switch self {
        case .permission:
            "Mikrofonga ruxsat kerak. System Settings → Privacy & Security → Microphone bo‘limida Echo’ni yoqing."
        case .notFound: "Mikrofon topilmadi. Qurilmani ulang yoki tizim mikrofonini tanlang."
        case .unavailable: "Mikrofonni ishga tushirib bo‘lmadi. Qurilmani tekshiring va qayta urinib ko‘ring."
        case .interrupted:
            "Mikrofon bilan aloqa uzildi. Qurilmalarni yangilang yoki boshqa mikrofonni tanlang."
        case .unsupportedFormat: "Mikrofonning audio formatini o‘qib bo‘lmadi. Boshqa qurilmani tanlang."
        }
    }
}

protocol MicrophoneCapturing: Sendable {
    func devices() async -> [MicrophoneDevice]
    func start(
        deviceID: String, recordingURL: URL?,
        onFrame: @escaping @Sendable (MicrophoneMeterFrame) -> Void,
        onFailure: @escaping @Sendable (MicrophoneCaptureError) -> Void
    ) async throws -> String
    func stop() async
}

/// All capture, device configuration, file I/O and DSP are confined to one serial queue.
/// Test mode passes no recordingURL: no file, network request or speaker output is created.
final class MicrophoneCapture: NSObject, MicrophoneCapturing, AVCaptureAudioDataOutputSampleBufferDelegate,
    @unchecked Sendable
{
    private let queue = DispatchQueue(label: "uz.voicelab.microphone", qos: .userInitiated)
    private var session: AVCaptureSession?
    private var output: AVCaptureAudioDataOutput?
    private var file: PCMRecordingWriter?
    private var generation = UUID()
    private var meter: MicrophoneMeter?
    private var converter: MicrophonePCMConverter?
    private var pendingStart: CheckedContinuation<String, Error>?
    private var startupTimeout: DispatchWorkItem?
    private var resolvedDeviceID = ""
    private var observers: [NSObjectProtocol] = []
    private var onFrame: (@Sendable (MicrophoneMeterFrame) -> Void)?
    private var onFailure: (@Sendable (MicrophoneCaptureError) -> Void)?

    func devices() async -> [MicrophoneDevice] {
        await withCheckedContinuation { continuation in
            queue.async {
                let devices = AVCaptureDevice.DiscoverySession(
                    deviceTypes: [.microphone, .external], mediaType: .audio, position: .unspecified
                ).devices
                continuation.resume(
                    returning: devices.map { MicrophoneDevice(id: $0.uniqueID, name: $0.localizedName) }
                        .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending })
            }
        }
    }

    func start(
        deviceID: String, recordingURL: URL?,
        onFrame: @escaping @Sendable (MicrophoneMeterFrame) -> Void,
        onFailure: @escaping @Sendable (MicrophoneCaptureError) -> Void
    ) async throws -> String {
        guard await AVCaptureDevice.requestAccess(for: .audio) else {
            throw MicrophoneCaptureError.permission
        }
        try Task.checkCancellation()
        return try await withCheckedThrowingContinuation { continuation in
            queue.async { [self] in
                self.close()
                self.pendingStart = continuation
                do {
                    let preferred = deviceID.isEmpty ? nil : AVCaptureDevice(uniqueID: deviceID)
                    guard let device = preferred ?? AVCaptureDevice.default(for: .audio),
                        device.hasMediaType(.audio)
                    else {
                        throw MicrophoneCaptureError.notFound
                    }
                    let session = AVCaptureSession()
                    let input = try AVCaptureDeviceInput(device: device)
                    let output = AVCaptureAudioDataOutput()
                    // Let CoreMedia use the microphone's native format. Device-side
                    // conversion to 16 kHz can fail for USB/Bluetooth/virtual inputs.
                    output.audioSettings = nil
                    session.beginConfiguration()
                    guard session.canAddInput(input), session.canAddOutput(output) else {
                        session.commitConfiguration()
                        throw MicrophoneCaptureError.unavailable
                    }
                    session.addInput(input)
                    session.addOutput(output)
                    session.commitConfiguration()
                    if let recordingURL {
                        self.file = try PCMRecordingWriter(url: recordingURL)
                    }
                    self.session = session
                    self.output = output
                    self.meter = MicrophoneMeter()
                    self.converter = MicrophonePCMConverter()
                    self.resolvedDeviceID = preferred == nil ? "" : device.uniqueID
                    self.onFrame = onFrame
                    self.onFailure = onFailure
                    output.setSampleBufferDelegate(self, queue: self.queue)
                    self.observeFailures(session: session, device: device)
                    session.startRunning()
                    guard session.isRunning else { throw MicrophoneCaptureError.unavailable }
                    // isRunning is not proof that a broken device delivers audio.
                    // Complete startup only after the first valid PCM buffer.
                    let id = self.generation
                    let timeout = DispatchWorkItem { [weak self] in
                        guard let self, self.generation == id, self.pendingStart != nil else { return }
                        self.fail(.unavailable)
                    }
                    self.startupTimeout = timeout
                    self.queue.asyncAfter(deadline: .now() + 5, execute: timeout)
                } catch {
                    self.close(startError: (error as? MicrophoneCaptureError) ?? .unavailable)
                }
            }
        }
    }

    func stop() async {
        await withCheckedContinuation { continuation in
            queue.async {
                self.close()
                continuation.resume()
            }
        }
    }

    func captureOutput(
        _ output: AVCaptureOutput, didOutput buffer: CMSampleBuffer, from connection: AVCaptureConnection
    ) {
        guard output === self.output else { return }
        guard let meter, let converter else { return }
        do {
            let samples = try converter.convert(buffer)
            guard !samples.isEmpty else { return }
            try file?.write(samples)
            if let pendingStart {
                self.pendingStart = nil
                startupTimeout?.cancel()
                startupTimeout = nil
                pendingStart.resume(returning: resolvedDeviceID)
            }
            if let frame = meter.process(samples, sampleRate: MicrophonePCMConverter.sampleRate) {
                onFrame?(frame)
            }
        } catch {
            fail((error as? MicrophoneCaptureError) ?? .unavailable)
        }
    }

    private func observeFailures(session: AVCaptureSession, device: AVCaptureDevice) {
        let id = generation
        for (name, object) in [
            (AVCaptureSession.runtimeErrorNotification, session as AnyObject),
            (AVCaptureSession.wasInterruptedNotification, session as AnyObject),
            (AVCaptureDevice.wasDisconnectedNotification, device as AnyObject),
        ] {
            observers.append(
                NotificationCenter.default.addObserver(forName: name, object: object, queue: nil) {
                    @Sendable [weak self] _ in
                    self?.queue.async { [weak self] in
                        guard let self, self.generation == id else { return }
                        self.fail(.interrupted)
                    }
                })
        }
    }
    private func fail(_ error: MicrophoneCaptureError) {
        let callback = pendingStart == nil ? onFailure : nil
        close(startError: error)
        callback?(error)
    }
    private func close(startError: any Error = CancellationError()) {
        generation = UUID()
        startupTimeout?.cancel()
        startupTimeout = nil
        let pendingStart = self.pendingStart
        self.pendingStart = nil
        observers.forEach(NotificationCenter.default.removeObserver)
        observers.removeAll()
        output?.setSampleBufferDelegate(nil, queue: nil)
        session?.stopRunning()
        session = nil
        output = nil
        file = nil
        meter = nil
        converter = nil
        onFrame = nil
        onFailure = nil
        pendingStart?.resume(throwing: startError)
    }
}
