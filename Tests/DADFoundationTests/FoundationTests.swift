import Foundation
import XCTest
@testable import DADFoundation

final class MemoryStore: CredentialStore, @unchecked Sendable {
    private let lock = NSLock()
    private var value: Credentials?
    private(set) var saves = 0
    init(_ value: Credentials?) { self.value = value }
    func load() throws -> Credentials? { lock.withLock { value } }
    func save(_ credentials: Credentials) throws { lock.withLock { value = credentials; saves += 1 } }
    func clear() throws { lock.withLock { value = nil } }
}

actor ControlledAPI: AccountAPI {
    var refreshes = 0
    var loggedOut: [String] = []
    private var waiting: CheckedContinuation<Credentials, Error>?
    private var entered: [CheckedContinuation<Void, Never>] = []
    func profile(access: String) async throws -> AccountProfile {
        if access == "old" { throw AccountError.signedOut }
        return AccountProfile(email: "donor@example.org", publicName: "Alex")
    }
    func refresh(token: String) async throws -> Credentials {
        refreshes += 1
        return try await withCheckedThrowingContinuation { continuation in
            waiting = continuation
            entered.forEach { $0.resume() }; entered = []
        }
    }
    func waitForRefresh() async {
        if waiting != nil { return }
        await withCheckedContinuation { entered.append($0) }
    }
    func finishRefresh() {
        waiting?.resume(returning: Credentials(access: "new", refresh: "new-refresh", expiresAt: Date().addingTimeInterval(900)))
        waiting = nil
    }
    func rejectRefresh() { waiting?.resume(throwing: AccountError.signedOut); waiting = nil }
    func claim(token: String) async throws -> Credentials {
        Credentials(access: "claimed", refresh: "claimed-refresh", expiresAt: Date().addingTimeInterval(900))
    }
    func logout(access: String) async throws { loggedOut.append(access) }
}

@MainActor
final class FoundationTests: XCTestCase {
    func testConcurrentExpiryUsesOneRefreshAndPersistsOnce() async throws {
        let api = ControlledAPI()
        let store = MemoryStore(Credentials(access: "old", refresh: "refresh", expiresAt: .distantPast))
        let session = try AccountSession(api: api, store: store)
        let requests = Task {
            try await withThrowingTaskGroup(of: AccountProfile.self) { group in
                for _ in 0..<20 { group.addTask { try await session.profile() } }
                var results: [AccountProfile] = []
                for try await value in group { results.append(value) }
                return results
            }
        }
        await api.waitForRefresh()
        await api.finishRefresh()
        let profiles = try await requests.value
        XCTAssertEqual(profiles.count, 20)
        let refreshes = await api.refreshes
        XCTAssertEqual(refreshes, 1)
        XCTAssertEqual(store.saves, 1)
        XCTAssertEqual(try store.load()?.access, "new")
    }
    func testUnauthorizedReadRefreshesAndRetryIsBounded() async throws {
        let api = ControlledAPI()
        let session = try AccountSession(api: api, store: MemoryStore(Credentials(access: "old", refresh: "refresh", expiresAt: .distantFuture)))
        let request = Task { try await session.profile() }
        await api.waitForRefresh()
        await api.finishRefresh()
        let result = try await request.value
        XCTAssertEqual(result.publicName, "Alex")
        let count = await api.refreshes
        XCTAssertEqual(count, 1)
    }
    func testLogoutDuringRefreshCannotRestoreCredentialsAndRevokesNewestAccess() async throws {
        let api = ControlledAPI()
        let store = MemoryStore(Credentials(access: "old", refresh: "refresh", expiresAt: .distantPast))
        let session = try AccountSession(api: api, store: store)
        let request = Task { try await session.profile() }
        await api.waitForRefresh()
        let logout = Task { try await session.logout() }
        // Reading the actor after logout starts puts the local transition before the provider reply.
        for _ in 0..<1000 {
            if try store.load() == nil { break }
            await Task.yield()
        }
        XCTAssertNil(try store.load())
        await api.finishRefresh()
        try await logout.value
        do { _ = try await request.value; XCTFail("late refresh restored the session") }
        catch { XCTAssertEqual(error as? AccountError, .signedOut) }
        XCTAssertNil(try store.load())
        let revoked = await api.loggedOut
        XCTAssertEqual(revoked, ["new"])
    }
    func testRefreshRevocationClearsLocalStorage() async throws {
        let api = ControlledAPI()
        let store = MemoryStore(Credentials(access: "old", refresh: "refresh", expiresAt: .distantPast))
        let session = try AccountSession(api: api, store: store)
        let request = Task { try await session.profile() }
        await api.waitForRefresh()
        await api.rejectRefresh()
        do { _ = try await request.value; XCTFail("revoked refresh accepted") }
        catch { XCTAssertEqual(error as? AccountError, .signedOut) }
        XCTAssertNil(try store.load())
    }
    func testNewClaimCannotBeOverwrittenByEarlierRefresh() async throws {
        let api = ControlledAPI()
        let store = MemoryStore(Credentials(access: "old", refresh: "refresh", expiresAt: .distantPast))
        let session = try AccountSession(api: api, store: store)
        let old = Task { try await session.profile() }
        await api.waitForRefresh()
        try await session.claim(token: "synthetic-proof")
        _ = try await session.profile()
        await api.finishRefresh()
        do { _ = try await old.value; XCTFail("previous session survived account claim") }
        catch { XCTAssertEqual(error as? AccountError, .signedOut) }
        XCTAssertEqual(try store.load()?.access, "claimed")
    }

