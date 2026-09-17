import Foundation

// MARK: - Durable local storage for manually imported bank-statement transactions

public enum FinanceImportedTransactionStoreError: Error, Equatable, Sendable {
    case applicationSupportUnavailable
    case readFailed
    case invalidEnvelope
    /// A persisted import was produced by the pre-v3 mapped identity scheme.
    /// It must be reconciled before a v3 import can create another row.
    case migrationRequired
    case writeFailed
    case transactionNotFound
    case stateTooLarge
    case syncOutboxFull
    case syncPayloadTooLarge
    case syncRetryExpired
    case syncAttemptsExhausted
    case syncReceiptUnresolved
    case syncSnapshotRewound
    case syncSnapshotETagMismatch
}

public enum FinanceImportedSyncBlockReason: String, Codable, Equatable, Sendable, CaseIterable {
    case conflict
    case retryExpired
    case attemptsExhausted
    case payloadTooLarge
    case invalidEnvelope
}

public enum FinanceImportedPendingSyncState: String, Codable, Equatable, Sendable {
    case pending
    case blocked
}

public struct FinanceImportedSyncStatus: Equatable, Sendable {
    public let pendingEntryCount: Int
    public let blockedEntryCount: Int
    public let pendingOperationCount: Int
    public let blockedOperationCount: Int
    public let blockedReasons: [FinanceImportedSyncBlockReason]

    public init(
        pendingEntryCount: Int,
        blockedEntryCount: Int,
        pendingOperationCount: Int,
        blockedOperationCount: Int,
        blockedReasons: [FinanceImportedSyncBlockReason]
    ) {
        self.pendingEntryCount = pendingEntryCount
        self.blockedEntryCount = blockedEntryCount
        self.pendingOperationCount = pendingOperationCount
        self.blockedOperationCount = blockedOperationCount
        self.blockedReasons = blockedReasons
    }
}

extension FinanceImportedTransactionStoreError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .applicationSupportUnavailable: return "Local Finance import storage is unavailable."
        case .readFailed: return "Local Finance import storage could not be read."
        case .invalidEnvelope: return "Local Finance import storage is invalid and was not loaded."
        case .migrationRequired: return "This Finance import needs one-time identity migration before it can be imported again."
        case .writeFailed: return "Imported transaction changes could not be saved."
        case .transactionNotFound: return "The imported transaction to remove was not found."
        case .stateTooLarge: return "The imported Finance ledger exceeds its safe storage limit."
        case .syncOutboxFull: return "Imported Finance changes are waiting for sync. The bounded outbox is full."
        case .syncPayloadTooLarge: return "The imported Finance sync payload exceeds its safe size."
        case .syncRetryExpired: return "An imported Finance sync change is too old to retry safely."
        case .syncAttemptsExhausted: return "An imported Finance sync change needs manual recovery after repeated failures."
        case .syncReceiptUnresolved: return "A previous Finance sync could not be proven safe to replay, so the change was paused."
        case .syncSnapshotRewound: return "The gateway returned an older Finance snapshot."
        case .syncSnapshotETagMismatch: return "The gateway returned conflicting Finance revision metadata."
        }
    }
}

/// Result of a local import write. Source corrections are reported as
/// updates, while stable-ID reimports are reported as duplicates.
public struct FinanceImportSaveResult: Equatable, Sendable {
    public let requestedCount: Int
    public let insertedCount: Int
    public let updatedCount: Int
    public let duplicateCount: Int
    public let storedCount: Int

    public init(
        requestedCount: Int,
        insertedCount: Int,
        updatedCount: Int = 0,
        duplicateCount: Int,
        storedCount: Int
    ) {
        self.requestedCount = max(requestedCount, 0)
        self.insertedCount = max(insertedCount, 0)
        self.updatedCount = max(updatedCount, 0)
        self.duplicateCount = max(duplicateCount, 0)
        self.storedCount = max(storedCount, 0)
    }
}

/// The immutable request that was (or is about to be) transmitted. Keeping
/// the exact bytes and headers makes a timeout/relaunch retry the same
/// operation, even if a later fetch observes a newer authority revision.
public struct FinanceImportedAttemptedSyncRequest: Codable, Equatable, Sendable {
    public static let maximumBodyBytes = FinanceImportedSyncRequest.maximumRequestBytes

    public let baseRevision: Int
    public let ifMatch: String
    public let idempotencyKey: String
    public let body: Data

    private enum CodingKeys: String, CodingKey, CaseIterable { case baseRevision, ifMatch, idempotencyKey, body }

    public init(baseRevision: Int, ifMatch: String, idempotencyKey: String, body: Data) throws {
        guard baseRevision >= 0,
              baseRevision <= FinanceImportedSyncRecord.maximumSafeCents,
              TailscaleSyncClient.validatedFinanceImportedETag(ifMatch) != nil,
              TailscaleSyncClient.financeImportedETagRevision(ifMatch) == baseRevision,
              TailscaleSyncClient.validatedFinanceImportedIdempotencyKey(idempotencyKey) != nil,
              body.count <= Self.maximumBodyBytes else {
            throw FinanceImportedTransactionStoreError.invalidEnvelope
        }
        do {
            let request = try JSONDecoder.lifeOS.decode(FinanceImportedSyncRequest.self, from: body)
            let currentCanonical = try request.canonicalData()
            var acceptedCanonical = currentCanonical == body
            if !acceptedCanonical, let legacyIdentityCanonical = try? request.legacyIdentityCanonicalData() {
                acceptedCanonical = legacyIdentityCanonical == body
            }
            guard request.baseRevision == baseRevision,
                  acceptedCanonical else {
                throw FinanceImportedTransactionStoreError.invalidEnvelope
            }
        } catch let error as FinanceImportedTransactionStoreError {
            throw error
        } catch {
            throw FinanceImportedTransactionStoreError.invalidEnvelope
        }
        self.baseRevision = baseRevision
        self.ifMatch = ifMatch
        self.idempotencyKey = idempotencyKey
        self.body = body
    }

    public init(from decoder: Decoder) throws {
        try rejectUnknownLifeOSKeys(decoder, allowed: Set(CodingKeys.allCases.map(\.stringValue)))
        let container = try decoder.container(keyedBy: CodingKeys.self)
        guard Set(container.allKeys) == Set(CodingKeys.allCases) else {
            throw FinanceImportedTransactionStoreError.invalidEnvelope
        }
        try self.init(
            baseRevision: container.decode(Int.self, forKey: .baseRevision),
            ifMatch: container.decode(String.self, forKey: .ifMatch),
            idempotencyKey: container.decode(String.self, forKey: .idempotencyKey),
            body: container.decode(Data.self, forKey: .body)
        )
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(baseRevision, forKey: .baseRevision)
        try container.encode(ifMatch, forKey: .ifMatch)
        try container.encode(idempotencyKey, forKey: .idempotencyKey)
        try container.encode(body, forKey: .body)
    }

    public func decodedRequest() throws -> FinanceImportedSyncRequest {
        do {
            return try JSONDecoder.lifeOS.decode(FinanceImportedSyncRequest.self, from: body)
        } catch {
            throw FinanceImportedTransactionStoreError.invalidEnvelope
        }
    }
}

/// One durable outbox entry. The attempted request is immutable after the
/// first attempt. A conflict may replace the unattempted logical envelope
/// with a safe rebase, but it never resets attemptCount.
fileprivate struct FinanceImportedSupersededAttemptReceipt: Codable, Equatable, Sendable {
    let idempotencyKey: String
    let recordIDs: [UUID]

    private enum CodingKeys: String, CodingKey, CaseIterable {
        case idempotencyKey, recordIDs
    }

    init(idempotencyKey: String, recordIDs: [UUID]) throws {
        guard TailscaleSyncClient.validatedFinanceImportedIdempotencyKey(idempotencyKey) != nil,
              recordIDs.count <= FinanceImportedSyncRequest.maximumOperations,
              Set(recordIDs).count == recordIDs.count else {
            throw FinanceImportedTransactionStoreError.invalidEnvelope
        }
        self.idempotencyKey = idempotencyKey
        self.recordIDs = recordIDs
    }

    init(from decoder: Decoder) throws {
        try rejectUnknownLifeOSKeys(decoder, allowed: Set(CodingKeys.allCases.map(\.stringValue)))
        let container = try decoder.container(keyedBy: CodingKeys.self)
        guard Set(container.allKeys) == Set(CodingKeys.allCases) else {
            throw FinanceImportedTransactionStoreError.invalidEnvelope
        }
        try self.init(
            idempotencyKey: container.decode(String.self, forKey: .idempotencyKey),
            recordIDs: container.decode([UUID].self, forKey: .recordIDs)
        )
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(idempotencyKey, forKey: .idempotencyKey)
        try container.encode(recordIDs, forKey: .recordIDs)
    }
}

public struct FinanceImportedPendingSyncEntry: Codable, Equatable, Sendable {
    public static let maximumOperations = 512
    public static let maximumAttempts = 32
    fileprivate static let maximumSupersededAttemptReceipts = 4

    public let idempotencyKey: String
    public let operations: [FinanceImportedSyncOperation]
    public let createdAt: Date
    public var attemptCount: Int
    public var lastAttemptAt: Date?
    public var state: FinanceImportedPendingSyncState
    public var blockedReason: FinanceImportedSyncBlockReason?
    public var attemptedRequest: FinanceImportedAttemptedSyncRequest?
    /// Receipts for requests whose payload was removed by clear-all while
    /// transmission was in progress. These carry no merchant payload; the
    /// record IDs bind a late response to only the corresponding delete
    /// preconditions.
    fileprivate var supersededAttemptReceipts: [FinanceImportedSupersededAttemptReceipt]

    private enum CodingKeys: String, CodingKey, CaseIterable {
        case idempotencyKey, operations, createdAt, attemptCount, lastAttemptAt
        case state, blockedReason, attemptedRequest, supersededAttemptKeys
    }

    public init(
        idempotencyKey: String,
        operations: [FinanceImportedSyncOperation],
        createdAt: Date = .now,
        attemptCount: Int = 0,
        lastAttemptAt: Date? = nil,
        state: FinanceImportedPendingSyncState = .pending,
        blockedReason: FinanceImportedSyncBlockReason? = nil,
        attemptedRequest: FinanceImportedAttemptedSyncRequest? = nil
    ) throws {
        guard TailscaleSyncClient.validatedFinanceImportedIdempotencyKey(idempotencyKey) != nil,
              !operations.isEmpty,
              operations.count <= Self.maximumOperations,
              (0...Self.maximumAttempts).contains(attemptCount),
              Set(operations.map(\.recordID)).count == operations.count,
              createdAt.timeIntervalSinceNow <= 5,
              lastAttemptAt == nil || lastAttemptAt!.timeIntervalSince(createdAt) >= 0,
              lastAttemptAt == nil || lastAttemptAt!.timeIntervalSinceNow <= 5,
              (state == .blocked) == (blockedReason != nil),
              attemptedRequest == nil || attemptedRequest!.idempotencyKey == idempotencyKey else {
            throw FinanceImportedTransactionStoreError.invalidEnvelope
        }
        self.idempotencyKey = idempotencyKey
        self.operations = operations
        self.createdAt = createdAt
        self.attemptCount = attemptCount
        self.lastAttemptAt = lastAttemptAt
        self.state = state
        self.blockedReason = blockedReason
        self.attemptedRequest = attemptedRequest
        self.supersededAttemptReceipts = []
    }

    fileprivate init(
        idempotencyKey: String,
        operations: [FinanceImportedSyncOperation],
        createdAt: Date = .now,
        attemptCount: Int = 0,
        lastAttemptAt: Date? = nil,
        state: FinanceImportedPendingSyncState = .pending,
        blockedReason: FinanceImportedSyncBlockReason? = nil,
        attemptedRequest: FinanceImportedAttemptedSyncRequest? = nil,
        supersededAttemptReceipts: [FinanceImportedSupersededAttemptReceipt]
    ) throws {
        try self.init(
            idempotencyKey: idempotencyKey,
            operations: operations,
            createdAt: createdAt,
            attemptCount: attemptCount,
            lastAttemptAt: lastAttemptAt,
            state: state,
            blockedReason: blockedReason,
            attemptedRequest: attemptedRequest
        )
        try setSupersededAttemptReceipts(supersededAttemptReceipts)
    }

    fileprivate mutating func setSupersededAttemptReceipts(
        _ receipts: [FinanceImportedSupersededAttemptReceipt]
    ) throws {
        let keys = receipts.map(\.idempotencyKey)
        let recordIDCount = receipts.reduce(into: 0) { $0 += $1.recordIDs.count }
        guard receipts.count <= Self.maximumSupersededAttemptReceipts,
              recordIDCount <= Self.maximumOperations * Self.maximumSupersededAttemptReceipts,
              Set(keys).count == keys.count,
              !keys.contains(idempotencyKey) else {
            throw FinanceImportedTransactionStoreError.invalidEnvelope
        }
        supersededAttemptReceipts = receipts
    }

