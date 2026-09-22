import Foundation

public enum CalendarStoreError: Error, Equatable, Sendable {
    case invalidAppGroupIdentifier
    case unsupportedSchemaVersion(Int)
    case invalidEnvelope
    case corruptStore
    case payloadTooLarge
}

private struct CalendarStoreCodingKey: CodingKey, Hashable {
    let stringValue: String
    let intValue: Int? = nil

    init?(stringValue: String) { self.stringValue = stringValue }
    init?(intValue: Int) { return nil }
}

private func calendarStoreKey(_ value: String) throws -> CalendarStoreCodingKey {
    guard let key = CalendarStoreCodingKey(stringValue: value) else {
        throw CalendarStoreError.invalidEnvelope
    }
    return key
}

public struct CalendarSeriesLink: Codable, Equatable, Sendable {
    public let itemID: String
    public let seriesID: String

    public init(itemID: UUID, seriesID: UUID) {
        self.itemID = itemID.uuidString.lowercased()
        self.seriesID = seriesID.uuidString.lowercased()
    }

    public init(itemID: String, seriesID: String) throws {
        try SyncContractValidation.requireUUID(itemID)
        try SyncContractValidation.requireUUID(seriesID)
        self.itemID = itemID
        self.seriesID = seriesID
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CalendarStoreCodingKey.self)
        guard Set(container.allKeys.map(\.stringValue)) == Set(["itemID", "seriesID"]) else {
            throw CalendarStoreError.invalidEnvelope
        }
        let itemIDKey = try calendarStoreKey("itemID")
        let seriesIDKey = try calendarStoreKey("seriesID")
        try self.init(
            itemID: try container.decode(String.self, forKey: itemIDKey),
            seriesID: try container.decode(String.self, forKey: seriesIDKey)
        )
    }
}

public struct CalendarStoreEnvelope: Codable, Equatable, Sendable {
    public static let currentSchemaVersion = 1
    public static let maximumEncodedBytes = 32 * 1_024 * 1_024
    public static let maximumLedgerEntries = SyncContractConstants.maxPageOperations * 8

    public let schemaVersion: Int
    public let snapshot: CalendarSnapshot
    public let seriesMembership: [CalendarSeriesLink]
    public let replication: SyncAdapterEnvelope?

    public init(
        schemaVersion: Int = Self.currentSchemaVersion,
        snapshot: CalendarSnapshot,
        seriesMembership: [CalendarSeriesLink],
        replication: SyncAdapterEnvelope? = nil
    ) throws {
        guard schemaVersion == Self.currentSchemaVersion else {
            throw CalendarStoreError.unsupportedSchemaVersion(schemaVersion)
        }
        self.schemaVersion = schemaVersion
        self.snapshot = snapshot
        self.seriesMembership = seriesMembership.sorted { lhs, rhs in
            lhs.itemID == rhs.itemID ? lhs.seriesID < rhs.seriesID : lhs.itemID < rhs.itemID
        }
        self.replication = replication
        try validate()
    }

