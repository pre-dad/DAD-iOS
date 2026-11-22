import XCTest
@testable import DADFoundation

final class PartnerRoleTests: XCTestCase {
    func testAdminCapabilities() {
        let admin = PartnerRole.admin
        XCTAssertTrue(admin.canManageUsers)
        XCTAssertTrue(admin.canEditProfile)
        XCTAssertTrue(admin.canExport)
    }

    func testViewerIsReadOnly() {
        let viewer = PartnerRole.viewer
        XCTAssertFalse(viewer.canManageUsers)
        XCTAssertFalse(viewer.canEditProfile)
        XCTAssertFalse(viewer.canExport)
    }

    func testUnknownRoleDecodesToLeastPrivileged() {
        XCTAssertEqual(PartnerRole(contract: "SUPERADMIN"), .viewer)
        XCTAssertEqual(PartnerRole(contract: "ADMIN"), .admin)
    }
}

final class VerifiedFigureTests: XCTestCase {
    func testVerifiedMoneyShowsOnlyWhenVerified() {
        XCTAssertEqual(VerifiedMoney(amountMinor: 124_000, verified: true).label, "$1,240")
        XCTAssertNil(VerifiedMoney(amountMinor: 124_000, verified: false).label)
    }

    func testVerifiedCountHiddenWhenUnverified() {
        XCTAssertEqual(VerifiedCount(value: 42, verified: true).label, "42")
        XCTAssertEqual(VerifiedCount(value: 12_400, verified: true).label, "12,400")
        XCTAssertNil(VerifiedCount(value: 42, verified: false).label)
    }
}

final class PartnerOverviewTests: XCTestCase {
    private func overview(enrolled: Int64?, role: PartnerRole = .admin) -> PartnerOverview {
        PartnerOverview(
            organization: "Acme", description: "desc", userID: "u1", role: role, companyCode: "ACME",
            committed: VerifiedMoney(amountMinor: 500_000, verified: true),
            deployed: VerifiedMoney(amountMinor: 300_000, verified: false),
            deployedPercent: 60,
            peopleReached: VerifiedCount(value: 1200, verified: true),
            employeesEnrolled: enrolled, workforceSize: 120,
            enrolledPercent: enrolled == nil ? nil : 35,
            updatedAt: Date(timeIntervalSince1970: 1_793_000_000), hasLogo: true)
    }

    func testUnverifiedDeployedIsHiddenNotEstimated() {
        let o = overview(enrolled: 42)
        XCTAssertEqual(o.committed.label, "$5,000")   // verified -> shown
        XCTAssertNil(o.deployed.label)                 // unverified -> hidden, never estimated (§7.3)
        XCTAssertEqual(o.peopleReached.label, "1,200")
    }

    func testSuppressedEnrollmentShowsNoCount() {
        XCTAssertNil(overview(enrolled: nil).enrolledLabel) // <5 suppressed -> null -> hidden
        XCTAssertEqual(overview(enrolled: 42).enrolledLabel, "42 of 120")
    }

    func testVerifiedLineCarriesTheAsOfDate() {
        XCTAssertNotNil(overview(enrolled: 42).verifiedLine())
        XCTAssertTrue(overview(enrolled: 42).verifiedLine()!.contains("Verified by DAD"))
    }
}

final class PartnerPeopleTests: XCTestCase {
    func testSuppressedGroupHidesFiguresAndShowsNotice() {
        let suppressed = PartnerPeople(enrolled: 3, workforceSize: 120, givenMinor: 40_000,
                                       matchedMinor: 20_000, avgStreakDays: 10, volunteerMinutes: 60,
                                       teams: 1, suppressed: true)
        XCTAssertNil(suppressed.givenLabel)
        XCTAssertNil(suppressed.matchedLabel)
        XCTAssertNotNil(suppressed.suppressionNotice)
        XCTAssertTrue(suppressed.suppressionNotice!.contains("Fewer than 5"))
        XCTAssertEqual([suppressed.enrolled, suppressed.givenMinor, suppressed.matchedMinor, suppressed.avgStreakDays,
                        suppressed.volunteerMinutes, suppressed.teams], [0, 0, 0, 0, 0, 0])
        XCTAssertFalse(suppressed.streakVerified)
    }

