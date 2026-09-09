import Foundation

#if canImport(Darwin)
import Darwin
#endif

// MARK: - Store contract

public enum TrainingStoreError: Error, Equatable, LocalizedError, Sendable {
    case unsupportedSchema(Int)
    case corruptLedger
    case ledgerTooLarge
    case unreadableLedger
    case protectedDataUnavailable
    case integrityUnavailable
    case persistenceFailed
    case readbackValidationFailed
    case invalidClock
    case invalidMutation
    case mutationIDReuse
    case mutationIDRetired
    case revisionExhausted
    case externalMutationConflict
    case lockUnavailable
    case legacyQueueDataPresent
    case sessionNotFound
    case revisionConflict(expected: Int, actual: Int)
    case invalidStateTransition
    case activeSessionExists
    case importedRecordAlreadyLinked
    case importedRecordNotLinked
    case sessionLimit
    case receiptJournalFull
    case replayProtectionFull
    case invalidHistoryPage

    public var errorDescription: String? {
        switch self {
        case .unsupportedSchema(let version): "This training ledger schema is unsupported (\(version))."
        case .corruptLedger: "The training ledger is corrupt and was preserved for recovery."
        case .ledgerTooLarge: "The training ledger exceeds its local size limit."
        case .unreadableLedger: "The training ledger could not be read; the last valid state was preserved."
        case .protectedDataUnavailable: "Training data is locked until the device is unlocked."
        case .integrityUnavailable: "Training writes are blocked until the preserved ledger is recovered."
        case .persistenceFailed: "The training change could not be saved locally."
        case .readbackValidationFailed: "The saved training ledger failed readback validation."
        case .invalidClock: "The injected training clock returned an invalid instant."
        case .invalidMutation: "The training mutation payload is invalid."
        case .mutationIDReuse: "This mutation ID was already used with a different payload."
        case .mutationIDRetired: "This mutation ID was retired and cannot be replayed."
        case .revisionExhausted: "The training revision limit has been reached."
        case .externalMutationConflict: "The training ledger changed outside this store; reload before retrying."
        case .lockUnavailable: "The training ledger could not be exclusively locked."
        case .legacyQueueDataPresent: "This legacy ledger contains unsupported queued mutations and was preserved."
        case .sessionNotFound: "The local training session no longer exists."
        case .revisionConflict(let expected, let actual): "The training session changed (expected revision \(expected), current revision \(actual))."
        case .invalidStateTransition: "This training session cannot make that state transition."
        case .activeSessionExists: "Finish, pause, or discard the current training session before starting another."
        case .importedRecordAlreadyLinked: "This imported workout is already linked to another local session."
        case .importedRecordNotLinked: "This local session is not linked to that imported workout."
        case .sessionLimit: "The local training session limit has been reached; export or delete records to continue."
        case .receiptJournalFull: "The local mutation receipt journal is full; export and clear receipts before continuing."
        case .replayProtectionFull: "The durable replay-protection index is full; archive this ledger before continuing."
        case .invalidHistoryPage: "The requested training history page is invalid."
        }
    }
}

public enum TrainingStoreLimits {
    public static let maximumSessions = 10_000
    public static let maximumReceipts = 10_000
    public static let maximumRetiredMutationIDs = 100_000
    public static let maximumHistoryPageSize = 100
    public static let maximumLedgerBytes = 64 * 1_024 * 1_024
    /// Recovery may copy an oversized ledger to a user-selected destination,
    /// but the streaming path still refuses an unbounded source file.
    public static let maximumRecoveryExportBytes = maximumLedgerBytes * 4

    static func validateEncodedLedgerBytes(_ data: Data) throws {
        guard data.count <= maximumLedgerBytes else { throw TrainingStoreError.ledgerTooLarge }
    }
}

public struct TrainingLedgerEnvelope: Codable, Equatable, Sendable {
    public static let currentSchemaVersion = 2

    public let schemaVersion: Int
    public let sessions: [TrainingSession]
    public let receipts: [TrainingReceiptJournalEntry]
    public let retiredMutationIDs: [TrainingRecordID]

    public init(
        schemaVersion: Int = TrainingLedgerEnvelope.currentSchemaVersion,
        sessions: [TrainingSession] = [],
        receipts: [TrainingReceiptJournalEntry] = [],
        retiredMutationIDs: [TrainingRecordID] = []
    ) {
        self.schemaVersion = schemaVersion
        self.sessions = sessions
        self.receipts = receipts
        self.retiredMutationIDs = retiredMutationIDs
    }

    public func validate(now: Date = .now) throws {
        guard schemaVersion == Self.currentSchemaVersion else {
            throw TrainingStoreError.unsupportedSchema(schemaVersion)
        }
        guard sessions.count <= TrainingStoreLimits.maximumSessions else {
            throw TrainingStoreError.sessionLimit
        }
        guard receipts.count <= TrainingStoreLimits.maximumReceipts else {
            throw TrainingStoreError.receiptJournalFull
        }
        guard retiredMutationIDs.count <= TrainingStoreLimits.maximumRetiredMutationIDs else {
            throw TrainingStoreError.replayProtectionFull
        }

        var sessionIDs = Set<TrainingRecordID>()
        var importedOwnershipTokens = Set<String>()
        var openSessionCount = 0
        for session in sessions {
            guard sessionIDs.insert(session.id).inserted else {
                throw TrainingStoreError.corruptLedger
            }
            try session.validate(now: now)
            if let importedRecordKey = session.importedRecordKey {
                for token in try TrainingImportedWorkoutIdentity.stableKeyTokens(importedRecordKey) {
                    guard importedOwnershipTokens.insert(token).inserted else {
                        throw TrainingStoreError.corruptLedger
                    }
                }
            }
            if session.status == .active || session.status == .paused {
                openSessionCount += 1
                guard openSessionCount == 1 else {
                    throw TrainingStoreError.corruptLedger
                }
            }
        }

        var receiptIDs = Set<TrainingRecordID>()
        for entry in receipts {
            guard receiptIDs.insert(entry.mutationID).inserted,
                  entry.mutationID == entry.receipt.mutationID else {
                throw TrainingStoreError.corruptLedger
            }
        }
        var retiredIDs = Set<TrainingRecordID>()
        for mutationID in retiredMutationIDs {
            guard retiredIDs.insert(mutationID).inserted,
                  !receiptIDs.contains(mutationID) else {
                throw TrainingStoreError.corruptLedger
            }
        }
    }

    private enum CodingKeys: String, CodingKey {
        case schemaVersion, sessions, receipts, retiredMutationIDs
    }

    public init(from decoder: Decoder) throws {
        try rejectUnknownTrainingStoreKeys(decoder, allowed: ["schemaVersion", "sessions", "receipts", "retiredMutationIDs"])
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            schemaVersion: try c.decode(Int.self, forKey: .schemaVersion),
            sessions: try decodeBoundedTrainingStoreArray(
                TrainingSession.self,
                forKey: .sessions,
                from: c,
                maximum: TrainingStoreLimits.maximumSessions,
                overflow: .sessionLimit
            ),
            receipts: try decodeBoundedTrainingStoreArray(
                TrainingReceiptJournalEntry.self,
                forKey: .receipts,
                from: c,
                maximum: TrainingStoreLimits.maximumReceipts,
                overflow: .receiptJournalFull
            ),
            retiredMutationIDs: try decodeBoundedTrainingStoreArray(
                TrainingRecordID.self,
                forKey: .retiredMutationIDs,
                from: c,
                maximum: TrainingStoreLimits.maximumRetiredMutationIDs,
                overflow: .replayProtectionFull
            )
        )
    }
}

private struct TrainingStoreAnyCodingKey: CodingKey {
    let stringValue: String
    let intValue: Int? = nil

    init?(stringValue: String) { self.stringValue = stringValue }
    init?(intValue: Int) { return nil }
}

private func rejectUnknownTrainingStoreKeys(_ decoder: Decoder, allowed: Set<String>) throws {
    let container = try decoder.container(keyedBy: TrainingStoreAnyCodingKey.self)
    let keys = Set(container.allKeys.map(\.stringValue))
    guard keys.isSubset(of: allowed) else {
        throw DecodingError.dataCorrupted(.init(
            codingPath: decoder.codingPath,
            debugDescription: "Unknown training ledger field"
        ))
    }
}

private struct TrainingSchemaProbe: Decodable {
    let schemaVersion: Int
}

