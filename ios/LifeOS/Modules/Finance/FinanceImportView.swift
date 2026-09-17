import Combine
import SwiftUI
import UniformTypeIdentifiers

private extension FinanceImportSkipReason {
    var displayName: String {
        switch self {
        case .malformedRow: "malformed row"
        case .unsupportedCurrency: "unsupported currency"
        case .invalidDateOrAmount: "invalid date or amount"
        case .unrecognizedHeader: "unrecognized date/amount header"
        @unknown default: "skipped row"
        }
    }
}

extension FinanceImportDiagnostic {
    /// A duplicate identity is a valid parsed row with a distinct user-facing
    /// outcome. Keep it separate from parser failures even though the shared
    /// compatibility reason remains unchanged.
    var financeImportDisplayName: String {
        switch duplicateDisposition {
        case .exactRepeat:
            "exact repeat"
        case .conflictingProviderID:
            "conflicting provider identity"
        case nil:
            reason.displayName
        }
    }
}

enum FinanceImportSyncState: Equatable {
    case idle
    case pending(entryCount: Int, operationCount: Int)
    case blocked(entryCount: Int, reasons: [FinanceImportedSyncBlockReason])
    case syncing
    case unavailable
    case error
}

enum FinanceImportConfirmationResult: Equatable {
    case saved
    case failed(message: String)
}

enum FinanceImportCopy {
    static let clearAllPropagation = "Deletion of imported records propagates on the next sync; connected bank accounts are unaffected."
    static let clearAllConfirmation = "This removes imported records on this device. " + clearAllPropagation
    static let clearAllSuccess = "Imported records removed on this device. " + clearAllPropagation
}

/// An account identity available to the mapping editor. A locally reviewed
/// mapping contributes its private label; a mapped row received from another
/// device contributes only its stable UUID and must be given a local label
/// before it can be used. No source account value is retained here.
struct FinanceImportAccountChoice: Identifiable, Equatable {
    let id: UUID
    let localLabel: String?

    var isSyncedOnly: Bool { localLabel == nil }

    var displayName: String {
        if let localLabel { return localLabel }
        return "Synced account · \(id.uuidString.prefix(8))"
    }
}

// MARK: - Manual bank-statement CSV import

/// Drives the CSV file picker, parse preview, and persistence for manually
/// imported bank-statement transactions. Deliberately independent of
/// `FinanceCoordinator`: this surface reads/writes only its own
/// `FinanceImportedTransactionStore` and never touches the live Finance
/// connector snapshot, so a manual import can never be mistaken for a
/// connector observation.
@MainActor
final class FinanceImportViewModel: ObservableObject {
    typealias SyncOperation = (FinanceImportedTransactionStore) async throws -> FinanceImportedSyncResult
    typealias PreparedImportOperation = (FinancePreparedImport, [FinanceImportCategoryEdit]) async throws -> FinanceImportSaveResult

    @Published var isImporterPresented = false
    @Published var pendingResult: FinanceImportResult?
    @Published var errorMessage: String?
    @Published var statusMessage: String?
    @Published private(set) var savedTransactions: [FinanceImportedTransaction] = []
    @Published private(set) var syncState: FinanceImportSyncState
    @Published private(set) var currentSyncStatus: FinanceImportedSyncStatus?
    @Published private(set) var syncMessage: String?
    @Published private(set) var lastConfirmedRemoteRevision: Int?
    @Published private(set) var isSynchronizing = false
    @Published private(set) var isImporting = false
    @Published private(set) var availableAccountChoices: [FinanceImportAccountChoice] = []

    /// Card-state callback for derived local recurring-payment assessment.
    /// The recurring view receives snapshots; it never mutates this model's
    /// transaction store.
    var onImportedStateChanged: (() -> Void)?

    private let store: FinanceImportedTransactionStore?
    private let syncOperation: SyncOperation
    private let preparedImportOperation: PreparedImportOperation
    private var syncGeneration = 0
    private var importGeneration = 0
    private var pendingSourceData: Data?
    private var pendingInspection: FinanceImportInspection?
    private var pendingHeaderColumns: [String] = []
    private var pendingPreparedImport: FinancePreparedImport?
    private var pendingSessionID: UUID?

    private static let boundedReadChunkSize = 64 * 1024

    init(
        store: FinanceImportedTransactionStore? = nil,
        syncOperation: @escaping SyncOperation = { store in
            try await store.synchronize(using: TailscaleSyncClient())
        },
        preparedImportOperation: PreparedImportOperation? = nil
    ) {
        let resolvedStore: FinanceImportedTransactionStore?
        let initialTransactions: [FinanceImportedTransaction]
        let initialAccountChoices: [FinanceImportAccountChoice]
        let initialSyncStatus: FinanceImportedSyncStatus?
        let initialError: String?
        if let store {
            resolvedStore = store
            var loadedTransactions: [FinanceImportedTransaction] = []
            var loadedMappings: [FinanceImportMapping] = []
            var loadError: String?
            do {
                loadedTransactions = try store.all()
            } catch {
                loadError = Self.localErrorMessage(for: error)
            }
            do {
                loadedMappings = try store.importMappings()
            } catch {
                if loadError == nil { loadError = Self.localErrorMessage(for: error) }
            }
            initialTransactions = loadedTransactions
            initialAccountChoices = Self.accountChoices(from: loadedMappings, transactions: loadedTransactions)
            do {
                initialSyncStatus = try store.syncStatus()
            } catch {
                initialSyncStatus = nil
                if loadError == nil { loadError = Self.localErrorMessage(for: error) }
            }
            initialError = loadError
        } else {
            do {
                let candidate = try FinanceImportedTransactionStore()
                resolvedStore = candidate
                var loadedTransactions: [FinanceImportedTransaction] = []
                var loadedMappings: [FinanceImportMapping] = []
                var loadError: String?
                do {
                    loadedTransactions = try candidate.all()
                } catch {
                    loadError = Self.localErrorMessage(for: error)
                }
                do {
                    loadedMappings = try candidate.importMappings()
                } catch {
                    if loadError == nil { loadError = Self.localErrorMessage(for: error) }
                }
                initialTransactions = loadedTransactions
                initialAccountChoices = Self.accountChoices(from: loadedMappings, transactions: loadedTransactions)
                do {
                    initialSyncStatus = try candidate.syncStatus()
                } catch {
                    initialSyncStatus = nil
                    if loadError == nil { loadError = Self.localErrorMessage(for: error) }
                }
                initialError = loadError
            } catch {
                resolvedStore = nil
                initialTransactions = []
                initialAccountChoices = []
                initialSyncStatus = nil
                initialError = Self.localErrorMessage(for: error)
            }
        }
        self.store = resolvedStore
        self.syncOperation = syncOperation
        self.preparedImportOperation = preparedImportOperation ?? { prepared, categoryEdits in
            guard let resolvedStore else {
                throw FinanceImportedTransactionStoreError.applicationSupportUnavailable
            }
            return try resolvedStore.commitPreparedImport(prepared, categoryEdits: categoryEdits)
        }
        self.savedTransactions = initialTransactions
        self.availableAccountChoices = initialAccountChoices
        self.currentSyncStatus = initialSyncStatus
        self.syncState = if resolvedStore == nil {
            .unavailable
        } else if let initialSyncStatus {
            Self.presentationState(for: initialSyncStatus)
        } else {
            .error
        }
        self.errorMessage = initialError
        self.syncMessage = if resolvedStore == nil {
            "Imported Finance storage is unavailable. Local rows cannot be loaded here."
        } else if initialSyncStatus == nil {
            "Imported Finance storage could not be refreshed. Local rows were kept where possible."
        } else {
            nil
        }
    }

    var hasStore: Bool { store != nil }
    var canImport: Bool { store != nil && !isImporting }
    var canSynchronize: Bool { store != nil && !isSynchronizing }
    var requiresExplicitMapping: Bool {
        pendingPreparedImport == nil && pendingInspection?.mappingEligibility.requiresExplicitMapping == true
    }
    var mappingIsBlocked: Bool {
        pendingPreparedImport == nil && pendingInspection?.mappingEligibility.isBlocked == true
    }
    var mappingHeaderColumns: [String] { pendingHeaderColumns }
    var mappingHeaderRecordIndices: [Int] {
        pendingInspection?.candidateHeaderRecordIndices ?? []
    }
    var mappingHeaderRecordIndex: Int? {
        pendingInspection?.headerRecordIndex
    }
    var showsMappingEditor: Bool {
        guard pendingInspection?.mappingEligibility.requiresExplicitMapping == true else { return false }
        return pendingPreparedImport == nil || pendingPreparedImport?.transactions.isEmpty == true
    }
    var canEditMapping: Bool {
        pendingInspection?.mappingEligibility.requiresExplicitMapping == true
            && pendingPreparedImport?.transactions.isEmpty == false
    }
    var syncActionTitle: String {
        if isSynchronizing { return "Syncing…" }
        if case .blocked = syncState { return "Retry sync" }
        return "Sync to LifeOS"
    }

    func handlePickedFile(_ result: Result<[URL], Error>) {
        guard !isImporting else {
            errorMessage = "An import is already being saved. Keep the current preview open and wait for it to finish."
            return
        }
        importGeneration &+= 1
        errorMessage = nil
        statusMessage = nil
        pendingResult = nil
        pendingSourceData = nil
        pendingInspection = nil
        pendingHeaderColumns = []
        pendingPreparedImport = nil
        pendingSessionID = nil
        switch result {
        case .failure(let error):
            errorMessage = error.localizedDescription
        case .success(let urls):
            guard urls.count == 1, let url = urls.first else {
                errorMessage = "Choose one CSV statement at a time."
                return
            }
            let secured = url.startAccessingSecurityScopedResource()
            defer { if secured { url.stopAccessingSecurityScopedResource() } }
            do {
                let resourceValues = try url.resourceValues(forKeys: [.fileSizeKey, .isDirectoryKey])
                guard resourceValues.isDirectory != true else {
                    throw FinanceStatementImporter.Error.inputTooLarge
                }
                if let fileSize = resourceValues.fileSize,
                   fileSize > FinanceStatementImporter.maximumInputBytes {
                    throw FinanceStatementImporter.Error.inputTooLarge
                }
                let data = try Self.readBoundedData(
                    from: url,
                    maximumBytes: FinanceStatementImporter.maximumInputBytes
                )
                let parsedResult = try FinanceStatementImporter.parseCSV(data: data)
                let inspection = try FinanceStatementImporter.inspectCSV(data: data)
                pendingSourceData = data
                pendingInspection = inspection
                pendingHeaderColumns = try Self.headerColumnNames(
                    data: data,
                    inspection: inspection,
                    recordIndex: inspection.headerRecordIndex
                )
                pendingSessionID = UUID()

                switch inspection.mappingEligibility.state {
                case .known:
                    pendingResult = parsedResult
                    if !parsedResult.transactions.isEmpty {
                        pendingPreparedImport = try FinanceStatementImporter.prepareKnownImport(
                            result: parsedResult,
                            inspection: inspection,
                            sessionID: pendingSessionID!,
                            revision: importGeneration
                        )
                    }
                case .requiresMapping:
                    // The legacy parser may be able to guess generic columns,
                    // but those rows are not trusted until the user chooses
                    // an explicit mapping. Keep the preview honest.
                    pendingResult = FinanceImportResult(
                        transactions: [],
                        skippedRowCount: 0,
                        detectedSource: .genericCSV,
                        dataRowCount: inspection.dataRowCount,
                        headerRecognized: inspection.headerRecordIndex != nil,
                        institutionDetection: inspection.originalDetection
                    )
                case .blocked:
                    pendingResult = FinanceImportResult(
                        transactions: [],
                        skippedRowCount: inspection.dataRowCount,
                        detectedSource: .genericCSV,
                        dataRowCount: inspection.dataRowCount,
                        headerRecognized: inspection.headerRecordIndex != nil,
                        diagnostics: (0..<inspection.dataRowCount).map {
                            FinanceImportDiagnostic(
                                rowNumber: (inspection.headerRecordIndex ?? 0) + 2 + $0,
                                reason: .unrecognizedHeader
                            )
                        },
                        institutionDetection: inspection.originalDetection
                    )
                }

                if requiresExplicitMapping {
                    statusMessage = "Choose the statement columns before any rows can be saved."
                } else if mappingIsBlocked {
                    statusMessage = "This export is recognized as an unsupported format and cannot be imported as a bank statement."
                } else if pendingResult?.headerRecognized == false {
                    statusMessage = "No date and amount header was recognized; no columns were guessed."
                } else if pendingResult?.transactions.isEmpty == true {
                    statusMessage = "The statement was read, but no valid EUR transactions were found."
                }
            } catch FinanceStatementImporter.Error.inputTooLarge {
                errorMessage = "The CSV is larger than the 5 MB import limit."
            } catch FinanceStatementImporter.Error.unsupportedEncoding {
                errorMessage = "The CSV encoding is not supported. Export it as UTF-8 or UTF-16 text."
            } catch {
                errorMessage = "The selected file could not be read as text."
            }
        }
    }

