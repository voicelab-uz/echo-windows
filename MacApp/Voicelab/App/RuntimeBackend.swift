import Foundation
import VoiceLabCore

enum RuntimeBackend {
    static let environment = ServerEnvironment.production

    static var keychain: KeychainStore {
        KeychainStore(service: "uz.voicelab.native" + environment.storageNamespace)
    }
    static var libraryDirectory: URL {
        URL.applicationSupportDirectory.appendingPathComponent(
            "VoiceLabNative" + environment.storageNamespace, isDirectory: true)
    }
    static var signInCooldownKey: String { "VoiceLab.auth.retryAt" + environment.storageNamespace }
}
