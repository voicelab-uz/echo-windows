// ActivityKit's Activity reference has no Sendable annotation in the current
// SDK. The MainActor worker below owns and serializes every use of that reference.
@preconcurrency import ActivityKit
import Foundation
import UIKit

/// Mirrors the existing audio host. It never requests microphone permissions,
/// records audio, or starts an activity after a background-only state update.
@MainActor
final class EchoLiveActivityController {
    static let shared = EchoLiveActivityController()
    private typealias EchoActivity = Activity<EchoLiveActivityAttributes>
    private struct Desired: Equatable {
        let sessionID: String
        let state: EchoLiveActivityAttributes.ContentState
    }
    private var activity: EchoActivity?
    private var authorizedSessionID: String?
    private var pendingEnds: [EchoActivity] = []
    private var desired: Desired?
    private var worker: Task<Void, Never>?
    private var revision = 0
    private var creationAuthorized = false
    private var recordingStartedAt: Date?
    private var lastSent: Desired?
    private var lastSentAt = Date.distantPast
    private var didCleanOrphans = false
    private var endObserver: NSObjectProtocol?
    #if DEBUG
    private var lastSyncDiagnostic: String?
    private var lastDiagnostic: String?
    #endif

    private init() {
        endObserver = NotificationCenter.default.addObserver(forName: .echoLiveActivityEndRequested, object: nil, queue: .main) { [weak self] notification in
            let sessionID = notification.object as? String
            Task { @MainActor [weak self] in
                guard let self, let sessionID else { return }
                self.end(sessionID: sessionID)
            }
        }
    }

    /// Called once by the installed app-lifetime host, never by an initializer.
    /// An already authorized live host takes precedence over startup cleanup.
    @discardableResult
    func cleanupStaleActivitiesAtLaunch() -> Bool {
        guard authorizedSessionID == nil, activity == nil, desired == nil, !didCleanOrphans else { return false }
        didCleanOrphans = true
        pendingEnds.append(contentsOf: EchoActivity.activities)
        if !pendingEnds.isEmpty { schedule() }
        return true
    }

    /// Request inline during the foreground Start, before audio actor awaits.
    func beginForegroundSession(snapshot: VoiceBridge.Snapshot, keepsReady: Bool) {
        guard UIApplication.shared.applicationState == .active,
              let sessionID = snapshot.sessionID, !sessionID.isEmpty,
              makeDesired(snapshot: snapshot, keepsReady: keepsReady) != nil else {
            recordDiagnostic("foreground_request_skipped", state: snapshot.phase.rawValue, canStart: true,
                             hasSession: snapshot.sessionID != nil)
            return
        }
        authorizedSessionID = sessionID
        accept(snapshot: snapshot, keepsReady: keepsReady)
        guard let target = desired else { return }
        if let current = activity, current.attributes.sessionID == sessionID,
           current.activityState == .active || current.activityState == .stale { return }
        // Detach A before requesting B, including when B is refused. A's panel
        // must not survive under B's ownership after a failed SDK request.
        if let previous = activity {
            pendingEnds.append(previous); activity = nil; lastSent = nil
            revision += 1; schedule()
        }
        guard ActivityAuthorizationInfo().areActivitiesEnabled else { return }
        creationAuthorized = true
        defer { creationAuthorized = false }
        recordDiagnostic("request_attempt", state: target.state.phase.rawValue)
        do {
            let newActivity = try EchoActivity.request(attributes: .init(sessionID: sessionID),
                content: ActivityContent(state: target.state, staleDate: .now.addingTimeInterval(45)), pushType: nil)
            if let previous = activity, previous.id != newActivity.id { pendingEnds.append(previous) }
            activity = newActivity
            lastSent = target; lastSentAt = .now
            didCleanOrphans = false
            revision += 1
            recordDiagnostic("request_success", state: target.state.phase.rawValue)
            schedule()
        } catch {
            recordDiagnostic("request_failure", state: target.state.phase.rawValue, error: error)
        }
    }

