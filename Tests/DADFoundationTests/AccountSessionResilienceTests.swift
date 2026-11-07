import Foundation
import HTTPTypes
import OpenAPIRuntime
import XCTest
@testable import DADFoundation

private final class ScriptedAccountAPI: AccountAPI, @unchecked Sendable {
    private let lock = NSLock()
    private var refreshResults: [Result<Credentials, Error>]
    private var refreshCount = 0
    private var revoked: [String] = []
    var logoutError: Error?

    init(refresh: [Result<Credentials, Error>]) { refreshResults = refresh }

    var refreshes: Int { lock.withLock { refreshCount } }
    var loggedOut: [String] { lock.withLock { revoked } }

    func profile(access: String) async throws -> AccountProfile { AccountProfile(email: "a@b.org", publicName: nil) }
    func refresh(token: String) async throws -> Credentials {
        let result: Result<Credentials, Error> = lock.withLock {
            refreshCount += 1
            return refreshResults.count > 1 ? refreshResults.removeFirst() : refreshResults[0]
        }
        return try result.get()
    }
    func claim(token: String) async throws -> Credentials { throw AccountError.unavailable }
    func logout(access: String) async throws {
        lock.withLock { revoked.append(access) }
        if let logoutError { throw logoutError }
    }
}

private struct SaveFails: Error {}

private final class SaveFailingStore: CredentialStore, @unchecked Sendable {
    private let lock = NSLock()
    private var value: Credentials?
    private(set) var failSaves = false
    init(_ value: Credentials?) { self.value = value }
    func failFurtherSaves() { lock.withLock { failSaves = true } }
    func load() throws -> Credentials? { lock.withLock { value } }
    func save(_ credentials: Credentials) throws {
        if lock.withLock({ failSaves }) { throw SaveFails() }
        lock.withLock { value = credentials }
    }
    func clear() throws { lock.withLock { value = nil } }
}

private actor Barrier {
    private let parties: Int
    private var arrived = 0
    private var waiting: [CheckedContinuation<Void, Never>] = []
    init(parties: Int) { self.parties = parties }
    func arrive() async {
        arrived += 1
        if arrived == parties { waiting.forEach { $0.resume() }; waiting = []; return }
        await withCheckedContinuation { waiting.append($0) }
    }
}

private func fresh(_ access: String = "new") -> Credentials {
    Credentials(access: access, refresh: "\(access)-refresh", expiresAt: Date().addingTimeInterval(900))
}

final class AccountSessionResilienceTests: XCTestCase {
    func testATransientRefreshFailureKeepsTheSessionAndTheNextCallRetries() async throws {
        for failure in [AccountError.unavailable, .rateLimited, .invalidResponse] {
            let api = ScriptedAccountAPI(refresh: [.failure(failure), .success(fresh())])
            let store = MemoryStore(Credentials(access: "old", refresh: "r", expiresAt: .distantPast))
            let session = try AccountSession(api: api, store: store)
            do { _ = try await session.profile(); XCTFail("\(failure)") }
            catch { XCTAssertEqual(error as? AccountError, failure) }
            XCTAssertEqual(try store.load()?.refresh, "r", "\(failure) must not end the session")
            let signedIn = await session.isSignedIn
            XCTAssertTrue(signedIn)
            _ = try await session.profile()
            XCTAssertEqual(api.refreshes, 2, "the failed flight is cleared, so the next call refreshes again")
            XCTAssertEqual(try store.load()?.access, "new")
        }
    }

    func testAnUnauthorizedCallWhoseRefreshFailsTransientlyKeepsTheSession() async throws {
        let api = ScriptedAccountAPI(refresh: [.failure(AccountError.unavailable)])
        let store = MemoryStore(Credentials(access: "old", refresh: "r", expiresAt: .distantFuture))
        let session = try AccountSession(api: api, store: store)
        do { _ = try await session.authorized { _ -> Int in throw AccountError.signedOut }; XCTFail() }
        catch { XCTAssertEqual(error as? AccountError, .unavailable) }
        XCTAssertEqual(try store.load()?.access, "old", "a 401 followed by an unreachable refresh is not proof the session is dead")
    }

    func testARefreshThatCannotBePersistedEndsTheSessionInsteadOfHoldingUnsavedCredentials() async throws {
        let store = SaveFailingStore(Credentials(access: "old", refresh: "r", expiresAt: .distantPast))
        store.failFurtherSaves()
        let session = try AccountSession(api: ScriptedAccountAPI(refresh: [.success(fresh())]), store: store)
        do { _ = try await session.profile(); XCTFail() }
        catch { XCTAssertTrue(error is SaveFails, "\(error)") }
        XCTAssertNil(try store.load(), "an unpersisted rotation would orphan the old refresh credential")
        let signedIn = await session.isSignedIn
        XCTAssertFalse(signedIn)
    }

