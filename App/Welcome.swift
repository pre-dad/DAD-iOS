import SwiftUI
import Combine
import DADFoundation

/// The Founding Donor window closes at the end of Dec 31 2026, New York time. Shown at most once per
/// screen (Welcome and the celebration). After the deadline the line is hidden entirely.
enum FoundingWindow {
    /// Start of Jan 1 2027 America/New_York — the first instant the window is closed.
    static let closesAt: Date = {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "America/New_York") ?? .current
        return cal.date(from: DateComponents(year: 2027, month: 1, day: 1)) ?? .distantFuture
    }()

    /// Whole days remaining until the window closes, or nil once it has (hide the line).
    static func daysRemaining(from now: Date = Date()) -> Int? {
        guard now < closesAt else { return nil }
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "America/New_York") ?? .current
        let days = cal.dateComponents([.day], from: now, to: closesAt).day ?? 0
        return max(days, 0)
    }

    /// "Founding Donor: 54 days left" — nil after the deadline.
    static func line(from now: Date = Date()) -> String? {
        guard let days = daysRemaining(from: now) else { return nil }
        return "Founding Donor: \(days) \(days == 1 ? "day" : "days") left"
    }
}

/// The unauthenticated landing: brand, value proposition, the Founding window, the invitation and
/// notice messages, and three graded actions. Each action emits `.roleSelected`.
struct WelcomeScreen: View {
    let notice: String?
    var invitation: String?
    /// Primary "Give $1 a day" → create-account (donor).
    let onGive: () -> Void
    /// Secondary "I already give — sign in" → sign-in methods (donor).
    let onSignIn: () -> Void
    /// Tertiary "Partner organization? Sign in here" → partner sign-in.
    let onPartner: () -> Void
    @Environment(AnalyticsController.self) private var analytics: AnalyticsController?
    @ScaledMetric(relativeTo: .largeTitle) private var logoSize: CGFloat = 44

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            Image(systemName: "heart.circle.fill").font(.system(size: logoSize))
                .foregroundStyle(Color.dad("brand")).accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 8) {
                Text("Aid, delivered.").font(.caption).textCase(.uppercase).foregroundStyle(Color.dad("dkmut"))
                Text("A dollar a day. Every dollar on the record.")
                    .font(.dadDisplay(.largeTitle, size: 34)).accessibilityAddTraits(.isHeader)
                Text("Give monthly, invite the people you know, and watch your circle grow.")
                    .font(.body).foregroundStyle(Color.dad("dkmut"))
            }
            if let founding = FoundingWindow.line() {
                Label(founding, systemImage: "star.fill").font(.footnote.weight(.semibold))
                    .foregroundStyle(Color.dad("brand"))
            }
            if let notice {
                Text(notice).font(.footnote).foregroundStyle(Color.dad("fail")).accessibilityIdentifier("auth-notice")
            }
            if let invitation { Text(invitation).font(.body).accessibilityIdentifier("auth-invitation") }
            VStack(spacing: 12) {
                Button("Give $1 a day") { analytics?.emit(.roleSelected); onGive() }
                    .buttonStyle(DADButtonStyle(.primary))
                Button("I already give — sign in") { analytics?.emit(.roleSelected); onSignIn() }
                    .buttonStyle(DADButtonStyle(.secondary))
                Button("Partner organization? Sign in here") { analytics?.emit(.roleSelected); onPartner() }
                    .buttonStyle(DADButtonStyle(.tertiary))
            }
        }
        .frame(maxWidth: 520, alignment: .leading).padding(28).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(Color.dad("ink-deep").ignoresSafeArea())
        .foregroundStyle(Color.dad("paper"))
        .accessibilityElement(children: .contain).accessibilityIdentifier("role-select")
    }
}

/// Sign-in method picker (PRD §5.1). Phone is the primary ("Continue with
/// phone"), email link secondary. Methods `SignInCapabilities` reports unavailable are HIDDEN rather
/// than shown disabled; any available Apple/Google/passkey render as a secondary row, and password
/// lives under a "More options" disclosure. A "New to DAD?" card offers "Get started" (signup).
private struct SignInMethods: View {
    let capabilities: SignInCapabilities
    let onSelect: (SignInMethod) -> Void
    let onCreateAccount: () -> Void
    @State private var showMore = false

