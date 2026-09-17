import XCTest
@testable import LifeOSMac

private actor FinanceRecurringRefreshCancellationProbe {
    private var firstInvocation = true
    private var didStart = false
    private var wasCancelled = false
    private var continuation: CheckedContinuation<Void, Never>?

    func blockFirstComputationUntilCancelled() async {
        guard firstInvocation else { return }
        firstInvocation = false
        didStart = true
        await withTaskCancellationHandler(operation: {
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                Task { self.install(continuation) }
            }
        }, onCancel: {
            Task { await self.release() }
        })
    }

    func started() -> Bool { didStart }
    func cancelled() -> Bool { wasCancelled }

    private func install(_ continuation: CheckedContinuation<Void, Never>) {
        if wasCancelled {
            continuation.resume()
        } else {
            self.continuation = continuation
        }
    }

    private func release() {
        wasCancelled = true
        continuation?.resume()
        continuation = nil
    }
}

@MainActor
final class FinanceRecurringPaymentsViewModelMacTests: XCTestCase {
    func testRefreshAndManagePaymentPersistOnlyTheLocalOverride() async throws {
        let url = FinanceRecurringTestFixtures.temporaryURL("view-model")
        defer { try? FileManager.default.removeItem(at: url) }

        let transactions = try [
            FinanceRecurringTestFixtures.transaction(date: try FinanceRecurringTestFixtures.date(2026, 1, 31)),
            FinanceRecurringTestFixtures.transaction(date: try FinanceRecurringTestFixtures.date(2026, 2, 28)),
            FinanceRecurringTestFixtures.transaction(date: try FinanceRecurringTestFixtures.date(2026, 3, 31)),
            FinanceRecurringTestFixtures.transaction(date: try FinanceRecurringTestFixtures.date(2026, 4, 30))
        ]
        let batches = [try FinanceRecurringTestFixtures.batch(for: transactions)]
        let store = try FinanceRecurringPaymentStore(url: url)
        let viewModel = FinanceRecurringPaymentsViewModel(store: store)

        viewModel.refresh(transactions: transactions, batches: batches)
        for _ in 0..<500 where viewModel.isRefreshing {
            try await Task.sleep(nanoseconds: 1_000_000)
        }

        XCTAssertFalse(viewModel.isRefreshing)
        XCTAssertNil(viewModel.errorMessage)
        let row = try XCTUnwrap(viewModel.rows.first)
        XCTAssertEqual(row.cadence, .monthly)
        XCTAssertTrue(viewModel.hasManagedRow(for: transactions[0].id))

        viewModel.save(
            row: row,
            cadence: .monthly,
            status: .paused,
            anchorDate: row.anchor?.date
        )
        XCTAssertEqual(viewModel.rows.first?.status, .paused)
        XCTAssertEqual(try store.load().overrides.first?.status, .paused)

        viewModel.resetAutomatic(for: try XCTUnwrap(viewModel.rows.first))
        XCTAssertEqual(viewModel.rows.first?.status, .active)
        XCTAssertTrue(try store.load().overrides.isEmpty)
    }

    func testPresentationUsesTheFollowingPeriodForEarlyMonthlyPayments() async throws {
        let url = FinanceRecurringTestFixtures.temporaryURL("early-monthly-row")
        defer { try? FileManager.default.removeItem(at: url) }
        let transactions = try [
            FinanceRecurringTestFixtures.transaction(date: try FinanceRecurringTestFixtures.date(2026, 1, 31)),
            FinanceRecurringTestFixtures.transaction(date: try FinanceRecurringTestFixtures.date(2026, 2, 27)),
            FinanceRecurringTestFixtures.transaction(date: try FinanceRecurringTestFixtures.date(2026, 3, 30)),
            FinanceRecurringTestFixtures.transaction(date: try FinanceRecurringTestFixtures.date(2026, 4, 29))
        ]
        let viewModel = FinanceRecurringPaymentsViewModel(
            store: try FinanceRecurringPaymentStore(url: url)
        )
        viewModel.refresh(transactions: transactions, batches: [try FinanceRecurringTestFixtures.batch(for: transactions)])
        try await waitForRefresh(viewModel)

        let row = try XCTUnwrap(viewModel.rows.first)
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try XCTUnwrap(TimeZone(identifier: "Europe/Berlin"))
        let predicted = try XCTUnwrap(row.predictedDate)
        XCTAssertEqual(calendar.component(.month, from: predicted), 5)
        XCTAssertEqual(calendar.component(.day, from: predicted), 31)
    }

