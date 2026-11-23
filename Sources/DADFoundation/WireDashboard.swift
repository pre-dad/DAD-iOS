import Foundation
import OpenAPIRuntime

/// Real donor-home reads over the generated client: `dashboard`, `todayInitiative`, `gifts`, `receipt`
/// and `annualSummary`, each authorized through the session (single refresh + one retry on 401).
///
/// Status mapping (contract 2.5.0 documents 429 on these GETs as `.tooManyRequests`; the body is not
/// guaranteed and `Retry-After` may be absent, so neither is read; 403 from the app guard is not
/// documented and falls to unavailable): 401 -> signed out; 429 -> rate limited;
/// 404 on today's initiative -> nil (nothing in rotation); 422/404/409 on a gift read -> invalid
/// input / unavailable; everything else -> unavailable. A body that does not decode is unavailable.
public struct WireDashboard: DashboardService {
    private let product: ProductClient
    /// Defensive page cap: the server pages at 50; a larger body is truncated rather than trusted.
    static let pageRowLimit = 100

    public init(origin: URL, session: AccountSession) throws {
        self.init(product: try ProductClient(origin: origin, session: session))
    }

    init(product: ProductClient) { self.product = product }

    public func dashboard() async throws -> DashboardState {
        try await product.call { client in
            switch try await client.dashboard(.init()) {
            case .ok(let response):
                switch try response.body.json {
                case .case1: return .preparing
                case .case2(let value): return .ready(Self.map(value))
                }
            case .unauthorized: throw AccountError.signedOut
            case .tooManyRequests: throw AccountError.rateLimited
            case .undocumented(let status, _): throw Self.undocumented(status)
            default: throw AccountError.unavailable
            }
        }
    }

    public func todayInitiative() async throws -> TodayInitiative? {
        try await product.call { client in
            switch try await client.todayInitiative(.init()) {
            case .ok(let response):
                let value = try response.body.json
                return TodayInitiative(
                    id: value.initiative_id, slug: value.slug, title: value.title, summary: value.summary,
                    location: value.location, kind: value._type, startedOn: value.started_on,
                    metrics: value.metrics.map {
                        InitiativeMetric(label: $0.label, value: Int(clamping: $0.value),
                                         unit: InitiativeMetric.Unit(rawValue: $0.unit.rawValue), verifiedOn: $0.verified_on)
                    })
            case .notFound: return nil
            case .unauthorized: throw AccountError.signedOut
            case .tooManyRequests: throw AccountError.rateLimited
            case .undocumented(let status, _): throw Self.undocumented(status)
            default: throw AccountError.unavailable
            }
        }
    }

    public func gifts(offset: Int) async throws -> GiftHistoryPage {
        guard offset >= 0 else { throw AccountError.invalidInput }
        return try await product.call { client in
            switch try await client.gifts(.init(query: .init(offset: Int64(offset)))) {
            case .ok(let response):
                let page = try response.body.json
                return GiftHistoryPage(
                    gifts: page.gifts.prefix(Self.pageRowLimit).map {
                        GiftEntry(id: $0.id, amountMinor: Int(clamping: $0.amount_minor), paidAt: $0.paid_at,
                                  frequency: GiftEntry.Frequency(rawValue: $0.frequency.rawValue) ?? .oneTime,
                                  refundedMinor: Int(clamping: $0.refunded_minor), netMinor: Int(clamping: $0.net_minor))
                    },
                    nextOffset: page.next_offset.map { Int(clamping: $0) })
            case .unauthorized: throw AccountError.signedOut
            case .unprocessableContent: throw AccountError.invalidInput
            case .tooManyRequests: throw AccountError.rateLimited
            case .undocumented(let status, _): throw Self.undocumented(status)
            default: throw AccountError.unavailable
            }
        }
    }

    public func receipt(giftID: String) async throws -> GiftReceipt {
        // A malformed id is a 404 server-side; refuse it before it becomes a path segment.
        guard UUID(uuidString: giftID) != nil else { throw AccountError.invalidInput }
        return try await product.call { client in
            switch try await client.receipt(.init(path: .init(gift_id: giftID))) {
            case .ok(let response):
                let value = try response.body.json
                return GiftReceipt(gift: Self.entry(value.gift), refunds: Self.refunds(value.gift), taxReceipt: value.tax_receipt, asOf: value.as_of)
            case .notFound: throw AccountError.invalidInput
            case .unauthorized: throw AccountError.signedOut
            case .unprocessableContent: throw AccountError.invalidInput
            case .tooManyRequests: throw AccountError.rateLimited
            case .undocumented(let status, _): throw Self.undocumented(status)
            default: throw AccountError.unavailable
            }
        }
    }

