import Foundation

extension FitnessMetric: Equatable {
    public static func == (lhs: FitnessMetric, rhs: FitnessMetric) -> Bool {
        lhs.id == rhs.id && lhs.title == rhs.title && lhs.value == rhs.value &&
        lhs.unit == rhs.unit && lhs.detail == rhs.detail && lhs.quality == rhs.quality &&
        lhs.sourceState == rhs.sourceState && lhs.provenance == rhs.provenance &&
        lhs.progress == rhs.progress && lhs.trend == rhs.trend
    }
}

/// Source-backed copy used by Fitness detail surfaces. A sentence is data too:
/// it must not imply an insight when its observations are missing.
public struct FitnessSourceCopy: Equatable {
    public enum State: Equatable {
        case unavailable(reason: String)
        case observed(text: String, window: String, provenance: String)
        case demo(text: String, window: String, provenance: String)
    }

    public let state: State

    public init(state: State) {
        self.state = Self.validated(state)
    }

    public static func unavailable(_ reason: String) -> FitnessSourceCopy {
        FitnessSourceCopy(state: .unavailable(reason: reason))
    }

    public var text: String? {
        switch state {
        case .unavailable:
            return nil
        case .observed(let text, _, _), .demo(let text, _, _):
            return text
        }
    }

    public var isUnavailable: Bool {
        if case .unavailable = state { return true }
        return false
    }

    private static func validated(_ state: State) -> State {
        func trimmed(_ value: String) -> String {
            value.trimmingCharacters(in: .whitespacesAndNewlines)
        }

        switch state {
        case .unavailable(let reason):
            let reason = trimmed(reason)
            return .unavailable(reason: reason.isEmpty ? "No source observation is available." : reason)
        case .observed(let text, let window, let provenance):
            let text = trimmed(text)
            let window = trimmed(window)
            let provenance = trimmed(provenance)
            guard !text.isEmpty, !window.isEmpty, !provenance.isEmpty else {
                return .unavailable(reason: "Source copy is invalid or missing provenance.")
            }
            return .observed(text: text, window: window, provenance: provenance)
        case .demo(let text, let window, let provenance):
            let text = trimmed(text)
            let window = trimmed(window)
            let provenance = trimmed(provenance)
            guard !text.isEmpty, !window.isEmpty, !provenance.isEmpty else {
                return .unavailable(reason: "Fixture copy is invalid or missing provenance.")
            }
            return .demo(text: text, window: window, provenance: provenance)
        }
    }
}

/// A load gauge may only be drawn against an explicit source target band.
/// LifeOS does not reverse-engineer Bevel's load formula or create a target.
public struct FitnessLoadGauge {
    public enum State: Equatable {
        case unavailable(reason: String)
        case observed(
            current: Double,
            lowerBound: Double,
            upperBound: Double,
            unit: String,
            window: String,
            provenance: String
        )
        case demo(
            current: Double,
            lowerBound: Double,
            upperBound: Double,
            unit: String,
            window: String,
            provenance: String
        )
    }

    public let state: State

    public init(state: State) {
        self.state = Self.validated(state)
    }

    public static let unavailable = FitnessLoadGauge(
        state: .unavailable(reason: "A source target band and current load are required.")
    )

    public var targetLabel: String {
        switch state {
        case .unavailable:
            return "Unavailable · target band not configured"
        case .observed(_, let lower, let upper, let unit, _, _),
                .demo(_, let lower, let upper, let unit, _, _):
            return "\(FitnessLoadGauge.format(lower))–\(FitnessLoadGauge.format(upper)) \(unit)"
        }
    }

    public var currentProgress: Double? {
        switch state {
        case .unavailable:
            return nil
        case .observed(let current, let lower, let upper, _, _, _),
                .demo(let current, let lower, let upper, _, _, _):
            guard upper > lower else { return nil }
            return min(1, max(0, (current - lower) / (upper - lower)))
        }
    }

    private static func format(_ value: Double) -> String {
        value.formatted(.number.precision(.fractionLength(0...1)))
    }

    private static func validated(_ state: State) -> State {
        func validText(_ value: String) -> Bool {
            !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
        func validNumbers(current: Double, lower: Double, upper: Double) -> Bool {
            current.isFinite && lower.isFinite && upper.isFinite && current >= 0 && lower >= 0 && upper > lower
        }

        switch state {
        case .unavailable(let reason):
            let reason = reason.trimmingCharacters(in: .whitespacesAndNewlines)
            return .unavailable(reason: reason.isEmpty ? "A source target band and current load are required." : reason)
        case .observed(let current, let lower, let upper, let unit, let window, let provenance):
            guard validNumbers(current: current, lower: lower, upper: upper), validText(unit), validText(window), validText(provenance) else {
                return .unavailable(reason: "Load target is invalid or missing its provenance.")
            }
            return .observed(current: current, lowerBound: lower, upperBound: upper, unit: unit.trimmingCharacters(in: .whitespacesAndNewlines), window: window.trimmingCharacters(in: .whitespacesAndNewlines), provenance: provenance.trimmingCharacters(in: .whitespacesAndNewlines))
        case .demo(let current, let lower, let upper, let unit, let window, let provenance):
            guard validNumbers(current: current, lower: lower, upper: upper), validText(unit), validText(window), validText(provenance) else {
                return .unavailable(reason: "Fixture load target is invalid or missing its provenance.")
            }
            return .demo(current: current, lowerBound: lower, upperBound: upper, unit: unit.trimmingCharacters(in: .whitespacesAndNewlines), window: window.trimmingCharacters(in: .whitespacesAndNewlines), provenance: provenance.trimmingCharacters(in: .whitespacesAndNewlines))
        }
    }
}

/// A named range is a UI selection only when the source supplied enough real
/// history for that range. The enum is shared by load and recovery so both
/// details keep the same date/range semantics.
public enum FitnessTrendRange: Int, CaseIterable, Hashable, Identifiable, Sendable {
    case three = 3
    case seven = 7
    case fourteen = 14
    case thirty = 30
    case ninety = 90

    public var id: Int { rawValue }

    public var title: String { "\(rawValue) days" }
}

/// Provenance is deliberately separate from a displayed value. A metric can
/// be observed while its source window or freshness metadata is unavailable;
/// that remains visible instead of being inferred from a neighbouring card.
public struct FitnessSourceEvidence: Equatable {
    public enum State: Equatable {
        case unavailable(reason: String)
        case permissionRequired(reason: String)
        case deviceUnavailable(reason: String)
        case readIndeterminate(reason: String)
        case calibrating(reason: String)
        case partial(reason: String)
        case stale(reason: String)
        case conflict(reason: String)
        case error(reason: String)
        case observed(source: String, device: String, window: String, freshness: String)
        case demo(source: String, device: String, window: String, freshness: String)
    }

