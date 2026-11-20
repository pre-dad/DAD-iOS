import XCTest
import HTTPTypes
@testable import DADFoundation

/// The partner portal on the wire. Every operation maps every status the same way (401 ends the
/// partner session, 403 role, 404, 409, 422, 429 with or without the Problem body), unknown enum values are
/// tolerated, the application receipt and the partner/donor sessions live apart, and cancellation keeps state.
final class WirePartnerStatusTests: XCTestCase {
    private typealias Call = @Sendable (WirePartner) async throws -> Void
    private let operations: [(name: String, path: String, call: Call)] = [
        ("overview", "/donor/partner/overview", { _ = try await $0.overview() }),
        ("initiatives", "/donor/partner/initiatives", { _ = try await $0.initiatives() }),
        ("spend", "/donor/partner/spend", { _ = try await $0.spend() }),
        ("people", "/donor/partner/our-people", { _ = try await $0.people() }),
        ("teams", "/donor/partner/teams", { _ = try await $0.teams() }),
        ("users", "/donor/partner/users", { _ = try await $0.users() }),
        ("invite", "/donor/partner/users", { try await $0.inviteUser(email: "b@x.com", name: "Bea", role: .viewer) }),
        ("remove", "/donor/partner/users/u2/remove", { try await $0.removeUser(id: "u2") }),
        ("profile", "/donor/partner/profile", { try await $0.saveProfile(organization: "Acme", description: "d") }),
        ("workforce", "/donor/partner/workforce", { try await $0.saveWorkforce(size: 10) }),
        ("saveLogo", "/donor/partner/logo", { try await $0.saveLogo(png: Data([1])) }),
        ("exports", "/donor/partner/exports", { _ = try await $0.exports() }),
        ("report", "/donor/partner/report.pdf", { _ = try await $0.report() }),
        ("retained", "/donor/partner/reports/r1/report.pdf", { _ = try await $0.retainedReport(id: "r1") }),
    ]

    func testReportLimitsKeepTheSessionAndExplainTheRefusal() async throws {
        for (status, code, expected) in [
            (HTTPResponse.Status.tooManyRequests, "PARTNER_REPORT_DAILY_LIMIT", PartnerReportLimit.daily),
            (.conflict, "PARTNER_REPORT_STORAGE_LIMIT", .storage),
            (.contentTooLarge, "PARTNER_REPORT_TOO_LARGE", .tooLarge),
        ] {
            let transport = ScriptedTransport { _, _ in (status, "{\"detail\":\"Limit reached\",\"code\":\"\(code)\"}") }
            let store = MemoryStore(nil)
            let session = try PartnerSession(store: store)
            try await session.install(token: "PB")
            let wire = WirePartner(origin: testOrigin, transport: transport, session: session)
            do { _ = try await wire.report(); XCTFail("report must throw") }
            catch { XCTAssertEqual(error as? PartnerReportLimit, expected) }
            XCTAssertNotNil(try store.load())
        }
    }

    private func expected(_ status: Int) -> AccountError {
        switch status {
        case 401: return .signedOut
        case 403: return .forbidden
        case 404: return .notFound
        case 409: return .conflict
        case 422: return .invalidInput
        case 429: return .rateLimited
        default: return .unavailable
        }
    }

    func testEveryOperationMapsEveryStatus() async throws {
        let statuses: [(Int, HTTPResponse.Status)] = [(401, .unauthorized), (403, .forbidden), (404, .notFound), (409, .conflict),
                                                      (422, .unprocessableContent), (429, .tooManyRequests), (503, .serviceUnavailable)]
        for operation in operations {
            for (code, status) in statuses {
                for emptyBody in [false, true] {
                    let transport = ScriptedTransport { _, _ in (status, emptyBody ? "" : "{}") }
                    let store = MemoryStore(nil)
                    let session = try PartnerSession(store: store)
                    try await session.install(token: "PB")
                    let wire = WirePartner(origin: testOrigin, transport: transport, session: session)
                    do {
                        try await operation.call(wire)
                        XCTFail("\(operation.name) \(code) did not throw")
                    } catch {
                        XCTAssertEqual(error as? AccountError, expected(code), "\(operation.name) \(code) emptyBody=\(emptyBody)")
                    }
                    let kept = try store.load() != nil
                    XCTAssertEqual(kept, code != 401, "\(operation.name): only a 401 ends the partner session")
                    XCTAssertEqual(transport.calls(to: operation.path).count, 1, "\(operation.name) hits \(operation.path) once")
                }
            }
        }
    }

