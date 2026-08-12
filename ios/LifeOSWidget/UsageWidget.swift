import Foundation
import SwiftUI
import WidgetKit

struct LifeOSTimelineProvider: TimelineProvider {
    func placeholder(in context: Context) -> LifeOSEntry {
        LifeOSEntry(date: .now, snapshot: DemoDataProvider.widget())
    }

    func getSnapshot(in context: Context, completion: @escaping (LifeOSEntry) -> Void) {
        let snapshot = context.isPreview
            ? DemoDataProvider.widget()
            : liveSnapshot()
        completion(LifeOSEntry(date: .now, snapshot: snapshot))
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<LifeOSEntry>) -> Void) {
        let now = Date.now
        let snapshot = liveSnapshot(at: now)
        let entry = LifeOSEntry(date: now, snapshot: snapshot)
        completion(Timeline(entries: [entry], policy: .after(nextRefreshDate(for: snapshot, now: now))))
    }

    private func liveSnapshot(at date: Date = .now) -> WidgetSnapshot {
        guard let snapshot = SharedSnapshotStore.read(),
              snapshot.provenance.quality != .demo,
              !snapshot.providers.contains(where: { $0.provenance.quality == .demo }) else {
            return WidgetSnapshot.unavailable(at: date)
        }
        return snapshot
    }

    private func nextRefreshDate(for snapshot: WidgetSnapshot, now: Date) -> Date {
        let nextBoundary = snapshot.providers
            .flatMap { $0.windows.compactMap(\.resetAt) }
            .filter { $0 > now }
            .min()

        guard let nextBoundary, nextBoundary.timeIntervalSince(now) <= 2 * 60 * 60 else {
            return now.addingTimeInterval(30 * 60)
        }
        return max(nextBoundary, now.addingTimeInterval(60))
    }
}

struct LifeOSEntry: TimelineEntry {
    let date: Date
    let snapshot: WidgetSnapshot
}

private struct UsageWidgetProviderData: Identifiable {
    let summary: UsageWidgetSummary
    let resetAt: Date?

    var id: Provider { summary.provider }
    var name: String { Self.displayName(for: summary.provider) }

    static func displayName(for provider: Provider) -> String {
        provider.displayName
    }
}

private enum UsageWidgetData {
    static func providers(from snapshot: WidgetSnapshot) -> [UsageWidgetProviderData] {
        snapshot.providers.compactMap { provider in
            guard let summary = UsageWidgetSummary(snapshot: provider) else { return nil }
            return UsageWidgetProviderData(
                summary: summary,
                resetAt: provider.smallestObservedWindow?.resetAt
            )
        }
    }

    static func leading(from providers: [UsageWidgetProviderData]) -> UsageWidgetProviderData? {
        providers.sorted(by: isHigherPriority).first
    }

    private static func isHigherPriority(
        _ lhs: UsageWidgetProviderData,
        _ rhs: UsageWidgetProviderData
    ) -> Bool {
        if lhs.summary.observedUsedPercent != rhs.summary.observedUsedPercent {
            return lhs.summary.observedUsedPercent > rhs.summary.observedUsedPercent
        }

        switch (lhs.resetAt, rhs.resetAt) {
        case let (left?, right?) where left != right:
            return left < right
        case (_?, nil):
            return true
        case (nil, _?):
            return false
        default:
            return lhs.name < rhs.name
        }
    }
}

private enum UsageWidgetDate {
    private static let formatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "h:mm a"
        return formatter
    }()

    static func updated(_ date: Date) -> String {
        "Updated \(formatter.string(from: date))"
    }
}

private struct UsageRingView: View {
    let progress: Double?
    let diameter: CGFloat
    let lineWidth: CGFloat
    let heroFontSize: CGFloat

    private var clampedProgress: Double {
        min(max(progress ?? 0, 0), 1)
    }

    private var heroText: String {
        guard let progress else { return "—" }
        let remainingPercent = Int((min(max(progress, 0), 1) * 100).rounded())
        return "\(remainingPercent)%"
    }

