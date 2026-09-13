import Foundation

public enum OverviewSectionKind: String, Codable, CaseIterable, Sendable {
    case llm
    case clipper
    case health
    case finance
}

public enum OverviewMetricIcon: String, Codable, Equatable, Sendable {
    case usage
    case views
    case subscribers
    case revenue
    case heartRate = "heart_rate"
    case sleep
    case health
    case savings
    case budget
}

/// Overview's compact projection predates Clipper's richer `partial` quality
/// enum. Keep that distinction explicit at the section boundary rather than
/// relabelling a partial provider payload as complete observed data.
public enum OverviewSectionState: String, Codable, Equatable, Sendable {
    case complete
    case partial
}

public struct OverviewMetric: Codable, Equatable, Identifiable, Sendable {
    public let id: String
    public let label: String
    public let value: String?
    public let unit: String?
    public let icon: OverviewMetricIcon

    public init(id: String? = nil, label: String, value: String?, unit: String? = nil, icon: OverviewMetricIcon) {
        self.id = id ?? label.lowercased().replacingOccurrences(of: " ", with: "-")
        self.label = label
        self.value = value
        self.unit = unit
        self.icon = icon
    }

    public var displayValue: String? {
        guard let value else { return nil }
        guard let unit, !unit.isEmpty else { return value }
        return "\(value) \(unit)"
    }
}

public struct OverviewSection: Codable, Equatable, Identifiable, Sendable {
    public var id: OverviewSectionKind { kind }
    public let kind: OverviewSectionKind
    public let title: String
    public let metrics: [OverviewMetric]
    public let provenance: Provenance
    public let state: OverviewSectionState

    public init(kind: OverviewSectionKind, title: String, metrics: [OverviewMetric], provenance: Provenance,
                state: OverviewSectionState = .complete) {
        self.kind = kind
        self.title = title
        self.metrics = metrics
        self.provenance = provenance
        self.state = state
    }
}

public struct OverviewSnapshot: Codable, Equatable, Sendable {
    public let sections: [OverviewSection]
    public let generatedAt: Date
    /// The typed provider-neutral payload is retained for the Clipper detail
    /// route. The compact sections remain the Home projection, while detail
    /// rendering can distinguish an observed empty breakdown from unavailable
    /// connector data without re-fetching or inventing rows.
    public let clipperSnapshot: ClipperSnapshot?

    public init(sections: [OverviewSection], generatedAt: Date, clipperSnapshot: ClipperSnapshot? = nil) {
        self.sections = sections
        self.generatedAt = generatedAt
        self.clipperSnapshot = clipperSnapshot
    }
}

public extension OverviewSection {
    func metric(containing needle: String) -> OverviewMetric? {
        metrics.first { $0.label.localizedCaseInsensitiveContains(needle) }
    }

    /// Builds the Home Usage summary from provider snapshots only. A missing
    /// observed window remains nil; this helper never turns an unavailable
    /// provider into a zero or an estimate.
    static func usageSummary(from providers: [ProviderSnapshot], generatedAt: Date = .now) -> OverviewSection {
        let metrics = Provider.allCases.map { provider in
            let used = providers.first(where: { $0.provider == provider })?.smallestObservedWindow?.usedPercent
            let remaining = used.map { Int(((1 - $0) * 100).rounded()) }
            return OverviewMetric(
                label: provider.displayName,
                value: remaining.map(String.init),
                unit: "% left",
                icon: .usage
            )
        } + [OverviewMetric(label: "Banked resets", value: nil, icon: .usage)]

        let observed = providers.filter { $0.provenance.quality == .observed }
        let demo = providers.contains { $0.provenance.quality == .demo }
        let quality: DataQuality = observed.isEmpty ? (demo ? .demo : .unavailable) : .observed
        let connector: ConnectorState
        if observed.isEmpty {
            connector = .unavailable
        } else {
            connector = observed.allSatisfy { $0.provenance.connector == .healthy } ? .healthy : .refreshDue
        }
        let observedAt = providers.map { $0.provenance.observedAt }.max() ?? generatedAt
        let source: String
        switch quality {
        case .observed: source = "Provider-specific usage observations"
        case .demo: source = "Demo fixture"
        case .estimated: source = "No validated usage source"
        case .unavailable: source = "No connected usage source"
        }

        return OverviewSection(
            kind: .llm,
            title: "LLM",
            metrics: metrics,
            provenance: Provenance(source: source, observedAt: observedAt, quality: quality, connector: connector)
        )
    }

