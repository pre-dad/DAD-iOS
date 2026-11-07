import Foundation
import HTTPTypes
import OpenAPIRuntime

/// The partner's app session: the bearer `POST /donor/partner/accept-invite` returns to a native request.
/// It lasts 12 hours and cannot be refreshed, so it is kept with its expiry and dropped the moment it
/// lapses or the server rejects it; the partner then signs in again with an emailed link. Stored apart
/// from the donor session (one email has one role, but a device may hold both).
public actor PartnerSession {
    public static let lifetime: TimeInterval = 12 * 60 * 60

    private let store: any CredentialStore
    private let now: @Sendable () -> Date
    private var stored: Credentials?
    private var epoch = 0

    public init(store: any CredentialStore, now: @escaping @Sendable () -> Date = Date.init) throws {
        self.store = store; self.now = now
        stored = try store.load()
    }

    public var isSignedIn: Bool { (try? token()) != nil }

    func install(token: String) throws {
        let credentials = Credentials(access: token, refresh: "", expiresAt: now().addingTimeInterval(Self.lifetime))
        try store.save(credentials)
        stored = credentials
        epoch += 1
    }

    /// The bearer, or `.signedOut` once it has expired (which also forgets it).
    func token() throws -> String {
        guard let stored else { throw AccountError.signedOut }
        guard stored.expiresAt > now() else { try clear(); throw AccountError.signedOut }
        return stored.access
    }

    func establish(_ produce: @Sendable () async throws -> String) async throws {
        let before = epoch
        let bearer = try await produce()
        guard before == epoch else { throw AccountError.signedOut }
        try Task.checkCancellation()
        try install(token: bearer)
    }

    func authorized<T: Sendable>(_ call: @Sendable (String) async throws -> T) async throws -> T {
        try Task.checkCancellation()
        let bearer = try token()
        let before = epoch
        do {
            let result = try await call(bearer)
            guard before == epoch else { throw AccountError.signedOut }
            try Task.checkCancellation()
            return result
        } catch AccountError.signedOut {
            if before == epoch { try clear() }
            throw AccountError.signedOut
        }
    }

    func end() throws -> String? {
        let bearer = try? token()
        try clear()
        return bearer
    }

    func clear() throws {
        epoch += 1
        stored = nil
        try store.clear()
    }
}

/// Runs one partner call and maps a 4xx/5xx the generated client could not decode (the ingress limiter's 429
/// has no Problem body) by its status, exactly as a documented response would be. Cancellation is never remapped.
func mappingUndecodableStatus<T: Sendable>(_ work: () async throws -> T) async throws -> T {
    do { return try await work() }
    catch let error as ClientError {
        if let status = error.response?.status.code, status >= 400, !error.underlyingError.isCancellation {
            throw AccountError.forStatus(status)
        }
        throw error
    }
}

/// Partner sign-in over the generated client: request an emailed link (`partnerRequestSignIn`) and
/// exchange the link's single-use token for the app session (`partnerAcceptInvite`).
public struct WirePartnerAuth: Sendable {
    private let origin: URL
    private let transport: any ClientTransport
    private let session: PartnerSession

    public init(origin: URL, session: PartnerSession) throws {
        guard origin.isBareHTTPSOrigin else { throw AccountError.invalidConfiguration }
        self.init(origin: origin, transport: makeNativeTransport(), session: session)
    }

    init(origin: URL, transport: any ClientTransport, session: PartnerSession) {
        self.origin = origin; self.transport = transport; self.session = session
    }

    private var client: Client { Client(serverURL: origin, transport: transport, middlewares: [NativeHeaders(access: { nil })]) }

    public func requestSignInLink(email: String) async throws {
        try await mappingUndecodableStatus {
            switch try await client.partnerRequestSignIn(.init(body: .json(.init(email: email)))) {
            case .accepted: return
            case .forbidden: throw AccountError.forbidden
            case .unprocessableContent: throw AccountError.invalidInput
            case .tooManyRequests: throw AccountError.rateLimited
            case .undocumented(let status, _): throw AccountError.forStatus(status)
            default: throw AccountError.unavailable
            }
        }
    }

    /// Exchanges the link for a session and keeps it. A used or expired link is `.invalidInput`.
    public func accept(token: String) async throws {
        try await session.establish {
            try await mappingUndecodableStatus {
                switch try await client.partnerAcceptInvite(.init(body: .json(.init(invite: token)))) {
                case .ok(let response):
                    guard let bearer = try response.body.json.session, !bearer.isEmpty else { throw AccountError.invalidResponse }
                    return bearer
                case .unprocessableContent: throw AccountError.invalidInput
                case .forbidden: throw AccountError.forbidden
                case .tooManyRequests: throw AccountError.rateLimited
                case .undocumented(let status, _): throw AccountError.forStatus(status)
                default: throw AccountError.unavailable
                }
            }
        }
    }
}