    func testUnsuppressedGroupShowsFigures() {
        let shown = PartnerPeople(enrolled: 42, workforceSize: 120, givenMinor: 40_000,
                                  matchedMinor: 20_000, avgStreakDays: 10, volunteerMinutes: 60,
                                  teams: 3, suppressed: false)
        XCTAssertEqual(shown.givenLabel, "$400")
        XCTAssertEqual(shown.matchedLabel, "$200")
        XCTAssertNil(shown.suppressionNotice)
    }
}

final class PartnerInitiativeTests: XCTestCase {
    func testHeadlineMetricsCappedAtThree() {
        let metrics = (1...5).map { PartnerMetric(label: "m\($0)", value: Int64($0), unit: .people) }
        let initiative = PartnerInitiative(id: "i1", title: "T", summary: "S", status: .active,
                                           region: "West", committedMinor: 100_000,
                                           deployedMinor: 50_000, metrics: metrics)
        XCTAssertEqual(initiative.headlineMetrics.count, 3)
        XCTAssertEqual(initiative.committedLabel, "$1,000")
        XCTAssertEqual(initiative.status.label, "Active")
    }
}

@MainActor
final class PartnerModelTests: XCTestCase {
    private final class FakeService: PartnerService, @unchecked Sendable {
        var role: PartnerRole = .admin
        var userID = "u1"
        var fail = false
        var failSpend = false
        var overviewError: Error?
        var spendSignedOut = false
        var hasLogo = false
        var removeError: Error?
        var actionError: Error?
        var retainedError: Error?
        var signOutError: Error?
        private(set) var invited: [(String, String, PartnerRole)] = []
        private(set) var profiles: [(String, String)] = []
        private(set) var workforce: [Int] = []
        private(set) var logos: [Data?] = []
        private(set) var reports = 0
        private(set) var signedOut = false
        private(set) var removed: [String] = []
        private(set) var pushRegistered = false
        private(set) var pushUnregistered = false
        var users: [PartnerUser] = [PartnerUser(id: "u1", email: "a@x.com", name: "A", role: .admin)]

        func overview() async throws -> PartnerOverview {
            if let overviewError { throw overviewError }
            if fail { throw AccountError.signedOut }
            return PartnerOverview(organization: "Acme", description: "d", userID: userID, role: role, companyCode: "AC",
                committed: VerifiedMoney(amountMinor: 1, verified: true),
                deployed: VerifiedMoney(amountMinor: 1, verified: true), deployedPercent: 1,
                peopleReached: VerifiedCount(value: 1, verified: true), employeesEnrolled: 42,
                workforceSize: workforce.last ?? 120, enrolledPercent: 35, updatedAt: Date(), hasLogo: hasLogo)
        }
        func initiatives() async throws -> [PartnerInitiative] { [] }
        func spend() async throws -> [PartnerSpendCategory] {
            if spendSignedOut { throw AccountError.signedOut }
            if failSpend { throw AccountError.unavailable }
            return []
        }
        func people() async throws -> PartnerPeople {
            PartnerPeople(enrolled: 42, workforceSize: 120, givenMinor: 0, matchedMinor: 0,
                          avgStreakDays: 0, volunteerMinutes: 0, teams: 0, suppressed: false)
        }
        func users() async throws -> [PartnerUser] { users }
        func teams() async throws -> [TeamStanding] { [] }
        func inviteUser(email: String, name: String, role: PartnerRole) async throws {
            if let actionError { throw actionError }
            invited.append((email, name, role))
        }
        func removeUser(id: String) async throws {
            if let removeError { throw removeError }
            removed.append(id); users.removeAll { $0.id == id }
        }
        func saveProfile(organization: String, description: String) async throws {
            if let actionError { throw actionError }
            profiles.append((organization, description))
        }
        func saveWorkforce(size: Int) async throws { workforce.append(size) }
        func logo() async throws -> Data? { Data("LOGO".utf8) }
        func saveLogo(png: Data?) async throws { logos.append(png) }
        func exports() async throws -> [PartnerExport] {
            [PartnerExport(id: "r1", createdAt: Date(), exportedBy: "A", committedMinor: 1, deployedMinor: 1, downloadable: true)]
        }
        func report() async throws -> Data { reports += 1; return Data("%PDF".utf8) }
        func retainedReport(id: String) async throws -> Data {
            if let retainedError { throw retainedError }
            return Data("%PDF".utf8)
        }
        func signOut() async throws {
            if let signOutError { throw signOutError }
            signedOut = true
        }
        func registerPushDevice(token: String, environment: PushEnvironment) async throws { pushRegistered = true }
        func unregisterPushDevice() async throws { pushUnregistered = true }
    }

