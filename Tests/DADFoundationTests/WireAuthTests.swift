import Foundation
import HTTPTypes
import OpenAPIRuntime
import XCTest
@testable import DADFoundation

final class WireAuthTests: XCTestCase {
    func testRequestCodePostsPhoneUnauthenticatedAndReturnsItAsHandle() async throws {
        let transport = ScriptedTransport { _, _ in (.ok, #"{"sent":true}"#) }
        let handle = try await WireAuth(origin: testOrigin, transport: transport).requestPhoneCode(phone: "+14155550123")
        XCTAssertEqual(handle, "+14155550123")
        let call = try XCTUnwrap(transport.seen.first)
        XCTAssertEqual(call.request.path, "/donor/phone/sign-in/options")
        XCTAssertTrue(call.body.contains("+14155550123"))
        XCTAssertNil(call.request.headerFields[.authorization], "sign-in must never carry a bearer")
        XCTAssertEqual(call.request.headerFields[nativeClientHeader], "native")
    }

    func testRequestCodeStatusMapping() async {
        let cases: [(HTTPResponse.Status, AccountError)] = [
            (.unprocessableContent, .invalidInput), (.tooManyRequests, .rateLimited),
            (.serviceUnavailable, .unavailable), (.forbidden, .unavailable), (.internalServerError, .unavailable),
        ]
        for (status, expected) in cases {
            let transport = ScriptedTransport { _, _ in (status, "{}") }
            do { _ = try await WireAuth(origin: testOrigin, transport: transport).requestPhoneCode(phone: "+14155550123"); XCTFail("\(status)") }
            catch { XCTAssertEqual(error as? AccountError, expected, "\(status)") }
        }
    }

    func testVerifyReturnsNativeCredentialsAndSendsPlatformCodeAndDeviceName() async throws {
        let transport = ScriptedTransport { _, _ in (.ok, nativeSessionJSON) }
        let credentials = try await WireAuth(origin: testOrigin, transport: transport, deviceName: "Alex’s iPhone")
            .verifyPhone(handle: "+14155550123", code: "123456")
        XCTAssertEqual(credentials.access, "A1")
        XCTAssertEqual(credentials.refresh, "R1")
        XCTAssertGreaterThan(credentials.expiresAt.timeIntervalSinceNow, 800)
        let call = try XCTUnwrap(transport.seen.first)
        XCTAssertEqual(call.request.path, "/donor/phone/sign-in")
        for fragment in ["+14155550123", "123456", "IOS", "Alex"] { XCTAssertTrue(call.body.contains(fragment), fragment) }
        XCTAssertNil(call.request.headerFields[.authorization])
    }

    func testVerifyStatusMapping() async {
        let cases: [(HTTPResponse.Status, AccountError)] = [
            (.unauthorized, .signedOut), (.tooManyRequests, .rateLimited), (.unprocessableContent, .invalidInput),
            (.serviceUnavailable, .unavailable),
        ]
        for (status, expected) in cases {
            let transport = ScriptedTransport { _, _ in (status, "{}") }
            do { _ = try await WireAuth(origin: testOrigin, transport: transport).verifyPhone(handle: "+1", code: "1"); XCTFail("\(status)") }
            catch { XCTAssertEqual(error as? AccountError, expected, "\(status)") }
        }
    }

    func testBrowserShapedOrEmptyTokenBodiesAreNeverASession() async {
        for json in [#"{"signed_in":true}"#,
                     #"{"access_token":"","expires_in":900,"refresh_token":"R","refresh_expires_in":1}"#,
                     #"{"access_token":"A","expires_in":0,"refresh_token":"R","refresh_expires_in":1}"#] {
            let transport = ScriptedTransport { _, _ in (.ok, json) }
            do { _ = try await WireAuth(origin: testOrigin, transport: transport).verifyPhone(handle: "+1", code: "123456"); XCTFail(json) }
            catch { XCTAssertEqual(error as? AccountError, .invalidResponse, json) }
        }
    }

    func testInsecureOriginIsRejected() {
        XCTAssertThrowsError(try WireAuth(origin: URL(string: "http://api.test")!))
    }

    func testSignOutDuringSignInDiscardsTheLateResult() async throws {
        let gate = Gate()
        let transport = ScriptedTransport { _, _ in await gate.pass(); return (.ok, nativeSessionJSON) }
        let store = MemoryStore(nil)
        let session = try AccountSession(api: ControlledAPI(), store: store)
        let auth = WireAuth(origin: testOrigin, transport: transport)
        let signIn = Task { try await session.establish { try await auth.verifyPhone(handle: "+14155550123", code: "123456") } }
        await gate.waitUntilEntered()
        try await session.discardLocal()   // signed out / switched while the SMS check was in flight
        await gate.release()
        do { _ = try await signIn.value; XCTFail("late sign-in resurrected a signed-out session") }
        catch { XCTAssertEqual(error as? AccountError, .signedOut) }
        XCTAssertNil(try store.load())
        let signedIn = await session.isSignedIn
        XCTAssertFalse(signedIn)
    }

    func testEstablishInstallsAndPersistsExactlyOnce() async throws {
        let transport = ScriptedTransport { _, _ in (.ok, nativeSessionJSON) }
        let store = MemoryStore(nil)
        let session = try AccountSession(api: ControlledAPI(), store: store)
        let auth = WireAuth(origin: testOrigin, transport: transport)
        let installed = try await session.establish { try await auth.verifyPhone(handle: "+14155550123", code: "123456") }
        XCTAssertEqual(installed.access, "A1")
        XCTAssertEqual(store.saves, 1)
        XCTAssertEqual(try store.load()?.refresh, "R1")
        let signedIn = await session.isSignedIn
        XCTAssertTrue(signedIn)
    }

    func testFailedVerifyLeavesNoCredentials() async throws {
        let transport = ScriptedTransport { _, _ in (.unauthorized, "{}") }
        let store = MemoryStore(nil)
        let session = try AccountSession(api: ControlledAPI(), store: store)
        let auth = WireAuth(origin: testOrigin, transport: transport)
        do { _ = try await session.establish { try await auth.verifyPhone(handle: "+1", code: "000000") }; XCTFail("verifyPhone must throw") }
        catch { XCTAssertEqual(error as? AccountError, .signedOut) }
        XCTAssertNil(try store.load())
        XCTAssertEqual(store.saves, 0)
    }

    @MainActor func testPhoneModelEstablishesThroughTheSessionAndMapsErrors() async throws {
        let transport = ScriptedTransport { seen, _ in
            seen.request.path == "/donor/phone/sign-in/options" ? (.ok, #"{"sent":true}"#)
                : seen.body.contains("123456") ? (.ok, nativeSessionJSON) : (.tooManyRequests, "{}")
        }
        let session = try AccountSession(api: ControlledAPI(), store: MemoryStore(nil))
        let model = PhoneSignInModel(service: WireAuth(origin: testOrigin, transport: transport)) { produce in
            try await session.establish(produce)
        }
        model.phone = "+14155550123"
        await model.requestCode()
        XCTAssertTrue(model.isAwaitingCode)
        model.code = "000000"
        await model.verify()
        guard case .failed(let message) = model.phase else { return XCTFail("expected failure") }
        XCTAssertTrue(message.contains("Too many"))
        let early = await session.isSignedIn
        XCTAssertFalse(early)
        model.code = "123456"
        await model.verify()
        guard case .signedIn(let credentials) = model.phase else { return XCTFail("expected signed in: \(model.phase)") }
        XCTAssertEqual(credentials.access, "A1")
        let signedIn = await session.isSignedIn
        XCTAssertTrue(signedIn)
    }
}

final class SessionAuthorizedTests: XCTestCase {
    func testAuthorizedRetriesOnceAfter401WithARefreshedToken() async throws {
        let api = ControlledAPI()
        let session = try AccountSession(api: api, store: MemoryStore(Credentials(access: "old", refresh: "r", expiresAt: .distantFuture)))
        let task = Task { try await session.authorized { access -> String in if access == "old" { throw AccountError.signedOut }; return access } }
        await api.waitForRefresh()
        await api.finishRefresh()
        let used = try await task.value
        XCTAssertEqual(used, "new")
    }

    func testSecond401EndsTheSessionLocally() async throws {
        let api = ControlledAPI()
        let store = MemoryStore(Credentials(access: "old", refresh: "r", expiresAt: .distantFuture))
        let session = try AccountSession(api: api, store: store)
        let task = Task { try await session.authorized { _ -> String in throw AccountError.signedOut } }
        await api.waitForRefresh()
        await api.finishRefresh()
        do { _ = try await task.value; XCTFail("the failed refresh must surface to its waiter") } catch { XCTAssertEqual(error as? AccountError, .signedOut) }
        XCTAssertNil(try store.load())
    }

    func testNonAuthFailuresDoNotRefreshOrClear() async throws {
        let store = MemoryStore(Credentials(access: "ok", refresh: "r", expiresAt: .distantFuture))
        let session = try AccountSession(api: ControlledAPI(), store: store)
        do { _ = try await session.authorized { _ -> Int in throw AccountError.unavailable }; XCTFail("authorized must throw") }
        catch { XCTAssertEqual(error as? AccountError, .unavailable) }
        XCTAssertNotNil(try store.load())
    }

    func testDiscardLocalInvalidatesAnInFlightCall() async throws {
        let gate = Gate()
        let store = MemoryStore(Credentials(access: "ok", refresh: "r", expiresAt: .distantFuture))
        let session = try AccountSession(api: ControlledAPI(), store: store)
        let task = Task { try await session.authorized { _ -> Int in await gate.pass(); return 1 } }
        await gate.waitUntilEntered()
        try await session.discardLocal()
        await gate.release()
        do { _ = try await task.value; XCTFail("result of a call that outlived its session was returned") }
        catch { XCTAssertEqual(error as? AccountError, .signedOut) }
    }

    func testRestoredCredentialsFlagReflectsStore() throws {
        let stored = Credentials(access: "a", refresh: "r", expiresAt: .distantFuture)
        XCTAssertTrue(try AccountSession(api: ControlledAPI(), store: MemoryStore(stored)).restoredCredentials)
        XCTAssertFalse(try AccountSession(api: ControlledAPI(), store: MemoryStore(nil)).restoredCredentials)
    }
}
