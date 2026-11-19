import Foundation

// Account management beyond preferences (PRD §6.12, EM-2/EM-4/EM-5): contact details, the account
// email, where the donor is signed in, and their employer and team. Each model owns its own phase
// so a failure in one card never blanks the rest of Settings.

public struct DeviceSessionSummary: Sendable, Equatable, Identifiable {
    public let id: String
    public let label: String
    public let isApp: Bool
    public let lastUsedAt: Date
    public let current: Bool
    public init(id: String, label: String, isApp: Bool, lastUsedAt: Date, current: Bool) {
        self.id = id; self.label = label; self.isApp = isApp; self.lastUsedAt = lastUsedAt; self.current = current
    }
}

public struct TeamStanding: Sendable, Equatable, Identifiable {
    public let id: String
    public let name: String
    public let activeGivers: Int64
    public let annualizedMinor: Int64
    public let avgStreakDays: Int64
    public let volunteerMinutes: Int64
    public let metricsVerified: Bool
    public init(id: String, name: String, activeGivers: Int64, annualizedMinor: Int64, avgStreakDays: Int64, volunteerMinutes: Int64, metricsVerified: Bool = false) {
        self.id = id; self.name = name; self.activeGivers = activeGivers; self.annualizedMinor = annualizedMinor
        self.avgStreakDays = avgStreakDays; self.volunteerMinutes = volunteerMinutes; self.metricsVerified = metricsVerified
    }
}

/// The donor's employer link. `organization` is nil until a company code links one; the leaderboard
/// only lists teams of five or more (EM-5), so it can be empty while linked.
public struct EmployerTeam: Sendable, Equatable {
    public let organization: String?
    public let teamName: String?
    public let leaderboard: [TeamStanding]
    public init(organization: String?, teamName: String?, leaderboard: [TeamStanding]) {
        self.organization = organization; self.teamName = teamName; self.leaderboard = leaderboard
    }
}

public protocol AccountManagementService: Sendable {
    /// Empty strings clear a field. Returns the saved profile.
    func saveProfile(zip: String, city: String, phone: String, timezoneOverride: String?) async throws -> AccountProfileSummary
    /// Starts the two-step change: a confirmation goes to the current address first.
    func requestEmailChange(to email: String) async throws
    func sessions() async throws -> [DeviceSessionSummary]
    func revokeSession(id: String) async throws -> [DeviceSessionSummary]
    func revokeOtherSessions() async throws -> [DeviceSessionSummary]
    /// Ends every session, this one included, then clears local credentials.
    func signOutEverywhere() async throws
    func employer() async throws -> EmployerTeam
    /// Returns the linked organization's name.
    func enroll(companyCode: String) async throws -> String
    func joinTeam(name: String) async throws
}

public extension AccountManagementService {
    func saveProfile(zip: String, city: String, phone: String) async throws -> AccountProfileSummary {
        try await saveProfile(zip: zip, city: city, phone: phone, timezoneOverride: nil)
    }
}

public enum StreakTimeZone {
    public static let choices: [(value: String, label: String)] = [
        ("", "Use ZIP suggestion"),
        ("America/New_York", "Eastern"), ("America/Chicago", "Central"),
        ("America/Denver", "Mountain"), ("America/Phoenix", "Arizona"),
        ("America/Los_Angeles", "Pacific"), ("America/Anchorage", "Alaska"),
        ("America/Adak", "Aleutian Islands"), ("Pacific/Honolulu", "Hawaii"),
        ("America/Puerto_Rico", "Puerto Rico / US Virgin Islands"),
        ("Pacific/Guam", "Guam / Northern Mariana Islands"),
        ("Pacific/Pago_Pago", "American Samoa")
    ]
}

public enum ProfileRules {
    public static let cityLimit = 80

    /// US ZIP or ZIP+4, or empty to clear it — the contract's pattern.
    public static func isAcceptableZip(_ raw: String) -> Bool {
        let zip = raw.trimmingCharacters(in: .whitespaces)
        return zip.isEmpty || zip.range(of: "^[0-9]{5}(-[0-9]{4})?$", options: .regularExpression) != nil
    }