    public let state: State

    public init(state: State) {
        self.state = Self.validated(state)
    }

    public static func unavailable(_ reason: String) -> FitnessSourceEvidence {
        FitnessSourceEvidence(state: .unavailable(reason: reason))
    }

    public static func from(metric: FitnessMetric) -> FitnessSourceEvidence {
        switch metric.sourceState {
        case .unavailable:
            return .unavailable(metric.detail)
        case .permissionRequired:
            return FitnessSourceEvidence(state: .permissionRequired(reason: metric.detail))
        case .deviceUnavailable:
            return FitnessSourceEvidence(state: .deviceUnavailable(reason: metric.detail))
        case .readIndeterminate:
            return FitnessSourceEvidence(state: .readIndeterminate(reason: metric.detail))
        case .calibrating:
            return FitnessSourceEvidence(state: .calibrating(reason: metric.detail))
        case .partial:
            return FitnessSourceEvidence(state: .partial(reason: metric.provenance?.summary ?? metric.detail))
        case .stale:
            return FitnessSourceEvidence(state: .stale(reason: metric.provenance?.summary ?? metric.detail))
        case .conflict:
            return FitnessSourceEvidence(state: .conflict(reason: metric.detail))
        case .error:
            return FitnessSourceEvidence(state: .error(reason: metric.detail))
        case .demo:
            return FitnessSourceEvidence(state: .demo(
                source: "DEMO · NOT LIVE",
                device: "Fixture",
                window: "Explicit fixture window",
                freshness: "Fixture timestamp"
            ))
        case .observed:
            guard let provenance = metric.provenance else {
                return .unavailable("Observed metric is missing source provenance.")
            }
            return FitnessSourceEvidence(state: .observed(
                source: provenance.source,
                device: provenance.device,
                window: provenance.window,
                freshness: provenance.freshness
            ))
        case .derived, .manual:
            return .unavailable("Source provenance is not supplied for this metric.")
        }
    }

    public var isUnavailable: Bool {
        switch state {
        case .unavailable, .permissionRequired, .deviceUnavailable,
             .readIndeterminate, .calibrating, .conflict, .error:
            return true
        case .partial, .stale, .observed, .demo:
            return false
        }
    }

    public var isDemo: Bool {
        if case .demo = state { return true }
        return false
    }

    public var isPartial: Bool {
        if case .partial = state { return true }
        return false
    }

    public var isStale: Bool {
        if case .stale = state { return true }
        return false
    }

    public var statusLabel: String {
        switch state {
        case .unavailable: "Unavailable"
        case .permissionRequired: "Permission required"
        case .deviceUnavailable: "Device unavailable"
        case .readIndeterminate: "Read status unknown"
        case .calibrating: "Calibrating"
        case .partial: "Partial"
        case .stale: "Stale"
        case .conflict: "Conflict"
        case .error: "Source error"
        case .observed: "Observed"
        case .demo: "Demo fixture"
        }
    }

    public var summary: String {
        switch state {
        case .unavailable(let reason): return "Unavailable · \(reason)"
        case .permissionRequired(let reason): return "Permission required · \(reason)"
        case .deviceUnavailable(let reason): return "Device unavailable · \(reason)"
        case .readIndeterminate(let reason): return "Read status unknown · \(reason)"
        case .calibrating(let reason): return "Calibrating · \(reason)"
        case .partial(let reason): return "Partial · \(reason)"
        case .stale(let reason): return "Stale · \(reason)"
        case .conflict(let reason): return "Conflict · \(reason)"
        case .error(let reason): return "Source error · \(reason)"
        case .observed(let source, let device, let window, let freshness),
             .demo(let source, let device, let window, let freshness):
            return "\(source) · \(device) · \(window) · \(freshness)"
        }
    }

    private static func validated(_ state: State) -> State {
        func clean(_ value: String) -> String {
            let value = value.trimmingCharacters(in: .whitespacesAndNewlines)
            return value.isEmpty ? "Not supplied" : value
        }

        switch state {
        case .unavailable(let reason):
            let reason = clean(reason)
            return .unavailable(reason: reason == "Not supplied" ? "Source evidence is not available." : reason)
        case .permissionRequired(let reason):
            let reason = clean(reason)
            return .permissionRequired(reason: reason == "Not supplied" ? "Source permission is required." : reason)
        case .deviceUnavailable(let reason):
            let reason = clean(reason)
            return .deviceUnavailable(reason: reason == "Not supplied" ? "The source device is unavailable." : reason)
        case .readIndeterminate(let reason):
            let reason = clean(reason)
            return .readIndeterminate(reason: reason == "Not supplied" ? "The source read result is indeterminate." : reason)
        case .calibrating(let reason):
            let reason = clean(reason)
            return .calibrating(reason: reason == "Not supplied" ? "Source calibration is incomplete." : reason)
        case .partial(let reason):
            let reason = clean(reason)
            return .partial(reason: reason == "Not supplied" ? "The source supplied only part of the requested data." : reason)
        case .stale(let reason):
            let reason = clean(reason)
            return .stale(reason: reason == "Not supplied" ? "The source observation is outside its freshness window." : reason)
        case .conflict(let reason):
            let reason = clean(reason)
            return .conflict(reason: reason == "Not supplied" ? "Conflicting source observations were withheld." : reason)
        case .error(let reason):
            let reason = clean(reason)
            return .error(reason: reason == "Not supplied" ? "The source reported an error." : reason)
        case .observed(let source, let device, let window, let freshness):
            let values = [source, device, window, freshness].map(clean)
            guard values.allSatisfy({ $0 != "Not supplied" }) else {
                return .unavailable(reason: "Source evidence is incomplete.")
            }
            return .observed(source: values[0], device: values[1], window: values[2], freshness: values[3])
        case .demo(let source, let device, let window, let freshness):
            let values = [source, device, window, freshness].map(clean)
            guard values.allSatisfy({ $0 != "Not supplied" }) else {
                return .unavailable(reason: "Fixture source evidence is incomplete.")
            }
            return .demo(source: values[0], device: values[1], window: values[2], freshness: values[3])
        }
    }
}

/// A trend keeps the source's finite values in their original unit. The view
/// may normalize these values for geometry, but it must never rewrite the
/// domain series into a percentage or clamp minutes/bpm into a 0...1 range.
public struct FitnessTrendSeries: Equatable {
    public let values: [Double]

