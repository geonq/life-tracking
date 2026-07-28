import WidgetKit
import SwiftUI

public struct CalendarWidgetEntry: TimelineEntry {
    public let date: Date
    public let snapshot: CalendarSnapshot
    public let storageAvailable: Bool
    public let isPreview: Bool

    public init(date: Date = .now, snapshot: CalendarSnapshot, storageAvailable: Bool = true, isPreview: Bool = false) {
        self.date = date; self.snapshot = snapshot; self.storageAvailable = storageAvailable; self.isPreview = isPreview
    }
}

public struct CalendarWidgetProvider: TimelineProvider {
    public init() {}

    public func placeholder(in context: Context) -> CalendarWidgetEntry {
        do {
            let item = try CalendarItem(title: "Preview commitment", icon: "📝", start: .now, end: .now.addingTimeInterval(3600))
            return CalendarWidgetEntry(snapshot: CalendarSnapshot(items: [item]), isPreview: true)
        } catch { return CalendarWidgetEntry(snapshot: CalendarSnapshot(), storageAvailable: false, isPreview: true) }
    }

    public func getSnapshot(in context: Context, completion: @escaping (CalendarWidgetEntry) -> Void) {
        if context.isPreview { completion(placeholder(in: context)); return }
        load(completion: completion)
    }

    public func getTimeline(in context: Context, completion: @escaping (Timeline<CalendarWidgetEntry>) -> Void) {
        load { entry in
            completion(Timeline(entries: [entry], policy: .after(.now.addingTimeInterval(900))))
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
    private var upcoming: [CalendarItem] { entry.snapshot.items.filter { !$0.isDeleted && $0.end >= entry.date }.sorted { $0.start < $1.start }.prefix(3).map { $0 } }

    public var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack { Text(entry.date, format: .dateTime.weekday(.abbreviated)).font(.headline); Spacer(); Text(entry.date, format: .dateTime.month(.abbreviated).day()).font(.caption).foregroundStyle(.secondary) }
            if !entry.storageAvailable && !entry.isPreview { Spacer(); Text("Calendar unavailable").font(.subheadline).foregroundStyle(.secondary); Text("App Group storage is inaccessible.").font(.caption2).foregroundStyle(.secondary); Spacer() }
            else if upcoming.isEmpty { Spacer(); Text(entry.isPreview ? "Preview only" : "No upcoming commitments").font(.subheadline).foregroundStyle(.secondary); Spacer() }
            else { ForEach(upcoming) { item in HStack(spacing: 7) { Text(item.icon); VStack(alignment: .leading) { Text(item.title).font(.caption.bold()).lineLimit(1); Text("\(item.start, format: .dateTime.hour().minute())–\(item.end, format: .dateTime.hour().minute())").font(.caption2).foregroundStyle(.secondary) }; Spacer(); Image(systemName: item.status == .done ? "checkmark.circle.fill" : item.status == .blocked ? "exclamationmark.circle.fill" : "circle").foregroundStyle(item.status.color).accessibilityLabel(item.status.label) } } }
        }.containerBackground(.background, for: .widget).accessibilityElement(children: .combine).accessibilityLabel("Calendar for \(entry.date, format: .dateTime.month().day()). \(upcoming.count) upcoming items.")
    }
}

public struct CalendarWidget: Widget {
    public let kind = "LifeOSCalendarWidget"
    public init() {}
    public var body: some WidgetConfiguration { StaticConfiguration(kind: kind, provider: CalendarWidgetProvider()) { CalendarWidgetView(entry: $0) }.configurationDisplayName("Calendar").description("Upcoming commitments at a glance.").supportedFamilies([.systemMedium]) }
}
