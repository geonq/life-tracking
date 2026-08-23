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
public actor WidgetSnapshotPublisher {
    /// Lives in `ios/LifeOS/` rather than `ios/Shared/` because it needs
    /// `HealthKitFitnessProjection`/`HealthKitFitnessComposition`, which are
    /// app-target-only (excluded from `Shared/` for `LifeOSWidget`,
    /// `LifeOSMac`, `LifeOSMacWidget` in `project.yml`). It is only ever
    /// constructed and called from `LifeOSApp.swift`, also app-target-only.
    ///
    /// `actor` rather than a mutable struct: every call site spawns its own
    /// concurrent publish attempt (an app-active transition, a HealthKit
    /// observer completion, a Finance change can all fire within the same
    /// burst). An actor serializes those into a single mailbox, so the
    /// compare-write-reload sequence below is a true read-modify-write —
    /// only one call in a simultaneous burst of identical content actually
    /// writes and reloads. A struct mutated by independently-spawned
    /// detached tasks cannot make that guarantee: each task captures its own
    /// copy of `lastPublished` at spawn time, so a burst can race past the
    /// dedupe check and each perform a redundant write + reload.
    private let write: @Sendable (FutureWidgetSnapshot) throws -> Void
    private let reload: @Sendable () -> Void
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
        write: @escaping @Sendable (FutureWidgetSnapshot) throws -> Void = { snapshot in
            try FutureWidgetSnapshotStore.write(snapshot)
        },
        reload: @escaping @Sendable () -> Void = WidgetSnapshotPublisher.defaultReload
    ) {
        self.write = write
        self.reload = reload
        self.lastPublished = nil
    }

    @Sendable public static func defaultReload() {
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
    ///
    /// Actor-isolated, so concurrent callers queue on the actor's mailbox
    /// and this compare-write-reload sequence runs as an atomic unit per
    /// call: a burst of simultaneous identical publishes results in exactly
    /// one write + reload, not one per caller.
    @discardableResult
    public func publish(
        finance: WidgetSafeFinanceSummary,
        fitness: WidgetSafeFitnessSummary,
        fitnessWidgets: WidgetSafeFitnessWidgetsSummary,
        nutrition: WidgetSafeNutritionSummary,
        privacyMode: WidgetPrivacyMode,
        now: Date = .now,
        onWriteFailure: (@Sendable (Error) -> Void)? = nil
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
    /// Finance widget aggregates are derived only from observations already
    /// accepted by `FinanceDomain`:
    ///
    /// - net worth is the overflow-checked sum of observed account balances;
    /// - cash flow is `FinanceTransactionTotals.netCashFlowCents`, i.e. the
    ///   sum of signed observed transaction amounts.
    ///
    /// A missing transaction snapshot is not an empty ledger, so cash flow
    /// remains unavailable until at least one observed transaction is present.
    public static func mapFinance(
        summary: FinanceSummary?,
        state: FinanceLoadState,
        now: Date = .now
    ) -> WidgetSafeFinanceSummary {
        guard state == .observed || state == .stale, let summary else {
            return .unavailable()
        }

        var observedProvenance: [FinancePayloadProvenance] = []
        var spendCents: Int?
        if summary.spent.availability == .observed,
           let amount = summary.spent.amountCents,
           isUsableObservedProvenance(summary.spent.provenance) {
            spendCents = amount
            observedProvenance.append(summary.spent.provenance)
        }

        let accounts = usableObservedAccounts(from: summary)
        let netWorthCents = overflowCheckedAccountTotal(accounts)
        if !accounts.isEmpty {
            observedProvenance.append(summary.accounts!.provenance)
            observedProvenance.append(contentsOf: accounts.map(\.provenance))
        }

        var cashFlowCents: Int?
        if let transactionSnapshot = summary.transactions,
           transactionSnapshot.availability == .observed,
           let transactions = transactionSnapshot.transactions,
           !transactions.isEmpty,
           isUsableObservedProvenance(transactionSnapshot.provenance),
           transactions.allSatisfy({ isUsableObservedProvenance($0.provenance) }) {
            // FinanceTransactionTotals is the shared, reviewable rule: each
            // row is signed, so income minus spending equals signed sum.
            cashFlowCents = FinanceTransactionTotals(transactions: transactions).netCashFlowCents
            observedProvenance.append(transactionSnapshot.provenance)
            observedProvenance.append(contentsOf: transactions.map(\.provenance))
        }

        guard spendCents != nil || netWorthCents != nil || cashFlowCents != nil,
              let observedAt = observedProvenance.map(\.observedAt).min() else {
            return .unavailable()
        }

        let hasStaleEvidence = state == .stale || observedProvenance.contains {
            $0.freshness == .stale
                || $0.connectorState == .refreshDue
        }
        let freshness: WidgetSnapshotFreshness = hasStaleEvidence ? .stale : .fresh
        return WidgetSafeFinanceSummary(
            connector: .connected,
            consent: .granted,
            freshness: freshness,
            observedAt: observedAt,
            netWorthCents: netWorthCents,
            spendCents: spendCents,
            cashFlowCents: cashFlowCents
        )
    }

    private static let maximumFinanceCents = 9_007_199_254_740_991

    private static func usableObservedAccounts(from summary: FinanceSummary) -> [FinanceAccountObservation] {
        guard let snapshot = summary.accounts,
              snapshot.availability == .observed,
              isUsableObservedProvenance(snapshot.provenance),
              let accounts = snapshot.accounts,
              !accounts.isEmpty else {
            return []
        }
        return accounts.filter { isUsableObservedProvenance($0.provenance) }
    }

    private static func overflowCheckedAccountTotal(_ accounts: [FinanceAccountObservation]) -> Int? {
        guard !accounts.isEmpty else { return nil }
        var total = 0
        for account in accounts {
            let (next, overflowed) = total.addingReportingOverflow(account.balanceCents)
            guard !overflowed,
                  next >= -maximumFinanceCents,
                  next <= maximumFinanceCents else {
                return nil
            }
            total = next
        }
        return total
    }

    private static func isUsableObservedProvenance(_ provenance: FinancePayloadProvenance) -> Bool {
        provenance.quality == .observed
            && provenance.freshness != .unknown
            && (provenance.connectorState == .healthy || provenance.connectorState == .refreshDue)
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