    /// Adapts the typed Clipper payload to the compact Home contract. Missing
    /// metrics remain nil; the Overview surface never turns an unavailable
    /// provider field into zero or a fabricated estimate.
    static func clipperSummary(from snapshot: ClipperSnapshot) -> OverviewSection {
        let provenance = Provenance(
            source: snapshot.provenance.source,
            observedAt: snapshot.provenance.observedAt,
            quality: snapshot.availability == .observed ? .observed : .unavailable,
            connector: snapshot.provenance.connectorState
        )
        let metrics = snapshot.metrics
        return OverviewSection(
            kind: .clipper,
            title: "Clipper",
            metrics: [
                OverviewMetric(label: "Views today", value: countValue(metrics?.views), icon: .views),
                OverviewMetric(label: "Subscribers today", value: countValue(metrics?.subscribers), icon: .subscribers),
                OverviewMetric(label: "Revenue this month", value: revenueValue(metrics?.revenue), icon: .revenue)
            ],
            provenance: provenance,
            state: snapshot.availability == .observed && snapshot.provenance.quality == .partial ? .partial : .complete
        )
    }

    private static func countValue(_ metric: ClipperCountMetric?) -> String? {
        guard let metric, metric.availability == .observed, let value = metric.value else { return nil }
        return String(value)
    }

    private static func revenueValue(_ metric: ClipperRevenueMetric?) -> String? {
        guard let metric, metric.availability == .observed, let amountCents = metric.amountCents else { return nil }
        let euros = amountCents / 100
        let cents = amountCents % 100
        guard cents != 0 else { return "€\(euros)" }
        let centsText = cents < 10 ? "0\(cents)" : "\(cents)"
        return "€\(euros).\(centsText)"
    }
}

/// A small, provider-neutral point used by Home's compact trend charts. The
/// projection helpers below only transform observations already present in a
/// coordinator snapshot; they never create a second point to make a chart fit.
public struct OverviewChartPoint: Identifiable, Equatable, Sendable {
    public let date: Date
    public let value: Double

    public var id: Date { date }

    public init(date: Date, value: Double) {
        self.date = date
        self.value = value
    }
}

public enum OverviewChartAxisLabelMode: String, Equatable, Sendable {
    case time
    case day
}

public enum OverviewChartAxis {
    /// Use clock labels for a sub-day window and calendar-day labels once the
    /// series spans a day or more. This keeps the compact Home chart from
    /// repeating the same weekday/day label for every short-window point.
    public static func labelMode(for points: [OverviewChartPoint]) -> OverviewChartAxisLabelMode {
        guard let first = points.first?.date, let last = points.last?.date,
              last.timeIntervalSince(first) < 24 * 60 * 60 else {
            return .day
        }
        return .time
    }
}

public enum OverviewUsageTrendPresentation {
    public static func label(for quality: DataQuality?) -> String {
        switch quality {
        case .observed: return "Observed trend"
        case .demo: return "Demo fixture · not live"
        case .estimated: return "Estimated activity"
        case .unavailable, nil: return "History unavailable"
        }
    }

    public static func isRenderable(for quality: DataQuality?) -> Bool {
        quality != nil && quality != .unavailable
    }
}

public enum OverviewClipperTrendMetric: String, CaseIterable, Equatable, Sendable {
    case views
    case subscribers
    case revenue

