import Foundation
import HTTPTypes
import OpenAPIRuntime
import XCTest
@testable import DADFoundation

private let subID = "5d6f1d9e-0a5b-4e6f-8d0f-3f1c2a9b7c10"
private let periodEndText = "2026-11-20T00:00:00Z"
private let effectiveText = "2026-11-20T00:00:00Z"

func recurringJSON(amount: Int = 15000, stopsAt: String? = nil, status: String = "active") -> String {
    #"{"mode":"test","state":"ready","observed_at":"2026-10-31T12:00:00Z","subscription":{"amount_minor":\#(amount),"currency":"USD","id":"\#(subID)","period_end":"\#(periodEndText)","status":"\#(status)","stops_at":\#(stopsAt.map { "\"\($0)\"" } ?? "null")}}"#
}
let checkoutJSON = #"{"url":"https://checkout.stripe.com/c/pay/cs_1","session_id":"cs_1","expires_at":"2026-11-01T12:00:00Z"}"#
let noRecurringJSON = #"{"mode":"test","state":"ready","subscription":null}"#
func amountOptionsJSON(next: Int = 15000, change: String = "null") -> String {
    #"{"state":"ready","subscription_id":"\#(subID)","amount_minor":\#(next),"effective_at":"\#(effectiveText)","change":\#(change)}"#
}
func amountChangeJSON(amount: Int = 30000, previous: Int = 15000, confirmed: Bool = false) -> String {
    #"{"amount_minor":\#(amount),"previous_minor":\#(previous),"confirmed":\#(confirmed),"effective_at":"\#(effectiveText)","request_id":"11111111-2222-4333-8444-555555555555"}"#
}

final class WireGivingTests: XCTestCase {
    private typealias Rig = (service: WireGiving, session: AccountSession, store: MemoryStore)

    private func make(_ transport: ScriptedTransport) throws -> Rig {
        let store = MemoryStore(Credentials(access: "tok", refresh: "ref", expiresAt: .distantFuture))
        let session = try AccountSession(api: WireAPI(origin: testOrigin, transport: transport), store: store)
        return (WireGiving(product: ProductClient(origin: testOrigin, transport: transport, session: session)),
                session, store)
    }

    /// A scripted server for the amount change: GET offer, POST change, GET recurring.
    private func amountServer(post: @escaping @Sendable (ScriptedTransport.Seen, Int) -> ScriptedTransport.Reply = { _, _ in (.ok, amountChangeJSON()) }) -> ScriptedTransport {
        ScriptedTransport { seen, index in
            switch (seen.request.method, seen.request.path) {
            case (.get, "/donor/me/recurring/amount"): return (.ok, amountOptionsJSON())
            case (.post, "/donor/me/recurring/amount"): return post(seen, index)
            case (.get, "/donor/me/recurring"): return (.ok, recurringJSON(amount: 30000))
            default: return (.notFound, "{}")
            }
        }
    }

    private func idempotencyKey(_ seen: ScriptedTransport.Seen) -> String? { seen.request.headerFields[HTTPField.Name("Idempotency-Key")!] }

    // MARK: recurring

    func testActiveRecurringMapsWithBearerAndNativeHeader() async throws {
        let transport = ScriptedTransport { _, _ in (.ok, recurringJSON()) }
        let rig = try make(transport)
        let state = try await rig.service.recurring()
        guard case let .active(id, amount, end) = state else { return XCTFail("\(state)") }
        XCTAssertEqual(id, subID)
        XCTAssertEqual(amount, 15000)
        XCTAssertEqual(end.timeIntervalSince1970, 1_795_132_800)   // 2026-11-20T00:00:00Z
        let call = try XCTUnwrap(transport.seen.first)
        XCTAssertEqual(call.request.path, "/donor/me/recurring")
        XCTAssertEqual(call.request.headerFields[.authorization], "Bearer tok")
        XCTAssertEqual(call.request.headerFields[nativeClientHeader], "native")
    }

