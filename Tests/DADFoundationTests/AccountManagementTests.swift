import Foundation
import HTTPTypes
import OpenAPIRuntime
import XCTest
@testable import DADFoundation

private let sessionListJSON = #"""
{"sessions":[
 {"id":"11111111-1111-4111-8111-111111111111","client":"APP","platform":"IOS","label":"Alex’s iPhone","created_at":"2026-10-01T10:00:00Z","last_used_at":"2026-10-30T10:00:00Z","current":true},
 {"id":"22222222-2222-4222-8222-222222222222","client":"BROWSER","platform":null,"label":"Web browser","created_at":"2026-10-02T10:00:00Z","last_used_at":"2026-10-29T10:00:00Z","current":false}
]}
"""#

final class ProfileRulesTests: XCTestCase {
    func testZipAcceptsFiveDigitsZipPlusFourOrEmpty() {
        for zip in ["78701", "78701-1234", "", " 78701 "] { XCTAssertTrue(ProfileRules.isAcceptableZip(zip), zip) }
        for zip in ["7870", "787011", "78701-12", "abcde"] { XCTAssertFalse(ProfileRules.isAcceptableZip(zip), zip) }
    }

    func testPhoneNormalizesTheWaysPeopleTypeAUSNumber() {
        XCTAssertEqual(ProfileRules.e164("(415) 555-0123"), "+14155550123")
        XCTAssertEqual(ProfileRules.e164("1 415 555 0123"), "+14155550123")
        XCTAssertEqual(ProfileRules.e164("+44 20 7946 0958"), "+442079460958")
        XCTAssertEqual(ProfileRules.e164(""), "")
        XCTAssertNil(ProfileRules.e164("555-0123"))
        XCTAssertNil(ProfileRules.e164("+0123"))
        XCTAssertNil(ProfileRules.e164("call me"))
    }
}

private actor FakeManagement: AccountManagementService {
    var failure: AccountError?
    var saved: [(String, String, String)] = []
    var emailRequests: [String] = []
    var list = [
        DeviceSessionSummary(id: "this", label: "iPhone", isApp: true, lastUsedAt: .now, current: true),
        DeviceSessionSummary(id: "web", label: "Web browser", isApp: false, lastUsedAt: .now, current: false),
    ]
    var team = EmployerTeam(organization: nil, teamName: nil, leaderboard: [])
    var everywhere = 0

    func fail(_ error: AccountError?) { failure = error }
    private func check() throws { if let failure { throw failure } }

    func saveProfile(zip: String, city: String, phone: String) async throws -> AccountProfileSummary {
        try check()
        saved.append((zip, city, phone))
        return AccountProfileSummary(email: "alex@example.org", accountRole: "DONOR", zip: zip, city: city, phone: phone.isEmpty ? nil : phone)
    }
    func requestEmailChange(to email: String) async throws { try check(); emailRequests.append(email) }
    func sessions() async throws -> [DeviceSessionSummary] { try check(); return list }
    func revokeSession(id: String) async throws -> [DeviceSessionSummary] {
        try check()
        guard list.contains(where: { $0.id == id }) else { throw AccountError.notFound }
        list.removeAll { $0.id == id }
        return list
    }
    func revokeOtherSessions() async throws -> [DeviceSessionSummary] { try check(); list.removeAll { !$0.current }; return list }
    func signOutEverywhere() async throws { try check(); everywhere += 1 }
    func employer() async throws -> EmployerTeam { try check(); return team }
    func enroll(companyCode: String) async throws -> String {
        try check()
        guard companyCode == "ACME42" else { throw AccountError.invalidInput }
        team = EmployerTeam(organization: "Acme", teamName: nil, leaderboard: [])
        return "Acme"
    }
    func joinTeam(name: String) async throws {
        try check()
        team = EmployerTeam(organization: team.organization, teamName: name, leaderboard: [])
    }
}

@MainActor final class AccountManagementModelTests: XCTestCase {
    private let profile = AccountProfileSummary(email: "alex@example.org", accountRole: "DONOR", zip: "78701", city: "Austin", phone: nil)

    func testProfileSavesOnlyAValidChangeAndSendsE164() async {
        let service = FakeManagement()
        let model = ProfileDetailsModel(profile: profile, service: service)
        XCTAssertFalse(model.canSave, "nothing changed")
        model.phone = "415 555 012"
        XCTAssertFalse(model.canSave, "not a phone number")
        model.phone = "(415) 555-0123"
        model.zip = "7870"
        XCTAssertFalse(model.canSave, "not a ZIP")
        model.zip = "78702"
        XCTAssertTrue(model.canSave)
        await model.save()
        XCTAssertEqual(model.phase, .saved)
        let saved = await service.saved
        XCTAssertEqual(saved.first?.0, "78702")
        XCTAssertEqual(saved.first?.2, "+14155550123")
        XCTAssertEqual(model.profile.zip, "78702")
        XCTAssertFalse(model.canSave, "the saved values are the new baseline")
    }

    func testProfileRejectedByServerExplainsItself() async {
        let service = FakeManagement()
        await service.fail(.invalidInput)
        let model = ProfileDetailsModel(profile: profile, service: service)
        model.zip = ""
        await model.save()
        XCTAssertEqual(model.phase, .failed("Check the ZIP code and phone number, then try again."))
    }

    func testEmailChangeRequiresANewPlausibleAddress() async {
        let service = FakeManagement()
        let model = EmailChangeModel(current: "alex@example.org", service: service)
        model.email = "ALEX@example.org"
        XCTAssertFalse(model.canSubmit, "the same address is not a change")
        model.email = "new@example"
        XCTAssertFalse(model.canSubmit)
        model.email = " new@example.org "
        await model.submit()
        XCTAssertEqual(model.phase, .sent)
        let requested = await service.emailRequests
        XCTAssertEqual(requested, ["new@example.org"])
    }

    func testEmailChangeConflictNamesTheReason() async {
        let service = FakeManagement()
        await service.fail(.conflict)
        let model = EmailChangeModel(current: "alex@example.org", service: service)
        model.email = "taken@example.org"
        await model.submit()
        XCTAssertEqual(model.phase, .failed("That address can’t replace your account email. Existing accounts are never merged."))
    }

    func testSessionsRevokeOneThenOthers() async {
        let service = FakeManagement()
        let model = DeviceSessionsModel(service: service)
        await model.load()
        XCTAssertEqual(model.phase, .ready)
        XCTAssertEqual(model.others.map(\.id), ["web"])
        await model.revoke("web")
        XCTAssertTrue(model.others.isEmpty)
        XCTAssertNil(model.actionError)
        await model.revokeOthers()
        XCTAssertEqual(model.notice, "Signed out of every other device.")
    }

    func testRevokingAGoneSessionReloadsTheList() async {
        let service = FakeManagement()
        let model = DeviceSessionsModel(service: service)
        await model.load()
        await model.revoke("already-gone")
        XCTAssertNil(model.actionError)
        XCTAssertEqual(model.phase, .ready)
    }

    func testSignOutEverywhereLeavesTheShellOnlyWhenConfirmed() async {
        let service = FakeManagement()
        await service.fail(.unavailable)
        let model = DeviceSessionsModel(service: service)
        await model.signOutEverywhere()
        XCTAssertFalse(model.signedOut)
        XCTAssertNotNil(model.actionError)
        await service.fail(nil)
        await model.signOutEverywhere()
        XCTAssertTrue(model.signedOut)
        let calls = await service.everywhere
        XCTAssertEqual(calls, 1)
    }

    func testEmployerEnrollThenJoinTeam() async {
        let service = FakeManagement()
        let model = EmployerModel(service: service)
        await model.load()
        XCTAssertEqual(model.phase, .ready(EmployerTeam(organization: nil, teamName: nil, leaderboard: [])))
        model.companyCode = "WRONG"
        await model.enroll()
        XCTAssertEqual(model.actionError, "That company code isn’t recognized. Check it with your employer and try again.")
        model.companyCode = " ACME42 "
        await model.enroll()
        XCTAssertNil(model.actionError)
        XCTAssertEqual(model.companyCode, "")
        guard case .ready(let linked) = model.phase else { return XCTFail("\(model.phase)") }
        XCTAssertEqual(linked.organization, "Acme")
        model.teamName = String(repeating: "x", count: 81)
        XCTAssertFalse(model.canJoinTeam)
        model.teamName = "Platform"
        await model.joinTeam()
        guard case .ready(let joined) = model.phase else { return XCTFail("\(model.phase)") }
        XCTAssertEqual(joined.teamName, "Platform")
    }

    func testEmployerAlreadyLinkedElsewhere() async {
        let service = FakeManagement()
        let model = EmployerModel(service: service)
        await model.load()
        await service.fail(.conflict)
        model.companyCode = "OTHER"
        await model.enroll()
        XCTAssertEqual(model.actionError, "Your account is already linked to another employer.")
    }
}

final class WireAccountManagementTests: XCTestCase {
    private func make(_ transport: ScriptedTransport) throws -> (WireAccountManagement, AccountSession, MemoryStore) {
        let store = MemoryStore(Credentials(access: "tok", refresh: "ref", expiresAt: .distantFuture))
        let session = try AccountSession(api: WireAPI(origin: testOrigin, transport: transport), store: store)
        return (WireAccountManagement(product: ProductClient(origin: testOrigin, transport: transport, session: session)), session, store)
    }

    private func sent(_ call: ScriptedTransport.Seen?) throws -> [String: String] {
        let body = try XCTUnwrap(call?.body)
        return try XCTUnwrap(JSONSerialization.jsonObject(with: Data(body.utf8)) as? [String: String])
    }

    func testSaveProfileSendsAllThreeFieldsAndMapsTheProfile() async throws {
        let transport = ScriptedTransport { _, _ in (.ok, profileJSON()) }
        let (wire, _, _) = try make(transport)
        let saved = try await wire.saveProfile(zip: "78701", city: "Austin", phone: "")
        XCTAssertEqual(saved.email, "alex@example.org")
        let call = transport.calls(to: "/donor/me/profile").first
        XCTAssertEqual(call?.request.method, .post)
        XCTAssertEqual(call?.request.headerFields[.authorization], "Bearer tok")
        XCTAssertEqual(try sent(call), ["zip": "78701", "city": "Austin", "phone": ""])
    }

    func testSaveProfile422IsInvalidInput() async throws {
        let (wire, _, _) = try make(ScriptedTransport { _, _ in (.unprocessableContent, "{}") })
        do { _ = try await wire.saveProfile(zip: "1", city: "", phone: ""); XCTFail() }
        catch { XCTAssertEqual(error as? AccountError, .invalidInput) }
    }

    func testEmailChangeStatusMapping() async throws {
        let ok = ScriptedTransport { _, _ in (.ok, #"{"stage":"CURRENT"}"#) }
        try await make(ok).0.requestEmailChange(to: "new@example.org")
        XCTAssertEqual(try sent(ok.calls(to: "/donor/me/email-change").first), ["email": "new@example.org"])
        for (status, expected) in [(HTTPResponse.Status.conflict, AccountError.conflict), (.unprocessableContent, .invalidInput),
                                   (.serviceUnavailable, .unavailable), (.tooManyRequests, .rateLimited)] {
            do { try await make(ScriptedTransport { _, _ in (status, "{}") }).0.requestEmailChange(to: "x@example.org"); XCTFail() }
            catch { XCTAssertEqual(error as? AccountError, expected, "\(status)") }
        }
    }

    func testSessionsMapCurrentAndClient() async throws {
        let (wire, _, _) = try make(ScriptedTransport { _, _ in (.ok, sessionListJSON) })
        let list = try await wire.sessions()
        XCTAssertEqual(list.map(\.current), [true, false])
        XCTAssertEqual(list.map(\.isApp), [true, false])
        XCTAssertEqual(list[1].label, "Web browser")
    }

    func testRevokeSessionPostsToItsIdAndMaps404() async throws {
        let transport = ScriptedTransport { _, _ in (.ok, sessionListJSON) }
        _ = try await make(transport).0.revokeSession(id: "22222222-2222-4222-8222-222222222222")
        XCTAssertEqual(transport.seen.first?.request.path, "/donor/me/sessions/22222222-2222-4222-8222-222222222222/revoke")
        do { _ = try await make(ScriptedTransport { _, _ in (.notFound, "{}") }).0.revokeSession(id: "x"); XCTFail() }
        catch { XCTAssertEqual(error as? AccountError, .notFound) }
    }

    func testSignOutEverywhereClearsLocalOnlyAfterTheServerConfirms() async throws {
        let failing = try make(ScriptedTransport { _, _ in (.serviceUnavailable, "{}") })
        do { try await failing.0.signOutEverywhere(); XCTFail() } catch { XCTAssertEqual(error as? AccountError, .unavailable) }
        XCTAssertNotNil(try failing.2.load(), "a failed request must not pretend every device was signed out")

        let transport = ScriptedTransport { _, _ in (.ok, #"{"signed_out":true}"#) }
        let rig = try make(transport)
        try await rig.0.signOutEverywhere()
        XCTAssertNil(try rig.2.load())
        XCTAssertEqual(transport.calls(to: "/donor/logout-all").count, 1)
    }

    func testEmployerMapsAnUnlinkedDonorToNoOrganization() async throws {
        let unlinked = try make(ScriptedTransport { _, _ in (.ok, #"{"partner_id":"","organization":"","leaderboard":[]}"#) })
        let none = try await unlinked.0.employer()
        XCTAssertEqual(none, EmployerTeam(organization: nil, teamName: nil, leaderboard: []))

        let linked = try make(ScriptedTransport { _, _ in
            (.ok, #"{"partner_id":"p","organization":"Acme","team_id":"t","team_name":"Platform","leaderboard":[{"team_id":"t","name":"Platform","active_givers":6,"annualized_minor":360000,"avg_streak_days":12,"volunteer_minutes":90}]}"#)
        })
        let team = try await linked.0.employer()
        XCTAssertEqual(team.organization, "Acme")
        XCTAssertEqual(team.teamName, "Platform")
        XCTAssertEqual(team.leaderboard.first?.activeGivers, 6)
    }

    func testEnrollAndJoinTeamStatusMapping() async throws {
        let transport = ScriptedTransport { _, _ in (.ok, #"{"organization":"Acme"}"#) }
        let org = try await make(transport).0.enroll(companyCode: "ACME42")
        XCTAssertEqual(org, "Acme")
        XCTAssertEqual(try sent(transport.calls(to: "/donor/me/employer").first), ["company_code": "ACME42"])
        for (status, expected) in [(HTTPResponse.Status.unprocessableContent, AccountError.invalidInput), (.conflict, .conflict)] {
            do { _ = try await make(ScriptedTransport { _, _ in (status, "{}") }).0.enroll(companyCode: "X"); XCTFail() }
            catch { XCTAssertEqual(error as? AccountError, expected) }
        }
        let join = ScriptedTransport { _, _ in (.ok, #"{"team_id":"t"}"#) }
        try await make(join).0.joinTeam(name: "Platform")
        XCTAssertEqual(try sent(join.calls(to: "/donor/me/team").first), ["name": "Platform"])
    }
}

private actor FakeWallet: WalletPassService {
    var available = true
    var fails = false
    func set(available: Bool, fails: Bool) { self.available = available; self.fails = fails }
    func appleWalletAvailable() async throws -> Bool {
        if fails { throw AccountError.unavailable }
        return available
    }
    func applePass() async throws -> Data {
        if fails { throw AccountError.unavailable }
        return Data("pkpass".utf8)
    }
}

@MainActor final class WalletPassModelTests: XCTestCase {
    func testPreparesOnlyWhenWalletIsAvailable() async {
        let service = FakeWallet()
        await service.set(available: false, fails: false)
        let model = WalletPassModel(service: service)
        await model.check()
        XCTAssertEqual(model.available, false)
        await model.prepare()
        XCTAssertNil(model.pass)

        await service.set(available: true, fails: false)
        await model.check()
        await model.prepare()
        XCTAssertEqual(model.pass, Data("pkpass".utf8))
    }

    func testAFailedCheckOrPassSaysTheCodeStillWorks() async {
        let service = FakeWallet()
        let model = WalletPassModel(service: service)
        await model.check()
        await service.set(available: true, fails: true)
        await model.prepare()
        XCTAssertEqual(model.error, WalletPassModel.failure)
        await model.check()
        XCTAssertTrue(model.checkFailed)
        XCTAssertNil(model.available)

        await service.set(available: true, fails: false)
        await model.check()
        await model.prepare()
        model.passRejected()
        XCTAssertNil(model.pass)
        XCTAssertEqual(model.error, WalletPassModel.failure)
    }
}

final class WireWalletPassTests: XCTestCase {
    private func make(_ transport: ScriptedTransport) throws -> WireWalletPass {
        let store = MemoryStore(Credentials(access: "tok", refresh: "ref", expiresAt: .distantFuture))
        let session = try AccountSession(api: WireAPI(origin: testOrigin, transport: transport), store: store)
        return WireWalletPass(product: ProductClient(origin: testOrigin, transport: transport, session: session))
    }

    func testProvidersAndPassBytes() async throws {
        let transport = ScriptedTransport { seen, _ in
            seen.request.path == "/donor/me/wallet" ? (.ok, #"{"apple":true,"google":false}"#) : (.ok, "PKPASSBYTES")
        }
        let wire = try make(transport)
        let available = try await wire.appleWalletAvailable()
        XCTAssertTrue(available)
        let pass = try await wire.applePass()
        XCTAssertEqual(pass, Data("PKPASSBYTES".utf8))
        XCTAssertEqual(transport.calls(to: "/donor/me/wallet/apple").first?.request.method, .post)
    }

    func testPassBeforeAPublicNameIsAConflict() async throws {
        do { _ = try await make(ScriptedTransport { _, _ in (.conflict, "{}") }).applePass(); XCTFail() }
        catch { XCTAssertEqual(error as? AccountError, .conflict) }
    }
}
