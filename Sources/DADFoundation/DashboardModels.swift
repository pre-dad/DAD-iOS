import Foundation

// Donor home reads (PRD S-1..S-4, A-1..A-5, I-1..I-3, §6.1 gift history): the dashboard card set,
// today's initiative, paginated gift history, a gift record and a calendar-year summary. Pure value
// types and models; the network sits behind `DashboardService`. Money is integer USD minor units
// (int64 on the wire) formatted only by `formatUSDMinor`. Nothing here logs.

// MARK: - Dashboard

/// The 30-day streak card ladder (S-2/S-3). `bar` has one segment per day of the current window.
public struct StreakLadder: Sendable, Equatable {
    public let days: Int
    public let lastMilestone: Int
    public let nextMilestone: Int?
    public let daysToNext: Int?
    public let bar: [Bool]
    public init(days: Int, lastMilestone: Int, nextMilestone: Int?, daysToNext: Int?, bar: [Bool]) {
        self.days = days; self.lastMilestone = lastMilestone; self.nextMilestone = nextMilestone
        self.daysToNext = daysToNext; self.bar = bar
    }
    /// "12 days to your 30-day milestone", or nil past the last known milestone.
    public var nextLabel: String? {
        guard let next = nextMilestone, let to = daysToNext else { return nil }
        return "\(to) \(to == 1 ? "day" : "days") to your \(next)-day milestone"
    }
}

/// The celebration line for a streak milestone (S-3), worded as on Android: the first milestones have
/// their own lines, and every later one counts its days.
public func milestoneLine(days: Int) -> String {
    switch days {
    case 7: "7 days. A full week of aid, on the record."
    case 30: "30 days. That’s a month of aid, on the record."
    case 100: "100 days. Triple digits, on the record."
    case 365: "365 days. A full year of aid, on the record."
    default: "\(days) days. Every one on the record."
    }
}

public struct StreakCard: Sendable, Equatable {
    public let current: Int
    /// A renewal failed and the donor is inside the 7-day grace period (S-1).
    public let atRisk: Bool
    public let graceEndsAt: Date?
    public let ladder: StreakLadder?
    public init(current: Int, atRisk: Bool, graceEndsAt: Date?, ladder: StreakLadder?) {
        self.current = current; self.atRisk = atRisk; self.graceEndsAt = graceEndsAt; self.ladder = ladder
    }
    public var headline: String { "\(current)-day streak" }
}

/// The donor's own standing (S-4). `nationalPercentile` is the server's *top* bucket: 2 means
/// "Top 2%" (the PRD example), the opposite sense of a conventional percentile.
public struct DashboardRank: Sendable, Equatable {
    public let topPercent: Int
    public let city: String?
    public let cityRank: Int?
    public init(topPercent: Int, city: String?, cityRank: Int?) {
        self.topPercent = topPercent; self.city = city; self.cityRank = cityRank
    }
    public var nationalLabel: String { "Top \(max(1, topPercent))% nationally" }
    public var cityLabel: String? {
        guard let city, !city.isEmpty, let rank = cityRank else { return nil }
        return "#\(rank) in \(city)"
    }
}

/// What the rank line shows. Opted out is the explicit server flag, distinct from "opted in but not
/// ranked yet" (null rank with the flag false); neither shows a position or a zero.
public enum RankLine: Sendable, Equatable {
    case ranked(DashboardRank)
    case notRankedYet
    case optedOut
}

public struct ReferralTotals: Sendable, Equatable {
    public let link: Int
    public let irl: Int
    public let totalMinor: Int
    public init(link: Int, irl: Int, totalMinor: Int) { self.link = link; self.irl = irl; self.totalMinor = totalMinor }
    public var joined: Int { link + irl }
    public var totalLabel: String { formatUSDMinor(totalMinor) }
}

/// The ready dashboard. `streak`, `referrals` and `network` are nil when the server says the figure is
/// not currently known (or, for the network, the donor has no active referrals): never rendered as zero.
public struct DonorDashboard: Sendable, Equatable {
    public let computedAt: Date
    public let foundingDonor: Bool
    public let streak: StreakCard?
    public let rank: RankLine
    public let impact: ImpactTotals
    public let network: NetworkSummary?
    public let referrals: ReferralTotals?
    public init(computedAt: Date, foundingDonor: Bool, streak: StreakCard?, rank: RankLine, impact: ImpactTotals,
                network: NetworkSummary?, referrals: ReferralTotals?) {
        self.computedAt = computedAt; self.foundingDonor = foundingDonor; self.streak = streak
        self.rank = rank; self.impact = impact; self.network = network; self.referrals = referrals
    }
}

