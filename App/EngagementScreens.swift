import CoreImage.CIFilterBuiltins
import PassKit
import SwiftUI
import UIKit
import DADFoundation

// Engagement (PRD A-3, I-*, K-*, N-*, R-*, B-*): impact totals, the 24-badge grid, the rankings choice, the
// referral network and the invite link / IRL code, plus the initiative spend drill-in. Bound to
// `EngagementModel` and `InitiativeSpendModel`. State is always carried in text as well as colour, a section
// the server did not answer says so instead of drawing a zero, and nothing here logs.

private struct EngagementBackground: ViewModifier {
    @Environment(\.colorScheme) private var scheme
    func body(content: Content) -> some View {
        content.background(Color.dad(scheme == .dark ? "ink-deep" : "paper")).tint(Color.dad("brand-ink"))
    }
}

/// A QR code drawn locally with CoreImage, scaled by `scale` so it stays sharp when shown with `.interpolation(.none)`.
func qrCodeImage(_ text: String, scale: CGFloat) -> UIImage? {
    let filter = CIFilter.qrCodeGenerator()
    filter.message = Data(text.utf8)
    filter.correctionLevel = "M"
    guard let output = filter.outputImage?.transformed(by: CGAffineTransform(scaleX: scale, y: scale)),
          let cgImage = CIContext().createCGImage(output, from: output.extent) else { return nil }
    return UIImage(cgImage: cgImage)
}

/// The unavailable-section line: one wording everywhere so a missing figure is never mistaken for none.
private func unavailableLine(_ what: String) -> some View {
    Text("\(what) can’t be shown right now.").font(.footnote).foregroundStyle(.secondary)
}

