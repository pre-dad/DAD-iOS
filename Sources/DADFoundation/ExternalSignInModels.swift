import Foundation

// Sign in with Apple / Google (OIDC id_token exchange, `oidcSignIn`) and passkeys (WebAuthn,
// `beginDonorPasskeySignIn` / `finishDonorPasskeySignIn`). The platform ceremonies sit behind
// protocols (`IDTokenProvider`, `PasskeyAuthenticator`) implemented in the App target with
// AuthenticationServices; everything else here is platform-free and tested against stub transports.
// Each method is switched on only by `SignInCapabilities`, which needs build-time configuration
// the project does not ship with, so by default they are hidden from the sign-in screen.

// MARK: - Capability gating

/// Raw build configuration, read from Info.plist keys that expand from build settings. All three
/// are empty in the repository: the owner supplies them (see README "Switching on Apple, Google and passkeys").
public struct SignInConfig: Sendable, Equatable {
    public let appleSignInEnabled: Bool
    public let googleClientID: String?
    public let passkeyRelyingParty: String?

    public init(appleFlag: String?, googleClientID: String?, passkeyRelyingParty: String?) {
        appleSignInEnabled = ["yes", "true", "1"].contains((appleFlag ?? "").trimmingCharacters(in: .whitespaces).lowercased())
        let client = (googleClientID ?? "").trimmingCharacters(in: .whitespaces)
        self.googleClientID = client.range(of: "^[0-9A-Za-z._-]+\\.apps\\.googleusercontent\\.com$", options: .regularExpression) != nil ? client : nil
        let host = (passkeyRelyingParty ?? "").trimmingCharacters(in: .whitespaces).lowercased()
        self.passkeyRelyingParty = host.range(of: "^([a-z0-9]([a-z0-9-]*[a-z0-9])?\\.)+[a-z]{2,}$", options: .regularExpression) != nil ? host : nil
    }
}

/// Which optional sign-in methods can actually run in this build. Phone and password need no
/// client configuration and are always on; the rest are off until configured AND a platform
/// provider exists for them.
public struct SignInCapabilities: Sendable, Equatable {
    public let apple: Bool
    public let google: Bool
    public let passkey: Bool
    public static let none = SignInCapabilities(apple: false, google: false, passkey: false)

    public init(apple: Bool, google: Bool, passkey: Bool) { self.apple = apple; self.google = google; self.passkey = passkey }

    /// `googleProviderAvailable` is false until a Google id_token provider is linked into the App
    /// (see README); a client ID alone never switches Google on.
    public init(config: SignInConfig, googleProviderAvailable: Bool = false) {
        self.init(apple: config.appleSignInEnabled, google: config.googleClientID != nil && googleProviderAvailable,
                  passkey: config.passkeyRelyingParty != nil)
    }

    public func isAvailable(_ method: SignInMethod) -> Bool {
        switch method {
        case .phone, .emailLink, .password: true
        case .apple: apple
        case .google: google
        case .passkey: passkey
        }
    }

    /// True when any optional method is hidden, so the screen can say so in plain text.
    public var hasUnavailableMethod: Bool { !(apple && google && passkey) }
}

// MARK: - Seams

public enum OIDCProvider: String, Sendable, Equatable, CaseIterable {
    case apple, google
}

/// Why a platform ceremony ended without a token. `cancelled` is the person backing out and is
/// never shown as an error.
public enum ExternalSignInError: Error, Sendable, Equatable {
    case cancelled
    case unsupported
}

/// Produces a provider `id_token` through the platform sign-in UI (Apple: AuthenticationServices).
public protocol IDTokenProvider: Sendable {
    func idToken() async throws -> String
}

public protocol OIDCSignInService: Sendable {
    func signIn(provider: OIDCProvider, idToken: String) async throws -> Credentials
}

public struct PasskeyChallenge: Sendable, Equatable {
    public let ceremony: String
    public let challenge: Data
    public let relyingParty: String?
    public init(ceremony: String, challenge: Data, relyingParty: String?) {
        self.ceremony = ceremony; self.challenge = challenge; self.relyingParty = relyingParty
    }
}

public struct PasskeyAssertion: Sendable, Equatable {
    public let credentialID: Data
    public let clientDataJSON: Data
    public let authenticatorData: Data
    public let signature: Data
    public let userHandle: Data?
    public init(credentialID: Data, clientDataJSON: Data, authenticatorData: Data, signature: Data, userHandle: Data?) {
        self.credentialID = credentialID; self.clientDataJSON = clientDataJSON
        self.authenticatorData = authenticatorData; self.signature = signature; self.userHandle = userHandle
    }
}

/// Runs the WebAuthn assertion through the platform (ASAuthorizationPlatformPublicKeyCredentialProvider).
public protocol PasskeyAuthenticator: Sendable {
    func assertion(for challenge: PasskeyChallenge) async throws -> PasskeyAssertion
}

