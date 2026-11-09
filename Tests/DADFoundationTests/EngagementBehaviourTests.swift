import Foundation
import XCTest
@testable import DADFoundation

// P5: the rank-label correction, the invite/QR link shape, and the engagement + spend models.

final class RankLabelTests: XCTestCase {
    /// `national_percentile` is already the *top* bucket (the server's NAT2 badge is "top 2%"), so the label
    /// is that number as is. The previous `100 - p` rendered a top-2% donor as "Top 98%".
    func testTheServersTopBucketIsShownAsIs() {
        for (bucket, label) in [(1, "Top 1% nationally"), (2, "Top 2% nationally"), (50, "Top 50% nationally"), (98, "Top 98% nationally")] {
            XCTAssertEqual(RankingStanding(nationalPercentile: bucket, city: nil, cityRank: nil).nationalLabel, label, "bucket \(bucket)")
        }
    }

    func testOutOfRangeBucketsAreClamped() {
        XCTAssertEqual(RankingStanding(nationalPercentile: 0, city: nil, cityRank: nil).nationalLabel, "Top 1% nationally")
        XCTAssertEqual(RankingStanding(nationalPercentile: -7, city: nil, cityRank: nil).nationalLabel, "Top 1% nationally")
        XCTAssertEqual(RankingStanding(nationalPercentile: 100, city: nil, cityRank: nil).nationalLabel, "Top 100% nationally")
        XCTAssertEqual(RankingStanding(nationalPercentile: 250, city: nil, cityRank: nil).nationalLabel, "Top 100% nationally")
    }

    func testTheEngagementLabelAgreesWithTheDashboardLabel() {
        for bucket in [1, 2, 10, 50, 98] {
            XCTAssertEqual(RankingStanding(nationalPercentile: bucket, city: nil, cityRank: nil).nationalLabel,
                           DashboardRank(topPercent: bucket, city: nil, cityRank: nil).nationalLabel, "bucket \(bucket)")
        }
    }
}

final class InviteLinkTests: XCTestCase {
    func testInviteAndInPersonLinksUseTheReferralRoute() {
        let referral = ReferralInfo(code: "ALEX42", linkCount: nil, irlCount: nil)
        XCTAssertEqual(referral.inviteURL(host: "https://dollaraday.org")?.absoluteString, "https://dollaraday.org/r/ALEX42")
        XCTAssertEqual(referral.irlURL(host: "https://dollaraday.org")?.absoluteString, "https://dollaraday.org/r/ALEX42?via=irl")
    }

    func testWhitespaceAroundAServerCodeIsTrimmedBeforeBuildingTheLink() {
        let referral = ReferralInfo(code: "  ABC_123-x  ", linkCount: nil, irlCount: nil)
        XCTAssertEqual(referral.inviteURL(host: "https://dollaraday.org")?.absoluteString,
                       "https://dollaraday.org/r/ABC_123-x")
    }

    func testAMalformedCodeNeverBecomesALink() {
        for code in ["", "a b", "x/../y", "<script>", String(repeating: "A", count: 65)] {
            let referral = ReferralInfo(code: code, linkCount: nil, irlCount: nil)
            XCTAssertNil(referral.inviteURL(host: "https://dollaraday.org"), code)
            XCTAssertNil(referral.irlURL(host: "https://dollaraday.org"), code)
        }
    }

    func testTheInPersonLinkRoundTripsThroughTheAppRouter() throws {
        let origin = try XCTUnwrap(URL(string: "https://dollaraday.org"))
        let router = try LinkRouter(publicOrigin: origin)
        let url = try XCTUnwrap(ReferralInfo(code: "ALEX42", linkCount: nil, irlCount: nil).irlURL(host: origin.absoluteString))
        XCTAssertEqual(router.route(url), .referral(code: "ALEX42", inPerson: true))
        XCTAssertNil(router.route(try XCTUnwrap(URL(string: "https://other.test/r/ALEX42"))))
    }

    func testUnknownCountsAreNotZero() {
        XCTAssertNil(ReferralInfo(code: "A", linkCount: nil, irlCount: 2).totalConverted)
        XCTAssertNil(ReferralInfo(code: "A", linkCount: 1, irlCount: nil).totalConverted)
        XCTAssertEqual(ReferralInfo(code: "A", linkCount: 0, irlCount: 0).totalConverted, 0, "a known zero is still zero")
    }

