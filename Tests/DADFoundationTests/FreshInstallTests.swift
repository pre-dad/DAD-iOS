import XCTest
@testable import DADFoundation

private final class FailingClearStore: CredentialStore, @unchecked Sendable {
    func load() throws -> Credentials? { nil }
    func save(_ credentials: Credentials) throws {}
    func clear() throws { throw AccountError.secureStorage(-25308) }
}

final class FreshInstallTests: XCTestCase {
    private var defaults: UserDefaults!
    private var suite: String!
    private let session = Credentials(access: "tok", refresh: "ref", expiresAt: .distantFuture)

    override func setUp() {
        suite = "FreshInstallTests-\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suite)
    }

    override func tearDown() { defaults.removePersistentDomain(forName: suite) }

    func testAReinstallSignsOutEverySessionTheKeychainKept() throws {
        let donor = MemoryStore(session), partner = MemoryStore(session)
        FreshInstall.signOutIfNew(sessions: [donor, partner], defaults: defaults, protectedDataAvailable: true)
        XCTAssertNil(try donor.load())
        XCTAssertNil(try partner.load())
        XCTAssertTrue(defaults.bool(forKey: FreshInstall.markerKey))
    }

    func testLaterLaunchesKeepTheSession() throws {
        FreshInstall.signOutIfNew(sessions: [], defaults: defaults, protectedDataAvailable: true)
        let donor = MemoryStore(session)
        FreshInstall.signOutIfNew(sessions: [donor], defaults: defaults, protectedDataAvailable: true)
        XCTAssertEqual(try donor.load(), session)
    }

    func testALaunchBeforeFirstUnlockClearsNothingAndRecordsNothing() throws {
        let donor = MemoryStore(session)
        FreshInstall.signOutIfNew(sessions: [donor], defaults: defaults, protectedDataAvailable: false)
        XCTAssertEqual(try donor.load(), session)
        XCTAssertFalse(defaults.bool(forKey: FreshInstall.markerKey))
    }

    func testAStoreThatFailsToClearIsRetriedAtTheNextLaunch() throws {
        let donor = MemoryStore(session)
        FreshInstall.signOutIfNew(sessions: [FailingClearStore(), donor], defaults: defaults, protectedDataAvailable: true)
        XCTAssertNil(try donor.load())
        XCTAssertFalse(defaults.bool(forKey: FreshInstall.markerKey))
    }
}
