import AppKit
import SwiftUI
import WidgetKit
import XCTest

@MainActor
final class LifeOSWidgetSnapshotTests: XCTestCase {
    private let smallSize = CGSize(width: 155, height: 155)
    private let mediumSize = CGSize(width: 329, height: 155)
    private let scale: CGFloat = 2

    private var demoUsageEntry: LifeOSEntry {
        let observedAt = DemoDataProvider.observedAt
        return LifeOSEntry(
            date: observedAt,
            snapshot: DemoDataProvider.widget(now: observedAt)
        )
    }

    private var unavailableUsageEntry: LifeOSEntry {
        let observedAt = DemoDataProvider.observedAt
        return LifeOSEntry(
            date: observedAt,
            snapshot: WidgetSnapshot.unavailable(at: observedAt)
        )
    }

    private var unavailableFutureEntry: FutureModuleWidgetEntry {
        FutureModuleWidgetEntry(date: DemoDataProvider.observedAt)
    }

    private var summaryAllowedFutureEntry: FutureModuleWidgetEntry {
        let observedAt = Date(
            timeIntervalSince1970: floor(Date(timeIntervalSinceNow: -60).timeIntervalSince1970)
        )
        let finance = WidgetSafeFinanceSummary(
            connector: .connected,
            consent: .granted,
            freshness: .fresh,
            observedAt: observedAt,
            netWorthCents: 125_000_00,
            spendCents: 1_250_50,
            cashFlowCents: 2_500_00
        )
        let fitness = WidgetSafeFitnessSummary(
            connector: .connected,
            consent: .granted,
            freshness: .fresh,
            observedAt: observedAt,
            healthScore: 82,
            recoveryScore: 74,
            strainScore: 41
        )
        return FutureModuleWidgetEntry(
            date: observedAt,
            snapshot: FutureWidgetSnapshot(
                generatedAt: observedAt,
                privacyMode: .summaryAllowed,
                finance: finance,
                fitness: fitness,
                fitnessWidgets: WidgetSafeFitnessWidgetsSummary.demo(at: observedAt),
                nutrition: WidgetSafeNutritionSummary.demo(at: observedAt)
            )
        )
    }

    private var calendarDemoDate: Date {
        let day = fixedCalendar.date(from: DateComponents(year: 2026, month: 8, day: 31))!
        return fixedCalendar.date(bySettingHour: 8, minute: 0, second: 0, of: day)!
    }

    private var calendarDemoEntry: CalendarWidgetEntry {
        CalendarWidgetEntry(
            date: calendarDemoDate,
            snapshot: calendarDemoSnapshot
        )
    }

    /// Synthetic widget-only content: three events on the anchored day, including a
    /// deliberately long title so the small and medium layouts exercise truncation.
    private var calendarDemoSnapshot: CalendarSnapshot {
        let day = fixedCalendar.startOfDay(for: calendarDemoDate)
        func instant(hour: Int, minute: Int = 0) -> Date {
            fixedCalendar.date(bySettingHour: hour, minute: minute, second: 0, of: day)!
        }
        func item(id: String, title: String, start: Date, end: Date) -> CalendarItem {
            try! CalendarItem(
                id: UUID(uuidString: id)!,
                title: title,
                icon: "📅",
                status: .planned,
                start: start,
                end: end,
                createdAt: day,
                updatedAt: day
            )
        }

        return CalendarSnapshot(items: [
            item(
                id: "20000000-0000-0000-0000-000000000001",
                title: "Long strategy alignment with product and design",
                start: instant(hour: 9),
                end: instant(hour: 10)
            ),
            item(
                id: "20000000-0000-0000-0000-000000000002",
                title: "Deep work",
                start: instant(hour: 10, minute: 30),
                end: instant(hour: 12)
            ),
            item(
                id: "20000000-0000-0000-0000-000000000003",
                title: "Ship checkpoint",
                start: instant(hour: 13),
                end: instant(hour: 14, minute: 15)
            )
        ])
    }

    private var calendarEmptyEntry: CalendarWidgetEntry {
        CalendarWidgetEntry(date: calendarDemoDate, snapshot: CalendarSnapshot())
    }

    private var calendarUnavailableEntry: CalendarWidgetEntry {
        CalendarWidgetEntry(date: calendarDemoDate, snapshot: CalendarSnapshot(), storageAvailable: false)
    }

    func testUsageSmallDemoSnapshot() {
        render(
            LifeOSUsageSmallWidgetView(entry: demoUsageEntry),
            named: "usage-small-demo",
            size: smallSize
        )
    }

    func testUsageMediumDemoSnapshot() {
        render(
            LifeOSWidgetView(entry: demoUsageEntry),
            named: "usage-medium-demo",
            size: mediumSize
        )
    }

    func testUsageSmallUnavailableSnapshot() {
        render(
            LifeOSUsageSmallWidgetView(entry: unavailableUsageEntry),
            named: "usage-small-unavailable",
            size: smallSize
        )
    }

    func testUsageMediumUnavailableSnapshot() {
        render(
            LifeOSWidgetView(entry: unavailableUsageEntry),
            named: "usage-medium-unavailable",
            size: mediumSize
        )
    }

    func testFutureModuleSnapshots() {
        let entry = unavailableFutureEntry

        render(NetWorthWidgetView(entry: entry), named: "future-net-worth-medium", size: mediumSize)
        render(SpendRingWidgetView(entry: entry), named: "future-spend-small", size: smallSize)
        render(CashFlowWidgetView(entry: entry), named: "future-cash-flow-medium", size: mediumSize)
        render(HealthMonitorWidgetView(entry: entry), named: "future-health-monitor-medium", size: mediumSize)
        render(RecoveryRingWidgetView(entry: entry), named: "future-recovery-small", size: smallSize)
    }

