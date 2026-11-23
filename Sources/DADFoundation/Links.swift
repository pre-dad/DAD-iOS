import Foundation

public enum AccountDestination: String, Sendable, Equatable {
    case dashboard = "/account/dashboard"
    case gifts = "/account/gifts"
    case profile = "/account/profile"
    case paymentMethod = "/account/payment-method"
}

public enum LinkIntent: Sendable, Equatable, CustomStringConvertible, CustomDebugStringConvertible {
    case account(AccountDestination)
    case claim(token: String, next: AccountDestination?)
    case emailChange(token: String)
    /// An emailed partner sign-in link (`/partner/accept#token=`).
    case partnerSignIn(token: String)
    /// A donor's invite link (`/r/{code}`, `?via=irl` when shared in person).
    case referral(code: String, inPerson: Bool)
    /// An employer's company-code link (`/c/{code}`).
    case company(code: String)
    case web(URL)
    public var description: String {
        switch self {
        case .account(let destination): "Account(\(destination.rawValue))"
        case .claim: "Claim([redacted])"
        case .emailChange: "EmailChange([redacted])"
        case .partnerSignIn: "PartnerSignIn([redacted])"
        case .referral(let code, let inPerson): "Referral(\(code), inPerson: \(inPerson))"
        case .company(let code): "Company(\(code))"
        case .web: "WebLink([redacted])"
        }
    }
    public var debugDescription: String { description }
}

private struct LinkPolicy: Decodable, Sendable {
    let accountPaths: [String]
    let proofPaths: [String]
    let partnerProofPaths: [String]
    let claimReturnPaths: [String]
    let notificationPaths: [String]
    let referralPrefix: String
    let companyPrefix: String
}

extension URL {
    /// An HTTPS origin with no credentials, path, query, or fragment.
    var isBareHTTPSOrigin: Bool {
        scheme == "https" && host != nil && user == nil && password == nil && query == nil && fragment == nil
            && (path.isEmpty || path == "/")
    }
}

public struct LinkRouter: Sendable {
    private let origin: URL
    private let policy: LinkPolicy
    public init(publicOrigin: URL) throws {
        guard publicOrigin.isBareHTTPSOrigin,
              let file = Bundle.module.url(forResource: "links", withExtension: "json") else { throw AccountError.invalidConfiguration }
        origin = publicOrigin
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        policy = try decoder.decode(LinkPolicy.self, from: Data(contentsOf: file))
    }
    public func route(_ url: URL) -> LinkIntent? {
        guard url.absoluteString.count <= 4096, url.scheme == origin.scheme, url.host?.lowercased() == origin.host?.lowercased(), (url.port ?? 443) == (origin.port ?? 443),
              url.user == nil, url.password == nil,
              let parts = URLComponents(url: url, resolvingAgainstBaseURL: false),
              !parts.percentEncodedPath.lowercased().contains("%2f"),
              !parts.percentEncodedPath.lowercased().contains("%5c") else { return nil }
        if policy.partnerProofPaths.contains(url.path) {
            guard url.query == nil, let token = Self.singleToken(parts.fragment, allowNext: false) else { return nil }
            return .partnerSignIn(token: token)
        }
        if policy.proofPaths.contains(url.path) {
            guard url.query == nil, let token = Self.singleToken(parts.fragment, allowNext: url.path == "/account/claim") else { return nil }
            if url.path == "/account/email-change" { return .emailChange(token: token) }
            let next = parts.fragment.flatMap { URLComponents(string: "?" + $0)?.queryItems }?.first(where: { $0.name == "next" })?.value
            if let next, !policy.claimReturnPaths.contains(next) { return nil }
            return .claim(token: token, next: next.flatMap(AccountDestination.init(rawValue:)))
        }
        if policy.accountPaths.contains(url.path), url.query == nil, url.fragment == nil,
           let destination = AccountDestination(rawValue: url.path) { return .account(destination) }
        if url.fragment == nil, let code = Self.code(url.path, after: policy.referralPrefix) {
            switch url.query {
            case nil: return .referral(code: code, inPerson: false)
            case "via=irl": return .referral(code: code, inPerson: true)
            default: return .web(url)
            }
        }
        if url.query == nil, url.fragment == nil, let code = Self.code(url.path, after: policy.companyPrefix) { return .company(code: code) }
        return .web(url)
    }

    public func invitation(_ text: String) -> LinkIntent? {
        guard let url = URL(string: text.trimmingCharacters(in: .whitespacesAndNewlines)),
              let intent = route(url) else { return nil }
        switch intent {
        case .referral, .company: return intent
        default: return nil
        }
    }
    /// The one path segment after `prefix`, if it has the shape every referral and company code has.
    private static func code(_ path: String, after prefix: String) -> String? {
        guard path.hasPrefix(prefix) else { return nil }
        let code = String(path.dropFirst(prefix.count))
        return code.wholeMatch(of: /[A-Za-z0-9_-]{1,64}/) == nil ? nil : code
    }
    /// The fragment's one well-formed `token` (and, on a claim link, at most one `next`), or nil.
    private static func singleToken(_ fragment: String?, allowNext: Bool) -> String? {
        guard let fragment, let values = URLComponents(string: "?" + fragment)?.queryItems,
              values.filter({ $0.name == "token" }).count == 1,
              let token = values.first(where: { $0.name == "token" })?.value,
              (32...128).contains(token.count), token.range(of: "^[A-Za-z0-9_-]+$", options: .regularExpression) != nil,
              values.allSatisfy({ $0.name == "token" || (allowNext && $0.name == "next") }),
              values.filter({ $0.name == "next" }).count <= 1 else { return nil }
        return token
    }

    public func notification(path: String) -> AccountDestination? {
        guard policy.notificationPaths.contains(path) else { return nil }
        return AccountDestination(rawValue: path)
    }
}

public struct NavigationGate: Sendable {
    public private(set) var pending: AccountDestination?
    public init() {}
    public mutating func receive(_ destination: AccountDestination, signedIn: Bool) -> AccountDestination? {
        if signedIn { return destination }
        pending = destination
        return nil
    }
    public mutating func signedIn() -> AccountDestination? {
        defer { pending = nil }
        return pending
    }
    public mutating func signedOut() { pending = nil }
}