struct EngagementHome: View {
    @State var model: EngagementModel
    /// Adds the referral code to Apple Wallet; nil where Wallet is not wired (previews).
    @State var wallet: WalletPassModel? = nil
    var onSignedOut: () -> Void = {}
    @State private var showQR = false
    @Environment(AnalyticsController.self) private var analytics: AnalyticsController?
    @State private var copied = false
    @State private var nameDraft = ""
    /// Toggled when an invite is shared/copied, driving the success haptic.
    @State private var inviteShared = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                Text("Your impact").font(.largeTitle.bold()).accessibilityAddTraits(.isHeader)
                switch model.phase {
                case .loading:
                    ProgressView().accessibilityIdentifier("engagement-loading")
                case let .failed(message):
                    VStack(alignment: .leading, spacing: 12) {
                        Text(message).foregroundStyle(Color.dad("fail")).accessibilityIdentifier("engagement-error")
                        Button("Try again") { Task { await model.load() } }
                            .buttonStyle(DADButtonStyle(.primary)).accessibilityIdentifier("engagement-retry")
                    }
                case .ready:
                    if let notice = model.refreshNotice {
                        Text(notice).font(.footnote).foregroundStyle(Color.dad("fail")).accessibilityIdentifier("engagement-notice")
                    }
                    if let error = model.actionError {
                        Text(error).font(.footnote).foregroundStyle(Color.dad("fail"))
                            .accessibilityIdentifier("engagement-action-error")
                    }
                    if let snapshot = model.snapshot { content(snapshot) }
                }
            }
            .frame(maxWidth: 560, alignment: .leading).padding(28).frame(maxWidth: .infinity)
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("engagement-home")
        }
        .modifier(EngagementBackground())
        .task { await model.load() }
        .onChange(of: model.signedOut) { _, signedOut in if signedOut { onSignedOut() } }
        .sensoryFeedback(.success, trigger: inviteShared)
        .sheet(isPresented: $showQR) {
            if let url = model.snapshot?.referral?.irlURL() { InviteQRSheet(url: url, onClose: { showQR = false }) }
        }
    }

    @ViewBuilder private func content(_ snapshot: EngagementSnapshot) -> some View {
        impactCard(snapshot.impact)
        badges(snapshot.badges)
        rankings
        network(snapshot.network)
        invite(snapshot)
    }

    // MARK: impact (I-1, I-3)

    private func impactCard(_ impact: ImpactTotals?) -> some View {
        DADCard {
            VStack(alignment: .leading, spacing: 6) {
                Text("Lifetime given").font(.footnote).foregroundStyle(.secondary)
                if let impact {
                    Text(impact.givenLabel).font(.title.bold()).accessibilityIdentifier("impact-given")
                    Text("\(impact.initiativesFunded) \(impact.initiativesFunded == 1 ? "initiative" : "initiatives") · \(impact.eventsVolunteered) \(impact.eventsVolunteered == 1 ? "event" : "events")")
                        .font(.footnote).foregroundStyle(.secondary).accessibilityIdentifier("impact-counts")
                } else {
                    Text("—").font(.title.bold()).accessibilityLabel("Not available").accessibilityIdentifier("impact-given")
                    unavailableLine("Your impact")
                }
            }
        }
    }

    // MARK: badges (B-1..B-3), earned/locked in text never colour alone

    @ViewBuilder private func badges(_ collection: BadgeCollection?) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            if let collection {
                Text(collection.summaryLabel).font(.headline).accessibilityIdentifier("badge-summary")
                if collection.hasInviteOnlyAccess {
                    Text("You have invite-only event access.").font(.footnote).foregroundStyle(.secondary)
                        .accessibilityIdentifier("badge-invite-access")
                }
                // A grid of SF Symbols. Earned/unearned differ by SHAPE + LABEL (not colour
                // alone): earned shows a filled seal and "Earned"; unearned a lock and "Locked".
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 150), spacing: 12, alignment: .top)], alignment: .leading, spacing: 12) {
                    ForEach(collection.badges) { badge in
                        VStack(alignment: .leading, spacing: 4) {
                            HStack(spacing: 8) {
                                Image(systemName: badge.earned ? "checkmark.seal.fill" : "lock.fill")
                                    .foregroundStyle(badge.earned ? Color.dad("brand-ink") : .secondary)
                                Text(badge.earned ? "Earned" : "Locked").font(.caption.weight(.semibold))
                                    .foregroundStyle(.secondary)
                            }
                            Text(badge.shownTitle).fontWeight(badge.earned ? .semibold : .regular)
                            Text(badge.earned ? earnedLine(badge) : badge.rule).font(.caption).foregroundStyle(.secondary)
                            if badge.hasPerk {
                                Text("Perk: \(badge.perk)").font(.caption).foregroundStyle(.secondary)
                                    .accessibilityIdentifier("badge-perk-\(badge.code)")
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.dadSpace("3"))
                        .background(Color.dad("card-quiet"), in: RoundedRectangle(cornerRadius: .dadRadius("field"), style: .continuous))
                        .accessibilityElement(children: .ignore)
                        .accessibilityLabel(badge.accessibilitySummary)
                        .accessibilityIdentifier("badge-\(badge.code)")
                    }
                }
            } else {
                Text("Badges").font(.headline).accessibilityAddTraits(.isHeader)
                unavailableLine("Your badges")
            }
        }
    }

    private func earnedLine(_ badge: Badge) -> String {
        badge.earnedAt.map { "Earned \($0.formatted(date: .abbreviated, time: .omitted))" } ?? "Earned"
    }

    // MARK: rankings (K-1..K-3): opt-out hides the position entirely, never a name list

    private var rankings: some View {
        DADCard {
            VStack(alignment: .leading, spacing: 8) {
                Text("Rankings").font(.headline).accessibilityAddTraits(.isHeader)
                if let ranking = model.displayedRanking {
                    if ranking.isOptedOut {
                        Text("You’re not shown in rankings.").font(.footnote).foregroundStyle(.secondary)
                            .accessibilityIdentifier("ranking-optedout")
                    } else {
                        if let national = ranking.nationalLabel {
                            Text(national).accessibilityIdentifier("ranking-national")
                        } else if ranking.isNotRankedYet {
                            Text("Not ranked yet.").font(.footnote).foregroundStyle(.secondary)
                                .accessibilityIdentifier("ranking-unranked")
                        }
                        if let city = ranking.cityLabel {
                            Text(city).font(.footnote).foregroundStyle(.secondary).accessibilityIdentifier("ranking-city")
                        }
                    }
                    Button(ranking.isOptedOut ? "Show my ranking" : "Hide my ranking") {
                        Task { await model.setRankingOptIn(ranking.isOptedOut) }
                    }
                    .buttonStyle(DADButtonStyle(.secondary)).disabled(model.pendingOptIn != nil)
                    .accessibilityIdentifier("ranking-toggle")
                    Text("Only you see your position. Rankings never list other donors.").font(.caption).foregroundStyle(.secondary)
                } else {
                    unavailableLine("Your ranking")
                }
            }
        }
    }

    // MARK: network (N-1..N-3)

    @ViewBuilder private func network(_ network: NetworkSummary?) -> some View {
        DADCard {
            VStack(alignment: .leading, spacing: 6) {
                Text("Your network").font(.headline).accessibilityAddTraits(.isHeader)
                if let network {
                    Text("\(network.activeCount) active · \(network.annualizedLabel)").accessibilityIdentifier("network-active")
                    if let milestone = network.nextMilestone {
                        Text(milestone.progressLabel).font(.footnote).foregroundStyle(.secondary)
                            .accessibilityIdentifier("network-milestone")
                    }
                    ForEach(Array(network.invitees.enumerated()), id: \.offset) { index, invitee in
                        Text("\(invitee.name) · \(invitee.statusLabel)").font(.footnote)
                            .accessibilityIdentifier("network-invitee-\(index)")
                    }
                    if network.hasAnonymous {
                        Text("\(network.anonymousActive) \(network.anonymousActive == 1 ? "person chooses" : "people choose") to stay anonymous")
                            .font(.caption).foregroundStyle(.secondary).accessibilityIdentifier("network-anonymous")
                    }
                } else {
                    unavailableLine("Your network")
                }
            }
        }.accessibilityElement(children: .contain).accessibilityIdentifier("network-section")
    }

    // MARK: invite link + IRL code (R-1..R-4)

    /// A preview of what someone opening this donor's invite sees — the framing invitees get.
    @ViewBuilder private func invitePreview() -> some View {
        DADCard {
            VStack(alignment: .leading, spacing: 8) {
                Label("This is what your invite shows", systemImage: "person.crop.circle.badge.plus")
                    .font(.footnote.weight(.semibold)).foregroundStyle(.secondary)
                Text("You invited them to DAD").font(.headline)
                DADGiftFraming(monthly: "$30/month", daily: "$1 a day")
            }
        }.accessibilityElement(children: .contain).accessibilityIdentifier("invite-preview")
    }

    @ViewBuilder private func invite(_ snapshot: EngagementSnapshot) -> some View {
        if snapshot.referral != nil { invitePreview() }
        DADCard {
            VStack(alignment: .leading, spacing: 8) {
                Text("Invite friends").font(.headline).accessibilityAddTraits(.isHeader)
                if let referral = snapshot.referral {
                    Text("Your code: \(referral.code)").accessibilityIdentifier("referral-code")
                    if let total = referral.totalConverted {
                        Text("\(total) \(total == 1 ? "person has" : "people have") joined through you")
                            .font(.footnote).foregroundStyle(.secondary).accessibilityIdentifier("referral-total")
                    } else {
                        unavailableLine("Your referral count")
                    }
                    if let link = referral.inviteURL() {
                        VStack(spacing: 10) {
                            ShareLink(item: link, message: Text(referral.shareMessage())) {
                                Label("Share invite", systemImage: "square.and.arrow.up").frame(maxWidth: .infinity)
                            }.buttonStyle(DADButtonStyle(.primary)).accessibilityIdentifier("share-invite")
                                .simultaneousGesture(TapGesture().onEnded { inviteShared.toggle(); analytics?.emit(.inviteShared, properties: ["channel": "share_sheet"]) })
                            Button(copied ? "Copied" : "Copy link") {
                                UIPasteboard.general.string = link.absoluteString
                                copied = true
                                inviteShared.toggle()
                                analytics?.emit(.inviteShared, properties: ["channel": "copy"])
                            }.buttonStyle(DADButtonStyle(.secondary)).accessibilityIdentifier("copy-invite")
                            Button("Show QR") { showQR = true; analytics?.emit(.irlCodeShown) }
                                .buttonStyle(DADButtonStyle(.secondary)).accessibilityIdentifier("show-qr")
                            if let wallet { WalletPassButton(model: wallet) }
                        }
                        Text(link.absoluteString).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                            .accessibilityIdentifier("invite-link")
                    } else {
                        Text("Invite links aren’t available in this build.").font(.footnote).foregroundStyle(.secondary)
                            .accessibilityIdentifier("invite-unconfigured")
                    }
                    conversions(referral)
                } else if snapshot.needsPublicName {
                    namePrompt
                } else {
                    unavailableLine("Your invite link")
                }
            }
        }.accessibilityElement(children: .contain).accessibilityIdentifier("invite-section")
    }

    @ViewBuilder private func conversions(_ referral: ReferralInfo) -> some View {
        if let list = referral.conversions {
            if list.isEmpty {
                Text("No one has given through your link yet.").font(.footnote).foregroundStyle(.secondary)
                    .accessibilityIdentifier("conversions-empty")
            } else {
                Text("Recent first gifts").font(.subheadline.weight(.semibold))
                ForEach(Array(list.prefix(5).enumerated()), id: \.offset) { index, conversion in
                    Text("\(conversion.convertedAt.formatted(date: .abbreviated, time: .omitted)) · \(conversion.kind.label)")
                        .font(.footnote).accessibilityIdentifier("conversion-\(index)")
                }
                if list.count > 5 || referral.hasMoreConversions {
                    Text("Older first gifts aren’t listed here.").font(.caption).foregroundStyle(.secondary)
                }
            }
        } else {
            unavailableLine("Your recent first gifts")
        }
    }

    @ViewBuilder private var namePrompt: some View {
        Text("Choose the name your invite link goes out under. Friends see it when they open your link.").font(.footnote)
        TextField("Public name", text: $nameDraft)
            .textFieldStyle(.roundedBorder).textContentType(.name).textInputAutocapitalization(.words)
            .accessibilityLabel("Public name").accessibilityIdentifier("name-field")
        if let error = model.nameError {
            Text(error).font(.footnote).foregroundStyle(Color.dad("fail")).accessibilityIdentifier("name-error")
        }
        Button("Create my invite link") { Task { await model.choosePublicName(nameDraft) } }
            .buttonStyle(DADButtonStyle(.primary)).disabled(model.isSavingName || nameDraft.trimmingCharacters(in: .whitespaces).isEmpty)
            .accessibilityIdentifier("save-name")
    }
}

