#if os(iOS)
import Foundation

/// The source state exposed by the HealthKit-to-Fitness composition boundary.
///
/// `FitnessSourceState.Status` predates the HealthKit reconciliation contract
/// and cannot distinguish partial, conflict, indeterminate, and error states.
/// This app-only state is therefore kept beside the composed snapshot instead
/// of collapsing those states into a generic "connected" label.
public enum HealthKitFitnessCompositionSourceState: String, CaseIterable, Equatable, Sendable {
    case unavailable
    case permissionRequired = "permission_required"
    case observed
    case partial
    case stale
    case conflict
    case readIndeterminate = "read_indeterminate"
    case error

    public var label: String {
        switch self {
        case .unavailable: "Unavailable"
        case .permissionRequired: "Permission state required"
        case .observed: "Observed"
        case .partial: "Partial"
        case .stale: "Stale"
        case .conflict: "Conflict"
        case .readIndeterminate: "Read access indeterminate"
        case .error: "Error"
        }
    }

    fileprivate init(_ state: HealthKitMetricState) {
        switch state {
        case .unavailable: self = .unavailable
        case .permissionRequired: self = .permissionRequired
        case .readIndeterminate: self = .readIndeterminate
        case .observed: self = .observed
        case .partial: self = .partial
        case .stale: self = .stale
        case .conflict: self = .conflict
        case .error: self = .error
        }
    }
}

/// Short alias for callers that want to keep the source state name local to a
/// HealthKit composition call site.
public typealias HealthKitFitnessSourceState = HealthKitFitnessCompositionSourceState

/// Evidence carried alongside one composed source field.  The strings are
/// deliberately presentation-ready because `FitnessMetric` has no separate
/// provenance storage.  `sourceMatches` preserves the reviewed Helio match
/// result without turning a source name into a device claim.
public struct HealthKitFitnessCompositionEvidence: Equatable, Sendable {
    public let state: HealthKitFitnessCompositionSourceState
    public let source: String
    public let device: String
    public let provenance: String
    public let window: String
    public let freshness: String
    public let sourceMatches: [HealthKitSourceMatch]

    public init(
        state: HealthKitFitnessCompositionSourceState,
        source: String,
        device: String,
        provenance: String,
        window: String,
        freshness: String,
        sourceMatches: [HealthKitSourceMatch] = []
    ) {
        self.state = state
        self.source = source
        self.device = device
        self.provenance = provenance
        self.window = window
        self.freshness = freshness
        self.sourceMatches = sourceMatches
    }

    public var summary: String {
        "\(state.label) · \(source) · \(device) · \(window) · \(freshness) · \(provenance)"
    }
}

/// Pure app-only composition of a bounded HealthKit projection into the
/// existing Fitness snapshot contract.
///
/// This type performs no HealthKit query, store access, write, network call,
/// score calculation, baseline calculation, target calculation, or Helio
/// inference.  The caller owns the retained `HealthKitAnchorStore` snapshot
/// and supplies an already accepted `HealthKitFitnessProjection`.
public struct HealthKitFitnessComposition {
    public typealias SourceState = HealthKitFitnessCompositionSourceState

    public let snapshot: FitnessSnapshot
    public let sourceState: SourceState
    public let metricStates: [HealthKitMetricID: SourceState]
    public let sleepState: SourceState
    public let workoutState: SourceState
    public let evidence: [HealthKitMetricID: HealthKitFitnessCompositionEvidence]
    public let selectedDate: Date
    public let projectionWindow: DateInterval
    public let calendarIdentifier: Calendar.Identifier
    public let timeZoneIdentifier: String

    public init(
        projection: HealthKitFitnessProjection,
        selectedDate: Date
    ) {
        let built = Self.build(projection: projection, selectedDate: selectedDate)
        self.snapshot = built.snapshot
        self.sourceState = built.sourceState
        self.metricStates = built.metricStates
        self.sleepState = built.sleepState
        self.workoutState = built.workoutState
        self.evidence = built.evidence
        self.selectedDate = selectedDate
        self.projectionWindow = built.projectionWindow
        self.calendarIdentifier = projection.bucketCalendarIdentifier
        self.timeZoneIdentifier = projection.bucketTimeZoneIdentifier
    }

    /// Named constructor for call sites that prefer a verb over an init.
    public static func compose(
        projection: HealthKitFitnessProjection,
        selectedDate: Date
    ) -> Self {
        Self(projection: projection, selectedDate: selectedDate)
    }

    /// Convenience for the eventual view/root seam.  It intentionally does
    /// not retain or query a store and returns only the existing snapshot.
    public static func snapshot(
        from projection: HealthKitFitnessProjection,
        selectedDate: Date
    ) -> FitnessSnapshot {
        Self(projection: projection, selectedDate: selectedDate).snapshot
    }

    /// Equivalent spelling kept explicit for callers that want to avoid a
    /// method/property name collision at the call site.
    public static func makeSnapshot(
        projection: HealthKitFitnessProjection,
        selectedDate: Date
    ) -> FitnessSnapshot {
        Self(projection: projection, selectedDate: selectedDate).snapshot
    }

    private struct BuildResult {
        let snapshot: FitnessSnapshot
        let sourceState: SourceState
        let metricStates: [HealthKitMetricID: SourceState]
        let sleepState: SourceState
        let workoutState: SourceState
        let evidence: [HealthKitMetricID: HealthKitFitnessCompositionEvidence]
        let projectionWindow: DateInterval
    }

