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

    public init(kind: OverviewSectionKind, title: String, metrics: [OverviewMetric], provenance: Provenance) {
        self.kind = kind
        self.title = title
        self.metrics = metrics
        self.provenance = provenance
    }
}

public struct OverviewSnapshot: Codable, Equatable, Sendable {
    public let sections: [OverviewSection]
    public let generatedAt: Date

    public init(sections: [OverviewSection], generatedAt: Date) {
        self.sections = sections
        self.generatedAt = generatedAt
    }
}

public extension DemoDataProvider {
    static let overview = OverviewSnapshot(
        sections: [
            .init(kind: .llm, title: "LLM", metrics: [
                .init(label: "Codex", value: "58", unit: "% left", icon: .usage),
                .init(label: "Claude", value: nil, icon: .usage),
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
