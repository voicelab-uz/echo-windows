import Foundation
import VoiceLabCore

@MainActor private final class UpdateNotificationProbe: UpdateNotificationEnvironment {
    var status: PushAuthorization = .notDetermined
    var permissionRequests = 0
    var posts: [UpdateNotification] = []
    var removed: [String] = []
    var clears = 0
    var openedSettings = 0
    var reconciliations: [(String, String)] = []
    var shouldFail = false
    var pausePost = false
    var resume: CheckedContinuation<Void, Never>?
    func authorization() async -> PushAuthorization { status }
    func requestAuthorization() async throws -> Bool { permissionRequests += 1; status = .authorized; return true }
    func post(_ update: UpdateNotification) async throws {
        posts.append(update)
        if pausePost { await withCheckedContinuation { resume = $0 } }
        if shouldFail { throw URLError(.notConnectedToInternet) }
    }
    func remove(identifiers: [String]) { removed += identifiers }
    func clearUpdates() { clears += 1 }
    func removeObsolete(channel: String, installedBuild: String) { reconciliations.append((channel, installedBuild)) }
    func openSettings() { openedSettings += 1 }
}

@MainActor private final class UpdateCenterProbe: UpdateNotificationCenter {
    var delivered: [UpdateNotification] = [UpdateNotification(channel: "stable", build: "108", version: "2.0", stage: .ready)!]
    var pauseQuery = true
    var query: CheckedContinuation<Void, Never>?
    var posts = 0
    func post(_ update: UpdateNotification) async throws { posts += 1; delivered.append(update) }
    func deliveredUpdates() async -> [UpdateNotification] {
        if pauseQuery { await withCheckedContinuation { query = $0 } }
        return delivered
    }
    func remove(identifiers: [String]) { delivered.removeAll { identifiers.contains($0.identifier) } }
}

