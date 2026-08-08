import SwiftUI
#if os(iOS)
import UIKit
#else
import AppKit
#endif

public struct CalendarIconView: View {
    let item: CalendarItem
    let size: CGFloat

    public init(item: CalendarItem, size: CGFloat = 28) {
        self.item = item
        self.size = size
    }

    public var body: some View {
        Group {
            if let data = item.iconAsset?.bytes {
#if os(iOS)
                if let image = UIImage(data: data) { Image(uiImage: image).resizable().scaledToFit() } else { Text(item.icon) }
#else
                if let image = NSImage(data: data) { Image(nsImage: image).resizable().scaledToFit() } else { Text(item.icon) }
#endif
            } else { Text(item.icon) }
        }
        .frame(width: size, height: size)
        .clipShape(RoundedRectangle(cornerRadius: max(3, size * 0.21), style: .continuous))
    }
}

public extension CalendarProgress {
    var label: String {
        switch self {
        case .planned: "Planned"
        case .inProgress: "In progress"
        case .done: "Done"
        case .aborted: "Aborted"
        }
    }

    var color: Color {
        switch self {
        case .planned: LifeOSTokens.accent
        case .inProgress: .orange
        case .done: .green
        case .aborted: .red
        }
    }

    var iconName: LifeOSIconName {
        switch self {
        case .planned: .planned
        case .inProgress: .inProgress
        case .done: .done
        case .aborted: .aborted
        }
    }
}

public struct CalendarItemRow: View {
    public let item: CalendarItem
    private static let time: Date.FormatStyle = .dateTime.hour().minute()

    public init(item: CalendarItem) { self.item = item }

    public var body: some View {
        HStack(spacing: 12) {
            CalendarIconView(item: item).accessibilityLabel("Icon \(item.icon)")
            VStack(alignment: .leading, spacing: 4) {
                Text(item.title).font(.headline)
                Text("\(item.start, format: Self.time) – \(item.end, format: Self.time)")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            Circle().fill(item.status.color).frame(width: 9, height: 9)
                .accessibilityLabel(item.status.label)
        }
        .padding(.vertical, 5)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(item.icon) \(item.title), \(item.status.label), \(item.start, format: Self.time) to \(item.end, format: Self.time)")
    }
}

public struct CalendarProgressPicker: View {
    @Binding public var progress: CalendarProgress
    public init(progress: Binding<CalendarProgress>) { _progress = progress }
    public var body: some View {
        Picker("Status", selection: $progress) {
            ForEach(CalendarProgress.allCases, id: \.self) { status in
                Label {
                    Text(status.label)
                } icon: {
                    LifeOSIcon(status.iconName)
                }
                .tag(status)
            }
        }
        .pickerStyle(.menu)
    }
}

public struct CalendarTimelineView: View {
    public let days: [Date]
    public let items: [CalendarItem]
    public let holidays: [CalendarHoliday]
    public let hourHeight: CGFloat
    public let calendar: Calendar
    public let onSelect: (CalendarItem) -> Void

    private let timeGutter: CGFloat = 52
#if os(macOS)
    private let minimumDayWidth: CGFloat = 112
#else
    private let minimumDayWidth: CGFloat = 96
#endif

    public init(days: [Date], items: [CalendarItem], holidays: [CalendarHoliday] = [], hourHeight: CGFloat, calendar: Calendar = .current,
                onSelect: @escaping (CalendarItem) -> Void) {
        self.days = days
        self.items = items
        self.holidays = holidays
        self.hourHeight = hourHeight
        self.calendar = calendar
        self.onSelect = onSelect
    }

