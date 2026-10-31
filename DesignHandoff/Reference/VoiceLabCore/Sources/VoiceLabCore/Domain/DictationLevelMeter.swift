import Foundation

/// Queue-confined visual meter, independent of speech detection and recorded audio.
/// Eight frequency groups follow the input; no clock-driven motion is introduced.
struct DictationLevelMeter {
    private static let groups = [
        1..<3, 3..<5, 5..<9, 9..<13, 13..<19, 19..<27, 27..<39, 39..<56,
    ]
    private var levels = [Double](repeating: 0, count: 8)
    private var aboveThreshold: TimeInterval = 0
    private var gateOpen = false

    mutating func process(rms: Double, magnitudes: [Double], duration: TimeInterval) -> [Double] {
        let db = 20 * log10(max(rms, 1e-10))
        // Hysteresis avoids chatter near the noise floor. A short isolated key
        // click cannot open the visual gate; captured audio is never gated.
        if gateOpen {
            if db < -56 {
                gateOpen = false
                aboveThreshold = 0
            }
        } else {
            aboveThreshold = db > -50 ? aboveThreshold + duration : 0
            gateOpen = aboveThreshold >= 0.05
        }
        let drive = gateOpen ? pow(min(1, max(0, (db + 54) / 36)), 1.3) : 0
        let energies = Self.groups.map { group in
            group.reduce(0.0) { $0 + magnitudes[$1] * magnitudes[$1] } / Double(group.count)
        }
        let peak = max(energies.max() ?? 0, 1e-20)
        for index in levels.indices {
            let target = drive * pow(energies[index] / peak, 0.25)
            // Fast response to syllables, slightly slower decay between words.
            let timeConstant = target > levels[index] ? 0.035 : 0.12
            let blend = 1 - exp(-duration / timeConstant)
            levels[index] += (target - levels[index]) * blend
            if target == 0, levels[index] < 0.005 { levels[index] = 0 }
        }
        return levels
    }
}