    private var accessibilityText: String {
        guard let progress else { return "Usage not connected" }
        let remainingPercent = Int((min(max(progress, 0), 1) * 100).rounded())
        return "\(remainingPercent) percent remaining"
    }

    var body: some View {
        ZStack {
            Circle()
                .stroke(LifeOSTokens.Ring.track, lineWidth: lineWidth)

            if progress != nil, clampedProgress > 0 {
                Circle()
                    .trim(from: 0, to: clampedProgress)
                    .stroke(
                        LifeOSTokens.Ring.progress(.blue),
                        style: StrokeStyle(lineWidth: lineWidth, lineCap: .round)
                    )
                    .rotationEffect(.degrees(-90))
            }

            Text(heroText)
                .font(.system(size: heroFontSize, weight: .bold, design: .rounded))
                .monospacedDigit()
                .foregroundStyle(progress == nil ? Color.secondary : Color.primary)
        }
        .frame(width: diameter, height: diameter)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityText)
    }
}

struct LifeOSUsageSmallWidgetView: View {
    let entry: LifeOSEntry

    private var providers: [UsageWidgetProviderData] {
        UsageWidgetData.providers(from: entry.snapshot)
    }

    private var lead: UsageWidgetProviderData? {
        UsageWidgetData.leading(from: providers)
    }

    private var label: String {
        guard let lead else { return "Not connected" }
        return "\(lead.name) · \(lead.summary.windowIndicator)"
    }

    var body: some View {
        VStack(spacing: 4) {
            UsageRingView(
                progress: lead.map { $0.summary.remainingPercent },
                diameter: 56,
                lineWidth: 6,
                heroFontSize: 15
            )

            Text(label)
                .font(.system(size: 9, weight: .semibold))
                .lineLimit(1)
                .minimumScaleFactor(0.8)

            HStack(spacing: 5) {
                Text(UsageWidgetDate.updated(entry.snapshot.updatedAt))
                if entry.snapshot.provenance.quality == .demo {
                    Text("PREVIEW").fontWeight(.bold)
                }
            }
            .font(.system(size: 8, weight: .medium))
            .foregroundStyle(LifeOSTokens.tertiaryText)
            .lineLimit(1)
            .minimumScaleFactor(0.7)
        }
        .padding(10)
        .containerBackground(for: .widget) { LifeOSTokens.surface }
        .widgetURL(URL(string: "lifeos://usage"))
        .accessibilityElement(children: .combine)
        .accessibilityLabel(accessibilitySummary)
    }

    private var accessibilitySummary: String {
        guard let lead else { return "Usage, not connected" }
        return "Usage, \(lead.name), \(Int((lead.summary.remainingPercent * 100).rounded())) percent remaining, \(lead.summary.windowIndicator) window"
    }
}

struct LifeOSWidgetView: View {
    let entry: LifeOSEntry

    private var providers: [UsageWidgetProviderData] {
        UsageWidgetData.providers(from: entry.snapshot)
    }

    private var lead: UsageWidgetProviderData? {
        UsageWidgetData.leading(from: providers)
    }

