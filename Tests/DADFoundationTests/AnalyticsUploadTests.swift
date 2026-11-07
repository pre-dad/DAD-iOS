import Foundation
import HTTPTypes
import OpenAPIRuntime
import XCTest
@testable import DADFoundation

final class AnalyticsUploadTests: XCTestCase {
    private func observed(_ method: HTTPRequest.Method, _ path: String, request: String? = nil, response: String? = nil) -> [AnalyticsEvent] {
        observedEvents(method: method, path: path, requestBody: { request.map { Data($0.utf8) } }, responseBody: { response.map { Data($0.utf8) } })
    }

    func testSuccessfulCallsMapToTheEventsTheWebsiteCounts() {
        XCTAssertEqual(observed(.post, "/donor/signup"), [.signupStarted])
        XCTAssertEqual(observed(.post, "/donor/claim"), [.signupCompleted])
        XCTAssertEqual(observed(.post, "/donor/me/recurring/checkout"), [.giftStarted])
        XCTAssertEqual(observed(.post, "/donor/me/delete"), [.accountDeleted])
        XCTAssertEqual(observed(.post, "/donor/me/recurring/cancel"), [.giftCancelled])
        XCTAssertEqual(observed(.post, "/donor/me/recurring/amount"), [.amountChanged])
        XCTAssertEqual(observed(.post, "/donor/me/team"), [.teamJoined])
        XCTAssertEqual(observed(.post, "/donor/me/events/check-in"), [.eventCheckedIn])
        XCTAssertEqual(observed(.get, "/donor/me/events/e1"), [.eventViewed])
        XCTAssertEqual(observed(.get, "/events/e1"), [.eventViewed])
        XCTAssertEqual(observed(.get, "/donor/partner/report.pdf"), [.partnerReportExported])
        XCTAssertEqual(observed(.post, "/donor/me/events/e1/reserve", response: #"{"status":"RESERVED"}"#), [.eventReserved])
        XCTAssertEqual(observed(.post, "/donor/me/events/e1/reserve", response: #"{"status":"WAITLISTED"}"#), [.eventWaitlisted])
        XCTAssertEqual(observed(.post, "/donor/me/events/e1/reserve", response: "not json"), [])
        XCTAssertEqual(observed(.post, "/donor/me/preferences", request: #"{"rankings_opted_out":true,"volunteer":true}"#),
                       [.rankingsToggled, .volunteerOptedIn])
        XCTAssertEqual(observed(.post, "/donor/me/preferences", request: #"{"rankings_opted_out":false,"volunteer":false}"#), [.rankingsToggled])
        for (method, path) in [(HTTPRequest.Method.get, "/donor/me/events"), (.get, "/donor/me/events/e1/calendar.ics"),
                               (.post, "/donor/me/profile"), (.post, "/analytics/events")] {
            XCTAssertEqual(observed(method, path), [], path)
        }
    }

    private final class Seen: @unchecked Sendable {
        private let lock = NSLock()
        private var events: [AnalyticsEvent] = []
        func add(_ event: AnalyticsEvent) { lock.withLock { events.append(event) } }
        var all: [AnalyticsEvent] { lock.withLock { events } }
    }

    func testTheTransportReportsOnlySuccessfulCallsAndPassesBodiesThrough() async throws {
        let inner = ScriptedTransport { seen, _ in
            switch seen.request.path {
            case "/donor/me/events/e1/reserve": return (.ok, #"{"status":"WAITLISTED"}"#)
            case "/donor/me/preferences": return (.ok, profileJSON())
            default: return (.unprocessableContent, "{}")
            }
        }
        let observation = AnalyticsObservation()
        let seen = Seen()
        observation.install { seen.add($0) }
        let transport = ObservingTransport(inner: inner, observation: observation)
        func post(_ path: String, _ body: String) async throws -> String {
            let (_, reply) = try await transport.send(HTTPRequest(method: .post, scheme: "https", authority: "api.test", path: path),
                                                      body: HTTPBody(body), baseURL: testOrigin, operationID: "op")
            return try await String(collecting: reply!, upTo: 65_536)
        }
        let reserved = try await post("/donor/me/events/e1/reserve", "{}")
        _ = try await post("/donor/me/preferences", #"{"rankings_opted_out":false}"#)
        _ = try await post("/donor/signup", "{}")
        XCTAssertEqual(reserved, #"{"status":"WAITLISTED"}"#)
        XCTAssertEqual(inner.calls(to: "/donor/me/preferences").first?.body, #"{"rankings_opted_out":false}"#)
        XCTAssertEqual(seen.all, [.eventWaitlisted, .rankingsToggled])
    }

    func testTheWireBatchIsTheIngestShapeAndAttributedWhenSignedIn() async throws {
        let transport = ScriptedTransport { _, _ in (.ok, #"{"accepted":1}"#) }
        let id = UUID(uuidString: "11111111-1111-4111-8111-111111111111")!
        let journey = UUID(uuidString: "22222222-2222-4222-8222-222222222222")!
        let record = try AnalyticsRecord(.inviteShared, occurredAt: Date(timeIntervalSince1970: 1_793_527_200),
                                         properties: ["channel": "copy"], id: id, journeyID: journey)
        try await WireAnalytics(origin: testOrigin, transport: transport, access: { "A1" }).send(AnalyticsBatch([record]))
        try await WireAnalytics(origin: testOrigin, transport: transport, access: { nil }).send(AnalyticsBatch([try AnalyticsRecord(.appOpened)]))
        let (signedIn, anonymous) = (transport.seen[0], transport.seen[1])
        XCTAssertEqual(signedIn.request.path, "/analytics/events")
        XCTAssertEqual(signedIn.request.headerFields[.authorization], "Bearer A1")
        XCTAssertEqual(signedIn.request.headerFields[HTTPField.Name("X-DAD-Platform")!], "IOS")
        let body = try JSONSerialization.jsonObject(with: Data(signedIn.body.utf8)) as? [String: Any]
        let event = try XCTUnwrap((body?["events"] as? [[String: Any]])?.first)
        XCTAssertEqual(event["id"] as? String, "11111111-1111-4111-8111-111111111111")
        XCTAssertEqual(event["journey_id"] as? String, "22222222-2222-4222-8222-222222222222")
        XCTAssertEqual(event["name"] as? String, "invite_shared")
        XCTAssertEqual(event["occurred_at"] as? String, "2026-11-01T10:00:00Z")
        XCTAssertEqual(event["properties"] as? [String: String], ["channel": "copy"])
        XCTAssertNil(anonymous.request.headerFields[.authorization])
        XCTAssertFalse(anonymous.body.contains("properties"))
    }

    func testARejectedBatchIsInvalidInputAndIsNotRetried() async throws {
        let transport = ScriptedTransport { _, _ in (.unprocessableContent, "{}") }
        let wire = WireAnalytics(origin: testOrigin, transport: transport, access: { nil })
        do { try await wire.send(AnalyticsBatch([try AnalyticsRecord(.appOpened)])); XCTFail("expected a rejection") }
        catch { XCTAssertEqual(error as? AccountError, .invalidInput) }
        let recorder = AnalyticsRecorder(sink: wire)
        try await recorder.record(.appOpened)
        try await recorder.flush()
        let pending = await recorder.pending
        XCTAssertEqual(pending, 0)
    }

    @MainActor
    func testNothingIsRecordedUntilTheDonorAllowsItAndDecliningDropsTheBuffer() async throws {
        let transport = ScriptedTransport { _, _ in (.serviceUnavailable, "{}") }
        let consent = MemoryAnalyticsConsent()
        let analytics = AnalyticsController(consent: consent, sink: WireAnalytics(origin: testOrigin, transport: transport, access: { nil }))
        analytics.emit(.roleSelected)   // without consent the call returns before any task is spawned
        XCTAssertTrue(transport.seen.isEmpty)
        let before = await analytics.pending
        XCTAssertEqual(before, 0, "nothing is buffered until the donor allows it")
        XCTAssertNil(analytics.choice)
        analytics.choose(true)
        XCTAssertEqual(consent.choice, true)
        for _ in 0..<200 where transport.calls(to: "/analytics/events").isEmpty { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertEqual(transport.calls(to: "/analytics/events").count, 1)
        analytics.choose(false)
        for _ in 0..<200 where await analytics.pending > 0 { try await Task.sleep(for: .milliseconds(10)) }
        let left = await analytics.pending
        XCTAssertEqual(left, 0)
        analytics.emit(.irlCodeShown)   // declined: dropped synchronously, nothing queued to send
        let after = await analytics.pending
        XCTAssertEqual(after, 0)
        XCTAssertEqual(transport.calls(to: "/analytics/events").count, 1)
    }

    func testTheChoiceIsRememberedInDefaults() throws {
        let defaults = try XCTUnwrap(UserDefaults(suiteName: "analytics-consent-test"))
        defaults.removePersistentDomain(forName: "analytics-consent-test")
        let consent = DefaultsAnalyticsConsent(defaults: defaults)
        XCTAssertNil(consent.choice)
        consent.choice = false
        XCTAssertEqual(DefaultsAnalyticsConsent(defaults: defaults).choice, false)
        consent.choice = true
        XCTAssertEqual(DefaultsAnalyticsConsent(defaults: defaults).choice, true)
    }
}

final class PushTests: XCTestCase {
    func testTheDonorRegistersAnIOSTokenWithItsEnvironment() async throws {
        let transport = ScriptedTransport { _, _ in (.ok, #"{"registered":true,"platform":"IOS","environment":"SANDBOX"}"#) }
        let session = try AccountSession(api: WireAPI(origin: testOrigin, transport: transport),
                                         store: MemoryStore(Credentials(access: "tok", refresh: "ref", expiresAt: .distantFuture)))
        let push = WireDonorPush(product: ProductClient(origin: testOrigin, transport: transport, session: session))
        try await push.register(token: pushTokenHex(Data([0x0a, 0xff, 0x10])), environment: .sandbox)
        try await push.unregister()
        let register = try XCTUnwrap(transport.calls(to: "/donor/me/push-device").first)
        let body = try JSONSerialization.jsonObject(with: Data(register.body.utf8)) as? [String: String]
        XCTAssertEqual(body, ["platform": "IOS", "token": "0aff10", "environment": "SANDBOX"])
        XCTAssertEqual(register.request.headerFields[.authorization], "Bearer tok")
        XCTAssertEqual(transport.calls(to: "/donor/me/push-device/unregister").count, 1)
    }

    func testOnlyAWellFormedCategoryIsATap() {
        XCTAssertEqual(PushTap(userInfo: ["aps": [:], "category": "STREAK_AT_RISK", "path": "/account/gifts"]),
                       PushTap(category: "STREAK_AT_RISK", path: "/account/gifts"))
        XCTAssertNil(PushTap(userInfo: ["aps": [:], "path": "/account/gifts"]))
        XCTAssertNil(PushTap(category: "streak; drop", path: nil))
        XCTAssertNil(PushTap(category: "STREAK_AT_RISK", path: "/" + String(repeating: "a", count: 300))?.path)
    }
}
