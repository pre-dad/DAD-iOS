import XCTest

/// The donor engagement home. Launches straight into the signed-in engagement
/// screen (a dedicated preview arg that doesn't disturb the other donor tests) and exercises
/// impact, the badges summary, and the rankings opt-out toggle (which renders inline — no OS
/// action sheet — so it is deterministic under XCUITest).
@MainActor final class EngagementFlowTests: XCTestCase {
    func testEngagementHomeRendersImpactAndBadges() {
        let app = XCUIApplication()
        app.launchArguments = ["--preview-engagement"]
        app.launchInForeground()

        let home = app.otherElements["engagement-home"]
        XCTAssertTrue(home.waitForExistence(timeout: 5), "engagement home should appear")

        let given = app.staticTexts["impact-given"]
        XCTAssertTrue(given.waitForExistence(timeout: 3))
        XCTAssertEqual(given.label, "$1,240") // 124_000 minor, known total

        XCTAssertTrue(app.staticTexts["badge-summary"].waitForExistence(timeout: 2))
        XCTAssertEqual(app.staticTexts["badge-summary"].label, "2 of 3 earned")
    }

    func testRankingOptOutHidesPosition() {
        let app = XCUIApplication()
        app.launchArguments = ["--preview-engagement"]
        app.launchInForeground()

        XCTAssertTrue(app.otherElements["engagement-home"].waitForExistence(timeout: 5))
        // Starts opted-in: a national position is shown.
        XCTAssertTrue(app.staticTexts["ranking-national"].waitForExistence(timeout: 3))

        app.buttons["Hide my ranking"].tap()
        // Opting out replaces the position with the not-shown message — inline, deterministic.
        XCTAssertTrue(app.staticTexts["ranking-optedout"].waitForExistence(timeout: 3))
        XCTAssertFalse(app.staticTexts["ranking-national"].exists)
    }
}