    private struct MetricMapping {
        let metricID: HealthKitMetricID
        let metric: FitnessMetric
        let state: SourceState
        let evidence: HealthKitFitnessCompositionEvidence
    }

    /// Sleep is retained for the bounded projection window, but Fitness shows
    /// one local calendar day at a time.  Keep the selected result together so
    /// every downstream field (state, evidence, detail, and aggregate
    /// provenance/freshness) uses the same end-date bucket.
    private struct SelectedSleep {
        let samples: [HealthKitFitnessSleepSample]
        let conflicts: [HealthKitObservationConflict]
        let state: SourceState
        let reason: String?
        let start: Date?
        let end: Date?
        let provenance: [HealthKitProvenance]
    }

    private static let latestMetricIDs: [HealthKitMetricID] = [
        .restingHeartRate,
        .heartRateVariabilitySDNN,
        .respiratoryRate,
        .oxygenSaturation,
        .bodyMass,
        .bodyFatPercentage,
        .leanBodyMass,
        .vo2Max
    ]

    private static let dailyMetricIDs: [HealthKitMetricID] = [.steps, .activeEnergy]

    private static func build(
        projection: HealthKitFitnessProjection,
        selectedDate: Date
    ) -> BuildResult {
        let calendar = retainedCalendar(for: projection)
        let projectionWindow = safeProjectionWindow(for: projection)
        let windowDescription = describeProjectionWindow(projection, calendar: calendar)
        let selectedDayDescription = describeSelectedDay(selectedDate, calendar: calendar)
        let selectedDateIsFinite = selectedDate.timeIntervalSinceReferenceDate.isFinite
        let selectedSleep = selectSleep(
            projection.sleep,
            selectedDate: selectedDate,
            selectedDateIsFinite: selectedDateIsFinite,
            calendar: calendar
        )
        let aggregateFreshness = aggregateFreshnessDescription(
            projection: projection,
            selectedDate: selectedDate,
            selectedSleep: selectedSleep,
            calendar: calendar
        )

        var metricStates: [HealthKitMetricID: SourceState] = [:]
        var evidence: [HealthKitMetricID: HealthKitFitnessCompositionEvidence] = [:]

        func latestMapping(
            _ metricID: HealthKitMetricID,
            title: String,
            unit: String,
            hue: LifeOSTokens.Hue
        ) -> MetricMapping {
            let projectionMetric = projection.metric(metricID)
            let state = SourceState(projectionMetric.state)
            let provenance = projectionMetric.latest.map { [$0.provenance] } ?? projectionMetric.observations.map(\.provenance)
            let fieldEvidence = makeEvidence(
                state: state,
                provenances: provenance,
                window: windowDescription,
                freshness: latestMetricFreshness(projectionMetric, calendar: calendar)
            )
            let detail = metricDetail(
                state: state,
                evidence: fieldEvidence,
                reason: projectionMetric.reason
            )
            guard selectedValueIsDisplayable(state),
                  let value = projectionMetric.value,
                  value.metric == metricID else {
                return MetricMapping(
                    metricID: metricID,
                    metric: unavailableMetric(title: title, unit: unit, detail: detail, hue: hue, id: metricID.rawValue),
                    state: state,
                    evidence: fieldEvidence
                )
            }
            return MetricMapping(
                metricID: metricID,
                metric: FitnessMetric(
                    id: metricID.rawValue,
                    title: title,
                    value: formatNumber(value.value),
                    unit: unit,
                    detail: detail,
                    quality: .observed,
                    hue: hue
                ),
                state: state,
                evidence: fieldEvidence
            )
        }

        let restingHeartRate = latestMapping(.restingHeartRate, title: "Resting heart rate", unit: "bpm", hue: .pink)
        let hrv = latestMapping(.heartRateVariabilitySDNN, title: "HRV", unit: "ms", hue: .teal)
        let respiration = latestMapping(.respiratoryRate, title: "Respiration", unit: "/min", hue: .blue)
        let oxygen = latestMapping(.oxygenSaturation, title: "Blood oxygen", unit: "%", hue: .green)
        let bodyMass = latestMapping(.bodyMass, title: "Weight", unit: "kg", hue: .blue)
        let bodyFat = latestMapping(.bodyFatPercentage, title: "Body fat", unit: "%", hue: .pink)
        let leanBodyMass = latestMapping(.leanBodyMass, title: "Lean mass", unit: "kg", hue: .teal)
        let vo2Max = latestMapping(.vo2Max, title: "VO₂ max", unit: "ml/kg/min", hue: .green)

        for mapping in [restingHeartRate, hrv, respiration, oxygen, bodyMass, bodyFat, leanBodyMass, vo2Max] {
            metricStates[mapping.metricID] = mapping.state
            evidence[mapping.metricID] = mapping.evidence
        }

        let dailySteps = dailyMapping(
            projection: projection,
            metricID: .steps,
            title: "Steps",
            unit: "",
            hue: .teal,
            selectedDate: selectedDate,
            selectedDateIsFinite: selectedDateIsFinite,
            selectedDayDescription: selectedDayDescription,
            windowDescription: windowDescription
        )
        let dailyEnergy = dailyMapping(
            projection: projection,
            metricID: .activeEnergy,
            title: "Total energy",
            unit: "kcal",
            hue: .orange,
            selectedDate: selectedDate,
            selectedDateIsFinite: selectedDateIsFinite,
            selectedDayDescription: selectedDayDescription,
            windowDescription: windowDescription
        )
        metricStates[.steps] = dailySteps.state
        metricStates[.activeEnergy] = dailyEnergy.state
        evidence[.steps] = dailySteps.evidence
        evidence[.activeEnergy] = dailyEnergy.evidence

        let sleepState = selectedSleep.state
        let sleepEvidence = makeEvidence(
            state: sleepState,
            provenances: selectedSleep.provenance,
            window: selectedDayDescription + " · " + windowDescription,
            freshness: sleepFreshness(selectedSleep, calendar: calendar)
        )
        evidence[.sleep] = sleepEvidence
        metricStates[.sleep] = sleepState

        let selectedWorkouts = selectedWorkouts(
            projection.workouts,
            selectedDate: selectedDate,
            selectedDateIsFinite: selectedDateIsFinite,
            calendar: calendar
        )
        let workoutState: SourceState = selectedWorkouts.isEmpty
            ? .unavailable
            : aggregateState(selectedWorkouts.map { SourceState($0.state) })
        metricStates[.workout] = workoutState
        evidence[.workout] = makeEvidence(
            state: workoutState,
            provenances: selectedWorkouts.map(\.provenance),
            window: selectedDayDescription + " · " + windowDescription,
            freshness: workoutFreshness(selectedWorkouts, calendar: calendar)
        )

        let aggregateStates = Array(metricStates.values) + [sleepState, workoutState]
        let sourceState: SourceState = projection.issues.isEmpty
            ? aggregateState(aggregateStates)
            : .error

        let sourceEvidence = makeEvidence(
            state: sourceState,
            provenances: aggregateProvenances(
                projection: projection,
                selectedDate: selectedDate,
                selectedDateIsFinite: selectedDateIsFinite,
                selectedSleep: selectedSleep,
                calendar: calendar
            ),
            window: windowDescription + " · " + selectedDayDescription,
            freshness: aggregateFreshness
        )
        let source = FitnessSourceState(
            status: fitnessSourceStatus(for: sourceState),
            title: "HealthKit fitness source · \(sourceState.label)",
            detail: sourceEvidence.summary,
            freshness: aggregateFreshness
        )

        let unsupportedSkinTemperature = unavailableMetric(
            title: "Skin temperature",
            unit: "°C",
            detail: "Unavailable · no supported HealthKit fitness mapping in this composition.",
            hue: .orange,
            id: "skin_temperature"
        )
        let unsupportedSleep = unavailableMetric(
            title: "Sleep",
            unit: "",
            detail: "Unavailable · source sleep quality is not calculated by LifeOS.",
            hue: .violet,
            id: "sleep"
        )
        let unsupportedBaseline = unavailableMetric(
            title: "HRV baseline",
            unit: "ms",
            detail: "Unavailable · LifeOS does not calculate a baseline in this composition.",
            hue: .teal,
            id: "hrv_baseline"
        )

        let healthMonitor = [
            hrv.metric,
            restingHeartRate.metric,
            respiration.metric,
            oxygen.metric,
            unsupportedSkinTemperature,
            unsupportedSleep
        ]
        let bodyMetrics = [
            bodyMass.metric,
            bodyFat.metric,
            leanBodyMass.metric,
            vo2Max.metric,
            unsupportedBaseline
        ]

        let biology = makeBiologySnapshot(
            projection: projection,
            evidence: evidence
        )

        let sleepDetail = makeSleepDetail(
            selected: selectedSleep,
            evidence: sleepEvidence,
            timeZoneIdentifier: projection.bucketTimeZoneIdentifier
        )
        let workoutFacts: [FitnessWorkout] = workoutState == .observed
            ? selectedWorkouts.map { makeWorkout($0, state: workoutState, evidence: evidence[.workout]!) }
            : []

        let loadDetail = makeLoadDetail(
            dailySteps: dailySteps,
            dailyEnergy: dailyEnergy
        )

        let snapshot = FitnessSnapshot(
            source: source,
            readiness: .unavailable("Readiness"),
            strain: .unavailable("Strain"),
            sleep: unsupportedSleep,
            stress: .unavailable("Stress"),
            energyReserve: .unavailable("Energy reserve"),
            healthMonitor: healthMonitor,
            bodyMetrics: bodyMetrics,
            workouts: workoutFacts,
            activity: .unavailable,
            biology: biology,
            loadDetail: loadDetail,
            sleepDetail: sleepDetail,
            stressDetail: .unavailable
        )

        return BuildResult(
            snapshot: snapshot,
            sourceState: sourceState,
            metricStates: metricStates,
            sleepState: sleepState,
            workoutState: workoutState,
            evidence: evidence,
            projectionWindow: projectionWindow
        )
    }

