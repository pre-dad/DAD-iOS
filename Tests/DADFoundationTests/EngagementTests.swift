import Foundation
import XCTest
@testable import DADFoundation

// MARK: - Badges (B-1..B-4), a11y not colour-only

final class BadgeTests: XCTestCase {
    func testEarnedAndLockedAccessibilityLabelsCarryState() {
        let earned = Badge(code: "F", title: "Founding Donor", rule: "Join in year one", perk: "Invite-only events", earned: true)
        let locked = Badge(code: "7", title: "One Week", rule: "Reach a 7-day streak", perk: "—", earned: false)
        // State is in the text, never colour alone.
        XCTAssertEqual(earned.accessibilityLabel, "Founding Donor, earned")
        XCTAssertEqual(locked.accessibilityLabel, "One Week, locked. Reach a 7-day streak")
    }

    func testPerkGatingUnlocksOnlyForEarnedGatingBadges() {
        XCTAssertTrue(Badge(code: "F", title: "", rule: "", perk: "", earned: true).unlocksInviteOnlyEvents)
        XCTAssertTrue(Badge(code: "TC", title: "", rule: "", perk: "", earned: true).unlocksInviteOnlyEvents)
        // Earned but not a gating badge → no unlock.
        XCTAssertFalse(Badge(code: "7", title: "", rule: "", perk: "", earned: true).unlocksInviteOnlyEvents)
        // Gating badge but not earned → no unlock.
        XCTAssertFalse(Badge(code: "F", title: "", rule: "", perk: "", earned: false).unlocksInviteOnlyEvents)
    }

    func testPerkGatingUsesServerCatalogCodes() {
        XCTAssertEqual(Badge.perkGatingCodes, ["F", "1K", "TC"])
        for code in ["founding", "milestone_1000", "team_captain", "7", "REF3"] {
            XCTAssertFalse(Badge(code: code, title: "", rule: "", perk: "", earned: true).unlocksInviteOnlyEvents, code)
        }
        XCTAssertTrue(Badge(code: "1K", title: "1,000 Days", rule: "", perk: "", earned: true).unlocksInviteOnlyEvents)
    }

    func testCollectionSummaryAndInviteOnlyAccess() {
        let collection = BadgeCollection(badges: [
            Badge(code: "F", title: "Founding", rule: "", perk: "", earned: true),
            Badge(code: "7", title: "Streak", rule: "", perk: "", earned: true),
            Badge(code: "1K", title: "1000", rule: "", perk: "", earned: false),
        ])
        XCTAssertEqual(collection.earnedCount, 2)
        XCTAssertEqual(collection.total, 3)
        XCTAssertEqual(collection.summaryLabel, "2 of 3 earned")
        XCTAssertTrue(collection.hasInviteOnlyAccess) // founding is earned
    }

    func testNoInviteOnlyAccessWhenGatingBadgesLocked() {
        let collection = BadgeCollection(badges: [
            Badge(code: "F", title: "", rule: "", perk: "", earned: false),
            Badge(code: "7", title: "", rule: "", perk: "", earned: true),
        ])
        XCTAssertFalse(collection.hasInviteOnlyAccess)
    }
}

// MARK: - Rankings (K-1..K-3), opt-out hides self

final class RankingTests: XCTestCase {
    func testOptedOutShowsNoPosition() {
        let standing = RankingStanding(nationalPercentile: nil, city: nil, cityRank: nil, rankingsOptedOut: true)
        XCTAssertTrue(standing.isOptedOut)
        XCTAssertNil(standing.nationalLabel)
        XCTAssertNil(standing.cityLabel)
    }

    func testOptedInButUnrankedIsNotOptedOut() {
        let standing = RankingStanding(nationalPercentile: nil, city: nil, cityRank: nil, rankingsOptedOut: false)
        XCTAssertFalse(standing.isOptedOut)
        XCTAssertTrue(standing.isNotRankedYet)
        XCTAssertNil(standing.nationalLabel)
        let hidden = RankingStanding(nationalPercentile: nil, city: nil, cityRank: nil, rankingsOptedOut: true)
        XCTAssertTrue(hidden.isOptedOut)
        XCTAssertFalse(hidden.isNotRankedYet)
    }

    func testOptedOutWinsEvenWithStalePercentile() {
        XCTAssertTrue(RankingStanding(nationalPercentile: 90, city: "Austin", cityRank: 2, rankingsOptedOut: true).isOptedOut)
    }

    func testPercentileRendersAsTopShare() {
        // The server's `national_percentile` is already the top bucket (1 = top 1%), so 95 reads "Top 95%".
        let standing = RankingStanding(nationalPercentile: 95, city: "Austin", cityRank: 3)
        XCTAssertFalse(standing.isOptedOut)
        XCTAssertEqual(standing.nationalLabel, "Top 95% nationally")
        XCTAssertEqual(standing.cityLabel, "#3 in Austin")
    }

    func testCityLabelAbsentWithoutCityOrRank() {
        XCTAssertNil(RankingStanding(nationalPercentile: 50, city: nil, cityRank: 4).cityLabel)
        XCTAssertNil(RankingStanding(nationalPercentile: 50, city: "Reno", cityRank: nil).cityLabel)
    }
}

