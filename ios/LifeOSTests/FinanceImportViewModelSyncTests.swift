import Foundation
import XCTest
@testable import LifeOS

private actor FinanceImportSyncProbe {
    private var calls = 0
    private var releaseContinuation: CheckedContinuation<Void, Never>?

    func hold() async {
        calls += 1
        await withCheckedContinuation { continuation in
            releaseContinuation = continuation
        }
    }

    func release() {
        releaseContinuation?.resume()
        releaseContinuation = nil
    }

    func callCount() -> Int { calls }
}

private actor FinanceImportSaveProbe {
    private var calls = 0
    private var failNext: Bool
    private let holdsUntilReleased: Bool
    private var releaseContinuation: CheckedContinuation<Void, Never>?

    init(failNext: Bool = false, holdsUntilReleased: Bool = false) {
        self.failNext = failNext
        self.holdsUntilReleased = holdsUntilReleased
    }

    func beforeSave() async throws {
        calls += 1
        if failNext {
            failNext = false
            throw FinanceImportedTransactionStoreError.writeFailed
        }
        if holdsUntilReleased {
            await withCheckedContinuation { continuation in
                releaseContinuation = continuation
            }
        }
    }

    func release() {
        releaseContinuation?.resume()
        releaseContinuation = nil
    }

    func callCount() -> Int { calls }
}

private struct FinanceStoreFileMetadata: Equatable {
    let exists: Bool
    let byteCount: UInt64?
    let modificationDate: Date?
    let fileNumber: UInt64?

    init(fileManager: FileManager, url: URL) {
        guard let attributes = try? fileManager.attributesOfItem(atPath: url.path) else {
            exists = false
            byteCount = nil
            modificationDate = nil
            fileNumber = nil
            return
        }

        exists = true
        byteCount = (attributes[.size] as? NSNumber)?.uint64Value
        modificationDate = attributes[.modificationDate] as? Date
        fileNumber = (attributes[.systemFileNumber] as? NSNumber)?.uint64Value
    }
}

@MainActor
final class FinanceImportViewModelSyncTests: XCTestCase {
    private func temporaryStore() throws -> (FinanceImportedTransactionStore, URL) {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("lifeos-finance-import-view-model-\(UUID().uuidString)", isDirectory: true)
        let url = directory.appendingPathComponent(FinanceImportedTransactionStore.fileName)
        return (try FinanceImportedTransactionStore(url: url), url)
    }

    private func removeStore(at url: URL) {
        try? FileManager.default.removeItem(at: url.deletingLastPathComponent())
    }

    private func transaction() -> FinanceImportedTransaction {
        FinanceImportedTransaction(
            bookedAt: Date(timeIntervalSince1970: 1_786_449_600),
            amountCents: -1_234,
            description: "Supermarkt",
            source: .genericCSV,
            importedAt: Date(timeIntervalSince1970: 1_786_449_600)
        )
    }

    private func result(revision: Int) throws -> FinanceImportedSyncResult {
        FinanceImportedSyncResult(
            snapshot: try FinanceImportedSyncSnapshot(revision: revision, records: [], tombstones: []),
            etag: "test-revision-\(revision)"
        )
    }

    func testInitialAndLocalMutationStatesReflectTheBoundedOutbox() async throws {
        let (store, url) = try temporaryStore()
        defer { removeStore(at: url) }

        let model = FinanceImportViewModel(store: store)
        XCTAssertEqual(model.syncState, .idle)

        await model.confirmImport([transaction()])

        XCTAssertEqual(model.syncState, .pending(entryCount: 1, operationCount: 1))
        XCTAssertEqual(model.currentSyncStatus?.pendingEntryCount, 1)
        XCTAssertEqual(model.savedTransactions.count, 1)
    }

