import XCTest
@testable import LifeOS

final class FinanceDomainTests: XCTestCase {
    func testSpendableBudgetUsesObservedPerMetricValues() throws {
        let summary = try decodeSummary(
            monthlyIncome: 300_000,
            fixedCosts: 170_000,
            discretionaryBuffer: 30_000,
            spent: 45_000,
            savingsGoal: 1_000_000,
            saved: 250_000
        )

        XCTAssertEqual(summary.spendableBudgetCents, 100_000)
        XCTAssertEqual(summary.budgetUsedFraction ?? -1, 0.45, accuracy: 0.0001)
        XCTAssertEqual(summary.savingsProgressFraction ?? -1, 0.25, accuracy: 0.0001)
        XCTAssertEqual(summary.spent.provenance.quality, .observed)
    }

    func testFinanceConnectorCatalogFailsClosedUntilExplicitlyConfigured() {
        XCTAssertEqual(FinanceConnectorCatalog.defaults.map(\.kind), [.sparkasse, .revolutPersonal, .revolutBusiness, .tradeRepublic])
        XCTAssertTrue(FinanceConnectorCatalog.defaults.allSatisfy { !$0.isEnabled })
        XCTAssertTrue(FinanceConnectorCatalog.defaults.allSatisfy(\.requiresExplicitOptIn))
        XCTAssertTrue(FinanceConnectorCatalog.defaults.allSatisfy { !$0.provider.isEmpty && !$0.recommendation.isEmpty })
        XCTAssertEqual(FinanceConnectorCatalog.defaults.filter { $0.accessMethod == .regulatedOpenBanking }.map(\.provider), ["GoCardless Bank Account Data", "GoCardless Bank Account Data"])
        XCTAssertEqual(FinanceConnectorCatalog.defaults.filter { $0.risk == .consentRequired }.map(\.kind), [.sparkasse, .revolutPersonal])
        XCTAssertEqual(FinanceConnectorCatalog.defaults.first { $0.kind == .revolutBusiness }?.accessMethod, .officialOAuth)
        XCTAssertEqual(FinanceConnectorCatalog.defaults.first { $0.kind == .revolutBusiness }?.provider, "Official Revolut Business API")
        XCTAssertEqual(FinanceConnectorCatalog.defaults.first { $0.kind == .revolutBusiness }?.risk, .accountEligibilityRequired)
        XCTAssertEqual(FinanceConnectorCatalog.defaults.first { $0.kind == .tradeRepublic }?.accessMethod, .manualImport)
        XCTAssertEqual(FinanceConnectorCatalog.defaults.first { $0.kind == .tradeRepublic }?.provider, "Manual CSV/PDF import")
        XCTAssertEqual(FinanceConnectorCatalog.defaults.first { $0.kind == .tradeRepublic }?.risk, .manualImportOnly)
    }

    func testFinanceConnectorWireKeysMatchSharedAPIContract() throws {
        let data = Data("""
        {
          "id": "revolut_business",
          "displayName": "Revolut Business",
          "accessMethod": "official_oauth",
          "provider": "Official Revolut Business API",
          "enabled": false,
          "requiresExplicitOptIn": true,
          "risk": "account_eligibility_required",
          "recommendation": "Register an eligible Revolut Business app and complete official OAuth before enabling; Revolut review may delay access."
        }
        """.utf8)

        let descriptor = try JSONDecoder().decode(FinanceConnectorDescriptor.self, from: data)
        XCTAssertEqual(descriptor.kind, .revolutBusiness)
        XCTAssertFalse(descriptor.isEnabled)
        XCTAssertEqual(descriptor.accessMethod, .officialOAuth)

        let enabled = Data(String(decoding: data, as: UTF8.self)
            .replacingOccurrences(of: "\"enabled\": false", with: "\"enabled\": true").utf8)
        XCTAssertThrowsError(try JSONDecoder().decode(FinanceConnectorDescriptor.self, from: enabled))

        let encodedDefaults = try JSONEncoder().encode(FinanceConnectorCatalog.defaults)
        guard let connectorArray = try JSONSerialization.jsonObject(with: encodedDefaults) as? [[String: Any]] else {
            XCTFail("Encoded Finance connector defaults must be a JSON array")
            return
        }
        let catalogData = try JSONSerialization.data(withJSONObject: ["connectors": connectorArray])
        let catalog = try FinanceConnectorCatalog.decode(catalogData)
        XCTAssertEqual(catalog.connectors.map(\.kind), [.sparkasse, .revolutPersonal, .revolutBusiness, .tradeRepublic])

        let incompleteData = try JSONSerialization.data(withJSONObject: ["connectors": Array(connectorArray.dropLast())])
        XCTAssertThrowsError(try FinanceConnectorCatalog.decode(incompleteData))
    }

