import Foundation
import XCTest
@testable import DADFoundation

// Deterministic clock helpers.
private func date(_ iso: String) -> Date {
    let f = ISO8601DateFormatter()
    return f.date(from: iso)!
}

private func makeEvent(
    id: String = "e1",
    spotsLeft: Int = 5,
    capacity: Int = 50,
    status: ReservationStatus = .none,
    invitationNote: String? = nil,
    cancelled: Bool = false,
    bookingOpensAt: Date? = nil,
    earlyBooking: Bool = false,
    startsAt: Date = date("2026-12-01T18:00:00Z"),
    endsAt: Date = date("2026-12-01T20:00:00Z")
) -> DonorEvent {
    DonorEvent(
        id: id, slug: "slug-\(id)", title: "Event \(id)", type: "volunteer", venue: "Hall", city: "Austin",
        startsAt: startsAt, endsAt: endsAt, capacity: capacity, spotsLeft: spotsLeft, status: status,
        invitationNote: invitationNote, reportIssueURL: "mailto:help@dad.org", cancelled: cancelled,
        bookingOpensAt: bookingOpensAt, earlyBooking: earlyBooking
    )
}

// MARK: - Availability (E-2, E-3, E-4, E-9)

final class EventAvailabilityTests: XCTestCase {
    private let now = date("2026-11-15T12:00:00Z")

    func testReservableWhenSpotsRemain() {
        XCTAssertEqual(makeEvent(spotsLeft: 3).availability(now: now), .reservable(spotsLeft: 3))
    }

    func testWaitlistableWhenFull() {
        XCTAssertEqual(makeEvent(spotsLeft: 0).availability(now: now), .waitlistable)
    }

    func testReservedAndWaitlistedAndCheckedInFromStatus() {
        XCTAssertEqual(makeEvent(status: .reserved).availability(now: now), .reserved)
        XCTAssertEqual(makeEvent(status: .waitlisted).availability(now: now), .waitlisted)
        XCTAssertEqual(makeEvent(status: .checkedIn).availability(now: now), .checkedIn)
    }

    func testCancelledWinsOverEverything() {
        XCTAssertEqual(makeEvent(spotsLeft: 10, status: .reserved, cancelled: true).availability(now: now), .cancelled)
    }

    func testNotYetOpenBeforeBookingWindow() {
        let opens = date("2026-11-20T09:00:00Z")
        XCTAssertEqual(makeEvent(bookingOpensAt: opens).availability(now: now), .notYetOpen(opensAt: opens))
        // Once the window opens, it becomes reservable.
        XCTAssertEqual(makeEvent(bookingOpensAt: opens).availability(now: date("2026-11-20T10:00:00Z")), .reservable(spotsLeft: 5))
    }

    func testEarlyBookingDonorMayReserveBeforeItOpensToEveryone() {
        // `early_booking` is true while THIS donor (a Team Captain) may book before the public opening (B-3).
        let opens = date("2026-11-20T09:00:00Z")
        XCTAssertEqual(makeEvent(bookingOpensAt: opens, earlyBooking: true).availability(now: now), .reservable(spotsLeft: 5))
    }

    func testStartedEventOffersNoNewReservation() {
        let event = makeEvent(startsAt: date("2026-11-15T11:00:00Z"), endsAt: date("2026-11-15T14:00:00Z"))
        XCTAssertEqual(event.availability(now: now), .started)
        // ...but a donor who already holds a seat still sees it.
        XCTAssertEqual(makeEvent(status: .reserved, startsAt: date("2026-11-15T11:00:00Z"), endsAt: date("2026-11-15T14:00:00Z")).availability(now: now), .reserved)
    }

    func testUncappedEventIsAlwaysReservable() {
        let open = makeEvent(spotsLeft: 0, capacity: 0)
        XCTAssertTrue(open.isUncapped)
        XCTAssertEqual(open.availability(now: now), .reservable(spotsLeft: Int.max))
        XCTAssertEqual(open.spotsLabel, "Open to everyone")
    }

