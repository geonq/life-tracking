import Foundation
import SQLite3
import XCTest
@testable import LifeOSMac

private final class PlanningMacErrorBox: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [Error] = []

    func append(_ error: Error) {
        lock.lock()
        values.append(error)
        lock.unlock()
    }

    var snapshot: [Error] {
        lock.lock()
        defer { lock.unlock() }
        return values
    }
}

@available(macOS 14.0, *)
final class PlanningDurabilityTests: XCTestCase {
    private func temporaryRoot(_ label: String = "durability") throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("lifeos-planning-mac-\(label)-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    private func remove(_ root: URL) {
        try? FileManager.default.removeItem(at: root)
    }

    private func vault() throws -> PlanningVaultIdentity {
        try PlanningVaultIdentity(vaultID: UUID())
    }

    private func journalDirectory(root: URL, vault: PlanningVaultIdentity) -> URL {
        root
            .appendingPathComponent("LifeOS", isDirectory: true)
            .appendingPathComponent("Planning", isDirectory: true)
            .appendingPathComponent(vault.vaultID.uuidString.lowercased(), isDirectory: true)
    }

    private func databaseURL(root: URL, vault: PlanningVaultIdentity) -> URL {
        journalDirectory(root: root, vault: vault)
            .appendingPathComponent("journal.sqlite", isDirectory: false)
    }

    private func sqliteFileBytes(root: URL, vault: PlanningVaultIdentity) -> [String: Data?] {
        let database = databaseURL(root: root, vault: vault)
        return [
            "database": try? Data(contentsOf: database),
            "wal": try? Data(contentsOf: URL(fileURLWithPath: database.path + "-wal")),
            "shm": try? Data(contentsOf: URL(fileURLWithPath: database.path + "-shm"))
        ]
    }

    private func executeSQLite(_ url: URL, sql: String) throws {
        var database: OpaquePointer?
        let openCode = url.path.withCString {
            sqlite3_open_v2($0, &database, SQLITE_OPEN_READWRITE, nil)
        }
        guard openCode == SQLITE_OK, let database else {
            if let database { sqlite3_close_v2(database) }
            throw NSError(domain: "PlanningDurabilityTests", code: Int(openCode))
        }
        defer { sqlite3_close_v2(database) }
        let executeCode = sqlite3_exec(database, sql, nil, nil, nil)
        guard executeCode == SQLITE_OK else {
            throw NSError(domain: "PlanningDurabilityTests", code: Int(executeCode))
        }
    }

    private func rebuildReceiptsTable(_ url: URL, foreignKeyClause: String?) throws {
        var database: OpaquePointer?
        let openCode = url.path.withCString {
            sqlite3_open_v2($0, &database, SQLITE_OPEN_READWRITE, nil)
        }
        guard openCode == SQLITE_OK, let database else {
            if let database { sqlite3_close_v2(database) }
            throw NSError(domain: "PlanningDurabilityTests", code: Int(openCode))
        }
        var transactionOpen = false
        defer {
            if transactionOpen {
                _ = sqlite3_exec(database, "ROLLBACK", nil, nil, nil)
            }
            sqlite3_close_v2(database)
        }

        let execute: (String) throws -> Void = { statement in
            let code = sqlite3_exec(database, statement, nil, nil, nil)
            guard code == SQLITE_OK else {
                throw NSError(domain: "PlanningDurabilityTests", code: Int(code))
            }
        }
        try execute("PRAGMA foreign_keys = OFF")
        try execute("BEGIN")
        transactionOpen = true
        try execute("ALTER TABLE receipts RENAME TO receipts_original")
        let foreignKeyClause = foreignKeyClause.map { " \($0)" } ?? ""
        let createReceiptsTable = [
            "CREATE TABLE receipts(",
            "    mutation_id TEXT NOT NULL PRIMARY KEY" + foreignKeyClause + ",",
            "    fingerprint TEXT NOT NULL,",
            "    state TEXT NOT NULL,",
            "    result_version TEXT,",
            "    error_code TEXT,",
            "    updated_at REAL NOT NULL",
            ")"
        ].joined(separator: "\n")
        try execute(createReceiptsTable)
        try execute(
            """
            INSERT INTO receipts(mutation_id, fingerprint, state, result_version, error_code, updated_at)
            SELECT mutation_id, fingerprint, state, result_version, error_code, updated_at
            FROM receipts_original
            """
        )
        try execute("DROP TABLE receipts_original")
        try execute("COMMIT")
        transactionOpen = false
    }

    private func rebuildMutationsTableWithPartialFingerprintIndex(_ url: URL) throws {
        var database: OpaquePointer?
        let openCode = url.path.withCString {
            sqlite3_open_v2($0, &database, SQLITE_OPEN_READWRITE, nil)
        }
        guard openCode == SQLITE_OK, let database else {
            if let database { sqlite3_close_v2(database) }
            throw NSError(domain: "PlanningDurabilityTests", code: Int(openCode))
        }
        var transactionOpen = false
        defer {
            if transactionOpen {
                _ = sqlite3_exec(database, "ROLLBACK", nil, nil, nil)
            }
            _ = sqlite3_exec(database, "PRAGMA legacy_alter_table = OFF", nil, nil, nil)
            _ = sqlite3_exec(database, "PRAGMA foreign_keys = ON", nil, nil, nil)
            sqlite3_close_v2(database)
        }

        let execute: (String) throws -> Void = { statement in
            let code = sqlite3_exec(database, statement, nil, nil, nil)
            guard code == SQLITE_OK else {
                throw NSError(domain: "PlanningDurabilityTests", code: Int(code))
            }
        }
        try execute("PRAGMA foreign_keys = OFF")
        try execute("PRAGMA legacy_alter_table = ON")
        try execute("BEGIN")
        transactionOpen = true
        try execute("ALTER TABLE mutations RENAME TO mutations_original")
        try execute(
            """
            CREATE TABLE mutations(
                sequence INTEGER NOT NULL PRIMARY KEY AUTOINCREMENT,
                mutation_id TEXT NOT NULL UNIQUE,
                fingerprint TEXT NOT NULL,
                vault_id TEXT NOT NULL,
                path TEXT NOT NULL,
                operation TEXT NOT NULL,
                expected_version TEXT NOT NULL,
                proposed_digest TEXT,
                state TEXT NOT NULL,
                error_code TEXT,
                created_at REAL NOT NULL,
                updated_at REAL NOT NULL
            )
            """
        )
        try execute(
            """
            INSERT INTO mutations(
                sequence, mutation_id, fingerprint, vault_id, path, operation,
                expected_version, proposed_digest, state, error_code, created_at, updated_at
            )
            SELECT
                sequence, mutation_id, fingerprint, vault_id, path, operation,
                expected_version, proposed_digest, state, error_code, created_at, updated_at
            FROM mutations_original
            """
        )
        try execute("DROP TABLE mutations_original")
        try execute("CREATE INDEX mutations_nonterminal ON mutations(state, sequence)")
        try execute("CREATE INDEX mutations_fingerprint ON mutations(fingerprint)")
        try execute(
            "CREATE UNIQUE INDEX mutations_fingerprint_partial ON mutations(fingerprint) WHERE fingerprint IS NOT NULL"
        )
        try execute("COMMIT")
        transactionOpen = false
    }

    private func scalarInt(_ url: URL, sql: String) throws -> Int {
        var database: OpaquePointer?
        let openCode = url.path.withCString {
            sqlite3_open_v2($0, &database, SQLITE_OPEN_READONLY, nil)
        }
        guard openCode == SQLITE_OK, let database else {
            if let database { sqlite3_close_v2(database) }
            throw NSError(domain: "PlanningDurabilityTests", code: Int(openCode))
        }
        defer { sqlite3_close_v2(database) }

        var statement: OpaquePointer?
        let prepareCode = sqlite3_prepare_v2(database, sql, -1, &statement, nil)
        guard prepareCode == SQLITE_OK, let statement else {
            throw NSError(domain: "PlanningDurabilityTests", code: Int(prepareCode))
        }
        defer { sqlite3_finalize(statement) }
        guard sqlite3_step(statement) == SQLITE_ROW else {
            throw NSError(domain: "PlanningDurabilityTests", code: 2)
        }
        return Int(sqlite3_column_int64(statement, 0))
    }

    private func assertCorruptReopen(
        root: URL,
        vault: PlanningVaultIdentity,
        database: URL,
        unchangedBytes: Data
    ) throws {
        let reopened = PlanningMutationJournal(
            applicationSupportDirectory: root,
            vault: vault
        )
        defer { reopened.close() }
        XCTAssertThrowsError(try reopened.openValidated()) { error in
            XCTAssertEqual(error as? PlanningStorageError, .corruptDatabase)
        }
        XCTAssertEqual(try Data(contentsOf: database), unchangedBytes)
    }

    private func createRequest(
        vaultID: UUID,
        mutationID: UUID = UUID(),
        path: String = "Notes/empty.md",
        proposedBytes: Data = Data()
    ) throws -> PlanningMutationRequest {
        try PlanningMutationRequest(
            mutationID: mutationID,
            vaultID: vaultID,
            path: try PlanningStoredPath(path),
            operation: .create,
            expectedVersion: .absent,
            proposedBytes: proposedBytes
        )
    }

    private func roundTrip<T: Codable & Equatable>(_ value: T) throws -> T {
        try JSONDecoder().decode(T.self, from: JSONEncoder().encode(value))
    }

    private func publicationContext(
        for request: PlanningMutationRequest
    ) throws -> PlanningPublicationContext {
        let root = try PlanningFileIdentity(device: 10, inode: 20, fileType: 2)
        let observedIdentity: PlanningFileIdentity?
        switch request.expectedVersion {
        case .absent:
            observedIdentity = nil
        case .bytes:
            observedIdentity = try PlanningFileIdentity(device: 11, inode: 21, fileType: 1)
        }
        return try PlanningPublicationContext(
            selectionGeneration: UUID(),
            rootIdentity: root,
            observedVersion: request.expectedVersion,
            observedIdentity: observedIdentity
        )
    }

    private func publish(
        _ journal: PlanningMutationJournal,
        request: PlanningMutationRequest
    ) throws -> PlanningMutationReceipt {
        let attemptID = try journal.beginPublication(for: request.mutationID)
        if request.operation != .delete {
            let identity = try PlanningFileIdentity(device: 30, inode: 40, fileType: 1)
            try journal.recordStagedIdentity(
                mutationID: request.mutationID,
                attemptID: attemptID,
                identity: identity,
                witnessName: ".lifeos-stage-\(attemptID.uuidString.lowercased())"
            )
        }
        try journal.markPublishing(
            mutationID: request.mutationID,
            attemptID: attemptID,
            context: try publicationContext(for: request)
        )
        let result = request.proposedBytes.map(PlanningContentVersion.init(data:)) ?? .absent
        return try journal.recordPublicationOutcome(
            mutationID: request.mutationID,
            attemptID: attemptID,
            outcome: .published(result)
        )
    }

    private func deleteRequest(
        vaultID: UUID,
        mutationID: UUID = UUID(),
        path: String = "Notes/delete.md"
    ) throws -> PlanningMutationRequest {
        try PlanningMutationRequest(
            mutationID: mutationID,
            vaultID: vaultID,
            path: try PlanningStoredPath(path),
            operation: .delete,
            expectedVersion: PlanningContentVersion(data: Data("old".utf8)),
            proposedBytes: nil
        )
    }

    private func canvasRequest(
        vaultID: UUID,
        mutationID: UUID = UUID(),
        path: String,
        proposedBytes: Data = Data("{\"nodes\":[],\"edges\":[]}".utf8)
    ) throws -> PlanningMutationRequest {
        try PlanningMutationRequest(
            mutationID: mutationID,
            vaultID: vaultID,
            path: try PlanningStoredPath(path),
            operation: .create,
            expectedVersion: .absent,
            proposedBytes: proposedBytes
        )
    }

    private func openConflict(
        _ journal: PlanningMutationJournal,
        request: PlanningMutationRequest,
        conflictID: UUID = UUID(),
        observedBytes: Data? = Data("observed".utf8)
    ) throws -> PlanningConflict {
        let observedVersion = observedBytes.map(PlanningContentVersion.init(data:)) ?? .absent
        return try PlanningConflict(
            conflictID: conflictID,
            mutationID: request.mutationID,
            vaultID: request.vaultID,
            path: request.path,
            operation: request.operation,
            reason: "observed",
            baseVersion: request.expectedVersion,
            localBytes: request.proposedBytes,
            observedVersion: observedVersion,
            observedBytes: observedBytes
        )
    }

    private func setSQLiteUserVersion(_ version: UInt32, in data: inout Data) throws {
        guard data.count >= 64 else {
            throw NSError(domain: "PlanningDurabilityTests", code: 1)
        }
        let bytes = [
            UInt8((version >> 24) & 0xff),
            UInt8((version >> 16) & 0xff),
            UInt8((version >> 8) & 0xff),
            UInt8(version & 0xff)
        ]
        data.replaceSubrange(60..<64, with: bytes)
    }

    func testFreshJournalPersistsMutationAcrossReopen() throws {
        let root = try temporaryRoot()
        defer { remove(root) }
        let identity = try vault()
        let mutationID = UUID()
        let request = try createRequest(vaultID: identity.vaultID, mutationID: mutationID)

        let first = PlanningMutationJournal(applicationSupportDirectory: root, vault: identity)
        defer { first.close() }
        try first.openValidated()
        let pragmas = try first.debugPragmaSnapshot()
        XCTAssertEqual(pragmas.journalMode, "delete")
        XCTAssertEqual(pragmas.synchronous, 3)
        XCTAssertEqual(pragmas.foreignKeys, 1)
        XCTAssertEqual(pragmas.busyTimeout, 1_000)
        let staged = try first.stageMutation(request)
        XCTAssertEqual(staged.mutationID, mutationID)
        XCTAssertEqual(staged.fingerprint, request.fingerprint)
        XCTAssertEqual(staged.state, .staged)
        XCTAssertEqual(try first.status().pendingMutationCount, 1)

        let database = databaseURL(root: root, vault: identity)
        XCTAssertTrue(FileManager.default.fileExists(atPath: database.path))
        XCTAssertGreaterThan(try Data(contentsOf: database).count, 64)
        XCTAssertEqual(try scalarInt(database, sql: "PRAGMA user_version"), 2)
        XCTAssertEqual(try scalarInt(database, sql: "SELECT COUNT(*) FROM vault"), 1)
        XCTAssertEqual(try scalarInt(database, sql: "SELECT COUNT(*) FROM sqlite_master WHERE type = 'table' AND name = 'mutations'"), 1)
        first.close()

        let reopened = PlanningMutationJournal(applicationSupportDirectory: root, vault: identity)
        defer { reopened.close() }
        try reopened.openValidated()
        XCTAssertEqual(try reopened.receipt(for: mutationID), staged)
        XCTAssertEqual(try reopened.status().pendingMutationCount, 1)
    }

