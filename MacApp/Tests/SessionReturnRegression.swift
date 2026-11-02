import AppKit

@main
struct SessionReturnRegression {
    @MainActor static func main() async throws {
        let workspace = NotificationCenter(), distributed = NotificationCenter()
        var available = false, clock: TimeInterval = 100
        var returns = 0, departures = 0
        let monitor = SessionReturnMonitor(workspace: workspace, distributed: distributed,
            isAvailable: { available }, uptime: { clock }, delay: .milliseconds(5),
            onReturn: { returns += 1 }, onUnavailable: { departures += 1 })
        func event(_ name: Notification.Name, distributedEvent: Bool = false) async throws {
            (distributedEvent ? distributed : workspace).post(name: name, object: nil)
            try await Task.sleep(for: .milliseconds(30))
        }
        let locked = Notification.Name("com.apple.screenIsLocked")
        let unlocked = Notification.Name("com.apple.screenIsUnlocked")
        monitor.start(); monitor.start()
        try await event(NSWorkspace.didWakeNotification)
        precondition(returns == 0, "Wake at password prompt must not greet")
        available = true
        try await event(unlocked, distributedEvent: true)
        precondition(returns == 1)
        try await event(NSWorkspace.screensDidWakeNotification)
        try await event(NSWorkspace.sessionDidBecomeActiveNotification)
        try await event(unlocked, distributedEvent: true)
        precondition(returns == 1, "Coalesce overlapping unlock and wake signals")
        // A second real lock/unlock must restore input even inside the duplicate
        // notification suppression window of the previous return.
        clock += 1
        available = false
        try await event(locked, distributedEvent: true)
        precondition(departures == 1)
        available = true
        try await event(unlocked, distributedEvent: true)
        precondition(returns == 2, "Next unlock should greet again")
        clock += 30
        distributed.post(name: unlocked, object: nil)
        workspace.post(name: NSWorkspace.willSleepNotification, object: nil)
        try await Task.sleep(for: .milliseconds(30))
        precondition(returns == 2, "Sleep cancels a pending greeting")
        monitor.stop()
        try await event(unlocked, distributedEvent: true)
        precondition(returns == 2, "Stopped monitor must remove observers")
        monitor.start()
        try await event(NSWorkspace.sessionDidBecomeActiveNotification)
        precondition(returns == 3)
        monitor.stop()
        print("PASS: locked wake, unlock, duplicate events, subsequent unlock, cancellation and observer cleanup")
    }
}