    public init?(values: [Double]) {
        let finiteValues = values.filter(\.isFinite)
        guard !finiteValues.isEmpty else { return nil }
        self.values = finiteValues
    }

    public var minimum: Double { values.min() ?? 0 }
    public var maximum: Double { values.max() ?? 0 }
    public var first: Double { values[0] }
    public var last: Double { values[values.count - 1] }
    public var delta: Double { last - first }

    /// Explicitly view-only normalization. Equal samples sit on the midline so
    /// a valid flat series remains visible without inventing a scale.
    public var normalized: [Double] {
        let span = maximum - minimum
        guard span > 0, span.isFinite else {
            return values.map { _ in 0.5 }
        }
        return values.map { min(1, max(0, ($0 - minimum) / span)) }
    }

    public func context(unit: String) -> String {
        let suffix = unit.trimmingCharacters(in: .whitespacesAndNewlines)
        let range = "Range \(Self.format(minimum))–\(Self.format(maximum))"
        let delta = "Δ \(Self.signed(delta))"
        return suffix.isEmpty ? "\(range) · \(delta)" : "\(range) \(suffix) · \(delta) \(suffix)"
    }

    private static func format(_ value: Double) -> String {
        value.formatted(.number.precision(.fractionLength(0...1)))
    }

    private static func signed(_ value: Double) -> String {
        if value > 0 { return "+\(format(value))" }
        if value < 0 { return "−\(format(abs(value)))" }
        return format(value)
    }
}

private enum FitnessTrendSeriesValidation {
    static func validated(
        _ series: [FitnessTrendRange: [Double]],
        metric: FitnessMetric,
        evidence: FitnessSourceEvidence
    ) -> [FitnessTrendRange: [Double]] {
        guard metric.isValueAvailable, !evidence.isUnavailable else { return [:] }
        return series.reduce(into: [:]) { result, entry in
            guard let values = FitnessTrendSeries(values: entry.value)?.values else { return }
            result[entry.key] = values
        }
    }
}

public struct FitnessLoadTargetBand: Equatable {
    public let lower: Double
    public let upper: Double
    public let unit: String

    public init?(lower: Double, upper: Double, unit: String) {
        let unit = unit.trimmingCharacters(in: .whitespacesAndNewlines)
        guard lower.isFinite, upper.isFinite, lower >= 0, upper >= lower, !unit.isEmpty else { return nil }
        self.lower = lower
        self.upper = upper
        self.unit = unit
    }
}

public enum FitnessLoadTrendTruth: Equatable {
    case unavailable(reason: String)
    case observed
    case partial
    case stale
    case underTarget
    case inTarget
    case overTarget
    case demo

    public var label: String {
        switch self {
        case .unavailable: "Unavailable"
        case .observed: "Observed"
        case .partial: "Partial"
        case .stale: "Stale"
        case .underTarget: "Under target"
        case .inTarget: "Within target"
        case .overTarget: "Over target"
        case .demo: "Demo · not live"
        }
    }
}

public enum FitnessLoadTrendID: String, CaseIterable, Identifiable, Hashable {
    case load
    case duration
    case daytimeHeartRate
    case totalEnergy
    case steps

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .load: "Load"
        case .duration: "Training duration"
        case .daytimeHeartRate: "Daytime heart rate"
        case .totalEnergy: "Total energy"
        case .steps: "Steps"
        }
    }
}

public struct FitnessLoadTrendCard: Identifiable, Equatable {
    public let id: FitnessLoadTrendID
    public let metric: FitnessMetric
    public let evidence: FitnessSourceEvidence
    public let target: FitnessLoadTargetBand?
    public let availableRanges: Set<FitnessTrendRange>
    /// A range is selectable only when the source supplied a distinct series
    /// for that range. `metric.trend` is a point-in-time value and must never
    /// be relabelled as a longer history.
    public let seriesByRange: [FitnessTrendRange: [Double]]

    public init(
        id: FitnessLoadTrendID,
        metric: FitnessMetric,
        evidence: FitnessSourceEvidence? = nil,
        target: FitnessLoadTargetBand? = nil,
        availableRanges: Set<FitnessTrendRange> = [],
        seriesByRange: [FitnessTrendRange: [Double]] = [:]
    ) {
        self.id = id
        self.metric = metric
        let resolvedEvidence = evidence ?? FitnessSourceEvidence.from(metric: metric)
        self.evidence = resolvedEvidence
        self.target = target
        self.availableRanges = !metric.isValueAvailable || resolvedEvidence.isUnavailable ? [] : availableRanges
        self.seriesByRange = FitnessTrendSeriesValidation.validated(seriesByRange, metric: metric, evidence: resolvedEvidence)
    }

    public var availableSeriesRanges: Set<FitnessTrendRange> { Set(seriesByRange.keys) }

    public func series(for range: FitnessTrendRange) -> [Double]? { seriesByRange[range] }

    public var truth: FitnessLoadTrendTruth {
        guard metric.isValueAvailable, !evidence.isUnavailable else {
            return .unavailable(reason: metric.detail)
        }
        if metric.sourceState == .demo { return .demo }
        if metric.sourceState == .partial { return .partial }
        if metric.sourceState == .stale { return .stale }
        guard let target, let numericValue = Self.number(from: metric.value ?? "") else { return .observed }
        if numericValue < target.lower { return .underTarget }
        if numericValue > target.upper { return .overTarget }
        return .inTarget
    }

    private static func number(from value: String) -> Double? {
        let value = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { return nil }
        var normalized = value.replacingOccurrences(of: " ", with: "")
        normalized = normalized.replacingOccurrences(of: " ", with: "")
        if normalized.contains(",") && normalized.contains(".") {
            normalized = normalized.replacingOccurrences(of: ".", with: "").replacingOccurrences(of: ",", with: ".")
        } else if normalized.contains(",") {
            let parts = normalized.split(separator: ",", omittingEmptySubsequences: false)
            normalized = parts.count == 2 && parts[1].count == 3 ? parts.joined() : normalized.replacingOccurrences(of: ",", with: ".")
        } else if normalized.contains(".") {
            let parts = normalized.split(separator: ".", omittingEmptySubsequences: false)
            if parts.count == 2 && parts[1].count == 3 { normalized = parts.joined() }
        }
        let filtered = normalized.filter { $0.isNumber || $0 == "." || $0 == "-" }
        return Double(filtered)
    }
}

