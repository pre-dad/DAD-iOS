import Foundation
import XCTest
@testable import DADFoundation

/// A scriptable `GivingService`: each call pops the next scripted result (the last one repeats), and
/// every call is counted, so a test asserts both the state machine and how often the network was hit.
private final class Script<T: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var results: [Result<T, Error>]
    private(set) var calls = 0
    init(_ results: [Result<T, Error>]) { self.results = results }
    convenience init(_ value: T) { self.init([.success(value)]) }
    func next() throws -> T {
        let result: Result<T, Error> = lock.withLock {
            calls += 1
            return results.count > 1 ? results.removeFirst() : results[0]
        }
        return try result.get()
    }
    var count: Int { lock.withLock { calls } }
}

private final class GivingDouble: GivingService, @unchecked Sendable {
    var recurringScript = Script<RecurringState>(.none)
    var offerScript = Script<AmountOffer?>(nil)
    var changeScript = Script<RecurringState>(.none)
    var cancelScript = Script<RecurringState>(.none)
    var paymentScript = Script<PaymentMethodState>(PaymentMethodState(kind: .none))
    var beginPaymentScript = Script<PaymentPath>(.webCheckoutHandoff(URL(string: "https://pay.test/setup")!))
    var beginGiftScript = Script<PaymentPath>(.webCheckoutHandoff(URL(string: "https://dad.test/checkout")!))
    private let sentLock = NSLock()
    private var sent: [Int] = []
    var giftAmountsSent: [Int] { sentLock.withLock { sent } }
    var gate: Gate?
    func recurring() async throws -> RecurringState { try recurringScript.next() }
    func amountOffer() async throws -> AmountOffer? { try offerScript.next() }
    func changeAmount(subscriptionID: String, to amountMinor: Int) async throws -> RecurringState {
        await gate?.pass()
        return try changeScript.next()
    }
    func cancel(subscriptionID: String, periodEnd: Date) async throws -> RecurringState {
        await gate?.pass()
        return try cancelScript.next()
    }
    func paymentMethod() async throws -> PaymentMethodState { try paymentScript.next() }
    func beginPayment() async throws -> PaymentPath { try beginPaymentScript.next() }
    func beginGift(amountMinor: Int) async throws -> PaymentPath {
        sentLock.withLock { sent.append(amountMinor) }
        return try beginGiftScript.next()
    }
}

private let end = Date(timeIntervalSince1970: 1_795_132_800)
private func active(_ minor: Int = 15000) -> RecurringState { .active(subscriptionID: "sub", amountMinor: minor, periodEnd: end) }
private func ending(_ minor: Int = 15000) -> RecurringState { .ending(subscriptionID: "sub", amountMinor: minor, periodEnd: end, stopsAt: end) }
private func offer(_ next: Int = 15000, pending: AmountOffer.Pending? = nil) -> AmountOffer {
    AmountOffer(subscriptionID: "sub", nextAmountMinor: next, effectiveAt: end, pending: pending)
}
@MainActor private func model(_ service: GivingDouble, attempts: Int = 3) -> GivingModel {
    GivingModel(service: service, pollAttempts: attempts, pollDelay: .zero)
}

@MainActor
final class GivingFlowModelTests: XCTestCase {
    // MARK: load

    func testLoadReadsGiftOfferAndPaymentAndSyncsSelectionToTheQueuedAmount() async {
        let service = GivingDouble()
        service.recurringScript = Script(active())
        service.offerScript = Script(offer(pending: .init(amountMinor: 30000, previousMinor: 15000, effectiveAt: end, confirmed: false)))
        service.paymentScript = Script(PaymentMethodState(kind: .applied))
        let m = model(service)
        await m.load()
        XCTAssertEqual(m.phase, .idle)
        XCTAssertTrue(m.hasLoaded)
        XCTAssertEqual(m.selection.dailyDollars, 10, "a queued $300 change shows as the current choice")
        XCTAssertEqual(m.currentAmountMinor, 30000)
        XCTAssertEqual(m.payment?.kind, .applied)
    }

    func testNoGiftAndPreparingStatesLoadWithoutOfferOrError() async {
        let none = GivingDouble()
        let a = model(none)
        await a.load()
        XCTAssertEqual(a.recurring, .none)
        XCTAssertNil(a.offer)
        XCTAssertEqual(none.offerScript.count, 0, "the amount offer is only read for a subscription")
        let preparing = GivingDouble()
        preparing.recurringScript = Script(.preparing)
        let b = model(preparing)
        await b.load()
        XCTAssertEqual(b.recurring, .preparing)
        XCTAssertEqual(b.phase, .idle)
    }

