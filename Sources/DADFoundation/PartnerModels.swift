import Foundation

// Partner portal view models + the service seam. The models own explicit load/ready/failed state,
// role-gated actions and push register/unregister, so they are unit-tested without a network or UI —
// the same shape as the donor models.

public enum PartnerReportLimit: Error, Sendable, Equatable {
    case daily, storage, tooLarge
    public var message: String {
        switch self {
        case .daily: "This organization has reached today’s report limit. Try after midnight UTC. Existing reports remain available."
        case .storage: "Report storage is full. Download an existing report or contact DAD support."
        case .tooLarge: "This report is too large to export. Existing reports remain available; contact DAD support."
        }
    }
}

/// The seam the partner models call. A conformer maps to the generated client under the 12-hour
/// partner session (`WirePartner`) or a preview/test double; all value types so the models stay testable.
public protocol PartnerService: Sendable {
    func overview() async throws -> PartnerOverview
    func initiatives() async throws -> [PartnerInitiative]
    func spend() async throws -> [PartnerSpendCategory]
    func people() async throws -> PartnerPeople
    /// The company team leaderboard (EM-5); teams under five members are left out server-side.
    func teams() async throws -> [TeamStanding]
    func users() async throws -> [PartnerUser]
    /// Admin-only (P-13). The model gates on role before calling, but the server re-checks.
    func inviteUser(email: String, name: String, role: PartnerRole) async throws
    func removeUser(id: String) async throws
    /// Admin-only (§7.2): the organization's name and description.
    func saveProfile(organization: String, description: String) async throws
    /// Admin-only: the headcount enrollment percentages are measured against (EM-3).
    func saveWorkforce(size: Int) async throws
    /// The organization's logo as PNG, or nil when it has none.
    func logo() async throws -> Data?
    /// Admin-only: a PNG of at most 512 by 512 pixels and 256 KiB, or nil to remove the logo.
    func saveLogo(png: Data?) async throws
    /// Admin-only: earlier report exports, newest first.
    func exports() async throws -> [PartnerExport]
    /// Admin-only: a new PDF impact report (recorded as an export).
    func report() async throws -> Data
    func retainedReport(id: String) async throws -> Data
    func signOut() async throws
    /// Partner push (§7.5, v2.2). Register on sign-in, clear on sign-out; both native-only.
    func registerPushDevice(token: String, environment: PushEnvironment) async throws
    func unregisterPushDevice() async throws
}

/// One earlier report export (P-14). `downloadable` is false once its retained PDF has aged out.
public struct PartnerExport: Sendable, Equatable, Identifiable {
    public let id: String
    public let createdAt: Date
    public let exportedBy: String
    public let committedMinor: Int64
    public let deployedMinor: Int64
    public let downloadable: Bool
    public init(id: String, createdAt: Date, exportedBy: String, committedMinor: Int64, deployedMinor: Int64, downloadable: Bool) {
        self.id = id
        self.createdAt = createdAt
        self.exportedBy = exportedBy
        self.committedMinor = committedMinor
        self.deployedMinor = deployedMinor
        self.downloadable = downloadable
    }
}

/// A PDF ready to hand to the share sheet, written to a temporary file.
public struct PartnerReportFile: Sendable, Equatable, Identifiable {
    public let url: URL
    public var id: URL { url }
    public init(url: URL) { self.url = url }
}

// MARK: - Partner portal model (P-10..P-14)

@MainActor
@Observable
public final class PartnerModel {
    public enum Phase: Sendable, Equatable {
        case loading
        case ready
        case failed(String)
    }