    /// Apple/Google/passkey that this build actually wired — unavailable ones are not listed at all.
    private var externalMethods: [SignInMethod] {
        [.apple, .google, .passkey].filter { capabilities.isAvailable($0) }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Welcome back").font(.largeTitle.bold()).accessibilityAddTraits(.isHeader)
            VStack(spacing: 12) {
                Button(SignInMethod.phone.title) { onSelect(.phone) }
                    .buttonStyle(DADButtonStyle(.primary))
                Button(SignInMethod.emailLink.title) { onSelect(.emailLink) }
                    .buttonStyle(DADButtonStyle(.secondary))
                ForEach(externalMethods) { method in
                    Button(method.title) { onSelect(method) }
                        .buttonStyle(DADButtonStyle(.secondary))
                }
            }
            DisclosureGroup("More options", isExpanded: $showMore) {
                Button(SignInMethod.password.title) { onSelect(.password) }
                    .buttonStyle(DADButtonStyle(.tertiary))
            }
            if capabilities.hasUnavailableMethod {
                // Honest note that some methods this build can't offer are simply not shown.
                Text("Apple, Google and passkey sign-in aren’t available in this build yet.")
                    .font(.footnote).foregroundStyle(.secondary).accessibilityIdentifier("methods-unavailable-note")
            }
            Divider()
            DADCard {
                VStack(alignment: .leading, spacing: 8) {
                    Text("New to DAD?").font(.headline)
                    Button("Get started", action: onCreateAccount)
                        .buttonStyle(DADButtonStyle(.secondary)).accessibilityIdentifier("create-account")
                }
            }
        }
        .frame(maxWidth: 520, alignment: .leading).padding(28).frame(maxWidth: .infinity)
        .accessibilityElement(children: .contain).accessibilityIdentifier("sign-in-methods")
    }
}

/// Phone + SMS one-time-code journey, bound to `PhoneSignInModel`.
private struct PhoneSignIn: View {
    @State var model: PhoneSignInModel
    let onSignedIn: () -> Void
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Sign in with your phone").font(.title.bold()).accessibilityAddTraits(.isHeader)
            if model.isAwaitingCode {
                TextField("Verification code", text: $model.code)
                    .textFieldStyle(.roundedBorder)
                    .textContentType(.oneTimeCode)
                    .keyboardType(.numberPad)
                    .accessibilityLabel("Verification code")
                failure
                Button("Verify") { Task { await model.verify() } }
                    .buttonStyle(DADButtonStyle(.primary))
                    .disabled(!model.canVerify)
            } else if case .signedIn = model.phase {
                Text("You’re signed in.").font(.headline)
            } else {
                TextField("Phone number", text: $model.phone)
                    .textFieldStyle(.roundedBorder)
                    .textContentType(.telephoneNumber)
                    .keyboardType(.phonePad)
                    .accessibilityLabel("Phone number")
                failure
                Button("Send code") { Task { await model.requestCode() } }
                    .buttonStyle(DADButtonStyle(.primary))
                    .disabled(!model.canRequestCode)
            }
            if model.phase == .requestingCode || isVerifying { ProgressView() }
        }
        .frame(maxWidth: 520, alignment: .leading).padding(28).frame(maxWidth: .infinity)
        .accessibilityElement(children: .contain).accessibilityIdentifier("phone-sign-in")
        .onChange(of: model.phase) { _, phase in if case .signedIn = phase { onSignedIn() } }
    }

    private var isVerifying: Bool {
        if case .verifying = model.phase { true } else { false }
    }

    @ViewBuilder private var failure: some View {
        if case .failed(let message) = model.phase {
            Text(message).font(.footnote).foregroundStyle(Color.dad("fail"))
        }
    }
}

