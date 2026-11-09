import Foundation

/// Account deletion must also erase attribution saved by older app versions.
public enum LegacyAttribution {
    public static func clear(defaults: UserDefaults = .standard) {
        defaults.removeObject(forKey: "org.dad.attribution")
    }
}
