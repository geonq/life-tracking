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
        provenance: HealthKitProvenance? = nil,
        uuid: UUID = UUID()
    ) throws -> HealthKitObservation {
        try HealthKitObservation(
            metric: .sleep,
            identity: HealthKitSampleIdentity(uuid: uuid),
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

        let emptyError = HealthKitFitnessComposition.compose(
            projection: projection(states: [try state(metric: .bodyMass, syncState: .error)]),
            selectedDate: now
        )
        XCTAssertEqual(emptyError.metricStates[.bodyMass], .error)

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

    func testHistoricalLatestMetricsUseOnlySamplesBeforeSelectedLocalDayEnd() throws {
        let dayStart = calendar.date(from: DateComponents(year: 2023, month: 11, day: 13))!
        let dayEnd = calendar.date(byAdding: .day, value: 1, to: dayStart)!
        let selected = dayStart.addingTimeInterval(12 * 60 * 60)
        let oldDate = dayStart.addingTimeInterval(10 * 60 * 60)
        let oldProvenance = try provenance(bundle: "com.example.health")
        let futureProvenance = try provenance(bundle: "com.future.health")
        let expected: [(HealthKitMetricID, Double)] = [
            (.restingHeartRate, 54),
            (.heartRateVariabilitySDNN, 42),
            (.respiratoryRate, 16),
            (.oxygenSaturation, 98.2),
            (.bodyMass, 72.4),
            (.bodyFatPercentage, 18.2),
            (.leanBodyMass, 59.1),
            (.vo2Max, 44.2)
        ]
        let states = try expected.map { metric, value in
            try state(
                metric: metric,
                observations: [
                    try quantity(metric: metric, value: value, at: oldDate, provenance: oldProvenance),
                    try quantity(metric: metric, value: value + 100, at: dayEnd, provenance: futureProvenance)
                ],
                committedAt: oldDate
            )
        }
        let composition = HealthKitFitnessComposition.compose(
            projection: projection(
                states: states,
                start: dayStart.addingTimeInterval(-86_400),
                end: dayEnd.addingTimeInterval(86_400)
            ),
            selectedDate: selected
        )

        let cardValues: [(String, String)] = [
            ("Resting heart rate", "54"),
            ("HRV", "42"),
            ("Respiration", "16"),
            ("Blood oxygen", "98.2"),
            ("Weight", "72.4"),
            ("Body fat", "18.2"),
            ("Lean mass", "59.1"),
            ("VO₂ max", "44.2")
        ]
        for (title, value) in cardValues {
            let card = composition.snapshot.healthMonitor.first(where: { $0.title == title })
                ?? composition.snapshot.bodyMetrics.first(where: { $0.title == title })
            XCTAssertEqual(card?.value, value, "Expected historical value for \(title)")
        }

        let biologyValues: [(FitnessBiologyMetricID, Double)] = [
            (.weight, 72.4),
            (.bodyFat, 18.2),
            (.fatFreeMass, 59.1),
            (.vo2Max, 44.2)
        ]
        for (id, value) in biologyValues {
            let metric = try XCTUnwrap(composition.snapshot.biology.metrics.first(where: { $0.id == id }))
            guard case .observed(let current, _, _, let sampleCount, _, _, _, let samples) = metric.state else {
                return XCTFail("Expected observed historical biology metric for \(id)")
            }
            XCTAssertEqual(current, value)
            XCTAssertEqual(sampleCount, 1)
            XCTAssertEqual(samples.count, 1)
            XCTAssertTrue(samples.allSatisfy { $0.date < dayEnd })
        }

        for (metric, _) in expected {
            let fieldEvidence = try XCTUnwrap(composition.evidence[metric])
            XCTAssertFalse(fieldEvidence.freshness.contains("2023-11-14"), "Future freshness leaked for \(metric)")
            XCTAssertFalse(fieldEvidence.source.contains("com.future.health"), "Future provenance leaked for \(metric)")
        }
        XCTAssertFalse(composition.snapshot.source.freshness.contains("2023-11-14"))
        XCTAssertFalse(composition.snapshot.source.detail.contains("com.future.health"))
    }

    func testFutureOnlyLatestMetricsRemainUnavailable() throws {
        let dayStart = calendar.date(from: DateComponents(year: 2023, month: 11, day: 13))!
        let dayEnd = calendar.date(byAdding: .day, value: 1, to: dayStart)!
        let selected = dayStart.addingTimeInterval(12 * 60 * 60)
        let futureProvenance = try provenance(bundle: "com.future.health")
        let metricIDs: [HealthKitMetricID] = [
            .restingHeartRate,
            .heartRateVariabilitySDNN,
            .respiratoryRate,
            .oxygenSaturation,
            .bodyMass,
            .bodyFatPercentage,
            .leanBodyMass,
            .vo2Max
        ]
        let states = try metricIDs.map { metric in
            try state(
                metric: metric,
                observations: [try quantity(metric: metric, value: 100, at: dayEnd, provenance: futureProvenance)]
            )
        }
        let composition = HealthKitFitnessComposition.compose(
            projection: projection(
                states: states,
                start: dayStart,
                end: dayEnd.addingTimeInterval(86_400)
            ),
            selectedDate: selected
        )

        for metric in metricIDs {
            XCTAssertEqual(composition.metricStates[metric], .unavailable, "Future-only state leaked for \(metric)")
            XCTAssertEqual(composition.evidence[metric]?.state, .unavailable)
            XCTAssertFalse(composition.evidence[metric]?.freshness.contains("Observed through 2023-11-14") == true)
        }
        for title in ["Resting heart rate", "HRV", "Respiration", "Blood oxygen", "Weight", "Body fat", "Lean mass", "VO₂ max"] {
            let card = composition.snapshot.healthMonitor.first(where: { $0.title == title })
                ?? composition.snapshot.bodyMetrics.first(where: { $0.title == title })
            XCTAssertNil(card?.value, "Future-only value displayed for \(title)")
        }
        for id in [FitnessBiologyMetricID.weight, .bodyFat, .fatFreeMass, .vo2Max] {
            XCTAssertNil(composition.snapshot.biology.metrics.first(where: { $0.id == id })?.currentValue)
        }
        XCTAssertFalse(composition.snapshot.source.freshness.contains("Observed through 2023-11-14"))
        XCTAssertFalse(composition.snapshot.source.detail.contains("com.future.health"))
    }

    func testHistoricalLatestStateIgnoresFutureConflictAndGlobalErrorButKeepsSelectedConflict() throws {
        let dayStart = calendar.date(from: DateComponents(year: 2023, month: 11, day: 13))!
        let dayEnd = calendar.date(byAdding: .day, value: 1, to: dayStart)!
        let selected = dayStart.addingTimeInterval(12 * 60 * 60)
        let oldDate = dayStart.addingTimeInterval(10 * 60 * 60)
        let old = try quantity(metric: .bodyMass, value: 72, at: oldDate)

        func makeProjection(_ state: HealthKitStoredMetricState) -> HealthKitFitnessProjection {
            projection(
                states: [state],
                start: dayStart.addingTimeInterval(-86_400),
                end: dayEnd.addingTimeInterval(86_400)
            )
        }

        func assertHistoricalObserved(_ composition: HealthKitFitnessComposition) {
            XCTAssertEqual(composition.metricStates[.bodyMass], .observed)
            XCTAssertEqual(composition.evidence[.bodyMass]?.state, .observed)
            XCTAssertEqual(composition.sourceState, .observed)
            XCTAssertEqual(composition.snapshot.source.status, .connected)
            XCTAssertEqual(composition.snapshot.bodyMetrics.first(where: { $0.title == "Weight" })?.value, "72")
            XCTAssertEqual(composition.snapshot.biology.metrics.first(where: { $0.id == .weight })?.currentValue, 72)
        }

        let futureIdentity = UUID()
        let futureExisting = try quantity(metric: .bodyMass, value: 73, at: dayEnd, uuid: futureIdentity)
        let futureIncoming = try quantity(metric: .bodyMass, value: 74, at: dayEnd, uuid: futureIdentity)
        let futureConflict = HealthKitObservationConflict(
            metric: .bodyMass,
            identity: futureExisting.identity,
            existing: futureExisting,
            incoming: futureIncoming
        )
        let futureConflictComposition = HealthKitFitnessComposition.compose(
            projection: makeProjection(try state(metric: .bodyMass, observations: [old], conflicts: [futureConflict], committedAt: oldDate)),
            selectedDate: selected
        )
        assertHistoricalObserved(futureConflictComposition)

        let futureConflictOnlyComposition = HealthKitFitnessComposition.compose(
            projection: makeProjection(try state(metric: .bodyMass, conflicts: [futureConflict], committedAt: oldDate)),
            selectedDate: selected
        )
        XCTAssertEqual(futureConflictOnlyComposition.metricStates[.bodyMass], .unavailable)
        XCTAssertEqual(futureConflictOnlyComposition.evidence[.bodyMass]?.state, .unavailable)
        XCTAssertEqual(futureConflictOnlyComposition.sourceState, .unavailable)
        XCTAssertNil(futureConflictOnlyComposition.snapshot.bodyMetrics.first(where: { $0.title == "Weight" })?.value)
        XCTAssertNil(futureConflictOnlyComposition.snapshot.biology.metrics.first(where: { $0.id == .weight })?.currentValue)

        let globalErrorComposition = HealthKitFitnessComposition.compose(
            projection: makeProjection(try state(metric: .bodyMass, observations: [old], syncState: .error, committedAt: oldDate)),
            selectedDate: selected
        )
        assertHistoricalObserved(globalErrorComposition)

        let selectedIdentity = UUID()
        let selectedExisting = try quantity(metric: .bodyMass, value: 73, at: oldDate, uuid: selectedIdentity)
        let selectedIncoming = try quantity(metric: .bodyMass, value: 74, at: oldDate, uuid: selectedIdentity)
        let selectedConflict = HealthKitObservationConflict(
            metric: .bodyMass,
            identity: selectedExisting.identity,
            existing: selectedExisting,
            incoming: selectedIncoming
        )
        let selectedConflictComposition = HealthKitFitnessComposition.compose(
            projection: makeProjection(try state(metric: .bodyMass, observations: [old], conflicts: [selectedConflict], committedAt: oldDate)),
            selectedDate: selected
        )
        XCTAssertEqual(selectedConflictComposition.metricStates[.bodyMass], .conflict)
        XCTAssertEqual(selectedConflictComposition.evidence[.bodyMass]?.state, .conflict)
        XCTAssertEqual(selectedConflictComposition.sourceState, .conflict)
        XCTAssertNil(selectedConflictComposition.snapshot.bodyMetrics.first(where: { $0.title == "Weight" })?.value)
        XCTAssertNil(selectedConflictComposition.snapshot.biology.metrics.first(where: { $0.id == .weight })?.currentValue)
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

    func testSleepWithUnnamedStageShowsExactPartialNamedStageSums() throws {
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

        // The night stays partial and its evidence unavailable: the in-bed
        // interval is never called asleep time. The exact named-stage sums
        // stay visible with an explicit Partial label instead of vanishing.
        XCTAssertEqual(composition.snapshot.sleepDetail.night.start, start)
        XCTAssertEqual(composition.snapshot.sleepDetail.night.end, start.addingTimeInterval(2_400))
        XCTAssertEqual(composition.snapshot.sleepDetail.night.stageSamples.map(\.stage), [.core, .awake, .rem])
        XCTAssertNil(composition.snapshot.sleepDetail.quality.value)
        XCTAssertEqual(composition.snapshot.sleepDetail.night.state, .partial(reason: "Stage samples do not cover the full observed sleep interval."))
        XCTAssertEqual(composition.sleepState, .partial)
        XCTAssertEqual(composition.evidence[.sleep]?.state, .partial)

        // Exact sums of named source stages only; the 600 s in-bed interval
        // contributes to nothing.
        XCTAssertEqual(composition.snapshot.sleepDetail.duration.value, "26 min 40s")
        XCTAssertTrue(composition.snapshot.sleepDetail.duration.detail.contains("Partial"))
        XCTAssertTrue(composition.snapshot.sleepDetail.duration.detail.contains("unnamed source intervals excluded"))
        let trends = composition.snapshot.sleepDetail.trends
        XCTAssertEqual(trends.first(where: { $0.id == .core })?.metric.value, "20 min")
        XCTAssertEqual(trends.first(where: { $0.id == .awake })?.metric.value, "3 min 20s")
        XCTAssertEqual(trends.first(where: { $0.id == .rem })?.metric.value, "6 min 40s")

        // The Today Sleep card carries the same exact partial sum.
        XCTAssertEqual(composition.snapshot.sleep.value, "26 min 40s")
        XCTAssertTrue((composition.snapshot.sleep.detail).contains("Partial"))

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
        let trends = composition.snapshot.sleepDetail.trends
        XCTAssertEqual(composition.snapshot.sleepDetail.duration.value, "33 min 20s")
        XCTAssertEqual(trends.first(where: { $0.id == .duration })?.metric.value, "33 min 20s")
        XCTAssertEqual(trends.first(where: { $0.id == .rem })?.metric.value, "16 min 40s")
        XCTAssertNil(trends.first(where: { $0.id == .deep })?.metric.value)
        XCTAssertEqual(trends.first(where: { $0.id == .core })?.metric.value, "16 min 40s")
        XCTAssertEqual(trends.first(where: { $0.id == .awake })?.metric.value, "6 min 40s")
        XCTAssertEqual(trends.first(where: { $0.id == .rem })?.metric.quality, .observed)
        XCTAssertTrue(trends.first(where: { $0.id == .rem })?.availableRanges.isEmpty == true)
        XCTAssertTrue(trends.first(where: { $0.id == .rem })?.seriesByRange.isEmpty == true)
        XCTAssertFalse(trends.first(where: { $0.id == .rem })?.evidence.isUnavailable == true)
        XCTAssertNil(composition.snapshot.sleepDetail.timeInBed.value)
        XCTAssertNil(trends.first(where: { $0.id == .quality })?.metric.value)
    }

    func testSleepDurationRoundsAfterSummingFractionalStageIntervals() throws {
        let start = now.addingTimeInterval(-1.2)
        let sleepSamples = [
            try sleep(stage: .asleepCore, start: start, end: start.addingTimeInterval(0.6)),
            try sleep(stage: .asleepREM, start: start.addingTimeInterval(0.6), end: now)
        ]
        let composition = HealthKitFitnessComposition.compose(
            projection: projection(states: [try state(metric: .sleep, observations: sleepSamples)]),
            selectedDate: now
        )

        XCTAssertEqual(composition.sleepState, .observed)
        XCTAssertEqual(composition.snapshot.sleepDetail.duration.value, "2 s")
        XCTAssertEqual(composition.snapshot.sleepDetail.trends.first(where: { $0.id == .core })?.metric.value, "1 s")
        XCTAssertEqual(composition.snapshot.sleepDetail.trends.first(where: { $0.id == .rem })?.metric.value, "1 s")
    }

    func testSleepDurationUsesAbsoluteSecondsAcrossBerlinDSTFallback() throws {
        let start = try XCTUnwrap(calendar.date(from: DateComponents(year: 2023, month: 10, day: 28, hour: 22)))
        let end = try XCTUnwrap(calendar.date(from: DateComponents(year: 2023, month: 10, day: 29, hour: 7)))
        XCTAssertEqual(end.timeIntervalSince(start), 10 * 3_600)
        let sample = try sleep(stage: .asleepCore, start: start, end: end)
        let retained = projection(
            states: [try state(metric: .sleep, observations: [sample])],
            start: start.addingTimeInterval(-60),
            end: end.addingTimeInterval(60)
        )
        let selectedDate = try XCTUnwrap(calendar.date(from: DateComponents(year: 2023, month: 10, day: 29, hour: 12)))
        let composition = HealthKitFitnessComposition.compose(
            projection: retained,
            selectedDate: selectedDate
        )

        XCTAssertEqual(composition.sleepState, .observed)
        XCTAssertEqual(composition.snapshot.sleepDetail.night.end, end)
        XCTAssertEqual(composition.snapshot.sleepDetail.night.boundary?.name, "Selected sleep day (end-date bucket)")
        XCTAssertEqual(composition.snapshot.sleepDetail.duration.value, "10h 0m")
        XCTAssertEqual(composition.snapshot.sleepDetail.trends.first(where: { $0.id == .core })?.metric.value, "10h 0m")
    }

    func testNonObservedSleepStatesKeepDerivedTotalsUnavailable() throws {
        let start = now.addingTimeInterval(-2_400)
        let sleepSamples = [
            try sleep(stage: .asleepCore, start: start, end: start.addingTimeInterval(1_000)),
            try sleep(stage: .awake, start: start.addingTimeInterval(1_000), end: start.addingTimeInterval(1_400)),
            try sleep(stage: .asleepREM, start: start.addingTimeInterval(1_400), end: start.addingTimeInterval(2_400))
        ]
        for syncState in [HealthKitSyncState.partial, .stale] {
            let composition = HealthKitFitnessComposition.compose(
                projection: projection(states: [try state(metric: .sleep, observations: sleepSamples, syncState: syncState)]),
                selectedDate: now
            )
            XCTAssertNil(composition.snapshot.sleepDetail.duration.value)
            XCTAssertNil(composition.snapshot.sleepDetail.trends.first(where: { $0.id == .rem })?.metric.value)
            XCTAssertTrue(composition.snapshot.sleepDetail.trends.first(where: { $0.id == .rem })?.evidence.isUnavailable == true)
        }
    }

    func testSleepDurationReconcilesWithRoundedObservedStageTotals() throws {
        let start = now.addingTimeInterval(-10)
        let samples = [
            try sleep(stage: .asleepCore, start: start, end: start.addingTimeInterval(0.6)),
            try sleep(stage: .asleepREM, start: start.addingTimeInterval(0.6), end: start.addingTimeInterval(1.2))
        ]
        let composition = HealthKitFitnessComposition.compose(
            projection: projection(states: [try state(metric: .sleep, observations: samples)]),
            selectedDate: now
        )
        let trends = composition.snapshot.sleepDetail.trends
        XCTAssertEqual(composition.snapshot.sleepDetail.duration.value, "2 s")
        XCTAssertEqual(trends.first(where: { $0.id == .core })?.metric.value, "1 s")
        XCTAssertEqual(trends.first(where: { $0.id == .rem })?.metric.value, "1 s")
        XCTAssertNil(trends.first(where: { $0.id == .deep })?.metric.value)
    }

    // MARK: - sourceDerivedSleepDurationHours equivalence with the UI path
    //
    // `WidgetSnapshotPublisher` reads sleep duration exclusively through
    // `sourceDerivedSleepDurationHours`, a raw-value seam that must never
    // diverge from what `sleepDetail`/`sourceDerivedSleepMetrics` (the UI
    // path) derives from the identical projection. These three tests guard
    // that seam directly, since a silent drift there would let the widget
    // publish a sleep duration the app's own UI would refuse to show.

    func testSourceDerivedSleepDurationHoursEqualsUIPathForFullyStagedObservedNight() throws {
        // Each stage kept under 60s so `formatDuration` always emits the
        // simple "<n> s" form (matching the style already used by
        // `testSleepDurationReconcilesWithRoundedObservedStageTotals`),
        // which lets this test parse the UI-rendered totals back to seconds
        // and compare them against the widget seam without duplicating the
        // summation logic under test.
        let start = now.addingTimeInterval(-45)
        let sleepSamples = [
            try sleep(stage: .asleepCore, start: start, end: start.addingTimeInterval(20)),
            try sleep(stage: .asleepDeep, start: start.addingTimeInterval(20), end: start.addingTimeInterval(33)),
            try sleep(stage: .asleepREM, start: start.addingTimeInterval(33), end: start.addingTimeInterval(45))
        ]
        let testProjection = projection(states: [try state(metric: .sleep, observations: sleepSamples)])
        let composition = HealthKitFitnessComposition.compose(projection: testProjection, selectedDate: now)

        // The UI path: sum the exact per-stage second totals backing
        // `sleepDetail.trends`, the same fields the Fitness screen renders.
        let trends = composition.snapshot.sleepDetail.trends
        func stageSeconds(_ id: FitnessSleepTrendID) -> TimeInterval {
            guard let value = trends.first(where: { $0.id == id })?.metric.value,
                  let digits = value.split(separator: " ").first else { return 0 }
            return TimeInterval(digits) ?? 0
        }
        let uiDerivedSeconds = stageSeconds(.core) + stageSeconds(.deep) + stageSeconds(.rem)

        let widgetDerived = try XCTUnwrap(HealthKitFitnessComposition.sourceDerivedSleepDurationHours(
            from: testProjection,
            selectedDate: now
        ))

        XCTAssertEqual(composition.snapshot.sleepDetail.night.state, .observed)
        XCTAssertEqual(widgetDerived.hours * 3_600, uiDerivedSeconds, accuracy: 0.001)
        XCTAssertEqual(widgetDerived.hours * 3_600, 45, accuracy: 0.001)
        XCTAssertEqual(composition.snapshot.sleepDetail.duration.value, "45 s")
    }

    func testSourceDerivedSleepDurationHoursMatchesUIPathWhenSampleHasUnsupportedStage() throws {
        let start = now.addingTimeInterval(-3_000)
        let unsupportedStages: [HealthKitSleepStage] = [.inBed, .asleepUnspecified, .unknown(rawValue: 99)]
        for unsupported in unsupportedStages {
            let sleepSamples = [
                try sleep(stage: .asleepCore, start: start, end: start.addingTimeInterval(1_500)),
                try sleep(stage: unsupported, start: start.addingTimeInterval(1_500), end: start.addingTimeInterval(3_000))
            ]
            let testProjection = projection(states: [try state(metric: .sleep, observations: sleepSamples)])

            // The widget seam exposes exactly the named-stage sum (1_500 s);
            // the unnamed interval is excluded, never counted as asleep.
            let widgetDerived = try XCTUnwrap(
                HealthKitFitnessComposition.sourceDerivedSleepDurationHours(
                    from: testProjection,
                    selectedDate: now
                ),
                "Expected a partial named-stage sum for unsupported stage \(unsupported)"
            )
            XCTAssertEqual(widgetDerived.hours * 3_600, 1_500, accuracy: 0.001)

            // The UI path stays equivalent to the widget seam and labels the
            // reduced coverage as Partial.
            let composition = HealthKitFitnessComposition.compose(projection: testProjection, selectedDate: now)
            XCTAssertEqual(composition.snapshot.sleepDetail.duration.value, "25 min", "UI duration diverged for unsupported stage \(unsupported)")
            XCTAssertTrue(composition.snapshot.sleepDetail.duration.detail.contains("Partial"))
        }
    }

    func testSourceDerivedSleepDurationHoursIsNilForNonObservedSleepState() throws {
        let start = now.addingTimeInterval(-3_000)
        let sleepSamples = [
            try sleep(stage: .asleepCore, start: start, end: start.addingTimeInterval(1_500)),
            try sleep(stage: .asleepREM, start: start.addingTimeInterval(1_500), end: start.addingTimeInterval(3_000))
        ]
        // `.conflict` is intentionally excluded from this sweep: a bare
        // `.conflict` syncState with no actual conflicting sample for the
        // selected day resolves to `.observed` (see `selectSleep`'s comment
        // that a raw conflict elsewhere in the projection does not poison a
        // clean selected bucket). A real, selected-day conflict is covered
        // as its own case below.
        for syncState in [HealthKitSyncState.partial, .stale, .readIndeterminate, .error, .neverSynced] {
            let testProjection = projection(states: [try state(metric: .sleep, observations: sleepSamples, syncState: syncState)])

            let widgetDerived = HealthKitFitnessComposition.sourceDerivedSleepDurationHours(
                from: testProjection,
                selectedDate: now
            )
            XCTAssertNil(widgetDerived, "Expected nil for non-observed sleep sync state \(syncState)")
        }

        // A genuine selected-day conflict (not just a bare `.conflict`
        // syncState) must also gate the widget seam to nil.
        let identity = sleepSamples[0].identity
        let changed = try sleep(
            stage: .asleepDeep,
            start: start,
            end: start.addingTimeInterval(1_500),
            uuid: identity.uuid
        )
        let conflict = HealthKitObservationConflict(
            metric: .sleep,
            identity: identity,
            existing: sleepSamples[0],
            incoming: changed
        )
        let conflictedProjection = projection(states: [
            try state(metric: .sleep, observations: sleepSamples, conflicts: [conflict])
        ])
        let conflictedWidgetDerived = HealthKitFitnessComposition.sourceDerivedSleepDurationHours(
            from: conflictedProjection,
            selectedDate: now
        )
        XCTAssertNil(conflictedWidgetDerived, "Expected nil for a genuine selected-day sleep conflict")
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

    func testSelectedSleepDayKeepsAdjacentNightsSeparateAndEmptyDayUnavailable() throws {
        let day12 = try XCTUnwrap(calendar.date(from: DateComponents(year: 2023, month: 11, day: 12)))
        let day13 = try XCTUnwrap(calendar.date(byAdding: .day, value: 1, to: day12))
        let day14 = try XCTUnwrap(calendar.date(byAdding: .day, value: 2, to: day12))
        let nightOneStart = try XCTUnwrap(calendar.date(byAdding: .hour, value: 22, to: day12))
        let nightOneEnd = try XCTUnwrap(calendar.date(byAdding: .hour, value: 7, to: day13))
        let nightTwoStart = try XCTUnwrap(calendar.date(byAdding: .hour, value: 22, to: day13))
        let nightTwoEnd = try XCTUnwrap(calendar.date(byAdding: .hour, value: 7, to: day14))
        let first = try sleep(
            stage: .asleepCore,
            start: nightOneStart,
            end: nightOneEnd,
            provenance: try provenance(bundle: "com.example.first-night")
        )
        let second = try sleep(
            stage: .asleepREM,
            start: nightTwoStart,
            end: nightTwoEnd,
            provenance: try provenance(bundle: "com.example.second-night")
        )
        let retained = projection(
            states: [try state(metric: .sleep, observations: [first, second])],
            start: day12,
            end: now.addingTimeInterval(1)
        )

        let firstDay = HealthKitFitnessComposition.compose(
            projection: retained,
            selectedDate: day13.addingTimeInterval(12 * 3_600)
        )
        XCTAssertEqual(firstDay.sleepState, .observed)
        XCTAssertEqual(firstDay.snapshot.sleepDetail.night.start, nightOneStart)
        XCTAssertEqual(firstDay.snapshot.sleepDetail.night.end, nightOneEnd)
        XCTAssertEqual(firstDay.snapshot.sleepDetail.night.stageSamples.map(\.stage), [.core])
        XCTAssertEqual(firstDay.snapshot.sleepDetail.duration.value, "9h 0m")
        XCTAssertTrue(firstDay.evidence[.sleep]?.source.contains("first-night") == true)
        XCTAssertFalse(firstDay.evidence[.sleep]?.source.contains("second-night") == true)

        let secondDay = HealthKitFitnessComposition.compose(
            projection: retained,
            selectedDate: day14.addingTimeInterval(12 * 3_600)
        )
        XCTAssertEqual(secondDay.sleepState, .observed)
        XCTAssertEqual(secondDay.snapshot.sleepDetail.night.start, nightTwoStart)
        XCTAssertEqual(secondDay.snapshot.sleepDetail.night.end, nightTwoEnd)
        XCTAssertEqual(secondDay.snapshot.sleepDetail.night.stageSamples.map(\.stage), [.rem])
        XCTAssertEqual(secondDay.snapshot.sleepDetail.duration.value, "9h 0m")
        XCTAssertTrue(secondDay.evidence[.sleep]?.source.contains("second-night") == true)
        XCTAssertFalse(secondDay.evidence[.sleep]?.source.contains("first-night") == true)

        let emptyDay = HealthKitFitnessComposition.compose(
            projection: retained,
            selectedDate: day12.addingTimeInterval(12 * 3_600)
        )
        XCTAssertEqual(emptyDay.sleepState, .unavailable)
        XCTAssertNil(emptyDay.snapshot.sleepDetail.night.start)
        XCTAssertNil(emptyDay.snapshot.sleepDetail.night.end)
        XCTAssertTrue(emptyDay.snapshot.sleepDetail.night.stageSamples.isEmpty)
        XCTAssertFalse(emptyDay.evidence[.sleep]?.source.contains("first-night") == true)
        XCTAssertFalse(emptyDay.evidence[.sleep]?.source.contains("second-night") == true)
    }

    func testEmptySelectedSleepDayPreservesIndeterminateAndErrorStates() throws {
        let selected = try XCTUnwrap(calendar.date(from: DateComponents(year: 2023, month: 11, day: 14, hour: 12)))
        let indeterminate = HealthKitFitnessComposition.compose(
            projection: projection(states: [try state(metric: .sleep, syncState: .readIndeterminate)]),
            selectedDate: selected
        )
        XCTAssertEqual(indeterminate.sleepState, .readIndeterminate)
        XCTAssertTrue(indeterminate.snapshot.sleepDetail.night.evidence.isUnavailable)

        let failed = HealthKitFitnessComposition.compose(
            projection: projection(states: [try state(metric: .sleep, syncState: .error)]),
            selectedDate: selected
        )
        XCTAssertEqual(failed.sleepState, .error)
        XCTAssertTrue(failed.snapshot.sleepDetail.night.evidence.isUnavailable)
    }

    func testInvalidSelectedDateFailsClosedWithoutCalendarBucketing() throws {
        let invalid = Date(timeIntervalSinceReferenceDate: .nan)
        let composition = HealthKitFitnessComposition.compose(
            projection: projection(states: [try state(metric: .steps)]),
            selectedDate: invalid
        )
        XCTAssertEqual(composition.metricStates[.steps], .unavailable)
        XCTAssertEqual(composition.sleepState, .unavailable)
        XCTAssertEqual(composition.workoutState, .unavailable)
        XCTAssertTrue(composition.snapshot.workouts.isEmpty)
        XCTAssertFalse(composition.snapshot.source.freshness.lowercased().contains("nan"))
    }

    func testSleepEndAtLocalDayBoundaryBelongsToFollowingDay() throws {
        let day13 = try XCTUnwrap(calendar.date(from: DateComponents(year: 2023, month: 11, day: 13)))
        let day14 = try XCTUnwrap(calendar.date(byAdding: .day, value: 1, to: day13))
        let start = try XCTUnwrap(calendar.date(byAdding: .hour, value: 23, to: day13))
        let boundarySample = try sleep(stage: .asleepCore, start: start, end: day14)
        let retained = projection(
            states: [try state(metric: .sleep, observations: [boundarySample])],
            start: day13,
            end: now.addingTimeInterval(1)
        )

        let priorDay = HealthKitFitnessComposition.compose(
            projection: retained,
            selectedDate: day13.addingTimeInterval(12 * 3_600)
        )
        XCTAssertEqual(priorDay.sleepState, .unavailable)
        XCTAssertNil(priorDay.snapshot.sleepDetail.night.start)

        let wakeDay = HealthKitFitnessComposition.compose(
            projection: retained,
            selectedDate: day14.addingTimeInterval(12 * 3_600)
        )
        XCTAssertEqual(wakeDay.sleepState, .observed)
        XCTAssertEqual(wakeDay.snapshot.sleepDetail.night.start, start)
        XCTAssertEqual(wakeDay.snapshot.sleepDetail.night.end, day14)
        XCTAssertEqual(wakeDay.snapshot.sleepDetail.night.boundary?.name, "Selected sleep day (end-date bucket)")
    }

    func testSleepConflictOnlyPoisonsItsSelectedEndDateBucket() throws {
        let day12 = try XCTUnwrap(calendar.date(from: DateComponents(year: 2023, month: 11, day: 12)))
        let day13 = try XCTUnwrap(calendar.date(byAdding: .day, value: 1, to: day12))
        let day14 = try XCTUnwrap(calendar.date(byAdding: .day, value: 2, to: day12))
        let identity = UUID()
        let conflictedStart = try XCTUnwrap(calendar.date(byAdding: .hour, value: 22, to: day12))
        let conflictedEnd = try XCTUnwrap(calendar.date(byAdding: .hour, value: 6, to: day13))
        let existing = try sleep(stage: .asleepCore, start: conflictedStart, end: conflictedEnd, uuid: identity)
        let incoming = try sleep(stage: .asleepREM, start: conflictedStart, end: conflictedEnd, uuid: identity)
        let conflict = HealthKitObservationConflict(
            metric: .sleep,
            identity: existing.identity,
            existing: existing,
            incoming: incoming
        )
        let cleanStart = try XCTUnwrap(calendar.date(byAdding: .hour, value: 22, to: day13))
        let cleanEnd = try XCTUnwrap(calendar.date(byAdding: .hour, value: 7, to: day14))
        let clean = try sleep(stage: .asleepDeep, start: cleanStart, end: cleanEnd)
        let retained = projection(
            states: [try state(metric: .sleep, observations: [existing, clean], conflicts: [conflict])],
            start: day12,
            end: now.addingTimeInterval(1)
        )

        let conflictedDay = HealthKitFitnessComposition.compose(
            projection: retained,
            selectedDate: day13.addingTimeInterval(12 * 3_600)
        )
        XCTAssertEqual(conflictedDay.sleepState, .conflict)
        XCTAssertEqual(conflictedDay.snapshot.sleepDetail.night.state.label, "Conflict")
        XCTAssertTrue(conflictedDay.snapshot.sleepDetail.night.evidence.isUnavailable)
        XCTAssertNil(conflictedDay.snapshot.sleepDetail.duration.value)
        XCTAssertNil(conflictedDay.snapshot.sleepDetail.trends.first(where: { $0.id == .deep })?.metric.value)

        let cleanDay = HealthKitFitnessComposition.compose(
            projection: retained,
            selectedDate: day14.addingTimeInterval(12 * 3_600)
        )
        XCTAssertEqual(cleanDay.sleepState, .observed)
        XCTAssertEqual(cleanDay.snapshot.sleepDetail.night.start, cleanStart)
        XCTAssertEqual(cleanDay.snapshot.sleepDetail.night.end, cleanEnd)
        XCTAssertEqual(cleanDay.snapshot.sleepDetail.night.stageSamples.map(\.stage), [.deep])
        XCTAssertEqual(cleanDay.snapshot.sleepDetail.duration.value, "9h 0m")
    }

    func testAggregateFreshnessDoesNotLeakWorkoutFromAnotherSelectedDay() throws {
        let day13 = try XCTUnwrap(calendar.date(from: DateComponents(year: 2023, month: 11, day: 13)))
        let day14 = try XCTUnwrap(calendar.date(byAdding: .day, value: 1, to: day13))
        let selectedObservation = try quantity(
            metric: .steps,
            value: 2_000,
            at: try XCTUnwrap(calendar.date(byAdding: .hour, value: 9, to: day13))
        )
        let otherDayWorkout = try workout(
            start: try XCTUnwrap(calendar.date(byAdding: .hour, value: 18, to: day14)),
            duration: 1_800
        )
        let retained = projection(
            states: [
                try state(metric: .steps, observations: [selectedObservation]),
                try state(metric: .workout, observations: [otherDayWorkout])
            ],
            start: day13,
            end: now.addingTimeInterval(1)
        )

        let composition = HealthKitFitnessComposition.compose(
            projection: retained,
            selectedDate: day13.addingTimeInterval(12 * 3_600)
        )
        XCTAssertTrue(composition.snapshot.source.freshness.contains("2023-11-13"))
        XCTAssertFalse(composition.snapshot.source.freshness.contains("2023-11-14"))
        XCTAssertTrue(composition.snapshot.workouts.isEmpty)
    }

    func testRetainedHealthDataSettingsCountsSamplesCategoriesAndConfirmedHelio() throws {
        let confirmedEnd = now
        let otherEnd = now.addingTimeInterval(-60)
        let settings = RetainedHealthDataSettings.from(
            projection: projection(states: [
                try state(metric: .restingHeartRate, observations: [
                    try quantity(metric: .restingHeartRate, value: 52, at: now, provenance: try helioProvenance())
                ]),
                try state(metric: .steps, observations: [
                    try quantity(metric: .steps, value: 2_000, at: otherEnd)
                ])
            ])
        )

        XCTAssertEqual(settings.status, .observed)
        XCTAssertEqual(settings.sampleCount, 2)
        XCTAssertEqual(settings.categoryCount, 2)
        XCTAssertEqual(settings.confirmedHelioCategoryCount, 1)
        XCTAssertEqual(settings.latestObservation, confirmedEnd)
    }

    func testRetainedHealthDataSettingsEmptyPreservesReadIndeterminate() throws {
        let settings = RetainedHealthDataSettings.from(
            projection: projection(states: [try state(metric: .bodyMass, syncState: .readIndeterminate)])
        )

        XCTAssertEqual(settings.status, .readIndeterminate)
        XCTAssertEqual(settings.sampleCount, 0)
        XCTAssertEqual(settings.categoryCount, 0)
        XCTAssertNil(settings.latestObservation)
    }

    func testRetainedHealthDataSettingsPrioritizesConflictAndPartialOnlyWhenContributing() throws {
        let sample = try quantity(metric: .bodyMass, value: 72, at: now)
        let changed = try quantity(metric: .bodyMass, value: 73, at: now, uuid: sample.identity.uuid)
        let conflict = HealthKitObservationConflict(
            metric: .bodyMass,
            identity: sample.identity,
            existing: sample,
            incoming: changed
        )
        let conflicted = RetainedHealthDataSettings.from(
            projection: projection(states: [try state(
                metric: .bodyMass,
                observations: [sample],
                conflicts: [conflict]
            )])
        )
        XCTAssertEqual(conflicted.status, .conflict)
        XCTAssertEqual(conflicted.sampleCount, 1)

        let partial = RetainedHealthDataSettings.from(
            projection: projection(states: [try state(
                metric: .steps,
                observations: [try quantity(metric: .steps, value: 1_000, at: now)],
                syncState: .partial
            )])
        )
        XCTAssertEqual(partial.status, .partial)
        XCTAssertEqual(partial.sampleCount, 1)

        let retainedButUnavailable = RetainedHealthDataSettings.from(
            projection: projection(states: [try state(
                metric: .steps,
                observations: [try quantity(metric: .steps, value: 250, at: now)],
                syncState: .neverSynced
            )])
        )
        XCTAssertEqual(retainedButUnavailable.status, .unavailable)

        let indeterminate = RetainedHealthDataSettings.from(
            projection: projection(states: [try state(
                metric: .steps,
                observations: [try quantity(metric: .steps, value: 500, at: now)],
                syncState: .readIndeterminate
            )])
        )
        XCTAssertEqual(indeterminate.status, .readIndeterminate)
    }

    func testRetainedHealthDataSettingsPreservesEmptyWorkoutStates() throws {
        let cases: [(HealthKitSyncState, RetainedHealthDataSettings.Status)] = [
            (.error, .error),
            (.conflict, .conflict),
            (.readIndeterminate, .readIndeterminate),
            (.stale, .stale),
            (.partial, .partial),
            (.neverSynced, .unavailable)
        ]

        for (syncState, expected) in cases {
            let settings = RetainedHealthDataSettings.from(
                projection: projection(states: [try state(metric: .workout, syncState: syncState)])
            )
            XCTAssertEqual(settings.status, expected, "Unexpected workout state for \(syncState)")
            XCTAssertEqual(settings.sampleCount, 0)
            XCTAssertEqual(settings.categoryCount, 0)
        }
    }

    func testRetainedHealthDataSettingsUsesUnfilteredPersistedQuantityConflictWhenWindowIsEmpty() throws {
        let existing = try quantity(metric: .bodyMass, value: 72, at: now)
        let incoming = try quantity(metric: .bodyMass, value: 73, at: now, uuid: existing.identity.uuid)
        let conflict = HealthKitObservationConflict(
            metric: .bodyMass,
            identity: existing.identity,
            existing: existing,
            incoming: incoming
        )
        let retained = projection(
            states: [try state(metric: .bodyMass, observations: [existing], conflicts: [conflict])],
            start: now.addingTimeInterval(-2 * 86_400),
            end: now.addingTimeInterval(-86_400)
        )

        XCTAssertTrue(retained.metric(.bodyMass).observations.isEmpty)
        XCTAssertEqual(retained.metric(.bodyMass).state, .unavailable)
        XCTAssertEqual(retained.metric(.bodyMass).persistedState, .conflict)
        XCTAssertEqual(RetainedHealthDataSettings.from(projection: retained).status, .conflict)
    }

    func testRetainedHealthDataSettingsKeepsEmptySleepConflictScopedToItsProjection() throws {
        let start = now.addingTimeInterval(-2 * 86_400)
        let end = now.addingTimeInterval(-86_400)
        let existing = try sleep(
            stage: .asleepCore,
            start: now.addingTimeInterval(-3_600),
            end: now.addingTimeInterval(-1_800)
        )
        let incoming = try sleep(
            stage: .asleepREM,
            start: now.addingTimeInterval(-3_600),
            end: now.addingTimeInterval(-1_800),
            uuid: existing.identity.uuid
        )
        let conflict = HealthKitObservationConflict(
            metric: .sleep,
            identity: existing.identity,
            existing: existing,
            incoming: incoming
        )
        let retained = projection(
            states: [try state(metric: .sleep, observations: [existing], conflicts: [conflict])],
            start: start,
            end: end
        )

        XCTAssertTrue(retained.sleep.samples.isEmpty)
        XCTAssertEqual(retained.sleep.state, .unavailable)
        XCTAssertEqual(retained.sleep.persistedState, .conflict)
        XCTAssertEqual(RetainedHealthDataSettings.from(projection: retained).status, .conflict)
    }

    func testRetainedHealthDataSettingsDoesNotLeakFilteredSleepConflict() throws {
        let existing = try sleep(
            stage: .asleepCore,
            start: now.addingTimeInterval(-3_600),
            end: now.addingTimeInterval(-1_800)
        )
        let incoming = try sleep(
            stage: .asleepREM,
            start: now.addingTimeInterval(-3_600),
            end: now.addingTimeInterval(-1_800),
            uuid: existing.identity.uuid
        )
        let conflict = HealthKitObservationConflict(
            metric: .sleep,
            identity: existing.identity,
            existing: existing,
            incoming: incoming
        )
        let retained = HealthKitFitnessProjection(
            states: [try state(metric: .sleep, observations: [existing], conflicts: [conflict])],
            window: DateInterval(
                start: now.addingTimeInterval(-2 * 86_400),
                end: now.addingTimeInterval(-86_400)
            ),
            sourceFilter: .exact(bundleIdentifier: "com.other.source"),
            calendar: calendar
        )

        XCTAssertTrue(retained.sleep.samples.isEmpty)
        XCTAssertEqual(retained.sleep.state, .unavailable)
        XCTAssertEqual(retained.sleep.persistedState, .unavailable)
        XCTAssertEqual(RetainedHealthDataSettings.from(projection: retained).status, .unavailable)
    }

    func testRetainedHealthDataSettingsInvalidProjectionIsError() {
        let invalid = HealthKitFitnessProjection(
            states: [HealthKitStoredMetricState.empty(for: .bodyMass)],
            window: DateInterval(
                start: now.addingTimeInterval(-HealthKitFitnessProjection.maximumWindow - 1),
                end: now
            ),
            calendar: calendar
        )

        let settings = RetainedHealthDataSettings.from(projection: invalid)
        XCTAssertEqual(settings.status, .error)
        XCTAssertEqual(settings.sampleCount, 0)
        XCTAssertEqual(settings.categoryCount, 0)
    }

    // MARK: - Full coverage of synced metrics

    func testSyncedHeartRateReachesTheHealthMonitorSurface() throws {
        let sample = try quantity(metric: .heartRate, value: 61.4, at: now)
        let composition = HealthKitFitnessComposition.compose(
            projection: projection(states: [try state(metric: .heartRate, observations: [sample])]),
            selectedDate: now
        )

        let card = try XCTUnwrap(
            composition.snapshot.healthMonitor.first(where: { $0.title == "Heart rate" }),
            "A synced heart-rate observation must be displayed"
        )
        XCTAssertEqual(card.value, "61.4")
        XCTAssertEqual(card.unit, "bpm")
        XCTAssertEqual(composition.metricStates[.heartRate], .observed)

        let empty = HealthKitFitnessComposition.compose(
            projection: projection(states: [try state(metric: .heartRate, syncState: .readIndeterminate)]),
            selectedDate: now
        )
        XCTAssertNil(empty.snapshot.healthMonitor.first(where: { $0.title == "Heart rate" })?.value)
        XCTAssertEqual(empty.metricStates[.heartRate], .readIndeterminate)
    }

    func testSyncedWaterAndCaffeineDayTotalsReachTheNutritionSnapshot() throws {
        let water = try quantity(metric: .water, value: 1_250, at: now)
        let caffeine = try quantity(metric: .caffeine, value: 180, at: now)
        let composition = HealthKitFitnessComposition.compose(
            projection: projection(states: [
                try state(metric: .water, observations: [water]),
                try state(metric: .caffeine, observations: [caffeine])
            ]),
            selectedDate: now
        )

        XCTAssertEqual(composition.snapshot.nutrition.hydrationMilliliters, 1_250)
        XCTAssertEqual(composition.snapshot.nutrition.caffeineMilligrams, 180)
        XCTAssertNil(composition.snapshot.nutrition.hydrationTargetMilliliters, "No target is fabricated")

        // Non-observed durable states stay nil instead of becoming zero.
        let indeterminate = HealthKitFitnessComposition.compose(
            projection: projection(states: [
                try state(metric: .water, syncState: .readIndeterminate),
                try state(metric: .caffeine, observations: [caffeine], syncState: .partial)
            ]),
            selectedDate: now
        )
        XCTAssertNil(indeterminate.snapshot.nutrition.hydrationMilliliters)
        XCTAssertNil(indeterminate.snapshot.nutrition.caffeineMilligrams)
    }

    func testObservedSleepNightPopulatesTheTodaySleepCardWithExactDuration() throws {
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
        XCTAssertEqual(composition.snapshot.sleep.value, "33 min 20s")
        XCTAssertEqual(composition.snapshot.sleep.quality, .observed)
        XCTAssertTrue(composition.snapshot.sleep.detail.contains("Exact HealthKit interval sum"))

        // Without a validated exact sum the card stays unavailable with a
        // reason rather than showing zero.
        let empty = HealthKitFitnessComposition.compose(
            projection: projection(states: [try state(metric: .sleep, syncState: .neverSynced)]),
            selectedDate: now
        )
        XCTAssertNil(empty.snapshot.sleep.value)
        XCTAssertEqual(empty.snapshot.sleep.quality, .unavailable)
        XCTAssertTrue(empty.snapshot.sleep.detail.contains("Unavailable"))
    }
}
