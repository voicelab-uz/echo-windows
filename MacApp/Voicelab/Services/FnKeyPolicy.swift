import Darwin
import Foundation
import VoiceLabCore

/// Temporarily owns macOS's bare Fn action while our event tap is installed.
/// A durable backup survives abnormal termination and is restored on clean exit.
@MainActor
final class FnKeyPolicy {
    private struct Backup: Codable { let previous: Int? }
    private let domain = "com.apple.HIToolbox" as CFString
    private let key = "AppleFnUsageType" as CFString
    private let backupKey = "VoiceLab.FnKeyPolicy.backup"
    private let defaults = UserDefaults.standard
    private var applied = false
    private typealias UpdateFnUsage = @convention(c) (Int32) -> Void

    func acquire() throws {
        guard !applied else { return }
        CFPreferencesAppSynchronize(domain)
        let current = CFPreferencesCopyAppValue(key, domain) as? Int
        if current == 0 {
            // May be a previous run's backup; retain it until release.
            applied = true
            return
        }
        if let current, !(0...3).contains(current) {
            throw VoiceLabError.storage("macOS Fn sozlamasi qo‘llab-quvvatlanmaydi.")
        }
        try withLiveUpdater { update in
            // If the user changed the value after a crash, this is the new baseline.
            defaults.set(try JSONEncoder().encode(Backup(previous: current)), forKey: backupKey)
            guard defaults.synchronize() else {
                throw VoiceLabError.storage("Fn sozlamasining zaxira nusxasi saqlanmadi.")
            }
            CFPreferencesSetAppValue(key, NSNumber(value: 0), domain)
            guard CFPreferencesAppSynchronize(domain) else {
                CFPreferencesSetAppValue(key, current.map { NSNumber(value: $0) }, domain)
                CFPreferencesAppSynchronize(domain)
                throw VoiceLabError.storage("Fn uchun macOS sozlamasini o‘zgartirib bo‘lmadi.")
            }
            update(0)
            applied = true
        }
    }

    func release() throws {
        applied = false
        guard let data = defaults.data(forKey: backupKey) else { return }
        let backup = try JSONDecoder().decode(Backup.self, from: data)
        CFPreferencesAppSynchronize(domain)
        let current = CFPreferencesCopyAppValue(key, domain) as? Int
        // Preserve an explicit change made by the user while Echo was running.
        if current == 0 {
            try withLiveUpdater { update in
                CFPreferencesSetAppValue(key, backup.previous.map { NSNumber(value: $0) }, domain)
                guard CFPreferencesAppSynchronize(domain) else {
                    throw VoiceLabError.storage("Fn sozlamasini qaytarib bo‘lmadi. Qayta urinib ko‘ring.")
                }
                update(Int32(backup.previous ?? 2))
            }
        }
        defaults.removeObject(forKey: backupKey)
        defaults.synchronize()
    }

    /// Same guarded HIToolbox bridge as voicelab-desktop's native helper.
    /// This private entry point applies the cached preference without a logout.
    /// If unavailable, no system setting is changed.
    private func withLiveUpdater(_ body: (UpdateFnUsage) throws -> Void) throws {
        let path = "/System/Library/Frameworks/Carbon.framework/Frameworks/HIToolbox.framework/HIToolbox"
        guard let library = dlopen(path, RTLD_LAZY) else { throw unavailable }
        defer { dlclose(library) }
        guard let symbol = dlsym(library, "TISUpdateFnUsageType") else { throw unavailable }
        try body(unsafeBitCast(symbol, to: UpdateFnUsage.self))
    }

    private var unavailable: VoiceLabError {
        .storage(
            "Fn emoji amalini avtomatik o‘chirib bo‘lmadi. Keyboard sozlamalarida “Press 🌐 key to” → “Do Nothing” tanlang."
        )
    }
}
