import Foundation

/// Canned transcription for testing without spending VoiceLab credits. Launch a Debug build
/// with `-demoSpeech` and `SpeechSession` still records the mic but returns `text` instead of
/// uploading, after `-demoSpeechDelay <seconds>` (default 1.5). Never active in Release.
enum DemoSpeech {
    static var isRequested: Bool {
        #if DEBUG
        ProcessInfo.processInfo.arguments.contains("-demoSpeech")
        #else
        false
        #endif
    }

    static let text = "Assalomu alaykum, this note was dictated with the microphone."

    static var delay: Duration {
        // Launch arguments land in the argument domain of standard defaults.
        let seconds = UserDefaults.standard.double(forKey: "demoSpeechDelay")
        return .milliseconds(Int((seconds > 0 ? seconds : 1.5) * 1000))
    }
}
