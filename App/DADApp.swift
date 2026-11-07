import SwiftUI
import DADFoundation
import SafariServices
import CryptoKit
import UserNotifications

/// Preview/UITest launch switches exist only in DEBUG builds: a release binary ignores them, so a
/// shipped app can never be steered into synthetic data or a canned screen by launch arguments.
func launchFlag(_ name: String) -> Bool {
    #if DEBUG
    ProcessInfo.processInfo.arguments.contains(name)
    #else
    false
    #endif
}

/// The value of a `--name=value` launch argument, DEBUG only.
func launchValue(_ name: String) -> String? {
    #if DEBUG
    let prefix = name + "="
    return ProcessInfo.processInfo.arguments.first { $0.hasPrefix(prefix) }.map { String($0.dropFirst(prefix.count)) }
    #else
    nil
    #endif
}

func tokenColor(_ name: String) -> Color { Color.dad(name) }

struct AppBackground: ViewModifier {
    @Environment(\.colorScheme) private var scheme
    func body(content: Content) -> some View { content.background(tokenColor(scheme == .dark ? "ink-deep" : "paper")) }
}

#if DEBUG
private final class PreviewStore: CredentialStore, @unchecked Sendable {
    private let lock = NSLock()
    private var value: Credentials?
    init(signedIn: Bool = true) {
        value = signedIn ? Credentials(access: "preview", refresh: "preview-refresh", expiresAt: .distantFuture) : nil
    }
    func load() throws -> Credentials? { lock.withLock { value } }
    func save(_ credentials: Credentials) throws { lock.withLock { value = credentials } }
    func clear() throws { lock.withLock { value = nil } }
}
#endif

#if DEBUG
private actor PreviewAPI: AccountAPI {
    private var failFirst: Bool
    init(failFirst: Bool) { self.failFirst = failFirst }
    func profile(access: String) async throws -> AccountProfile {
        try await Task.sleep(for: .milliseconds(250))
        if failFirst { failFirst = false; throw AccountError.unavailable }
        return AccountProfile(email: "alex@example.org", publicName: "Alex")
    }
    func refresh(token: String) async throws -> Credentials { throw AccountError.signedOut }
    func claim(token: String) async throws -> Credentials { throw AccountError.unavailable }
    func logout(access: String) async throws {}
}
#endif