/// `preparing` is a normal server answer for a brand-new donor whose figures are not computed yet.
public enum DashboardState: Sendable, Equatable {
    case preparing
    case ready(DonorDashboard)
}

// MARK: - Today's initiative

public struct InitiativeMetric: Sendable, Equatable, Identifiable {
    public enum Unit: String, Sendable, Equatable { case usdCents = "USD_CENTS", people = "PEOPLE", initiatives = "INITIATIVES", partners = "PARTNERS" }
    public let label: String
    public let value: Int
    public let unit: Unit?
    public let verifiedOn: String
    public var id: String { label }
    public init(label: String, value: Int, unit: Unit?, verifiedOn: String) {
        self.label = label; self.value = value; self.unit = unit; self.verifiedOn = verifiedOn
    }
    public var valueLabel: String {
        switch unit {
        case .usdCents: return formatUSDMinor(value)
        case .people: return "\(value) \(value == 1 ? "person" : "people")"
        case .initiatives: return "\(value) \(value == 1 ? "initiative" : "initiatives")"
        case .partners: return "\(value) \(value == 1 ? "partner" : "partners")"
        case nil: return "\(value)"
        }
    }
}

public struct TodayInitiative: Sendable, Equatable {
    public let id: String
    public let slug: String
    public let title: String
    public let summary: String
    public let location: String
    public let kind: String
    public let startedOn: String
    public let metrics: [InitiativeMetric]
    public init(id: String, slug: String, title: String, summary: String, location: String, kind: String,
                startedOn: String, metrics: [InitiativeMetric]) {
        self.id = id; self.slug = slug; self.title = title; self.summary = summary; self.location = location
        self.kind = kind; self.startedOn = startedOn; self.metrics = metrics
    }
    /// A-2: up to four headline metrics.
    public var headlineMetrics: [InitiativeMetric] { Array(metrics.prefix(4)) }
    /// A-5: display attribution, not designated giving. Counsel owns the final wording.
    public static let attributionNote = "This shows where today’s rotation points. All gifts are unrestricted."
}

// MARK: - Gifts

public struct GiftEntry: Sendable, Equatable, Identifiable {
    public enum Frequency: String, Sendable, Equatable { case monthly = "MONTHLY", oneTime = "ONE_TIME" }
    public let id: String
    public let amountMinor: Int
    public let paidAt: Date
    public let frequency: Frequency
    public let refundedMinor: Int
    public let netMinor: Int
    public init(id: String, amountMinor: Int, paidAt: Date, frequency: Frequency, refundedMinor: Int, netMinor: Int) {
        self.id = id; self.amountMinor = amountMinor; self.paidAt = paidAt; self.frequency = frequency
        self.refundedMinor = refundedMinor; self.netMinor = netMinor
    }
    public var amountLabel: String { formatUSDMinor(amountMinor) }
    public var netLabel: String { formatUSDMinor(netMinor) }
    public var refundLabel: String? { refundedMinor > 0 ? "\(formatUSDMinor(refundedMinor)) refunded" : nil }
    public var frequencyLabel: String { frequency == .monthly ? "Monthly" : "One-time" }
}

public struct GiftHistoryPage: Sendable, Equatable {
    public let gifts: [GiftEntry]
    /// Offset to request next, nil on the last page.
    public let nextOffset: Int?
    public init(gifts: [GiftEntry], nextOffset: Int?) { self.gifts = gifts; self.nextOffset = nextOffset }
}

public struct RefundEntry: Sendable, Equatable, Identifiable {
    public let id: String
    public let amountMinor: Int
    public let status: String
    public let observedAt: Date
    public init(id: String, amountMinor: Int, status: String, observedAt: Date) {
        self.id = id; self.amountMinor = amountMinor; self.status = status; self.observedAt = observedAt
    }
}

