import Foundation

/// The Stress contract is source-aware by construction. A number shown here is
/// either supplied by the source, an explicitly labelled visual fixture, stale,
/// or unavailable. LifeOS does not recreate a proprietary stress formula.
public struct FitnessStressEvidence: Equatable, Sendable {
    public enum State: Equatable, Sendable {
        case unavailable(reason: String)
        case observed(source: String, device: String, window: String, freshness: String)
        case stale(source: String, device: String, window: String, freshness: String)
        case demo(source: String, device: String, window: String, freshness: String)
    }

    public let state: State

    public init(state: State) {
        self.state = Self.validated(state)
    }

    public static func unavailable(_ reason: String) -> FitnessStressEvidence {
        FitnessStressEvidence(state: .unavailable(reason: reason))
    }

    public var isUnavailable: Bool {
        if case .unavailable = state { return true }
        return false
    }

    public var isDemo: Bool {
        if case .demo = state { return true }
        return false
    }

    public var isStale: Bool {
        if case .stale = state { return true }
        return false
    }

    public var summary: String {
        switch state {
        case .unavailable(let reason):
            return "Unavailable · \(reason)"
        case .observed(let source, let device, let window, let freshness),
             .stale(let source, let device, let window, let freshness),
             .demo(let source, let device, let window, let freshness):
            return "\(source) · \(device) · \(window) · \(freshness)"
        }
    }

    public var source: String? {
        switch state {
        case .unavailable: return nil
        case .observed(let source, _, _, _), .stale(let source, _, _, _), .demo(let source, _, _, _):
            return source
        }
    }

    private static func validated(_ state: State) -> State {
        func clean(_ value: String) -> String {
            value.trimmingCharacters(in: .whitespacesAndNewlines)
        }

        switch state {
        case .unavailable(let reason):
            let reason = clean(reason)
            return .unavailable(reason: reason.isEmpty ? "No Stress source observation is available." : reason)
        case .observed(let source, let device, let window, let freshness):
            let values = [source, device, window, freshness].map(clean)
            guard values.allSatisfy({ !$0.isEmpty }) else {
                return .unavailable(reason: "Stress source evidence is incomplete.")
            }
            return .observed(source: values[0], device: values[1], window: values[2], freshness: values[3])
        case .stale(let source, let device, let window, let freshness):
            let values = [source, device, window, freshness].map(clean)
            guard values.allSatisfy({ !$0.isEmpty }) else {
                return .unavailable(reason: "Stale Stress source evidence is incomplete.")
            }
            return .stale(source: values[0], device: values[1], window: values[2], freshness: values[3])
        case .demo(let source, let device, let window, let freshness):
            let values = [source, device, window, freshness].map(clean)
            guard values.allSatisfy({ !$0.isEmpty }) else {
                return .unavailable(reason: "Stress fixture evidence is incomplete.")
            }
            return .demo(source: values[0], device: values[1], window: values[2], freshness: values[3])
        }
    }
}

public struct FitnessStressCopy: Equatable, Sendable {
    public enum State: Equatable, Sendable {
        case unavailable(reason: String)
        case observed(text: String, window: String, provenance: String)
        case stale(text: String, window: String, provenance: String)
        case demo(text: String, window: String, provenance: String)
    }

    public let state: State

    public init(state: State) {
        self.state = Self.validated(state)
    }

    public static func unavailable(_ reason: String) -> FitnessStressCopy {
        FitnessStressCopy(state: .unavailable(reason: reason))
    }

    public var text: String? {
        switch state {
        case .unavailable: return nil
        case .observed(let text, _, _), .stale(let text, _, _), .demo(let text, _, _): return text
        }
    }

    public var isUnavailable: Bool {
        if case .unavailable = state { return true }
        return false
    }

    public var provenanceSummary: String? {
        switch state {
        case .unavailable: return nil
        case .observed(_, let window, let provenance),
             .stale(_, let window, let provenance),
             .demo(_, let window, let provenance):
            return "\(window) · \(provenance)"
        }
    }

