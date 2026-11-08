import XCTest

/// Runs the REAL `WireDashboard`, `AccountSession` and `WireAPI` against the DEBUG-only scripted
/// transport (`--stub-backend`) and starts with a stored session (`--stub-signed-in`), so the donor
/// home renders stubbed server data through release code paths with no network.
@MainActor final class DashboardFlowTests: XCTestCase {
    private func launch(_ extra: String...) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["--stub-backend", "--stub-signed-in"] + extra
        app.launchInForeground()
        return app
    }

    private func text(_ app: XCUIApplication, _ id: String) -> XCUIElement { app.staticTexts[id] }

    func testSignedInDashboardRendersStubbedServerData() {
        let app = launch()
        XCTAssertTrue(app.staticTexts["Hi, Alex"].waitForExistence(timeout: 15))
        XCTAssertTrue(text(app, "streak-count").waitForExistence(timeout: 10))
        XCTAssertEqual(text(app, "streak-count").label, "18-day streak")
        XCTAssertEqual(text(app, "streak-next").label, "12 days to your 30-day milestone")
        XCTAssertEqual(text(app, "rank-national").label, "Top 2% nationally")
        XCTAssertEqual(text(app, "dash-given").label, "$1,240")
        XCTAssertTrue(text(app, "network-annualized").label.contains("$4,745"))
        XCTAssertTrue(text(app, "founding-donor").exists)
        XCTAssertEqual(text(app, "initiative-title").label, "Meals on Wheels")
        XCTAssertTrue(text(app, "initiative-note").exists, "the display-attribution note must accompany the initiative")
    }

    func testGiftHistoryPagesToTheEndAndShowsAGiftRecord() {
        let app = launch()
        XCTAssertTrue(app.buttons["open-history"].waitForExistence(timeout: 15))
        app.buttons["open-history"].tap()
        XCTAssertTrue(app.buttons["gift-row-0"].waitForExistence(timeout: 10))
        XCTAssertEqual(text(app, "history-year-total").label, "$3,515")
        XCTAssertFalse(app.buttons["gift-row-50"].exists, "only the first page is loaded")

        app.buttons["history-more"].tap()
        XCTAssertTrue(app.buttons["gift-row-99"].waitForExistence(timeout: 10))
        XCTAssertFalse(app.buttons["gift-row-100"].exists)
        app.buttons["history-more"].tap()
        XCTAssertTrue(app.buttons["gift-row-119"].waitForExistence(timeout: 10))
        XCTAssertFalse(app.buttons["history-more"].exists, "the last page ends pagination")

        app.buttons["gift-row-0"].tap()
        XCTAssertTrue(app.otherElements["receipt-detail"].waitForExistence(timeout: 10))
        // History is a push from Home; return with the navigation back button.
        app.navigationBars.buttons.element(boundBy: 0).tap()
        XCTAssertTrue(app.buttons["open-history"].waitForExistence(timeout: 5))
    }

    func testEmptyStates() {
        let app = launch("--stub-dashboard-empty")
        XCTAssertTrue(app.otherElements["dashboard-preparing"].waitForExistence(timeout: 15))
        XCTAssertTrue(text(app, "initiative-none").waitForExistence(timeout: 10))
        XCTAssertFalse(text(app, "streak-count").exists)
        app.buttons["open-history"].tap()
        XCTAssertTrue(text(app, "history-empty").waitForExistence(timeout: 10))
    }

    func testErrorsOfferRetryAndRecover() {
        let app = launch("--stub-dashboard-fail-first")
        XCTAssertTrue(text(app, "dashboard-error").waitForExistence(timeout: 15))
        app.buttons["dashboard-retry"].tap()
        XCTAssertTrue(text(app, "streak-count").waitForExistence(timeout: 10))

        app.buttons["open-history"].tap()
        XCTAssertTrue(text(app, "history-error").waitForExistence(timeout: 10))
        app.buttons["history-retry"].tap()
        XCTAssertTrue(app.buttons["gift-row-0"].waitForExistence(timeout: 10))
    }

    func testOptedOutAndUnknownFiguresAreNeverShownAsZero() {
        let app = launch("--stub-dashboard-unranked")
        XCTAssertTrue(text(app, "streak-unknown").waitForExistence(timeout: 15))
        XCTAssertFalse(text(app, "rank-national").exists)
        XCTAssertFalse(text(app, "rank-unranked").exists, "an opted-out donor sees no rank line")
        XCTAssertEqual(text(app, "dash-given").label, "—")
        XCTAssertFalse(app.otherElements["network-card"].exists)
    }
}
