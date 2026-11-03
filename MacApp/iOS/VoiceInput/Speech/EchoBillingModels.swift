import Foundation

enum EchoBilling {
    static let base = "/api/v1/billing/paylov"

    /// Successful read access is scoped to the endpoint that granted it. A failed
    /// payment-history read must not revoke a verified owner's card-management UI.
    struct Access: Sendable {
        var identityVerified = false
        var cardsVerified = false
        var accountSubscriptionVerified = false
        var cardSubscriptionVerified = false
        var pendingCheckoutVerified = false
        var canManageCards: Bool { identityVerified && cardsVerified }
        var canPurchaseLocal: Bool { canManageCards && accountSubscriptionVerified && cardSubscriptionVerified && pendingCheckoutVerified }
        var canPurchaseHosted: Bool { identityVerified && accountSubscriptionVerified && pendingCheckoutVerified }
    }

    struct Pricing: Decodable, Sendable {
        let enabled: Bool
        let cardSubscriptions: CardCatalog
        let subscriptionOffers: [HostedOffer]
    }
    struct HostedOffer: Decodable, Sendable {
        let packageCode: String
        let planCode: String
        let name: String
        let billingInterval: String
        let billingIntervalCount: Int
        let priceCents: Int64
        let currency: String
        let checkoutOptions: [CheckoutOption]
        var price: String { EchoBilling.money(priceCents, currency: currency) }
        var available: Bool { priceCents > 0 && checkoutOptions.contains { $0.provider == "polar" && $0.kind == "subscription" } }
    }
    struct CheckoutOption: Decodable, Sendable { let provider: String; let kind: String }
    struct HostedCheckout: Decodable, Identifiable, Sendable {
        let checkoutId: String
        let checkoutUrl: String
        var id: String { checkoutId }
        var url: URL? { EchoBilling.polarURL(checkoutUrl) }
    }
    struct PendingCheckoutReply: Decodable, Sendable { let pendingCheckout: PendingCheckout? }
    struct PendingCheckout: Decodable, Sendable {
        let checkoutId: String?
        let checkoutUrl: String?
        let packageCode: String?
        let planCode: String?
        let planName: String?
        let billingInterval: String?
        let billingIntervalCount: Int?
        let status: String
        let expiresAt: String?
        let canResume: Bool
        var resumableCheckout: HostedCheckout? {
            guard canResume, status == "open", let id = checkoutId, !id.isEmpty,
                  let raw = checkoutUrl, EchoBilling.polarURL(raw) != nil,
                  let expiry = expiresAt.flatMap(EchoBilling.timestamp), expiry > .now else { return nil }
            return HostedCheckout(checkoutId: id, checkoutUrl: raw)
        }
    }
    static func polarURL(_ raw: String) -> URL? {
        guard let value = URL(string: raw), value.scheme == "https",
              ["polar.sh", "sandbox.polar.sh"].contains(value.host ?? ""),
              value.user == nil, value.password == nil, value.port == nil,
              value.fragment == nil else { return nil }
        return value
    }
    static func timestamp(_ raw: String) -> Date? {
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return fractional.date(from: raw) ?? ISO8601DateFormatter().date(from: raw)
    }
    static func expiryDate(_ raw: String) -> String {
        guard let value = timestamp(raw) else { return raw }
        return value.formatted(date: .abbreviated, time: .standard)
    }
    struct HostedCheckoutBody: Encodable {
        let kind = "subscription"
        let code: String
    }
    struct AccountReply: Decodable, Sendable {
        let provider: String?
        let subscription: AccountSubscription?
    }
    struct AccountSubscription: Decodable, Sendable {
        let id: String
        let planName: String
        let status: String
        let cancelAtPeriodEnd: Bool
        let periodEndsAt: String
        var isCurrent: Bool { !["canceled", "cancelled", "expired"].contains(status) }
    }
    struct CardCatalog: Decodable, Sendable {
        let enabled: Bool
        let maxCards: Int
        let offers: [Offer]
    }
    struct Offer: Decodable, Identifiable, Sendable {
        var id: String { packageCode }
        let packageCode: String
        let planCode: String
        let name: String
        let billingInterval: String
        let billingIntervalCount: Int
        let credits: Int64
        let amountMinor: Int64
        let currency: String
        let sortOrder: Int
        var price: String { EchoBilling.money(amountMinor, currency: currency) }
        var purchasable: Bool { amountMinor > 0 && amountMinor % 100 == 0 && currency == "UZS" }
    }
    struct CardsReply: Decodable, Sendable { let cards: [Card]; let maxCards: Int }
    struct CardReply: Decodable, Sendable { let card: Card }
    struct Card: Decodable, Identifiable, Sendable, Equatable {
        let id: String
        let maskedNumber: String
        let holder: String
        let vendor: String
        let expireDate: String
        let isDefault: Bool
        let inUse: Bool
    }
    struct EnrollmentReply: Decodable, Sendable { let enrollment: Enrollment }
    struct Enrollment: Decodable, Sendable {
        let enrollmentId: String
        let phoneHint: String
        let expiresAt: String
    }
    struct SubscriptionReply: Decodable, Sendable { let subscription: Subscription? }
    struct Subscription: Decodable, Sendable {
        let id: String
        let packageCode: String
        let planName: String
        let billingInterval: String
        let billingIntervalCount: Int
        let amountMinor: Int64
        let currency: String
        let status: String
        let cancelAtPeriodEnd: Bool
        let periodEndsAt: String
        let changePending: Bool
        let card: CardSummary
        var isProcessing: Bool { status == "incomplete" || changePending }
        var isCurrent: Bool { !["canceled", "cancelled", "expired"].contains(status) }
    }
    struct CardSummary: Decodable, Sendable {
        let id: String
        let maskedNumber: String
        let vendor: String
    }
    struct PaymentsReply: Decodable, Sendable { let payments: [Payment] }
    struct Payment: Decodable, Identifiable, Sendable {
        let id: String
        let planName: String
        let kind: String
        let amountMinor: Int64
        let currency: String
        let status: String
        let cardMasked: String
        let paidAt: String?
        let createdAt: String
    }
    struct PreviewReply: Decodable, Sendable { let preview: Preview }
    struct Preview: Decodable, Sendable { let defaultTiming: String; let quotes: [Quote] }
    struct Quote: Decodable, Identifiable, Sendable {
        let id: String
        let timing: String
        let planName: String
        let amountDueMinor: Int64
        let priceMinor: Int64
        let effectiveAt: String
        let expiresAt: String
    }