public enum FitnessZoneDurationReconciliation: Equatable {
    case unavailable(reason: String)
    case matched(zoneSeconds: Int, workoutSeconds: Int)
    case mismatch(zoneSeconds: Int, workoutSeconds: Int)

    public var label: String {
        switch self {
        case .unavailable(let reason): return "Unavailable · \(reason)"
        case .matched(let zone, let workout): return "Reconciled · \(zone)s across zones / \(workout)s workout"
        case .mismatch(let zone, let workout): return "Mismatch · \(zone)s across zones / \(workout)s workout"
        }
    }
}

public enum FitnessDurationParser {
    public static func seconds(value: String, unit: String = "") -> Int? {
        let raw = value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !raw.isEmpty else { return nil }
        let compact = raw.replacingOccurrences(of: " ", with: "")
        if compact.range(of: #"^\d{1,3}:\d{2}:\d{2}$"#, options: .regularExpression) != nil {
            let pieces = compact.split(separator: ":").compactMap { Int($0) }
            guard pieces.count == 3, pieces[1] < 60, pieces[2] < 60 else { return nil }
            return pieces[0] * 3600 + pieces[1] * 60 + pieces[2]
        }
        if compact.range(of: #"^\d{1,3}:\d{2}$"#, options: .regularExpression) != nil {
            let pieces = compact.split(separator: ":").compactMap { Int($0) }
            guard pieces.count == 2, pieces[1] < 60 else { return nil }
            return pieces[0] * 60 + pieces[1]
        }
        guard let number = Double(compact.replacingOccurrences(of: ",", with: ".")), number >= 0, number.isFinite else { return nil }
        switch unit.lowercased() {
        case "s", "sec", "secs", "second", "seconds": return Int(number.rounded())
        case "h", "hr", "hrs", "hour", "hours": return Int((number * 3600).rounded())
        default: return Int((number * 60).rounded())
        }
    }
}

public struct FitnessHeartRateZone: Identifiable, Equatable {
    public let id: Int
    public let duration: String
    public let durationSeconds: Int
    public let range: String
    public let provenance: String
    public let evidence: FitnessSourceEvidence

    public init?(zone: Int, duration: String, range: String, provenance: String, freshness: String = "Freshness not supplied", window: String = "Selected day", device: String = "Device not supplied") {
        let duration = duration.trimmingCharacters(in: .whitespacesAndNewlines)
        let range = range.trimmingCharacters(in: .whitespacesAndNewlines)
        let provenance = provenance.trimmingCharacters(in: .whitespacesAndNewlines)
        guard (0...5).contains(zone), !duration.isEmpty, !range.isEmpty, !provenance.isEmpty,
              let durationSeconds = FitnessDurationParser.seconds(value: duration) else {
            return nil
        }
        self.id = zone
        self.duration = duration
        self.durationSeconds = durationSeconds
        self.range = range
        self.provenance = provenance
        let evidenceState: FitnessSourceEvidence.State = provenance.localizedCaseInsensitiveContains("demo")
            ? .demo(source: provenance, device: device, window: window, freshness: freshness)
            : .observed(source: provenance, device: device, window: window, freshness: freshness)
        self.evidence = FitnessSourceEvidence(state: evidenceState)
    }
}

public struct FitnessLoadDetail {
    public let gauge: FitnessLoadGauge
    public let duration: FitnessMetric
    public let energy: FitnessMetric
    public let coaching: FitnessSourceCopy
    public let heartRateZones: [FitnessHeartRateZone]
    /// A trend is typed separately from the Today card. An empty trend means
    /// the source did not supply a trend; no flat history is created here.
    public let trend: FitnessMetric?
    public let trendCards: [FitnessLoadTrendCard]

    public init(
        gauge: FitnessLoadGauge = .unavailable,
        duration: FitnessMetric = .unavailable("Training duration"),
        energy: FitnessMetric = .unavailable("Energy expenditure"),
        coaching: FitnessSourceCopy = .unavailable("Coaching requires an observed load and target."),
        heartRateZones: [FitnessHeartRateZone] = [],
        trend: FitnessMetric? = nil,
        trendCards: [FitnessLoadTrendCard] = []
    ) {
        self.gauge = gauge
        self.duration = duration
        self.energy = energy
        self.coaching = coaching
        self.heartRateZones = heartRateZones
        self.trend = trend
        if trendCards.isEmpty {
            var defaults = FitnessLoadTrendID.allCases.map {
                FitnessLoadTrendCard(id: $0, metric: .unavailable($0.title))
            }
            if let trend, let index = defaults.firstIndex(where: { $0.id == .load }) {
                defaults[index] = FitnessLoadTrendCard(id: .load, metric: trend)
            }
            self.trendCards = defaults
        } else {
            self.trendCards = trendCards
        }
    }

    public var zoneDurationSeconds: Int? {
        guard !heartRateZones.isEmpty else { return nil }
        return heartRateZones.reduce(0) { $0 + $1.durationSeconds }
    }

    public var durationReconciliation: FitnessZoneDurationReconciliation {
        guard let zoneSeconds = zoneDurationSeconds else {
            return .unavailable(reason: "No numeric heart-rate-zone durations supplied.")
        }
        guard let durationValue = duration.value,
              let workoutSeconds = FitnessDurationParser.seconds(value: durationValue, unit: duration.unit) else {
            return .unavailable(reason: "Workout duration is not numeric.")
        }
        // Workout cards commonly round to whole minutes while zones retain
        // second precision. Treat a one-minute display-rounding delta as a
        // reconciliation, but surface larger disagreements explicitly.
        return abs(zoneSeconds - workoutSeconds) <= 60
            ? .matched(zoneSeconds: zoneSeconds, workoutSeconds: workoutSeconds)
            : .mismatch(zoneSeconds: zoneSeconds, workoutSeconds: workoutSeconds)
    }
}

public enum FitnessRecoveryTrendID: String, CaseIterable, Identifiable, Hashable {
    case recovery
    case restingHRV
    case restingHeartRate
    case respiration
    case bloodOxygen
    case wristTemperature

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .recovery: "Recovery score"
        case .restingHRV: "Resting HRV"
        case .restingHeartRate: "Resting heart rate"
        case .respiration: "Respiration"
        case .bloodOxygen: "Blood oxygen"
        case .wristTemperature: "Wrist temperature"
        }
    }
}

