import Foundation

/// How the global dictation shortcut starts and ends a recording.
enum DictationActivationMode: String, CaseIterable, Identifiable {
    /// Press once to start, press again to stop.
    case toggle
    /// Recording lasts while the shortcut is held down.
    case hold
    /// Hold to talk, or tap once for hands-free recording that the next press ends.
    case automatic

    var id: String { rawValue }

    var title: String {
        switch self {
        case .toggle: "Bosib yoqish"
        case .hold: "Bosib turish"
        case .automatic: "Avtomatik (ikkalasi)"
        }
    }

    var detail: String {
        switch self {
        case .toggle: "Bir marta bosing — yozuv boshlanadi, yana bosing — tugaydi."
        case .hold: "Tugmani bosib turib gapiring, qo‘yib yuborsangiz yozuv tugaydi."
        case .automatic: "Bosib turib gapiring yoki bir marta bosib qo‘lsiz yozing. To‘xtatish uchun yana bosing."
        }
    }
}
