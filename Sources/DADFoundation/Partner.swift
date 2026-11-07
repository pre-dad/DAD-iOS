import Foundation

// Partner portal (PRD P-*, EM-*, §7). Pure value types and display rules live here so role
// gating, the "verified or hidden, never estimated" figure rule (§7.3), <5 suppression (EM-3),
// and last-updated rendering are unit-testable without a network or UI — the same "pure core,
// seam for I/O" shape as the donor phases (C/D/E).

// MARK: - Role (§7.2, P-4/P-5)

/// A partner user's role. ADMIN manages users, invites, profile and exports; VIEWER can only
/// read. Partner accounts can never donate (P-5) — that is enforced by the portal having no
/// giving surface at all, not by a flag here.
public enum PartnerRole: String, Sendable, Equatable, Codable {
    case admin = "ADMIN"
    case viewer = "VIEWER"

    /// Decode defensively — an unknown future role is treated as the least-privileged VIEWER
    /// rather than failing the whole overview.
    public init(contract raw: String) { self = PartnerRole(rawValue: raw) ?? .viewer }

    /// Capabilities the UI gates on (§7.2). Only an admin may invite/remove users, edit the
    /// organization profile/logo, or run an export. A viewer sees everything read-only.
    public var canManageUsers: Bool { self == .admin }
    public var canEditProfile: Bool { self == .admin }
    public var canExport: Bool { self == .admin }
}

// MARK: - Verified figures (§7.3 — hidden, never estimated)

/// One headline figure on the Overview. A figure is shown ONLY when the server marks it
/// verified; an unverified figure is HIDDEN (never estimated, never shown as a guess). This is
/// the §7.3 rule made a pure value so the Overview can't accidentally render an unverified number.
public struct VerifiedMoney: Sendable, Equatable {
    public let amountMinor: Int64
    public let verified: Bool
    public init(amountMinor: Int64, verified: Bool) {
        self.amountMinor = amountMinor
        self.verified = verified
    }
    /// The formatted figure when verified, or nil when it must be hidden.
    public var label: String? { verified ? formatUSDMinor(Int(amountMinor)) : nil }
}

public struct VerifiedCount: Sendable, Equatable {
    public let value: Int64
    public let verified: Bool
    public init(value: Int64, verified: Bool) {
        self.value = value
        self.verified = verified
    }
    public var label: String? { verified ? value.formatted(.number.locale(Locale(identifier: "en_US"))) : nil }
}

// MARK: - Overview (P-10, §7.3)

/// The partner Overview tiles. Each money/count figure pairs its value with a verified flag so
/// the UI renders it only when verified. `employeesEnrolled`/`enrolledPercent` are nullable
/// because they are <5-suppressed server-side (EM-3) — null means "too few to show", not zero.
public struct PartnerOverview: Sendable, Equatable {
    public let organization: String
    public let description: String
    public let userID: String
    public let role: PartnerRole
    public let companyCode: String
    public let committed: VerifiedMoney
    public let deployed: VerifiedMoney
    public let deployedPercent: Int
    public let peopleReached: VerifiedCount
    public let employeesEnrolled: Int64?
    public let workforceSize: Int
    public let enrolledPercent: Int?
    public let updatedAt: Date?
    public let hasLogo: Bool

    public init(organization: String, description: String, userID: String, role: PartnerRole, companyCode: String,
                committed: VerifiedMoney, deployed: VerifiedMoney, deployedPercent: Int,
                peopleReached: VerifiedCount, employeesEnrolled: Int64?, workforceSize: Int,
                enrolledPercent: Int?, updatedAt: Date?, hasLogo: Bool) {
        self.organization = organization
        self.description = description
        self.userID = userID
        self.role = role
        self.companyCode = companyCode
        self.committed = committed
        self.deployed = deployed
        self.deployedPercent = deployedPercent
        self.peopleReached = peopleReached
        self.employeesEnrolled = employeesEnrolled
        self.workforceSize = workforceSize
        self.enrolledPercent = enrolledPercent
        self.updatedAt = updatedAt
        self.hasLogo = hasLogo
    }

    /// "Enrolled: 42 of 120" or nil when suppressed (<5). Never shows a suppressed count.
    public var enrolledLabel: String? {
        guard let enrolled = employeesEnrolled else { return nil }
        return "\(enrolled) of \(workforceSize)"
    }

    /// The "Verified by DAD" assurance line with the figures' as-of date (§11 copy correction).
    /// When no figure has been verified yet, there is no date to stand behind, so returns nil.
    public func verifiedLine() -> String? {
        guard let updatedAt else { return nil }
        let df = DateFormatter()
        df.locale = Locale(identifier: "en_US_POSIX")
        df.dateStyle = .medium
        return "Verified by DAD · as of \(df.string(from: updatedAt))"
    }
}

