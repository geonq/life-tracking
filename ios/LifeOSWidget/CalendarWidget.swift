import Foundation
import WidgetKit
import SwiftUI

/// The calendar's semantic contrast controls must remain legible in iOS 18's
/// tinted widget mode. WidgetKit otherwise remaps both a fill and its label to
/// the same tint, even when SwiftUI supplied opposite foreground/background
/// colors. The full-color override is available for image content, so use an
/// SF Symbol for the two control surfaces and keep all other widget content
/// eligible for the user's chosen tint.
private extension Image {
    @ViewBuilder
    func lifeOSCalendarContrastRendering() -> some View {
#if os(iOS)
        if #available(iOS 18.0, *) {
            self.widgetAccentedRenderingMode(.fullColor)
        } else {
            self
        }
#elseif os(macOS)
        if #available(macOS 15.0, *) {
            self.widgetAccentedRenderingMode(.fullColor)
        } else {
            self
        }
#else
        self
#endif
    }
}

/// Shared, widget-only projection of persisted calendar items.
///
/// `CalendarSnapshot.items(on:)` intentionally exposes stored anchors. Widgets
/// need the same bounded derived-occurrence semantics as the calendar surface,
/// so every widget query expands through `CalendarRecurrence` before applying
/// its own date filter. This keeps deletion, `until`, ordering, and the
/// recurrence engine's per-item cap in one place without persisting shadows.
public enum CalendarWidgetData {
    static let refreshBoundaryHorizon: TimeInterval = 2 * 60 * 60
    static let boundaryInclusivityEpsilon: TimeInterval = 1

    public static func items(
        on day: Date,
        in snapshot: CalendarSnapshot,
        calendar: Calendar
    ) -> [CalendarItem] {
        let dayStart = calendar.startOfDay(for: day)
        guard let dayEnd = calendar.date(byAdding: .day, value: 1, to: dayStart) else {
            return []
        }
        return items(
            overlapping: DateInterval(start: dayStart, end: dayEnd),
            in: snapshot,
            calendar: calendar
        )
    }

    public static func items(
        overlapping window: DateInterval,
        in snapshot: CalendarSnapshot,
        calendar: Calendar
    ) -> [CalendarItem] {
        guard window.duration > 0 else { return [] }

        return snapshot.items
            .flatMap { CalendarRecurrence.occurrences(of: $0, overlapping: window, calendar: calendar) }
            // The recurrence engine filters recurring values itself. The extra
            // overlap filter is required for non-recurring items, whose engine
            // contract deliberately returns the item unchanged.
            .filter { !$0.isDeleted && $0.start < window.end && $0.end > window.start }
            .sorted(by: stableAscendingOrder)
    }

    /// Finds the nearest event that is still active or upcoming at `date`.
    /// Recurring items use a per-item window so an old anchor can still yield
    /// today's occurrence while the expansion remains bounded by the shared
    /// logarithmic historical search and the shared 400-instance recurrence
    /// output cap.
    public static func nextEvent(
        in snapshot: CalendarSnapshot,
        at date: Date,
        calendar: Calendar
    ) -> CalendarItem? {
        let candidates = snapshot.items.flatMap { item -> [CalendarItem] in
            guard !item.isDeleted else { return [] }
            guard item.recurrence != nil else {
                return item.end >= date ? [item] : []
            }

            let duration = max(0, item.end.timeIntervalSince(item.start))
            let windowStart = date.addingTimeInterval(-duration)
            // The anchor is itself a valid occurrence. Keep it in the search
            // window even when it is farther away than the derived look-ahead.
            let windowEnd = max(
                recurrenceSearchEnd(for: item, after: date, calendar: calendar),
                item.end
            )
            guard windowEnd > windowStart else { return [] }

            return CalendarRecurrence.occurrences(
                of: item,
                overlapping: DateInterval(start: windowStart, end: windowEnd),
                calendar: calendar
            )
            .filter { !$0.isDeleted && $0.end >= date }
        }

        return candidates.sorted(by: stableAscendingOrder).first
    }