public struct FitnessRecoveryTrendCard: Identifiable {
    public let id: FitnessRecoveryTrendID
    public let metric: FitnessMetric
    public let evidence: FitnessSourceEvidence
    public let availableRanges: Set<FitnessTrendRange>
    public let seriesByRange: [FitnessTrendRange: [Double]]

    public init(
        id: FitnessRecoveryTrendID,
        metric: FitnessMetric,
        evidence: FitnessSourceEvidence? = nil,
        availableRanges: Set<FitnessTrendRange> = [],
        seriesByRange: [FitnessTrendRange: [Double]] = [:]
    ) {
        self.id = id
        self.metric = metric
        let resolvedEvidence = evidence ?? FitnessSourceEvidence.from(metric: metric)
        self.evidence = resolvedEvidence
        self.availableRanges = !metric.isValueAvailable || resolvedEvidence.isUnavailable ? [] : availableRanges
        self.seriesByRange = FitnessTrendSeriesValidation.validated(seriesByRange, metric: metric, evidence: resolvedEvidence)
    }

    public var availableSeriesRanges: Set<FitnessTrendRange> { Set(seriesByRange.keys) }

    public func series(for range: FitnessTrendRange) -> [Double]? { seriesByRange[range] }
}

public struct FitnessRecoveryDetail {
    public let hrv: FitnessMetric
    public let restingHeartRate: FitnessMetric
    public let explanation: FitnessSourceCopy
    public let insights: [FitnessSourceCopy]
    public let trends: [FitnessRecoveryTrendCard]

    public init(
        hrv: FitnessMetric = .unavailable("Resting HRV"),
        restingHeartRate: FitnessMetric = .unavailable("Resting heart rate"),
        explanation: FitnessSourceCopy = .unavailable("Recovery explanation requires a reviewed wake-time observation."),
        insights: [FitnessSourceCopy] = [],
        trends: [FitnessRecoveryTrendCard] = []
    ) {
        self.hrv = hrv
        self.restingHeartRate = restingHeartRate
        self.explanation = explanation
        self.insights = insights
        self.trends = trends.isEmpty
            ? FitnessRecoveryTrendID.allCases.map { FitnessRecoveryTrendCard(id: $0, metric: .unavailable($0.title)) }
            : trends
    }

    public static func from(readiness: FitnessMetric, healthMonitor: [FitnessMetric]) -> FitnessRecoveryDetail {
        func matching(_ id: FitnessRecoveryTrendID) -> FitnessMetric {
            healthMonitor.first { metric in
                let title = metric.title.lowercased().replacingOccurrences(of: "₂", with: "2")
                switch id {
                case .recovery: return false
                case .restingHRV: return title == "hrv" || title.contains("heart rate variability") || title.contains("resting hrv")
                case .restingHeartRate: return title.contains("resting heart rate") || title == "rhr"
                case .respiration: return title.contains("respiration")
                case .bloodOxygen: return title.contains("oxygen") || title.contains("spo2") || title.contains("sp02")
                case .wristTemperature: return title.contains("temperature")
                }
            } ?? .unavailable(id.title)
        }

        let hrv = matching(.restingHRV)
        let rhr = matching(.restingHeartRate)
        let trends = FitnessRecoveryTrendID.allCases.map { id in
            let metric = id == .recovery ? readiness : matching(id)
            // A range is enabled for an explicit visual fixture only. Live
            // callers must provide actual history before a range is offered.
            let ranges: Set<FitnessTrendRange> = metric.sourceState == .demo ? [.seven, .fourteen, .thirty] : []
            return FitnessRecoveryTrendCard(id: id, metric: metric, evidence: FitnessSourceEvidence.from(metric: metric), availableRanges: ranges)
        }
        let explanation: FitnessSourceCopy
        let insight: FitnessSourceCopy
        switch readiness.sourceState {
        case .unavailable, .permissionRequired, .deviceUnavailable,
             .readIndeterminate, .calibrating, .conflict, .error:
            explanation = .unavailable("A reviewed wake-time observation is not available.")
            insight = .unavailable("Insights require observed recovery inputs; no conclusion is drawn from missing data.")
        case .demo:
            explanation = FitnessSourceCopy(state: .demo(text: "Fixture-only recovery context; LifeOS does not reproduce a proprietary score formula.", window: "Explicit fixture window", provenance: "DEMO · NOT LIVE"))
            insight = FitnessSourceCopy(state: .demo(text: "Fixture-only insight copy; live recovery inputs are not connected.", window: "Explicit fixture window", provenance: "DEMO · NOT LIVE"))
        case .partial, .stale:
            explanation = .unavailable("\(readiness.sourceState.label) recovery input; the source did not provide a complete current observation.")
            insight = .unavailable("Insights require a complete current recovery observation; no conclusion is drawn from partial or stale data.")
        case .observed:
            explanation = FitnessSourceCopy(state: .observed(text: "Recovery context is source-defined. LifeOS exposes the contributing observations without recreating a proprietary formula.", window: "Source-defined window", provenance: "Source-backed readiness metric"))
            insight = FitnessSourceCopy(state: .observed(text: "Insights describe the observed inputs only; they do not claim causation or prescribe action.", window: "Source-defined window", provenance: "Source-backed readiness metric"))
        case .derived, .manual:
            explanation = .unavailable("Recovery input is not an observed source value.")
            insight = .unavailable("Insights require an observed source value; no conclusion is drawn from derived or manual input.")
        }
        return FitnessRecoveryDetail(hrv: hrv, restingHeartRate: rhr, explanation: explanation, insights: [insight], trends: trends)
    }
}

/// A sleep schedule is a configured target, not an observed sleep result.
///
/// The radial treatment in the reference is useful for communicating a
/// bedtime/wake window, but the values must come from an explicit user
/// schedule or an approved source. Keeping minutes and evidence together
/// prevents a duration or a quality score from being re-used as a schedule.
public struct FitnessSleepSchedule: Equatable {
    public enum State: Equatable {
        case unavailable(reason: String)
        case configured(
            windDownMinutes: Int,
            targetBedtimeMinutes: Int,
            wakeTargetMinutes: Int,
            sleepNeedMinutes: Int,
            timeZone: String,
            window: String,
            provenance: String,
            freshness: String
        )
    }

    public let state: State

    public init(state: State) {
        self.state = Self.validated(state)
    }

    public static let unavailable = FitnessSleepSchedule(
        state: .unavailable(reason: "No explicit sleep schedule is configured or supplied by the source.")
    )

    public var isUnavailable: Bool {
        if case .unavailable = state { return true }
        return false
    }

