import Foundation

// Analytics instrumentation (PRD §9). A single typed event sink maps the §9 taxonomy to the
// shared ingest schema (POST /analytics/events). The taxonomy, the per-event typed-property
// rules, and the batch envelope live here as pure values so emission is unit-testable without a
// network.

/// The §9 analytics events. Raw values are the exact wire names the ingest enum accepts, so an
/// event can never be mis-spelled at a call site.
public enum AnalyticsEvent: String, Sendable, Equatable, CaseIterable, Codable {
    case appOpened = "app_opened"
    case roleSelected = "role_selected"
    case signupStarted = "signup_started"
    case signupCompleted = "signup_completed"
    case attributionCaptured = "attribution_captured"
    case giftStarted = "gift_started"
    case giftCompleted = "gift_completed"
    case giftFailed = "gift_failed"
    case giftRecovered = "gift_recovered"
    case giftLapsed = "gift_lapsed"
    case amountChanged = "amount_changed"
    case giftCancelled = "gift_cancelled"
    case accountDeleted = "account_deleted"
    case inviteShared = "invite_shared"
    case irlCodeShown = "irl_code_shown"
    case referralConverted = "referral_converted"
    case badgeEarned = "badge_earned"
    case milestoneReached = "milestone_reached"
    case rankingsToggled = "rankings_toggled"
    case volunteerOptedIn = "volunteer_opted_in"
    case eventViewed = "event_viewed"
    case eventReserved = "event_reserved"
    case eventWaitlisted = "event_waitlisted"
    case eventCheckedIn = "event_checked_in"
    case teamCreated = "team_created"
    case teamJoined = "team_joined"
    case partnerSignupSubmitted = "partner_signup_submitted"
    case partnerApproved = "partner_approved"
    case partnerReportExported = "partner_report_exported"
    case pushOpened = "push_opened"

    /// The property key this event REQUIRES, or nil when it takes no properties. The ingest schema
    /// only accepts these three carriers (§9): attribution_captured{source}, invite_shared{channel},
    /// push_opened{type}. Everything else must send no properties.
    public var requiredPropertyKey: String? {
        switch self {
        case .attributionCaptured: return "source"
        case .inviteShared: return "channel"
        case .pushOpened: return "type"
        default: return nil
        }
    }
}

/// A single analytics event ready for the sink. `id` makes delivery idempotent (a retried batch
/// carries the same ids); `journeyID` groups a flow (e.g. a whole signup). Construction validates
/// the typed-property rule so an invalid event can never be buffered.
public struct AnalyticsRecord: Sendable, Equatable, Identifiable {
    public let id: UUID
    public let name: AnalyticsEvent
    public let occurredAt: Date
    public let properties: [String: String]
    public let journeyID: UUID?

    public enum ValidationError: Error, Equatable {
        case missingRequiredProperty(String)
        case unexpectedProperties
        case invalidValue(String)
    }

    /// The only `attribution_captured.source` values the ingest accepts (case-sensitive).
    public static let attributionSources: Set<String> = ["link", "IRL", "company"]

    /// Build a validated record. Throws when a carrier event is missing its required key, or when
    /// a no-property event is given properties — mirroring what the server would reject.
    public init(
        _ name: AnalyticsEvent, occurredAt: Date = Date(), properties: [String: String] = [:],
        id: UUID = UUID(), journeyID: UUID? = nil
    ) throws {
        if let key = name.requiredPropertyKey {
            guard properties.count <= 1 else { throw ValidationError.unexpectedProperties }
            guard let value = properties[key], !value.isEmpty else {
                throw ValidationError.missingRequiredProperty(key)
            }
            if name == .attributionCaptured, !Self.attributionSources.contains(value) {
                throw ValidationError.invalidValue(key)
            }
        } else if !properties.isEmpty {
            throw ValidationError.unexpectedProperties
        }
        self.id = id
        self.name = name
        self.occurredAt = occurredAt
        self.properties = properties
        self.journeyID = journeyID
    }
}

/// A batch of records for one ingest call. The schema caps a batch at 100 events, so the envelope
/// enforces the cap by chunking — the recorder flushes one `AnalyticsBatch` per chunk.
public struct AnalyticsBatch: Sendable, Equatable {
    public static let maxEvents = 100

    public let events: [AnalyticsRecord]

    public enum BatchError: Error, Equatable {
        case empty
        case tooLarge
    }

    public init(_ events: [AnalyticsRecord]) throws {
        guard !events.isEmpty else { throw BatchError.empty }
        guard events.count <= Self.maxEvents else { throw BatchError.tooLarge }
        self.events = events
    }

    private init(validated events: ArraySlice<AnalyticsRecord>) {
        self.events = Array(events)
    }

    /// Split a buffer into wire-legal batches (1...100 each), preserving order.
    public static func chunk(_ records: [AnalyticsRecord]) -> [AnalyticsBatch] {
        stride(from: 0, to: records.count, by: maxEvents).map { start in
            AnalyticsBatch(validated: records[start..<min(start + maxEvents, records.count)])
        }
    }
}