    func testLogoNotFoundIsNoLogoNotAnError() async throws {
        let transport = ScriptedTransport { _, _ in (.notFound, "") }
        let session = try PartnerSession(store: MemoryStore(nil))
        try await session.install(token: "PB")
        let logo = try await WirePartner(origin: testOrigin, transport: transport, session: session).logo()
        XCTAssertNil(logo)
    }

    func testSignInLinkMapsStatusesWithAndWithoutABody() async throws {
        for (status, error): (HTTPResponse.Status, AccountError) in [(.forbidden, .forbidden), (.unprocessableContent, .invalidInput),
                                                                      (.tooManyRequests, .rateLimited), (.serviceUnavailable, .unavailable)] {
            for body in ["{}", ""] {
                let transport = ScriptedTransport { _, _ in (status, body) }
                let auth = WirePartnerAuth(origin: testOrigin, transport: transport, session: try PartnerSession(store: MemoryStore(nil)))
                do { try await auth.requestSignInLink(email: "a@x.com"); XCTFail("requestSignInLink must throw") }
                catch let thrown { XCTAssertEqual(thrown as? AccountError, error) }
                do { try await auth.accept(token: "t"); XCTFail("accept must throw") }
                catch let thrown { XCTAssertEqual(thrown as? AccountError, error) }
            }
        }
    }