    public init(from decoder: Decoder) throws {
        try rejectUnknownLifeOSKeys(decoder, allowed: Set(CodingKeys.allCases.map(\.stringValue)))
        let container = try decoder.container(keyedBy: CodingKeys.self)
        // Schema 2 entries predate the v3 retry metadata. Keep their durable
        // logical work and initialize the new counters instead of making a
        // readable local ledger unavailable during migration.
        let required = Set([CodingKeys.idempotencyKey, .operations, .createdAt])
        guard required.isSubset(of: Set(container.allKeys)) else {
            throw FinanceImportedTransactionStoreError.invalidEnvelope
        }
        let receipts: [FinanceImportedSupersededAttemptReceipt]
        if let decoded = try? container.decode(
            [FinanceImportedSupersededAttemptReceipt].self,
            forKey: .supersededAttemptKeys
        ) {
            receipts = decoded
        } else if let legacyKeys = try? container.decode([String].self, forKey: .supersededAttemptKeys) {
            receipts = try legacyKeys.map {
                try FinanceImportedSupersededAttemptReceipt(idempotencyKey: $0, recordIDs: [])
            }
        } else if container.contains(.supersededAttemptKeys) {
            throw FinanceImportedTransactionStoreError.invalidEnvelope
        } else {
            receipts = []
        }
        try self.init(
            idempotencyKey: container.decode(String.self, forKey: .idempotencyKey),
            operations: container.decode([FinanceImportedSyncOperation].self, forKey: .operations),
            createdAt: container.decode(Date.self, forKey: .createdAt),
            attemptCount: container.decodeIfPresent(Int.self, forKey: .attemptCount) ?? 0,
            lastAttemptAt: container.decodeIfPresent(Date.self, forKey: .lastAttemptAt),
            state: container.decodeIfPresent(FinanceImportedPendingSyncState.self, forKey: .state) ?? .pending,
            blockedReason: container.decodeIfPresent(FinanceImportedSyncBlockReason.self, forKey: .blockedReason),
            attemptedRequest: container.decodeIfPresent(FinanceImportedAttemptedSyncRequest.self, forKey: .attemptedRequest),
            supersededAttemptReceipts: receipts
        )
    }

    public func encode(to encoder: Encoder) throws {
        guard !operations.contains(where: { $0.isLegacy }) else {
            throw FinanceImportedTransactionStoreError.invalidEnvelope
        }
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(idempotencyKey, forKey: .idempotencyKey)
        try container.encode(operations, forKey: .operations)
        try container.encode(createdAt, forKey: .createdAt)
        try container.encode(attemptCount, forKey: .attemptCount)
        try container.encode(lastAttemptAt, forKey: .lastAttemptAt)
        try container.encode(state, forKey: .state)
        try container.encode(blockedReason, forKey: .blockedReason)
        try container.encode(attemptedRequest, forKey: .attemptedRequest)
        try container.encode(supersededAttemptReceipts, forKey: .supersededAttemptKeys)
    }
}

public struct FinanceImportedPendingSyncRequest: Equatable, Sendable {
    public let request: FinanceImportedSyncRequest
    public let body: Data
    public let ifMatch: String
    public let idempotencyKey: String

    public init(request: FinanceImportedSyncRequest, body: Data, ifMatch: String, idempotencyKey: String) {
        self.request = request
        self.body = body
        self.ifMatch = ifMatch
        self.idempotencyKey = idempotencyKey
    }
}

/// Version 3 adds per-record authority metadata, tombstone metadata, and
/// immutable attempted envelopes. Version 4 adds local-only mapping and
/// import provenance metadata. Versions 1–3 are decoded only to run a
/// one-time explicit migration; unknown versions fail closed.
public struct FinanceImportedTransactionStoreEnvelope: Codable, Equatable, Sendable {
    public static let legacySchemaVersion = 1
    public static let previousSchemaVersion = 2
    public static let preProvenanceSchemaVersion = 3
    public static let currentSchemaVersion = 4

    public let schemaVersion: Int
    public let transactions: [FinanceImportedTransaction]
    public let remoteRevision: Int
    public let remoteETag: String?
    public let remoteRecordRevisions: [String: Int]
    public let remoteTombstones: [FinanceImportedSyncTombstone]
    public let outbox: [FinanceImportedPendingSyncEntry]
    public let importMappings: [FinanceImportMapping]
    public let importBatches: [FinanceImportBatchProvenance]
    /// Local-only fence for mappings decoded from the legacy mapped-v2
    /// identity scheme. The marker is deliberately kept outside the mapping
    /// payload so older mapping decoders can still be read without silently
    /// losing the migration requirement.
    public let legacyIdentityMappingIDs: [UUID]
    /// Local-only fence for generic CSV rows written before reviewed import
    /// provenance existed. Their historical v2 IDs cannot be safely matched
    /// to the account-scoped mapped-v3 IDs, so a new mapped import must stop
    /// until the user explicitly reconciles or clears those rows.
    public let legacyGenericTransactionIDs: [UUID]

    private enum CodingKeys: String, CodingKey, CaseIterable {
        case schemaVersion, transactions, remoteRevision, remoteETag
        case remoteRecordRevisions, remoteTombstones, outbox
        case importMappings, importBatches, legacyIdentityMappingIDs, legacyGenericTransactionIDs
    }

    public init(
        transactions: [FinanceImportedTransaction] = [],
        remoteRevision: Int = 0,
        remoteETag: String? = nil,
        remoteRecordRevisions: [String: Int] = [:],
        remoteTombstones: [FinanceImportedSyncTombstone] = [],
        outbox: [FinanceImportedPendingSyncEntry] = [],
        importMappings: [FinanceImportMapping] = [],
        importBatches: [FinanceImportBatchProvenance] = [],
        legacyIdentityMappingIDs: [UUID] = [],
        legacyGenericTransactionIDs: [UUID] = []
    ) {
        schemaVersion = Self.currentSchemaVersion
        self.transactions = transactions
        self.remoteRevision = remoteRevision
        self.remoteETag = remoteETag
        self.remoteRecordRevisions = remoteRecordRevisions
        self.remoteTombstones = remoteTombstones
        self.outbox = outbox
        self.importMappings = importMappings
        self.importBatches = importBatches
        self.legacyIdentityMappingIDs = legacyIdentityMappingIDs
        self.legacyGenericTransactionIDs = legacyGenericTransactionIDs
    }

    public init(from decoder: Decoder) throws {
        try rejectUnknownLifeOSKeys(decoder, allowed: Set(CodingKeys.allCases.map(\.stringValue)))
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let schemaVersion = try container.decode(Int.self, forKey: .schemaVersion)
        switch schemaVersion {
        case Self.legacySchemaVersion:
            guard Set(container.allKeys) == Set([CodingKeys.schemaVersion, .transactions]) else {
                throw FinanceImportedTransactionStoreError.invalidEnvelope
            }
            self.schemaVersion = schemaVersion
            transactions = try container.decode([FinanceImportedTransaction].self, forKey: .transactions)
            remoteRevision = 0
            remoteETag = nil
            remoteRecordRevisions = [:]
            remoteTombstones = []
            outbox = []
            importMappings = []
            importBatches = []
            legacyIdentityMappingIDs = []
            legacyGenericTransactionIDs = []
        case Self.previousSchemaVersion:
            guard Set(container.allKeys) == Set([CodingKeys.schemaVersion, .transactions, .remoteRevision, .remoteETag, .outbox]) else {
                throw FinanceImportedTransactionStoreError.invalidEnvelope
            }
            self.schemaVersion = schemaVersion
            transactions = try container.decode([FinanceImportedTransaction].self, forKey: .transactions)
            remoteRevision = try container.decode(Int.self, forKey: .remoteRevision)
            remoteETag = try container.decodeIfPresent(String.self, forKey: .remoteETag)
            remoteRecordRevisions = [:]
            remoteTombstones = []
            outbox = try container.decode([FinanceImportedPendingSyncEntry].self, forKey: .outbox)
            importMappings = []
            importBatches = []
            legacyIdentityMappingIDs = []
            legacyGenericTransactionIDs = []
        case Self.preProvenanceSchemaVersion:
            guard Set(container.allKeys) == Set([
                CodingKeys.schemaVersion, .transactions, .remoteRevision, .remoteETag,
                .remoteRecordRevisions, .remoteTombstones, .outbox
            ]) else {
                throw FinanceImportedTransactionStoreError.invalidEnvelope
            }
            self.schemaVersion = schemaVersion
            transactions = try container.decode([FinanceImportedTransaction].self, forKey: .transactions)
            remoteRevision = try container.decode(Int.self, forKey: .remoteRevision)
            remoteETag = try container.decodeIfPresent(String.self, forKey: .remoteETag)
            remoteRecordRevisions = try container.decode([String: Int].self, forKey: .remoteRecordRevisions)
            remoteTombstones = try container.decode([FinanceImportedSyncTombstone].self, forKey: .remoteTombstones)
            outbox = try container.decode([FinanceImportedPendingSyncEntry].self, forKey: .outbox)
            importMappings = []
            importBatches = []
            legacyIdentityMappingIDs = []
            legacyGenericTransactionIDs = []
        case Self.currentSchemaVersion:
            let optionalKeys: Set<CodingKeys> = [.legacyIdentityMappingIDs, .legacyGenericTransactionIDs]
            let requiredKeys = Set(CodingKeys.allCases).subtracting(optionalKeys)
            guard requiredKeys.isSubset(of: Set(container.allKeys)),
                  Set(container.allKeys).isSubset(of: Set(CodingKeys.allCases)) else {
                throw FinanceImportedTransactionStoreError.invalidEnvelope
            }
            self.schemaVersion = schemaVersion
            transactions = try container.decode([FinanceImportedTransaction].self, forKey: .transactions)
            remoteRevision = try container.decode(Int.self, forKey: .remoteRevision)
            remoteETag = try container.decodeIfPresent(String.self, forKey: .remoteETag)
            remoteRecordRevisions = try container.decode([String: Int].self, forKey: .remoteRecordRevisions)
            remoteTombstones = try container.decode([FinanceImportedSyncTombstone].self, forKey: .remoteTombstones)
            outbox = try container.decode([FinanceImportedPendingSyncEntry].self, forKey: .outbox)
            importMappings = try container.decode([FinanceImportMapping].self, forKey: .importMappings)
            importBatches = try container.decode([FinanceImportBatchProvenance].self, forKey: .importBatches)
            legacyIdentityMappingIDs = try container.decodeIfPresent([UUID].self, forKey: .legacyIdentityMappingIDs) ?? []
            legacyGenericTransactionIDs = try container.decodeIfPresent([UUID].self, forKey: .legacyGenericTransactionIDs) ?? []
        default:
            throw FinanceImportedTransactionStoreError.invalidEnvelope
        }
    }

    public func encode(to encoder: Encoder) throws {
        guard schemaVersion == Self.currentSchemaVersion else { throw FinanceImportedTransactionStoreError.invalidEnvelope }
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(schemaVersion, forKey: .schemaVersion)
        try container.encode(transactions, forKey: .transactions)
        try container.encode(remoteRevision, forKey: .remoteRevision)
        try container.encode(remoteETag, forKey: .remoteETag)
        try container.encode(remoteRecordRevisions, forKey: .remoteRecordRevisions)
        try container.encode(remoteTombstones, forKey: .remoteTombstones)
        try container.encode(outbox, forKey: .outbox)
        try container.encode(importMappings, forKey: .importMappings)
        try container.encode(importBatches, forKey: .importBatches)
        if !legacyIdentityMappingIDs.isEmpty {
            try container.encode(legacyIdentityMappingIDs, forKey: .legacyIdentityMappingIDs)
        }
        if !legacyGenericTransactionIDs.isEmpty {
            try container.encode(legacyGenericTransactionIDs, forKey: .legacyGenericTransactionIDs)
        }
    }
}

private actor FinanceImportedSyncGate {
    private var busy = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func acquire() async {
        if !busy {
            busy = true
            return
        }
        await withCheckedContinuation { continuation in
            waiters.append(continuation)
        }
    }

    func release() {
        if let next = waiters.first {
            waiters.removeFirst()
            next.resume()
        } else {
            busy = false
        }
    }
}

/// Atomic Application-Support-backed storage with a bounded local-first
/// outbox. File locks protect only synchronous read-modify-write sections;
/// synchronize uses an actor gate for its network lifecycle.
public final class FinanceImportedTransactionStore: @unchecked Sendable {
    public static let fileName = "finance-imported-transactions.json"
    public static let maximumTransactions = 10_000
    public static let maximumOutboxEntries = 64
    public static let maximumPendingOperations = 10_000
    public static let maximumStateBytes = 8 * 1024 * 1024
    public static let maximumRetryAge: TimeInterval = 90 * 24 * 60 * 60
    public static let maximumImportMappings = 256
    public static let maximumImportBatches = 1_024
    public static let maximumImportRowLinks = maximumTransactions

    private static let processTransactionLock = NSLock()
    private static let maximumOperationsPerEntry = FinanceImportedPendingSyncEntry.maximumOperations

    private struct State {
        var transactions: [FinanceImportedTransaction]
        var remoteRevision: Int
        var remoteETag: String?
        var remoteRecordRevisions: [UUID: Int]
        var remoteTombstones: [UUID: FinanceImportedSyncTombstone]
        var outbox: [FinanceImportedPendingSyncEntry]
        var importMappings: [FinanceImportMapping]
        var importBatches: [FinanceImportBatchProvenance]
        var legacyIdentityMappingIDs: [UUID]
        var legacyGenericTransactionIDs: [UUID]
    }

    private struct TransactionCommitOutcome {
        let result: FinanceImportSaveResult
        let didChange: Bool
    }

    private struct EquivalentBatchMatch {
        let prior: FinanceImportBatchProvenance
        let isPartial: Bool
    }

    public let fileURL: URL
    private let fileManager: FileManager
    private let synchronizationGate = FinanceImportedSyncGate()

    public init(url: URL? = nil, fileManager: FileManager = .default) throws {
        self.fileManager = fileManager
        if let url { fileURL = url } else { fileURL = try Self.defaultURL(fileManager: fileManager) }
    }

    public static func defaultURL(fileManager: FileManager = .default) throws -> URL {
        guard let support = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else {
            throw FinanceImportedTransactionStoreError.applicationSupportUnavailable
        }
        return support.appendingPathComponent("LifeOS", isDirectory: true).appendingPathComponent(fileName, isDirectory: false)
    }

    public func all() throws -> [FinanceImportedTransaction] {
        Self.processTransactionLock.lock()
        defer { Self.processTransactionLock.unlock() }
        return try loadStateUnlocked().transactions
    }

    /// Content-free local receipts for reviewed imports. Raw CSV, headers,
    /// paths and account values are intentionally absent from this metadata.
    public func importBatches() throws -> [FinanceImportBatchProvenance] {
        Self.processTransactionLock.lock()
        defer { Self.processTransactionLock.unlock() }
        return try loadStateUnlocked().importBatches
    }