    /// Passive snapshots can update only the session explicitly authorized above.
    /// In particular nil/off from a transient SwiftUI host is never an end command.
    func synchronize(snapshot: VoiceBridge.Snapshot, keepsReady: Bool, canStartActivity: Bool) {
        if canStartActivity { beginForegroundSession(snapshot: snapshot, keepsReady: keepsReady); return }
        guard let sessionID = snapshot.sessionID, sessionID == authorizedSessionID,
              makeDesired(snapshot: snapshot, keepsReady: keepsReady) != nil else {
            recordDiagnostic("ignored_nonowner_snapshot", state: snapshot.phase.rawValue,
                             canStart: false, hasSession: snapshot.sessionID != nil)
            return
        }
        accept(snapshot: snapshot, keepsReady: keepsReady)
        guard let target = desired, activity != nil else { return }
        if target == lastSent, Date.now.timeIntervalSince(lastSentAt) < 30 { return }
        schedule()
    }

    private func makeDesired(snapshot: VoiceBridge.Snapshot, keepsReady: Bool) -> Desired? {
        let visible = snapshot.phase == .recording || snapshot.phase == .transcribing
            || snapshot.phase == .starting || snapshot.phase == .ready && keepsReady
        guard visible, let sessionID = snapshot.sessionID, !sessionID.isEmpty,
              let phase = EchoLiveActivityAttributes.ContentState.Phase(rawValue: snapshot.phase.rawValue) else { return nil }
        let start: Date? = snapshot.phase == .recording
            ? (desired?.sessionID == sessionID && desired?.state.phase == .recording ? recordingStartedAt : .now) : nil
        let measured = snapshot.level.isFinite ? min(1, max(0, Double(snapshot.level))) : 0
        return Desired(sessionID: sessionID, state: .init(phase: phase, recordingStartedAt: start,
            audioLevel: snapshot.phase == .recording ? (measured * 10).rounded() / 10 : 0,
            languageCode: UserDefaults.standard.string(forKey: "echo.app.language") ?? "uz"))
    }

    private func accept(snapshot: VoiceBridge.Snapshot, keepsReady: Bool) {
        guard let next = makeDesired(snapshot: snapshot, keepsReady: keepsReady) else { return }
        #if DEBUG
        let signature = [snapshot.phase.rawValue, diagnosticAppState, String(activity != nil)].joined(separator: "|")
        if signature != lastSyncDiagnostic {
            lastSyncDiagnostic = signature
            recordDiagnostic("sync", state: snapshot.phase.rawValue, canStart: false, hasSession: true)
        }
        #endif
        recordingStartedAt = next.state.recordingStartedAt
        if next != desired { desired = next; revision += 1 }
    }

    /// Only the captured owner session may end its activity. A delayed end for A
    /// cannot clear B, even when both sessions use the same app host instance.
    func end(sessionID: String) {
        guard authorizedSessionID == sessionID || activity?.attributes.sessionID == sessionID else {
            recordDiagnostic("ignored_stale_end", state: "off")
            return
        }
        if let current = activity, current.attributes.sessionID == sessionID {
            pendingEnds.append(current); activity = nil
        }
        if desired?.sessionID == sessionID { desired = nil; recordingStartedAt = nil }
        if authorizedSessionID == sessionID { authorizedSessionID = nil }
        if lastSent?.sessionID == sessionID { lastSent = nil }
        creationAuthorized = false
        revision += 1
        recordDiagnostic("end_scheduled", state: "off")
        schedule()
    }

    private func schedule() {
        guard worker == nil else { return }
        worker = Task { [weak self] in
            await self?.reconcile()
            self?.worker = nil
        }
    }

    /// End captured references only, never enumerate-and-end every activity in
    /// response to an off snapshot. Recheck ownership after every suspension.
    private func reconcile() async {
        while !Task.isCancelled {
            let version = revision
            let endings = pendingEnds
            pendingEnds.removeAll()
            for ending in endings where ending.id != activity?.id {
                await ending.end(nil, dismissalPolicy: .immediate)
                recordDiagnostic("ended", state: "off")
            }
            if version != revision { continue }
            guard let target = desired, target.sessionID == authorizedSessionID else { return }
            if !didCleanOrphans {
                let retained = activity
                let orphans = EchoActivity.activities.filter { candidate in candidate.id != retained?.id && !endings.contains(where: { $0.id == candidate.id }) }
                for orphan in orphans {
                    guard orphan.id != activity?.id else { continue }
                    await orphan.end(nil, dismissalPolicy: .immediate)
                    if version != revision { break }
                }
                if version != revision { continue }
                didCleanOrphans = true
            }
            guard let current = activity, current.attributes.sessionID == target.sessionID else { return }
            if current.activityState == .ended || current.activityState == .dismissed {
                activity = nil; lastSent = nil
                return
            }
            let phaseChanged = lastSent?.sessionID != target.sessionID || lastSent?.state.phase != target.state.phase
            let elapsed = Date.now.timeIntervalSince(lastSentAt)
            if target == lastSent && elapsed < 30 { return }
            if !phaseChanged && elapsed < 1 {
                try? await Task.sleep(for: .seconds(max(0, 1 - elapsed)))
                continue
            }
            await current.update(ActivityContent(state: target.state, staleDate: .now.addingTimeInterval(45)))
            guard version == revision, activity === current else { continue }
            lastSent = target; lastSentAt = .now
            if phaseChanged { recordDiagnostic("phase_updated", state: target.state.phase.rawValue) }
            if version == revision && pendingEnds.isEmpty { return }
        }
    }

