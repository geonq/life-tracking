#if os(iOS)
import Foundation

/// A source selector for a projection.  Matching is deliberately exact: a
/// display name or a substring is never enough to turn a HealthKit sample
/// into Helio evidence.
public struct HealthKitFitnessSourceFilter: Equatable, Sendable {
    public enum Rule: Equatable, Sendable {
        case all
        case helioMatch(HealthKitSourceMatch)
        case sourceBundle(String)
        case device(manufacturer: String?, model: String?)
        case exact(bundleIdentifier: String, manufacturer: String?, model: String?)
    }

    public let rule: Rule

    public init(rule: Rule = .all) {
        self.rule = Self.normalized(rule)
    }

    public static let all = HealthKitFitnessSourceFilter()

    public static func helioMatch(_ match: HealthKitSourceMatch) -> Self {
        Self(rule: .helioMatch(match))
    }

    public static func sourceBundle(_ bundleIdentifier: String) -> Self {
        Self(rule: .sourceBundle(bundleIdentifier))
    }

    public static func device(manufacturer: String? = nil, model: String? = nil) -> Self {
        Self(rule: .device(manufacturer: manufacturer, model: model))
    }

    public static func exact(
        bundleIdentifier: String,
        manufacturer: String? = nil,
        model: String? = nil
    ) -> Self {
        Self(rule: .exact(bundleIdentifier: bundleIdentifier, manufacturer: manufacturer, model: model))
    }

    public func matches(_ provenance: HealthKitProvenance) -> Bool {
        switch rule {
        case .all:
            return true
        case .helioMatch(let match):
            return provenance.helioMatch == match
        case .sourceBundle(let bundleIdentifier):
            return provenance.source?.bundleIdentifier == bundleIdentifier
        case .device(let manufacturer, let model):
            guard let device = provenance.device else { return false }
            if let manufacturer, device.manufacturer != manufacturer { return false }
            if let model, device.model != model { return false }
            return manufacturer != nil || model != nil
        case .exact(let bundleIdentifier, let manufacturer, let model):
            guard provenance.source?.bundleIdentifier == bundleIdentifier else { return false }
            if let manufacturer, provenance.device?.manufacturer != manufacturer { return false }
            if let model, provenance.device?.model != model { return false }
            return true
        }
    }

    private static func normalized(_ rule: Rule) -> Rule {
        func clean(_ value: String) -> String { value.trimmingCharacters(in: .whitespacesAndNewlines) }
        func optional(_ value: String?) -> String? {
            guard let value else { return nil }
            let clean = clean(value)
            return clean.isEmpty ? nil : clean
        }

        switch rule {
        case .all, .helioMatch:
            return rule
        case .sourceBundle(let bundle):
            return .sourceBundle(clean(bundle))
        case .device(let manufacturer, let model):
            return .device(manufacturer: optional(manufacturer), model: optional(model))
        case .exact(let bundle, let manufacturer, let model):
            return .exact(bundleIdentifier: clean(bundle), manufacturer: optional(manufacturer), model: optional(model))
        }
    }
}

/// A quantity observation that remains tied to its persisted HealthKit
/// identity, canonical unit, interval, and provenance.  It is intentionally
/// not a `FitnessMetric`: the UI must decide how (or whether) to display it.
public struct HealthKitFitnessQuantitySample: Equatable, Identifiable, Sendable {
    public let metric: HealthKitMetricID
    public let identity: HealthKitSampleIdentity
    public let quantity: HealthKitQuantityValue
    public let startDate: Date
    public let endDate: Date
    public let provenance: HealthKitProvenance
    public let state: HealthKitMetricState

    public var id: String { identity.stableKey }
    public var unit: HealthKitCanonicalUnit { quantity.unit }

    fileprivate init(observation: HealthKitObservation, state: HealthKitMetricState) throws {
        guard case .quantity(let quantity) = observation.value else {
            throw HealthKitDomainError.invalidQuantity
        }
        self.metric = observation.metric
        self.identity = observation.identity
        self.quantity = quantity
        self.startDate = observation.startDate
        self.endDate = observation.endDate
        self.provenance = observation.provenance
        self.state = state
    }
}

/// The state and selected source observations for one HealthKit metric.
/// `latest` is nil when the selected window has no matching sample; it is
/// never replaced with zero, a target, or a derived score.
public struct HealthKitFitnessMetricProjection: Equatable, Sendable {
    public let metric: HealthKitMetricID
    public let persistedState: HealthKitMetricState
    public let state: HealthKitMetricState
    public let syncState: HealthKitSyncState
    public let reason: String?
    public let lastCommittedAt: Date?
    public let observations: [HealthKitFitnessQuantitySample]
    public let latest: HealthKitFitnessQuantitySample?
    public let tombstones: [HealthKitDeletionTombstone]
    public let conflicts: [HealthKitObservationConflict]
    public let sourceMatches: [HealthKitSourceMatch]