    private static func dailyMapping(
        projection: HealthKitFitnessProjection,
        metricID: HealthKitMetricID,
        title: String,
        unit: String,
        hue: LifeOSTokens.Hue,
        selectedDate: Date,
        selectedDateIsFinite: Bool,
        selectedDayDescription: String,
        windowDescription: String
    ) -> MetricMapping {
        let daily = selectedDateIsFinite ? projection.dailyTotal(for: metricID, on: selectedDate) : nil
        let state = daily.map { SourceState($0.state) } ?? .unavailable
        let provenances = daily?.provenance ?? []
        let fieldEvidence = makeEvidence(
            state: state,
            provenances: provenances,
            window: selectedDayDescription + " · " + windowDescription,
            freshness: dailyFreshness(daily, calendar: retainedCalendar(for: projection))
        )
        let reason = daily?.reason ?? "No selected-day \(title.lowercased()) source observation is available."
        let detail = metricDetail(state: state, evidence: fieldEvidence, reason: reason)
        guard selectedValueIsDisplayable(state),
              let value = daily?.total,
              value.metric == metricID else {
            return MetricMapping(
                metricID: metricID,
                metric: unavailableMetric(title: title, unit: unit, detail: detail, hue: hue, id: metricID.rawValue),
                state: state,
                evidence: fieldEvidence
            )
        }
        return MetricMapping(
            metricID: metricID,
            metric: FitnessMetric(
                id: metricID.rawValue,
                title: title,
                value: formatNumber(value.value),
                unit: unit,
                detail: detail,
                quality: .observed,
                hue: hue
            ),
            state: state,
            evidence: fieldEvidence
        )
    }

