import Foundation
import XCTest
@testable import LifeOS

final class FinanceWealthAllocationTests: XCTestCase {
    private let observedAt = Date(timeIntervalSince1970: 1_786_449_600)

    private func provenance(
        source: String = "trade_republic",
        quality: FinancePayloadQuality = .observed,
        freshness: FinancePayloadFreshness = .fresh,
        connectorState: ConnectorState = .healthy
    ) -> FinancePayloadProvenance {
        FinancePayloadProvenance(
            source: source,
            observedAt: observedAt,
            freshness: freshness,
            quality: quality,
            connectorState: connectorState
        )
    }

    private func observedHolding(
        id: String,
        name: String,
        assetClass: String?,
        valueCents: Int,
        currency: String = "EUR"
    ) -> FinanceHoldingObservation {
        FinanceHoldingObservation(
            id: id,
            name: name,
            assetClass: assetClass,
            valueCents: valueCents,
            currency: currency,
            source: "trade_republic",
            provenance: provenance()
        )
    }

    private func unavailableHolding(id: String, name: String, assetClass: String? = nil) -> FinanceHoldingObservation {
        FinanceHoldingObservation(
            id: id,
            name: name,
            assetClass: assetClass,
            currency: "EUR",
            source: "trade_republic",
            provenance: provenance(quality: .unavailable, freshness: .unknown, connectorState: .unavailable)
        )
    }

    private func snapshot(holdings: [FinanceHoldingObservation]?, availability: FinanceMetricAvailability = .observed) -> FinanceWealthSnapshot {
        FinanceWealthSnapshot(
            availability: availability,
            holdings: holdings,
            provenance: availability == .observed
                ? provenance()
                : provenance(source: "no-authorized-finance-source", quality: .unavailable, freshness: .unknown, connectorState: .unavailable)
        )
    }

    // MARK: 1. No snapshot / unavailable snapshot -> no ring

    func testNilSnapshotIsUnavailable() {
        XCTAssertEqual(FinanceWealthAllocationEngine.breakdown(from: nil), .unavailable)
    }

    func testUnavailableSnapshotIsUnavailable() {
        let value = snapshot(holdings: nil, availability: .unavailable)
        XCTAssertEqual(FinanceWealthAllocationEngine.breakdown(from: value), .unavailable)
    }

    // MARK: 2. Empty holdings behaves sanely -- no ring, no crash

    func testEmptyHoldingsIsUnavailable() {
        let value = snapshot(holdings: [])
        XCTAssertEqual(FinanceWealthAllocationEngine.breakdown(from: value), .unavailable)
    }

    // MARK: 3. Single category behaves sanely -- 100%, no partial flag

    func testSingleCategoryIsHundredPercent() {
        let value = snapshot(holdings: [
            observedHolding(id: "1", name: "VWCE", assetClass: "ETF", valueCents: 250_000)
        ])
        guard case .observed(let breakdown) = FinanceWealthAllocationEngine.breakdown(from: value) else {
            return XCTFail("expected an observed breakdown")
        }
        XCTAssertEqual(breakdown.categories.count, 1)
        XCTAssertEqual(breakdown.categories[0].name, "ETF")
        XCTAssertEqual(breakdown.categories[0].percentage, 100)
        XCTAssertEqual(breakdown.categories[0].valueCents, 250_000)
        XCTAssertEqual(breakdown.categories[0].holdingCount, 1)
        XCTAssertEqual(breakdown.totalValueCents, 250_000)
        XCTAssertFalse(breakdown.isPartial)
        XCTAssertEqual(breakdown.excludedHoldingCount, 0)
    }

    // MARK: 4. Missing asset class groups under "Uncategorized"

    func testMissingAssetClassGroupsAsUncategorized() {
        let value = snapshot(holdings: [
            observedHolding(id: "1", name: "Mystery holding", assetClass: nil, valueCents: 10_000),
            observedHolding(id: "2", name: "Mystery holding 2", assetClass: "   ", valueCents: 5_000)
        ])
        guard case .observed(let breakdown) = FinanceWealthAllocationEngine.breakdown(from: value) else {
            return XCTFail("expected an observed breakdown")
        }
        XCTAssertEqual(breakdown.categories.count, 1)
        XCTAssertEqual(breakdown.categories[0].name, "Uncategorized")
        XCTAssertEqual(breakdown.categories[0].holdingCount, 2)
        XCTAssertEqual(breakdown.categories[0].valueCents, 15_000)
        XCTAssertEqual(breakdown.categories[0].percentage, 100)
    }

    // MARK: 5. Rounding rule sums to exactly 100, largest-remainder tie-break by name

