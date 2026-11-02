import ActivityKit
import Foundation

/// Small, transcript-free state shared by the app and its Live Activity extension.
struct EchoLiveActivityAttributes: ActivityAttributes {
    let sessionID: String

    struct ContentState: Codable, Hashable, Sendable {
        enum Phase: String, Codable, Sendable {
            case ready, starting, recording, transcribing, off, unavailable
        }
        var phase: Phase
        var recordingStartedAt: Date?
        var audioLevel: Double
        var languageCode: String

        func text(uz: String, en: String, ru: String) -> String {
            switch languageCode {
            case "en": en
            case "ru": ru
            default: uz
            }
        }
        var status: String {
            switch phase {
            case .ready: text(uz: "Echo tayyor", en: "Echo is ready", ru: "Echo готов")
            case .starting: text(uz: "Tayyorlanmoqda", en: "Getting ready", ru: "Подготовка")
            case .recording: text(uz: "Tinglanmoqda", en: "Listening", ru: "Слушаю")
            case .transcribing: text(uz: "Matnga o‘girilmoqda", en: "Transcribing", ru: "Распознавание")
            case .unavailable: text(uz: "Holatni Echo’da tekshiring", en: "Check status in Echo", ru: "Проверьте статус в Echo")
            case .off: text(uz: "Seans tugadi", en: "Session ended", ru: "Сеанс завершён")
            }
        }
    }
}

extension Notification.Name {
    static let echoLiveActivityEndRequested = Notification.Name("uz.voicelab.echo.liveActivity.endRequested")
}
