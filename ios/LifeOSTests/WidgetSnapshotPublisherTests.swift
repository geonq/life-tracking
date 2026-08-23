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
        freshness: String = "fresh",
        transactions: [String: Any]? = nil
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
        var payload: [String: Any] = [
            "generatedAt": formatter.string(from: now),
            "currency": "EUR",
            "monthlyIncome": unavailableMetric,
            "fixedCosts": unavailableMetric,
            "discretionaryBuffer": unavailableMetric,
            "spent": spentMetric,
            "savingsGoal": unavailableMetric,
            "saved": unavailableMetric
        ]
        if let transactions {
            payload["transactions"] = transactions
        }
        return try FinanceSummary.decode(JSONSerialization.data(withJSONObject: payload), now: now)
    }

    private func accountOnlyFinanceSummary(
        balances: [Int],
        observedAt: Date? = nil,
        freshness: String = "fresh",
        connector: String = "healthy"
    ) throws -> FinanceSummary {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let accountObservedAt = observedAt ?? now.addingTimeInterval(-60)
        let observed = formatter.string(from: accountObservedAt)
        let unavailableProvenance: [String: Any] = [
            "source": "no-authorized-finance-source", "observedAt": observed,
            "freshness": "unknown", "quality": "unavailable", "connectorState": "unavailable"
        ]
        let unavailableMetric: [String: Any] = [
            "availability": "unavailable", "provenance": unavailableProvenance
        ]
        let accountProvenance: [String: Any] = [
            "source": "sparkasse_leipzig", "observedAt": observed,
            "freshness": freshness, "quality": "observed", "connectorState": connector
        ]
        let accounts: [[String: Any]] = balances.enumerated().map { index, balance in
            [
                "id": "sparkasse-(index)", "name": "Sparkasse Leipzig (index + 1)",
                "detail": "Checking", "balanceCents": balance,
                "source": "sparkasse_leipzig", "provenance": accountProvenance
            ]
        }
        let payload: [String: Any] = [
            "generatedAt": formatter.string(from: now), "currency": "EUR",
            "monthlyIncome": unavailableMetric, "fixedCosts": unavailableMetric,
            "discretionaryBuffer": unavailableMetric, "spent": unavailableMetric,
            "savingsGoal": unavailableMetric, "saved": unavailableMetric,
            "accounts": [
                "availability": "observed", "accounts": accounts,
                "provenance": accountProvenance
            ]
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

    func testObservedAccountsMapToOverflowSafeNetWorth() throws {
        let summary = try accountOnlyFinanceSummary(balances: [125_000, -25_000])
        let mapped = WidgetSnapshotPublisher.mapFinance(summary: summary, state: .observed, now: now)

        XCTAssertEqual(mapped.netWorthCents, 100_000)
        XCTAssertNil(mapped.cashFlowCents)
        XCTAssertEqual(mapped.freshness, .fresh)
        XCTAssertEqual(mapped.availability(at: now), .fresh)
    }

    func testOverflowingObservedAccountTotalFailsClosed() throws {
        // Each row is within the FinanceDomain account bound, but this many
        // rows exceed Int.max when summed. The mapper must not trap or wrap.
        let summary = try accountOnlyFinanceSummary(
            balances: Array(repeating: 9_007_199_254_740_991, count: 1_025)
        )
        let mapped = WidgetSnapshotPublisher.mapFinance(summary: summary, state: .observed, now: now)

        XCTAssertNil(mapped.netWorthCents)
        XCTAssertEqual(mapped.availability(at: now), .unavailable)
    }

    func testStaleObservedAccountsRemainVisibleWithStaleFreshness() throws {
        let summary = try accountOnlyFinanceSummary(
            balances: [100_000],
            observedAt: now.addingTimeInterval(-3_600),
            freshness: "stale",
            connector: "refresh_due"
        )
        let mapped = WidgetSnapshotPublisher.mapFinance(summary: summary, state: .stale, now: now)

        XCTAssertEqual(mapped.netWorthCents, 100_000)
        XCTAssertEqual(mapped.freshness, .stale)
        XCTAssertEqual(mapped.availability(at: now), .stale)
    }

    func testObservedTransactionsDeriveCashFlowFromSignedTotals() throws {
        let observedAt = now.addingTimeInterval(-60)
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let timestamp = formatter.string(from: observedAt)
        let provenance: [String: Any] = [
            "source": "revolut_personal", "observedAt": timestamp,
            "freshness": "fresh", "quality": "observed", "connectorState": "healthy"
        ]
        let transactions: [String: Any] = [
            "availability": "observed",
            "transactions": [
                [
                    "id": "income-1", "merchant": "Employer", "title": "Salary",
                    "signedAmountCents": 1_200, "timestamp": timestamp,
                    "account": "Revolut Personal", "source": "revolut_personal",
                    "category": "Income", "provenance": provenance
                ],
                [
                    "id": "spend-1", "merchant": "REWE", "title": "Groceries",
                    "signedAmountCents": -250, "timestamp": timestamp,
                    "account": "Revolut Personal", "source": "revolut_personal",
                    "category": "Food", "provenance": provenance
                ]
            ],
            "provenance": provenance
        ]
        let summary = try financeSummary(
            spentAvailability: "unavailable",
            transactions: transactions
        )
        let mapped = WidgetSnapshotPublisher.mapFinance(summary: summary, state: .observed, now: now)

        XCTAssertEqual(mapped.cashFlowCents, 950)
        XCTAssertNil(mapped.netWorthCents)
        XCTAssertNil(mapped.spendCents)
    }

    func testAbsentTransactionsNeverMapCashFlowToZero() throws {
        let summary = try financeSummary(spentAvailability: "unavailable")
        let mapped = WidgetSnapshotPublisher.mapFinance(summary: summary, state: .observed, now: now)

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

    /// Thread-safe counter/recorder used by the coalescing tests below.
    /// `WidgetSnapshotPublisher`'s `write`/`reload` closures are `@Sendable`
    /// and may be invoked from the actor's executor, which is not
    /// necessarily the calling test's thread — a plain mutable class would
    /// be a data race under `-only-testing` parallelism and under the
    /// concurrent-burst test in particular.
    private final class Spy: @unchecked Sendable {
        private let lock = NSLock()
        private var _writeCount = 0
        private var _reloadCount = 0

        var writeCount: Int { lock.withLock { _writeCount } }
        var reloadCount: Int { lock.withLock { _reloadCount } }

        func recordWrite() { lock.withLock { _writeCount += 1 } }
        func recordReload() { lock.withLock { _reloadCount += 1 } }
    }

    func testCoalescingSkipsWriteAndReloadWhenContentUnchanged() async throws {
        let spy = Spy()
        let publisher = WidgetSnapshotPublisher(
            write: { _ in spy.recordWrite() },
            reload: { spy.recordReload() }
        )
        let finance = WidgetSafeFinanceSummary(
            connector: .connected, consent: .granted, freshness: .fresh,
            observedAt: now.addingTimeInterval(-60), spendCents: 1_000
        )

        let firstResult = await publisher.publish(
            finance: finance, fitness: .unavailable(), fitnessWidgets: .unavailable(),
            nutrition: .unavailable(), privacyMode: .summaryAllowed, now: now
        )
        XCTAssertTrue(firstResult)
        XCTAssertEqual(spy.writeCount, 1)
        XCTAssertEqual(spy.reloadCount, 1)

        // Same semantic content, only `now`/generatedAt differs — must be a no-op.
        let secondResult = await publisher.publish(
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
        let thirdResult = await publisher.publish(
            finance: changedFinance, fitness: .unavailable(), fitnessWidgets: .unavailable(),
            nutrition: .unavailable(), privacyMode: .summaryAllowed, now: now.addingTimeInterval(10)
        )
        XCTAssertTrue(thirdResult)
        XCTAssertEqual(spy.writeCount, 2)
        XCTAssertEqual(spy.reloadCount, 2)
    }

    func testCoalescingSkipsOnWriteFailureAndReportsError() async {
        struct WriteFailure: Error {}
        let spy = Spy()
        final class ErrorBox: @unchecked Sendable {
            private let lock = NSLock()
            private var _error: Error?
            var error: Error? { lock.withLock { _error } }
            func record(_ error: Error) { lock.withLock { _error = error } }
        }
        let errorBox = ErrorBox()
        let publisher = WidgetSnapshotPublisher(
            write: { _ in throw WriteFailure() },
            reload: { spy.recordReload() }
        )
        let result = await publisher.publish(
            finance: .unavailable(), fitness: .unavailable(), fitnessWidgets: .unavailable(),
            nutrition: .unavailable(), privacyMode: .summaryAllowed, now: now,
            onWriteFailure: { errorBox.record($0) }
        )
        XCTAssertFalse(result)
        XCTAssertEqual(spy.reloadCount, 0)
        XCTAssertNotNil(errorBox.error)
    }

    /// F1 regression guard: a burst of concurrent, content-identical
    /// `publish` calls against the SAME actor instance (mirroring how
    /// `LifeOSApp`/`LifeOSMacApp` spawn one `Task.detached` per
    /// `publishWidgetSnapshots()` call site, all targeting one durable
    /// `widgetSnapshotPublisher`) must collapse to exactly one write and one
    /// reload — not one per caller. A following genuinely-changed publish
    /// must still fire again afterward.
    func testConcurrentBurstOfIdenticalPublishesCollapsesToOneWriteAndReload() async throws {
        let spy = Spy()
        let publisher = WidgetSnapshotPublisher(
            write: { _ in spy.recordWrite() },
            reload: { spy.recordReload() }
        )
        let finance = WidgetSafeFinanceSummary(
            connector: .connected, consent: .granted, freshness: .fresh,
            observedAt: now.addingTimeInterval(-60), spendCents: 4_200
        )

        // Fire N concurrent publishes with identical content (generatedAt is
        // excluded from the dedupe comparison) at the same actor instance,
        // exactly as a burst of near-simultaneous onChange call sites would.
        let burstSize = 25
        await withTaskGroup(of: Bool.self) { group in
            for offset in 0..<burstSize {
                group.addTask {
                    await publisher.publish(
                        finance: finance, fitness: .unavailable(), fitnessWidgets: .unavailable(),
                        nutrition: .unavailable(), privacyMode: .summaryAllowed,
                        now: self.now.addingTimeInterval(TimeInterval(offset))
                    )
                }
            }
            var trueCount = 0
            for await result in group where result { trueCount += 1 }
            XCTAssertEqual(trueCount, 1, "Exactly one publish in the burst should report a real write")
        }
        XCTAssertEqual(spy.writeCount, 1)
        XCTAssertEqual(spy.reloadCount, 1)

        // A following genuinely different publish must still fire again.
        let changedFinance = WidgetSafeFinanceSummary(
            connector: .connected, consent: .granted, freshness: .fresh,
            observedAt: now.addingTimeInterval(-10), spendCents: 5_500
        )
        let changedResult = await publisher.publish(
            finance: changedFinance, fitness: .unavailable(), fitnessWidgets: .unavailable(),
            nutrition: .unavailable(), privacyMode: .summaryAllowed, now: now.addingTimeInterval(100)
        )
        XCTAssertTrue(changedResult)
        XCTAssertEqual(spy.writeCount, 2)
        XCTAssertEqual(spy.reloadCount, 2)
    }
}
