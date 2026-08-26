import Foundation
import CoreGraphics

public struct UsageHourWeight: Codable, Equatable, Sendable {
    public let weekday: Int
    public let hour: Int
    public let weight: Double

    public init(weekday: Int, hour: Int, weight: Double) {
        self.weekday = weekday
        self.hour = hour
        self.weight = max(0, weight)
    }
}

public struct UsageActivityProfile: Codable, Equatable, Sendable {
    public let hourlyWeights: [UsageHourWeight]

    public init(hourlyWeights: [UsageHourWeight]) {
        self.hourlyWeights = hourlyWeights
    }

    public func weight(at date: Date, calendar: Calendar = .current) -> Double {
        let weekday = calendar.component(.weekday, from: date)
        let hour = calendar.component(.hour, from: date)
        return hourlyWeights.first { $0.weekday == weekday && $0.hour == hour }?.weight ?? 1
    }
}

public struct UsageProjectionPoint: Identifiable, Codable, Equatable, Sendable {
    public var id: Date { date }
    public let date: Date
    public let usedPercent: Double

    public init(date: Date, usedPercent: Double) {
        self.date = date
        self.usedPercent = min(max(usedPercent, 0), 1)
    }
}

public enum UsageProjectionEngine {
    /// Projects to the natural reset using a learned hour-of-week activity profile.
    /// The baseline is the recent observed hourly increase; profile weights model daily cycles.
    public static func points(
        currentUsedPercent: Double,
        observedAt: Date,
        resetAt: Date,
        baselineHourlyIncrease: Double,
        profile: UsageActivityProfile,
        calendar: Calendar = .current
    ) -> [UsageProjectionPoint] {
        guard resetAt > observedAt, baselineHourlyIncrease >= 0 else { return [] }
        var result = [UsageProjectionPoint(date: observedAt, usedPercent: currentUsedPercent)]
        var cursor = observedAt
        var projected = min(max(currentUsedPercent, 0), 1)

        while cursor < resetAt {
            let hourEnd = calendar.dateInterval(of: .hour, for: cursor)?.end
            let candidate = hourEnd.flatMap { $0 > cursor ? $0 : nil }
                ?? cursor.addingTimeInterval(3_600)
            let next = min(candidate, resetAt)
            let hours = next.timeIntervalSince(cursor) / 3_600
            projected = min(
                1,
                projected + baselineHourlyIncrease * profile.weight(at: cursor, calendar: calendar) * hours
            )
            result.append(UsageProjectionPoint(date: next, usedPercent: projected))
            cursor = next
        }
        return result
    }
}

public struct UsageActivityPoint: Identifiable, Codable, Equatable, Sendable {
    public var id: Date { date }
    public let date: Date
    public let tokens: Int
    public let usedPercent: Double

    public init(date: Date, tokens: Int, usedPercent: Double) {
        self.date = date
        self.tokens = max(0, tokens)
        self.usedPercent = min(max(usedPercent, 0), 1)
    }
}

public struct UsageModelBreakdown: Identifiable, Codable, Equatable, Sendable {
    public var id: String { model }
    public let model: String
    public let inputTokens: Int
    public let outputTokens: Int
    public let reasoningTokens: Int
    public let toolTokens: Int
    public let imageTokens: Int

    public init(model: String, inputTokens: Int, outputTokens: Int, reasoningTokens: Int,
                toolTokens: Int, imageTokens: Int) {
        self.model = model
        self.inputTokens = max(0, inputTokens)
        self.outputTokens = max(0, outputTokens)
        self.reasoningTokens = max(0, reasoningTokens)
        self.toolTokens = max(0, toolTokens)
        self.imageTokens = max(0, imageTokens)
    }

    public var totalTokens: Int {
        inputTokens + outputTokens + reasoningTokens + toolTokens + imageTokens
    }

    public var categories: [(label: String, value: Int)] {
        [("Input", inputTokens), ("Output", outputTokens), ("Reasoning", reasoningTokens),
         ("Tools", toolTokens), ("Images", imageTokens)]
    }
}

public struct UsageHeatmapCell: Identifiable, Codable, Equatable, Sendable {
    public var id: String { "\(weekday)-\(hour)" }
    public let weekday: Int
    public let hour: Int
    public let intensity: Double

    public init(weekday: Int, hour: Int, intensity: Double) {
        self.weekday = weekday
        self.hour = hour
        self.intensity = min(max(intensity, 0), 1)
    }
}

