import Foundation
import XCTest
@testable import DADFoundation

private func at(_ iso: String) -> Date { ISO8601DateFormatter().date(from: iso)! }

private func event(_ id: String = "e1", status: ReservationStatus = .none, spots: Int = 5, slug: String = "park-cleanup") -> DonorEvent {
    DonorEvent(id: id, slug: slug, title: "Park Cleanup", type: "volunteer", venue: "Zilker", city: "Austin",
               startsAt: at("2026-12-01T18:00:00Z"), endsAt: at("2026-12-01T20:00:00Z"), capacity: 20, spotsLeft: spots, status: status)
}

/// A scriptable service whose reserve can be parked, to prove a second tap is ignored while one is in flight.
private actor ScriptedEvents: EventsService {
    var list: [DonorEvent]
    var reserveError: Error?
    var cancelError: Error?
    var detailError: Error?
    var listError: Error?
    var calendarResult: Result<Data, Error> = .success(Data("BEGIN:VCALENDAR\r\nEND:VCALENDAR\r\n".utf8))
    private(set) var reserveCalls = 0
    private(set) var listCalls = 0
    private let gate: Gate?
    private let detailGate: Gate?

    init(list: [DonorEvent], gate: Gate? = nil, detailGate: Gate? = nil) {
        self.list = list; self.gate = gate; self.detailGate = detailGate
    }
    func setReserveError(_ error: Error?) { reserveError = error }
    func setCancelError(_ error: Error?) { cancelError = error }
    func setDetailError(_ error: Error?) { detailError = error }
    func setListError(_ error: Error?) { listError = error }
    func setList(_ events: [DonorEvent]) { list = events }
    func setCalendar(_ result: Result<Data, Error>) { calendarResult = result }

    func events() async throws -> [DonorEvent] {
        listCalls += 1
        if let listError { throw listError }
        return list
    }
    func event(id: String) async throws -> DonorEvent {
        if let detailError { throw detailError }
        let result = list.first { $0.id == id }!
        await detailGate?.pass()
        return result
    }
    func reserve(eventID: String) async throws -> ReservationOutcome {
        reserveCalls += 1
        await gate?.pass()
        if let reserveError { throw reserveError }
        return .reserved
    }
    func cancel(eventID: String) async throws { if let cancelError { throw cancelError } }
    func checkIn(code: String) async throws -> CheckInResultValue { CheckInResultValue(eventID: "e1", checkedIn: true, alreadyCheckedIn: false) }
    func calendar(eventID: String) async throws -> Data { try calendarResult.get() }
}

@MainActor
final class EventsModelBehaviourTests: XCTestCase {
    func testDetailRefreshUsesTheCurrentListAfterSuspension() async {
        for mutation in [false, true] {
            let gate = Gate()
            let service = ScriptedEvents(list: [event()], detailGate: gate)
            let model = EventsModel(service: service)
            await model.load()
            let request = Task {
                if mutation { await model.reserve(eventID: "e1") }
                else { await model.reloadEvent(eventID: "e1") }
            }
            await gate.waitUntilEntered()
            await service.setList([event("e2")])
            await model.load()
            await gate.release()
            await request.value
            XCTAssertEqual(model.events.map(\.id), ["e2"], "the old index must not replace a different event")
        }
    }

    func testRefreshHonorsSessionRevocationAndRemovedEvents() async {
        let service = ScriptedEvents(list: [event()])
        let model = EventsModel(service: service)
        await model.load()
        await service.setDetailError(AccountError.signedOut)
        await model.reserve(eventID: "e1")
        XCTAssertTrue(model.signedOut)

        let removed = EventsModel(service: service)
        await removed.load()
        await service.setDetailError(AccountError.notFound)
        await removed.reloadEvent(eventID: "e1")
        XCTAssertTrue(removed.events.isEmpty)
    }

    func testASecondReserveWhileOneIsInFlightIsIgnored() async {
        let gate = Gate()
        let service = ScriptedEvents(list: [event()], gate: gate)
        let model = EventsModel(service: service)
        await model.load()
        let first = Task { await model.reserve(eventID: "e1") }
        await gate.waitUntilEntered()
        XCTAssertTrue(model.isBusy("e1"))
        await model.reserve(eventID: "e1")   // the double tap
        await gate.release()
        await first.value
        let calls = await service.reserveCalls
        XCTAssertEqual(calls, 1)
        XCTAssertFalse(model.isBusy("e1"))
    }