/// "Add to Apple Wallet" for the referral code, shown only when the deployment issues passes. The
/// bytes go to Wallet's own add sheet; ones Wallet cannot read are reported, not silently dropped.
private struct WalletPassButton: View {
    @State var model: WalletPassModel
    @State private var presented: PresentedPass?

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if model.available == true {
                Button(model.isPreparing ? "Preparing your Wallet pass…" : "Add to Apple Wallet") { Task { await model.prepare() } }
                    .buttonStyle(DADButtonStyle(.secondary)).disabled(model.isPreparing).accessibilityIdentifier("wallet-add")
            } else if model.checkFailed {
                Text("Wallet availability couldn’t be checked. Your on-screen code still works.").font(.footnote).foregroundStyle(.secondary)
                Button("Check Wallet availability again") { Task { await model.check() } }.buttonStyle(DADButtonStyle(.tertiary)).accessibilityIdentifier("wallet-recheck")
            }
            if let error = model.error {
                Text(error).font(.footnote).foregroundStyle(Color.dad("fail")).accessibilityIdentifier("wallet-error")
            }
        }
        .task { await model.check() }
        .onChange(of: model.pass) { _, data in
            guard let data else { return }
            if let pass = try? PKPass(data: data) { presented = PresentedPass(pass: pass); model.pass = nil } else { model.passRejected() }
        }
        .sheet(item: $presented) { AddPassSheet(pass: $0.pass) }
    }
}

