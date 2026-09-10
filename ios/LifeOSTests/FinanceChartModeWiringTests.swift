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
@MainActor
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

    func testFinanceRoutePolicyAcceptsRepeatedRouteWhenGenerationChanges() {
        let first = FinanceInitialRouteIntent(route: .cashFlow, generation: 1)
        let repeated = FinanceInitialRouteIntent(route: .cashFlow, generation: 2)
        let cleared = FinanceInitialRouteIntent(route: nil, generation: 3)

        XCTAssertTrue(FinanceInitialRoutePolicy.shouldApply(first, after: nil))
        XCTAssertFalse(FinanceInitialRoutePolicy.shouldApply(first, after: first))
        XCTAssertTrue(FinanceInitialRoutePolicy.shouldApply(repeated, after: first))
        XCTAssertEqual(
            FinanceInitialRoutePolicy.action(for: cleared, after: repeated),
            .clear
        )
        XCTAssertEqual(
            FinanceInitialRoutePolicy.selectedDetail(for: .clear, current: .income),
            .income
        )
    }

    func testFinanceSceneStateKeepsSelectionAcrossClearAndRemountEvent() throws {
        let state = FinancePresentationState(selectedDetail: .income, selectedRange: .week, selectedChartMode: .bar, showAnalytics: true, analyticsSelectedEntry: .travel)
        state.receiveExternalRoute(.cashFlow)
        let first = try XCTUnwrap(state.externalRouteIntent)
        state.selectedDetail = .income
        state.receiveExternalRoute(nil)
        let cleared = try XCTUnwrap(state.externalRouteIntent)

        XCTAssertEqual(state.selectedDetail, .income)
        XCTAssertEqual(state.selectedRange, .week)
        XCTAssertEqual(state.selectedChartMode, .bar)
        XCTAssertTrue(state.showAnalytics)
        XCTAssertEqual(state.analyticsSelectedEntry, .travel)
        XCTAssertGreaterThan(cleared.generation, first.generation)
        XCTAssertEqual(
            FinanceInitialRoutePolicy.action(for: cleared, after: first),
            .clear
        )
    }

    func testPointSelectionPreservesExactSampleAndClearsWhenMissing() {
        XCTAssertEqual(
            FinancePointSelectionPolicy.preservedPointID(
                selectedID: "selected",
                availableIDs: ["older", "selected", "latest"]
            ),
            "selected"
        )
        XCTAssertNil(
            FinancePointSelectionPolicy.preservedPointID(
                selectedID: "gone",
                availableIDs: ["older", "latest"]
            )
        )
        XCTAssertNil(
            FinancePointSelectionPolicy.preservedPointID(
                selectedID: nil,
                availableIDs: ["latest"]
            )
        )
    }

    func testPointSelectionPreservesOnlySameModelAndRangeContext() {
        let model = FinanceChartModelContext(
            accountScope: "Revolut Personal",
            currency: "EUR",
            series: FinanceDetail.spend.rawValue,
            model: "transaction-daily-aggregate",
            provenance: "revolut_personal"
        )
        let base = FinanceChartSelectionContext(
            modelContext: model,
            range: .month,
            mode: .line,
            datasetRevision: FinanceChartDatasetRevision(pointCount: 2, fingerprint: 1)
        )
        let changedRange = FinanceChartSelectionContext(
            modelContext: model,
            range: .week,
            mode: .line,
            datasetRevision: base.datasetRevision
        )
        let changedDetail = FinanceChartSelectionContext(
            modelContext: FinanceChartModelContext(
                accountScope: model.accountScope,
                currency: model.currency,
                series: FinanceDetail.income.rawValue,
                model: model.model,
                provenance: model.provenance
            ),
            range: .month,
            mode: .line,
            datasetRevision: base.datasetRevision
        )
        let changedMode = FinanceChartSelectionContext(
            modelContext: model,
            range: .month,
            mode: .bar,
            datasetRevision: base.datasetRevision
        )
        let changedModel = FinanceChartSelectionContext(
            modelContext: FinanceChartModelContext(
                accountScope: "Sparkasse",
                currency: model.currency,
                series: model.series,
                model: model.model,
                provenance: model.provenance
            ),
            range: .month,
            mode: .line,
            datasetRevision: base.datasetRevision
        )

        XCTAssertEqual(
            FinancePointSelectionPolicy.selectionAfterRefresh(
                selectedID: "selected",
                availableIDs: ["selected", "latest"],
                previousContext: base,
                currentContext: base
            ),
            "selected"
        )
        for context in [changedRange, changedDetail, changedMode, changedModel] {
            XCTAssertNil(
                FinancePointSelectionPolicy.selectionAfterRefresh(
                    selectedID: "selected",
                    availableIDs: ["selected", "latest"],
                    previousContext: base,
                    currentContext: context
                )
            )
        }
    }

    func testProductionSnapshotAppendPreservesSelectedPointAcrossDatasetRevision() throws {
        let now = Date(timeIntervalSinceReferenceDate: 800_000_000)
        let existing = try [
            makeTransaction(cents: 5_000, daysBeforeNow: 2, now: now, isIncome: false),
            makeTransaction(cents: 7_000, daysBeforeNow: 1, now: now, isIncome: false)
        ]
        let appended = try makeTransaction(cents: 3_000, daysBeforeNow: 0, now: now, isIncome: false)
        let before = FinanceDisplaySnapshot(summary: nil, transactions: existing, usesVisualFixtures: false)
        let after = FinanceDisplaySnapshot(summary: nil, transactions: existing + [appended], usesVisualFixtures: false)
        let beforePoints = before.points(for: .spend, range: .max)
        let afterPoints = after.points(for: .spend, range: .max)
        let selectedID = try XCTUnwrap(beforePoints.first?.id)
        let beforeContext = before.chartSelectionContext(for: .spend, range: .max, mode: .line)
        let afterContext = after.chartSelectionContext(for: .spend, range: .max, mode: .line)

        XCTAssertEqual(beforeContext.modelContext, afterContext.modelContext)
        XCTAssertNotEqual(beforeContext.datasetRevision, afterContext.datasetRevision)
        XCTAssertEqual(
            FinancePointSelectionPolicy.selectionAfterRefresh(
                selectedID: selectedID,
                availableIDs: Set(afterPoints.map(\.id)),
                previousContext: beforeContext,
                currentContext: afterContext
            ),
            selectedID
        )
    }

    func testProductionSnapshotRemovalClearsTheMissingSelectedPoint() throws {
        let now = Date(timeIntervalSinceReferenceDate: 800_000_000)
        let retained = try makeTransaction(cents: 5_000, daysBeforeNow: 2, now: now, isIncome: false)
        let removed = try makeTransaction(cents: 7_000, daysBeforeNow: 1, now: now, isIncome: false)
        let before = FinanceDisplaySnapshot(summary: nil, transactions: [retained, removed], usesVisualFixtures: false)
        let after = FinanceDisplaySnapshot(summary: nil, transactions: [retained], usesVisualFixtures: false)
        let selectedID = try XCTUnwrap(before.points(for: .spend, range: .max).last?.id)
        let beforeContext = before.chartSelectionContext(for: .spend, range: .max, mode: .line)
        let afterContext = after.chartSelectionContext(for: .spend, range: .max, mode: .line)

        XCTAssertEqual(beforeContext.modelContext, afterContext.modelContext)
        XCTAssertNotEqual(beforeContext.datasetRevision, afterContext.datasetRevision)
        XCTAssertNil(
            FinancePointSelectionPolicy.selectionAfterRefresh(
                selectedID: selectedID,
                availableIDs: Set(after.points(for: .spend, range: .max).map(\.id)),
                previousContext: beforeContext,
                currentContext: afterContext
            )
        )
    }

    func testFinanceSceneStateRestoresRangePerDetail() {
        let state = FinancePresentationState(selectedDetail: .spend, selectedRange: .week)

        state.selectedDetail = .income
        state.selectedRange = .year
        state.selectedDetail = .spend
        XCTAssertEqual(state.selectedRange, .week)

        state.selectedDetail = .income
        XCTAssertEqual(state.selectedRange, .year)
    }

    func testFinanceSceneStateNormalizesInitialNetWorthRange() {
        let inferred = FinancePresentationState(selectedDetail: .netWorth, selectedRange: .year)
        XCTAssertEqual(inferred.selectedRange, .year)
        XCTAssertEqual(inferred.selectedNetWorthRange, .year)

        let explicit = FinancePresentationState(
            selectedDetail: .netWorth,
            selectedRange: .week,
            selectedNetWorthRange: .year
        )
        XCTAssertEqual(explicit.selectedRange, .year)
        XCTAssertEqual(explicit.selectedNetWorthRange, .year)
    }

    func testFinanceAnalyticsEntryIsHeldByPresentationState() {
        let state = FinancePresentationState()
        state.analyticsSelectedEntry = .wealth
        XCTAssertEqual(state.analyticsSelectedEntry, .wealth)
        state.analyticsSelectedEntry = .travel
        XCTAssertEqual(state.analyticsSelectedEntry, .travel)
    }

    func testFinanceSceneStateRetainsMainScrollAnchorAcrossAnalyticsToggle() {
        let state = FinancePresentationState(selectedDetail: .cashFlow, selectedRange: .halfYear)
        state.rememberMainScrollAnchor(.analytics)
        state.showAnalytics = true
        state.showAnalytics = false

        XCTAssertEqual(state.mainScrollAnchor, .analytics)
        XCTAssertEqual(state.selectedDetail, .cashFlow)
        XCTAssertEqual(state.selectedRange, .halfYear)
    }

    func testFinanceScrollRestorationChoosesLastSectionPastTop() {
        let anchor = FinanceScrollRestorationPolicy.anchor(for: [
            .header: -420,
            .summary: -80,
            .details: 18,
            .accounts: 420
        ])

        XCTAssertEqual(anchor, .summary)
    }

    func testFinanceScrollRestorationFallsBackToFirstFiniteSection() {
        let anchor = FinanceScrollRestorationPolicy.anchor(for: [
            .header: 180,
            .details: 640,
            .accounts: .infinity
        ])

        XCTAssertEqual(anchor, .header)
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