    func testFutureWidgetSnapshotDefaultsRedactedAndFailsClosed() throws {
        let reference = Date(timeIntervalSinceNow: -60)
        let snapshot = FutureWidgetSnapshot(generatedAt: reference)
        XCTAssertEqual(snapshot.schemaVersion, FutureWidgetSnapshot.currentSchemaVersion)
        XCTAssertEqual(snapshot.privacyMode, .redacted)
        XCTAssertEqual(snapshot.financeDisplayState, .redacted)
        XCTAssertEqual(snapshot.fitnessDisplayState, .redacted)
        XCTAssertNil(snapshot.finance.netWorthCents)
        XCTAssertNil(snapshot.fitness.healthScore)
        XCTAssertNil(snapshot.nutrition.caloriesEaten.value)
        XCTAssertEqual(snapshot.nutrition.displayState(at: reference), .redacted)
        XCTAssertNil(snapshot.fitnessWidgets.strain.value)
        XCTAssertNil(snapshot.fitnessWidgets.strain.sourceLabel)
        XCTAssertNil(snapshot.fitnessWidgets.recovery.value)
        XCTAssertNil(snapshot.fitnessWidgets.sleepDuration.value)
        XCTAssertNil(snapshot.fitnessWidgets.respiration.value)
        XCTAssertNil(snapshot.fitnessWidgets.heartRate.value)
        XCTAssertNil(snapshot.fitnessWidgets.hrv.value)
        XCTAssertNil(snapshot.fitnessWidgets.spo2.value)
        XCTAssertNil(snapshot.fitnessWidgets.temperature.value)
        XCTAssertNil(snapshot.fitnessWidgets.sleepScore.value)
        XCTAssertNil(snapshot.fitnessWidgets.stressScore.value)
        XCTAssertNil(snapshot.fitnessWidgets.energyReserve.level.value)
        XCTAssertNil(snapshot.fitnessWidgets.energyReserve.startingLevel.value)
        XCTAssertNil(snapshot.fitnessWidgets.energyReserve.chargedPercent.value)
        XCTAssertNil(snapshot.fitnessWidgets.energyReserve.dischargedPercent.value)
        XCTAssertTrue(snapshot.fitnessWidgets.stressTrend.buckets.isEmpty)
        XCTAssertNil(snapshot.fitnessWidgets.stressTrend.sourceLabel)
        XCTAssertNil(snapshot.fitnessWidgets.energyReserve.lastChargedAt)
        XCTAssertNil(snapshot.fitnessWidgets.provenanceLabel)

        let deniedFinance = WidgetSafeFinanceSummary(
            connector: .connected,
            consent: .notGranted,
            freshness: .fresh,
            observedAt: reference,
            spendCents: 123
        )
        XCTAssertNil(deniedFinance.spendCents, "Consent denial must not cross the widget boundary")

        let demoFitness = WidgetSafeFitnessWidgetsSummary.demo(at: reference)
        let deniedFitness = WidgetSafeFitnessWidgetsSummary(
            connector: .unavailable,
            consent: .granted,
            strain: demoFitness.strain,
            stressTrend: demoFitness.stressTrend,
            energyReserve: demoFitness.energyReserve,
            provenanceLabel: "DEMO · NOT LIVE"
        )
        XCTAssertNil(deniedFitness.strain.value)
        XCTAssertNil(deniedFitness.stressTrend.sourceLabel)
        XCTAssertTrue(deniedFitness.stressTrend.buckets.isEmpty)
        XCTAssertNil(deniedFitness.energyReserve.level.value)
        XCTAssertNil(deniedFitness.provenanceLabel)

        let encoded = try FutureWidgetSnapshotStore.encode(snapshot)
        XCTAssertNotNil(FutureWidgetSnapshotStore.decode(encoded, now: reference))
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        object["accountName"] = "must not be accepted"
        let unsafe = try JSONSerialization.data(withJSONObject: object)
        XCTAssertNil(FutureWidgetSnapshotStore.decode(unsafe, now: reference))
    }

    func testFutureWidgetSnapshotStoreWritesAndReadsAtomicVersionedPayload() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("lifeos-future-widget-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let target = directory.appendingPathComponent(FutureWidgetSnapshotStore.snapshotFilename)
        let snapshot = summaryAllowedFutureEntry.snapshot

        try FutureWidgetSnapshotStore.write(snapshot, to: target)
        let loaded = try XCTUnwrap(FutureWidgetSnapshotStore.read(
            from: target,
            now: snapshot.generatedAt.addingTimeInterval(1)
        ))
        XCTAssertEqual(loaded, snapshot)
        XCTAssertEqual(loaded.schemaVersion, 1)
        XCTAssertEqual(loaded.finance.cashFlowCents, 2_500_00)
        XCTAssertEqual(loaded.fitness.recoveryScore, 74)
        XCTAssertEqual(loaded.nutrition.caloriesEaten.value, 1_860)
        XCTAssertEqual(loaded.nutrition.fatGoalGrams.value, 75)
    }

