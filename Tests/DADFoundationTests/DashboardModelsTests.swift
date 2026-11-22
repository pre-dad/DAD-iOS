import Foundation
import XCTest
@testable import DADFoundation

/// Scriptable `DashboardService`: each call pops the next scripted result (the last one repeats).
private final class ScriptedDashboard: DashboardService, @unchecked Sendable {
    private let lock = NSLock()
    var dashboards: [Result<DashboardState, Error>] = [.success(.preparing)]
    var initiatives: [Result<TodayInitiative?, Error>] = [.success(nil)]
    var pages: [Int: Result<GiftHistoryPage, Error>] = [:]
    var receipts: [String: Result<GiftReceipt, Error>] = [:]
    var summary: Result<AnnualGivingSummary, Error> = .failure(AccountError.unavailable)
    var pageGate: Gate?
    private(set) var requestedOffsets: [Int] = []
    private var returnedPages = 0
    var pagesReturned: Int { lock.withLock { returnedPages } }

    private func next<T>(_ list: inout [T]) -> T { list.count > 1 ? list.removeFirst() : list[0] }
    func dashboard() async throws -> DashboardState { try lock.withLock { try next(&dashboards).get() } }
    func todayInitiative() async throws -> TodayInitiative? { try lock.withLock { try next(&initiatives).get() } }
    func gifts(offset: Int) async throws -> GiftHistoryPage {
        lock.withLock { requestedOffsets.append(offset) }
        defer { lock.withLock { returnedPages += 1 } }
        if let pageGate { await pageGate.pass() }
        try Task.checkCancellation()
        return try lock.withLock { try (pages[offset] ?? .failure(AccountError.unavailable)).get() }
    }
    func receipt(giftID: String) async throws -> GiftReceipt { try lock.withLock { try (receipts[giftID] ?? .failure(AccountError.invalidInput)).get() } }
    func annualSummary(year: Int) async throws -> AnnualGivingSummary { try lock.withLock { try summary.get() } }
}

private func gift(_ id: String, amount: Int = 3000) -> GiftEntry {
    GiftEntry(id: id, amountMinor: amount, paidAt: Date(timeIntervalSince1970: 1_700_000_000), frequency: .monthly, refundedMinor: 0, netMinor: amount)
}

private let sampleDashboard = DonorDashboard(
    computedAt: Date(), foundingDonor: false, streak: StreakCard(current: 5, atRisk: false, graceEndsAt: nil, ladder: nil),
    rank: .notRankedYet, impact: ImpactTotals(givenMinor: 5000, initiativesFunded: 1, eventsVolunteered: 0), network: nil, referrals: nil)

private let sampleToday = TodayInitiative(id: "i", slug: "s", title: "Meals", summary: "x", location: "Austin", kind: "PROGRAM", startedOn: "2025-01-01", metrics: [])

final class RankingLabelTests: XCTestCase {
    func testBothRankCardsClampAndOmitTheSameWay() {
        XCTAssertEqual(DashboardRank(topPercent: 0, city: nil, cityRank: nil).nationalLabel, "Top 1% nationally")
        XCTAssertEqual(DashboardRank(topPercent: 250, city: nil, cityRank: nil).nationalLabel, "Top 100% nationally")
        XCTAssertEqual(RankingStanding(nationalPercentile: 0, city: nil, cityRank: nil).nationalLabel, "Top 1% nationally")
        XCTAssertEqual(RankingStanding(nationalPercentile: 250, city: nil, cityRank: nil).nationalLabel, "Top 100% nationally")
        XCTAssertNil(RankingStanding(nationalPercentile: nil, city: nil, cityRank: nil).nationalLabel)
        XCTAssertNil(DashboardRank(topPercent: 2, city: "", cityRank: 4).cityLabel)
        XCTAssertNil(RankingStanding(nationalPercentile: 2, city: "", cityRank: 4).cityLabel)
        XCTAssertEqual(RankingStanding(nationalPercentile: 2, city: "Austin", cityRank: 4).cityLabel, "#4 in Austin")
    }
}

