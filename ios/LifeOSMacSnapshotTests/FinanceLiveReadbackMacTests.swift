import Foundation
import XCTest
@testable import LifeOSMac

final class FinanceLiveReadbackMacTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    func testMalformedAndContradictoryMetadataFailsClosed() throws {
        let contradictory = try XCTUnwrap(HTTPURLResponse(
            url: URL(string: "https://lifeos.example/finance/summary")!,
            statusCode: 200,
            httpVersion: nil,
            headerFields: [
                "Content-Type": "application/json",
                "X-LifeOS-Banking-State": "healthy",
                "X-LifeOS-Banking-Partial": "true"
            ]
        ))
        XCTAssertThrowsError(try FinanceResponseMetadata(response: contradictory, bodySize: 128, now: now))

        let unknownState = try XCTUnwrap(HTTPURLResponse(
            url: URL(string: "https://lifeos.example/finance/summary")!,
            statusCode: 200,
            httpVersion: nil,
            headerFields: [
                "Content-Type": "application/json",
                "X-LifeOS-Banking-State": "maybe"
            ]
        ))
        XCTAssertThrowsError(try FinanceResponseMetadata(response: unknownState, bodySize: 128, now: now))

        XCTAssertThrowsError(try FinanceResponseMetadata(
            statusCode: 200,
            contentType: "text/plain",
            bodySize: 128,
            bankingState: nil,
            isPartial: nil,
            lastSuccessAt: nil,
            lastFailureAt: nil,
            now: now
        ))
    }

    func testPartialReadbackRetainsCoverageExclusionsAndRecurringBoundary() throws {
        let observedAt = now.addingTimeInterval(-60)
        let summary = try makeSummary(
            accountRows: [
                account(id: "checking", name: "Main", detail: "EUR checking", balanceCents: 12_345, observedAt: observedAt),
                unavailableAccount(id: "usd", name: "USD reserve", detail: "USD reserve", observedAt: observedAt)
            ],
            transactionRows: [transaction(id: "tx-1", source: "sparkasse_leipzig", observedAt: observedAt)]
        )
        let metadata = try response(state: .partial, isPartial: true)
        let readback = try FinanceReadback.make(summary: summary, response: metadata, now: now)

        XCTAssertEqual(readback.assessment.availability, .partial)
        XCTAssertTrue(readback.assessment.isPartial)
        XCTAssertEqual(readback.assessment.coverage.accountCount, 2)
        XCTAssertEqual(readback.assessment.coverage.observedAccountCount, 1)
        XCTAssertEqual(readback.assessment.coverage.unavailableAccountCount, 1)
        XCTAssertTrue(readback.assessment.exclusions.contains { $0.reason == .unsupportedCurrency })
        XCTAssertEqual(readback.assessment.recurringEligibility, .liveRowsRequireVersionedAccountIdentity)
    }

    func testExpiredConsentIsUnavailableAndCachedProjectionIsStale() throws {
        let observedAt = now.addingTimeInterval(-60)
        let summary = try makeSummary(
            accountRows: [account(id: "checking", name: "Main", detail: "EUR checking", balanceCents: 12_345, observedAt: observedAt)]
        )
        let readback = try FinanceReadback.make(
            summary: summary,
            response: try response(state: .consent, isPartial: false),
            now: now
        )

        XCTAssertEqual(readback.assessment.availability, .unavailable)
        XCTAssertTrue(readback.assessment.exclusions.contains { $0.reason == .consentRequired })

        let projection = FinanceBankCashProjection.project(
            summary: summary,
            readback: readback,
            now: now
        )
        XCTAssertEqual(projection.availability, .stale)
        XCTAssertEqual(projection.totalCents, 12_345)
        XCTAssertTrue(projection.exclusions.contains { $0.reason == .consentRequired })
    }

    func testStaleObservationIsExcludedFromCurrentProjection() throws {
        let observedAt = now.addingTimeInterval(-60 * 60)
        let summary = try makeSummary(
            accountRows: [
                account(
                    id: "checking",
                    name: "Main",
                    detail: "EUR checking",
                    balanceCents: 12_345,
                    observedAt: observedAt,
                    freshness: "stale",
                    connector: "refresh_due"
                )
            ],
            accountSnapshotFreshness: "stale",
            accountSnapshotConnector: "refresh_due"
        )
        let projection = FinanceBankCashProjection.project(summary: summary, now: now)

        XCTAssertEqual(projection.availability, .stale)
        XCTAssertNil(projection.totalCents)
        XCTAssertTrue(projection.exclusions.contains { $0.reason == .staleObservation })
    }

    func testFutureObservationIsExplicitlyExcludedFromReadbackAndProjection() throws {
        let future = now.addingTimeInterval(2)
        let summary = try makeSummary(
            accountRows: [account(id: "future", name: "Future", detail: "EUR checking", balanceCents: 12_345, observedAt: future)],
            accountSnapshotObservedAt: future
        )
        let readback = try FinanceReadback.make(summary: summary, response: try response(), now: now)
        let projection = FinanceBankCashProjection.project(summary: summary, readback: readback, now: now)

        XCTAssertEqual(readback.assessment.availability, .stale)
        XCTAssertEqual(readback.assessment.coverage.futureAccountCount, 1)
        XCTAssertTrue(readback.assessment.exclusions.contains { $0.reason == .futureObservation })
        XCTAssertEqual(projection.availability, .stale)
        XCTAssertNil(projection.totalCents)
        XCTAssertTrue(projection.exclusions.contains { $0.reason == .futureObservation })
    }

    func testDuplicateStableIdentityConflictDoesNotUseAccountLabels() throws {
        let observedAt = now.addingTimeInterval(-60)
        let summary = try makeSummary(
            accountRows: [
                account(id: "same-id", name: "Label A", detail: "EUR checking", balanceCents: 100, observedAt: observedAt),
                account(id: "same-id", name: "Label B", detail: "EUR checking", balanceCents: 200, observedAt: observedAt)
            ]
        )
        let projection = FinanceBankCashProjection.project(summary: summary, now: now)

        XCTAssertTrue(projection.includedAccounts.isEmpty)
        XCTAssertNil(projection.totalCents)
        XCTAssertEqual(projection.exclusions.filter { $0.reason == .conflictingIdentity }.count, 2)
    }

    func testRecognizedSourceAliasesCanonicalizeBeforeGrouping() throws {
        let observedAt = now.addingTimeInterval(-60)
        let summary = try makeSummary(
            accountRows: [
                account(
                    id: "same-account",
                    name: "Legacy alias",
                    detail: "EUR checking",
                    balanceCents: 1_000,
                    observedAt: observedAt,
                    source: "  SpArKaSsE_LeIpZiG  "
                ),
                account(
                    id: "same-account",
                    name: "Current alias",
                    detail: "EUR checking",
                    balanceCents: 1_000,
                    observedAt: observedAt,
                    source: " ENABLEBANKING:SPARKASSE_LEIPZIG "
                )
            ]
        )

        let projection = FinanceBankCashProjection.project(summary: summary, now: now)

        XCTAssertNil(projection.totalCents)
        XCTAssertTrue(projection.includedAccounts.isEmpty)
        XCTAssertEqual(
            projection.exclusions.filter { $0.reason == .duplicateIdentity }.count,
            2
        )
        XCTAssertEqual(
            Set(projection.exclusions.map(\.identity)),
            ["enablebanking:sparkasse_leipzig|same-account"]
        )

        let legacyOnly = try makeSummary(accountRows: [
            account(
                id: "legacy-only",
                name: "Legacy alias",
                detail: "EUR checking",
                balanceCents: 1_000,
                observedAt: observedAt,
                source: "  SPARKASSE_LEIPZIG  "
            )
        ])
        let included = FinanceBankCashProjection.project(summary: legacyOnly, now: now).includedAccounts

        XCTAssertEqual(included.first?.source, "enablebanking:sparkasse_leipzig")
        XCTAssertTrue(included.first?.verificationID.hasPrefix(
            "finance-account|enablebanking:sparkasse_leipzig|legacy-only|"
        ) == true)
    }

    func testConflictingRecognizedSourceAliasesAreExcludedWithoutDoubleCounting() throws {
        let observedAt = now.addingTimeInterval(-60)
        let summary = try makeSummary(
            accountRows: [
                account(
                    id: "same-account",
                    name: "Legacy alias",
                    detail: "EUR checking",
                    balanceCents: 1_000,
                    observedAt: observedAt,
                    source: "sparkasse_leipzig"
                ),
                account(
                    id: "same-account",
                    name: "Current alias",
                    detail: "EUR checking",
                    balanceCents: 2_000,
                    observedAt: observedAt,
                    source: "enablebanking:sparkasse_leipzig"
                )
            ]
        )

        let projection = FinanceBankCashProjection.project(summary: summary, now: now)

        XCTAssertNil(projection.totalCents)
        XCTAssertTrue(projection.includedAccounts.isEmpty)
        XCTAssertEqual(
            projection.exclusions.filter { $0.reason == .conflictingIdentity }.count,
            2
        )
    }

    func testExactNegativeCentsRemainSignedAndAreSummedWithoutFloatingPoint() throws {
        let observedAt = now.addingTimeInterval(-60)
        let summary = try makeSummary(
            accountRows: [
                account(id: "overdraft", name: "Overdraft", detail: "EUR current", balanceCents: -12_345, observedAt: observedAt),
                account(id: "reserve", name: "Reserve", detail: "EUR savings", balanceCents: 1_000, observedAt: observedAt)
            ]
        )
        let projection = FinanceBankCashProjection.project(summary: summary, now: now)

        XCTAssertEqual(projection.availability, .observed)
        XCTAssertEqual(projection.totalCents, -11_345)
        XCTAssertEqual(projection.includedAccounts.map(\.amount.amount.canonicalValue), ["-123.45", "10"])
    }

    func testSingleDigitCentRemaindersAreLeftPaddedAndReconcileWithTotal() throws {
        XCTAssertEqual(
            FinanceBankCashProjection.money(cents: 101)?.amount.canonicalValue,
            "1.01"
        )
        XCTAssertEqual(
            FinanceBankCashProjection.money(cents: -109)?.amount.canonicalValue,
            "-1.09"
        )

        let observedAt = now.addingTimeInterval(-60)
        let summary = try makeSummary(
            accountRows: [
                account(id: "positive", name: "Positive", detail: "EUR current", balanceCents: 101, observedAt: observedAt),
                account(id: "negative", name: "Negative", detail: "EUR current", balanceCents: -109, observedAt: observedAt)
            ]
        )
        let projection = FinanceBankCashProjection.project(summary: summary, now: now)

        XCTAssertEqual(projection.totalCents, -8)
        XCTAssertEqual(
            projection.includedAccounts.map(\.amount.amount.canonicalValue),
            ["-1.09", "1.01"]
        )
    }

    func testIntMinMoneyConversionReturnsNilWithoutNegationTrap() {
        XCTAssertNil(FinanceBankCashProjection.money(cents: Int.min))
        XCTAssertEqual(
            FinanceBankCashProjection.money(cents: -12_345)?.amount.canonicalValue,
            "-123.45"
        )
    }

    func testBankCashSourcePolicyAllowsOnlyCurrentAndEstablishedLegacyLabels() throws {
        let supportedSources = [
            "enablebanking:sparkasse_leipzig",
            "enablebanking:revolut_personal",
            "sparkasse_leipzig",
            "revolut_personal"
        ]
        for source in supportedSources {
            let summary = try makeSummary(accountRows: [
                account(
                    id: "supported-\(source)",
                    name: "Supported",
                    detail: "EUR current",
                    balanceCents: 101,
                    observedAt: now.addingTimeInterval(-60),
                    source: source
                )
            ])
            let projection = FinanceBankCashProjection.project(summary: summary, now: now)

            XCTAssertEqual(projection.totalCents, 101, source)
            XCTAssertEqual(projection.includedAccounts.count, 1, source)
            XCTAssertTrue(projection.exclusions.isEmpty, source)
        }

        let excludedSources = [
            ("unknown-bank", FinanceBankCashExclusionReason.unsupportedSource),
            ("manual", FinanceBankCashExclusionReason.nonLiveSource),
            ("enable-banking", FinanceBankCashExclusionReason.unsupportedSource),
            ("enablebanking", FinanceBankCashExclusionReason.unsupportedSource),
            ("revolut_business", FinanceBankCashExclusionReason.unsupportedSource),
            ("robinhood", FinanceBankCashExclusionReason.nonLiveSource),
            ("trade-republic", FinanceBankCashExclusionReason.nonLiveSource)
        ]
        for (source, reason) in excludedSources {
            let summary = try makeSummary(accountRows: [
                account(
                    id: "excluded-\(source)",
                    name: "Excluded",
                    detail: "EUR current",
                    balanceCents: 101,
                    observedAt: now.addingTimeInterval(-60),
                    source: source
                )
            ])
            let projection = FinanceBankCashProjection.project(summary: summary, now: now)

            XCTAssertNil(projection.totalCents, source)
            XCTAssertTrue(projection.includedAccounts.isEmpty, source)
            XCTAssertTrue(projection.exclusions.contains { $0.reason == reason }, source)
        }
    }

    func testTransactionActivityNeverBecomesBankCash() throws {
        let summary = try makeSummary(
            accountRows: nil,
            transactionRows: [transaction(id: "rh-1", source: "robinhood", observedAt: now.addingTimeInterval(-60))]
        )
        let projection = FinanceBankCashProjection.project(summary: summary, now: now)
        let readback = try FinanceReadback.make(summary: summary, response: try response(), now: now)

        XCTAssertNil(projection.totalCents)
        XCTAssertTrue(projection.includedAccounts.isEmpty)
        XCTAssertEqual(projection.availability, .unavailable)
        XCTAssertEqual(readback.assessment.recurringEligibility, .liveRowsRequireVersionedAccountIdentity)
    }

    func testReadbackIsPublishedAndWarmCacheFailureRemainsFailedAndStale() async throws {
        let summary = try makeSummary(
            accountRows: [account(id: "checking", name: "Main", detail: "EUR checking", balanceCents: 100, observedAt: now.addingTimeInterval(-60))]
        )
        let readback = try FinanceReadback.make(summary: summary, response: try response(), now: now)
        let client = FixtureReadbackClient(result: FinanceReadbackResult(summary: summary, readback: readback), failure: true)
        let coordinator = await MainActor.run {
            FinanceCoordinator(client: client, initialSummary: summary, initialReadback: readback)
        }

        await coordinator.refresh()

        let state = await MainActor.run {
            (coordinator.state, coordinator.observationState, coordinator.summary, coordinator.readback, coordinator.errorMessage)
        }
        XCTAssertEqual(state.0, .stale)
        XCTAssertEqual(state.1, .error)
        XCTAssertEqual(state.2, summary)
        XCTAssertEqual(state.3, readback)
        XCTAssertEqual(state.4, "Finance data unavailable")
    }

    @MainActor
    func testAgedInitialReadbackPublishesStaleStateAndObservation() throws {
        let summary = try makeSummary(
            accountRows: [account(
                id: "checking",
                name: "Main",
                detail: "EUR checking",
                balanceCents: 100,
                observedAt: now.addingTimeInterval(-60)
            )]
        )
        let readback = try FinanceReadback.make(summary: summary, response: try response(), now: now)
        let clock = FinanceReadbackTestClock(now: now.addingTimeInterval(15 * 60 + 1))
        let coordinator = FinanceCoordinator(
            fetch: { summary },
            initialSummary: summary,
            initialReadback: readback,
            clock: { clock.now }
        )

        XCTAssertEqual(coordinator.state, .stale)
        XCTAssertEqual(coordinator.observationState, .stale)
    }

    @MainActor
    func testInitialReadbackAgesSourceBeforeFreshEnvelope() throws {
        let sourceObservedAt = now.addingTimeInterval(-60)
        let summary = try makeSummary(
            accountRows: [account(
                id: "checking",
                name: "Main",
                detail: "EUR checking",
                balanceCents: 100,
                observedAt: sourceObservedAt
            )]
        )
        let readback = try FinanceReadback.make(summary: summary, response: try response(), now: now)
        let envelopeStillFresh = now.addingTimeInterval(15 * 60 - 50)
        let clock = FinanceReadbackTestClock(now: envelopeStillFresh)
        let coordinator = FinanceCoordinator(
            fetch: { summary },
            initialSummary: summary,
            initialReadback: readback,
            clock: { clock.now }
        )

        XCTAssertLessThan(envelopeStillFresh.timeIntervalSince(summary.generatedAt), 15 * 60)
        XCTAssertGreaterThanOrEqual(envelopeStillFresh.timeIntervalSince(sourceObservedAt), 15 * 60)
        XCTAssertEqual(coordinator.state, .stale)
        XCTAssertEqual(coordinator.observationState, .stale)
    }

    func testCancellationAgesSourceBeforeFreshEnvelope() async throws {
        let sourceObservedAt = now.addingTimeInterval(-60)
        let summary = try makeSummary(
            accountRows: [account(
                id: "checking",
                name: "Main",
                detail: "EUR checking",
                balanceCents: 100,
                observedAt: sourceObservedAt
            )]
        )
        let readback = try FinanceReadback.make(summary: summary, response: try response(), now: now)
        let clock = FinanceReadbackTestClock(now: now)
        let gate = RefreshStartGate()
        let coordinator = await MainActor.run {
            FinanceCoordinator(
                fetch: {
                    await gate.markStarted()
                    await gate.waitUntilReleased()
                    return summary
                },
                initialSummary: summary,
                initialReadback: readback,
                clock: { clock.now }
            )
        }

        let initial = await MainActor.run { (coordinator.state, coordinator.observationState) }
        XCTAssertEqual(initial.0, .observed)
        XCTAssertEqual(initial.1, .partial)

        let refresh = Task { await coordinator.refresh() }
        while !(await gate.started) { await Task.yield() }
        await MainActor.run {
            clock.now = now.addingTimeInterval(15 * 60 - 50)
            coordinator.cancel()
        }
        await gate.release()
        await refresh.value

        let final = await MainActor.run { (coordinator.state, coordinator.observationState) }
        XCTAssertLessThan(clock.now.timeIntervalSince(summary.generatedAt), 15 * 60)
        XCTAssertGreaterThanOrEqual(clock.now.timeIntervalSince(sourceObservedAt), 15 * 60)
        XCTAssertEqual(final.0, .stale)
        XCTAssertEqual(final.1, .stale)
    }

    @MainActor
    func testInitialTransactionReadbackAgesSourceBeforeFreshEnvelope() throws {
        let sourceObservedAt = now.addingTimeInterval(-60)
        let summary = try makeSummary(
            accountRows: nil,
            transactionRows: [transaction(
                id: "tx-1",
                source: "sparkasse_leipzig",
                observedAt: sourceObservedAt
            )]
        )
        let readback = try FinanceReadback.make(summary: summary, response: try response(), now: now)
        let envelopeStillFresh = now.addingTimeInterval(15 * 60 - 50)
        let clock = FinanceReadbackTestClock(now: envelopeStillFresh)
        let coordinator = FinanceCoordinator(
            fetch: { summary },
            initialSummary: summary,
            initialReadback: readback,
            clock: { clock.now }
        )

        XCTAssertLessThan(envelopeStillFresh.timeIntervalSince(summary.generatedAt), 15 * 60)
        XCTAssertGreaterThanOrEqual(envelopeStillFresh.timeIntervalSince(sourceObservedAt), 15 * 60)
        XCTAssertEqual(coordinator.state, .stale)
        XCTAssertEqual(coordinator.observationState, .stale)
    }

    func testCancellationAgesTransactionSourceBeforeFreshEnvelope() async throws {
        let sourceObservedAt = now.addingTimeInterval(-60)
        let summary = try makeSummary(
            accountRows: nil,
            transactionRows: [transaction(
                id: "tx-1",
                source: "sparkasse_leipzig",
                observedAt: sourceObservedAt
            )]
        )
        let readback = try FinanceReadback.make(summary: summary, response: try response(), now: now)
        let clock = FinanceReadbackTestClock(now: now)
        let gate = RefreshStartGate()
        let coordinator = await MainActor.run {
            FinanceCoordinator(
                fetch: {
                    await gate.markStarted()
                    await gate.waitUntilReleased()
                    return summary
                },
                initialSummary: summary,
                initialReadback: readback,
                clock: { clock.now }
            )
        }

        let initial = await MainActor.run { (coordinator.state, coordinator.observationState) }
        XCTAssertEqual(initial.0, .observed)
        XCTAssertEqual(initial.1, .partial)

        let refresh = Task { await coordinator.refresh() }
        while !(await gate.started) { await Task.yield() }
        await MainActor.run {
            clock.now = now.addingTimeInterval(15 * 60 - 50)
            coordinator.cancel()
        }
        await gate.release()
        await refresh.value

        let final = await MainActor.run { (coordinator.state, coordinator.observationState) }
        XCTAssertLessThan(clock.now.timeIntervalSince(summary.generatedAt), 15 * 60)
        XCTAssertGreaterThanOrEqual(clock.now.timeIntervalSince(sourceObservedAt), 15 * 60)
        XCTAssertEqual(final.0, .stale)
        XCTAssertEqual(final.1, .stale)
    }

    func testCancellationAfterReadbackFreshnessDeadlineDoesNotRestoreCachedPartialState() async throws {
        let summary = try makeSummary(
            accountRows: [account(
                id: "checking",
                name: "Main",
                detail: "EUR checking",
                balanceCents: 100,
                observedAt: now.addingTimeInterval(-60)
            )]
        )
        let readback = try FinanceReadback.make(summary: summary, response: try response(), now: now)
        let clock = FinanceReadbackTestClock(now: now)
        let gate = RefreshStartGate()
        let coordinator = await MainActor.run {
            FinanceCoordinator(
                fetch: {
                    await gate.markStarted()
                    await gate.waitUntilReleased()
                    return summary
                },
                initialSummary: summary,
                initialReadback: readback,
                clock: { clock.now }
            )
        }

        let initial = await MainActor.run { (coordinator.state, coordinator.observationState) }
        XCTAssertEqual(initial.0, .observed)
        XCTAssertEqual(initial.1, .partial)

        let refresh = Task { await coordinator.refresh() }
        while !(await gate.started) { await Task.yield() }
        await MainActor.run {
            clock.now = now.addingTimeInterval(15 * 60 + 1)
            coordinator.cancel()
        }
        await gate.release()
        await refresh.value

        let final = await MainActor.run { (coordinator.state, coordinator.observationState) }
        XCTAssertEqual(final.0, .stale)
        XCTAssertEqual(final.1, .stale)
    }

    func testCancellationDoesNotPublishAnUnfinishedReadback() async throws {
        let summary = try makeSummary(
            accountRows: [account(id: "checking", name: "Main", detail: "EUR checking", balanceCents: 100, observedAt: now.addingTimeInterval(-60))]
        )
        let gate = RefreshStartGate()
        let coordinator = await MainActor.run {
            FinanceCoordinator(fetch: {
                await gate.markStarted()
                try await Task.sleep(nanoseconds: 5_000_000_000)
                return summary
            })
        }

        let refresh = Task { await coordinator.refresh() }
        while !(await gate.started) { await Task.yield() }
        await MainActor.run { coordinator.cancel() }
        await refresh.value

        let state = await MainActor.run { (coordinator.state, coordinator.summary, coordinator.readback) }
        XCTAssertEqual(state.0, .unavailable)
        XCTAssertNil(state.1)
        XCTAssertNil(state.2)
    }

    func testCancellationPreservesConsentReadbackWithWarmCache() async throws {
        let summary = try makeSummary(
            accountRows: [account(
                id: "checking",
                name: "Main",
                detail: "EUR checking",
                balanceCents: 100,
                observedAt: now.addingTimeInterval(-60)
            )]
        )
        let consentReadback = try FinanceReadback.make(
            summary: summary,
            response: try response(state: .consent, isPartial: false),
            now: now
        )
        let gate = RefreshStartGate()
        let coordinator = await MainActor.run {
            FinanceCoordinator(
                fetch: {
                    await gate.markStarted()
                    await gate.waitUntilReleased()
                    return summary
                },
                initialSummary: summary,
                initialReadback: consentReadback
            )
        }

        let refresh = Task { await coordinator.refresh() }
        while !(await gate.started) { await Task.yield() }
        await MainActor.run { coordinator.cancel() }
        await gate.release()
        await refresh.value

        let state = await MainActor.run {
            (coordinator.state, coordinator.summary, coordinator.readback, coordinator.observationState, coordinator.errorMessage)
        }
        XCTAssertEqual(state.0, .stale)
        XCTAssertEqual(state.1, summary)
        XCTAssertEqual(state.2, consentReadback)
        XCTAssertEqual(state.3, .unavailable)
        XCTAssertNil(state.4)
    }

    func testCancellationAfterAppliedConsentReadbackPreservesUnavailableState() async throws {
        let summary = try makeSummary(
            accountRows: [account(
                id: "checking",
                name: "Main",
                detail: "EUR checking",
                balanceCents: 100,
                observedAt: now.addingTimeInterval(-60)
            )]
        )
        let consentReadback = try FinanceReadback.make(
            summary: summary,
            response: try response(state: .consent, isPartial: false),
            now: now
        )
        let gate = RefreshStartGate()
        let client = SequencedReadbackClient(result: FinanceReadbackResult(
            summary: summary,
            readback: consentReadback
        ), gate: gate)
        let coordinator = await MainActor.run {
            FinanceCoordinator(client: client)
        }

        await coordinator.refresh()

        let applied = await MainActor.run {
            (coordinator.state, coordinator.observationState, coordinator.errorMessage)
        }
        XCTAssertEqual(applied.0, .unavailable)
        XCTAssertEqual(applied.1, .unavailable)
        XCTAssertEqual(applied.2, "Finance data unavailable")

        let refresh = Task { await coordinator.refresh() }
        while !(await gate.started) { await Task.yield() }
        await MainActor.run { coordinator.cancel() }
        await gate.release()
        await refresh.value

        let cancelled = await MainActor.run {
            (coordinator.state, coordinator.observationState, coordinator.errorMessage)
        }
        XCTAssertEqual(cancelled.0, .stale)
        XCTAssertEqual(cancelled.1, .unavailable)
        XCTAssertNil(cancelled.2)
    }

    func testCancellationPreservesPublishedWarmCacheRefreshError() async throws {
        let summary = try makeSummary(
            accountRows: [account(
                id: "checking",
                name: "Main",
                detail: "EUR checking",
                balanceCents: 100,
                observedAt: now.addingTimeInterval(-60)
            )]
        )
        let readback = try FinanceReadback.make(summary: summary, response: try response(), now: now)
        let client = FixtureReadbackClient(
            result: FinanceReadbackResult(summary: summary, readback: readback),
            failure: true
        )
        let coordinator = await MainActor.run {
            FinanceCoordinator(client: client, initialSummary: summary, initialReadback: readback)
        }

        await coordinator.refresh()
        await MainActor.run { coordinator.cancel() }

        let state = await MainActor.run { (coordinator.state, coordinator.observationState, coordinator.errorMessage) }
        XCTAssertEqual(state.0, .stale)
        XCTAssertEqual(state.1, .error)
        XCTAssertEqual(state.2, "Finance data unavailable")
    }

    func testRetryCancellationPreservesLastSettledWarmCacheFailure() async throws {
        let summary = try makeSummary(
            accountRows: [account(
                id: "checking",
                name: "Main",
                detail: "EUR checking",
                balanceCents: 100,
                observedAt: now.addingTimeInterval(-60)
            )]
        )
        let readback = try FinanceReadback.make(summary: summary, response: try response(), now: now)
        let attempts = RefreshAttemptCounter()
        let gate = RefreshStartGate()
        let coordinator = await MainActor.run {
            FinanceCoordinator(
                fetch: {
                    switch await attempts.next() {
                    case 1:
                        throw FinanceLiveReadbackTestError.failed
                    default:
                        await gate.markStarted()
                        await gate.waitUntilReleased()
                        return summary
                    }
                },
                initialSummary: summary,
                initialReadback: readback
            )
        }

        await coordinator.refresh()
        let failedState = await MainActor.run {
            (coordinator.state, coordinator.observationState, coordinator.errorMessage)
        }
        XCTAssertEqual(failedState.0, .stale)
        XCTAssertEqual(failedState.1, .error)
        XCTAssertEqual(failedState.2, "Finance data unavailable")

        let retry = Task { await coordinator.retry() }
        while !(await gate.started) { await Task.yield() }
        await MainActor.run { coordinator.cancel() }
        await gate.release()
        await retry.value

        let state = await MainActor.run {
            (coordinator.state, coordinator.observationState, coordinator.summary,
             coordinator.readback, coordinator.errorMessage)
        }
        XCTAssertEqual(state.0, .stale)
        XCTAssertEqual(state.1, .error)
        XCTAssertEqual(state.2, summary)
        XCTAssertEqual(state.3, readback)
        XCTAssertEqual(state.4, "Finance data unavailable")
    }

    private func response(
        state: FinanceBankingState? = .healthy,
        isPartial: Bool? = false
    ) throws -> FinanceResponseMetadata {
        try FinanceResponseMetadata(
            statusCode: 200,
            contentType: "application/json; charset=utf-8",
            bodySize: 256,
            bankingState: state,
            isPartial: isPartial,
            lastSuccessAt: state == .healthy ? now.addingTimeInterval(-60) : nil,
            lastFailureAt: state == .consent ? now.addingTimeInterval(-1) : nil,
            now: now
        )
    }

    private func makeSummary(
        accountRows: [[String: Any]]?,
        accountSnapshotFreshness: String = "fresh",
        accountSnapshotConnector: String = "healthy",
        accountSnapshotObservedAt: Date? = nil,
        transactionRows: [[String: Any]]? = nil
    ) throws -> FinanceSummary {
        let unavailableProvenance: [String: Any] = [
            "source": "no-authorized-finance-source",
            "observedAt": iso(now.addingTimeInterval(-60)),
            "freshness": "unknown",
            "quality": "unavailable",
            "connectorState": "unavailable"
        ]
        let unavailable: [String: Any] = [
            "availability": "unavailable",
            "provenance": unavailableProvenance
        ]
        var payload: [String: Any] = [
            "generatedAt": iso(now),
            "currency": "EUR",
            "monthlyIncome": unavailable,
            "fixedCosts": unavailable,
            "discretionaryBuffer": unavailable,
            "spent": unavailable,
            "savingsGoal": unavailable,
            "saved": unavailable
        ]

        if let accountRows {
            let source = (accountRows.first?["source"] as? String) ?? "sparkasse_leipzig"
            let normalizedSources = Set(accountRows.compactMap { row in
                (row["source"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            })
            let snapshotSource = normalizedSources.count > 1
                ? "derived-account-snapshot"
                : source
            payload["accounts"] = [
                "availability": "observed",
                "accounts": accountRows,
                "provenance": [
                    "source": snapshotSource,
                    "observedAt": iso(accountSnapshotObservedAt ?? now.addingTimeInterval(-30)),
                    "freshness": accountSnapshotFreshness,
                    "quality": "observed",
                    "connectorState": accountSnapshotConnector
                ]
            ]
        }
        if let transactionRows {
            let source = (transactionRows.first?["source"] as? String) ?? "sparkasse_leipzig"
            payload["transactions"] = [
                "availability": "observed",
                "transactions": transactionRows,
                "provenance": [
                    "source": source,
                    "observedAt": iso(now.addingTimeInterval(-30)),
                    "freshness": "fresh",
                    "quality": "observed",
                    "connectorState": "healthy"
                ]
            ]
        }
        return try FinanceSummary.decode(JSONSerialization.data(withJSONObject: payload), now: now)
    }

    private func account(
        id: String,
        name: String,
        detail: String,
        balanceCents: Int,
        observedAt: Date,
        source: String = "sparkasse_leipzig",
        freshness: String = "fresh",
        connector: String = "healthy"
    ) -> [String: Any] {
        [
            "availability": "observed",
            "id": id,
            "name": name,
            "detail": detail,
            "balanceCents": balanceCents,
            "source": source,
            "provenance": [
                "source": source,
                "observedAt": iso(observedAt),
                "freshness": freshness,
                "quality": "observed",
                "connectorState": connector
            ]
        ]
    }

    private func unavailableAccount(
        id: String,
        name: String,
        detail: String,
        observedAt: Date,
        source: String = "sparkasse_leipzig"
    ) -> [String: Any] {
        [
            "availability": "unavailable",
            "id": id,
            "name": name,
            "detail": detail,
            "source": source,
            "provenance": [
                "source": source,
                "observedAt": iso(observedAt),
                "freshness": "unknown",
                "quality": "unavailable",
                "connectorState": "unavailable"
            ]
        ]
    }

    private func transaction(id: String, source: String, observedAt: Date) -> [String: Any] {
        [
            "id": id,
            "merchant": "Example",
            "title": "Example transaction",
            "signedAmountCents": -250,
            "timestamp": iso(observedAt),
            "account": "Account",
            "source": source,
            "category": "Other",
            "provenance": [
                "source": source,
                "observedAt": iso(observedAt),
                "freshness": "fresh",
                "quality": "observed",
                "connectorState": "healthy"
            ]
        ]
    }

    private func iso(_ date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.string(from: date)
    }
}

private enum FinanceLiveReadbackTestError: Error, Sendable {
    case failed
}

private struct FixtureReadbackClient: FinanceSummaryFetching, FinanceReadbackFetching, Sendable {
    let result: FinanceReadbackResult
    let failure: Bool

    func fetchFinanceSummary() async throws -> FinanceSummary {
        result.summary
    }

    func fetchFinanceReadback() async throws -> FinanceReadbackResult {
        if failure { throw FinanceLiveReadbackTestError.failed }
        return result
    }
}

private final class FinanceReadbackTestClock: @unchecked Sendable {
    var now: Date

    init(now: Date) {
        self.now = now
    }
}

private actor SequencedReadbackClient: FinanceSummaryFetching, FinanceReadbackFetching {
    let result: FinanceReadbackResult
    let gate: RefreshStartGate
    private var readbackCount = 0

    init(result: FinanceReadbackResult, gate: RefreshStartGate) {
        self.result = result
        self.gate = gate
    }

    func fetchFinanceSummary() async throws -> FinanceSummary {
        result.summary
    }

    func fetchFinanceReadback() async throws -> FinanceReadbackResult {
        readbackCount += 1
        if readbackCount > 1 {
            await gate.markStarted()
            await gate.waitUntilReleased()
        }
        return result
    }
}

private actor RefreshStartGate {
    private(set) var started = false
    private var released = false
    private var releaseContinuation: CheckedContinuation<Void, Never>?

    func markStarted() {
        started = true
    }

    func waitUntilReleased() async {
        guard !released else { return }
        await withCheckedContinuation { continuation in
            releaseContinuation = continuation
        }
    }

    func release() {
        released = true
        releaseContinuation?.resume()
        releaseContinuation = nil
    }
}

private actor RefreshAttemptCounter {
    private var count = 0

    func next() -> Int {
        count += 1
        return count
    }
}