// MARK: - Impact (I-1..I-3), unknown total is not $0

final class ImpactTests: XCTestCase {
    func testKnownTotalFormats() {
        XCTAssertEqual(ImpactTotals(givenMinor: 124000, initiativesFunded: 3, eventsVolunteered: 2).givenLabel, "$1,240")
    }
    func testUnknownTotalShowsDashNotZero() {
        XCTAssertEqual(ImpactTotals(givenMinor: nil, initiativesFunded: 0, eventsVolunteered: 0).givenLabel, "—")
    }
}

// MARK: - Referral + QR (R-1..R-4)

final class ReferralQRTests: XCTestCase {
    func testInviteURLAndShareMessageCarryCode() {
        let referral = ReferralInfo(code: "SHAWN42", linkCount: 3, irlCount: 1)
        XCTAssertEqual(referral.totalConverted, 4)
        XCTAssertEqual(referral.inviteURL()?.absoluteString, "https://dollaraday.org/r/SHAWN42")
        XCTAssertEqual(referral.irlURL()?.absoluteString, "https://dollaraday.org/r/SHAWN42?via=irl")
        XCTAssertTrue(referral.shareMessage().contains("/r/SHAWN42"))
    }

    func testInviteURLUsesTheInjectedOrigin() {
        let referral = ReferralInfo(code: "SHAWN42", linkCount: 0, irlCount: 0)
        XCTAssertEqual(referral.inviteURL(host: "https://staging.example.org")?.absoluteString,
                       "https://staging.example.org/r/SHAWN42")
        XCTAssertTrue(referral.shareMessage(host: "https://staging.example.org").hasSuffix("https://staging.example.org/r/SHAWN42"))
        XCTAssertNil(referral.inviteURL(host: nil))
        XCTAssertFalse(referral.shareMessage(host: nil).contains("http"))
    }

    func testPublicOriginResolution() {
        XCTAssertEqual(PublicOrigin.resolve("https://staging.example.org"), "https://staging.example.org")
        XCTAssertNil(PublicOrigin.resolve("http://insecure.example.org"))
        XCTAssertNil(PublicOrigin.resolve("https://example.org/path"))
        #if DEBUG
        XCTAssertEqual(PublicOrigin.resolve(nil), "https://dollaraday.org")
        XCTAssertEqual(PublicOrigin.resolve(""), "https://dollaraday.org")
        #else
        XCTAssertNil(PublicOrigin.resolve(nil))
        #endif
    }

    func testQREncodeDecodeRoundTrip() {
        let url = ReferralInfo(code: "ABC123", linkCount: 0, irlCount: 0).inviteURL()!.absoluteString
        let payload = QRPayload(url)
        let roundTripped = QRPayload.decode(payload.encoded())
        XCTAssertEqual(roundTripped, payload)
        XCTAssertEqual(roundTripped?.referralCode, "ABC123")
    }

    func testDecodeTrimsWhitespaceAndRejectsEmpty() {
        XCTAssertEqual(QRPayload.decode("  hello \n")?.payload, "hello")
        XCTAssertNil(QRPayload.decode("   \n "))
    }

    func testReferralCodeNilForNonInviteQR() {
        XCTAssertNil(QRPayload("https://example.com/other").referralCode)
        XCTAssertNil(QRPayload("just some text").referralCode)
    }

    func testReferralCodeRejectsMalformedCodes() {
        XCTAssertNil(QRPayload("https://dollaraday.org/join?ref=").referralCode)
        XCTAssertNil(QRPayload("https://dollaraday.org/join?ref=a%20b").referralCode)
        XCTAssertNil(QRPayload("https://dollaraday.org/join?ref=%3Cscript%3E").referralCode)
        XCTAssertNil(QRPayload("https://dollaraday.org/join?ref=\(String(repeating: "A", count: 65))").referralCode)
        XCTAssertEqual(QRPayload("https://dollaraday.org/join?ref=ABC_123-x").referralCode, "ABC_123-x")
    }
}

// MARK: - EngagementModel state machine

private struct StubEngagementService: EngagementService {
    let snapshotResult: EngagementSnapshot
    var failSnapshot = false
    var optInResult: RankingStanding = RankingStanding(nationalPercentile: nil, city: nil, cityRank: nil, rankingsOptedOut: true)
    var snapshotError: Error?
    var optInError: Error?

    func snapshot() async throws -> EngagementSnapshot {
        if let snapshotError { throw snapshotError }
        if failSnapshot { throw AccountError.signedOut }
        return snapshotResult
    }
    func setRankingOptIn(_ optIn: Bool) async throws -> RankingStanding {
        if let optInError { throw optInError }
        return optInResult
    }
    var nameError: Error?
    var spendResult: InitiativeSpendSummary = InitiativeSpendSummary(initiativeID: "i", totalMinor: 0, slices: [])
    var spendError: Error?
    func choosePublicName(_ name: String) async throws { if let nameError { throw nameError } }
    func initiativeSpend(id: String) async throws -> InitiativeSpendSummary {
        if let spendError { throw spendError }
        return spendResult
    }
}

