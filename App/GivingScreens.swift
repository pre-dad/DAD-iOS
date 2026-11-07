import SwiftUI
import SafariServices
import DADFoundation

// Giving screens (PRD G-1..G-11, D-5): the recurring gift, its amount, the payment method, and the
// cancel path. Bound to `GivingModel`. The app never handles card data: starting a gift and updating
// the card both open a page hosted outside the app (the system's secure Safari view), and when that
// page closes the model re-reads the server until it reflects the outcome.

/// What the giving screens need from the composition root.
struct GivingKit {
    let service: any GivingService
    /// DEBUG `--stub-backend` only: stands in for the hosted page finishing (the Stripe webhook).
    /// Always nil in a release build, which therefore always opens the real hosted page.
    var stubComplete: (@Sendable (HostedHandoff.Purpose) -> Void)?
    /// How long the model waits between re-reads after a hosted page closes.
    var pollDelay: Duration = .seconds(2)

    @MainActor func makeModel() -> GivingModel { GivingModel(service: service, pollDelay: pollDelay) }
}

/// The system's secure browser view, with a delegate so "Done" tells the model the page closed.
private struct SafariPage: UIViewControllerRepresentable {
    let url: URL
    let onFinish: () -> Void
    func makeCoordinator() -> Coordinator { Coordinator(onFinish: onFinish) }
    func makeUIViewController(context: Context) -> SFSafariViewController {
        let controller = SFSafariViewController(url: url)
        controller.delegate = context.coordinator
        return controller
    }
    func updateUIViewController(_ controller: SFSafariViewController, context: Context) {}

    @MainActor final class Coordinator: NSObject, @preconcurrency SFSafariViewControllerDelegate {
        let onFinish: () -> Void
        init(onFinish: @escaping () -> Void) { self.onFinish = onFinish }
        func safariViewControllerDidFinish(_ controller: SFSafariViewController) { onFinish() }
    }
}

#if DEBUG
/// Stands in for the Stripe-hosted page under `--stub-backend`, where `stub.invalid` cannot load.
private struct StubHostedPage: View {
    let purpose: HostedHandoff.Purpose
    let complete: @Sendable (HostedHandoff.Purpose) -> Void
    let onFinish: () -> Void
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Secure payment page").font(.largeTitle.bold()).accessibilityAddTraits(.isHeader)
            Text(purpose == .startGift ? "Pretend checkout for a monthly gift." : "Pretend card update.")
            Button("Complete payment") { complete(purpose); onFinish() }
                .buttonStyle(DADButtonStyle(.primary)).accessibilityIdentifier("stub-complete")
            Button("Close without paying") { onFinish() }
                .buttonStyle(DADButtonStyle(.secondary)).accessibilityIdentifier("stub-close")
        }
        .frame(maxWidth: 520, alignment: .leading).padding(28).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .dadBackground()
        .accessibilityElement(children: .contain).accessibilityIdentifier("hosted-page-stub")
    }
}
#endif

/// The hosted page, presented as a sheet. Closing it by any route (Done, swipe down) ends in `onFinish`.
struct HostedPageSheet: View {
    let handoff: HostedHandoff
    let stubComplete: (@Sendable (HostedHandoff.Purpose) -> Void)?
    let onFinish: () -> Void
    var body: some View {
        #if DEBUG
        if let stubComplete {
            StubHostedPage(purpose: handoff.purpose, complete: stubComplete, onFinish: onFinish)
        } else {
            SafariPage(url: handoff.url, onFinish: onFinish).ignoresSafeArea()
        }
        #else
        SafariPage(url: handoff.url, onFinish: onFinish).ignoresSafeArea()
        #endif
    }
}

private func shortDate(_ date: Date) -> String { date.formatted(date: .abbreviated, time: .omitted) }

