import XCTest
@testable import LifeOS

/// Closes the reachable `unit + integration` halves of five P0 Finance
/// category-aggregation truth rows. `ui-runtime`/`visual` stays gated
/// separately -- nothing here exercises rendering, only the real
/// `FinanceDisplaySnapshot` / `FinanceTransactionTotals` / `FinanceCategory`
/// / `FinanceTransactionFilter` pipeline the view reads from.
///
/// - RF-09: Income category totals/count/percent/transaction drilldown.
/// - RF-10: Net cash flow income/spend series, signed categories and periods.
/// - RF-11: Spending modes/categories/percent/count/transactions.
/// - RF-15: Income category ring and timestamped merchant/source transactions.
/// - RF-18: Spending merchant/date/amount/source drilldown and reconciliation.
///
/// A real defect was found and fixed here (see
/// `testSpentDetailCountsOnlySpendingTransactionsNotAllTransactions`):
/// `FinanceDisplaySnapshot.spent.detail` labelled its transaction count with
/// `FinanceTransactionTotals.transactionCount`, which counts EVERY
/// transaction (income, spend, and any zero-amount row) rather than only the
/// spending rows the "Spent" card is describing. A wallet with 5 deposits and
/// 8 purchases showed "Spent: EUR X . 13 transactions" instead of "8
/// transactions". Fixed in `FinanceView.swift` to mirror how `income.detail`
/// already computes its own count via an explicit `isIncome`/`isSpending`
/// filter instead of reusing the all-transactions aggregate.
@available(iOS 17.0, macOS 14.0, *)
final class FinanceCategoryAggregationTests: XCTestCase {

    // MARK: - Fixtures

    private func provenance(source: String = "revolut_personal", observedAt: Date) -> FinancePayloadProvenance {
        FinancePayloadProvenance(
            source: source,
            observedAt: observedAt,
            freshness: .fresh,
            quality: .observed,
            connectorState: .healthy
        )
    }

    private func row(
        _ id: String,
        _ merchant: String,
        _ category: String,
        _ cents: Int,
        date: Date,
        source: String = "revolut_personal"
    ) -> FinanceTransactionObservation {
        FinanceTransactionObservation(
            id: id,
            merchant: merchant,
            title: "\(merchant) transaction",
            signedAmountCents: cents,
            timestamp: date,
            account: "Revolut Personal",
            source: source,
            category: category,
            provenance: provenance(source: source, observedAt: date)
        )
    }

    /// A realistic mixed ledger: 5 income rows across 4 categories (one of
    /// them, "Shopping", is a positive refund under a spend-shaped category
    /// name -- this proves grouping follows the transaction's SIGN, not its
    /// category label) and 8 spend rows across 4 categories, all at the same
    /// timestamp so range filtering is not a factor for the sum/count/percent
    /// properties.
    private func mixedLedger(now: Date) -> [FinanceTransactionObservation] {
        [
            row("salary-1", "Employer", "Salary", 285_073, date: now),
            row("freelance-1", "Client", "Freelance", 154_231, date: now),
            row("refund-1", "REWE", "Shopping", 4_999, date: now),
            row("interest-1", "Bank", "Interest", 733, date: now),
            row("food-1", "REWE", "Food", -12_345, date: now),
            row("food-2", "EDEKA", "Food", -6_789, date: now),
            row("food-3", "Aldi", "Food", -1_111, date: now),
            row("transport-1", "BVG", "Transport", -8_500, date: now),
            row("transport-2", "DB", "Transport", -2_250, date: now),
            row("home-1", "IKEA", "Home", -95_000, date: now),
            row("lifestyle-1", "Gym", "Lifestyle", -7_777, date: now),
            row("lifestyle-2", "Restaurant", "Lifestyle", -3_333, date: now)
        ]
    }

    private func snapshot(_ transactions: [FinanceTransactionObservation]?) -> FinanceDisplaySnapshot {
        FinanceDisplaySnapshot(summary: nil, transactions: transactions, usesVisualFixtures: false)
    }

    // MARK: - Property 1: category totals sum exactly to the aggregate, no drift, no double count

