import XCTest
@testable import LifeOS

final class HealthKitFitnessProjectionTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_700_000_000)

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
        at start: Date,
        end: Date? = nil,
        provenance: HealthKitProvenance? = nil,
        uuid: UUID = UUID()
    ) throws -> HealthKitObservation {
        let value = try HealthKitQuantityValue(metric: metric, value: value, unit: try XCTUnwrap(metric.canonicalUnit))
        return try HealthKitObservation(
            metric: metric,
            identity: HealthKitSampleIdentity(uuid: uuid),
            value: .quantity(value),
            startDate: start,
            endDate: end ?? start,
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
        let value = try HealthKitSleepValue(stage: stage, timeZoneIdentifier: "Europe/Berlin")
        return try HealthKitObservation(
            metric: .sleep,
            identity: HealthKitSampleIdentity(uuid: UUID()),
            value: .sleep(value),
            startDate: start,
            endDate: end,
            provenance: try provenance ?? self.provenance(),
            now: now
        )
    }

    private func workout(
        start: Date,
        duration: Double,
        activityType: Int = 37,
        energy: Double? = 210,
        provenance: HealthKitProvenance? = nil,
        uuid: UUID = UUID()
    ) throws -> HealthKitObservation {
        let value = try HealthKitWorkoutValue(
            activityTypeRawValue: activityType,
            durationSeconds: duration,
            activeEnergyKilocalories: energy
        )
        return try HealthKitObservation(
            metric: .workout,
            identity: HealthKitSampleIdentity(uuid: uuid),
            value: .workout(value),
            startDate: start,
            endDate: start.addingTimeInterval(duration),
            provenance: try provenance ?? self.provenance(),
            now: now
        )
    }

    private func state(
        metric: HealthKitMetricID,
        observations: [HealthKitObservation] = [],
        tombstones: [HealthKitDeletionTombstone] = [],
        conflicts: [HealthKitObservationConflict] = [],
        syncState: HealthKitSyncState = .synced,
        committedAt: Date? = nil
    ) throws -> HealthKitStoredMetricState {
        let projection = try HealthKitMetricProjection(
            metric: metric,
            observations: observations,
            tombstones: tombstones,
            conflicts: conflicts,
            lastCommittedAt: committedAt ?? now,
            syncState: syncState
        )
        return HealthKitStoredMetricState(projection: projection)
    }

    private func window(_ start: Date, _ end: Date) -> DateInterval {
        DateInterval(start: start, end: end)
    }

    func testEmptyStateIsUnavailableAndDoesNotFabricateZeroOrScore() throws {
        let projection = HealthKitFitnessProjection(
            states: [HealthKitStoredMetricState.empty(for: .restingHeartRate)],
            window: window(now.addingTimeInterval(-3_600), now)
        )

        XCTAssertEqual(projection.restingHeartRate.state, .unavailable)
        XCTAssertNil(projection.restingHeartRate.latest)
        XCTAssertNil(projection.restingHeartRate.value)
        XCTAssertTrue(projection.restingHeartRate.reason?.contains("No") == true)
        XCTAssertTrue(projection.workouts.isEmpty)
        XCTAssertTrue(projection.dailyTotals.values.allSatisfy { $0[.steps]?.total == nil || $0[.steps]?.samples.isEmpty == true })
    }

    func testSourceFilterSelectsOnlyExactProvenanceAndDoesNotLeakInventory() throws {
        let first = try quantity(
            metric: .restingHeartRate,
            value: 61,
            at: now.addingTimeInterval(-600),
            provenance: provenance()
        )
        let helio = try quantity(
            metric: .restingHeartRate,
            value: 54,
            at: now.addingTimeInterval(-300),
            provenance: helioProvenance()
        )
        let stored = try state(metric: .restingHeartRate, observations: [first, helio])
        let projection = HealthKitFitnessProjection(
            states: [stored],
            window: window(now.addingTimeInterval(-3_600), now),
            sourceFilter: .helioMatch(.confirmed)
        )

        XCTAssertEqual(projection.restingHeartRate.observations.count, 1)
        XCTAssertEqual(projection.restingHeartRate.latest?.quantity.value, 54)
        XCTAssertEqual(projection.restingHeartRate.sourceMatches, [.confirmed])
        XCTAssertEqual(projection.restingHeartRate.latest?.provenance.helioMatch, .confirmed)
    }

    func testWindowUsesHalfOpenBoundariesAndDailyTotalsUseSampleStart() throws {
        let start = now.addingTimeInterval(-3_600)
        let included = try quantity(metric: .water, value: 250, at: start)
        let excluded = try quantity(metric: .water, value: 999, at: now)
        let crossMidnight = try quantity(
            metric: .water,
            value: 100,
            at: start.addingTimeInterval(30),
            end: start.addingTimeInterval(90)
        )
        let stored = try state(metric: .water, observations: [included, excluded, crossMidnight])
        let projection = HealthKitFitnessProjection(
            states: [stored],
            window: window(start, now)
        )

        XCTAssertEqual(projection.metric(.water).observations.count, 2)
        let day = try XCTUnwrap(projection.dailyTotal(for: .water, on: start))
        XCTAssertEqual(day.total?.value, 350)
        XCTAssertEqual(day.total?.unit, .milliliters)
        XCTAssertFalse(day.samples.contains { $0.quantity.value == 999 })
    }

    func testPartialStaleAndConflictStatesRemainDistinct() throws {
        let sample = try quantity(metric: .bodyMass, value: 72, at: now.addingTimeInterval(-60))
        let partial = HealthKitFitnessProjection(
            states: [try state(metric: .bodyMass, observations: [sample], syncState: .partial)],
            window: window(now.addingTimeInterval(-300), now)
        )
        XCTAssertEqual(partial.bodyMass.state, .partial)

        let stale = HealthKitFitnessProjection(
            states: [try state(metric: .bodyMass, observations: [sample], syncState: .stale)],
            window: window(now.addingTimeInterval(-300), now)
        )
        XCTAssertEqual(stale.bodyMass.state, .stale)

        let changed = try quantity(metric: .bodyMass, value: 73, at: sample.startDate, uuid: sample.identity.uuid)
        let conflict = HealthKitObservationConflict(metric: .bodyMass, identity: sample.identity, existing: sample, incoming: changed)
        let conflicted = HealthKitFitnessProjection(
            states: [try state(metric: .bodyMass, observations: [sample], conflicts: [conflict])],
            window: window(now.addingTimeInterval(-300), now)
        )
        XCTAssertEqual(conflicted.bodyMass.state, .conflict)
        XCTAssertEqual(conflicted.bodyMass.conflicts.count, 1)
    }

    func testCanonicalUnitsAndDailyTotalsPreserveMetricSemantics() throws {
        let energy = try state(metric: .activeEnergy, observations: [
            try quantity(metric: .activeEnergy, value: 120, at: now.addingTimeInterval(-500)),
            try quantity(metric: .activeEnergy, value: 80, at: now.addingTimeInterval(-400))
        ])
        let hrv = try state(metric: .heartRateVariabilitySDNN, observations: [
            try quantity(metric: .heartRateVariabilitySDNN, value: 42, at: now.addingTimeInterval(-200))
        ])
        let projection = HealthKitFitnessProjection(
            states: [energy, hrv],
            window: window(now.addingTimeInterval(-3_600), now)
        )

        XCTAssertEqual(projection.metric(.heartRateVariabilitySDNN).value?.unit, .milliseconds)
        XCTAssertEqual(projection.dailyTotal(for: .activeEnergy, on: now)?.total?.value, 200)
        XCTAssertEqual(projection.dailyTotal(for: .activeEnergy, on: now)?.total?.unit, .kilocalories)
        XCTAssertNotEqual(projection.metric(.heartRateVariabilitySDNN).value?.value, 200, "No cross-metric or score formula is applied")
    }

    func testSleepPreservesStagesIntervalAndSourceEvidence() throws {
        let start = now.addingTimeInterval(-1_800)
        let samples = [
            try sleep(stage: .asleepCore, start: start, end: start.addingTimeInterval(600)),
            try sleep(stage: .asleepREM, start: start.addingTimeInterval(600), end: start.addingTimeInterval(1_200))
        ]
        let projection = HealthKitFitnessProjection(
            states: [try state(metric: .sleep, observations: samples)],
            window: window(start.addingTimeInterval(60), now)
        )

        XCTAssertEqual(projection.sleep.state, .observed)
        XCTAssertEqual(projection.sleep.samples.map(\.stage), [.asleepCore, .asleepREM])
        XCTAssertEqual(projection.sleep.interval?.duration, 1_200)
        XCTAssertEqual(projection.sleep.samples.first?.timeZoneIdentifier, "Europe/Berlin")
        XCTAssertFalse(projection.sleep.provenance.isEmpty)
    }

    func testWorkoutPreservesRawActivityDurationAndEnergyWithoutLoadScore() throws {
        let workout = try workout(start: now.addingTimeInterval(-900), duration: 600, activityType: 13, energy: 321)
        let projection = HealthKitFitnessProjection(
            states: [try state(metric: .workout, observations: [workout])],
            window: window(now.addingTimeInterval(-1_200), now)
        )

        let result = try XCTUnwrap(projection.workouts.first)
        XCTAssertEqual(result.activityTypeRawValue, 13)
        XCTAssertEqual(result.durationSeconds, 600)
        XCTAssertEqual(result.activeEnergyKilocalories, 321)
        XCTAssertEqual(result.state, .observed)
        XCTAssertEqual(projection.workouts.count, 1)
    }

    func testConflictingWorkoutIdentityProducesNoAcceptedWorkoutRecord() throws {
        let uuid = UUID()
        let first = try workout(start: now.addingTimeInterval(-900), duration: 600, uuid: uuid)
        let changed = try workout(start: now.addingTimeInterval(-900), duration: 900, uuid: uuid)
        let projection = HealthKitFitnessProjection(
            states: [try state(metric: .workout, observations: [first, changed])],
            window: window(now.addingTimeInterval(-1_200), now)
        )
        XCTAssertTrue(projection.workouts.isEmpty)
    }

    func testObservedStateOutsideSelectedWindowIsNotClaimedAsObserved() throws {
        let old = try quantity(metric: .restingHeartRate, value: 55, at: now.addingTimeInterval(-86_400))
        let projection = HealthKitFitnessProjection(
            states: [try state(metric: .restingHeartRate, observations: [old])],
            window: window(now.addingTimeInterval(-3_600), now)
        )

        XCTAssertEqual(projection.restingHeartRate.persistedState, .observed)
        XCTAssertEqual(projection.restingHeartRate.state, .unavailable)
        XCTAssertNil(projection.restingHeartRate.latest)
    }

    func testFilteredProjectionDoesNotLeakUnrelatedConflictPayloadOrState() throws {
        let uuid = UUID()
        let existing = try quantity(
            metric: .bodyMass,
            value: 72,
            at: now.addingTimeInterval(-60),
            provenance: provenance(bundle: "com.example.scale-a"),
            uuid: uuid
        )
        let incoming = try quantity(
            metric: .bodyMass,
            value: 73,
            at: now.addingTimeInterval(-60),
            provenance: provenance(bundle: "com.example.scale-b"),
            uuid: uuid
        )
        let conflict = HealthKitObservationConflict(metric: .bodyMass, identity: existing.identity, existing: existing, incoming: incoming)
        let tombstone = try HealthKitDeletionTombstone(metric: .bodyMass, identity: existing.identity, deletedAt: now)
        let stored = try state(metric: .bodyMass, observations: [existing], tombstones: [tombstone], conflicts: [conflict])

        let filtered = HealthKitFitnessProjection(
            states: [stored],
            window: window(now.addingTimeInterval(-300), now),
            sourceFilter: .sourceBundle("com.example.scale-a")
        )
        XCTAssertEqual(filtered.bodyMass.state, .observed)
        XCTAssertTrue(filtered.bodyMass.conflicts.isEmpty)
        XCTAssertTrue(filtered.bodyMass.tombstones.isEmpty)
        XCTAssertEqual(filtered.bodyMass.latest?.quantity.value, 72)

        let unfiltered = HealthKitFitnessProjection(
            states: [stored],
            window: window(now.addingTimeInterval(-300), now)
        )
        XCTAssertEqual(unfiltered.bodyMass.state, .conflict)
        XCTAssertEqual(unfiltered.bodyMass.conflicts.count, 1)
        XCTAssertEqual(unfiltered.bodyMass.tombstones.count, 1)
    }

    func testDuplicateMetricStatesAtSameCommitAreAnErrorAndNewestStateWinsOtherwise() throws {
        let first = try state(
            metric: .bodyMass,
            observations: [try quantity(metric: .bodyMass, value: 72, at: now.addingTimeInterval(-60))],
            committedAt: now
        )
        let second = try state(
            metric: .bodyMass,
            observations: [try quantity(metric: .bodyMass, value: 73, at: now.addingTimeInterval(-60))],
            committedAt: now
        )
        let duplicate = HealthKitFitnessProjection(
            states: [first, second],
            window: window(now.addingTimeInterval(-300), now)
        )
        XCTAssertTrue(duplicate.issues.contains(.duplicateMetricState(.bodyMass)))
        XCTAssertEqual(duplicate.bodyMass.state, .error)
        XCTAssertNil(duplicate.bodyMass.latest)

        let older = try state(
            metric: .bodyMass,
            observations: [try quantity(metric: .bodyMass, value: 70, at: now.addingTimeInterval(-60))],
            committedAt: now.addingTimeInterval(-60)
        )
        let newer = try state(
            metric: .bodyMass,
            observations: [try quantity(metric: .bodyMass, value: 74, at: now.addingTimeInterval(-30))],
            committedAt: now
        )
        let newest = HealthKitFitnessProjection(
            states: [older, newer],
            window: window(now.addingTimeInterval(-300), now)
        )
        XCTAssertTrue(newest.issues.isEmpty)
        XCTAssertEqual(newest.bodyMass.latest?.quantity.value, 74)
    }

    func testDailyTotalsDedupeExactIdentityAndFailClosedOnConflictingIdentity() throws {
        let uuid = UUID()
        let exact = try quantity(metric: .water, value: 250, at: now.addingTimeInterval(-120), uuid: uuid)
        let exactProjection = HealthKitFitnessProjection(
            states: [try state(metric: .water, observations: [exact, exact])],
            window: window(now.addingTimeInterval(-300), now)
        )
        let exactDay = try XCTUnwrap(exactProjection.dailyTotal(for: .water, on: now))
        XCTAssertEqual(exactDay.total?.value, 250)
        XCTAssertEqual(exactDay.samples.count, 1)

        let changed = try quantity(metric: .water, value: 400, at: exact.startDate, uuid: uuid)
        let conflictingProjection = HealthKitFitnessProjection(
            states: [try state(metric: .water, observations: [exact, changed])],
            window: window(now.addingTimeInterval(-300), now)
        )
        let conflictingDay = try XCTUnwrap(conflictingProjection.dailyTotal(for: .water, on: now))
        XCTAssertEqual(conflictingDay.state, .conflict)
        XCTAssertNil(conflictingDay.total)
        XCTAssertEqual(conflictingDay.conflicts.count, 1)
        XCTAssertEqual(conflictingProjection.metric(.water).state, .conflict)
        XCTAssertNil(conflictingProjection.metric(.water).latest)
    }

    func testConflictingDailyRevisionAcrossMidnightFailsClosedOnBothDays() throws {
        var berlin = Calendar(identifier: .gregorian)
        berlin.timeZone = try XCTUnwrap(TimeZone(identifier: "Europe/Berlin"))
        let currentDayStart = berlin.startOfDay(for: now)
        let firstDay = try XCTUnwrap(berlin.date(byAdding: .minute, value: -5, to: currentDayStart))
        let secondDay = try XCTUnwrap(berlin.date(byAdding: .minute, value: 10, to: firstDay))
        let uuid = UUID()
        let existing = try quantity(metric: .water, value: 250, at: firstDay, uuid: uuid)
        let incoming = try quantity(metric: .water, value: 400, at: secondDay, uuid: uuid)
        let projection = HealthKitFitnessProjection(
            states: [try state(metric: .water, observations: [existing, incoming])],
            window: DateInterval(
                start: berlin.startOfDay(for: firstDay),
                end: try XCTUnwrap(berlin.date(byAdding: .day, value: 1, to: berlin.startOfDay(for: secondDay)))
            ),
            calendar: berlin
        )

        let first = try XCTUnwrap(projection.dailyTotal(for: .water, on: firstDay))
        let second = try XCTUnwrap(projection.dailyTotal(for: .water, on: secondDay))
        XCTAssertEqual(first.state, .conflict)
        XCTAssertNil(first.total)
        XCTAssertEqual(second.state, .conflict)
        XCTAssertNil(second.total)
        XCTAssertEqual(first.conflicts.count, 1)
        XCTAssertEqual(second.conflicts.count, 1)
    }

    func testConflictingRevisionEnteringWindowCannotBecomeAcceptedTotal() throws {
        let uuid = UUID()
        let outside = try quantity(metric: .water, value: 250, at: now.addingTimeInterval(-600), uuid: uuid)
        let inside = try quantity(metric: .water, value: 400, at: now.addingTimeInterval(-120), uuid: uuid)
        let conflict = HealthKitObservationConflict(
            metric: .water,
            identity: outside.identity,
            existing: outside,
            incoming: inside
        )
        let projection = HealthKitFitnessProjection(
            states: [try state(metric: .water, observations: [inside], conflicts: [conflict])],
            window: window(now.addingTimeInterval(-300), now)
        )

        let day = try XCTUnwrap(projection.dailyTotal(for: .water, on: now))
        XCTAssertEqual(day.state, .conflict)
        XCTAssertNil(day.total)
        XCTAssertEqual(day.conflicts.count, 1)
        XCTAssertEqual(projection.metric(.water).state, .conflict)
        XCTAssertNil(projection.metric(.water).latest)
    }

    func testBucketCalendarAndTimeZoneAreRetainedAcrossBerlinSpringAndFallDST() throws {
        var berlin = Calendar(identifier: .gregorian)
        berlin.timeZone = try XCTUnwrap(TimeZone(identifier: "Europe/Berlin"))

        let springStart = try XCTUnwrap(berlin.date(from: DateComponents(year: 2023, month: 3, day: 26, hour: 1, minute: 30)))
        let springNext = try XCTUnwrap(berlin.date(byAdding: .day, value: 1, to: berlin.startOfDay(for: springStart)))
        let springProjection = HealthKitFitnessProjection(
            states: [try state(metric: .water, observations: [try quantity(metric: .water, value: 100, at: springStart)])],
            window: DateInterval(start: berlin.startOfDay(for: springStart), end: springNext.addingTimeInterval(86_400)),
            calendar: berlin
        )
        XCTAssertEqual(springProjection.bucketTimeZoneIdentifier, "Europe/Berlin")
        XCTAssertEqual(springProjection.bucketCalendarIdentifier, .gregorian)
        XCTAssertEqual(springProjection.dailyTotal(for: .water, on: springStart)?.total?.value, 100)

        let fallStart = try XCTUnwrap(berlin.date(from: DateComponents(year: 2023, month: 10, day: 29, hour: 1, minute: 30)))
        let fallNext = try XCTUnwrap(berlin.date(byAdding: .day, value: 1, to: berlin.startOfDay(for: fallStart)))
        let fallProjection = HealthKitFitnessProjection(
            states: [try state(metric: .water, observations: [try quantity(metric: .water, value: 200, at: fallStart)])],
            window: DateInterval(start: berlin.startOfDay(for: fallStart), end: fallNext.addingTimeInterval(86_400)),
            calendar: berlin
        )
        XCTAssertEqual(fallProjection.dailyTotal(for: .water, on: fallStart)?.total?.value, 200)
        XCTAssertEqual(fallProjection.dailyTotals.count, 2)
    }

    func testOversizedWindowOrStateSetProducesIssuesAndNoPartialBuckets() {
        let oversizedWindow = HealthKitFitnessProjection(
            states: [],
            window: window(now, now.addingTimeInterval(HealthKitFitnessProjection.maximumWindow + 1))
        )
        XCTAssertTrue(oversizedWindow.issues.contains(.windowTooLarge))
        XCTAssertFalse(oversizedWindow.isValid)
        XCTAssertTrue(oversizedWindow.dailyTotals.isEmpty)
        XCTAssertEqual(oversizedWindow.restingHeartRate.state, .error)

        let tooManyStates = Array(
            repeating: HealthKitStoredMetricState.empty(for: .water),
            count: HealthKitMetricID.allCases.count + 1
        )
        let oversizedStateSet = HealthKitFitnessProjection(
            states: tooManyStates,
            window: window(now.addingTimeInterval(-60), now)
        )
        XCTAssertTrue(oversizedStateSet.issues.contains(.tooManyStates))
        XCTAssertTrue(oversizedStateSet.dailyTotals.isEmpty)
    }
}
