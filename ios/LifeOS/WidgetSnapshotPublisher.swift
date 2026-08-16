import Foundation
#if canImport(WidgetKit)
import WidgetKit
#endif

/// Maps confirmed app state into `FutureWidgetSnapshot`, writes it through
/// `FutureWidgetSnapshotStore`, and requests a coalesced widget-timeline
/// reload.
///
/// This type is deliberately dumb about privacy/fixture gating: it maps
/// exactly the inputs it is given and trusts its caller. The caller
/// (`LifeOSApp`) is the single gate that decides whether to invoke `publish`
/// at all — production real-data publishing must never run while
/// `-LifeOSVisualFixtures` is active, and this type has no way to know that
/// on its own, so it does not try to guess it. See `LifeOSApp.swift` for the
/// exact call sites.
///
/// A missing/unobserved metric always maps to that field's `.unavailable()`
/// factory, never to zero or an estimate. Where this codebase currently has
/// no producer for a widget field at all (Finance net worth/cash flow,
/// Fitness health/recovery/strain scores, most `WidgetSafeFitnessWidgetsSummary`
/// fields), the mapping functions below say so in a comment next to the
/// permanent `.unavailable()` they return.
public struct WidgetSnapshotPublisher {
    /// Lives in `ios/LifeOS/` rather than `ios/Shared/` because it needs
    /// `HealthKitFitnessProjection`/`HealthKitFitnessComposition`, which are
    /// app-target-only (excluded from `Shared/` for `LifeOSWidget`,
    /// `LifeOSMac`, `LifeOSMacWidget` in `project.yml`). It is only ever
    /// constructed and called from `LifeOSApp.swift`, also app-target-only.
    private let write: (FutureWidgetSnapshot) throws -> Void
    private let reload: () -> Void
    private var lastPublished: FutureWidgetSnapshot?

    /// The future-module widget kinds that share `FutureModuleTimelineProvider`
    /// in `ios/LifeOSWidget/FutureModuleWidgets.swift`. Reloaded together as
    /// one batch since they all read the same `FutureWidgetSnapshot`.
    public static let widgetKinds: [String] = [
        "NetWorthWidget",
        "SpendRingWidget",
        "CashFlowWidget",
        "HealthMonitorWidget",
        "RecoveryRingWidget",
        "TasksWidget",
        "NutritionOverviewWidget",
        "CaloriesMacrosWidget",
        "NetEnergyWidget",
        "DailyOverviewWidget",
        "FitnessHealthMonitorWidget",
        "FitnessStressWidget",
        "FitnessEnergyReserveWidget"
    ]

    public init(
        write: @escaping (FutureWidgetSnapshot) throws -> Void = { snapshot in
            try FutureWidgetSnapshotStore.write(snapshot)
        },
        reload: @escaping () -> Void = WidgetSnapshotPublisher.defaultReload
    ) {
        self.write = write
        self.reload = reload
        self.lastPublished = nil
    }

    public static func defaultReload() {
#if canImport(WidgetKit)
        for kind in widgetKinds {
            WidgetCenter.shared.reloadTimelines(ofKind: kind)
        }
#endif
    }

    /// Maps the given inputs, writes the result only if it differs from the
    /// last published snapshot (ignoring `generatedAt`, which changes on
    /// every call even when nothing observed did), and requests a reload
    /// only on that same condition. A write failure is swallowed after being
    /// reported through `onWriteFailure` — a widget staying on its last good
    /// snapshot is the correct honest fallback, not a crash.
    @discardableResult
    public mutating func publish(
        finance: WidgetSafeFinanceSummary,
        fitness: WidgetSafeFitnessSummary,
        fitnessWidgets: WidgetSafeFitnessWidgetsSummary,
        nutrition: WidgetSafeNutritionSummary,
        privacyMode: WidgetPrivacyMode,
        now: Date = .now,
        onWriteFailure: ((Error) -> Void)? = nil
    ) -> Bool {
        let candidate = FutureWidgetSnapshot(
            generatedAt: now,
            privacyMode: privacyMode,
            finance: finance,
            fitness: fitness,
            fitnessWidgets: fitnessWidgets,
            nutrition: nutrition
        )
        if let lastPublished, Self.contentEquals(candidate, lastPublished) {
            return false
        }
        do {
            try write(candidate)
        } catch {
            onWriteFailure?(error)
            return false
        }
        lastPublished = candidate
        reload()
        return true
    }

