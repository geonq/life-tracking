import XCTest
@testable import LifeOS

final class HealthKitFitnessCompositionTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_700_000_000)
    private let calendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Europe/Berlin")!
        return calendar
    }()

    private func provenance(
        bundle: String = "com.example.health",
        manufacturer: String? = nil,
        model: String? = nil
    ) throws -> HealthKitProvenance {
        let source = try HealthKitSourceMetadata(bundleIdentifier: bundle, name: bundle)
        let device = try HealthKitDeviceMetadata(manufacturer: manufacturer, model: model)
        return try HealthKitProvenance.from(source: source, device: device, registry: .canonical)
    }

    private func helioProvenance() throws -> HealthKitProvenance {
        try provenance(bundle: "com.zepp.health", manufacturer: "Amazfit", model: "Helio Strap")
    }

    private func quantity(
        metric: HealthKitMetricID,
        value: Double,
        at date: Date,
        provenance: HealthKitProvenance? = nil,
        uuid: UUID = UUID()
    ) throws -> HealthKitObservation {
        try HealthKitObservation(
            metric: metric,
            identity: HealthKitSampleIdentity(uuid: uuid),
            value: .quantity(try HealthKitQuantityValue(metric: metric, value: value, unit: XCTUnwrap(metric.canonicalUnit))),
            startDate: date,
            endDate: date,
            provenance: try provenance ?? self.provenance(),
            now: now
        )
    }

    private func sleep(
        stage: HealthKitSleepStage,
        start: Date,
        end: Date,
        provenance: HealthKitProvenance? = nil
    ) throws -> HealthKitObservation {
        try HealthKitObservation(
            metric: .sleep,
            identity: HealthKitSampleIdentity(uuid: UUID()),
            value: .sleep(try HealthKitSleepValue(stage: stage, timeZoneIdentifier: "Europe/Berlin")),
            startDate: start,
            endDate: end,
            provenance: try provenance ?? self.provenance(),
            now: now
        )
    }

    private func workout(
        start: Date,
        duration: Double,
        activityType: Int = 13,
        energy: Double? = 321
    ) throws -> HealthKitObservation {
        try HealthKitObservation(
            metric: .workout,
            identity: HealthKitSampleIdentity(uuid: UUID()),
            value: .workout(try HealthKitWorkoutValue(
                activityTypeRawValue: activityType,
                durationSeconds: duration,
                activeEnergyKilocalories: energy
            )),
            startDate: start,
            endDate: start.addingTimeInterval(duration),
            provenance: try provenance(),
            now: now
        )
    }

    private func state(
        metric: HealthKitMetricID,
        observations: [HealthKitObservation] = [],
        conflicts: [HealthKitObservationConflict] = [],
        syncState: HealthKitSyncState = .synced,
        committedAt: Date? = nil
    ) throws -> HealthKitStoredMetricState {
        let projection = try HealthKitMetricProjection(
            metric: metric,
            observations: observations,
            conflicts: conflicts,
            lastCommittedAt: committedAt ?? now,
            syncState: syncState
        )
        return HealthKitStoredMetricState(projection: projection)
    }

    private func projection(
        states: [HealthKitStoredMetricState],
        start: Date? = nil,
        end: Date? = nil
    ) -> HealthKitFitnessProjection {
        HealthKitFitnessProjection(
            states: states,
            window: DateInterval(
                start: start ?? now.addingTimeInterval(-86_400),
                end: end ?? now.addingTimeInterval(86_400)
            ),
            calendar: calendar
        )
    }

    func testDirectMetricsAndSelectedDayTotalsMapWithoutZeroFabrication() throws {
        let selected = calendar.date(from: DateComponents(year: 2023, month: 11, day: 14, hour: 12))!
        let rhr = try quantity(metric: .restingHeartRate, value: 54, at: selected)
        let steps = try quantity(metric: .steps, value: 7_432, at: selected)
        let energy = try quantity(metric: .activeEnergy, value: 321.5, at: selected)
        let composition = HealthKitFitnessComposition.compose(
            projection: projection(
                states: [
                    try state(metric: .restingHeartRate, observations: [rhr]),
                    try state(metric: .steps, observations: [steps]),
                    try state(metric: .activeEnergy, observations: [energy])
                ],
                start: calendar.startOfDay(for: selected),
                end: calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: selected))!
            ),
            selectedDate: selected
        )

        XCTAssertEqual(composition.snapshot.healthMonitor.first(where: { $0.title == "Resting heart rate" })?.value, "54")
        XCTAssertEqual(composition.snapshot.loadDetail.trendCards.first(where: { $0.id == .steps })?.metric.value, "7,432")
        XCTAssertEqual(composition.snapshot.loadDetail.energy.value, "321.5")
        XCTAssertNil(composition.snapshot.bodyMetrics.first(where: { $0.title == "Body fat" })?.value)
        XCTAssertEqual(composition.sourceState, .observed)
        XCTAssertTrue(composition.snapshot.healthMonitor.allSatisfy { $0.trend.isEmpty })
    }

    func testMetricFreshnessUsesOnlyThatMetricEvidence() throws {
        let oldDate = now.addingTimeInterval(-172_800)
        let oldBodyMass = try quantity(metric: .bodyMass, value: 72, at: oldDate)
        let freshRHR = try quantity(metric: .restingHeartRate, value: 55, at: now)
        let composition = HealthKitFitnessComposition.compose(
            projection: projection(
                states: [
                    try state(metric: .bodyMass, observations: [oldBodyMass], committedAt: oldDate),
                    try state(metric: .restingHeartRate, observations: [freshRHR], committedAt: now)
                ],
                start: oldDate.addingTimeInterval(-60),
                end: now.addingTimeInterval(60)
            ),
            selectedDate: now
        )

        let bodyFreshness = try XCTUnwrap(composition.evidence[.bodyMass]?.freshness)
        let rhrFreshness = try XCTUnwrap(composition.evidence[.restingHeartRate]?.freshness)
        XCTAssertNotEqual(bodyFreshness, rhrFreshness)
        XCTAssertTrue(bodyFreshness.contains("2023-11-12"))
        XCTAssertTrue(rhrFreshness.contains("2023-11-14"))
    }

    func testSelectedDateUsesRetainedCalendarAndDoesNotLeakAnotherDay() throws {
        let selected = calendar.date(from: DateComponents(year: 2023, month: 11, day: 14, hour: 12))!
        let otherDay = calendar.date(byAdding: .day, value: -1, to: selected)!
        let steps = try quantity(metric: .steps, value: 999, at: otherDay)
        let composition = HealthKitFitnessComposition.compose(
            projection: projection(states: [try state(metric: .steps, observations: [steps])]),
            selectedDate: selected
        )

        XCTAssertNil(composition.snapshot.loadDetail.trendCards.first(where: { $0.id == .steps })?.metric.value)
        XCTAssertTrue(composition.snapshot.loadDetail.trendCards.first(where: { $0.id == .steps })?.metric.detail.contains("Selected day") == true)
        XCTAssertEqual(composition.timeZoneIdentifier, "Europe/Berlin")
        XCTAssertEqual(composition.calendarIdentifier, .gregorian)
    }

    func testPartialStaleConflictReadIndeterminateAndErrorRemainVisible() throws {
        let sample = try quantity(metric: .bodyMass, value: 72, at: now)
        let partial = HealthKitFitnessComposition.compose(
            projection: projection(states: [try state(metric: .bodyMass, observations: [sample], syncState: .partial)]),
            selectedDate: now
        )
        XCTAssertEqual(partial.metricStates[.bodyMass], .partial)
        XCTAssertNil(partial.snapshot.bodyMetrics.first(where: { $0.title == "Weight" })?.value, "Partial source data is not presented as complete latest data")

        let stale = HealthKitFitnessComposition.compose(
            projection: projection(states: [try state(metric: .bodyMass, observations: [sample], syncState: .stale)]),
            selectedDate: now
        )
        XCTAssertEqual(stale.metricStates[.bodyMass], .stale)

        let changed = try quantity(metric: .bodyMass, value: 73, at: now, uuid: sample.identity.uuid)
        let conflict = HealthKitObservationConflict(metric: .bodyMass, identity: sample.identity, existing: sample, incoming: changed)
        let conflicted = HealthKitFitnessComposition.compose(
            projection: projection(states: [try state(metric: .bodyMass, observations: [sample], conflicts: [conflict])]),
            selectedDate: now
        )
        XCTAssertEqual(conflicted.metricStates[.bodyMass], .conflict)
        XCTAssertNil(conflicted.snapshot.bodyMetrics.first(where: { $0.title == "Weight" })?.value)
        XCTAssertNil(conflicted.snapshot.biology.metrics.first(where: { $0.id == .weight })?.currentValue)

        let indeterminate = HealthKitFitnessComposition.compose(
            projection: projection(states: [try state(metric: .bodyMass, syncState: .readIndeterminate)]),
            selectedDate: now
        )
        XCTAssertEqual(indeterminate.metricStates[.bodyMass], .readIndeterminate)

        let invalid = HealthKitFitnessComposition.compose(
            projection: HealthKitFitnessProjection(
                states: [HealthKitStoredMetricState.empty(for: .bodyMass)],
                window: DateInterval(
                    start: now.addingTimeInterval(-HealthKitFitnessProjection.maximumWindow - 1),
                    end: now
                ),
                calendar: calendar
            ),
            selectedDate: now
        )
        XCTAssertEqual(invalid.sourceState, .error)
        XCTAssertEqual(invalid.snapshot.source.status, .unavailable)
    }

    func testWorkoutRowsRequireObservedNonconflictingFacts() throws {
        let sample = try workout(start: now.addingTimeInterval(-600), duration: 321)
        let stale = HealthKitFitnessComposition.compose(
            projection: projection(states: [try state(metric: .workout, observations: [sample], syncState: .stale)]),
            selectedDate: now
        )
        XCTAssertEqual(stale.workoutState, .stale)
        XCTAssertTrue(stale.snapshot.workouts.isEmpty)

        let partial = HealthKitFitnessComposition.compose(
            projection: projection(states: [try state(metric: .workout, observations: [sample], syncState: .partial)]),
            selectedDate: now
        )
        XCTAssertEqual(partial.workoutState, .partial)
        XCTAssertTrue(partial.snapshot.workouts.isEmpty)
    }

    func testPermissionRequiredMapsToPermissionSourceStatus() {
        XCTAssertEqual(
            HealthKitFitnessComposition.fitnessSourceStatus(for: .permissionRequired),
            .permissionRequired
        )
    }

    func testObservedFieldKeepsAggregateSourceVisibleWhenAnotherFieldIsIndeterminate() throws {
        let observed = try quantity(metric: .restingHeartRate, value: 55, at: now)
        let composition = HealthKitFitnessComposition.compose(
            projection: projection(states: [
                try state(metric: .restingHeartRate, observations: [observed]),
                try state(metric: .bodyMass, syncState: .readIndeterminate)
            ]),
            selectedDate: now
        )
        XCTAssertEqual(composition.metricStates[.bodyMass], .readIndeterminate)
        XCTAssertEqual(composition.sourceState, .observed)
        XCTAssertEqual(composition.snapshot.source.status, .connected)
    }

    func testUnsupportedScoresBaselinesAndBiologicalAgeStayUnavailable() throws {
        let composition = HealthKitFitnessComposition.compose(
            projection: projection(states: [HealthKitStoredMetricState.empty(for: .vo2Max)]),
            selectedDate: now
        )
        XCTAssertNil(composition.snapshot.readiness.value)
        XCTAssertNil(composition.snapshot.strain.value)
        XCTAssertNil(composition.snapshot.stress.value)
        XCTAssertNil(composition.snapshot.energyReserve.value)
        XCTAssertNil(composition.snapshot.bodyMetrics.first(where: { $0.title == "HRV baseline" })?.value)
        XCTAssertTrue(composition.snapshot.biology.metrics.allSatisfy { $0.currentValue == nil })
        if case .gated = composition.snapshot.biology.biologicalAge.state {
            // Biological age remains gated without a reviewed model.
        } else {
            XCTFail("Biological age must remain gated")
        }
        XCTAssertNil(composition.snapshot.sleepDetail.quality.value)
    }

    func testObservedDirectBiologyMetricsCarryCurrentSamplesAndKeepGatesUnavailable() throws {
        let states: [HealthKitStoredMetricState] = [
            try state(metric: .bodyMass, observations: [try quantity(metric: .bodyMass, value: 72.4, at: now)]),
            try state(metric: .bodyFatPercentage, observations: [try quantity(metric: .bodyFatPercentage, value: 18.2, at: now)]),
            try state(metric: .leanBodyMass, observations: [try quantity(metric: .leanBodyMass, value: 59.1, at: now)]),
            try state(metric: .vo2Max, observations: [try quantity(metric: .vo2Max, value: 44.2, at: now)])
        ]
        let composition = HealthKitFitnessComposition.compose(
            projection: projection(states: states),
            selectedDate: now
        )
        let biology = composition.snapshot.biology
        let expected: [(FitnessBiologyMetricID, Double, FitnessBiologyUnit)] = [
            (.weight, 72.4, .kilograms),
            (.bodyFat, 18.2, .percent),
            (.fatFreeMass, 59.1, .kilograms),
            (.vo2Max, 44.2, .millilitersPerKilogramMinute)
        ]
        for (id, value, unit) in expected {
            let metric = try XCTUnwrap(biology.metrics.first(where: { $0.id == id }))
            guard case .observed(let current, let actualUnit, let device, let count, let freshness, let window, let provenance, let samples) = metric.state else {
                return XCTFail("Expected observed biology metric for \(id)")
            }
            XCTAssertEqual(current, value)
            XCTAssertEqual(actualUnit, unit)
            XCTAssertFalse(device.isEmpty)
            XCTAssertEqual(count, 1)
            XCTAssertEqual(samples.count, 1)
            XCTAssertFalse(freshness.isEmpty)
            XCTAssertFalse(window.isEmpty)
            XCTAssertFalse(provenance.isEmpty)
        }
        XCTAssertNil(biology.metrics.first(where: { $0.id == .hrvBaseline })?.currentValue)
        XCTAssertNil(biology.metrics.first(where: { $0.id == .rhrBaseline })?.currentValue)
        if case .gated = biology.biologicalAge.state {
            // Expected: biological age remains gated without a reviewed model.
        } else {
            XCTFail("Biological age must remain gated")
        }
    }

    func testHelioLabelRequiresConfirmedCanonicalProvenance() throws {
        let confirmed = HealthKitFitnessComposition.compose(
            projection: projection(states: [try state(metric: .restingHeartRate, observations: [
                try quantity(metric: .restingHeartRate, value: 52, at: now, provenance: try helioProvenance())
            ])]),
            selectedDate: now
        )
        XCTAssertTrue(confirmed.evidence[.restingHeartRate]?.source.contains("Helio") == true)
        XCTAssertEqual(confirmed.evidence[.restingHeartRate]?.sourceMatches, [.confirmed])

        let candidate = try provenance(bundle: "com.zepp.health", manufacturer: "Amazfit")
        let unconfirmed = HealthKitFitnessComposition.compose(
            projection: projection(states: [try state(metric: .restingHeartRate, observations: [
                try quantity(metric: .restingHeartRate, value: 53, at: now, provenance: candidate)
            ])]),
            selectedDate: now
        )
        XCTAssertFalse(unconfirmed.evidence[.restingHeartRate]?.source.contains("Helio →") == true)
        XCTAssertEqual(unconfirmed.evidence[.restingHeartRate]?.sourceMatches, [.candidate])
    }

    func testSleepRetainsIntervalAndNamedStagesButDoesNotCallIntervalAsleepDuration() throws {
        let start = now.addingTimeInterval(-3_600)
        let sleepSamples = [
            try sleep(stage: .inBed, start: start, end: start.addingTimeInterval(600)),
            try sleep(stage: .asleepCore, start: start.addingTimeInterval(600), end: start.addingTimeInterval(1_800)),
            try sleep(stage: .awake, start: start.addingTimeInterval(1_800), end: start.addingTimeInterval(2_000)),
            try sleep(stage: .asleepREM, start: start.addingTimeInterval(2_000), end: start.addingTimeInterval(2_400))
        ]
        let composition = HealthKitFitnessComposition.compose(
            projection: projection(states: [try state(metric: .sleep, observations: sleepSamples)]),
            selectedDate: now
        )

        XCTAssertEqual(composition.snapshot.sleepDetail.night.start, start)
        XCTAssertEqual(composition.snapshot.sleepDetail.night.end, start.addingTimeInterval(2_400))
        XCTAssertEqual(composition.snapshot.sleepDetail.night.stageSamples.map(\.stage), [.core, .awake, .rem])
        XCTAssertNil(composition.snapshot.sleepDetail.duration.value)
        XCTAssertNil(composition.snapshot.sleepDetail.quality.value)
        XCTAssertEqual(composition.snapshot.sleepDetail.night.state, .partial(reason: "Stage samples do not cover the full observed sleep interval."))
        if case .unavailable = composition.snapshot.sleepDetail.night.evidence.state {
            // The domain validator downgraded the night, so its evidence must
            // not continue to claim an observed sleep night.
        } else {
            XCTFail("A partial sleep night must not retain observed evidence")
        }
    }

    func testFullyCoveredNamedSleepStagesKeepObservedEvidence() throws {
        let start = now.addingTimeInterval(-2_400)
        let sleepSamples = [
            try sleep(stage: .asleepCore, start: start, end: start.addingTimeInterval(1_000)),
            try sleep(stage: .awake, start: start.addingTimeInterval(1_000), end: start.addingTimeInterval(1_400)),
            try sleep(stage: .asleepREM, start: start.addingTimeInterval(1_400), end: start.addingTimeInterval(2_400))
        ]
        let composition = HealthKitFitnessComposition.compose(
            projection: projection(states: [try state(metric: .sleep, observations: sleepSamples)]),
            selectedDate: now
        )

        XCTAssertEqual(composition.snapshot.sleepDetail.night.state, .observed)
        if case .observed = composition.snapshot.sleepDetail.night.evidence.state {
            // Fully covered, named stages preserve observed evidence.
        } else {
            XCTFail("A fully covered observed sleep night must retain observed evidence")
        }
    }

    func testWorkoutRetainsRawActivityFactsWithoutKindMappingOrLoad() throws {
        let sample = try workout(start: now.addingTimeInterval(-600), duration: 321, activityType: 99, energy: 210)
        let composition = HealthKitFitnessComposition.compose(
            projection: projection(states: [try state(metric: .workout, observations: [sample])]),
            selectedDate: now
        )
        let workout = try XCTUnwrap(composition.snapshot.workouts.first)
        XCTAssertEqual(workout.name, "HealthKit activity type 99")
        XCTAssertEqual(workout.kind, "HealthKit raw activity")
        XCTAssertEqual(workout.duration, "5 min 21s")
        XCTAssertTrue(workout.detail.contains("Active energy 210 kcal"))
        XCTAssertNil(composition.snapshot.strain.value)
        XCTAssertNil(composition.snapshot.loadDetail.gauge.currentProgress)
    }

    func testMissingValuesNeverBecomeZero() throws {
        let composition = HealthKitFitnessComposition.compose(
            projection: projection(states: [
                HealthKitStoredMetricState.empty(for: .steps),
                HealthKitStoredMetricState.empty(for: .activeEnergy),
                HealthKitStoredMetricState.empty(for: .sleep),
                HealthKitStoredMetricState.empty(for: .workout)
            ]),
            selectedDate: now
        )
        XCTAssertNil(composition.snapshot.loadDetail.trendCards.first(where: { $0.id == .steps })?.metric.value)
        XCTAssertNil(composition.snapshot.loadDetail.trendCards.first(where: { $0.id == .totalEnergy })?.metric.value)
        XCTAssertTrue(composition.snapshot.workouts.isEmpty)
        XCTAssertFalse(composition.snapshot.loadDetail.trendCards.contains { $0.metric.value == "0" })
    }

    func testNonObservedDailyStatesKeepStepsAndEnergyEvidenceUnavailable() throws {
        let states: [(HealthKitSyncState, String)] = [
            (.neverSynced, "unavailable"),
            (.partial, "partial"),
            (.stale, "stale"),
            (.readIndeterminate, "read-indeterminate")
        ]
        for (syncState, label) in states {
            let composition = HealthKitFitnessComposition.compose(
                projection: projection(states: [
                    try state(metric: .steps, syncState: syncState),
                    try state(metric: .activeEnergy, syncState: syncState)
                ]),
                selectedDate: now
            )
            let steps = try XCTUnwrap(composition.snapshot.loadDetail.trendCards.first(where: { $0.id == .steps }))
            let energy = try XCTUnwrap(composition.snapshot.loadDetail.trendCards.first(where: { $0.id == .totalEnergy }))
            XCTAssertTrue(steps.evidence.isUnavailable, "Steps evidence must be unavailable for \(label)")
            XCTAssertTrue(energy.evidence.isUnavailable, "Energy evidence must be unavailable for \(label)")
            XCTAssertNil(steps.metric.value, "Steps must not display a value for \(label)")
            XCTAssertNil(energy.metric.value, "Energy must not display a value for \(label)")
        }

        let steps = try quantity(metric: .steps, value: 7_000, at: now)
        let changedSteps = try quantity(metric: .steps, value: 7_001, at: now, uuid: steps.identity.uuid)
        let energy = try quantity(metric: .activeEnergy, value: 300, at: now)
        let changedEnergy = try quantity(metric: .activeEnergy, value: 301, at: now, uuid: energy.identity.uuid)
        let conflict = HealthKitFitnessComposition.compose(
            projection: projection(states: [
                try state(metric: .steps, observations: [steps], conflicts: [
                    HealthKitObservationConflict(metric: .steps, identity: steps.identity, existing: steps, incoming: changedSteps)
                ]),
                try state(metric: .activeEnergy, observations: [energy], conflicts: [
                    HealthKitObservationConflict(metric: .activeEnergy, identity: energy.identity, existing: energy, incoming: changedEnergy)
                ])
            ]),
            selectedDate: now
        )
        let conflictSteps = try XCTUnwrap(conflict.snapshot.loadDetail.trendCards.first(where: { $0.id == .steps }))
        let conflictEnergy = try XCTUnwrap(conflict.snapshot.loadDetail.trendCards.first(where: { $0.id == .totalEnergy }))
        XCTAssertEqual(conflict.metricStates[.steps], .conflict)
        XCTAssertEqual(conflict.metricStates[.activeEnergy], .conflict)
        XCTAssertTrue(conflictSteps.evidence.isUnavailable)
        XCTAssertTrue(conflictEnergy.evidence.isUnavailable)
        XCTAssertNil(conflictSteps.metric.value)
        XCTAssertNil(conflictEnergy.metric.value)
    }
}
