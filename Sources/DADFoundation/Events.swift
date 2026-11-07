import Foundation

// Donor events & volunteering (PRD E-1..E-10, §6.11). Pure value types and the display /
// eligibility rules live here so event availability, the check-in window, invite-only
// gating and reservation transitions are unit-testable without a network, a camera, or UI.
//
// The server is always authoritative for reservation and check-in (capacity races, the
// exact window). These rules are the *client-side* pre-checks that drive what the UI
// offers and disables.

// MARK: - Reservation status (E-3, E-4)

/// Where the signed-in donor stands on one event. Mirrors the contract's `reservation_status`
/// string so the detail screen can render the right primary action without re-deriving it.
public enum ReservationStatus: String, Sendable, Equatable, Codable {
    case none
    case reserved
    case waitlisted
    case checkedIn = "checked_in"

    /// The contract sends unknown future values as strings; decode defensively to `.none`
    /// rather than failing the whole event list.
    public init(contract raw: String) {
        self = ReservationStatus(rawValue: raw) ?? .none
    }
}

// MARK: - Availability (E-2, E-3, E-4)

/// What the detail screen's primary action should offer, derived from capacity, the donor's
/// current standing, and the booking window. Keeping this a pure function of the event makes
/// the "reserve vs join waitlist vs full vs not-yet-open" decision testable.
public enum EventAvailability: Sendable, Equatable {
    /// Booking has not opened yet (early-booking gate) — show the open time, no action.
    case notYetOpen(opensAt: Date)
    /// The event has started and the donor holds nothing — the server refuses new reservations (409).
    case started
    /// Spots remain — offer Reserve.
    case reservable(spotsLeft: Int)
    /// Full — offer Join waitlist (E-4).
    case waitlistable
    /// Donor already holds a reservation — offer Cancel (E-9).
    case reserved
    /// Donor is on the waitlist — show waitlisted, offer leave.
    case waitlisted
    /// Donor already checked in — terminal, no action.
    case checkedIn
    /// Event cancelled by the organiser — no action.
    case cancelled
}

// MARK: - Event (the detail/list model, decoded from EventView)

/// One event as the list and detail screens render it. Independent of the generated
/// `EventView` so the domain + tests never import transport types; `WireAPI` maps across.
public struct DonorEvent: Sendable, Equatable, Identifiable {
    public let id: String
    public let slug: String
    public let title: String
    public let type: String
    public let venue: String
    public let city: String
    public let startsAt: Date
    public let endsAt: Date
    public let capacity: Int
    public let spotsLeft: Int
    public let status: ReservationStatus
    /// Present only for invite-only events the donor can see (E-5); nil = a public event.
    public let invitationNote: String?
    public let reportIssueURL: String?
    public let cancelled: Bool
    public let bookingOpensAt: Date?
    public let earlyBooking: Bool
    /// Free text from the organiser (E-3); empty when the server sent none.
    public let details: String
    /// Street address (E-3); empty when the server sent none.
    public let address: String
    /// IANA identifier of the venue's time zone (contract `time_zone`); empty when unknown.
    public let timeZoneID: String
    /// When the signed-in donor checked in (E-8); nil until they do.
    public let checkedInAt: Date?

    public init(
        id: String, slug: String, title: String, type: String, venue: String, city: String,
        startsAt: Date, endsAt: Date, capacity: Int, spotsLeft: Int, status: ReservationStatus,
        invitationNote: String? = nil, reportIssueURL: String? = nil, cancelled: Bool = false,
        bookingOpensAt: Date? = nil, earlyBooking: Bool = false, details: String = "", address: String = "",
        timeZoneID: String = "", checkedInAt: Date? = nil
    ) {
        self.id = id
        self.slug = slug
        self.title = title
        self.type = type
        self.venue = venue
        self.city = city
        self.startsAt = startsAt
        self.endsAt = endsAt
        self.capacity = capacity
        self.spotsLeft = spotsLeft
        self.status = status
        self.invitationNote = invitationNote
        self.reportIssueURL = reportIssueURL
        self.cancelled = cancelled
        self.bookingOpensAt = bookingOpensAt
        self.earlyBooking = earlyBooking
        self.details = details
        self.address = address
        self.timeZoneID = timeZoneID
        self.checkedInAt = checkedInAt
    }