    func testConversionKindsTolerateUnknownChannels() {
        XCTAssertEqual(ConversionKind(wire: "link"), .link)
        XCTAssertEqual(ConversionKind(wire: "IRL"), .irl)
        XCTAssertEqual(ConversionKind(wire: "SMS"), .other)
        XCTAssertEqual(ConversionKind.other.label, "Invite")
    }
}

final class BadgeCopyTests: XCTestCase {
    func testPerkCopyForTheCatalogKeys() {
        XCTAssertEqual(Badge.perkCopy(forKey: ""), "")
        XCTAssertEqual(Badge.perkCopy(forKey: "FOUNDING_EVENTS"), "Invite-only founding events")
        XCTAssertEqual(Badge.perkCopy(forKey: "MILESTONE_EVENTS"), "Invite-only milestone events")
        XCTAssertTrue(Badge.perkCopy(forKey: "TEAM_CAPTAIN").contains("DAD merch item"))
        XCTAssertEqual(Badge.perkCopy(forKey: "ANYTHING_NEW"), "Unlocks a member perk")
    }

    func testAccessibilitySummaryCarriesStateAndPerkInText() {
        let locked = Badge(code: "1K", title: "1,000 Days", rule: "Reach a 1,000-day streak", perk: "Invite-only milestone events", earned: false)
        XCTAssertEqual(locked.accessibilitySummary, "1,000 Days, locked. Reach a 1,000-day streak. Perk: Invite-only milestone events")
        XCTAssertEqual(Badge(code: "7", title: "One Week", rule: "r", perk: "", earned: true).accessibilitySummary, "One Week, earned")
    }
}

// MARK: - models

private actor ScriptedEngagement: EngagementService {
    var snapshots: [Result<EngagementSnapshot, Error>]
    var toggle: Result<RankingStanding, Error>
    var name: Result<Void, Error> = .success(())
    var spend: Result<InitiativeSpendSummary, Error> = .success(InitiativeSpendSummary(initiativeID: "i", totalMinor: 100, slices: []))
    private(set) var toggles: [Bool] = []
    private(set) var names: [String] = []
    private var gate: Gate?

    init(snapshots: [Result<EngagementSnapshot, Error>], toggle: Result<RankingStanding, Error> = .success(RankingStanding(nationalPercentile: nil, city: nil, cityRank: nil, rankingsOptedOut: true))) {
        self.snapshots = snapshots; self.toggle = toggle
    }
    func hold(_ gate: Gate) { self.gate = gate }
    func setName(_ result: Result<Void, Error>) { name = result }
    func setSpend(_ result: Result<InitiativeSpendSummary, Error>) { spend = result }

    func snapshot() async throws -> EngagementSnapshot {
        let next = snapshots.count > 1 ? snapshots.removeFirst() : snapshots[0]
        return try next.get()
    }
    func setRankingOptIn(_ optIn: Bool) async throws -> RankingStanding {
        toggles.append(optIn)
        if let gate { await gate.pass() }
        return try toggle.get()
    }
    func choosePublicName(_ name: String) async throws { names.append(name); try self.name.get() }
    func initiativeSpend(id: String) async throws -> InitiativeSpendSummary { try spend.get() }
}

private let ranked = RankingStanding(nationalPercentile: 2, city: "Austin", cityRank: 4)
private func snap(ranking: RankingStanding? = ranked, referral: ReferralInfo? = ReferralInfo(code: "ALEX42", linkCount: 1, irlCount: 1),
                  needsName: Bool = false, badges: BadgeCollection? = BadgeCollection(badges: [])) -> EngagementSnapshot {
    EngagementSnapshot(impact: ImpactTotals(givenMinor: nil, initiativesFunded: 1, eventsVolunteered: 0), badges: badges, ranking: ranking,
                       network: nil, referral: referral, needsPublicName: needsName)
}

@MainActor
final class EngagementModelP5Tests: XCTestCase {
    func testSectionsTheServerDidNotGiveStayNilOnTheSnapshot() async {
        let model = EngagementModel(service: ScriptedEngagement(snapshots: [.success(snap(ranking: nil, referral: nil, badges: nil))]))
        await model.load()
        XCTAssertEqual(model.phase, .ready)
        XCTAssertNil(model.snapshot?.ranking)
        XCTAssertNil(model.displayedRanking)
        XCTAssertNil(model.snapshot?.badges)
        XCTAssertNil(model.snapshot?.referral)
    }

