import Foundation

// Email signup, email + password sign-in, and set/change password (PRD §5.1, D-2). Pure rules,
// service seams and state machines, unit-tested without a network or a view.
// Passwords are never stored, logged or echoed: models clear them once a call succeeds or the session ends, and
// keep them after any other failure so the donor can retry.

// MARK: - Shared input rules

/// Input rules shared by signup, password sign-in and the partner invite field.
public enum CredentialRules {
    /// Plausible-address check (same rule as Android and the partner invite field): trimmed, at
    /// most 254 characters, no whitespace, exactly one `@`, a non-empty local part and a domain of
    /// at least two non-empty dot-separated labels. The server stays the authority on deliverability.
    public static func isPlausibleEmail(_ raw: String) -> Bool {
        let email = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard email.count <= 254, !email.contains(where: \.isWhitespace) else { return false }
        let parts = email.split(separator: "@", omittingEmptySubsequences: false)
        guard parts.count == 2, !parts[0].isEmpty else { return false }
        let labels = parts[1].split(separator: ".", omittingEmptySubsequences: false)
        return labels.count >= 2 && labels.allSatisfy { !$0.isEmpty }
    }

    /// The contract and server accept a new password of 12 to 72 BYTES (bcrypt's limit).
    public static let passwordBytes = 12...72
    /// Shown wherever the length rule is stated: the limit counts bytes, and some symbols are more than one.
    public static let passwordRule = "Use 12 to 72 bytes; some symbols count as more than one."

    public static func isAcceptableNewPassword(_ password: String) -> Bool {
        passwordBytes.contains(password.utf8.count)
    }

    /// Sign-in only needs a non-empty value the server can bound-check; over 72 bytes can never match.
    public static func isSubmittablePassword(_ password: String) -> Bool {
        (1...72).contains(password.utf8.count)
    }

    /// US ZIP: exactly five digits (the server derives local-day rollover from it, §10).
    public static func isPlausibleZip(_ raw: String) -> Bool {
        raw.trimmingCharacters(in: .whitespaces).range(of: "^[0-9]{5}$", options: .regularExpression) != nil
    }
}

// MARK: - Services

public struct SignupForm: Sendable, Equatable {
    public let name: String
    public let email: String
    public let zip: String
    public let city: String
    public init(name: String, email: String, zip: String, city: String) {
        self.name = name; self.email = email; self.zip = zip; self.city = city
    }
}

/// New-donor signup (D-2). The server never reveals whether the address already exists and
/// replies only that a single-use sign-in link was emailed; the link is claimed via `AccountSession.claim`.
public protocol SignupService: Sendable {
    func requestSignup(_ form: SignupForm) async throws
}

/// An existing donor asks for a single-use sign-in link (`POST /donor/login`). Like signup, the
/// server never says whether the address has an account; the link is claimed via `AccountSession.claim`.
public protocol SignInLinkService: Sendable {
    func requestSignInLink(email: String) async throws
}

public protocol PasswordSignInService: Sendable {
    /// Returns native credentials; the caller hands them to `AccountSession.establish`.
    func signIn(email: String, password: String) async throws -> Credentials
}

/// Set or change the signed-in donor's password. `current` may be nil right after a fresh
/// sign-in, when the server accepts the recent authentication instead.
public protocol PasswordSettingsService: Sendable {
    func setPassword(current: String?, new: String) async throws
}

// MARK: - Signup model

@MainActor @Observable
public final class SignupModel {
    public enum Phase: Equatable {
        case editing
        case submitting
        case sent(email: String)
        case failed(String)
    }

    public private(set) var phase: Phase = .editing
    public var name = ""
    public var email = ""
    public var zip = ""
    public var city = ""

    private let service: any SignupService
    public init(service: any SignupService) { self.service = service }

    public var canSubmit: Bool {
        if case .submitting = phase { return false }
        return !trimmedName.isEmpty && trimmedName.count <= 100 && CredentialRules.isPlausibleEmail(email)
            && CredentialRules.isPlausibleZip(zip) && !trimmedCity.isEmpty && trimmedCity.count <= 100
    }

    private var trimmedName: String { name.trimmingCharacters(in: .whitespacesAndNewlines) }
    private var trimmedCity: String { city.trimmingCharacters(in: .whitespacesAndNewlines) }

    public func submit() async {
        guard canSubmit else { return }
        phase = .submitting
        let cleanEmail = email.trimmingCharacters(in: .whitespacesAndNewlines)
        do {
            try await service.requestSignup(SignupForm(
                name: trimmedName, email: cleanEmail, zip: zip.trimmingCharacters(in: .whitespaces), city: trimmedCity))
            phase = .sent(email: cleanEmail)
        } catch {
            if error.isCancellation { phase = .editing; return }
            phase = .failed(Self.message(for: error))
        }
    }

    /// Back to the form after a failure or to change the address; entered values are kept.
    public func edit() { phase = .editing }

    static func message(for error: Error) -> String {
        switch error as? AccountError {
        case .invalidInput: "Check your name, email, city and ZIP code, then try again."
        case .rateLimited: "Too many attempts. Please wait a moment and try again."
        case .unavailable: "We couldn’t send your sign-in link right now. Please try again in a moment."
        default: "Something went wrong. Please try again."
        }
    }
}