/// New-donor signup (D-2): name, email, ZIP, city. The server emails a single-use sign-in link
/// (it never reveals whether the address exists); the link signs the donor in and lands in the donor
/// shell. A pasted link works when the email was opened on another device.
private struct SignupView: View {
    @State var model: SignupModel
    let notice: String?
    let onBack: () -> Void
    let onPasteLink: (String) -> Bool
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Step 1 of 2 · About you").font(.title.bold()).accessibilityAddTraits(.isHeader)
            if case .sent(let email) = model.phase {
                CheckEmailView(
                    email: email,
                    detail: "Open it on this device to finish creating your account. The link works once and expires in 15 minutes.",
                    notice: notice, onPasteLink: onPasteLink, onResend: { Task { await model.submit() } }, onEdit: { model.edit() })
            } else {
                formBody
            }
            Button("Back", action: onBack).buttonStyle(DADButtonStyle(.secondary)).accessibilityIdentifier("signup-back")
        }
        .frame(maxWidth: 520, alignment: .leading).padding(28).frame(maxWidth: .infinity)
        .accessibilityElement(children: .contain).accessibilityIdentifier("signup")
    }

    @ViewBuilder private var formBody: some View {
        TextField("Full name", text: $model.name)
            .textFieldStyle(.roundedBorder).textContentType(.name).textInputAutocapitalization(.words)
            .accessibilityLabel("Full name")
        TextField("Email", text: $model.email)
            .textFieldStyle(.roundedBorder).textContentType(.emailAddress).keyboardType(.emailAddress)
            .textInputAutocapitalization(.never).autocorrectionDisabled().accessibilityLabel("Email")
        TextField("ZIP code", text: $model.zip)
            .textFieldStyle(.roundedBorder).textContentType(.postalCode).keyboardType(.numberPad)
            .accessibilityLabel("ZIP code")
        TextField("City", text: $model.city)
            .textFieldStyle(.roundedBorder).textContentType(.addressCity).textInputAutocapitalization(.words)
            .accessibilityLabel("City")
        if case .failed(let message) = model.phase {
            Text(message).font(.footnote).foregroundStyle(Color.dad("fail")).accessibilityIdentifier("signup-error")
        }
        Button("Create account") { Task { await model.submit() } }
            .buttonStyle(DADButtonStyle(.primary)).disabled(!model.canSubmit)
        if model.phase == .submitting { ProgressView() }
    }
}

/// "Check your email" after a link was requested (signup or sign-in): the emailed link opens the app,
/// and a link opened on another device can be pasted here instead.
private struct CheckEmailView: View {
    /// The address the link went to, shown bold in the header line.
    let email: String
    /// The rest of the instruction (link is single-use, expires, works on this device).
    let detail: String
    let notice: String?
    let onPasteLink: (String) -> Bool
    let onResend: () -> Void
    let onEdit: () -> Void
    @State private var pasted = ""
    @State private var pasteFailed = false
    /// Seconds until Resend re-enables. A STATIC count (a once-a-second tick, never an animated
    /// number) honours the motion rule: the digits change, nothing animates.
    @State private var resendIn = 30
    private let tick = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

    var body: some View {
        Text("Check your inbox").font(.headline).accessibilityAddTraits(.isHeader).accessibilityIdentifier("signup-sent")
        (Text("We emailed ") + Text(email).bold() + Text(" a sign-in link. \(detail)"))
        if let notice {
            Text(notice).font(.footnote).foregroundStyle(Color.dad("fail")).accessibilityIdentifier("signup-link-error")
        }
        Text("Opened the email somewhere else? Paste the link here.").font(.footnote)
        TextField("Paste your sign-in link", text: $pasted)
            .textFieldStyle(.roundedBorder).keyboardType(.URL).textInputAutocapitalization(.never).autocorrectionDisabled()
            .accessibilityLabel("Paste your sign-in link")
        if pasteFailed {
            Text("That doesn’t look like a DAD sign-in link.").font(.footnote).foregroundStyle(Color.dad("fail"))
                .accessibilityIdentifier("signup-paste-error")
        }
        Button("Continue") { pasteFailed = !onPasteLink(pasted) }
            .buttonStyle(DADButtonStyle(.primary)).disabled(pasted.isEmpty).accessibilityIdentifier("signup-continue")
        Button(resendIn > 0 ? "Resend in \(resendIn)s" : "Resend the email") { resendIn = 30; onResend() }
            .buttonStyle(DADButtonStyle(.secondary)).disabled(resendIn > 0).accessibilityIdentifier("signup-resend")
        Button("Use a different email", action: onEdit).buttonStyle(DADButtonStyle(.secondary))
            .onReceive(tick) { _ in if resendIn > 0 { resendIn -= 1 } }
    }
}

/// An existing donor asks for a single-use sign-in link by email (`login`). The server never says
/// whether the address has an account, so the same "check your email" step follows either way.
private struct EmailLinkSignIn: View {
    @State var model: SignInLinkModel
    let notice: String?
    let onBack: () -> Void
    let onPasteLink: (String) -> Bool
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Sign in with an email link").font(.title.bold()).accessibilityAddTraits(.isHeader)
            if case .sent(let email) = model.phase {
                CheckEmailView(
                    email: email,
                    detail: "If it belongs to a DAD account, open it on this device to sign in. The link works once and expires in 15 minutes.",
                    notice: notice, onPasteLink: onPasteLink, onResend: { Task { await model.submit() } }, onEdit: { model.edit() })
            } else {
                TextField("Email", text: $model.email)
                    .textFieldStyle(.roundedBorder).textContentType(.emailAddress).keyboardType(.emailAddress)
                    .textInputAutocapitalization(.never).autocorrectionDisabled().accessibilityLabel("Email")
                if case .failed(let message) = model.phase {
                    Text(message).font(.footnote).foregroundStyle(Color.dad("fail")).accessibilityIdentifier("email-link-error")
                }
                Button("Email me a link") { Task { await model.submit() } }
                    .buttonStyle(DADButtonStyle(.primary)).disabled(!model.canSubmit).accessibilityIdentifier("email-link-submit")
                if model.phase == .submitting { ProgressView() }
            }
            Button("Back", action: onBack).buttonStyle(DADButtonStyle(.secondary))
        }
        .frame(maxWidth: 520, alignment: .leading).padding(28).frame(maxWidth: .infinity)
        .accessibilityElement(children: .contain).accessibilityIdentifier("email-link-sign-in")
    }
}

