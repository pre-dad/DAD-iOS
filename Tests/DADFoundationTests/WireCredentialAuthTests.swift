import Foundation
import HTTPTypes
import OpenAPIRuntime
import XCTest
@testable import DADFoundation

private let wrongCurrentJSON = #"{"detail":"Current password is incorrect","code":"CURRENT_PASSWORD_INCORRECT"}"#
private let rejectedJSON = #"{"detail":"The email or password is incorrect"}"#

final class WireSignupTests: XCTestCase {
    private let form = SignupForm(name: "Alex Rivera", email: "alex@example.org", zip: "78701", city: "Austin")

    func testSignupPostsTheFormUnauthenticatedAndAcceptsTheDocumented200() async throws {
        let transport = ScriptedTransport { _, _ in (.ok, #"{"sent":true}"#) }
        try await WireCredentialAuth(origin: testOrigin, transport: transport).requestSignup(form)
        let call = try XCTUnwrap(transport.seen.first)
        XCTAssertEqual(call.request.path, "/donor/signup")
        XCTAssertNil(call.request.headerFields[.authorization])
        XCTAssertEqual(call.request.headerFields[nativeClientHeader], "native")
        let sent = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(call.body.utf8)) as? [String: Any])
        XCTAssertEqual(sent["name"] as? String, "Alex Rivera")
        XCTAssertEqual(sent["email"] as? String, "alex@example.org")
        XCTAssertEqual(sent["zip"] as? String, "78701")
        XCTAssertEqual(sent["city"] as? String, "Austin")
        XCTAssertEqual(sent.count, 4)
    }

    /// An older server's 202 (with any body) still means "link emailed".
    func testSignupAcceptsAnyOlderServer2xxReply() async throws {
        let transport = ScriptedTransport { _, _ in (.accepted, #"{"message":"Check your email"}"#) }
        try await WireCredentialAuth(origin: testOrigin, transport: transport).requestSignup(form)
        XCTAssertEqual(transport.seen.count, 1)
        XCTAssertEqual(transport.seen.first?.request.path, "/donor/signup")
    }

    func testSignupStatusMapping() async {
        let cases: [(HTTPResponse.Status, AccountError)] = [
            (.unprocessableContent, .invalidInput), (.tooManyRequests, .rateLimited),
            (.serviceUnavailable, .unavailable), (.forbidden, .unavailable), (.internalServerError, .unavailable),
            (.conflict, .unavailable),
        ]
        for (status, expected) in cases {
            let transport = ScriptedTransport { _, _ in (status, "{}") }
            do { try await WireCredentialAuth(origin: testOrigin, transport: transport).requestSignup(form); XCTFail("\(status)") }
            catch { XCTAssertEqual(error as? AccountError, expected, "\(status)") }
        }
    }

    func testInsecureOriginIsRejected() {
        XCTAssertThrowsError(try WireCredentialAuth(origin: URL(string: "http://api.test")!))
    }
}

final class WireSignInLinkTests: XCTestCase {
    func testSignInLinkPostsOnlyTheEmailUnauthenticated() async throws {
        let transport = ScriptedTransport { _, _ in (.accepted, #"{"message":"Check your email"}"#) }
        try await WireCredentialAuth(origin: testOrigin, transport: transport).requestSignInLink(email: "alex@example.org")
        let call = try XCTUnwrap(transport.seen.first)
        XCTAssertEqual(call.request.method, .post)
        XCTAssertEqual(call.request.path, "/donor/login")
        XCTAssertNil(call.request.headerFields[.authorization])
        XCTAssertEqual(call.request.headerFields[nativeClientHeader], "native")
        let sent = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(call.body.utf8)) as? [String: Any])
        XCTAssertEqual(sent as? [String: String], ["email": "alex@example.org"], "no return page: the app claims the link itself")
    }

    func testSignInLinkStatusMapping() async {
        let cases: [(HTTPResponse.Status, AccountError)] = [
            (.unprocessableContent, .invalidInput), (.tooManyRequests, .rateLimited),
            (.serviceUnavailable, .unavailable), (.forbidden, .unavailable), (.internalServerError, .unavailable),
        ]
        for (status, expected) in cases {
            let transport = ScriptedTransport { _, _ in (status, #"{"detail":"x"}"#) }
            do {
                try await WireCredentialAuth(origin: testOrigin, transport: transport).requestSignInLink(email: "alex@example.org")
                XCTFail("\(status)")
            } catch { XCTAssertEqual(error as? AccountError, expected, "\(status)") }
        }
    }
}

final class WirePasswordSignInTests: XCTestCase {
    func testPasswordSignInSendsEmailAndPasswordWithNoBearerAndReturnsNativeCredentials() async throws {
        let transport = ScriptedTransport { _, _ in (.ok, nativeSessionJSON) }
        let credentials = try await WireCredentialAuth(origin: testOrigin, transport: transport)
            .signIn(email: "alex@example.org", password: "correct horse battery")
        XCTAssertEqual(credentials.access, "A1")
        XCTAssertEqual(credentials.refresh, "R1")
        let call = try XCTUnwrap(transport.seen.first)
        XCTAssertEqual(call.request.path, "/donor/password/sign-in")
        XCTAssertNil(call.request.headerFields[.authorization])
        XCTAssertEqual(call.request.headerFields[nativeClientHeader], "native")
        let sent = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(call.body.utf8)) as? [String: Any])
        XCTAssertEqual(sent["email"] as? String, "alex@example.org")
        XCTAssertEqual(sent["password"] as? String, "correct horse battery")
        XCTAssertEqual(sent["platform"] as? String, "IOS")
        XCTAssertNil(sent["device_name"], "no device name configured, none sent")
        XCTAssertEqual(sent.count, 3)
    }

    func testPasswordSignInSendsDeviceNameAndPlatform() async throws {
        let transport = ScriptedTransport { _, _ in (.ok, nativeSessionJSON) }
        _ = try await WireCredentialAuth(origin: testOrigin, transport: transport, deviceName: "Alex’s iPhone")
            .signIn(email: "alex@example.org", password: "correct horse battery")
        let sent = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(try XCTUnwrap(transport.seen.first).body.utf8)) as? [String: Any])
        XCTAssertEqual(sent["device_name"] as? String, "Alex’s iPhone")
        XCTAssertEqual(sent["platform"] as? String, "IOS")
    }

