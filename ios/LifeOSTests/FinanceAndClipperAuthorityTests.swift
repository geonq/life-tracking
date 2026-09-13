import XCTest
@testable import LifeOS

/// Closes the reachable `integration` halves of three P0 truth rows:
///
/// - DA-06: Finance account/transaction/budget/holding authority and
///   reconciliation. Proves net worth derives only from observed account
///   balances, cash flow only from observed transactions, a missing
///   component never becomes zero or silently promotes the aggregate to
///   `observed`, a trade/transaction never produces a holding value, and
///   manually imported data stays structurally distinct from connected data.
/// - DA-07: Clipper snapshot authority. Proves a correction sharing a
///   timestamp with the value it replaces supersedes it end-to-end through
///   the real decoder (`ClipperSnapshot.decode`) and the real projection
///   (`OverviewChartProjection.preferredClipperTrend`), and that a
///   revocation-by-correction removes the value rather than leaving a stale
///   one presentable as current.
/// - CL-02: Clipper ingestion -> gateway -> typed client preserves integer
///   cents exactly (a fractional wire value is rejected, never rounded),
///   keeps replay/retry bounded and idempotent, and never double-applies.
///
/// All Clipper snapshots below are constructed through
/// `ClipperSnapshot.decode`, never through a hand-built struct literal --
/// `ClipperSnapshot` has no public `.observed` initializer, so this is the
/// only route into an `.observed` snapshot and therefore already exercises
/// the full wire boundary (JSON syntax scan, key rejection, invariant
/// checks) rather than a shortcut around it.
@available(iOS 17.0, macOS 14.0, *)
final class FinanceAndClipperAuthorityTests: XCTestCase {

    // MARK: - DA-06: net worth / cash flow authority

    /// Net worth must come only from observed account balances. A wealth
    /// snapshot with a much larger observed holdings total sits alongside
    /// the account, but must never be folded into `netWorth`.
    func testNetWorthDerivesOnlyFromObservedAccountBalancesNeverFromWealthHoldings() throws {
        let now = Date.now
        let summary = try makeFinanceSummary(
            now: now,
            accounts: [account(id: "sparkasse-checking", balanceCents: 123_456, observedAt: now.addingTimeInterval(-1))],
            wealthHoldings: [holding(id: "etf-1", assetClass: "ETF", valueCents: 50_000_000, observedAt: now.addingTimeInterval(-1))]
        )

        let snapshot = FinanceDisplaySnapshot(summary: summary, transactions: nil, usesVisualFixtures: false)

        XCTAssertEqual(snapshot.netWorth.cents, 123_456, "Net worth must equal the account balance only, never account + holdings.")
        XCTAssertEqual(snapshot.wealth?.observedValueCents, 50_000_000, "The wealth snapshot itself must still carry its own observed total.")
        XCTAssertEqual(snapshot.netWorth.detail, "Observed account balances")
    }

    /// Cash flow must come only from observed transactions, never derived
    /// from account-balance deltas or wealth. A summary with a large,
    /// growing account balance but no transaction source must leave cash
    /// flow unavailable rather than inferring a flow from the balance.
    func testCashFlowDerivesOnlyFromObservedTransactionsNeverFromAccountsOrWealth() throws {
        let now = Date.now
        let summary = try makeFinanceSummary(
            now: now,
            accounts: [account(id: "revolut-personal", balanceCents: 900_000, observedAt: now.addingTimeInterval(-1))],
            wealthHoldings: [holding(id: "etf-1", assetClass: "ETF", valueCents: 10_000, observedAt: now.addingTimeInterval(-1))],
            includeTransactions: false
        )

        let snapshot = FinanceDisplaySnapshot(summary: summary, transactions: nil, usesVisualFixtures: false)

        XCTAssertTrue(snapshot.cashFlow.isUnavailable, "No observed transaction source exists; cash flow must stay unavailable, not zero or account-derived.")
        XCTAssertFalse(snapshot.hasTransactionSource)
        XCTAssertEqual(snapshot.netWorth.cents, 900_000, "Net worth is unaffected and still observed from the account.")
    }

