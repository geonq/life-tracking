import Foundation

/// The independently sourced body metrics shown by the Biology surface.
///
/// These are deliberately not folded into `FitnessMetric`: biology needs to
/// retain the source device, sample count, freshness, and trend window for
/// every metric. An absent HealthKit/Helio observation remains absent; the
/// domain never turns it into zero or a guessed value.
public enum FitnessBiologyMetricID: String, CaseIterable, Identifiable, Sendable {
    case weight
    case hrvBaseline
    case rhrBaseline
    case bodyFat
    case fatFreeMass
    case vo2Max

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .weight: "Weight"
        case .hrvBaseline: "HRV baseline"
        case .rhrBaseline: "RHR baseline"
        case .bodyFat: "Body fat"
        case .fatFreeMass: "Fat-free mass"
        case .vo2Max: "VO₂ max"
        }
    }

    public var unit: FitnessBiologyUnit {
        switch self {
        case .weight, .fatFreeMass: .kilograms
        case .hrvBaseline: .milliseconds
        case .rhrBaseline: .beatsPerMinute
        case .bodyFat: .percent
        case .vo2Max: .millilitersPerKilogramMinute
        }
    }

    public var hue: LifeOSTokens.Hue {
        switch self {
        case .weight: .blue
        case .hrvBaseline: .teal
        case .rhrBaseline: .pink
        case .bodyFat: .orange
        case .fatFreeMass: .violet
        case .vo2Max: .green
        }
    }

    /// Plausibility boundaries are display/import safeguards, not medical
    /// reference ranges. Values outside them are unavailable for review.
    var plausibleRange: ClosedRange<Double> {
        switch self {
        case .weight: 20...500
        case .hrvBaseline: 1...1_000
        case .rhrBaseline: 20...240
        case .bodyFat: 0...100
        case .fatFreeMass: 10...500
        case .vo2Max: 1...150
        }
    }
}

public enum FitnessBiologyUnit: String, Equatable, Sendable {
    case kilograms
    case milliseconds
    case beatsPerMinute
    case percent
    case millilitersPerKilogramMinute

    public var label: String {
        switch self {
        case .kilograms: "kg"
        case .milliseconds: "ms"
        case .beatsPerMinute: "bpm"
        case .percent: "%"
        case .millilitersPerKilogramMinute: "ml/kg/min"
        }
    }
}

public struct FitnessBiologySample: Identifiable, Equatable, Sendable {
    public let date: Date
    public let value: Double

    public var id: Date { date }

    /// A sample must have a finite timestamp and finite, non-negative value.
    /// Metric-specific plausibility is checked by `FitnessBiologyMetric`.
    public init?(date: Date, value: Double) {
        guard FitnessBiologyValidation.isValidTimestamp(date), value.isFinite, value >= 0 else {
            return nil
        }
        self.date = date
        self.value = value
    }
}

public struct FitnessBiologyMetric: Identifiable, Equatable, Sendable {
    public enum State: Equatable, Sendable {
        case unavailable(reason: String)
        case calibrating(reason: String)
        case observed(
            value: Double,
            unit: FitnessBiologyUnit,
            sourceDevice: String,
            sampleCount: Int,
            freshness: String,
            window: String,
            provenance: String,
            samples: [FitnessBiologySample]
        )
        case demo(
            value: Double,
            unit: FitnessBiologyUnit,
            sourceDevice: String,
            sampleCount: Int,
            freshness: String,
            window: String,
            provenance: String,
            samples: [FitnessBiologySample]
        )
    }

    public let id: FitnessBiologyMetricID
    public let state: State
    /// The source state is independent from the value state. A partial, stale,
    /// conflicted, or permission-blocked source must remain explicit even
    /// though `currentValue` is intentionally withheld for some of those
    /// conditions.
    public let sourceState: FitnessMetric.SourceState

    public init(
        id: FitnessBiologyMetricID,
        state: State,
        sourceState: FitnessMetric.SourceState? = nil
    ) {
        self.id = id
        let validatedState = Self.validated(id: id, state: state)
        self.state = validatedState
        self.sourceState = Self.resolvedSourceState(sourceState, for: validatedState)
    }

    public var title: String { id.title }
    public var unit: FitnessBiologyUnit { id.unit }

