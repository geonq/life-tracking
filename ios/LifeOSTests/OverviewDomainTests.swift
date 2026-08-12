import XCTest
@testable import LifeOS

final class OverviewDomainTests: XCTestCase {
    func testDemoOverviewContainsRequestedCompactCardsWithoutPretendingToBeLive() {
        let overview = DemoDataProvider.overview
        XCTAssertEqual(overview.sections.map(\.kind), [.llm, .clipper, .health, .finance])
        XCTAssertTrue(overview.sections.allSatisfy { $0.provenance.quality == .demo })
        XCTAssertEqual(overview.sections.first { $0.kind == .llm }?.metrics.map(\.label), ["Codex", "Claude", "GLM", "DeepSeek", "Google AI Studio", "Banked resets"])
        XCTAssertEqual(overview.sections.first { $0.kind == .clipper }?.metrics.map(\.label), ["Views today", "Subscribers today", "Revenue this month"])
        XCTAssertEqual(overview.sections.first { $0.kind == .clipper }?.metrics.map(\.icon), [.views, .subscribers, .revenue])
        XCTAssertEqual(overview.sections.first { $0.kind == .finance }?.metrics.map(\.icon), [.savings, .budget])
    }

    func testUnavailableValuesStayUnavailableInsteadOfInventingMetrics() {
        let metric = OverviewMetric(label: "Resting heart rate", value: nil, unit: "bpm", icon: .heartRate)
        XCTAssertNil(metric.displayValue)
    }

    func testProductionOverviewFallbackContainsNoSyntheticValues() {
        let generatedAt = Date(timeIntervalSince1970: 1_800_000_000)
        let overview = OverviewSnapshot.unavailable(at: generatedAt)

        XCTAssertEqual(overview.generatedAt, generatedAt)
        XCTAssertEqual(overview.sections.map(\.kind), [.llm, .clipper, .health, .finance])
        XCTAssertTrue(overview.sections.allSatisfy { section in
            section.provenance.quality == .unavailable
                && section.provenance.connector == .unavailable
                && section.metrics.allSatisfy { $0.value == nil }
        })
    }

    func testProductionOverviewRetainsTypedClipperPayloadForDetailRendering() {
        let generatedAt = Date(timeIntervalSince1970: 1_800_000_000)
        let clipper = ClipperSnapshot.unavailable(at: generatedAt)
        let overview = OverviewSnapshot.production(clipper: clipper, at: generatedAt)

        XCTAssertEqual(overview.clipperSnapshot, clipper)
    }

    func testPartialClipperQualityRemainsExplicitInOverviewProjection() throws {
        let clipper = try makeClipperSnapshot(quality: "partial", amountCents: 8_420)
        let section = OverviewSection.clipperSummary(from: clipper)

        XCTAssertEqual(section.provenance.quality, .observed)
        XCTAssertEqual(section.state, .partial)
        XCTAssertEqual(section.provenance.source, "reviewed-clipper-connector")
    }

    func testClipperRevenueFormattingHandlesTheFullSafeIntegerCentsBound() throws {
        let clipper = try makeClipperSnapshot(amountCents: 9_007_199_254_740_991)
        let section = OverviewSection.clipperSummary(from: clipper)

        XCTAssertEqual(section.metric(containing: "Revenue")?.value, "€90071992547409.91")
    }

    func testUsageSummaryAdaptsAcrossAllProvidersWithoutInventingValues() {
        let section = OverviewSection.usageSummary(from: DemoDataProvider.providers)
        XCTAssertEqual(section.metrics.map(\.label), ["Codex", "Claude", "GLM", "DeepSeek", "Google AI Studio", "Banked resets"])
        XCTAssertEqual(section.metrics.first { $0.label == "Codex" }?.value, "58")
        XCTAssertEqual(section.metrics.first { $0.label == "Claude" }?.value, "69")
        for name in ["GLM", "DeepSeek", "Google AI Studio"] {
            let metric = section.metrics.first { $0.label == name }
            XCTAssertNil(metric?.value)
            XCTAssertEqual(metric?.unit, "% left")
        }
    }

    func testUnavailableClipperContractKeepsDetailMetricsEmpty() throws {
        let overview = OverviewSnapshot.unavailable(at: Date(timeIntervalSince1970: 1_800_000_000))
        let clipper = try XCTUnwrap(overview.sections.first { $0.kind == .clipper })

        XCTAssertEqual(clipper.metrics.map(\.label), ["Views today", "Subscribers today", "Revenue this month"])
        XCTAssertTrue(clipper.metrics.allSatisfy { $0.displayValue == nil })
        XCTAssertEqual(clipper.provenance.quality, .unavailable)
        XCTAssertEqual(clipper.provenance.connector, .unavailable)
    }

    func testOverviewSectionMetricLookupIsCaseInsensitiveAndDoesNotInventHistory() throws {
        let finance = try XCTUnwrap(DemoDataProvider.overview.sections.first { $0.kind == .finance })

        XCTAssertEqual(finance.metric(containing: "BUDGET")?.value, "45")
        XCTAssertNil(finance.metric(containing: "history"))
    }

    private func makeClipperSnapshot(quality: String = "observed", amountCents: Int) throws -> ClipperSnapshot {
        let now = Date()
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let timestamp = formatter.string(from: now)
        let provenance: [String: Any] = [
            "source": "reviewed-clipper-connector", "observedAt": timestamp,
            "freshness": "fresh", "quality": "observed", "connectorState": "healthy",
        ]
        let metrics: [String: Any] = [
            "views": ["availability": "observed", "value": 42_000, "provenance": provenance],
            "subscribers": ["availability": "observed", "value": 1_240, "provenance": provenance],
            "revenue": ["availability": "observed", "amountCents": amountCents, "currency": "EUR", "provenance": provenance],
        ]
        let payload: [String: Any] = [
            "schemaVersion": 1, "availability": "observed", "generatedAt": timestamp,
            "currency": "EUR", "metrics": metrics, "accounts": [], "trends": [], "breakdowns": [],
            "provenance": [
                "source": "reviewed-clipper-connector", "observedAt": timestamp,
                "freshness": "fresh", "quality": quality, "connectorState": "healthy",
            ],
        ]
        return try ClipperSnapshot.decode(JSONSerialization.data(withJSONObject: payload), now: now)
    }
}