    public var canonicalUnit: HealthKitCanonicalUnit? { metric.canonicalUnit }
    public var value: HealthKitQuantityValue? { latest?.quantity }

    fileprivate init(
        metric: HealthKitMetricID,
        persistedState: HealthKitMetricState,
        state: HealthKitMetricState,
        syncState: HealthKitSyncState,
        reason: String?,
        lastCommittedAt: Date?,
        observations: [HealthKitFitnessQuantitySample],
        latest: HealthKitFitnessQuantitySample?,
        tombstones: [HealthKitDeletionTombstone],
        conflicts: [HealthKitObservationConflict],
        sourceMatches: [HealthKitSourceMatch]
    ) {
        self.metric = metric
        self.persistedState = persistedState
        self.state = state
        self.syncState = syncState
        self.reason = reason
        self.lastCommittedAt = lastCommittedAt
        self.observations = observations
        self.latest = latest
        self.tombstones = tombstones
        self.conflicts = conflicts
        self.sourceMatches = sourceMatches
    }
}

/// A day bucket contains only source quantity samples whose start belongs to
/// that day.  The interval is half-open (`start <= t < end`); a sample that
/// straddles midnight is not fractionally split because that would invent a
/// quantity the source did not provide.
public struct HealthKitFitnessDailyTotal: Equatable, Identifiable, Sendable {
    public let date: Date
    public let metric: HealthKitMetricID
    public let state: HealthKitMetricState
    public let persistedState: HealthKitMetricState
    public let syncState: HealthKitSyncState
    public let reason: String?
    public let total: HealthKitQuantityValue?
    public let samples: [HealthKitFitnessQuantitySample]
    public let conflicts: [HealthKitObservationConflict]
    public let provenance: [HealthKitProvenance]

    public var id: String {
        "\(metric.rawValue)|\(date.timeIntervalSinceReferenceDate)"
    }

    fileprivate init(
        date: Date,
        metric: HealthKitMetricID,
        state: HealthKitMetricState,
        persistedState: HealthKitMetricState,
        syncState: HealthKitSyncState,
        reason: String?,
        total: HealthKitQuantityValue?,
        samples: [HealthKitFitnessQuantitySample],
        conflicts: [HealthKitObservationConflict] = []
    ) {
        self.date = date
        self.metric = metric
        self.state = state
        self.persistedState = persistedState
        self.syncState = syncState
        self.reason = reason
        self.total = total
        self.samples = samples
        self.conflicts = conflicts
        self.provenance = samples.map(\.provenance)
    }
}

/// Sleep samples retain the source stage and source time zone.  LifeOS does
/// not collapse them into a sleep-quality score or infer a named night.
public struct HealthKitFitnessSleepSample: Equatable, Identifiable, Sendable {
    public let identity: HealthKitSampleIdentity
    public let stage: HealthKitSleepStage
    public let timeZoneIdentifier: String?
    public let startDate: Date
    public let endDate: Date
    public let provenance: HealthKitProvenance
    public let state: HealthKitMetricState

    public var id: String { identity.stableKey }

    fileprivate init(observation: HealthKitObservation, state: HealthKitMetricState) throws {
        guard case .sleep(let value) = observation.value else {
            throw HealthKitDomainError.invalidSleepStage
        }
        self.identity = observation.identity
        self.stage = value.stage
        self.timeZoneIdentifier = value.timeZoneIdentifier
        self.startDate = observation.startDate
        self.endDate = observation.endDate
        self.provenance = observation.provenance
        self.state = state
    }
}

/// Sleep projection exposes the enclosing interval of selected source
/// samples.  It is an interval boundary, not a claim that every second inside
/// it was asleep and not a proprietary sleep score.
public struct HealthKitFitnessSleepProjection: Equatable, Sendable {
    public let persistedState: HealthKitMetricState
    public let state: HealthKitMetricState
    public let syncState: HealthKitSyncState
    public let reason: String?
    public let startDate: Date?
    public let endDate: Date?
    public let samples: [HealthKitFitnessSleepSample]
    public let conflicts: [HealthKitObservationConflict]
    public let provenance: [HealthKitProvenance]

    public var interval: DateInterval? {
        guard let startDate, let endDate, endDate >= startDate else { return nil }
        return DateInterval(start: startDate, end: endDate)
    }

