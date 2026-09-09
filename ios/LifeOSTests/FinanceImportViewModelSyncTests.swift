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

    func testInitialAndLocalMutationStatesReflectTheBoundedOutbox() throws {
        let (store, url) = try temporaryStore()
        defer { removeStore(at: url) }

        let model = FinanceImportViewModel(store: store)
        XCTAssertEqual(model.syncState, .idle)

        model.confirmImport([transaction()])

        XCTAssertEqual(model.syncState, .pending(entryCount: 1, operationCount: 1))
        XCTAssertEqual(model.currentSyncStatus?.pendingEntryCount, 1)
        XCTAssertEqual(model.savedTransactions.count, 1)
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