    private enum CodingKeys: String, CodingKey {
        case schemaVersion, snapshot, seriesMembership, replication
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CalendarStoreCodingKey.self)
        let keys = Set(container.allKeys.map(\.stringValue))
        let requiredKeys: Set<String> = ["schemaVersion", "snapshot", "seriesMembership"]
        let optionalKeys: Set<String> = ["replication"]
        guard requiredKeys.isSubset(of: keys), keys.isSubset(of: requiredKeys.union(optionalKeys)) else {
            throw CalendarStoreError.invalidEnvelope
        }
        let schemaVersionKey = try calendarStoreKey("schemaVersion")
        let snapshotKey = try calendarStoreKey("snapshot")
        let seriesMembershipKey = try calendarStoreKey("seriesMembership")
        let replicationKey = try calendarStoreKey("replication")
        let snapshotDecoder = try container.superDecoder(forKey: snapshotKey)
        try self.init(
            schemaVersion: try container.decode(Int.self, forKey: schemaVersionKey),
            snapshot: try CalendarSnapshot.decodeRawSnapshot(from: snapshotDecoder),
            seriesMembership: try container.decode([CalendarSeriesLink].self, forKey: seriesMembershipKey),
            replication: try container.decodeIfPresent(SyncAdapterEnvelope.self, forKey: replicationKey)
        )
    }

    public func validate() throws {
        guard schemaVersion == Self.currentSchemaVersion else {
            throw CalendarStoreError.unsupportedSchemaVersion(schemaVersion)
        }
        try snapshot.validatedForPersistence()
        let snapshotData = try JSONEncoder.calendar.encode(snapshot)
        guard snapshotData.count <= CalendarSnapshot.maximumEncodedBytes else {
            throw CalendarSnapshotError.payloadTooLarge
        }
        guard seriesMembership.count == snapshot.items.count,
              seriesMembership.count <= CalendarSnapshot.maximumItemCount else {
            throw CalendarStoreError.invalidEnvelope
        }

        let itemIDs = Set(snapshot.items.map { $0.id.uuidString.lowercased() })
        var linkedItemIDs = Set<String>()
        var links = Set<String>()
        for link in seriesMembership {
            try SyncContractValidation.requireUUID(link.itemID)
            try SyncContractValidation.requireUUID(link.seriesID)
            guard itemIDs.contains(link.itemID), linkedItemIDs.insert(link.itemID).inserted else {
                throw CalendarStoreError.invalidEnvelope
            }
            guard links.insert(link.itemID + "\u{0}" + link.seriesID).inserted else {
                throw CalendarStoreError.invalidEnvelope
            }
        }
        guard linkedItemIDs == itemIDs else { throw CalendarStoreError.invalidEnvelope }
        if let replication { try Self.validateReplication(replication) }
    }

    private static func validateReplication(_ value: SyncAdapterEnvelope) throws {
        guard value.schemaVersion == SyncContractConstants.schemaVersion,
              value.receiptLedgerVersion == 0 || value.receiptLedgerVersion == 1,
              value.receiptLedgerVersion != 0 || value.receipts.isEmpty,
              value.outbox.count <= maximumLedgerEntries,
              value.inbox.count <= maximumLedgerEntries,
              value.entities.count <= maximumLedgerEntries,
              value.conflicts.count <= maximumLedgerEntries,
              value.acknowledgements.count <= maximumLedgerEntries,
              value.receivedAcknowledgements.count <= maximumLedgerEntries,
              value.receipts.count <= maximumLedgerEntries else {
            throw CalendarStoreError.invalidEnvelope
        }
        try SyncContractValidation.requireUUID(value.storeID)
        try SyncContractValidation.requireUUID(value.datasetID)
        try SyncContractValidation.requireUUID(value.localOriginID)
        _ = try SyncContractValidation.requireUnsigned(value.epoch, positive: true)
        let nextSequence = try SyncContractValidation.requireUnsigned(value.nextSequence, positive: true)
        try validateFrontier(value.received, storeID: value.storeID)
        try validateFrontier(value.applied, storeID: value.storeID)

        var knownOperationsByMutation: [String: SyncOperation] = [:]
        var knownOperationsByStream: [String: SyncOperation] = [:]
        func register(_ operation: SyncOperation) throws {
            try validateOperation(operation, storeID: value.storeID, datasetID: value.datasetID, epoch: value.epoch)
            let streamKey = operation.originID + "\u{0}" + operation.sequence
            if let previous = knownOperationsByMutation[operation.mutationID], previous != operation {
                throw CalendarStoreError.invalidEnvelope
            }
            if let previous = knownOperationsByStream[streamKey], previous != operation {
                throw CalendarStoreError.invalidEnvelope
            }
            knownOperationsByMutation[operation.mutationID] = operation
            knownOperationsByStream[streamKey] = operation
        }
        for operation in value.inbox {
            try register(operation)
        }
        for entry in value.outbox {
            guard entry.schemaVersion == SyncContractConstants.schemaVersion,
                  entry.attempts >= 0,
                  entry.acknowledgements.count <= SyncContractConstants.maxMembers,
                  entry.gatewayStoredBy.count <= SyncContractConstants.maxMembers,
                  Set(entry.gatewayStoredBy).count == entry.gatewayStoredBy.count else {
                throw CalendarStoreError.invalidEnvelope
            }
            guard entry.operation.originID == value.localOriginID else {
                throw CalendarStoreError.invalidEnvelope
            }
            for endpointID in entry.gatewayStoredBy {
                try SyncContractValidation.requireUUID(endpointID)
            }
            try register(entry.operation)
            for acknowledgement in entry.acknowledgements {
                try validateAcknowledgement(acknowledgement, storeID: value.storeID, datasetID: value.datasetID, epoch: value.epoch)
                guard knownOperationsByMutation[acknowledgement.mutationID] != nil else {
                    throw CalendarStoreError.invalidEnvelope
                }
            }
        }

        var entityIDs = Set<String>()
        for entity in value.entities {
            try SyncContractValidation.requireHash(entity.entityID)
            try SyncContractValidation.requireHash(entity.versionHash)
            try SyncContractValidation.requireSortedUnique(entity.heads)
            guard entity.heads.count <= SyncContractConstants.maxCausalParents else { throw CalendarStoreError.invalidEnvelope }
            for head in entity.heads { try SyncContractValidation.requireUUID(head) }
            guard entityIDs.insert(entity.entityID).inserted else { throw CalendarStoreError.invalidEnvelope }
        }

        var conflictIDs = Set<String>()
        for conflict in value.conflicts {
            try SyncContractValidation.requireUUID(conflict.conflictID)
            try SyncContractValidation.requireUUID(conflict.storeID)
            try SyncContractValidation.requireHash(conflict.entityID)
            guard conflict.storeID == value.storeID else { throw CalendarStoreError.invalidEnvelope }
            guard !conflict.branches.isEmpty,
                  conflict.branches.count <= SyncContractConstants.maxCausalParents + 1,
                  conflictIDs.insert(conflict.conflictID).inserted else {
                throw CalendarStoreError.invalidEnvelope
            }
            for branch in conflict.branches {
                try register(branch)
            }
        }

        var acknowledgementKeys = Set<String>()
        for acknowledgement in value.acknowledgements {
            try validateAcknowledgement(acknowledgement, storeID: value.storeID, datasetID: value.datasetID, epoch: value.epoch)
            let key = acknowledgement.mutationID + "\u{0}" + acknowledgement.operationHash + "\u{0}" + acknowledgement.replicaID
            guard acknowledgementKeys.insert(key).inserted else { throw CalendarStoreError.invalidEnvelope }
            guard knownOperationsByMutation[acknowledgement.mutationID] != nil else {
                throw CalendarStoreError.invalidEnvelope
            }
        }

        var receivedAcknowledgementKeys = Set<String>()
        for acknowledgement in value.receivedAcknowledgements {
            try validateAcknowledgement(acknowledgement, storeID: value.storeID, datasetID: value.datasetID, epoch: value.epoch)
            let key = acknowledgement.mutationID + "\u{0}" + acknowledgement.operationHash + "\u{0}" + acknowledgement.replicaID
            guard acknowledgement.replicaID != value.localOriginID,
                  receivedAcknowledgementKeys.insert(key).inserted,
                  knownOperationsByMutation[acknowledgement.mutationID] != nil else {
                throw CalendarStoreError.invalidEnvelope
            }
        }

        var receiptKeys = Set<String>()
        for receipt in value.receipts {
            try SyncContractValidation.requireHash(receipt.operationHash)
            try SyncContractValidation.requireUUID(receipt.mutationID)
            try SyncContractValidation.requireHash(receipt.entityVersion)
            guard receipt.disposition == .applied
                    || receipt.disposition == .retainedConflict
                    || receipt.disposition == .alreadyApplied
                    || receipt.disposition == .ambiguous,
                  receiptKeys.insert(receipt.operationHash).inserted,
                  knownOperationsByMutation[receipt.mutationID] != nil else {
                throw CalendarStoreError.invalidEnvelope
            }
        }
        let maximumLocalSequence = knownOperationsByMutation.values
            .filter { $0.originID == value.localOriginID }
            .compactMap { UInt64($0.sequence) }
            .max() ?? 0
        guard nextSequence > maximumLocalSequence else { throw CalendarStoreError.invalidEnvelope }
    }

    private static func validateFrontier(_ frontier: SyncFrontier, storeID: String) throws {
        guard frontier.schemaVersion == SyncContractConstants.schemaVersion,
              frontier.positions.count <= SyncContractConstants.maxFrontierPositions else {
            throw CalendarStoreError.invalidEnvelope
        }
        var keys = Set<String>()
        for position in frontier.positions {
            try SyncContractValidation.requireUUID(position.stream.storeID)
            try SyncContractValidation.requireUUID(position.stream.originID)
            _ = try SyncContractValidation.requireUnsigned(position.through)
            guard position.stream.storeID == storeID,
                  keys.insert(position.stream.storeID + "\u{0}" + position.stream.originID).inserted else {
                throw CalendarStoreError.invalidEnvelope
            }
        }
    }

    private static func validateOperation(
        _ operation: SyncOperation,
        storeID: String,
        datasetID: String,
        epoch: String
    ) throws {
        guard operation.schemaVersion == SyncContractConstants.schemaVersion else {
            throw CalendarStoreError.invalidEnvelope
        }
        try SyncContractValidation.requireUUID(operation.datasetID)
        try SyncContractValidation.requireUUID(operation.storeID)
        try SyncContractValidation.requireUUID(operation.originID)
        try SyncContractValidation.requireUUID(operation.mutationID)
        _ = try SyncContractValidation.requireUnsigned(operation.epoch, positive: true)
        _ = try SyncContractValidation.requireUnsigned(operation.sequence, positive: true)
        try SyncContractValidation.requireHash(operation.keyID)
        try SyncContractValidation.requireHash(operation.entityID)
        try SyncContractValidation.requireHashOrNil(operation.baseHash)
        guard operation.parents.count <= SyncContractConstants.maxCausalParents else {
            throw CalendarStoreError.invalidEnvelope
        }
        for parent in operation.parents { try SyncContractValidation.requireUUID(parent) }
        do {
            try SyncContractValidation.requireSortedUnique(operation.parents)
        } catch {
            throw CalendarStoreError.invalidEnvelope
        }
        guard operation.payload.schemaVersion == SyncContractConstants.schemaVersion,
              operation.payload.byteCount >= 0,
              UInt64(operation.payload.byteCount) <= SyncContractConstants.maxBlobBytes else {
            throw CalendarStoreError.invalidEnvelope
        }
        try SyncContractValidation.requireHash(operation.payload.hash)
        if let inline = operation.payload.inline {
            guard operation.payload.blobHash == nil else { throw CalendarStoreError.invalidEnvelope }
            let bytes = try SyncContractValidation.requireBase64URL(
                inline,
                maximumDecodedBytes: SyncContractConstants.maxInlinePayloadBytes
            )
            guard bytes.count == operation.payload.byteCount else { throw CalendarStoreError.invalidEnvelope }
        } else if let blobHash = operation.payload.blobHash {
            try SyncContractValidation.requireHash(blobHash)
            guard blobHash == operation.payload.hash else { throw CalendarStoreError.invalidEnvelope }
        } else {
            throw CalendarStoreError.invalidEnvelope
        }
        let signature = try SyncContractValidation.requireBase64URL(
            operation.signature,
            maximumDecodedBytes: 64
        )
        guard signature.count == 64 else { throw CalendarStoreError.invalidEnvelope }
        guard operation.storeID == storeID,
              operation.datasetID == datasetID,
              operation.epoch == epoch,
              operation.domain == .calendar else {
            throw CalendarStoreError.invalidEnvelope
        }
    }

    private static func validateAcknowledgement(
        _ acknowledgement: SyncAck,
        storeID: String,
        datasetID: String,
        epoch: String
    ) throws {
        guard acknowledgement.schemaVersion == SyncContractConstants.schemaVersion else {
            throw CalendarStoreError.invalidEnvelope
        }
        try SyncContractValidation.requireUUID(acknowledgement.datasetID)
        try SyncContractValidation.requireUUID(acknowledgement.storeID)
        try SyncContractValidation.requireUUID(acknowledgement.mutationID)
        try SyncContractValidation.requireUUID(acknowledgement.replicaID)
        _ = try SyncContractValidation.requireUnsigned(acknowledgement.epoch, positive: true)
        try SyncContractValidation.requireHash(acknowledgement.operationHash)
        try SyncContractValidation.requireHash(acknowledgement.resultHash)
        try SyncContractValidation.requireHash(acknowledgement.keyID)
        let signature = try SyncContractValidation.requireBase64URL(
            acknowledgement.signature,
            maximumDecodedBytes: 64
        )
        guard signature.count == 64 else { throw CalendarStoreError.invalidEnvelope }
        guard acknowledgement.storeID == storeID,
              acknowledgement.datasetID == datasetID,
              acknowledgement.epoch == epoch else {
            throw CalendarStoreError.invalidEnvelope
        }
    }
}

