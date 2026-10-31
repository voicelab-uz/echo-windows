import Foundation

/// Trusted origins travel together so credentials and browser consent cannot
/// accidentally use different environments. All builds use production.
public struct ServerEnvironment: Sendable {
    public let apiOrigin: URL
    public let websiteOrigin: URL
    public let storageNamespace: String

    public static let production = ServerEnvironment(
        apiOrigin: URL(string: "https://api.voicelab.uz")!,
        websiteOrigin: URL(string: "https://voicelab.uz")!, storageNamespace: "")

    public var desktopBillingURL: URL {
        websiteOrigin.appending(path: "app/billing")
            .appending(queryItems: [URLQueryItem(name: "source", value: "desktop")])
    }

    public func allowsAuthorizationURL(_ url: URL) -> Bool {
        url.scheme == websiteOrigin.scheme && url.host == websiteOrigin.host
            && url.port == websiteOrigin.port && url.user == nil && url.password == nil
            && url.fragment == nil && url.path == "/app/sign-in"
    }
}