    func testForbiddenReserveSaysNotEligibleAndKeepsTheEvent() async {
        let service = ScriptedEvents(list: [event()])
        await service.setReserveError(AccountError.forbidden)
        let model = EventsModel(service: service)
        await model.load()
        await model.reserve(eventID: "e1")
        XCTAssertEqual(model.actionError, "You’re not eligible to reserve this event.")
        XCTAssertEqual(model.actionErrorEventID, "e1")
        XCTAssertEqual(model.event(id: "e1")?.status, ReservationStatus.none)
        XCTAssertNil(model.lastOutcome)
    }

    func testConflictOnReserveRefreshesTheListSoTheDonorSeesTheFullEvent() async {
        let service = ScriptedEvents(list: [event(spots: 1)])
        await service.setReserveError(AccountError.conflict)
        let model = EventsModel(service: service)
        await model.load()
        await service.setList([event(spots: 0)])
        await model.reserve(eventID: "e1")
        XCTAssertEqual(model.actionError, "This event just filled up or isn’t open for booking. We’ve refreshed it.")
        XCTAssertEqual(model.event(id: "e1")?.spotsLeft, 0, "the refreshed list now shows it full")
        XCTAssertEqual(model.event(id: "e1")?.availability(now: at("2026-11-01T00:00:00Z")), .waitlistable)
    }

    func testRateLimitedReserveSurfacesTheWaitMessage() async {
        let service = ScriptedEvents(list: [event()])
        await service.setReserveError(AccountError.rateLimited)
        let model = EventsModel(service: service)
        await model.load()
        await model.reserve(eventID: "e1")
        XCTAssertEqual(model.actionError, "Too many attempts. Please wait a moment and try again.")
    }

    func testFailedCancelKeepsTheReservationAndSaysSo() async {
        let service = ScriptedEvents(list: [event(status: .reserved)])
        await service.setCancelError(AccountError.unavailable)
        let model = EventsModel(service: service)
        await model.load()
        await model.cancel(eventID: "e1")
        XCTAssertEqual(model.event(id: "e1")?.status, .reserved, "cancellation keeps the prior state")
        XCTAssertNotNil(model.actionError)
    }

    func testCancelledCancelCommandIsSilentAndKeepsState() async {
        let service = ScriptedEvents(list: [event(status: .reserved)])
        await service.setCancelError(URLError(.cancelled))
        let model = EventsModel(service: service)
        await model.load()
        await model.cancel(eventID: "e1")
        XCTAssertNil(model.actionError)
        XCTAssertEqual(model.event(id: "e1")?.status, .reserved)
    }

    func testForbiddenCancelSaysItCannotBeCancelled() async {
        let service = ScriptedEvents(list: [event(status: .reserved)])
        await service.setCancelError(AccountError.forbidden)
        let model = EventsModel(service: service)
        await model.load()
        await model.cancel(eventID: "e1")
        XCTAssertEqual(model.actionError, "You can’t cancel this reservation.")
    }

    func testSuccessfulMutationWithFailedRefetchStillShowsTheConfirmedStatus() async {
        let service = ScriptedEvents(list: [event()])
        await service.setDetailError(AccountError.unavailable)
        let model = EventsModel(service: service)
        await model.load()
        await model.reserve(eventID: "e1")
        XCTAssertEqual(model.event(id: "e1")?.status, .reserved)
        XCTAssertNil(model.actionError, "the reservation worked; a failed re-read is not an error")
    }

    func testAFailedRefreshKeepsTheRowsAndShowsANotice() async {
        let service = ScriptedEvents(list: [event()])
        let model = EventsModel(service: service)
        await model.load()
        await service.setListError(AccountError.unavailable)
        await model.load()
        XCTAssertEqual(model.phase, .ready)
        XCTAssertEqual(model.events.map(\.id), ["e1"])
        XCTAssertNotNil(model.refreshNotice)
        await service.setListError(nil)
        await model.load()
        XCTAssertNil(model.refreshNotice)
    }

    func testAFailedFirstLoadStillShowsTheFailedState() async {
        let service = ScriptedEvents(list: [event()])
        await service.setListError(AccountError.unavailable)
        let model = EventsModel(service: service)
        await model.load()
        guard case .failed = model.phase else { return XCTFail("\(model.phase)") }
        XCTAssertNil(model.refreshNotice)
    }

    func testSignedOutIsReportedFromLoadAndCommands() async {
        let service = ScriptedEvents(list: [event()])
        await service.setReserveError(AccountError.signedOut)
        let model = EventsModel(service: service)
        await model.load()
        XCTAssertFalse(model.signedOut)
        await model.reserve(eventID: "e1")
        XCTAssertTrue(model.signedOut)
    }