    private static func validated(_ state: State) -> State {
        func clean(_ value: String) -> String {
            value.trimmingCharacters(in: .whitespacesAndNewlines)
        }

        switch state {
        case .unavailable(let reason):
            let reason = clean(reason)
            return .unavailable(reason: reason.isEmpty ? "Source-authored coaching is unavailable." : reason)
        case .observed(let text, let window, let provenance):
            let values = [text, window, provenance].map(clean)
            guard values.allSatisfy({ !$0.isEmpty }) else {
                return .unavailable(reason: "Source-authored coaching is incomplete.")
            }
            return .observed(text: values[0], window: values[1], provenance: values[2])
        case .stale(let text, let window, let provenance):
            let values = [text, window, provenance].map(clean)
            guard values.allSatisfy({ !$0.isEmpty }) else {
                return .unavailable(reason: "Stale source-authored coaching is incomplete.")
            }
            return .stale(text: values[0], window: values[1], provenance: values[2])
        case .demo(let text, let window, let provenance):
            let values = [text, window, provenance].map(clean)
            guard values.allSatisfy({ !$0.isEmpty }) else {
                return .unavailable(reason: "Fixture coaching is incomplete.")
            }
            return .demo(text: values[0], window: values[1], provenance: values[2])
        }
    }
}

public struct FitnessStressScale: Equatable, Sendable {
    public let minimum: Double
    public let maximum: Double
    public let unit: String
    public let provenance: String

    public init?(minimum: Double, maximum: Double, unit: String, provenance: String) {
        let unit = unit.trimmingCharacters(in: .whitespacesAndNewlines)
        let provenance = provenance.trimmingCharacters(in: .whitespacesAndNewlines)
        guard minimum.isFinite, maximum.isFinite, minimum < maximum,
              !unit.isEmpty, !provenance.isEmpty else { return nil }
        self.minimum = minimum
        self.maximum = maximum
        self.unit = unit
        self.provenance = provenance
    }

    public func normalized(_ value: Double) -> Double {
        guard maximum > minimum else { return 0 }
        return min(1, max(0, (value - minimum) / (maximum - minimum)))
    }
}

public struct FitnessStressMetric: Equatable, Sendable {
    public let id: String
    public let title: String
    public let value: Double?
    public let unit: String
    public let state: FitnessStressEvidence.State
    public let evidence: FitnessStressEvidence
    public let scale: FitnessStressScale?

    public init(
        id: String? = nil,
        title: String,
        value: Double?,
        unit: String,
        state: FitnessStressEvidence.State,
        evidence: FitnessStressEvidence,
        scale: FitnessStressScale? = nil
    ) {
        let cleanTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
        let cleanUnit = unit.trimmingCharacters(in: .whitespacesAndNewlines)
        let safeTitle = cleanTitle.isEmpty ? "Stress metric" : cleanTitle
        let safeEvidence = evidence
        let compatibleValue: Double?
        let compatibleState: FitnessStressEvidence.State
        switch safeEvidence.state {
        case .unavailable:
            compatibleValue = nil
            compatibleState = safeEvidence.state
        case .observed, .stale, .demo:
            guard let value, value.isFinite else {
                compatibleValue = nil
                compatibleState = .unavailable(reason: "\(safeTitle) has no finite source value.")
                self.id = id ?? cleanTitle
                self.title = safeTitle
                self.value = compatibleValue
                self.unit = cleanUnit
                self.state = compatibleState
                self.evidence = .unavailable("Stress metric value is invalid.")
                self.scale = nil
                return
            }
            compatibleValue = value
            compatibleState = safeEvidence.state
        }
        self.id = id ?? (cleanTitle.isEmpty ? "stress-metric" : cleanTitle)
        self.title = safeTitle
        self.value = compatibleValue
        self.unit = cleanUnit
        self.state = compatibleState
        self.evidence = safeEvidence.isUnavailable ? .unavailable(safeEvidence.summary) : safeEvidence
        self.scale = scale
    }

    public static func unavailable(_ title: String, reason: String = "No source observation is available.") -> FitnessStressMetric {
        let evidence = FitnessStressEvidence.unavailable(reason)
        return FitnessStressMetric(title: title, value: nil, unit: "", state: evidence.state, evidence: evidence)
    }