    func testCancelUntilStartOnly() {
        let held = makeEvent(status: .reserved)   // starts 2026-12-01T18:00Z
        XCTAssertTrue(held.canCancel(now: now))
        XCTAssertTrue(makeEvent(status: .waitlisted).canCancel(now: now))
        XCTAssertFalse(held.canCancel(now: date("2026-12-01T18:00:00Z")))
        XCTAssertFalse(makeEvent(status: .none).canCancel(now: now))
        XCTAssertFalse(makeEvent(status: .reserved, cancelled: true).canCancel(now: now))
    }

    func testOnlyAHeldSeatCanAttemptCheckIn() {
        XCTAssertTrue(makeEvent(status: .reserved).canAttemptCheckIn)
        XCTAssertFalse(makeEvent(status: .waitlisted).canAttemptCheckIn)
        XCTAssertFalse(makeEvent(status: .none).canAttemptCheckIn)
    }

    func testSpotsLabel() {
        XCTAssertEqual(makeEvent(spotsLeft: 3).spotsLabel, "3 spots left")
        XCTAssertEqual(makeEvent(spotsLeft: 1).spotsLabel, "1 spot left")
        XCTAssertEqual(makeEvent(spotsLeft: 0).spotsLabel, "Full")
        XCTAssertEqual(makeEvent(cancelled: true).spotsLabel, "Cancelled")
    }
}

// MARK: - Invite-only gating (E-5)

final class InviteOnlyGatingTests: XCTestCase {
    func testInviteOnlyDetectedByInvitationNote() {
        XCTAssertTrue(makeEvent(invitationNote: "Founding donors only").isInviteOnly)
        XCTAssertFalse(makeEvent(invitationNote: nil).isInviteOnly)
    }

    func testInviteOnlyTypeAloneMarksTheEvent() {
        let event = DonorEvent(id: "x", slug: "x", title: "x", type: "invite_only", venue: "", city: "", startsAt: Date(), endsAt: Date(),
                               capacity: 1, spotsLeft: 1, status: .none)
        XCTAssertTrue(event.isInviteOnly)
        XCTAssertEqual(event.typeLabel, "Invite-only")
    }

    func testReservationStatusDecodesUnknownToNone() {
        XCTAssertEqual(ReservationStatus(contract: "reserved"), .reserved)
        XCTAssertEqual(ReservationStatus(contract: "checked_in"), .checkedIn)
        XCTAssertEqual(ReservationStatus(contract: "some_future_value"), .none)
    }
}

// MARK: - Check-in window (E-8), rejected outside window

final class CheckInWindowTests: XCTestCase {
    private let starts = date("2026-12-01T18:00:00Z")
    private let ends = date("2026-12-01T20:00:00Z")

    func testWindowOpensAtStartLikeTheContract() {
        // Contract: check-in is accepted only between the event's start and end (no early grace).
        let window = CheckInWindow(startsAt: starts, endsAt: ends)
        XCTAssertEqual(window.opensAt, starts)
    }

    func testTooEarlyBeforeWindow() {
        let window = CheckInWindow(startsAt: starts, endsAt: ends)
        if case .tooEarly(let opensAt) = window.state(now: date("2026-12-01T17:30:00Z")) {
            XCTAssertEqual(opensAt, starts)
        } else {
            XCTFail("expected tooEarly")
        }
        XCTAssertFalse(window.isOpen(now: date("2026-12-01T17:30:00Z")))
        XCTAssertFalse(window.isOpen(now: date("2026-12-01T17:59:59Z")))
    }

    func testOpenInsideWindow() {
        let window = CheckInWindow(startsAt: starts, endsAt: ends)
        XCTAssertTrue(window.isOpen(now: date("2026-12-01T18:30:00Z")))
        XCTAssertTrue(window.isOpen(now: starts))   // inclusive at both ends
        XCTAssertTrue(window.isOpen(now: ends))
    }

    func testTooLateAfterEnd() {
        let window = CheckInWindow(startsAt: starts, endsAt: ends)
        XCTAssertEqual(window.state(now: date("2026-12-01T20:30:00Z")), .tooLate)
        XCTAssertFalse(window.isOpen(now: date("2026-12-01T20:30:00Z")))
    }
}

// MARK: - Reservation outcome (E-4)