    func testCalendarPreparationWritesAnICSAndFailureIsInline() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("dad-events-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let service = ScriptedEvents(list: [event(slug: "Park Cleanup/../x")])
        let model = EventsModel(service: service, exportDirectory: directory)
        await model.load()
        await model.prepareCalendar(eventID: "e1")
        let file = try XCTUnwrap(model.calendarFile, "calendar not prepared: \(model.actionError ?? "no error")")
        XCTAssertEqual(file.url.pathExtension, "ics")
        XCTAssertEqual(file.url.deletingLastPathComponent().lastPathComponent, "dad-calendar")
        XCTAssertFalse(file.url.lastPathComponent.contains("/"))
        XCTAssertTrue(try String(contentsOf: file.url, encoding: .utf8).hasPrefix("BEGIN:VCALENDAR"))
        model.clearCalendar()
        XCTAssertNil(model.calendarFile)
        XCTAssertFalse(FileManager.default.fileExists(atPath: file.url.path), "the exported file is removed once the share sheet is done")

        await service.setCalendar(.failure(AccountError.notFound))
        await model.prepareCalendar(eventID: "e1")
        XCTAssertNil(model.calendarFile)
        XCTAssertEqual(model.actionError, "This event isn’t available any more.")
    }

    func testANonICSBodyIsNotWritten() async {
        let service = ScriptedEvents(list: [event()])
        await service.setCalendar(.success(Data("<html>nope</html>".utf8)))
        let model = EventsModel(service: service, exportDirectory: FileManager.default.temporaryDirectory.appendingPathComponent("dad-bad-\(UUID().uuidString)"))
        await model.load()
        await model.prepareCalendar(eventID: "e1")
        XCTAssertNil(model.calendarFile)
        XCTAssertNotNil(model.actionError)
    }
}

final class EventMessageTests: XCTestCase {
    func testEveryStatusHasAnEventSpecificSentence() {
        XCTAssertEqual(AccountError.forbidden.eventMessage(for: .checkIn), "You’re not eligible to check in to this event.")
        XCTAssertEqual(AccountError.forbidden.eventMessage(for: .load), "Events aren’t available for this account.")
        XCTAssertEqual(AccountError.conflict.eventMessage(for: .cancel), "Your reservation changed. We’ve refreshed it; please review it.")
        XCTAssertTrue(AccountError.invalidInput.eventMessage(for: .checkIn).hasPrefix("That code didn’t work."))
        XCTAssertEqual(AccountError.rateLimited.eventMessage(for: .reserve), "Too many attempts. Please wait a moment and try again.")
        XCTAssertEqual(AccountError.signedOut.eventMessage(for: .reserve), "Please sign in again.")
        XCTAssertEqual(AccountError.unavailable.eventMessage(for: .reserve), "Something went wrong. Please try again.")
        XCTAssertFalse(AccountError.forbidden.eventMessage(for: .reserve).contains("Giving"))
    }
}

@MainActor
final class CheckInModelHardeningTests: XCTestCase {
    private let window = CheckInWindow(startsAt: at("2026-12-01T18:00:00Z"), endsAt: at("2026-12-01T20:00:00Z"))
    private let inside = at("2026-12-01T18:30:00Z")

    func testCodeForAnotherEventDoesNotConfirmTheSelectedEvent() async {
        let model = CheckInModel(service: ScriptedEvents(list: []))
        await model.submit(code: validCheckInToken, window: window, now: inside, eventID: "e2")
        XCTAssertEqual(model.state, .failed("That code belongs to a different event. Open that event to check your attendance."))
        await model.submit(code: validCheckInToken, window: window, now: inside, eventID: "E1")
        XCTAssertEqual(model.state, .success(alreadyCheckedIn: false))
    }

    func testEmptyAndControlCharacterCodesNeverReachTheService() async {
        for code in ["", "   "] {
            let model = CheckInModel(service: ScriptedEvents(list: []))
            await model.submit(code: code, window: window, now: inside)
            XCTAssertEqual(model.state, .failed("Enter the code shown at the venue."), code)
        }
        for code in ["a\u{0}b", "tok", String(validCheckInToken.dropLast()), validCheckInToken + "x", "QR123"] {
            let service = ScriptedEvents(list: [])
            let model = CheckInModel(service: service)
            await model.submit(code: code, window: window, now: inside)
            guard case .failed(let message) = model.state else { return XCTFail("expected a shape failure for \(code)") }
            XCTAssertTrue(message.hasPrefix("That doesn’t look like a full check-in code."), code)
        }
    }

