import Foundation
import Testing
@testable import VoiceLabCore

@Suite struct DesktopUsageTests {
    @Test func classifiesAppsAndOnlyKnownWebsites() {
        #expect(DesktopUsageContext.classify(bundleID: "ru.keepcoder.Telegram", appName: "Telegram").category == .personal)
        #expect(DesktopUsageContext.classify(bundleID: "com.tinyspeck.slackmacgap", appName: "Slack").category == .work)
        #expect(DesktopUsageContext.classify(bundleID: "com.apple.mail", appName: "Mail").category == .email)
        #expect(DesktopUsageContext.classify(bundleID: "com.apple.Notes", appName: "Notes").category == .documents)
        let gemini = DesktopUsageContext.classify(bundleID: "com.google.Chrome", appName: "Chrome", host: "gemini.google.com")
        #expect(gemini.category == .ai && gemini.appName == "Gemini" && gemini.appID == "web:gemini.google.com")
        let spoof = DesktopUsageContext.classify(bundleID: "com.google.Chrome", appName: "Chrome", host: "gemini.google.com.attacker.test")
        #expect(spoof.category == .other && spoof.appID == "com.google.Chrome")
        let unknown = DesktopUsageContext.classify(bundleID: "com.google.Chrome", appName: "Chrome", host: "private.corp.test")
        #expect(unknown.appID == "com.google.Chrome" && unknown.appName == "Chrome")
    }
    @Test func aggregatesDestinationsWithoutInferringOldRecordings() {
        let now = Date.now
        let key = StatisticsSummary.dayKey(now, calendar: .current)
        let slack = DesktopUsageContext.classify(bundleID: "com.tinyspeck.slackmacgap", appName: "Slack")
        let notes = DesktopUsageContext.classify(bundleID: "com.apple.Notes", appName: "Notes")
        var one = Transcript(id: "one", text: "one two three", language: "en", durationMS: 1000, createdAt: now)
        one.usageContext = slack
        var two = Transcript(id: "two", text: "salom", language: "uz", durationMS: 1000, createdAt: now)
        two.usageContext = notes
        var three = Transcript(id: "three", text: "Привет мир", language: "ru", durationMS: 1000, createdAt: now)
        three.usageContext = slack
        let old = Transcript(id: "old", text: "this does not reveal its app", language: "en", durationMS: 1000, createdAt: now)
        let rows = DesktopUsageSummary.localRows([one, two, three, one, old])
        let result = DesktopUsageSummary(rows: rows, validDays: [key])
        #expect(result.apps.count == 2 && result.recordings == 3)
        #expect(result.categories.first(where: { $0.id == .work })?.recordings == 2)
        #expect(result.days[key]?.topApp?.name == "Slack" && result.days[key]?.topApp?.words == 5)
        #expect(DesktopUsageSummary(rows: rows, validDays: []).recordings == 0)
        #expect(DesktopUsageSummary.localRows([old]).isEmpty)
    }
    @Test func contextPersistsAndUsesServerKeys() throws {
        let value = DesktopUsageContext.classify(bundleID: "com.apple.Notes", appName: "Notes")
        let encoder = JSONEncoder(); encoder.keyEncodingStrategy = .convertToSnakeCase
        let data = try encoder.encode(value)
        let json = try #require(JSONSerialization.jsonObject(with: data) as? [String: String])
        #expect(json["app_id"] == "com.apple.Notes" && json["app_name"] == "Notes")
        var transcript = Transcript(text: "hi", language: "en", durationMS: 1000)
        transcript.usageContext = value
        let saved = try JSONDecoder().decode(Transcript.self, from: JSONEncoder().encode(transcript))
        #expect(saved.usageContext == value)
    }
    @Test func decodesOldAndNewStatisticsResponses() throws {
        let old = Data(#"{"days":[],"from":"2026-04-23","through":"2026-10-21","time_zone":"UTC"}"#.utf8)
        #expect(try HTTPClient.decode(DictationStatistics.self, data: old).applications == nil)
        let new = Data(#"{"days":[],"applications":[{"day":"2026-10-21","app_id":"web:gemini.google.com","app_name":"Gemini","category":"ai","words":20,"recordings":1}],"from":"2026-04-23","through":"2026-10-21","time_zone":"UTC"}"#.utf8)
        let row = try #require(HTTPClient.decode(DictationStatistics.self, data: new).applications?.first)
        #expect(row.appID == "web:gemini.google.com" && row.category == .ai)
    }
}
