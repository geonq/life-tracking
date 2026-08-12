import Foundation
import XCTest
@testable import LifeOS

final class FitnessBiologyDomainTests: XCTestCase {
    private let anchor = Date(timeIntervalSince1970: 1_754_000_000)

    func testDefaultSnapshotKeepsAllSixMetricsIndependentlyUnavailable() {
        let snapshot = FitnessBiologySnapshot.unavailable
        XCTAssertEqual(snapshot.metrics.map(\.id), FitnessBiologyMetricID.allCases)
        XCTAssertTrue(snapshot.metrics.allSatisfy { metric in
            if case .unavailable = metric.state { return true }
            return false
        })
        XCTAssertFalse(snapshot.biologicalAge.isReviewedAndDisplayable)
    }

    func testUnavailableAndCalibratingReasonsTrimAndUseFallbackWhenAbsent() {
        let unavailable = FitnessBiologyMetric.unavailable(.weight, reason: "  Sensor is still syncing.  ")
        let missing = FitnessBiologyMetric.unavailable(.hrvBaseline)
        let calibrating = FitnessBiologyMetric.calibrating(.rhrBaseline, reason: "   ")

        if case .unavailable(let reason) = unavailable.state {
            XCTAssertEqual(reason, "Sensor is still syncing.")
        } else {
            XCTFail("Expected an unavailable metric")
        }
        if case .unavailable(let reason) = missing.state {
            XCTAssertEqual(reason, "No source observation is available.")
        } else {
            XCTFail("Expected an unavailable metric")
        }
        if case .calibrating(let reason) = calibrating.state {
            XCTAssertEqual(reason, "Source calibration is incomplete.")
        } else {
            XCTFail("Expected a calibrating metric")
        }
    }

    func testObservedMetricRetainsUnitSourceCountFreshnessWindowAndTrend() throws {
        let first = try XCTUnwrap(FitnessBiologySample(date: anchor.addingTimeInterval(-86_400), value: 51))
        let second = try XCTUnwrap(FitnessBiologySample(date: anchor, value: 54))
        let metric = FitnessBiologyMetric(
            id: .hrvBaseline,
            state: .observed(
                value: 54,
                unit: .milliseconds,
                sourceDevice: "Helio Strap",
                sampleCount: 18,
                freshness: "Fresh · 2h ago",
                window: "Last 30 days",
                provenance: "Helio Strap → Zepp → HealthKit",
                samples: [first, second]
            )
        )

        XCTAssertEqual(metric.currentValue, 54)
        XCTAssertEqual(metric.unit, .milliseconds)
        XCTAssertEqual(metric.sourceDevice, "Helio Strap")
        XCTAssertEqual(metric.sampleCount, 18)
        XCTAssertEqual(metric.freshness, "Fresh · 2h ago")
        XCTAssertEqual(metric.window, "Last 30 days")
        XCTAssertEqual(metric.provenance, "Helio Strap → Zepp → HealthKit")
        XCTAssertEqual(metric.samples, [first, second])
    }

    func testEachMetricRejectsInvalidValueUnitCountAndMetadata() {
        let invalidValues: [(FitnessBiologyMetricID, Double)] = [
            (.weight, .infinity),
            (.hrvBaseline, 0),
            (.rhrBaseline, 300),
            (.bodyFat, -1),
            (.fatFreeMass, 0),
            (.vo2Max, 200)
        ]
        for (id, value) in invalidValues {
            let metric = FitnessBiologyMetric(
                id: id,
                state: .observed(
                    value: value,
                    unit: id.unit,
                    sourceDevice: "Helio Strap",
                    sampleCount: 1,
                    freshness: "Fresh",
                    window: "Last 30 days",
                    provenance: "HealthKit",
                    samples: []
                )
            )
            guard case .unavailable = metric.state else {
                return XCTFail("Expected \(id.rawValue) to reject invalid value")
            }
        }

        let wrongUnit = FitnessBiologyMetric(
            id: .weight,
            state: .observed(value: 80, unit: .percent, sourceDevice: "Helio Strap", sampleCount: 1, freshness: "Fresh", window: "Last 30 days", provenance: "HealthKit", samples: [])
        )
        if case .unavailable = wrongUnit.state {} else { XCTFail("A metric must reject a mismatched unit") }

        let missingMetadata = FitnessBiologyMetric(
            id: .weight,
            state: .observed(value: 80, unit: .kilograms, sourceDevice: " ", sampleCount: 0, freshness: "", window: "", provenance: "", samples: [])
        )
        if case .unavailable = missingMetadata.state {} else { XCTFail("Missing provenance must remain unavailable") }
    }

