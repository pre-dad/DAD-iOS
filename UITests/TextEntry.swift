import XCTest

extension XCUIElement {
    /// Replaces a field's contents by selecting them all first: per-character delete keystrokes are dropped by
    /// the simulator keyboard. A field with nothing to select offers no Select All, so the text is typed as is.
    func replaceText(with text: String, in app: XCUIApplication) {
        XCTAssertTrue(waitForExistence(timeout: 10), "\(self)")
        tap()
        press(forDuration: 1.0)
        let selectAll = app.menuItems["Select All"]
        if selectAll.waitForExistence(timeout: 3) { selectAll.tap() }
        typeText(text)
    }
}
