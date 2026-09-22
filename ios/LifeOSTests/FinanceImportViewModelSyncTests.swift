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

@MainActor
private final class FinanceImportPreparedMappingProbe {
    var mapping: FinanceImportMapping?
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
    private let knownTradeRepublicCSV = """
    Datum;Typ;Beschreibung;Betrag
    10.08.2026;Zahlung;Supermarkt;-12,34
    11.08.2026;Zahlung;Gehalt;100,00
    """

    private let unknownCSV = """
    posted,merchant,value
    2026-08-01,Coffee Shop,-4.50
    """

    private func temporaryStore() throws -> (FinanceImportedTransactionStore, URL) {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("lifeos-finance-import-view-model-\(UUID().uuidString)", isDirectory: true)
        let url = directory.appendingPathComponent(FinanceImportedTransactionStore.fileName)
        return (try FinanceImportedTransactionStore(url: url), url)
    }

    private func temporaryCSV(_ contents: String) throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("lifeos-finance-import-view-model-csv-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent("statement.csv", isDirectory: false)
        try Data(contents.utf8).write(to: url, options: [.atomic])
        return url
    }

    private func temporaryCSV(data: Data) throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("lifeos-finance-import-view-model-csv-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent("statement.csv", isDirectory: false)
        try data.write(to: url, options: [.atomic])
        return url
    }

    private func removeStore(at url: URL) {
        try? FileManager.default.removeItem(at: url.deletingLastPathComponent())
    }

    private func removeCSV(at url: URL) {
        try? FileManager.default.removeItem(at: url.deletingLastPathComponent())
    }

    private func persistedTransactions(
        _ transactions: [FinanceImportedTransaction]
    ) throws -> [FinanceImportedTransaction] {
        try JSONDecoder.lifeOS.decode(
            [FinanceImportedTransaction].self,
            from: JSONEncoder.lifeOS.encode(transactions)
        )
    }

    private func prepareKnownPreview(
        for model: FinanceImportViewModel,
        at url: URL
    ) throws -> FinanceImportResult {
        model.handlePickedFile(.success([url]))
        let preview = try XCTUnwrap(model.pendingResult)
        XCTAssertFalse(model.requiresExplicitMapping)
        XCTAssertFalse(model.mappingIsBlocked)
        XCTAssertEqual(preview.institutionDetection.state, .known)
        XCTAssertFalse(preview.transactions.isEmpty)
        return preview
    }

    private func mappedDraft(for account: FinanceImportAccountIdentity) -> FinanceImportMappingDraft {
        FinanceImportMappingDraft(
            delimiter: .comma,
            headerRecordIndex: 0,
            dateColumn: 0,
            dateFormat: .yearMonthDay,
            amount: .signed(column: 2),
            currency: .constantEUR,
            account: FinanceImportAccountSelection(identity: account),
            description: .column(index: 1)
        )
    }

    private func prepareMappedPreview(
        for model: FinanceImportViewModel,
        at url: URL,
        account: FinanceImportAccountIdentity
    ) throws -> FinanceImportResult {
        model.handlePickedFile(.success([url]))
        XCTAssertTrue(model.requiresExplicitMapping)
        model.applyMapping(mappedDraft(for: account))
        let preview = try XCTUnwrap(model.pendingResult)
        XCTAssertFalse(preview.transactions.isEmpty)
        XCTAssertTrue(model.canEditMapping)
        return preview
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
        let statementURL = try temporaryCSV(knownTradeRepublicCSV)
        defer { removeCSV(at: statementURL) }

        let model = FinanceImportViewModel(store: store)
        XCTAssertEqual(model.syncState, .idle)

        let preview = try prepareKnownPreview(for: model, at: statementURL)
        let confirmation = await model.confirmImport(preview.transactions)

        XCTAssertEqual(confirmation, .saved)
        XCTAssertEqual(
            model.syncState,
            .pending(entryCount: 1, operationCount: preview.transactions.count)
        )
        XCTAssertEqual(model.currentSyncStatus?.pendingEntryCount, 1)
        XCTAssertEqual(model.savedTransactions.count, preview.transactions.count)
    }

