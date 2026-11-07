import Foundation
import HTTPTypes
import OpenAPIRuntime
import XCTest
@testable import DADFoundation

private struct TestTransport: ClientTransport {
    let json: String
    let validate: @Sendable (HTTPRequest) -> Void
    func send(_ request: HTTPRequest, body: HTTPBody?, baseURL: URL, operationID: String) async throws -> (HTTPResponse, HTTPBody?) {
        validate(request)
        return (HTTPResponse(status: .ok, headerFields: [.contentType: "application/json"]), HTTPBody(json))
    }
}

@MainActor final class WireTests: XCTestCase {
    func testGeneratedClientSendsNativeBearerWithoutCookies() async throws {
        let transport = TestTransport(json: #"{"email":"donor@example.org","public_name":null,"account_role":"DONOR","zip":null,"city":null,"timezone":null,"phone":null,"referral_emails":true,"marketing_emails":false,"push_referral_converted":true,"push_streak_at_risk":true,"push_streak_milestone":true,"push_streak_lapsed":true,"push_badge_earned":true,"push_gift_processed":true,"push_event_nearby":true,"push_event_reminder":true,"push_event_promoted":true,"rankings_opted_out":false,"network_visible":false,"volunteer":false,"volunteer_interests":[],"version":3,"consent_version":"synthetic-v1"}"#) { request in
            XCTAssertEqual(request.headerFields[.authorization], "Bearer synthetic-access")
            XCTAssertEqual(request.headerFields[.init("X-DAD-Client")!], "native")
            XCTAssertNil(request.headerFields[.cookie])
            XCTAssertNil(request.headerFields[.init("Origin")!])
        }
        let api = WireAPI(origin: URL(string: "https://api.test")!, transport: transport)
        let profile = try await api.profile(access: "synthetic-access")
        XCTAssertEqual(profile, AccountProfile(email: "donor@example.org", publicName: nil))
    }
    func testBrowserClaimPayloadIsRejectedByNativeSessionAdapter() async throws {
        let transport = TestTransport(json: #"{"claimed":true}"#) { _ in }
        do {
            _ = try await WireAPI(origin: URL(string: "https://api.test")!, transport: transport).claim(token: String(repeating: "a", count: 32))
            XCTFail("browser payload accepted as native credentials")
        } catch { XCTAssertEqual(error as? AccountError, .invalidResponse) }
    }
    func testInsecureAndNonOriginURLsAreRejected() {
        for value in ["http://api.test", "https://user:pass@api.test", "https://api.test/path", "https://api.test?query=x"] {
            XCTAssertThrowsError(try WireAPI(origin: URL(string: value)!))
        }
    }
    func testOversizedResponseIsRejected() async throws {
        let transport = TestTransport(json: String(repeating: "x", count: 1_048_577)) { _ in }
        do {
            _ = try await WireAPI(origin: URL(string: "https://api.test")!, transport: transport).profile(access: "synthetic-access")
            XCTFail("unbounded response accepted")
        } catch { assertBodyRejected(error) }
    }

    func testMiddlewareStripsAmbientCredentialsAndAttachesOnlyTheProvidedBearer() async throws {
        var incoming = HTTPRequest(method: .get, scheme: "https", authority: "api.test", path: "/p")
        incoming.headerFields[.cookie] = "session=ambient"
        incoming.headerFields[.authorization] = "Bearer stale"
        incoming.headerFields[HTTPField.Name("Origin")!] = "https://evil.test"
        let seen = SeenRequest()
        let next: @Sendable (HTTPRequest, HTTPBody?, URL) async throws -> (HTTPResponse, HTTPBody?) = { request, _, _ in
            seen.set(request)
            return (HTTPResponse(status: .ok), nil)
        }
        let base = URL(string: "https://api.test")!
        _ = try await NativeHeaders(access: { nil }).intercept(incoming, body: nil, baseURL: base, operationID: "t", next: next)
        XCTAssertNil(seen.value?.headerFields[.authorization], "an unauthenticated call must not inherit a stale bearer")
        XCTAssertNil(seen.value?.headerFields[.cookie])
        XCTAssertNil(seen.value?.headerFields[HTTPField.Name("Origin")!])
        _ = try await NativeHeaders(access: { "fresh" }).intercept(incoming, body: nil, baseURL: base, operationID: "t", next: next)
        XCTAssertEqual(seen.value?.headerFields[.authorization], "Bearer fresh")
    }
    func testMiddlewareFailsTheCallWhenTheSessionCannotProvideAToken() async {
        let request = HTTPRequest(method: .get, scheme: "https", authority: "api.test", path: "/p")
        let sent = SeenRequest()
        do {
            _ = try await NativeHeaders(access: { throw AccountError.signedOut }).intercept(
                request, body: nil, baseURL: URL(string: "https://api.test")!, operationID: "t") { request, _, _ in
                sent.set(request)
                return (HTTPResponse(status: .ok), nil)
            }
            XCTFail("request sent without credentials")
        } catch { XCTAssertEqual(error as? AccountError, .signedOut) }
        XCTAssertNil(sent.value, "nothing may reach the network when the bearer cannot be resolved")
    }
}

private final class SeenRequest: @unchecked Sendable {
    private let lock = NSLock()
    private var request: HTTPRequest?
    func set(_ value: HTTPRequest) { lock.withLock { request = value } }
    var value: HTTPRequest? { lock.withLock { request } }
}