    func testChangedMonthlyAnchorUsesTheFollowingOverridePeriod() async throws {
        let url = FinanceRecurringTestFixtures.temporaryURL("changed-monthly-anchor")
        defer { try? FileManager.default.removeItem(at: url) }
        let transactions = try [
            FinanceRecurringTestFixtures.transaction(date: try FinanceRecurringTestFixtures.date(2026, 1, 31)),
            FinanceRecurringTestFixtures.transaction(date: try FinanceRecurringTestFixtures.date(2026, 2, 27)),
            FinanceRecurringTestFixtures.transaction(date: try FinanceRecurringTestFixtures.date(2026, 3, 30)),
            FinanceRecurringTestFixtures.transaction(date: try FinanceRecurringTestFixtures.date(2026, 4, 29))
        ]
        let viewModel = FinanceRecurringPaymentsViewModel(store: try FinanceRecurringPaymentStore(url: url))
        viewModel.refresh(transactions: transactions, batches: [try FinanceRecurringTestFixtures.batch(for: transactions)])
        try await waitForRefresh(viewModel)

        let row = try XCTUnwrap(viewModel.rows.first)
        XCTAssertTrue(viewModel.save(
            row: row,
            cadence: .monthly,
            status: .active,
            anchorDate: try FinanceRecurringTestFixtures.date(2025, 12, 31)
        ))

        let predicted = try XCTUnwrap(viewModel.rows.first?.predictedDate)
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try XCTUnwrap(TimeZone(identifier: "Europe/Berlin"))
        XCTAssertEqual(calendar.component(.month, from: predicted), 5)
        XCTAssertEqual(calendar.component(.day, from: predicted), 31)
        XCTAssertGreaterThan(predicted, transactions.last!.bookedAt)
    }

    func testManualOverrideCannotPredictBeforeLaterEligibleEvidence() async throws {
        let url = FinanceRecurringTestFixtures.temporaryURL("manual-latest-boundary")
        defer { try? FileManager.default.removeItem(at: url) }
        let transactions = try [
            FinanceRecurringTestFixtures.transaction(date: try FinanceRecurringTestFixtures.date(2026, 1, 31)),
            FinanceRecurringTestFixtures.transaction(date: try FinanceRecurringTestFixtures.date(2026, 2, 28)),
            FinanceRecurringTestFixtures.transaction(date: try FinanceRecurringTestFixtures.date(2026, 3, 31)),
            FinanceRecurringTestFixtures.transaction(date: try FinanceRecurringTestFixtures.date(2026, 4, 30)),
            FinanceRecurringTestFixtures.transaction(date: try FinanceRecurringTestFixtures.date(2026, 6, 15))
        ]
        let viewModel = FinanceRecurringPaymentsViewModel(store: try FinanceRecurringPaymentStore(url: url))
        viewModel.refresh(
            transactions: transactions,
            batches: [try FinanceRecurringTestFixtures.batch(for: transactions)]
        )
        try await waitForRefresh(viewModel)

        let row = try XCTUnwrap(viewModel.rows.first)
        XCTAssertEqual(row.candidate?.latestEligiblePaymentDate, transactions.last?.bookedAt)
        XCTAssertNil(row.predictedDate)
        XCTAssertTrue(viewModel.save(
            row: row,
            cadence: .monthly,
            status: .active,
            anchorDate: try FinanceRecurringTestFixtures.date(2026, 1, 31)
        ))
        XCTAssertNil(viewModel.rows.first?.predictedDate)
    }