    public var isUnavailable: Bool { value == nil || evidence.isUnavailable }

    public var progress: Double? {
        guard let value, let scale else { return nil }
        return scale.normalized(value)
    }
}

public enum FitnessStressSeriesKind: String, CaseIterable, Hashable, Identifiable, Sendable {
    case overall
    case nonActivity
    case sleep

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .overall: return "Stress"
        case .nonActivity: return "Non-activity stress"
        case .sleep: return "Sleep stress"
        }
    }
}

public struct FitnessStressSample: Identifiable, Equatable, Sendable {
    public let id: String
    public let timestamp: Date
    public let value: Double

    public init?(id: String? = nil, timestamp: Date, value: Double) {
        let cleanID = id?.trimmingCharacters(in: .whitespacesAndNewlines)
        guard timestamp.timeIntervalSince1970.isFinite, value.isFinite else { return nil }
        self.id = cleanID?.isEmpty == false ? cleanID! : "stress-\(timestamp.timeIntervalSince1970)-\(value)"
        self.timestamp = timestamp
        self.value = value
    }
}

public struct FitnessStressSeries: Equatable, Sendable {
    public let kind: FitnessStressSeriesKind
    public let samples: [FitnessStressSample]
    public let evidence: FitnessStressEvidence
    public let scale: FitnessStressScale?

    public init(
        kind: FitnessStressSeriesKind,
        samples: [FitnessStressSample] = [],
        evidence: FitnessStressEvidence = .unavailable("No \(FitnessStressSeriesKind.overall.title) samples are available."),
        scale: FitnessStressScale? = nil
    ) {
        self.kind = kind
        self.evidence = evidence
        self.scale = scale
        guard !evidence.isUnavailable else {
            self.samples = []
            return
        }
        self.samples = samples.sorted { lhs, rhs in
            if lhs.timestamp == rhs.timestamp { return lhs.id < rhs.id }
            return lhs.timestamp < rhs.timestamp
        }
    }

    public static func unavailable(_ kind: FitnessStressSeriesKind) -> FitnessStressSeries {
        FitnessStressSeries(kind: kind, evidence: .unavailable("No \(kind.title) samples are available."))
    }

    public var isUnavailable: Bool { evidence.isUnavailable || samples.isEmpty }

    public var values: [Double] { samples.map(\.value) }
}

public enum FitnessStressBand: String, CaseIterable, Hashable, Sendable {
    case low
    case medium
    case high

    public var title: String {
        switch self {
        case .low: return "Low"
        case .medium: return "Medium"
        case .high: return "High"
        }
    }
}

public struct FitnessStressThresholdLabels: Equatable, Sendable {
    public let labels: [FitnessStressBand: String]
    public let provenance: String

    public init?(labels: [FitnessStressBand: String], provenance: String) {
        let cleanProvenance = provenance.trimmingCharacters(in: .whitespacesAndNewlines)
        guard Set(labels.keys) == Set(FitnessStressBand.allCases),
              labels.values.allSatisfy({ !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }),
              !cleanProvenance.isEmpty else { return nil }
        self.labels = labels.mapValues { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
        self.provenance = cleanProvenance
    }

    public subscript(band: FitnessStressBand) -> String? { labels[band] }
}

public struct FitnessStressDistribution: Equatable, Sendable {
    public enum State: Equatable, Sendable {
        case unavailable(reason: String)
        case observed(totalSeconds: Int, durations: [FitnessStressBand: Int], labels: FitnessStressThresholdLabels?, provenance: String)
        case stale(totalSeconds: Int, durations: [FitnessStressBand: Int], labels: FitnessStressThresholdLabels?, provenance: String)
        case demo(totalSeconds: Int, durations: [FitnessStressBand: Int], labels: FitnessStressThresholdLabels?, provenance: String)
    }

    public let state: State

    public init(state: State) {
        self.state = Self.validated(state)
    }

