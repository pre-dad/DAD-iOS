import SwiftUI
import XCTest
@testable import DADFoundation

final class DesignTokenTests: XCTestCase {
    /// An unparsed token silently falls back to `.primary` (black in light mode), which once
    /// turned every `#fff` card and secondary button black. Every shipped token must resolve.
    func testEveryColorTokenParses() {
        for (name, value) in DADTokens.color {
            XCTAssertTrue(Color.parseHex(value) != nil || Color.parseRGBA(value) != nil, "token \(name) = \(value) does not parse")
        }
    }

    func testTokenPairingsMeetContrast() {
        func luminance(_ hex: String) -> Double {
            var digits = String(hex.dropFirst())
            if digits.count == 3 { digits = digits.map { "\($0)\($0)" }.joined() }
            guard digits.count == 6, let packed = Int(digits, radix: 16) else { XCTFail("token \(hex) is not a hex colour"); return 0 }
            let channels = [16, 8, 0].map { shift -> Double in
                let value = Double((packed >> shift) & 0xFF) / 255
                return value <= 0.03928 ? value / 12.92 : pow((value + 0.055) / 1.055, 2.4)
            }
            return 0.2126 * channels[0] + 0.7152 * channels[1] + 0.0722 * channels[2]
        }
        func ratio(_ a: String, _ b: String) -> Double {
            let (hi, lo) = (max(luminance(a), luminance(b)), min(luminance(a), luminance(b)))
            return (hi + 0.05) / (lo + 0.05)
        }
        let paper = DADTokens.color["paper"]!
        XCTAssertLessThan(ratio(paper, DADTokens.color["brand"]!), 4.5, "brand is the decorative colour, not a text background")
        XCTAssertGreaterThanOrEqual(ratio(paper, DADTokens.color["brand-ink"]!), 4.5)
        XCTAssertGreaterThanOrEqual(ratio(DADTokens.color["ink"]!, DADTokens.color["brand"]!), 4.5, "ink on brand must clear AA")
    }

    func testStreakProgressTokensResolve() {
        XCTAssertNotNil(Color.parseHex(DADTokens.color["ok"]!))
        XCTAssertNotNil(Color.parseHex(DADTokens.color["ok-ink"]!))
    }

    func testShorthandHexExpands() {
        XCTAssertEqual(Color.parseHex("#fff"), Color.parseHex("#ffffff"))
        XCTAssertEqual(Color.parseHex("#0af"), Color.parseHex("#00aaff"))
        XCTAssertNotNil(Color.parseHex("#0e1e1e"))
        XCTAssertNil(Color.parseHex("#ffff"))
        XCTAssertNil(Color.parseHex("fff"))
        XCTAssertNil(Color.parseHex("#ggg"))
    }
}