public struct UsageHeatmapGridItem: Identifiable, Equatable, Sendable {
    public enum Kind: Equatable, Sendable {
        case corner
        case hourHeader(Int)
        case dayHeader(Int)
        case cell(UsageHeatmapCell)
    }

    public let id: String
    public let kind: Kind

    public init(id: String, kind: Kind) {
        self.id = id
        self.kind = kind
    }
}

public enum UsageHeatmapGrid {
    public static let displayedHours = stride(from: 0, to: 24, by: 3).map { $0 }

    public static func items(cells: [UsageHeatmapCell]) -> [UsageHeatmapGridItem] {
        var items = [UsageHeatmapGridItem(id: "corner", kind: .corner)]
        items += displayedHours.map {
            UsageHeatmapGridItem(id: "hour-header-\($0)", kind: .hourHeader($0))
        }

        for weekday in 1...7 {
            items.append(UsageHeatmapGridItem(id: "day-header-\(weekday)", kind: .dayHeader(weekday)))
            for hour in displayedHours {
                let cell = cells.first { $0.weekday == weekday && $0.hour == hour }
                    ?? UsageHeatmapCell(weekday: weekday, hour: hour, intensity: 0)
                items.append(UsageHeatmapGridItem(id: "cell-\(weekday)-\(hour)", kind: .cell(cell)))
            }
        }
        return items
    }
}

public struct UsageAnalyticsSnapshot: Codable, Equatable, Sendable {
    public let provider: Provider
    /// Analytics are scoped to one provider window. Keeping that scope explicit prevents a
    /// 5-hour estimate from being shown after the user switches the detail surface to 7 days.
    public let windowID: String?
    public let activity: [UsageActivityPoint]
    public let projection: [UsageProjectionPoint]
    public let modelBreakdowns: [UsageModelBreakdown]
    public let heatmap: [UsageHeatmapCell]
    public let provenance: Provenance

    public init(provider: Provider, windowID: String? = nil, activity: [UsageActivityPoint], projection: [UsageProjectionPoint],
                modelBreakdowns: [UsageModelBreakdown], heatmap: [UsageHeatmapCell], provenance: Provenance) {
        self.provider = provider
        self.windowID = windowID
        self.activity = activity
        self.projection = projection
        self.modelBreakdowns = modelBreakdowns
        self.heatmap = heatmap
        self.provenance = provenance
    }
}

public struct UsageSelectionPoint: Equatable, Sendable {
    public let date: Date
    public let usedPercent: Double
    public let isProjected: Bool

    /// Stable selection identity. Selection must survive a source reorder or refresh;
    /// array offsets are presentation details and are not valid IDs.
    public var id: String {
        "\(isProjected ? "projected" : "observed")|\(date.timeIntervalSinceReferenceDate)"
    }
}

public enum UsageSelection {
    public static func closestPoint(
        to date: Date,
        observed: [UsageProjectionPoint],
        projected: [UsageProjectionPoint]
    ) -> UsageSelectionPoint? {
        let candidates = observed.map {
            UsageSelectionPoint(date: $0.date, usedPercent: $0.usedPercent, isProjected: false)
        } + projected.map {
            UsageSelectionPoint(date: $0.date, usedPercent: $0.usedPercent, isProjected: true)
        }
        return candidates.min {
            let leftDistance = abs($0.date.timeIntervalSince(date))
            let rightDistance = abs($1.date.timeIntervalSince(date))
            guard leftDistance == rightDistance else { return leftDistance < rightDistance }
            if $0.isProjected != $1.isProjected {
                return !$0.isProjected
            }
            return $0.date < $1.date
        }
    }

    public static func radarCategoryIndex(at location: CGPoint, center: CGPoint, count: Int) -> Int? {
        guard count > 0 else { return nil }
        let dx = location.x - center.x
        let dy = location.y - center.y
        guard hypot(dx, dy) > 4 else { return nil }
        let normalized = (atan2(dy, dx) + .pi / 2 + 2 * .pi).truncatingRemainder(dividingBy: 2 * .pi)
        let sector = 2 * .pi / Double(count)
        return min(Int(floor(normalized / sector)), count - 1)
    }
}

public enum UsageAnalyticsResolver {
    public static func matching(
        snapshot: ProviderSnapshot,
        candidates: [UsageAnalyticsSnapshot],
        windowID: String? = nil
    ) -> UsageAnalyticsSnapshot? {
        let qualityMatches = candidates.filter { candidate in
            guard candidate.provider == snapshot.provider else { return false }
            if snapshot.provenance.quality == .demo {
                return candidate.provenance.quality == .demo
            }
            return candidate.provenance.quality != .demo
        }

        guard let windowID else { return qualityMatches.first }

        // A scoped analytics record must never be reused for another range. An unscoped
        // record remains a valid provider-level fallback, but it cannot contribute a forward
        // estimate because `UsageProjectionChart` requires an explicit matching window ID.
        if let exact = qualityMatches.first(where: { $0.windowID == windowID }) {
            return exact
        }
        return qualityMatches.first(where: { $0.windowID == nil })
    }
}

