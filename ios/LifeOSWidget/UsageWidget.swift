import SwiftUI
import WidgetKit

struct LifeOSTimelineProvider: TimelineProvider {
    func placeholder(in context: Context) -> LifeOSEntry { LifeOSEntry(date: .now, snapshot: DemoDataProvider.widget()) }
    func getSnapshot(in context: Context, completion: @escaping (LifeOSEntry) -> Void) { completion(LifeOSEntry(date: .now, snapshot: SharedSnapshotStore.read() ?? DemoDataProvider.widget())) }
    func getTimeline(in context: Context, completion: @escaping (Timeline<LifeOSEntry>) -> Void) {
        let entry = LifeOSEntry(date: .now, snapshot: SharedSnapshotStore.read() ?? DemoDataProvider.widget())
        completion(Timeline(entries: [entry], policy: .after(.now.addingTimeInterval(900))))
    }
}

struct LifeOSEntry: TimelineEntry { let date: Date; let snapshot: WidgetSnapshot }

struct LifeOSWidgetView: View {
    let entry: LifeOSEntry
    @Environment(\.colorScheme) private var colorScheme

    private var primaryText: Color { colorScheme == .dark ? .lifeOSWhite : .lifeOSBlue950 }
    private var secondaryText: Color { colorScheme == .dark ? .lifeOSBlue100 : .lifeOSBlue700 }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Label("Usage", systemImage: "chart.bar.xaxis")
                    .font(.headline.weight(.bold))
                    .foregroundStyle(primaryText)
                Spacer()
                Text(entry.snapshot.freshness.rawValue.capitalized)
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(secondaryText)
            }
            ForEach(entry.snapshot.providers, id: \.provider) { provider in
                HStack {
                    Text(provider.provider.rawValue.capitalized).font(.subheadline.weight(.semibold)).foregroundStyle(primaryText)
                    Spacer()
                    Text(summary(provider)).font(.subheadline.monospacedDigit().weight(.bold)).foregroundStyle(secondaryText)
                }
            }
            Text("Source · \(entry.snapshot.provenance.source) · \(entry.snapshot.provenance.quality.rawValue)")
                .font(.caption2).foregroundStyle(primaryText.opacity(0.7)).lineLimit(1)
            Spacer(minLength: 0)
            Text("Updated \(entry.snapshot.updatedAt, style: .time)")
                .font(.caption2).foregroundStyle(primaryText.opacity(0.7))
        }
        .padding(16)
        .containerBackground(for: .widget) { LifeOSTokens.surface }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Usage overview, \(entry.snapshot.freshness.rawValue)")
    }

    private func summary(_ provider: ProviderSnapshot) -> String {
        guard let window = provider.windows.first(where: { $0.used != nil }), let used = window.used,
              let limit = window.limit, limit > 0 else { return "Unavailable" }
        return "\(Int((min(max(used / limit, 0), 1) * 100).rounded()))%"
    }
}

struct LifeOSWidget: Widget {
    let kind = "LifeOSWidget"
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: kind, provider: LifeOSTimelineProvider()) { LifeOSWidgetView(entry: $0) }
            .configurationDisplayName("Usage overview")
            .description("Privacy-safe provider usage summary")
            .supportedFamilies([.systemMedium])
    }
}