    func testBudgetFractionsAvoidDivisionByZero() throws {
        let summary = try decodeSummary(
            monthlyIncome: 100,
            fixedCosts: 100,
            discretionaryBuffer: 0,
            spent: 500,
            savingsGoal: 0,
            saved: 500
        )

        XCTAssertEqual(summary.spendableBudgetCents, 0)
        XCTAssertNil(summary.budgetUsedFraction)
        XCTAssertNil(summary.savingsProgressFraction)
    }

    func testUnavailableAmountsDoNotProduceDerivedZeros() throws {
        let summary = try decodeSummary(
            monthlyIncome: nil,
            fixedCosts: 100,
            discretionaryBuffer: 0,
            spent: nil,
            savingsGoal: nil,
            saved: 0
        )

        XCTAssertNil(summary.monthlyIncomeCents)
        XCTAssertNil(summary.spentCents)
        XCTAssertNil(summary.spendableBudgetCents)
        XCTAssertNil(summary.budgetUsedFraction)
        XCTAssertNil(summary.savingsProgressFraction)
        XCTAssertEqual(summary.monthlyIncome.provenance.quality, .unavailable)
        XCTAssertEqual(summary.monthlyIncome.provenance.connectorState, .unavailable)
    }

    func testFinancePayloadPreservesPerMetricUnavailableProvenance() throws {
        let provenance: [String: Any] = [
            "source": "no-authorized-finance-source",
            "observedAt": "2026-08-08T12:00:00.123Z",
            "freshness": "unknown",
            "quality": "unavailable",
            "connectorState": "unavailable"
        ]
        let unavailable: [String: Any] = ["availability": "unavailable", "provenance": provenance]
        let payload: [String: Any] = [
            "generatedAt": "2026-08-08T12:00:00.456Z", "currency": "EUR",
            "monthlyIncome": unavailable, "fixedCosts": unavailable,
            "discretionaryBuffer": unavailable, "spent": unavailable,
            "savingsGoal": unavailable, "saved": unavailable
        ]

        let decoded = try FinanceSummary.decode(JSONSerialization.data(withJSONObject: payload))

        XCTAssertEqual(decoded.currency, "EUR")
        XCTAssertEqual(decoded.spent.availability, .unavailable)
        XCTAssertNil(decoded.spent.amountCents)
        XCTAssertEqual(decoded.spent.provenance.quality, .unavailable)
    }

    func testFinancePayloadRejectsUnavailableMetricWithFabricatedZero() throws {
        let provenance: [String: Any] = [
            "source": "no-authorized-finance-source",
            "observedAt": "2026-08-08T12:00:00.123Z",
            "freshness": "unknown",
            "quality": "unavailable",
            "connectorState": "unavailable"
        ]
        let unavailable: [String: Any] = ["availability": "unavailable", "provenance": provenance]
        var invalid = unavailable
        invalid["amountCents"] = 0
        let payload: [String: Any] = [
            "generatedAt": "2026-08-08T12:00:00.456Z", "currency": "EUR",
            "monthlyIncome": unavailable, "fixedCosts": unavailable,
            "discretionaryBuffer": unavailable, "spent": invalid,
            "savingsGoal": unavailable, "saved": unavailable
        ]

        let data = try JSONSerialization.data(withJSONObject: payload)
        XCTAssertThrowsError(try FinanceSummary.decode(data))
    }

    func testFinancePayloadRejectsNullUnknownUnsafeAndUnsupportedValues() throws {
        let unavailableProvenance: [String: Any] = [
            "source": "no-authorized-finance-source",
            "observedAt": "2026-08-08T12:00:00.123Z",
            "freshness": "unknown",
            "quality": "unavailable",
            "connectorState": "unavailable"
        ]
        let unavailable: [String: Any] = ["availability": "unavailable", "provenance": unavailableProvenance]
        var base: [String: Any] = [
            "generatedAt": "2026-08-08T12:00:00.456Z", "currency": "EUR",
            "monthlyIncome": unavailable, "fixedCosts": unavailable,
            "discretionaryBuffer": unavailable, "spent": unavailable,
            "savingsGoal": unavailable, "saved": unavailable
        ]

        var nullMetric = unavailable
        nullMetric["amountCents"] = NSNull()
        base["spent"] = nullMetric
        XCTAssertThrowsError(try FinanceSummary.decode(JSONSerialization.data(withJSONObject: base)))

        base["spent"] = unavailable
        base["unexpected"] = true
        XCTAssertThrowsError(try FinanceSummary.decode(JSONSerialization.data(withJSONObject: base)))

        base.removeValue(forKey: "unexpected")
        base["currency"] = "USD"
        XCTAssertThrowsError(try FinanceSummary.decode(JSONSerialization.data(withJSONObject: base)))

        base["currency"] = "EUR"
        base["spent"] = [
            "availability": "observed",
            "amountCents": 9_007_199_254_740_992,
            "provenance": [
                "source": "statement-import",
                "observedAt": "2026-08-08T12:00:00.123Z",
                "freshness": "fresh",
                "quality": "observed",
                "connectorState": "healthy"
            ]
        ]
        XCTAssertThrowsError(try FinanceSummary.decode(JSONSerialization.data(withJSONObject: base)))
    }

