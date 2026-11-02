import AppKit

/// Event-driven: no timer runs while the Mac is asleep or locked.
@MainActor
final class SessionReturnMonitor {
    private var workspaceObservers: [NSObjectProtocol] = []
    private var distributedObservers: [NSObjectProtocol] = []
    private var pending: Task<Void, Never>?
    private var lastDelivery: TimeInterval?
    private var running = false
    private let workspace: NotificationCenter
    private let distributed: NotificationCenter
    private let isAvailable: () -> Bool
    private let uptime: () -> TimeInterval
    private let delay: Duration
    private let onReturn: () -> Void
    private let onUnavailable: () -> Void

    init(workspace: NotificationCenter = NSWorkspace.shared.notificationCenter,
         distributed: NotificationCenter = DistributedNotificationCenter.default(),
         isAvailable: @escaping () -> Bool = { SessionReturnMonitor.desktopAvailable },
         uptime: @escaping () -> TimeInterval = { ProcessInfo.processInfo.systemUptime },
         delay: Duration = .milliseconds(900),
         onReturn: @escaping () -> Void, onUnavailable: @escaping () -> Void = {}) {
        self.workspace = workspace
        self.distributed = distributed
        self.isAvailable = isAvailable
        self.uptime = uptime
        self.delay = delay
        self.onReturn = onReturn
        self.onUnavailable = onUnavailable
    }

    static var desktopAvailable: Bool {
        guard let session = CGSessionCopyCurrentDictionary() as? [String: Any] else { return false }
        // WindowServer's lock flag supplements workspace notifications, which
        // describe fast user switching rather than password unlocks.
        return session[kCGSessionOnConsoleKey as String] as? Bool == true
            && session[kCGSessionLoginDoneKey as String] as? Bool == true
            && session["CGSSessionScreenIsLocked"] as? Bool != true
    }

    func start(announceInitial: Bool = false) {
        guard !running else { return }
        running = true
        for name in [NSWorkspace.didWakeNotification, NSWorkspace.screensDidWakeNotification,
                     NSWorkspace.sessionDidBecomeActiveNotification] {
            workspaceObservers.append(workspace.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor [weak self] in self?.schedule() }
            })
        }
        for name in [NSWorkspace.willSleepNotification, NSWorkspace.screensDidSleepNotification,
                     NSWorkspace.sessionDidResignActiveNotification] {
            workspaceObservers.append(workspace.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor [weak self] in self?.unavailable() }
            })
        }
        for (name, returning) in [("com.apple.screenIsUnlocked", true), ("com.apple.screenIsLocked", false)] {
            distributedObservers.append(distributed.addObserver(forName: Notification.Name(name), object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor [weak self] in
                    if returning { self?.schedule() } else { self?.unavailable() }
                }
            })
        }
        if announceInitial { schedule() }
    }

    func stop() {
        running = false
        pending?.cancel(); pending = nil
        workspaceObservers.forEach(workspace.removeObserver)
        distributedObservers.forEach(distributed.removeObserver)
        workspaceObservers.removeAll(); distributedObservers.removeAll()
    }

    private func unavailable() {
        guard running else { return }
        pending?.cancel(); pending = nil
        // A real departure starts a new session, even if the previous unlock
        // was less than five seconds ago. Only duplicate return signals coalesce.
        lastDelivery = nil
        onUnavailable()
    }

    private func schedule() {
        guard running else { return }
        pending?.cancel()
        let delay = self.delay
        pending = Task { [weak self] in
            do { try await Task.sleep(for: delay) } catch { return }
            guard let self, self.running, self.isAvailable() else { return }
            let now = self.uptime()
            guard self.lastDelivery.map({ now - $0 >= 5 }) ?? true else { return }
            self.lastDelivery = now
            self.pending = nil
            self.onReturn()
        }
    }
}