    public static func unavailable(_ reason: String = "No observed stress duration is available.") -> FitnessStressDistribution {
        FitnessStressDistribution(state: .unavailable(reason: reason))
    }

    public var totalObservedSeconds: Int? {
        switch state {
        case .unavailable: return nil
        case .observed(let total, _, _, _), .stale(let total, _, _, _), .demo(let total, _, _, _): return total
        }
    }

    public func duration(for band: FitnessStressBand) -> Int? {
        switch state {
        case .unavailable: return nil
        case .observed(_, let durations, _, _), .stale(_, let durations, _, _), .demo(_, let durations, _, _):
            return durations[band]
        }
    }

    public func percentage(for band: FitnessStressBand) -> Double? {
        guard let total = totalObservedSeconds, total > 0, let duration = duration(for: band) else { return nil }
        return Double(duration) / Double(total)
    }

    public var labels: FitnessStressThresholdLabels? {
        switch state {
        case .unavailable: return nil
        case .observed(_, _, let labels, _), .stale(_, _, let labels, _), .demo(_, _, let labels, _): return labels
        }
    }

    public var isUnavailable: Bool {
        if case .unavailable = state { return true }
        return false
    }

    public var provenance: String? {
        switch state {
        case .unavailable: return nil
        case .observed(_, _, _, let provenance), .stale(_, _, _, let provenance), .demo(_, _, _, let provenance): return provenance
        }
    }

    private static func validated(_ state: State) -> State {
        func clean(_ value: String) -> String { value.trimmingCharacters(in: .whitespacesAndNewlines) }
        func valid(
            total: Int,
            durations: [FitnessStressBand: Int],
            provenance: String
        ) -> Bool {
            total >= 0 && Set(durations.keys) == Set(FitnessStressBand.allCases) &&
            durations.values.allSatisfy { $0 >= 0 } && durations.values.reduce(0, +) == total && !clean(provenance).isEmpty
        }

        switch state {
        case .unavailable(let reason):
            let reason = clean(reason)
            return .unavailable(reason: reason.isEmpty ? "No observed stress duration is available." : reason)
        case .observed(let total, let durations, let labels, let provenance):
            guard valid(total: total, durations: durations, provenance: provenance) else {
                return .unavailable(reason: "Stress duration buckets do not reconcile to observed duration.")
            }
            return .observed(totalSeconds: total, durations: durations, labels: labels, provenance: clean(provenance))
        case .stale(let total, let durations, let labels, let provenance):
            guard valid(total: total, durations: durations, provenance: provenance) else {
                return .unavailable(reason: "Stale stress duration buckets do not reconcile to observed duration.")
            }
            return .stale(totalSeconds: total, durations: durations, labels: labels, provenance: clean(provenance))
        case .demo(let total, let durations, let labels, let provenance):
            guard valid(total: total, durations: durations, provenance: provenance) else {
                return .unavailable(reason: "Fixture stress duration buckets do not reconcile to observed duration.")
            }
            return .demo(totalSeconds: total, durations: durations, labels: labels, provenance: clean(provenance))
        }
    }
}

public struct FitnessStressCoverageDay: Identifiable, Equatable, Sendable {
    public enum State: Equatable, Sendable {
        case observed(durationSeconds: Int)
        case zeroObserved
        case unavailable(reason: String)
    }

    public let id: String
    public let date: Date
    public let state: State

    public init(date: Date, state: State) {
        self.date = date
        self.id = String(Int(date.timeIntervalSince1970))
        switch state {
        case .observed(let duration):
            self.state = duration >= 0 ? state : .unavailable(reason: "Coverage duration is invalid.")
        case .zeroObserved:
            self.state = state
        case .unavailable(let reason):
            let clean = reason.trimmingCharacters(in: .whitespacesAndNewlines)
            self.state = .unavailable(reason: clean.isEmpty ? "No observation for this day." : clean)
        }
    }

    public var isAvailable: Bool {
        switch state {
        case .observed, .zeroObserved: return true
        case .unavailable: return false
        }
    }

