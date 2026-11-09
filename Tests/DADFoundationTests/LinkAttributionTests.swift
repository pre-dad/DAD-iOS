import Foundation
import HTTPTypes
import XCTest
@testable import DADFoundation

final class KeptReferral: @unchecked Sendable {
    private let lock = NSLock()
    private var token: String?
    init(_ token: String?) { self.token = token }
    var value: String? {
        get { lock.withLock { token } }
        set { lock.withLock { token = newValue } }
    }
}

private final class MemoryLinkTokens: LinkTokenStore, @unchecked Sendable {
    private let lock = NSLock()
    private var tokens: LinkTokens
    init(_ tokens: LinkTokens = LinkTokens()) { self.tokens = tokens }
    func load() -> LinkTokens { lock.withLock { tokens } }
    func save(_ tokens: LinkTokens) { lock.withLock { self.tokens = tokens } }
}

private final class Sources: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [String] = []
    func add(_ value: String) { lock.withLock { values.append(value) } }
    var all: [String] { lock.withLock { values } }
}

final class LinkAttributionTests: XCTestCase {
    private let kept = String(repeating: "k", count: 43)
    private let fresh = String(repeating: "f", count: 43)

    private func make(_ transport: ScriptedTransport, tokens: LinkTokens = LinkTokens()) throws -> (LinkAttribution, MemoryLinkTokens, Sources) {
        let store = MemoryStore(Credentials(access: "tok", refresh: "ref", expiresAt: .distantFuture))
        let session = try AccountSession(api: WireAPI(origin: testOrigin, transport: transport), store: store)
        let links = MemoryLinkTokens(tokens)
        let sources = Sources()
        let service = WireLinkAttribution(product: ProductClient(origin: testOrigin, transport: transport, session: session))
        return (LinkAttribution(service: service, store: links, captured: { sources.add($0) }), links, sources)
    }

    private func body(_ seen: ScriptedTransport.Seen) throws -> [String: Any] {
        try XCTUnwrap(JSONSerialization.jsonObject(with: Data(seen.body.utf8)) as? [String: Any])
    }

