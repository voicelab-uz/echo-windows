import Accelerate
import Foundation

public struct MicrophoneMeterFrame: Sendable {
    public let bands: [Double]
    public let level: Double
    public let dictationLevels: [Double]
    public let elapsed: TimeInterval
    public let speechDetected: Bool
}

/// Queue-confined DSP. Mirrors the desktop's 256-point analyser, 28 lower-frequency
/// bands, 0.7 smoothing, and six consecutive speech-level frames. No audio is retained
/// beyond a single analysis window. UI delivery is capped at 60 frames per second.
public final class MicrophoneMeter {
    public static let bandCount = 28
    private static let windowSize = 256
    private let transform: vDSP_DFT_Setup
    private var window = [Float](repeating: 0, count: windowSize)
    private var samples = [Float](repeating: 0, count: windowSize)
    private var real = [Float](repeating: 0, count: windowSize)
    private var imaginary = [Float](repeating: 0, count: windowSize)
    private var outputReal = [Float](repeating: 0, count: windowSize)
    private var outputImaginary = [Float](repeating: 0, count: windowSize)
    private var magnitudes = [Double](repeating: 0, count: windowSize / 4)
    private var cursor = 0
    private var sinceDelivery = 0
    private var totalSamples = 0
    private var speechFrames = 0
    private var detected = false
    private var dictationMeter = DictationLevelMeter()
    private var deliveryEnergy = 0.0

    public init() {
        // 256 is a supported radix-2 DFT size.
        transform = vDSP_DFT_zop_CreateSetup(nil, vDSP_Length(Self.windowSize), .FORWARD)!
        vDSP_blkman_window(&window, vDSP_Length(Self.windowSize), 0)
    }
    deinit { vDSP_DFT_DestroySetup(transform) }

    public func process(_ input: [Float], sampleRate: Double) -> MicrophoneMeterFrame? {
        guard !input.isEmpty, sampleRate.isFinite, sampleRate > 0 else { return nil }
        var energy = 0.0
        for value in input {
            let sample = value.isFinite ? min(1, max(-1, value)) : 0
            samples[cursor] = sample
            cursor = (cursor + 1) % Self.windowSize
            energy += Double(sample * sample)
        }
        totalSamples += input.count
        sinceDelivery += input.count
        deliveryEnergy += energy
        guard sinceDelivery >= Int(ceil(sampleRate / 60)) else { return nil }
        let duration = Double(sinceDelivery) / sampleRate
        let rms = sqrt(deliveryEnergy / Double(sinceDelivery))
        sinceDelivery = 0
        deliveryEnergy = 0
        for i in 0..<Self.windowSize { real[i] = samples[(cursor + i) % Self.windowSize] * window[i] }
        vDSP_DFT_Execute(transform, real, imaginary, &outputReal, &outputImaginary)
        for i in magnitudes.indices {
            let magnitude = hypot(Double(outputReal[i]), Double(outputImaginary[i])) / Double(Self.windowSize)
            magnitudes[i] = 0.7 * magnitudes[i] + 0.3 * magnitude
        }
        let bands = (0..<Self.bandCount).map { band in
            (0..<2).reduce(0.0) { result, offset in
                let db = 20 * log10(max(magnitudes[band * 2 + offset], 1e-10))
                return result + min(1, max(0, (db + 100) / 70)) / 2
            }
        }
        // Require current input as well as spectrum energy so a decaying spike cannot pass.
        if bands.reduce(0, +) / Double(Self.bandCount) > 0.12 && rms > 0.003 {
            speechFrames += 1
            if speechFrames >= 6 { detected = true }
        } else {
            speechFrames = 0
        }
        return MicrophoneMeterFrame(
            bands: bands, level: min(1, pow(rms, 2.0 / 3)),
            dictationLevels: dictationMeter.process(rms: rms, magnitudes: magnitudes, duration: duration),
            elapsed: Double(totalSamples) / sampleRate, speechDetected: detected)
    }
}