final class ReservationOutcomeTests: XCTestCase {
    func testOutcomeFromContractStatus() {
        XCTAssertEqual(ReservationOutcome(contract: "reserved"), .reserved)
        XCTAssertEqual(ReservationOutcome(contract: "waitlisted"), .waitlisted)
        XCTAssertEqual(ReservationOutcome(contract: "confirmed"), .reserved) // anything not waitlisted = reserved
    }

    func testConfirmationCopyDiffersByOutcome() {
        XCTAssertEqual(ReservationOutcome.reserved.confirmationTitle, "You’re going")
        XCTAssertEqual(ReservationOutcome.waitlisted.confirmationTitle, "You’re on the waitlist")
        XCTAssertNotEqual(ReservationOutcome.reserved.confirmationDetail, ReservationOutcome.waitlisted.confirmationDetail)
    }
}

// MARK: - EventsModel + CheckInModel state machines

/// A controllable test double for EventsService.
private actor FakeEventsService: EventsService {
    var list: [DonorEvent]
    var reserveOutcome: ReservationOutcome
    var checkInResult: CheckInResultValue
    var throwOnReserve: Error?
    var throwOnCheckIn: Error?
    var throwOnList: Error?
    private(set) var checkInCalls = 0
    /// What `event(id:)` returns after a mutation — lets a test model the waitlist→reserved promotion.
    var refreshed: [String: DonorEvent] = [:]

    init(
        list: [DonorEvent],
        reserveOutcome: ReservationOutcome = .reserved,
        checkInResult: CheckInResultValue = CheckInResultValue(eventID: "e1", checkedIn: true, alreadyCheckedIn: false)
    ) {
        self.list = list
        self.reserveOutcome = reserveOutcome
        self.checkInResult = checkInResult
    }

    func setRefreshed(_ event: DonorEvent) { refreshed[event.id] = event }
    func setThrowOnReserve(_ error: Error?) { throwOnReserve = error }
    func setThrowOnCheckIn(_ error: Error?) { throwOnCheckIn = error }
    func setThrowOnList(_ error: Error?) { throwOnList = error }

    func events() async throws -> [DonorEvent] {
        if let error = throwOnList { throw error }
        return list
    }
    func event(id: String) async throws -> DonorEvent { refreshed[id] ?? list.first { $0.id == id }! }
    func reserve(eventID: String) async throws -> ReservationOutcome {
        if let error = throwOnReserve { throw error }
        return reserveOutcome
    }
    func cancel(eventID: String) async throws {}
    func calendar(eventID: String) async throws -> Data { Data("BEGIN:VCALENDAR\r\nEND:VCALENDAR\r\n".utf8) }
    func checkIn(code: String) async throws -> CheckInResultValue {
        checkInCalls += 1
        if let error = throwOnCheckIn { throw error }
        return checkInResult
    }
}

@MainActor
final class EventsModelTests: XCTestCase {
    func testLoadSortsSoonestFirst() async {
        let later = makeEvent(id: "later", startsAt: date("2026-12-10T18:00:00Z"))
        let sooner = makeEvent(id: "sooner", startsAt: date("2026-12-02T18:00:00Z"))
        let model = EventsModel(service: FakeEventsService(list: [later, sooner]))
        await model.load()
        XCTAssertEqual(model.phase, .ready)
        XCTAssertEqual(model.sortedEvents.map(\.id), ["sooner", "later"])
    }

    func testReserveRecordsOutcomeAndRefreshesEventInPlace() async {
        // Waitlist outcome, and the refreshed event reflects the new status.
        let event = makeEvent(id: "e1", spotsLeft: 0, status: .none)
        let service = FakeEventsService(list: [event], reserveOutcome: .waitlisted)
        await service.setRefreshed(makeEvent(id: "e1", spotsLeft: 0, status: .waitlisted))
        let model = EventsModel(service: service)
        await model.load()
        await model.reserve(eventID: "e1")
        XCTAssertEqual(model.lastOutcome, .waitlisted)
        XCTAssertEqual(model.events.first?.status, .waitlisted)
    }

