import XCTest
@testable import LifeOS

/// Exercises the Finance chart-mode wiring added for RF-08/RF-14/RF-07:
/// - RF-08: the bar-mode adapter (`FinanceDisplaySnapshot.barBuckets`,
///   reached here via `FinanceView.barBucketsForTesting`) must never turn a
///   week with no coverage into a fabricated zero.
/// - RF-14: `FinanceChartSelectionCodec` round-trips a date through an id in
///   a mode-agnostic way, which is what lets a selection survive a mode
///   switch without a parallel state model.
/// - RF-07: the net-worth projection wiring (`FinanceView
///   .netWorthProjectionForTesting`) must refuse to fabricate a trend when
///   there is no real observed history.
@available(iOS 17.0, macOS 14.0, *)
final class FinanceChartModeWiringTests: XCTestCase {

    // MARK: - RF-08: bar bucket honesty through the real adapter

    func testBarBucketsMarkWeeksBeforeObservedHistoryAsGapNotZero() throws {
        // Only ~10 days of real transactions, but a 31-day ("month") window
        // is requested — several early weeks in that window have no
        // coverage at all and must come back `totalCents == nil`, never `0`.
        let now = Date(timeIntervalSinceReferenceDate: 800_000_000)
        let transactions = try (0..<10).map { offset in
            try makeTransaction(cents: 5_000, daysBeforeNow: offset, now: now, isIncome: true)
        }

        let buckets = FinanceView.barBucketsForTesting(
            transactions: transactions,
            isIncome: true,
            windowCalendarDays: 31
        )

        XCTAssertFalse(buckets.isEmpty)
        let gapBuckets = buckets.filter { $0.totalCents == nil }
        XCTAssertFalse(gapBuckets.isEmpty, "A 31-day window over ~10 days of history must contain gap weeks.")
        for bucket in gapBuckets {
            XCTAssertTrue(bucket.isUnavailable)
        }

        let observedBuckets = buckets.filter { $0.totalCents != nil }
        XCTAssertFalse(observedBuckets.isEmpty, "Weeks that do overlap the observed transactions must carry a real total.")
        XCTAssertTrue(observedBuckets.contains { ($0.totalCents ?? 0) > 0 })
    }

    func testBarBucketsMarkTheCurrentWeekIncompleteNotADecline() throws {
        let now = Date(timeIntervalSinceReferenceDate: 800_000_000)
        let transactions = try (0..<10).map { offset in
            try makeTransaction(cents: 3_000, daysBeforeNow: offset, now: now, isIncome: false)
        }

        let buckets = FinanceView.barBucketsForTesting(
            transactions: transactions,
            isIncome: false,
            windowCalendarDays: nil // .max: displayRange == coverageRange, so no gap weeks here
        )

        XCTAssertFalse(buckets.isEmpty)
        XCTAssertTrue(
            buckets.allSatisfy { $0.totalCents != nil },
            "The .max window is exactly the observed coverage range; nothing in it should be a gap."
        )
        let ordered = buckets.sorted { $0.weekStart < $1.weekStart }
        XCTAssertFalse(ordered.last?.isComplete ?? true, "The bucket containing `now` must be the still-accumulating partial week.")
        XCTAssertTrue(ordered.dropLast().allSatisfy(\.isComplete), "Every earlier bucket has fully elapsed.")
    }

    func testBarBucketsWithNoTransactionsIsEmptyNotFabricated() {
        let buckets = FinanceView.barBucketsForTesting(transactions: [], isIncome: true, windowCalendarDays: 31)
        XCTAssertTrue(buckets.isEmpty, "No source points at all must yield no buckets, never a fabricated flat history.")
    }

    // MARK: - Finance display state

    func testFinanceChartStateUsesCompactNoSourceStateWithoutShowMax() {
        let snapshot = FinanceDisplaySnapshot(
            summary: nil,
            transactions: nil,
            usesVisualFixtures: false
        )

        XCTAssertEqual(snapshot.displayState, .noReviewedSource)
        let state = snapshot.chartState(for: .spend, range: .month)
        XCTAssertEqual(state.availability, .noReviewedSource)
        XCTAssertFalse(state.rendersChartShell)
        XCTAssertFalse(state.showsShowMax)
    }

    func testKnownSourceWithNoRowsHasNoShowMaxAction() {
        let snapshot = FinanceDisplaySnapshot(
            summary: nil,
            transactions: [],
            usesVisualFixtures: false
        )

        let state = snapshot.chartState(for: .spend, range: .month)
        XCTAssertTrue(snapshot.hasReviewedSource)
        XCTAssertEqual(state.availability, .sourceHasNoObservations)
        XCTAssertFalse(state.rendersChartShell)
        XCTAssertFalse(state.showsShowMax)
    }