private struct PresentedPass: Identifiable {
    let id = UUID()
    let pass: PKPass
}

private struct AddPassSheet: UIViewControllerRepresentable {
    let pass: PKPass
    func makeUIViewController(context: Context) -> UIViewController {
        PKAddPassesViewController(pass: pass) ?? UIViewController()
    }
    func updateUIViewController(_ controller: UIViewController, context: Context) {}
}

/// The full-screen IRL code (R-1, R-2): a QR of the in-person link, drawn locally with CoreImage so no image
/// is fetched and no untrusted file is parsed. Meant to be scanned from a phone screen face to face.
private struct InviteQRSheet: View {
    let url: URL
    let onClose: () -> Void

    var body: some View {
        NavigationStack {
            VStack(spacing: 20) {
                Text("Show this code").font(.title.bold()).accessibilityAddTraits(.isHeader)
                if let image = qrCodeImage(url.absoluteString, scale: 10) {
                    Image(uiImage: image).interpolation(.none).resizable().scaledToFit()
                        .frame(maxWidth: 320).padding(16).background(Color.white, in: RoundedRectangle(cornerRadius: 12))
                        .accessibilityLabel("QR code for your invite link").accessibilityIdentifier("qr-code")
                } else {
                    Text("The code couldn’t be drawn. Share your link instead.").accessibilityIdentifier("qr-failed")
                }
                Text("A friend scans it with their phone camera to open your invite.").font(.footnote).foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                Spacer()
            }
            .padding(28).modifier(EngagementBackground()).accessibilityElement(children: .contain).accessibilityIdentifier("qr-sheet")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done", action: onClose).accessibilityIdentifier("qr-close")
                }
            }
        }
    }
}