    /// An `unavailable` accounts component must never become a $0 net worth,
    /// and its absence must not silently promote the aggregate assessment to
    /// fully `observed` when other components are missing too.
    func testMissingAccountsComponentStaysUnavailableNeverZeroAndDoesNotPromoteAggregateToObserved() throws {
        let now = Date.now
        let summary = try makeFinanceSummary(
            now: now,
            accounts: nil, // accounts component entirely unavailable
            wealthHoldings: nil,
            includeTransactions: true,
            transactionAmounts: [-2_450]
        )

        let snapshot = FinanceDisplaySnapshot(summary: summary, transactions: nil, usesVisualFixtures: false)

        XCTAssertTrue(snapshot.netWorth.isUnavailable, "Missing accounts must leave net worth unavailable, never a fabricated 0.")
        XCTAssertNil(snapshot.netWorth.cents)
        // Transactions ARE observed, so the aggregate must be "partial", not
        // "observed" (accounts are missing) and not "unavailable" (something
        // real was observed).
        XCTAssertEqual(snapshot.observationState, .partial)
        let assessment = summary.financeAssessment()
        XCTAssertEqual(assessment.state, .partial)
        XCTAssertGreaterThan(assessment.unavailableComponentCount, 0)
    }

    /// A partially-observed account list (one usable observed row, one
    /// unavailable row) must exclude the unavailable row from both the sum
    /// and the count, never coerce it to zero-and-add, and must mark the
    /// aggregate `partial` rather than `observed`.
    func testPartialAccountListExcludesUnavailableRowsFromNetWorthAndMarksPartial() throws {
        let now = Date.now
        let observedAt = now.addingTimeInterval(-1)
        let observedRow = account(id: "sparkasse-checking", balanceCents: 50_000, observedAt: observedAt)
        let unavailableRow = accountUnavailable(id: "sparkasse-savings", observedAt: observedAt, source: "sparkasse_leipzig")
        let summary = try makeFinanceSummary(
            now: now,
            accountsProvenanceSource: "sparkasse_leipzig",
            accountRows: [observedRow, unavailableRow],
            wealthHoldings: nil,
            includeTransactions: false
        )

        let snapshot = FinanceDisplaySnapshot(summary: summary, transactions: nil, usesVisualFixtures: false)

        // Only the observed row's balance must be summed; if the unavailable
        // row were ever coerced to 0 and added, the total would still read
        // 50_000 by coincidence, so also assert the account list surfaces
        // both rows (proving the unavailable row was seen, not dropped
        // silently) while the total excludes it.
        XCTAssertEqual(snapshot.accounts.count, 2)
        XCTAssertEqual(snapshot.netWorth.cents, 50_000)
        XCTAssertEqual(snapshot.observationState, .partial)
    }

    /// Investment-order-shaped transaction activity (large negative amount,
    /// "Investment" category) must be treated as ordinary cash spending and
    /// must never produce or adjust a holding value. Without an explicit
    /// wealth snapshot from the source, wealth stays nil/unavailable no
    /// matter how the cash ledger reads.
    func testWealthHoldingValueNeverInferredFromTransactionOrTradeActivity() throws {
        let now = Date.now
        let summary = try makeFinanceSummary(
            now: now,
            accounts: [account(id: "trade-republic-cash", balanceCents: 200_000, observedAt: now.addingTimeInterval(-1))],
            wealthHoldings: nil, // no wealth snapshot at all from the source
            includeTransactions: true,
            transactionAmounts: [-150_000], // a large outflow shaped like a buy order
            transactionCategory: "Investment"
        )

        let snapshot = FinanceDisplaySnapshot(summary: summary, transactions: nil, usesVisualFixtures: false)

        XCTAssertNil(summary.wealth, "No wealth snapshot was supplied by the source; the trade must not manufacture one.")
        XCTAssertNil(snapshot.wealth?.observedValueCents)
        XCTAssertEqual(FinanceWealthAllocationEngine.breakdown(from: snapshot.wealth), .unavailable)
        // The trade still counts as ordinary spending on the cash ledger.
        XCTAssertEqual(snapshot.cashFlow.cents, -150_000)
    }

