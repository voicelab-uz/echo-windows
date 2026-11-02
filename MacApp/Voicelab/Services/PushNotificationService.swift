import Foundation
import Observation
import VoiceLabCore

enum PushAuthorization { case notDetermined, denied, authorized }

@MainActor
protocol PushNotificationEnvironment: AnyObject {
    var environment: PushEnvironment? { get }
    func authorization() async -> PushAuthorization
    func requestAuthorization() async throws -> Bool
    func register()
    func unregister()
    func clearDelivered(accountID: String, category: PushCategory?)
    func openSettings()
}

/// Account-bound registration. Nothing prompts, polls, or blocks app startup.
@MainActor @Observable
final class PushNotificationService {
    private(set) var authorization: PushAuthorization = .notDetermined
    private(set) var isEnabled: Bool
    private(set) var preferences: PushPreferences
    private(set) var isUpdating = false
    private(set) var error: String?
    private(set) var accountID: String?
    @ObservationIgnored var onReceive: (() -> Void)?
    @ObservationIgnored var onOpen: ((PushRoute) -> Void)?
    @ObservationIgnored private let api: any PushServing
    @ObservationIgnored private let system: any PushNotificationEnvironment
    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private var registration: PushRegistration?
    @ObservationIgnored private var uploaded: PushRegistration?
    @ObservationIgnored private var syncTask: Task<Void, Never>?
    @ObservationIgnored private var removalTask: Task<Void, Never>?
    @ObservationIgnored private var serverUnsubscribed = false
    @ObservationIgnored private var generation = UUID()
    @ObservationIgnored private var nextAttempt = Date.distantPast
    @ObservationIgnored private var pendingRoute: PushRoute?
    private static let enabledKey = "Echo.push.enabled"
    private static let importantKey = "Echo.push.important.enabled"
    private static let newsKey = "Echo.push.news.enabled"

    init(api: any PushServing, system: any PushNotificationEnvironment,
         defaults: UserDefaults = .standard) {
        self.api = api
        self.system = system
        self.defaults = defaults
        let enabled = defaults.object(forKey: Self.enabledKey) as? Bool ?? true
        isEnabled = enabled
        preferences = PushPreferences(
            important: defaults.object(forKey: Self.importantKey) as? Bool ?? enabled,
            news: defaults.object(forKey: Self.newsKey) as? Bool ?? enabled)
    }

    deinit {
        syncTask?.cancel()
        removalTask?.cancel()
    }

    func activate(accountID: String) {
        let route = pendingRoute
        if self.accountID != accountID {
            deactivate()
            self.accountID = accountID
        }
        pendingRoute = nil
        if let route { open(route) }
        Task { await refresh() }
    }

    func deactivate() {
        let previousOwner = accountID
        generation = UUID()
        syncTask?.cancel()
        syncTask = nil
        removalTask?.cancel()
        removalTask = nil
        serverUnsubscribed = false
        accountID = nil
        registration = nil
        uploaded = nil
        nextAttempt = .distantPast
        system.unregister()
        if let previousOwner { system.clearDelivered(accountID: previousOwner, category: nil) }
        error = nil
        pendingRoute = nil
    }

    func refresh() async {
        let current = generation
        let status = await system.authorization()
        guard current == generation else { return }
        authorization = status
        guard accountID != nil, isEnabled, status == .authorized else {
            system.unregister()
            if status == .denied || !isEnabled { await removeRegistration() }
            return
        }
        guard system.environment != nil else {
            error = AppLocalization.text("Push uchun ilovani imzolash sozlamalari kerak.")
            return
        }
        if registration == nil && Date.now >= nextAttempt { system.register() }
        else { synchronize() }
    }

    /// Category choices do not request OS permission. Settings has one explicit
    /// permission action shared by local updates and remote alerts.
    func setCategory(_ category: PushCategory, enabled: Bool) async {
        guard !isUpdating else { return }
        if !isEnabled { preferences = PushPreferences(important: false, news: false) }
        preferences[category] = enabled
        isEnabled = true
        defaults.set(true, forKey: Self.enabledKey)
        savePreferences()
        if !enabled, let accountID { system.clearDelivered(accountID: accountID, category: category) }
        error = nil
        nextAttempt = .distantPast
        await refresh()
    }

    private func savePreferences() {
        defaults.set(preferences.important, forKey: Self.importantKey)
        defaults.set(preferences.news, forKey: Self.newsKey)
        registration?.preferences = preferences
    }

