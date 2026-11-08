import XCTest
@testable import DADFoundation

final class OIDCNonceTests: XCTestCase {
    func testHashIsLowercaseHexSHA256OfTheRawString() {
        XCTAssertEqual(OIDCNonce(raw: "abc").hashed, "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad")
        XCTAssertEqual(OIDCNonce(raw: "").hashed, "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855")
    }

    func testGeneratedNoncesAreLongUniqueAndURLSafe() {
        let generator = SecureNonceGenerator()
        let draws = (0..<1000).map { _ in generator.make() }
        XCTAssertEqual(Set(draws.map(\.raw)).count, 1000)
        let allowed = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_")
        for nonce in draws {
            XCTAssertEqual(nonce.raw.count, 43)
            XCTAssertEqual(Data(base64URL: nonce.raw)?.count, 32)
            XCTAssertTrue(nonce.raw.unicodeScalars.allSatisfy(allowed.contains), nonce.raw)
            XCTAssertEqual(nonce.hashed.count, 64)
        }
    }
}
