import Foundation

public enum AccountError: Error, Sendable, Equatable {
    case signedOut
    case unavailable
    case invalidConfiguration
    case invalidResponse
    case secureStorage(Int32)
    /// 429: the server is throttling this caller; retry later.
    case rateLimited
    /// 422: the server rejected the value as malformed (e.g. a phone number).
    case invalidInput
    /// 409 on account deletion: a monthly gift is still set to renew or a checkout is open.
    case deletionBlocked
    /// 401 on set-password whose body says the credential was wrong: NOT an expired session, so it
    /// must never trigger the refresh-retry or end the local session.
    case passwordIncorrect
    /// 403 on a giving command: giving is not available for this account.
    case forbidden
    /// 409 on a giving command: billing changed since the screen last read it; refresh, then retry.
    case conflict
    /// 503 carrying a `code`: this deployment has deliberately not configured payments. Not transient.
    case paymentsUnavailable
    /// 404 on an event command or read: the event is gone, hidden from this donor, or the id is not one.
    case notFound
}

public struct Credentials: Codable, Sendable, Equatable, CustomStringConvertible, CustomDebugStringConvertible {
    public let access: String
    public let refresh: String
    public let expiresAt: Date
    public var description: String { "Credentials([redacted])" }
    public var debugDescription: String { description }
    public init(access: String, refresh: String, expiresAt: Date) {
        self.access = access; self.refresh = refresh; self.expiresAt = expiresAt
    }
}

public struct AccountProfile: Sendable, Equatable {
    public let email: String
    public let publicName: String?
    public init(email: String, publicName: String?) { self.email = email; self.publicName = publicName }
}

public protocol AccountAPI: Sendable {
    func profile(access: String) async throws -> AccountProfile
    func refresh(token: String) async throws -> Credentials
    func claim(token: String) async throws -> Credentials
    func logout(access: String) async throws
}

public protocol CredentialStore: Sendable {
    func load() throws -> Credentials?
    func save(_ credentials: Credentials) throws
    func clear() throws
}

public actor AccountSession {
    private let api: any AccountAPI
    private let store: any CredentialStore
    private var credentials: Credentials?
    private var epoch = 0
    private var flight: (id: UUID, task: Task<Credentials, Error>)?
    /// Whether stored credentials existed when the session was created. Immutable so the UI can
    /// decide synchronously between "restoring a session" and "show sign-in" at launch.
    public nonisolated let restoredCredentials: Bool

    public init(api: any AccountAPI, store: any CredentialStore) throws {
        self.api = api; self.store = store
        let stored: Credentials?
        do { stored = try store.load() }
        catch is DecodingError {
            try store.clear()
            stored = nil
        }
        self.credentials = stored
        self.restoredCredentials = stored != nil
    }

    /// True while this session holds credentials (it may still be rejected by the server later).
    public var isSignedIn: Bool { credentials != nil }

    public func claim(token: String) async throws {
        try await install { try await self.api.claim(token: token) }
    }

    /// Install credentials produced by a completed sign-in (phone/passkey/OIDC/password).
    /// The credential-producing work runs INSIDE the actor so the epoch captured before it
    /// guards the install: a sign-in that resolves after a sign-out does not clobber state,
    /// exactly like `claim`.
    @discardableResult
    public func establish(_ produce: @Sendable () async throws -> Credentials) async throws -> Credentials {
        try await install(produce)
    }

    @discardableResult
    private func install(_ produce: @Sendable () async throws -> Credentials) async throws -> Credentials {
        let before = epoch
        let result = try await produce()
        guard before == epoch else { throw AccountError.signedOut }
        // A caller that gave up (view left, task replaced) must not have a session installed behind it.
        try Task.checkCancellation()
        try store.save(result)
        credentials = result
        epoch += 1
        flight = nil
        return result
    }

    /// A currently-valid access token, refreshing through the single-flight path if needed.
    /// Product clients call this per request to authorize a native call; throws `.signedOut`
    /// when there is no usable session.
    public func accessToken() async throws -> String {
        try Task.checkCancellation()
        return try await usableCredentials().access
    }

    public func profile() async throws -> AccountProfile {
        let api = self.api
        return try await authorized { try await api.profile(access: $0) }
    }

    /// Run one authenticated call with a currently-valid access token. The shared recipe for every
    /// product call: refresh through the single-flight path if expired; on a 401 (the call throws
    /// `AccountError.signedOut`) force exactly one refresh and retry once; a second 401 ends the
    /// session locally. A sign-out/switch while the call is in flight (epoch change) or caller
    /// cancellation discards the result rather than returning it. Only use for requests that the
    /// server has not processed when it answers 401 (all of them: 401 is rejected before handling).
    public func authorized<T: Sendable>(_ call: @Sendable (String) async throws -> T) async throws -> T {
        try Task.checkCancellation()
        let before = epoch
        let current = try await usableCredentials()
        do { return try await checked(call, current, epoch: before) }
        catch AccountError.signedOut {
            guard before == epoch else { throw AccountError.signedOut }
            let next = try await usableCredentials(forceFor: current.access)
            do { return try await checked(call, next, epoch: before) }
            catch AccountError.signedOut {
                if before == epoch { try clearLocal() }
                throw AccountError.signedOut
            }
        }
    }

    private func checked<T: Sendable>(_ call: @Sendable (String) async throws -> T, _ value: Credentials, epoch before: Int) async throws -> T {
        let result = try await call(value.access)
        guard before == epoch else { throw AccountError.signedOut }
        try Task.checkCancellation()
        return result
    }

    /// Drop local credentials without contacting the server (after a confirmed server-side
    /// account deletion, where the remote session no longer exists). Bumps the epoch so any
    /// in-flight call or sign-in started before it is discarded.
    public func discardLocal() throws { try clearLocal() }

    private func usableCredentials(forceFor access: String? = nil) async throws -> Credentials {
        guard let current = credentials else { throw AccountError.signedOut }
        if flight == nil, current.expiresAt.timeIntervalSinceNow > 30, access != current.access { return current }
        let before = epoch
        let pending: (id: UUID, task: Task<Credentials, Error>)
        if let active = flight { pending = active }
        else {
            let api = self.api
            pending = (UUID(), Task { try await api.refresh(token: current.refresh) })
            flight = pending
        }
        do {
            let refreshed = try await pending.task.value
            guard before == epoch else { throw AccountError.signedOut }
            if flight?.id == pending.id {
                do { try store.save(refreshed) }
                catch { try clearLocal(); throw error }
                credentials = refreshed
                flight = nil
            }
            guard let latest = credentials else { throw AccountError.signedOut }
            try Task.checkCancellation()
            return latest
        } catch {
            if before == epoch, flight?.id == pending.id {
                flight = nil
                if error as? AccountError == .signedOut { try clearLocal() }
            }
            throw error
        }
    }

    private func clearLocal() throws {
        epoch += 1
        credentials = nil
        flight = nil
        try store.clear()
    }

    // Keep a refresh already in progress so remote logout can use its new access token.
    public func logout() async throws {
        let old = credentials
        let pending = flight?.task
        try clearLocal()
        var access = old?.access
        if let pending {
            do { access = try await pending.value.access }
            catch { if access == nil { throw error } }
        }
        if let access { try await api.logout(access: access) }
    }
}