private enum CalendarJSONStructureGuard {
    static func validate(_ data: Data) throws {
        var parser = Parser(bytes: Array(data))
        try parser.value(depth: 0)
        parser.whitespace()
        guard parser.index == parser.bytes.count else { throw CalendarStoreError.invalidEnvelope }
    }

    private struct Parser {
        let bytes: [UInt8]
        var index = 0

        mutating func value(depth: Int) throws {
            guard depth < 64 else { throw CalendarStoreError.invalidEnvelope }
            whitespace()
            guard index < bytes.count else { throw CalendarStoreError.invalidEnvelope }
            switch bytes[index] {
            case 123: try object(depth: depth + 1)
            case 91: try array(depth: depth + 1)
            case 34: _ = try string()
            case 116: try literal(Array("true".utf8))
            case 102: try literal(Array("false".utf8))
            case 110: try literal(Array("null".utf8))
            default: try scalar()
            }
        }

        mutating func object(depth: Int) throws {
            index += 1
            var keys = Set<String>()
            whitespace()
            if consume(125) { return }
            while true {
                whitespace()
                let key = try string()
                guard keys.insert(key).inserted else { throw CalendarStoreError.invalidEnvelope }
                whitespace()
                guard consume(58) else { throw CalendarStoreError.invalidEnvelope }
                try value(depth: depth)
                whitespace()
                if consume(125) { return }
                guard consume(44) else { throw CalendarStoreError.invalidEnvelope }
            }
        }

