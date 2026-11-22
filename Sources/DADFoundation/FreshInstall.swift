import Foundation

/// iOS keeps an app's Keychain items when the app is deleted, but not its UserDefaults. Without this,
/// deleting DAD would not sign anyone out: reinstalling would restore the old donor and partner sessions.
/// The marker lives in UserDefaults, so its absence means this install has not run before.
public enum FreshInstall {
    public static let markerKey = "org.dad.installed"

    /// Clears `sessions` on an install's first launch, then records that it ran. Before the device is
    /// first unlocked (a prewarmed launch) UserDefaults can read as empty, so nothing is cleared until
    /// `protectedDataAvailable`; a store that fails to clear is retried at the next launch.
    public static func signOutIfNew(sessions: [any CredentialStore], defaults: UserDefaults = .standard,
                                    protectedDataAvailable: Bool) {
        guard protectedDataAvailable, !defaults.bool(forKey: markerKey) else { return }
        var cleared = true
        for store in sessions {
            do { try store.clear() } catch { cleared = false }
        }
        if cleared { defaults.set(true, forKey: markerKey) }
    }
}