    private static func makeLoadDetail(
        dailySteps: MetricMapping,
        dailyEnergy: MetricMapping
    ) -> FitnessLoadDetail {
        let defaults = FitnessLoadTrendID.allCases.map {
            FitnessLoadTrendCard(id: $0, metric: .unavailable($0.title))
        }
        var cards = defaults
        if let index = cards.firstIndex(where: { $0.id == .steps }) {
            cards[index] = FitnessLoadTrendCard(id: .steps, metric: dailySteps.metric, evidence: fitnessEvidence(dailySteps.evidence))
        }
        if let index = cards.firstIndex(where: { $0.id == .totalEnergy }) {
            cards[index] = FitnessLoadTrendCard(id: .totalEnergy, metric: dailyEnergy.metric, evidence: fitnessEvidence(dailyEnergy.evidence))
        }
        let energyMetric: FitnessMetric
        if dailyEnergy.metric.quality == .unavailable {
            energyMetric = .unavailable("Energy expenditure")
        } else {
            energyMetric = FitnessMetric(
                id: "active_energy",
                title: "Energy expenditure",
                value: dailyEnergy.metric.value,
                unit: dailyEnergy.metric.unit,
                detail: dailyEnergy.metric.detail,
                quality: dailyEnergy.metric.quality,
                hue: dailyEnergy.metric.hue
            )
        }
        return FitnessLoadDetail(
            energy: energyMetric,
            trendCards: cards
        )
    }

    private static func makeBiologySnapshot(
        projection: HealthKitFitnessProjection,
        evidence: [HealthKitMetricID: HealthKitFitnessCompositionEvidence]
    ) -> FitnessBiologySnapshot {
        let directMappings: [(HealthKitMetricID, FitnessBiologyMetricID)] = [
            (.bodyMass, .weight),
            (.bodyFatPercentage, .bodyFat),
            (.leanBodyMass, .fatFreeMass),
            (.vo2Max, .vo2Max)
        ]
        let directMetrics = directMappings.map { metricID, biologyID in
            makeBiologyMetric(
                projection: projection.metric(metricID),
                metricID: metricID,
                biologyID: biologyID,
                evidence: evidence[metricID]
            )
        }
        return FitnessBiologySnapshot(
            biologicalAge: .unavailable,
            metrics: directMetrics + [
                .unavailable(.hrvBaseline, reason: "Unavailable · HRV baseline is not calculated by this composition."),
                .unavailable(.rhrBaseline, reason: "Unavailable · RHR baseline is not calculated by this composition.")
            ]
        )
    }

    private static func makeBiologyMetric(
        projection: HealthKitFitnessMetricProjection,
        metricID: HealthKitMetricID,
        biologyID: FitnessBiologyMetricID,
        evidence: HealthKitFitnessCompositionEvidence?
    ) -> FitnessBiologyMetric {
        let state = SourceState(projection.state)
        guard state == .observed,
              let latest = projection.latest,
              latest.quantity.metric == metricID else {
            return .unavailable(
                biologyID,
                reason: projection.reason ?? "Unavailable · \(biologyID.title) is not an observed direct HealthKit value."
            )
        }

        let sourceEvidence = evidence ?? HealthKitFitnessCompositionEvidence(
            state: state,
            source: "HealthKit",
            device: "Device metadata not supplied",
            provenance: "HealthKit provenance unavailable",
            window: "Projection window",
            freshness: "Freshness unavailable"
        )
        let samples = projection.observations.compactMap { sample in
            FitnessBiologySample(date: sample.startDate, value: sample.quantity.value)
        }
        guard let currentSample = FitnessBiologySample(date: latest.startDate, value: latest.quantity.value),
              !samples.isEmpty else {
            return .unavailable(
                biologyID,
                reason: "Unavailable · \(biologyID.title) has no valid source sample timestamp."
            )
        }
        return FitnessBiologyMetric(
            id: biologyID,
            state: .observed(
                value: currentSample.value,
                unit: biologyID.unit,
                sourceDevice: sourceEvidence.device,
                sampleCount: samples.count,
                freshness: sourceEvidence.freshness,
                window: sourceEvidence.window,
                provenance: sourceEvidence.provenance,
                samples: samples
            )
        )
    }