    /// Reads at most one byte beyond the importer limit. The metadata check in
    /// `handlePickedFile` is only an early rejection; this second check closes
    /// the growth/replacement race before any parser receives the bytes.
    private static func readBoundedData(from url: URL, maximumBytes: Int) throws -> Data {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }

        var data = Data()
        data.reserveCapacity(min(maximumBytes, boundedReadChunkSize))
        while data.count <= maximumBytes {
            let remaining = maximumBytes + 1 - data.count
            guard remaining > 0 else { break }
            let chunk = try handle.read(upToCount: min(remaining, boundedReadChunkSize)) ?? Data()
            if chunk.isEmpty { break }
            data.append(chunk)
        }
        guard data.count <= maximumBytes else {
            throw FinanceStatementImporter.Error.inputTooLarge
        }
        return data
    }

    /// Uses the shared bounded indexed-header API. Raw labels stay transient;
    /// only the selected record index and the mapping's resulting fingerprint
    /// cross the mapping boundary.
    private static func headerColumnNames(
        data: Data,
        inspection: FinanceImportInspection,
        recordIndex: Int?
    ) throws -> [String] {
        guard let recordIndex,
              inspection.candidateHeaderRecordIndices.contains(recordIndex) else {
            throw FinanceImportMappingError.missingHeader
        }
        guard let candidate = try FinanceStatementImporter.headerCandidates(data: data, inspection: inspection)
            .first(where: { $0.recordIndex == recordIndex }) else {
            throw FinanceImportMappingError.missingHeader
        }
        return candidate.labels
    }

    fileprivate func headerColumns(for recordIndex: Int) -> [String]? {
        guard let data = pendingSourceData, let inspection = pendingInspection else { return nil }
        return try? Self.headerColumnNames(data: data, inspection: inspection, recordIndex: recordIndex)
    }

    @discardableResult
    func confirmImport(_ transactions: [FinanceImportedTransaction]) async -> FinanceImportConfirmationResult {
        guard pendingPreparedImport != nil else {
            return .failed(message: "This import preview is no longer available. Choose the file again.")
        }
        return await confirmPreparedImport(transactions)
    }

    /// Secure production commit path. The caller can edit categories, but it
    /// cannot replace importer-owned source rows, IDs, detection or
    /// provenance. The store receives the immutable prepared preview and the
    /// validated category-only delta.
    @discardableResult
    func confirmPreparedImport(_ editedTransactions: [FinanceImportedTransaction]) async -> FinanceImportConfirmationResult {
        guard let prepared = pendingPreparedImport, store != nil else {
            return .failed(message: "This import preview is no longer available. Choose the file again.")
        }
        guard !isImporting else {
            return .failed(message: "An import is already being saved. Keep this preview open and wait for it to finish.")
        }
        guard editedTransactions.count == prepared.transactions.count else {
            return .failed(message: "The import preview changed. Review it and retry.")
        }

        do {
            let originalByID = Dictionary(uniqueKeysWithValues: prepared.transactions.map { ($0.id, $0) })
            guard Set(editedTransactions.map(\.id)) == Set(originalByID.keys) else {
                throw FinanceImportedTransactionStoreError.invalidEnvelope
            }
            var edits: [FinanceImportCategoryEdit] = []
            edits.reserveCapacity(editedTransactions.count)
            for edited in editedTransactions {
                guard let original = originalByID[edited.id],
                      edited.hasSameSourceObservation(as: original) else {
                    throw FinanceImportedTransactionStoreError.invalidEnvelope
                }
                let editedCategory = try edited.category.map { rawValue in
                    guard let category = FinanceTransactionCategory(rawValue: rawValue) else {
                        throw FinanceImportedTransactionStoreError.invalidEnvelope
                    }
                    return category
                }
                if edited.category != original.category {
                    edits.append(FinanceImportCategoryEdit(transactionID: edited.id, category: editedCategory))
                }
            }
            return await commitPreparedImport(prepared, categoryEdits: edits)
        } catch {
            return .failed(message: "The import preview changed. Review it and retry.")
        }
    }

    private func commitPreparedImport(
        _ prepared: FinancePreparedImport,
        categoryEdits: [FinanceImportCategoryEdit]
    ) async -> FinanceImportConfirmationResult {
        importGeneration &+= 1
        let generation = importGeneration
        isImporting = true
        defer {
            if generation == importGeneration { isImporting = false }
        }
        do {
            try Task.checkCancellation()
            let result = try await preparedImportOperation(prepared, categoryEdits)
            guard generation == importGeneration else {
                return .failed(message: "This import result is stale. The editable preview remains available; retry it.")
            }
            errorMessage = nil
            clearPendingImport()
            refreshAfterLocalMutation()
            statusMessage = Self.importStatusMessage(for: result)
            return .saved
        } catch is CancellationError {
            guard generation == importGeneration else {
                return .failed(message: "This import result is stale. The editable preview remains available; retry it.")
            }
            return .failed(message: "Import cancelled. The preview remains available; retry when ready.")
        } catch {
            guard generation == importGeneration else {
                return .failed(message: "This import result is stale. The editable preview remains available; retry it.")
            }
            handleLocalError(error)
            return .failed(message: Self.localErrorMessage(for: error))
        }
    }

    func applyMapping(_ draft: FinanceImportMappingDraft) {
        guard !isImporting,
              let data = pendingSourceData,
              let inspection = pendingInspection,
              let sessionID = pendingSessionID else {
            errorMessage = "This import preview is no longer available. Choose the file again."
            return
        }
        do {
            guard let headerRecordIndex = draft.headerRecordIndex else {
                throw FinanceImportMappingError.missingHeader
            }
            let headerColumns = try Self.headerColumnNames(
                data: data,
                inspection: inspection,
                recordIndex: headerRecordIndex
            )
            var boundDraft = draft
            boundDraft.delimiter = inspection.delimiter
            let mapping = try FinanceImportMapping(draft: boundDraft, headerColumns: headerColumns)
            let prepared = try FinanceStatementImporter.prepareMappedImport(
                data: data,
                inspection: inspection,
                mapping: mapping,
                sessionID: sessionID,
                revision: importGeneration
            )
            pendingPreparedImport = prepared
            pendingResult = prepared.result
            errorMessage = nil
            statusMessage = prepared.transactions.isEmpty
                ? "The mapping is valid, but no rows contain a valid EUR transaction."
                : "Mapping applied. Review the rows before saving."
        } catch FinanceImportMappingError.unsupportedProfile {
            errorMessage = "This export matches an unsupported institution format and cannot be enabled by mapping."
        } catch FinanceImportMappingError.mappingNotRequired {
            errorMessage = "This export is already a verified layout. Choose the file again to refresh its preview."
        } catch FinanceImportMappingError.stalePreview {
            errorMessage = "The file changed while it was being reviewed. Choose it again."
        } catch {
            errorMessage = "That mapping is incomplete or does not match the selected statement."
        }
    }

    /// Drops only the importer-produced preview. The source bytes, inspection,
    /// header choices, session, and persisted account choices remain available
    /// so the user can correct a mapping without selecting the file again.
    func beginMappingEdit() {
        guard !isImporting,
              canEditMapping,
              let inspection = pendingInspection else { return }
        importGeneration &+= 1
        pendingPreparedImport = nil
        pendingResult = FinanceImportResult(
            transactions: [],
            skippedRowCount: 0,
            detectedSource: .genericCSV,
            dataRowCount: inspection.dataRowCount,
            headerRecognized: inspection.headerRecordIndex != nil,
            institutionDetection: inspection.originalDetection
        )
        errorMessage = nil
        statusMessage = "Adjust the statement columns before reviewing the rows."
    }

    func discardPending() {
        guard !isImporting else { return }
        importGeneration &+= 1
        clearPendingImport()
        statusMessage = nil
    }

    private func clearPendingImport() {
        pendingResult = nil
        pendingSourceData = nil
        pendingInspection = nil
        pendingHeaderColumns = []
        pendingPreparedImport = nil
        pendingSessionID = nil
    }

    private static func importStatusMessage(for result: FinanceImportSaveResult) -> String {
        var parts: [String] = []
        if result.insertedCount > 0 { parts.append("imported \(result.insertedCount) new rows") }
        if result.updatedCount > 0 { parts.append("updated \(result.updatedCount) corrected rows") }
        if result.duplicateCount > 0 { parts.append("skipped \(result.duplicateCount) unchanged duplicates") }
        return parts.isEmpty ? "No source changes were found." : parts.joined(separator: "; ") + "."
    }

    func delete(id: UUID) {
        guard let store else { return }
        do {
            try store.remove(id: id)
            refreshAfterLocalMutation()
        } catch {
            handleLocalError(error)
        }
    }

    func setCategory(_ category: FinanceTransactionCategory?, for id: UUID) {
        guard let store else { return }
        do {
            if category == nil {
                try store.clearCategoryOverride(for: id)
            } else {
                try store.setCategory(category, for: id)
            }
            refreshAfterLocalMutation()
        } catch {
            handleLocalError(error)
        }
    }

    func clearAll() {
        guard let store else { return }
        do {
            try store.clearAll()
            refreshAfterLocalMutation()
            statusMessage = FinanceImportCopy.clearAllSuccess
        } catch {
            handleLocalError(error)
        }
    }

    func synchronize() async {
        guard !isSynchronizing else { return }
        guard let store else {
            syncState = .unavailable
            syncMessage = "Imported Finance storage is unavailable. Local rows remain separate on this device."
            return
        }

        syncGeneration += 1
        let generation = syncGeneration
        isSynchronizing = true
        syncState = .syncing
        syncMessage = nil

        do {
            try Task.checkCancellation()
            let result = try await syncOperation(store)
            try Task.checkCancellation()
            guard generation == syncGeneration else { return }

            isSynchronizing = false
            do {
                let transactions = try store.all()
                let status = try store.syncStatus()
                savedTransactions = transactions
                currentSyncStatus = status
                lastConfirmedRemoteRevision = result.snapshot.revision
                syncState = Self.presentationState(for: status)
                if status.blockedEntryCount > 0 {
                    syncMessage = "The gateway confirmed revision \(result.snapshot.revision), but blocked local changes remain."
                } else {
                    syncMessage = "The gateway confirmed revision \(result.snapshot.revision)."
                }
                onImportedStateChanged?()
            } catch {
                syncState = .error
                syncMessage = "The gateway replied, but imported Finance data could not be refreshed."
                // Synchronization succeeded, but the authoritative local
                // snapshot could not be read. Notify derived consumers once
                // so they clear current evidence instead of retaining an old
                // recurring assessment as fresh.
                onImportedStateChanged?()
            }
        } catch is CancellationError {
            guard generation == syncGeneration else { return }
            isSynchronizing = false
            refreshLocalState()
            syncMessage = "Sync cancelled. Local rows were kept."
        } catch {
            guard generation == syncGeneration else { return }
            isSynchronizing = false
            refreshLocalState()
            if case .blocked = syncState {
                // Preserve the actionable blocked state reported by the local
                // store while exposing the transport failure in the message.
            } else {
                syncState = .error
            }
            syncMessage = Self.syncErrorMessage(for: error)
        }
    }

    private func refreshAfterLocalMutation() {
        syncMessage = nil
        refreshLocalState()
    }

    private func refreshLocalState() {
        guard let store else {
            currentSyncStatus = nil
            syncState = .unavailable
            return
        }
        do {
            let transactions = try store.all()
            let mappings = try store.importMappings()
            let status = try store.syncStatus()
            savedTransactions = transactions
            availableAccountChoices = Self.accountChoices(from: mappings, transactions: transactions)
            currentSyncStatus = status
            syncState = isSynchronizing ? .syncing : Self.presentationState(for: status)
            onImportedStateChanged?()
        } catch {
            currentSyncStatus = nil
            syncState = .error
            syncMessage = "Imported Finance data could not be refreshed."
            errorMessage = Self.localErrorMessage(for: error)
            // A failed refresh invalidates every consumer of the imported
            // snapshot. The recurring view must clear current evidence and
            // expose its durable overrides as stale instead of retaining the
            // previous assessment as if it were still current.
            onImportedStateChanged?()
        }
    }

    func recurringSnapshot() throws -> (
        transactions: [FinanceImportedTransaction],
        batches: [FinanceImportBatchProvenance]
    ) {
        guard let store else {
            throw FinanceImportedTransactionStoreError.applicationSupportUnavailable
        }
        return (try store.all(), try store.importBatches())
    }

    private static func accountChoices(
        from mappings: [FinanceImportMapping],
        transactions: [FinanceImportedTransaction]
    ) -> [FinanceImportAccountChoice] {
        var choicesByID: [UUID: FinanceImportAccountChoice] = [:]
        var orderedIDs: [UUID] = []
        orderedIDs.reserveCapacity(mappings.count + transactions.count)

        for mapping in mappings {
            let identity = mapping.account.identity
            guard choicesByID[identity.id] == nil else { continue }
            choicesByID[identity.id] = FinanceImportAccountChoice(
                id: identity.id,
                localLabel: identity.label
            )
            orderedIDs.append(identity.id)
        }

        for transaction in transactions {
            guard transaction.identityScheme == .mappedV3,
                  let mappedIdentity = transaction.mappedIdentity,
                  choicesByID[mappedIdentity.accountID] == nil else { continue }
            choicesByID[mappedIdentity.accountID] = FinanceImportAccountChoice(
                id: mappedIdentity.accountID,
                localLabel: nil
            )
            orderedIDs.append(mappedIdentity.accountID)
        }

        return orderedIDs.compactMap { choicesByID[$0] }
    }

    private func handleLocalError(_ error: Error) {
        syncState = .error
        syncMessage = "Imported Finance changes could not be saved."
        errorMessage = Self.localErrorMessage(for: error)
    }

    private static func presentationState(for status: FinanceImportedSyncStatus) -> FinanceImportSyncState {
        if status.blockedEntryCount > 0 {
            return .blocked(entryCount: status.blockedEntryCount, reasons: status.blockedReasons)
        }
        if status.pendingEntryCount > 0 {
            return .pending(entryCount: status.pendingEntryCount, operationCount: status.pendingOperationCount)
        }
        return .idle
    }

    private static func localErrorMessage(for error: Error) -> String {
        guard let error = error as? FinanceImportedTransactionStoreError else {
            return "Imported Finance storage could not be read or saved."
        }
        switch error {
        case .applicationSupportUnavailable, .readFailed, .invalidEnvelope:
            return "Imported Finance storage is unavailable or invalid."
        case .migrationRequired:
            return "Older generic Finance imports need one-time reconciliation before another mapped statement can be saved."
        case .transactionNotFound:
            return "That imported row is no longer available. Refresh the list and try again."
        case .stateTooLarge:
            return "The imported Finance ledger has reached its safe size limit."
        case .syncOutboxFull:
            return "Local changes could not be queued for private sync."
        default:
            return "Imported Finance changes could not be saved."
        }
    }

    private static func syncErrorMessage(for error: Error) -> String {
        if error is CancellationError {
            return "Sync cancelled. Local rows were kept."
        }
        if error is FinanceImportFixtureSyncError {
            return "Private sync is disabled in visual fixtures. Local rows were kept."
        }
        if let error = error as? TailscaleSyncError {
            switch error {
            case .notConfigured, .invalidServerURL, .gatewayNotConfigured:
                return "Private sync is not configured. Check the approved LifeOS gateway, then retry."
            case .invalidResponse:
                return "The private sync gateway returned an unusable response. Local rows were kept."
            case .httpError:
                return "The private sync gateway is unavailable right now. Local rows were kept; retry later."
            case .responseTooLarge, .requestTooLarge:
                return "The private sync exchange exceeded its safety limit. Local rows were kept."
            default:
                return "The private sync gateway could not be reached. Local rows were kept; retry later."
            }
        }
        if let error = error as? FinanceImportedSyncError {
            switch error {
            case .conflict:
                return "Sync is blocked by a remote change. Your local rows are safe; review them and retry."
            case .remoteSnapshotRewound, .remoteSnapshotETagMismatch, .invalidRevision, .malformedETag:
                return "The gateway returned conflicting revision data. Local rows were kept; retry later."
            case .requestTooLarge, .responseTooLarge:
                return "The private sync exchange exceeded its safety limit. Local rows were kept."
            case .httpError:
                return "The private sync gateway is unavailable right now. Local rows were kept; retry later."
            default:
                return "The private sync gateway could not complete this exchange. Local rows were kept; retry later."
            }
        }
        if let error = error as? FinanceImportedTransactionStoreError {
            switch error {
            case .syncRetryExpired, .syncAttemptsExhausted:
                return "A local sync change needs review before it can be retried. Your rows were kept."
            case .syncSnapshotRewound, .syncSnapshotETagMismatch:
                return "The gateway returned conflicting revision data. Local rows were kept; retry later."
            case .syncPayloadTooLarge, .syncOutboxFull:
                return "Local changes could not fit in the bounded private sync queue. Your rows were kept."
            default:
                return "Private sync could not complete. Local rows were kept; retry later."
            }
        }
        if let error = error as? URLError,
           [.notConnectedToInternet, .networkConnectionLost, .cannotFindHost, .cannotConnectToHost, .timedOut].contains(error.code) {
            return "The private sync gateway is unavailable right now. Check the network and retry."
        }
        return "Private sync could not complete. Local rows were kept; retry later."
    }
}

