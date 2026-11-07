import SwiftUI
import DADFoundation

// Donor home reads (PRD S-1..S-4, A-1..A-5, I-1..I-3, gift history). Bound to `DashboardModel` and
// `GiftHistoryModel`; every state the server can produce has its own on-screen answer, and state is
// always carried in text as well as colour.

/// "2025-01-02" -> "January 2, 2025"; anything unparseable is shown as sent rather than dropped.
private func friendlyDate(_ value: String) -> String {
    let parser = DateFormatter()
    parser.locale = Locale(identifier: "en_US_POSIX")
    parser.dateFormat = "yyyy-MM-dd"
    guard let date = parser.date(from: value) else { return value }
    return date.formatted(date: .long, time: .omitted)
}

/// The Home header's small date line, e.g. "Monday, November 2". Pinned to en_US_POSIX so the
/// weekday/month words are stable regardless of host locale.
private func homeHeaderDate(_ date: Date = Date()) -> String {
    let f = DateFormatter()
    f.locale = Locale(identifier: "en_US_POSIX")
    f.setLocalizedDateFormatFromTemplate("EEEEMMMMd")
    return f.string(from: date)
}

struct DonorHomeView: View {
    @State private var model: DashboardModel
    let onSignedOut: () -> Void
    private let service: any DashboardService
    private let giving: GivingKit?
    private let events: (any EventsService)?
    private let engagement: (any EngagementService)?
    private let wallet: (any WalletPassService)?
    /// The donor's public name for the "Hi, …" greeting the home shows (nil → "Welcome back").
    private let greeting: String?
    private let preview: Bool
    /// Switch the shell to the Giving tab (at-risk "Update payment" and the monthly-gift row).
    private let onSwitchToGiving: () -> Void
    /// Switch the shell to the Circle tab (the "Invite someone" primary; Circle owns ShareLink/QR).
    private let onInvite: () -> Void
    @State private var giftModel: GivingModel?
    /// A screen a tapped notification asked for. Routing now lives in the shell (tab + push); the
    /// binding stays so Home can be constructed with the same signature.
    @Binding private var destination: AccountDestination?

