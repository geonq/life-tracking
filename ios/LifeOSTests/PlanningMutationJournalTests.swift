import Foundation
import SQLite3
import XCTest
@testable import LifeOS

private final class PlanningTestErrorBox: @unchecked Sendable {
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

final class PlanningMutationJournalTests: XCTestCase {
    private func temporaryRoot(_ name: String = "journal") throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("lifeos-planning-\(name)-\(UUID().uuidString)", isDirectory: true)
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

    private func scalar(_ url: URL, pragma: String) throws -> String {
        var database: OpaquePointer?
        let openCode = url.path.withCString {
            sqlite3_open_v2($0, &database, SQLITE_OPEN_READONLY, nil)
        }
        guard openCode == SQLITE_OK, let database else {
            if let database { sqlite3_close_v2(database) }
            throw NSError(domain: "PlanningMutationJournalTests", code: Int(openCode))
        }
        defer { sqlite3_close_v2(database) }

        var statement: OpaquePointer?
        let sql = "PRAGMA \(pragma)"
        let prepareCode = sqlite3_prepare_v2(database, sql, -1, &statement, nil)
        guard prepareCode == SQLITE_OK, let statement else {
            throw NSError(domain: "PlanningMutationJournalTests", code: Int(prepareCode))
        }
        defer { sqlite3_finalize(statement) }
        guard sqlite3_step(statement) == SQLITE_ROW,
              let text = sqlite3_column_text(statement, 0) else {
            throw NSError(domain: "PlanningMutationJournalTests", code: 1)
        }
        return String(cString: text)
    }

    private func createSQLiteFile(_ url: URL, sql: String) throws {
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        var database: OpaquePointer?
        let openCode = url.path.withCString {
            sqlite3_open_v2($0, &database, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE, nil)
        }
        guard openCode == SQLITE_OK, let database else {
            if let database { sqlite3_close_v2(database) }
            throw NSError(domain: "PlanningMutationJournalTests", code: Int(openCode))
        }
        defer { sqlite3_close_v2(database) }
        let executeCode = sqlite3_exec(database, sql, nil, nil, nil)
        guard executeCode == SQLITE_OK else {
            throw NSError(domain: "PlanningMutationJournalTests", code: Int(executeCode))
        }
    }

    private func executeSQLite(_ url: URL, sql: String) throws {
        var database: OpaquePointer?
        let openCode = url.path.withCString {
            sqlite3_open_v2($0, &database, SQLITE_OPEN_READWRITE, nil)
        }
        guard openCode == SQLITE_OK, let database else {
            if let database { sqlite3_close_v2(database) }
            throw NSError(domain: "PlanningMutationJournalTests", code: Int(openCode))
        }
        defer { sqlite3_close_v2(database) }
        let executeCode = sqlite3_exec(database, sql, nil, nil, nil)
        guard executeCode == SQLITE_OK else {
            throw NSError(domain: "PlanningMutationJournalTests", code: Int(executeCode))
        }
    }

    func testFreshOpenReopenAndExactPragmas() throws {
        let root = try temporaryRoot()
        defer { remove(root) }
        let identity = try vault()

        let first = PlanningMutationJournal(applicationSupportDirectory: root, vault: identity)
        try first.openValidated()
        XCTAssertEqual(try first.status().accessState, .ready)

        let request = try PlanningMutationRequest(
            mutationID: UUID(),
            vaultID: identity.vaultID,
            path: try PlanningStoredPath("Notes/empty.md"),
            operation: .create,
            expectedVersion: .absent,
            proposedBytes: Data()
        )
        let staged = try first.stageMutation(request)
        XCTAssertEqual(staged.fingerprint, request.fingerprint)

        let database = databaseURL(root: root, vault: identity)
        let pragmas = try first.debugPragmaSnapshot()
        XCTAssertEqual(pragmas.journalMode, "delete")
        XCTAssertEqual(pragmas.synchronous, 3)
        XCTAssertEqual(pragmas.foreignKeys, 1)
        XCTAssertEqual(pragmas.busyTimeout, 1_000)
        XCTAssertEqual(try scalar(database, pragma: "user_version"), "1")
        first.close()

        let reopened = PlanningMutationJournal(applicationSupportDirectory: root, vault: identity)
        try reopened.openValidated()
        XCTAssertEqual(try reopened.status().accessState, .ready)
        XCTAssertEqual(try reopened.receipt(for: request.mutationID), staged)
        reopened.close()
    }