    func testLoadReadyCarriesRole() async {
        let model = PartnerModel(service: FakeService())
        await model.load()
        XCTAssertEqual(model.phase, .ready)
        XCTAssertEqual(model.role, .admin)
    }

    func testLoadFailureSurfacesFailed() async {
        let svc = FakeService(); svc.fail = true
        let model = PartnerModel(service: svc)
        await model.load()
        guard case .failed = model.phase else { return XCTFail("expected failed") }
    }

    func testSecondarySectionFailureIsFlaggedNotShownAsEmpty() async {
        let svc = FakeService(); svc.failSpend = true
        let model = PartnerModel(service: svc)
        await model.load()
        XCTAssertEqual(model.phase, .ready, "the portal still renders with what did load")
        XCTAssertTrue(model.sectionsUnavailable)
        XCTAssertNotNil(model.people)
        XCTAssertEqual(model.users.count, 1)
    }

    func testCleanLoadDoesNotFlagSections() async {
        let model = PartnerModel(service: FakeService())
        await model.load()
        XCTAssertFalse(model.sectionsUnavailable)
    }

    func testLostSessionInASectionFailsTheWholeLoad() async {
        let svc = FakeService(); svc.spendSignedOut = true
        let model = PartnerModel(service: svc)
        await model.load()
        XCTAssertEqual(model.phase, .failed("Please sign in again."))
    }

    func testViewerCannotInviteOrRemove() async {
        let svc = FakeService(); svc.role = .viewer
        let model = PartnerModel(service: svc)
        await model.load()
        await model.inviteUser(email: "b@x.com", name: "Bea", role: .viewer)
        await model.removeUser(id: "u1")
        XCTAssertTrue(svc.invited.isEmpty)   // gated client-side, never hit the service
        XCTAssertTrue(svc.removed.isEmpty)
        XCTAssertNotNil(model.actionError)
    }

    func testAdminCanInviteAndRemove() async {
        let svc = FakeService()
        let model = PartnerModel(service: svc)
        await model.load()
        await model.inviteUser(email: "b@x.com", name: "Bea", role: .viewer)
        XCTAssertEqual(svc.invited.count, 1)
        XCTAssertEqual(svc.invited.first?.0, "b@x.com")
    }

    func testCancelledLoadKeepsPriorPhaseInsteadOfFailing() async {
        let svc = FakeService()
        let model = PartnerModel(service: svc)
        await model.load()
        svc.overviewError = CancellationError()
        await model.load()
        XCTAssertEqual(model.phase, .ready)
    }

    func testInviteRejectsInvalidEmailWithoutCallingService() async {
        let svc = FakeService()
        let model = PartnerModel(service: svc)
        await model.load()
        for bad in ["", "nobody", "a@b", "a@@b.com", "a b@x.com", "@x.com", "a@x..com"] {
            await model.inviteUser(email: bad, name: "Bea", role: .viewer)
            XCTAssertEqual(model.actionError, "Enter a valid email address.", bad)
        }
        XCTAssertTrue(svc.invited.isEmpty)
    }

    func testInviteTrimsAndSendsTheTypedEmail() async {
        let svc = FakeService()
        let model = PartnerModel(service: svc)
        await model.load()
        await model.inviteUser(email: "  new@acme.com ", name: " Nell ", role: .viewer)
        XCTAssertEqual(svc.invited.first?.0, "new@acme.com")
        XCTAssertEqual(svc.invited.first?.1, "Nell")
        XCTAssertNil(model.actionError)
        XCTAssertEqual(model.notice, "Invitation sent to new@acme.com.")
    }