/// A gift record with its refunds. Sandbox records are not tax receipts (G-11): the flag is carried
/// so the screen can say so rather than assume it.
public struct GiftReceipt: Sendable, Equatable {
    public let gift: GiftEntry
    public let refunds: [RefundEntry]
    public let taxReceipt: Bool
    public let asOf: Date
    public init(gift: GiftEntry, refunds: [RefundEntry], taxReceipt: Bool, asOf: Date) {
        self.gift = gift; self.refunds = refunds; self.taxReceipt = taxReceipt; self.asOf = asOf
    }
}

public struct AnnualGivingSummary: Sendable, Equatable {
    public let year: Int
    public let giftCount: Int
    public let amountMinor: Int
    public let refundedMinor: Int
    public let netMinor: Int
    public let taxReceipt: Bool
    public init(year: Int, giftCount: Int, amountMinor: Int, refundedMinor: Int, netMinor: Int, taxReceipt: Bool) {
        self.year = year; self.giftCount = giftCount; self.amountMinor = amountMinor
        self.refundedMinor = refundedMinor; self.netMinor = netMinor; self.taxReceipt = taxReceipt
    }
    public var netLabel: String { formatUSDMinor(netMinor) }
}

// MARK: - Service seam

/// The donor-home read seam. `todayInitiative` answers nil for a 404 (nothing in rotation today).
public protocol DashboardService: Sendable {
    func dashboard() async throws -> DashboardState
    func todayInitiative() async throws -> TodayInitiative?
    func gifts(offset: Int) async throws -> GiftHistoryPage
    func receipt(giftID: String) async throws -> GiftReceipt
    func annualSummary(year: Int) async throws -> AnnualGivingSummary
}

// MARK: - Dashboard model

/// Drives the donor home cards. A refresh that fails or is cancelled keeps the cards already on
/// screen (a notice explains a failed one); only a first load with nothing to show becomes `.failed`.
@MainActor
@Observable
public final class DashboardModel {
    public enum Phase: Sendable, Equatable {
        case loading
        case ready(DashboardState)
        case failed(String)
    }
    public enum InitiativePhase: Sendable, Equatable {
        case loading
        case none
        case ready(TodayInitiative)
        case failed
    }

    public private(set) var phase: Phase = .loading
    public private(set) var initiative: InitiativePhase = .loading
    /// Shown above stale cards when a refresh failed.
    public private(set) var refreshNotice: String?
    /// The session ended (a refresh was refused twice): the shell must route to sign-in.
    public private(set) var signedOut = false

    private let service: any DashboardService
    private var generation = 0

    public init(service: any DashboardService) { self.service = service }

    public func load() async {
        generation += 1
        let current = generation
        let priorPhase = phase
        let priorInitiative = initiative
        if case .ready = phase {} else { phase = .loading }
        if case .ready = initiative {} else { initiative = .loading }
        refreshNotice = nil
        async let dashboardResult = Self.capture { try await self.service.dashboard() }
        async let initiativeResult = Self.capture { try await self.service.todayInitiative() }
        let (dash, today) = await (dashboardResult, initiativeResult)
        guard current == generation else { return }
        switch dash {
        case .success(let state): phase = .ready(state)
        case .failure(let error):
            if error.isCancellation { phase = priorPhase; initiative = priorInitiative; return }
            if error as? AccountError == .signedOut { signedOut = true }
            if case .ready = priorPhase { phase = priorPhase; refreshNotice = error.userMessage }
            else { phase = .failed(error.userMessage) }
        }
        switch today {
        case .success(let value): initiative = value.map { .ready($0) } ?? InitiativePhase.none
        case .failure(let error):
            if error.isCancellation { initiative = priorInitiative }
            else {
                if error as? AccountError == .signedOut { signedOut = true }
                if case .ready = priorInitiative {} else { initiative = .failed }
            }
        }
    }

    private static func capture<T: Sendable>(_ work: @Sendable () async throws -> T) async -> Result<T, Error> {
        do { return .success(try await work()) } catch { return .failure(error) }
    }
}

// MARK: - Gift history model