@MainActor @Observable
final class AccountModel {
    enum State: Equatable { case loading, ready(AccountProfile), unavailable, signedOut }
    var state = State.loading
    let session: AccountSession?
    /// Sign-in transport for the unauthenticated stack: the real `WireAuth` against a configured
    /// origin, the scripted stub under `--stub-backend`, or a DEBUG preview double. Never a preview in Release.
    private(set) var kit = SignInKit.unconfigured
    private var settingsService: (any AccountSettingsService)?
    /// Set/change password in Settings; nil in previews, where there is no real account to change.
    private(set) var passwordSettings: (any PasswordSettingsService)?
    /// Contact details, account email, sessions and employer in Settings; nil in previews.
    private(set) var management: (any AccountManagementService)?
    /// Donor-home reads (dashboard, today's initiative, gift history): real `WireDashboard` or the
    /// scripted stub; nil in the synthetic DEBUG preview, which has no account to read.
    private(set) var dashboardService: (any DashboardService)?
    /// Giving (recurring gift, amount, payment method, cancel): real `WireGiving` or the scripted stub; nil in previews.
    private(set) var givingKit: GivingKit?
    /// Events (list, reserve, cancel, check-in, calendar): real `WireEvents` or the scripted stub; nil in previews.
    private(set) var eventsService: (any EventsService)?
    private(set) var engagementService: (any EngagementService)?
    /// The referral code as an Apple Wallet pass; nil in previews.
    private(set) var walletService: (any WalletPassService)?
    /// The partner portal under its own 12-hour session; nil when this build cannot reach DAD.
    private(set) var partnerService: (any PartnerService)?
    private(set) var partnerSignIn: (any PartnerSignInService)?
    /// The partner application's status, read with a stored receipt; nil in previews.
    private(set) var applicationStatus: (any ApplicationStatusService)?
    /// Submits a partner application and keeps its receipt; nil in previews, which fall back to the website.
    private(set) var applicationSubmit: (any PartnerApplicationService)?
    private var partnerSession: PartnerSession?
    /// The public site, for links the app hands out (the partner's company sign-up link).
    private(set) var publicOrigin: URL?
    /// A tapped partner sign-in link waiting for the partner sign-in screen to accept it.
    var pendingPartnerToken: String?
    /// Opt-in usage analytics; nil in the synthetic preview, which never sends anything.
    private(set) var analytics: AnalyticsController?
    private var donorPush: (any DonorPushService)?
    /// The device token last registered for the current donor session.
    private var registeredPush: String?
    /// A screen a tapped notification or link asked for, opened by the donor shell once signed in.
    var destination: AccountDestination?
    /// A user-facing line for the unauthenticated screen: a failed sign-in link or a build that has
    /// no API origin configured (never silently synthetic data).
    var notice: String?
    /// "<name> invited you", after an invite link was opened before sign-in.
    var invitation: String?
    /// Referral and company-code link visits, kept and spent as the website's cookies are; nil in the preview.
    private var linkAttribution: LinkAttribution?
    private var completedProof: String?
    private var activeProof: String?
    private var gate = NavigationGate()
    private var generation = 0
    private let router: LinkRouter?
    let preview: Bool
    /// Whether a session object exists. A `.unavailable`/`.signedOut` state with a session
    /// present is a transient sub-state of the donor shell (recoverable via "Try again"),
    /// NOT a reason to leave for the role-select splash — only a session-less app goes there.
    var hasSession: Bool { session != nil }
    /// A session whose credentials were found on launch: the donor shell (and its own loading and
    /// recovery states) is the right place to wait. A session with nothing stored goes straight to sign-in.
    var hasRestorableSession: Bool { session?.restoredCredentials == true }
    var isReady: Bool { if case .ready = state { true } else { false } }
    func makeSettings() -> (any AccountSettingsService)? { settingsService }
    func hasPartnerSession() async -> Bool { await partnerSession?.isSignedIn ?? false }
    /// Runs sign-in verification INSIDE the session so it owns the await and the epoch guard.
    func establish() -> PhoneSignInModel.Establish {
        guard let session else { return { _ in throw AccountError.invalidConfiguration } }
        return { produce in try await session.establish(produce) }
    }
    init() {
        let apiOrigin = Bundle.main.object(forInfoDictionaryKey: "DADAPIOrigin") as? String ?? ""
        #if DEBUG
        preview = apiOrigin.isEmpty && !launchFlag("--stub-backend")
        #else
        preview = false
        #endif
        #if DEBUG
        let stubRouter = launchFlag("--stub-backend") ? try? LinkRouter(publicOrigin: StubBackend.origin) : nil
        #else
        let stubRouter: LinkRouter? = nil
        #endif
        let configuredPublicOrigin = (Bundle.main.object(forInfoDictionaryKey: "DADPublicOrigin") as? String).flatMap(URL.init(string:))
        router = stubRouter ?? configuredPublicOrigin.flatMap { try? LinkRouter(publicOrigin: $0) }
        publicOrigin = stubRouter == nil ? configuredPublicOrigin : StubBackend.origin
        #if DEBUG
        if preview {
            partnerSignIn = PreviewPartnerSignIn()
            partnerService = PreviewPartner(role: launchFlag("--preview-partner-viewer") ? .viewer : .admin)
        }
        #endif
        #if DEBUG
        if launchFlag("--stub-backend") {
            // The REAL conformers (WireAuth, WireAPI, WireAccountSettings, AccountSession) run on a
            // scripted in-process transport: UITests exercise release code paths with no network.
            do {
                let scenario: StubBackend.Scenario = launchFlag("--stub-dashboard-empty") ? .empty
                    : launchFlag("--stub-dashboard-fail-first") ? .failFirst
                    : launchFlag("--stub-dashboard-unranked") ? .unranked : .populated
                let gift: StubBackend.GiftScenario = launchFlag("--stub-gift-fail-first") ? .activeFailFirst
                    : launchFlag("--stub-gift-active") ? .active : .none
                let eventScenario: StubBackend.EventsScenario = launchFlag("--stub-events-ungated") ? .ungated
                    : launchFlag("--stub-events-fail-first") ? .failFirst : .standard
                let engagementScenario: StubBackend.EngagementScenario = launchFlag("--stub-rankings-fail-toggle") ? .rankingToggleFails
                    : launchFlag("--stub-no-public-name") ? .noPublicName : launchFlag("--stub-badges-down") ? .badgesDown : .standard
                let services = try StubBackend.make(deletionBlocked: launchFlag("--stub-delete-blocked"), scenario: scenario, gift: gift,
                                                    events: eventScenario, engagement: engagementScenario,
                                                    signedIn: launchFlag("--stub-signed-in"),
                                                    partnerSignedIn: launchFlag("--stub-partner-signed-in"),
                                                    partnerViewer: launchFlag("--stub-partner-viewer"),
                                                    application: ["pending": "PENDING", "approved": "APPROVED", "rejected": "REJECTED",
                                                                  "unknown": "UNDER_REVIEW"].first { launchFlag("--stub-application-\($0.key)") }?.value,
                                                    applicationSubmit: launchFlag("--stub-apply-invalid") ? .invalid
                                                        : launchFlag("--stub-apply-throttled") ? .throttled
                                                        : launchFlag("--stub-apply-fails-first") ? .failsFirst : .accepts,
                                                    onLocalWipe: { Self.wipeAttribution(linkTokens: StubBackend.linkTokensKey) })
                session = services.session
                kit = SignInKit(phone: services.signIn, signup: services.credentialAuth, link: services.credentialAuth,
                                password: services.credentialAuth,
                                oidc: nil, passkey: nil, capabilities: .none)
                settingsService = services.settings
                passwordSettings = services.passwords
                management = services.management
                dashboardService = services.dashboard
                eventsService = services.events
                engagementService = services.engagement
                walletService = services.wallet
                partnerService = services.partner
                partnerSignIn = services.partnerAuth
                applicationStatus = services.applicationStatus
                applicationSubmit = services.applicationSubmit
                partnerSession = services.partnerSession
                givingKit = GivingKit(service: services.giving, stubComplete: services.completeHandoff, pollDelay: .milliseconds(200))
                donorPush = services.push
                installAnalytics(AnalyticsController(consent: MemoryAnalyticsConsent(choice: launchFlag("--stub-analytics-unset") ? nil : false),
                                                     sink: services.analyticsSink))
                // Each stub launch starts as a fresh install: no link visit kept from an earlier run.
                DefaultsLinkTokenStore(key: StubBackend.linkTokensKey).clear()
                installLinkAttribution(services.linkAttribution, store: DefaultsLinkTokenStore(key: StubBackend.linkTokensKey))
                state = .loading
            } catch { session = nil; state = .unavailable }
            return
        }
        // A session-less launch (no stored credentials) lands on role-select + the auth shell;
        // the preview normally starts signed-in, so this path is opt-in for the auth journey/UITest.
        if launchFlag("--preview-signed-out") {
            session = try? AccountSession(api: PreviewAPI(failFirst: false), store: PreviewStore(signedIn: false))
            kit = .preview
            if let session { settingsService = PreviewSessionSettings(session: session) }
            state = .signedOut
            return
        }
        #endif
        do {
            if apiOrigin.isEmpty {
                // The synthetic (PreviewAPI/PreviewStore) path must NEVER ship in a release build —
                // an empty origin there is a misconfiguration, not a demo mode, and falling back
                // would serve synthetic data as if real. Compile it only into DEBUG; a release
                // build with an empty origin is a hard configuration failure.
                #if DEBUG
                let built = try AccountSession(api: PreviewAPI(failFirst: launchFlag("--preview-unavailable")), store: PreviewStore())
                kit = .preview
                settingsService = PreviewSessionSettings(session: built)
                session = built
                #else
                throw AccountError.invalidConfiguration
                #endif
            } else {
                guard let origin = URL(string: apiOrigin) else { throw AccountError.invalidConfiguration }
                // Namespace the keychain by the running bundle id so the release
                // (org.dad.foundation) and debug (.debug) builds never share a
                // credential bucket, and the name tracks the id automatically.
                let service = Bundle.main.bundleIdentifier ?? "org.dad.foundation"
                let built = try AccountSession(api: WireAPI(origin: origin), store: KeychainStore(service: service))
                let auth = try WireAuth(origin: origin, deviceName: UIDevice.current.name)
                let credentialAuth = try WireCredentialAuth(origin: origin, deviceName: UIDevice.current.name)
                let settings = try WireAccountSettings(origin: origin, session: built, onLocalWipe: { Self.wipeAttribution() })
                // Apple, Google and passkeys stay off until the owner supplies their build settings.
                let capabilities = SignInCapabilities(config: SignInConfig(
                    appleFlag: Bundle.main.object(forInfoDictionaryKey: "DADAppleSignInEnabled") as? String,
                    googleClientID: Bundle.main.object(forInfoDictionaryKey: "DADGoogleClientID") as? String,
                    passkeyRelyingParty: Bundle.main.object(forInfoDictionaryKey: "DADPasskeyRelyingParty") as? String))
                kit = SignInKit(phone: auth, signup: credentialAuth, link: credentialAuth, password: credentialAuth,
                                oidc: capabilities.apple || capabilities.google ? credentialAuth : nil,
                                passkey: capabilities.passkey ? credentialAuth : nil, capabilities: capabilities,
                                passkeyRelyingParty: (Bundle.main.object(forInfoDictionaryKey: "DADPasskeyRelyingParty") as? String) ?? "")
                settingsService = settings
                passwordSettings = try WirePasswordSettings(origin: origin, session: built)
                management = try WireAccountManagement(origin: origin, session: built)
                dashboardService = try WireDashboard(origin: origin, session: built)
                givingKit = GivingKit(service: try WireGiving(origin: origin, session: built,
                                                              referral: { DefaultsLinkTokenStore().load().referral }))
                eventsService = try WireEvents(origin: origin, session: built)
                engagementService = try WireEngagement(origin: origin, session: built)
                walletService = try WireWalletPass(origin: origin, session: built)
                let partner = try PartnerSession(store: KeychainStore(service: service, account: "partner-session"))
                partnerSignIn = try WirePartnerAuth(origin: origin, session: partner)
                // One Keychain item holds the application receipt: the submission writes it, the status read uses it.
                let receipt = KeychainStore(service: service, account: "partner-application-receipt")
                applicationStatus = try WireApplicationStatus(origin: origin, receipt: receipt)
                applicationSubmit = try WirePartnerApplication(origin: origin, receipt: receipt)
                partnerService = try WirePartner(origin: origin, session: partner)
                partnerSession = partner
                donorPush = try WireDonorPush(origin: origin, session: built)
                let analyticsSink = try WireAnalytics(origin: origin, access: { try? await built.accessToken() })
                let links = try WireLinkAttribution(origin: origin, session: built)
                session = built
                installAnalytics(AnalyticsController(consent: DefaultsAnalyticsConsent(), sink: analyticsSink))
                installLinkAttribution(links, store: DefaultsLinkTokenStore())
            }
        } catch {
            session = nil
            state = .unavailable
            notice = "This build isn’t configured to reach DAD. Install a build with a valid API origin."
        }
    }
    private func installAnalytics(_ controller: AnalyticsController) {
        analytics = controller
        AnalyticsObservation.shared.install { controller.emit($0) }
    }
    private func installLinkAttribution(_ service: any LinkAttributionService, store: any LinkTokenStore) {
        let analytics = analytics
        linkAttribution = LinkAttribution(service: service, store: store) { analytics?.emit(.attributionCaptured, properties: ["source": $0]) }
    }
    /// Account deletion forgets where this install came from, link tokens included.
    private nonisolated static func wipeAttribution(linkTokens key: String = "org.dad.link-tokens") {
        DefaultsAttributionStore().clear()
        DefaultsLinkTokenStore(key: key).clear()
    }
    func load() async {
        guard let session else { state = .unavailable; return }
        generation += 1
        let current = generation
        state = .loading
        do {
            let profile = try await session.profile()
            if current == generation {
                state = .ready(profile)
                invitation = nil
                if let pending = gate.signedIn() { destination = pending }
                if let linkAttribution { Task { await linkAttribution.bindCompany() } }
            }
        }
        catch is CancellationError { return }
        catch AccountError.signedOut { if current == generation { state = .signedOut; registeredPush = nil } }
        catch { if current == generation { state = .unavailable } }
    }

