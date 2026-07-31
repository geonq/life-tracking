import XCTest
@testable import LifeOS

final class FinanceDomainTests: XCTestCase {
    func testSpendableBudgetUsesIncomeFixedCostsAndConfiguredBuffer() {
        let summary = FinanceSummary(
            monthlyIncomeCents: 300_000,
            fixedCostsCents: 170_000,
            discretionaryBufferCents: 30_000,
            spentCents: 45_000,
            savingsGoalCents: 1_000_000,
            savedCents: 250_000,
            provenance: DemoDataProvider.provenance
        )

        XCTAssertEqual(summary.spendableBudgetCents, 100_000)
        XCTAssertEqual(summary.budgetUsedFraction ?? -1, 0.45, accuracy: 0.0001)
        XCTAssertEqual(summary.savingsProgressFraction ?? -1, 0.25, accuracy: 0.0001)
    }

    func testFinanceConnectorCatalogFailsClosedUntilExplicitlyConfigured() {
        XCTAssertEqual(FinanceConnectorCatalog.defaults.map(\.kind), [.sparkasse, .paypal, .tradeRepublic])
        XCTAssertTrue(FinanceConnectorCatalog.defaults.allSatisfy { !$0.isEnabled })
        XCTAssertTrue(FinanceConnectorCatalog.defaults.allSatisfy(\.requiresExplicitOptIn))
        XCTAssertEqual(FinanceConnectorCatalog.defaults.first { $0.kind == .tradeRepublic }?.accessMethod, .regulatedProviderPending)
        XCTAssertEqual(FinanceConnectorCatalog.defaults.first { $0.kind == .tradeRepublic }?.risk, .experimentalOnly)
    }

    func testBudgetFractionsAreClampedAndAvoidDivisionByZero() {
        let summary = FinanceSummary(
            monthlyIncomeCents: 100,
            fixedCostsCents: 100,
            discretionaryBufferCents: 0,
            spentCents: 500,
            savingsGoalCents: 0,
            savedCents: 500,
            provenance: DemoDataProvider.provenance
        )

        XCTAssertEqual(summary.spendableBudgetCents, 0)
        XCTAssertNil(summary.budgetUsedFraction)
        XCTAssertNil(summary.savingsProgressFraction)
    }
}
