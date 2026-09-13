import XCTest
@testable import LifeOS

final class UsageFactsTests: XCTestCase {
    func testComputeReturnsAllNilFactsWhenAnalyticsIsMissing() {
        let facts = UsageFacts.compute(from: nil)

        XCTAssertNil(facts.peakActivity)
        XCTAssertNil(facts.observedTotals)
        XCTAssertNil(facts.freshness)
    }

    func testComputeReturnsNilPeakAndTotalsWhenActivityIsEmpty() {
        let snapshot = UsageAnalyticsSnapshot(
            provider: .codex,
            activity: [],
            projection: [],
            modelBreakdowns: [],
            heatmap: [],
            provenance: DemoDataProvider.provenance
        )

        let facts = UsageFacts.compute(from: snapshot)

        XCTAssertNil(facts.peakActivity, "empty activity must not fabricate a peak")
        XCTAssertNil(facts.observedTotals, "empty activity must not fabricate a total of 0")
        XCTAssertNotNil(facts.freshness, "freshness is sourced from provenance, independent of activity")
    }

    func testComputeFindsPeakHourTokensAndLabelsGranularityAsHour() throws {
        let base = Date(timeIntervalSince1970: 1_785_283_200)
        let activity = [
            UsageActivityPoint(date: base, tokens: 1_000, usedPercent: 0.1),
            UsageActivityPoint(date: base.addingTimeInterval(3_600), tokens: 42_000, usedPercent: 0.3),
            UsageActivityPoint(date: base.addingTimeInterval(7_200), tokens: 8_000, usedPercent: 0.4)
        ]
        let snapshot = UsageAnalyticsSnapshot(
            provider: .codex,
            activity: activity,
            projection: [],
            modelBreakdowns: [],
            heatmap: [],
            provenance: DemoDataProvider.provenance
        )

        let facts = UsageFacts.compute(from: snapshot)
        let peak = try XCTUnwrap(facts.peakActivity)

        XCTAssertEqual(peak.tokens, 42_000)
        XCTAssertEqual(peak.date, base.addingTimeInterval(3_600))
        XCTAssertEqual(peak.granularityLabel, "hour")
    }

    func testComputeSumsObservedTokensAndCountsObservations() throws {
        let base = Date(timeIntervalSince1970: 1_785_283_200)
        let activity = [
            UsageActivityPoint(date: base, tokens: 1_000, usedPercent: 0.1),
            UsageActivityPoint(date: base.addingTimeInterval(3_600), tokens: 2_500, usedPercent: 0.2),
            UsageActivityPoint(date: base.addingTimeInterval(7_200), tokens: 500, usedPercent: 0.25)
        ]
        let snapshot = UsageAnalyticsSnapshot(
            provider: .claude,
            activity: activity,
            projection: [],
            modelBreakdowns: [],
            heatmap: [],
            provenance: DemoDataProvider.provenance
        )

        let facts = UsageFacts.compute(from: snapshot)
        let totals = try XCTUnwrap(facts.observedTotals)

        XCTAssertEqual(totals.totalTokens, 4_000)
        XCTAssertEqual(totals.observationCount, 3)
    }

    func testComputeDerivesFreshnessFromProvenance() throws {
        let observedAt = Date(timeIntervalSince1970: 1_785_283_200)
        let provenance = Provenance(source: "Live connector", observedAt: observedAt, quality: .observed, connector: .healthy)
        let snapshot = UsageAnalyticsSnapshot(
            provider: .codex,
            activity: [],
            projection: [],
            modelBreakdowns: [],
            heatmap: [],
            provenance: provenance
        )

        let now = observedAt.addingTimeInterval(60) // well within "fresh" (< 7.5 min)
        let facts = UsageFacts.compute(from: snapshot, now: now)
        let freshness = try XCTUnwrap(facts.freshness)

        XCTAssertEqual(freshness.observedAt, observedAt)
        XCTAssertEqual(freshness.freshness, .fresh)
        XCTAssertEqual(freshness.source, "Live connector")
    }

    func testComputeMarksStaleConnectorAsUnavailableFreshnessNotFabricatedFresh() throws {
        let observedAt = Date(timeIntervalSince1970: 1_785_283_200)
        let provenance = Provenance(source: "Live connector", observedAt: observedAt, quality: .observed, connector: .revoked)
        let snapshot = UsageAnalyticsSnapshot(
            provider: .codex,
            activity: [],
            projection: [],
            modelBreakdowns: [],
            heatmap: [],
            provenance: provenance
        )

        let facts = UsageFacts.compute(from: snapshot, now: observedAt)
        let freshness = try XCTUnwrap(facts.freshness)

        XCTAssertEqual(freshness.freshness, .unavailable)
    }

    func testComputeOnDemoAnalyticsPopulatesRealNumbersForQAVisibility() throws {
        let demo = try XCTUnwrap(DemoUsageAnalytics.snapshots.first { $0.provider == .codex })

        let facts = UsageFacts.compute(from: demo, now: DemoDataProvider.observedAt)

        XCTAssertNotNil(facts.peakActivity, "demo fixtures must populate real computed numbers for QA")
        XCTAssertNotNil(facts.observedTotals)
        XCTAssertNotNil(facts.freshness)
        XCTAssertGreaterThan(try XCTUnwrap(facts.observedTotals).totalTokens, 0)
    }
}
