import Foundation

public enum DemoDataProvider {
    /// Fixed reference time keeps previews and screenshot fixtures reproducible.
    public static let observedAt = Date(timeIntervalSince1970: 1_785_283_200)
    public static let provenance = Provenance(source: "Demo fixture", observedAt: observedAt, quality: .demo, connector: .healthy)
    public static let unavailableProvenance = Provenance(
        source: "No validated demo provider observation",
        observedAt: observedAt,
        quality: .unavailable,
        connector: .unavailable
    )
    public static let codex = ProviderSnapshot(
        provider: .codex,
        accountLabel: "Demo Codex account",
        windows: [
            UsageWindow(id: "5h", label: "5-hour", limit: 1, used: 0.42, resetAt: observedAt.addingTimeInterval(3_600), durationMinutes: 300),
            UsageWindow(id: "7d", label: "7-day", limit: 1, used: 0.18, resetAt: observedAt.addingTimeInterval(86_400 * 3), projection: Projection(percentAtReset: 0.22, percentAtExhaustion: 0.95, confidence: 0.72, sampleSpan: "14 days"), durationMinutes: 10_080)
        ],
        model: "Demo model",
        metrics: [],
        provenance: provenance
    )
    public static let claude = ProviderSnapshot(
        provider: .claude,
        accountLabel: "Demo Claude account",
        windows: [
            UsageWindow(id: "5h", label: "5-hour", durationMinutes: 300),
            UsageWindow(id: "7d", label: "7-day", limit: 1, used: 0.31, resetAt: observedAt.addingTimeInterval(86_400 * 2), durationMinutes: 10_080)
        ],
        provenance: provenance
    )
    public static let glm = ProviderSnapshot(
        provider: .glm,
        accountLabel: "GLM",
        windows: [],
        provenance: unavailableProvenance
    )
    public static let deepSeek = ProviderSnapshot(
        provider: .deepseek,
        accountLabel: "DeepSeek",
        windows: [],
        provenance: unavailableProvenance
    )
    public static let googleAIStudio = ProviderSnapshot(
        provider: .googleAIStudio,
        accountLabel: "Google AI Studio",
        windows: [],
        provenance: unavailableProvenance
    )
    public static var providers: [ProviderSnapshot] { [codex, claude, glm, deepSeek, googleAIStudio] }
    public static func widget(now: Date = .now) -> WidgetSnapshot {
        WidgetSnapshot(
            providers: providers,
            codexStatus: "Demo active",
            clipperSignal: "Blocked · connector",
            healthSignal: "Blocked · HealthKit",
            financeSignal: "Blocked · import",
            updatedAt: observedAt,
            freshness: provenance.freshness(now: now),
            warning: "Demo data only",
            provenance: provenance
        )
    }
}

/// Deterministic, synthetic calendar content used only by previews and visual QA.
/// It exercises overlap, overnight clipping, all progress states, emoji, a bounded
/// custom image, and a month boundary without using personal information.
public enum CalendarVisualFixtures {
    /// A deterministic sanitized asset used only by icon-picker visual
    /// evidence. It is never loaded by a normal production calendar.
    public static var reusableIcon: CalendarReusableIcon? {
        let bytes = Data(base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNk+A8AAQUBAScY42YAAAAASUVORK5CYII=")
        guard let bytes, let asset = try? CalendarIconAsset(format: .png, bytes: bytes) else { return nil }
        return try? CalendarReusableIcon(name: "Fixture mark", asset: asset)
    }

    public static func snapshot(anchor: Date = .now, calendar: Calendar = .current) -> CalendarSnapshot {
        let day = calendar.startOfDay(for: anchor)
        func instant(dayOffset: Int = 0, hour: Int, minute: Int = 0) -> Date {
            let shifted = calendar.date(byAdding: .day, value: dayOffset, to: day) ?? day
            return calendar.date(bySettingHour: hour, minute: minute, second: 0, of: shifted) ?? shifted
        }
        func item(
            id: String,
            title: String,
            icon: String,
            asset: CalendarIconAsset? = nil,
            status: CalendarProgress,
            start: Date,
            end: Date
        ) -> CalendarItem? {
            try? CalendarItem(
                id: UUID(uuidString: id)!, title: title, icon: icon, iconAsset: asset,
                status: status, start: start, end: end, createdAt: day, updatedAt: day
            )
        }

        let tinyPNG = Data(base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNk+A8AAQUBAScY42YAAAAASUVORK5CYII=")
        let customIcon = tinyPNG.flatMap { try? CalendarIconAsset(format: .png, bytes: $0) }
        let monthStart = calendar.date(from: calendar.dateComponents([.year, .month], from: day)) ?? day
        let nextMonth = calendar.date(byAdding: .month, value: 1, to: monthStart) ?? day
        let monthBoundaryStart = calendar.date(byAdding: .hour, value: -1, to: nextMonth) ?? nextMonth
        let monthBoundaryEnd = calendar.date(byAdding: .hour, value: 2, to: nextMonth) ?? nextMonth

        return CalendarSnapshot(items: [
            item(id: "10000000-0000-0000-0000-000000000001", title: "Deep work", icon: "🎯", status: .inProgress,
                 start: instant(hour: 9), end: instant(hour: 11)),
            item(id: "10000000-0000-0000-0000-000000000002", title: "Design review", icon: "✏️", status: .planned,
                 start: instant(hour: 9, minute: 30), end: instant(hour: 10, minute: 30)),
            item(id: "10000000-0000-0000-0000-000000000003", title: "Ship checkpoint", icon: "🚀", asset: customIcon, status: .done,
                 start: instant(hour: 13), end: instant(hour: 14, minute: 15)),
            item(id: "10000000-0000-0000-0000-000000000004", title: "Cancelled call", icon: "☎️", status: .aborted,
                 start: instant(dayOffset: 1, hour: 15), end: instant(dayOffset: 1, hour: 16)),
            item(id: "10000000-0000-0000-0000-000000000005", title: "Overnight focus", icon: "🌙", status: .planned,
                 start: instant(dayOffset: 1, hour: 23), end: instant(dayOffset: 2, hour: 1)),
            item(id: "10000000-0000-0000-0000-000000000006", title: "Month handoff", icon: "📆", status: .planned,
                 start: monthBoundaryStart, end: monthBoundaryEnd)
        ].compactMap { $0 })
    }
}
