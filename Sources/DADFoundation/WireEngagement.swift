import Foundation
import OpenAPIRuntime

/// Real engagement service (PRD A-3, I-*, K-*, N-*, R-*, B-*) over the generated client: `dashboard` (impact,
/// rank, referral counts), `donorBadges`, `donorNetwork`, `sharing` + `conversions` (invite), `profile` +
/// `savePreferences` (the rankings choice), `saveSharing` (public name) and `initiativeSpend`, each
/// authorized through the session (single refresh + one retry on 401).
///
/// `snapshot()` reads the sections concurrently and keeps the ones that answered: a section whose read
/// failed is nil in the snapshot (shown as unavailable), never an empty value or a zero. The whole load
/// fails only when the session ended, the work was cancelled, or every section failed.
///
/// Status mapping: 401 -> signed out; 403 -> forbidden; 404 -> not found (an initiative with no published
/// spend); 409 -> conflict (stale preferences version after one retry; no public name on the code, which this
/// service does not read); 422 -> invalid input; 429 (with or without a body: the ingress limiter sends
/// none) -> rate limited; anything else, or a body that does not decode, -> unavailable. Cancellation
/// propagates untouched so the model keeps its prior state. Nothing here logs.
public struct WireEngagement: EngagementService {
    private let product: ProductClient
    /// Defensive caps: a larger body is truncated rather than trusted.
    static let badgeLimit = 64
    static let inviteeLimit = 200
    static let conversionLimit = 50
    static let spendCategoryLimit = 100

    public init(origin: URL, session: AccountSession) throws {
        self.init(product: try ProductClient(origin: origin, session: session))
    }

    init(product: ProductClient) { self.product = product }

    // MARK: - snapshot

    public func snapshot() async throws -> EngagementSnapshot {
        async let dashboard = Self.capture { try await WireDashboard(product: product).dashboard() }
        async let badges = Self.capture { try await self.badges() }
        async let network = Self.capture { try await self.network() }
        async let invite = Self.capture { try await self.invite() }
        let (dash, badgeResult, networkResult, inviteResult) = await (dashboard, badges, network, invite)

        let results: [Result<Void, Error>] = [dash.map { _ in () }, badgeResult.map { _ in () },
                                              networkResult.map { _ in () }, inviteResult.map { _ in () }]
        let failures = results.compactMap { result -> Error? in if case .failure(let error) = result { return error } else { return nil } }
        // A cancelled or signed-out load is not a partial one.
        if let stop = failures.first(where: { $0.isCancellation || ($0 as? AccountError) == .signedOut }) { throw stop }
        if failures.count == results.count, let first = failures.first { throw first }

        var impact: ImpactTotals?
        var ranking: RankingStanding?
        var counts: ReferralTotals?
        if case .success(let state) = dash {
            switch state {
            case .ready(let value):
                impact = value.impact
                counts = value.referrals
                switch value.rank {
                case .ranked(let rank): ranking = RankingStanding(nationalPercentile: rank.topPercent, city: rank.city, cityRank: rank.cityRank)
                case .notRankedYet: ranking = RankingStanding(nationalPercentile: nil, city: nil, cityRank: nil)
                case .optedOut: ranking = RankingStanding(nationalPercentile: nil, city: nil, cityRank: nil, rankingsOptedOut: true)
                }
            case .preparing:
                // Figures are not computed yet, but the donor's rankings choice is still theirs to make.
                if let settings = try? await WireAccountSettings(product: product).load() {
                    ranking = RankingStanding(nationalPercentile: nil, city: nil, cityRank: nil,
                                              rankingsOptedOut: settings.preferences.rankingsOptedOut)
                }
            }
        }
        let badgeCollection = try? badgeResult.get()
        let networkSummary = try? networkResult.get()
        var referral: ReferralInfo?
        var needsName = false
        if case .success(let found) = inviteResult {
            switch found.outcome {
            case .needsName: needsName = true
            case .code(let code):
                referral = ReferralInfo(code: code, linkCount: counts.map(\.link), irlCount: counts.map(\.irl),
                                        conversions: found.conversions, hasMoreConversions: found.more)
            case .unusable: break
            }
        }
        return EngagementSnapshot(impact: impact, badges: badgeCollection, ranking: ranking, network: networkSummary,
                                  referral: referral, needsPublicName: needsName)
    }

