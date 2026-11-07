import Foundation
import HTTPTypes
import Observation
import OpenAPIRuntime

/// The donor's analytics choice: nil until asked. Opt-in, as on the website: nothing is recorded until it is true.
public protocol AnalyticsConsent: AnyObject, Sendable {
    var choice: Bool? { get set }
}

public final class DefaultsAnalyticsConsent: AnalyticsConsent {
    // UserDefaults is thread-safe per Apple's docs but predates Sendable.
    private nonisolated(unsafe) let defaults: UserDefaults
    private let key: String
    public init(defaults: UserDefaults = .standard, key: String = "org.dad.analytics.consent") {
        self.defaults = defaults
        self.key = key
    }
    public var choice: Bool? {
        get { defaults.object(forKey: key) == nil ? nil : defaults.bool(forKey: key) }
        set { if let newValue { defaults.set(newValue, forKey: key) } else { defaults.removeObject(forKey: key) } }
    }
}

public final class MemoryAnalyticsConsent: AnalyticsConsent, @unchecked Sendable {
    private let lock = NSLock()
    private var value: Bool?
    public init(choice: Bool? = nil) { value = choice }
    public var choice: Bool? {
        get { lock.withLock { value } }
        set { lock.withLock { value = newValue } }
    }
}

/// The app's analytics: records nothing until the donor allows it, then buffers events in the recorder and uploads
/// them in the background (a failed upload is retried with the next event once its backoff has passed). Declining drops anything still buffered.
/// One journey id per launch groups a visit, like the website's per-tab journey.
@MainActor
@Observable
public final class AnalyticsController {
    public private(set) var choice: Bool?
    @ObservationIgnored private let consent: any AnalyticsConsent
    @ObservationIgnored private let recorder: AnalyticsRecorder
    @ObservationIgnored private let journey = UUID()

    public init(consent: any AnalyticsConsent, sink: any AnalyticsSink) {
        self.consent = consent
        self.recorder = AnalyticsRecorder(sink: sink)
        choice = consent.choice
    }

    public func choose(_ allowed: Bool) {
        consent.choice = allowed
        choice = allowed
        if allowed {
            emit(.appOpened)
        } else {
            let recorder = recorder
            Task { await recorder.discardPending() }
        }
    }

    /// Fire-and-forget from any context; an event the schema would reject is never recorded.
    public nonisolated func emit(_ event: AnalyticsEvent, properties: [String: String] = [:]) {
        guard consent.choice == true,
              let record = try? AnalyticsRecord(event, properties: properties, journeyID: journey) else { return }
        let recorder = recorder
        Task {
            await recorder.record(record)
            try? await recorder.flushWhenDue()
        }
    }

    /// Waits for the buffer to drain or fail; for tests.
    public func flush() async throws { try await recorder.flush() }
    public var pending: Int { get async { await recorder.pending } }
}

/// `POST /analytics/events`, attributed to the donor when `access` yields a session token and anonymous otherwise.
public struct WireAnalytics: AnalyticsSink {
    private let origin: URL
    private let transport: any ClientTransport
    private let access: @Sendable () async -> String?

    public init(origin: URL, access: @escaping @Sendable () async -> String?) throws {
        guard origin.isBareHTTPSOrigin else { throw AccountError.invalidConfiguration }
        self.init(origin: origin, transport: makeNativeTransport(observed: false), access: access)
    }

    init(origin: URL, transport: any ClientTransport, access: @escaping @Sendable () async -> String?) {
        self.origin = origin; self.transport = transport; self.access = access
    }

    public func send(_ batch: AnalyticsBatch) async throws {
        typealias Event = Operations.ingestAnalytics.Input.Body.jsonPayload.eventsPayloadPayload
        let events = try batch.events.map { record in
            guard let name = Event.namePayload(rawValue: record.name.rawValue) else { throw AccountError.invalidInput }
            return Event(name: name, occurred_at: record.occurredAt,
                         properties: record.properties.isEmpty ? nil : .init(additionalProperties: record.properties),
                         id: record.id.uuidString.lowercased(), journey_id: record.journeyID?.uuidString.lowercased())
        }
        let token = await access()
        let client = Client(serverURL: origin, configuration: .init(dateTranscoder: LenientDateTranscoder()),
                            transport: transport, middlewares: [NativeHeaders(access: { token })])
        switch try await client.ingestAnalytics(body: .json(.init(events: events))) {
        case .ok: return
        case .unprocessableContent, .contentTooLarge: throw AccountError.invalidInput
        case .tooManyRequests: throw AccountError.rateLimited
        default: throw AccountError.unavailable
        }
    }
}

