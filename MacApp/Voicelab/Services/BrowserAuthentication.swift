import AppKit
import VoiceLabCore

/// Uses the existing browser session and a callback owned by this app process.
@MainActor
final class BrowserAuthentication {
    private let openURL: @MainActor (URL) -> Bool

    init(openURL: @escaping @MainActor (URL) -> Bool = { NSWorkspace.shared.open($0) }) {
        self.openURL = openURL
    }

    func authenticate(using authentication: Authentication) async throws -> URL {
        let callback = LoopbackAuthenticationCallback()
        return try await withTaskCancellationHandler {
            defer { callback.cancel() }
            let redirectURI = try await callback.start()
            let attempt = try await authentication.beginAuthorization(redirectURI: redirectURI)
            try Task.checkCancellation()
            return try await callback.wait(for: attempt, openURL: openURL)
        } onCancel: {
            Task { @MainActor in callback.cancel() }
        }
    }
}

enum BrowserAuthenticationError: LocalizedError {
    case browserUnavailable, callbackUnavailable, timedOut

    var errorDescription: String? {
        switch self {
        case .browserUnavailable:
            "Brauzerni ochib bo‘lmadi. Standart brauzeringizni tekshirib, qayta urinib ko‘ring."
        case .callbackUnavailable:
            "Brauzerdan javob olishni ishga tushirib bo‘lmadi. Qayta urinib ko‘ring."
        case .timedOut:
            "Brauzerda kirish uchun ajratilgan vaqt tugadi. Qayta urinib ko‘ring."
        }
    }
}
