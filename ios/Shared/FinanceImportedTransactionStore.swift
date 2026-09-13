import Foundation

// MARK: - Durable local storage for manually imported bank-statement transactions

public enum FinanceImportedTransactionStoreError: Error, Equatable, Sendable {
    case applicationSupportUnavailable
    case readFailed
    case invalidEnvelope
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
            guard request.baseRevision == baseRevision, try request.canonicalData() == body else {
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
/// immutable attempted envelopes. Versions 1 and 2 are decoded only to run a
/// one-time explicit migration; unknown versions fail closed.
public struct FinanceImportedTransactionStoreEnvelope: Codable, Equatable, Sendable {
    public static let legacySchemaVersion = 1
    public static let previousSchemaVersion = 2
    public static let currentSchemaVersion = 3

    public let schemaVersion: Int
    public let transactions: [FinanceImportedTransaction]
    public let remoteRevision: Int
    public let remoteETag: String?
    public let remoteRecordRevisions: [String: Int]
    public let remoteTombstones: [FinanceImportedSyncTombstone]
    public let outbox: [FinanceImportedPendingSyncEntry]

    private enum CodingKeys: String, CodingKey, CaseIterable {
        case schemaVersion, transactions, remoteRevision, remoteETag
        case remoteRecordRevisions, remoteTombstones, outbox
    }

    public init(
        transactions: [FinanceImportedTransaction] = [],
        remoteRevision: Int = 0,
        remoteETag: String? = nil,
        remoteRecordRevisions: [String: Int] = [:],
        remoteTombstones: [FinanceImportedSyncTombstone] = [],
        outbox: [FinanceImportedPendingSyncEntry] = []
    ) {
        schemaVersion = Self.currentSchemaVersion
        self.transactions = transactions
        self.remoteRevision = remoteRevision
        self.remoteETag = remoteETag
        self.remoteRecordRevisions = remoteRecordRevisions
        self.remoteTombstones = remoteTombstones
        self.outbox = outbox
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
        case Self.currentSchemaVersion:
            guard Set(container.allKeys) == Set(CodingKeys.allCases) else {
                throw FinanceImportedTransactionStoreError.invalidEnvelope
            }
            self.schemaVersion = schemaVersion
            transactions = try container.decode([FinanceImportedTransaction].self, forKey: .transactions)
            remoteRevision = try container.decode(Int.self, forKey: .remoteRevision)
            remoteETag = try container.decodeIfPresent(String.self, forKey: .remoteETag)
            remoteRecordRevisions = try container.decode([String: Int].self, forKey: .remoteRecordRevisions)
            remoteTombstones = try container.decode([FinanceImportedSyncTombstone].self, forKey: .remoteTombstones)
            outbox = try container.decode([FinanceImportedPendingSyncEntry].self, forKey: .outbox)
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

    private static let processTransactionLock = NSLock()
    private static let maximumOperationsPerEntry = FinanceImportedPendingSyncEntry.maximumOperations

    private struct State {
        var transactions: [FinanceImportedTransaction]
        var remoteRevision: Int
        var remoteETag: String?
        var remoteRecordRevisions: [UUID: Int]
        var remoteTombstones: [UUID: FinanceImportedSyncTombstone]
        var outbox: [FinanceImportedPendingSyncEntry]
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

    @discardableResult
    public func add(_ transactions: [FinanceImportedTransaction]) throws -> FinanceImportSaveResult {
        guard !transactions.isEmpty else {
            return FinanceImportSaveResult(requestedCount: 0, insertedCount: 0, duplicateCount: 0, storedCount: try all().count)
        }
        Self.processTransactionLock.lock()
        defer { Self.processTransactionLock.unlock() }
        var state = try loadStateUnlocked()
        guard state.transactions.count <= Self.maximumTransactions else { throw FinanceImportedTransactionStoreError.stateTooLarge }
        var indexByID = Dictionary(uniqueKeysWithValues: state.transactions.enumerated().map { ($0.element.id, $0.offset) })
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
                if candidate.category == nil { candidate.category = existing.category }
                candidate = FinanceImportedTransaction(
                    id: candidate.id, bookedAt: candidate.bookedAt, amountCents: candidate.amountCents,
                    description: candidate.description, category: candidate.category, source: candidate.source,
                    importedAt: existing.importedAt, sourceCategory: candidate.sourceCategory,
                    providerCode: candidate.providerCode, kind: candidate.kind, investment: candidate.investment
                )
                if existing.hasSameSourceObservation(as: candidate), existing.category == candidate.category {
                    duplicateCount += 1
                } else {
                    state.transactions[index] = candidate
                    changedOperations.append(.upsert(
                        record: try FinanceImportedSyncRecord(validating: candidate, sourceRevision: expected),
                        expectedSourceRevision: expected
                    ))
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
        state.transactions.append(contentsOf: additions)
        let result = FinanceImportSaveResult(requestedCount: transactions.count, insertedCount: additions.count,
                                             updatedCount: updatedCount, duplicateCount: duplicateCount,
                                             storedCount: state.transactions.count)
        guard !changedOperations.isEmpty else { return result }
        try appendToOutbox(changedOperations, state: &state)
        try saveStateUnlocked(state)
        return result
    }

    public func remove(id: UUID) throws {
        Self.processTransactionLock.lock()
        defer { Self.processTransactionLock.unlock() }
        var state = try loadStateUnlocked()
        guard let index = state.transactions.firstIndex(where: { $0.id == id }) else { throw FinanceImportedTransactionStoreError.transactionNotFound }
        state.transactions.remove(at: index)
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
        guard !clearedIDs.isEmpty else { return }
        state.transactions.removeAll(keepingCapacity: false)
        try compactOutboxForClearAll(clearedIDs: clearedIDs, state: &state, deletedAt: .now)
        try saveStateUnlocked(state)
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
        mergeRemoteUnlocked(result, state: &state)
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
            mergeRemoteUnlocked(result, state: &state)
            blockSupersededAttemptReceiptUnlocked(reconciliationReceipt.idempotencyKey, state: &state)
            try saveStateUnlocked(state)
            throw FinanceImportedTransactionStoreError.syncReceiptUnresolved
        }
        if isCurrentHead {
            state.outbox.removeFirst()
        }
        mergeRemoteUnlocked(result, state: &state)
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
        mergeRemoteUnlocked(result, state: &state)
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

    private func mergeRemoteUnlocked(_ result: FinanceImportedSyncResult, state: inout State) {
        let protectedIDs = Set(state.outbox.flatMap { $0.operations.map(\.recordID) })
        var byID = Dictionary(uniqueKeysWithValues: state.transactions.map { ($0.id, $0) })
        for record in result.snapshot.records where !protectedIDs.contains(record.recordID) {
            byID[record.recordID] = record.transaction
        }
        for tombstone in result.snapshot.tombstones where !protectedIDs.contains(tombstone.recordID) {
            byID.removeValue(forKey: tombstone.recordID)
        }
        state.transactions = byID.values.sorted {
            if $0.bookedAt != $1.bookedAt { return $0.bookedAt < $1.bookedAt }
            return $0.id.uuidString < $1.id.uuidString
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

    private func loadStateUnlocked() throws -> State {
        guard fileManager.fileExists(atPath: fileURL.path) else {
            return State(transactions: [], remoteRevision: 0, remoteETag: nil,
                         remoteRecordRevisions: [:], remoteTombstones: [:], outbox: [])
        }
        let data: Data
        do { data = try Data(contentsOf: fileURL) } catch { throw FinanceImportedTransactionStoreError.readFailed }
        guard data.count <= Self.maximumStateBytes else { throw FinanceImportedTransactionStoreError.stateTooLarge }
        let envelope: FinanceImportedTransactionStoreEnvelope
        do { envelope = try JSONDecoder.lifeOS.decode(FinanceImportedTransactionStoreEnvelope.self, from: data) }
        catch let error as FinanceImportedTransactionStoreError { throw error }
        catch { throw FinanceImportedTransactionStoreError.invalidEnvelope }

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
            transactions: envelope.transactions, remoteRevision: envelope.remoteRevision, remoteETag: envelope.remoteETag,
            remoteRecordRevisions: revisions, remoteTombstones: tombstones, outbox: envelope.outbox
        )
        guard envelope.remoteRevision >= 0, envelope.remoteRevision <= FinanceImportedSyncRecord.maximumSafeCents else {
            throw FinanceImportedTransactionStoreError.invalidEnvelope
        }
        var changed = envelope.schemaVersion != FinanceImportedTransactionStoreEnvelope.currentSchemaVersion
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
    }

    private func saveStateUnlocked(_ state: State) throws {
        try validateState(state)
        let envelope = FinanceImportedTransactionStoreEnvelope(
            transactions: state.transactions,
            remoteRevision: state.remoteRevision,
            remoteETag: state.remoteETag,
            remoteRecordRevisions: Dictionary(uniqueKeysWithValues: state.remoteRecordRevisions.map { ($0.key.uuidString.lowercased(), $0.value) }),
            remoteTombstones: state.remoteTombstones.values.sorted { $0.recordID.uuidString < $1.recordID.uuidString },
            outbox: state.outbox
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