    /// The venue's zone, or nil when the identifier is empty or unknown to this device.
    public var timeZone: TimeZone? { TimeZone(identifier: timeZoneID) }

    /// Whether this event is invite-only (E-5): the contract's INVITE_ONLY type, or an invitation note.
    public var isInviteOnly: Bool { invitationNote != nil || type.lowercased() == "invite_only" }

    /// The contract's `capacity` is 0 for an uncapped event (and `spots_left` is then null).
    public var isUncapped: Bool { capacity == 0 }

    /// "Volunteer" / "Community" / "Invite-only" (E-3), from the contract's upper-case type.
    public var typeLabel: String {
        switch type.lowercased() {
        case "volunteer": return "Volunteer"
        case "community": return "Community"
        case "invite_only": return "Invite-only"
        default: return type.isEmpty ? "Event" : type.prefix(1).uppercased() + type.dropFirst().lowercased()
        }
    }

    /// The signed-in donor's reservation or waitlist place can still be cancelled until the event
    /// starts (E-9); a cancelled event has nothing left to cancel.
    public func canCancel(now: Date) -> Bool {
        !cancelled && (status == .reserved || status == .waitlisted) && now < startsAt
    }

    /// The window in which check-in is accepted (E-8), exactly as the server enforces it.
    public var checkInWindow: CheckInWindow { CheckInWindow(startsAt: startsAt, endsAt: endsAt, timeZone: timeZone) }

    /// Check-in is for a held seat, not a waitlist place (the server answers 422 otherwise).
    public var canAttemptCheckIn: Bool { !cancelled && status == .reserved }

    /// The primary-action decision (E-3/E-4/E-9). `now` is injected so tests are deterministic.
    public func availability(now: Date) -> EventAvailability {
        if cancelled { return .cancelled }
        switch status {
        case .checkedIn: return .checkedIn
        case .reserved: return .reserved
        case .waitlisted: return .waitlisted
        case .none:
            if now >= startsAt { return .started }
            if let opens = bookingOpensAt, now < opens, !earlyBooking { return .notYetOpen(opensAt: opens) }
            if isUncapped { return .reservable(spotsLeft: Int.max) }
            return spotsLeft > 0 ? .reservable(spotsLeft: spotsLeft) : .waitlistable
        }
    }

    /// "3 spots left" / "Full" line for the list row and detail header.
    public var spotsLabel: String {
        if cancelled { return "Cancelled" }
        if isUncapped { return "Open to everyone" }
        if spotsLeft <= 0 { return "Full" }
        return spotsLeft == 1 ? "1 spot left" : "\(spotsLeft) spots left"
    }
}

// MARK: - Check-in window (E-8)

/// The client-side check-in gate. The server is authoritative, but the scanner should only
/// *offer* check-in inside the window and give a clear reason when it is too early / too late,
/// rather than firing a request that is bound to 422. The window opens at `startsAt` and closes
/// at `endsAt`, matching the contract.
public struct CheckInWindow: Sendable, Equatable {
    /// How long before `startsAt` check-in opens. The contract accepts a check-in only between the
    /// event's start and end (E-8), so there is no early grace; the server stays authoritative.
    public static let earlyGrace: TimeInterval = 0

    public let startsAt: Date
    public let endsAt: Date
    /// The event's zone, used only to word "opens at ..." messages; nil falls back to the device zone.
    public let timeZone: TimeZone?

    public init(startsAt: Date, endsAt: Date, timeZone: TimeZone? = nil) {
        self.startsAt = startsAt
        self.endsAt = endsAt
        self.timeZone = timeZone
    }

    public var opensAt: Date { startsAt.addingTimeInterval(-Self.earlyGrace) }