    private static func selectSleep(
        _ sleep: HealthKitFitnessSleepProjection,
        selectedDate: Date,
        selectedDateIsFinite: Bool,
        calendar: Calendar
    ) -> SelectedSleep {
        guard selectedDateIsFinite,
              let day = calendar.dateInterval(of: .day, for: selectedDate),
              day.start.timeIntervalSinceReferenceDate.isFinite,
              day.end.timeIntervalSinceReferenceDate.isFinite,
              day.end > day.start else {
            return SelectedSleep(
                samples: [],
                conflicts: [],
                state: .unavailable,
                reason: "Selected sleep day is invalid.",
                start: nil,
                end: nil,
                provenance: []
            )
        }

        func belongsToSelectedDay(_ endDate: Date) -> Bool {
            endDate >= day.start && endDate < day.end
        }

        let samples = sleep.samples.filter { belongsToSelectedDay($0.endDate) }
        let conflicts = sleep.conflicts.filter { conflict in
            conflict.existing.metric == .sleep && conflict.incoming.metric == .sleep &&
            (belongsToSelectedDay(conflict.existing.endDate) || belongsToSelectedDay(conflict.incoming.endDate))
        }

        let state: SourceState
        if !conflicts.isEmpty {
            // A selected revision conflict is terminal even if the enclosing
            // projection reports a nominally synced state.
            state = .conflict
        } else {
            switch sleep.syncState {
            case .neverSynced:
                state = .unavailable
            case .syncing, .partial:
                state = .partial
            case .readIndeterminate:
                state = .readIndeterminate
            case .stale:
                state = .stale
            case .fullResyncRequired, .error:
                state = .error
            case .synced, .conflict:
                // A raw conflict can exist elsewhere in the retained
                // projection; it does not poison this selected day. A clean,
                // empty selected bucket remains honestly unavailable.
                state = samples.isEmpty ? .unavailable : .observed
            }
        }

        let reason: String?
        switch state {
        case .unavailable:
            reason = "No sleep sample ends in the selected day."
        case .partial:
            reason = sleep.reason ?? "Persisted HealthKit sleep observations are partial."
        case .stale:
            reason = sleep.reason ?? "Persisted HealthKit sleep observations are stale."
        case .conflict:
            reason = sleep.reason ?? "Selected HealthKit sleep observations contain a source conflict."
        case .readIndeterminate:
            reason = "HealthKit read access is indeterminate for sleep."
        case .error:
            reason = sleep.reason ?? "HealthKit sleep projection failed."
        case .observed, .permissionRequired:
            reason = nil
        }

        let provenance = samples.map(\.provenance) + conflicts.flatMap { conflict in
            [conflict.existing.provenance, conflict.incoming.provenance]
        }
        return SelectedSleep(
            samples: samples,
            conflicts: conflicts,
            state: state,
            reason: reason,
            start: samples.map(\.startDate).min(),
            end: samples.map(\.endDate).max(),
            provenance: provenance
        )
    }

    private static func makeSleepDetail(
        selected: SelectedSleep,
        evidence: HealthKitFitnessCompositionEvidence,
        timeZoneIdentifier: String
    ) -> FitnessSleepDetail {
        let knownStages = selected.samples.compactMap { sample -> FitnessSleepStageSample? in
            guard let stage = fitnessSleepStage(for: sample.stage) else { return nil }
            return FitnessSleepStageSample(
                id: sample.identity.stableKey,
                stage: stage,
                start: sample.startDate,
                end: sample.endDate
            )
        }
        let hasUnsupportedStage = selected.samples.contains { fitnessSleepStage(for: $0.stage) == nil }
        let nightState: FitnessSleepNight.State
        switch selected.state {
        case .observed:
            nightState = .observed
        case .partial:
            nightState = .partial(reason: selected.reason ?? "The source supplied only part of this sleep night.")
        case .stale:
            nightState = .partial(reason: "The source sleep interval is stale; no freshness assumption is added.")
        case .conflict:
            nightState = .conflict(reason: selected.reason ?? "Source sleep observations disagree for this night.")
        case .readIndeterminate:
            nightState = .unavailable(reason: "HealthKit read access is indeterminate for sleep.")
        case .permissionRequired:
            nightState = .unavailable(reason: "HealthKit sleep permission state is not established.")
        case .error:
            nightState = .unavailable(reason: selected.reason ?? "HealthKit sleep projection failed.")
        case .unavailable:
            nightState = .unavailable(reason: selected.reason ?? "No source sleep interval is available.")
        }

        let boundary = FitnessSleepDayBoundary(
            name: "Selected sleep day (end-date bucket)",
            timeZone: timeZoneIdentifier
        )
        let sleepEvidenceState: FitnessSleepObservationEvidence.State
        switch selected.state {
        case .observed:
            sleepEvidenceState = .observed(
                source: evidence.source,
                device: evidence.device,
                provenance: evidence.provenance,
                freshness: evidence.freshness
            )
        case .partial:
            sleepEvidenceState = .unavailable(reason: "Sleep source is partial; evidence is retained separately from a complete night.")
        case .stale:
            sleepEvidenceState = .unavailable(reason: "Sleep source is stale; evidence is retained separately from freshness.")
        case .conflict:
            sleepEvidenceState = .unavailable(reason: "Sleep source observations conflict.")
        case .readIndeterminate:
            sleepEvidenceState = .unavailable(reason: "HealthKit read access is indeterminate for sleep.")
        case .permissionRequired:
            sleepEvidenceState = .unavailable(reason: "HealthKit sleep permission state is not established.")
        case .error:
            sleepEvidenceState = .unavailable(reason: "HealthKit sleep projection failed.")
        case .unavailable:
            sleepEvidenceState = .unavailable(reason: "No source sleep interval is available.")
        }
        // Build once so the domain validator can downgrade an apparently
        // observed interval when stage coverage is incomplete or otherwise
        // invalid. The evidence on the final night must agree with that
        // validated state; an observed evidence value must never survive a
        // partial/conflict/unavailable downgrade.
        let initialNight = FitnessSleepNight(
            id: "healthkit-sleep-night",
            start: selected.start,
            end: selected.end,
            stageSamples: knownStages,
            boundary: boundary,
            evidence: FitnessSleepObservationEvidence(state: sleepEvidenceState),
            state: nightState
        )
        let finalSleepEvidence: FitnessSleepObservationEvidence
        switch initialNight.state {
        case .observed:
            finalSleepEvidence = FitnessSleepObservationEvidence(state: .observed(
                source: evidence.source,
                device: evidence.device,
                provenance: evidence.provenance,
                freshness: evidence.freshness
            ))
        case .partial(let reason):
            finalSleepEvidence = .unavailable("Sleep night is partial · \(reason)")
        case .conflict(let reason):
            finalSleepEvidence = .unavailable("Sleep night is conflicted · \(reason)")
        case .unavailable(let reason):
            finalSleepEvidence = .unavailable("Sleep night unavailable · \(reason)")
        }
        let night = FitnessSleepNight(
            id: initialNight.id,
            start: initialNight.start,
            end: initialNight.end,
            stageSamples: initialNight.stageSamples,
            boundary: initialNight.boundary,
            evidence: finalSleepEvidence,
            state: initialNight.state
        )

        // The projection's enclosing interval is not an asleep-duration
        // claim: it may include in-bed, awake, and unclassified time. Keep
        // Fitness duration unavailable until an explicit asleep-stage sum is
        // accepted by the product contract.
        let duration = unavailableMetric(
            title: "Sleep duration",
            unit: "",
            detail: metricDetail(
                state: selected.state,
                evidence: evidence,
                reason: hasUnsupportedStage
                    ? "Source sleep interval and stages retained; duration is unavailable because stage coverage is not fully named."
                    : "Source sleep interval retained; LifeOS does not relabel the enclosing interval as asleep duration."
            ),
            hue: .violet,
            id: "sleep_duration"
        )

        return FitnessSleepDetail(
            night: night,
            quality: unavailableMetric(
                title: "Sleep quality",
                unit: "",
                detail: "Unavailable · LifeOS does not calculate sleep quality from an interval or stage timeline.",
                hue: .violet,
                id: "sleep_quality"
            ),
            timeInBed: .unavailable("Time in bed"),
            duration: duration,
            sleepNeed: .unavailable("Sleep need requires a configured target; no target is fabricated."),
            windDown: .unavailable("Wind-down requires a configured sleep schedule."),
            insights: [],
            trends: []
        )
    }

