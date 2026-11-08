import Foundation
import OpenAPIRuntime

/// Real account & settings service (PRD §6.11, §6.12) over the generated client:
/// `profile`, `savePreferences`, `deleteAccount`, `logout`, all authorized through the session.
///
/// Account deletion (App Store 5.1.1(v)) is: `POST /donor/me/delete` -> on a 200, wipe local state
/// (Keychain credentials via `AccountSession.discardLocal`, plus any caller-supplied local data via
/// `onLocalWipe`) -> the model then leaves the shell. A 409 (monthly gift still renewing or a
/// checkout open) is `AccountError.deletionBlocked` and leaves the session untouched.
public struct WireAccountSettings: AccountSettingsService {
    private let product: ProductClient
    private let onLocalWipe: @Sendable () -> Void

    public init(origin: URL, session: AccountSession, onLocalWipe: @escaping @Sendable () -> Void = {}) throws {
        self.init(product: try ProductClient(origin: origin, session: session), onLocalWipe: onLocalWipe)
    }

    init(product: ProductClient, onLocalWipe: @escaping @Sendable () -> Void = {}) {
        self.product = product; self.onLocalWipe = onLocalWipe
    }

    public func load() async throws -> AccountSettingsSnapshot {
        try await product.perform { client in
            switch try await client.profile(.init()) {
            case .ok(let response): return try Self.snapshot(response.body.json)
            case .unauthorized: throw AccountError.signedOut
            case .tooManyRequests: throw AccountError.rateLimited
            default: throw AccountError.unavailable
            }
        }
    }

    public func savePreferences(_ p: AccountPreferences) async throws -> AccountSettingsSnapshot {
        let body = Self.preferencesBody(p)
        return try await product.perform { client in
            switch try await client.savePreferences(.init(body: .json(body))) {
            case .ok(let response): return try Self.snapshot(response.body.json)
            case .unauthorized: throw AccountError.signedOut
            // Stale `version`: the caller must re-read; surfaced as unavailable so the model shows retry.
            case .conflict: throw AccountError.unavailable
            case .tooManyRequests: throw AccountError.rateLimited
            default: throw AccountError.unavailable
            }
        }
    }

    public func deleteAccount() async throws {
        try await product.perform { client in
            switch try await client.deleteAccount(.init()) {
            case .ok: return
            case .unauthorized: throw AccountError.signedOut
            case .conflict: throw AccountError.deletionBlocked
            case .tooManyRequests: throw AccountError.rateLimited
            default: throw AccountError.unavailable
            }
        }
        // Confirmed deleted server-side: nothing remains to revoke remotely, so wipe locally
        // without a further network call. Wipe the local data even if the keychain clear throws.
        defer { onLocalWipe() }
        try await product.session.discardLocal()
    }

    /// Local credentials are cleared first (`AccountSession.logout`), so a remote-logout failure
    /// afterwards (offline) still leaves the donor signed out on this device; the server session
    /// then simply expires. Only a failure to clear secure storage is reported.
    public func signOut() async throws {
        do { try await product.session.logout() }
        catch {
            if case AccountError.secureStorage = error { throw error }
            if await product.session.isSignedIn { throw error }
        }
    }

    static func preferencesBody(_ p: AccountPreferences) -> Operations.savePreferences.Input.Body.jsonPayload {
        .init(
            version: Int32(clamping: p.version), referral_emails: p.referralEmails, marketing_emails: p.marketingEmails,
            push_referral_converted: p.pushReferralConverted, push_streak_at_risk: p.pushStreakAtRisk,
            push_streak_milestone: p.pushStreakMilestone, push_streak_lapsed: p.pushStreakLapsed,
            push_badge_earned: p.pushBadgeEarned, push_event_nearby: p.pushEventNearby,
            push_event_reminder: p.pushEventReminder, push_event_promoted: p.pushEventPromoted,
            rankings_opted_out: p.rankingsOptedOut, network_visible: p.networkVisible, volunteer: p.volunteer,
            volunteer_interests: p.volunteerInterestsEdited ? p.volunteerInterests : nil,
            push_gift_processed: p.pushGiftProcessed)
    }

    static func snapshot(_ p: Components.Schemas.Profile) throws -> AccountSettingsSnapshot {
        AccountSettingsSnapshot(
            profile: AccountProfileSummary(email: p.email, accountRole: p.account_role.rawValue, zip: p.zip, city: p.city, phone: p.phone),
            preferences: AccountPreferences(
                version: Int(p.version), referralEmails: p.referral_emails, marketingEmails: p.marketing_emails,
                pushReferralConverted: p.push_referral_converted, pushStreakAtRisk: p.push_streak_at_risk,
                pushStreakMilestone: p.push_streak_milestone, pushStreakLapsed: p.push_streak_lapsed,
                pushBadgeEarned: p.push_badge_earned, pushEventNearby: p.push_event_nearby,
                pushEventReminder: p.push_event_reminder, pushEventPromoted: p.push_event_promoted,
                pushGiftProcessed: p.push_gift_processed, rankingsOptedOut: p.rankings_opted_out,
                networkVisible: p.network_visible, volunteer: p.volunteer,
                volunteerInterests: p.volunteer_interests))
    }
}
