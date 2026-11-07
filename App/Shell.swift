import SwiftUI
import DADFoundation

/// A pushed destination on a tab's `NavigationStack`. Shared so a deep link can push the same screen
/// the on-screen links reach, and so Home and Giving can both host gift history.
enum GiftRoute: Hashable { case history }
/// A-3 "Where the money went" push from Home.
struct SpendRoute: Hashable { let id: String; let title: String }

/// The four donor tabs. The raw title doubles as the VoiceOver label XCUITest addresses
/// (`app.tabBars.buttons["Home"]`), so no per-tab identifier is added.
enum DonorTab: Hashable { case home, circle, events, giving }

/// The signed-in donor shell: a `TabView` of four `NavigationStack`s (Home, Circle, Events, Giving),
/// a per-tab toolbar avatar that opens Settings as a sheet, and the deep-link/notification router that
/// selects a tab (and pushes gift history for `.gifts`). Replaces the former scrolling `DonorLanding`.
struct DonorShell: View {
    let model: AccountModel
    @Binding var destination: AccountDestination?
    @State private var selectedTab: DonorTab
    @State private var givingPath: [GiftRoute] = []
    @State private var showSettings = false
    /// The analytics question is asked once, after first sign-in. Shown
    /// the first time the signed-in shell appears while the choice is still unset.
    @State private var showAnalyticsChoice = false
    @ScaledMetric(relativeTo: .subheadline) private var avatarSize: CGFloat = 30

    init(model: AccountModel, destination: Binding<AccountDestination?>) {
        self.model = model
        _destination = destination
        // DEBUG screenshot/UITest aids: open straight onto a tab (replaces the old auto-opened sheets).
        let initial: DonorTab = launchFlag("--stub-open-engagement") ? .circle
            : launchFlag("--stub-open-events") ? .events
            : launchFlag("--stub-open-gift") ? .giving : .home
        _selectedTab = State(initialValue: initial)
    }

    /// The avatar's initial comes from the public name once the profile is read; a person glyph stands in
    /// until then (or when there is none).
    private var publicName: String? { if case .ready(let profile) = model.state { profile.publicName } else { nil } }

    var body: some View {
        TabView(selection: $selectedTab) {
            NavigationStack {
                homeContent
                    .navigationTitle("Home")
                    .navigationBarTitleDisplayMode(.large)
                    .navigationDestination(for: GiftRoute.self) { _ in giftHistory }
                    .navigationDestination(for: SpendRoute.self) { route in spend(route) }
                    .toolbar { avatarToolbar }
            }
            .tabItem { Label("Home", systemImage: "house.fill") }
            .tag(DonorTab.home)

            NavigationStack {
                circleContent
                    .navigationTitle("Circle")
                    .navigationBarTitleDisplayMode(.large)
                    .toolbar { avatarToolbar }
            }
            .tabItem { Label("Circle", systemImage: "person.2.fill") }
            .tag(DonorTab.circle)

            NavigationStack {
                eventsContent
                    .navigationTitle("Events")
                    .navigationBarTitleDisplayMode(.large)
                    .toolbar { avatarToolbar }
            }
            .tabItem { Label("Events", systemImage: "calendar") }
            .tag(DonorTab.events)

            NavigationStack(path: $givingPath) {
                givingContent
                    .navigationTitle("Giving")
                    .navigationBarTitleDisplayMode(.large)
                    .navigationDestination(for: GiftRoute.self) { _ in giftHistory }
                    .toolbar { avatarToolbar }
            }
            .tabItem { Label("Giving", systemImage: "heart.fill") }
            .tag(DonorTab.giving)
        }
        .tint(tokenColor("brand-ink"))
        .task(id: destinationKey) { route(destination) }
        .sheet(isPresented: $showSettings) {
            if let service = model.makeSettings() {
                SettingsSheet(service: service, passwords: model.passwordSettings, management: model.management,
                              giving: model.givingKit, onClose: { showSettings = false },
                              onSignedOut: { showSettings = false; Task { await model.load() } })
                .environment(model.analytics)
            }
        }
        .task {
            // Ask the analytics question once, right after first sign-in. The controller
            // persists the answer, so a later launch with a stored choice never re-presents it.
            if let analytics = model.analytics, analytics.choice == nil { showAnalyticsChoice = true }
        }
        .sheet(isPresented: $showAnalyticsChoice) {
            if let analytics = model.analytics {
                AnalyticsChoiceSheet(analytics: analytics) { showAnalyticsChoice = false }
            }
        }
    }

    /// `AccountDestination` isn't `Hashable`, so key the router task off the raw value.
    private var destinationKey: String? { destination?.rawValue }

    @ToolbarContentBuilder private var avatarToolbar: some ToolbarContent {
        ToolbarItem(placement: .topBarTrailing) {
            Button { showSettings = true } label: {
                Text(avatarInitial).font(.subheadline.weight(.semibold))
                    .frame(width: avatarSize, height: avatarSize)
                    .background(tokenColor("brand").opacity(0.18), in: Circle())
                    .overlay(Circle().strokeBorder(tokenColor("brand-ink").opacity(0.4)))
            }
            .accessibilityLabel("Account and settings")
            .accessibilityAddTraits(.isButton)
            .accessibilityIdentifier("open-settings")
        }
    }