    /// A manually imported row must never be presentable as connected-account
    /// data. `FinanceDisplaySnapshot.transactions` is typed
    /// `[FinanceTransactionObservation]` and can only ever be populated from
    /// the connector-backed summary/live transactions -- there is no code
    /// path that appends a `FinanceImportedTransaction` into it. This proves
    /// that at the source-disclosure level: only the connector source
    /// appears, never a manual-import source label, even when an import
    /// batch exists in parallel.
    func testManualImportNeverPresentableAsConnectedSourceInDisplaySnapshot() throws {
        let now = Date.now
        let summary = try makeFinanceSummary(
            now: now,
            accounts: [account(id: "revolut-personal", balanceCents: 10_000, observedAt: now.addingTimeInterval(-1))],
            wealthHoldings: nil,
            includeTransactions: true,
            transactionAmounts: [-500],
            transactionSource: "revolut_personal"
        )
        // A manually imported Trade Republic row exists in parallel, but is
        // never fed into `FinanceDisplaySnapshot`.
        let imported = FinanceImportedTransaction(
            bookedAt: now.addingTimeInterval(-86_400),
            amountCents: -9_999,
            description: "Manual import row",
            source: .tradeRepublicCSV
        )

        let snapshot = FinanceDisplaySnapshot(summary: summary, transactions: nil, usesVisualFixtures: false)

        XCTAssertTrue(snapshot.sourceDisclosure.contains("Revolut Personal") || snapshot.sourceDisclosure.contains("revolut"))
        XCTAssertFalse(snapshot.sourceDisclosure.lowercased().contains("trade republic"))
        XCTAssertFalse(snapshot.sourceDisclosure.lowercased().contains("csv"))
        // The imported row's amount must not appear anywhere in the
        // connector-backed cash flow total.
        XCTAssertEqual(snapshot.cashFlow.cents, -500)
        XCTAssertNotEqual(imported.amountCents, snapshot.cashFlow.cents)
    }

    // MARK: - DA-07: Clipper snapshot authority (correction / revocation)

    /// A corrected Clipper observation legitimately shares a timestamp with
    /// the value it supersedes. Decoding must succeed end-to-end (the
    /// ff5b262 fix), and the real projection must select the corrected
    /// (last-in-source) value, not the original.
    func testClipperCorrectionSharingTimestampSupersedesReplacedValueEndToEndThroughDecode() throws {
        let now = Date.now
        let correctedTimestamp = now.addingTimeInterval(-3_600)
        let laterTimestamp = now.addingTimeInterval(-1_800)

        let observedAt = now.addingTimeInterval(-1)
        let original = clipperTrendJSON(at: correctedTimestamp, observedAt: observedAt, views: 100, subscribers: 10, revenueCents: 500)
        let correction = clipperTrendJSON(at: correctedTimestamp, observedAt: observedAt, views: 275, subscribers: 10, revenueCents: 500)
        let later = clipperTrendJSON(at: laterTimestamp, observedAt: observedAt, views: 300, subscribers: 12, revenueCents: 700)

        // Decoding must NOT throw: two trend points at the same instant are
        // a correction, not corruption, as long as they are not
        // byte-identical.
        let snapshot = try decodeClipperSnapshot(now: now, trends: [original, correction, later])

        let selection = try XCTUnwrap(OverviewChartProjection.preferredClipperTrend(from: snapshot.trends ?? []))
        XCTAssertEqual(selection.metric, .views)
        XCTAssertEqual(selection.points.map(\.value), [275, 300], "The corrected (last-in-source) value must supersede the original, never the first-seen value.")
    }

