import Foundation
import HTTPTypes
import OpenAPIRuntime
import XCTest
@testable import DADFoundation

private let initiativeID = "11111111-1111-4111-8111-111111111111"

private func dashboardJSON(rank: String = #"{"national_percentile":2,"city":"Austin","city_rank":4,"computed_at":"2026-10-30T00:00:00Z"}"#,
                           optedOut: Bool = false, given: String = "124000", referrals: String =
                           #"{"currency":"USD","irl":1,"irl_minor":3000,"link":2,"link_minor":9000,"total_minor":12000}"#) -> String {
    #"{"state":"ready","mode":"test","computed_at":"2026-10-30T12:00:00Z","founding_donor":true,"referrals":\#(referrals),"streak":null,"rank":\#(rank),"rankings_opted_out":\#(optedOut),"network":null,"impact":{"given_minor":\#(given),"currency":"USD","initiatives_funded":4,"events_volunteered":2}}"#
}
private let preparingJSON = #"{"state":"preparing","mode":"test"}"#

private func badgeRow(_ code: String = "F", title: String = "Founding Donor", perk: String = "FOUNDING_EVENTS", earned: Bool = true,
                      city: String? = nil, displayTitle: String? = nil) -> String {
    let cityJSON = city.map { "\"\($0)\"" } ?? "null"
    return #"{"code":"\#(code)","title":"\#(title)","city":\#(cityJSON),"display_title":"\#(displayTitle ?? title)","rule":"Start a monthly gift","perk":"\#(perk)","earned":\#(earned),"earned_at":\#(earned ? #""2026-09-02T10:00:00Z""# : "null"),"artwork":"a"}"#
}
private func badgesJSON(_ rows: String...) -> String { #"{"badges":[\#(rows.joined(separator: ","))]}"# }

private let networkJSON = #"{"active_count":3,"annualized_minor":474500,"next_milestone":{"label":"Team Captain","target":20,"remaining":17},"invitees":[{"name":"Sam L","active":true},{"name":"Jo P","active":false}],"anonymous_active":1}"#
private func sharingJSON(name: String? = "Alex R", link: String? = "https://dollaraday.org/r/ALEX42", code: String? = "ALEX42") -> String {
    let c = code.map { "\"\($0)\"" } ?? "null"
    let n = name.map { "\"\($0)\"" } ?? "null"
    let l = link.map { "\"\($0)\"" } ?? "null"
    return #"{"public_name":\#(n),"link":\#(l),"irl_link":\#(l),"referral_code":\#(c)}"#
}
private func conversionsJSON(kind: String = "LINK", more: Bool = false) -> String {
    #"{"conversions":[{"converted_at":"2026-10-20T10:00:00Z","kind":"\#(kind)"},{"converted_at":"2026-10-02T10:00:00.5Z","kind":"IRL"}],"more":\#(more)}"#
}
private let spendJSON = #"{"initiative_id":"\#(initiativeID)","total_minor":125000,"categories":[{"category":"Food","amount_minor":90000},{"category":"Delivery","amount_minor":35000}]}"#

/// Answers every engagement read from a table of (status, body); a missing path is a 404.
private func engagementTransport(dashboard: (HTTPResponse.Status, String) = (.ok, dashboardJSON()),
                                 badges: (HTTPResponse.Status, String) = (.ok, badgesJSON(badgeRow())),
                                 network: (HTTPResponse.Status, String) = (.ok, networkJSON),
                                 sharing: (HTTPResponse.Status, String) = (.ok, sharingJSON()),
                                 conversions: (HTTPResponse.Status, String) = (.ok, conversionsJSON())) -> ScriptedTransport {
    ScriptedTransport { seen, _ in
        switch seen.request.path {
        case "/donor/me/dashboard": return dashboard
        case "/donor/me/badges": return badges
        case "/donor/me/network": return network
        case "/donor/me/sharing": return sharing
        case "/donor/me/conversions": return conversions
        case "/donor/refresh": return (.ok, freshSessionJSON)
        default: return (.notFound, "{}")
        }
    }
}

final class WireEngagementTests: XCTestCase {
    private typealias Rig = (service: WireEngagement, session: AccountSession, store: MemoryStore)

    private func make(_ transport: ScriptedTransport) throws -> Rig {
        let store = MemoryStore(Credentials(access: "tok", refresh: "ref", expiresAt: .distantFuture))
        let session = try AccountSession(api: WireAPI(origin: testOrigin, transport: transport), store: store)
        return (WireEngagement(product: ProductClient(origin: testOrigin, transport: transport, session: session)), session, store)
    }

    private func assertThrows(_ expected: AccountError, _ message: String = "", _ run: () async throws -> Void,
                              file: StaticString = #filePath, line: UInt = #line) async {
        do { try await run(); XCTFail("expected \(expected) \(message)", file: file, line: line) }
        catch { XCTAssertEqual(error as? AccountError, expected, message, file: file, line: line) }
    }

    // MARK: snapshot

    func testSnapshotMapsEverySection() async throws {
        let transport = engagementTransport()
        let snapshot = try await make(transport).service.snapshot()
        XCTAssertEqual(snapshot.impact, ImpactTotals(givenMinor: 124000, initiativesFunded: 4, eventsVolunteered: 2))
        XCTAssertEqual(snapshot.ranking, RankingStanding(nationalPercentile: 2, city: "Austin", cityRank: 4))
        XCTAssertEqual(snapshot.ranking?.nationalLabel, "Top 2% nationally", "the server's top bucket is shown as is")
        XCTAssertEqual(snapshot.badges?.badges.map(\.code), ["F"])
        XCTAssertEqual(snapshot.badges?.badges.first?.perk, "Invite-only founding events")
        XCTAssertEqual(snapshot.badges?.hasInviteOnlyAccess, true)
        XCTAssertEqual(snapshot.network?.activeCount, 3)
        XCTAssertEqual(snapshot.network?.invitees, [NetworkInvitee(name: "Sam L", active: true), NetworkInvitee(name: "Jo P", active: false)])
        XCTAssertEqual(snapshot.network?.anonymousActive, 1)
        XCTAssertEqual(snapshot.network?.nextMilestone, NetworkMilestone(label: "Team Captain", target: 20, remaining: 17))
        XCTAssertEqual(snapshot.referral?.code, "ALEX42")
        XCTAssertEqual(snapshot.referral?.linkCount, 2)
        XCTAssertEqual(snapshot.referral?.irlCount, 1)
        XCTAssertEqual(snapshot.referral?.conversions?.map(\.kind), [.link, .irl])
        XCTAssertFalse(snapshot.needsPublicName)
        XCTAssertTrue(transport.seen.allSatisfy { $0.request.headerFields[.authorization] == "Bearer tok" })
    }

    func testReferralCodeComesFromTheServerField() async throws {
        // The link path says ONE, the field says TWO: the displayed code is the field.
        let snap = try await make(engagementTransport(sharing: (.ok, sharingJSON(link: "https://dollaraday.org/r/ONE", code: "TWO")))).service.snapshot()
        XCTAssertEqual(snap.referral?.code, "TWO")
    }

    func testNullReferralCodeWithNullLinksNeedsAName() async throws {
        let snap = try await make(engagementTransport(sharing: (.ok, sharingJSON(name: nil, link: nil, code: nil)))).service.snapshot()
        XCTAssertNil(snap.referral)
        XCTAssertTrue(snap.needsPublicName)
    }

    func testCityBadgeShowsDisplayTitleWhenEarnedAndTitleWhenLocked() async throws {
        let rows = badgesJSON(
            badgeRow("CITY50", title: "Top 50 City", perk: "", earned: true, city: "Chicago", displayTitle: "Top 50 in Chicago"),
            badgeRow("C2", title: "Top 50 City", perk: "", earned: false, city: nil, displayTitle: "Top 50 City"),
            badgeRow("C3", title: "Top 50 City", perk: "", earned: false, city: "Chicago", displayTitle: "Top 50 in Chicago"),
            badgeRow("7", title: "One Week", perk: "", earned: true),
            badgeRow("E", title: "Blank Display", perk: "", earned: true, displayTitle: ""))
        let list = try await make(engagementTransport(badges: (.ok, rows))).service.snapshot().badges?.badges ?? []
        XCTAssertEqual(list.map(\.shownTitle), ["Top 50 in Chicago", "Top 50 City", "Top 50 City", "One Week", "Blank Display"])
        XCTAssertEqual(list.first?.accessibilitySummary, "Top 50 in Chicago, earned")
    }

    func testOptedOutAndNotRankedAreDistinct() async throws {
        let out = try await make(engagementTransport(dashboard: (.ok, dashboardJSON(rank: "null", optedOut: true)))).service.snapshot()
        XCTAssertEqual(out.ranking?.isOptedOut, true)
        let unranked = try await make(engagementTransport(dashboard: (.ok, dashboardJSON(rank: "null")))).service.snapshot()
        XCTAssertEqual(unranked.ranking?.isNotRankedYet, true)
        XCTAssertEqual(unranked.ranking?.isOptedOut, false)
    }

    func testUnknownFiguresStayUnknownNotZero() async throws {
        let snapshot = try await make(engagementTransport(dashboard: (.ok, dashboardJSON(given: "null", referrals: "null")))).service.snapshot()
        XCTAssertNil(snapshot.impact?.givenMinor)
        XCTAssertEqual(snapshot.impact?.givenLabel, "—")
        XCTAssertNil(snapshot.referral?.linkCount)
        XCTAssertNil(snapshot.referral?.totalConverted)
    }

    func testPreparingDashboardLeavesImpactUnknownButKeepsTheRankingsChoice() async throws {
        let transport = ScriptedTransport { seen, _ in
            switch seen.request.path {
            case "/donor/me/dashboard": return (.ok, preparingJSON)
            case "/donor/me/profile": return (.ok, profileJSON().replacingOccurrences(of: "\"rankings_opted_out\":false", with: "\"rankings_opted_out\":true"))
            case "/donor/me/badges": return (.ok, badgesJSON(badgeRow()))
            case "/donor/me/network": return (.ok, networkJSON)
            case "/donor/me/sharing": return (.ok, sharingJSON())
            case "/donor/me/conversions": return (.ok, conversionsJSON())
            default: return (.notFound, "{}")
            }
        }
        let snapshot = try await make(transport).service.snapshot()
        XCTAssertNil(snapshot.impact)
        XCTAssertEqual(snapshot.ranking?.isOptedOut, true)
        XCTAssertNil(snapshot.referral?.linkCount, "counts are unknown while the dashboard is preparing")
    }

    func testAFailedSectionIsNilWhileTheOthersStay() async throws {
        for (label, transport) in [
            ("badges", engagementTransport(badges: (.serviceUnavailable, "{}"))),
            ("network", engagementTransport(network: (.internalServerError, "{}"))),
            ("dashboard", engagementTransport(dashboard: (.tooManyRequests, ""))),
            ("sharing", engagementTransport(sharing: (.serviceUnavailable, "{}"))),
        ] {
            let snapshot = try await make(transport).service.snapshot()
            switch label {
            case "badges": XCTAssertNil(snapshot.badges); XCTAssertNotNil(snapshot.network)
            case "network": XCTAssertNil(snapshot.network); XCTAssertNotNil(snapshot.badges)
            case "dashboard": XCTAssertNil(snapshot.impact); XCTAssertNil(snapshot.ranking); XCTAssertNotNil(snapshot.badges)
            default: XCTAssertNil(snapshot.referral); XCTAssertFalse(snapshot.needsPublicName, "a failed read is not \"no name\""); XCTAssertNotNil(snapshot.badges)
            }
        }
    }

    func testAFailedConversionsReadKeepsTheCodeWithConversionsUnknown() async throws {
        let snapshot = try await make(engagementTransport(conversions: (.tooManyRequests, ""))).service.snapshot()
        XCTAssertEqual(snapshot.referral?.code, "ALEX42")
        XCTAssertNil(snapshot.referral?.conversions)
    }

    func testEverySectionFailingThrowsTheFirstError() async throws {
        for (status, body, expected) in [(HTTPResponse.Status.tooManyRequests, "", AccountError.rateLimited),
                                         (.serviceUnavailable, "{}", .unavailable), (.internalServerError, "{}", .unavailable)] {
            let all = engagementTransport(dashboard: (status, body), badges: (status, body), network: (status, body), sharing: (status, body))
            let rig = try make(all)
            await assertThrows(expected, "\(status)") { _ = try await rig.service.snapshot() }
            XCTAssertNotNil(try rig.store.load(), "\(status) must not end the session")
        }
    }

    func testASecondUnauthorizedEndsTheSessionAndThrowsSignedOut() async throws {
        let rig = try make(ScriptedTransport { seen, _ in seen.request.path == "/donor/refresh" ? (.unauthorized, "{}") : (.unauthorized, "{}") })
        await assertThrows(.signedOut) { _ = try await rig.service.snapshot() }
        XCTAssertNil(try rig.store.load())
    }

    func testOneSectionUnauthorizedThenRefreshedSucceeds() async throws {
        let transport = ScriptedTransport { seen, _ in
            let fresh = seen.request.headerFields[.authorization] == "Bearer fresh"
            switch seen.request.path {
            case "/donor/refresh": return (.ok, freshSessionJSON)
            case "/donor/me/badges": return fresh ? (.ok, badgesJSON(badgeRow())) : (.unauthorized, "{}")
            case "/donor/me/dashboard": return (.ok, dashboardJSON())
            case "/donor/me/network": return (.ok, networkJSON)
            case "/donor/me/sharing": return (.ok, sharingJSON())
            case "/donor/me/conversions": return (.ok, conversionsJSON())
            default: return (.notFound, "{}")
            }
        }
        let snapshot = try await make(transport).service.snapshot()
        XCTAssertEqual(snapshot.badges?.total, 1)
    }

    func testNoPublicNameMeansNeedsPublicNameNotAnInvite() async throws {
        for sharing in [sharingJSON(name: nil, link: nil), sharingJSON(name: "", link: nil), sharingJSON(name: "Alex", link: nil)] {
            let snapshot = try await make(engagementTransport(sharing: (.ok, sharing))).service.snapshot()
            XCTAssertNil(snapshot.referral)
            XCTAssertTrue(snapshot.needsPublicName, sharing)
        }
    }

    func testUnusableReferralCodesAreNeitherAnInviteNorANamePrompt() async throws {
        for code in [nil, "", "AL EX", "A/B", String(repeating: "A", count: 65)] as [String?] {
            let snapshot = try await make(engagementTransport(sharing: (.ok, sharingJSON(code: code)))).service.snapshot()
            XCTAssertNil(snapshot.referral, code ?? "nil")
            XCTAssertFalse(snapshot.needsPublicName, code ?? "nil")
        }
    }

    func testInviteURLsComeFromTheConfiguredPublicOriginNotTheServerLink() async throws {
        let snapshot = try await make(engagementTransport(sharing: (.ok, sharingJSON(link: "https://evil.example/r/ALEX42")))).service.snapshot()
        XCTAssertEqual(snapshot.referral?.inviteURL(host: "https://dollaraday.org")?.absoluteString, "https://dollaraday.org/r/ALEX42")
        XCTAssertEqual(snapshot.referral?.irlURL(host: "https://dollaraday.org")?.absoluteString, "https://dollaraday.org/r/ALEX42?via=irl")
        XCTAssertNil(snapshot.referral?.inviteURL(host: nil), "no configured origin means no link, never an invented one")
    }

    func testSnapshotCancellationPropagatesAndKeepsTheSession() async throws {
        let gate = Gate()
        let rig = try make(ScriptedTransport { seen, _ in
            await gate.pass()
            try Task.checkCancellation()
            return (.ok, seen.request.path == "/donor/me/dashboard" ? dashboardJSON() : badgesJSON(badgeRow()))
        })
        let service = rig.service
        let task = Task { try await service.snapshot() }
        await gate.waitUntilEntered()
        task.cancel()
        await gate.release()
        do { _ = try await task.value; XCTFail() } catch { XCTAssertTrue(error.isCancellation, "\(error)") }
        XCTAssertNotNil(try rig.store.load())
    }

    // MARK: badges

    func testBadgesMapEarnedLockedPerksAndUnknownPerkKeys() async throws {
        let json = badgesJSON(
            badgeRow("F"), badgeRow("7", title: "One Week", perk: "", earned: true), badgeRow("1K", title: "1,000 Days", perk: "MILESTONE_EVENTS", earned: false),
            badgeRow("TC", title: "Team Captain", perk: "TEAM_CAPTAIN", earned: true), badgeRow("NEW", title: "Future", perk: "SOME_FUTURE_PERK", earned: true))
        let collection = try await make(engagementTransport(badges: (.ok, json))).service.badges()
        XCTAssertEqual(collection.summaryLabel, "4 of 5 earned")
        let byCode = Dictionary(uniqueKeysWithValues: collection.badges.map { ($0.code, $0) })
        XCTAssertFalse(byCode["7"]!.hasPerk)
        XCTAssertEqual(byCode["1K"]?.perk, "Invite-only milestone events")
        XCTAssertEqual(byCode["1K"]?.earned, false)
        XCTAssertTrue(byCode["TC"]!.perk.contains("48-hour early event booking"))
        XCTAssertEqual(byCode["NEW"]?.perk, "Unlocks a member perk", "an unknown perk key still says there is a perk")
        // Perk gating follows the server catalog codes: an unknown future badge never opens invite-only events.
        XCTAssertTrue(byCode["F"]!.unlocksInviteOnlyEvents)
        XCTAssertTrue(byCode["TC"]!.unlocksInviteOnlyEvents)
        XCTAssertFalse(byCode["1K"]!.unlocksInviteOnlyEvents, "locked")
        XCTAssertFalse(byCode["NEW"]!.unlocksInviteOnlyEvents)
        XCTAssertEqual(byCode["F"]?.earnedAt, ISO8601DateFormatter().date(from: "2026-09-02T10:00:00Z"))
    }

    func testBadgesSkipRowsWithoutACodeOrTitleAndCapTheList() async throws {
        let many = (0..<80).map { badgeRow("B\($0)", title: "Badge \($0)", perk: "", earned: false) }
        let json = #"{"badges":[\#(([badgeRow("", title: "No code"), badgeRow("X", title: "")] + many).joined(separator: ","))]}"#
        let collection = try await make(engagementTransport(badges: (.ok, json))).service.badges()
        XCTAssertEqual(collection.total, WireEngagement.badgeLimit)
        XCTAssertFalse(collection.badges.contains { $0.title.isEmpty || $0.code.isEmpty })
    }

    func testBadgesStatusMapping() async throws {
        for (status, body, expected) in [(HTTPResponse.Status.tooManyRequests, "", AccountError.rateLimited), (.tooManyRequests, "{}", .rateLimited),
                                         (.serviceUnavailable, "{}", .unavailable), (.internalServerError, "{}", .unavailable), (.forbidden, "{}", .forbidden),
                                         (.notFound, "{}", .notFound)] {
            let rig = try make(engagementTransport(badges: (status, body)))
            await assertThrows(expected, "\(status)") { _ = try await rig.service.badges() }
            XCTAssertNotNil(try rig.store.load(), "\(status) must not end the session")
        }
    }

    func testMalformedAndOversizeBodiesThrow() async throws {
        let padding = String(repeating: "a", count: 1_100_000)
        for body in [#"{"badges":[{"code":"F"}]}"#, "<html>", #"{"badges":"nope"}"#, #"{"badges":[],"pad":""# + padding + #""}"#] {
            let rig = try make(engagementTransport(badges: (.ok, body)))
            do { _ = try await rig.service.badges(); XCTFail(String(body.prefix(40))) } catch { assertBodyRejected(error) }
        }
        for body in [#"{"active_count":"x"}"#, "{}", #"{"active_count":1,"annualized_minor":1,"next_milestone":null,"invitees":[{"name":"A"}],"anonymous_active":0}"#] {
            let rig = try make(engagementTransport(network: (.ok, body)))
            do { _ = try await rig.service.network(); XCTFail(body) } catch { assertBodyRejected(error) }
        }
    }

    // MARK: network

    func testNetworkMapsAndCapsInvitees() async throws {
        let rig = try make(engagementTransport(network: (.ok, networkJSON.replacingOccurrences(of: #""next_milestone":{"label":"Team Captain","target":20,"remaining":17}"#, with: #""next_milestone":null"#))))
        let network = try await rig.service.network()
        XCTAssertNil(network.nextMilestone, "null once every tier is reached")
        XCTAssertEqual(network.annualizedLabel, "$4,745/yr")
        let rows = (0..<260).map { #"{"name":"P \#($0)","active":true}"# }.joined(separator: ",")
        let big = #"{"active_count":260,"annualized_minor":1,"next_milestone":null,"invitees":[\#(rows)],"anonymous_active":0}"#
        let capped = try await make(engagementTransport(network: (.ok, big))).service.network()
        XCTAssertEqual(capped.invitees.count, WireEngagement.inviteeLimit)
    }

    func testNetworkStatusMapping() async throws {
        for (status, body, expected) in [(HTTPResponse.Status.tooManyRequests, "", AccountError.rateLimited), (.serviceUnavailable, "{}", .unavailable),
                                         (.notFound, "{}", .notFound)] {
            let rig = try make(engagementTransport(network: (status, body)))
            await assertThrows(expected, "\(status)") { _ = try await rig.service.network() }
        }
    }

    // MARK: conversions

    func testConversionsTolerateUnknownKindsAndFractionalSeconds() async throws {
        let snapshot = try await make(engagementTransport(conversions: (.ok, conversionsJSON(kind: "SMS", more: true)))).service.snapshot()
        XCTAssertEqual(snapshot.referral?.conversions?.map(\.kind), [.other, .irl], "an unknown channel does not fail the list")
        XCTAssertEqual(snapshot.referral?.hasMoreConversions, true)
        XCTAssertEqual(snapshot.referral?.conversions?.count, 2)
    }

    // MARK: rankings choice (K-2)

    private func rankingsTransport(saveStatus: @escaping @Sendable (Int) -> (HTTPResponse.Status, String) = { _ in (.ok, profileJSON(version: 4)) },
                                   dashboard: (HTTPResponse.Status, String) = (.ok, dashboardJSON())) -> ScriptedTransport {
        ScriptedTransport { seen, index in
            switch (seen.request.method, seen.request.path) {
            case (.get, "/donor/me/profile"): return (.ok, profileJSON(version: 3 + index))
            case (.post, "/donor/me/preferences"): return saveStatus(index)
            case (.get, "/donor/me/dashboard"): return dashboard
            case (.post, "/donor/refresh"): return (.ok, freshSessionJSON)
            default: return (.notFound, "{}")
            }
        }
    }

    func testOptingOutReadsTheProfileThenSavesTheFullBlockWithItsVersion() async throws {
        let transport = rankingsTransport()
        let standing = try await make(transport).service.setRankingOptIn(false)
        XCTAssertEqual(standing, RankingStanding(nationalPercentile: nil, city: nil, cityRank: nil, rankingsOptedOut: true))
        let save = try XCTUnwrap(transport.calls(to: "/donor/me/preferences").first)
        let body = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(save.body.utf8)) as? [String: Any])
        XCTAssertEqual(body["rankings_opted_out"] as? Bool, true)
        XCTAssertEqual(body["version"] as? Int, 3, "the version of the profile just read")
        XCTAssertEqual(body["network_visible"] as? Bool, true, "every other choice is carried unchanged")
        XCTAssertEqual(body["push_streak_lapsed"] as? Bool, true)
        XCTAssertTrue(transport.calls(to: "/donor/me/dashboard").isEmpty, "no position is read for an opt-out")
    }

    func testOptingBackInReturnsTheServersPosition() async throws {
        let transport = rankingsTransport()
        let standing = try await make(transport).service.setRankingOptIn(true)
        XCTAssertEqual(standing, RankingStanding(nationalPercentile: 2, city: "Austin", cityRank: 4))
        let body = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(try XCTUnwrap(transport.calls(to: "/donor/me/preferences").first).body.utf8)) as? [String: Any])
        XCTAssertEqual(body["rankings_opted_out"] as? Bool, false)
    }

    func testOptingBackInSurvivesAFailedPositionRead() async throws {
        let standing = try await make(rankingsTransport(dashboard: (.serviceUnavailable, "{}"))).service.setRankingOptIn(true)
        XCTAssertEqual(standing, RankingStanding(nationalPercentile: nil, city: nil, cityRank: nil), "opted in, position not known yet")
        XCTAssertFalse(standing.isOptedOut)
    }

    func testAStaleVersionIsReReadAndRetriedOnce() async throws {
        let transport = rankingsTransport(saveStatus: { index in index < 3 ? (.conflict, "{}") : (.ok, profileJSON(version: 9)) })
        _ = try await make(transport).service.setRankingOptIn(false)
        XCTAssertEqual(transport.calls(to: "/donor/me/profile").count, 2)
        XCTAssertEqual(transport.calls(to: "/donor/me/preferences").count, 2)
    }

    func testAPersistentConflictIsReportedNotLooped() async throws {
        let transport = rankingsTransport(saveStatus: { _ in (.conflict, "{}") })
        let rig = try make(transport)
        await assertThrows(.conflict) { _ = try await rig.service.setRankingOptIn(false) }
        XCTAssertEqual(transport.calls(to: "/donor/me/preferences").count, 2, "one retry, then give up")
    }

    func testRankingsChoiceStatusMapping() async throws {
        for (status, body, expected) in [(HTTPResponse.Status.tooManyRequests, "", AccountError.rateLimited), (.tooManyRequests, "{}", .rateLimited),
                                         (.serviceUnavailable, "{}", .unavailable), (.unprocessableContent, "{}", .invalidInput)] {
            let rig = try make(rankingsTransport(saveStatus: { _ in (status, body) }))
            await assertThrows(expected, "\(status)") { _ = try await rig.service.setRankingOptIn(false) }
            XCTAssertNotNil(try rig.store.load())
        }
    }

    func testRankingsChoiceRefreshesOnceOn401() async throws {
        let transport = ScriptedTransport { seen, _ in
            switch seen.request.path {
            case "/donor/refresh": return (.ok, freshSessionJSON)
            case "/donor/me/profile": return (.ok, profileJSON())
            case "/donor/me/preferences": return seen.request.headerFields[.authorization] == "Bearer fresh" ? (.ok, profileJSON(version: 4)) : (.unauthorized, "{}")
            default: return (.notFound, "{}")
            }
        }
        _ = try await make(transport).service.setRankingOptIn(false)
        XCTAssertEqual(transport.calls(to: "/donor/refresh").count, 1)
    }

    func testRankingsChoiceCancellationPropagates() async throws {
        let gate = Gate()
        let rig = try make(ScriptedTransport { _, _ in
            await gate.pass()
            try Task.checkCancellation()
            return (.ok, profileJSON())
        })
        let service = rig.service
        let task = Task { try await service.setRankingOptIn(false) }
        await gate.waitUntilEntered()
        task.cancel()
        await gate.release()
        do { _ = try await task.value; XCTFail() } catch { XCTAssertTrue(error.isCancellation, "\(error)") }
        XCTAssertNotNil(try rig.store.load())
    }

    // MARK: public name (R-1)

    func testChoosingAPublicNamePostsTheTrimmedNameWithoutReplacingTheCode() async throws {
        let transport = ScriptedTransport { _, _ in (.ok, sharingJSON()) }
        try await make(transport).service.choosePublicName("  Alex R  ")
        let call = try XCTUnwrap(transport.seen.first)
        XCTAssertEqual(call.request.method, .post)
        XCTAssertEqual(call.request.path, "/donor/me/sharing")
        let body = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(call.body.utf8)) as? [String: Any])
        XCTAssertEqual(body["public_name"] as? String, "Alex R")
        XCTAssertEqual(body["replace_code"] as? Bool, false)
    }

    func testPublicNameIsValidatedBeforeTheNetwork() async throws {
        let transport = ScriptedTransport { _, _ in (.ok, sharingJSON()) }
        let rig = try make(transport)
        for name in ["", "   ", String(repeating: "a", count: 81)] {
            await assertThrows(.invalidInput, name) { try await rig.service.choosePublicName(name) }
        }
        XCTAssertTrue(transport.seen.isEmpty)
    }

    func testPublicNameStatusMapping() async throws {
        for (status, body, expected) in [(HTTPResponse.Status.forbidden, "{}", AccountError.forbidden), (.unprocessableContent, "{}", .invalidInput),
                                         (.tooManyRequests, "", .rateLimited), (.tooManyRequests, "{}", .rateLimited), (.serviceUnavailable, "{}", .unavailable),
                                         (.contentTooLarge, "{}", .unavailable)] {
            let rig = try make(ScriptedTransport { _, _ in (status, body) })
            await assertThrows(expected, "\(status)") { try await rig.service.choosePublicName("Alex") }
            XCTAssertNotNil(try rig.store.load())
        }
    }

    // MARK: initiative spend (A-3)

    func testInitiativeSpendMapsTotalsAndCategories() async throws {
        let transport = ScriptedTransport { _, _ in (.ok, spendJSON) }
        let spend = try await make(transport).service.initiativeSpend(id: initiativeID)
        XCTAssertEqual(spend, InitiativeSpendSummary(initiativeID: initiativeID, totalMinor: 125000, slices: [
            SpendSlice(category: "Food", amountMinor: 90000), SpendSlice(category: "Delivery", amountMinor: 35000)]))
        XCTAssertEqual(spend.totalLabel, "$1,250")
        XCTAssertEqual(transport.seen.first?.request.path, "/initiatives/\(initiativeID)/spend")
    }

    func testInitiativeSpendRefusesAMalformedIDAndABadTotal() async throws {
        let transport = ScriptedTransport { _, _ in (.ok, spendJSON.replacingOccurrences(of: "125000", with: "-5")) }
        let rig = try make(transport)
        await assertThrows(.invalidInput) { _ = try await rig.service.initiativeSpend(id: "../../etc") }
        XCTAssertTrue(transport.seen.isEmpty)
        await assertThrows(.invalidResponse, "a negative total is not a spend") { _ = try await rig.service.initiativeSpend(id: initiativeID) }
    }

    func testInitiativeSpendStatusMapping() async throws {
        for (status, body, expected) in [(HTTPResponse.Status.notFound, "{}", AccountError.notFound), (.tooManyRequests, "", .rateLimited),
                                         (.serviceUnavailable, "{}", .unavailable), (.internalServerError, "{}", .unavailable)] {
            let rig = try make(ScriptedTransport { _, _ in (status, body) })
            await assertThrows(expected, "\(status)") { _ = try await rig.service.initiativeSpend(id: initiativeID) }
            XCTAssertNotNil(try rig.store.load())
        }
        for body in ["<html>", #"{"initiative_id":"x"}"#, "{}"] {
            let rig = try make(ScriptedTransport { _, _ in (.ok, body) })
            do { _ = try await rig.service.initiativeSpend(id: initiativeID); XCTFail(body) } catch { assertBodyRejected(error) }
        }
    }

    func testInitiativeSpendCancellationPropagates() async throws {
        let gate = Gate()
        let rig = try make(ScriptedTransport { _, _ in
            await gate.pass()
            try Task.checkCancellation()
            return (.ok, spendJSON)
        })
        let service = rig.service
        let task = Task { try await service.initiativeSpend(id: initiativeID) }
        await gate.waitUntilEntered()
        task.cancel()
        await gate.release()
        do { _ = try await task.value; XCTFail() } catch { XCTAssertTrue(error.isCancellation, "\(error)") }
    }
}
