import SwiftUI
import DADFoundation
import UIKit

// Events (PRD E-1..E-10): the list, an in-place detail, reserve / waitlist / cancel, check-in (typed
// code or QR scan) and add-to-calendar through the system share sheet. Everything is inline in the
// view tree (no OS action sheets) so it is deterministic under XCUITest. Bound to `EventsModel` and
// `CheckInModel`; every server refusal has its own sentence, and state is always carried in text.

/// System share sheet for the exported `.ics` (E-6). The donor picks Calendar (or Files, Mail...);
/// the app never touches the calendar itself, so no calendar permission or entitlement is needed.
struct ShareSheet: UIViewControllerRepresentable {
    let url: URL
    let onDone: () -> Void
    func makeUIViewController(context: Context) -> UIActivityViewController {
        let controller = UIActivityViewController(activityItems: [url], applicationActivities: nil)
        controller.completionWithItemsHandler = { _, _, _, _ in onDone() }
        return controller
    }
    func updateUIViewController(_ controller: UIActivityViewController, context: Context) {}
}

struct EventsScreen: View {
    @State var model: EventsModel
    let service: any EventsService
    var onSignedOut: () -> Void = {}
    @State private var selected: String? = launchValue("--stub-event-detail")
    @State private var confirmingCancel: String?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                Text("Events").font(.largeTitle.bold()).accessibilityAddTraits(.isHeader)
                content
            }
            .frame(maxWidth: 560, alignment: .leading).padding(28).frame(maxWidth: .infinity)
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("events-home")
        }
        .modifier(AppBackground())
        .tint(Color.dad("brand-ink"))
        .task {
            await model.load()
            if launchFlag("--stub-auto-calendar"), let selected { await model.prepareCalendar(eventID: selected) }
        }
        .onChange(of: model.signedOut) { _, signedOut in if signedOut { onSignedOut() } }
        // Success haptic when a seat is reserved / waitlisted.
        .sensoryFeedback(.success, trigger: model.lastOutcome)
        .sheet(item: calendarBinding) { file in
            ShareSheet(url: file.url, onDone: { model.clearCalendar() }).ignoresSafeArea()
        }
    }

    private var calendarBinding: Binding<CalendarFile?> {
        Binding(get: { model.calendarFile }, set: { if $0 == nil { model.clearCalendar() } })
    }

    @ViewBuilder private var content: some View {
        switch model.phase {
        case .loading:
            ProgressView().accessibilityIdentifier("events-loading")
        case let .failed(message):
            VStack(alignment: .leading, spacing: 12) {
                Text(message).foregroundStyle(Color.dad("fail")).accessibilityIdentifier("events-error")
                Button("Try again") { Task { await model.load() } }
                    .buttonStyle(DADButtonStyle(.primary)).accessibilityIdentifier("events-retry")
            }
        case .ready:
            if let outcome = model.lastOutcome {
                DADCard {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(outcome.confirmationTitle).font(.headline).accessibilityIdentifier("reserve-confirm")
                        Text(outcome.confirmationDetail).font(.footnote).foregroundStyle(.secondary)
                        Button("Done") { model.clearOutcome() }.buttonStyle(DADButtonStyle(.secondary))
                    }
                }
            }
            if let id = selected, let event = model.event(id: id) {
                EventDetail(model: model, service: service, event: event, confirmingCancel: $confirmingCancel,
                            onBack: { selected = nil }, onSignedOut: onSignedOut)
            } else if model.sortedEvents.isEmpty {
                Text("No upcoming events near you yet. Check back soon.").accessibilityIdentifier("events-empty")
            } else {
                ForEach(model.sortedEvents) { event in row(event) }
            }
        }
    }

    @ViewBuilder private func row(_ event: DonorEvent) -> some View {
        DADCard {
            VStack(alignment: .leading, spacing: 6) {
                EventHeader(event: event)
                Text(EventTime.start(event)).font(.footnote).accessibilityIdentifier("time-\(event.id)")
                Text("\(event.venue) · \(event.city)").font(.footnote).foregroundStyle(.secondary)
                Text(event.spotsLabel).font(.caption).foregroundStyle(.secondary).accessibilityIdentifier("spots-\(event.id)")
                EventActions(model: model, event: event, confirmingCancel: $confirmingCancel)
                Button("Details") { selected = event.id }
                    .buttonStyle(DADButtonStyle(.secondary)).accessibilityIdentifier("details-\(event.id)")
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("event-\(event.id)")
    }
}

/// Title plus the type and invite-only markers (E-3, E-5).
private struct EventHeader: View {
    let event: DonorEvent
    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            Text(event.title).font(.headline).accessibilityAddTraits(.isHeader)
            if event.isInviteOnly {
                Text("Invite-only").font(.caption2).padding(.horizontal, 6).padding(.vertical, 2)
                    .background(Color.dad("brand-ink").opacity(0.12)).clipShape(Capsule())
                    .accessibilityIdentifier("invite-only-badge")
            }
        }
    }
}