    func testFinancePayloadRejectsFutureAndFreshnessInconsistentObservedValues() throws {
        let now = Date.now
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        func payload(observedAt: Date, freshness: String, connector: String) -> Data {
            let provenance: [String: Any] = ["source": "statement-import",
                "observedAt": formatter.string(from: observedAt), "freshness": freshness,
                "quality": "observed", "connectorState": connector]
            let metric: [String: Any] = ["availability": "observed", "amountCents": 100, "provenance": provenance]
            return try! JSONSerialization.data(withJSONObject: [
                "generatedAt": formatter.string(from: now), "currency": "EUR",
                "monthlyIncome": metric, "fixedCosts": metric, "discretionaryBuffer": metric,
                "spent": metric, "savingsGoal": metric, "saved": metric
            ])
        }
        XCTAssertThrowsError(try FinanceSummary.decode(
            payload(observedAt: now.addingTimeInterval(60), freshness: "fresh", connector: "healthy"), now: now))
        XCTAssertThrowsError(try FinanceSummary.decode(
            payload(observedAt: now.addingTimeInterval(-3600), freshness: "fresh", connector: "healthy"), now: now))
    }

    func testTransactionTotalsReconcileIncomeSpendAndCashFlow() {
        let transactions = fixtureTransactions()
        let totals = FinanceTransactionTotals(transactions: transactions)

        XCTAssertEqual(totals.incomeCents, 10_500)
        XCTAssertEqual(totals.spendingCents, 4_000)
        XCTAssertEqual(totals.netCashFlowCents, 6_500)
        XCTAssertEqual(totals.transactionCount, 4)
        XCTAssertEqual(totals.categoryObservations.map(\.name), ["Food", "Transport"])
        XCTAssertEqual(totals.categoryObservations.map(\.amountCents), [2_500, 1_500])
        XCTAssertEqual(totals.categoryObservations.map(\.transactionCount), [1, 1])
        XCTAssertEqual(totals.categoryObservations.reduce(0) { $0 + $1.amountCents }, totals.spendingCents)
        XCTAssertEqual(totals.categoryObservations.reduce(0.0) { $0 + $1.fraction }, 1.0, accuracy: 0.0001)
    }

    func testCategoryProvenanceIsExplicitlyDerivedForMixedSources() {
        let base = fixtureTransactions()
        let sparkasseObservedAt = base[1].provenance.observedAt.addingTimeInterval(-60 * 60)
        let sparkasseProvenance = FinancePayloadProvenance(
            source: "sparkasse", observedAt: sparkasseObservedAt,
            freshness: .stale, quality: .observed, connectorState: .refreshDue
        )
        let secondFood = FinanceTransactionObservation(
            id: "food-2", merchant: "EDEKA", title: "Groceries", signedAmountCents: -1_000,
            timestamp: sparkasseObservedAt, account: "Sparkasse", source: "sparkasse",
            category: "Food", provenance: sparkasseProvenance
        )
        let totals = FinanceTransactionTotals(transactions: base + [secondFood])
        let food = try! XCTUnwrap(totals.categoryObservations.first(where: { $0.name == "Food" }))

        XCTAssertEqual(food.source, "derived-transaction-rollup")
        XCTAssertEqual(food.provenance.source, "derived-transaction-rollup")
        XCTAssertEqual(food.contributingSources, ["revolut_personal", "sparkasse"])
        XCTAssertTrue(food.isMixedSource)
        XCTAssertEqual(food.sourceSummary, "revolut_personal, sparkasse")
        XCTAssertEqual(food.provenance.observedAt, sparkasseObservedAt)
        XCTAssertEqual(food.provenance.freshness, .stale)
        XCTAssertEqual(food.provenance.connectorState, .refreshDue)
    }