    /// A revocation is a correction to `.unavailable`. The revoked instant
    /// must be removed from the trend series entirely -- never shown as the
    /// stale pre-revocation value, and never shown as a fabricated zero.
    func testClipperRevocationViaCorrectionRemovesValueRatherThanLeavingStalePresentable() throws {
        let now = Date.now
        let keptEarly = now.addingTimeInterval(-7_200)
        let revokedInstant = now.addingTimeInterval(-3_600)
        let keptLate = now.addingTimeInterval(-1_800)

        let observedAt = now.addingTimeInterval(-1)
        let early = clipperTrendJSON(at: keptEarly, observedAt: observedAt, views: 100, subscribers: 10, revenueCents: 500)
        let staleValueBeforeRevocation = clipperTrendJSON(at: revokedInstant, observedAt: observedAt, views: 150, subscribers: 11, revenueCents: 600)
        let revocation = clipperTrendJSON(at: revokedInstant, observedAt: observedAt, views: nil, subscribers: 11, revenueCents: 600)
        let late = clipperTrendJSON(at: keptLate, observedAt: observedAt, views: 240, subscribers: 12, revenueCents: 700)

        let snapshot = try decodeClipperSnapshot(now: now, trends: [early, staleValueBeforeRevocation, revocation, late])

        let selection = try XCTUnwrap(OverviewChartProjection.preferredClipperTrend(from: snapshot.trends ?? []))
        XCTAssertEqual(selection.metric, .views)
        XCTAssertEqual(
            selection.points.map(\.value), [100, 240],
            "The revoked instant (150) must be dropped entirely -- never shown as a lingering stale value and never coerced to 0."
        )
        XCTAssertEqual(selection.points.count, 2)
    }

    // MARK: - CL-02: integer cents, provenance, and safe retry

    /// The wire boundary must reject a fractional cents value outright
    /// rather than silently rounding it into an integer. Money in this
    /// domain is `Int` cents everywhere; a payload asserting a non-integer
    /// amount is malformed, not "close enough".
    func testClipperIntegerCentsRejectsFractionalWireValueRatherThanRounding() throws {
        let now = Date.now
        let provenance = clipperProvenanceJSON(observedAt: now.addingTimeInterval(-1))
        var metrics = clipperMetricsJSON(views: 42_000, subscribers: 1_240, revenueCents: 84_200, provenance: provenance)
        // Corrupt the wire payload's revenue amount to a fractional cents
        // value by string surgery on otherwise-valid JSON.
        metrics = metrics.replacingOccurrences(of: "\"amountCents\":84200", with: "\"amountCents\":84200.5")

        let payload = clipperSnapshotJSON(now: now, metricsJSON: metrics, accountsJSON: "[]", trendsJSON: "[]", breakdownsJSON: "[]", topLevelProvenanceJSON: provenance)

        XCTAssertThrowsError(try ClipperSnapshot.decode(Data(payload.utf8), now: now)) { error in
            XCTAssertTrue(error is DecodingError, "A fractional cents value must be rejected at decode, not rounded into an Int.")
        }
    }

    /// Retry safety: submitting the identical accepted snapshot twice must
    /// never double-apply (second submission reports `.replay`), and the
    /// replay ledger must stay bounded rather than growing without limit as
    /// retries accumulate. A key that has aged out of the bound is,
    /// correctly, no longer tracked -- proving the bound is enforced, not
    /// silently unbounded.
    func testClipperReplayLedgerRetryIsIdempotentAndBoundedNeverDoubleApplies() throws {
        let now = Date.now
        let snapshot = try decodeClipperSnapshot(now: now, trends: [])

        var ledger = ClipperReplayLedger()
        XCTAssertEqual(try ledger.accept(snapshot: snapshot, now: now), .accepted)
        // Simulate three retried deliveries of the exact same accepted
        // payload (e.g. a client retrying after a dropped ACK).
        for _ in 0..<3 {
            XCTAssertEqual(try ledger.accept(snapshot: snapshot, now: now), .replay, "A retried identical payload must never be re-applied as new.")
        }

        // Fill the ledger past its bound with distinct synthetic keys, then
        // confirm the ledger enforces `maximumReplayKeys` rather than
        // growing unbounded.
        var flooded = ClipperReplayLedger(acceptedKeys: (0..<(ClipperPayloadLimits.maximumReplayKeys + 50)).map { "synthetic-\($0)" })
        XCTAssertEqual(flooded.acceptedKeys.count, ClipperPayloadLimits.maximumReplayKeys, "The ledger must cap stored keys at the documented bound.")
        // The oldest synthetic keys must have been evicted (FIFO), the
        // newest retained.
        XCTAssertFalse(flooded.acceptedKeys.contains("synthetic-0"))
        XCTAssertTrue(flooded.acceptedKeys.contains("synthetic-\(ClipperPayloadLimits.maximumReplayKeys + 49)"))
    }

