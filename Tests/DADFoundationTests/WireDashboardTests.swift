import Foundation
import HTTPTypes
import OpenAPIRuntime
import XCTest
@testable import DADFoundation

private let giftUUID = "7b0c6f9e-3c5a-4f0e-9a52-0d3a1c0e7a11"

func dashboardReadyJSON(streak: String? = nil, rank: String = "null", optedOut: Bool = false, network: String? = nil,
                        referrals: String? = nil, given: String = "124000") -> String {
    let streakJSON = streak ?? #"{"at_risk":false,"current":18,"grace_ends_at":null,"ladder":{"days":18,"last_milestone":7,"next_milestone":30,"days_to_next":12,"bar":[true,true,true,false]}}"#
    let networkJSON = network ?? #"{"active_count":3,"annualized_minor":474500,"currency":"USD"}"#
    let referralsJSON = referrals ?? #"{"currency":"USD","irl":1,"irl_minor":3000,"link":2,"link_minor":9000,"total_minor":12000}"#
    return #"{"state":"ready","mode":"test","computed_at":"2026-10-30T12:00:00Z","founding_donor":true,"referrals":\#(referralsJSON),"streak":\#(streakJSON),"rank":\#(rank),"rankings_opted_out":\#(optedOut),"network":\#(networkJSON),"impact":{"given_minor":\#(given),"currency":"USD","initiatives_funded":4,"events_volunteered":2}}"#
}

let todayJSON = #"{"initiative_id":"abc","slug":"meals","title":"Meals on Wheels","summary":"Hot meals for neighbours.","region":"TX","location":"Austin, TX","type":"PROGRAM","started_on":"2025-01-02","metrics":[{"label":"Meals this week","value":1200,"unit":"PEOPLE","verified_on":"2026-10-28"},{"label":"Cost per meal","value":425,"unit":"USD_CENTS","verified_on":"2026-10-28"},{"label":"Partners","value":1,"unit":"PARTNERS","verified_on":"2026-10-28"}],"distinct_shown":4}"#

