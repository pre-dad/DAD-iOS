import Foundation

// Donor engagement surface (PRD A-*, I-*, R-*, N-*, B-*, K-*). Pure value types and the
// display/eligibility rules live here so badge state, rankings opt-out, impact formatting
// and QR payloads are unit-testable without a network, a camera, or UI.

// MARK: - Badges (B-1..B-4)

/// A single badge as the badges grid renders it. `earned` drives colour vs. greyed, but the
/// grid must never rely on colour alone (PRD §10 / WCAG): `accessibilityLabel` and the
/// visible `rule` text carry the earned/locked state for VoiceOver and colour-blind users.
public struct Badge: Sendable, Equatable, Hashable, Identifiable {
    public let code: String
    public let title: String
    /// How this badge is earned — shown beneath a locked badge so the rule is never colour-only.
    public let rule: String
    /// What the badge unlocks (perk gating copy), e.g. "invite-only events"; empty when it unlocks nothing.
    public let perk: String
    public let earned: Bool
    public let earnedAt: Date?
    /// Server-composed title for an earned badge (e.g. "Top 50 in Chicago"); empty when the server gave none.
    public let displayTitle: String

    public var id: String { code }

    /// What the grid shows: the display title once earned (falling back to `title` when blank), else `title`.
    public var shownTitle: String {
        guard earned else { return title }
        let trimmed = displayTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? title : displayTitle
    }

    public init(code: String, title: String, rule: String, perk: String, earned: Bool, earnedAt: Date? = nil, displayTitle: String = "") {
        self.code = code
        self.title = title
        self.rule = rule
        self.perk = perk
        self.earned = earned
        self.earnedAt = earnedAt
        self.displayTitle = displayTitle
    }

    public var hasPerk: Bool { !perk.isEmpty }

    /// Perk copy for the server's perk key (PRD B-3). The key is an open set: an unknown, non-empty key still
    /// says the badge carries a perk rather than hiding it, and an empty key means no perk.
    public static func perkCopy(forKey key: String) -> String {
        switch key {
        case "": return ""
        case "FOUNDING_EVENTS": return "Invite-only founding events"
        case "MILESTONE_EVENTS": return "Invite-only milestone events"
        case "TEAM_CAPTAIN": return "Invite-only events, a DAD merch item, 48-hour early event booking and opt-in name listing on initiative pages"
        default: return "Unlocks a member perk"
        }
    }

    /// A text-only statement of state, so the grid conveys earned/locked without colour.
    public var accessibilityLabel: String {
        earned ? "\(shownTitle), earned" : "\(title), locked. \(rule)"
    }

    /// The state statement plus the perk, for the grid row that reads as one element.
    public var accessibilitySummary: String { hasPerk ? "\(accessibilityLabel). Perk: \(perk)" : accessibilityLabel }

    /// Perk gating (B-4): these three badges unlock invite-only events. Kept as a rule on the
    /// domain, not scattered in the UI, so the gate is testable.
    /// These are the server catalog codes (DAD-Main `badges.go`, PRD Appendix A): F = Founding
    /// Donor, 1K = 1,000 Days, TC = Team Captain.
    public static let perkGatingCodes: Set<String> = ["F", "1K", "TC"]

    /// Whether holding this (earned) badge unlocks invite-only event access.
    public var unlocksInviteOnlyEvents: Bool { earned && Self.perkGatingCodes.contains(code) }
}

/// The badges collection with the two derived rollups the badges home shows.
public struct BadgeCollection: Sendable, Equatable {
    public let badges: [Badge]
    public init(badges: [Badge]) { self.badges = badges }

    public var earnedCount: Int { badges.filter(\.earned).count }
    public var total: Int { badges.count }
    /// Any earned perk-gating badge grants invite-only event access.
    public var hasInviteOnlyAccess: Bool { badges.contains(where: \.unlocksInviteOnlyEvents) }
    /// "7 of 24 earned" — the headline summary.
    public var summaryLabel: String { "\(earnedCount) of \(total) earned" }
}

// MARK: - Rankings (K-1..K-3)

/// A donor's standing. Opt-out is the explicit server flag (`rankings_opted_out`), distinct from
/// "opted in but not ranked yet" (null rank with the flag false). The UI never renders a zero as
/// a rank, and there is never a public name list, only the viewer's own percentile/city position.
public struct RankingStanding: Sendable, Equatable {
    public let nationalPercentile: Int?
    public let city: String?
    public let cityRank: Int?
    public let rankingsOptedOut: Bool

    public init(nationalPercentile: Int?, city: String?, cityRank: Int?, rankingsOptedOut: Bool = false) {
        self.nationalPercentile = nationalPercentile
        self.city = city
        self.cityRank = cityRank
        self.rankingsOptedOut = rankingsOptedOut
    }

    /// The donor chose to be hidden: the card shows the opt-in prompt, never a position.
    public var isOptedOut: Bool { rankingsOptedOut }