        mutating func array(depth: Int) throws {
            index += 1
            whitespace()
            if consume(93) { return }
            while true {
                try value(depth: depth)
                whitespace()
                if consume(93) { return }
                guard consume(44) else { throw CalendarStoreError.invalidEnvelope }
            }
        }

        mutating func string() throws -> String {
            guard consume(34) else { throw CalendarStoreError.invalidEnvelope }
            let start = index - 1
            var escaped = false
            while index < bytes.count {
                let byte = bytes[index]
                index += 1
                if byte == 34 && !escaped {
                    let raw = Data(bytes[start..<index])
                    let decoded: Any
                    do {
                        decoded = try JSONSerialization.jsonObject(with: raw, options: [.fragmentsAllowed])
                    } catch {
                        throw CalendarStoreError.invalidEnvelope
                    }
                    guard let result = decoded as? String else {
                        throw CalendarStoreError.invalidEnvelope
                    }
                    return result
                }
                if byte < 0x20 && !escaped { throw CalendarStoreError.invalidEnvelope }
                if byte == 92 && !escaped { escaped = true } else { escaped = false }
            }
            throw CalendarStoreError.invalidEnvelope
        }

        mutating func literal(_ expected: [UInt8]) throws {
            guard bytes[index..<min(index + expected.count, bytes.count)].elementsEqual(expected) else {
                throw CalendarStoreError.invalidEnvelope
            }
            index += expected.count
        }

