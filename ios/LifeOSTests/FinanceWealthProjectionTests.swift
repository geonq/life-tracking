import Foundation
import XCTest
@testable import LifeOS

final class FinanceWealthProjectionTests: XCTestCase {
    private let referenceDate = Date(timeIntervalSince1970: 1_786_449_600)

    private func point(daysFromReference: Int, valueCents: Int) -> FinanceWealthObservationPoint {
        FinanceWealthObservationPoint(
            date: referenceDate.addingTimeInterval(Double(daysFromReference) * 86_400),
            valueCents: valueCents
        )
    }

    // MARK: 1. Insufficient history is refused, never a fabricated trend

    func testFewerThanMinimumPointsIsInsufficientHistory() {
        let observations = [point(daysFromReference: 0, valueCents: 100_000)]
        let result = FinanceWealthProjector.project(observations: observations, horizonDays: 30)
        XCTAssertEqual(result, .insufficientHistory(pointsProvided: 1, minimumRequired: FinanceWealthProjector.minimumHistoryPointCount))
    }

    func testEmptyHistoryIsInsufficientHistory() {
        let result = FinanceWealthProjector.project(observations: [], horizonDays: 30)
        XCTAssertEqual(result, .insufficientHistory(pointsProvided: 0, minimumRequired: FinanceWealthProjector.minimumHistoryPointCount))
    }

    // MARK: 2. Minimum point count projects successfully

    func testExactlyMinimumPointCountProjects() {
        let observations = [
            point(daysFromReference: 0, valueCents: 100_000),
            point(daysFromReference: 10, valueCents: 110_000),
            point(daysFromReference: 20, valueCents: 120_000)
        ]
        guard case .projected(let projection) = FinanceWealthProjector.project(observations: observations, horizonDays: 10) else {
            return XCTFail("expected a projection")
        }
        XCTAssertEqual(projection.basedOnPointCount, 3)
    }

    // MARK: 3. Projection is never mistakeable for an observation (distinct type)

    func testProjectionIsADistinctTypeFromObservation() {
        let observations = [
            point(daysFromReference: 0, valueCents: 100_000),
            point(daysFromReference: 10, valueCents: 110_000),
            point(daysFromReference: 20, valueCents: 120_000)
        ]
        guard case .projected(let projection) = FinanceWealthProjector.project(observations: observations, horizonDays: 10) else {
            return XCTFail("expected a projection")
        }
        // The type itself (FinanceWealthProjection) is not
        // FinanceWealthObservationPoint or any FinanceDomain observed-wealth
        // type -- this compiles only because they are unrelated types.
        let isObservationPoint = projection is FinanceWealthObservationPoint
        XCTAssertFalse(isObservationPoint)
    }

    // MARK: 4. Exact linear trend projects the exact expected value

    func testExactLinearTrendProjectsExpectedValue() {
        // Value increases by exactly 1_000 cents per day.
        let observations = [
            point(daysFromReference: 0, valueCents: 100_000),
            point(daysFromReference: 1, valueCents: 101_000),
            point(daysFromReference: 2, valueCents: 102_000),
            point(daysFromReference: 3, valueCents: 103_000)
        ]
        guard case .projected(let projection) = FinanceWealthProjector.project(observations: observations, horizonDays: 10) else {
            return XCTFail("expected a projection")
        }
        // Last observed day is day 3 at 103_000; +10 days at +1_000/day = 113_000.
        XCTAssertEqual(projection.projectedValueCents, 113_000)
        XCTAssertEqual(projection.displayRoundedValueCents, 113_000)
    }

    // MARK: 5. Integer-cents exactness: display rounding never touches the exact value

    func testDisplayRoundingDoesNotAlterExactValue() {
        let observations = [
            point(daysFromReference: 0, valueCents: 100_003),
            point(daysFromReference: 1, valueCents: 100_057),
            point(daysFromReference: 2, valueCents: 100_111)
        ]
        guard case .projected(let projection) = FinanceWealthProjector.project(observations: observations, horizonDays: 1) else {
            return XCTFail("expected a projection")
        }
        // Exact value must never be silently replaced by the rounded display value.
        XCTAssertNotEqual(projection.projectedValueCents, projection.displayRoundedValueCents)
        XCTAssertEqual(projection.displayRoundedValueCents % 100, 0)
    }

    // MARK: 6. Degenerate history: all points share one timestamp

    func testAllPointsAtSameTimestampIsDegenerateHistory() {
        let observations = [
            point(daysFromReference: 0, valueCents: 100_000),
            point(daysFromReference: 0, valueCents: 101_000),
            point(daysFromReference: 0, valueCents: 99_000)
        ]
        let result = FinanceWealthProjector.project(observations: observations, horizonDays: 30)
        XCTAssertEqual(result, .degenerateHistory)
    }

    // MARK: 7. Invalid horizon is refused

    func testNonPositiveHorizonIsInvalid() {
        let observations = [
            point(daysFromReference: 0, valueCents: 100_000),
            point(daysFromReference: 1, valueCents: 101_000),
            point(daysFromReference: 2, valueCents: 102_000)
        ]
        XCTAssertEqual(FinanceWealthProjector.project(observations: observations, horizonDays: 0), .invalidHorizon)
        XCTAssertEqual(FinanceWealthProjector.project(observations: observations, horizonDays: -5), .invalidHorizon)
    }

    // MARK: 8. Determinism and order-independence of input

    func testProjectionIsDeterministicRegardlessOfInputOrder() {
        let ordered = [
            point(daysFromReference: 0, valueCents: 100_000),
            point(daysFromReference: 5, valueCents: 105_000),
            point(daysFromReference: 10, valueCents: 110_000)
        ]
        let shuffled = [ordered[2], ordered[0], ordered[1]]

        let first = FinanceWealthProjector.project(observations: ordered, horizonDays: 15)
        let second = FinanceWealthProjector.project(observations: shuffled, horizonDays: 15)
        XCTAssertEqual(first, second)
    }

    // MARK: 9. asOfDate tracks the latest observation, not "now"

    func testAsOfDateIsTheLatestObservationDate() {
        let observations = [
            point(daysFromReference: 0, valueCents: 100_000),
            point(daysFromReference: 5, valueCents: 105_000),
            point(daysFromReference: 12, valueCents: 112_000)
        ]
        guard case .projected(let projection) = FinanceWealthProjector.project(observations: observations, horizonDays: 30) else {
            return XCTFail("expected a projection")
        }
        XCTAssertEqual(projection.asOfDate, referenceDate.addingTimeInterval(12 * 86_400))
        XCTAssertEqual(projection.targetDate, referenceDate.addingTimeInterval(42 * 86_400))
    }
}