    /// The number as E.164, accepting the ways people type a US number; "" for an empty field and
    /// nil when it cannot be one.
    public static func e164(_ raw: String) -> String? {
        let trimmed = raw.trimmingCharacters(in: .whitespaces)
        if trimmed.isEmpty { return "" }
        let plus = trimmed.hasPrefix("+")
        let body = plus ? trimmed.dropFirst() : Substring(trimmed)
        guard body.allSatisfy({ $0.isASCII && ($0.isNumber || " -().".contains($0)) }) else { return nil }
        let digits = body.filter(\.isNumber)
        let candidate: String
        if plus { candidate = "+" + digits }
        else if digits.count == 10 { candidate = "+1" + digits }
        else if digits.count == 11, digits.hasPrefix("1") { candidate = "+" + digits }
        else { return nil }
        return candidate.range(of: "^\\+[1-9][0-9]{1,14}$", options: .regularExpression) != nil ? candidate : nil
    }
}

@MainActor
@Observable
public final class ProfileDetailsModel {
    public enum Phase: Sendable, Equatable { case idle, saving, saved, failed(String) }

    public private(set) var profile: AccountProfileSummary
    public var zip: String
    public var city: String
    public var phone: String
    public var timezoneOverride: String
    public private(set) var phase: Phase = .idle
    private let service: any AccountManagementService

    public init(profile: AccountProfileSummary, service: any AccountManagementService) {
        self.profile = profile; self.service = service
        zip = profile.zip ?? ""; city = profile.city ?? ""; phone = profile.phone ?? ""
        timezoneOverride = profile.timezoneOverride ?? ""
    }

    public var zipValid: Bool { ProfileRules.isAcceptableZip(zip) }
    public var phoneValid: Bool { ProfileRules.e164(phone) != nil }
    public var cityValid: Bool { trimmedCity.count <= ProfileRules.cityLimit }
    private var trimmedCity: String { city.trimmingCharacters(in: .whitespaces) }
    private var trimmedZip: String { zip.trimmingCharacters(in: .whitespaces) }

    public var changed: Bool {
        timezoneOverride != (profile.timezoneOverride ?? "") || trimmedZip != (profile.zip ?? "") || trimmedCity != (profile.city ?? "") || ProfileRules.e164(phone) != (profile.phone ?? "")
    }

    public var canSave: Bool { zipValid && phoneValid && cityValid && StreakTimeZone.choices.contains(where: { $0.value == timezoneOverride }) && changed && phase != .saving }

    public func save() async {
        guard canSave, let phone = ProfileRules.e164(phone) else { return }
        phase = .saving
        do {
            profile = try await service.saveProfile(zip: trimmedZip, city: trimmedCity, phone: phone, timezoneOverride: timezoneOverride)
            zip = profile.zip ?? ""; city = profile.city ?? ""; self.phone = profile.phone ?? ""
            timezoneOverride = profile.timezoneOverride ?? ""
            phase = .saved
        } catch where error.isCancellation {
            phase = .idle
        } catch AccountError.invalidInput {
            phase = .failed("Check the ZIP code and phone number, then try again.")
        } catch {
            phase = .failed(error.userMessage)
        }
    }
}

@MainActor
@Observable
public final class EmailChangeModel {
    public enum Phase: Sendable, Equatable { case editing, submitting, sent, failed(String) }

    public var email = ""
    public private(set) var phase: Phase = .editing
    private let current: String
    private let service: any AccountManagementService

    public init(current: String, service: any AccountManagementService) { self.current = current; self.service = service }

    private var trimmed: String { email.trimmingCharacters(in: .whitespacesAndNewlines) }

    public var canSubmit: Bool {
        CredentialRules.isPlausibleEmail(trimmed) && trimmed.lowercased() != current.lowercased() && phase != .submitting
    }

    public func submit() async {
        guard canSubmit else { return }
        phase = .submitting
        do {
            try await service.requestEmailChange(to: trimmed)
            phase = .sent
        } catch where error.isCancellation {
            phase = .editing
        } catch AccountError.invalidInput {
            phase = .failed("Check the email address and try again.")
        } catch AccountError.conflict {
            phase = .failed("That address can’t replace your account email. Existing accounts are never merged.")
        } catch AccountError.unavailable {
            phase = .failed("We couldn’t request the change right now. Please try again in a moment.")
        } catch {
            phase = .failed(error.userMessage)
        }
    }