    /// Best-effort, once per token and donor session: platforms rotate tokens, so the server wants every launch.
    func registerPush(_ token: String?) async {
        guard let token, let donorPush, case .ready = state, registeredPush != token else { return }
        registeredPush = token
        do { try await donorPush.register(token: token, environment: .ofThisBuild) } catch { registeredPush = nil }
    }

    /// A tapped notification: counted (`push_opened`), then its screen is opened, after sign-in if need be.
    func openNotification(_ tap: PushTap) {
        analytics?.emit(.pushOpened, properties: ["type": tap.category])
        guard let path = tap.path, let target = router?.notification(path: path) else { return }
        let signedIn: Bool
        if case .ready = state { signedIn = true } else { signedIn = false }
        if let now = gate.receive(target, signedIn: signedIn) { destination = now }
    }
    /// A sign-in link pasted from the "check your email" screen (the email may have been opened on
    /// another device or in a browser). A claim link, including its supported return path, goes through the
    /// same single-use proof exchange as a tapped link. Returns false when the text is not one.
    func openPastedLink(_ text: String) -> Bool {
        guard let url = URL(string: text.trimmingCharacters(in: .whitespacesAndNewlines)),
              let intent = router?.route(url), case .claim = intent else { return false }
        notice = nil
        return receive(url, role: nil) == nil
    }

