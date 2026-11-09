import Foundation

// Engagement view models + the service seam. The models own explicit load/ready/failed
// state so the impact, badges, network, rankings and referral surfaces are unit-tested
// without a network, a camera, or UI — the same shape as the giving and auth models.

/// Everything the engagement home needs in one load. Each section is nil when the server did not
/// give it (the read failed, or the figure is not computed yet): the screen says "not available" for
/// that section instead of drawing a zero, an empty grid or a "not ranked" claim it cannot back.
public struct EngagementSnapshot: Sendable, Equatable {
    public let impact: ImpactTotals?
    public let badges: BadgeCollection?
    public let ranking: RankingStanding?
    public let network: NetworkSummary?
    /// Nil when there is no usable invite code: see `needsPublicName` for the one case that is the donor's to fix.
    public let referral: ReferralInfo?
    /// The donor has not chosen a public name yet, so the server issues no invite link (409 on the code).
    public let needsPublicName: Bool

    public init(
        impact: ImpactTotals?,
        badges: BadgeCollection?,
        ranking: RankingStanding?,
        network: NetworkSummary?,
        referral: ReferralInfo?,
        needsPublicName: Bool = false
    ) {
        self.impact = impact
        self.badges = badges
        self.ranking = ranking
        self.network = network
        self.referral = referral
        self.needsPublicName = needsPublicName
    }

    func replacing(ranking: RankingStanding?) -> EngagementSnapshot {
        EngagementSnapshot(impact: impact, badges: badges, ranking: ranking, network: network, referral: referral,
                           needsPublicName: needsPublicName)
    }
}

/// The seam the engagement model calls. A conformer maps to the generated client (WireEngagement)
/// or a preview/test double; all value types so the model stays testable.
public protocol EngagementService: Sendable {
    func snapshot() async throws -> EngagementSnapshot
    /// Opt into or out of the public rankings (K-2). Returns the resulting standing —
    /// opting out yields an all-nil standing so no position is ever shown.
    func setRankingOptIn(_ optIn: Bool) async throws -> RankingStanding
    /// Choose the public name the invite link and IRL code are issued for (R-1). Throws `invalidInput` for a
    /// name the server would refuse.
    func choosePublicName(_ name: String) async throws
    /// Spend by category for one initiative (A-3).
    func initiativeSpend(id: String) async throws -> InitiativeSpendSummary
}

/// Drives the engagement home. One load fetches the snapshot; `phase` tells the UI whether
/// to show the skeleton, the content, or a retryable error.
@MainActor
@Observable
public final class EngagementModel {
    public enum Phase: Sendable, Equatable {
        case loading
        case ready
        case failed(String)
    }

    public private(set) var phase: Phase = .loading
    public private(set) var snapshot: EngagementSnapshot?
    /// A transient toggle failure shown inline; the loaded screen and the prior ranking stay put.
    public private(set) var actionError: String?
    /// Shown above stale content when a refresh failed.
    public private(set) var refreshNotice: String?
    /// The session ended (a refresh was refused twice): the shell must route to sign-in.
    public private(set) var signedOut = false
    /// The rankings choice being saved. The screen shows it immediately; a failed save clears it, which
    /// reverts the screen to the standing the server last confirmed.
    public private(set) var pendingOptIn: Bool?
    public private(set) var nameError: String?
    public private(set) var isSavingName = false

    private let service: any EngagementService
    private var generation = 0

    public init(service: any EngagementService) { self.service = service }

    /// What the rankings card shows right now: the confirmed standing, or the donor's pending choice.
    public var displayedRanking: RankingStanding? {
        guard let ranking = snapshot?.ranking else { return nil }
        switch pendingOptIn {
        case nil: return ranking
        case false?: return RankingStanding(nationalPercentile: nil, city: nil, cityRank: nil, rankingsOptedOut: true)
        case true?: return RankingStanding(nationalPercentile: ranking.nationalPercentile, city: ranking.city,
                                           cityRank: ranking.cityRank, rankingsOptedOut: false)
        }
    }

    public func load() async {
        generation += 1
        let current = generation
        let prior = phase
        refreshNotice = nil
        if snapshot == nil { phase = .loading }
        do {
            let value = try await service.snapshot()
            guard current == generation else { return }
            snapshot = value
            phase = .ready
        } catch where error.isCancellation {
            guard current == generation else { return }
            phase = prior
        } catch {
            guard current == generation else { return }
            if error as? AccountError == .signedOut { signedOut = true }
            if snapshot != nil { phase = .ready; refreshNotice = error.userMessage } else { phase = .failed(error.userMessage) }
        }
    }

    /// Toggle rankings visibility (K-2). The card flips at once; on success the standing is replaced in
    /// place so it re-renders to the opt-in prompt or the restored position, and on failure it reverts to the
    /// prior standing with an inline notice. A second tap while one is saving is ignored.
    public func setRankingOptIn(_ optIn: Bool) async {
        guard snapshot != nil, pendingOptIn == nil else { return }
        actionError = nil
        pendingOptIn = optIn
        defer { pendingOptIn = nil }
        do {
            let ranking = try await service.setRankingOptIn(optIn)
            snapshot = snapshot?.replacing(ranking: ranking)
        } catch where error.isCancellation {
            return
        } catch {
            if error as? AccountError == .signedOut { signedOut = true }
            actionError = error.userMessage
        }
    }

    /// Choose the public name behind the invite link (R-1), then reload so the code and link appear.
    public func choosePublicName(_ raw: String) async {
        let name = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !isSavingName else { return }
        guard (1...80).contains(name.count) else { nameError = "Enter a name between 1 and 80 characters."; return }
        isSavingName = true
        nameError = nil
        defer { isSavingName = false }
        do {
            try await service.choosePublicName(name)
        } catch where error.isCancellation {
            return
        } catch {
            if error as? AccountError == .signedOut { signedOut = true }
            switch error as? AccountError {
            case .invalidInput?: nameError = "That name can’t be used. Try another."
            case .forbidden?: nameError = "Invite links aren’t available for this account."
            default: nameError = error.userMessage
            }
            return
        }
        await load()
    }
}

/// Spend by category for one initiative (A-3), opened from today's initiative card.
@MainActor
@Observable
public final class InitiativeSpendModel {
    public enum Phase: Sendable, Equatable {
        case loading
        case ready(InitiativeSpendSummary)
        /// The initiative has no published spend (404).
        case unpublished
        case failed(String)
    }

    public private(set) var phase: Phase = .loading
    public private(set) var signedOut = false

    private let service: any EngagementService
    private let initiativeID: String

    public init(service: any EngagementService, initiativeID: String) {
        self.service = service; self.initiativeID = initiativeID
    }

    public func load() async {
        let prior = phase
        if case .ready = phase {} else { phase = .loading }
        do {
            phase = .ready(try await service.initiativeSpend(id: initiativeID))
        } catch where error.isCancellation {
            phase = prior
        } catch AccountError.notFound {
            phase = .unpublished
        } catch {
            if error as? AccountError == .signedOut { signedOut = true }
            if case .ready = prior { phase = prior } else { phase = .failed(error.userMessage) }
        }
    }
}