    public var body: some View {
        GeometryReader { viewport in
            let contentWidth = max(viewport.size.width, timeGutter + CGFloat(days.count) * minimumDayWidth)
            ScrollView(.horizontal) {
                VStack(spacing: 0) {
                    dayHeader(width: contentWidth)
                    ScrollViewReader { scrollProxy in
                        ScrollView(.vertical) {
                            HStack(alignment: .top, spacing: 0) {
                                hourLabels
                                    .frame(width: timeGutter)
                                ForEach(days, id: \.self) { day in
                                    CalendarDayTimeline(
                                        day: day,
                                        items: items,
                                        hourHeight: hourHeight,
                                        calendar: calendar,
                                        onSelect: onSelect
                                    )
                                    .frame(width: (contentWidth - timeGutter) / CGFloat(max(days.count, 1)))
                                }
                            }
                        }
                        .task(id: days.first) {
                            scrollProxy.scrollTo(initialVisibleHour, anchor: .top)
                        }
                    }
                }
                .frame(width: contentWidth)
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Calendar timeline, \(days.count) days")
    }

    private func dayHeader(width: CGFloat) -> some View {
        HStack(spacing: 0) {
            Color.clear.frame(width: timeGutter, height: 58)
            ForEach(days, id: \.self) { day in
                let dayHolidays = holidays.filter { calendar.isDate($0.date, inSameDayAs: day) }
                VStack(spacing: 2) {
                    Text(day, format: .dateTime.weekday(.abbreviated))
                        .font(.caption.weight(.medium))
                        .foregroundStyle(.secondary)
                    Text(day, format: .dateTime.day())
                        .font(.title3.weight(calendar.isDateInToday(day) ? .bold : .medium))
                        .foregroundStyle(calendar.isDateInToday(day) ? LifeOSTokens.accent : .primary)
                    if let holiday = dayHolidays.first {
                        Text(holiday.name)
                            .font(.system(size: 8, weight: .medium))
                            .foregroundStyle(LifeOSTokens.accent)
                            .lineLimit(1)
                    }
                }
                .frame(width: (width - timeGutter) / CGFloat(max(days.count, 1)), height: 58)
                .background(calendar.isDateInToday(day) ? LifeOSTokens.accent.opacity(0.06) : .clear)
                .overlay(alignment: .trailing) { Rectangle().fill(Color.primary.opacity(0.08)).frame(width: 1) }
            }
        }
        .background(LifeOSTokens.canvas)
        .overlay(alignment: .bottom) { Rectangle().fill(Color.primary.opacity(0.10)).frame(height: 1) }
    }

    private var hourLabels: some View {
        VStack(spacing: 0) {
            ForEach(0..<24, id: \.self) { hour in
                Text(String(format: "%02d:00", hour))
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
                    .padding(.trailing, 8)
                    .id(hour)
            }
        }
        .frame(height: hourHeight * 24)
    }

    /// Starts near the first useful daytime event instead of an empty midnight grid.
    /// Overnight events remain available by scrolling upward.
    private var initialVisibleHour: Int {
        let visibleDayStarts = Set(days.map { calendar.startOfDay(for: $0) })
        let firstDaytimeEventHour = items
            .filter { item in
                visibleDayStarts.contains(calendar.startOfDay(for: item.start)) &&
                    item.end.timeIntervalSince(item.start) <= 12 * 60 * 60
            }
            .map { calendar.component(.hour, from: $0.start) }
            .filter { $0 >= 6 }
            .min()
        return max(0, min(8, (firstDaytimeEventHour ?? 9) - 1))
    }
}

private struct CalendarDayTimeline: View {
    let day: Date
    let items: [CalendarItem]
    let hourHeight: CGFloat
    let calendar: Calendar
    let onSelect: (CalendarItem) -> Void

    private var interval: DateInterval {
        let start = calendar.startOfDay(for: day)
        return DateInterval(start: start, end: calendar.date(byAdding: .day, value: 1, to: start) ?? start.addingTimeInterval(86_400))
    }

    private var placements: [CalendarEventPlacement] {
        CalendarOverlapLayout.layout(items: items, interval: interval)
    }

    var body: some View {
        GeometryReader { proxy in
            let totalHeight = hourHeight * 24
            ZStack(alignment: .topLeading) {
                VStack(spacing: 0) {
                    ForEach(0..<24, id: \.self) { _ in
                        Rectangle()
                            .fill(Color.clear)
                            .frame(height: hourHeight)
                            .overlay(alignment: .top) { Rectangle().fill(Color.primary.opacity(0.075)).frame(height: 1) }
                    }
                }

                ForEach(placements) { placement in
                    let columnWidth = proxy.size.width / CGFloat(max(placement.columnCount, 1))
                    let y = CGFloat(placement.yStart) * totalHeight
                    let rawHeight = CGFloat(placement.yEnd - placement.yStart) * totalHeight
                    Button { onSelect(placement.item) } label: {
                        CalendarTimelineEvent(
                            item: placement.item,
                            compact: rawHeight < 44,
                            narrow: columnWidth < 82,
                            timeZone: calendar.timeZone
                        )
                    }
                    .buttonStyle(.plain)
                    .frame(width: max(24, columnWidth - 3), height: max(24, rawHeight - 2), alignment: .topLeading)
                    .offset(x: CGFloat(placement.column) * columnWidth + 1, y: y + 1)
                    .zIndex(2)
                }

                if calendar.isDateInToday(day) {
                    TimelineView(.periodic(from: .now, by: 60)) { context in
                        let seconds = context.date.timeIntervalSince(interval.start)
                        if seconds >= 0, seconds < interval.duration {
                            HStack(spacing: 0) {
                                Circle().fill(.red).frame(width: 7, height: 7)
                                Rectangle().fill(.red).frame(height: 1)
                            }
                            .offset(x: -3.5, y: CGFloat(seconds / interval.duration) * totalHeight)
                            .zIndex(3)
                        }
                    }
                }
            }
            .frame(height: totalHeight)
            .background(calendar.isDateInToday(day) ? LifeOSTokens.accent.opacity(0.025) : .clear)
            .overlay(alignment: .trailing) { Rectangle().fill(Color.primary.opacity(0.08)).frame(width: 1) }
        }
        .frame(height: hourHeight * 24)
    }
}

private struct CalendarTimelineEvent: View {
    let item: CalendarItem
    let compact: Bool
    let narrow: Bool
    let timeZone: TimeZone

    private var timeStyle: Date.FormatStyle {
        var style = Date.FormatStyle.dateTime.hour().minute()
        style.timeZone = timeZone
        return style
    }

    var body: some View {
        Group {
            if narrow {
                VStack(alignment: .leading, spacing: 2) {
                    Text(item.icon)
                        .font(.caption)
                    Text(item.start, format: timeStyle)
                        .font(.caption2.monospacedDigit())
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .minimumScaleFactor(0.75)
                }
            } else {
                HStack(alignment: .top, spacing: 5) {
                    Text(item.icon).font(.caption)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(item.title)
                            .font(.caption.weight(.semibold))
                            .lineLimit(compact ? 1 : 2)
                        if !compact {
                            Text(item.start, format: timeStyle)
                                .font(.caption2.monospacedDigit())
                                .foregroundStyle(.secondary)
                        }
                    }
                    Spacer(minLength: 0)
                }
            }
        }
        .padding(.horizontal, narrow ? 5 : 6)
        .padding(.vertical, 4)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .foregroundStyle(.primary)
        .background(item.status.color.opacity(0.18), in: RoundedRectangle(cornerRadius: 7, style: .continuous))
        .overlay(alignment: .leading) {
            RoundedRectangle(cornerRadius: 2).fill(item.status.color).frame(width: 3).padding(.vertical, 3)
        }
        .overlay(RoundedRectangle(cornerRadius: 7, style: .continuous).stroke(item.status.color.opacity(0.35)))
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(item.title), \(item.status.label), \(item.start.formatted(timeStyle))")
    }
}

public struct CalendarMonthGrid: View {
    public let month: Date
    public let selectedDate: Date
    public let items: [CalendarItem]
    public let holidays: [CalendarHoliday]
    public let calendar: Calendar
    public let onSelectDate: (Date) -> Void
    public let onSelectItem: (CalendarItem) -> Void
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass

