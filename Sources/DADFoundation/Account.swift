import Foundation

// Account & settings (PRD §6.11, §6.12). The App Store mandates an in-app account-deletion flow.
// Pure value types so the preferences block, its optimistic version, and the delete-account
// confirm gate are unit-testable without I/O.

/// The account header settings shows. `accountRole` is fixed at creation and immutable (D-1), so
/// it is display-only; the saved time zone controls the streak’s local-day rollover (§10).
public struct AccountProfileSummary: Sendable, Equatable {
    public let email: String
    public let accountRole: String
    public let zip: String?
    public let city: String?
    public let phone: String?
    public let timezone: String?
    public let timezoneOverride: String?

    public init(email: String, accountRole: String, zip: String?, city: String?, phone: String?, timezone: String? = nil, timezoneOverride: String? = nil) {
        self.email = email
        self.accountRole = accountRole
        self.zip = zip
        self.city = city
        self.phone = phone
        self.timezone = timezone; self.timezoneOverride = timezoneOverride
    }

    public var zipLabel: String {
        guard let zip, !zip.isEmpty else { return "Not set" }
        return zip
    }
}

/// The donor's preference block, carrying the optimistic-concurrency `version` it was read at so a
/// stale overwrite is rejected server-side. Payment-failure email is deliberately absent — it is
/// non-toggleable server-side.
public struct AccountPreferences: Sendable, Equatable {
    public let version: Int
    public var referralEmails: Bool
    public var marketingEmails: Bool
    public var pushReferralConverted: Bool
    public var pushStreakAtRisk: Bool
    public var pushStreakMilestone: Bool
    public var pushStreakLapsed: Bool
    public var pushBadgeEarned: Bool
    public var pushEventNearby: Bool
    public var pushEventReminder: Bool
    public var pushEventPromoted: Bool
    public var pushGiftProcessed: Bool
    public var rankingsOptedOut: Bool
    public var networkVisible: Bool
    public var volunteer: Bool
    /// Free-form event interests (E-1), already trimmed and unique.
    public private(set) var volunteerInterests: [String]
    /// Set once the donor edits the interests; only then are they sent on save. Otherwise the field
    /// is omitted and the server keeps what it has.
    public private(set) var volunteerInterestsEdited = false

    public static let maxInterests = 20
    public static let maxInterestLength = 60

    public init(
        version: Int, referralEmails: Bool, marketingEmails: Bool, pushReferralConverted: Bool,
        pushStreakAtRisk: Bool, pushStreakMilestone: Bool, pushStreakLapsed: Bool,
        pushBadgeEarned: Bool, pushEventNearby: Bool, pushEventReminder: Bool,
        pushEventPromoted: Bool, pushGiftProcessed: Bool, rankingsOptedOut: Bool,
        networkVisible: Bool, volunteer: Bool, volunteerInterests: [String] = []
    ) {
        self.version = version
        self.referralEmails = referralEmails
        self.marketingEmails = marketingEmails
        self.pushReferralConverted = pushReferralConverted
        self.pushStreakAtRisk = pushStreakAtRisk
        self.pushStreakMilestone = pushStreakMilestone
        self.pushStreakLapsed = pushStreakLapsed
        self.pushBadgeEarned = pushBadgeEarned
        self.pushEventNearby = pushEventNearby
        self.pushEventReminder = pushEventReminder
        self.pushEventPromoted = pushEventPromoted
        self.pushGiftProcessed = pushGiftProcessed
        self.rankingsOptedOut = rankingsOptedOut
        self.networkVisible = networkVisible
        self.volunteer = volunteer
        self.volunteerInterests = volunteerInterests
    }

    public struct Toggle: Sendable, Equatable {
        public let key: String
        public let label: String
        public let value: Bool
    }

    private struct Field: Sendable {
        let key: String
        /// Nil for a flag the settings screen does not list as a push or email row.
        let label: String?
        let path: WritableKeyPath<AccountPreferences, Bool> & Sendable
        init(_ key: String, _ label: String?, _ path: WritableKeyPath<AccountPreferences, Bool> & Sendable) {
            self.key = key; self.label = label; self.path = path
        }
    }

