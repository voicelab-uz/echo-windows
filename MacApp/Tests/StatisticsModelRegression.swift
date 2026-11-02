import Foundation
import VoiceLabCore

@main struct StatisticsModelRegression {
    @MainActor static func main() async throws {
        let api = StatisticsProbe()
        let model = StatisticsModel(api: api)
        let record = Transcript(id: "local", text: "Salom dunyo", language: "uz", durationMS: 1000)
        await api.setFailure(true)
        await model.updateLocal([record], accountID: "alice")
        await model.refresh(accountID: "alice")
        precondition(model.remote == nil && model.localRows.first?.words == 2 && model.refreshFailed)
        print("PASS: unavailable endpoint preserves usable local statistics")
        for _ in 0..<10 { await model.refresh(accountID: "alice") }
        let attempts = await api.calls.count
        precondition(attempts == 1)
        print("PASS: repeated activation does not flood the server")

        await api.setFailure(false)
        let gate = StatisticsGate()
        await api.hold(gate)
        let oldRequest = Task { await model.refresh(accountID: "alice", force: true) }
        try await eventually { await api.calls.count == 2 }
        model.reset()
        await model.refresh(accountID: "bob")
        await gate.release(); await oldRequest.value
        precondition(model.remote?.days.first?.words == 20 && model.localRows.isEmpty)
        print("PASS: old account response cannot replace current statistics")

        await api.setFailure(true)
        await model.refresh(accountID: "bob", force: true)
        precondition(model.remote?.days.first?.words == 20 && model.refreshFailed)
        print("PASS: transient failure preserves last server snapshot")
        model.reset()
        precondition(model.remote == nil && model.localRows.isEmpty && !model.isLoading)
        print("PASS: logout clears all statistics")
    }
    @MainActor static func eventually(_ predicate: @MainActor () async -> Bool) async throws {
        for _ in 0..<200 {
            if await predicate() { return }
            try await Task.sleep(for: .milliseconds(5))
        }
        fatalError("Statistics condition timed out")
    }
}
private actor StatisticsGate {
    var continuation: CheckedContinuation<Void, Never>?
    var released = false
    func wait() async {
        if released { return }
        await withCheckedContinuation { continuation = $0 }
    }
    func release() { released = true; continuation?.resume(); continuation = nil }
}
private actor StatisticsProbe: StatisticsServing {
    var calls: [String] = []
    var fail = false
    var gate: StatisticsGate?
    func hold(_ gate: StatisticsGate) { self.gate = gate }
    func setFailure(_ value: Bool) { fail = value }
    func statistics(accountID: String, timeZone: String) async throws -> DictationStatistics {
        calls.append(accountID)
        let pending = gate; gate = nil
        await pending?.wait()
        if fail { throw URLError(.notConnectedToInternet) }
        let json: [String: Any] = [
            "days": [["day": "2026-10-21", "language": "uz", "words": accountID == "bob" ? 20 : 10, "recordings": 1, "duration_ms": 1000]],
            "from": "2026-04-23", "through": "2026-10-21", "time_zone": timeZone,
        ]
        return try HTTPClient.decode(DictationStatistics.self, data: JSONSerialization.data(withJSONObject: json))
    }
}
