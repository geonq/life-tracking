import Foundation

public struct CalendarEventPlacement: Identifiable, Equatable, Sendable {
    public let id: UUID
    public let item: CalendarItem
    public let visibleStart: Date
    public let visibleEnd: Date
    public let column: Int
    public let columnCount: Int
    public let yStart: Double
    public let yEnd: Double

    public init(
        item: CalendarItem,
        visibleStart: Date,
        visibleEnd: Date,
        column: Int,
        columnCount: Int,
        interval: DateInterval
    ) {
        self.id = item.id
        self.item = item
        self.visibleStart = visibleStart
        self.visibleEnd = visibleEnd
        self.column = column
        self.columnCount = max(1, columnCount)
        let duration = interval.duration
        if duration > 0 {
            self.yStart = min(1, max(0, visibleStart.timeIntervalSince(interval.start) / duration))
            self.yEnd = min(1, max(0, visibleEnd.timeIntervalSince(interval.start) / duration))
        } else {
            self.yStart = 0
            self.yEnd = 0
        }
    }
}

public enum CalendarOverlapLayout {
    private struct VisibleEvent {
        let item: CalendarItem
        let start: Date
        let end: Date
    }

    private struct ColumnEvent {
        let event: VisibleEvent
        let column: Int
    }

    /// Places events into the smallest available side-by-side columns. Events
    /// that only touch at an endpoint do not overlap and may reuse a column.
    public static func layout(items: [CalendarItem], interval: DateInterval) -> [CalendarEventPlacement] {
        guard interval.duration > 0 else { return [] }

        let visible = items
            .filter { !$0.isDeleted && $0.start < interval.end && $0.end > interval.start }
            .map {
                VisibleEvent(
                    item: $0,
                    start: max($0.start, interval.start),
                    end: min($0.end, interval.end)
                )
            }
            .sorted {
                if $0.start != $1.start { return $0.start < $1.start }
                if $0.end != $1.end { return $0.end > $1.end }
                return $0.item.id.uuidString < $1.item.id.uuidString
            }

        var output: [CalendarEventPlacement] = []
        var index = 0

        while index < visible.count {
            var groupEnd = visible[index].end
            var groupEndIndex = index + 1
            while groupEndIndex < visible.count, visible[groupEndIndex].start < groupEnd {
                groupEnd = max(groupEnd, visible[groupEndIndex].end)
                groupEndIndex += 1
            }

            let group = Array(visible[index..<groupEndIndex])
            var columnEnds: [Date] = []
            var assigned: [ColumnEvent] = []

            for event in group {
                if let available = columnEnds.firstIndex(where: { $0 <= event.start }) {
                    columnEnds[available] = event.end
                    assigned.append(ColumnEvent(event: event, column: available))
                } else {
                    let column = columnEnds.count
                    columnEnds.append(event.end)
                    assigned.append(ColumnEvent(event: event, column: column))
                }
            }

            let columnCount = max(1, columnEnds.count)
            output.append(contentsOf: assigned.map {
                CalendarEventPlacement(
                    item: $0.event.item,
                    visibleStart: $0.event.start,
                    visibleEnd: $0.event.end,
                    column: $0.column,
                    columnCount: columnCount,
                    interval: interval
                )
            })
            index = groupEndIndex
        }

        return output
    }
}

public enum CalendarDateRange {
    public static func days(containing anchor: Date, count: Int, calendar: Calendar = .current) -> [Date] {
        guard count > 0 else { return [] }
        let start = calendar.startOfDay(for: anchor)
        return (0..<count).compactMap { calendar.date(byAdding: .day, value: $0, to: start) }
    }

    public static func week(containing anchor: Date, calendar: Calendar = .current) -> [Date] {
        let start = calendar.dateInterval(of: .weekOfYear, for: anchor)?.start ?? calendar.startOfDay(for: anchor)
        return (0..<7).compactMap { calendar.date(byAdding: .day, value: $0, to: start) }
    }

    public static func monthGrid(containing anchor: Date, calendar: Calendar = .current) -> [Date] {
        guard let month = calendar.dateInterval(of: .month, for: anchor),
              let weekStart = calendar.dateInterval(of: .weekOfYear, for: month.start)?.start,
              let lastMoment = calendar.date(byAdding: .second, value: -1, to: month.end),
              let finalWeek = calendar.dateInterval(of: .weekOfYear, for: lastMoment),
              let gridEnd = calendar.date(byAdding: .day, value: 7, to: finalWeek.start)
        else { return [] }

        var days: [Date] = []
        var day = weekStart
        while day < gridEnd {
            days.append(day)
            guard let next = calendar.date(byAdding: .day, value: 1, to: day) else { break }
            day = next
        }
        return days
    }
}

public enum CalendarMonthCellPresentation {
    public static func visibleEventLimit(isCompact: Bool) -> Int {
        isCompact ? 1 : 3
    }

    public static func overflowCount(total: Int, visible: Int) -> Int {
        max(0, total - max(0, visible))
    }
}