    func testAutomaticActivePreservesDriftSuppressionAcrossPauseAndResume() async throws {
        let url = FinanceRecurringTestFixtures.temporaryURL("automatic-drift")
        defer { try? FileManager.default.removeItem(at: url) }
        let transactions = try [
            FinanceRecurringTestFixtures.transaction(date: try FinanceRecurringTestFixtures.date(2026, 1, 1)),
            FinanceRecurringTestFixtures.transaction(date: try FinanceRecurringTestFixtures.date(2026, 1, 9)),
            FinanceRecurringTestFixtures.transaction(date: try FinanceRecurringTestFixtures.date(2026, 1, 17)),
            FinanceRecurringTestFixtures.transaction(date: try FinanceRecurringTestFixtures.date(2026, 1, 25))
        ]
        let viewModel = FinanceRecurringPaymentsViewModel(store: try FinanceRecurringPaymentStore(url: url))
        viewModel.refresh(
            transactions: transactions,
            batches: [try FinanceRecurringTestFixtures.batch(for: transactions)]
        )
        try await waitForRefresh(viewModel)

        var row = try XCTUnwrap(viewModel.rows.first)
        XCTAssertEqual(row.candidate?.detectedCadence, .weekly)
        XCTAssertTrue(row.candidate?.reasonCodes.contains(.scheduleDrift) == true)
        XCTAssertNil(row.candidate?.predictedDate)
        XCTAssertNil(row.predictedDate)

        XCTAssertTrue(viewModel.save(row: row, cadence: nil, status: .active, anchorDate: nil))
        row = try XCTUnwrap(viewModel.rows.first)
        XCTAssertEqual(row.override?.cadence, nil)
        XCTAssertEqual(row.status, .active)
        XCTAssertNil(row.predictedDate)

        XCTAssertTrue(viewModel.save(row: row, cadence: nil, status: .paused, anchorDate: nil))
        row = try XCTUnwrap(viewModel.rows.first)
        XCTAssertEqual(row.status, .paused)
        XCTAssertNil(row.predictedDate)

        XCTAssertTrue(viewModel.save(row: row, cadence: nil, status: .active, anchorDate: nil))
        XCTAssertEqual(viewModel.rows.first?.status, .active)
        XCTAssertNil(viewModel.rows.first?.predictedDate)
    }

    func testChangedYearlyAnchorUsesTheFollowingOverridePeriod() async throws {
        let url = FinanceRecurringTestFixtures.temporaryURL("changed-yearly-anchor")
        defer { try? FileManager.default.removeItem(at: url) }
        let transactions = try [
            FinanceRecurringTestFixtures.transaction(date: try FinanceRecurringTestFixtures.date(2024, 1, 31)),
            FinanceRecurringTestFixtures.transaction(date: try FinanceRecurringTestFixtures.date(2025, 1, 30)),
            FinanceRecurringTestFixtures.transaction(date: try FinanceRecurringTestFixtures.date(2026, 1, 29)),
            FinanceRecurringTestFixtures.transaction(date: try FinanceRecurringTestFixtures.date(2027, 1, 28))
        ]
        let viewModel = FinanceRecurringPaymentsViewModel(store: try FinanceRecurringPaymentStore(url: url))
        viewModel.refresh(transactions: transactions, batches: [try FinanceRecurringTestFixtures.batch(for: transactions)])
        try await waitForRefresh(viewModel)

        let row = try XCTUnwrap(viewModel.rows.first)
        XCTAssertTrue(viewModel.save(
            row: row,
            cadence: .yearly,
            status: .active,
            anchorDate: try FinanceRecurringTestFixtures.date(2023, 1, 31)
        ))

        let predicted = try XCTUnwrap(viewModel.rows.first?.predictedDate)
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try XCTUnwrap(TimeZone(identifier: "Europe/Berlin"))
        XCTAssertEqual(calendar.component(.year, from: predicted), 2028)
        XCTAssertEqual(calendar.component(.month, from: predicted), 1)
        XCTAssertEqual(calendar.component(.day, from: predicted), 31)
        XCTAssertGreaterThan(predicted, transactions.last!.bookedAt)
    }

