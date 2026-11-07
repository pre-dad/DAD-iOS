import PhotosUI
import SwiftUI
import DADFoundation

// Partner sign-in and portal (PRD P-*, EM-*, §7). Approved partner users sign in with an emailed link; the
// portal shows verified-or-hidden figures (§7.3), the workforce rollup with <5 suppression (EM-3), and the
// organization tools gated to admins (§7.2): profile, logo, users, company code and report exports.

private func failureText(_ message: String, id: String) -> some View {
    Text(message).font(.footnote).foregroundStyle(Color.dad("fail")).accessibilityIdentifier(id)
}

/// Email → "check your email" → the tapped (or pasted) link signs the partner in.
struct PartnerSignInFlow: View {
    @State var model: PartnerSignInModel
    /// A tapped partner link's token, accepted as soon as it arrives.
    let incomingToken: String?
    let onTokenConsumed: () -> Void
    let onBack: () -> Void
    let onSignedIn: () -> Void
    /// The website's partner application (`<public origin>/apply`); nil when no public origin is configured.
    var applyURL: URL?
    /// Where this install's partner application stands, when it holds a receipt for one; nil hides the card.
    var applicationStatus: (any ApplicationStatusService)?
    /// Submits a partner application from the app; nil falls back to the website's form.
    var applicationSubmit: (any PartnerApplicationService)?
    @State private var pasted = ""
    @State private var sentTo: String?
    @State private var applying = false
    @State private var holdsApplication = false
    @State private var statusReload = 0

    var body: some View {
        ScrollView { signInContent }
    }

    private var signInContent: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Partner sign-in").font(.largeTitle.bold()).accessibilityAddTraits(.isHeader)
            switch model.phase {
            case .sent(let email):
                checkEmail(email, error: nil)
            case .failed(let message) where sentTo != nil:
                checkEmail(sentTo ?? "", error: message)
            case .accepting where sentTo != nil:
                checkEmail(sentTo ?? "", error: nil)
            case .accepting, .signedIn:
                ProgressView("Signing you in…").accessibilityIdentifier("partner-signing-in")
            default:
                if applying, let applicationSubmit {
                    PartnerApplicationForm(model: PartnerApplicationModel(service: applicationSubmit),
                                           onCancel: { applying = false },
                                           onSubmitted: { applying = false; statusReload += 1 })
                } else {
                    signInFields
                }
            }
            Button("Back", action: onBack).buttonStyle(DADButtonStyle(.secondary)).accessibilityIdentifier("partner-sign-in-back")
        }
        .frame(maxWidth: 520, alignment: .leading).padding(28).frame(maxWidth: .infinity)
        .accessibilityElement(children: .contain).accessibilityIdentifier("partner-sign-in")
        .task(id: incomingToken) {
            guard let token = incomingToken else { return }
            onTokenConsumed()
            await model.accept(token: token)
        }
        .onChange(of: model.phase) { _, phase in
            switch phase {
            case .sent(let email): sentTo = email
            case .signedIn: onSignedIn()
            case .editing: sentTo = nil
            default: break
            }
        }
    }

    @ViewBuilder private var signInFields: some View {
        Group {
            if let applicationStatus {
                ApplicationStatusCard(model: ApplicationStatusModel(service: applicationStatus), onHolds: { holdsApplication = $0 })
                    .id(statusReload)
            }
            Group {
                Text("We’ll email you a link to sign in to your organization’s portal.")
                TextField("Work email", text: $model.email)
                    .textFieldStyle(.roundedBorder).keyboardType(.emailAddress).textContentType(.emailAddress)
                    .textInputAutocapitalization(.never).autocorrectionDisabled()
                    .accessibilityIdentifier("partner-sign-in-email")
                if case .failed(let message) = model.phase { failureText(message, id: "partner-sign-in-error") }
                Button(model.phase == .submitting ? "Sending…" : "Email me a sign-in link") { Task { await model.submit() } }
                    .buttonStyle(DADButtonStyle(.primary)).disabled(!model.canSubmit)
                    .accessibilityIdentifier("partner-sign-in-submit")
                if applicationSubmit != nil, !holdsApplication {
                    Button("New partner? Apply for your organization") { applying = true }
                        .buttonStyle(DADButtonStyle(.secondary)).accessibilityIdentifier("partner-apply-in-app")
                }
                if let applyURL {
                    Link(applicationSubmit == nil ? "New partner? Apply on the website" : "Prefer the website? Apply there",
                         destination: applyURL).accessibilityIdentifier("partner-apply")
                }
            }
        }
    }

    private func checkEmail(_ email: String, error: String?) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Check your email").font(.title2.bold()).accessibilityAddTraits(.isHeader)
            Text("We sent a sign-in link to \(email). Open it on this device to sign in.")
                .accessibilityIdentifier("partner-check-email")
            Text("Opened the email somewhere else? Paste the link here.").font(.footnote).foregroundStyle(.secondary)
            TextField("Sign-in link", text: $pasted)
                .textFieldStyle(.roundedBorder).textInputAutocapitalization(.never).autocorrectionDisabled()
                .accessibilityIdentifier("partner-paste-link")
            if let error { failureText(error, id: "partner-sign-in-error") }
            Button(model.phase == .accepting ? "Signing in…" : "Sign in with this link") { Task { await model.accept(pasted: pasted) } }
                .buttonStyle(DADButtonStyle(.primary))
                .disabled(pasted.trimmingCharacters(in: .whitespaces).isEmpty || model.phase == .accepting)
                .accessibilityIdentifier("partner-paste-submit")
            Button("Use a different email") { model.edit() }.buttonStyle(DADButtonStyle(.secondary))
        }
    }
}