/// "See every dollar this initiative has spent" (A-3): spend by category, totals only (PRD §5.2).
struct InitiativeSpendScreen: View {
    @State var model: InitiativeSpendModel
    let title: String
    var onSignedOut: () -> Void = {}

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Text("Where the money went").font(.largeTitle.bold()).accessibilityAddTraits(.isHeader)
                Text(title).font(.headline)
                switch model.phase {
                case .loading:
                    ProgressView().accessibilityIdentifier("spend-loading")
                case .unpublished:
                    Text("This initiative’s spending hasn’t been published yet.").accessibilityIdentifier("spend-unpublished")
                case .failed(let message):
                    Text(message).accessibilityIdentifier("spend-error")
                    Button("Try again") { Task { await model.load() } }
                        .buttonStyle(DADButtonStyle(.primary)).accessibilityIdentifier("spend-retry")
                case .ready(let summary):
                    DADCard {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("Total spent").font(.footnote).foregroundStyle(.secondary)
                            Text(summary.totalLabel).font(.title.bold()).accessibilityIdentifier("spend-total")
                        }
                    }
                    if summary.slices.isEmpty {
                        Text("No spending by category yet.").font(.footnote).accessibilityIdentifier("spend-empty")
                    }
                    ForEach(Array(summary.slices.enumerated()), id: \.offset) { index, slice in
                        HStack {
                            Text(slice.category)
                            Spacer()
                            Text(slice.amountLabel).monospacedDigit()
                        }
                        .accessibilityElement(children: .combine).accessibilityIdentifier("spend-row-\(index)")
                    }
                    Text("Totals by category, not individual payments.").font(.caption).foregroundStyle(.secondary)
                }
            }
            .frame(maxWidth: 560, alignment: .leading).padding(28).frame(maxWidth: .infinity)
        }
        .modifier(EngagementBackground())
        .accessibilityElement(children: .contain).accessibilityIdentifier("spend-screen")
        .task { await model.load() }
        .onChange(of: model.signedOut) { _, signedOut in if signedOut { onSignedOut() } }
    }
}