    func testPlausibleEmail() {
        XCTAssertTrue(PartnerModel.isPlausibleEmail("a.b+c@sub.acme.co"))
        XCTAssertFalse(PartnerModel.isPlausibleEmail("a@b"))
        XCTAssertTrue(PartnerModel.isPlausibleEmail("  a@b.co  "))      // trimmed
        XCTAssertFalse(PartnerModel.isPlausibleEmail("a@b..c"))         // empty label
        XCTAssertFalse(PartnerModel.isPlausibleEmail("a@.b.c"))
        XCTAssertFalse(PartnerModel.isPlausibleEmail("@b.co"))
        XCTAssertFalse(PartnerModel.isPlausibleEmail("a b@c.co"))
        XCTAssertFalse(PartnerModel.isPlausibleEmail("a@@b.co"))
        let local = String(repeating: "a", count: 64)
        let ok = local + "@" + String(repeating: "b", count: 254 - 64 - 1 - 3) + ".co"
        XCTAssertEqual(ok.count, 254)
        XCTAssertTrue(PartnerModel.isPlausibleEmail(ok))
        XCTAssertFalse(PartnerModel.isPlausibleEmail("a" + ok))         // 255 characters
    }

    func testSelfIdComesFromOverviewNotInit() async {
        let svc = FakeService(); svc.userID = "u2"
        svc.users = [PartnerUser(id: "u1", email: "a@x.com", name: "A", role: .admin),
                     PartnerUser(id: "u2", email: "b@x.com", name: "B", role: .admin)]
        let model = PartnerModel(service: svc)
        XCTAssertNil(model.currentUserID)
        await model.load()
        XCTAssertEqual(model.currentUserID, "u2")
        XCTAssertFalse(model.canRemove(model.users[1]))
        XCTAssertTrue(model.canRemove(model.users[0]))
    }

    func testLastAdminCannotBeRemoved() async {
        let svc = FakeService(); svc.userID = "u2"
        svc.users = [PartnerUser(id: "u1", email: "a@x.com", name: "A", role: .admin),
                     PartnerUser(id: "u2", email: "b@x.com", name: "B", role: .admin),
                     PartnerUser(id: "u3", email: "c@x.com", name: "C", role: .viewer)]
        let model = PartnerModel(service: svc)
        await model.load()
        await model.removeUser(id: "u1")                 // two admins: allowed
        XCTAssertEqual(svc.removed, ["u1"])
        let admin = FakeService(); admin.userID = "u9"
        admin.users = [PartnerUser(id: "u2", email: "b@x.com", name: "B", role: .admin),
                       PartnerUser(id: "u3", email: "c@x.com", name: "C", role: .viewer)]
        let m2 = PartnerModel(service: admin)
        await m2.load()
        XCTAssertFalse(m2.canRemove(m2.users[0]))
        m2.requestRemoval(id: "u2")
        XCTAssertNil(m2.pendingRemoval)
        await m2.removeUser(id: "u2")
        XCTAssertTrue(admin.removed.isEmpty)
        XCTAssertEqual(m2.actionError, "You can’t remove the last admin.")
        XCTAssertTrue(m2.canRemove(m2.users[1]))
    }

    func testRemovalNeedsConfirmationAndCanBeCancelled() async {
        let svc = FakeService()
        svc.users = [PartnerUser(id: "u1", email: "a@x.com", name: "A", role: .admin),
                     PartnerUser(id: "u2", email: "v@x.com", name: "V", role: .viewer)]
        let model = PartnerModel(service: svc)
        await model.load()
        model.requestRemoval(id: "u2")
        XCTAssertEqual(model.pendingRemoval?.id, "u2")
        XCTAssertTrue(svc.removed.isEmpty, "staging a removal must not call the service")
        model.cancelRemoval()
        await model.confirmRemoval()
        XCTAssertTrue(svc.removed.isEmpty)
        model.requestRemoval(id: "u2")
        await model.confirmRemoval()
        XCTAssertEqual(svc.removed, ["u2"])
        XCTAssertNil(model.pendingRemoval)
        XCTAssertEqual(model.users.map(\.id), ["u1"])
    }

    func testAdminCannotRemoveThemselves() async {
        let svc = FakeService()
        let model = PartnerModel(service: svc)
        await model.load()
        XCTAssertFalse(model.canRemove(model.users[0]))
        model.requestRemoval(id: "u1")
        XCTAssertNil(model.pendingRemoval)
        await model.removeUser(id: "u1")
        XCTAssertTrue(svc.removed.isEmpty)
        XCTAssertEqual(model.actionError, "You can’t remove yourself.")
    }