@MainActor final class DashboardModelTests: XCTestCase {
    func testLoadShowsDashboardAndInitiative() async {
        let service = ScriptedDashboard()
        service.dashboards = [.success(.ready(sampleDashboard))]
        service.initiatives = [.success(sampleToday)]
        let model = DashboardModel(service: service)
        XCTAssertEqual(model.phase, .loading)
        await model.load()
        XCTAssertEqual(model.phase, .ready(.ready(sampleDashboard)))
        XCTAssertEqual(model.initiative, .ready(sampleToday))
        XCTAssertNil(model.refreshNotice)
    }

    func testPreparingAndNoInitiativeAreFirstClassStates() async {
        let model = DashboardModel(service: ScriptedDashboard())
        await model.load()
        XCTAssertEqual(model.phase, .ready(.preparing))
        XCTAssertEqual(model.initiative, .none)
    }

    func testFirstLoadFailureIsRetryableAndRetryRecovers() async {
        let service = ScriptedDashboard()
        service.dashboards = [.failure(AccountError.unavailable), .success(.ready(sampleDashboard))]
        let model = DashboardModel(service: service)
        await model.load()
        XCTAssertEqual(model.phase, .failed("Something went wrong. Please try again."))
        XCTAssertFalse(model.signedOut)
        await model.load()
        XCTAssertEqual(model.phase, .ready(.ready(sampleDashboard)))
    }

    func testRateLimitUsesTheThrottleMessage() async {
        let service = ScriptedDashboard()
        service.dashboards = [.failure(AccountError.rateLimited)]
        let model = DashboardModel(service: service)
        await model.load()
        XCTAssertEqual(model.phase, .failed("Too many attempts. Please wait a moment and try again."))
    }

    func testFailedRefreshKeepsTheCardsAndShowsANotice() async {
        let service = ScriptedDashboard()
        service.dashboards = [.success(.ready(sampleDashboard)), .failure(AccountError.unavailable)]
        service.initiatives = [.success(sampleToday), .failure(AccountError.unavailable)]
        let model = DashboardModel(service: service)
        await model.load()
        await model.load()
        XCTAssertEqual(model.phase, .ready(.ready(sampleDashboard)), "stale data beats an error screen")
        XCTAssertEqual(model.initiative, .ready(sampleToday))
        XCTAssertNotNil(model.refreshNotice)
    }

    func testCancellationKeepsPriorStateWithNoNotice() async {
        let service = ScriptedDashboard()
        service.dashboards = [.success(.ready(sampleDashboard)), .failure(CancellationError())]
        let model = DashboardModel(service: service)
        await model.load()
        await model.load()
        XCTAssertEqual(model.phase, .ready(.ready(sampleDashboard)))
        XCTAssertNil(model.refreshNotice)
        let fresh = DashboardModel(service: { let s = ScriptedDashboard(); s.dashboards = [.failure(URLError(.cancelled))]; return s }())
        await fresh.load()
        XCTAssertEqual(fresh.phase, .loading, "a cancelled first load is not a failure")
    }

    func testSignedOutIsReportedSoTheShellCanRoute() async {
        let service = ScriptedDashboard()
        service.dashboards = [.failure(AccountError.signedOut)]
        let model = DashboardModel(service: service)
        await model.load()
        XCTAssertTrue(model.signedOut)
    }

    func testInitiativeFailureDoesNotHideTheDashboard() async {
        let service = ScriptedDashboard()
        service.dashboards = [.success(.ready(sampleDashboard))]
        service.initiatives = [.failure(AccountError.unavailable)]
        let model = DashboardModel(service: service)
        await model.load()
        XCTAssertEqual(model.phase, .ready(.ready(sampleDashboard)))
        XCTAssertEqual(model.initiative, .failed)
    }
}

/// Lets the model's continuation after a returned service call run before the test asserts.
@MainActor private func settle() async { for _ in 0..<10 { await Task.yield() } }

