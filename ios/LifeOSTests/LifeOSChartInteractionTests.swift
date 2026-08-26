import XCTest
@testable import LifeOS

final class LifeOSChartInteractionTests: XCTestCase {
    func testNormalizationSortsKeepsLastDuplicateAndPreservesGaps() {
        let base = Date(timeIntervalSince1970: 1_800_000_000)
        let series = LifeOSChartSeries(
            id: "observed",
            label: "Observed",
            kind: .observed,
            points: [
                LifeOSChartPoint(timestamp: base.addingTimeInterval(10_800), value: 4),
                LifeOSChartPoint(timestamp: base.addingTimeInterval(7_200), value: nil),
                LifeOSChartPoint(timestamp: base.addingTimeInterval(3_600), value: 2),
                LifeOSChartPoint(timestamp: base, value: 1),
                LifeOSChartPoint(timestamp: base.addingTimeInterval(3_600), value: 3),
            ],
            source: "Test source",
            provenance: .observed
        )

        let normalized = LifeOSChartKit.normalizedPoints(
            for: series,
            expectedCadence: 3_600
        )

        XCTAssertEqual(normalized.map(\.timestamp), [
            base,
            base.addingTimeInterval(3_600),
            base.addingTimeInterval(7_200),
            base.addingTimeInterval(10_800),
        ])
        XCTAssertEqual(normalized[1].value, 3, "The last source occurrence wins deterministically")
        XCTAssertTrue(normalized[2].isGap)
        XCTAssertTrue(normalized[3].startsNewSegment)
        XCTAssertEqual(LifeOSChartKit.segments(from: normalized).count, 2)
        XCTAssertEqual(LifeOSChartKit.segments(from: normalized).map(\.count), [2, 1])
    }

    func testNearestSelectionUsesTimestampAndObservedTieBreak() throws {
        let base = Date(timeIntervalSince1970: 1_800_000_000)
        let target = LifeOSChartSeries(
            id: "target",
            label: "Target",
            kind: .target,
            points: [LifeOSChartPoint(timestamp: base.addingTimeInterval(-10), value: 0.2)],
            source: "Target plan",
            provenance: .estimated
        )
        let observed = LifeOSChartSeries(
            id: "observed",
            label: "Observed",
            kind: .observed,
            points: [LifeOSChartPoint(timestamp: base.addingTimeInterval(10), value: 0.4)],
            source: "Live source",
            provenance: .observed
        )

        let selected = try XCTUnwrap(
            LifeOSChartKit.nearestSelection(in: [target, observed], to: base)
        )

        XCTAssertEqual(selected.kind, .observed)
        XCTAssertEqual(selected.point.timestamp, base.addingTimeInterval(10))
        XCTAssertEqual(selected.provenanceLabel, "Observed · Live source")
    }

    func testUsageSelectionIdentitySeparatesObservedAndProjectedPoints() {
        let base = Date(timeIntervalSince1970: 1_800_000_000)
        let observed = UsageSelectionPoint(date: base, usedPercent: 0.4, isProjected: false)
        let projected = UsageSelectionPoint(date: base, usedPercent: 0.6, isProjected: true)

        XCTAssertNotEqual(observed.id, projected.id)
        XCTAssertEqual(
            UsageSelection.closestPoint(to: base, observed: [observed].map {
                UsageProjectionPoint(date: $0.date, usedPercent: $0.usedPercent)
            }, projected: [projected].map {
                UsageProjectionPoint(date: $0.date, usedPercent: $0.usedPercent)
            })?.id,
            observed.id
        )
    }