    func testChangedWeeklyAnchorUsesTheFollowingOverridePeriod() async throws {
        let url = FinanceRecurringTestFixtures.temporaryURL("changed-weekly-anchor")
        defer { try? FileManager.default.removeItem(at: url) }
        let transactions = try [
            FinanceRecurringTestFixtures.transaction(date: try FinanceRecurringTestFixtures.date(2026, 1, 6)),
            FinanceRecurringTestFixtures.transaction(date: try FinanceRecurringTestFixtures.date(2026, 1, 13)),
            FinanceRecurringTestFixtures.transaction(date: try FinanceRecurringTestFixtures.date(2026, 1, 20)),
            FinanceRecurringTestFixtures.transaction(date: try FinanceRecurringTestFixtures.date(2026, 1, 27))
        ]
        let viewModel = FinanceRecurringPaymentsViewModel(store: try FinanceRecurringPaymentStore(url: url))
        viewModel.refresh(transactions: transactions, batches: [try FinanceRecurringTestFixtures.batch(for: transactions)])
        try await waitForRefresh(viewModel)

        let row = try XCTUnwrap(viewModel.rows.first)
        XCTAssertTrue(viewModel.save(
            row: row,
            cadence: .weekly,
            status: .active,
            anchorDate: try FinanceRecurringTestFixtures.date(2025, 12, 30)
        ))

        let predicted = try XCTUnwrap(viewModel.rows.first?.predictedDate)
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try XCTUnwrap(TimeZone(identifier: "Europe/Berlin"))
        XCTAssertEqual(calendar.component(.month, from: predicted), 2)
        XCTAssertEqual(calendar.component(.day, from: predicted), 3)
        XCTAssertGreaterThan(predicted, transactions.last!.bookedAt)
    }

    func testOverrideRemainsVisibleAfterEvidenceDisappearsAndAcrossRestart() async throws {
        let url = FinanceRecurringTestFixtures.temporaryURL("override-union")
        defer { try? FileManager.default.removeItem(at: url) }
        let transactions = try [
            FinanceRecurringTestFixtures.transaction(date: try FinanceRecurringTestFixtures.date(2026, 1, 6)),
            FinanceRecurringTestFixtures.transaction(date: try FinanceRecurringTestFixtures.date(2026, 1, 13)),
            FinanceRecurringTestFixtures.transaction(date: try FinanceRecurringTestFixtures.date(2026, 1, 20)),
            FinanceRecurringTestFixtures.transaction(date: try FinanceRecurringTestFixtures.date(2026, 1, 27))
        ]
        let batches = [try FinanceRecurringTestFixtures.batch(for: transactions)]
        let store = try FinanceRecurringPaymentStore(url: url)
        let viewModel = FinanceRecurringPaymentsViewModel(store: store)

        viewModel.refresh(transactions: transactions, batches: batches)
        try await waitForRefresh(viewModel)
        let detected = try XCTUnwrap(viewModel.rows.first)
        XCTAssertTrue(viewModel.save(row: detected, cadence: .weekly, status: .paused, anchorDate: detected.anchor?.date))

        viewModel.refresh(transactions: [], batches: [])
        try await waitForRefresh(viewModel)
        let missing = try XCTUnwrap(viewModel.rows.first)
        XCTAssertEqual(missing.override?.status, .paused)
        XCTAssertEqual(missing.override?.cadence, .weekly)
        XCTAssertTrue(missing.evidence.isEmpty)

        let reopened = FinanceRecurringPaymentsViewModel(store: try FinanceRecurringPaymentStore(url: url))
        reopened.refresh(transactions: [], batches: [])
        try await waitForRefresh(reopened)
        XCTAssertEqual(reopened.rows.first?.id, missing.id)
        XCTAssertTrue(reopened.rows.first?.evidence.isEmpty == true)
        XCTAssertEqual(reopened.rows.first?.override?.status, .paused)
    }

