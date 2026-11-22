import Foundation
import HTTPTypes
import OpenAPIRuntime
import XCTest
@testable import DADFoundation

/// Records every request and answers from a per-call script, so a conformer's wire behaviour
/// (path, headers, body, status mapping) is asserted without a network.
final class ScriptedTransport: ClientTransport, @unchecked Sendable {
    struct Seen { let request: HTTPRequest; let body: String }
    typealias Reply = (status: HTTPResponse.Status, json: String)
    private let lock = NSLock()
    private var log: [Seen] = []
    private let script: @Sendable (Seen, Int) async throws -> Reply
    init(_ script: @escaping @Sendable (Seen, Int) async throws -> Reply) { self.script = script }
    var seen: [Seen] { lock.withLock { log } }
    func calls(to path: String) -> [Seen] { seen.filter { $0.request.path == path } }
    func send(_ request: HTTPRequest, body: HTTPBody?, baseURL: URL, operationID: String) async throws -> (HTTPResponse, HTTPBody?) {
        var text = ""
        if let body { text = try await String(collecting: body, upTo: 8192) }
        let entry = Seen(request: request, body: text)
        let index = lock.withLock { log.append(entry); return log.count - 1 }
        let reply = try await script(entry, index)
        // Every non-2xx body is the contract's Problem object, which requires `detail`.
        let json = reply.status.code >= 400 && reply.json == "{}" ? #"{"detail":"scripted"}"# : reply.json
        // A successful `.ics` read and a Wallet pass are the non-JSON bodies the product API serves.
        let type = reply.status.code >= 300 ? "application/json"
            : request.path?.hasSuffix("/calendar.ics") == true ? "text/calendar"
            : request.path?.hasSuffix("/report.pdf") == true ? "application/pdf"
            : request.path == "/donor/me/wallet/apple" ? "application/vnd.apple.pkpass" : "application/json"
        return (HTTPResponse(status: reply.status, headerFields: [.contentType: type]), HTTPBody(json))
    }
}

let testOrigin = URL(string: "https://api.test")!
let nativeSessionJSON = #"{"access_token":"A1","expires_in":900,"refresh_token":"R1","refresh_expires_in":5184000}"#
let freshSessionJSON = #"{"access_token":"fresh","expires_in":900,"refresh_token":"fresh-r","refresh_expires_in":1}"#
let nativeClientHeader = HTTPField.Name("X-DAD-Client")!

func profileJSON(version: Int = 3) -> String {
    #"{"email":"alex@example.org","public_name":"Alex","account_role":"DONOR","zip":"78701","city":"Austin","timezone":null,"phone":null,"referral_emails":true,"marketing_emails":false,"push_referral_converted":true,"push_streak_at_risk":true,"push_streak_milestone":true,"push_streak_lapsed":true,"push_badge_earned":true,"push_gift_processed":true,"push_event_nearby":false,"push_event_reminder":true,"push_event_promoted":false,"rankings_opted_out":false,"network_visible":true,"volunteer":true,"volunteer_interests":[],"version":\#(version),"consent_version":"v1"}"#
}

/// Polls until `condition` holds; fails the test instead of hanging when it never does.
@MainActor
func waitUntil(timeout: Duration = .seconds(5), file: StaticString = #filePath, line: UInt = #line,
               _ condition: @MainActor () -> Bool) async {
    let deadline = ContinuousClock.now + timeout
    while !condition() {
        if ContinuousClock.now >= deadline { XCTFail("condition not met within \(timeout)", file: file, line: line); return }
        await Task.yield()
    }
}

/// Polls an async condition every 10 ms and fails the test if it does not hold within `timeout`.
@MainActor func eventually(timeout: Duration = .seconds(5), file: StaticString = #filePath, line: UInt = #line,
                _ condition: @MainActor () async -> Bool) async {
    let deadline = ContinuousClock.now + timeout
    while await !condition() {
        if ContinuousClock.now >= deadline { XCTFail("condition not met within \(timeout)", file: file, line: line); return }
        try? await Task.sleep(for: .milliseconds(10))
    }
}

/// Latch the test opens to release a gated transport/call; also signals when the call arrived.
actor Gate {
    private var open = false
    private var waiters: [CheckedContinuation<Void, Never>] = []
    private var entered: [CheckedContinuation<Void, Never>] = []
    private var didEnter = false
    func pass() async {
        didEnter = true; entered.forEach { $0.resume() }; entered = []
        if open { return }
        await withCheckedContinuation { waiters.append($0) }
    }
    func waitUntilEntered() async { if didEnter { return }; await withCheckedContinuation { entered.append($0) } }
    func release() { open = true; waiters.forEach { $0.resume() }; waiters = [] }
}

/// Lets `task` reach its gated call, cancels it, and asserts the cancellation surfaces as such.
func assertCancels<T: Sendable>(_ task: Task<T, Error>, at gate: Gate, file: StaticString = #filePath, line: UInt = #line) async {
    await gate.waitUntilEntered()
    task.cancel()
    await gate.release()
    do { _ = try await task.value; XCTFail("expected cancellation", file: file, line: line) }
    catch { XCTAssertTrue(error.isCancellation, "\(error)", file: file, line: line) }
}

final class WipeBox: @unchecked Sendable {
    private let lock = NSLock()
    private var hits = 0
    func hit() { lock.withLock { hits += 1 } }
    var count: Int { lock.withLock { hits } }
}

/// A 2xx body the client cannot accept (undecodable, wrong shape, over the 1 MiB bound) must surface as the
/// runtime's `ClientError` or `invalidResponse`: never as a session end, a cancellation, or a throttle.
func assertBodyRejected(_ error: Error, file: StaticString = #filePath, line: UInt = #line) {
    XCTAssertTrue(error is ClientError || (error as? AccountError) == .invalidResponse, "\(error)", file: file, line: line)
}

final class LockedBox<Value: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Value
    init(_ value: Value) { self.value = value }
    func set(_ new: Value) { lock.withLock { value = new } }
    func get() -> Value { lock.withLock { value } }
}

final class KeptReferral: @unchecked Sendable {
    private let lock = NSLock()
    private var token: String?
    init(_ token: String?) { self.token = token }
    var value: String? {
        get { lock.withLock { token } }
        set { lock.withLock { token = newValue } }
    }
}

func dashboardReadyJSON(streak: String? = nil, rank: String = "null", optedOut: Bool = false, network: String? = nil,
                        referrals: String? = nil, given: String = "124000", insights: String? = nil) -> String {
    let streakJSON = streak ?? #"{"at_risk":false,"current":18,"grace_ends_at":null,"ladder":{"days":18,"last_milestone":7,"next_milestone":30,"days_to_next":12,"bar":[true,true,true,false]}}"#
    let networkJSON = network ?? #"{"active_count":3,"annualized_minor":474500,"currency":"USD"}"#
    let referralsJSON = referrals ?? #"{"currency":"USD","irl":1,"irl_minor":3000,"link":2,"link_minor":9000,"total_minor":12000}"#
    return #"{"state":"ready","mode":"test","computed_at":"2026-10-30T12:00:00Z","founding_donor":true,"referrals":\#(referralsJSON),"streak":\#(streakJSON),"rank":\#(rank),"rankings_opted_out":\#(optedOut),"network":\#(networkJSON),"impact":{"given_minor":\#(given),"currency":"USD","initiatives_funded":4,"events_volunteered":2}\#(insights.map { #","insights":\#($0)"# } ?? "")}"#
}