    func testSamplesRejectNonFiniteAndOutOfBoundsTimestamps() {
        XCTAssertNil(FitnessBiologySample(date: anchor, value: .nan))
        XCTAssertNil(FitnessBiologySample(date: anchor, value: -2))
        XCTAssertNil(FitnessBiologySample(date: .distantPast, value: 80))
        XCTAssertNil(FitnessBiologySample(date: .distantFuture, value: 80))
        XCTAssertNotNil(FitnessBiologySample(date: anchor, value: 80))
    }

    func testRangeFilteringIsDateScopedAndDoesNotInventSamples() throws {
        let samples = try [
            XCTUnwrap(FitnessBiologySample(date: anchor.addingTimeInterval(-9 * 86_400), value: 78)),
            XCTUnwrap(FitnessBiologySample(date: anchor.addingTimeInterval(-6 * 86_400), value: 77.8)),
            XCTUnwrap(FitnessBiologySample(date: anchor, value: 77.5))
        ]
        let metric = FitnessBiologyMetric(
            id: .weight,
            state: .observed(value: 77.5, unit: .kilograms, sourceDevice: "Scale", sampleCount: 3, freshness: "Fresh", window: "Last 30 days", provenance: "HealthKit", samples: samples)
        )
        XCTAssertEqual(metric.samples(for: .sevenDays, endingAt: anchor).map(\.value), [77.8, 77.5])
        XCTAssertEqual(metric.samples(for: .threeDays, endingAt: anchor).map(\.value), [77.5])
    }

    func testBiologicalAgeRequiresAdultAndExplicitReviewedMetadata() {
        let missingModel = FitnessBiologicalAge(state: .observed(value: 32, userAge: 30, reviewedModel: "", reviewedAt: anchor, window: "Last 30 days", provenance: "HealthKit"))
        if case .gated = missingModel.state {} else { XCTFail("Missing reviewed model must gate biological age") }

        let underage = FitnessBiologicalAge(state: .observed(value: 20, userAge: 17, reviewedModel: "LifeOS reviewed model", reviewedAt: anchor, window: "Last 30 days", provenance: "HealthKit"))
        if case .gated = underage.state {} else { XCTFail("Biological age must be adult-gated") }

        let valid = FitnessBiologicalAge(state: .observed(value: 32.4, userAge: 30, reviewedModel: "LifeOS reviewed model v1", reviewedAt: anchor, window: "Last 90 days", provenance: "Helio Strap → HealthKit"))
        XCTAssertTrue(valid.isReviewedAndDisplayable)
        XCTAssertEqual(valid.displayValue, 32.4)
    }

    func testDemoSnapshotHasSixExplicitMetricsButNoBiologicalAgeNumber() {
        let snapshot = FitnessBiologySnapshot.demo(anchor: anchor)
        XCTAssertEqual(snapshot.metrics.count, 6)
        XCTAssertTrue(snapshot.metrics.allSatisfy(\.isDemo))
        XCTAssertTrue(snapshot.metrics.allSatisfy { $0.sampleCount == 7 })
        XCTAssertNil(snapshot.biologicalAge.displayValue)
        XCTAssertFalse(snapshot.biologicalAge.isReviewedAndDisplayable)
    }
}