    // MARK: - Break-and-confirm scratch helpers (not test cases)

    // MARK: - Helpers: Finance

    private func account(id: String, balanceCents: Int, observedAt: Date, source: String = "sparkasse_leipzig") -> [String: Any] {
        [
            "availability": "observed",
            "id": id, "name": id, "detail": "Checking",
            "balanceCents": balanceCents, "source": source,
            "provenance": [
                "source": source, "observedAt": iso(observedAt),
                "freshness": "fresh", "quality": "observed", "connectorState": "healthy"
            ]
        ]
    }

    private func accountUnavailable(id: String, observedAt: Date, source: String = "revolut_personal") -> [String: Any] {
        [
            "availability": "unavailable",
            "id": id, "name": id, "detail": "Checking",
            "source": source,
            "provenance": [
                "source": source, "observedAt": iso(observedAt),
                "freshness": "unknown", "quality": "unavailable", "connectorState": "unavailable"
            ]
        ]
    }

    private func holding(id: String, assetClass: String, valueCents: Int, observedAt: Date, source: String = "manual_wealth_entry") -> [String: Any] {
        [
            "availability": "observed",
            "id": id, "name": id, "assetClass": assetClass,
            "valueCents": valueCents, "currency": "EUR", "source": source,
            "provenance": [
                "source": source, "observedAt": iso(observedAt),
                "freshness": "fresh", "quality": "observed", "connectorState": "healthy"
            ]
        ]
    }

    private func iso(_ date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.string(from: date)
    }

    private func makeFinanceSummary(
        now: Date,
        accounts: [[String: Any]]? = nil,
        accountsProvenanceSource: String? = nil,
        accountRows: [[String: Any]]? = nil,
        wealthHoldings: [[String: Any]]?,
        includeTransactions: Bool = false,
        transactionAmounts: [Int] = [],
        transactionSource: String = "revolut_personal",
        transactionCategory: String = "Food"
    ) throws -> FinanceSummary {
        let unavailableAmount: [String: Any] = [
            "availability": "unavailable",
            "provenance": [
                "source": "no-authorized-finance-source", "observedAt": iso(now.addingTimeInterval(-1)),
                "freshness": "unknown", "quality": "unavailable", "connectorState": "unavailable"
            ]
        ]

        var payload: [String: Any] = [
            "generatedAt": iso(now), "currency": "EUR",
            "monthlyIncome": unavailableAmount, "fixedCosts": unavailableAmount,
            "discretionaryBuffer": unavailableAmount, "spent": unavailableAmount,
            "savingsGoal": unavailableAmount, "saved": unavailableAmount
        ]

        let rows = accountRows ?? accounts
        if let rows, !rows.isEmpty {
            let source = accountsProvenanceSource ?? (rows.first?["source"] as? String ?? "sparkasse_leipzig")
            payload["accounts"] = [
                "availability": "observed",
                "accounts": rows,
                "provenance": [
                    "source": source, "observedAt": iso(now.addingTimeInterval(-1)),
                    "freshness": "fresh", "quality": "observed", "connectorState": "healthy"
                ]
            ]
        }

        if let wealthHoldings, !wealthHoldings.isEmpty {
            payload["wealth"] = [
                "availability": "observed",
                "holdings": wealthHoldings,
                "provenance": [
                    "source": "manual_wealth_entry", "observedAt": iso(now.addingTimeInterval(-1)),
                    "freshness": "fresh", "quality": "observed", "connectorState": "healthy"
                ]
            ]
        }

        if includeTransactions {
            let observedAt = now.addingTimeInterval(-1)
            let transactionProvenance: [String: Any] = [
                "source": transactionSource, "observedAt": iso(observedAt),
                "freshness": "fresh", "quality": "observed", "connectorState": "healthy"
            ]
            let rows: [[String: Any]] = transactionAmounts.enumerated().map { index, amount in
                [
                    "id": "\(transactionSource)-\(index + 1)",
                    "merchant": amount > 0 ? "Employer" : "Merchant",
                    "title": amount > 0 ? "Salary" : "Purchase",
                    "signedAmountCents": amount,
                    "timestamp": iso(observedAt),
                    "account": transactionSource,
                    "source": transactionSource,
                    "category": transactionCategory,
                    "provenance": transactionProvenance
                ]
            }
            payload["transactions"] = [
                "availability": "observed",
                "transactions": rows,
                "provenance": transactionProvenance
            ]
        }

        return try FinanceSummary.decode(JSONSerialization.data(withJSONObject: payload), now: now)
    }