    func testServerRefusalsReadAsEventMessages() async {
        let service = ScriptedEvents(list: [])
        let cases: [(AccountError, String)] = [
            (.forbidden, "You’re not eligible to check in to this event."),
            (.rateLimited, "Too many attempts. Please wait a moment and try again."),
        ]
        for (error, message) in cases {
            let model = CheckInModel(service: FailingCheckIn(error: error))
            await model.submit(code: validCheckInToken, window: window, now: inside)
            XCTAssertEqual(model.state, .failed(message))
        }
        _ = service
    }

    func testSignedOutIsFlagged() async {
        let model = CheckInModel(service: FailingCheckIn(error: AccountError.signedOut))
        await model.submit(code: validCheckInToken, window: window, now: inside)
        XCTAssertTrue(model.signedOut)
    }

    func testCancelledCheckInRestoresThePriorState() async {
        let model = CheckInModel(service: FailingCheckIn(error: CancellationError()))
        await model.submit(code: validCheckInToken, window: window, now: inside)
        XCTAssertEqual(model.state, .idle)
    }
}

private struct FailingCheckIn: EventsService {
    let error: Error
    init(error: Error) { self.error = error }
    func events() async throws -> [DonorEvent] { [] }
    func event(id: String) async throws -> DonorEvent { throw error }
    func reserve(eventID: String) async throws -> ReservationOutcome { throw error }
    func cancel(eventID: String) async throws { throw error }
    func checkIn(code: String) async throws -> CheckInResultValue { throw error }
    func calendar(eventID: String) async throws -> Data { throw error }
}

final class EventTimeZoneTests: XCTestCase {
    private func event(zone: String) -> DonorEvent {
        DonorEvent(id: "e", slug: "e", title: "t", type: "volunteer", venue: "v", city: "c",
                   startsAt: at("2026-11-07T18:00:00Z"), endsAt: at("2026-11-07T20:00:00Z"), capacity: 1, spotsLeft: 1, status: .none,
                   timeZoneID: zone)
    }
    private let en = Locale(identifier: "en_US")

    /// Event in Los Angeles while the device (explicitly UTC here) is elsewhere: the venue's clock wins.
    func testTimesUseTheEventZoneNotTheDeviceZone() {
        let la = event(zone: "America/Los_Angeles")
        let text = EventTime.range(la, locale: en)
        XCTAssertTrue(text.contains("10:00"), text)   // 18:00Z is 10:00 PST
        XCTAssertTrue(text.contains("12:00"), text)
        XCTAssertTrue(text.contains("PST"), text)
        let device = EventTime.range(la, timeZone: TimeZone(identifier: "UTC")!, locale: en)
        XCTAssertTrue(device.contains("6:00"), device)
        XCTAssertNotEqual(text, device)
    }

    func testDaylightTimeShowsDaylightAbbreviation() {
        let summer = DonorEvent(id: "e", slug: "e", title: "t", type: "volunteer", venue: "v", city: "c",
                                startsAt: at("2026-07-07T18:00:00Z"), endsAt: at("2026-07-07T20:00:00Z"), capacity: 1, spotsLeft: 1,
                                status: .none, timeZoneID: "America/Los_Angeles")
        let text = EventTime.start(summer, locale: en)
        XCTAssertTrue(text.contains("11:00") && text.contains("PDT"), text)
    }

    func testUnknownZoneFallsBackToTheDeviceZone() {
        XCTAssertNil(event(zone: "Mars/Olympus").timeZone)
        XCTAssertNil(event(zone: "").timeZone)
        let fallback = EventTime.start(event(zone: "Mars/Olympus"), locale: en)
        XCTAssertEqual(fallback, EventTime.start(event(zone: "Mars/Olympus"), timeZone: .current, locale: en))
    }

    func testCheckInOpensMessageUsesTheEventZone() async {
        let la = event(zone: "America/Los_Angeles")
        let model = await MainActor.run { CheckInModel(service: ScriptedEvents(list: [])) }
        await model.submit(code: validCheckInToken, window: la.checkInWindow, now: at("2026-11-07T10:00:00Z"))
        let state = await MainActor.run { model.state }
        guard case .outsideWindow(let reason) = state else { return XCTFail("expected outsideWindow") }
        XCTAssertTrue(reason.contains("PST"), reason)
    }
}