    /// Routes a tapped link for the signed-in `role` (nil before sign-in); returns a URL for the web
    /// fallback when the app does not handle it here.
    func receive(_ url: URL, role: AppRole?) -> URL? {
        guard let intent = router?.route(url) else { return nil }
        switch intent {
        case .partnerSignIn(let token):
            // A partner already in the portal stays put; a donor's app cannot also be a partner's, so the
            // website takes the link.
            switch role {
            case nil: pendingPartnerToken = token; return nil
            case .partner: return nil
            case .donor: return url
            }
        case .account(let target):
            if role == .partner { return url }
            let signedIn: Bool
            if case .ready = state { signedIn = true } else { signedIn = false }
            if let now = gate.receive(target, signedIn: signedIn) { destination = now }
            Task { await load() }
            return nil
        case .referral(let code, let inPerson):
            guard let linkAttribution else { return url }
            Task {
                let name = await linkAttribution.captureReferral(code: code, inPerson: inPerson)
                if let name, !isReady { invitation = "\(name) invited you to give with DAD." }
            }
            return nil
        case .company(let code):
            guard let linkAttribution else { return url }
            Task {
                await linkAttribution.captureCompany(code: code)
                if isReady { await linkAttribution.bindCompany() }
            }
            return nil
        case .claim(let token, let next):
            if role == .partner { return url }
            guard let session, !preview else { return url }
            let digest = SHA256.hash(data: Data(token.utf8)).map { String(format: "%02x", $0) }.joined()
            guard activeProof == nil, completedProof != digest else { return nil }
            activeProof = digest
            if let next { _ = gate.receive(next, signedIn: false) }
            generation += 1
            state = .loading
            Task {
                defer { activeProof = nil }
                do {
                    try await session.claim(token: token)
                    completedProof = digest
                    await load()
                } catch {
                    if await session.isSignedIn { state = .unavailable }
                    else {
                        state = .signedOut
                        notice = "That sign-in link didn’t work. It may have expired — request a new one."
                    }
                }
            }
            return nil
        default: return url
        }
    }
}

private struct PushRegistrationKey: Equatable { let token: String?; let ready: Bool }

private struct WebDestination: Identifiable { let id = UUID(); let url: URL }
private struct WebFallback: UIViewControllerRepresentable {
    let url: URL
    func makeUIViewController(context: Context) -> SFSafariViewController { SFSafariViewController(url: url) }
    func updateUIViewController(_ controller: SFSafariViewController, context: Context) {}
}

#if DEBUG
/// Preview sign-in transport — returns a handle and preview credentials so the auth journey
/// runs in the simulator with no backend. The wire implementation replaces this once the
/// phone/OIDC endpoints are consumed; the screens bind to the protocol, not this type.
// Internal (not file-private) so SignInKit.preview in the extracted App/Welcome.swift can see it.
actor PreviewSignIn: SignInService, SignupService, SignInLinkService, PasswordSignInService {
    func requestSignup(_ form: SignupForm) async throws { try await Task.sleep(for: .milliseconds(150)) }
    func requestSignInLink(email: String) async throws { try await Task.sleep(for: .milliseconds(150)) }
    func signIn(email: String, password: String) async throws -> Credentials {
        try await Task.sleep(for: .milliseconds(150))
        return Credentials(access: "preview", refresh: "preview-refresh", expiresAt: .distantFuture)
    }
    func requestPhoneCode(phone: String) async throws -> String {
        try await Task.sleep(for: .milliseconds(150))
        return "preview-handle"
    }
    func verifyPhone(handle: String, code: String) async throws -> Credentials {
        try await Task.sleep(for: .milliseconds(150))
        return Credentials(access: "preview", refresh: "preview-refresh", expiresAt: .distantFuture)
    }
}
#endif

