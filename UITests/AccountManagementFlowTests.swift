import XCTest

/// Runs the REAL `WireAccountManagement` against the DEBUG-only scripted transport (`--stub-backend`):
/// saving contact details, requesting an email change, linking an employer by company code and joining a
/// team, and ending other sessions and every session. Script: company code `ACME42` links "Acme"; an email
/// starting `taken` is refused as belonging to another account.
@MainActor final class AccountManagementFlowTests: XCTestCase {
    private func openSettings() -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["--stub-backend", "--stub-signed-in"]
        app.launch()
        XCTAssertTrue(app.buttons["open-settings"].waitForExistence(timeout: 20))
        app.buttons["open-settings"].tap()
        XCTAssertTrue(app.otherElements["settings-screen"].waitForExistence(timeout: 10))
        return app
    }

    func testContactDetailsSaveANormalizedPhone() {
        let app = openSettings()
        XCTAssertFalse(app.buttons["details-save"].waitForExistence(timeout: 10) && app.buttons["details-save"].isEnabled,
                       "nothing changed yet")
        app.textFields["details-phone"].replaceText(with: "415555012", in: app)
        XCTAssertTrue(app.staticTexts["details-phone-hint"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.buttons["details-save"].isEnabled)
        app.textFields["details-phone"].typeText("3")
        XCTAssertTrue(app.buttons["details-save"].isEnabled)
        app.buttons["details-save"].tap()
        XCTAssertTrue(app.staticTexts["details-saved"].waitForExistence(timeout: 10))
        XCTAssertEqual(app.textFields["details-phone"].value as? String, "+14155550123")
    }

    func testEmailChangeExplainsAConflictThenSends() {
        let app = openSettings()
        app.buttons["email-change-start"].tap()
        app.textFields["email-change-input"].replaceText(with: "taken@example.org", in: app)
        app.buttons["email-change-submit"].tap()
        XCTAssertTrue(app.staticTexts["email-change-error"].waitForExistence(timeout: 10))
        app.textFields["email-change-input"].replaceText(with: "new@example.org", in: app)
        app.buttons["email-change-submit"].tap()
        XCTAssertTrue(app.staticTexts["email-change-sent"].waitForExistence(timeout: 10))
    }

    func testCompanyCodeLinksAnEmployerThenJoinsATeam() {
        let app = openSettings()
        app.textFields["employer-code"].replaceText(with: "WRONG", in: app)
        app.buttons["employer-enroll"].tap()
        XCTAssertTrue(app.staticTexts["employer-error"].waitForExistence(timeout: 10))
        app.textFields["employer-code"].replaceText(with: "ACME42", in: app)
        app.buttons["employer-enroll"].tap()
        XCTAssertTrue(app.staticTexts["employer-linked"].waitForExistence(timeout: 10))
        XCTAssertFalse(app.staticTexts["employer-error"].exists)
        XCTAssertTrue(app.otherElements["leaderboard-55555555-5555-4555-8555-555555555555"].exists
                      || app.staticTexts["leaderboard-55555555-5555-4555-8555-555555555555"].exists)
        app.textFields["employer-team-name"].replaceText(with: "Platform", in: app)
        app.buttons["employer-join-team"].tap()
        XCTAssertTrue(app.staticTexts["employer-team"].waitForExistence(timeout: 10))
        XCTAssertEqual(app.staticTexts["employer-team"].label, "Your team: Platform")
    }

    func testEndingOtherSessionsThenEverySessionSignsOut() {
        let app = openSettings()
        let other = app.buttons["session-revoke-22222222-2222-4222-8222-222222222222"]
        XCTAssertTrue(other.waitForExistence(timeout: 10))
        other.tap()
        XCTAssertTrue(app.staticTexts["You’re not signed in anywhere else."].waitForExistence(timeout: 10))
        XCTAssertFalse(other.exists)
        app.buttons["sessions-sign-out-everywhere"].tap()
        XCTAssertTrue(app.buttons["Give $1 a day"].waitForExistence(timeout: 15)
                      || app.otherElements["sign-in-methods"].waitForExistence(timeout: 5),
                      "ending every session must leave the donor shell")
        XCTAssertFalse(app.buttons["open-settings"].exists)
    }
}