    #if DEBUG
    /// Read-only launch-flag probe. It never creates an activity or starts audio.
    func diagnoseLiveActivity() {
        let hasExtension = Bundle.main.builtInPlugInsURL.flatMap {
            try? FileManager.default.contentsOfDirectory(at: $0, includingPropertiesForKeys: nil)
        }?.contains(where: { url in
            guard url.pathExtension == "appex", let bundle = Bundle(url: url),
                  let metadata = bundle.object(forInfoDictionaryKey: "NSExtension") as? [String: Any] else { return false }
            return metadata["NSExtensionPointIdentifier"] as? String == "com.apple.widgetkit-extension"
        }) ?? false
        recordDiagnostic("probe", state: desired?.state.phase.rawValue ?? "off",
                         extra: ["widgetExtensionPresent": String(hasExtension),
                                 "supportsLiveActivities": String(Bundle.main.object(forInfoDictionaryKey: "NSSupportsLiveActivities") as? Bool == true)])
    }

    private var diagnosticAppState: String {
        switch UIApplication.shared.applicationState {
        case .active: "active"
        case .background: "background"
        default: "inactive"
        }
    }
    #endif

    private func recordDiagnostic(_ phase: String, state: String, canStart: Bool? = nil,
                                  hasSession: Bool? = nil, error: Error? = nil,
                                  extra: [String: String] = [:]) {
        #if DEBUG
        var event = ["phase": phase, "state": state,
                     "areActivitiesEnabled": String(ActivityAuthorizationInfo().areActivitiesEnabled),
                     "appState": diagnosticAppState,
                     "hasSession": String(hasSession ?? (desired != nil)),
                     "creationAuthorized": String(creationAuthorized),
                     "activityCount": String(EchoActivity.activities.count)]
        if let canStart { event["canStartActivity"] = String(canStart) }
        if let current = activity {
            switch current.activityState {
            case .active: event["activityState"] = "active"
            case .stale: event["activityState"] = "stale"
            case .ended: event["activityState"] = "ended"
            case .dismissed: event["activityState"] = "dismissed"
            default: event["activityState"] = "other"
            }
        }
        if let error {
            let failure = error as NSError
            if failure.domain.count <= 96,
               failure.domain.unicodeScalars.allSatisfy({ CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789_.-").contains($0) }) {
                event["errorDomain"] = failure.domain
            }
            event["errorCode"] = String(failure.code)
        }
        for (key, value) in extra { event[key] = value }
        let signature = event.keys.sorted().map { $0 + "=" + (event[$0] ?? "") }.joined(separator: "|")
        guard signature != lastDiagnostic else { return }
        lastDiagnostic = signature
        let version = ProcessInfo.processInfo.operatingSystemVersion
        event["osVersion"] = "\(version.majorVersion).\(version.minorVersion).\(version.patchVersion)"
        event["timestamp"] = ISO8601DateFormatter().string(from: .now)
        guard let directory = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first else { return }
        let url = directory.appendingPathComponent("echo-live-activity-diagnostics.json")
        var events = [[String: String]]()
        if let size = try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize, size <= 32_768,
           let data = try? Data(contentsOf: url), let existing = try? JSONDecoder().decode([[String: String]].self, from: data) {
            events = Array(existing.suffix(39))
        }
        events.append(event)
        guard let data = try? JSONEncoder().encode(events), data.count <= 32_768 else { return }
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try? data.write(to: url, options: .atomic)
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        #endif
    }

}