/// The applicant's status, shown above partner sign-in only when the server recognizes this install's receipt.
private struct ApplicationStatusCard: View {
    @State var model: ApplicationStatusModel
    /// Whether this install holds an application that is still shown, so the sign-in screen can stop offering to apply.
    var onHolds: (Bool) -> Void = { _ in }
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        // A container, not a bare Group: `.task` on the empty initial state would never run.
        VStack(alignment: .leading, spacing: 0) {
            switch model.phase {
            case .loaded(let info):
                VStack(alignment: .leading, spacing: 6) {
                    Text(info.title).font(.headline).accessibilityAddTraits(.isHeader)
                    Text(info.message).accessibilityIdentifier("partner-application-message")
                }
                .padding(16).frame(maxWidth: .infinity, alignment: .leading)
                .background(scheme == .dark ? Color.dad("ink") : Color.dad("line").opacity(0.35), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                .accessibilityElement(children: .contain).accessibilityIdentifier("partner-application-status")
            case .failed(let message):
                VStack(alignment: .leading, spacing: 8) {
                    Text(message).font(.footnote).foregroundStyle(.secondary).accessibilityIdentifier("partner-application-error")
                    Button("Try again") { Task { await model.load() } }.buttonStyle(DADButtonStyle(.secondary))
                }
            case .loading, .none:
                EmptyView()
            }
        }
        .task { await model.load() }
        .onChange(of: model.phase) { _, phase in
            if case .loaded = phase { onHolds(true) }
        }
    }
}

/// The application form: the website's fields, submitted natively. After an unconfirmed attempt the form locks
/// and a retry resends exactly what was sent.
private struct PartnerApplicationForm: View {
    @State var model: PartnerApplicationModel
    let onCancel: () -> Void
    let onSubmitted: () -> Void

    private func field(_ title: String, text: Binding<String>, id: String, content: UITextContentType? = nil,
                       keyboard: UIKeyboardType = .default, capitalization: TextInputAutocapitalization = .words) -> some View {
        TextField(title, text: text)
            .textFieldStyle(.roundedBorder).textContentType(content).keyboardType(keyboard)
            .textInputAutocapitalization(capitalization).autocorrectionDisabled()
            .disabled(model.isLocked).accessibilityIdentifier(id)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Apply as a partner").font(.title2.bold()).accessibilityAddTraits(.isHeader)
            Text("Tell us about your organization. We’ll email you when it’s decided.").foregroundStyle(.secondary)
            field("Organization", text: $model.organization, id: "partner-app-organization", content: .organizationName)
            Picker("Organization type", selection: $model.type) {
                ForEach(PartnerOrganizationType.allCases) { Text($0.rawValue).tag($0) }
            }
            .disabled(model.isLocked).accessibilityIdentifier("partner-app-type")
            field("Website", text: $model.website, id: "partner-app-website", content: .URL, keyboard: .URL, capitalization: .never)
            field("Approximate workforce size", text: $model.workforce, id: "partner-app-workforce", keyboard: .numberPad, capitalization: .never)
            field("Your name", text: $model.contactName, id: "partner-app-contact", content: .name)
            field("Your title", text: $model.title, id: "partner-app-title", content: .jobTitle)
            field("Work email", text: $model.workEmail, id: "partner-app-email", content: .emailAddress, keyboard: .emailAddress, capitalization: .never)
            field("Phone", text: $model.phone, id: "partner-app-phone", content: .telephoneNumber, keyboard: .phonePad, capitalization: .never)
            if case .failed(let message) = model.phase { failureText(message, id: "partner-app-error") }
            Button(model.phase == .submitting ? "Sending…" : model.isLocked ? "Retry" : "Submit application") { Task { await model.submit() } }
                .buttonStyle(DADButtonStyle(.primary)).disabled(!model.canSubmit).accessibilityIdentifier("partner-app-submit")
            Button("Cancel", action: onCancel).buttonStyle(DADButtonStyle(.secondary)).disabled(model.phase == .submitting)
                .accessibilityIdentifier("partner-app-cancel")
        }
        .accessibilityElement(children: .contain).accessibilityIdentifier("partner-application-form")
        .onChange(of: model.phase) { _, phase in if phase == .submitted { onSubmitted() } }
    }
}

