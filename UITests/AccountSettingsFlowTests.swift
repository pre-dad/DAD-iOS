import XCTest

/// The account & settings screen, including the in-app account-deletion flow the App Store requires.
/// Launches straight into the signed-in settings screen via a dedicated preview arg. Covers: renders
/// profile + toggles, the delete-account confirm gate stays disabled until the exact word is typed
/// (§6.12), and sign-out leaves the shell.
@MainActor final class AccountSettingsFlowTests: XCTestCase {
    private func launch(_ extraArguments: String...) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["--preview-settings"] + extraArguments
        app.launchInForeground()
        return app
    }

    func testSettingsRendersProfileAndToggles() {
        let app = launch()

        XCTAssertTrue(app.otherElements["settings-screen"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["settings-email"].waitForExistence(timeout: 3))
        XCTAssertTrue(app.switches["ranking-toggle"].waitForExistence(timeout: 3))
        XCTAssertTrue(app.switches["pref-push_streak_at_risk"].exists)
        XCTAssertTrue(app.staticTexts["settings-version"].exists)
        XCTAssertTrue(app.staticTexts["settings-preview-note"].exists)
    }

    func testDeleteGateDisabledUntilConfirmWordTyped() {
        let app = launch()

        XCTAssertTrue(app.otherElements["settings-screen"].waitForExistence(timeout: 5))
        let start = app.buttons["delete-start"]
        XCTAssertTrue(start.waitForExistence(timeout: 3))
        start.tap()

        let confirm = app.buttons["delete-confirm"]
        XCTAssertTrue(confirm.waitForExistence(timeout: 3))
        // Disabled with no / wrong text.
        XCTAssertFalse(confirm.isEnabled)
        let field = app.textFields["delete-input"]
        XCTAssertTrue(field.waitForExistence(timeout: 2))
        field.tap()
        field.typeText("DELETE")
        // Enabled once the exact word is present.
        XCTAssertTrue(confirm.isEnabled)
    }

    func testSignOutLeavesTheShell() {
        let app = launch()

        XCTAssertTrue(app.otherElements["settings-screen"].waitForExistence(timeout: 5))
        let signout = app.buttons["settings-signout"]
        XCTAssertTrue(signout.waitForExistence(timeout: 3))
        signout.tap()
        XCTAssertTrue(app.staticTexts["settings-signed-out"].waitForExistence(timeout: 3))
    }

    func testConfirmedDeleteLeavesTheShell() {
        let app = launch()

        XCTAssertTrue(app.buttons["delete-start"].waitForExistence(timeout: 5))
        app.buttons["delete-start"].tap()
        let field = app.textFields["delete-input"]
        XCTAssertTrue(field.waitForExistence(timeout: 3))
        field.tap()
        field.typeText("DELETE")
        app.buttons["delete-confirm"].tap()
        XCTAssertTrue(app.staticTexts["settings-signed-out"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.buttons["delete-confirm"].exists)
    }

    func testKeepMyAccountBacksOutAndClearsTheTypedWord() {
        let app = launch()

        XCTAssertTrue(app.buttons["delete-start"].waitForExistence(timeout: 5))
        app.buttons["delete-start"].tap()
        let field = app.textFields["delete-input"]
        XCTAssertTrue(field.waitForExistence(timeout: 3))
        field.tap()
        field.typeText("DELETE")
        app.buttons["Keep my account"].tap()
        XCTAssertTrue(app.buttons["delete-start"].waitForExistence(timeout: 3))
        app.buttons["delete-start"].tap()
        XCTAssertTrue(app.buttons["delete-confirm"].waitForExistence(timeout: 3))
        XCTAssertFalse(app.buttons["delete-confirm"].isEnabled, "the typed word must not survive backing out")
    }

    func testLargestAccessibilityTextStillReachesSignOut() {
        let app = launch("-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityXXXL")

        XCTAssertTrue(app.buttons["settings-signout"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["delete-start"].exists)
        for _ in 0..<10 where !app.buttons["settings-signout"].isHittable { app.swipeUp() }
        XCTAssertTrue(app.buttons["settings-signout"].isHittable, "sign-out remains reachable at the largest text size")
        let screenshot = XCTAttachment(screenshot: app.screenshot())
        screenshot.name = "Settings largest text"
        screenshot.lifetime = .keepAlways
        add(screenshot)
    }

    func testVolunteerInterestsCanBeAddedAndRemoved() {
        let app = launch()

        XCTAssertTrue(app.otherElements["settings-screen"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.otherElements["interest-row-Food drives"].waitForExistence(timeout: 5), "the saved interest loads")

        let field = app.textFields["interest-input"]
        XCTAssertTrue(field.waitForExistence(timeout: 3))
        field.tap()
        field.typeText("  Tutoring ")
        app.buttons["interest-add"].tap()
        XCTAssertTrue(app.otherElements["interest-row-Tutoring"].waitForExistence(timeout: 5), "added trimmed")

        field.tap()
        field.typeText("tutoring")
        app.buttons["interest-add"].tap()
        XCTAssertTrue(app.staticTexts["interest-error"].waitForExistence(timeout: 5), "a duplicate is refused")

        let remove = app.buttons["Remove Food drives"]
        XCTAssertTrue(remove.exists, "VoiceOver label names the interest")
        remove.tap()
        let gone = NSPredicate(format: "exists == false")
        expectation(for: gone, evaluatedWith: app.otherElements["interest-row-Food drives"])
        waitForExpectations(timeout: 5)
        XCTAssertTrue(app.otherElements["interest-row-Tutoring"].exists)
    }
}