    func testSaveFailureKeepsManageDraftOpenAndReportsTheDurableError() async throws {
        let url = FinanceRecurringTestFixtures.temporaryURL("save-failure")
        defer { try? FileManager.default.removeItem(at: url) }
        let transactions = try [
            FinanceRecurringTestFixtures.transaction(date: try FinanceRecurringTestFixtures.date(2026, 1, 6)),
            FinanceRecurringTestFixtures.transaction(date: try FinanceRecurringTestFixtures.date(2026, 1, 13)),
            FinanceRecurringTestFixtures.transaction(date: try FinanceRecurringTestFixtures.date(2026, 1, 20)),
            FinanceRecurringTestFixtures.transaction(date: try FinanceRecurringTestFixtures.date(2026, 1, 27))
        ]
        let store = try FinanceRecurringPaymentStore(url: url)
        let viewModel = FinanceRecurringPaymentsViewModel(store: store)
        viewModel.refresh(transactions: transactions, batches: [try FinanceRecurringTestFixtures.batch(for: transactions)])
        try await waitForRefresh(viewModel)
        let row = try XCTUnwrap(viewModel.rows.first)
        viewModel.beginManage(for: row)

        let current = try store.load()
        _ = try store.saveOverride(
            try FinanceRecurringPaymentOverride(key: row.key, status: .ignored),
            expectedRevision: current.revision
        )

        XCTAssertFalse(viewModel.save(row: row, cadence: .monthly, status: .active, anchorDate: row.anchor?.date))
        XCTAssertNotNil(viewModel.editingRow)
        XCTAssertEqual(viewModel.editingOwner, .recurringCard)
        XCTAssertNotNil(viewModel.errorMessage)

        viewModel.beginManage(transactionID: transactions[0].id)
        XCTAssertEqual(viewModel.editingOwner, .importedTransactions)
        XCTAssertFalse(viewModel.save(row: row, cadence: .monthly, status: .active, anchorDate: row.anchor?.date))
        XCTAssertNotNil(viewModel.editingRow)
        XCTAssertEqual(viewModel.editingOwner, .importedTransactions)
    }

    func testManagePaymentRouteHasExactlyOneActiveSheetOwner() async throws {
        let url = FinanceRecurringTestFixtures.temporaryURL("sheet-owner")
        defer { try? FileManager.default.removeItem(at: url) }
        let transactions = try [
            FinanceRecurringTestFixtures.transaction(date: try FinanceRecurringTestFixtures.date(2026, 1, 6)),
            FinanceRecurringTestFixtures.transaction(date: try FinanceRecurringTestFixtures.date(2026, 1, 13)),
            FinanceRecurringTestFixtures.transaction(date: try FinanceRecurringTestFixtures.date(2026, 1, 20)),
            FinanceRecurringTestFixtures.transaction(date: try FinanceRecurringTestFixtures.date(2026, 1, 27))
        ]
        let viewModel = FinanceRecurringPaymentsViewModel(store: try FinanceRecurringPaymentStore(url: url))
        viewModel.refresh(transactions: transactions, batches: [try FinanceRecurringTestFixtures.batch(for: transactions)])
        try await waitForRefresh(viewModel)
        let row = try XCTUnwrap(viewModel.rows.first)

        viewModel.beginManage(for: row)
        XCTAssertTrue(viewModel.shouldPresentEditor(for: .recurringCard))
        XCTAssertFalse(viewModel.shouldPresentEditor(for: .importedTransactions))
        XCTAssertNotNil(viewModel.editorBinding(for: .recurringCard).wrappedValue)
        XCTAssertNil(viewModel.editorBinding(for: .importedTransactions).wrappedValue)

        viewModel.dismissManage(owner: .importedTransactions)
        XCTAssertEqual(viewModel.editingOwner, .recurringCard)
        viewModel.dismissManage(owner: .recurringCard)
        XCTAssertNil(viewModel.editingRow)

        viewModel.beginManage(transactionID: transactions[0].id)
        XCTAssertTrue(viewModel.shouldPresentEditor(for: .importedTransactions))
        XCTAssertFalse(viewModel.shouldPresentEditor(for: .recurringCard))
        XCTAssertNil(viewModel.editorBinding(for: .recurringCard).wrappedValue)
        XCTAssertNotNil(viewModel.editorBinding(for: .importedTransactions).wrappedValue)
        viewModel.dismissManage(owner: .importedTransactions)
        XCTAssertNil(viewModel.editingRow)
    }

