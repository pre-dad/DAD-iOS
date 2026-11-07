import Foundation
import OpenAPIRuntime

/// One Idempotency-Key per distinct giving command, held until the command reaches a definitive
/// outcome. A command that ends in a timeout, a 429, a 503 or a lost response is retried with the
/// SAME key (the server then returns the original outcome and never repeats the effect); a success
/// or a definitive refusal (403/409/422) retires the key so the next command is a fresh one.
final class IdempotencyLedger: @unchecked Sendable {
    private let lock = NSLock()
    private var keys: [String: String] = [:]
    func key(for fingerprint: String) -> String {
        lock.withLock {
            if let existing = keys[fingerprint] { return existing }
            let fresh = UUID().uuidString.lowercased()   // a version 4 UUID, as the contract requires
            keys[fingerprint] = fresh
            return fresh
        }
    }
    func settle(_ fingerprint: String) { lock.withLock { keys[fingerprint] = nil } }
}

/// Real giving service (PRD G-1..G-11) over the generated client: `recurring`, `amountOptions`,
/// `changeAmount`, `cancelRecurring`, `paymentMethod` and `beginPaymentUpdate`, each authorized
/// through the session (single refresh + one retry on 401). The app never handles card data: card
/// entry happens on a Stripe-hosted page that the screen opens in the system's secure browser view.
///
/// Status mapping: 401 -> signed out; 403 -> forbidden (giving unavailable for this account);
/// 409 -> conflict (billing moved; the model re-reads); 422 -> invalid input; 429 (with or without a
/// body: the ingress limiter sends none) -> rate limited; 503 with a `code` -> payments not
/// configured (do not retry); any other 503/413/415/undocumented status or a body that does not
/// decode -> unavailable. Cancellation propagates untouched so the model keeps its prior state.
///
/// Starting a NEW gift (contract 2.6.0): `startRecurringCheckout` mints a Stripe-hosted Checkout
/// session for the signed-in donor and the amount they chose; the app opens the returned `https` url
/// in the secure browser view and then re-reads `recurring` (the return page does not prove payment).
/// The referral token a link visit kept (contract 2.10) goes with it, crediting the referrer as the
/// website's cookie would.
public struct WireGiving: GivingService {
    private let product: ProductClient
    private let ledger: IdempotencyLedger
    private let referral: @Sendable () -> String?

    public init(origin: URL, session: AccountSession, referral: @escaping @Sendable () -> String? = { nil }) throws {
        self.init(product: try ProductClient(origin: origin, session: session), referral: referral)
    }

    init(product: ProductClient, ledger: IdempotencyLedger = IdempotencyLedger(), referral: @escaping @Sendable () -> String? = { nil }) {
        self.product = product; self.ledger = ledger; self.referral = referral
    }

    public func recurring() async throws -> RecurringState {
        try await product.call { client in
            switch try await client.recurring(.init()) {
            case .ok(let response): return Self.state(try response.body.json)
            case .unauthorized: throw AccountError.signedOut
            case .tooManyRequests: throw AccountError.rateLimited
            case .undocumented(let status, _): throw AccountError.forStatus(status)
            default: throw AccountError.unavailable
            }
        }
    }

    public func amountOffer() async throws -> AmountOffer? {
        try await product.call { client in
            switch try await client.amountOptions(.init()) {
            case .ok(let response):
                switch try response.body.json {
                case .case1: return nil
                case .case2(let value):
                    return AmountOffer(
                        subscriptionID: value.subscription_id, nextAmountMinor: Int(clamping: value.amount_minor),
                        effectiveAt: value.effective_at,
                        pending: value.change.map {
                            AmountOffer.Pending(amountMinor: Int(clamping: $0.amount_minor), previousMinor: Int(clamping: $0.previous_minor),
                                                effectiveAt: $0.effective_at, confirmed: $0.confirmed)
                        })
                }
            case .unauthorized: throw AccountError.signedOut
            case .tooManyRequests: throw AccountError.rateLimited
            case .undocumented(let status, _): throw AccountError.forStatus(status)
            default: throw AccountError.unavailable
            }
        }
    }

