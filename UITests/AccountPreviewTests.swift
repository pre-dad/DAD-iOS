import XCTest

@MainActor final class AccountPreviewTests: XCTestCase {
    func testAccountPreviewLoads() {
        let app = XCUIApplication()
        app.launchInForeground()
        XCTAssertTrue(app.staticTexts["Hi, Alex"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.staticTexts["Preview · Sample account"].exists)
    }
    func testUnavailableStateCanRecover() {
        let app = XCUIApplication()
        app.launchArguments = ["--preview-unavailable"]
        app.launchInForeground()
        XCTAssertTrue(app.buttons["Try again"].waitForExistence(timeout: 10))
        app.buttons["Try again"].tap()
        XCTAssertTrue(app.staticTexts["Hi, Alex"].waitForExistence(timeout: 10))
    }
}
