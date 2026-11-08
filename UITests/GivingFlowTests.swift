import XCTest

/// The donor giving journey. Launches straight into the set-gift screen (a
/// dedicated preview arg that doesn't disturb the signed-in donor-landing tests) and
/// exercises the $1–$30/day stepper and the cancel confirmation.
@MainActor final class GivingFlowTests: XCTestCase {
    func testSetGiftScreenRendersAndSteps() {
        let app = XCUIApplication()
        app.launchArguments = ["--preview-giving"]
        app.launchInForeground()

        let screen = app.otherElements["gift-screen"]
        XCTAssertTrue(screen.waitForExistence(timeout: 5), "gift screen should appear")

        // The preview gift starts at $1/day; incrementing moves it up a $1/day step.
        let daily = app.staticTexts["gift-daily"]
        XCTAssertTrue(daily.waitForExistence(timeout: 2))
        XCTAssertEqual(daily.label, "$1/day")

        // The ± stepper is revealed by the "Other" amount option.
        app.buttons["amount-other"].tap()
        XCTAssertTrue(app.buttons["Increase gift"].waitForExistence(timeout: 5))
        app.buttons["Increase gift"].tap()
        XCTAssertEqual(app.staticTexts["gift-daily"].label, "$2/day")
    }

    func testCancelConfirmationAppears() {
        let app = XCUIApplication()
        app.launchArguments = ["--preview-giving"]
        app.launchInForeground()

        XCTAssertTrue(app.otherElements["gift-screen"].waitForExistence(timeout: 5))
        let cancel = app.buttons["Cancel gift"]
        XCTAssertTrue(cancel.waitForExistence(timeout: 3), "an active gift should offer cancel")
        cancel.tap()
        // The confirmation dialog states the ends-streak consequence.
        XCTAssertTrue(app.buttons["Keep giving"].waitForExistence(timeout: 3))
    }
}
