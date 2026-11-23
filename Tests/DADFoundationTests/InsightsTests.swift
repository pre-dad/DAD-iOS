import Foundation
import XCTest
@testable import DADFoundation

private let specID = "7b0c6f9e-3c5a-4f0e-9a52-0d3a1c0e7a11"

private func panelJSON(_ spec: String, version: String = "1") -> String {
    #"{"catalog_version":\#(version),"spec_id":"\#(specID)","spec":\#(spec)}"#
}

final class InsightsCatalogTests: XCTestCase {
    private func catalog() throws -> UICatalog { try XCTUnwrap(UICatalog.shared, "bundled catalog must load") }

    private func contract(_ name: String) throws -> Data {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        return try Data(contentsOf: root.appendingPathComponent("contracts/foundation/\(name)"))
    }

    func testEverySharedVectorGetsTheCatalogVerdict() throws {
        let catalog = try catalog()
        let vectors = try XCTUnwrap(UIValue(json: contract("ui-catalog-vectors.json"))["vectors"]?.arrayValue)
        XCTAssertGreaterThan(vectors.count, 40)
        for vector in vectors {
            let name = vector["name"]?.stringValue ?? "?"
            let issues = catalog.validate(try XCTUnwrap(vector["spec"], name))
            if case .bool(true)? = vector["valid"] {
                XCTAssertEqual(issues, [], name)
            } else {
                let expected = (vector["codes"]?.arrayValue ?? []).compactMap(\.stringValue).sorted()
                XCTAssertEqual(issues.map(\.code).sorted(), expected, name)
            }
        }
    }

    func testBundledCatalogIsTheVendoredOne() throws {
        let catalog = try catalog()
        let vendored = try UIValue(json: contract("ui-catalog.json"))
        XCTAssertEqual(vendored["catalog_version"]?.integerValue, catalog.version)
        XCTAssertEqual(catalog.version, 1)
    }

    func testEveryCaptionAndLinkLabelHasLocalizedTextMatchingTheCatalog() throws {
        let catalog = try catalog()
        XCTAssertFalse(catalog.captions.isEmpty)
        for (id, english) in catalog.captions { XCTAssertEqual(InsightsText.caption(id), english, id) }
        XCTAssertFalse(catalog.labels.isEmpty)
        for (path, english) in catalog.labels { XCTAssertEqual(InsightsText.link(path), english, path) }
        XCTAssertNil(InsightsText.caption("made_up"))
    }

