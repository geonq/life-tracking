import XCTest
@testable import LifeOS

final class LifeOSBarChartTests: XCTestCase {
    private func mondayFirstCalendar() -> Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        calendar.firstWeekday = 2 // Monday
        return calendar
    }

    private func date(_ calendar: Calendar, _ year: Int, _ month: Int, _ day: Int, _ hour: Int = 0) -> Date {
        var components = DateComponents()
        components.year = year
        components.month = month
        components.day = day
        components.hour = hour
        components.timeZone = calendar.timeZone
        return calendar.date(from: components)!
    }

    // MARK: - Week start derivation

    func testWeekStartComesFromCalendarFirstWeekdayNotHardcodedMonday() {
        let mondayCalendar = mondayFirstCalendar()
        var sundayCalendar = mondayCalendar
        sundayCalendar.firstWeekday = 1 // Sunday

        // 2026-01-07 is a Wednesday.
        let wednesday = date(mondayCalendar, 2026, 1, 7)

        let mondayBuckets = LifeOSBarChartKit.weeklyBuckets(
            observations: [],
            calendar: mondayCalendar,
            displayRange: wednesday..<wednesday.addingTimeInterval(1),
            coverageRange: wednesday..<wednesday.addingTimeInterval(1),
            now: wednesday
        )
        let sundayBuckets = LifeOSBarChartKit.weeklyBuckets(
            observations: [],
            calendar: sundayCalendar,
            displayRange: wednesday..<wednesday.addingTimeInterval(1),
            coverageRange: wednesday..<wednesday.addingTimeInterval(1),
            now: wednesday
        )

        XCTAssertEqual(mondayBuckets.count, 1)
        XCTAssertEqual(sundayBuckets.count, 1)
        // 2026-01-05 is the Monday of that week; 2026-01-04 is the Sunday.
        XCTAssertEqual(mondayBuckets[0].weekStart, date(mondayCalendar, 2026, 1, 5))
        XCTAssertEqual(sundayBuckets[0].weekStart, date(sundayCalendar, 2026, 1, 4))
        XCTAssertNotEqual(
            mondayBuckets[0].weekStart, sundayBuckets[0].weekStart,
            "Changing the calendar's firstWeekday must change the bucket boundary, proving it isn't hardcoded"
        )
    }

    // MARK: - Boundary correctness (the explicit test the spec demands)

    func testValueExactlyOnWeekBoundaryLandsInNextWeekNotDroppedNorDoubleCounted() {
        let calendar = mondayFirstCalendar()
        let week0Start = date(calendar, 2026, 1, 5) // Monday
        let week1Start = date(calendar, 2026, 1, 12) // next Monday == week0's exclusive end

        let observations = [
            LifeOSMoneyObservation(timestamp: week0Start.addingTimeInterval(3_600), cents: 100),
            // Exactly on the boundary: must count toward week1, never week0.
            LifeOSMoneyObservation(timestamp: week1Start, cents: 250),
        ]

        let buckets = LifeOSBarChartKit.weeklyBuckets(
            observations: observations,
            calendar: calendar,
            displayRange: week0Start..<week1Start.addingTimeInterval(7 * 86_400),
            coverageRange: week0Start..<week1Start.addingTimeInterval(7 * 86_400),
            now: week1Start.addingTimeInterval(7 * 86_400)
        )

        XCTAssertEqual(buckets.count, 2)
        XCTAssertEqual(buckets[0].weekEnd, week1Start, "Bucket boundaries must be contiguous, half-open")
        XCTAssertEqual(buckets[0].totalCents, 100, "The boundary value must not be double-counted into week0")
        XCTAssertEqual(buckets[1].totalCents, 250, "The boundary value must not be dropped — it belongs to week1")
    }

    // MARK: - Honest empty vs. observed zero (the single most important requirement)

    func testWeekOutsideCoverageIsNilNotZero() {
        let calendar = mondayFirstCalendar()
        let week0Start = date(calendar, 2026, 1, 5)
        let week1Start = date(calendar, 2026, 1, 12)
        let displayEnd = week1Start.addingTimeInterval(7 * 86_400)

        // Coverage only starts at week1 — week0 has no known data at all.
        let buckets = LifeOSBarChartKit.weeklyBuckets(
            observations: [],
            calendar: calendar,
            displayRange: week0Start..<displayEnd,
            coverageRange: week1Start..<displayEnd,
            now: displayEnd
        )

        XCTAssertEqual(buckets.count, 2)
        XCTAssertNil(buckets[0].totalCents, "Week outside coverage must be nil, never a zero-height bar")
        XCTAssertTrue(buckets[0].isUnavailable)
        XCTAssertEqual(buckets[1].totalCents, 0, "Week inside coverage with no matching observations is a real, observed zero")
        XCTAssertFalse(buckets[1].isUnavailable)

        let normalized = LifeOSBarChartKit.normalizedBuckets(from: buckets)
        XCTAssertNil(normalized[0].height, "A nil bucket must normalize to a nil height, not 0")
        XCTAssertTrue(normalized[0].isGap)
        XCTAssertEqual(normalized[1].height, 0, "An observed zero renders as an explicit zero-height bar, distinct from a gap")
        XCTAssertFalse(normalized[1].isGap)
    }

    // MARK: - Partial vs. complete week

    func testCurrentWeekContainingNowIsIncompleteWhilePastWeekIsComplete() {
        let calendar = mondayFirstCalendar()
        let week0Start = date(calendar, 2026, 1, 5)
        let week1Start = date(calendar, 2026, 1, 12)
        let now = week1Start.addingTimeInterval(2 * 86_400) // Wednesday of week1

        let buckets = LifeOSBarChartKit.weeklyBuckets(
            observations: [],
            calendar: calendar,
            displayRange: week0Start..<week1Start.addingTimeInterval(7 * 86_400),
            coverageRange: week0Start..<week1Start.addingTimeInterval(7 * 86_400),
            now: now
        )

        XCTAssertEqual(buckets.count, 2)
        XCTAssertTrue(buckets[0].isComplete, "A fully elapsed week must be marked complete")
        XCTAssertFalse(buckets[1].isComplete, "The week containing `now` is still accumulating and must not read as complete")
    }

    // MARK: - Normalization scaling

    func testNormalizedHeightsScaleAgainstMaximumObservedTotal() throws {
        let calendar = mondayFirstCalendar()
        let week0Start = date(calendar, 2026, 1, 5)
        let week1Start = date(calendar, 2026, 1, 12)
        let displayEnd = week1Start.addingTimeInterval(7 * 86_400)

        let observations = [
            LifeOSMoneyObservation(timestamp: week0Start.addingTimeInterval(3_600), cents: 400),
            LifeOSMoneyObservation(timestamp: week1Start.addingTimeInterval(3_600), cents: 200),
        ]

        let buckets = LifeOSBarChartKit.weeklyBuckets(
            observations: observations,
            calendar: calendar,
            displayRange: week0Start..<displayEnd,
            coverageRange: week0Start..<displayEnd,
            now: displayEnd
        )
        let normalized = LifeOSBarChartKit.normalizedBuckets(from: buckets)

        let height0 = try XCTUnwrap(normalized[0].height)
        let height1 = try XCTUnwrap(normalized[1].height)
        XCTAssertEqual(height0, 1.0, accuracy: 0.0001)
        XCTAssertEqual(height1, 0.5, accuracy: 0.0001)
        XCTAssertEqual(normalized[0].x, 0.0, accuracy: 0.0001)
        XCTAssertEqual(normalized[1].x, 1.0, accuracy: 0.0001)
    }

    // MARK: - Selection parity with the line chart

    func testSelectionSnapsToContainingBucketAndFlagsUnavailableWeekAsNoData() {
        let calendar = mondayFirstCalendar()
        let week0Start = date(calendar, 2026, 1, 5)
        let week1Start = date(calendar, 2026, 1, 12)
        let displayEnd = week1Start.addingTimeInterval(7 * 86_400)

        let observations = [
            LifeOSMoneyObservation(timestamp: week1Start.addingTimeInterval(3_600), cents: 500),
        ]

        let buckets = LifeOSBarChartKit.weeklyBuckets(
            observations: observations,
            calendar: calendar,
            displayRange: week0Start..<displayEnd,
            coverageRange: week1Start..<displayEnd, // week0 unavailable
            now: displayEnd
        )

        let insideAvailableWeek = LifeOSBarChartKit.nearestSelection(
            in: buckets,
            seriesID: "income",
            to: week1Start.addingTimeInterval(3_600)
        )
        guard case .selected(let datum) = insideAvailableWeek else {
            return XCTFail("Expected a selected datum inside the available week")
        }
        XCTAssertEqual(datum.bucket.weekStart, week1Start)
        XCTAssertEqual(datum.bucket.totalCents, 500)
        XCTAssertEqual(datum.seriesID, "income")

        let insideUnavailableWeek = LifeOSBarChartKit.nearestSelection(
            in: buckets,
            seriesID: "income",
            to: week0Start.addingTimeInterval(3_600)
        )
        guard case .noData(let noData) = insideUnavailableWeek else {
            return XCTFail("Expected no-data for a request landing inside an unavailable week")
        }
        XCTAssertEqual(noData.reason, .explicitGap)
        XCTAssertEqual(noData.seriesID, "income")
    }

    func testSelectionOnEmptyBucketListReturnsNoValidData() {
        let result = LifeOSBarChartKit.nearestSelection(in: [], seriesID: "income", to: Date())
        guard case .noData(let noData) = result else {
            return XCTFail("Expected no-data when there are no buckets at all")
        }
        XCTAssertEqual(noData.reason, .noValidData)
    }
}
