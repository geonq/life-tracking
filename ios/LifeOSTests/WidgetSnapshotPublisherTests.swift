import XCTest
@testable import LifeOS

final class WidgetSnapshotPublisherTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_700_000_000)
    private let calendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Europe/Berlin")!
        return calendar
    }()

    // MARK: - Finance mapping

    private func financeSummary(
        spentAvailability: String = "observed",
        spentCents: Int = 45_000,
        observedAt: Date? = nil,
        freshness: String = "fresh"
    ) throws -> FinanceSummary {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let observed = formatter.string(from: observedAt ?? now.addingTimeInterval(-60))
        let unavailableProvenance: [String: Any] = [
            "source": "no-authorized-finance-source", "observedAt": observed,
            "freshness": "unknown", "quality": "unavailable", "connectorState": "unavailable"
        ]
        let unavailableMetric: [String: Any] = ["availability": "unavailable", "provenance": unavailableProvenance]
        var spentMetric: [String: Any]
        if spentAvailability == "observed" {
            let spentProvenance: [String: Any] = [
                "source": "test-observation", "observedAt": observed,
                "freshness": freshness, "quality": "observed", "connectorState": "healthy"
            ]
            spentMetric = ["availability": "observed", "provenance": spentProvenance, "amountCents": spentCents]
        } else {
            spentMetric = unavailableMetric
        }
        let payload: [String: Any] = [
            "generatedAt": formatter.string(from: now),
            "currency": "EUR",
            "monthlyIncome": unavailableMetric,
            "fixedCosts": unavailableMetric,
            "discretionaryBuffer": unavailableMetric,
            "spent": spentMetric,
            "savingsGoal": unavailableMetric,
            "saved": unavailableMetric
        ]
        return try FinanceSummary.decode(JSONSerialization.data(withJSONObject: payload), now: now)
    }

    func testFinanceObservedSpendMapsToFreshSpendCentsOnly() throws {
        let summary = try financeSummary(spentCents: 12_345)
        let mapped = WidgetSnapshotPublisher.mapFinance(summary: summary, state: .observed, now: now)

        XCTAssertEqual(mapped.spendCents, 12_345)
        XCTAssertEqual(mapped.freshness, .fresh)
        // No app-side net worth/cash flow producer exists against
        // FinanceSummary; these must stay unavailable, never a guessed value.
        XCTAssertNil(mapped.netWorthCents)
        XCTAssertNil(mapped.cashFlowCents)
    }

    func testFinanceUnavailableSpendMapsToFullyUnavailableNotZero() throws {
        let summary = try financeSummary(spentAvailability: "unavailable")
        let mapped = WidgetSnapshotPublisher.mapFinance(summary: summary, state: .unavailable, now: now)

        XCTAssertNil(mapped.spendCents)
        XCTAssertNil(mapped.netWorthCents)
        XCTAssertNil(mapped.cashFlowCents)
        XCTAssertEqual(mapped.availability(at: now), .unavailable)
    }

    func testFinanceNilSummaryMapsToUnavailable() {
        let mapped = WidgetSnapshotPublisher.mapFinance(summary: nil, state: .unavailable, now: now)
        XCTAssertNil(mapped.spendCents)
        XCTAssertEqual(mapped.availability(at: now), .unavailable)
    }

    // MARK: - Fitness (aggregate scores) — permanent invariant

    func testFitnessSummaryAlwaysMapsFullyUnavailable() {
        // No producer exists anywhere for health/recovery/strain score.
        // Regression guard: if this ever starts returning a value, a future
        // change fabricated a score.
        let mapped = WidgetSnapshotPublisher.mapFitness(projection: nil, now: now)
        XCTAssertNil(mapped.healthScore)
        XCTAssertNil(mapped.recoveryScore)
        XCTAssertNil(mapped.strainScore)
        XCTAssertEqual(mapped.availability(at: now), .unavailable)
    }

    // MARK: - Fitness widgets mapping

    private func provenance() throws -> HealthKitProvenance {
        let source = try HealthKitSourceMetadata(bundleIdentifier: "com.example.health", name: "com.example.health")
        let device = try HealthKitDeviceMetadata(manufacturer: nil, model: nil)
        return try HealthKitProvenance.from(source: source, device: device, registry: .canonical)
    }

    private func quantityObservation(
        metric: HealthKitMetricID,
        value: Double,
        at date: Date
    ) throws -> HealthKitObservation {
        try HealthKitObservation(
            metric: metric,
            identity: HealthKitSampleIdentity(uuid: UUID()),
            value: .quantity(try HealthKitQuantityValue(metric: metric, value: value, unit: XCTUnwrap(metric.canonicalUnit))),
            startDate: date,
            endDate: date,
            provenance: try provenance(),
            now: now
        )
    }

    private func metricState(
        metric: HealthKitMetricID,
        observations: [HealthKitObservation] = [],
        syncState: HealthKitSyncState = .synced
    ) throws -> HealthKitStoredMetricState {
        let projection = try HealthKitMetricProjection(
            metric: metric,
            observations: observations,
            conflicts: [],
            lastCommittedAt: now,
            syncState: syncState
        )
        return HealthKitStoredMetricState(projection: projection)
    }

    private func fitnessProjection(states: [HealthKitStoredMetricState]) -> HealthKitFitnessProjection {
        HealthKitFitnessProjection(
            states: states,
            window: DateInterval(start: now.addingTimeInterval(-86_400), end: now.addingTimeInterval(86_400)),
            calendar: calendar
        )
    }

    func testObservedHeartRateMapsToFreshValueWithExactObservedAt() throws {
        let sampleDate = now.addingTimeInterval(-120)
        let observation = try quantityObservation(metric: .restingHeartRate, value: 58, at: sampleDate)
        let projection = fitnessProjection(states: [try metricState(metric: .restingHeartRate, observations: [observation])])

        let mapped = WidgetSnapshotPublisher.mapFitnessWidgets(projection: projection, selectedDate: now, now: now)

        XCTAssertEqual(mapped.heartRate.value, 58)
        XCTAssertEqual(mapped.heartRate.unit, .beatsPerMinute)
        XCTAssertEqual(mapped.heartRate.observedAt, sampleDate)
        XCTAssertEqual(mapped.heartRate.state(at: now), .fresh)
    }

    func testStaleOrUnavailableHealthKitStateMapsToUnavailableNotZero() throws {
        // never_synced -> unavailable state at the projection level.
        let unsyncedProjection = fitnessProjection(states: [try metricState(metric: .restingHeartRate, syncState: .neverSynced)])
        let unsyncedMapped = WidgetSnapshotPublisher.mapFitnessWidgets(projection: unsyncedProjection, selectedDate: now, now: now)
        XCTAssertNil(unsyncedMapped.heartRate.value)
        XCTAssertEqual(unsyncedMapped.heartRate.state(at: now), .unavailable)

        // stale sync state -> also must not surface as a value.
        let staleObservation = try quantityObservation(metric: .restingHeartRate, value: 61, at: now.addingTimeInterval(-3_600))
        let staleProjection = fitnessProjection(states: [
            try metricState(metric: .restingHeartRate, observations: [staleObservation], syncState: .stale)
        ])
        let staleMapped = WidgetSnapshotPublisher.mapFitnessWidgets(projection: staleProjection, selectedDate: now, now: now)
        XCTAssertNil(staleMapped.heartRate.value)
        XCTAssertEqual(staleMapped.heartRate.state(at: now), .unavailable)
    }

    func testFitnessWidgetsScoreAndTemperatureFieldsAlwaysUnavailable() throws {
        // These have no HealthKit producer at all (no HealthKitMetricID case
        // for temperature or any score). Regression guard.
        let observation = try quantityObservation(metric: .restingHeartRate, value: 58, at: now.addingTimeInterval(-60))
        let projection = fitnessProjection(states: [try metricState(metric: .restingHeartRate, observations: [observation])])
        let mapped = WidgetSnapshotPublisher.mapFitnessWidgets(projection: projection, selectedDate: now, now: now)

        XCTAssertNil(mapped.strain.value)
        XCTAssertNil(mapped.recovery.value)
        XCTAssertNil(mapped.sleepScore.value)
        XCTAssertNil(mapped.temperature.value)
        XCTAssertNil(mapped.stressScore.value)
        XCTAssertTrue(mapped.stressTrend.buckets.isEmpty)
        XCTAssertNil(mapped.energyReserve.level.value)
    }

    func testFitnessWidgetsNilProjectionMapsToUnavailable() {
        let mapped = WidgetSnapshotPublisher.mapFitnessWidgets(projection: nil, selectedDate: now, now: now)
        XCTAssertNil(mapped.heartRate.value)
        XCTAssertEqual(mapped.displayState(at: now), .unavailable)
    }

    // MARK: - Nutrition mapping

    private func makeNutritionStores() throws -> (meals: NutritionMealStore, goals: NutritionGoalStore, mealsURL: URL, goalsURL: URL) {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let mealsURL = directory.appendingPathComponent("meals.json")
        let goalsURL = directory.appendingPathComponent("goals.json")
        return (try NutritionMealStore(url: mealsURL), try NutritionGoalStore(url: goalsURL), mealsURL, goalsURL)
    }

    func testNutritionWithLoggedMealsMapsObservedTotals() throws {
        let stores = try makeNutritionStores()
        let loggedAt = now.addingTimeInterval(-3_600)
        let meal = NutritionMeal(
            id: UUID(),
            loggedAt: loggedAt,
            timeZoneIdentifier: "Europe/Berlin",
            name: "Lunch",
            kcal: 650,
            proteinGrams: 40,
            carbGrams: 60,
            fatGrams: 20,
            journalNote: nil,
            provenance: .manual,
            createdAt: loggedAt,
            revision: 1
        )
        try stores.meals.addConfirmed(meal)
        try stores.goals.setGoal(NutritionGoal(effectiveFrom: now.addingTimeInterval(-86_400), calorieTarget: 2_200, createdAt: now))

        let mapped = WidgetSnapshotPublisher.mapNutrition(mealStore: stores.meals, goalStore: stores.goals, on: loggedAt, calendar: calendar)

        XCTAssertEqual(mapped.caloriesEaten.value, 650)
        XCTAssertEqual(mapped.caloriesEaten.observedAt, loggedAt)
        XCTAssertEqual(mapped.calorieGoal.value, 2_200)
        // No producer for these — must stay unavailable, not zero.
        XCTAssertNil(mapped.caloriesBurned.value)
        XCTAssertNil(mapped.qualityScore.value)
    }

    func testNutritionWithNoLoggedMealsMapsFullyUnavailableNotZero() throws {
        let stores = try makeNutritionStores()
        let mapped = WidgetSnapshotPublisher.mapNutrition(mealStore: stores.meals, goalStore: stores.goals, on: now, calendar: calendar)

        XCTAssertNil(mapped.caloriesEaten.value)
        XCTAssertNil(mapped.fatGrams.value)
        XCTAssertNil(mapped.carbsGrams.value)
        XCTAssertNil(mapped.proteinGrams.value)
        XCTAssertFalse(mapped.hasAggregateValue)
    }

    // MARK: - Redaction is enforced by FutureWidgetSnapshot itself

    func testRedactedPrivacyModeRedactsEveryField() throws {
        let summary = try financeSummary(spentCents: 5_000)
        let finance = WidgetSnapshotPublisher.mapFinance(summary: summary, state: .observed, now: now)
        let snapshot = FutureWidgetSnapshot(
            generatedAt: now,
            privacyMode: .redacted,
            finance: finance,
            fitness: .unavailable(),
            fitnessWidgets: .unavailable(),
            nutrition: .unavailable()
        )
        XCTAssertNil(snapshot.finance.spendCents)
        XCTAssertEqual(snapshot.financeDisplayState(at: now), .redacted)
    }

    // MARK: - Demo/fixture gating guardrail

    func testPublisherSourceNeverCallsADemoFactory() throws {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("LifeOS/WidgetSnapshotPublisher.swift")
        let source = try String(contentsOf: url, encoding: .utf8)
        XCTAssertFalse(source.contains(".demo("), "WidgetSnapshotPublisher must never construct demo/fixture widget data")
        XCTAssertFalse(source.contains("DEMO · NOT LIVE"), "WidgetSnapshotPublisher must never emit the demo source label")
    }

    // MARK: - Store round trip (exercises the existing write/read, not reimplemented here)

    func testStoreWriteReadRoundTrip() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let target = directory.appendingPathComponent("future-widget-snapshot.v1.json")

        let summary = try financeSummary(spentCents: 9_900)
        let finance = WidgetSnapshotPublisher.mapFinance(summary: summary, state: .observed, now: now)
        let snapshot = FutureWidgetSnapshot(
            generatedAt: now,
            privacyMode: .summaryAllowed,
            finance: finance,
            fitness: .unavailable(),
            fitnessWidgets: .unavailable(),
            nutrition: .unavailable()
        )

        try FutureWidgetSnapshotStore.write(snapshot, to: target)
        let readBack = FutureWidgetSnapshotStore.read(from: target, now: now)

        XCTAssertEqual(readBack, snapshot)
        XCTAssertEqual(readBack?.finance.spendCents, 9_900)
    }

    // MARK: - Reload coalescing

    func testCoalescingSkipsWriteAndReloadWhenContentUnchanged() throws {
        final class Spy {
            var writeCount = 0
            var reloadCount = 0
        }
        let spy = Spy()
        var publisher = WidgetSnapshotPublisher(
            write: { _ in spy.writeCount += 1 },
            reload: { spy.reloadCount += 1 }
        )
        let finance = WidgetSafeFinanceSummary(
            connector: .connected, consent: .granted, freshness: .fresh,
            observedAt: now.addingTimeInterval(-60), spendCents: 1_000
        )

        let firstResult = publisher.publish(
            finance: finance, fitness: .unavailable(), fitnessWidgets: .unavailable(),
            nutrition: .unavailable(), privacyMode: .summaryAllowed, now: now
        )
        XCTAssertTrue(firstResult)
        XCTAssertEqual(spy.writeCount, 1)
        XCTAssertEqual(spy.reloadCount, 1)

        // Same semantic content, only `now`/generatedAt differs — must be a no-op.
        let secondResult = publisher.publish(
            finance: finance, fitness: .unavailable(), fitnessWidgets: .unavailable(),
            nutrition: .unavailable(), privacyMode: .summaryAllowed, now: now.addingTimeInterval(5)
        )
        XCTAssertFalse(secondResult)
        XCTAssertEqual(spy.writeCount, 1)
        XCTAssertEqual(spy.reloadCount, 1)

        // Genuinely different content -> must write and reload again.
        let changedFinance = WidgetSafeFinanceSummary(
            connector: .connected, consent: .granted, freshness: .fresh,
            observedAt: now.addingTimeInterval(-30), spendCents: 2_000
        )
        let thirdResult = publisher.publish(
            finance: changedFinance, fitness: .unavailable(), fitnessWidgets: .unavailable(),
            nutrition: .unavailable(), privacyMode: .summaryAllowed, now: now.addingTimeInterval(10)
        )
        XCTAssertTrue(thirdResult)
        XCTAssertEqual(spy.writeCount, 2)
        XCTAssertEqual(spy.reloadCount, 2)
    }

    func testCoalescingSkipsOnWriteFailureAndReportsError() {
        struct WriteFailure: Error {}
        var reloadCount = 0
        var reportedError: Error?
        var publisher = WidgetSnapshotPublisher(
            write: { _ in throw WriteFailure() },
            reload: { reloadCount += 1 }
        )
        let result = publisher.publish(
            finance: .unavailable(), fitness: .unavailable(), fitnessWidgets: .unavailable(),
            nutrition: .unavailable(), privacyMode: .summaryAllowed, now: now,
            onWriteFailure: { reportedError = $0 }
        )
        XCTAssertFalse(result)
        XCTAssertEqual(reloadCount, 0)
        XCTAssertNotNil(reportedError)
    }
}