    /// User mappings are private local configuration. They are never added to
    /// sync records or canonical operation bytes.
    public func importMappings() throws -> [FinanceImportMapping] {
        Self.processTransactionLock.lock()
        defer { Self.processTransactionLock.unlock() }
        return try loadStateUnlocked().importMappings
    }

    @discardableResult
    public func add(_ transactions: [FinanceImportedTransaction]) throws -> FinanceImportSaveResult {
        guard !transactions.isEmpty else {
            return FinanceImportSaveResult(requestedCount: 0, insertedCount: 0, duplicateCount: 0, storedCount: try all().count)
        }
        Self.processTransactionLock.lock()
        defer { Self.processTransactionLock.unlock() }
        var state = try loadStateUnlocked()
        let outcome = try commitTransactions(transactions, state: &state)
        guard outcome.didChange else { return outcome.result }
        try saveStateUnlocked(state)
        return outcome.result
    }

    /// Commits only an importer-owned immutable preview. Source fields and
    /// transaction IDs are taken from `prepared`; the caller may submit only
    /// category edits keyed to rows already present in that preview.
    @discardableResult
    public func commitPreparedImport(
        _ prepared: FinancePreparedImport,
        categoryEdits: [FinanceImportCategoryEdit] = []
    ) throws -> FinanceImportSaveResult {
        Self.processTransactionLock.lock()
        defer { Self.processTransactionLock.unlock() }
        var state = try loadStateUnlocked()
        try validatePreparedImport(prepared, categoryEdits: categoryEdits, state: state)
        let effectiveMapping = try validateMappingReuse(
            prepared.mapping,
            batch: prepared.batchProvenance,
            state: state
        )
        let effectiveBatch = try batchProvenance(
            prepared.batchProvenance,
            mappingID: effectiveMapping?.id
        )

        // The batch token is the idempotency boundary for local provenance.
        // A retried commit reports the original rows as duplicates and never
        // applies a second set of category edits or receipt metadata.
        if let existingBatch = state.importBatches.first(where: { $0.id == effectiveBatch.id }) {
            guard try equivalentBatchReceipt(existingBatch, effectiveBatch),
                  existingBatch.rowLinks.map(\.transactionID) == effectiveBatch.rowLinks.map(\.transactionID),
                  existingBatch.rowLinks.map(\.sourceRowNumber) == effectiveBatch.rowLinks.map(\.sourceRowNumber) else {
                throw FinanceImportedTransactionStoreError.invalidEnvelope
            }
            return try commitDuplicatePreparedImport(
                prepared,
                categoryEdits: categoryEdits,
                state: &state
            )
        }

        if let equivalentReceipt = try equivalentBatch(
            for: effectiveBatch,
            mapping: effectiveMapping,
            state: state
        ) {
            let committedTransactions = try equivalentImportTransactions(
                prepared,
                categoryEdits: categoryEdits,
                state: state
            )
            let outcome = try commitTransactions(
                committedTransactions,
                categoryEditIDs: Set(categoryEdits.map(\.transactionID)),
                state: &state
            )
            if equivalentReceipt.isPartial {
                guard let batchIndex = state.importBatches.firstIndex(where: { $0.id == equivalentReceipt.prior.id }) else {
                    throw FinanceImportedTransactionStoreError.invalidEnvelope
                }
                state.importBatches[batchIndex] = try repairedEquivalentBatch(
                    prior: equivalentReceipt.prior,
                    candidate: effectiveBatch
                )
            }
            // An exact duplicate has no receipt append. Category edits remain
            // a normal local mutation and therefore still persist through the
            // ordinary outbox path.
            if outcome.didChange || equivalentReceipt.isPartial { try saveStateUnlocked(state) }
            return outcome.result
        }

        let committedTransactions = try transactionsApplyingCategoryEdits(
            to: prepared.transactions,
            edits: categoryEdits
        )
        let outcome = try commitTransactions(
            committedTransactions,
            categoryEditIDs: Set(categoryEdits.map(\.transactionID)),
            state: &state
        )
        guard state.importBatches.count < Self.maximumImportBatches else {
            throw FinanceImportedTransactionStoreError.stateTooLarge
        }
        if let mapping = effectiveMapping,
           !state.importMappings.contains(where: { $0.id == mapping.id }) {
            guard state.importMappings.count < Self.maximumImportMappings else {
                throw FinanceImportedTransactionStoreError.stateTooLarge
            }
            state.importMappings.append(mapping)
        }
        state.importBatches.append(effectiveBatch)
        // The single atomic replacement covers transactions, outbox, mapping
        // and provenance together. Duplicate-only imports return above and do
        // not consume durable receipt, mapping, or row-link capacity.
        try saveStateUnlocked(state)
        return outcome.result
    }

    /// Reopening a previously imported source is a receipt replay. Preserve
    /// any current source correction already in the ledger, while still
    /// allowing a deliberately deleted row to be restored and an explicit
    /// category edit to apply to an existing row.
    private func equivalentImportTransactions(
        _ prepared: FinancePreparedImport,
        categoryEdits: [FinanceImportCategoryEdit],
        state: State
    ) throws -> [FinanceImportedTransaction] {
        let editedPreview = try transactionsApplyingCategoryEdits(
            to: prepared.transactions,
            edits: categoryEdits
        )
        let editedIDs = Set(categoryEdits.map(\.transactionID))
        let currentByID = Dictionary(uniqueKeysWithValues: state.transactions.map { ($0.id, $0) })
        return editedPreview.map { candidate in
            guard let current = currentByID[candidate.id] else { return candidate }
            let category = editedIDs.contains(candidate.id) ? candidate.category : current.category
            return FinanceImportedTransaction(
                id: current.id,
                bookedAt: current.bookedAt,
                amountCents: current.amountCents,
                description: current.description,
                category: category,
                source: current.source,
                identityScheme: current.identityScheme,
                mappedIdentity: current.mappedIdentity,
                importedAt: current.importedAt,
                sourceCategory: current.sourceCategory,
                providerCode: current.providerCode,
                kind: current.kind,
                investment: current.investment
            )
        }
    }

    private func commitDuplicatePreparedImport(
        _ prepared: FinancePreparedImport,
        categoryEdits: [FinanceImportCategoryEdit],
        state: inout State
    ) throws -> FinanceImportSaveResult {
        // A committed batch token is a receipt replay, not a new mutation.
        // In particular, never reapply an old source preview or category edit
        // after a later import has corrected the same provider identity.
        _ = categoryEdits
        return FinanceImportSaveResult(
            requestedCount: prepared.transactions.count,
            insertedCount: 0,
            updatedCount: 0,
            duplicateCount: prepared.transactions.count,
            storedCount: state.transactions.count
        )
    }

    private func commitTransactions(
        _ transactions: [FinanceImportedTransaction],
        categoryEditIDs: Set<UUID> = Set<UUID>(),
        state: inout State
    ) throws -> TransactionCommitOutcome {
        guard state.transactions.count <= Self.maximumTransactions else { throw FinanceImportedTransactionStoreError.stateTooLarge }
        var indexByID: [UUID: Int] = [:]
        indexByID.reserveCapacity(state.transactions.count)
        for (index, transaction) in state.transactions.enumerated() {
            // `validateState` already rejects duplicates. Assignment keeps
            // this path fail-safe if it is ever reused before validation.
            indexByID[transaction.id] = index
        }
        var seenIncomingIDs = Set<UUID>()
        var additions: [FinanceImportedTransaction] = []
        var changedOperations: [FinanceImportedSyncOperation] = []
        var updatedCount = 0
        var duplicateCount = 0

        for incoming in transactions {
            guard seenIncomingIDs.insert(incoming.id).inserted else { duplicateCount += 1; continue }
            let expected = state.remoteRecordRevisions[incoming.id] ?? 0
            if let index = indexByID[incoming.id] {
                let existing = state.transactions[index]
                var candidate = incoming
                if candidate.category == nil && !categoryEditIDs.contains(incoming.id) {
                    candidate.category = existing.category
                }
                candidate = FinanceImportedTransaction(
                    id: candidate.id, bookedAt: candidate.bookedAt, amountCents: candidate.amountCents,
                    description: candidate.description, category: candidate.category, source: candidate.source,
                    identityScheme: candidate.identityScheme,
                    mappedIdentity: candidate.mappedIdentity,
                    importedAt: existing.importedAt, sourceCategory: candidate.sourceCategory,
                    providerCode: candidate.providerCode, kind: candidate.kind, investment: candidate.investment
                )
                let sourceChanged = !existing.hasSameSourceObservation(as: candidate)
                let categoryChanged = existing.category != candidate.category
                if !sourceChanged && !categoryChanged {
                    duplicateCount += 1
                } else {
                    state.transactions[index] = candidate
                    if !sourceChanged && categoryChanged && categoryEditIDs.contains(incoming.id) {
                        if let category = candidate.category {
                            guard let category = FinanceTransactionCategory(rawValue: category) else {
                                throw FinanceImportedTransactionStoreError.invalidEnvelope
                            }
                            changedOperations.append(.categorySet(
                                recordID: candidate.id,
                                expectedSourceRevision: expected,
                                categoryOverride: category
                            ))
                        } else {
                            changedOperations.append(.categoryClear(
                                recordID: candidate.id,
                                expectedSourceRevision: expected
                            ))
                        }
                    } else {
                        changedOperations.append(.upsert(
                            record: try FinanceImportedSyncRecord(validating: candidate, sourceRevision: expected),
                            expectedSourceRevision: expected
                        ))
                    }
                    updatedCount += 1
                }
            } else {
                indexByID[incoming.id] = state.transactions.count + additions.count
                additions.append(incoming)
                changedOperations.append(.upsert(
                    record: try FinanceImportedSyncRecord(validating: incoming, sourceRevision: expected),
                    expectedSourceRevision: expected
                ))
            }
        }
        guard additions.count <= Self.maximumTransactions - state.transactions.count else {
            throw FinanceImportedTransactionStoreError.stateTooLarge
        }
        state.transactions.append(contentsOf: additions)
        let result = FinanceImportSaveResult(requestedCount: transactions.count, insertedCount: additions.count,
                                             updatedCount: updatedCount, duplicateCount: duplicateCount,
                                             storedCount: state.transactions.count)
        if !changedOperations.isEmpty {
            try appendToOutbox(changedOperations, state: &state)
        }
        return TransactionCommitOutcome(result: result, didChange: !changedOperations.isEmpty)
    }

    private func validatePreparedImport(
        _ prepared: FinancePreparedImport,
        categoryEdits: [FinanceImportCategoryEdit],
        state: State
    ) throws {
        guard !prepared.rows.isEmpty,
              prepared.rows.count <= Self.maximumTransactions,
              prepared.token.batchID == prepared.batchProvenance.id,
              prepared.token.sourceDigest == prepared.batchProvenance.sourceDigest,
              prepared.effectiveDetection == prepared.batchProvenance.effectiveDetection,
              prepared.originalDetection == prepared.batchProvenance.originalDetection,
              prepared.rows.count == prepared.batchProvenance.rowLinks.count,
              prepared.rows.map(\.transaction.id) == prepared.batchProvenance.rowLinks.map(\.transactionID),
              prepared.rows.map(\.sourceRowNumber) == prepared.batchProvenance.rowLinks.map(\.sourceRowNumber) else {
            throw FinanceImportedTransactionStoreError.invalidEnvelope
        }
        switch prepared.effectiveDetection.state {
        case .known:
            guard prepared.effectiveDetection.institution != nil, prepared.mapping == nil,
                  prepared.batchProvenance.mappingID == nil else {
                throw FinanceImportedTransactionStoreError.invalidEnvelope
            }
        case .userMapped:
            guard prepared.effectiveDetection.institution == nil,
                  let mapping = prepared.mapping,
                  prepared.batchProvenance.mappingID == mapping.id,
                  prepared.transactions.allSatisfy({
                      $0.source == .genericCSV && $0.identityScheme == .mappedV3
                  }) else {
                throw FinanceImportedTransactionStoreError.invalidEnvelope
            }
            guard !state.transactions.contains(where: {
                $0.identityScheme == .mappedV3 && $0.mappedIdentity == nil
            }) else {
                // A mapped row from an older client has no account/configuration
                // proof. Do not guess its relationship to this import.
                throw FinanceImportedTransactionStoreError.migrationRequired
            }
            guard state.legacyGenericTransactionIDs.isEmpty else {
                throw FinanceImportedTransactionStoreError.migrationRequired
            }
        case .unknown, .ambiguous:
            throw FinanceImportedTransactionStoreError.invalidEnvelope
        }
        let existingIDs = Set(state.transactions.map(\.id))
        let previewIDs = Set(prepared.rows.map(\.transaction.id))
        let newCount = prepared.rows.reduce(into: 0) { count, row in
            if !existingIDs.contains(row.transaction.id) { count += 1 }
        }
        guard state.transactions.count + newCount <= Self.maximumTransactions else {
            throw FinanceImportedTransactionStoreError.stateTooLarge
        }
        var editIDs = Set<UUID>()
        for edit in categoryEdits {
            guard editIDs.insert(edit.transactionID).inserted,
                  previewIDs.contains(edit.transactionID) else {
                throw FinanceImportedTransactionStoreError.invalidEnvelope
            }
        }
    }

