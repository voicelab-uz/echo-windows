import Foundation

enum TextInsertionMethod: String, CaseIterable, Identifiable {
    case automatic, pasteboard, typing
    var id: String { rawValue }
    var title: String {
        switch self {
        case .automatic: "Avtomatik"
        case .pasteboard: "Clipboard orqali"
        case .typing: "Klaviatura orqali"
        }
    }
}
