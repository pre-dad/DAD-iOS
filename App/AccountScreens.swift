import SwiftUI
import DADFoundation

// Account management sections shown inside Settings (PRD §6.12, EM-2/EM-4/EM-5): contact details,
// the account email, the employer and team, and where the donor is signed in. Each section owns its
// own model, so one that cannot load says so without hiding the others.

private func failureText(_ message: String, id: String) -> some View {
    Text(message).font(.footnote).foregroundStyle(Color.dad("fail")).accessibilityIdentifier(id)
}

/// A manual zone corrects ZIP suggestions at regional boundaries.
struct ProfileDetailsSection: View {
    @State private var model: ProfileDetailsModel

    init(profile: AccountProfileSummary, service: any AccountManagementService) {
        _model = State(initialValue: ProfileDetailsModel(profile: profile, service: service))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Your details").font(.headline).accessibilityAddTraits(.isHeader)
            Text("Your ZIP code suggests your time zone. Correct it below if your local midnight differs.").font(.footnote).foregroundStyle(.secondary)
            TextField("ZIP code", text: $model.zip)
                .textFieldStyle(.roundedBorder).textContentType(.postalCode).keyboardType(.numbersAndPunctuation)
                .accessibilityIdentifier("details-zip")
            if !model.zipValid { failureText("Enter a 5-digit ZIP code, or leave it empty.", id: "details-zip-hint") }
            Picker("Streak time zone", selection: $model.timezoneOverride) {
                ForEach(StreakTimeZone.choices, id: \.value) { choice in
                    Text(choice.label).tag(choice.value)
                }
            }.accessibilityIdentifier("details-timezone")
            if let zone = model.profile.timezone {
                Text("Saved streak time zone: \(zone)").font(.footnote).foregroundStyle(.secondary)
            }
            TextField("City", text: $model.city)
                .textFieldStyle(.roundedBorder).textContentType(.addressCity).textInputAutocapitalization(.words)
                .accessibilityIdentifier("details-city")
            TextField("Mobile phone", text: $model.phone)
                .textFieldStyle(.roundedBorder).textContentType(.telephoneNumber).keyboardType(.phonePad)
                .accessibilityIdentifier("details-phone")
            if !model.phoneValid { failureText("Enter a US number, or include the country code starting with +.", id: "details-phone-hint") }
            switch model.phase {
            case .saved: Text("Your details were saved.").font(.footnote).accessibilityIdentifier("details-saved")
            case .failed(let message): failureText(message, id: "details-error")
            default: EmptyView()
            }
            Button("Save details") { Task { await model.save() } }
                .buttonStyle(DADButtonStyle(.secondary)).disabled(!model.canSave).accessibilityIdentifier("details-save")
        }
        .accessibilityElement(children: .contain).accessibilityIdentifier("details-section")
    }
}

/// Changing the account email: confirmation goes to the current address first, then the new one.
/// Both links open on the website, which completes the change and signs every device out.
struct EmailChangeSection: View {
    @State private var model: EmailChangeModel
    @State private var expanded = false

    init(current: String, service: any AccountManagementService) {
        _model = State(initialValue: EmailChangeModel(current: current, service: service))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if !expanded {
                Button("Change account email") { expanded = true }
                    .buttonStyle(DADButtonStyle(.secondary)).accessibilityIdentifier("email-change-start")
            } else if model.phase == .sent {
                Text("Check your current email address first. After you confirm there, we’ll send a second confirmation to your new address. Each link expires after 15 minutes.")
                    .font(.footnote).accessibilityIdentifier("email-change-sent")
            } else {
                Text("Change account email").font(.headline).accessibilityAddTraits(.isHeader)
                TextField("New email address", text: $model.email)
                    .textFieldStyle(.roundedBorder).textContentType(.emailAddress).keyboardType(.emailAddress)
                    .textInputAutocapitalization(.never).autocorrectionDisabled().accessibilityIdentifier("email-change-input")
                if case .failed(let message) = model.phase { failureText(message, id: "email-change-error") }
                Button("Send confirmation") { Task { await model.submit() } }
                    .buttonStyle(DADButtonStyle(.primary)).disabled(!model.canSubmit).accessibilityIdentifier("email-change-submit")
                Button("Cancel") { model.edit(); expanded = false }.buttonStyle(DADButtonStyle(.secondary)).accessibilityIdentifier("email-change-cancel")
            }
        }
        .accessibilityElement(children: .contain).accessibilityIdentifier("email-change-section")
    }
}

/// Company code (EM-2), then the donor's team and the company team leaderboard (EM-4/EM-5).
struct EmployerSection: View {
    @State private var model: EmployerModel

