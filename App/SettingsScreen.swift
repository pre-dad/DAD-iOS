import SwiftUI
import DADFoundation

// Account & settings screen, kept out of DADApp.swift, which is hand-structured. The sub-sections it composes
// (ProfileDetailsSection, EmailChangeSection, EmployerSection, SessionsSection,
// NotificationPermissionRow) live in App/AccountScreens.swift / App/SignInScreens.swift.

/// Account & settings (PRD §6.11/§6.12): profile header, notification + privacy toggles, sign
/// out, and the store-mandated delete-account flow with a typed-word confirm gate — all inline.
/// Bound to `AccountSettingsModel`.
struct AccountSettingsScreen: View {
    @State var model: AccountSettingsModel
    /// Set/change password; nil where there is no real account to change (previews).
    var passwords: (any PasswordSettingsService)?
    var management: (any AccountManagementService)?
    /// The real cancel-gift flow, offered when the server refuses deletion because a gift is still renewing.
    var giving: GivingKit?
    var onSignedOut: (() -> Void)?
    @State private var giftModel: GivingModel?
    @Environment(AnalyticsController.self) private var analytics: AnalyticsController?
    @State private var confirmingDelete = false
    @State private var deleteTyped = ""
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Settings").font(.largeTitle.bold()).accessibilityAddTraits(.isHeader)
            if model.signedOut {
                Text("You’re signed out.").accessibilityIdentifier("settings-signed-out")
            } else {
                switch model.phase {
                case .loading:
                    ProgressView().accessibilityIdentifier("settings-loading")
                case .failed(let message):
                    VStack(alignment: .leading, spacing: 8) {
                        Text(message).accessibilityIdentifier("settings-error")
                        Button("Try again") { Task { await model.load() } }.buttonStyle(DADButtonStyle(.primary))
                    }
                case .ready:
                    if let snapshot = model.snapshot {
                        settingsBody(snapshot)
                    }
                }
            }
            if let error = model.actionError {
                Text(error).foregroundStyle(Color.dad("fail")).accessibilityIdentifier("settings-action-error")
            }
        }
        .frame(maxWidth: 520, alignment: .leading).padding(28).frame(maxWidth: .infinity)
        .accessibilityElement(children: .contain).accessibilityIdentifier("settings-screen")
        .task { await model.load() }
        .onChange(of: model.signedOut) { _, signedOut in if signedOut { onSignedOut?() } }
        .sheet(isPresented: Binding(get: { giftModel != nil }, set: { if !$0 { giftModel = nil } })) {
            if let giftModel, let giving {
                GiftSheet(model: giftModel, stubComplete: giving.stubComplete, onClose: { self.giftModel = nil },
                          onSignedOut: { self.giftModel = nil; onSignedOut?() })
            }
        }
    }

    /// A labelled settings group (insetGrouped look) hosting its rows; the sheet presents this screen
    /// inside a ScrollView, so grouped cards are used rather than a Form (a nested Form collapses).
    @ViewBuilder private func section(_ title: String, @ViewBuilder _ rows: () -> some View) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title).font(.footnote.weight(.semibold)).textCase(.uppercase).foregroundStyle(.secondary)
                .accessibilityAddTraits(.isHeader)
            DADCard { VStack(alignment: .leading, spacing: 12) { rows() } }
        }
    }

    @ViewBuilder private func settingsBody(_ snapshot: AccountSettingsSnapshot) -> some View {
        // Profile
        section("Profile") {
            Text(snapshot.profile.email).font(.headline).accessibilityIdentifier("settings-email")
            if let management {
                EmailChangeSection(current: snapshot.profile.email, service: management)
                ProfileDetailsSection(profile: snapshot.profile, service: management)
            } else {
                Text("ZIP: \(snapshot.profile.zipLabel)").font(.footnote)
            }
        }

        // Notifications (§6.11) — payment-failure email is absent by design.
        section("Notifications") {
            NotificationPermissionRow()
            ForEach(snapshot.preferences.pushToggles, id: \.key) { toggle in
                Toggle(toggle.label, isOn: Binding(
                    get: { toggle.value },
                    set: { newValue in Task { await model.toggle(toggle.key, newValue) } }
                )).disabled(model.isBusy).accessibilityIdentifier("pref-\(toggle.key)")
            }
            ForEach(snapshot.preferences.emailToggles, id: \.key) { toggle in
                Toggle(toggle.label, isOn: Binding(
                    get: { toggle.value },
                    set: { newValue in Task { await model.toggle(toggle.key, newValue) } }
                )).disabled(model.isBusy).accessibilityIdentifier("pref-\(toggle.key)")
            }
        }

        // Privacy: "Show my ranking" inverts rankings_opted_out.
        section("Privacy") {
            Toggle("Show my ranking", isOn: Binding(
                get: { snapshot.preferences.showRanking },
                set: { newValue in Task { await model.toggle("rankings_opted_out", !newValue) } }
            )).disabled(model.isBusy).accessibilityIdentifier("ranking-toggle")
            Toggle("Show me in my network", isOn: Binding(
                get: { snapshot.preferences.networkVisible },
                set: { newValue in Task { await model.toggle("network_visible", newValue) } }
            )).disabled(model.isBusy).accessibilityIdentifier("pref-network_visible")
            Toggle("I’d like to volunteer", isOn: Binding(
                get: { snapshot.preferences.volunteer },
                set: { newValue in Task { await model.toggle("volunteer", newValue) } }
            )).disabled(model.isBusy).accessibilityIdentifier("pref-volunteer")
            if let analytics {
                Toggle("Usage analytics", isOn: Binding(get: { analytics.choice == true }, set: { analytics.choose($0) }))
                    .accessibilityIdentifier("analytics-toggle")
                Text("First-party only: a temporary journey ID measures signup, sharing and giving. No names, email addresses "
                     + "or payment details are sent.").font(.footnote).foregroundStyle(.secondary)
            }
        }

        // Security
        section("Security") {
            if let passwords {
                PasswordSection(service: passwords, onSignedOut: { onSignedOut?() })
            }
            if let management {
                EmployerSection(service: management)
                SessionsSection(service: management, onSignedOut: { onSignedOut?() })
            }
        }

        // Account: the single quiet preview footnote lives here (not per card).
        section("Account") {
            Text("Preview build · test payments only").font(.footnote).foregroundStyle(.secondary)
                .accessibilityIdentifier("settings-preview-note")
        }

        // Sign out + Delete account in a separate bottom section.
        bottomSection
    }

    @ViewBuilder private var bottomSection: some View {
        Button("Sign out") { Task { await model.signOut() } }
            .buttonStyle(DADButtonStyle(.secondary)).disabled(model.isBusy).accessibilityIdentifier("settings-signout")

        // Delete account (store-mandated, §6.12): typed-word confirm gate, inline.
        if !confirmingDelete {
            Button("Delete my account") { confirmingDelete = true }
                .buttonStyle(DADButtonStyle(.destructive)).accessibilityIdentifier("delete-start")
        } else {
            VStack(alignment: .leading, spacing: 8) {
                Text(DeleteAccountGate(typed: deleteTyped).helpText).font(.footnote)
                TextField("Type \(DeleteAccountGate.confirmWord)", text: $deleteTyped)
                    .textFieldStyle(.roundedBorder).textInputAutocapitalization(.characters).autocorrectionDisabled()
                    .accessibilityIdentifier("delete-input")
                Button("Permanently delete") { Task { await model.deleteAccount(DeleteAccountGate(typed: deleteTyped)) } }
                    .buttonStyle(DADButtonStyle(.primary))
                    .disabled(!DeleteAccountGate(typed: deleteTyped).isConfirmed || model.isBusy)
                    .accessibilityIdentifier("delete-confirm")
                Button("Keep my account") { confirmingDelete = false; deleteTyped = "" }
                    .buttonStyle(DADButtonStyle(.secondary))
                if model.deletionBlocked, let giving {
                    // The server refused because a monthly gift is still set to renew (or a checkout is open):
                    // offer the real cancel flow rather than a dead end, then the donor tries deleting again.
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Cancel your monthly gift, then delete your account again.").font(.footnote)
                        Button("Cancel my monthly gift") { giftModel = giving.makeModel() }
                            .buttonStyle(DADButtonStyle(.secondary)).accessibilityIdentifier("delete-cancel-gift")
                    }.accessibilityElement(children: .contain).accessibilityIdentifier("delete-blocked-block")
                }
            }.accessibilityElement(children: .contain).accessibilityIdentifier("delete-confirm-block")
        }
    }
}
/// Set or change the sign-in password, inline in Settings. Collapsed until asked for. The current
/// password is optional: right after a fresh sign-in the server accepts the recent authentication.
private struct PasswordSection: View {
    @State private var model: PasswordChangeModel
    @State private var expanded = false
    let onSignedOut: () -> Void