    public private(set) var phase: Phase = .loading
    public private(set) var overview: PartnerOverview?
    public private(set) var initiatives: [PartnerInitiative] = []
    public private(set) var spend: [PartnerSpendCategory] = []
    public private(set) var people: PartnerPeople?
    public private(set) var teams: [TeamStanding] = []
    public private(set) var users: [PartnerUser] = []
    public private(set) var exports: [PartnerExport] = []
    public private(set) var logo: Data?
    /// A transient action error shown inline without losing the portal.
    public private(set) var actionError: String?
    /// Confirms the last completed action ("Organization profile saved.").
    public private(set) var notice: String?
    /// True when the overview loaded but at least one secondary section failed to load.
    public private(set) var sectionsUnavailable = false
    /// True once the session ended (signed out, expired or revoked): the app returns to sign-in.
    public private(set) var signedOut = false
    public private(set) var isBusy = false
    /// A report ready to share.
    public var report: PartnerReportFile?

    /// The user awaiting an inline remove confirmation, if any.
    public private(set) var pendingRemoval: PartnerUser?

    private let service: any PartnerService
    /// The signed-in partner user's id (from the overview, contract 2.3.0), so an admin can never
    /// remove themselves. Nil until the overview loads.
    public var currentUserID: String? { overview?.userID }

    public init(service: any PartnerService) {
        self.service = service
    }

    /// Plausible-address check for the invite field (same rule as Android): trimmed, at most 254
    /// characters, no whitespace, exactly one `@`, a non-empty local part and a domain of at least
    /// two non-empty dot-separated labels. The server remains the authority on deliverability.
    public static func isPlausibleEmail(_ raw: String) -> Bool { CredentialRules.isPlausibleEmail(raw) }

    /// Why this user cannot be removed, or nil when removal is allowed: never yourself, and never
    /// the last admin (the partner would be left with nobody able to manage users).
    private func removalBlock(for id: String) -> String? {
        if id == currentUserID { return "You can’t remove yourself." }
        if let user = users.first(where: { $0.id == id }), user.role == .admin,
           users.filter({ $0.role == .admin }).count <= 1 { return "You can’t remove the last admin." }
        return nil
    }

    public func canRemove(_ user: PartnerUser) -> Bool { role.canManageUsers && removalBlock(for: user.id) == nil }

    /// The current role, defaulting to the least-privileged VIEWER until the overview loads, so
    /// capability gates never open early.
    public var role: PartnerRole { overview?.role ?? .viewer }

    /// Runs one secondary section load. A lost session still fails the whole load; any other
    /// failure degrades just that section and raises `sectionsUnavailable`, so a failed fetch is
    /// never shown as a genuinely empty section.
    private func optional<T: Sendable>(_ call: @Sendable () async throws -> T) async throws -> T? {
        do { return try await call() }
        catch AccountError.signedOut { throw AccountError.signedOut }
        catch where error.isCancellation { throw CancellationError() }
        catch {
            sectionsUnavailable = true
            return nil
        }
    }

    public func load() async {
        let prior = phase
        phase = .loading
        do {
            // Overview first: it carries the role every other section and action is gated on.
            let overview = try await service.overview()
            self.overview = overview
            sectionsUnavailable = false
            let admin = overview.role.canExport
            let hasLogo = overview.hasLogo
            async let initiatives = optional { try await self.service.initiatives() }
            async let spend = optional { try await self.service.spend() }
            async let people = optional { try await self.service.people() }
            async let teams = optional { try await self.service.teams() }
            async let users = optional { try await self.service.users() }
            async let exports = optional { admin ? try await self.service.exports() : [] }
            async let logo = optional { hasLogo ? try await self.service.logo() : nil }
            self.initiatives = try await initiatives ?? []
            self.spend = try await spend ?? []
            self.people = try await people
            self.teams = try await teams ?? []
            self.users = try await users ?? []
            self.exports = try await exports ?? []
            self.logo = try await logo ?? nil
            phase = .ready
        } catch where error.isCancellation {
            phase = prior
        } catch AccountError.signedOut {
            signedOut = true
            phase = .failed(AccountError.signedOut.userMessage)
        } catch {
            phase = .failed(error.userMessage)
        }
    }