    func testPushRegistersAndSignOutUnregistersBeforeEndingTheSession() async {
        let svc = FakeService()
        let model = PartnerModel(service: svc)
        await model.registerPush(token: "t", environment: .sandbox)
        await model.signOut()
        XCTAssertTrue(svc.pushRegistered)
        XCTAssertTrue(svc.pushUnregistered)
        XCTAssertTrue(svc.signedOut)
        XCTAssertTrue(model.signedOut)
    }

    func testInviteNeedsANameAndMapsConflict() async {
        let svc = FakeService()
        let model = PartnerModel(service: svc)
        await model.load()
        await model.inviteUser(email: "b@x.com", name: "  ", role: .viewer)
        XCTAssertEqual(model.actionError, "Enter their name.")
        svc.actionError = AccountError.conflict
        await model.inviteUser(email: "b@x.com", name: "Bea", role: .viewer)
        XCTAssertEqual(model.actionError, "That email already signs in to DAD with another role or organization.")
        XCTAssertTrue(svc.invited.isEmpty)
    }

    func testFailedLocalSignOutDoesNotClaimTheSessionWasForgotten() async {
        let service = FakeService()
        service.signOutError = AccountError.secureStorage(-1)
        let model = PartnerModel(service: service)
        await model.load()
        await model.signOut()
        XCTAssertFalse(model.signedOut)
        XCTAssertNotNil(model.actionError)
    }

    func testLostSessionDuringAnActionEndsThePortal() async {
        let svc = FakeService()
        let model = PartnerModel(service: svc)
        await model.load()
        svc.removeError = AccountError.signedOut
        svc.users.append(PartnerUser(id: "u2", email: "b@x.com", name: "B", role: .viewer))
        await model.load()
        await model.removeUser(id: "u2")
        XCTAssertTrue(model.signedOut)
    }

    func testProfileIsValidatedTrimmedAndReloaded() async {
        let svc = FakeService()
        let model = PartnerModel(service: svc)
        await model.load()
        await model.saveProfile(organization: "  ", description: "x")
        XCTAssertEqual(model.actionError, PartnerModel.profileRule)
        await model.saveProfile(organization: String(repeating: "a", count: 201), description: "")
        XCTAssertEqual(model.actionError, PartnerModel.profileRule)
        XCTAssertTrue(svc.profiles.isEmpty)
        await model.saveProfile(organization: " Acme Co ", description: " Builds wells. ")
        XCTAssertEqual(svc.profiles.first?.0, "Acme Co")
        XCTAssertEqual(svc.profiles.first?.1, "Builds wells.")
        XCTAssertEqual(model.notice, "Organization profile saved.")
    }

    func testViewerCannotEditProfileWorkforceLogoOrExport() async {
        let svc = FakeService(); svc.role = .viewer
        let model = PartnerModel(service: svc)
        await model.load()
        await model.saveProfile(organization: "Acme", description: "")
        await model.saveWorkforce("300")
        await model.saveLogo(png: Data("P".utf8))
        await model.exportReport()
        XCTAssertTrue(svc.profiles.isEmpty)
        XCTAssertTrue(svc.workforce.isEmpty)
        XCTAssertTrue(svc.logos.isEmpty)
        XCTAssertEqual(svc.reports, 0)
        XCTAssertTrue(model.exports.isEmpty)
    }

    func testWorkforceMustBeAWholeNumber() async {
        let svc = FakeService()
        let model = PartnerModel(service: svc)
        await model.load()
        for bad in ["", "-1", "12.5", "lots"] {
            await model.saveWorkforce(bad)
            XCTAssertEqual(model.actionError, "Enter the number of employees as a whole number.", bad)
        }
        await model.saveWorkforce(" 300 ")
        XCTAssertEqual(svc.workforce, [300])
        XCTAssertEqual(model.overview?.workforceSize, 300)
    }

