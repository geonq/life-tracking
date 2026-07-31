import XCTest
@testable import LifeOS

final class CalendarWidgetDateGridTests: XCTestCase {
    func testGridIsSixWeeksAndStartsOnConfiguredWeekStart() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        calendar.firstWeekday = 2 // Monday
        let date = calendar.date(from: DateComponents(year: 2026, month: 8, day: 12))!

        let days = CalendarWidgetDateGrid.days(containing: date, calendar: calendar)

        XCTAssertEqual(days.count, 42)
        XCTAssertEqual(calendar.component(.weekday, from: days[0]), 2)
        XCTAssertTrue(days.contains { calendar.isDate($0, inSameDayAs: date) })
    }
}
