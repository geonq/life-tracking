import XCTest
@testable import LifeOS

@available(iOS 17.0, macOS 14.0, *)
final class FinanceCoordinatorTests: XCTestCase {
    func testSuccessfulRefreshPublishesObservedSummary() async throws {
        let expected = try makeSummary()
        let coordinator = await MainActor.run {
            FinanceCoordinator(fetch: { expected })
        }

        await coordinator.refresh()

        let result = await MainActor.run { (coordinator.state, coordinator.summary, coordinator.errorMessage) }
        XCTAssertEqual(result.0, .observed)
        XCTAssertEqual(result.1, expected)
        XCTAssertNil(result.2)
    }

    func testFailurePreservesLastValidSummaryAsStale() async throws {
        let expected = try makeSummary()
        let coordinator = await MainActor.run {
            FinanceCoordinator(fetch: { throw URLError(.notConnectedToInternet) }, initialSummary: expected)
        }
        let before = await MainActor.run { coordinator.summary }

        await coordinator.refresh()

        let result = await MainActor.run { (coordinator.state, coordinator.summary, coordinator.errorMessage) }
        XCTAssertEqual(result.0, .stale)
        XCTAssertEqual(before, expected)
        XCTAssertEqual(result.1, expected)
        XCTAssertEqual(result.2, "Finance data unavailable")
    }

    func testCancellationWithoutObservationRemainsUnavailable() async throws {
        let gate = RefreshGate()
        let coordinator = await MainActor.run {
            FinanceCoordinator(fetch: {
                await gate.enter()
                do {
                    try await Task.sleep(nanoseconds: 200_000_000)
                } catch { }
                await gate.leave()
                return try! self.makeSummary()
            })
        }

        let refresh = Task { await coordinator.refresh() }
        while await gate.activeCount == 0 { await Task.yield() }
        await MainActor.run { coordinator.cancel() }
        await refresh.value

        let result = await MainActor.run { (coordinator.state, coordinator.summary) }
        XCTAssertEqual(result.0, .unavailable)
        XCTAssertNil(result.1)
    }

    func testLatestRefreshWinsAfterCancellingPreviousGeneration() async throws {
        let first = try makeSummary(spent: 10_000)
        let second = try makeSummary(spent: 20_000)
        let gate = RefreshGate()
        let coordinator = await MainActor.run {
            FinanceCoordinator(fetch: {
                await gate.enter()
                let call = await gate.callNumber
                do {
                    try await Task.sleep(nanoseconds: 200_000_000)
                } catch { }
                await gate.leave()
                return call == 1 ? first : second
            })
        }

        let firstRefresh = Task { await coordinator.refresh() }
        while await gate.activeCount == 0 { await Task.yield() }
        let secondRefresh = Task { await coordinator.refresh() }
        await firstRefresh.value
        await secondRefresh.value

        let result = await MainActor.run { (coordinator.state, coordinator.summary?.spentCents) }
        let maximum = await gate.maximum
        let activeCount = await gate.activeCount
        XCTAssertEqual(result.0, .observed)
        XCTAssertEqual(result.1, second.spentCents)
        XCTAssertEqual(maximum, 1)
        XCTAssertEqual(activeCount, 0)
    }

    func testObservedTransactionSnapshotCountsAsFinanceEvidence() async throws {
        let summary = try makeTransactionOnlySummary(observedAt: .now.addingTimeInterval(-1), freshness: "fresh", connector: "healthy")
        let coordinator = await MainActor.run {
            FinanceCoordinator(fetch: { summary })
        }

        await coordinator.refresh()

        let result = await MainActor.run { (coordinator.state, coordinator.summary?.transactions?.availability) }
        XCTAssertEqual(result.0, .observed)
        XCTAssertEqual(result.1, .observed)
    }

    @MainActor
    func testStaleTransactionSnapshotCountsAsStaleEvidence() throws {
        let summary = try makeTransactionOnlySummary(observedAt: .now.addingTimeInterval(-60 * 60), freshness: "stale", connector: "refresh_due")
        let coordinator = FinanceCoordinator(initialSummary: summary)

        XCTAssertEqual(coordinator.state, .stale)
    }

    private func makeSummary(
        generatedAt: Date = .now,
        observedAt: Date = .now.addingTimeInterval(-1),
        spent: Int = 45_000
    ) throws -> FinanceSummary {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let observed = formatter.string(from: observedAt)
        let metric: [String: Any] = [
            "availability": "observed",
            "amountCents": 100_000,
            "provenance": [
                "source": "test-observation",
                "observedAt": observed,
                "freshness": "fresh",
                "quality": "observed",
                "connectorState": "healthy"
            ]
        ]
        var spentMetric = metric
        spentMetric["amountCents"] = spent
        let payload: [String: Any] = [
            "generatedAt": formatter.string(from: generatedAt),
            "currency": "EUR",
            "monthlyIncome": metric,
            "fixedCosts": metric,
            "discretionaryBuffer": metric,
            "spent": spentMetric,
            "savingsGoal": metric,
            "saved": metric
        ]
        return try FinanceSummary.decode(JSONSerialization.data(withJSONObject: payload))
    }

    private func makeTransactionOnlySummary(
        observedAt: Date,
        freshness: String,
        connector: String
    ) throws -> FinanceSummary {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let generatedAt = formatter.string(from: .now)
        let observed = formatter.string(from: observedAt)
        let unavailableProvenance: [String: Any] = [
            "source": "no-authorized-finance-source", "observedAt": observed,
            "freshness": "unknown", "quality": "unavailable", "connectorState": "unavailable"
        ]
        let unavailable: [String: Any] = ["availability": "unavailable", "provenance": unavailableProvenance]
        let transactionProvenance: [String: Any] = [
            "source": "revolut_personal", "observedAt": observed,
            "freshness": freshness, "quality": "observed", "connectorState": connector
        ]
        let transaction: [String: Any] = [
            "id": "revolut-1", "merchant": "REWE", "title": "Groceries", "signedAmountCents": -2_450,
            "timestamp": observed, "account": "Revolut Personal", "source": "revolut_personal",
            "category": "Food", "provenance": transactionProvenance
        ]
        let payload: [String: Any] = [
            "generatedAt": generatedAt, "currency": "EUR",
            "monthlyIncome": unavailable, "fixedCosts": unavailable,
            "discretionaryBuffer": unavailable, "spent": unavailable,
            "savingsGoal": unavailable, "saved": unavailable,
            "transactions": [
                "availability": "observed", "transactions": [transaction], "provenance": transactionProvenance
            ]
        ]
        return try FinanceSummary.decode(JSONSerialization.data(withJSONObject: payload))
    }
}

private actor RefreshGate {
    private(set) var active = 0
    private(set) var maximum = 0
    private(set) var callNumber = 0

    var activeCount: Int { active }

    func enter() {
        active += 1
        callNumber += 1
        maximum = max(maximum, active)
    }

    func leave() {
        active -= 1
    }
}
