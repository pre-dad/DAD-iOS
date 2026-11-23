#if DEBUG
import Foundation
import HTTPTypes
import OpenAPIRuntime

public final class InMemoryCredentialStore: CredentialStore, @unchecked Sendable {
    private let lock = NSLock()
    private var value: Credentials?
    public init(_ value: Credentials? = nil) { self.value = value }
    public func load() throws -> Credentials? { lock.withLock { value } }
    public func save(_ credentials: Credentials) throws { lock.withLock { value = credentials } }
    public func clear() throws { lock.withLock { value = nil } }
}

/// DEBUG-only scripted backend for the simulator UITests. It is NOT a preview double: the app
/// runs the REAL `WireAuth`, `WireAccountSettings`, `WireAPI`, `AccountSession` and keychain-shaped
/// store on top of it, so a UITest drives the same code a release build uses, with only the
/// network replaced by this transport. Compiled out of release builds.
///
/// Script: phone sign-in accepts code `123456`; `000000` is throttled (429); anything else is a
/// 401. Email signup answers 200 `{"sent":true}` like the live server (the emailed link is claimed
/// with a token starting `stubclaim`); password sign-in accepts `correct horse battery` (the
/// stored password, replaceable via set-password), `throttled password` is 429, anything else is
/// the server's 401 "email or password is incorrect". Set-password rejects a wrong `current_password`
/// with 422 `CURRENT_PASSWORD_INCORRECT` and a new password outside 12...72 bytes with 422. Profile/preferences/
/// logout/refresh behave like a live account; the donor-home reads (dashboard, today's initiative, 120 gifts
/// paged 50 at a time, receipts, the annual summary) follow `Scenario`; account deletion succeeds (200) unless
/// `deletionBlocked` (409) or while a monthly gift is still set to renew (`GiftScenario`), after which the
/// account is gone (profile -> 401). The giving reads/commands (recurring, amount, cancel, payment method)
/// follow a stateful gift: the hosted Stripe pages are stubbed by the UI (`completeHandoff` plays the
/// "payment finished" webhook), so the REAL `WireGiving` conformer runs end to end. Partner sign-in links are
/// accepted for tokens starting `stubpartner` (anything else is the server's 422 "invalid or expired"); the
/// portal is an ADMIN at Acme with two users, one unverified figure, an earlier export and no logo. Link
/// capture answers like the server: referral code `ALEX42` is Alex R's, company code `ACME42` is Acme's, and
/// any other code keeps the token sent, if any; the checkout records the referral token it was given.
public enum StubBackend {
    public static let origin = URL(string: "https://stub.invalid")!
    /// Where a stub-backed launch keeps its link tokens, apart from a real install's.
    public static let linkTokensKey = "org.dad.link-tokens.stub"

    /// What the scripted donor-home reads answer. `populated`: a ready dashboard, an initiative and 120
    /// gifts. `empty`: dashboard still preparing, no initiative in rotation, no gifts. `failFirst`: the
    /// first dashboard/gifts read of each kind is a 503, then it behaves like `populated`. `unranked`:
    /// like `populated` but the donor opted out of rankings and has no streak figure yet.
    public enum Scenario: Sendable { case populated, empty, failFirst, unranked }

    /// The donor's recurring gift at launch. `none`: no gift yet. `active`: $5/day ($150/month) renewing.
    /// `activeFailFirst`: like `active`, but the first recurring read is a 503 (the error + retry path).
    public enum GiftScenario: Sendable { case none, active, activeFailFirst }

    /// What the scripted events answer. `standard`: five events (one reservable, one full, one invite-only unlocked
    /// for this donor, one in progress that the donor already holds a seat for, one that refuses the donor with
    /// 403). `ungated`: the donor lacks the badge, so the invite-only event is neither listed nor readable (404).
    /// `failFirst`: the first list read is a 503, then it behaves like `standard`.
    public enum EventsScenario: Sendable { case standard, ungated, failFirst }

    /// What the scripted engagement reads answer. `standard`: badges, network, a public name and conversions all
    /// answer. `rankingToggleFails`: like `standard`, but saving the rankings choice is a 503 (the revert path).
    /// `noPublicName`: the donor has not chosen a public name, so there is no invite code until one is saved.
    /// `badgesDown`: the badges read is a 503 while everything else answers (the partial-section path).
    public enum EngagementScenario: Sendable { case standard, rankingToggleFails, noPublicName, badgesDown }

    /// How the application submission answers. `accepts`: 200, and the receipt then reads as PENDING. `invalid`:
    /// 422 every time. `throttled`: 429 with `Retry-After: 30` and no JSON body, like the ingress. `failsFirst`: the
    /// first attempt is recorded but answers 503 (the unconfirmed case), the retry is accepted.
    public enum ApplicationSubmitScenario: Sendable { case accepts, invalid, throttled, failsFirst }

    public struct Services: Sendable {
        public let session: AccountSession
        public let signIn: any SignInService
        public let settings: any AccountSettingsService
        public let credentialAuth: WireCredentialAuth
        public let passwords: any PasswordSettingsService
        public let dashboard: any DashboardService
        public let giving: any GivingService
        public let events: any EventsService
        public let engagement: any EngagementService
        public let management: any AccountManagementService
        public let wallet: any WalletPassService
        public let partnerAuth: WirePartnerAuth
        public let partner: WirePartner
        public let partnerSession: PartnerSession
        /// The pending-application read; holds a receipt only when the launch asked for an application scenario.
        public let applicationStatus: WireApplicationStatus
        /// Submits through the same receipt store the status read uses, as the app does.
        public let applicationSubmit: WirePartnerApplication
        public let push: any DonorPushService
        public let linkAttribution: any LinkAttributionService
        /// The referral token the last `startRecurringCheckout` carried, for UITests' expectations.
        public let checkoutReferral: @Sendable () -> String?
        /// The ingest sink, on the bare transport so the upload itself is never observed.
        public let analyticsSink: any AnalyticsSink
        /// Plays the Stripe webhook after the stubbed hosted page "finishes" (a gift starts, a card is applied).
        public let completeHandoff: @Sendable (HostedHandoff.Purpose) -> Void
    }

    /// `signedIn` starts with a stored session (as after a relaunch), skipping the phone sign-in dance.
    public static func make(deletionBlocked: Bool = false, scenario: Scenario = .populated, gift: GiftScenario = .none,
                            events: EventsScenario = .standard, engagement: EngagementScenario = .standard, signedIn: Bool = false,
                            partnerSignedIn: Bool = false, partnerViewer: Bool = false, application: String? = nil,
                            applicationSubmit: ApplicationSubmitScenario = .accepts,
                            onLocalWipe: @escaping @Sendable () -> Void = {}) throws -> Services {
        let stub = StubTransport(deletionBlocked: deletionBlocked, scenario: scenario, gift: gift, events: events,
                                 engagement: engagement, partnerViewer: partnerViewer, application: application,
                                 applicationSubmit: applicationSubmit)
        let receiptStore = InMemoryCredentialStore(application == nil ? nil : Credentials(
            access: "stub-receipt-" + String(repeating: "r", count: 31), refresh: "", expiresAt: Date().addingTimeInterval(30 * 86_400)))
        let transport = ObservingTransport(inner: stub, observation: .shared)
        let session = try AccountSession(api: WireAPI(origin: origin, transport: transport), store: InMemoryCredentialStore(signedIn ? Credentials(
            access: "stub-access-0", refresh: "stub-refresh-0-xxxxxxxxxxxxxxxxxxxxxxxxxxxx", expiresAt: Date().addingTimeInterval(900)) : nil))
        let product = ProductClient(origin: origin, transport: transport, session: session)
        let partnerSession = try PartnerSession(store: InMemoryCredentialStore(partnerSignedIn ? Credentials(
            access: "stub-partner-0", refresh: "", expiresAt: Date().addingTimeInterval(PartnerSession.lifetime)) : nil))
        return Services(
            session: session,
            signIn: WireAuth(origin: origin, transport: transport),
            settings: WireAccountSettings(product: product, onLocalWipe: onLocalWipe),
            credentialAuth: WireCredentialAuth(origin: origin, transport: transport),
            passwords: WirePasswordSettings(product: product),
            dashboard: WireDashboard(product: product),
            giving: WireGiving(product: product, referral: { DefaultsLinkTokenStore(key: StubBackend.linkTokensKey).load().referral }),
            events: WireEvents(product: product),
            engagement: WireEngagement(product: product),
            management: WireAccountManagement(product: product),
            wallet: WireWalletPass(product: product),
            partnerAuth: WirePartnerAuth(origin: origin, transport: transport, session: partnerSession),
            partner: WirePartner(origin: origin, transport: transport, session: partnerSession),
            partnerSession: partnerSession,
            applicationStatus: WireApplicationStatus(origin: origin, transport: transport, receipt: receiptStore),
            applicationSubmit: WirePartnerApplication(origin: origin, transport: transport, receipt: receiptStore),
            push: WireDonorPush(product: product),
            linkAttribution: WireLinkAttribution(product: product),
            checkoutReferral: { stub.checkoutReferral },
            analyticsSink: WireAnalytics(origin: origin, transport: stub, access: { nil }),
            completeHandoff: { stub.completeHandoff($0) })
    }
}

