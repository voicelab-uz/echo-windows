import Foundation
import OSLog

public protocol StatisticsServing: Sendable {
    func statistics(accountID: String, timeZone: String) async throws -> DictationStatistics
}
extension DesktopAPI {
    static let statisticsLog = Logger(subsystem: "uz.voicelab.desktop", category: "Statistics")

    /// Names the first rule a statistics response broke, so a silent fallback to local
    /// history (which never has iPhone rows) can be diagnosed from Console.
    static func logRejection(_ result: DictationStatistics, timeZone: String) {
        if result.timeZone != timeZone {
            statisticsLog.error("statistics rejected: time zone \(result.timeZone, privacy: .public) != \(timeZone, privacy: .public)")
            return
        }
        let keys = result.days.map { $0.day + ":" + $0.language + ":" + ($0.platform ?? "desktop") }
        if Set(keys).count != keys.count {
            statisticsLog.error("statistics rejected: duplicate day/language/platform rows")
            return
        }
        if let bad = result.days.first(where: { !($0.day >= result.from && $0.day <= result.through) }) {
            statisticsLog.error("statistics rejected: day \(bad.day, privacy: .public) outside \(result.from, privacy: .public)…\(result.through, privacy: .public)")
        } else if let bad = result.days.first(where: { !SpeechLanguages.isLanguageCode($0.language) }) {
            statisticsLog.error("statistics rejected: language \(bad.language, privacy: .public) on \(bad.platform ?? "nil", privacy: .public)")
        } else if let bad = result.days.first(where: { !($0.platform == nil || $0.platform == "desktop" || $0.platform == "ios") }) {
            statisticsLog.error("statistics rejected: platform \(bad.platform ?? "nil", privacy: .public)")
        } else {
            statisticsLog.error("statistics rejected: a count is out of range")
        }
    }
}

extension DesktopAPI: StatisticsServing {
    public func statistics(accountID: String, timeZone: String) async throws -> DictationStatistics {
        var components = URLComponents()
        components.queryItems = [URLQueryItem(name: "time_zone", value: timeZone)]
        let result = try HTTPClient.decode(
            DictationStatistics.self,
            data: await request(
                "/v1/desktop/statistics?" + (components.percentEncodedQuery ?? ""), accountID: accountID))
        let breakdown = Dictionary(grouping: result.platformDays ?? [], by: { $0.platform ?? "nil" })
            .mapValues { $0.reduce(0) { $0 + $1.recordings } }
        Self.statisticsLog.notice(
            "statistics: \(result.days.count) day rows, platform_days recordings=\(breakdown.description, privacy: .public)")
        guard result.timeZone == timeZone, result.days.count <= 182 * 100,
            Set(result.days.map { $0.day + ":" + $0.language + ":" + ($0.platform ?? "desktop") }).count == result.days.count,
            result.days.allSatisfy({
                $0.day >= result.from && $0.day <= result.through && SpeechLanguages.isLanguageCode($0.language)
                    && ($0.platform == nil || $0.platform == "desktop" || $0.platform == "ios")
                    && $0.words >= 0 && $0.recordings >= 0 && $0.durationMs >= 0 && $0.words <= 1_000_000_000
                    && $0.recordings <= 1_000_000 && $0.durationMs <= 86_400_000_000
            })
        else {
            Self.logRejection(result, timeZone: timeZone)
            throw VoiceLabError.invalidResponse
        }
        if let platformDays = result.platformDays {
            guard platformDays.count <= 182 * 100 * 2,
                  platformDays.allSatisfy({
                      $0.day >= result.from && $0.day <= result.through
                      && ($0.platform == "desktop" || $0.platform == "ios")
                      && $0.words >= 0 && $0.recordings >= 0 && $0.durationMs >= 0
                      && $0.words <= 1_000_000_000 && $0.recordings <= 1_000_000
                  }) else {
                Self.statisticsLog.error("statistics rejected: platform_days has an unknown platform or bad count")
                throw VoiceLabError.invalidResponse
            }
        }
        if let applications = result.applications {
            guard applications.count <= 100_000,
                  applications.allSatisfy({
                      $0.day >= result.from && $0.day <= result.through && !$0.appID.isEmpty
                      && $0.appID.count <= 200 && !$0.appName.isEmpty && $0.appName.count <= 80
                      && $0.words >= 0 && $0.words <= 1_000_000_000
                      && $0.recordings > 0 && $0.recordings <= 1_000_000
                  }) else { throw VoiceLabError.invalidResponse }
        }
        return result
    }
}

public protocol DesktopUsageServing: Sendable {
    func saveUsageContext(_ context: DesktopUsageContext, transcriptID: String, accountID: String) async throws
}

extension DesktopAPI: DesktopUsageServing {
    public func saveUsageContext(_ context: DesktopUsageContext, transcriptID: String, accountID: String) async throws {
        guard transcriptID.range(of: "^dst_[A-Za-z0-9_-]+$", options: .regularExpression) != nil else {
            throw VoiceLabError.invalidResponse
        }
        let encoder = JSONEncoder()
        encoder.keyEncodingStrategy = .convertToSnakeCase
        _ = try await request("/v1/desktop/transcriptions/\(transcriptID)/usage", method: "PUT",
                              body: encoder.encode(context), accountID: accountID)
    }
}