struct PartnerPortal: View {
    private enum Section: String, CaseIterable, Identifiable {
        case overview = "Overview", initiatives = "Initiatives", people = "People", organization = "Organization"
        var id: String { rawValue }
    }

    @State var model: PartnerModel
    /// The public site, for the company sign-up link; nil hides the company code's link and QR.
    let publicOrigin: URL?
    /// This device's APNs token once issued; the portal registers it for partner notifications.
    var pushToken: String?
    let onSignedOut: () -> Void
    @State private var section: Section = .overview

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            header
            switch model.phase {
            case .loading where model.overview == nil:
                ProgressView().accessibilityIdentifier("partner-loading")
            case .failed(let message) where model.overview == nil:
                VStack(alignment: .leading, spacing: 8) {
                    Text(message).accessibilityIdentifier("partner-error")
                    Button("Try again") { Task { await model.load() } }.buttonStyle(DADButtonStyle(.primary))
                }
            default:
                if let overview = model.overview {
                    Picker("Section", selection: $section) {
                        ForEach(Section.allCases) { Text($0.rawValue).tag($0) }
                    }
                    .pickerStyle(.segmented).accessibilityIdentifier("partner-sections")
                    if model.sectionsUnavailable {
                        VStack(alignment: .leading, spacing: 8) {
                            Text("Some details couldn’t be loaded right now.").font(.footnote).foregroundStyle(.secondary)
                            Button("Try again") { Task { await model.load() } }.buttonStyle(DADButtonStyle(.secondary))
                        }.accessibilityElement(children: .contain).accessibilityIdentifier("partner-partial")
                    }
                    if let notice = model.notice {
                        Text(notice).font(.footnote).accessibilityIdentifier("partner-notice")
                    }
                    if let error = model.actionError { failureText(error, id: "partner-action-error") }
                    switch section {
                    case .overview: PartnerOverviewSection(model: model, overview: overview)
                    case .initiatives: PartnerInitiativesSection(initiatives: model.initiatives)
                    case .people: PartnerPeopleSection(people: model.people, teams: model.teams)
                    case .organization:
                        PartnerOrganizationSection(model: model, overview: overview, publicOrigin: publicOrigin)
                    }
                }
            }
        }
        .frame(maxWidth: 560, alignment: .leading).padding(28).frame(maxWidth: .infinity)
        .accessibilityElement(children: .contain).accessibilityIdentifier("partner-portal")
        .task { await model.load() }
        .task(id: pushToken) { if let pushToken { await model.registerPush(token: pushToken, environment: .ofThisBuild) } }
        .onChange(of: model.signedOut) { _, out in if out { onSignedOut() } }
    }

    private var header: some View {
        HStack(spacing: 12) {
            if let data = model.logo, let image = UIImage(data: data) {
                Image(uiImage: image).resizable().scaledToFit().frame(width: 44, height: 44)
                    .accessibilityLabel("Organization logo").accessibilityIdentifier("partner-logo")
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(model.overview?.organization ?? "Partner portal").font(.largeTitle.bold()).accessibilityAddTraits(.isHeader)
                if let overview = model.overview {
                    Text(overview.role == .admin ? "Admin" : "Viewer").font(.footnote).foregroundStyle(.secondary)
                }
            }
        }
    }
}