/// A fixture-only persistence boundary for the Finance import card. The
/// configuration owns one unique temporary directory and both stores for the
/// lifetime of the card state. Production never constructs this value, so its
/// existing Application Support defaults remain unchanged.
struct FinanceImportPersistenceConfiguration {
    let importedTransactionStore: FinanceImportedTransactionStore?
    let budgetStore: FinanceBudgetStore?
    let recurringPaymentStore: FinanceRecurringPaymentStore?
    let directoryURL: URL?
    let syncOperation: FinanceImportViewModel.SyncOperation

    static func makeVisualFixtures(fileManager: FileManager = .default) -> Self {
        let directory = fileManager.temporaryDirectory
            .appendingPathComponent("LifeOS", isDirectory: true)
            .appendingPathComponent("FinanceFixtures", isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let importedURL = directory.appendingPathComponent(
            FinanceImportedTransactionStore.fileName,
            isDirectory: false
        )
        let budgetURL = directory.appendingPathComponent(
            FinanceBudgetStore.fileName,
            isDirectory: false
        )
        let recurringURL = directory.appendingPathComponent(
            FinanceRecurringPaymentStore.fileName,
            isDirectory: false
        )
        let importedStore = try? FinanceImportedTransactionStore(url: importedURL, fileManager: fileManager)
        let budgetStore = try? FinanceBudgetStore(url: budgetURL, fileManager: fileManager)
        let recurringPaymentStore = try? FinanceRecurringPaymentStore(url: recurringURL, fileManager: fileManager)

        return Self(
            importedTransactionStore: importedStore,
            budgetStore: budgetStore,
            recurringPaymentStore: recurringPaymentStore,
            directoryURL: directory,
            syncOperation: { _ in
                // A visual fixture can exercise the sync button's failure
                // state, but it must never construct a client or transmit a
                // request to the user's gateway.
                throw FinanceImportFixtureSyncError.disabled
            }
        )
    }
}

private enum FinanceImportFixtureSyncError: Error {
    case disabled
}

/// Owns the Finance import card's long-lived dependencies. Keeping this
/// object behind `@StateObject` makes the fixture directory and its stores
/// stable across SwiftUI body reconstruction.
@MainActor
final class FinanceImportCardState: ObservableObject {
    let usesVisualFixtures: Bool
    let persistence: FinanceImportPersistenceConfiguration?
    let model: FinanceImportViewModel
    let recurringPayments: FinanceRecurringPaymentsViewModel
    private var modelObservation: AnyCancellable?

    init(usesVisualFixtures: Bool) {
        self.usesVisualFixtures = usesVisualFixtures
        if usesVisualFixtures {
            let configuration = FinanceImportPersistenceConfiguration.makeVisualFixtures()
            persistence = configuration
            model = FinanceImportViewModel(
                store: configuration.importedTransactionStore,
                syncOperation: configuration.syncOperation
            )
            recurringPayments = FinanceRecurringPaymentsViewModel(store: configuration.recurringPaymentStore)
        } else {
            persistence = nil
            // Preserve the existing production defaults exactly: the model
            // resolves the Application Support store and live sync operation
            // through its zero-argument initializer.
            model = FinanceImportViewModel()
            recurringPayments = FinanceRecurringPaymentsViewModel(store: try? FinanceRecurringPaymentStore())
        }

        modelObservation = model.objectWillChange.sink { [weak self] _ in
            self?.objectWillChange.send()
        }
        model.onImportedStateChanged = { [weak self] in
            self?.refreshRecurringPayments()
        }
        refreshRecurringPayments()
    }

    private func refreshRecurringPayments() {
        do {
            let snapshot = try model.recurringSnapshot()
            recurringPayments.refresh(transactions: snapshot.transactions, batches: snapshot.batches)
        } catch {
            recurringPayments.presentSnapshotReadError(error)
        }
    }
}

/// A small card on the Finance screen offering CSV import. Self-contained:
/// it owns its own view model and store and never reads or mutates anything
/// from `FinanceCoordinator` or `FinanceView`'s scroll/route/accounts state.
struct FinanceImportCard: View {
    @StateObject private var state: FinanceImportCardState
    @State private var isShowingImportedList = false
    @State private var isShowingImportedDetails = false

    init(usesVisualFixtures: Bool = false) {
        _state = StateObject(wrappedValue: FinanceImportCardState(usesVisualFixtures: usesVisualFixtures))
    }

    private var model: FinanceImportViewModel { state.model }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .center, spacing: 10) {
                LifeOSIcon(.importDocument)
                    .foregroundStyle(LifeOSTokens.Module.finance)
                    .frame(width: 18, height: 18)
                VStack(alignment: .leading, spacing: 3) {
                    Text("Import statement")
                        .lifeOSTypography(.cardTitle)
                    Text("Manual CSV · stored on this device")
                        .lifeOSTypography(.metadata)
                        .foregroundStyle(LifeOSTokens.tertiaryText)
                }
                Spacer(minLength: 8)
                Button {
                    model.isImporterPresented = true
                } label: {
                    Label("Import CSV", systemImage: "plus")
                }
                .buttonStyle(LifeOSButtonStyle(.secondary))
                .disabled(!model.canImport)
                .accessibilityIdentifier("finance-import-csv-button")
            }

            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(model.savedTransactions.isEmpty ? "No imported rows" : "\(model.savedTransactions.count) imported rows")
                    .lifeOSTypography(.metadata)
                    .foregroundStyle(LifeOSTokens.tertiaryText)
                Button {
                    isShowingImportedList = true
                } label: {
                    Text("View rows")
                        .lifeOSTypography(.metadata)
                        .foregroundStyle(LifeOSTokens.accent)
                }
                .buttonStyle(.plain)
                .disabled(model.savedTransactions.isEmpty)
                .accessibilityIdentifier("finance-imported-transactions-button")
                Spacer(minLength: 0)
            }

            FinanceImportSyncSection(model: model)

            if let statusMessage = model.statusMessage {
                Label(statusMessage, systemImage: "info.circle")
                    .lifeOSTypography(.metadata)
                    .foregroundStyle(LifeOSTokens.secondaryText)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("finance-import-status")
            }

            Text("Local first: imported rows stay on this device. Optional private sync mirrors this ledger to your LifeOS gateway and remains separate from connected-account observations.")
                .lifeOSTypography(.metadata)
                .foregroundStyle(LifeOSTokens.tertiaryText)
                .fixedSize(horizontal: false, vertical: true)

            FinanceRecurringPaymentsView(viewModel: state.recurringPayments)

            if !model.savedTransactions.isEmpty {
                DisclosureGroup(isExpanded: $isShowingImportedDetails) {
                    VStack(alignment: .leading, spacing: 12) {
                        FinanceSpendingByCategorySection(transactions: model.savedTransactions)
                        Divider().overlay(LifeOSTokens.hairlineBorder)
                        FinanceBudgetsSection(
                            transactions: model.savedTransactions,
                            store: state.persistence?.budgetStore,
                            usesVisualFixtures: state.usesVisualFixtures
                        )
                        if model.savedTransactions.contains(where: { $0.isInvestmentOrder }) {
                            Divider().overlay(LifeOSTokens.hairlineBorder)
                            FinanceImportedInvestmentsSection(transactions: model.savedTransactions)
                        }
                    }
                    .padding(.top, 8)
                } label: {
                    HStack {
                        Text("Imported analysis")
                            .lifeOSTypography(.button)
                        Spacer()
                        Text(isShowingImportedDetails ? "Hide" : "Show")
                            .lifeOSTypography(.metadata)
                            .foregroundStyle(LifeOSTokens.accent)
                    }
                }
                .tint(LifeOSTokens.accent)
            }
        }
        .padding(18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .flatCard()
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("finance-import-card")
        .fileImporter(
            isPresented: Binding(
                get: { model.isImporterPresented },
                set: { model.isImporterPresented = $0 }
            ),
            allowedContentTypes: [.commaSeparatedText, .plainText],
            allowsMultipleSelection: false
        ) { result in
            model.handlePickedFile(result)
        }
        .sheet(item: Binding(
            get: { model.pendingResult.map(FinanceImportPreviewSheetItem.init) },
            set: { newValue in if newValue == nil { model.discardPending() } }
        )) { item in
            FinanceImportPreviewView(
                model: model,
                result: item.result,
                onConfirm: { transactions in await model.confirmImport(transactions) },
                onApplyMapping: model.applyMapping,
                onCancel: model.discardPending
            )
        }
            .sheet(isPresented: $isShowingImportedList) {
            FinanceImportedTransactionsListView(
                model: model,
                recurringViewModel: state.recurringPayments
            )
        }
        .alert("Import statement", isPresented: Binding(
            get: { model.errorMessage != nil },
            set: { if !$0 { model.errorMessage = nil } }
        )) {
            Button("OK") {}
        } message: {
            Text(model.errorMessage ?? "")
        }
    }
}