private func sampleSnapshot(ranking: RankingStanding) -> EngagementSnapshot {
    EngagementSnapshot(
        impact: ImpactTotals(givenMinor: 30000, initiativesFunded: 2, eventsVolunteered: 1),
        badges: BadgeCollection(badges: [Badge(code: "F", title: "Founding", rule: "", perk: "", earned: true)]),
        ranking: ranking,
        network: NetworkSummary(activeCount: 4, annualizedMinor: 48000, anonymousActive: 1),
        referral: ReferralInfo(code: "SHAWN42", linkCount: 2, irlCount: 2)
    )
}

@MainActor
final class EngagementModelTests: XCTestCase {
    func testLoadReady() async {
        let model = EngagementModel(service: StubEngagementService(snapshotResult: sampleSnapshot(ranking: RankingStanding(nationalPercentile: 90, city: "Austin", cityRank: 5))))
        await model.load()
        XCTAssertEqual(model.phase, .ready)
        XCTAssertEqual(model.snapshot?.badges?.earnedCount, 1)
        XCTAssertEqual(model.snapshot?.ranking?.nationalLabel, "Top 90% nationally")
    }

    func testLoadFailureSurfacesSignedOut() async {
        let model = EngagementModel(service: StubEngagementService(snapshotResult: sampleSnapshot(ranking: .init(nationalPercentile: nil, city: nil, cityRank: nil)), failSnapshot: true))
        await model.load()
        XCTAssertEqual(model.phase, .failed("Please sign in again."))
    }

    func testOptingOutReplacesRankingWithNoPosition() async {
        let service = StubEngagementService(
            snapshotResult: sampleSnapshot(ranking: RankingStanding(nationalPercentile: 90, city: "Austin", cityRank: 5)),
            optInResult: RankingStanding(nationalPercentile: nil, city: nil, cityRank: nil, rankingsOptedOut: true)
        )
        let model = EngagementModel(service: service)
        await model.load()
        XCTAssertEqual(model.snapshot?.ranking?.isOptedOut, false)
        await model.setRankingOptIn(false)
        XCTAssertEqual(model.snapshot?.ranking?.isOptedOut, true) // self hidden
        XCTAssertEqual(model.phase, .ready)
    }

    func testFailedToggleKeepsScreenAndRankingAndShowsInlineError() async {
        let ranked = RankingStanding(nationalPercentile: 90, city: "Austin", cityRank: 5)
        var service = StubEngagementService(snapshotResult: sampleSnapshot(ranking: ranked))
        service.optInError = AccountError.unavailable
        let model = EngagementModel(service: service)
        await model.load()
        await model.setRankingOptIn(false)
        XCTAssertEqual(model.phase, .ready, "a failed toggle must not replace the screen with the error state")
        XCTAssertEqual(model.snapshot?.ranking, ranked, "the toggle reverts to the prior ranking")
        XCTAssertEqual(model.actionError, "Something went wrong. Please try again.")
    }

    func testCancelledToggleIsNotAFailure() async {
        var service = StubEngagementService(snapshotResult: sampleSnapshot(ranking: RankingStanding(nationalPercentile: 90, city: "Austin", cityRank: 5)))
        service.optInError = CancellationError()
        let model = EngagementModel(service: service)
        await model.load()
        await model.setRankingOptIn(false)
        XCTAssertEqual(model.phase, .ready)
        XCTAssertNil(model.actionError)
    }

    func testACancelledFirstLoadIsNeitherReadyNorFailed() async {
        for cancellation in [URLError(.cancelled) as Error, CancellationError()] {
            var service = StubEngagementService(snapshotResult: sampleSnapshot(ranking: RankingStanding(nationalPercentile: 90, city: "Austin", cityRank: 5)))
            service.snapshotError = cancellation
            let model = EngagementModel(service: service)
            await model.load()
            XCTAssertEqual(model.phase, .loading, "abandoned work leaves the screen where it was")
            XCTAssertNil(model.snapshot)
            XCTAssertNil(model.refreshNotice)
        }
    }
}

// MARK: - ScanModel (R-4) attribution

@MainActor
final class ScanModelTests: XCTestCase {
    func testScanningInviteResolvesCode() {
        let model = ScanModel()
        model.ingest("https://dollaraday.org/join?ref=FRIEND9")
        XCTAssertEqual(model.phase, .resolved("FRIEND9"))
    }

    func testScanningNonInviteFails() {
        let model = ScanModel()
        model.ingest("https://example.com/not-us")
        XCTAssertEqual(model.phase, .failed("That QR code isn’t a Dollar A Day invite."))
    }

    func testEmptyScanFails() {
        let model = ScanModel()
        model.ingest("   ")
        XCTAssertEqual(model.phase, .failed("That didn’t scan. Try again."))
    }

    func testResetReturnsToScanning() {
        let model = ScanModel()
        model.ingest("nope")
        model.reset()
        XCTAssertEqual(model.phase, .scanning)
    }
}