    private func validateMappingReuse(
        _ mapping: FinanceImportMapping?,
        batch: FinanceImportBatchProvenance,
        state: State
    ) throws -> FinanceImportMapping? {
        guard let mapping else { return nil }
        // A v2 mapping cannot be allowed to create a v3 row. The importer may
        // still be able to decode and display the old configuration, but the
        // store has no safe way to prove that its old IDs match the v3 scheme.
        guard !mapping.usesLegacyIdentityScheme else {
            throw FinanceImportedTransactionStoreError.migrationRequired
        }
        let existingMapping = state.importMappings.first(where: { $0.id == mapping.id })
        if let existingMapping {
            guard !existingMapping.usesLegacyIdentityScheme,
                  !state.legacyIdentityMappingIDs.contains(existingMapping.id) else {
                throw FinanceImportedTransactionStoreError.migrationRequired
            }
            guard existingMapping == mapping else { throw FinanceImportedTransactionStoreError.invalidEnvelope }
        }

        // A legacy mapping has no safe correspondence to mapped-v3 IDs. The
        // account identity is the only durable scope that survives the old
        // format, so any later mapped import for that account must stop at an
        // explicit migration boundary regardless of changed selectors.
        if state.importMappings.contains(where: {
            ($0.usesLegacyIdentityScheme || state.legacyIdentityMappingIDs.contains($0.id))
                && $0.account.identity.id == mapping.account.identity.id
        }) {
            throw FinanceImportedTransactionStoreError.migrationRequired
        }

        let mappedConfigurationDigest = mapping.identityConfigurationDigest
        for transaction in state.transactions where transaction.identityScheme == .mappedV3 {
            guard let mappedIdentity = transaction.mappedIdentity else {
                throw FinanceImportedTransactionStoreError.migrationRequired
            }
            if mappedIdentity.accountID == mapping.account.identity.id,
               mappedIdentity.configurationDigest != mappedConfigurationDigest {
                throw FinanceImportedTransactionStoreError.migrationRequired
            }
        }

        let mappingsByID = Dictionary(uniqueKeysWithValues: state.importMappings.map { ($0.id, $0) })
        for priorBatch in state.importBatches where priorBatch.sourceDigest == batch.sourceDigest {
            guard let priorMappingID = priorBatch.mappingID else { continue }
            guard let priorMapping = mappingsByID[priorMappingID] else {
                throw FinanceImportedTransactionStoreError.invalidEnvelope
            }
            // The same source/account cannot silently adopt a different
            // interpretation. Requiring an explicit new account preserves
            // account separation while avoiding a second ledger copy caused
            // by changed mapping columns.
            if priorMapping.account.identity.id == mapping.account.identity.id,
               !priorMapping.hasSameConfiguration(as: mapping) {
                // A changed identity selector, source-account column, or
                // amount interpretation can produce a different row ID for
                // the same bytes. Never create a second ledger copy without
                // an explicit migration/reconciliation step.
                throw FinanceImportedTransactionStoreError.migrationRequired
            }
        }
        for priorMapping in state.importMappings
            where priorMapping.account.identity.id == mapping.account.identity.id
                && priorMapping.id != mapping.id {
            guard priorMapping.hasSameConfiguration(as: mapping) else {
                // A changed provider selector, amount interpretation, source
                // account column, or layout can address the same statement
                // rows with different IDs. Require explicit reconciliation
                // even when the newly selected export has different bytes.
                throw FinanceImportedTransactionStoreError.migrationRequired
            }
        }

        if let existingMapping {
            return existingMapping
        }

        // A new preview may carry a new UUID even though the user selected
        // the same reviewed account and layout. Reuse the durable mapping so
        // the UUID cannot consume another mapping slot or change provenance
        // identity on an exact reimport. This return is deliberately after
        // the source/account interpretation checks above.
        if let equivalent = state.importMappings.first(where: { $0.hasSameConfiguration(as: mapping) }) {
            guard !state.legacyIdentityMappingIDs.contains(equivalent.id) else {
                throw FinanceImportedTransactionStoreError.migrationRequired
            }
            return equivalent
        }
        return mapping
    }

    private func batchProvenance(
        _ batch: FinanceImportBatchProvenance,
        mappingID: UUID?
    ) throws -> FinanceImportBatchProvenance {
        guard batch.mappingID != mappingID else { return batch }
        return try FinanceImportBatchProvenance(
            id: batch.id,
            importedAt: batch.importedAt,
            sourceDigest: batch.sourceDigest,
            byteCount: batch.byteCount,
            headerFingerprint: batch.headerFingerprint,
            delimiter: batch.delimiter,
            headerRecordIndex: batch.headerRecordIndex,
            mappingID: mappingID,
            originalDetection: batch.originalDetection,
            effectiveDetection: batch.effectiveDetection,
            rowLinks: batch.rowLinks
        )
    }

    /// JSONEncoder.lifeOS intentionally writes whole-second ISO-8601 dates.
    /// Compare the encoded date bytes instead of the in-memory Date values so
    /// a prepared receipt remains idempotent after a relaunch.
    private func equivalentBatchReceipt(
        _ lhs: FinanceImportBatchProvenance,
        _ rhs: FinanceImportBatchProvenance
    ) throws -> Bool {
        guard lhs.id == rhs.id,
              lhs.sourceDigest == rhs.sourceDigest,
              lhs.byteCount == rhs.byteCount,
              lhs.headerFingerprint == rhs.headerFingerprint,
              lhs.delimiter == rhs.delimiter,
              lhs.headerRecordIndex == rhs.headerRecordIndex,
              lhs.mappingID == rhs.mappingID,
              lhs.registryVersion == rhs.registryVersion,
              lhs.detectorVersion == rhs.detectorVersion,
              lhs.normalizationVersion == rhs.normalizationVersion,
              lhs.originalDetection == rhs.originalDetection,
              lhs.effectiveDetection == rhs.effectiveDetection,
              lhs.rowLinks == rhs.rowLinks else {
            return false
        }
        let lhsDate = try JSONEncoder.lifeOS.encode(lhs.importedAt)
        let rhsDate = try JSONEncoder.lifeOS.encode(rhs.importedAt)
        return lhsDate == rhsDate
    }

    /// Returns an existing receipt only when source bytes, effective layout,
    /// and every row identity match. A partial receipt is allowed to be
    /// repaired by a later import; an incompatible identity set is fenced so
    /// a changed identity algorithm can never silently duplicate rows.
    private func equivalentBatch(
        for candidate: FinanceImportBatchProvenance,
        mapping: FinanceImportMapping?,
        state: State
    ) throws -> EquivalentBatchMatch? {
        for prior in state.importBatches where prior.sourceDigest == candidate.sourceDigest {
            guard prior.byteCount == candidate.byteCount,
                  prior.headerFingerprint == candidate.headerFingerprint,
                  prior.delimiter == candidate.delimiter,
                  prior.headerRecordIndex == candidate.headerRecordIndex,
                  prior.originalDetection == candidate.originalDetection,
                  prior.effectiveDetection == candidate.effectiveDetection else {
                continue
            }

            let sameEffectiveMapping: Bool
            switch (prior.mappingID, candidate.mappingID) {
            case (nil, nil):
                sameEffectiveMapping = true
            case let (priorID?, candidateID?):
                guard let priorMapping = state.importMappings.first(where: { $0.id == priorID }) else {
                    throw FinanceImportedTransactionStoreError.invalidEnvelope
                }
                guard let mapping else { throw FinanceImportedTransactionStoreError.invalidEnvelope }
                // candidateID is checked by validateMappingReuse; keeping the
                // comparison here makes this helper safe if another caller is
                // added later.
                guard candidateID == mapping.id else { continue }
                sameEffectiveMapping = priorMapping.hasSameConfiguration(as: mapping)
            default:
                sameEffectiveMapping = false
            }
            guard sameEffectiveMapping else { continue }

            let priorIDs = prior.rowLinks.map(\.transactionID)
            let candidateIDs = candidate.rowLinks.map(\.transactionID)
            if priorIDs == candidateIDs,
               prior.rowLinks.map(\.sourceRowNumber) == candidate.rowLinks.map(\.sourceRowNumber) {
                return EquivalentBatchMatch(prior: prior, isPartial: false)
            }

            // Removing a local row prunes its link from a receipt. Permit a
            // later full statement to restore that row and repair the same
            // receipt atomically. Any other mismatch is an identity-version
            // seam and requires explicit migration before another row can be
            // created.
            let priorIDSet = Set(priorIDs)
            let candidateIDSet = Set(candidateIDs)
            guard priorIDSet.isSubset(of: candidateIDSet)
                    || candidateIDSet.isSubset(of: priorIDSet) else {
                throw FinanceImportedTransactionStoreError.migrationRequired
            }
            return EquivalentBatchMatch(prior: prior, isPartial: true)
        }
        return nil
    }

    private func repairedEquivalentBatch(
        prior: FinanceImportBatchProvenance,
        candidate: FinanceImportBatchProvenance
    ) throws -> FinanceImportBatchProvenance {
        let repairedLinks = try candidate.rowLinks.map {
            try FinanceImportRowProvenance(
                batchID: prior.id,
                sourceRowNumber: $0.sourceRowNumber,
                transactionID: $0.transactionID
            )
        }
        return try FinanceImportBatchProvenance(
            id: prior.id,
            importedAt: prior.importedAt,
            sourceDigest: candidate.sourceDigest,
            byteCount: candidate.byteCount,
            headerFingerprint: candidate.headerFingerprint,
            delimiter: candidate.delimiter,
            headerRecordIndex: candidate.headerRecordIndex,
            mappingID: candidate.mappingID,
            originalDetection: candidate.originalDetection,
            effectiveDetection: candidate.effectiveDetection,
            rowLinks: repairedLinks
        )
    }

    private func transactionsApplyingCategoryEdits(
        to transactions: [FinanceImportedTransaction],
        edits: [FinanceImportCategoryEdit]
    ) throws -> [FinanceImportedTransaction] {
        let transactionIDs = Set(transactions.map(\.id))
        var editsByID: [UUID: FinanceImportCategoryEdit] = [:]
        editsByID.reserveCapacity(edits.count)
        for edit in edits {
            guard editsByID[edit.transactionID] == nil,
                  transactionIDs.contains(edit.transactionID) else {
                throw FinanceImportedTransactionStoreError.invalidEnvelope
            }
            editsByID[edit.transactionID] = edit
        }
        return transactions.map { transaction in
            guard let edit = editsByID[transaction.id] else { return transaction }
            return FinanceImportedTransaction(
                id: transaction.id,
                bookedAt: transaction.bookedAt,
                amountCents: transaction.amountCents,
                description: transaction.description,
                category: edit.category?.rawValue,
                source: transaction.source,
                identityScheme: transaction.identityScheme,
                mappedIdentity: transaction.mappedIdentity,
                importedAt: transaction.importedAt,
                sourceCategory: transaction.sourceCategory,
                providerCode: transaction.providerCode,
                kind: transaction.kind,
                investment: transaction.investment
            )
        }
    }

    public func remove(id: UUID) throws {
        Self.processTransactionLock.lock()
        defer { Self.processTransactionLock.unlock() }
        var state = try loadStateUnlocked()
        guard let index = state.transactions.firstIndex(where: { $0.id == id }) else { throw FinanceImportedTransactionStoreError.transactionNotFound }
        state.transactions.remove(at: index)
        try pruneImportBatches(&state)
        try appendToOutbox([.delete(recordID: id, expectedSourceRevision: state.remoteRecordRevisions[id] ?? 0, deletedAt: .now)], state: &state)
        try saveStateUnlocked(state)
    }

    public func setCategory(_ category: FinanceTransactionCategory?, for id: UUID) throws {
        Self.processTransactionLock.lock()
        defer { Self.processTransactionLock.unlock() }
        var state = try loadStateUnlocked()
        guard let index = state.transactions.firstIndex(where: { $0.id == id }) else { throw FinanceImportedTransactionStoreError.transactionNotFound }
        state.transactions[index].category = category?.rawValue
        let expected = state.remoteRecordRevisions[id] ?? 0
        let operation: FinanceImportedSyncOperation = category.map {
            .categorySet(recordID: id, expectedSourceRevision: expected, categoryOverride: $0)
        } ?? .categoryClear(recordID: id, expectedSourceRevision: expected)
        try appendToOutbox([operation], state: &state)
        try saveStateUnlocked(state)
    }

    public func clearCategoryOverride(for id: UUID) throws { try setCategory(nil, for: id) }

    public func clearAll() throws {
        Self.processTransactionLock.lock()
        defer { Self.processTransactionLock.unlock() }
        var state = try loadStateUnlocked()
        // A prior local import can still be represented only by an outbox
        // upsert after a crash or an older client cleared its in-memory rows.
        // Include those payload-bearing IDs so clear-all is a durable privacy
        // operation even when the visible transaction list is already empty.
        let clearedIDs = Set(state.transactions.map(\.id)).union(
            state.outbox.flatMap { entry in
                entry.operations.compactMap { operation -> UUID? in
                    switch operation {
                    case .upsert(let record, _), .restore(let record, _), .legacyUpsert(let record, _):
                        return record.recordID
                    case .categorySet, .categoryClear, .delete, .legacyDelete:
                        return nil
                    }
                }
            }
        )
        guard !clearedIDs.isEmpty || !state.importMappings.isEmpty || !state.importBatches.isEmpty
                || !state.legacyIdentityMappingIDs.isEmpty
                || !state.legacyGenericTransactionIDs.isEmpty else { return }
        state.transactions.removeAll(keepingCapacity: false)
        if !clearedIDs.isEmpty {
            try compactOutboxForClearAll(clearedIDs: clearedIDs, state: &state, deletedAt: .now)
        }
        state.importMappings.removeAll(keepingCapacity: false)
        state.importBatches.removeAll(keepingCapacity: false)
        state.legacyIdentityMappingIDs.removeAll(keepingCapacity: false)
        state.legacyGenericTransactionIDs.removeAll(keepingCapacity: false)
        try saveStateUnlocked(state)
    }

    /// Keeps durable import provenance aligned with the local transaction set.
    /// A batch is a receipt for rows that still exist locally; once its last
    /// row is removed, the receipt is dropped as well. Mappings remain until
    /// `clearAll()` so a user can reuse a reviewed mapping after deleting an
    /// earlier import.
    private func pruneImportBatches(_ state: inout State) throws {
        let transactionIDs = Set(state.transactions.map(\.id))
        state.importBatches = try state.importBatches.compactMap { batch in
            let retainedLinks = batch.rowLinks.filter { transactionIDs.contains($0.transactionID) }
            guard !retainedLinks.isEmpty else { return nil }
            guard retainedLinks.count != batch.rowLinks.count else { return batch }
            return try FinanceImportBatchProvenance(
                id: batch.id,
                importedAt: batch.importedAt,
                sourceDigest: batch.sourceDigest,
                byteCount: batch.byteCount,
                headerFingerprint: batch.headerFingerprint,
                delimiter: batch.delimiter,
                headerRecordIndex: batch.headerRecordIndex,
                mappingID: batch.mappingID,
                originalDetection: batch.originalDetection,
                effectiveDetection: batch.effectiveDetection,
                rowLinks: retainedLinks
            )
        }
    }