    /// Compares every field except `generatedAt`, which is expected to
    /// differ on every call. `FutureWidgetSnapshot`'s synthesized `Equatable`
    /// includes `generatedAt`, so a direct `==` would defeat coalescing.
    private static func contentEquals(_ a: FutureWidgetSnapshot, _ b: FutureWidgetSnapshot) -> Bool {
        a.privacyMode == b.privacyMode
            && a.finance == b.finance
            && a.fitness == b.fitness
            && a.fitnessWidgets == b.fitnessWidgets
            && a.nutrition == b.nutrition
    }
}

// MARK: - Mapping: Finance

extension WidgetSnapshotPublisher {
    /// `FinanceSummary` has no net-worth or cash-flow field, and no app-side
    /// code derives either from it (verified: the only `netWorth` usage in
    /// the app is `FinanceView`'s own `FinanceDisplayMetric`, built from a
    /// separate, more detailed account model that `FinanceCoordinator` does
    /// not expose). Both stay permanently unavailable rather than guessing a
    /// formula. Only `spendCents` has a direct, honest source.
    public static func mapFinance(
        summary: FinanceSummary?,
        state: FinanceLoadState,
        now: Date = .now
    ) -> WidgetSafeFinanceSummary {
        guard state == .observed || state == .stale,
              let summary,
              summary.spent.availability == .observed,
              let spendCents = summary.spent.amountCents else {
            return .unavailable()
        }
        let observedAt = summary.spent.provenance.observedAt
        let freshness: WidgetSnapshotFreshness = summary.spent.provenance.freshness == .stale || state == .stale
            ? .stale
            : .fresh
        return WidgetSafeFinanceSummary(
            connector: .connected,
            consent: .granted,
            freshness: freshness,
            observedAt: observedAt,
            netWorthCents: nil,
            spendCents: spendCents,
            cashFlowCents: nil
        )
    }
}

// MARK: - Mapping: Fitness (aggregate scores)

#if os(iOS)
extension WidgetSnapshotPublisher {
    /// `WidgetSafeFitnessSummary.healthScore/recoveryScore/strainScore` have
    /// no producer anywhere in this codebase: `HealthKitMetricID` has no
    /// score-shaped case, and no app-side composition calculates one. This
    /// permanently maps to fully unavailable. It takes a projection
    /// parameter only so the call site does not need a special case, and so
    /// a future regression that starts fabricating a score here is visible
    /// as a diff against this comment, not a silent behavior change.
    public static func mapFitness(
        projection: HealthKitFitnessProjection?,
        now: Date = .now
    ) -> WidgetSafeFitnessSummary {
        .unavailable()
    }
}

// MARK: - Mapping: Fitness widgets (per-metric detail)

extension WidgetSnapshotPublisher {
    /// Maps the subset of `WidgetSafeFitnessWidgetsSummary` that has a real
    /// HealthKit producer: heart rate, HRV, respiration, SpO2, and sleep
    /// duration. `strain`, `recovery`, `sleepScore`, `temperature`,
    /// `stressScore`, `stressTrend`, and `energyReserve` have no HealthKit
    /// metric or app-side calculation backing them (confirmed: no body
    /// temperature, sleep/recovery/strain/stress score exists in
    /// `HealthKitMetricID` or `HealthKitFitnessComposition`) and stay
    /// permanently unavailable.
    public static func mapFitnessWidgets(
        projection: HealthKitFitnessProjection?,
        selectedDate: Date = .now,
        now: Date = .now
    ) -> WidgetSafeFitnessWidgetsSummary {
        guard let projection else { return .unavailable() }

        func metric(
            _ projectionMetric: HealthKitFitnessMetricProjection,
            unit: WidgetFitnessMetricUnit,
            sourceLabel: String
        ) -> WidgetFitnessMetric {
            guard projectionMetric.state == .observed,
                  let latest = projectionMetric.latest else {
                return .unavailable(unit: unit)
            }
            return WidgetFitnessMetric(
                value: latest.quantity.value,
                unit: unit,
                state: .fresh,
                observedAt: latest.endDate,
                sourceLabel: sourceLabel
            )
        }

        let heartRate = metric(projection.restingHeartRate, unit: .beatsPerMinute, sourceLabel: "HealthKit")
        let hrv = metric(projection.hrv, unit: .milliseconds, sourceLabel: "HealthKit")
        let respiration = metric(projection.respiratoryRate, unit: .breathsPerMinute, sourceLabel: "HealthKit")
        let spo2 = metric(projection.oxygenSaturation, unit: .oxygenPercent, sourceLabel: "HealthKit")

        let sleepDuration: WidgetFitnessMetric
        if let derived = HealthKitFitnessComposition.sourceDerivedSleepDurationHours(
            from: projection,
            selectedDate: selectedDate
        ) {
            sleepDuration = WidgetFitnessMetric(
                value: derived.hours,
                unit: .hours,
                state: .fresh,
                observedAt: derived.observedAt,
                sourceLabel: "HealthKit"
            )
        } else {
            sleepDuration = .unavailable(unit: .hours)
        }

        let hasAnyValue = [heartRate, hrv, respiration, spo2, sleepDuration].contains { $0.value != nil }
        guard hasAnyValue else { return .unavailable() }

        return WidgetSafeFitnessWidgetsSummary(
            connector: .connected,
            consent: .granted,
            sleepDuration: sleepDuration,
            respiration: respiration,
            heartRate: heartRate,
            hrv: hrv,
            spo2: spo2,
            provenanceLabel: "HealthKit"
        )
    }
}
#else
extension WidgetSnapshotPublisher {
    /// `HealthKitFitnessRepository`/`HealthKitFitnessComposition` are
    /// iOS-only (no HealthKit on macOS). Mac publishes Finance and Nutrition
    /// only; Fitness stays permanently unavailable on this platform.
    public static func mapFitness(now: Date = .now) -> WidgetSafeFitnessSummary {
        .unavailable()
    }

