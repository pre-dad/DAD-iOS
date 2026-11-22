import XCTest
import HTTPTypes
import OpenAPIRuntime
@testable import DADFoundation

/// Contract 2.11: the app submits a partner application itself (`applyWithReceipt`), keeps the receipt it chose,
/// and reads the status back with it.

/// Replies with a fixed status, optional headers and an optional JSON body, and records what it was sent.
private final class HeaderTransport: ClientTransport, @unchecked Sendable {
    struct Seen { let request: HTTPRequest; let body: String }
    private let lock = NSLock()
    private var log: [Seen] = []
    private let reply: @Sendable (Int) throws -> (HTTPResponse.Status, HTTPFields, String?)
    private var sendHook: @Sendable () -> Void = {}
    var onSend: @Sendable () -> Void {
        get { lock.withLock { sendHook } }
        set { lock.withLock { sendHook = newValue } }
    }
    init(_ reply: @escaping @Sendable (Int) throws -> (HTTPResponse.Status, HTTPFields, String?)) { self.reply = reply }
    var seen: [Seen] { lock.withLock { log } }

    func send(_ request: HTTPRequest, body: HTTPBody?, baseURL: URL, operationID: String) async throws -> (HTTPResponse, HTTPBody?) {
        var text = ""
        if let body { text = try await String(collecting: body, upTo: 8192) }
        let index = lock.withLock { log.append(Seen(request: request, body: text)); return log.count - 1 }
        onSend()
        var (status, fields, json) = try reply(index)
        if json != nil { fields[.contentType] = "application/json" }
        return (HTTPResponse(status: status, headerFields: fields), json.map { HTTPBody($0) })
    }
}

private let sample = PartnerApplication(organization: "Acme Corp", website: "https://acme.example", type: .nonprofit, contactName: "Ada Admin",
                                        title: "Director", workEmail: "ada@acme.example", phone: "555-0100", workforceSize: 240)

final class WirePartnerApplicationTests: XCTestCase {
    private func attempt(_ receipt: String = String(repeating: "r", count: 43)) -> PartnerApplicationAttempt {
        PartnerApplicationAttempt(application: sample, idempotencyKey: "4c3b8f0e-7a1d-4e55-9f2a-0b1c2d3e4f50", receipt: receipt)
    }

    private func store() -> MemoryStore { MemoryStore(nil) }

    func testSendsTheNativeRequestAndKeepsTheReceiptBeforeAndAfter() async throws {
        let receipts = store()
        let heldWhenSent = LockedBox<String?>(nil)
        let transport = HeaderTransport { _ in (.ok, HTTPFields(), #"{"received":true}"#) }
        transport.onSend = { heldWhenSent.set((try? receipts.load())?.access) }
        let wire = WirePartnerApplication(origin: testOrigin, transport: transport, receipt: receipts)
        try await wire.submit(attempt())

        XCTAssertEqual(heldWhenSent.get(), String(repeating: "r", count: 43), "the receipt is in secure storage before the request leaves")
        XCTAssertEqual(try receipts.load()?.access, String(repeating: "r", count: 43), "a success keeps it for the status read")
        let call = try XCTUnwrap(transport.seen.first)
        XCTAssertEqual(call.request.method, .post)
        XCTAssertEqual(call.request.path, "/donor/partner/applications")
        XCTAssertEqual(call.request.headerFields[nativeClientHeader], "native")
        XCTAssertEqual(call.request.headerFields[HTTPField.Name("Idempotency-Key")!], "4c3b8f0e-7a1d-4e55-9f2a-0b1c2d3e4f50")
        XCTAssertNil(call.request.headerFields[.origin])
        XCTAssertNil(call.request.headerFields[.cookie])
        XCTAssertNil(call.request.headerFields[.authorization], "the receipt travels in the body, not as a bearer, on submission")
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(call.body.utf8)) as? [String: Any])
        XCTAssertEqual(json["receipt"] as? String, String(repeating: "r", count: 43))
        let application = try XCTUnwrap(json["application"] as? [String: Any])
        XCTAssertEqual(application["organization"] as? String, "Acme Corp")
        XCTAssertEqual(application["type"] as? String, "Nonprofit")
        XCTAssertEqual(application["work_email"] as? String, "ada@acme.example")
        XCTAssertEqual(application["workforce_size"] as? Int, 240)
        XCTAssertEqual(Set(application.keys), ["organization", "website", "type", "contact_name", "title", "work_email", "phone", "workforce_size"])
    }

