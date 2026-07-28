import SwiftUI
import WidgetKit

struct LifeOSTimelineProvider: TimelineProvider {
    func placeholder(in context: Context) -> LifeOSEntry {
        LifeOSEntry(date: .now, snapshot: DemoDataProvider.widget())
    }

    func getSnapshot(in context: Context, completion: @escaping (LifeOSEntry) -> Void) {
        completion(LifeOSEntry(date: .now, snapshot: SharedSnapshotStore.read() ?? DemoDataProvider.widget()))
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<LifeOSEntry>) -> Void) {
        let entry = LifeOSEntry(date: .now, snapshot: SharedSnapshotStore.read() ?? DemoDataProvider.widget())
        completion(Timeline(entries: [entry], policy: .after(.now.addingTimeInterval(900))))
    }
}

struct LifeOSEntry: TimelineEntry {
    let date: Date
    let snapshot: WidgetSnapshot
}

struct LifeOSWidgetView: View {
    let entry: LifeOSEntry

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("Usage").font(.headline)
                Spacer()
                Text(entry.snapshot.freshness.rawValue).font(.caption).foregroundStyle(.secondary)
            }
            ForEach(entry.snapshot.providers, id: \.provider) { provider in
                HStack {
                    Text(provider.provider.rawValue).font(.subheadline.bold())
                    Spacer()
                    Text(summary(provider)).font(.caption)
                }
            }
            Text("Source · \(entry.snapshot.provenance.source) · \(entry.snapshot.provenance.quality.rawValue)")
                .font(.caption2).foregroundStyle(.secondary)
            Text(entry.snapshot.warning ?? "Unavailable").font(.caption2).foregroundStyle(.secondary)
            Spacer()
            Text("Updated \(entry.snapshot.updatedAt, style: .time)").font(.caption2).foregroundStyle(.secondary)
        }
        .padding()
        .containerBackground(.background, for: .widget)
    }

    private func summary(_ provider: ProviderSnapshot) -> String {
        guard let window = provider.windows.first(where: { $0.used != nil }), let used = window.used else {
            return "Unavailable"
        }
        return "\(Int((used * 100).rounded()))%"
    }
}

struct LifeOSWidget: Widget {
    let kind = "LifeOSWidget"

    var body: some WidgetConfiguration {
        StaticConfiguration(kind: kind, provider: LifeOSTimelineProvider()) {
            LifeOSWidgetView(entry: $0)
        }
        .configurationDisplayName("Usage overview")
        .description("Privacy-safe provider usage summary")
        .supportedFamilies([.systemMedium])
    }
}