/// Headline figures render ONLY when verified (§7.3); an unverified figure is left out, never estimated.
private struct PartnerOverviewSection: View {
    let model: PartnerModel
    let overview: PartnerOverview
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if let line = overview.verifiedLine() {
                Text(line).font(.footnote).foregroundStyle(.secondary).accessibilityIdentifier("partner-verified-line")
            }
            if let committed = overview.committed.label {
                Text("Committed: \(committed)").accessibilityIdentifier("partner-committed")
            }
            if let deployed = overview.deployed.label {
                Text("Deployed: \(deployed) (\(overview.deployedPercent)%)").accessibilityIdentifier("partner-deployed")
            }
            if let reached = overview.peopleReached.label {
                Text("People reached: \(reached)").accessibilityIdentifier("partner-reached")
            }
            if let enrolled = overview.enrolledLabel {
                Text("Enrolled: \(enrolled)").accessibilityIdentifier("partner-enrolled")
            }
        }
        if !model.spend.isEmpty {
            VStack(alignment: .leading, spacing: 4) {
                Text("Where it went").font(.title3.bold()).accessibilityAddTraits(.isHeader)
                ForEach(model.spend, id: \.category) { row in
                    HStack { Text(row.category); Spacer(); Text(row.amountLabel) }
                        .accessibilityElement(children: .combine)
                }
            }.accessibilityIdentifier("partner-spend")
        }
    }
}

private struct PartnerInitiativesSection: View {
    let initiatives: [PartnerInitiative]
    var body: some View {
        if initiatives.isEmpty {
            Text("No initiatives yet.").foregroundStyle(.secondary).accessibilityIdentifier("partner-initiatives-empty")
        }
        ForEach(initiatives, id: \.id) { initiative in
            VStack(alignment: .leading, spacing: 4) {
                Text(initiative.title).font(.headline)
                Text("\(initiative.status.label) · \(initiative.region)").font(.footnote).foregroundStyle(.secondary)
                Text(initiative.summary)
                Text("Committed \(initiative.committedLabel) · Deployed \(initiative.deployedLabel)").font(.footnote)
                ForEach(initiative.headlineMetrics, id: \.label) { metric in
                    Text("\(metric.label): \(metric.valueLabel)").font(.footnote)
                }
            }
            .padding(.vertical, 4)
            .accessibilityElement(children: .combine).accessibilityIdentifier("partner-initiative-\(initiative.id)")
        }
    }
}

private struct PartnerPeopleSection: View {
    let people: PartnerPeople?
    let teams: [TeamStanding]
    var body: some View {
        if let people {
            VStack(alignment: .leading, spacing: 4) {
                Text("Our people").font(.title3.bold()).accessibilityAddTraits(.isHeader)
                if let notice = people.suppressionNotice {
                    Text(notice).accessibilityIdentifier("partner-suppressed")
                } else {
                    Text("Enrolled: \(people.enrolled) of \(people.workforceSize)")
                    if let given = people.givenLabel { Text("Given: \(given)").accessibilityIdentifier("partner-given") }
                    if let matched = people.matchedLabel { Text("Matched: \(matched)") }
                    Text("Average streak: \(people.avgStreakDays) days")
                    Text("Volunteered: \(people.volunteerMinutes / 60) hours")
                }
            }
        }
        if !teams.isEmpty {
            VStack(alignment: .leading, spacing: 4) {
                Text("Teams").font(.title3.bold()).accessibilityAddTraits(.isHeader)
                Text("Teams with fewer than 5 people are left out.").font(.footnote).foregroundStyle(.secondary)
                ForEach(Array(teams.enumerated()), id: \.element.id) { index, team in
                    Text("\(index + 1). \(team.name) · \(team.activeGivers) givers · \(formatUSDMinor(Int(team.annualizedMinor)))/yr")
                        .accessibilityIdentifier("partner-team-\(team.id)")
                }
            }
        }
    }
}

private struct PartnerOrganizationSection: View {
    let model: PartnerModel
    let overview: PartnerOverview
    let publicOrigin: URL?

    var body: some View {
        PartnerProfileEditor(model: model, overview: overview)
        PartnerCompanyCode(code: overview.companyCode, publicOrigin: publicOrigin)
        PartnerUsersSection(model: model)
        if model.role.canExport { PartnerReportsSection(model: model) }
        Button("Sign out") { Task { await model.signOut() } }
            .buttonStyle(DADButtonStyle(.secondary)).accessibilityIdentifier("partner-sign-out")
    }
}

