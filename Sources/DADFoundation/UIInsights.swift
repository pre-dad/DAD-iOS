import Foundation

public enum UICalloutTone: Sendable, Equatable { case info, success, warning }

public struct UIMetricCell: Sendable, Equatable {
    public let value: String
    public let caption: String?
}

public struct UILink: Sendable, Equatable {
    public let destination: AccountDestination
    public let label: String
}

public enum UIListRow: Sendable, Equatable {
    case text(String)
    case link(UILink)
}

/// A node of the approved layout that has something to show. Nodes of an unknown type, with a bind that does not
/// resolve, or with a value of the wrong type are left out, never an error.
public enum UIBlock: Sendable, Equatable {
    case heading(String)
    case text(String)
    case metrics([UIMetricCell])
    case callout(tone: UICalloutTone, title: String, body: String)
    case list([UIListRow])
    case link(UILink)
}

/// The "Your insights" panel: the blocks of a layout that passed validation and drew at least one node.
public struct InsightsPanel: Sendable, Equatable {
    public let specID: String
    public let blocks: [UIBlock]
    public init(specID: String, blocks: [UIBlock]) { self.specID = specID; self.blocks = blocks }
}

/// Draws an approved dashboard layout against the DonorDashboard response it arrived in. Mirrors the web
/// renderer (DAD-Main `apps/web/components/insights`): the same nodes draw, and the same ones draw nothing.
public enum UIInsights {
    /// The panel for a response's `insights` field, or nil when there is nothing to show: no field, a layout for a
    /// catalog version this build does not draw, one that fails validation, or one that draws no node.
    public static func panel(raw: UIValue?, dashboard: UIValue, catalog: UICatalog? = .shared) -> InsightsPanel? {
        guard let catalog, let raw, raw.objectValue != nil, raw["catalog_version"]?.integerValue == catalog.version,
              let specID = raw["spec_id"]?.stringValue, let spec = raw["spec"], let nodes = spec.arrayValue,
              catalog.validate(spec).isEmpty else { return nil }
        let blocks = nodes.compactMap { block($0, dashboard, catalog) }
        return blocks.isEmpty ? nil : InsightsPanel(specID: specID, blocks: blocks)
    }

    /// Resolves an RFC 6901 pointer in the dashboard response; nil when any step is missing.
    static func resolve(_ root: UIValue, _ pointer: UIValue?) -> UIValue? {
        guard let pointer = pointer?.stringValue, pointer.hasPrefix("/") else { return nil }
        let parts = pointer.dropFirst().split(separator: "/", omittingEmptySubsequences: false).map {
            $0.replacingOccurrences(of: "~1", with: "/").replacingOccurrences(of: "~0", with: "~")
        }
        if parts.first == "insights" { return nil }
        var current = root
        for part in parts {
            guard !part.isEmpty, let next = current[part] else { return nil }
            current = next
        }
        return current
    }

    /// A scalar as display text; nil for null, an object or an array.
    static func scalarText(_ value: UIValue?) -> String? {
        switch value {
        case .string(let text):
            return instant(text) ?? text
        case .integer(let number): return number.formatted(.number.locale(Locale(identifier: "en_US")))
        case .number(let number):
            return number.isFinite ? number.formatted(.number.locale(Locale(identifier: "en_US"))) : nil
        case .bool(let flag): return flag ? InsightsText.yes : InsightsText.no
        default: return nil
        }
    }

    private static func instant(_ text: String) -> String? {
        guard text.wholeMatch(of: /\d{4}-\d{2}-\d{2}T\d{2}:\d{2}.*/) != nil else { return nil }
        let plain = ISO8601DateFormatter()
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        guard let date = plain.date(from: text) ?? fractional.date(from: text) else { return nil }
        return date.formatted(date: .abbreviated, time: .shortened)
    }

    /// A whole-number metric in its catalog format; nil for a value that is not an integer.
    static func metricText(_ value: UIValue?, format: String?) -> String? {
        guard let number = value?.integerValue else { return nil }
        switch format {
        case "integer": return number.formatted(.number.locale(Locale(identifier: "en_US")))
        case "usd_minor": return formatUSDMinor(number)
        case "days": return InsightsText.days(number)
        case "percent": return "\(number)%"
        default: return nil
        }
    }

    private static func label(_ value: UIValue?) -> String? {
        guard let text = value?.stringValue, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        return text
    }

    private static func link(_ path: UIValue?, _ catalog: UICatalog) -> UILink? {
        guard let path = path?.stringValue, catalog.allowedPaths.contains(path),
              let destination = AccountDestination(rawValue: path), let text = InsightsText.link(path) else { return nil }
        return UILink(destination: destination, label: text)
    }

    private static func metric(_ node: UIValue, _ dashboard: UIValue, _ catalog: UICatalog) -> UIMetricCell? {
        guard node["type"]?.stringValue == "Metric",
              let value = metricText(resolve(dashboard, node["bind"]), format: node["format"]?.stringValue) else { return nil }
        return UIMetricCell(value: value, caption: node["caption"]?.stringValue.flatMap(InsightsText.caption))
    }

