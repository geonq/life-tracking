import Foundation
import SQLite3
#if canImport(Darwin)
import Darwin
#endif

private let planningSQLiteTransient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

private func planningSQLiteFailure(_ code: Int32, database: OpaquePointer?) -> PlanningStorageError {
    let primary = code & 0xFF
    if primary == SQLITE_FULL || primary == SQLITE_IOERR {
        return .databaseFull
    }
    if primary == SQLITE_BUSY || primary == SQLITE_LOCKED {
        return .writerBusy
    }
    let message = database.map { String(cString: sqlite3_errmsg($0)) } ?? "sqlite"
    let safeCode = "\(primary):\(message.prefix(120))"
    return .database(safeCode)
}

private struct PlanningSchemaColumn: Equatable {
    let type: String
    let notNull: Int
    let primaryKey: Int
}

private struct PlanningSchemaIndex: Equatable {
    let name: String
    let unique: Bool
    let partial: Bool
    let columns: [String]
    let collations: [String]
    let descending: [Bool]

    var usesDefaultComparisonSemantics: Bool {
        collations.allSatisfy { $0 == "BINARY" } && descending.allSatisfy { !$0 }
    }
}

private struct PlanningSchemaForeignKey: Equatable {
    let id: Int
    let sequence: Int
    let table: String
    let from: String
    let to: String
    let onUpdate: String
    let onDelete: String
    let match: String
}

private extension PlanningMutationState {
    var isPending: Bool {
        switch self {
        case .staged, .prepared, .stageReady, .publishing, .conflicted:
            return true
        case .published, .resolved, .cancelled, .failed:
            return false
        }
    }
}

internal struct PlanningJournalPragmaSnapshot: Equatable, Sendable {
    let journalMode: String
    let synchronous: Int
    let foreignKeys: Int
    let busyTimeout: Int
}

public final class PlanningMutationJournal: @unchecked Sendable {
    public let applicationSupportDirectory: URL
    public let vault: PlanningVaultIdentity
    public let deviceID: UUID

    private let directoryURL: URL
    private let databaseURL: URL
    private let lockURL: URL
    private var database: OpaquePointer?
    private var lockDescriptor: Int32 = -1
    private var isOpen = false
    private var isClosed = false
    private let operationLock = NSLock()

    public init(
        applicationSupportDirectory: URL,
        vault: PlanningVaultIdentity,
        deviceID: UUID = UUID()
    ) {
        self.applicationSupportDirectory = applicationSupportDirectory
        self.vault = vault
        self.deviceID = deviceID
        let planningDirectory = applicationSupportDirectory
            .appendingPathComponent("LifeOS", isDirectory: true)
            .appendingPathComponent("Planning", isDirectory: true)
            .appendingPathComponent(vault.vaultID.uuidString.lowercased(), isDirectory: true)
        self.directoryURL = planningDirectory
        self.databaseURL = planningDirectory.appendingPathComponent("journal.sqlite", isDirectory: false)
        self.lockURL = planningDirectory.appendingPathComponent("writer.lock", isDirectory: false)
    }

    deinit {
        close()
    }

    public func openValidated() throws {
        try withOperation {
            try openValidatedLocked()
        }
    }

    private func openValidatedLocked() throws {
        guard !isClosed else { throw PlanningStorageError.closed }
        if isOpen { return }

        do {
            try createStorageDirectory()
            try acquireWriterLock()
            let existed = FileManager.default.fileExists(atPath: databaseURL.path)
            if existed {
                try rejectSymlink(at: databaseURL)
            }

            var opened: OpaquePointer?
            let flags = SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX
            let openCode = databaseURL.path.withCString {
                sqlite3_open_v2($0, &opened, flags, nil)
            }
            guard openCode == SQLITE_OK, let opened else {
                let error = planningSQLiteFailure(openCode, database: opened)
                if let opened { sqlite3_close_v2(opened) }
                throw error
            }
            database = opened
            let userVersion = try pragmaInteger("user_version")
            if existed {
                guard userVersion == 1 else {
                    throw userVersion == 0
                        ? PlanningStorageError.corruptDatabase
                        : PlanningStorageError.unsupportedSchema(userVersion)
                }
                try configureAndVerifyPragmas()
                try verifySchema()
                try validateVaultRow()
                try validateDurableRecords()
            } else {
                guard userVersion == 0 else {
                    throw PlanningStorageError.corruptDatabase
                }
                try configureAndVerifyPragmas()
                try createSchemaAndVault()
            }
            guard try pragmaInteger("user_version") == 1 else {
                throw PlanningStorageError.corruptDatabase
            }
            isOpen = true
        } catch {
            if let database {
                sqlite3_close_v2(database)
                self.database = nil
            }
            releaseWriterLock()
            throw error
        }
    }

    public func close() {
        operationLock.lock()
        defer { operationLock.unlock() }
        closeLocked()
    }

    private func closeLocked() {
        guard !isClosed else { return }
        isClosed = true
        isOpen = false
        if let database {
            sqlite3_close_v2(database)
            self.database = nil
        }
        releaseWriterLock()
    }

    public func stageMutation(_ request: PlanningMutationRequest) throws -> PlanningMutationReceipt {
        try withOperation {
        try withOpen {
            guard request.vaultID == vault.vaultID else {
                throw PlanningStorageError.invalid("mutation.vaultID")
            }
            return try transaction {
                try stageMutationLocked(request)
            }
        }
        }
    }

    public func receipt(for mutationID: UUID) throws -> PlanningMutationReceipt? {
        try withOperation {
        try withOpen {
            try receiptLocked(for: mutationID)
        }
        }
    }

    @discardableResult
    public func beginPublication(
        for mutationID: UUID,
        attemptID: UUID = UUID()
    ) throws -> UUID {
        try withOperation {
        try withOpen {
            try transaction {
                guard let mutation = try mutationLocked(for: mutationID) else {
                    throw PlanningStorageError.notFound
                }
                switch mutation.state {
                case .staged, .prepared, .stageReady, .publishing:
                    break
                case .published, .resolved, .cancelled, .failed:
                    throw PlanningStorageError.invalidState(mutation.state.rawValue)
                case .conflicted:
                    throw PlanningStorageError.conflict
                }
                try execute(
                    """
                    INSERT INTO publication_attempts(
                        attempt_id, mutation_id, phase, witness_name, staged_identity,
                        created_at, updated_at
                    ) VALUES (?, ?, 'prepared', NULL, NULL, ?, ?)
                    """,
                    binds: [
                        .text(attemptID.uuidString.lowercased()),
                        .text(mutationID.uuidString.lowercased()),
                        .double(Date().timeIntervalSince1970),
                        .double(Date().timeIntervalSince1970)
                    ]
                )
                try updateMutationState(mutationID, state: .prepared, errorCode: nil)
                return attemptID
            }
        }
        }
    }

    public func recordStagedIdentity(
        mutationID: UUID,
        attemptID: UUID,
        identity: PlanningFileIdentity,
        witnessName: String
    ) throws {
        try withOperation {
        guard !witnessName.isEmpty, witnessName.utf8.count <= 512 else {
            throw PlanningStorageError.invalid("publication.witnessName")
        }
        try withOpen {
            try transaction {
                guard try attemptExists(attemptID, mutationID: mutationID) else {
                    throw PlanningStorageError.notFound
                }
                try execute(
                    """
                    UPDATE publication_attempts
                    SET phase = 'stageReady', witness_name = ?, staged_identity = ?, updated_at = ?
                    WHERE attempt_id = ? AND mutation_id = ?
                    """,
                    binds: [
                        .text(witnessName),
                        .text(identity.storageToken),
                        .double(Date().timeIntervalSince1970),
                        .text(attemptID.uuidString.lowercased()),
                        .text(mutationID.uuidString.lowercased())
                    ]
                )
                try updateMutationState(mutationID, state: .stageReady, errorCode: nil)
            }
        }
        }
    }