    init(service: any DashboardService, giving: GivingKit? = nil, events: (any EventsService)? = nil,
         engagement: (any EngagementService)? = nil, wallet: (any WalletPassService)? = nil,
         greeting: String? = nil, preview: Bool = false,
         onSwitchToGiving: @escaping () -> Void = {}, onInvite: @escaping () -> Void = {},
         destination: Binding<AccountDestination?> = .constant(nil), onSignedOut: @escaping () -> Void) {
        _destination = destination
        self.service = service
        self.giving = giving
        self.events = events
        self.engagement = engagement
        self.wallet = wallet
        self.greeting = greeting
        self.preview = preview
        self.onSwitchToGiving = onSwitchToGiving
        self.onInvite = onInvite
        self.onSignedOut = onSignedOut
        _model = State(initialValue: DashboardModel(service: service))
        _giftModel = State(initialValue: giving?.makeModel())
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                header
                if let notice = model.refreshNotice {
                    Text(notice).font(.footnote).foregroundStyle(Color.dad("fail")).accessibilityIdentifier("dashboard-notice")
                }
                switch model.phase {
                case .loading:
                    ProgressView("Loading your dashboard…").accessibilityIdentifier("dashboard-loading")
                case .failed(let message):
                    VStack(alignment: .leading, spacing: 12) {
                        Text(message).accessibilityIdentifier("dashboard-error")
                        Button("Try again") { Task { await model.load() } }
                            .buttonStyle(DADButtonStyle(.primary)).accessibilityIdentifier("dashboard-retry")
                    }
                case .ready(.preparing):
                    DADCard {
                        VStack(alignment: .leading, spacing: 8) {
                            Text("Getting your dashboard ready").font(.headline)
                            Text("Your numbers appear here once your first gift has been counted.").font(.footnote)
                            Button("Refresh") { Task { await model.load() } }.buttonStyle(DADButtonStyle(.secondary))
                        }
                    }.accessibilityElement(children: .contain).accessibilityIdentifier("dashboard-preparing")
                case .ready(.ready(let dashboard)):
                    DashboardCards(dashboard: dashboard, onUpdatePayment: onSwitchToGiving)
                    // The lone primary on Home: Circle owns the share/QR affordances.
                    Button("Invite someone", action: onInvite)
                        .buttonStyle(DADButtonStyle(.primary)).accessibilityIdentifier("invite-someone")
                }
                // A-3: "Where the money went" is a push, not a sheet. The link carries the initiative's id.
                InitiativeCard(phase: model.initiative, onRetry: { Task { await model.load() } },
                               spendRoute: engagement == nil ? nil : { id, title in SpendRoute(id: id, title: title) })
                if let giftModel { GiftSummaryCard(model: giftModel, onOpen: onSwitchToGiving) }
                // Gift history is a push from Home; the Giving tab reaches it too (shell deep-link).
                NavigationLink(value: GiftRoute.history) { Text("Gift history") }
                    .buttonStyle(DADButtonStyle(.secondary)).accessibilityIdentifier("open-history")
            }
            .frame(maxWidth: 560, alignment: .leading).padding(28).frame(maxWidth: .infinity)
            .accessibilityElement(children: .contain).accessibilityIdentifier("donor-home")
        }
        .modifier(HistoryBackground())
        .task { await model.load() }
        .task { await giftModel?.load() }
        .refreshable { await model.load(); await giftModel?.load() }
        .onChange(of: model.signedOut) { _, signedOut in if signedOut { onSignedOut() } }
        // Warning haptic when the streak is at risk (payment needs attention).
        .sensoryFeedback(.warning, trigger: streakAtRisk)
    }

    /// Whether the dashboard's streak is currently at risk — drives the warning haptic.
    private var streakAtRisk: Bool {
        if case .ready(.ready(let dashboard)) = model.phase { return dashboard.streak?.atRisk == true }
        return false
    }

    /// Small date line over a large "Hi, {name}" title; "Welcome back" when there is no name.
    private var header: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(homeHeaderDate()).font(.subheadline).foregroundStyle(.secondary)
            Text(greeting.map { "Hi, \($0)" } ?? "Welcome back")
                .font(.largeTitle.bold()).accessibilityAddTraits(.isHeader)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// The donor's monthly gift at a glance (G-7..G-9). It reads the same `GivingModel` as the Giving tab's
/// gift screen, so a cancel or change shows here the moment it succeeds.
private struct GiftSummaryCard: View {
    let model: GivingModel
    /// Tapping the row switches to the Giving tab.
    var onOpen: () -> Void = {}

    var body: some View {
        Button(action: onOpen) {
            DADCard {
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Text("Your monthly gift").font(.headline).accessibilityAddTraits(.isHeader)
                        Spacer(minLength: 0)
                        Image(systemName: "chevron.right").font(.footnote).foregroundStyle(.secondary).accessibilityHidden(true)
                    }
                    // Equal-weight framing when a gift exists (G-7..G-9); the server detail line keeps
                    // the `gift-summary` id/text UITests assert.
                    if let framing { DADGiftFraming(monthly: framing.monthly, daily: framing.daily) }
                    Text(summary).font(.footnote).accessibilityIdentifier("gift-summary")
                }
            }
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .contain).accessibilityIdentifier("gift-summary-card")
    }

    /// The monthly/daily pair shown with equal weight, when the active amount maps to the daily rule.
    private var framing: (monthly: String, daily: String)? {
        guard model.hasLoaded, let minor = model.recurring.amountMinor,
              let amount = GiftAmount(monthlyMinor: minor) else { return nil }
        return ("\(formatUSDMinor(minor))/month", "$\(amount.dailyDollars) a day")
    }

    private var summary: String {
        guard model.hasLoaded else {
            if case .failed = model.phase { return "Your gift isn’t available right now." }
            return "Loading your gift…"
        }
        func date(_ d: Date) -> String { d.formatted(date: .long, time: .omitted) }
        switch model.recurring {
        case .none: return "No monthly gift yet."
        case .preparing: return "Getting your first gift ready."
        case let .active(_, amount, periodEnd): return "\(formatUSDMinor(amount))/month · renews \(date(model.offer?.effectiveAt ?? periodEnd))"
        case let .ending(_, amount, _, stopsAt): return "\(formatUSDMinor(amount))/month · ends \(date(stopsAt)), no further renewals"
        }
    }
}