    /// Opted in but the server has no standing for them yet (not the same as opted out).
    public var isNotRankedYet: Bool { !rankingsOptedOut && nationalPercentile == nil }

    /// "Top 2% nationally" — only when a percentile exists. The server's `national_percentile` is already
    /// the *top* bucket (1 = top 1%, 2 = top 2%), so it is shown as is, never as `100 - p`. Clamped to
    /// 1...100 so a stray value cannot read "Top 0%" or "Top -3%".
    public var nationalLabel: String? {
        guard let p = nationalPercentile else { return nil }
        return "Top \(min(100, max(1, p)))% nationally"
    }

    /// "#3 in Austin" — only when both a city and a rank exist.
    public var cityLabel: String? {
        guard let city, let rank = cityRank else { return nil }
        return "#\(rank) in \(city)"
    }
}

// MARK: - Impact (A-*, I-1..I-3)

/// Lifetime impact totals. `givenMinor` is nullable by contract: when the backend hasn't
/// computed it we show "—", never "$0", so an unknown total is never mistaken for nothing given.
public struct ImpactTotals: Sendable, Equatable {
    public let givenMinor: Int?
    public let initiativesFunded: Int
    public let eventsVolunteered: Int

    public init(givenMinor: Int?, initiativesFunded: Int, eventsVolunteered: Int) {
        self.givenMinor = givenMinor
        self.initiativesFunded = initiativesFunded
        self.eventsVolunteered = eventsVolunteered
    }

    /// "$1,240" when known, "—" when the total is not yet computed.
    public var givenLabel: String {
        guard let minor = givenMinor else { return "—" }
        return formatUSDMinor(minor)
    }
}

/// A spend-by-category slice for the initiative-spend screen. Totals only (PRD §5.2) — never
/// a per-donor line-item ledger.
public struct SpendSlice: Sendable, Equatable, Identifiable {
    public let category: String
    public let amountMinor: Int
    public var id: String { category }
    public init(category: String, amountMinor: Int) {
        self.category = category
        self.amountMinor = amountMinor
    }
    public var amountLabel: String { formatUSDMinor(amountMinor) }
}

// MARK: - Network (N-1..N-3)

/// One opted-in person the donor brought in (N-3): first name and last initial, and whether they still give.
public struct NetworkInvitee: Sendable, Equatable, Hashable, Identifiable {
    public let name: String
    public let active: Bool
    public var id: String { name }
    public init(name: String, active: Bool) { self.name = name; self.active = active }
    public var statusLabel: String { active ? "Active" : "Not giving now" }
}

/// Progress toward the next network tier (N-2), e.g. "8 more to unlock Team Captain".
public struct NetworkMilestone: Sendable, Equatable {
    public let label: String
    public let target: Int
    public let remaining: Int
    public init(label: String, target: Int, remaining: Int) { self.label = label; self.target = target; self.remaining = remaining }
    public var progressLabel: String { "\(remaining) more to reach \(label)" }
}

/// The donor's referral network rollup. Opt-in visibility (N-3): `anonymousActive` are the
/// invitees who did not opt into being shown, counted but never named.
public struct NetworkSummary: Sendable, Equatable {
    public let activeCount: Int
    public let annualizedMinor: Int
    public let anonymousActive: Int
    public let invitees: [NetworkInvitee]
    public let nextMilestone: NetworkMilestone?
    public init(activeCount: Int, annualizedMinor: Int, anonymousActive: Int, invitees: [NetworkInvitee] = [],
                nextMilestone: NetworkMilestone? = nil) {
        self.activeCount = activeCount
        self.annualizedMinor = annualizedMinor
        self.anonymousActive = anonymousActive
        self.invitees = invitees
        self.nextMilestone = nextMilestone
    }
    public var annualizedLabel: String { "\(formatUSDMinor(annualizedMinor))/yr" }
    public var hasAnonymous: Bool { anonymousActive > 0 }
}

/// How a referral reached the donor's first gift.
public enum ConversionKind: Sendable, Equatable {
    case link, irl
    /// A channel this build does not know (the server's set is open).
    case other
    public init(wire: String) {
        switch wire.uppercased() {
        case "LINK": self = .link
        case "IRL": self = .irl
        default: self = .other
        }
    }
    public var label: String {
        switch self {
        case .link: return "Invite link"
        case .irl: return "In person"
        case .other: return "Invite"
        }
    }
}

/// A referral's first gift (R-3). It carries nothing about the referred donor.
public struct Conversion: Sendable, Equatable, Identifiable {
    public let convertedAt: Date
    public let kind: ConversionKind
    public var id: String { "\(convertedAt.timeIntervalSince1970)-\(kind.label)" }
    public init(convertedAt: Date, kind: ConversionKind) { self.convertedAt = convertedAt; self.kind = kind }
}

// MARK: - Referral / IRL (R-1..R-4)