@main struct UpdateNotificationRegression {
    @MainActor static func main() async throws {
        let suite = "Echo.UpdateNotifications.\(UUID())"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let system = UpdateNotificationProbe()
        let service = UpdateNotificationService(system: system, defaults: defaults)
        let available = UpdateNotification(channel: "stable", build: "109", version: "2.0.1", stage: .available)!
        let ready = UpdateNotification(channel: "stable", build: "109", version: "2.0.1", stage: .ready)!
        service.configure(channel: "stable", installedBuild: "108")
        var eligible = true
        service.canDeliver = { eligible }
        await service.refresh()
        await service.consider(available, userInitiated: false)
        precondition(system.permissionRequests == 0 && system.posts.isEmpty,
                     "Startup and background checks must never request permission")
        await service.requestPermission()
        precondition(system.permissionRequests == 1 && service.authorization == .authorized)
        await service.consider(available, userInitiated: true)
        eligible = false
        await service.consider(ready, userInitiated: false)
        precondition(system.posts.isEmpty, "Manual checks, foreground use and busy work must stay quiet")
        eligible = true
        await service.consider(available, userInitiated: false)
        await service.consider(ready, userInitiated: false)
        precondition(system.posts.count == 1, "Ready must not repeat an already delivered available notice")
        let reopened = UpdateNotificationService(system: system, defaults: defaults)
        reopened.configure(channel: "stable", installedBuild: "108")
        reopened.canDeliver = { true }
        await reopened.consider(ready, userInitiated: false)
        precondition(system.posts.count == 1, "Deduplication must survive relaunch")
        let testNotice = UpdateNotification(channel: "test", build: "109", version: "2.0.1", stage: .ready)!
        await reopened.consider(testNotice, userInitiated: false)
        precondition(system.posts.count == 1, "Different channels cannot leak into the current channel")
        reopened.configure(channel: "test", installedBuild: "108")
        await reopened.consider(testNotice, userInitiated: false)
        precondition(system.posts.count == 2, "Deduplication must distinguish channel and build")

        let next = UpdateNotification(channel: "stable", build: "110", version: "2.0.2", stage: .ready)!
        system.shouldFail = true
        await service.consider(next, userInitiated: false)
        system.shouldFail = false
        await service.consider(next, userInitiated: false)
        precondition(system.posts.count == 4, "Failed delivery must not consume the deduplication key")
        system.pausePost = true
        let pending = UpdateNotification(channel: "stable", build: "111", version: "2.0.3", stage: .ready)!
        let task = Task { await service.consider(pending, userInitiated: false) }
        while system.resume == nil { await Task.yield() }
        await service.consider(pending, userInitiated: false)
        precondition(system.posts.count == 5, "Concurrent callbacks must submit only once")
        service.setEnabled(false)
        system.resume?.resume(); system.resume = nil
        await task.value
        precondition(system.clears == 1 && system.removed.contains(pending.identifier),
                     "Opting out while delivery is in flight must remove the late notification")
        let disabled = UpdateNotificationService(system: system, defaults: defaults)
        precondition(!disabled.isEnabled, "Category opt-out must survive relaunch")
        system.status = .denied
        await disabled.requestPermission()
        precondition(system.permissionRequests == 1 && system.openedSettings == 1,
                     "Denied permission must open Settings without repeatedly prompting")

        system.pausePost = false
        system.status = .authorized
        service.setEnabled(true)
        let dismissed = UpdateNotification(channel: "stable", build: "112", version: "2.0.4", stage: .ready)!
        service.schedule(dismissed)
        service.clearDelivered()
        for _ in 0..<10 { await Task.yield() }
        precondition(system.posts.count == 5, "Dismissal must invalidate a queued scheduled callback")
        system.pausePost = true
        let late = Task { await service.consider(dismissed, userInitiated: false) }
        while system.resume == nil { await Task.yield() }
        service.clearDelivered()
        system.resume?.resume(); system.resume = nil
        await late.value
        precondition(system.removed.contains(dismissed.identifier), "Dismissal must remove an in-flight delivery")

        let remoteInfo: [AnyHashable: Any] = ["account_id": "alice", "destination": "settings"]
        precondition(AppNotificationRoute.resolve(identifier: available.identifier, userInfo: available.userInfo,
                                                  isRemote: false) == .update(available))
        precondition(AppNotificationRoute.resolve(identifier: available.identifier, userInfo: available.userInfo,
                                                  isRemote: true) == nil, "APNs cannot impersonate a local update")
        precondition(AppNotificationRoute.resolve(identifier: "remote", userInfo: remoteInfo, isRemote: false) == nil,
                     "Local notices cannot impersonate account-bound remote routes")
        precondition(AppNotificationRoute.resolve(identifier: "remote", userInfo: remoteInfo, isRemote: true)
                     == .remote(PushRoute(userInfo: remoteInfo)!))
        precondition(UpdateNotification(identifier: ready.identifier + "injected", userInfo: ready.userInfo) == nil)
        precondition(UpdateNotification(channel: "stable", build: "https://bad", version: "2", stage: .ready) == nil)
        var opens = 0
        let cold = UpdateNotificationService(system: system, defaults: defaults)
        cold.onOpen = { opens += 1 }
        cold.open(ready)
        precondition(opens == 0, "Cold-launch click must wait for channel configuration")
        cold.configure(channel: "stable", installedBuild: "108")
        precondition(opens == 1)
        cold.open(testNotice)
        precondition(opens == 1, "Cross-channel click must not open update UI")
        let center = UpdateCenterProbe()
        let native = NativeUpdateNotificationEnvironment(center: center)
        native.clearUpdates()
        while center.query == nil { await Task.yield() }
        let newDelivery = Task { try await native.post(next) }
        for _ in 0..<10 { await Task.yield() }
        precondition(center.posts == 0, "A new native post must wait for the pending cleanup query")
        center.query?.resume(); center.query = nil
        try await newDelivery.value
        precondition(center.delivered == [next],
                     "A late cleanup callback must never remove a newer notification")
        center.pauseQuery = false
        try await native.post(testNotice)
        native.removeObsolete(channel: "stable", installedBuild: "110")
        let future = UpdateNotification(channel: "stable", build: "113", version: "2.0.5", stage: .ready)!
        try await native.post(future)
        precondition(center.delivered == [future], "Relaunch at the target build must remove installed and other-channel notices")
        native.removeObsolete(channel: "stable", installedBuild: "112")
        try await native.post(dismissed)
        precondition(center.delivered.contains(future), "Startup reconciliation must retain a newer staged reminder")
        precondition(system.reconciliations.first?.1 == "108")
        print("PASS: native delivery and asynchronous cleanup are serialized")

        print("PASS: explicit permission, quiet delivery, persistent dedup, in-flight opt-out, transport isolation and cold-launch routing")
    }
}
