import Foundation
import Testing

@testable import VoiceLabCore

@Suite
struct HTTPRateLimitTests {
    @Test func localCooldownDoesNotReadOrOverwriteProduction() async throws {
        let suite = "Echo.EnvironmentTests.\(UUID())"
        defer { UserDefaults(suiteName: suite)?.removePersistentDomain(forName: suite) }
        let production = HTTPRateLimitGate(
            persistAuthenticationCooldown: true, defaults: UserDefaults(suiteName: suite)!)
        let until = Date.now.addingTimeInterval(90)
        await production.record("desktop-auth:token", retryAt: until, requestID: nil)
        let local = HTTPRateLimitGate(
            persistAuthenticationCooldown: true, defaults: UserDefaults(suiteName: suite)!, namespace: ".local")
        try await local.check("desktop-auth:token")
        await local.record("desktop-auth:token", retryAt: .now.addingTimeInterval(10), requestID: nil)
        #expect(UserDefaults(suiteName: suite)?.object(forKey: "VoiceLab.auth.retryAt") as? Date == until)
        let restarted = HTTPRateLimitGate(
            persistAuthenticationCooldown: true, defaults: UserDefaults(suiteName: suite)!, namespace: ".local")
        await #expect(throws: VoiceLabError.self) { try await restarted.check("desktop-auth:token") }
    }

    @Test func authorizationCooldownDoesNotBlockTokenOrUsage() async throws {
        let gate = HTTPRateLimitGate()
        let until = Date.now.addingTimeInterval(60)
        await gate.record("desktop-auth:authorizations", retryAt: until, requestID: "fake-request")
        await #expect(throws: VoiceLabError.rateLimited(retryAt: until, requestID: "fake-request")) {
            try await gate.check("desktop-auth:authorizations")
        }
        try await gate.check("desktop-auth:token")
        try await gate.check("GET:/v1/desktop/usage")
        try await gate.check("POST:/v1/desktop/stt")
    }

    @Test func shorterResponseCannotShortenExistingCooldown() async throws {
        let gate = HTTPRateLimitGate()
        let until = Date.now.addingTimeInterval(60)
        await gate.record("desktop-auth:token", retryAt: until, requestID: "first")
        await gate.record("desktop-auth:token", retryAt: .now.addingTimeInterval(5), requestID: "second")
        await #expect(throws: VoiceLabError.rateLimited(retryAt: until, requestID: "first")) {
            try await gate.check("desktop-auth:token")
        }
    }

    @Test func scopedCooldownSurvivesRelaunchWithoutBlockingUnrelatedAuth() async throws {
        let suite = "VoiceLab.AuthTests.\(UUID())"
        defer { UserDefaults(suiteName: suite)?.removePersistentDomain(forName: suite) }
        let gate = HTTPRateLimitGate(
            persistAuthenticationCooldown: true, defaults: UserDefaults(suiteName: suite)!)
        let until = Date.now.addingTimeInterval(60)
        await gate.record("desktop-auth:authorizations", retryAt: until, requestID: nil)
        let restarted = HTTPRateLimitGate(
            persistAuthenticationCooldown: true, defaults: UserDefaults(suiteName: suite)!)
        await #expect(throws: VoiceLabError.self) { try await restarted.check("desktop-auth:authorizations") }
        try await restarted.check("desktop-auth:token")
        try await restarted.check("desktop-auth:logout")
    }

    @Test func legacyCooldownIsRespectedUntilItExpires() async throws {
        let suite = "VoiceLab.AuthTests.\(UUID())"
        defer { UserDefaults(suiteName: suite)?.removePersistentDomain(forName: suite) }
        let until = Date.now.addingTimeInterval(60)
        UserDefaults(suiteName: suite)!.set(until, forKey: "VoiceLab.auth.retryAt")
        let gate = HTTPRateLimitGate(
            persistAuthenticationCooldown: true, defaults: UserDefaults(suiteName: suite)!)
        await #expect(throws: VoiceLabError.self) { try await gate.check("desktop-auth:token") }
        await #expect(throws: VoiceLabError.self) { try await gate.check("desktop-auth:authorizations") }
        try await gate.check("desktop-auth:logout")
    }

    @Test func expiredCooldownDoesNotBlockAndClearsCountdown() async throws {
        let suite = "VoiceLab.AuthTests.\(UUID())"
        defer { UserDefaults(suiteName: suite)?.removePersistentDomain(forName: suite) }
        let gate = HTTPRateLimitGate(
            persistAuthenticationCooldown: true, defaults: UserDefaults(suiteName: suite)!)
        await gate.record("desktop-auth:token", retryAt: .now.addingTimeInterval(-1), requestID: nil)
        try await gate.check("desktop-auth:token")
        #expect(UserDefaults(suiteName: suite)?.object(forKey: "VoiceLab.auth.retryAt") == nil)
    }

    @Test func retryAfterHandlesSecondsHTTPDatesAndInvalidHeaders() {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        #expect(HTTPRateLimitGate.retryDate("30", now: now) == now.addingTimeInterval(30))
        #expect(HTTPRateLimitGate.retryDate("0", now: now) == now.addingTimeInterval(1))
        #expect(
            HTTPRateLimitGate.retryDate("Tue, 14 Nov 2023 22:14:20 GMT", now: now)
                == now.addingTimeInterval(60))
        for header in [nil, "", "-5", "NaN", "Infinity", "invalid"] {
            #expect(HTTPRateLimitGate.retryDate(header, now: now) == now.addingTimeInterval(60))
        }
    }
}
