import Foundation
import Testing
@testable import VoiceLabCore

struct AppUpdateConfigurationTests {
    private let key = Data(repeating: 42, count: 32).base64EncodedString()

    @Test func acceptsPublicHTTPSFeedAndKnownChannels() {
        for channel in ["stable", "beta", "test"] {
            let config = AppUpdateConfiguration(
                feedURL: "https://updates.example.test/echo/\(channel)/appcast.xml", publicKey: key, channel: channel)
            #expect(config?.channel == channel)
            #expect(config?.publicKey == key)
        }
    }

    @Test(arguments: ["", "$(ECHO_UPDATE_FEED_URL)", "http://updates.example.test/appcast.xml",
        "file:///tmp/appcast.xml", "https://user:secret@example.test/appcast.xml",
        "https://example.test/appcast.xml?token=secret", "https://example.test/appcast.xml#fragment", "https://example.test"])
    func rejectsUnsafeOrUnconfiguredFeed(feed: String) {
        #expect(AppUpdateConfiguration(feedURL: feed, publicKey: key, channel: "stable") == nil)
    }

    @Test(arguments: ["", "not-base64", Data(repeating: 1, count: 31).base64EncodedString(),
                      Data(repeating: 1, count: 64).base64EncodedString()])
    func rejectsMalformedPublicKeys(publicKey: String) {
        #expect(AppUpdateConfiguration(feedURL: "https://example.test/appcast.xml", publicKey: publicKey, channel: "stable") == nil)
    }

    @Test func rejectsUnknownChannel() {
        #expect(AppUpdateConfiguration(feedURL: "https://example.test/appcast.xml", publicKey: key, channel: "release") == nil)
    }
}