    public func changeAmount(subscriptionID: String, to amountMinor: Int) async throws -> RecurringState {
        guard UUID(uuidString: subscriptionID) != nil, GiftAmount(monthlyMinor: amountMinor) != nil else { throw AccountError.invalidInput }
        // The command echoes what the matching GET returned, so read it fresh; a subscription that is
        // no longer the one on screen is a conflict, not something to send.
        guard let offer = try await amountOffer() else { throw AccountError.unavailable }
        guard offer.subscriptionID.lowercased() == subscriptionID.lowercased() else { throw AccountError.conflict }
        let body = Operations.changeAmount.Input.Body.jsonPayload(
            subscription_id: offer.subscriptionID, amount_minor: Int64(amountMinor),
            previous_minor: Int64(offer.nextAmountMinor), effective_at: offer.effectiveAt)
        let fingerprint = "amount:\(offer.subscriptionID):\(amountMinor):\(offer.nextAmountMinor):\(offer.effectiveAt.timeIntervalSince1970)"
        try await command(fingerprint) { key in
            try await self.product.call { client in
                switch try await client.changeAmount(.init(headers: .init(Idempotency_hyphen_Key: key), body: .json(body))) {
                case .ok: return
                case .unauthorized: throw AccountError.signedOut
                case .forbidden: throw AccountError.forbidden
                case .conflict: throw AccountError.conflict
                case .unprocessableContent: throw AccountError.invalidInput
                case .tooManyRequests: throw AccountError.rateLimited
                case .serviceUnavailable(let response): throw Self.unavailable(response)
                case .undocumented(let status, _): throw AccountError.forStatus(status)
                default: throw AccountError.unavailable
                }
            }
        }
        return try await recurring()
    }

    public func cancel(subscriptionID: String, periodEnd: Date) async throws -> RecurringState {
        guard UUID(uuidString: subscriptionID) != nil else { throw AccountError.invalidInput }
        let body = Operations.cancelRecurring.Input.Body.jsonPayload(subscription_id: subscriptionID, period_end: periodEnd)
        let fingerprint = "cancel:\(subscriptionID):\(periodEnd.timeIntervalSince1970)"
        return try await command(fingerprint) { key in
            try await self.product.call { client in
                switch try await client.cancelRecurring(.init(headers: .init(Idempotency_hyphen_Key: key), body: .json(body))) {
                case .ok(let response): return Self.state(try response.body.json)
                case .unauthorized: throw AccountError.signedOut
                case .forbidden: throw AccountError.forbidden
                case .conflict: throw AccountError.conflict
                case .unprocessableContent: throw AccountError.invalidInput
                case .tooManyRequests: throw AccountError.rateLimited
                case .serviceUnavailable(let response): throw Self.unavailable(response)
                case .undocumented(let status, _): throw AccountError.forStatus(status)
                default: throw AccountError.unavailable
                }
            }
        }
    }

    public func paymentMethod() async throws -> PaymentMethodState {
        try await product.call { client in
            switch try await client.paymentMethod(.init()) {
            case .ok(let response):
                let value = try response.body.json
                return PaymentMethodState(kind: Self.kind(value.status.rawValue), completedAt: value.completed_at)
            case .unauthorized: throw AccountError.signedOut
            case .tooManyRequests: throw AccountError.rateLimited
            case .undocumented(let status, _): throw AccountError.forStatus(status)
            default: throw AccountError.unavailable
            }
        }
    }