    func setEnabled(_ enabled: Bool) async {
        guard !isUpdating else { return }
        isUpdating = true
        defer { isUpdating = false }
        isEnabled = enabled
        defaults.set(enabled, forKey: Self.enabledKey)
        if enabled && !preferences.hasEnabledCategory { preferences = PushPreferences(); savePreferences() }
        error = nil
        nextAttempt = .distantPast
        if !enabled {
            system.unregister()
            if let accountID { system.clearDelivered(accountID: accountID, category: nil) }
            await removeRegistration()
            return
        }
        let current = generation
        do {
            let status = await system.authorization()
            guard current == generation else { return }
            if status == .notDetermined {
                _ = try await system.requestAuthorization()
            } else if status == .denied { system.openSettings() }
            guard current == generation else { return }
            await refresh()
        } catch {
            guard current == generation else { return }
            self.error = AppLocalization.text("Bildirishnoma ruxsatini olib bo‘lmadi. Qayta urinib ko‘ring.")
        }
    }

    func receivedToken(_ data: Data) {
        guard isEnabled, accountID != nil, authorization == .authorized,
              !data.isEmpty, let environment = system.environment else { return }
        let value = PushRegistration(token: data, environment: environment, preferences: preferences)
        if value != registration {
            registration = value
            uploaded = nil
            nextAttempt = .distantPast
            // Complete any preceding PUT before uploading a rotated token.
        }
        synchronize()
    }

    func registrationFailed() {
        guard accountID != nil, isEnabled else { return }
        nextAttempt = .now.addingTimeInterval(60)
        error = AppLocalization.text("Pushga ulanib bo‘lmadi. Keyingi faollashishda qayta uriniladi.")
    }

    func canPresent(_ route: PushRoute?) -> Bool {
        guard isEnabled, let accountID, let route, route.accountID == accountID else { return false }
        return preferences[route.category]
    }

    func receive(_ route: PushRoute?) {
        guard canPresent(route) else { return }
        onReceive?()
    }

    func open(_ route: PushRoute) {
        if accountID == nil {
            pendingRoute = route
            return
        }
        guard canPresent(route) else { return }
        onReceive?()
        onOpen?(route)
    }

    func openSystemSettings() { system.openSettings() }
    func retryRegistration() async {
        nextAttempt = .distantPast
        await refresh()
    }

    private func synchronize() {
        guard syncTask == nil, removalTask == nil, isEnabled, authorization == .authorized,
              Date.now >= nextAttempt, let owner = accountID,
              let value = registration, uploaded != value else { return }
        let current = generation
        serverUnsubscribed = false
        syncTask = Task { [weak self, api] in
            do {
                try await api.registerPush(value, accountID: owner)
                guard let self, current == self.generation, !Task.isCancelled else { return }
                self.uploaded = value
                self.error = nil
                self.syncTask = nil
                self.synchronize()
            } catch {
                guard let self, current == self.generation, !Task.isCancelled else { return }
                self.syncTask = nil
                // No retry loop or competing token refreshes. Foreground activation retries.
                self.nextAttempt = .now.addingTimeInterval(60)
                if case VoiceLabError.rateLimited(let retryAt, _) = error {
                    self.nextAttempt = max(self.nextAttempt, retryAt)
                }
                self.error = AppLocalization.text("Pushga ulanib bo‘lmadi. Keyingi faollashishda qayta uriniladi.")
            }
        }
    }

    private func removeRegistration() async {
        if let removalTask {
            await removalTask.value
            return
        }
        guard !serverUnsubscribed, Date.now >= nextAttempt, let owner = accountID else { return }
        let current = generation
        // Await an in-flight PUT so it cannot arrive after our DELETE.
        let pending = syncTask
        let task = Task { [weak self, api] in
            await pending?.value
            guard let self, current == self.generation, !Task.isCancelled else { return }
            do {
                try await api.unregisterPush(accountID: owner)
                guard current == self.generation, !Task.isCancelled else { return }
                self.uploaded = nil
                self.serverUnsubscribed = true
                self.error = nil
            } catch {
                guard current == self.generation, !Task.isCancelled else { return }
                self.nextAttempt = .now.addingTimeInterval(60)
                if case VoiceLabError.rateLimited(let retryAt, _) = error {
                    self.nextAttempt = max(self.nextAttempt, retryAt)
                }
                self.error = AppLocalization.text("Serverdagi bildirishnoma sozlamasi yangilanmadi. Qayta urinib ko‘ring.")
            }
        }
        removalTask = task
        await task.value
        guard current == generation else { return }
        removalTask = nil
        synchronize()
    }
}