/// Paginated gift history (50 rows a page from the server). Memory is bounded: past `maxRows` the model
/// stops fetching and says so. A reload or `cancel()` invalidates any page in flight.
@MainActor
@Observable
public final class GiftHistoryModel {
    public enum Phase: Sendable, Equatable { case loading, ready, failed(String) }
    public enum ReceiptPhase: Sendable, Equatable {
        case loading(String)
        case ready(GiftReceipt)
        case failed(String, String)
        public var giftID: String {
            switch self {
            case .loading(let id), .failed(let id, _): return id
            case .ready(let receipt): return receipt.gift.id
            }
        }
    }

    public static let maxRows = 500

    public private(set) var phase: Phase = .loading
    public private(set) var gifts: [GiftEntry] = []
    public private(set) var nextOffset: Int?
    public private(set) var isLoadingMore = false
    public private(set) var moreError: String?
    public private(set) var summary: AnnualGivingSummary?
    public private(set) var receipt: ReceiptPhase?
    public private(set) var signedOut = false

    private let service: any DashboardService
    private let year: Int
    private var generation = 0
    private var pageTask: Task<Void, Never>?

    public init(service: any DashboardService, year: Int = Calendar.current.component(.year, from: Date())) {
        self.service = service; self.year = year
    }

    public var hasMore: Bool { nextOffset != nil && gifts.count < Self.maxRows }
    public var reachedLimit: Bool { nextOffset != nil && gifts.count >= Self.maxRows }
    public var isEmpty: Bool { phase == .ready && gifts.isEmpty }

    public func load() async {
        pageTask?.cancel(); pageTask = nil
        generation += 1
        let current = generation
        isLoadingMore = false
        moreError = nil
        let hadRows = !gifts.isEmpty
        if !hadRows { phase = .loading }
        async let summaryResult: AnnualGivingSummary? = try? await service.annualSummary(year: year)
        do {
            let page = try await service.gifts(offset: 0)
            guard current == generation else { return }
            gifts = Self.bounded(page.gifts)
            nextOffset = Self.advance(page.nextOffset, past: 0)
            phase = .ready
        } catch {
            guard current == generation else { return }
            if error.isCancellation { if !hadRows { phase = .loading }; return }
            if error as? AccountError == .signedOut { signedOut = true }
            if hadRows { moreError = error.userMessage } else { phase = .failed(error.userMessage) }
        }
        let loadedSummary = await summaryResult
        if current == generation { summary = loadedSummary }
    }

    /// Fetch the next page on a task the model owns, so `cancel()` (the screen disappearing) stops it.
    public func requestMore() {
        guard pageTask == nil, hasMore, let offset = nextOffset else { return }
        let current = generation
        isLoadingMore = true
        moreError = nil
        pageTask = Task { [weak self] in
            await self?.fetchPage(offset: offset, generation: current)
        }
    }

    private func fetchPage(offset: Int, generation current: Int) async {
        defer { if current == generation { pageTask = nil; isLoadingMore = false } }
        do {
            let page = try await service.gifts(offset: offset)
            guard current == generation else { return }
            let known = Set(gifts.map(\.id))
            gifts = Self.bounded(gifts + page.gifts.filter { !known.contains($0.id) })
            nextOffset = Self.advance(page.nextOffset, past: offset)
        } catch {
            guard current == generation, !error.isCancellation else { return }
            if error as? AccountError == .signedOut { signedOut = true }
            moreError = error.userMessage
        }
    }

    /// Stop any page in flight (the screen left); loaded rows stay.
    public func cancel() {
        pageTask?.cancel(); pageTask = nil
        generation += 1
        isLoadingMore = false
    }

    public func showReceipt(giftID: String) async {
        receipt = .loading(giftID)
        do {
            let value = try await service.receipt(giftID: giftID)
            if receipt?.giftID == giftID { receipt = .ready(value) }
        } catch {
            if error.isCancellation { if receipt?.giftID == giftID { receipt = nil }; return }
            if error as? AccountError == .signedOut { signedOut = true }
            if receipt?.giftID == giftID { receipt = .failed(giftID, error.userMessage) }
        }
    }

    public func hideReceipt() { receipt = nil }

    private static func bounded(_ rows: [GiftEntry]) -> [GiftEntry] { Array(rows.prefix(maxRows)) }

    /// A server offset that does not move forward would loop forever: treat it as the end.
    private static func advance(_ next: Int?, past offset: Int) -> Int? {
        guard let next, next > offset else { return nil }
        return next
    }
}
