import Foundation
import XCTest
@testable import LifeOS

final class FinanceCategorizerTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_786_449_600)

    private func transaction(
        description: String,
        amountCents: Int,
        bookedAt: Date? = nil
    ) -> FinanceImportedTransaction {
        FinanceImportedTransaction(
            bookedAt: bookedAt ?? now,
            amountCents: amountCents,
            description: description,
            source: .genericCSV,
            importedAt: now
        )
    }

    // MARK: 1. German merchant keyword matching

    func testGermanGroceryKeywordsMatchGroceries() {
        XCTAssertEqual(FinanceCategorizer.category(for: "REWE Markt 4521", amountCents: -3450), .groceries)
        XCTAssertEqual(FinanceCategorizer.category(for: "ALDI SUED", amountCents: -1899), .groceries)
        XCTAssertEqual(FinanceCategorizer.category(for: "Lidl Vertrieb", amountCents: -2210), .groceries)
    }

    func testGermanTransportKeywordsMatchTransport() {
        XCTAssertEqual(FinanceCategorizer.category(for: "DB Vertrieb GmbH", amountCents: -4900), .transport)
        XCTAssertEqual(FinanceCategorizer.category(for: "BVG Fahrschein", amountCents: -290), .transport)
    }

    func testGermanBillsKeywordsMatchBills() {
        XCTAssertEqual(FinanceCategorizer.category(for: "Miete August", amountCents: -85000), .bills)
        XCTAssertEqual(FinanceCategorizer.category(for: "Vodafone GmbH", amountCents: -3999), .bills)
    }

    func testGermanDiacriticsMatchFeesAndTransfersWithoutUberCollision() {
        XCTAssertEqual(FinanceCategorizer.category(for: "Bankgebühr Kontoführung", amountCents: -399), .fees)
        XCTAssertEqual(FinanceCategorizer.category(for: "Überweisung an Vermieter", amountCents: -85000), .transfers)
    }

    // MARK: 2. English / international merchant keyword matching

    func testEnglishSubscriptionKeywordsMatchSubscriptions() {
        XCTAssertEqual(FinanceCategorizer.category(for: "NETFLIX.COM", amountCents: -1299), .subscriptions)
        XCTAssertEqual(FinanceCategorizer.category(for: "Spotify AB", amountCents: -999), .subscriptions)
    }

    func testEnglishShoppingKeywordsMatchShopping() {
        XCTAssertEqual(FinanceCategorizer.category(for: "AMAZON.DE MARKETPLACE", amountCents: -5499), .shopping)
        XCTAssertEqual(FinanceCategorizer.category(for: "Zalando SE", amountCents: -7999), .shopping)
    }

    func testSpecificSubscriptionWinsOverBroadAmazonShoppingRule() {
        XCTAssertEqual(FinanceCategorizer.category(for: "Amazon Prime", amountCents: -899), .subscriptions)
    }

    func testEnglishTransportKeywordsMatchTransport() {
        XCTAssertEqual(FinanceCategorizer.category(for: "UBER *TRIP", amountCents: -1450), .transport)
    }

    func testKeywordMatchingIsCaseInsensitive() {
        XCTAssertEqual(FinanceCategorizer.category(for: "rewe markt", amountCents: -1000), .groceries)
        XCTAssertEqual(FinanceCategorizer.category(for: "REWE MARKT", amountCents: -1000), .groceries)
        XCTAssertEqual(FinanceCategorizer.category(for: "ReWe Markt", amountCents: -1000), .groceries)
    }

    // MARK: 3. Income detection (direction-aware)

    func testGehaltInflowIsIncome() {
        XCTAssertEqual(FinanceCategorizer.category(for: "Gehalt August 2026", amountCents: 320000), .income)
    }

    func testSalaryInflowIsIncome() {
        XCTAssertEqual(FinanceCategorizer.category(for: "Acme Corp Salary", amountCents: 280000), .income)
    }

    func testIncomeKeywordOnOutflowIsNotForcedToIncome() {
        // Direction disagrees with the income rule (a negative amount can't
        // be a salary deposit) — must not be force-guessed as income.
        XCTAssertNotEqual(FinanceCategorizer.category(for: "Gehalt Correction", amountCents: -500), .income)
    }

    // MARK: 4. Unmatched stays uncategorized (never fabricated)

    func testUnknownMerchantIsUncategorized() {
        XCTAssertEqual(FinanceCategorizer.category(for: "XYZ Completely Unknown Merchant 9284", amountCents: -1234), .uncategorized)
    }

    func testEmptyDescriptionIsUncategorized() {
        XCTAssertEqual(FinanceCategorizer.category(for: "", amountCents: -500), .uncategorized)
    }

    func testGenericPositiveAmountWithoutIncomeKeywordIsNotForcedToIncome() {
        // A plain inflow with no recognizable keyword must stay honest, not
        // be guessed as income just because the sign is positive.
        XCTAssertEqual(FinanceCategorizer.category(for: "Transfer from J. Schmidt", amountCents: 15000), .uncategorized)
    }

    func testRecognizedStatementCategoryWinsOverMerchantHeuristic() {
        XCTAssertEqual(
            FinanceCategorizer.category(for: "Unknown merchant", amountCents: -1200, sourceCategory: "Food"),
            .groceries
        )
        XCTAssertEqual(
            FinanceCategorizer.category(for: "Amazon Marketplace", amountCents: -1200, sourceCategory: "Health"),
            .health
        )
    }

    func testIncomeSourceCategoryDoesNotOverrideOutflowDirection() {
        XCTAssertNotEqual(
            FinanceCategorizer.category(for: "Unknown", amountCents: -1200, sourceCategory: "Income"),
            .income
        )
    }

    func testCommonGermanAndProviderCategoryLabelsNormalizeToCanonicalValues() {
        XCTAssertEqual(
            FinanceCategorizer.category(for: "Unknown merchant", amountCents: -1200, sourceCategory: "Food & Dining"),
            .dining
        )
        XCTAssertEqual(
            FinanceCategorizer.category(for: "Unknown merchant", amountCents: -1200, sourceCategory: "Gebühren"),
            .fees
        )
        XCTAssertEqual(
            FinanceCategorizer.category(for: "Unknown merchant", amountCents: -1200, sourceCategory: "Überweisung"),
            .transfers
        )
    }

    // MARK: 5. Summary totals — integer cents, in/out/net

    func testSummaryAggregatesOutflowInflowAndCountPerCategory() {
        let transactions = [
            transaction(description: "Rewe Markt", amountCents: -4000),
            transaction(description: "Aldi Sued", amountCents: -2000),
            transaction(description: "Gehalt", amountCents: 300000)
        ]
        let summary = FinanceCategorizer.summary(for: transactions)

        let groceries = try! XCTUnwrap(summary.first { $0.category == .groceries })
        XCTAssertEqual(groceries.outflowCents, 6000)
        XCTAssertEqual(groceries.inflowCents, 0)
        XCTAssertEqual(groceries.count, 2)
        XCTAssertEqual(groceries.netCents, -6000)

        let income = try! XCTUnwrap(summary.first { $0.category == .income })
        XCTAssertEqual(income.inflowCents, 300000)
        XCTAssertEqual(income.outflowCents, 0)
        XCTAssertEqual(income.count, 1)
    }

    func testSummaryUsesImportedSourceCategory() {
        let imported = FinanceImportedTransaction(
            bookedAt: now,
            amountCents: -2_000,
            description: "Unknown merchant",
            source: .genericCSV,
            importedAt: now,
            sourceCategory: "Health"
        )
        XCTAssertEqual(FinanceCategorizer.summary(for: [imported]).first?.category, .health)
    }

    func testCategoryPrecedenceIsOverrideThenProviderThenHeuristic() {
        let imported = FinanceImportedTransaction(
            bookedAt: now,
            amountCents: -2_000,
            description: "Amazon Marketplace",
            category: FinanceTransactionCategory.dining.rawValue,
            source: .genericCSV,
            importedAt: now,
            sourceCategory: "Health"
        )
        let resolution = FinanceCategorizer.resolve(transaction: imported)
        XCTAssertEqual(resolution.category, .dining)
        XCTAssertEqual(resolution.source, .userOverride)

        let providerOnly = FinanceImportedTransaction(
            bookedAt: now,
            amountCents: -2_000,
            description: "Amazon Marketplace",
            source: .genericCSV,
            importedAt: now,
            sourceCategory: "Health"
        )
        let providerResolution = FinanceCategorizer.resolve(transaction: providerOnly)
        XCTAssertEqual(providerResolution.category, .health)
        XCTAssertEqual(providerResolution.source, .provider)

        let heuristicOnly = transaction(description: "Amazon Marketplace", amountCents: -2_000)
        let heuristicResolution = FinanceCategorizer.resolve(transaction: heuristicOnly)
        XCTAssertEqual(heuristicResolution.category, .shopping)
        XCTAssertEqual(heuristicResolution.source, .heuristic)
    }

    func testProviderMCCWinsOverMerchantHeuristicAfterSourceCategory() {
        let coded = FinanceImportedTransaction(
            bookedAt: now,
            amountCents: -2_000,
            description: "Amazon Marketplace",
            source: .genericCSV,
            importedAt: now,
            providerCode: "5411"
        )
        let resolution = FinanceCategorizer.resolve(transaction: coded)
        XCTAssertEqual(resolution.category, .groceries)
        XCTAssertEqual(resolution.source, .providerCode)

        let sourceWins = FinanceImportedTransaction(
            bookedAt: now,
            amountCents: -2_000,
            description: "Amazon Marketplace",
            source: .genericCSV,
            importedAt: now,
            sourceCategory: "Health",
            providerCode: "5411"
        )
        XCTAssertEqual(FinanceCategorizer.resolve(transaction: sourceWins).category, .health)
    }

    func testInvestmentOrderAlwaysStaysOutsideOrdinaryBudgetCategories() {
        let order = FinanceImportedTransaction(
            bookedAt: now,
            amountCents: -10_000,
            description: "Amazon Marketplace",
            source: .tradeRepublicCSV,
            importedAt: now,
            kind: .investmentOrder,
            investment: FinanceImportedInvestmentDetails(symbol: "VWCE", assetClass: "ETF", quantity: "1")
        )
        let transfer = FinanceImportedTransaction(
            bookedAt: now,
            amountCents: -5_000,
            description: "Bank transfer",
            source: .genericCSV,
            importedAt: now,
            sourceCategory: "Transfer"
        )

        XCTAssertEqual(FinanceCategorizer.category(for: order), .investments)
        XCTAssertFalse(FinanceCategorizer.isBudgetEligible(order))
        XCTAssertFalse(FinanceCategorizer.isBudgetEligible(transfer))
        XCTAssertTrue(FinanceCategorizer.budgetSummary(for: [order, transfer]).isEmpty)
    }

    func testUserOverrideWinsForInvestmentDisplayButOrderRemainsExcludedFromBudgets() {
        let order = FinanceImportedTransaction(
            bookedAt: now,
            amountCents: -10_000,
            description: "Vanguard order",
            category: FinanceTransactionCategory.shopping.rawValue,
            source: .tradeRepublicCSV,
            importedAt: now,
            kind: .investmentOrder,
            investment: FinanceImportedInvestmentDetails(symbol: "VWCE", assetClass: "ETF", quantity: "1")
        )

        let resolution = FinanceCategorizer.resolve(transaction: order)
        XCTAssertEqual(resolution.category, .shopping)
        XCTAssertEqual(resolution.source, .userOverride)
        XCTAssertFalse(FinanceCategorizer.isBudgetEligible(order))
    }

    func testSummarySortedByAbsoluteSpendDescending() {
        let transactions = [
            transaction(description: "Netflix", amountCents: -1000),
            transaction(description: "Rewe Markt", amountCents: -9000),
            transaction(description: "Aldi", amountCents: -3000)
        ]
        let summary = FinanceCategorizer.summary(for: transactions)
        let magnitudes = summary.map { $0.outflowCents + $0.inflowCents }
        XCTAssertEqual(magnitudes, magnitudes.sorted(by: >))
        XCTAssertEqual(summary.first?.category, .groceries)
    }

    func testTotalsComputeOverallInOutNet() {
        let transactions = [
            transaction(description: "Rewe Markt", amountCents: -4000),
            transaction(description: "Gehalt", amountCents: 300000),
            transaction(description: "Netflix", amountCents: -1200)
        ]
        let totals = FinanceCategorizer.totals(for: transactions)
        XCTAssertEqual(totals.outflowCents, 5200)
        XCTAssertEqual(totals.inflowCents, 300000)
        XCTAssertEqual(totals.netCents, 294800)
        XCTAssertEqual(totals.transactionCount, 3)
    }

    // MARK: 6. Empty input -> empty summary (honest, not fabricated)

    func testEmptyTransactionsProduceEmptySummary() {
        XCTAssertTrue(FinanceCategorizer.summary(for: []).isEmpty)
    }

    func testEmptyTransactionsProduceZeroedTotals() {
        let totals = FinanceCategorizer.totals(for: [])
        XCTAssertEqual(totals.outflowCents, 0)
        XCTAssertEqual(totals.inflowCents, 0)
        XCTAssertEqual(totals.netCents, 0)
        XCTAssertEqual(totals.transactionCount, 0)
    }
}
