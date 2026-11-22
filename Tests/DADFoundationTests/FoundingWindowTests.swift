import XCTest
@testable import DADFoundation

final class FoundingWindowTests: XCTestCase {
    func testCountsWholeDaysAndPluralises() {
        XCTAssertEqual(FoundingWindow.line(from: FoundingWindow.closesAt.addingTimeInterval(-54 * 86_400 - 3_600)), "Founding Donor: 54 days left")
        XCTAssertEqual(FoundingWindow.line(from: FoundingWindow.closesAt.addingTimeInterval(-86_400 - 3_600)), "Founding Donor: 1 day left")
    }

    func testTheLastDayReadsAsSuchNotZeroDays() {
        XCTAssertEqual(FoundingWindow.line(from: FoundingWindow.closesAt.addingTimeInterval(-12 * 3_600)), "Founding Donor: last day")
    }

    func testTheLineIsHiddenOnceTheWindowCloses() {
        XCTAssertNil(FoundingWindow.line(from: FoundingWindow.closesAt))
        XCTAssertNil(FoundingWindow.line(from: FoundingWindow.closesAt.addingTimeInterval(1)))
    }
}
