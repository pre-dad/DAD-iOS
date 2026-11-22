import Foundation

// Events view models + the service seam. The models own explicit load/ready/failed state and
// the reserve/cancel/check-in transitions, so they are unit-tested without a network, a camera,
// or UI.

/// The seam the events models call. A conformer maps to the generated client (WireEvents) or a
/// preview/test double; all value types so the models stay testable. The server is
/// authoritative — these calls can throw (401/403/404/409/422/429) and the models surface that.
public protocol EventsService: Sendable {
    /// Events near the donor, soonest-first (E-2). Includes any invite-only events the donor
    /// is eligible to see (E-5); the service merges public + invite-only server-side.
    func events() async throws -> [DonorEvent]
    /// One event's detail (E-3).
    func event(id: String) async throws -> DonorEvent
    /// Reserve or join the waitlist (E-4). Returns the outcome so the model shows the right copy.
    func reserve(eventID: String) async throws -> ReservationOutcome
    /// Cancel a reservation (E-9).
    func cancel(eventID: String) async throws
    /// Check in with a scanned code (E-8). The server validates the window and returns whether
    /// the check-in took (or was already recorded).
    func checkIn(code: String) async throws -> CheckInResultValue
    /// The authenticated `.ics` for one event, including invite-only events (E-6).
    func calendar(eventID: String) async throws -> Data
}

/// What the donor was doing when a call failed, so the sentence names the right problem.
public enum EventAction: Sendable, Equatable { case load, reserve, cancel, checkIn, calendar }

extension Error {
    /// The one user-facing sentence for a failed events call. 403 means "not eligible" here (not the
    /// giving copy `userMessage` uses); detail from the server is never shown.
    func eventMessage(for action: EventAction) -> String {
        guard let account = self as? AccountError else { return userMessage }
        switch (account, action) {
        case (.forbidden, .reserve): return "You’re not eligible to reserve this event."
        case (.forbidden, .cancel): return "You can’t cancel this reservation."
        case (.forbidden, .checkIn): return "You’re not eligible to check in to this event."
        case (.forbidden, _): return "Events aren’t available for this account."
        case (.conflict, .reserve): return "This event just filled up or isn’t open for booking. We’ve refreshed it."
        case (.conflict, .cancel): return "Your reservation changed. We’ve refreshed it; please review it."
        case (.conflict, _): return "This event changed. We’ve refreshed it."
        case (.notFound, _): return "This event isn’t available any more."
        case (.invalidInput, .checkIn):
            return "That code didn’t work. Check-in needs a reserved seat, the code shown at the venue, and has to happen during the event."
        case (.invalidInput, _): return "Something went wrong. Please try again."
        default: return userMessage
        }
    }
}

/// The shape of a check-in token: exactly `<22 base64url>.<43 base64url>` (66 characters).
public enum CheckInToken {
    public static let length = 66
    public static func isWellFormed(_ code: String) -> Bool {
        let parts = code.split(separator: ".", omittingEmptySubsequences: false)
        guard code.utf8.count == length, parts.count == 2, parts[0].utf8.count == 22, parts[1].utf8.count == 43 else { return false }
        return code.utf8.allSatisfy { $0 == 0x2E || $0 == 0x2D || $0 == 0x5F || ($0 >= 0x30 && $0 <= 0x39) || ($0 >= 0x41 && $0 <= 0x5A) || ($0 >= 0x61 && $0 <= 0x7A) }
    }
}

/// Domain mirror of the contract's `CheckInResult` so the model/tests never import transport.
public struct CheckInResultValue: Sendable, Equatable {
    public let eventID: String
    public let checkedIn: Bool
    public let alreadyCheckedIn: Bool

    public init(eventID: String, checkedIn: Bool, alreadyCheckedIn: Bool) {
        self.eventID = eventID
        self.checkedIn = checkedIn
        self.alreadyCheckedIn = alreadyCheckedIn
    }
}

/// An `.ics` file written to disk for the system share sheet. Opening it with Calendar adds the
/// event; no calendar permission or entitlement is involved because the app never reads or writes
/// the donor's calendar itself.
public struct CalendarFile: Sendable, Equatable, Identifiable {
    public let eventID: String
    public let url: URL
    public var id: String { eventID }
}