    private var avatarInitial: String {
        guard let first = publicName?.trimmingCharacters(in: .whitespaces).first else { return "•" }
        return String(first).uppercased()
    }

    private func onSignedOut() { Task { await model.load() } }

    // MARK: - Tab roots

    @ViewBuilder private var homeContent: some View {
        if case .ready(let profile) = model.state, let dashboard = model.dashboardService {
            DonorHomeView(service: dashboard, giving: model.givingKit, events: model.eventsService,
                          engagement: model.engagementService, wallet: model.walletService,
                          greeting: profile.publicName, preview: model.preview,
                          onSwitchToGiving: { selectedTab = .giving },
                          onInvite: { selectedTab = .circle },
                          destination: $destination, onSignedOut: onSignedOut)
        } else {
            accountState
        }
    }

    @ViewBuilder private var circleContent: some View {
        if let engagement = model.engagementService {
            EngagementHome(model: EngagementModel(service: engagement),
                           wallet: model.walletService.map { WalletPassModel(service: $0) },
                           onSignedOut: onSignedOut)
        } else {
            accountState
        }
    }

    @ViewBuilder private var eventsContent: some View {
        if let events = model.eventsService {
            EventsScreen(model: EventsModel(service: events), service: events, onSignedOut: onSignedOut)
        } else {
            accountState
        }
    }

    @ViewBuilder private var givingContent: some View {
        if let giving = model.givingKit {
            ScrollView {
                GiftScreen(model: giving.makeModel(), stubComplete: giving.stubComplete,
                           onSignedOut: onSignedOut, onInvite: { selectedTab = .circle },
                           foundingProvider: model.dashboardService)
            }
            .modifier(AppBackground())
        } else {
            accountState
        }
    }

    @ViewBuilder private var giftHistory: some View {
        if let dashboard = model.dashboardService {
            GiftHistoryScreen(service: dashboard, onSignedOut: onSignedOut)
        }
    }

    @ViewBuilder private func spend(_ route: SpendRoute) -> some View {
        if let engagement = model.engagementService {
            InitiativeSpendScreen(model: InitiativeSpendModel(service: engagement, initiativeID: route.id),
                                  title: route.title, onSignedOut: onSignedOut)
        }
    }

    /// Loading / unavailable / signed-out: the synthetic preview and the retry path reach these before a
    /// service exists. Carries the same copy and `account-state` identifier the former landing used.
    @ViewBuilder private var accountState: some View {
        Group {
            switch model.state {
            case .loading:
                ProgressView("Loading your account…")
            case .ready(let profile):
                VStack(alignment: .leading, spacing: 8) {
                    Text(profile.publicName.map { "Hi, \($0)" } ?? "Welcome back").font(.title2.bold())
                    Text("Your account has a home here.")
                }
            case .unavailable:
                VStack(alignment: .leading, spacing: 12) {
                    Text("Your account is unavailable right now.").font(.headline)
                    Text("Please try again in a moment.")
                    Button("Try again") { Task { await model.load() } }.buttonStyle(DADButtonStyle(.primary))
                }
            case .signedOut:
                Text("You’re signed out. Use your DAD sign-in link to continue.")
            }
            if model.preview { Text("Preview · Sample account").font(.footnote).foregroundStyle(.secondary) }
        }
        .frame(maxWidth: 520, alignment: .leading).padding(28).frame(maxWidth: .infinity, alignment: .topLeading)
        .accessibilityElement(children: .contain).accessibilityIdentifier("account-state")
    }

    // MARK: - Routing (R-INV R1–R4)

    private func route(_ destination: AccountDestination?) {
        guard let destination else { return }
        switch destination {
        case .dashboard:
            selectedTab = .home
        case .gifts:
            selectedTab = .giving
            givingPath = [.history]
        case .paymentMethod:
            selectedTab = .giving
        case .profile:
            showSettings = true
        }
        self.destination = nil
    }
}

/// Settings presented from the donor shell: sign-out and deletion run against the real session, and
/// leaving the signed-in state dismisses the sheet so the root can route to sign-in. "Done" lives in a
/// cancellation-action toolbar item rather than an inline button.
struct SettingsSheet: View {
    let service: any AccountSettingsService
    let passwords: (any PasswordSettingsService)?
    var management: (any AccountManagementService)?
    var giving: GivingKit?
    let onClose: () -> Void
    let onSignedOut: () -> Void
    var body: some View {
        NavigationStack {
            ScrollView {
                AccountSettingsScreen(model: AccountSettingsModel(service: service), passwords: passwords, management: management,
                                      giving: giving, onSignedOut: onSignedOut)
            }
            .modifier(AppBackground())
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done", action: onClose).accessibilityIdentifier("settings-close")
                }
            }
        }.tint(tokenColor("brand-ink"))
    }
}
