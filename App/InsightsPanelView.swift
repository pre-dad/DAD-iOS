import SwiftUI
import DADFoundation

/// The "Your insights" section of the donor home: an approved layout drawn from the dashboard response.
/// `UIInsights` has already dropped every node that has nothing to show, so each block here draws.
struct InsightsPanelView: View {
    let panel: InsightsPanel
    let onNavigate: (AccountDestination) -> Void

    var body: some View {
        DADCard {
            VStack(alignment: .leading, spacing: 12) {
                Text("Your insights").font(.headline).accessibilityAddTraits(.isHeader)
                    .accessibilityIdentifier("insights-title")
                ForEach(Array(panel.blocks.enumerated()), id: \.offset) { _, block in
                    InsightsBlockView(block: block, onNavigate: onNavigate)
                }
            }
        }
        .accessibilityElement(children: .contain).accessibilityIdentifier("insights-panel")
    }
}

private struct InsightsBlockView: View {
    let block: UIBlock
    let onNavigate: (AccountDestination) -> Void

    var body: some View {
        switch block {
        case .heading(let text):
            Text(text).font(.subheadline.weight(.semibold)).accessibilityAddTraits(.isHeader)
                .accessibilityIdentifier("insights-heading")
        case .text(let text):
            Text(text).accessibilityIdentifier("insights-text")
        case .metrics(let cells):
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 140), alignment: .topLeading)], alignment: .leading, spacing: 12) {
                ForEach(Array(cells.enumerated()), id: \.offset) { _, cell in
                    VStack(alignment: .leading, spacing: 2) {
                        Text(cell.value).font(.title2.bold())
                        if let caption = cell.caption { Text(caption).font(.footnote).foregroundStyle(.secondary) }
                    }
                    .accessibilityElement(children: .combine).accessibilityIdentifier("insights-metric")
                }
            }
        case .callout(let tone, let title, let body):
            VStack(alignment: .leading, spacing: 4) {
                Label {
                    Text(title).font(.subheadline.weight(.semibold))
                } icon: {
                    Image(systemName: icon(tone)).foregroundStyle(color(tone)).accessibilityHidden(true)
                }
                .accessibilityAddTraits(.isHeader)
                Text(body).font(.footnote)
            }
            .accessibilityElement(children: .combine).accessibilityIdentifier("insights-callout")
        case .list(let rows):
            VStack(alignment: .leading, spacing: 8) {
                ForEach(Array(rows.enumerated()), id: \.offset) { _, row in
                    switch row {
                    case .text(let text): Text(text).accessibilityIdentifier("insights-list-text")
                    case .link(let link): LinkRow(link: link, onNavigate: onNavigate)
                    }
                }
            }
            .accessibilityElement(children: .contain).accessibilityIdentifier("insights-list")
        case .link(let link):
            LinkRow(link: link, onNavigate: onNavigate)
        }
    }

    private func icon(_ tone: UICalloutTone) -> String {
        switch tone {
        case .info: "info.circle.fill"
        case .success: "checkmark.circle.fill"
        case .warning: "exclamationmark.triangle.fill"
        }
    }

    private func color(_ tone: UICalloutTone) -> Color {
        switch tone {
        case .info: Color.dad("brand-ink")
        case .success: Color.dad("ok")
        case .warning: Color.dad("warn")
        }
    }
}

private struct LinkRow: View {
    let link: UILink
    let onNavigate: (AccountDestination) -> Void

    var body: some View {
        Button(link.label) { onNavigate(link.destination) }
            .buttonStyle(DADButtonStyle(.secondary, fillsWidth: false))
            .accessibilityIdentifier("insights-link-\(link.destination.rawValue.dropFirst("/account/".count))")
    }
}