    fileprivate init(
        persistedState: HealthKitMetricState,
        state: HealthKitMetricState,
        syncState: HealthKitSyncState,
        reason: String?,
        startDate: Date?,
        endDate: Date?,
        samples: [HealthKitFitnessSleepSample],
        conflicts: [HealthKitObservationConflict] = []
    ) {
        self.persistedState = persistedState
        self.state = state
        self.syncState = syncState
        self.reason = reason
        self.startDate = startDate
        self.endDate = endDate
        self.samples = samples
        self.conflicts = conflicts
        self.provenance = samples.map(\.provenance)
    }
}

public enum HealthKitFitnessProjectionIssue: Equatable, Sendable {
    case invalidWindow
    case windowTooLarge
    case tooManyStates
    case oversizedState(HealthKitMetricID)
    case duplicateMetricState(HealthKitMetricID)
}

/// A workout record with its HealthKit activity type preserved as a raw value.
/// Mapping that value to a display label belongs to an iOS HealthKit adapter or
/// UI layer and must not be guessed in this projection.
public struct HealthKitFitnessWorkout: Equatable, Identifiable, Sendable {
    public let identity: HealthKitSampleIdentity
    public let activityTypeRawValue: Int
    public let durationSeconds: Double
    public let activeEnergyKilocalories: Double?
    public let startDate: Date
    public let endDate: Date
    public let provenance: HealthKitProvenance
    public let state: HealthKitMetricState

    public var id: String { identity.stableKey }

    fileprivate init(observation: HealthKitObservation, state: HealthKitMetricState) throws {
        guard case .workout(let value) = observation.value else {
            throw HealthKitDomainError.invalidWorkout
        }
        self.identity = observation.identity
        self.activityTypeRawValue = value.activityTypeRawValue
        self.durationSeconds = value.durationSeconds
        self.activeEnergyKilocalories = value.activeEnergyKilocalories
        self.startDate = observation.startDate
        self.endDate = observation.endDate
        self.provenance = observation.provenance
        self.state = state
    }
}

/// Pure, deterministic projection of persisted HealthKit state into typed
/// Fitness source data.  It contains no HealthKit queries, writes, SwiftUI,
/// score formula, target, recovery/strain/stress/energy inference, or direct
/// Helio-device claim.
public struct HealthKitFitnessProjection: Equatable, Sendable {
    public static let maximumWindow: TimeInterval = 366 * 24 * 60 * 60
    public static let latestMetricIDs: [HealthKitMetricID] = [
        .restingHeartRate,
        .heartRateVariabilitySDNN,
        .respiratoryRate,
        .oxygenSaturation,
        .bodyMass,
        .bodyFatPercentage,
        .leanBodyMass,
        .vo2Max
    ]

    public static let dailyTotalMetricIDs: [HealthKitMetricID] = [
        .steps,
        .activeEnergy,
        .water,
        .caffeine
    ]

