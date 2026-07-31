import WidgetKit
import SwiftUI

public struct CalendarWidgetEntry: TimelineEntry {
    public let date: Date
    public let snapshot: CalendarSnapshot
    public let storageAvailable: Bool
    public let isPreview: Bool

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
        if context.isPreview { completion(placeholder(in: context)); return }
        load(completion: completion)
    }

    public func getTimeline(in context: Context, completion: @escaping (Timeline<CalendarWidgetEntry>) -> Void) {
        load { entry in
            completion(Timeline(entries: [entry], policy: .after(entry.date.addingTimeInterval(900))))
        }
    }

    private func load(completion: @escaping (CalendarWidgetEntry) -> Void) {
        guard let identifier = Bundle.main.object(forInfoDictionaryKey: "APP_GROUP_IDENTIFIER") as? String else {
            completion(CalendarWidgetEntry(snapshot: CalendarSnapshot(), storageAvailable: false)); return
        }
        do {
            let url = try CalendarStoreURL.appGroupURL(identifier: identifier)
            Task {
                do { completion(CalendarWidgetEntry(snapshot: try await CalendarStore(url: url).load())) }
                catch { completion(CalendarWidgetEntry(snapshot: CalendarSnapshot(), storageAvailable: false)) }
            }
        } catch { completion(CalendarWidgetEntry(snapshot: CalendarSnapshot(), storageAvailable: false)) }
    }
}

public struct CalendarWidgetView: View {
    public let entry: CalendarWidgetEntry
    public init(entry: CalendarWidgetEntry) { self.entry = entry }

    private let calendar = Calendar.current
    private var upcoming: [CalendarItem] {
        entry.snapshot.items.filter { !$0.isDeleted && $0.end >= entry.date }.sorted { $0.start < $1.start }.prefix(1).map { $0 }
    }
    private var monthDays: [Date] { CalendarWidgetDateGrid.days(containing: entry.date, calendar: calendar) }
    private var monthTitle: String { entry.date.formatted(.dateTime.month(.wide).year()) }
    private var daySymbols: [String] {
        let symbols = calendar.veryShortWeekdaySymbols
        let start = max(0, calendar.firstWeekday - 1)
        return Array(symbols[start...]) + Array(symbols[..<start])
    }

    public var body: some View {
        Group {
            if !entry.storageAvailable && !entry.isPreview {
                unavailableView
            } else {
                HStack(alignment: .top, spacing: 14) {
                    monthGrid
                        .frame(width: 148)
                    Rectangle().fill(Color.primary.opacity(0.08)).frame(width: 1)
                    detailPane
                }
            }
        }
        .padding(14)
        .containerBackground(for: .widget) { LifeOSTokens.surface }
        .widgetURL(URL(string: "lifeos://calendar"))
        .accessibilityElement(children: .combine)
        .accessibilityLabel(accessibilitySummary)
    }