    func testLogoLoadsWhenPresentAndCanBeRemoved() async {
        let svc = FakeService(); svc.hasLogo = true
        let model = PartnerModel(service: svc)
        await model.load()
        XCTAssertEqual(model.logo, Data("LOGO".utf8))
        await model.saveLogo(png: nil)
        XCTAssertNil(model.logo)
        XCTAssertEqual(svc.logos, [nil])
        XCTAssertEqual(model.notice, "Logo removed.")
    }

    func testExportWritesAShareablePDF() async throws {
        let svc = FakeService()
        let model = PartnerModel(service: svc)
        await model.load()
        XCTAssertEqual(model.exports.map(\.id), ["r1"])
        await model.exportReport()
        XCTAssertNil(model.actionError)
        let url = try XCTUnwrap(model.report?.url)
        XCTAssertEqual(url.pathExtension, "pdf")
        XCTAssertEqual(try Data(contentsOf: url), Data("%PDF".utf8))
    }

    func testAgedOutRetainedReportSaysSo() async throws {
        let svc = FakeService(); svc.retainedError = AccountError.notFound
        let model = PartnerModel(service: svc)
        await model.load()
        await model.download(try XCTUnwrap(model.exports.first))
        XCTAssertNil(model.report)
        XCTAssertEqual(model.actionError, "That report is no longer available. Export a new one.")
    }
}

final class PartnerSignInModelTests: XCTestCase {
    private final class FakeSignIn: PartnerSignInService, @unchecked Sendable {
        var error: Error?
        private(set) var requested: [String] = []
        private(set) var accepted: [String] = []
        func requestSignInLink(email: String) async throws {
            if let error { throw error }
            requested.append(email)
        }
        func accept(token: String) async throws {
            if let error { throw error }
            accepted.append(token)
        }
    }

    @MainActor func testRequestsALinkForAPlausibleAddress() async {
        let svc = FakeSignIn()
        let model = PartnerSignInModel(service: svc)
        model.email = "nope"
        XCTAssertFalse(model.canSubmit)
        model.email = " ada@acme.com "
        await model.submit()
        XCTAssertEqual(svc.requested, ["ada@acme.com"])
        XCTAssertEqual(model.phase, .sent("ada@acme.com"))
    }

    @MainActor func testPastedLinkOrBareTokenIsAccepted() async {
        let svc = FakeSignIn()
        let model = PartnerSignInModel(service: svc)
        await model.accept(pasted: " https://dad.example/partner/accept#token=abc123 ")
        XCTAssertEqual(model.phase, .signedIn)
        await model.accept(pasted: "def456")
        XCTAssertEqual(svc.accepted, ["abc123", "def456"])
        await model.accept(pasted: "two words")
        XCTAssertEqual(model.phase, .failed("Paste the whole sign-in link from your email."))
    }

    @MainActor func testUsedLinkAndBlockedAccountAreExplained() async {
        let svc = FakeSignIn()
        let model = PartnerSignInModel(service: svc)
        svc.error = AccountError.invalidInput
        await model.accept(token: "t")
        XCTAssertEqual(model.phase, .failed("That sign-in link has expired or was already used. Request a new one."))
        svc.error = AccountError.forbidden
        await model.accept(token: "t")
        XCTAssertEqual(model.phase, .failed("This partner account can’t sign in. Ask your organization’s admin or DAD support."))
    }
}

final class PartnerSessionTests: XCTestCase {
    func testCorruptPartnerCredentialsAreForgottenWithoutBlockingAppStartup() async throws {
        struct CorruptStore: CredentialStore {
            let wiped: WipeBox
            func load() throws -> Credentials? { throw DecodingError.dataCorrupted(.init(codingPath: [], debugDescription: "corrupt")) }
            func save(_ credentials: Credentials) throws {}
            func clear() throws { wiped.hit() }
        }
        let wiped = WipeBox()
        let session = try PartnerSession(store: CorruptStore(wiped: wiped))
        let signedIn = await session.isSignedIn
        XCTAssertFalse(signedIn)
        XCTAssertEqual(wiped.count, 1)
    }

    func testSessionLastsTwelveHoursThenIsForgotten() async throws {
        let clock = Clock()
        let store = MemoryStore(nil)
        let session = try PartnerSession(store: store, now: { clock.now })
        try await session.install(token: "P1")
        let token = try await session.token()
        XCTAssertEqual(token, "P1")
        clock.now = clock.now.addingTimeInterval(PartnerSession.lifetime + 1)
        do { _ = try await session.token(); XCTFail("expired session must not authorize") }
        catch { XCTAssertEqual(error as? AccountError, .signedOut) }
        XCTAssertNil(try store.load())
    }

