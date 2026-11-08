import XCTest

/// The partner portal. The preview args (admin / viewer) launch straight into the signed-in
/// partner shell; the stub-backend journeys run the real partner conformers from the emailed link to
/// sign-out. Covers verified-or-hidden Overview figures (§7.3), admin-vs-viewer capability gating (§7.2)
/// and the organization tools (profile, users, reports).
@MainActor final class PartnerFlowTests: XCTestCase {
    func testAdminPortalRendersVerifiedFiguresAndCanManage() {
        let app = XCUIApplication()
        app.launchArguments = ["--preview-partner"]
        app.launchInForeground()

        let portal = app.otherElements["partner-portal"]
        XCTAssertTrue(portal.waitForExistence(timeout: 5), "partner portal should appear")

        // Verified figures render; the unverified "deployed" figure is intentionally ABSENT (§7.3).
        XCTAssertTrue(app.staticTexts["partner-committed"].waitForExistence(timeout: 3))
        XCTAssertTrue(app.staticTexts["partner-reached"].waitForExistence(timeout: 3))
        XCTAssertFalse(app.staticTexts["partner-deployed"].exists, "unverified figure must be hidden, not estimated")
        // The "Verified by DAD" assurance line is present (§11).
        XCTAssertTrue(app.staticTexts["partner-verified-line"].exists)
        // Admin can manage users.
        app.buttons["Organization"].tap()
        XCTAssertTrue(app.buttons["partner-invite"].waitForExistence(timeout: 3))
    }

    func testInviteNeedsValidEmailAndRemoveNeedsConfirmation() {
        let app = XCUIApplication()
        app.launchArguments = ["--preview-partner"]
        app.launchInForeground()

        XCTAssertTrue(app.buttons["Organization"].waitForExistence(timeout: 5))
        app.buttons["Organization"].tap()
        let invite = app.buttons["partner-invite"]
        XCTAssertTrue(invite.waitForExistence(timeout: 5))
        XCTAssertFalse(invite.isEnabled, "invite stays disabled until the name and email are given")
        let name = app.textFields["partner-invite-name"]
        name.tap()
        name.typeText("Nell")
        let field = app.textFields["partner-invite-email"]
        field.tap()
        field.typeText("not-an-email")
        XCTAssertFalse(invite.isEnabled)
        field.replaceText(with: "new@acme.com", in: app)
        XCTAssertTrue(invite.isEnabled)

        XCTAssertFalse(app.buttons["partner-remove-u1"].exists, "an admin cannot remove themselves")
        let remove = app.buttons["partner-remove-u2"]
        XCTAssertTrue(remove.exists)
        remove.tap()
        XCTAssertTrue(app.otherElements["partner-remove-prompt"].waitForExistence(timeout: 3))
        app.buttons["partner-remove-cancel"].tap()
        XCTAssertFalse(app.buttons["partner-remove-confirm"].exists)
        XCTAssertTrue(remove.exists, "cancelling keeps the user")
        remove.tap()
        app.buttons["partner-remove-confirm"].tap()
        XCTAssertFalse(app.buttons["partner-remove-u2"].waitForExistence(timeout: 2), "confirmed removal drops the row")
    }