    public var isZeroObserved: Bool {
        if case .zeroObserved = state { return true }
        return false
    }
}

public struct FitnessStressDailyPoint: Identifiable, Equatable, Sendable {
    public enum State: Equatable, Sendable {
        case observed(value: Double)
        case zeroObserved
        case unavailable(reason: String)
    }

    public let id: String
    public let date: Date
    public let state: State

    public init(date: Date, state: State) {
        self.date = date
        self.id = String(Int(date.timeIntervalSince1970))
        switch state {
        case .observed(let value):
            self.state = value.isFinite ? state : .unavailable(reason: "Trend value is invalid.")
        case .zeroObserved:
            self.state = state
        case .unavailable(let reason):
            let clean = reason.trimmingCharacters(in: .whitespacesAndNewlines)
            self.state = .unavailable(reason: clean.isEmpty ? "No observation for this day." : clean)
        }
    }

    public var value: Double? {
        switch state {
        case .observed(let value): return value
        case .zeroObserved: return 0
        case .unavailable: return nil
        }
    }
}

public struct FitnessStressTrendWindow: Identifiable, Equatable, Sendable {
    public let id: String
    public let kind: FitnessStressSeriesKind
    public let range: FitnessTrendRange
    public let sourceWindow: String
    public let points: [FitnessStressDailyPoint]
    public let evidence: FitnessStressEvidence

    public init(
        kind: FitnessStressSeriesKind,
        range: FitnessTrendRange,
        sourceWindow: String,
        points: [FitnessStressDailyPoint],
        evidence: FitnessStressEvidence
    ) {
        self.kind = kind
        self.range = range
        self.id = "\(kind.rawValue)-\(range.rawValue)"
        self.sourceWindow = sourceWindow.trimmingCharacters(in: .whitespacesAndNewlines)
        self.points = points.sorted { $0.date < $1.date }
        self.evidence = evidence
    }

    public var isAvailable: Bool {
        !sourceWindow.isEmpty && !evidence.isUnavailable && points.contains(where: { $0.value != nil })
    }

    public var availableValues: [Double] { points.compactMap(\.value) }

    public var average: Double? {
        guard !availableValues.isEmpty else { return nil }
        return availableValues.reduce(0, +) / Double(availableValues.count)
    }

    public var change: Double? {
        let values = availableValues
        guard let first = values.first, let last = values.last, values.count > 1 else { return nil }
        return last - first
    }

    public var trendLabel: String? {
        guard let change else { return nil }
        if abs(change) < 0.01 { return "Flat" }
        return change > 0 ? "Rising" : "Falling"
    }
}

public struct FitnessStressDay: Identifiable, Equatable, Sendable {
    public let id: String
    public let date: Date
    public let stress: FitnessStressMetric
    public let averageHRV: FitnessStressMetric
    public let averageHeartRate: FitnessStressMetric
    public let coaching: FitnessStressCopy
    public let overall: FitnessStressSeries
    public let nonActivity: FitnessStressSeries
    public let sleep: FitnessStressSeries
    public let distribution: FitnessStressDistribution
    public let evidence: FitnessStressEvidence

    public init(
        date: Date,
        stress: FitnessStressMetric,
        averageHRV: FitnessStressMetric = .unavailable("Average HRV"),
        averageHeartRate: FitnessStressMetric = .unavailable("Average heart rate"),
        coaching: FitnessStressCopy = .unavailable("Source-authored coaching is unavailable."),
        overall: FitnessStressSeries = .unavailable(.overall),
        nonActivity: FitnessStressSeries = .unavailable(.nonActivity),
        sleep: FitnessStressSeries = .unavailable(.sleep),
        distribution: FitnessStressDistribution = .unavailable(),
        evidence: FitnessStressEvidence = .unavailable("No selected-day Stress evidence is available.")
    ) {
        self.id = String(Int(date.timeIntervalSince1970))
        self.date = date
        self.stress = stress
        self.averageHRV = averageHRV
        self.averageHeartRate = averageHeartRate
        self.coaching = coaching
        self.overall = overall
        self.nonActivity = nonActivity
        self.sleep = sleep
        self.distribution = distribution
        self.evidence = evidence
    }

