import Foundation
import HTTPTypes
import OpenAPIRuntime
import XCTest
@testable import DADFoundation

private let eventA = "11111111-0000-4000-8000-000000000001"
private let eventB = "11111111-0000-4000-8000-000000000002"
private let eventC = "11111111-0000-4000-8000-000000000003"

/// A well-formed check-in token: 22 + "." + 43 base64url characters.
let validCheckInToken = "abcdefghijklmnopqrstuv.ABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-_abcde"

func eventJSON(id: String = eventA, type: String = "VOLUNTEER", status: String = "null", note: String = "null", capacity: Int = 20,
               spots: String = "8", start: String = "2026-11-07T15:00:00Z", end: String = "2026-11-07T17:00:00Z",
               opens: String = "null", early: Bool = false, cancelled: Bool = false, report: String = #""mailto:help@dad.org""#,
               zone: String = "America/Chicago", checkedInAt: String = "null") -> String {
    #"{"id":"\#(id)","slug":"park-cleanup","title":"Park Cleanup","type":"\#(type)","description":"Bring water.","venue":"Zilker Park","address":"2100 Barton Springs Rd","city":"Austin","starts_at":"\#(start)","ends_at":"\#(end)","capacity":\#(capacity),"spots_left":\#(spots),"reservation_status":\#(status),"time_zone":"\#(zone)","checked_in_at":\#(checkedInAt),"invitation_note":\#(note),"report_issue_url":\#(report),"cancelled":\#(cancelled),"booking_opens_at":\#(opens),"early_booking":\#(early)}"#
}
private func listJSON(_ rows: String...) -> String { #"{"events":[\#(rows.joined(separator: ","))]}"# }
private let icsText = "BEGIN:VCALENDAR\r\nVERSION:2.0\r\nBEGIN:VEVENT\r\nSUMMARY:Park Cleanup\r\nEND:VEVENT\r\nEND:VCALENDAR\r\n"
private let reservedJSON = #"{"status":"RESERVED"}"#
private let cancelledJSON = #"{"status":"CANCELLED"}"#

final class WireEventsTests: XCTestCase {
    private typealias Rig = (service: WireEvents, session: AccountSession, store: MemoryStore)

    private func make(_ transport: ScriptedTransport) throws -> Rig {
        let store = MemoryStore(Credentials(access: "tok", refresh: "ref", expiresAt: .distantFuture))
        let session = try AccountSession(api: WireAPI(origin: testOrigin, transport: transport), store: store)
        return (WireEvents(product: ProductClient(origin: testOrigin, transport: transport, session: session)), session, store)
    }

    /// Runs one status table against an operation: each (status, body) must map to the error and keep the session.
    private func assertMapping(_ cases: [(HTTPResponse.Status, String, AccountError)],
                               _ run: @escaping (WireEvents) async throws -> Void) async throws {
        for (status, body, expected) in cases {
            let rig = try make(ScriptedTransport { _, _ in (status, body) })
            do { try await run(rig.service); XCTFail("\(status)") }
            catch { XCTAssertEqual(error as? AccountError, expected, "\(status)") }
            XCTAssertNotNil(try rig.store.load(), "\(status) must not end the session")
        }
    }

    /// Cancels a call parked inside the transport and asserts it surfaces as cancellation, session intact.
    private func assertCancellation(_ okBody: String, _ run: @escaping @Sendable (WireEvents) async throws -> Void) async throws {
        let gate = Gate()
        let rig = try make(ScriptedTransport { _, _ in
            await gate.pass()
            try Task.checkCancellation()
            return (.ok, okBody)
        })
        let service = rig.service
        let task = Task { try await run(service) }
        await gate.waitUntilEntered()
        task.cancel()
        await gate.release()
        do { try await task.value; XCTFail() }
        catch { XCTAssertTrue(error.isCancellation, "\(error)") }
        XCTAssertNotNil(try rig.store.load())
    }

    // MARK: list (donorEvents + inviteOnlyEvents)

    func testListMergesPublicAndInviteOnlyDedupesAndSortsSoonestFirst() async throws {
        let transport = ScriptedTransport { seen, _ in
            switch seen.request.path {
            case "/donor/me/events":
                return (.ok, listJSON(eventJSON(id: eventB, start: "2026-11-09T15:00:00Z", end: "2026-11-09T17:00:00Z"),
                                      eventJSON(id: eventA, status: #""RESERVED""#)))
            case "/donor/me/events/invite-only":
                return (.ok, listJSON(eventJSON(id: eventC, type: "INVITE_ONLY", note: #""Invitation earned at Founding Donor""#,
                                                start: "2026-11-08T15:00:00Z", end: "2026-11-08T17:00:00Z"),
                                      eventJSON(id: eventA, status: #""RESERVED""#)))
            default: return (.notFound, "{}")
            }
        }
        let rig = try make(transport)
        let events = try await rig.service.events()
        XCTAssertEqual(events.map(\.id), [eventA, eventC, eventB], "soonest first, one copy of an event in both reads")
        XCTAssertEqual(events[0].status, .reserved)
        XCTAssertTrue(events[1].isInviteOnly)
        XCTAssertEqual(events[1].invitationNote, "Invitation earned at Founding Donor")
        let call = try XCTUnwrap(transport.calls(to: "/donor/me/events").first)
        XCTAssertEqual(call.request.headerFields[.authorization], "Bearer tok")
        XCTAssertEqual(call.request.headerFields[nativeClientHeader], "native")
    }

    func testEventFieldsMapIncludingUncappedAndOptionalFields() async throws {
        let rig = try make(ScriptedTransport { seen, _ in
            seen.request.path == "/donor/me/events/invite-only" ? (.ok, listJSON())
                : (.ok, listJSON(eventJSON(type: "COMMUNITY", status: #""WAITLISTED""#, capacity: 0, spots: "null", opens: #""2026-11-01T09:00:00Z""#,
                                           early: true, cancelled: true, report: "null")))
        })
        let all = try await rig.service.events()
        let event = try XCTUnwrap(all.first)
        XCTAssertEqual(event.type, "community")
        XCTAssertEqual(event.typeLabel, "Community")
        XCTAssertEqual(event.status, .waitlisted)
        XCTAssertTrue(event.isUncapped)
        XCTAssertNil(event.reportIssueURL)
        XCTAssertTrue(event.cancelled)
        XCTAssertTrue(event.earlyBooking)
        XCTAssertEqual(event.bookingOpensAt?.timeIntervalSince1970, 1_793_523_600)
        XCTAssertEqual(event.address, "2100 Barton Springs Rd")
        XCTAssertEqual(event.details, "Bring water.")
        XCTAssertEqual(event.startsAt.timeIntervalSince1970, 1_794_063_600)
    }

    func testUnknownEnumValuesDecodeInsteadOfFailingTheList() async throws {
        let rig = try make(ScriptedTransport { seen, _ in
            seen.request.path == "/donor/me/events/invite-only" ? (.ok, listJSON())
                : (.ok, listJSON(eventJSON(type: "GALA", status: #""PENDING_REVIEW""#)))
        })
        let events = try await rig.service.events()
        let event = try XCTUnwrap(events.first)
        XCTAssertEqual(event.type, "gala")
        XCTAssertEqual(event.typeLabel, "Gala")
        XCTAssertEqual(event.status, .none, "an unknown reservation status is no usable reservation")
    }

    func testUnknownReservationResultStatusIsNotASuccess() async throws {
        for json in [#"{"status":"PENDING"}"#] {
            let reserve = try make(ScriptedTransport { _, _ in (.ok, json) })
            do { _ = try await reserve.service.reserve(eventID: eventA); XCTFail() } catch { XCTAssertEqual(error as? AccountError, .invalidResponse) }
            let cancel = try make(ScriptedTransport { _, _ in (.ok, json) })
            do { try await cancel.service.cancel(eventID: eventA); XCTFail() } catch { XCTAssertEqual(error as? AccountError, .invalidResponse) }
        }
    }

    func testTimeZoneAndCheckedInAtAreMapped() async throws {
        let rig = try make(ScriptedTransport { seen, _ in
            seen.request.path == "/donor/me/events/invite-only" ? (.ok, listJSON())
                : (.ok, listJSON(eventJSON(status: #""RESERVED""#, zone: "America/Los_Angeles", checkedInAt: #""2026-11-07T15:05:00Z""#)))
        })
        let events = try await rig.service.events()
        let event = try XCTUnwrap(events.first)
        XCTAssertEqual(event.timeZoneID, "America/Los_Angeles")
        XCTAssertEqual(event.checkedInAt?.timeIntervalSince1970, 1_794_063_900)
        XCTAssertEqual(event.status, .checkedIn, "RESERVED plus checked_in_at is checked in")
        XCTAssertEqual(event.availability(now: Date(timeIntervalSince1970: 1_794_064_000)), .checkedIn)
    }

    func testReservedWithoutCheckedInAtStaysReserved() async throws {
        let rig = try make(ScriptedTransport { _, _ in (.ok, eventJSON(status: #""RESERVED""#)) })
        let event = try await rig.service.event(id: eventA)
        XCTAssertEqual(event.status, .reserved)
        XCTAssertNil(event.checkedInAt)
    }

    func testFractionalSecondTimestampsDecode() async throws {
        let rig = try make(ScriptedTransport { seen, _ in
            seen.request.path == "/donor/me/events/invite-only" ? (.ok, listJSON())
                : (.ok, listJSON(eventJSON(start: "2026-11-07T15:00:00.5Z", end: "2026-11-07T17:00:00.25Z")))
        })
        let events = try await rig.service.events()
        XCTAssertEqual(events.count, 1)
    }

    func testInviteOnlyReadFailureFailsTheListRatherThanHidingEvents() async throws {
        let rig = try make(ScriptedTransport { seen, _ in
            seen.request.path == "/donor/me/events" ? (.ok, listJSON(eventJSON())) : (.serviceUnavailable, "{}")
        })
        do { _ = try await rig.service.events(); XCTFail() }
        catch { XCTAssertEqual(error as? AccountError, .unavailable) }
    }

    func testListStatusMappingIncludingBodylessIngress429() async throws {
        try await assertMapping([
            (.tooManyRequests, "", .rateLimited),    // the ingress limiter sends no body
            (.tooManyRequests, "{}", .rateLimited),
            (.serviceUnavailable, "{}", .unavailable),
            (.internalServerError, "{}", .unavailable),
        ]) { _ = try await $0.events() }
    }

    func testMalformedAndOversizeBodiesThrow() async throws {
        let padding = String(repeating: "a", count: 1_100_000)
        for body in [#"{"events":[{"id":"x"}]}"#, "<html>", listJSON(eventJSON(zone: "")).replacingOccurrences(of: "\"time_zone\":\"\",", with: ""), #"{"events":[],"pad":""# + padding + #""}"#] {
            let rig = try make(ScriptedTransport { _, _ in (.ok, body) })
            do { _ = try await rig.service.events(); XCTFail(String(body.prefix(40))) } catch { assertBodyRejected(error) }
        }
    }

    func testList401RefreshesOnceThenSucceeds() async throws {
        let transport = ScriptedTransport { seen, _ in
            switch seen.request.path {
            case "/donor/refresh": return (.ok, freshSessionJSON)
            case "/donor/me/events":
                return seen.request.headerFields[.authorization] == "Bearer fresh" ? (.ok, listJSON(eventJSON())) : (.unauthorized, "{}")
            case "/donor/me/events/invite-only": return (.ok, listJSON())
            default: return (.notFound, "{}")
            }
        }
        let rig = try make(transport)
        let events = try await rig.service.events()
        XCTAssertEqual(events.count, 1)
        XCTAssertEqual(transport.calls(to: "/donor/refresh").count, 1)
    }

    func testSecond401EndsTheSessionLocally() async throws {
        let rig = try make(ScriptedTransport { _, _ in (.unauthorized, "{}") })
        do { _ = try await rig.service.events(); XCTFail() }
        catch { XCTAssertEqual(error as? AccountError, .signedOut) }
        XCTAssertNil(try rig.store.load())
    }

    func testListCancellationPropagatesAndKeepsTheSession() async throws {
        try await assertCancellation(listJSON()) { _ = try await $0.events() }
    }

    // MARK: detail

    func testDetailMapsAndRefusesAMalformedIDBeforeTheNetwork() async throws {
        let transport = ScriptedTransport { _, _ in (.ok, eventJSON(status: #""RESERVED""#)) }
        let rig = try make(transport)
        let event = try await rig.service.event(id: eventA)
        XCTAssertEqual(event.status, .reserved)
        XCTAssertEqual(transport.seen.first?.request.path, "/donor/me/events/\(eventA)")
        do { _ = try await rig.service.event(id: "../etc/passwd"); XCTFail() }
        catch { XCTAssertEqual(error as? AccountError, .invalidInput) }
        XCTAssertEqual(transport.seen.count, 1)
    }

    func testDetailStatusMapping() async throws {
        try await assertMapping([
            (.notFound, "{}", .notFound),            // gone, or hidden by the invite-only gate
            (.tooManyRequests, "", .rateLimited),
            (.serviceUnavailable, "{}", .unavailable),
        ]) { _ = try await $0.event(id: eventA) }
    }

    // MARK: reserve

    func testReserveWithNoBodyReturnsReservedOrWaitlisted() async throws {
        for (json, expected) in [(reservedJSON, ReservationOutcome.reserved), (#"{"status":"WAITLISTED"}"#, .waitlisted)] {
            let transport = ScriptedTransport { _, _ in (.ok, json) }
            let rig = try make(transport)
            let outcome = try await rig.service.reserve(eventID: eventA)
            XCTAssertEqual(outcome, expected)
            let call = try XCTUnwrap(transport.seen.first)
            XCTAssertEqual(call.request.method, .post)
            XCTAssertEqual(call.request.path, "/donor/me/events/\(eventA)/reserve")
            XCTAssertEqual(call.body, "", "reserve carries no body")
            XCTAssertEqual(call.request.headerFields[.authorization], "Bearer tok")
        }
    }

    func testReserveStatusMappingIncluding403And409And429() async throws {
        try await assertMapping([
            (.forbidden, "{}", .forbidden),          // not eligible
            (.notFound, "{}", .notFound),
            (.conflict, "{}", .conflict),            // full / started / not open yet
            (.tooManyRequests, "", .rateLimited),    // ingress limiter, no body
            (.tooManyRequests, "{}", .rateLimited),
            (.unprocessableContent, "{}", .invalidInput),
            (.serviceUnavailable, "{}", .unavailable),
            (.internalServerError, "{}", .unavailable),
        ]) { _ = try await $0.reserve(eventID: eventA) }
    }

    func testReserveMalformedOrCancelledResultIsNotASuccess() async throws {
        for json in [cancelledJSON, #"{"status":"SOON"}"#, "{}", "nope"] {
            let rig = try make(ScriptedTransport { _, _ in (.ok, json) })
            do { _ = try await rig.service.reserve(eventID: eventA); XCTFail(json) } catch { assertBodyRejected(error) }
        }
    }

    func testReserveRefusesAMalformedIDWithoutCallingTheServer() async throws {
        let transport = ScriptedTransport { _, _ in (.ok, reservedJSON) }
        let rig = try make(transport)
        do { _ = try await rig.service.reserve(eventID: "not-a-uuid"); XCTFail() }
        catch { XCTAssertEqual(error as? AccountError, .invalidInput) }
        XCTAssertTrue(transport.seen.isEmpty)
    }

    func testReserve401RefreshesAndRetriesOnce() async throws {
        let transport = ScriptedTransport { seen, _ in
            if seen.request.path == "/donor/refresh" { return (.ok, freshSessionJSON) }
            return seen.request.headerFields[.authorization] == "Bearer fresh" ? (.ok, reservedJSON) : (.unauthorized, "{}")
        }
        let rig = try make(transport)
        let outcome = try await rig.service.reserve(eventID: eventA)
        XCTAssertEqual(outcome, .reserved)
        XCTAssertEqual(transport.calls(to: "/donor/refresh").count, 1)
        XCTAssertEqual(transport.calls(to: "/donor/me/events/\(eventA)/reserve").count, 2)
    }

    func testReserveSendsNoIdempotencyKeyBecauseTheContractDefinesNone() async throws {
        let transport = ScriptedTransport { _, _ in (.ok, reservedJSON) }
        let rig = try make(transport)
        _ = try await rig.service.reserve(eventID: eventA)
        XCTAssertNil(transport.seen.first?.request.headerFields[HTTPField.Name("Idempotency-Key")!])
    }

    func testReserveCancellationPropagatesAndKeepsTheSession() async throws {
        try await assertCancellation(reservedJSON) { _ = try await $0.reserve(eventID: eventA) }
    }

    // MARK: cancel

    func testCancelPostsToTheCancelPathAndRequiresCancelledResult() async throws {
        let transport = ScriptedTransport { _, _ in (.ok, cancelledJSON) }
        let rig = try make(transport)
        try await rig.service.cancel(eventID: eventA)
        let call = try XCTUnwrap(transport.seen.first)
        XCTAssertEqual(call.request.method, .post)
        XCTAssertEqual(call.request.path, "/donor/me/events/\(eventA)/cancel")
        for json in [reservedJSON, "{}", "nope"] {
            let wrong = try make(ScriptedTransport { _, _ in (.ok, json) })
            do { try await wrong.service.cancel(eventID: eventA); XCTFail(json) } catch { assertBodyRejected(error) }
        }
    }

    func testCancelStatusMappingIncluding403And409And429() async throws {
        try await assertMapping([
            (.forbidden, "{}", .forbidden),
            (.notFound, "{}", .notFound),
            (.conflict, "{}", .conflict),
            (.tooManyRequests, "", .rateLimited),
            (.tooManyRequests, "{}", .rateLimited),
            (.serviceUnavailable, "{}", .unavailable),
        ]) { try await $0.cancel(eventID: eventA) }
    }

    func testCancelCancellationPropagates() async throws {
        try await assertCancellation(cancelledJSON) { try await $0.cancel(eventID: eventA) }
    }

    // MARK: check-in

    func testCheckInPostsTheTokenAndMapsTheResult() async throws {
        let transport = ScriptedTransport { _, _ in (.ok, #"{"event_id":"\#(eventA)","checked_in":true,"already_checked_in":false}"#) }
        let rig = try make(transport)
        let result = try await rig.service.checkIn(code: validCheckInToken)
        XCTAssertEqual(result, CheckInResultValue(eventID: eventA, checkedIn: true, alreadyCheckedIn: false))
        let call = try XCTUnwrap(transport.seen.first)
        XCTAssertEqual(call.request.path, "/donor/me/events/check-in")
        let body = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(call.body.utf8)) as? [String: String])
        XCTAssertEqual(body, ["token": validCheckInToken])
    }

    func testCheckInSecondScanIsAlreadyCheckedIn() async throws {
        let rig = try make(ScriptedTransport { _, _ in (.ok, #"{"event_id":"\#(eventA)","checked_in":false,"already_checked_in":true}"#) })
        let result = try await rig.service.checkIn(code: validCheckInToken)
        XCTAssertTrue(result.alreadyCheckedIn)
    }

    func testCheckInStatusMappingIncluding403And422And429() async throws {
        try await assertMapping([
            (.forbidden, "{}", .forbidden),                  // not eligible to check in
            (.unprocessableContent, "{}", .invalidInput),    // outside the window, no held seat, unknown code
            (.tooManyRequests, "", .rateLimited),
            (.tooManyRequests, "{}", .rateLimited),
            (.serviceUnavailable, "{}", .unavailable),
            (.unsupportedMediaType, "{}", .unavailable),
        ]) { _ = try await $0.checkIn(code: validCheckInToken) }
    }

    func testCheckInRefusesEmptyOrNulCodesWithoutCallingTheServer() async throws {
        let transport = ScriptedTransport { _, _ in (.ok, "{}") }
        let rig = try make(transport)
        for code in ["", "a\u{0}b", String(repeating: "x", count: 2000), "tok", String(validCheckInToken.dropLast()), validCheckInToken + "x",
                     validCheckInToken.replacingOccurrences(of: ".", with: "-"), String(validCheckInToken.dropLast()) + "="] {
            do { _ = try await rig.service.checkIn(code: code); XCTFail() }
            catch { XCTAssertEqual(error as? AccountError, .invalidInput) }
        }
        XCTAssertTrue(transport.seen.isEmpty)
    }

    func testCheckInMalformedBodyThrows() async throws {
        let rig = try make(ScriptedTransport { _, _ in (.ok, #"{"event_id":"x"}"#) })
        do { _ = try await rig.service.checkIn(code: validCheckInToken); XCTFail() } catch { assertBodyRejected(error) }
    }

    // MARK: calendar

    func testCalendarReturnsTheICSBytes() async throws {
        let transport = ScriptedTransport { _, _ in (.ok, icsText) }
        let rig = try make(transport)
        let data = try await rig.service.calendar(eventID: eventA)
        XCTAssertEqual(String(decoding: data, as: UTF8.self), icsText)
        XCTAssertEqual(transport.seen.first?.request.path, "/donor/me/events/\(eventA)/calendar.ics")
        XCTAssertEqual(transport.seen.first?.request.headerFields[.authorization], "Bearer tok")
    }

    func testCalendarStatusMapping() async throws {
        try await assertMapping([
            (.notFound, "{}", .notFound), (.tooManyRequests, "", .rateLimited), (.serviceUnavailable, "{}", .unavailable),
            (.forbidden, "{}", .forbidden),
        ]) { _ = try await $0.calendar(eventID: eventA) }
    }

    func testCalendarOversizeBodyIsRefused() async throws {
        let big = "BEGIN:VCALENDAR\r\n" + String(repeating: "X-PAD:1\r\n", count: 20_000)
        let rig = try make(ScriptedTransport { _, _ in (.ok, big) })
        do { _ = try await rig.service.calendar(eventID: eventA); XCTFail() } catch { assertBodyRejected(error) }
    }

    func testCalendarRefusesAMalformedID() async throws {
        let transport = ScriptedTransport { _, _ in (.ok, icsText) }
        let rig = try make(transport)
        do { _ = try await rig.service.calendar(eventID: "nope"); XCTFail() }
        catch { XCTAssertEqual(error as? AccountError, .invalidInput) }
        XCTAssertTrue(transport.seen.isEmpty)
    }
}
