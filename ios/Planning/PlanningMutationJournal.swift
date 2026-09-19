import Foundation
import SQLite3
#if canImport(Darwin)
import Darwin
#endif

private let planningSQLiteTransient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

private func planningSQLiteFailure(_ code: Int32, database: OpaquePointer?) -> PlanningStorageError {
    let primary = code & 0xFF
    if primary == SQLITE_FULL {
        return .databaseFull
    }
    if primary == SQLITE_IOERR {
        return .database("ioerr:\(code)")
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
    private let clock: () -> Date
    private let monotonicClock: () -> UInt64
    private var database: OpaquePointer?
    private var lockDescriptor: Int32 = -1
    private var isOpen = false
    private var isClosed = false
    private let operationLock = NSLock()

    public init(
        applicationSupportDirectory: URL,
        vault: PlanningVaultIdentity,
        deviceID: UUID = UUID(),
        clock: @escaping () -> Date = { Date() },
        monotonicClock: @escaping () -> UInt64 = { DispatchTime.now().uptimeNanoseconds }
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
        self.clock = clock
        self.monotonicClock = monotonicClock
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
            if existed {
                let preflightUserVersion = try preflightExistingDatabaseHeader()
                // SQLite can update WAL shared-memory metadata merely by
                // opening a database read/write. Validate rejected files
                // through a read-only handle first, then reopen only a file
                // that passed the complete v1/v2 validation.
                var readOnlyDatabase: OpaquePointer?
                let readOnlyFlags = SQLITE_OPEN_READONLY | SQLITE_OPEN_FULLMUTEX
                let readOnlyCode = databaseURL.path.withCString {
                    sqlite3_open_v2($0, &readOnlyDatabase, readOnlyFlags, nil)
                }
                guard readOnlyCode == SQLITE_OK, let readOnlyDatabase else {
                    let error = planningSQLiteFailure(readOnlyCode, database: readOnlyDatabase)
                    if let readOnlyDatabase { sqlite3_close_v2(readOnlyDatabase) }
                    throw error
                }
                database = readOnlyDatabase
                let userVersion = try pragmaInteger("user_version")
                guard userVersion == preflightUserVersion else {
                    throw PlanningStorageError.corruptDatabase
                }
                switch userVersion {
                case 1:
                    // Validate the existing file before any PRAGMA that can
                    // rewrite the database or its journal mode. A rejected
                    // legacy/unsupported file must remain an observation,
                    // not become a repaired file as a side effect of open.
                    try verifySchema(version: 1)
                    try validateVaultRow()
                    try validateDurableRecords()
                case PlanningPublicationLimits.schemaVersion:
                    try verifySchema(version: PlanningPublicationLimits.schemaVersion)
                    try validateVaultRow()
                    try validateDurableRecords()
                case 0:
                    throw PlanningStorageError.corruptDatabase
                default:
                    throw PlanningStorageError.unsupportedSchema(userVersion)
                }

                sqlite3_close_v2(readOnlyDatabase)
                database = nil
                try rejectSymlink(at: databaseURL)

                var opened: OpaquePointer?
                let flags = SQLITE_OPEN_READWRITE | SQLITE_OPEN_FULLMUTEX
                let openCode = databaseURL.path.withCString {
                    sqlite3_open_v2($0, &opened, flags, nil)
                }
                guard openCode == SQLITE_OK, let opened else {
                    let error = planningSQLiteFailure(openCode, database: opened)
                    if let opened { sqlite3_close_v2(opened) }
                    throw error
                }
                database = opened
                switch userVersion {
                case 1:
                    try configureAndVerifyPragmas()
                    try migrateV1ToV2()
                    try verifySchema(version: 2)
                    try validateVaultRow()
                    try validateDurableRecords()
                case PlanningPublicationLimits.schemaVersion:
                    try configureAndVerifyPragmas()
                    try verifySchema(version: PlanningPublicationLimits.schemaVersion)
                    try validateVaultRow()
                    try validateDurableRecords()
                default:
                    throw PlanningStorageError.corruptDatabase
                }
            } else {
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
                guard userVersion == 0 else {
                    throw PlanningStorageError.corruptDatabase
                }
                try configureAndVerifyPragmas()
                try createSchemaAndVault()
            }
            guard try pragmaInteger("user_version") == PlanningPublicationLimits.schemaVersion else {
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
        try beginPublicationInternal(for: mutationID, attemptID: attemptID, context: nil)
    }

    @discardableResult
    public func beginPublication(
        for mutationID: UUID,
        attemptID: UUID = UUID(),
        context: PlanningPublicationContext
    ) throws -> UUID {
        try beginPublicationInternal(for: mutationID, attemptID: attemptID, context: context)
    }

    private func beginPublicationInternal(
        for mutationID: UUID,
        attemptID: UUID,
        context: PlanningPublicationContext?
    ) throws -> UUID {
        try withOperation {
            try withOpen {
                try transaction {
                    guard let mutation = try mutationLocked(for: mutationID) else {
                        throw PlanningStorageError.notFound
                    }
                    if let context {
                        try validatePublicationContext(context, for: mutation.request)
                    }
                    if let existing = try publicationAttemptLocked(for: attemptID) {
                        guard existing.snapshot.mutationID == mutationID else {
                            throw PlanningStorageError.mutationIDReused
                        }
                        if let context {
                            try bindContextIfNeeded(context, to: existing.snapshot)
                        }
                        return attemptID
                    }
                    if let active = try activePublicationAttemptLocked(for: mutationID) {
                        throw PlanningStorageError.invalidState(
                            "publication.activeAttempt.\(active.snapshot.attemptID.uuidString.lowercased())"
                        )
                    }
                    switch mutation.state {
                    case .staged, .prepared:
                        break
                    case .stageReady, .publishing:
                        throw PlanningStorageError.corruptDatabase
                    case .published, .resolved, .cancelled, .failed:
                        throw PlanningStorageError.invalidState(mutation.state.rawValue)
                    case .conflicted:
                        throw PlanningStorageError.conflict
                    }
                    let attemptCount = try scalarInt(
                        "SELECT COUNT(*) FROM publication_attempts WHERE mutation_id = ?",
                        binds: [.text(mutationID.uuidString.lowercased())]
                    )
                    guard attemptCount < PlanningPublicationLimits.maximumAttemptsPerMutation else {
                        throw PlanningStorageError.backpressure("publicationAttempts")
                    }
                    let ordinal = try scalarInt(
                        "SELECT COALESCE(MAX(ordinal), 0) + 1 FROM publication_details WHERE mutation_id = ?",
                        binds: [.text(mutationID.uuidString.lowercased())]
                    )
                    guard ordinal <= PlanningPublicationLimits.maximumAttemptsPerMutation else {
                        throw PlanningStorageError.backpressure("publicationAttempts")
                    }
                    let now = currentDate().timeIntervalSince1970
                    let contextJSON = try context.map {
                        try planningPublicationEncodeJSON(
                            $0,
                            maximumBytes: PlanningPublicationLimits.maximumContextBytes,
                            field: "publicationContext"
                        )
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
                            .double(now),
                            .double(now)
                        ]
                    )
                    try execute(
                        """
                        INSERT INTO publication_details(
                            attempt_id, mutation_id, ordinal, context_json, outcome_json,
                            retry_after, legacy_unverified
                        ) VALUES (?, ?, ?, ?, NULL, NULL, 0)
                        """,
                        binds: [
                            .text(attemptID.uuidString.lowercased()),
                            .text(mutationID.uuidString.lowercased()),
                            .int(ordinal),
                            .optionalBlob(contextJSON)
                        ]
                    )
                    try updateMutationState(mutationID, state: .prepared, errorCode: nil)
                    try enforceDatabaseBound()
                    return attemptID
                }
            }
        }
    }

    public func publicationAttempt(
        for mutationID: UUID
    ) throws -> PlanningPublicationAttemptSnapshot? {
        try withOperation {
            try withOpen {
                guard let attempt = try latestAttemptID(for: mutationID) else { return nil }
                return try publicationAttemptLocked(for: attempt)?.snapshot
            }
        }
    }

    /// Returns migration evidence for a v1 resolved conflict. This record is
    /// inspection-only; it is never treated as a resolution or publication
    /// authorization.
    public func legacyConflictInspection(
        for conflictID: UUID
    ) throws -> PlanningLegacyConflictInspection? {
        try withOperation {
            try withOpen {
                try legacyConflictInspectionLocked(for: conflictID)
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
            guard identity.fileType == PlanningPublicationLimits.regularFileType else {
                throw PlanningStorageError.invalid("publication.stagedIdentity")
            }
            try validateWitnessName(witnessName, attemptID: attemptID)
            try withOpen {
                try transaction {
                    guard let mutation = try mutationLocked(for: mutationID),
                          let stored = try publicationAttemptLocked(for: attemptID),
                          stored.snapshot.mutationID == mutationID else {
                        throw PlanningStorageError.notFound
                    }
                    guard !stored.snapshot.legacyUnverified,
                          stored.snapshot.phase == .prepared,
                          mutation.state == .prepared else {
                        throw PlanningStorageError.invalidState("publication.stageReady")
                    }
                    guard mutation.request.operation != .delete else {
                        throw PlanningStorageError.invalidState("publication.deleteStage")
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
                            .double(currentDate().timeIntervalSince1970),
                            .text(attemptID.uuidString.lowercased()),
                            .text(mutationID.uuidString.lowercased())
                        ]
                    )
                    try updateMutationState(mutationID, state: .stageReady, errorCode: nil)
                }
            }
        }
    }

    public func markPublishing(
        mutationID: UUID,
        attemptID: UUID,
        context: PlanningPublicationContext
    ) throws {
        try withOperation {
            try withOpen {
                try transaction {
                    guard let mutation = try mutationLocked(for: mutationID),
                          let stored = try publicationAttemptLocked(for: attemptID),
                          stored.snapshot.mutationID == mutationID else {
                        throw PlanningStorageError.notFound
                    }
                    try validatePublicationContext(context, for: mutation.request)
                    guard !stored.snapshot.legacyUnverified else {
                        throw PlanningStorageError.invalidState("publication.legacyAttempt")
                    }
                    if let storedContext = stored.snapshot.context, storedContext != context {
                        throw PlanningStorageError.invalidState("publication.contextChanged")
                    }
                    switch mutation.request.operation {
                    case .create, .replace:
                        guard stored.snapshot.phase == .stageReady,
                              stored.snapshot.witnessName != nil,
                              stored.snapshot.stagedIdentity != nil,
                              mutation.state == .stageReady else {
                            throw PlanningStorageError.invalidState("publication.markPublishing")
                        }
                    case .delete:
                        guard stored.snapshot.phase == .prepared || stored.snapshot.phase == .stageReady,
                              mutation.state == .prepared || mutation.state == .stageReady else {
                            throw PlanningStorageError.invalidState("publication.markPublishing")
                        }
                    }
                    let witnessName = stored.snapshot.witnessName ?? expectedWitnessName(attemptID)
                    try validateWitnessName(witnessName, attemptID: attemptID)
                    let contextJSON = try planningPublicationEncodeJSON(
                        context,
                        maximumBytes: PlanningPublicationLimits.maximumContextBytes,
                        field: "publicationContext"
                    )
                    try execute(
                        """
                        UPDATE publication_attempts
                        SET phase = 'publishing', witness_name = ?, updated_at = ?
                        WHERE attempt_id = ? AND mutation_id = ?
                        """,
                        binds: [
                            .text(witnessName),
                            .double(currentDate().timeIntervalSince1970),
                            .text(attemptID.uuidString.lowercased()),
                            .text(mutationID.uuidString.lowercased())
                        ]
                    )
                    try execute(
                        """
                        UPDATE publication_details
                        SET context_json = ?, retry_after = NULL
                        WHERE attempt_id = ?
                        """,
                        binds: [
                            .blob(contextJSON),
                            .text(attemptID.uuidString.lowercased())
                        ]
                    )
                    try updateMutationState(mutationID, state: .publishing, errorCode: nil)
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
                    guard let mutation = try mutationLocked(for: mutationID),
                          let stored = try publicationAttemptLocked(for: attemptID),
                          stored.snapshot.mutationID == mutationID else {
                        throw PlanningStorageError.notFound
                    }
                    let record = try publicationOutcomeRecord(outcome, for: mutation.request)
                    if isTerminalPublicationPhase(stored.snapshot.phase) {
                        guard publicationOutcomeMatches(record, snapshot: stored.snapshot) else {
                            throw PlanningStorageError.invalidState("publication.terminalReplay")
                        }
                        guard let receipt = try receiptLocked(for: mutationID) else {
                            throw PlanningStorageError.corruptDatabase
                        }
                        return receipt
                    }
                    guard !stored.snapshot.legacyUnverified else {
                        throw PlanningStorageError.invalidState("publication.legacyAttempt")
                    }
                    guard let active = try activePublicationAttemptLocked(for: mutationID),
                          active.snapshot.attemptID == attemptID else {
                        throw PlanningStorageError.invalidState("publication.staleAttempt")
                    }

                    let state: PlanningMutationState
                    let phase: PlanningPublicationPhase
                    let retryAfter: Date?
                    switch outcome {
                    case .published(let version):
                        guard stored.snapshot.phase == .publishing,
                              version == expectedPublicationResultVersion(for: mutation.request) else {
                            throw PlanningStorageError.invalidState("publication.resultVersion")
                        }
                        state = .published
                        phase = .published
                        retryAfter = nil
                    case .conflicted:
                        guard stored.snapshot.phase == .prepared
                                || stored.snapshot.phase == .stageReady
                                || stored.snapshot.phase == .publishing else {
                            throw PlanningStorageError.invalidState("publication.conflictPhase")
                        }
                        guard try scalarInt(
                            "SELECT COUNT(*) FROM conflicts WHERE mutation_id = ? AND state = 'open'",
                            binds: [.text(mutationID.uuidString.lowercased())]
                        ) == 1 else {
                            throw PlanningStorageError.conflict
                        }
                        state = .conflicted
                        phase = .conflicted
                        retryAfter = nil
                    case .failed(let code, let retryable):
                        try planningPublicationValidateString(
                            code,
                            maximumBytes: PlanningPublicationLimits.maximumErrorCodeBytes,
                            field: "publication.errorCode",
                            allowEmpty: false
                        )
                        guard stored.snapshot.phase == .prepared || stored.snapshot.phase == .stageReady else {
                            throw PlanningStorageError.invalidState("publication.ambiguous")
                        }
                        state = retryable ? .prepared : .failed
                        phase = .failed
                        if retryable {
                            let priorFailures = try scalarInt(
                                "SELECT COUNT(*) FROM publication_attempts WHERE mutation_id = ? AND phase = 'failed'",
                                binds: [.text(mutationID.uuidString.lowercased())]
                            )
                            let exponent = min(priorFailures, 8)
                            let seconds = min(900.0, 5.0 * pow(2.0, Double(exponent)))
                            retryAfter = currentDate().addingTimeInterval(seconds)
                        } else {
                            retryAfter = nil
                        }
                    }
                    let outcomeJSON = try planningPublicationEncodeJSON(
                        record,
                        maximumBytes: PlanningPublicationLimits.maximumOutcomeBytes,
                        field: "publicationOutcome"
                    )
                    try execute(
                        """
                        UPDATE publication_attempts
                        SET phase = ?, updated_at = ?
                        WHERE attempt_id = ? AND mutation_id = ?
                        """,
                        binds: [
                            .text(phase.rawValue),
                            .double(currentDate().timeIntervalSince1970),
                            .text(attemptID.uuidString.lowercased()),
                            .text(mutationID.uuidString.lowercased())
                        ]
                    )
                    try execute(
                        """
                        UPDATE publication_details
                        SET outcome_json = ?, retry_after = ?
                        WHERE attempt_id = ?
                        """,
                        binds: [
                            .blob(outcomeJSON),
                            .optionalDouble(retryAfter?.timeIntervalSince1970),
                            .text(attemptID.uuidString.lowercased())
                        ]
                    )
                    try updateMutationState(
                        mutationID,
                        state: state,
                        errorCode: outcomeErrorCode(outcome),
                        resultVersion: outcomeResultVersion(outcome)
                    )
                    guard let receipt = try receiptLocked(for: mutationID) else {
                        throw PlanningStorageError.corruptDatabase
                    }
                    return receipt
                }
            }
        }
    }

    private func validatePublicationContext(
        _ context: PlanningPublicationContext,
        for request: PlanningMutationRequest
    ) throws {
        try planningValidateContentVersion(
            context.observedVersion,
            maximumByteCount: request.path.isCanvas
                ? PlanningStorageLimits.canvasBytes
                : PlanningStorageLimits.markdownBytes,
            field: "publicationContext.observedVersion"
        )
        guard context.observedVersion == request.expectedVersion else {
            throw PlanningStorageError.invalid("publicationContext.expectedVersion")
        }
    }

    private func validateWitnessName(_ witnessName: String, attemptID: UUID) throws {
        try planningPublicationValidateString(
            witnessName,
            maximumBytes: PlanningPublicationLimits.maximumWitnessBytes,
            field: "publication.witnessName",
            allowEmpty: false
        )
        guard witnessName == expectedWitnessName(attemptID) else {
            throw PlanningStorageError.invalid("publication.witnessName")
        }
    }

    private func isTerminalPublicationPhase(_ phase: PlanningPublicationPhase) -> Bool {
        switch phase {
        case .published, .conflicted, .failed:
            return true
        case .prepared, .stageReady, .publishing:
            return false
        }
    }

    private func publicationOutcomeRecord(
        _ outcome: PlanningPublicationOutcome,
        for request: PlanningMutationRequest
    ) throws -> PlanningPublicationOutcomeRecord {
        switch outcome {
        case .published(let version):
            try planningValidateContentVersion(
                version,
                maximumByteCount: request.path.isCanvas
                    ? PlanningStorageLimits.canvasBytes
                    : PlanningStorageLimits.markdownBytes,
                field: "publication.resultVersion"
            )
            return .published(version)
        case .conflicted:
            return .conflicted
        case .failed(let code, let retryable):
            try planningPublicationValidateString(
                code,
                maximumBytes: PlanningPublicationLimits.maximumErrorCodeBytes,
                field: "publication.errorCode",
                allowEmpty: false
            )
            return .failed(code: code, retryable: retryable)
        }
    }

    private func publicationOutcomeMatches(
        _ outcome: PlanningPublicationOutcomeRecord,
        snapshot: PlanningPublicationAttemptSnapshot
    ) -> Bool {
        guard let stored = snapshot.outcome else { return false }
        return stored == outcome
    }

    private func outcomeErrorCode(_ outcome: PlanningPublicationOutcome) -> String? {
        if case .failed(let code, _) = outcome { return code }
        if case .conflicted = outcome { return "conflict" }
        return nil
    }

    private func outcomeResultVersion(_ outcome: PlanningPublicationOutcome) -> PlanningContentVersion? {
        if case .published(let version) = outcome { return version }
        return nil
    }

    private func bindContextIfNeeded(
        _ context: PlanningPublicationContext,
        to snapshot: PlanningPublicationAttemptSnapshot
    ) throws {
        if let storedContext = snapshot.context {
            guard storedContext == context else {
                throw PlanningStorageError.invalidState("publication.contextChanged")
            }
            return
        }
        guard snapshot.phase == .prepared, !snapshot.legacyUnverified else {
            throw PlanningStorageError.invalidState("publication.contextMissing")
        }
        let encoded = try planningPublicationEncodeJSON(
            context,
            maximumBytes: PlanningPublicationLimits.maximumContextBytes,
            field: "publicationContext"
        )
        try execute(
            "UPDATE publication_details SET context_json = ? WHERE attempt_id = ?",
            binds: [.blob(encoded), .text(snapshot.attemptID.uuidString.lowercased())]
        )
    }
    @discardableResult
    public func recordConflict(_ conflict: PlanningConflict) throws -> PlanningMutationReceipt {
        try withOperation {
            try withOpen {
                guard conflict.vaultID == vault.vaultID else {
                    throw PlanningStorageError.invalid("conflict.vaultID")
                }
                guard conflict.state == .open else {
                    throw PlanningStorageError.invalid("conflict.state")
                }
                return try transaction {
                    if let existing = try conflictLocked(for: conflict.conflictID) {
                        guard conflictEvidenceMatches(existing.conflict, conflict) else {
                            throw PlanningStorageError.invalidState("conflictIDReused")
                        }
                        if existing.conflict.state == .resolved {
                            guard try durableResolutionLocked(for: conflict.conflictID) != nil else {
                                throw PlanningStorageError.corruptDatabase
                            }
                        }
                        guard let receipt = try receiptLocked(for: conflict.mutationID) else {
                            throw PlanningStorageError.corruptDatabase
                        }
                        return receipt
                    }
                    guard let mutation = try mutationLocked(for: conflict.mutationID) else {
                        throw PlanningStorageError.notFound
                    }
                    guard mutation.state.isPending,
                          mutation.state != .conflicted else {
                        throw PlanningStorageError.invalidState("conflict.mutation")
                    }
                    guard mutation.request.path == conflict.path,
                          mutation.request.operation == conflict.operation,
                          mutation.request.expectedVersion == conflict.baseVersion,
                          mutation.request.proposedBytes == conflict.localBytes else {
                        throw PlanningStorageError.invalid("conflict.immutableEvidence")
                    }
                    guard try scalarInt(
                        "SELECT COUNT(*) FROM conflicts WHERE mutation_id = ? AND state = 'open'",
                        binds: [.text(conflict.mutationID.uuidString.lowercased())]
                    ) == 0 else {
                        throw PlanningStorageError.invalidState("conflict.multipleOpen")
                    }
                    try insertPayloadIfNeeded(conflict.localBytes)
                    try insertPayloadIfNeeded(conflict.observedBytes)
                    let localDigest = try conflict.localBytes.map(planningRequiredDigest)
                    let observedDigest = try conflict.observedBytes.map(planningRequiredDigest)
                    try execute(
                        """
                        INSERT INTO conflicts(
                            conflict_id, mutation_id, vault_id, path, operation, reason,
                            base_version, local_digest, observed_version, observed_digest, state, created_at
                        ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, 'open', ?)
                        """,
                        binds: [
                            .text(conflict.conflictID.uuidString.lowercased()),
                            .text(conflict.mutationID.uuidString.lowercased()),
                            .text(conflict.vaultID.uuidString.lowercased()),
                            .text(conflict.path.value),
                            .text(conflict.operation.rawValue),
                            .text(conflict.reason),
                            .text(planningVersionToken(conflict.baseVersion)),
                            .optionalText(localDigest),
                            .text(planningVersionToken(conflict.observedVersion)),
                            .optionalText(observedDigest),
                            .double(currentDate().timeIntervalSince1970)
                        ]
                    )
                    if let active = try activePublicationAttemptLocked(for: conflict.mutationID) {
                        let outcomeJSON = try planningPublicationEncodeJSON(
                            PlanningPublicationOutcomeRecord.conflicted,
                            maximumBytes: PlanningPublicationLimits.maximumOutcomeBytes,
                            field: "publicationOutcome"
                        )
                        try execute(
                            """
                            UPDATE publication_attempts
                            SET phase = 'conflicted', updated_at = ?
                            WHERE attempt_id = ?
                            """,
                            binds: [
                                .double(currentDate().timeIntervalSince1970),
                                .text(active.snapshot.attemptID.uuidString.lowercased())
                            ]
                        )
                        try execute(
                            """
                            UPDATE publication_details
                            SET outcome_json = ?, retry_after = NULL
                            WHERE attempt_id = ?
                            """,
                            binds: [
                                .blob(outcomeJSON),
                                .text(active.snapshot.attemptID.uuidString.lowercased())
                            ]
                        )
                    }
                    try updateMutationState(
                        conflict.mutationID,
                        state: .conflicted,
                        errorCode: "conflict"
                    )
                    try enforceDatabaseBound()
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
                    // Validate version/schema/payload bounds before building
                    // the decision fingerprint. This keeps oversized merged
                    // input out of the hash copy, including on replay.
                    try validateConflictResolution(resolution, for: stored.conflict)
                    let fingerprint = planningPublicationDecisionFingerprint(
                        conflictID: conflictID,
                        resolution: resolution
                    )
                    if let existing = try durableResolutionLocked(for: conflictID) {
                        guard existing.decisionFingerprint == fingerprint,
                              existing.resolution == resolution else {
                            throw PlanningStorageError.invalidState("conflictResolution.replay")
                        }
                        let replayMutationID = existing.childMutationID
                            ?? existing.continuationMutationID
                        let childReceipt = try replayMutationID.flatMap {
                            try receiptLocked(for: $0)
                        }
                        let replayReceipt: PlanningMutationReceipt?
                        if let childReceipt {
                            replayReceipt = childReceipt
                        } else {
                            replayReceipt = nil
                        }
                        return PlanningConflictResolutionReceipt(
                            conflictID: conflictID,
                            state: .resolved,
                            newMutationReceipt: replayReceipt
                        )
                    }
                    guard stored.conflict.state == .open else {
                        throw PlanningStorageError.corruptDatabase
                    }
                    let evidence = try PlanningConflictEvidence(
                        validating: stored.conflict,
                        attemptedPublication: stored.attemptedPublication,
                        displacedVersion: stored.displacedVersion
                    )
                    guard let parentMutation = try mutationLocked(for: stored.conflict.mutationID) else {
                        throw PlanningStorageError.corruptDatabase
                    }
                    let decision = try PlanningConflictResolver.resolve(
                        evidence: evidence,
                        resolution: resolution
                    )

                    let childMutationID: UUID?
                    let continuationMutationID: UUID?
                    let childReceipt: PlanningMutationReceipt?
                    switch decision {
                    case .keepObserved:
                        try updateMutationState(
                            stored.conflict.mutationID,
                            state: .resolved,
                            errorCode: nil
                        )
                        childMutationID = nil
                        continuationMutationID = nil
                        childReceipt = nil
                    case .keepBoth(_, let bytes):
                        try updateMutationState(
                            stored.conflict.mutationID,
                            state: .resolved,
                            errorCode: nil
                        )
                        let childRequest = try makeKeepBothRequest(
                            conflict: stored.conflict,
                            bytes: bytes
                        )
                        childMutationID = childRequest.mutationID
                        continuationMutationID = nil
                        childReceipt = try stageMutationLocked(childRequest)
                    case .applyLocal(let request), .applyMerged(let request):
                        if canContinueResolutionInPlace(
                            request,
                            parent: parentMutation,
                            conflict: stored.conflict
                        ) {
                            // A create conflict with an absent observation has
                            // the same request fingerprint as its continuation.
                            // Reopen that exact row instead of weakening global
                            // duplicate detection or creating a second row.
                            try updateMutationState(
                                stored.conflict.mutationID,
                                state: .staged,
                                errorCode: nil
                            )
                            childMutationID = nil
                            continuationMutationID = stored.conflict.mutationID
                            childReceipt = try receiptLocked(for: stored.conflict.mutationID)
                        } else {
                            try updateMutationState(
                                stored.conflict.mutationID,
                                state: .resolved,
                                errorCode: nil
                            )
                            childMutationID = request.mutationID
                            continuationMutationID = nil
                            childReceipt = try stageMutationLocked(request)
                        }
                    }

                    try markConflictResolved(conflictID)
                    let record = try PlanningDurableResolutionRecord(
                        conflictID: conflictID,
                        decisionFingerprint: fingerprint,
                        resolution: resolution,
                        childMutationID: childMutationID,
                        continuationMutationID: continuationMutationID
                    )
                    let decisionJSON = try planningPublicationEncodeJSON(
                        record,
                        maximumBytes: PlanningPublicationLimits.maximumResolutionBytes,
                        field: "durableResolution"
                    )
                    try execute(
                        """
                        INSERT INTO conflict_resolutions(
                            conflict_id, decision_fingerprint, decision_json, child_mutation_id
                        ) VALUES (?, ?, ?, ?)
                        """,
                        binds: [
                            .text(conflictID.uuidString.lowercased()),
                            .text(fingerprint),
                            .blob(decisionJSON),
                            .optionalText(childMutationID?.uuidString.lowercased())
                        ]
                    )
                    try enforceDatabaseBound()
                    return PlanningConflictResolutionReceipt(
                        conflictID: conflictID,
                        state: .resolved,
                        newMutationReceipt: childReceipt
                    )
                }
            }
        }
    }

    private func durableResolutionLocked(
        for conflictID: UUID
    ) throws -> PlanningDurableResolutionRecord? {
        var result: PlanningDurableResolutionRecord?
        var found = false
        try query(
            """
            SELECT decision_fingerprint, decision_json, child_mutation_id
            FROM conflict_resolutions WHERE conflict_id = ?
            """,
            binds: [.text(conflictID.uuidString.lowercased())]
        ) { statement in
            try mapPersistedCorruption {
                found = true
                guard let fingerprint = try columnText(statement, 0),
                      let json = try persistedBlob(
                          statement,
                          1,
                          maximumBytes: PlanningPublicationLimits.maximumResolutionBytes
                      ),
                      let record = try? planningPublicationDecodeJSON(
                          PlanningDurableResolutionRecord.self,
                          data: json,
                          maximumBytes: PlanningPublicationLimits.maximumResolutionBytes,
                          field: "durableResolution"
                      ) else {
                    throw PlanningStorageError.corruptDatabase
                }
                let childText = try columnText(statement, 2)
                guard record.conflictID == conflictID,
                      record.decisionFingerprint == fingerprint,
                      record.childMutationID?.uuidString.lowercased() == childText else {
                    throw PlanningStorageError.corruptDatabase
                }
                result = record
            }
        }
        return found ? result : nil
    }

    private func legacyConflictInspectionLocked(
        for conflictID: UUID
    ) throws -> PlanningLegacyConflictInspection? {
        var result: PlanningLegacyConflictInspection?
        var found = false
        try query(
            """
            SELECT source_schema_version, reason
            FROM legacy_conflict_inspections
            WHERE conflict_id = ?
            """,
            binds: [.text(conflictID.uuidString.lowercased())]
        ) { statement in
            try mapPersistedCorruption {
                found = true
                guard let sourceSchemaVersion = columnInt(statement, 0),
                      let reason = try columnText(statement, 1) else {
                    throw PlanningStorageError.corruptDatabase
                }
                result = try PlanningLegacyConflictInspection(
                    conflictID: conflictID,
                    sourceSchemaVersion: sourceSchemaVersion,
                    reason: reason
                )
            }
        }
        return found ? result : nil
    }

    private func makeKeepBothRequest(
        conflict: PlanningConflict,
        bytes: Data,
        mutationID: UUID = UUID()
    ) throws -> PlanningMutationRequest {
        let original = conflict.path.value
        let filename = original.split(separator: "/").last.map(String.init) ?? original
        let stem: String
        let extensionName: String
        if let dot = filename.lastIndex(of: ".") {
            stem = String(filename[..<dot])
            extensionName = String(filename[dot...])
        } else {
            stem = filename
            extensionName = conflict.path.isCanvas ? ".canvas" : ".md"
        }
        let suffix = " (LifeOS conflict \(conflict.conflictID.uuidString.lowercased()))"
        let directory = original.split(separator: "/").dropLast().joined(separator: "/")
        let primaryName = "\(stem)\(suffix)\(extensionName)"
        let fallbackName = "conflict-\(conflict.conflictID.uuidString.lowercased())\(extensionName)"
        let candidateValues = [
            directory.isEmpty ? primaryName : "\(directory)/\(primaryName)",
            directory.isEmpty ? fallbackName : "\(directory)/\(fallbackName)"
        ]
        var path: PlanningStoredPath?
        for candidate in candidateValues {
            if let value = try? PlanningStoredPath(candidate) {
                path = value
                break
            }
        }
        guard let path else {
            throw PlanningStorageError.backpressure("conflictPath")
        }
        return try PlanningMutationRequest(
            mutationID: mutationID,
            vaultID: conflict.vaultID,
            path: path,
            operation: .create,
            expectedVersion: .absent,
            proposedBytes: bytes
        )
    }

    public func loadRecoveryBatch() throws -> [PlanningRecoveryEntry] {
        let page = try loadPublicationRecoveryPage(after: nil)
        return page.entries.map(\.recovery)
    }

    public func loadPublicationRecoveryPage(
        after cursor: PlanningPublicationRecoveryCursor? = nil
    ) throws -> PlanningPublicationRecoveryPage {
        try withOperation {
            try withOpen {
                let maximumSequence: Int64
                let lastExaminedSequence: Int64
                if let cursor {
                    guard cursor.vaultID == vault.vaultID else {
                        throw PlanningStorageError.invalid("publicationRecovery.vault")
                    }
                    maximumSequence = cursor.maximumSequence
                    lastExaminedSequence = cursor.lastExaminedSequence
                } else {
                    maximumSequence = Int64(try scalarInt(
                        "SELECT COALESCE(MAX(sequence), 0) FROM mutations"
                    ))
                    lastExaminedSequence = 0
                }
                guard maximumSequence >= 0,
                      lastExaminedSequence >= 0,
                      lastExaminedSequence <= maximumSequence else {
                    throw PlanningStorageError.invalid("publicationRecovery.cursor")
                }

                let startedAt = monotonicNow()
                var examined = lastExaminedSequence
                var materializedBytes = 0
                var entries: [PlanningPublicationRecoveryEntry] = []
                var blockedByPayloadBudget = false
                var stoppedByDeadline = false
                do {
                    try query(
                        """
                        SELECT sequence, mutation_id, state
                        FROM mutations
                        WHERE sequence > ? AND sequence <= ?
                          AND state IN ('staged', 'prepared', 'stageReady', 'publishing', 'conflicted')
                        ORDER BY sequence ASC
                        LIMIT ?
                        """,
                        binds: [
                            .int64(lastExaminedSequence),
                            .int64(maximumSequence),
                            .int(PlanningStorageLimits.recoveryBatch)
                        ]
                    ) { statement in
                        if monotonicNow() - startedAt >= PlanningStorageLimits.recoveryBudgetNanoseconds {
                            throw RecoveryPageStop.deadline
                        }
                        guard let sequence = columnInt64(statement, 0),
                              let mutationText = try columnText(statement, 1),
                              let mutationID = UUID(uuidString: mutationText),
                              let stateText = try columnText(statement, 2),
                              let state = PlanningMutationState(rawValue: stateText) else {
                            throw PlanningStorageError.corruptDatabase
                        }
                        guard let byteCount = try proposedPayloadByteCount(for: mutationID) else {
                            throw PlanningStorageError.corruptDatabase
                        }
                        guard byteCount <= PlanningStorageLimits.recoveryPayloadBytes,
                              materializedBytes + byteCount <= PlanningStorageLimits.recoveryPayloadBytes else {
                            throw RecoveryPageStop.payloadBudget
                        }
                        guard let stored = try mutationLocked(for: mutationID) else {
                            throw PlanningStorageError.corruptDatabase
                        }
                        materializedBytes += stored.request.proposedBytes?.count ?? 0
                        let attemptID = try latestAttemptID(for: mutationID)
                        let attempt = try attemptID.flatMap { try publicationAttemptLocked(for: $0)?.snapshot }
                        entries.append(PlanningPublicationRecoveryEntry(
                            recovery: PlanningRecoveryEntry(
                                mutationID: mutationID,
                                state: state,
                                request: stored.request,
                                attemptID: attemptID
                            ),
                            attempt: attempt,
                            sequence: sequence
                        ))
                        examined = sequence
                    }
                } catch RecoveryPageStop.deadline {
                    stoppedByDeadline = true
                } catch RecoveryPageStop.payloadBudget {
                    blockedByPayloadBudget = true
                }

                if !stoppedByDeadline && !blockedByPayloadBudget {
                    let remaining = try scalarInt(
                        """
                        SELECT COUNT(*) FROM mutations
                        WHERE sequence > ? AND sequence <= ?
                          AND state IN ('staged', 'prepared', 'stageReady', 'publishing', 'conflicted')
                        """,
                        binds: [.int64(examined), .int64(maximumSequence)]
                    )
                    if remaining == 0 {
                        examined = maximumSequence
                    }
                }
                let nextCursor = try PlanningPublicationRecoveryCursor(
                    vaultID: vault.vaultID,
                    maximumSequence: maximumSequence,
                    lastExaminedSequence: examined
                )
                let endOfPass = !stoppedByDeadline
                    && !blockedByPayloadBudget
                    && examined >= maximumSequence
                return try PlanningPublicationRecoveryPage(
                    entries: entries,
                    nextCursor: nextCursor,
                    endOfPass: endOfPass
                )
            }
        }
    }

    private func proposedPayloadByteCount(for mutationID: UUID) throws -> Int? {
        var digest: String?
        var found = false
        try query(
            "SELECT proposed_digest FROM mutations WHERE mutation_id = ?",
            binds: [.text(mutationID.uuidString.lowercased())]
        ) { statement in
            found = true
            digest = try columnText(statement, 0)
        }
        guard found else { return nil }
        guard let digest else { return 0 }
        guard planningDigestIsValid(digest) else { throw PlanningStorageError.corruptDatabase }
        var count: Int?
        try query(
            "SELECT byte_count, bytes FROM payloads WHERE digest = ?",
            binds: [.text(digest)]
        ) { statement in
            guard sqlite3_column_type(statement, 0) == SQLITE_INTEGER,
                  sqlite3_column_type(statement, 1) == SQLITE_BLOB,
                  let value = columnInt64(statement, 0),
                  value >= 0,
                  value <= Int64(PlanningStorageLimits.canvasBytes),
                  value <= Int64(Int.max),
                  Int64(sqlite3_column_bytes(statement, 1)) == value else {
                throw PlanningStorageError.corruptDatabase
            }
            count = Int(value)
        }
        guard let count else { throw PlanningStorageError.corruptDatabase }
        return count
    }

    @discardableResult
    public func compactUnreferencedPayloads() throws -> Int {
        try withOperation {
            try withOpen {
                try transaction {
                    var candidates: [String] = []
                    try query(
                        """
                        SELECT digest FROM payloads
                        WHERE NOT EXISTS (
                            SELECT 1 FROM mutations
                            WHERE mutations.proposed_digest = payloads.digest
                        )
                        AND NOT EXISTS (
                            SELECT 1 FROM conflicts
                            WHERE conflicts.local_digest = payloads.digest
                               OR conflicts.observed_digest = payloads.digest
                        )
                        LIMIT 128
                        """
                    ) { statement in
                        guard let digest = try columnText(statement, 0),
                              planningDigestIsValid(digest) else {
                            throw PlanningStorageError.corruptDatabase
                        }
                        candidates.append(digest)
                    }
                    for digest in candidates {
                        try execute(
                            "DELETE FROM payloads WHERE digest = ?",
                            binds: [.text(digest)]
                        )
                    }
                    try enforceDatabaseBound()
                    return candidates.count
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

    #if DEBUG
    internal func debugSetMaximumPageCountForTests(_ maximumPages: Int) throws {
        try withOperation {
            try withOpen {
                guard maximumPages > 0 else {
                    throw PlanningStorageError.invalid("sqlitePageLimit")
                }
                guard try pragmaInteger("max_page_count = \(maximumPages)") == maximumPages else {
                    throw PlanningStorageError.unavailable("sqlitePageLimit")
                }
            }
        }
    }
    #endif

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

    private struct StoredPublicationAttempt {
        let snapshot: PlanningPublicationAttemptSnapshot
    }

    private enum BindValue {
        case text(String)
        case optionalText(String?)
        case blob(Data)
        case optionalBlob(Data?)
        case int(Int)
        case int64(Int64)
        case double(Double)
        case optionalDouble(Double?)
        case null
    }

    private enum RecoveryPageStop: Error {
        case deadline
        case payloadBudget
    }

    private func withOperation<T>(_ body: () throws -> T) rethrows -> T {
        operationLock.lock()
        defer { operationLock.unlock() }
        return try body()
    }

    private func currentDate() -> Date {
        clock()
    }

    private func monotonicNow() -> UInt64 {
        monotonicClock()
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

    private func preflightExistingDatabaseHeader() throws -> Int {
        let handle = try FileHandle(forReadingFrom: databaseURL)
        defer { try? handle.close() }
        guard let header = try handle.read(upToCount: 100),
              header.count >= 64,
              header.prefix(16) == Data("SQLite format 3\0".utf8) else {
            throw PlanningStorageError.corruptDatabase
        }
        guard header[18] == 1, header[19] == 1 else {
            let rawVersion = Int(header[60]) << 24
                | Int(header[61]) << 16
                | Int(header[62]) << 8
                | Int(header[63])
            if rawVersion > PlanningPublicationLimits.schemaVersion {
                throw PlanningStorageError.unsupportedSchema(rawVersion)
            }
            throw PlanningStorageError.corruptDatabase
        }
        let userVersion = Int(header[60]) << 24
            | Int(header[61]) << 16
            | Int(header[62]) << 8
            | Int(header[63])
        guard userVersion == 1 || userVersion == PlanningPublicationLimits.schemaVersion else {
            throw userVersion == 0
                ? PlanningStorageError.corruptDatabase
                : PlanningStorageError.unsupportedSchema(userVersion)
        }
        return userVersion
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
        let pageSize = try pragmaInteger("page_size")
        guard pageSize > 0 else { throw PlanningStorageError.unavailable("sqlitePageSize") }
        let maximumPages = PlanningStorageLimits.databaseBytes / pageSize
        guard maximumPages > 0,
              try pragmaInteger("max_page_count = \(maximumPages)") == maximumPages else {
            throw PlanningStorageError.unavailable("sqlitePageLimit")
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
                """
                CREATE TABLE publication_details(
                    attempt_id TEXT NOT NULL PRIMARY KEY REFERENCES publication_attempts(attempt_id),
                    mutation_id TEXT NOT NULL REFERENCES mutations(mutation_id),
                    ordinal INTEGER NOT NULL,
                    context_json BLOB,
                    outcome_json BLOB,
                    retry_after REAL,
                    legacy_unverified INTEGER NOT NULL,
                    UNIQUE(mutation_id, ordinal)
                )
                """,
                """
                CREATE TABLE conflict_resolutions(
                    conflict_id TEXT NOT NULL PRIMARY KEY REFERENCES conflicts(conflict_id),
                    decision_fingerprint TEXT NOT NULL,
                    decision_json BLOB NOT NULL,
                    child_mutation_id TEXT UNIQUE REFERENCES mutations(mutation_id)
                )
                """,
                """
                CREATE TABLE legacy_conflict_inspections(
                    conflict_id TEXT NOT NULL PRIMARY KEY REFERENCES conflicts(conflict_id),
                    source_schema_version INTEGER NOT NULL,
                    reason TEXT NOT NULL
                )
                """,
                "CREATE INDEX mutations_nonterminal ON mutations(state, sequence)",
                "CREATE INDEX mutations_fingerprint ON mutations(fingerprint)",
                "CREATE INDEX attempts_mutation ON publication_attempts(mutation_id, updated_at)",
                "CREATE INDEX conflicts_state ON conflicts(state, created_at)",
                "CREATE INDEX mutation_reservations_mutation ON mutation_reservations(mutation_id)",
                "CREATE INDEX publication_details_mutation ON publication_details(mutation_id, ordinal)",
                "CREATE INDEX conflict_resolutions_child ON conflict_resolutions(child_mutation_id)"
            ]
            for statement in statements {
                try execute(statement)
            }
            try consumeRows("PRAGMA user_version = \(PlanningPublicationLimits.schemaVersion)")
            guard try pragmaInteger("user_version") == PlanningPublicationLimits.schemaVersion else {
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
                    .double(currentDate().timeIntervalSince1970)
                ]
            )
            try verifySchema(version: PlanningPublicationLimits.schemaVersion)
            try validateVaultRow()
            try validateDurableRecords()
            try execute("COMMIT")
        } catch {
            _ = try? execute("ROLLBACK")
            throw error
        }
    }

    private func migrateV1ToV2() throws {
        try execute("BEGIN EXCLUSIVE")
        do {
            let statements = [
                """
                CREATE TABLE publication_details(
                    attempt_id TEXT NOT NULL PRIMARY KEY REFERENCES publication_attempts(attempt_id),
                    mutation_id TEXT NOT NULL REFERENCES mutations(mutation_id),
                    ordinal INTEGER NOT NULL,
                    context_json BLOB,
                    outcome_json BLOB,
                    retry_after REAL,
                    legacy_unverified INTEGER NOT NULL,
                    UNIQUE(mutation_id, ordinal)
                )
                """,
                """
                CREATE TABLE conflict_resolutions(
                    conflict_id TEXT NOT NULL PRIMARY KEY REFERENCES conflicts(conflict_id),
                    decision_fingerprint TEXT NOT NULL,
                    decision_json BLOB NOT NULL,
                    child_mutation_id TEXT UNIQUE REFERENCES mutations(mutation_id)
                )
                """,
                """
                CREATE TABLE legacy_conflict_inspections(
                    conflict_id TEXT NOT NULL PRIMARY KEY REFERENCES conflicts(conflict_id),
                    source_schema_version INTEGER NOT NULL,
                    reason TEXT NOT NULL
                )
                """,
                "CREATE INDEX publication_details_mutation ON publication_details(mutation_id, ordinal)",
                "CREATE INDEX conflict_resolutions_child ON conflict_resolutions(child_mutation_id)"
            ]
            for statement in statements {
                try execute(statement)
            }

            var attempts: [(UUID, UUID, String?, String?, Double)] = []
            try query(
                """
                SELECT attempt_id, mutation_id, witness_name, staged_identity, created_at
                FROM publication_attempts
                ORDER BY created_at ASC, attempt_id ASC
                """
            ) { statement in
                guard let attemptText = try columnText(statement, 0),
                      let attemptID = UUID(uuidString: attemptText),
                      let mutationText = try columnText(statement, 1),
                      let mutationID = UUID(uuidString: mutationText),
                      let createdAt = columnDouble(statement, 4),
                      createdAt.isFinite else {
                    throw PlanningStorageError.corruptDatabase
                }
                if let witness = try columnText(statement, 2) {
                    try planningPublicationValidateString(
                        witness,
                        maximumBytes: PlanningPublicationLimits.maximumWitnessBytes,
                        field: "publicationAttempt.witnessName",
                        allowEmpty: false
                    )
                }
                if let stagedIdentity = try columnText(statement, 3) {
                    _ = try PlanningFileIdentity(storageToken: stagedIdentity)
                }
                guard try scalarInt(
                    "SELECT COUNT(*) FROM mutations WHERE mutation_id = ?",
                    binds: [.text(mutationID.uuidString.lowercased())]
                ) == 1 else {
                    throw PlanningStorageError.corruptDatabase
                }
                attempts.append((
                    attemptID,
                    mutationID,
                    try columnText(statement, 2),
                    try columnText(statement, 3),
                    createdAt
                ))
            }

            var ordinals: [UUID: Int] = [:]
            for (attemptID, mutationID, witness, identity, _) in attempts {
                let ordinal = (ordinals[mutationID] ?? 0) + 1
                guard ordinal <= PlanningPublicationLimits.maximumAttemptsPerMutation else {
                    throw PlanningStorageError.backpressure("publicationAttempts")
                }
                ordinals[mutationID] = ordinal
                try execute(
                    """
                    INSERT INTO publication_details(
                        attempt_id, mutation_id, ordinal, context_json, outcome_json,
                        retry_after, legacy_unverified
                    ) VALUES (?, ?, ?, NULL, NULL, NULL, 1)
                    """,
                    binds: [
                        .text(attemptID.uuidString.lowercased()),
                        .text(mutationID.uuidString.lowercased()),
                        .int(ordinal)
                    ]
                )
                _ = witness
                _ = identity
            }

            try query(
                "SELECT conflict_id, mutation_id FROM conflicts WHERE state = 'resolved'"
            ) { statement in
                guard let conflictText = try columnText(statement, 0),
                      let conflictID = UUID(uuidString: conflictText),
                      let mutationText = try columnText(statement, 1),
                      let mutationID = UUID(uuidString: mutationText),
                      let mutation = try mutationLocked(for: mutationID),
                      mutation.state == .resolved,
                      let inspection = try? PlanningLegacyConflictInspection(conflictID: conflictID),
                      inspection.conflictID == conflictID else {
                    throw PlanningStorageError.corruptDatabase
                }
                try execute(
                    """
                    INSERT INTO legacy_conflict_inspections(
                        conflict_id, source_schema_version, reason
                    ) VALUES (?, ?, ?)
                    """,
                    binds: [
                        .text(inspection.conflictID.uuidString.lowercased()),
                        .int(inspection.sourceSchemaVersion),
                        .text(inspection.reason)
                    ]
                )
            }

            try verifySchema(version: PlanningPublicationLimits.schemaVersion)
            try execute("PRAGMA user_version = \(PlanningPublicationLimits.schemaVersion)")
            guard try pragmaInteger("user_version") == PlanningPublicationLimits.schemaVersion else {
                throw PlanningStorageError.corruptDatabase
            }
            try validateDurableRecords()
            try execute("COMMIT")
        } catch {
            _ = try? execute("ROLLBACK")
            throw error
        }
    }

    private func verifySchema(version: Int) throws {
        guard version == 1 || version == PlanningPublicationLimits.schemaVersion else {
            throw PlanningStorageError.unsupportedSchema(version)
        }
        var expectedTables: Set<String> = [
            "vault", "documents", "mutations", "publication_attempts",
            "conflicts", "payloads", "receipts", "mutation_reservations"
        ]
        if version == PlanningPublicationLimits.schemaVersion {
            expectedTables.formUnion([
                "publication_details",
                "conflict_resolutions",
                "legacy_conflict_inspections"
            ])
        }
        var actualTables = Set<String>()
        try query(
            "SELECT name FROM sqlite_master WHERE type = 'table' AND name NOT LIKE 'sqlite_%'"
        ) { statement in
            if let name = try columnText(statement, 0) { actualTables.insert(name) }
        }
        guard actualTables == expectedTables else {
            throw PlanningStorageError.corruptDatabase
        }

        var expectedColumns: [(String, [String: PlanningSchemaColumn])] = [
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
        if version == PlanningPublicationLimits.schemaVersion {
            expectedColumns.append(("publication_details", [
                "attempt_id": PlanningSchemaColumn(type: "TEXT", notNull: 1, primaryKey: 1),
                "mutation_id": PlanningSchemaColumn(type: "TEXT", notNull: 1, primaryKey: 0),
                "ordinal": PlanningSchemaColumn(type: "INTEGER", notNull: 1, primaryKey: 0),
                "context_json": PlanningSchemaColumn(type: "BLOB", notNull: 0, primaryKey: 0),
                "outcome_json": PlanningSchemaColumn(type: "BLOB", notNull: 0, primaryKey: 0),
                "retry_after": PlanningSchemaColumn(type: "REAL", notNull: 0, primaryKey: 0),
                "legacy_unverified": PlanningSchemaColumn(type: "INTEGER", notNull: 1, primaryKey: 0)
            ]))
            expectedColumns.append(("conflict_resolutions", [
                "conflict_id": PlanningSchemaColumn(type: "TEXT", notNull: 1, primaryKey: 1),
                "decision_fingerprint": PlanningSchemaColumn(type: "TEXT", notNull: 1, primaryKey: 0),
                "decision_json": PlanningSchemaColumn(type: "BLOB", notNull: 1, primaryKey: 0),
                "child_mutation_id": PlanningSchemaColumn(type: "TEXT", notNull: 0, primaryKey: 0)
            ]))
            expectedColumns.append(("legacy_conflict_inspections", [
                "conflict_id": PlanningSchemaColumn(type: "TEXT", notNull: 1, primaryKey: 1),
                "source_schema_version": PlanningSchemaColumn(type: "INTEGER", notNull: 1, primaryKey: 0),
                "reason": PlanningSchemaColumn(type: "TEXT", notNull: 1, primaryKey: 0)
            ]))
        }
        for (table, expected) in expectedColumns {
            guard try schemaColumns(for: table) == expected else {
                throw PlanningStorageError.corruptDatabase
            }
        }

        var uniqueConstraints: [(String, [String])] = [
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
        if version == PlanningPublicationLimits.schemaVersion {
            uniqueConstraints.append(("publication_details", ["attempt_id"]))
            uniqueConstraints.append(("publication_details", ["mutation_id", "ordinal"]))
            uniqueConstraints.append(("conflict_resolutions", ["conflict_id"]))
            uniqueConstraints.append(("conflict_resolutions", ["child_mutation_id"]))
            uniqueConstraints.append(("legacy_conflict_inspections", ["conflict_id"]))
        }
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

        var requiredIndexes: [(String, String, [String])] = [
            ("mutations", "mutations_nonterminal", ["state", "sequence"]),
            ("mutations", "mutations_fingerprint", ["fingerprint"]),
            ("publication_attempts", "attempts_mutation", ["mutation_id", "updated_at"]),
            ("conflicts", "conflicts_state", ["state", "created_at"]),
            ("mutation_reservations", "mutation_reservations_mutation", ["mutation_id"])
        ]
        if version == PlanningPublicationLimits.schemaVersion {
            requiredIndexes.append(("publication_details", "publication_details_mutation", ["mutation_id", "ordinal"]))
            requiredIndexes.append(("conflict_resolutions", "conflict_resolutions_child", ["child_mutation_id"]))
        }
        for (table, name, columns) in requiredIndexes {
            guard indexesByTable[table]?.contains(where: {
                $0.name == name && !$0.unique && !$0.partial && $0.columns == columns
            }) == true else {
                throw PlanningStorageError.corruptDatabase
            }
        }

        var expectedForeignKeys: [(String, [PlanningSchemaForeignKey])] = [
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
        if version == PlanningPublicationLimits.schemaVersion {
            expectedForeignKeys.append(("publication_details", [
                PlanningSchemaForeignKey(
                    id: 0,
                    sequence: 0,
                    table: "mutations",
                    from: "mutation_id",
                    to: "mutation_id",
                    onUpdate: "NO ACTION",
                    onDelete: "NO ACTION",
                    match: "NONE"
                ),
                PlanningSchemaForeignKey(
                    id: 1,
                    sequence: 0,
                    table: "publication_attempts",
                    from: "attempt_id",
                    to: "attempt_id",
                    onUpdate: "NO ACTION",
                    onDelete: "NO ACTION",
                    match: "NONE"
                )
            ]))
            expectedForeignKeys.append(("conflict_resolutions", [
                PlanningSchemaForeignKey(
                    id: 0,
                    sequence: 0,
                    table: "mutations",
                    from: "child_mutation_id",
                    to: "mutation_id",
                    onUpdate: "NO ACTION",
                    onDelete: "NO ACTION",
                    match: "NONE"
                ),
                PlanningSchemaForeignKey(
                    id: 1,
                    sequence: 0,
                    table: "conflicts",
                    from: "conflict_id",
                    to: "conflict_id",
                    onUpdate: "NO ACTION",
                    onDelete: "NO ACTION",
                    match: "NONE"
                )
            ]))
            expectedForeignKeys.append(("legacy_conflict_inspections", [
                PlanningSchemaForeignKey(
                    id: 0,
                    sequence: 0,
                    table: "conflicts",
                    from: "conflict_id",
                    to: "conflict_id",
                    onUpdate: "NO ACTION",
                    onDelete: "NO ACTION",
                    match: "NONE"
                )
            ]))
        }
        for (table, expected) in expectedForeignKeys {
            let actual = try schemaForeignKeys(for: table).map { key in
                (key.table, key.from, key.to, key.onUpdate, key.onDelete, key.match)
            }.sorted { lhs, rhs in
                String(describing: lhs) < String(describing: rhs)
            }
            let wanted = expected.map { key in
                (key.table, key.from, key.to, key.onUpdate, key.onDelete, key.match)
            }.sorted { lhs, rhs in
                String(describing: lhs) < String(describing: rhs)
            }
            guard actual.count == wanted.count,
                  actual.elementsEqual(wanted, by: { lhs, rhs in
                      lhs.0 == rhs.0
                          && lhs.1 == rhs.1
                          && lhs.2 == rhs.2
                          && lhs.3 == rhs.3
                          && lhs.4 == rhs.4
                          && lhs.5 == rhs.5
                  }) else {
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
        guard try scalarInt("SELECT COUNT(*) FROM mutations") <= PlanningPublicationLimits.maximumRetainedMutations else {
            throw PlanningStorageError.backpressure("retainedMutations")
        }
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

        if try pragmaInteger("user_version") == PlanningPublicationLimits.schemaVersion {
            try validatePublicationRecords()
            try validateResolutionRecords()
        }
    }

    private func validatePublicationRecords() throws {
        let attemptCount = try scalarInt("SELECT COUNT(*) FROM publication_attempts")
        let detailCount = try scalarInt("SELECT COUNT(*) FROM publication_details")
        guard attemptCount == detailCount else {
            throw PlanningStorageError.corruptDatabase
        }

        // A mutation that has entered the publication protocol must retain at
        // least one attempt/detail pair. Direct conflict admission is
        // intentionally different: a staged mutation may be marked conflicted
        // without a publication attempt, and its conflict record is the durable
        // evidence for that path. Legacy rows are inspection-only migration
        // evidence; they satisfy this reverse relationship check but are
        // skipped by the live phase checks below.
        try query(
            """
            SELECT m.mutation_id
            FROM mutations AS m
            WHERE m.state IN ('prepared', 'stageReady', 'publishing', 'published', 'failed')
              AND NOT EXISTS (
                  SELECT 1
                  FROM publication_attempts AS a
                  JOIN publication_details AS d ON d.attempt_id = a.attempt_id
                  WHERE a.mutation_id = m.mutation_id
              )
            """
        ) { _ in
            throw PlanningStorageError.corruptDatabase
        }

        // Conflict state is durable evidence in its own right. This reverse
        // check covers direct conflict admission, which has no publication
        // attempt, as well as attempts that later became conflicted or
        // resolved. A mutation must have exactly one conflict in the matching
        // state, and a conflict may not outlive that mutation state.
        try query(
            """
            SELECT m.mutation_id
            FROM mutations AS m
            LEFT JOIN conflicts AS c ON c.mutation_id = m.mutation_id
            WHERE m.state IN ('conflicted', 'resolved')
            GROUP BY m.mutation_id, m.state
            HAVING (m.state = 'conflicted'
                    AND SUM(CASE WHEN c.state = 'open' THEN 1 ELSE 0 END) != 1)
                OR (m.state = 'resolved'
                    AND SUM(CASE WHEN c.state = 'resolved' THEN 1 ELSE 0 END) < 1)
            """
        ) { _ in
            throw PlanningStorageError.corruptDatabase
        }
        try query(
            """
            SELECT c.conflict_id
            FROM conflicts AS c
            JOIN mutations AS m ON m.mutation_id = c.mutation_id
            WHERE (c.state = 'open' AND m.state <> 'conflicted')
            """
        ) { _ in
            throw PlanningStorageError.corruptDatabase
        }

        var activeByMutation: [UUID: Int] = [:]
        try query(
            "SELECT attempt_id FROM publication_attempts ORDER BY mutation_id, updated_at, attempt_id"
        ) { statement in
            guard let text = try columnText(statement, 0),
                  let attemptID = UUID(uuidString: text),
                  let stored = try publicationAttemptLocked(for: attemptID),
                  let mutation = try mutationLocked(for: stored.snapshot.mutationID) else {
                throw PlanningStorageError.corruptDatabase
            }
            let snapshot = stored.snapshot
            let isActive: Bool
            switch snapshot.phase {
            case .prepared, .stageReady, .publishing:
                isActive = true
            case .published, .conflicted, .failed:
                isActive = false
            }
            if isActive && !snapshot.legacyUnverified {
                activeByMutation[snapshot.mutationID, default: 0] += 1
                guard activeByMutation[snapshot.mutationID, default: 0] <= 1 else {
                    throw PlanningStorageError.corruptDatabase
                }
            }
            let currentAttemptID = try latestAttemptID(for: snapshot.mutationID)
            let isCurrentAttempt = currentAttemptID == attemptID

            if let context = snapshot.context {
                guard context.observedVersion == mutation.request.expectedVersion else {
                    throw PlanningStorageError.corruptDatabase
                }
                try planningValidateContentVersion(
                    context.observedVersion,
                    maximumByteCount: mutation.request.path.isCanvas
                        ? PlanningStorageLimits.canvasBytes
                        : PlanningStorageLimits.markdownBytes,
                    field: "publicationContext.observedVersion"
                )
            }
            if !snapshot.legacyUnverified {
                if let witness = snapshot.witnessName {
                    guard witness == expectedWitnessName(snapshot.attemptID) else {
                        throw PlanningStorageError.corruptDatabase
                    }
                }
                switch snapshot.phase {
                case .prepared:
                    guard isCurrentAttempt, mutation.state == .prepared else {
                        throw PlanningStorageError.corruptDatabase
                    }
                    guard snapshot.witnessName == nil, snapshot.stagedIdentity == nil else {
                        throw PlanningStorageError.corruptDatabase
                    }
                case .stageReady:
                    guard isCurrentAttempt,
                          mutation.state == .stageReady,
                          snapshot.witnessName != nil,
                          snapshot.stagedIdentity != nil,
                          snapshot.outcome == nil else {
                        throw PlanningStorageError.corruptDatabase
                    }
                case .publishing:
                    guard isCurrentAttempt,
                          mutation.state == .publishing,
                          snapshot.context != nil,
                          snapshot.witnessName != nil,
                          snapshot.outcome == nil else {
                        throw PlanningStorageError.corruptDatabase
                    }
                    if mutation.request.operation != .delete {
                        guard snapshot.stagedIdentity != nil else {
                            throw PlanningStorageError.corruptDatabase
                        }
                    }
                case .published:
                    guard isCurrentAttempt,
                          mutation.state == .published,
                          snapshot.context != nil,
                          snapshot.witnessName != nil,
                          case .published(let resultVersion)? = snapshot.outcome,
                          resultVersion == expectedPublicationResultVersion(for: mutation.request) else {
                        throw PlanningStorageError.corruptDatabase
                    }
                    if mutation.request.operation != .delete {
                        guard snapshot.stagedIdentity != nil else {
                            throw PlanningStorageError.corruptDatabase
                        }
                    }
                case .conflicted:
                    let hasInPlaceContinuation = try hasInPlaceResolutionContinuationLocked(
                        for: snapshot.mutationID
                    )
                    guard mutation.state == .conflicted
                        || mutation.state == .resolved
                        || hasInPlaceContinuation,
                          case .conflicted? = snapshot.outcome else {
                        throw PlanningStorageError.corruptDatabase
                    }
                case .failed:
                    guard case .failed(_, let retryable)? = snapshot.outcome else {
                        throw PlanningStorageError.corruptDatabase
                    }
                    if retryable {
                        if isCurrentAttempt {
                            switch mutation.state {
                            case .prepared:
                                break
                            case .staged:
                                // A retryable failed attempt normally leaves
                                // the mutation prepared. The only valid path
                                // back to staged is an already-committed,
                                // lineage-checked in-place continuation.
                                guard try hasInPlaceResolutionContinuationLocked(
                                    for: snapshot.mutationID
                                ) else {
                                    throw PlanningStorageError.corruptDatabase
                                }
                            case .conflicted:
                                guard try scalarInt(
                                    "SELECT COUNT(*) FROM conflicts WHERE mutation_id = ? AND state = 'open'",
                                    binds: [.text(snapshot.mutationID.uuidString.lowercased())]
                                ) == 1 else {
                                    throw PlanningStorageError.corruptDatabase
                                }
                            case .resolved:
                                guard try resolutionLineageCountsLocked(
                                    for: snapshot.mutationID
                                ).terminal == 1 else {
                                    throw PlanningStorageError.corruptDatabase
                                }
                            default:
                                throw PlanningStorageError.corruptDatabase
                            }
                        } else {
                            guard currentAttemptID != nil, currentAttemptID != attemptID else {
                                throw PlanningStorageError.corruptDatabase
                            }
                        }
                    } else {
                        guard isCurrentAttempt, mutation.state == .failed else {
                            throw PlanningStorageError.corruptDatabase
                        }
                    }
                }
            }
            if case .published(let resultVersion)? = snapshot.outcome {
                try planningValidateContentVersion(
                    resultVersion,
                    maximumByteCount: mutation.request.path.isCanvas
                        ? PlanningStorageLimits.canvasBytes
                        : PlanningStorageLimits.markdownBytes,
                    field: "publication.resultVersion"
                )
                guard resultVersion == expectedPublicationResultVersion(for: mutation.request) else {
                    throw PlanningStorageError.corruptDatabase
                }
            }
            if case .failed(_, let retryable)? = snapshot.outcome {
                if retryable {
                    guard snapshot.retryAfter != nil else { throw PlanningStorageError.corruptDatabase }
                } else {
                    guard snapshot.retryAfter == nil else { throw PlanningStorageError.corruptDatabase }
                }
            }
        }
    }

    private enum ResolutionLineage {
        case terminal
        case continuation
    }

    private func validateResolutionLineageLocked(
        record: PlanningDurableResolutionRecord,
        stored: StoredConflict,
        childText: String?
    ) throws -> ResolutionLineage {
        guard let parent = try mutationLocked(for: stored.conflict.mutationID) else {
            throw PlanningStorageError.corruptDatabase
        }
        let evidence = try PlanningConflictEvidence(
            validating: stored.conflict,
            attemptedPublication: stored.attemptedPublication,
            displacedVersion: stored.displacedVersion
        )
        let decision = try PlanningConflictResolver.resolve(
            evidence: evidence,
            resolution: record.resolution
        )
        switch decision {
        case .keepObserved:
            guard record.childMutationID == nil,
                  record.continuationMutationID == nil,
                  childText == nil else {
                throw PlanningStorageError.corruptDatabase
            }
            return .terminal
        case .keepBoth(_, let bytes):
            guard record.continuationMutationID == nil,
                  let childID = record.childMutationID,
                  childText == childID.uuidString.lowercased(),
                  let child = try mutationLocked(for: childID),
                  child.state != .cancelled,
                  child.request == (try makeKeepBothRequest(
                      conflict: stored.conflict,
                      bytes: bytes,
                      mutationID: childID
                  )) else {
                throw PlanningStorageError.corruptDatabase
            }
            return .terminal
        case .applyLocal(let expectedRequest), .applyMerged(let expectedRequest):
            if let continuationID = record.continuationMutationID {
                guard record.childMutationID == nil,
                      childText == nil,
                      continuationID == stored.conflict.mutationID,
                      canContinueResolutionInPlace(
                          expectedRequest,
                          parent: parent,
                          conflict: stored.conflict
                      ) else {
                    throw PlanningStorageError.corruptDatabase
                }
                return .continuation
            }
            guard let childID = record.childMutationID,
                  childText == childID.uuidString.lowercased() else {
                throw PlanningStorageError.corruptDatabase
            }
            if childID == stored.conflict.mutationID {
                // Accept the earlier Packet B encoding for the one
                // self-continuation it could represent. New writes use the
                // explicit continuation marker with a NULL child column.
                guard canContinueResolutionInPlace(
                    expectedRequest,
                    parent: parent,
                    conflict: stored.conflict
                ) else {
                    throw PlanningStorageError.corruptDatabase
                }
                return .continuation
            }
            guard let child = try mutationLocked(for: childID),
                  child.state != .cancelled,
                  child.request == (try PlanningMutationRequest(
                      mutationID: childID,
                      vaultID: expectedRequest.vaultID,
                      path: expectedRequest.path,
                      operation: expectedRequest.operation,
                      expectedVersion: expectedRequest.expectedVersion,
                      proposedBytes: expectedRequest.proposedBytes
                  )) else {
                throw PlanningStorageError.corruptDatabase
            }
            return .terminal
        }
    }

    private func validateResolutionRecords() throws {
        var terminalByMutation: [UUID: Int] = [:]
        var continuationByMutation: [UUID: Int] = [:]

        try query(
            """
            SELECT c.conflict_id
            FROM conflicts AS c
            LEFT JOIN conflict_resolutions AS r ON r.conflict_id = c.conflict_id
            LEFT JOIN legacy_conflict_inspections AS l ON l.conflict_id = c.conflict_id
            WHERE c.state = 'resolved'
            GROUP BY c.conflict_id
            HAVING NOT (
                COUNT(r.conflict_id) = 1 AND COUNT(l.conflict_id) = 0
                OR COUNT(r.conflict_id) = 0 AND COUNT(l.conflict_id) = 1
            )
            """
        ) { _ in
            throw PlanningStorageError.corruptDatabase
        }

        try query(
            """
            SELECT conflict_id, source_schema_version, reason
            FROM legacy_conflict_inspections
            """
        ) { statement in
            guard let conflictText = try columnText(statement, 0),
                  let conflictID = UUID(uuidString: conflictText),
                  let sourceSchemaVersion = columnInt(statement, 1),
                  let reason = try columnText(statement, 2),
                  let conflict = try conflictLocked(for: conflictID),
                  conflict.conflict.state == .resolved,
                  let mutation = try mutationLocked(for: conflict.conflict.mutationID),
                  mutation.state == .resolved,
                  try scalarInt(
                      "SELECT COUNT(*) FROM conflict_resolutions WHERE conflict_id = ?",
                      binds: [.text(conflictID.uuidString.lowercased())]
                  ) == 0 else {
                throw PlanningStorageError.corruptDatabase
            }
            do {
                _ = try PlanningLegacyConflictInspection(
                    conflictID: conflictID,
                    sourceSchemaVersion: sourceSchemaVersion,
                    reason: reason
                )
            } catch {
                throw PlanningStorageError.corruptDatabase
            }
        }

        try query(
            "SELECT conflict_id, decision_fingerprint, decision_json, child_mutation_id FROM conflict_resolutions"
        ) { statement in
            guard let conflictText = try columnText(statement, 0),
                  let conflictID = UUID(uuidString: conflictText),
                  let fingerprint = try columnText(statement, 1),
                  let decisionJSON = try persistedBlob(
                      statement,
                      2,
                      maximumBytes: PlanningPublicationLimits.maximumResolutionBytes
                  ),
                  let stored = try conflictLocked(for: conflictID),
                  let record = try? planningPublicationDecodeJSON(
                      PlanningDurableResolutionRecord.self,
                      data: decisionJSON,
                      maximumBytes: PlanningPublicationLimits.maximumResolutionBytes,
                      field: "durableResolution"
                  ) else {
                throw PlanningStorageError.corruptDatabase
            }
            guard record.conflictID == conflictID,
                  record.decisionFingerprint == fingerprint,
                  fingerprint == planningPublicationDecisionFingerprint(
                      conflictID: conflictID,
                      resolution: record.resolution
                  ),
                  stored.conflict.state == .resolved else {
                throw PlanningStorageError.corruptDatabase
            }
            try validateConflictResolution(record.resolution, for: stored.conflict)
            let childText = try columnText(statement, 3)
            switch try validateResolutionLineageLocked(
                record: record,
                stored: stored,
                childText: childText
            ) {
            case .terminal:
                terminalByMutation[stored.conflict.mutationID, default: 0] += 1
            case .continuation:
                continuationByMutation[stored.conflict.mutationID, default: 0] += 1
            }
        }

        try query(
            "SELECT mutation_id, state FROM mutations WHERE state IN ('staged', 'prepared', 'stageReady', 'publishing', 'published', 'conflicted', 'resolved', 'failed', 'cancelled')"
        ) { statement in
            guard let mutationText = try columnText(statement, 0),
                  let mutationID = UUID(uuidString: mutationText),
                  let stateText = try columnText(statement, 1),
                  let state = PlanningMutationState(rawValue: stateText) else {
                throw PlanningStorageError.corruptDatabase
            }
            let terminalCount = terminalByMutation[mutationID, default: 0]
            let continuationCount = continuationByMutation[mutationID, default: 0]
            let legacyCount = try scalarInt(
                "SELECT COUNT(*) FROM legacy_conflict_inspections WHERE conflict_id IN (SELECT conflict_id FROM conflicts WHERE mutation_id = ?)",
                binds: [.text(mutationID.uuidString.lowercased())]
            )
            switch state {
            case .resolved:
                guard (terminalCount == 1 && legacyCount == 0)
                    || (terminalCount == 0 && continuationCount == 0 && legacyCount == 1) else {
                    throw PlanningStorageError.corruptDatabase
                }
            case .staged, .prepared, .stageReady, .publishing, .published, .conflicted:
                guard terminalCount == 0, legacyCount == 0 else {
                    throw PlanningStorageError.corruptDatabase
                }
            case .cancelled, .failed:
                guard terminalCount == 0, legacyCount == 0 else {
                    throw PlanningStorageError.corruptDatabase
                }
            }
        }
    }

    private func expectedPublicationResultVersion(
        for request: PlanningMutationRequest
    ) -> PlanningContentVersion {
        guard let proposedBytes = request.proposedBytes else { return .absent }
        return PlanningContentVersion(data: proposedBytes)
    }

    private func expectedWitnessName(_ attemptID: UUID) -> String {
        ".lifeos-stage-\(attemptID.uuidString.lowercased())"
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
        let retained = try scalarInt("SELECT COUNT(*) FROM mutations")
        guard retained < PlanningPublicationLimits.maximumRetainedMutations else {
            throw PlanningStorageError.backpressure("retainedMutations")
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
        let now = currentDate().timeIntervalSince1970
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
            guard let resultVersion = receipt.resultVersion,
                  resultVersion == expectedPublicationResultVersion(for: mutation.request) else {
                throw PlanningStorageError.corruptDatabase
            }
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
                .double(currentDate().timeIntervalSince1970)
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
                .double(currentDate().timeIntervalSince1970),
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
                .double(currentDate().timeIntervalSince1970),
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
            SELECT attempt_id FROM publication_details
            WHERE mutation_id = ? ORDER BY ordinal DESC LIMIT 1
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

    private func publicationAttemptLocked(for attemptID: UUID) throws -> StoredPublicationAttempt? {
        var result: StoredPublicationAttempt?
        var found = false
        try query(
            """
            SELECT a.attempt_id, a.mutation_id, a.phase, a.witness_name,
                   a.staged_identity, d.ordinal, d.context_json, d.outcome_json,
                   d.retry_after, d.legacy_unverified, d.mutation_id
            FROM publication_attempts AS a
            JOIN publication_details AS d ON d.attempt_id = a.attempt_id
            WHERE a.attempt_id = ?
            """,
            binds: [.text(attemptID.uuidString.lowercased())]
        ) { statement in
            try mapPersistedCorruption {
                found = true
                guard let storedAttemptText = try columnText(statement, 0),
                      UUID(uuidString: storedAttemptText) == attemptID,
                      let mutationText = try columnText(statement, 1),
                      let mutationID = UUID(uuidString: mutationText),
                      let phaseText = try columnText(statement, 2),
                      let phase = PlanningPublicationPhase(rawValue: phaseText),
                      let ordinal = columnInt(statement, 5),
                      let legacyValue = columnInt(statement, 9),
                      legacyValue == 0 || legacyValue == 1,
                      let detailMutationText = try columnText(statement, 10),
                      UUID(uuidString: detailMutationText) == mutationID else {
                    throw PlanningStorageError.corruptDatabase
                }
                let witnessName = try columnText(statement, 3)
                if let witnessName {
                    try planningPublicationValidateString(
                        witnessName,
                        maximumBytes: PlanningPublicationLimits.maximumWitnessBytes,
                        field: "publicationAttempt.witnessName",
                        allowEmpty: false
                    )
                }
                let stagedIdentity = try columnText(statement, 4).map(PlanningFileIdentity.init(storageToken:))
                let context = try persistedBlob(
                    statement,
                    6,
                    maximumBytes: PlanningPublicationLimits.maximumContextBytes
                ).map {
                    try planningPublicationDecodeJSON(
                        PlanningPublicationContext.self,
                        data: $0,
                        maximumBytes: PlanningPublicationLimits.maximumContextBytes,
                        field: "publicationContext"
                    )
                }
                let outcome = try persistedBlob(
                    statement,
                    7,
                    maximumBytes: PlanningPublicationLimits.maximumOutcomeBytes
                ).map {
                    try planningPublicationDecodeJSON(
                        PlanningPublicationOutcomeRecord.self,
                        data: $0,
                        maximumBytes: PlanningPublicationLimits.maximumOutcomeBytes,
                        field: "publicationOutcome"
                    )
                }
                let retryAfter: Date?
                if let value = columnDouble(statement, 8) {
                    guard value.isFinite else { throw PlanningStorageError.corruptDatabase }
                    retryAfter = Date(timeIntervalSince1970: value)
                } else {
                    retryAfter = nil
                }
                let snapshot = try PlanningPublicationAttemptSnapshot(
                    attemptID: attemptID,
                    mutationID: mutationID,
                    ordinal: ordinal,
                    phase: phase,
                    context: context,
                    witnessName: witnessName,
                    stagedIdentity: stagedIdentity,
                    outcome: outcome,
                    retryAfter: retryAfter,
                    legacyUnverified: legacyValue == 1
                )
                result = StoredPublicationAttempt(snapshot: snapshot)
            }
        }
        return found ? result : nil
    }

    private func activePublicationAttemptLocked(for mutationID: UUID) throws -> StoredPublicationAttempt? {
        var attemptID: UUID?
        try query(
            """
            SELECT attempt_id FROM publication_attempts
            WHERE mutation_id = ? AND phase IN ('prepared', 'stageReady', 'publishing')
            ORDER BY attempt_id LIMIT 2
            """,
            binds: [.text(mutationID.uuidString.lowercased())]
        ) { statement in
            guard let text = try columnText(statement, 0), let id = UUID(uuidString: text) else {
                throw PlanningStorageError.corruptDatabase
            }
            guard attemptID == nil else { throw PlanningStorageError.corruptDatabase }
            attemptID = id
        }
        guard let attemptID else { return nil }
        return try publicationAttemptLocked(for: attemptID)
    }

    private func persistedBlob(
        _ statement: OpaquePointer,
        _ index: Int32,
        maximumBytes: Int? = nil
    ) throws -> Data? {
        let type = sqlite3_column_type(statement, index)
        if type == SQLITE_NULL { return nil }
        guard type == SQLITE_BLOB else { throw PlanningStorageError.corruptDatabase }
        let count = Int(sqlite3_column_bytes(statement, index))
        guard count >= 0,
              maximumBytes.map({ count <= $0 }) ?? true else {
            throw PlanningStorageError.corruptDatabase
        }
        if count == 0 {
            guard sqlite3_column_blob(statement, index) != nil else {
                throw PlanningStorageError.corruptDatabase
            }
            return Data()
        }
        guard let pointer = sqlite3_column_blob(statement, index) else {
            throw PlanningStorageError.corruptDatabase
        }
        return Data(bytes: pointer, count: count)
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
                  mutation.request.operation == operation,
                  mutation.request.expectedVersion == (try planningVersionFromToken(baseText)) else {
                throw PlanningStorageError.corruptDatabase
            }
            let localBytes = try columnText(statement, 7).flatMap { try payloadLocked(digest: $0) }
            let observedBytes = try columnText(statement, 9).flatMap { try payloadLocked(digest: $0) }
            guard mutation.request.proposedBytes == localBytes else {
                throw PlanningStorageError.corruptDatabase
            }
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

    private func conflictEvidenceMatches(
        _ lhs: PlanningConflict,
        _ rhs: PlanningConflict
    ) -> Bool {
        lhs.conflictID == rhs.conflictID
            && lhs.mutationID == rhs.mutationID
            && lhs.vaultID == rhs.vaultID
            && lhs.path == rhs.path
            && lhs.operation == rhs.operation
            && lhs.reason == rhs.reason
            && lhs.baseVersion == rhs.baseVersion
            && lhs.localBytes == rhs.localBytes
            && lhs.observedVersion == rhs.observedVersion
            && lhs.observedBytes == rhs.observedBytes
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

    private func canContinueResolutionInPlace(
        _ request: PlanningMutationRequest,
        parent: StoredMutation,
        conflict: PlanningConflict
    ) -> Bool {
        guard conflict.operation == .create,
              conflict.observedVersion == .absent,
              request.vaultID == parent.request.vaultID,
              request.path == parent.request.path,
              request.operation == parent.request.operation,
              request.expectedVersion == parent.request.expectedVersion,
              request.proposedBytes == parent.request.proposedBytes else {
            return false
        }
        return request.fingerprint == parent.fingerprint
    }

    private func resolutionLineageCountsLocked(
        for mutationID: UUID
    ) throws -> (terminal: Int, continuation: Int) {
        var terminal = 0
        var continuation = 0
        try query(
            """
            SELECT c.conflict_id
                , r.child_mutation_id
            FROM conflicts AS c
            JOIN conflict_resolutions AS r ON r.conflict_id = c.conflict_id
            WHERE c.mutation_id = ? AND c.state = 'resolved'
            """,
            binds: [.text(mutationID.uuidString.lowercased())]
        ) { statement in
            guard let conflictText = try columnText(statement, 0),
                  let conflictID = UUID(uuidString: conflictText),
                  let stored = try conflictLocked(for: conflictID),
                  let record = try durableResolutionLocked(for: conflictID) else {
                throw PlanningStorageError.corruptDatabase
            }
            let childText = try columnText(statement, 1)
            switch try validateResolutionLineageLocked(
                record: record,
                stored: stored,
                childText: childText
            ) {
            case .terminal:
                terminal += 1
            case .continuation:
                continuation += 1
            }
        }
        return (terminal: terminal, continuation: continuation)
    }

    private func hasInPlaceResolutionContinuationLocked(for mutationID: UUID) throws -> Bool {
        try resolutionLineageCountsLocked(for: mutationID).continuation > 0
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
            case .optionalDouble(let value):
                guard let value else {
                    code = sqlite3_bind_null(statement, index)
                    break
                }
                guard value.isFinite else {
                    throw PlanningStorageError.invalid("persistedDouble")
                }
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

    private func columnInt64(_ statement: OpaquePointer, _ index: Int32) -> Int64? {
        sqlite3_column_type(statement, index) == SQLITE_NULL ? nil : sqlite3_column_int64(statement, index)
    }

    private func columnDouble(_ statement: OpaquePointer, _ index: Int32) -> Double? {
        sqlite3_column_type(statement, index) == SQLITE_NULL ? nil : sqlite3_column_double(statement, index)
    }
}