    func testThreeEqualCategoriesRoundToHundredByLargestRemainder() {
        let value = snapshot(holdings: [
            observedHolding(id: "1", name: "Bond fund", assetClass: "Bonds", valueCents: 100),
            observedHolding(id: "2", name: "ETF fund", assetClass: "ETF", valueCents: 100),
            observedHolding(id: "3", name: "Stock", assetClass: "Stocks", valueCents: 100)
        ])
        guard case .observed(let breakdown) = FinanceWealthAllocationEngine.breakdown(from: value) else {
            return XCTFail("expected an observed breakdown")
        }
        XCTAssertEqual(breakdown.categories.map(\.percentage).reduce(0, +), 100)
        // Equal values and remainders tie-break by ascending category name:
        // "Bonds" wins the single extra remainder point (34%), the rest get 33%.
        let byName = Dictionary(uniqueKeysWithValues: breakdown.categories.map { ($0.name, $0.percentage) })
        XCTAssertEqual(byName["Bonds"], 34)
        XCTAssertEqual(byName["ETF"], 33)
        XCTAssertEqual(byName["Stocks"], 33)
    }

    func testUnevenValuesRoundToHundredByLargestRemainder() {
        // 1/3, 1/3, 1/3 style split via non-round cents: 333, 333, 334 -> exact
        // percentages 33.3, 33.3, 33.4 rounding to 33/33/34 with no leftover
        // remainder distribution needed beyond the natural floors.
        let value = snapshot(holdings: [
            observedHolding(id: "1", name: "A", assetClass: "A", valueCents: 1),
            observedHolding(id: "2", name: "B", assetClass: "B", valueCents: 1),
            observedHolding(id: "3", name: "C", assetClass: "C", valueCents: 1),
            observedHolding(id: "4", name: "D", assetClass: "D", valueCents: 4)
        ])
        guard case .observed(let breakdown) = FinanceWealthAllocationEngine.breakdown(from: value) else {
            return XCTFail("expected an observed breakdown")
        }
        XCTAssertEqual(breakdown.totalValueCents, 7)
        XCTAssertEqual(breakdown.categories.map(\.percentage).reduce(0, +), 100)
    }

    // MARK: 6. An unavailable-value holding is excluded, never treated as zero

    func testUnavailableHoldingIsExcludedNotZeroed() {
        let value = snapshot(holdings: [
            observedHolding(id: "1", name: "VWCE", assetClass: "ETF", valueCents: 100_000),
            unavailableHolding(id: "2", name: "Unknown broker position", assetClass: "Unknown")
        ])
        guard case .observed(let breakdown) = FinanceWealthAllocationEngine.breakdown(from: value) else {
            return XCTFail("expected an observed breakdown")
        }
        // The unavailable holding must not appear as its own zero-value
        // category, and must not silently deflate the ETF category's share.
        XCTAssertEqual(breakdown.categories.count, 1)
        XCTAssertEqual(breakdown.categories[0].percentage, 100)
        XCTAssertEqual(breakdown.totalValueCents, 100_000)
        XCTAssertTrue(breakdown.isPartial)
        XCTAssertEqual(breakdown.excludedHoldingCount, 1)
    }

    func testAllHoldingsUnavailableIsUnavailable() {
        let value = snapshot(holdings: [
            unavailableHolding(id: "1", name: "Unknown broker position 1"),
            unavailableHolding(id: "2", name: "Unknown broker position 2")
        ])
        XCTAssertEqual(FinanceWealthAllocationEngine.breakdown(from: value), .unavailable)
    }

    // MARK: 7. Non-positive or non-EUR observed values are excluded defensively

    func testZeroValueHoldingIsExcluded() {
        let value = snapshot(holdings: [
            observedHolding(id: "1", name: "VWCE", assetClass: "ETF", valueCents: 100_000),
            observedHolding(id: "2", name: "Worthless position", assetClass: "Other", valueCents: 0)
        ])
        guard case .observed(let breakdown) = FinanceWealthAllocationEngine.breakdown(from: value) else {
            return XCTFail("expected an observed breakdown")
        }
        XCTAssertEqual(breakdown.categories.count, 1)
        XCTAssertEqual(breakdown.excludedHoldingCount, 1)
        XCTAssertTrue(breakdown.isPartial)
    }

    func testNonEURObservedValueIsExcludedDefensively() {
        let value = snapshot(holdings: [
            observedHolding(id: "1", name: "VWCE", assetClass: "ETF", valueCents: 100_000),
            observedHolding(id: "2", name: "US position", assetClass: "Stocks", valueCents: 50_000, currency: "USD")
        ])
        guard case .observed(let breakdown) = FinanceWealthAllocationEngine.breakdown(from: value) else {
            return XCTFail("expected an observed breakdown")
        }
        XCTAssertEqual(breakdown.categories.count, 1)
        XCTAssertEqual(breakdown.totalValueCents, 100_000)
        XCTAssertEqual(breakdown.excludedHoldingCount, 1)
    }

    // MARK: 8. Categories are ordered deterministically by value, ties by name

    func testCategoriesOrderedByValueDescendingThenName() {
        let value = snapshot(holdings: [
            observedHolding(id: "1", name: "Small", assetClass: "Cash", valueCents: 1_000),
            observedHolding(id: "2", name: "Big", assetClass: "ETF", valueCents: 100_000)
        ])
        guard case .observed(let breakdown) = FinanceWealthAllocationEngine.breakdown(from: value) else {
            return XCTFail("expected an observed breakdown")
        }
        XCTAssertEqual(breakdown.categories.map(\.name), ["ETF", "Cash"])
    }
}