    /// Runs one portal action: one at a time, errors inline, and a lost session leaves the portal.
    private func act(_ success: String?, invalid: String? = nil, conflict: String? = nil,
                     _ work: () async throws -> Void) async {
        guard !isBusy else { return }
        isBusy = true
        defer { isBusy = false }
        actionError = nil
        notice = nil
        do {
            try await work()
            notice = success
        } catch where error.isCancellation {
            return
        } catch AccountError.signedOut {
            signedOut = true
        } catch AccountError.invalidInput where invalid != nil {
            actionError = invalid
        } catch AccountError.conflict where conflict != nil {
            actionError = conflict
        } catch let limit as PartnerReportLimit {
            actionError = limit.message
        } catch AccountError.forbidden {
            actionError = "Only an admin can do that."
        } catch {
            actionError = error.userMessage
        }
    }

    /// Invite a user (P-13), admin-only. Gated client-side; the server re-checks. A viewer call
    /// is a no-op that surfaces the gate rather than hitting the network.
    public func inviteUser(email: String, name: String, role: PartnerRole) async {
        guard self.role.canManageUsers else { actionError = "Only an admin can invite users."; return }
        guard Self.isPlausibleEmail(email) else { actionError = "Enter a valid email address."; return }
        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedName.isEmpty else { actionError = "Enter their name."; return }
        let address = email.trimmingCharacters(in: .whitespacesAndNewlines)
        await act("Invitation sent to \(address).", invalid: "Check the name and email address, then try again.",
                  conflict: "That email already signs in to DAD with another role or organization.") {
            try await service.inviteUser(email: address, name: trimmedName, role: role)
            users = (try? await service.users()) ?? users
        }
    }

    /// Step one of removal: stage the user for the inline confirmation. Nothing is sent yet.
    public func requestRemoval(id: String) {
        guard role.canManageUsers else { actionError = "Only an admin can remove users."; return }
        if let block = removalBlock(for: id) { actionError = block; return }
        actionError = nil
        pendingRemoval = users.first { $0.id == id }
    }

    public func cancelRemoval() { pendingRemoval = nil }

    public func confirmRemoval() async {
        guard let user = pendingRemoval else { return }
        pendingRemoval = nil
        await removeUser(id: user.id)
    }

    public func removeUser(id: String) async {
        guard role.canManageUsers else { actionError = "Only an admin can remove users."; return }
        if let block = removalBlock(for: id) { actionError = block; return }
        await act(nil, conflict: "You can’t remove the last admin.") {
            try await service.removeUser(id: id)
            users.removeAll { $0.id == id }
        }
    }

    public static let logoRule = "Use a PNG or JPEG image of at most 512 by 512 pixels."
    public static let profileRule = "Use a name of up to 200 characters and a description of up to 4,000."

    public func saveProfile(organization: String, description: String) async {
        guard role.canEditProfile else { actionError = "Only an admin can edit the organization profile."; return }
        let name = organization.trimmingCharacters(in: .whitespacesAndNewlines)
        let about = description.trimmingCharacters(in: .whitespacesAndNewlines)
        guard (1...200).contains(name.count), about.count <= 4000 else { actionError = Self.profileRule; return }
        await act("Organization profile saved.", invalid: Self.profileRule) {
            try await service.saveProfile(organization: name, description: about)
            overview = try await service.overview()
        }
    }

    public func saveWorkforce(_ raw: String) async {
        guard role.canEditProfile else { actionError = "Only an admin can set the workforce size."; return }
        let rule = "Enter the number of employees as a whole number."
        guard let size = Int(raw.trimmingCharacters(in: .whitespaces)), size >= 0 else { actionError = rule; return }
        await act("Workforce size saved.", invalid: rule) {
            try await service.saveWorkforce(size: size)
            overview = try await service.overview()
            people = (try? await service.people()) ?? people
        }
    }

    /// `png` is already scaled to fit the server's limits; nil removes the logo.
    public func saveLogo(png: Data?) async {
        guard role.canEditProfile else { actionError = "Only an admin can change the logo."; return }
        await act(png == nil ? "Logo removed." : "Logo saved.", invalid: Self.logoRule) {
            try await service.saveLogo(png: png)
            logo = png
        }
    }