    public static func unavailable(for date: Date) -> FitnessStressDay {
        FitnessStressDay(date: date, stress: .unavailable("Stress"))
    }

    public func series(for kind: FitnessStressSeriesKind) -> FitnessStressSeries {
        switch kind {
        case .overall: return overall
        case .nonActivity: return nonActivity
        case .sleep: return sleep
        }
    }
}

public struct FitnessStressSnapshot: Equatable, Sendable {
    public let days: [FitnessStressDay]
    public let coverage: [FitnessStressCoverageDay]
    public let trendWindows: [FitnessStressSeriesKind: [FitnessStressTrendWindow]]

    public init(
        days: [FitnessStressDay] = [],
        coverage: [FitnessStressCoverageDay] = [],
        trendWindows: [FitnessStressSeriesKind: [FitnessStressTrendWindow]] = [:]
    ) {
        self.days = days.sorted { $0.date < $1.date }
        self.coverage = coverage.sorted { $0.date < $1.date }
        self.trendWindows = trendWindows.mapValues { windows in
            windows.sorted { $0.range.rawValue < $1.range.rawValue }
        }
    }

    public static let unavailable = FitnessStressSnapshot()

    public func day(for date: Date, calendar: Calendar = .current) -> FitnessStressDay? {
        let components = calendar.dateComponents([.era, .year, .month, .day], from: date)
        return days.first {
            calendar.dateComponents([.era, .year, .month, .day], from: $0.date) == components
        }
    }

    public func windows(for kind: FitnessStressSeriesKind) -> [FitnessStressTrendWindow] {
        (trendWindows[kind] ?? []).filter(\.isAvailable)
    }

    public func window(for kind: FitnessStressSeriesKind, range: FitnessTrendRange) -> FitnessStressTrendWindow? {
        windows(for: kind).first { $0.range == range }
    }

    public func coverage(for date: Date, calendar: Calendar = .current) -> FitnessStressCoverageDay? {
        let components = calendar.dateComponents([.era, .year, .month, .day], from: date)
        return coverage.first {
            calendar.dateComponents([.era, .year, .month, .day], from: $0.date) == components
        }
    }

    public static var demo: FitnessStressSnapshot { demo(anchor: .now) }