    func testVisualFixtureFinanceActionsStayOutOfPersonalStoresAndNetwork() async throws {
        let fileManager = FileManager.default
        let personalTransactionURL = try FinanceImportedTransactionStore.defaultURL(fileManager: fileManager)
        let personalBudgetURL = try FinanceBudgetStore.defaultURL(fileManager: fileManager)
        let personalTransactionBefore = FinanceStoreFileMetadata(
            fileManager: fileManager,
            url: personalTransactionURL
        )
        let personalBudgetBefore = FinanceStoreFileMetadata(
            fileManager: fileManager,
            url: personalBudgetURL
        )
#if DEBUG
        let networkTaskCountBefore = LifeOSNetworkTaskAudit.shared.createdTaskCount
#endif

        let cardState = FinanceImportCardState(usesVisualFixtures: true)
        guard let fixturePersistence = cardState.persistence,
              let fixtureTransactionStore = fixturePersistence.importedTransactionStore,
              let fixtureBudgetStore = fixturePersistence.budgetStore,
              let fixtureDirectory = fixturePersistence.directoryURL else {
            return XCTFail("visual fixtures must have isolated Finance stores")
        }
        defer { try? fileManager.removeItem(at: fixtureDirectory) }

        XCTAssertTrue(
            fixtureDirectory.standardizedFileURL.path.hasPrefix(
                fileManager.temporaryDirectory.standardizedFileURL.path
            ),
            "fixture Finance persistence must live under the temporary directory"
        )
        XCTAssertNotEqual(fixtureTransactionStore.fileURL, personalTransactionURL)
        XCTAssertNotEqual(fixtureBudgetStore.fileURL, personalBudgetURL)

        let imported = transaction()
        let confirmationResult = await cardState.model.confirmImport([imported])
        XCTAssertEqual(confirmationResult, .saved)
        XCTAssertEqual(try fixtureTransactionStore.all(), [imported])
#if DEBUG
        XCTAssertEqual(
            LifeOSNetworkTaskAudit.shared.createdTaskCount,
            networkTaskCountBefore,
            "fixture confirmation must not create a production Tailscale transport task"
        )
#endif

        let sentinelDate = Date(timeIntervalSince1970: 1_786_449_600)
        let budgetModel = FinanceBudgetViewModel(
            store: fixtureBudgetStore,
            usesVisualFixtures: true
        )
        budgetModel.setLimit(
            cents: 25_000,
            for: .groceries,
            effectiveFrom: sentinelDate
        )
        XCTAssertEqual(
            try fixtureBudgetStore.currentBudgets(on: sentinelDate)[.groceries]?.monthlyLimitCents,
            25_000
        )

        cardState.model.clearAll()
        XCTAssertTrue(try fixtureTransactionStore.all().isEmpty)
        XCTAssertEqual(cardState.model.syncState, .pending(entryCount: 1, operationCount: 1))

        // The fixture sync operation is a fail-closed no-op. It throws before
        // constructing TailscaleSyncClient, so exercising the refresh action
        // cannot issue a request or mutate the live gateway.
        await cardState.model.synchronize()
        XCTAssertEqual(
            cardState.model.syncMessage,
            "Private sync is disabled in visual fixtures. Local rows were kept."
        )
        XCTAssertEqual(try fixtureTransactionStore.all(), [])

        XCTAssertEqual(
            FinanceStoreFileMetadata(fileManager: fileManager, url: personalTransactionURL),
            personalTransactionBefore,
            "fixture actions must not create or replace the resolved personal transaction store"
        )
        XCTAssertEqual(
            FinanceStoreFileMetadata(fileManager: fileManager, url: personalBudgetURL),
            personalBudgetBefore,
            "fixture actions must not create or replace the resolved personal budget store"
        )
#if DEBUG
        XCTAssertEqual(
            LifeOSNetworkTaskAudit.shared.createdTaskCount,
            networkTaskCountBefore,
            "visual-fixture sync must fail closed before the production Tailscale transport"
        )
#endif
    }

    func testAsyncImportFailureKeepsPreviewForExactRetryThenClearsAfterSuccess() async throws {
        let (store, url) = try temporaryStore()
        defer { removeStore(at: url) }
        let imported = transaction()
        let preview = FinanceImportResult(
            transactions: [imported],
            skippedRowCount: 0,
            detectedSource: .genericCSV
        )
        let probe = FinanceImportSaveProbe(failNext: true)
        let model = FinanceImportViewModel(store: store, importOperation: { transactions in
            try await probe.beforeSave()
            return try store.add(transactions)
        })
        model.pendingResult = preview

        let failed = await model.confirmImport(preview.transactions)

        XCTAssertEqual(failed, .failed(message: "Imported Finance changes could not be saved."))
        XCTAssertEqual(model.pendingResult, preview, "A failed durable write must leave the editable preview and retry payload intact")
        XCTAssertEqual(model.errorMessage, "Imported Finance changes could not be saved.")
        XCTAssertFalse(model.isImporting)
        XCTAssertTrue(try store.all().isEmpty)

        let saved = await model.confirmImport(preview.transactions)

        XCTAssertEqual(saved, .saved)
        XCTAssertNil(model.pendingResult, "The sheet payload is cleared only after the durable retry succeeds")
        XCTAssertNil(model.errorMessage, "A successful retry must clear the stale failure alert")
        XCTAssertEqual(try store.all(), [imported])
        let retryCallCount = await probe.callCount()
        XCTAssertEqual(retryCallCount, 2)
    }

