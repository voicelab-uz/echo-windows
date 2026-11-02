import Foundation
import OSLog
import Security
import VoiceLabCore

/// A one-shot developer reset runs after the application can show its window.
/// Blocking Keychain and cache work is isolated from the main actor. No cloud data changes.
@MainActor
enum LocalInstallationReset {
    private(set) static var didResetInThisProcess = false
    fileprivate nonisolated static let replayKey = "Echo.onboarding.replayPending"
    fileprivate nonisolated static var replayMarker: URL {
        URL.applicationSupportDirectory.appendingPathComponent("Echo.onboarding-replay-pending")
    }
    private static let worker = LocalInstallationResetWorker()
    private static var operation: Task<Bool, Error>?

    static var needsOnboardingReplay: Bool {
        #if DEBUG
            UserDefaults.standard.bool(forKey: replayKey)
                || FileManager.default.fileExists(atPath: replayMarker.path)
        #else
            false
        #endif
    }

    static func completeOnboardingReplay() throws {
        if FileManager.default.fileExists(atPath: replayMarker.path) {
            try FileManager.default.removeItem(at: replayMarker)
        }
        UserDefaults.standard.removeObject(forKey: replayKey)
    }

    static func performIfRequested() async throws {
        #if DEBUG
            guard !didResetInThisProcess,
                ProcessInfo.processInfo.environment["XCODE_RUNNING_FOR_PREVIEWS"] != "1"
            else { return }
            if let operation {
                didResetInThisProcess = try await operation.value
                return
            }
            let task = Task { try await worker.performIfRequested() }
            operation = task
            defer { operation = nil }
            didResetInThisProcess = try await task.value
        #endif
    }
}