    @discardableResult
    public func recordPublicationOutcome(
        mutationID: UUID,
        attemptID: UUID,
        outcome: PlanningPublicationOutcome
    ) throws -> PlanningMutationReceipt {
        try withOperation {
        try withOpen {
            try transaction {
                guard try attemptExists(attemptID, mutationID: mutationID) else {
                    throw PlanningStorageError.notFound
                }
                guard let mutation = try mutationLocked(for: mutationID) else {
                    throw PlanningStorageError.notFound
                }
                let state: PlanningMutationState
                let phase: String
                let resultVersion: PlanningContentVersion?
                let errorCode: String?
                switch outcome {
                case .published(let version):
                    try planningValidateContentVersion(
                        version,
                        maximumByteCount: mutation.request.path.isCanvas
                            ? PlanningStorageLimits.canvasBytes
                            : PlanningStorageLimits.markdownBytes,
                        field: "publication.resultVersion"
                    )
                    state = .published
                    phase = "published"
                    resultVersion = version
                    errorCode = nil
                case .conflicted:
                    state = .conflicted
                    phase = "conflicted"
                    resultVersion = nil
                    errorCode = "conflict"
                case .failed(let code, let retryable):
                    guard !code.isEmpty, code.utf8.count <= 256 else {
                        throw PlanningStorageError.invalid("publication.errorCode")
                    }
                    state = retryable ? .prepared : .failed
                    phase = "failed"
                    resultVersion = nil
                    errorCode = code
                }
                try execute(
                    """
                    UPDATE publication_attempts
                    SET phase = ?, updated_at = ?
                    WHERE attempt_id = ? AND mutation_id = ?
                    """,
                    binds: [
                        .text(phase),
                        .double(Date().timeIntervalSince1970),
                        .text(attemptID.uuidString.lowercased()),
                        .text(mutationID.uuidString.lowercased())
                    ]
                )
                try updateMutationState(mutationID, state: state, errorCode: errorCode, resultVersion: resultVersion)
                guard let receipt = try receiptLocked(for: mutationID) else {
                    throw PlanningStorageError.corruptDatabase
                }
                return receipt
            }
        }
        }
    }

    @discardableResult
    public func recordConflict(_ conflict: PlanningConflict) throws -> PlanningMutationReceipt {
        try withOperation {
        try withOpen {
            guard conflict.vaultID == vault.vaultID else {
                throw PlanningStorageError.invalid("conflict.vaultID")
            }
            return try transaction {
                guard try mutationLocked(for: conflict.mutationID) != nil else {
                    throw PlanningStorageError.notFound
                }
                try insertPayloadIfNeeded(conflict.localBytes)
                try insertPayloadIfNeeded(conflict.observedBytes)
                let baseToken = planningVersionToken(conflict.baseVersion)
                let localDigest: String?
                if let localBytes = conflict.localBytes {
                    localDigest = try planningRequiredDigest(localBytes)
                } else {
                    localDigest = nil
                }
                let observedDigest: String?
                if let observedBytes = conflict.observedBytes {
                    observedDigest = try planningRequiredDigest(observedBytes)
                } else {
                    observedDigest = nil
                }
                try execute(
                    """
                    INSERT OR REPLACE INTO conflicts(
                        conflict_id, mutation_id, vault_id, path, operation, reason,
                        base_version, local_digest, observed_version, observed_digest, state, created_at
                    ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                    """,
                    binds: [
                        .text(conflict.conflictID.uuidString.lowercased()),
                        .text(conflict.mutationID.uuidString.lowercased()),
                        .text(conflict.vaultID.uuidString.lowercased()),
                        .text(conflict.path.value),
                        .text(conflict.operation.rawValue),
                        .text(conflict.reason),
                        .text(baseToken),
                        .optionalText(localDigest),
                        .text(planningVersionToken(conflict.observedVersion)),
                        .optionalText(observedDigest),
                        .text(conflict.state.rawValue),
                        .double(Date().timeIntervalSince1970)
                    ]
                )
                try updateMutationState(
                    conflict.mutationID,
                    state: conflict.state == .open ? .conflicted : .resolved,
                    errorCode: conflict.state == .open ? "conflict" : nil
                )
                guard let receipt = try receiptLocked(for: conflict.mutationID) else {
                    throw PlanningStorageError.corruptDatabase
                }
                return receipt
            }
        }
        }
    }

    public func resolveConflict(
        _ conflictID: UUID,
        resolution: PlanningConflictResolution
    ) throws -> PlanningConflictResolutionReceipt {
        try withOperation {
        try withOpen {
            try transaction {
                guard let stored = try conflictLocked(for: conflictID) else {
                    throw PlanningStorageError.notFound
                }
                let evidence = try PlanningConflictEvidence(
                    validating: stored.conflict,
                    attemptedPublication: stored.attemptedPublication,
                    displacedVersion: stored.displacedVersion
                )
                try validateConflictResolution(resolution, for: stored.conflict)
                let decision = try PlanningConflictResolver.resolve(evidence: evidence, resolution: resolution)
                switch decision {
                case .keepObserved, .keepBoth:
                    try markConflictResolved(conflictID)
                    try updateMutationState(stored.conflict.mutationID, state: .resolved, errorCode: nil)
                    return PlanningConflictResolutionReceipt(
                        conflictID: conflictID,
                        state: .resolved,
                        newMutationReceipt: try receiptLocked(for: stored.conflict.mutationID)
                    )
                case .applyLocal(let request), .applyMerged(let request):
                    try updateMutationState(stored.conflict.mutationID, state: .resolved, errorCode: nil)
                    let receipt = try stageMutationLocked(request)
                    try markConflictResolved(conflictID)
                    return PlanningConflictResolutionReceipt(
                        conflictID: conflictID,
                        state: .resolved,
                        newMutationReceipt: receipt
                    )
                }
            }
        }
        }
    }

    public func loadRecoveryBatch() throws -> [PlanningRecoveryEntry] {
        try withOperation {
        try withOpen {
            let start = DispatchTime.now().uptimeNanoseconds
            var entries: [PlanningRecoveryEntry] = []
            try query(
                """
                SELECT mutation_id, state
                FROM mutations
                WHERE state IN ('staged', 'prepared', 'stageReady', 'publishing', 'conflicted')
                ORDER BY sequence ASC
                LIMIT ?
                """,
                binds: [.int(PlanningStorageLimits.recoveryBatch)]
            ) { statement in
                guard entries.count < PlanningStorageLimits.recoveryBatch else { return }
                if DispatchTime.now().uptimeNanoseconds - start >= PlanningStorageLimits.recoveryBudgetNanoseconds {
                    return
                }
                guard let mutationText = try columnText(statement, 0),
                      let mutationID = UUID(uuidString: mutationText),
                      let stateText = try columnText(statement, 1),
                      let state = PlanningMutationState(rawValue: stateText) else {
                    throw PlanningStorageError.corruptDatabase
                }
                guard let stored = try mutationLocked(for: mutationID) else {
                    throw PlanningStorageError.corruptDatabase
                }
                let request = stored.request
                let proposedCount = request.proposedBytes?.count ?? 0
                let currentCount = entries.reduce(0) { $0 + ($1.request.proposedBytes?.count ?? 0) }
                guard currentCount + proposedCount <= PlanningStorageLimits.recoveryPayloadBytes else {
                    return
                }
                let attemptID = try latestAttemptID(for: mutationID)
                entries.append(PlanningRecoveryEntry(
                    mutationID: mutationID,
                    state: state,
                    request: request,
                    attemptID: attemptID
                ))
            }
            return entries
        }
        }
    }

    @discardableResult
    public func compactUnreferencedPayloads() throws -> Int {
        try withOperation {
        try withOpen {
            try transaction {
                let before = try scalarInt("SELECT COUNT(*) FROM payloads")
                try execute(
                    """
                    DELETE FROM payloads
                    WHERE digest NOT IN (
                        SELECT proposed_digest FROM mutations WHERE proposed_digest IS NOT NULL
                        UNION SELECT local_digest FROM conflicts WHERE state = 'open' AND local_digest IS NOT NULL
                        UNION SELECT observed_digest FROM conflicts WHERE state = 'open' AND observed_digest IS NOT NULL
                    )
                    """
                )
                let after = try scalarInt("SELECT COUNT(*) FROM payloads")
                return max(0, before - after)
            }
        }
        }
    }

    public func status() throws -> PlanningStoreStatus {
        try withOperation {
        try withOpen {
            let pending = try scalarInt(
                "SELECT COUNT(*) FROM mutations WHERE state IN ('staged','prepared','stageReady','publishing','conflicted')"
            )
            let conflicts = try scalarInt("SELECT COUNT(*) FROM conflicts WHERE state = 'open'")
            let payloadBytes = try scalarInt("SELECT COALESCE(SUM(byte_count), 0) FROM payloads")
            let databaseBytes = try databaseSizeBytes()
            return try PlanningStoreStatus(
                accessState: .ready,
                pendingMutationCount: pending,
                openConflictCount: conflicts,
                retainedPayloadBytes: payloadBytes,
                databaseBytes: databaseBytes
            )
        }
        }
    }