    /// The picked image could not be read or scaled to the logo limits.
    public func rejectLogo() {
        notice = nil
        actionError = Self.logoRule
    }

    public func exportReport() async {
        guard role.canExport else { actionError = "Only an admin can export a report."; return }
        await act(nil) {
            report = try Self.file(try await service.report(), name: "DAD impact report")
            exports = (try? await service.exports()) ?? exports
        }
    }

    public func download(_ export: PartnerExport) async {
        guard role.canExport, export.downloadable else { return }
        await act(nil, invalid: nil) {
            do {
                report = try Self.file(try await service.retainedReport(id: export.id), name: "DAD impact report \(export.id.prefix(8))")
            } catch AccountError.notFound {
                actionError = "That report is no longer available. Export a new one."
                exports = (try? await service.exports()) ?? exports
            }
        }
    }

    public func signOut() async {
        try? await service.unregisterPushDevice()
        do {
            try await service.signOut()
            signedOut = true
        } catch {
            actionError = error.userMessage
        }
    }

    private static func file(_ pdf: Data, name: String) throws -> PartnerReportFile {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(name).appendingPathExtension("pdf")
        try pdf.write(to: url, options: .atomic)
        return PartnerReportFile(url: url)
    }

    /// Register this device for partner push after sign-in (§7.5). Best-effort — a push failure
    /// never blocks the portal.
    public func registerPush(token: String, environment: PushEnvironment) async {
        try? await service.registerPushDevice(token: token, environment: environment)
    }
}

// MARK: - Partner sign-in (approved partner users sign in with an emailed link)

public protocol PartnerSignInService: Sendable {
    func requestSignInLink(email: String) async throws
    /// Exchanges an emailed link's token for the partner session and keeps it.
    func accept(token: String) async throws
}

extension WirePartnerAuth: PartnerSignInService {}

@MainActor
@Observable
public final class PartnerSignInModel {
    public enum Phase: Sendable, Equatable { case editing, submitting, sent(String), accepting, signedIn, failed(String) }

    public var email = ""
    public private(set) var phase: Phase = .editing
    private let service: any PartnerSignInService

    public init(service: any PartnerSignInService) { self.service = service }

    public var canSubmit: Bool { CredentialRules.isPlausibleEmail(email) && phase != .submitting }

    public func submit() async {
        guard canSubmit else { return }
        let address = email.trimmingCharacters(in: .whitespacesAndNewlines)
        phase = .submitting
        do {
            try await service.requestSignInLink(email: address)
            phase = .sent(address)
        } catch where error.isCancellation {
            phase = .editing
        } catch AccountError.invalidInput {
            phase = .failed("Check your email address, then try again.")
        } catch AccountError.rateLimited {
            phase = .failed(AccountError.rateLimited.userMessage)
        } catch {
            phase = .failed("We couldn’t send your sign-in link right now. Please try again in a moment.")
        }
    }

    /// Signs in with the token from an emailed partner link, tapped or pasted.
    public func accept(token: String) async {
        guard phase != .accepting else { return }
        phase = .accepting
        do {
            try await service.accept(token: token)
            phase = .signedIn
        } catch where error.isCancellation {
            phase = .editing
        } catch AccountError.invalidInput {
            phase = .failed("That sign-in link has expired or was already used. Request a new one.")
        } catch AccountError.forbidden {
            phase = .failed("This partner account can’t sign in. Ask your organization’s admin or DAD support.")
        } catch {
            phase = .failed(error.userMessage)
        }
    }

    /// Accepts a pasted partner link (`…/partner/accept#token=…`) or a bare token.
    public func accept(pasted raw: String) async {
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        let token = URLComponents(string: text)?.fragment.flatMap { fragment in
            URLComponents(string: "?" + fragment)?.queryItems?.first { $0.name == "token" }?.value
        } ?? text
        guard !token.isEmpty, !token.contains(" ") else {
            phase = .failed("Paste the whole sign-in link from your email.")
            return
        }
        await accept(token: token)
    }

    public func edit() { phase = .editing }
}