    private static func row(_ node: UIValue, _ dashboard: UIValue, _ catalog: UICatalog) -> UIListRow? {
        switch node["type"]?.stringValue {
        case "Text": scalarText(resolve(dashboard, node["bind"])).map(UIListRow.text)
        case "LinkButton": link(node["navigate"], catalog).map(UIListRow.link)
        default: nil
        }
    }

    private static func block(_ node: UIValue, _ dashboard: UIValue, _ catalog: UICatalog) -> UIBlock? {
        switch node["type"]?.stringValue {
        case "Heading":
            return (label(node["title"]) ?? scalarText(resolve(dashboard, node["bind"]))).map(UIBlock.heading)
        case "Text":
            return scalarText(resolve(dashboard, node["bind"])).map(UIBlock.text)
        case "Metric":
            return metric(node, dashboard, catalog).map { .metrics([$0]) }
        case "MetricGrid":
            let cells = (node["children"]?.arrayValue ?? []).compactMap { metric($0, dashboard, catalog) }
            return cells.isEmpty ? nil : .metrics(cells)
        case "Callout":
            guard let title = label(node["title"]),
                  let body = label(node["body"]) ?? scalarText(resolve(dashboard, node["bind"])) else { return nil }
            let tone: UICalloutTone = node["tone"]?.stringValue == "success" ? .success : node["tone"]?.stringValue == "warning" ? .warning : .info
            return .callout(tone: tone, title: title, body: body)
        case "List":
            guard case .array(let items)? = resolve(dashboard, node["bind"]), !items.isEmpty,
                  let children = node["children"]?.arrayValue else { return nil }
            let limit = catalog.limits["max_list_items", default: 8]
            let rows = children.prefix(limit).compactMap { row($0, dashboard, catalog) }
            return rows.isEmpty ? nil : .list(rows)
        case "LinkButton":
            return link(node["navigate"], catalog).map(UIBlock.link)
        default:
            return nil
        }
    }
}

/// The words a layout can show without carrying free text: the metric captions and link labels are catalog ids
/// mapped to localized strings here. The tests hold every id to the catalog's English wording.
enum InsightsText {
    static let yes = String(localized: "insights.yes", defaultValue: "Yes", bundle: .module)
    static let no = String(localized: "insights.no", defaultValue: "No", bundle: .module)

    static func days(_ count: Int) -> String {
        let number = count.formatted(.number.locale(Locale(identifier: "en_US")))
        return count == 1
            ? String(localized: "insights.days.one", defaultValue: "\(number) day", bundle: .module)
            : String(localized: "insights.days.other", defaultValue: "\(number) days", bundle: .module)
    }

    static func caption(_ id: String) -> String? {
        switch id {
        case "given": String(localized: "insights.caption.given", defaultValue: "Total given", bundle: .module)
        case "initiatives_funded": String(localized: "insights.caption.initiatives_funded", defaultValue: "Initiatives funded", bundle: .module)
        case "events_volunteered": String(localized: "insights.caption.events_volunteered", defaultValue: "Events volunteered", bundle: .module)
        case "referral_total": String(localized: "insights.caption.referral_total", defaultValue: "Given through your referrals", bundle: .module)
        case "referral_link": String(localized: "insights.caption.referral_link", defaultValue: "Referred by link", bundle: .module)
        case "referral_irl": String(localized: "insights.caption.referral_irl", defaultValue: "Referred in person", bundle: .module)
        case "active_network": String(localized: "insights.caption.active_network", defaultValue: "Active in your network", bundle: .module)
        case "annualized_network": String(localized: "insights.caption.annualized_network", defaultValue: "Network giving per year", bundle: .module)
        case "streak": String(localized: "insights.caption.streak", defaultValue: "Current streak", bundle: .module)
        case "days_to_next": String(localized: "insights.caption.days_to_next", defaultValue: "Days to next milestone", bundle: .module)
        case "last_milestone": String(localized: "insights.caption.last_milestone", defaultValue: "Last milestone", bundle: .module)
        case "national_percentile": String(localized: "insights.caption.national_percentile", defaultValue: "National percentile", bundle: .module)
        case "city_rank": String(localized: "insights.caption.city_rank", defaultValue: "City rank", bundle: .module)
        default: nil
        }
    }

    static func link(_ path: String) -> String? {
        switch path {
        case "/account/dashboard": String(localized: "insights.link.dashboard", defaultValue: "Your dashboard", bundle: .module)
        case "/account/profile": String(localized: "insights.link.profile", defaultValue: "Your profile", bundle: .module)
        case "/account/payment-method": String(localized: "insights.link.payment_method", defaultValue: "Payment method", bundle: .module)
        case "/account/gifts": String(localized: "insights.link.gifts", defaultValue: "Your gifts", bundle: .module)
        default: nil
        }
    }
}
