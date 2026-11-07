import XCTest

/// The donor events home. Launches straight into the signed-in events screen (a
/// dedicated preview arg that doesn't disturb the other donor tests) and exercises the list,
/// an invite-only marker, a reserve → inline confirmation, and the inline cancel confirmation
/// (no OS action sheet, which keeps it deterministic under XCUITest).
@MainActor final class EventsFlowTests: XCTestCase {
    func testEventsHomeRendersListAndInviteOnlyMarker() {
        let app = XCUIApplication()
        app.launchArguments = ["--preview-events"]
        app.launch()

        let home = app.otherElements["events-home"]
        XCTAssertTrue(home.waitForExistence(timeout: 5), "events home should appear")

        // The invite-only event carries a visible marker (E-5).
        XCTAssertTrue(app.staticTexts["invite-only-badge"].waitForExistence(timeout: 3))
        // A reservable public event offers Reserve.
        XCTAssertTrue(app.buttons["reserve-e1"].waitForExistence(timeout: 3))
        // The full event offers Join waitlist (E-4).
        XCTAssertTrue(app.buttons["waitlist-e2"].waitForExistence(timeout: 3))
    }

    func testReserveShowsInlineConfirmation() {
        let app = XCUIApplication()
        app.launchArguments = ["--preview-events"]
        app.launch()

        XCTAssertTrue(app.otherElements["events-home"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["reserve-e1"].waitForExistence(timeout: 3))
        app.buttons["reserve-e1"].tap()

        // Confirmation renders inline — no action sheet.
        XCTAssertTrue(app.staticTexts["reserve-confirm"].waitForExistence(timeout: 3))
    }

    func testCancelUsesInlineConfirmation() {
        let app = XCUIApplication()
        app.launchArguments = ["--preview-events"]
        app.launch()

        XCTAssertTrue(app.otherElements["events-home"].waitForExistence(timeout: 5))
        // Reserve first so a cancel action appears.
        XCTAssertTrue(app.buttons["reserve-e1"].waitForExistence(timeout: 3))
        app.buttons["reserve-e1"].tap()
        // Dismiss the confirmation card to get back to the row.
        if app.buttons["Done"].waitForExistence(timeout: 3) { app.buttons["Done"].tap() }

        // Now the reserved event offers Cancel; tapping it shows the INLINE confirm block.
        let cancel = app.buttons["cancel-e1"]
        XCTAssertTrue(cancel.waitForExistence(timeout: 3))
        cancel.tap()
        XCTAssertTrue(app.otherElements["cancel-confirm-e1"].waitForExistence(timeout: 3))
        // "Keep it" (cancel role) is a plain in-tree button, not an OS sheet action.
        XCTAssertTrue(app.buttons["Keep it"].waitForExistence(timeout: 2))
    }
}