    func testWarmSnapshotFailureClearsCurrentEvidenceAndKeepsOverrideStale() async throws {
        let url = FinanceRecurringTestFixtures.temporaryURL("warm-snapshot-failure")
        defer { try? FileManager.default.removeItem(at: url) }
        let transactions = try [
            FinanceRecurringTestFixtures.transaction(date: try FinanceRecurringTestFixtures.date(2026, 1, 6)),
            FinanceRecurringTestFixtures.transaction(date: try FinanceRecurringTestFixtures.date(2026, 1, 13)),
            FinanceRecurringTestFixtures.transaction(date: try FinanceRecurringTestFixtures.date(2026, 1, 20)),
            FinanceRecurringTestFixtures.transaction(date: try FinanceRecurringTestFixtures.date(2026, 1, 27))
        ]
        let store = try FinanceRecurringPaymentStore(url: url)
        let viewModel = FinanceRecurringPaymentsViewModel(store: store)
        viewModel.refresh(transactions: transactions, batches: [try FinanceRecurringTestFixtures.batch(for: transactions)])
        try await waitForRefresh(viewModel)
        let detected = try XCTUnwrap(viewModel.rows.first)
        XCTAssertTrue(viewModel.save(row: detected, cadence: .weekly, status: .paused, anchorDate: detected.anchor?.date))
        XCTAssertNotNil(viewModel.assessment)
        XCTAssertFalse(viewModel.rows.first?.evidence.isEmpty == true)

        viewModel.presentSnapshotReadError(FinanceRecurringPaymentStoreError.readFailed)

        XCTAssertNil(viewModel.assessment)
        XCTAssertTrue(viewModel.isStale)
        let stale = try XCTUnwrap(viewModel.rows.first)
        XCTAssertTrue(stale.isStale)
        XCTAssertTrue(stale.evidence.isEmpty)
        XCTAssertEqual(stale.override?.status, .paused)
        XCTAssertEqual(stale.override?.cadence, .weekly)
    }

    func testColdSnapshotFailureShowsPersistedOverrideWithoutCurrentEvidence() async throws {
        let url = FinanceRecurringTestFixtures.temporaryURL("cold-snapshot-failure")
        defer { try? FileManager.default.removeItem(at: url) }
        let transactions = try [
            FinanceRecurringTestFixtures.transaction(date: try FinanceRecurringTestFixtures.date(2026, 1, 6)),
            FinanceRecurringTestFixtures.transaction(date: try FinanceRecurringTestFixtures.date(2026, 1, 13)),
            FinanceRecurringTestFixtures.transaction(date: try FinanceRecurringTestFixtures.date(2026, 1, 20)),
            FinanceRecurringTestFixtures.transaction(date: try FinanceRecurringTestFixtures.date(2026, 1, 27))
        ]
        let store = try FinanceRecurringPaymentStore(url: url)
        let seed = FinanceRecurringPaymentsViewModel(store: store)
        seed.refresh(transactions: transactions, batches: [try FinanceRecurringTestFixtures.batch(for: transactions)])
        try await waitForRefresh(seed)
        let row = try XCTUnwrap(seed.rows.first)
        XCTAssertTrue(seed.save(row: row, cadence: .weekly, status: .paused, anchorDate: row.anchor?.date))

        let reopened = FinanceRecurringPaymentsViewModel(store: try FinanceRecurringPaymentStore(url: url))
        reopened.presentSnapshotReadError(FinanceRecurringPaymentStoreError.readFailed)

        XCTAssertNil(reopened.assessment)
        XCTAssertTrue(reopened.isStale)
        let stale = try XCTUnwrap(reopened.rows.first)
        XCTAssertTrue(stale.isStale)
        XCTAssertTrue(stale.evidence.isEmpty)
        XCTAssertEqual(stale.override?.status, .paused)
        XCTAssertEqual(stale.override?.cadence, .weekly)
    }

