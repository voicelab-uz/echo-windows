import Foundation

/// Shared by copies of HTTPClient. Rejects early retries without replaying requests.
actor HTTPRateLimitGate {
    private struct Cooldown: Codable {
        let retryAt: Date
        let requestID: String?
    }
    private var cooldowns: [String: Cooldown] = [:]
    private let deadlineKey: String
    private let requestKey: String
    private let scopesKey: String
    private let defaults: UserDefaults?

    init(persistAuthenticationCooldown: Bool = false, defaults: UserDefaults = .standard, namespace: String = "") {
        deadlineKey = "VoiceLab.auth.retryAt" + namespace
        requestKey = "VoiceLab.auth.retryRequestID" + namespace
        scopesKey = "VoiceLab.auth.cooldowns" + namespace
        self.defaults = persistAuthenticationCooldown ? defaults : nil
        if persistAuthenticationCooldown,
            let data = defaults.data(forKey: scopesKey),
            let stored = try? JSONDecoder().decode([String: Cooldown].self, from: data)
        {
            cooldowns = stored.filter { $0.value.retryAt > .now }
        } else if persistAuthenticationCooldown,
            let retryAt = defaults.object(forKey: deadlineKey) as? Date,
            retryAt > .now
        {
            // Older builds shared one auth bucket. Respect its remaining wait
            // during migration; new responses are persisted by server operation.
            let legacy = Cooldown(retryAt: retryAt, requestID: defaults.string(forKey: requestKey))
            cooldowns["desktop-auth:token"] = legacy
            cooldowns["desktop-auth:authorizations"] = legacy
        }
    }

    func check(_ key: String) throws {
        guard let cooldown = cooldowns[key] else { return }
        guard cooldown.retryAt > .now else {
            cooldowns[key] = nil
            persist()
            return
        }
        throw VoiceLabError.rateLimited(retryAt: cooldown.retryAt, requestID: cooldown.requestID)
    }

    func record(_ key: String, retryAt: Date, requestID: String?) {
        guard retryAt > (cooldowns[key]?.retryAt ?? .distantPast) else { return }
        cooldowns[key] = Cooldown(retryAt: retryAt, requestID: requestID)
        persist()
    }

    private func persist() {
        guard let defaults else { return }
        let auth = cooldowns.filter { $0.key.hasPrefix("desktop-auth:") && $0.value.retryAt > .now }
        if let data = try? JSONEncoder().encode(auth) {
            defaults.set(data, forKey: scopesKey)
        }
        // Preserve the sign-in countdown used by the app without coupling
        // unrelated endpoints in the HTTP layer.
        let signIn = auth.filter { ["desktop-auth:authorizations", "desktop-auth:token"].contains($0.key) }
            .values.max { $0.retryAt < $1.retryAt }
        if let signIn {
            defaults.set(signIn.retryAt, forKey: deadlineKey)
            defaults.set(signIn.requestID, forKey: requestKey)
        } else {
            defaults.removeObject(forKey: deadlineKey)
            defaults.removeObject(forKey: requestKey)
        }
    }

    static func retryDate(_ header: String?, now: Date = .now) -> Date {
        let value = header?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if let seconds = Double(value), seconds.isFinite, seconds >= 0 {
            return now.addingTimeInterval(max(1, seconds))
        }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss z"
        if let date = formatter.date(from: value) { return max(now.addingTimeInterval(1), date) }
        // Missing or invalid server guidance: wait conservatively, never auto-retry.
        return now.addingTimeInterval(60)
    }
}
