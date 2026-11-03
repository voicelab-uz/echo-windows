import Foundation

// Replace only the system boundaries. The script compiles the actual shared
// attributes and production controller; no lifecycle logic is copied here.
protocol ActivityAttributes { associatedtype ContentState: Codable & Hashable }
struct ActivityContent<State> { let state: State; let staleDate: Date? }
enum ActivityState { case active, stale, ended, dismissed }
enum ActivityUIDismissalPolicy { case immediate }
@MainActor struct ActivityAuthorizationInfo { var areActivitiesEnabled: Bool { true } }
@MainActor enum ActivityRuntime {
    static var all: [Any] = []
    static var requests = 0
    static var failNextRequest = false
    static var updates: [Date] = []
    static var ends = 0
    static var suspendEnds = false
    static var suspendedEnds: [CheckedContinuation<Void, Never>] = []
    static var suspendUpdates = false
    static var suspended: [CheckedContinuation<Void, Never>] = []
    static func resumeUpdates() {
        suspendUpdates = false
        let continuations = suspended
        suspended.removeAll()
        for continuation in continuations { continuation.resume() }
    }
}
@MainActor final class Activity<Attributes: ActivityAttributes> {
    let id = UUID().uuidString
    let attributes: Attributes
    var activityState = ActivityState.active
    init(attributes: Attributes) { self.attributes = attributes }
    static var activities: [Activity<Attributes>] {
        ActivityRuntime.all.compactMap { $0 as? Activity<Attributes> }.filter { $0.activityState != .ended }
    }
    static func request(attributes: Attributes, content: ActivityContent<Attributes.ContentState>, pushType: Int?) throws -> Activity<Attributes> {
        ActivityRuntime.requests += 1
        if ActivityRuntime.failNextRequest {
            ActivityRuntime.failNextRequest = false
            throw NSError(domain: "fixture.ActivityKit", code: 1)
        }
        let activity = Activity(attributes: attributes)
        ActivityRuntime.all.append(activity)
        return activity
    }
    func update(_ content: ActivityContent<Attributes.ContentState>) async {
        ActivityRuntime.updates.append(.now)
        if ActivityRuntime.suspendUpdates {
            await withCheckedContinuation { ActivityRuntime.suspended.append($0) }
        }
    }
    func end(_ content: ActivityContent<Attributes.ContentState>?, dismissalPolicy: ActivityUIDismissalPolicy) async {
        // Expose another suspension boundary for old/new session ordering.
        if ActivityRuntime.suspendEnds {
            await withCheckedContinuation { ActivityRuntime.suspendedEnds.append($0) }
        } else { await Task.yield() }
        activityState = .ended
        ActivityRuntime.ends += 1
    }
}
@MainActor final class UIApplication {
    static let shared = UIApplication()
    enum State { case active, background }
    var applicationState = State.active
}
enum VoiceBridge {
    enum Phase: String { case off, ready, starting, recording, transcribing }
    struct Snapshot { var sessionID: String?; var phase: Phase = .off; var level: Float = 0 }
}