    public func beginPayment() async throws -> PaymentPath {
        try await command("payment-setup") { key in
            try await self.product.call { client in
                switch try await client.beginPaymentUpdate(.init(headers: .init(Idempotency_hyphen_Key: key))) {
                case .ok(let response):
                    switch try response.body.json {
                    case .case1(let value): return .webCheckoutHandoff(try Self.hostedURL(value.url))
                    case .case2(let value):
                        return .alreadyFinished(PaymentMethodState(kind: Self.kind(value.status.rawValue), completedAt: value.completed_at))
                    }
                case .unauthorized: throw AccountError.signedOut
                case .forbidden: throw AccountError.forbidden
                case .conflict: throw AccountError.conflict
                case .unprocessableContent: throw AccountError.invalidInput
                case .tooManyRequests: throw AccountError.rateLimited
                case .serviceUnavailable(let response): throw Self.unavailable(response)
                case .undocumented(let status, _): throw AccountError.forStatus(status)
                }
            }
        }
    }

    public func beginGift(amountMinor: Int) async throws -> PaymentPath {
        guard GiftAmount(monthlyMinor: amountMinor) != nil else { throw AccountError.invalidInput }
        // One key per distinct amount and referral: a retry of the same choice reuses it (the server returns
        // the same session), a different choice is a different checkout.
        let referral = referral()
        return try await command("gift-checkout:\(amountMinor):\(referralFingerprint(referral))") { key in
            try await self.product.call { client -> PaymentPath in
                let body = Operations.startRecurringCheckout.Input.Body.jsonPayload(amount_minor: Int64(amountMinor), referral_token: referral)
                switch try await client.startRecurringCheckout(.init(headers: .init(Idempotency_hyphen_Key: key), body: .json(body))) {
                case .created(let response): return .webCheckoutHandoff(try Self.hostedURL(try response.body.json.url))
                case .unauthorized: throw AccountError.signedOut
                case .forbidden: throw AccountError.forbidden
                case .conflict: throw AccountError.conflict
                case .unprocessableContent: throw AccountError.invalidInput
                case .tooManyRequests: throw AccountError.rateLimited
                case .serviceUnavailable(let response): throw Self.unavailable(response)
                case .undocumented(let status, _): throw AccountError.forStatus(status)
                default: throw AccountError.unavailable
                }
            }
        }
    }

    // MARK: - helpers

    private func command<T: Sendable>(_ fingerprint: String, _ run: (String) async throws -> T) async throws -> T {
        let key = ledger.key(for: fingerprint)
        do {
            let value = try await run(key)
            ledger.settle(fingerprint)
            return value
        } catch let error as AccountError {
            switch error {
            case .forbidden, .conflict, .invalidInput, .paymentsUnavailable, .signedOut: ledger.settle(fingerprint)
            default: break   // outcome unknown or retryable: the next attempt reuses the key
            }
            throw error
        }
    }

    /// A hosted page must be https with no embedded credentials; anything else is not opened.
    static func hostedURL(_ text: String) throws -> URL {
        guard let url = URL(string: text), url.scheme == "https", url.host?.isEmpty == false,
              url.user == nil, url.password == nil else { throw AccountError.invalidResponse }
        return url
    }

    private static func state(_ details: Components.Schemas.RecurringDetails) -> RecurringState {
        guard let sub = details.subscription else { return details.state == .preparing ? .preparing : .none }
        let amount = Int(clamping: sub.amount_minor)
        if let stops = sub.stops_at { return .ending(subscriptionID: sub.id, amountMinor: amount, periodEnd: sub.period_end, stopsAt: stops) }
        return .active(subscriptionID: sub.id, amountMinor: amount, periodEnd: sub.period_end)
    }

    private static func kind(_ raw: String) -> PaymentMethodState.Kind {
        PaymentMethodState.Kind(rawValue: raw.lowercased()) ?? .none
    }

    private static func unavailable(_ response: Components.Responses.Unavailable) -> AccountError {
        // A 503 with a `code` is a feature this deployment has not configured: do not retry.
        if let problem = try? response.body.json, problem.code != nil { return .paymentsUnavailable }
        return .unavailable
    }
}