    func testSuccessfulSyncFollowedByPostSyncReadFailureInvalidatesRecurringAssessment() async throws {
        let importURL = FinanceRecurringTestFixtures.temporaryURL("post-sync-import")
        let recurringURL = FinanceRecurringTestFixtures.temporaryURL("post-sync-recurring")
        defer {
            try? FileManager.default.removeItem(at: importURL)
            try? FileManager.default.removeItem(at: recurringURL)
        }

        let importedStore = try FinanceImportedTransactionStore(url: importURL)
        let seedTransaction = try FinanceRecurringTestFixtures.transaction(
            date: try FinanceRecurringTestFixtures.date(2026, 1, 1)
        )
        _ = try importedStore.add([seedTransaction])

        let recurringTransactions = try [
            FinanceRecurringTestFixtures.transaction(date: try FinanceRecurringTestFixtures.date(2026, 1, 6)),
            FinanceRecurringTestFixtures.transaction(date: try FinanceRecurringTestFixtures.date(2026, 1, 13)),
            FinanceRecurringTestFixtures.transaction(date: try FinanceRecurringTestFixtures.date(2026, 1, 20)),
            FinanceRecurringTestFixtures.transaction(date: try FinanceRecurringTestFixtures.date(2026, 1, 27))
        ]
        let recurringViewModel = FinanceRecurringPaymentsViewModel(
            store: try FinanceRecurringPaymentStore(url: recurringURL)
        )
        recurringViewModel.refresh(
            transactions: recurringTransactions,
            batches: [try FinanceRecurringTestFixtures.batch(for: recurringTransactions)]
        )
        try await waitForRefresh(recurringViewModel)
        let recurringRow = try XCTUnwrap(recurringViewModel.rows.first)
        XCTAssertTrue(recurringViewModel.save(
            row: recurringRow,
            cadence: .weekly,
            status: .paused,
            anchorDate: recurringRow.anchor?.date
        ))
        XCTAssertNotNil(recurringViewModel.assessment)

        let model = FinanceImportViewModel(
            store: importedStore,
            syncOperation: { store in
                try Data("corrupt-after-success".utf8).write(to: store.fileURL, options: [.atomic])
                return FinanceImportedSyncResult(
                    snapshot: try FinanceImportedSyncSnapshot(revision: 0, records: [], tombstones: []),
                    etag: "test-revision-0"
                )
            }
        )
        var callbackCount = 0
        model.onImportedStateChanged = {
            callbackCount += 1
            do {
                let snapshot = try model.recurringSnapshot()
                recurringViewModel.refresh(transactions: snapshot.transactions, batches: snapshot.batches)
            } catch {
                recurringViewModel.presentSnapshotReadError(error)
            }
        }

        await model.synchronize()

        XCTAssertEqual(callbackCount, 1)
        XCTAssertEqual(model.syncState, .error)
        XCTAssertNil(recurringViewModel.assessment)
        XCTAssertTrue(recurringViewModel.isStale)
        let staleRow = try XCTUnwrap(recurringViewModel.rows.first)
        XCTAssertTrue(staleRow.isStale)
        XCTAssertTrue(staleRow.evidence.isEmpty)
        XCTAssertEqual(staleRow.override?.status, .paused)
    }