/// The data behind the invite + IRL screens. Splits link vs. in-real-life attributed giving
/// and builds the invite URL + QR payload a donor shares. The counts and the conversions list are nil
/// when the server did not give them: unknown is never shown as zero.
public struct ReferralInfo: Sendable, Equatable {
    public let code: String
    public let linkCount: Int?
    public let irlCount: Int?
    /// Newest first, at most 20 (the server's page); nil when that read failed.
    public let conversions: [Conversion]?
    public let hasMoreConversions: Bool

    public init(code: String, linkCount: Int?, irlCount: Int?, conversions: [Conversion]? = nil, hasMoreConversions: Bool = false) {
        self.code = code
        self.linkCount = linkCount
        self.irlCount = irlCount
        self.conversions = conversions
        self.hasMoreConversions = hasMoreConversions
    }

    /// Nil unless both counts are known.
    public var totalConverted: Int? {
        guard let linkCount, let irlCount else { return nil }
        return linkCount + irlCount
    }

    /// The shareable invite URL carrying this donor's code (R-1): `<public origin>/r/<code>`, the
    /// referral route the web app and the deep-link router (`links.json` `referral_prefix`) serve. The
    /// host is the configured public origin (`DAD_PUBLIC_ORIGIN`), the same one the router trusts.
    /// Nil when no valid origin is configured or the code is not a well-formed one.
    public func inviteURL(host: String? = PublicOrigin.configured()) -> URL? { url(host: host, inPerson: false) }

    /// The in-person (QR) link: the invite URL tagged `via=irl` so a scan is attributed as IRL (R-1, R-4).
    public func irlURL(host: String? = PublicOrigin.configured()) -> URL? { url(host: host, inPerson: true) }

    private func url(host: String?, inPerson: Bool) -> URL? {
        guard let host, let safe = Attribution.sanitized(code), var components = URLComponents(string: host) else { return nil }
        components.path = "/r/\(safe)"
        components.queryItems = inPerson ? [URLQueryItem(name: "via", value: "irl")] : nil
        return components.url
    }

    /// The prefilled share-sheet message (R-1).
    public func shareMessage(host: String? = PublicOrigin.configured()) -> String {
        let base = "Join me on Dollar A Day — give $1 a day to local causes."
        guard let link = inviteURL(host: host)?.absoluteString else { return base }
        return "\(base) \(link)"
    }
}

/// Spend by category for one initiative (A-3): totals only (PRD §5.2), never a per-donor line-item ledger.
public struct InitiativeSpendSummary: Sendable, Equatable {
    public let initiativeID: String
    public let totalMinor: Int
    public let slices: [SpendSlice]
    public init(initiativeID: String, totalMinor: Int, slices: [SpendSlice]) {
        self.initiativeID = initiativeID; self.totalMinor = totalMinor; self.slices = slices
    }
    public var totalLabel: String { formatUSDMinor(totalMinor) }
}

/// The app's configured public HTTPS origin (Info.plist `DADPublicOrigin`, from the
/// `DAD_PUBLIC_ORIGIN` build setting). A DEBUG build with nothing configured falls back to
/// production so previews and tests have a link; a release build never invents an origin.
public enum PublicOrigin {
    public static func configured(_ bundle: Bundle = .main) -> String? {
        resolve(bundle.object(forInfoDictionaryKey: "DADPublicOrigin") as? String)
    }

    public static func resolve(_ value: String?) -> String? {
        if let value, !value.isEmpty {
            guard let url = URL(string: value), url.isBareHTTPSOrigin else { return nil }
            return value
        }
        #if DEBUG
        return "https://dollaraday.org"
        #else
        return nil
        #endif
    }
}

// MARK: - QR (R-2)

/// A scanned or shareable QR payload: the invite URL the on-screen QR encodes (rendered with CoreImage) and
/// the parser that reads a scan back into a referral code.
public struct QRPayload: Sendable, Equatable {
    public let payload: String
    public init(_ payload: String) { self.payload = payload }

    public func encoded() -> String { payload }

    /// Decode a scanned string back to a payload, trimming surrounding whitespace a camera
    /// scan can introduce. Returns nil for an empty scan so the scanner ignores noise.
    public static func decode(_ scanned: String) -> QRPayload? {
        let trimmed = scanned.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        return QRPayload(trimmed)
    }

    /// Extract the referral code from a scanned invite URL (R-4: scanning another's IRL code
    /// attributes to them): `/r/<code>` (what the app and web share) or a legacy `?ref=<code>`.
    /// Returns nil when the scan is not a DAD invite link.
    public var referralCode: String? {
        guard let components = URLComponents(string: payload) else { return nil }
        let parts = components.path.split(separator: "/").map(String.init)
        // A scanned QR is untrusted input headed for sign-up attribution: accept only a well-formed code.
        if parts.count == 2, parts[0] == "r" { return Attribution.sanitized(parts[1]) }
        guard let ref = components.queryItems?.first(where: { $0.name == "ref" })?.value else { return nil }
        return Attribution.sanitized(ref)
    }
}