    private static let pushFields: [Field] = [
        Field("push_referral_converted", "Someone joined through you", \.pushReferralConverted),
        Field("push_streak_at_risk", "Streak at risk", \.pushStreakAtRisk),
        Field("push_streak_milestone", "Streak milestone", \.pushStreakMilestone),
        Field("push_streak_lapsed", "Streak lapsed", \.pushStreakLapsed),
        Field("push_badge_earned", "Badge earned", \.pushBadgeEarned),
        Field("push_event_nearby", "Events nearby", \.pushEventNearby),
        Field("push_event_reminder", "Event reminders", \.pushEventReminder),
        Field("push_event_promoted", "Event promoted", \.pushEventPromoted),
        Field("push_gift_processed", "Gift processed", \.pushGiftProcessed),
    ]

    private static let emailFields: [Field] = [
        Field("referral_emails", "Referral emails", \.referralEmails),
        Field("marketing_emails", "Marketing emails", \.marketingEmails),
    ]

    /// Keys for the privacy and volunteering flags the settings screen shows outside the push and email rows.
    public static let rankingsOptedOutKey = "rankings_opted_out"
    public static let networkVisibleKey = "network_visible"
    public static let volunteerKey = "volunteer"

    /// Toggles flipped by key that the settings screen does not list as push or email rows.
    private static let otherFields: [Field] = [
        Field(rankingsOptedOutKey, nil, \.rankingsOptedOut),
        Field(networkVisibleKey, nil, \.networkVisible),
        Field(volunteerKey, nil, \.volunteer),
    ]

    /// The push category toggles (§6.11), in display order. Payment-failure email is absent
    /// (non-toggleable server-side).
    public var pushToggles: [Toggle] { Self.toggles(Self.pushFields, of: self) }

    public var emailToggles: [Toggle] { Self.toggles(Self.emailFields, of: self) }

    private static func toggles(_ fields: [Field], of preferences: AccountPreferences) -> [Toggle] {
        fields.compactMap { field in
            field.label.map { Toggle(key: field.key, label: $0, value: preferences[keyPath: field.path]) }
        }
    }

    /// Inverted for display: "Show my ranking" = NOT opted out.
    public var showRanking: Bool { !rankingsOptedOut }

    /// A copy with `text` added to the interests, or why it cannot be: blank text, over the length limit,
    /// already present (ignoring case), or the list is full.
    public func addingInterest(_ text: String) -> Result<AccountPreferences, InterestError> {
        let interest = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !interest.isEmpty else { return .failure(.empty) }
        guard interest.count <= Self.maxInterestLength else { return .failure(.tooLong) }
        guard !volunteerInterests.contains(where: { $0.caseInsensitiveCompare(interest) == .orderedSame }) else {
            return .failure(.duplicate)
        }
        guard volunteerInterests.count < Self.maxInterests else { return .failure(.full) }
        var copy = self
        copy.volunteerInterests.append(interest)
        copy.volunteerInterestsEdited = true
        return .success(copy)
    }

    /// A copy without `interest`; unknown values return self unchanged.
    public func removingInterest(_ interest: String) -> AccountPreferences {
        guard volunteerInterests.contains(interest) else { return self }
        var copy = self
        copy.volunteerInterests.removeAll { $0 == interest }
        copy.volunteerInterestsEdited = true
        return copy
    }

    public enum InterestError: Error, Sendable, Equatable {
        case empty, tooLong, duplicate, full

        public var message: String {
            switch self {
            case .empty: "Type an interest to add."
            case .tooLong: "Keep each interest to \(AccountPreferences.maxInterestLength) characters or fewer."
            case .duplicate: "That interest is already on your list."
            case .full: "You can list up to \(AccountPreferences.maxInterests) interests."
            }
        }
    }

    /// A copy with one toggle flipped by key; an unknown key returns self unchanged.
    public func with(_ key: String, _ value: Bool) -> AccountPreferences {
        guard let field = (Self.pushFields + Self.emailFields + Self.otherFields).first(where: { $0.key == key }) else { return self }
        var copy = self
        copy[keyPath: field.path] = value
        return copy
    }
}

/// The delete-account confirm gate. Deletion is irreversible (backend removes personal data, keeps
/// legally-required gift records), so the donor must type the exact word before the action enables.
public struct DeleteAccountGate: Sendable, Equatable {
    public static let confirmWord = "DELETE"

    public let typed: String
    public init(typed: String) { self.typed = typed }

    public var isConfirmed: Bool { typed == Self.confirmWord }

    public var helpText: String {
        "This permanently deletes your personal data. Your required gift records are kept. " +
            "Type \(Self.confirmWord) to confirm."
    }
}
