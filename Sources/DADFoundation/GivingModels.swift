import Foundation

// Giving view models + the service seam. The models own explicit state machines driven
// through `GivingService`, so the set-gift / change-amount / cancel flows are unit-tested
// without a network, exactly like the auth models.

/// The payment path resolved for this build. The §10 / Risk-1 decision is "support both":
/// in-app Apple Pay only once DAD is an Apple-approved nonprofit, otherwise hand off to the
/// Stripe web checkout. The app never handles card data: the first charge is backend-driven
/// after the hosted page finishes, so this only decides which affordance the screen presents.
public enum PaymentPath: Sendable, Equatable {
    /// Open the hosted Stripe checkout / setup page in the system's secure browser view.
    case webCheckoutHandoff(URL)
    /// Present the in-app Apple Pay setup sheet (gated behind nonprofit approval).
    case applePay
    /// A payment update that finished before a new one could begin; nothing to open.
    case alreadyFinished(PaymentMethodState)
}

/// The seam the giving models call. A conformer maps to the generated client (`WireGiving`) or
/// to a preview/test double. Everything is value types so the models stay testable.
public protocol GivingService: Sendable {
    /// Current recurring gift (or `.none`).
    func recurring() async throws -> RecurringState
    /// What the next renewal charges and any queued amount change; nil when the server cannot say.
    func amountOffer() async throws -> AmountOffer?
    /// Change the monthly amount of an existing subscription; returns the resulting state.
    func changeAmount(subscriptionID: String, to amountMinor: Int) async throws -> RecurringState
    /// Cancel at period end; returns the resulting (`.ending`) state.
    func cancel(subscriptionID: String, periodEnd: Date) async throws -> RecurringState
    /// Where the hosted payment-method update stands.
    func paymentMethod() async throws -> PaymentMethodState
    /// Begin a payment-method update; returns which path to present.
    func beginPayment() async throws -> PaymentPath
    /// Begin a new gift of `amountMinor` (integer cents a month) through the hosted checkout.
    func beginGift(amountMinor: Int) async throws -> PaymentPath
}

/// A hosted page the app has been asked to show (Stripe-hosted card setup, or the website's
/// Stripe Checkout page). The app only opens it; it never sees card data.
public struct HostedHandoff: Sendable, Equatable, Identifiable {
    public enum Purpose: Sendable, Equatable { case startGift, updatePayment }
    public let id = UUID()
    public let url: URL
    public let purpose: Purpose
}

/// Drives the giving screen. Holds a selected daily amount and the known recurring state, and
/// exposes the operations the screen can perform with explicit phases so the UI never has to
/// infer "is a request in flight". Re-entrant calls while a request is in flight are ignored
/// (double-tap guard); a cancelled request keeps the prior state rather than erroring.
@MainActor
@Observable
public final class GivingModel {
    public enum Phase: Sendable, Equatable {
        case idle
        case working
        case failed(String)
    }

    public private(set) var recurring: RecurringState = .none
    public private(set) var phase: Phase = .idle
    /// The daily amount the stepper/slider currently shows. Starts at the active amount when
    /// one exists, else the $1/day floor.
    public private(set) var selection: GiftAmount
    public private(set) var offer: AmountOffer?
    public private(set) var payment: PaymentMethodState?
    /// Set when a hosted page should be shown; the screen clears it through `handoffFinished()`.
    public private(set) var handoff: HostedHandoff?
    /// A non-error line the screen shows (saved, cancelled, still confirming...).
    public private(set) var notice: String?
    /// The first read completed, so the screen can tell "loading" from "loaded, then a command failed".
    public private(set) var hasLoaded = false
    /// After a hosted page closes the model polls until the server reflects the outcome.
    public private(set) var isConfirming = false
    /// The server rejected the session; the screen leaves for sign-in.
    public private(set) var signedOut = false

    private let service: any GivingService
    private let pollAttempts: Int
    private let pollDelay: Duration