/// The §9 events a successful API call stands for, derived exactly as the website derives them from the same calls
/// (DAD-Main `apps/web/lib/analytics.ts` `observeAPI`), so a funnel counts the same thing on every platform.
/// `requestBody` is read only for preferences and `responseBody` only for an event reservation.
func observedEvents(method: HTTPRequest.Method, path: String, requestBody: () -> Data?, responseBody: () -> Data?) -> [AnalyticsEvent] {
    func object(_ data: Data?) -> [String: Any]? { data.flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] } }
    if method == .get {
        if path.wholeMatch(of: /\/(donor\/me\/)?events\/[^\/]+/) != nil { return [.eventViewed] }
        if path == "/donor/partner/report.pdf" { return [.partnerReportExported] }
        return []
    }
    guard method == .post else { return [] }
    switch path {
    case "/donor/signup": return [.signupStarted]
    case "/donor/claim": return [.signupCompleted]
    case "/donor/me/recurring/checkout": return [.giftStarted]
    case "/donor/me/delete": return [.accountDeleted]
    case "/donor/me/recurring/cancel": return [.giftCancelled]
    case "/donor/me/recurring/amount": return [.amountChanged]
    case "/donor/me/team": return [.teamJoined]
    case "/donor/me/events/check-in": return [.eventCheckedIn]
    case "/donor/me/preferences":
        guard let body = object(requestBody()) else { return [] }
        var events: [AnalyticsEvent] = []
        if body["rankings_opted_out"] != nil { events.append(.rankingsToggled) }
        if body["volunteer"] as? Bool == true { events.append(.volunteerOptedIn) }
        return events
    default:
        guard path.wholeMatch(of: /\/donor\/me\/events\/[^\/]+\/reserve/) != nil else { return [] }
        switch object(responseBody())?["status"] as? String {
        case "WAITLISTED": return [.eventWaitlisted]
        case "RESERVED": return [.eventReserved]
        default: return []
        }
    }
}

/// Where observed API calls are reported. The app installs its analytics controller once at launch; until then (and
/// in tests that do not install one) calls are not observed.
public final class AnalyticsObservation: @unchecked Sendable {
    public static let shared = AnalyticsObservation()
    private let lock = NSLock()
    private var emit: (@Sendable (AnalyticsEvent) -> Void)?

    public init() {}
    public func install(_ emit: @escaping @Sendable (AnalyticsEvent) -> Void) { lock.withLock { self.emit = emit } }
    var handler: (@Sendable (AnalyticsEvent) -> Void)? { lock.withLock { emit } }
}

/// Wraps a transport and reports the events each successful call stands for. Bodies are buffered (both are bounded:
/// requests are the app's own JSON, responses are capped by `NativeHeaders`) only when the call needs them read.
struct ObservingTransport: ClientTransport {
    let inner: any ClientTransport
    let observation: AnalyticsObservation

    func send(_ request: HTTPRequest, body: HTTPBody?, baseURL: URL, operationID: String) async throws -> (HTTPResponse, HTTPBody?) {
        guard let report = observation.handler else { return try await inner.send(request, body: body, baseURL: baseURL, operationID: operationID) }
        let path = String((request.path ?? "").prefix { $0 != "?" })
        var requestData: Data?
        var sentBody = body
        if path == "/donor/me/preferences", let body {
            let bytes = try await ArraySlice<UInt8>(collecting: body, upTo: 65_536)
            requestData = Data(bytes)
            sentBody = HTTPBody(bytes)
        }
        let (response, responseBody) = try await inner.send(request, body: sentBody, baseURL: baseURL, operationID: operationID)
        guard response.status.kind == .successful else { return (response, responseBody) }
        var responseData: Data?
        var returnedBody = responseBody
        if path.hasSuffix("/reserve"), let responseBody {
            let bytes = try await ArraySlice<UInt8>(collecting: responseBody, upTo: 1_048_576)
            responseData = Data(bytes)
            returnedBody = HTTPBody(bytes)
        }
        observedEvents(method: request.method, path: path, requestBody: { requestData }, responseBody: { responseData }).forEach(report)
        return (response, returnedBody)
    }
}
