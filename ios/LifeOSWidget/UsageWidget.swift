import SwiftUI
import WidgetKit

struct LifeOSTimelineProvider: TimelineProvider {
    func placeholder(in context: Context) -> LifeOSEntry {
        LifeOSEntry(date: .now, snapshot: DemoDataProvider.widget())
    }

    func getSnapshot(in context: Context, completion: @escaping (LifeOSEntry) -> Void) {
        let snapshot = context.isPreview
            ? DemoDataProvider.widget()
            : SharedSnapshotStore.read() ?? WidgetSnapshot.unavailable()
        completion(LifeOSEntry(date: .now, snapshot: snapshot))
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<LifeOSEntry>) -> Void) {
        let entry = LifeOSEntry(
            date: .now,
            snapshot: SharedSnapshotStore.read() ?? WidgetSnapshot.unavailable()
        )
        completion(Timeline(entries: [entry], policy: .after(.now.addingTimeInterval(900))))
    }
}

struct LifeOSEntry: TimelineEntry { let date: Date; let snapshot: WidgetSnapshot }

struct LifeOSWidgetView: View {
    let entry: LifeOSEntry
    @Environment(\.colorScheme) private var colorScheme

    private var primaryText: Color { colorScheme == .dark ? .lifeOSWhite : .lifeOSBlue950 }
    private var secondaryText: Color { colorScheme == .dark ? .lifeOSBlue100 : .lifeOSBlue700 }
    private var summaries: [UsageWidgetSummary] { entry.snapshot.providers.compactMap(UsageWidgetSummary.init) }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                HStack(spacing: 7) {
                    LifeOSIcon(.usage).frame(width: 16, height: 16)
                    Text("Usage")
                }
                .font(.headline.weight(.bold))
                .foregroundStyle(primaryText)
                Spacer()
                Text(entry.snapshot.provenance.quality == .demo ? "PREVIEW" : entry.snapshot.freshness.rawValue.uppercased())
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(secondaryText)
            }

            HStack(alignment: .top, spacing: 12) {
                VStack(alignment: .leading, spacing: 7) {
                    ForEach(summaries, id: \.provider) { summary in
                        HStack(spacing: 6) {
                            Circle().fill(color(summary.provider)).frame(width: 6, height: 6)
                            Text(summary.provider == .codex ? "Codex" : "Claude")
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(primaryText)
                            Spacer(minLength: 4)
                            Text(summary.remainingPercent, format: .percent.precision(.fractionLength(0)))
                                .font(.caption.monospacedDigit().weight(.bold))
                                .foregroundStyle(color(summary.provider))
                            Text("(\(summary.windowIndicator))")
                                .font(.system(size: 8, weight: .medium))
                                .foregroundStyle(secondaryText)
                        }
                    }
                }
                .frame(width: 118)

                SharedUsageGraph(summaries: summaries)
                    .frame(maxWidth: .infinity, minHeight: 58)
            }

            Spacer(minLength: 0)
            HStack {
                Text("Target 35% · projection 65% opacity")
                Spacer()
                Text(entry.snapshot.updatedAt, style: .time)
            }
            .font(.system(size: 8))
            .foregroundStyle(primaryText.opacity(0.62))
        }
        .padding(15)
        .containerBackground(for: .widget) { LifeOSTokens.surface }
        .widgetURL(URL(string: "lifeos://usage"))
        .accessibilityElement(children: .combine)
        .accessibilityLabel(accessibilitySummary)
    }

    private var accessibilitySummary: String {
        let values = summaries.map {
            "\($0.provider == .codex ? "Codex" : "Claude") \($0.remainingPercent.formatted(.percent)) left, \($0.windowIndicator) window"
        }.joined(separator: ", ")
        return "Usage overview, \(values), \(entry.snapshot.provenance.quality.rawValue) data"
    }

    private func color(_ provider: Provider) -> Color {
        provider == .codex
            ? Color(red: 0.55, green: 0.32, blue: 0.96)
            : Color(red: 0.94, green: 0.43, blue: 0.18)
    }
}

private struct SharedUsageGraph: View {
    let summaries: [UsageWidgetSummary]

    var body: some View {
        Canvas { context, size in
            let inset: CGFloat = 2
            let graphHeight = max(1, size.height - inset * 2)
            let graphWidth = max(1, size.width - inset * 2)

            for guide in [0.25, 0.5, 0.75] {
                var path = Path()
                let y = inset + graphHeight * (1 - guide)
                path.move(to: CGPoint(x: inset, y: y))
                path.addLine(to: CGPoint(x: size.width - inset, y: y))
                context.stroke(path, with: .color(Color.secondary.opacity(0.08)), lineWidth: 1)
            }

            for summary in summaries {
                let providerColor = color(summary.provider)
                let start = max(0, summary.observedUsedPercent * 0.72)
                let end = summary.projectedUsedPercent ?? min(1, summary.observedUsedPercent * 1.28)

                var target = Path()
                target.move(to: point(x: 0, value: start, width: graphWidth, height: graphHeight, inset: inset))
                target.addCurve(
                    to: point(x: 1, value: min(1, summary.observedUsedPercent + 0.10), width: graphWidth, height: graphHeight, inset: inset),
                    control1: point(x: 0.35, value: start + 0.02, width: graphWidth, height: graphHeight, inset: inset),
                    control2: point(x: 0.72, value: summary.observedUsedPercent + 0.04, width: graphWidth, height: graphHeight, inset: inset)
                )
                context.stroke(target, with: .color(providerColor.opacity(0.35)), style: StrokeStyle(lineWidth: 1.5, dash: [3, 3]))

                var projection = Path()
                projection.move(to: point(x: 0, value: summary.observedUsedPercent, width: graphWidth, height: graphHeight, inset: inset))
                projection.addCurve(
                    to: point(x: 1, value: end, width: graphWidth, height: graphHeight, inset: inset),
                    control1: point(x: 0.28, value: summary.observedUsedPercent + (end - summary.observedUsedPercent) * 0.16, width: graphWidth, height: graphHeight, inset: inset),
                    control2: point(x: 0.66, value: summary.observedUsedPercent + (end - summary.observedUsedPercent) * 0.78, width: graphWidth, height: graphHeight, inset: inset)
                )
                context.stroke(projection, with: .color(providerColor.opacity(0.65)), style: StrokeStyle(lineWidth: 2.2, lineCap: .round))
            }
        }
        .accessibilityHidden(true)
    }

    private func point(x: Double, value: Double, width: CGFloat, height: CGFloat, inset: CGFloat) -> CGPoint {
        CGPoint(x: inset + width * x, y: inset + height * (1 - min(max(value, 0), 1)))
    }

    private func color(_ provider: Provider) -> Color {
        provider == .codex
            ? Color(red: 0.55, green: 0.32, blue: 0.96)
            : Color(red: 0.94, green: 0.43, blue: 0.18)
    }
}

struct LifeOSWidget: Widget {
    let kind = "LifeOSWidget"
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: kind, provider: LifeOSTimelineProvider()) { LifeOSWidgetView(entry: $0) }
            .configurationDisplayName("Usage overview")
            .description("Codex and Claude remaining limits with a shared projection graph")
            .supportedFamilies([.systemMedium])
    }
}
