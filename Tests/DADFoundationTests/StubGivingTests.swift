#if DEBUG
import Foundation
import XCTest
@testable import DADFoundation

/// The scripted stub backend drives the UITests, so its giving rules are pinned here: the REAL
/// `WireGiving` and `WireAccountSettings` run on it exactly as they do in the simulator.
@MainActor final class StubGivingTests: XCTestCase {
    func testTimezoneCorrectionSurvivesProfileSavesAndCanReset() async throws {
        let services = try StubBackend.make(gift: .none, signedIn: true)
        let first = try await services.management.saveProfile(zip: "78701", city: "Austin", phone: "", timezoneOverride: "America/Phoenix")
        XCTAssertEqual(first.timezone, "America/Phoenix")
        XCTAssertEqual(first.timezoneOverride, "America/Phoenix")
        let kept = try await services.management.saveProfile(zip: "", city: "", phone: "")
        XCTAssertEqual(kept.timezoneOverride, "America/Phoenix")
        let reset = try await services.management.saveProfile(zip: "", city: "", phone: "", timezoneOverride: "")
        XCTAssertNil(reset.timezoneOverride)
        XCTAssertNil(reset.timezone)
    }

    func testActiveGiftBlocksDeletionUntilItIsCancelledThenDeletes() async throws {
        let services = try StubBackend.make(gift: .active, signedIn: true)
        do { try await services.settings.deleteAccount(); XCTFail("a renewing gift must block deletion") }
        catch { XCTAssertEqual(error as? AccountError, .deletionBlocked) }

        let model = GivingModel(service: services.giving, pollDelay: .zero)
        await model.load()
        XCTAssertEqual(model.recurring.amountMinor, 15000)
        await model.cancel()
        XCTAssertTrue(model.recurring.isEnding)
        XCTAssertEqual(model.phase, .idle)

        try await services.settings.deleteAccount()
        let signedIn = await services.session.isSignedIn
        XCTAssertFalse(signedIn)
    }

    func testStartingAGiftThenChangingTheAmountAndUpdatingTheCard() async throws {
        let services = try StubBackend.make(gift: .none, signedIn: true)
        let model = GivingModel(service: services.giving, pollAttempts: 2, pollDelay: .zero)
        await model.load()
        XCTAssertEqual(model.recurring, .none)

        model.setDaily(4)
        await model.startGift()
        XCTAssertEqual(model.handoff?.url, URL(string: "https://stub.invalid/pay/checkout"))
        services.completeHandoff(.startGift)
        await model.handoffFinished()
        XCTAssertEqual(model.recurring.amountMinor, 12000, "the gift is for the amount the donor chose")
        XCTAssertEqual(model.notice, "Your gift is set up.")

        model.setDaily(10)
        await model.applySelection()
        XCTAssertEqual(model.recurring.amountMinor, 30000)
        XCTAssertEqual(model.notice, "Saved. Your next renewal will be $300.")

        await model.updatePayment()
        XCTAssertEqual(model.handoff?.url, URL(string: "https://stub.invalid/pay/setup"))
        services.completeHandoff(.updatePayment)
        await model.handoffFinished()
        XCTAssertEqual(model.payment?.kind, .applied)
        XCTAssertEqual(model.notice, "Your payment method was updated.")
    }

    func testFailFirstRecurringReadThenRetrySucceeds() async throws {
        let services = try StubBackend.make(gift: .activeFailFirst, signedIn: true)
        let model = GivingModel(service: services.giving, pollDelay: .zero)
        await model.load()
        guard case .failed = model.phase else { return XCTFail("\(model.phase)") }
        await model.load()
        XCTAssertEqual(model.phase, .idle)
        XCTAssertEqual(model.recurring.amountMinor, 15000)
    }

    func testTheCheckoutOpenFlagStillBlocksDeletionWithNoGift() async throws {
        let services = try StubBackend.make(deletionBlocked: true, gift: .none, signedIn: true)
        do { try await services.settings.deleteAccount(); XCTFail() }
        catch { XCTAssertEqual(error as? AccountError, .deletionBlocked) }
    }
}
#endif
