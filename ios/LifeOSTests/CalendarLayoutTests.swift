import XCTest
@testable import LifeOS

final class CalendarLayoutTests: XCTestCase {
    private var calendar: Calendar {
        var value = Calendar(identifier: .gregorian)
        value.timeZone = TimeZone(secondsFromGMT: 0)!
        return value
    }

    private var dayStart: Date {
        DateComponents(calendar: calendar, timeZone: calendar.timeZone, year: 2026, month: 7, day: 31).date!
    }

    private func item(
        _ id: UUID = UUID(),
        title: String,
        start: TimeInterval,
        end: TimeInterval
    ) throws -> CalendarItem {
        try CalendarItem(
            id: id,
            title: title,
            start: dayStart.addingTimeInterval(start),
            end: dayStart.addingTimeInterval(end),
            createdAt: dayStart,
            updatedAt: dayStart
        )
    }

    func testOnlyOverlappingEventsShareAnOverlapGroup() throws {
        let a = try item(title: "A", start: 0, end: 60)
        let b = try item(title: "B", start: 30, end: 90)
        let c = try item(title: "C", start: 90, end: 120)

        let result = CalendarOverlapLayout.layout(
            items: [a, b, c],
            interval: DateInterval(start: dayStart, duration: 120)
        )

        XCTAssertEqual(result.map(\.item.title), ["A", "B", "C"])
        XCTAssertEqual(result.map(\.column), [0, 1, 0])
        XCTAssertEqual(result.map(\.columnCount), [2, 2, 1])
    }

    func testTouchingIntervalsDoNotOverlap() throws {
        let a = try item(title: "A", start: 0, end: 60)
        let b = try item(title: "B", start: 60, end: 120)

        let result = CalendarOverlapLayout.layout(
            items: [a, b],
            interval: DateInterval(start: dayStart, duration: 120)
        )

        XCTAssertEqual(result.map(\.column), [0, 0])
        XCTAssertEqual(result.map(\.columnCount), [1, 1])
    }

    func testEventsAreClippedToVisibleInterval() throws {
        let event = try item(title: "Spanning", start: -3600, end: 3600)
        let visible = DateInterval(start: dayStart, duration: 1800)

        let placement = try XCTUnwrap(CalendarOverlapLayout.layout(items: [event], interval: visible).first)

        XCTAssertEqual(placement.visibleStart, dayStart)
        XCTAssertEqual(placement.visibleEnd, dayStart.addingTimeInterval(1800))
        XCTAssertEqual(placement.yStart, 0, accuracy: 0.0001)
        XCTAssertEqual(placement.yEnd, 1, accuracy: 0.0001)
    }

    func testDeletedItemsAndItemsOutsideIntervalAreExcluded() throws {
        let live = try item(title: "Live", start: 0, end: 60)
        let deleted = live.deleting(at: dayStart.addingTimeInterval(1))
        let later = try item(title: "Later", start: 121, end: 180)

        let result = CalendarOverlapLayout.layout(
            items: [deleted, later],
            interval: DateInterval(start: dayStart, duration: 120)
        )

        XCTAssertTrue(result.isEmpty)
    }

    func testSameStartOrderingIsDeterministic() throws {
        let firstID = UUID(uuidString: "00000000-0000-0000-0000-000000000001")!
        let secondID = UUID(uuidString: "00000000-0000-0000-0000-000000000002")!
        let first = try item(firstID, title: "First", start: 0, end: 60)
        let second = try item(secondID, title: "Second", start: 0, end: 60)

        let result = CalendarOverlapLayout.layout(
            items: [second, first],
            interval: DateInterval(start: dayStart, duration: 120)
        )

        XCTAssertEqual(result.map(\.item.title), ["First", "Second"])
        XCTAssertEqual(result.map(\.column), [0, 1])
    }

    func testThreeSimultaneousEventsUseThreeColumns() throws {
        let events = try [
            item(title: "A", start: 0, end: 120),
            item(title: "B", start: 10, end: 100),
            item(title: "C", start: 20, end: 80)
        ]

        let result = CalendarOverlapLayout.layout(
            items: events,
            interval: DateInterval(start: dayStart, duration: 120)
        )

        XCTAssertEqual(result.map(\.column), [0, 1, 2])
        XCTAssertEqual(result.map(\.columnCount), [3, 3, 3])
    }

    func testDayQueryIncludesOvernightEventOnBothDays() throws {
        let event = try item(title: "Overnight", start: -1800, end: 1800)
        let snapshot = CalendarSnapshot(items: [event])

        XCTAssertEqual(snapshot.items(on: dayStart.addingTimeInterval(-1), calendar: calendar).map(\.title), ["Overnight"])
        XCTAssertEqual(snapshot.items(on: dayStart, calendar: calendar).map(\.title), ["Overnight"])
    }

    func testVisibleDaysHaveExactRequestedCount() {
        XCTAssertEqual(CalendarDateRange.days(containing: dayStart, count: 3, calendar: calendar).count, 3)
        XCTAssertEqual(CalendarDateRange.days(containing: dayStart, count: 7, calendar: calendar).count, 7)
    }

    func testMonthCellPresentationLimitsEventsForCompactColumns() {
        XCTAssertEqual(CalendarMonthCellPresentation.visibleEventLimit(isCompact: true), 1)
        XCTAssertEqual(CalendarMonthCellPresentation.visibleEventLimit(isCompact: false), 3)
        XCTAssertEqual(CalendarMonthCellPresentation.overflowCount(total: 4, visible: 1), 3)
        XCTAssertEqual(CalendarMonthCellPresentation.overflowCount(total: 2, visible: 3), 0)
    }
}