    func testStatusMapping() async {
        let cases: [(HTTPResponse.Status, AccountError)] = [
            (.unauthorized, .signedOut), (.unprocessableContent, .invalidInput), (.tooManyRequests, .rateLimited),
            (.serviceUnavailable, .unavailable), (.forbidden, .unavailable),
        ]
        for (status, expected) in cases {
            let transport = ScriptedTransport { _, _ in (status, "{}") }
            do { _ = try await WireCredentialAuth(origin: testOrigin, transport: transport).signIn(email: "a@b.co", password: "x"); XCTFail("\(status)") }
            catch { XCTAssertEqual(error as? AccountError, expected, "\(status)") }
        }
    }

    func testBrowserShapedOrEmptyTokenBodiesAreNeverASession() async {
        for json in [#"{"signed_in":true}"#,
                     #"{"access_token":"","expires_in":900,"refresh_token":"R","refresh_expires_in":1}"#,
                     #"{"access_token":"A","expires_in":0,"refresh_token":"R","refresh_expires_in":1}"#] {
            let transport = ScriptedTransport { _, _ in (.ok, json) }
            do { _ = try await WireCredentialAuth(origin: testOrigin, transport: transport).signIn(email: "a@b.co", password: "x"); XCTFail(json) }
            catch { XCTAssertEqual(error as? AccountError, .invalidResponse, json) }
        }
    }

    func testMalformedBodyIsAFailureNotASession() async {
        let transport = ScriptedTransport { _, _ in (.ok, "not json") }
        do { _ = try await WireCredentialAuth(origin: testOrigin, transport: transport).signIn(email: "a@b.co", password: "x"); XCTFail() }
        catch { assertBodyRejected(error) }
    }

    func testSignOutDuringPasswordSignInDiscardsTheLateResult() async throws {
        let gate = Gate()
        let transport = ScriptedTransport { _, _ in await gate.pass(); return (.ok, nativeSessionJSON) }
        let store = MemoryStore(nil)
        let session = try AccountSession(api: ControlledAPI(), store: store)
        let auth = WireCredentialAuth(origin: testOrigin, transport: transport)
        let signIn = Task { try await session.establish { try await auth.signIn(email: "a@b.co", password: "pw") } }
        await gate.waitUntilEntered()
        try await session.discardLocal()
        await gate.release()
        do { _ = try await signIn.value; XCTFail("late sign-in resurrected a signed-out session") }
        catch { XCTAssertEqual(error as? AccountError, .signedOut) }
        XCTAssertNil(try store.load())
    }