public enum CalendarExport {
    /// Writes the `.ics` bytes to `<temp>/dad-calendar/<safe-slug>.ics`, replacing an earlier export.
    public static func write(_ data: Data, slug: String, directory: URL = FileManager.default.temporaryDirectory) throws -> URL {
        guard data.starts(with: Array("BEGIN:VCALENDAR".utf8)) else { throw AccountError.invalidResponse }
        let safe = String(slug.map { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-") ? $0 : "-" }.prefix(60))
        let folder = directory.appendingPathComponent("dad-calendar", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let url = folder.appendingPathComponent("\(safe.isEmpty ? "event" : safe).ics")
        try data.write(to: url, options: [.atomic, .completeFileProtection])
        return url
    }
}

/// Drives the events list and detail. One load fetches the list; reserving/cancelling updates
/// the affected event in place so the list and detail re-render without a full reload. A failed
/// command never changes the event on screen (cancellation keeps the prior state), and a command
/// for an event already in flight is ignored so a double tap cannot book twice.
@MainActor
@Observable
public final class EventsModel {
    public enum Phase: Sendable, Equatable {
        case loading
        case ready
        case failed(String)
    }

    public private(set) var phase: Phase = .loading
    public private(set) var events: [DonorEvent] = []
    /// The last reserve outcome, so the detail screen can present the confirmation (E-4).
    public private(set) var lastOutcome: ReservationOutcome?
    /// A transient action error (403/409/etc.) shown inline without losing the list.
    public private(set) var actionError: String?
    /// The event the `actionError` belongs to, so only that card shows it.
    public private(set) var actionErrorEventID: String?
    /// Events with a command in flight.
    public private(set) var busy: Set<String> = []
    /// Set when a call proved the session is gone; the host routes back to sign-in.
    public private(set) var signedOut = false
    /// The prepared `.ics`, ready for the share sheet.
    public private(set) var calendarFile: CalendarFile?
    public private(set) var calendarPreparing: String?
    /// Why a refresh failed while earlier rows stay on screen.
    public private(set) var refreshNotice: String?

    private let service: any EventsService
    private let exportDirectory: URL

    public init(service: any EventsService, exportDirectory: URL = FileManager.default.temporaryDirectory) {
        self.service = service
        self.exportDirectory = exportDirectory
    }

    public func load() async {
        let prior = phase
        if events.isEmpty { phase = .loading }
        refreshNotice = nil
        do {
            events = try await service.events()
            phase = .ready
        } catch where error.isCancellation {
            phase = prior
        } catch {
            noteSignedOut(error)
            let message = error.eventMessage(for: .load)
            if events.isEmpty { phase = .failed(message) } else { phase = .ready; refreshNotice = message }
        }
    }

    /// Events already sorted soonest-first (E-2). The service returns server order; sorting here
    /// keeps the list stable even if a reserve re-fetch reorders.
    public var sortedEvents: [DonorEvent] { events.sorted { $0.startsAt < $1.startsAt } }

    public func event(id: String) -> DonorEvent? { events.first { $0.id == id } }
    public func isBusy(_ eventID: String) -> Bool { busy.contains(eventID) }

    public func reserve(eventID: String) async {
        guard busy.insert(eventID).inserted else { return }
        defer { busy.remove(eventID) }
        clearError()
        do {
            let outcome = try await service.reserve(eventID: eventID)
            lastOutcome = outcome
            await refresh(eventID: eventID, assuming: outcome == .waitlisted ? .waitlisted : .reserved)
        } catch where error.isCancellation {
            return
        } catch {
            await fail(error, action: .reserve, eventID: eventID)
        }
    }

    public func cancel(eventID: String) async {
        guard busy.insert(eventID).inserted else { return }
        defer { busy.remove(eventID) }
        clearError()
        do {
            try await service.cancel(eventID: eventID)
            lastOutcome = nil
            await refresh(eventID: eventID, assuming: ReservationStatus.none)
        } catch where error.isCancellation {
            return
        } catch {
            await fail(error, action: .cancel, eventID: eventID)
        }
    }

    /// Fetches the event's `.ics` and writes it where the share sheet can offer it (E-6).
    public func prepareCalendar(eventID: String) async {
        guard calendarPreparing == nil, let event = event(id: eventID) else { return }
        calendarPreparing = eventID
        defer { calendarPreparing = nil }
        clearError()
        do {
            let data = try await service.calendar(eventID: eventID)
            calendarFile = CalendarFile(eventID: eventID, url: try CalendarExport.write(data, slug: event.slug, directory: exportDirectory))
        } catch where error.isCancellation {
            return
        } catch {
            await fail(error, action: .calendar, eventID: eventID)
        }
    }

    /// Re-read one event (after a check-in) so `checkedInAt` shows; a failed read keeps what is on screen.
    public func reloadEvent(eventID: String) async {
        do {
            let updated = try await service.event(id: eventID)
            guard let index = events.firstIndex(where: { $0.id == eventID }) else { return }
            events[index] = updated
        } catch AccountError.notFound {
            events.removeAll { $0.id == eventID }
        } catch {
            noteSignedOut(error)
        }
    }

    public func clearCalendar() {
        if let file = calendarFile { try? FileManager.default.removeItem(at: file.url) }
        calendarFile = nil
    }

    /// Re-fetch one event after a mutation and splice it back into the list in place.
    private func refresh(eventID: String, assuming status: ReservationStatus) async {
        do {
            let updated = try await service.event(id: eventID)
            guard let index = events.firstIndex(where: { $0.id == eventID }) else { return }
            events[index] = updated
        } catch AccountError.notFound {
            events.removeAll { $0.id == eventID }
        } catch where error.isCancellation {
            return
        } catch {
            noteSignedOut(error)
            // The command succeeded; keep its confirmed status if the follow-up read is unavailable.
            guard !signedOut, let index = events.firstIndex(where: { $0.id == eventID }) else { return }
            events[index] = events[index].with(status: status)
        }
    }

    /// A 404/409 means what is on screen is stale; refresh the list quietly so the next tap is informed.
    private func fail(_ error: Error, action: EventAction, eventID: String) async {
        noteSignedOut(error)
        actionError = error.eventMessage(for: action)
        actionErrorEventID = eventID
        switch error as? AccountError {
        case .conflict?, .notFound?:
            // Another command's own refresh would be overwritten by this older list.
            guard busy.subtracting([eventID]).isEmpty else { return }
            do { events = try await service.events() } catch { noteSignedOut(error) }
        default: break
        }
    }

    private func clearError() { actionError = nil; actionErrorEventID = nil }
    private func noteSignedOut(_ error: Error) { if error as? AccountError == .signedOut { signedOut = true } }

    public func clearOutcome() { lastOutcome = nil }
}

extension DonorEvent {
    /// The same event with a different reservation status (the server's own count is fetched on refresh).
    func with(status: ReservationStatus) -> DonorEvent {
        var copy = self
        copy.status = status
        return copy
    }
}

/// Drives the QR check-in flow. The camera scanner (a device seam, validated structurally) feeds
/// a scanned code in; this model applies the client-side window pre-check, calls the service, and
/// exposes a result the inline success/failure view renders. Server remains authoritative.
@MainActor
@Observable
public final class CheckInModel {
    public enum State: Sendable, Equatable {
        case idle
        case checking
        case success(alreadyCheckedIn: Bool)
        case outsideWindow(reason: String)
        case failed(String)
    }

    public private(set) var state: State = .idle
    public private(set) var signedOut = false

    private let service: any EventsService

    public init(service: any EventsService) { self.service = service }

    /// Apply the client-side window gate, then (if open) check in. `window` and `now` are injected
    /// so the "too early / too late" branch is deterministic in tests; the server still validates.
    public func submit(code rawCode: String, window: CheckInWindow, now: Date, eventID: String? = nil) async {
        if state == .checking { return }   // double-tap / double-scan guard
        let code = rawCode.trimmingCharacters(in: .whitespacesAndNewlines)
        switch window.state(now: now) {
        case .tooEarly(let opensAt):
            state = .outsideWindow(reason: "Check-in opens \(EventTime.moment(opensAt, timeZone: window.timeZone)).")
            return
        case .tooLate:
            state = .outsideWindow(reason: "Check-in for this event has closed.")
            return
        case .open:
            break
        }
        guard !code.isEmpty else {
            state = .failed("Enter the code shown at the venue.")
            return
        }
        guard CheckInToken.isWellFormed(code) else {
            state = .failed("That doesn’t look like a full check-in code. Scan the QR code again, or paste the whole code exactly as shown (\(CheckInToken.length) characters).")
            return
        }
        let prior = state
        state = .checking
        do {
            let result = try await service.checkIn(code: code)
            if let eventID, result.eventID.caseInsensitiveCompare(eventID) != .orderedSame {
                state = .failed("That code belongs to a different event. Open that event to check your attendance.")
                return
            }
            guard result.checkedIn || result.alreadyCheckedIn else { throw AccountError.invalidResponse }
            state = .success(alreadyCheckedIn: result.alreadyCheckedIn)
        } catch where error.isCancellation {
            state = prior
        } catch {
            if error as? AccountError == .signedOut { signedOut = true }
            state = .failed(error.eventMessage(for: .checkIn))
        }
    }

    public func reset() { state = .idle }
}