    // MARK: - sections

    func badges() async throws -> BadgeCollection {
        try await product.call { client in
            switch try await client.donorBadges(.init()) {
            case .ok(let response):
                let list = try response.body.json
                return BadgeCollection(badges: list.badges.filter { !$0.code.isEmpty && !$0.title.isEmpty }.prefix(Self.badgeLimit).map { view in
                    Badge(code: view.code, title: view.title, rule: view.rule, perk: Badge.perkCopy(forKey: view.perk),
                          earned: view.earned, earnedAt: view.earned_at, displayTitle: view.display_title)
                })
            case .unauthorized: throw AccountError.signedOut
            case .tooManyRequests: throw AccountError.rateLimited
            case .serviceUnavailable: throw AccountError.unavailable
            case .undocumented(let status, _): throw AccountError.forStatus(status)
            }
        }
    }

    func network() async throws -> NetworkSummary {
        try await product.call { client in
            switch try await client.donorNetwork(.init()) {
            case .ok(let response):
                let value = try response.body.json
                return NetworkSummary(
                    activeCount: Int(clamping: value.active_count), annualizedMinor: Int(clamping: value.annualized_minor),
                    anonymousActive: Int(clamping: value.anonymous_active),
                    invitees: value.invitees.prefix(Self.inviteeLimit).map { NetworkInvitee(name: $0.name, active: $0.active) },
                    nextMilestone: value.next_milestone.map {
                        NetworkMilestone(label: $0.label, target: Int(clamping: $0.target), remaining: Int(clamping: $0.remaining))
                    })
            case .unauthorized: throw AccountError.signedOut
            case .tooManyRequests: throw AccountError.rateLimited
            case .serviceUnavailable: throw AccountError.unavailable
            case .undocumented(let status, _): throw AccountError.forStatus(status)
            }
        }
    }

    private enum InviteOutcome { case code(String), needsName, unusable }
    private struct Invite { let outcome: InviteOutcome; let conversions: [Conversion]?; let more: Bool }

    /// The invite code (from `sharing`) and the recent conversions. A failed conversions read leaves the code
    /// usable with the conversions unknown; a failed sharing read fails the invite section.
    private func invite() async throws -> Invite {
        let sharing = try await product.call { client in
            switch try await client.sharing(.init()) {
            case .ok(let response): return try response.body.json
            case .unauthorized: throw AccountError.signedOut
            case .tooManyRequests: throw AccountError.rateLimited
            case .serviceUnavailable: throw AccountError.unavailable
            case .undocumented(let status, _): throw AccountError.forStatus(status)
            }
        }
        let outcome = Self.outcome(of: sharing)
        guard case .code = outcome else { return Invite(outcome: outcome, conversions: nil, more: false) }
        do {
            let page = try await conversions()
            return Invite(outcome: outcome, conversions: page.conversions, more: page.more)
        } catch {
            // Only an ended session or a cancelled load must stop the whole snapshot; any other failure is partial.
            if error.isCancellation || (error as? AccountError) == .signedOut { throw error }
            return Invite(outcome: outcome, conversions: nil, more: false)
        }
    }

    private static func outcome(of sharing: Components.Schemas.Sharing) -> InviteOutcome {
        guard let name = sharing.public_name, !name.isEmpty, sharing.link != nil else { return .needsName }
        // The server names the code (`referral_code`, null exactly when the links are); the share and QR links are
        // rebuilt from the configured public origin around it.
        guard let raw = sharing.referral_code, let code = ReferralInfo.sanitizedCode(raw) else { return .unusable }
        return .code(code)
    }

