import Foundation
import SwiftUI
import WidgetKit

/// A static glance at the nearest calendar event that has not ended yet.
///
/// The calendar entry/provider deliberately remain shared with `CalendarWidget` so both
/// widgets read the same snapshot and report the same storage state.
public struct NextEventWidgetView: View {
    public let entry: CalendarWidgetEntry

    @Environment(\.calendar) private var environmentCalendar
    @Environment(\.locale) private var environmentLocale
    @Environment(\.showsWidgetContainerBackground) private var showsWidgetContainerBackground
    @Environment(\.widgetFamily) private var widgetFamily
    @Environment(\.widgetRenderingMode) private var widgetRenderingMode

    private static let calendarURL = URL(string: "lifeos://calendar")!

    public init(entry: CalendarWidgetEntry) {
        self.entry = entry
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

    private var nextEvent: CalendarItem? {
        CalendarWidgetData.nextEvent(
            in: entry.snapshot,
            at: entry.date,
            calendar: environmentCalendar
        )
    }

    private func dateFormatter(template: String) -> DateFormatter {
        let formatter = DateFormatter()
        formatter.calendar = environmentCalendar
        formatter.locale = environmentLocale
        formatter.timeZone = environmentCalendar.timeZone
        formatter.setLocalizedDateFormatFromTemplate(template)
        return formatter
    }

    private func timeString(_ date: Date) -> String {
        let formatter = dateFormatter(template: "HHmm")
        formatter.dateFormat = "HH:mm"
        return formatter.string(from: date)
    }

    private func dateContext(for date: Date) -> String {
        dateFormatter(template: "EEE MMM d yyyy").string(from: date)
    }

    private func timeRange(for item: CalendarItem) -> String {
        "\(timeString(item.start))–\(timeString(item.end))"
    }

    public var body: some View {
        Group {
#if os(iOS)
            if widgetFamily == .accessoryRectangular {
                accessoryRectangularContent
            } else {
                smallContent
            }
#else
            smallContent
#endif
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
        .padding(contentPadding)
        .containerBackground(for: .widget) {
            usesTransparentTreatment ? Color.clear : LifeOSTokens.surface
        }
        .widgetURL(Self.calendarURL)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(accessibilitySummary)
    }

    private var contentPadding: CGFloat {
#if os(iOS)
        widgetFamily == .accessoryRectangular ? 4 : 14
#else
        14
#endif
    }

    private var smallContent: some View {
        Group {
            if !entry.storageAvailable && !entry.isPreview {
                unavailableContent
            } else if let nextEvent {
                eventContent(nextEvent, compact: false)
            } else {
                emptyContent
            }
        }
    }

#if os(iOS)
    private var accessoryRectangularContent: some View {
        Group {
            if !entry.storageAvailable && !entry.isPreview {
                accessoryUnavailableContent
            } else if let nextEvent {
                eventContent(nextEvent, compact: true)
            } else {
                accessoryEmptyContent
            }
        }
    }
#endif

    private func eventContent(_ item: CalendarItem, compact: Bool) -> some View {
        HStack(alignment: .top, spacing: compact ? 6 : 9) {
            RoundedRectangle(cornerRadius: 1.5, style: .continuous)
                .fill(LifeOSTokens.accent)
                .frame(width: 3, height: compact ? 40 : 74)

            VStack(alignment: .leading, spacing: compact ? 1 : 3) {
                Text(timeString(item.start))
                    .font(.system(
                        size: compact ? 16 : 31,
                        weight: .bold,
                        design: .rounded
                    ))
                    .foregroundStyle(primaryForeground)
                    .lineLimit(1)
                    .minimumScaleFactor(compact ? 0.75 : 0.62)

                Text(item.title)
                    .font(.system(size: compact ? 12 : 15, weight: .semibold))
                    .foregroundStyle(primaryForeground)
                    .lineLimit(compact ? 1 : 2)
                    .minimumScaleFactor(0.72)

                Text(dateContext(for: item.start))
                    .font(.system(size: compact ? 9 : 10))
                    .foregroundStyle(secondaryForeground)
                    .lineLimit(1)
                    .minimumScaleFactor(0.68)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
    }

    private var unavailableContent: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(CalendarWidgetEntry.SharingCopy.title)
                .font(.system(size: 15, weight: .bold))
                .foregroundStyle(primaryForeground)
                .lineLimit(2)
            Text(CalendarWidgetEntry.SharingCopy.detail)
                .font(.system(size: 11))
                .foregroundStyle(secondaryForeground)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
    }

    private var emptyContent: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("No upcoming events")
                .font(.system(size: 15, weight: .bold))
                .foregroundStyle(primaryForeground)
                .lineLimit(2)
            Text("Your calendar is clear.")
                .font(.system(size: 11))
                .foregroundStyle(secondaryForeground)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
    }

#if os(iOS)
    private var accessoryUnavailableContent: some View {
        HStack(alignment: .top, spacing: 6) {
            VStack(alignment: .leading, spacing: 1) {
                Text(CalendarWidgetEntry.SharingCopy.title)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(primaryForeground)
                    .lineLimit(1)
                Text(CalendarWidgetEntry.SharingCopy.detail)
                    .font(.system(size: 9))
                    .foregroundStyle(secondaryForeground)
                    .lineLimit(1)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
    }

    private var accessoryEmptyContent: some View {
        HStack(alignment: .top, spacing: 6) {
            VStack(alignment: .leading, spacing: 1) {
                Text("No upcoming events")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(primaryForeground)
                    .lineLimit(1)
                Text("Your calendar is clear")
                    .font(.system(size: 9))
                    .foregroundStyle(secondaryForeground)
                    .lineLimit(1)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
    }
#endif

    private var accessibilitySummary: String {
        if !entry.storageAvailable && !entry.isPreview {
            return CalendarWidgetEntry.SharingCopy.accessibility
        }
        guard let nextEvent else {
            return "No upcoming calendar events."
        }
        return "Next event, \(nextEvent.title), \(dateContext(for: nextEvent.start)), \(timeRange(for: nextEvent))."
    }
}

public struct NextEventWidget: Widget {
    public let kind = "LifeOSNextEventWidget"

    public init() {}

    public var body: some WidgetConfiguration {
        StaticConfiguration(kind: kind, provider: CalendarWidgetProvider()) { entry in
            NextEventWidgetView(entry: entry)
        }
        .configurationDisplayName("Next Event")
        .description("The next event on your calendar.")
#if os(iOS)
        .supportedFamilies([.systemSmall, .accessoryRectangular])
#else
        .supportedFamilies([.systemSmall])
#endif
    }
}
