import XCTest

/// Runs the REAL `WireEngagement`, `WireDashboard`, `AccountSession` and `WireAPI` against the DEBUG-only
/// scripted transport (`--stub-backend`): badges earned and locked with a perk, the rank label, the rankings
/// choice (saved, and a refused save reverting), the network list, the invite link, copy/share/QR, choosing a
/// public name, the Wallet pass failure path, a partly unavailable screen and the initiative spend drill-in.
@MainActor final class EngagementWiredFlowTests: XCTestCase {
    private func launch(_ extra: String...) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["--stub-backend", "--stub-signed-in"] + extra
        app.launchInForeground()
        return app
    }

    private func openEngagement(_ app: XCUIApplication) {
        // Engagement is the Circle tab, not a card/sheet on Home.
        let circle = app.tabBars.buttons["Circle"]
        XCTAssertTrue(circle.waitForExistence(timeout: 20))
        circle.tap()
        XCTAssertTrue(app.otherElements["engagement-home"].waitForExistence(timeout: 10))
    }

    func testBadgesShowEarnedAndLockedWithAPerk() {
        let app = launch()
        openEngagement(app)
        XCTAssertTrue(app.staticTexts["badge-summary"].waitForExistence(timeout: 10))
        XCTAssertEqual(app.staticTexts["badge-summary"].label, "3 of 6 earned")
        XCTAssertTrue(app.staticTexts["badge-invite-access"].exists, "an earned Founding Donor badge opens invite-only events")

        let founding = app.otherElements["badge-F"]
        XCTAssertTrue(founding.waitForExistence(timeout: 5))
        XCTAssertTrue(founding.label.contains("earned"), founding.label)
        XCTAssertEqual(app.staticTexts["badge-perk-F"].label, "Perk: Invite-only founding events")

        let city = app.otherElements["badge-CITY50"]
        XCTAssertTrue(city.exists)
        XCTAssertTrue(city.label.contains("Top 50 in Chicago"), "an earned city badge shows its display title: \(city.label)")
        let milestone = app.otherElements["badge-1K"]
        XCTAssertTrue(milestone.exists)
        XCTAssertTrue(milestone.label.contains("locked"), "locked is stated in text: \(milestone.label)")
        XCTAssertTrue(milestone.label.contains("Reach a 1,000-day streak"), milestone.label)
        XCTAssertEqual(app.staticTexts["badge-perk-1K"].label, "Perk: Invite-only milestone events")
    }

    func testRankLabelReadsTop2AndTheChoiceIsSavedBothWays() {
        let app = launch()
        openEngagement(app)
        XCTAssertTrue(app.staticTexts["ranking-national"].waitForExistence(timeout: 10))
        XCTAssertEqual(app.staticTexts["ranking-national"].label, "Top 2% nationally")
        XCTAssertEqual(app.staticTexts["ranking-city"].label, "#4 in Austin")

        app.buttons["ranking-toggle"].tap()
        XCTAssertTrue(app.staticTexts["ranking-optedout"].waitForExistence(timeout: 10))
        XCTAssertFalse(app.staticTexts["ranking-national"].exists)
        XCTAssertEqual(app.buttons["ranking-toggle"].label, "Show my ranking")
        XCTAssertFalse(app.staticTexts["engagement-action-error"].exists)

        app.buttons["ranking-toggle"].tap()
        XCTAssertTrue(app.staticTexts["ranking-national"].waitForExistence(timeout: 10), "opting back in restores the server's position")
        XCTAssertEqual(app.staticTexts["ranking-national"].label, "Top 2% nationally")
        XCTAssertEqual(app.buttons["ranking-toggle"].label, "Hide my ranking")
    }

    func testAFailedRankingsSaveRevertsWithAnInlineNotice() {
        let app = launch("--stub-rankings-fail-toggle")
        openEngagement(app)
        XCTAssertTrue(app.staticTexts["ranking-national"].waitForExistence(timeout: 10))
        app.buttons["ranking-toggle"].tap()
        let error = app.staticTexts["engagement-action-error"]
        XCTAssertTrue(error.waitForExistence(timeout: 10))
        XCTAssertEqual(error.label, "Something went wrong. Please try again.")
        XCTAssertTrue(app.staticTexts["ranking-national"].exists, "the standing the server last confirmed is back")
        XCTAssertFalse(app.staticTexts["ranking-optedout"].exists)
        XCTAssertEqual(app.buttons["ranking-toggle"].label, "Hide my ranking")
    }

    func testNetworkListAndInviteLink() {
        let app = launch()
        openEngagement(app)
        XCTAssertTrue(app.staticTexts["network-active"].waitForExistence(timeout: 10))
        XCTAssertEqual(app.staticTexts["network-active"].label, "3 active · $4,745/yr")
        XCTAssertEqual(app.staticTexts["network-invitee-0"].label, "Sam L · Active")
        XCTAssertEqual(app.staticTexts["network-invitee-1"].label, "Jo P · Not giving now")
        XCTAssertEqual(app.staticTexts["network-anonymous"].label, "1 person chooses to stay anonymous")
        XCTAssertEqual(app.staticTexts["network-milestone"].label, "17 more to reach Team Captain")

        XCTAssertEqual(app.staticTexts["referral-code"].label, "Your code: ALEX42")
        XCTAssertEqual(app.staticTexts["referral-total"].label, "3 people have joined through you")
        XCTAssertTrue(app.staticTexts["invite-link"].label.hasSuffix("/r/ALEX42"), app.staticTexts["invite-link"].label)
        XCTAssertTrue(app.staticTexts["conversion-0"].label.hasSuffix("Invite link"), app.staticTexts["conversion-0"].label)
        XCTAssertTrue(app.staticTexts["conversion-1"].label.hasSuffix("In person"), app.staticTexts["conversion-1"].label)
    }

    func testShareSheetAndCopyAndQR() {
        let app = launch()
        openEngagement(app)
        let copy = app.buttons["copy-invite"]
        XCTAssertTrue(copy.waitForExistence(timeout: 10))
        copy.tap()
        XCTAssertEqual(app.buttons["copy-invite"].label, "Copied")

        app.buttons["share-invite"].tap()
        let sheet = app.otherElements["ActivityListView"]
        XCTAssertTrue(sheet.waitForExistence(timeout: 10) || app.collectionViews.firstMatch.waitForExistence(timeout: 5),
                      "the system share sheet should present the invite")
    }

    func testShowQRPresentsTheCode() {
        let app = launch()
        openEngagement(app)
        let show = app.buttons["show-qr"]
        XCTAssertTrue(show.waitForExistence(timeout: 10))
        show.tap()
        XCTAssertTrue(app.images["qr-code"].waitForExistence(timeout: 10))
        app.buttons["qr-close"].tap()
        XCTAssertTrue(app.otherElements["engagement-home"].waitForExistence(timeout: 5))
    }

    func testAPassWalletCannotReadSaysTheCodeStillWorks() {
        let app = launch()
        openEngagement(app)
        let add = app.buttons["wallet-add"]
        XCTAssertTrue(add.waitForExistence(timeout: 10), "the deployment issues Apple Wallet passes")
        add.tap()
        XCTAssertTrue(app.staticTexts["wallet-error"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.staticTexts["wallet-error"].label.contains("on-screen code still works"))
    }

    func testChoosingAPublicNameCreatesTheInviteLink() {
        let app = launch("--stub-no-public-name")
        openEngagement(app)
        let field = app.textFields["name-field"]
        XCTAssertTrue(field.waitForExistence(timeout: 10))
        XCTAssertFalse(app.staticTexts["referral-code"].exists)
        field.tap()
        field.typeText("Alex R")
        app.buttons["save-name"].tap()
        XCTAssertTrue(app.staticTexts["referral-code"].waitForExistence(timeout: 10))
        XCTAssertEqual(app.staticTexts["referral-code"].label, "Your code: ALEX42")
        XCTAssertFalse(app.textFields["name-field"].exists)
    }

    func testAnUnavailableSectionSaysSoWhileTheRestStays() {
        let app = launch("--stub-badges-down")
        openEngagement(app)
        XCTAssertTrue(app.staticTexts["Your badges can’t be shown right now."].waitForExistence(timeout: 10))
        XCTAssertFalse(app.staticTexts["badge-summary"].exists, "no empty grid or zero count stands in for the missing badges")
        XCTAssertEqual(app.staticTexts["impact-given"].label, "$1,240")
        XCTAssertTrue(app.staticTexts["network-active"].exists)
    }

    func testInitiativeSpendDrillIn() {
        let app = launch()
        let open = app.buttons["open-spend"]
        XCTAssertTrue(open.waitForExistence(timeout: 20))
        open.tap()
        XCTAssertTrue(app.staticTexts["spend-total"].waitForExistence(timeout: 10))
        XCTAssertEqual(app.staticTexts["spend-total"].label, "$1,250")
        XCTAssertTrue(app.staticTexts["spend-row-0"].exists)
        XCTAssertTrue(app.staticTexts["spend-row-0"].label.contains("Food"), app.staticTexts["spend-row-0"].label)
        XCTAssertTrue(app.staticTexts["spend-row-0"].label.contains("$900"), app.staticTexts["spend-row-0"].label)
        XCTAssertTrue(app.staticTexts["spend-row-1"].label.contains("Delivery"))
        // Spend is a push from Home; return with the navigation back button.
        app.navigationBars.buttons.element(boundBy: 0).tap()
        XCTAssertTrue(app.staticTexts["initiative-title"].waitForExistence(timeout: 5))
    }
}
