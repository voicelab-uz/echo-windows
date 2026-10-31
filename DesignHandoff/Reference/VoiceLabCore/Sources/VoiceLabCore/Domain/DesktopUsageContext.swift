import Foundation

/// A destination captured for one dictation, not a log of foreground applications.
/// URLs, window titles, document contents and paths are never persisted.
public struct DesktopUsageContext: Codable, Equatable, Sendable {
    public enum Category: String, Codable, CaseIterable, Sendable {
        case personal, other, ai, email, work, documents
    }
    public let appID: String
    public let appName: String
    public let category: Category
    enum CodingKeys: String, CodingKey {
        case appID = "appId"
        case appName, category
    }
    public init(appID: String, appName: String, category: Category) {
        self.appID = appID
        self.appName = appName
        self.category = category
    }

    public static func classify(bundleID: String, appName: String, host: String? = nil) -> Self {
        let websites: [(String, String, Category)] = [
            ("chatgpt.com", "ChatGPT", .ai), ("chat.openai.com", "ChatGPT", .ai),
            ("gemini.google.com", "Gemini", .ai), ("claude.ai", "Claude", .ai),
            ("grok.com", "Grok", .ai), ("perplexity.ai", "Perplexity", .ai),
            ("mail.google.com", "Gmail", .email), ("outlook.live.com", "Outlook", .email),
            ("outlook.office.com", "Outlook", .email), ("outlook.office365.com", "Outlook", .email),
            ("web.whatsapp.com", "WhatsApp", .personal), ("web.telegram.org", "Telegram", .personal),
            ("discord.com", "Discord", .personal), ("messenger.com", "Messenger", .personal),
            ("app.slack.com", "Slack", .work), ("teams.microsoft.com", "Teams", .work),
            ("teams.cloud.microsoft", "Teams", .work),
            ("docs.google.com", "Google Docs", .documents), ("notion.so", "Notion", .documents),
        ]
        if let host = host?.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: ".")),
            let match = websites.first(where: { host == $0.0 || host.hasSuffix("." + $0.0) })
        {
            return Self(appID: "web:" + match.0, appName: match.1, category: match.2)
        }
        let groups: [(Category, [String])] = [
            (
                .personal,
                [
                    "ru.keepcoder.Telegram", "org.telegram.desktop", "net.whatsapp.WhatsApp",
                    "com.apple.MobileSMS", "com.hnc.Discord", "org.whispersystems.signal-desktop",
                ]
            ),
            (.work, ["com.tinyspeck.slackmacgap", "com.microsoft.teams", "com.microsoft.teams2"]),
            (.email, ["com.apple.mail", "com.microsoft.Outlook", "com.readdle.smartemail-Mac"]),
            (.ai, ["com.openai.chat", "com.anthropic.claudefordesktop", "ai.perplexity.mac"]),
            (
                .documents,
                [
                    "com.apple.Notes", "com.apple.iWork.Pages", "com.microsoft.Word", "notion.id",
                    "md.obsidian", "com.apple.TextEdit", "com.screensaver.Voicelab",
                ]
            ),
        ]
        let category =
            groups.first { $0.1.contains { $0.caseInsensitiveCompare(bundleID) == .orderedSame } }?.0
            ?? .other
        return Self(
            appID: String(bundleID.prefix(200)), appName: String(appName.prefix(80)), category: category)
    }
}

public struct DesktopUsageDay: Codable, Equatable, Sendable {
    public let day: String
    public let appID: String
    public let appName: String
    public let category: DesktopUsageContext.Category
    public var words: Int
    public var recordings: Int
    // Explicit camel casing supports both encrypted storage and the HTTP decoder's snake-case conversion.
    enum CodingKeys: String, CodingKey {
        case day
        case appID = "appId"
        case appName, category, words, recordings
    }
    public init(day: String, context: DesktopUsageContext, words: Int, recordings: Int) {
        self.day = day
        appID = context.appID
        appName = context.appName
        category = context.category
        self.words = words
        self.recordings = recordings
    }
}

public struct DesktopUsageSummary: Sendable {
    public struct Application: Identifiable, Sendable {
        public let id: String
        public var name: String
        public var words = 0
        public var recordings = 0
    }
    public struct Day: Sendable {
        public var apps: [String: Application] = [:]
        public var topApp: Application? {
            apps.values.sorted { $0.words == $1.words ? $0.id < $1.id : $0.words > $1.words }.first
        }
    }
    public struct Category: Identifiable, Sendable {
        public let id: DesktopUsageContext.Category
        public var recordings = 0
        public var words = 0
    }
    public let categories: [Category]
    public let apps: [String: Application]
    public let days: [String: Day]
    public let recordings: Int
    public init(rows: [DesktopUsageDay], validDays: Set<String>) {
        var grouped = Dictionary(
            uniqueKeysWithValues: DesktopUsageContext.Category.allCases.map { ($0, Category(id: $0)) })
        var apps: [String: Application] = [:]
        var days: [String: Day] = [:]
        var count = 0
        for row in rows where validDays.contains(row.day) && row.words >= 0 && row.recordings > 0 {
            grouped[row.category]?.recordings += row.recordings
            grouped[row.category]?.words += row.words
            var app = apps[row.appID, default: Application(id: row.appID, name: row.appName)]
            app.words += row.words
            app.recordings += row.recordings
            apps[row.appID] = app
            var day = days[row.day, default: Day()]
            var dailyApp = day.apps[row.appID, default: Application(id: row.appID, name: row.appName)]
            dailyApp.words += row.words
            dailyApp.recordings += row.recordings
            day.apps[row.appID] = dailyApp
            days[row.day] = day
            count += row.recordings
        }
        categories = DesktopUsageContext.Category.allCases.compactMap { grouped[$0] }
        self.apps = apps
        self.days = days
        recordings = count
    }
    public static func localRows(_ records: [Transcript], calendar: Calendar = .current) -> [DesktopUsageDay]
    {
        var seen = Set<String>()
        var grouped: [String: DesktopUsageDay] = [:]
        for record in records {
            guard seen.insert(record.id).inserted, let context = record.usageContext else { continue }
            let day = StatisticsSummary.dayKey(record.createdAt, calendar: calendar)
            let key = day + ":" + context.appID + ":" + context.category.rawValue
            var row = grouped[
                key, default: DesktopUsageDay(day: day, context: context, words: 0, recordings: 0)]
            row.words += StatisticsSummary.wordCount(record.text)
            row.recordings += 1
            grouped[key] = row
        }
        return Array(grouped.values)
    }
}
