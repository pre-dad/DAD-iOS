import Foundation
import OpenAPIRuntime

extension AccountError {
    /// The one HTTP-status mapping the `Wire<X>` conformers share for a response the generated client
    /// has no case for: 401 signed out, 403 forbidden, 404 not found, 409 conflict, 422 invalid input,
    /// 429 rate limited, anything else unavailable.
    static func forStatus(_ status: Int) -> AccountError {
        switch status {
        case 401: return .signedOut
        case 403: return .forbidden
        case 404: return .notFound
        case 409: return .conflict
        case 422: return .invalidInput
        case 429: return .rateLimited
        default: return .unavailable
        }
    }
}

extension ProductClient {
    /// `perform` plus `mappingUndecodableStatus`, for responses the generated client cannot decode.
    func call<T: Sendable>(_ operation: @Sendable (Client) async throws -> T) async throws -> T {
        try await perform { client in try await mappingUndecodableStatus { try await operation(client) } }
    }
}
