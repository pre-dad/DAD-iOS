import Foundation
import DADFoundation

// DEBUG-only in-memory doubles behind the --preview-* launch arguments: the app runs its journeys in the
// simulator and UITests with no backend. A release build compiles none of this.

#if DEBUG
final class PreviewStore: CredentialStore, @unchecked Sendable {
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
actor PreviewAPI: AccountAPI {
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

#if DEBUG
/// Preview sign-in transport: returns a handle and preview credentials so the auth journey runs in
/// the simulator with no backend. Internal rather than private because `SignInKit.preview` uses it.
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
/// Preview giving transport: an in-memory recurring gift so the giving journey runs in the simulator with no backend.
actor PreviewGiving: GivingService {
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
actor PreviewEngagement: EngagementService {
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

#if DEBUG
/// Preview double for the events service. One reservable public event, one full event (waitlist),
/// and one invite-only event, so the list/detail/reserve path is exercised without a network.
actor PreviewEvents: EventsService {
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
actor PreviewAccountSettings: AccountSettingsService {
    private var prefs = AccountPreferences(
        version: 3, referralEmails: true, marketingEmails: false, pushReferralConverted: true,
        pushStreakAtRisk: true, pushStreakMilestone: true, pushStreakLapsed: true,
        pushBadgeEarned: true, pushEventNearby: false, pushEventReminder: true,
        pushEventPromoted: false, pushGiftProcessed: true, rankingsOptedOut: false,
        networkVisible: true, volunteer: true, volunteerInterests: ["Food drives"])

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
            volunteer: preferences.volunteer, volunteerInterests: preferences.volunteerInterests)
        return snapshot()
    }
    func deleteAccount() async throws {}
    func signOut() async throws {}
}

/// Preview settings tied to the live (preview) session, so signing out or deleting from the donor
/// shell really ends the session and routes back to sign-in, like a release build.
struct PreviewSessionSettings: AccountSettingsService {
    let session: AccountSession
    private let inner = PreviewAccountSettings()
    init(session: AccountSession) { self.session = session }
    func load() async throws -> AccountSettingsSnapshot { try await inner.load() }
    func savePreferences(_ preferences: AccountPreferences) async throws -> AccountSettingsSnapshot { try await inner.savePreferences(preferences) }
    func deleteAccount() async throws { try await session.discardLocal() }
    func signOut() async throws { try await session.logout() }
}
#endif
