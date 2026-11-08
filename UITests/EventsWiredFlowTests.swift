import XCTest

/// Runs the REAL `WireEvents`, `AccountSession` and `WireAPI` against the DEBUG-only scripted transport
/// (`--stub-backend`): browse the list, open a detail, reserve and cancel, join a waitlist, the
/// invite-only gate, check-in inside and outside the event window, add to calendar and a 403.
@MainActor final class EventsWiredFlowTests: XCTestCase {
    private let park = "11111111-0000-4000-8000-000000000001"
    private let foodBank = "11111111-0000-4000-8000-000000000002"
    private let dinner = "11111111-0000-4000-8000-000000000003"
    private let workshop = "11111111-0000-4000-8000-000000000004"
    private let brunch = "11111111-0000-4000-8000-000000000005"

    /// Well-formed check-in tokens (`<22>.<43>` base64url): the stub accepts the workshop's; the other is well formed but unknown.
    private let workshopToken = "stubworkshop0stubworks.stubworkshopcheckin0stubworkshopcheckin0stu"
    private let unknownToken = "unknown0unknown0unknow.unknowncheckin0unknowncheckin0unknownchecki"

    private func launch(_ extra: String...) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["--stub-backend", "--stub-signed-in"] + extra
        app.launchInForeground()
        return app
    }

    private func openEvents(_ app: XCUIApplication) {
        // Events is the Events tab, not a card/sheet on Home.
        let events = app.tabBars.buttons["Events"]
        XCTAssertTrue(events.waitForExistence(timeout: 20))
        events.tap()
        XCTAssertTrue(app.otherElements["events-home"].waitForExistence(timeout: 10))
    }

    private func openDetail(_ app: XCUIApplication, _ id: String) {
        let details = app.buttons["details-\(id)"]
        XCTAssertTrue(details.waitForExistence(timeout: 10))
        details.tap()
        XCTAssertTrue(app.buttons["events-back"].waitForExistence(timeout: 5))
    }

    func testBrowseDetailReserveThenCancel() {
        let app = launch()
        openEvents(app)
        XCTAssertTrue(app.staticTexts["spots-\(park)"].waitForExistence(timeout: 10))
        XCTAssertEqual(app.staticTexts["spots-\(park)"].label, "8 spots left")
        openDetail(app, park)
        XCTAssertTrue(app.staticTexts["event-time"].exists)
        XCTAssertTrue(app.staticTexts["event-description"].exists)

        app.buttons["reserve-\(park)"].tap()
        XCTAssertTrue(app.staticTexts["reserve-confirm"].waitForExistence(timeout: 10))
        XCTAssertEqual(app.staticTexts["reserve-confirm"].label, "You’re going")
        XCTAssertTrue(app.staticTexts["status-\(park)"].waitForExistence(timeout: 5))
        XCTAssertEqual(app.staticTexts["spots-\(park)"].label, "7 spots left")

        let cancel = app.buttons["cancel-\(park)"]
        XCTAssertTrue(cancel.waitForExistence(timeout: 5))
        cancel.tap()
        XCTAssertTrue(app.buttons["Keep it"].waitForExistence(timeout: 3))
        app.buttons["confirm-cancel-\(park)"].tap()
        XCTAssertTrue(app.buttons["reserve-\(park)"].waitForExistence(timeout: 10), "cancelling returns the event to reservable")
        XCTAssertEqual(app.staticTexts["spots-\(park)"].label, "8 spots left")
    }

    func testFullEventJoinsTheWaitlist() {
        let app = launch()
        openEvents(app)
        XCTAssertTrue(app.staticTexts["spots-\(foodBank)"].waitForExistence(timeout: 10))
        XCTAssertEqual(app.staticTexts["spots-\(foodBank)"].label, "Full")
        let join = app.buttons["waitlist-\(foodBank)"]
        XCTAssertTrue(join.exists)
        join.tap()
        XCTAssertTrue(app.staticTexts["reserve-confirm"].waitForExistence(timeout: 10))
        XCTAssertEqual(app.staticTexts["reserve-confirm"].label, "You’re on the waitlist")
        XCTAssertEqual(app.staticTexts["status-\(foodBank)"].label, "On the waitlist")
    }

    func testInviteOnlyEventIsShownWhenTheServerUnlocksIt() {
        let app = launch()
        openEvents(app)
        XCTAssertTrue(app.buttons["details-\(dinner)"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.staticTexts["invite-only-badge"].exists)
        openDetail(app, dinner)
        XCTAssertEqual(app.staticTexts["invitation-note"].label, "Invitation earned at Founding Donor")
    }

    func testInviteOnlyEventIsAbsentWithoutTheBadge() {
        let app = launch("--stub-events-ungated")
        openEvents(app)
        XCTAssertTrue(app.buttons["details-\(park)"].waitForExistence(timeout: 10))
        XCTAssertFalse(app.buttons["details-\(dinner)"].exists, "the server hides it, so the app never shows it")
        XCTAssertFalse(app.staticTexts["invite-only-badge"].exists)
    }

    func testCheckInInsideTheWindowSucceedsAndASecondScanIsRecognised() {
        let app = launch()
        openEvents(app)
        openDetail(app, workshop)
        XCTAssertFalse(app.buttons["cancel-\(workshop)"].exists, "an event in progress can no longer be cancelled")
        let code = app.textFields["checkin-code"]
        XCTAssertTrue(code.waitForExistence(timeout: 5))
        code.tap()
        code.typeText(workshopToken)
        app.buttons["checkin-submit"].tap()
        XCTAssertTrue(app.staticTexts["checkin-result"].waitForExistence(timeout: 10))
        XCTAssertEqual(app.staticTexts["checkin-result"].label, "You’re checked in. Thanks for showing up.")
        let status = app.staticTexts["status-\(workshop)"]
        XCTAssertTrue(status.waitForExistence(timeout: 10), "checked_in_at drives the checked-in state")
        XCTAssertTrue(status.label.hasPrefix("Checked in · "), status.label)
        XCTAssertTrue(status.label.hasSuffix("CST") || status.label.hasSuffix("CDT"), "shown in the event's zone: \(status.label)")
        app.buttons["checkin-submit"].tap()
        XCTAssertTrue(app.staticTexts["You were already checked in."].waitForExistence(timeout: 10))
    }

    func testAWrongCodeIsExplainedNotAccepted() {
        let app = launch()
        openEvents(app)
        openDetail(app, workshop)
        let code = app.textFields["checkin-code"]
        XCTAssertTrue(code.waitForExistence(timeout: 5))
        code.tap()
        code.typeText(unknownToken)
        app.buttons["checkin-submit"].tap()
        XCTAssertTrue(app.staticTexts["checkin-result"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.staticTexts["checkin-result"].label.hasPrefix("That code didn’t work."))
    }

    func testAMalformedCodeIsRefusedBeforeAnyRequest() {
        let app = launch()
        openEvents(app)
        openDetail(app, workshop)
        let code = app.textFields["checkin-code"]
        XCTAssertTrue(code.waitForExistence(timeout: 5))
        code.tap()
        code.typeText("NOTACODE")
        app.buttons["checkin-submit"].tap()
        XCTAssertTrue(app.staticTexts["checkin-result"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.staticTexts["checkin-result"].label.hasPrefix("That doesn’t look like a full check-in code."))
    }

    func testEventTimesCarryTheEventZoneAbbreviation() {
        let app = launch()
        openEvents(app)
        openDetail(app, park)
        let label = app.staticTexts["event-time"].label
        XCTAssertTrue(label.hasSuffix("CST") || label.hasSuffix("CDT"), "the stub venue is America/Chicago: \(label)")
    }

    func testCheckInOutsideTheWindowOffersNoScannerAndSaysWhenItOpens() {
        let app = launch()
        openEvents(app)
        openDetail(app, park)
        app.buttons["reserve-\(park)"].tap()
        XCTAssertTrue(app.staticTexts["checkin-closed"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.staticTexts["checkin-closed"].label.hasPrefix("Check-in opens "))
        XCTAssertFalse(app.buttons["checkin-submit"].exists)
        XCTAssertFalse(app.buttons["checkin-scan"].exists)
    }

    func testAddToCalendarPresentsTheShareSheet() {
        let app = launch()
        openEvents(app)
        openDetail(app, park)
        let add = app.buttons["add-calendar-\(park)"]
        XCTAssertTrue(add.waitForExistence(timeout: 5))
        add.tap()
        let sheet = app.otherElements["ActivityListView"]
        let bar = app.navigationBars["park-cleanup.ics"]
        XCTAssertTrue(sheet.waitForExistence(timeout: 10) || bar.waitForExistence(timeout: 5) || app.collectionViews.firstMatch.waitForExistence(timeout: 5),
                      "the system share sheet should present the .ics")
    }

    func testAForbiddenReservationSaysNotEligible() {
        let app = launch()
        openEvents(app)
        let reserve = app.buttons["reserve-\(brunch)"]
        XCTAssertTrue(reserve.waitForExistence(timeout: 10))
        reserve.tap()
        let error = app.staticTexts["event-error-\(brunch)"]
        XCTAssertTrue(error.waitForExistence(timeout: 10))
        XCTAssertEqual(error.label, "You’re not eligible to reserve this event.")
        XCTAssertTrue(app.buttons["reserve-\(brunch)"].exists, "the event is unchanged")
        XCTAssertFalse(app.staticTexts["reserve-confirm"].exists)
    }

    func testAFailedListLoadCanBeRetried() {
        let app = launch("--stub-events-fail-first")
        openEvents(app)
        XCTAssertTrue(app.staticTexts["events-error"].waitForExistence(timeout: 10))
        app.buttons["events-retry"].tap()
        XCTAssertTrue(app.buttons["details-\(park)"].waitForExistence(timeout: 10))
    }
}