    func testAnAccessCredentialAboutToExpireIsRefreshedBeforeUse() async throws {
        let soon = Credentials(access: "soon", refresh: "r", expiresAt: Date().addingTimeInterval(10))
        let api = ScriptedAccountAPI(refresh: [.success(fresh())])
        let session = try AccountSession(api: api, store: MemoryStore(soon))
        let token = try await session.accessToken()
        XCTAssertEqual(token, "new")
        XCTAssertEqual(api.refreshes, 1)

        let later = Credentials(access: "later", refresh: "r", expiresAt: Date().addingTimeInterval(3600))
        let quiet = ScriptedAccountAPI(refresh: [.success(fresh())])
        let kept = try AccountSession(api: quiet, store: MemoryStore(later))
        let unchanged = try await kept.accessToken()
        XCTAssertEqual(unchanged, "later")
        XCTAssertEqual(quiet.refreshes, 0)
    }

    func testConcurrentUnauthorizedCallsShareOneForcedRefresh() async throws {
        let api = ScriptedAccountAPI(refresh: [.success(fresh())])
        let store = MemoryStore(Credentials(access: "old", refresh: "r", expiresAt: .distantFuture))
        let session = try AccountSession(api: api, store: store)
        let barrier = Barrier(parties: 5)
        let results = try await withThrowingTaskGroup(of: String.self) { group in
            for _ in 0..<5 {
                group.addTask {
                    try await session.authorized { access -> String in
                        guard access == "old" else { return access }
                        await barrier.arrive()
                        throw AccountError.signedOut
                    }
                }
            }
            return try await group.reduce(into: []) { $0.append($1) }
        }
        XCTAssertEqual(results, Array(repeating: "new", count: 5))
        XCTAssertEqual(api.refreshes, 1, "five 401s race, one refresh rotates the credential")
        XCTAssertEqual(try store.load()?.access, "new")
    }

    func testLogoutWithoutCredentialsNeverCallsTheServer() async throws {
        let api = ScriptedAccountAPI(refresh: [.success(fresh())])
        let session = try AccountSession(api: api, store: MemoryStore(nil))
        try await session.logout()
        XCTAssertTrue(api.loggedOut.isEmpty)
        XCTAssertEqual(api.refreshes, 0)
    }

    func testLogoutClearsLocallyEvenWhenTheServerCannotBeReached() async throws {
        let api = ScriptedAccountAPI(refresh: [.success(fresh())])
        api.logoutError = AccountError.unavailable
        let store = MemoryStore(Credentials(access: "live", refresh: "r", expiresAt: .distantFuture))
        let session = try AccountSession(api: api, store: store)
        do { try await session.logout(); XCTFail("the revocation failure must be visible to the caller") }
        catch { XCTAssertEqual(error as? AccountError, .unavailable) }
        XCTAssertNil(try store.load(), "the device is signed out whether or not the server heard about it")
        XCTAssertEqual(api.loggedOut, ["live"])
        let signedIn = await session.isSignedIn
        XCTAssertFalse(signedIn)
    }

    func testAnAccessTokenRequestFromACancelledCallerThrowsCancellation() async throws {
        let session = try AccountSession(api: ScriptedAccountAPI(refresh: [.success(fresh())]),
                                         store: MemoryStore(Credentials(access: "live", refresh: "r", expiresAt: .distantFuture)))
        let gate = Gate()
        let task = Task { await gate.pass(); return try await session.accessToken() }
        await gate.waitUntilEntered()
        task.cancel()
        await gate.release()
        do { _ = try await task.value; XCTFail("a cancelled caller was handed a credential") }
        catch { XCTAssertTrue(error is CancellationError, "\(error)") }
    }

    func testAnEstablishedSessionStartsFreshAfterAnEarlierOneWasDiscarded() async throws {
        let api = ScriptedAccountAPI(refresh: [.success(fresh("refreshed"))])
        let store = MemoryStore(Credentials(access: "old", refresh: "r", expiresAt: .distantFuture))
        let session = try AccountSession(api: api, store: store)
        try await session.discardLocal()
        do { _ = try await session.accessToken(); XCTFail() }
        catch { XCTAssertEqual(error as? AccountError, .signedOut) }
        let installed = try await session.establish { fresh("signed-in") }
        XCTAssertEqual(installed.access, "signed-in")
        let token = try await session.accessToken()
        XCTAssertEqual(token, "signed-in")
        XCTAssertEqual(api.refreshes, 0)
    }
}

