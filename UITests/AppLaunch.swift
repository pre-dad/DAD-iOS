import XCTest

extension XCUIApplication {
    /// Launches a fresh instance and waits for it to reach the foreground. A leftover instance is terminated
    /// first so only one app process holds a background assertion at a time; the explicit wait gives a loaded
    /// simulator a generous, uniform allowance and names the failure instead of surfacing it later as a
    /// missing element.
    func launchInForeground(file: StaticString = #filePath, line: UInt = #line) {
        if state != .notRunning {
            terminate()
        }
        launch()
        XCTAssertTrue(
            wait(for: .runningForeground, timeout: 120),
            "app did not reach the foreground after launch (state \(state.rawValue))",
            file: file, line: line)
    }
}

extension XCUIElement {
    /// Waits for the element to exist, then taps it, so the first tap on a freshly presented screen
    /// fails with a named assertion instead of racing the render.
    func tapWhenReady(timeout: TimeInterval = 10, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertTrue(waitForExistence(timeout: timeout), "\(self) did not appear", file: file, line: line)
        tap()
    }
}