    func testReferralCaptureSendsTheKeptTokenAnonymouslyAndKeepsTheNewOne() async throws {
        let fresh = fresh
        let transport = ScriptedTransport { _, _ in (.ok, #"{"captured":true,"public_name":"Alex R","token":"\#(fresh)"}"#) }
        let (attribution, links, sources) = try make(transport, tokens: LinkTokens(referral: kept))
        let name = await attribution.captureReferral(code: "ALEX42", inPerson: true)
        XCTAssertEqual(name, "Alex R")
        XCTAssertEqual(links.load().referral, fresh)
        XCTAssertEqual(attribution.referralToken, fresh)
        XCTAssertEqual(sources.all, ["IRL"])
        let call = try XCTUnwrap(transport.seen.first)
        XCTAssertEqual(call.request.path, "/donor/referrals/ALEX42")
        XCTAssertNil(call.request.headerFields[.authorization], "a link visit is anonymous")
        XCTAssertEqual(call.request.headerFields[nativeClientHeader], "native")
        let sent = try body(call)
        XCTAssertEqual(sent["kind"] as? String, "IRL")
        XCTAssertEqual(sent["token"] as? String, kept)
    }

    func testLaterReferralReplacesTheTokenWithoutLosingTheCompanyTouch() async throws {
        let first = String(repeating: "a", count: 43)
        let second = String(repeating: "b", count: 43)
        let company = String(repeating: "c", count: 43)
        let transport = ScriptedTransport { seen, _ in
            let token = seen.request.path == "/donor/company/ACME" ? company :
                seen.request.path == "/donor/referrals/FIRST" ? first : second
            if seen.request.path == "/donor/company/ACME" {
                return (.ok, "{\"captured\":true,\"token\":\"\(token)\"}")
            }
            return (.ok, "{\"captured\":true,\"public_name\":null,\"token\":\"\(token)\"}")
        }
        let (attribution, links, sources) = try make(transport)
        await attribution.captureReferral(code: "FIRST", inPerson: false)
        await attribution.captureCompany(code: "ACME")
        await attribution.captureReferral(code: "SECOND", inPerson: true)

        XCTAssertEqual(links.load(), LinkTokens(referral: second, company: company))
        XCTAssertEqual(sources.all, ["link", "company", "IRL"])
        XCTAssertEqual(transport.seen.count, 3)
        XCTAssertNil(try body(transport.seen[0])["token"])
        XCTAssertEqual(try body(transport.seen[2])["token"] as? String, first)
        XCTAssertEqual(try body(transport.seen[2])["kind"] as? String, "IRL")
    }

    func testACaptureThatKeepsNothingDiscardsTheTokenAndAFailureKeepsIt() async throws {
        let nothing = ScriptedTransport { _, _ in (.ok, #"{"captured":false,"public_name":null,"token":null}"#) }
        let (cleared, links, sources) = try make(nothing, tokens: LinkTokens(referral: kept, company: kept))
        await cleared.captureReferral(code: "gone", inPerson: false)
        XCTAssertEqual(links.load(), LinkTokens(referral: nil, company: kept))
        XCTAssertEqual(try body(XCTUnwrap(nothing.seen.first))["token"] as? String, kept)
        XCTAssertEqual(sources.all, [])

        let down = ScriptedTransport { _, _ in (.serviceUnavailable, "{}") }
        let (failing, kept, _) = try make(down, tokens: LinkTokens(referral: kept, company: kept))
        await failing.captureReferral(code: "ALEX42", inPerson: false)
        await failing.captureCompany(code: "ACME42")
        XCTAssertEqual(kept.load(), LinkTokens(referral: self.kept, company: self.kept))
    }

    func testCompanyTokenIsCapturedThenBoundOnceSignedIn() async throws {
        let fresh = fresh
        let transport = ScriptedTransport { seen, _ in
            seen.request.path == "/donor/me/company-touch" ? (.ok, #"{"bound":true}"#) : (.ok, #"{"captured":true,"token":"\#(fresh)"}"#)
        }
        let (attribution, links, sources) = try make(transport)
        await attribution.captureCompany(code: "ACME42")
        XCTAssertEqual(links.load().company, fresh)
        XCTAssertEqual(sources.all, ["company"])
        XCTAssertNil(try body(transport.seen[0])["token"] as? String)
        await attribution.bindCompany()
        let bind = transport.seen[1]
        XCTAssertEqual(bind.request.path, "/donor/me/company-touch")
        XCTAssertEqual(bind.request.headerFields[.authorization], "Bearer tok")
        XCTAssertEqual(try body(bind)["token"] as? String, fresh)
        XCTAssertNil(links.load().company, "a bound token is spent")
        await attribution.bindCompany()
        XCTAssertEqual(transport.seen.count, 2, "nothing left to bind")
    }

    func testATransientBindFailureKeepsTheCompanyTokenForLater() async throws {
        let transport = ScriptedTransport { _, _ in (.serviceUnavailable, "{}") }
        let (attribution, links, _) = try make(transport, tokens: LinkTokens(company: kept))
        await attribution.bindCompany()
        XCTAssertEqual(links.load().company, kept)
        let refused = ScriptedTransport { _, _ in (.unprocessableContent, "{}") }
        let (spent, spentLinks, _) = try make(refused, tokens: LinkTokens(company: kept))
        await spent.bindCompany()
        XCTAssertNil(spentLinks.load().company, "a token the server refuses is not retried forever")
    }

    func testDefaultsStoreRoundTripsAndForgetsAnEmptyRecord() {
        let defaults = UserDefaults(suiteName: "link-tokens-\(UUID())")!
        let store = DefaultsLinkTokenStore(defaults: defaults, key: "t")
        XCTAssertEqual(store.load(), LinkTokens())
        store.save(LinkTokens(referral: kept))
        XCTAssertEqual(DefaultsLinkTokenStore(defaults: defaults, key: "t").load(), LinkTokens(referral: kept))
        store.save(LinkTokens())
        XCTAssertNil(defaults.data(forKey: "t"))
    }
}