        mutating func scalar() throws {
            let start = index
            while index < bytes.count, ![32, 9, 10, 13, 44, 93, 125].contains(bytes[index]) { index += 1 }
            guard index > start else { throw CalendarStoreError.invalidEnvelope }
        }

        mutating func whitespace() {
            while index < bytes.count, [32, 9, 10, 13].contains(bytes[index]) { index += 1 }
        }

        mutating func consume(_ value: UInt8) -> Bool {
            guard index < bytes.count, bytes[index] == value else { return false }
            index += 1
            return true
        }
    }
}

public enum CalendarStoreURL {
    /// Local app fallback; unlike an App Group this does not claim widget sharing.
    public static func localURL(baseDirectory: URL? = nil, fileName: String = "calendar.json", fileManager: FileManager = .default) -> URL {
        let base = baseDirectory ?? fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("LifeOS", isDirectory: true)
        return base.appendingPathComponent(fileName, isDirectory: false)
    }

    public static func appGroupURL(identifier: String, fileName: String = "calendar.json", fileManager: FileManager = .default) throws -> URL {
        guard let value = AppGroupConfiguration.validatedIdentifier(identifier),
              let url = fileManager.containerURL(forSecurityApplicationGroupIdentifier: value) else {
            throw CalendarStoreError.invalidAppGroupIdentifier
        }
        return url.appendingPathComponent(fileName, isDirectory: false)
    }
}