    public func transactions(in interval: DateInterval?) throws -> [FinanceImportedTransaction] {
        let existing = try all()
        let filtered = interval.map { range in existing.filter { range.contains($0.bookedAt) } } ?? existing
        return filtered.sorted {
            if $0.bookedAt != $1.bookedAt { return $0.bookedAt < $1.bookedAt }
            return $0.id.uuidString < $1.id.uuidString
        }
    }

    public func pendingSyncEntryCount() throws -> Int {
        Self.processTransactionLock.lock()
        defer { Self.processTransactionLock.unlock() }
        return try loadStateUnlocked().outbox.count
    }

    public func syncStatus() throws -> FinanceImportedSyncStatus {
        Self.processTransactionLock.lock()
        defer { Self.processTransactionLock.unlock() }
        let state = try loadStateUnlocked()
        var pendingEntries = 0
        var blockedEntries = 0
        var pendingOperations = 0
        var blockedOperations = 0
        var reasons = Set<FinanceImportedSyncBlockReason>()
        for entry in state.outbox {
            if entry.state == .blocked {
                blockedEntries += 1
                blockedOperations += entry.operations.count
                if let reason = entry.blockedReason { reasons.insert(reason) }
            } else {
                pendingEntries += 1
                pendingOperations += entry.operations.count
            }
        }
        return FinanceImportedSyncStatus(
            pendingEntryCount: pendingEntries,
            blockedEntryCount: blockedEntries,
            pendingOperationCount: pendingOperations,
            blockedOperationCount: blockedOperations,
            blockedReasons: reasons.sorted { $0.rawValue < $1.rawValue }
        )
    }

    public func pendingSyncRequest() throws -> FinanceImportedPendingSyncRequest? {
        Self.processTransactionLock.lock()
        defer { Self.processTransactionLock.unlock() }
        var state = try loadStateUnlocked()
        normalizeDeferredOperations(&state)
        try saveStateUnlocked(state)
        return try prepareHeadUnlocked(state: &state, incrementAttempt: false)
    }

    @discardableResult
    public func synchronize(using client: TailscaleSyncClient) async throws -> FinanceImportedSyncResult {
        await synchronizationGate.acquire()
        do {
            let result = try await synchronizeSerially(using: client)
            await synchronizationGate.release()
            return result
        } catch {
            await synchronizationGate.release()
            throw error
        }
    }

    private func synchronizeSerially(using client: TailscaleSyncClient) async throws -> FinanceImportedSyncResult {
        var latest = try await client.fetchFinanceImportedLedger()
        try adoptRemote(latest)
        try await reconcileSupersededAttemptReceipts(using: client, latest: &latest)
        while try pendingSyncRequest() != nil {
            let attempted = try beginAttempt()
            do {
                let pushed = try await client.pushFinanceImportedLedger(
                    body: attempted.body, ifMatch: attempted.ifMatch, idempotencyKey: attempted.idempotencyKey
                )
                try completeAttempt(pushed, idempotencyKey: attempted.idempotencyKey)
                latest = pushed
            } catch let error as FinanceImportedSyncError {
                guard case .conflict(let snapshot, let etag) = error else { throw error }
                let canRetry = try handleConflict(
                    FinanceImportedSyncResult(snapshot: snapshot, etag: etag),
                    supersededAttemptKey: attempted.idempotencyKey
                )
                if !canRetry { throw error }
            }
        }
        return latest
    }

    public func adoptRemote(_ result: FinanceImportedSyncResult) throws {
        guard TailscaleSyncClient.validatedFinanceImportedETag(result.etag) != nil,
              TailscaleSyncClient.financeImportedETagRevision(result.etag) == result.snapshot.revision else {
            throw FinanceImportedTransactionStoreError.invalidEnvelope
        }
        Self.processTransactionLock.lock()
        defer { Self.processTransactionLock.unlock() }
        var state = try loadStateUnlocked()
        try validateRemoteOrdering(result, state: state)
        try mergeRemoteUnlocked(result, state: &state)
        normalizeDeferredOperations(&state)
        try saveStateUnlocked(state)
    }

    private func beginAttempt() throws -> FinanceImportedPendingSyncRequest {
        Self.processTransactionLock.lock()
        defer { Self.processTransactionLock.unlock() }
        var state = try loadStateUnlocked()
        normalizeDeferredOperations(&state)
        guard let request = try prepareHeadUnlocked(state: &state, incrementAttempt: true) else {
            throw FinanceImportedTransactionStoreError.syncPayloadTooLarge
        }
        return request
    }

    private func completeAttempt(_ result: FinanceImportedSyncResult, idempotencyKey: String) throws {
        Self.processTransactionLock.lock()
        defer { Self.processTransactionLock.unlock() }
        var state = try loadStateUnlocked()
        let isCurrentHead = state.outbox.first?.idempotencyKey == idempotencyKey
        let reconciliationReceipt = state.outbox.lazy.compactMap { entry in
            entry.supersededAttemptReceipts.first { $0.idempotencyKey == idempotencyKey }
        }.first
        guard isCurrentHead || reconciliationReceipt != nil else {
            throw FinanceImportedTransactionStoreError.invalidEnvelope
        }
        try validateRemoteOrdering(result, state: state)
        if let reconciliationReceipt, result.wasReplay {
            // A replay returns the gateway's current snapshot, which may be
            // newer than the revision committed by the original request. It
            // cannot prove that the returned row revision belongs to that
            // request, so never advance a superseded clear-all delete from it.
            try mergeRemoteUnlocked(result, state: &state)
            blockSupersededAttemptReceiptUnlocked(reconciliationReceipt.idempotencyKey, state: &state)
            try saveStateUnlocked(state)
            throw FinanceImportedTransactionStoreError.syncReceiptUnresolved
        }
        if isCurrentHead {
            state.outbox.removeFirst()
        }
        try mergeRemoteUnlocked(result, state: &state)
        if let reconciliationReceipt {
            try rebaseSupersededDeletes(
                receipt: reconciliationReceipt,
                result: result,
                state: &state
            )
        }
        removeSupersededAttemptKey(idempotencyKey, state: &state)
        normalizeDeferredOperations(&state)
        try saveStateUnlocked(state)
    }

    private func handleConflict(
        _ result: FinanceImportedSyncResult,
        supersededAttemptKey: String? = nil
    ) throws -> Bool {
        Self.processTransactionLock.lock()
        defer { Self.processTransactionLock.unlock() }
        var state = try loadStateUnlocked()
        try validateRemoteOrdering(result, state: state)
        try mergeRemoteUnlocked(result, state: &state)
        // A conflict response is authoritative evidence that this request was
        // rejected. Its snapshot may contain another writer's newer row, so it
        // can never serve as proof for rebasing a superseded delete. Only the
        // exact committed receipt path below may advance that precondition.
        if let supersededAttemptKey {
            removeSupersededAttemptKey(supersededAttemptKey, state: &state)
        }
        guard let head = state.outbox.first, head.state == .pending else {
            try saveStateUnlocked(state)
            return false
        }
        guard head.attemptCount < FinanceImportedPendingSyncEntry.maximumAttempts else {
            state.outbox[0].state = .blocked
            state.outbox[0].blockedReason = .attemptsExhausted
            try saveStateUnlocked(state)
            return false
        }
        // Check the original source preconditions before any helper can
        // promote expected revision zero from the returned snapshot. A
        // rejected create followed by clear-all must never become a delete
        // of a competing writer's row.
        guard head.operations.allSatisfy({ canSafelyRebase($0, state: state) }) else {
            state.outbox[0].state = .blocked
            state.outbox[0].blockedReason = .conflict
            try saveStateUnlocked(state)
            return false
        }
        state.outbox[0] = try FinanceImportedPendingSyncEntry(
            idempotencyKey: "finance-import-\(UUID().uuidString)",
            operations: head.operations,
            createdAt: head.createdAt,
            attemptCount: head.attemptCount,
            lastAttemptAt: head.lastAttemptAt,
            state: .pending,
            blockedReason: nil,
            attemptedRequest: nil,
            supersededAttemptReceipts: head.supersededAttemptReceipts
        )
        try saveStateUnlocked(state)
        return true
    }

    private func reconcileSupersededAttemptReceipts(
        using client: TailscaleSyncClient,
        latest: inout FinanceImportedSyncResult
    ) async throws {
        let receipts = try loadSupersededAttemptReceipts()
        for receipt in receipts {
            let proof = try await client.fetchFinanceImportedReceipt(receipt.idempotencyKey)
            guard proof.state == .committed, let proofRevision = proof.revision else {
                try blockSupersededAttemptReceipt(receipt.idempotencyKey)
                throw FinanceImportedTransactionStoreError.syncReceiptUnresolved
            }

            if latest.snapshot.revision < proofRevision {
                latest = try await client.fetchFinanceImportedLedger()
                try adoptRemote(latest)
            }
            guard latest.snapshot.revision == proofRevision else {
                // A current snapshot newer than the receipt may include a
                // different writer's edit. Without historical snapshots, a
                // delete based on that response is not safe to infer.
                try blockSupersededAttemptReceipt(receipt.idempotencyKey)
                throw FinanceImportedTransactionStoreError.syncReceiptUnresolved
            }
            try applyCommittedSupersededAttemptReceipt(receipt, result: latest)
        }
    }

    private func loadSupersededAttemptReceipts() throws -> [FinanceImportedSupersededAttemptReceipt] {
        Self.processTransactionLock.lock()
        defer { Self.processTransactionLock.unlock() }
        let state = try loadStateUnlocked()
        return state.outbox.flatMap(\.supersededAttemptReceipts)
    }

    private func applyCommittedSupersededAttemptReceipt(
        _ receipt: FinanceImportedSupersededAttemptReceipt,
        result: FinanceImportedSyncResult
    ) throws {
        Self.processTransactionLock.lock()
        defer { Self.processTransactionLock.unlock() }
        var state = try loadStateUnlocked()
        guard state.outbox.contains(where: { entry in
            entry.supersededAttemptReceipts.contains { $0.idempotencyKey == receipt.idempotencyKey }
        }) else { return }
        try validateRemoteOrdering(result, state: state)
        try rebaseSupersededDeletes(receipt: receipt, result: result, state: &state)
        removeSupersededAttemptKey(receipt.idempotencyKey, state: &state)
        normalizeDeferredOperations(&state)
        try saveStateUnlocked(state)
    }

    private func blockSupersededAttemptReceipt(_ idempotencyKey: String) throws {
        Self.processTransactionLock.lock()
        defer { Self.processTransactionLock.unlock() }
        var state = try loadStateUnlocked()
        blockSupersededAttemptReceiptUnlocked(idempotencyKey, state: &state)
        try saveStateUnlocked(state)
    }

    private func blockSupersededAttemptReceiptUnlocked(
        _ idempotencyKey: String,
        state: inout State
    ) {
        guard let index = state.outbox.firstIndex(where: { entry in
            entry.supersededAttemptReceipts.contains { $0.idempotencyKey == idempotencyKey }
        }) else { return }
        state.outbox[index].state = .blocked
        state.outbox[index].blockedReason = .conflict
    }

    private func removeSupersededAttemptKey(_ key: String, state: inout State) {
        for index in state.outbox.indices {
            state.outbox[index].supersededAttemptReceipts.removeAll { $0.idempotencyKey == key }
        }
    }

    /// A clear-all delete may have been created from the row's old source
    /// revision while a correction for that same row was already in flight.
    /// The late correction response is an exact receipt for that delete, so
    /// its source revision can be advanced to the response's authoritative
    /// row revision. The receipt binds this narrowly to the superseded
    /// correction; ordinary deletes continue through conflict handling.
    private func rebaseSupersededDeletes(
        receipt: FinanceImportedSupersededAttemptReceipt,
        result: FinanceImportedSyncResult,
        state: inout State
    ) throws {
        let receiptIDs = Set(receipt.recordIDs)
        guard !receiptIDs.isEmpty else { return }
        let authoritativeRevisions = Dictionary(
            uniqueKeysWithValues: result.snapshot.records.map { ($0.recordID, $0.sourceRevision) }
        )

        for index in state.outbox.indices {
            let entry = state.outbox[index]
            var changed = false
            let operations = entry.operations.map { operation -> FinanceImportedSyncOperation in
                guard case .delete(let recordID, let expectedSourceRevision, let deletedAt) = operation,
                      receiptIDs.contains(recordID),
                      let authoritativeRevision = authoritativeRevisions[recordID],
                      authoritativeRevision > 0,
                      authoritativeRevision != expectedSourceRevision else {
                    return operation
                }
                changed = true
                return .delete(
                    recordID: recordID,
                    expectedSourceRevision: authoritativeRevision,
                    deletedAt: deletedAt
                )
            }
            guard changed else { continue }

            // A clear-all delete is normally unattempted. If a future caller
            // has already prepared a request for this entry, discard those
            // stale bytes and issue a fresh logical request after the receipt
            // updates the authoritative cursor.
            state.outbox[index] = try FinanceImportedPendingSyncEntry(
                idempotencyKey: entry.attemptedRequest == nil
                    ? entry.idempotencyKey
                    : "finance-import-\(UUID().uuidString)",
                operations: operations,
                createdAt: entry.createdAt,
                attemptCount: entry.attemptCount,
                lastAttemptAt: entry.lastAttemptAt,
                state: .pending,
                blockedReason: nil,
                attemptedRequest: nil,
                supersededAttemptReceipts: entry.supersededAttemptReceipts
            )
        }
    }