/// The primary action for an event, derived from `DonorEvent.availability` (E-4, E-9), plus its inline
/// error. Shared by the list row and the detail so both behave identically.
private struct EventActions: View {
    let model: EventsModel
    let event: DonorEvent
    @Binding var confirmingCancel: String?
    /// Reserve is the single primary on the DETAIL screen; in a list row it's secondary.
    var isDetail: Bool = false

    var body: some View {
        let now = Date()
        VStack(alignment: .leading, spacing: 6) {
            switch event.availability(now: now) {
            case .reservable:
                Button("Reserve") { Task { await model.reserve(eventID: event.id) } }
                    .buttonStyle(DADButtonStyle(isDetail ? .primary : .secondary)).disabled(model.isBusy(event.id)).accessibilityIdentifier("reserve-\(event.id)")
            case .waitlistable:
                Button("Join waitlist") { Task { await model.reserve(eventID: event.id) } }
                    .buttonStyle(DADButtonStyle(.secondary)).disabled(model.isBusy(event.id)).accessibilityIdentifier("waitlist-\(event.id)")
            case .reserved, .waitlisted:
                held(now: now)
            case .checkedIn:
                Text(event.checkedInAt.map { "Checked in · \(EventTime.moment($0, in: event))" } ?? "Checked in")
                    .font(.subheadline.bold()).foregroundStyle(Color.dad("brand-ink")).accessibilityIdentifier("status-\(event.id)")
            case let .notYetOpen(opensAt):
                Text("Booking opens \(EventTime.moment(opensAt, in: event))")
                    .font(.footnote).foregroundStyle(.secondary).accessibilityIdentifier("not-open-\(event.id)")
            case .started:
                Text("This event has already started.").font(.footnote).foregroundStyle(.secondary)
            case .cancelled:
                Text("Cancelled").font(.footnote).foregroundStyle(Color.dad("fail"))
            }
            if event.earlyBooking, event.status == .none, event.bookingOpensAt != nil {
                Text("Early booking is open to you as a Team Captain.").font(.caption).foregroundStyle(.secondary)
            }
            if model.actionErrorEventID == event.id, let message = model.actionError {
                Text(message).font(.footnote).foregroundStyle(Color.dad("fail")).accessibilityIdentifier("event-error-\(event.id)")
            }
        }
    }

    @ViewBuilder private func held(now: Date) -> some View {
        Text(event.status == .waitlisted ? "On the waitlist" : "You’re going").font(.subheadline.bold())
            .accessibilityIdentifier("status-\(event.id)")
        if event.canCancel(now: now) {
            if confirmingCancel == event.id {
                VStack(alignment: .leading, spacing: 6) {
                    Text(event.status == .waitlisted ? "Leave the waitlist?" : "Cancel your reservation?").font(.subheadline)
                    HStack {
                        Button("Yes, cancel") { Task { await model.cancel(eventID: event.id) }; confirmingCancel = nil }
                            .buttonStyle(DADButtonStyle(.primary)).accessibilityIdentifier("confirm-cancel-\(event.id)")
                        Button("Keep it") { confirmingCancel = nil }.buttonStyle(DADButtonStyle(.secondary))
                    }
                }
                .accessibilityElement(children: .contain).accessibilityIdentifier("cancel-confirm-\(event.id)")
            } else {
                Button(event.status == .waitlisted ? "Leave waitlist" : "Cancel reservation") { confirmingCancel = event.id }
                    .buttonStyle(DADButtonStyle(.secondary)).disabled(model.isBusy(event.id)).accessibilityIdentifier("cancel-\(event.id)")
            }
        }
    }
}

private struct EventDetail: View {
    let model: EventsModel
    let service: any EventsService
    let event: DonorEvent
    @Binding var confirmingCancel: String?
    let onBack: () -> Void
    let onSignedOut: () -> Void
    @Environment(\.openURL) private var openURL

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Button("Back to events", action: onBack).buttonStyle(DADButtonStyle(.tertiary)).accessibilityIdentifier("events-back")
            DADCard {
                VStack(alignment: .leading, spacing: 8) {
                    EventHeader(event: event)
                    if !event.isInviteOnly { Text(event.typeLabel).font(.caption).foregroundStyle(.secondary) }
                    if let note = event.invitationNote {
                        Text(note).font(.footnote.weight(.semibold)).accessibilityIdentifier("invitation-note")
                    }
                    Text(EventTime.range(event)).font(.subheadline).accessibilityIdentifier("event-time")
                    Text(([event.venue, event.address, event.city].filter { !$0.isEmpty }).joined(separator: ", "))
                        .font(.footnote).foregroundStyle(.secondary)
                    if !event.details.isEmpty { Text(event.details).accessibilityIdentifier("event-description") }
                    Text(event.spotsLabel).font(.caption).foregroundStyle(.secondary).accessibilityIdentifier("spots-\(event.id)")
                    EventActions(model: model, event: event, confirmingCancel: $confirmingCancel, isDetail: true)
                }
            }.accessibilityElement(children: .contain).accessibilityIdentifier("event-detail-\(event.id)")
            if event.status == .reserved || event.status == .waitlisted || event.status == .checkedIn {
                CheckInPanel(model: CheckInModel(service: service), event: event, onSignedOut: onSignedOut,
                             onCheckedIn: { await model.reloadEvent(eventID: event.id) })
                    .id(event.id)
            }
            if !event.cancelled {
                Button(model.calendarPreparing == event.id ? "Preparing…" : "Add to calendar") {
                    Task { await model.prepareCalendar(eventID: event.id) }
                }
                .buttonStyle(DADButtonStyle(.secondary)).disabled(model.calendarPreparing != nil)
                .accessibilityIdentifier("add-calendar-\(event.id)")
            }
            if let report = event.reportIssueURL, let url = URL(string: report), url.scheme == "mailto" {
                Button("Report an issue with this event") { openURL(url) }
                    .buttonStyle(DADButtonStyle(.secondary)).accessibilityIdentifier("report-issue")
            }
        }
    }
}