    private static func recurrenceSearchEnd(
        for item: CalendarItem,
        after date: Date,
        calendar: Calendar
    ) -> Date {
        guard let rule = item.recurrence else { return date }
        let maximum = CalendarRecurrence.maximumOccurrencesPerItem
        guard rule.interval <= Int.max / maximum else { return .distantFuture }
        let value = rule.interval * maximum
        return calendar.date(byAdding: rule.frequency.stepUnit, value: value, to: date) ?? .distantFuture
    }

    private static func stableAscendingOrder(_ lhs: CalendarItem, _ rhs: CalendarItem) -> Bool {
        if lhs.start != rhs.start { return lhs.start < rhs.start }
        if lhs.id != rhs.id { return lhs.id.uuidString < rhs.id.uuidString }
        if lhs.end != rhs.end { return lhs.end < rhs.end }
        return (lhs.occurrenceSourceID?.uuidString ?? "") < (rhs.occurrenceSourceID?.uuidString ?? "")
    }
}

public struct CalendarWidgetEntry: TimelineEntry {
    public let date: Date
    public let snapshot: CalendarSnapshot
    public let storageAvailable: Bool
    public let isPreview: Bool

    public enum SharingCopy {
        public static let title = "Widget sharing unavailable"
        public static let detail = "A provisioned App Group is required. Open LifeOS for the local calendar."
        public static let accessibility = "Widget sharing unavailable. A provisioned App Group is required. Open LifeOS for the local calendar."
    }

    public init(date: Date = .now, snapshot: CalendarSnapshot, storageAvailable: Bool = true, isPreview: Bool = false) {
        self.date = date
        self.snapshot = snapshot
        self.storageAvailable = storageAvailable
        self.isPreview = isPreview
    }
}

public struct CalendarWidgetProvider: TimelineProvider {
    public init() {}

    public func placeholder(in context: Context) -> CalendarWidgetEntry {
        CalendarWidgetEntry(
            snapshot: CalendarVisualFixtures.snapshot(),
            storageAvailable: true,
            isPreview: true
        )
    }

    public func getSnapshot(in context: Context, completion: @escaping (CalendarWidgetEntry) -> Void) {
        if context.isPreview {
            completion(placeholder(in: context))
            return
        }
        load(completion: completion)
    }

    public func getTimeline(in context: Context, completion: @escaping (Timeline<CalendarWidgetEntry>) -> Void) {
        load { entry in
            let refresh = Self.nextRefreshDate(for: entry.snapshot, after: entry.date)
            completion(Timeline(entries: [entry], policy: .after(refresh)))
        }
    }

    /// Refresh at the next event boundary only when that boundary is close enough to
    /// matter. A quiet calendar still gets a bounded refresh so a newly-saved event can
    /// appear without waiting for the next day.
    static func nextRefreshDate(for snapshot: CalendarSnapshot, after date: Date) -> Date {
        // Add a one-second epsilon because CalendarRecurrence treats the window
        // end as exclusive, while the legacy raw-item path treated a boundary
        // exactly two hours away as eligible.
        let window = DateInterval(
            start: date,
            end: date.addingTimeInterval(
                CalendarWidgetData.refreshBoundaryHorizon + CalendarWidgetData.boundaryInclusivityEpsilon
            )
        )
        let boundaries = CalendarWidgetData.items(overlapping: window, in: snapshot, calendar: .current)
            .flatMap { [$0.start, $0.end] }
            .filter { $0 > date }
            .sorted()

        if let nextBoundary = boundaries.first,
           nextBoundary.timeIntervalSince(date) <= CalendarWidgetData.refreshBoundaryHorizon {
            return nextBoundary
        }
        return date.addingTimeInterval(30 * 60)
    }