    func testFailedLoadShowsMessageAndRetryRecovers() async {
        let service = GivingDouble()
        service.recurringScript = Script([.failure(AccountError.unavailable), .success(active())])
        let m = model(service)
        await m.load()
        XCTAssertEqual(m.phase, .failed("Something went wrong. Please try again."))
        XCTAssertFalse(m.hasLoaded)
        await m.load()
        XCTAssertEqual(m.phase, .idle)
        XCTAssertTrue(m.hasLoaded)
    }

    func testEveryErrorStatusHasItsOwnPlainMessage() async {
        let cases: [(AccountError, String)] = [
            (.rateLimited, "Too many attempts. Please wait a moment and try again."),
            (.forbidden, "Giving isn’t available for this account."),
            (.paymentsUnavailable, "Payments aren’t available right now. Please try again later."),
            (.unavailable, "Something went wrong. Please try again."),
        ]
        for (error, message) in cases {
            let service = GivingDouble()
            service.recurringScript = Script([.failure(error)])
            let m = model(service)
            await m.load()
            XCTAssertEqual(m.phase, .failed(message), "\(error)")
        }
    }

    func testSignedOutFlagsTheModelSoTheScreenLeaves() async {
        let service = GivingDouble()
        service.recurringScript = Script([.failure(AccountError.signedOut)])
        let m = model(service)
        await m.load()
        XCTAssertTrue(m.signedOut)
        let soft = GivingDouble()
        soft.recurringScript = Script(active())
        soft.paymentScript = Script([.failure(AccountError.signedOut)])
        let n = model(soft)
        await n.load()
        XCTAssertTrue(n.signedOut, "a 401 on a supporting read also ends the screen")
    }

    func testCancelledLoadKeepsPriorStateAndIsNotAnError() async {
        let service = GivingDouble()
        service.recurringScript = Script([.success(active()), .failure(CancellationError())])
        let m = model(service)
        await m.load()
        await m.load()
        XCTAssertEqual(m.phase, .idle)
        XCTAssertEqual(m.recurring, active())
        XCTAssertTrue(m.hasLoaded)
    }

    func testSupportingReadFailureDoesNotFailTheScreen() async {
        let service = GivingDouble()
        service.recurringScript = Script(active())
        service.offerScript = Script([.failure(AccountError.rateLimited)])
        service.paymentScript = Script([.failure(AccountError.unavailable)])
        let m = model(service)
        await m.load()
        XCTAssertEqual(m.phase, .idle)
        XCTAssertNil(m.offer)
        XCTAssertNil(m.payment)
        XCTAssertEqual(m.selection.dailyDollars, 5, "falls back to the subscription's own amount")
    }

    // MARK: change amount

    func testApplySelectionSavesRefreshesTheOfferAndExplainsWhenItTakesEffect() async {
        let service = GivingDouble()
        service.recurringScript = Script(active())
        service.offerScript = Script([.success(offer()), .success(offer(30000))])
        service.changeScript = Script(active(30000))
        let m = model(service)
        await m.load()
        m.setDaily(10)
        await m.applySelection()
        XCTAssertEqual(m.phase, .idle)
        XCTAssertEqual(m.notice, "Saved. Your next renewal will be $300.")
        XCTAssertEqual(service.changeScript.count, 1)
    }

    func testApplyingTheAmountAlreadyInForceSendsNothing() async {
        let service = GivingDouble()
        service.recurringScript = Script(active())
        service.offerScript = Script(offer())
        let m = model(service)
        await m.load()
        await m.applySelection()
        XCTAssertEqual(service.changeScript.count, 0)
        XCTAssertEqual(m.notice, "That’s already your gift amount.")
    }

    func testDoubleTapOnSaveSendsOneCommand() async {
        let service = GivingDouble()
        service.recurringScript = Script(active())
        service.offerScript = Script(offer())
        service.changeScript = Script(active(30000))
        let gate = Gate()
        service.gate = gate
        let m = model(service)
        await m.load()
        m.setDaily(10)
        let first = Task { await m.applySelection() }
        await gate.waitUntilEntered()
        XCTAssertTrue(m.isBusy)
        await m.applySelection()          // the second tap while the first is in flight
        await m.cancel()                  // and a different command
        await gate.release()
        await first.value
        XCTAssertEqual(service.changeScript.count, 1)
        XCTAssertEqual(service.cancelScript.count, 0)
    }