    private var unavailableView: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 7) {
                LifeOSIcon(.calendar).frame(width: 16, height: 16)
                Text("Calendar").font(.headline.weight(.bold))
            }
            .foregroundStyle(LifeOSTokens.accent)
            Spacer(minLength: 0)
            Text("Calendar unavailable").font(.subheadline.weight(.semibold))
            Text("Open LifeOS to configure shared calendar storage.")
                .font(.caption2)
                .foregroundStyle(.secondary)
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
    }

    private var monthGrid: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack {
                Text(monthTitle).font(.subheadline.weight(.bold)).foregroundStyle(.primary)
                Spacer()
                Text(entry.date, format: .dateTime.day()).font(.caption.weight(.bold)).foregroundStyle(LifeOSTokens.accent)
            }
            HStack(spacing: 0) {
                ForEach(daySymbols, id: \.self) { Text($0).frame(maxWidth: .infinity) }
            }
            .font(.system(size: 8, weight: .semibold)).foregroundStyle(.secondary)
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 2), count: 7), spacing: 5) {
                ForEach(monthDays, id: \.self) { day in
                    let isToday = calendar.isDate(day, inSameDayAs: entry.date)
                    let hasEvent = !entry.snapshot.items(on: day, calendar: calendar).isEmpty
                    Text(calendar.component(.day, from: day).description)
                        .font(.system(size: 10, weight: isToday ? .bold : .regular, design: .rounded))
                        .foregroundStyle(isToday ? Color.white : calendar.component(.month, from: day) == calendar.component(.month, from: entry.date) ? .primary : .secondary.opacity(0.45))
                        .frame(width: 17, height: 17)
                        .background { if isToday { Circle().fill(LifeOSTokens.accent) } }
                        .overlay(alignment: .bottom) { if hasEvent && !isToday { Circle().fill(LifeOSTokens.accent).frame(width: 3, height: 3).offset(y: 2) } }
                        .accessibilityLabel(day.formatted(.dateTime.month().day()) + (hasEvent ? ", has event" : ""))
                }
            }
        }
    }

    private var detailPane: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack {
                HStack(spacing: 5) {
                    LifeOSIcon(.calendar).frame(width: 11, height: 11)
                    Text("UP NEXT")
                }
                .font(.system(size: 9, weight: .bold))
                .foregroundStyle(LifeOSTokens.accent)
                Spacer()
                Link(destination: URL(string: "lifeos://calendar/new")!) {
                    LifeOSIcon(.add)
                        .frame(width: 12, height: 12)
                        .foregroundStyle(LifeOSTokens.accent)
                        .frame(width: 24, height: 24)
                        .background(LifeOSTokens.accentLight, in: Circle())
                }
                .accessibilityLabel("Create calendar event")
            }
            if !entry.storageAvailable && !entry.isPreview {
                Spacer(minLength: 0)
                Text("Calendar unavailable").font(.subheadline.weight(.semibold))
                Text("Open LifeOS to reconnect.").font(.caption2).foregroundStyle(.secondary)
                Spacer(minLength: 0)
            } else if let item = upcoming.first {
                CalendarIconView(item: item).frame(width: 34, height: 34).accessibilityLabel("Icon \(item.icon)")
                Text(item.title).font(.subheadline.weight(.bold)).lineLimit(2)
                Text("\(item.start, format: .dateTime.weekday(.abbreviated).month(.abbreviated).day())")
                    .font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                Text("\(item.start, format: .dateTime.hour().minute()) – \(item.end, format: .dateTime.hour().minute())")
                    .font(.caption.weight(.medium)).foregroundStyle(LifeOSTokens.accent)
            } else {
                Spacer(minLength: 0)
                Text(entry.isPreview ? "Preview calendar" : "Nothing scheduled")
                    .font(.subheadline.weight(.semibold))
                Text(entry.isPreview ? "Your next event will appear here." : "Enjoy the open time.")
                    .font(.caption2).foregroundStyle(.secondary)
                Spacer(minLength: 0)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var accessibilitySummary: String {
        if !entry.storageAvailable && !entry.isPreview { return "Calendar unavailable. Open LifeOS to reconnect." }
        guard let item = upcoming.first else { return entry.isPreview ? "Preview calendar. Your next event will appear here." : "Calendar. Nothing scheduled." }
        return "Next event, \(item.title), \(item.start.formatted(.dateTime.weekday().month().day().hour().minute())). Create event button available."
    }
}

public struct CalendarWidget: Widget {
    public let kind = "LifeOSCalendarWidget"
    public init() {}
    public var body: some WidgetConfiguration {
        StaticConfiguration(kind: kind, provider: CalendarWidgetProvider()) { CalendarWidgetView(entry: $0) }
            .configurationDisplayName("Calendar")
            .description("A month at a glance and your next commitment.")
            .supportedFamilies([.systemMedium])
    }
}