    func testSelectionReturnsNoDataInsideExplicitGap() {
        let base = Date(timeIntervalSince1970: 1_800_000_000)
        let series = LifeOSChartSeries(
            id: "observed",
            label: "Observed",
            kind: .observed,
            points: [
                LifeOSChartPoint(timestamp: base, value: 1),
                LifeOSChartPoint(timestamp: base.addingTimeInterval(3_600), value: nil),
                LifeOSChartPoint(timestamp: base.addingTimeInterval(7_200), value: 3),
            ],
            source: "Gateway",
            provenance: .observed
        )

        let result = LifeOSChartKit.selectionResult(
            in: [series],
            to: base.addingTimeInterval(5_400),
            expectedCadence: 3_600
        )

        XCTAssertEqual(result.noDataSelection?.reason, .explicitGap)
        XCTAssertNil(result.selectedDatum)
    }

    func testSelectionReturnsNoDataInsideCadenceBreak() {
        let base = Date(timeIntervalSince1970: 1_800_000_000)
        let series = LifeOSChartSeries(
            id: "observed",
            label: "Observed",
            kind: .observed,
            points: [
                LifeOSChartPoint(timestamp: base, value: 1),
                LifeOSChartPoint(timestamp: base.addingTimeInterval(7_200), value: 3),
            ],
            source: "Gateway",
            provenance: .observed
        )

        let result = LifeOSChartKit.selectionResult(
            in: [series],
            to: base.addingTimeInterval(3_600),
            expectedCadence: 3_600
        )

        XCTAssertEqual(result.noDataSelection?.reason, .cadenceBreak)
        XCTAssertNil(result.selectedDatum)
    }

    func testObservedGapBlocksDistantCrossSeriesFallback() {
        let base = Date(timeIntervalSince1970: 1_800_000_000)
        let observed = LifeOSChartSeries(
            id: "observed",
            label: "Observed",
            kind: .observed,
            points: [
                LifeOSChartPoint(timestamp: base, value: 1),
                LifeOSChartPoint(timestamp: base.addingTimeInterval(3_600), value: nil),
                LifeOSChartPoint(timestamp: base.addingTimeInterval(7_200), value: 3),
            ],
            source: "Gateway",
            provenance: .observed
        )
        let target = LifeOSChartSeries(
            id: "target",
            label: "Target",
            kind: .target,
            points: [
                LifeOSChartPoint(timestamp: base.addingTimeInterval(-86_400), value: 0),
                LifeOSChartPoint(timestamp: base.addingTimeInterval(86_400), value: 4),
            ],
            source: "Plan",
            provenance: .estimated
        )

        let result = LifeOSChartKit.selectionResult(
            in: [observed, target],
            to: base.addingTimeInterval(5_400),
            expectedCadence: 3_600
        )

        XCTAssertEqual(result.noDataSelection?.reason, .explicitGap)
        XCTAssertNil(result.selectedDatum)
    }

    func testSeriesStylesKeepBindingDashPatternsDistinct() {
        XCTAssertEqual(LifeOSChartSeriesKind.target.style.dashPattern.map(Double.init), [6, 4])
        XCTAssertEqual(LifeOSChartSeriesKind.estimate.style.dashPattern.map(Double.init), [3, 3])
        XCTAssertEqual(LifeOSChartSeriesKind.history.style.lineStyle, .dotted)
    }

    func testTooltipFrameStaysInsidePlotInset() {
        let bounds = CGRect(x: 0, y: 0, width: 200, height: 100)
        let frame = LifeOSChartKit.boundedTooltipFrame(
            anchor: CGPoint(x: 198, y: 2),
            size: CGSize(width: 90, height: 40),
            in: bounds
        )

        XCTAssertTrue(bounds.insetBy(dx: 8, dy: 8).contains(frame))
    }

    func testAccessibilitySummaryKeepsProvenanceVisible() {
        let summary = LifeOSChartAccessibilitySummary(
            title: "Usage",
            unit: "%",
            source: "Gateway",
            provenance: .demo,
            value: "58",
            timestamp: Date(timeIntervalSince1970: 1_800_000_000)
        )

        XCTAssertTrue(summary.spokenSummary.contains("DEMO · NOT LIVE"))
        XCTAssertTrue(summary.spokenSummary.contains("Source Gateway"))
    }
}