final class CheckInTokenTests: XCTestCase {
    func testShape() {
        XCTAssertTrue(CheckInToken.isWellFormed(validCheckInToken))
        XCTAssertEqual(validCheckInToken.count, 66)
        for bad in ["", "STUBCHECKIN", String(validCheckInToken.dropLast()), validCheckInToken + "a",
                    validCheckInToken.replacingOccurrences(of: ".", with: "_"),                       // no separator
                    "abcdefghijklmnopqrstu.ABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-_abcdef",            // 21 + 44
                    String(validCheckInToken.dropLast()) + "+", String(validCheckInToken.dropLast()) + " ",
                    String(validCheckInToken.dropLast()) + "é"] {
            XCTAssertFalse(CheckInToken.isWellFormed(bad), bad)
        }
    }
}

@MainActor
final class CheckedInReloadTests: XCTestCase {
    func testCheckedInAtShowsAfterReload() async {
        let service = ScriptedEvents(list: [event("e1", status: .reserved)])
        let model = EventsModel(service: service)
        await model.load()
        XCTAssertNil(model.event(id: "e1")?.checkedInAt)
        let stamp = at("2026-12-01T18:30:00Z")
        await service.setList([DonorEvent(id: "e1", slug: "park-cleanup", title: "Park Cleanup", type: "volunteer", venue: "Zilker", city: "Austin",
                                          startsAt: at("2026-12-01T18:00:00Z"), endsAt: at("2026-12-01T20:00:00Z"), capacity: 20, spotsLeft: 5,
                                          status: .checkedIn, timeZoneID: "America/Chicago", checkedInAt: stamp)])
        await model.reloadEvent(eventID: "e1")
        XCTAssertEqual(model.event(id: "e1")?.status, .checkedIn)
        XCTAssertEqual(model.event(id: "e1")?.checkedInAt, stamp)
        await model.load()   // a relaunch re-reads the list: the state comes from the server, not the session
        XCTAssertEqual(model.event(id: "e1")?.checkedInAt, stamp)
    }
}

final class EventTimeTests: XCTestCase {
    private let sample = DonorEvent(id: "e", slug: "e", title: "t", type: "volunteer", venue: "v", city: "c",
                                    startsAt: at("2026-11-07T16:00:00Z"), endsAt: at("2026-11-07T18:00:00Z"), capacity: 1, spotsLeft: 1, status: .none)
    private let central = TimeZone(identifier: "America/Chicago")!

    func testRangeUsesTheGivenZoneAndLocaleWithAZoneAbbreviation() {
        let us = EventTime.range(sample, timeZone: central, locale: Locale(identifier: "en_US"))
        XCTAssertTrue(us.contains("10:00"), us)
        XCTAssertTrue(us.contains("CST"), us)
        let tokyo = EventTime.range(sample, timeZone: TimeZone(identifier: "Asia/Tokyo")!, locale: Locale(identifier: "en_US"))
        XCTAssertTrue(tokyo.contains("1:00"), tokyo)   // 16:00Z is 01:00 the next day in Tokyo
        XCTAssertNotEqual(us, tokyo)
    }

    func testLocaleChangesTheClockStyle() {
        let us = EventTime.start(sample, timeZone: central, locale: Locale(identifier: "en_US"))
        let de = EventTime.start(sample, timeZone: central, locale: Locale(identifier: "de_DE"))
        XCTAssertNotEqual(us, de)
        XCTAssertTrue(us.contains("AM") || us.contains("PM"), us)
        XCTAssertFalse(de.contains("AM"), de)
    }

    func testAnEventSpanningMidnightShowsTheEndDate() {
        let overnight = DonorEvent(id: "e", slug: "e", title: "t", type: "community", venue: "v", city: "c",
                                   startsAt: at("2026-11-08T04:00:00Z"), endsAt: at("2026-11-08T08:00:00Z"), capacity: 1, spotsLeft: 1, status: .none)
        let same = EventTime.range(overnight, timeZone: TimeZone(identifier: "UTC")!, locale: Locale(identifier: "en_US"))
        XCTAssertEqual(same.components(separatedBy: "Nov 8").count, 2, "same-day end omits the date: \(same)")
        let crossing = EventTime.range(overnight, timeZone: central, locale: Locale(identifier: "en_US"))   // 10pm Nov 7 to 2am Nov 8
        XCTAssertTrue(crossing.contains("Nov 7") && crossing.contains("Nov 8"), crossing)
    }
}