private struct FinanceImportSyncSection: View {
    @ObservedObject var model: FinanceImportViewModel

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Divider().overlay(LifeOSTokens.hairlineBorder)

            HStack(alignment: .top, spacing: 10) {
                LifeOSIcon(statusIcon)
                    .foregroundStyle(statusColor)
                    .frame(width: 18, height: 18)
                VStack(alignment: .leading, spacing: 3) {
                    Text(statusTitle)
                        .lifeOSTypography(.button)
                    Text(statusDetail)
                        .lifeOSTypography(.metadata)
                        .foregroundStyle(LifeOSTokens.tertiaryText)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 8)
                if model.isSynchronizing {
                    ProgressView()
                        .controlSize(.small)
                        .tint(LifeOSTokens.accent)
                        .accessibilityLabel("Syncing")
                }
            }
            .accessibilityElement(children: .combine)
            .accessibilityLabel("Private Finance sync")
            .accessibilityValue(statusDetail)

            if let revision = model.lastConfirmedRemoteRevision {
                Text("Last gateway confirmation · revision \(revision)")
                    .lifeOSTypography(.metadata)
                    .foregroundStyle(LifeOSTokens.secondaryText)
                    .accessibilityIdentifier("finance-import-last-remote-revision")
            }

            if let syncMessage = model.syncMessage, !isBlocked {
                Label(syncMessage, systemImage: messageIcon)
                    .lifeOSTypography(.metadata)
                    .foregroundStyle(messageColor)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("finance-import-sync-message")
            }

            Button {
                Task { await model.synchronize() }
            } label: {
                HStack(spacing: 8) {
                    LifeOSIcon(.refresh)
                        .frame(width: 16, height: 16)
                    Text(model.syncActionTitle)
                    Spacer(minLength: 0)
                }
            }
            .buttonStyle(LifeOSButtonStyle(.primary))
            .disabled(!model.canSynchronize)
            .accessibilityIdentifier("finance-import-sync-button")
            .accessibilityHint("Mirrors the local manual import ledger to the approved private LifeOS gateway.")
        }
        .animation(LifeOSMotion.reduceMotion ? nil : LifeOSMotion.snappy, value: model.syncState)
        .accessibilityIdentifier("finance-import-sync-section")
    }

    private var isBlocked: Bool {
        if case .blocked = model.syncState { return true }
        return false
    }

    private var statusTitle: String {
        switch model.syncState {
        case .idle:
            return model.lastConfirmedRemoteRevision == nil ? "Ready for private sync" : "Up to date"
        case .pending:
            return "Changes waiting"
        case .blocked:
            return "Sync blocked"
        case .syncing:
            return "Syncing to LifeOS"
        case .unavailable:
            return "Sync unavailable"
        case .error:
            return "Sync needs attention"
        }
    }

    private var statusDetail: String {
        switch model.syncState {
        case .idle:
            return model.lastConfirmedRemoteRevision == nil
                ? "Rows are local until you choose to mirror them to the private gateway."
                : "The private gateway confirmed the latest local ledger."
        case .pending(let entries, let operations):
            return "\(entries) pending change\(entries == 1 ? "" : "s") · \(operations) operation\(operations == 1 ? "" : "s") waiting to be mirrored."
        case .blocked(let entries, let reasons):
            return "\(entries) change\(entries == 1 ? "" : "s") need review. Your local rows are safe; review them and retry\(reasonSummary(reasons))"
        case .syncing:
            return "Sending the local import ledger through the approved private gateway."
        case .unavailable:
            return "The local ledger or approved private gateway is unavailable."
        case .error:
            return "The last exchange did not complete. Your local rows were kept; retry when ready."
        }
    }

    private var statusIcon: LifeOSIconName {
        switch model.syncState {
        case .idle: model.lastConfirmedRemoteRevision == nil ? .refresh : .verified
        case .pending, .syncing: .refresh
        case .blocked, .error: .warning
        case .unavailable: .security
        }
    }

    private var statusColor: Color {
        switch model.syncState {
        case .idle:
            model.lastConfirmedRemoteRevision == nil ? LifeOSTokens.secondaryText : LifeOSTokens.success
        case .pending, .syncing: LifeOSTokens.accent
        case .blocked, .error: LifeOSTokens.warning
        case .unavailable: LifeOSTokens.tertiaryText
        }
    }

    private var messageIcon: String {
        isBlocked ? "exclamationmark.triangle" : "info.circle"
    }

    private var messageColor: Color {
        switch model.syncState {
        case .error, .blocked: LifeOSTokens.warning
        default: LifeOSTokens.secondaryText
        }
    }

    private func reasonSummary(_ reasons: [FinanceImportedSyncBlockReason]) -> String {
        guard !reasons.isEmpty else { return "" }
        let names = reasons.map { reason -> String in
            switch reason {
            case .conflict: "remote conflict"
            case .retryExpired: "retry expired"
            case .attemptsExhausted: "retry limit reached"
            case .payloadTooLarge: "payload too large"
            case .invalidEnvelope: "invalid local envelope"
            }
        }
        return ". Reason: \(names.joined(separator: ", "))."
    }
}

/// `Identifiable` wrapper so `FinanceImportResult` (a plain struct) can drive
/// a `.sheet(item:)` presentation.
private struct FinanceImportPreviewSheetItem: Identifiable {
    let id = UUID()
    let result: FinanceImportResult
}

/// Shows parsed-count, skipped-count, and the first rows before the user
/// commits to persisting anything. Nothing is written to the durable store
/// until the user explicitly taps Import.
private struct FinanceImportPreviewView: View {
    @ObservedObject var model: FinanceImportViewModel
    let result: FinanceImportResult
    let onConfirm: ([FinanceImportedTransaction]) async -> FinanceImportConfirmationResult
    let onApplyMapping: (FinanceImportMappingDraft) -> Void
    let onCancel: () -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var workingTransactions: [FinanceImportedTransaction]
    @State private var confirmationError: String?
    @State private var isSaving = false
    @State private var draftRevision = 0
    @State private var activeSaveToken: UUID?

    init(
        model: FinanceImportViewModel,
        result: FinanceImportResult,
        onConfirm: @escaping ([FinanceImportedTransaction]) async -> FinanceImportConfirmationResult,
        onApplyMapping: @escaping (FinanceImportMappingDraft) -> Void,
        onCancel: @escaping () -> Void
    ) {
        self.model = model
        self.result = result
        self.onConfirm = onConfirm
        self.onApplyMapping = onApplyMapping
        self.onCancel = onCancel
        _workingTransactions = State(initialValue: result.transactions)
        _confirmationError = State(initialValue: nil)
    }

    private var displayedResult: FinanceImportResult {
        model.pendingResult ?? result
    }

    private var previewRows: [FinanceImportedTransaction] {
        Array(workingTransactions.prefix(20))
    }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    HStack {
                        Text("Parsed")
                        Spacer()
                        Text("\(displayedResult.transactions.count)")
                            .foregroundStyle(LifeOSTokens.success)
                            .fontWeight(.semibold)
                    }
                    HStack {
                        Text("Skipped (invalid rows)")
                        Spacer()
                        Text("\(displayedResult.skippedRowCount)")
                            .foregroundStyle(displayedResult.skippedRowCount > 0 ? LifeOSTokens.warning : LifeOSTokens.tertiaryText)
                            .fontWeight(.semibold)
                    }
                    HStack {
                        Text("Detected layout")
                        Spacer()
                        Text(displayedResult.detectedSource == .tradeRepublicCSV ? "Trade Republic" : "Generic CSV")
                            .foregroundStyle(LifeOSTokens.tertiaryText)
                    }
                    HStack {
                        Text("Rows in file")
                        Spacer()
                        Text("\(displayedResult.dataRowCount)")
                            .foregroundStyle(LifeOSTokens.tertiaryText)
                    }
                    if displayedResult.investmentTransactionCount > 0 {
                        HStack {
                            Text("Investment orders")
                            Spacer()
                            Text("\(displayedResult.investmentTransactionCount)")
                                .foregroundStyle(LifeOSTokens.secondaryText)
                        }
                    }
                    if !displayedResult.diagnostics.isEmpty {
                        Text("Diagnostics identify only affected rows and never include statement contents.")
                            .lifeOSTypography(.metadata)
                            .foregroundStyle(LifeOSTokens.tertiaryText)
                    }
                }

                if model.mappingIsBlocked {
                    Section("Import unavailable") {
                        Label("Unsupported statement format", systemImage: "nosign")
                            .foregroundStyle(LifeOSTokens.warning)
                        Text("This export is recognized as an unsupported institution format. Mapping its columns cannot enable it as a bank statement.")
                            .lifeOSTypography(.metadata)
                            .foregroundStyle(LifeOSTokens.secondaryText)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                } else if model.showsMappingEditor {
                    Section("Choose columns") {
                        FinanceImportMappingEditor(
                            headers: model.mappingHeaderColumns,
                            headerRecordIndices: model.mappingHeaderRecordIndices,
                            selectedHeaderRecordIndex: model.mappingHeaderRecordIndex,
                            headerColumnsForRecord: { model.headerColumns(for: $0) },
                            accountChoices: model.availableAccountChoices,
                            onApply: onApplyMapping
                        )
                    }
                }

                if model.canEditMapping {
                    Section {
                        Button {
                            model.beginMappingEdit()
                        } label: {
                            Label("Edit mapping", systemImage: "slider.horizontal.3")
                        }
                        .disabled(isSaving)
                        Text("Review the statement with a different column interpretation. The current preview will be discarded until the new mapping is applied.")
                            .lifeOSTypography(.metadata)
                            .foregroundStyle(LifeOSTokens.tertiaryText)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }

                if !displayedResult.diagnostics.isEmpty {
                    Section("Import diagnostics") {
                        ForEach(Array(displayedResult.diagnostics.prefix(8).enumerated()), id: \.offset) { _, diagnostic in
                            HStack(spacing: 8) {
                                LifeOSIcon(.warning)
                                    .foregroundStyle(LifeOSTokens.warning)
                                    .frame(width: 14, height: 14)
                                Text("Row \(diagnostic.rowNumber): \(diagnostic.financeImportDisplayName)")
                                    .lifeOSTypography(.metadata)
                                    .foregroundStyle(LifeOSTokens.secondaryText)
                            }
                        }
                        if displayedResult.diagnostics.count > 8 {
                            Text("Showing the first 8 of \(displayedResult.diagnostics.count) skipped rows.")
                                .lifeOSTypography(.metadata)
                                .foregroundStyle(LifeOSTokens.tertiaryText)
                        }
                    }
                }

                if let confirmationError {
                    Section {
                        Label("Import was not saved", systemImage: "exclamationmark.triangle")
                            .foregroundStyle(LifeOSTokens.warning)
                        Text(confirmationError)
                            .lifeOSTypography(.metadata)
                            .foregroundStyle(LifeOSTokens.secondaryText)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }

                if displayedResult.transactions.isEmpty {
                    Section {
                        Text(model.requiresExplicitMapping
                             ? "The file has not been interpreted yet. Choose the columns above; no guessed rows can be imported."
                             : model.mappingIsBlocked
                             ? "No rows were imported because this institution format is not enabled for bank-statement import."
                             : model.showsMappingEditor
                             ? "No valid rows matched this mapping. Adjust the columns above and apply the mapping again."
                             : displayedResult.headerRecognized
                             ? "No valid EUR transactions were found in this file. Rows with unsupported currencies or malformed dates/amounts are not imported."
                             : "No date and amount header was recognized. No column order was guessed, so nothing was imported.")
                            .foregroundStyle(LifeOSTokens.tertiaryText)
                    }
                } else {
                    Section("Preview (first \(previewRows.count))") {
                        ForEach(previewRows) { transaction in
                            FinanceImportPreviewRow(
                                transaction: transaction,
                                isDisabled: isSaving,
                                onCategoryChange: { category in
                                    guard !isSaving else { return }
                                    guard let index = workingTransactions.firstIndex(where: { $0.id == transaction.id }) else { return }
                                    workingTransactions[index].category = category?.rawValue
                                    draftRevision &+= 1
                                    confirmationError = nil
                                }
                            )
                        }
                    }
                }
            }
            .navigationTitle("Review import")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") {
                        guard !isSaving else { return }
                        onCancel()
                        dismiss()
                    }
                    .disabled(isSaving)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Import") {
                        savePreview()
                    }
                    .disabled(workingTransactions.isEmpty || isSaving)
                    .overlay {
                        if isSaving {
                            ProgressView()
                                .controlSize(.small)
                                .tint(LifeOSTokens.accent)
                        }
                    }
                }
            }
            .interactiveDismissDisabled(isSaving)
            .onChange(of: model.pendingResult) { _, newValue in
                guard let newValue else { return }
                workingTransactions = newValue.transactions
                draftRevision &+= 1
                confirmationError = nil
            }
        }
    }

    private func savePreview() {
        guard !isSaving, !workingTransactions.isEmpty else { return }

        let token = UUID()
        let revision = draftRevision
        let payload = workingTransactions
        activeSaveToken = token
        isSaving = true
        confirmationError = nil

        Task { @MainActor in
            let outcome = await onConfirm(payload)
            guard activeSaveToken == token else { return }
            isSaving = false
            activeSaveToken = nil

            guard draftRevision == revision else {
                confirmationError = "The preview changed while it was being saved. Review it and retry."
                return
            }
            switch outcome {
            case .saved:
                confirmationError = nil
                dismiss()
            case .failed(let message):
                // Keep `workingTransactions` intact so the user can correct
                // or retry the exact editable payload after a failed write.
                confirmationError = message
            }
        }
    }
}

