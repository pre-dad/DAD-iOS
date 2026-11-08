import XCTest

extension XCUIElement {
    /// Replaces a field's contents by selecting them all first: per-character delete keystrokes are dropped by
    /// the simulator keyboard. The Select All menu is slow to appear on a loaded runner, and typing without it
    /// inserts at the caret instead of replacing, so the result is verified and the selection retried.
    func replaceText(with text: String, in app: XCUIApplication) {
        XCTAssertTrue(waitForExistence(timeout: 10), "\(self)")
        // A secure field reports one bullet per character, so its contents are checked by length.
        let expected = elementType == .secureTextField ? String(repeating: "•", count: text.count) : text
        for _ in 0..<3 {
            tap()
            if hasEnteredText {
                press(forDuration: 1.0)
                let selectAll = app.menuItems["Select All"]
                guard selectAll.waitForExistence(timeout: 6) else { continue }
                selectAll.tap()
            }
            typeText(text)
            if value as? String == expected { return }
        }
        XCTAssertEqual(value as? String, expected, "the field must hold exactly the replacement text")
    }

    private var hasEnteredText: Bool {
        guard let current = value as? String, !current.isEmpty else { return false }
        return current != placeholderValue
    }
}