    private var secondary: UsageWidgetProviderData? {
        providers.first { $0.id != lead?.id }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(alignment: .top, spacing: 12) {
                VStack(spacing: 4) {
                    UsageRingView(
                        progress: lead.map { $0.summary.remainingPercent },
                        diameter: 72,
                        lineWidth: 8,
                        heroFontSize: 18
                    )

                    Text(lead.map { "\($0.name) · \($0.summary.windowIndicator) window" } ?? "Not connected")
                        .font(.system(size: 9, weight: .semibold))
                        .lineLimit(1)
                        .minimumScaleFactor(0.72)

                    if let secondary {
                        HStack(spacing: 4) {
                            Circle()
                                .fill(LifeOSTokens.Hue.teal.base)
                                .frame(width: 5, height: 5)
                            Text(secondary.name)
                            Spacer(minLength: 1)
                            Text("\(Int((secondary.summary.remainingPercent * 100).rounded()))%")
                                .monospacedDigit()
                                .foregroundStyle(LifeOSTokens.Hue.teal.base)
                        }
                        .font(.system(size: 8, weight: .semibold))
                        .lineLimit(1)
                    }
                }
                .frame(width: 106)

                SharedUsageGraph(summary: lead)
                    .frame(maxWidth: .infinity, minHeight: 74)
            }

            HStack(spacing: 4) {
                Text(lead == nil ? "Not connected" : "Current use · projected dashed")
                Spacer(minLength: 4)
                Text(UsageWidgetDate.updated(entry.snapshot.updatedAt))
                if entry.snapshot.provenance.quality == .demo {
                    Text("PREVIEW").fontWeight(.bold)
                }
            }
            .font(.system(size: 8, weight: .medium))
            .foregroundStyle(LifeOSTokens.tertiaryText)
            .lineLimit(1)
            .minimumScaleFactor(0.6)
        }
        .padding(12)
        .containerBackground(for: .widget) { LifeOSTokens.surface }
        .widgetURL(URL(string: "lifeos://usage"))
        .accessibilityElement(children: .combine)
        .accessibilityLabel(accessibilitySummary)
    }

    private var accessibilitySummary: String {
        guard let lead else { return "Usage overview, not connected" }
        var result = "Usage overview, \(lead.name) \(Int((lead.summary.remainingPercent * 100).rounded())) percent remaining, \(lead.summary.windowIndicator) window"
        if let secondary {
            result += ", \(secondary.name) \(Int((secondary.summary.remainingPercent * 100).rounded())) percent remaining"
        }
        return result
    }
}

private struct SharedUsageGraph: View {
    let summary: UsageWidgetProviderData?

    private let observedX = 0.62

    var body: some View {
        GeometryReader { proxy in
            let inset: CGFloat = 4
            let width = max(1, proxy.size.width - inset * 2)
            let height = max(1, proxy.size.height - inset * 2)
            let projected = summary?.summary.projectedUsedPercent
            let newestValue = projected ?? summary?.summary.observedUsedPercent ?? 0.5
            let newestX = 1.0
            let newestPoint = point(
                x: newestX,
                value: newestValue,
                width: width,
                height: height,
                inset: inset
            )

            ZStack {
                Canvas { context, size in
                    let graphWidth = max(1, size.width - inset * 2)
                    let graphHeight = max(1, size.height - inset * 2)
                    let flatValue = summary?.summary.observedUsedPercent ?? 0.5
                    let observedValue = summary?.summary.observedUsedPercent ?? flatValue
                    let observedEndX = projected == nil ? 1.0 : observedX
                    let start = point(x: 0, value: observedValue, width: graphWidth, height: graphHeight, inset: inset)
                    let observedEnd = point(x: observedEndX, value: observedValue, width: graphWidth, height: graphHeight, inset: inset)
                    let end = point(x: 1, value: projected ?? observedValue, width: graphWidth, height: graphHeight, inset: inset)

                    var trend = Path()
                    trend.move(to: start)
                    trend.addLine(to: observedEnd)
                    if projected != nil {
                        trend.addLine(to: end)
                    }

                    if summary != nil {
                        var area = trend
                        area.addLine(to: CGPoint(x: end.x, y: size.height - inset))
                        area.addLine(to: CGPoint(x: start.x, y: size.height - inset))
                        area.closeSubpath()
                        context.fill(
                            area,
                            with: .linearGradient(
                                Gradient(colors: [
                                    LifeOSTokens.Hue.blue.base.opacity(0.12),
                                    Color.clear
                                ]),
                                startPoint: CGPoint(x: 0, y: inset),
                                endPoint: CGPoint(x: 0, y: size.height - inset)
                            )
                        )

                        var observed = Path()
                        observed.move(to: start)
                        observed.addLine(to: observedEnd)
                        context.stroke(
                            observed,
                            with: .linearGradient(
                                Gradient(colors: [LifeOSTokens.Hue.blue.base, LifeOSTokens.Hue.blue.glow]),
                                startPoint: CGPoint(x: 0, y: 0),
                                endPoint: CGPoint(x: size.width, y: 0)
                            ),
                            style: StrokeStyle(lineWidth: 2.2, lineCap: .round)
                        )

                        if projected != nil {
                            var estimate = Path()
                            estimate.move(to: observedEnd)
                            estimate.addLine(to: end)
                            context.stroke(
                                estimate,
                                with: .linearGradient(
                                    Gradient(colors: [
                                        LifeOSTokens.Hue.blue.base.opacity(0.50),
                                        LifeOSTokens.Hue.blue.glow.opacity(0.50)
                                    ]),
                                    startPoint: CGPoint(x: 0, y: 0),
                                    endPoint: CGPoint(x: size.width, y: 0)
                                ),
                                style: StrokeStyle(lineWidth: 2.2, lineCap: .round, dash: [3, 3])
                            )
                        }
                    } else {
                        context.stroke(
                            trend,
                            with: .color(Color.secondary.opacity(0.28)),
                            style: StrokeStyle(lineWidth: 1.5, lineCap: .round)
                        )
                    }
                }

                if summary != nil {
                    Circle()
                        .fill(LifeOSTokens.Hue.blue.base)
                        .frame(width: 5, height: 5)
                        .position(newestPoint)
                }
            }
        }
        .accessibilityHidden(true)
    }