private struct FinanceImportMappingEditor: View {
    @State private var headers: [String]
    let headerRecordIndices: [Int]
    let headerColumnsForRecord: (Int) -> [String]?
    let accountChoices: [FinanceImportAccountChoice]
    let onApply: (FinanceImportMappingDraft) -> Void

    @State private var selectedHeaderRecordIndex: Int
    @State private var dateColumn: Int
    @State private var dateFormat: FinanceImportDateFormat = .yearMonthDay
    @State private var amountMode: AmountMode = .signed
    @State private var amountColumn: Int
    @State private var debitColumn: Int
    @State private var creditColumn: Int
    @State private var debitCreditConvention: FinanceImportDebitCreditConvention = .debitIsNegative
    @State private var decimalSeparator: FinanceImportDecimalSeparator = .dot
    @State private var groupingSeparator: FinanceImportGroupingSeparator = .none
    @State private var descriptionMode: DescriptionMode = .column
    @State private var descriptionColumn: Int
    @State private var currencyMode: CurrencyMode = .constantEUR
    @State private var currencyColumn: Int
    @State private var sourceAccountColumn: Int?
    @State private var providerIDColumn: Int?
    @State private var merchantColumn: Int?
    @State private var accountMode: AccountMode
    @State private var selectedAccountID: UUID?
    @State private var accountLabel = "Personal account"
    @State private var errorMessage: String?

    private enum AmountMode: String, CaseIterable, Identifiable {
        case signed
        case debitCredit
        var id: Self { self }
        var title: String { self == .signed ? "Signed amount" : "Debit + credit" }
    }

    private enum DescriptionMode: String, CaseIterable, Identifiable {
        case column
        case none
        var id: Self { self }
        var title: String { self == .column ? "Description column" : "No description" }
    }

    private enum CurrencyMode: String, CaseIterable, Identifiable {
        case constantEUR
        case column
        var id: Self { self }
        var title: String { self == .constantEUR ? "All rows are EUR" : "Currency column" }
    }

    private enum AccountMode: String, CaseIterable, Identifiable {
        case existing
        case new
        var id: Self { self }
        var title: String {
            switch self {
            case .existing: "Use saved account"
            case .new: "Create new account"
            }
        }
    }

    private struct ColumnDefaults {
        let date: Int
        let amount: Int
        let debit: Int
        let credit: Int
        let description: Int?
        let currency: Int
    }

    init(
        headers: [String],
        headerRecordIndices: [Int],
        selectedHeaderRecordIndex: Int?,
        headerColumnsForRecord: @escaping (Int) -> [String]?,
        accountChoices: [FinanceImportAccountChoice],
        onApply: @escaping (FinanceImportMappingDraft) -> Void
    ) {
        _headers = State(initialValue: headers)
        self.headerRecordIndices = headerRecordIndices
        self.headerColumnsForRecord = headerColumnsForRecord
        self.accountChoices = accountChoices
        self.onApply = onApply
        let defaults = Self.defaults(for: headers)
        _selectedHeaderRecordIndex = State(initialValue: selectedHeaderRecordIndex ?? headerRecordIndices.first ?? 0)
        _dateColumn = State(initialValue: defaults.date)
        _amountColumn = State(initialValue: defaults.amount)
        _debitColumn = State(initialValue: defaults.debit)
        _creditColumn = State(initialValue: defaults.credit)
        _descriptionColumn = State(initialValue: defaults.description ?? 0)
        _descriptionMode = State(initialValue: defaults.description == nil ? .none : .column)
        _currencyColumn = State(initialValue: defaults.currency)
        _sourceAccountColumn = State(initialValue: nil)
        _providerIDColumn = State(initialValue: nil)
        _merchantColumn = State(initialValue: nil)
        let defaultAccount = accountChoices.first
        _accountMode = State(initialValue: defaultAccount == nil ? .new : .existing)
        _selectedAccountID = State(initialValue: defaultAccount?.id)
        _accountLabel = State(initialValue: defaultAccount?.localLabel ?? (defaultAccount == nil ? "Personal account" : ""))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("This file needs a one-time interpretation. The choices are saved with the import receipt; raw CSV text is never persisted.")
                .lifeOSTypography(.metadata)
                .foregroundStyle(LifeOSTokens.secondaryText)
                .fixedSize(horizontal: false, vertical: true)

            if headers.isEmpty {
                Text("No usable header row was found.")
                    .lifeOSTypography(.metadata)
                    .foregroundStyle(LifeOSTokens.warning)
            } else {
                if !headerRecordIndices.isEmpty {
                    Picker("Header row", selection: $selectedHeaderRecordIndex) {
                        ForEach(headerRecordIndices, id: \.self) { recordIndex in
                            Text("Record \(recordIndex + 1)").tag(recordIndex)
                        }
                    }
                    .disabled(headerRecordIndices.count < 2)
                    Text("The selected record is used as the exact source header for this mapping.")
                        .lifeOSTypography(.metadata)
                        .foregroundStyle(LifeOSTokens.tertiaryText)
                        .fixedSize(horizontal: false, vertical: true)
                }
                mappingPicker("Date", selection: $dateColumn)
                Picker("Date format", selection: $dateFormat) {
                    ForEach(FinanceImportDateFormat.allCases, id: \.self) { format in
                        Text(format.rawValue).tag(format)
                    }
                }
                Picker("Amount", selection: $amountMode) {
                    ForEach(AmountMode.allCases) { mode in Text(mode.title).tag(mode) }
                }
                if amountMode == .signed {
                    mappingPicker("Amount column", selection: $amountColumn)
                } else {
                    mappingPicker("Debit column", selection: $debitColumn)
                    mappingPicker("Credit column", selection: $creditColumn)
                    Picker("Direction", selection: $debitCreditConvention) {
                        Text("Debit is outflow").tag(FinanceImportDebitCreditConvention.debitIsNegative)
                        Text("Credit is outflow").tag(FinanceImportDebitCreditConvention.creditIsNegative)
                    }
                }
                Picker("Decimal separator", selection: $decimalSeparator) {
                    Text("Dot · 1234.56").tag(FinanceImportDecimalSeparator.dot)
                    Text("Comma · 1234,56").tag(FinanceImportDecimalSeparator.comma)
                }
                Picker("Grouping", selection: $groupingSeparator) {
                    Text("None").tag(FinanceImportGroupingSeparator.none)
                    Text("Dot").tag(FinanceImportGroupingSeparator.dot)
                    Text("Comma").tag(FinanceImportGroupingSeparator.comma)
                    Text("Space").tag(FinanceImportGroupingSeparator.space)
                    Text("Non-breaking space").tag(FinanceImportGroupingSeparator.nonBreakingSpace)
                    Text("Narrow non-breaking space").tag(FinanceImportGroupingSeparator.narrowNonBreakingSpace)
                }
                Picker("Currency", selection: $currencyMode) {
                    ForEach(CurrencyMode.allCases) { mode in Text(mode.title).tag(mode) }
                }
                if currencyMode == .column {
                    mappingPicker("Currency column", selection: $currencyColumn)
                }
                Picker("Description", selection: $descriptionMode) {
                    ForEach(DescriptionMode.allCases) { mode in Text(mode.title).tag(mode) }
                }
                if descriptionMode == .column {
                    mappingPicker("Description column", selection: $descriptionColumn)
                }
                optionalMappingPicker("Provider ID", selection: $providerIDColumn)
                optionalMappingPicker("Merchant", selection: $merchantColumn)
                if accountChoices.isEmpty {
                    Text("Account identity · Create new account")
                        .lifeOSTypography(.metadata)
                        .foregroundStyle(LifeOSTokens.secondaryText)
                } else {
                    Picker("Account identity", selection: $accountMode) {
                        ForEach(AccountMode.allCases) { mode in
                            Text(mode.title).tag(mode)
                        }
                    }
                }
                if accountMode == .existing, !accountChoices.isEmpty {
                    Picker("Saved account", selection: $selectedAccountID) {
                        ForEach(accountChoices) { account in
                            Text(account.displayName).tag(Optional(account.id))
                        }
                    }
                    if let selectedAccount = selectedAccountChoice {
                        if let localLabel = selectedAccount.localLabel {
                            Text("Using \(localLabel)")
                                .lifeOSTypography(.metadata)
                                .foregroundStyle(LifeOSTokens.tertiaryText)
                        } else {
                            Text("This identity came from a synced mapped row. Add a private local label before applying the mapping.")
                                .lifeOSTypography(.metadata)
                                .foregroundStyle(LifeOSTokens.tertiaryText)
                                .fixedSize(horizontal: false, vertical: true)
                            TextField("Local account label", text: $accountLabel)
                                #if os(iOS)
                                .textInputAutocapitalization(.sentences)
                                #endif
                                .textFieldStyle(.roundedBorder)
                        }
                    }
                } else {
                    if accountChoices.isEmpty {
                        Text("No saved account identity exists yet. Create one explicitly for this statement.")
                            .lifeOSTypography(.metadata)
                            .foregroundStyle(LifeOSTokens.tertiaryText)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    TextField("Local account label", text: $accountLabel)
                        #if os(iOS)
                        .textInputAutocapitalization(.sentences)
                        #endif
                        .textFieldStyle(.roundedBorder)
                }
                optionalMappingPicker("Source account", selection: $sourceAccountColumn)
                Text("Optional columns default to None. Selecting a source account separates rows from one export into the saved account identity while keeping the source value out of local provenance.")
                    .lifeOSTypography(.metadata)
                    .foregroundStyle(LifeOSTokens.tertiaryText)
                    .fixedSize(horizontal: false, vertical: true)
                if let errorMessage {
                    Text(errorMessage)
                        .lifeOSTypography(.metadata)
                        .foregroundStyle(LifeOSTokens.warning)
                }
                Button("Apply mapping") {
                    apply()
                }
                .buttonStyle(LifeOSButtonStyle(.secondary))
                .disabled(headers.isEmpty)
            }
        }
        .onAppear { reconcileAccountSelection() }
        .onChange(of: accountChoices) { _, _ in reconcileAccountSelection() }
        .onChange(of: selectedAccountID) { _, _ in updateAccountLabelForSelection(resetSyncedLabel: true) }
        .onChange(of: accountMode) { _, newMode in
            if newMode == .existing { updateAccountLabelForSelection(resetSyncedLabel: true) }
        }
        .onChange(of: selectedHeaderRecordIndex) { oldValue, newValue in
            selectHeader(newValue, revertingTo: oldValue)
        }
    }

    @ViewBuilder
    private func mappingPicker(_ title: String, selection: Binding<Int>) -> some View {
        Picker(title, selection: selection) {
            ForEach(headers.indices, id: \.self) { index in
                Text(Self.displayName(headers[index], index: index)).tag(index)
            }
        }
    }

    @ViewBuilder
    private func optionalMappingPicker(_ title: String, selection: Binding<Int?>) -> some View {
        Picker(title, selection: selection) {
            Text("None").tag(nil as Int?)
            ForEach(headers.indices, id: \.self) { index in
                Text(Self.displayName(headers[index], index: index)).tag(Optional(index))
            }
        }
    }