    func testAToggleShowsTheChoiceAtOnceThenConfirmsIt() async {
        let gate = Gate()
        let service = ScriptedEngagement(snapshots: [.success(snap())])
        await service.hold(gate)
        let model = EngagementModel(service: service)
        await model.load()
        XCTAssertEqual(model.displayedRanking?.isOptedOut, false)
        let task = Task { await model.setRankingOptIn(false) }
        await gate.waitUntilEntered()
        XCTAssertEqual(model.pendingOptIn, false)
        XCTAssertEqual(model.displayedRanking?.isOptedOut, true, "the card flips before the server answers")
        XCTAssertEqual(model.snapshot?.ranking, ranked, "the confirmed standing is untouched until then")
        await gate.release()
        await task.value
        XCTAssertNil(model.pendingOptIn)
        XCTAssertEqual(model.displayedRanking?.isOptedOut, true)
        XCTAssertEqual(model.snapshot?.ranking?.isOptedOut, true)
        XCTAssertNil(model.actionError)
    }

    func testAFailedToggleRevertsAndSaysSoInline() async {
        let service = ScriptedEngagement(snapshots: [.success(snap())], toggle: .failure(AccountError.unavailable))
        let model = EngagementModel(service: service)
        await model.load()
        await model.setRankingOptIn(false)
        XCTAssertNil(model.pendingOptIn)
        XCTAssertEqual(model.displayedRanking, ranked, "the screen reverts to the standing the server last confirmed")
        XCTAssertEqual(model.actionError, "Something went wrong. Please try again.")
        XCTAssertEqual(model.phase, .ready)
        XCTAssertFalse(model.signedOut)
    }

    func testARateLimitedToggleRevertsWithTheRateLimitCopy() async {
        let model = EngagementModel(service: ScriptedEngagement(snapshots: [.success(snap())], toggle: .failure(AccountError.rateLimited)))
        await model.load()
        await model.setRankingOptIn(false)
        XCTAssertEqual(model.displayedRanking, ranked)
        XCTAssertEqual(model.actionError, "Too many attempts. Please wait a moment and try again.")
    }

    func testASignedOutToggleFlagsTheShell() async {
        let model = EngagementModel(service: ScriptedEngagement(snapshots: [.success(snap())], toggle: .failure(AccountError.signedOut)))
        await model.load()
        await model.setRankingOptIn(false)
        XCTAssertTrue(model.signedOut)
        XCTAssertEqual(model.displayedRanking, ranked)
    }

    func testASecondTapWhileSavingIsIgnored() async {
        let gate = Gate()
        let service = ScriptedEngagement(snapshots: [.success(snap())])
        await service.hold(gate)
        let model = EngagementModel(service: service)
        await model.load()
        let first = Task { await model.setRankingOptIn(false) }
        await gate.waitUntilEntered()
        await model.setRankingOptIn(true)
        await gate.release()
        await first.value
        let toggles = await service.toggles
        XCTAssertEqual(toggles, [false])
    }

    func testToggleWithoutALoadedSnapshotDoesNothing() async {
        let service = ScriptedEngagement(snapshots: [.success(snap())])
        let model = EngagementModel(service: service)
        await model.setRankingOptIn(false)
        let toggles = await service.toggles
        XCTAssertTrue(toggles.isEmpty)
    }

    func testARefreshThatFailsKeepsTheContentAndShowsANotice() async {
        let service = ScriptedEngagement(snapshots: [.success(snap()), .failure(AccountError.unavailable)])
        let model = EngagementModel(service: service)
        await model.load()
        await model.load()
        XCTAssertEqual(model.phase, .ready)
        XCTAssertEqual(model.snapshot?.ranking, ranked)
        XCTAssertEqual(model.refreshNotice, "Something went wrong. Please try again.")
        await model.load()
        XCTAssertEqual(model.phase, .ready)
    }

    func testASignedOutLoadFlagsTheShell() async {
        let model = EngagementModel(service: ScriptedEngagement(snapshots: [.failure(AccountError.signedOut)]))
        await model.load()
        XCTAssertTrue(model.signedOut)
        XCTAssertEqual(model.phase, .failed("Please sign in again."))
    }

    func testCancelledLoadKeepsTheContent() async {
        let service = ScriptedEngagement(snapshots: [.success(snap()), .failure(CancellationError())])
        let model = EngagementModel(service: service)
        await model.load()
        await model.load()
        XCTAssertEqual(model.phase, .ready)
        XCTAssertNil(model.refreshNotice)
        XCTAssertNotNil(model.snapshot)
    }

