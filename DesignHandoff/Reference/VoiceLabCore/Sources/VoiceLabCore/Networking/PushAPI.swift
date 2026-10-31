import Foundation

public enum PushEnvironment: String, Codable, Sendable { case development, production }

public enum PushCategory: String, Codable, CaseIterable, Sendable { case important, news }

public struct PushPreferences: Codable, Equatable, Sendable {
    public var important: Bool
    public var news: Bool
    public var hasEnabledCategory: Bool { important || news }
    public init(important: Bool = true, news: Bool = true) {
        self.important = important
        self.news = news
    }
    public subscript(category: PushCategory) -> Bool {
        get { category == .important ? important : news }
        set {
            if category == .important { important = newValue }
            else { news = newValue }
        }
    }
}

public struct PushRegistration: Codable, Equatable, Sendable {
    public let token: String
    public let environment: PushEnvironment
    // Explicit topic prevents an upgraded Echo token from being associated with
    // the retired VoiceLab APNs provider. Never retry by omitting this field.
    public let topic: String
    public var preferences: PushPreferences
    public init(token: Data, environment: PushEnvironment, preferences: PushPreferences = .init()) {
        self.token = token.map { String(format: "%02x", $0) }.joined()
        self.environment = environment
        self.topic = "uz.voicelab.desktop"
        self.preferences = preferences
    }
}

public protocol PushServing: Sendable {
    func registerPush(_ registration: PushRegistration, accountID: String) async throws
    func unregisterPush(accountID: String) async throws
}

extension DesktopAPI: PushServing {
    public func registerPush(_ registration: PushRegistration, accountID: String) async throws {
        _ = try await request("/v1/desktop/push/device", method: "PUT",
                              body: JSONEncoder().encode(registration), accountID: accountID)
    }
    public func unregisterPush(accountID: String) async throws {
        _ = try await request("/v1/desktop/push/device", method: "DELETE", accountID: accountID)
    }
}

/// Only internal, allowlisted destinations can be opened by a remote payload.
public struct PushRoute: Equatable, Sendable {
    public enum Destination: String, Sendable { case home, notes, vocabulary, settings }
    public let accountID: String
    public let destination: Destination
    public let category: PushCategory
    public init?(userInfo: [AnyHashable: Any]) {
        guard let owner = userInfo["account_id"] as? String, !owner.isEmpty,
              let value = userInfo["destination"] as? String,
              let destination = Destination(rawValue: value) else { return nil }
        if let value = userInfo["category"] {
            guard let raw = value as? String, let category = PushCategory(rawValue: raw) else { return nil }
            self.category = category
        } else { category = .important }
        accountID = owner
        self.destination = destination
    }
}
