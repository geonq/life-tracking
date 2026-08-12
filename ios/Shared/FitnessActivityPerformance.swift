import Foundation

/// A source-aware value used by the Fitness activity/performance surface.
///
/// The view never computes a Bevel score. An importer must provide an observed
/// value and its window/provenance, or the UI stays unavailable/calibrating.
public struct FitnessActivityMetric: Identifiable {
    public enum State: Equatable, Sendable {
        case unavailable(reason: String)
        case calibrating(reason: String)
        case observed(value: Double, unit: Unit, window: String, provenance: String)
        case demo(value: Double, unit: Unit, window: String, provenance: String)
    }

    public enum Unit: String, Equatable, Sendable {
        case minutes
        case percent
        /// A provider-defined value with no universal denominator. The UI must
        /// never present this as a fabricated `/100` score.
        case sourceDefined
        case bpm
        case kilograms
        case count

        public var suffix: String {
            switch self {
            case .minutes: "min"
            case .percent: "%"
            case .sourceDefined: "source-defined"
            case .bpm: "bpm"
            case .kilograms: "kg"
            case .count: ""
            }
        }
    }

    public let id: String
    public let title: String
    public let state: State
    public let hue: LifeOSTokens.Hue

    public init(id: String, title: String, state: State, hue: LifeOSTokens.Hue = .blue) {
        self.id = id
        self.title = title
        self.state = Self.validated(state)
        self.hue = hue
    }

    private static func validated(_ state: State) -> State {
        switch state {
        case .unavailable(let reason):
            return .unavailable(reason: reason.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "No source observation is available." : reason)
        case .calibrating(let reason):
            return .calibrating(reason: reason.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "Source calibration is incomplete." : reason)
        case .observed(let value, let unit, let window, let provenance):
            guard value.isFinite, value >= 0,
                  !window.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  !provenance.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                return .unavailable(reason: "Source observation is invalid or missing its provenance.")
            }
            return .observed(value: value, unit: unit, window: window, provenance: provenance)
        case .demo(let value, let unit, let window, let provenance):
            guard value.isFinite, value >= 0,
                  !window.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  !provenance.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                return .unavailable(reason: "Fixture value is invalid or missing its provenance.")
            }
            return .demo(value: value, unit: unit, window: window, provenance: provenance)
        }
    }

    public static func unavailable(
        id: String,
        title: String,
        reason: String,
        hue: LifeOSTokens.Hue = .blue
    ) -> FitnessActivityMetric {
        FitnessActivityMetric(id: id, title: title, state: .unavailable(reason: reason), hue: hue)
    }
}

public struct FitnessActivityDay: Identifiable, Equatable, Sendable {
    public enum State: Equatable, Sendable {
        case unavailable(reason: String, window: String, provenance: String)
        case observed(count: Int, window: String, provenance: String)
        case demo(count: Int, window: String, provenance: String)
    }

    public let date: Date
    public let state: State

    public var id: Date { date }
    public var activityCount: Int? {
        switch state {
        case .unavailable: nil
        case .observed(let count, _, _), .demo(let count, _, _): count
        }
    }
    public var legendBucket: Int? {
        activityCount.map { min(max($0, 0), 3) }
    }

    public init(date: Date, state: State) {
        self.date = date
        self.state = Self.validated(state)
    }

    private static func validated(_ state: State) -> State {
        func text(_ value: String) -> String {
            value.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        switch state {
        case .unavailable(let reason, let window, let provenance):
            return .unavailable(
                reason: text(reason).isEmpty ? "No source observation is available for this day." : text(reason),
                window: text(window).isEmpty ? "Named activity window unavailable" : text(window),
                provenance: text(provenance).isEmpty ? "Source provenance unavailable" : text(provenance)
            )
        case .observed(let count, let window, let provenance):
            guard count >= 0, !text(window).isEmpty, !text(provenance).isEmpty else {
                return .unavailable(
                    reason: "Source observation is invalid or missing its provenance.",
                    window: text(window).isEmpty ? "Named activity window unavailable" : text(window),
                    provenance: text(provenance).isEmpty ? "Source provenance unavailable" : text(provenance)
                )
            }
            return .observed(count: count, window: text(window), provenance: text(provenance))
        case .demo(let count, let window, let provenance):
            guard count >= 0, !text(window).isEmpty, !text(provenance).isEmpty else {
                return .unavailable(
                    reason: "Fixture value is invalid or missing its provenance.",
                    window: text(window).isEmpty ? "Named activity window unavailable" : text(window),
                    provenance: text(provenance).isEmpty ? "Fixture provenance unavailable" : text(provenance)
                )
            }
            return .demo(count: count, window: text(window), provenance: text(provenance))
        }
    }
}

public struct FitnessActivitySeriesPoint: Identifiable, Equatable, Sendable {
    public let date: Date
    public let value: Double?