/// The same recovery rules, end to end through the generated client: what the donor's screens actually hit.
final class WireRefreshFailureModeTests: XCTestCase {
    private func make(_ transport: ScriptedTransport) throws -> (WireDashboard, MemoryStore) {
        let store = MemoryStore(Credentials(access: "tok", refresh: "ref", expiresAt: .distantFuture))
        let session = try AccountSession(api: WireAPI(origin: testOrigin, transport: transport), store: store)
        return (WireDashboard(product: ProductClient(origin: testOrigin, transport: transport, session: session)), store)
    }

    func testAnUnauthorizedReadWhoseRefreshIsRefusedForTheServerBeingDownKeepsTheSession() async throws {
        for (refreshStatus, refreshBody) in [(HTTPResponse.Status.serviceUnavailable, "{}"), (.tooManyRequests, ""), (.internalServerError, "{}")] {
            let transport = ScriptedTransport { seen, _ in
                seen.request.path == "/donor/refresh" ? (refreshStatus, refreshBody) : (.unauthorized, "{}")
            }
            let (dashboard, store) = try make(transport)
            do { _ = try await dashboard.dashboard(); XCTFail("\(refreshStatus)") }
            catch { XCTAssertEqual(error as? AccountError, .unavailable, "\(refreshStatus)") }
            XCTAssertEqual(try store.load()?.refresh, "ref", "\(refreshStatus): an outage is not a revocation")
            XCTAssertEqual(transport.calls(to: "/donor/me/dashboard").count, 1, "no retry without a fresh credential")
            XCTAssertEqual(transport.calls(to: "/donor/refresh").count, 1)
        }
    }

    func testARefreshAnsweredWithABrowserShapedBodyIsNotACredential() async throws {
        let transport = ScriptedTransport { seen, _ in
            seen.request.path == "/donor/refresh" ? (.ok, #"{"signed_in":true}"#) : (.unauthorized, "{}")
        }
        let (dashboard, store) = try make(transport)
        do { _ = try await dashboard.dashboard(); XCTFail() }
        catch { assertBodyRejected(error) }
        XCTAssertEqual(try store.load()?.access, "tok")
    }

    func testARefreshRevokedByTheServerEndsTheSessionOnce() async throws {
        let transport = ScriptedTransport { _, _ in (.unauthorized, "{}") }
        let (dashboard, store) = try make(transport)
        do { _ = try await dashboard.dashboard(); XCTFail() }
        catch { XCTAssertEqual(error as? AccountError, .signedOut) }
        XCTAssertNil(try store.load())
        XCTAssertEqual(transport.calls(to: "/donor/refresh").count, 1)
        do { _ = try await dashboard.dashboard(); XCTFail() }
        catch { XCTAssertEqual(error as? AccountError, .signedOut) }
        XCTAssertEqual(transport.calls(to: "/donor/me/dashboard").count, 1, "a signed-out device sends nothing further")
    }

    func testBeingOfflineIsNotASignOutAndNeverTouchesTheCredentials() async throws {
        for code in [URLError.Code.notConnectedToInternet, .timedOut, .networkConnectionLost, .cannotFindHost] {
            let transport = ScriptedTransport { _, _ in throw URLError(code) }
            let (dashboard, store) = try make(transport)
            do { _ = try await dashboard.dashboard(); XCTFail("\(code)") }
            catch {
                XCTAssertNotEqual(error as? AccountError, .signedOut, "\(code)")
                XCTAssertFalse(error.isCancellation, "\(code)")
                XCTAssertEqual(error.userMessage, "Something went wrong. Please try again.")
            }
            XCTAssertEqual(try store.load()?.access, "tok", "\(code)")
            XCTAssertTrue(transport.calls(to: "/donor/refresh").isEmpty)
        }
    }

    func testAnOfflineRefreshAfterAnUnauthorizedReadKeepsTheSession() async throws {
        let transport = ScriptedTransport { seen, _ in
            if seen.request.path == "/donor/refresh" { throw URLError(.notConnectedToInternet) }
            return (.unauthorized, "{}")
        }
        let (dashboard, store) = try make(transport)
        do { _ = try await dashboard.dashboard(); XCTFail() }
        catch { XCTAssertNotEqual(error as? AccountError, .signedOut) }
        XCTAssertEqual(try store.load()?.refresh, "ref")
    }
}