    private func conversions() async throws -> (conversions: [Conversion], more: Bool) {
        try await product.call { client in
            switch try await client.conversions(.init()) {
            case .ok(let response):
                let list = try response.body.json
                return (list.conversions.prefix(Self.conversionLimit).map {
                    Conversion(convertedAt: $0.converted_at, kind: ConversionKind(wire: $0.kind))
                }, list.more)
            case .unauthorized: throw AccountError.signedOut
            case .unprocessableContent: throw AccountError.invalidInput
            case .tooManyRequests: throw AccountError.rateLimited
            case .serviceUnavailable: throw AccountError.unavailable
            case .undocumented(let status, _): throw AccountError.forStatus(status)
            }
        }
    }

    // MARK: - commands

    public func setRankingOptIn(_ optIn: Bool) async throws -> RankingStanding {
        let settings = WireAccountSettings(product: product)
        var attempt = 0
        while true {
            let current = try await settings.load().preferences
            let wanted = current.with("rankings_opted_out", !optIn)
            do {
                try await savePreferences(wanted)
                break
            } catch AccountError.conflict where attempt == 0 {
                // The profile changed between the read and the save (another device, the settings screen): read again once.
                attempt += 1
            }
        }
        guard optIn else { return RankingStanding(nationalPercentile: nil, city: nil, cityRank: nil, rankingsOptedOut: true) }
        // Back in the rankings: the server decides the position. If that read fails the choice still stands.
        if case .ready(let dashboard)? = try? await WireDashboard(product: product).dashboard() {
            switch dashboard.rank {
            case .ranked(let rank): return RankingStanding(nationalPercentile: rank.topPercent, city: rank.city, cityRank: rank.cityRank)
            case .notRankedYet, .optedOut: break
            }
        }
        return RankingStanding(nationalPercentile: nil, city: nil, cityRank: nil)
    }

    private func savePreferences(_ preferences: AccountPreferences) async throws {
        let body = WireAccountSettings.preferencesBody(preferences)
        try await product.call { client in
            switch try await client.savePreferences(.init(body: .json(body))) {
            case .ok: return
            case .unauthorized: throw AccountError.signedOut
            case .conflict: throw AccountError.conflict
            case .unprocessableContent: throw AccountError.invalidInput
            case .tooManyRequests: throw AccountError.rateLimited
            case .undocumented(let status, _): throw AccountError.forStatus(status)
            default: throw AccountError.unavailable
            }
        }
    }

    public func choosePublicName(_ name: String) async throws {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard (1...80).contains(trimmed.count) else { throw AccountError.invalidInput }
        try await product.call { client in
            switch try await client.saveSharing(.init(body: .json(.init(public_name: trimmed, replace_code: false)))) {
            case .ok: return
            case .unauthorized: throw AccountError.signedOut
            case .forbidden: throw AccountError.forbidden
            case .unprocessableContent: throw AccountError.invalidInput
            case .tooManyRequests: throw AccountError.rateLimited
            case .serviceUnavailable: throw AccountError.unavailable
            case .undocumented(let status, _): throw AccountError.forStatus(status)
            default: throw AccountError.unavailable
            }
        }
    }

    public func initiativeSpend(id: String) async throws -> InitiativeSpendSummary {
        // A malformed id is a 404 server-side; refuse it before it becomes a path segment.
        guard UUID(uuidString: id) != nil else { throw AccountError.invalidInput }
        return try await product.call { client in
            switch try await client.initiativeSpend(.init(path: .init(initiative_id: id))) {
            case .ok(let response):
                let value = try response.body.json
                guard value.total_minor >= 0 else { throw AccountError.invalidResponse }
                return InitiativeSpendSummary(
                    initiativeID: value.initiative_id, totalMinor: Int(clamping: value.total_minor),
                    slices: value.categories.prefix(Self.spendCategoryLimit).map {
                        SpendSlice(category: $0.category, amountMinor: Int(clamping: max(0, $0.amount_minor)))
                    })
            case .notFound: throw AccountError.notFound
            case .serviceUnavailable: throw AccountError.unavailable
            case .undocumented(let status, _): throw AccountError.forStatus(status)
            }
        }
    }

    private static func capture<T: Sendable>(_ work: @Sendable () async throws -> T) async -> Result<T, Error> {
        do { return .success(try await work()) } catch { return .failure(error) }
    }
}