    public var samples: [FitnessBiologySample] {
        guard sourceState.canDisplayValue else { return [] }
        switch state {
        case .observed(_, _, _, _, _, _, _, let samples), .demo(_, _, _, _, _, _, _, let samples):
            return samples.sorted { $0.date < $1.date }
        case .unavailable, .calibrating:
            return []
        }
    }

    public var currentValue: Double? {
        guard sourceState.canDisplayValue else { return nil }
        switch state {
        case .observed(let value, _, _, _, _, _, _, _), .demo(let value, _, _, _, _, _, _, _):
            return value
        case .unavailable, .calibrating:
            return nil
        }
    }

    public var isDemo: Bool {
        if case .demo = state { return true }
        return false
    }

    public var sourceDevice: String? {
        switch state {
        case .observed(_, _, let device, _, _, _, _, _), .demo(_, _, let device, _, _, _, _, _): device
        case .unavailable, .calibrating: nil
        }
    }

    public var sampleCount: Int? {
        switch state {
        case .observed(_, _, _, let count, _, _, _, _), .demo(_, _, _, let count, _, _, _, _): count
        case .unavailable, .calibrating: nil
        }
    }

    public var freshness: String? {
        switch state {
        case .observed(_, _, _, _, let freshness, _, _, _), .demo(_, _, _, _, let freshness, _, _, _): freshness
        case .unavailable, .calibrating: nil
        }
    }

    public var window: String? {
        switch state {
        case .observed(_, _, _, _, _, let window, _, _), .demo(_, _, _, _, _, let window, _, _): window
        case .unavailable, .calibrating: nil
        }
    }

    public var provenance: String? {
        switch state {
        case .observed(_, _, _, _, _, _, let provenance, _), .demo(_, _, _, _, _, _, let provenance, _): provenance
        case .unavailable, .calibrating: nil
        }
    }

    public var stateDetail: String {
        switch state {
        case .unavailable(let reason), .calibrating(let reason):
            sourceState == .unavailable || sourceState == .calibrating
                ? reason
                : "\(sourceState.label) · \(reason)"
        case .observed:
            sourceState == .observed ? "Observed source value" : "\(sourceState.label) · source value"
        case .demo: "DEMO · NOT LIVE"
        }
    }

    /// Filters by half-open local calendar days. Using calendar arithmetic
    /// keeps the range correct across daylight-saving transitions instead of
    /// assuming every local day has exactly 86,400 seconds.
    public func samples(
        for range: FitnessBiologyRange,
        endingAt date: Date,
        calendar: Calendar = .current
    ) -> [FitnessBiologySample] {
        guard date.timeIntervalSinceReferenceDate.isFinite else { return [] }
        let endDay = calendar.startOfDay(for: date)
        guard let start = calendar.date(byAdding: .day, value: -(range.days - 1), to: endDay),
              let end = calendar.date(byAdding: .day, value: 1, to: endDay) else {
            return []
        }
        return samples.filter { $0.date >= start && $0.date < end }
    }

    public static func unavailable(
        _ id: FitnessBiologyMetricID,
        reason: String? = nil,
        sourceState: FitnessMetric.SourceState? = nil
    ) -> FitnessBiologyMetric {
        FitnessBiologyMetric(
            id: id,
            state: .unavailable(reason: FitnessBiologyValidation.reason(reason, fallback: "No source observation is available.")),
            sourceState: sourceState
        )
    }

    public static func calibrating(
        _ id: FitnessBiologyMetricID,
        reason: String? = nil,
        sourceState: FitnessMetric.SourceState? = nil
    ) -> FitnessBiologyMetric {
        FitnessBiologyMetric(
            id: id,
            state: .calibrating(reason: FitnessBiologyValidation.reason(reason, fallback: "Source calibration is incomplete.")),
            sourceState: sourceState
        )
    }