    private static func makeWorkout(
        _ workout: HealthKitFitnessWorkout,
        state: SourceState,
        evidence: HealthKitFitnessCompositionEvidence
    ) -> FitnessWorkout {
        let durationSeconds = max(0, Int(workout.durationSeconds.rounded()))
        let duration = formatDuration(seconds: durationSeconds)
        let energy: String
        if let activeEnergy = workout.activeEnergyKilocalories {
            energy = "Active energy \(formatNumber(activeEnergy)) kcal"
        } else {
            energy = "Active energy unavailable"
        }
        let rawReason = "Raw HealthKit activity type \(workout.activityTypeRawValue) · duration \(durationSeconds) s"
        let detail = metricDetail(state: state, evidence: evidence, reason: rawReason) + " · \(energy)"
        return FitnessWorkout(
            id: workout.identity.stableKey,
            name: "HealthKit activity type \(workout.activityTypeRawValue)",
            kind: "HealthKit raw activity",
            time: workout.startDate,
            duration: duration,
            detail: detail,
            hue: .blue
        )
    }

    private static func selectedWorkouts(
        _ workouts: [HealthKitFitnessWorkout],
        selectedDate: Date,
        selectedDateIsFinite: Bool,
        calendar: Calendar
    ) -> [HealthKitFitnessWorkout] {
        guard selectedDateIsFinite,
              let day = calendar.dateInterval(of: .day, for: selectedDate) else { return [] }
        return workouts.filter { workout in
            let interval = DateInterval(start: workout.startDate, end: workout.endDate)
            return interval.start < day.end && interval.end > day.start
        }
    }

    private static func aggregateProvenances(
        projection: HealthKitFitnessProjection,
        selectedDate: Date,
        selectedDateIsFinite: Bool,
        selectedSleep: SelectedSleep,
        calendar: Calendar
    ) -> [HealthKitProvenance] {
        var result: [HealthKitProvenance] = []
        for metricID in latestMetricIDs {
            result.append(contentsOf: projection.metric(metricID).observations.map(\.provenance))
        }
        if selectedDateIsFinite {
            for metricID in dailyMetricIDs {
                result.append(contentsOf: projection.dailyTotal(for: metricID, on: selectedDate)?.provenance ?? [])
            }
        }
        result.append(contentsOf: selectedSleep.provenance)
        result.append(contentsOf: selectedWorkouts(projection.workouts, selectedDate: selectedDate, selectedDateIsFinite: selectedDateIsFinite, calendar: calendar).map(\.provenance))
        return result
    }