/// Email + password sign-in, bound to `PasswordSignInModel`. The password field is a secure entry
/// field that offers saved credentials; the model clears the secret as soon as it is sent.
private struct PasswordSignIn: View {
    @State var model: PasswordSignInModel
    let onBack: () -> Void
    let onSignedIn: () -> Void
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Sign in with email & password").font(.title.bold()).accessibilityAddTraits(.isHeader)
            TextField("Email", text: $model.email)
                .textFieldStyle(.roundedBorder).textContentType(.username).keyboardType(.emailAddress)
                .textInputAutocapitalization(.never).autocorrectionDisabled().accessibilityLabel("Email")
            SecureField("Password", text: $model.password)
                .textFieldStyle(.roundedBorder).textContentType(.password).accessibilityLabel("Password")
            if case .failed(let message) = model.phase {
                Text(message).font(.footnote).foregroundStyle(Color.dad("fail")).accessibilityIdentifier("password-sign-in-error")
            }
            Button("Sign in") { Task { await model.submit() } }
                .buttonStyle(DADButtonStyle(.primary)).disabled(!model.canSubmit).accessibilityIdentifier("password-sign-in-submit")
            if model.phase == .submitting { ProgressView() }
            Button("Back", action: onBack).buttonStyle(DADButtonStyle(.secondary))
        }
        .frame(maxWidth: 520, alignment: .leading).padding(28).frame(maxWidth: .infinity)
        .accessibilityElement(children: .contain).accessibilityIdentifier("password-sign-in")
        .onChange(of: model.phase) { _, phase in if case .signedIn = phase { onSignedIn() } }
    }
}

/// One in-flight Apple / Google / passkey attempt: the platform sheet runs on appear.
@MainActor private struct ExternalRun {
    let title: String
    let phase: () -> ExternalSignInPhase
    let start: () async -> Void
}

private struct ExternalSignInView: View {
    let run: ExternalRun
    let onBack: () -> Void
    let onSignedIn: () -> Void
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(run.title).font(.title.bold()).accessibilityAddTraits(.isHeader)
            switch run.phase() {
            case .working: ProgressView()
            case .failed(let message):
                Text(message).font(.footnote).foregroundStyle(Color.dad("fail")).accessibilityIdentifier("external-sign-in-error")
                Button("Try again") { Task { await run.start() } }.buttonStyle(DADButtonStyle(.primary))
            case .idle:
                Button("Try again") { Task { await run.start() } }.buttonStyle(DADButtonStyle(.primary))
            case .signedIn:
                Text("You’re signed in.").font(.headline)
            }
            Button("Back", action: onBack).buttonStyle(DADButtonStyle(.secondary))
        }
        .frame(maxWidth: 520, alignment: .leading).padding(28).frame(maxWidth: .infinity)
        .accessibilityElement(children: .contain).accessibilityIdentifier("external-sign-in")
        .task { await run.start() }
        .onChange(of: run.phase()) { _, phase in if case .signedIn = phase { onSignedIn() } }
    }
}

/// Used when no API origin is configured (Release): sign-in fails clearly instead of inheriting a preview double.
private struct UnconfiguredSignIn: SignInService, SignupService, SignInLinkService, PasswordSignInService {
    func requestPhoneCode(phone: String) async throws -> String { throw AccountError.invalidConfiguration }
    func verifyPhone(handle: String, code: String) async throws -> Credentials { throw AccountError.invalidConfiguration }
    func requestSignup(_ form: SignupForm) async throws { throw AccountError.invalidConfiguration }
    func requestSignInLink(email: String) async throws { throw AccountError.invalidConfiguration }
    func signIn(email: String, password: String) async throws -> Credentials { throw AccountError.invalidConfiguration }
}