private struct PartnerProfileEditor: View {
    let model: PartnerModel
    let overview: PartnerOverview
    @State private var organization = ""
    @State private var about = ""
    @State private var workforce = ""
    @State private var photo: PhotosPickerItem?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Organization").font(.title3.bold()).accessibilityAddTraits(.isHeader)
            if model.role.canEditProfile {
                TextField("Organization name", text: $organization)
                    .textFieldStyle(.roundedBorder).accessibilityIdentifier("partner-profile-name")
                TextField("Description", text: $about, axis: .vertical)
                    .lineLimit(3...8).textFieldStyle(.roundedBorder).accessibilityIdentifier("partner-profile-description")
                Button("Save profile") { Task { await model.saveProfile(organization: organization, description: about) } }
                    .buttonStyle(DADButtonStyle(.primary)).disabled(model.isBusy).accessibilityIdentifier("partner-profile-save")
                TextField("Number of employees", text: $workforce)
                    .textFieldStyle(.roundedBorder).keyboardType(.numberPad).accessibilityIdentifier("partner-workforce")
                Text("Enrollment percentages are measured against this headcount.").font(.footnote).foregroundStyle(.secondary)
                Button("Save workforce size") { Task { await model.saveWorkforce(workforce) } }
                    .buttonStyle(DADButtonStyle(.secondary)).disabled(model.isBusy).accessibilityIdentifier("partner-workforce-save")
                HStack {
                    PhotosPicker(model.logo == nil ? "Add logo" : "Change logo", selection: $photo, matching: .images)
                        .accessibilityIdentifier("partner-logo-pick")
                    if model.logo != nil {
                        Spacer()
                        Button("Remove logo") { Task { await model.saveLogo(png: nil) } }
                            .buttonStyle(DADButtonStyle(.secondary, fillsWidth: false)).accessibilityIdentifier("partner-logo-remove")
                    }
                }
            } else {
                Text(overview.organization).font(.headline)
                if !overview.description.isEmpty { Text(overview.description) }
                Text("Employees: \(overview.workforceSize)").font(.footnote)
            }
        }
        .onAppear {
            organization = overview.organization
            about = overview.description
            workforce = String(overview.workforceSize)
        }
        .onChange(of: photo) { _, item in
            guard let item else { return }
            Task {
                photo = nil
                guard let data = try? await item.loadTransferable(type: Data.self), let png = LogoImage.png(from: data) else {
                    model.rejectLogo()
                    return
                }
                await model.saveLogo(png: png)
            }
        }
    }
}

/// Scales a picked image to the server's logo limits: a PNG no larger than 512 by 512 pixels and 256 KiB.
enum LogoImage {
    static func png(from data: Data) -> Data? {
        guard let image = UIImage(data: data), image.size.width > 0, image.size.height > 0 else { return nil }
        var side: CGFloat = 512
        while side >= 64 {
            let scale = min(1, side / max(image.size.width, image.size.height))
            let size = CGSize(width: (image.size.width * scale).rounded(.down), height: (image.size.height * scale).rounded(.down))
            let format = UIGraphicsImageRendererFormat()
            format.scale = 1
            let png = UIGraphicsImageRenderer(size: size, format: format).pngData { _ in image.draw(in: CGRect(origin: .zero, size: size)) }
            if png.count <= 256 * 1024 { return png }
            side /= 2
        }
        return nil
    }
}

/// The company code employees enroll with (EM-1), as a sign-up link and its QR code.
private struct PartnerCompanyCode: View {
    let code: String
    let publicOrigin: URL?
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Company code").font(.title3.bold()).accessibilityAddTraits(.isHeader)
            Text(code).font(.title2.monospaced().bold()).accessibilityIdentifier("partner-company-code")
            if let publicOrigin, let link = URL(string: "c/\(code)", relativeTo: publicOrigin)?.absoluteURL {
                if let qr = qrCodeImage(link.absoluteString, scale: 8) {
                    Image(uiImage: qr).interpolation(.none).resizable().frame(width: 160, height: 160)
                        .accessibilityLabel("QR code for \(link.absoluteString)").accessibilityIdentifier("partner-company-qr")
                }
                ShareLink("Share sign-up link", item: link).accessibilityIdentifier("partner-company-share")
            }
        }
    }
}