    func testUnknownRoleAndStatusDecodeAndAnUnknownUnitIsHiddenInsteadOfFailingThePortal() async throws {
        let transport = ScriptedTransport { seen, _ in
            switch seen.request.path {
            case "/donor/partner/overview":
                return (.ok, #"{"user_id":"u9","organization":"Acme","description":"d","role":"OWNER","company_code":"AC","committed_minor":1,"deployed_minor":1,"deployed_percent":1,"people_reached":1,"employees_enrolled":null,"workforce_size":5,"enrolled_percent":null,"updated_at":null,"has_logo":false,"committed_verified":true,"deployed_verified":true,"people_reached_verified":true}"#)
            default:
                return (.ok, #"{"initiatives":[{"id":"i1","title":"T","summary":"S","status":"PAUSED","region":"R","county_count":1,"committed_minor":1,"deployed_minor":1,"metrics":[{"label":"L","value":3,"unit":"HOURS","verified_on":"2026-10-20"},{"label":"P","value":7,"unit":"PEOPLE","verified_on":"2026-10-20"}],"spend":[],"updated_at":"2026-10-28T10:00:00Z"}]}"#)
            }
        }
        let session = try PartnerSession(store: MemoryStore(nil))
        try await session.install(token: "PB")
        let wire = WirePartner(origin: testOrigin, transport: transport, session: session)
        let overview = try await wire.overview()
        XCTAssertEqual(overview.role, .viewer, "an unknown role is the least-privileged one")
        XCTAssertFalse(overview.role.canManageUsers)
        XCTAssertEqual(overview.userID, "u9")
        XCTAssertNil(overview.employeesEnrolled)
        let initiatives = try await wire.initiatives()
        XCTAssertEqual(initiatives.map(\.id), ["i1"])
        XCTAssertEqual(initiatives.first?.status, .active)
        XCTAssertEqual(initiatives.first?.metrics.map(\.label), ["P"], "a metric in a unit this build does not know is hidden, not shown as a people count")
    }

    func testRemoveUserSendsTheIdInThePathAndPartnerPushMapsRejection() async throws {
        let transport = ScriptedTransport { seen, _ in
            seen.request.path?.contains("push-device") == true ? (.unprocessableContent, "{}") : (.ok, #"{"removed":true}"#)
        }
        let session = try PartnerSession(store: MemoryStore(nil))
        try await session.install(token: "PB")
        let wire = WirePartner(origin: testOrigin, transport: transport, session: session)
        try await wire.removeUser(id: "abc")
        XCTAssertEqual(transport.calls(to: "/donor/partner/users/abc/remove").first?.request.method, .post)
        do { try await wire.registerPushDevice(token: "T", environment: .sandbox); XCTFail("registerPushDevice must throw") }
        catch { XCTAssertEqual(error as? AccountError, .invalidInput) }
    }

    func testCancelledOperationKeepsTheSessionAndThrowsCancellation() async throws {
        let gate = Gate()
        let transport = ScriptedTransport { _, _ in await gate.pass(); return (.ok, #"{"users":[]}"#) }
        let store = MemoryStore(nil)
        let session = try PartnerSession(store: store)
        try await session.install(token: "PB")
        let wire = WirePartner(origin: testOrigin, transport: transport, session: session)
        let call = Task { try await wire.users() }
        await gate.waitUntilEntered()
        call.cancel()
        await gate.release()
        do { _ = try await call.value; XCTFail("a cancelled read returned data") }
        catch { XCTAssertTrue(error.isCancellation) }
        XCTAssertNotNil(try store.load(), "cancellation never signs the partner out")
    }
}

final class WireApplicationStatusTests: XCTestCase {
    private func receiptStore() -> MemoryStore {
        MemoryStore(Credentials(access: String(repeating: "r", count: 43), refresh: "", expiresAt: Date().addingTimeInterval(86_400)))
    }

    func testReadsTheStatusWithTheReceiptAsTheBearer() async throws {
        for (raw, state): (String, ApplicationState) in [("PENDING", .pending), ("APPROVED", .approved), ("REJECTED", .rejected),
                                                         ("UNDER_REVIEW", .other("UNDER_REVIEW"))] {
            let transport = ScriptedTransport { _, _ in (.ok, #"{"organization":"Acme","status":"\#(raw)"}"#) }
            let wire = WireApplicationStatus(origin: testOrigin, transport: transport, receipt: receiptStore())
            let info = try await wire.status()
            XCTAssertEqual(info, ApplicationStatusInfo(organization: "Acme", state: state))
            let call = try XCTUnwrap(transport.calls(to: "/donor/partner/application-status").first)
            XCTAssertEqual(call.request.headerFields[.authorization], "Bearer " + String(repeating: "r", count: 43))
            XCTAssertEqual(call.request.headerFields[nativeClientHeader], "native")
            XCTAssertEqual(call.request.method, .get)
        }
    }

    func testNoReceiptMeansNoCallAndNothingToShow() async throws {
        let transport = ScriptedTransport { _, _ in (.ok, "{}") }
        let wire = WireApplicationStatus(origin: testOrigin, transport: transport, receipt: MemoryStore(nil))
        let info = try await wire.status()
        XCTAssertNil(info)
        XCTAssertFalse(wire.hasReceipt)
        XCTAssertTrue(transport.seen.isEmpty)
    }

    func testAnUnrecognizedReceiptIsForgotten() async throws {
        let store = receiptStore()
        let wire = WireApplicationStatus(origin: testOrigin, transport: ScriptedTransport { _, _ in (.unauthorized, "{}") }, receipt: store)
        let info = try await wire.status()
        XCTAssertNil(info)
        XCTAssertNil(try store.load())
    }

    func testThrottlingAndOutagesKeepTheReceipt() async throws {
        for (status, body, error): (HTTPResponse.Status, String, AccountError) in [(.tooManyRequests, "", .rateLimited), (.tooManyRequests, "{}", .rateLimited),
                                                                                    (.serviceUnavailable, "{}", .unavailable)] {
            let store = receiptStore()
            let wire = WireApplicationStatus(origin: testOrigin, transport: ScriptedTransport { _, _ in (status, body) }, receipt: store)
            do { _ = try await wire.status(); XCTFail("status must throw") }
            catch let thrown { XCTAssertEqual(thrown as? AccountError, error) }
            XCTAssertNotNil(try store.load())
        }
    }

    func testMessagesNeverClaimMoreThanTheServerSaid() {
        let pending = ApplicationStatusInfo(organization: "Acme", state: .pending)
        XCTAssertEqual(pending.title, "Application under review")
        XCTAssertTrue(pending.message.contains("being reviewed"))
        XCTAssertTrue(ApplicationStatusInfo(organization: "Acme", state: .approved).message.contains("sign-in link"))
        XCTAssertTrue(ApplicationStatusInfo(organization: "Acme", state: .rejected).message.contains("wasn’t approved"))
        let other = ApplicationStatusInfo(organization: "Acme", state: .other("X"))
        XCTAssertFalse(other.message.contains("approved"))
        XCTAssertFalse(other.message.contains("X"), "an unknown status string is not shown to the applicant")
    }
}

@MainActor
final class ApplicationStatusModelTests: XCTestCase {
    private final class FakeStatus: ApplicationStatusService, @unchecked Sendable {
        var result: Result<ApplicationStatusInfo?, Error> = .success(nil)
        func status() async throws -> ApplicationStatusInfo? { try result.get() }
    }

    func testLoadsNoneThenPendingThenKeepsItWhenARefreshFails() async {
        let fake = FakeStatus()
        let model = ApplicationStatusModel(service: fake)
        await model.load()
        XCTAssertEqual(model.phase, .none)
        let info = ApplicationStatusInfo(organization: "Acme", state: .pending)
        fake.result = .success(info)
        await model.load()
        XCTAssertEqual(model.phase, .loaded(info))
        fake.result = .failure(AccountError.unavailable)
        await model.load()
        XCTAssertEqual(model.phase, .loaded(info), "a failed refresh never replaces a status already read")
        fake.result = .failure(CancellationError())
        await model.load()
        XCTAssertEqual(model.phase, .loaded(info), "cancellation keeps the prior state")
    }

    func testFirstFailureIsExplainedAndRetryable() async {
        let fake = FakeStatus()
        fake.result = .failure(AccountError.rateLimited)
        let model = ApplicationStatusModel(service: fake)
        await model.load()
        XCTAssertEqual(model.phase, .failed(AccountError.rateLimited.userMessage))
        fake.result = .success(ApplicationStatusInfo(organization: "Acme", state: .approved))
        await model.load()
        XCTAssertEqual(model.phase, .loaded(ApplicationStatusInfo(organization: "Acme", state: .approved)))
    }
}

/// Partner and donor credentials are separate items, so ending one never touches the other.
final class PartnerDonorSessionSeparationTests: XCTestCase {
    func testPartnerSignOutAndExpiryLeaveTheDonorCredentialsAlone() async throws {
        let donorStore = MemoryStore(Credentials(access: "donor-access", refresh: "donor-refresh-xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx",
                                                 expiresAt: Date().addingTimeInterval(900)))
        let partnerStore = MemoryStore(nil)
        let partner = try PartnerSession(store: partnerStore)
        try await partner.install(token: "PB")
        _ = try await partner.end()
        XCTAssertNil(try partnerStore.load())
        XCTAssertEqual(try donorStore.load()?.access, "donor-access")
    }

    func testPartnerCallsNeverCarryTheDonorToken() async throws {
        let transport = ScriptedTransport { _, _ in (.ok, #"{"users":[]}"#) }
        let partner = try PartnerSession(store: MemoryStore(nil))
        try await partner.install(token: "PARTNER-ONLY")
        _ = try await WirePartner(origin: testOrigin, transport: transport, session: partner).users()
        let sent = try XCTUnwrap(transport.seen.first?.request.headerFields[.authorization])
        XCTAssertEqual(sent, "Bearer PARTNER-ONLY")
    }

    func testKeychainItemsForDonorPartnerAndApplicationAreDistinct() throws {
        let service = "org.dad.tests." + UUID().uuidString
        let donor = KeychainStore(service: service)
        let partner = KeychainStore(service: service, account: "partner-session")
        let receipt = KeychainStore(service: service, account: "partner-application-receipt")
        defer { for store in [donor, partner, receipt] { try? store.clear() } }
        do { try partner.save(Credentials(access: "p", refresh: "", expiresAt: Date().addingTimeInterval(60))) }
        catch { throw XCTSkip("Keychain is not available to this test host: \(error)") }
        XCTAssertNil(try donor.load())
        XCTAssertNil(try receipt.load())
        try donor.save(Credentials(access: "d", refresh: "dr", expiresAt: Date().addingTimeInterval(60)))
        try partner.clear()
        XCTAssertEqual(try donor.load()?.access, "d", "clearing the partner item leaves the donor item")
    }
}

@MainActor
final class PartnerPortalModelTests: XCTestCase {
    private actor Service: PartnerService {
        var role: PartnerRole = .admin
        var users = [PartnerUser(id: "u1", email: "a@x.com", name: "Ada", role: .admin),
                     PartnerUser(id: "u2", email: "v@x.com", name: "Val", role: .viewer)]
        var inviteError: Error?
        var gate: Gate?
        func setInviteError(_ error: Error?) { inviteError = error }
        func setGate(_ gate: Gate?) { self.gate = gate }
        func setRole(_ role: PartnerRole) { self.role = role }
        func overview() async throws -> PartnerOverview {
            PartnerOverview(organization: "Acme", description: "", userID: "u1", role: role, companyCode: "AC",
                            committed: VerifiedMoney(amountMinor: 1, verified: true), deployed: VerifiedMoney(amountMinor: 1, verified: false),
                            deployedPercent: 0, peopleReached: VerifiedCount(value: 1, verified: true), employeesEnrolled: nil,
                            workforceSize: 5, enrolledPercent: nil, updatedAt: nil, hasLogo: false)
        }
        func initiatives() async throws -> [PartnerInitiative] { [] }
        func spend() async throws -> [PartnerSpendCategory] { [] }
        func people() async throws -> PartnerPeople {
            PartnerPeople(enrolled: 0, workforceSize: 5, givenMinor: 0, matchedMinor: 0, avgStreakDays: 0, volunteerMinutes: 0, teams: 0, suppressed: true)
        }
        func teams() async throws -> [TeamStanding] { [] }
        func users() async throws -> [PartnerUser] { users }
        func inviteUser(email: String, name: String, role: PartnerRole) async throws {
            if let gate { await gate.pass() }
            try Task.checkCancellation()
            if let inviteError { throw inviteError }
            users.append(PartnerUser(id: "u3", email: email, name: name, role: role))
        }
        func removeUser(id: String) async throws { users.removeAll { $0.id == id } }
        func saveProfile(organization: String, description: String) async throws {}
        func saveWorkforce(size: Int) async throws {}
        func logo() async throws -> Data? { nil }
        func saveLogo(png: Data?) async throws {}
        func exports() async throws -> [PartnerExport] { [] }
        func report() async throws -> Data { Data() }
        func retainedReport(id: String) async throws -> Data { Data() }
        func signOut() async throws {}
        func registerPushDevice(token: String, environment: PushEnvironment) async throws {}
        func unregisterPushDevice() async throws {}
    }

    func testServerRoleRefusalShowsTheAdminMessageAndKeepsThePortal() async {
        let service = Service()
        let model = PartnerModel(service: service)
        await model.load()
        await service.setInviteError(AccountError.forbidden)
        await model.inviteUser(email: "n@x.com", name: "Nell", role: .viewer)
        XCTAssertEqual(model.actionError, "Only an admin can do that.")
        XCTAssertFalse(model.signedOut)
        XCTAssertEqual(model.users.count, 2)
    }

    func testRateLimitedInviteIsExplainedInlineAndLeavesTheListAlone() async {
        let service = Service()
        let model = PartnerModel(service: service)
        await model.load()
        await service.setInviteError(AccountError.rateLimited)
        await model.inviteUser(email: "n@x.com", name: "Nell", role: .viewer)
        XCTAssertEqual(model.actionError, AccountError.rateLimited.userMessage)
        XCTAssertEqual(model.users.map(\.id), ["u1", "u2"])
    }

    func testCancelledInviteChangesNothingAndShowsNoError() async {
        let service = Service()
        let gate = Gate()
        await service.setGate(gate)
        let model = PartnerModel(service: service)
        await model.load()
        let task = Task { await model.inviteUser(email: "n@x.com", name: "Nell", role: .viewer) }
        await gate.waitUntilEntered()
        task.cancel()
        await gate.release()
        await task.value
        XCTAssertNil(model.actionError)
        XCTAssertNil(model.notice)
        XCTAssertEqual(model.users.map(\.id), ["u1", "u2"])
        XCTAssertFalse(model.isBusy)
    }

    func testViewerGetsNoAdminCapabilityAndNoRemovableUser() async {
        let service = Service()
        await service.setRole(.viewer)
        let model = PartnerModel(service: service)
        await model.load()
        XCTAssertEqual(model.role, .viewer)
        XCTAssertTrue(model.users.allSatisfy { !model.canRemove($0) })
        model.requestRemoval(id: "u2")
        XCTAssertNil(model.pendingRemoval)
        XCTAssertEqual(model.actionError, "Only an admin can remove users.")
    }

    func testAdminSeesOnlyTheNonSelfUserAsRemovable() async {
        let model = PartnerModel(service: Service())
        await model.load()
        XCTAssertFalse(model.canRemove(model.users[0]), "an admin cannot remove themselves")
        XCTAssertTrue(model.canRemove(model.users[1]))
    }
}

/// The scripted backend the partner UITests run on behaves like the server: a viewer's writes are 403, the
/// signed-in user and the last admin cannot be removed (409), and an application receipt is recognized.
@MainActor
final class StubPartnerBackendTests: XCTestCase {
    func testViewerScenarioIsReadOnlyOnTheServerSideToo() async throws {
        let services = try StubBackend.make(partnerViewer: true)
        try await services.partnerAuth.accept(token: "stubpartner" + String(repeating: "x", count: 24))
        let model = PartnerModel(service: services.partner)
        await model.load()
        XCTAssertEqual(model.role, .viewer)
        XCTAssertEqual(model.overview?.userID, "u2")
        XCTAssertTrue(model.exports.isEmpty, "a viewer never loads exports")
        do { try await services.partner.inviteUser(email: "n@x.com", name: "N", role: .viewer); XCTFail("inviteUser must throw") }
        catch { XCTAssertEqual(error as? AccountError, .forbidden) }
        do { _ = try await services.partner.report(); XCTFail("report must throw") }
        catch { XCTAssertEqual(error as? AccountError, .forbidden) }
    }

    func testServerRefusesToRemoveTheSignedInUser() async throws {
        let services = try StubBackend.make(partnerSignedIn: true)
        do { try await services.partner.removeUser(id: "u1"); XCTFail("removeUser must throw") }
        catch { XCTAssertEqual(error as? AccountError, .conflict) }
        let model = PartnerModel(service: services.partner)
        await model.load()
        await model.removeUser(id: "u2")
        XCTAssertEqual(model.users.map(\.id), ["u1"])
    }

    func testApplicationScenariosAnswerEachStatusAndNoneByDefault() async throws {
        let none = try StubBackend.make()
        let nothing = try await none.applicationStatus.status()
        XCTAssertNil(nothing)
        for (raw, state): (String, ApplicationState) in [("PENDING", .pending), ("APPROVED", .approved), ("REJECTED", .rejected),
                                                         ("UNDER_REVIEW", .other("UNDER_REVIEW"))] {
            let services = try StubBackend.make(application: raw)
            let info = try await services.applicationStatus.status()
            XCTAssertEqual(info, ApplicationStatusInfo(organization: "Acme Corp", state: state))
        }
    }
}
