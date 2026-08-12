import Foundation
import XCTest
@testable import LifeOS

final class FitnessStressDomainTests: XCTestCase {
    private let evidence = FitnessStressEvidence(state: .observed(
        source: "HealthKit",
        device: "Helio Strap",
        window: "Selected day",
        freshness: "12 minutes ago"
    ))

    func testDistributionRejectsBucketsThatDoNotReconcile() {
        let distribution = FitnessStressDistribution(state: .observed(
            totalSeconds: 600,
            durations: [.low: 300, .medium: 200, .high: 50],
            labels: nil,
            provenance: "HealthKit source duration"
        ))

        XCTAssertTrue(distribution.isUnavailable)
        XCTAssertNil(distribution.totalObservedSeconds)
    }

    func testDistributionKeepsExactDurationAndPercentages() {
        let distribution = FitnessStressDistribution(state: .observed(
            totalSeconds: 1_000,
            durations: [.low: 250, .medium: 500, .high: 250],
            labels: nil,
            provenance: "HealthKit source duration"
        ))

        XCTAssertEqual(distribution.totalObservedSeconds, 1_000)
        XCTAssertEqual(distribution.duration(for: FitnessStressBand.low), 250)
        XCTAssertEqual(distribution.duration(for: FitnessStressBand.medium), 500)
        XCTAssertEqual(distribution.duration(for: FitnessStressBand.high), 250)
        XCTAssertEqual(
            FitnessStressBand.allCases.compactMap(distribution.percentage(for:)).reduce(0, +),
            1,
            accuracy: 0.0001
        )
    }

    func testAbsentSubtypesStayUnavailableAndAreNeverCopiedFromOverall() {
        let start = Date(timeIntervalSinceReferenceDate: 10_000)
        let overallSample = FitnessStressSample(timestamp: start, value: 32)!
        let day = FitnessStressDay(
            date: start,
            stress: FitnessStressMetric(
                title: "Stress",
                value: 32,
                unit: "score",
                state: evidence.state,
                evidence: evidence
            ),
            overall: FitnessStressSeries(kind: .overall, samples: [overallSample], evidence: evidence)
        )

        XCTAssertFalse(day.overall.isUnavailable)
        XCTAssertTrue(day.nonActivity.isUnavailable)
        XCTAssertTrue(day.sleep.isUnavailable)
        XCTAssertTrue(day.series(for: .nonActivity).samples.isEmpty)
        XCTAssertTrue(day.series(for: .sleep).samples.isEmpty)
    }

    func testTrendRangesOnlyExistForNamedSuppliedWindows() {
        let date = Date(timeIntervalSinceReferenceDate: 20_000)
        let point = FitnessStressDailyPoint(date: date, state: .observed(value: 30))
        let window = FitnessStressTrendWindow(
            kind: .overall,
            range: .seven,
            sourceWindow: "Named 7-day source window",
            points: [point],
            evidence: evidence
        )
        let snapshot = FitnessStressSnapshot(trendWindows: [.overall: [window]])

        XCTAssertEqual(snapshot.windows(for: .overall).map(\.range), [.seven])
        XCTAssertNil(snapshot.window(for: .overall, range: .thirty))
        XCTAssertTrue(snapshot.windows(for: .sleep).isEmpty)
    }

    func testCoverageDistinguishesUnavailableFromExplicitZero() {
        let date = Date(timeIntervalSinceReferenceDate: 30_000)
        let unavailable = FitnessStressCoverageDay(date: date, state: .unavailable(reason: "Permission denied"))
        let zero = FitnessStressCoverageDay(date: date.addingTimeInterval(86_400), state: .zeroObserved)

        XCTAssertFalse(unavailable.isAvailable)
        XCTAssertFalse(unavailable.isZeroObserved)
        XCTAssertTrue(zero.isAvailable)
        XCTAssertTrue(zero.isZeroObserved)
    }

    func testSelectedDateLookupDoesNotFallBackToAnotherDay() {
        let first = FitnessStressDay.unavailable(for: Date(timeIntervalSinceReferenceDate: 40_000))
        let secondDate = first.date.addingTimeInterval(86_400)
        let snapshot = FitnessStressSnapshot(days: [first])

        XCTAssertNotNil(snapshot.day(for: first.date))
        XCTAssertNil(snapshot.day(for: secondDate))
    }

    func testStaleAndDemoStatesRemainExplicit() {
        let stale = FitnessStressEvidence(state: .stale(
            source: "HealthKit", device: "Helio Strap", window: "7 days", freshness: "Older than freshness window"
        ))
        let demo = FitnessStressEvidence(state: .demo(
            source: "DEMO · NOT LIVE", device: "Visual fixture", window: "Selected day", freshness: "Fixture timestamp"
        ))

        XCTAssertTrue(stale.isStale)
        XCTAssertFalse(stale.isDemo)
        XCTAssertTrue(demo.isDemo)
        XCTAssertFalse(demo.isUnavailable)
    }

    func testEvidenceSummaryAndDemoSamplesRetainTheirValuesAndIDs() {
        XCTAssertEqual(evidence.summary, "HealthKit · Helio Strap · Selected day · 12 minutes ago")

        let demo = FitnessStressSnapshot.demo
        let samples = demo.days.first?.overall.samples ?? []
        XCTAssertEqual(samples.count, 18)
        XCTAssertEqual(Set(samples.map(\.id)).count, samples.count)
        XCTAssertTrue(samples.allSatisfy { $0.id.hasPrefix("demo-overall-") })
        XCTAssertTrue(demo.days.first?.coaching.provenanceSummary?.contains("source-authored copy fixture") == true)
    }
}