    func testTransactionFilterComposesCategorySourceDateAndSpendingOnly() {
        let transactions = fixtureTransactions()
        let filter = FinanceTransactionFilter(
            category: "Food",
            source: "revolut_personal",
            startDate: transactions[1].timestamp,
            endDate: transactions[1].timestamp,
            spendingOnly: true
        )

        let filtered = filter.applying(to: transactions)

        XCTAssertEqual(filtered.map(\.id), ["food-1"])
        XCTAssertTrue(filtered.allSatisfy { $0.category == "Food" && $0.isSpending })
    }

    func testSummaryWithoutTransactionSourceDoesNotInventLedgerTotals() throws {
        let summary = try decodeSummary(
            monthlyIncome: 10_500,
            fixedCosts: nil,
            discretionaryBuffer: nil,
            spent: 4_000,
            savingsGoal: nil,
            saved: nil
        )

        XCTAssertNil(summary.transactions)
        XCTAssertNil(summary.transactions?.transactions)
    }

    func testObservedTransactionSnapshotPreservesSourceAwareFields() throws {
        let transaction = fixtureTransactions()[0]
        let snapshot = FinanceTransactionSnapshot(
            availability: .observed,
            transactions: [transaction],
            provenance: transaction.provenance
        )
        let encoded = try JSONEncoder.lifeOS.encode(snapshot)
        let decoder = JSONDecoder.lifeOS
        decoder.userInfo[.lifeOSNow] = Date(timeIntervalSince1970: 1_754_660_000)
        let decoded = try decoder.decode(FinanceTransactionSnapshot.self, from: encoded)

        XCTAssertEqual(decoded.transactions?.first?.merchant, "Salary")
        XCTAssertEqual(decoded.transactions?.first?.signedAmountCents, 10_000)
        XCTAssertEqual(decoded.transactions?.first?.account, "Revolut Personal")
        XCTAssertEqual(decoded.transactions?.first?.source, "revolut_personal")
        XCTAssertEqual(decoded.transactions?.first?.provenance.quality, .observed)
    }

    func testTransactionObservationRejectsSourceProvenanceMismatch() throws {
        let transaction = fixtureTransactions()[0]
        var payload = try XCTUnwrap(
            try JSONSerialization.jsonObject(with: JSONEncoder.lifeOS.encode(transaction)) as? [String: Any]
        )
        payload["source"] = "sparkasse"

        let decoder = JSONDecoder.lifeOS
        decoder.userInfo[.lifeOSNow] = Date(timeIntervalSince1970: 1_754_660_000)
        XCTAssertThrowsError(try decoder.decode(
            FinanceTransactionObservation.self,
            from: JSONSerialization.data(withJSONObject: payload)
        ))
    }

    func testObservedTransactionSnapshotRejectsUnreconciledSourceAndRowObservationTime() throws {
        let transaction = fixtureTransactions()[0]
        let snapshot = FinanceTransactionSnapshot(
            availability: .observed,
            transactions: [transaction],
            provenance: transaction.provenance
        )
        let encoded = try JSONSerialization.jsonObject(with: JSONEncoder.lifeOS.encode(snapshot)) as! [String: Any]
        var sourceMismatch = encoded
        sourceMismatch["provenance"] = [
            "source": "sparkasse",
            "observedAt": "2025-08-08T13:30:00.000Z",
            "freshness": "fresh",
            "quality": "observed",
            "connectorState": "healthy"
        ]
        var oldEnvelope = encoded
        oldEnvelope["provenance"] = [
            "source": "revolut_personal",
            "observedAt": "2025-08-08T11:00:00.000Z",
            "freshness": "fresh",
            "quality": "observed",
            "connectorState": "healthy"
        ]

        let decoder = JSONDecoder.lifeOS
        decoder.userInfo[.lifeOSNow] = Date(timeIntervalSince1970: 1_754_660_000)
        XCTAssertThrowsError(try decoder.decode(
            FinanceTransactionSnapshot.self,
            from: JSONSerialization.data(withJSONObject: sourceMismatch)
        ))
        XCTAssertThrowsError(try decoder.decode(
            FinanceTransactionSnapshot.self,
            from: JSONSerialization.data(withJSONObject: oldEnvelope)
        ))
    }

