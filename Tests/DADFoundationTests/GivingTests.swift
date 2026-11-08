import Foundation
import XCTest
@testable import DADFoundation

// MARK: - GiftAmount math (G-1/G-2)

final class GiftAmountTests: XCTestCase {
    func testDailyToMonthlyIsTimes30() {
        XCTAssertEqual(GiftAmount(dailyDollars: 1)?.monthlyMinor, 3000)   // $1/day → $30/mo
        XCTAssertEqual(GiftAmount(dailyDollars: 5)?.monthlyMinor, 15000)  // $5/day → $150/mo
        XCTAssertEqual(GiftAmount(dailyDollars: 30)?.monthlyMinor, 90000) // $30/day → $900/mo
    }

    func testCeilingClampsAt30PerDay() {
        XCTAssertEqual(GiftAmount(dailyDollars: 50)?.dailyDollars, 30)    // over ceiling clamps
        XCTAssertEqual(GiftAmount(dailyDollars: 31)?.monthlyMinor, 90000)
    }

    func testBelowFloorIsRejected() {
        XCTAssertNil(GiftAmount(dailyDollars: 0))
        XCTAssertNil(GiftAmount(dailyDollars: -3))
    }

    func testFromMonthlyMinorAcceptsOnlyExactSteps() {
        XCTAssertEqual(GiftAmount(monthlyMinor: 15000)?.dailyDollars, 5)
        XCTAssertNil(GiftAmount(monthlyMinor: 15001))   // not a $1/day step
        XCTAssertNil(GiftAmount(monthlyMinor: 2999))    // below floor
        XCTAssertNil(GiftAmount(monthlyMinor: 90001))   // above ceiling
    }

    func testLabels() {
        let amount = GiftAmount(dailyDollars: 5)!
        XCTAssertEqual(amount.dailyLabel, "$5/day")
        XCTAssertEqual(amount.monthlyLabel, "$150/mo")
    }

    func testFormatUSDMinor() {
        XCTAssertEqual(formatUSDMinor(15000), "$150")
        XCTAssertEqual(formatUSDMinor(1234), "$12.34")
        XCTAssertEqual(formatUSDMinor(0), "$0")
    }
}

// MARK: - GivingModel state machine (G-7/G-8/G-9)

final class GivingModelTests: XCTestCase {
    private actor StubService: GivingService {
        var state: RecurringState
        var payment: PaymentPath
        var failNext = false
        private(set) var changedTo: Int?
        private(set) var cancelled = false

        init(state: RecurringState, payment: PaymentPath = .webCheckoutHandoff(URL(string: "https://give.example.org/setup")!)) {
            self.state = state; self.payment = payment
        }
        func setFailNext(_ value: Bool) { failNext = value }

        func recurring() async throws -> RecurringState {
            if failNext { failNext = false; throw AccountError.unavailable }
            return state
        }
        func changeAmount(subscriptionID: String, to amountMinor: Int) async throws -> RecurringState {
            if failNext { failNext = false; throw AccountError.unavailable }
            changedTo = amountMinor
            if case let .active(id, _, end) = state { state = .active(subscriptionID: id, amountMinor: amountMinor, periodEnd: end) }
            return state
        }
        func cancel(subscriptionID: String, periodEnd: Date) async throws -> RecurringState {
            if failNext { failNext = false; throw AccountError.unavailable }
            cancelled = true
            if case let .active(id, amount, end) = state {
                state = .ending(subscriptionID: id, amountMinor: amount, periodEnd: end, stopsAt: periodEnd)
            }
            return state
        }
        func beginPayment() async throws -> PaymentPath { payment }
        func amountOffer() async throws -> AmountOffer? { nil }
        func paymentMethod() async throws -> PaymentMethodState { PaymentMethodState(kind: .none) }
        func beginGift(amountMinor: Int) async throws -> PaymentPath { payment }
    }

    @MainActor
    func testLoadSyncsSelectionToActiveAmount() async {
        let end = Date().addingTimeInterval(86_400)
        let service = StubService(state: .active(subscriptionID: "sub_1", amountMinor: 15000, periodEnd: end))
        let model = GivingModel(service: service)
        await model.load()
        XCTAssertEqual(model.phase, .idle)
        XCTAssertEqual(model.selection.dailyDollars, 5)         // 15000¢ → $5/day
        XCTAssertEqual(model.recurring.subscriptionID, "sub_1")
    }