    func testViewerIsReadOnly() {
        let app = XCUIApplication()
        app.launchArguments = ["--preview-partner-viewer"]
        app.launchInForeground()

        XCTAssertTrue(app.otherElements["partner-portal"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["Organization"].waitForExistence(timeout: 5))
        app.buttons["Organization"].tap()
        // A viewer sees the read-only notice and NO invite, profile or export action (§7.2 gating).
        XCTAssertTrue(app.staticTexts["partner-readonly"].waitForExistence(timeout: 3))
        XCTAssertFalse(app.buttons["partner-invite"].exists, "a viewer must not get the invite action")
        XCTAssertFalse(app.buttons["partner-profile-save"].exists)
        XCTAssertFalse(app.buttons["partner-export"].exists)
    }

    func testEmailedLinkSignsInAndSignOutReturnsToTheStart() {
        let app = XCUIApplication()
        app.launchArguments = ["--stub-backend"]
        app.launchInForeground()

        XCTAssertTrue(app.buttons["Partner organization? Sign in here"].waitForExistence(timeout: 10))
        app.buttons["Partner organization? Sign in here"].tap()
        let email = app.textFields["partner-sign-in-email"]
        XCTAssertTrue(email.waitForExistence(timeout: 5))
        XCTAssertTrue(app.links["partner-apply"].exists || app.buttons["partner-apply"].exists, "a new partner is pointed to the application")
        email.tap()
        email.typeText("ada@acme.com")
        app.buttons["partner-sign-in-submit"].tap()
        XCTAssertTrue(app.staticTexts["partner-check-email"].waitForExistence(timeout: 5))

        let paste = app.textFields["partner-paste-link"]
        paste.tap()
        paste.typeText("https://stub.invalid/partner/accept#token=expired" + String(repeating: "x", count: 32))
        app.buttons["partner-paste-submit"].tap()
        XCTAssertTrue(app.staticTexts["partner-sign-in-error"].waitForExistence(timeout: 5), "a used link is explained")
        paste.replaceText(with: "https://stub.invalid/partner/accept#token=stubpartner" + String(repeating: "x", count: 32), in: app)
        app.buttons["partner-paste-submit"].tap()

        XCTAssertTrue(app.staticTexts["partner-committed"].waitForExistence(timeout: 10), "the portal opens on the real conformers")
        XCTAssertFalse(app.staticTexts["partner-deployed"].exists, "unverified figure must be hidden, not estimated")
        app.buttons["Organization"].tap()
        let signOut = app.buttons["partner-sign-out"]
        for _ in 0..<6 where !signOut.isHittable { app.swipeUp() }
        signOut.tap()
        XCTAssertTrue(app.buttons["Partner organization? Sign in here"].waitForExistence(timeout: 5), "signing out returns to the start")
    }

    func testRestoredPartnerManagesTheOrganization() {
        let app = XCUIApplication()
        app.launchArguments = ["--stub-backend", "--stub-partner-signed-in"]
        app.launchInForeground()

        XCTAssertTrue(app.buttons["Organization"].waitForExistence(timeout: 10), "a stored partner session reopens the portal")
        app.buttons["People"].tap()
        XCTAssertTrue(app.staticTexts["partner-team-t1"].waitForExistence(timeout: 5))
        app.buttons["Organization"].tap()

        let name = app.textFields["partner-profile-name"]
        XCTAssertTrue(name.waitForExistence(timeout: 5))
        name.replaceText(with: "Acme Water", in: app)
        app.buttons["partner-profile-save"].tap()
        XCTAssertTrue(app.staticTexts["Acme Water"].waitForExistence(timeout: 5), "the header shows the saved name")
        XCTAssertTrue(app.staticTexts["partner-company-code"].exists)

        let export = app.buttons["partner-export"]
        for _ in 0..<6 where !export.isHittable { app.swipeUp() }
        export.tap()
        XCTAssertTrue(app.buttons["partner-report-share"].waitForExistence(timeout: 5) || app.links["partner-report-share"].exists)
        let aged = app.buttons["partner-export-r1"]
        for _ in 0..<4 where !aged.isHittable { app.swipeUp() }
        aged.tap()
        XCTAssertTrue(app.staticTexts["partner-action-error"].waitForExistence(timeout: 5), "an aged-out report says so")
    }

    // MARK: - The real partner conformers on the scripted backend

    private func launchSignedInPartner(_ extra: [String] = []) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["--stub-backend", "--stub-partner-signed-in"] + extra
        app.launchInForeground()
        return app
    }

    private func reveal(_ element: XCUIElement, in app: XCUIApplication) {
        for _ in 0..<8 where !element.isHittable { app.swipeUp() }
    }

    func testWiredAdminCannotRemoveSelfAndRemovesAnotherUserAfterConfirming() {
        let app = launchSignedInPartner()
        XCTAssertTrue(app.buttons["Organization"].waitForExistence(timeout: 10))
        app.buttons["Organization"].tap()
        let remove = app.buttons["partner-remove-u2"]
        reveal(remove, in: app)
        XCTAssertTrue(remove.exists)
        XCTAssertFalse(app.buttons["partner-remove-u1"].exists, "the signed-in admin has no remove action for themselves")
        remove.tap()
        XCTAssertTrue(app.otherElements["partner-remove-prompt"].waitForExistence(timeout: 3))
        app.buttons["partner-remove-cancel"].tap()
        XCTAssertTrue(remove.exists, "cancelling keeps the user")
        remove.tap()
        app.buttons["partner-remove-confirm"].tap()
        XCTAssertFalse(app.buttons["partner-remove-u2"].waitForExistence(timeout: 3), "the server removed the user")
    }

