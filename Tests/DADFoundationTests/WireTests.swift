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

@MainActor final class NativeHeadersBodyRulesTests: XCTestCase {
    private func run(status: HTTPResponse.Status, contentType: String?, body: String?, maxBodyBytes: Int = 1_048_576,
                     retryAfter: String? = nil) async throws -> (HTTPResponse, String?) {
        var fields = HTTPFields()
        if let contentType { fields[.contentType] = contentType }
        if let retryAfter { fields[.retryAfter] = retryAfter }
        let sent = fields
        let (response, reply) = try await NativeHeaders(access: { nil }, maxBodyBytes: maxBodyBytes).intercept(
            HTTPRequest(method: .get, scheme: "https", authority: "api.test", path: "/p"), body: nil,
            baseURL: URL(string: "https://api.test")!, operationID: "t") { _, _, _ in
            (HTTPResponse(status: status, headerFields: sent), body.map { HTTPBody($0) })
        }
        var text: String?
        if let reply { text = try await String(collecting: reply, upTo: 1_048_576) }
        return (response, text)
    }

    func testAThrottleWithoutAProblemBodyIsGivenTheDocumentedOneAndKeepsRetryAfter() async throws {
        let undocumented: [(String?, String?)] = [(nil, nil), ("text/plain", "Too Many Requests"), ("application/json", "{}"),
                                                  ("application/json", "[1]"), ("application/json", #"{"detail":5}"#),
                                                  ("text/html", #"{"detail":"x"}"#), ("application/json", "not json")]
        for (type, body) in undocumented {
            let (response, text) = try await run(status: .tooManyRequests, contentType: type, body: body, retryAfter: "17")
            XCTAssertEqual(response.headerFields[.contentType], "application/json", "\(String(describing: type)) \(String(describing: body))")
            XCTAssertEqual(text, #"{"detail":"Too many requests"}"#)
            XCTAssertEqual(response.headerFields[.retryAfter], "17", "the server's wait must reach the model untouched")
        }
    }

    func testADocumentedThrottleBodyIsPassedThroughUnchanged() async throws {
        let problem = #"{"detail":"Slow down","code":"RATE"}"#
        let (response, text) = try await run(status: .tooManyRequests, contentType: "application/problem+json; charset=utf-8", body: problem)
        XCTAssertEqual(text, problem)
        XCTAssertEqual(response.headerFields[.contentType], "application/problem+json; charset=utf-8")
    }

    func testOnlyThrottlesAreRewrittenAndBodylessRepliesStayBodyless() async throws {
        let (error, errorText) = try await run(status: .internalServerError, contentType: "text/plain", body: "boom")
        XCTAssertEqual(errorText, "boom")
        XCTAssertEqual(error.status, .internalServerError)
        let (empty, emptyText) = try await run(status: .noContent, contentType: nil, body: nil)
        XCTAssertNil(emptyText)
        XCTAssertEqual(empty.status, .noContent)
    }

    func testTheBodyBoundIsInclusiveAndAppliesToEveryStatus() async throws {
        let (_, atLimit) = try await run(status: .ok, contentType: "application/json", body: String(repeating: "x", count: 16), maxBodyBytes: 16)
        XCTAssertEqual(atLimit?.count, 16)
        for status in [HTTPResponse.Status.ok, .internalServerError, .tooManyRequests] {
            do {
                _ = try await run(status: status, contentType: "application/json", body: String(repeating: "x", count: 17), maxBodyBytes: 16)
                XCTFail("\(status) body over the bound was accepted")
            } catch { XCTAssertFalse(error.isCancellation, "\(status): \(error)") }
        }
    }
}

final class LenientDateTranscoderTests: XCTestCase {
    func testWholeAndFractionalSecondsBothDecodeToTheSameInstant() throws {
        let transcoder = LenientDateTranscoder()
        let whole = try transcoder.decode("2026-11-07T15:00:00Z")
        XCTAssertEqual(whole.timeIntervalSince1970, 1_794_063_600)
        XCTAssertEqual(try transcoder.decode("2026-11-07T15:00:00.500Z").timeIntervalSince1970, 1_794_063_600.5, accuracy: 0.001)
        XCTAssertEqual(try transcoder.decode("2026-11-07T10:00:00-05:00"), whole, "an offset names the same instant")
    }

    func testGarbageIsADecodingErrorNotADate() {
        for text in ["", "yesterday", "2026-11-07", "2026-13-40T99:00:00Z", "1794063600"] {
            XCTAssertThrowsError(try LenientDateTranscoder().decode(text), text) { XCTAssertTrue($0 is DecodingError, "\($0)") }
        }
    }

    func testEncodingIsThePlainFormTheServerAccepts() throws {
        let text = try LenientDateTranscoder().encode(Date(timeIntervalSince1970: 1_794_063_600.75))
        XCTAssertEqual(text, "2026-11-07T15:00:00Z")
        XCTAssertEqual(try LenientDateTranscoder().decode(text).timeIntervalSince1970, 1_794_063_600)
    }
}

final class WireAPIStatusMappingTests: XCTestCase {
    private typealias Call = @Sendable (WireAPI) async throws -> Void
    private let operations: [(name: String, path: String, call: Call)] = [
        ("profile", "/donor/me/profile", { _ = try await $0.profile(access: "A") }),
        ("refresh", "/donor/refresh", { _ = try await $0.refresh(token: "R") }),
        ("claim", "/donor/claim", { _ = try await $0.claim(token: String(repeating: "a", count: 32)) }),
        ("logout", "/donor/logout", { try await $0.logout(access: "A") }),
    ]

    func testEveryAccountCallMapsEveryStatusAndNeverInventsASession() async {
        let statuses: [(HTTPResponse.Status, String)] = [(.unauthorized, "{}"), (.forbidden, "{}"), (.notFound, "{}"), (.unprocessableContent, "{}"),
                                                         (.tooManyRequests, ""), (.tooManyRequests, "{}"), (.internalServerError, "{}"),
                                                         (.serviceUnavailable, "{}")]
        for operation in operations {
            for (status, body) in statuses {
                let transport = ScriptedTransport { _, _ in (status, body) }
                let api = WireAPI(origin: testOrigin, transport: transport)
                let expected: AccountError = status == .unauthorized && operation.name != "logout" ? .signedOut : .unavailable
                do { try await operation.call(api); XCTFail("\(operation.name) \(status) did not throw") }
                catch { XCTAssertEqual(error as? AccountError, expected, "\(operation.name) \(status) body=\(body.debugDescription)") }
                XCTAssertEqual(transport.calls(to: operation.path).count, 1, "\(operation.name) is never retried by the transport layer")
            }
        }
    }

    func testRefreshAndClaimSendNoBearerAndOnlyTheirOwnSecretInTheBody() async throws {
        let transport = ScriptedTransport { _, _ in (.ok, nativeSessionJSON) }
        let api = WireAPI(origin: testOrigin, transport: transport)
        let refreshed = try await api.refresh(token: "REFRESH-SECRET")
        let claimed = try await api.claim(token: String(repeating: "c", count: 32))
        XCTAssertEqual(refreshed.access, "A1")
        XCTAssertEqual(claimed.refresh, "R1")
        let (refresh, claim) = (transport.seen[0], transport.seen[1])
        XCTAssertNil(refresh.request.headerFields[.authorization])
        XCTAssertNil(claim.request.headerFields[.authorization])
        let refreshBody = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(refresh.body.utf8)) as? [String: String])
        XCTAssertEqual(refreshBody, ["refresh_token": "REFRESH-SECRET"])
        let claimBody = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(claim.body.utf8)) as? [String: String])
        XCTAssertEqual(claimBody, ["token": String(repeating: "c", count: 32), "platform": "IOS"])
    }

    func testLogoutSendsTheGivenBearerOnly() async throws {
        let transport = ScriptedTransport { _, _ in (.ok, #"{"signed_out":true}"#) }
        try await WireAPI(origin: testOrigin, transport: transport).logout(access: "REVOKE-ME")
        XCTAssertEqual(transport.seen.first?.request.headerFields[.authorization], "Bearer REVOKE-ME")
        XCTAssertEqual(transport.seen.first?.request.method, .post)
    }

    func testCredentialsExpireAccordingToTheServersLifetime() async throws {
        let transport = ScriptedTransport { _, _ in (.ok, nativeSessionJSON) }
        let before = Date()
        let credentials = try await WireAPI(origin: testOrigin, transport: transport).refresh(token: "R")
        XCTAssertEqual(credentials.expiresAt.timeIntervalSince(before), 900, accuracy: 5)
    }
}