    func testImportedMutationsNotifyDerivedRecurringConsumers() async throws {
        let (store, url) = try temporaryStore()
        defer { removeStore(at: url) }
        let statementURL = try temporaryCSV(knownTradeRepublicCSV)
        defer { removeCSV(at: statementURL) }

        let model = FinanceImportViewModel(store: store)
        var callbackCount = 0
        model.onImportedStateChanged = { callbackCount += 1 }

        let preview = try prepareKnownPreview(for: model, at: statementURL)
        let confirmation = await model.confirmImport(preview.transactions)
        XCTAssertEqual(confirmation, .saved)
        XCTAssertEqual(callbackCount, 1)

        model.clearAll()
        XCTAssertEqual(callbackCount, 2)
    }

    func testOversizedPickedCSVIsRejectedBeforeAnyPreviewIsCreated() throws {
        let (store, storeURL) = try temporaryStore()
        defer { removeStore(at: storeURL) }
        let oversized = Data(repeating: 0x61, count: FinanceStatementImporter.maximumInputBytes + 1)
        let statementURL = try temporaryCSV(data: oversized)
        defer { removeCSV(at: statementURL) }
        let model = FinanceImportViewModel(store: store)

        model.handlePickedFile(.success([statementURL]))

        XCTAssertEqual(model.errorMessage, "The CSV is larger than the 5 MB import limit.")
        XCTAssertNil(model.pendingResult)
        XCTAssertFalse(model.requiresExplicitMapping)
    }

    func testSelectedHeaderAndOptionalIdentityColumnsReachPreparedMapping() async throws {
        let (store, url) = try temporaryStore()
        defer { removeStore(at: url) }
        let statementURL = try temporaryCSV("""
        preamble,metadata
        posted,amount,merchant,provider,account
        2026-08-01,-4.50,Coffee,coffee-1,checking
        posted,amount,merchant,provider,account
        2026-08-02,-5.50,Tea,tea-1,savings
        """)
        defer { removeCSV(at: statementURL) }
        let account = try FinanceImportAccountIdentity(
            id: UUID(uuidString: "00000000-0000-4000-8000-000000000092")!,
            label: "Mapped account"
        )
        let probe = FinanceImportPreparedMappingProbe()
        let model = FinanceImportViewModel(store: store, preparedImportOperation: { prepared, categoryEdits in
            probe.mapping = prepared.mapping
            return try store.commitPreparedImport(prepared, categoryEdits: categoryEdits)
        })

        model.handlePickedFile(.success([statementURL]))

        XCTAssertTrue(model.requiresExplicitMapping)
        XCTAssertEqual(model.mappingHeaderRecordIndices, [1, 3])
        XCTAssertEqual(model.mappingHeaderRecordIndex, 1)
        model.applyMapping(
            FinanceImportMappingDraft(
                delimiter: .comma,
                headerRecordIndex: 3,
                dateColumn: 0,
                dateFormat: .yearMonthDay,
                amount: .signed(column: 1),
                currency: .constantEUR,
                account: FinanceImportAccountSelection(identity: account, sourceColumn: 4),
                description: FinanceImportDescriptionSelection.none,
                providerIDColumn: 3,
                merchantColumn: 2
            )
        )

        let preview = try XCTUnwrap(model.pendingResult)
        XCTAssertEqual(preview.transactions.count, 1)
        let outcome = await model.confirmImport(preview.transactions)
        XCTAssertEqual(outcome, .saved)

        let mapping = try XCTUnwrap(probe.mapping)
        XCTAssertEqual(mapping.headerRecordIndex, 3)
        XCTAssertEqual(mapping.columnCount, 5)
        XCTAssertEqual(
            mapping.headerFingerprint,
            FinanceImportFingerprint.header(["posted", "amount", "merchant", "provider", "account"])
        )
        XCTAssertEqual(mapping.providerIDColumn, 3)
        XCTAssertEqual(mapping.merchantColumn, 2)
        XCTAssertEqual(mapping.account.sourceColumn, 4)
    }