    func testEquivalentMutationReplayIsIdempotentAndChangedRequestIsRejected() throws {
        let root = try temporaryRoot("idempotency")
        defer { remove(root) }
        let identity = try vault()
        let journal = PlanningMutationJournal(applicationSupportDirectory: root, vault: identity)
        defer { journal.close() }
        try journal.openValidated()

        let mutationID = UUID()
        let request = try createRequest(vaultID: identity.vaultID, mutationID: mutationID)
        let first = try journal.stageMutation(request)
        let replay = try journal.stageMutation(request)

        XCTAssertEqual(replay, first)
        XCTAssertEqual(try journal.status().pendingMutationCount, 1)

        let changed = try createRequest(
            vaultID: identity.vaultID,
            mutationID: mutationID,
            path: "Notes/other.md"
        )
        XCTAssertThrowsError(try journal.stageMutation(changed)) { error in
            XCTAssertEqual(error as? PlanningStorageError, .mutationIDReused)
        }
        XCTAssertEqual(try journal.status().pendingMutationCount, 1)
    }

    func testCompletedMutationAllowsNewPendingHistoryAndReopens() throws {
        let root = try temporaryRoot("history")
        defer { remove(root) }
        let identity = try vault()
        let journal = PlanningMutationJournal(applicationSupportDirectory: root, vault: identity)
        try journal.openValidated()

        let first = try createRequest(vaultID: identity.vaultID, path: "Notes/history.md")
        let firstStaged = try journal.stageMutation(first)
        let published = try publish(journal, request: first)
        XCTAssertEqual(published.state, .published)

        let second = try createRequest(
            vaultID: identity.vaultID,
            path: first.path.value,
            proposedBytes: Data("next".utf8)
        )
        let secondStaged = try journal.stageMutation(second)
        XCTAssertEqual(try journal.receipt(for: first.mutationID), published)
        XCTAssertEqual(try journal.receipt(for: second.mutationID), secondStaged)
        XCTAssertEqual(try journal.status().pendingMutationCount, 1)
        journal.close()

        let reopened = PlanningMutationJournal(applicationSupportDirectory: root, vault: identity)
        defer { reopened.close() }
        try reopened.openValidated()
        XCTAssertEqual(try reopened.receipt(for: first.mutationID), published)
        XCTAssertEqual(try reopened.receipt(for: second.mutationID), secondStaged)
        XCTAssertEqual(firstStaged.fingerprint, first.fingerprint)
    }

    func testSecondWriterIsRejectedUntilTheFirstReleasesItsLock() throws {
        let root = try temporaryRoot("writer")
        defer { remove(root) }
        let identity = try vault()
        let first = PlanningMutationJournal(applicationSupportDirectory: root, vault: identity)
        let second = PlanningMutationJournal(applicationSupportDirectory: root, vault: identity)
        defer {
            first.close()
            second.close()
        }

        try first.openValidated()
        XCTAssertThrowsError(try second.openValidated()) { error in
            XCTAssertEqual(error as? PlanningStorageError, .writerBusy)
        }

        first.close()
        try second.openValidated()
        XCTAssertEqual(try second.status().accessState, .ready)
        second.close()

        XCTAssertThrowsError(try second.openValidated()) { error in
            XCTAssertEqual(error as? PlanningStorageError, .closed)
        }
    }