public actor CalendarStore {
    public nonisolated let url: URL
    private let fileManager: FileManager
    // This is an internal test seam used to make coordinator overlap
    // deterministic. It runs before the actor takes its synchronous
    // read/modify/write section; production stores leave it nil.
    private let beforeMutation: (@Sendable () async throws -> Void)?
    public init(
        url: URL,
        fileManager: FileManager = .default,
        beforeMutation: (@Sendable () async throws -> Void)? = nil
    ) {
        self.url = url
        self.fileManager = fileManager
        self.beforeMutation = beforeMutation
    }

    public func load() throws -> CalendarSnapshot {
        try loadEnvelope().snapshot
    }

    public func loadEnvelope() throws -> CalendarStoreEnvelope {
        guard fileManager.fileExists(atPath: url.path) else {
            let empty = try CalendarStoreEnvelope(snapshot: CalendarSnapshot(), seriesMembership: [])
            return empty
        }
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        let data = try handle.read(upToCount: CalendarStoreEnvelope.maximumEncodedBytes + 1) ?? Data()
        guard data.count <= CalendarStoreEnvelope.maximumEncodedBytes else {
            throw CalendarStoreError.payloadTooLarge
        }
        let isWrapper: Bool
        if let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            isWrapper = !Set(object.keys).isDisjoint(with: ["snapshot", "seriesMembership", "replication"])
        } else {
            isWrapper = false
        }
        if data.count > CalendarSnapshot.maximumEncodedBytes, !isWrapper {
            throw CalendarSnapshotError.payloadTooLarge
        }
        try CalendarJSONStructureGuard.validate(data)
        let envelope: CalendarStoreEnvelope
        if isWrapper {
            envelope = try JSONDecoder.calendar.decode(CalendarStoreEnvelope.self, from: data)
        } else {
            guard data.count <= CalendarSnapshot.maximumEncodedBytes else {
                throw CalendarSnapshotError.payloadTooLarge
            }
            let snapshot = try JSONDecoder.calendar.decode(CalendarSnapshot.self, from: data)
            envelope = try CalendarStoreEnvelope(
                snapshot: snapshot,
                seriesMembership: Self.defaultSeriesMembership(for: snapshot)
            )
        }
        try envelope.validate()
        return envelope
    }

    @discardableResult
    public func save(_ snapshot: CalendarSnapshot) throws -> CalendarSnapshot {
        try snapshot.validatedForPersistence()
        let existing = try loadEnvelope()
        let links = Self.membership(for: snapshot, preserving: existing.seriesMembership)
        let envelope = try CalendarStoreEnvelope(
            snapshot: snapshot,
            seriesMembership: links,
            replication: existing.replication
        )
        let data = try encodeEnvelope(envelope)
        // Decode and validate the exact bytes that are about to be committed.
        // This gives callers the canonical value represented by durable data
        // without making a fallible read after the atomic replacement.
        let canonical = try JSONDecoder.calendar.decode(CalendarStoreEnvelope.self, from: data)
        try canonical.validate()
        try persist(data)
        return canonical.snapshot
    }

    public func saveEnvelope(_ envelope: CalendarStoreEnvelope) throws {
        let data = try encodeEnvelope(envelope)
        try persist(data)
    }

    private func encodeEnvelope(_ envelope: CalendarStoreEnvelope) throws -> Data {
        try envelope.validate()
        let data = try JSONEncoder.calendar.encode(envelope)
        guard data.count <= CalendarStoreEnvelope.maximumEncodedBytes else {
            throw CalendarStoreError.payloadTooLarge
        }
        return data
    }

    private func persist(_ data: Data) throws {
        let directory = url.deletingLastPathComponent()
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        let temporary = directory.appendingPathComponent(".\(url.lastPathComponent).\(UUID().uuidString).tmp")
        do {
#if os(iOS)
            try data.write(to: temporary, options: [.atomic, .completeFileProtection])
#else
            try data.write(to: temporary, options: .atomic)
#endif
            if fileManager.fileExists(atPath: url.path) {
                _ = try fileManager.replaceItemAt(url, withItemAt: temporary)
            } else {
                try fileManager.moveItem(at: temporary, to: url)
            }
        } catch {
            try? fileManager.removeItem(at: temporary)
            throw error
        }
    }

    public func mutateEnvelope<T: Sendable>(
        _ mutation: @Sendable (CalendarStoreEnvelope) throws -> (CalendarStoreEnvelope, T)
    ) async throws -> T {
        try await beforeMutation?()
        let current = try loadEnvelope()
        let (updated, result) = try mutation(current)
        try updated.validate()
        if updated != current { try saveEnvelope(updated) }
        return result
    }

    /// Applies one read/modify/write transaction against the latest durable
    /// snapshot. The mutation itself and the subsequent save contain no
    /// suspension points, so actor reentrancy cannot allow two callers to
    /// derive candidates from the same old snapshot.
    public func mutate(
        _ mutation: @Sendable (CalendarSnapshot) throws -> CalendarSnapshot
    ) async throws -> CalendarSnapshot {
        try await beforeMutation?()
        let current = try load()
        return try save(try mutation(current))
    }

    public func merge(_ remote: CalendarSnapshot) throws -> CalendarSnapshot {
        try merge(remote, authorizedBy: nil, token: nil)
    }

    func merge(
        _ remote: CalendarSnapshot,
        authorizedBy peerFence: CalendarPeerMutationFence?,
        token: CalendarPeerMutationFence.Token?
    ) throws -> CalendarSnapshot {
        let operation = { [self] in
            try remote.validatedForPersistence()
            let current = try self.load()
            let sanitized = CalendarRemoteMergePolicy.sanitize(
                remote,
                against: current,
                now: .now
            )
            let merged = current.merged(with: sanitized.snapshot)
            guard merged != current else { return current }
            return try self.save(merged)
        }
        guard let peerFence else {
            return try operation()
        }
        guard let token else { throw CalendarPeerMutationFenceError.revoked }
        return try peerFence.withAuthorizedCommit(token, operation)
    }

    private static func defaultSeriesMembership(for snapshot: CalendarSnapshot) -> [CalendarSeriesLink] {
        snapshot.items.map { CalendarSeriesLink(itemID: $0.id, seriesID: $0.id) }
    }

    private static func membership(
        for snapshot: CalendarSnapshot,
        preserving links: [CalendarSeriesLink]
    ) -> [CalendarSeriesLink] {
        var previous: [String: String] = [:]
        for link in links {
            previous[link.itemID] = link.seriesID
        }
        return snapshot.items.map { item in
            let itemID = item.id.uuidString.lowercased()
            let seriesID = previous[itemID].flatMap(UUID.init(uuidString:)) ?? item.id
            return CalendarSeriesLink(itemID: item.id, seriesID: seriesID)
        }
    }
}