    private static func validated(id: FitnessBiologyMetricID, state: State) -> State {
        switch state {
        case .unavailable(let reason):
            return .unavailable(reason: FitnessBiologyValidation.reason(reason, fallback: "No source observation is available."))
        case .calibrating(let reason):
            return .calibrating(reason: FitnessBiologyValidation.reason(reason, fallback: "Source calibration is incomplete."))
        case .observed(let value, let unit, let device, let count, let freshness, let window, let provenance, let samples):
            guard isValid(id: id, value: value, unit: unit, sourceDevice: device, sampleCount: count, freshness: freshness, window: window, provenance: provenance, samples: samples) else {
                return .unavailable(reason: "Source observation is invalid or missing its provenance.")
            }
            return .observed(value: value, unit: unit, sourceDevice: device.trimmed, sampleCount: count, freshness: freshness.trimmed, window: window.trimmed, provenance: provenance.trimmed, samples: samples)
        case .demo(let value, let unit, let device, let count, let freshness, let window, let provenance, let samples):
            guard isValid(id: id, value: value, unit: unit, sourceDevice: device, sampleCount: count, freshness: freshness, window: window, provenance: provenance, samples: samples), provenance.localizedCaseInsensitiveContains("demo") else {
                return .unavailable(reason: "Fixture value is invalid or missing its provenance.")
            }
            return .demo(value: value, unit: unit, sourceDevice: device.trimmed, sampleCount: count, freshness: freshness.trimmed, window: window.trimmed, provenance: provenance.trimmed, samples: samples)
        }
    }

    private static func isValid(id: FitnessBiologyMetricID, value: Double, unit: FitnessBiologyUnit, sourceDevice: String, sampleCount: Int, freshness: String, window: String, provenance: String, samples: [FitnessBiologySample]) -> Bool {
        value.isFinite && id.plausibleRange.contains(value) && unit == id.unit && sampleCount > 0 && sampleCount >= samples.count && !sourceDevice.isBlank && !freshness.isBlank && !window.isBlank && !provenance.isBlank && samples.allSatisfy { $0.value.isFinite && id.plausibleRange.contains($0.value) }
    }

    private static func resolvedSourceState(_ requested: FitnessMetric.SourceState?, for state: State) -> FitnessMetric.SourceState {
        let fallback: FitnessMetric.SourceState
        switch state {
        case .unavailable: fallback = .unavailable
        case .calibrating: fallback = .calibrating
        case .observed: fallback = .observed
        case .demo: fallback = .demo
        }

        guard let requested else { return fallback }
        switch state {
        case .demo:
            return .demo
        case .observed:
            switch requested {
            case .observed, .partial, .stale, .conflict:
                return requested
            default:
                return .observed
            }
        case .calibrating, .unavailable:
            switch requested {
            case .permissionRequired, .deviceUnavailable, .readIndeterminate,
                 .partial, .stale, .conflict, .error:
                return requested
            default:
                return fallback
            }
        }
    }
}

public enum FitnessBiologyRange: String, CaseIterable, Identifiable, Sendable {
    case threeDays = "3D"
    case sevenDays = "7D"
    case fourteenDays = "14D"
    case thirtyDays = "30D"
    case ninetyDays = "90D"

    public var id: String { rawValue }
    public var days: Int {
        switch self {
        case .threeDays: 3
        case .sevenDays: 7
        case .fourteenDays: 14
        case .thirtyDays: 30
        case .ninetyDays: 90
        }
    }
}

/// Biological age is not a score that can be approximated from the metrics
/// above. It can only render after a reviewed model, review timestamp, named
/// source window, and provenance are all explicit. There is no paywall or
/// proprietary Bevel formula in this contract.
public struct FitnessBiologicalAge: Equatable, Sendable {
    public enum State: Equatable, Sendable {
        case unavailable(reason: String)
        case calibrating(reason: String)
        case gated(reason: String)
        case observed(value: Double, userAge: Int, reviewedModel: String, reviewedAt: Date, window: String, provenance: String)
    }

    public let state: State

    public init(state: State) {
        self.state = Self.validated(state)
    }

    public static let unavailable = FitnessBiologicalAge(state: .gated(reason: "Experimental biological age requires a reviewed model and source history."))

    public var displayValue: Double? {
        if case .observed(let value, _, _, _, _, _) = state { return value }
        return nil
    }

    public var isReviewedAndDisplayable: Bool {
        if case .observed = state { return true }
        return false
    }

