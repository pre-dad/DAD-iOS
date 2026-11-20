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

/// Runs one call and maps a 4xx/5xx the generated client could not decode (the ingress limiter's 429
/// has no Problem body) by its status, exactly as a documented response would be. Cancellation is never remapped.
func mappingUndecodableStatus<T: Sendable>(_ work: () async throws -> T) async throws -> T {
    do { return try await work() }
    catch let error as ClientError {
        if let status = error.response?.status.code, status >= 400, !error.underlyingError.isCancellation {
            throw AccountError.forStatus(status)
        }
        throw error
    }
}

/// An optional secondary read: any failure but cancellation yields nil, so the caller keeps what it already has.
func optionalRead<T: Sendable>(_ read: () async throws -> T) async throws -> T? {
    do { return try await read() }
    catch where error.isCancellation { throw error }
    catch { return nil }
}