    public static let defaultCalendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        return calendar
    }()

    public let windowStart: Date
    public let windowEnd: Date
    public let bucketCalendarIdentifier: Calendar.Identifier
    public let bucketTimeZoneIdentifier: String
    public let issues: [HealthKitFitnessProjectionIssue]
    public let metrics: [HealthKitMetricID: HealthKitFitnessMetricProjection]
    public let dailyTotals: [Date: [HealthKitMetricID: HealthKitFitnessDailyTotal]]
    public let sleep: HealthKitFitnessSleepProjection
    public let workouts: [HealthKitFitnessWorkout]
    public let sourceFilter: HealthKitFitnessSourceFilter

    public var isValid: Bool { issues.isEmpty }

    public var restingHeartRate: HealthKitFitnessMetricProjection { metric(.restingHeartRate) }
    public var hrv: HealthKitFitnessMetricProjection { metric(.heartRateVariabilitySDNN) }
    public var respiratoryRate: HealthKitFitnessMetricProjection { metric(.respiratoryRate) }
    public var oxygenSaturation: HealthKitFitnessMetricProjection { metric(.oxygenSaturation) }
    public var bodyMass: HealthKitFitnessMetricProjection { metric(.bodyMass) }
    public var bodyFatPercentage: HealthKitFitnessMetricProjection { metric(.bodyFatPercentage) }
    public var leanBodyMass: HealthKitFitnessMetricProjection { metric(.leanBodyMass) }
    public var vo2Max: HealthKitFitnessMetricProjection { metric(.vo2Max) }

    public init(
        states: [HealthKitStoredMetricState],
        window: DateInterval,
        sourceFilter: HealthKitFitnessSourceFilter = .all,
        calendar: Calendar = HealthKitFitnessProjection.defaultCalendar
    ) {
        self.windowStart = window.start
        self.windowEnd = window.end
        self.bucketCalendarIdentifier = calendar.identifier
        self.bucketTimeZoneIdentifier = calendar.timeZone.identifier
        self.sourceFilter = sourceFilter

        let shapeIssues = Self.inputIssues(states: states, window: window)
        let normalized = Self.normalizedStates(states)
        self.issues = shapeIssues + normalized.issues
        let canProject = shapeIssues.isEmpty
        let validWindow = canProject ? DateInterval(start: window.start, end: window.end) : nil
        let normalizedStates = canProject ? normalized.states : [:]
        let projectedMetricIDs = HealthKitMetricID.allCases.filter { $0 != .alcoholicBeverages }
        var metricMap: [HealthKitMetricID: HealthKitFitnessMetricProjection] = [:]

        for metric in projectedMetricIDs {
            if let duplicate = normalized.duplicateMetrics.first(where: { $0 == metric }) {
                metricMap[metric] = Self.invalidMetricProjection(metric: duplicate, reason: "Duplicate persisted HealthKit states disagree at the same commit time.")
            } else if let validWindow {
                let stored = normalizedStates[metric] ?? .empty(for: metric)
                metricMap[metric] = Self.metricProjection(stored: stored, window: validWindow, sourceFilter: sourceFilter)
            } else {
                metricMap[metric] = Self.invalidMetricProjection(metric: metric, reason: "HealthKit projection input is outside its bounded window contract.")
            }
        }
        self.metrics = metricMap

        var totals: [Date: [HealthKitMetricID: HealthKitFitnessDailyTotal]] = [:]
        let bucketCalendar = Self.bucketCalendar(identifier: calendar.identifier, timeZoneIdentifier: calendar.timeZone.identifier)
        let days = validWindow.map { Self.days(in: $0, calendar: bucketCalendar) } ?? []
        for metric in canProject ? Self.dailyTotalMetricIDs : [] {
            guard !normalized.duplicateMetrics.contains(metric) else { continue }
            let stored = normalizedStates[metric] ?? .empty(for: metric)
            let selected = Self.quantitySelection(
                from: stored,
                window: validWindow!,
                sourceFilter: sourceFilter,
                intervalSemantics: .startsInWindow
            )
            let selectedConflicts = Self.scopedConflicts(
                from: stored,
                window: validWindow!,
                sourceFilter: sourceFilter,
                intervalSemantics: .startsInWindow
            ) + selected.duplicateConflicts
            let grouped = Dictionary(grouping: selected.observations) { bucketCalendar.startOfDay(for: $0.startDate) }
            for day in days {
                let ordered = (grouped[day] ?? []).sorted(by: Self.observationOrder)
                // A conflicting revision can move a source sample across a
                // local-day boundary. Both affected days must fail closed;
                // assigning the conflict only to the retained/original day
                // would let the incoming quantity be counted on its new day.
                let dayDuplicateConflicts = selectedConflicts.filter {
                    bucketCalendar.startOfDay(for: $0.existing.startDate) == day ||
                        bucketCalendar.startOfDay(for: $0.incoming.startDate) == day
                }
                let persistedState = Self.scopedMetricState(stored: stored, selected: ordered, conflicts: dayDuplicateConflicts)
                let state = Self.effectiveState(
                    persistedState,
                    hasSelection: !ordered.isEmpty
                )
                let samples = ordered.compactMap { try? HealthKitFitnessQuantitySample(observation: $0, state: state) }
                let (total, aggregationReason) = Self.sum(samples, metric: metric, hasConflict: !dayDuplicateConflicts.isEmpty || Self.hasScopedSourceConflict(ordered))
                let daily = HealthKitFitnessDailyTotal(
                    date: day,
                    metric: metric,
                    state: state,
                    persistedState: persistedState,
                    syncState: stored.syncState,
                    reason: aggregationReason ?? Self.selectionReason(state: state, hasSelection: !ordered.isEmpty, sourceFilter: sourceFilter, kind: "quantity"),
                    total: total,
                    samples: samples,
                    conflicts: dayDuplicateConflicts
                )
                totals[day, default: [:]][metric] = daily
            }
        }
        self.dailyTotals = totals

        let sleepStored = normalizedStates[.sleep] ?? .empty(for: .sleep)
        self.sleep = validWindow.map { Self.sleepProjection(stored: sleepStored, window: $0, sourceFilter: sourceFilter) }
            ?? Self.invalidSleepProjection(reason: "HealthKit projection input is outside its bounded window contract.")

        let workoutStored = normalizedStates[.workout] ?? .empty(for: .workout)
        if let validWindow {
            let workoutCandidates = workoutStored.observations
                .filter { $0.metric == .workout && Self.overlaps($0, validWindow) && sourceFilter.matches($0.provenance) }
            let workoutSelection = Self.deduplicate(workoutCandidates, metric: .workout)
            let workoutConflicts = Self.scopedConflicts(from: workoutStored, window: validWindow, sourceFilter: sourceFilter, intervalSemantics: .overlapsWindow) + workoutSelection.duplicateConflicts
            let workoutState = Self.scopedMetricState(stored: workoutStored, selected: workoutSelection.observations, conflicts: workoutConflicts)
            let workoutHasConflict = !workoutConflicts.isEmpty || Self.hasScopedSourceConflict(workoutSelection.observations)
            self.workouts = workoutHasConflict ? [] : workoutSelection.observations
                .compactMap { try? HealthKitFitnessWorkout(observation: $0, state: workoutState) }
                .sorted(by: Self.workoutOrder)
        } else {
            self.workouts = []
        }
    }

    public func metric(_ metric: HealthKitMetricID) -> HealthKitFitnessMetricProjection {
        metrics[metric] ?? Self.emptyMetricProjection(for: metric)
    }

    public func dailyTotal(
        for metric: HealthKitMetricID,
        on date: Date
    ) -> HealthKitFitnessDailyTotal? {
        let calendar = Self.bucketCalendar(identifier: bucketCalendarIdentifier, timeZoneIdentifier: bucketTimeZoneIdentifier)
        return dailyTotals[calendar.startOfDay(for: date)]?[metric]
    }

    private enum IntervalSemantics { case startsInWindow, overlapsWindow }

    private struct NormalizedStates {
        let states: [HealthKitMetricID: HealthKitStoredMetricState]
        let duplicateMetrics: Set<HealthKitMetricID>
        let issues: [HealthKitFitnessProjectionIssue]
    }

    private struct QuantitySelection {
        let observations: [HealthKitObservation]
        let duplicateConflicts: [HealthKitObservationConflict]
    }

    private static func inputIssues(
        states: [HealthKitStoredMetricState],
        window: DateInterval
    ) -> [HealthKitFitnessProjectionIssue] {
        var issues: [HealthKitFitnessProjectionIssue] = []
        let finite = window.start.timeIntervalSinceReferenceDate.isFinite &&
            window.end.timeIntervalSinceReferenceDate.isFinite
        guard finite, window.end > window.start else {
            issues.append(.invalidWindow)
            return issues
        }
        if window.duration > maximumWindow { issues.append(.windowTooLarge) }
        if states.count > HealthKitMetricID.allCases.count { issues.append(.tooManyStates) }
        for state in states where state.observations.count > HealthKitSafetyLimits.maxProjectionItems ||
            state.tombstones.count > HealthKitSafetyLimits.maxProjectionItems ||
            state.conflicts.count > HealthKitSafetyLimits.maxConflictItems {
            issues.append(.oversizedState(state.metric))
        }
        return issues
    }

    private static func normalizedStates(_ states: [HealthKitStoredMetricState]) -> NormalizedStates {
        var result: [HealthKitMetricID: HealthKitStoredMetricState] = [:]
        var blocked = Set<HealthKitMetricID>()
        var issues: [HealthKitFitnessProjectionIssue] = []
        for state in states where state.metric != .alcoholicBeverages {
            guard !blocked.contains(state.metric) else { continue }
            guard let current = result[state.metric] else {
                result[state.metric] = state
                continue
            }
            let currentDate = current.lastCommittedAt ?? .distantPast
            let candidateDate = state.lastCommittedAt ?? .distantPast
            if state == current { continue }
            if candidateDate > currentDate {
                result[state.metric] = state
            } else if candidateDate == currentDate {
                result.removeValue(forKey: state.metric)
                blocked.insert(state.metric)
                issues.append(.duplicateMetricState(state.metric))
            }
        }
        return NormalizedStates(states: result, duplicateMetrics: blocked, issues: issues)
    }

    private static func metricProjection(
        stored: HealthKitStoredMetricState,
        window: DateInterval,
        sourceFilter: HealthKitFitnessSourceFilter
    ) -> HealthKitFitnessMetricProjection {
        let selected = quantitySelection(from: stored, window: window, sourceFilter: sourceFilter, intervalSemantics: .startsInWindow)
        let ordered = selected.observations.sorted(by: observationOrder)
        let scopedConflicts = scopedConflicts(
            from: stored,
            window: window,
            sourceFilter: sourceFilter,
            intervalSemantics: .startsInWindow
        ) + selected.duplicateConflicts
        // For an unfiltered projection, `persistedState` deliberately describes
        // the complete durable metric inventory while `state` describes only
        // the selected window. A source-filtered projection cannot expose that
        // broader inventory because doing so would leak an excluded source's
        // conflict state.
        let scopedState = scopedMetricState(stored: stored, selected: ordered, conflicts: scopedConflicts)
        let persistedState = sourceFilter == .all ? metricState(for: stored) : scopedState
        let state = effectiveState(scopedState, hasSelection: !ordered.isEmpty)
        let samples = ordered.compactMap { try? HealthKitFitnessQuantitySample(observation: $0, state: state) }
        let latest = scopedConflicts.isEmpty ? samples.last : nil
        let reason = scopedConflicts.isEmpty
            ? selectionReason(state: state, hasSelection: !ordered.isEmpty, sourceFilter: sourceFilter, kind: "observation")
            : "Selected HealthKit observations contain a source conflict."
        return HealthKitFitnessMetricProjection(
            metric: stored.metric,
            persistedState: persistedState,
            state: state,
            syncState: stored.syncState,
            reason: reason,
            lastCommittedAt: stored.lastCommittedAt,
            observations: samples,
            latest: latest,
            tombstones: sourceFilter == .all ? stored.tombstones : [],
            conflicts: scopedConflicts,
            sourceMatches: Self.sourceMatches(observations: samples)
        )
    }

    private static func emptyMetricProjection(for metric: HealthKitMetricID) -> HealthKitFitnessMetricProjection {
        HealthKitFitnessMetricProjection(
            metric: metric,
            persistedState: .unavailable,
            state: .unavailable,
            syncState: .neverSynced,
            reason: "No persisted HealthKit state is available.",
            lastCommittedAt: nil,
            observations: [],
            latest: nil,
            tombstones: [],
            conflicts: [],
            sourceMatches: []
        )
    }

    private static func invalidMetricProjection(metric: HealthKitMetricID, reason: String) -> HealthKitFitnessMetricProjection {
        HealthKitFitnessMetricProjection(
            metric: metric,
            persistedState: .error,
            state: .error,
            syncState: .error,
            reason: reason,
            lastCommittedAt: nil,
            observations: [],
            latest: nil,
            tombstones: [],
            conflicts: [],
            sourceMatches: []
        )
    }

    private static func invalidSleepProjection(reason: String) -> HealthKitFitnessSleepProjection {
        HealthKitFitnessSleepProjection(
            persistedState: .error,
            state: .error,
            syncState: .error,
            reason: reason,
            startDate: nil,
            endDate: nil,
            samples: [],
            conflicts: []
        )
    }

    /// Complete durable metric state. This is exposed only by an unfiltered
    /// projection; filtered projections use `scopedMetricState` so excluded
    /// source conflicts cannot leak into their result.
    private static func metricState(for stored: HealthKitStoredMetricState) -> HealthKitMetricState {
        if !stored.conflicts.isEmpty || stored.sourceIndex.values.contains(.conflict) {
            return .conflict
        }
        switch stored.syncState {
        case .neverSynced:
            return .unavailable
        case .syncing, .partial:
            return .partial
        case .synced:
            return stored.observations.isEmpty ? .unavailable : .observed
        case .readIndeterminate:
            return .readIndeterminate
        case .stale:
            return .stale
        case .conflict:
            return .conflict
        case .fullResyncRequired, .error:
            return .error
        }
    }

    private static func scopedMetricState(
        stored: HealthKitStoredMetricState,
        selected: [HealthKitObservation],
        conflicts: [HealthKitObservationConflict]
    ) -> HealthKitMetricState {
        if !conflicts.isEmpty || hasScopedSourceConflict(selected) { return .conflict }
        switch stored.syncState {
        case .neverSynced:
            return .unavailable
        case .syncing, .partial:
            return .partial
        case .synced:
            return selected.isEmpty ? .unavailable : .observed
        case .readIndeterminate:
            return .readIndeterminate
        case .stale:
            return .stale
        case .conflict:
            // A conflict outside the selected source/window is not allowed to
            // poison this scoped projection. The unfiltered durable state is
            // still available through the store for an operator to inspect.
            return selected.isEmpty ? .unavailable : .observed
        case .fullResyncRequired, .error:
            return .error
        }
    }

    private static func effectiveState(_ persistedState: HealthKitMetricState, hasSelection: Bool) -> HealthKitMetricState {
        guard !hasSelection else { return persistedState }
        return persistedState == .observed ? .unavailable : persistedState
    }

    private static func selectionReason(
        state: HealthKitMetricState,
        hasSelection: Bool,
        sourceFilter: HealthKitFitnessSourceFilter,
        kind: String
    ) -> String? {
        guard !hasSelection else { return nil }
        switch state {
        case .unavailable:
            return sourceFilter == .all
                ? "No \(kind) falls in the selected window."
                : "No \(kind) matches the requested source filter in the selected window."
        case .permissionRequired:
            return "HealthKit permission is required."
        case .readIndeterminate:
            return "HealthKit read access is indeterminate; an empty read is not proof of no data."
        case .partial:
            return "Persisted HealthKit observations are partial."
        case .stale:
            return "Persisted HealthKit observations are stale."
        case .conflict:
            return "Persisted HealthKit observations contain a source conflict."
        case .error:
            return "Persisted HealthKit state requires recovery before it can be treated as current."
        case .observed:
            return nil
        }
    }

    private static func quantitySelection(
        from stored: HealthKitStoredMetricState,
        window: DateInterval,
        sourceFilter: HealthKitFitnessSourceFilter,
        intervalSemantics: IntervalSemantics
    ) -> QuantitySelection {
        let candidates = stored.observations.filter { observation in
            guard observation.metric == stored.metric,
                  sourceFilter.matches(observation.provenance) else { return false }
            switch intervalSemantics {
            case .startsInWindow:
                guard observation.startDate >= window.start && observation.startDate < window.end else { return false }
            case .overlapsWindow:
                guard overlaps(observation, window) else { return false }
            }
            return true
        }
        return deduplicate(candidates, metric: stored.metric)
    }

    private static func deduplicate(
        _ candidates: [HealthKitObservation],
        metric: HealthKitMetricID
    ) -> QuantitySelection {
        var retained: [HealthKitObservation] = []
        var duplicateConflicts: [HealthKitObservationConflict] = []
        var conflictKeys = Set<String>()
        for candidate in candidates.sorted(by: observationOrder) {
            guard let existingIndex = retained.firstIndex(where: { $0.identity.matchesStableIdentity(candidate.identity) }) else {
                retained.append(candidate)
                continue
            }
            let existing = retained[existingIndex]
            if existing == candidate { continue }
            let key = existing.identity.stableKey
            if !conflictKeys.contains(key) {
                duplicateConflicts.append(HealthKitObservationConflict(
                    metric: metric,
                    identity: existing.identity,
                    existing: existing,
                    incoming: candidate
                ))
                conflictKeys.insert(key)
            }
            if !retained.contains(candidate) { retained.append(candidate) }
        }
        return QuantitySelection(observations: retained, duplicateConflicts: duplicateConflicts)
    }

    private static func scopedConflicts(
        from stored: HealthKitStoredMetricState,
        window: DateInterval,
        sourceFilter: HealthKitFitnessSourceFilter,
        intervalSemantics: IntervalSemantics
    ) -> [HealthKitObservationConflict] {
        stored.conflicts.filter { conflict in
            guard conflict.metric == stored.metric,
                  conflict.existing.metric == stored.metric,
                  conflict.incoming.metric == stored.metric,
                  sourceFilter.matches(conflict.existing.provenance),
                  sourceFilter.matches(conflict.incoming.provenance) else { return false }
            switch intervalSemantics {
            case .startsInWindow:
                // A revision can move a stable-identity observation across
                // the projection boundary. If either side is selected, the
                // selected result must remain conflicted rather than accepting
                // the in-window side as uncontested truth.
                return (conflict.existing.startDate >= window.start && conflict.existing.startDate < window.end) ||
                    (conflict.incoming.startDate >= window.start && conflict.incoming.startDate < window.end)
            case .overlapsWindow:
                return overlaps(conflict.existing, window) || overlaps(conflict.incoming, window)
            }
        }
    }

    private static func hasScopedSourceConflict(_ observations: [HealthKitObservation]) -> Bool {
        let grouped = Dictionary(grouping: observations) { HealthKitSourceIndexKey.make(for: $0.provenance) }
        return grouped.values.contains { Set($0.map { $0.provenance.helioMatch }).count > 1 }
    }

    private static func sleepProjection(
        stored: HealthKitStoredMetricState,
        window: DateInterval,
        sourceFilter: HealthKitFitnessSourceFilter
    ) -> HealthKitFitnessSleepProjection {
        let candidates = stored.observations
            .filter { $0.metric == .sleep && overlaps($0, window) && sourceFilter.matches($0.provenance) }
        let selection = deduplicate(candidates, metric: .sleep)
        let scopedConflicts = scopedConflicts(from: stored, window: window, sourceFilter: sourceFilter, intervalSemantics: .overlapsWindow) + selection.duplicateConflicts
        let persistedState = scopedMetricState(stored: stored, selected: selection.observations, conflicts: scopedConflicts)
        let state = effectiveState(persistedState, hasSelection: !selection.observations.isEmpty)
        let selected = selection.observations
            .compactMap { try? HealthKitFitnessSleepSample(observation: $0, state: state) }
            .sorted { lhs, rhs in
                if lhs.startDate != rhs.startDate { return lhs.startDate < rhs.startDate }
                if lhs.endDate != rhs.endDate { return lhs.endDate < rhs.endDate }
                return lhs.id < rhs.id
            }
        let reason = scopedConflicts.isEmpty
            ? selectionReason(state: state, hasSelection: !selected.isEmpty, sourceFilter: sourceFilter, kind: "sleep sample")
            : "Selected HealthKit sleep observations contain a source conflict."
        return HealthKitFitnessSleepProjection(
            persistedState: persistedState,
            state: state,
            syncState: stored.syncState,
            reason: reason,
            startDate: selected.map(\.startDate).min(),
            endDate: selected.map(\.endDate).max(),
            samples: selected,
            conflicts: scopedConflicts
        )
    }

    private static func sourceMatches(observations: [HealthKitFitnessQuantitySample]) -> [HealthKitSourceMatch] {
        let matches = observations.map(\.provenance.helioMatch)
        return Array(Set(matches.map(\.rawValue))).compactMap(HealthKitSourceMatch.init(rawValue:)).sorted { $0.rawValue < $1.rawValue }
    }

    private static func sum(
        _ samples: [HealthKitFitnessQuantitySample],
        metric: HealthKitMetricID,
        hasConflict: Bool = false
    ) -> (HealthKitQuantityValue?, String?) {
        guard !samples.isEmpty else { return (nil, nil) }
        guard !hasConflict else { return (nil, "Selected HealthKit observations conflict and cannot be aggregated.") }
        guard let unit = metric.canonicalUnit else {
            return (nil, "The metric has no canonical quantity unit.")
        }
        var value = 0.0
        for sample in samples {
            guard sample.quantity.metric == metric, sample.quantity.unit == unit else {
                return (nil, "Source quantity units do not match the canonical metric unit.")
            }
            value += sample.quantity.value
            guard value.isFinite, value <= HealthKitSafetyLimits.maxQuantityValue else {
                return (nil, "The source total exceeds the bounded HealthKit quantity limit.")
            }
        }
        return (try? HealthKitQuantityValue(metric: metric, value: value, unit: unit), nil)
    }

    private static func days(in window: DateInterval, calendar: Calendar) -> [Date] {
        guard window.end > window.start else { return [] }
        var result: [Date] = []
        var cursor = calendar.startOfDay(for: window.start)
        while cursor < window.end && result.count < HealthKitSafetyLimits.maxProjectionItems {
            result.append(cursor)
            guard let next = calendar.date(byAdding: .day, value: 1, to: cursor), next > cursor else { break }
            cursor = next
        }
        return result
    }

    private static func bucketCalendar(
        identifier: Calendar.Identifier,
        timeZoneIdentifier: String
    ) -> Calendar {
        var calendar = Calendar(identifier: identifier)
        calendar.timeZone = TimeZone(identifier: timeZoneIdentifier) ?? TimeZone(secondsFromGMT: 0)!
        return calendar
    }

    private static func overlaps(_ observation: HealthKitObservation, _ window: DateInterval) -> Bool {
        if observation.startDate == observation.endDate {
            return observation.startDate >= window.start && observation.startDate < window.end
        }
        return observation.startDate < window.end && observation.endDate > window.start
    }

    private static func observationOrder(_ lhs: HealthKitObservation, _ rhs: HealthKitObservation) -> Bool {
        if lhs.endDate != rhs.endDate { return lhs.endDate < rhs.endDate }
        if lhs.startDate != rhs.startDate { return lhs.startDate < rhs.startDate }
        return lhs.identity.stableKey < rhs.identity.stableKey
    }

    private static func workoutOrder(_ lhs: HealthKitFitnessWorkout, _ rhs: HealthKitFitnessWorkout) -> Bool {
        if lhs.startDate != rhs.startDate { return lhs.startDate < rhs.startDate }
        if lhs.endDate != rhs.endDate { return lhs.endDate < rhs.endDate }
        return lhs.id < rhs.id
    }
}
#endif
