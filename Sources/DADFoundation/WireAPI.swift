import Foundation
import HTTPTypes
import OpenAPIRuntime
import OpenAPIURLSession

private final class NoRedirect: NSObject, URLSessionTaskDelegate, Sendable {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping @Sendable (URLRequest?) -> Void) {
        completionHandler(nil)
    }
}

/// The one URLSession shape every native call uses: ephemeral, no cookies/credential/URL cache,
/// bounded timeouts, and redirects refused so a bearer can never be replayed to another location.
func makeNativeTransport(observed: Bool = true) -> any ClientTransport {
    let configuration = URLSessionConfiguration.ephemeral
    configuration.httpShouldSetCookies = false
    configuration.httpCookieStorage = nil
    configuration.urlCredentialStorage = nil
    configuration.urlCache = nil
    configuration.timeoutIntervalForRequest = 20
    configuration.timeoutIntervalForResource = 30
    let session = URLSession(configuration: configuration, delegate: NoRedirect(), delegateQueue: nil)
    let transport = URLSessionTransport(configuration: .init(session: session))
    return observed ? ObservingTransport(inner: transport, observation: .shared) : transport
}

extension HTTPField.Name {
    // Valid by construction; asserting once here avoids a force-unwrap at every request.
    fileprivate static let dadClient: HTTPField.Name = {
        guard let name = HTTPField.Name("X-DAD-Client") else { preconditionFailure("invalid header name literal") }
        return name
    }()
    fileprivate static let dadPlatform: HTTPField.Name = {
        guard let name = HTTPField.Name("X-DAD-Platform") else { preconditionFailure("invalid header name literal") }
        return name
    }()
    fileprivate static let origin: HTTPField.Name = {
        guard let name = HTTPField.Name("Origin") else { preconditionFailure("invalid header name literal") }
        return name
    }()
}

/// Native request shaping shared by session bootstrap and product calls: native client marker,
/// no cookies, no Origin, a per-request bearer (nil for unauthenticated calls), and a response
/// body bounded to 1 MiB.
struct NativeHeaders: ClientMiddleware {
    let access: @Sendable () async throws -> String?
    let maxBodyBytes: Int
    init(access: @escaping @Sendable () async throws -> String?, maxBodyBytes: Int = 1_048_576) {
        self.access = access; self.maxBodyBytes = maxBodyBytes
    }
    func intercept(_ request: HTTPRequest, body: HTTPBody?, baseURL: URL, operationID: String,
                   next: @Sendable (HTTPRequest, HTTPBody?, URL) async throws -> (HTTPResponse, HTTPBody?)) async throws -> (HTTPResponse, HTTPBody?) {
        var request = request
        request.headerFields[.dadClient] = "native"
        request.headerFields[.dadPlatform] = "IOS"
        request.headerFields[.cookie] = nil
        request.headerFields[.origin] = nil
        request.headerFields[.authorization] = try await access().map { "Bearer \($0)" }
        let (response, responseBody) = try await next(request, body, baseURL)
        var bytes: ArraySlice<UInt8>?
        if let responseBody { bytes = try await ArraySlice<UInt8>(collecting: responseBody, upTo: maxBodyBytes) }
        if response.status == .tooManyRequests, !Self.isJSONObject(response, bytes) {
            // Since contract 2.11 the ingress 429 is documented with a Problem body, but an older edge or a CDN
            // rule still sends it empty or as text. Give it the minimal Problem so it decodes as the documented
            // throttle instead of failing the decode; `Retry-After` is passed through untouched.
            var normalized = response
            normalized.headerFields[.contentType] = "application/json"
            return (normalized, HTTPBody(#"{"detail":"Too many requests"}"#))
        }
        return (response, bytes.map { HTTPBody($0) })
    }

    private static func isJSONObject(_ response: HTTPResponse, _ bytes: ArraySlice<UInt8>?) -> Bool {
        guard let bytes, response.headerFields[.contentType]?.lowercased().contains("json") == true,
              let object = try? JSONSerialization.jsonObject(with: Data(bytes)) as? [String: Any] else { return false }
        return object["detail"] is String
    }
}

public struct WireAPI: AccountAPI {
    private let origin: URL
    private let transport: any ClientTransport

    public init(origin: URL) throws {
        guard origin.isBareHTTPSOrigin else { throw AccountError.invalidConfiguration }
        self.origin = origin
        self.transport = makeNativeTransport()
    }

    init(origin: URL, transport: any ClientTransport) { self.origin = origin; self.transport = transport }
    private func client(_ access: String? = nil) -> Client {
        Client(serverURL: origin, transport: transport, middlewares: [NativeHeaders(access: { access })])
    }
    public func profile(access: String) async throws -> AccountProfile {
        switch try await client(access).profile(.init()) {
        case .ok(let response):
            let value = try response.body.json
            return AccountProfile(email: value.email, publicName: value.public_name)
        case .unauthorized: throw AccountError.signedOut
        default: throw AccountError.unavailable
        }
    }
    public func refresh(token: String) async throws -> Credentials {
        switch try await client().refresh(.init(body: .json(.init(refresh_token: token)))) {
        case .ok(let response): return try nativeCredentials(response.body.json)
        case .unauthorized: throw AccountError.signedOut
        default: throw AccountError.unavailable
        }
    }
    public func claim(token: String) async throws -> Credentials {
        switch try await client().claim(.init(body: .json(.init(token: token, platform: .IOS)))) {
        case .ok(let response):
            guard case .NativeSession(let value) = try response.body.json else { throw AccountError.invalidResponse }
            return try nativeCredentials(value)
        case .unauthorized: throw AccountError.signedOut
        default: throw AccountError.unavailable
        }
    }
    public func logout(access: String) async throws {
        guard case .ok = try await client(access).logout(.init()) else { throw AccountError.unavailable }
    }
}