    func testCategoryObservationRejectsMalformedInvariants() throws {
        let category = try XCTUnwrap(
            FinanceTransactionTotals(transactions: fixtureTransactions())
                .categoryObservations.first(where: { $0.name == "Food" })
        )
        let valid = try XCTUnwrap(
            try JSONSerialization.jsonObject(with: JSONEncoder.lifeOS.encode(category)) as? [String: Any]
        )
        let decoder = JSONDecoder.lifeOS
        decoder.userInfo[.lifeOSNow] = Date(timeIntervalSince1970: 1_754_660_000)

        for (key, value) in [("amountCents", 0), ("transactionCount", 0), ("fraction", 1.5)] as [(String, Any)] {
            var invalid = valid
            invalid[key] = value
            XCTAssertThrowsError(
                try decoder.decode(
                    FinanceCategoryObservation.self,
                    from: JSONSerialization.data(withJSONObject: invalid)
                ),
                "Expected malformed category \(key) to be rejected"
            )
        }

        var duplicateSources = valid
        duplicateSources["contributingSources"] = ["revolut_personal", "revolut_personal"]
        XCTAssertThrowsError(try decoder.decode(
            FinanceCategoryObservation.self,
            from: JSONSerialization.data(withJSONObject: duplicateSources)
        ))
    }

    func testUnavailableTransactionSnapshotRejectsAnEmptyObservedLookingLedger() throws {
        let payload: [String: Any] = [
            "availability": "unavailable",
            "transactions": [],
            "provenance": [
                "source": "no-authorized-finance-source",
                "observedAt": "2026-08-08T12:00:00.123Z",
                "freshness": "unknown",
                "quality": "unavailable",
                "connectorState": "unavailable"
            ]
        ]
        let decoder = JSONDecoder.lifeOS
        decoder.userInfo[.lifeOSNow] = ISO8601DateFormatter().date(from: "2026-08-08T12:05:00Z")!

        XCTAssertThrowsError(try decoder.decode(
            FinanceTransactionSnapshot.self,
            from: JSONSerialization.data(withJSONObject: payload)
        ))
    }

    private func fixtureTransactions() -> [FinanceTransactionObservation] {
        let observedAt = Date(timeIntervalSince1970: 1_754_659_800)
        let provenance = FinancePayloadProvenance(
            source: "revolut_personal",
            observedAt: observedAt,
            freshness: .fresh,
            quality: .observed,
            connectorState: .healthy
        )
        return [
            FinanceTransactionObservation(
                id: "salary-1", merchant: "Salary", title: "Monthly salary", signedAmountCents: 10_000,
                timestamp: observedAt, account: "Revolut Personal", source: "revolut_personal",
                category: "Income", provenance: provenance
            ),
            FinanceTransactionObservation(
                id: "food-1", merchant: "REWE", title: "Groceries", signedAmountCents: -2_500,
                timestamp: observedAt, account: "Revolut Personal", source: "revolut_personal",
                category: "Food", provenance: provenance
            ),
            FinanceTransactionObservation(
                id: "transport-1", merchant: "BVG", title: "Transit", signedAmountCents: -1_500,
                timestamp: observedAt, account: "Revolut Personal", source: "revolut_personal",
                category: "Transport", provenance: provenance
            ),
            FinanceTransactionObservation(
                id: "refund-1", merchant: "REWE", title: "Refund", signedAmountCents: 500,
                timestamp: observedAt, account: "Revolut Personal", source: "revolut_personal",
                category: "Food", provenance: provenance
            )
        ]
    }

    private func decodeSummary(
        monthlyIncome: Int?,
        fixedCosts: Int?,
        discretionaryBuffer: Int?,
        spent: Int?,
        savingsGoal: Int?,
        saved: Int?
    ) throws -> FinanceSummary {
        func metric(_ amount: Int?) -> [String: Any] {
            if let amount {
                return [
                    "availability": "observed",
                    "amountCents": amount,
                    "provenance": [
                        "source": "statement-import",
                        "observedAt": "2026-08-08T12:00:00.123Z",
                        "freshness": "fresh",
                        "quality": "observed",
                        "connectorState": "healthy"
                    ]
                ]
            }
            return [
                "availability": "unavailable",
                "provenance": [
                    "source": "no-authorized-finance-source",
                    "observedAt": "2026-08-08T12:00:00.123Z",
                    "freshness": "unknown",
                    "quality": "unavailable",
                    "connectorState": "unavailable"
                ]
            ]
        }

        let payload: [String: Any] = [
            "generatedAt": "2026-08-08T12:00:00.456Z",
            "currency": "EUR",
            "monthlyIncome": metric(monthlyIncome),
            "fixedCosts": metric(fixedCosts),
            "discretionaryBuffer": metric(discretionaryBuffer),
            "spent": metric(spent),
            "savingsGoal": metric(savingsGoal),
            "saved": metric(saved)
        ]
        let referenceNow = ISO8601DateFormatter().date(from: "2026-08-08T12:05:00Z")!
        return try FinanceSummary.decode(JSONSerialization.data(withJSONObject: payload), now: referenceNow)
    }
}