    private func apply() {
        do {
            guard !headers.isEmpty, headerRecordIndices.contains(selectedHeaderRecordIndex) else {
                errorMessage = "Choose a valid header row before applying the mapping."
                return
            }
            guard !hasDuplicateColumnSelection else {
                errorMessage = "Each mapped field must use a different column. Choose None for optional fields when needed."
                return
            }
            let identity: FinanceImportAccountIdentity
            switch accountMode {
            case .existing:
                guard let selectedAccountID,
                      let selectedAccount = accountChoices.first(where: { $0.id == selectedAccountID }) else {
                    errorMessage = "Choose a saved account or create a new account explicitly."
                    return
                }
                let localLabel = selectedAccount.localLabel ?? accountLabel
                identity = try FinanceImportAccountIdentity(id: selectedAccount.id, label: localLabel)
            case .new:
                identity = try FinanceImportAccountIdentity(label: accountLabel)
            }
            let amount = amountMode == .signed
                ? FinanceImportAmountSelection.signed(
                    column: amountColumn,
                    format: FinanceImportAmountFormat(decimalSeparator: decimalSeparator, groupingSeparator: groupingSeparator)
                )
                : FinanceImportAmountSelection.debitCredit(
                    debitColumn: debitColumn,
                    creditColumn: creditColumn,
                    convention: debitCreditConvention,
                    format: FinanceImportAmountFormat(decimalSeparator: decimalSeparator, groupingSeparator: groupingSeparator)
                )
            let draft = FinanceImportMappingDraft(
                delimiter: nil,
                headerRecordIndex: selectedHeaderRecordIndex,
                dateColumn: dateColumn,
                dateFormat: dateFormat,
                amount: amount,
                currency: currencyMode == .constantEUR ? .constantEUR : .column(index: currencyColumn),
                account: FinanceImportAccountSelection(identity: identity, sourceColumn: sourceAccountColumn),
                description: descriptionMode == .none
                    ? FinanceImportDescriptionSelection.none
                    : FinanceImportDescriptionSelection.column(index: descriptionColumn),
                providerIDColumn: providerIDColumn,
                merchantColumn: merchantColumn
            )
            onApply(draft)
            errorMessage = nil
        } catch {
            errorMessage = "Enter a short local account label before applying the mapping."
        }
    }

    private var hasDuplicateColumnSelection: Bool {
        var columns = [dateColumn]
        if amountMode == .signed {
            columns.append(amountColumn)
        } else {
            columns.append(contentsOf: [debitColumn, creditColumn])
        }
        if currencyMode == .column { columns.append(currencyColumn) }
        if descriptionMode == .column { columns.append(descriptionColumn) }
        if let sourceAccountColumn { columns.append(sourceAccountColumn) }
        if let providerIDColumn { columns.append(providerIDColumn) }
        if let merchantColumn { columns.append(merchantColumn) }
        return !columns.allSatisfy({ headers.indices.contains($0) })
            || Set(columns).count != columns.count
    }

    private func selectHeader(_ recordIndex: Int, revertingTo previousRecordIndex: Int) {
        guard let selectedHeaders = headerColumnsForRecord(recordIndex), !selectedHeaders.isEmpty else {
            selectedHeaderRecordIndex = previousRecordIndex
            errorMessage = "That candidate header could not be read. Choose another header row."
            return
        }
        headers = selectedHeaders
        resetColumnDefaults()
        errorMessage = nil
    }

    private func resetColumnDefaults() {
        let defaults = Self.defaults(for: headers)
        dateColumn = defaults.date
        dateFormat = .yearMonthDay
        amountMode = .signed
        amountColumn = defaults.amount
        debitColumn = defaults.debit
        creditColumn = defaults.credit
        debitCreditConvention = .debitIsNegative
        decimalSeparator = .dot
        groupingSeparator = .none
        descriptionMode = defaults.description == nil ? .none : .column
        descriptionColumn = defaults.description ?? 0
        currencyMode = .constantEUR
        currencyColumn = defaults.currency
        sourceAccountColumn = nil
        providerIDColumn = nil
        merchantColumn = nil
    }

    private func reconcileAccountSelection() {
        guard !accountChoices.isEmpty else {
            accountMode = .new
            selectedAccountID = nil
            return
        }
        guard accountMode == .existing else { return }
        guard let selectedAccountID,
              accountChoices.contains(where: { $0.id == selectedAccountID }) else {
            let first = accountChoices[0]
            self.selectedAccountID = first.id
            self.accountLabel = first.localLabel ?? ""
            return
        }
        updateAccountLabelForSelection()
    }

    private var selectedAccountChoice: FinanceImportAccountChoice? {
        guard let selectedAccountID else { return nil }
        return accountChoices.first(where: { $0.id == selectedAccountID })
    }

    private func updateAccountLabelForSelection(resetSyncedLabel: Bool = false) {
        guard accountMode == .existing,
              let selectedAccountChoice else { return }
        if let localLabel = selectedAccountChoice.localLabel {
            accountLabel = localLabel
        } else if resetSyncedLabel {
            // A synced-only choice stays content-free until the user enters
            // a private label in the local mapping editor.
            accountLabel = ""
        }
    }

    private static func defaults(for headers: [String]) -> ColumnDefaults {
        guard !headers.isEmpty else {
            return ColumnDefaults(date: 0, amount: 0, debit: 0, credit: 0, description: nil, currency: 0)
        }
        let date = preferredIndex(
            in: headers,
            matching: ["date", "datum", "buchungsdatum", "booking date"],
            excluding: []
        ) ?? firstAvailable(in: headers, excluding: []) ?? 0
        let amount = preferredIndex(
            in: headers,
            matching: ["amount", "betrag", "value", "netto"],
            excluding: [date]
        ) ?? firstAvailable(in: headers, excluding: [date]) ?? date
        let debit = preferredIndex(
            in: headers,
            matching: ["debit", "debit amount", "lastschrift"],
            excluding: [date]
        ) ?? firstAvailable(in: headers, excluding: [date]) ?? date
        let creditExcluding = [date, debit]
        let credit = preferredIndex(
            in: headers,
            matching: ["credit", "credit amount", "gutschrift"],
            excluding: creditExcluding
        ) ?? firstAvailable(in: headers, excluding: creditExcluding)
            ?? headers.indices.first(where: { $0 != debit })
            ?? debit
        let descriptionExcluding = [date, amount]
        let description = preferredIndex(
            in: headers,
            matching: ["description", "beschreibung", "memo", "name", "merchant"],
            excluding: descriptionExcluding
        ) ?? firstAvailable(in: headers, excluding: descriptionExcluding)
        let currencyExcluding = descriptionExcluding + (description.map { [$0] } ?? [])
        let currency = preferredIndex(
            in: headers,
            matching: ["currency", "währung", "waehrung"],
            excluding: currencyExcluding
        ) ?? firstAvailable(in: headers, excluding: currencyExcluding) ?? 0
        return ColumnDefaults(
            date: date,
            amount: amount,
            debit: debit,
            credit: credit,
            description: description,
            currency: currency
        )
    }

    private static func preferredIndex(
        in headers: [String],
        matching values: [String],
        excluding: [Int]
    ) -> Int? {
        let excluded = Set(excluding)
        let normalized = Set(values.map(FinanceInstitutionDetector.normalizeHeader))
        return headers.indices.first {
            !excluded.contains($0)
                && normalized.contains(FinanceInstitutionDetector.normalizeHeader(headers[$0]))
        }
    }

    private static func firstAvailable(in headers: [String], excluding: [Int]) -> Int? {
        let excluded = Set(excluding)
        return headers.indices.first(where: { !excluded.contains($0) })
    }

    private static func displayName(_ header: String, index: Int) -> String {
        let cleaned = header.trimmingCharacters(in: .whitespacesAndNewlines)
        let label = cleaned.isEmpty ? "Unnamed column" : String(cleaned.prefix(36))
        return "\(index + 1) · \(label)"
    }
}

private struct FinanceImportPreviewRow: View {
    let transaction: FinanceImportedTransaction
    var isDisabled = false
    var onCategoryChange: ((FinanceTransactionCategory?) -> Void)? = nil
    var onManagePayment: (() -> Void)? = nil

    private var effectiveCategory: FinanceTransactionCategory {
        FinanceCategorizer.category(for: transaction)
    }

    private var categoryOrigin: String {
        switch FinanceCategorizer.resolve(transaction: transaction).source {
        case .userOverride: "Override"
        case .provider: "From statement"
        case .providerCode: "From provider code"
        case .investmentSource: "Investment source"
        case .heuristic, .uncategorized: "Automatic"
        }
    }

    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(transaction.description)
                    .lifeOSTypography(.metadata)
                if transaction.isInvestmentOrder {
                    Text(investmentSubtitle)
                        .lifeOSTypography(.metadata)
                        .foregroundStyle(LifeOSTokens.secondaryText)
                }
                Text(FinanceImportDateFormatter.timestamp(transaction.bookedAt))
                    .lifeOSTypography(.metadata)
                    .foregroundStyle(LifeOSTokens.tertiaryText)
            }
            Spacer(minLength: 8)
            Text(FinanceImportCurrencyFormatter.signedEuro(cents: transaction.amountCents))
                .lifeOSTypography(.button)
                .foregroundStyle(transaction.isOutflow ? LifeOSTokens.danger : LifeOSTokens.success)
                .monospacedDigit()
            if let onCategoryChange {
                Menu {
                    Button(transaction.category == nil ? "Automatic" : "Automatic (clear override)") {
                        onCategoryChange(nil)
                    }
                    Divider()
                    ForEach(FinanceTransactionCategory.allCases, id: \.self) { category in
                        Button(category.displayName) { onCategoryChange(category) }
                    }
                } label: {
                    HStack(spacing: 4) {
                        LifeOSIcon(effectiveCategory.iconName)
                            .frame(width: 12, height: 12)
                        Text(effectiveCategory.displayName)
                            .lifeOSTypography(.metadata)
                            .lineLimit(1)
                    }
                    .foregroundStyle(effectiveCategory.hue.base)
                }
                .accessibilityLabel("Category")
                .accessibilityValue("\(effectiveCategory.displayName), \(categoryOrigin)")
                .accessibilityIdentifier("finance-import-category-\(transaction.id.uuidString)")
                .disabled(isDisabled)
            }
            if let onManagePayment {
                Button {
                    onManagePayment()
                } label: {
                    LifeOSIcon(.refresh, context: .toolbar)
                        .foregroundStyle(LifeOSTokens.Module.finance)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Manage Payment")
                .accessibilityIdentifier("finance-manage-payment-\(transaction.id.uuidString)")
                .disabled(isDisabled)
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(accessibilitySummary)
    }

    private var investmentSubtitle: String {
        let details = transaction.investment
        let symbol = details?.symbol ?? "Investment order"
        let quantity = details?.quantity.map { " · \($0) units" } ?? ""
        let price = details?.unitPriceCents.map {
            " · \(FinanceImportCurrencyFormatter.magnitudeEuro(cents: $0)) unit price"
        } ?? ""
        return "\(symbol)\(quantity)\(price); holdings value unavailable"
    }

    private var accessibilitySummary: String {
        let investment = transaction.isInvestmentOrder ? ", investment order; holdings value unavailable" : ""
        return "\(transaction.description), \(FinanceImportDateFormatter.point(transaction.bookedAt)), \(FinanceImportCurrencyFormatter.signedEuro(cents: transaction.amountCents)), \(effectiveCategory.displayName), \(categoryOrigin)\(investment)"
    }
}

/// Reads the durable store, grouped by month, with per-row delete and clear
/// all. Honest empty state when the store has nothing in it.
private struct FinanceImportedTransactionsListView: View {
    @ObservedObject var model: FinanceImportViewModel
    @ObservedObject var recurringViewModel: FinanceRecurringPaymentsViewModel
    @Environment(\.dismiss) private var dismiss
    @State private var isShowingClearConfirmation = false

    private var groupedByMonth: [(key: Date, transactions: [FinanceImportedTransaction])] {
        let calendar = Calendar.current
        let grouped = Dictionary(grouping: model.savedTransactions) { transaction in
            calendar.date(from: calendar.dateComponents([.year, .month], from: transaction.bookedAt)) ?? transaction.bookedAt
        }
        return grouped
            .map { (key: $0.key, transactions: $0.value.sorted { $0.bookedAt > $1.bookedAt }) }
            .sorted { $0.key > $1.key }
    }

    var body: some View {
        NavigationStack {
            Group {
                if model.savedTransactions.isEmpty {
                    FinanceImportedEmptyState()
                } else {
                    List {
                        ForEach(groupedByMonth, id: \.key) { group in
                            Section(FinanceImportDateFormatter.month(group.key)) {
                                ForEach(group.transactions) { transaction in
                                    FinanceImportPreviewRow(
                                        transaction: transaction,
                                        onCategoryChange: { category in
                                            model.setCategory(category, for: transaction.id)
                                        },
                                        onManagePayment: recurringViewModel.hasManagedRow(for: transaction.id)
                                            ? { recurringViewModel.beginManage(transactionID: transaction.id) }
                                            : nil
                                    )
                                }
                                .onDelete { offsets in
                                    for index in offsets {
                                        model.delete(id: group.transactions[index].id)
                                    }
                                }
                            }
                        }
                    }
                }
            }
            .navigationTitle("Imported transactions")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { dismiss() }
                }
                if !model.savedTransactions.isEmpty {
                    ToolbarItem(placement: .destructiveAction) {
                        Button("Clear all", role: .destructive) {
                            isShowingClearConfirmation = true
                        }
                    }
                }
            }
            .confirmationDialog(
                "Clear all imported transactions?",
                isPresented: $isShowingClearConfirmation,
                titleVisibility: .visible
            ) {
                Button("Clear all", role: .destructive) { model.clearAll() }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text(FinanceImportCopy.clearAllConfirmation)
            }
            // This list is the visible presentation owner while the
            // imported-transactions sheet is open. The recurring card's
            // sheet modifier is underneath that presentation and therefore
            // cannot reliably present this editor itself.
            .sheet(item: recurringViewModel.editorBinding(for: .importedTransactions)) { row in
                FinanceRecurringPaymentManageSheet(
                    row: row,
                    timeZoneIdentifier: recurringViewModel.timeZoneIdentifier,
                    errorMessage: recurringViewModel.errorMessage,
                    onSave: { cadence, status, anchorDate in
                        recurringViewModel.save(row: row, cadence: cadence, status: status, anchorDate: anchorDate)
                    },
                    onReset: { recurringViewModel.resetAutomatic(for: row) }
                )
            }
        }
    }
}

