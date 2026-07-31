import XCTest
@testable import LifeOS

final class CalendarHolidayTests: XCTestCase {
    private var calendar: Calendar {
        var value = Calendar(identifier: .gregorian)
        value.timeZone = TimeZone(identifier: "Europe/Berlin")!
        return value
    }

    func testBerlinIncludesRegionalAndGermanPublicHolidays() throws {
        let holidays = CalendarHolidayCatalog.holidays(year: 2026, regions: [.berlin], calendar: calendar)
        XCTAssertTrue(holidays.contains { $0.name == "International Women's Day" && calendar.component(.month, from: $0.date) == 3 })
        XCTAssertTrue(holidays.contains { $0.name == "German Unity Day" && calendar.component(.day, from: $0.date) == 3 })
        XCTAssertTrue(holidays.contains { $0.name == "Easter Monday" })
    }

    func testUSIncludesFederalHolidays() throws {
        let holidays = CalendarHolidayCatalog.holidays(year: 2026, regions: [.unitedStates], calendar: calendar)
        let thanksgiving = try XCTUnwrap(holidays.first { $0.name == "Thanksgiving" })
        XCTAssertEqual(calendar.component(.weekday, from: thanksgiving.date), 5)
        XCTAssertEqual(calendar.component(.month, from: thanksgiving.date), 11)
        XCTAssertTrue(holidays.contains { $0.name == "Juneteenth" })
    }

    func testCombinedRegionsDeduplicateSharedHolidays() {
        let holidays = CalendarHolidayCatalog.holidays(year: 2026, regions: [.berlin, .unitedStates], calendar: calendar)
        let newYears = holidays.filter { $0.name == "New Year's Day" }
        XCTAssertEqual(newYears.count, 1)
        XCTAssertEqual(newYears.first?.regions, Set([.berlin, .unitedStates]))
    }

    func testUnsupportedYearFailsClosedWithoutCrashing() {
        XCTAssertTrue(
            CalendarHolidayCatalog.holidays(
                year: Int.max,
                regions: [.berlin, .unitedStates],
                calendar: calendar
            ).isEmpty
        )
    }
}