    /// A visual fixture must be anchored to the date the surface is actually
    /// presenting. This keeps deterministic snapshot evidence populated while
    /// the normal demo launch follows today's selected date.
    public static func demo(anchor: Date) -> FitnessStressSnapshot {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Europe/Berlin")!
        let day = calendar.date(byAdding: .hour, value: 12, to: calendar.startOfDay(for: anchor))!
        let evidence = FitnessStressEvidence(state: .demo(
            source: "DEMO · NOT LIVE",
            device: "Visual fixture",
            window: "Selected day · explicit source window",
            freshness: "Fixture timestamp"
        ))
        let scale = FitnessStressScale(minimum: 0, maximum: 100, unit: "score", provenance: "Explicit source scale in visual fixture")
        let values: [Double] = [8, 5, 12, 6, 18, 15, 28, 34, 42, 50, 41, 57, 48, 69, 52, 81, 61, 36]
        let overallSamples = values.enumerated().compactMap { index, value in
            FitnessStressSample(
                id: "demo-overall-\(index)",
                timestamp: day.addingTimeInterval(Double(index) * 14 * 60),
                value: value
            )
        }
        let nonActivitySamples = values.enumerated().compactMap { index, value in
            FitnessStressSample(
                id: "demo-nonactivity-\(index)",
                timestamp: day.addingTimeInterval(Double(index) * 14 * 60),
                value: max(0, value - Double(index % 4) * 2)
            )
        }
        let thresholds = FitnessStressThresholdLabels(
            labels: [.low: "<30", .medium: "30–60", .high: ">60"],
            provenance: "Explicit source threshold labels · demo"
        )
        let distribution = FitnessStressDistribution(state: .demo(
            totalSeconds: 4 * 3_600 + 24 * 60,
            durations: [.low: 2 * 3_600, .medium: 1 * 3_600 + 48 * 60, .high: 36 * 60],
            labels: thresholds,
            provenance: "Explicit source bucket durations · DEMO · NOT LIVE"
        ))
        let stress = FitnessStressMetric(
            title: "Stress",
            value: 32,
            unit: "score",
            state: evidence.state,
            evidence: evidence,
            scale: scale
        )
        let averageHRV = FitnessStressMetric(
            title: "Average HRV",
            value: 52,
            unit: "ms",
            state: evidence.state,
            evidence: evidence
        )
        let averageHeartRate = FitnessStressMetric(
            title: "Average heart rate",
            value: 101,
            unit: "bpm",
            state: evidence.state,
            evidence: evidence
        )
        let coaching = FitnessStressCopy(state: .demo(
            text: "The source describes the selected observations as within its normal presentation band. LifeOS does not infer a cause or make a health claim.",
            window: "Selected day · explicit source window",
            provenance: "DEMO · NOT LIVE · source-authored copy fixture"
        ))
        let overall = FitnessStressSeries(kind: .overall, samples: overallSamples, evidence: evidence, scale: scale)
        let nonActivity = FitnessStressSeries(kind: .nonActivity, samples: nonActivitySamples, evidence: evidence, scale: scale)
        let daySnapshot = FitnessStressDay(
            date: day,
            stress: stress,
            averageHRV: averageHRV,
            averageHeartRate: averageHeartRate,
            coaching: coaching,
            overall: overall,
            nonActivity: nonActivity,
            sleep: .unavailable(.sleep),
            distribution: distribution,
            evidence: evidence
        )
        let dailyDates = (0..<7).compactMap { calendar.date(byAdding: .day, value: $0 - 6, to: day) }
        let trendValues: [Double?] = [29, 34, nil, 37, 35, 39, 32]
        let trendPoints = dailyDates.enumerated().map { index, date in
            if let value = trendValues[index] { return FitnessStressDailyPoint(date: date, state: .observed(value: value)) }
            return FitnessStressDailyPoint(date: date, state: .unavailable(reason: "No source observation for this day."))
        }
        let trend = FitnessStressTrendWindow(
            kind: .overall,
            range: .seven,
            sourceWindow: "Rolling 7-day source window ending on selected day",
            points: trendPoints,
            evidence: evidence
        )
        let nonActivityTrend = FitnessStressTrendWindow(
            kind: .nonActivity,
            range: .seven,
            sourceWindow: "Rolling 7-day non-activity source window ending on selected day",
            points: trendPoints.map { point in
                FitnessStressDailyPoint(date: point.date, state: point.value.map { .observed(value: max(0, $0 - 2)) } ?? .unavailable(reason: "No non-activity source observation for this day."))
            },
            evidence: evidence
        )
        let monthStart = calendar.dateInterval(of: .month, for: day)!.start
        let dayRange = calendar.range(of: .day, in: .month, for: day)!
        let selectedDayNumber = calendar.component(.day, from: day)
        let coverage = dayRange.compactMap { dayNumber -> FitnessStressCoverageDay? in
            guard let date = calendar.date(byAdding: .day, value: dayNumber - 1, to: monthStart) else { return nil }
            if dayNumber == selectedDayNumber { return FitnessStressCoverageDay(date: date, state: .observed(durationSeconds: distribution.totalObservedSeconds ?? 0)) }
            if dayNumber == selectedDayNumber + 1 { return FitnessStressCoverageDay(date: date, state: .zeroObserved) }
            return FitnessStressCoverageDay(date: date, state: .unavailable(reason: "No source observation for this day."))
        }
        return FitnessStressSnapshot(
            days: [daySnapshot],
            coverage: coverage,
            trendWindows: [.overall: [trend], .nonActivity: [nonActivityTrend]]
        )
    }
}

private extension FitnessStressMetric {
    var evidenceStateMatches: Bool {
        switch (state, evidence.state) {
        case (.unavailable, .unavailable), (.observed, .observed), (.stale, .stale), (.demo, .demo): return true
        default: return false
        }
    }
}