/// Actor methods run on the cooperative executor, including synchronous Security calls.
/// Constructing this worker performs no Keychain or application-service queries.
private actor LocalInstallationResetWorker {
    private let logger = Logger(subsystem: "uz.voicelab.desktop", category: "local-reset")
    func performIfRequested() async throws -> Bool {
        let files = FileManager.default
        let support = URL.applicationSupportDirectory
        let onboardingRequest = support.appendingPathComponent("Echo.onboarding-reset-request")
        if files.fileExists(atPath: onboardingRequest.path) {
            try await resetOnboarding(request: onboardingRequest)
            return true
        }
        let request = support.appendingPathComponent("VoiceLabNative.reset-request")
        guard files.fileExists(atPath: request.path) else { return false }
        guard Bundle.main.bundleIdentifier == "uz.voicelab.desktop" else {
            throw VoiceLabError.storage("Lokal tozalash uchun ilova identifikatori mos kelmadi.")
        }

        // Restore the global Fn setting before deleting the backup preference.
        try await MainActor.run { try FnKeyPolicy().release() }
        let status = SecItemDelete(
            [
                kSecClass as String: kSecClassGenericPassword,
                kSecAttrService as String: "uz.voicelab.native" + RuntimeBackend.environment.storageNamespace,
            ] as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw VoiceLabError.storage("Lokal loginni tozalab bo‘lmadi (Keychain: \(status)).")
        }
        let bundleID = "uz.voicelab.desktop"
        URLCache.shared.removeAllCachedResponses()
        HTTPCookieStorage.shared.removeCookies(since: .distantPast)
        let userLibrary = files.homeDirectoryForCurrentUser.appendingPathComponent("Library")
        let paths = [
            RuntimeBackend.libraryDirectory,
            URL.cachesDirectory.appendingPathComponent(bundleID, isDirectory: true),
            userLibrary.appendingPathComponent("HTTPStorages/\(bundleID)", isDirectory: true),
            userLibrary.appendingPathComponent("HTTPStorages/\(bundleID).binarycookies"),
            userLibrary.appendingPathComponent("WebKit/\(bundleID)", isDirectory: true),
            files.homeDirectoryForCurrentUser.appendingPathComponent(
                "Library/Saved Application State/\(bundleID).savedState", isDirectory: true),
        ]
        for path in paths where files.fileExists(atPath: path.path) { try files.removeItem(at: path) }
        // Only UUID-named recording directories created by this native app.
        for path in try files.contentsOfDirectory(
            at: files.temporaryDirectory, includingPropertiesForKeys: nil
        ) where path.lastPathComponent.hasPrefix("VoiceLab-") {
            if UUID(uuidString: String(path.lastPathComponent.dropFirst("VoiceLab-".count))) != nil {
                try files.removeItem(at: path)
            }
        }
        UserDefaults.standard.removePersistentDomain(forName: bundleID)
        guard UserDefaults.standard.synchronize() else {
            throw VoiceLabError.storage("Lokal sozlamalarni tozalash yakunlanmadi.")
        }
        // Consumed only on success; failures stay retryable on the next launch.
        try files.removeItem(at: request)
        return true
    }

    /// Replay setup without destroying account libraries, pending note sync, or their encryption keys.
    private func resetOnboarding(request: URL) async throws {
        guard Bundle.main.bundleIdentifier == "uz.voicelab.desktop" else {
            throw VoiceLabError.storage("Lokal tozalash uchun ilova identifikatori mos kelmadi.")
        }
        // This scoped reset preserves the Fn backup, so restoring a private
        // system preference is unnecessary and must not gate onboarding.
        try step("Keychain session") { try RuntimeBackend.keychain.remove("session") }
        try step("HTTP cache") {
            URLCache.shared.removeAllCachedResponses()
            HTTPCookieStorage.shared.removeCookies(since: .distantPast)
        }

        let files = FileManager.default
        let library = files.homeDirectoryForCurrentUser.appendingPathComponent("Library")
        let bundleID = "uz.voicelab.desktop"
        let paths = [
            URL.cachesDirectory.appendingPathComponent(bundleID, isDirectory: true),
            library.appendingPathComponent("HTTPStorages/\(bundleID)", isDirectory: true),
            library.appendingPathComponent("HTTPStorages/\(bundleID).binarycookies"),
            library.appendingPathComponent("WebKit/\(bundleID)", isDirectory: true),
            library.appendingPathComponent(
                "Saved Application State/\(bundleID).savedState", isDirectory: true),
        ]
        for path in paths {
            try step("Cache \(path.lastPathComponent)") {
                do { try files.removeItem(at: path) } catch CocoaError.fileNoSuchFile
                { /* A missing cache is already clean. */  }
            }
        }

        // Keep server Retry-After deadlines and installation identity intact.
        for key in [
            "dictationShortcut", "microphoneID", "uzbekAlphabet", "autoPaste", "textInsertionMethod",
            "retainHistory", "appearance", "alwaysShowDockIcon", "activationMode", "accentColor",
        ] {
            UserDefaults.standard.removeObject(forKey: key)
        }
        try step("Onboarding replay marker") {
            // Persist replay intent independently of UserDefaults' asynchronous flush.
            // A restart between cleanup and login must still reset only onboarding.
            try Data("pending\n".utf8).write(to: LocalInstallationReset.replayMarker, options: .atomic)
            UserDefaults.standard.set(true, forKey: LocalInstallationReset.replayKey)
        }
        // Consume only after all cleanup succeeded; previews never reach this path.
        try step("Reset request") { try files.removeItem(at: request) }
    }

    private func step(_ name: String, operation: () throws -> Void) throws {
        logger.notice("Local reset: \(name, privacy: .public)")
        do {
            try operation()
        } catch {
            let failure = error as NSError
            logger.error(
                "Local reset failed: \(name, privacy: .public), \(failure.domain, privacy: .public) \(failure.code): \(error.localizedDescription, privacy: .public)"
            )
            throw VoiceLabError.storage("\(name): \(error.localizedDescription)")
        }
    }
}
