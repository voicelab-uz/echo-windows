import Foundation
import Observation

@MainActor protocol UpdateNotificationEnvironment: AnyObject {
    func authorization() async -> PushAuthorization
    func requestAuthorization() async throws -> Bool
    func post(_ update: UpdateNotification) async throws
    func remove(identifiers: [String])
    func clearUpdates()
    func removeObsolete(channel: String, installedBuild: String)
    func openSettings()
}

/// One quiet notification per channel/build, including across process restarts.
/// Suppressed events stay visible in Settings; they are not queued to interrupt later.
@MainActor @Observable final class UpdateNotificationService {
    private(set) var authorization: PushAuthorization = .notDetermined
    private(set) var isEnabled: Bool
    private(set) var isRequestingPermission = false
    private(set) var error: String?
    @ObservationIgnored var canDeliver: () -> Bool = { false }
    @ObservationIgnored var onOpen: (() -> Void)?
    @ObservationIgnored private let system: any UpdateNotificationEnvironment
    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private var channel: String?
    @ObservationIgnored private var generation = UUID()
    @ObservationIgnored private var inFlight: Set<String> = []
    @ObservationIgnored private var pendingOpen: UpdateNotification?
    private static let enabledKey = "Echo.notifications.updates.enabled"
    private static let deliveredKey = "Echo.notifications.updates.delivered.v1"

    init(system: any UpdateNotificationEnvironment, defaults: UserDefaults = .standard) {
        self.system = system
        self.defaults = defaults
        isEnabled = defaults.object(forKey: Self.enabledKey) as? Bool ?? true
    }

    func configure(channel: String, installedBuild: String) {
        system.removeObsolete(channel: channel, installedBuild: installedBuild)
        guard self.channel != channel else { return }
        generation = UUID()
        self.channel = channel
        if let pendingOpen {
            self.pendingOpen = nil
            open(pendingOpen)
        }
    }

    func refresh() async { authorization = await system.authorization() }

    func setEnabled(_ enabled: Bool) {
        generation = UUID()
        isEnabled = enabled
        defaults.set(enabled, forKey: Self.enabledKey)
        error = nil
        if !enabled { system.clearUpdates() }
    }

    /// Called only from a clearly labeled Settings action, never during startup.
    func requestPermission() async {
        guard !isRequestingPermission else { return }
        isRequestingPermission = true
        defer { isRequestingPermission = false }
        error = nil
        do {
            authorization = await system.authorization()
            if authorization == .notDetermined { _ = try await system.requestAuthorization() }
            else if authorization == .denied { system.openSettings() }
            await refresh()
        } catch {
            self.error = AppLocalization.text("Bildirishnoma ruxsatini olib bo‘lmadi. Qayta urinib ko‘ring.")
        }
    }

    func schedule(_ update: UpdateNotification) {
        let eventGeneration = generation
        Task { [weak self] in
            guard let self, eventGeneration == generation else { return }
            await consider(update, userInitiated: false)
        }
    }

    func consider(_ update: UpdateNotification, userInitiated: Bool) async {
        guard !userInitiated, isEnabled, update.channel == channel, canDeliver(),
              !delivered.contains(update.identifier), inFlight.insert(update.identifier).inserted else { return }
        let attempt = generation
        defer { inFlight.remove(update.identifier) }
        let status = await system.authorization()
        authorization = status
        guard attempt == generation, status == .authorized, isEnabled, canDeliver() else { return }
        do {
            try await system.post(update)
            guard attempt == generation, isEnabled else {
                system.remove(identifiers: [update.identifier])
                return
            }
            var recent = delivered.filter { $0 != update.identifier }
            recent.append(update.identifier)
            defaults.set(Array(recent.suffix(64)), forKey: Self.deliveredKey)
        } catch {
            guard attempt == generation else { return }
            // A later scheduled check may retry. There is no timer or alert loop.
            self.error = AppLocalization.text("Could not show the update notification. Updates are still available in Settings.")
        }
    }

    func canPresent(_ update: UpdateNotification) -> Bool {
        isEnabled && update.channel == channel && canDeliver()
    }

    func open(_ update: UpdateNotification) {
        guard let channel else { pendingOpen = update; return }
        guard update.channel == channel else { return }
        // Opening an already delivered alert remains useful after opting out.
        system.remove(identifiers: [update.identifier])
        onOpen?()
    }

    func clearDelivered() {
        generation = UUID()
        system.clearUpdates()
    }
    func openSystemSettings() { system.openSettings() }
    private var delivered: [String] { defaults.stringArray(forKey: Self.deliveredKey) ?? [] }
}