    private final class Clock: @unchecked Sendable { var now = Date(timeIntervalSince1970: 1_800_000_000) }
}

final class WirePartnerTests: XCTestCase {
    func testAcceptStoresTheBearerAndPortalCallsSendIt() async throws {
        let transport = ScriptedTransport { seen, _ in
            switch seen.request.path {
            case "/donor/partner/accept-invite": return (.ok, #"{"session":"PB"}"#)
            case "/donor/partner/users": return (.ok, #"{"users":[{"id":"u1","email":"a@x.com","name":"A","role":"ADMIN","accepted":true}]}"#)
            default: return (.ok, "{}")
            }
        }
        let session = try PartnerSession(store: MemoryStore(nil))
        try await WirePartnerAuth(origin: testOrigin, transport: transport, session: session).accept(token: "INV")
        XCTAssertTrue(transport.calls(to: "/donor/partner/accept-invite").first?.body.contains(#""invite" : "INV""#) == true)
        let users = try await WirePartner(origin: testOrigin, transport: transport, session: session).users()
        XCTAssertEqual(users.map(\.id), ["u1"])
        XCTAssertEqual(transport.calls(to: "/donor/partner/users").first?.request.headerFields[.authorization], "Bearer PB")
    }

    func testRejectedSessionIsForgotten() async throws {
        let transport = ScriptedTransport { _, _ in (.unauthorized, "{}") }
        let store = MemoryStore(nil)
        let session = try PartnerSession(store: store)
        try await session.install(token: "PB")
        do { _ = try await WirePartner(origin: testOrigin, transport: transport, session: session).overview(); XCTFail("overview must throw") }
        catch { XCTAssertEqual(error as? AccountError, .signedOut) }
        XCTAssertNil(try store.load())
    }

    func testInviteAndLogoBodies() async throws {
        let transport = ScriptedTransport { seen, _ in
            seen.request.path == "/donor/partner/users" ? (.ok, #"{"invited":true}"#) : (.ok, #"{"saved":true}"#)
        }
        let session = try PartnerSession(store: MemoryStore(nil))
        try await session.install(token: "PB")
        let wire = WirePartner(origin: testOrigin, transport: transport, session: session)
        try await wire.inviteUser(email: "b@x.com", name: "Bea", role: .viewer)
        try await wire.saveLogo(png: Data([1, 2, 3]))
        try await wire.saveLogo(png: nil)
        func json(_ body: String) throws -> [String: String] {
            try XCTUnwrap(JSONSerialization.jsonObject(with: Data(body.utf8)) as? [String: String])
        }
        let invite = try json(try XCTUnwrap(transport.calls(to: "/donor/partner/users").first?.body))
        XCTAssertEqual(invite, ["email": "b@x.com", "name": "Bea", "role": "VIEWER"])
        let logos = try transport.calls(to: "/donor/partner/logo").filter { $0.request.method == .post }.map { try json($0.body) }
        XCTAssertEqual(logos, [["data_url": "data:image/png;base64,AQID"], ["data_url": ""]])
    }
}

final class StubPartnerTests: XCTestCase {
    @MainActor func testPortalRunsEndToEndOnTheScriptedBackend() async throws {
        let services = try StubBackend.make()
        let signIn = PartnerSignInModel(service: services.partnerAuth)
        await signIn.accept(token: "nope")
        XCTAssertEqual(signIn.phase, .failed("That sign-in link has expired or was already used. Request a new one."))
        await signIn.accept(token: "stubpartner" + String(repeating: "x", count: 24))
        XCTAssertEqual(signIn.phase, .signedIn)

        let model = PartnerModel(service: services.partner)
        await model.load()
        XCTAssertEqual(model.phase, .ready)
        XCTAssertFalse(model.sectionsUnavailable)
        XCTAssertEqual(model.teams.map(\.name), ["Engineering", "Sales"])
        await model.saveProfile(organization: "Acme \"Water\" Co", description: "Wells.")
        XCTAssertEqual(model.overview?.organization, "Acme \"Water\" Co")
        await model.saveLogo(png: Data([0x89, 0x50]))
        await model.load()
        XCTAssertEqual(model.logo, Data([0x89, 0x50]))
        await model.inviteUser(email: "new@acme.com", name: "Nell", role: .viewer)
        XCTAssertEqual(model.users.map(\.name), ["Ada Admin", "Val Viewer", "Nell"])
        await model.download(try XCTUnwrap(model.exports.first))
        XCTAssertEqual(model.actionError, "That report is no longer available. Export a new one.")
        await model.exportReport()
        XCTAssertNotNil(model.report)
        XCTAssertEqual(model.exports.count, 2)
        await model.signOut()
        let signedIn = await services.partnerSession.isSignedIn
        XCTAssertFalse(signedIn)
    }
}

@MainActor
final class PartnerSessionRaceTests: XCTestCase {
    func testOldPartnerRequestsCannotReturnDataOrClearANewSession() async throws {
        for rejected in [false, true] {
            let store = MemoryStore(nil)
            let session = try PartnerSession(store: store)
            try await session.install(token: "old")
            let gate = Gate()
            let request = Task { try await session.authorized { _ in
                await gate.pass()
                if rejected { throw AccountError.signedOut }
                return "old private data"
            } }
            await gate.waitUntilEntered()
            try await session.install(token: "new")
            await gate.release()
            do { _ = try await request.value; XCTFail("stale request returned private data") }
            catch { XCTAssertEqual(error as? AccountError, .signedOut) }
            let current = try await session.token()
            XCTAssertEqual(current, "new")
        }
    }

    func testPartnerSignInCannotRestoreASignedOutSession() async throws {
        let store = MemoryStore(nil)
        let session = try PartnerSession(store: store)
        let gate = Gate()
        let request = Task { try await session.establish { await gate.pass(); return "late" } }
        await gate.waitUntilEntered()
        try await session.clear()
        await gate.release()
        do { try await request.value; XCTFail("late sign-in restored the session") }
        catch { XCTAssertEqual(error as? AccountError, .signedOut) }
        XCTAssertNil(try store.load())
    }

    func testCancelledPartnerSignInInstallsNothing() async throws {
        let store = MemoryStore(nil)
        let session = try PartnerSession(store: store)
        let gate = Gate()
        let request = Task { try await session.establish { await gate.pass(); return "late" } }
        await gate.waitUntilEntered()
        request.cancel()
        await gate.release()
        do { try await request.value; XCTFail("cancelled sign-in installed credentials") }
        catch { XCTAssertTrue(error is CancellationError) }
        XCTAssertNil(try store.load())
    }
}

final class PartnerMetricRangeTests: XCTestCase {
    func testCountsRetainTheFullInt64Range() {
        XCTAssertEqual(PartnerMetric(label: "People", value: Int64.max, unit: .people).valueLabel, "9,223,372,036,854,775,807")
        XCTAssertEqual(PartnerMetric(label: "People", value: 12400, unit: .people).valueLabel, "12,400")
    }
}

final class PartnerReportSizeTests: XCTestCase {
    func testReportsCanExceedTheOrdinaryJSONBodyLimit() async throws {
        let pdf = "%PDF-1.4\n" + String(repeating: "x", count: 2 * 1_048_576)
        let transport = ScriptedTransport { _, _ in (.ok, pdf) }
        let session = try PartnerSession(store: MemoryStore(nil))
        try await session.install(token: "PB")
        let service = WirePartner(origin: testOrigin, transport: transport, session: session)
        let report = try await service.report()
        let retained = try await service.retainedReport(id: "report")
        XCTAssertEqual(report, Data(pdf.utf8))
        XCTAssertEqual(retained, report)
    }
}

final class VolunteerTimeTests: XCTestCase {
    func testLabelsMinutesBelowAnHourAndHoursToOneDecimal() {
        let cases: [(Int64, String)] = [(0, "0 minutes"), (1, "1 minute"), (59, "59 minutes"), (60, "1 hour"), (90, "1.5 hours"),
                                        (125, "2.1 hours"), (120, "2 hours")]
        for (minutes, label) in cases { XCTAssertEqual(VolunteerTime.label(minutes: minutes), label, "\(minutes)") }
    }
}