    private func load(completion: @escaping (CalendarWidgetEntry) -> Void) {
        guard let identifier = AppGroupConfiguration.identifier(bundle: .main) else {
            completion(CalendarWidgetEntry(snapshot: CalendarSnapshot(), storageAvailable: false))
            return
        }
        do {
            let url = try CalendarStoreURL.appGroupURL(identifier: identifier)
            Task {
                do {
                    completion(CalendarWidgetEntry(snapshot: try await CalendarStore(url: url).load()))
                } catch {
                    completion(CalendarWidgetEntry(snapshot: CalendarSnapshot(), storageAvailable: false))
                }
            }
        } catch {
            completion(CalendarWidgetEntry(snapshot: CalendarSnapshot(), storageAvailable: false))
        }
    }
}

public struct CalendarWidgetView: View {
    public let entry: CalendarWidgetEntry

    @Environment(\.calendar) private var environmentCalendar
    @Environment(\.locale) private var environmentLocale
    @Environment(\.showsWidgetContainerBackground) private var showsWidgetContainerBackground
    @Environment(\.widgetRenderingMode) private var widgetRenderingMode

    public init(entry: CalendarWidgetEntry) {
        self.entry = entry
    }

    private let weekNumberWidth: CGFloat = 14
    private let leftColumnWidth: CGFloat = 124
    private let dayCellSize: CGFloat = 17

    private var calendar: Calendar {
        var calendar = environmentCalendar
        calendar.locale = environmentLocale
        // The Figma frame is Monday-first. Keep the symbols locale-aware while making
        // the ordering deterministic across a user's locale/week-start preference.
        calendar.firstWeekday = 2
        return calendar
    }

    private var formatLocale: Locale {
        calendar.locale ?? .current
    }

    private var isoCalendar: Calendar {
        var calendar = Calendar(identifier: .iso8601)
        calendar.locale = environmentLocale
        calendar.timeZone = self.calendar.timeZone
        return calendar
    }

    private var usesTransparentTreatment: Bool {
        widgetChrome.usesTransparentTreatment
    }

    private var widgetChrome: LifeOSWidgetChrome {
        LifeOSWidgetChrome.resolving(
            showsContainerBackground: showsWidgetContainerBackground,
            renderingMode: widgetRenderingMode
        )
    }

    private var primaryForeground: Color {
        widgetChrome.hero
    }

    private var secondaryForeground: Color {
        widgetChrome.secondary
    }

    private var tertiaryForeground: Color {
        widgetChrome.tertiary
    }

    /// Contrast-sensitive controls must keep their foreground and fill in
    /// opposite color roles. `widgetAccentable` is intentionally not used for
    /// these layers: WidgetKit may remap both an accentable glyph and its
    /// accentable surface to the same tinted color.
    private var contrastFill: Color {
        // These controls are intentionally fixed high-contrast pixels. An
        // adaptive/text role can be remapped by WidgetKit's tinted treatment,
        // collapsing the numeral into its marker; black-on-white remains
        // legible in dark, light, tinted, clear, and vibrant placements.
        .white
    }

    private var contrastForeground: Color {
        .black
    }

    private var monthDays: [Date] {
        CalendarWidgetDateGrid.days(containing: entry.date, calendar: calendar)
    }

    private var monthTitle: String {
        entry.date.formatted(.dateTime.locale(formatLocale).month(.wide))
    }

    private var weekLabel: String {
        formatLocale.identifier.lowercased().hasPrefix("de") ? "Woche" : "Week"
    }

    private var isoWeek: Int {
        isoCalendar.component(.weekOfYear, from: entry.date)
    }

    private var weekdaySymbols: [String] {
        let symbols = calendar.shortWeekdaySymbols
        let start = max(0, calendar.firstWeekday - 1)
        let reordered = Array(symbols[start...]) + Array(symbols[..<start])
        return reordered.map(compactWeekdaySymbol)
    }

    private func compactWeekdaySymbol(_ symbol: String) -> String {
        let lettersAndNumbers = symbol.filter { $0.isLetter || $0.isNumber }
        return String(lettersAndNumbers.prefix(2))
    }

    private var agendaEvents: [CalendarItem] {
        Array(snapshotItems(on: entry.date).prefix(3))
    }