    func testChoosingANameSavesThenReloadsTheInvite() async {
        let service = ScriptedEngagement(snapshots: [.success(snap(referral: nil, needsName: true)),
                                                     .success(snap(referral: ReferralInfo(code: "ALEX42", linkCount: 0, irlCount: 0)))])
        let model = EngagementModel(service: service)
        await model.load()
        XCTAssertEqual(model.snapshot?.needsPublicName, true)
        await model.choosePublicName("  Alex R ")
        let names = await service.names
        XCTAssertEqual(names, ["Alex R"])
        XCTAssertEqual(model.snapshot?.referral?.code, "ALEX42")
        XCTAssertEqual(model.snapshot?.needsPublicName, false)
        XCTAssertNil(model.nameError)
    }

    func testANameThatIsRefusedSaysSoAndKeepsThePrompt() async {
        let service = ScriptedEngagement(snapshots: [.success(snap(referral: nil, needsName: true))])
        await service.setName(.failure(AccountError.invalidInput))
        let model = EngagementModel(service: service)
        await model.load()
        await model.choosePublicName("x")
        XCTAssertEqual(model.nameError, "That name can’t be used. Try another.")
        XCTAssertEqual(model.snapshot?.needsPublicName, true)
        XCTAssertFalse(model.isSavingName)
    }

    func testAnEmptyOrTooLongNameNeverReachesTheService() async {
        let service = ScriptedEngagement(snapshots: [.success(snap(referral: nil, needsName: true))])
        let model = EngagementModel(service: service)
        await model.load()
        for name in ["", "   ", String(repeating: "a", count: 81)] {
            await model.choosePublicName(name)
            XCTAssertEqual(model.nameError, "Enter a name between 1 and 80 characters.")
        }
        let names = await service.names
        XCTAssertTrue(names.isEmpty)
    }
}

@MainActor
final class InitiativeSpendModelTests: XCTestCase {
    private let summary = InitiativeSpendSummary(initiativeID: "i", totalMinor: 125_000, slices: [SpendSlice(category: "Food", amountMinor: 90_000)])

    func testLoadsTheSpend() async {
        let service = ScriptedEngagement(snapshots: [.success(snap())])
        await service.setSpend(.success(summary))
        let model = InitiativeSpendModel(service: service, initiativeID: "i")
        await model.load()
        XCTAssertEqual(model.phase, .ready(summary))
    }

    func testANotFoundSpendIsUnpublishedNotAnError() async {
        let service = ScriptedEngagement(snapshots: [.success(snap())])
        await service.setSpend(.failure(AccountError.notFound))
        let model = InitiativeSpendModel(service: service, initiativeID: "i")
        await model.load()
        XCTAssertEqual(model.phase, .unpublished)
    }

    func testAFailureThenARetryRecovers() async {
        let service = ScriptedEngagement(snapshots: [.success(snap())])
        await service.setSpend(.failure(AccountError.rateLimited))
        let model = InitiativeSpendModel(service: service, initiativeID: "i")
        await model.load()
        XCTAssertEqual(model.phase, .failed("Too many attempts. Please wait a moment and try again."))
        await service.setSpend(.success(summary))
        await model.load()
        XCTAssertEqual(model.phase, .ready(summary))
    }

    func testCancellationKeepsThePriorStateAndAFailedRefreshKeepsTheSpend() async {
        let service = ScriptedEngagement(snapshots: [.success(snap())])
        await service.setSpend(.success(summary))
        let model = InitiativeSpendModel(service: service, initiativeID: "i")
        await model.load()
        await service.setSpend(.failure(CancellationError()))
        await model.load()
        XCTAssertEqual(model.phase, .ready(summary))
        await service.setSpend(.failure(AccountError.unavailable))
        await model.load()
        XCTAssertEqual(model.phase, .ready(summary), "a failed refresh does not blank figures already on screen")
    }

    func testSignedOutFlagsTheShell() async {
        let service = ScriptedEngagement(snapshots: [.success(snap())])
        await service.setSpend(.failure(AccountError.signedOut))
        let model = InitiativeSpendModel(service: service, initiativeID: "i")
        await model.load()
        XCTAssertTrue(model.signedOut)
    }

    func testSpendLabelsUseTheMoneyFormatter() {
        XCTAssertEqual(summary.totalLabel, "$1,250")
        XCTAssertEqual(summary.slices.first?.amountLabel, "$900")
        XCTAssertEqual(InitiativeSpendSummary(initiativeID: "i", totalMinor: 1_234_56, slices: []).totalLabel, "$1,234.56")
    }
}