#if DEBUG
/// Preview giving transport — an in-memory recurring gift so the Phase C giving journey runs
/// in the simulator with no backend. The wire implementation (mapping the generated giving
/// client) replaces this; the screens bind to the `GivingService` protocol, not this type.
private actor PreviewGiving: GivingService {
    private var state: RecurringState
    init(state: RecurringState = .active(subscriptionID: "preview-sub", amountMinor: 3000, periodEnd: Date().addingTimeInterval(14 * 86_400))) {
        self.state = state
    }
    func recurring() async throws -> RecurringState { state }
    func changeAmount(subscriptionID: String, to amountMinor: Int) async throws -> RecurringState {
        if case let .active(id, _, end) = state { state = .active(subscriptionID: id, amountMinor: amountMinor, periodEnd: end) }
        return state
    }
    func cancel(subscriptionID: String, periodEnd: Date) async throws -> RecurringState {
        if case let .active(id, amount, end) = state { state = .ending(subscriptionID: id, amountMinor: amount, periodEnd: end, stopsAt: periodEnd) }
        return state
    }
    func beginPayment() async throws -> PaymentPath {
        .webCheckoutHandoff(URL(string: "https://give.example.org/setup")!)
    }
    func amountOffer() async throws -> AmountOffer? { nil }
    func paymentMethod() async throws -> PaymentMethodState { PaymentMethodState(kind: .none) }
    func beginGift(amountMinor: Int) async throws -> PaymentPath { .webCheckoutHandoff(URL(string: "https://give.example.org/checkout")!) }
}
#endif

#if DEBUG
private actor PreviewEngagement: EngagementService {
    private var optedIn: Bool
    init(optedIn: Bool = true) { self.optedIn = optedIn }

    private func currentRanking() -> RankingStanding {
        optedIn
            ? RankingStanding(nationalPercentile: 2, city: "Austin", cityRank: 4)
            : RankingStanding(nationalPercentile: nil, city: nil, cityRank: nil, rankingsOptedOut: true)
    }

    func snapshot() async throws -> EngagementSnapshot {
        EngagementSnapshot(
            impact: ImpactTotals(givenMinor: 124_000, initiativesFunded: 3, eventsVolunteered: 2),
            badges: BadgeCollection(badges: [
                Badge(code: "F", title: "Founding Donor", rule: "Start a monthly gift before January 2027, or join the website waitlist", perk: Badge.perkCopy(forKey: "FOUNDING_EVENTS"), earned: true),
                Badge(code: "7", title: "One Week", rule: "Reach a 7-day streak", perk: "", earned: true),
                Badge(code: "1K", title: "1,000 Days", rule: "Reach a 1,000-day streak", perk: Badge.perkCopy(forKey: "MILESTONE_EVENTS"), earned: false),
            ]),
            ranking: currentRanking(),
            network: NetworkSummary(activeCount: 6, annualizedMinor: 72_000, anonymousActive: 2),
            referral: ReferralInfo(code: "SHAWN42", linkCount: 4, irlCount: 2,
                                   conversions: [Conversion(convertedAt: Date().addingTimeInterval(-86_400), kind: .link)])
        )
    }

    func setRankingOptIn(_ optIn: Bool) async throws -> RankingStanding {
        optedIn = optIn
        return currentRanking()
    }

    func choosePublicName(_ name: String) async throws {}

    func initiativeSpend(id: String) async throws -> InitiativeSpendSummary {
        InitiativeSpendSummary(initiativeID: id, totalMinor: 125_000, slices: [
            SpendSlice(category: "Food", amountMinor: 90_000), SpendSlice(category: "Delivery", amountMinor: 35_000)])
    }
}
#endif

// MARK: - Events preview + screen (Phase E)

#if DEBUG
/// Preview double for the events service. One reservable public event, one full event (waitlist),
/// and one invite-only event, so the list/detail/reserve path is exercised without a network.
private actor PreviewEvents: EventsService {
    private var store: [String: DonorEvent]

    init() {
        let soon = Date().addingTimeInterval(60 * 60 * 24 * 7)
        let events = [
            DonorEvent(id: "e1", slug: "park-cleanup", title: "Park Cleanup", type: "volunteer", venue: "Zilker Park",
                       city: "Austin", startsAt: soon, endsAt: soon.addingTimeInterval(7200), capacity: 50, spotsLeft: 8,
                       status: .none, reportIssueURL: "mailto:help@dad.org"),
            DonorEvent(id: "e2", slug: "food-bank", title: "Food Bank Night", type: "volunteer", venue: "Central Kitchen",
                       city: "Austin", startsAt: soon.addingTimeInterval(86400), endsAt: soon.addingTimeInterval(86400 + 7200),
                       capacity: 30, spotsLeft: 0, status: .none, reportIssueURL: "mailto:help@dad.org"),
            DonorEvent(id: "e3", slug: "founders-dinner", title: "Founders Dinner", type: "social", venue: "The Loft",
                       city: "Austin", startsAt: soon.addingTimeInterval(2 * 86400), endsAt: soon.addingTimeInterval(2 * 86400 + 7200),
                       capacity: 20, spotsLeft: 5, status: .none, invitationNote: "Founding donors only",
                       reportIssueURL: "mailto:help@dad.org"),
        ]
        store = Dictionary(uniqueKeysWithValues: events.map { ($0.id, $0) })
    }

    func events() async throws -> [DonorEvent] { store.values.sorted { $0.startsAt < $1.startsAt } }
    func event(id: String) async throws -> DonorEvent {
        guard let event = store[id] else { throw AccountError.unavailable }
        return event
    }

    func reserve(eventID: String) async throws -> ReservationOutcome {
        guard let event = store[eventID] else { return .reserved }
        let outcome: ReservationOutcome = event.spotsLeft > 0 ? .reserved : .waitlisted
        store[eventID] = DonorEvent(
            id: event.id, slug: event.slug, title: event.title, type: event.type, venue: event.venue, city: event.city,
            startsAt: event.startsAt, endsAt: event.endsAt, capacity: event.capacity,
            spotsLeft: max(0, event.spotsLeft - 1), status: outcome == .reserved ? .reserved : .waitlisted,
            invitationNote: event.invitationNote, reportIssueURL: event.reportIssueURL, cancelled: event.cancelled,
            bookingOpensAt: event.bookingOpensAt, earlyBooking: event.earlyBooking)
        return outcome
    }

    func cancel(eventID: String) async throws {
        guard let event = store[eventID] else { return }
        store[eventID] = DonorEvent(
            id: event.id, slug: event.slug, title: event.title, type: event.type, venue: event.venue, city: event.city,
            startsAt: event.startsAt, endsAt: event.endsAt, capacity: event.capacity, spotsLeft: event.spotsLeft + 1,
            status: .none, invitationNote: event.invitationNote, reportIssueURL: event.reportIssueURL,
            cancelled: event.cancelled, bookingOpensAt: event.bookingOpensAt, earlyBooking: event.earlyBooking)
    }

    func checkIn(code: String) async throws -> CheckInResultValue {
        CheckInResultValue(eventID: "e1", checkedIn: true, alreadyCheckedIn: false)
    }

    func calendar(eventID: String) async throws -> Data {
        Data("BEGIN:VCALENDAR\r\nVERSION:2.0\r\nBEGIN:VEVENT\r\nSUMMARY:Preview event\r\nEND:VEVENT\r\nEND:VCALENDAR\r\n".utf8)
    }
}
#endif

