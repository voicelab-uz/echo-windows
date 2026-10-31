import Foundation
import Testing

@testable import VoiceLabCore

struct MicrophoneMeterTests {
    private func signal(_ offset: Int = 0) -> [Float] {
        (0..<320).map { i in
            let t = Double(i + offset) / 16000
            return Float(
                (1...8).reduce(0.0) { sum, harmonic in
                    sum + 0.04 * sin(2 * .pi * Double(197 * harmonic) * t)
                })
        }
    }

    @Test func silenceNeverUnlocks() {
        let meter = MicrophoneMeter()
        for _ in 0..<100 {
            let frame = meter.process(Array(repeating: 0, count: 320), sampleRate: 16000)!
            #expect(!frame.speechDetected)
            #expect(frame.bands == Array(repeating: 0, count: 28))
            #expect(frame.level == 0)
        }
    }

    @Test func sustainedSoundUnlocksAndRemainsDetected() {
        let meter = MicrophoneMeter()
        for index in 0..<6 {
            let frame = meter.process(signal(index * 320), sampleRate: 16000)!
            #expect(frame.speechDetected == (index == 5))
            #expect(frame.bands.count == 28)
            #expect(frame.bands.allSatisfy { $0.isFinite && (0...1).contains($0) })
            #expect(Set(frame.bands).count > 5, "Bands must represent frequencies, not repeated volume.")
        }
        let silence = meter.process(Array(repeating: 0, count: 320), sampleRate: 16000)!
        #expect(silence.speechDetected)
        #expect(abs(silence.elapsed - 0.14) < 0.001)
        let fresh = MicrophoneMeter().process(signal(), sampleRate: 16000)!
        #expect(!fresh.speechDetected, "Changing input starts a new detection window.")
    }

    @Test func isolatedNoiseCannotUnlockThroughSpectrumDecay() {
        let meter = MicrophoneMeter()
        _ = meter.process(signal(), sampleRate: 16000)
        for _ in 0..<30 {
            let frame = meter.process(Array(repeating: 0, count: 320), sampleRate: 16000)!
            #expect(!frame.speechDetected)
        }
    }

    @Test func invalidInputAndDeliveryRateAreBounded() {
        let meter = MicrophoneMeter()
        #expect(meter.process([], sampleRate: 16000) == nil)
        #expect(meter.process([0], sampleRate: .nan) == nil)
        #expect(meter.process(Array(repeating: 0, count: 200), sampleRate: 16000) == nil)
        let frame = meter.process(Array(repeating: .infinity, count: 100), sampleRate: 16000)!
        #expect(frame.level == 0)
        #expect(frame.bands.allSatisfy { $0.isFinite })
        #expect(!frame.speechDetected)
    }
}