    public var id: Date { date }

    public init(date: Date, value: Double?) {
        self.date = date
        guard let value, value.isFinite, value >= 0 else {
            self.value = nil
            return
        }
        self.value = value
    }
}

public struct FitnessPerformanceTarget: Equatable, Sendable {
    public enum State: Equatable, Sendable {
        case unavailable(reason: String)
        case calibrating(reason: String)
        case observed(
            current: Double,
            deviationPercent: Double,
            lowerBound: Double,
            upperBound: Double,
            window: String,
            provenance: String
        )
        case demo(
            current: Double,
            deviationPercent: Double,
            lowerBound: Double,
            upperBound: Double,
            window: String,
            provenance: String
        )
    }

    public let state: State
    public let series: [FitnessActivitySeriesPoint]

    public init(state: State, series: [FitnessActivitySeriesPoint] = []) {
        self.state = Self.validated(state)
        self.series = series
    }

    private static func validated(_ state: State) -> State {
        switch state {
        case .unavailable(let reason):
            return .unavailable(reason: reason.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "No target observation is available." : reason)
        case .calibrating(let reason):
            return .calibrating(reason: reason.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "Target calibration is incomplete." : reason)
        case .observed(let current, let deviation, let lower, let upper, let window, let provenance):
            guard current.isFinite, current >= 0, deviation.isFinite,
                  lower.isFinite, upper.isFinite, lower >= 0, upper >= lower,
                  !window.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  !provenance.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                return .unavailable(reason: "Target observation is invalid or missing its provenance.")
            }
            return .observed(current: current, deviationPercent: deviation, lowerBound: lower, upperBound: upper, window: window, provenance: provenance)
        case .demo(let current, let deviation, let lower, let upper, let window, let provenance):
            guard current.isFinite, current >= 0, deviation.isFinite,
                  lower.isFinite, upper.isFinite, lower >= 0, upper >= lower,
                  !window.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  !provenance.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                return .unavailable(reason: "Fixture target is invalid or missing its provenance.")
            }
            return .demo(current: current, deviationPercent: deviation, lowerBound: lower, upperBound: upper, window: window, provenance: provenance)
        }
    }

    public static let unavailable = FitnessPerformanceTarget(
        state: .unavailable(reason: "A reviewed source must provide a target window and observed load.")
    )
}

/// The exact data boundary for Bevel IMG_0391–0392's activity/performance
/// continuation. It is intentionally independent from HealthKit so that an
/// adapter can preserve source truth and the UI can render honest empty states.
public struct FitnessActivitySnapshot {
    public let activityCalendarDays: [FitnessActivityDay]
    public let activitySeries: [FitnessActivitySeriesPoint]
    public let activityTotal: FitnessActivityMetric
    public let performanceTarget: FitnessPerformanceTarget
    public let cardioLoad: FitnessActivityMetric
    public let cardioFocus: FitnessActivityMetric
    public let heartRateRecovery: FitnessActivityMetric
    public let strengthVolume: FitnessActivityMetric