#if DEBUG
/// In-memory partner service for the preview/UITest. `--preview-partner-viewer` loads as a VIEWER (read-only);
/// `--preview-partner` is an ADMIN portal with one verified and one unverified figure, an unsuppressed
/// workforce, and two users.
actor PreviewPartner: PartnerService {
    private let role: PartnerRole
    private var userList: [PartnerUser]
    private var organization = "Acme Corp"
    private var about = "Doing good together."
    private var workforce = 240
    private var savedLogo: Data?

    init(role: PartnerRole = .admin) {
        self.role = role
        userList = [
            PartnerUser(id: "u1", email: "ada@acme.com", name: "Ada Admin", role: .admin),
            PartnerUser(id: "u2", email: "val@acme.com", name: "Val Viewer", role: .viewer),
        ]
    }

    func overview() async throws -> PartnerOverview {
        PartnerOverview(
            organization: organization, description: about,
            userID: role == .admin ? "u1" : "u2", role: role, companyCode: "ACME",
            committed: VerifiedMoney(amountMinor: 5_000_000, verified: true),
            deployed: VerifiedMoney(amountMinor: 3_000_000, verified: false), // unverified -> hidden (§7.3)
            deployedPercent: 60,
            peopleReached: VerifiedCount(value: 12_400, verified: true),
            employeesEnrolled: 86, workforceSize: workforce, enrolledPercent: 35,
            updatedAt: Date(timeIntervalSince1970: 1_793_000_000), hasLogo: savedLogo != nil)
    }

    func initiatives() async throws -> [PartnerInitiative] {
        [PartnerInitiative(id: "i1", title: "Clean Water West", summary: "Wells across 6 counties.",
                           status: .active, region: "West", committedMinor: 2_000_000, deployedMinor: 1_200_000,
                           metrics: [PartnerMetric(label: "People reached", value: 8400, unit: .people),
                                     PartnerMetric(label: "Wells", value: 32, unit: .initiatives)])]
    }

    func spend() async throws -> [PartnerSpendCategory] {
        [PartnerSpendCategory(category: "Water", amountMinor: 1_800_000),
         PartnerSpendCategory(category: "Housing", amountMinor: 1_200_000)]
    }

    func people() async throws -> PartnerPeople {
        PartnerPeople(enrolled: 86, workforceSize: workforce, givenMinor: 940_000, matchedMinor: 470_000,
                      avgStreakDays: 42, volunteerMinutes: 6_300, teams: 7, suppressed: false)
    }

    func teams() async throws -> [TeamStanding] {
        [TeamStanding(id: "t1", name: "Engineering", activeGivers: 31, annualizedMinor: 1_200_000, avgStreakDays: 40, volunteerMinutes: 1_200)]
    }
    func users() async throws -> [PartnerUser] { userList }
    func inviteUser(email: String, name: String, role: PartnerRole) async throws {
        userList.append(PartnerUser(id: "u\(userList.count + 1)", email: email, name: name, role: role))
    }
    func removeUser(id: String) async throws { userList.removeAll { $0.id == id } }
    func saveProfile(organization: String, description: String) async throws {
        self.organization = organization
        about = description
    }
    func saveWorkforce(size: Int) async throws { workforce = size }
    func logo() async throws -> Data? { savedLogo }
    func saveLogo(png: Data?) async throws { savedLogo = png }
    func exports() async throws -> [PartnerExport] { [] }
    func report() async throws -> Data { Data("%PDF-1.4 preview".utf8) }
    func retainedReport(id: String) async throws -> Data { throw AccountError.notFound }
    func signOut() async throws {}
    func registerPushDevice(token: String, environment: PushEnvironment) async throws {}
    func unregisterPushDevice() async throws {}
}