// MARK: - Sign-in link model

@MainActor @Observable
public final class SignInLinkModel {
    public enum Phase: Equatable {
        case editing
        case submitting
        case sent(email: String)
        case failed(String)
    }

    public private(set) var phase: Phase = .editing
    public var email = ""

    private let service: any SignInLinkService
    public init(service: any SignInLinkService) { self.service = service }

    public var canSubmit: Bool {
        if case .submitting = phase { return false }
        return CredentialRules.isPlausibleEmail(email)
    }

    public func submit() async {
        guard canSubmit else { return }
        phase = .submitting
        let cleanEmail = email.trimmingCharacters(in: .whitespacesAndNewlines)
        do {
            try await service.requestSignInLink(email: cleanEmail)
            phase = .sent(email: cleanEmail)
        } catch {
            if error.isCancellation { phase = .editing; return }
            phase = .failed(Self.message(for: error))
        }
    }

    public func edit() { phase = .editing }

    static func message(for error: Error) -> String {
        switch error as? AccountError {
        case .invalidInput: "Check your email address, then try again."
        case .rateLimited: "Too many attempts. Please wait a moment and try again."
        case .unavailable: "We couldn’t send your sign-in link right now. Please try again in a moment."
        default: "Something went wrong. Please try again."
        }
    }
}

// MARK: - Password sign-in model

@MainActor @Observable
public final class PasswordSignInModel {
    public enum Phase: Equatable {
        case editing
        case submitting
        case failed(String)
        case signedIn(Credentials)
    }

    public private(set) var phase: Phase = .editing
    public var email = ""
    public var password = ""

    private let service: any PasswordSignInService
    private let establish: PhoneSignInModel.Establish

    public init(service: any PasswordSignInService, establish: @escaping PhoneSignInModel.Establish) {
        self.service = service
        self.establish = establish
    }

    public var canSubmit: Bool {
        if case .submitting = phase { return false }
        return CredentialRules.isPlausibleEmail(email) && CredentialRules.isSubmittablePassword(password)
    }

    public func submit() async {
        guard canSubmit else { return }
        phase = .submitting
        let service = self.service
        let cleanEmail = email.trimmingCharacters(in: .whitespacesAndNewlines)
        let secret = password
        // The password leaves the model the moment it is handed to the call; a failure re-asks for it.
        password = ""
        do {
            let credentials = try await establish { try await service.signIn(email: cleanEmail, password: secret) }
            phase = .signedIn(credentials)
        } catch {
            if error.isCancellation { phase = .editing; return }
            phase = .failed(Self.message(for: error))
        }
    }

    static func message(for error: Error) -> String {
        switch error as? AccountError {
        case .signedOut: "The email or password is incorrect."
        case .invalidInput: "Check your email and password, then try again."
        case .rateLimited: "Too many attempts. Please wait a moment and try again."
        case .unavailable: "We couldn’t reach DAD. Please try again in a moment."
        default: "Something went wrong. Please try again."
        }
    }
}

// MARK: - Set / change password (Settings)

@MainActor @Observable
public final class PasswordChangeModel {
    public enum Phase: Equatable {
        case editing
        case saving
        case saved
        case failed(String)
    }

    public private(set) var phase: Phase = .editing
    /// True once the session ended (expired / revoked) so the screen leaves the signed-in shell.
    public private(set) var signedOut = false
    public var currentPassword = ""
    public var newPassword = ""
    public var confirmPassword = ""

    private let service: any PasswordSettingsService
    public init(service: any PasswordSettingsService) { self.service = service }

    public var newPasswordHint: String? {
        guard !newPassword.isEmpty, !CredentialRules.isAcceptableNewPassword(newPassword) else { return nil }
        return CredentialRules.passwordRule
    }

    public var confirmMismatch: Bool { !confirmPassword.isEmpty && confirmPassword != newPassword }

    public var canSave: Bool {
        if case .saving = phase { return false }
        return CredentialRules.isAcceptableNewPassword(newPassword) && newPassword == confirmPassword
            && currentPassword.utf8.count <= 72
    }

    public func save() async {
        guard canSave else { return }
        phase = .saving
        let current = currentPassword.isEmpty ? nil : currentPassword
        let new = newPassword
        do {
            try await service.setPassword(current: current, new: new)
            currentPassword = ""; newPassword = ""; confirmPassword = ""
            phase = .saved
        } catch {
            if error.isCancellation { phase = .editing; return }
            if error as? AccountError == .signedOut {
                signedOut = true
                currentPassword = ""; newPassword = ""; confirmPassword = ""
            }
            phase = .failed(Self.message(for: error))
        }
    }

    public func edit() { phase = .editing }

    static func message(for error: Error) -> String {
        switch error as? AccountError {
        case .passwordIncorrect: "Your current password didn’t match. Check it and try again."
        case .invalidInput: CredentialRules.passwordRule
        case .rateLimited: "Too many attempts. Please wait a moment and try again."
        case .signedOut: "Please sign in again."
        case .unavailable: "We couldn’t save your password right now. Please try again in a moment."
        default: "Something went wrong. Please try again."
        }
    }
}
