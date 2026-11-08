import Foundation
import OpenAPIRuntime

/// Unauthenticated credential flows over the generated client: email signup (`postDonorSignup`),
/// an emailed sign-in link for an existing donor (`login`),
/// email + password sign-in (`postDonorPasswordSignIn`), Sign in with Apple/Google (`oidcSignIn`)
/// and passkey sign-in (`beginDonorPasskeySignIn` / `finishDonorPasskeySignIn`).
///
/// Same shape as `WireAuth`: sign-in methods return credentials but never store them; the caller
/// passes the call to `AccountSession.establish { ... }` so the session owns the await and its
/// epoch guard. No secret (password, id_token, assertion) is ever logged or placed in an error.
public struct WireCredentialAuth: SignupService, SignInLinkService, PasswordSignInService, OIDCSignInService, PasskeySignInService {
    private let origin: URL
    private let transport: any ClientTransport
    private let deviceName: String?

    public init(origin: URL, deviceName: String? = nil) throws {
        guard origin.isBareHTTPSOrigin else { throw AccountError.invalidConfiguration }
        self.init(origin: origin, transport: makeNativeTransport(), deviceName: deviceName)
    }

    init(origin: URL, transport: any ClientTransport, deviceName: String? = nil) {
        self.origin = origin; self.transport = transport
        self.deviceName = deviceName.map { String($0.prefix(64)) }
    }

    private var client: Client {
        Client(serverURL: origin, transport: transport, middlewares: [NativeHeaders(access: { nil })])
    }

    // MARK: Signup

    public func requestSignup(_ form: SignupForm) async throws {
        let body = Operations.postDonorSignup.Input.Body.jsonPayload(name: form.name, email: form.email, zip: form.zip, city: form.city)
        switch try await client.postDonorSignup(.init(body: .json(body))) {
        case .ok: return
        // Contract 2.4 answers 200 `{"sent":true}`; an older server's 202 means the same thing (a
        // link was emailed), so any 2xx is accepted without reading the body.
        case .undocumented(let status, _) where (200..<300).contains(status): return
        case .unprocessableContent: throw AccountError.invalidInput
        case .tooManyRequests: throw AccountError.rateLimited
        default: throw AccountError.unavailable
        }
    }

    // MARK: Sign-in link

    public func requestSignInLink(email: String) async throws {
        switch try await client.login(.init(body: .json(.init(email: email)))) {
        case .accepted: return
        case .unprocessableContent: throw AccountError.invalidInput
        case .tooManyRequests: throw AccountError.rateLimited
        default: throw AccountError.unavailable
        }
    }

    // MARK: Password sign-in

    public func signIn(email: String, password: String) async throws -> Credentials {
        let body = Operations.postDonorPasswordSignIn.Input.Body.jsonPayload(
            email: email, password: password, device_name: deviceName, platform: .IOS)
        switch try await client.postDonorPasswordSignIn(.init(body: .json(body))) {
        case .ok(let response):
            guard case .NativeSession(let session) = try response.body.json else { throw AccountError.invalidResponse }
            return try nativeCredentials(session)
        case .unauthorized: throw AccountError.signedOut
        case .unprocessableContent: throw AccountError.invalidInput
        case .tooManyRequests: throw AccountError.rateLimited
        default: throw AccountError.unavailable
        }
    }

    // MARK: Apple / Google

    public func signIn(provider: OIDCProvider, idToken: String, nonce: String) async throws -> Credentials {
        guard !idToken.isEmpty, idToken.utf8.count <= 8192, (1...256).contains(nonce.count) else { throw AccountError.invalidInput }
        let path = Operations.oidcSignIn.Input.Path(provider: provider == .apple ? .apple : .google)
        let body = Operations.oidcSignIn.Input.Body.jsonPayload(id_token: idToken, nonce: nonce, device_name: deviceName, platform: .IOS)
        switch try await client.oidcSignIn(.init(path: path, body: .json(body))) {
        case .ok(let response):
            guard case .NativeSession(let session) = try response.body.json else { throw AccountError.invalidResponse }
            return try nativeCredentials(session)
        case .unauthorized: throw AccountError.signedOut
        case .unprocessableContent: throw AccountError.invalidInput
        case .tooManyRequests: throw AccountError.rateLimited
        default: throw AccountError.unavailable
        }
    }