private func decodeBoundedTrainingStoreArray<Element: Decodable, Key: CodingKey>(
    _ type: Element.Type,
    forKey key: Key,
    from container: KeyedDecodingContainer<Key>,
    maximum: Int,
    overflow: TrainingStoreError
) throws -> [Element] {
    var nested = try container.nestedUnkeyedContainer(forKey: key)
    var values: [Element] = []
    if let count = nested.count {
        values.reserveCapacity(min(count, maximum))
    }
    while !nested.isAtEnd {
        guard values.count < maximum else { throw overflow }
        values.append(try nested.decode(Element.self))
    }
    return values
}

/// Schema 1 used ISO-8601 dates and carried an unimplemented queue field.
/// Decode it only with the legacy date parser, then migrate to schema 2 in one
/// durable transaction. A non-empty queue is rejected rather than discarded.
private struct LegacyTrainingLedgerEnvelope: Decodable {
    let schemaVersion: Int
    let sessions: [TrainingSession]
    let receipts: [LegacyTrainingReceiptJournalEntry]
    let hasQueuedMutations: Bool

    private enum CodingKeys: String, CodingKey {
        case schemaVersion, sessions, receipts, queuedMutations
    }

    init(from decoder: Decoder) throws {
        try rejectUnknownTrainingStoreKeys(decoder, allowed: ["schemaVersion", "sessions", "receipts", "queuedMutations"])
        let c = try decoder.container(keyedBy: CodingKeys.self)
        schemaVersion = try c.decode(Int.self, forKey: .schemaVersion)
        sessions = try decodeBoundedTrainingStoreArray(
            TrainingSession.self,
            forKey: .sessions,
            from: c,
            maximum: TrainingStoreLimits.maximumSessions,
            overflow: .sessionLimit
        )
        receipts = try decodeBoundedTrainingStoreArray(
            LegacyTrainingReceiptJournalEntry.self,
            forKey: .receipts,
            from: c,
            maximum: TrainingStoreLimits.maximumReceipts,
            overflow: .receiptJournalFull
        )
        if c.contains(.queuedMutations) {
            if try c.decodeNil(forKey: .queuedMutations) {
                hasQueuedMutations = false
            } else {
                let queue = try c.nestedUnkeyedContainer(forKey: .queuedMutations)
                hasQueuedMutations = !queue.isAtEnd
            }
        } else {
            hasQueuedMutations = false
        }
    }
}

/// Schema 1 receipt entries did not carry a fingerprint version. Their
/// containing envelope is the version marker, so they are converted to the
/// explicit legacy version during migration without recomputing any receipt
/// from the current session.
private struct LegacyTrainingReceiptJournalEntry: Decodable {
    let mutationID: TrainingRecordID
    let payloadFingerprint: String
    let receipt: TrainingCommitReceipt

    private enum CodingKeys: String, CodingKey { case mutationID, payloadFingerprint, receipt }

    init(from decoder: Decoder) throws {
        try rejectUnknownTrainingStoreKeys(decoder, allowed: ["mutationID", "payloadFingerprint", "receipt"])
        let c = try decoder.container(keyedBy: CodingKeys.self)
        mutationID = try c.decode(TrainingRecordID.self, forKey: .mutationID)
        payloadFingerprint = try c.decode(String.self, forKey: .payloadFingerprint)
        receipt = try c.decode(TrainingCommitReceipt.self, forKey: .receipt)
        guard payloadFingerprint.utf8.count == 64,
              payloadFingerprint.utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) }) else {
            throw TrainingStoreError.corruptLedger
        }
        guard receipt.mutationID == mutationID else { throw TrainingStoreError.corruptLedger }
    }

    func migrated() throws -> TrainingReceiptJournalEntry {
        try TrainingReceiptJournalEntry(
            mutationID: mutationID,
            payloadFingerprint: payloadFingerprint,
            payloadFingerprintVersion: .legacyISO8601V1,
            receipt: receipt
        )
    }
}

private final class TrainingFileLock {
    private let descriptor: Int32

    init(url: URL, fileManager: FileManager) throws {
        try fileManager.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true,
            attributes: nil
        )
#if canImport(Darwin)
        let opened = url.path.withCString { path in
            Darwin.open(path, O_CREAT | O_RDWR, mode_t(0o600))
        }
        guard opened >= 0 else { throw TrainingStoreError.lockUnavailable }
        guard flock(opened, LOCK_EX) == 0 else {
            Darwin.close(opened)
            throw TrainingStoreError.lockUnavailable
        }
        descriptor = opened
#else
        throw TrainingStoreError.lockUnavailable
#endif
    }

    deinit {
#if canImport(Darwin)
        _ = flock(descriptor, LOCK_UN)
        _ = Darwin.close(descriptor)
#endif
    }
}

// MARK: - Local-first actor store