    func testFutureWidgetFreshnessIsDerivedAndRequiresAnAggregate() {
        let now = Date(timeIntervalSinceNow: -60)
        let oldObservation = now.addingTimeInterval(-(futureWidgetFreshnessWindow + 1))
        let staleFinance = WidgetSafeFinanceSummary(
            connector: .connected,
            consent: .granted,
            freshness: .fresh,
            observedAt: oldObservation,
            spendCents: 1_200
        )
        let staleSnapshot = FutureWidgetSnapshot(
            generatedAt: now,
            privacyMode: .summaryAllowed,
            finance: staleFinance
        )
        XCTAssertEqual(staleSnapshot.financeDisplayState(at: now), .stale)

        let persistedStale = WidgetSafeFinanceSummary(
            connector: .connected,
            consent: .granted,
            freshness: .stale,
            observedAt: now.addingTimeInterval(-1),
            spendCents: 1_300
        )
        let persistedStaleSnapshot = FutureWidgetSnapshot(
            generatedAt: now,
            privacyMode: .summaryAllowed,
            finance: persistedStale
        )
        XCTAssertEqual(persistedStaleSnapshot.financeDisplayState(at: now), .stale)
        let persistedStaleData = try! FutureWidgetSnapshotStore.encode(persistedStaleSnapshot)
        let persistedStaleLoaded = FutureWidgetSnapshotStore.decode(persistedStaleData, now: now)
        XCTAssertEqual(persistedStaleLoaded?.financeDisplayState(at: now), .stale)

        let noValueFinance = WidgetSafeFinanceSummary(
            connector: .connected,
            consent: .granted,
            freshness: .fresh,
            observedAt: now
        )
        let noValueSnapshot = FutureWidgetSnapshot(
            generatedAt: now,
            privacyMode: .summaryAllowed,
            finance: noValueFinance
        )
        XCTAssertEqual(noValueSnapshot.financeDisplayState(at: now), .unavailable)

        let futureFinance = WidgetSafeFinanceSummary(
            connector: .connected,
            consent: .granted,
            freshness: .fresh,
            observedAt: Date(timeIntervalSinceNow: 60),
            spendCents: 99
        )
        XCTAssertNil(futureFinance.spendCents)
        let nonFiniteFinance = WidgetSafeFinanceSummary(
            connector: .connected,
            consent: .granted,
            freshness: .fresh,
            observedAt: Date(timeIntervalSince1970: .nan),
            spendCents: 99
        )
        XCTAssertNil(nonFiniteFinance.spendCents)

        let injectedNow = Date(
            timeIntervalSince1970: floor(Date(timeIntervalSinceNow: -300).timeIntervalSince1970)
        )
        let injectedSnapshot = FutureWidgetSnapshot(
            generatedAt: injectedNow,
            privacyMode: .summaryAllowed,
            finance: WidgetSafeFinanceSummary(
                connector: .connected,
                consent: .granted,
                freshness: .stale,
                observedAt: injectedNow,
                spendCents: 1_400
            )
        )
        let injectedData = try! FutureWidgetSnapshotStore.encode(injectedSnapshot)
        let decoded = FutureWidgetSnapshotStore.decode(injectedData, now: injectedNow)
        XCTAssertEqual(decoded, injectedSnapshot, "Decoding with an injected clock must preserve the snapshot")
        XCTAssertEqual(decoded?.financeDisplayState(at: injectedNow), .stale)
    }

    func testFutureWidgetSnapshotRejectsNestedObservationAfterSnapshot() throws {
        let entry = summaryAllowedFutureEntry
        let encoded = try FutureWidgetSnapshotStore.encode(entry.snapshot)
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        object["generatedAt"] = "2020-01-01T00:00:00Z"
        let contradictory = try JSONSerialization.data(withJSONObject: object)
        XCTAssertNil(FutureWidgetSnapshotStore.decode(contradictory, now: Date()))
    }