    public init(month: Date, selectedDate: Date, items: [CalendarItem], holidays: [CalendarHoliday] = [], calendar: Calendar = .current,
                onSelectDate: @escaping (Date) -> Void, onSelectItem: @escaping (CalendarItem) -> Void) {
        self.month = month
        self.selectedDate = selectedDate
        self.items = items
        self.holidays = holidays
        self.calendar = calendar
        self.onSelectDate = onSelectDate
        self.onSelectItem = onSelectItem
    }

    private var days: [Date] { CalendarDateRange.monthGrid(containing: month, calendar: calendar) }
    private var monthComponent: Int { calendar.component(.month, from: month) }
    private var usesCompactCells: Bool {
#if os(iOS)
        horizontalSizeClass == .compact
#else
        false
#endif
    }

    public var body: some View {
        VStack(spacing: 0) {
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 0), count: 7), spacing: 0) {
                // Single-letter weekday symbols repeat (S/T). Index identity keeps
                // all seven columns instead of SwiftUI coalescing duplicate IDs.
                ForEach(Array(weekdaySymbols.enumerated()), id: \.offset) { _, symbol in
                    Text(symbol).font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity).padding(.vertical, 8)
                }
                ForEach(days, id: \.self) { day in
                    monthCell(day)
                }
            }
        }
        .background(LifeOSTokens.canvas)
    }

    private var weekdaySymbols: [String] {
        let symbols = calendar.veryShortStandaloneWeekdaySymbols
        let index = max(0, min(symbols.count - 1, calendar.firstWeekday - 1))
        return Array(symbols[index...] + symbols[..<index])
    }

    private func monthCell(_ day: Date) -> some View {
        let dayItems = CalendarSnapshot(items: items).items(on: day, calendar: calendar)
        let dayHolidays = holidays.filter { calendar.isDate($0.date, inSameDayAs: day) }
        let isCurrentMonth = calendar.component(.month, from: day) == monthComponent
        let visibleEventLimit = CalendarMonthCellPresentation.visibleEventLimit(isCompact: usesCompactCells)
        let overflowCount = CalendarMonthCellPresentation.overflowCount(total: dayItems.count, visible: visibleEventLimit)
        return VStack(alignment: .leading, spacing: 4) {
            Button { onSelectDate(day) } label: {
                Text(day, format: .dateTime.day())
                    .font(.caption.weight(calendar.isDateInToday(day) ? .bold : .medium))
                    .foregroundStyle(calendar.isDateInToday(day) ? .white : (isCurrentMonth ? Color.primary : Color.secondary))
                    .frame(width: 25, height: 25)
                    .background(calendar.isDateInToday(day) ? LifeOSTokens.accent : .clear, in: Circle())
            }
            .buttonStyle(.plain)

            if let holiday = dayHolidays.first {
                if usesCompactCells {
                    Circle()
                        .fill(LifeOSTokens.accent)
                        .frame(width: 5, height: 5)
                        .accessibilityLabel("Holiday: \(holiday.name)")
                } else {
                    Text(holiday.name)
                        .font(.system(size: 8, weight: .semibold))
                        .foregroundStyle(LifeOSTokens.accent)
                        .lineLimit(1)
                        .help(holiday.name)
                }
            }

            ForEach(dayItems.prefix(visibleEventLimit)) { item in
                Button { onSelectItem(item) } label: {
                    HStack(spacing: 3) {
                        Circle().fill(item.status.color).frame(width: 4, height: 4)
                        CalendarIconView(item: item, size: usesCompactCells ? 11 : 14)
                        if !usesCompactCells {
                            Text(item.title).lineLimit(1)
                        }
                    }
                    .font(.caption2)
                    .padding(.horizontal, usesCompactCells ? 3 : 4)
                    .padding(.vertical, 2)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(item.status.color.opacity(0.12), in: RoundedRectangle(cornerRadius: 4))
                }
                .buttonStyle(.plain)
                .accessibilityLabel("\(item.title), \(item.status.label)")
            }
            if overflowCount > 0 {
                Text("+\(overflowCount)")
                    .font(.system(size: usesCompactCells ? 8 : 10, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .accessibilityLabel("\(overflowCount) more events")
            }
            Spacer(minLength: 0)
        }
        .padding(6)
        .frame(maxWidth: .infinity, minHeight: 88, alignment: .topLeading)
        .opacity(isCurrentMonth ? 1 : 0.45)
        .background(calendar.isDate(day, inSameDayAs: selectedDate) ? LifeOSTokens.accent.opacity(0.08) : .clear)
        .overlay(Rectangle().stroke(Color.primary.opacity(0.075), lineWidth: 0.5))
    }
}

public struct CalendarCompactMonth: View {
    @Binding public var selectedDate: Date
    public let calendar: Calendar
    public let items: [CalendarItem]
    @State private var visibleMonth: Date

    public init(
        selectedDate: Binding<Date>,
        calendar: Calendar = .current,
        items: [CalendarItem] = []
    ) {
        _selectedDate = selectedDate
        self.calendar = calendar
        self.items = items
        _visibleMonth = State(initialValue: selectedDate.wrappedValue)
    }

    public var body: some View {
        VStack(spacing: 12) {
            HStack(spacing: 6) {
                Text(visibleMonth, format: .dateTime.month(.wide).year())
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(Color.primary)
                    .contentTransition(.numericText())
                Spacer(minLength: 8)
                monthButton(direction: -1, icon: .chevronLeft)
                monthButton(direction: 1, icon: .chevronRight)
            }

            LazyVGrid(columns: columns, spacing: 5) {
                ForEach(Array(weekdaySymbols.enumerated()), id: \.offset) { _, symbol in
                    Text(symbol)
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(LifeOSTokens.tertiaryText)
                        .frame(maxWidth: .infinity)
                        .accessibilityHidden(true)
                }

                ForEach(monthDays, id: \.self) { day in
                    CalendarCompactDayButton(
                        day: day,
                        visibleMonth: visibleMonth,
                        selectedDate: selectedDate,
                        hasEvents: items.contains { calendar.isDate($0.start, inSameDayAs: day) },
                        calendar: calendar
                    ) {
                        selectedDate = day
                    }
                }
            }
        }
        .onChange(of: selectedDate) { _, date in
            guard !calendar.isDate(date, equalTo: visibleMonth, toGranularity: .month) else { return }
            visibleMonth = date
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Mini calendar")
    }

    private let columns = Array(repeating: GridItem(.flexible(), spacing: 4), count: 7)

    private var monthDays: [Date] {
        CalendarDateRange.monthGrid(containing: visibleMonth, calendar: calendar)
    }

    private var weekdaySymbols: [String] {
        let symbols = calendar.veryShortStandaloneWeekdaySymbols
        let offset = max(0, min(symbols.count - 1, calendar.firstWeekday - 1))
        return Array(symbols[offset...] + symbols[..<offset])
    }

    private func monthButton(direction: Int, icon: LifeOSIconName) -> some View {
        Button {
            guard let month = calendar.date(byAdding: .month, value: direction, to: visibleMonth) else { return }
            withAnimation(LifeOSMotion.easeNavigate) { visibleMonth = month }
        } label: {
            LifeOSIcon(icon)
                .frame(width: 11, height: 11)
                .frame(width: 24, height: 24)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(Color.secondary)
        .background(Color.primary.opacity(0.045), in: RoundedRectangle(cornerRadius: 6, style: .continuous))
        .accessibilityLabel(direction < 0 ? "Previous month" : "Next month")
    }
}

private struct CalendarCompactDayButton: View {
    let day: Date
    let visibleMonth: Date
    let selectedDate: Date
    let hasEvents: Bool
    let calendar: Calendar
    let action: () -> Void
    @State private var isHovering = false

    private var isSelected: Bool { calendar.isDate(day, inSameDayAs: selectedDate) }
    private var isToday: Bool { calendar.isDateInToday(day) }
    private var isInMonth: Bool { calendar.isDate(day, equalTo: visibleMonth, toGranularity: .month) }

    var body: some View {
        Button(action: action) {
            ZStack(alignment: .bottom) {
                Text(day, format: .dateTime.day())
                    .font(.system(size: 11, weight: isSelected || isToday ? .semibold : .regular))
                    .foregroundStyle(dayForeground)
                    .frame(width: 26, height: 26)
                    .background(dayBackground, in: RoundedRectangle(cornerRadius: 7, style: .continuous))
                    .overlay {
                        if isToday && !isSelected {
                            RoundedRectangle(cornerRadius: 7, style: .continuous)
                                .stroke(LifeOSTokens.accent.opacity(0.65), lineWidth: 1)
                        }
                    }

                if hasEvents {
                    Circle()
                        .fill(isSelected ? Color.white.opacity(0.9) : LifeOSTokens.accent.opacity(isInMonth ? 0.9 : 0.35))
                        .frame(width: 2.5, height: 2.5)
                        .padding(.bottom, 2.5)
                }
            }
            .frame(maxWidth: .infinity)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { isHovering = $0 }
        .accessibilityLabel(day.formatted(.dateTime.weekday(.wide).month(.wide).day().year()))
        .accessibilityValue(isSelected ? "Selected" : (hasEvents ? "Has events" : ""))
    }

    private var dayForeground: Color {
        if isSelected { return .white }
        if isToday { return LifeOSTokens.accent }
        return isInMonth ? .primary : LifeOSTokens.tertiaryText.opacity(0.55)
    }

    private var dayBackground: Color {
        if isSelected { return LifeOSTokens.accent }
        if isHovering { return Color.primary.opacity(0.07) }
        return .clear
    }
}

public struct CalendarEmojiPicker: View {
    @Binding public var selection: String
    private let emojis = [
        "📅", "✅", "💼", "💻", "📱", "🧠", "❤️", "🏃", "🏋️", "🧘", "😴", "🍽️",
        "☕️", "🎯", "📚", "✍️", "🎨", "🎬", "🎵", "🎮", "✈️", "🚗", "🏠", "💰",
        "📈", "🧾", "🛒", "🎁", "🎉", "👥", "📞", "💬", "⚡️", "🔥", "🌙", "☀️"
    ]

    public init(selection: Binding<String>) { _selection = selection }

    public var body: some View {
        LazyVGrid(columns: Array(repeating: GridItem(.fixed(34), spacing: 7), count: 6), spacing: 7) {
            ForEach(emojis, id: \.self) { emoji in
                Button { selection = emoji } label: {
                    Text(emoji).font(.title3).frame(width: 34, height: 34)
                        .background(selection == emoji ? LifeOSTokens.accent.opacity(0.20) : Color.primary.opacity(0.04),
                                    in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                        .overlay(RoundedRectangle(cornerRadius: 8).stroke(selection == emoji ? LifeOSTokens.accent : .clear))
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Use \(emoji) icon")
            }
        }
        .padding(10)
    }
}