    func testConflictRereadsBillingAndSaysSo() async {
        let service = GivingDouble()
        service.recurringScript = Script([.success(active()), .success(active(60000))])
        service.offerScript = Script([.success(offer()), .success(offer(60000))])
        service.changeScript = Script([.failure(AccountError.conflict)])
        let m = model(service)
        await m.load()
        m.setDaily(10)
        await m.applySelection()
        XCTAssertEqual(m.phase, .failed("Your gift changed while you were looking at it. We’ve refreshed it; please review and try again."))
        XCTAssertEqual(m.recurring.amountMinor, 60000, "the screen now shows current billing")
        XCTAssertEqual(m.selection.dailyDollars, 20)
    }

    func testChangeFailuresKeepThePriorGift() async {
        for error in [AccountError.rateLimited, .forbidden, .invalidInput, .unavailable, .paymentsUnavailable] {
            let service = GivingDouble()
            service.recurringScript = Script(active())
            service.offerScript = Script(offer())
            service.changeScript = Script([.failure(error)])
            let m = model(service)
            await m.load()
            m.setDaily(10)
            await m.applySelection()
            guard case .failed = m.phase else { XCTFail("\(error)"); continue }
            XCTAssertEqual(m.recurring, active(), "\(error)")
        }
    }

    func testCancelledChangeKeepsPriorStateWithoutAnError() async {
        let service = GivingDouble()
        service.recurringScript = Script(active())
        service.offerScript = Script(offer())
        service.changeScript = Script([.failure(CancellationError())])
        let m = model(service)
        await m.load()
        m.setDaily(10)
        await m.applySelection()
        XCTAssertEqual(m.phase, .idle)
        XCTAssertEqual(m.recurring, active())
    }

    func testAnEndingGiftCannotBeChanged() async {
        let service = GivingDouble()
        service.recurringScript = Script(ending())
        let m = model(service)
        await m.load()
        m.setDaily(10)
        await m.applySelection()
        XCTAssertEqual(m.phase, .failed("Your gift is ending, so its amount can’t be changed."))
        XCTAssertEqual(service.changeScript.count, 0)
    }

    // MARK: cancel

    func testCancelEndsTheGiftAndKeepsItVisibleUntilThePeriodEnds() async {
        let service = GivingDouble()
        service.recurringScript = Script(active())
        service.cancelScript = Script(ending())
        let m = model(service)
        await m.load()
        await m.cancel()
        XCTAssertEqual(m.phase, .idle)
        XCTAssertTrue(m.recurring.isEnding)
        await m.cancel()   // already ending: refused locally, not sent
        XCTAssertEqual(service.cancelScript.count, 1)
        XCTAssertEqual(m.phase, .failed("There’s no active gift to cancel."))
    }

    func testCancelFailureKeepsTheGiftActive() async {
        for error in [AccountError.rateLimited, .forbidden, .unavailable, .paymentsUnavailable, .invalidInput] {
            let service = GivingDouble()
            service.recurringScript = Script(active())
            service.cancelScript = Script([.failure(error)])
            let m = model(service)
            await m.load()
            await m.cancel()
            guard case .failed = m.phase else { XCTFail("\(error)"); continue }
            XCTAssertEqual(m.recurring, active(), "\(error): a failed cancel leaves the gift as it was")
        }
    }

    func testCancelConflictRereadsAndShowsTheCurrentGift() async {
        let service = GivingDouble()
        service.recurringScript = Script([.success(active()), .success(ending())])
        service.cancelScript = Script([.failure(AccountError.conflict)])
        let m = model(service)
        await m.load()
        await m.cancel()
        XCTAssertTrue(m.recurring.isEnding, "billing already shows the gift ending")
        guard case .failed = m.phase else { return XCTFail("expected the failed phase") }
    }

    func testCancelCancellationKeepsStateAndDoubleTapSendsOnce() async {
        let cancelled = GivingDouble()
        cancelled.recurringScript = Script(active())
        cancelled.cancelScript = Script([.failure(CancellationError())])
        let a = model(cancelled)
        await a.load()
        await a.cancel()
        XCTAssertEqual(a.phase, .idle)
        XCTAssertEqual(a.recurring, active())

        let service = GivingDouble()
        service.recurringScript = Script(active())
        service.cancelScript = Script(ending())
        let gate = Gate()
        service.gate = gate
        let b = model(service)
        await b.load()
        let first = Task { await b.cancel() }
        await gate.waitUntilEntered()
        await b.cancel()
        await gate.release()
        await first.value
        XCTAssertEqual(service.cancelScript.count, 1)
    }

