import Foundation
import notify
import os

/// Contract between the VoiceInput app, which owns the microphone, and the VoiceKeyboard
/// extension, which iOS never lets record. State lives in the shared App Group defaults;
/// Darwin notifications only say "something changed, re-read it".
///
/// Flow: keyboard mic → (no live session) open `voicelab-echo://dictate` → app opens the mic
/// in the background and starts listening → user returns to the other app → keyboard sends
/// `stop` → app writes the transcript → keyboard inserts it once and acknowledges it.
enum VoiceBridge {
    static let appGroup = "group.uz.voicelab.echo.shared"
    static let dictateURLString = "voicelab-echo://dictate"
    /// Opens the app's explicit keyboard-session activation flow without recording.
    static let readySessionURLString = "voicelab-echo://dictate?session=ready"
    static let urlScheme = "voicelab-echo"

    static let commandNotification = "uz.voicelab.echo.command"
    static let stateNotification = "uz.voicelab.echo.state"

    /// The app refreshes its heartbeat this often while it holds the mic.
    static let heartbeatInterval: Duration = .seconds(2)
    /// A heartbeat older than this means the app was suspended or ended the session.
    static let staleAfter: TimeInterval = 6
    static let sessionIdleTimeout: TimeInterval = 5 * 60
    /// Transcripts the keyboard did not pick up in time are dropped, so text never lands in
    /// an app the user switched to later.
    static let transcriptLifetime: TimeInterval = 60

    enum Action: String, Codable, Sendable {
        case start, stop, cancel, endSession
    }

    enum MicrophoneMode: String, CaseIterable, Sendable {
        case readySession, recordingOnly
    }

    /// A visible keyboard or foreground app keeps an already activated session ready.
    /// This never activates the microphone by itself.
    static func shouldEndKeyboardSession(lastActivity: Date, now: Date = .now,
                                         appIsActive: Bool, keyboardIsVisible: Bool) -> Bool {
        !appIsActive && !keyboardIsVisible
            && now.timeIntervalSince(lastActivity) >= sessionIdleTimeout
    }

    /// Commands carry an increasing id so each one runs once, even if a notification repeats.
    struct Command: Codable, Sendable, Equatable {
        let id: Int
        let action: Action
    }

    enum Phase: String, Codable, Sendable {
        case off, ready, starting, recording, transcribing
    }

    enum Failure: String, Codable, Sendable {
        case permissionDenied, unavailable, offline, noCredits, noSpeech, recognitionFailed
    }

    struct Transcript: Codable, Sendable, Equatable {
        let id: Int
        let text: String
        let createdAt: Date
    }

    struct Snapshot: Codable, Sendable, Equatable {
        var phase: Phase = .off
        var sessionID: String?
        var level: Float = 0
        var heartbeat: Date = .distantPast
        var transcript: Transcript?
        var failure: Failure?

        func isAlive(at now: Date = .now) -> Bool {
            phase != .off && now.timeIntervalSince(heartbeat) < VoiceBridge.staleAfter
        }
    }

    static func post(_ name: String) {
        notify_post(name)
    }
}

extension VoiceBridge {
    /// Typed access to the shared App Group defaults. Nil when the App Group is unavailable
    /// (missing entitlement, or a keyboard without Full Access).
    struct Store: @unchecked Sendable {
        // UserDefaults is thread-safe; it is not annotated Sendable on every SDK.
        private let defaults: UserDefaults

        private static let snapshotKey = "bridge.snapshot"
        private static let commandKey = "bridge.command"
        private static let ackKey = "bridge.ack"
        private static let microphoneModeKey = "bridge.microphoneMode"
        private static let keyboardVisibilityKey = "bridge.keyboardVisibleAt"

        init?() {
            guard let defaults = UserDefaults(suiteName: VoiceBridge.appGroup) else { return nil }
            self.defaults = defaults
        }

        func snapshot() -> Snapshot {
            decode(Snapshot.self, forKey: Self.snapshotKey) ?? Snapshot()
        }

        func write(_ snapshot: Snapshot) {
            encode(snapshot, forKey: Self.snapshotKey)
        }

        func command() -> Command? {
            decode(Command.self, forKey: Self.commandKey)
        }

        func send(_ action: Action) {
            let next = Command(id: (command()?.id ?? 0) + 1, action: action)
            encode(next, forKey: Self.commandKey)
            VoiceBridge.post(VoiceBridge.commandNotification)
        }

        /// A preference, not an active session: recording still requires a Start tap.
        var microphoneMode: MicrophoneMode {
            get {
                guard let raw = defaults.string(forKey: Self.microphoneModeKey) else { return .readySession }
                return MicrophoneMode(rawValue: raw) ?? .recordingOnly
            }
            nonmutating set { defaults.set(newValue.rawValue, forKey: Self.microphoneModeKey) }
        }

        /// The lease expires if iOS kills the extension without a disappearance callback.
        func setKeyboardVisible(_ visible: Bool, at now: Date = .now) {
            if visible { defaults.set(now.timeIntervalSince1970, forKey: Self.keyboardVisibilityKey) }
            else { defaults.removeObject(forKey: Self.keyboardVisibilityKey) }
        }

        func keyboardIsVisible(at now: Date = .now) -> Bool {
            let elapsed = now.timeIntervalSince1970 - defaults.double(forKey: Self.keyboardVisibilityKey)
            return elapsed >= 0 && elapsed < VoiceBridge.staleAfter
        }

        /// Highest transcript id the keyboard has inserted.
        var acknowledgedTranscriptID: Int {
            get { defaults.integer(forKey: Self.ackKey) }
            nonmutating set { defaults.set(newValue, forKey: Self.ackKey) }
        }

        private func decode<Value: Decodable>(_ type: Value.Type, forKey key: String) -> Value? {
            guard let data = defaults.data(forKey: key) else { return nil }
            do {
                return try JSONDecoder().decode(type, from: data)
            } catch {
                bridgeLogger.error("Bridge decode failed for \(key, privacy: .public)")
                return nil
            }
        }

        private func encode(_ value: some Encodable, forKey key: String) {
            do {
                defaults.set(try JSONEncoder().encode(value), forKey: key)
            } catch {
                bridgeLogger.error("Bridge encode failed for \(key, privacy: .public)")
            }
        }
    }

    /// Calls `handler` on the main actor whenever the Darwin notification `name` is posted.
    final class Observer {
        private var token: Int32 = NOTIFY_TOKEN_INVALID

        init(name: String, handler: @escaping @MainActor () -> Void) {
            notify_register_dispatch(name, &token, DispatchQueue.main) { _ in
                MainActor.assumeIsolated { handler() }
            }
        }

        deinit {
            notify_cancel(token)
        }
    }
}

private let bridgeLogger = Logger(subsystem: "uz.voicelab.echo", category: "bridge")
