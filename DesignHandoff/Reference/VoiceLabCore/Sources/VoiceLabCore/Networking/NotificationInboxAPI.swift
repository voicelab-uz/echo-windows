import Foundation

public struct InboxNotification: Codable, Identifiable, Equatable, Sendable {
    public let id: String
    public let title: String
    public let body: String
    public let destination: String
    public let createdAt: String
    public var read: Bool
    public let category: PushCategory
    private enum CodingKeys: String, CodingKey { case id, title, body, destination, createdAt, read, category }
    public init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        id = try values.decode(String.self, forKey: .id)
        title = try values.decode(String.self, forKey: .title)
        body = try values.decode(String.self, forKey: .body)
        destination = try values.decode(String.self, forKey: .destination)
        createdAt = try values.decode(String.self, forKey: .createdAt)
        read = try values.decode(Bool.self, forKey: .read)
        category = try values.decodeIfPresent(PushCategory.self, forKey: .category) ?? .important
    }
    public var date: Date? {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.date(from: createdAt) ?? ISO8601DateFormatter().date(from: createdAt)
    }
}
public struct NotificationInboxPage: Decodable, Sendable {
    public let items: [InboxNotification]
    public let nextCursor: String
    public let throughCursor: String
    public let unread: Int
}
public protocol NotificationInboxServing: Sendable {
    func notifications(cursor: String, accountID: String) async throws -> NotificationInboxPage
    func readNotification(id: String?, throughCursor: String?, accountID: String) async throws
}
extension DesktopAPI: NotificationInboxServing {
    public func notifications(cursor: String = "", accountID: String) async throws -> NotificationInboxPage {
        guard cursor.isEmpty || Int64(cursor).map({ $0 > 0 }) == true else { throw VoiceLabError.invalidResponse }
        let suffix = cursor.isEmpty ? "" : "?cursor=\(cursor)"
        let data = try await request("/v1/desktop/notifications" + suffix, accountID: accountID)
        let page = try HTTPClient.decode(NotificationInboxPage.self, data: data)
        guard page.items.count <= 20, page.unread >= 0, Set(page.items.map(\.id)).count == page.items.count,
              [page.nextCursor, page.throughCursor].allSatisfy({ $0.isEmpty || Int64($0).map { $0 > 0 } == true }),
              page.items.allSatisfy({ UUID(uuidString: $0.id) != nil && $0.date != nil && PushRoute.Destination(rawValue: $0.destination) != nil })
        else { throw VoiceLabError.invalidResponse }
        return page
    }
    public func readNotification(id: String?, throughCursor: String?, accountID: String) async throws {
        guard (id == nil) != (throughCursor == nil),
              id.map({ UUID(uuidString: $0) != nil }) ?? true,
              throughCursor.map({ Int64($0).map { $0 > 0 } == true }) ?? true else { throw VoiceLabError.invalidResponse }
        var body: [String: String] = [:]
        body["id"] = id
        body["through_cursor"] = throughCursor
        _ = try await request("/v1/desktop/notifications/read", method: "POST",
                              body: JSONEncoder().encode(body), accountID: accountID)
    }
}
