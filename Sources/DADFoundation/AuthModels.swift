import Foundation

/// The sign-in methods offered on the auth screen (PRD §5.1). Email+password and phone+SMS
/// are credential flows; Apple/Google are OIDC token exchanges; passkey is WebAuthn. Order is
/// the display order. The admin console is web-only and never appears here.
public enum SignInMethod: String, Sendable, Equatable, CaseIterable, Identifiable {
    case passkey
    case phone
    case emailLink
    case apple
    case google
    case password
    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .passkey: "Sign in with a passkey"
        case .phone: "Continue with phone"
        case .emailLink: "Email me a sign-in link"
        case .apple: "Sign in with Apple"
        case .google: "Sign in with Google"
        case .password: "Sign in with email & password"
        }
    }
}

/// Transport seam for the sign-in flows, so view models are unit-testable without a network.
/// `WireAuth` implements this against the generated client; tests substitute a fake.
public protocol SignInService: Sendable {
    /// Request a one-time SMS code for `phone` (E.164). Returns a handle that `verifyPhone`
    /// consumes — opaque so the wire layer can carry a server challenge/session id.
    func requestPhoneCode(phone: String) async throws -> String
    /// Verify the SMS `code` against the handle from `requestPhoneCode`, returning credentials.
    func verifyPhone(handle: String, code: String) async throws -> Credentials
}

/// Drives the phone + SMS one-time-code journey: pick number → request code → enter code → done.
/// Explicit state machine so every transition is unit-testable; the view binds to `phase`.
@MainActor @Observable
public final class PhoneSignInModel {
    public enum Phase: Equatable {
        case enterPhone
        case requestingCode
        case enterCode(handle: String)
        case verifying(handle: String)
        case failed(String)
        case signedIn(Credentials)
    }

    public private(set) var phase: Phase = .enterPhone
    public var phone: String = ""
    public var code: String = ""

    /// The SMS challenge handle, retained across `verifying`/`failed` so a retry re-uses it
    /// instead of requesting a fresh code. Cleared only when returning to the phone screen.
    private var activeHandle: String?

    /// True once a code has been sent and not abandoned, including after a wrong code: the
    /// screen stays on code entry so the donor retries without requesting a fresh SMS.
    public var isAwaitingCode: Bool {
        switch phase {
        case .enterCode, .verifying: true
        case .failed: activeHandle != nil
        default: false
        }
    }

    /// Runs the credential-producing work inside the session (`AccountSession.establish`) so the
    /// session owns the await and its epoch guard: a sign-in that resolves after a sign-out is
    /// discarded instead of clobbering state. Returns the credentials that were installed.
    public typealias Establish = @Sendable (@Sendable () async throws -> Credentials) async throws -> Credentials

    private let service: any SignInService
    private let establish: Establish

    public init(service: any SignInService, establish: @escaping Establish) {
        self.service = service
        self.establish = establish
    }

    /// The typed number as E.164 (US numbers may be typed with or without +1, spaces, dashes or
    /// parentheses), or nil when it cannot be sent: not 8–15 digits after a leading +.
    public var normalizedPhone: String? {
        guard let e164 = ProfileRules.e164(phone), !e164.isEmpty,
              e164.range(of: "^\\+[1-9][0-9]{7,14}$", options: .regularExpression) != nil else { return nil }
        return e164
    }

    public var canRequestCode: Bool { normalizedPhone != nil }

    /// Shown under the phone field once something is typed that cannot be sent, so a disabled
    /// button never goes unexplained.
    public var phoneFormatHint: String? {
        phone.trimmingCharacters(in: .whitespaces).isEmpty || canRequestCode
            ? nil : "Enter a US number like (555) 123-4567, or include your country code, like +44 20 7946 0958."
    }

    /// The server issues 6-digit codes; enable verify only when the field is complete.
    public var canVerify: Bool {
        code.range(of: "^[0-9]{6}$", options: .regularExpression) != nil
    }

    public func requestCode() async {
        guard let number = normalizedPhone else { return }
        if case .requestingCode = phase { return }
        phase = .requestingCode
        do {
            let handle = try await service.requestPhoneCode(phone: number)
            activeHandle = handle
            phase = .enterCode(handle: handle)
        } catch where error.isCancellation {
            phase = .enterPhone
        } catch {
            activeHandle = nil
            phase = .failed(Self.message(for: error, verifying: false))
        }
    }

    public func verify() async {
        guard canVerify, let handle = activeHandle else { return }
        if case .verifying = phase { return }
        phase = .verifying(handle: handle)
        do {
            let service = self.service
            let credentials = try await establish { try await service.verifyPhone(handle: handle, code: code) }
            phase = .signedIn(credentials)
        } catch where error.isCancellation {
            phase = .enterCode(handle: handle)
        } catch {
            // Keep the handle so the user can re-enter the code without re-requesting.
            phase = .failed(Self.message(for: error, verifying: true))
        }
    }

    /// The same server error means different things on the two calls: a 401 or 400 on verify is a
    /// wrong code, but on request it is not about the code at all.
    private static func message(for error: Error, verifying: Bool) -> String {
        switch error {
        case AccountError.signedOut where verifying, AccountError.invalidInput where verifying:
            "That code didn’t match. Check it and try again."
        case AccountError.invalidInput: "That phone number doesn’t look right. Check it and try again."
        case AccountError.unavailable: "We couldn’t reach DAD. Please try again in a moment."
        case AccountError.rateLimited: "Too many attempts. Please wait a moment and try again."
        default: "Something went wrong. Please try again."
        }
    }
}