    func testCorruptAndUnsupportedJournalInputsFailClosedWithoutRepair() throws {
        let corruptRoot = try temporaryRoot("corrupt")
        defer { remove(corruptRoot) }
        let corruptIdentity = try vault()
        let corruptURL = databaseURL(root: corruptRoot, vault: corruptIdentity)
        try FileManager.default.createDirectory(
            at: corruptURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let corruptBytes = Data([0x53, 0x51, 0x4c, 0x69, 0x74, 0x65, 0x20, 0x66])
        try corruptBytes.write(to: corruptURL, options: .atomic)

        let corruptJournal = PlanningMutationJournal(
            applicationSupportDirectory: corruptRoot,
            vault: corruptIdentity
        )
        XCTAssertThrowsError(try corruptJournal.openValidated())
        XCTAssertEqual(try Data(contentsOf: corruptURL), corruptBytes)
        corruptJournal.close()

        let unsupportedRoot = try temporaryRoot("unsupported")
        defer { remove(unsupportedRoot) }
        let unsupportedIdentity = try vault()
        let seed = PlanningMutationJournal(
            applicationSupportDirectory: unsupportedRoot,
            vault: unsupportedIdentity
        )
        try seed.openValidated()
        seed.close()

        let unsupportedURL = databaseURL(root: unsupportedRoot, vault: unsupportedIdentity)
        var unsupportedBytes = try Data(contentsOf: unsupportedURL)
        try setSQLiteUserVersion(77, in: &unsupportedBytes)
        try unsupportedBytes.write(to: unsupportedURL, options: .atomic)

        let before = try Data(contentsOf: unsupportedURL)
        let unsupportedJournal = PlanningMutationJournal(
            applicationSupportDirectory: unsupportedRoot,
            vault: unsupportedIdentity
        )
        XCTAssertThrowsError(try unsupportedJournal.openValidated()) { error in
            XCTAssertEqual(error as? PlanningStorageError, .unsupportedSchema(77))
        }
        XCTAssertEqual(try Data(contentsOf: unsupportedURL), before)
        unsupportedJournal.close()
    }

    func testProductionValidationRejectsInvalidDomainAndPersistedValues() throws {
        XCTAssertThrowsError(
            try PlanningContentVersion(sha256: "not-a-sha256", byteCount: 0)
        ) { error in
            XCTAssertEqual(error as? PlanningStorageError, .invalid("contentVersion"))
        }

        let unknownKey = Data(#"{"kind":"absent","unexpected":true}"#.utf8)
        XCTAssertThrowsError(
            try JSONDecoder().decode(PlanningContentVersion.self, from: unknownKey)
        ) { error in
            XCTAssertEqual(error as? PlanningStorageError, .invalid("contentVersion.keys"))
        }

        XCTAssertThrowsError(try PlanningStoredPath("../Notes.md"))
        XCTAssertThrowsError(try PlanningStoredPath("C:\\Notes\\unsafe.md"))
    }

    func testOptionalCodableFieldsRoundTripOnMacRuntime() throws {
        let identity = try vault()
        let deviceID = UUID()
        let generation = UUID()
        let fileIdentity = try PlanningFileIdentity(device: 1, inode: 2, fileType: 1)
        let path = try PlanningStoredPath("Notes/empty.md")
        let version = PlanningContentVersion(data: Data())
        let create = try createRequest(vaultID: identity.vaultID, path: path.value)
        let delete = try PlanningMutationRequest(
            mutationID: UUID(),
            vaultID: identity.vaultID,
            path: path,
            operation: .delete,
            expectedVersion: version,
            proposedBytes: nil
        )
        let fullGrant = try PlanningDeviceVaultGrant(
            deviceID: deviceID,
            vaultID: identity.vaultID,
            bookmarkData: Data([1, 2]),
            selectionGeneration: generation,
            lastValidatedRootIdentity: fileIdentity
        )
        let minimalGrant = try PlanningDeviceVaultGrant(
            deviceID: deviceID,
            vaultID: identity.vaultID,
            bookmarkData: Data(),
            selectionGeneration: generation
        )
        let fullObservation = try PlanningFileObservation(
            path: path,
            version: version,
            identity: fileIdentity,
            byteCount: 0,
            observedAt: Date(timeIntervalSince1970: 0)
        )
        let minimalObservation = try PlanningFileObservation(
            path: path,
            version: version,
            identity: nil,
            byteCount: 0,
            observedAt: Date(timeIntervalSince1970: 0)
        )
        let fullReceipt = try PlanningMutationReceipt(
            mutationID: create.mutationID,
            fingerprint: create.fingerprint,
            state: .published,
            resultVersion: version,
            errorCode: "ok",
            updatedAt: Date(timeIntervalSince1970: 0)
        )
        let minimalReceipt = try PlanningMutationReceipt(
            mutationID: delete.mutationID,
            fingerprint: delete.fingerprint,
            state: .staged,
            updatedAt: Date(timeIntervalSince1970: 0)
        )
        let fullConflict = try PlanningConflict(
            mutationID: create.mutationID,
            vaultID: identity.vaultID,
            path: path,
            operation: .create,
            reason: "observed",
            baseVersion: .absent,
            localBytes: Data(),
            observedVersion: version,
            observedBytes: Data()
        )
        let minimalConflict = try PlanningConflict(
            mutationID: delete.mutationID,
            vaultID: identity.vaultID,
            path: path,
            operation: .delete,
            reason: "observed",
            baseVersion: version,
            localBytes: nil,
            observedVersion: .absent,
            observedBytes: nil
        )
        let fullStatus = try PlanningStoreStatus(
            accessState: .ready,
            pendingMutationCount: 1,
            openConflictCount: 2,
            retainedPayloadBytes: 3,
            databaseBytes: 4,
            lastErrorCode: "temporary"
        )
        let minimalStatus = try PlanningStoreStatus(
            accessState: .unselected,
            pendingMutationCount: 0,
            openConflictCount: 0,
            retainedPayloadBytes: 0,
            databaseBytes: 0
        )

        XCTAssertEqual(try roundTrip(fullGrant), fullGrant)
        XCTAssertEqual(try roundTrip(minimalGrant), minimalGrant)
        XCTAssertEqual(try roundTrip(fullObservation), fullObservation)
        XCTAssertEqual(try roundTrip(minimalObservation), minimalObservation)
        XCTAssertEqual(try roundTrip(create), create)
        XCTAssertEqual(try roundTrip(delete), delete)
        XCTAssertEqual(try roundTrip(fullReceipt), fullReceipt)
        XCTAssertEqual(try roundTrip(minimalReceipt), minimalReceipt)
        XCTAssertEqual(try roundTrip(fullConflict), fullConflict)
        XCTAssertEqual(try roundTrip(minimalConflict), minimalConflict)
        XCTAssertEqual(try roundTrip(fullStatus), fullStatus)
        XCTAssertEqual(try roundTrip(minimalStatus), minimalStatus)
    }

    func testPendingMutationReservesCanonicalPathOnMacRuntime() throws {
        let root = try temporaryRoot("collision")
        defer { remove(root) }
        let identity = try vault()
        let journal = PlanningMutationJournal(applicationSupportDirectory: root, vault: identity)
        defer { journal.close() }
        try journal.openValidated()

        let first = try createRequest(
            vaultID: identity.vaultID,
            path: "Notes/Plan.md"
        )
        XCTAssertNoThrow(try journal.stageMutation(first))
        XCTAssertEqual(try journal.stageMutation(first), try journal.receipt(for: first.mutationID))

        let alias = try createRequest(vaultID: identity.vaultID, path: "notes/plan.md")
        XCTAssertThrowsError(try journal.stageMutation(alias)) { error in
            XCTAssertEqual(error as? PlanningStorageError, .invalid("mutation.pathCollision"))
        }
    }

    func testPublishedReceiptWithOversizedResultVersionMapsToCorruptDatabase() throws {
        let root = try temporaryRoot("receipt-version")
        defer { remove(root) }
        let identity = try vault()
        let journal = PlanningMutationJournal(applicationSupportDirectory: root, vault: identity)
        try journal.openValidated()
        let request = try createRequest(
            vaultID: identity.vaultID,
            path: "Notes/published.md"
        )
        _ = try journal.stageMutation(request)
        _ = try publish(journal, request: request)
        journal.close()

        guard let digest = PlanningContentVersion(data: Data()).digest else {
            XCTFail("empty-data digest must be present")
            return
        }
        let database = databaseURL(root: root, vault: identity)
        try executeSQLite(
            database,
            sql: "UPDATE receipts SET result_version = 'bytes:\(digest):\(PlanningStorageLimits.markdownBytes + 1)'"
        )
        let tamperedBytes = try Data(contentsOf: database)
        try assertCorruptReopen(
            root: root,
            vault: identity,
            database: database,
            unchangedBytes: tamperedBytes
        )
    }

    func testInvalidAndMissingPayloadsMapToCorruptDatabase() throws {
        let tamperStatements = [
            "UPDATE payloads SET byte_count = byte_count + 1",
            "UPDATE payloads SET bytes = X'FF'"
        ]
        for (index, statement) in tamperStatements.enumerated() {
            let root = try temporaryRoot("payload-invalid-\(index)")
            defer { remove(root) }
            let identity = try vault()
            let journal = PlanningMutationJournal(applicationSupportDirectory: root, vault: identity)
            try journal.openValidated()
            _ = try journal.stageMutation(
                createRequest(
                    vaultID: identity.vaultID,
                    path: "Notes/payload-\(index).md",
                    proposedBytes: Data("payload".utf8)
                )
            )
            journal.close()

            let database = databaseURL(root: root, vault: identity)
            try executeSQLite(database, sql: statement)
            let tamperedBytes = try Data(contentsOf: database)
            try assertCorruptReopen(
                root: root,
                vault: identity,
                database: database,
                unchangedBytes: tamperedBytes
            )
        }

        let root = try temporaryRoot("payload-missing")
        defer { remove(root) }
        let identity = try vault()
        let journal = PlanningMutationJournal(applicationSupportDirectory: root, vault: identity)
        try journal.openValidated()
        _ = try journal.stageMutation(
            createRequest(
                vaultID: identity.vaultID,
                path: "Notes/missing-payload.md",
                proposedBytes: Data("payload".utf8)
            )
        )
        journal.close()

        let database = databaseURL(root: root, vault: identity)
        try executeSQLite(database, sql: "DELETE FROM payloads")
        let tamperedBytes = try Data(contentsOf: database)
        try assertCorruptReopen(
            root: root,
            vault: identity,
            database: database,
            unchangedBytes: tamperedBytes
        )
    }

    func testUnreferencedOversizedCanvasPayloadMapsToCorruptDatabase() throws {
        let root = try temporaryRoot("payload-oversized-canvas")
        defer { remove(root) }
        let identity = try vault()
        let journal = PlanningMutationJournal(applicationSupportDirectory: root, vault: identity)
        try journal.openValidated()
        journal.close()

        let size = PlanningStorageLimits.canvasBytes + 1
        let digestData = Data(repeating: 0, count: size)
        guard let digest = PlanningContentVersion(data: digestData).digest else {
            XCTFail("oversized canvas digest must be present")
            return
        }
        let database = databaseURL(root: root, vault: identity)
        try executeSQLite(
            database,
            sql: "INSERT INTO payloads(digest, byte_count, bytes) VALUES ('\(digest)', \(size), zeroblob(\(size)))"
        )
        let tamperedBytes = try Data(contentsOf: database)
        try assertCorruptReopen(
            root: root,
            vault: identity,
            database: database,
            unchangedBytes: tamperedBytes
        )
    }

    func testTerminalAndUnknownReservationOwnersMapToCorruptDatabase() throws {
        let terminalRoot = try temporaryRoot("terminal-reservation")
        defer { remove(terminalRoot) }
        let terminalVault = try vault()
        let terminalJournal = PlanningMutationJournal(
            applicationSupportDirectory: terminalRoot,
            vault: terminalVault
        )
        try terminalJournal.openValidated()
        let terminalRequest = try createRequest(
            vaultID: terminalVault.vaultID,
            path: "Notes/terminal.md"
        )
        _ = try terminalJournal.stageMutation(terminalRequest)
        _ = try publish(terminalJournal, request: terminalRequest)
        terminalJournal.close()

        let terminalDatabase = databaseURL(root: terminalRoot, vault: terminalVault)
        try executeSQLite(
            terminalDatabase,
            sql: "INSERT INTO mutation_reservations(collision_key, mutation_id) VALUES ('\(terminalRequest.path.collisionKey)', '\(terminalRequest.mutationID.uuidString.lowercased())')"
        )
        let terminalBytes = try Data(contentsOf: terminalDatabase)
        try assertCorruptReopen(
            root: terminalRoot,
            vault: terminalVault,
            database: terminalDatabase,
            unchangedBytes: terminalBytes
        )

        let unknownRoot = try temporaryRoot("unknown-reservation")
        defer { remove(unknownRoot) }
        let unknownVault = try vault()
        let unknownJournal = PlanningMutationJournal(
            applicationSupportDirectory: unknownRoot,
            vault: unknownVault
        )
        try unknownJournal.openValidated()
        unknownJournal.close()

        let unknownDatabase = databaseURL(root: unknownRoot, vault: unknownVault)
        try executeSQLite(
            unknownDatabase,
            sql: "PRAGMA foreign_keys = OFF; INSERT INTO mutation_reservations(collision_key, mutation_id) VALUES ('notes/unknown.md', '00000000-0000-0000-0000-000000000099')"
        )
        let unknownBytes = try Data(contentsOf: unknownDatabase)
        try assertCorruptReopen(
            root: unknownRoot,
            vault: unknownVault,
            database: unknownDatabase,
            unchangedBytes: unknownBytes
        )
    }

    func testAlteredPersistedMutationTextMapsToCorruptDatabase() throws {
        let tamperStatements = [
            "UPDATE mutations SET fingerprint = '0000000000000000000000000000000000000000000000000000000000000000'",
            "UPDATE mutations SET path = '../tampered.md'"
        ]
        for (index, statement) in tamperStatements.enumerated() {
            let root = try temporaryRoot("mutation-text-\(index)")
            defer { remove(root) }
            let identity = try vault()
            let journal = PlanningMutationJournal(applicationSupportDirectory: root, vault: identity)
            try journal.openValidated()
            _ = try journal.stageMutation(
                createRequest(
                    vaultID: identity.vaultID,
                    path: "Notes/tampered-\(index).md"
                )
            )
            journal.close()

            let database = databaseURL(root: root, vault: identity)
            try executeSQLite(database, sql: statement)
            let tamperedBytes = try Data(contentsOf: database)
            try assertCorruptReopen(
                root: root,
                vault: identity,
                database: database,
                unchangedBytes: tamperedBytes
            )
        }
    }

    func testEmbeddedNULAndInvalidUTF8PersistedTextMapToCorruptDatabase() throws {
        let nulRoot = try temporaryRoot("unsafe-text-nul")
        defer { remove(nulRoot) }
        let nulIdentity = try vault()
        let nulJournal = PlanningMutationJournal(
            applicationSupportDirectory: nulRoot,
            vault: nulIdentity
        )
        try nulJournal.openValidated()
        let nulRequest = try createRequest(
            vaultID: nulIdentity.vaultID,
            path: "Notes/unsafe-0.md"
        )
        _ = try nulJournal.stageMutation(nulRequest)
        nulJournal.close()

        let nulDatabase = databaseURL(root: nulRoot, vault: nulIdentity)
        try executeSQLite(
            nulDatabase,
            sql: "UPDATE mutations SET path = path || char(0) || 'suffix', fingerprint = fingerprint || char(0) || 'suffix' WHERE mutation_id = '\(nulRequest.mutationID.uuidString.lowercased())'"
        )
        let nulTamperedBytes = try Data(contentsOf: nulDatabase)
        try assertCorruptReopen(
            root: nulRoot,
            vault: nulIdentity,
            database: nulDatabase,
            unchangedBytes: nulTamperedBytes
        )

        let invalidUTF8Root = try temporaryRoot("unsafe-text-utf8")
        defer { remove(invalidUTF8Root) }
        let invalidUTF8Identity = try vault()
        let invalidUTF8Journal = PlanningMutationJournal(
            applicationSupportDirectory: invalidUTF8Root,
            vault: invalidUTF8Identity
        )
        try invalidUTF8Journal.openValidated()
        let invalidUTF8Request = try createRequest(
            vaultID: invalidUTF8Identity.vaultID,
            path: "Notes/unsafe-1.md"
        )
        _ = try invalidUTF8Journal.stageMutation(invalidUTF8Request)
        invalidUTF8Journal.close()

        let invalidUTF8Database = databaseURL(root: invalidUTF8Root, vault: invalidUTF8Identity)
        try executeSQLite(
            invalidUTF8Database,
            sql: "UPDATE mutations SET fingerprint = CAST(X'FF' AS TEXT) WHERE mutation_id = '\(invalidUTF8Request.mutationID.uuidString.lowercased())'"
        )
        let invalidUTF8TamperedBytes = try Data(contentsOf: invalidUTF8Database)
        try assertCorruptReopen(
            root: invalidUTF8Root,
            vault: invalidUTF8Identity,
            database: invalidUTF8Database,
            unchangedBytes: invalidUTF8TamperedBytes
        )
    }

    func testPublicTextInputsRejectNULWithoutPublishingTruncatedRows() throws {
        let identity = try PlanningFileIdentity(device: 1, inode: 2, fileType: 1)

        let witnessRoot = try temporaryRoot("write-text-witness")
        defer { remove(witnessRoot) }
        let witnessVault = try vault()
        let witnessJournal = PlanningMutationJournal(
            applicationSupportDirectory: witnessRoot,
            vault: witnessVault
        )
        defer { witnessJournal.close() }
        try witnessJournal.openValidated()
        let witnessRequest = try createRequest(
            vaultID: witnessVault.vaultID,
            path: "Notes/write-witness.md"
        )
        _ = try witnessJournal.stageMutation(witnessRequest)
        let witnessAttempt = try witnessJournal.beginPublication(for: witnessRequest.mutationID)
        XCTAssertThrowsError(
            try witnessJournal.recordStagedIdentity(
                mutationID: witnessRequest.mutationID,
                attemptID: witnessAttempt,
                identity: identity,
                witnessName: "Mac\0suffix"
            )
        ) { error in
            XCTAssertEqual(error as? PlanningStorageError, .invalid("publication.witnessName.nul"))
        }
        XCTAssertEqual(
            try witnessJournal.receipt(for: witnessRequest.mutationID)?.state,
            .prepared
        )
        XCTAssertNoThrow(
            try witnessJournal.recordStagedIdentity(
                mutationID: witnessRequest.mutationID,
                attemptID: witnessAttempt,
                identity: identity,
                witnessName: ".lifeos-stage-\(witnessAttempt.uuidString.lowercased())"
            )
        )
        XCTAssertEqual(
            try witnessJournal.receipt(for: witnessRequest.mutationID)?.state,
            .stageReady
        )

        XCTAssertThrowsError(
            try witnessJournal.recordPublicationOutcome(
                mutationID: witnessRequest.mutationID,
                attemptID: witnessAttempt,
                outcome: .failed(code: "io\0truncated", retryable: true)
            )
        ) { error in
            XCTAssertEqual(error as? PlanningStorageError, .invalid("publication.errorCode.nul"))
        }
        let afterNULFailure = try XCTUnwrap(
            try witnessJournal.receipt(for: witnessRequest.mutationID)
        )
        XCTAssertEqual(afterNULFailure.state, .stageReady)
        XCTAssertNil(afterNULFailure.errorCode)
        let validFailure = try witnessJournal.recordPublicationOutcome(
            mutationID: witnessRequest.mutationID,
            attemptID: witnessAttempt,
            outcome: .failed(code: "io", retryable: true)
        )
        XCTAssertEqual(validFailure.state, .prepared)
        XCTAssertEqual(validFailure.errorCode, "io")

        let conflictRoot = try temporaryRoot("write-text-conflict")
        defer { remove(conflictRoot) }
        let conflictVault = try vault()
        let conflictJournal = PlanningMutationJournal(
            applicationSupportDirectory: conflictRoot,
            vault: conflictVault
        )
        defer { conflictJournal.close() }
        try conflictJournal.openValidated()
        let conflictRequest = try createRequest(
            vaultID: conflictVault.vaultID,
            path: "Notes/write-conflict.md"
        )
        let staged = try conflictJournal.stageMutation(conflictRequest)
        let invalidConflict = try PlanningConflict(
            mutationID: conflictRequest.mutationID,
            vaultID: conflictVault.vaultID,
            path: conflictRequest.path,
            operation: .create,
            reason: "observed\0truncated",
            baseVersion: .absent,
            localBytes: Data(),
            observedVersion: .absent,
            observedBytes: nil
        )
        XCTAssertThrowsError(try conflictJournal.recordConflict(invalidConflict)) { error in
            XCTAssertEqual(error as? PlanningStorageError, .invalid("persistedText.nul"))
        }
        XCTAssertEqual(try conflictJournal.receipt(for: conflictRequest.mutationID), staged)
        XCTAssertEqual(try conflictJournal.status().openConflictCount, 0)

        let validConflict = try PlanningConflict(
            mutationID: conflictRequest.mutationID,
            vaultID: conflictVault.vaultID,
            path: conflictRequest.path,
            operation: .create,
            reason: "observed",
            baseVersion: .absent,
            localBytes: Data(),
            observedVersion: .absent,
            observedBytes: nil
        )
        let conflictReceipt = try conflictJournal.recordConflict(validConflict)
        XCTAssertEqual(conflictReceipt.state, .conflicted)
        XCTAssertEqual(try conflictJournal.status().openConflictCount, 1)
    }

    func testPartialUniqueAndAlteredForeignKeySchemasFailClosedWithoutRepair() throws {
        let partialRoot = try temporaryRoot("schema-adversarial-partial")
        defer { remove(partialRoot) }
        let partialIdentity = try vault()
        let partialJournal = PlanningMutationJournal(
            applicationSupportDirectory: partialRoot,
            vault: partialIdentity
        )
        try partialJournal.openValidated()
        partialJournal.close()

        let partialDatabase = databaseURL(root: partialRoot, vault: partialIdentity)
        try rebuildMutationsTableWithPartialFingerprintIndex(partialDatabase)
        let partialTamperedBytes = try Data(contentsOf: partialDatabase)
        try assertCorruptReopen(
            root: partialRoot,
            vault: partialIdentity,
            database: partialDatabase,
            unchangedBytes: partialTamperedBytes
        )

        let receiptForeignKeys: [String?] = [
            "REFERENCES mutations(mutation_id) ON DELETE CASCADE",
            nil
        ]
        for (index, foreignKeyClause) in receiptForeignKeys.enumerated() {
            let root = try temporaryRoot("schema-adversarial-fk-\(index)")
            defer { remove(root) }
            let identity = try vault()
            let journal = PlanningMutationJournal(applicationSupportDirectory: root, vault: identity)
            try journal.openValidated()
            journal.close()

            let database = databaseURL(root: root, vault: identity)
            try rebuildReceiptsTable(database, foreignKeyClause: foreignKeyClause)
            let tamperedBytes = try Data(contentsOf: database)
            try assertCorruptReopen(
                root: root,
                vault: identity,
                database: database,
                unchangedBytes: tamperedBytes
            )
        }
    }

    func testExistingForeignKeyViolationFailsClosedWithoutRepair() throws {
        let root = try temporaryRoot("foreign-key-violation")
        defer { remove(root) }
        let identity = try vault()
        let journal = PlanningMutationJournal(applicationSupportDirectory: root, vault: identity)
        try journal.openValidated()
        journal.close()

        let database = databaseURL(root: root, vault: identity)
        try executeSQLite(
            database,
            sql: "PRAGMA foreign_keys = OFF; INSERT INTO publication_attempts(attempt_id, mutation_id, phase, witness_name, staged_identity, created_at, updated_at) VALUES ('00000000-0000-0000-0000-000000000098', '00000000-0000-0000-0000-000000000099', 'staged', NULL, NULL, 0, 0)"
        )
        let tamperedBytes = try Data(contentsOf: database)
        try assertCorruptReopen(
            root: root,
            vault: identity,
            database: database,
            unchangedBytes: tamperedBytes
        )
    }

    func testDeletedZeroAndMultipleVaultRowsFailClosedWithoutRepair() throws {
        let mutations = [
            "DELETE FROM vault",
            "INSERT INTO vault(schema_version, vault_id, lifeos_subfolder, device_id, created_at) VALUES (1, '00000000-0000-0000-0000-000000000099', 'LifeOS', '00000000-0000-0000-0000-000000000098', 0)"
        ]
        for (index, mutation) in mutations.enumerated() {
            let root = try temporaryRoot("vault-row-\(index)")
            defer { remove(root) }
            let identity = try vault()
            let journal = PlanningMutationJournal(applicationSupportDirectory: root, vault: identity)
            try journal.openValidated()
            journal.close()

            let database = databaseURL(root: root, vault: identity)
            try executeSQLite(database, sql: mutation)
            let tamperedBytes = try Data(contentsOf: database)
            try assertCorruptReopen(
                root: root,
                vault: identity,
                database: database,
                unchangedBytes: tamperedBytes
            )
        }
    }

    func testCoordinatedRuntimeLifecycleCallsRemainSafe() throws {
        let root = try temporaryRoot("lifecycle")
        defer { remove(root) }
        let identity = try vault()
        let journal = PlanningMutationJournal(applicationSupportDirectory: root, vault: identity)
        try journal.openValidated()
        let request = try createRequest(vaultID: identity.vaultID, path: "Notes/concurrent.md")

        let errors = PlanningMacErrorBox()
        DispatchQueue.concurrentPerform(iterations: 6) { _ in
            do {
                _ = try journal.stageMutation(request)
                _ = try journal.receipt(for: request.mutationID)
                _ = try journal.status()
            } catch {
                errors.append(error)
            }
        }
        XCTAssertTrue(errors.snapshot.isEmpty, errors.snapshot.map { String(describing: $0) }.joined(separator: ", "))

        let group = DispatchGroup()
        let lifecycleErrors = PlanningMacErrorBox()
        group.enter()
        DispatchQueue.global(qos: .utility).async {
            journal.close()
            group.leave()
        }
        for _ in 0..<3 {
            group.enter()
            DispatchQueue.global(qos: .utility).async {
                do {
                    _ = try journal.status()
                } catch let error as PlanningStorageError where error == .closed {
                } catch {
                    lifecycleErrors.append(error)
                }
                group.leave()
            }
        }
        XCTAssertEqual(group.wait(timeout: .now() + 2), .success)
        XCTAssertTrue(lifecycleErrors.snapshot.isEmpty, lifecycleErrors.snapshot.map { String(describing: $0) }.joined(separator: ", "))
        XCTAssertThrowsError(try journal.status()) { error in
            XCTAssertEqual(error as? PlanningStorageError, .closed)
        }
    }

    // MARK: Packet B migration

    func testFreshSchemaV2IncludesPublicationTablesAndDetails() throws {
        let root = try temporaryRoot("v2-schema")
        defer { remove(root) }
        let identity = try vault()
        let journal = PlanningMutationJournal(applicationSupportDirectory: root, vault: identity)
        defer { journal.close() }
        try journal.openValidated()
        let request = try createRequest(vaultID: identity.vaultID)
        _ = try journal.stageMutation(request)
        let attemptID = try journal.beginPublication(for: request.mutationID)

        let database = databaseURL(root: root, vault: identity)
        XCTAssertEqual(try scalarInt(database, sql: "PRAGMA user_version"), 2)
        XCTAssertEqual(try scalarInt(database, sql: "SELECT COUNT(*) FROM publication_details"), 1)
        XCTAssertEqual(try scalarInt(database, sql: "SELECT COUNT(*) FROM conflict_resolutions"), 0)
        XCTAssertEqual(try scalarInt(database, sql: "SELECT COUNT(*) FROM legacy_conflict_inspections"), 0)
        XCTAssertEqual(try journal.publicationAttempt(for: request.mutationID)?.attemptID, attemptID)
        XCTAssertEqual(try journal.publicationAttempt(for: request.mutationID)?.phase, .prepared)
    }

    func testV1MigrationPreservesLegacyAttemptEvidenceAndCommitsV2() throws {
        let root = try temporaryRoot("v1-migration")
        defer { remove(root) }
        let identity = try vault()
        let journal = PlanningMutationJournal(applicationSupportDirectory: root, vault: identity)
        try journal.openValidated()
        let request = try createRequest(vaultID: identity.vaultID)
        _ = try journal.stageMutation(request)
        _ = try journal.beginPublication(for: request.mutationID)
        journal.close()

        let database = databaseURL(root: root, vault: identity)
        try executeSQLite(
            database,
            sql: """
            DROP TABLE conflict_resolutions;
            DROP TABLE legacy_conflict_inspections;
            DROP TABLE publication_details;
            PRAGMA user_version = 1;
            """
        )
        let reopened = PlanningMutationJournal(applicationSupportDirectory: root, vault: identity)
        defer { reopened.close() }
        try reopened.openValidated()
        XCTAssertEqual(try scalarInt(database, sql: "PRAGMA user_version"), 2)
        let attempt = try XCTUnwrap(try reopened.publicationAttempt(for: request.mutationID))
        XCTAssertTrue(attempt.legacyUnverified)
        XCTAssertNil(attempt.context)
        XCTAssertEqual(attempt.phase, .prepared)
    }

    func testV1MigrationPreservesResolvedConflictAsInspectionOnly() throws {
        let root = try temporaryRoot("v1-resolved-conflict")
        defer { remove(root) }
        let identity = try vault()
        let journal = PlanningMutationJournal(applicationSupportDirectory: root, vault: identity)
        try journal.openValidated()
        let request = try createRequest(
            vaultID: identity.vaultID,
            path: "Notes/v1-resolved.md",
            proposedBytes: Data("local".utf8)
        )
        _ = try journal.stageMutation(request)
        let conflict = try openConflict(journal, request: request)
        _ = try journal.recordConflict(conflict)
        _ = try journal.resolveConflict(conflict.conflictID, resolution: .keepObserved)
        journal.close()

        let database = databaseURL(root: root, vault: identity)
        try executeSQLite(
            database,
            sql: """
            DROP TABLE legacy_conflict_inspections;
            DROP TABLE conflict_resolutions;
            DROP TABLE publication_details;
            PRAGMA user_version = 1;
            """
        )

        let migrated = PlanningMutationJournal(applicationSupportDirectory: root, vault: identity)
        try migrated.openValidated()
        XCTAssertEqual(try scalarInt(database, sql: "PRAGMA user_version"), 2)
        XCTAssertEqual(
            try scalarInt(database, sql: "SELECT COUNT(*) FROM legacy_conflict_inspections"),
            1
        )
        XCTAssertEqual(
            try scalarInt(database, sql: "SELECT COUNT(*) FROM conflict_resolutions"),
            0
        )
        let inspection = try XCTUnwrap(
            try migrated.legacyConflictInspection(for: conflict.conflictID)
        )
        XCTAssertEqual(inspection.conflictID, conflict.conflictID)
        XCTAssertEqual(inspection.sourceSchemaVersion, 1)
        XCTAssertEqual(inspection.reason, "resolvedConflictWithoutDecision")
        XCTAssertThrowsError(try migrated.beginPublication(for: request.mutationID)) { error in
            XCTAssertEqual(error as? PlanningStorageError, .invalidState("resolved"))
        }
        XCTAssertThrowsError(
            try migrated.resolveConflict(conflict.conflictID, resolution: .keepObserved)
        ) { error in
            XCTAssertEqual(error as? PlanningStorageError, .corruptDatabase)
        }
        migrated.close()

        let reopened = PlanningMutationJournal(applicationSupportDirectory: root, vault: identity)
        defer { reopened.close() }
        try reopened.openValidated()
        XCTAssertEqual(
            try reopened.legacyConflictInspection(for: conflict.conflictID),
            inspection
        )
        XCTAssertThrowsError(
            try reopened.resolveConflict(conflict.conflictID, resolution: .keepObserved)
        ) { error in
            XCTAssertEqual(error as? PlanningStorageError, .corruptDatabase)
        }
    }

    func testV1MigrationRejectsMalformedLegacyEvidenceWithoutRepair() throws {
        let root = try temporaryRoot("v1-malformed")
        defer { remove(root) }
        let identity = try vault()
        let journal = PlanningMutationJournal(applicationSupportDirectory: root, vault: identity)
        try journal.openValidated()
        let request = try createRequest(vaultID: identity.vaultID)
        _ = try journal.stageMutation(request)
        _ = try journal.beginPublication(for: request.mutationID)
        journal.close()

        let database = databaseURL(root: root, vault: identity)
        try executeSQLite(
            database,
            sql: """
            DROP TABLE conflict_resolutions;
            DROP TABLE legacy_conflict_inspections;
            DROP TABLE publication_details;
            PRAGMA user_version = 1;
            UPDATE publication_attempts SET witness_name = 'bad' || char(0) || 'value';
            """
        )
        let before = try Data(contentsOf: database)
        let reopened = PlanningMutationJournal(applicationSupportDirectory: root, vault: identity)
        XCTAssertThrowsError(try reopened.openValidated()) { error in
            XCTAssertEqual(error as? PlanningStorageError, .corruptDatabase)
        }
        XCTAssertEqual(try Data(contentsOf: database), before)
        reopened.close()
    }

    func testV1SchemaFailureRemainsUnchangedAndDoesNotMigrate() throws {
        let root = try temporaryRoot("v1-schema-failure")
        defer { remove(root) }
        let identity = try vault()
        let journal = PlanningMutationJournal(applicationSupportDirectory: root, vault: identity)
        try journal.openValidated()
        journal.close()

        let database = databaseURL(root: root, vault: identity)
        try executeSQLite(
            database,
            sql: """
            DROP TABLE conflict_resolutions;
            DROP TABLE legacy_conflict_inspections;
            DROP TABLE publication_details;
            DROP INDEX mutations_fingerprint;
            PRAGMA user_version = 1;
            """
        )
        let before = try Data(contentsOf: database)
        let reopened = PlanningMutationJournal(applicationSupportDirectory: root, vault: identity)
        XCTAssertThrowsError(try reopened.openValidated()) { error in
            XCTAssertEqual(error as? PlanningStorageError, .corruptDatabase)
        }
        XCTAssertEqual(try scalarInt(database, sql: "PRAGMA user_version"), 1)
        XCTAssertEqual(try Data(contentsOf: database), before)
        reopened.close()
    }

    func testV1MigrationPreservesMultipleActiveLegacyAttemptsAsInspectionOnly() throws {
        let root = try temporaryRoot("v1-multiple-active")
        defer { remove(root) }
        let identity = try vault()
        let journal = PlanningMutationJournal(applicationSupportDirectory: root, vault: identity)
        try journal.openValidated()
        let request = try createRequest(vaultID: identity.vaultID)
        _ = try journal.stageMutation(request)
        let first = try journal.beginPublication(for: request.mutationID)
        journal.close()

        let second = UUID()
        let database = databaseURL(root: root, vault: identity)
        try executeSQLite(
            database,
            sql: """
            DROP TABLE conflict_resolutions;
            DROP TABLE legacy_conflict_inspections;
            DROP TABLE publication_details;
            PRAGMA user_version = 1;
            INSERT INTO publication_attempts(
                attempt_id, mutation_id, phase, witness_name, staged_identity, created_at, updated_at
            ) VALUES ('\(second.uuidString.lowercased())', '\(request.mutationID.uuidString.lowercased())',
                      'prepared', NULL, NULL, 9999999999, 9999999999);
            """
        )
        let reopened = PlanningMutationJournal(applicationSupportDirectory: root, vault: identity)
        defer { reopened.close() }
        try reopened.openValidated()
        XCTAssertEqual(try scalarInt(database, sql: "PRAGMA user_version"), 2)
        XCTAssertEqual(try scalarInt(database, sql: "SELECT COUNT(*) FROM publication_details"), 2)
        XCTAssertEqual(try reopened.publicationAttempt(for: request.mutationID)?.attemptID, second)
        XCTAssertTrue(try XCTUnwrap(reopened.publicationAttempt(for: request.mutationID)).legacyUnverified)
        XCTAssertThrowsError(try reopened.beginPublication(for: request.mutationID))
        XCTAssertNotEqual(first, second)
    }

    func testUnsupportedWalJournalRemainsByteForByteUnchanged() throws {
        let root = try temporaryRoot("unsupported-wal")
        defer { remove(root) }
        let identity = try vault()
        let journal = PlanningMutationJournal(applicationSupportDirectory: root, vault: identity)
        try journal.openValidated()
        journal.close()
        let database = databaseURL(root: root, vault: identity)
        try executeSQLite(
            database,
            sql: "PRAGMA journal_mode = WAL; PRAGMA user_version = 99;"
        )
        let before = sqliteFileBytes(root: root, vault: identity)
        let reopened = PlanningMutationJournal(applicationSupportDirectory: root, vault: identity)
        XCTAssertThrowsError(try reopened.openValidated()) { error in
            XCTAssertEqual(error as? PlanningStorageError, .unsupportedSchema(99))
        }
        reopened.close()
        XCTAssertEqual(sqliteFileBytes(root: root, vault: identity), before)
    }

    func testMigrationFailureRollsBackNewTablesAndPreservesLegacyEvidence() throws {
        let root = try temporaryRoot("v1-migration-rollback")
        defer { remove(root) }
        let identity = try vault()
        let journal = PlanningMutationJournal(applicationSupportDirectory: root, vault: identity)
        try journal.openValidated()
        let request = try createRequest(vaultID: identity.vaultID)
        _ = try journal.stageMutation(request)
        _ = try journal.beginPublication(for: request.mutationID)
        journal.close()

        let database = databaseURL(root: root, vault: identity)
        var inserts = [
            "DROP TABLE conflict_resolutions",
            "DROP TABLE legacy_conflict_inspections",
            "DROP TABLE publication_details",
            "PRAGMA user_version = 1"
        ]
        for index in 0..<64 {
            let attemptID = UUID().uuidString.lowercased()
            inserts.append(
                "INSERT INTO publication_attempts(attempt_id, mutation_id, phase, witness_name, staged_identity, created_at, updated_at) "
                    + "VALUES ('\(attemptID)', '\(request.mutationID.uuidString.lowercased())', 'prepared', NULL, NULL, \(index + 1), \(index + 1))"
            )
        }
        try executeSQLite(database, sql: inserts.joined(separator: ";\n") + ";")
        let before = try Data(contentsOf: database)
        let reopened = PlanningMutationJournal(applicationSupportDirectory: root, vault: identity)
        XCTAssertThrowsError(try reopened.openValidated()) { error in
            XCTAssertEqual(error as? PlanningStorageError, .backpressure("publicationAttempts"))
        }
        reopened.close()
        XCTAssertEqual(try scalarInt(database, sql: "PRAGMA user_version"), 1)
        XCTAssertEqual(try scalarInt(
            database,
            sql: "SELECT COUNT(*) FROM sqlite_master WHERE type = 'table' AND name = 'publication_details'"
        ), 0)
        XCTAssertEqual(try scalarInt(database, sql: "SELECT COUNT(*) FROM publication_attempts"), 65)
        XCTAssertEqual(try Data(contentsOf: database), before)
    }

    // MARK: Packet B publication

    func testPublicationLifecycleStoresContextAndExactPublishedOutcome() throws {
        let root = try temporaryRoot("publication-valid")
        defer { remove(root) }
        let identity = try vault()
        let journal = PlanningMutationJournal(applicationSupportDirectory: root, vault: identity)
        defer { journal.close() }
        try journal.openValidated()
        let request = try createRequest(vaultID: identity.vaultID, proposedBytes: Data("new".utf8))
        _ = try journal.stageMutation(request)
        let attemptID = try journal.beginPublication(for: request.mutationID)
        try journal.recordStagedIdentity(
            mutationID: request.mutationID,
            attemptID: attemptID,
            identity: try PlanningFileIdentity(device: 30, inode: 40, fileType: 1),
            witnessName: ".lifeos-stage-\(attemptID.uuidString.lowercased())"
        )
        let context = try publicationContext(for: request)
        try journal.markPublishing(mutationID: request.mutationID, attemptID: attemptID, context: context)
        XCTAssertEqual(try journal.publicationAttempt(for: request.mutationID)?.phase, .publishing)
        XCTAssertEqual(try journal.publicationAttempt(for: request.mutationID)?.context, context)
        let expected = PlanningContentVersion(data: Data("new".utf8))
        let receipt = try journal.recordPublicationOutcome(
            mutationID: request.mutationID,
            attemptID: attemptID,
            outcome: .published(expected)
        )
        XCTAssertEqual(receipt.state, .published)
        XCTAssertEqual(receipt.resultVersion, expected)
        XCTAssertEqual(try journal.recordPublicationOutcome(
            mutationID: request.mutationID,
            attemptID: attemptID,
            outcome: .published(expected)
        ), receipt)
    }

    func testCompetingPublicationAttemptsAndStaleCallsAreRejected() throws {
        let root = try temporaryRoot("publication-competing")
        defer { remove(root) }
        let identity = try vault()
        let journal = PlanningMutationJournal(applicationSupportDirectory: root, vault: identity)
        defer { journal.close() }
        try journal.openValidated()
        let request = try createRequest(vaultID: identity.vaultID)
        _ = try journal.stageMutation(request)
        let first = try journal.beginPublication(for: request.mutationID)
        let second = UUID()
        XCTAssertThrowsError(try journal.beginPublication(for: request.mutationID, attemptID: second)) { error in
            XCTAssertEqual(error as? PlanningStorageError, .invalidState("publication.activeAttempt.\(first.uuidString.lowercased())"))
        }
        XCTAssertThrowsError(
            try journal.recordStagedIdentity(
                mutationID: request.mutationID,
                attemptID: second,
                identity: try PlanningFileIdentity(device: 1, inode: 2, fileType: 1),
                witnessName: ".lifeos-stage-\(second.uuidString.lowercased())"
            )
        ) { error in
            XCTAssertEqual(error as? PlanningStorageError, .notFound)
        }
    }

    func testIllegalPhaseAndWrongResultVersionAreRejected() throws {
        let root = try temporaryRoot("publication-illegal")
        defer { remove(root) }
        let identity = try vault()
        let journal = PlanningMutationJournal(applicationSupportDirectory: root, vault: identity)
        defer { journal.close() }
        try journal.openValidated()
        let request = try createRequest(vaultID: identity.vaultID, proposedBytes: Data("expected".utf8))
        _ = try journal.stageMutation(request)
        let attemptID = try journal.beginPublication(for: request.mutationID)
        let wrong = PlanningContentVersion(data: Data("wrong".utf8))
        XCTAssertThrowsError(
            try journal.recordPublicationOutcome(
                mutationID: request.mutationID,
                attemptID: attemptID,
                outcome: .published(wrong)
            )
        )
        XCTAssertEqual(try journal.publicationAttempt(for: request.mutationID)?.phase, .prepared)
        try journal.recordStagedIdentity(
            mutationID: request.mutationID,
            attemptID: attemptID,
            identity: try PlanningFileIdentity(device: 3, inode: 4, fileType: 1),
            witnessName: ".lifeos-stage-\(attemptID.uuidString.lowercased())"
        )
        XCTAssertThrowsError(
            try journal.recordPublicationOutcome(
                mutationID: request.mutationID,
                attemptID: attemptID,
                outcome: .published(wrong)
            )
        )
        try journal.markPublishing(
            mutationID: request.mutationID,
            attemptID: attemptID,
            context: try publicationContext(for: request)
        )
        XCTAssertThrowsError(
            try journal.recordPublicationOutcome(
                mutationID: request.mutationID,
                attemptID: attemptID,
                outcome: .published(wrong)
            )
        )
        XCTAssertEqual(try journal.publicationAttempt(for: request.mutationID)?.phase, .publishing)
    }

    func testDeletePublicationUsesPresentObservationAndAbsentResult() throws {
        let root = try temporaryRoot("publication-delete")
        defer { remove(root) }
        let identity = try vault()
        let journal = PlanningMutationJournal(applicationSupportDirectory: root, vault: identity)
        defer { journal.close() }
        try journal.openValidated()
        let request = try deleteRequest(vaultID: identity.vaultID)
        _ = try journal.stageMutation(request)
        let attemptID = try journal.beginPublication(for: request.mutationID)
        let context = try publicationContext(for: request)
        try journal.markPublishing(mutationID: request.mutationID, attemptID: attemptID, context: context)
        let receipt = try journal.recordPublicationOutcome(
            mutationID: request.mutationID,
            attemptID: attemptID,
            outcome: .published(.absent)
        )
        XCTAssertEqual(receipt.state, .published)
        XCTAssertEqual(receipt.resultVersion, .absent)
    }

    func testPublishedReceiptResultMustMatchRequestedOutcome() throws {
        let root = try temporaryRoot("publication-receipt-result")
        defer { remove(root) }
        let identity = try vault()
        let journal = PlanningMutationJournal(applicationSupportDirectory: root, vault: identity)
        try journal.openValidated()
        let request = try createRequest(
            vaultID: identity.vaultID,
            path: "Notes/receipt-result.md",
            proposedBytes: Data("published-bytes".utf8)
        )
        _ = try journal.stageMutation(request)
        let receipt = try publish(journal, request: request)
        XCTAssertEqual(receipt.state, .published)
        XCTAssertEqual(receipt.resultVersion, PlanningContentVersion(data: request.proposedBytes ?? Data()))
        journal.close()

        let database = databaseURL(root: root, vault: identity)
        try executeSQLite(
            database,
            sql: "UPDATE receipts SET result_version = 'absent' WHERE mutation_id = '\(request.mutationID.uuidString.lowercased())'"
        )
        try assertCorruptReopen(
            root: root,
            vault: identity,
            database: database,
            unchangedBytes: try Data(contentsOf: database)
        )
    }

    func testPublishingFailureCannotBeRetriedWithoutFilesystemReconciliation() throws {
        let root = try temporaryRoot("publication-ambiguous")
        defer { remove(root) }
        let identity = try vault()
        let journal = PlanningMutationJournal(applicationSupportDirectory: root, vault: identity)
        defer { journal.close() }
        try journal.openValidated()
        let request = try createRequest(vaultID: identity.vaultID)
        _ = try journal.stageMutation(request)
        let attemptID = try journal.beginPublication(for: request.mutationID)
        try journal.recordStagedIdentity(
            mutationID: request.mutationID,
            attemptID: attemptID,
            identity: try PlanningFileIdentity(device: 5, inode: 6, fileType: 1),
            witnessName: ".lifeos-stage-\(attemptID.uuidString.lowercased())"
        )
        try journal.markPublishing(
            mutationID: request.mutationID,
            attemptID: attemptID,
            context: try publicationContext(for: request)
        )
        XCTAssertThrowsError(
            try journal.recordPublicationOutcome(
                mutationID: request.mutationID,
                attemptID: attemptID,
                outcome: .failed(code: "io", retryable: true)
            )
        ) { error in
            XCTAssertEqual(error as? PlanningStorageError, .invalidState("publication.ambiguous"))
        }
        XCTAssertEqual(try journal.publicationAttempt(for: request.mutationID)?.phase, .publishing)
    }

    func testRetryableHistoricalAttemptMayAdvanceAndReopen() throws {
        let root = try temporaryRoot("retry-reopen")
        defer { remove(root) }
        let identity = try vault()
        var now = Date(timeIntervalSince1970: 1_000)
        let journal = PlanningMutationJournal(
            applicationSupportDirectory: root,
            vault: identity,
            clock: { now }
        )
        try journal.openValidated()
        let request = try createRequest(
            vaultID: identity.vaultID,
            proposedBytes: Data("retry-success".utf8)
        )
        _ = try journal.stageMutation(request)
        let first = try journal.beginPublication(for: request.mutationID)
        _ = try journal.recordPublicationOutcome(
            mutationID: request.mutationID,
            attemptID: first,
            outcome: .failed(code: "temporary", retryable: true)
        )
        now = now.addingTimeInterval(5)
        let second = try journal.beginPublication(for: request.mutationID)
        try journal.recordStagedIdentity(
            mutationID: request.mutationID,
            attemptID: second,
            identity: try PlanningFileIdentity(device: 60, inode: 70, fileType: 1),
            witnessName: ".lifeos-stage-\(second.uuidString.lowercased())"
        )
        try journal.markPublishing(
            mutationID: request.mutationID,
            attemptID: second,
            context: try publicationContext(for: request)
        )
        let expected = PlanningContentVersion(data: request.proposedBytes ?? Data())
        _ = try journal.recordPublicationOutcome(
            mutationID: request.mutationID,
            attemptID: second,
            outcome: .published(expected)
        )
        journal.close()

        let reopened = PlanningMutationJournal(applicationSupportDirectory: root, vault: identity)
        defer { reopened.close() }
        try reopened.openValidated()
        XCTAssertEqual(try reopened.receipt(for: request.mutationID)?.state, .published)
        XCTAssertEqual(try reopened.publicationAttempt(for: request.mutationID)?.attemptID, second)
        XCTAssertEqual(try scalarInt(
            databaseURL(root: root, vault: identity),
            sql: "SELECT COUNT(*) FROM publication_attempts WHERE phase = 'failed'"
        ), 1)

        // A retryable failure may be followed by an absent-observation
        // conflict before another publication attempt is started. Applying
        // the unchanged local request reopens the same durable row; the
        // failed attempt remains latest and the continuation must survive
        // close/reopen and decision replay.
        let conflictRoot = try temporaryRoot("retry-conflict-reopen")
        defer { remove(conflictRoot) }
        let conflictVault = try vault()
        let conflictJournal = PlanningMutationJournal(
            applicationSupportDirectory: conflictRoot,
            vault: conflictVault,
            clock: { now }
        )
        try conflictJournal.openValidated()
        let conflictRequest = try createRequest(
            vaultID: conflictVault.vaultID,
            path: "Notes/retry-conflict.md",
            proposedBytes: Data("retry-conflict".utf8)
        )
        _ = try conflictJournal.stageMutation(conflictRequest)
        let failedAttempt = try conflictJournal.beginPublication(for: conflictRequest.mutationID)
        _ = try conflictJournal.recordPublicationOutcome(
            mutationID: conflictRequest.mutationID,
            attemptID: failedAttempt,
            outcome: .failed(code: "temporary", retryable: true)
        )
        let conflict = try openConflict(
            conflictJournal,
            request: conflictRequest,
            observedBytes: nil
        )
        _ = try conflictJournal.recordConflict(conflict)
        let continuation = try conflictJournal.resolveConflict(
            conflict.conflictID,
            resolution: .applyLocal(expectedObservedVersion: .absent)
        )
        XCTAssertEqual(continuation.newMutationReceipt?.mutationID, conflictRequest.mutationID)
        XCTAssertEqual(continuation.newMutationReceipt?.state, .staged)
        conflictJournal.close()

        let conflictReopened = PlanningMutationJournal(
            applicationSupportDirectory: conflictRoot,
            vault: conflictVault,
            clock: { now }
        )
        defer { conflictReopened.close() }
        try conflictReopened.openValidated()
        let reopenedReceipt = try XCTUnwrap(
            try conflictReopened.receipt(for: conflictRequest.mutationID)
        )
        XCTAssertEqual(reopenedReceipt.state, .staged)
        XCTAssertEqual(
            try conflictReopened.publicationAttempt(for: conflictRequest.mutationID)?.phase,
            .failed
        )
        XCTAssertEqual(
            try scalarInt(
                databaseURL(root: conflictRoot, vault: conflictVault),
                sql: "SELECT COUNT(*) FROM publication_attempts WHERE phase = 'failed'"
            ),
            1
        )
        let replay = try conflictReopened.resolveConflict(
            conflict.conflictID,
            resolution: .applyLocal(expectedObservedVersion: .absent)
        )
        XCTAssertEqual(replay.newMutationReceipt, reopenedReceipt)
        XCTAssertEqual(
            try scalarInt(
                databaseURL(root: conflictRoot, vault: conflictVault),
                sql: "SELECT COUNT(*) FROM mutations"
            ),
            1
        )
        XCTAssertEqual(
            try scalarInt(
                databaseURL(root: conflictRoot, vault: conflictVault),
                sql: "SELECT COUNT(*) FROM conflict_resolutions"
            ),
            1
        )
    }

    func testRetryBackoffUsesFakeClockAndSurvivesEightDayRestart() throws {
        let root = try temporaryRoot("retry-backoff")
        defer { remove(root) }
        let identity = try vault()
        var now = Date(timeIntervalSince1970: 10_000)
        var monotonicCalls = 0
        var forceRecoveryDeadline = false
        let deterministicMonotonicClock: () -> UInt64 = {
            monotonicCalls += 1
            if forceRecoveryDeadline && monotonicCalls >= 2 {
                return PlanningStorageLimits.recoveryBudgetNanoseconds
            }
            return 0
        }
        let journal = PlanningMutationJournal(
            applicationSupportDirectory: root,
            vault: identity,
            clock: { now },
            monotonicClock: deterministicMonotonicClock
        )
        try journal.openValidated()
        let request = try createRequest(vaultID: identity.vaultID)
        _ = try journal.stageMutation(request)
        let first = try journal.beginPublication(for: request.mutationID)
        _ = try journal.recordPublicationOutcome(
            mutationID: request.mutationID,
            attemptID: first,
            outcome: .failed(code: "temporary", retryable: true)
        )
        XCTAssertEqual(
            try journal.publicationAttempt(for: request.mutationID)?.retryAfter,
            Date(timeIntervalSince1970: 10_005)
        )
        now = Date(timeIntervalSince1970: 10_005)
        let second = try journal.beginPublication(for: request.mutationID)
        _ = try journal.recordPublicationOutcome(
            mutationID: request.mutationID,
            attemptID: second,
            outcome: .failed(code: "temporary", retryable: true)
        )
        XCTAssertEqual(
            try journal.publicationAttempt(for: request.mutationID)?.retryAfter,
            Date(timeIntervalSince1970: 10_015)
        )
        forceRecoveryDeadline = true
        monotonicCalls = 0
        let deadlinePage = try journal.loadPublicationRecoveryPage()
        XCTAssertTrue(deadlinePage.entries.isEmpty)
        XCTAssertFalse(deadlinePage.endOfPass)
        XCTAssertEqual(deadlinePage.nextCursor.lastExaminedSequence, 0)
        now = now.addingTimeInterval(8 * 24 * 60 * 60)
        journal.close()

        forceRecoveryDeadline = false
        monotonicCalls = 0
        let reopened = PlanningMutationJournal(
            applicationSupportDirectory: root,
            vault: identity,
            clock: { now },
            monotonicClock: deterministicMonotonicClock
        )
        defer { reopened.close() }
        try reopened.openValidated()
        XCTAssertEqual(
            try reopened.publicationAttempt(for: request.mutationID)?.retryAfter,
            Date(timeIntervalSince1970: 10_015)
        )
        let resumedPage = try reopened.loadPublicationRecoveryPage()
        XCTAssertTrue(resumedPage.endOfPass)
        XCTAssertTrue(resumedPage.entries.contains { $0.recovery.mutationID == request.mutationID })
        XCTAssertNoThrow(try reopened.beginPublication(for: request.mutationID))
    }

    func testTerminalPublicationReplayRejectsContradictoryOutcome() throws {
        let root = try temporaryRoot("publication-terminal")
        defer { remove(root) }
        let identity = try vault()
        let journal = PlanningMutationJournal(applicationSupportDirectory: root, vault: identity)
        defer { journal.close() }
        try journal.openValidated()
        let request = try createRequest(vaultID: identity.vaultID)
        _ = try journal.stageMutation(request)
        let receipt = try publish(journal, request: request)
        let attemptID = try XCTUnwrap(try journal.publicationAttempt(for: request.mutationID)?.attemptID)
        XCTAssertEqual(try journal.recordPublicationOutcome(
            mutationID: request.mutationID,
            attemptID: attemptID,
            outcome: .published(.bytes(sha256: receipt.resultVersion?.digest ?? "", byteCount: 0))
        ), receipt)
        XCTAssertThrowsError(
            try journal.recordPublicationOutcome(
                mutationID: request.mutationID,
                attemptID: attemptID,
                outcome: .failed(code: "contradiction", retryable: false)
            )
        ) { error in
            XCTAssertEqual(error as? PlanningStorageError, .invalidState("publication.terminalReplay"))
        }
    }

    // MARK: Packet B conflicts

    func testConflictEvidenceIsImmutableAndOpenReplayIsIdempotent() throws {
        let root = try temporaryRoot("conflict-evidence")
        defer { remove(root) }
        let identity = try vault()
        let journal = PlanningMutationJournal(applicationSupportDirectory: root, vault: identity)
        defer { journal.close() }
        try journal.openValidated()
        let request = try createRequest(vaultID: identity.vaultID, proposedBytes: Data("local".utf8))
        _ = try journal.stageMutation(request)
        _ = try journal.beginPublication(for: request.mutationID)
        let conflict = try openConflict(journal, request: request)
        let conflicted = try journal.recordConflict(conflict)
        XCTAssertEqual(conflicted.state, .conflicted)
        XCTAssertEqual(try journal.recordConflict(conflict), conflicted)
        let changed = try PlanningConflict(
            conflictID: conflict.conflictID,
            mutationID: conflict.mutationID,
            vaultID: conflict.vaultID,
            path: conflict.path,
            operation: conflict.operation,
            reason: "changed",
            baseVersion: conflict.baseVersion,
            localBytes: conflict.localBytes,
            observedVersion: conflict.observedVersion,
            observedBytes: conflict.observedBytes
        )
        XCTAssertThrowsError(try journal.recordConflict(changed))
        let second = try PlanningConflict(
            mutationID: request.mutationID,
            vaultID: request.vaultID,
            path: request.path,
            operation: request.operation,
            reason: "second",
            baseVersion: request.expectedVersion,
            localBytes: request.proposedBytes,
            observedVersion: conflict.observedVersion,
            observedBytes: conflict.observedBytes
        )
        XCTAssertThrowsError(try journal.recordConflict(second))
    }

    func testKeepObservedResolutionIsDurableAndDecisionReplayIsIdempotent() throws {
        let root = try temporaryRoot("conflict-observed")
        defer { remove(root) }
        let identity = try vault()
        let journal = PlanningMutationJournal(applicationSupportDirectory: root, vault: identity)
        try journal.openValidated()
        let request = try createRequest(vaultID: identity.vaultID, proposedBytes: Data("local".utf8))
        _ = try journal.stageMutation(request)
        let conflict = try openConflict(journal, request: request)
        _ = try journal.recordConflict(conflict)
        let first = try journal.resolveConflict(conflict.conflictID, resolution: .keepObserved)
        XCTAssertNil(first.newMutationReceipt)
        journal.close()

        let reopened = PlanningMutationJournal(applicationSupportDirectory: root, vault: identity)
        defer { reopened.close() }
        try reopened.openValidated()
        let recordedAgain = try reopened.recordConflict(conflict)
        XCTAssertEqual(recordedAgain, try XCTUnwrap(try reopened.receipt(for: request.mutationID)))
        let replay = try reopened.resolveConflict(conflict.conflictID, resolution: .keepObserved)
        XCTAssertEqual(replay, first)
        XCTAssertThrowsError(
            try reopened.resolveConflict(
                conflict.conflictID,
                resolution: .keepBoth
            )
        )
    }

    func testApplyLocalResolutionCreatesOneQueuedChild() throws {
        let root = try temporaryRoot("conflict-local")
        defer { remove(root) }
        let identity = try vault()
        let journal = PlanningMutationJournal(applicationSupportDirectory: root, vault: identity)
        defer { journal.close() }
        try journal.openValidated()
        let request = try createRequest(vaultID: identity.vaultID, proposedBytes: Data("local".utf8))
        _ = try journal.stageMutation(request)
        let conflict = try openConflict(journal, request: request)
        _ = try journal.recordConflict(conflict)
        let first = try journal.resolveConflict(
            conflict.conflictID,
            resolution: .applyLocal(expectedObservedVersion: conflict.observedVersion)
        )
        let child = try XCTUnwrap(first.newMutationReceipt)
        XCTAssertEqual(child.state, .staged)
        let replay = try journal.resolveConflict(
            conflict.conflictID,
            resolution: .applyLocal(expectedObservedVersion: conflict.observedVersion)
        )
        XCTAssertEqual(replay.newMutationReceipt?.mutationID, child.mutationID)
        XCTAssertEqual(try scalarInt(
            databaseURL(root: root, vault: identity),
            sql: "SELECT COUNT(*) FROM mutations"
        ), 2)

        let equalRoot = try temporaryRoot("conflict-local-equal-parent")
        defer { remove(equalRoot) }
        let equalVault = try vault()
        let equalJournal = PlanningMutationJournal(
            applicationSupportDirectory: equalRoot,
            vault: equalVault
        )
        try equalJournal.openValidated()
        let equalRequest = try createRequest(
            vaultID: equalVault.vaultID,
            path: "Notes/equal-parent.md",
            proposedBytes: Data("same local bytes".utf8)
        )
        _ = try equalJournal.stageMutation(equalRequest)
        let equalConflict = try openConflict(
            equalJournal,
            request: equalRequest,
            observedBytes: nil
        )
        _ = try equalJournal.recordConflict(equalConflict)

        let equalFirst = try equalJournal.resolveConflict(
            equalConflict.conflictID,
            resolution: .applyLocal(expectedObservedVersion: .absent)
        )
        let continuation = try XCTUnwrap(equalFirst.newMutationReceipt)
        XCTAssertEqual(continuation.mutationID, equalRequest.mutationID)
        XCTAssertEqual(continuation.state, .staged)
        XCTAssertEqual(try scalarInt(
            databaseURL(root: equalRoot, vault: equalVault),
            sql: "SELECT COUNT(*) FROM mutations"
        ), 1)
        XCTAssertEqual(try scalarInt(
            databaseURL(root: equalRoot, vault: equalVault),
            sql: "SELECT COUNT(*) FROM conflict_resolutions"
        ), 1)
        XCTAssertEqual(
            try equalJournal.loadPublicationRecoveryPage().entries.map { $0.recovery.mutationID },
            [equalRequest.mutationID]
        )
        equalJournal.close()

        let reopenedEqual = PlanningMutationJournal(
            applicationSupportDirectory: equalRoot,
            vault: equalVault
        )
        defer { reopenedEqual.close() }
        try reopenedEqual.openValidated()
        let reopenedContinuation = try XCTUnwrap(
            try reopenedEqual.receipt(for: equalRequest.mutationID)
        )
        XCTAssertEqual(reopenedContinuation.state, .staged)
        let replayAfterRestart = try reopenedEqual.resolveConflict(
            equalConflict.conflictID,
            resolution: .applyLocal(expectedObservedVersion: .absent)
        )
        XCTAssertEqual(replayAfterRestart.newMutationReceipt, reopenedContinuation)

        let secondEqualConflict = try openConflict(
            reopenedEqual,
            request: equalRequest,
            observedBytes: nil
        )
        _ = try reopenedEqual.recordConflict(secondEqualConflict)
        let secondContinuation = try reopenedEqual.resolveConflict(
            secondEqualConflict.conflictID,
            resolution: .applyLocal(expectedObservedVersion: .absent)
        )
        XCTAssertEqual(secondContinuation.newMutationReceipt?.mutationID, equalRequest.mutationID)
        XCTAssertEqual(secondContinuation.newMutationReceipt?.state, .staged)
        let secondReplay = try reopenedEqual.resolveConflict(
            secondEqualConflict.conflictID,
            resolution: .applyLocal(expectedObservedVersion: .absent)
        )
        XCTAssertEqual(secondReplay.newMutationReceipt, secondContinuation.newMutationReceipt)
        XCTAssertEqual(try scalarInt(
            databaseURL(root: equalRoot, vault: equalVault),
            sql: "SELECT COUNT(*) FROM mutations"
        ), 1)
        XCTAssertEqual(try scalarInt(
            databaseURL(root: equalRoot, vault: equalVault),
            sql: "SELECT COUNT(*) FROM conflict_resolutions"
        ), 2)
        reopenedEqual.close()
        equalJournal.close()

        let reopenedEqualAgain = PlanningMutationJournal(
            applicationSupportDirectory: equalRoot,
            vault: equalVault
        )
        defer { reopenedEqualAgain.close() }
        try reopenedEqualAgain.openValidated()
        XCTAssertEqual(
            try reopenedEqualAgain.resolveConflict(
                equalConflict.conflictID,
                resolution: .applyLocal(expectedObservedVersion: .absent)
            ).newMutationReceipt?.mutationID,
            equalRequest.mutationID
        )
        XCTAssertEqual(
            try reopenedEqualAgain.resolveConflict(
                secondEqualConflict.conflictID,
                resolution: .applyLocal(expectedObservedVersion: .absent)
            ).newMutationReceipt?.mutationID,
            equalRequest.mutationID
        )
        let continuationRequest = try XCTUnwrap(
            try reopenedEqualAgain.loadPublicationRecoveryPage().entries.first?.recovery.request
        )
        XCTAssertEqual(
            try publish(reopenedEqualAgain, request: continuationRequest).state,
            .published
        )
        let replayAfterPublish = try reopenedEqualAgain.resolveConflict(
            equalConflict.conflictID,
            resolution: .applyLocal(expectedObservedVersion: .absent)
        )
        XCTAssertEqual(replayAfterPublish.newMutationReceipt?.state, .published)
        XCTAssertEqual(
            try reopenedEqualAgain.resolveConflict(
                secondEqualConflict.conflictID,
                resolution: .applyLocal(expectedObservedVersion: .absent)
            ).newMutationReceipt?.state,
            .published
        )

        let mixedRoot = try temporaryRoot("conflict-local-then-terminal")
        defer { remove(mixedRoot) }
        let mixedVault = try vault()
        let mixedJournal = PlanningMutationJournal(
            applicationSupportDirectory: mixedRoot,
            vault: mixedVault
        )
        try mixedJournal.openValidated()
        let mixedRequest = try createRequest(
            vaultID: mixedVault.vaultID,
            path: "Notes/local-then-terminal.md",
            proposedBytes: Data("same local bytes".utf8)
        )
        _ = try mixedJournal.stageMutation(mixedRequest)
        let firstMixedConflict = try openConflict(
            mixedJournal,
            request: mixedRequest,
            observedBytes: nil
        )
        _ = try mixedJournal.recordConflict(firstMixedConflict)
        _ = try mixedJournal.resolveConflict(
            firstMixedConflict.conflictID,
            resolution: .applyLocal(expectedObservedVersion: .absent)
        )
        let terminalConflict = try openConflict(
            mixedJournal,
            request: mixedRequest,
            observedBytes: nil
        )
        _ = try mixedJournal.recordConflict(terminalConflict)
        let terminal = try mixedJournal.resolveConflict(
            terminalConflict.conflictID,
            resolution: .keepObserved
        )
        XCTAssertNil(terminal.newMutationReceipt)
        XCTAssertEqual(
            try mixedJournal.receipt(for: mixedRequest.mutationID)?.state,
            .resolved
        )
        mixedJournal.close()

        let mixedReopened = PlanningMutationJournal(
            applicationSupportDirectory: mixedRoot,
            vault: mixedVault
        )
        defer { mixedReopened.close() }
        try mixedReopened.openValidated()
        XCTAssertEqual(
            try mixedReopened.receipt(for: mixedRequest.mutationID)?.state,
            .resolved
        )
        XCTAssertNil(
            try mixedReopened.resolveConflict(
                terminalConflict.conflictID,
                resolution: .keepObserved
            ).newMutationReceipt
        )
        XCTAssertEqual(
            try mixedReopened.resolveConflict(
                firstMixedConflict.conflictID,
                resolution: .applyLocal(expectedObservedVersion: .absent)
            ).newMutationReceipt?.mutationID,
            mixedRequest.mutationID
        )
    }

    func testResolutionChildMayAdvanceAndReopen() throws {
        let root = try temporaryRoot("resolution-child-reopen")
        defer { remove(root) }
        let identity = try vault()
        let journal = PlanningMutationJournal(applicationSupportDirectory: root, vault: identity)
        try journal.openValidated()
        let request = try createRequest(
            vaultID: identity.vaultID,
            proposedBytes: Data("local".utf8)
        )
        _ = try journal.stageMutation(request)
        let conflict = try openConflict(journal, request: request)
        _ = try journal.recordConflict(conflict)
        let resolved = try journal.resolveConflict(
            conflict.conflictID,
            resolution: .applyLocal(expectedObservedVersion: conflict.observedVersion)
        )
        let childID = try XCTUnwrap(resolved.newMutationReceipt?.mutationID)
        // The resolution child is a replace when the observation is present.
        let actualChild = try XCTUnwrap(try journal.loadPublicationRecoveryPage().entries.first {
            $0.recovery.mutationID == childID
        }?.recovery.request)
        XCTAssertEqual(actualChild.operation, .replace)
        XCTAssertEqual(actualChild.proposedBytes, request.proposedBytes)
        let childReceipt = try publish(journal, request: actualChild)
        XCTAssertEqual(childReceipt.state, .published)
        journal.close()

        let reopened = PlanningMutationJournal(applicationSupportDirectory: root, vault: identity)
        defer { reopened.close() }
        try reopened.openValidated()
        XCTAssertEqual(try reopened.receipt(for: childID)?.state, .published)
        XCTAssertEqual(try reopened.status().openConflictCount, 0)
    }

    func testApplyMergedResolutionCreatesBoundedQueuedChild() throws {
        let root = try temporaryRoot("conflict-merged")
        defer { remove(root) }
        let identity = try vault()
        let journal = PlanningMutationJournal(applicationSupportDirectory: root, vault: identity)
        defer { journal.close() }
        try journal.openValidated()
        let request = try createRequest(vaultID: identity.vaultID, proposedBytes: Data("local".utf8))
        _ = try journal.stageMutation(request)
        let conflict = try openConflict(journal, request: request)
        _ = try journal.recordConflict(conflict)
        let merged = Data("merged".utf8)
        let receipt = try journal.resolveConflict(
            conflict.conflictID,
            resolution: .applyMerged(
                bytes: merged,
                expectedObservedVersion: conflict.observedVersion
            )
        )
        XCTAssertEqual(receipt.newMutationReceipt?.state, .staged)
        XCTAssertEqual(try journal.resolveConflict(
            conflict.conflictID,
            resolution: .applyMerged(
                bytes: merged,
                expectedObservedVersion: conflict.observedVersion
            )
        ).newMutationReceipt?.mutationID, receipt.newMutationReceipt?.mutationID)
    }

    func testKeepBothQueuesAReservedBoundedSibling() throws {
        let root = try temporaryRoot("conflict-both")
        defer { remove(root) }
        let identity = try vault()
        let journal = PlanningMutationJournal(applicationSupportDirectory: root, vault: identity)
        defer { journal.close() }
        try journal.openValidated()
        let request = try createRequest(
            vaultID: identity.vaultID,
            path: "Notes/keep-both.md",
            proposedBytes: Data("local".utf8)
        )
        _ = try journal.stageMutation(request)
        let conflict = try openConflict(journal, request: request)
        _ = try journal.recordConflict(conflict)
        let resolved = try journal.resolveConflict(conflict.conflictID, resolution: .keepBoth)
        XCTAssertEqual(resolved.newMutationReceipt?.state, .staged)
        let sibling = try PlanningMutationRequest(
            vaultID: identity.vaultID,
            path: try PlanningStoredPath(
                "Notes/keep-both (LifeOS conflict \(conflict.conflictID.uuidString.lowercased())).md"
            ),
            operation: .create,
            expectedVersion: .absent,
            proposedBytes: Data("other".utf8)
        )
        XCTAssertThrowsError(try journal.stageMutation(sibling)) { error in
            XCTAssertEqual(error as? PlanningStorageError, .invalid("mutation.pathCollision"))
        }
        XCTAssertEqual(try journal.resolveConflict(conflict.conflictID, resolution: .keepBoth).newMutationReceipt?.mutationID,
                       resolved.newMutationReceipt?.mutationID)
    }

    // MARK: Packet B recovery

    func testRecoveryPagesFreezeSequenceAndAdvanceByKeyset() throws {
        let root = try temporaryRoot("recovery-pages")
        defer { remove(root) }
        let identity = try vault()
        let journal = PlanningMutationJournal(applicationSupportDirectory: root, vault: identity)
        defer { journal.close() }
        try journal.openValidated()
        for index in 0..<33 {
            let request = try createRequest(
                vaultID: identity.vaultID,
                path: "Notes/recovery-\(index).md"
            )
            _ = try journal.stageMutation(request)
        }
        let first = try journal.loadPublicationRecoveryPage()
        XCTAssertEqual(first.entries.count, 32)
        XCTAssertFalse(first.endOfPass)
        let after = first.nextCursor
        let late = try createRequest(vaultID: identity.vaultID, path: "Notes/recovery-late.md")
        _ = try journal.stageMutation(late)
        let second = try journal.loadPublicationRecoveryPage(after: after)
        XCTAssertEqual(second.entries.count, 1)
        XCTAssertTrue(second.endOfPass)
        XCTAssertFalse(second.entries.contains { $0.recovery.mutationID == late.mutationID })
    }

    func testRecoveryPageHonorsSixteenMiBMaterializationBoundary() throws {
        let root = try temporaryRoot("recovery-budget")
        defer { remove(root) }
        let identity = try vault()
        let journal = PlanningMutationJournal(applicationSupportDirectory: root, vault: identity)
        defer { journal.close() }
        try journal.openValidated()
        let prefix = Data("{\"nodes\":[],\"edges\":[]}".utf8)
        let canvasBytes = prefix + Data(repeating: 0x20, count: PlanningStorageLimits.canvasBytes - prefix.count)
        var largeExcluded: PlanningMutationRequest?
        for index in 0..<9 {
            let request = try canvasRequest(
                vaultID: identity.vaultID,
                path: "Notes/budget-\(index).canvas",
                proposedBytes: canvasBytes
            )
            _ = try journal.stageMutation(request)
            if index == 8 {
                largeExcluded = request
            }
        }
        let smallAfterExcluded = try createRequest(
            vaultID: identity.vaultID,
            path: "Notes/budget-small.md"
        )
        _ = try journal.stageMutation(smallAfterExcluded)
        let first = try journal.loadPublicationRecoveryPage()
        XCTAssertEqual(first.entries.count, 8)
        XCTAssertFalse(first.endOfPass)
        let second = try journal.loadPublicationRecoveryPage(after: first.nextCursor)
        XCTAssertEqual(second.entries.count, 2)
        XCTAssertEqual(second.entries[0].recovery.mutationID, largeExcluded?.mutationID)
        XCTAssertEqual(second.entries[1].recovery.mutationID, smallAfterExcluded.mutationID)
        XCTAssertTrue(second.endOfPass)
    }

    func testRecoveryReportsConflictsAndDoesNotResolveThem() throws {
        let root = try temporaryRoot("recovery-conflict")
        defer { remove(root) }
        let identity = try vault()
        let journal = PlanningMutationJournal(applicationSupportDirectory: root, vault: identity)
        defer { journal.close() }
        try journal.openValidated()
        let request = try createRequest(vaultID: identity.vaultID, proposedBytes: Data("local".utf8))
        _ = try journal.stageMutation(request)
        _ = try journal.beginPublication(for: request.mutationID)
        let conflict = try openConflict(journal, request: request)
        _ = try journal.recordConflict(conflict)
        let page = try journal.loadPublicationRecoveryPage()
        XCTAssertEqual(page.entries.count, 1)
        XCTAssertEqual(page.entries[0].recovery.state, .conflicted)
        XCTAssertEqual(page.entries[0].attempt?.phase, .conflicted)
        XCTAssertEqual(try journal.status().openConflictCount, 1)
    }

    func testRecoveryEmptyPassReturnsExplicitEndCursor() throws {
        let root = try temporaryRoot("recovery-empty")
        defer { remove(root) }
        let identity = try vault()
        let journal = PlanningMutationJournal(applicationSupportDirectory: root, vault: identity)
        defer { journal.close() }
        try journal.openValidated()
        let page = try journal.loadPublicationRecoveryPage()
        XCTAssertTrue(page.entries.isEmpty)
        XCTAssertTrue(page.endOfPass)
        XCTAssertEqual(page.nextCursor.maximumSequence, 0)
        XCTAssertEqual(page.nextCursor.lastExaminedSequence, 0)
    }

    // MARK: Packet B capacity and security

    func testCompactionRetainsPayloadsReferencedByResolvedConflicts() throws {
        let root = try temporaryRoot("compaction-conflict")
        defer { remove(root) }
        let identity = try vault()
        let journal = PlanningMutationJournal(applicationSupportDirectory: root, vault: identity)
        defer { journal.close() }
        try journal.openValidated()
        let request = try createRequest(vaultID: identity.vaultID, proposedBytes: Data("local".utf8))
        _ = try journal.stageMutation(request)
        let conflict = try openConflict(journal, request: request)
        _ = try journal.recordConflict(conflict)
        _ = try journal.resolveConflict(conflict.conflictID, resolution: .keepObserved)
        XCTAssertEqual(try journal.compactUnreferencedPayloads(), 0)
        XCTAssertGreaterThan(try journal.status().retainedPayloadBytes, 0)
    }

    func testSQLiteFullRollsBackMutationWithoutDroppingExistingEvidence() throws {
        let root = try temporaryRoot("sqlite-full")
        defer { remove(root) }
        let identity = try vault()
        let journal = PlanningMutationJournal(applicationSupportDirectory: root, vault: identity)
        defer { journal.close() }
        try journal.openValidated()
        let existing = try createRequest(
            vaultID: identity.vaultID,
            path: "Notes/existing.md",
            proposedBytes: Data("existing".utf8)
        )
        _ = try journal.stageMutation(existing)
        let database = databaseURL(root: root, vault: identity)
        let pageCount = try scalarInt(database, sql: "PRAGMA page_count")
        try journal.debugSetMaximumPageCountForTests(pageCount)
        let failing = try createRequest(
            vaultID: identity.vaultID,
            path: "Notes/full.md",
            proposedBytes: Data(repeating: 0x20, count: 64 * 1024)
        )
        XCTAssertThrowsError(try journal.stageMutation(failing)) { error in
            XCTAssertEqual(error as? PlanningStorageError, .databaseFull)
        }
        XCTAssertEqual(try scalarInt(database, sql: "SELECT COUNT(*) FROM mutations"), 1)
        XCTAssertEqual(try journal.receipt(for: existing.mutationID)?.state, .staged)
        XCTAssertNil(try journal.receipt(for: failing.mutationID))
    }

    func testPublicationDomainAllowsAdditiveUnknownFieldsButRejectsInvalidIdentity() throws {
        let context = try PlanningPublicationContext(
            selectionGeneration: UUID(),
            rootIdentity: try PlanningFileIdentity(device: 10, inode: 20, fileType: 2),
            observedVersion: .absent,
            observedIdentity: nil
        )
        var data = try JSONEncoder().encode(context)
        data.removeLast()
        data.append(contentsOf: Data(#", "future": true}"#.utf8))
        XCTAssertEqual(try JSONDecoder().decode(PlanningPublicationContext.self, from: data), context)
        XCTAssertThrowsError(
            try PlanningPublicationContext(
                selectionGeneration: UUID(),
                rootIdentity: try PlanningFileIdentity(device: 10, inode: 20, fileType: 1),
                observedVersion: .absent,
                observedIdentity: nil
            )
        )
        XCTAssertThrowsError(
            try PlanningPublicationAttemptSnapshot(
                attemptID: UUID(),
                mutationID: UUID(),
                ordinal: 1,
                phase: .stageReady
            )
        )
        XCTAssertThrowsError(
            try PlanningDurableResolutionRecord(
                conflictID: UUID(),
                decisionFingerprint: String(repeating: "0", count: 64),
                resolution: .keepObserved,
                childMutationID: nil
            )
        )
    }

    func testAttemptCapRejectsWithoutDroppingDurableEvidence() throws {
        let root = try temporaryRoot("attempt-cap")
        defer { remove(root) }
        let identity = try vault()
        let journal = PlanningMutationJournal(applicationSupportDirectory: root, vault: identity)
        defer { journal.close() }
        try journal.openValidated()
        let request = try createRequest(vaultID: identity.vaultID)
        _ = try journal.stageMutation(request)
        for _ in 0..<64 {
            let attempt = try journal.beginPublication(for: request.mutationID)
            _ = try journal.recordPublicationOutcome(
                mutationID: request.mutationID,
                attemptID: attempt,
                outcome: .failed(code: "retry", retryable: true)
            )
        }
        XCTAssertThrowsError(try journal.beginPublication(for: request.mutationID)) { error in
            XCTAssertEqual(error as? PlanningStorageError, .backpressure("publicationAttempts"))
        }
        XCTAssertEqual(try scalarInt(
            databaseURL(root: root, vault: identity),
            sql: "SELECT COUNT(*) FROM publication_details"
        ), 64)
    }

    func testConcurrentBeginPublicationIsSerializedWithoutDuplicateAttempt() throws {
        let root = try temporaryRoot("attempt-concurrent")
        defer { remove(root) }
        let identity = try vault()
        let journal = PlanningMutationJournal(applicationSupportDirectory: root, vault: identity)
        defer { journal.close() }
        try journal.openValidated()
        let request = try createRequest(vaultID: identity.vaultID)
        _ = try journal.stageMutation(request)
        let errors = PlanningMacErrorBox()
        DispatchQueue.concurrentPerform(iterations: 2) { _ in
            do {
                _ = try journal.beginPublication(for: request.mutationID)
            } catch {
                errors.append(error)
            }
        }
        XCTAssertEqual(errors.snapshot.count, 1)
        XCTAssertEqual(try scalarInt(
            databaseURL(root: root, vault: identity),
            sql: "SELECT COUNT(*) FROM publication_details"
        ), 1)
    }

    func testTamperedDurableResolutionFailsClosedWithoutRepair() throws {
        let root = try temporaryRoot("resolution-tamper")
        defer { remove(root) }
        let identity = try vault()
        let journal = PlanningMutationJournal(applicationSupportDirectory: root, vault: identity)
        try journal.openValidated()
        let request = try createRequest(vaultID: identity.vaultID, proposedBytes: Data("local".utf8))
        _ = try journal.stageMutation(request)
        let conflict = try openConflict(journal, request: request)
        _ = try journal.recordConflict(conflict)
        _ = try journal.resolveConflict(conflict.conflictID, resolution: .keepObserved)
        journal.close()

        let database = databaseURL(root: root, vault: identity)
        try executeSQLite(
            database,
            sql: "UPDATE conflict_resolutions SET decision_fingerprint = '0000000000000000000000000000000000000000000000000000000000000000'"
        )
        let before = try Data(contentsOf: database)
        let reopened = PlanningMutationJournal(applicationSupportDirectory: root, vault: identity)
        XCTAssertThrowsError(try reopened.openValidated()) { error in
            XCTAssertEqual(error as? PlanningStorageError, .corruptDatabase)
        }
        XCTAssertEqual(try Data(contentsOf: database), before)
        reopened.close()
    }

    func testConflictEvidenceDeletionFailsClosedWithoutRepair() throws {
        let conflictedRoot = try temporaryRoot("conflict-evidence-deleted")
        defer { remove(conflictedRoot) }
        let conflictedVault = try vault()
        let conflictedJournal = PlanningMutationJournal(
            applicationSupportDirectory: conflictedRoot,
            vault: conflictedVault
        )
        try conflictedJournal.openValidated()
        let conflictedRequest = try createRequest(
            vaultID: conflictedVault.vaultID,
            path: "Notes/conflicted-evidence.md"
        )
        _ = try conflictedJournal.stageMutation(conflictedRequest)
        let conflicted = try openConflict(conflictedJournal, request: conflictedRequest)
        _ = try conflictedJournal.recordConflict(conflicted)
        conflictedJournal.close()
        let conflictedDatabase = databaseURL(root: conflictedRoot, vault: conflictedVault)
        try executeSQLite(
            conflictedDatabase,
            sql: "DELETE FROM conflicts WHERE conflict_id = '\(conflicted.conflictID.uuidString.lowercased())'"
        )
        try assertCorruptReopen(
            root: conflictedRoot,
            vault: conflictedVault,
            database: conflictedDatabase,
            unchangedBytes: try Data(contentsOf: conflictedDatabase)
        )

        let resolvedRoot = try temporaryRoot("resolved-evidence-deleted")
        defer { remove(resolvedRoot) }
        let resolvedVault = try vault()
        let resolvedJournal = PlanningMutationJournal(
            applicationSupportDirectory: resolvedRoot,
            vault: resolvedVault
        )
        try resolvedJournal.openValidated()
        let resolvedRequest = try createRequest(
            vaultID: resolvedVault.vaultID,
            path: "Notes/resolved-evidence.md",
            proposedBytes: Data("local".utf8)
        )
        _ = try resolvedJournal.stageMutation(resolvedRequest)
        let resolved = try openConflict(resolvedJournal, request: resolvedRequest)
        _ = try resolvedJournal.recordConflict(resolved)
        _ = try resolvedJournal.resolveConflict(resolved.conflictID, resolution: .keepObserved)
        resolvedJournal.close()
        let resolvedDatabase = databaseURL(root: resolvedRoot, vault: resolvedVault)
        try executeSQLite(
            resolvedDatabase,
            sql: """
            DELETE FROM conflict_resolutions WHERE conflict_id = '\(resolved.conflictID.uuidString.lowercased())';
            DELETE FROM conflicts WHERE conflict_id = '\(resolved.conflictID.uuidString.lowercased())';
            """
        )
        try assertCorruptReopen(
            root: resolvedRoot,
            vault: resolvedVault,
            database: resolvedDatabase,
            unchangedBytes: try Data(contentsOf: resolvedDatabase)
        )
    }

    func testPublicationAndResolutionRelationshipsFailClosedWithoutRepair() throws {
        let detailRoot = try temporaryRoot("relationship-detail")
        defer { remove(detailRoot) }
        let detailVault = try vault()
        let detailJournal = PlanningMutationJournal(applicationSupportDirectory: detailRoot, vault: detailVault)
        try detailJournal.openValidated()
        let detailRequest = try createRequest(vaultID: detailVault.vaultID)
        _ = try detailJournal.stageMutation(detailRequest)
        let detailAttempt = try detailJournal.beginPublication(for: detailRequest.mutationID)
        let otherDetailRequest = try createRequest(
            vaultID: detailVault.vaultID,
            path: "Notes/relationship-other.md"
        )
        _ = try detailJournal.stageMutation(otherDetailRequest)
        detailJournal.close()
        let detailDatabase = databaseURL(root: detailRoot, vault: detailVault)
        try executeSQLite(
            detailDatabase,
            sql: "UPDATE publication_details SET mutation_id = '\(otherDetailRequest.mutationID.uuidString.lowercased())' WHERE attempt_id = '\(detailAttempt.uuidString.lowercased())'"
        )
        try assertCorruptReopen(
            root: detailRoot,
            vault: detailVault,
            database: detailDatabase,
            unchangedBytes: try Data(contentsOf: detailDatabase)
        )

        let deletionRoot = try temporaryRoot("relationship-deletion")
        defer { remove(deletionRoot) }
        let deletionVault = try vault()
        let deletionJournal = PlanningMutationJournal(
            applicationSupportDirectory: deletionRoot,
            vault: deletionVault
        )
        try deletionJournal.openValidated()
        let deletionRequest = try createRequest(
            vaultID: deletionVault.vaultID,
            path: "Notes/relationship-deleted.md"
        )
        _ = try deletionJournal.stageMutation(deletionRequest)
        let deletionAttempt = try deletionJournal.beginPublication(for: deletionRequest.mutationID)
        deletionJournal.close()
        let deletionDatabase = databaseURL(root: deletionRoot, vault: deletionVault)
        try executeSQLite(
            deletionDatabase,
            sql: "DELETE FROM publication_details WHERE attempt_id = '\(deletionAttempt.uuidString.lowercased())'; DELETE FROM publication_attempts WHERE attempt_id = '\(deletionAttempt.uuidString.lowercased())'"
        )
        try assertCorruptReopen(
            root: deletionRoot,
            vault: deletionVault,
            database: deletionDatabase,
            unchangedBytes: try Data(contentsOf: deletionDatabase)
        )

        let contextRoot = try temporaryRoot("relationship-context")
        defer { remove(contextRoot) }
        let contextVault = try vault()
        let contextJournal = PlanningMutationJournal(applicationSupportDirectory: contextRoot, vault: contextVault)
        try contextJournal.openValidated()
        let contextRequest = try createRequest(
            vaultID: contextVault.vaultID,
            proposedBytes: Data("context".utf8)
        )
        _ = try contextJournal.stageMutation(contextRequest)
        let contextAttempt = try contextJournal.beginPublication(for: contextRequest.mutationID)
        try contextJournal.recordStagedIdentity(
            mutationID: contextRequest.mutationID,
            attemptID: contextAttempt,
            identity: try PlanningFileIdentity(device: 1, inode: 2, fileType: 1),
            witnessName: ".lifeos-stage-\(contextAttempt.uuidString.lowercased())"
        )
        try contextJournal.markPublishing(
            mutationID: contextRequest.mutationID,
            attemptID: contextAttempt,
            context: try publicationContext(for: contextRequest)
        )
        contextJournal.close()
        let contextDatabase = databaseURL(root: contextRoot, vault: contextVault)
        try executeSQLite(
            contextDatabase,
            sql: "UPDATE publication_details SET context_json = NULL"
        )
        try assertCorruptReopen(
            root: contextRoot,
            vault: contextVault,
            database: contextDatabase,
            unchangedBytes: try Data(contentsOf: contextDatabase)
        )

        let identityRoot = try temporaryRoot("relationship-identity")
        defer { remove(identityRoot) }
        let identityVault = try vault()
        let identityJournal = PlanningMutationJournal(applicationSupportDirectory: identityRoot, vault: identityVault)
        try identityJournal.openValidated()
        let identityRequest = try createRequest(
            vaultID: identityVault.vaultID,
            proposedBytes: Data("identity".utf8)
        )
        _ = try identityJournal.stageMutation(identityRequest)
        let identityAttempt = try identityJournal.beginPublication(for: identityRequest.mutationID)
        try identityJournal.recordStagedIdentity(
            mutationID: identityRequest.mutationID,
            attemptID: identityAttempt,
            identity: try PlanningFileIdentity(device: 3, inode: 4, fileType: 1),
            witnessName: ".lifeos-stage-\(identityAttempt.uuidString.lowercased())"
        )
        try identityJournal.markPublishing(
            mutationID: identityRequest.mutationID,
            attemptID: identityAttempt,
            context: try publicationContext(for: identityRequest)
        )
        identityJournal.close()
        let identityDatabase = databaseURL(root: identityRoot, vault: identityVault)
        try executeSQLite(
            identityDatabase,
            sql: "UPDATE publication_attempts SET staged_identity = NULL"
        )
        try assertCorruptReopen(
            root: identityRoot,
            vault: identityVault,
            database: identityDatabase,
            unchangedBytes: try Data(contentsOf: identityDatabase)
        )

        let childRoot = try temporaryRoot("relationship-child")
        defer { remove(childRoot) }
        let childVault = try vault()
        let childJournal = PlanningMutationJournal(applicationSupportDirectory: childRoot, vault: childVault)
        try childJournal.openValidated()
        let childRequest = try createRequest(
            vaultID: childVault.vaultID,
            proposedBytes: Data("local".utf8)
        )
        _ = try childJournal.stageMutation(childRequest)
        let childConflict = try openConflict(childJournal, request: childRequest)
        _ = try childJournal.recordConflict(childConflict)
        let childResolution = try childJournal.resolveConflict(childConflict.conflictID, resolution: .applyLocal(
            expectedObservedVersion: childConflict.observedVersion
        ))
        let actualChildID = try XCTUnwrap(childResolution.newMutationReceipt?.mutationID)
        childJournal.close()
        let childDatabase = databaseURL(root: childRoot, vault: childVault)
        try executeSQLite(
            childDatabase,
            sql: """
            UPDATE conflict_resolutions
            SET child_mutation_id = '\(childRequest.mutationID.uuidString.lowercased())',
                decision_json = CAST(
                    replace(
                        replace(
                            CAST(decision_json AS TEXT),
                            '\(actualChildID.uuidString.lowercased())',
                            '\(childRequest.mutationID.uuidString.lowercased())'
                        ),
                        '\(actualChildID.uuidString.uppercased())',
                        '\(childRequest.mutationID.uuidString.lowercased())'
                    ) AS BLOB
                )
            WHERE conflict_id = '\(childConflict.conflictID.uuidString.lowercased())'
            """
        )
        try assertCorruptReopen(
            root: childRoot,
            vault: childVault,
            database: childDatabase,
            unchangedBytes: try Data(contentsOf: childDatabase)
        )

        let resolutionDeletionRoot = try temporaryRoot("relationship-resolution-deletion")
        defer { remove(resolutionDeletionRoot) }
        let resolutionDeletionVault = try vault()
        let resolutionDeletionJournal = PlanningMutationJournal(
            applicationSupportDirectory: resolutionDeletionRoot,
            vault: resolutionDeletionVault
        )
        try resolutionDeletionJournal.openValidated()
        let resolutionDeletionRequest = try createRequest(
            vaultID: resolutionDeletionVault.vaultID,
            path: "Notes/relationship-resolution-deleted.md"
        )
        _ = try resolutionDeletionJournal.stageMutation(resolutionDeletionRequest)
        let resolutionDeletionConflict = try openConflict(
            resolutionDeletionJournal,
            request: resolutionDeletionRequest
        )
        _ = try resolutionDeletionJournal.recordConflict(resolutionDeletionConflict)
        _ = try resolutionDeletionJournal.resolveConflict(
            resolutionDeletionConflict.conflictID,
            resolution: .keepObserved
        )
        resolutionDeletionJournal.close()
        let resolutionDeletionDatabase = databaseURL(
            root: resolutionDeletionRoot,
            vault: resolutionDeletionVault
        )
        try executeSQLite(
            resolutionDeletionDatabase,
            sql: "DELETE FROM conflict_resolutions WHERE conflict_id = '\(resolutionDeletionConflict.conflictID.uuidString.lowercased())'"
        )
        try assertCorruptReopen(
            root: resolutionDeletionRoot,
            vault: resolutionDeletionVault,
            database: resolutionDeletionDatabase,
            unchangedBytes: try Data(contentsOf: resolutionDeletionDatabase)
        )
    }

    func testOversizedPersistedPublicationFieldsRejectBeforeMaterialization() throws {
        let contextRoot = try temporaryRoot("oversized-context")
        defer { remove(contextRoot) }
        let contextVault = try vault()
        let contextJournal = PlanningMutationJournal(
            applicationSupportDirectory: contextRoot,
            vault: contextVault
        )
        try contextJournal.openValidated()
        let contextRequest = try createRequest(vaultID: contextVault.vaultID)
        _ = try contextJournal.stageMutation(contextRequest)
        _ = try contextJournal.beginPublication(for: contextRequest.mutationID)
        contextJournal.close()
        let contextDatabase = databaseURL(root: contextRoot, vault: contextVault)
        try executeSQLite(
            contextDatabase,
            sql: "UPDATE publication_details SET context_json = zeroblob(4097)"
        )
        try assertCorruptReopen(
            root: contextRoot,
            vault: contextVault,
            database: contextDatabase,
            unchangedBytes: try Data(contentsOf: contextDatabase)
        )

        let outcomeRoot = try temporaryRoot("oversized-outcome")
        defer { remove(outcomeRoot) }
        let outcomeVault = try vault()
        let outcomeJournal = PlanningMutationJournal(
            applicationSupportDirectory: outcomeRoot,
            vault: outcomeVault
        )
        try outcomeJournal.openValidated()
        let outcomeRequest = try createRequest(vaultID: outcomeVault.vaultID)
        _ = try outcomeJournal.stageMutation(outcomeRequest)
        let outcomeAttempt = try outcomeJournal.beginPublication(for: outcomeRequest.mutationID)
        _ = try outcomeJournal.recordPublicationOutcome(
            mutationID: outcomeRequest.mutationID,
            attemptID: outcomeAttempt,
            outcome: .failed(code: "temporary", retryable: true)
        )
        outcomeJournal.close()
        let outcomeDatabase = databaseURL(root: outcomeRoot, vault: outcomeVault)
        try executeSQLite(
            outcomeDatabase,
            sql: "UPDATE publication_details SET outcome_json = zeroblob(2049)"
        )
        try assertCorruptReopen(
            root: outcomeRoot,
            vault: outcomeVault,
            database: outcomeDatabase,
            unchangedBytes: try Data(contentsOf: outcomeDatabase)
        )

        let resolutionRoot = try temporaryRoot("oversized-resolution")
        defer { remove(resolutionRoot) }
        let resolutionVault = try vault()
        let resolutionJournal = PlanningMutationJournal(
            applicationSupportDirectory: resolutionRoot,
            vault: resolutionVault
        )
        try resolutionJournal.openValidated()
        let resolutionRequest = try createRequest(
            vaultID: resolutionVault.vaultID,
            proposedBytes: Data("local".utf8)
        )
        _ = try resolutionJournal.stageMutation(resolutionRequest)
        let resolutionConflict = try openConflict(resolutionJournal, request: resolutionRequest)
        _ = try resolutionJournal.recordConflict(resolutionConflict)
        _ = try resolutionJournal.resolveConflict(
            resolutionConflict.conflictID,
            resolution: .keepObserved
        )
        resolutionJournal.close()
        let resolutionDatabase = databaseURL(root: resolutionRoot, vault: resolutionVault)
        try executeSQLite(
            resolutionDatabase,
            sql: "UPDATE conflict_resolutions SET decision_json = zeroblob(3000000)"
        )
        try assertCorruptReopen(
            root: resolutionRoot,
            vault: resolutionVault,
            database: resolutionDatabase,
            unchangedBytes: try Data(contentsOf: resolutionDatabase)
        )
    }

    func testNearLimitMergedCanvasResolutionReopens() throws {
        let root = try temporaryRoot("merged-near-limit")
        defer { remove(root) }
        let identity = try vault()
        let journal = PlanningMutationJournal(applicationSupportDirectory: root, vault: identity)
        try journal.openValidated()
        // U+01FF is valid Canvas text and its UTF-8 bytes make one quarter of
        // the base64 output be `/`. This reproduces Foundation's old slash
        // escaping inflation while keeping the source document valid UTF-8
        // JSON. Four bounded text fields fill the exact Canvas byte ceiling.
        let repeatedText = String(repeating: "ǿ", count: 262_000)
        var nearLimitJSON = "{\"nodes\":["
        for index in 0..<4 {
            if index > 0 { nearLimitJSON.append(",") }
            nearLimitJSON += "{\"id\":\"near-\(index)\",\"type\":\"text\",\"x\":\(index * 100),\"y\":0,\"width\":100,\"height\":100,\"text\":\"\(repeatedText)\"}"
        }
        nearLimitJSON += "],\"edges\":[]}"
        var nearLimitCanvas = Data(nearLimitJSON.utf8)
        XCTAssertLessThanOrEqual(nearLimitCanvas.count, PlanningStorageLimits.canvasBytes)
        nearLimitCanvas.append(Data(
            repeating: 0x20,
            count: PlanningStorageLimits.canvasBytes - nearLimitCanvas.count
        ))
        XCTAssertEqual(nearLimitCanvas.count, PlanningStorageLimits.canvasBytes)
        XCTAssertNoThrow(try PlanningCanvasCodec.decode(nearLimitCanvas))
        let request = try canvasRequest(
            vaultID: identity.vaultID,
            path: "Boards/near-limit.canvas",
            proposedBytes: nearLimitCanvas
        )
        _ = try journal.stageMutation(request)
        let observedVersion = PlanningContentVersion(data: nearLimitCanvas)
        let conflict = try PlanningConflict(
            conflictID: UUID(),
            mutationID: request.mutationID,
            vaultID: identity.vaultID,
            path: request.path,
            operation: request.operation,
            reason: "near-limit",
            baseVersion: request.expectedVersion,
            localBytes: request.proposedBytes,
            observedVersion: observedVersion,
            observedBytes: nearLimitCanvas
        )
        _ = try journal.recordConflict(conflict)
        let resolution = try journal.resolveConflict(
            conflict.conflictID,
            resolution: .applyMerged(
                bytes: nearLimitCanvas,
                expectedObservedVersion: observedVersion
            )
        )
        XCTAssertEqual(resolution.newMutationReceipt?.state, .staged)
        journal.close()

        let reopened = PlanningMutationJournal(applicationSupportDirectory: root, vault: identity)
        defer { reopened.close() }
        try reopened.openValidated()
        XCTAssertEqual(try reopened.receipt(for: request.mutationID)?.state, .resolved)
        XCTAssertEqual(resolution.newMutationReceipt?.mutationID,
                       try reopened.resolveConflict(
                           conflict.conflictID,
                           resolution: .applyMerged(
                               bytes: nearLimitCanvas,
                               expectedObservedVersion: observedVersion
                           )
                       ).newMutationReceipt?.mutationID)
    }

    func testOversizedMergedResolutionIsRejectedBeforeFingerprinting() throws {
        let root = try temporaryRoot("merged-oversized")
        defer { remove(root) }
        let identity = try vault()
        let journal = PlanningMutationJournal(
            applicationSupportDirectory: root,
            vault: identity
        )
        defer { journal.close() }
        try journal.openValidated()

        let request = try canvasRequest(
            vaultID: identity.vaultID,
            path: "Boards/oversized.canvas"
        )
        _ = try journal.stageMutation(request)
        let conflict = try openConflict(
            journal,
            request: request,
            observedBytes: nil
        )
        _ = try journal.recordConflict(conflict)

        let oversized = Data(repeating: 0x20, count: PlanningStorageLimits.canvasBytes + 1)
        XCTAssertThrowsError(
            try journal.resolveConflict(
                conflict.conflictID,
                resolution: .applyMerged(
                    bytes: oversized,
                    expectedObservedVersion: .absent
                )
            )
        ) { error in
            XCTAssertEqual(error as? PlanningStorageError, .backpressure("mutationPayload"))
        }
        XCTAssertEqual(try scalarInt(
            databaseURL(root: root, vault: identity),
            sql: "SELECT COUNT(*) FROM conflict_resolutions"
        ), 0)
        XCTAssertEqual(try journal.receipt(for: request.mutationID)?.state, .conflicted)

        // The rejected input leaves the open conflict untouched and a valid
        // decision can still be committed in the same journal.
        let resolved = try journal.resolveConflict(
            conflict.conflictID,
            resolution: .keepObserved
        )
        XCTAssertNil(resolved.newMutationReceipt)
        XCTAssertEqual(try journal.receipt(for: request.mutationID)?.state, .resolved)
    }

}
