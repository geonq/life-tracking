import Foundation
import XCTest
@testable import LifeOSMac

final class FinanceImportMacTests: XCTestCase {
    private let accountID = UUID(uuidString: "00000000-0000-4000-8000-000000000071")!
    private let mappingID = UUID(uuidString: "00000000-0000-4000-8000-000000000072")!
    private let secondAccountID = UUID(uuidString: "00000000-0000-4000-8000-000000000074")!
    private let secondMappingID = UUID(uuidString: "00000000-0000-4000-8000-000000000075")!

    private var unknownCSV: Data {
        Data("posted,merchant,value\n2026-08-01,Coffee Shop,-4.50\n".utf8)
    }

    private func mapping(
        for headers: [String],
        accountID: UUID = UUID(uuidString: "00000000-0000-4000-8000-000000000071")!,
        mappingID: UUID = UUID(uuidString: "00000000-0000-4000-8000-000000000072")!,
        amountColumn: Int = 2,
        sourceAccountColumn: Int? = nil,
        providerIDColumn: Int? = nil,
        merchantColumn: Int? = nil
    ) throws -> FinanceImportMapping {
        let account = try FinanceImportAccountIdentity(
            id: accountID,
            label: "Mac test account \(accountID.uuidString.suffix(4))"
        )
        let draft = FinanceImportMappingDraft(
            delimiter: .comma,
            headerRecordIndex: 0,
            dateColumn: 0,
            dateFormat: .yearMonthDay,
            amount: .signed(column: amountColumn),
            currency: .constantEUR,
            account: FinanceImportAccountSelection(identity: account, sourceColumn: sourceAccountColumn),
            description: merchantColumn == nil
                ? .column(index: 1)
                : FinanceImportDescriptionSelection.none,
            providerIDColumn: providerIDColumn,
            merchantColumn: merchantColumn
        )
        return try FinanceImportMapping(id: mappingID, draft: draft, headerColumns: headers)
    }

    private func preparedImport() throws -> FinancePreparedImport {
        let inspection = try FinanceStatementImporter.inspectCSV(data: unknownCSV)
        let headers = try FinanceStatementImporter.headerColumnNames(data: unknownCSV, inspection: inspection)
        let mapping = try mapping(for: headers)
        return try FinanceStatementImporter.prepareMappedImport(
            data: unknownCSV,
            inspection: inspection,
            mapping: mapping,
            sessionID: UUID(uuidString: "00000000-0000-4000-8000-000000000073")!,
            revision: 4
        )
    }

    private func preparedProviderImport(
        csv: String,
        accountID: UUID = UUID(uuidString: "00000000-0000-4000-8000-000000000071")!,
        mappingID: UUID = UUID(uuidString: "00000000-0000-4000-8000-000000000072")!
    ) throws -> FinancePreparedImport {
        let data = Data(csv.utf8)
        let inspection = try FinanceStatementImporter.inspectCSV(data: data)
        let headers = try FinanceStatementImporter.headerColumnNames(data: data, inspection: inspection)
        let mapping = try mapping(
            for: headers,
            accountID: accountID,
            mappingID: mappingID,
            amountColumn: 3,
            sourceAccountColumn: 4,
            providerIDColumn: 1,
            merchantColumn: 2
        )
        return try FinanceStatementImporter.prepareMappedImport(
            data: data,
            inspection: inspection,
            mapping: mapping,
            sessionID: UUID(uuidString: "00000000-0000-4000-8000-000000000076")!,
            revision: 4
        )
    }

    private var providerCSV: String {
        "date,provider,merchant,amount,account\n2026-08-01,p-1,Coffee Shop,-4.50,checking\n"
    }

    func testUnknownCSVRequiresExplicitMappingAndProducesPreparedRowsAfterMapping() throws {
        let inspection = try FinanceStatementImporter.inspectCSV(data: unknownCSV)

        XCTAssertEqual(inspection.mappingEligibility.state, .requiresMapping)
        XCTAssertEqual(inspection.candidateHeaderRecordIndices, [0])

        let prepared = try preparedImport()
        XCTAssertEqual(prepared.effectiveDetection.state, .userMapped)
        XCTAssertEqual(prepared.transactions.count, 1)
        XCTAssertEqual(prepared.transactions[0].amountCents, -450)
        XCTAssertEqual(prepared.rows[0].sourceRowNumber, 2)
    }