enum CalendarDateCoding {
    private static func formatter() -> ISO8601DateFormatter {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        return formatter
    }

    private static let pattern = try! NSRegularExpression(
        pattern: #"^(.+T\d{2}:\d{2}:\d{2})(?:\.(\d+))?(Z|[+-]\d{2}:\d{2})$"#
    )

    static func canonicalDate(_ date: Date) throws -> Date {
        try parse(try canonicalString(for: date))
    }

    static func encode(_ date: Date, to encoder: Encoder) throws {
        let value = try canonicalString(for: date, codingPath: encoder.codingPath)
        var container = encoder.singleValueContainer()
        try container.encode(value)
    }

    private static func canonicalString(for date: Date, codingPath: [CodingKey] = []) throws -> String {
        let seconds = date.timeIntervalSince1970
        guard seconds.isFinite else {
            throw EncodingError.invalidValue(
                date,
                .init(codingPath: codingPath, debugDescription: "Invalid calendar timestamp")
            )
        }
        var wholeSeconds = floor(seconds)
        var nanoseconds = Int(((seconds - wholeSeconds) * 1_000_000_000).rounded())
        if nanoseconds >= 1_000_000_000 {
            wholeSeconds += 1
            nanoseconds = 0
        }
        let base = formatter().string(from: Date(timeIntervalSince1970: wholeSeconds))
        var fraction = String(format: "%09d", nanoseconds)
        while fraction.last == "0" { fraction.removeLast() }
        let value = fraction.isEmpty
            ? base
            : base.replacingOccurrences(of: "Z", with: ".\(fraction)Z")
        return value
    }