/// A single actor owns the local training ledger. Every mutation builds a
/// complete candidate state, validates and encodes it, atomically replaces the
/// file, validates the readback, and only then publishes the candidate state.
public actor FitnessTrainingStore {
    private static let processTransactionLock = NSLock()

    private static var defaultPersistenceURL: URL? {
        guard let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else {
            return nil
        }
        return support
            .appendingPathComponent("LifeOS", isDirectory: true)
            .appendingPathComponent("fitness-training-ledger.json")
    }

    private let persistenceURL: URL?
    private let fileManager: FileManager
    private let clock: @Sendable () -> Date
    private let beforeReplace: (() throws -> Void)?
    private let afterReplace: (() throws -> Void)?
    private let beforeRestore: (() throws -> Void)?

    private var sessionsByID: [TrainingRecordID: TrainingSession] = [:]
    private var receiptsByMutationID: [TrainingRecordID: TrainingReceiptJournalEntry] = [:]
    private var retiredMutationIDs: Set<TrainingRecordID> = []
    private var hasLoaded = false
    /// A valid empty ledger is still a loaded state. Track whether this store
    /// has ever observed a durable path separately from that in-memory state.
    private var hasObservedDurableFile = false
    private var preservedLedgerData: Data?
    private var loadFailure: TrainingStoreError?
    private var lastDurableData: Data?

    public init(
        persistenceURL: URL? = nil,
        fileManager: FileManager = .default,
        clock: @escaping @Sendable () -> Date = { Date() },
        beforeReplace: (() throws -> Void)? = nil,
        afterReplace: (() throws -> Void)? = nil,
        beforeRestore: (() throws -> Void)? = nil
    ) {
        self.persistenceURL = (persistenceURL ?? Self.defaultPersistenceURL)?.standardizedFileURL
        self.fileManager = fileManager
        self.clock = clock
        self.beforeReplace = beforeReplace
        self.afterReplace = afterReplace
        self.beforeRestore = beforeRestore
    }

    /// Loads the disk state. A malformed, unsupported, oversized, or
    /// unreadable file remains untouched and is reported to the caller; it is
    /// never converted into an empty ledger.
    @discardableResult
    public func load() throws -> [TrainingSession] {
        try withPersistenceTransaction {
            try reloadFromDiskLocked()
            return sortedSessions()
        }
    }

    public func session(id: TrainingRecordID) throws -> TrainingSession? {
        try withPersistenceTransaction {
            try refreshForDurableReadLocked()
            return sessionsByID[id]
        }
    }

    public func allSessions() throws -> [TrainingSession] {
        try withPersistenceTransaction {
            try refreshForDurableReadLocked()
            return sortedSessions()
        }
    }

    public func activeSession() throws -> TrainingSession? {
        try withPersistenceTransaction {
            try refreshForDurableReadLocked()
            return sessionsByID.values.first { $0.status == .active || $0.status == .paused }
        }
    }

    public func allHistory() throws -> [TrainingHistoryItem] {
        try withPersistenceTransaction {
            try refreshForDurableReadLocked()
            return try allHistoryLocked()
        }
    }

    public func historyPage(offset: Int, limit: Int = TrainingStoreLimits.maximumHistoryPageSize) throws -> TrainingHistoryPage {
        guard offset >= 0, (1...TrainingStoreLimits.maximumHistoryPageSize).contains(limit) else {
            throw TrainingStoreError.invalidHistoryPage
        }
        return try withPersistenceTransaction {
            try refreshForDurableReadLocked()
            return try historyPageLocked(offset: offset, limit: limit)
        }
    }

    public func pagedHistory(page: Int, pageSize: Int = TrainingStoreLimits.maximumHistoryPageSize) throws -> TrainingHistoryPage {
        guard page >= 0, (1...TrainingStoreLimits.maximumHistoryPageSize).contains(pageSize),
              page <= Int.max / pageSize else {
            throw TrainingStoreError.invalidHistoryPage
        }
        return try withPersistenceTransaction {
            try refreshForDurableReadLocked()
            return try historyPageLocked(offset: page * pageSize, limit: pageSize)
        }
    }

    /// Returns the last valid bytes when the ledger is quarantined, which
    /// gives a caller a recovery/export path without exposing a file path.
    public func export() throws -> Data {
        try withPersistenceTransaction {
            if let preservedLedgerData { return preservedLedgerData }
            if let loadFailure { throw loadFailure }
            do {
                try reloadFromDiskLocked()
                if let lastDurableData { return lastDurableData }
                return try encode(currentEnvelope())
            } catch let error as TrainingStoreError {
                if let preservedLedgerData { return preservedLedgerData }
                throw error
            }
        }
    }

    /// Copies a quarantined ledger to a caller-selected recovery destination.
    /// The bounded path is useful for oversized files because it never builds a
    /// `Data` value from the source. Source and destination symlinks are
    /// rejected before the copy and the destination is published atomically.
    public func export(to destinationURL: URL) throws {
        try withPersistenceTransaction {
            guard let destinationURL = normalizedRecoveryDestination(destinationURL),
                  persistenceURL != destinationURL else {
                throw TrainingStoreError.persistenceFailed
            }

            if let preservedLedgerData {
                try writeRecoveryData(preservedLedgerData, to: destinationURL)
                return
            }

            if let loadFailure {
                guard loadFailure == .ledgerTooLarge, let persistenceURL else {
                    throw loadFailure
                }
                try copyRecoveryFile(from: persistenceURL, to: destinationURL)
                return
            }

            do {
                try reloadFromDiskLocked()
                if let preservedLedgerData {
                    try writeRecoveryData(preservedLedgerData, to: destinationURL)
                } else if let lastDurableData {
                    try writeRecoveryData(lastDurableData, to: destinationURL)
                } else {
                    try writeRecoveryData(try encode(currentEnvelope()), to: destinationURL)
                }
            } catch let error as TrainingStoreError {
                if let preservedLedgerData {
                    try writeRecoveryData(preservedLedgerData, to: destinationURL)
                } else if error == .ledgerTooLarge, let persistenceURL {
                    try copyRecoveryFile(from: persistenceURL, to: destinationURL)
                } else {
                    throw error
                }
            }
        }
    }

    /// Returns one immutable view of the exact durable generation observed by
    /// the transaction. If a previously verified generation is no longer
    /// readable, the view is explicitly stale so projection callers cannot
    /// mistake retained diagnostic data for current truth.
    public func snapshot() throws -> TrainingStoreSnapshot {
        try withPersistenceTransaction {
            do {
                try refreshForDurableReadLocked()
                if loadFailure != nil {
                    return try makeSnapshot(integrity: .unavailable, freshness: .stale)
                }
                return try makeSnapshot(integrity: .verified, freshness: .current)
            } catch let error as TrainingStoreError {
                guard lastDurableData != nil else { throw error }
                return try makeSnapshot(integrity: .unavailable, freshness: .stale)
            }
        }
    }

    public func loadFailureState() -> TrainingStoreError? {
        loadFailure
    }

    public func receipt(for mutationID: UUID) throws -> TrainingCommitReceipt? {
        try withPersistenceTransaction {
            try refreshForDurableReadLocked()
            return receiptsByMutationID[TrainingRecordID(uuid: mutationID)]?.receipt
        }
    }

    // MARK: Begin

    @discardableResult
    public func begin(
        template: TrainingTemplateSnapshot? = nil,
        title: String? = nil,
        activityKind: TrainingActivityKind = .strength,
        notes: String? = nil,
        mutationID: UUID = UUID()
    ) throws -> TrainingCommitReceipt {
        let mutation = TrainingMutation(
            mutationID: TrainingRecordID(uuid: mutationID),
            operation: .begin,
            template: template,
            title: title,
            activityKind: activityKind,
            notes: notes
        )
        return try execute(mutation)
    }

    @discardableResult
    public func begin(
        template: TrainingTemplateSnapshot? = nil,
        title: String? = nil,
        activityKind: TrainingActivityKind = .strength,
        notes: String? = nil,
        mutationID: TrainingRecordID
    ) throws -> TrainingCommitReceipt {
        try begin(
            template: template,
            title: title,
            activityKind: activityKind,
            notes: notes,
            mutationID: mutationID.uuid
        )
    }

    // MARK: Revisioned edits

    @discardableResult
    public func update(
        _ session: TrainingSession,
        expectedRevision: Int,
        mutationID: UUID
    ) throws -> TrainingCommitReceipt {
        let mutation = TrainingMutation(
            mutationID: TrainingRecordID(uuid: mutationID),
            operation: .update,
            recordID: session.id,
            expectedRevision: expectedRevision,
            session: session
        )
        return try execute(mutation)
    }

    @discardableResult
    public func update(
        _ session: TrainingSession,
        expectedRevision: Int,
        mutationID: TrainingRecordID
    ) throws -> TrainingCommitReceipt {
        try update(session, expectedRevision: expectedRevision, mutationID: mutationID.uuid)
    }

    @discardableResult
    public func finish(
        _ session: TrainingSession,
        expectedRevision: Int,
        mutationID: UUID
    ) throws -> TrainingCommitReceipt {
        let mutation = TrainingMutation(
            mutationID: TrainingRecordID(uuid: mutationID),
            operation: .finish,
            recordID: session.id,
            expectedRevision: expectedRevision,
            session: session
        )
        return try execute(mutation)
    }

    @discardableResult
    public func finish(
        _ session: TrainingSession,
        expectedRevision: Int,
        mutationID: TrainingRecordID
    ) throws -> TrainingCommitReceipt {
        try finish(session, expectedRevision: expectedRevision, mutationID: mutationID.uuid)
    }

    @discardableResult
    public func discard(
        id: TrainingRecordID,
        expectedRevision: Int,
        mutationID: UUID
    ) throws -> TrainingCommitReceipt {
        let mutation = TrainingMutation(
            mutationID: TrainingRecordID(uuid: mutationID),
            operation: .discard,
            recordID: id,
            expectedRevision: expectedRevision
        )
        return try execute(mutation)
    }

    @discardableResult
    public func delete(
        id: TrainingRecordID,
        expectedRevision: Int,
        mutationID: UUID
    ) throws -> TrainingCommitReceipt {
        let mutation = TrainingMutation(
            mutationID: TrainingRecordID(uuid: mutationID),
            operation: .delete,
            recordID: id,
            expectedRevision: expectedRevision
        )
        return try execute(mutation)
    }

    /// Links one local session to one imported source identity. The stable key
    /// is validated against the imported identity grammar before it enters the
    /// durable ledger; the local sets and imported source record remain
    /// separate namespaces.
    @discardableResult
    public func link(
        sessionID: TrainingRecordID,
        importedRecordKey: String,
        expectedRevision: Int,
        mutationID: UUID
    ) throws -> TrainingCommitReceipt {
        try execute(TrainingMutation(
            mutationID: TrainingRecordID(uuid: mutationID),
            operation: .link,
            recordID: sessionID,
            expectedRevision: expectedRevision,
            importedRecordKey: importedRecordKey
        ))
    }

    @discardableResult
    public func unlink(
        sessionID: TrainingRecordID,
        importedRecordKey: String,
        expectedRevision: Int,
        mutationID: UUID
    ) throws -> TrainingCommitReceipt {
        try execute(TrainingMutation(
            mutationID: TrainingRecordID(uuid: mutationID),
            operation: .unlink,
            recordID: sessionID,
            expectedRevision: expectedRevision,
            importedRecordKey: importedRecordKey
        ))
    }

    /// Explicit recovery after the caller has exported the receipt journal.
    /// Receipt payloads are moved to an append-only retired-ID index before
    /// the clear, so an old mutation can never execute again. Retired IDs do
    /// not expire or compact automatically; reaching the count or encoded
    /// ledger limit fails closed and requires an explicit archive/new ledger.
    public func clearReceiptJournalAfterExport() throws {
        try withPersistenceTransaction {
            // Receipt compaction is destructive to the journal. A failed
            // write/reload must be recovered explicitly through `load()`
            // before an old receipt can be retired.
            guard loadFailure == nil else { throw TrainingStoreError.integrityUnavailable }
            try reloadFromDiskLocked()
            try ensureLoadedLocked()
            guard !receiptsByMutationID.isEmpty else { return }
            let retired = retiredMutationIDs.union(receiptsByMutationID.keys)
            guard retired.count <= TrainingStoreLimits.maximumRetiredMutationIDs else {
                throw TrainingStoreError.replayProtectionFull
            }
            let candidate = TrainingLedgerEnvelope(
                sessions: sortedSessions(),
                receipts: [],
                retiredMutationIDs: retired.sorted { $0.rawValue < $1.rawValue }
            )
            let data = try persistAndVerify(candidate)
            sessionsByID = Dictionary(uniqueKeysWithValues: candidate.sessions.map { ($0.id, $0) })
            receiptsByMutationID = [:]
            retiredMutationIDs = retired
            lastDurableData = data
        }
    }

    // MARK: Mutation implementation

    private func execute(_ mutation: TrainingMutation) throws -> TrainingCommitReceipt {
        try withPersistenceTransaction {
            // Re-read while the process and sidecar file locks are held. This
            // makes an already-created actor instance adopt the latest durable
            // generation before it constructs a candidate state.
            guard loadFailure == nil else { throw TrainingStoreError.integrityUnavailable }
            try reloadFromDiskLocked()
            try ensureLoadedLocked()
            try validateMutationShape(mutation)

            if retiredMutationIDs.contains(mutation.mutationID) {
                throw TrainingStoreError.mutationIDRetired
            }
            if let existing = receiptsByMutationID[mutation.mutationID] {
                guard try existingFingerprintMatches(existing, mutation: mutation) else {
                    throw TrainingStoreError.mutationIDReuse
                }
                // Returning the stored value preserves the exact durable
                // receipt and makes a retry free of a second write.
                return existing.receipt
            }
            let fingerprintVersion: TrainingFingerprintVersion = .losslessNumericV2
            let fingerprint = try TrainingFingerprint.hex(for: mutation, version: fingerprintVersion)
            guard receiptsByMutationID.count < TrainingStoreLimits.maximumReceipts else {
                throw TrainingStoreError.receiptJournalFull
            }

            switch mutation.operation {
            case .begin:
                return try applyBegin(mutation, fingerprint: fingerprint)
            case .update:
                return try applyRevisionedSession(mutation, fingerprint: fingerprint, finishing: false)
            case .finish:
                return try applyRevisionedSession(mutation, fingerprint: fingerprint, finishing: true)
            case .discard:
                return try applyDiscard(mutation, fingerprint: fingerprint)
            case .delete:
                return try applyDelete(mutation, fingerprint: fingerprint)
            case .link:
                return try applyLink(mutation, fingerprint: fingerprint)
            case .unlink:
                return try applyUnlink(mutation, fingerprint: fingerprint)
            }
        }
    }

    private func existingFingerprintMatches(
        _ entry: TrainingReceiptJournalEntry,
        mutation: TrainingMutation
    ) throws -> Bool {
        switch entry.payloadFingerprintVersion {
        case .losslessNumericV2:
            let fingerprint = try TrainingFingerprint.hex(
                for: mutation,
                version: .losslessNumericV2
            )
            return entry.payloadFingerprint == fingerprint
        case .legacyISO8601V1:
            return try TrainingFingerprint.legacyCandidates(for: mutation).contains(entry.payloadFingerprint)
        }
    }

    private func validateMutationShape(_ mutation: TrainingMutation) throws {
        guard mutation.mutationID.uuid.uuidString.lowercased() == mutation.mutationID.rawValue else {
            throw TrainingStoreError.invalidMutation
        }
        if let expectedRevision = mutation.expectedRevision,
           expectedRevision < 0 || expectedRevision >= Int.max {
            throw TrainingStoreError.invalidMutation
        }
        switch mutation.operation {
        case .begin:
            guard mutation.recordID == nil, mutation.expectedRevision == nil,
                  mutation.session == nil, mutation.activityKind != nil,
                  mutation.importedRecordKey == nil else {
                throw TrainingStoreError.invalidMutation
            }
            if let title = mutation.title, title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                throw TrainingStoreError.invalidMutation
            }
        case .update, .finish:
            guard let recordID = mutation.recordID,
                  let expectedRevision = mutation.expectedRevision,
                  let session = mutation.session,
                  session.id == recordID,
                  session.revision == expectedRevision,
                  mutation.importedRecordKey == nil else {
                throw TrainingStoreError.invalidMutation
            }
        case .discard, .delete:
            guard mutation.recordID != nil,
                  mutation.expectedRevision != nil,
                  mutation.session == nil,
                  mutation.template == nil,
                  mutation.title == nil,
                  mutation.activityKind == nil,
                  mutation.notes == nil,
                  mutation.importedRecordKey == nil else {
                throw TrainingStoreError.invalidMutation
            }
        case .link, .unlink:
            guard mutation.recordID != nil,
                  mutation.expectedRevision != nil,
                  let importedRecordKey = mutation.importedRecordKey,
                  (try? TrainingImportedWorkoutIdentity.validateStableKey(importedRecordKey)) != nil,
                  mutation.session == nil,
                  mutation.template == nil,
                  mutation.title == nil,
                  mutation.activityKind == nil,
                  mutation.notes == nil else {
                throw TrainingStoreError.invalidMutation
            }
        }
    }

    private func applyBegin(_ mutation: TrainingMutation, fingerprint: String) throws -> TrainingCommitReceipt {
        if sessionsByID.values.contains(where: { $0.status == .active || $0.status == .paused }) {
            return try persistBlockedReceipt(
                mutation: mutation,
                fingerprint: fingerprint,
                recordID: nil,
                revision: nil,
                reason: .activeSession,
                message: TrainingStoreError.activeSessionExists.localizedDescription
            )
        }
        guard sessionsByID.count < TrainingStoreLimits.maximumSessions else {
            return try persistBlockedReceipt(
                mutation: mutation,
                fingerprint: fingerprint,
                recordID: nil,
                revision: nil,
                reason: .sessionLimit,
                message: TrainingStoreError.sessionLimit.localizedDescription
            )
        }

        let now = try currentTime()
        let session = try makeInitialSession(
            template: mutation.template,
            title: mutation.title,
            activityKind: mutation.activityKind ?? .strength,
            notes: mutation.notes,
            now: now
        )
        var nextSessions = sessionsByID
        nextSessions[session.id] = session
        let receipt = try TrainingCommitReceipt(
            mutationID: mutation.mutationID,
            outcome: .saved,
            recordID: session.id,
            revision: session.revision
        )
        return try persistCandidate(
            sessions: nextSessions,
            receipts: receiptEntry(mutation: mutation, fingerprint: fingerprint, receipt: receipt),
            receipt: receipt
        )
    }

    private func applyRevisionedSession(
        _ mutation: TrainingMutation,
        fingerprint: String,
        finishing: Bool
    ) throws -> TrainingCommitReceipt {
        guard let recordID = mutation.recordID,
              let expectedRevision = mutation.expectedRevision,
              let submitted = mutation.session,
              let current = sessionsByID[recordID] else {
            throw TrainingStoreError.sessionNotFound
        }
        let now = try currentTime()
        try submitted.validate(now: now)

        if current.revision != expectedRevision {
            let conflict = try TrainingCommitReceipt(
                mutationID: mutation.mutationID,
                outcome: .conflict,
                recordID: current.id,
                revision: current.revision,
                currentSession: current,
                message: "The durable session changed before this draft was saved."
            )
            return try persistCandidate(
                sessions: sessionsByID,
                receipts: receiptEntry(mutation: mutation, fingerprint: fingerprint, receipt: conflict),
                receipt: conflict
            )
        }

        guard current.status == .active || current.status == .paused,
              submitted.createdAt == current.createdAt,
              submitted.startedAt == current.startedAt,
              submitted.timeZoneIdentifier == current.timeZoneIdentifier,
              submitted.templateID == current.templateID,
              submitted.templateSnapshot == current.templateSnapshot,
              submitted.importedRecordKey == current.importedRecordKey else {
            throw TrainingStoreError.invalidMutation
        }

        if finishing {
            guard submitted.status == .completed,
                  current.status == .active || current.status == .paused else {
                throw TrainingStoreError.invalidStateTransition
            }
        } else {
            guard submitted.status == .active || submitted.status == .paused else {
                throw TrainingStoreError.invalidStateTransition
            }
        }

        let durableUpdatedAt = max(now, current.updatedAt)
        let next = try submitted.replacing(
            revision: try nextRevision(after: expectedRevision),
            updatedAt: durableUpdatedAt,
            status: finishing ? .completed : submitted.status,
            endedAt: submitted.endedAt,
            pauses: submitted.pauses,
            now: now
        )
        var nextSessions = sessionsByID
        nextSessions[recordID] = next
        let receipt = try TrainingCommitReceipt(
            mutationID: mutation.mutationID,
            outcome: .saved,
            recordID: recordID,
            revision: next.revision
        )
        return try persistCandidate(
            sessions: nextSessions,
            receipts: receiptEntry(mutation: mutation, fingerprint: fingerprint, receipt: receipt),
            receipt: receipt
        )
    }

    private func applyDiscard(_ mutation: TrainingMutation, fingerprint: String) throws -> TrainingCommitReceipt {
        guard let recordID = mutation.recordID,
              let expectedRevision = mutation.expectedRevision,
              let current = sessionsByID[recordID] else {
            throw TrainingStoreError.sessionNotFound
        }
        guard current.revision == expectedRevision else {
            let conflict = try TrainingCommitReceipt(
                mutationID: mutation.mutationID,
                outcome: .conflict,
                recordID: current.id,
                revision: current.revision,
                currentSession: current,
                message: "The durable session changed before it was discarded."
            )
            return try persistCandidate(
                sessions: sessionsByID,
                receipts: receiptEntry(mutation: mutation, fingerprint: fingerprint, receipt: conflict),
                receipt: conflict
            )
        }
        guard current.status == .active || current.status == .paused else {
            throw TrainingStoreError.invalidStateTransition
        }

        let now = try currentTime()
        let closeAt = max(now, current.pauses.last?.startedAt.addingTimeInterval(0.001) ?? now)
        let closedPauses = try current.pauses.map { pause in
            guard pause.endedAt == nil else { return pause }
            return try pause.ended(at: closeAt, now: now)
        }
        let next = try current.replacing(
            revision: try nextRevision(after: expectedRevision),
            updatedAt: max(now, current.updatedAt),
            status: .discarded,
            endedAt: nil,
            pauses: closedPauses,
            now: now
        )
        var nextSessions = sessionsByID
        nextSessions[recordID] = next
        let receipt = try TrainingCommitReceipt(
            mutationID: mutation.mutationID,
            outcome: .saved,
            recordID: recordID,
            revision: next.revision
        )
        return try persistCandidate(
            sessions: nextSessions,
            receipts: receiptEntry(mutation: mutation, fingerprint: fingerprint, receipt: receipt),
            receipt: receipt
        )
    }

    private func applyDelete(_ mutation: TrainingMutation, fingerprint: String) throws -> TrainingCommitReceipt {
        guard let recordID = mutation.recordID,
              let expectedRevision = mutation.expectedRevision,
              let current = sessionsByID[recordID] else {
            throw TrainingStoreError.sessionNotFound
        }
        guard current.revision == expectedRevision else {
            let conflict = try TrainingCommitReceipt(
                mutationID: mutation.mutationID,
                outcome: .conflict,
                recordID: current.id,
                revision: current.revision,
                currentSession: current,
                message: "The durable session changed before deletion."
            )
            return try persistCandidate(
                sessions: sessionsByID,
                receipts: receiptEntry(mutation: mutation, fingerprint: fingerprint, receipt: conflict),
                receipt: conflict
            )
        }

        var nextSessions = sessionsByID
        nextSessions.removeValue(forKey: recordID)
        let receipt = try TrainingCommitReceipt(
            mutationID: mutation.mutationID,
            outcome: .saved,
            recordID: recordID,
            revision: current.revision
        )
        return try persistCandidate(
            sessions: nextSessions,
            receipts: receiptEntry(mutation: mutation, fingerprint: fingerprint, receipt: receipt),
            receipt: receipt
        )
    }

    private func applyLink(_ mutation: TrainingMutation, fingerprint: String) throws -> TrainingCommitReceipt {
        guard let recordID = mutation.recordID,
              let expectedRevision = mutation.expectedRevision,
              let importedRecordKey = mutation.importedRecordKey,
              let current = sessionsByID[recordID] else {
            throw TrainingStoreError.sessionNotFound
        }
        let normalizedImportedRecordKey = try TrainingImportedWorkoutIdentity.canonicalStableKey(from: [importedRecordKey])
        guard current.revision == expectedRevision else {
            return try persistConflict(
                mutation: mutation,
                fingerprint: fingerprint,
                current: current,
                message: "The durable session changed before it was linked."
            )
        }
        guard current.status != .discarded else { throw TrainingStoreError.invalidStateTransition }

        if let currentImportedRecordKey = current.importedRecordKey {
            let currentTokens = Set(try TrainingImportedWorkoutIdentity.stableKeyTokens(currentImportedRecordKey))
            let incomingTokens = Set(try TrainingImportedWorkoutIdentity.stableKeyTokens(normalizedImportedRecordKey))
            guard !currentTokens.isDisjoint(with: incomingTokens) else {
                return try persistConflict(
                    mutation: mutation,
                    fingerprint: fingerprint,
                    current: current,
                    message: "Unlink the current imported record before linking another one."
                )
            }

            let reconciledKey = try TrainingImportedWorkoutIdentity.canonicalStableKey(
                from: [currentImportedRecordKey, normalizedImportedRecordKey]
            )
            if reconciledKey == currentImportedRecordKey {
                let receipt = try TrainingCommitReceipt(
                    mutationID: mutation.mutationID,
                    outcome: .duplicate,
                    recordID: current.id,
                    revision: current.revision,
                    message: "The local session was already linked to this imported record."
                )
                return try persistCandidate(
                    sessions: sessionsByID,
                    receipts: receiptEntry(mutation: mutation, fingerprint: fingerprint, receipt: receipt),
                    receipt: receipt
                )
            }

            let now = try currentTime()
            let next = try current.replacingImportedRecordKey(
                reconciledKey,
                revision: try nextRevision(after: expectedRevision),
                updatedAt: max(now, current.updatedAt),
                now: now
            )
            var nextSessions = sessionsByID
            nextSessions[recordID] = next
            let receipt = try TrainingCommitReceipt(
                mutationID: mutation.mutationID,
                outcome: .saved,
                recordID: recordID,
                revision: next.revision
            )
            return try persistCandidate(
                sessions: nextSessions,
                receipts: receiptEntry(mutation: mutation, fingerprint: fingerprint, receipt: receipt),
                receipt: receipt
            )
        }
        if let owner = sessionsByID.values.first(where: {
            guard $0.id != current.id, let ownerKey = $0.importedRecordKey else { return false }
            return TrainingImportedWorkoutIdentity.stableKeysRepresentSameIdentity(ownerKey, normalizedImportedRecordKey)
        }) {
            return try persistConflict(
                mutation: mutation,
                fingerprint: fingerprint,
                current: owner,
                message: "This imported record is already linked to another local session."
            )
        }

        let now = try currentTime()
        let next = try current.replacingImportedRecordKey(
            normalizedImportedRecordKey,
            revision: try nextRevision(after: expectedRevision),
            updatedAt: max(now, current.updatedAt),
            now: now
        )
        var nextSessions = sessionsByID
        nextSessions[recordID] = next
        let receipt = try TrainingCommitReceipt(
            mutationID: mutation.mutationID,
            outcome: .saved,
            recordID: recordID,
            revision: next.revision
        )
        return try persistCandidate(
            sessions: nextSessions,
            receipts: receiptEntry(mutation: mutation, fingerprint: fingerprint, receipt: receipt),
            receipt: receipt
        )
    }

    private func applyUnlink(_ mutation: TrainingMutation, fingerprint: String) throws -> TrainingCommitReceipt {
        guard let recordID = mutation.recordID,
              let expectedRevision = mutation.expectedRevision,
              let importedRecordKey = mutation.importedRecordKey,
              let current = sessionsByID[recordID] else {
            throw TrainingStoreError.sessionNotFound
        }
        guard current.revision == expectedRevision else {
            return try persistConflict(
                mutation: mutation,
                fingerprint: fingerprint,
                current: current,
                message: "The durable session changed before it was unlinked."
            )
        }
        guard let currentImportedRecordKey = current.importedRecordKey,
              TrainingImportedWorkoutIdentity.stableKeysRepresentSameIdentity(currentImportedRecordKey, importedRecordKey) else {
            return try persistConflict(
                mutation: mutation,
                fingerprint: fingerprint,
                current: current,
                message: "The local session is no longer linked to that imported record."
            )
        }

        let now = try currentTime()
        let next = try current.replacingImportedRecordKey(
            nil,
            revision: try nextRevision(after: expectedRevision),
            updatedAt: max(now, current.updatedAt),
            now: now
        )
        var nextSessions = sessionsByID
        nextSessions[recordID] = next
        let receipt = try TrainingCommitReceipt(
            mutationID: mutation.mutationID,
            outcome: .saved,
            recordID: recordID,
            revision: next.revision
        )
        return try persistCandidate(
            sessions: nextSessions,
            receipts: receiptEntry(mutation: mutation, fingerprint: fingerprint, receipt: receipt),
            receipt: receipt
        )
    }

    private func persistConflict(
        mutation: TrainingMutation,
        fingerprint: String,
        current: TrainingSession,
        message: String
    ) throws -> TrainingCommitReceipt {
        let conflict = try TrainingCommitReceipt(
            mutationID: mutation.mutationID,
            outcome: .conflict,
            recordID: current.id,
            revision: current.revision,
            currentSession: current,
            message: message
        )
        return try persistCandidate(
            sessions: sessionsByID,
            receipts: receiptEntry(mutation: mutation, fingerprint: fingerprint, receipt: conflict),
            receipt: conflict
        )
    }

    private func persistBlockedReceipt(
        mutation: TrainingMutation,
        fingerprint: String,
        recordID: TrainingRecordID?,
        revision: Int?,
        reason: TrainingCommitReceipt.BlockReason,
        message: String
    ) throws -> TrainingCommitReceipt {
        let receipt = try TrainingCommitReceipt(
            mutationID: mutation.mutationID,
            outcome: .blocked,
            recordID: recordID,
            revision: revision,
            blockReason: reason,
            message: message
        )
        return try persistCandidate(
            sessions: sessionsByID,
            receipts: receiptEntry(mutation: mutation, fingerprint: fingerprint, receipt: receipt),
            receipt: receipt
        )
    }

    private func receiptEntry(
        mutation: TrainingMutation,
        fingerprint: String,
        receipt: TrainingCommitReceipt
    ) throws -> TrainingReceiptJournalEntry {
        try TrainingReceiptJournalEntry(
            mutationID: mutation.mutationID,
            payloadFingerprint: fingerprint,
            receipt: receipt
        )
    }

    private func persistCandidate(
        sessions: [TrainingRecordID: TrainingSession],
        receipts: TrainingReceiptJournalEntry,
        receipt: TrainingCommitReceipt
    ) throws -> TrainingCommitReceipt {
        var nextReceipts = receiptsByMutationID
        nextReceipts[receipts.mutationID] = receipts
        let envelope = TrainingLedgerEnvelope(
            sessions: sessions.values.sorted {
                if $0.startedAt != $1.startedAt { return $0.startedAt < $1.startedAt }
                return $0.id.rawValue < $1.id.rawValue
            },
            receipts: nextReceipts.values.sorted { $0.mutationID.rawValue < $1.mutationID.rawValue },
            retiredMutationIDs: retiredMutationIDs.sorted { $0.rawValue < $1.rawValue }
        )
        do {
            let data = try persistAndVerify(envelope)
            sessionsByID = sessions
            receiptsByMutationID = nextReceipts
            lastDurableData = data
            preservedLedgerData = nil
            loadFailure = nil
            hasLoaded = true
            if persistenceURL != nil { hasObservedDurableFile = true }
            return receipt
        } catch TrainingStoreError.ledgerTooLarge {
            // No bytes were replaced and no receipt was published. This is a
            // truthful blocked outcome; a retry can use the same draft/ID.
            return try TrainingCommitReceipt(
                mutationID: receipt.mutationID,
                outcome: .blocked,
                recordID: receipt.recordID,
                revision: receipt.revision,
                blockReason: .ledgerSize,
                message: TrainingStoreError.ledgerTooLarge.localizedDescription
            )
        }
    }

    // MARK: Session construction and loading

    private func makeInitialSession(
        template: TrainingTemplateSnapshot?,
        title: String?,
        activityKind: TrainingActivityKind,
        notes: String?,
        now: Date
    ) throws -> TrainingSession {
        let sessionTitle = title ?? template?.name ?? "Training session"
        let exerciseLogs: [TrainingExerciseLog]
        if let template {
            exerciseLogs = try template.exercises.map { exercise in
                let sets = try (0..<exercise.targetSets).map { _ in
                    try TrainingSetLog(
                        kind: .working,
                        targetRepetitions: exercise.targetRepetitions,
                        targetLoadKilograms: exercise.targetLoadKilograms,
                        now: now
                    )
                }
                return try TrainingExerciseLog(
                    templateExerciseID: exercise.id,
                    name: exercise.name,
                    muscleGroup: exercise.muscleGroup,
                    loadConvention: exercise.loadConvention,
                    sets: sets
                )
            }
        } else {
            exerciseLogs = []
        }
        return try TrainingSession(
            revision: 0,
            activityKind: activityKind,
            title: sessionTitle,
            createdAt: now,
            updatedAt: now,
            startedAt: now,
            timeZoneIdentifier: TimeZone.current.identifier,
            templateID: template?.templateID,
            templateSnapshot: template,
            status: .active,
            exercises: exerciseLogs,
            notes: notes,
            now: now
        )
    }

    private func refreshForDurableReadLocked() throws {
        if loadFailure != nil { throw TrainingStoreError.integrityUnavailable }
        do {
            try reloadFromDiskLocked()
            try ensureLoadedLocked()
        } catch {
            // Retained state is exposed only through snapshot(), which marks
            // its generation stale. Ordinary reads must fail closed instead
            // of presenting diagnostic bytes as current truth.
            throw TrainingStoreError.integrityUnavailable
        }
    }

    private func ensureLoadedLocked() throws {
        if !hasLoaded {
            try reloadFromDiskLocked()
        }
        if loadFailure != nil {
            // A previously verified snapshot remains readable for recovery
            // diagnostics, but all mutations stay fail-closed. A store with
            // no verified snapshot cannot pretend to contain an empty ledger.
            guard lastDurableData != nil else { throw TrainingStoreError.integrityUnavailable }
        }
    }

    private func allHistoryLocked() throws -> [TrainingHistoryItem] {
        let now = try currentTime()
        return try sessionsByID.values
            .filter { $0.status != .discarded }
            .map { try TrainingHistoryItem(session: $0, now: now) }
            .sorted(by: TrainingHistorySort.newestFirst)
    }

    private func historyPageLocked(offset: Int, limit: Int) throws -> TrainingHistoryPage {
        let history = try allHistoryLocked()
        guard offset <= history.count else { throw TrainingStoreError.invalidHistoryPage }
        let end = min(history.count, offset + limit)
        return TrainingHistoryPage(
            items: Array(history[offset..<end]),
            offset: offset,
            limit: limit,
            totalCount: history.count
        )
    }

    private func makeSnapshot(
        integrity: TrainingStoreIntegrity,
        freshness: TrainingStoreFreshness
    ) throws -> TrainingStoreSnapshot {
        let data: Data
        if let lastDurableData {
            data = lastDurableData
        } else {
            data = try encode(currentEnvelope())
        }
        return TrainingStoreSnapshot(
            sessions: sortedSessions(),
            generation: TrainingFingerprint.hex(data: data),
            integrity: integrity,
            freshness: freshness,
            capturedAt: try currentTime()
        )
    }

    /// Actor isolation protects one instance only. The process lock and the
    /// sidecar advisory lock cover the complete durable read/modify/replace
    /// transaction for all instances and cooperating processes.
    private func withPersistenceTransaction<T>(_ work: () throws -> T) throws -> T {
        Self.processTransactionLock.lock()
        defer { Self.processTransactionLock.unlock() }
        guard let persistenceURL else { return try work() }
        let lockURL = persistenceURL
            .deletingLastPathComponent()
            .appendingPathComponent(".\(persistenceURL.lastPathComponent).lock", isDirectory: false)
        let fileLock = try TrainingFileLock(url: lockURL, fileManager: fileManager)
        return try withExtendedLifetime(fileLock) {
            try work()
        }
    }

    private func reloadFromDiskLocked() throws {
        do {
            guard let persistenceURL else {
                if !hasLoaded {
                    sessionsByID = [:]
                    receiptsByMutationID = [:]
                    retiredMutationIDs = []
                    hasLoaded = true
                }
                loadFailure = nil
                preservedLedgerData = nil
                return
            }

            guard pathEntryExists(at: persistenceURL) else {
                guard !hasObservedDurableFile, lastDurableData == nil else {
                    throw TrainingStoreError.externalMutationConflict
                }
                sessionsByID = [:]
                receiptsByMutationID = [:]
                retiredMutationIDs = []
                lastDurableData = nil
                hasLoaded = true
                loadFailure = nil
                preservedLedgerData = nil
                return
            }

            // An unreadable or oversized path is still an observed durable
            // path. If it later disappears, that is an external mutation and
            // cannot be treated as first use.
            hasObservedDurableFile = true

            let data = try readDiskData(at: persistenceURL)
            let now = try currentTime()
            let decoded = try decodeEnvelope(data, now: now)
            let envelope: TrainingLedgerEnvelope
            let durableData: Data
            if decoded.requiresMigration {
                envelope = decoded.envelope
                durableData = try persistAndVerify(envelope, expectedPreviousData: data)
            } else {
                envelope = decoded.envelope
                durableData = data
            }
            sessionsByID = Dictionary(uniqueKeysWithValues: envelope.sessions.map { ($0.id, $0) })
            receiptsByMutationID = Dictionary(uniqueKeysWithValues: envelope.receipts.map { ($0.mutationID, $0) })
            retiredMutationIDs = Set(envelope.retiredMutationIDs)
            lastDurableData = durableData
            preservedLedgerData = nil
            loadFailure = nil
            hasLoaded = true
        } catch let error as TrainingStoreError {
            preserveLoadFailure(error)
            throw error
        } catch {
            preserveLoadFailure(.corruptLedger)
            throw TrainingStoreError.corruptLedger
        }
    }

    private func preserveLoadFailure(_ error: TrainingStoreError) {
        loadFailure = error
        // Re-open through the same bounded descriptor reader used for normal
        // reads. A pathname size check followed by `contents(atPath:)` would
        // allow a replacement or growth race to allocate without the ledger
        // bound while attempting to preserve recovery bytes.
        preservedLedgerData = persistenceURL.flatMap { try? readDiskData(at: $0) }
        // A prior valid in-memory state stays available to diagnostics, but
        // mutation entry points remain blocked until the file is recovered.
        // Mark even an initially failed load as attempted so subsequent reads
        // fail with the integrity-blocked state instead of retrying forever.
        hasLoaded = true
    }

    private func decodeEnvelope(_ data: Data, now: Date) throws -> (envelope: TrainingLedgerEnvelope, requiresMigration: Bool) {
        let probeDecoder = TrainingDateCoding.makeDecoder(now: now)
        let probe: TrainingSchemaProbe
        do {
            probe = try probeDecoder.decode(TrainingSchemaProbe.self, from: data)
        } catch {
            throw TrainingStoreError.corruptLedger
        }
        switch probe.schemaVersion {
        case 1:
            do {
                let legacy = try makeLegacyDecoder(now: now).decode(LegacyTrainingLedgerEnvelope.self, from: data)
                guard legacy.schemaVersion == 1 else { throw TrainingStoreError.corruptLedger }
                guard !legacy.hasQueuedMutations else { throw TrainingStoreError.legacyQueueDataPresent }
                let envelope = TrainingLedgerEnvelope(
                    sessions: legacy.sessions,
                    receipts: try legacy.receipts.map { try $0.migrated() },
                    retiredMutationIDs: []
                )
                try envelope.validate(now: now)
                return (envelope, true)
            } catch let error as TrainingStoreError {
                throw error
            } catch {
                throw TrainingStoreError.corruptLedger
            }
        case TrainingLedgerEnvelope.currentSchemaVersion:
            do {
                let envelope = try TrainingDateCoding.makeDecoder(now: now).decode(TrainingLedgerEnvelope.self, from: data)
                try envelope.validate(now: now)
                return (envelope, false)
            } catch let error as TrainingStoreError {
                throw error
            } catch {
                throw TrainingStoreError.corruptLedger
            }
        default:
            throw TrainingStoreError.unsupportedSchema(probe.schemaVersion)
        }
    }

    private func makeLegacyDecoder(now: Date) -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .custom { decoder in
            let container = try decoder.singleValueContainer()
            let string = try container.decode(String.self)
            let fractional = Date.ISO8601FormatStyle(includingFractionalSeconds: true)
            let plain = Date.ISO8601FormatStyle(includingFractionalSeconds: false)
            let date = (try? fractional.parse(string)) ?? (try? plain.parse(string))
            guard let date,
                  date.timeIntervalSinceReferenceDate.isFinite else {
                throw DecodingError.dataCorrupted(.init(
                    codingPath: decoder.codingPath,
                    debugDescription: "Invalid schema-1 ISO-8601 training date"
                ))
            }
            return date
        }
        decoder.userInfo[.trainingValidationNow] = now
        return decoder
    }

    private func makeEncoder() -> JSONEncoder {
        TrainingDateCoding.makeEncoder()
    }

    private func encode(_ envelope: TrainingLedgerEnvelope) throws -> Data {
        try envelope.validate(now: try currentTime())
        do {
            let data = try makeEncoder().encode(envelope)
            try TrainingStoreLimits.validateEncodedLedgerBytes(data)
            return data
        } catch let error as TrainingStoreError {
            throw error
        } catch {
            throw TrainingStoreError.persistenceFailed
        }
    }

    private func persistAndVerify(_ envelope: TrainingLedgerEnvelope, expectedPreviousData: Data? = nil) throws -> Data {
        let data = try encode(envelope)
        guard let persistenceURL else {
            return data
        }

        let previousData: Data?
        if pathEntryExists(at: persistenceURL) {
            // An existing but unreadable target is not equivalent to an
            // absent target. Abort before replacement so its bytes remain the
            // only recovery material available to the caller.
            previousData = try readDiskData(at: persistenceURL)
        } else {
            previousData = nil
        }

        let expected = expectedPreviousData ?? lastDurableData
        if let expected, previousData != expected {
            throw TrainingStoreError.externalMutationConflict
        }

        do {
            try replaceData(data, at: persistenceURL, invokeHooks: true)
            let readback = try readDiskData(at: persistenceURL)
            guard readback == data else { throw TrainingStoreError.readbackValidationFailed }
            _ = try decodeEnvelope(readback, now: try currentTime())
            return readback
        } catch let error as TrainingStoreError {
            do {
                try restore(previousData, at: persistenceURL)
            } catch {
                markIntegrityBlocked(previousData: previousData)
                throw TrainingStoreError.integrityUnavailable
            }
            throw error
        } catch {
            do {
                try restore(previousData, at: persistenceURL)
            } catch {
                markIntegrityBlocked(previousData: previousData)
                throw TrainingStoreError.integrityUnavailable
            }
            throw TrainingStoreError.persistenceFailed
        }
    }

    private func restore(_ data: Data?, at url: URL) throws {
        try beforeRestore?()
        if let data {
            try replaceData(data, at: url, invokeHooks: false)
            guard try readDiskData(at: url) == data else { throw TrainingStoreError.readbackValidationFailed }
        } else if pathEntryExists(at: url) {
            try fileManager.removeItem(at: url)
        }
        guard !pathEntryExists(at: url) || data != nil else {
            throw TrainingStoreError.readbackValidationFailed
        }
    }

    private func replaceData(_ data: Data, at url: URL, invokeHooks: Bool) throws {
        let directory = url.deletingLastPathComponent()
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true, attributes: nil)
        let temporary = directory.appendingPathComponent(".\(url.lastPathComponent).\(UUID().uuidString).tmp", isDirectory: false)
        defer {
            if pathEntryExists(at: temporary) {
                try? fileManager.removeItem(at: temporary)
            }
        }

        try data.write(to: temporary, options: Self.writeOptions)
        if invokeHooks { try beforeReplace?() }
        if pathEntryExists(at: url) {
            _ = try fileManager.replaceItemAt(url, withItemAt: temporary)
        } else {
            try fileManager.moveItem(at: temporary, to: url)
        }