    public init(service: any GivingService, initial: GiftAmount = .minimum,
                pollAttempts: Int = 5, pollDelay: Duration = .seconds(2)) {
        self.service = service
        self.selection = initial
        self.pollAttempts = max(pollAttempts, 1)
        self.pollDelay = pollDelay
    }

    /// True while a command or read is running; the screen disables its controls on this.
    public var isBusy: Bool { phase == .working || isConfirming }

    /// Clamp to the $1…$30 daily rule. Out-of-range requests are ignored at the edges rather
    /// than erroring, so the stepper simply stops.
    public func setDaily(_ dollars: Int) {
        guard let amount = GiftAmount(dailyDollars: max(dollars, GiftAmount.minDailyDollars)) else { return }
        selection = amount
    }

    public func increment() { setDaily(selection.dailyDollars + 1) }
    public func decrement() { setDaily(selection.dailyDollars - 1) }

    /// What the donor's next renewal will charge, in integer cents: a queued change wins over the
    /// subscription's own figure.
    public var currentAmountMinor: Int? { offer?.pending?.amountMinor ?? offer?.nextAmountMinor ?? recurring.amountMinor }

    public func dismissNotice() { notice = nil }

    /// Load the current recurring gift, the amount offer and the payment-method status, and sync
    /// the selection to the gift. The recurring read is the one that can fail the screen; the other
    /// two are supporting detail and fall back to "unknown".
    public func load() async {
        guard !isBusy else { return }
        phase = .working
        notice = nil
        do {
            recurring = try await service.recurring()
        } catch {
            await fail(error)
            return
        }
        await readSupporting()
        syncSelection()
        hasLoaded = true
        phase = .idle
    }

    /// Apply the current selection to the existing subscription (G-7). No-op with a clear
    /// failure when there is no subscription to change — the set-up-first case the UI gates on.
    public func applySelection() async {
        guard !isBusy else { return }
        guard let id = recurring.subscriptionID else {
            phase = .failed("Set up a gift before changing the amount.")
            return
        }
        guard !recurring.isEnding else {
            phase = .failed("Your gift is ending, so its amount can’t be changed.")
            return
        }
        if selection.monthlyMinor == currentAmountMinor {
            phase = .idle
            notice = "That’s already your gift amount."
            return
        }
        phase = .working
        notice = nil
        do {
            recurring = try await service.changeAmount(subscriptionID: id, to: selection.monthlyMinor)
        } catch {
            await fail(error, rereadOnConflict: true)
            return
        }
        await readSupporting()
        notice = "Saved. Your next renewal will be \(formatUSDMinor(currentAmountMinor ?? selection.monthlyMinor))."
        phase = .idle
    }

    /// Cancel at period end (G-8/G-9). Requires an active subscription with a known period end.
    public func cancel() async {
        guard !isBusy else { return }
        guard case let .active(id, _, periodEnd) = recurring else {
            phase = .failed("There’s no active gift to cancel.")
            return
        }
        phase = .working
        notice = nil
        do {
            recurring = try await service.cancel(subscriptionID: id, periodEnd: periodEnd)
        } catch {
            await fail(error, rereadOnConflict: true)
            return
        }
        await readSupporting()
        phase = .idle
    }

    /// Start a new gift through the hosted checkout (D-5). The screen shows `handoff` next.
    public func startGift() async {
        guard !isBusy else { return }
        guard case .none = recurring else {
            phase = .failed("You already have a gift.")
            return
        }
        let amount = selection.monthlyMinor
        await begin(.startGift) { try await self.service.beginGift(amountMinor: amount) }
    }

    /// Update the card through the hosted payment-method page.
    public func updatePayment() async {
        guard !isBusy else { return }
        guard recurring.subscriptionID != nil else {
            phase = .failed("Set up a gift before updating a payment method.")
            return
        }
        await begin(.updatePayment) { try await self.service.beginPayment() }
    }