@main struct EchoLiveActivityControllerRegression {
    @MainActor static func wait(_ milliseconds: Int) async {
        try? await Task.sleep(for: .milliseconds(milliseconds))
    }
    @MainActor static func main() async {
        let controller = EchoLiveActivityController.shared
        controller.synchronize(snapshot: .init(), keepsReady: false, canStartActivity: false)
        await wait(40)
        precondition(ActivityRuntime.requests == 0, "App launch requested an activity")
        UIApplication.shared.applicationState = .background
        controller.synchronize(snapshot: .init(sessionID: "background", phase: .recording), keepsReady: true, canStartActivity: true)
        await wait(40)
        precondition(ActivityRuntime.requests == 0, "Even an authorization hint must not create while backgrounded")
        UIApplication.shared.applicationState = .active
        controller.synchronize(snapshot: .init(sessionID: "first", phase: .recording), keepsReady: true, canStartActivity: false)
        await wait(40)
        precondition(ActivityRuntime.requests == 0, "Foreground heartbeat created without explicit Start")
        controller.beginForegroundSession(snapshot: .init(sessionID: "first", phase: .starting), keepsReady: true)
        controller.synchronize(snapshot: .init(), keepsReady: false, canStartActivity: false)
        controller.synchronize(snapshot: .init(sessionID: "obsolete", phase: .off), keepsReady: false, canStartActivity: false)
        precondition(Activity<EchoLiveActivityAttributes>.activities.count == 1,
                     "Queued nil/off snapshots ended the new foreground activity")
        // The user returns immediately, before the worker or audio setup can run.
        precondition(ActivityRuntime.requests == 1 && Activity<EchoLiveActivityAttributes>.activities.count == 1,
                     "Foreground request was deferred across the quick-return window")
        UIApplication.shared.applicationState = .background
        controller.synchronize(snapshot: .init(sessionID: "first", phase: .recording), keepsReady: true, canStartActivity: false)
        await wait(40)
        precondition(Activity<EchoLiveActivityAttributes>.activities.count == 1,
                     "Orphan cleanup ended the synchronously created activity")
        let phaseUpdates = ActivityRuntime.updates.count

        for level in 1...20 {
            controller.synchronize(snapshot: .init(sessionID: "first", phase: .recording, level: Float(level) / 20), keepsReady: true, canStartActivity: false)
        }
        await wait(1100)
        precondition(ActivityRuntime.updates.count == phaseUpdates + 1, "Audio cadence was not coalesced into one update")
        for level in (0...19).reversed() {
            controller.synchronize(snapshot: .init(sessionID: "first", phase: .recording, level: Float(level) / 20), keepsReady: true, canStartActivity: false)
        }
        await wait(1100)
        precondition(ActivityRuntime.updates.count == phaseUpdates + 2)
        precondition(ActivityRuntime.updates[phaseUpdates + 1].timeIntervalSince(ActivityRuntime.updates[phaseUpdates]) >= 0.99,
                     "Level-only ActivityKit updates exceeded 1Hz")

        controller.end(sessionID: "first")
        UIApplication.shared.applicationState = .background
        controller.synchronize(snapshot: .init(sessionID: "stale", phase: .recording), keepsReady: true, canStartActivity: false)
        await wait(60)
        precondition(ActivityRuntime.requests == 1 && ActivityRuntime.ends == 1,
                     "Off followed by an old background update resurrected the activity")
        precondition(Activity<EchoLiveActivityAttributes>.activities.isEmpty)

        UIApplication.shared.applicationState = .active
        controller.synchronize(snapshot: .init(sessionID: "new", phase: .ready), keepsReady: true, canStartActivity: true)
        await wait(40)
        precondition(ActivityRuntime.requests == 2)
        NotificationCenter.default.post(name: .echoLiveActivityEndRequested, object: "first")
        await wait(40)
        precondition(ActivityRuntime.ends == 1 && Activity<EchoLiveActivityAttributes>.activities.count == 1,
                     "A stale typed End controlled the newer session")

        // Hold a real controller update across suspension, then end the session.
        // Completing the older await must not restore that activity afterwards.
        ActivityRuntime.suspendUpdates = true
        controller.synchronize(snapshot: .init(sessionID: "new", phase: .recording), keepsReady: true, canStartActivity: false)
        for _ in 0..<100 where ActivityRuntime.suspended.isEmpty { await wait(2) }
        precondition(!ActivityRuntime.suspended.isEmpty, "Fixture never reached the asynchronous update")
        controller.end(sessionID: "new")
        ActivityRuntime.resumeUpdates()
        await wait(60)
        precondition(ActivityRuntime.requests == 2 && ActivityRuntime.ends == 2)
        precondition(Activity<EchoLiveActivityAttributes>.activities.isEmpty, "An update completed after End and revived the activity")
        UIApplication.shared.applicationState = .background
        controller.synchronize(snapshot: .init(sessionID: "new", phase: .ready), keepsReady: true, canStartActivity: false)
        await wait(40)
        precondition(ActivityRuntime.requests == 2)

        UIApplication.shared.applicationState = .active
        controller.synchronize(snapshot: .init(sessionID: "last", phase: .ready), keepsReady: true, canStartActivity: true)
        await wait(40)
        NotificationCenter.default.post(name: .echoLiveActivityEndRequested, object: "last")
        await wait(60)
        precondition(ActivityRuntime.requests == 3 && ActivityRuntime.ends == 3)
        precondition(Activity<EchoLiveActivityAttributes>.activities.isEmpty)
        controller.beginForegroundSession(snapshot: .init(sessionID: "replace-old", phase: .starting), keepsReady: true)
        ActivityRuntime.suspendEnds = true
        controller.end(sessionID: "replace-old")
        for _ in 0..<100 where ActivityRuntime.suspendedEnds.isEmpty { await wait(2) }
        precondition(!ActivityRuntime.suspendedEnds.isEmpty)
        controller.beginForegroundSession(snapshot: .init(sessionID: "replace-new", phase: .starting), keepsReady: true)
        controller.end(sessionID: "replace-old")
        controller.synchronize(snapshot: .init(), keepsReady: false, canStartActivity: false)
        controller.synchronize(snapshot: .init(sessionID: "replace-old", phase: .ready), keepsReady: true, canStartActivity: false)
        precondition(ActivityRuntime.requests == 5, "New foreground request waited for old async cleanup")
        ActivityRuntime.suspendEnds = false
        let oldEnds = ActivityRuntime.suspendedEnds
        ActivityRuntime.suspendedEnds.removeAll()
        for continuation in oldEnds { continuation.resume() }
        await wait(60)
        precondition(Activity<EchoLiveActivityAttributes>.activities.count == 1)
        precondition(Activity<EchoLiveActivityAttributes>.activities.first?.attributes.sessionID == "replace-new",
                     "Old cleanup ended the new foreground activity")
        controller.end(sessionID: "replace-new")
        await wait(40)
        precondition(Activity<EchoLiveActivityAttributes>.activities.isEmpty)
        controller.beginForegroundSession(snapshot: .init(sessionID: "failure-old", phase: .starting), keepsReady: true)
        await wait(40)
        ActivityRuntime.failNextRequest = true
        controller.beginForegroundSession(snapshot: .init(sessionID: "failure-new", phase: .starting), keepsReady: true)
        await wait(60)
        precondition(Activity<EchoLiveActivityAttributes>.activities.isEmpty,
                     "Failed replacement request left the previous session panel alive")
        let attemptsAfterFailure = ActivityRuntime.requests
        UIApplication.shared.applicationState = .background
        controller.synchronize(snapshot: .init(sessionID: "failure-new", phase: .recording), keepsReady: true, canStartActivity: false)
        await wait(40)
        precondition(ActivityRuntime.requests == attemptsAfterFailure, "Failed activity re-requested itself in background")
        controller.end(sessionID: "failure-new")
        print("Live Activity controller regression passed: foreground creation, transient/off isolation, 1Hz coalescing, scoped End, failed replacement cleanup and no async resurrection")
    }
}