    private func appendUniqueSupersededAttemptReceipts(
        _ newReceipts: [FinanceImportedSupersededAttemptReceipt],
        to receipts: inout [FinanceImportedSupersededAttemptReceipt]
    ) {
        for receipt in newReceipts where !receipts.contains(where: { $0.idempotencyKey == receipt.idempotencyKey }) {
            receipts.append(receipt)
        }
    }

    private func prepareHeadUnlocked(state: inout State, incrementAttempt: Bool) throws -> FinanceImportedPendingSyncRequest? {
        guard !state.outbox.isEmpty, state.outbox[0].state == .pending, let etag = state.remoteETag else { return nil }
        let entry = state.outbox[0]
        guard Date().timeIntervalSince(entry.createdAt) <= Self.maximumRetryAge else {
            state.outbox[0].state = .blocked
            state.outbox[0].blockedReason = .retryExpired
            try saveStateUnlocked(state)
            return nil
        }
        guard entry.attemptCount < FinanceImportedPendingSyncEntry.maximumAttempts else {
            state.outbox[0].state = .blocked
            state.outbox[0].blockedReason = .attemptsExhausted
            try saveStateUnlocked(state)
            return nil
        }

        if let persisted = entry.attemptedRequest {
            let request = try persisted.decodedRequest()
            guard persisted.idempotencyKey == entry.idempotencyKey, request.operations == entry.operations else {
                state.outbox[0].state = .blocked
                state.outbox[0].blockedReason = .invalidEnvelope
                try saveStateUnlocked(state)
                return nil
            }
            if incrementAttempt {
                state.outbox[0].attemptCount += 1
                state.outbox[0].lastAttemptAt = .now
                try saveStateUnlocked(state)
            }
            return FinanceImportedPendingSyncRequest(request: request, body: persisted.body,
                                                     ifMatch: persisted.ifMatch, idempotencyKey: persisted.idempotencyKey)
        }

        let request: FinanceImportedSyncRequest
        let body: Data
        do {
            request = try FinanceImportedSyncRequest(baseRevision: state.remoteRevision, operations: entry.operations)
            body = try request.canonicalData()
        } catch let error as FinanceImportedSyncError where error == .requestTooLarge {
            state.outbox[0].state = .blocked
            state.outbox[0].blockedReason = .payloadTooLarge
            try saveStateUnlocked(state)
            return nil
        } catch {
            state.outbox[0].state = .blocked
            state.outbox[0].blockedReason = .invalidEnvelope
            try saveStateUnlocked(state)
            return nil
        }
        state.outbox[0].attemptedRequest = try FinanceImportedAttemptedSyncRequest(
            baseRevision: state.remoteRevision, ifMatch: etag, idempotencyKey: entry.idempotencyKey, body: body
        )
        if incrementAttempt {
            state.outbox[0].attemptCount += 1
            state.outbox[0].lastAttemptAt = .now
        }
        try saveStateUnlocked(state)
        return FinanceImportedPendingSyncRequest(request: request, body: body, ifMatch: etag, idempotencyKey: entry.idempotencyKey)
    }

    private func validateRemoteOrdering(_ result: FinanceImportedSyncResult, state: State) throws {
        if result.snapshot.revision < state.remoteRevision { throw FinanceImportedTransactionStoreError.syncSnapshotRewound }
        if result.snapshot.revision == state.remoteRevision, let currentETag = state.remoteETag, currentETag != result.etag {
            throw FinanceImportedTransactionStoreError.syncSnapshotETagMismatch
        }
    }

    private func mergeRemoteUnlocked(_ result: FinanceImportedSyncResult, state: inout State) throws {
        let protectedIDs = Set(state.outbox.flatMap { $0.operations.map(\.recordID) })
        var byID = Dictionary(uniqueKeysWithValues: state.transactions.map { ($0.id, $0) })
        for record in result.snapshot.records where !protectedIDs.contains(record.recordID) {
            byID[record.recordID] = record.transaction
        }
        var acceptedTombstoneIDs = Set<UUID>()
        for tombstone in result.snapshot.tombstones where !protectedIDs.contains(tombstone.recordID) {
            byID.removeValue(forKey: tombstone.recordID)
            acceptedTombstoneIDs.insert(tombstone.recordID)
        }
        state.transactions = byID.values.sorted {
            if $0.bookedAt != $1.bookedAt { return $0.bookedAt < $1.bookedAt }
            return $0.id.uuidString < $1.id.uuidString
        }
        // Remote tombstones remove their local provenance links together with
        // the accepted transaction. Protected local outbox rows remain in
        // `byID`, so their links are retained until the local write resolves.
        if !acceptedTombstoneIDs.isEmpty {
            try pruneImportBatches(&state)
        }
        state.remoteRevision = result.snapshot.revision
        state.remoteETag = result.etag
        state.remoteRecordRevisions = Dictionary(uniqueKeysWithValues: result.snapshot.records.map { ($0.recordID, $0.sourceRevision) })
        state.remoteTombstones = Dictionary(uniqueKeysWithValues: result.snapshot.tombstones.map { ($0.recordID, $0) })
    }

    private func canSafelyRebase(_ operation: FinanceImportedSyncOperation, state: State) -> Bool {
        switch operation {
        case .upsert(let record, let expected):
            guard state.remoteTombstones[record.recordID] == nil else { return false }
            return (state.remoteRecordRevisions[record.recordID] ?? 0) == expected && record.sourceRevision == expected
        case .categorySet(let id, let expected, _), .categoryClear(let id, let expected):
            guard state.remoteTombstones[id] == nil else { return false }
            return expected >= 0 && state.remoteRecordRevisions[id] == expected
        case .delete(let id, let expected, _):
            guard state.remoteTombstones[id] == nil else { return false }
            return (state.remoteRecordRevisions[id] ?? 0) == expected
        case .restore(let record, let expected):
            return record.sourceRevision == 0 && state.remoteRecordRevisions[record.recordID] == nil
                && state.remoteTombstones[record.recordID]?.revision == expected
        case .legacyUpsert, .legacyDelete:
            return false
        }
    }

    private func normalizeDeferredOperations(_ state: inout State) {
        for index in state.outbox.indices where state.outbox[index].state == .pending
            && state.outbox[index].attemptedRequest == nil
            && state.outbox[index].attemptCount == 0 {
            let oldOperations = state.outbox[index].operations
            var changed = false
            var blockedByCompetingDelete = false
            let operations = oldOperations.map { operation -> FinanceImportedSyncOperation in
                switch operation {
                case .categorySet(let id, let expected, let category) where expected == 0:
                    guard let revision = state.remoteRecordRevisions[id], revision > 0,
                          state.remoteTombstones[id] == nil else { return operation }
                    changed = true
                    return .categorySet(recordID: id, expectedSourceRevision: revision, categoryOverride: category)
                case .categoryClear(let id, let expected) where expected == 0:
                    guard let revision = state.remoteRecordRevisions[id], revision > 0,
                          state.remoteTombstones[id] == nil else { return operation }
                    changed = true
                    return .categoryClear(recordID: id, expectedSourceRevision: revision)
                case .delete(let id, let expected, _) where expected == 0:
                    // An expected-zero delete may represent a local row that
                    // never reached the server. A later snapshot can contain
                    // another writer's row with the same stable ID, so its
                    // current revision is not proof that this delete belongs
                    // to that row. Keep the zero precondition and fail closed
                    // before a new request can transmit it.
                    guard state.remoteRecordRevisions[id] == nil,
                          state.remoteTombstones[id] == nil else {
                        blockedByCompetingDelete = true
                        return operation
                    }
                    return operation
                default:
                    return operation
                }
            }
            if blockedByCompetingDelete {
                state.outbox[index].state = .blocked
                state.outbox[index].blockedReason = .conflict
                continue
            }
            guard changed, let replacement = try? FinanceImportedPendingSyncEntry(
                idempotencyKey: state.outbox[index].idempotencyKey, operations: operations,
                createdAt: state.outbox[index].createdAt, attemptCount: state.outbox[index].attemptCount,
                lastAttemptAt: state.outbox[index].lastAttemptAt,
                supersededAttemptReceipts: state.outbox[index].supersededAttemptReceipts
            ) else { continue }
            state.outbox[index] = replacement
        }
    }

    /// Removes payload-bearing work for cleared records while retaining
    /// unrelated outbox operations. A delete operation is the only retained
    /// work for a cleared record because it contains no transaction payload.
    /// The whole state is saved once by `clearAll`, so compaction remains
    /// atomic with the local hard delete and cannot leave a half-compacted
    /// envelope after a crash.
    private func compactOutboxForClearAll(
        clearedIDs: Set<UUID>,
        state: inout State,
        deletedAt: Date
    ) throws {
        var retainedEntries: [FinanceImportedPendingSyncEntry] = []
        retainedEntries.reserveCapacity(state.outbox.count)
        var retainedDeleteIDs = Set<UUID>()
        var orphanedSupersededAttemptReceipts: [FinanceImportedSupersededAttemptReceipt] = []

        for entry in state.outbox {
            let clearedOperationRecordIDs = entry.operations.compactMap { operation in
                clearedIDs.contains(operation.recordID) ? operation.recordID : nil
            }
            let retainedOperations = entry.operations.compactMap { operation -> FinanceImportedSyncOperation? in
                guard clearedIDs.contains(operation.recordID) else { return operation }

                // Keep the first existing delete for a record. It may already
                // have entered the transmission lifecycle, so replacing it
                // would discard useful retry/idempotency metadata.
                guard case .delete = operation,
                      state.remoteTombstones[operation.recordID] == nil,
                      retainedDeleteIDs.insert(operation.recordID).inserted else {
                    return nil
                }
                return operation
            }
            guard !retainedOperations.isEmpty else {
                appendUniqueSupersededAttemptReceipts(
                    entry.supersededAttemptReceipts,
                    to: &orphanedSupersededAttemptReceipts
                )
                if let attempted = entry.attemptedRequest {
                    let receipt = try FinanceImportedSupersededAttemptReceipt(
                        idempotencyKey: attempted.idempotencyKey,
                        recordIDs: clearedOperationRecordIDs
                    )
                    appendUniqueSupersededAttemptReceipts(
                        [receipt],
                        to: &orphanedSupersededAttemptReceipts
                    )
                }
                continue
            }

            if retainedOperations == entry.operations {
                retainedEntries.append(entry)
            } else {
                var supersededReceipts = entry.supersededAttemptReceipts
                if let attempted = entry.attemptedRequest {
                    let receipt = try FinanceImportedSupersededAttemptReceipt(
                        idempotencyKey: attempted.idempotencyKey,
                        recordIDs: clearedOperationRecordIDs
                    )
                    appendUniqueSupersededAttemptReceipts([receipt], to: &supersededReceipts)
                }
                retainedEntries.append(try rebuildCompactedEntry(
                    entry,
                    operations: retainedOperations,
                    supersededAttemptReceipts: supersededReceipts
                ))
            }
        }
        state.outbox = retainedEntries

        let missingDeletionIDs = clearedIDs
            .subtracting(retainedDeleteIDs)
            .filter { state.remoteTombstones[$0] == nil }
            .sorted { $0.uuidString.lowercased() < $1.uuidString.lowercased() }
        guard !missingDeletionIDs.isEmpty else {
            // A known remote tombstone needs no new delete operation. Keep a
            // late receipt marker on any surviving entry when possible; the
            // gateway cannot validly report a successful upsert over that
            // tombstone, but retaining the marker is safer than accepting an
            // unrelated response as the superseded attempt.
            if !orphanedSupersededAttemptReceipts.isEmpty, !state.outbox.isEmpty {
                var entry = state.outbox[0]
                try entry.setSupersededAttemptReceipts(
                    entry.supersededAttemptReceipts + orphanedSupersededAttemptReceipts
                )
                state.outbox[0] = entry
            }
            return
        }

        let deletions = missingDeletionIDs.map { id in
            FinanceImportedSyncOperation.delete(
                recordID: id,
                expectedSourceRevision: state.remoteRecordRevisions[id] ?? 0,
                deletedAt: deletedAt
            )
        }
        try appendToOutbox(
            deletions,
            state: &state,
            createdAt: deletedAt,
            supersededAttemptReceipts: orphanedSupersededAttemptReceipts
        )
    }

    /// Rebuilds a partially retained entry without carrying a stale attempted
    /// body whose operations no longer match. If the entry had already been
    /// attempted, preserve its base revision, ETag, attempt count, and last
    /// attempt time while issuing a new exact receipt for only the unrelated
    /// operations. This keeps retry accounting intact without retaining a
    /// cleared merchant payload in the durable bytes.
    private func rebuildCompactedEntry(
        _ entry: FinanceImportedPendingSyncEntry,
        operations: [FinanceImportedSyncOperation],
        supersededAttemptReceipts: [FinanceImportedSupersededAttemptReceipt]
    ) throws -> FinanceImportedPendingSyncEntry {
        guard !operations.isEmpty else { throw FinanceImportedTransactionStoreError.invalidEnvelope }

        if let attempted = entry.attemptedRequest {
            let request = try FinanceImportedSyncRequest(
                baseRevision: attempted.baseRevision,
                operations: operations
            )
            let body = try request.canonicalData()
            let idempotencyKey = "finance-import-\(UUID().uuidString)"
            let receipt = try FinanceImportedAttemptedSyncRequest(
                baseRevision: attempted.baseRevision,
                ifMatch: attempted.ifMatch,
                idempotencyKey: idempotencyKey,
                body: body
            )
            return try FinanceImportedPendingSyncEntry(
                idempotencyKey: idempotencyKey,
                operations: operations,
                createdAt: entry.createdAt,
                attemptCount: entry.attemptCount,
                lastAttemptAt: entry.lastAttemptAt,
                state: entry.state,
                blockedReason: entry.blockedReason,
                attemptedRequest: receipt,
                supersededAttemptReceipts: supersededAttemptReceipts
            )
        }

        return try FinanceImportedPendingSyncEntry(
            idempotencyKey: entry.idempotencyKey,
            operations: operations,
            createdAt: entry.createdAt,
            attemptCount: entry.attemptCount,
            lastAttemptAt: entry.lastAttemptAt,
            state: entry.state,
            blockedReason: entry.blockedReason,
            supersededAttemptReceipts: supersededAttemptReceipts
        )
    }