    private var agendaOverflow: Int {
        let total = snapshotItems(on: entry.date).count
        return max(0, total - agendaEvents.count)
    }

    private func snapshotItems(on day: Date) -> [CalendarItem] {
        CalendarWidgetData.items(on: day, in: entry.snapshot, calendar: calendar)
    }

    private func isInDisplayedMonth(_ day: Date) -> Bool {
        calendar.component(.year, from: day) == calendar.component(.year, from: entry.date) &&
            calendar.component(.month, from: day) == calendar.component(.month, from: entry.date)
    }

    private func timeString(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = formatLocale
        formatter.calendar = calendar
        formatter.timeZone = calendar.timeZone
        formatter.dateFormat = "HH:mm"
        return formatter.string(from: date)
    }

    private func timeRange(for item: CalendarItem) -> String {
        "\(timeString(item.start))–\(timeString(item.end))"
    }

    public var body: some View {
        Group {
            if !entry.storageAvailable && !entry.isPreview {
                unavailableView
            } else {
                widgetContent
            }
        }
        .containerBackground(for: .widget) {
            usesTransparentTreatment ? Color.clear : LifeOSTokens.surface
        }
        .accessibilityElement(children: .contain)
    }

    private var widgetContent: some View {
        ZStack(alignment: .bottomTrailing) {
            Link(destination: URL(string: "lifeos://calendar")!) {
                HStack(alignment: .top, spacing: 16) {
                    monthGrid
                        .frame(width: leftColumnWidth)
                    agendaPane
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                .contentShape(Rectangle())
            }
            .accessibilityLabel(accessibilitySummary)

            Link(destination: URL(string: "lifeos://calendar/new")!) {
                plusButton
            }
            .accessibilityLabel("Create calendar event")
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }

    private var unavailableView: some View {
        VStack(alignment: .leading, spacing: 7) {
            Text(CalendarWidgetEntry.SharingCopy.title)
                .font(.system(size: 16, weight: .bold))
                .foregroundStyle(primaryForeground)
            Text(CalendarWidgetEntry.SharingCopy.detail)
                .font(.system(size: 11))
                .foregroundStyle(secondaryForeground)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
        .padding(16)
    }

    private var monthGrid: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(alignment: .firstTextBaseline, spacing: 5) {
                Text(monthTitle)
                    .font(.system(size: 15, weight: .bold))
                    .foregroundStyle(primaryForeground)
                    .lineLimit(1)
                Text("\(weekLabel) \(isoWeek)")
                    .font(.system(size: 11))
                    .foregroundStyle(secondaryForeground)
                    .lineLimit(1)
                Spacer(minLength: 0)
            }
            .frame(height: 18, alignment: .leading)

            HStack(spacing: 0) {
                Color.clear.frame(width: weekNumberWidth)
                ForEach(weekdaySymbols.indices, id: \.self) { index in
                    Text(weekdaySymbols[index])
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(secondaryForeground)
                        .lineLimit(1)
                        .minimumScaleFactor(0.55)
                        .frame(maxWidth: .infinity)
                }
            }
            .frame(height: 11)

            VStack(spacing: 0) {
                ForEach(0..<6, id: \.self) { row in
                    HStack(spacing: 0) {
                        Text("\(isoCalendar.component(.weekOfYear, from: monthDays[row * 7]))")
                            .font(.system(size: 9))
                            .foregroundStyle(tertiaryForeground)
                            .frame(width: weekNumberWidth, height: dayCellSize)

                        ForEach(0..<7, id: \.self) { column in
                            dayCell(monthDays[row * 7 + column])
                                .frame(maxWidth: .infinity, maxHeight: dayCellSize)
                        }
                    }
                    .frame(height: dayCellSize)
                }
            }
        }
    }

    private func dayCell(_ day: Date) -> some View {
        let isToday = calendar.isDate(day, inSameDayAs: entry.date)
        let isCurrentMonth = isInDisplayedMonth(day)
        // Today is marked by primary-text inversion (§5.6): filled square in
        // the primary-text role, numeral in the canvas role. The same explicit
        // pair is used for transparent/tinted treatment so WidgetKit cannot
        // collapse both layers into one system accent color.
        let textColor: Color = isToday
            ? contrastForeground
            : (isCurrentMonth ? primaryForeground : secondaryForeground.opacity(0.58))

        return ZStack {
            if isToday {
                Image(systemName: "square.fill")
                    .lifeOSCalendarContrastRendering()
                    .font(.system(size: dayCellSize))
                    .foregroundStyle(contrastFill)
                    .frame(width: dayCellSize, height: dayCellSize)
            }
            Text(calendar.component(.day, from: day).description)
                .font(.system(size: 10, weight: isToday ? .bold : .regular, design: .rounded))
                .foregroundStyle(textColor)
        }
        .frame(width: dayCellSize, height: dayCellSize)
        .accessibilityLabel(day.formatted(.dateTime.locale(formatLocale).month().day()) + (isToday ? ", today" : ""))
    }

    private var agendaPane: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(alignment: .firstTextBaseline, spacing: 4) {
                Text(compactWeekdaySymbol(entry.date.formatted(.dateTime.locale(formatLocale).weekday(.abbreviated))))
                    .foregroundStyle(primaryForeground)
                Text(entry.date, format: .dateTime.locale(formatLocale).day())
                    .foregroundStyle(primaryForeground)
            }
            .font(.system(size: 19, weight: .bold))
            .lineLimit(1)

            if agendaEvents.isEmpty {
                Text("No events today")
                    .font(.system(size: 12))
                    .foregroundStyle(secondaryForeground)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.top, 5)
            } else {
                VStack(alignment: .leading, spacing: 5) {
                    ForEach(agendaEvents) { item in
                        agendaRow(item)
                    }
                    if agendaOverflow > 0 {
                        Text("+\(agendaOverflow) more")
                            .font(.system(size: 11))
                            .foregroundStyle(tertiaryForeground)
                            .padding(.leading, 10)
                    }
                }
                .padding(.top, 2)
                Spacer(minLength: 0)
            }
        }
    }

    private func agendaRow(_ item: CalendarItem) -> some View {
        HStack(alignment: .top, spacing: 7) {
            RoundedRectangle(cornerRadius: 1.5, style: .continuous)
                .fill(LifeOSTokens.accent)
                .frame(width: 3, height: 28)
            VStack(alignment: .leading, spacing: 0) {
                Text(item.title)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(primaryForeground)
                    .lineLimit(1)
                Text(timeRange(for: item))
                    .font(.system(size: 12))
                    .foregroundStyle(secondaryForeground)
                    .lineLimit(1)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var plusButton: some View {
        ZStack {
            Image(systemName: "circle.fill")
                .lifeOSCalendarContrastRendering()
                .font(.system(size: 34))
                .foregroundStyle(contrastFill)
            Image(systemName: "plus")
                .lifeOSCalendarContrastRendering()
                .font(.system(size: 18, weight: .semibold))
                .foregroundStyle(contrastForeground)
        }
        .frame(width: 34, height: 34)
    }

    private var accessibilitySummary: String {
        if !entry.storageAvailable && !entry.isPreview {
            return CalendarWidgetEntry.SharingCopy.accessibility
        }
        if agendaEvents.isEmpty {
            return "Calendar. No events today. Create event button available."
        }
        let titles = agendaEvents.map(\.title).joined(separator: ", ")
        return "Calendar for \(monthTitle). Today's events: \(titles). Create event button available."
    }
}

public struct CalendarWidget: Widget {
    public let kind = "LifeOSCalendarWidget"

    public init() {}

    public var body: some WidgetConfiguration {
        StaticConfiguration(kind: kind, provider: CalendarWidgetProvider()) { CalendarWidgetView(entry: $0) }
            .configurationDisplayName("Calendar")
            .description("A month at a glance and today's agenda.")
            .supportedFamilies([.systemMedium])
    }
}
