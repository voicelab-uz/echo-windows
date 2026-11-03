import Foundation
import VoiceLabCore

@main
struct PushNotificationRegression {
    @MainActor static func main() async throws {
        let suite = "Echo.Push.Tests.\(UUID())"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let api = PushAPIProbe()
        let system = PushSystemProbe()
        let service = PushNotificationService(api: api, system: system, defaults: defaults)
        service.activate(accountID: "alice")
        await service.refresh()
        precondition(system.prompts == 0 && system.registrations == 0)
        print("PASS: startup never prompts for notification permission")

        await service.setEnabled(true)
        precondition(system.prompts == 1 && system.registrations > 0)
        let first = Data(repeating: 0x01, count: 32)
        service.receivedToken(first)
        try await eventually { await api.puts.count == 1 }
        service.receivedToken(first)
        await service.refresh()
        try await Task.sleep(for: .milliseconds(20))
        let initialCount = await api.puts.count
        precondition(initialCount == 1)
        print("PASS: explicit consent registers once; unchanged token is deduplicated")

        let gate = PushGate()
        await api.hold(gate)
        service.receivedToken(Data(repeating: 0x02, count: 32))
        try await eventually { await api.puts.count == 2 }
        service.receivedToken(Data(repeating: 0x03, count: 48))
        await gate.release()
        try await eventually { await api.puts.count == 3 }
        let latest = await api.puts.last!
        precondition(latest.1.token == String(repeating: "03", count: 48))
        print("PASS: rotated, variable-length APNs tokens upload in order")

        let disableGate = PushGate()
        await api.hold(disableGate)
        service.receivedToken(Data(repeating: 0x04, count: 32))
        try await eventually { await api.puts.count == 4 }
        let disabling = Task { await service.setEnabled(false) }
        try await Task.sleep(for: .milliseconds(20))
        let deletesBefore = await api.deletes.count
        precondition(deletesBefore == 0)
        await disableGate.release()
        await disabling.value
        let deletes = await api.deletes
        precondition(deletes == ["alice"] && !service.isEnabled)
        for _ in 0..<10 { await service.refresh() }
        let repeatedDeletes = await api.deletes.count
        precondition(repeatedDeletes == 1)
        print("PASS: disabling waits for pending registration, then deletes it")

        await service.setEnabled(true)
        try await eventually { await api.puts.count == 5 }
        service.deactivate()
        service.activate(accountID: "bob")
        await service.refresh()
        var opened: PushRoute?
        service.onOpen = { opened = $0 }
        let alice = PushRoute(userInfo: ["account_id":"alice", "destination":"notes"])!
        let bob = PushRoute(userInfo: ["account_id":"bob", "destination":"notes"])!
        service.open(alice)
        precondition(opened == nil && !service.canPresent(alice))
        service.open(bob)
        precondition(opened == bob && service.canPresent(bob))
        precondition(PushRoute(userInfo: ["account_id":"bob", "destination":"https://malicious.example"]) == nil)
        print("PASS: notifications cannot cross accounts or launch arbitrary URLs")

        await api.setFailure(true)
        service.receivedToken(first)
        try await eventually { await MainActor.run { service.error != nil } }
        let count = await api.puts.count
        for _ in 0..<10 { await service.refresh() }
        let afterFailure = await api.puts.count
        precondition(count == afterFailure)
        print("PASS: failed upload does not start a retry storm")

        service.deactivate()
        opened = nil
        service.open(bob)
        service.activate(accountID: "bob")
        precondition(opened == bob)
        print("PASS: cold-launch notification waits for matching session restoration")
        service.deactivate()

        let categorySuite = suite + ".categories"
        let categoryDefaults = UserDefaults(suiteName: categorySuite)!
        defer { categoryDefaults.removePersistentDomain(forName: categorySuite) }
        let categoryAPI = PushAPIProbe()
        let categorySystem = PushSystemProbe()
        let categories = PushNotificationService(api: categoryAPI, system: categorySystem, defaults: categoryDefaults)
        precondition(categories.preferences == PushPreferences(), "All categories start enabled")
        categories.activate(accountID: "alice")
        await categories.setCategory(.news, enabled: false)
        precondition(categorySystem.prompts == 0, "A category choice must not request OS permission")
        categorySystem.status = .authorized
        await categories.refresh()
        categories.receivedToken(first)
        try await eventually { await categoryAPI.puts.count == 1 }
        let firstCategoryPuts = await categoryAPI.puts
        let registration = firstCategoryPuts[0].1
        let encoded = try JSONSerialization.jsonObject(with: JSONEncoder().encode(registration)) as! [String: Any]
        precondition(encoded["topic"] as? String == "uz.voicelab.desktop")
        precondition(encoded["preferences"] as? [String: Bool] == ["important": true, "news": false],
                     "Every registration must send explicit topic and category preferences")
        let important = PushRoute(userInfo: ["account_id": "alice", "destination": "home"])!
        let news = PushRoute(userInfo: ["account_id": "alice", "destination": "home", "category": "news"])!
        precondition(important.category == .important && categories.canPresent(important) && !categories.canPresent(news))
        precondition(PushRoute(userInfo: ["account_id": "alice", "destination": "home", "category": "unknown"]) == nil)
        precondition(categorySystem.cleared.last?.0 == "alice" && categorySystem.cleared.last?.1 == .news)
        let reopenedCategories = PushNotificationService(api: categoryAPI, system: categorySystem, defaults: categoryDefaults)
        precondition(reopenedCategories.preferences == PushPreferences(important: true, news: false))

        let preferenceGate = PushGate()
        await categoryAPI.hold(preferenceGate)
        await categories.setCategory(.news, enabled: true)
        try await eventually { await categoryAPI.puts.count == 2 }
        await categories.setCategory(.important, enabled: false)
        await categories.setCategory(.news, enabled: false)
        await preferenceGate.release()
        try await eventually { await categoryAPI.puts.count == 3 }
        let finalCategoryPuts = await categoryAPI.puts
        let finalPreferences = finalCategoryPuts.last!.1.preferences
        precondition(finalPreferences == PushPreferences(important: false, news: false),
                     "Rapid edits must serialize and send the latest preferences after the in-flight PUT")
        categories.deactivate()
        categories.activate(accountID: "bob")
        precondition(categorySystem.cleared.last?.0 == "alice", "Late cleanup must target only the previous account")
        precondition(!categories.canPresent(important))
        categories.deactivate()
        print("PASS: explicit APNs topic, durable category opt-outs, legacy important fallback and serialized preference updates")
    }
    @MainActor static func eventually(_ condition: @MainActor () async -> Bool) async throws {
        for _ in 0..<200 { if await condition() { return }; try await Task.sleep(for: .milliseconds(5)) }
        fatalError("Timed out waiting for push state")
    }
}

