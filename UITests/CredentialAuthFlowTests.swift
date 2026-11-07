import XCTest

/// Runs the REAL signup, email-link and password sign-in, set-password and session conformers against the DEBUG-only
/// scripted transport (`--stub-backend`). Script: password `correct horse battery` signs in; anything
/// else is the server's 401; the signup link is claimed with a token starting `stubclaim`.
@MainActor final class CredentialAuthFlowTests: XCTestCase {
    private let stubClaimLink = "https://stub.invalid/account/claim#token=stubclaim0123456789abcdef0123456789abcdef"

    private func launch() -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["--stub-backend"]
        app.launch()
        // Phase D: Welcome's "I already give — sign in" reaches the sign-in methods.
        XCTAssertTrue(app.buttons["I already give — sign in"].waitForExistence(timeout: 15))
        app.buttons["I already give — sign in"].tap()
        return app
    }

    private func type(_ text: String, into field: XCUIElement, in app: XCUIApplication) {
        XCTAssertTrue(field.waitForExistence(timeout: 5), "\(field)")
        field.tap()
        // Simulator Password AutoFill may offer a strong password on a new-password field; decline it.
        let own = app.buttons["Choose My Own Password"]
        if own.waitForExistence(timeout: 1) { own.tap() }
        field.typeText(text)
    }

    /// Replaces a field's contents by selecting them all first. Per-character delete keystrokes are dropped by the
    /// simulator keyboard, so they cannot clear a field reliably.
    private func replaceText(in field: XCUIElement, with text: String, app: XCUIApplication) {
        field.tap()
        field.press(forDuration: 1.0)
        let selectAll = app.menuItems["Select All"]
        XCTAssertTrue(selectAll.waitForExistence(timeout: 5), "the edit menu must offer Select All")
        selectAll.tap()
        field.typeText(text)
    }

    private func signInWithPassword(_ app: XCUIApplication, password: String) {
        // Phase D: password lives under the "More options" disclosure.
        app.buttons["More options"].tap()
        app.buttons["Sign in with email & password"].tap()
        type("alex@example.org", into: app.textFields["Email"], in: app)
        type(password, into: app.secureTextFields["Password"], in: app)
        app.buttons["password-sign-in-submit"].tap()
    }

    func testNewDonorSignupThenEmailedLinkLandsInDonorShell() {
        let app = launch()
        app.buttons["create-account"].tap()
        XCTAssertTrue(app.textFields["Full name"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.buttons["Create account"].isEnabled, "an empty form must not submit")
        type("Alex Rivera", into: app.textFields["Full name"], in: app)
        type("alex@example.org", into: app.textFields["Email"], in: app)
        type("78701", into: app.textFields["ZIP code"], in: app)
        XCTAssertFalse(app.buttons["Create account"].isEnabled, "city is required")
        type("Austin", into: app.textFields["City"], in: app)
        XCTAssertTrue(app.buttons["Create account"].isEnabled)
        app.buttons["Create account"].tap()

        XCTAssertTrue(app.staticTexts["signup-sent"].waitForExistence(timeout: 10), "signup must say a link was emailed")
        // A link that is not a DAD claim link is refused in place.
        type("https://example.com/not-ours", into: app.textFields["Paste your sign-in link"], in: app)
        app.buttons["signup-continue"].tap()
        XCTAssertTrue(app.staticTexts["signup-paste-error"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.buttons["open-settings"].exists)

        let paste = app.textFields["Paste your sign-in link"]
        let signupLink = stubClaimLink + "&next=/account/dashboard"
        replaceText(in: paste, with: signupLink, app: app)
        XCTAssertEqual(paste.value as? String, signupLink)
        app.buttons["signup-continue"].tap()

        XCTAssertTrue(app.buttons["open-settings"].waitForExistence(timeout: 15), "claiming the link must land in the donor shell")
        XCTAssertTrue(app.staticTexts["Hi, Alex"].waitForExistence(timeout: 10))
    }

    func testEmailLinkSignInThenClaimingTheLinkLandsInDonorShell() {
        let app = launch()
        app.buttons["Email me a sign-in link"].tap()
        XCTAssertTrue(app.otherElements["email-link-sign-in"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.buttons["email-link-submit"].isEnabled, "an empty address must not submit")
        type("alex@example.org", into: app.textFields["Email"], in: app)
        app.buttons["email-link-submit"].tap()

        XCTAssertTrue(app.staticTexts["signup-sent"].waitForExistence(timeout: 10), "the app must say a link was emailed")
        type(stubClaimLink, into: app.textFields["Paste your sign-in link"], in: app)
        app.buttons["signup-continue"].tap()
        XCTAssertTrue(app.buttons["open-settings"].waitForExistence(timeout: 15), "claiming the link must land in the donor shell")
    }

    func testPasswordSignInSuccessLandsInDonorShell() {
        let app = launch()
        signInWithPassword(app, password: "correct horse battery")
        XCTAssertTrue(app.buttons["open-settings"].waitForExistence(timeout: 15))
        XCTAssertTrue(app.staticTexts["Hi, Alex"].waitForExistence(timeout: 10))
    }

    func testWrongPasswordKeepsPersonSignedOutWithAnError() {
        let app = launch()
        signInWithPassword(app, password: "not the password")
        XCTAssertTrue(app.staticTexts["password-sign-in-error"].waitForExistence(timeout: 10))
        XCTAssertFalse(app.buttons["open-settings"].exists)
        XCTAssertEqual(app.secureTextFields["Password"].value as? String, "Password", "the typed secret must be cleared (placeholder shows)")
    }

    func testSetPasswordInSettingsRejectsWrongCurrentThenSaves() {
        let app = launch()
        signInWithPassword(app, password: "correct horse battery")
        XCTAssertTrue(app.buttons["open-settings"].waitForExistence(timeout: 15))
        app.buttons["open-settings"].tap()
        XCTAssertTrue(app.buttons["password-start"].waitForExistence(timeout: 10))
        app.buttons["password-start"].tap()

        XCTAssertFalse(app.buttons["password-save"].isEnabled)
        type("wrong current", into: app.secureTextFields["password-current"], in: app)
        type("a much longer passphrase", into: app.secureTextFields["password-new"], in: app)
        type("a much longer passphrase", into: app.secureTextFields["password-confirm"], in: app)
        XCTAssertTrue(app.buttons["password-save"].isEnabled)
        app.buttons["password-save"].tap()
        XCTAssertTrue(app.staticTexts["password-error"].waitForExistence(timeout: 10), "a wrong current password must explain itself")
        XCTAssertTrue(app.otherElements["settings-screen"].exists, "a typo must not end the session")
        XCTAssertFalse(app.staticTexts["settings-signed-out"].exists)

        let current = app.secureTextFields["password-current"]
        current.tap()
        current.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: 20))
        current.typeText("correct horse battery")
        app.buttons["password-save"].tap()
        XCTAssertTrue(app.staticTexts["password-saved"].waitForExistence(timeout: 10))
    }

    func testAppleGooglePasskeyAreHiddenWithAnExplanationWhenUnconfigured() {
        // Phase D: unavailable methods are no longer listed as disabled rows — they are hidden, with an
        // honest note that the build can't offer them. Phone (primary) and email (secondary) stay.
        let app = launch()
        XCTAssertTrue(app.buttons["Continue with phone"].waitForExistence(timeout: 10))
        for title in ["Sign in with Apple", "Sign in with Google", "Sign in with a passkey"] {
            XCTAssertFalse(app.buttons[title].exists, title)
        }
        XCTAssertTrue(app.buttons["Continue with phone"].isEnabled)
        XCTAssertTrue(app.buttons["Email me a sign-in link"].isEnabled)
        app.buttons["More options"].tap()
        XCTAssertTrue(app.buttons["Sign in with email & password"].isEnabled)
        XCTAssertTrue(app.staticTexts["methods-unavailable-note"].exists, "the reason must be visible text, not only a hint")
    }
}