#if os(macOS)
        try fileManager.setAttributes([.posixPermissions: NSNumber(value: 0o600)], ofItemAtPath: url.path)
#endif
        if invokeHooks { try afterReplace?() }
    }

    private func markIntegrityBlocked(previousData: Data?) {
        loadFailure = .integrityUnavailable
        hasLoaded = true
        if persistenceURL != nil { hasObservedDurableFile = true }
        preservedLedgerData = previousData
    }

    private func readDiskData(at url: URL) throws -> Data {
#if canImport(Darwin)
        var pathInfo = stat()
        guard url.path.withCString({ lstat($0, &pathInfo) == 0 }) else {
            throw TrainingStoreError.unreadableLedger
        }
        guard (pathInfo.st_mode & S_IFMT) == S_IFREG else {
            throw TrainingStoreError.unreadableLedger
        }

        let descriptor = url.path.withCString { path in
            Darwin.open(path, O_RDONLY | O_NOFOLLOW)
        }
        guard descriptor >= 0 else { throw TrainingStoreError.unreadableLedger }
        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        defer { try? handle.close() }

        var openedInfo = stat()
        guard fstat(descriptor, &openedInfo) == 0,
              (openedInfo.st_mode & S_IFMT) == S_IFREG,
              openedInfo.st_dev == pathInfo.st_dev,
              openedInfo.st_ino == pathInfo.st_ino else {
            throw TrainingStoreError.externalMutationConflict
        }
        let initialSize = Int64(openedInfo.st_size)
        guard initialSize >= 0 else { throw TrainingStoreError.unreadableLedger }
        guard initialSize <= Int64(TrainingStoreLimits.maximumLedgerBytes) else {
            throw TrainingStoreError.ledgerTooLarge
        }

        var data = Data()
        data.reserveCapacity(Int(initialSize))
        while true {
            let remaining = TrainingStoreLimits.maximumLedgerBytes - data.count
            let requestSize = min(1_024 * 1_024, remaining + 1)
            let chunk = try handle.read(upToCount: requestSize) ?? Data()
            if chunk.isEmpty { break }
            guard chunk.count <= remaining else { throw TrainingStoreError.ledgerTooLarge }
            data.append(chunk)
        }

        var finalDescriptorInfo = stat()
        guard fstat(descriptor, &finalDescriptorInfo) == 0,
              (finalDescriptorInfo.st_mode & S_IFMT) == S_IFREG,
              finalDescriptorInfo.st_dev == openedInfo.st_dev,
              finalDescriptorInfo.st_ino == openedInfo.st_ino,
              Int64(finalDescriptorInfo.st_size) == Int64(data.count) else {
            throw TrainingStoreError.externalMutationConflict
        }

        var finalPathInfo = stat()
        guard url.path.withCString({ lstat($0, &finalPathInfo) == 0 }),
              (finalPathInfo.st_mode & S_IFMT) == S_IFREG,
              finalPathInfo.st_dev == finalDescriptorInfo.st_dev,
              finalPathInfo.st_ino == finalDescriptorInfo.st_ino else {
            throw TrainingStoreError.externalMutationConflict
        }
        return data
#else
        throw TrainingStoreError.unreadableLedger
#endif
    }

    private func normalizedRecoveryDestination(_ url: URL) -> URL? {
        guard url.isFileURL else { return nil }
        let standardized = url.standardizedFileURL
        guard !standardized.path.isEmpty,
              !isSymbolicLink(at: standardized),
              !isSymbolicLink(at: standardized.deletingLastPathComponent()) else {
            return nil
        }
        return standardized
    }

    private func writeRecoveryData(_ data: Data, to destination: URL) throws {
        guard data.count <= TrainingStoreLimits.maximumLedgerBytes,
              normalizedRecoveryDestination(destination) == destination else {
            throw TrainingStoreError.persistenceFailed
        }
        try replaceData(data, at: destination, invokeHooks: false)
    }

    /// Copies at most the bounded recovery size using a descriptor and fixed
    /// chunks. `O_NOFOLLOW` and `fstat` keep the source check attached to the
    /// opened file rather than to a path that can be swapped underneath it.
    private func copyRecoveryFile(from source: URL, to destination: URL) throws {
        guard source.isFileURL,
              destination.isFileURL,
              source.standardizedFileURL != destination.standardizedFileURL,
              !isSymbolicLink(at: source),
              normalizedRecoveryDestination(destination) == destination else {
            throw TrainingStoreError.persistenceFailed
        }

#if canImport(Darwin)
        let sourceDescriptor = source.path.withCString { path in
            Darwin.open(path, O_RDONLY | O_NOFOLLOW)
        }
        guard sourceDescriptor >= 0 else { throw TrainingStoreError.unreadableLedger }
        let sourceHandle = FileHandle(fileDescriptor: sourceDescriptor, closeOnDealloc: true)
        var sourceInfo = stat()
        guard fstat(sourceDescriptor, &sourceInfo) == 0,
              (sourceInfo.st_mode & S_IFMT) == S_IFREG else {
            try? sourceHandle.close()
            throw TrainingStoreError.unreadableLedger
        }
        let sourceSize = Int64(sourceInfo.st_size)
        guard sourceSize >= 0,
              sourceSize <= Int64(TrainingStoreLimits.maximumRecoveryExportBytes) else {
            try? sourceHandle.close()
            throw TrainingStoreError.ledgerTooLarge
        }

        let directory = destination.deletingLastPathComponent()
        do {
            try fileManager.createDirectory(at: directory, withIntermediateDirectories: true, attributes: nil)
        } catch {
            try? sourceHandle.close()
            throw TrainingStoreError.persistenceFailed
        }
        let temporary = directory.appendingPathComponent(".\(destination.lastPathComponent).\(UUID().uuidString).tmp", isDirectory: false)
        let destinationDescriptor = temporary.path.withCString { path in
            Darwin.open(path, O_WRONLY | O_CREAT | O_EXCL, mode_t(0o600))
        }
        guard destinationDescriptor >= 0 else {
            try? sourceHandle.close()
            throw TrainingStoreError.persistenceFailed
        }
        let destinationHandle = FileHandle(fileDescriptor: destinationDescriptor, closeOnDealloc: true)
        defer {
            try? sourceHandle.close()
            try? destinationHandle.close()
            if pathEntryExists(at: temporary) { try? fileManager.removeItem(at: temporary) }
        }

        var copiedBytes: Int64 = 0
        while copiedBytes < sourceSize {
            let requestSize = Int(min(Int64(1_024 * 1_024), sourceSize - copiedBytes))
            let chunk = try destinationSafeRead(sourceHandle, count: requestSize)
            guard !chunk.isEmpty,
                  Int64(chunk.count) <= sourceSize - copiedBytes else {
                throw TrainingStoreError.unreadableLedger
            }
            try destinationHandle.write(contentsOf: chunk)
            copiedBytes += Int64(chunk.count)
        }

        var finalSourceInfo = stat()
        guard fstat(sourceDescriptor, &finalSourceInfo) == 0,
              Int64(finalSourceInfo.st_size) == sourceSize else {
            throw TrainingStoreError.externalMutationConflict
        }
        try destinationHandle.synchronize()
        try destinationHandle.close()
        try sourceHandle.close()
        guard !isSymbolicLink(at: destination) else { throw TrainingStoreError.persistenceFailed }
        if pathEntryExists(at: destination) {
            _ = try fileManager.replaceItemAt(destination, withItemAt: temporary)
        } else {
            try fileManager.moveItem(at: temporary, to: destination)
        }
#if os(macOS)
        try fileManager.setAttributes([.posixPermissions: NSNumber(value: 0o600)], ofItemAtPath: destination.path)
#endif
#else
        guard let attributes = try? fileManager.attributesOfItem(atPath: source.path),
              let size = attributes[.size] as? NSNumber,
              size.intValue >= 0,
              size.intValue <= TrainingStoreLimits.maximumRecoveryExportBytes,
              !isSymbolicLink(at: source) else {
            throw TrainingStoreError.ledgerTooLarge
        }
        throw TrainingStoreError.persistenceFailed
#endif
    }