    /// The hosted page was closed (finished, cancelled or dismissed): the app cannot tell which, so
    /// poll the server until it reflects the outcome, bounded, then say what it found.
    public func handoffFinished() async {
        guard let finished = handoff, !isConfirming else { return }
        handoff = nil
        isConfirming = true
        defer { isConfirming = false }
        notice = nil
        var settled = false
        for attempt in 0..<pollAttempts {
            if attempt > 0 {
                try? await Task.sleep(for: pollDelay)
                if Task.isCancelled { break }
            }
            guard await readAfterHandoff() else { break }
            switch finished.purpose {
            case .startGift: settled = recurring.subscriptionID != nil
            case .updatePayment: settled = payment.map { !$0.isInFlight } ?? false
            }
            if settled { break }
        }
        syncSelection()
        hasLoaded = true
        notice = Self.outcome(finished.purpose, settled: settled, recurring: recurring, payment: payment)
    }

    // MARK: - private

    private func begin(_ purpose: HostedHandoff.Purpose, _ open: () async throws -> PaymentPath) async {
        phase = .working
        notice = nil
        do {
            switch try await open() {
            case .webCheckoutHandoff(let url):
                handoff = HostedHandoff(url: url, purpose: purpose)
            case .alreadyFinished(let state):
                payment = state
                notice = Self.outcome(.updatePayment, settled: true, recurring: recurring, payment: state)
            case .applePay:
                phase = .failed("Apple Pay isn’t available in this build yet.")
                return
            }
            phase = .idle
        } catch {
            if purpose == .startGift, case AccountError.conflict = error {
                // A gift or an open checkout already exists (or the key was used for another amount): pull
                // the server's truth in and say so.
                await fail(error, rereadOnConflict: true)
                phase = .failed("You already have a monthly gift or a checkout in progress. We’ve refreshed it; please review.")
            } else if purpose == .startGift, case AccountError.paymentsUnavailable = error {
                phase = .failed("Giving isn’t available right now. Please try again later.")
            } else {
                await fail(error)
            }
        }
    }

    /// One recurring + payment read during confirmation. False when the poll should stop
    /// (cancelled, or the session ended).
    private func readAfterHandoff() async -> Bool {
        do { recurring = try await service.recurring() }
        catch {
            if error.isCancellation { return false }
            if case AccountError.signedOut = error { signedOut = true; return false }
        }
        await readSupporting()
        return !signedOut
    }

    private func readSupporting() async {
        if recurring.subscriptionID != nil {
            do { offer = try await service.amountOffer() } catch { noteSoft(error) }
        } else {
            offer = nil
        }
        do { payment = try await service.paymentMethod() } catch { noteSoft(error) }
    }

    private func noteSoft(_ error: Error) {
        if case AccountError.signedOut = error { signedOut = true }
    }

    private func syncSelection() {
        if let minor = currentAmountMinor, let amount = GiftAmount(monthlyMinor: minor) { selection = amount }
    }

    private func fail(_ error: Error, rereadOnConflict: Bool = false) async {
        if error.isCancellation { phase = .idle; return }   // abandoned, not failed: prior state stands
        if case AccountError.signedOut = error { signedOut = true }
        if rereadOnConflict, case AccountError.conflict = error {
            // Billing moved under the screen: pull the new truth in so the donor reviews current figures.
            if let fresh = try? await service.recurring() { recurring = fresh }
            await readSupporting()
            syncSelection()
        }
        phase = .failed(error.userMessage)
    }

    private static func outcome(_ purpose: HostedHandoff.Purpose, settled: Bool, recurring: RecurringState, payment: PaymentMethodState?) -> String {
        switch purpose {
        case .startGift:
            return settled ? "Your gift is set up." : "We haven’t seen a new gift yet. If you finished checkout, it can take a moment to appear."
        case .updatePayment:
            guard settled, let kind = payment?.kind else {
                return "We’re still waiting for the payment provider to confirm. Check back in a moment."
            }
            switch kind {
            case .applied: return "Your payment method was updated."
            case .cancelled: return "The payment update was cancelled. Your payment method is unchanged."
            case .expired: return "The payment update expired. Start again to update your payment method."
            case .none, .pending, .open: return "Your payment method is unchanged."
            }
        }
    }
}