    /// Contains no PAN, OTP, token or phone number. Restoring this intent keeps a
    /// network retry attached to the same accepted price and payment identity.
    struct PurchaseIntent: Codable, Sendable, Equatable {
        let packageCode: String
        let cardId: String
        let expectedAmountMinor: Int64
        let expectedRegularAmountMinor: Int64
        let idempotencyKey: String
        let createdAt: Date
        var serverSubscriptionId: String? = nil
        init(offer: Offer, card: Card) {
            packageCode = offer.packageCode; cardId = card.id
            expectedAmountMinor = offer.amountMinor
            expectedRegularAmountMinor = offer.amountMinor
            idempotencyKey = "echo_" + UUID().uuidString
            createdAt = .now
        }
        var canRetry: Bool { let age = Date.now.timeIntervalSince(createdAt); return age >= 0 && age < 14 * 60 }
    }
    private struct PurchaseBody: Encodable {
        let packageCode: String; let cardId: String
        let expectedAmountMinor: Int64; let expectedRegularAmountMinor: Int64
    }

    static func decode<T: Decodable>(_ type: T.Type, data: Data) throws -> T {
        let decoder = JSONDecoder(); decoder.keyDecodingStrategy = .convertFromSnakeCase
        return try decoder.decode(type, from: data)
    }
    static func body<T: Encodable>(_ value: T) throws -> Data {
        let encoder = JSONEncoder(); encoder.keyEncodingStrategy = .convertToSnakeCase
        encoder.outputFormatting = .sortedKeys
        return try encoder.encode(value)
    }
    static func purchaseBody(_ intent: PurchaseIntent) throws -> Data {
        try body(PurchaseBody(packageCode: intent.packageCode, cardId: intent.cardId,
                              expectedAmountMinor: intent.expectedAmountMinor,
                              expectedRegularAmountMinor: intent.expectedRegularAmountMinor))
    }
    static func money(_ minor: Int64, currency: String) -> String {
        let formatter = NumberFormatter()
        formatter.numberStyle = .currency; formatter.currencyCode = currency
        formatter.locale = Locale(identifier: "uz_UZ")
        formatter.maximumFractionDigits = currency == "UZS" && minor % 100 == 0 ? 0 : 2
        formatter.minimumFractionDigits = formatter.maximumFractionDigits
        let value = NSDecimalNumber(decimal: Decimal(minor) / 100)
        return formatter.string(from: value) ?? "\(value.stringValue) \(currency)"
    }
    static func date(_ raw: String) -> String {
        let fractional = ISO8601DateFormatter(); fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        guard let date = fractional.date(from: raw) ?? ISO8601DateFormatter().date(from: raw) else { return raw }
        return date.formatted(date: .abbreviated, time: .omitted)
    }
    static func digits(_ value: String) -> String { String(value.filter { $0 >= "0" && $0 <= "9" }) }
    static func validCard(_ value: String) -> Bool {
        let digits = digits(value)
        guard digits.count == 16, digits != String(repeating: "0", count: 16) else { return false }
        let sum = digits.reversed().enumerated().reduce(0) { sum, item in
            let n = item.element.wholeNumberValue ?? 0
            let value = item.offset.isMultiple(of: 2) ? n : n * 2
            return sum + (value > 9 ? value - 9 : value)
        }
        return sum.isMultiple(of: 10)
    }
    static func expiry(_ display: String, now: Date = .now) -> String? {
        let numbers = digits(display)
        guard numbers.count == 4, let month = Int(numbers.prefix(2)), (1...12).contains(month),
              let shortYear = Int(numbers.suffix(2)) else { return nil }
        let year = 2000 + shortYear
        let current = Calendar(identifier: .gregorian).dateComponents([.year, .month], from: now)
        guard year > (current.year ?? 0) || year == current.year && month >= (current.month ?? 1) else { return nil }
        return String(numbers.suffix(2) + numbers.prefix(2))
    }
}

actor EchoBillingService {
    func request<T: Decodable & Sendable>(_ type: T.Type, path: String,
                                         method: String = "GET", body: Data? = nil,
                                         key: String? = nil) async throws -> T {
        let data = try await EchoAuthClient.shared.billingRequest(path: path, method: method,
                                                                 body: body, idempotencyKey: key)
        return try EchoBilling.decode(type, data: data)
    }
    func mutate(path: String, method: String, body: Data? = nil) async throws {
        _ = try await EchoAuthClient.shared.billingRequest(path: path, method: method, body: body, idempotencyKey: nil)
    }
}