private struct DashboardCards: View {
    let dashboard: DonorDashboard
    /// At-risk "Update payment" switches to the Giving tab.
    var onUpdatePayment: () -> Void = {}
    @ScaledMetric(relativeTo: .largeTitle) private var streakSize: CGFloat = 44
    /// The milestone last acknowledged on this device, so a newly crossed milestone shows the
    /// inline card once (NOT a modal) and fires the success haptic only on first sight.
    @AppStorage("dad.lastSeenMilestone") private var lastSeenMilestone = 0
    @State private var milestoneDismissed = false

    /// The milestone the streak has crossed but this device hasn't acknowledged yet, if any.
    private var newMilestone: Int? {
        guard let reached = dashboard.streak?.ladder?.lastMilestone, reached > 0, reached > lastSeenMilestone,
              !milestoneDismissed else { return nil }
        return reached
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            if let streak = dashboard.streak, streak.atRisk { atRiskBanner(streak) }
            if let reached = newMilestone { milestoneCard(reached) }
            streak
            referralTiles
            impact
            if let network = dashboard.network {
                DADCard {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Your network").font(.headline).accessibilityAddTraits(.isHeader)
                        Text("Together your network funds \(formatUSDMinor(network.annualizedMinor)) a year")
                            .accessibilityIdentifier("network-annualized")
                        Text("\(network.activeCount) active \(network.activeCount == 1 ? "donor" : "donors")")
                            .font(.footnote).foregroundStyle(.secondary)
                        if let referrals = dashboard.referrals {
                            Text("\(referrals.joined) joined through you · \(referrals.totalLabel) given")
                                .font(.footnote).foregroundStyle(.secondary)
                        }
                    }
                }.accessibilityElement(children: .contain).accessibilityIdentifier("network-card")
            }
        }
    }

    /// S-1 at-risk: a warn/warn-wash card with an SF Symbol (not emoji) and the Giving-tab action.
    @ViewBuilder private func atRiskBanner(_ streak: StreakCard) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Label {
                Text(streak.graceEndsAt.map { "A renewal didn’t go through. Update your payment by \($0.formatted(date: .long, time: .omitted)) to keep your streak." }
                     ?? "A renewal didn’t go through. Update your payment to keep your streak.")
            } icon: {
                Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(Color.dad("warn")).accessibilityHidden(true)
            }
            .font(.footnote).accessibilityIdentifier("streak-at-risk")
            Button("Update payment", action: onUpdatePayment)
                .buttonStyle(DADButtonStyle(.secondary, fillsWidth: false)).accessibilityIdentifier("at-risk-update")
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.dadSpace("5"))
        .background(Color.dad("warn-wash"))
        .foregroundStyle(Color.dad("ink"))
        .clipShape(RoundedRectangle(cornerRadius: .dadRadius("card"), style: .continuous))
        .accessibilityElement(children: .contain).accessibilityIdentifier("at-risk-banner")
    }

    /// Milestone-reached (streak crossed a milestone since last launch): a dismissible inline card with
    /// a share action — NOT a modal. First sight also fires the success haptic.
    @ViewBuilder private func milestoneCard(_ reached: Int) -> some View {
        let message = "\(reached) days. That’s a month of aid, on the record."
        DADCard {
            VStack(alignment: .leading, spacing: 10) {
                HStack(alignment: .top) {
                    Label("Milestone reached", systemImage: "flag.checkered")
                        .font(.footnote.weight(.semibold)).accessibilityAddTraits(.isHeader)
                    Spacer(minLength: 0)
                    Button {
                        lastSeenMilestone = reached
                        milestoneDismissed = true
                    } label: { Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary) }
                    .buttonStyle(.plain).accessibilityLabel("Dismiss")
                }
                Text(message).font(.headline)
                ShareLink(item: message) {
                    Label("Share", systemImage: "square.and.arrow.up")
                }.buttonStyle(DADButtonStyle(.secondary, fillsWidth: false))
            }
        }
        .accessibilityElement(children: .contain).accessibilityIdentifier("milestone-card")
        .sensoryFeedback(.success, trigger: reached)
    }

    /// Link | IRL referral counts, equal weight. Unknown stays unknown (nil → "—", never 0); a real 0
    /// reads muted with the "show your code in person" hint.
    @ViewBuilder private var referralTiles: some View {
        let referrals = dashboard.referrals
        HStack(alignment: .top, spacing: .dadSpace("3")) {
            DADStatTile(title: "Link", value: referrals.map { "\($0.link)" },
                        caption: referrals?.link == 0 ? "Share your invite link" : nil)
            DADStatTile(title: "IRL", value: referrals.map { "\($0.irl)" },
                        caption: referrals?.irl == 0 ? "Show your code in person" : nil)
        }
    }

    /// The streak hero on ink: day count in the display face, teal 30-day bar, milestone + rank, and the
    /// single Founding Donor mention on this screen.
    @ViewBuilder private var streak: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Giving streak").font(.caption).textCase(.uppercase).foregroundStyle(Color.dad("dkmut"))
            if let streak = dashboard.streak {
                Text("\(streak.current)").font(.dadDisplay(.largeTitle, size: streakSize))
                    .accessibilityIdentifier("streak-count").accessibilityLabel(streak.headline)
                Text("\(streak.current == 1 ? "day" : "days")").font(.footnote).foregroundStyle(Color.dad("dkmut"))
                if let ladder = streak.ladder {
                    let filled = ladder.bar.filter { $0 }.count
                    DADStreakBar(filled: filled, total: max(ladder.bar.count, 1))
                    if let next = ladder.nextLabel {
                        Text(next).font(.footnote).foregroundStyle(Color.dad("dkmut")).accessibilityIdentifier("streak-next")
                    }
                }
            } else {
                // The server says the figure is not known: say so rather than show a zero streak.
                Text("Your streak isn’t available right now.").font(.headline).accessibilityIdentifier("streak-unknown")
            }
            rankLine
            if dashboard.foundingDonor {
                Label("Founding donor", systemImage: "star.fill").font(.footnote.weight(.semibold))
                    .padding(.horizontal, .dadSpace("3")).padding(.vertical, .dadSpace("1"))
                    .background(Color.dad("ok-ink"), in: Capsule())
                    .foregroundStyle(Color.dad("paper"))
                    .accessibilityIdentifier("founding-donor")
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.dadSpace("5"))
        .background(Color.dad("ink"))
        .foregroundStyle(Color.dad("paper"))
        .clipShape(RoundedRectangle(cornerRadius: .dadRadius("card"), style: .continuous))
        .accessibilityElement(children: .contain).accessibilityIdentifier("streak-card")
    }

    @ViewBuilder private var rankLine: some View {
        switch dashboard.rank {
        case .ranked(let rank):
            Text(rank.nationalLabel).font(.subheadline.weight(.semibold)).accessibilityIdentifier("rank-national")
            if let city = rank.cityLabel { Text(city).font(.footnote).foregroundStyle(Color.dad("dkmut")) }
        case .notRankedYet:
            Text("Not ranked yet.").font(.footnote).foregroundStyle(Color.dad("dkmut")).accessibilityIdentifier("rank-unranked")
        case .optedOut:
            EmptyView()   // S-4: a hidden donor shows no rank line at all
        }
    }

    private var impact: some View {
        DADCard {
            VStack(alignment: .leading, spacing: 6) {
                Text("Total given").font(.footnote).foregroundStyle(.secondary)
                Text(dashboard.impact.givenLabel).font(.title.bold()).accessibilityIdentifier("dash-given")
                Text("\(dashboard.impact.initiativesFunded) \(dashboard.impact.initiativesFunded == 1 ? "initiative" : "initiatives") funded · \(dashboard.impact.eventsVolunteered) \(dashboard.impact.eventsVolunteered == 1 ? "event" : "events") volunteered")
                    .font(.footnote).foregroundStyle(.secondary)
            }
        }.accessibilityElement(children: .contain).accessibilityIdentifier("impact-card")
    }
}