private struct FinanceImportedEmptyState: View {
    var body: some View {
        VStack(spacing: 10) {
            LifeOSIcon(.importDocument)
                .foregroundStyle(LifeOSTokens.tertiaryText)
                .frame(width: 30, height: 30)
            Text("No imported transactions")
                .lifeOSTypography(.button)
            Text("Import a CSV to see your transactions here.")
                .lifeOSTypography(.body)
                .foregroundStyle(LifeOSTokens.tertiaryText)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("No imported transactions")
    }
}

// MARK: - Spending by category

/// Groups the given imported transactions by month (newest first), keyed by
/// the first-of-month `Date`. Shared by the imported-transactions list and
/// the spending-by-category section so both use the same month buckets.
private func financeImportGroupedByMonth(
    _ transactions: [FinanceImportedTransaction]
) -> [(key: Date, transactions: [FinanceImportedTransaction])] {
    let calendar = Calendar.current
    let grouped = Dictionary(grouping: transactions) { transaction in
        calendar.date(from: calendar.dateComponents([.year, .month], from: transaction.bookedAt)) ?? transaction.bookedAt
    }
    return grouped
        .map { (key: $0.key, transactions: $0.value) }
        .sorted { $0.key > $1.key }
}

/// "Spending by category" section shown inside `FinanceImportCard`, below
/// the import controls. Operates purely on `FinanceCategorizer` against
/// whatever imported transactions already exist for the selected month —
/// no new store, no persistence of categories, categorized fresh every
/// render. Honest empty state when there are no imported transactions at
/// all, or none for the selected month.
private struct FinanceSpendingByCategorySection: View {
    let transactions: [FinanceImportedTransaction]
    @State private var selectedMonth: Date?

    private var monthGroups: [(key: Date, transactions: [FinanceImportedTransaction])] {
        financeImportGroupedByMonth(transactions)
    }

    private var currentMonth: Date? {
        selectedMonth ?? monthGroups.first?.key
    }

    private var transactionsForMonth: [FinanceImportedTransaction] {
        guard let currentMonth else { return [] }
        return monthGroups.first { $0.key == currentMonth }?.transactions ?? []
    }

    private var summary: [FinanceCategorySpend] {
        FinanceCategorizer.summary(for: transactionsForMonth)
    }

    private var totals: FinanceSpendTotals {
        FinanceCategorizer.totals(for: transactionsForMonth)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Spending by category")
                    .lifeOSTypography(.cardTitle)
                Spacer(minLength: 8)
                if !monthGroups.isEmpty {
                    monthPicker
                }
            }

            if transactions.isEmpty {
                FinanceSpendingByCategoryEmptyState(hasAnyImports: false)
            } else if transactionsForMonth.isEmpty {
                FinanceSpendingByCategoryEmptyState(hasAnyImports: true)
            } else {
                FinanceSpendTotalsRow(totals: totals)
                VStack(spacing: 8) {
                    ForEach(summary, id: \.category) { spend in
                        FinanceCategorySpendRow(spend: spend, maxMagnitudeCents: maxMagnitudeCents)
                    }
                }
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("finance-spending-by-category-section")
    }

    private var maxMagnitudeCents: Int {
        summary.map { $0.outflowCents + $0.inflowCents }.max() ?? 0
    }

    private var monthPicker: some View {
        Menu {
            ForEach(monthGroups, id: \.key) { group in
                Button(FinanceImportDateFormatter.month(group.key)) {
                    selectedMonth = group.key
                }
            }
        } label: {
            HStack(spacing: 4) {
                Text(currentMonth.map(FinanceImportDateFormatter.month) ?? "")
                    .lifeOSTypography(.metadata)
                LifeOSIcon(.chevronRight)
                    .frame(width: 9, height: 9)
                    .rotationEffect(.degrees(90))
            }
            .foregroundStyle(LifeOSTokens.tertiaryText)
        }
        .accessibilityIdentifier("finance-spending-by-category-month-picker")
    }
}

private struct FinanceSpendTotalsRow: View {
    let totals: FinanceSpendTotals

    var body: some View {
        HStack(spacing: 14) {
            FinanceSpendTotalItem(label: "Spent", cents: totals.outflowCents, color: LifeOSTokens.danger)
            FinanceSpendTotalItem(label: "Income", cents: totals.inflowCents, color: LifeOSTokens.success)
            FinanceSpendTotalItem(
                label: "Net",
                cents: totals.netCents,
                color: totals.netCents < 0 ? LifeOSTokens.danger : LifeOSTokens.success,
                isSigned: true,
                signedValue: totals.netCents
            )
            Spacer(minLength: 0)
        }
    }
}

private struct FinanceSpendTotalItem: View {
    let label: String
    let cents: Int
    let color: Color
    var isSigned: Bool = false
    var signedValue: Int = 0

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label)
                .lifeOSTypography(.metadata)
                .foregroundStyle(LifeOSTokens.tertiaryText)
            Text(isSigned ? FinanceImportCurrencyFormatter.signedEuro(cents: signedValue) : FinanceImportCurrencyFormatter.magnitudeEuro(cents: cents))
                .lifeOSTypography(.button)
                .foregroundStyle(color)
                .monospacedDigit()
        }
    }
}

/// One row per category: icon/hue, name, transaction count, EUR total, and
/// a simple proportional bar. Outflow renders in `LifeOSTokens.danger`,
/// pure-income categories in `.success`.
private struct FinanceCategorySpendRow: View {
    let spend: FinanceCategorySpend
    let maxMagnitudeCents: Int
    @State private var hasAppeared = false

    private var magnitudeCents: Int { spend.outflowCents + spend.inflowCents }
    private var isPrimarilyIncome: Bool { spend.inflowCents > spend.outflowCents }
    private var amountColor: Color { isPrimarilyIncome ? LifeOSTokens.success : LifeOSTokens.danger }
    private var barFraction: CGFloat {
        guard maxMagnitudeCents > 0 else { return 0 }
        return CGFloat(magnitudeCents) / CGFloat(maxMagnitudeCents)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 8) {
                LifeOSIcon(spend.category.iconName)
                    .foregroundStyle(spend.category.hue.base)
                    .frame(width: 14, height: 14)
                Text(spend.category.displayName)
                    .lifeOSTypography(.metadata)
                Text("\(spend.count)")
                    .lifeOSTypography(.metadata)
                    .foregroundStyle(LifeOSTokens.tertiaryText)
                Spacer(minLength: 8)
                Text(isPrimarilyIncome
                     ? FinanceImportCurrencyFormatter.signedEuro(cents: spend.inflowCents)
                     : FinanceImportCurrencyFormatter.signedEuro(cents: -spend.outflowCents))
                    .lifeOSTypography(.button)
                    .foregroundStyle(amountColor)
                    .monospacedDigit()
            }

            GeometryReader { proxy in
                ZStack(alignment: .leading) {
                    Capsule()
                        .fill(LifeOSTokens.Ring.track)
                    Capsule()
                        .fill(spend.category.hue.base)
                        .frame(width: proxy.size.width * (hasAppeared ? barFraction : 0))
                }
            }
            .frame(height: 5)
            .accessibilityHidden(true)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(spend.category.displayName), \(spend.count) transactions")
        .onAppear {
            if LifeOSMotion.reduceMotion {
                hasAppeared = true
            } else {
                withAnimation(LifeOSMotion.chartDraw) { hasAppeared = true }
            }
        }
    }
}

private struct FinanceSpendingByCategoryEmptyState: View {
    /// `true` when imports exist overall but not for the selected month;
    /// `false` when there are no imported transactions at all. Both are
    /// honest — neither fabricates category data.
    let hasAnyImports: Bool

    var body: some View {
        Text(hasAnyImports
             ? "No imported transactions in this month."
             : "Import a CSV to see spending by category here.")
            .lifeOSTypography(.body)
            .foregroundStyle(LifeOSTokens.tertiaryText)
            .accessibilityIdentifier("finance-spending-by-category-empty-state")
    }
}

// MARK: - Investment boundary

/// Shows Trade Republic order rows without pretending that a transaction
/// statement is a holdings feed. Current wealth, allocation, and performance
/// remain unavailable until an explicit holdings observation is supplied.
private struct FinanceImportedInvestmentsSection: View {
    let transactions: [FinanceImportedTransaction]

    private var investmentRows: [FinanceImportedTransaction] {
        transactions
            .filter(\.isInvestmentOrder)
            .sorted { $0.bookedAt > $1.bookedAt }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label {
                Text("Trade Republic investments")
            } icon: {
                LifeOSIcon(.investments)
            }
                .lifeOSTypography(.cardTitle)
                .foregroundStyle(LifeOSTokens.secondaryText)
            Text("\(investmentRows.count) investment order\(investmentRows.count == 1 ? "" : "s") imported as cash movements. Holdings value, allocation, and wealth performance are unavailable from this statement.")
                .lifeOSTypography(.metadata)
                .foregroundStyle(LifeOSTokens.tertiaryText)
                .fixedSize(horizontal: false, vertical: true)
            ForEach(Array(investmentRows.prefix(5))) { transaction in
                FinanceImportPreviewRow(transaction: transaction)
            }
            if investmentRows.count > 5 {
                Text("Showing the latest 5 orders")
                    .lifeOSTypography(.metadata)
                    .foregroundStyle(LifeOSTokens.tertiaryText)
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("finance-imported-investments-section")
    }
}

// MARK: - Budgets

/// Drives budget persistence for the "Budgets" section: reads/writes its own
/// `FinanceBudgetStore` and is otherwise stateless. Self-contained, mirroring
/// `FinanceImportViewModel` — never touches `FinanceCoordinator` or any other
/// Finance surface.
@MainActor
final class FinanceBudgetViewModel: ObservableObject {
    @Published private(set) var currentBudgets: [FinanceTransactionCategory: FinanceCategoryBudget] = [:]
    @Published var errorMessage: String?

    private let store: FinanceBudgetStore?

    init(store: FinanceBudgetStore? = nil, usesVisualFixtures: Bool = false) {
        // An explicit fixture mode is fail-closed: a missing injected store
        // must remain unavailable rather than falling back to the personal
        // Application Support budget file.
        let resolvedStore = usesVisualFixtures ? store : (store ?? (try? FinanceBudgetStore()))
        self.store = resolvedStore
        reload(on: .now)
    }

    var hasStore: Bool { store != nil }