    func testWiredInviteRejectsAnInvalidAddressExplainsAConflictAndInvitesAValidOne() {
        let app = launchSignedInPartner()
        XCTAssertTrue(app.buttons["Organization"].waitForExistence(timeout: 10))
        app.buttons["Organization"].tap()
        let invite = app.buttons["partner-invite"]
        let name = app.textFields["partner-invite-name"]
        reveal(name, in: app)
        name.tap()
        name.typeText("Nell")
        let email = app.textFields["partner-invite-email"]
        email.tap()
        email.typeText("not-an-email")
        XCTAssertFalse(invite.isEnabled, "an invalid address cannot be sent")

        email.replaceText(with: "taken@acme.com", in: app)
        XCTAssertTrue(invite.isEnabled)
        invite.tap()
        let error = app.staticTexts["partner-action-error"]
        for _ in 0..<8 where !error.exists { app.swipeDown() }
        XCTAssertTrue(error.waitForExistence(timeout: 5), "the server's 409 is explained")
        XCTAssertTrue(error.label.contains("another role or organization"))

        reveal(email, in: app)
        email.replaceText(with: "new@acme.com", in: app)
        reveal(invite, in: app)
        invite.tap()
        XCTAssertTrue(app.staticTexts["Nell · Viewer"].waitForExistence(timeout: 5), "the invited user appears in the refreshed list")
    }