    static func decode(from decoder: Decoder) throws -> Date {
        let container = try decoder.singleValueContainer()
        let raw = try container.decode(String.self)
        do {
            return try parse(raw)
        } catch {
            throw DecodingError.dataCorruptedError(
                in: container,
                debugDescription: "Invalid ISO-8601 calendar timestamp"
            )
        }
    }

    private static func parse(_ raw: String) throws -> Date {
        let range = NSRange(location: 0, length: (raw as NSString).length)
        guard let match = pattern.firstMatch(in: raw, range: range),
              let baseRange = Range(match.range(at: 1), in: raw),
              let zoneRange = Range(match.range(at: 3), in: raw),
              let baseDate = formatter().date(from: String(raw[baseRange]) + String(raw[zoneRange])) else {
            throw CalendarDateCodingError.invalidTimestamp
        }

        var fraction = 0.0
        if match.range(at: 2).location != NSNotFound,
           let fractionRange = Range(match.range(at: 2), in: raw) {
            let digits = String(raw[fractionRange].prefix(9))
            guard let parsed = Double("0.\(digits)") else {
                throw CalendarDateCodingError.invalidTimestamp
            }
            fraction = parsed
        }
        return baseDate.addingTimeInterval(fraction)
    }

    private enum CalendarDateCodingError: Error {
        case invalidTimestamp
    }
}

extension JSONEncoder {
    static var calendar: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .custom { date, nestedEncoder in
            try CalendarDateCoding.encode(date, to: nestedEncoder)
        }
        encoder.outputFormatting = [.sortedKeys]
        return encoder
    }
}

extension JSONDecoder {
    static var calendar: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .custom { nestedDecoder in
            try CalendarDateCoding.decode(from: nestedDecoder)
        }
        return decoder
    }
}