    func testMappedIDsAreStableAndSourceMutationInvalidatesInspection() throws {
        let first = try preparedImport()
        let second = try preparedImport()
        XCTAssertEqual(first.transactions.map(\.id), second.transactions.map(\.id))

        let originalInspection = try FinanceStatementImporter.inspectCSV(data: unknownCSV)
        let headers = try FinanceStatementImporter.headerColumnNames(data: unknownCSV, inspection: originalInspection)
        let mapping = try mapping(for: headers)
        let changedCSV = Data("posted,merchant,value\n2026-08-01,Changed Shop,-4.50\n".utf8)

        XCTAssertThrowsError(
            try FinanceStatementImporter.prepareMappedImport(
                data: changedCSV,
                inspection: originalInspection,
                mapping: mapping,
                sessionID: UUID(),
                revision: 4
            )
        ) { error in
            XCTAssertEqual(error as? FinanceImportMappingError, .stalePreview)
        }
    }

    func testPreparedStoreCommitIsIdempotentAndKeepsImportMetadataLocal() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("lifeos-finance-mac-test-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: url) }

        let prepared = try preparedImport()
        let store = try FinanceImportedTransactionStore(url: url)
        let remoteSnapshot = try FinanceImportedSyncSnapshot(revision: 0, records: [], tombstones: [])
        let remoteDigest = String(repeating: "0", count: 64)
        try store.adoptRemote(
            FinanceImportedSyncResult(
                snapshot: remoteSnapshot,
                etag: "\"finance-imported-v2-r0-\(remoteDigest)\""
            )
        )
        let first = try store.commitPreparedImport(prepared)
        let relaunched = try FinanceImportedTransactionStore(url: url)
        let retry = try relaunched.commitPreparedImport(prepared)

        XCTAssertEqual(first.insertedCount, 1)
        XCTAssertEqual(retry.insertedCount, 0)
        XCTAssertEqual(retry.duplicateCount, 1)
        XCTAssertEqual(try relaunched.all().count, 1)
        XCTAssertEqual(try relaunched.importMappings().count, 1)
        XCTAssertEqual(try relaunched.importBatches().count, 1)

        let syncBody = try XCTUnwrap(try relaunched.pendingSyncRequest()?.body)
        let wire = String(decoding: syncBody, as: UTF8.self)
        XCTAssertFalse(wire.contains("importMappings"))
        XCTAssertFalse(wire.contains("importBatches"))
    }