    func testWaitlistPromotionReflectedOnRefresh() async {
        // E-4: a waitlisted reservation later promotes to reserved; a refresh picks it up.
        let event = makeEvent(id: "e1", spotsLeft: 0, status: .waitlisted)
        let service = FakeEventsService(list: [event])
        await service.setRefreshed(makeEvent(id: "e1", spotsLeft: 1, status: .reserved))
        let model = EventsModel(service: service)
        await model.load()
        await model.cancel(eventID: "e1") // any mutation triggers refresh
        XCTAssertEqual(model.events.first?.status, .reserved)
    }

    func testCancelledLoadKeepsPriorEventsAndPhase() async {
        let service = FakeEventsService(list: [makeEvent(id: "e1")])
        let model = EventsModel(service: service)
        await model.load()
        await service.setThrowOnList(CancellationError())
        await model.load()
        XCTAssertEqual(model.phase, .ready)
        XCTAssertEqual(model.events.count, 1)
    }

    func testCancelledReserveIsNotAnActionError() async {
        let service = FakeEventsService(list: [makeEvent(id: "e1")])
        await service.setThrowOnReserve(URLError(.cancelled))
        let model = EventsModel(service: service)
        await model.load()
        await model.reserve(eventID: "e1")
        XCTAssertNil(model.actionError)
    }

    func testReserveErrorSurfacesInlineWithoutLosingList() async {
        let service = FakeEventsService(list: [makeEvent(id: "e1")])
        await service.setThrowOnReserve(AccountError.unavailable)
        let model = EventsModel(service: service)
        await model.load()
        await model.reserve(eventID: "e1")
        XCTAssertNotNil(model.actionError)
        XCTAssertEqual(model.events.count, 1) // list preserved
        XCTAssertEqual(model.phase, .ready)
    }
}

@MainActor
final class CheckInModelTests: XCTestCase {
    private let window = CheckInWindow(startsAt: date("2026-12-01T18:00:00Z"), endsAt: date("2026-12-01T20:00:00Z"))

    func testRejectsBeforeWindowWithoutCallingService() async {
        let service = FakeEventsService(list: [])
        let model = CheckInModel(service: service)
        await model.submit(code: validCheckInToken, window: window, now: date("2026-12-01T16:00:00Z"))
        guard case .outsideWindow(let reason) = model.state else { return XCTFail("expected outsideWindow (too early)") }
        XCTAssertTrue(reason.hasPrefix("Check-in opens "))
        let calls = await service.checkInCalls
        XCTAssertEqual(calls, 0)
    }

    func testRejectsAfterWindow() async {
        let service = FakeEventsService(list: [])
        let model = CheckInModel(service: service)
        await model.submit(code: validCheckInToken, window: window, now: date("2026-12-01T21:00:00Z"))
        XCTAssertEqual(model.state, .outsideWindow(reason: "Check-in for this event has closed."))
        let calls = await service.checkInCalls
        XCTAssertEqual(calls, 0)
    }

    func testChecksInInsideWindow() async {
        let service = FakeEventsService(list: [], checkInResult: CheckInResultValue(eventID: "e1", checkedIn: true, alreadyCheckedIn: false))
        let model = CheckInModel(service: service)
        await model.submit(code: validCheckInToken, window: window, now: date("2026-12-01T18:30:00Z"))
        XCTAssertEqual(model.state, .success(alreadyCheckedIn: false))
    }

    func testAlreadyCheckedInSurfaced() async {
        let service = FakeEventsService(list: [], checkInResult: CheckInResultValue(eventID: "e1", checkedIn: false, alreadyCheckedIn: true))
        let model = CheckInModel(service: service)
        await model.submit(code: validCheckInToken, window: window, now: date("2026-12-01T18:30:00Z"))
        XCTAssertEqual(model.state, .success(alreadyCheckedIn: true))
    }

    func testServiceErrorInsideWindowFails() async {
        let service = FakeEventsService(list: [])
        await service.setThrowOnCheckIn(AccountError.invalidResponse)
        let model = CheckInModel(service: service)
        await model.submit(code: validCheckInToken, window: window, now: date("2026-12-01T18:30:00Z"))
        if case .failed = model.state {} else { XCTFail("expected failed") }
    }
}