    func testKnownSourceWithRangeFilteredEmptyKeepsPlotAndOffersShowMax() throws {
        let now = Date(timeIntervalSinceReferenceDate: 800_000_000)
        let transactions = try (0..<2).map { offset in
            try makeTransaction(cents: 5_000, daysBeforeNow: offset, now: now, isIncome: false)
        }
        let snapshot = FinanceDisplaySnapshot(
            summary: nil,
            transactions: transactions,
            usesVisualFixtures: false
        )

        let filtered = snapshot.chartState(for: .spend, range: .month)
        XCTAssertEqual(filtered.availability, .filteredEmpty)
        XCTAssertTrue(filtered.rendersChartShell)
        XCTAssertTrue(filtered.preservesPlotGeometry)
        XCTAssertTrue(filtered.showsShowMax)

        let max = snapshot.chartState(for: .spend, range: .max)
        XCTAssertEqual(max.availability, .observed)
        XCTAssertFalse(max.showsShowMax)
    }

    func testObservedStaleAndRefreshingStatesRetainTheirTruth() throws {
        let now = Date(timeIntervalSinceReferenceDate: 800_000_000)
        let transactions = try (0...31).map { offset in
            try makeTransaction(cents: 5_000, daysBeforeNow: offset, now: now, isIncome: true)
        }

        let observed = FinanceDisplaySnapshot(
            summary: nil,
            transactions: transactions,
            usesVisualFixtures: false
        )
        XCTAssertEqual(observed.displayState, .observed)
        XCTAssertEqual(observed.chartState(for: .income, range: .month).availability, .observed)

        let stale = FinanceDisplaySnapshot(
            summary: nil,
            transactions: transactions,
            usesVisualFixtures: false,
            observationState: .stale
        )
        XCTAssertEqual(stale.displayState, .staleRetained)
        XCTAssertEqual(stale.chartState(for: .income, range: .month).sourceState, .staleRetained)

        let refreshing = FinanceDisplaySnapshot(
            summary: nil,
            transactions: transactions,
            usesVisualFixtures: false,
            observationState: .observed,
            isRefreshing: true
        )
        XCTAssertEqual(refreshing.displayState, .refreshingRetained)
        XCTAssertEqual(refreshing.chartState(for: .income, range: .month).sourceState, .refreshingRetained)
    }

    // MARK: - RF-14: selection codec round-trips a date mode-agnostically

    func testSelectionCodecRoundTripsDate() {
        let date = Date(timeIntervalSinceReferenceDate: 123_456.789)
        let id = FinanceChartSelectionCodec.id(seriesID: "Income", date: date)
        XCTAssertEqual(FinanceChartSelectionCodec.date(fromID: id), date)
    }

    func testSelectionCodecRejectsMalformedID() {
        XCTAssertNil(FinanceChartSelectionCodec.date(fromID: "not-an-id"))
        XCTAssertNil(FinanceChartSelectionCodec.date(fromID: ""))
    }

    // MARK: - RF-07: projection wiring never fabricates a trend

    func testNetWorthProjectionWithoutFixturesIsInsufficientHistoryNotFabricated() {
        let result = FinanceView.netWorthProjectionForTesting(usesVisualFixtures: false)
        switch result {
        case .insufficientHistory(let provided, _):
            XCTAssertEqual(provided, 0, "The production (non-fixture) path has no net-worth observation store yet; it must refuse, not invent a trend.")
        default:
            XCTFail("Expected .insufficientHistory with zero real net-worth points, got \(result).")
        }
    }

    func testNetWorthProjectionWithDemoFixtureProducesAnHonestEstimate() {
        let result = FinanceView.netWorthProjectionForTesting(usesVisualFixtures: true)
        switch result {
        case .projected(let projection):
            XCTAssertGreaterThan(projection.basedOnPointCount, 0)
            XCTAssertGreaterThan(projection.targetDate, projection.asOfDate)
        default:
            XCTFail("The demo fixture has enough varying net-worth history to project; got \(result) instead.")
        }
    }

    // MARK: - Fixtures

    private func makeTransaction(
        cents: Int,
        daysBeforeNow: Int,
        now: Date,
        isIncome: Bool
    ) throws -> FinanceTransactionObservation {
        let timestamp = Calendar.current.date(byAdding: .day, value: -daysBeforeNow, to: now) ?? now
        let provenance = FinancePayloadProvenance(
            source: "revolut_personal",
            observedAt: now,
            freshness: .fresh,
            quality: .observed,
            connectorState: .healthy
        )
        return FinanceTransactionObservation(
            id: "tx-\(daysBeforeNow)-\(isIncome)",
            merchant: isIncome ? "Employer" : "Merchant",
            title: isIncome ? "Salary" : "Purchase",
            signedAmountCents: isIncome ? abs(cents) : -abs(cents),
            timestamp: timestamp,
            account: "Revolut Personal",
            source: "revolut_personal",
            category: isIncome ? "Income" : "Food",
            provenance: provenance
        )
    }
}