    func testCancellationAfterDetectorWorkStartsCannotPublishEarlierGeneration() async throws {
        let url = FinanceRecurringTestFixtures.temporaryURL("cancel-after-start")
        defer { try? FileManager.default.removeItem(at: url) }
        let transactions = try [
            FinanceRecurringTestFixtures.transaction(date: try FinanceRecurringTestFixtures.date(2026, 1, 6)),
            FinanceRecurringTestFixtures.transaction(date: try FinanceRecurringTestFixtures.date(2026, 1, 13)),
            FinanceRecurringTestFixtures.transaction(date: try FinanceRecurringTestFixtures.date(2026, 1, 20)),
            FinanceRecurringTestFixtures.transaction(date: try FinanceRecurringTestFixtures.date(2026, 1, 27))
        ]
        let probe = FinanceRecurringRefreshCancellationProbe()
        let store = try FinanceRecurringPaymentStore(url: url)
        let viewModel = FinanceRecurringPaymentsViewModel(
            store: store,
            onComputationStarted: { await probe.blockFirstComputationUntilCancelled() }
        )

        viewModel.refresh(transactions: transactions, batches: [try FinanceRecurringTestFixtures.batch(for: transactions)])
        for _ in 0..<500 {
            if await probe.started() { break }
            await Task.yield()
        }
        let didStart = await probe.started()
        XCTAssertTrue(didStart)

        // This replacement cancels the first task while its detector has
        // completed but before its durable cache write or UI publication.
        viewModel.refresh(transactions: [], batches: [])
        try await waitForRefresh(viewModel)

        let wasCancelled = await probe.cancelled()
        XCTAssertTrue(wasCancelled)
        XCTAssertTrue(viewModel.rows.isEmpty)
        XCTAssertEqual(viewModel.assessment?.candidates.count, 0)
        XCTAssertEqual(try store.load().evidenceCache?.assessment.candidates.count, 0)
    }

    func testRefreshGenerationRejectsAnEarlierCancelledSnapshotAndDeduplicatesPresentation() async throws {
        let url = FinanceRecurringTestFixtures.temporaryURL("generation")
        defer { try? FileManager.default.removeItem(at: url) }
        let transactions = try [
            FinanceRecurringTestFixtures.transaction(date: try FinanceRecurringTestFixtures.date(2026, 1, 6)),
            FinanceRecurringTestFixtures.transaction(date: try FinanceRecurringTestFixtures.date(2026, 1, 13)),
            FinanceRecurringTestFixtures.transaction(date: try FinanceRecurringTestFixtures.date(2026, 1, 20)),
            FinanceRecurringTestFixtures.transaction(date: try FinanceRecurringTestFixtures.date(2026, 1, 27))
        ]
        let viewModel = FinanceRecurringPaymentsViewModel(store: try FinanceRecurringPaymentStore(url: url))
        let batch = try FinanceRecurringTestFixtures.batch(for: transactions)

        viewModel.refresh(transactions: transactions + [transactions[0]], batches: [batch])
        viewModel.refresh(transactions: [], batches: [])
        try await waitForRefresh(viewModel)

        XCTAssertTrue(viewModel.rows.isEmpty)
        XCTAssertEqual(viewModel.assessment?.candidates.count, 0)
        XCTAssertFalse(viewModel.isStale)
    }

    func testSnapshotReadFailureStaysAnErrorInsteadOfBecomingAnEmptySuccess() async throws {
        let url = FinanceRecurringTestFixtures.temporaryURL("snapshot-error")
        defer { try? FileManager.default.removeItem(at: url) }
        try Data("corrupt".utf8).write(to: url)
        let viewModel = FinanceRecurringPaymentsViewModel(store: try FinanceRecurringPaymentStore(url: url))

        viewModel.refresh(transactions: [], batches: [])
        try await waitForRefresh(viewModel)

        XCTAssertTrue(viewModel.rows.isEmpty)
        XCTAssertTrue(viewModel.isStale)
        XCTAssertNotNil(viewModel.errorMessage)
        XCTAssertNotNil(viewModel.staleMessage)
    }

    private func waitForRefresh(
        _ viewModel: FinanceRecurringPaymentsViewModel
    ) async throws {
        for _ in 0..<500 where viewModel.isRefreshing {
            try await Task.sleep(nanoseconds: 1_000_000)
        }
        XCTAssertFalse(viewModel.isRefreshing)
    }
}