    public var evidenceSummary: String {
        switch state {
        case .unavailable(let reason):
            return "Unavailable · \(reason)"
        case .configured(_, _, _, _, let timeZone, let window, let provenance, let freshness):
            return "\(provenance) · \(timeZone) · \(window) · \(freshness)"
        }
    }

    public static func clockLabel(minutes: Int) -> String {
        let normalized = ((minutes % 1_440) + 1_440) % 1_440
        return String(format: "%02d:%02d", normalized / 60, normalized % 60)
    }

    public static func durationLabel(minutes: Int) -> String {
        let hours = minutes / 60
        let remainder = minutes % 60
        if hours == 0 { return "\(remainder)m" }
        if remainder == 0 { return "\(hours)h" }
        return "\(hours)h \(remainder)m"
    }

    private static func validated(_ state: State) -> State {
        func clean(_ value: String) -> String {
            value.trimmingCharacters(in: .whitespacesAndNewlines)
        }

        switch state {
        case .unavailable(let reason):
            let reason = clean(reason)
            return .unavailable(reason: reason.isEmpty ? "No explicit sleep schedule is configured or supplied by the source." : reason)
        case .configured(
            let windDownMinutes,
            let targetBedtimeMinutes,
            let wakeTargetMinutes,
            let sleepNeedMinutes,
            let timeZone,
            let window,
            let provenance,
            let freshness
        ):
            let timeZone = clean(timeZone)
            let window = clean(window)
            let provenance = clean(provenance)
            let freshness = clean(freshness)
            guard (0..<1_440).contains(windDownMinutes),
                  (0..<1_440).contains(targetBedtimeMinutes),
                  (0..<1_440).contains(wakeTargetMinutes),
                  (1...1_440).contains(sleepNeedMinutes),
                  !timeZone.isEmpty, !window.isEmpty, !provenance.isEmpty, !freshness.isEmpty else {
                return .unavailable(reason: "Sleep schedule values or provenance are invalid.")
            }
            return .configured(
                windDownMinutes: windDownMinutes,
                targetBedtimeMinutes: targetBedtimeMinutes,
                wakeTargetMinutes: wakeTargetMinutes,
                sleepNeedMinutes: sleepNeedMinutes,
                timeZone: timeZone,
                window: window,
                provenance: provenance,
                freshness: freshness
            )
        }
    }
}

/// A named boundary is part of the sleep contract. A calendar day is not a
/// sufficient definition for an overnight observation because a source may
/// assign a night by local midnight, a configurable cutoff, or its own
/// reviewed rule.
public struct FitnessSleepDayBoundary: Equatable {
    public let name: String
    public let timeZone: String

    public init?(name: String, timeZone: String) {
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let timeZone = timeZone.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, !timeZone.isEmpty else { return nil }
        self.name = name
        self.timeZone = timeZone
    }

    public var summary: String { "\(name) · \(timeZone)" }
}

/// Sleep evidence is deliberately more specific than a generic metric. The
/// source, provenance, and freshness belong to the observed night, and a
/// fixture can never be mistaken for a live observation.
public struct FitnessSleepObservationEvidence: Equatable {
    public enum State: Equatable {
        case unavailable(reason: String)
        case permissionRequired(reason: String)
        case deviceUnavailable(reason: String)
        case readIndeterminate(reason: String)
        case observed(source: String, device: String, provenance: String, freshness: String)
        case partial(reason: String)
        case stale(reason: String)
        case conflict(reason: String)
        case error(reason: String)
        case demo(source: String, device: String, provenance: String, freshness: String)
    }

    public let state: State

    public init(state: State) {
        self.state = Self.validated(state)
    }

    public static func unavailable(_ reason: String) -> FitnessSleepObservationEvidence {
        FitnessSleepObservationEvidence(state: .unavailable(reason: reason))
    }

    public var summary: String {
        switch state {
        case .unavailable(let reason): return "Unavailable · \(reason)"
        case .permissionRequired(let reason): return "Permission required · \(reason)"
        case .deviceUnavailable(let reason): return "Device unavailable · \(reason)"
        case .readIndeterminate(let reason): return "Read status unknown · \(reason)"
        case .partial(let reason): return "Partial · \(reason)"
        case .stale(let reason): return "Stale · \(reason)"
        case .conflict(let reason): return "Conflict · \(reason)"
        case .error(let reason): return "Source error · \(reason)"
        case .observed(let source, let device, let provenance, let freshness),
             .demo(let source, let device, let provenance, let freshness):
            return "\(source) · \(device) · \(provenance) · \(freshness)"
        }
    }

    public var isUnavailable: Bool {
        switch state {
        case .unavailable, .permissionRequired, .deviceUnavailable,
             .readIndeterminate, .conflict, .error:
            return true
        case .observed, .partial, .stale, .demo:
            return false
        }
    }

    public var isDemo: Bool {
        if case .demo = state { return true }
        return false
    }

    public var isPartial: Bool {
        if case .partial = state { return true }
        return false
    }

    public var isStale: Bool {
        if case .stale = state { return true }
        return false
    }

    public var statusLabel: String {
        switch state {
        case .unavailable: "Unavailable"
        case .permissionRequired: "Permission required"
        case .deviceUnavailable: "Device unavailable"
        case .readIndeterminate: "Read status unknown"
        case .observed: "Observed"
        case .partial: "Partial"
        case .stale: "Stale"
        case .conflict: "Conflict"
        case .error: "Source error"
        case .demo: "Demo fixture"
        }
    }