    @MainActor
    func testStepperClampsToRule() {
        let service = StubService(state: .none)
        let model = GivingModel(service: service)
        model.setDaily(30); model.increment()                   // can't exceed $30
        XCTAssertEqual(model.selection.dailyDollars, 30)
        model.setDaily(1); model.decrement()                    // can't go below $1
        XCTAssertEqual(model.selection.dailyDollars, 1)
    }

    @MainActor
    func testApplySelectionChangesAmount() async {
        let end = Date().addingTimeInterval(86_400)
        let service = StubService(state: .active(subscriptionID: "sub_1", amountMinor: 3000, periodEnd: end))
        let model = GivingModel(service: service)
        await model.load()
        model.setDaily(10)
        await model.applySelection()
        XCTAssertEqual(model.phase, .idle)
        XCTAssertEqual(model.recurring.amountMinor, 30000)      // $10/day → $300/mo
        let changed = await service.changedTo
        XCTAssertEqual(changed, 30000)
    }

    @MainActor
    func testApplyWithoutSubscriptionFailsClearly() async {
        let service = StubService(state: .none)
        let model = GivingModel(service: service)
        await model.applySelection()
        guard case .failed(let message) = model.phase else { return XCTFail("expected failure") }
        XCTAssertFalse(message.isEmpty)
        let changed = await service.changedTo
        XCTAssertNil(changed, "no subscription means nothing is sent")
    }

    @MainActor
    func testCancelMovesToEnding() async {
        let end = Date().addingTimeInterval(3 * 86_400)
        let service = StubService(state: .active(subscriptionID: "sub_1", amountMinor: 15000, periodEnd: end))
        let model = GivingModel(service: service)
        await model.load()
        await model.cancel()
        XCTAssertTrue(model.recurring.isEnding)
        let cancelled = await service.cancelled
        XCTAssertTrue(cancelled)
    }

    @MainActor
    func testFailurePathSurfacesMessage() async {
        let service = StubService(state: .active(subscriptionID: "sub_1", amountMinor: 3000, periodEnd: Date()))
        await service.setFailNext(true)
        let model = GivingModel(service: service)
        await model.load()
        XCTAssertEqual(model.phase, .failed("Something went wrong. Please try again."))
        XCTAssertFalse(model.hasLoaded)
    }
}

// MARK: - Cancel copy (G-8/G-9)

final class CancelCopyTests: XCTestCase {
    func testConfirmationNamesTheDateAndStreakEnd() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        let date = calendar.date(from: DateComponents(year: 2027, month: 1, day: 15))!
        let copy = CancelCopy.confirmation(periodEnd: date, calendar: calendar)
        XCTAssertTrue(copy.contains("2027"))
        XCTAssertTrue(copy.lowercased().contains("streak ends"))
    }
}

final class RecurringHeadingTests: XCTestCase {
    private let date = Date(timeIntervalSince1970: 0)

    func testHeadingBeforeLoadIgnoresState() {
        XCTAssertEqual(RecurringState.none.heading(hasLoaded: false), "Your monthly gift")
        XCTAssertEqual(RecurringState.ending(subscriptionID: "s", amountMinor: 500, periodEnd: date, stopsAt: date).heading(hasLoaded: false), "Your monthly gift")
    }

    func testHeadingPerLoadedState() {
        XCTAssertEqual(RecurringState.none.heading(hasLoaded: true), "Start a monthly gift")
        XCTAssertEqual(RecurringState.preparing.heading(hasLoaded: true), "Your gift is on its way")
        XCTAssertEqual(RecurringState.active(subscriptionID: "s", amountMinor: 500, periodEnd: date).heading(hasLoaded: true), "Your monthly gift")
        XCTAssertEqual(RecurringState.ending(subscriptionID: "s", amountMinor: 500, periodEnd: date, stopsAt: date).heading(hasLoaded: true), "Your gift is ending")
    }
}
