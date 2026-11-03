import AppKit
import Security
import UserNotifications
import VoiceLabCore

@MainActor
final class NativePushNotificationEnvironment: PushNotificationEnvironment {
    var environment: PushEnvironment? {
        var code: SecCode?
        var staticCode: SecStaticCode?
        var information: CFDictionary?
        guard SecCodeCopySelf([], &code) == errSecSuccess, let code,
              SecCodeCopyStaticCode(code, [], &staticCode) == errSecSuccess, let staticCode,
              SecCodeCopySigningInformation(staticCode, SecCSFlags(rawValue: kSecCSSigningInformation), &information) == errSecSuccess,
              let values = information as? [String: Any],
              let entitlements = values[kSecCodeInfoEntitlementsDict as String] as? [String: Any],
              let raw = entitlements["com.apple.developer.aps-environment"] as? String
        else { return nil }
        return PushEnvironment(rawValue: raw)
    }
    func authorization() async -> PushAuthorization {
        switch await UNUserNotificationCenter.current().notificationSettings().authorizationStatus {
        case .authorized, .provisional, .ephemeral: .authorized
        case .notDetermined: .notDetermined
        default: .denied
        }
    }
    func requestAuthorization() async throws -> Bool {
        try await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound])
    }
    func register() { NSApplication.shared.registerForRemoteNotifications() }
    func unregister() { NSApplication.shared.unregisterForRemoteNotifications() }
    func clearDelivered(accountID: String, category: PushCategory?) {
        let center = UNUserNotificationCenter.current()
        Task {
            let notifications = await center.deliveredNotifications()
            // Signing out must remove account alerts, never local update reminders.
            let identifiers = notifications.filter {
                $0.request.trigger is UNPushNotificationTrigger &&
                    PushRoute(userInfo: $0.request.content.userInfo)?.accountID == accountID &&
                    (category == nil || PushRoute(userInfo: $0.request.content.userInfo)?.category == category)
            }.map { $0.request.identifier }
            center.removeDeliveredNotifications(withIdentifiers: identifiers)
        }
    }
    func openSettings() {
        guard let url = URL(string: "x-apple.systempreferences:com.apple.Notifications-Settings.extension") else { return }
        NSWorkspace.shared.open(url)
    }
}