    private static func validated(_ state: State) -> State {
        switch state {
        case .unavailable(let reason):
            return .unavailable(reason: FitnessBiologyValidation.reason(reason, fallback: "Biological age is unavailable."))
        case .calibrating(let reason):
            return .calibrating(reason: FitnessBiologyValidation.reason(reason, fallback: "Biological age is still calibrating."))
        case .gated(let reason):
            return .gated(reason: FitnessBiologyValidation.reason(reason, fallback: "Experimental biological age is not enabled."))
        case .observed(let value, let userAge, let reviewedModel, let reviewedAt, let window, let provenance):
            guard value.isFinite, (18...120).contains(userAge), (18...150).contains(value), FitnessBiologyValidation.isValidTimestamp(reviewedAt), !reviewedModel.isBlank, !window.isBlank, !provenance.isBlank else {
                return .gated(reason: "Experimental biological age needs a reviewed model, adult profile, and complete source metadata.")
            }
            return .observed(value: value, userAge: userAge, reviewedModel: reviewedModel.trimmed, reviewedAt: reviewedAt, window: window.trimmed, provenance: provenance.trimmed)
        }
    }
}

public struct FitnessBiologySnapshot: Equatable, Sendable {
    public let biologicalAge: FitnessBiologicalAge
    public let metrics: [FitnessBiologyMetric]

    public init(biologicalAge: FitnessBiologicalAge = .unavailable, metrics: [FitnessBiologyMetric] = FitnessBiologyMetric.defaultMetrics) {
        self.biologicalAge = biologicalAge
        // Prefer the last value for a duplicate identifier instead of
        // crashing while assembling an adapter payload. The public snapshot
        // still exposes exactly one independently validated metric per ID.
        let byID = metrics.reduce(into: [FitnessBiologyMetricID: FitnessBiologyMetric]()) { result, metric in
            result[metric.id] = metric
        }
        self.metrics = FitnessBiologyMetricID.allCases.map { byID[$0] ?? .unavailable($0) }
    }

    public static let unavailable = FitnessBiologySnapshot()

    /// Explicit visual fixture for screenshot review. It contains no
    /// biological-age number and remains visibly labelled as demo data.
    public static func demo(anchor: Date) -> FitnessBiologySnapshot {
        let calendar = Calendar(identifier: .gregorian)
        let values: [FitnessBiologyMetricID: [Double]] = [
            .weight: [78.1, 78.0, 77.8, 77.9, 77.7, 77.6, 77.5],
            .hrvBaseline: [48, 51, 49, 53, 52, 54, 52],
            .rhrBaseline: [56, 55, 55, 54, 55, 53, 54],
            .bodyFat: [18.2, 18.0, 18.1, 17.9, 17.8, 17.9, 17.7],
            .fatFreeMass: [63.8, 64.0, 63.9, 64.1, 64.2, 64.0, 64.3],
            .vo2Max: [44.1, 44.3, 44.0, 44.5, 44.7, 44.6, 44.9]
        ]
        let metrics = FitnessBiologyMetricID.allCases.map { id in
            let samples = values[id, default: []].enumerated().compactMap { index, value in
                FitnessBiologySample(date: calendar.date(byAdding: .day, value: index - 6, to: anchor) ?? anchor, value: value)
            }
            return FitnessBiologyMetric(
                id: id,
                state: .demo(
                    value: samples.last?.value ?? 0,
                    unit: id.unit,
                    sourceDevice: "Demo fixture",
                    sampleCount: samples.count,
                    freshness: "Demo snapshot",
                    window: "Last 7 days · demo",
                    provenance: "DEMO · NOT LIVE HEALTH DATA",
                    samples: samples
                )
            )
        }
        return FitnessBiologySnapshot(biologicalAge: .unavailable, metrics: metrics)
    }
}

extension FitnessBiologyMetric {
    public static var defaultMetrics: [FitnessBiologyMetric] {
        FitnessBiologyMetricID.allCases.map { .unavailable($0) }
    }
}

private enum FitnessBiologyValidation {
    static func isValidTimestamp(_ date: Date) -> Bool {
        let timestamp = date.timeIntervalSince1970
        let now = Date().timeIntervalSince1970
        return timestamp.isFinite && timestamp >= 946_684_800 && timestamp <= now + 86_400
    }

    static func reason(_ value: String?, fallback: String) -> String {
        let trimmed = value?.trimmed ?? ""
        return trimmed.isEmpty ? fallback : trimmed
    }
}

private extension String {
    var trimmed: String { trimmingCharacters(in: .whitespacesAndNewlines) }
    var isBlank: Bool { trimmed.isEmpty }
}