    init(service: any AccountManagementService) { _model = State(initialValue: EmployerModel(service: service)) }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Employer and team").font(.headline).accessibilityAddTraits(.isHeader)
            switch model.phase {
            case .loading: ProgressView("Loading your employer…")
            case .failed(let message):
                failureText(message, id: "employer-load-error")
                Button("Try again") { Task { await model.load() } }.buttonStyle(DADButtonStyle(.secondary))
            case .ready(let team):
                if let organization = team.organization {
                    linked(organization, team)
                } else {
                    Text("If your employer gave you a company code, link it so your giving counts for your workplace.").font(.footnote)
                    TextField("Company code", text: $model.companyCode)
                        .textFieldStyle(.roundedBorder).textInputAutocapitalization(.characters).autocorrectionDisabled()
                        .accessibilityIdentifier("employer-code")
                    Button("Link my employer") { Task { await model.enroll() } }
                        .buttonStyle(DADButtonStyle(.secondary)).disabled(!model.canEnroll).accessibilityIdentifier("employer-enroll")
                }
            }
            if let error = model.actionError { failureText(error, id: "employer-error") }
        }
        .accessibilityElement(children: .contain).accessibilityIdentifier("employer-section")
        .task { await model.load() }
    }

    @ViewBuilder private func linked(_ organization: String, _ team: EmployerTeam) -> some View {
        Text("Linked to \(organization)").accessibilityIdentifier("employer-linked")
        if let name = team.teamName {
            Text("Your team: \(name)").accessibilityIdentifier("employer-team")
        } else {
            TextField("Team name", text: $model.teamName)
                .textFieldStyle(.roundedBorder).textInputAutocapitalization(.words).accessibilityIdentifier("employer-team-name")
            Button("Join or start a team") { Task { await model.joinTeam() } }
                .buttonStyle(DADButtonStyle(.secondary)).disabled(!model.canJoinTeam).accessibilityIdentifier("employer-join-team")
        }
        Text("Team leaderboard").font(.subheadline.bold())
        if team.leaderboard.isEmpty {
            Text("Teams appear here once they have five members.").font(.footnote).foregroundStyle(.secondary)
        } else {
            let ranksVerified = team.leaderboard.allSatisfy(\.metricsVerified)
            ForEach(Array(team.leaderboard.enumerated()), id: \.element.id) { index, row in
                VStack(alignment: .leading, spacing: 2) {
                    Text(ranksVerified ? "\(index + 1). \(row.name)" : row.name).font(.subheadline.bold())
                    if row.metricsVerified {
                        Text("\(row.activeGivers) givers · \(formatUSDMinor(Int(clamping: row.annualizedMinor))) a year · \(row.avgStreakDays)-day average streak")
                            .font(.caption).foregroundStyle(.secondary)
                    } else {
                        Text("Giving and streak figures are awaiting verification.").font(.caption).foregroundStyle(.secondary)
                    }
                }
                .accessibilityElement(children: .combine).accessibilityIdentifier("leaderboard-\(row.id)")
            }
        }
    }
}

/// Where the donor is signed in: end one other session, every other one, or every session.
struct SessionsSection: View {
    @State private var model: DeviceSessionsModel
    let onSignedOut: () -> Void

    init(service: any AccountManagementService, onSignedOut: @escaping () -> Void) {
        _model = State(initialValue: DeviceSessionsModel(service: service))
        self.onSignedOut = onSignedOut
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Where you’re signed in").font(.headline).accessibilityAddTraits(.isHeader)
            switch model.phase {
            case .loading: ProgressView("Loading where you’re signed in…")
            case .failed(let message):
                failureText(message, id: "sessions-load-error")
                Button("Try again") { Task { await model.load() } }.buttonStyle(DADButtonStyle(.secondary))
            case .ready:
                ForEach(model.sessions) { session in row(session) }
                if model.others.isEmpty {
                    Text("You’re not signed in anywhere else.").font(.footnote).foregroundStyle(.secondary)
                } else {
                    Button("Sign out of every other device") { Task { await model.revokeOthers() } }
                        .buttonStyle(DADButtonStyle(.secondary)).disabled(model.isBusy).accessibilityIdentifier("sessions-revoke-others")
                }
            }
            if let notice = model.notice { Text(notice).font(.footnote).accessibilityIdentifier("sessions-notice") }
            if let error = model.actionError { failureText(error, id: "sessions-error") }
            Button("Sign out on every device") { Task { await model.signOutEverywhere() } }
                .buttonStyle(DADButtonStyle(.secondary)).disabled(model.isBusy).accessibilityIdentifier("sessions-sign-out-everywhere")
        }
        .accessibilityElement(children: .contain).accessibilityIdentifier("sessions-section")
        .task { await model.load() }
        .onChange(of: model.signedOut) { _, signedOut in if signedOut { onSignedOut() } }
    }

    private func row(_ session: DeviceSessionSummary) -> some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(session.current ? "\(session.label) · This device" : session.label).font(.subheadline)
                Text("Last used \(session.lastUsedAt.formatted(date: .abbreviated, time: .shortened))").font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            if !session.current {
                Button("Sign out") { Task { await model.revoke(session.id) } }
                    .buttonStyle(DADButtonStyle(.destructive)).disabled(model.isBusy).accessibilityLabel("Sign out \(session.label)").accessibilityIdentifier("session-revoke-\(session.id)")
            }
        }
    }
}