    func testStopsAtMakesTheGiftEnding() async throws {
        let rig = try make(ScriptedTransport { _, _ in (.ok, recurringJSON(stopsAt: "2026-11-20T00:00:00Z")) })
        let state = try await rig.service.recurring()
        XCTAssertTrue(state.isEnding)
        XCTAssertEqual(state.subscriptionID, subID)
    }

    func testNoSubscriptionAndPreparing() async throws {
        let none = try make(ScriptedTransport { _, _ in (.ok, noRecurringJSON) })
        let noneState = try await none.service.recurring()
        XCTAssertEqual(noneState, .none)
        let preparing = try make(ScriptedTransport { _, _ in (.ok, #"{"mode":"test","state":"preparing","subscription":null}"#) })
        let preparingState = try await preparing.service.recurring()
        XCTAssertEqual(preparingState, .preparing)
    }

    func testReadStatusMappingIncludingBodylessIngress429() async throws {
        let cases: [(HTTPResponse.Status, String, AccountError)] = [
            (.tooManyRequests, "", .rateLimited),   // the ingress limiter sends no body
            (.tooManyRequests, "{}", .rateLimited),
            (.serviceUnavailable, "{}", .unavailable),
            (.forbidden, "{}", .forbidden),
            (.internalServerError, "{}", .unavailable),
        ]
        for (status, body, expected) in cases {
            let rig = try make(ScriptedTransport { _, _ in (status, body) })
            do { _ = try await rig.service.recurring(); XCTFail("\(status)") }
            catch { XCTAssertEqual(error as? AccountError, expected, "\(status)") }
            XCTAssertNotNil(try rig.store.load(), "\(status) must not end the session")
        }
    }

    func testMalformedAndOversizeBodiesThrow() async throws {
        let bad = try make(ScriptedTransport { _, _ in (.ok, #"{"mode":"test","subscription":{"amount_minor":"lots"}}"#) })
        do { _ = try await bad.service.recurring(); XCTFail() } catch { assertBodyRejected(error) }
        let padding = String(repeating: "a", count: 1_100_000)
        let big = try make(ScriptedTransport { _, _ in (.ok, #"{"mode":"test","subscription":null,"pad":""# + padding + #""}"#) })
        do { _ = try await big.service.recurring(); XCTFail() } catch { assertBodyRejected(error) }
    }

    func testRecurring401RefreshesOnceThenSucceeds() async throws {
        let transport = ScriptedTransport { seen, _ in
            switch seen.request.path {
            case "/donor/refresh": return (.ok, freshSessionJSON)
            case "/donor/me/recurring":
                return seen.request.headerFields[.authorization] == "Bearer fresh" ? (.ok, recurringJSON()) : (.unauthorized, "{}")
            default: return (.notFound, "{}")
            }
        }
        let rig = try make(transport)
        _ = try await rig.service.recurring()
        XCTAssertEqual(transport.calls(to: "/donor/refresh").count, 1)
        XCTAssertEqual(transport.calls(to: "/donor/me/recurring").count, 2)
    }

    func testSecond401EndsTheSessionLocally() async throws {
        let rig = try make(ScriptedTransport { _, _ in (.unauthorized, "{}") })
        do { _ = try await rig.service.recurring(); XCTFail() }
        catch { XCTAssertEqual(error as? AccountError, .signedOut) }
        XCTAssertNil(try rig.store.load())
    }

    func testCancellationSurfacesAsCancellationAndKeepsTheSession() async throws {
        let gate = Gate()
        let transport = ScriptedTransport { _, _ in
            await gate.pass()
            try Task.checkCancellation()
            return (.ok, recurringJSON())
        }
        let rig = try make(transport)
        let task = Task { try await rig.service.recurring() }
        await gate.waitUntilEntered()
        task.cancel()
        await gate.release()
        do { _ = try await task.value; XCTFail() }
        catch { XCTAssertTrue(error.isCancellation, "\(error)") }
        XCTAssertNotNil(try rig.store.load())
    }

    // MARK: amount options

    func testAmountOfferMapsNextRenewalAndPendingChange() async throws {
        let change = #"{"amount_minor":30000,"previous_minor":15000,"confirmed":false,"effective_at":"2026-11-20T00:00:00Z","request_id":"11111111-2222-4333-8444-555555555555"}"#
        let rig = try make(ScriptedTransport { _, _ in (.ok, amountOptionsJSON(change: change)) })
        let offer = try await rig.service.amountOffer()
        XCTAssertEqual(offer?.subscriptionID, subID)
        XCTAssertEqual(offer?.nextAmountMinor, 15000)
        XCTAssertEqual(offer?.pending?.amountMinor, 30000)
        XCTAssertEqual(offer?.pending?.previousMinor, 15000)
        XCTAssertEqual(offer?.pending?.confirmed, false)
    }

    func testUnavailableOfferIsNilNotAnError() async throws {
        let rig = try make(ScriptedTransport { _, _ in (.ok, #"{"state":"unavailable"}"#) })
        let offer = try await rig.service.amountOffer()
        XCTAssertNil(offer)
    }

    // MARK: change amount

    func testChangeAmountEchoesTheOfferAndSendsAFreshV4Key() async throws {
        let transport = amountServer()
        let rig = try make(transport)
        let state = try await rig.service.changeAmount(subscriptionID: subID, to: 30000)
        XCTAssertEqual(state.amountMinor, 30000, "the result is the re-read recurring state")
        let post = try XCTUnwrap(transport.calls(to: "/donor/me/recurring/amount").first { $0.request.method == .post })
        let body = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(post.body.utf8)) as? [String: Any])
        XCTAssertEqual(body["subscription_id"] as? String, subID)
        XCTAssertEqual(body["amount_minor"] as? Int, 30000)
        XCTAssertEqual(body["previous_minor"] as? Int, 15000, "previous_minor is the next-renewal amount the GET returned")
        XCTAssertEqual(body["effective_at"] as? String, effectiveText)
        let key = try XCTUnwrap(idempotencyKey(post))
        let uuid = try XCTUnwrap(UUID(uuidString: key))
        XCTAssertEqual(key, uuid.uuidString.lowercased())
        XCTAssertEqual(key.dropFirst(14).first, "4", "the key is a version 4 UUID")
        XCTAssertEqual(post.request.headerFields[.authorization], "Bearer tok")
    }

    func testRetryAfterA503ReusesTheKeyAndASuccessRetiresIt() async throws {
        let transport = amountServer { _, index in index < 2 ? (.serviceUnavailable, "{}") : (.ok, amountChangeJSON()) }
        let rig = try make(transport)
        do { _ = try await rig.service.changeAmount(subscriptionID: subID, to: 30000); XCTFail() }
        catch { XCTAssertEqual(error as? AccountError, .unavailable) }
        _ = try await rig.service.changeAmount(subscriptionID: subID, to: 30000)
        let posts = transport.calls(to: "/donor/me/recurring/amount").filter { $0.request.method == .post }
        XCTAssertEqual(posts.count, 2)
        XCTAssertEqual(idempotencyKey(posts[0]), idempotencyKey(posts[1]), "a retry after a 503 reuses the key")
        _ = try await rig.service.changeAmount(subscriptionID: subID, to: 30000)
        let all = transport.calls(to: "/donor/me/recurring/amount").filter { $0.request.method == .post }
        XCTAssertNotEqual(idempotencyKey(all[1]), idempotencyKey(all[2]), "a completed command retires its key")
    }

    func testA401OnTheCommandRefreshesAndRetriesWithTheSameKey() async throws {
        let transport = ScriptedTransport { seen, _ in
            switch (seen.request.method, seen.request.path) {
            case (_, "/donor/refresh"): return (.ok, freshSessionJSON)
            case (.get, "/donor/me/recurring/amount"): return (.ok, amountOptionsJSON())
            case (.post, "/donor/me/recurring/amount"):
                return seen.request.headerFields[.authorization] == "Bearer fresh" ? (.ok, amountChangeJSON()) : (.unauthorized, "{}")
            case (.get, "/donor/me/recurring"): return (.ok, recurringJSON(amount: 30000))
            default: return (.notFound, "{}")
            }
        }
        let rig = try make(transport)
        _ = try await rig.service.changeAmount(subscriptionID: subID, to: 30000)
        let posts = transport.calls(to: "/donor/me/recurring/amount").filter { $0.request.method == .post }
        XCTAssertEqual(posts.count, 2)
        XCTAssertEqual(idempotencyKey(posts[0]), idempotencyKey(posts[1]))
        XCTAssertEqual(transport.calls(to: "/donor/refresh").count, 1)
    }

    func testChangeAmountStatusMapping() async throws {
        let cases: [(HTTPResponse.Status, String, AccountError)] = [
            (.forbidden, "{}", .forbidden), (.conflict, "{}", .conflict), (.unprocessableContent, "{}", .invalidInput),
            (.tooManyRequests, "", .rateLimited), (.tooManyRequests, "{}", .rateLimited),
            (.serviceUnavailable, "{}", .unavailable),
            (.serviceUnavailable, #"{"detail":"Payments are not configured","code":"PAYMENTS_UNCONFIGURED"}"#, .paymentsUnavailable),
            (.contentTooLarge, "{}", .unavailable), (.unsupportedMediaType, "{}", .unavailable),
        ]
        for (status, body, expected) in cases {
            let rig = try make(amountServer { _, _ in (status, body) })
            do { _ = try await rig.service.changeAmount(subscriptionID: subID, to: 30000); XCTFail("\(status)") }
            catch { XCTAssertEqual(error as? AccountError, expected, "\(status) \(body)") }
            XCTAssertNotNil(try rig.store.load(), "\(status) must not end the session")
        }
    }

    func testAnAmountOutsideTheDailyRuleOrABadSubscriptionNeverReachesTheNetwork() async throws {
        let transport = amountServer()
        let rig = try make(transport)
        for amount in [0, 2999, 3001, 93000] {
            do { _ = try await rig.service.changeAmount(subscriptionID: subID, to: amount); XCTFail("\(amount)") }
            catch { XCTAssertEqual(error as? AccountError, .invalidInput) }
        }
        do { _ = try await rig.service.changeAmount(subscriptionID: "../x", to: 30000); XCTFail() }
        catch { XCTAssertEqual(error as? AccountError, .invalidInput) }
        XCTAssertTrue(transport.seen.isEmpty)
    }

    func testAnOfferForADifferentSubscriptionIsAConflictAndSendsNothing() async throws {
        let transport = amountServer()
        let rig = try make(transport)
        do { _ = try await rig.service.changeAmount(subscriptionID: "0f8f2f0a-1b5c-4d7e-9a3b-6c4d5e6f7a8b", to: 30000); XCTFail() }
        catch { XCTAssertEqual(error as? AccountError, .conflict) }
        XCTAssertTrue(transport.calls(to: "/donor/me/recurring/amount").allSatisfy { $0.request.method == .get })
    }

    func testChangeAmountWhenTheOfferIsUnavailableIsUnavailable() async throws {
        let transport = ScriptedTransport { _, _ in (.ok, #"{"state":"unavailable"}"#) }
        let rig = try make(transport)
        do { _ = try await rig.service.changeAmount(subscriptionID: subID, to: 30000); XCTFail() }
        catch { XCTAssertEqual(error as? AccountError, .unavailable) }
        XCTAssertEqual(transport.seen.count, 1)
    }

    func testMalformedChangeResponseStillSucceedsOnlyIfDecodedElseThrowsAndKeepsKey() async throws {
        // Success status but a body that does not decode: the outcome is unknown, so the key survives.
        let transport = amountServer { _, index in index < 2 ? (.ok, #"{"oops":1}"#) : (.ok, amountChangeJSON()) }
        let rig = try make(transport)
        do { _ = try await rig.service.changeAmount(subscriptionID: subID, to: 30000); XCTFail() } catch { assertBodyRejected(error) }
        _ = try await rig.service.changeAmount(subscriptionID: subID, to: 30000)
        let posts = transport.calls(to: "/donor/me/recurring/amount").filter { $0.request.method == .post }
        XCTAssertEqual(idempotencyKey(posts[0]), idempotencyKey(posts[1]))
    }

    func testChangeAmountCancellationLeavesTheSessionAndPropagates() async throws {
        let gate = Gate()
        let transport = ScriptedTransport { seen, _ in
            if seen.request.method == .post {
                await gate.pass()
                try Task.checkCancellation()
                return (.ok, amountChangeJSON())
            }
            return (.ok, amountOptionsJSON())
        }
        let rig = try make(transport)
        let task = Task { try await rig.service.changeAmount(subscriptionID: subID, to: 30000) }
        await gate.waitUntilEntered()
        task.cancel()
        await gate.release()
        do { _ = try await task.value; XCTFail() }
        catch { XCTAssertTrue(error.isCancellation, "\(error)") }
        XCTAssertNotNil(try rig.store.load())
    }

    // MARK: cancel

    func testCancelSendsSubscriptionAndPeriodEndWithAKeyAndReturnsEnding() async throws {
        let transport = ScriptedTransport { _, _ in (.ok, recurringJSON(stopsAt: "2026-11-20T00:00:00Z")) }
        let rig = try make(transport)
        let period = Date(timeIntervalSince1970: 1_795_132_800)
        let state = try await rig.service.cancel(subscriptionID: subID, periodEnd: period)
        XCTAssertTrue(state.isEnding)
        let call = try XCTUnwrap(transport.seen.first)
        XCTAssertEqual(call.request.path, "/donor/me/recurring/cancel")
        XCTAssertEqual(call.request.method, .post)
        let body = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(call.body.utf8)) as? [String: Any])
        XCTAssertEqual(body["subscription_id"] as? String, subID)
        XCTAssertEqual(body["period_end"] as? String, periodEndText)
        XCTAssertNotNil(idempotencyKey(call).flatMap(UUID.init(uuidString:)))
    }

    func testCancelRetryAfterTimeoutReusesTheKeyThenSuccessRetiresIt() async throws {
        let transport = ScriptedTransport { _, index in index == 0 ? (.serviceUnavailable, "{}") : (.ok, recurringJSON(stopsAt: periodEndText)) }
        let rig = try make(transport)
        let period = Date(timeIntervalSince1970: 1_795_132_800)
        do { _ = try await rig.service.cancel(subscriptionID: subID, periodEnd: period); XCTFail() } catch { XCTAssertEqual(error as? AccountError, .unavailable) }
        _ = try await rig.service.cancel(subscriptionID: subID, periodEnd: period)
        _ = try await rig.service.cancel(subscriptionID: subID, periodEnd: period)
        let keys = transport.seen.map(idempotencyKey)
        XCTAssertEqual(keys[0], keys[1])
        XCTAssertNotEqual(keys[1], keys[2])
    }

    func testCancelStatusMappingAndDefinitiveRefusalRetiresTheKey() async throws {
        let cases: [(HTTPResponse.Status, String, AccountError)] = [
            (.forbidden, "{}", .forbidden), (.conflict, "{}", .conflict), (.unprocessableContent, "{}", .invalidInput),
            (.tooManyRequests, "", .rateLimited), (.serviceUnavailable, "{}", .unavailable),
            (.serviceUnavailable, #"{"detail":"x","code":"PAYMENTS_UNCONFIGURED"}"#, .paymentsUnavailable),
        ]
        let period = Date(timeIntervalSince1970: 1_795_132_800)
        for (status, body, expected) in cases {
            let transport = ScriptedTransport { _, _ in (status, body) }
            let rig = try make(transport)
            for _ in 0..<2 {
                do { _ = try await rig.service.cancel(subscriptionID: subID, periodEnd: period); XCTFail("\(status)") }
                catch { XCTAssertEqual(error as? AccountError, expected, "\(status) \(body)") }
            }
            let keys = transport.seen.map(idempotencyKey)
            switch expected {
            case .forbidden, .conflict, .invalidInput, .paymentsUnavailable:
                XCTAssertNotEqual(keys[0], keys[1], "\(status): a definitive refusal retires the key")
            default:
                XCTAssertEqual(keys[0], keys[1], "\(status): a retryable failure keeps the key")
            }
            XCTAssertNotNil(try rig.store.load())
        }
    }

    func testCancelWithABadSubscriptionNeverReachesTheNetwork() async throws {
        let transport = ScriptedTransport { _, _ in (.ok, recurringJSON()) }
        let rig = try make(transport)
        do { _ = try await rig.service.cancel(subscriptionID: "nope", periodEnd: Date()); XCTFail() }
        catch { XCTAssertEqual(error as? AccountError, .invalidInput) }
        XCTAssertTrue(transport.seen.isEmpty)
    }

    func testCancelMalformedBodyThrows() async throws {
        let rig = try make(ScriptedTransport { _, _ in (.ok, #"{"subscription":12}"#) })
        do { _ = try await rig.service.cancel(subscriptionID: subID, periodEnd: Date()); XCTFail() } catch { assertBodyRejected(error) }
    }

    // MARK: payment method

    func testPaymentMethodStatusesMap() async throws {
        let expectations: [(String, PaymentMethodState.Kind)] = [
            ("NONE", .none), ("PENDING", .pending), ("OPEN", .open), ("APPLIED", .applied), ("EXPIRED", .expired), ("CANCELLED", .cancelled),
        ]
        for (raw, kind) in expectations {
            let rig = try make(ScriptedTransport { _, _ in (.ok, #"{"mode":"test","status":"\#(raw)","completed_at":null}"#) })
            let state = try await rig.service.paymentMethod()
            XCTAssertEqual(state.kind, kind, raw)
            XCTAssertEqual(state.isInFlight, kind == .pending || kind == .open)
        }
    }

    func testPaymentMethodErrorsAndUnknownStatus() async throws {
        let unknown = try make(ScriptedTransport { _, _ in (.ok, #"{"mode":"test","status":"WEIRD","completed_at":null}"#) })
        do { _ = try await unknown.service.paymentMethod(); XCTFail() } catch { assertBodyRejected(error) }
        for (status, body, expected) in [(HTTPResponse.Status.tooManyRequests, "", AccountError.rateLimited), (.serviceUnavailable, "{}", .unavailable)] {
            let rig = try make(ScriptedTransport { _, _ in (status, body) })
            do { _ = try await rig.service.paymentMethod(); XCTFail() }
            catch { XCTAssertEqual(error as? AccountError, expected) }
        }
    }

    func testBeginPaymentReturnsTheHostedURLWithAKeyAndNoBody() async throws {
        let transport = ScriptedTransport { _, _ in (.ok, #"{"url":"https://checkout.stripe.com/c/pay/cs_test_123"}"#) }
        let rig = try make(transport)
        let path = try await rig.service.beginPayment()
        XCTAssertEqual(path, .webCheckoutHandoff(URL(string: "https://checkout.stripe.com/c/pay/cs_test_123")!))
        let call = try XCTUnwrap(transport.seen.first)
        XCTAssertEqual(call.request.path, "/donor/me/payment-method/setup")
        XCTAssertEqual(call.body, "")
        XCTAssertNotNil(idempotencyKey(call).flatMap(UUID.init(uuidString:)))
    }

    func testAnUpdateThatAlreadyFinishedHasNothingToOpen() async throws {
        let rig = try make(ScriptedTransport { _, _ in (.ok, #"{"status":"APPLIED","completed_at":"2026-10-31T12:00:00Z","url":null}"#) })
        let path = try await rig.service.beginPayment()
        guard case let .alreadyFinished(state) = path else { return XCTFail("\(path)") }
        XCTAssertEqual(state.kind, .applied)
        XCTAssertNotNil(state.completedAt)
    }

    func testAHostedURLThatIsNotHTTPSIsRefused() async throws {
        for bad in ["http://checkout.stripe.com/x", "javascript:alert(1)", "https://user:pw@evil.test/x", "not a url", "dad://pay"] {
            let rig = try make(ScriptedTransport { _, _ in (.ok, #"{"url":"\#(bad)"}"#) })
            do { _ = try await rig.service.beginPayment(); XCTFail(bad) }
            catch { XCTAssertEqual(error as? AccountError, .invalidResponse, bad) }
        }
    }

    func testBeginPaymentStatusMappingAndRetryKeyReuse() async throws {
        let cases: [(HTTPResponse.Status, String, AccountError)] = [
            (.forbidden, "{}", .forbidden), (.conflict, "{}", .conflict), (.unprocessableContent, "{}", .invalidInput),
            (.tooManyRequests, "", .rateLimited), (.serviceUnavailable, "{}", .unavailable),
            (.serviceUnavailable, #"{"detail":"x","code":"PAYMENTS_UNCONFIGURED"}"#, .paymentsUnavailable),
        ]
        for (status, body, expected) in cases {
            let rig = try make(ScriptedTransport { _, _ in (status, body) })
            do { _ = try await rig.service.beginPayment(); XCTFail("\(status)") }
            catch { XCTAssertEqual(error as? AccountError, expected, "\(status) \(body)") }
        }
        let transport = ScriptedTransport { _, index in index == 0 ? (.serviceUnavailable, "{}") : (.ok, #"{"url":"https://checkout.stripe.com/c/1"}"#) }
        let rig = try make(transport)
        do { _ = try await rig.service.beginPayment(); XCTFail() } catch { XCTAssertEqual(error as? AccountError, .unavailable) }
        _ = try await rig.service.beginPayment()
        XCTAssertEqual(idempotencyKey(transport.seen[0]), idempotencyKey(transport.seen[1]))
    }

    // MARK: start a gift (native checkout)

    func testBeginGiftPostsTheChosenAmountWithKeyAndReturnsTheHostedURL() async throws {
        let transport = ScriptedTransport { _, _ in (.created, checkoutJSON) }
        let rig = try make(transport)
        let path = try await rig.service.beginGift(amountMinor: 21000)
        XCTAssertEqual(path, .webCheckoutHandoff(URL(string: "https://checkout.stripe.com/c/pay/cs_1")!))
        let call = try XCTUnwrap(transport.seen.first)
        XCTAssertEqual(call.request.method, .post)
        XCTAssertEqual(call.request.path, "/donor/me/recurring/checkout")
        XCTAssertEqual(call.request.headerFields[.authorization], "Bearer tok")
        XCTAssertEqual(call.request.headerFields[nativeClientHeader], "native")
        XCTAssertNotNil(idempotencyKey(call).flatMap(UUID.init(uuidString:)))
        let sent = try JSONSerialization.jsonObject(with: Data(call.body.utf8)) as? [String: Any]
        XCTAssertEqual(sent?["amount_minor"] as? Int, 21000)
        XCTAssertEqual(sent?.count, 1)
    }

    func testBeginGiftCarriesTheKeptReferralAndKeysByIt() async throws {
        let transport = ScriptedTransport { _, index in index == 0 ? (.serviceUnavailable, "{}") : (.created, checkoutJSON) }
        let store = MemoryStore(Credentials(access: "tok", refresh: "ref", expiresAt: .distantFuture))
        let session = try AccountSession(api: WireAPI(origin: testOrigin, transport: transport), store: store)
        let kept = KeptReferral("r" + String(repeating: "1", count: 42))
        let service = WireGiving(product: ProductClient(origin: testOrigin, transport: transport, session: session), referral: { kept.value })
        do { _ = try await service.beginGift(amountMinor: 6000); XCTFail() } catch { XCTAssertEqual(error as? AccountError, .unavailable) }
        kept.value = "r" + String(repeating: "2", count: 42)
        _ = try await service.beginGift(amountMinor: 6000)
        let sent = try transport.seen.map { try XCTUnwrap(JSONSerialization.jsonObject(with: Data($0.body.utf8)) as? [String: Any]) }
        XCTAssertEqual(sent.map { $0["referral_token"] as? String }, ["r" + String(repeating: "1", count: 42), "r" + String(repeating: "2", count: 42)])
        XCTAssertNotEqual(idempotencyKey(transport.seen[0]), idempotencyKey(transport.seen[1]), "a changed referral reused the key")
    }

    func testBeginGiftRefusesAnAmountOffTheDailyStepWithoutCallingTheServer() async throws {
        let transport = ScriptedTransport { _, _ in (.created, checkoutJSON) }
        let rig = try make(transport)
        for bad in [0, 2999, 3500, 93000] {
            do { _ = try await rig.service.beginGift(amountMinor: bad); XCTFail("\(bad)") }
            catch { XCTAssertEqual(error as? AccountError, .invalidInput) }
        }
        XCTAssertTrue(transport.seen.isEmpty)
    }

    func testBeginGiftStatusMapping() async throws {
        let cases: [(HTTPResponse.Status, String, AccountError)] = [
            (.unauthorized, "{}", .signedOut), (.forbidden, "{}", .forbidden), (.conflict, "{}", .conflict),
            (.unprocessableContent, "{}", .invalidInput), (.tooManyRequests, #"{"detail":"slow"}"#, .rateLimited),
            (.tooManyRequests, "", .rateLimited),   // the ingress limiter sends no body
            (.serviceUnavailable, "{}", .unavailable),
            (.serviceUnavailable, #"{"detail":"x","code":"PAYMENTS_UNCONFIGURED"}"#, .paymentsUnavailable),
        ]
        for (status, body, expected) in cases {
            let rig = try make(ScriptedTransport { _, _ in (status, body) })
            do { _ = try await rig.service.beginGift(amountMinor: 6000); XCTFail("\(status)") }
            catch { XCTAssertEqual(error as? AccountError, expected, "\(status) \(body)") }
        }
    }

    func testBeginGiftRefusesANonHTTPSHostedURL() async throws {
        for bad in ["http://checkout.stripe.com/x", "javascript:alert(1)", "https://u:p@evil.test/x", "dad://pay"] {
            let rig = try make(ScriptedTransport { _, _ in (.created, #"{"url":"\#(bad)","session_id":"cs","expires_at":"2026-11-01T12:00:00Z"}"#) })
            do { _ = try await rig.service.beginGift(amountMinor: 6000); XCTFail(bad) }
            catch { XCTAssertEqual(error as? AccountError, .invalidResponse, bad) }
        }
    }

    func testBeginGiftKeyIsReusedOnRetryAndRetiredAfterDefinitiveOutcomes() async throws {
        // Retryable outcomes (503, 429, lost response) keep the key for the same amount.
        let transport = ScriptedTransport { _, index in index < 2 ? (index == 0 ? (.serviceUnavailable, "{}") : (.tooManyRequests, "")) : (.created, checkoutJSON) }
        let rig = try make(transport)
        for _ in 0..<2 { do { _ = try await rig.service.beginGift(amountMinor: 6000); XCTFail() } catch { XCTAssertTrue([.unavailable, .rateLimited].contains(error as? AccountError), "\(error)") } }
        _ = try await rig.service.beginGift(amountMinor: 6000)
        XCTAssertEqual(Set(transport.seen.compactMap(idempotencyKey)).count, 1)
        // Success retired it: the next gift of the same amount is a new command.
        _ = try await rig.service.beginGift(amountMinor: 6000)
        XCTAssertEqual(Set(transport.seen.compactMap(idempotencyKey)).count, 2)
        // A different amount never shares a key.
        _ = try await rig.service.beginGift(amountMinor: 9000)
        XCTAssertEqual(Set(transport.seen.compactMap(idempotencyKey)).count, 3)
        // A definitive refusal (409) retires the key too.
        let refused = ScriptedTransport { _, _ in (.conflict, "{}") }
        let r2 = try make(refused)
        for _ in 0..<2 { do { _ = try await r2.service.beginGift(amountMinor: 6000); XCTFail() } catch { XCTAssertEqual(error as? AccountError, .conflict) } }
        XCTAssertEqual(Set(refused.seen.compactMap(idempotencyKey)).count, 2)
    }

    // MARK: Subscription.status is an open set

    func testAnUnknownSubscriptionStatusStillDecodesTheRecurringResponse() async throws {
        for status in ["paused", "trialing", "some_future_status", "active", "incomplete_expired"] {
            let rig = try make(ScriptedTransport { _, _ in (.ok, recurringJSON(status: status)) })
            let state = try await rig.service.recurring()
            guard case let .active(_, amount, _) = state else { return XCTFail("\(status): \(state)") }
            XCTAssertEqual(amount, 15000, status)
        }
    }
}
