import Foundation
import OpenAPIRuntime

/// Real account management over the generated client: `saveProfile`, `requestEmailChange`,
/// `sessions` / `revokeSession` / `revokeOtherSessions`, `logoutAll`, and the employee calls
/// `employeeTeam` / `employeeEnroll` / `employeeJoinTeam`, all authorized through the session.
public struct WireAccountManagement: AccountManagementService {
    private let product: ProductClient

    public init(origin: URL, session: AccountSession) throws {
        self.init(product: try ProductClient(origin: origin, session: session))
    }

    init(product: ProductClient) { self.product = product }

    public func saveProfile(zip: String, city: String, phone: String, timezoneOverride: String?) async throws -> AccountProfileSummary {
        if let timezoneOverride, !StreakTimeZone.choices.contains(where: { $0.value == timezoneOverride }) { throw AccountError.invalidInput }
        return try await product.call { client in
            switch try await client.saveProfile(.init(body: .json(.init(zip: zip, city: city, phone: phone, timezone_override: timezoneOverride)))) {
            case .ok(let response): return WireAccountSettings.snapshot(try response.body.json).profile
            case .unauthorized: throw AccountError.signedOut
            case .unprocessableContent: throw AccountError.invalidInput
            case .tooManyRequests: throw AccountError.rateLimited
            default: throw AccountError.unavailable
            }
        }
    }

    public func requestEmailChange(to email: String) async throws {
        try await product.call { client in
            switch try await client.requestEmailChange(.init(body: .json(.init(email: email)))) {
            case .ok: return
            case .unauthorized: throw AccountError.signedOut
            case .conflict: throw AccountError.conflict
            case .unprocessableContent: throw AccountError.invalidInput
            case .tooManyRequests: throw AccountError.rateLimited
            default: throw AccountError.unavailable
            }
        }
    }

    public func sessions() async throws -> [DeviceSessionSummary] {
        try await product.call { client in
            switch try await client.sessions(.init()) {
            case .ok(let response): return Self.sessions(try response.body.json)
            case .unauthorized: throw AccountError.signedOut
            case .tooManyRequests: throw AccountError.rateLimited
            default: throw AccountError.unavailable
            }
        }
    }

    public func revokeSession(id: String) async throws -> [DeviceSessionSummary] {
        try await product.call { client in
            switch try await client.revokeSession(.init(path: .init(session_id: id))) {
            case .ok(let response): return Self.sessions(try response.body.json)
            case .unauthorized: throw AccountError.signedOut
            case .notFound: throw AccountError.notFound
            case .conflict: throw AccountError.conflict
            case .tooManyRequests: throw AccountError.rateLimited
            default: throw AccountError.unavailable
            }
        }
    }

    public func revokeOtherSessions() async throws -> [DeviceSessionSummary] {
        try await product.call { client in
            switch try await client.revokeOtherSessions(.init()) {
            case .ok(let response): return Self.sessions(try response.body.json)
            case .unauthorized: throw AccountError.signedOut
            case .tooManyRequests: throw AccountError.rateLimited
            default: throw AccountError.unavailable
            }
        }
    }

    /// Local credentials are cleared only once the server confirms, so a failed request leaves
    /// the donor signed in to retry rather than believing the other devices were signed out.
    public func signOutEverywhere() async throws {
        do {
            try await product.call { client in
                switch try await client.logoutAll(.init()) {
                case .ok: return
                case .unauthorized: throw AccountError.signedOut
                case .tooManyRequests: throw AccountError.rateLimited
                default: throw AccountError.unavailable
                }
            }
        } catch AccountError.signedOut {}
        try await product.session.discardLocal()
    }

    public func employer() async throws -> EmployerTeam {
        try await product.call { client in
            switch try await client.employeeTeam(.init()) {
            case .ok(let response):
                let body = try response.body.json
                return EmployerTeam(
                    organization: body.organization.isEmpty ? nil : body.organization,
                    teamName: body.team_name.flatMap { $0.isEmpty ? nil : $0 },
                    leaderboard: body.leaderboard.map {
                        TeamStanding(id: $0.team_id, name: $0.name, activeGivers: $0.active_givers, annualizedMinor: $0.annualized_minor,
                                     avgStreakDays: $0.avg_streak_days, volunteerMinutes: $0.volunteer_minutes, metricsVerified: $0.metrics_verified)
                    })
            case .unauthorized: throw AccountError.signedOut
            case .tooManyRequests: throw AccountError.rateLimited
            default: throw AccountError.unavailable
            }
        }
    }

    public func enroll(companyCode: String) async throws -> String {
        try await product.call { client in
            switch try await client.employeeEnroll(.init(body: .json(.init(company_code: companyCode)))) {
            case .ok(let response): return try response.body.json.organization
            case .unauthorized: throw AccountError.signedOut
            case .unprocessableContent: throw AccountError.invalidInput
            case .conflict: throw AccountError.conflict
            case .tooManyRequests: throw AccountError.rateLimited
            default: throw AccountError.unavailable
            }
        }
    }

    public func joinTeam(name: String) async throws {
        try await product.call { client in
            switch try await client.employeeJoinTeam(.init(body: .json(.init(name: name)))) {
            case .ok: return
            case .unauthorized: throw AccountError.signedOut
            case .unprocessableContent: throw AccountError.invalidInput
            case .tooManyRequests: throw AccountError.rateLimited
            default: throw AccountError.unavailable
            }
        }
    }

    static func sessions(_ list: Components.Schemas.SessionList) -> [DeviceSessionSummary] {
        list.sessions.map {
            DeviceSessionSummary(id: $0.id, label: $0.label, isApp: $0.client == .APP, lastUsedAt: $0.last_used_at, current: $0.current)
        }
    }
}