    private static func aggregateState(_ states: [SourceState]) -> SourceState {
        // The aggregate describes the strongest state of the source-backed
        // fields that actually contribute data. An indeterminate/partial
        // side-channel must not hide an observed metric, while conflict/error
        // remain terminal because they invalidate accepted source facts.
        if states.contains(.error) { return .error }
        if states.contains(.conflict) { return .conflict }
        if states.contains(.observed) {
            if states.contains(.stale) { return .stale }
            if states.contains(.partial) { return .partial }
            return .observed
        }
        if states.contains(.readIndeterminate) { return .readIndeterminate }
        if states.contains(.permissionRequired) { return .permissionRequired }
        if states.contains(.stale) { return .stale }
        if states.contains(.partial) { return .partial }
        return .unavailable
    }

    private static func selectedValueIsDisplayable(_ state: SourceState) -> Bool {
        switch state {
        case .observed:
            return true
        case .unavailable, .permissionRequired, .partial, .stale, .conflict, .readIndeterminate, .error:
            return false
        }
    }

    public static func fitnessSourceStatus(for state: SourceState) -> FitnessSourceState.Status {
        switch state {
        case .observed: return .connected
        case .stale: return .stale
        case .permissionRequired: return .permissionRequired
        case .unavailable, .partial, .conflict, .readIndeterminate, .error:
            return .unavailable
        }
    }

    private static func makeEvidence(
        state: SourceState,
        provenances: [HealthKitProvenance],
        window: String,
        freshness: String
    ) -> HealthKitFitnessCompositionEvidence {
        let uniqueProvenances = Array(Set(provenances)).sorted { lhs, rhs in
            provenanceKey(lhs) < provenanceKey(rhs)
        }
        let matches = Array(Set(uniqueProvenances.map(\.helioMatch))).sorted { $0.rawValue < $1.rawValue }
        let confirmed = !uniqueProvenances.isEmpty && uniqueProvenances.allSatisfy { $0.helioMatch == .confirmed }
        let bundles = Array(Set(uniqueProvenances.compactMap { $0.source?.bundleIdentifier })).sorted()
        let devices = Array(Set(uniqueProvenances.compactMap { provenance -> String? in
            guard confirmed else { return nil }
            if let model = provenance.device?.model { return model }
            if let manufacturer = provenance.device?.manufacturer { return manufacturer }
            return nil
        })).sorted()
        let source: String
        let device: String
        let provenance: String
        if confirmed {
            source = "Helio → Zepp → Apple Health → HealthKit"
            device = devices.isEmpty ? "Reviewed Helio device" : devices.joined(separator: ", ")
            provenance = "Helio provenance confirmed by the canonical reviewed registry"
        } else {
            source = bundles.isEmpty ? "HealthKit" : "HealthKit source bundle: \(bundles.joined(separator: ", "))"
            device = "Device metadata not reviewed"
            provenance = uniqueProvenances.isEmpty
                ? "HealthKit provenance unavailable"
                : "HealthKit provenance · reviewed device identity not confirmed"
        }
        return HealthKitFitnessCompositionEvidence(
            state: state,
            source: source,
            device: device,
            provenance: provenance,
            window: window,
            freshness: freshness,
            sourceMatches: matches
        )
    }

    private static func fitnessEvidence(
        _ evidence: HealthKitFitnessCompositionEvidence
    ) -> FitnessSourceEvidence {
        switch evidence.state {
        case .observed:
            return FitnessSourceEvidence(state: .observed(
                source: evidence.source,
                device: evidence.device,
                window: evidence.window,
                freshness: evidence.freshness
            ))
        case .unavailable:
            return .unavailable("Unavailable · \(evidence.provenance)")
        case .permissionRequired, .partial, .stale, .conflict, .readIndeterminate, .error:
            return .unavailable("\(evidence.state.label) · \(evidence.provenance)")
        }
    }