    func testCategoryTotalsSumExactlyToAggregateWithNoDriftOrDoubleCounting() throws {
        let now = Date(timeIntervalSince1970: 1_754_659_800)
        let transactions = mixedLedger(now: now)
        let snap = snapshot(transactions)

        // 12 rows: 4 income + 8 spend (refund-1 is positive -> income side).
        XCTAssertEqual(transactions.count, 12)
        XCTAssertEqual(snap.income.cents, 285_073 + 154_231 + 4_999 + 733)
        XCTAssertEqual(snap.spent.cents, 12_345 + 6_789 + 1_111 + 8_500 + 2_250 + 95_000 + 7_777 + 3_333)

        let spendSum = snap.categories.reduce(0) { $0 + $1.amountCents }
        XCTAssertEqual(spendSum, snap.spent.cents, "Sum of category totals must equal the spend aggregate exactly, in integer cents.")

        let incomeSum = snap.incomeCategories.reduce(0) { $0 + $1.amountCents }
        XCTAssertEqual(incomeSum, snap.income.cents, "Sum of income category totals must equal the income aggregate exactly, in integer cents.")

        // No double-counting: category transaction counts partition the
        // ledger exactly -- their sum equals the number of spend/income rows,
        // and no row is counted in more than one category.
        let spendRowCount = transactions.filter(\.isSpending).count
        let incomeRowCount = transactions.filter(\.isIncome).count
        XCTAssertEqual(snap.categories.reduce(0) { $0 + $1.transactionCount }, spendRowCount)
        XCTAssertEqual(snap.incomeCategories.reduce(0) { $0 + $1.transactionCount }, incomeRowCount)
        XCTAssertEqual(Set(snap.categories.map(\.name)).count, snap.categories.count, "No category name must appear twice as a separate rollup.")
        XCTAssertEqual(Set(snap.incomeCategories.map(\.name)).count, snap.incomeCategories.count)

        // The refund landed on the income side despite its "Shopping" label.
        XCTAssertTrue(snap.incomeCategories.contains { $0.name == "Shopping" && $0.amountCents == 4_999 })
        XCTAssertFalse(snap.categories.contains { $0.name == "Shopping" }, "A positive-amount row must never be folded into spend categories merely because of its label.")
    }

    // MARK: - Property 2: percentages are honest

    func testCategoryPercentagesUseHonestTruncationAndFractionsStayWithinBounds() throws {
        let now = Date(timeIntervalSince1970: 1_754_659_800)
        let snap = snapshot(mixedLedger(now: now))

        // Rounding rule found in FinanceView.swift's category legend: the
        // displayed percentage is `Int(category.fraction * 100)`, i.e. a
        // truncation toward zero (floor for non-negative fractions), not
        // round-half-up. That means the displayed percentages do not
        // necessarily sum to 100 -- verified below rather than assumed.
        func displayedPercent(_ category: FinanceCategory) -> Int { Int(category.fraction * 100) }

        let spendByName = Dictionary(uniqueKeysWithValues: snap.categories.map { ($0.name, $0) })
        XCTAssertEqual(displayedPercent(try XCTUnwrap(spendByName["Food"])), 14)
        XCTAssertEqual(displayedPercent(try XCTUnwrap(spendByName["Transport"])), 7)
        XCTAssertEqual(displayedPercent(try XCTUnwrap(spendByName["Home"])), 69)
        XCTAssertEqual(displayedPercent(try XCTUnwrap(spendByName["Lifestyle"])), 8)
        // Truncation loses fractional remainder: 14+7+69+8 = 98, not 100.
        XCTAssertEqual(spendByName.values.reduce(0) { $0 + displayedPercent($1) }, 98)

        let incomeByName = Dictionary(uniqueKeysWithValues: snap.incomeCategories.map { ($0.name, $0) })
        XCTAssertEqual(displayedPercent(try XCTUnwrap(incomeByName["Salary"])), 64)
        XCTAssertEqual(displayedPercent(try XCTUnwrap(incomeByName["Freelance"])), 34)
        XCTAssertEqual(displayedPercent(try XCTUnwrap(incomeByName["Shopping"])), 1)
        XCTAssertEqual(displayedPercent(try XCTUnwrap(incomeByName["Interest"])), 0)

        // Every fraction is a real share of the whole: finite, within [0, 1],
        // and the exact fractions (not the truncated display) sum to 1.0.
        for category in snap.categories + snap.incomeCategories {
            XCTAssertTrue(category.fraction.isFinite)
            XCTAssertGreaterThanOrEqual(category.fraction, 0)
            XCTAssertLessThanOrEqual(category.fraction, 1)
        }
        XCTAssertEqual(snap.categories.reduce(0.0) { $0 + $1.fraction }, 1.0, accuracy: 0.0001)
        XCTAssertEqual(snap.incomeCategories.reduce(0.0) { $0 + $1.fraction }, 1.0, accuracy: 0.0001)
    }