    public func edit() { phase = .editing }
}

@MainActor
@Observable
public final class DeviceSessionsModel {
    public enum Phase: Sendable, Equatable { case loading, ready, failed(String) }

    public private(set) var phase: Phase = .loading
    public private(set) var sessions: [DeviceSessionSummary] = []
    public private(set) var isBusy = false
    public private(set) var actionError: String?
    public private(set) var notice: String?
    /// True once "sign out everywhere" ended this session too.
    public private(set) var signedOut = false
    private let service: any AccountManagementService

    public init(service: any AccountManagementService) { self.service = service }

    public var others: [DeviceSessionSummary] { sessions.filter { !$0.current } }

    public func load() async {
        phase = .loading
        do {
            sessions = try await service.sessions()
            phase = .ready
        } catch where error.isCancellation {
            return
        } catch {
            phase = .failed("Your signed-in devices couldn’t be loaded right now. Please try again in a moment.")
        }
    }

    public func revoke(_ id: String) async {
        await act { self.sessions = try await self.service.revokeSession(id: id) }
    }

    public func revokeOthers() async {
        await act {
            self.sessions = try await self.service.revokeOtherSessions()
            self.notice = "Signed out of every other device."
        }
    }

    public func signOutEverywhere() async {
        await act {
            try await self.service.signOutEverywhere()
            self.signedOut = true
        }
    }

    private func act(_ work: @MainActor () async throws -> Void) async {
        guard !isBusy else { return }
        isBusy = true
        defer { isBusy = false }
        actionError = nil
        notice = nil
        do { try await work() }
        catch where error.isCancellation { return }
        catch AccountError.notFound { await load() }
        catch AccountError.signedOut { signedOut = true }
        catch { actionError = "Sign-out wasn’t confirmed. Refresh the list to check before trying again." }
    }
}

@MainActor
@Observable
public final class EmployerModel {
    public enum Phase: Sendable, Equatable { case loading, ready(EmployerTeam), failed(String) }

    public private(set) var phase: Phase = .loading
    public var companyCode = ""
    public var teamName = ""
    public private(set) var isBusy = false
    public private(set) var actionError: String?
    private let service: any AccountManagementService

    public init(service: any AccountManagementService) { self.service = service }

    public var canEnroll: Bool { !companyCode.trimmingCharacters(in: .whitespaces).isEmpty && !isBusy }
    public var canJoinTeam: Bool {
        let name = teamName.trimmingCharacters(in: .whitespaces)
        return !name.isEmpty && name.count <= 80 && !isBusy
    }

    public func load() async {
        phase = .loading
        do { phase = .ready(try await service.employer()) }
        catch where error.isCancellation { return }
        catch { phase = .failed("Your employer details couldn’t be loaded right now. Please try again in a moment.") }
    }

    public func enroll() async {
        guard canEnroll else { return }
        let code = companyCode.trimmingCharacters(in: .whitespaces)
        await act(
            invalid: "That company code isn’t recognized. Check it with your employer and try again.",
            conflict: "Your account is already linked to another employer.") {
            _ = try await self.service.enroll(companyCode: code)
            self.companyCode = ""
        }
    }

    public func joinTeam() async {
        guard canJoinTeam else { return }
        let name = teamName.trimmingCharacters(in: .whitespaces)
        await act(invalid: "That team name couldn’t be saved. Use up to 80 characters.", conflict: nil) {
            try await self.service.joinTeam(name: name)
            self.teamName = ""
        }
    }

    private func act(invalid: String, conflict: String?, _ work: @MainActor () async throws -> Void) async {
        isBusy = true
        defer { isBusy = false }
        actionError = nil
        do {
            try await work()
            phase = .ready(try await service.employer())
        } catch where error.isCancellation {
            return
        } catch AccountError.invalidInput {
            actionError = invalid
        } catch AccountError.conflict where conflict != nil {
            actionError = conflict
        } catch {
            actionError = error.userMessage
        }
    }
}