private struct InitiativeCard: View {
    let phase: DashboardModel.InitiativePhase
    let onRetry: () -> Void
    /// A-3: builds the push route for the initiative's spend by category; nil when engagement is not wired.
    var spendRoute: ((String, String) -> SpendRoute)?

    var body: some View {
        DADCard {
            VStack(alignment: .leading, spacing: 8) {
                Text("Today your $1 funded").font(.headline).accessibilityAddTraits(.isHeader)
                switch phase {
                case .loading:
                    ProgressView().accessibilityIdentifier("initiative-loading")
                case .none:
                    Text("Nothing is in today’s rotation yet. Check back tomorrow.").font(.footnote)
                        .accessibilityIdentifier("initiative-none")
                case .failed:
                    Text("Today’s initiative isn’t available right now.").font(.footnote).accessibilityIdentifier("initiative-error")
                    Button("Try again", action: onRetry).buttonStyle(DADButtonStyle(.secondary)).accessibilityIdentifier("initiative-retry")
                case .ready(let initiative):
                    Text(initiative.title).font(.title3.bold()).accessibilityIdentifier("initiative-title")
                    Text("\(initiative.location) · \(initiative.kind.capitalized) · Started \(friendlyDate(initiative.startedOn))")
                        .font(.footnote).foregroundStyle(.secondary)
                    if !initiative.summary.isEmpty { Text(initiative.summary) }
                    ForEach(initiative.headlineMetrics) { metric in
                        VStack(alignment: .leading, spacing: 0) {
                            Text(metric.valueLabel).font(.headline)
                            Text(metric.label).font(.caption).foregroundStyle(.secondary)
                        }
                        .accessibilityElement(children: .combine)
                    }
                    Text(TodayInitiative.attributionNote).font(.caption).foregroundStyle(.secondary)
                        .accessibilityIdentifier("initiative-note")
                    if let spendRoute {
                        NavigationLink(value: spendRoute(initiative.id, initiative.title)) {
                            Text("Where the money went ›")
                        }
                        .buttonStyle(DADButtonStyle(.secondary)).accessibilityIdentifier("open-spend")
                    }
                }
            }
        }.accessibilityElement(children: .contain).accessibilityIdentifier("initiative-card")
    }
}