    func testDuplicateDiagnosticsExposeExactAndConflictingIdentityPresentation() throws {
        let (store, storeURL) = try temporaryStore()
        defer { removeStore(at: storeURL) }
        let statementURL = try temporaryCSV("""
        posted,amount,provider
        2026-08-01,-4.50,same-provider
        2026-08-01,-4.50,same-provider
        2026-08-01,-5.50,same-provider
        """)
        defer { removeCSV(at: statementURL) }
        let account = try FinanceImportAccountIdentity(label: "Duplicate test account")
        let model = FinanceImportViewModel(store: store)

        model.handlePickedFile(.success([statementURL]))
        model.applyMapping(
            FinanceImportMappingDraft(
                delimiter: .comma,
                headerRecordIndex: 0,
                dateColumn: 0,
                dateFormat: .yearMonthDay,
                amount: .signed(column: 1),
                currency: .constantEUR,
                account: FinanceImportAccountSelection(identity: account),
                description: FinanceImportDescriptionSelection.none,
                providerIDColumn: 2
            )
        )

        let diagnostics = try XCTUnwrap(model.pendingResult?.diagnostics)
        XCTAssertEqual(
            diagnostics.map(\.duplicateDisposition),
            [.conflictingProviderID, .conflictingProviderID, .conflictingProviderID]
        )
        XCTAssertEqual(diagnostics.map(\.financeImportDisplayName), [
            "conflicting provider identity",
            "conflicting provider identity",
            "conflicting provider identity"
        ])
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
        let statementURL = try temporaryCSV(knownTradeRepublicCSV)
        defer { removeCSV(at: statementURL) }

        XCTAssertTrue(
            fixtureDirectory.standardizedFileURL.path.hasPrefix(
                fileManager.temporaryDirectory.standardizedFileURL.path
            ),
            "fixture Finance persistence must live under the temporary directory"
        )
        XCTAssertNotEqual(fixtureTransactionStore.fileURL, personalTransactionURL)
        XCTAssertNotEqual(fixtureBudgetStore.fileURL, personalBudgetURL)

        let preview = try prepareKnownPreview(for: cardState.model, at: statementURL)
        let confirmationResult = await cardState.model.confirmImport(preview.transactions)
        XCTAssertEqual(confirmationResult, .saved)
        XCTAssertEqual(try fixtureTransactionStore.all(), try persistedTransactions(preview.transactions))
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
        XCTAssertEqual(
            cardState.model.syncState,
            .pending(entryCount: 1, operationCount: preview.transactions.count)
        )

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
        let statementURL = try temporaryCSV(knownTradeRepublicCSV)
        defer { removeCSV(at: statementURL) }
        let probe = FinanceImportSaveProbe(failNext: true)
        let model = FinanceImportViewModel(store: store, preparedImportOperation: { prepared, categoryEdits in
            try await probe.beforeSave()
            return try store.commitPreparedImport(prepared, categoryEdits: categoryEdits)
        })
        let preview = try prepareKnownPreview(for: model, at: statementURL)

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
        XCTAssertEqual(try store.all(), try persistedTransactions(preview.transactions))
        let retryCallCount = await probe.callCount()
        XCTAssertEqual(retryCallCount, 2)
    }

    func testConcurrentImportTapIsRejectedWhileTheFirstSaveIsInFlight() async throws {
        let (store, url) = try temporaryStore()
        defer { removeStore(at: url) }
        let statementURL = try temporaryCSV(knownTradeRepublicCSV)
        defer { removeCSV(at: statementURL) }
        let probe = FinanceImportSaveProbe(holdsUntilReleased: true)
        let model = FinanceImportViewModel(store: store, preparedImportOperation: { prepared, categoryEdits in
            try await probe.beforeSave()
            return try store.commitPreparedImport(prepared, categoryEdits: categoryEdits)
        })
        let preview = try prepareKnownPreview(for: model, at: statementURL)

        let first = Task { await model.confirmImport(preview.transactions) }
        while await probe.callCount() == 0 {
            await Task.yield()
        }

        let second = await model.confirmImport(preview.transactions)
        XCTAssertEqual(second, .failed(message: "An import is already being saved. Keep this preview open and wait for it to finish."))
        let concurrentCallCount = await probe.callCount()
        XCTAssertEqual(concurrentCallCount, 1)
        XCTAssertTrue(model.isImporting)

        await probe.release()
        let firstResult = await first.value
        XCTAssertEqual(firstResult, .saved)
        XCTAssertEqual(try store.all(), try persistedTransactions(preview.transactions))
        XCTAssertFalse(model.isImporting)
    }

    func testConfirmAfterDiscardIsRejectedWithoutAStoreWrite() async throws {
        let (store, url) = try temporaryStore()
        defer { removeStore(at: url) }
        let statementURL = try temporaryCSV(knownTradeRepublicCSV)
        defer { removeCSV(at: statementURL) }
        let probe = FinanceImportSaveProbe()
        let model = FinanceImportViewModel(store: store, preparedImportOperation: { prepared, categoryEdits in
            try await probe.beforeSave()
            return try store.commitPreparedImport(prepared, categoryEdits: categoryEdits)
        })
        let preview = try prepareKnownPreview(for: model, at: statementURL)

        model.discardPending()

        let outcome = await model.confirmImport(preview.transactions)
        XCTAssertEqual(outcome, .failed(message: "This import preview is no longer available. Choose the file again."))
        XCTAssertTrue(try store.all().isEmpty)
        XCTAssertEqual(try store.pendingSyncEntryCount(), 0)
        let saveCallCount = await probe.callCount()
        XCTAssertEqual(saveCallCount, 0)
    }