    public init(
        activityCalendarDays: [FitnessActivityDay] = [],
        activitySeries: [FitnessActivitySeriesPoint] = [],
        activityTotal: FitnessActivityMetric = .unavailable(
            id: "activity-total",
            title: "Activity summary",
            reason: "No source workout history is available.",
            hue: .orange
        ),
        performanceTarget: FitnessPerformanceTarget = .unavailable,
        cardioLoad: FitnessActivityMetric = .unavailable(
            id: "cardio-load",
            title: "Cardio load",
            reason: "Requires source workout samples and a named window.",
            hue: .blue
        ),
        cardioFocus: FitnessActivityMetric = .unavailable(
            id: "cardio-focus",
            title: "Cardio focus",
            reason: "Requires source cardio sessions with intensity classification.",
            hue: .teal
        ),
        heartRateRecovery: FitnessActivityMetric = .unavailable(
            id: "heart-rate-recovery",
            title: "Heart-rate recovery",
            reason: "Requires a source workout with recovery heart-rate samples.",
            hue: .pink
        ),
        strengthVolume: FitnessActivityMetric = .unavailable(
            id: "strength-volume",
            title: "Strength volume",
            reason: "Requires logged sets, load, and a named source window.",
            hue: .violet
        )
    ) {
        self.activityCalendarDays = activityCalendarDays
        self.activitySeries = activitySeries
        self.activityTotal = activityTotal
        self.performanceTarget = performanceTarget
        self.cardioLoad = cardioLoad
        self.cardioFocus = cardioFocus
        self.heartRateRecovery = heartRateRecovery
        self.strengthVolume = strengthVolume
    }

    public static let unavailable = FitnessActivitySnapshot()

    /// Explicitly opt-in visual fixture for the reference screenshots. The
    /// numbers are fixture values only and are labelled in the rendered UI.
    public static func demo(anchor: Date) -> FitnessActivitySnapshot {
        let calendar = Calendar(identifier: .gregorian)
        let start = calendar.startOfDay(for: anchor)
        let dayCounts = [0, 1, 0, 2, 1, 0, 3, 0, 1, 0, 2, 1, 0, 0, 1, 0, 2, 0, 1, 3, 0, 0, 2, 1, 0, 1, 0, 2, 0, 1]
        let window = "Last 30 days · demo fixture"
        let provenance = "DEMO · NOT LIVE · explicit fixture field"
        let calendarDays = (-29...0).compactMap { offset -> FitnessActivityDay? in
            guard let date = calendar.date(byAdding: .day, value: offset, to: start) else { return nil }
            return FitnessActivityDay(
                date: date,
                state: .demo(count: dayCounts[offset + 29], window: window, provenance: provenance)
            )
        }
        let activityValues = [0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 21, 63]
        let performanceValues = [24, 31, 28, 34, 27, 30, 26, 32, 29, 35, 31, 33, 28, 26, 30, 34, 29, 32, 27, 31, 35, 29, 33, 30, 28, 34, 31, 29, 82, 24]
        let series = (0..<30).compactMap { index -> FitnessActivitySeriesPoint? in
            guard let date = calendar.date(byAdding: .day, value: index - 29, to: start) else { return nil }
            return FitnessActivitySeriesPoint(date: date, value: Double(activityValues[index]))
        }
        let targetSeries = (0..<30).compactMap { index -> FitnessActivitySeriesPoint? in
            guard let date = calendar.date(byAdding: .day, value: index - 29, to: start) else { return nil }
            return FitnessActivitySeriesPoint(date: date, value: Double(performanceValues[index]))
        }
        return FitnessActivitySnapshot(
            activityCalendarDays: calendarDays,
            activitySeries: series,
            activityTotal: FitnessActivityMetric(
                id: "activity-total",
                title: "Activity summary",
                state: .demo(value: 63, unit: .minutes, window: window, provenance: provenance),
                hue: .orange
            ),
            performanceTarget: FitnessPerformanceTarget(
                state: .demo(current: 24, deviationPercent: -28, lowerBound: 20, upperBound: 40, window: window, provenance: provenance),
                series: targetSeries
            ),
            cardioLoad: FitnessActivityMetric(id: "cardio-load", title: "Cardio load", state: .calibrating(reason: "Needs a validated cardio history window."), hue: .blue),
            cardioFocus: FitnessActivityMetric(id: "cardio-focus", title: "Cardio focus", state: .unavailable(reason: "No source intensity classification is connected."), hue: .teal),
            heartRateRecovery: FitnessActivityMetric(id: "heart-rate-recovery", title: "Heart-rate recovery", state: .unavailable(reason: "No recovery heart-rate sample is connected."), hue: .pink),
            strengthVolume: FitnessActivityMetric(id: "strength-volume", title: "Strength volume", state: .demo(value: 0, unit: .kilograms, window: window, provenance: provenance), hue: .violet)
        )
    }
}