    init(service: any PasswordSettingsService, onSignedOut: @escaping () -> Void) {
        _model = State(initialValue: PasswordChangeModel(service: service))
        self.onSignedOut = onSignedOut
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if !expanded {
                Button("Set or change password") { expanded = true }
                    .buttonStyle(DADButtonStyle(.secondary)).accessibilityIdentifier("password-start")
            } else {
                Text("Password").font(.headline)
                SecureField("Current password (if you have one)", text: $model.currentPassword)
                    .textFieldStyle(.roundedBorder).textContentType(.password).accessibilityIdentifier("password-current")
                SecureField("New password", text: $model.newPassword)
                    .textFieldStyle(.roundedBorder).textContentType(.newPassword).accessibilityIdentifier("password-new")
                SecureField("Confirm new password", text: $model.confirmPassword)
                    .textFieldStyle(.roundedBorder).textContentType(.newPassword).accessibilityIdentifier("password-confirm")
                Text(model.newPasswordHint ?? "Use 12 to 72 characters.").font(.footnote).foregroundStyle(.secondary)
                if model.confirmMismatch {
                    Text("The two passwords don’t match.").font(.footnote).foregroundStyle(Color.dad("fail"))
                }
                switch model.phase {
                case .failed(let message):
                    Text(message).font(.footnote).foregroundStyle(Color.dad("fail")).accessibilityIdentifier("password-error")
                case .saved:
                    Text("Password saved.").font(.footnote).accessibilityIdentifier("password-saved")
                default: EmptyView()
                }
                Button("Save password") { Task { await model.save() } }
                    .buttonStyle(DADButtonStyle(.primary)).disabled(!model.canSave).accessibilityIdentifier("password-save")
                Button("Cancel") { model.edit(); expanded = false }.buttonStyle(DADButtonStyle(.secondary))
            }
        }
        .accessibilityElement(children: .contain).accessibilityIdentifier("password-section")
        .onChange(of: model.signedOut) { _, signedOut in if signedOut { onSignedOut() } }
    }
}