    private static func validated(_ state: State) -> State {
        func clean(_ value: String) -> String {
            value.trimmingCharacters(in: .whitespacesAndNewlines)
        }

        switch state {
        case .unavailable(let reason):
            let reason = clean(reason)
            return .unavailable(reason: reason.isEmpty ? "Sleep source evidence is unavailable." : reason)
        case .permissionRequired(let reason):
            let reason = clean(reason)
            return .permissionRequired(reason: reason.isEmpty ? "Sleep source permission is required." : reason)
        case .deviceUnavailable(let reason):
            let reason = clean(reason)
            return .deviceUnavailable(reason: reason.isEmpty ? "The sleep source device is unavailable." : reason)
        case .readIndeterminate(let reason):
            let reason = clean(reason)
            return .readIndeterminate(reason: reason.isEmpty ? "Sleep read status is indeterminate." : reason)
        case .observed(let source, let device, let provenance, let freshness):
            let values = [source, device, provenance, freshness].map(clean)
            guard values.allSatisfy({ !$0.isEmpty }) else {
                return .unavailable(reason: "Sleep source evidence is incomplete.")
            }
            return .observed(source: values[0], device: values[1], provenance: values[2], freshness: values[3])
        case .partial(let reason):
            let reason = clean(reason)
            return .partial(reason: reason.isEmpty ? "The source supplied only part of the sleep night." : reason)
        case .stale(let reason):
            let reason = clean(reason)
            return .stale(reason: reason.isEmpty ? "The sleep source observation is outside its freshness window." : reason)
        case .conflict(let reason):
            let reason = clean(reason)
            return .conflict(reason: reason.isEmpty ? "Conflicting sleep observations were withheld." : reason)
        case .error(let reason):
            let reason = clean(reason)
            return .error(reason: reason.isEmpty ? "The sleep source reported an error." : reason)
        case .demo(let source, let device, let provenance, let freshness):
            let values = [source, device, provenance, freshness].map(clean)
            guard values.allSatisfy({ !$0.isEmpty }) else {
                return .unavailable(reason: "Sleep fixture evidence is incomplete.")
            }
            return .demo(source: values[0], device: values[1], provenance: values[2], freshness: values[3])
        }
    }
}

public struct FitnessSleepStageSample: Identifiable, Equatable {
    public enum Stage: String, CaseIterable, Identifiable {
        case rem
        case deep
        case core
        case awake

        public var id: String { rawValue }

        public var title: String {
            switch self {
            case .rem: "REM"
            case .deep: "Deep"
            case .core: "Core"
            case .awake: "Awake"
            }
        }
    }

    public let id: String
    public let stage: Stage
    public let start: Date
    public let end: Date

    public init?(id: String? = nil, stage: Stage, start: Date, end: Date) {
        guard end > start else { return nil }
        self.id = id ?? "\(stage.rawValue)-\(start.timeIntervalSinceReferenceDate)-\(end.timeIntervalSinceReferenceDate)"
        self.stage = stage
        self.start = start
        self.end = end
    }

    public var durationSeconds: Int { max(0, Int(end.timeIntervalSince(start).rounded())) }
}

/// The source truth behind the sleep timeline. `partial` means the source
/// supplied only part of the night (for example an interval without stages),
/// while `conflict` is reserved for mutually inconsistent observations. These
/// states are never collapsed into zeroes or a score.
public struct FitnessSleepNight: Identifiable, Equatable {
    public enum State: Equatable {
        case unavailable(reason: String)
        case partial(reason: String)
        case observed
        case conflict(reason: String)

        public var label: String {
            switch self {
            case .unavailable: "Unavailable"
            case .partial: "Partial"
            case .observed: "Observed"
            case .conflict: "Conflict"
            }
        }
    }

    public let id: String
    public let start: Date?
    public let end: Date?
    public let stageSamples: [FitnessSleepStageSample]
    public let boundary: FitnessSleepDayBoundary?
    public let evidence: FitnessSleepObservationEvidence
    public let state: State

    public init(
        id: String = "sleep-night",
        start: Date? = nil,
        end: Date? = nil,
        stageSamples: [FitnessSleepStageSample] = [],
        boundary: FitnessSleepDayBoundary? = nil,
        evidence: FitnessSleepObservationEvidence = .unavailable("No observed sleep night is available."),
        state: State = .unavailable(reason: "No observed sleep night is available.")
    ) {
        self.id = id
        self.start = start
        self.end = end
        self.stageSamples = stageSamples.sorted { $0.start < $1.start }
        self.boundary = boundary
        self.evidence = evidence
        self.state = Self.validated(
            state: state,
            start: start,
            end: end,
            stages: stageSamples,
            boundary: boundary,
            evidence: evidence
        )
    }

    public static let unavailable = FitnessSleepNight()

    public var durationSeconds: Int? {
        guard let start, let end, end > start else { return nil }
        return Int(end.timeIntervalSince(start).rounded())
    }

    public var isUnavailable: Bool {
        if case .unavailable = state { return true }
        return false
    }

    public var statusSummary: String {
        switch state {
        case .unavailable(let reason), .partial(let reason), .conflict(let reason):
            return "\(state.label) · \(reason)"
        case .observed:
            return "Observed · \(evidence.summary)"
        }
    }

    private static func validated(
        state: State,
        start: Date?,
        end: Date?,
        stages: [FitnessSleepStageSample],
        boundary: FitnessSleepDayBoundary?,
        evidence: FitnessSleepObservationEvidence
    ) -> State {
        func reason(_ value: String, fallback: String) -> String {
            let clean = value.trimmingCharacters(in: .whitespacesAndNewlines)
            return clean.isEmpty ? fallback : clean
        }

        switch state {
        case .unavailable(let value):
            return .unavailable(reason: reason(value, fallback: "No observed sleep night is available."))
        case .partial(let value):
            return .partial(reason: reason(value, fallback: "The source supplied only part of this sleep night."))
        case .conflict(let value):
            return .conflict(reason: reason(value, fallback: "Source observations disagree for this sleep night."))
        case .observed:
            guard let start, let end, end > start else {
                return .unavailable(reason: "Observed sleep interval has no valid start and end.")
            }
            guard boundary != nil else {
                return .unavailable(reason: "Observed sleep interval has no named sleep-day boundary.")
            }
            guard !evidence.isUnavailable else {
                return .unavailable(reason: evidence.summary)
            }
            if stages.isEmpty {
                return .partial(reason: "Sleep interval is present, but no stage samples were supplied.")
            }
            let sorted = stages.sorted { $0.start < $1.start }
            for sample in sorted where sample.start < start || sample.end > end {
                return .conflict(reason: "Stage sample falls outside the observed sleep interval.")
            }
            for pair in zip(sorted, sorted.dropFirst()) where pair.0.end > pair.1.start {
                return .conflict(reason: "Stage samples overlap and cannot be rendered as one timeline.")
            }
            if let first = sorted.first, let last = sorted.last,
               first.start > start || last.end < end || zip(sorted, sorted.dropFirst()).contains(where: { $0.0.end < $0.1.start }) {
                return .partial(reason: "Stage samples do not cover the full observed sleep interval.")
            }
            return .observed
        }
    }
}