    func testDefinitiveRefusalsMapAndForgetTheReceipt() async throws {
        for (status, expected): (HTTPResponse.Status, ApplicationSubmitError) in [(.unprocessableContent, .invalid), (.conflict, .conflict), (.forbidden, .forbidden)] {
            let receipts = store()
            let wire = WirePartnerApplication(origin: testOrigin, transport: HeaderTransport { _ in (status, HTTPFields(), #"{"detail":"x"}"#) }, receipt: receipts)
            do { try await wire.submit(attempt()); XCTFail("\(status) should throw") }
            catch let error as ApplicationSubmitError { XCTAssertEqual(error, expected) }
            XCTAssertNil(try receipts.load(), "a refused application leaves no receipt behind (\(status.code))")
        }
    }

    func testThrottleReadsRetryAfterWithOrWithoutABodyAndKeepsTheReceipt() async throws {
        let fields: HTTPFields = {
            var fields = HTTPFields()
            fields[.retryAfter] = "30"
            return fields
        }()
        for body in [#"{"detail":"slow down"}"#, nil] as [String?] {
            let receipts = store()
            let wire = WirePartnerApplication(origin: testOrigin, transport: HeaderTransport { _ in (.tooManyRequests, fields, body) }, receipt: receipts)
            do { try await wire.submit(attempt()); XCTFail("429 should throw") }
            catch let error as ApplicationSubmitError { XCTAssertEqual(error, .rateLimited(retryAfter: 30), "body: \(body ?? "empty")") }
            XCTAssertNotNil(try receipts.load(), "the server may not have seen it, and a retry must reuse the receipt")
        }
        let wire = WirePartnerApplication(origin: testOrigin, transport: HeaderTransport { _ in (.tooManyRequests, HTTPFields(), "{}") }, receipt: store())
        do { try await wire.submit(attempt()); XCTFail("expected the call to throw") }
        catch let error as ApplicationSubmitError { XCTAssertEqual(error, .rateLimited(retryAfter: nil), "a missing header is not guessed") }
    }

    func testOutagesAndLostConnectionsKeepTheReceipt() async throws {
        let receipts = store()
        let down = WirePartnerApplication(origin: testOrigin, transport: HeaderTransport { _ in (.serviceUnavailable, HTTPFields(), #"{"detail":"x"}"#) }, receipt: receipts)
        do { try await down.submit(attempt()); XCTFail("expected the call to throw") }
        catch let error as ApplicationSubmitError { XCTAssertEqual(error, .unavailable) }
        XCTAssertNotNil(try receipts.load())

        let offline = WirePartnerApplication(origin: testOrigin, transport: HeaderTransport { _ in throw URLError(.notConnectedToInternet) }, receipt: receipts)
        do { try await offline.submit(attempt()); XCTFail("expected the call to throw") }
        catch { XCTAssertFalse(error is ApplicationSubmitError) }
        XCTAssertNotNil(try receipts.load())
    }

    func testReceiptsAreFortyThreeBase64urlCharactersAndNeverRepeat() {
        let receipts = (0..<50).map { _ in makeApplicationReceipt() }
        XCTAssertEqual(Set(receipts).count, 50)
        for receipt in receipts {
            XCTAssertNotNil(receipt.range(of: "^[A-Za-z0-9_-]{43}$", options: .regularExpression), receipt)
        }
        let keys = (0..<5).map { _ in PartnerApplicationAttempt.make(sample).idempotencyKey }
        for key in keys { XCTAssertNotNil(UUID(uuidString: key)); XCTAssertEqual(key, key.lowercased()) }
    }

    func testSubmittedReceiptReadsBackAsThePendingStatus() async throws {
        let services = try StubBackend.make()
        try await services.applicationSubmit.submit(.make(sample))
        let info = try await services.applicationStatus.status()
        XCTAssertEqual(info, ApplicationStatusInfo(organization: "Acme Corp", state: .pending))
    }

    func testStubScenariosAnswerLikeTheServer() async throws {
        let invalid = try StubBackend.make(applicationSubmit: .invalid)
        do { try await invalid.applicationSubmit.submit(.make(sample)); XCTFail("expected the call to throw") }
        catch let error as ApplicationSubmitError { XCTAssertEqual(error, .invalid) }
        let none = try await invalid.applicationStatus.status()
        XCTAssertNil(none)

        let throttled = try StubBackend.make(applicationSubmit: .throttled)
        do { try await throttled.applicationSubmit.submit(.make(sample)); XCTFail("expected the call to throw") }
        catch let error as ApplicationSubmitError { XCTAssertEqual(error, .rateLimited(retryAfter: 30)) }
    }
}

@MainActor
final class PartnerApplicationModelTests: XCTestCase {
    private final class FakeService: PartnerApplicationService, @unchecked Sendable {
        private let lock = NSLock()
        private var sent: [PartnerApplicationAttempt] = []
        var results: [Result<Void, Error>] = []
        var attempts: [PartnerApplicationAttempt] { lock.withLock { sent } }
        func submit(_ attempt: PartnerApplicationAttempt) async throws {
            let result: Result<Void, Error> = lock.withLock {
                sent.append(attempt)
                return results.isEmpty ? .success(()) : results.removeFirst()
            }
            try result.get()
        }
    }

    private let counter = LockedBox<Int>(0)

    private func model(_ service: FakeService) -> PartnerApplicationModel {
        let counter = counter
        let model = PartnerApplicationModel(service: service) { application in
            let n = counter.get() + 1
            counter.set(n)
            return PartnerApplicationAttempt(application: application, idempotencyKey: "key-\(n)", receipt: "receipt-\(n)")
        }
        model.organization = " Acme Corp "; model.website = "acme.example"; model.type = .nonprofit; model.contactName = "Ada Admin"
        model.title = "Director"; model.workEmail = "ada@acme.example"; model.phone = "555-0100"; model.workforce = "240"
        return model
    }

    func testTheFormNeedsEveryFieldAndNormalizesWhatItSends() {
        let m = model(FakeService())
        XCTAssertEqual(m.application, PartnerApplication(organization: "Acme Corp", website: "https://acme.example", type: .nonprofit,
                                                         contactName: "Ada Admin", title: "Director", workEmail: "ada@acme.example",
                                                         phone: "555-0100", workforceSize: 240))
        for mutate: (PartnerApplicationModel) -> Void in [{ $0.organization = "  " }, { $0.contactName = "" }, { $0.title = "" }, { $0.phone = "" },
                                                          { $0.workEmail = "not-an-email" }, { $0.workforce = "many" }, { $0.workforce = "-3" },
                                                          { $0.website = "" }, { $0.website = "http://acme.example" }, { $0.website = "acme" },
                                                          { $0.organization = String(repeating: "a", count: 201) }] {
            let broken = model(FakeService())
            mutate(broken)
            XCTAssertNil(broken.application)
            XCTAssertFalse(broken.canSubmit)
        }
    }

    func testSuccessIsSubmittedAndSendsTheFormOnce() async {
        let service = FakeService()
        let m = model(service)
        await m.submit()
        XCTAssertEqual(m.phase, .submitted)
        XCTAssertFalse(m.isLocked)
        XCTAssertEqual(service.attempts.count, 1)
        XCTAssertEqual(service.attempts[0].application.website, "https://acme.example")
        await m.submit()
        XCTAssertEqual(service.attempts.count, 1, "a submitted form is not sent again")
    }

    func testAnUnconfirmedAttemptLocksTheFormAndRetriesWithTheSameKeyAndReceipt() async {
        let service = FakeService()
        service.results = [.failure(ApplicationSubmitError.unavailable), .failure(URLError(.timedOut)), .success(())]
        let m = model(service)
        await m.submit()
        guard case .failed(let message) = m.phase else { return XCTFail("expected the call to throw") }
        XCTAssertTrue(message.contains("retry"))
        XCTAssertTrue(m.isLocked)
        m.organization = "Changed after the fact"
        await m.submit()
        XCTAssertTrue(m.isLocked)
        await m.submit()
        XCTAssertEqual(m.phase, .submitted)
        XCTAssertEqual(Set(service.attempts.map(\.idempotencyKey)), ["key-1"])
        XCTAssertEqual(Set(service.attempts.map(\.receipt)), ["receipt-1"])
        XCTAssertEqual(Set(service.attempts.map(\.application.organization)), ["Acme Corp"], "the frozen form is what is resent")
    }

    func testARefusalUnlocksAndTheNextTryGetsANewKeyAndReceipt() async {
        let service = FakeService()
        service.results = [.failure(ApplicationSubmitError.invalid), .failure(ApplicationSubmitError.conflict), .success(())]
        let m = model(service)
        await m.submit()
        guard case .failed(let invalid) = m.phase else { return XCTFail("expected the call to throw") }
        XCTAssertTrue(invalid.contains("Check each field"))
        XCTAssertFalse(m.isLocked)
        await m.submit()
        guard case .failed = m.phase else { return XCTFail("expected the call to throw") }
        XCTAssertFalse(m.isLocked)
        await m.submit()
        XCTAssertEqual(m.phase, .submitted)
        XCTAssertEqual(service.attempts.map(\.idempotencyKey), ["key-1", "key-2", "key-3"])
        XCTAssertEqual(service.attempts.map(\.receipt), ["receipt-1", "receipt-2", "receipt-3"])
    }

    func testThrottlingNamesTheWaitAndKeepsTheAttempt() async {
        let service = FakeService()
        service.results = [.failure(ApplicationSubmitError.rateLimited(retryAfter: 30)), .failure(ApplicationSubmitError.rateLimited(retryAfter: 120)),
                           .failure(ApplicationSubmitError.rateLimited(retryAfter: nil))]
        let m = model(service)
        await m.submit()
        XCTAssertEqual(m.phase, .failed("Too many attempts. Please wait 30 seconds and try again."))
        XCTAssertTrue(m.isLocked)
        await m.submit()
        XCTAssertEqual(m.phase, .failed("Too many attempts. Please wait 2 minutes and try again."))
        await m.submit()
        XCTAssertEqual(m.phase, .failed(AccountError.rateLimited.userMessage))
        XCTAssertEqual(Set(service.attempts.map(\.idempotencyKey)), ["key-1"])
    }

    func testForbiddenPointsToTheWebsiteAndCancellationChangesNothing() async {
        let service = FakeService()
        service.results = [.failure(ApplicationSubmitError.forbidden), .failure(CancellationError())]
        let m = model(service)
        await m.submit()
        guard case .failed(let message) = m.phase else { return XCTFail("expected the call to throw") }
        XCTAssertTrue(message.contains("website"))
        XCTAssertFalse(m.isLocked)
        await m.submit()
        XCTAssertEqual(m.phase, .editing)
        XCTAssertTrue(m.isLocked, "a cancelled send may have arrived, so a retry repeats it")
    }
}

final class ApplicationDecisionDiscardTests: XCTestCase {
    private final class Recording: ApplicationStatusService, @unchecked Sendable {
        var info: ApplicationStatusInfo?
        private(set) var discarded = 0
        func status() async throws -> ApplicationStatusInfo? { info }
        func discardReceipt() throws { discarded += 1 }
    }

    @MainActor
    func testADecidedApplicationIsShownThenForgottenAndOthersAreKept() async {
        for (state, forgotten): (ApplicationState, Bool) in [(.approved, true), (.rejected, true), (.pending, false), (.other("UNDER_REVIEW"), false)] {
            let service = Recording()
            service.info = ApplicationStatusInfo(organization: "Acme", state: state)
            let model = ApplicationStatusModel(service: service)
            await model.load()
            XCTAssertEqual(model.phase, .loaded(ApplicationStatusInfo(organization: "Acme", state: state)))
            XCTAssertEqual(service.discarded, forgotten ? 1 : 0, "\(state)")
        }
    }

    func testTheWireStatusDiscardsOnlyItsOwnReceipt() throws {
        let store = MemoryStore(Credentials(access: String(repeating: "r", count: 43), refresh: "", expiresAt: Date().addingTimeInterval(86_400)))
        let wire = WireApplicationStatus(origin: testOrigin, transport: ScriptedTransport { _, _ in (.ok, "{}") }, receipt: store)
        XCTAssertNotNil(try store.load())
        try wire.discardReceipt()
        XCTAssertNil(try store.load())
    }
}

/// Contract 2.11 documents the ingress 429 with a Problem body; an older edge still sends none.
final class IngressThrottleToleranceTests: XCTestCase {
    func testAnEmptyOrTextThrottleStillMapsAsTheDocumentedOne() async throws {
        for body in ["", "Too Many Requests", "{}"] {
            let store = MemoryStore(Credentials(access: "tok", refresh: "ref", expiresAt: .distantFuture))
            let transport = ScriptedTransport { seen, _ in seen.request.path == "/donor/me/dashboard" ? (.tooManyRequests, body) : (.ok, "{}") }
            let session = try AccountSession(api: WireAPI(origin: testOrigin, transport: transport), store: store)
            let dashboard = WireDashboard(product: ProductClient(origin: testOrigin, transport: transport, session: session))
            do { _ = try await dashboard.dashboard(); XCTFail("429 should throw") }
            catch { XCTAssertEqual(error as? AccountError, .rateLimited, "body: \(body.debugDescription)") }
            XCTAssertNotNil(try store.load(), "a throttle never ends the session")
        }
    }
}