    func testEmptyTruncatedAndNonSchemaDatabasesFailClosed() throws {
        let emptyRoot = try temporaryRoot("empty")
        defer { remove(emptyRoot) }
        let emptyIdentity = try vault()
        let emptyURL = databaseURL(root: emptyRoot, vault: emptyIdentity)
        try FileManager.default.createDirectory(
            at: emptyURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try Data().write(to: emptyURL, options: .atomic)
        XCTAssertThrowsError(
            try PlanningMutationJournal(
                applicationSupportDirectory: emptyRoot,
                vault: emptyIdentity
            ).openValidated()
        )
        XCTAssertEqual(try Data(contentsOf: emptyURL), Data())

        let truncatedRoot = try temporaryRoot("truncated")
        defer { remove(truncatedRoot) }
        let truncatedIdentity = try vault()
        let truncatedURL = databaseURL(root: truncatedRoot, vault: truncatedIdentity)
        try FileManager.default.createDirectory(
            at: truncatedURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let truncated = Data("SQLite format 3\0".utf8)
        try truncated.write(to: truncatedURL, options: .atomic)
        XCTAssertThrowsError(
            try PlanningMutationJournal(
                applicationSupportDirectory: truncatedRoot,
                vault: truncatedIdentity
            ).openValidated()
        )
        XCTAssertEqual(try Data(contentsOf: truncatedURL), truncated)

        let schemaRoot = try temporaryRoot("schema")
        defer { remove(schemaRoot) }
        let schemaIdentity = try vault()
        let schemaURL = databaseURL(root: schemaRoot, vault: schemaIdentity)
        try createSQLiteFile(schemaURL, sql: "CREATE TABLE unrelated(value INTEGER);")
        XCTAssertThrowsError(
            try PlanningMutationJournal(
                applicationSupportDirectory: schemaRoot,
                vault: schemaIdentity
            ).openValidated()
        )
        XCTAssertEqual(try scalar(schemaURL, pragma: "user_version"), "0")
    }

    func testUnsupportedSchemaFailsClosedWithoutRepair() throws {
        let root = try temporaryRoot("unsupported")
        defer { remove(root) }
        let identity = try vault()
        let database = databaseURL(root: root, vault: identity)
        try createSQLiteFile(database, sql: "PRAGMA user_version = 77;")
        XCTAssertThrowsError(
            try PlanningMutationJournal(
                applicationSupportDirectory: root,
                vault: identity
            ).openValidated()
        ) { error in
            XCTAssertEqual(error as? PlanningStorageError, .unsupportedSchema(77))
        }
        XCTAssertEqual(try scalar(database, pragma: "user_version"), "77")
    }

    func testSameMutationIDReplaysAndChangedRequestIsRejected() throws {
        let root = try temporaryRoot("idempotency")
        defer { remove(root) }
        let identity = try vault()
        let journal = PlanningMutationJournal(applicationSupportDirectory: root, vault: identity)
        try journal.openValidated()

        let mutationID = UUID()
        let first = try PlanningMutationRequest(
            mutationID: mutationID,
            vaultID: identity.vaultID,
            path: try PlanningStoredPath("Notes/empty.md"),
            operation: .create,
            expectedVersion: .absent,
            proposedBytes: Data()
        )
        let firstReceipt = try journal.stageMutation(first)
        let replayReceipt = try journal.stageMutation(first)
        XCTAssertEqual(firstReceipt, replayReceipt)

        let changed = try PlanningMutationRequest(
            mutationID: mutationID,
            vaultID: identity.vaultID,
            path: try PlanningStoredPath("Notes/other.md"),
            operation: .create,
            expectedVersion: .absent,
            proposedBytes: Data()
        )
        XCTAssertThrowsError(try journal.stageMutation(changed)) { error in
            XCTAssertEqual(error as? PlanningStorageError, .mutationIDReused)
        }
        journal.close()
    }

    func testPendingMutationReservesCanonicalCollisionKey() throws {
        let root = try temporaryRoot("collision")
        defer { remove(root) }
        let identity = try vault()
        let journal = PlanningMutationJournal(applicationSupportDirectory: root, vault: identity)
        defer { journal.close() }
        try journal.openValidated()

        let first = try PlanningMutationRequest(
            mutationID: UUID(),
            vaultID: identity.vaultID,
            path: try PlanningStoredPath("Notes/Plan.md"),
            operation: .create,
            expectedVersion: .absent,
            proposedBytes: Data()
        )
        XCTAssertNoThrow(try journal.stageMutation(first))
        XCTAssertEqual(try journal.stageMutation(first), try journal.receipt(for: first.mutationID))

        let caseAlias = try PlanningMutationRequest(
            mutationID: UUID(),
            vaultID: identity.vaultID,
            path: try PlanningStoredPath("notes/plan.md"),
            operation: .create,
            expectedVersion: .absent,
            proposedBytes: Data()
        )
        XCTAssertThrowsError(try journal.stageMutation(caseAlias)) { error in
            XCTAssertEqual(error as? PlanningStorageError, .invalid("mutation.pathCollision"))
        }

        let composed = try PlanningMutationRequest(
            mutationID: UUID(),
            vaultID: identity.vaultID,
            path: try PlanningStoredPath("Notes/café.md"),
            operation: .create,
            expectedVersion: .absent,
            proposedBytes: Data()
        )
        XCTAssertNoThrow(try journal.stageMutation(composed))
        let decomposed = try PlanningMutationRequest(
            mutationID: UUID(),
            vaultID: identity.vaultID,
            path: try PlanningStoredPath("Notes/café.md"),
            operation: .create,
            expectedVersion: .absent,
            proposedBytes: Data()
        )
        XCTAssertThrowsError(try journal.stageMutation(decomposed)) { error in
            XCTAssertEqual(error as? PlanningStorageError, .invalid("mutation.pathCollision"))
        }
    }

    func testTamperedMutationRowsFailClosedWithoutRepair() throws {
        let tamperStatements = [
            "UPDATE mutations SET fingerprint = '0000000000000000000000000000000000000000000000000000000000000000'",
            "UPDATE mutations SET vault_id = '00000000-0000-0000-0000-000000000099'",
            "UPDATE mutations SET path = '../tampered.md'"
        ]
        for (index, statement) in tamperStatements.enumerated() {
            let root = try temporaryRoot("tamper-\(index)")
            defer { remove(root) }
            let identity = try vault()
            let journal = PlanningMutationJournal(applicationSupportDirectory: root, vault: identity)
            try journal.openValidated()
            let request = try PlanningMutationRequest(
                mutationID: UUID(),
                vaultID: identity.vaultID,
                path: try PlanningStoredPath("Notes/tamper.md"),
                operation: .create,
                expectedVersion: .absent,
                proposedBytes: Data()
            )
            _ = try journal.stageMutation(request)
            journal.close()

            let database = databaseURL(root: root, vault: identity)
            try executeSQLite(database, sql: statement)
            let tamperedBytes = try Data(contentsOf: database)
            let reopened = PlanningMutationJournal(applicationSupportDirectory: root, vault: identity)
            XCTAssertThrowsError(try reopened.openValidated()) { error in
                XCTAssertEqual(error as? PlanningStorageError, .corruptDatabase)
            }
            XCTAssertEqual(try Data(contentsOf: database), tamperedBytes)
            reopened.close()
        }
    }

    func testMalformedSchemaAndDeletedVaultFailClosedWithoutRepair() throws {
        let schemaRoot = try temporaryRoot("missing-index")
        defer { remove(schemaRoot) }
        let schemaIdentity = try vault()
        let schemaJournal = PlanningMutationJournal(applicationSupportDirectory: schemaRoot, vault: schemaIdentity)
        try schemaJournal.openValidated()
        schemaJournal.close()
        let schemaDatabase = databaseURL(root: schemaRoot, vault: schemaIdentity)
        try executeSQLite(schemaDatabase, sql: "DROP INDEX mutations_fingerprint")
        let malformedBytes = try Data(contentsOf: schemaDatabase)
        let malformedJournal = PlanningMutationJournal(applicationSupportDirectory: schemaRoot, vault: schemaIdentity)
        XCTAssertThrowsError(try malformedJournal.openValidated()) { error in
            XCTAssertEqual(error as? PlanningStorageError, .corruptDatabase)
        }
        XCTAssertEqual(try Data(contentsOf: schemaDatabase), malformedBytes)
        malformedJournal.close()

        let vaultRoot = try temporaryRoot("deleted-vault")
        defer { remove(vaultRoot) }
        let vaultIdentity = try vault()
        let vaultJournal = PlanningMutationJournal(applicationSupportDirectory: vaultRoot, vault: vaultIdentity)
        try vaultJournal.openValidated()
        vaultJournal.close()
        let vaultDatabase = databaseURL(root: vaultRoot, vault: vaultIdentity)
        try executeSQLite(vaultDatabase, sql: "DELETE FROM vault")
        let deletedVaultBytes = try Data(contentsOf: vaultDatabase)
        let deletedVaultJournal = PlanningMutationJournal(applicationSupportDirectory: vaultRoot, vault: vaultIdentity)
        XCTAssertThrowsError(try deletedVaultJournal.openValidated()) { error in
            XCTAssertEqual(error as? PlanningStorageError, .corruptDatabase)
        }
        XCTAssertEqual(try Data(contentsOf: vaultDatabase), deletedVaultBytes)
        deletedVaultJournal.close()
    }

    func testSerializedLifecycleOperationsRemainSafeWhenCoordinatedConcurrently() throws {
        let root = try temporaryRoot("lifecycle")
        defer { remove(root) }
        let identity = try vault()
        let journal = PlanningMutationJournal(applicationSupportDirectory: root, vault: identity)
        try journal.openValidated()
        let request = try PlanningMutationRequest(
            mutationID: UUID(),
            vaultID: identity.vaultID,
            path: try PlanningStoredPath("Notes/concurrent.md"),
            operation: .create,
            expectedVersion: .absent,
            proposedBytes: Data()
        )

        let errors = PlanningTestErrorBox()
        DispatchQueue.concurrentPerform(iterations: 8) { _ in
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
        let lifecycleErrors = PlanningTestErrorBox()
        group.enter()
        DispatchQueue.global(qos: .utility).async {
            journal.close()
            group.leave()
        }
        for _ in 0..<4 {
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

    func testCloseLifecycleAndSecondWriterContentionAreDeterministic() throws {
        let root = try temporaryRoot("lock")
        defer { remove(root) }
        let identity = try vault()

        let first = PlanningMutationJournal(applicationSupportDirectory: root, vault: identity)
        let second = PlanningMutationJournal(applicationSupportDirectory: root, vault: identity)
        try first.openValidated()
        XCTAssertThrowsError(try second.openValidated()) { error in
            XCTAssertEqual(error as? PlanningStorageError, .writerBusy)
        }

        first.close()
        XCTAssertThrowsError(try first.status()) { error in
            XCTAssertEqual(error as? PlanningStorageError, .closed)
        }

        try second.openValidated()
        XCTAssertEqual(try second.status().accessState, .ready)
        second.close()
        XCTAssertThrowsError(try second.openValidated()) { error in
            XCTAssertEqual(error as? PlanningStorageError, .closed)
        }
    }
}