    func reload(on date: Date) {
        guard let store else { return }
        do {
            currentBudgets = try store.currentBudgets(on: date)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    /// Sets a new monthly limit for `category`, effective from `date` (the
    /// selected month being viewed). Rejects non-positive limits and
    /// `.income` up front rather than round-tripping an invalid value
    /// through the store.
    func setLimit(cents: Int, for category: FinanceTransactionCategory, effectiveFrom date: Date) {
        errorMessage = nil
        guard let store else {
            errorMessage = FinanceBudgetStoreError.applicationSupportUnavailable.localizedDescription
            return
        }
        guard category.isBudgetable else {
            errorMessage = FinanceBudgetStoreError.notBudgetable.localizedDescription
            return
        }
        guard cents > 0, cents <= FinanceBudgetAmountParser.maximumCents else {
            errorMessage = FinanceBudgetStoreError.invalidLimit.localizedDescription
            return
        }
        do {
            try store.setBudget(FinanceCategoryBudget(category: category, monthlyLimitCents: cents, effectiveFrom: date))
            reload(on: date)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func removeBudget(for category: FinanceTransactionCategory, viewingDate date: Date) {
        guard let store else { return }
        do {
            try store.remove(category: category)
            reload(on: date)
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}

/// "Budgets" section shown inside `FinanceImportCard`, below "Spending by
/// category." For the selected month, shows every budgetable category with
/// either its set monthly limit (editable) and actual spend as a progress
/// bar, or an honest "No budget set" row when nothing has been configured —
/// never a fabricated zero limit. Uses the same month-grouping helper as
/// "Spending by category" so both sections agree on month boundaries.
private struct FinanceBudgetsSection: View {
    let transactions: [FinanceImportedTransaction]
    @StateObject private var model: FinanceBudgetViewModel
    @State private var selectedMonth: Date?

    init(
        transactions: [FinanceImportedTransaction],
        store: FinanceBudgetStore? = nil,
        usesVisualFixtures: Bool = false
    ) {
        self.transactions = transactions
        _model = StateObject(
            wrappedValue: FinanceBudgetViewModel(
                store: store,
                usesVisualFixtures: usesVisualFixtures
            )
        )
    }

    private var monthGroups: [(key: Date, transactions: [FinanceImportedTransaction])] {
        financeImportGroupedByMonth(transactions)
    }

    private var fallbackMonth: Date {
        Calendar.current.date(from: Calendar.current.dateComponents([.year, .month], from: .now)) ?? .now
    }

    private var currentMonth: Date {
        selectedMonth ?? monthGroups.first?.key ?? fallbackMonth
    }

    private var transactionsForMonth: [FinanceImportedTransaction] {
        monthGroups.first { $0.key == currentMonth }?.transactions ?? []
    }

    private var spendByCategory: [FinanceTransactionCategory: FinanceCategorySpend] {
        Dictionary(uniqueKeysWithValues: FinanceCategorizer.budgetSummary(for: transactionsForMonth).map { ($0.category, $0) })
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Budgets")
                    .lifeOSTypography(.cardTitle)
                Spacer(minLength: 8)
                if !monthGroups.isEmpty {
                    monthPicker
                }
            }

            VStack(spacing: 10) {
                ForEach(FinanceTransactionCategory.budgetableCategories, id: \.self) { category in
                    FinanceCategoryBudgetRow(
                        category: category,
                        budget: model.currentBudgets[category],
                        spend: spendByCategory[category],
                        actualsAvailable: !transactionsForMonth.isEmpty,
                        onSetLimit: { cents in
                            model.setLimit(cents: cents, for: category, effectiveFrom: currentMonth)
                        },
                        onRemove: {
                            model.removeBudget(for: category, viewingDate: currentMonth)
                        }
                    )
                }
            }
        }
        .onAppear { reloadBudgetsForDisplayedMonth() }
        .onChange(of: selectedMonth) { _, _ in
            reloadBudgetsForDisplayedMonth()
        }
        .onChange(of: transactions) { _, _ in
            // Imported rows can change without changing the set of month
            // keys (for example, a corrected amount in the selected month).
            // Reload against the month the section actually displays, then
            // reconcile a selection whose month disappeared.
            reloadBudgetsForDisplayedMonth()
        }
        .alert("Budgets", isPresented: Binding(
            get: { model.errorMessage != nil },
            set: { if !$0 { model.errorMessage = nil } }
        )) {
            Button("OK") {}
        } message: {
            Text(model.errorMessage ?? "")
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("finance-budgets-section")
    }

    private func reloadBudgetsForDisplayedMonth() {
        let availableMonths = monthGroups.map(\.key)
        let displayedMonth: Date
        if let selectedMonth, availableMonths.contains(selectedMonth) {
            displayedMonth = selectedMonth
        } else {
            if selectedMonth != nil { self.selectedMonth = nil }
            displayedMonth = availableMonths.first ?? fallbackMonth
        }
        model.reload(on: displayedMonth)
    }

    private var monthPicker: some View {
        Menu {
            ForEach(monthGroups, id: \.key) { group in
                Button(FinanceImportDateFormatter.month(group.key)) {
                    selectedMonth = group.key
                }
            }
        } label: {
            HStack(spacing: 4) {
                Text(FinanceImportDateFormatter.month(currentMonth))
                    .lifeOSTypography(.metadata)
                LifeOSIcon(.chevronRight)
                    .frame(width: 9, height: 9)
                    .rotationEffect(.degrees(90))
            }
            .foregroundStyle(LifeOSTokens.tertiaryText)
        }
        .accessibilityIdentifier("finance-budgets-month-picker")
    }
}

/// One row per budgetable category: icon/name, editable limit field, and
/// (when a limit is set) actual spend this month with a progress bar and an
/// honest remaining/over-by readout. When no limit is set, shows "No budget
/// set" plus the entry field — never a fabricated zero limit standing in for
/// "unset."
private struct FinanceCategoryBudgetRow: View {
    let category: FinanceTransactionCategory
    let budget: FinanceCategoryBudget?
    let spend: FinanceCategorySpend?
    let actualsAvailable: Bool
    let onSetLimit: (Int) -> Void
    let onRemove: () -> Void

    @State private var limitText: String = ""
    @FocusState private var isFieldFocused: Bool
    @State private var hasAppeared = false

    private var spentCents: Int? {
        guard actualsAvailable else { return nil }
        return spend?.outflowCents ?? 0
    }
    private var limitCents: Int? { budget?.monthlyLimitCents }
    private var isOverBudget: Bool {
        guard let limitCents, let spentCents else { return false }
        return spentCents > limitCents
    }
    private var progressFraction: CGFloat? {
        guard let limitCents, limitCents > 0, let spentCents else { return nil }
        return min(CGFloat(spentCents) / CGFloat(limitCents), 1)
    }
    private var progressColor: Color {
        isOverBudget ? LifeOSTokens.danger : LifeOSTokens.success
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                LifeOSIcon(category.iconName)
                    .foregroundStyle(category.hue.base)
                    .frame(width: 14, height: 14)
                Text(category.displayName)
                    .lifeOSTypography(.metadata)
                Spacer(minLength: 8)
                HStack(spacing: 3) {
                    Text("€")
                        .lifeOSTypography(.body)
                        .foregroundStyle(LifeOSTokens.tertiaryText)
                    TextField("Limit", text: $limitText)
                        #if os(iOS)
                        .keyboardType(.decimalPad)
                        #endif
                        .multilineTextAlignment(.trailing)
                        .lifeOSTypography(.button)
                        .frame(width: 56)
                        .focused($isFieldFocused)
                        .onSubmit(commitLimit)
                        .accessibilityIdentifier("finance-budget-limit-field-\(category.rawValue)")
                }
            }

            if let limitCents {
                if let progressFraction {
                    HStack(spacing: 6) {
                        GeometryReader { proxy in
                            ZStack(alignment: .leading) {
                                Capsule()
                                    .fill(LifeOSTokens.Ring.track)
                                Capsule()
                                    .fill(progressColor)
                                    .frame(width: proxy.size.width * (hasAppeared ? progressFraction : 0))
                            }
                        }
                        .frame(height: 5)
                        .accessibilityHidden(true)
                    }
                    .onAppear {
                        if LifeOSMotion.reduceMotion {
                            hasAppeared = true
                        } else {
                            withAnimation(LifeOSMotion.chartDraw) { hasAppeared = true }
                        }
                    }

                    HStack(spacing: 6) {
                        if let spentCents {
                            Text(FinanceImportCurrencyFormatter.magnitudeEuro(cents: spentCents) + " of " + FinanceImportCurrencyFormatter.magnitudeEuro(cents: limitCents))
                                .lifeOSTypography(.metadata)
                                .foregroundStyle(LifeOSTokens.tertiaryText)
                            Spacer(minLength: 8)
                            Text(isOverBudget
                                 ? "Over by \(FinanceImportCurrencyFormatter.magnitudeEuro(cents: spentCents - limitCents))"
                                 : "\(FinanceImportCurrencyFormatter.magnitudeEuro(cents: limitCents - spentCents)) remaining")
                                .lifeOSTypography(.metadata, weight: .semibold)
                                .foregroundStyle(isOverBudget ? LifeOSTokens.danger : LifeOSTokens.success)
                        }
                        Button("Remove", role: .destructive, action: onRemove)
                            .lifeOSTypography(.metadata)
                            .buttonStyle(.plain)
                            .foregroundStyle(LifeOSTokens.tertiaryText)
                            .accessibilityIdentifier("finance-budget-remove-\(category.rawValue)")
                    }
                } else {
                    HStack(spacing: 8) {
                        LifeOSIcon(.warning)
                            .foregroundStyle(LifeOSTokens.warning)
                            .frame(width: 13, height: 13)
                        Text("Actual spend unavailable until a statement is imported")
                            .lifeOSTypography(.metadata)
                            .foregroundStyle(LifeOSTokens.warning)
                        Spacer(minLength: 8)
                        Button("Remove", role: .destructive, action: onRemove)
                            .lifeOSTypography(.metadata)
                            .buttonStyle(.plain)
                            .foregroundStyle(LifeOSTokens.tertiaryText)
                            .accessibilityIdentifier("finance-budget-remove-\(category.rawValue)")
                    }
                }
            } else {
                VStack(alignment: .leading, spacing: 3) {
                    Text("No budget set")
                        .lifeOSTypography(.metadata)
                        .foregroundStyle(LifeOSTokens.tertiaryText)
                        .accessibilityIdentifier("finance-budget-unset-\(category.rawValue)")
                    Text(actualsAvailable
                         ? (spend.map { "Actual spend \(FinanceImportCurrencyFormatter.magnitudeEuro(cents: $0.outflowCents))" } ?? "No spend recorded")
                         : "Actual spend unavailable until a statement is imported")
                        .lifeOSTypography(.metadata)
                        .foregroundStyle(actualsAvailable ? LifeOSTokens.secondaryText : LifeOSTokens.warning)
                }
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("finance-budget-row-\(category.rawValue)")
        .onChange(of: isFieldFocused) { wasFocused, isFocused in
            if wasFocused && !isFocused {
                commitLimit()
            }
        }
        .onAppear {
            limitText = limitCents.map(FinanceImportCurrencyFormatter.editableEuro(cents:)) ?? ""
        }
        .onChange(of: limitCents) { _, newValue in
            if !isFieldFocused {
                limitText = newValue.map(FinanceImportCurrencyFormatter.editableEuro(cents:)) ?? ""
            }
        }
    }

    private func commitLimit() {
        guard let cents = FinanceBudgetAmountParser.cents(from: limitText) else {
            // Invalid or empty entry: revert the field rather than silently
            // writing a fabricated limit.
            limitText = limitCents.map(FinanceImportCurrencyFormatter.editableEuro(cents:)) ?? ""
            return
        }
        onSetLimit(cents)
    }
}

// MARK: - Formatting helpers (kept local to this file; Finance's private
// formatters in FinanceView.swift are not exposed outside that file)

enum FinanceImportCurrencyFormatter {
    static func signedEuro(cents: Int) -> String {
        let magnitude = magnitudeEuro(cents: cents)
        return cents < 0 ? "-\(magnitude)" : "+\(magnitude)"
    }

    /// Unsigned EUR string for `abs(cents)`. Used for totals rows where the
    /// sign is already conveyed by a label ("Spent" / "Income") or color.
    static func magnitudeEuro(cents: Int) -> String {
        let formatter = NumberFormatter()
        formatter.numberStyle = .currency
        formatter.currencyCode = "EUR"
        formatter.locale = Locale.current
        formatter.minimumFractionDigits = 2
        formatter.maximumFractionDigits = 2

        let exactValue = exactDecimal(cents: cents)
        let magnitude = cents < 0
            ? exactValue.multiplying(by: NSDecimalNumber(value: Int64(-1)))
            : exactValue
        return formatter.string(from: magnitude) ?? fallbackMagnitudeEuro(cents: cents)
    }

    /// Stable editor text for a positive cent amount. It deliberately uses
    /// integer arithmetic so a budget is never rendered through a binary
    /// floating-point approximation, including at the payload's upper bound.
    static func editableEuro(cents: Int) -> String {
        guard cents > 0 else { return "" }
        let parts = exactMagnitudeParts(cents: cents)
        return "\(parts.whole).\(parts.fraction)"
    }

    private static func exactDecimal(cents: Int) -> NSDecimalNumber {
        NSDecimalNumber(
            string: exactSignedIntegerText(cents: cents),
            locale: Locale(identifier: "en_US_POSIX")
        ).dividing(by: NSDecimalNumber(value: Int64(100)))
    }

    private static func fallbackMagnitudeEuro(cents: Int) -> String {
        let parts = exactMagnitudeParts(cents: cents)
        return "€\(parts.whole).\(parts.fraction)"
    }

    private static func exactSignedIntegerText(cents: Int) -> String {
        if cents == Int.min {
            return "-\(UInt64(Int.max) + 1)"
        }
        return String(cents)
    }

    private static func exactMagnitudeParts(cents: Int) -> (whole: String, fraction: String) {
        let magnitude: UInt64
        if cents == Int.min {
            magnitude = UInt64(Int.max) + 1
        } else {
            magnitude = UInt64(cents < 0 ? -cents : cents)
        }
        let whole = magnitude / 100
        let remainder = magnitude % 100
        return (String(whole), remainder < 10 ? "0\(remainder)" : String(remainder))
    }
}

private enum FinanceImportDateFormatter {
    static func point(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "EEE, MMM d"
        return formatter.string(from: date)
    }

    static func timestamp(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "MMM d, yyyy · HH:mm"
        return formatter.string(from: date)
    }

    static func month(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "MMMM yyyy"
        return formatter.string(from: date)
    }
}
