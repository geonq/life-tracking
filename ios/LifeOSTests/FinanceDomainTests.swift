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
        XCTAssertEqual(FinanceConnectorCatalog.defaults.map(\.kind), [.sparkasse, .paypal, .tradeRepublic])
        XCTAssertTrue(FinanceConnectorCatalog.defaults.allSatisfy { !$0.isEnabled })
        XCTAssertTrue(FinanceConnectorCatalog.defaults.allSatisfy(\.requiresExplicitOptIn))
        XCTAssertTrue(FinanceConnectorCatalog.defaults.allSatisfy { !$0.provider.isEmpty && !$0.recommendation.isEmpty })
        XCTAssertEqual(FinanceConnectorCatalog.defaults.first { $0.kind == .paypal }?.accessMethod, .officialOAuth)
        XCTAssertEqual(FinanceConnectorCatalog.defaults.first { $0.kind == .tradeRepublic }?.accessMethod, .regulatedProviderPending)
        XCTAssertEqual(FinanceConnectorCatalog.defaults.first { $0.kind == .tradeRepublic }?.risk, .experimentalOnly)
    }

    func testFinanceConnectorWireKeysMatchSharedAPIContract() throws {
        let data = Data("""
        {
          "id": "paypal",
          "displayName": "PayPal",
          "accessMethod": "official_oauth",
          "provider": "PayPal Transaction Search API",
          "enabled": false,
          "requiresExplicitOptIn": true,
          "risk": "account_eligibility_required",
          "recommendation": "Use official OAuth only; fall back to statement import if this account cannot access transaction history."
        }
        """.utf8)

        let descriptor = try JSONDecoder().decode(FinanceConnectorDescriptor.self, from: data)
        XCTAssertEqual(descriptor.kind, .paypal)
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
        XCTAssertEqual(catalog.connectors.map(\.kind), [.sparkasse, .paypal, .tradeRepublic])

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
