import Foundation
import XCTest
@testable import DADFoundation

final class AccessTokenTests: XCTestCase {
    func testAccessTokenReturnsCurrentWhenValid() async throws {
        let store = MemoryStore(Credentials(access: "live", refresh: "r", expiresAt: .distantFuture))
        let session = try AccountSession(api: StaticAPI(), store: store)
        let token = try await session.accessToken()
        XCTAssertEqual(token, "live")
    }

    func testAccessTokenThrowsSignedOutWithNoCredentials() async {
        let store = MemoryStore(nil)
        do {
            let session = try AccountSession(api: StaticAPI(), store: store)
            _ = try await session.accessToken()
            XCTFail("expected signedOut")
        } catch {
            XCTAssertEqual(error as? AccountError, .signedOut)
        }
    }
}

private struct StaticAPI: AccountAPI {
    func profile(access: String) async throws -> AccountProfile { AccountProfile(email: "a@b.org", publicName: "A") }
    func refresh(token: String) async throws -> Credentials { Credentials(access: "refreshed", refresh: token, expiresAt: .distantFuture) }
    func claim(token: String) async throws -> Credentials { throw AccountError.unavailable }
    func logout(access: String) async throws {}
}
