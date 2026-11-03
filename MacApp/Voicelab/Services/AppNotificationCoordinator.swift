import AppKit
import UserNotifications

@MainActor protocol UpdateNotificationCenter: AnyObject {
    func post(_ update: UpdateNotification) async throws
    func deliveredUpdates() async -> [UpdateNotification]
    func remove(identifiers: [String])
}

@MainActor private final class SystemUpdateNotificationCenter: UpdateNotificationCenter {
    func post(_ update: UpdateNotification) async throws {
        let content = UNMutableNotificationContent()
        content.title = AppLocalization.text(update.stage == .ready
            ? "Echo %@ is ready to install" : "Echo %@ is available", update.version)
        content.body = AppLocalization.text("Open Echo to review the update. Your work will stay protected.")
        content.userInfo = update.userInfo
        // No sound: update reminders should not interrupt other work.
        try await UNUserNotificationCenter.current().add(UNNotificationRequest(
            identifier: update.identifier, content: content, trigger: nil))
    }

    func deliveredUpdates() async -> [UpdateNotification] {
        let notifications = await UNUserNotificationCenter.current().deliveredNotifications()
        return notifications.compactMap {
            guard !($0.request.trigger is UNPushNotificationTrigger) else { return nil }
            return UpdateNotification(identifier: $0.request.identifier, userInfo: $0.request.content.userInfo)
        }
    }

    func remove(identifiers: [String]) {
        let center = UNUserNotificationCenter.current()
        center.removePendingNotificationRequests(withIdentifiers: identifiers)
        center.removeDeliveredNotifications(withIdentifiers: identifiers)
    }
}

@MainActor final class NativeUpdateNotificationEnvironment: UpdateNotificationEnvironment {
    private let permission = NativePushNotificationEnvironment()
    private let center: any UpdateNotificationCenter
    private var operation: Task<Void, Never>?
    init(center: (any UpdateNotificationCenter)? = nil) {
        self.center = center ?? SystemUpdateNotificationCenter()
    }
    func authorization() async -> PushAuthorization { await permission.authorization() }
    func requestAuthorization() async throws -> Bool { try await permission.requestAuthorization() }
    func openSettings() { permission.openSettings() }

    func post(_ update: UpdateNotification) async throws {
        let previous = operation
        let posting = Task { [center] in
            await previous?.value
            try await center.post(update)
        }
        operation = Task { _ = try? await posting.value }
        try await posting.value
    }

    func remove(identifiers: [String]) {
        let previous = operation
        operation = Task { [center] in
            await previous?.value
            center.remove(identifiers: identifiers)
        }
    }

    func removeObsolete(channel: String, installedBuild: String) {
        let previous = operation
        operation = Task { [center] in
            await previous?.value
            let identifiers = await center.deliveredUpdates().filter {
                $0.isObsolete(channel: channel, installedBuild: installedBuild)
            }.map(\.identifier)
            center.remove(identifiers: identifiers)
        }
    }

    func clearUpdates() {
        let previous = operation
        operation = Task { [center] in
            await previous?.value
            // Keep query and removal ahead of every later post. Otherwise a slow
            // delivered-notifications callback could erase a newer reminder.
            let identifiers = await center.deliveredUpdates().map(\.identifier)
            center.remove(identifiers: identifiers)
        }
    }
}

/// Always installed, even in builds without APNs entitlements. Only typed,
/// Sendable route values cross from delegate callbacks to the main actor.
final class AppNotificationCoordinator: NSObject, UNUserNotificationCenterDelegate, Sendable {
    private let push: PushNotificationService?
    private let updates: UpdateNotificationService
    init(push: PushNotificationService?, updates: UpdateNotificationService) {
        self.push = push
        self.updates = updates
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter,
                                willPresent notification: UNNotification) async -> UNNotificationPresentationOptions {
        switch Self.route(notification) {
        case .update(let update):
            return await updates.canPresent(update) ? [.banner, .list] : []
        case .remote(let route):
            let allowed = await push?.canPresent(route) == true
            await push?.receive(route)
            return allowed ? [.banner, .list, .sound] : []
        case nil: return []
        }
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter,
                                didReceive response: UNNotificationResponse) async {
        guard response.actionIdentifier == UNNotificationDefaultActionIdentifier else { return }
        switch Self.route(response.notification) {
        case .update(let update): await updates.open(update)
        case .remote(let route): await push?.open(route)
        case nil: break
        }
    }

    private static func route(_ notification: UNNotification) -> AppNotificationRoute? {
        AppNotificationRoute.resolve(identifier: notification.request.identifier,
            userInfo: notification.request.content.userInfo,
            isRemote: notification.request.trigger is UNPushNotificationTrigger)
    }
}
