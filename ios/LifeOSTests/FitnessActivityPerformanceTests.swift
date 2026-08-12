import Foundation
import XCTest
@testable import LifeOS

final class FitnessActivityPerformanceTests: XCTestCase {
    func testActivityDayCarriesExplicitObservedDemoAndUnavailableState() {
        let date = Date(timeIntervalSince1970: 1_754_000_000)
        let observed = FitnessActivityDay(
            date: date,
            state: .observed(count: 8, window: "2026-07-13/2026-08-11", provenance: "Helio Strap → HealthKit")
        )
        XCTAssertEqual(observed.activityCount, 8)
        XCTAssertEqual(observed.legendBucket, 3)
        if case .observed(let count, let window, let provenance) = observed.state {
            XCTAssertEqual(count, 8)
            XCTAssertEqual(window, "2026-07-13/2026-08-11")
            XCTAssertEqual(provenance, "Helio Strap → HealthKit")
        } else {
            XCTFail("Expected an observed day")
        }

        let demo = FitnessActivityDay(
            date: date,
            state: .demo(count: 0, window: "Last 30 days · demo fixture", provenance: "DEMO · NOT LIVE")
        )
        XCTAssertEqual(demo.activityCount, 0, "An explicit observed/demo zero is not unavailable")
        XCTAssertEqual(demo.legendBucket, 0)

        let unavailable = FitnessActivityDay(
            date: date,
            state: .unavailable(reason: "No workout sample", window: "Last 30 days", provenance: "HealthKit")
        )
        XCTAssertNil(unavailable.activityCount, "Unavailable must never become zero")
        XCTAssertNil(unavailable.legendBucket)
    }

    func testActivityDayInvalidSourceMetadataBecomesUnavailable() {
        let date = Date(timeIntervalSince1970: 1_754_000_000)
        let invalid = FitnessActivityDay(
            date: date,
            state: .observed(count: -2, window: "", provenance: "")
        )
        guard case .unavailable(let reason, let window, let provenance) = invalid.state else {
            return XCTFail("Invalid day observations must not render")
        }
        XCTAssertFalse(reason.isEmpty)
        XCTAssertFalse(window.isEmpty)
        XCTAssertFalse(provenance.isEmpty)
    }

    func testSeriesPointRejectsNonFiniteAndNegativeValues() {
        let date = Date(timeIntervalSince1970: 1_754_000_000)
        XCTAssertNil(FitnessActivitySeriesPoint(date: date, value: .infinity).value)
        XCTAssertNil(FitnessActivitySeriesPoint(date: date, value: .nan).value)
        XCTAssertNil(FitnessActivitySeriesPoint(date: date, value: -4).value)
        XCTAssertEqual(FitnessActivitySeriesPoint(date: date, value: 12.5).value, 12.5)
    }

    func testUnavailableActivitySurfaceHasExplicitStatesForAllPerformanceCards() {
        let snapshot = FitnessActivitySnapshot.unavailable
        for metric in [snapshot.cardioLoad, snapshot.cardioFocus, snapshot.heartRateRecovery, snapshot.strengthVolume] {
            guard case .unavailable(let reason) = metric.state else {
                return XCTFail("Expected an unavailable state for \(metric.id)")
            }
            XCTAssertFalse(reason.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        }
        guard case .unavailable(let targetReason) = snapshot.performanceTarget.state else {
            return XCTFail("Expected an unavailable target")
        }
        XCTAssertFalse(targetReason.isEmpty)
    }

    func testDemoSnapshotIsExplicitAndUsesNamedWindow() throws {
        let anchor = Date(timeIntervalSince1970: 1_754_000_000)
        let snapshot = FitnessActivitySnapshot.demo(anchor: anchor)
        XCTAssertEqual(snapshot.activitySeries.count, 30)
        XCTAssertEqual(snapshot.performanceTarget.series.count, 30)
        XCTAssertEqual(snapshot.activityCalendarDays.count, 30)
        let calendar = Calendar(identifier: .gregorian)
        let first = try XCTUnwrap(snapshot.activityCalendarDays.map(\.date).min())
        let last = try XCTUnwrap(snapshot.activityCalendarDays.map(\.date).max())
        XCTAssertEqual(calendar.dateComponents([.day], from: first, to: last).day, 29)
        XCTAssertTrue(snapshot.activityCalendarDays.allSatisfy {
            if case .demo = $0.state { return true }
            return false
        })
        guard case .demo(_, _, let window, let provenance) = snapshot.activityTotal.state else {
            return XCTFail("Activity total must remain a demo fixture")
        }
        XCTAssertTrue(window.contains("Last 30 days"))
        XCTAssertTrue(provenance.contains("DEMO · NOT LIVE"))
        guard case .demo(_, _, _, _, let targetWindow, let targetProvenance) = snapshot.performanceTarget.state else {
            return XCTFail("Performance target must remain a demo fixture")
        }
        XCTAssertEqual(targetWindow, window)
        XCTAssertEqual(targetProvenance, provenance)
    }

    func testObservedMetricPreservesSourceWindowAndProvenanceWithoutRecalculation() {
        XCTAssertEqual(FitnessActivityMetric.Unit.sourceDefined.suffix, "source-defined")
        XCTAssertNotEqual(FitnessActivityMetric.Unit.sourceDefined.suffix, "/100")
        let metric = FitnessActivityMetric(
            id: "cardio-load",
            title: "Cardio load",
            state: .observed(
                value: 42,
                unit: .sourceDefined,
                window: "2026-07-13/2026-08-11",
                provenance: "Helio Strap → HealthKit"
            ),
            hue: .blue
        )
        guard case .observed(let value, let unit, let window, let provenance) = metric.state else {
            return XCTFail("Expected an observed metric")
        }
        XCTAssertEqual(value, 42)
        XCTAssertEqual(unit, .sourceDefined)
        XCTAssertEqual(window, "2026-07-13/2026-08-11")
        XCTAssertEqual(provenance, "Helio Strap → HealthKit")
    }

    func testInvalidObservedMetricAndTargetBecomeUnavailable() {
        let metric = FitnessActivityMetric(
            id: "invalid",
            title: "Invalid",
            state: .observed(value: .nan, unit: .sourceDefined, window: "window", provenance: "source")
        )
        guard case .unavailable = metric.state else {
            return XCTFail("Non-finite observed values must not render")
        }

        let negative = FitnessActivityMetric(
            id: "negative",
            title: "Negative",
            state: .observed(value: -1, unit: .sourceDefined, window: "window", provenance: "source")
        )
        guard case .unavailable = negative.state else {
            return XCTFail("Negative observed values must not render")
        }

        let target = FitnessPerformanceTarget(
            state: .observed(
                current: 20,
                deviationPercent: .infinity,
                lowerBound: 40,
                upperBound: 20,
                window: "window",
                provenance: "source"
            )
        )
        guard case .unavailable = target.state else {
            return XCTFail("Invalid target bands must not render")
        }
    }
}