    // MARK: Passkey

    public func begin() async throws -> PasskeyChallenge {
        switch try await client.beginDonorPasskeySignIn(.init()) {
        case .ok(let response):
            let ceremony = try response.body.json
            guard !ceremony.ceremony.isEmpty, let text = ceremony.options.value["challenge"] as? String,
                  let challenge = Data(base64URL: text), !challenge.isEmpty else { throw AccountError.invalidResponse }
            return PasskeyChallenge(ceremony: ceremony.ceremony, challenge: challenge, relyingParty: ceremony.options.value["rpId"] as? String)
        case .tooManyRequests: throw AccountError.rateLimited
        default: throw AccountError.unavailable
        }
    }

    public func finish(_ challenge: PasskeyChallenge, assertion: PasskeyAssertion) async throws -> Credentials {
        let credential = try OpenAPIObjectContainer(unvalidatedValue: assertion.credentialJSON)
        let body = Operations.finishDonorPasskeySignIn.Input.Body.jsonPayload(
            ceremony: challenge.ceremony, credential: credential, device_name: deviceName, platform: .IOS)
        switch try await client.finishDonorPasskeySignIn(.init(body: .json(body))) {
        case .ok(let response):
            guard case .NativeSession(let session) = try response.body.json else { throw AccountError.invalidResponse }
            return try nativeCredentials(session)
        case .unauthorized: throw AccountError.signedOut
        case .unprocessableContent: throw AccountError.invalidInput
        case .tooManyRequests: throw AccountError.rateLimited
        default: throw AccountError.unavailable
        }
    }
}

/// Authenticated password management (`postDonorMePassword`) through the session.
///
/// A wrong `current_password` answers 422 with `code` `CURRENT_PASSWORD_INCORRECT` (contract 2.4):
/// the session is fine, so it surfaces as `AccountError.passwordIncorrect` and never ends the session.
/// Any other 401 is a real session failure and takes the normal refresh-once path. Servers older than
/// 2.4 answered a wrong password with a 401 carrying `rejectedDetail`; that is still read as a wrong
/// password. A 422 body whose `code` is unknown (or unreadable) is plain invalid input.
public struct WirePasswordSettings: PasswordSettingsService, PasskeyManagementService {
    private let product: ProductClient
    static let wrongCurrentCode = "CURRENT_PASSWORD_INCORRECT"
    static let rejectedDetail = "The email or password is incorrect"

    public init(origin: URL, session: AccountSession) throws {
        self.init(product: try ProductClient(origin: origin, session: session))
    }

    init(product: ProductClient) { self.product = product }

    public func setPassword(current: String?, new: String) async throws {
        let body = Operations.postDonorMePassword.Input.Body.jsonPayload(current_password: current, password: new)
        try await product.perform { client in
            switch try await client.postDonorMePassword(.init(body: .json(body))) {
            case .ok: return
            case .unauthorized(let response):
                if let detail = try? response.body.json.detail, detail == Self.rejectedDetail { throw AccountError.passwordIncorrect }
                throw AccountError.signedOut
            case .unprocessableContent(let response):
                if let code = try? response.body.json.code, code == Self.wrongCurrentCode { throw AccountError.passwordIncorrect }
                throw AccountError.invalidInput
            case .tooManyRequests: throw AccountError.rateLimited
            default: throw AccountError.unavailable
            }
        }
    }

    public func list() async throws -> [PasskeySummary] {
        try await product.perform { client in
            switch try await client.donorPasskeys(.init()) {
            case .ok(let response): return try response.body.json.passkeys.map { PasskeySummary(id: $0.id, name: $0.name) }
            case .unauthorized: throw AccountError.signedOut
            default: throw AccountError.unavailable
            }
        }
    }

    public func delete(id: String) async throws {
        try await product.perform { client in
            switch try await client.deleteDonorPasskey(.init(path: .init(passkey_id: id))) {
            case .ok: return
            case .unauthorized: throw AccountError.signedOut
            case .notFound: throw AccountError.invalidInput
            case .tooManyRequests: throw AccountError.rateLimited
            default: throw AccountError.unavailable
            }
        }
    }
}