@MainActor final class GiftHistoryModelTests: XCTestCase {
    private func make(_ service: ScriptedDashboard) -> GiftHistoryModel { GiftHistoryModel(service: service, year: 2026) }

    func testFirstPageThenContinueUntilTheEnd() async {
        let service = ScriptedDashboard()
        service.pages = [0: .success(GiftHistoryPage(gifts: [gift("a"), gift("b")], nextOffset: 2)),
                         2: .success(GiftHistoryPage(gifts: [gift("c")], nextOffset: nil))]
        let model = make(service)
        await model.load()
        XCTAssertEqual(model.gifts.map(\.id), ["a", "b"])
        XCTAssertTrue(model.hasMore)
        model.requestMore()
        await waitUntil { !model.isLoadingMore }
        XCTAssertEqual(model.gifts.map(\.id), ["a", "b", "c"])
        XCTAssertFalse(model.hasMore)
        model.requestMore()
        XCTAssertEqual(service.requestedOffsets, [0, 2], "no request past the last page")
    }

    func testEmptyHistory() async {
        let service = ScriptedDashboard()
        service.pages = [0: .success(GiftHistoryPage(gifts: [], nextOffset: nil))]
        let model = make(service)
        await model.load()
        XCTAssertTrue(model.isEmpty)
        XCTAssertFalse(model.hasMore)
    }

    func testFirstPageFailureThenRetry() async {
        let service = ScriptedDashboard()
        let model = make(service)
        await model.load()
        XCTAssertEqual(model.phase, .failed("Something went wrong. Please try again."))
        service.pages = [0: .success(GiftHistoryPage(gifts: [gift("a")], nextOffset: nil))]
        await model.load()
        XCTAssertEqual(model.phase, .ready)
        XCTAssertEqual(model.gifts.count, 1)
    }

    func testFailedNextPageKeepsRowsAndCanRetry() async {
        let service = ScriptedDashboard()
        service.pages = [0: .success(GiftHistoryPage(gifts: [gift("a")], nextOffset: 1)), 1: .failure(AccountError.rateLimited)]
        let model = make(service)
        await model.load()
        model.requestMore()
        await waitUntil { !model.isLoadingMore }
        XCTAssertEqual(model.gifts.map(\.id), ["a"])
        XCTAssertEqual(model.moreError, "Too many attempts. Please wait a moment and try again.")
        XCTAssertTrue(model.hasMore)
        service.pages[1] = .success(GiftHistoryPage(gifts: [gift("b")], nextOffset: nil))
        model.requestMore()
        await waitUntil { !model.isLoadingMore }
        XCTAssertEqual(model.gifts.map(\.id), ["a", "b"])
        XCTAssertNil(model.moreError)
    }

    func testDuplicateRowsAcrossPagesAreDropped() async {
        let service = ScriptedDashboard()
        service.pages = [0: .success(GiftHistoryPage(gifts: [gift("a"), gift("b")], nextOffset: 2)),
                         2: .success(GiftHistoryPage(gifts: [gift("b"), gift("c")], nextOffset: nil))]
        let model = make(service)
        await model.load()
        model.requestMore()
        await waitUntil { !model.isLoadingMore }
        XCTAssertEqual(model.gifts.map(\.id), ["a", "b", "c"])
    }

    func testAServerOffsetThatDoesNotAdvanceEndsPaginationInsteadOfLooping() async {
        let service = ScriptedDashboard()
        service.pages = [0: .success(GiftHistoryPage(gifts: [gift("a")], nextOffset: 0))]
        let model = make(service)
        await model.load()
        XCTAssertFalse(model.hasMore)
    }

    func testMemoryIsBoundedAtMaxRows() async {
        let service = ScriptedDashboard()
        let rows = (0..<GiftHistoryModel.maxRows + 50).map { gift("g\($0)") }
        service.pages = [0: .success(GiftHistoryPage(gifts: rows, nextOffset: rows.count))]
        let model = make(service)
        await model.load()
        XCTAssertEqual(model.gifts.count, GiftHistoryModel.maxRows)
        XCTAssertFalse(model.hasMore)
        XCTAssertTrue(model.reachedLimit)
        model.requestMore()
        XCTAssertEqual(service.requestedOffsets, [0])
    }