/// Gift history (paged) with an inline gift record per row and the calendar-year total on top.
struct GiftHistoryScreen: View {
    @State private var model: GiftHistoryModel
    let onSignedOut: () -> Void
    @Environment(\.colorScheme) private var scheme

    init(service: any DashboardService, onSignedOut: @escaping () -> Void) {
        self.onSignedOut = onSignedOut
        _model = State(initialValue: GiftHistoryModel(service: service))
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Text("Gift history").font(.largeTitle.bold()).accessibilityAddTraits(.isHeader)
                if let summary = model.summary {
                    DADCard {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("\(String(summary.year)) total").font(.footnote).foregroundStyle(.secondary)
                            Text(summary.netLabel).font(.title2.bold()).accessibilityIdentifier("history-year-total")
                            Text("Sandbox records, not tax receipts.").font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
                content
            }
            .frame(maxWidth: 560, alignment: .leading).padding(28).frame(maxWidth: .infinity)
        }
        .modifier(HistoryBackground())
        .accessibilityElement(children: .contain).accessibilityIdentifier("history-screen")
        .task { await model.load() }
        .onDisappear { model.cancel() }
        .onChange(of: model.signedOut) { _, signedOut in if signedOut { onSignedOut() } }
    }

    @ViewBuilder private var content: some View {
        switch model.phase {
        case .loading:
            ProgressView().accessibilityIdentifier("history-loading")
        case .failed(let message):
            VStack(alignment: .leading, spacing: 12) {
                Text(message).accessibilityIdentifier("history-error")
                Button("Try again") { Task { await model.load() } }
                    .buttonStyle(DADButtonStyle(.primary)).accessibilityIdentifier("history-retry")
            }
        case .ready:
            if model.gifts.isEmpty {
                Text("No gifts yet. Once you give, each gift appears here.").accessibilityIdentifier("history-empty")
            } else {
                VStack(alignment: .leading, spacing: 12) {
                    ForEach(Array(model.gifts.enumerated()), id: \.element.id) { index, gift in
                        row(gift, index: index)
                    }
                }
                footer
            }
        }
    }

