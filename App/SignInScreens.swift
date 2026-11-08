import SwiftUI
import UserNotifications
import UIKit
import DADFoundation

/// Asks iOS for notification permission only when the donor chooses to, never at launch; once allowed the app
/// registers for a device token (see `PushAppDelegate`).
struct NotificationPermissionRow: View {
    @State private var status: UNAuthorizationStatus?
    var body: some View {
        Group {
            switch status {
            case .notDetermined:
                Button("Turn on notifications") {
                    Task {
                        let granted = (try? await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge])) ?? false
                        if granted { UIApplication.shared.registerForRemoteNotifications() }
                        status = await UNUserNotificationCenter.current().notificationSettings().authorizationStatus
                    }
                }.buttonStyle(DADButtonStyle(.secondary)).accessibilityIdentifier("notifications-allow")
            case .denied:
                Text("Notifications are off for DAD in iOS Settings.").font(.footnote).accessibilityIdentifier("notifications-denied")
            default:
                EmptyView()
            }
        }
        .task { status = await UNUserNotificationCenter.current().notificationSettings().authorizationStatus }
    }
}

/// Presents the analytics question as a small sheet once, right after first sign-in. Same two options/copy and the same identifiers; dismisses once answered.
struct AnalyticsChoiceSheet: View {
    @Bindable var analytics: AnalyticsController
    let onDone: () -> Void
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            AnalyticsChoice(analytics: analytics)
        }
        .frame(maxWidth: 520, alignment: .leading).padding(28).frame(maxWidth: .infinity, alignment: .topLeading)
        .onChange(of: analytics.choice) { _, choice in if choice != nil { onDone() } }
    }
}

/// The first-launch analytics question, worded as on the website; the answer can be changed in Settings.
struct AnalyticsChoice: View {
    let analytics: AnalyticsController
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Allow first-party usage analytics? DAD uses a temporary journey ID to measure signup, sharing and giving. "
                 + "No names, email addresses or payment details are sent. Observations are kept for 13 months. "
                 + "You can change this choice in Settings.").font(.footnote)
            Button("Allow usage analytics") { analytics.choose(true) }
                .buttonStyle(DADButtonStyle(.secondary)).accessibilityIdentifier("analytics-allow")
            Button("Decline usage analytics") { analytics.choose(false) }
                .buttonStyle(DADButtonStyle(.secondary)).accessibilityIdentifier("analytics-decline")
        }.accessibilityElement(children: .contain).accessibilityIdentifier("analytics-choice")
    }
}
