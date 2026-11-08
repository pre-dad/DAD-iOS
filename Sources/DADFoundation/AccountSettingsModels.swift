import Foundation

// Settings view model + service seam. The model owns load/ready/failed state, toggle-and-save
// (optimistic version bump), and the delete-account flow (confirm gate -> server delete -> local
// wipe), so it is unit-tested without a network or UI — the iOS counterpart of Android Phase 7.

public struct AccountSettingsSnapshot: Sendable, Equatable {
    public let profile: AccountProfileSummary
    public let preferences: AccountPreferences
    public init(profile: AccountProfileSummary, preferences: AccountPreferences) {
        self.profile = profile
        self.preferences = preferences
    }
}

public protocol AccountSettingsService: Sendable {
    func load() async throws -> AccountSettingsSnapshot
    /// Save the preference block; returns the new snapshot (bumped version).
    func savePreferences(_ preferences: AccountPreferences) async throws -> AccountSettingsSnapshot
    /// Delete the account server-side (personal data removed, gift records kept).
    func deleteAccount() async throws
    /// Clear the local session (sign out / post-delete wipe).
    func signOut() async throws
}

@MainActor
@Observable
public final class AccountSettingsModel {
    public enum Phase: Sendable, Equatable {
        case loading
        case ready
        case failed(String)
    }

    public private(set) var phase: Phase = .loading
    public private(set) var snapshot: AccountSettingsSnapshot?
    /// True once deleted or signed out — the UI leaves the settings shell.
    public private(set) var signedOut = false
    public private(set) var actionError: String?
    /// Why the last interest entry was rejected, shown beside the field.
    public private(set) var interestError: String?
    /// The server refused deletion (409) because a monthly gift is still set to renew or a checkout is
    /// open. The screen then offers the real cancel-gift flow instead of a dead end; a retry after the
    /// gift is cancelled clears it.
    public private(set) var deletionBlocked = false
    /// A save or delete is in flight; the UI disables its controls so requests cannot overlap.
    public private(set) var isBusy = false

    private let service: any AccountSettingsService

    public init(service: any AccountSettingsService) { self.service = service }

    public func load() async {
        phase = .loading
        do {
            snapshot = try await service.load()
            phase = .ready
        } catch {
            phase = .failed(error.userMessage)
        }
    }

    /// Flip one preference toggle and persist; the snapshot is replaced in place on success.
    /// Saves are serialized: each one carries the optimistic `version` it read, so a second save
    /// started before the first returns would be rejected as stale.
    public func toggle(_ key: String, _ value: Bool) async {
        guard let current = snapshot, !isBusy else { return }
        isBusy = true
        defer { isBusy = false }
        actionError = nil
        do {
            snapshot = try await service.savePreferences(current.preferences.with(key, value))
        } catch {
            actionError = error.userMessage
        }
    }

    /// Add one free-form volunteer interest and persist. A rejected entry sets `interestError` and
    /// saves nothing; returns whether the interest was saved so the field can clear.
    @discardableResult
    public func addInterest(_ text: String) async -> Bool {
        guard let current = snapshot, !isBusy else { return false }
        switch current.preferences.addingInterest(text) {
        case .failure(let reason):
            interestError = reason.message
            return false
        case .success(let updated):
            interestError = nil
            return await save(updated)
        }
    }

    public func removeInterest(_ interest: String) async {
        guard let current = snapshot, !isBusy else { return }
        interestError = nil
        await save(current.preferences.removingInterest(interest))
    }

    @discardableResult
    private func save(_ preferences: AccountPreferences) async -> Bool {
        isBusy = true
        defer { isBusy = false }
        actionError = nil
        do {
            snapshot = try await service.savePreferences(preferences)
            return true
        } catch {
            actionError = error.userMessage
            return false
        }
    }

    /// Delete only when the confirm gate is satisfied, then wipe the local session.
    public func deleteAccount(_ gate: DeleteAccountGate) async {
        guard gate.isConfirmed else {
            actionError = "Type \(DeleteAccountGate.confirmWord) to confirm."
            return
        }
        guard !isBusy else { return }
        isBusy = true
        defer { isBusy = false }
        actionError = nil
        deletionBlocked = false
        do {
            try await service.deleteAccount()
        } catch {
            if case AccountError.deletionBlocked = error { deletionBlocked = true }
            actionError = error.userMessage
            return
        }
        // The account is gone server-side, so the donor must leave the shell even if the remote
        // logout then fails (the deleted account's token is typically already rejected): the
        // service clears local credentials before it contacts the server.
        try? await service.signOut()
        signedOut = true
    }

    public func signOut() async {
        guard !isBusy else { return }
        isBusy = true
        defer { isBusy = false }
        do {
            try await service.signOut()
            signedOut = true
        } catch {
            actionError = error.userMessage
        }
    }
}