/// The partner portal over the generated client, under the partner session. A 401 means the session
/// ended (expired or revoked): it is forgotten so the app returns to partner sign-in.
public struct WirePartner: PartnerService {
    private let origin: URL
    private let transport: any ClientTransport
    private let session: PartnerSession

    public init(origin: URL, session: PartnerSession) throws {
        guard origin.isBareHTTPSOrigin else { throw AccountError.invalidConfiguration }
        self.init(origin: origin, transport: makeNativeTransport(), session: session)
    }

    init(origin: URL, transport: any ClientTransport, session: PartnerSession) {
        self.origin = origin; self.transport = transport; self.session = session
    }

    private func perform<T: Sendable>(maxBodyBytes: Int = 1_048_576, _ operation: @Sendable (Client) async throws -> T) async throws -> T {
        try await session.authorized { bearer in
            let client = Client(serverURL: origin, configuration: .init(dateTranscoder: LenientDateTranscoder()),
                                transport: transport, middlewares: [NativeHeaders(access: { bearer }, maxBodyBytes: maxBodyBytes)])
            return try await mappingUndecodableStatus { try await operation(client) }
        }
    }

    public func overview() async throws -> PartnerOverview {
        try await perform { client in
            switch try await client.partnerOverview(.init()) {
            case .ok(let response):
                let o = try response.body.json
                return PartnerOverview(
                    organization: o.organization, description: o.description, userID: o.user_id,
                    role: PartnerRole(contract: o.role), companyCode: o.company_code,
                    committed: VerifiedMoney(amountMinor: o.committed_minor, verified: o.committed_verified),
                    deployed: VerifiedMoney(amountMinor: o.deployed_minor, verified: o.deployed_verified),
                    deployedPercent: o.deployed_percent,
                    peopleReached: VerifiedCount(value: o.people_reached, verified: o.people_reached_verified),
                    employeesEnrolled: o.employees_enrolled, workforceSize: o.workforce_size,
                    enrolledPercent: o.enrolled_percent, updatedAt: o.updated_at, hasLogo: o.has_logo)
            case .unauthorized: throw AccountError.signedOut
            case .forbidden: throw AccountError.forbidden
            case .tooManyRequests: throw AccountError.rateLimited
            case .undocumented(let status, _): throw AccountError.forStatus(status)
            default: throw AccountError.unavailable
            }
        }
    }

    public func initiatives() async throws -> [PartnerInitiative] {
        try await perform { client in
            switch try await client.partnerInitiatives(.init()) {
            case .ok(let response):
                return try response.body.json.initiatives.map { i in
                    PartnerInitiative(
                        id: i.id, title: i.title, summary: i.summary, status: InitiativeStatus(contract: i.status),
                        region: i.region, committedMinor: i.committed_minor, deployedMinor: i.deployed_minor,
                        metrics: i.metrics.map { PartnerMetric(label: $0.label, value: $0.value, unit: PartnerMetric.Unit(contract: $0.unit)) })
                }
            case .unauthorized: throw AccountError.signedOut
            case .forbidden: throw AccountError.forbidden
            case .tooManyRequests: throw AccountError.rateLimited
            case .undocumented(let status, _): throw AccountError.forStatus(status)
            default: throw AccountError.unavailable
            }
        }
    }

    public func spend() async throws -> [PartnerSpendCategory] {
        try await perform { client in
            switch try await client.partnerSpend(.init()) {
            case .ok(let response):
                return try response.body.json.categories.map { PartnerSpendCategory(category: $0.category, amountMinor: $0.amount_minor) }
            case .unauthorized: throw AccountError.signedOut
            case .forbidden: throw AccountError.forbidden
            case .tooManyRequests: throw AccountError.rateLimited
            case .undocumented(let status, _): throw AccountError.forStatus(status)
            default: throw AccountError.unavailable
            }
        }
    }