    /// A category's percentage must never be derived from a denominator that
    /// includes unavailable data -- when there is no spending at all, the
    /// spend-category list is empty (no fabricated 0%-of-nothing rows), and
    /// income categories are entirely unaffected.
    func testPercentageDenominatorNeverIncludesUnavailableSpendWhenThereIsNoSpending() throws {
        let now = Date(timeIntervalSince1970: 1_754_659_800)
        let incomeOnly = [row("salary-1", "Employer", "Salary", 100_000, date: now)]
        let snap = snapshot(incomeOnly)

        XCTAssertTrue(snap.categories.isEmpty, "No spending rows exist; spend categories must be empty, not a fabricated zero-amount entry.")
        XCTAssertEqual(snap.incomeCategories.count, 1)
        XCTAssertEqual(snap.incomeCategories[0].fraction, 1.0, accuracy: 0.0001)
        XCTAssertEqual(snap.spent.cents, 0, "Genuine zero spend (observed, not missing) is a real zero, distinct from `isUnavailable`.")
        XCTAssertFalse(snap.spent.isUnavailable)
    }

    // MARK: - Property 3: counts match contents

    func testCategoryTransactionCountEqualsActualDrilldownRowCountForSpendAndIncome() {
        let now = Date(timeIntervalSince1970: 1_754_659_800)
        let transactions = mixedLedger(now: now)
        let snap = snapshot(transactions)

        for category in snap.categories {
            let drilldown = snap.filteredTransactions(category: category.name, source: nil, range: .max)
            XCTAssertEqual(drilldown.count, category.transactionCount, "\(category.name): displayed count must equal the actual drilldown row count, no off-by-one.")
            XCTAssertTrue(drilldown.allSatisfy { $0.category == category.name && $0.isSpending })
        }
        for category in snap.incomeCategories {
            let drilldown = snap.filteredTransactions(category: category.name, source: nil, range: .max, incomeOnly: true)
            XCTAssertEqual(drilldown.count, category.transactionCount)
            XCTAssertTrue(drilldown.allSatisfy { $0.category == category.name && $0.isIncome })
        }
    }

    // MARK: - Property 4 (RF-10): signs are correct

    func testNetCashFlowSignsAreCorrectAndEqualsIncomeMinusSpendExactly() {
        let now = Date(timeIntervalSince1970: 1_754_659_800)
        let transactions = mixedLedger(now: now)
        let snap = snapshot(transactions)

        XCTAssertTrue(transactions.filter(\.isIncome).allSatisfy { $0.signedAmountCents > 0 })
        XCTAssertTrue(transactions.filter(\.isSpending).allSatisfy { $0.signedAmountCents < 0 })

        let income = try! XCTUnwrap(snap.income.cents)
        let spend = try! XCTUnwrap(snap.spent.cents)
        let cashFlow = try! XCTUnwrap(snap.cashFlow.cents)
        XCTAssertEqual(cashFlow, income - spend, "Net cash flow must equal income minus spend exactly.")
        XCTAssertGreaterThan(income, spend)
        XCTAssertGreaterThan(cashFlow, 0, "Income (445,036) exceeds spend (137,105); the dominant single spend category (Home, 95,000) must not flip the overall sign.")

        // Flip the scenario: spend now exceeds income overall even though it
        // is spread across several small categories -- net must go negative,
        // proving no single category (nor its sign) can override the ledger total.
        let spendHeavy = [
            row("salary-1", "Employer", "Salary", 50_000, date: now),
            row("food-1", "REWE", "Food", -20_000, date: now),
            row("transport-1", "BVG", "Transport", -15_000, date: now),
            row("home-1", "IKEA", "Home", -25_000, date: now)
        ]
        let spendHeavySnap = snapshot(spendHeavy)
        let heavyIncome = try! XCTUnwrap(spendHeavySnap.income.cents)
        let heavySpend = try! XCTUnwrap(spendHeavySnap.spent.cents)
        let heavyCashFlow = try! XCTUnwrap(spendHeavySnap.cashFlow.cents)
        XCTAssertEqual(heavyCashFlow, heavyIncome - heavySpend)
        XCTAssertEqual(heavyCashFlow, -10_000)
        XCTAssertLessThan(heavyCashFlow, 0)
    }