/// Every sign-in transport the unauthenticated stack can use, plus which optional methods are on.
struct SignInKit {
    let phone: any SignInService
    let signup: any SignupService
    let link: any SignInLinkService
    let password: any PasswordSignInService
    let oidc: (any OIDCSignInService)?
    let passkey: (any PasskeySignInService)?
    let capabilities: SignInCapabilities
    var passkeyRelyingParty = ""

    static let unconfigured = SignInKit(phone: UnconfiguredSignIn(), signup: UnconfiguredSignIn(), link: UnconfiguredSignIn(),
                                        password: UnconfiguredSignIn(),
                                        oidc: nil, passkey: nil, capabilities: .none)
    #if DEBUG
    static let preview = SignInKit(phone: PreviewSignIn(), signup: PreviewSignIn(), link: PreviewSignIn(), password: PreviewSignIn(),
                                   oidc: nil, passkey: nil, capabilities: .none)
    #endif
}

/// The unauthenticated stack: role select → sign-in methods → the chosen method's flow. Verification
/// runs through `establish` so the session (not this view) owns the network await and its epoch guard.
struct UnauthenticatedStack: View {
    let kit: SignInKit
    let establish: PhoneSignInModel.Establish
    let notice: String?
    var invitation: String?
    let onPasteLink: (String) -> Bool
    var partnerSignIn: (any PartnerSignInService)?
    var applicationStatus: (any ApplicationStatusService)?
    var applicationSubmit: (any PartnerApplicationService)?
    var partnerToken: String?
    var onPartnerTokenConsumed: () -> Void = {}
    var onPartnerSignedIn: () -> Void = {}
    var publicOrigin: URL?
    let onSignedIn: () -> Void
    @State private var step: Step = .roleSelect
    @State private var external: ExternalRun?
    private enum Step: Equatable { case roleSelect, methods, phone, emailLink, password, signup, external, partner }

    var body: some View {
        content.onChange(of: partnerToken, initial: true) { _, token in if token != nil { step = .partner } }
    }

    @ViewBuilder private var content: some View {
        switch step {
        case .roleSelect:
            WelcomeScreen(notice: notice, invitation: invitation,
                          onGive: { step = .signup },
                          onSignIn: { step = .methods },
                          onPartner: { step = .partner })
        case .methods:
            SignInMethods(capabilities: kit.capabilities, onSelect: select, onCreateAccount: { step = .signup })
        case .phone:
            PhoneSignIn(model: PhoneSignInModel(service: kit.phone, establish: establish), onSignedIn: onSignedIn)
        case .password:
            PasswordSignIn(model: PasswordSignInModel(service: kit.password, establish: establish),
                           onBack: { step = .methods }, onSignedIn: onSignedIn)
        case .emailLink:
            EmailLinkSignIn(model: SignInLinkModel(service: kit.link), notice: notice, onBack: { step = .methods }, onPasteLink: onPasteLink)
        case .signup:
            SignupView(model: SignupModel(service: kit.signup), notice: notice, onBack: { step = .methods }, onPasteLink: onPasteLink)
        case .external:
            if let external {
                ExternalSignInView(run: external, onBack: { step = .methods; self.external = nil }, onSignedIn: onSignedIn)
            }
        case .partner:
            if let partnerSignIn {
                PartnerSignInFlow(model: PartnerSignInModel(service: partnerSignIn), incomingToken: partnerToken,
                                  onTokenConsumed: onPartnerTokenConsumed, onBack: { step = .roleSelect }, onSignedIn: onPartnerSignedIn,
                                  applyURL: publicOrigin?.appending(path: "apply"),
                                  applicationStatus: applicationStatus, applicationSubmit: applicationSubmit)
            }
        }
    }

    private func select(_ method: SignInMethod) {
        switch method {
        case .phone: step = .phone
        case .emailLink: step = .emailLink
        case .password: step = .password
        case .apple, .google:
            guard let oidc = kit.oidc else { return }
            let provider: OIDCProvider = method == .apple ? .apple : .google
            guard let tokens: any IDTokenProvider = method == .apple ? AppleIDTokenProvider() : GoogleSignIn.provider else { return }
            let model = OIDCSignInModel(provider: provider, tokens: tokens, service: oidc, establish: establish)
            external = ExternalRun(title: method.title, phase: { model.phase }, start: { await model.start() })
            step = .external
        case .passkey:
            guard let passkey = kit.passkey else { return }
            let model = PasskeySignInModel(authenticator: PlatformPasskeyAuthenticator(fallbackRelyingParty: kit.passkeyRelyingParty),
                                           service: passkey, establish: establish)
            external = ExternalRun(title: method.title, phase: { model.phase }, start: { await model.start() })
            step = .external
        }
    }
}