func giftsPageJSON(ids: [String], next: Int?) -> String {
    let rows = ids.map { #"{"id":"\#($0)","amount_minor":3000,"currency":"USD","frequency":"MONTHLY","paid_at":"2026-10-01T10:00:00Z","refunded_minor":500,"net_minor":2500}"# }
    return #"{"email":"alex@example.org","mode":"test","gifts":[\#(rows.joined(separator: ","))],"next_offset":\#(next.map(String.init) ?? "null")}"#
}

private func giftRecordJSON(id: String) -> String {
    #"{"id":"\#(id)","amount_minor":3000,"currency":"USD","paid_at":"2026-10-01T10:00:00Z","frequency":"MONTHLY","refunded_minor":500,"net_minor":2500,"refunds":[{"id":"re_1","amount_minor":500,"status":"succeeded","observed_at":"2026-10-02T10:00:00Z"}]}"#
}

final class WireDashboardTests: XCTestCase {
    private typealias Rig = (service: WireDashboard, session: AccountSession, store: MemoryStore)

    private func make(_ transport: ScriptedTransport) throws -> Rig {
        let store = MemoryStore(Credentials(access: "tok", refresh: "ref", expiresAt: .distantFuture))
        let session = try AccountSession(api: WireAPI(origin: testOrigin, transport: transport), store: store)
        return (WireDashboard(product: ProductClient(origin: testOrigin, transport: transport, session: session)), session, store)
    }

    // MARK: dashboard

    func testReadyDashboardMapsEveryCardWithBearerAndNativeHeader() async throws {
        let transport = ScriptedTransport { _, _ in (.ok, dashboardReadyJSON(rank: #"{"national_percentile":2,"city":"Austin","city_rank":4,"computed_at":"2026-10-30T00:00:00Z"}"#)) }
        let rig = try make(transport)
        guard case .ready(let dash) = try await rig.service.dashboard() else { return XCTFail("expected ready") }
        XCTAssertEqual(dash.streak?.current, 18)
        XCTAssertEqual(dash.streak?.ladder?.nextMilestone, 30)
        XCTAssertEqual(dash.streak?.ladder?.nextLabel, "12 days to your 30-day milestone")
        XCTAssertEqual(dash.streak?.ladder?.bar, [true, true, true, false])
        XCTAssertEqual(dash.impact.givenMinor, 124_000)
        XCTAssertEqual(dash.impact.givenLabel, "$1,240")
        XCTAssertEqual(dash.network?.annualizedLabel, "$4,745/yr")
        XCTAssertEqual(dash.referrals?.joined, 3)
        XCTAssertTrue(dash.foundingDonor)
        XCTAssertEqual(dash.rank, .ranked(DashboardRank(topPercent: 2, city: "Austin", cityRank: 4)))
        let call = try XCTUnwrap(transport.seen.first)
        XCTAssertEqual(call.request.path, "/donor/me/dashboard")
        XCTAssertEqual(call.request.headerFields[.authorization], "Bearer tok")
        XCTAssertEqual(call.request.headerFields[nativeClientHeader], "native")
    }

    func testPreparingStateIsNotAnError() async throws {
        let rig = try make(ScriptedTransport { _, _ in (.ok, #"{"state":"preparing","mode":"test"}"#) })
        let state = try await rig.service.dashboard()
        XCTAssertEqual(state, .preparing)
    }

    func testNullStreakReferralsNetworkAndNullGivenAreUnknownNotZero() async throws {
        let json = #"{"state":"ready","mode":"test","computed_at":"2026-10-30T12:00:00Z","founding_donor":false,"referrals":null,"streak":null,"rank":null,"rankings_opted_out":false,"network":null,"impact":{"given_minor":null,"currency":"USD","initiatives_funded":0,"events_volunteered":0}}"#
        let rig = try make(ScriptedTransport { _, _ in (.ok, json) })
        guard case .ready(let dash) = try await rig.service.dashboard() else { return XCTFail() }
        XCTAssertNil(dash.streak)
        XCTAssertNil(dash.referrals)
        XCTAssertNil(dash.network)
        XCTAssertNil(dash.impact.givenMinor)
        XCTAssertEqual(dash.impact.givenLabel, "—", "an unknown total must not read as $0")
        XCTAssertEqual(dash.rank, .notRankedYet)
    }

    func testStreakWithNullLadderAndAtRiskGrace() async throws {
        let streak = #"{"at_risk":true,"current":9,"grace_ends_at":"2026-11-02T00:00:00Z","ladder":null}"#
        let rig = try make(ScriptedTransport { _, _ in (.ok, dashboardReadyJSON(streak: streak)) })
        guard case .ready(let dash) = try await rig.service.dashboard() else { return XCTFail() }
        XCTAssertEqual(dash.streak?.atRisk, true)
        XCTAssertNotNil(dash.streak?.graceEndsAt)
        XCTAssertNil(dash.streak?.ladder)
    }

    func testOptedOutUsesTheExplicitFlagEvenWhenARankIsPresent() async throws {
        let rank = #"{"national_percentile":2,"city":null,"city_rank":null,"computed_at":"2026-10-30T00:00:00Z"}"#
        let rig = try make(ScriptedTransport { _, _ in (.ok, dashboardReadyJSON(rank: rank, optedOut: true)) })
        guard case .ready(let dash) = try await rig.service.dashboard() else { return XCTFail() }
        XCTAssertEqual(dash.rank, .optedOut, "a hidden donor never shows a position")
    }

    func testRankLabelsReadAsTopPercentAndNeverZero() {
        XCTAssertEqual(DashboardRank(topPercent: 2, city: nil, cityRank: nil).nationalLabel, "Top 2% nationally")
        XCTAssertEqual(DashboardRank(topPercent: 0, city: nil, cityRank: nil).nationalLabel, "Top 1% nationally")
        XCTAssertEqual(DashboardRank(topPercent: 5, city: "Reno", cityRank: 3).cityLabel, "#3 in Reno")
        XCTAssertNil(DashboardRank(topPercent: 5, city: "Reno", cityRank: nil).cityLabel)
    }

    func testDashboardStatusMapping() async throws {
        let cases: [(HTTPResponse.Status, AccountError)] = [
            (.tooManyRequests, .rateLimited), (.serviceUnavailable, .unavailable), (.forbidden, .unavailable), (.notFound, .unavailable),
        ]
        for (status, expected) in cases {
            let rig = try make(ScriptedTransport { _, _ in (status, "{}") })
            do { _ = try await rig.service.dashboard(); XCTFail("\(status)") }
            catch { XCTAssertEqual(error as? AccountError, expected, "\(status)") }
            XCTAssertNotNil(try rig.store.load(), "\(status) must keep the session")
        }
    }

    func testMalformedBodyIsAnErrorNotACrash() async throws {
        for body in ["not json", #"{"state":"ready"}"#, #"{"state":"mystery","mode":"test"}"#] {
            let rig = try make(ScriptedTransport { _, _ in (.ok, body) })
            do { _ = try await rig.service.dashboard(); XCTFail(body) } catch { assertBodyRejected(error) }
        }
    }

    func testOversizeBodyIsRefused() async throws {
        let padding = String(repeating: "a", count: 1_100_000)
        let rig = try make(ScriptedTransport { _, _ in (.ok, #"{"state":"preparing","mode":"test","pad":""# + padding + #""}"#) })
        do { _ = try await rig.service.dashboard(); XCTFail() } catch { assertBodyRejected(error) }
    }

    // MARK: 401 refresh race

    func testDashboard401RefreshesOnceThenSucceeds() async throws {
        let transport = ScriptedTransport { seen, _ in
            switch seen.request.path {
            case "/donor/refresh": return (.ok, freshSessionJSON)
            case "/donor/me/dashboard":
                return seen.request.headerFields[.authorization] == "Bearer fresh" ? (.ok, #"{"state":"preparing","mode":"test"}"#) : (.unauthorized, "{}")
            default: return (.notFound, "{}")
            }
        }
        let rig = try make(transport)
        let state = try await rig.service.dashboard()
        XCTAssertEqual(state, .preparing)
        XCTAssertEqual(transport.calls(to: "/donor/refresh").count, 1)
        XCTAssertEqual(transport.calls(to: "/donor/me/dashboard").count, 2)
    }

    func testSecond401EndsTheSessionLocally() async throws {
        let rig = try make(ScriptedTransport { _, _ in (.unauthorized, "{}") })
        do { _ = try await rig.service.dashboard(); XCTFail() }
        catch { XCTAssertEqual(error as? AccountError, .signedOut) }
        XCTAssertNil(try rig.store.load())
    }

    func testConcurrentReadsShareOneRefresh() async throws {
        let transport = ScriptedTransport { seen, _ in
            switch seen.request.path {
            case "/donor/refresh": return (.ok, freshSessionJSON)
            case "/donor/me/dashboard", "/donor/me/today-initiative":
                guard seen.request.headerFields[.authorization] == "Bearer fresh" else { return (.unauthorized, "{}") }
                return seen.request.path == "/donor/me/dashboard" ? (.ok, #"{"state":"preparing","mode":"test"}"#) : (.ok, todayJSON)
            default: return (.notFound, "{}")
            }
        }
        let rig = try make(transport)
        async let a = rig.service.dashboard()
        async let b = rig.service.todayInitiative()
        _ = try await (a, b)
        XCTAssertEqual(transport.calls(to: "/donor/refresh").count, 1)
    }

    // MARK: cancellation

    func testCancellationSurfacesAsCancellationNotAFailure() async throws {
        let gate = Gate()
        let transport = ScriptedTransport { _, _ in
            await gate.pass()
            try Task.checkCancellation()
            return (.ok, #"{"state":"preparing","mode":"test"}"#)
        }
        let rig = try make(transport)
        let task = Task { try await rig.service.dashboard() }
        await gate.waitUntilEntered()
        task.cancel()
        await gate.release()
        do { _ = try await task.value; XCTFail() }
        catch { XCTAssertTrue(error.isCancellation, "\(error)") }
        XCTAssertNotNil(try rig.store.load(), "cancelling a read must not end the session")
    }

    // MARK: today's initiative

    func testTodayInitiativeMapsMetricsAndLabels() async throws {
        let rig = try make(ScriptedTransport { _, _ in (.ok, todayJSON) })
        let fetched = try await rig.service.todayInitiative()
        let today = try XCTUnwrap(fetched)
        XCTAssertEqual(today.title, "Meals on Wheels")
        XCTAssertEqual(today.location, "Austin, TX")
        XCTAssertEqual(today.kind, "PROGRAM")
        XCTAssertEqual(today.startedOn, "2025-01-02")
        XCTAssertEqual(today.metrics.map(\.valueLabel), ["1200 people", "$4.25", "1 partner"])
    }

    func testTodayInitiative404MeansNothingInRotation() async throws {
        let rig = try make(ScriptedTransport { _, _ in (.notFound, "{}") })
        let today = try await rig.service.todayInitiative()
        XCTAssertNil(today)
    }

    func testUnknownMetricUnitStillRendersTheNumber() async throws {
        XCTAssertEqual(InitiativeMetric(label: "x", value: 7, unit: nil, verifiedOn: "").valueLabel, "7")
        XCTAssertEqual(InitiativeMetric(label: "x", value: 1, unit: .initiatives, verifiedOn: "").valueLabel, "1 initiative")
    }

    func testHeadlineMetricsCapAtFour() {
        let metrics = (0..<6).map { InitiativeMetric(label: "m\($0)", value: $0, unit: .people, verifiedOn: "") }
        let today = TodayInitiative(id: "1", slug: "s", title: "t", summary: "", location: "", kind: "", startedOn: "", metrics: metrics)
        XCTAssertEqual(today.headlineMetrics.count, 4)
    }

    func testTodayInitiativeStatusMapping() async throws {
        let cases: [(HTTPResponse.Status, AccountError)] = [(.tooManyRequests, .rateLimited), (.serviceUnavailable, .unavailable), (.forbidden, .unavailable)]
        for (status, expected) in cases {
            let rig = try make(ScriptedTransport { _, _ in (status, "{}") })
            do { _ = try await rig.service.todayInitiative(); XCTFail("\(status)") }
            catch { XCTAssertEqual(error as? AccountError, expected, "\(status)") }
        }
    }

    // MARK: gifts

    func testGiftsPageSendsOffsetAndMapsMoney() async throws {
        let transport = ScriptedTransport { _, _ in (.ok, giftsPageJSON(ids: [giftUUID], next: 50)) }
        let rig = try make(transport)
        let page = try await rig.service.gifts(offset: 0)
        XCTAssertEqual(page.nextOffset, 50)
        let gift = try XCTUnwrap(page.gifts.first)
        XCTAssertEqual(gift.amountMinor, 3000)
        XCTAssertEqual(gift.amountLabel, "$30")
        XCTAssertEqual(gift.netLabel, "$25")
        XCTAssertEqual(gift.refundLabel, "$5 refunded")
        XCTAssertEqual(gift.frequency, .monthly)
        _ = try await rig.service.gifts(offset: 50)
        let queries = transport.seen.map { $0.request.path ?? "" }
        XCTAssertTrue(queries[1].hasSuffix("offset=50"), queries[1])
    }

    func testLastPageEndsPagination() async throws {
        let rig = try make(ScriptedTransport { _, _ in (.ok, giftsPageJSON(ids: [giftUUID], next: nil)) })
        let page = try await rig.service.gifts(offset: 50)
        XCTAssertNil(page.nextOffset)
    }

    func testEmptyHistoryIsAValidPage() async throws {
        let rig = try make(ScriptedTransport { _, _ in (.ok, giftsPageJSON(ids: [], next: nil)) })
        let page = try await rig.service.gifts(offset: 0)
        XCTAssertTrue(page.gifts.isEmpty)
    }

    func testNegativeOffsetNeverReachesTheNetwork() async throws {
        let transport = ScriptedTransport { _, _ in (.ok, giftsPageJSON(ids: [], next: nil)) }
        let rig = try make(transport)
        do { _ = try await rig.service.gifts(offset: -1); XCTFail() }
        catch { XCTAssertEqual(error as? AccountError, .invalidInput) }
        XCTAssertTrue(transport.seen.isEmpty)
    }

    func testGiftsStatusMapping() async throws {
        let cases: [(HTTPResponse.Status, AccountError)] = [
            (.unprocessableContent, .invalidInput), (.tooManyRequests, .rateLimited), (.serviceUnavailable, .unavailable), (.forbidden, .unavailable),
        ]
        for (status, expected) in cases {
            let rig = try make(ScriptedTransport { _, _ in (status, "{}") })
            do { _ = try await rig.service.gifts(offset: 0); XCTFail("\(status)") }
            catch { XCTAssertEqual(error as? AccountError, expected, "\(status)") }
        }
    }

    func testGiftsMalformedBodyThrows() async throws {
        let rig = try make(ScriptedTransport { _, _ in (.ok, #"{"gifts":"nope"}"#) })
        do { _ = try await rig.service.gifts(offset: 0); XCTFail() } catch { assertBodyRejected(error) }
    }

    // MARK: receipt + annual summary

    func testReceiptMapsGiftAndRefunds() async throws {
        let json = #"{"mode":"test","tax_receipt":false,"as_of":"2026-10-30T00:00:00Z","receipt_id":"r1","gift":\#(giftRecordJSON(id: giftUUID))}"#
        let transport = ScriptedTransport { _, _ in (.ok, json) }
        let rig = try make(transport)
        let receipt = try await rig.service.receipt(giftID: giftUUID)
        XCTAssertEqual(receipt.gift.id, giftUUID)
        XCTAssertFalse(receipt.taxReceipt)
        XCTAssertEqual(receipt.refunds.map(\.amountMinor), [500])
        XCTAssertEqual(transport.seen.first?.request.path, "/donor/me/receipts/\(giftUUID)")
    }

    func testReceiptRejectsANonUUIDBeforeTheNetwork() async throws {
        let transport = ScriptedTransport { _, _ in (.ok, "{}") }
        let rig = try make(transport)
        do { _ = try await rig.service.receipt(giftID: "../../x"); XCTFail() }
        catch { XCTAssertEqual(error as? AccountError, .invalidInput) }
        XCTAssertTrue(transport.seen.isEmpty)
    }

    func testReceiptStatusMapping() async throws {
        let cases: [(HTTPResponse.Status, AccountError)] = [
            (.notFound, .invalidInput), (.unprocessableContent, .invalidInput), (.conflict, .unavailable),
            (.tooManyRequests, .rateLimited), (.serviceUnavailable, .unavailable),
        ]
        for (status, expected) in cases {
            let rig = try make(ScriptedTransport { _, _ in (status, "{}") })
            do { _ = try await rig.service.receipt(giftID: giftUUID); XCTFail("\(status)") }
            catch { XCTAssertEqual(error as? AccountError, expected, "\(status)") }
        }
    }

    func testAnnualSummaryMapsTotals() async throws {
        let json = #"{"mode":"test","tax_receipt":false,"year":2026,"timezone":"America/Chicago","as_of":"2026-10-30T00:00:00Z","gifts":[\#(giftRecordJSON(id: giftUUID))],"amount_minor":3000,"refunded_minor":500,"net_minor":2500,"currency":"USD"}"#
        let transport = ScriptedTransport { _, _ in (.ok, json) }
        let rig = try make(transport)
        let summary = try await rig.service.annualSummary(year: 2026)
        XCTAssertEqual(summary, AnnualGivingSummary(year: 2026, giftCount: 1, amountMinor: 3000, refundedMinor: 500, netMinor: 2500, taxReceipt: false))
        XCTAssertEqual(summary.netLabel, "$25")
        XCTAssertEqual(transport.seen.first?.request.path, "/donor/me/annual-summary/2026")
    }

    func testAnnualSummaryOutOfRangeYearNeverReachesTheNetwork() async throws {
        let transport = ScriptedTransport { _, _ in (.ok, "{}") }
        let rig = try make(transport)
        do { _ = try await rig.service.annualSummary(year: 1999); XCTFail() }
        catch { XCTAssertEqual(error as? AccountError, .invalidInput) }
        XCTAssertTrue(transport.seen.isEmpty)
    }
}