    public enum State: Sendable, Equatable {
        case tooEarly(opensAt: Date)
        case open
        case tooLate
    }

    public func state(now: Date) -> State {
        if now < opensAt { return .tooEarly(opensAt: opensAt) }
        if now > endsAt { return .tooLate }
        return .open
    }

    /// Whether the scanner should allow a check-in attempt right now.
    public func isOpen(now: Date) -> Bool { state(now: now) == .open }
}

// MARK: - Reservation outcome (E-4)

/// The result of a reserve attempt, from `ReservationResult.status`. Distinguishes a confirmed
/// seat from a waitlist placement so the confirmation screen shows the right copy (E-4).
public enum ReservationOutcome: Sendable, Equatable {
    case reserved
    case waitlisted

    public init(contract raw: String) {
        self = raw.lowercased() == "waitlisted" ? .waitlisted : .reserved
    }

    public var confirmationTitle: String {
        self == .waitlisted ? "You’re on the waitlist" : "You’re going"
    }

    public var confirmationDetail: String {
        self == .waitlisted
            ? "We’ll notify you if a spot opens up."
            : "Your spot is confirmed. Add it to your calendar so you don’t miss it."
    }
}

// MARK: - Time display (E-3)

/// Event times in the EVENT's time zone with the donor's locale (E-3), always with the zone abbreviation
/// so a time is never ambiguous. An explicit `timeZone` wins; otherwise the event's `time_zone`; the
/// device zone is only the fallback for an identifier this device does not know. Pure, so it is unit-tested.
public enum EventTime {
    public static func start(_ event: DonorEvent, timeZone: TimeZone? = nil, locale: Locale = .current) -> String {
        moment(event.startsAt, in: event, timeZone: timeZone, locale: locale)
    }

    /// "Wed, Nov 4, 3:00 PM CST" for any instant (booking opens, check-in opens) in the event's zone.
    public static func moment(_ date: Date, in event: DonorEvent, timeZone: TimeZone? = nil, locale: Locale = .current) -> String {
        moment(date, timeZone: resolve(event, timeZone), locale: locale)
    }

    public static func moment(_ date: Date, timeZone: TimeZone?, locale: Locale = .current) -> String {
        let zone = timeZone ?? .current
        let text = date.formatted(Self.style(.dateTime.weekday(.abbreviated).month(.abbreviated).day().hour().minute(), zone, locale))
        return "\(text) \(abbreviation(date, zone, locale))"
    }

    /// "Sat, Nov 7, 10:00 AM – 12:00 PM CST" (the end carries its date only when it is another day).
    public static func range(_ event: DonorEvent, timeZone: TimeZone? = nil, locale: Locale = .current) -> String {
        let zone = resolve(event, timeZone)
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = zone
        let startText = event.startsAt.formatted(Self.style(.dateTime.weekday(.abbreviated).month(.abbreviated).day().hour().minute(), zone, locale))
        let sameDay = calendar.isDate(event.startsAt, inSameDayAs: event.endsAt)
        let endText = event.endsAt.formatted(Self.style(sameDay
            ? .dateTime.hour().minute()
            : .dateTime.weekday(.abbreviated).month(.abbreviated).day().hour().minute(), zone, locale))
        return "\(startText) – \(endText) \(abbreviation(event.endsAt, zone, locale))"
    }

    private static func resolve(_ event: DonorEvent, _ explicit: TimeZone?) -> TimeZone { explicit ?? event.timeZone ?? .current }

    private static func style(_ format: Date.FormatStyle, _ timeZone: TimeZone, _ locale: Locale) -> Date.FormatStyle {
        var style = format
        style.timeZone = timeZone
        style.locale = locale
        return style
    }

    private static func abbreviation(_ date: Date, _ timeZone: TimeZone, _ locale: Locale) -> String {
        timeZone.localizedName(for: timeZone.isDaylightSavingTime(for: date) ? .shortDaylightSaving : .shortStandard, locale: locale)
            ?? timeZone.abbreviation(for: date) ?? timeZone.identifier
    }
}