@MainActor private final class PushSystemProbe: PushNotificationEnvironment {
    var environment: PushEnvironment? = .development
    var status: PushAuthorization = .notDetermined
    var prompts = 0
    var registrations = 0
    func authorization() async -> PushAuthorization { status }
    func requestAuthorization() async throws -> Bool { prompts += 1; status = .authorized; return true }
    func register() { registrations += 1 }
    func unregister() {}
    var cleared: [(String, PushCategory?)] = []
    func clearDelivered(accountID: String, category: PushCategory?) { cleared.append((accountID, category)) }
    func openSettings() {}
}
private actor PushGate {
    var continuation: CheckedContinuation<Void, Never>?
    var released = false
    func wait() async {
        if released { return }
        await withCheckedContinuation { continuation = $0 }
    }
    func release() { released = true; continuation?.resume(); continuation = nil }
}
private actor PushAPIProbe: PushServing {
    var puts: [(String, PushRegistration)] = []
    var deletes: [String] = []
    var gate: PushGate?
    var fail = false
    func hold(_ gate: PushGate) { self.gate = gate }
    func setFailure(_ value: Bool) { fail = value }
    func registerPush(_ registration: PushRegistration, accountID: String) async throws {
        puts.append((accountID, registration))
        let pending = gate
        gate = nil
        await pending?.wait()
        if fail { throw URLError(.notConnectedToInternet) }
    }
    func unregisterPush(accountID: String) async throws { deletes.append(accountID) }
}