    func testRepeatedMappedPreviewReusesTheSelectedPersistedAccountIdentity() async throws {
        let (store, url) = try temporaryStore()
        defer { removeStore(at: url) }
        let statementURL = try temporaryCSV(unknownCSV)
        defer { removeCSV(at: statementURL) }
        let account = try FinanceImportAccountIdentity(
            id: UUID(uuidString: "00000000-0000-4000-8000-000000000091")!,
            label: "Everyday account"
        )

        let firstModel = FinanceImportViewModel(store: store)
        let firstPreview = try prepareMappedPreview(for: firstModel, at: statementURL, account: account)
        let firstOutcome = await firstModel.confirmImport(firstPreview.transactions)
        XCTAssertEqual(firstOutcome, .saved)
        XCTAssertEqual(
            firstModel.availableAccountChoices,
            [FinanceImportAccountChoice(id: account.id, localLabel: account.label)]
        )

        let secondModel = FinanceImportViewModel(store: store)
        let selectedChoice = try XCTUnwrap(secondModel.availableAccountChoices.first)
        let selectedAccount = try FinanceImportAccountIdentity(
            id: selectedChoice.id,
            label: try XCTUnwrap(selectedChoice.localLabel)
        )
        XCTAssertEqual(selectedAccount.id, account.id)
        let secondPreview = try prepareMappedPreview(for: secondModel, at: statementURL, account: selectedAccount)
        let secondOutcome = await secondModel.confirmImport(secondPreview.transactions)
        XCTAssertEqual(secondOutcome, .saved)

        let persistedMappings = try store.importMappings()
        XCTAssertEqual(Set(persistedMappings.map { $0.account.identity.id }), Set([account.id]))
        XCTAssertEqual(Set(persistedMappings.map { $0.account.identity.label }), Set([account.label]))
        XCTAssertEqual(try store.all().count, 1, "reimporting with the saved account must not create a second ledger row")
    }

    func testSyncedMappedIdentityCanBeSelectedWithNewLocalLabel() async throws {
        let statementURL = try temporaryCSV(unknownCSV)
        defer { removeCSV(at: statementURL) }

        let seedStoreAndURL = try temporaryStore()
        defer { removeStore(at: seedStoreAndURL.1) }
        let remoteAccount = try FinanceImportAccountIdentity(
            id: UUID(uuidString: "00000000-0000-4000-8000-000000000093")!,
            label: "Remote-only label"
        )
        let seedModel = FinanceImportViewModel(store: seedStoreAndURL.0)
        let seedPreview = try prepareMappedPreview(
            for: seedModel,
            at: statementURL,
            account: remoteAccount
        )
        let receiverStoreAndURL = try temporaryStore()
        defer { removeStore(at: receiverStoreAndURL.1) }
        try receiverStoreAndURL.0.add(seedPreview.transactions)

        let receiverModel = FinanceImportViewModel(store: receiverStoreAndURL.0)
        let syncedChoice = try XCTUnwrap(receiverModel.availableAccountChoices.first)
        XCTAssertEqual(syncedChoice.id, remoteAccount.id)
        XCTAssertTrue(syncedChoice.isSyncedOnly)
        XCTAssertNil(syncedChoice.localLabel)
        XCTAssertTrue(try receiverStoreAndURL.0.importMappings().isEmpty)

        let localIdentity = try FinanceImportAccountIdentity(
            id: syncedChoice.id,
            label: "Everyday account"
        )
        let preview = try prepareMappedPreview(
            for: receiverModel,
            at: statementURL,
            account: localIdentity
        )
        let confirmation = await receiverModel.confirmImport(preview.transactions)
        XCTAssertEqual(confirmation, .saved)

        let mapping = try XCTUnwrap(try receiverStoreAndURL.0.importMappings().first)
        XCTAssertEqual(mapping.account.identity.id, syncedChoice.id)
        XCTAssertEqual(mapping.account.identity.label, "Everyday account")
        XCTAssertEqual(try receiverStoreAndURL.0.all().count, seedPreview.transactions.count)
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