    private func canonicalOperationByteCount(_ operation: FinanceImportedSyncOperation) throws -> Int {
        let encoder = JSONEncoder.lifeOS
        encoder.outputFormatting = [.sortedKeys]
        return try encoder.encode(operation).count
    }

    private func emptyCanonicalRequestByteCount(baseRevision: Int) throws -> Int {
        let request = try FinanceImportedSyncRequest(baseRevision: baseRevision, operations: [])
        return try request.canonicalData().count
    }

    /// Partitions operations with an incremental byte budget. Encoding each
    /// operation once keeps migration and local import batching linear in the
    /// encoded input size; it avoids re-encoding the growing candidate request
    /// for every row. The preferred key stays on the final unattempted chunk
    /// when an existing entry must be split.
    private func partitionOperations(
        _ operations: [FinanceImportedSyncOperation],
        baseRevision: Int,
        createdAt: Date,
        attemptCount: Int = 0,
        lastAttemptAt: Date? = nil,
        preferredFinalKey: String? = nil
    ) throws -> [FinanceImportedPendingSyncEntry] {
        guard !operations.isEmpty else { return [] }
        let emptyRequestBytes = try emptyCanonicalRequestByteCount(baseRevision: baseRevision)
        var chunks: [[FinanceImportedSyncOperation]] = []
        var blockedChunks = [Bool]()
        var current: [FinanceImportedSyncOperation] = []
        var currentRequestBytes = emptyRequestBytes

        func emitCurrent() {
            guard !current.isEmpty else { return }
            chunks.append(current)
            blockedChunks.append(false)
            current.removeAll(keepingCapacity: true)
            currentRequestBytes = emptyRequestBytes
        }

        for operation in operations {
            let operationBytes = try canonicalOperationByteCount(operation)
            if current.count >= Self.maximumOperationsPerEntry {
                emitCurrent()
            }
            let candidateBytes = current.isEmpty
                ? emptyRequestBytes + operationBytes
                : currentRequestBytes + 1 + operationBytes
            if candidateBytes <= FinanceImportedSyncRequest.maximumRequestBytes {
                current.append(operation)
                currentRequestBytes = candidateBytes
                continue
            }

            if !current.isEmpty {
                emitCurrent()
            }
            if emptyRequestBytes + operationBytes <= FinanceImportedSyncRequest.maximumRequestBytes {
                current = [operation]
                currentRequestBytes = emptyRequestBytes + operationBytes
            } else {
                chunks.append([operation])
                blockedChunks.append(true)
            }
        }
        emitCurrent()

        return try chunks.enumerated().map { index, operations in
            let isLast = index == chunks.count - 1
            return try FinanceImportedPendingSyncEntry(
                idempotencyKey: isLast ? (preferredFinalKey ?? "finance-import-\(UUID().uuidString)") : "finance-import-\(UUID().uuidString)",
                operations: operations,
                createdAt: createdAt,
                attemptCount: attemptCount,
                lastAttemptAt: lastAttemptAt,
                state: blockedChunks[index] ? .blocked : .pending,
                blockedReason: blockedChunks[index] ? .payloadTooLarge : nil
            )
        }
    }

    private func appendToOutbox(
        _ operations: [FinanceImportedSyncOperation],
        state: inout State,
        createdAt: Date = .now,
        supersededAttemptReceipts: [FinanceImportedSupersededAttemptReceipt] = []
    ) throws {
        guard operations.count <= Self.maximumPendingOperations else { throw FinanceImportedTransactionStoreError.syncOutboxFull }
        let existingOperationCount = state.outbox.reduce(into: 0) { count, entry in
            count += entry.operations.count
        }
        guard existingOperationCount <= Self.maximumPendingOperations - operations.count else {
            throw FinanceImportedTransactionStoreError.syncOutboxFull
        }
        var additions = try partitionOperations(
            operations,
            baseRevision: state.remoteRevision,
            createdAt: createdAt
        )
        guard state.outbox.count + additions.count <= Self.maximumOutboxEntries else { throw FinanceImportedTransactionStoreError.syncOutboxFull }
        if !supersededAttemptReceipts.isEmpty {
            var first = additions[0]
            try first.setSupersededAttemptReceipts(supersededAttemptReceipts)
            additions[0] = first
        }
        state.outbox.append(contentsOf: additions)
    }

    private static let legacyIdentityMarkerKeys: Set<String> = [
        "identityScheme", "identitySchemeVersion", "identityVersion",
        "stableIDScheme", "stableIDVersion", "stableIdentityVersion",
        "identityAlgorithm"
    ]

