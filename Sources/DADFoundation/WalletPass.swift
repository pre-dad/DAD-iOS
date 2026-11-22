import Foundation
import OpenAPIRuntime

// The donor's referral code as an Apple Wallet pass (`walletProviders`, `applePass`). The pass is
// a convenience: when Wallet is not configured or the pass cannot be prepared, the on-screen code
// still works, and the screen says so rather than hiding the failure.

public protocol WalletPassService: Sendable {
    /// Whether this deployment can issue Apple Wallet passes.
    func appleWalletAvailable() async throws -> Bool
    /// The signed `.pkpass` bytes for the donor's referral code.
    func applePass() async throws -> Data
}

@MainActor
@Observable
public final class WalletPassModel {
    public static let failure = "The Wallet pass couldn’t be prepared. Please try again. Your on-screen code still works."
    public static let throttled = "\(AccountError.rateLimited.userMessage) Your on-screen code still works."

    /// nil until checked, or when the check failed.
    public private(set) var available: Bool?
    public private(set) var checkFailed = false
    public private(set) var isPreparing = false
    public private(set) var error: String?
    /// Bytes ready to hand to Wallet; the screen clears them once presented.
    public var pass: Data?
    private let service: any WalletPassService

    public init(service: any WalletPassService) { self.service = service }

    public func check() async {
        checkFailed = false
        do { available = try await service.appleWalletAvailable() }
        catch where error.isCancellation { return }
        catch { available = nil; checkFailed = true }
    }

    public func prepare() async {
        guard available == true, !isPreparing else { return }
        isPreparing = true
        defer { isPreparing = false }
        error = nil
        do { pass = try await service.applePass() }
        catch where error.isCancellation { return }
        catch AccountError.rateLimited { self.error = Self.throttled }
        catch { self.error = Self.failure }
    }

    /// Wallet refused the bytes (not a valid signed pass).
    public func passRejected() {
        pass = nil
        error = Self.failure
    }
}

public struct WireWalletPass: WalletPassService {
    private let product: ProductClient

    public init(origin: URL, session: AccountSession) throws {
        self.init(product: try ProductClient(origin: origin, session: session))
    }

    init(product: ProductClient) { self.product = product }

    public func appleWalletAvailable() async throws -> Bool {
        try await product.perform { client in
            switch try await client.walletProviders(.init()) {
            case .ok(let response): return try response.body.json.apple
            case .unauthorized: throw AccountError.signedOut
            case .tooManyRequests: throw AccountError.rateLimited
            default: throw AccountError.unavailable
            }
        }
    }

    public func applePass() async throws -> Data {
        try await product.perform { client in
            switch try await client.applePass(.init()) {
            case .ok(let response):
                return Data(try await ArraySlice<UInt8>(collecting: response.body.application_vnd_period_apple_period_pkpass, upTo: 1_048_576))
            case .unauthorized: throw AccountError.signedOut
            case .conflict: throw AccountError.conflict
            case .tooManyRequests: throw AccountError.rateLimited
            default: throw AccountError.unavailable
            }
        }
    }
}