/// Accepts any partner link, so the preview's partner sign-in journey runs with no backend.
actor PreviewPartnerSignIn: PartnerSignInService {
    func requestSignInLink(email: String) async throws {}
    func accept(token: String) async throws {}
}
#endif

#if DEBUG
/// In-memory settings service for the preview/UITest.
private actor PreviewAccountSettings: AccountSettingsService {
    private var prefs = AccountPreferences(
        version: 3, referralEmails: true, marketingEmails: false, pushReferralConverted: true,
        pushStreakAtRisk: true, pushStreakMilestone: true, pushStreakLapsed: true,
        pushBadgeEarned: true, pushEventNearby: false, pushEventReminder: true,
        pushEventPromoted: false, pushGiftProcessed: true, rankingsOptedOut: false,
        networkVisible: true, volunteer: true)

    private func snapshot() -> AccountSettingsSnapshot {
        AccountSettingsSnapshot(
            profile: AccountProfileSummary(email: "donor@example.com", accountRole: "DONOR",
                                           zip: "78701", city: "Austin", phone: nil),
            preferences: prefs)
    }

    func load() async throws -> AccountSettingsSnapshot { snapshot() }
    func savePreferences(_ preferences: AccountPreferences) async throws -> AccountSettingsSnapshot {
        prefs = AccountPreferences(
            version: preferences.version + 1, referralEmails: preferences.referralEmails,
            marketingEmails: preferences.marketingEmails, pushReferralConverted: preferences.pushReferralConverted,
            pushStreakAtRisk: preferences.pushStreakAtRisk, pushStreakMilestone: preferences.pushStreakMilestone,
            pushStreakLapsed: preferences.pushStreakLapsed, pushBadgeEarned: preferences.pushBadgeEarned,
            pushEventNearby: preferences.pushEventNearby, pushEventReminder: preferences.pushEventReminder,
            pushEventPromoted: preferences.pushEventPromoted, pushGiftProcessed: preferences.pushGiftProcessed,
            rankingsOptedOut: preferences.rankingsOptedOut, networkVisible: preferences.networkVisible,
            volunteer: preferences.volunteer)
        return snapshot()
    }
    func deleteAccount() async throws {}
    func signOut() async throws {}
}

/// Preview settings tied to the live (preview) session, so signing out or deleting from the donor
/// shell really ends the session and routes back to sign-in, like a release build.
private struct PreviewSessionSettings: AccountSettingsService {
    let session: AccountSession
    private let inner = PreviewAccountSettings()
    init(session: AccountSession) { self.session = session }
    func load() async throws -> AccountSettingsSnapshot { try await inner.load() }
    func savePreferences(_ preferences: AccountPreferences) async throws -> AccountSettingsSnapshot { try await inner.savePreferences(preferences) }
    func deleteAccount() async throws { try await session.discardLocal() }
    func signOut() async throws { try await session.logout() }
}
#endif

/// UIKit's push callbacks, surfaced to SwiftUI: the device token once APNs issues one, and the latest tapped
/// notification. Without the Push Notifications entitlement (it needs the signing team) APNs issues no token.
@MainActor @Observable
final class PushCenter {
    static let shared = PushCenter()
    var token: String?
    var tap: PushTap?
}

extension PushEnvironment {
    /// Development-signed (Debug) builds receive sandbox APNs tokens.
    static var ofThisBuild: PushEnvironment {
        #if DEBUG
        .sandbox
        #else
        .production
        #endif
    }
}

final class PushAppDelegate: NSObject, UIApplicationDelegate, UNUserNotificationCenterDelegate {
    func application(_ application: UIApplication, didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil) -> Bool {
        UNUserNotificationCenter.current().delegate = self
        Task {
            // Already allowed (asked from Settings on an earlier launch): fetch this launch's token. Never prompts.
            let status = await UNUserNotificationCenter.current().notificationSettings().authorizationStatus
            if [.authorized, .provisional, .ephemeral].contains(status) { application.registerForRemoteNotifications() }
        }
        return true
    }

    func application(_ application: UIApplication, didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Data) {
        PushCenter.shared.token = pushTokenHex(deviceToken)
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse) async {
        guard let tap = PushTap(userInfo: response.notification.request.content.userInfo) else { return }
        await MainActor.run { PushCenter.shared.tap = tap }
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter,
                                            willPresent notification: UNNotification) async -> UNNotificationPresentationOptions {
        [.banner, .list, .sound]
    }
}

@main
struct DADApp: App {
    @UIApplicationDelegateAdaptor(PushAppDelegate.self) private var appDelegate
    @State private var push = PushCenter.shared
    @State private var model = AccountModel()
    @State private var router = RoleRouter()
    @State private var web: WebDestination?

    @ViewBuilder private var donorRoot: some View {
        #if DEBUG
        if launchFlag("--preview-giving") {
            GiftScreen(model: GivingModel(service: PreviewGiving()))
        } else if launchFlag("--preview-engagement") {
            EngagementHome(model: EngagementModel(service: PreviewEngagement()))
        } else if launchFlag("--preview-events") {
            let preview = PreviewEvents()
            EventsScreen(model: EventsModel(service: preview), service: preview)
        } else if launchFlag("--preview-settings") {
            AccountSettingsScreen(model: AccountSettingsModel(service: PreviewAccountSettings()))
        } else {
            donorLanding
        }
        #else
        donorLanding
        #endif
    }

