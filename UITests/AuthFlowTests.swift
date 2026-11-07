import XCTest

@MainActor final class AuthFlowTests: XCTestCase {
    /// A session-less launch lands on the Welcome screen; "I already give — sign in" reaches the
    /// sign-in methods, and the phone method opens the SMS-code journey (PRD §5.1, D-1).
    func testSignedOutLaunchReachesPhoneSignIn() {
        let app = XCUIApplication()
        app.launchArguments = ["--preview-signed-out"]
        app.launch()

        // Welcome is the unauthenticated entry point; its sign-in path reaches the methods.
        XCTAssertTrue(app.buttons["I already give — sign in"].waitForExistence(timeout: 10))
        app.buttons["I already give — sign in"].tap()

        // Sign-in method picker: phone is the primary, labelled "Continue with phone".
        XCTAssertTrue(app.buttons["Continue with phone"].waitForExistence(timeout: 10))
        app.buttons["Continue with phone"].tap()

        // Phone + SMS code screen renders with its phone field.
        XCTAssertTrue(app.staticTexts["Sign in with your phone"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.textFields["Phone number"].exists)
    }

    /// A valid phone number advances to code entry, and Send code stays disabled for junk input.
    func testPhoneNumberAdvancesToCodeEntry() {
        let app = XCUIApplication()
        app.launchArguments = ["--preview-signed-out"]
        app.launch()

        app.buttons["I already give — sign in"].tap()
        XCTAssertTrue(app.buttons["Continue with phone"].waitForExistence(timeout: 10))
        app.buttons["Continue with phone"].tap()

        let phone = app.textFields["Phone number"]
        XCTAssertTrue(phone.waitForExistence(timeout: 5))
        XCTAssertFalse(app.buttons["Send code"].isEnabled)
        phone.tap()
        phone.typeText("+14155551234")
        XCTAssertTrue(app.buttons["Send code"].isEnabled)
        app.buttons["Send code"].tap()

        let code = app.textFields["Verification code"]
        XCTAssertTrue(code.waitForExistence(timeout: 5))
        XCTAssertFalse(app.buttons["Verify"].isEnabled)
        code.tap()
        code.typeText("123456")
        XCTAssertTrue(app.buttons["Verify"].isEnabled)
    }

    /// Methods without a wired transport are HIDDEN (not shown disabled); the available
    /// phone method is present and enabled, and the honest "not in this build" note remains.
    func testUnwiredMethodsAreHidden() {
        let app = XCUIApplication()
        app.launchArguments = ["--preview-signed-out"]
        app.launch()

        app.buttons["I already give — sign in"].tap()
        XCTAssertTrue(app.buttons["Continue with phone"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.buttons["Continue with phone"].isEnabled)
        XCTAssertFalse(app.buttons["Sign in with Apple"].exists, "unavailable methods are not listed")
        XCTAssertFalse(app.buttons["Sign in with Google"].exists)
        XCTAssertFalse(app.buttons["Sign in with a passkey"].exists)
        XCTAssertTrue(app.staticTexts["methods-unavailable-note"].exists)
    }
}