    func testWiredViewerSeesTheDataButNoAdminActions() {
        let app = launchSignedInPartner(["--stub-partner-viewer"])
        XCTAssertTrue(app.staticTexts["partner-committed"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.staticTexts["Viewer"].exists)
        app.buttons["Organization"].tap()
        XCTAssertTrue(app.staticTexts["partner-readonly"].waitForExistence(timeout: 5))
        for id in ["partner-invite", "partner-profile-save", "partner-workforce-save", "partner-logo-remove", "partner-export", "partner-remove-u1", "partner-remove-u2"] {
            XCTAssertFalse(app.buttons[id].exists, "\(id) must not be offered to a viewer")
        }
        XCTAssertFalse(app.textFields["partner-profile-name"].exists)
        XCTAssertTrue(app.buttons["partner-sign-out"].exists || app.buttons["partner-sign-out"].waitForExistence(timeout: 2))
    }

    func testWiredExportOffersTheReportToShareAndKeepsTheHistory() {
        let app = launchSignedInPartner()
        XCTAssertTrue(app.buttons["Organization"].waitForExistence(timeout: 10))
        app.buttons["Organization"].tap()
        let export = app.buttons["partner-export"]
        reveal(export, in: app)
        export.tap()
        let share = app.buttons["partner-report-share"]
        XCTAssertTrue(share.waitForExistence(timeout: 5) || app.links["partner-report-share"].waitForExistence(timeout: 2),
                      "the exported PDF is offered to the share sheet")
        let latest = app.buttons["partner-export-r2"]
        reveal(latest, in: app)
        XCTAssertTrue(latest.exists, "the new export is listed and can be downloaded again")
        latest.tap()
        XCTAssertFalse(app.staticTexts["partner-action-error"].waitForExistence(timeout: 2), "a retained report downloads")
    }

    func testPendingApplicationIsShownAboveSignIn() {
        let app = XCUIApplication()
        app.launchArguments = ["--stub-backend", "--stub-application-pending"]
        app.launchInForeground()
        XCTAssertTrue(app.buttons["Partner organization? Sign in here"].waitForExistence(timeout: 10))
        app.buttons["Partner organization? Sign in here"].tap()
        let card = app.otherElements["partner-application-status"]
        XCTAssertTrue(card.waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["partner-application-message"].label.contains("being reviewed"))
        XCTAssertTrue(app.textFields["partner-sign-in-email"].exists, "sign-in is still available")
    }

    func testApprovedAndUnknownApplicationStatusesAreWordedHonestly() {
        let approved = XCUIApplication()
        approved.launchArguments = ["--stub-backend", "--stub-application-approved"]
        approved.launchInForeground()
        approved.buttons["Partner organization? Sign in here"].tap()
        XCTAssertTrue(approved.staticTexts["partner-application-message"].waitForExistence(timeout: 5))
        XCTAssertTrue(approved.staticTexts["partner-application-message"].label.contains("is approved"))
        approved.terminate()

        let unknown = XCUIApplication()
        unknown.launchArguments = ["--stub-backend", "--stub-application-unknown"]
        unknown.launchInForeground()
        unknown.buttons["Partner organization? Sign in here"].tap()
        XCTAssertTrue(unknown.staticTexts["partner-application-message"].waitForExistence(timeout: 5))
        XCTAssertFalse(unknown.staticTexts["partner-application-message"].label.contains("approved"))
    }

    func testNoApplicationCardWithoutAReceipt() {
        let app = XCUIApplication()
        app.launchArguments = ["--stub-backend"]
        app.launchInForeground()
        XCTAssertTrue(app.buttons["Partner organization? Sign in here"].waitForExistence(timeout: 10))
        app.buttons["Partner organization? Sign in here"].tap()
        XCTAssertTrue(app.textFields["partner-sign-in-email"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.otherElements["partner-application-status"].exists)
    }

    // MARK: - Applying from the app

    private func openApplication(_ extra: [String] = []) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["--stub-backend"] + extra
        app.launchInForeground()
        XCTAssertTrue(app.buttons["Partner organization? Sign in here"].waitForExistence(timeout: 10))
        app.buttons["Partner organization? Sign in here"].tap()
        let apply = app.buttons["partner-apply-in-app"]
        XCTAssertTrue(apply.waitForExistence(timeout: 5), "a new partner can apply in the app")
        reveal(apply, in: app)
        apply.tap()
        XCTAssertTrue(app.otherElements["partner-application-form"].waitForExistence(timeout: 5))
        return app
    }

    private func fillApplication(in app: XCUIApplication) {
        for (id, text) in [("partner-app-organization", "Acme Corp"), ("partner-app-website", "acme.example"), ("partner-app-workforce", "240"),
                           ("partner-app-contact", "Ada Admin"), ("partner-app-title", "Director"), ("partner-app-email", "ada@acme.example"),
                           ("partner-app-phone", "5550100")] {
            let field = app.textFields[id]
            reveal(field, in: app)
            field.tap()
            field.typeText(text)
        }
    }

    private func submitApplication(in app: XCUIApplication) {
        let submit = app.buttons["partner-app-submit"]
        if app.keyboards.count > 0 { app.otherElements["partner-application-form"].staticTexts.firstMatch.tap() }
        reveal(submit, in: app)
        XCTAssertTrue(submit.isEnabled, "a complete application can be sent")
        submit.tap()
    }

    func testSubmittingAnApplicationShowsItPendingFromTheStoredReceipt() {
        let app = openApplication()
        XCTAssertFalse(app.buttons["partner-app-submit"].isEnabled, "an empty application cannot be sent")
        fillApplication(in: app)
        submitApplication(in: app)
        let message = app.staticTexts["partner-application-message"]
        XCTAssertTrue(message.waitForExistence(timeout: 10), "the status card reads the receipt the submission kept")
        XCTAssertTrue(message.label.contains("Acme Corp"))
        XCTAssertTrue(message.label.contains("being reviewed"))
        XCTAssertFalse(app.otherElements["partner-application-form"].exists)
        XCTAssertFalse(app.buttons["partner-apply-in-app"].exists, "an install with an application under review is not offered another")
        XCTAssertTrue(app.textFields["partner-sign-in-email"].exists, "sign-in is still available")
    }

    func testARefusedApplicationIsExplainedAndTheFormStaysEditable() {
        let app = openApplication(["--stub-apply-invalid"])
        fillApplication(in: app)
        submitApplication(in: app)
        let error = app.staticTexts["partner-app-error"]
        for _ in 0..<6 where !error.exists { app.swipeDown() }
        XCTAssertTrue(error.waitForExistence(timeout: 5))
        XCTAssertTrue(error.label.contains("Check each field"))
        XCTAssertTrue(app.textFields["partner-app-organization"].isEnabled, "a refused application can be corrected")
        XCTAssertFalse(app.staticTexts["partner-application-message"].exists, "no status card without an accepted application")
    }

    func testAThrottledApplicationNamesTheWait() {
        let app = openApplication(["--stub-apply-throttled"])
        fillApplication(in: app)
        submitApplication(in: app)
        let error = app.staticTexts["partner-app-error"]
        for _ in 0..<6 where !error.exists { app.swipeDown() }
        XCTAssertTrue(error.waitForExistence(timeout: 5))
        XCTAssertTrue(error.label.contains("30 seconds"), "the ingress Retry-After is shown even without a JSON body")
    }

    func testAnUnconfirmedApplicationRetriesTheSameSubmission() {
        let app = openApplication(["--stub-apply-fails-first"])
        fillApplication(in: app)
        submitApplication(in: app)
        let error = app.staticTexts["partner-app-error"]
        for _ in 0..<6 where !error.exists { app.swipeDown() }
        XCTAssertTrue(error.waitForExistence(timeout: 5))
        XCTAssertTrue(error.label.contains("couldn’t confirm"))
        XCTAssertFalse(app.textFields["partner-app-organization"].isEnabled, "the sent form is locked so a retry repeats it")
        let retry = app.buttons["partner-app-submit"]
        reveal(retry, in: app)
        XCTAssertEqual(retry.label, "Retry")
        retry.tap()
        XCTAssertTrue(app.staticTexts["partner-application-message"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.staticTexts["partner-application-message"].label.contains("being reviewed"))
    }

    func testWiredSignOutReturnsToTheRoleSelect() {
        let app = launchSignedInPartner()
        XCTAssertTrue(app.buttons["Organization"].waitForExistence(timeout: 10))
        app.buttons["Organization"].tap()
        let signOut = app.buttons["partner-sign-out"]
        reveal(signOut, in: app)
        signOut.tap()
        XCTAssertTrue(app.buttons["Partner organization? Sign in here"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.buttons["Organization"].exists)
    }
}