public struct UsageWidgetSummary: Equatable, Sendable {
    public let provider: Provider
    public let windowIndicator: String
    public let remainingPercent: Double
    public let observedUsedPercent: Double
    public let projectedUsedPercent: Double?

    public init?(snapshot: ProviderSnapshot) {
        guard let window = snapshot.smallestObservedWindow, let used = window.usedPercent else { return nil }
        provider = snapshot.provider
        remainingPercent = 1 - used
        observedUsedPercent = used
        projectedUsedPercent = window.projection?.percentAtReset
        if let duration = window.durationMinutes {
            windowIndicator = Self.indicator(forMinutes: duration)
        } else {
            windowIndicator = window.id.localizedCaseInsensitiveContains("5") ? "5hr" : "w"
        }
    }

    private static func indicator(forMinutes minutes: Int) -> String {
        if minutes < 60 { return "\(minutes)m" }
        if minutes % 10_080 == 0 { return minutes == 10_080 ? "w" : "\(minutes / 10_080)w" }
        if minutes % 1_440 == 0 { return "\(minutes / 1_440)d" }
        if minutes % 60 == 0 { return "\(minutes / 60)hr" }
        return "\(minutes)m"
    }
}

public enum DemoUsageAnalytics {
    public static let snapshots: [UsageAnalyticsSnapshot] = [
        make(provider: .codex, scale: 1, models: [
            UsageModelBreakdown(model: "gpt-5.6-sol", inputTokens: 186_000, outputTokens: 54_000, reasoningTokens: 92_000, toolTokens: 31_000, imageTokens: 8_000),
            UsageModelBreakdown(model: "gpt-5.6-luna", inputTokens: 74_000, outputTokens: 29_000, reasoningTokens: 41_000, toolTokens: 12_000, imageTokens: 3_000)
        ]),
        make(provider: .claude, scale: 0.72, models: [
            UsageModelBreakdown(model: "Claude", inputTokens: 121_000, outputTokens: 47_000, reasoningTokens: 58_000, toolTokens: 18_000, imageTokens: 2_000)
        ])
    ]

    private static func make(provider: Provider, scale: Double, models: [UsageModelBreakdown]) -> UsageAnalyticsSnapshot {
        let start = DemoDataProvider.observedAt.addingTimeInterval(-11 * 3_600)
        let activity = (0..<12).map { index in
            let cycle = [0.18, 0.12, 0.08, 0.06, 0.10, 0.28, 0.62, 0.86, 0.74, 0.93, 0.56, 0.42][index]
            return UsageActivityPoint(
                date: start.addingTimeInterval(Double(index) * 3_600),
                tokens: Int(Double(42_000) * cycle * scale),
                usedPercent: min(0.08 + Double(index) * 0.026 * scale, 0.72)
            )
        }
        let profile = UsageActivityProfile(hourlyWeights: (0..<24).map {
            UsageHourWeight(weekday: Calendar.current.component(.weekday, from: DemoDataProvider.observedAt),
                            hour: $0, weight: $0 >= 8 && $0 <= 22 ? 1.35 : 0.28)
        })
        let projection = UsageProjectionEngine.points(
            currentUsedPercent: activity.last?.usedPercent ?? 0,
            observedAt: DemoDataProvider.observedAt,
            resetAt: DemoDataProvider.observedAt.addingTimeInterval(3_600),
            baselineHourlyIncrease: 0.018 * scale,
            profile: profile
        )
        let heatmap = (1...7).flatMap { weekday in
            stride(from: 0, to: 24, by: 3).map { hour in
                let active = hour >= 9 && hour <= 21
                let variation = Double((weekday * 7 + hour) % 5) / 10
                return UsageHeatmapCell(weekday: weekday, hour: hour,
                                        intensity: min((active ? 0.45 : 0.08) + variation * scale, 1))
            }
        }
        return UsageAnalyticsSnapshot(provider: provider, windowID: "5h", activity: activity, projection: projection,
                                      modelBreakdowns: models, heatmap: heatmap,
                                      provenance: DemoDataProvider.provenance)
    }
}
