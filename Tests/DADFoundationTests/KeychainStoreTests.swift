import Foundation
import Security
import XCTest
@testable import DADFoundation

final class KeychainStoreTests: XCTestCase {
    private var service = ""
    private var store: KeychainStore { KeychainStore(service: service) }

    override func setUp() {
        service = "org.dad.tests.keychain." + UUID().uuidString
    }

    override func tearDown() {
        try? store.clear()
    }

    private func credentials(_ access: String, expiresIn seconds: TimeInterval = 900) -> Credentials {
        Credentials(access: access, refresh: access + "-refresh", expiresAt: Date(timeIntervalSince1970: 1_800_000_000 + seconds))
    }

    /// The first write doubles as the availability probe: a host with no usable keychain skips instead of failing.
    private func saveOrSkip(_ value: Credentials) throws {
        do { try store.save(value) }
        catch AccountError.secureStorage(let status) { throw XCTSkip("Keychain is not available to this test host (OSStatus \(status))") }
    }

    func testNothingStoredLoadsAsNil() throws {
        XCTAssertNil(try store.load())
    }

    func testSaveLoadRoundTripsEveryField() throws {
        let value = credentials("a1")
        try saveOrSkip(value)
        XCTAssertEqual(try store.load(), value)
    }

    func testSavingAgainReplacesTheItemInsteadOfAddingOrFailing() throws {
        try saveOrSkip(credentials("first"))
        try store.save(credentials("second", expiresIn: 60))
        XCTAssertEqual(try store.load(), credentials("second", expiresIn: 60))
    }

    func testClearRemovesTheItemAndIsIdempotent() throws {
        try saveOrSkip(credentials("a1"))
        try store.clear()
        XCTAssertNil(try store.load())
        XCTAssertNoThrow(try store.clear(), "clearing an empty store is not an error")
    }

    func testItemsAreScopedByServiceAndAccount() throws {
        try saveOrSkip(credentials("donor"))
        XCTAssertNil(try KeychainStore(service: service, account: "partner-session").load())
        XCTAssertNil(try KeychainStore(service: service + ".other").load())
    }

    func testAnUndecodableItemIsAnErrorNeverASession() throws {
        try saveOrSkip(credentials("a1"))
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
                                    kSecAttrAccount as String: "donor-session", kSecAttrSynchronizable as String: false]
        let status = SecItemUpdate(query as CFDictionary, [kSecValueData as String: Data("not json".utf8)] as CFDictionary)
        XCTAssertEqual(status, errSecSuccess)
        XCTAssertThrowsError(try store.load()) { XCTAssertTrue($0 is DecodingError, "\($0)") }
    }

    func testCredentialsNeverPrintTheirSecrets() {
        let value = credentials("super-secret-access")
        for text in ["\(value)", String(reflecting: value), value.description, value.debugDescription] {
            XCTAssertFalse(text.contains("super-secret"), text)
        }
    }
}
