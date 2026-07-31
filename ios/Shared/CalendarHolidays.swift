import Foundation

public enum CalendarHolidayRegion: String, Codable, Hashable, Sendable {
    case berlin
    case unitedStates = "united_states"
}

public struct CalendarHoliday: Identifiable, Equatable, Sendable {
    public var id: String { "\(name)-\(date.timeIntervalSince1970)" }
    public let name: String
    public let date: Date
    public let regions: Set<CalendarHolidayRegion>

    public init(name: String, date: Date, regions: Set<CalendarHolidayRegion>) {
        self.name = name
        self.date = date
        self.regions = regions
    }
}

public enum CalendarHolidayCatalog {
    public static func holidays(
        year: Int,
        regions: Set<CalendarHolidayRegion> = [.berlin, .unitedStates],
        calendar: Calendar = .current
    ) -> [CalendarHoliday] {
        guard (1...9_999).contains(year) else { return [] }

        var gregorian = Calendar(identifier: .gregorian)
        gregorian.timeZone = calendar.timeZone
        gregorian.locale = calendar.locale
        var entries: [(String, Date, CalendarHolidayRegion)] = []

        func append(_ name: String, _ day: Date?, _ region: CalendarHolidayRegion) {
            guard let day else { return }
            entries.append((name, day, region))
        }

        if regions.contains(.berlin), let easter = easterSunday(year: year, calendar: gregorian) {
            append("New Year's Day", date(year, 1, 1, gregorian), .berlin)
            append("International Women's Day", date(year, 3, 8, gregorian), .berlin)
            append("Good Friday", adding(days: -2, to: easter, calendar: gregorian), .berlin)
            append("Easter Monday", adding(days: 1, to: easter, calendar: gregorian), .berlin)
            append("Labour Day", date(year, 5, 1, gregorian), .berlin)
            append("Ascension Day", adding(days: 39, to: easter, calendar: gregorian), .berlin)
            append("Whit Monday", adding(days: 50, to: easter, calendar: gregorian), .berlin)
            append("German Unity Day", date(year, 10, 3, gregorian), .berlin)
            append("Christmas Day", date(year, 12, 25, gregorian), .berlin)
            append("Second Day of Christmas", date(year, 12, 26, gregorian), .berlin)
        }

        if regions.contains(.unitedStates) {
            append("New Year's Day", date(year, 1, 1, gregorian), .unitedStates)
            append("Martin Luther King Jr. Day", nthWeekday(2, weekday: 2, month: 1, year: year, calendar: gregorian), .unitedStates)
            append("Washington's Birthday", nthWeekday(3, weekday: 2, month: 2, year: year, calendar: gregorian), .unitedStates)
            append("Memorial Day", lastWeekday(2, month: 5, year: year, calendar: gregorian), .unitedStates)
            append("Juneteenth", date(year, 6, 19, gregorian), .unitedStates)
            append("Independence Day", date(year, 7, 4, gregorian), .unitedStates)
            append("Labor Day", nthWeekday(1, weekday: 2, month: 9, year: year, calendar: gregorian), .unitedStates)
            append("Columbus Day", nthWeekday(2, weekday: 2, month: 10, year: year, calendar: gregorian), .unitedStates)
            append("Veterans Day", date(year, 11, 11, gregorian), .unitedStates)
            append("Thanksgiving", nthWeekday(4, weekday: 5, month: 11, year: year, calendar: gregorian), .unitedStates)
            append("Christmas Day", date(year, 12, 25, gregorian), .unitedStates)
        }

        var merged: [String: CalendarHoliday] = [:]
        for (name, day, region) in entries {
            let start = gregorian.startOfDay(for: day)
            let key = "\(name)|\(start.timeIntervalSince1970)"
            if let existing = merged[key] {
                merged[key] = CalendarHoliday(name: name, date: start, regions: existing.regions.union([region]))
            } else {
                merged[key] = CalendarHoliday(name: name, date: start, regions: [region])
            }
        }
        return merged.values.sorted { $0.date == $1.date ? $0.name < $1.name : $0.date < $1.date }
    }

    private static func date(_ year: Int, _ month: Int, _ day: Int, _ calendar: Calendar) -> Date? {
        calendar.date(from: DateComponents(timeZone: calendar.timeZone, year: year, month: month, day: day))
    }

    private static func adding(days: Int, to date: Date, calendar: Calendar) -> Date? {
        calendar.date(byAdding: .day, value: days, to: date)
    }

    private static func nthWeekday(_ ordinal: Int, weekday: Int, month: Int, year: Int, calendar: Calendar) -> Date? {
        guard let first = date(year, month, 1, calendar) else { return nil }
        let firstWeekday = calendar.component(.weekday, from: first)
        let offset = (weekday - firstWeekday + 7) % 7 + (ordinal - 1) * 7
        return adding(days: offset, to: first, calendar: calendar)
    }

    private static func lastWeekday(_ weekday: Int, month: Int, year: Int, calendar: Calendar) -> Date? {
        let firstNextMonth = month == 12
            ? date(year + 1, 1, 1, calendar)
            : date(year, month + 1, 1, calendar)
        guard let firstNextMonth,
              let last = adding(days: -1, to: firstNextMonth, calendar: calendar) else { return nil }
        let lastWeekday = calendar.component(.weekday, from: last)
        let offset = (lastWeekday - weekday + 7) % 7
        return adding(days: -offset, to: last, calendar: calendar)
    }

    /// Meeus/Jones/Butcher Gregorian Easter algorithm.
    private static func easterSunday(year: Int, calendar: Calendar) -> Date? {
        let a = year % 19
        let b = year / 100
        let c = year % 100
        let d = b / 4
        let e = b % 4
        let f = (b + 8) / 25
        let g = (b - f + 1) / 3
        let h = (19 * a + b - d - g + 15) % 30
        let i = c / 4
        let k = c % 4
        let l = (32 + 2 * e + 2 * i - h - k) % 7
        let m = (a + 11 * h + 22 * l) / 451
        let month = (h + l - 7 * m + 114) / 31
        let day = ((h + l - 7 * m + 114) % 31) + 1
        return date(year, month, day, calendar)
    }
}