/// Users: an admin invites and removes inline (never themselves or the last admin); a viewer reads the list.
private struct PartnerUsersSection: View {
    let model: PartnerModel
    @State private var inviteEmail = ""
    @State private var inviteName = ""
    @State private var inviteRole: PartnerRole = .viewer

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Users").font(.title3.bold()).accessibilityAddTraits(.isHeader)
            ForEach(model.users) { user in
                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        Text("\(user.name) · \(user.role == .admin ? "Admin" : "Viewer")")
                        if model.canRemove(user) {
                            Spacer()
                            Button("Remove") { model.requestRemoval(id: user.id) }
                                .buttonStyle(DADButtonStyle(.secondary, fillsWidth: false))
                                .accessibilityLabel("Remove \(user.name)")
                                .accessibilityIdentifier("partner-remove-\(user.id)")
                        }
                    }
                    if model.pendingRemoval?.id == user.id {
                        VStack(alignment: .leading, spacing: 8) {
                            Text("Remove \(user.name) from your organization?").font(.footnote)
                            HStack {
                                Button("Cancel") { model.cancelRemoval() }
                                    .buttonStyle(DADButtonStyle(.secondary, fillsWidth: false))
                                    .accessibilityIdentifier("partner-remove-cancel")
                                Button("Confirm remove") { Task { await model.confirmRemoval() } }
                                    .buttonStyle(DADButtonStyle(.primary, fillsWidth: false))
                                    .accessibilityIdentifier("partner-remove-confirm")
                            }
                        }
                        .accessibilityElement(children: .contain)
                        .accessibilityIdentifier("partner-remove-prompt")
                    }
                }
            }
            if model.role.canManageUsers {
                TextField("Their name", text: $inviteName)
                    .textFieldStyle(.roundedBorder).textContentType(.name).accessibilityIdentifier("partner-invite-name")
                TextField("Their work email", text: $inviteEmail)
                    .textFieldStyle(.roundedBorder).keyboardType(.emailAddress)
                    .textContentType(.emailAddress).textInputAutocapitalization(.never).autocorrectionDisabled()
                    .accessibilityIdentifier("partner-invite-email")
                Picker("Role", selection: $inviteRole) {
                    Text("Viewer").tag(PartnerRole.viewer)
                    Text("Admin").tag(PartnerRole.admin)
                }.pickerStyle(.segmented).accessibilityIdentifier("partner-invite-role")
                Button("Invite user") {
                    let (email, name, role) = (inviteEmail, inviteName, inviteRole)
                    Task {
                        await model.inviteUser(email: email, name: name, role: role)
                        if model.actionError == nil { inviteEmail = ""; inviteName = "" }
                    }
                }
                .buttonStyle(DADButtonStyle(.primary))
                .disabled(!PartnerModel.isPlausibleEmail(inviteEmail) || inviteName.trimmingCharacters(in: .whitespaces).isEmpty || model.isBusy)
                .accessibilityIdentifier("partner-invite")
            } else {
                Text("Read-only access").font(.footnote).foregroundStyle(.secondary).accessibilityIdentifier("partner-readonly")
            }
        }
    }
}

/// Admin-only PDF impact reports (P-14): a new export, and earlier ones while they are retained.
private struct PartnerReportsSection: View {
    let model: PartnerModel
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Reports").font(.title3.bold()).accessibilityAddTraits(.isHeader)
            Button(model.isBusy ? "Preparing…" : "Export impact report") { Task { await model.exportReport() } }
                .buttonStyle(DADButtonStyle(.primary)).disabled(model.isBusy).accessibilityIdentifier("partner-export")
            if let report = model.report {
                ShareLink("Share report", item: report.url).accessibilityIdentifier("partner-report-share")
            }
            ForEach(model.exports) { export in
                HStack {
                    VStack(alignment: .leading) {
                        Text(export.createdAt.formatted(date: .abbreviated, time: .omitted))
                        Text("By \(export.exportedBy) · Committed \(formatUSDMinor(Int(export.committedMinor)))")
                            .font(.footnote).foregroundStyle(.secondary)
                    }
                    Spacer()
                    if export.downloadable {
                        Button("Download") { Task { await model.download(export) } }
                            .buttonStyle(DADButtonStyle(.secondary, fillsWidth: false)).disabled(model.isBusy)
                            .accessibilityIdentifier("partner-export-\(export.id)")
                    } else {
                        Text("No longer kept").font(.footnote).foregroundStyle(.secondary)
                    }
                }
            }
        }
    }
}