    private static func metricDetail(
        state: SourceState,
        evidence: HealthKitFitnessCompositionEvidence,
        reason: String?
    ) -> String {
        let stateText = "\(state.label) · \(evidence.source) · \(evidence.window) · \(evidence.freshness)"
        guard let reason, !reason.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return stateText
        }
        return stateText + " · " + reason
    }

    private static func unavailableMetric(
        title: String,
        unit: String,
        detail: String,
        hue: LifeOSTokens.Hue,
        id: String
    ) -> FitnessMetric {
        FitnessMetric(
            id: id,
            title: title,
            value: nil,
            unit: unit,
            detail: detail,
            quality: .unavailable,
            hue: hue
        )
    }

    private static func retainedCalendar(for projection: HealthKitFitnessProjection) -> Calendar {
        var calendar = Calendar(identifier: projection.bucketCalendarIdentifier)
        calendar.timeZone = TimeZone(identifier: projection.bucketTimeZoneIdentifier) ?? TimeZone(secondsFromGMT: 0)!
        return calendar
    }

    private static func safeProjectionWindow(for projection: HealthKitFitnessProjection) -> DateInterval {
        let start = projection.windowStart.timeIntervalSinceReferenceDate.isFinite ? projection.windowStart : .distantPast
        let end = projection.windowEnd.timeIntervalSinceReferenceDate.isFinite && projection.windowEnd > start
            ? projection.windowEnd
            : start.addingTimeInterval(1)
        return DateInterval(start: start, end: end)
    }

    private static func describeProjectionWindow(
        _ projection: HealthKitFitnessProjection,
        calendar: Calendar
    ) -> String {
        "Projection window \(formatDate(projection.windowStart, calendar: calendar))–\(formatDate(projection.windowEnd, calendar: calendar)) · \(calendar.timeZone.identifier)"
    }

    private static func describeSelectedDay(_ date: Date, calendar: Calendar) -> String {
        guard date.timeIntervalSinceReferenceDate.isFinite else {
            return "Selected day invalid · \(calendar.timeZone.identifier)"
        }
        return "Selected day \(formatDate(calendar.startOfDay(for: date), calendar: calendar, dateOnly: true)) · \(calendar.timeZone.identifier)"
    }

    private static func latestMetricFreshness(
        _ metric: HealthKitFitnessMetricProjection,
        calendar: Calendar
    ) -> String {
        freshnessDescription(
            committed: metric.lastCommittedAt,
            observed: metric.observations.map(\.endDate).max(),
            calendar: calendar
        )
    }

    private static func dailyFreshness(
        _ daily: HealthKitFitnessDailyTotal?,
        calendar: Calendar
    ) -> String {
        freshnessDescription(
            committed: nil,
            observed: daily?.samples.map(\.endDate).max(),
            calendar: calendar
        )
    }

    private static func sleepFreshness(
        _ sleep: SelectedSleep,
        calendar: Calendar
    ) -> String {
        freshnessDescription(
            committed: nil,
            observed: sleep.samples.map(\.endDate).max(),
            calendar: calendar
        )
    }

    private static func workoutFreshness(
        _ workouts: [HealthKitFitnessWorkout],
        calendar: Calendar
    ) -> String {
        freshnessDescription(
            committed: nil,
            observed: workouts.map(\.endDate).max(),
            calendar: calendar
        )
    }

    private static func freshnessDescription(
        committed: Date?,
        observed: Date?,
        calendar: Calendar
    ) -> String {
        var parts: [String] = []
        if let committed {
            parts.append("Committed \(formatDate(committed, calendar: calendar))")
        }
        if let observed {
            parts.append("Observed through \(formatDate(observed, calendar: calendar))")
        }
        return parts.isEmpty ? "Freshness unavailable" : parts.joined(separator: " · ")
    }

    private static func aggregateFreshnessDescription(
        projection: HealthKitFitnessProjection,
        selectedDate: Date,
        selectedSleep: SelectedSleep,
        calendar: Calendar
    ) -> String {
        let selectedDateIsFinite = selectedDate.timeIntervalSinceReferenceDate.isFinite
        let selectedWorkoutObservations = selectedWorkouts(
            projection.workouts,
            selectedDate: selectedDate,
            selectedDateIsFinite: selectedDateIsFinite,
            calendar: calendar
        )
        let selectedDailyDates = selectedDateIsFinite
            ? dailyMetricIDs.flatMap { projection.dailyTotal(for: $0, on: selectedDate)?.samples.map(\.endDate) ?? [] }
            : []
        let committedDates = latestMetricIDs.compactMap { projection.metric($0).lastCommittedAt }
        let observedDates = latestMetricIDs.flatMap { projection.metric($0).observations.map(\.endDate) }
            + selectedDailyDates
            + selectedSleep.samples.map(\.endDate)
            + selectedWorkoutObservations.map(\.endDate)
        return freshnessDescription(
            committed: committedDates.max(),
            observed: observedDates.max(),
            calendar: calendar
        )
    }

    private static func provenanceKey(_ provenance: HealthKitProvenance) -> String {
        let source = provenance.source?.bundleIdentifier ?? ""
        let manufacturer = provenance.device?.manufacturer ?? ""
        let model = provenance.device?.model ?? ""
        return "\(source)|\(manufacturer)|\(model)|\(provenance.helioMatch.rawValue)"
    }

    private static func fitnessSleepStage(for stage: HealthKitSleepStage) -> FitnessSleepStageSample.Stage? {
        switch stage {
        case .asleepREM: .rem
        case .asleepDeep: .deep
        case .asleepCore: .core
        case .awake: .awake
        case .inBed, .asleepUnspecified, .unknown: nil
        }
    }

    private static func formatNumber(_ value: Double) -> String {
        guard value.isFinite else { return "—" }
        let formatter = NumberFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.numberStyle = .decimal
        formatter.usesGroupingSeparator = true
        formatter.minimumFractionDigits = 0
        formatter.maximumFractionDigits = 2
        return formatter.string(from: NSNumber(value: value)) ?? String(format: "%.2f", locale: Locale(identifier: "en_US_POSIX"), value)
    }

    private static func formatDuration(seconds: Int) -> String {
        guard seconds > 0 else { return "0 s" }
        let hours = seconds / 3_600
        let minutes = (seconds % 3_600) / 60
        let remainder = seconds % 60
        if hours > 0 {
            return remainder == 0 ? "\(hours)h \(minutes)m" : "\(hours)h \(minutes)m \(remainder)s"
        }
        if minutes > 0 {
            return remainder == 0 ? "\(minutes) min" : "\(minutes) min \(remainder)s"
        }
        return "\(remainder) s"
    }

    private static func formatDate(
        _ date: Date,
        calendar: Calendar,
        dateOnly: Bool = false
    ) -> String {
        guard date.timeIntervalSinceReferenceDate.isFinite else { return "Invalid date" }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = calendar
        formatter.timeZone = calendar.timeZone
        formatter.dateFormat = dateOnly ? "yyyy-MM-dd" : "yyyy-MM-dd HH:mm:ss ZZZZ"
        return formatter.string(from: date)
    }
}
#endif