    internal func debugPragmaSnapshot() throws -> PlanningJournalPragmaSnapshot {
        try withOperation {
            try withOpen {
                PlanningJournalPragmaSnapshot(
                    journalMode: try pragmaString("journal_mode").lowercased(),
                    synchronous: try pragmaInteger("synchronous"),
                    foreignKeys: try pragmaInteger("foreign_keys"),
                    busyTimeout: try pragmaInteger("busy_timeout")
                )
            }
        }
    }

    private struct StoredMutation {
        let request: PlanningMutationRequest
        let fingerprint: String
        let state: PlanningMutationState
    }

    private struct StoredConflict {
        let conflict: PlanningConflict
        let attemptedPublication: Bool
        let displacedVersion: PlanningContentVersion?
    }

    private enum BindValue {
        case text(String)
        case optionalText(String?)
        case blob(Data)
        case optionalBlob(Data?)
        case int(Int)
        case int64(Int64)
        case double(Double)
        case null
    }

    private func withOperation<T>(_ body: () throws -> T) rethrows -> T {
        operationLock.lock()
        defer { operationLock.unlock() }
        return try body()
    }

    private func mapPersistedCorruption<T>(_ body: () throws -> T) throws -> T {
        do {
            return try body()
        } catch {
            throw PlanningStorageError.corruptDatabase
        }
    }

    private func withOpen<T>(_ body: () throws -> T) throws -> T {
        guard !isClosed else { throw PlanningStorageError.closed }
        guard isOpen, database != nil else { throw PlanningStorageError.unavailable("notOpen") }
        do {
            return try body()
        } catch {
            throw error
        }
    }