/// Set / change your recurring gift (G-1/G-2/G-7), start one (D-5), update the card, or cancel (G-8/G-9).
struct GiftScreen: View {
    @State var model: GivingModel
    var stubComplete: (@Sendable (HostedHandoff.Purpose) -> Void)?
    var onSignedOut: () -> Void = {}
    /// "Invite someone" on the celebration screen switches to the Circle tab (set from the shell).
    var onInvite: () -> Void = {}
    /// The donor-home read seam, used only to learn whether this donor is a Founding Donor so the
    /// celebration can show the capsule when applicable (the flag lives on the dashboard, not on the
    /// giving service). nil in previews/when home reads aren't wired — the capsule then stays hidden.
    var foundingProvider: (any DashboardService)? = nil
    @State private var confirmingCancel = false
    @ScaledMetric(relativeTo: .largeTitle) private var amountSize: CGFloat = 44
    /// Show the one-time celebration after a FIRST gift is set up. Tracks that this screen
    /// started a gift (so a later amount-change never re-celebrates) and whether it's been shown.
    @State private var startedGift = false
    @State private var showCelebration = false
    /// Whether this donor is a Founding Donor, read once from the dashboard so the celebration can show
    /// the Founding capsule. Defaults to false, so a missing/failed read simply omits the capsule.
    @State private var founding = false

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            Text(model.recurring.heading(hasLoaded: model.hasLoaded))
                .font(.largeTitle.bold()).accessibilityAddTraits(.isHeader)
            if !model.hasLoaded {
                loadingOrFailed
            } else {
                loaded
            }
        }
        .frame(maxWidth: 520, alignment: .leading).padding(28).frame(maxWidth: .infinity)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("gift-screen")
        .task { await model.load() }
        // Read the Founding flag once from the dashboard so the first-gift celebration can show the
        // capsule when applicable. A failure leaves `founding` false (capsule hidden), never blocks giving.
        .task {
            guard let foundingProvider else { return }
            if case .ready(let dashboard) = try? await foundingProvider.dashboard() { founding = dashboard.foundingDonor }
        }
        .onChange(of: model.signedOut) { _, signedOut in if signedOut { onSignedOut() } }
        .sheet(isPresented: Binding(get: { model.handoff != nil }, set: { shown in
            if !shown { Task { await model.handoffFinished() } }
        })) {
            if let handoff = model.handoff {
                HostedPageSheet(handoff: handoff, stubComplete: stubComplete, onFinish: { Task { await model.handoffFinished() } })
            }
        }
        // Success haptic the moment a gift is set up or saved; warning when payment needs
        // attention. Triggers are published model state, so no number is animated.
        .sensoryFeedback(.success, trigger: model.recurring.subscriptionID)
        .sensoryFeedback(.warning, trigger: paymentNeedsAttention)
        // One-time celebration after a FIRST gift completes (not an amount change).
        .onChange(of: model.recurring.subscriptionID) { previous, current in
            if startedGift, previous == nil, current != nil { showCelebration = true }
        }
        .fullScreenCover(isPresented: $showCelebration) {
            CelebrationView(monthly: "\(formatUSDMinor(model.selection.monthlyMinor))/month",
                            daily: "$\(model.selection.dailyDollars) a day",
                            founding: founding,
                            onInvite: { showCelebration = false; onInvite() },
                            onDone: { showCelebration = false })
        }
    }

    /// True when the payment-method update is in a state the donor must act on (expired).
    private var paymentNeedsAttention: Bool { model.payment?.kind == .expired }

    @ViewBuilder private var loadingOrFailed: some View {
        if case .failed(let message) = model.phase {
            VStack(alignment: .leading, spacing: 12) {
                Text(message).accessibilityIdentifier("gift-error")
                Button("Try again") { Task { await model.load() } }
                    .buttonStyle(DADButtonStyle(.primary)).accessibilityIdentifier("gift-retry")
            }
        } else {
            ProgressView("Loading your gift…").accessibilityIdentifier("gift-loading")
        }
    }

    @ViewBuilder private var loaded: some View {
        status
        if case .active = model.recurring { changeSection }
        if case .none = model.recurring { startSection }
        if model.recurring.subscriptionID != nil { paymentSection }
        feedback
        if case .active = model.recurring { cancelSection }
    }

    // MARK: status

    @ViewBuilder private var status: some View {
        switch model.recurring {
        case .none:
            DADCard {
                VStack(alignment: .leading, spacing: 12) {
                    Text("You don’t have a monthly gift yet.").font(.headline).accessibilityIdentifier("gift-none")
                    Text("You’ll finish on a secure page hosted by our payment provider. This app never handles your card details.")
                        .font(.footnote).foregroundStyle(.secondary)
                }
            }
        case .preparing:
            DADCard {
                VStack(alignment: .leading, spacing: 12) {
                    Text("We’re getting your first gift ready.").font(.headline)
                    Text("It can take a moment after checkout. Refresh to check again.").font(.footnote).foregroundStyle(.secondary)
                    Button("Refresh") { Task { await model.load() } }
                        .buttonStyle(DADButtonStyle(.secondary)).disabled(model.isBusy).accessibilityIdentifier("gift-refresh")
                }
            }.accessibilityElement(children: .contain).accessibilityIdentifier("gift-preparing")
        case .active, .ending:
            DADCard {
                VStack(alignment: .leading, spacing: 6) {
                    Text("\(formatUSDMinor(model.recurring.amountMinor ?? 0))/month").font(.title2.bold())
                        .accessibilityIdentifier("gift-monthly")
                    renewalLines
                }
            }.accessibilityElement(children: .contain).accessibilityIdentifier("gift-status")
        }
    }

    @ViewBuilder private var renewalLines: some View {
        switch model.recurring {
        case let .active(_, amount, periodEnd):
            if let pending = model.offer?.pending {
                Text("Changing to \(formatUSDMinor(pending.amountMinor))/month from \(shortDate(pending.effectiveAt))\(pending.confirmed ? "" : ", awaiting confirmation").")
                    .font(.footnote).foregroundStyle(.secondary).accessibilityIdentifier("gift-pending-change")
            } else if let next = model.offer?.nextAmountMinor, next != amount {
                Text("Your next renewal will be \(formatUSDMinor(next)) on \(shortDate(model.offer?.effectiveAt ?? periodEnd)).")
                    .font(.footnote).foregroundStyle(.secondary).accessibilityIdentifier("gift-renewal")
            } else {
                Text("Renews \(shortDate(model.offer?.effectiveAt ?? periodEnd)).")
                    .font(.footnote).foregroundStyle(.secondary).accessibilityIdentifier("gift-renewal")
            }
        case let .ending(_, _, _, stopsAt):
            Text("Your gift won’t renew — it stays active until \(shortDate(stopsAt)).")
                .font(.footnote).foregroundStyle(.secondary).accessibilityIdentifier("gift-ending")
        default: EmptyView()
        }
    }

    // MARK: amount

    /// Pick the daily amount, then start the gift: the chosen amount is what checkout is created for.
    private var startSection: some View {
        VStack(alignment: .leading, spacing: 16) {
            amountCard
            Button("Start · \(formatUSDMinor(model.selection.monthlyMinor))/month") { startedGift = true; Task { await model.startGift() } }
                .buttonStyle(DADButtonStyle(.primary)).disabled(model.isBusy).accessibilityIdentifier("start-gift")
        }
    }

    private var changeSection: some View {
        VStack(alignment: .leading, spacing: 16) {
            amountCard
            Button("Save · \(formatUSDMinor(model.selection.monthlyMinor))/month") { Task { await model.applySelection() } }
                .buttonStyle(DADButtonStyle(.primary))
                .disabled(model.isBusy)
                .accessibilityIdentifier("save-gift")
        }
    }

    /// The $1 / $3 / $5 / Other amount picker. The three presets are a radio row (the selected option
    /// carries `.isSelected` for VoiceOver); "Other" reveals a ± stepper for any $1–$30/day.
    @State private var otherExpanded = false

    private var amountCard: some View {
        DADCard {
            VStack(alignment: .leading, spacing: 16) {
                HStack(spacing: 8) {
                    ForEach([1, 3, 5], id: \.self) { dollars in
                        amountChip(dollars)
                    }
                    otherChip
                }
                if showsStepper { stepperControls }
                // "You'll give" with equal-weight framing and the effective date. The daily readout
                // carries the gift-daily id UITests assert ("$3/day"); shown as the amount headline.
                VStack(alignment: .leading, spacing: 6) {
                    Text("You’ll give").font(.footnote).foregroundStyle(.secondary)
                    Text(model.selection.dailyLabel).font(.system(size: amountSize, weight: .bold))
                        .accessibilityIdentifier("gift-daily")
                    DADGiftFraming(monthly: "\(formatUSDMinor(model.selection.monthlyMinor))/month",
                                   daily: "$\(model.selection.dailyDollars) a day")
                    Text(effectiveLine).font(.footnote).foregroundStyle(.secondary)
                }
            }
        }
    }

    /// Whether the ± stepper is shown: when "Other" is chosen, or the current amount isn't a preset.
    private var showsStepper: Bool { otherExpanded || ![1, 3, 5].contains(model.selection.dailyDollars) }

    /// A preset radio chip. Selection is shown with a checkmark + bolder fill (not colour alone) and
    /// the `.isSelected` VoiceOver trait; never `.primary`, so the Start/Save button stays the lone CTA.
    private func amountChip(_ dollars: Int) -> some View {
        let selected = !showsStepper && model.selection.dailyDollars == dollars
        return Button { otherExpanded = false; model.setDaily(dollars) } label: {
            Label("$\(dollars)", systemImage: selected ? "largecircle.fill.circle" : "circle")
                .labelStyle(.titleAndIcon)
        }
        .buttonStyle(DADButtonStyle(selected ? .secondary : .tertiary, fillsWidth: false))
        .disabled(model.isBusy)
        .accessibilityAddTraits(selected ? .isSelected : [])
        .accessibilityIdentifier("amount-\(dollars)")
    }

    private var otherChip: some View {
        Button { otherExpanded = true } label: {
            Label("Other", systemImage: showsStepper ? "largecircle.fill.circle" : "circle")
                .labelStyle(.titleAndIcon)
        }
        .buttonStyle(DADButtonStyle(showsStepper ? .secondary : .tertiary, fillsWidth: false))
        .disabled(model.isBusy)
        .accessibilityAddTraits(showsStepper ? .isSelected : [])
        .accessibilityIdentifier("amount-other")
    }

    private var stepperControls: some View {
        HStack(spacing: 16) {
            Button { model.decrement() } label: { Image(systemName: "minus.circle.fill").font(.title) }
                .buttonStyle(.plain)
                .accessibilityLabel("Decrease gift")
                .disabled(model.selection.dailyDollars <= GiftAmount.minDailyDollars || model.isBusy)
            Text(model.selection.dailyLabel).font(.title3.weight(.semibold)).monospacedDigit()
            Button { model.increment() } label: { Image(systemName: "plus.circle.fill").font(.title) }
                .buttonStyle(.plain)
                .accessibilityLabel("Increase gift")
                .disabled(model.selection.dailyDollars >= GiftAmount.maxDailyDollars || model.isBusy)
        }
    }

    private var effectiveLine: String {
        if let effective = model.offer?.effectiveAt {
            return "Starts \(effective.formatted(date: .long, time: .omitted))."
        }
        return "Charged monthly."
    }

    // MARK: payment method

    private var paymentSection: some View {
        VStack(spacing: 12) {
            DADCard {
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Text("Payment method").font(.headline).accessibilityAddTraits(.isHeader)
                        Spacer(minLength: 0)
                    }
                    Text(paymentLine).font(.footnote).foregroundStyle(.secondary).accessibilityIdentifier("payment-status")
                    if case .active = model.recurring {
                        Button {
                            Task { await model.updatePayment() }
                        } label: {
                            HStack { Text("Update payment method"); Spacer(minLength: 0); Image(systemName: "chevron.right").font(.footnote).accessibilityHidden(true) }
                        }
                        .buttonStyle(DADButtonStyle(.secondary)).disabled(model.isBusy).accessibilityIdentifier("update-payment")
                    }
                }
            }.accessibilityElement(children: .contain).accessibilityIdentifier("payment-card")
            // Gift history is a push on the Giving tab's NavigationStack (registered in Shell.swift).
            NavigationLink(value: GiftRoute.history) {
                HStack { Text("Gift history"); Spacer(minLength: 0); Image(systemName: "chevron.right").font(.footnote).accessibilityHidden(true) }
            }
            .buttonStyle(DADButtonStyle(.secondary)).accessibilityIdentifier("giving-history")
        }
    }

    private var paymentLine: String {
        guard let payment = model.payment else { return "Update your card on a secure page hosted by our payment provider." }
        switch payment.kind {
        case .none: return "Update your card on a secure page hosted by our payment provider."
        case .pending, .open: return "A card update is in progress."
        case .applied: return payment.completedAt.map { "Card updated \(shortDate($0))." } ?? "Card updated."
        case .expired: return "The last card update expired. You can start again."
        case .cancelled: return "The last card update was cancelled. Your card is unchanged."
        }
    }

    // MARK: feedback + cancel

    @ViewBuilder private var feedback: some View {
        if model.isConfirming {
            ProgressView("Confirming with the payment provider…").accessibilityIdentifier("gift-confirming")
        }
        if let notice = model.notice {
            Text(notice).font(.footnote).accessibilityIdentifier("gift-notice")
        }
        if case .failed(let message) = model.phase {
            Text(message).font(.footnote).foregroundStyle(Color.dad("fail")).accessibilityIdentifier("gift-failure")
        }
    }

    @ViewBuilder private var cancelSection: some View {
        if confirmingCancel {
            // Inline confirmation rather than a `confirmationDialog`: the OS action sheet presents in a
            // separate layer whose buttons the simulator's XCUITest harness surfaces unreliably, so an
            // inline block is both deterministic to test and keeps the ends-streak copy beside the choice.
            VStack(alignment: .leading, spacing: 12) {
                Text("Cancel your gift?").font(.headline)
                if case let .active(_, _, periodEnd) = model.recurring {
                    Text(CancelCopy.confirmation(periodEnd: periodEnd)).font(.footnote).foregroundStyle(.secondary)
                }
                Button("End my gift") { confirmingCancel = false; Task { await model.cancel() } }
                    .buttonStyle(DADButtonStyle(.secondary)).disabled(model.isBusy)
                Button("Keep giving") { confirmingCancel = false }
                    .buttonStyle(DADButtonStyle(.primary))
            }
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("cancel-confirm")
        } else {
            Button("Cancel gift") { confirmingCancel = true }
                .buttonStyle(DADButtonStyle(.destructive)).disabled(model.isBusy)
        }
    }
}

/// The gift screen presented as a sheet from the donor home or from Settings (cancel-before-delete).
struct GiftSheet: View {
    let model: GivingModel
    let stubComplete: (@Sendable (HostedHandoff.Purpose) -> Void)?
    let onClose: () -> Void
    let onSignedOut: () -> Void
    var body: some View {
        NavigationStack {
            ScrollView {
                GiftScreen(model: model, stubComplete: stubComplete, onSignedOut: onSignedOut)
            }
            .dadBackground()
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done", action: onClose).accessibilityIdentifier("gift-close")
                }
            }
        }
    }
}