    public var title: String {
        switch self {
        case .views: "Views"
        case .subscribers: "Subscribers"
        case .revenue: "Revenue"
        }
    }

    public var unit: String {
        switch self {
        case .views, .subscribers: ""
        case .revenue: "EUR cents"
        }
    }
}

public struct OverviewClipperTrend: Equatable, Sendable {
    public let metric: OverviewClipperTrendMetric
    public let points: [OverviewChartPoint]

    public init(metric: OverviewClipperTrendMetric, points: [OverviewChartPoint]) {
        self.metric = metric
        self.points = points
    }
}

/// Pure, source-driven chart projections for the Home cards. Keeping this in
/// the shared domain makes the "no fabricated history" rule testable without
/// instantiating SwiftUI or a coordinator.
public enum OverviewChartProjection {
    /// Converts observed hourly usage activity to a remaining-percent series.
    /// The optional window bounds the series to the same window as the lead
    /// provider ring. A single observation is retained for truthful empty-state
    /// messaging, but callers should render a trend only when there are at
    /// least two points.
    public static func usageRemaining(
        from analytics: UsageAnalyticsSnapshot,
        window: UsageWindow? = nil
    ) -> [OverviewChartPoint] {
        let lowerBound: Date?
        if let resetAt = window?.resetAt, let durationMinutes = window?.durationMinutes {
            lowerBound = resetAt.addingTimeInterval(-Double(durationMinutes) * 60)
        } else {
            lowerBound = nil
        }
        let upperBound = window?.resetAt

        // Preserve source order while collapsing duplicates so the last
        // source occurrence wins deterministically, then sort for Chart.
        var latestByDate = [Date: UsageActivityPoint]()
        for point in analytics.activity {
            guard lowerBound.map({ point.date >= $0 }) ?? true,
                  upperBound.map({ point.date <= $0 }) ?? true else { continue }
            latestByDate[point.date] = point
        }
        return latestByDate.values
            .sorted { $0.date < $1.date }
            .map { point in
                OverviewChartPoint(
                    date: point.date,
                    value: min(max(1 - point.usedPercent, 0), 1)
                )
            }
    }

    /// Selects the most useful observed Clipper trend deterministically:
    /// views first, then subscribers, then revenue. A metric is eligible only
    /// when at least two dated observations exist, so a single current value
    /// cannot masquerade as a trend.
    public static func preferredClipperTrend(
        from trends: [ClipperTrendPoint]
    ) -> OverviewClipperTrend? {
        for metric in OverviewClipperTrendMetric.allCases {
            var byDate = [Date: Double]()
            // Preserve source order while collapsing duplicates so the last
            // source occurrence wins deterministically, then sort for Chart.
            for trend in trends {
                guard let value = value(for: metric, in: trend.metrics), value.isFinite else {
                    byDate.removeValue(forKey: trend.at)
                    continue
                }
                byDate[trend.at] = value
            }
            let points = byDate.keys.sorted().compactMap { date -> OverviewChartPoint? in
                guard let value = byDate[date] else { return nil }
                return OverviewChartPoint(date: date, value: value)
            }
            guard points.count >= 2 else { continue }
            return OverviewClipperTrend(metric: metric, points: points)
        }
        return nil
    }

    private static func value(for metric: OverviewClipperTrendMetric, in metrics: ClipperMetricSet) -> Double? {
        switch metric {
        case .views:
            guard metrics.views.availability == .observed, let value = metrics.views.value else { return nil }
            return Double(value)
        case .subscribers:
            guard metrics.subscribers.availability == .observed, let value = metrics.subscribers.value else { return nil }
            return Double(value)
        case .revenue:
            guard metrics.revenue.availability == .observed, let value = metrics.revenue.amountCents else { return nil }
            return Double(value)
        }
    }
}