    private static func legacyIdentityMappingIDs(in data: Data) -> Set<UUID> {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return []
        }
        var ids = Set<UUID>()
        if let encodedIDs = root["legacyIdentityMappingIDs"] as? [String] {
            for rawID in encodedIDs {
                if let id = UUID(uuidString: rawID) { ids.insert(id) }
            }
        }
        guard let mappings = root["importMappings"] as? [[String: Any]] else { return ids }
        for mapping in mappings {
            guard let rawID = mapping["id"] as? String,
                  let id = UUID(uuidString: rawID) else { continue }
            let marker = mapping.contains { key, value in
                guard Self.legacyIdentityMarkerKeys.contains(key) else { return false }
                if let string = value as? String {
                    let normalized = string.lowercased()
                    let compact = normalized
                        .replacingOccurrences(of: "-", with: "")
                        .replacingOccurrences(of: "_", with: "")
                    return compact.contains("mappedv2")
                        || compact == "v2"
                        || compact == "legacyv2"
                }
                if let number = value as? NSNumber { return number.intValue == 2 }
                return false
            }
            if marker { ids.insert(id) }
        }
        return ids
    }

    private static func strippingLegacyIdentityMarkers(from data: Data) -> Data? {
        guard var root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              var mappings = root["importMappings"] as? [[String: Any]],
              !mappings.isEmpty else {
            return nil
        }
        var removed = false
        for index in mappings.indices {
            let keys = mappings[index].keys.filter { Self.legacyIdentityMarkerKeys.contains($0) }
            for key in keys {
                mappings[index].removeValue(forKey: key)
                removed = true
            }
        }
        guard removed else { return nil }
        root["importMappings"] = mappings
        return try? JSONSerialization.data(withJSONObject: root, options: [.sortedKeys])
    }

    private func readBoundedStateData() throws -> Data {
        let handle: FileHandle
        do {
            handle = try FileHandle(forReadingFrom: fileURL)
        } catch {
            throw FinanceImportedTransactionStoreError.readFailed
        }
        defer { try? handle.close() }

        var data = Data()
        data.reserveCapacity(min(Self.maximumStateBytes, 64 * 1024))
        do {
            while data.count <= Self.maximumStateBytes {
                let remaining = Self.maximumStateBytes + 1 - data.count
                guard remaining > 0 else { break }
                let chunk = try handle.read(upToCount: min(remaining, 64 * 1024)) ?? Data()
                if chunk.isEmpty { break }
                data.append(contentsOf: chunk)
            }
        } catch {
            throw FinanceImportedTransactionStoreError.readFailed
        }
        guard data.count <= Self.maximumStateBytes else {
            throw FinanceImportedTransactionStoreError.stateTooLarge
        }
        return data
    }

    private func loadStateUnlocked() throws -> State {
        guard fileManager.fileExists(atPath: fileURL.path) else {
            return State(transactions: [], remoteRevision: 0, remoteETag: nil,
                         remoteRecordRevisions: [:], remoteTombstones: [:], outbox: [],
                         importMappings: [], importBatches: [], legacyIdentityMappingIDs: [],
                         legacyGenericTransactionIDs: [])
        }
        let data = try readBoundedStateData()
        let detectedLegacyIdentityMappingIDs = Self.legacyIdentityMappingIDs(in: data)
        let envelope: FinanceImportedTransactionStoreEnvelope
        do {
            envelope = try JSONDecoder.lifeOS.decode(FinanceImportedTransactionStoreEnvelope.self, from: data)
        } catch let error as FinanceImportedTransactionStoreError {
            throw error
        } catch {
            guard !detectedLegacyIdentityMappingIDs.isEmpty,
                  let sanitizedData = Self.strippingLegacyIdentityMarkers(from: data) else {
                throw FinanceImportedTransactionStoreError.invalidEnvelope
            }
            do {
                envelope = try JSONDecoder.lifeOS.decode(FinanceImportedTransactionStoreEnvelope.self, from: sanitizedData)
            } catch {
                throw FinanceImportedTransactionStoreError.invalidEnvelope
            }
        }
        let decoderLegacyIdentityMappingIDs = Set(
            envelope.importMappings.filter(\.usesLegacyIdentityScheme).map(\.id)
        )
        let legacyIdentityMappingIDs = Set(envelope.legacyIdentityMappingIDs)
            .union(decoderLegacyIdentityMappingIDs)
            .union(detectedLegacyIdentityMappingIDs)
        var modernMappingsByID: [UUID: FinanceImportMapping] = [:]
        for mapping in envelope.importMappings where !mapping.usesLegacyIdentityScheme {
            guard modernMappingsByID[mapping.id] == nil else {
                throw FinanceImportedTransactionStoreError.invalidEnvelope
            }
            modernMappingsByID[mapping.id] = mapping
        }
        var mappedIdentitiesByTransactionID: [UUID: FinanceImportedMappedIdentity] = [:]
        for batch in envelope.importBatches {
            guard let mappingID = batch.mappingID,
                  let mapping = modernMappingsByID[mappingID] else { continue }
            let mappedIdentity = try FinanceImportedMappedIdentity(mapping: mapping)
            for link in batch.rowLinks {
                if let prior = mappedIdentitiesByTransactionID[link.transactionID], prior != mappedIdentity {
                    throw FinanceImportedTransactionStoreError.invalidEnvelope
                }
                mappedIdentitiesByTransactionID[link.transactionID] = mappedIdentity
            }
        }
        for transaction in envelope.transactions {
            guard let expected = mappedIdentitiesByTransactionID[transaction.id] else { continue }
            if transaction.identityScheme == .mappedV3,
               let actual = transaction.mappedIdentity,
               actual != expected {
                throw FinanceImportedTransactionStoreError.invalidEnvelope
            }
        }
        let normalizedTransactions = envelope.transactions.map { transaction in
            guard transaction.source == .genericCSV,
                  let mappedIdentity = mappedIdentitiesByTransactionID[transaction.id] else {
                return transaction
            }
            return transaction
                .withIdentityScheme(.mappedV3)
                .withMappedIdentity(mappedIdentity)
        }
        let normalizedMappedIdentitySchemes = normalizedTransactions != envelope.transactions
        let linkedImportTransactionIDs = Set(envelope.importBatches.flatMap { $0.rowLinks.map(\.transactionID) })
        let inferredLegacyGenericTransactionIDs = Set(
            normalizedTransactions
                .filter {
                    $0.source == .genericCSV
                        && $0.identityScheme == .legacyV2
                        && !linkedImportTransactionIDs.contains($0.id)
                }
                .map(\.id)
        )
        let legacyGenericCandidates = Set(envelope.legacyGenericTransactionIDs)
            .union(inferredLegacyGenericTransactionIDs)
        let legacyGenericTransactionIDs = Set(
            normalizedTransactions
                .filter {
                    $0.source == .genericCSV
                        && $0.identityScheme == .legacyV2
                        && legacyGenericCandidates.contains($0.id)
                }
                .map(\.id)
        )

        var revisions: [UUID: Int] = [:]
        for (rawID, revision) in envelope.remoteRecordRevisions {
            guard let id = UUID(uuidString: rawID), rawID.lowercased() == id.uuidString.lowercased(),
                  revision > 0, revision <= FinanceImportedSyncRecord.maximumSafeCents else {
                throw FinanceImportedTransactionStoreError.invalidEnvelope
            }
            revisions[id] = revision
        }
        var tombstones: [UUID: FinanceImportedSyncTombstone] = [:]
        for tombstone in envelope.remoteTombstones {
            guard tombstones[tombstone.recordID] == nil else { throw FinanceImportedTransactionStoreError.invalidEnvelope }
            tombstones[tombstone.recordID] = tombstone
        }

        var state = State(
            transactions: normalizedTransactions, remoteRevision: envelope.remoteRevision, remoteETag: envelope.remoteETag,
            remoteRecordRevisions: revisions, remoteTombstones: tombstones, outbox: envelope.outbox,
            importMappings: envelope.importMappings, importBatches: envelope.importBatches,
            legacyIdentityMappingIDs: legacyIdentityMappingIDs.sorted { $0.uuidString < $1.uuidString },
            legacyGenericTransactionIDs: legacyGenericTransactionIDs.sorted { $0.uuidString < $1.uuidString }
        )
        guard envelope.remoteRevision >= 0, envelope.remoteRevision <= FinanceImportedSyncRecord.maximumSafeCents else {
            throw FinanceImportedTransactionStoreError.invalidEnvelope
        }
        var changed = envelope.schemaVersion != FinanceImportedTransactionStoreEnvelope.currentSchemaVersion
            || Set(envelope.legacyIdentityMappingIDs) != legacyIdentityMappingIDs
            || Set(envelope.legacyGenericTransactionIDs) != legacyGenericTransactionIDs
            || normalizedMappedIdentitySchemes
        if let etag = state.remoteETag,
           (TailscaleSyncClient.validatedFinanceImportedETag(etag) == nil
            || TailscaleSyncClient.financeImportedETagRevision(etag) != state.remoteRevision) {
            state.remoteETag = nil
            changed = true
        }

        if envelope.schemaVersion == FinanceImportedTransactionStoreEnvelope.legacySchemaVersion {
            let migrated = try state.transactions.map {
                try FinanceImportedSyncOperation.upsert(
                    record: FinanceImportedSyncRecord(validating: $0, sourceRevision: 0), expectedSourceRevision: 0
                )
            }
            state.outbox = try makeEntries(for: migrated, state: state)
            changed = true
        } else {
            var rebuilt: [FinanceImportedPendingSyncEntry] = []
            for entry in state.outbox {
                let operations = try migrateLegacyOperations(entry.operations, state: state)
                let migratedEntry = try FinanceImportedPendingSyncEntry(
                    idempotencyKey: entry.idempotencyKey, operations: operations, createdAt: entry.createdAt,
                    attemptCount: entry.attemptCount, lastAttemptAt: entry.lastAttemptAt, state: entry.state,
                    blockedReason: entry.blockedReason, attemptedRequest: entry.attemptedRequest,
                    supersededAttemptReceipts: entry.supersededAttemptReceipts
                )
                if operations != entry.operations { changed = true }
                if migratedEntry.attemptedRequest == nil && migratedEntry.state == .pending {
                    let split = try splitEntryIfNeeded(migratedEntry, state: state)
                    rebuilt.append(contentsOf: split)
                    if split.count != 1 || split[0] != migratedEntry { changed = true }
                } else {
                    rebuilt.append(migratedEntry)
                }
            }
            if rebuilt != state.outbox { state.outbox = rebuilt; changed = true }
        }

        if state.remoteRecordRevisions.isEmpty, state.remoteRevision > 0, !state.transactions.isEmpty {
            var derivedRevision = false
            for transaction in state.transactions where state.remoteTombstones[transaction.id] == nil {
                state.remoteRecordRevisions[transaction.id] = state.remoteRevision
                derivedRevision = true
            }
            changed = derivedRevision || changed
        }
        try validateState(state)
        changed = markIneligibleEntries(&state) || changed
        if changed { try saveStateUnlocked(state) }
        return state
    }

    private func migrateLegacyOperations(_ operations: [FinanceImportedSyncOperation], state: State) throws -> [FinanceImportedSyncOperation] {
        try operations.map { operation in
            switch operation {
            case .legacyUpsert(let record, let action):
                let expected = state.remoteRecordRevisions[record.recordID] ?? (state.remoteRevision > 0 ? state.remoteRevision : 0)
                if expected > 0 {
                    switch action {
                    case .set:
                        if let category = record.categoryOverride {
                            return .categorySet(recordID: record.recordID, expectedSourceRevision: expected, categoryOverride: category)
                        }
                    case .clear:
                        return .categoryClear(recordID: record.recordID, expectedSourceRevision: expected)
                    case .preserve:
                        break
                    }
                }
                // A legacy whole-record operation has no immutable source
                // precondition. Preserve its local source data, but send it
                // as a new create candidate so it can never overwrite a row
                // observed by another device during migration.
                return .upsert(record: try record.withSourceRevision(0), expectedSourceRevision: 0)
            case .legacyDelete(let id, let deletedAt):
                return .delete(recordID: id, expectedSourceRevision: state.remoteRecordRevisions[id] ?? 0, deletedAt: deletedAt)
            default:
                return operation
            }
        }
    }

    private func makeEntries(for operations: [FinanceImportedSyncOperation], state: State) throws -> [FinanceImportedPendingSyncEntry] {
        return try partitionOperations(
            operations,
            baseRevision: state.remoteRevision,
            createdAt: .now
        )
    }

    private func splitEntryIfNeeded(_ entry: FinanceImportedPendingSyncEntry, state: State) throws -> [FinanceImportedPendingSyncEntry] {
        // A legacy entry with a nonzero attempt count has already entered the
        // transmission lifecycle even if it predates persisted request bytes.
        // Leave it intact so it can be surfaced as blocked rather than split
        // into a different set of writes.
        guard entry.attemptedRequest == nil, entry.attemptCount == 0, entry.state == .pending else { return [entry] }
        var split = try partitionOperations(
            entry.operations,
            baseRevision: state.remoteRevision,
            createdAt: entry.createdAt,
            attemptCount: entry.attemptCount,
            lastAttemptAt: entry.lastAttemptAt,
            preferredFinalKey: entry.idempotencyKey
        )
        guard !entry.supersededAttemptReceipts.isEmpty else { return split }
        guard var first = split.first else {
            throw FinanceImportedTransactionStoreError.invalidEnvelope
        }
        try first.setSupersededAttemptReceipts(entry.supersededAttemptReceipts)
        split[0] = first
        return split
    }

    private func markIneligibleEntries(_ state: inout State) -> Bool {
        var changed = false
        for index in state.outbox.indices where state.outbox[index].state == .pending {
            // Apply the same policy order as prepareHeadUnlocked. Age and
            // attempt exhaustion are durable status, not decode failures;
            // classify them before the pre-v3 missing-receipt fallback.
            if Date().timeIntervalSince(state.outbox[index].createdAt) > Self.maximumRetryAge {
                state.outbox[index].state = .blocked
                state.outbox[index].blockedReason = .retryExpired
                changed = true
            } else if state.outbox[index].attemptCount >= FinanceImportedPendingSyncEntry.maximumAttempts {
                state.outbox[index].state = .blocked
                state.outbox[index].blockedReason = .attemptsExhausted
                changed = true
            } else if state.outbox[index].attemptCount > 0 && state.outbox[index].attemptedRequest == nil {
                // A pre-v3 entry reports that transmission began but has no
                // immutable bytes to replay. Do not invent a new request
                // body during migration; preserve the work as recoverable
                // blocked state instead.
                state.outbox[index].state = .blocked
                state.outbox[index].blockedReason = .invalidEnvelope
                changed = true
            }
        }
        return changed
    }

    private func validateState(_ state: State) throws {
        guard state.transactions.count <= Self.maximumTransactions,
              state.remoteRevision >= 0, state.remoteRevision <= FinanceImportedSyncRecord.maximumSafeCents,
              state.remoteRecordRevisions.count <= Self.maximumTransactions,
              state.remoteTombstones.count <= FinanceImportedSyncSnapshot.maximumTombstones,
              state.outbox.count <= Self.maximumOutboxEntries,
              state.outbox.flatMap({ $0.operations }).count <= Self.maximumPendingOperations else {
            throw FinanceImportedTransactionStoreError.invalidEnvelope
        }
        guard Set(state.transactions.map(\.id)).count == state.transactions.count else { throw FinanceImportedTransactionStoreError.invalidEnvelope }
        if let etag = state.remoteETag,
           (TailscaleSyncClient.validatedFinanceImportedETag(etag) == nil
            || TailscaleSyncClient.financeImportedETagRevision(etag) != state.remoteRevision) {
            throw FinanceImportedTransactionStoreError.invalidEnvelope
        }
        for transaction in state.transactions {
            do { _ = try FinanceImportedSyncRecord(validating: transaction) }
            catch { throw FinanceImportedTransactionStoreError.invalidEnvelope }
        }
        for (id, revision) in state.remoteRecordRevisions {
            guard revision > 0, revision <= FinanceImportedSyncRecord.maximumSafeCents, state.remoteTombstones[id] == nil else {
                throw FinanceImportedTransactionStoreError.invalidEnvelope
            }
        }
        for (id, tombstone) in state.remoteTombstones {
            guard id == tombstone.recordID, tombstone.revision <= state.remoteRevision else { throw FinanceImportedTransactionStoreError.invalidEnvelope }
        }
        for entry in state.outbox {
            guard entry.operations.count <= FinanceImportedPendingSyncEntry.maximumOperations,
                  Set(entry.operations.map(\.recordID)).count == entry.operations.count else {
                throw FinanceImportedTransactionStoreError.invalidEnvelope
            }
            if let attempted = entry.attemptedRequest {
                guard attempted.idempotencyKey == entry.idempotencyKey else { throw FinanceImportedTransactionStoreError.invalidEnvelope }
                _ = try attempted.decodedRequest()
            }
        }
        guard state.importMappings.count <= Self.maximumImportMappings,
              state.importBatches.count <= Self.maximumImportBatches,
              state.importBatches.reduce(0, { $0 + $1.rowLinks.count }) <= Self.maximumImportRowLinks,
              Set(state.importMappings.map(\.id)).count == state.importMappings.count,
              Set(state.importBatches.map(\.id)).count == state.importBatches.count,
              state.legacyIdentityMappingIDs.count <= Self.maximumImportMappings,
              Set(state.legacyIdentityMappingIDs).count == state.legacyIdentityMappingIDs.count,
              state.legacyGenericTransactionIDs.count <= Self.maximumTransactions,
              Set(state.legacyGenericTransactionIDs).count == state.legacyGenericTransactionIDs.count else {
            throw FinanceImportedTransactionStoreError.invalidEnvelope
        }
        let localTransactionIDs = Set(state.transactions.map(\.id))
        let transactionsByID = Dictionary(uniqueKeysWithValues: state.transactions.map { ($0.id, $0) })
        guard Set(state.legacyGenericTransactionIDs).isSubset(of: localTransactionIDs),
              state.legacyGenericTransactionIDs.allSatisfy({
                  transactionsByID[$0]?.source == .genericCSV
                      && transactionsByID[$0]?.identityScheme == .legacyV2
              }) else {
            throw FinanceImportedTransactionStoreError.invalidEnvelope
        }
        let mappingIDs = Set(state.importMappings.map(\.id))
        guard Set(state.legacyIdentityMappingIDs).isSubset(of: mappingIDs) else {
            throw FinanceImportedTransactionStoreError.invalidEnvelope
        }
        let mappingsByID = Dictionary(uniqueKeysWithValues: state.importMappings.map { ($0.id, $0) })
        guard state.legacyIdentityMappingIDs.allSatisfy({ mappingsByID[$0]?.usesLegacyIdentityScheme == true }) else {
            throw FinanceImportedTransactionStoreError.invalidEnvelope
        }
        for batch in state.importBatches {
            guard batch.mappingID.map(mappingIDs.contains) ?? true,
                  !batch.rowLinks.isEmpty,
                  Set(batch.rowLinks.map(\.batchID)) == Set([batch.id]),
                  Set(batch.rowLinks.map(\.transactionID)).count == batch.rowLinks.count,
                  batch.rowLinks.allSatisfy({ localTransactionIDs.contains($0.transactionID) }) else {
                throw FinanceImportedTransactionStoreError.invalidEnvelope
            }
            switch batch.effectiveDetection.state {
            case .known:
                guard batch.effectiveDetection.institution != nil, batch.mappingID == nil else {
                    throw FinanceImportedTransactionStoreError.invalidEnvelope
                }
            case .userMapped:
                guard batch.effectiveDetection.institution == nil, batch.mappingID != nil else {
                    throw FinanceImportedTransactionStoreError.invalidEnvelope
                }
            case .unknown, .ambiguous:
                throw FinanceImportedTransactionStoreError.invalidEnvelope
            }
        }
        for mapping in state.importMappings {
            guard mapping.schemaVersion == FinanceImportMapping.schemaVersion,
                  mapping.columnCount > 0 else {
                throw FinanceImportedTransactionStoreError.invalidEnvelope
            }
        }
    }

    private func reconcileLegacyGenericFence(_ state: inout State) {
        let linkedTransactionIDs = Set(state.importBatches.flatMap { $0.rowLinks.map(\.transactionID) })
        let currentGenericTransactionIDs = Set(
            state.transactions
                .filter { $0.source == .genericCSV && $0.identityScheme == .legacyV2 }
                .map(\.id)
        )
        let inferred = state.transactions
            .filter {
                $0.source == .genericCSV
                    && $0.identityScheme == .legacyV2
                    && !linkedTransactionIDs.contains($0.id)
            }
            .map(\.id)
        state.legacyGenericTransactionIDs = Set(state.legacyGenericTransactionIDs)
            .intersection(currentGenericTransactionIDs)
            .union(inferred)
            .sorted { $0.uuidString < $1.uuidString }
    }

    private func saveStateUnlocked(_ input: State) throws {
        var state = input
        reconcileLegacyGenericFence(&state)
        try validateState(state)
        let envelope = FinanceImportedTransactionStoreEnvelope(
            transactions: state.transactions,
            remoteRevision: state.remoteRevision,
            remoteETag: state.remoteETag,
            remoteRecordRevisions: Dictionary(uniqueKeysWithValues: state.remoteRecordRevisions.map { ($0.key.uuidString.lowercased(), $0.value) }),
            remoteTombstones: state.remoteTombstones.values.sorted { $0.recordID.uuidString < $1.recordID.uuidString },
            outbox: state.outbox,
            importMappings: state.importMappings,
            importBatches: state.importBatches,
            legacyIdentityMappingIDs: state.legacyIdentityMappingIDs,
            legacyGenericTransactionIDs: state.legacyGenericTransactionIDs
        )
        let data: Data
        do { data = try JSONEncoder.lifeOS.encode(envelope) }
        catch let error as FinanceImportedTransactionStoreError { throw error }
        catch { throw FinanceImportedTransactionStoreError.invalidEnvelope }
        guard data.count <= Self.maximumStateBytes else { throw FinanceImportedTransactionStoreError.stateTooLarge }
        do { try atomicReplace(data) } catch { throw FinanceImportedTransactionStoreError.writeFailed }
    }

    private func atomicReplace(_ data: Data) throws {
        let directory = fileURL.deletingLastPathComponent()
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true, attributes: nil)
        let temporary = directory.appendingPathComponent(".\(fileURL.lastPathComponent).\(UUID().uuidString).tmp", isDirectory: false)
        defer { if fileManager.fileExists(atPath: temporary.path) { try? fileManager.removeItem(at: temporary) } }
#if os(iOS)
        try data.write(to: temporary, options: [.atomic, .completeFileProtection])
#else
        try data.write(to: temporary, options: [.atomic])
#endif
        if fileManager.fileExists(atPath: fileURL.path) { _ = try fileManager.replaceItemAt(fileURL, withItemAt: temporary) }
        else { try fileManager.moveItem(at: temporary, to: fileURL) }
    }
}
