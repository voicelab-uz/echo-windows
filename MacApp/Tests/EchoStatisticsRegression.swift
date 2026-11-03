import Foundation

@main struct EchoStatisticsRegression {
    static func decode(_ body: String) throws -> EchoStatistics {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        return try decoder.decode(EchoStatistics.self, from: Data(body.utf8))
    }
    static func main() throws {
        let old = #"{"days":[{"day":"2026-10-27","language":"uz","words":100,"recordings":1,"duration_ms":60000}],"from":"2026-04-28","through":"2026-10-27","time_zone":"Asia/Tashkent"}"#
        let legacy = try decode(old)
        precondition(legacy.summary == nil && legacy.estimatedSavedTime == nil)
        precondition(legacy.days[0].estimatedTimeSavedMs == nil)
        let summary = #""summary":{"words":100,"recordings":1,"duration_ms":60000,"estimated_time_saved_ms":90000,"typing_baseline_wpm":40,"estimation_method":"per_recording_clamped"},"#
        let current = old.replacingOccurrences(of: #"{"days""#, with: "{" + summary + #""days""#)
        let decoded = try decode(current)
        precondition(decoded.trustedSummary?.words == 100 && decoded.trustedSummary?.recordings == 1)
        precondition(decoded.estimatedSavedTime == .init(hours: 0, minutes: 2, isLessThanOneMinute: false))
        for invalid in [summary.replacingOccurrences(of: #""words":100"#, with: #""words":-1"#),
                        summary.replacingOccurrences(of: #""recordings":1"#, with: #""recordings":-1"#),
                        summary.replacingOccurrences(of: #""duration_ms":60000"#, with: #""duration_ms":-1"#),
                        summary.replacingOccurrences(of: #""estimated_time_saved_ms":90000"#, with: #""estimated_time_saved_ms":-1"#),
                        summary.replacingOccurrences(of: #""typing_baseline_wpm":40"#, with: #""typing_baseline_wpm":60"#),
                        summary.replacingOccurrences(of: "per_recording_clamped", with: "aggregate_clamped")] {
            let rejected = try decode(current.replacingOccurrences(of: summary, with: invalid))
            precondition(rejected.trustedSummary == nil && rejected.estimatedSavedTime == nil,
                         "Untrusted estimate must be hidden instead of recalculated from totals")
        }
        let withPlatforms = current.replacingOccurrences(of: #""from":"#, with: #""platform_days":[{"day":"2026-10-27","language":"uz","platform":"ios","words":100,"recordings":1,"duration_ms":60000,"estimated_time_saved_ms":90000}],"from":"#)
        let platforms = try decode(withPlatforms)
        precondition(platforms.platformDays?[0].estimatedTimeSavedMs == 90000)
        precondition(platforms.trustedSummary?.words == 100, "Device breakdown must not be added to the summary")
        precondition(EchoStatistics.savedTime(milliseconds: -1) == nil)
        precondition(EchoStatistics.savedTime(milliseconds: 0) == .init(hours: 0, minutes: 0, isLessThanOneMinute: false))
        precondition(EchoStatistics.savedTime(milliseconds: 29_999) == .init(hours: 0, minutes: 0, isLessThanOneMinute: true))
        precondition(EchoStatistics.savedTime(milliseconds: 30_000) == .init(hours: 0, minutes: 1, isLessThanOneMinute: false))
        precondition(EchoStatistics.savedTime(milliseconds: 3_570_000) == .init(hours: 1, minutes: 0, isLessThanOneMinute: false))
        precondition(EchoStatistics.savedTime(milliseconds: 3_660_000) == .init(hours: 1, minutes: 1, isLessThanOneMinute: false))
        precondition(EchoStatistics.savedTime(milliseconds: Int64.max) != nil)
        print("Statistics regression passed: additive summary, hidden unsupported estimates, no device double-count, and minute/hour rounding")
    }
}
