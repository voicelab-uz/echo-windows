import Foundation
import Testing

@testable import VoiceLabCore

@Suite struct StatisticsTests {
    @Test func desktopAndIPhoneRowsDecodeAndAddWithoutLosingOlderRows() throws {
        let data = Data("""
        {"days":[
          {"day":"2026-10-21","language":"uz","platform":"desktop","words":20,"recordings":2,"duration_ms":12000},
          {"day":"2026-10-21","language":"uz","platform":"ios","words":10,"recordings":1,"duration_ms":6000},
          {"day":"2026-10-20","language":"en","words":5,"recordings":1,"duration_ms":3000}
        ],"from":"2026-04-23","through":"2026-10-21","time_zone":"America/New_York"}
        """.utf8)
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        let result = try decoder.decode(DictationStatistics.self, from: data)
        #expect(result.days.map(\.platform) == ["desktop", "ios", nil])
        let summary = StatisticsSummary(rows: result.days, period: 7, now: date(2026, 10, 21), calendar: calendar)
        #expect(summary.recordings == 4 && summary.words == 35)
    }

    /// Current servers: `days` are cross-device totals without a platform; the device split
    /// arrives in `platform_days`. Totals must come from `days` only, never both.
    @Test func platformDaysCarryTheDeviceSplitSeparatelyFromTotals() throws {
        let data = Data("""
        {"days":[
          {"day":"2026-10-21","language":"uz","words":30,"recordings":3,"duration_ms":18000}
        ],"platform_days":[
          {"day":"2026-10-21","language":"uz","platform":"desktop","words":20,"recordings":2,"duration_ms":12000},
          {"day":"2026-10-21","language":"uz","platform":"ios","words":10,"recordings":1,"duration_ms":6000}
        ],"from":"2026-04-23","through":"2026-10-21","time_zone":"America/New_York"}
        """.utf8)
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        let result = try decoder.decode(DictationStatistics.self, from: data)
        let split = try #require(result.platformDays)
        #expect(split.filter { $0.platform == "ios" }.reduce(0) { $0 + $1.recordings } == 1)
        #expect(split.filter { $0.platform == "desktop" }.reduce(0) { $0 + $1.recordings } == 2)
        let summary = StatisticsSummary(rows: result.days, period: 7, now: date(2026, 10, 21), calendar: calendar)
        #expect(summary.recordings == 3 && summary.words == 30)
    }

    private var calendar: Calendar {
        var value = Calendar(identifier: .gregorian)
        value.timeZone = TimeZone(identifier: "America/New_York")!
        return value
    }
    private func date(_ year: Int, _ month: Int, _ day: Int) -> Date {
        calendar.date(from: DateComponents(year: year, month: month, day: day, hour: 12))!
    }
    @Test func wordsRespectUzbekApostrophesAndPunctuation() {
        #expect(
            StatisticsSummary.wordCount("O‘zbekiston, g'oya va ko‘z. Привет мир! Hello-world… 😀 ' ’") == 8)
        #expect(StatisticsSummary.wordCount("... 😀\n") == 0)
        #expect(StatisticsSummary.wordCount("Özbekiston ğoya çiroyli şahar") == 4)
    }
    @Test func speedIsDurationWeighted() {
        let now = date(2026, 10, 21)
        let rows = [
            StatisticsDay(day: "2026-10-21", language: "uz", words: 100, recordings: 1, durationMs: 60_000),
            StatisticsDay(day: "2026-10-20", language: "en", words: 100, recordings: 1, durationMs: 30_000),
        ]
        let summary = StatisticsSummary(rows: rows, period: 7, now: now, calendar: calendar)
        #expect(summary.words == 200 && summary.recordings == 2 && summary.durationMs == 90_000)
        #expect(abs(summary.wordsPerMinute! - 133.333333) < 0.001)
        #expect(summary.currentStreak == 2 && summary.longestStreak == 2)
        #expect(summary.languages.count == 2)
    }
    @Test func streakAllowsTodayButNotMissingYesterday() {
        let now = date(2026, 10, 21)
        let rows = [18, 19, 20].map {
            StatisticsDay(day: "2026-10-\($0)", language: "uz", words: 1, recordings: 1, durationMs: 500)
        }
        #expect(StatisticsSummary(rows: rows, period: 7, now: now, calendar: calendar).currentStreak == 3)
        let broken = StatisticsSummary(rows: Array(rows.dropLast()), period: 7, now: now, calendar: calendar)
        #expect(broken.currentStreak == 0 && broken.longestStreak == 2)
    }
    @Test func daylightSavingAndPeriodBoundaries() {
        let now = date(2026, 3, 10)
        let rows = (4...10).map {
            StatisticsDay(
                day: String(format: "2026-03-%02d", $0), language: "uz", words: 1, recordings: 1,
                durationMs: 500)
        }
        let summary = StatisticsSummary(rows: rows, period: 7, now: now, calendar: calendar)
        #expect(summary.days.count == 7 && summary.activeDays == 7 && summary.currentStreak == 7)
        #expect(summary.days[5].date.timeIntervalSince(summary.days[4].date) == 23 * 3600)
        #expect(StatisticsSummary(rows: rows, period: 1, now: now, calendar: calendar).words == 1)
    }
    @Test func localHistoryDeduplicatesAndExcludesFutureOrOldRecords() {
        let now = date(2026, 10, 21)
        let record = Transcript(
            id: "a", text: "Salom dunyo", language: "uz", durationMS: 1000, createdAt: now)
        let future = Transcript(
            id: "b", text: "future", language: "en", durationMS: 1000, createdAt: date(2026, 10, 22))
        let old = Transcript(
            id: "c", text: "old", language: "en", durationMS: 1000, createdAt: date(2025, 1, 1))
        let rows = StatisticsSummary.localRows([record, record, future, old], now: now, calendar: calendar)
        #expect(rows.count == 1 && rows[0].words == 2 && rows[0].recordings == 1)
    }
    @Test func emptyHistoryHasNoInventedSpeedOrStreak() {
        let result = StatisticsSummary(rows: [], period: 30, now: date(2026, 10, 21), calendar: calendar)
        #expect(result.wordsPerMinute == nil && result.currentStreak == 0 && result.longestStreak == 0)
        #expect(result.words == 0 && result.recordings == 0 && result.activeDays == 0)
        #expect(result.days.count == 30)
    }
}