    func testSignedOutDuringCancelFlagsTheScreen() async {
        let service = GivingDouble()
        service.recurringScript = Script(active())
        service.cancelScript = Script([.failure(AccountError.signedOut)])
        let m = model(service)
        await m.load()
        await m.cancel()
        XCTAssertTrue(m.signedOut)
    }

    // MARK: start a gift

    func testStartGiftOpensTheHostedPageThenPollsUntilTheGiftAppears() async {
        let service = GivingDouble()
        service.recurringScript = Script([.success(.none), .success(.none), .success(.none), .success(active(3000))])
        service.offerScript = Script(offer(3000))
        let m = model(service, attempts: 5)
        await m.load()
        await m.startGift()
        XCTAssertEqual(m.handoff?.url, URL(string: "https://dad.test/checkout"))
        XCTAssertEqual(m.handoff?.purpose, .startGift)
        await m.handoffFinished()
        XCTAssertNil(m.handoff)
        XCTAssertFalse(m.isConfirming)
        XCTAssertEqual(m.recurring.subscriptionID, "sub")
        XCTAssertEqual(m.notice, "Your gift is set up.")
        XCTAssertEqual(m.selection.dailyDollars, 1)
    }

    func testACancelledPollDoesNotClaimNoGiftWasFound() async {
        let service = GivingDouble()
        let m = model(service, attempts: 3)
        await m.load()
        await m.startGift()
        let poll = Task { await m.handoffFinished() }
        poll.cancel()
        await poll.value
        XCTAssertNil(m.notice)
        XCTAssertFalse(m.isConfirming)
    }

    func testStartGiftThatNeverAppearsStopsPollingAndSaysSo() async {
        let service = GivingDouble()
        let m = model(service, attempts: 3)
        await m.load()
        await m.startGift()
        await m.handoffFinished()
        XCTAssertEqual(service.recurringScript.count, 1 + 3, "one load plus the bounded polls")
        XCTAssertEqual(m.notice, "We haven’t seen a new gift yet. If you finished checkout, it can take a moment to appear.")
        XCTAssertEqual(m.recurring, .none)
    }

    func testStartGiftSendsTheAmountTheDonorChose() async {
        let service = GivingDouble()
        let m = model(service)
        await m.load()
        m.setDaily(7)
        await m.startGift()
        XCTAssertEqual(service.giftAmountsSent, [21000], "$7/day is 21000 cents a month")
        XCTAssertNotNil(m.handoff)
    }

    func testStartGiftPaymentsUnconfiguredSaysGivingIsUnavailable() async {
        let service = GivingDouble()
        service.beginGiftScript = Script([.failure(AccountError.paymentsUnavailable)])
        let m = model(service)
        await m.startGift()
        XCTAssertEqual(m.phase, .failed("Giving isn’t available right now. Please try again later."))
        XCTAssertNil(m.handoff)
    }

    func testStartGiftConflictRereadsAndTellsTheDonor() async {
        let service = GivingDouble()
        service.recurringScript = Script([.success(.none), .success(active(6000))])
        service.beginGiftScript = Script([.failure(AccountError.conflict)])
        let m = model(service)
        await m.load()
        await m.startGift()
        XCTAssertEqual(service.recurringScript.count, 2, "re-read after the conflict")
        XCTAssertEqual(m.recurring.amountMinor, 6000)
        XCTAssertEqual(m.phase, .failed("You already have a monthly gift or a checkout in progress. We’ve refreshed it; please review."))
        XCTAssertNil(m.handoff)
    }

    func testStartGiftIsRefusedWhenAGiftAlreadyExistsAndDoubleTapOpensOnce() async {
        let existing = GivingDouble()
        existing.recurringScript = Script(active())
        let a = model(existing)
        await a.load()
        await a.startGift()
        XCTAssertEqual(existing.beginGiftScript.count, 0)
        XCTAssertEqual(a.phase, .failed("You already have a gift."))

        let service = GivingDouble()
        let m = model(service)
        await m.load()
        await m.startGift()
        let firstHandoff = m.handoff
        await m.handoffFinished()
        await m.handoffFinished()   // a second dismissal callback is ignored
        XCTAssertNotNil(firstHandoff)
        XCTAssertEqual(service.recurringScript.count, 1 + 3)
    }