    public func annualSummary(year: Int) async throws -> AnnualGivingSummary {
        guard (2000...9999).contains(year) else { throw AccountError.invalidInput }
        return try await product.call { client in
            switch try await client.annualSummary(.init(path: .init(year: year))) {
            case .ok(let response):
                let value = try response.body.json
                return AnnualGivingSummary(
                    year: Int(value.year), giftCount: value.gifts.count, amountMinor: Int(clamping: value.amount_minor),
                    refundedMinor: Int(clamping: value.refunded_minor), netMinor: Int(clamping: value.net_minor),
                    taxReceipt: value.tax_receipt)
            case .notFound: throw AccountError.invalidInput
            case .unauthorized: throw AccountError.signedOut
            case .unprocessableContent: throw AccountError.invalidInput
            case .tooManyRequests: throw AccountError.rateLimited
            case .undocumented(let status, _): throw Self.undocumented(status)
            default: throw AccountError.unavailable
            }
        }
    }

    /// Narrower than `AccountError.forStatus` on purpose: dashboard reads treat 403/404/409 as unavailable, not as actionable errors.
    private static func undocumented(_ status: Int) -> AccountError {
        switch status {
        case 401: return .signedOut
        case 429: return .rateLimited
        default: return .unavailable
        }
    }

    private static func entry(_ record: Components.Schemas.GiftRecord) -> GiftEntry {
        GiftEntry(id: record.id, amountMinor: Int(clamping: record.amount_minor), paidAt: record.paid_at,
                  frequency: GiftEntry.Frequency(rawValue: record.frequency.rawValue) ?? .oneTime,
                  refundedMinor: Int(clamping: record.refunded_minor), netMinor: Int(clamping: record.net_minor))
    }

    private static func refunds(_ record: Components.Schemas.GiftRecord) -> [RefundEntry] {
        record.refunds.map { RefundEntry(id: $0.id, amountMinor: Int(clamping: $0.amount_minor), status: $0.status, observedAt: $0.observed_at) }
    }

    /// The layout is untrusted JSON bound into the response it came with; whatever goes wrong, the dashboard still
    /// loads without a panel.
    private static func insights(_ value: Components.Schemas.DonorDashboard.Case2Payload) -> InsightsPanel? {
        guard let raw = value.insights, let dashboard = try? UIValue(encoding: value),
              let panel = try? UIValue(encoding: raw) else { return nil }
        return UIInsights.panel(raw: panel, dashboard: dashboard)
    }

    private static func map(_ value: Components.Schemas.DonorDashboard.Case2Payload) -> DonorDashboard {
        let streak = value.streak.map { streak in
            StreakCard(
                current: Int(streak.current), atRisk: streak.at_risk, graceEndsAt: streak.grace_ends_at,
                ladder: streak.ladder.map {
                    StreakLadder(days: Int(clamping: $0.days), lastMilestone: Int(clamping: $0.last_milestone),
                                 nextMilestone: $0.next_milestone.map { Int(clamping: $0) },
                                 daysToNext: $0.days_to_next.map { Int(clamping: $0) }, bar: $0.bar)
                })
        }
        let rank: RankLine
        if value.rankings_opted_out { rank = .optedOut }
        else if let r = value.rank { rank = .ranked(DashboardRank(topPercent: r.national_percentile, city: r.city, cityRank: r.city_rank)) }
        else { rank = .notRankedYet }
        return DonorDashboard(
            computedAt: value.computed_at, foundingDonor: value.founding_donor, streak: streak, rank: rank,
            impact: ImpactTotals(givenMinor: value.impact.given_minor.map { Int(clamping: $0) },
                                 initiativesFunded: Int(clamping: value.impact.initiatives_funded),
                                 eventsVolunteered: Int(clamping: value.impact.events_volunteered)),
            network: value.network.map {
                NetworkSummary(activeCount: Int(clamping: $0.active_count), annualizedMinor: Int(clamping: $0.annualized_minor), anonymousActive: 0)
            },
            referrals: value.referrals.map {
                ReferralTotals(link: Int(clamping: $0.link), irl: Int(clamping: $0.irl), totalMinor: Int(clamping: $0.total_minor))
            },
            insights: insights(value))
    }
}