    public func people() async throws -> PartnerPeople {
        try await perform { client in
            switch try await client.employeeOurPeople(.init()) {
            case .ok(let response):
                let p = try response.body.json
                return PartnerPeople(enrolled: p.enrolled, workforceSize: p.workforce_size, givenMinor: p.given_minor,
                                     matchedMinor: p.matched_minor, avgStreakDays: p.avg_streak_days,
                                     volunteerMinutes: p.volunteer_minutes, teams: p.teams, suppressed: p.suppressed)
            case .unauthorized: throw AccountError.signedOut
            case .forbidden: throw AccountError.forbidden
            case .tooManyRequests: throw AccountError.rateLimited
            case .undocumented(let status, _): throw AccountError.forStatus(status)
            default: throw AccountError.unavailable
            }
        }
    }

    public func teams() async throws -> [TeamStanding] {
        try await perform { client in
            switch try await client.employeeTeams(.init()) {
            case .ok(let response):
                return try response.body.json.teams.map {
                    TeamStanding(id: $0.team_id, name: $0.name, activeGivers: $0.active_givers, annualizedMinor: $0.annualized_minor,
                                 avgStreakDays: $0.avg_streak_days, volunteerMinutes: $0.volunteer_minutes)
                }
            case .unauthorized: throw AccountError.signedOut
            case .forbidden: throw AccountError.forbidden
            case .tooManyRequests: throw AccountError.rateLimited
            case .undocumented(let status, _): throw AccountError.forStatus(status)
            default: throw AccountError.unavailable
            }
        }
    }

    public func users() async throws -> [PartnerUser] {
        try await perform { client in
            switch try await client.partnerUsers(.init()) {
            case .ok(let response):
                return try response.body.json.users.map {
                    PartnerUser(id: $0.id, email: $0.email, name: $0.name, role: PartnerRole(contract: $0.role))
                }
            case .unauthorized: throw AccountError.signedOut
            case .forbidden: throw AccountError.forbidden
            case .tooManyRequests: throw AccountError.rateLimited
            case .undocumented(let status, _): throw AccountError.forStatus(status)
            default: throw AccountError.unavailable
            }
        }
    }

    public func inviteUser(email: String, name: String, role: PartnerRole) async throws {
        try await perform { client in
            switch try await client.partnerInviteUser(.init(body: .json(.init(email: email, name: name, role: role.rawValue)))) {
            case .ok: return
            case .unauthorized: throw AccountError.signedOut
            case .forbidden: throw AccountError.forbidden
            case .conflict: throw AccountError.conflict
            case .unprocessableContent: throw AccountError.invalidInput
            case .tooManyRequests: throw AccountError.rateLimited
            case .undocumented(let status, _): throw AccountError.forStatus(status)
            default: throw AccountError.unavailable
            }
        }
    }

    public func removeUser(id: String) async throws {
        try await perform { client in
            switch try await client.partnerRemoveUser(.init(path: .init(userID: id), body: .json(.init()))) {
            case .ok: return
            case .unauthorized: throw AccountError.signedOut
            case .forbidden: throw AccountError.forbidden
            case .notFound: throw AccountError.notFound
            case .conflict: throw AccountError.conflict
            case .unprocessableContent: throw AccountError.invalidInput
            case .tooManyRequests: throw AccountError.rateLimited
            case .undocumented(let status, _): throw AccountError.forStatus(status)
            default: throw AccountError.unavailable
            }
        }
    }

    public func saveProfile(organization: String, description: String) async throws {
        try await perform { client in
            switch try await client.partnerSaveProfile(.init(body: .json(.init(organization: organization, description: description)))) {
            case .ok: return
            case .unauthorized: throw AccountError.signedOut
            case .forbidden: throw AccountError.forbidden
            case .unprocessableContent: throw AccountError.invalidInput
            case .tooManyRequests: throw AccountError.rateLimited
            case .undocumented(let status, _): throw AccountError.forStatus(status)
            default: throw AccountError.unavailable
            }
        }
    }

    public func saveWorkforce(size: Int) async throws {
        try await perform { client in
            switch try await client.employeeWorkforce(.init(body: .json(.init(workforce_size: size)))) {
            case .ok: return
            case .unauthorized: throw AccountError.signedOut
            case .forbidden: throw AccountError.forbidden
            case .unprocessableContent: throw AccountError.invalidInput
            case .tooManyRequests: throw AccountError.rateLimited
            case .undocumented(let status, _): throw AccountError.forStatus(status)
            default: throw AccountError.unavailable
            }
        }
    }

    public func logo() async throws -> Data? {
        // No logo is a 404, with or without the Problem body: not an error.
        do { return try await fetchLogo() } catch AccountError.notFound { return nil }
    }