    func testCancelStopsAPageInFlightAndKeepsLoadedRows() async {
        let service = ScriptedDashboard()
        service.pages = [0: .success(GiftHistoryPage(gifts: [gift("a")], nextOffset: 1)), 1: .success(GiftHistoryPage(gifts: [gift("b")], nextOffset: nil))]
        let model = make(service)
        await model.load()
        let gate = Gate()
        service.pageGate = gate
        model.requestMore()
        await gate.waitUntilEntered()
        model.cancel()
        await gate.release()
        await waitUntil { service.pagesReturned == 2 }
        await settle()
        XCTAssertEqual(model.gifts.map(\.id), ["a"], "a cancelled page must not append")
        XCTAssertFalse(model.isLoadingMore)
        XCTAssertNil(model.moreError, "cancellation is not an error")
    }

    func testReloadDiscardsAStalePageInFlight() async {
        let service = ScriptedDashboard()
        service.pages = [0: .success(GiftHistoryPage(gifts: [gift("a")], nextOffset: 1)), 1: .success(GiftHistoryPage(gifts: [gift("stale")], nextOffset: nil))]
        let model = make(service)
        await model.load()
        let gate = Gate()
        service.pageGate = gate
        model.requestMore()
        await gate.waitUntilEntered()
        service.pageGate = nil
        service.pages[0] = .success(GiftHistoryPage(gifts: [gift("fresh")], nextOffset: nil))
        await model.load()
        await gate.release()
        await waitUntil { service.pagesReturned == 3 }
        await settle()
        XCTAssertEqual(model.gifts.map(\.id), ["fresh"])
    }

    func testAnnualSummaryIsBestEffort() async {
        let service = ScriptedDashboard()
        service.pages = [0: .success(GiftHistoryPage(gifts: [gift("a")], nextOffset: nil))]
        let model = make(service)
        await model.load()
        XCTAssertNil(model.summary, "a failed summary read never blocks the list")
        service.summary = .success(AnnualGivingSummary(year: 2026, giftCount: 1, amountMinor: 3000, refundedMinor: 0, netMinor: 3000, taxReceipt: false))
        await model.load()
        XCTAssertEqual(model.summary?.netMinor, 3000)
    }

    func testSignedOutOnFirstPageIsReported() async {
        let service = ScriptedDashboard()
        service.pages = [0: .failure(AccountError.signedOut)]
        let model = make(service)
        await model.load()
        XCTAssertTrue(model.signedOut)
    }

    func testReceiptLoadsFailsAndHides() async {
        let service = ScriptedDashboard()
        let record = GiftReceipt(gift: gift("a"), refunds: [], taxReceipt: false, asOf: Date())
        service.receipts = ["a": .success(record)]
        let model = make(service)
        await model.showReceipt(giftID: "a")
        XCTAssertEqual(model.receipt, .ready(record))
        await model.showReceipt(giftID: "zzz")
        XCTAssertEqual(model.receipt, .failed("zzz", "Something went wrong. Please try again."))
        model.hideReceipt()
        XCTAssertNil(model.receipt)
    }
}

final class MilestoneLineTests: XCTestCase {
    func testEachMilestoneSaysWhatItReached() {
        XCTAssertEqual(milestoneLine(days: 7), "7 days. A full week of aid, on the record.")
        XCTAssertEqual(milestoneLine(days: 30), "30 days. That’s a month of aid, on the record.")
        XCTAssertEqual(milestoneLine(days: 100), "100 days. Triple digits, on the record.")
        XCTAssertEqual(milestoneLine(days: 365), "365 days. A full year of aid, on the record.")
        XCTAssertEqual(milestoneLine(days: 500), "500 days. Every one on the record.")
        XCTAssertEqual(milestoneLine(days: 1_095), "1095 days. Every one on the record.")
    }
}
