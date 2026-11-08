import Foundation

// Donor giving core (PRD G-*, S-*, §6.12). Pure value types and the amount rule live
// here so the arithmetic and state transitions are unit-testable without a network or UI.

/// A validated recurring gift amount. The canonical unit is integer USD cents charged
/// monthly; the product rule (G-1/G-2) is a whole number of dollars a day, $1…$30, times 30.
/// Construction is the only place the rule is enforced, so an out-of-range amount cannot exist.
public struct GiftAmount: Sendable, Equatable, Hashable, Comparable {
    /// Dollars per day, 1…30.
    public let dailyDollars: Int
    /// Monthly charge in integer USD cents (dailyDollars × 30 × 100 == dailyDollars × 3000).
    public var monthlyMinor: Int { dailyDollars * Self.centsPerDailyDollar }

    /// The $1/day floor, for callers that need a starting amount without handling the failable initializers.
    public static let minimum = GiftAmount(uncheckedDailyDollars: minDailyDollars)

    private init(uncheckedDailyDollars: Int) { dailyDollars = uncheckedDailyDollars }

    public static let minDailyDollars = 1
    public static let maxDailyDollars = 30
    /// A daily dollar maps to this many monthly cents: $1/day → $30/month → 3000¢.
    public static let centsPerDailyDollar = 3000

    /// Build from a per-day dollar figure, clamped to the $1…$30 rule. Returns nil only
    /// for a non-positive input; values above the ceiling clamp to $30 rather than fail,
    /// so a slider cannot wedge.
    public init?(dailyDollars: Int) {
        guard dailyDollars >= 1 else { return nil }
        self.dailyDollars = min(dailyDollars, Self.maxDailyDollars)
    }

    /// Reconstruct from a monthly-cents figure returned by the API. Accepts only exact
    /// multiples of the $1/day step within range; anything else (a legacy amount predating
    /// the daily rule) returns nil so the caller shows it as a raw figure, not a daily tier.
    public init?(monthlyMinor: Int) {
        guard monthlyMinor >= Self.minDailyDollars * Self.centsPerDailyDollar,
              monthlyMinor <= Self.maxDailyDollars * Self.centsPerDailyDollar,
              monthlyMinor % Self.centsPerDailyDollar == 0 else { return nil }
        self.dailyDollars = monthlyMinor / Self.centsPerDailyDollar
    }

    public static func < (lhs: GiftAmount, rhs: GiftAmount) -> Bool { lhs.dailyDollars < rhs.dailyDollars }

    /// "$5/day" — the headline the set-gift screen shows.
    public var dailyLabel: String { "$\(dailyDollars)/day" }
    /// "$150/mo" — the monthly equivalent, derived, never entered directly.
    public var monthlyLabel: String { "$\(monthlyMinor / 100)/mo" }
}

/// Format an integer-cents USD figure as "$12.34" / "$150" / "$1,240". Whole-dollar amounts drop
/// the decimals; thousands are grouped for readability (WCAG). Display-only, never used for
/// arithmetic. The formatter is pinned to en_US_POSIX so grouping is stable regardless of host
/// locale, and cached because NumberFormatter construction is expensive.
private let usdWholeFormatter: NumberFormatter = {
    let f = NumberFormatter()
    f.numberStyle = .decimal
    f.locale = Locale(identifier: "en_US_POSIX")
    f.usesGroupingSeparator = true
    f.groupingSeparator = ","
    f.groupingSize = 3
    f.maximumFractionDigits = 0
    return f
}()

private let usdCentsFormatter: NumberFormatter = {
    let f = NumberFormatter()
    f.numberStyle = .decimal
    f.locale = Locale(identifier: "en_US_POSIX")
    f.usesGroupingSeparator = true
    f.groupingSeparator = ","
    f.groupingSize = 3
    f.decimalSeparator = "."
    f.minimumFractionDigits = 2
    f.maximumFractionDigits = 2
    return f
}()