    func testCancelledPasswordSignInInstallsNothing() async throws {
        let gate = Gate()
        let transport = ScriptedTransport { _, _ in await gate.pass(); return (.ok, nativeSessionJSON) }
        let store = MemoryStore(nil)
        let session = try AccountSession(api: ControlledAPI(), store: store)
        let auth = WireCredentialAuth(origin: testOrigin, transport: transport)
        let signIn = Task { try await session.establish { try await auth.signIn(email: "a@b.co", password: "pw") } }
        await gate.waitUntilEntered()
        signIn.cancel()
        await gate.release()
        do { _ = try await signIn.value; XCTFail("a cancelled sign-in reported success") }
        catch { XCTAssertTrue(error is CancellationError, "\(error)") }
        XCTAssertNil(try store.load(), "a cancelled sign-in must not persist credentials")
        XCTAssertEqual(store.saves, 0)
    }
}

final class WireOIDCTests: XCTestCase {
    func testAppleAndGoogleHitTheirOwnPathWithTokenPlatformAndDevice() async throws {
        for (provider, path) in [(OIDCProvider.apple, "/donor/oidc/apple/sign-in"), (.google, "/donor/oidc/google/sign-in")] {
            let transport = ScriptedTransport { _, _ in (.ok, nativeSessionJSON) }
            let credentials = try await WireCredentialAuth(origin: testOrigin, transport: transport, deviceName: "Alex’s iPhone")
                .signIn(provider: provider, idToken: "header.payload.sig", nonce: "raw-nonce-value")
            XCTAssertEqual(credentials.access, "A1")
            let call = try XCTUnwrap(transport.seen.first)
            XCTAssertEqual(call.request.path, path)
            XCTAssertNil(call.request.headerFields[.authorization])
            for fragment in ["header.payload.sig", "IOS", "Alex"] { XCTAssertTrue(call.body.contains(fragment), fragment) }
            let json = try JSONSerialization.jsonObject(with: Data(call.body.utf8)) as? [String: Any]
            XCTAssertEqual(json?["nonce"] as? String, "raw-nonce-value")
        }
    }

    func testStatusMapping() async {
        let cases: [(HTTPResponse.Status, AccountError)] = [
            (.unauthorized, .signedOut), (.unprocessableContent, .invalidInput), (.tooManyRequests, .rateLimited),
            (.serviceUnavailable, .unavailable), (.forbidden, .unavailable),
        ]
        for (status, expected) in cases {
            let transport = ScriptedTransport { _, _ in (status, "{}") }
            do { _ = try await WireCredentialAuth(origin: testOrigin, transport: transport).signIn(provider: .apple, idToken: "t", nonce: "n"); XCTFail("\(status)") }
            catch { XCTAssertEqual(error as? AccountError, expected, "\(status)") }
        }
    }

    func testEmptyOrOversizeTokenNeverReachesTheWire() async {
        for token in ["", String(repeating: "a", count: 8193)] {
            let transport = ScriptedTransport { _, _ in (.ok, nativeSessionJSON) }
            do { _ = try await WireCredentialAuth(origin: testOrigin, transport: transport).signIn(provider: .google, idToken: token, nonce: "n"); XCTFail() }
            catch { XCTAssertEqual(error as? AccountError, .invalidInput) }
            XCTAssertTrue(transport.seen.isEmpty)
        }
    }

    func testEmptyOrOversizeNonceNeverReachesTheWire() async {
        for nonce in ["", String(repeating: "n", count: 257)] {
            let transport = ScriptedTransport { _, _ in (.ok, nativeSessionJSON) }
            do { _ = try await WireCredentialAuth(origin: testOrigin, transport: transport).signIn(provider: .apple, idToken: "t", nonce: nonce); XCTFail() }
            catch { XCTAssertEqual(error as? AccountError, .invalidInput) }
            XCTAssertTrue(transport.seen.isEmpty)
        }
    }

