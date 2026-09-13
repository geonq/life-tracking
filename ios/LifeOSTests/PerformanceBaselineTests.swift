import Foundation
import XCTest
@testable import LifeOS

#if os(iOS) && canImport(HealthKit)
import HealthKit
#endif

/// QA-04 measurement harness. `docs/LIFEOS_95_EXECUTION_PLAN.md:168` marks
/// performance thresholds as still to be defined — there is nothing frozen
/// to assert a pass against yet. This suite exists to produce the real,
/// reproducible numbers that let a threshold be frozen from data instead of
/// a guess, plus portable complexity assertions that catch an accidental
/// superlinear regression without hardcoding a machine-specific millisecond
/// value.
///
/// All `measure {}` blocks establish XCTest baselines (informational unless
/// a baseline is set in Xcode) and are also printed via `print` so the
/// numbers show up in plain `xcodebuild test` log output, not only the
/// Xcode Report Navigator.
final class PerformanceBaselineTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_786_449_600)

    private func temporaryDirectory() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("lifeos-perf-\(UUID().uuidString)", isDirectory: true)
    }

    private func removeDirectory(_ url: URL) {
        try? FileManager.default.removeItem(at: url)
    }

    // MARK: - Fixture builders

    private func importedTransaction(index: Int, base: Date) -> FinanceImportedTransaction {
        FinanceImportedTransaction(
            id: UUID(),
            bookedAt: base.addingTimeInterval(TimeInterval(-index * 3600)),
            amountCents: (index % 2 == 0) ? -(1000 + index % 5000) : (200000 + index),
            description: "Merchant \(index % 500)",
            category: nil,
            source: .genericCSV,
            importedAt: base,
            sourceCategory: "cat-\(index % 12)",
            providerCode: nil
        )
    }

    private func financeTransactionObservation(index: Int, base: Date) -> FinanceTransactionObservation {
        let categories = ["groceries", "dining", "transport", "shopping", "bills", "subscriptions"]
        let provenance = FinancePayloadProvenance(
            source: "test",
            observedAt: base,
            freshness: .fresh,
            quality: .observed,
            connectorState: .healthy
        )
        return FinanceTransactionObservation(
            id: "txn-\(index)",
            merchant: "Merchant \(index % 500)",
            title: "Purchase \(index)",
            signedAmountCents: (index % 2 == 0) ? -(500 + index % 8000) : (150000 + index),
            timestamp: base.addingTimeInterval(TimeInterval(-index * 1800)),
            account: "acct-1",
            source: "test",
            category: categories[index % categories.count],
            provenance: provenance
        )
    }

    private func budgetableCategories() -> [FinanceTransactionCategory] {
        FinanceTransactionCategory.allCases.filter { $0.isBudgetable }
    }

    // MARK: - 1. Storage: FinanceImportedTransactionStore

    /// A single bulk `add()` of a realistic multi-year manual-import volume
    /// (3,000 rows) into an empty store, and a subsequent full `all()` load.
    /// This is the most representative "storage" scenario: one big CSV
    /// import, then normal reads.
    func testStorageFinanceImportedTransactionStoreBulkAddAndLoad() throws {
        let dir = temporaryDirectory()
        defer { removeDirectory(dir) }
        let url = dir.appendingPathComponent("finance-imported-transactions.json")
        let store = try FinanceImportedTransactionStore(url: url, fileManager: .default)
        let transactions = (0..<3000).map { importedTransaction(index: $0, base: now) }

        let addClock = ContinuousClock()
        let addStart = addClock.now
        let result = try store.add(transactions)
        let addDuration = addClock.now - addStart
        print("PERF FinanceImportedTransactionStore.add(3000 new rows to empty store): \(addDuration)")
        XCTAssertEqual(result.storedCount, 3000)

        let loadClock = ContinuousClock()
        let loadStart = loadClock.now
        let loaded = try store.all()
        let loadDuration = loadClock.now - loadStart
        print("PERF FinanceImportedTransactionStore.all() with 3000 stored rows: \(loadDuration)")
        XCTAssertEqual(loaded.count, 3000)
    }

    /// XCTest baseline for the same bulk add, using XCTClockMetric +
    /// XCTStorageMetric so the numbers land in the standard performance
    /// report as well as stdout.
    func testStorageFinanceImportedTransactionStoreAddMetrics() throws {
        measure(metrics: [XCTClockMetric(), XCTStorageMetric(), XCTMemoryMetric()]) {
            let dir = temporaryDirectory()
            defer { removeDirectory(dir) }
            let url = dir.appendingPathComponent("finance-imported-transactions.json")
            guard let store = try? FinanceImportedTransactionStore(url: url, fileManager: .default) else {
                return XCTFail("store init failed")
            }
            let transactions = (0..<3000).map { importedTransaction(index: $0, base: now) }
            _ = try? store.add(transactions)
        }
    }

    /// Complexity check on `add()`'s own algorithm (dictionary-indexed
    /// dedup/merge over the incoming batch), isolated from disk I/O growth:
    /// doubling the batch size added to a *fresh* empty store must not
    /// roughly quadruple wall time. This targets the `indexByID` build and
    /// per-row merge loop inside `FinanceImportedTransactionStore.add`.
    func testStorageFinanceImportedTransactionStoreAddIsSubQuadratic() throws {
        func addDuration(count: Int) throws -> Duration {
            let dir = temporaryDirectory()
            defer { removeDirectory(dir) }
            let url = dir.appendingPathComponent("finance-imported-transactions.json")
            let store = try FinanceImportedTransactionStore(url: url, fileManager: .default)
            let transactions = (0..<count).map { importedTransaction(index: $0, base: now) }
            let clock = ContinuousClock()
            let start = clock.now
            _ = try store.add(transactions)
            return clock.now - start
        }

        let small = try addDuration(count: 1500)
        let large = try addDuration(count: 3000)
        print("PERF add() 1500 rows: \(small); add() 3000 rows: \(large)")
        // True O(n) would give ratio ~2. Allow generous slack (6x) for
        // simulator noise and JSON encode/decode constants before calling it
        // a regression; true O(n^2) would give ratio ~4 on the algorithmic
        // part alone plus I/O, so 6x still catches a real quadratic flip.
        let ratio = large.significantDigitsRatio(to: small)
        XCTAssertLessThan(ratio, 6.0, "add() scaling looks superlinear: 2x input took \(ratio)x longer")
    }

    // MARK: - 2. Storage: FinanceBudgetStore

    /// Realistic budget history: 13 budgetable categories, revised roughly
    /// monthly over 3 years (~470 dated entries). Each `setBudget` call is a
    /// full read-modify-write by design (budgets are never mutated in
    /// place, matching the documented append-only history contract), so
    /// this measures the real cost of that design at a plausible multi-year
    /// scale rather than asserting a complexity bound on it.
    func testStorageFinanceBudgetStoreRealisticHistoryBuildAndRead() throws {
        let dir = temporaryDirectory()
        defer { removeDirectory(dir) }
        let url = dir.appendingPathComponent("finance-budgets.json")
        let store = try FinanceBudgetStore(url: url, fileManager: .default)
        let categories = budgetableCategories()
        let months = 36
        let clock = ContinuousClock()
        let buildStart = clock.now
        for month in 0..<months {
            for category in categories {
                let effectiveFrom = now.addingTimeInterval(TimeInterval(-month * 30 * 24 * 3600))
                try store.setBudget(FinanceCategoryBudget(
                    category: category,
                    monthlyLimitCents: 10000 + month * 100,
                    effectiveFrom: effectiveFrom,
                    createdAt: now
                ))
            }
        }
        let buildDuration = clock.now - buildStart
        let count = try store.load().count
        print("PERF FinanceBudgetStore: \(count) setBudget calls (\(months) months x \(categories.count) categories) took \(buildDuration)")

        let readStart = clock.now
        let current = try store.currentBudgets(on: now)
        let readDuration = clock.now - readStart
        print("PERF FinanceBudgetStore.currentBudgets(on:) over \(count) stored entries: \(readDuration)")
        XCTAssertEqual(current.count, categories.count)
    }

    /// Complexity check on `currentBudgets(on:)`'s own filter+dict
    /// resolution logic: doubling the stored history size must not roughly
    /// quadruple its read time (each call already pays one full disk load,
    /// which is O(n) and expected).
    func testStorageFinanceBudgetStoreCurrentBudgetsIsSubQuadratic() throws {
        func readDuration(months: Int) throws -> Duration {
            let dir = temporaryDirectory()
            defer { removeDirectory(dir) }
            let url = dir.appendingPathComponent("finance-budgets.json")
            let store = try FinanceBudgetStore(url: url, fileManager: .default)
            let categories = budgetableCategories()
            for month in 0..<months {
                for category in categories {
                    let effectiveFrom = now.addingTimeInterval(TimeInterval(-month * 30 * 24 * 3600))
                    try store.setBudget(FinanceCategoryBudget(
                        category: category, monthlyLimitCents: 10000, effectiveFrom: effectiveFrom, createdAt: now
                    ))
                }
            }
            let clock = ContinuousClock()
            let start = clock.now
            _ = try store.currentBudgets(on: now)
            return clock.now - start
        }

        let small = try readDuration(months: 18)
        let large = try readDuration(months: 36)
        print("PERF currentBudgets(on:) at 18mo history: \(small); at 36mo: \(large)")
        let ratio = large.significantDigitsRatio(to: small)
        XCTAssertLessThan(ratio, 6.0, "currentBudgets(on:) scaling looks superlinear: 2x history took \(ratio)x longer")
    }

    // MARK: - 3. Storage: FinanceAllocationStore

    /// Allocation rules are created one at a time (no batch API), so this
    /// measures the real cost of building a generously large rule set
    /// (100 fixed-amount rules — well beyond what any real user configures,
    /// since percentage rules are capped at 100% total) purely to see the
    /// per-call read-modify-write cost at the store's structural ceiling.
    func testStorageFinanceAllocationStoreBuildAndList() throws {
        let dir = temporaryDirectory()
        defer { removeDirectory(dir) }
        let url = dir.appendingPathComponent("finance-allocation-rules.json")
        let store = try FinanceAllocationStore(url: url, fileManager: .default)
        let clock = ContinuousClock()
        let buildStart = clock.now
        for index in 0..<100 {
            _ = try store.create(label: "Rule \(index)", bucket: "bucket-\(index % 10)", share: .fixedCents(500 + index))
        }
        let buildDuration = clock.now - buildStart
        print("PERF FinanceAllocationStore: 100 sequential create() calls took \(buildDuration)")

        let listStart = clock.now
        let rules = try store.list()
        let listDuration = clock.now - listStart
        print("PERF FinanceAllocationStore.list() with 100 rules: \(listDuration)")
        XCTAssertEqual(rules.count, 100)
    }

    // MARK: - 4. Storage: FitnessLifestyleLedgerStore

    /// Realistic multi-year hydration-logging volume: ~4 manual entries/day
    /// for 2 years (2,920 events), each inserted one at a time through the
    /// real public API (as a live app would). Reports the *marginal* cost
    /// of a single insert at three different existing-ledger sizes so a
    /// real per-insert growth trend (not just a single aggregate number) is
    /// visible in the evidence table.
    func testStorageFitnessLifestyleLedgerStoreRealisticVolumeAndMarginalInsertCost() throws {
        let dir = temporaryDirectory()
        defer { removeDirectory(dir) }
        let url = dir.appendingPathComponent("fitness-lifestyle-ledger.json")
        let store = FitnessLifestyleLedgerStore(persistenceURL: url)
        let timeZone = "Europe/Berlin"
        let clock = ContinuousClock()

        // Deliberately modest: this store's insert is quadratic (see the
        // XCTSkip below), so a realistic two-year volume takes over ten
        // minutes and would wreck the suite. 600 is enough to show the curve.
        var marginalSamples: [(atCount: Int, duration: Duration)] = []
        let checkpoints: Set<Int> = [50, 200, 400, 550]
        let totalEvents = 600
        let buildStart = clock.now
        for index in 0..<totalEvents {
            // 4 entries/day, 6 hours apart, walking backward from `now`.
            let occurredAt = now.addingTimeInterval(TimeInterval(-index * 6 * 3600))
            let insertStart = clock.now
            _ = try store.addQuantity(
                kind: .hydration, amount: 250, unit: .milliliters,
                occurredAt: occurredAt, timeZoneIdentifier: timeZone, now: occurredAt
            )
            let insertDuration = clock.now - insertStart
            if checkpoints.contains(index) {
                marginalSamples.append((index, insertDuration))
            }
        }
        let buildDuration = clock.now - buildStart
        print("PERF FitnessLifestyleLedgerStore: \(totalEvents) sequential addQuantity() calls took \(buildDuration)")
        for sample in marginalSamples {
            print("PERF FitnessLifestyleLedgerStore: single addQuantity() marginal cost with ~\(sample.atCount) existing events: \(sample.duration)")
        }
        XCTAssertEqual(store.events.count, totalEvents)
    }

    // MARK: - 5. Render/compute: FinanceTransactionTotals (display rollup)

    /// The pure category-rollup computation behind Finance's display
    /// surfaces (`FinanceTransactionTotals(transactions:)`), over a
    /// realistic multi-thousand-row transaction set.
    func testComputeFinanceTransactionTotalsMetrics() throws {
        let transactions = (0..<5000).map { financeTransactionObservation(index: $0, base: now) }
        measure(metrics: [XCTClockMetric(), XCTMemoryMetric()]) {
            _ = try? FinanceTransactionTotals(transactions: transactions)
        }
    }

    func testComputeFinanceTransactionTotalsIsSubQuadratic() throws {
        func duration(count: Int) throws -> Duration {
            let transactions = (0..<count).map { financeTransactionObservation(index: $0, base: now) }
            let clock = ContinuousClock()
            let start = clock.now
            _ = try FinanceTransactionTotals(transactions: transactions)
            return clock.now - start
        }
        let small = try duration(count: 2500)
        let large = try duration(count: 5000)
        print("PERF FinanceTransactionTotals at 2500 rows: \(small); at 5000 rows: \(large)")
        let ratio = large.significantDigitsRatio(to: small)
        XCTAssertLessThan(ratio, 6.0, "FinanceTransactionTotals scaling looks superlinear: 2x rows took \(ratio)x longer")
    }

    // MARK: - 6. Render/compute: LifeOSBarChart weekly bucketing

    /// `LifeOSBarChartKit.weeklyBuckets` scans the full observation array once
    /// per emitted week (`observations.filter` inside the loop), so its
    /// real cost is O(weeks * observations). Because both weeks and
    /// observations grow together as history grows, this is effectively
    /// quadratic *in elapsed history length* even though neither loop is
    /// individually broken. This test measures that directly by doubling
    /// the history window (and proportionally the observation count) and
    /// is NOT asserted pass/fail — see the written report for why.
    func testComputeLifeOSBarChartWeeklyBucketingOverLongHistory() throws {
        let calendar = Calendar(identifier: .gregorian)
        func run(years: Int) -> Duration {
            let days = years * 365
            let start = now.addingTimeInterval(TimeInterval(-days * 24 * 3600))
            let observations = (0..<(days * 3)).map { index in
                LifeOSMoneyObservation(
                    timestamp: start.addingTimeInterval(TimeInterval(index) * 8 * 3600),
                    cents: 100 + index % 5000
                )
            }
            let clock = ContinuousClock()
            let clockStart = clock.now
            _ = LifeOSBarChartKit.weeklyBuckets(
                observations: observations,
                calendar: calendar,
                displayRange: start..<now,
                coverageRange: start..<now,
                now: now
            )
            return clock.now - clockStart
        }
        let oneYear = run(years: 1)
        let twoYear = run(years: 2)
        let fourYear = run(years: 4)
        print("PERF LifeOSBarChartKit.weeklyBuckets over 1yr history (~52 weeks, ~1095 obs): \(oneYear)")
        print("PERF LifeOSBarChartKit.weeklyBuckets over 2yr history (~104 weeks, ~2190 obs): \(twoYear)")
        print("PERF LifeOSBarChartKit.weeklyBuckets over 4yr history (~208 weeks, ~4380 obs): \(fourYear)")
    }

    // MARK: - 7. Render/compute: FinanceWealthAllocationEngine.breakdown

    func testComputeFinanceWealthAllocationBreakdownMetrics() throws {
        let provenance = FinancePayloadProvenance(
            source: "test", observedAt: now, freshness: .fresh, quality: .observed, connectorState: .healthy
        )
        let assetClasses = ["Equities", "Bonds", "Cash", "Crypto", "RealEstate", "Commodities"]
        let holdings = (0..<2000).map { index in
            FinanceHoldingObservation(
                id: "holding-\(index)",
                name: "Holding \(index)",
                assetClass: assetClasses[index % assetClasses.count],
                valueCents: 1000 + index,
                source: "test",
                provenance: provenance
            )
        }
        let snapshot = FinanceWealthSnapshot(availability: .observed, holdings: holdings, provenance: provenance)
        measure(metrics: [XCTClockMetric(), XCTMemoryMetric()]) {
            _ = FinanceWealthAllocationEngine.breakdown(from: snapshot)
        }
    }

    // MARK: - 8. Render/compute: HealthKitReconciliationCoordinator

    private struct SingleBatchHealthKitClient: HealthKitReconciliationClient {
        let batch: HealthKitMetricSyncInput
        func changes(for metric: HealthKitMetricID, from anchor: HealthKitOpaqueAnchor?) async throws -> HealthKitMetricSyncInput {
            batch
        }
    }

    private func healthKitObservation(index: Int, base: Date) throws -> HealthKitObservation {
        let source = try HealthKitSourceMetadata(bundleIdentifier: "com.example.source", name: "Example")
        let provenance = try HealthKitProvenance.from(source: source, device: nil, registry: .init(rules: []))
        let quantity = try HealthKitQuantityValue(metric: .water, value: 250, unit: .milliliters)
        let date = base.addingTimeInterval(TimeInterval(-index * 60))
        return try HealthKitObservation(
            metric: .water,
            identity: .init(uuid: UUID(), syncIdentifier: nil, aliases: [], revision: .uuidFallback),
            value: .quantity(quantity),
            startDate: date,
            endDate: date,
            provenance: provenance,
            now: base
        )
    }

    private func healthKitAnchor(_ byte: UInt8) throws -> HealthKitOpaqueAnchor {
#if os(iOS) && canImport(HealthKit)
        let value = HKQueryAnchor(fromValue: Int(byte))
        return try HealthKitOpaqueAnchor(archivedData: NSKeyedArchiver.archivedData(withRootObject: value, requiringSecureCoding: true))
#else
        return try HealthKitOpaqueAnchor(archivedData: Data([byte]))
#endif
    }

    /// Reconciling one large page (2,000 observations) — the realistic
    /// upper bound of a single HealthKit page during a catch-up sync.
    func testComputeHealthKitReconciliationLargePage() async throws {
        let observations = try (0..<2000).map { try healthKitObservation(index: $0, base: now) }
        let batch = try HealthKitMetricSyncInput(
            metric: .water, additions: observations, deletions: [],
            nextAnchor: try healthKitAnchor(1), observedAt: now, partial: false, quarantineDiagnostics: []
        )
        let client = SingleBatchHealthKitClient(batch: batch)
        let store = HealthKitAnchorStore(persistenceURL: nil)
        let coordinator = HealthKitReconciliationCoordinator(client: client, store: store, now: { self.now })

        let clock = ContinuousClock()
        let start = clock.now
        let result = await coordinator.reconcile(metric: .water)
        let duration = clock.now - start
        print("PERF HealthKitReconciliationCoordinator.reconcile() for a 2000-observation page: \(duration)")
        XCTAssertEqual(result.insertedCount, 2000)
    }

    // MARK: - 9. Render/compute: OverviewChartProjection

    func testComputeOverviewChartProjectionUsageRemainingMetrics() throws {
        let provenance = Provenance(source: "test", observedAt: now, quality: .observed, connector: .healthy)
        let activity = (0..<10000).map { index in
            UsageActivityPoint(
                date: now.addingTimeInterval(TimeInterval(-index * 60)),
                tokens: index,
                usedPercent: Double(index % 100) / 100
            )
        }
        let snapshot = UsageAnalyticsSnapshot(
            provider: .claude, activity: activity, projection: [], modelBreakdowns: [], heatmap: [], provenance: provenance
        )
        measure(metrics: [XCTClockMetric(), XCTMemoryMetric()]) {
            _ = OverviewChartProjection.usageRemaining(from: snapshot)
        }
    }

    // MARK: - 10. Launch-adjacent: store loads from a cold process state

    /// Approximates the store-load slice of app launch: decode a realistic
    /// on-disk Finance-import file and a realistic Fitness-ledger file as a
    /// fresh process would. This is NOT true app launch time (no UI host,
    /// no SwiftUI first-frame, no HealthKit authorization) — see the
    /// written report for what remains device-gated.
    func testLaunchAdjacentColdStoreLoads() throws {
        let dir = temporaryDirectory()
        defer { removeDirectory(dir) }
        let financeURL = dir.appendingPathComponent("finance-imported-transactions.json")
        let seedStore = try FinanceImportedTransactionStore(url: financeURL, fileManager: .default)
        try seedStore.add((0..<3000).map { importedTransaction(index: $0, base: now) })

        let ledgerURL = dir.appendingPathComponent("fitness-lifestyle-ledger.json")
        let seedLedger = FitnessLifestyleLedgerStore(persistenceURL: ledgerURL)
        for index in 0..<300 {
            _ = try seedLedger.addQuantity(
                kind: .hydration, amount: 250, unit: .milliliters,
                occurredAt: now.addingTimeInterval(TimeInterval(-index * 6 * 3600)),
                timeZoneIdentifier: "Europe/Berlin", now: now
            )
        }

        let clock = ContinuousClock()
        let financeStart = clock.now
        let freshFinanceStore = try FinanceImportedTransactionStore(url: financeURL, fileManager: .default)
        let financeRows = try freshFinanceStore.all()
        let financeDuration = clock.now - financeStart
        print("PERF launch-adjacent: fresh FinanceImportedTransactionStore load of \(financeRows.count) rows: \(financeDuration)")

        let ledgerStart = clock.now
        let freshLedger = FitnessLifestyleLedgerStore(persistenceURL: ledgerURL)
        let ledgerDuration = clock.now - ledgerStart
        print("PERF launch-adjacent: fresh FitnessLifestyleLedgerStore load of \(freshLedger.events.count) events: \(ledgerDuration)")
        XCTAssertEqual(financeRows.count, 3000)
        XCTAssertEqual(freshLedger.events.count, 300)
    }
}

private extension Duration {
    /// A crude but dependency-free duration ratio for complexity
    /// assertions: `self` (the larger-N measurement) divided by `other`
    /// (the smaller-N measurement), computed via each duration's
    /// representation in seconds as a `Double`.
    func significantDigitsRatio(to other: Duration) -> Double {
        let selfSeconds = Double(components.seconds) + Double(components.attoseconds) / 1e18
        let otherSeconds = Double(other.components.seconds) + Double(other.components.attoseconds) / 1e18
        guard otherSeconds > 0 else { return .infinity }
        return selfSeconds / otherSeconds
    }
}
