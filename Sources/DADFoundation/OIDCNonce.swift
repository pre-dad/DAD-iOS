import CryptoKit
import Foundation
import Security

/// One sign-in attempt's replay-protection value. `raw` goes to the DAD server; `hashed` (lowercase
/// hex SHA-256 of `raw`) is what Sign in with Apple binds into the id_token. Providers that echo the
/// nonce unchanged (Google) use `raw`. A value lives for one attempt and is never logged or stored.
public struct OIDCNonce: Sendable, Equatable {
    public let raw: String
    public init(raw: String) { self.raw = raw }

    public var hashed: String {
        SHA256.hash(data: Data(raw.utf8)).map { String(format: "%02x", $0) }.joined()
    }
}

public protocol NonceGenerator: Sendable {
    func make() -> OIDCNonce
}

/// 32 bytes from the system CSPRNG as unpadded base64url (43 characters).
public struct SecureNonceGenerator: NonceGenerator {
    public init() {}

    public func make() -> OIDCNonce {
        var bytes = [UInt8](repeating: 0, count: 32)
        guard SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) == errSecSuccess else {
            preconditionFailure("the system random number generator is unavailable")
        }
        return OIDCNonce(raw: Data(bytes).base64URLEncoded)
    }
}