    public static func mapFitnessWidgets(now: Date = .now) -> WidgetSafeFitnessWidgetsSummary {
        .unavailable()
    }
}
#endif

// MARK: - Mapping: Nutrition

extension WidgetSnapshotPublisher {
    /// Reads `NutritionMealStore`/`NutritionGoalStore` synchronously (both
    /// are cheap local file reads per their own documentation, no different
    /// from any other durable-store `load()`). `caloriesBurned` and
    /// `qualityScore`/`qualityLabel` have no source here and stay
    /// unavailable. `observedAt` per macro is the latest `loggedAt` among the
    /// day's contributing meals — not "now", since that would misrepresent
    /// when the value was actually observed.
    public static func mapNutrition(
        mealStore: NutritionMealStore,
        goalStore: NutritionGoalStore,
        on date: Date,
        calendar: Calendar = .current
    ) -> WidgetSafeNutritionSummary {
        guard let dayMeals = try? mealStore.meals(on: date, calendar: calendar),
              !dayMeals.isEmpty,
              let totals = try? mealStore.dailyTotals(on: date, calendar: calendar) else {
            return .unavailable()
        }
        let goal = try? goalStore.currentGoal(on: date, calendar: calendar)
        let latestLoggedAt = dayMeals.map(\.loggedAt).max()

        func eaten(_ value: Int?) -> WidgetNutritionMetric {
            guard let value, let observedAt = latestLoggedAt else { return .unavailable() }
            return WidgetNutritionMetric(
                value: Double(value),
                state: .fresh,
                observedAt: observedAt,
                sourceLabel: "Nutrition log"
            )
        }
        func target(_ value: Int?) -> WidgetNutritionMetric {
            // A goal has no "observed at" moment the way a logged meal does;
            // use the same latest-meal timestamp so the pair renders with a
            // consistent freshness label instead of a fabricated instant.
            guard let value, let observedAt = latestLoggedAt else { return .unavailable() }
            return WidgetNutritionMetric(
                value: Double(value),
                state: .fresh,
                observedAt: observedAt,
                sourceLabel: "Nutrition goal"
            )
        }

        let caloriesEaten = eaten(totals.kcal)
        let fatGrams = eaten(totals.fatGrams)
        let carbsGrams = eaten(totals.carbGrams)
        let proteinGrams = eaten(totals.proteinGrams)
        let calorieGoal = target(goal?.calorieTarget)
        let fatGoalGrams = target(goal?.fatGramsTarget)
        let carbsGoalGrams = target(goal?.carbGramsTarget)
        let proteinGoalGrams = target(goal?.proteinGramsTarget)

        let hasAnyValue = [caloriesEaten, fatGrams, carbsGrams, proteinGrams,
                            calorieGoal, fatGoalGrams, carbsGoalGrams, proteinGoalGrams]
            .contains { $0.value != nil }
        guard hasAnyValue else { return .unavailable() }

        return WidgetSafeNutritionSummary(
            connector: .connected,
            consent: .granted,
            caloriesEaten: caloriesEaten,
            calorieGoal: calorieGoal,
            fatGrams: fatGrams,
            fatGoalGrams: fatGoalGrams,
            carbsGrams: carbsGrams,
            carbsGoalGrams: carbsGoalGrams,
            proteinGrams: proteinGrams,
            proteinGoalGrams: proteinGoalGrams,
            provenanceLabel: "Nutrition log"
        )
    }
}