    func testConcurrentImportTapIsRejectedWhileTheFirstSaveIsInFlight() async throws {
        let (store, url) = try temporaryStore()
        defer { removeStore(at: url) }
        let imported = transaction()
        let probe = FinanceImportSaveProbe(holdsUntilReleased: true)
        let model = FinanceImportViewModel(store: store, importOperation: { transactions in
            try await probe.beforeSave()
            return try store.add(transactions)
        })

        let first = Task { await model.confirmImport([imported]) }
        while await probe.callCount() == 0 {
            await Task.yield()
        }

        let second = await model.confirmImport([imported])
        XCTAssertEqual(second, .failed(message: "An import is already being saved. Keep this preview open and wait for it to finish."))
        let concurrentCallCount = await probe.callCount()
        XCTAssertEqual(concurrentCallCount, 1)
        XCTAssertTrue(model.isImporting)

        await probe.release()
        let firstResult = await first.value
        XCTAssertEqual(firstResult, .saved)
        XCTAssertEqual(try store.all(), [imported])
        XCTAssertFalse(model.isImporting)
    }

    func testClearAllCopyExplainsDeferredImportedDeletionAndProtectsConnectedAccounts() throws {
        let (store, url) = try temporaryStore()
        defer { removeStore(at: url) }
        try store.add([transaction()])
        let model = FinanceImportViewModel(store: store)

        model.clearAll()

        XCTAssertEqual(model.statusMessage, FinanceImportCopy.clearAllSuccess)
        XCTAssertEqual(FinanceImportCopy.clearAllConfirmation, "This removes imported records on this device. Deletion of imported records propagates on the next sync; connected bank accounts are unaffected.")
        XCTAssertTrue(model.statusMessage?.contains("next sync") == true)
        XCTAssertTrue(model.statusMessage?.contains("connected bank accounts are unaffected") == true)
        XCTAssertTrue(model.savedTransactions.isEmpty)
        XCTAssertEqual(try store.pendingSyncEntryCount(), 1)
    }

    func testSuccessfulSyncExposesOnlyTheGatewayRevision() async throws {
        let (store, url) = try temporaryStore()
        defer { removeStore(at: url) }
        let gatewayResult = try result(revision: 7)
        let model = FinanceImportViewModel(store: store, syncOperation: { _ in gatewayResult })

        await model.synchronize()

        XCTAssertEqual(model.syncState, .idle)
        XCTAssertEqual(model.lastConfirmedRemoteRevision, 7)
        XCTAssertEqual(model.syncMessage, "The gateway confirmed revision 7.")
        XCTAssertFalse(model.isSynchronizing)
    }

    func testConfigurationFailureIsSafeAndLeavesRetryAvailable() async throws {
        let (store, url) = try temporaryStore()
        defer { removeStore(at: url) }
        let model = FinanceImportViewModel(store: store, syncOperation: { _ in
            throw TailscaleSyncError.notConfigured
        })

        await model.synchronize()

        XCTAssertEqual(model.syncState, .error)
        XCTAssertEqual(model.syncMessage, "Private sync is not configured. Check the approved LifeOS gateway, then retry.")
        XCTAssertTrue(model.canSynchronize)
        XCTAssertFalse(model.syncMessage?.contains("notConfigured") ?? false)
    }

    func testCancellationKeepsLocalRowsAndPendingState() async throws {
        let (store, url) = try temporaryStore()
        defer { removeStore(at: url) }
        try store.add([transaction()])
        let model = FinanceImportViewModel(store: store, syncOperation: { _ in
            throw CancellationError()
        })

        await model.synchronize()

        XCTAssertEqual(model.syncState, .pending(entryCount: 1, operationCount: 1))
        XCTAssertEqual(model.savedTransactions.count, 1)
        XCTAssertEqual(model.syncMessage, "Sync cancelled. Local rows were kept.")
        XCTAssertFalse(model.isSynchronizing)
    }

    func testConcurrentTapsRunOnlyOneSyncOperation() async throws {
        let (store, url) = try temporaryStore()
        defer { removeStore(at: url) }
        let probe = FinanceImportSyncProbe()
        let gatewayResult = try result(revision: 2)
        let model = FinanceImportViewModel(store: store, syncOperation: { _ in
            await probe.hold()
            return gatewayResult
        })

        let first = Task { await model.synchronize() }
        while await probe.callCount() == 0 {
            await Task.yield()
        }

        await model.synchronize()
        let callsAfterSecondTap = await probe.callCount()
        XCTAssertEqual(callsAfterSecondTap, 1)

        await probe.release()
        await first.value
        XCTAssertEqual(model.lastConfirmedRemoteRevision, 2)
        XCTAssertFalse(model.isSynchronizing)
    }
}