    @ViewBuilder private var footer: some View {
        if model.isLoadingMore { ProgressView().accessibilityIdentifier("history-more-loading") }
        if let error = model.moreError { Text(error).font(.footnote).foregroundStyle(Color.dad("fail")).accessibilityIdentifier("history-more-error") }
        if model.hasMore && !model.isLoadingMore {
            Button(model.moreError == nil ? "Load more" : "Try again") { model.requestMore() }
                .buttonStyle(DADButtonStyle(.secondary)).accessibilityIdentifier("history-more")
        }
        if model.reachedLimit {
            Text("Showing your \(GiftHistoryModel.maxRows) most recent gifts.").font(.footnote).foregroundStyle(.secondary)
                .accessibilityIdentifier("history-limit")
        }
    }

    @ViewBuilder private func row(_ gift: GiftEntry, index: Int) -> some View {
        let open = model.receipt?.giftID == gift.id
        VStack(alignment: .leading, spacing: 8) {
            Button {
                if open { model.hideReceipt() } else { Task { await model.showReceipt(giftID: gift.id) } }
            } label: {
                VStack(alignment: .leading, spacing: 2) {
                    Text(gift.paidAt.formatted(date: .abbreviated, time: .omitted)).font(.headline)
                    Text("\(gift.frequencyLabel) · \(gift.netLabel)").font(.subheadline)
                    if let refund = gift.refundLabel { Text(refund).font(.caption).foregroundStyle(.secondary) }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityHint(open ? "Hides the gift record" : "Shows the gift record")
            .accessibilityIdentifier("gift-row-\(index)")
            if open { receiptView }
            Divider()
        }
    }

    @ViewBuilder private var receiptView: some View {
        switch model.receipt {
        case .loading:
            ProgressView().accessibilityIdentifier("receipt-loading")
        case .failed(_, let message):
            Text(message).font(.footnote).foregroundStyle(Color.dad("fail")).accessibilityIdentifier("receipt-error")
        case .ready(let receipt):
            VStack(alignment: .leading, spacing: 4) {
                Text("Gift record").font(.subheadline.weight(.semibold))
                Text("Amount \(receipt.gift.amountLabel)")
                if receipt.gift.refundedMinor > 0 { Text("Refunded \(formatUSDMinor(receipt.gift.refundedMinor))") }
                Text("Net \(receipt.gift.netLabel)")
                ForEach(receipt.refunds) { refund in
                    Text("Refund \(formatUSDMinor(refund.amountMinor)) · \(refund.status.capitalized)").font(.caption).foregroundStyle(.secondary)
                }
                if !receipt.taxReceipt {
                    Text("This is a sandbox record, not a tax receipt.").font(.caption).foregroundStyle(.secondary)
                }
            }
            .padding(12).frame(maxWidth: .infinity, alignment: .leading)
            .background(scheme == .dark ? Color.dad("ink") : Color.dad("line").opacity(0.35), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            .accessibilityElement(children: .contain).accessibilityIdentifier("receipt-detail")
        case nil:
            EmptyView()
        }
    }
}

private struct HistoryBackground: ViewModifier {
    @Environment(\.colorScheme) private var scheme
    func body(content: Content) -> some View {
        content.background(Color.dad(scheme == .dark ? "ink-deep" : "paper")).tint(Color.dad("brand-ink"))
    }
}