    func testNutritionWidgetBoundaryPrivacyAndStrictness() throws {
        let now = Date(timeIntervalSinceNow: -60)
        let fixture = WidgetSafeNutritionSummary.demo(at: now)
        let redacted = FutureWidgetSnapshot(generatedAt: now, privacyMode: .redacted, nutrition: fixture)
        XCTAssertNil(redacted.nutrition.caloriesEaten.value)
        XCTAssertNil(redacted.nutrition.qualityLabel)
        XCTAssertNil(redacted.nutrition.provenanceLabel)
        XCTAssertEqual(redacted.nutritionDisplayState(at: now), .redacted)

        let metric = WidgetNutritionMetric(value: 1_860, state: .fresh, observedAt: now, sourceLabel: "DEMO · NOT LIVE")
        let denied = WidgetSafeNutritionSummary(connector: .connected, consent: .notGranted, caloriesEaten: metric, provenanceLabel: "DEMO · NOT LIVE")
        XCTAssertNil(denied.caloriesEaten.value)
        XCTAssertNil(denied.provenanceLabel)

        let stale = WidgetNutritionMetric(value: 194, state: .fresh, observedAt: now.addingTimeInterval(-(futureWidgetFreshnessWindow + 1)), sourceLabel: "DEMO · NOT LIVE")
        let independent = WidgetSafeNutritionSummary(
            connector: .connected,
            consent: .granted,
            caloriesEaten: metric,
            carbsGrams: stale,
            qualityScore: .redacted()
        )
        XCTAssertEqual(independent.caloriesEaten.state(at: now), .fresh)
        XCTAssertEqual(independent.carbsGrams.state(at: now), .stale)
        XCTAssertEqual(independent.qualityScore.state(at: now), .redacted)

        let encoded = try JSONEncoder.lifeOS.encode(FutureWidgetSnapshot(generatedAt: now, privacyMode: .summaryAllowed, nutrition: fixture))
        var unknown = try XCTUnwrap(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        unknown["mealName"] = "must not cross widget boundary"
        XCTAssertNil(FutureWidgetSnapshotStore.decode(try JSONSerialization.data(withJSONObject: unknown), now: now))

        var outOfRange = try XCTUnwrap(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        var nutrition = try XCTUnwrap(outOfRange["nutrition"] as? [String: Any])
        var quality = try XCTUnwrap(nutrition["qualityScore"] as? [String: Any])
        quality["value"] = 101
        nutrition["qualityScore"] = quality
        outOfRange["nutrition"] = nutrition
        XCTAssertNil(FutureWidgetSnapshotStore.decode(try JSONSerialization.data(withJSONObject: outOfRange), now: now))

        var future = try XCTUnwrap(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        nutrition = try XCTUnwrap(future["nutrition"] as? [String: Any])
        var eaten = try XCTUnwrap(nutrition["caloriesEaten"] as? [String: Any])
        eaten["observedAt"] = "2999-01-01T00:00:00Z"
        nutrition["caloriesEaten"] = eaten
        future["nutrition"] = nutrition
        XCTAssertNil(FutureWidgetSnapshotStore.decode(try JSONSerialization.data(withJSONObject: future), now: now))

        var mixedOldAndFuture = try XCTUnwrap(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        nutrition = try XCTUnwrap(mixedOldAndFuture["nutrition"] as? [String: Any])
        var mixedEaten = try XCTUnwrap(nutrition["caloriesEaten"] as? [String: Any])
        var mixedCarbs = try XCTUnwrap(nutrition["carbsGrams"] as? [String: Any])
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        mixedEaten["observedAt"] = formatter.string(from: now.addingTimeInterval(1))
        mixedCarbs["observedAt"] = formatter.string(from: now.addingTimeInterval(-(futureWidgetFreshnessWindow + 1)))
        nutrition["caloriesEaten"] = mixedEaten
        nutrition["carbsGrams"] = mixedCarbs
        mixedOldAndFuture["nutrition"] = nutrition
        XCTAssertNil(
            FutureWidgetSnapshotStore.decode(
                try JSONSerialization.data(withJSONObject: mixedOldAndFuture),
                now: now
            ),
            "A summary with an old metric and a future metric must fail closed"
        )
    }

    func testFutureModuleRedactedSnapshotsAndAccessibilityStates() {
        let entry = unavailableFutureEntry
        render(NetWorthWidgetView(entry: entry), named: "future-net-worth-redacted", size: mediumSize)
        render(SpendRingWidgetView(entry: entry), named: "future-spend-redacted", size: smallSize)
        render(CashFlowWidgetView(entry: entry), named: "future-cash-flow-redacted", size: mediumSize)
        render(HealthMonitorWidgetView(entry: entry), named: "future-health-redacted", size: mediumSize)
        render(RecoveryRingWidgetView(entry: entry), named: "future-recovery-redacted", size: smallSize)
        XCTAssertEqual(entry.snapshot.financeDisplayState, .redacted)
        XCTAssertEqual(entry.snapshot.fitnessDisplayState, .redacted)
    }

    func testFutureModuleSummaryAllowedSnapshots() {
        let entry = summaryAllowedFutureEntry
        render(NetWorthWidgetView(entry: entry), named: "future-net-worth-summary", size: mediumSize)
        render(SpendRingWidgetView(entry: entry), named: "future-spend-summary", size: smallSize)
        render(CashFlowWidgetView(entry: entry), named: "future-cash-flow-summary", size: mediumSize)
        render(HealthMonitorWidgetView(entry: entry), named: "future-health-summary", size: mediumSize)
        render(RecoveryRingWidgetView(entry: entry), named: "future-recovery-summary", size: smallSize)
        XCTAssertEqual(entry.snapshot.financeDisplayState, .fresh)
        XCTAssertEqual(entry.snapshot.fitnessDisplayState, .fresh)
    }

    func testNutritionMediumWidgetsDemoLightAndDarkSnapshots() {
        let entry = summaryAllowedFutureEntry
        for (suffix, scheme) in [("dark", ColorScheme.dark), ("light", ColorScheme.light)] {
            render(
                NutritionOverviewWidgetView(entry: entry),
                named: "nutrition-overview-medium-demo-\(suffix)",
                size: mediumSize,
                colorScheme: scheme
            )
            render(
                CaloriesMacrosWidgetView(entry: entry),
                named: "nutrition-calories-macros-medium-demo-\(suffix)",
                size: mediumSize,
                colorScheme: scheme
            )
            render(
                NetEnergyWidgetView(entry: entry),
                named: "nutrition-net-energy-medium-demo-\(suffix)",
                size: mediumSize,
                colorScheme: scheme
            )
        }
    }

    func testNutritionWidgetsKeepIndependentUnavailableAndStaleMetrics() {
        let now = Date(timeIntervalSinceNow: -60)
        let old = now.addingTimeInterval(-(futureWidgetFreshnessWindow + 1))
        func metric(_ value: Double, at date: Date, state: WidgetAggregateAvailability = .fresh) -> WidgetNutritionMetric {
            WidgetNutritionMetric(value: value, state: state, observedAt: date, sourceLabel: "DEMO · NOT LIVE")
        }
        let nutrition = WidgetSafeNutritionSummary(
            connector: .connected,
            consent: .granted,
            caloriesEaten: metric(1_860, at: now),
            calorieGoal: metric(2_200, at: now),
            fatGrams: .unavailable(),
            fatGoalGrams: metric(100, at: now),
            carbsGrams: metric(300, at: old),
            carbsGoalGrams: metric(500, at: old),
            proteinGrams: metric(120, at: now),
            proteinGoalGrams: metric(140, at: now),
            caloriesBurned: metric(2_340, at: now),
            qualityScore: .redacted(),
            provenanceLabel: "DEMO · NOT LIVE"
        )
        let entry = FutureModuleWidgetEntry(
            date: now,
            snapshot: FutureWidgetSnapshot(generatedAt: now, privacyMode: .summaryAllowed, nutrition: nutrition)
        )
        XCTAssertEqual(entry.snapshot.nutrition.fatGrams.state(at: now), .unavailable)
        XCTAssertEqual(entry.snapshot.nutrition.carbsGrams.state(at: now), .stale)
        XCTAssertEqual(entry.snapshot.nutrition.qualityScore.state(at: now), .redacted)
        render(NutritionOverviewWidgetView(entry: entry), named: "nutrition-overview-medium-independent-states", size: mediumSize)
        render(CaloriesMacrosWidgetView(entry: entry), named: "nutrition-calories-macros-medium-independent-states", size: mediumSize)
        render(NetEnergyWidgetView(entry: entry), named: "nutrition-net-energy-medium-independent-states", size: mediumSize)
    }

    func testFitnessMediumWidgetsDemoLightAndDarkSnapshots() {
        let entry = summaryAllowedFutureEntry
        XCTAssertTrue(entry.snapshot.fitnessWidgets.isDemoFixture)
        let observedAt = entry.date
        let sleepDuration = WidgetFitnessMetric(
            value: 2.9,
            unit: .hours,
            state: .fresh,
            observedAt: observedAt,
            sourceLabel: "DEMO · NOT LIVE"
        )
        XCTAssertEqual(fitnessWidgetDurationText(sleepDuration, at: observedAt), "2:54")
        func fitnessMetric(_ value: Double, unit: WidgetFitnessMetricUnit) -> WidgetFitnessMetric {
            WidgetFitnessMetric(value: value, unit: unit, state: .fresh, observedAt: observedAt, sourceLabel: "DEMO · NOT LIVE")
        }
        func localizedOneDecimal(_ value: Double) -> String {
            value.formatted(.number.precision(.fractionLength(1)))
        }
        XCTAssertEqual(fitnessWidgetMetricValueText(fitnessMetric(9.3, unit: .breathsPerMinute), at: observedAt), localizedOneDecimal(9.3))
        XCTAssertEqual(fitnessWidgetMetricValueText(fitnessMetric(72, unit: .beatsPerMinute), at: observedAt), localizedOneDecimal(72))
        XCTAssertEqual(fitnessWidgetMetricValueText(fitnessMetric(33.6, unit: .milliseconds), at: observedAt), localizedOneDecimal(33.6))
        XCTAssertEqual(fitnessWidgetMetricValueText(fitnessMetric(94.7, unit: .oxygenPercent), at: observedAt), localizedOneDecimal(94.7))
        XCTAssertEqual(fitnessWidgetMetricValueText(fitnessMetric(35.6, unit: .celsius), at: observedAt), localizedOneDecimal(35.6))
        XCTAssertEqual(fitnessWidgetDemoDisclosure(entry.snapshot.fitnessWidgets), ", Demo, not live")
        let liveFitness = WidgetSafeFitnessWidgetsSummary(
            connector: .connected,
            consent: .granted,
            heartRate: WidgetFitnessMetric(
                value: 72,
                unit: .beatsPerMinute,
                state: .fresh,
                observedAt: observedAt,
                sourceLabel: "Validated source"
            ),
            provenanceLabel: "Validated source"
        )
        XCTAssertEqual(fitnessWidgetDemoDisclosure(liveFitness), "")
        for (suffix, scheme) in [("dark", ColorScheme.dark), ("light", ColorScheme.light)] {
            render(DailyOverviewWidgetView(entry: entry), named: "fitness-daily-overview-medium-demo-\(suffix)", size: mediumSize, colorScheme: scheme)
            render(FitnessHealthMonitorWidgetView(entry: entry), named: "fitness-health-monitor-medium-demo-\(suffix)", size: mediumSize, colorScheme: scheme)
            render(FitnessStressWidgetView(entry: entry), named: "fitness-stress-medium-demo-\(suffix)", size: mediumSize, colorScheme: scheme)
            render(FitnessEnergyReserveWidgetView(entry: entry), named: "fitness-energy-reserve-medium-demo-\(suffix)", size: mediumSize, colorScheme: scheme)
        }
    }

    func testFitnessWidgetsKeepIndependentUnavailableAndStaleMetrics() {
        let now = Date(timeIntervalSinceNow: -60)
        let old = now.addingTimeInterval(-(futureWidgetFreshnessWindow + 1))
        func metric(_ value: Double, unit: WidgetFitnessMetricUnit, at date: Date, state: WidgetAggregateAvailability = .fresh) -> WidgetFitnessMetric {
            WidgetFitnessMetric(value: value, unit: unit, state: state, observedAt: date, sourceLabel: "DEMO · NOT LIVE")
        }
        let fitness = WidgetSafeFitnessWidgetsSummary(
            connector: .connected,
            consent: .granted,
            strain: metric(15, unit: .score, at: now),
            recovery: metric(90, unit: .score, at: now),
            sleepScore: metric(80, unit: .score, at: now),
            sleepDuration: metric(2.9, unit: .hours, at: now),
            respiration: .unavailable(unit: .breathsPerMinute),
            heartRate: metric(72, unit: .beatsPerMinute, at: old),
            hrv: metric(33.6, unit: .milliseconds, at: now),
            spo2: metric(94.7, unit: .oxygenPercent, at: now),
            temperature: metric(35.6, unit: .celsius, at: now),
            stressScore: metric(53, unit: .score, at: now),
            stressTrend: WidgetStressTrend(
                buckets: [40, 45, 53],
                state: .fresh,
                observedAt: now,
                sourceLabel: "DEMO · NOT LIVE",
                windowStart: now.addingTimeInterval(-18 * 60 * 60),
                windowEnd: now
            ),
            energyReserve: .demo(at: now),
            provenanceLabel: "DEMO · NOT LIVE"
        )
        XCTAssertEqual(fitness.respiration.state(at: now), .unavailable)
        XCTAssertEqual(fitness.heartRate.state(at: now), .stale)
        XCTAssertEqual(fitness.hrv.state(at: now), .fresh)
        let entry = FutureModuleWidgetEntry(date: now, snapshot: FutureWidgetSnapshot(generatedAt: now, privacyMode: .summaryAllowed, fitnessWidgets: fitness))
        render(DailyOverviewWidgetView(entry: entry), named: "fitness-daily-overview-medium-independent-states", size: mediumSize)
        render(FitnessHealthMonitorWidgetView(entry: entry), named: "fitness-health-monitor-medium-independent-states", size: mediumSize)
        render(FitnessStressWidgetView(entry: entry), named: "fitness-stress-medium-independent-states", size: mediumSize)
        render(FitnessEnergyReserveWidgetView(entry: entry), named: "fitness-energy-reserve-medium-independent-states", size: mediumSize)
    }

    func testFitnessWidgetBoundaryNormalizesUnsafeDirectValuesAndRejectsUnsafePayloads() throws {
        let now = Date(timeIntervalSinceNow: -60)
        let source = "DEMO · NOT LIVE"
        let wrongUnit = WidgetFitnessMetric(value: 12, unit: .hours, state: .fresh, observedAt: now, sourceLabel: source)
        let wrongUnitSummary = WidgetSafeFitnessWidgetsSummary(connector: .connected, consent: .granted, strain: wrongUnit)
        XCTAssertNil(wrongUnitSummary.strain.value)
        XCTAssertEqual(wrongUnitSummary.strain.unit, .score)
        XCTAssertNil(WidgetFitnessMetric(value: 0, unit: .breathsPerMinute, state: .fresh, observedAt: now, sourceLabel: source).value)
        XCTAssertNil(WidgetFitnessMetric(value: 0, unit: .beatsPerMinute, state: .fresh, observedAt: now, sourceLabel: source).value)
        XCTAssertNil(WidgetFitnessMetric(value: 0, unit: .oxygenPercent, state: .fresh, observedAt: now, sourceLabel: source).value)
        XCTAssertNil(WidgetFitnessMetric(value: 0, unit: .celsius, state: .fresh, observedAt: now, sourceLabel: source).value)
        XCTAssertNil(WidgetFitnessMetric(value: 12, unit: .score, state: .fresh, observedAt: now, sourceLabel: nil).value)
        XCTAssertNil(WidgetFitnessMetric(value: 12, unit: .score, state: .fresh, observedAt: now, sourceLabel: "bad\nsource").value)
        XCTAssertNil(WidgetFitnessMetric(value: 12, unit: .score, state: .fresh, observedAt: now, sourceLabel: String(repeating: "x", count: 101)).value)
        let demoEnergy = WidgetEnergyReserveSummary.demo(at: now)
        XCTAssertNotNil(demoEnergy.lastChargedAt)
        let missingChargedTimestamp = WidgetEnergyReserveSummary(
            level: demoEnergy.level,
            startingLevel: demoEnergy.startingLevel,
            chargedPercent: demoEnergy.chargedPercent,
            dischargedPercent: demoEnergy.dischargedPercent,
            lastChargedAt: nil
        )
        XCTAssertNil(missingChargedTimestamp.level.value)
        let invalidEnergy = WidgetEnergyReserveSummary(
            level: demoEnergy.level,
            startingLevel: demoEnergy.startingLevel,
            chargedPercent: demoEnergy.chargedPercent,
            dischargedPercent: demoEnergy.dischargedPercent,
            lastChargedAt: Date.now.addingTimeInterval(30)
        )
        XCTAssertNil(invalidEnergy.level.value)
        XCTAssertTrue(WidgetStressTrend(
            buckets: [40, 53],
            state: .fresh,
            observedAt: now,
            sourceLabel: source,
            windowStart: now.addingTimeInterval(-18 * 60 * 60),
            windowEnd: now
        ).buckets.count == 2)
        XCTAssertTrue(WidgetStressTrend(
            buckets: [40, 53],
            state: .fresh,
            observedAt: now,
            sourceLabel: source,
            windowStart: now,
            windowEnd: now.addingTimeInterval(-1)
        ).buckets.isEmpty)
        XCTAssertTrue(WidgetStressTrend(
            buckets: [40, 53],
            state: .fresh,
            observedAt: now,
            sourceLabel: source,
            windowStart: now,
            windowEnd: Date.now.addingTimeInterval(30)
        ).buckets.isEmpty)
        XCTAssertTrue(WidgetStressTrend(
            buckets: [40, 53],
            state: .fresh,
            observedAt: now,
            sourceLabel: source,
            windowStart: now.addingTimeInterval(-2 * 365 * 24 * 60 * 60),
            windowEnd: now.addingTimeInterval(-365 * 24 * 60 * 60)
        ).buckets.isEmpty, "A stale aggregate window cannot be paired with a fresh observation")
        XCTAssertTrue(WidgetStressTrend(
            buckets: [40, 53],
            state: .fresh,
            observedAt: now,
            sourceLabel: nil,
            windowStart: now.addingTimeInterval(-18 * 60 * 60),
            windowEnd: now
        ).buckets.isEmpty)
        XCTAssertTrue(WidgetStressTrend(
            buckets: [40, 53],
            state: .fresh,
            observedAt: now,
            sourceLabel: "bad\nsource",
            windowStart: now.addingTimeInterval(-18 * 60 * 60),
            windowEnd: now
        ).buckets.isEmpty)
        XCTAssertTrue(WidgetStressTrend(
            buckets: [40, 53],
            state: .fresh,
            observedAt: now,
            sourceLabel: String(repeating: "x", count: 101),
            windowStart: now.addingTimeInterval(-18 * 60 * 60),
            windowEnd: now
        ).buckets.isEmpty)

        let encoded = try JSONEncoder.lifeOS.encode(FutureWidgetSnapshot(generatedAt: now, privacyMode: .summaryAllowed, fitnessWidgets: .demo(at: now)))
        let roundTripTrend = try XCTUnwrap(
            try JSONDecoder.lifeOS.decode(WidgetStressTrend.self, from: JSONEncoder.lifeOS.encode(WidgetStressTrend(
                buckets: [40, 45, 53],
                state: .fresh,
                observedAt: now,
                sourceLabel: source,
                windowStart: now.addingTimeInterval(-18 * 60 * 60),
                windowEnd: now
            )))
        )
        XCTAssertEqual(roundTripTrend.axisDates?.count, 4)
        let dateFormatter = ISO8601DateFormatter()
        var reversedWindow = try XCTUnwrap(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        var reversedFitness = try XCTUnwrap(reversedWindow["fitnessWidgets"] as? [String: Any])
        var reversedTrend = try XCTUnwrap(reversedFitness["stressTrend"] as? [String: Any])
        reversedTrend["windowStart"] = dateFormatter.string(from: now)
        reversedTrend["windowEnd"] = dateFormatter.string(from: now.addingTimeInterval(-1))
        reversedFitness["stressTrend"] = reversedTrend
        reversedWindow["fitnessWidgets"] = reversedFitness
        XCTAssertNil(FutureWidgetSnapshotStore.decode(
            try JSONSerialization.data(withJSONObject: reversedWindow),
            now: now
        ))
        var futureWindow = try XCTUnwrap(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        var futureFitness = try XCTUnwrap(futureWindow["fitnessWidgets"] as? [String: Any])
        var futureTrend = try XCTUnwrap(futureFitness["stressTrend"] as? [String: Any])
        futureTrend["windowStart"] = dateFormatter.string(from: now.addingTimeInterval(-18 * 60 * 60))
        futureTrend["windowEnd"] = dateFormatter.string(from: now.addingTimeInterval(10))
        futureFitness["stressTrend"] = futureTrend
        futureWindow["fitnessWidgets"] = futureFitness
        XCTAssertNil(FutureWidgetSnapshotStore.decode(
            try JSONSerialization.data(withJSONObject: futureWindow),
            now: now
        ))
        var future = try XCTUnwrap(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        var fitness = try XCTUnwrap(future["fitnessWidgets"] as? [String: Any])
        var respiration = try XCTUnwrap(fitness["respiration"] as? [String: Any])
        respiration["value"] = 0
        fitness["respiration"] = respiration
        future["fitnessWidgets"] = fitness
        XCTAssertNil(FutureWidgetSnapshotStore.decode(try JSONSerialization.data(withJSONObject: future), now: now))

        var mismatch = try XCTUnwrap(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        fitness = try XCTUnwrap(mismatch["fitnessWidgets"] as? [String: Any])
        var stressScore = try XCTUnwrap(fitness["stressScore"] as? [String: Any])
        stressScore["value"] = 12
        fitness["stressScore"] = stressScore
        mismatch["fitnessWidgets"] = fitness
        XCTAssertNil(FutureWidgetSnapshotStore.decode(try JSONSerialization.data(withJSONObject: mismatch), now: now))

        var mixed = try XCTUnwrap(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        fitness = try XCTUnwrap(mixed["fitnessWidgets"] as? [String: Any])
        var oldHeartRate = try XCTUnwrap(fitness["heartRate"] as? [String: Any])
        var futureTemperature = try XCTUnwrap(fitness["temperature"] as? [String: Any])
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        oldHeartRate["observedAt"] = formatter.string(from: now.addingTimeInterval(-(futureWidgetFreshnessWindow + 1)))
        futureTemperature["observedAt"] = formatter.string(from: now.addingTimeInterval(1))
        fitness["heartRate"] = oldHeartRate
        fitness["temperature"] = futureTemperature
        mixed["fitnessWidgets"] = fitness
        XCTAssertNil(FutureWidgetSnapshotStore.decode(try JSONSerialization.data(withJSONObject: mixed), now: now), "Mixed old and future Fitness metrics must fail closed")
    }

    func testFutureModuleStaleSummarySnapshot() {
        let now = Date()
        let observedAt = now.addingTimeInterval(-(futureWidgetFreshnessWindow + 30))
        let finance = WidgetSafeFinanceSummary(
            connector: .connected,
            consent: .granted,
            freshness: .fresh,
            observedAt: observedAt,
            netWorthCents: 90_000_00
        )
        let entry = FutureModuleWidgetEntry(
            date: now,
            snapshot: FutureWidgetSnapshot(
                generatedAt: observedAt,
                privacyMode: .summaryAllowed,
                finance: finance
            )
        )
        render(NetWorthWidgetView(entry: entry), named: "future-net-worth-stale", size: mediumSize)
        XCTAssertEqual(entry.snapshot.financeDisplayState(at: now), .stale)
    }

    func testTasksSmallAndMediumSnapshots() {
        let entry = unavailableFutureEntry
        render(TasksSmallWidgetView(entry: entry), named: "future-tasks-small", size: smallSize)
        render(TasksMediumWidgetView(entry: entry), named: "future-tasks-medium", size: mediumSize)
    }

    func testCalendarDemoSnapshot() {
        render(
            CalendarWidgetView(entry: calendarDemoEntry),
            named: "calendar-medium-demo",
            size: mediumSize,
            locale: fixedLocale
        )
    }

    func testCalendarAccentedSnapshot() {
        render(
            CalendarWidgetView(entry: calendarDemoEntry),
            named: "calendar-medium-accented",
            size: mediumSize,
            locale: fixedLocale,
            renderingMode: .accented
        )
    }

    func testCalendarEmptySnapshot() {
        render(
            CalendarWidgetView(entry: calendarEmptyEntry),
            named: "calendar-medium-empty",
            size: mediumSize,
            locale: fixedLocale
        )
    }

    func testCalendarUnavailableSnapshot() {
        render(
            CalendarWidgetView(entry: calendarUnavailableEntry),
            named: "calendar-medium-unavailable",
            size: mediumSize,
            locale: fixedLocale
        )
    }

    func testNextEventSmallDemoSnapshot() {
        render(
            NextEventWidgetView(entry: calendarDemoEntry),
            named: "next-event-small-demo",
            size: smallSize,
            locale: fixedLocale
        )
    }

    func testNextEventSmallEmptySnapshot() {
        render(
            NextEventWidgetView(entry: calendarEmptyEntry),
            named: "next-event-small-empty",
            size: smallSize,
            locale: fixedLocale
        )
    }

    func testNextEventSmallUnavailableSnapshot() {
        render(
            NextEventWidgetView(entry: calendarUnavailableEntry),
            named: "next-event-small-unavailable",
            size: smallSize,
            locale: fixedLocale
        )
    }

    private func render<V: View>(
        _ view: V,
        named name: String,
        size: CGSize,
        locale: Locale = Locale(identifier: "en_US_POSIX"),
        renderingMode: WidgetRenderingMode = .fullColor,
        colorScheme: ColorScheme = .dark,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        let calendar = fixedCalendar
        let rootView = ZStack {
            // WidgetKit normally supplies this container background. The wrapper keeps the
            // off-screen host deterministic without changing production widget backgrounds.
            LifeOSTokens.surface
            view.environment(\.widgetRenderingMode, renderingMode)
        }
        .frame(width: size.width, height: size.height)
        .environment(\.locale, locale)
        .environment(\.calendar, calendar)
        .environment(\.colorScheme, colorScheme)

        let hostingView = NSHostingView(rootView: rootView)
        hostingView.frame = NSRect(origin: .zero, size: size)
        hostingView.wantsLayer = true

        let window = NSWindow(
            contentRect: NSRect(x: -10_000, y: -10_000, width: size.width, height: size.height),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        window.isOpaque = false
        window.backgroundColor = .clear
        window.ignoresMouseEvents = true
        window.contentView = hostingView
        window.orderFront(nil)
        defer { window.orderOut(nil) }

        hostingView.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.05))
        hostingView.layoutSubtreeIfNeeded()

        let pixelWidth = Int(size.width * scale)
        let pixelHeight = Int(size.height * scale)
        guard let bitmap = NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: pixelWidth,
            pixelsHigh: pixelHeight,
            bitsPerSample: 8,
            samplesPerPixel: 4,
            hasAlpha: true,
            isPlanar: false,
            colorSpaceName: .deviceRGB,
            bitmapFormat: [],
            bytesPerRow: 0,
            bitsPerPixel: 0
        ) else {
            XCTFail("Could not allocate \(pixelWidth)x\(pixelHeight) bitmap for \(name)", file: file, line: line)
            return
        }
        bitmap.size = size
        hostingView.cacheDisplay(in: hostingView.bounds, to: bitmap)

        guard let png = bitmap.representation(using: .png, properties: [:]) else {
            XCTFail("Could not encode \(name) as PNG", file: file, line: line)
            return
        }
        XCTAssertEqual(bitmap.pixelsWide, pixelWidth, "Unexpected \(name) width", file: file, line: line)
        XCTAssertEqual(bitmap.pixelsHigh, pixelHeight, "Unexpected \(name) height", file: file, line: line)
        XCTAssertGreaterThan(png.count, 1_024, "Empty \(name) PNG", file: file, line: line)

        let attachment = XCTAttachment(uniformTypeIdentifier: "public.png", name: "\(name).png", payload: png)
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    private var fixedCalendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.locale = fixedLocale
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        calendar.firstWeekday = 2
        return calendar
    }

    private var fixedLocale: Locale {
        Locale(identifier: "en_US_POSIX")
    }
}