// MARK: - Our People rollup (P-13, EM-3 suppression)

/// The workforce rollup. When `suppressed` is true the group is under the <5 threshold and the
/// UI must show the suppression notice instead of any individual-level figure (EM-3).
public struct PartnerPeople: Sendable, Equatable {
    public let enrolled: Int64
    public let workforceSize: Int
    public let givenMinor: Int64
    public let matchedMinor: Int64
    public let avgStreakDays: Int64
    public let volunteerMinutes: Int64
    public let teams: Int64
    public let suppressed: Bool

    public init(enrolled: Int64, workforceSize: Int, givenMinor: Int64, matchedMinor: Int64,
                avgStreakDays: Int64, volunteerMinutes: Int64, teams: Int64, suppressed: Bool) {
        self.enrolled = enrolled
        self.workforceSize = workforceSize
        self.givenMinor = givenMinor
        self.matchedMinor = matchedMinor
        self.avgStreakDays = avgStreakDays
        self.volunteerMinutes = volunteerMinutes
        self.teams = teams
        self.suppressed = suppressed
    }

    /// The total given across the enrolled workforce, or nil when suppressed (<5).
    public var givenLabel: String? { suppressed ? nil : formatUSDMinor(Int(givenMinor)) }
    /// The employer-matched total, or nil when suppressed.
    public var matchedLabel: String? { suppressed ? nil : formatUSDMinor(Int(matchedMinor)) }
    /// The suppression notice shown in place of figures when the group is too small (EM-3).
    public var suppressionNotice: String? {
        suppressed ? "Fewer than 5 people have enrolled, so individual figures are hidden." : nil
    }
}

// MARK: - Initiatives (P-11)

public enum InitiativeStatus: String, Sendable, Equatable, Codable {
    case active = "ACTIVE"
    case complete = "COMPLETE"
    public init(contract raw: String) { self = InitiativeStatus(rawValue: raw) ?? .active }
    public var label: String { self == .active ? "Active" : "Complete" }
}

/// One partner initiative tile (P-11). At most three headline metrics (§7.2), each carrying its
/// own verified-on date so the UI can show provenance.
public struct PartnerInitiative: Sendable, Equatable {
    public let id: String
    public let title: String
    public let summary: String
    public let status: InitiativeStatus
    public let region: String
    public let committedMinor: Int64
    public let deployedMinor: Int64
    public let metrics: [PartnerMetric]

    public init(id: String, title: String, summary: String, status: InitiativeStatus,
                region: String, committedMinor: Int64, deployedMinor: Int64, metrics: [PartnerMetric]) {
        self.id = id
        self.title = title
        self.summary = summary
        self.status = status
        self.region = region
        self.committedMinor = committedMinor
        self.deployedMinor = deployedMinor
        self.metrics = metrics
    }

    /// At most three headline metrics (§7.2) so the tile never over-renders.
    public var headlineMetrics: [PartnerMetric] { Array(metrics.prefix(3)) }
    public var committedLabel: String { formatUSDMinor(Int(committedMinor)) }
    public var deployedLabel: String { formatUSDMinor(Int(deployedMinor)) }
}

public struct PartnerMetric: Sendable, Equatable {
    public enum Unit: String, Sendable, Equatable, Codable {
        case usdCents = "USD_CENTS"
        case people = "PEOPLE"
        case initiatives = "INITIATIVES"
        case partners = "PARTNERS"
        public init(contract raw: String) { self = Unit(rawValue: raw) ?? .people }
    }
    public let label: String
    public let value: Int64
    public let unit: Unit
    public init(label: String, value: Int64, unit: Unit) {
        self.label = label
        self.value = value
        self.unit = unit
    }
    /// Render the value in its unit: money as $, everything else as a grouped count.
    public var valueLabel: String {
        switch unit {
        case .usdCents: return formatUSDMinor(Int(value))
        default: return value.formatted(.number.locale(Locale(identifier: "en_US")))
        }
    }
}

// MARK: - Users (P-13 management)

public struct PartnerUser: Sendable, Equatable, Identifiable {
    public let id: String
    public let email: String
    public let name: String
    public let role: PartnerRole
    public init(id: String, email: String, name: String, role: PartnerRole) {
        self.id = id
        self.email = email
        self.name = name
        self.role = role
    }
}

// MARK: - Spend (P-12, totals only)

public struct PartnerSpendCategory: Sendable, Equatable {
    public let category: String
    public let amountMinor: Int64
    public init(category: String, amountMinor: Int64) {
        self.category = category
        self.amountMinor = amountMinor
    }
    public var amountLabel: String { formatUSDMinor(Int(amountMinor)) }
}
