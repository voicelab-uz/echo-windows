import Foundation
import VoiceLabCore

@main struct DesktopUsageSyncRegression {
    @MainActor static func main() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("Echo-Attribution-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let secrets = UsageSecrets()
        let store = LibraryStore(directory: root, secrets: secrets)
        let api = UsageProbe()
        let model = LibraryModel(store: store, usageAPI: api)
        let context = DesktopUsageContext.classify(bundleID: "com.apple.Notes", appName: "Notes")
        let record = Transcript(id: "dst_first", text: "Hello world", language: "en", durationMS: 1000)
        try await model.open(accountID: "alice")
        model.merge([record])
        await api.setFailure(URLError(.notConnectedToInternet))
        model.recordUsage(context, transcript: record, owner: "alice")
        await model.syncUsage()
        precondition(model.snapshot.pendingUsage?.count == 1)
        for _ in 0..<8 { await model.syncUsage() }
        let calls = await api.calls.count
        precondition(calls == 1)
        try await model.flush()
        let persisted = try await store.load(accountID: "alice")
        precondition(persisted.pendingUsage?.count == 1)
        print("PASS: offline usage is encrypted on disk and retry is throttled")

        model.merge([record])
        precondition(model.snapshot.transcripts.first?.usageContext == context)
        print("PASS: history refresh preserves local destination metadata")
        try await model.close()
        await api.setFailure(nil)
        try await model.open(accountID: "alice")
        await model.syncUsage()
        precondition(model.snapshot.pendingUsage?.isEmpty == true)
        let replayCalls = await api.calls.count
        precondition(replayCalls == 2)
        print("PASS: relaunch delivers the pending metadata without another transcription")

        await api.setFailure(VoiceLabError.server(status: 404, message: "Not Found", requestID: nil))
        model.recordUsage(context, transcript: record, owner: "alice")
        await model.syncUsage()
        precondition(model.snapshot.pendingUsage?.count == 1)
        print("PASS: undeployed endpoint retains pending metadata")
        try await model.close()
        await api.setFailure(VoiceLabError.server(status: 410, message: "Gone", requestID: nil))
        try await model.open(accountID: "alice")
        await model.syncUsage()
        precondition(model.snapshot.pendingUsage?.isEmpty == true)
        print("PASS: deleted server records do not block the outbox")

        await api.setFailure(nil)
        let gate = UsageGate()
        await api.hold(gate)
        model.recordUsage(context, transcript: record, owner: "alice")
        let waiting = Task { await model.syncUsage() }
        await gate.waitUntilEntered()
        try await model.open(accountID: "bob")
        await gate.release()
        await waiting.value
        precondition(model.accountID == "bob" && model.snapshot.transcripts.isEmpty && (model.snapshot.pendingUsage ?? [:]).isEmpty)
        let count = await api.calls.count
        model.recordUsage(context, transcript: record, owner: "alice")
        await model.syncUsage()
        let finalCount = await api.calls.count
        precondition(finalCount == count)
        print("PASS: late completion and stale owner cannot contaminate another account")
        try await model.close()
    }
}
private actor UsageProbe: DesktopUsageServing {
    var failure: (any Error)?
    var calls: [String] = []
    var gate: UsageGate?
    func setFailure(_ error: (any Error)?) { failure = error }
    func hold(_ gate: UsageGate) { self.gate = gate }
    func saveUsageContext(_ context: DesktopUsageContext, transcriptID: String, accountID: String) async throws {
        calls.append(accountID + ":" + transcriptID)
        let held = gate; gate = nil
        await held?.wait()
        if let failure { throw failure }
    }
}
private actor UsageGate {
    var entered = false
    var continuation: CheckedContinuation<Void, Never>?
    func wait() async { entered = true; await withCheckedContinuation { continuation = $0 } }
    func waitUntilEntered() async {
        for _ in 0..<200 { if entered { return }; try? await Task.sleep(for: .milliseconds(10)) }
        fatalError("Usage request did not start")
    }
    func release() { continuation?.resume(); continuation = nil }
}
private final class UsageSecrets: SecretStore, @unchecked Sendable {
    let lock = NSLock()
    var values: [String: Data] = [:]
    func read(_ key: String) throws -> Data? { lock.withLock { values[key] } }
    func write(_ data: Data, key: String) throws { lock.withLock { values[key] = data } }
    func remove(_ key: String) throws { _ = lock.withLock { values.removeValue(forKey: key) } }
}