    // MARK: - Helpers: Clipper

    private func clipperProvenanceJSON(observedAt: Date, source: String = "reviewed-clipper-connector") -> String {
        "{\"source\":\"\(source)\",\"observedAt\":\"\(iso(observedAt))\",\"freshness\":\"fresh\",\"quality\":\"observed\",\"connectorState\":\"healthy\"}"
    }

    private func clipperMetricsJSON(views: Int, subscribers: Int, revenueCents: Int, provenance: String) -> String {
        """
        {"views":{"availability":"observed","value":\(views),"provenance":\(provenance)},"subscribers":{"availability":"observed","value":\(subscribers),"provenance":\(provenance)},"revenue":{"availability":"observed","amountCents":\(revenueCents),"currency":"EUR","provenance":\(provenance)}}
        """
    }

    /// `date` is the trend's own historical instant (`at`); `observedAt` is
    /// when this observation was fetched/recorded, which is what each
    /// metric's provenance freshness is actually judged against. These are
    /// deliberately different: a trend point about an hour-old instant is
    /// still a *fresh* observation if it was fetched moments ago.
    private func clipperTrendJSON(at date: Date, observedAt: Date, views: Int?, subscribers: Int, revenueCents: Int) -> String {
        let observedProvenance = clipperProvenanceJSON(observedAt: observedAt)
        let unavailableProvenance = "{\"source\":\"no-authorized-clipper-source\",\"observedAt\":\"\(iso(observedAt))\",\"freshness\":\"unknown\",\"quality\":\"unavailable\",\"connectorState\":\"unavailable\"}"
        let viewsJSON = views.map { "{\"availability\":\"observed\",\"value\":\($0),\"provenance\":\(observedProvenance)}" }
            ?? "{\"availability\":\"unavailable\",\"provenance\":\(unavailableProvenance)}"
        return """
        {"at":"\(iso(date))","metrics":{"views":\(viewsJSON),"subscribers":{"availability":"observed","value":\(subscribers),"provenance":\(observedProvenance)},"revenue":{"availability":"observed","amountCents":\(revenueCents),"currency":"EUR","provenance":\(observedProvenance)}}}
        """
    }

    private func clipperSnapshotJSON(
        now: Date,
        metricsJSON: String,
        accountsJSON: String,
        trendsJSON: String,
        breakdownsJSON: String,
        topLevelProvenanceJSON: String
    ) -> String {
        """
        {
          "schemaVersion": 1,
          "availability": "observed",
          "generatedAt": "\(iso(now))",
          "currency": "EUR",
          "metrics": \(metricsJSON),
          "accounts": \(accountsJSON),
          "trends": \(trendsJSON),
          "breakdowns": \(breakdownsJSON),
          "provenance": \(topLevelProvenanceJSON)
        }
        """
    }

    private func decodeClipperSnapshot(now: Date, trends: [String]) throws -> ClipperSnapshot {
        let provenance = clipperProvenanceJSON(observedAt: now.addingTimeInterval(-1))
        let metrics = clipperMetricsJSON(views: 42_000, subscribers: 1_240, revenueCents: 84_200, provenance: provenance)
        let trendsJSON = "[" + trends.joined(separator: ",") + "]"
        let payload = clipperSnapshotJSON(
            now: now, metricsJSON: metrics, accountsJSON: "[]",
            trendsJSON: trendsJSON, breakdownsJSON: "[]", topLevelProvenanceJSON: provenance
        )
        return try ClipperSnapshot.decode(Data(payload.utf8), now: now)
    }
}
