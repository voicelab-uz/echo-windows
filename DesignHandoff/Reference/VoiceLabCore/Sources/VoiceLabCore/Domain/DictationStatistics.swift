import Foundation

public struct StatisticsDay: Codable, Equatable, Sendable {
    public let day: String
    public let language: String
    public let platform: String?
    public var words: Int
    public var recordings: Int
    public var durationMs: Int
    public init(day: String, language: String, words: Int, recordings: Int, durationMs: Int, platform: String? = nil) {
        self.day = day
        self.language = language
        self.platform = platform
        self.words = words
        self.recordings = recordings
        self.durationMs = durationMs
    }
}

public struct DictationStatistics: Decodable, Sendable {
    /// Daily totals across every device; rows carry no platform on current servers.
    public let days: [StatisticsDay]
    /// The additive per-device breakdown (`platform` is "desktop" or "ios"). Missing on
    /// older servers, where the platform, if any, sits on `days` instead.
    public let platformDays: [StatisticsDay]?
    public let applications: [DesktopUsageDay]?
    public let from: String
    public let through: String
    public let timeZone: String
}

public struct StatisticsSummary: Sendable {
    public struct Day: Identifiable, Sendable {
        public let date: Date
        public var words = 0
        public var recordings = 0
        public var id: Date { date }
    }
    public struct Language: Identifiable, Sendable {
        public let id: String
        public var words = 0
        public var recordings = 0
    }
    public let words: Int
    public let recordings: Int
    public let durationMs: Int
    public let currentStreak: Int
    public let longestStreak: Int
    public let days: [Day]
    public let languages: [Language]
    public var activeDays: Int { days.filter { $0.recordings > 0 }.count }
    public var wordsPerMinute: Double? {
        durationMs > 0 ? Double(words) * 60_000 / Double(durationMs) : nil
    }

    public init(rows: [StatisticsDay], period: Int, now: Date = .now, calendar: Calendar = .current) {
        let today = calendar.startOfDay(for: now)
        let count = min(182, max(1, period))
        var calendarDays = (0..<count).reversed().map {
            Day(date: calendar.date(byAdding: .day, value: -$0, to: today)!)
        }
        let indices = Dictionary(
            uniqueKeysWithValues: calendarDays.enumerated().map {
                (Self.dayKey($0.element.date, calendar: calendar), $0.offset)
            })
        var totalWords = 0
        var totalRecordings = 0
        var totalDuration = 0
        var byLanguage: [String: Language] = [:]
        for row in rows {
            guard let index = indices[row.day], row.words >= 0, row.recordings >= 0, row.durationMs >= 0
            else { continue }
            calendarDays[index].words += row.words
            calendarDays[index].recordings += row.recordings
            totalWords += row.words
            totalRecordings += row.recordings
            totalDuration += row.durationMs
            var language = byLanguage[row.language, default: Language(id: row.language)]
            language.words += row.words
            language.recordings += row.recordings
            byLanguage[row.language] = language
        }
        var longest = 0
        var running = 0
        for day in calendarDays {
            running = day.recordings > 0 ? running + 1 : 0
            longest = max(longest, running)
        }
        // Yesterday's streak stays active until the user has had all of today.
        let streakDays = calendarDays.last?.recordings == 0 ? Array(calendarDays.dropLast()) : calendarDays
        var current = 0
        for day in streakDays.reversed() {
            guard day.recordings > 0 else { break }
            current += 1
        }
        words = totalWords
        recordings = totalRecordings
        durationMs = totalDuration
        days = calendarDays
        currentStreak = current
        longestStreak = longest
        languages = byLanguage.values.sorted { $0.words == $1.words ? $0.id < $1.id : $0.words > $1.words }
    }

    private static let wordPattern = try! NSRegularExpression(
        pattern: "[\\p{L}\\p{N}]+(?:['’‘ʻʼ][\\p{L}\\p{N}]+)*")
    public static func wordCount(_ text: String) -> Int {
        wordPattern.numberOfMatches(in: text, range: NSRange(text.startIndex..., in: text))
    }
    public static func dayKey(_ date: Date, calendar: Calendar) -> String {
        let parts = calendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", parts.year!, parts.month!, parts.day!)
    }
    public static func localRows(_ transcripts: [Transcript], now: Date = .now, calendar: Calendar = .current)
        -> [StatisticsDay]
    {
        let today = calendar.startOfDay(for: now)
        let first = calendar.date(byAdding: .day, value: -181, to: today)!
        let end = calendar.date(byAdding: .day, value: 1, to: today)!
        var seen = Set<String>()
        var rows: [String: StatisticsDay] = [:]
        for record in transcripts where record.createdAt >= first && record.createdAt < end {
            guard seen.insert(record.id).inserted else { continue }
            let day = dayKey(record.createdAt, calendar: calendar)
            let key = day + ":" + record.language
            var row = rows[
                key,
                default: StatisticsDay(
                    day: day, language: record.language, words: 0, recordings: 0, durationMs: 0)]
            row.words += wordCount(record.text)
            row.recordings += 1
            row.durationMs += max(0, record.durationMS)
            rows[key] = row
        }
        return Array(rows.values)
    }
}