    private var donorLanding: some View {
        DonorShell(model: model, destination: Binding(get: { model.destination }, set: { model.destination = $0 }))
    }

    @ViewBuilder private var partnerRoot: some View {
        if let service = model.partnerService {
            PartnerPortal(model: PartnerModel(service: service), publicOrigin: model.publicOrigin, pushToken: push.token) {
                router.signedOut()
            }
        }
    }

    private var showsDonorShell: Bool {
        switch router.root {
        case .authenticated(.donor): return true
        case .restoring: return model.hasRestorableSession
        default: return false
        }
    }

    /// Whether the signed-in donor shows the full-window `TabView` shell (not a DEBUG single-screen
    /// preview, which keeps the scrolling root the standalone screens expect).
    private var showsDonorTabs: Bool {
        guard showsDonorShell else { return false }
        #if DEBUG
        return !["--preview-giving", "--preview-engagement", "--preview-events", "--preview-settings"].contains(where: launchFlag)
        #else
        return true
        #endif
    }

    @ViewBuilder private var rootContent: some View {
        if showsDonorShell {
            // ONE branch for both "restoring with a stored session" and "signed in as donor":
            // the restore -> signed-in transition must not change view identity, or the donor
            // home is rebuilt a frame after it mounted, cancelling its in-flight dashboard
            // read (result discarded) and starting a second one.
            donorRoot
        } else {
            switch router.root {
            case .authenticated(.donor):
                donorRoot   // unreachable: handled by `showsDonorShell`
            case .restoring:
                // A session-less launch waits on a neutral progress view so it never flashes
                // the signed-in screen (a restorable session is the donor shell above).
                ProgressView().accessibilityIdentifier("restoring")
            case .authenticated(.partner):
                partnerRoot
            case .unauthenticated:
                UnauthenticatedStack(kit: model.kit, establish: model.establish(), notice: model.notice,
                                     invitation: model.invitation,
                                     onPasteLink: { model.openPastedLink($0) }, partnerSignIn: model.partnerSignIn,
                                     applicationStatus: model.applicationStatus, applicationSubmit: model.applicationSubmit,
                                     partnerToken: model.pendingPartnerToken,
                                     onPartnerTokenConsumed: { model.pendingPartnerToken = nil },
                                     onPartnerSignedIn: { router.selectRole(.partner); router.signedIn(as: .partner) },
                                     publicOrigin: model.publicOrigin) {
                    // The session already holds the established credentials; read the profile
                    // through it, then enter the donor shell (which owns load/recovery states).
                    Task {
                        await model.load()
                        router.selectRole(.donor)
                        router.signedIn(as: .donor)
                        _ = router.flushPendingDestination()
                    }
                }
            }
        }
    }

    var body: some Scene {
        WindowGroup {
            Group {
                if showsDonorTabs {
                    // The TabView owns the full window; it must not sit inside a ScrollView.
                    rootContent
                } else {
                    ScrollView { rootContent }
                }
            }
            .modifier(AppBackground())
            .tint(tokenColor("brand-ink"))
            .environment(model.analytics)
            .task {
                model.analytics?.emit(.appOpened)
                #if DEBUG
                if launchFlag("--stub-push-tap-gifts") { push.tap = PushTap(category: "STREAK_AT_RISK", path: "/account/gifts") }
                // A preview screen is launched straight into its router state, before the profile
                // await, so the target renders immediately instead of dwelling in `.restoring`.
                if ["--preview-giving", "--preview-engagement", "--preview-events", "--preview-settings"].contains(where: launchFlag) {
                    router.signedIn(as: .donor)
                    return
                }
                if ["--preview-partner", "--preview-partner-viewer"].contains(where: launchFlag) {
                    router.signedIn(as: .partner)
                    return
                }
                #endif
                await model.load()
                // A session-backed shell is the donor journey — the donor landing owns every
                // account sub-state (loading / ready / unavailable / signed-out) and its own
                // recovery, so stay on it. Only a genuinely session-less app goes to role-select.
                // A session with nothing stored (or one the server revoked) is signed out: go to sign-in.
                // Without a donor session, a partner session still within its 12 hours reopens the portal.
                if model.state == .signedOut || !model.hasSession {
                    if await model.hasPartnerSession() { router.signedIn(as: .partner) } else { router.restoredSignedOut() }
                } else { router.signedIn(as: .donor) }
                #if DEBUG
                if launchFlag("--stub-open-invite"), let url = URL(string: "https://stub.invalid/r/ALEX42") {
                    _ = model.receive(url, role: router.currentRole)
                }
                #endif
            }
            .task(id: push.tap) {
                guard let tap = push.tap else { return }
                push.tap = nil
                model.openNotification(tap)
            }
            .task(id: PushRegistrationKey(token: push.token, ready: model.isReady)) { await model.registerPush(push.token) }
            .onChange(of: model.state) { _, state in
                switch state {
                case .ready where router.currentRole == nil:
                    router.signedIn(as: .donor)   // a claim link signed the person in from the sign-in screen
                case .signedOut where router.currentRole == .donor:
                    router.signedOut()            // sign-out, deletion, or a revoked session
                default: break
                }
            }
            .onOpenURL { if let url = model.receive($0, role: router.currentRole) { web = WebDestination(url: url) } }
            .onContinueUserActivity(NSUserActivityTypeBrowsingWeb) {
                if let url = $0.webpageURL, let fallback = model.receive(url, role: router.currentRole) { web = WebDestination(url: fallback) }
            }
            .sheet(item: $web) { WebFallback(url: $0.url) }
        }
    }
}
