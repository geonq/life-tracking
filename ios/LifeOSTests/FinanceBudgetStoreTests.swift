import Foundation
import XCTest
@testable import LifeOS

final class FinanceBudgetStoreTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_786_449_600)

    private func temporaryURL() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("lifeos-finance-budget-store-\(UUID().uuidString)", isDirectory: true)
            .appendingPathComponent("finance-budgets.json", isDirectory: false)
    }

    private func removeStore(at url: URL) {
        try? FileManager.default.removeItem(at: url.deletingLastPathComponent())
    }

    private func budget(
        category: FinanceTransactionCategory = .groceries,
        limitCents: Int = 30_000,
        effectiveFrom: Date? = nil
    ) -> FinanceCategoryBudget {
        FinanceCategoryBudget(
            category: category,
            monthlyLimitCents: limitCents,
            effectiveFrom: effectiveFrom ?? now,
            createdAt: now
        )
    }

    // MARK: 1. Persistence round-trip + reload-after-relaunch

    func testPersistenceRoundTripSurvivesRelaunch() throws {
        let url = temporaryURL()
        defer { removeStore(at: url) }
        let store = try FinanceBudgetStore(url: url)
        let original = budget(category: .dining, limitCents: 15_000)
        try store.setBudget(original)

        let relaunched = try FinanceBudgetStore(url: url)
        let loaded = try relaunched.load()
        XCTAssertEqual(loaded.count, 1)
        XCTAssertEqual(loaded.first?.id, original.id)
        XCTAssertEqual(loaded.first?.category, .dining)
        XCTAssertEqual(loaded.first?.monthlyLimitCents, 15_000)
    }

    // MARK: 2. currentBudgets-by-date resolution (latest effective, per category)

    func testCurrentBudgetsResolvesLatestEffectiveOnOrBeforeDatePerCategory() throws {
        let url = temporaryURL()
        defer { removeStore(at: url) }
        let store = try FinanceBudgetStore(url: url)

        let earlier = budget(category: .groceries, limitCents: 20_000, effectiveFrom: now.addingTimeInterval(-86_400 * 10))
        let later = budget(category: .groceries, limitCents: 25_000, effectiveFrom: now.addingTimeInterval(-86_400 * 2))
        let future = budget(category: .groceries, limitCents: 40_000, effectiveFrom: now.addingTimeInterval(86_400 * 30))
        let otherCategory = budget(category: .dining, limitCents: 10_000, effectiveFrom: now.addingTimeInterval(-86_400 * 5))
        try store.setBudget(earlier)
        try store.setBudget(later)
        try store.setBudget(future)
        try store.setBudget(otherCategory)

        let current = try store.currentBudgets(on: now, calendar: utcCalendar)
        XCTAssertEqual(current[.groceries]?.id, later.id)
        XCTAssertEqual(current[.groceries]?.monthlyLimitCents, 25_000)
        XCTAssertEqual(current[.dining]?.id, otherCategory.id)
        XCTAssertEqual(current.count, 2)

        // The future-dated budget is not yet in effect.
        XCTAssertNotEqual(current[.groceries]?.id, future.id)
    }

    func testCurrentBudgetsResolvesExactDayBoundary() throws {
        let url = temporaryURL()
        defer { removeStore(at: url) }
        let store = try FinanceBudgetStore(url: url)
        let today = budget(category: .shopping, limitCents: 12_000, effectiveFrom: now)
        try store.setBudget(today)

        let current = try store.currentBudgets(on: now, calendar: utcCalendar)
        XCTAssertEqual(current[.shopping]?.id, today.id)
    }

    // MARK: 3. Honest-empty when absent

    func testMissingFileDecodesToHonestEmptyState() throws {
        let url = temporaryURL()
        defer { removeStore(at: url) }
        let store = try FinanceBudgetStore(url: url)
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
        let loaded = try store.load()
        XCTAssertTrue(loaded.isEmpty)
    }

    func testCurrentBudgetsIsEmptyWhenNoBudgetEverSet() throws {
        let url = temporaryURL()
        defer { removeStore(at: url) }
        let store = try FinanceBudgetStore(url: url)
        let current = try store.currentBudgets(on: now, calendar: utcCalendar)
        XCTAssertTrue(current.isEmpty)
    }

    func testCurrentBudgetsOmitsCategoryWhenAllEntriesAreInTheFuture() throws {
        let url = temporaryURL()
        defer { removeStore(at: url) }
        let store = try FinanceBudgetStore(url: url)
        try store.setBudget(budget(category: .bills, effectiveFrom: now.addingTimeInterval(86_400 * 5)))

        let current = try store.currentBudgets(on: now, calendar: utcCalendar)
        XCTAssertNil(current[.bills])
        XCTAssertTrue(current.isEmpty)
    }

    // MARK: 4. Integer cents preserved

    func testIntegerCentsPreservedAfterRoundTrip() throws {
        let url = temporaryURL()
        defer { removeStore(at: url) }
        let store = try FinanceBudgetStore(url: url)
        try store.setBudget(budget(category: .transport, limitCents: 12_345))

        let loaded = try store.load()
        XCTAssertEqual(loaded.first?.monthlyLimitCents, 12_345)
    }

    // MARK: 5. Income is not budgetable

    func testSetBudgetThrowsForIncomeCategory() throws {
        let url = temporaryURL()
        defer { removeStore(at: url) }
        let store = try FinanceBudgetStore(url: url)
        XCTAssertThrowsError(try store.setBudget(budget(category: .income))) { error in
            XCTAssertEqual(error as? FinanceBudgetStoreError, .notBudgetable)
        }
        XCTAssertTrue(try store.load().isEmpty)
    }

    func testBudgetableCategoriesExcludesIncome() {
        XCTAssertFalse(FinanceTransactionCategory.budgetableCategories.contains(.income))
        XCTAssertFalse(FinanceTransactionCategory.income.isBudgetable)
        XCTAssertTrue(FinanceTransactionCategory.groceries.isBudgetable)
    }

    // MARK: 6. Remove

    func testRemoveClearsCategoryHistoryLeavingHonestEmpty() throws {
        let url = temporaryURL()
        defer { removeStore(at: url) }
        let store = try FinanceBudgetStore(url: url)
        try store.setBudget(budget(category: .groceries, limitCents: 20_000, effectiveFrom: now.addingTimeInterval(-86_400 * 10)))
        try store.setBudget(budget(category: .groceries, limitCents: 25_000, effectiveFrom: now))
        try store.setBudget(budget(category: .dining, limitCents: 10_000))

        try store.remove(category: .groceries)

        let loaded = try store.load()
        XCTAssertFalse(loaded.contains { $0.category == .groceries })
        XCTAssertTrue(loaded.contains { $0.category == .dining })

        let current = try store.currentBudgets(on: now, calendar: utcCalendar)
        XCTAssertNil(current[.groceries])
    }

    // MARK: 7. History ordering

    func testHistoryIsSortedByEffectiveFromAscending() throws {
        let url = temporaryURL()
        defer { removeStore(at: url) }
        let store = try FinanceBudgetStore(url: url)
        let third = budget(category: .groceries, limitCents: 30_000, effectiveFrom: now.addingTimeInterval(86_400 * 2))
        let first = budget(category: .groceries, limitCents: 20_000, effectiveFrom: now.addingTimeInterval(-86_400 * 2))
        let second = budget(category: .groceries, limitCents: 25_000, effectiveFrom: now)
        try store.setBudget(third)
        try store.setBudget(first)
        try store.setBudget(second)

        let history = try store.history()
        XCTAssertEqual(history.map(\.monthlyLimitCents), [20_000, 25_000, 30_000])
    }

    // MARK: 8. Backward-compatible decode of a minimal envelope

    func testMinimalEnvelopeJSONDecodesWithoutThrowing() throws {
        let url = temporaryURL()
        defer { removeStore(at: url) }
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let json = #"{"schemaVersion":1,"budgets":[]}"#
        try json.data(using: .utf8)!.write(to: url)

        let store = try FinanceBudgetStore(url: url)
        let loaded = try store.load()
        XCTAssertTrue(loaded.isEmpty)
    }

    func testEnvelopeMissingBudgetsFieldDecodesToEmptyList() throws {
        let url = temporaryURL()
        defer { removeStore(at: url) }
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let json = #"{"schemaVersion":1}"#
        try json.data(using: .utf8)!.write(to: url)

        let store = try FinanceBudgetStore(url: url)
        let loaded = try store.load()
        XCTAssertTrue(loaded.isEmpty)
    }

    // MARK: 9. Budget-vs-actual math (spent from categorizer summary vs limit)

    private func transaction(category rawCategory: FinanceTransactionCategory, cents: Int, daysAgo: Int = 0) -> FinanceImportedTransaction {
        // Descriptions chosen to match FinanceCategorizer's keyword rules so
        // `FinanceCategorizer.summary` buckets them into `rawCategory`.
        let description: String
        switch rawCategory {
        case .groceries: description = "REWE Markt"
        case .dining: description = "Lieferando"
        case .transport: description = "Deutsche Bahn"
        case .shopping: description = "Amazon.de"
        case .bills: description = "Miete"
        case .subscriptions: description = "Netflix"
        case .income: description = "Gehalt"
        case .cash: description = "Geldautomat"
        case .uncategorized: description = "Unknown Merchant XYZ"
        }
        return FinanceImportedTransaction(
            bookedAt: now.addingTimeInterval(-86_400 * Double(daysAgo)),
            amountCents: cents,
            description: description,
            source: .genericCSV,
            importedAt: now
        )
    }

    func testSpentUnderLimitLeavesPositiveRemaining() throws {
        let transactions = [
            transaction(category: .groceries, cents: -12_000),
            transaction(category: .groceries, cents: -5_000)
        ]
        let summary = FinanceCategorizer.summary(for: transactions)
        let groceriesSpend = summary.first { $0.category == .groceries }
        XCTAssertEqual(groceriesSpend?.outflowCents, 17_000)

        let limitCents = 30_000
        let remaining = limitCents - (groceriesSpend?.outflowCents ?? 0)
        XCTAssertEqual(remaining, 13_000)
        XCTAssertTrue(remaining >= 0)
    }

    func testSpentOverLimitProducesOverByAmount() throws {
        let transactions = [
            transaction(category: .dining, cents: -20_000),
            transaction(category: .dining, cents: -15_000)
        ]
        let summary = FinanceCategorizer.summary(for: transactions)
        let diningSpend = summary.first { $0.category == .dining }
        XCTAssertEqual(diningSpend?.outflowCents, 35_000)

        let limitCents = 25_000
        let overByCents = (diningSpend?.outflowCents ?? 0) - limitCents
        XCTAssertEqual(overByCents, 10_000)
        XCTAssertTrue(overByCents > 0)
    }

    func testCategoryWithNoTransactionsHasZeroSpendAgainstBudget() throws {
        let transactions = [transaction(category: .groceries, cents: -5_000)]
        let summary = FinanceCategorizer.summary(for: transactions)
        let billsSpend = summary.first { $0.category == .bills }
        XCTAssertNil(billsSpend)

        // No matching FinanceCategorySpend row means zero spend for a
        // budgeted category with no transactions this month — an honest
        // "on track, nothing spent yet," not a missing/broken row.
        let spentCents = billsSpend?.outflowCents ?? 0
        XCTAssertEqual(spentCents, 0)
    }

    // MARK: - Helpers

    private var utcCalendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return calendar
    }
}
