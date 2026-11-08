import XCTest

/// Runs the REAL sign-in, session and account-deletion conformers (WireAuth, AccountSession,
/// WireAccountSettings) against the DEBUG-only scripted transport (`--stub-backend`), so the
/// release code path is exercised in the simulator with no network.
@MainActor final class StubBackendFlowTests: XCTestCase {
    private func signIn(_ app: XCUIApplication, code: String) {
        // Welcome's donor sign-in path is "I already give — sign in"; phone is "Continue with phone".
        XCTAssertTrue(app.buttons["I already give — sign in"].waitForExistence(timeout: 15))
        app.buttons["I already give — sign in"].tap()
        app.buttons["Continue with phone"].tap()
        let phone = app.textFields["Phone number"]
        XCTAssertTrue(phone.waitForExistence(timeout: 5))
        phone.tap()
        phone.typeText("+14155551234")
        app.buttons["Send code"].tap()
        let field = app.textFields["Verification code"]
        XCTAssertTrue(field.waitForExistence(timeout: 5))
        field.tap()
        field.typeText(code)
        app.buttons["Verify"].tap()
    }

    func testSignInThenDeleteAccountReturnsToSignIn() {
        let app = XCUIApplication()
        app.launchArguments = ["--stub-backend"]
        app.launchInForeground()
        signIn(app, code: "123456")

        XCTAssertTrue(app.buttons["open-settings"].waitForExistence(timeout: 15))
        app.buttons["open-settings"].tap()
        XCTAssertTrue(app.buttons["delete-start"].waitForExistence(timeout: 10))
        app.buttons["delete-start"].tap()
        let input = app.textFields["delete-input"]
        XCTAssertTrue(input.waitForExistence(timeout: 5))
        input.tap()
        input.typeText("DELETE")
        app.buttons["delete-confirm"].tap()

        XCTAssertTrue(app.buttons["Give $1 a day"].waitForExistence(timeout: 15), "deletion must end the session")
    }

    func testWrongCodeKeepsPersonSignedOut() {
        let app = XCUIApplication()
        app.launchArguments = ["--stub-backend"]
        app.launchInForeground()
        signIn(app, code: "654321")
        XCTAssertFalse(app.buttons["open-settings"].waitForExistence(timeout: 4))
        XCTAssertTrue(app.textFields["Verification code"].exists)
    }

    func testTheAnalyticsQuestionIsAskedOnceAndRemembered() {
        // The analytics question is a sheet shown once after first sign-in, not part of Welcome.
        let app = XCUIApplication()
        app.launchArguments = ["--stub-backend", "--stub-analytics-unset"]
        app.launchInForeground()
        signIn(app, code: "123456")
        XCTAssertTrue(app.buttons["analytics-allow"].waitForExistence(timeout: 20), "the question is asked after sign-in")
        app.buttons["analytics-allow"].tap()
        XCTAssertFalse(app.buttons["analytics-allow"].waitForExistence(timeout: 2), "an answered question is not asked again")
        XCTAssertTrue(app.buttons["open-settings"].waitForExistence(timeout: 10), "the donor shell is reachable")
    }

    func testATappedNotificationOpensItsScreen() {
        let app = XCUIApplication()
        app.launchArguments = ["--stub-backend", "--stub-signed-in", "--stub-push-tap-gifts"]
        app.launchInForeground()
        XCTAssertTrue(app.buttons["gift-row-0"].waitForExistence(timeout: 20), "the gifts notification opens gift history")
    }

    func testAnInviteLinkNamesTheReferrerBeforeSignIn() {
        let app = XCUIApplication()
        app.launchArguments = ["--stub-backend", "--stub-open-invite"]
        app.launchInForeground()
        let invitation = app.staticTexts["auth-invitation"]
        XCTAssertTrue(invitation.waitForExistence(timeout: 20), "the opened invite link is captured natively")
        XCTAssertEqual(invitation.label, "Alex R invited you to give with DAD.")
    }
}