    func testLinkButtonOnlyReachesAccountPaths() throws {
        let catalog = try catalog()
        for path in ["/partner", "/account/claim", "https://evil.example/", "/account/dashboard?x=1"] {
            let spec = try UIValue(json: Data(#"[{"type":"LinkButton","navigate":"\#(path)"}]"#.utf8))
            XCTAssertEqual(catalog.validate(spec).map(\.code), ["NAV_FORBIDDEN"], path)
        }
        // Even a layout that skipped validation draws no link to a path outside the list.
        let dashboard = try UIValue(json: Data("{}".utf8))
        let raw = try UIValue(json: Data(panelJSON(#"[{"type":"LinkButton","navigate":"/partner"}]"#).utf8))
        XCTAssertNil(UIInsights.panel(raw: raw, dashboard: dashboard))
    }

    func testPanelDrawsEveryComponentFromTheDashboard() throws {
        let dashboard = try UIValue(json: Data(dashboardReadyJSON().utf8))
        let spec = #"""
        [{"type":"Heading","title":"Your impact"},
         {"type":"Text","bind":"/impact/currency"},
         {"type":"MetricGrid","children":[
           {"type":"Metric","bind":"/impact/given_minor","format":"usd_minor","caption":"given"},
           {"type":"Metric","bind":"/streak/ladder/days_to_next","format":"days","caption":"days_to_next"},
           {"type":"Metric","bind":"/impact/initiatives_funded","format":"integer"},
           {"type":"Metric","bind":"/rank/national_percentile","format":"percent"}]},
         {"type":"Callout","tone":"success","title":"Nice","body":"Keep going"},
         {"type":"List","bind":"/streak/ladder/bar","children":[{"type":"Text","bind":"/mode"},{"type":"LinkButton","navigate":"/account/gifts"}]},
         {"type":"LinkButton","navigate":"/account/profile"},
         {"type":"Sparkline","bind":"/impact/given_minor"}]
        """#
        let panel = try XCTUnwrap(UIInsights.panel(raw: UIValue(json: Data(panelJSON(spec).utf8)), dashboard: dashboard))
        XCTAssertEqual(panel.specID, specID)
        XCTAssertEqual(panel.blocks, [
            .heading("Your impact"),
            .text("USD"),
            // The percent metric binds a null rank, so its cell is left out rather than shown as 0.
            .metrics([UIMetricCell(value: "$1,240", caption: "Total given"),
                      UIMetricCell(value: "12 days", caption: "Days to next milestone"),
                      UIMetricCell(value: "4", caption: nil)]),
            .callout(tone: .success, title: "Nice", body: "Keep going"),
            .list([.text("test"), .link(UILink(destination: .gifts, label: "Your gifts"))]),
            .link(UILink(destination: .profile, label: "Your profile")),
        ])
    }

    func testUnsupportedVersionInvalidSpecAndEmptyDrawNoPanel() throws {
        let dashboard = try UIValue(json: Data(dashboardReadyJSON().utf8))
        let good = #"[{"type":"Heading","title":"Hi"}]"#
        for json in [panelJSON(good, version: "2"), panelJSON(good, version: "0"), panelJSON(good, version: #""1""#),
                     panelJSON("[]"), panelJSON(#"[{"type":"Heading","title":"<b>"}]"#),
                     panelJSON(#"[{"type":"Text","bind":"/insights/spec"}]"#), panelJSON(#"{"type":"Heading"}"#),
                     panelJSON(#"[{"type":"Text","bind":"/rank/city"}]"#), "[1]", "null", "{}"] {
            XCTAssertNil(UIInsights.panel(raw: try UIValue(json: Data(json.utf8)), dashboard: dashboard), json)
        }
        XCTAssertNil(UIInsights.panel(raw: nil, dashboard: dashboard))
        XCTAssertNotNil(UIInsights.panel(raw: try UIValue(json: Data(panelJSON(good).utf8)), dashboard: dashboard))
    }

    func testMetricFormatsAndScalarText() {
        XCTAssertEqual(UIInsights.metricText(.integer(1234), format: "integer"), "1,234")
        XCTAssertEqual(UIInsights.metricText(.integer(12345), format: "usd_minor"), "$123.45")
        XCTAssertEqual(UIInsights.metricText(.integer(1), format: "days"), "1 day")
        XCTAssertEqual(UIInsights.metricText(.integer(40), format: "percent"), "40%")
        XCTAssertNil(UIInsights.metricText(.string("4"), format: "integer"))
        XCTAssertNil(UIInsights.metricText(.integer(4), format: "bogus"))
        XCTAssertEqual(UIInsights.scalarText(.bool(true)), "Yes")
        XCTAssertNil(UIInsights.scalarText(.null))
        XCTAssertNil(UIInsights.scalarText(.array([])))
    }
}

final class WireInsightsTests: XCTestCase {
    private func dashboard(_ insights: String?) async throws -> DonorDashboard {
        let store = MemoryStore(Credentials(access: "tok", refresh: "ref", expiresAt: .distantFuture))
        let transport = ScriptedTransport { _, _ in (.ok, dashboardReadyJSON(insights: insights)) }
        let session = try AccountSession(api: WireAPI(origin: testOrigin, transport: transport), store: store)
        let service = WireDashboard(product: ProductClient(origin: testOrigin, transport: transport, session: session))
        guard case .ready(let value) = try await service.dashboard() else { throw AccountError.unavailable }
        return value
    }

    func testDashboardDecodesWithoutInsights() async throws {
        let value = try await dashboard(nil)
        XCTAssertNil(value.insights)
        XCTAssertEqual(value.impact.givenMinor, 124_000)
    }

    func testDashboardCarriesTheDrawnPanel() async throws {
        let value = try await dashboard(panelJSON(#"[{"type":"Metric","bind":"/impact/given_minor","format":"usd_minor","caption":"given"}]"#))
        XCTAssertEqual(value.insights?.blocks, [.metrics([UIMetricCell(value: "$1,240", caption: "Total given")])])
    }

    func testUnknownNodeTypesAndMalformedPanelsNeverFailTheDashboard() async throws {
        let unknown = try await dashboard(panelJSON(#"[{"type":"Chart","series":[1,2,{"a":null}]},{"type":"Heading","title":"Hi"}]"#))
        XCTAssertEqual(unknown.insights?.blocks, [.heading("Hi")])
        for malformed in [#"{"catalog_version":"x","spec_id":7,"spec":{"a":1}}"#, "null", "[]", #""text""#, "7",
                          panelJSON(#"[{"type":"Chart"}]"#), panelJSON(#"[{"type":"Heading","title":"Hi"}]"#, version: "9")] {
            let value = try await dashboard(malformed)
            XCTAssertNil(value.insights, malformed)
            XCTAssertEqual(value.streak?.current, 18, malformed)
        }
    }
}
