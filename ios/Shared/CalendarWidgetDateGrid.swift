import Foundation

/// Stable six-week month layout shared by the app, widget, and tests.
public enum CalendarWidgetDateGrid {
    public static func days(containing date: Date, calendar: Calendar = .current) -> [Date] {
        let monthStart = calendar.date(from: calendar.dateComponents([.year, .month], from: date)) ?? date
        let weekday = calendar.component(.weekday, from: monthStart)
        let offset = (weekday - calendar.firstWeekday + 7) % 7
        let gridStart = calendar.date(byAdding: .day, value: -offset, to: monthStart) ?? monthStart
        return (0..<42).compactMap { calendar.date(byAdding: .day, value: $0, to: gridStart) }
    }
}