    func testBrowserShapedBodyIsNeverASession() async {
        let transport = ScriptedTransport { _, _ in (.ok, #"{"signed_in":true}"#) }
        do { _ = try await WireCredentialAuth(origin: testOrigin, transport: transport).signIn(provider: .apple, idToken: "t", nonce: "n"); XCTFail() }
        catch { XCTAssertEqual(error as? AccountError, .invalidResponse) }
    }
}

private let passkeyChallengeBytes = Data((0..<32).map { UInt8($0) })
private let passkeyOptionsJSON =
    #"{"ceremony":"\#(String(repeating: "c", count: 40))","options":{"challenge":"\#(passkeyChallengeBytes.base64URLEncoded)","rpId":"dad.example","timeout":300000}}"#

final class WirePasskeyTests: XCTestCase {
    private let challengeBytes = passkeyChallengeBytes
    private let assertion = PasskeyAssertion(credentialID: Data([1, 2, 3]), clientDataJSON: Data("{}".utf8),
                                             authenticatorData: Data([9, 9]), signature: Data([7, 7, 7]), userHandle: Data([5]))

    func testBeginParsesTheChallengeWithNoBodyAndNoBearer() async throws {
        let transport = ScriptedTransport { _, _ in (.ok, passkeyOptionsJSON) }
        let challenge = try await WireCredentialAuth(origin: testOrigin, transport: transport).begin()
        XCTAssertEqual(challenge.challenge, challengeBytes)
        XCTAssertEqual(challenge.relyingParty, "dad.example")
        XCTAssertEqual(challenge.ceremony.count, 40)
        let call = try XCTUnwrap(transport.seen.first)
        XCTAssertEqual(call.request.path, "/donor/passkeys/sign-in/options")
        XCTAssertNil(call.request.headerFields[.authorization])
    }

    func testBeginRejectsMalformedChallenges() async {
        let bad = [
            #"{"ceremony":"","options":{"challenge":"AAAA"}}"#,
            #"{"ceremony":"c","options":{}}"#,
            #"{"ceremony":"c","options":{"challenge":""}}"#,
            #"{"ceremony":"c","options":{"challenge":"***not base64***"}}"#,
            #"{"ceremony":"c","options":{"challenge":42}}"#,
        ]
        for json in bad {
            let transport = ScriptedTransport { _, _ in (.ok, json) }
            do { _ = try await WireCredentialAuth(origin: testOrigin, transport: transport).begin(); XCTFail(json) }
            catch { XCTAssertEqual(error as? AccountError, .invalidResponse, json) }
        }
    }

    func testBeginStatusMapping() async {
        for (status, expected) in [(HTTPResponse.Status.tooManyRequests, AccountError.rateLimited), (.serviceUnavailable, .unavailable), (.forbidden, .unavailable)] {
            let transport = ScriptedTransport { _, _ in (status, "{}") }
            do { _ = try await WireCredentialAuth(origin: testOrigin, transport: transport).begin(); XCTFail("\(status)") }
            catch { XCTAssertEqual(error as? AccountError, expected, "\(status)") }
        }
    }

    func testFinishSendsCeremonyAndWebAuthnJSONAndReturnsCredentials() async throws {
        let transport = ScriptedTransport { _, _ in (.ok, nativeSessionJSON) }
        let challenge = PasskeyChallenge(ceremony: String(repeating: "c", count: 40), challenge: challengeBytes, relyingParty: nil)
        let credentials = try await WireCredentialAuth(origin: testOrigin, transport: transport, deviceName: "Phone")
            .finish(challenge, assertion: assertion)
        XCTAssertEqual(credentials.access, "A1")
        let call = try XCTUnwrap(transport.seen.first)
        XCTAssertEqual(call.request.path, "/donor/passkeys/sign-in")
        let sent = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(call.body.utf8)) as? [String: Any])
        XCTAssertEqual(sent["ceremony"] as? String, challenge.ceremony)
        XCTAssertEqual(sent["platform"] as? String, "IOS")
        let credential = try XCTUnwrap(sent["credential"] as? [String: Any])
        XCTAssertEqual(credential["type"] as? String, "public-key")
        XCTAssertEqual(credential["id"] as? String, "AQID")
        XCTAssertEqual(credential["rawId"] as? String, "AQID")
        let response = try XCTUnwrap(credential["response"] as? [String: Any])
        XCTAssertEqual(response["signature"] as? String, "BwcH")
        XCTAssertEqual(response["userHandle"] as? String, "BQ")
        XCTAssertEqual(response["authenticatorData"] as? String, "CQk")
        XCTAssertNotNil(response["clientDataJSON"])
    }