    private func createStorageDirectory() throws {
        var isDirectory: ObjCBool = false
        let fm = FileManager.default
        if fm.fileExists(atPath: directoryURL.path, isDirectory: &isDirectory) {
            guard isDirectory.boolValue else { throw PlanningStorageError.unavailable("storageDirectory") }
        } else {
            try fm.createDirectory(
                at: directoryURL,
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700]
            )
        }
        try fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directoryURL.path)
    }

    private func rejectSymlink(at url: URL) throws {
        var info = stat()
        guard lstat(url.path, &info) == 0 else {
            if errno == ENOENT { return }
            throw PlanningStorageError.unavailable("storageIdentity")
        }
        guard (info.st_mode & S_IFMT) != S_IFLNK else {
            throw PlanningStorageError.unavailable("storageSymlink")
        }
        guard (info.st_mode & S_IFMT) == S_IFREG else {
            throw PlanningStorageError.unavailable("storageType")
        }
    }

    private func acquireWriterLock() throws {
        #if canImport(Darwin)
        let flags = O_CREAT | O_RDWR | O_CLOEXEC | O_NOFOLLOW
        let descriptor = lockURL.path.withCString { Darwin.open($0, flags, 0o600) }
        guard descriptor >= 0 else {
            throw PlanningStorageError.unavailable("writerLock")
        }
        var pathInfo = stat()
        var descriptorInfo = stat()
        guard lstat(lockURL.path, &pathInfo) == 0,
              fstat(descriptor, &descriptorInfo) == 0,
              pathInfo.st_dev == descriptorInfo.st_dev,
              pathInfo.st_ino == descriptorInfo.st_ino,
              (descriptorInfo.st_mode & S_IFMT) == S_IFREG else {
            Darwin.close(descriptor)
            throw PlanningStorageError.unavailable("writerLockIdentity")
        }
        guard flock(descriptor, LOCK_EX | LOCK_NB) == 0 else {
            Darwin.close(descriptor)
            if errno == EWOULDBLOCK || errno == EAGAIN {
                throw PlanningStorageError.writerBusy
            }
            throw PlanningStorageError.unavailable("writerLock")
        }
        lockDescriptor = descriptor
        #else
        throw PlanningStorageError.unavailable("writerLockPlatform")
        #endif
    }

    private func releaseWriterLock() {
        #if canImport(Darwin)
        guard lockDescriptor >= 0 else { return }
        _ = flock(lockDescriptor, LOCK_UN)
        _ = Darwin.close(lockDescriptor)
        lockDescriptor = -1
        #endif
    }

    private func configureAndVerifyPragmas() throws {
        guard let database else { throw PlanningStorageError.closed }
        guard sqlite3_busy_timeout(database, 1_000) == SQLITE_OK else {
            throw PlanningStorageError.unavailable("busyTimeout")
        }
        let assignedJournalMode = try pragmaString("journal_mode = DELETE")
        try consumeRows("PRAGMA synchronous = EXTRA")
        try consumeRows("PRAGMA foreign_keys = ON")
        guard assignedJournalMode.lowercased() == "delete",
              try pragmaString("journal_mode").lowercased() == "delete",
              try pragmaInteger("synchronous") == 3,
              try pragmaInteger("foreign_keys") == 1,
              try pragmaInteger("busy_timeout") == 1_000 else {
            throw PlanningStorageError.unavailable("sqlitePragmas")
        }
    }

    private func createSchemaAndVault() throws {
        try execute("BEGIN EXCLUSIVE")
        do {
            let statements = [
                """
                CREATE TABLE vault(
                    schema_version INTEGER NOT NULL,
                    vault_id TEXT NOT NULL PRIMARY KEY,
                    lifeos_subfolder TEXT NOT NULL,
                    device_id TEXT NOT NULL,
                    created_at REAL NOT NULL
                )
                """,
                """
                CREATE TABLE documents(
                    path TEXT NOT NULL PRIMARY KEY,
                    collision_key TEXT NOT NULL UNIQUE,
                    observed_version TEXT NOT NULL,
                    cached_bytes BLOB,
                    observed_at REAL NOT NULL
                )
                """,
                """
                CREATE TABLE mutations(
                    sequence INTEGER NOT NULL PRIMARY KEY AUTOINCREMENT,
                    mutation_id TEXT NOT NULL UNIQUE,
                    fingerprint TEXT NOT NULL UNIQUE,
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
                """,
                """
                CREATE TABLE publication_attempts(
                    attempt_id TEXT NOT NULL PRIMARY KEY,
                    mutation_id TEXT NOT NULL REFERENCES mutations(mutation_id),
                    phase TEXT NOT NULL,
                    witness_name TEXT,
                    staged_identity TEXT,
                    created_at REAL NOT NULL,
                    updated_at REAL NOT NULL
                )
                """,
                """
                CREATE TABLE conflicts(
                    conflict_id TEXT NOT NULL PRIMARY KEY,
                    mutation_id TEXT NOT NULL REFERENCES mutations(mutation_id),
                    vault_id TEXT NOT NULL,
                    path TEXT NOT NULL,
                    operation TEXT NOT NULL,
                    reason TEXT NOT NULL,
                    base_version TEXT NOT NULL,
                    local_digest TEXT,
                    observed_version TEXT NOT NULL,
                    observed_digest TEXT,
                    state TEXT NOT NULL,
                    created_at REAL NOT NULL
                )
                """,
                """
                CREATE TABLE payloads(
                    digest TEXT NOT NULL PRIMARY KEY,
                    byte_count INTEGER NOT NULL,
                    bytes BLOB NOT NULL
                )
                """,
                """
                CREATE TABLE receipts(
                    mutation_id TEXT NOT NULL PRIMARY KEY REFERENCES mutations(mutation_id),
                    fingerprint TEXT NOT NULL,
                    state TEXT NOT NULL,
                    result_version TEXT,
                    error_code TEXT,
                    updated_at REAL NOT NULL
                )
                """,
                """
                CREATE TABLE mutation_reservations(
                    collision_key TEXT NOT NULL PRIMARY KEY,
                    mutation_id TEXT NOT NULL UNIQUE REFERENCES mutations(mutation_id)
                )
                """,
                "CREATE INDEX mutations_nonterminal ON mutations(state, sequence)",
                "CREATE INDEX mutations_fingerprint ON mutations(fingerprint)",
                "CREATE INDEX attempts_mutation ON publication_attempts(mutation_id, updated_at)",
                "CREATE INDEX conflicts_state ON conflicts(state, created_at)",
                "CREATE INDEX mutation_reservations_mutation ON mutation_reservations(mutation_id)"
            ]
            for statement in statements {
                try execute(statement)
            }
            try consumeRows("PRAGMA user_version = 1")
            guard try pragmaInteger("user_version") == 1 else {
                throw PlanningStorageError.corruptDatabase
            }
            try execute(
                """
                INSERT INTO vault(schema_version, vault_id, lifeos_subfolder, device_id, created_at)
                VALUES (?, ?, ?, ?, ?)
                """,
                binds: [
                    .int(1),
                    .text(vault.vaultID.uuidString.lowercased()),
                    .text("LifeOS"),
                    .text(deviceID.uuidString.lowercased()),
                    .double(Date().timeIntervalSince1970)
                ]
            )
            try verifySchema()
            try validateVaultRow()
            try execute("COMMIT")
        } catch {
            _ = try? execute("ROLLBACK")
            throw error
        }
    }

    private func verifySchema() throws {
        let expectedTables: Set<String> = [
            "vault", "documents", "mutations", "publication_attempts",
            "conflicts", "payloads", "receipts", "mutation_reservations"
        ]
        var actualTables = Set<String>()
        try query(
            "SELECT name FROM sqlite_master WHERE type = 'table' AND name NOT LIKE 'sqlite_%'"
        ) { statement in
            if let name = try columnText(statement, 0) { actualTables.insert(name) }
        }
        guard actualTables == expectedTables else {
            throw PlanningStorageError.corruptDatabase
        }

        let expectedColumns: [(String, [String: PlanningSchemaColumn])] = [
            ("vault", [
                "schema_version": PlanningSchemaColumn(type: "INTEGER", notNull: 1, primaryKey: 0),
                "vault_id": PlanningSchemaColumn(type: "TEXT", notNull: 1, primaryKey: 1),
                "lifeos_subfolder": PlanningSchemaColumn(type: "TEXT", notNull: 1, primaryKey: 0),
                "device_id": PlanningSchemaColumn(type: "TEXT", notNull: 1, primaryKey: 0),
                "created_at": PlanningSchemaColumn(type: "REAL", notNull: 1, primaryKey: 0)
            ]),
            ("documents", [
                "path": PlanningSchemaColumn(type: "TEXT", notNull: 1, primaryKey: 1),
                "collision_key": PlanningSchemaColumn(type: "TEXT", notNull: 1, primaryKey: 0),
                "observed_version": PlanningSchemaColumn(type: "TEXT", notNull: 1, primaryKey: 0),
                "cached_bytes": PlanningSchemaColumn(type: "BLOB", notNull: 0, primaryKey: 0),
                "observed_at": PlanningSchemaColumn(type: "REAL", notNull: 1, primaryKey: 0)
            ]),
            ("mutations", [
                "sequence": PlanningSchemaColumn(type: "INTEGER", notNull: 1, primaryKey: 1),
                "mutation_id": PlanningSchemaColumn(type: "TEXT", notNull: 1, primaryKey: 0),
                "fingerprint": PlanningSchemaColumn(type: "TEXT", notNull: 1, primaryKey: 0),
                "vault_id": PlanningSchemaColumn(type: "TEXT", notNull: 1, primaryKey: 0),
                "path": PlanningSchemaColumn(type: "TEXT", notNull: 1, primaryKey: 0),
                "operation": PlanningSchemaColumn(type: "TEXT", notNull: 1, primaryKey: 0),
                "expected_version": PlanningSchemaColumn(type: "TEXT", notNull: 1, primaryKey: 0),
                "proposed_digest": PlanningSchemaColumn(type: "TEXT", notNull: 0, primaryKey: 0),
                "state": PlanningSchemaColumn(type: "TEXT", notNull: 1, primaryKey: 0),
                "error_code": PlanningSchemaColumn(type: "TEXT", notNull: 0, primaryKey: 0),
                "created_at": PlanningSchemaColumn(type: "REAL", notNull: 1, primaryKey: 0),
                "updated_at": PlanningSchemaColumn(type: "REAL", notNull: 1, primaryKey: 0)
            ]),
            ("publication_attempts", [
                "attempt_id": PlanningSchemaColumn(type: "TEXT", notNull: 1, primaryKey: 1),
                "mutation_id": PlanningSchemaColumn(type: "TEXT", notNull: 1, primaryKey: 0),
                "phase": PlanningSchemaColumn(type: "TEXT", notNull: 1, primaryKey: 0),
                "witness_name": PlanningSchemaColumn(type: "TEXT", notNull: 0, primaryKey: 0),
                "staged_identity": PlanningSchemaColumn(type: "TEXT", notNull: 0, primaryKey: 0),
                "created_at": PlanningSchemaColumn(type: "REAL", notNull: 1, primaryKey: 0),
                "updated_at": PlanningSchemaColumn(type: "REAL", notNull: 1, primaryKey: 0)
            ]),
            ("conflicts", [
                "conflict_id": PlanningSchemaColumn(type: "TEXT", notNull: 1, primaryKey: 1),
                "mutation_id": PlanningSchemaColumn(type: "TEXT", notNull: 1, primaryKey: 0),
                "vault_id": PlanningSchemaColumn(type: "TEXT", notNull: 1, primaryKey: 0),
                "path": PlanningSchemaColumn(type: "TEXT", notNull: 1, primaryKey: 0),
                "operation": PlanningSchemaColumn(type: "TEXT", notNull: 1, primaryKey: 0),
                "reason": PlanningSchemaColumn(type: "TEXT", notNull: 1, primaryKey: 0),
                "base_version": PlanningSchemaColumn(type: "TEXT", notNull: 1, primaryKey: 0),
                "local_digest": PlanningSchemaColumn(type: "TEXT", notNull: 0, primaryKey: 0),
                "observed_version": PlanningSchemaColumn(type: "TEXT", notNull: 1, primaryKey: 0),
                "observed_digest": PlanningSchemaColumn(type: "TEXT", notNull: 0, primaryKey: 0),
                "state": PlanningSchemaColumn(type: "TEXT", notNull: 1, primaryKey: 0),
                "created_at": PlanningSchemaColumn(type: "REAL", notNull: 1, primaryKey: 0)
            ]),
            ("payloads", [
                "digest": PlanningSchemaColumn(type: "TEXT", notNull: 1, primaryKey: 1),
                "byte_count": PlanningSchemaColumn(type: "INTEGER", notNull: 1, primaryKey: 0),
                "bytes": PlanningSchemaColumn(type: "BLOB", notNull: 1, primaryKey: 0)
            ]),
            ("receipts", [
                "mutation_id": PlanningSchemaColumn(type: "TEXT", notNull: 1, primaryKey: 1),
                "fingerprint": PlanningSchemaColumn(type: "TEXT", notNull: 1, primaryKey: 0),
                "state": PlanningSchemaColumn(type: "TEXT", notNull: 1, primaryKey: 0),
                "result_version": PlanningSchemaColumn(type: "TEXT", notNull: 0, primaryKey: 0),
                "error_code": PlanningSchemaColumn(type: "TEXT", notNull: 0, primaryKey: 0),
                "updated_at": PlanningSchemaColumn(type: "REAL", notNull: 1, primaryKey: 0)
            ]),
            ("mutation_reservations", [
                "collision_key": PlanningSchemaColumn(type: "TEXT", notNull: 1, primaryKey: 1),
                "mutation_id": PlanningSchemaColumn(type: "TEXT", notNull: 1, primaryKey: 0)
            ])
        ]
        for (table, expected) in expectedColumns {
            guard try schemaColumns(for: table) == expected else {
                throw PlanningStorageError.corruptDatabase
            }
        }

        let uniqueConstraints: [(String, [String])] = [
            ("vault", ["vault_id"]),
            ("documents", ["path"]),
            ("documents", ["collision_key"]),
            ("mutations", ["mutation_id"]),
            ("mutations", ["fingerprint"]),
            ("publication_attempts", ["attempt_id"]),
            ("conflicts", ["conflict_id"]),
            ("payloads", ["digest"]),
            ("receipts", ["mutation_id"]),
            ("mutation_reservations", ["collision_key"]),
            ("mutation_reservations", ["mutation_id"])
        ]
        var indexesByTable: [String: [PlanningSchemaIndex]] = [:]
        for table in expectedTables {
            indexesByTable[table] = try schemaIndexes(for: table)
        }
        for (table, columns) in uniqueConstraints {
            guard indexesByTable[table]?.contains(where: {
                $0.unique
                    && !$0.partial
                    && $0.columns == columns
                    && $0.usesDefaultComparisonSemantics
            }) == true else {
                throw PlanningStorageError.corruptDatabase
            }
        }

        let requiredIndexes: [(String, String, [String])] = [
            ("mutations", "mutations_nonterminal", ["state", "sequence"]),
            ("mutations", "mutations_fingerprint", ["fingerprint"]),
            ("publication_attempts", "attempts_mutation", ["mutation_id", "updated_at"]),
            ("conflicts", "conflicts_state", ["state", "created_at"]),
            ("mutation_reservations", "mutation_reservations_mutation", ["mutation_id"])
        ]
        for (table, name, columns) in requiredIndexes {
            guard indexesByTable[table]?.contains(where: {
                $0.name == name && !$0.unique && !$0.partial && $0.columns == columns
            }) == true else {
                throw PlanningStorageError.corruptDatabase
            }
        }

        let expectedForeignKeys: [(String, [PlanningSchemaForeignKey])] = [
            ("vault", []),
            ("documents", []),
            (
                "mutations",
                []
            ),
            (
                "publication_attempts",
                [
                    PlanningSchemaForeignKey(
                        id: 0,
                        sequence: 0,
                        table: "mutations",
                        from: "mutation_id",
                        to: "mutation_id",
                        onUpdate: "NO ACTION",
                        onDelete: "NO ACTION",
                        match: "NONE"
                    )
                ]
            ),
            (
                "conflicts",
                [
                    PlanningSchemaForeignKey(
                        id: 0,
                        sequence: 0,
                        table: "mutations",
                        from: "mutation_id",
                        to: "mutation_id",
                        onUpdate: "NO ACTION",
                        onDelete: "NO ACTION",
                        match: "NONE"
                    )
                ]
            ),
            ("payloads", []),
            (
                "receipts",
                [
                    PlanningSchemaForeignKey(
                        id: 0,
                        sequence: 0,
                        table: "mutations",
                        from: "mutation_id",
                        to: "mutation_id",
                        onUpdate: "NO ACTION",
                        onDelete: "NO ACTION",
                        match: "NONE"
                    )
                ]
            ),
            (
                "mutation_reservations",
                [
                    PlanningSchemaForeignKey(
                        id: 0,
                        sequence: 0,
                        table: "mutations",
                        from: "mutation_id",
                        to: "mutation_id",
                        onUpdate: "NO ACTION",
                        onDelete: "NO ACTION",
                        match: "NONE"
                    )
                ]
            )
        ]
        for (table, expected) in expectedForeignKeys {
            guard try schemaForeignKeys(for: table) == expected else {
                throw PlanningStorageError.corruptDatabase
            }
        }
        var hasForeignKeyViolation = false
        try query("PRAGMA foreign_key_check") { _ in
            hasForeignKeyViolation = true
        }
        guard !hasForeignKeyViolation else {
            throw PlanningStorageError.corruptDatabase
        }
    }

    private func schemaColumns(for table: String) throws -> [String: PlanningSchemaColumn] {
        var rows: [(String, PlanningSchemaColumn)] = []
        let escapedTable = table.replacingOccurrences(of: "'", with: "''")
        try query("PRAGMA table_info('\(escapedTable)')") { statement in
            guard let name = try columnText(statement, 1),
                  let type = try columnText(statement, 2),
                  let notNull = columnInt(statement, 3),
                  let primaryKey = columnInt(statement, 5) else {
                throw PlanningStorageError.corruptDatabase
            }
            rows.append((name, PlanningSchemaColumn(
                type: type.uppercased(),
                notNull: notNull,
                primaryKey: primaryKey
            )))
        }
        var columns: [String: PlanningSchemaColumn] = [:]
        for (name, column) in rows {
            guard columns.updateValue(column, forKey: name) == nil else {
                throw PlanningStorageError.corruptDatabase
            }
        }
        return columns
    }

    private func schemaIndexes(for table: String) throws -> [PlanningSchemaIndex] {
        var indexes: [PlanningSchemaIndex] = []
        let escapedTable = table.replacingOccurrences(of: "'", with: "''")
        try query("PRAGMA index_list('\(escapedTable)')") { statement in
            guard let name = try columnText(statement, 1),
                  let unique = columnInt(statement, 2),
                  let partial = columnInt(statement, 4) else {
                throw PlanningStorageError.corruptDatabase
            }
            let keyColumns = try schemaIndexKeyColumns(name)
            indexes.append(PlanningSchemaIndex(
                name: name,
                unique: unique == 1,
                partial: partial == 1,
                columns: keyColumns.map(\.name),
                collations: keyColumns.map(\.collation),
                descending: keyColumns.map(\.descending)
            ))
        }
        return indexes
    }

    private func schemaIndexKeyColumns(
        _ index: String
    ) throws -> [(sequence: Int, name: String, collation: String, descending: Bool)] {
        var columns: [(sequence: Int, name: String, collation: String, descending: Bool)] = []
        let escapedIndex = index.replacingOccurrences(of: "'", with: "''")
        try query("PRAGMA index_xinfo('\(escapedIndex)')") { statement in
            guard let sequence = columnInt(statement, 0),
                  let isKey = columnInt(statement, 5) else {
                throw PlanningStorageError.corruptDatabase
            }
            guard isKey == 1 else { return }
            guard let name = try columnText(statement, 2),
                  let descending = columnInt(statement, 3),
                  let collation = try columnText(statement, 4),
                  descending == 0 || descending == 1 else {
                throw PlanningStorageError.corruptDatabase
            }
            columns.append((sequence, name, collation, descending == 1))
        }
        return columns.sorted { $0.sequence < $1.sequence }
    }

    private func schemaForeignKeys(for table: String) throws -> [PlanningSchemaForeignKey] {
        var keys: [PlanningSchemaForeignKey] = []
        let escapedTable = table.replacingOccurrences(of: "'", with: "''")
        try query("PRAGMA foreign_key_list('\(escapedTable)')") { statement in
            guard let id = columnInt(statement, 0),
                  let sequence = columnInt(statement, 1),
                  let referencedTable = try columnText(statement, 2),
                  let from = try columnText(statement, 3),
                  let to = try columnText(statement, 4),
                  let onUpdate = try columnText(statement, 5),
                  let onDelete = try columnText(statement, 6),
                  let match = try columnText(statement, 7) else {
                throw PlanningStorageError.corruptDatabase
            }
            keys.append(PlanningSchemaForeignKey(
                id: id,
                sequence: sequence,
                table: referencedTable,
                from: from,
                to: to,
                onUpdate: onUpdate,
                onDelete: onDelete,
                match: match
            ))
        }
        return keys.sorted {
            if $0.id == $1.id { return $0.sequence < $1.sequence }
            return $0.id < $1.id
        }
    }

    private func validateVaultRow() throws {
        let count = try scalarInt("SELECT COUNT(*) FROM vault")
        guard count == 1 else { throw PlanningStorageError.corruptDatabase }
        var matched = false
        try query(
            "SELECT schema_version, vault_id, lifeos_subfolder FROM vault"
        ) { statement in
            guard let storedVaultID = try columnText(statement, 1),
                  let storedSubfolder = try columnText(statement, 2) else {
                throw PlanningStorageError.corruptDatabase
            }
            matched = sqlite3_column_int(statement, 0) == 1
                && storedVaultID == vault.vaultID.uuidString.lowercased()
                && storedSubfolder == "LifeOS"
        }
        guard matched else { throw PlanningStorageError.corruptDatabase }
    }

    private func validateDurableRecords() throws {
        var mutationIDs: [UUID] = []
        try query("SELECT mutation_id FROM mutations ORDER BY sequence ASC") { statement in
            guard let value = try columnText(statement, 0),
                  let mutationID = UUID(uuidString: value) else {
                throw PlanningStorageError.corruptDatabase
            }
            mutationIDs.append(mutationID)
        }
        for mutationID in mutationIDs {
            guard try mutationLocked(for: mutationID) != nil,
                  try receiptLocked(for: mutationID) != nil else {
                throw PlanningStorageError.corruptDatabase
            }
        }

        var receiptIDs: [UUID] = []
        try query("SELECT mutation_id FROM receipts") { statement in
            guard let value = try columnText(statement, 0),
                  let mutationID = UUID(uuidString: value) else {
                throw PlanningStorageError.corruptDatabase
            }
            receiptIDs.append(mutationID)
        }
        for mutationID in receiptIDs {
            guard try receiptLocked(for: mutationID) != nil else {
                throw PlanningStorageError.corruptDatabase
            }
        }

        var conflictIDs: [UUID] = []
        try query("SELECT conflict_id FROM conflicts") { statement in
            guard let value = try columnText(statement, 0),
                  let conflictID = UUID(uuidString: value) else {
                throw PlanningStorageError.corruptDatabase
            }
            conflictIDs.append(conflictID)
        }
        for conflictID in conflictIDs {
            guard try conflictLocked(for: conflictID) != nil else {
                throw PlanningStorageError.corruptDatabase
            }
        }

        var payloadDigests: [String] = []
        try query("SELECT digest FROM payloads") { statement in
            guard let digest = try columnText(statement, 0) else {
                throw PlanningStorageError.corruptDatabase
            }
            payloadDigests.append(digest)
        }
        for digest in payloadDigests {
            guard try payloadLocked(digest: digest) != nil else {
                throw PlanningStorageError.corruptDatabase
            }
        }

        try query("SELECT collision_key, mutation_id FROM mutation_reservations") { statement in
            guard let collisionKey = try columnText(statement, 0),
                  let mutationText = try columnText(statement, 1),
                  let mutationID = UUID(uuidString: mutationText),
                  let mutation = try mutationLocked(for: mutationID),
                  mutation.request.path.collisionKey == collisionKey,
                  mutation.state.isPending else {
                throw PlanningStorageError.corruptDatabase
            }
        }
    }

    private func transaction<T>(_ body: () throws -> T) throws -> T {
        try execute("BEGIN IMMEDIATE")
        do {
            let value = try body()
            try execute("COMMIT")
            return value
        } catch {
            _ = try? execute("ROLLBACK")
            throw error
        }
    }

    private func stageMutationLocked(_ request: PlanningMutationRequest) throws -> PlanningMutationReceipt {
        let fingerprint = request.fingerprint
        if let existing = try mutationLocked(for: request.mutationID) {
            guard existing.fingerprint == fingerprint else {
                throw PlanningStorageError.mutationIDReused
            }
            guard let receipt = try receiptLocked(for: request.mutationID) else {
                throw PlanningStorageError.corruptDatabase
            }
            return receipt
        }
        if try mutationFingerprintExists(fingerprint) {
            throw PlanningStorageError.duplicateRequest
        }
        let pending = try scalarInt(
            "SELECT COUNT(*) FROM mutations WHERE state IN ('staged','prepared','stageReady','publishing','conflicted')"
        )
        guard pending < PlanningStorageLimits.pendingMutations else {
            throw PlanningStorageError.backpressure("pendingMutations")
        }
        if let proposedBytes = request.proposedBytes {
            try insertPayloadIfNeeded(proposedBytes)
        }
        let now = Date().timeIntervalSince1970
        let proposedDigest: String?
        if let proposedBytes = request.proposedBytes {
            proposedDigest = try planningRequiredDigest(proposedBytes)
        } else {
            proposedDigest = nil
        }
        if let reservationMutationID = try reservationMutationID(for: request.path.collisionKey) {
            guard let reserved = try mutationLocked(for: reservationMutationID) else {
                throw PlanningStorageError.corruptDatabase
            }
            guard reserved.state.isPending else {
                throw PlanningStorageError.corruptDatabase
            }
            throw PlanningStorageError.invalid("mutation.pathCollision")
        }
        try execute(
            """
            INSERT INTO mutations(
                mutation_id, fingerprint, vault_id, path, operation, expected_version,
                proposed_digest, state, error_code, created_at, updated_at
            ) VALUES (?, ?, ?, ?, ?, ?, ?, 'staged', NULL, ?, ?)
            """,
            binds: [
                .text(request.mutationID.uuidString.lowercased()),
                .text(fingerprint),
                .text(request.vaultID.uuidString.lowercased()),
                .text(request.path.value),
                .text(request.operation.rawValue),
                .text(planningVersionToken(request.expectedVersion)),
                .optionalText(proposedDigest),
                .double(now),
                .double(now)
            ]
        )
        try execute(
            "INSERT INTO mutation_reservations(collision_key, mutation_id) VALUES (?, ?)",
            binds: [
                .text(request.path.collisionKey),
                .text(request.mutationID.uuidString.lowercased())
            ]
        )
        try insertReceipt(
            mutationID: request.mutationID,
            fingerprint: fingerprint,
            state: .staged,
            resultVersion: nil,
            errorCode: nil
        )
        try enforceDatabaseBound()
        guard let receipt = try receiptLocked(for: request.mutationID) else {
            throw PlanningStorageError.corruptDatabase
        }
        return receipt
    }

    private func mutationFingerprintExists(_ fingerprint: String) throws -> Bool {
        try scalarInt(
            "SELECT COUNT(*) FROM mutations WHERE fingerprint = ?",
            binds: [.text(fingerprint)]
        ) > 0
    }

    private func reservationMutationID(for collisionKey: String) throws -> UUID? {
        var result: UUID?
        var found = false
        try query(
            "SELECT mutation_id FROM mutation_reservations WHERE collision_key = ?",
            binds: [.text(collisionKey)]
        ) { statement in
            found = true
            guard let value = try columnText(statement, 0),
                  let mutationID = UUID(uuidString: value) else {
                throw PlanningStorageError.corruptDatabase
            }
            result = mutationID
        }
        guard !found || result != nil else { throw PlanningStorageError.corruptDatabase }
        return result
    }

    private func validateReservation(
        for request: PlanningMutationRequest,
        state: PlanningMutationState
    ) throws {
        let reservedMutationID = try reservationMutationID(for: request.path.collisionKey)
        let mutationReservationCount = try scalarInt(
            "SELECT COUNT(*) FROM mutation_reservations WHERE mutation_id = ?",
            binds: [.text(request.mutationID.uuidString.lowercased())]
        )
        if state.isPending {
            guard reservedMutationID == request.mutationID,
                  mutationReservationCount == 1 else {
                throw PlanningStorageError.corruptDatabase
            }
        } else {
            guard mutationReservationCount == 0 else {
                throw PlanningStorageError.corruptDatabase
            }
            guard let reservedMutationID else { return }
            guard reservedMutationID != request.mutationID,
                  let reservedMutation = try mutationLocked(for: reservedMutationID),
                  reservedMutation.state.isPending,
                  reservedMutation.request.path.collisionKey == request.path.collisionKey else {
                throw PlanningStorageError.corruptDatabase
            }
        }
    }

    private func mutationLocked(for mutationID: UUID) throws -> StoredMutation? {
        var result: StoredMutation?
        try query(
            """
            SELECT mutation_id, fingerprint, state, vault_id, path, operation, expected_version, proposed_digest
            FROM mutations WHERE mutation_id = ?
            """,
            binds: [.text(mutationID.uuidString.lowercased())]
        ) { statement in
            try mapPersistedCorruption {
            guard let storedMutationText = try columnText(statement, 0),
                  UUID(uuidString: storedMutationText) == mutationID,
                  let fingerprint = try columnText(statement, 1),
                  planningDigestIsValid(fingerprint),
                  let stateText = try columnText(statement, 2),
                  let state = PlanningMutationState(rawValue: stateText),
                  let vaultText = try columnText(statement, 3),
                  let vaultID = UUID(uuidString: vaultText),
                  let pathText = try columnText(statement, 4),
                  let operationText = try columnText(statement, 5),
                  let operation = PlanningMutationOperation(rawValue: operationText),
                  let expectedText = try columnText(statement, 6) else {
                throw PlanningStorageError.corruptDatabase
            }
            guard vaultID == vault.vaultID else {
                throw PlanningStorageError.corruptDatabase
            }
            let path = try PlanningStoredPath(pathText)
            let expected = try planningVersionFromToken(expectedText)
            let proposedDigest = try columnText(statement, 7)
            let proposedBytes = try proposedDigest.flatMap { try payloadLocked(digest: $0) }
            let request = try PlanningMutationRequest(
                mutationID: mutationID,
                vaultID: vaultID,
                path: path,
                operation: operation,
                expectedVersion: expected,
                proposedBytes: proposedBytes
            )
            guard request.fingerprint == fingerprint else {
                throw PlanningStorageError.corruptDatabase
            }
            try validateReservation(for: request, state: state)
            result = StoredMutation(request: request, fingerprint: fingerprint, state: state)
            }
        }
        return result
    }

    private func receiptLocked(for mutationID: UUID) throws -> PlanningMutationReceipt? {
        var result: PlanningMutationReceipt?
        var found = false
        try query(
            """
            SELECT mutation_id, fingerprint, state, result_version, error_code, updated_at
            FROM receipts WHERE mutation_id = ?
            """,
            binds: [.text(mutationID.uuidString.lowercased())]
        ) { statement in
            try mapPersistedCorruption {
            found = true
            guard let storedMutationText = try columnText(statement, 0),
                  UUID(uuidString: storedMutationText) == mutationID,
                  let fingerprint = try columnText(statement, 1),
                  let stateText = try columnText(statement, 2),
                  let state = PlanningMutationState(rawValue: stateText),
                  let updatedAt = columnDouble(statement, 5) else {
                throw PlanningStorageError.corruptDatabase
            }
            let resultVersion = try columnText(statement, 3).map(planningVersionFromToken)
            let errorCode = try columnText(statement, 4)
            result = try PlanningMutationReceipt(
                mutationID: mutationID,
                fingerprint: fingerprint,
                state: state,
                resultVersion: resultVersion,
                errorCode: errorCode,
                updatedAt: Date(timeIntervalSince1970: updatedAt)
            )
            }
        }
        guard found else {
            let mutationCount = try scalarInt(
                "SELECT COUNT(*) FROM mutations WHERE mutation_id = ?",
                binds: [.text(mutationID.uuidString.lowercased())]
            )
            guard mutationCount == 0 else { throw PlanningStorageError.corruptDatabase }
            return nil
        }
        guard let receipt = result,
              let mutation = try mutationLocked(for: mutationID) else {
            throw PlanningStorageError.corruptDatabase
        }
        guard receipt.fingerprint == mutation.fingerprint,
              receipt.state == mutation.state else {
            throw PlanningStorageError.corruptDatabase
        }
        if receipt.state == .published {
            guard receipt.resultVersion != nil else { throw PlanningStorageError.corruptDatabase }
        } else if receipt.resultVersion != nil {
            throw PlanningStorageError.corruptDatabase
        }
        if let resultVersion = receipt.resultVersion {
            try mapPersistedCorruption {
                try planningValidateContentVersion(
                    resultVersion,
                    maximumByteCount: mutation.request.path.isCanvas
                        ? PlanningStorageLimits.canvasBytes
                        : PlanningStorageLimits.markdownBytes,
                    field: "mutationReceipt.resultVersion"
                )
            }
        }
        return result
    }

    private func insertReceipt(
        mutationID: UUID,
        fingerprint: String,
        state: PlanningMutationState,
        resultVersion: PlanningContentVersion?,
        errorCode: String?
    ) throws {
        try execute(
            """
            INSERT INTO receipts(mutation_id, fingerprint, state, result_version, error_code, updated_at)
            VALUES (?, ?, ?, ?, ?, ?)
            """,
            binds: [
                .text(mutationID.uuidString.lowercased()),
                .text(fingerprint),
                .text(state.rawValue),
                .optionalText(resultVersion.map(planningVersionToken)),
                .optionalText(errorCode),
                .double(Date().timeIntervalSince1970)
            ]
        )
    }

    private func updateMutationState(
        _ mutationID: UUID,
        state: PlanningMutationState,
        errorCode: String?,
        resultVersion: PlanningContentVersion? = nil
    ) throws {
        try execute(
            "UPDATE mutations SET state = ?, error_code = ?, updated_at = ? WHERE mutation_id = ?",
            binds: [
                .text(state.rawValue),
                .optionalText(errorCode),
                .double(Date().timeIntervalSince1970),
                .text(mutationID.uuidString.lowercased())
            ]
        )
        try execute(
            """
            UPDATE receipts SET state = ?, result_version = ?, error_code = ?, updated_at = ?
            WHERE mutation_id = ?
            """,
            binds: [
                .text(state.rawValue),
                .optionalText(resultVersion.map(planningVersionToken)),
                .optionalText(errorCode),
                .double(Date().timeIntervalSince1970),
                .text(mutationID.uuidString.lowercased())
            ]
        )
        if !state.isPending {
            try execute(
                "DELETE FROM mutation_reservations WHERE mutation_id = ?",
                binds: [.text(mutationID.uuidString.lowercased())]
            )
        }
    }

    private func insertPayloadIfNeeded(_ bytes: Data?) throws {
        guard let bytes else { return }
        let digest = try planningRequiredDigest(bytes)
        var exists = false
        try query(
            "SELECT byte_count, bytes FROM payloads WHERE digest = ?",
            binds: [.text(digest)]
        ) { statement in
            guard let count = columnInt(statement, 0),
                  let existing = columnBlob(statement, 1),
                  count == bytes.count,
                  existing == bytes else {
                throw PlanningStorageError.corruptDatabase
            }
            exists = true
        }
        if exists { return }
        let total = try scalarInt("SELECT COALESCE(SUM(byte_count), 0) FROM payloads")
        guard total + bytes.count <= PlanningStorageLimits.pendingPayloadBytes else {
            throw PlanningStorageError.backpressure("payloadBytes")
        }
        try execute(
            "INSERT INTO payloads(digest, byte_count, bytes) VALUES (?, ?, ?)",
            binds: [.text(digest), .int(bytes.count), .blob(bytes)]
        )
    }

    private func payloadLocked(digest: String) throws -> Data? {
        try mapPersistedCorruption {
            var data: Data?
            var found = false
            guard planningDigestIsValid(digest) else { throw PlanningStorageError.corruptDatabase }
            try query(
                "SELECT byte_count, bytes FROM payloads WHERE digest = ?",
                binds: [.text(digest)]
            ) { statement in
                found = true
                guard sqlite3_column_type(statement, 0) == SQLITE_INTEGER,
                      sqlite3_column_type(statement, 1) == SQLITE_BLOB else {
                    throw PlanningStorageError.corruptDatabase
                }
                let storedByteCount = sqlite3_column_int64(statement, 0)
                guard storedByteCount >= 0,
                      storedByteCount <= Int64(PlanningStorageLimits.canvasBytes),
                      storedByteCount <= Int64(Int.max) else {
                    throw PlanningStorageError.corruptDatabase
                }
                let sqliteByteCount = Int(sqlite3_column_bytes(statement, 1))
                guard sqliteByteCount >= 0,
                      Int64(sqliteByteCount) == storedByteCount else {
                    throw PlanningStorageError.corruptDatabase
                }
                let bytes: Data
                if sqliteByteCount == 0 {
                    bytes = Data()
                } else {
                    guard let pointer = sqlite3_column_blob(statement, 1) else {
                        throw PlanningStorageError.corruptDatabase
                    }
                    bytes = Data(bytes: pointer, count: sqliteByteCount)
                }
                let version = PlanningContentVersion(data: bytes)
                try planningValidateContentVersion(version, field: "payload")
                guard version.digest == digest else {
                    throw PlanningStorageError.corruptDatabase
                }
                data = bytes
            }
            guard found, data != nil else { throw PlanningStorageError.corruptDatabase }
            return data
        }
    }

    private func attemptExists(_ attemptID: UUID, mutationID: UUID) throws -> Bool {
        try scalarInt(
            "SELECT COUNT(*) FROM publication_attempts WHERE attempt_id = ? AND mutation_id = ?",
            binds: [
                .text(attemptID.uuidString.lowercased()),
                .text(mutationID.uuidString.lowercased())
            ]
        ) == 1
    }

    private func latestAttemptID(for mutationID: UUID) throws -> UUID? {
        var result: UUID?
        try query(
            """
            SELECT attempt_id FROM publication_attempts
            WHERE mutation_id = ? ORDER BY updated_at DESC LIMIT 1
            """,
            binds: [.text(mutationID.uuidString.lowercased())]
        ) { statement in
            guard let text = try columnText(statement, 0),
                  let attemptID = UUID(uuidString: text) else {
                throw PlanningStorageError.corruptDatabase
            }
            result = attemptID
        }
        return result
    }

    private func persistedTextByteCount(_ value: String) throws -> Int32 {
        let bytes = value.utf8
        guard !bytes.contains(0) else {
            throw PlanningStorageError.invalid("persistedText.nul")
        }
        guard bytes.count <= Int(Int32.max) else {
            throw PlanningStorageError.backpressure("persistedText")
        }
        return Int32(bytes.count)
    }

    private func conflictLocked(for conflictID: UUID) throws -> StoredConflict? {
        var result: StoredConflict?
        try query(
            """
            SELECT conflict_id, mutation_id, vault_id, path, operation, reason,
                   base_version, local_digest, observed_version, observed_digest, state
            FROM conflicts WHERE conflict_id = ?
            """,
            binds: [.text(conflictID.uuidString.lowercased())]
        ) { statement in
            try mapPersistedCorruption {
            guard let conflictText = try columnText(statement, 0),
                  let storedID = UUID(uuidString: conflictText),
                  let mutationText = try columnText(statement, 1),
                  let mutationID = UUID(uuidString: mutationText),
                  let vaultText = try columnText(statement, 2),
                  let vaultID = UUID(uuidString: vaultText),
                  let pathText = try columnText(statement, 3),
                  let operationText = try columnText(statement, 4),
                  let operation = PlanningMutationOperation(rawValue: operationText),
                  let reason = try columnText(statement, 5),
                  let baseText = try columnText(statement, 6),
                  let observedText = try columnText(statement, 8),
                  let stateText = try columnText(statement, 10),
                  let state = PlanningConflictState(rawValue: stateText) else {
                throw PlanningStorageError.corruptDatabase
            }
            guard vaultID == vault.vaultID,
                  let mutation = try mutationLocked(for: mutationID),
                  mutation.request.path.value == pathText,
                  mutation.request.operation == operation else {
                throw PlanningStorageError.corruptDatabase
            }
            let localBytes = try columnText(statement, 7).flatMap { try payloadLocked(digest: $0) }
            let observedBytes = try columnText(statement, 9).flatMap { try payloadLocked(digest: $0) }
            let conflict = try PlanningConflict(
                conflictID: storedID,
                mutationID: mutationID,
                vaultID: vaultID,
                path: try PlanningStoredPath(pathText),
                operation: operation,
                reason: reason,
                baseVersion: try planningVersionFromToken(baseText),
                localBytes: localBytes,
                observedVersion: try planningVersionFromToken(observedText),
                observedBytes: observedBytes,
                state: state
            )
            result = StoredConflict(
                conflict: conflict,
                attemptedPublication: try scalarInt(
                    "SELECT COUNT(*) FROM publication_attempts WHERE mutation_id = ?",
                    binds: [.text(mutationID.uuidString.lowercased())]
                ) > 0,
                displacedVersion: nil
            )
            }
        }
        return result
    }

    private func validateConflictResolution(
        _ resolution: PlanningConflictResolution,
        for conflict: PlanningConflict
    ) throws {
        let maximumByteCount = conflict.path.isCanvas
            ? PlanningStorageLimits.canvasBytes
            : PlanningStorageLimits.markdownBytes
        switch resolution {
        case .keepObserved, .keepBoth:
            return
        case .applyLocal(let expectedObservedVersion):
            try planningValidateContentVersion(
                expectedObservedVersion,
                maximumByteCount: maximumByteCount,
                field: "conflictResolution.expectedObservedVersion"
            )
        case .applyMerged(let bytes, let expectedObservedVersion):
            try planningValidateContentVersion(
                expectedObservedVersion,
                maximumByteCount: maximumByteCount,
                field: "conflictResolution.expectedObservedVersion"
            )
            try PlanningMutationRequest.validateConflictBytes(bytes, for: conflict.path)
        }
    }

    private func markConflictResolved(_ conflictID: UUID) throws {
        try execute(
            "UPDATE conflicts SET state = 'resolved' WHERE conflict_id = ?",
            binds: [.text(conflictID.uuidString.lowercased())]
        )
    }

    private func enforceDatabaseBound() throws {
        guard try databaseSizeBytes() <= PlanningStorageLimits.databaseBytes else {
            throw PlanningStorageError.backpressure("databaseBytes")
        }
    }

    private func databaseSizeBytes() throws -> Int {
        guard let database else { throw PlanningStorageError.closed }
        guard let filename = sqlite3_db_filename(database, "main") else {
            throw PlanningStorageError.unavailable("databasePath")
        }
        let url = URL(fileURLWithPath: String(cString: filename))
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        guard let size = attributes[.size] as? NSNumber else {
            throw PlanningStorageError.unavailable("databaseSize")
        }
        return size.intValue
    }

    private func consumeRows(_ sql: String, binds: [BindValue] = []) throws {
        try query(sql, binds: binds) { _ in }
    }

    private func pragmaInteger(_ name: String) throws -> Int {
        try scalarInt("PRAGMA \(name)")
    }

    private func pragmaString(_ name: String) throws -> String {
        var value: String?
        try query("PRAGMA \(name)") { statement in
            value = try columnText(statement, 0)
        }
        guard let value else { throw PlanningStorageError.corruptDatabase }
        return value
    }

    private func scalarInt(_ sql: String, binds: [BindValue] = []) throws -> Int {
        var result: Int?
        try query(sql, binds: binds) { statement in
            result = columnInt(statement, 0)
        }
        guard let result else { throw PlanningStorageError.corruptDatabase }
        return result
    }

    private func execute(_ sql: String, binds: [BindValue] = []) throws {
        guard let database else { throw PlanningStorageError.closed }
        var statement: OpaquePointer?
        let prepareCode = sqlite3_prepare_v2(database, sql, -1, &statement, nil)
        guard prepareCode == SQLITE_OK, let statement else {
            throw planningSQLiteFailure(prepareCode, database: database)
        }
        defer { sqlite3_finalize(statement) }
        try bind(binds, to: statement)
        let stepCode = sqlite3_step(statement)
        guard stepCode == SQLITE_DONE else {
            throw planningSQLiteFailure(stepCode, database: database)
        }
    }

    private func query(
        _ sql: String,
        binds: [BindValue] = [],
        row: (OpaquePointer) throws -> Void
    ) throws {
        guard let database else { throw PlanningStorageError.closed }
        var statement: OpaquePointer?
        let prepareCode = sqlite3_prepare_v2(database, sql, -1, &statement, nil)
        guard prepareCode == SQLITE_OK, let statement else {
            throw planningSQLiteFailure(prepareCode, database: database)
        }
        defer { sqlite3_finalize(statement) }
        try bind(binds, to: statement)
        while true {
            let stepCode = sqlite3_step(statement)
            switch stepCode {
            case SQLITE_ROW:
                try row(statement)
            case SQLITE_DONE:
                return
            default:
                throw planningSQLiteFailure(stepCode, database: database)
            }
        }
    }

    private func bind(_ values: [BindValue], to statement: OpaquePointer) throws {
        for (offset, value) in values.enumerated() {
            let index = Int32(offset + 1)
            let code: Int32
            switch value {
            case .text(let string):
                let byteCount = try persistedTextByteCount(string)
                code = string.withCString {
                    sqlite3_bind_text(statement, index, $0, byteCount, planningSQLiteTransient)
                }
            case .optionalText(let value):
                guard let value else {
                    code = sqlite3_bind_null(statement, index)
                    break
                }
                let byteCount = try persistedTextByteCount(value)
                code = value.withCString {
                    sqlite3_bind_text(statement, index, $0, byteCount, planningSQLiteTransient)
                }
            case .blob(let data):
                code = data.withUnsafeBytes { buffer in
                    sqlite3_bind_blob(statement, index, buffer.baseAddress, Int32(data.count), planningSQLiteTransient)
                }
            case .optionalBlob(let data):
                guard let data else {
                    code = sqlite3_bind_null(statement, index)
                    break
                }
                code = data.withUnsafeBytes { buffer in
                    sqlite3_bind_blob(statement, index, buffer.baseAddress, Int32(data.count), planningSQLiteTransient)
                }
            case .int(let value):
                code = sqlite3_bind_int(statement, index, Int32(value))
            case .int64(let value):
                code = sqlite3_bind_int64(statement, index, value)
            case .double(let value):
                code = sqlite3_bind_double(statement, index, value)
            case .null:
                code = sqlite3_bind_null(statement, index)
            }
            guard code == SQLITE_OK else {
                throw planningSQLiteFailure(code, database: database)
            }
        }
    }

    private func columnText(_ statement: OpaquePointer, _ index: Int32) throws -> String? {
        let type = sqlite3_column_type(statement, index)
        if type == SQLITE_NULL {
            return nil
        }
        guard type == SQLITE_TEXT else {
            throw PlanningStorageError.corruptDatabase
        }
        let count = Int(sqlite3_column_bytes(statement, index))
        guard count >= 0 else {
            throw PlanningStorageError.corruptDatabase
        }
        if count == 0 {
            guard sqlite3_column_text(statement, index) != nil else {
                throw PlanningStorageError.corruptDatabase
            }
            return ""
        }
        guard let pointer = sqlite3_column_text(statement, index) else {
            throw PlanningStorageError.corruptDatabase
        }
        let bytes = Data(bytes: pointer, count: count)
        guard !bytes.contains(0), let value = String(data: bytes, encoding: .utf8) else {
            throw PlanningStorageError.corruptDatabase
        }
        return value
    }

    private func columnBlob(_ statement: OpaquePointer, _ index: Int32) -> Data? {
        let count = Int(sqlite3_column_bytes(statement, index))
        guard count >= 0, let pointer = sqlite3_column_blob(statement, index) else {
            return count == 0 ? Data() : nil
        }
        return Data(bytes: pointer, count: count)
    }

    private func columnInt(_ statement: OpaquePointer, _ index: Int32) -> Int? {
        sqlite3_column_type(statement, index) == SQLITE_NULL ? nil : Int(sqlite3_column_int64(statement, index))
    }

    private func columnDouble(_ statement: OpaquePointer, _ index: Int32) -> Double? {
        sqlite3_column_type(statement, index) == SQLITE_NULL ? nil : sqlite3_column_double(statement, index)
    }
}