public enum FitnessSleepTrendID: String, CaseIterable, Identifiable, Hashable {
    case quality
    case timeInBed
    case duration
    case rem
    case deep
    case core
    case awake
    case heartRateDrop
    case sleepBalance
    case wakeTime
    case sleepOnset

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .quality: "Sleep quality"
        case .timeInBed: "Time in bed"
        case .duration: "Sleep duration"
        case .rem: "REM sleep"
        case .deep: "Deep sleep"
        case .core: "Core sleep"
        case .awake: "Awake time"
        case .heartRateDrop: "Heart-rate drop"
        case .sleepBalance: "Sleep balance"
        case .wakeTime: "Wake time"
        case .sleepOnset: "Sleep onset"
        }
    }

    public var icon: LifeOSIconName {
        switch self {
        case .quality: .sleep
        case .timeInBed, .duration, .wakeTime, .sleepOnset: .calendar
        case .rem, .deep, .core: .sleep
        case .awake: .heartRate
        case .heartRateDrop: .heartRate
        case .sleepBalance: .health
        }
    }
}

public struct FitnessSleepTrendCard: Identifiable, Equatable {
    public let id: FitnessSleepTrendID
    public let metric: FitnessMetric
    public let evidence: FitnessSourceEvidence
    public let availableRanges: Set<FitnessTrendRange>
    public let seriesByRange: [FitnessTrendRange: [Double]]

    public init(
        id: FitnessSleepTrendID,
        metric: FitnessMetric,
        evidence: FitnessSourceEvidence? = nil,
        availableRanges: Set<FitnessTrendRange> = [],
        seriesByRange: [FitnessTrendRange: [Double]] = [:]
    ) {
        self.id = id
        self.metric = metric
        let resolvedEvidence = evidence ?? FitnessSourceEvidence.from(metric: metric)
        self.evidence = resolvedEvidence
        self.availableRanges = !metric.isValueAvailable || resolvedEvidence.isUnavailable ? [] : availableRanges
        self.seriesByRange = FitnessTrendSeriesValidation.validated(seriesByRange, metric: metric, evidence: resolvedEvidence)
    }

    public var availableSeriesRanges: Set<FitnessTrendRange> { Set(seriesByRange.keys) }

    public func series(for range: FitnessTrendRange) -> [Double]? { seriesByRange[range] }
}

public struct FitnessSleepDetail {
    /// The interval and stage timeline are kept separate from generic Today
    /// metrics so a duration cannot become a score, time-in-bed, or stage.
    public let night: FitnessSleepNight
    public let quality: FitnessMetric
    public let timeInBed: FitnessMetric
    public let duration: FitnessMetric
    public let schedule: FitnessSleepSchedule
    public let sleepNeed: FitnessSourceCopy
    public let windDown: FitnessSourceCopy
    public let insights: [FitnessSourceCopy]
    public let trends: [FitnessSleepTrendCard]

    public init(
        night: FitnessSleepNight = .unavailable,
        quality: FitnessMetric = .unavailable("Sleep quality"),
        timeInBed: FitnessMetric = .unavailable("Time in bed"),
        duration: FitnessMetric = .unavailable("Sleep duration"),
        schedule: FitnessSleepSchedule = .unavailable,
        sleepNeed: FitnessSourceCopy = .unavailable("Sleep need requires a configured target and source sleep history."),
        windDown: FitnessSourceCopy = .unavailable("Wind-down requires a configured sleep schedule."),
        insights: [FitnessSourceCopy] = [],
        trends: [FitnessSleepTrendCard] = []
    ) {
        self.night = night
        self.quality = quality
        self.timeInBed = timeInBed
        self.duration = duration
        self.schedule = schedule
        self.sleepNeed = sleepNeed
        self.windDown = windDown
        self.insights = insights
        let defaults = [
            FitnessSleepTrendCard(id: .quality, metric: quality),
            FitnessSleepTrendCard(id: .timeInBed, metric: timeInBed),
            FitnessSleepTrendCard(id: .duration, metric: duration),
            FitnessSleepTrendCard(id: .rem, metric: .unavailable(FitnessSleepTrendID.rem.title)),
            FitnessSleepTrendCard(id: .deep, metric: .unavailable(FitnessSleepTrendID.deep.title)),
            FitnessSleepTrendCard(id: .core, metric: .unavailable(FitnessSleepTrendID.core.title)),
            FitnessSleepTrendCard(id: .awake, metric: .unavailable(FitnessSleepTrendID.awake.title)),
            FitnessSleepTrendCard(id: .heartRateDrop, metric: .unavailable(FitnessSleepTrendID.heartRateDrop.title)),
            FitnessSleepTrendCard(id: .sleepBalance, metric: .unavailable(FitnessSleepTrendID.sleepBalance.title)),
            FitnessSleepTrendCard(id: .wakeTime, metric: .unavailable(FitnessSleepTrendID.wakeTime.title)),
            FitnessSleepTrendCard(id: .sleepOnset, metric: .unavailable(FitnessSleepTrendID.sleepOnset.title))
        ]
        self.trends = trends.isEmpty ? defaults : trends
    }

    public static func from(sleep: FitnessMetric) -> FitnessSleepDetail {
        guard let duration = durationMetric(from: sleep) else {
            return FitnessSleepDetail()
        }
        return FitnessSleepDetail(duration: duration)
    }

    /// The Today snapshot exposes a generic `Sleep` value. It is safe to carry
    /// that value into duration only when the value itself is recognisably a
    /// duration. It is never a sleep-quality or time-in-bed observation.
    private static func durationMetric(from sleep: FitnessMetric) -> FitnessMetric? {
        let title = sleep.title.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard title == "sleep" || title == "sleep duration" else { return nil }
        guard sleep.isValueAvailable, let value = sleep.value else { return nil }

        let normalized = value
            .lowercased()
            .replacingOccurrences(of: "hours", with: "h")
            .replacingOccurrences(of: "hour", with: "h")
            .replacingOccurrences(of: "hrs", with: "h")
            .replacingOccurrences(of: "mins", with: "m")
            .replacingOccurrences(of: "minutes", with: "m")
            .replacingOccurrences(of: "minute", with: "m")
            .replacingOccurrences(of: " ", with: "")
        let pattern = #"^(?=.*\d)(?:\d{1,3}h)?(?:\d{1,3}m)?$"#
        guard normalized.range(of: pattern, options: .regularExpression) != nil,
              normalized.contains("h") || normalized.contains("m") else {
            return nil
        }

        return FitnessMetric(
            id: "\(sleep.id)-duration",
            title: "Sleep duration",
            value: sleep.value,
            unit: sleep.unit,
            detail: sleep.detail,
            quality: sleep.quality,
            progress: sleep.progress,
            hue: sleep.hue,
            trend: sleep.trend,
            sourceState: sleep.sourceState,
            provenance: sleep.provenance
        )
    }
}