    func testClaimLinksRequireTheExactOriginAndFragment() throws {
        let router = try LinkRouter(publicOrigin: XCTUnwrap(URL(string: "https://public.test")))
        let token = String(repeating: "a", count: 32)
        XCTAssertEqual(router.route(URL(string: "https://public.test/account/claim#token=\(token)&next=/account/dashboard")!), .claim(token: token, next: .dashboard))
        for value in ["https://evil.test/account/dashboard", "http://public.test/account/profile", "https://user@public.test/account/profile", "https://public.test/account%2fclaim#token=\(token)", "https://public.test/account/claim#token=\(token)&next=https://evil.test", "https://public.test/account/claim#token=\(token)&token=\(token)"] {
            XCTAssertNil(router.route(URL(string: value)!), value)
        }
    }

    func testPartnerAcceptLinksRequireAShapedFragmentAndNoNext() throws {
        let router = try LinkRouter(publicOrigin: XCTUnwrap(URL(string: "https://public.test")))
        let token = String(repeating: "a", count: 32)
        XCTAssertEqual(router.route(URL(string: "https://public.test/partner/accept#token=\(token)")!), .partnerSignIn(token: token))
        for value in ["https://public.test/partner/accept#token=\(token)&next=/account/dashboard", "https://public.test/partner/accept?x=1#token=\(token)", "https://public.test/partner/accept#token=short"] {
            XCTAssertNil(router.route(URL(string: value)!), value)
        }
    }

    func testNotificationPathsAreAllowlisted() throws {
        let router = try LinkRouter(publicOrigin: XCTUnwrap(URL(string: "https://public.test")))
        XCTAssertEqual(router.notification(path: "/account/payment-method"), .paymentMethod)
        XCTAssertEqual(router.notification(path: "/account/gifts"), .gifts)
        XCTAssertNil(router.notification(path: "https://public.test/account/dashboard"))
    }

    func testReferralAndCompanyLinksRouteOnlyWithAValidShape() throws {
        let router = try LinkRouter(publicOrigin: XCTUnwrap(URL(string: "https://public.test")))
        XCTAssertEqual(router.route(URL(string: "https://public.test/r/friend?via=irl")!), .referral(code: "friend", inPerson: true))
        XCTAssertEqual(router.route(URL(string: "https://public.test/r/friend_2-x")!), .referral(code: "friend_2-x", inPerson: false))
        XCTAssertEqual(router.route(URL(string: "https://public.test/c/ACME-1")!), .company(code: "ACME-1"))
        for value in ["https://public.test/r/friend?via=web", "https://public.test/r/a/b", "https://public.test/r/", "https://public.test/r/friend#x",
                      "https://public.test/c/acme?via=irl", "https://public.test/c/a.b", "https://public.test/r/" + String(repeating: "a", count: 65)] {
            XCTAssertEqual(router.route(URL(string: value)!), .web(URL(string: value)!), value)
        }
        XCTAssertNil(router.route(URL(string: "https://evil.test/r/friend")!))
    }

    func testNavigationGateDefersARouteUntilSignedIn() {
        var gate = NavigationGate()
        XCTAssertNil(gate.receive(.dashboard, signedIn: false))
        XCTAssertEqual(gate.signedIn(), .dashboard)
        XCTAssertNil(gate.signedIn())
    }
}