    // MARK: - Property 7: unavailable never becomes zero (RF-10 cash flow specifically)

    func testUnavailableTransactionSourceLeavesCashFlowAndCategoriesUnavailableNotZero() {
        let snap = snapshot(nil)

        XCTAssertFalse(snap.hasTransactionSource)
        XCTAssertTrue(snap.cashFlow.isUnavailable)
        XCTAssertNil(snap.cashFlow.cents)
        XCTAssertTrue(snap.categories.isEmpty)
        XCTAssertTrue(snap.incomeCategories.isEmpty)
        XCTAssertTrue(snap.spent.isUnavailable)
        XCTAssertNil(snap.spent.cents)
    }

    // MARK: - Property 5 (RF-15/RF-18): drilldown reconciles exactly

    func testDrilldownRowsGenuinelyBelongToCategoryAndFieldsMatchTheUnderlyingRecordExactly() {
        let now = Date(timeIntervalSince1970: 1_754_659_800)
        let transactions = mixedLedger(now: now)
        let byID = Dictionary(uniqueKeysWithValues: transactions.map { ($0.id, $0) })
        let snap = snapshot(transactions)

        let foodDrilldown = snap.filteredTransactions(category: "Food", source: nil, range: .max)
        XCTAssertEqual(foodDrilldown.count, 3)
        for shown in foodDrilldown {
            let original = try! XCTUnwrap(byID[shown.id], "Drilldown must never invent a row absent from the underlying ledger.")
            XCTAssertEqual(shown.category, "Food")
            XCTAssertEqual(shown.merchant, original.merchant)
            XCTAssertEqual(shown.timestamp, original.timestamp)
            XCTAssertEqual(shown.signedAmountCents, original.signedAmountCents)
            XCTAssertEqual(shown.source, original.source)
        }

        let salaryDrilldown = snap.filteredTransactions(category: "Salary", source: nil, range: .max, incomeOnly: true)
        XCTAssertEqual(salaryDrilldown.map(\.id), ["salary-1"])
        XCTAssertEqual(salaryDrilldown[0].merchant, "Employer")
        XCTAssertEqual(salaryDrilldown[0].signedAmountCents, 285_073)
    }

    // MARK: - Property 5 cont. + 6 (RF-15/RF-18): range re-filters correctly at exact period boundaries