    func testStartGiftErrorsKeepTheScreenUsable() async {
        for error in [AccountError.rateLimited, .unavailable, .forbidden] {
            let service = GivingDouble()
            service.beginGiftScript = Script([.failure(error)])
            let m = model(service)
            await m.startGift()
            guard case .failed = m.phase else { XCTFail("\(error)"); continue }
            XCTAssertNil(m.handoff)
            XCTAssertFalse(m.isBusy)
        }
    }

    // MARK: update payment

    func testUpdatePaymentOpensTheHostedPageAndPollsToApplied() async {
        let service = GivingDouble()
        service.recurringScript = Script(active())
        service.offerScript = Script(offer())
        service.paymentScript = Script([.success(PaymentMethodState(kind: .none)), .success(PaymentMethodState(kind: .pending)),
                                        .success(PaymentMethodState(kind: .open)), .success(PaymentMethodState(kind: .applied))])
        let m = model(service, attempts: 5)
        await m.load()
        await m.updatePayment()
        XCTAssertEqual(m.handoff?.url, URL(string: "https://pay.test/setup"))
        XCTAssertEqual(m.handoff?.purpose, .updatePayment)
        await m.handoffFinished()
        XCTAssertEqual(m.payment?.kind, .applied)
        XCTAssertEqual(m.notice, "Your payment method was updated.")
    }

    func testPaymentUpdateOutcomesCancelledExpiredAndStillPending() async {
        let outcomes: [(PaymentMethodState.Kind, String)] = [
            (.cancelled, "The payment update was cancelled. Your payment method is unchanged."),
            (.expired, "The payment update expired. Start again to update your payment method."),
            (.pending, "We’re still waiting for the payment provider to confirm. Check back in a moment."),
            (.open, "We’re still waiting for the payment provider to confirm. Check back in a moment."),
        ]
        for (kind, message) in outcomes {
            let service = GivingDouble()
            service.recurringScript = Script(active())
            service.offerScript = Script(offer())
            service.paymentScript = Script(PaymentMethodState(kind: kind))
            let m = model(service, attempts: 2)
            await m.load()
            await m.updatePayment()
            await m.handoffFinished()
            XCTAssertEqual(m.notice, message, "\(kind)")
        }
    }

    func testUpdateThatAlreadyFinishedOpensNothing() async {
        let service = GivingDouble()
        service.recurringScript = Script(active())
        service.offerScript = Script(offer())
        service.beginPaymentScript = Script(.alreadyFinished(PaymentMethodState(kind: .applied)))
        let m = model(service)
        await m.load()
        await m.updatePayment()
        XCTAssertNil(m.handoff)
        XCTAssertEqual(m.notice, "Your payment method was updated.")
        XCTAssertEqual(m.phase, .idle)
    }

    func testUpdatePaymentNeedsAGiftAndMapsErrors() async {
        let none = GivingDouble()
        let a = model(none)
        await a.load()
        await a.updatePayment()
        XCTAssertEqual(none.beginPaymentScript.count, 0)
        guard case .failed = a.phase else { return XCTFail("expected the failed phase") }

        for error in [AccountError.conflict, .forbidden, .rateLimited, .unavailable, .paymentsUnavailable] {
            let service = GivingDouble()
            service.recurringScript = Script(active())
            service.beginPaymentScript = Script([.failure(error)])
            let m = model(service)
            await m.load()
            await m.updatePayment()
            guard case .failed = m.phase else { XCTFail("\(error)"); continue }
            XCTAssertNil(m.handoff)
        }
    }

    func testDoubleTapOnUpdatePaymentOpensOnePage() async {
        let service = GivingDouble()
        service.recurringScript = Script(active())
        let m = model(service)
        await m.load()
        async let first: Void = m.updatePayment()
        async let second: Void = m.updatePayment()
        _ = await (first, second)
        XCTAssertEqual(service.beginPaymentScript.count, 1)
    }

    func testApplePayPathIsRefusedUntilItIsApproved() async {
        let service = GivingDouble()
        service.recurringScript = Script(active())
        service.beginPaymentScript = Script(.applePay)
        let m = model(service)
        await m.load()
        await m.updatePayment()
        XCTAssertEqual(m.phase, .failed("Apple Pay isn’t available in this build yet."))
    }
}
