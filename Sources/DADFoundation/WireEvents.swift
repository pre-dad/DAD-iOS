import Foundation
import OpenAPIRuntime

/// Real events service (PRD E-1..E-10) over the generated client: `donorEvents` + `inviteOnlyEvents`
/// (merged), `donorEventDetail`, `reserveEvent`, `cancelEvent`, `checkInEvent` and `donorEventCalendar`,
/// each authorized through the session (single refresh + one retry on 401).
///
/// Status mapping: 401 -> signed out; 403 -> forbidden (not eligible to reserve/cancel/check in);
/// 404 -> not found (gone, or hidden by the invite-only gate); 409 -> conflict (full, started,
/// booking not open yet, or the reservation changed); 422 -> invalid input (a check-in the server
/// refuses: outside the window, no held seat, unknown code); 429 (with or without a body: the
/// ingress limiter sends none) -> rate limited; anything else, or a body that does not decode ->
/// unavailable. Cancellation propagates untouched so the model keeps its prior state.
///
/// The contract defines no Idempotency-Key for these commands: reserve, cancel and check-in are naturally
/// idempotent server-side, so retrying after a lost response is safe. The model still refuses a second
/// command for an event while one is in flight (double-tap guard), so no key is invented here.
public struct WireEvents: EventsService {
    private let product: ProductClient
    /// Defensive caps: a larger body is truncated rather than trusted.
    static let eventRowLimit = 200
    static let calendarByteLimit = 64 * 1024

    public init(origin: URL, session: AccountSession) throws {
        self.init(product: try ProductClient(origin: origin, session: session))
    }

    init(product: ProductClient) { self.product = product }

    public func events() async throws -> [DonorEvent] {
        let own = try await product.call { client in
            switch try await client.donorEvents(.init()) {
            case .ok(let response): return try response.body.json.events
            case .unauthorized: throw AccountError.signedOut
            case .tooManyRequests: throw AccountError.rateLimited
            case .serviceUnavailable: throw AccountError.unavailable
            case .undocumented(let status, _): throw AccountError.forStatus(status)
            }
        }
        let gated = try await product.call { client in
            switch try await client.inviteOnlyEvents(.init()) {
            case .ok(let response): return try response.body.json.events
            case .unauthorized: throw AccountError.signedOut
            case .tooManyRequests: throw AccountError.rateLimited
            case .serviceUnavailable: throw AccountError.unavailable
            case .undocumented(let status, _): throw AccountError.forStatus(status)
            }
        }
        // The same event may appear in both reads; keep one, then soonest-first (E-2).
        var seen = Set<String>()
        return (own + gated).filter { seen.insert($0.id).inserted }
            .prefix(Self.eventRowLimit).map(Self.map).sorted { $0.startsAt < $1.startsAt }
    }

    public func event(id: String) async throws -> DonorEvent {
        try Self.requireID(id)
        return try await product.call { client in
            switch try await client.donorEventDetail(.init(path: .init(event_id: id))) {
            case .ok(let response): return Self.map(try response.body.json)
            case .unauthorized: throw AccountError.signedOut
            case .notFound: throw AccountError.notFound
            case .tooManyRequests: throw AccountError.rateLimited
            case .serviceUnavailable: throw AccountError.unavailable
            case .undocumented(let status, _): throw AccountError.forStatus(status)
            }
        }
    }

    public func reserve(eventID: String) async throws -> ReservationOutcome {
        try Self.requireID(eventID)
        return try await product.call { client in
            switch try await client.reserveEvent(.init(path: .init(event_id: eventID))) {
            case .ok(let response):
                // An open string: only the two outcomes a reserve can produce are accepted.
                switch try response.body.json.status.uppercased() {
                case "RESERVED": return .reserved
                case "WAITLISTED": return .waitlisted
                default: throw AccountError.invalidResponse
                }
            case .unauthorized: throw AccountError.signedOut
            case .forbidden: throw AccountError.forbidden
            case .notFound: throw AccountError.notFound
            case .conflict: throw AccountError.conflict
            case .tooManyRequests: throw AccountError.rateLimited
            case .serviceUnavailable: throw AccountError.unavailable
            case .undocumented(let status, _): throw AccountError.forStatus(status)
            }
        }
    }

