import CryptoKit
import Foundation
import OpenAPIRuntime

/// The visitor tokens DAD-Main handed back for this install's latest referral and company-code link visits
/// (contract 2.10). They stand in for the browser's `dad_referral` / `dad_company` cookies: the referral token
/// is sent with the first monthly gift, the company token is bound once the donor is signed in.
public struct LinkTokens: Codable, Sendable, Equatable {
    public var referral: String?
    public var company: String?
    public init(referral: String? = nil, company: String? = nil) { self.referral = referral; self.company = company }
}

public protocol LinkTokenStore: Sendable {
    func load() -> LinkTokens
    func save(_ tokens: LinkTokens)
}

/// UserDefaults: a token only steers attribution credit at the next gift and is
/// worth nothing to anyone else, so it is not a Keychain credential.
public struct DefaultsLinkTokenStore: LinkTokenStore {
    private nonisolated(unsafe) let defaults: UserDefaults
    private let key: String
    public init(defaults: UserDefaults = .standard, key: String = "org.dad.link-tokens") {
        self.defaults = defaults
        self.key = key
    }
    public func load() -> LinkTokens {
        defaults.data(forKey: key).flatMap { try? JSONDecoder().decode(LinkTokens.self, from: $0) } ?? LinkTokens()
    }
    public func save(_ tokens: LinkTokens) {
        if tokens == LinkTokens() { defaults.removeObject(forKey: key); return }
        if let data = try? JSONEncoder().encode(tokens) { defaults.set(data, forKey: key) }
    }
    public func clear() { defaults.removeObject(forKey: key) }
}

public struct ReferralCaptureResult: Sendable, Equatable {
    /// The token to keep, or nil when the visit started or kept no referral window (discard any kept one).
    public let token: String?
    public let referrerName: String?
}

public protocol LinkAttributionService: Sendable {
    func captureReferral(code: String, inPerson: Bool, token: String?) async throws -> ReferralCaptureResult
    /// The token to keep, or nil when nothing was captured.
    func captureCompany(code: String, token: String?) async throws -> String?
    /// Whether the token named an unexpired company-code visit, now bound to the signed-in donor.
    func bindCompanyTouch(token: String) async throws -> Bool
}

/// `captureReferral` / `captureCompany` are anonymous (the visit usually precedes sign-in); `bindCompanyTouch`
/// goes through the donor session.
public struct WireLinkAttribution: LinkAttributionService {
    private let product: ProductClient

    public init(origin: URL, session: AccountSession) throws { product = try ProductClient(origin: origin, session: session) }
    init(product: ProductClient) { self.product = product }

    private func anonymous() -> Client {
        Client(serverURL: product.origin, configuration: .init(dateTranscoder: LenientDateTranscoder()),
               transport: product.transport, middlewares: [NativeHeaders(access: { nil })])
    }

    public func captureReferral(code: String, inPerson: Bool, token: String?) async throws -> ReferralCaptureResult {
        let body = Operations.captureReferral.Input.Body.jsonPayload(kind: inPerson ? .IRL : .LINK, token: token)
        switch try await anonymous().captureReferral(path: .init(code: code), body: .json(body)) {
        case .ok(let response):
            let value = try response.body.json
            return ReferralCaptureResult(token: value.captured ? value.token : nil, referrerName: value.public_name)
        case .notFound: return ReferralCaptureResult(token: token, referrerName: nil)
        case .unprocessableContent: throw AccountError.invalidInput
        case .tooManyRequests: throw AccountError.rateLimited
        default: throw AccountError.unavailable
        }
    }

    public func captureCompany(code: String, token: String?) async throws -> String? {
        switch try await anonymous().captureCompany(path: .init(code: code), body: .json(.init(token: token))) {
        case .ok(let response):
            let value = try response.body.json
            return value.captured ? value.token : nil
        case .notFound: return token
        case .unprocessableContent: throw AccountError.invalidInput
        case .tooManyRequests: throw AccountError.rateLimited
        default: throw AccountError.unavailable
        }
    }

    public func bindCompanyTouch(token: String) async throws -> Bool {
        try await product.perform { client in
            switch try await client.bindCompanyTouch(body: .json(.init(token: token))) {
            case .ok(let response): return try response.body.json.bound
            case .unauthorized: throw AccountError.signedOut
            case .unprocessableContent: throw AccountError.invalidInput
            case .tooManyRequests: throw AccountError.rateLimited
            default: throw AccountError.unavailable
            }
        }
    }
}

/// Keeps the tokens a link visit earns and spends them, as the website's cookies would be: the latest valid
/// link wins, a capture that keeps nothing discards the kept token, and a company token is bound once after
/// sign-in. Attribution is best effort, so a failed call leaves the kept tokens as they were.
public final class LinkAttribution: @unchecked Sendable {
    private let service: any LinkAttributionService
    private let store: any LinkTokenStore
    private let captured: @Sendable (String) -> Void
    private let lock = NSLock()

    /// `captured` receives the `attribution_captured` source (`link`, `IRL` or `company`) of each visit kept.
    public init(service: any LinkAttributionService, store: any LinkTokenStore, captured: @escaping @Sendable (String) -> Void = { _ in }) {
        self.service = service; self.store = store; self.captured = captured
    }

    /// Records a referral visit and returns the referrer's public name, if the server named one.
    @discardableResult
    public func captureReferral(code: String, inPerson: Bool) async -> String? {
        guard let result = try? await service.captureReferral(code: code, inPerson: inPerson, token: store.load().referral) else { return nil }
        update { $0.referral = result.token }
        if result.token != nil { captured(inPerson ? "IRL" : "link") }
        return result.referrerName
    }

    public func captureCompany(code: String) async {
        // A thrown error is a transient failure: keep whatever token was stored. A successful call that
        // returns nil means the visit kept no company window, so the stored token must be discarded —
        // mirroring `captureReferral`. `try?` would flatten the `String??` and lose that distinction
        // (binding a non-optional `String`, so a returned-nil would wrongly keep the stale token).
        let token: String?
        do { token = try await service.captureCompany(code: code, token: store.load().company) }
        catch { return }
        update { $0.company = token }
        if token != nil { captured("company") }
    }

    /// Binds a kept company token to the signed-in donor. The token is spent once the server has answered
    /// either way (bound, or naming nothing); a transient failure keeps it for the next sign-in.
    public func bindCompany() async {
        guard let token = store.load().company else { return }
        do { _ = try await service.bindCompanyTouch(token: token) }
        catch AccountError.invalidInput {}
        catch { return }
        update { if $0.company == token { $0.company = nil } }
    }

    public var referralToken: String? { store.load().referral }

    private func update(_ change: (inout LinkTokens) -> Void) {
        lock.withLock {
            var tokens = store.load()
            change(&tokens)
            store.save(tokens)
        }
    }
}

/// A short, stable stand-in for a referral token in an idempotency fingerprint, so a checkout retried with a
/// different referral is a different command (the server refuses a key reused with a different referral).
func referralFingerprint(_ token: String?) -> String {
    guard let token else { return "none" }
    return SHA256.hash(data: Data(token.utf8)).prefix(8).map { String(format: "%02x", $0) }.joined()
}
