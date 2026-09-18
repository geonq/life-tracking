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
        XCTAssertEqual(try scalarInt(database, sql: "PRAGMA user_version"), 1)
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
        let attemptID = try journal.beginPublication(for: first.mutationID)
        let published = try journal.recordPublicationOutcome(
            mutationID: first.mutationID,
            attemptID: attemptID,
            outcome: .published(PlanningContentVersion(data: Data()))
        )
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
        let attemptID = try journal.beginPublication(for: request.mutationID)
        _ = try journal.recordPublicationOutcome(
            mutationID: request.mutationID,
            attemptID: attemptID,
            outcome: .published(PlanningContentVersion(data: Data()))
        )
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
        let terminalAttempt = try terminalJournal.beginPublication(for: terminalRequest.mutationID)
        _ = try terminalJournal.recordPublicationOutcome(
            mutationID: terminalRequest.mutationID,
            attemptID: terminalAttempt,
            outcome: .published(PlanningContentVersion(data: Data()))
        )
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
            XCTAssertEqual(error as? PlanningStorageError, .invalid("persistedText.nul"))
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
                witnessName: "Mac"
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
            XCTAssertEqual(error as? PlanningStorageError, .invalid("persistedText.nul"))
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
}