    func testFinishStatusMappingAndBrowserBody() async {
        let challenge = PasskeyChallenge(ceremony: String(repeating: "c", count: 40), challenge: challengeBytes, relyingParty: nil)
        for (status, expected) in [(HTTPResponse.Status.unauthorized, AccountError.signedOut), (.unprocessableContent, .invalidInput),
                                   (.tooManyRequests, .rateLimited), (.serviceUnavailable, .unavailable)] {
            let transport = ScriptedTransport { _, _ in (status, "{}") }
            do { _ = try await WireCredentialAuth(origin: testOrigin, transport: transport).finish(challenge, assertion: assertion); XCTFail("\(status)") }
            catch { XCTAssertEqual(error as? AccountError, expected, "\(status)") }
        }
        let browser = ScriptedTransport { _, _ in (.ok, #"{"signed_in":true}"#) }
        do { _ = try await WireCredentialAuth(origin: testOrigin, transport: browser).finish(challenge, assertion: assertion); XCTFail() }
        catch { XCTAssertEqual(error as? AccountError, .invalidResponse) }
    }

    func testBase64URLRoundTripAndRejection() {
        let data = Data([0xfb, 0xff, 0xfe, 0x00, 0x10])
        XCTAssertEqual(data.base64URLEncoded, "-__-ABA")
        XCTAssertEqual(Data(base64URL: "-__-ABA"), data)
        XCTAssertNil(Data(base64URL: "***"))
    }
}

final class WirePasswordSettingsTests: XCTestCase {
    private func make(_ transport: ScriptedTransport) throws -> (WirePasswordSettings, AccountSession, MemoryStore) {
        let store = MemoryStore(Credentials(access: "tok", refresh: "ref", expiresAt: .distantFuture))
        let session = try AccountSession(api: WireAPI(origin: testOrigin, transport: transport), store: store)
        return (WirePasswordSettings(product: ProductClient(origin: testOrigin, transport: transport, session: session)), session, store)
    }

    func testSetPasswordSendsBearerAndOmitsAbsentCurrent() async throws {
        let transport = ScriptedTransport { _, _ in (.ok, #"{"saved":true}"#) }
        let (settings, _, _) = try make(transport)
        try await settings.setPassword(current: nil, new: "a brand new passphrase")
        let call = try XCTUnwrap(transport.seen.first)
        XCTAssertEqual(call.request.path, "/donor/me/password")
        XCTAssertEqual(call.request.headerFields[.authorization], "Bearer tok")
        let sent = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(call.body.utf8)) as? [String: Any])
        XCTAssertEqual(sent["password"] as? String, "a brand new passphrase")
        XCTAssertNil(sent["current_password"])
        try await settings.setPassword(current: "old passphrase!", new: "another new passphrase")
        let second = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(transport.seen[1].body.utf8)) as? [String: Any])
        XCTAssertEqual(second["current_password"] as? String, "old passphrase!")
    }

    /// A wrong current password is a 422 with a code. It must NOT refresh, retry or end the session.
    func testWrongCurrentPasswordIsNotASessionFailure() async throws {
        try await assertWrongPassword(.unprocessableContent, wrongCurrentJSON)
    }

    /// Servers older than contract 2.4 answered the same condition with a 401 and this detail.
    func testLegacy401WrongPasswordFallbackIsNotASessionFailure() async throws {
        try await assertWrongPassword(.unauthorized, rejectedJSON)
    }