/// Fixed ids for the scripted events (`StubBackend.EventsScenario`), shared with the UITests' expectations.
enum StubEvents {
    static let park = "11111111-0000-4000-8000-000000000001"
    static let foodBank = "11111111-0000-4000-8000-000000000002"
    static let dinner = "11111111-0000-4000-8000-000000000003"
    static let workshop = "11111111-0000-4000-8000-000000000004"
    static let brunch = "11111111-0000-4000-8000-000000000005"
}

private final class StubTransport: ClientTransport, @unchecked Sendable {
    private let lock = NSLock()
    private let deletionBlocked: Bool
    private let scenario: StubBackend.Scenario
    private var failuresServed = Set<String>()
    private var generation = 0
    private var deleted = false
    private var version = 3
    private var storedPassword = "correct horse battery"
    private let partnerViewer: Bool
    /// The application status the stub answers for a receipt (`PENDING`, `APPROVED`, `REJECTED` or any other string).
    private let applicationStatus: String?
    private let applicationSubmit: StubBackend.ApplicationSubmitScenario
    /// Receipts the stub has accepted with an application, mapped to the organization they named.
    private var submittedReceipts = [String: String]()
    private var submitAttempts = 0
    private var partnerOrg = "Acme Corp"
    private var partnerAbout = "Doing good together."
    private var partnerWorkforce = 240
    private var partnerLogo: Data?
    private var partnerUsers = [#"{"id":"u1","email":"ada@acme.com","name":"Ada Admin","role":"ADMIN","accepted":true}"#,
                                #"{"id":"u2","email":"val@acme.com","name":"Val Viewer","role":"VIEWER","accepted":true}"#]
    // r1 is listed as downloadable but has aged out on the server: downloading it is the 404 path.
    private var partnerExports = [#"{"id":"r1","committed_minor":4000000,"deployed_minor":2000000,"people_reached":9000,"exported_by":"Ada Admin","created_at":"2026-09-01T10:00:00Z","downloadable":true,"people_reached_verified":true}"#]
    private var prefs: [String: Bool] = [
        "referral_emails": true, "marketing_emails": false, "push_referral_converted": true, "push_streak_at_risk": true,
        "push_streak_milestone": true, "push_streak_lapsed": true, "push_badge_earned": true, "push_event_nearby": false,
        "push_event_reminder": true, "push_event_promoted": false, "push_gift_processed": true,
        "rankings_opted_out": false, "network_visible": true, "volunteer": true,
    ]

    // Giving: one stateful gift. `giftAmount` is the integer-cent monthly charge; nil means no gift.
    private enum Payment: String { case none = "NONE", open = "OPEN", applied = "APPLIED" }
    private var giftAmount: Int?
    private var giftEnding = false
    /// The amount the last `startRecurringCheckout` was created for: what the "paid" webhook activates.
    private var checkoutAmount: Int?
    private var referralSent: String?
    var checkoutReferral: String? { lock.withLock { referralSent } }
    private static let referralToken = "stub-referral-token-0000000000000000000000"
    private static let companyToken = "stub-company-token-00000000000000000000000"
    private var payment = Payment.none
    private var recurringFailureServed = false
    private let failFirstRecurring: Bool
    private static let subscriptionID = "5d6f1d9e-0a5b-4e6f-8d0f-3f1c2a9b7c10"
    private static let periodEnd = "2026-11-20T15:00:00Z"

    // Events: reservation status per event id, and which codes have already checked in.
    private let eventsScenario: StubBackend.EventsScenario
    private var reservations: [String: String] = [StubEvents.workshop: "RESERVED"]
    private var checkedIn = [String: Date]()
    private var eventListFailureServed = false

    // Engagement: the donor's public name (nil until chosen under `.noPublicName`).
    private let engagementScenario: StubBackend.EngagementScenario
    private var publicName: String?
    private static let initiativeID = "11111111-1111-4111-8111-111111111111"

    // Account management: contact details, other sessions, and the employer link. Company code
    // `ACME42` links "Acme"; any other code is unrecognized.
    private var contact = (zip: "78701", city: "Austin", phone: Optional<String>.none)
    private var timezoneOverride: String?
    private var otherSessions = [#"{"id":"22222222-2222-4222-8222-222222222222","client":"BROWSER","platform":null,"label":"Web browser","created_at":"2026-10-02T10:00:00Z","last_used_at":"2026-10-29T10:00:00Z","current":false}"#]
    private var employer: String?
    private var team: String?

    init(deletionBlocked: Bool, scenario: StubBackend.Scenario, gift: StubBackend.GiftScenario, events: StubBackend.EventsScenario,
         engagement: StubBackend.EngagementScenario, partnerViewer: Bool, application: String?,
         applicationSubmit: StubBackend.ApplicationSubmitScenario) {
        self.partnerViewer = partnerViewer; applicationStatus = application; self.applicationSubmit = applicationSubmit
        self.deletionBlocked = deletionBlocked; self.scenario = scenario; eventsScenario = events
        engagementScenario = engagement
        publicName = engagement == .noPublicName ? nil : "Alex R"
        giftAmount = gift == .none ? nil : 15000
        failFirstRecurring = gift == .activeFailFirst
    }

    /// The "payment finished" webhook: what the server would hold once the hosted page completed.
    func completeHandoff(_ purpose: HostedHandoff.Purpose) {
        lock.withLock {
            switch purpose {
            case .startGift: giftAmount = checkoutAmount ?? 3000; giftEnding = false
            case .updatePayment: payment = .applied
            }
        }
    }

    private func recurringJSON() -> String {
        lock.withLock {
            guard let amount = giftAmount else { return #"{"mode":"test","state":"ready","subscription":null}"# }
            let stops = giftEnding ? "\"" + Self.periodEnd + "\"" : "null"
            return #"{"mode":"test","state":"ready","observed_at":"2026-10-31T12:00:00Z","subscription":{"amount_minor":\#(amount),"currency":"USD","id":"\#(Self.subscriptionID)","period_end":"\#(Self.periodEnd)","status":"active","stops_at":\#(stops)}}"#
        }
    }

    /// Giving routes. Commands need a version 4 Idempotency-Key and echo the values the matching GET returned.
    private func giving(_ request: HTTPRequest, _ payload: String, authorized: Bool,
                        _ reply: (HTTPResponse.Status, String) -> (HTTPResponse, HTTPBody?)) -> (HTTPResponse, HTTPBody?)? {
        guard let path = request.path, path.hasPrefix("/donor/me/recurring") || path == "/donor/me/payment-method" || path == "/donor/me/payment-method/setup" else { return nil }
        guard authorized, !lock.withLock({ deleted }) else { return reply(.unauthorized, "{}") }
        let key = request.headerFields[HTTPField.Name("Idempotency-Key")!]
        let fields = Self.object(payload)
        func validKey() -> Bool { key.flatMap(UUID.init(uuidString:)) != nil }
        switch (request.method, path) {
        case (.get, "/donor/me/recurring"):
            let fail = lock.withLock { () -> Bool in
                guard failFirstRecurring, !recurringFailureServed else { return false }
                recurringFailureServed = true
                return true
            }
            return fail ? reply(.serviceUnavailable, #"{"detail":"unavailable"}"#) : reply(.ok, recurringJSON())
        case (.get, "/donor/me/recurring/amount"):
            guard let amount = lock.withLock({ giftAmount }) else { return reply(.ok, #"{"state":"unavailable"}"#) }
            return reply(.ok, #"{"state":"ready","subscription_id":"\#(Self.subscriptionID)","amount_minor":\#(amount),"effective_at":"\#(Self.periodEnd)","change":null}"#)
        case (.post, "/donor/me/recurring/checkout"):
            guard validKey() else { return reply(.unprocessableContent, "{}") }
            guard let amount = fields["amount_minor"] as? Int, amount >= 3000, amount <= 90000, amount % 3000 == 0 else { return reply(.unprocessableContent, "{}") }
            guard lock.withLock({ giftAmount }) == nil else { return reply(.conflict, "{}") }
            let referral = fields["referral_token"] as? String
            lock.withLock { checkoutAmount = amount; referralSent = referral }
            return reply(.created, #"{"url":"https://stub.invalid/pay/checkout","session_id":"cs_stub_1","expires_at":"2026-11-01T12:00:00Z"}"#)
        case (.post, "/donor/me/recurring/amount"):
            guard validKey() else { return reply(.unprocessableContent, "{}") }
            guard let new = fields["amount_minor"] as? Int, new >= 3000, new <= 90000, new % 3000 == 0 else { return reply(.unprocessableContent, "{}") }
            let current = lock.withLock { giftAmount }
            guard let current, fields["subscription_id"] as? String == Self.subscriptionID, fields["previous_minor"] as? Int == current,
                  fields["effective_at"] as? String == Self.periodEnd else { return reply(.conflict, "{}") }
            lock.withLock { giftAmount = new }
            return reply(.ok, #"{"amount_minor":\#(new),"previous_minor":\#(current),"confirmed":true,"effective_at":"\#(Self.periodEnd)","request_id":"11111111-2222-4333-8444-555555555555"}"#)
        case (.post, "/donor/me/recurring/cancel"):
            guard validKey() else { return reply(.unprocessableContent, "{}") }
            guard lock.withLock({ giftAmount }) != nil, fields["subscription_id"] as? String == Self.subscriptionID,
                  fields["period_end"] as? String == Self.periodEnd else { return reply(.conflict, "{}") }
            lock.withLock { giftEnding = true }
            return reply(.ok, recurringJSON())
        case (.get, "/donor/me/payment-method"):
            let status = lock.withLock { payment.rawValue }
            let completed = status == "APPLIED" ? "\"2026-10-31T12:00:00Z\"" : "null"
            return reply(.ok, #"{"mode":"test","status":"\#(status)","completed_at":\#(completed)}"#)
        case (.post, "/donor/me/payment-method/setup"):
            guard validKey() else { return reply(.unprocessableContent, "{}") }
            guard lock.withLock({ giftAmount }) != nil else { return reply(.conflict, "{}") }
            lock.withLock { payment = .open }
            return reply(.ok, #"{"url":"https://stub.invalid/pay/setup"}"#)
        default: return nil
        }
    }

    private struct StubEvent {
        let id: String, slug: String, title: String, type: String, venue: String, city: String
        let startOffset: TimeInterval, duration: TimeInterval, capacity: Int, taken: Int
        var note: String? = nil
    }

    private static let eventTable: [StubEvent] = [
        StubEvent(id: StubEvents.park, slug: "park-cleanup", title: "Park Cleanup", type: "VOLUNTEER", venue: "Zilker Park", city: "Austin",
                  startOffset: 3 * 86_400, duration: 7_200, capacity: 20, taken: 12),
        StubEvent(id: StubEvents.foodBank, slug: "food-bank-night", title: "Food Bank Night", type: "COMMUNITY", venue: "Central Kitchen", city: "Austin",
                  startOffset: 4 * 86_400, duration: 7_200, capacity: 30, taken: 30),
        StubEvent(id: StubEvents.dinner, slug: "founders-dinner", title: "Founders Dinner", type: "INVITE_ONLY", venue: "The Loft", city: "Austin",
                  startOffset: 6 * 86_400, duration: 10_800, capacity: 20, taken: 15, note: "Invitation earned at Founding Donor"),
        StubEvent(id: StubEvents.workshop, slug: "live-workshop", title: "Live Workshop", type: "VOLUNTEER", venue: "Maker Hall", city: "Austin",
                  startOffset: -1_800, duration: 7_200, capacity: 10, taken: 4),
        StubEvent(id: StubEvents.brunch, slug: "members-brunch", title: "Members Brunch", type: "COMMUNITY", venue: "Cafe Sol", city: "Austin",
                  startOffset: 5 * 86_400, duration: 5_400, capacity: 40, taken: 10),
    ]
    /// Well-formed tokens (`<22 base64url>.<43 base64url>`) the stub accepts, plus one well-formed but unknown.
    static let checkInTokens = ["stubworkshop0stubworks.stubworkshopcheckin0stubworkshopcheckin0stu": StubEvents.workshop,
                                "stubpark0stubpark0stub.stubparkcheckin0stubparkcheckin0stubparkche": StubEvents.park]

    private static func iso(_ date: Date) -> String { ISO8601DateFormatter().string(from: date) }

    private func eventJSON(_ event: StubEvent, now: Date) -> String {
        let mine = lock.withLock { reservations[event.id] }
        let start = now.addingTimeInterval(event.startOffset)
        // The donor's own seat counts toward what is taken (the fixture's `taken` is everyone else).
        let spots = max(0, event.capacity - event.taken - (mine == "RESERVED" ? 1 : 0))
        let status = mine.map { "\"\($0)\"" } ?? "null"
        let checkedInAt = lock.withLock { checkedIn[event.id] }.map { "\"\(Self.iso($0))\"" } ?? "null"
        let note = event.note.map { "\"\($0)\"" } ?? "null"
        return #"{"id":"\#(event.id)","slug":"\#(event.slug)","title":"\#(event.title)","type":"\#(event.type)","description":"Bring water and good shoes.","venue":"\#(event.venue)","address":"1 Main St","city":"\#(event.city)","starts_at":"\#(Self.iso(start))","ends_at":"\#(Self.iso(start.addingTimeInterval(event.duration)))","capacity":\#(event.capacity),"spots_left":\#(spots),"reservation_status":\#(status),"time_zone":"America/Chicago","checked_in_at":\#(checkedInAt),"invitation_note":\#(note),"report_issue_url":"mailto:help@dad.org","cancelled":false,"booking_opens_at":null,"early_booking":false}"#
    }

    private func events(_ request: HTTPRequest, _ payload: String, authorized: Bool,
                        _ reply: (HTTPResponse.Status, String) -> (HTTPResponse, HTTPBody?)) -> (HTTPResponse, HTTPBody?)? {
        guard let path = request.path, path.hasPrefix("/donor/me/events") else { return nil }
        guard authorized, !lock.withLock({ deleted }) else { return reply(.unauthorized, "{}") }
        let now = Date()
        let gated = eventsScenario == .ungated
        func visible(_ event: StubEvent) -> Bool { !(gated && event.type == "INVITE_ONLY") }
        let parts = path.split(separator: "/").map(String.init)   // donor, me, events, [id|check-in|invite-only], [action]
        switch (request.method, parts.count) {
        case (.get, 3):
            let fail = lock.withLock { () -> Bool in
                guard eventsScenario == .failFirst, !eventListFailureServed else { return false }
                eventListFailureServed = true
                return true
            }
            if fail { return reply(.serviceUnavailable, #"{"detail":"unavailable"}"#) }
            let rows = Self.eventTable.filter { $0.type != "INVITE_ONLY" }.map { eventJSON($0, now: now) }.joined(separator: ",")
            return reply(.ok, #"{"events":[\#(rows)]}"#)
        case (.get, 4) where parts[3] == "invite-only":
            let rows = Self.eventTable.filter { $0.type == "INVITE_ONLY" && visible($0) }.map { eventJSON($0, now: now) }.joined(separator: ",")
            return reply(.ok, #"{"events":[\#(rows)]}"#)
        case (.post, 4) where parts[3] == "check-in":
            guard let token = Self.object(payload)["token"] as? String, !token.isEmpty else { return reply(.unprocessableContent, "{}") }
            guard let id = Self.checkInTokens[token], let event = Self.eventTable.first(where: { $0.id == id }) else { return reply(.unprocessableContent, "{}") }
            let start = now.addingTimeInterval(event.startOffset)
            guard now >= start, now <= start.addingTimeInterval(event.duration), lock.withLock({ reservations[id] }) == "RESERVED" else {
                return reply(.unprocessableContent, "{}")
            }
            let already = lock.withLock { () -> Bool in
                if checkedIn[id] != nil { return true }
                checkedIn[id] = now
                return false
            }
            return reply(.ok, #"{"event_id":"\#(id)","checked_in":\#(!already),"already_checked_in":\#(already)}"#)
        case (.get, 4):
            guard let event = Self.eventTable.first(where: { $0.id == parts[3] }), visible(event) else { return reply(.notFound, "{}") }
            return reply(.ok, eventJSON(event, now: now))
        case (.get, 5) where parts[4] == "calendar.ics":
            guard let event = Self.eventTable.first(where: { $0.id == parts[3] }), visible(event) else { return reply(.notFound, "{}") }
            let start = now.addingTimeInterval(event.startOffset)
            let compact = { (d: Date) in Self.iso(d).replacingOccurrences(of: "-", with: "").replacingOccurrences(of: ":", with: "") }
            let ics = "BEGIN:VCALENDAR\r\nVERSION:2.0\r\nPRODID:-//DAD//Stub//EN\r\nBEGIN:VEVENT\r\nUID:\(event.id)@stub.invalid\r\nDTSTAMP:\(compact(now))\r\nDTSTART:\(compact(start))\r\nDTEND:\(compact(start.addingTimeInterval(event.duration)))\r\nSUMMARY:\(event.title)\r\nEND:VEVENT\r\nEND:VCALENDAR\r\n"
            return (HTTPResponse(status: .ok, headerFields: [.contentType: "text/calendar"]), HTTPBody(ics))
        case (.post, 5) where parts[4] == "reserve" || parts[4] == "cancel":
            guard let event = Self.eventTable.first(where: { $0.id == parts[3] }), visible(event) else { return reply(.notFound, "{}") }
            if parts[4] == "cancel" {
                guard lock.withLock({ reservations[event.id] }) != nil else { return reply(.conflict, "{}") }
                lock.withLock { reservations[event.id] = nil }
                return reply(.ok, #"{"status":"CANCELLED"}"#)
            }
            if event.id == StubEvents.brunch { return reply(.forbidden, "{}") }
            guard lock.withLock({ reservations[event.id] }) == nil, now < now.addingTimeInterval(event.startOffset) else { return reply(.conflict, "{}") }
            let full = event.capacity - event.taken <= 0
            lock.withLock { reservations[event.id] = full ? "WAITLISTED" : "RESERVED" }
            return reply(.ok, #"{"status":"\#(full ? "WAITLISTED" : "RESERVED")"}"#)
        default: return nil
        }
    }

    private static let badges = #"{"badges":[{"code":"F","title":"Founding Donor","rule":"Start a monthly gift before January 2027, or join the website waitlist","perk":"FOUNDING_EVENTS","earned":true,"earned_at":"2026-09-02T10:00:00Z","artwork":"f","city":null,"display_title":"Founding Donor"},{"code":"7","title":"One Week","rule":"Reach a 7-day streak","perk":"","earned":true,"earned_at":"2026-10-14T10:00:00Z","artwork":"7","city":null,"display_title":"One Week"},{"code":"30","title":"One Month","rule":"Reach a 30-day streak","perk":"","earned":false,"earned_at":null,"artwork":"30","city":null,"display_title":"One Month"},{"code":"1K","title":"1,000 Days","rule":"Reach a 1,000-day streak","perk":"MILESTONE_EVENTS","earned":false,"earned_at":null,"artwork":"1k","city":null,"display_title":"1,000 Days"},{"code":"TC","title":"Team Captain","rule":"Twenty people you invited complete a gift","perk":"TEAM_CAPTAIN","earned":false,"earned_at":null,"artwork":"tc","city":null,"display_title":"Team Captain"},{"code":"CITY50","title":"Top 50 City","rule":"Rank in the top 50 donors in your city","perk":"","earned":true,"earned_at":"2026-10-20T10:00:00Z","artwork":"c50","city":"Chicago","display_title":"Top 50 in Chicago"}]}"#
    private static let network = #"{"active_count":3,"annualized_minor":474500,"next_milestone":{"label":"Team Captain","target":20,"remaining":17},"invitees":[{"name":"Sam L","active":true},{"name":"Jo P","active":false}],"anonymous_active":1}"#
    private static let conversions = #"{"conversions":[{"converted_at":"2026-10-20T10:00:00Z","kind":"LINK"},{"converted_at":"2026-10-02T10:00:00Z","kind":"IRL"}],"more":false}"#
    private static let spend = #"{"initiative_id":"11111111-1111-4111-8111-111111111111","total_minor":125000,"categories":[{"category":"Food","amount_minor":90000},{"category":"Delivery","amount_minor":35000}]}"#

    private func sharingJSON() -> String {
        guard let name = lock.withLock({ publicName }) else { return #"{"public_name":null,"link":null,"irl_link":null,"referral_code":null}"# }
        return #"{"public_name":"\#(name)","link":"https://stub.invalid/r/ALEX42","irl_link":"https://stub.invalid/r/ALEX42?via=irl","referral_code":"ALEX42"}"#
    }

    /// The dashboard with the donor's current rankings choice applied: opted out hides the rank, as the server does.
    private func readyDashboard() -> String {
        lock.withLock({ prefs["rankings_opted_out"] }) == true ? Self.readyOptedOut : Self.ready
    }

    private func engagement(_ request: HTTPRequest, _ payload: String, authorized: Bool,
                            _ reply: (HTTPResponse.Status, String) -> (HTTPResponse, HTTPBody?)) -> (HTTPResponse, HTTPBody?)? {
        guard let path = request.path else { return nil }
        if path.hasPrefix("/initiatives/"), path.hasSuffix("/spend") {
            return path == "/initiatives/\(Self.initiativeID)/spend" ? reply(.ok, Self.spend) : reply(.notFound, "{}")
        }
        guard ["/donor/me/badges", "/donor/me/network", "/donor/me/sharing", "/donor/me/conversions"].contains(where: { path.hasPrefix($0) }) else { return nil }
        guard authorized, !lock.withLock({ deleted }) else { return reply(.unauthorized, "{}") }
        switch (request.method, path) {
        case (.get, "/donor/me/badges"):
            return engagementScenario == .badgesDown ? reply(.serviceUnavailable, #"{"detail":"unavailable"}"#) : reply(.ok, Self.badges)
        case (.get, "/donor/me/network"): return reply(.ok, Self.network)
        case (.get, "/donor/me/sharing"): return reply(.ok, sharingJSON())
        case (.get, "/donor/me/conversions"): return reply(.ok, Self.conversions)
        case (.post, "/donor/me/sharing"):
            guard let name = Self.object(payload)["public_name"] as? String, !name.isEmpty, name.count <= 80 else { return reply(.unprocessableContent, "{}") }
            lock.withLock { publicName = name }
            return reply(.ok, sharingJSON())
        default: return nil
        }
    }

    private func partner(_ request: HTTPRequest, _ payload: String,
                         _ reply: (HTTPResponse.Status, String) -> (HTTPResponse, HTTPBody?)) -> (HTTPResponse, HTTPBody?)? {
        guard let path = request.path, path.hasPrefix("/donor/partner/") else { return nil }
        let fields = Self.object(payload)
        switch (request.method, path) {
        case (.post, "/donor/partner/sign-in"):
            let email = fields["email"] as? String ?? ""
            return email.contains("@") ? reply(.accepted, #"{"message":"stub"}"#) : reply(.unprocessableContent, "{}")
        case (.post, "/donor/partner/accept-invite"):
            let token = fields["invite"] as? String ?? ""
            return token.hasPrefix("stubpartner") ? reply(.ok, #"{"session":"stub-partner-1"}"#) : reply(.unprocessableContent, "{}")
        case (.post, "/donor/partner/applications"):
            guard request.headerFields[.authorization] == nil, request.headerFields[HTTPField.Name("Idempotency-Key")!] != nil,
                  let receipt = fields["receipt"] as? String, receipt.count == 43,
                  let organization = (fields["application"] as? [String: Any])?["organization"] as? String else { return reply(.unprocessableContent, "{}") }
            let attempt = lock.withLock { submitAttempts += 1; return submitAttempts }
            switch applicationSubmit {
            case .invalid: return reply(.unprocessableContent, "{}")
            case .throttled:
                return (HTTPResponse(status: .tooManyRequests, headerFields: [.retryAfter: "30"]), nil)
            case .failsFirst where attempt == 1:
                lock.withLock { submittedReceipts[receipt] = organization }
                return reply(.serviceUnavailable, "{}")
            default:
                lock.withLock { submittedReceipts[receipt] = organization }
                return reply(.ok, #"{"received":true}"#)
            }
        case (.get, "/donor/partner/application-status"):
            let bearer = request.headerFields[.authorization].map { String($0.dropFirst("Bearer ".count)) } ?? ""
            if let organization = lock.withLock({ submittedReceipts[bearer] }) {
                return reply(.ok, #"{"organization":\#(Self.quoted(organization)),"status":"PENDING"}"#)
            }
            // The receipt is the bearer; only the receipt the launch seeded is recognized.
            guard request.headerFields[.authorization]?.hasPrefix("Bearer stub-receipt-") == true, let status = applicationStatus else {
                return reply(.unauthorized, "{}")
            }
            return reply(.ok, #"{"organization":"Acme Corp","status":\#(Self.quoted(status))}"#)
        default: break
        }
        guard request.headerFields[.authorization]?.hasPrefix("Bearer stub-partner-") == true else { return reply(.unauthorized, "{}") }
        let pdf = { (HTTPResponse(status: .ok, headerFields: [.contentType: "application/pdf"]), HTTPBody("%PDF-1.4 stub")) }
        // Like the server, a viewer's writes and the admin-only exports are 403, whatever the app's own gating does.
        let adminOnly = request.method == .post && !path.hasSuffix("/sign-out") && !path.contains("/push-device")
            || path == "/donor/partner/exports" || path.hasSuffix("report.pdf")
        if partnerViewer && adminOnly { return reply(.forbidden, "{}") }
        switch (request.method, path) {
        case (.get, "/donor/partner/overview"):
            let (organization, description, workforce, hasLogo) = lock.withLock { (partnerOrg, partnerAbout, partnerWorkforce, partnerLogo != nil) }
            return reply(.ok, #"{"user_id":"\#(partnerViewer ? "u2" : "u1")","organization":\#(Self.quoted(organization)),"description":\#(Self.quoted(description)),"role":"\#(partnerViewer ? "VIEWER" : "ADMIN")","company_code":"ACME","committed_minor":5000000,"deployed_minor":3000000,"deployed_percent":60,"people_reached":12400,"employees_enrolled":86,"workforce_size":\#(workforce),"enrolled_percent":35,"updated_at":"2026-10-28T10:00:00Z","has_logo":\#(hasLogo),"committed_verified":true,"deployed_verified":false,"people_reached_verified":true}"#)
        case (.get, "/donor/partner/initiatives"):
            return reply(.ok, #"{"initiatives":[{"id":"i1","title":"Clean Water West","summary":"Wells across 6 counties.","status":"ACTIVE","region":"West","county_count":6,"committed_minor":2000000,"deployed_minor":1200000,"metrics":[{"label":"People reached","value":8400,"unit":"PEOPLE","verified_on":"2026-10-20"}],"spend":[{"category":"Water","amount_minor":1200000}],"updated_at":"2026-10-28T10:00:00Z"}]}"#)
        case (.get, "/donor/partner/spend"):
            return reply(.ok, #"{"categories":[{"category":"Water","amount_minor":1800000},{"category":"Housing","amount_minor":1200000}]}"#)
        case (.get, "/donor/partner/our-people"):
            let workforce = lock.withLock { partnerWorkforce }
            return reply(.ok, #"{"enrolled":86,"workforce_size":\#(workforce),"streak_verified":true,"given_minor":940000,"matched_minor":470000,"avg_streak_days":42,"volunteer_minutes":6300,"teams":2,"suppressed":false}"#)
        case (.get, "/donor/partner/teams"):
            return reply(.ok, #"{"teams":[{"team_id":"t1","name":"Engineering","metrics_verified":true,"active_givers":31,"annualized_minor":1200000,"avg_streak_days":40,"volunteer_minutes":1200},{"team_id":"t2","name":"Sales","metrics_verified":true,"active_givers":12,"annualized_minor":600000,"avg_streak_days":18,"volunteer_minutes":300}]}"#)
        case (.get, "/donor/partner/users"):
            return reply(.ok, #"{"users":[\#(lock.withLock { partnerUsers }.joined(separator: ","))]}"#)
        case (.post, "/donor/partner/users"):
            guard let email = fields["email"] as? String, email.contains("@"), let name = fields["name"] as? String, !name.isEmpty,
                  let role = fields["role"] as? String else { return reply(.unprocessableContent, "{}") }
            if email.hasPrefix("taken") { return reply(.conflict, "{}") }
            lock.withLock { partnerUsers.append(#"{"id":"u\#(partnerUsers.count + 1)","email":\#(Self.quoted(email)),"name":\#(Self.quoted(name)),"role":"\#(role)","accepted":false}"#) }
            return reply(.ok, #"{"invited":true}"#)
        case (.post, _) where path.hasPrefix("/donor/partner/users/") && path.hasSuffix("/remove"):
            let id = path.dropFirst("/donor/partner/users/".count).dropLast("/remove".count)
            // The server refuses to remove the signed-in user and the organization's last admin (409).
            let refused = lock.withLock { () -> Bool in
                let admins = partnerUsers.filter { $0.contains(#""role":"ADMIN""#) }
                let target = partnerUsers.first { $0.contains(#""id":"\#(id)""#) }
                return id == "u1" || (target?.contains(#""role":"ADMIN""#) == true && admins.count <= 1)
            }
            if refused { return reply(.conflict, "{}") }
            lock.withLock { partnerUsers.removeAll { $0.contains(#""id":"\#(id)""#) } }
            return reply(.ok, #"{"removed":true}"#)
        case (.post, "/donor/partner/profile"):
            guard let organization = fields["organization"] as? String, (1...200).contains(organization.count),
                  let description = fields["description"] as? String else { return reply(.unprocessableContent, "{}") }
            lock.withLock { partnerOrg = organization; partnerAbout = description }
            return reply(.ok, #"{"saved":true}"#)
        case (.post, "/donor/partner/workforce"):
            guard let size = fields["workforce_size"] as? Int else { return reply(.unprocessableContent, "{}") }
            lock.withLock { partnerWorkforce = size }
            return reply(.ok, #"{"saved":true}"#)
        case (.get, "/donor/partner/logo"):
            guard let logo = lock.withLock({ partnerLogo }) else { return reply(.notFound, "{}") }
            return (HTTPResponse(status: .ok, headerFields: [.contentType: "image/png"]), HTTPBody(logo))
        case (.post, "/donor/partner/logo"):
            let dataURL = fields["data_url"] as? String ?? ""
            let logo = dataURL.isEmpty ? nil : Data(base64Encoded: String(dataURL.drop { $0 != "," }.dropFirst()))
            if !dataURL.isEmpty && logo == nil { return reply(.unprocessableContent, "{}") }
            lock.withLock { partnerLogo = logo }
            return reply(.ok, #"{"saved":true}"#)
        case (.get, "/donor/partner/exports"):
            return reply(.ok, #"{"exports":[\#(lock.withLock { partnerExports }.joined(separator: ","))]}"#)
        case (.get, "/donor/partner/report.pdf"):
            lock.withLock {
                partnerExports.insert(#"{"id":"r\#(partnerExports.count + 1)","committed_minor":5000000,"deployed_minor":3000000,"people_reached":12400,"exported_by":"Ada Admin","created_at":"2026-11-01T10:00:00Z","downloadable":true,"people_reached_verified":true}"#, at: 0)
            }
            return pdf()
        case (.get, _) where path.hasPrefix("/donor/partner/reports/"):
            return path.contains("/r1/") ? (HTTPResponse(status: .notFound, headerFields: [.contentType: "application/json"]), HTTPBody(#"{"detail":"stub"}"#)) : pdf()
        case (.post, "/donor/partner/sign-out"): return reply(.ok, #"{"signed_out":true}"#)
        case (.post, "/donor/partner/push-device"), (.post, "/donor/partner/push-device/unregister"):
            return reply(.ok, #"{"registered":false,"platform":null,"environment":null}"#)
        default: return reply(.notFound, "{}")
        }
    }

    private static func quoted(_ text: String) -> String {
        String(decoding: (try? JSONEncoder().encode(text)) ?? Data(#""""#.utf8), as: UTF8.self)
    }

    private func management(_ request: HTTPRequest, _ payload: String, authorized: Bool,
                            _ reply: (HTTPResponse.Status, String) -> (HTTPResponse, HTTPBody?)) -> (HTTPResponse, HTTPBody?)? {
        guard let path = request.path, request.method == .post || request.method == .get else { return nil }
        let routes = ["/donor/me/sessions", "/donor/logout-all", "/donor/me/email-change", "/donor/me/employer", "/donor/me/team",
                      "/donor/me/wallet"]
        let saveProfile = request.method == .post && path == "/donor/me/profile"
        guard saveProfile || routes.contains(where: { path.hasPrefix($0) }) else { return nil }
        guard authorized else { return reply(.unauthorized, "{}") }
        let fields = Self.object(payload)
        func sessions() -> String {
            let current = #"{"id":"11111111-1111-4111-8111-111111111111","client":"APP","platform":"IOS","label":"iPhone","created_at":"2026-10-01T10:00:00Z","last_used_at":"2026-10-30T10:00:00Z","current":true}"#
            return #"{"sessions":[\#(([current] + lock.withLock { otherSessions }).joined(separator: ","))]}"#
        }
        switch (request.method, path) {
        case (.post, "/donor/me/profile"):
            let zip = fields["zip"] as? String ?? "", city = fields["city"] as? String ?? "", phone = fields["phone"] as? String ?? ""
            guard zip.isEmpty || zip.range(of: "^[0-9]{5}(-[0-9]{4})?$", options: .regularExpression) != nil else { return reply(.unprocessableContent, "{}") }
            let zone = fields["timezone_override"] as? String
            guard zone == nil || StreakTimeZone.choices.contains(where: { $0.value == zone }) else { return reply(.unprocessableContent, "{}") }
            lock.withLock {
                contact = (zip, city, phone.isEmpty ? nil : phone)
                if let zone { timezoneOverride = zone.isEmpty ? nil : zone }
            }
            return reply(.ok, profile())
        case (.post, "/donor/me/email-change"):
            let email = fields["email"] as? String ?? ""
            if email.hasPrefix("taken") { return reply(.conflict, "{}") }
            return email.contains("@") ? reply(.ok, #"{"stage":"CURRENT"}"#) : reply(.unprocessableContent, "{}")
        case (.get, "/donor/me/wallet"): return reply(.ok, #"{"apple":true,"google":false}"#)
        // Not a signed pass, so Wallet refuses it and the screen must say so.
        case (.post, "/donor/me/wallet/apple"):
            return (HTTPResponse(status: .ok, headerFields: [.contentType: "application/vnd.apple.pkpass"]), HTTPBody("unsigned"))
        case (.get, "/donor/me/sessions"): return reply(.ok, sessions())
        case (.post, "/donor/me/sessions/revoke-others"):
            lock.withLock { otherSessions = [] }
            return reply(.ok, sessions())
        case (.post, _) where path.hasPrefix("/donor/me/sessions/") && path.hasSuffix("/revoke"):
            let id = path.dropFirst("/donor/me/sessions/".count).dropLast("/revoke".count)
            let removed = lock.withLock { () -> Bool in
                let before = otherSessions.count
                otherSessions.removeAll { $0.contains(#""id":"\#(id)""#) }
                return otherSessions.count < before
            }
            return removed ? reply(.ok, sessions()) : reply(.notFound, "{}")
        case (.post, "/donor/logout-all"):
            lock.withLock { otherSessions = [] }
            return reply(.ok, #"{"signed_out":true}"#)
        case (.get, "/donor/me/team"):
            let (org, name) = lock.withLock { (employer, team) }
            guard let org else { return reply(.ok, #"{"partner_id":"","organization":"","leaderboard":[]}"#) }
            let mine = name.map { #","team_id":"33333333-3333-4333-8333-333333333333","team_name":"\#($0)""# } ?? ""
            return reply(.ok, #"{"partner_id":"44444444-4444-4444-8444-444444444444","organization":"\#(org)"\#(mine),"leaderboard":[{"team_id":"55555555-5555-4555-8555-555555555555","name":"Design","metrics_verified":true,"active_givers":7,"annualized_minor":420000,"avg_streak_days":21,"volunteer_minutes":180}]}"#)
        case (.post, "/donor/me/employer"):
            guard fields["company_code"] as? String == "ACME42" else { return reply(.unprocessableContent, "{}") }
            lock.withLock { employer = "Acme" }
            return reply(.ok, #"{"organization":"Acme"}"#)
        case (.post, "/donor/me/team"):
            guard let name = fields["name"] as? String, !name.isEmpty, name.count <= 80, lock.withLock({ employer }) != nil else {
                return reply(.unprocessableContent, "{}")
            }
            lock.withLock { team = name }
            return reply(.ok, #"{"team_id":"33333333-3333-4333-8333-333333333333"}"#)
        default: return reply(.notFound, "{}")
        }
    }

    private func session() -> String {
        lock.withLock { generation += 1; return """
        {"access_token":"stub-access-\(generation)","expires_in":900,"refresh_token":"stub-refresh-\(generation)-xxxxxxxxxxxxxxxxxxxxxxxxxxxx","refresh_expires_in":5184000}
        """ }
    }

    private func profile() -> String {
        lock.withLock {
            let flags = prefs.map { "\"\($0.key)\":\($0.value)" }.sorted().joined(separator: ",")
            let zone = timezoneOverride.map { "\"\($0)\"" } ?? "null"
            let correction = timezoneOverride.map { ",\"timezone_override\":\"\($0)\"" } ?? ""
            let phone = contact.phone.map { "\"\($0)\"" } ?? "null"
            return "{\"email\":\"alex@example.org\",\"public_name\":\"Alex\",\"account_role\":\"DONOR\",\"zip\":\"\(contact.zip)\",\"city\":\"\(contact.city)\",\"timezone\":\(zone)\(correction),\"phone\":\(phone),\(flags),\"volunteer_interests\":[],\"version\":\(version),\"consent_version\":\"stub-v1\"}"
        }
    }

    private static let wrongCurrent = #"{"detail":"Current password is incorrect","code":"CURRENT_PASSWORD_INCORRECT"}"#
    private static let rejected = #"{"detail":"The email or password is incorrect"}"#

    private static func object(_ payload: String) -> [String: Any] {
        (payload.data(using: .utf8).flatMap { try? JSONSerialization.jsonObject(with: $0) } as? [String: Any]) ?? [:]
    }

    private static let reads = ["/donor/me/dashboard", "/donor/me/today-initiative", "/donor/me/gifts", "/donor/me/receipts/", "/donor/me/annual-summary/"]
    private static let giftTotal = 120
    private static let ready = #"{"state":"ready","mode":"test","computed_at":"2026-10-30T12:00:00Z","founding_donor":true,"referrals":{"currency":"USD","irl":1,"irl_minor":3000,"link":2,"link_minor":9000,"total_minor":12000},"streak":{"at_risk":false,"current":1,"grace_ends_at":null,"ladder":{"days":18,"last_milestone":7,"next_milestone":30,"days_to_next":12,"bar":[true,true,true,true,true,true,true,true,true,true,true,true,true,true,true,true,true,true,false,false,false,false,false,false,false,false,false,false,false,false]}},"rank":{"national_percentile":2,"city":"Austin","city_rank":4,"computed_at":"2026-10-30T00:00:00Z"},"rankings_opted_out":false,"network":{"active_count":3,"annualized_minor":474500,"currency":"USD"},"impact":{"given_minor":124000,"currency":"USD","initiatives_funded":4,"events_volunteered":2}}"#
    private static let readyOptedOut = #"{"state":"ready","mode":"test","computed_at":"2026-10-30T12:00:00Z","founding_donor":true,"referrals":{"currency":"USD","irl":1,"irl_minor":3000,"link":2,"link_minor":9000,"total_minor":12000},"streak":{"at_risk":false,"current":1,"grace_ends_at":null,"ladder":{"days":18,"last_milestone":7,"next_milestone":30,"days_to_next":12,"bar":[true,true,true,true,true,true,true,true,true,true,true,true,true,true,true,true,true,true,false,false,false,false,false,false,false,false,false,false,false,false]}},"rank":null,"rankings_opted_out":true,"network":{"active_count":3,"annualized_minor":474500,"currency":"USD"},"impact":{"given_minor":124000,"currency":"USD","initiatives_funded":4,"events_volunteered":2}}"#
    private static let unranked = #"{"state":"ready","mode":"test","computed_at":"2026-10-30T12:00:00Z","founding_donor":false,"referrals":null,"streak":null,"rank":null,"rankings_opted_out":true,"network":null,"impact":{"given_minor":null,"currency":"USD","initiatives_funded":0,"events_volunteered":0}}"#
    private static let today = #"{"initiative_id":"11111111-1111-4111-8111-111111111111","slug":"meals-on-wheels","title":"Meals on Wheels","summary":"Hot meals delivered to neighbours who cannot cook for themselves.","region":"TX","location":"Austin, TX","type":"PROGRAM","started_on":"2025-01-02","metrics":[{"label":"Meals this week","value":1200,"unit":"PEOPLE","verified_on":"2026-10-28"},{"label":"Cost per meal","value":425,"unit":"USD_CENTS","verified_on":"2026-10-28"},{"label":"Partners","value":1,"unit":"PARTNERS","verified_on":"2026-10-28"}],"distinct_shown":4}"#

    private static func giftID(_ index: Int) -> String { String(format: "00000000-0000-4000-8000-%012d", index) }
    private static func giftRecord(_ index: Int) -> String {
        let refunded = index % 7 == 0 ? 500 : 0
        let day = 28 - (index % 28)
        return #"{"id":"\#(giftID(index))","amount_minor":3000,"currency":"USD","paid_at":"2026-09-\#(String(format: "%02d", day))T10:00:00Z","frequency":"MONTHLY","refunded_minor":\#(refunded),"net_minor":\#(3000 - refunded),"refunds":[\#(refunded > 0 ? #"{"id":"re_\#(index)","amount_minor":500,"status":"succeeded","observed_at":"2026-09-29T10:00:00Z"}"# : "")]}"#
    }

    /// The first read of each kind fails under `.failFirst`, so the UITest sees the error and its retry.
    private func failsThisTime(_ key: String) -> Bool {
        lock.withLock { scenario == .failFirst && failuresServed.insert(key).inserted }
    }

    private func read(_ target: String, _ reply: (HTTPResponse.Status, String) -> (HTTPResponse, HTTPBody?)) -> (HTTPResponse, HTTPBody?) {
        let parts = target.split(separator: "?", maxSplits: 1).map(String.init)
        let path = parts[0]
        switch path {
        case "/donor/me/dashboard":
            if failsThisTime("dashboard") { return reply(.serviceUnavailable, #"{"detail":"unavailable"}"#) }
            switch scenario {
            case .empty: return reply(.ok, #"{"state":"preparing","mode":"test"}"#)
            case .unranked: return reply(.ok, Self.unranked)
            default: return reply(.ok, readyDashboard())
            }
        case "/donor/me/today-initiative":
            return scenario == .empty ? reply(.notFound, #"{"detail":"nothing in rotation"}"#) : reply(.ok, Self.today)
        case "/donor/me/gifts":
            if failsThisTime("gifts") { return reply(.serviceUnavailable, #"{"detail":"unavailable"}"#) }
            let offset = parts.count > 1 ? Int(parts[1].replacingOccurrences(of: "offset=", with: "")) ?? 0 : 0
            return reply(.ok, page(total: scenario == .empty ? 0 : Self.giftTotal, offset: offset))
        case _ where path.hasPrefix("/donor/me/receipts/"):
            let id = String(path.dropFirst("/donor/me/receipts/".count))
            guard scenario != .empty, let index = Self.giftIndex(id) else { return reply(.notFound, #"{"detail":"not found"}"#) }
            return reply(.ok, #"{"mode":"test","tax_receipt":false,"as_of":"2026-10-30T00:00:00Z","receipt_id":"rcpt-\#(index)","gift":\#(Self.giftRecord(index))}"#)
        case _ where path.hasPrefix("/donor/me/annual-summary/"):
            if scenario == .empty { return reply(.notFound, #"{"detail":"no gifts"}"#) }
            return reply(.ok, #"{"mode":"test","tax_receipt":false,"year":2026,"timezone":"America/Chicago","as_of":"2026-10-30T00:00:00Z","gifts":[\#(Self.giftRecord(0))],"amount_minor":360000,"refunded_minor":8500,"net_minor":351500,"currency":"USD"}"#)
        default:
            return reply(.notFound, #"{"detail":"not found"}"#)
        }
    }

    private func page(total: Int, offset: Int) -> String {
        let end = min(offset + 50, total)
        let rows = (offset..<max(offset, end)).map(Self.giftRecordSummary).joined(separator: ",")
        return #"{"email":"alex@example.org","mode":"test","gifts":[\#(rows)],"next_offset":\#(end < total ? String(end) : "null")}"#
    }

    private static func giftIndex(_ id: String) -> Int? {
        guard id.hasPrefix("00000000-0000-4000-8000-"), let n = Int(id.suffix(12)), n >= 0, n < giftTotal else { return nil }
        return n
    }

    private static func giftRecordSummary(_ index: Int) -> String {
        let refunded = index % 7 == 0 ? 500 : 0
        let day = 28 - (index % 28)
        return #"{"id":"\#(giftID(index))","amount_minor":3000,"currency":"USD","frequency":"MONTHLY","paid_at":"2026-09-\#(String(format: "%02d", day))T10:00:00Z","refunded_minor":\#(refunded),"net_minor":\#(3000 - refunded)}"#
    }

    func send(_ request: HTTPRequest, body: HTTPBody?, baseURL: URL, operationID: String) async throws -> (HTTPResponse, HTTPBody?) {
        var payload = ""
        if let body { payload = try await String(collecting: body, upTo: 262_144) }
        let authorized = request.headerFields[.authorization].map { $0.hasPrefix("Bearer stub-access-") } ?? false
        let isDeleted = lock.withLock { deleted }
        func reply(_ status: HTTPResponse.Status, _ json: String = "{}") -> (HTTPResponse, HTTPBody?) {
            // Every non-2xx body is the contract's Problem object, which requires `detail`.
            let body = status.code >= 400 && json == "{}" ? #"{"detail":"stub"}"# : json
            return (HTTPResponse(status: status, headerFields: [.contentType: "application/json"]), HTTPBody(body))
        }
        if let response = giving(request, payload, authorized: authorized, reply) { return response }
        if let response = events(request, payload, authorized: authorized, reply) { return response }
        if let response = engagement(request, payload, authorized: authorized, reply) { return response }
        if let response = management(request, payload, authorized: authorized && !isDeleted, reply) { return response }
        if let response = partner(request, payload, reply) { return response }
        switch (request.method, request.path ?? "") {
        case (.post, "/analytics/events"):
            return reply(.ok, #"{"accepted":\#(payload.components(separatedBy: #""name""#).count - 1)}"#)
        case (.post, let path) where path.hasPrefix("/donor/referrals/") || path.hasPrefix("/donor/company/"):
            let referral = path.hasPrefix("/donor/referrals/")
            let code = String(path.split(separator: "/").last ?? "")
            let kept = Self.object(payload)["token"] as? String
            let token = code == (referral ? "ALEX42" : "ACME42") ? (referral ? Self.referralToken : Self.companyToken) : kept
            let tokenJSON = token.map { "\"\($0)\"" } ?? "null"
            return referral
                ? reply(.ok, #"{"captured":\#(token != nil),"public_name":\#(token == nil ? "null" : "\"Alex R\""),"token":\#(tokenJSON)}"#)
                : reply(.ok, #"{"captured":\#(token != nil),"token":\#(tokenJSON)}"#)
        case (.post, "/donor/me/company-touch"):
            guard authorized, !isDeleted else { return reply(.unauthorized) }
            let bound = Self.object(payload)["token"] as? String == Self.companyToken
            if bound { lock.withLock { employer = employer ?? "Acme" } }
            return reply(.ok, #"{"bound":\#(bound)}"#)
        case (.post, "/donor/me/push-device"):
            return authorized ? reply(.ok, #"{"registered":true,"platform":"IOS","environment":"SANDBOX"}"#) : reply(.unauthorized)
        case (.post, "/donor/phone/sign-in/options"): return reply(.ok, #"{"sent":true}"#)
        case (.post, "/donor/phone/sign-in"):
            if payload.contains("\"123456\"") { return reply(.ok, session()) }
            if payload.contains("\"000000\"") { return reply(.tooManyRequests) }
            return reply(.unauthorized)
        case (.post, "/donor/signup"):
            let fields = Self.object(payload)
            guard let email = fields["email"] as? String, email.contains("@"), (fields["name"] as? String)?.isEmpty == false else {
                return reply(.unprocessableContent)
            }
            return email.hasPrefix("throttled") ? reply(.tooManyRequests) : reply(.ok, #"{"sent":true}"#)
        case (.post, "/donor/login"):
            let fields = Self.object(payload)
            guard let email = fields["email"] as? String, email.contains("@"), fields.count == 1 else { return reply(.unprocessableContent) }
            return email.hasPrefix("throttled") ? reply(.tooManyRequests) : reply(.accepted, #"{"message":"stub"}"#)
        case (.post, "/donor/claim"):
            let token = Self.object(payload)["token"] as? String ?? ""
            return token.hasPrefix("stubclaim") ? reply(.ok, session()) : reply(.unauthorized)
        case (.post, "/donor/password/sign-in"):
            let password = Self.object(payload)["password"] as? String ?? ""
            if password == "throttled password" { return reply(.tooManyRequests) }
            return password == lock.withLock({ storedPassword }) ? reply(.ok, session()) : reply(.unauthorized, Self.rejected)
        case (.post, "/donor/me/password"):
            guard authorized, !isDeleted else { return reply(.unauthorized) }
            let fields = Self.object(payload)
            let new = fields["password"] as? String ?? ""
            guard (12...72).contains(new.utf8.count) else { return reply(.unprocessableContent) }
            if let current = fields["current_password"] as? String, current != lock.withLock({ storedPassword }) {
                return reply(.unprocessableContent, Self.wrongCurrent)
            }
            lock.withLock { storedPassword = new }
            return reply(.ok, #"{"saved":true}"#)
        case (.post, "/donor/refresh"): return isDeleted ? reply(.unauthorized) : reply(.ok, session())
        case (.get, "/donor/me/profile"): return authorized && !isDeleted ? reply(.ok, profile()) : reply(.unauthorized)
        case (.post, "/donor/me/preferences"):
            guard authorized, !isDeleted else { return reply(.unauthorized) }
            guard let data = payload.data(using: .utf8), let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                return reply(.unprocessableContent)
            }
            // `rankingToggleFails`: a change to the rankings choice is refused, so the screen must revert.
            if engagementScenario == .rankingToggleFails, let wanted = object["rankings_opted_out"] as? Bool,
               wanted != lock.withLock({ prefs["rankings_opted_out"] }) {
                return reply(.serviceUnavailable, #"{"detail":"unavailable"}"#)
            }
            lock.withLock {
                for (key, value) in object { if let flag = value as? Bool { prefs[key] = flag } }
                version += 1
            }
            return reply(.ok, profile())
        case (.post, "/donor/me/delete"):
            guard authorized, !isDeleted else { return reply(.unauthorized) }
            // 409 while a checkout is open (`deletionBlocked`) or a monthly gift is still set to renew.
            if deletionBlocked || lock.withLock({ giftAmount != nil && !giftEnding }) { return reply(.conflict) }
            lock.withLock { deleted = true }
            return reply(.ok, #"{"deleted":true}"#)
        case (.post, "/donor/logout"): return reply(.ok, #"{"signed_out":true}"#)
        case (.get, let path) where path.hasPrefix("/donor/me/") && Self.reads.contains(where: { path.hasPrefix($0) }):
            guard authorized, !isDeleted else { return reply(.unauthorized) }
            return read(path, reply)
        default: return reply(.notFound)
        }
    }
}
#endif