    private func point(x: Double, value: Double, width: CGFloat, height: CGFloat, inset: CGFloat) -> CGPoint {
        CGPoint(
            x: inset + width * CGFloat(x),
            y: inset + height * (1 - min(max(value, 0), 1))
        )
    }
}

struct LifeOSWidget: Widget {
    let kind = "LifeOSWidget"

    var body: some WidgetConfiguration {
        StaticConfiguration(kind: kind, provider: LifeOSTimelineProvider()) { LifeOSWidgetView(entry: $0) }
            .configurationDisplayName("Usage overview")
            .description("Connected AI provider limits with a shared projection graph")
            .supportedFamilies([.systemMedium])
    }
}

struct LifeOSUsageSmallWidget: Widget {
    let kind = "LifeOSUsageSmallWidget"

    var body: some WidgetConfiguration {
        StaticConfiguration(kind: kind, provider: LifeOSTimelineProvider()) { LifeOSUsageSmallWidgetView(entry: $0) }
            .configurationDisplayName("Usage ring")
            .description("Remaining AI usage in a compact ring")
            .supportedFamilies([.systemSmall])
    }
}

#if os(iOS)
private struct LifeOSUsageAccessoryCircularView: View {
    let entry: LifeOSEntry

    private var lead: UsageWidgetProviderData? {
        let providers = UsageWidgetData.providers(from: entry.snapshot)
        return UsageWidgetData.leading(from: providers)
    }

    var body: some View {
        ProgressView(value: lead?.summary.remainingPercent ?? 0, total: 1)
            .progressViewStyle(.circular)
            .widgetAccentable()
            .containerBackground(for: .widget) { Color.clear }
            .widgetURL(URL(string: "lifeos://usage"))
            .accessibilityLabel(accessibilitySummary)
    }

    private var accessibilitySummary: String {
        guard let lead else { return "Usage, not connected" }
        return "Usage, \(lead.name), \(Int((lead.summary.remainingPercent * 100).rounded())) percent remaining"
    }
}

struct LifeOSUsageLockScreenWidget: Widget {
    let kind = "LifeOSUsageLockScreenWidget"

    var body: some WidgetConfiguration {
        StaticConfiguration(kind: kind, provider: LifeOSTimelineProvider()) { LifeOSUsageAccessoryCircularView(entry: $0) }
            .configurationDisplayName("Usage")
            .description("Remaining AI usage on the Lock Screen")
            .supportedFamilies([.accessoryCircular])
    }
}
#endif