    public func cancel(eventID: String) async throws {
        try Self.requireID(eventID)
        try await product.call { client in
            switch try await client.cancelEvent(.init(path: .init(event_id: eventID))) {
            case .ok(let response):
                // Anything but CANCELLED means the server did not do what was asked: do not report success.
                guard try response.body.json.status.uppercased() == "CANCELLED" else { throw AccountError.invalidResponse }
            case .unauthorized: throw AccountError.signedOut
            case .forbidden: throw AccountError.forbidden
            case .notFound: throw AccountError.notFound
            case .conflict: throw AccountError.conflict
            case .tooManyRequests: throw AccountError.rateLimited
            case .serviceUnavailable: throw AccountError.unavailable
            case .undocumented(let status, _): throw AccountError.forStatus(status)
            }
        }
    }

    public func checkIn(code: String) async throws -> CheckInResultValue {
        // A token is exactly `<22 base64url>.<43 base64url>`; refuse anything else before it becomes a request.
        guard CheckInToken.isWellFormed(code) else { throw AccountError.invalidInput }
        return try await product.call { client in
            switch try await client.checkInEvent(.init(body: .json(.init(token: code)))) {
            case .ok(let response):
                let value = try response.body.json
                return CheckInResultValue(eventID: value.event_id, checkedIn: value.checked_in, alreadyCheckedIn: value.already_checked_in)
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

    public func calendar(eventID: String) async throws -> Data {
        try Self.requireID(eventID)
        return try await product.call { client in
            switch try await client.donorEventCalendar(.init(path: .init(event_id: eventID))) {
            case .ok(let response):
                let body = try response.body.text_calendar
                // A body over the cap throws from `collecting`; it is not an event file, so unavailable.
                guard let bytes = try? await Data(collecting: body, upTo: Self.calendarByteLimit) else { throw AccountError.invalidResponse }
                return bytes
            case .unauthorized: throw AccountError.signedOut
            case .notFound: throw AccountError.notFound
            case .tooManyRequests: throw AccountError.rateLimited
            case .serviceUnavailable: throw AccountError.unavailable
            case .undocumented(let status, _): throw AccountError.forStatus(status)
            }
        }
    }

    // MARK: - helpers

    /// A malformed id is a 404 server-side; refuse it before it becomes a path segment.
    private static func requireID(_ id: String) throws {
        guard UUID(uuidString: id) != nil else { throw AccountError.invalidInput }
    }

    static func map(_ value: Components.Schemas.EventView) -> DonorEvent {
        // `reservation_status` is an open string (unknown values mean no usable reservation). A donor who
        // checked in keeps RESERVED on the wire; `checked_in_at` is what makes the event "checked in".
        var status: ReservationStatus
        switch value.reservation_status?.uppercased() {
        case "RESERVED"?: status = .reserved
        case "WAITLISTED"?: status = .waitlisted
        default: status = .none
        }
        if status == .reserved, value.checked_in_at != nil { status = .checkedIn }
        return DonorEvent(
            id: value.id, slug: value.slug, title: value.title, type: value._type.lowercased(), venue: value.venue,
            city: value.city, startsAt: value.starts_at, endsAt: value.ends_at, capacity: Int(value.capacity),
            spotsLeft: value.spots_left.map(Int.init) ?? 0, status: status, invitationNote: value.invitation_note,
            reportIssueURL: value.report_issue_url, cancelled: value.cancelled, bookingOpensAt: value.booking_opens_at,
            earlyBooking: value.early_booking, details: value.description, address: value.address,
            timeZoneID: value.time_zone, checkedInAt: value.checked_in_at)
    }
}
