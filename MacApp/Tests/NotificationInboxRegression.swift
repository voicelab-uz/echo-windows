import Foundation
import VoiceLabCore

@main struct NotificationInboxRegression {
    @MainActor static func main() async throws {
        let api = InboxProbe()
        let model = NotificationInboxModel(api: api)
        let oldGate = InboxGate()
        await api.hold(oldGate)
        model.activate(accountID: "alice")
        try await eventually { await api.calls.count == 1 }
        model.deactivate()
        model.activate(accountID: "bob")
        try await eventually { model.items.first?.title == "bob" }
        await oldGate.release()
        try await Task.sleep(for: .milliseconds(10))
        precondition(model.items.count == 1 && model.items[0].title == "bob")
        print("PASS: late inbox response cannot cross accounts")

        var route: PushRoute?
        model.onOpen = { route = $0 }
        model.open(model.items[0])
        try await eventually { await api.reads.count == 1 }
        try await eventually { !model.isMarkingRead }
        precondition(route?.accountID == "bob" && route?.destination == .notes)
        let firstRead = await api.reads[0]
        precondition(firstRead.0 == "bob" && firstRead.1 != nil && firstRead.2 == nil)
        print("PASS: notification opens allowlisted destination and marks only its account")

        await model.markRead()
        let lastRead = await api.reads.last!
        precondition(lastRead.0 == "bob" && lastRead.1 == nil && lastRead.2 == "10")
        print("PASS: mark-all uses server snapshot watermark")

        let readGate = InboxGate()
        await api.holdRead(readGate)
        let oldReadCount = await api.reads.count
        let readOne = Task { await model.markRead(id: "11111111-1111-4111-8111-111111111111") }
        try await eventually { await api.reads.count == oldReadCount + 1 }
        let readTwo = Task { await model.markRead(id: "22222222-2222-4222-8222-222222222222") }
        await readGate.release()
        await readOne.value; await readTwo.value
        let newReadCount = await api.reads.count
        precondition(newReadCount == oldReadCount + 2)
        print("PASS: consecutive message clicks serialize without losing read updates")

        let gate = InboxGate()
        await api.hold(gate)
        let baseline = await api.calls.count
        let first = Task { await model.refresh(force: true) }
        try await eventually { await api.calls.count == baseline + 1 }
        let second = Task { await model.refresh(force: true) }
        let third = Task { await model.refresh(force: true) }
        try await Task.sleep(for: .milliseconds(10))
        let activeCalls = await api.calls.count
        precondition(activeCalls == baseline + 1)
        await gate.release()
        await first.value; await second.value; await third.value
        let callsAfter = await api.calls.count
        precondition(callsAfter == baseline + 2)
        print("PASS: repeated pushes coalesce with one follow-up refresh")

        let pageGate = InboxGate()
        await api.hold(pageGate)
        let paging = Task { await model.loadMore() }
        try await eventually { await api.calls.last?.1 == "9" }
        let beforeRefresh = await api.calls.count
        let refreshing = Task { await model.refresh(force: true) }
        try await Task.sleep(for: .milliseconds(10))
        let duringPaging = await api.calls.count
        precondition(beforeRefresh == duringPaging)
        await pageGate.release()
        await paging.value; await refreshing.value
        precondition(model.items.count == 1 && model.nextCursor == "9")
        print("PASS: pagination and refresh serialize; new snapshot cannot skip unseen pages")

        model.deactivate()
        precondition(model.items.isEmpty && model.unread == 0 && !model.isLoading)
        await model.refresh(force: true)
        let afterLogout = await api.calls.count
        precondition(afterLogout == beforeRefresh + 1)
        print("PASS: logout clears inbox and stops account requests")
    }
    @MainActor static func eventually(_ predicate: @MainActor () async -> Bool) async throws {
        for _ in 0..<200 {
            if await predicate() { return }
            try await Task.sleep(for: .milliseconds(5))
        }
        fatalError("Inbox condition timed out")
    }
}

private actor InboxGate {
    var continuation: CheckedContinuation<Void, Never>?
    var released = false
    func wait() async {
        if released { return }
        await withCheckedContinuation { continuation = $0 }
    }
    func release() { released = true; continuation?.resume(); continuation = nil }
}
private actor InboxProbe: NotificationInboxServing {
    var calls: [(String, String)] = []
    var reads: [(String, String?, String?)] = []
    var gate: InboxGate?
    var readGate: InboxGate?
    func holdRead(_ gate: InboxGate) { readGate = gate }
    func hold(_ gate: InboxGate) { self.gate = gate }
    func notifications(cursor: String, accountID: String) async throws -> NotificationInboxPage {
        calls.append((accountID, cursor))
        let pending = gate; gate = nil
        await pending?.wait()
        let id = cursor.isEmpty ? "11111111-1111-4111-8111-111111111111" : "22222222-2222-4222-8222-222222222222"
        let json: [String: Any] = [
            "items": [["id": id, "title": accountID, "body": "News", "destination": "notes", "created_at": "2026-10-21T10:00:00Z", "read": false]],
            "next_cursor": cursor.isEmpty ? "9" : "", "through_cursor": "10", "unread": 1,
        ]
        return try HTTPClient.decode(NotificationInboxPage.self, data: JSONSerialization.data(withJSONObject: json))
    }
    func readNotification(id: String?, throughCursor: String?, accountID: String) async throws {
        reads.append((accountID, id, throughCursor))
        let pending = readGate; readGate = nil
        await pending?.wait()
    }
}
