import Foundation

/// Distributed builds accept only public, signed HTTPS feeds.
public struct AppUpdateConfiguration: Sendable, Equatable {
    public let feedURL: URL
    public let publicKey: String
    public let channel: String

    public init?(feedURL: String, publicKey: String, channel: String) {
        guard let parts = URLComponents(string: feedURL),
            parts.scheme?.lowercased() == "https",
            let host = parts.host, !host.isEmpty,
            parts.user == nil, parts.password == nil,
            parts.query == nil, parts.fragment == nil,
            !parts.path.isEmpty, let url = parts.url,
            let key = Data(base64Encoded: publicKey), key.count == 32,
            ["stable", "beta", "test"].contains(channel)
        else { return nil }
        self.feedURL = url
        self.publicKey = publicKey
        self.channel = channel
    }
}
