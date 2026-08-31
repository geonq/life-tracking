import Foundation
import XCTest
@testable import LifeOS

final class FitnessActivityPerformanceTests: XCTestCase {
    func testFitnessDateNavigationKeepsLocalDayAcrossBerlinSpringForward() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try XCTUnwrap(TimeZone(identifier: "Europe/Berlin"))
        let beforeTransition = try XCTUnwrap(calendar.date(from: DateComponents(
            year: 2026, month: 3, day: 28, hour: 12
        )))

        let nextDay = FitnessDateNavigation.addingDays(1, to: beforeTransition, calendar: calendar)

        XCTAssertEqual(calendar.component(.day, from: nextDay), 29)
        XCTAssertEqual(calendar.component(.hour, from: nextDay), 12)
        XCTAssertEqual(nextDay.timeIntervalSince(beforeTransition), 23 * 60 * 60, accuracy: 0.5)
    }

    func testFitnessDateNavigationKeepsLocalDayAcrossBerlinFallBack() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try XCTUnwrap(TimeZone(identifier: "Europe/Berlin"))
        let beforeTransition = try XCTUnwrap(calendar.date(from: DateComponents(
            year: 2026, month: 10, day: 24, hour: 12
        )))

        let nextDay = FitnessDateNavigation.addingDays(1, to: beforeTransition, calendar: calendar)

        XCTAssertEqual(calendar.component(.day, from: nextDay), 25)
        XCTAssertEqual(calendar.component(.hour, from: nextDay), 12)
        XCTAssertEqual(nextDay.timeIntervalSince(beforeTransition), 25 * 60 * 60, accuracy: 0.5)
    }

    func testFitnessDateNavigationFallsBackToTheOriginalDateAtCalendarBounds() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let original = Date(timeIntervalSince1970: 0)

        XCTAssertEqual(
            FitnessDateNavigation.addingDays(Int.max, to: original, calendar: calendar),
            original
        )
    }

    func testFitnessSectionRevealPolicyPreservesVisibleUserSelections() {
        XCTAssertFalse(
            FitnessSectionRevealPolicy.shouldReveal(
                selection: .journal,
                visibleSectionIDs: [FitnessSection.journal.id],
                userInitiated: true
            )
        )
        XCTAssertFalse(
            FitnessSectionRevealPolicy.shouldReveal(
                selection: .journal,
                visibleSectionIDs: [FitnessSection.journal.id],
                userInitiated: false
            )
        )
        XCTAssertTrue(
            FitnessSectionRevealPolicy.shouldReveal(
                selection: .settings,
                visibleSectionIDs: [FitnessSection.today.id],
                userInitiated: false
            )
        )
    }

    func testFitnessSectionRevealStateWaitsForLayoutAndRejectsStaleRequests() {
        let request = FitnessSectionRevealRequest(
            section: .settings,
            generation: 7,
            isInitialAppearance: true
        )

        XCTAssertEqual(
            FitnessSectionRevealState.action(
                for: request,
                currentSelection: .settings,
                currentGeneration: 7,
                visibleSectionIDs: [],
                layoutReady: false
            ),
            .waitForLayout
        )
        XCTAssertEqual(
            FitnessSectionRevealState.action(
                for: request,
                currentSelection: .settings,
                currentGeneration: 7,
                visibleSectionIDs: [FitnessSection.settings.id],
                layoutReady: true
            ),
            .clear
        )
        XCTAssertEqual(
            FitnessSectionRevealState.action(
                for: request,
                currentSelection: .settings,
                currentGeneration: 7,
                visibleSectionIDs: [FitnessSection.today.id],
                layoutReady: true
            ),
            .reveal
        )
        XCTAssertEqual(
            FitnessSectionRevealState.action(
                for: request,
                currentSelection: .settings,
                currentGeneration: 8,
                visibleSectionIDs: [FitnessSection.today.id],
                layoutReady: true
            ),
            .clear
        )
    }

    func testFitnessNavigationSourceKeepsStripAndDateControlsAccessible() throws {
        let sourceURL = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("LifeOS/Modules/Fitness/FitnessView.swift")
        let source = try String(contentsOf: sourceURL, encoding: .utf8)

        XCTAssertTrue(source.contains("ScrollView(.horizontal, showsIndicators: false)"))
        XCTAssertFalse(source.contains("ScrollView(.horizontal, showsIndicators: true)"))
        XCTAssertTrue(source.contains("accessibilityLabel(\"Previous day\")"))
        XCTAssertTrue(source.contains("accessibilityLabel(\"Next day\")"))
        XCTAssertTrue(source.contains("accessibilityIdentifier(\"fitness-date-previous-day\")"))
        XCTAssertTrue(source.contains("accessibilityIdentifier(\"fitness-date-next-day\")"))
        XCTAssertTrue(source.contains("accessibilityIdentifier(\"fitness-date-picker\")"))
        XCTAssertTrue(source.contains("FitnessSectionRevealState.action"))
        XCTAssertTrue(source.contains("FitnessDateNavigation.addingDays"))
    }

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

    func testPerformanceTargetStatusUsesCurrentAgainstInclusiveTargetBand() {
        let expected: [(Double, FitnessPerformanceTarget.TargetStatus)] = [
            (19, .below),
            (20, .within),
            (24, .within),
            (40, .within),
            (41, .above)
        ]

        for (current, status) in expected {
            XCTAssertEqual(
                FitnessPerformanceTarget.targetStatus(current: current, lowerBound: 20, upperBound: 40),
                status,
                "Expected \(current) against 20...40 to be \(status.rawValue)"
            )
        }
    }

    func testPerformanceTargetStateExposesBandStatusAndLeavesUnavailableStatesUnclassified() {
        let observed = FitnessPerformanceTarget(state: .observed(
            current: 19,
            deviationPercent: 12,
            lowerBound: 20,
            upperBound: 40,
            window: "Last 30 days",
            provenance: "Reviewed source"
        ))
        XCTAssertEqual(observed.targetStatus, .below)

        let demo = FitnessPerformanceTarget(state: .demo(
            current: 24,
            deviationPercent: -99,
            lowerBound: 20,
            upperBound: 40,
            window: "Demo window",
            provenance: "DEMO · NOT LIVE"
        ))
        XCTAssertEqual(demo.targetStatus, .within, "Deviation sign must not override the displayed band")

        XCTAssertEqual(
            FitnessPerformanceTarget.targetStatus(current: 20, lowerBound: 20, upperBound: 20),
            .within,
            "A zero-width target includes its exact boundary"
        )
        XCTAssertEqual(FitnessPerformanceTarget.targetStatus(current: 19, lowerBound: 20, upperBound: 20), .below)
        XCTAssertEqual(FitnessPerformanceTarget.targetStatus(current: 21, lowerBound: 20, upperBound: 20), .above)

        let calibrating = FitnessPerformanceTarget(state: .calibrating(reason: "Waiting for source calibration"))
        XCTAssertNil(calibrating.targetStatus)

        let unavailable = FitnessPerformanceTarget(state: .unavailable(reason: "No source target"))
        XCTAssertNil(unavailable.targetStatus)
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

    func testActivityMetricKeepsPartialAndStaleValuesDistinctFromUnavailable() {
        let partial = FitnessActivityMetric(
            id: "cardio-load",
            title: "Cardio load",
            state: .partial(
                value: 42,
                unit: .sourceDefined,
                window: "Rolling 30 days",
                provenance: "Helio Strap → Zepp → HealthKit"
            )
        )
        XCTAssertEqual(partial.value, 42)
        XCTAssertEqual(partial.statusLabel, "Partial")

        let stale = FitnessActivityMetric(
            id: "cardio-load",
            title: "Cardio load",
            state: .stale(
                value: 38,
                unit: .sourceDefined,
                window: "Rolling 30 days",
                provenance: "HealthKit retained observation"
            )
        )
        XCTAssertEqual(stale.value, 38)
        XCTAssertEqual(stale.statusLabel, "Stale")

        let permission = FitnessActivityMetric(
            id: "cardio-load",
            title: "Cardio load",
            state: .permissionRequired(reason: "HealthKit permission is required.")
        )
        XCTAssertNil(permission.value)
        XCTAssertEqual(permission.statusLabel, "Permission required")
    }

    func testPerformanceTargetRetainsIndependentSourceState() {
        let stale = FitnessPerformanceTarget(
            state: .observed(
                current: 24,
                deviationPercent: -12,
                lowerBound: 20,
                upperBound: 40,
                window: "Rolling 30 days",
                provenance: "HealthKit retained target"
            ),
            sourceState: .stale
        )
        XCTAssertEqual(stale.sourceState, .stale)
        XCTAssertEqual(stale.targetStatus, .within)

        let conflict = FitnessPerformanceTarget(
            state: .unavailable(reason: "Two target revisions disagree."),
            series: [FitnessActivitySeriesPoint(date: Date(timeIntervalSinceReferenceDate: 1), value: 24)],
            sourceState: .conflict
        )
        XCTAssertEqual(conflict.sourceState, .conflict)
        XCTAssertNil(conflict.targetStatus)
        XCTAssertTrue(conflict.series.isEmpty)
    }
}