public func formatUSDMinor(_ minor: Int) -> String {
    if minor % 100 == 0 {
        let whole = usdWholeFormatter.string(from: NSNumber(value: minor / 100)) ?? "\(minor / 100)"
        return "$\(whole)"
    }
    let dollars = usdCentsFormatter.string(from: NSNumber(value: Double(minor) / 100)) ?? String(format: "%.2f", Double(minor) / 100)
    return "$\(dollars)"
}

/// The recurring gift as the giving screens see it: either none set yet, or an active
/// subscription, or one scheduled to stop at period end (the cancel path, G-8/G-9).
public enum RecurringState: Sendable, Equatable {
    case none
    /// The server has a gift in progress but has not counted it yet (`state: preparing`).
    case preparing
    case active(subscriptionID: String, amountMinor: Int, periodEnd: Date)
    /// Cancelled but still running until `stopsAt` — the streak continues until then.
    case ending(subscriptionID: String, amountMinor: Int, periodEnd: Date, stopsAt: Date)

    /// The subscription id recurring commands (change amount, cancel) need, when one exists.
    public var subscriptionID: String? {
        switch self {
        case .none, .preparing: return nil
        case let .active(id, _, _), let .ending(id, _, _, _): return id
        }
    }

    public var amountMinor: Int? {
        switch self {
        case .none, .preparing: return nil
        case let .active(_, amount, _), let .ending(_, amount, _, _): return amount
        }
    }

    public var isEnding: Bool { if case .ending = self { return true }; return false }

    public func heading(hasLoaded: Bool) -> String {
        guard hasLoaded else { return "Your monthly gift" }
        switch self {
        case .none: return "Start a monthly gift"
        case .preparing: return "Your gift is on its way"
        case .active: return "Your monthly gift"
        case .ending: return "Your gift is ending"
        }
    }
}

/// What the amount endpoint offers for the subscription: the amount the next renewal will charge,
/// when, and a change that is already on its way (queued but not yet confirmed, or confirmed and
/// waiting for its effective date). Minor units are integer USD cents.
public struct AmountOffer: Sendable, Equatable {
    public struct Pending: Sendable, Equatable {
        public let amountMinor: Int
        public let previousMinor: Int
        public let effectiveAt: Date
        public let confirmed: Bool
        public init(amountMinor: Int, previousMinor: Int, effectiveAt: Date, confirmed: Bool) {
            self.amountMinor = amountMinor; self.previousMinor = previousMinor
            self.effectiveAt = effectiveAt; self.confirmed = confirmed
        }
    }
    public let subscriptionID: String
    public let nextAmountMinor: Int
    public let effectiveAt: Date
    public let pending: Pending?
    public init(subscriptionID: String, nextAmountMinor: Int, effectiveAt: Date, pending: Pending? = nil) {
        self.subscriptionID = subscriptionID; self.nextAmountMinor = nextAmountMinor
        self.effectiveAt = effectiveAt; self.pending = pending
    }
}

/// Where the payment-method update (the hosted card page) stands, from `GET /donor/me/payment-method`.
public struct PaymentMethodState: Sendable, Equatable {
    public enum Kind: String, Sendable, Equatable { case none, pending, open, applied, expired, cancelled }
    public let kind: Kind
    public let completedAt: Date?
    public init(kind: Kind, completedAt: Date? = nil) { self.kind = kind; self.completedAt = completedAt }
    /// An update is in flight: the donor started it and the server has not finished it.
    public var isInFlight: Bool { kind == .pending || kind == .open }
}

/// Copy for the cancel confirmation (G-8/G-9): cancelling ends the recurring gift at the
/// current period end and the streak lapses after that — stated plainly, counsel owns no
/// part of this string so it stays inline and testable.
public enum CancelCopy {
    public static func confirmation(periodEnd: Date, calendar: Calendar = .current) -> String {
        let formatter = DateFormatter()
        formatter.calendar = calendar
        formatter.timeZone = calendar.timeZone
        formatter.dateStyle = .medium
        formatter.timeStyle = .none
        let date = formatter.string(from: periodEnd)
        return "Your gift stays active until \(date). After that it won’t renew and your streak ends."
    }
}