/// Check-in (E-8): a typed code or a QR scan, offered only to a donor holding a seat. The window is the
/// contract's start..end; outside it the panel says when it opens or that it closed instead of sending
/// a request the server would refuse.
private struct CheckInPanel: View {
    @State var model: CheckInModel
    let event: DonorEvent
    let onSignedOut: () -> Void
    let onCheckedIn: () async -> Void
    @State private var code = ""
    @State private var scanning = false

    var body: some View {
        TimelineView(.periodic(from: .now, by: 20)) { context in
            panel(now: context.date)
        }
    }

    @ViewBuilder private func panel(now: Date) -> some View {
        DADCard {
            VStack(alignment: .leading, spacing: 8) {
                Text("Check in").font(.headline).accessibilityAddTraits(.isHeader)
                if event.status == .checkedIn, model.state == .idle {
                    Text(event.checkedInAt.map { "You’re checked in (\(EventTime.moment($0, in: event)))." } ?? "You’re checked in.")
                        .font(.subheadline.bold()).accessibilityIdentifier("checkin-result")
                } else if !event.canAttemptCheckIn && event.status != .checkedIn {
                    Text("Check-in is for reserved seats. You’re on the waitlist.").font(.footnote)
                        .accessibilityIdentifier("checkin-waitlisted")
                } else {
                    switch event.checkInWindow.state(now: now) {
                    case let .tooEarly(opensAt):
                        Text("Check-in opens \(EventTime.moment(opensAt, in: event)), when the event starts.")
                            .font(.footnote).accessibilityIdentifier("checkin-closed")
                    case .tooLate:
                        Text("Check-in for this event has closed.").font(.footnote).accessibilityIdentifier("checkin-closed")
                    case .open:
                        entry(now: now)
                    }
                    result
                }
            }
        }
        .accessibilityElement(children: .contain).accessibilityIdentifier("checkin-panel")
        .sheet(isPresented: $scanning) {
            QRScanSheet(onCode: { scanned in
                scanning = false
                code = scanned
                Task { await submit(scanned) }
            }, onClose: { scanning = false })
        }
    }

    /// Submit, then re-read the event so the list and detail show the server's `checked_in_at`.
    private func submit(_ value: String) async {
        await model.submit(code: value, window: event.checkInWindow, now: Date(), eventID: event.id)
        if model.signedOut { onSignedOut() }
        if case .success = model.state { await onCheckedIn() }
    }

    @ViewBuilder private func entry(now: Date) -> some View {
        Text("Scan the QR code shown at the venue, or type the code.").font(.footnote).foregroundStyle(.secondary)
        Button("Scan QR code") { scanning = true }
            .buttonStyle(DADButtonStyle(.secondary)).accessibilityIdentifier("checkin-scan")
        TextField("Check-in code", text: $code)
            .textInputAutocapitalization(.never).autocorrectionDisabled()
            .textFieldStyle(.roundedBorder).accessibilityIdentifier("checkin-code")
        Button(model.state == .checking ? "Checking in…" : "Check in") {
            Task { await submit(code) }
        }
        .buttonStyle(DADButtonStyle(.primary)).disabled(model.state == .checking || code.trimmingCharacters(in: .whitespaces).isEmpty)
        .accessibilityIdentifier("checkin-submit")
    }

    @ViewBuilder private var result: some View {
        switch model.state {
        case .idle, .checking:
            EmptyView()
        case let .success(already):
            Text(already ? "You were already checked in." : "You’re checked in. Thanks for showing up.")
                .font(.subheadline.bold()).accessibilityIdentifier("checkin-result")
        case let .outsideWindow(reason):
            Text(reason).font(.footnote).foregroundStyle(Color.dad("fail")).accessibilityIdentifier("checkin-result")
        case let .failed(message):
            Text(message).font(.footnote).foregroundStyle(Color.dad("fail")).accessibilityIdentifier("checkin-result")
        }
    }
}
