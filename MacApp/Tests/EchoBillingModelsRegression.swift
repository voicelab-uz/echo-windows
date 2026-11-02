import Foundation

// Transport adapter only: production request construction and dispatch are
// extracted by the script; private token access deliberately fails in this fixture.
enum EchoAuthError: Error { case signedOut, invalidResponse, server(Int) }
enum EchoAuthDiagnostics {
    static func recordHTTP(path: String, response: HTTPURLResponse, data: Data) {}
}
actor BillingProbeTransport {
    private(set) var requests: [URLRequest] = []
    func data(for request: URLRequest) async throws -> (Data, URLResponse) {
        requests.append(request)
        let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
        return (Data("public-catalog".utf8), response)
    }
}
actor EchoAuthClient {
    static let shared = EchoAuthClient()
    static let apiOrigin = URL(string: "https://api.voicelab.uz")!
    let transport = BillingProbeTransport()
    private(set) var privateAuthAttempts = 0
    func authenticatedRequest(_ path: String, method: String = "GET", body: Data? = nil,
                              idempotencyKey: String? = nil) async throws -> Data {
        privateAuthAttempts += 1
        throw EchoAuthError.signedOut
    }
}

@main struct EchoBillingModelsRegression {
    static func main() async throws {
        let publicData = try await EchoAuthClient.shared.billingRequest(path: "/api/v1/billing/pricing")
        precondition(String(decoding: publicData, as: UTF8.self) == "public-catalog")
        let tokenAttempts = await EchoAuthClient.shared.privateAuthAttempts
        precondition(tokenAttempts == 0, "Public prices must load even when no private session token exists")
        do {
            _ = try await EchoAuthClient.shared.billingRequest(path: "/api/v1/billing/paylov/cards")
            preconditionFailure("Private card API bypassed token acquisition")
        } catch EchoAuthError.signedOut {}
        let publicRequest = EchoAuthClient.publicBillingPricingRequest()
        precondition(publicRequest.url?.absoluteString == "https://api.voicelab.uz/api/v1/billing/pricing")
        precondition(publicRequest.httpMethod == "GET" && publicRequest.httpBody == nil)
        precondition(publicRequest.value(forHTTPHeaderField: "Accept") == "application/json")
        precondition(publicRequest.value(forHTTPHeaderField: "Authorization") == nil,
                     "Public catalog must not depend on an authenticated token")
        var access = EchoBilling.Access()
        precondition(!access.canManageCards && !access.canPurchaseLocal && !access.canPurchaseHosted)
        access.identityVerified = true
        precondition(!access.canManageCards, "Restored identity alone must not authorize Add Card")
        access.cardsVerified = true
        precondition(access.canManageCards && !access.canPurchaseLocal && !access.canPurchaseHosted,
                     "A successful owner card read should allow Add Card even when subscription/history reads fail")
        access.accountSubscriptionVerified = true
        access.cardSubscriptionVerified = true
        precondition(!access.canPurchaseLocal && !access.canPurchaseHosted)
        access.pendingCheckoutVerified = true
        precondition(access.canPurchaseHosted && access.canPurchaseLocal)
        access.identityVerified = false
        precondition(!access.canManageCards && !access.canPurchaseLocal && !access.canPurchaseHosted,
                     "A changed identity must revoke every mutation gate")
        let emptyCards = try EchoBilling.decode(EchoBilling.CardsReply.self, data: Data(#"{"cards":[],"max_cards":5}"#.utf8))
        let emptyPayments = try EchoBilling.decode(EchoBilling.PaymentsReply.self, data: Data(#"{"payments":[]}"#.utf8))
        precondition(emptyCards.cards.isEmpty && emptyPayments.payments.isEmpty)
        if CommandLine.arguments.count > 1 {
            let live = try EchoBilling.decode(EchoBilling.Pricing.self, data: Data(contentsOf: URL(fileURLWithPath: CommandLine.arguments[1])))
            precondition(live.enabled && live.cardSubscriptions.enabled)
            precondition(live.cardSubscriptions.offers.filter { $0.planCode == "starter" }.count == 2)
            precondition(live.subscriptionOffers.filter { $0.planCode == "starter" && $0.available }.count == 2)
        }
        let catalog = try EchoBilling.decode(EchoBilling.Pricing.self, data: Data(#"{"enabled":true,"subscription_offers":[{"package_code":"starter-usd-month","plan_code":"starter","name":"Starter","billing_interval":"month","billing_interval_count":1,"price_cents":500,"currency":"USD","checkout_options":[{"provider":"polar","kind":"subscription"}]}],"card_subscriptions":{"enabled":true,"provider":"paylov","max_cards":5,"offers":[{"package_code":"starter-month","plan_code":"starter","name":"Starter","billing_interval":"month","billing_interval_count":1,"credits":1000000,"amount_minor":6000000,"currency":"UZS","sort_order":1}]}}"#.utf8))
        let hosted = catalog.subscriptionOffers[0]
        precondition(hosted.available && hosted.priceCents == 500)
        let checkoutBody = try JSONSerialization.jsonObject(with: EchoBilling.body(EchoBilling.HostedCheckoutBody(code: hosted.packageCode))) as! [String: String]
        precondition(checkoutBody == ["kind": "subscription", "code": "starter-usd-month"])
        let checkout = try EchoBilling.decode(EchoBilling.HostedCheckout.self, data: Data(#"{"checkout_id":"test","checkout_url":"https://polar.sh/checkout/example","expires_at":null}"#.utf8))
        precondition(checkout.url?.scheme == "https")
        let unsafe = try EchoBilling.decode(EchoBilling.HostedCheckout.self, data: Data(#"{"checkout_id":"test","checkout_url":"http://polar.sh/checkout/example"}"#.utf8))
        precondition(unsafe.url == nil)
        let noPending = try EchoBilling.decode(EchoBilling.PendingCheckoutReply.self, data: Data(#"{"pending_checkout":null,"request_id":"r"}"#.utf8))
        precondition(noPending.pendingCheckout == nil)
        let future = ISO8601DateFormatter().string(from: Date.now.addingTimeInterval(3600))
        let pendingJSON = "{\"pending_checkout\":{\"checkout_id\":\"prior-yearly\",\"checkout_url\":\"https://polar.sh/checkout/prior\",\"package_code\":\"starter-yearly\",\"plan_name\":\"Starter\",\"billing_interval\":\"year\",\"billing_interval_count\":1,\"status\":\"open\",\"expires_at\":\"\(future)\",\"can_resume\":true}}"
        let previous = try EchoBilling.decode(EchoBilling.PendingCheckoutReply.self, data: Data(pendingJSON.utf8)).pendingCheckout!
        precondition(previous.billingInterval == "year" && previous.resumableCheckout?.checkoutId == "prior-yearly")
        for changed in [pendingJSON.replacingOccurrences(of: "\"can_resume\":true", with: "\"can_resume\":false"),
                        pendingJSON.replacingOccurrences(of: "\"status\":\"open\"", with: "\"status\":\"confirmed\""),
                        pendingJSON.replacingOccurrences(of: future, with: "2020-01-01T00:00:00Z"),
                        pendingJSON.replacingOccurrences(of: "https://polar.sh/", with: "https://evil.example/"),
                        pendingJSON.replacingOccurrences(of: "https://polar.sh/", with: "https://polar.sh.evil.example/"),
                        pendingJSON.replacingOccurrences(of: "https://polar.sh/", with: "https://person@polar.sh/"),
                        pendingJSON.replacingOccurrences(of: "https://polar.sh/", with: "https://polar.sh:444/"),
                        pendingJSON.replacingOccurrences(of: "/checkout/prior", with: "/checkout/prior#secret")] {
            let denied = try EchoBilling.decode(EchoBilling.PendingCheckoutReply.self, data: Data(changed.utf8))
            precondition(denied.pendingCheckout?.resumableCheckout == nil)
        }
        let unknown = try EchoBilling.decode(EchoBilling.PendingCheckoutReply.self, data: Data(#"{"pending_checkout":{"status":"unknown","expires_at":null,"can_resume":false}}"#.utf8))
        precondition(unknown.pendingCheckout?.resumableCheckout == nil)
        let account = try EchoBilling.decode(EchoBilling.AccountReply.self, data: Data(#"{"provider":"polar","subscription":{"id":"s1","plan_name":"Starter","status":"active","cancel_at_period_end":false,"period_ends_at":"2026-12-26T12:00:00Z"}}"#.utf8))
        precondition(account.subscription?.isCurrent == true)
        let offer = catalog.cardSubscriptions.offers[0]
        precondition(offer.purchasable && offer.amountMinor == 6_000_000)
        let cards = try EchoBilling.decode(EchoBilling.CardsReply.self, data: Data(#"{"cards":[{"id":"pcd_test","masked_number":"8600 **** **** 1234","holder":"TEST USER","vendor":"UZCARD","expire_date":"2912","is_default":true,"in_use":false}],"max_cards":5}"#.utf8))
        let card = cards.cards[0]
        precondition(card.isDefault && !card.inUse && card.maskedNumber == "8600 **** **** 1234")
        let intent = EchoBilling.PurchaseIntent(offer: offer, card: card)
        let restored = try JSONDecoder().decode(EchoBilling.PurchaseIntent.self, from: JSONEncoder().encode(intent))
        precondition(restored.idempotencyKey == intent.idempotencyKey && restored == intent)
        let originalBody = try EchoBilling.purchaseBody(intent)
        let restoredBody = try EchoBilling.purchaseBody(restored)
        precondition(originalBody == restoredBody)
        let body = try JSONSerialization.jsonObject(with: EchoBilling.purchaseBody(intent)) as! [String: Any]
        precondition(Set(body.keys) == ["package_code", "card_id", "expected_amount_minor", "expected_regular_amount_minor"])
        precondition(body["expected_amount_minor"] as? Int64 == 6_000_000)
        precondition(body["expected_regular_amount_minor"] as? Int64 == 6_000_000)
        let persisted = String(decoding: try JSONEncoder().encode(intent), as: UTF8.self)
        precondition(!persisted.contains("masked") && !persisted.contains("1234") && !persisted.contains("otp"))
        let missing = try EchoBilling.decode(EchoBilling.SubscriptionReply.self, data: Data(#"{"subscription":null}"#.utf8))
        precondition(missing.subscription == nil)
        let pending = try EchoBilling.decode(EchoBilling.SubscriptionReply.self, data: Data(#"{"subscription":{"id":"psb_test","package_code":"starter-month","plan_name":"Starter","billing_interval":"month","billing_interval_count":1,"amount_minor":6000000,"currency":"UZS","status":"incomplete","cancel_at_period_end":false,"period_ends_at":"2026-12-26T12:00:00Z","change_pending":false,"card":{"id":"pcd_test","masked_number":"8600 **** **** 1234","vendor":"UZCARD"}}}"#.utf8))
        precondition(pending.subscription?.isProcessing == true)
        precondition(EchoBilling.validCard("4111 1111 1111 1111"))
        precondition(!EchoBilling.validCard("4111 1111 1111 1112"))
        precondition(!EchoBilling.validCard("0000000000000000"))
        precondition(!EchoBilling.validCard("４１１１１１１１１１１１１１１１"))
        let date = ISO8601DateFormatter().date(from: "2026-10-26T12:00:00Z")!
        precondition(EchoBilling.expiry("12/29", now: date) == "2912")
        precondition(EchoBilling.expiry("09/26", now: date) == nil)
        precondition(EchoBilling.expiry("13/29", now: date) == nil)
        precondition(EchoBilling.expiry("10/26", now: date) == "2610")
        precondition(!offer.price.isEmpty && !offer.price.contains("6000000"))
        print("Echo billing catalog, prices, payment identity, and card validation regressions passed")
    }
}