    func testLegacyAttemptedBodySurvivesIdentitySchemaUpgradeAndRelaunch() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("lifeos-finance-mac-legacy-attempt-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: url) }
        let row = FinanceImportedTransaction(
            id: UUID(uuidString: "00000000-0000-4000-8000-000000000078")!,
            bookedAt: Date(timeIntervalSince1970: 1_786_449_600),
            amountCents: -2500,
            description: "Legacy attempted body",
            source: .genericCSV,
            importedAt: Date(timeIntervalSince1970: 1_786_449_600)
        )
        let store = try FinanceImportedTransactionStore(url: url)
        let zeroDigest = String(repeating: "0", count: 64)
        try store.adoptRemote(
            FinanceImportedSyncResult(
                snapshot: try FinanceImportedSyncSnapshot(revision: 0, records: [], tombstones: []),
                etag: "\"finance-imported-v2-r0-\(zeroDigest)\""
            )
        )
        try store.add([row])
        let first = try XCTUnwrap(store.pendingSyncRequest())
        let legacyBody = try legacyIdentityRequestBody(from: first.body)

        var root = try XCTUnwrap(try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
        var outbox = try XCTUnwrap(root["outbox"] as? [[String: Any]])
        var entry = try XCTUnwrap(outbox.first)
        var attempted = try XCTUnwrap(entry["attemptedRequest"] as? [String: Any])
        attempted["body"] = legacyBody.base64EncodedString()
        entry["attemptedRequest"] = attempted
        outbox[0] = entry
        root["outbox"] = outbox
        try JSONSerialization.data(withJSONObject: root, options: [.sortedKeys]).write(to: url, options: .atomic)

        let relaunched = try FinanceImportedTransactionStore(url: url)
        let retry = try XCTUnwrap(relaunched.pendingSyncRequest())
        XCTAssertEqual(retry.body, legacyBody)
        XCTAssertEqual(retry.ifMatch, first.ifMatch)
        XCTAssertEqual(retry.idempotencyKey, first.idempotencyKey)
        XCTAssertEqual(retry.request, first.request)
    }

    func testCorrectedProviderRowUpdatesExistingTransactionAndReusesMapping() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("lifeos-finance-mac-correction-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: url) }

        let original = try preparedProviderImport(csv: providerCSV)
        let corrected = try preparedProviderImport(csv: providerCSV.replacingOccurrences(of: "Coffee Shop,-4.50", with: "Coffee Shop corrected,-5.25"))
        XCTAssertEqual(original.transactions.map(\.id), corrected.transactions.map(\.id))

        let store = try FinanceImportedTransactionStore(url: url)
        XCTAssertEqual(try store.commitPreparedImport(original).insertedCount, 1)
        let result = try store.commitPreparedImport(corrected)

        XCTAssertEqual(result.insertedCount, 0)
        XCTAssertEqual(result.updatedCount, 1)
        XCTAssertEqual(try store.all().first?.description, "Coffee Shop corrected")
        XCTAssertEqual(try store.all().first?.amountCents, -525)
        XCTAssertEqual(try store.importMappings().count, 1)
        XCTAssertEqual(try store.importBatches().count, 2)
    }

    func testCommittedBatchRetryCannotUndoLaterProviderCorrection() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("lifeos-finance-mac-retry-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: url) }

        let original = try preparedProviderImport(csv: providerCSV)
        let corrected = try preparedProviderImport(
            csv: providerCSV.replacingOccurrences(of: "Coffee Shop,-4.50", with: "Coffee Shop corrected,-5.25")
        )
        let store = try FinanceImportedTransactionStore(url: url)
        _ = try store.commitPreparedImport(original)
        XCTAssertEqual(try store.commitPreparedImport(corrected).updatedCount, 1)

        let reopenedOriginal = try preparedProviderImport(csv: providerCSV)
        let retry = try store.commitPreparedImport(reopenedOriginal)
        XCTAssertEqual(retry.insertedCount, 0)
        XCTAssertEqual(retry.updatedCount, 0)
        XCTAssertEqual(retry.duplicateCount, 1)
        XCTAssertEqual(try store.all().first?.description, "Coffee Shop corrected")
        XCTAssertEqual(try store.all().first?.amountCents, -525)
    }

    func testPartialReceiptReimportRestoresMissingRowsWithoutUndoingCorrections() throws {
        let originalCSV = """
        date,provider,merchant,amount,account
        2026-08-01,p-1,Coffee Shop,-4.50,checking
        2026-08-02,p-2,Book Shop,-8.00,checking
        """
        let correctedCSV = originalCSV.replacingOccurrences(
            of: "Coffee Shop,-4.50",
            with: "Coffee Shop corrected,-5.25"
        )
        let original = try preparedProviderImport(csv: originalCSV)
        let corrected = try preparedProviderImport(csv: correctedCSV)
        let deletedID = original.transactions[1].id
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("lifeos-finance-mac-partial-receipt-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: url) }
        let store = try FinanceImportedTransactionStore(url: url)
        _ = try store.commitPreparedImport(original)
        XCTAssertEqual(try store.commitPreparedImport(corrected).updatedCount, 1)
        try store.remove(id: deletedID)

        let reopened = try preparedProviderImport(csv: originalCSV)
        let result = try store.commitPreparedImport(reopened)
        XCTAssertEqual(result.insertedCount, 1)
        XCTAssertEqual(result.updatedCount, 0)
        XCTAssertEqual(try store.all().count, 2)
        let correctedID = original.transactions[0].id
        XCTAssertEqual(try store.all().first(where: { $0.id == correctedID })?.description, "Coffee Shop corrected")
        XCTAssertEqual(try store.all().first(where: { $0.id == correctedID })?.amountCents, -525)
        XCTAssertEqual(try store.all().first(where: { $0.id == deletedID })?.amountCents, -800)
        let repairedReceipt = try XCTUnwrap(
            try store.importBatches().first(where: { $0.id == original.batchProvenance.id })
        )
        XCTAssertEqual(
            Set(repairedReceipt.rowLinks.map(\.transactionID)),
            Set(original.transactions.map(\.id))
        )
    }

    func testChangedMappingInterpretationForSameSourceRequiresMigration() throws {
        let data = Data(providerCSV.utf8)
        let inspection = try FinanceStatementImporter.inspectCSV(data: data)
        let headers = try FinanceStatementImporter.headerColumnNames(data: data, inspection: inspection)
        let original = try preparedProviderImport(csv: providerCSV)
        let changedMapping = try mapping(
            for: headers,
            accountID: accountID,
            mappingID: UUID(uuidString: "00000000-0000-4000-8000-000000000076")!,
            amountColumn: 3,
            sourceAccountColumn: 4,
            providerIDColumn: nil,
            merchantColumn: 2
        )
        let changed = try FinanceStatementImporter.prepareMappedImport(
            data: data,
            inspection: inspection,
            mapping: changedMapping,
            sessionID: UUID(uuidString: "00000000-0000-4000-8000-000000000077")!,
            revision: 4
        )
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("lifeos-finance-mac-mapping-change-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: url) }
        let store = try FinanceImportedTransactionStore(url: url)
        _ = try store.commitPreparedImport(original)
        XCTAssertNoThrow(try store.all())
        XCTAssertThrowsError(try store.commitPreparedImport(changed)) { error in
            XCTAssertEqual(error as? FinanceImportedTransactionStoreError, .migrationRequired)
        }
        XCTAssertEqual(try store.all().count, 1)
        XCTAssertEqual(try store.importBatches().count, 1)
    }

    func testSourceInterpretationChangeForSameAccountRequiresMigrationRegardlessOfSourceDigest() throws {
        let sourceA = Data(providerCSV.utf8)
        let sourceB = Data(providerCSV.replacingOccurrences(of: "p-1", with: "p-2").utf8)
        let inspectionA = try FinanceStatementImporter.inspectCSV(data: sourceA)
        let inspectionB = try FinanceStatementImporter.inspectCSV(data: sourceB)
        let headers = try FinanceStatementImporter.headerColumnNames(data: sourceA, inspection: inspectionA)
        let mappingA = try mapping(
            for: headers,
            accountID: accountID,
            mappingID: mappingID,
            amountColumn: 3,
            sourceAccountColumn: 4,
            providerIDColumn: 1,
            merchantColumn: 2
        )
        let mappingB = try mapping(
            for: headers,
            accountID: accountID,
            mappingID: secondMappingID,
            amountColumn: 3,
            sourceAccountColumn: 4,
            providerIDColumn: nil,
            merchantColumn: 2
        )
        let importA = try FinanceStatementImporter.prepareMappedImport(
            data: sourceA,
            inspection: inspectionA,
            mapping: mappingA,
            sessionID: UUID(uuidString: "00000000-0000-4000-8000-000000000080")!,
            revision: 4
        )
        let importB = try FinanceStatementImporter.prepareMappedImport(
            data: sourceB,
            inspection: inspectionB,
            mapping: mappingB,
            sessionID: UUID(uuidString: "00000000-0000-4000-8000-000000000081")!,
            revision: 4
        )
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("lifeos-finance-mac-mapping-cross-export-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: url) }
        let store = try FinanceImportedTransactionStore(url: url)
        _ = try store.commitPreparedImport(importA)
        XCTAssertThrowsError(try store.commitPreparedImport(importB)) { error in
            XCTAssertEqual(error as? FinanceImportedTransactionStoreError, .migrationRequired)
        }
        XCTAssertEqual(try store.all().count, 1)
        XCTAssertEqual(try store.importBatches().count, 1)
    }

    func testChangedExportCannotChangeMappingInterpretationForSameAccount() throws {
        let original = try preparedProviderImport(csv: providerCSV)
        let changedCSV = providerCSV + "2026-08-02,p-2,Book Shop,-8.00,checking\n"
        let changedData = Data(changedCSV.utf8)
        let inspection = try FinanceStatementImporter.inspectCSV(data: changedData)
        let headers = try FinanceStatementImporter.headerColumnNames(data: changedData, inspection: inspection)
        let changedMapping = try mapping(
            for: headers,
            accountID: accountID,
            mappingID: secondMappingID,
            amountColumn: 3,
            sourceAccountColumn: 4,
            providerIDColumn: nil,
            merchantColumn: 2
        )
        let changed = try FinanceStatementImporter.prepareMappedImport(
            data: changedData,
            inspection: inspection,
            mapping: changedMapping,
            sessionID: UUID(uuidString: "00000000-0000-4000-8000-000000000083")!,
            revision: 4
        )
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("lifeos-finance-mac-cross-export-fence-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: url) }
        let store = try FinanceImportedTransactionStore(url: url)
        _ = try store.commitPreparedImport(original)
        XCTAssertThrowsError(try store.commitPreparedImport(changed)) { error in
            XCTAssertEqual(error as? FinanceImportedTransactionStoreError, .migrationRequired)
        }
        XCTAssertEqual(try store.all().count, 1)
        XCTAssertEqual(try store.importBatches().count, 1)
    }

    func testModernMappedRowsArrivingFromSyncDoNotTriggerLegacyFence() throws {
        let prepared = try preparedImport()
        let record = try FinanceImportedSyncRecord(validating: prepared.transactions[0], sourceRevision: 1)
        XCTAssertEqual(record.identityScheme, .mappedV3)
        let snapshot = try FinanceImportedSyncSnapshot(revision: 1, records: [record], tombstones: [])
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("lifeos-finance-mac-modern-sync-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: url) }
        let store = try FinanceImportedTransactionStore(url: url)
        let zeroDigest = String(repeating: "0", count: 64)
        let etag = "\"finance-imported-v2-r1-\(zeroDigest)\""
        try store.adoptRemote(
            FinanceImportedSyncResult(
                snapshot: snapshot,
                etag: etag
            )
        )
        let result = try store.commitPreparedImport(prepared)
        XCTAssertEqual(result.insertedCount, 0)
        XCTAssertEqual(result.duplicateCount, 1)
        XCTAssertEqual(try store.all().first?.identityScheme, .mappedV3)
        XCTAssertEqual(try store.importBatches().count, 1)
    }

    func testSyncedMappedRowsFenceChangedMappingInterpretationWithoutLocalReceipt() throws {
        let original = try preparedProviderImport(csv: providerCSV)
        let source = Data(providerCSV.utf8)
        let inspection = try FinanceStatementImporter.inspectCSV(data: source)
        let headers = try FinanceStatementImporter.headerColumnNames(data: source, inspection: inspection)
        let changedMapping = try mapping(
            for: headers,
            accountID: accountID,
            mappingID: secondMappingID,
            amountColumn: 3,
            sourceAccountColumn: 4,
            providerIDColumn: nil,
            merchantColumn: 2
        )
        let changed = try FinanceStatementImporter.prepareMappedImport(
            data: source,
            inspection: inspection,
            mapping: changedMapping,
            sessionID: UUID(uuidString: "00000000-0000-4000-8000-000000000084")!,
            revision: 4
        )
        let record = try FinanceImportedSyncRecord(validating: original.transactions[0], sourceRevision: 1)
        let snapshot = try FinanceImportedSyncSnapshot(revision: 1, records: [record], tombstones: [])
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("lifeos-finance-mac-modern-sync-fence-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: url) }
        let store = try FinanceImportedTransactionStore(url: url)
        let zeroDigest = String(repeating: "0", count: 64)
        try store.adoptRemote(
            FinanceImportedSyncResult(
                snapshot: snapshot,
                etag: "\"finance-imported-v2-r1-\(zeroDigest)\""
            )
        )
        XCTAssertThrowsError(try store.commitPreparedImport(changed)) { error in
            XCTAssertEqual(error as? FinanceImportedTransactionStoreError, .migrationRequired)
        }
        XCTAssertEqual(try store.all().count, 1)
        XCTAssertTrue(try store.importBatches().isEmpty)
    }

    func testLegacyGenericRowsAreFencedBeforeMappedImport() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("lifeos-finance-mac-legacy-generic-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: url) }
        let legacyRow = FinanceImportedTransaction(
            id: UUID(uuidString: "00000000-0000-4000-8000-000000000078")!,
            bookedAt: Date(timeIntervalSince1970: 1_786_449_600),
            amountCents: -1234,
            description: "Legacy generic row",
            source: .genericCSV,
            importedAt: Date(timeIntervalSince1970: 1_786_449_600)
        )
        let rowObject = try JSONSerialization.jsonObject(with: JSONEncoder.lifeOS.encode(legacyRow))
        let object: [String: Any] = [
            "schemaVersion": FinanceImportedTransactionStoreEnvelope.preProvenanceSchemaVersion,
            "transactions": [rowObject],
            "remoteRevision": 0,
            "remoteETag": NSNull(),
            "remoteRecordRevisions": [:],
            "remoteTombstones": [],
            "outbox": []
        ]
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]).write(to: url)

        let store = try FinanceImportedTransactionStore(url: url)
        XCTAssertEqual(try store.all(), [legacyRow])
        XCTAssertThrowsError(try store.commitPreparedImport(try preparedImport())) { error in
            XCTAssertEqual(error as? FinanceImportedTransactionStoreError, .migrationRequired)
        }
        XCTAssertEqual(try store.all(), [legacyRow])
    }

    func testDeletingLegacyGenericRowRemovesItsFence() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("lifeos-finance-mac-legacy-delete-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: url) }
        let legacyRow = FinanceImportedTransaction(
            id: UUID(uuidString: "00000000-0000-4000-8000-000000000079")!,
            bookedAt: Date(timeIntervalSince1970: 1_786_449_600),
            amountCents: -1234,
            description: "Legacy generic row",
            source: .genericCSV,
            importedAt: Date(timeIntervalSince1970: 1_786_449_600)
        )
        let rowObject = try JSONSerialization.jsonObject(with: JSONEncoder.lifeOS.encode(legacyRow))
        let object: [String: Any] = [
            "schemaVersion": FinanceImportedTransactionStoreEnvelope.preProvenanceSchemaVersion,
            "transactions": [rowObject],
            "remoteRevision": 0,
            "remoteETag": NSNull(),
            "remoteRecordRevisions": [:],
            "remoteTombstones": [],
            "outbox": []
        ]
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]).write(to: url)

        let store = try FinanceImportedTransactionStore(url: url)
        XCTAssertEqual(try store.all(), [legacyRow])
        try store.remove(id: legacyRow.id)
        XCTAssertTrue(try store.all().isEmpty)
        XCTAssertTrue(try store.importBatches().isEmpty)
        let envelope = try JSONDecoder.lifeOS.decode(
            FinanceImportedTransactionStoreEnvelope.self,
            from: Data(contentsOf: url)
        )
        XCTAssertTrue(envelope.legacyGenericTransactionIDs.isEmpty)
    }

    func testProviderDuplicateAndConflictDiagnosticsAreDeterministic() throws {
        let repeated = try preparedProviderImport(csv: """
        date,provider,merchant,amount,account
        2026-08-01,p-1,Coffee Shop,-4.50,checking
        2026-08-01,p-1,Coffee Shop,-4.50,checking
        """)
        XCTAssertEqual(repeated.transactions.count, 1)
        XCTAssertEqual(repeated.skippedRowCount, 1)
        XCTAssertEqual(repeated.diagnostics.last?.duplicateDisposition, .exactRepeat)

        let conflicting = try preparedProviderImport(csv: """
        date,provider,merchant,amount,account
        2026-08-01,p-1,Coffee Shop,-4.50,checking
        2026-08-01,p-1,Coffee Shop,-5.50,checking
        """)
        XCTAssertEqual(conflicting.transactions.count, 0)
        XCTAssertEqual(conflicting.skippedRowCount, 2)
        XCTAssertEqual(
            conflicting.diagnostics.map(\.duplicateDisposition),
            [.conflictingProviderID, .conflictingProviderID]
        )
    }

    func testDistinctMappedAccountsKeepRowsAndMappingsSeparate() throws {
        let first = try preparedProviderImport(
            csv: providerCSV,
            accountID: accountID,
            mappingID: mappingID
        )
        let second = try preparedProviderImport(
            csv: providerCSV,
            accountID: secondAccountID,
            mappingID: secondMappingID
        )
        XCTAssertNotEqual(first.transactions.map(\.id), second.transactions.map(\.id))

        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("lifeos-finance-mac-accounts-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: url) }
        let store = try FinanceImportedTransactionStore(url: url)
        _ = try store.commitPreparedImport(first)
        _ = try store.commitPreparedImport(second)

        XCTAssertEqual(try store.all().count, 2)
        XCTAssertEqual(try store.importMappings().count, 2)
        XCTAssertEqual(try store.importBatches().count, 2)
    }

    func testOversizedPersistedStateIsRejectedBeforeDecode() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("lifeos-finance-mac-oversized-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: url) }
        try Data(repeating: 0x20, count: FinanceImportedTransactionStore.maximumStateBytes + 1).write(to: url)

        let store = try FinanceImportedTransactionStore(url: url)
        XCTAssertThrowsError(try store.all()) { error in
            XCTAssertEqual(error as? FinanceImportedTransactionStoreError, .stateTooLarge)
        }
    }

    private func legacyIdentityRequestBody(from body: Data) throws -> Data {
        var root = try XCTUnwrap(try JSONSerialization.jsonObject(with: body) as? [String: Any])
        var operations = try XCTUnwrap(root["operations"] as? [[String: Any]])
        for index in operations.indices {
            guard var record = operations[index]["record"] as? [String: Any] else { continue }
            record.removeValue(forKey: "identityScheme")
            record.removeValue(forKey: "mappedIdentity")
            operations[index]["record"] = record
        }
        root["operations"] = operations
        return try JSONSerialization.data(withJSONObject: root, options: [.sortedKeys])
    }
}