    func testUnknownProblemCodeOn422IsInvalidInput() async throws {
        let (settings, _, store) = try make(ScriptedTransport { _, _ in (.unprocessableContent, #"{"detail":"x","code":"SOMETHING_NEW"}"#) })
        do { try await settings.setPassword(current: "a", new: "a brand new passphrase"); XCTFail() }
        catch { XCTAssertEqual(error as? AccountError, .invalidInput) }
        XCTAssertNotNil(try store.load())
    }

    private func assertWrongPassword(_ status: HTTPResponse.Status, _ json: String) async throws {
        let transport = ScriptedTransport { _, _ in (status, json) }
        let (settings, session, store) = try make(transport)
        do { try await settings.setPassword(current: "typo", new: "a brand new passphrase"); XCTFail() }
        catch { XCTAssertEqual(error as? AccountError, .passwordIncorrect) }
        XCTAssertEqual(transport.seen.count, 1, "no refresh and no retry for a rejected credential")
        XCTAssertNotNil(try store.load(), "a typo must not wipe the session")
        let signedIn = await session.isSignedIn
        XCTAssertTrue(signedIn)
    }

    func testExpiredAccessTokenRefreshesOnceAndRetries() async throws {
        let transport = ScriptedTransport { seen, _ in
            switch seen.request.path {
            case "/donor/refresh": return (.ok, freshSessionJSON)
            default: return seen.request.headerFields[.authorization] == "Bearer fresh" ? (.ok, #"{"saved":true}"#) : (.unauthorized, "{}")
            }
        }
        let (settings, _, store) = try make(transport)
        try await settings.setPassword(current: nil, new: "a brand new passphrase")
        XCTAssertEqual(transport.calls(to: "/donor/refresh").count, 1)
        XCTAssertEqual(transport.calls(to: "/donor/me/password").count, 2)
        XCTAssertEqual(try store.load()?.access, "fresh")
    }

    func testSecondGenericUnauthorizedEndsTheSession() async throws {
        let transport = ScriptedTransport { seen, _ in seen.request.path == "/donor/refresh" ? (.ok, freshSessionJSON) : (.unauthorized, "{}") }
        let (settings, _, store) = try make(transport)
        do { try await settings.setPassword(current: nil, new: "a brand new passphrase"); XCTFail() }
        catch { XCTAssertEqual(error as? AccountError, .signedOut) }
        XCTAssertNil(try store.load())
    }

    func testStatusMapping() async throws {
        let cases: [(HTTPResponse.Status, AccountError)] = [
            (.unprocessableContent, .invalidInput), (.tooManyRequests, .rateLimited), (.serviceUnavailable, .unavailable),
            (.conflict, .unavailable), (.forbidden, .unavailable),
        ]
        for (status, expected) in cases {
            let (settings, _, store) = try make(ScriptedTransport { _, _ in (status, "{}") })
            do { try await settings.setPassword(current: nil, new: "a brand new passphrase"); XCTFail("\(status)") }
            catch { XCTAssertEqual(error as? AccountError, expected, "\(status)") }
            XCTAssertNotNil(try store.load(), "\(status) must not end the session")
        }
    }

    func testSignOutWhileSavingDiscardsTheResult() async throws {
        let gate = Gate()
        let transport = ScriptedTransport { _, _ in await gate.pass(); return (.ok, #"{"saved":true}"#) }
        let (settings, session, _) = try make(transport)
        let task = Task { try await settings.setPassword(current: nil, new: "a brand new passphrase") }
        await gate.waitUntilEntered()
        try await session.discardLocal()
        await gate.release()
        do { try await task.value; XCTFail("a save that outlived its session reported success") }
        catch { XCTAssertEqual(error as? AccountError, .signedOut) }
    }

    func testPasskeyListAndDelete() async throws {
        let id = "11111111-1111-1111-1111-111111111111"
        let list = #"{"passkeys":[{"id":"\#(id)","name":"Alex’s iPhone","created_at":"2026-10-01T10:00:00Z","last_used_at":null}]}"#
        let transport = ScriptedTransport { seen, _ in (.ok, list) }   // delete answers with the remaining list
        let (service, _, _) = try make(transport)
        let passkeys = try await service.list()
        XCTAssertEqual(passkeys, [PasskeySummary(id: id, name: "Alex’s iPhone")])
        try await service.delete(id: id)
        XCTAssertEqual(transport.calls(to: "/donor/me/passkeys/\(id)/delete").count, 1)
        XCTAssertEqual(transport.seen.last?.request.headerFields[.authorization], "Bearer tok")
    }

    func testPasskeyDeleteNotFoundMapsToInvalidInput() async throws {
        let (service, _, _) = try make(ScriptedTransport { _, _ in (.notFound, "{}") })
        do { try await service.delete(id: "11111111-1111-1111-1111-111111111111"); XCTFail() }
        catch { XCTAssertEqual(error as? AccountError, .invalidInput) }
    }
}