    func testChangingRangeRefiltersAtExactBoundariesWithoutLosingOrInventingRows() {
        let calendar = Calendar.current
        let latest = Date(timeIntervalSinceReferenceDate: 820_000_000)
        let dayStart = calendar.startOfDay(for: latest)

        func daysBefore(_ days: Int, offsetSeconds: TimeInterval = 0) -> Date {
            let day = calendar.date(byAdding: .day, value: -days, to: dayStart)!
            return day.addingTimeInterval(offsetSeconds)
        }

        // Week window (calendarDays: 7) starts at dayStart - 6 days.
        // Month window (calendarDays: 31) starts at dayStart - 30 days.
        let transactions = [
            row("latest", "REWE", "Food", -1_000, date: latest),
            row("week-in", "REWE", "Food", -500, date: daysBefore(6)),                      // exactly the week boundary -> IN week
            row("week-out", "REWE", "Food", -700, date: daysBefore(7, offsetSeconds: -1)),  // 1s before the week boundary -> OUT of week, IN month
            row("month-in", "REWE", "Food", -600, date: daysBefore(30)),                    // exactly the month boundary -> IN month, OUT of week
            row("month-out", "REWE", "Food", -300, date: daysBefore(31, offsetSeconds: -1)) // 1s before the month boundary -> OUT of month, IN max only
        ]
        let snap = snapshot(transactions)

        let week = Set(snap.filteredTransactions(category: "Food", source: nil, range: .week).map(\.id))
        let month = Set(snap.filteredTransactions(category: "Food", source: nil, range: .month).map(\.id))
        let max = Set(snap.filteredTransactions(category: "Food", source: nil, range: .max).map(\.id))

        XCTAssertEqual(week, ["latest", "week-in"])
        XCTAssertEqual(month, ["latest", "week-in", "week-out", "month-in"])
        XCTAssertEqual(max, Set(transactions.map(\.id)), "The .max range must include every real row, never inventing or dropping one.")

        // Every transaction on the week-start boundary is counted exactly
        // once for that range (present in week, and also in the wider
        // month/max windows that contain it) -- never duplicated, never
        // silently dropped from a window it belongs in.
        XCTAssertTrue(week.isSubset(of: month), "Every week row must also appear in the wider month window (nested, not duplicated elsewhere).")
        XCTAssertTrue(month.isSubset(of: max))
        XCTAssertFalse(month.contains("month-out"), "A row 1 second before the month boundary must be excluded, not counted.")
        XCTAssertFalse(week.contains("week-out"), "A row 1 second before the week boundary must be excluded, not counted.")
    }

    /// The daily chart buckets (`spendPoints`) must place a transaction into
    /// exactly one calendar day, even when two transactions straddle
    /// midnight by a single second.
    func testTransactionsStraddlingMidnightLandInExactlyOneDailyBucketEach() {
        let calendar = Calendar.current
        let dayStart = calendar.startOfDay(for: Date(timeIntervalSinceReferenceDate: 820_000_000))
        let justBeforeMidnight = dayStart.addingTimeInterval(-1)
        let exactlyMidnight = dayStart

        let transactions = [
            row("before", "REWE", "Food", -1_000, date: justBeforeMidnight),
            row("after", "REWE", "Food", -2_000, date: exactlyMidnight)
        ]
        let snap = snapshot(transactions)

        XCTAssertEqual(snap.spendPoints.count, 2, "Two transactions on opposite sides of a midnight boundary must produce two distinct daily points, never merged into one.")
        let sortedValues = snap.spendPoints.sorted { $0.date < $1.date }.map(\.value)
        XCTAssertEqual(sortedValues, [1_000, 2_000])
        XCTAssertEqual(snap.spendPoints.reduce(0) { $0 + $1.value }, 3_000, "Combined, the two buckets still equal the total spend -- no cent is lost or duplicated across the boundary.")
    }

    // MARK: - Defect found and fixed: spent.detail counted ALL transactions, not just spending ones

    /// `FinanceDisplaySnapshot.spent.detail` must report how many SPENDING
    /// transactions make up the "Spent" total, not the count of every
    /// transaction in the ledger (income included). Before the fix in
    /// `FinanceView.swift`, this used `FinanceTransactionTotals
    /// .transactionCount`, which is `transactions.count` -- every row,
    /// income and spend alike. With 4 income rows and 8 spend rows this
    /// showed "Spent: EUR 1,371.05 . 12 transactions" instead of the true
    /// "8 transactions" for that card's own total.
    func testSpentDetailCountsOnlySpendingTransactionsNotAllTransactions() {
        let now = Date(timeIntervalSince1970: 1_754_659_800)
        let transactions = mixedLedger(now: now)
        let snap = snapshot(transactions)

        let spendRowCount = transactions.filter(\.isSpending).count
        XCTAssertEqual(spendRowCount, 8)
        XCTAssertEqual(transactions.count, 12, "Sanity check: the ledger has more rows in total than are spending rows.")
        XCTAssertEqual(snap.spent.detail, "8 transactions", "The Spent card must count only its own (spending) rows, matching how the Income card already counts only deposits.")
    }
}