#if canImport(Darwin)
    private func destinationSafeRead(_ handle: FileHandle, count: Int) throws -> Data {
        try handle.read(upToCount: count) ?? Data()
    }
#endif

    private func pathEntryExists(at url: URL) -> Bool {
#if canImport(Darwin)
        var info = stat()
        return url.path.withCString { lstat($0, &info) == 0 }
#else
        return fileManager.fileExists(atPath: url.path)
#endif
    }

    private func isSymbolicLink(at url: URL) -> Bool {
#if canImport(Darwin)
        var info = stat()
        return url.path.withCString {
            lstat($0, &info) == 0 && (info.st_mode & S_IFMT) == S_IFLNK
        }
#else
        guard let type = try? fileManager.attributesOfItem(atPath: url.path)[.type] as? FileAttributeType else {
            return false
        }
        return type == .typeSymbolicLink
#endif
    }

    private func currentEnvelope() throws -> TrainingLedgerEnvelope {
        TrainingLedgerEnvelope(
            sessions: sortedSessions(),
            receipts: receiptsByMutationID.values.sorted { $0.mutationID.rawValue < $1.mutationID.rawValue },
            retiredMutationIDs: retiredMutationIDs.sorted { $0.rawValue < $1.rawValue }
        )
    }

    private func nextRevision(after revision: Int) throws -> Int {
        guard revision >= 0, revision < Int.max - 1 else {
            throw TrainingStoreError.revisionExhausted
        }
        return revision + 1
    }

    private func sortedSessions() -> [TrainingSession] {
        sessionsByID.values.sorted {
            if $0.startedAt != $1.startedAt { return $0.startedAt < $1.startedAt }
            return $0.id.rawValue < $1.id.rawValue
        }
    }

    private func currentTime() throws -> Date {
        let now = clock()
        guard now.timeIntervalSinceReferenceDate.isFinite else {
            throw TrainingStoreError.invalidClock
        }
        return now
    }

    private static var writeOptions: Data.WritingOptions {
#if os(iOS)
        [.atomic, .completeFileProtection]
#else
        [.atomic]
#endif
    }
}
