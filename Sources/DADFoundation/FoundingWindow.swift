import Foundation

/// The Founding Donor window closes at the end of Dec 31 2026, New York time. After the deadline the
/// line is hidden entirely.
public enum FoundingWindow {
    private static let calendar: Calendar = {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "America/New_York") ?? .current
        return cal
    }()

    /// Start of Jan 1 2027 America/New_York, the first instant the window is closed.
    public static let closesAt: Date = calendar.date(from: DateComponents(year: 2027, month: 1, day: 1)) ?? .distantFuture

    /// Whole days remaining until the window closes, or nil once it has (hide the line).
    public static func daysRemaining(from now: Date = Date()) -> Int? {
        guard now < closesAt else { return nil }
        return max(calendar.dateComponents([.day], from: now, to: closesAt).day ?? 0, 0)
    }

    /// "Founding Donor: 54 days left", "Founding Donor: last day", or nil after the deadline.
    public static func line(from now: Date = Date()) -> String? {
        guard let days = daysRemaining(from: now) else { return nil }
        if days == 0 { return "Founding Donor: last day" }
        return "Founding Donor: \(days) \(days == 1 ? "day" : "days") left"
    }
}