public extension OverviewSnapshot {
    static func production(clipper: ClipperSnapshot, at date: Date = .now) -> OverviewSnapshot {
        let unavailable = OverviewSnapshot.unavailable(at: date)
        let clipperSection = OverviewSection.clipperSummary(from: clipper)
        return OverviewSnapshot(
            sections: unavailable.sections.map { section in
                section.kind == .clipper ? clipperSection : section
            },
            generatedAt: max(date, clipper.generatedAt),
            clipperSnapshot: clipper
        )
    }

    static func unavailable(at date: Date = .now) -> OverviewSnapshot {
        let provenance = Provenance(
            source: "No connected data source",
            observedAt: date,
            quality: .unavailable,
            connector: .unavailable
        )
        return OverviewSnapshot(
            sections: [
                .init(kind: .llm, title: "LLM", metrics: [
                    .init(label: "Codex", value: nil, unit: "% left", icon: .usage),
                    .init(label: "Claude", value: nil, unit: "% left", icon: .usage),
                    .init(label: "GLM", value: nil, unit: "% left", icon: .usage),
                    .init(label: "DeepSeek", value: nil, unit: "% left", icon: .usage),
                    .init(label: "Google AI Studio", value: nil, unit: "% left", icon: .usage),
                    .init(label: "Banked resets", value: nil, icon: .usage)
                ], provenance: provenance),
                .init(kind: .clipper, title: "Clipper", metrics: [
                    .init(label: "Views today", value: nil, icon: .views),
                    .init(label: "Subscribers today", value: nil, icon: .subscribers),
                    .init(label: "Revenue this month", value: nil, icon: .revenue)
                ], provenance: provenance),
                .init(kind: .health, title: "Health", metrics: [
                    .init(label: "Resting heart rate", value: nil, unit: "bpm", icon: .heartRate),
                    .init(label: "Sleep quality", value: nil, unit: "%", icon: .sleep)
                ], provenance: provenance),
                .init(kind: .finance, title: "Finance", metrics: [
                    .init(label: "Savings goal", value: nil, unit: "%", icon: .savings),
                    .init(label: "Monthly budget", value: nil, unit: "% used", icon: .budget)
                ], provenance: provenance)
            ],
            generatedAt: date
        )
    }
}

public extension DemoDataProvider {
    static let overview = OverviewSnapshot(
        sections: [
            .init(kind: .llm, title: "LLM", metrics: [
                .init(label: "Codex", value: "58", unit: "% left", icon: .usage),
                .init(label: "Claude", value: "69", unit: "% left", icon: .usage),
                .init(label: "GLM", value: nil, unit: "% left", icon: .usage),
                .init(label: "DeepSeek", value: nil, unit: "% left", icon: .usage),
                .init(label: "Google AI Studio", value: nil, unit: "% left", icon: .usage),
                .init(label: "Banked resets", value: "1", icon: .usage)
            ], provenance: provenance),
            .init(kind: .clipper, title: "Clipper", metrics: [
                .init(label: "Views today", value: "18.4K", icon: .views),
                .init(label: "Subscribers today", value: "+126", icon: .subscribers),
                .init(label: "Revenue this month", value: "€842", icon: .revenue)
            ], provenance: provenance),
            .init(kind: .health, title: "Health", metrics: [
                .init(label: "Resting heart rate", value: "58", unit: "bpm", icon: .heartRate),
                .init(label: "Sleep quality", value: "86", unit: "%", icon: .sleep),
                .init(label: "Steps", value: "7,420", icon: .health),
                .init(label: "Active energy", value: "420", unit: "kcal", icon: .health)
            ], provenance: provenance),
            .init(kind: .finance, title: "Finance", metrics: [
                .init(label: "Savings goal", value: "25", unit: "%", icon: .savings),
                .init(label: "Monthly budget", value: "45", unit: "% used", icon: .budget)
            ], provenance: provenance)
        ],
        generatedAt: observedAt
    )
}