public protocol PasskeySignInService: Sendable {
    func begin() async throws -> PasskeyChallenge
    func finish(_ challenge: PasskeyChallenge, assertion: PasskeyAssertion) async throws -> Credentials
}

public struct PasskeySummary: Sendable, Equatable, Identifiable {
    public let id: String
    public let name: String?
    public init(id: String, name: String?) { self.id = id; self.name = name }
}

/// Passkey management for the signed-in donor (wired and tested; the settings UI follows with
/// the Associated Domains configuration).
public protocol PasskeyManagementService: Sendable {
    func list() async throws -> [PasskeySummary]
    func delete(id: String) async throws
}

extension Data {
    /// base64url without padding, the encoding WebAuthn JSON uses for binary fields.
    var base64URLEncoded: String {
        base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    init?(base64URL value: String) {
        var text = value.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        text += String(repeating: "=", count: (4 - text.count % 4) % 4)
        self.init(base64Encoded: text)
    }
}

extension PasskeyAssertion {
    /// The `PublicKeyCredential` JSON the server verifies (`credential.toJSON()` shape).
    var credentialJSON: [String: (any Sendable)?] {
        var response: [String: (any Sendable)?] = [
            "clientDataJSON": clientDataJSON.base64URLEncoded,
            "authenticatorData": authenticatorData.base64URLEncoded,
            "signature": signature.base64URLEncoded,
        ]
        if let userHandle { response["userHandle"] = userHandle.base64URLEncoded }
        return [
            "id": credentialID.base64URLEncoded, "rawId": credentialID.base64URLEncoded, "type": "public-key",
            "response": response, "clientExtensionResults": [String: (any Sendable)?](),
        ]
    }
}

// MARK: - Models

/// Shared phase for the one-tap external methods.
public enum ExternalSignInPhase: Equatable {
    case idle
    case working
    case failed(String)
    case signedIn(Credentials)
}

@MainActor @Observable
public final class OIDCSignInModel {
    public private(set) var phase: ExternalSignInPhase = .idle
    public let provider: OIDCProvider
    private let tokens: any IDTokenProvider
    private let service: any OIDCSignInService
    private let establish: PhoneSignInModel.Establish

    public init(provider: OIDCProvider, tokens: any IDTokenProvider, service: any OIDCSignInService,
                establish: @escaping PhoneSignInModel.Establish) {
        self.provider = provider; self.tokens = tokens; self.service = service; self.establish = establish
    }

    public func start() async {
        if case .working = phase { return }
        phase = .working
        do {
            let token = try await tokens.idToken()
            let service = self.service, provider = self.provider
            let credentials = try await establish { try await service.signIn(provider: provider, idToken: token) }
            phase = .signedIn(credentials)
        } catch {
            if error.isCancellation || error as? ExternalSignInError == .cancelled { phase = .idle; return }
            phase = .failed(message(for: error))
        }
    }

    private var name: String { provider == .apple ? "Apple" : "Google" }

    private func message(for error: Error) -> String {
        if error as? ExternalSignInError == .unsupported { return "\(name) sign-in isn’t available on this device." }
        return switch error as? AccountError {
        case .signedOut: "We couldn’t find a DAD account for that \(name) sign-in. Create your account with your email first."
        case .rateLimited: "Too many attempts. Please wait a moment and try again."
        case .unavailable: "\(name) sign-in isn’t available right now. Please try again in a moment."
        default: "Something went wrong. Please try again."
        }
    }
}

@MainActor @Observable
public final class PasskeySignInModel {
    public private(set) var phase: ExternalSignInPhase = .idle
    private let authenticator: any PasskeyAuthenticator
    private let service: any PasskeySignInService
    private let establish: PhoneSignInModel.Establish

    public init(authenticator: any PasskeyAuthenticator, service: any PasskeySignInService,
                establish: @escaping PhoneSignInModel.Establish) {
        self.authenticator = authenticator; self.service = service; self.establish = establish
    }

    public func start() async {
        if case .working = phase { return }
        phase = .working
        do {
            let challenge = try await service.begin()
            let assertion = try await authenticator.assertion(for: challenge)
            let service = self.service
            let credentials = try await establish { try await service.finish(challenge, assertion: assertion) }
            phase = .signedIn(credentials)
        } catch {
            if error.isCancellation || error as? ExternalSignInError == .cancelled { phase = .idle; return }
            phase = .failed(Self.message(for: error))
        }
    }

    static func message(for error: Error) -> String {
        if error as? ExternalSignInError == .unsupported { return "Passkeys aren’t available on this device." }
        return switch error as? AccountError {
        case .signedOut: "That passkey didn’t work. Try another sign-in method."
        case .rateLimited: "Too many attempts. Please wait a moment and try again."
        case .unavailable: "Passkey sign-in isn’t available right now. Please try again in a moment."
        default: "Something went wrong. Please try again."
        }
    }
}
