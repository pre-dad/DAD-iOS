import XCTest

/// Wiring P3 — the REAL `WireGiving`, `GivingModel`, `WireAccountSettings` and `AccountSession` run
/// against the DEBUG-only scripted transport (`--stub-backend`). The Stripe-hosted pages cannot load
/// from the simulator, so the app shows a stub "secure payment page" whose "Complete payment" button
/// plays the webhook; everything else (reads, idempotent commands, the 409 rules) is release code.
@MainActor final class GiftFlowTests: XCTestCase {
    private func launch(_ extra: String...) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["--stub-backend", "--stub-signed-in"] + extra
        app.launch()
        return app
    }

    private func openGift(_ app: XCUIApplication, file: StaticString = #filePath, line: UInt = #line) {
        // The gift screen is the Giving tab, not a sheet from the Home card.
        let giving = app.tabBars.buttons["Giving"]
        XCTAssertTrue(giving.waitForExistence(timeout: 20), "the donor shell offers the Giving tab", file: file, line: line)
        giving.tap()
        XCTAssertTrue(app.otherElements["gift-screen"].waitForExistence(timeout: 10), file: file, line: line)
    }

    func testStartAGiftThroughTheHostedHandoffThenTheHomeCardReflectsIt() {
        let app = launch()
        XCTAssertTrue(app.staticTexts["gift-summary"].waitForExistence(timeout: 20))
        XCTAssertEqual(app.staticTexts["gift-summary"].label, "No monthly gift yet.")
        openGift(app)
        XCTAssertTrue(app.staticTexts["gift-none"].waitForExistence(timeout: 10))
        XCTAssertEqual(app.staticTexts["gift-daily"].label, "$1/day")
        // The ± stepper lives under "Other"; the presets are $1/$3/$5.
        app.buttons["amount-other"].tap()
        XCTAssertTrue(app.buttons["Increase gift"].waitForExistence(timeout: 5))
        app.buttons["Increase gift"].tap()
        app.buttons["Increase gift"].tap()
        XCTAssertEqual(app.staticTexts["gift-daily"].label, "$3/day")
        app.buttons["start-gift"].tap()

        XCTAssertTrue(app.otherElements["hosted-page-stub"].waitForExistence(timeout: 10), "the hosted page opens")
        app.buttons["stub-complete"].tap()
        // A first gift shows the one-time celebration; dismiss it to reach the gift screen.
        XCTAssertTrue(app.otherElements["celebration-screen"].waitForExistence(timeout: 20), "a first gift celebrates")
        // The stub donor is a Founding Donor, so the celebration shows the Founding capsule (threaded
        // from the dashboard, not hardcoded off).
        XCTAssertTrue(app.staticTexts["celebration-founding"].waitForExistence(timeout: 5), "a founding donor sees the Founding capsule on the celebration")
        app.buttons["celebration-done"].tap()
        XCTAssertTrue(app.staticTexts["gift-monthly"].waitForExistence(timeout: 20), "the gift appears once the server reflects it")
        // The stub backend activates the gift for the amount the checkout request carried.
        XCTAssertEqual(app.staticTexts["gift-monthly"].label, "$90/month")
        XCTAssertEqual(app.staticTexts["gift-notice"].label, "Your gift is set up.")

        // The Giving tab has no inline close; the Home card reflects the new gift.
        app.tabBars.buttons["Home"].tap()
        XCTAssertTrue(app.staticTexts["gift-summary"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.staticTexts["gift-summary"].label.hasPrefix("$90/month · renews"), app.staticTexts["gift-summary"].label)
    }

    func testClosingTheHostedPageWithoutPayingLeavesNoGift() {
        let app = launch()
        openGift(app)
        XCTAssertTrue(app.buttons["start-gift"].waitForExistence(timeout: 10))
        app.buttons["start-gift"].tap()
        XCTAssertTrue(app.buttons["stub-close"].waitForExistence(timeout: 10))
        app.buttons["stub-close"].tap()
        XCTAssertTrue(app.staticTexts["gift-notice"].waitForExistence(timeout: 20))
        XCTAssertTrue(app.staticTexts["gift-notice"].label.hasPrefix("We haven’t seen a new gift yet"), app.staticTexts["gift-notice"].label)
        XCTAssertTrue(app.buttons["start-gift"].exists, "the donor can start again")
    }

    func testChangeTheAmount() {
        let app = launch("--stub-gift-active")
        openGift(app)
        XCTAssertTrue(app.staticTexts["gift-monthly"].waitForExistence(timeout: 10))
        XCTAssertEqual(app.staticTexts["gift-monthly"].label, "$150/month")
        XCTAssertEqual(app.staticTexts["gift-daily"].label, "$5/day")

        // Reveal the ± stepper via "Other" before stepping off the $5 preset.
        app.buttons["amount-other"].tap()
        XCTAssertTrue(app.buttons["Increase gift"].waitForExistence(timeout: 5))
        app.buttons["Increase gift"].tap()
        XCTAssertEqual(app.staticTexts["gift-daily"].label, "$6/day")
        app.buttons["save-gift"].tap()
        XCTAssertTrue(app.staticTexts["gift-notice"].waitForExistence(timeout: 10))
        XCTAssertEqual(app.staticTexts["gift-notice"].label, "Saved. Your next renewal will be $180.")
        XCTAssertEqual(app.staticTexts["gift-monthly"].label, "$180/month")
    }

    func testCancelTheMonthlyGiftThenTheHomeCardShowsItEnding() {
        let app = launch("--stub-gift-active")
        XCTAssertTrue(app.staticTexts["gift-summary"].waitForExistence(timeout: 20))
        openGift(app)
        app.buttons["Cancel gift"].tap()
        XCTAssertTrue(app.otherElements["cancel-confirm"].waitForExistence(timeout: 5))
        app.buttons["End my gift"].tap()
        XCTAssertTrue(app.staticTexts["gift-ending"].waitForExistence(timeout: 10))
        XCTAssertFalse(app.buttons["Cancel gift"].exists, "an ending gift offers no second cancel")

        // The Giving tab has no inline close; the Home card reflects the ending gift.
        app.tabBars.buttons["Home"].tap()
        XCTAssertTrue(app.staticTexts["gift-summary"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.staticTexts["gift-summary"].label.contains("no further renewals"), app.staticTexts["gift-summary"].label)
    }

    func testKeepGivingLeavesTheGiftActive() {
        let app = launch("--stub-gift-active")
        openGift(app)
        app.buttons["Cancel gift"].tap()
        XCTAssertTrue(app.buttons["Keep giving"].waitForExistence(timeout: 5))
        app.buttons["Keep giving"].tap()
        XCTAssertTrue(app.buttons["Cancel gift"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.staticTexts["gift-ending"].exists)
    }

    func testUpdateThePaymentMethodThroughTheHostedPage() {
        let app = launch("--stub-gift-active")
        openGift(app)
        XCTAssertTrue(app.buttons["update-payment"].waitForExistence(timeout: 10))
        app.buttons["update-payment"].tap()
        XCTAssertTrue(app.otherElements["hosted-page-stub"].waitForExistence(timeout: 10))
        app.buttons["stub-complete"].tap()
        XCTAssertTrue(app.staticTexts["gift-notice"].waitForExistence(timeout: 20))
        XCTAssertEqual(app.staticTexts["gift-notice"].label, "Your payment method was updated.")
        XCTAssertTrue(app.staticTexts["payment-status"].label.hasPrefix("Card updated"), app.staticTexts["payment-status"].label)
    }

    func testAFailedGiftReadShowsAMessageAndOpeningTheScreenRecovers() {
        let app = launch("--stub-gift-fail-first")
        XCTAssertTrue(app.staticTexts["gift-summary"].waitForExistence(timeout: 20))
        let failed = NSPredicate(format: "label == %@", "Your gift isn’t available right now.")
        expectation(for: failed, evaluatedWith: app.staticTexts["gift-summary"])
        waitForExpectations(timeout: 15)
        openGift(app)
        XCTAssertTrue(app.staticTexts["gift-monthly"].waitForExistence(timeout: 15), "the screen re-reads on open")
        XCTAssertEqual(app.staticTexts["gift-monthly"].label, "$150/month")
    }

    func testDeleteAccountWithAnActiveGiftOffersTheCancelFlowThenDeletes() {
        let app = launch("--stub-gift-active")
        XCTAssertTrue(app.buttons["open-settings"].waitForExistence(timeout: 20))
        app.buttons["open-settings"].tap()
        XCTAssertTrue(app.buttons["delete-start"].waitForExistence(timeout: 10))
        app.buttons["delete-start"].tap()
        let input = app.textFields["delete-input"]
        XCTAssertTrue(input.waitForExistence(timeout: 5))
        input.tap()
        input.typeText("DELETE")
        app.buttons["delete-confirm"].tap()

        // The server refuses (409): the screen explains and offers the real cancel flow.
        XCTAssertTrue(app.staticTexts["settings-action-error"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.staticTexts["settings-action-error"].label.contains("Cancel your monthly gift first"))
        XCTAssertTrue(app.buttons["delete-cancel-gift"].waitForExistence(timeout: 5))
        app.buttons["delete-cancel-gift"].tap()
        XCTAssertTrue(app.otherElements["gift-screen"].waitForExistence(timeout: 10))
        app.buttons["Cancel gift"].tap()
        XCTAssertTrue(app.buttons["End my gift"].waitForExistence(timeout: 5))
        app.buttons["End my gift"].tap()
        XCTAssertTrue(app.staticTexts["gift-ending"].waitForExistence(timeout: 10))
        app.buttons["gift-close"].tap()

        // With the gift no longer renewing, deleting goes through and the session ends.
        XCTAssertTrue(app.buttons["delete-confirm"].waitForExistence(timeout: 10))
        app.buttons["delete-confirm"].tap()
        XCTAssertTrue(app.buttons["Give $1 a day"].waitForExistence(timeout: 20), "deletion must end the session")
    }

    func testDeleteWithNoGiftStillJustDeletes() {
        let app = launch()
        XCTAssertTrue(app.buttons["open-settings"].waitForExistence(timeout: 20))
        app.buttons["open-settings"].tap()
        app.buttons["delete-start"].tap()
        let input = app.textFields["delete-input"]
        XCTAssertTrue(input.waitForExistence(timeout: 5))
        input.tap()
        input.typeText("DELETE")
        app.buttons["delete-confirm"].tap()
        XCTAssertTrue(app.buttons["Give $1 a day"].waitForExistence(timeout: 20))
    }
}