    private func fetchLogo() async throws -> Data? {
        try await perform { client in
            switch try await client.partnerLogo(.init()) {
            case .ok(let response): return Data(try await ArraySlice<UInt8>(collecting: response.body.png, upTo: 1_048_576))
            case .notFound: return nil
            case .unauthorized: throw AccountError.signedOut
            case .forbidden: throw AccountError.forbidden
            case .tooManyRequests: throw AccountError.rateLimited
            case .undocumented(let status, _): throw AccountError.forStatus(status)
            default: throw AccountError.unavailable
            }
        }
    }

    public func saveLogo(png: Data?) async throws {
        let dataURL = png.map { "data:image/png;base64," + $0.base64EncodedString() } ?? ""
        try await perform { client in
            switch try await client.partnerSaveLogo(.init(body: .json(.init(data_url: dataURL)))) {
            case .ok: return
            case .unauthorized: throw AccountError.signedOut
            case .forbidden: throw AccountError.forbidden
            case .unprocessableContent: throw AccountError.invalidInput
            case .tooManyRequests: throw AccountError.rateLimited
            case .undocumented(let status, _): throw AccountError.forStatus(status)
            default: throw AccountError.unavailable
            }
        }
    }

    public func exports() async throws -> [PartnerExport] {
        try await perform { client in
            switch try await client.partnerExports(.init()) {
            case .ok(let response):
                return try response.body.json.exports.map {
                    PartnerExport(id: $0.id, createdAt: $0.created_at, exportedBy: $0.exported_by, committedMinor: $0.committed_minor,
                                  deployedMinor: $0.deployed_minor, downloadable: $0.downloadable)
                }
            case .unauthorized: throw AccountError.signedOut
            case .forbidden: throw AccountError.forbidden
            case .tooManyRequests: throw AccountError.rateLimited
            case .undocumented(let status, _): throw AccountError.forStatus(status)
            default: throw AccountError.unavailable
            }
        }
    }

    public func report() async throws -> Data {
        try await perform(maxBodyBytes: 16 * 1_048_576) { client in
            switch try await client.partnerReport(.init()) {
            case .ok(let response): return Data(try await ArraySlice<UInt8>(collecting: response.body.pdf, upTo: 16 * 1_048_576))
            case .unauthorized: throw AccountError.signedOut
            case .forbidden: throw AccountError.forbidden
            case .tooManyRequests: throw AccountError.rateLimited
            case .undocumented(let status, _): throw AccountError.forStatus(status)
            default: throw AccountError.unavailable
            }
        }
    }

    public func retainedReport(id: String) async throws -> Data {
        try await perform(maxBodyBytes: 16 * 1_048_576) { client in
            switch try await client.partnerRetainedReport(.init(path: .init(report_id: id))) {
            case .ok(let response): return Data(try await ArraySlice<UInt8>(collecting: response.body.pdf, upTo: 16 * 1_048_576))
            case .unauthorized: throw AccountError.signedOut
            case .forbidden: throw AccountError.forbidden
            case .notFound: throw AccountError.notFound
            case .tooManyRequests: throw AccountError.rateLimited
            case .undocumented(let status, _): throw AccountError.forStatus(status)
            default: throw AccountError.unavailable
            }
        }
    }

    /// The local session is forgotten first, so the partner is signed out on this device even when the
    /// server cannot be reached; the server session then simply expires.
    public func signOut() async throws {
        guard let bearer = try await session.end() else { return }
        let client = Client(serverURL: origin, transport: transport, middlewares: [NativeHeaders(access: { bearer })])
        _ = try? await client.partnerSignOut(.init(body: .json(.init())))
    }

    public func registerPushDevice(token: String, environment: PushEnvironment) async throws {
        try await perform { client in
            let body = Operations.partnerRegisterPushDevice.Input.Body.jsonPayload(
                platform: .IOS, token: token, environment: environment == .sandbox ? .SANDBOX : .PRODUCTION)
            switch try await client.partnerRegisterPushDevice(.init(body: .json(body))) {
            case .ok: return
            case .unauthorized: throw AccountError.signedOut
            case .unprocessableContent: throw AccountError.invalidInput
            case .undocumented(let status, _): throw AccountError.forStatus(status)
            default: throw AccountError.unavailable
            }
        }
    }

    public func unregisterPushDevice() async throws {
        try await perform { client in
            switch try await client.partnerUnregisterPushDevice(.init()) {
            case .ok: return
            case .unauthorized: throw AccountError.signedOut
            case .undocumented(let status, _): throw AccountError.forStatus(status)
            default: throw AccountError.unavailable
            }
        }
    }
}
