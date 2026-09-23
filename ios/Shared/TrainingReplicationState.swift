import Foundation

/// The fixed identity tuple for one training replica. These values are
/// persisted before any operation is signed or assigned a sequence.
public struct TrainingSyncBinding: Codable, Equatable, Sendable {
    public let datasetID: String
    public let epoch: String
    public let storeID: String
    public let localOriginID: String
    public let keyID: String

    public init(datasetID: String, epoch: String, storeID: String, localOriginID: String, keyID: String) {
        self.datasetID = datasetID
        self.epoch = epoch
        self.storeID = storeID
        self.localOriginID = localOriginID
        self.keyID = keyID
    }

    func validate() throws {
        guard Self.isCanonicalUUID(datasetID),
              Self.isCanonicalUUID(storeID),
              Self.isCanonicalUUID(localOriginID),
              let parsedEpoch = UInt64(epoch), parsedEpoch > 0, String(parsedEpoch) == epoch,
              Self.isSHA256(keyID) else {
            throw TrainingStoreError.invalidReplicationBinding
        }
    }

    private static func isCanonicalUUID(_ value: String) -> Bool {
        guard let uuid = UUID(uuidString: value) else { return false }
        return value == uuid.uuidString.lowercased()
    }

    fileprivate static func isSHA256(_ value: String) -> Bool {
        value.utf8.count == 64
            && value.utf8.allSatisfy { (48...57).contains($0) || (97...102).contains($0) }
    }

    private enum CodingKeys: String, CodingKey { case datasetID, epoch, storeID, localOriginID, keyID }

    public init(from decoder: Decoder) throws {
        try rejectUnknownTrainingReplicationKeys(
            decoder,
            allowed: ["datasetID", "epoch", "storeID", "localOriginID", "keyID"]
        )
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            datasetID: try c.decode(String.self, forKey: .datasetID),
            epoch: try c.decode(String.self, forKey: .epoch),
            storeID: try c.decode(String.self, forKey: .storeID),
            localOriginID: try c.decode(String.self, forKey: .localOriginID),
            keyID: try c.decode(String.self, forKey: .keyID)
        )
    }
}

public struct TrainingBootstrapEntry: Codable, Equatable, Sendable {
    public let recordID: TrainingRecordID
    public let mutationID: TrainingRecordID
    public let entityID: String
    public let payloadHash: String

    public init(recordID: TrainingRecordID, mutationID: TrainingRecordID, entityID: String, payloadHash: String) {
        self.recordID = recordID
        self.mutationID = mutationID
        self.entityID = entityID
        self.payloadHash = payloadHash
    }

    private enum CodingKeys: String, CodingKey { case recordID, mutationID, entityID, payloadHash }

    public init(from decoder: Decoder) throws {
        try rejectUnknownTrainingReplicationKeys(decoder, allowed: ["recordID", "mutationID", "entityID", "payloadHash"])
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            recordID: try c.decode(TrainingRecordID.self, forKey: .recordID),
            mutationID: try c.decode(TrainingRecordID.self, forKey: .mutationID),
            entityID: try c.decode(String.self, forKey: .entityID),
            payloadHash: try c.decode(String.self, forKey: .payloadHash)
        )
    }
}

public struct TrainingEntityKey: Codable, Equatable, Sendable {
    public let recordID: TrainingRecordID
    public let entityID: String

    public init(recordID: TrainingRecordID, entityID: String) {
        self.recordID = recordID
        self.entityID = entityID
    }

    private enum CodingKeys: String, CodingKey { case recordID, entityID }

    public init(from decoder: Decoder) throws {
        try rejectUnknownTrainingReplicationKeys(decoder, allowed: ["recordID", "entityID"])
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            recordID: try c.decode(TrainingRecordID.self, forKey: .recordID),
            entityID: try c.decode(String.self, forKey: .entityID)
        )
    }
}

public struct TrainingSyncIntent: Codable, Equatable, Sendable {
    public let mutationID: TrainingRecordID
    public let recordID: TrainingRecordID
    public let kind: SyncOperationKind
    public let payload: SyncPayload

    public init(mutationID: TrainingRecordID, recordID: TrainingRecordID, kind: SyncOperationKind, payload: SyncPayload) {
        self.mutationID = mutationID
        self.recordID = recordID
        self.kind = kind
        self.payload = payload
    }

    private enum CodingKeys: String, CodingKey { case mutationID, recordID, kind, payload }

    public init(from decoder: Decoder) throws {
        try rejectUnknownTrainingReplicationKeys(decoder, allowed: ["mutationID", "recordID", "kind", "payload"])
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            mutationID: try c.decode(TrainingRecordID.self, forKey: .mutationID),
            recordID: try c.decode(TrainingRecordID.self, forKey: .recordID),
            kind: try c.decode(SyncOperationKind.self, forKey: .kind),
            payload: try c.decode(SyncPayload.self, forKey: .payload)
        )
    }
}

/// Durable local replication material. Signing and sequence allocation are
/// intentionally handled by a later adapter batch.
public struct TrainingReplicationState: Codable, Equatable, Sendable {
    public let binding: TrainingSyncBinding
    public let bootstrapMap: [TrainingBootstrapEntry]
    public let pendingIntents: [TrainingSyncIntent]
    public let entityKeys: [TrainingEntityKey]
    public let ledger: SyncAdapterEnvelope

    public init(
        binding: TrainingSyncBinding,
        bootstrapMap: [TrainingBootstrapEntry],
        pendingIntents: [TrainingSyncIntent],
        entityKeys: [TrainingEntityKey],
        ledger: SyncAdapterEnvelope
    ) {
        self.binding = binding
        self.bootstrapMap = bootstrapMap
        self.pendingIntents = pendingIntents
        self.entityKeys = entityKeys
        self.ledger = ledger
    }

    public static func entityID(for recordID: TrainingRecordID) throws -> String {
        try SyncWireCodec.hash(
            domain: "LifeOS/training-entity/v1",
            canonical: SyncWireCodec.canonicalJSON(recordID.rawValue)
        )
    }

    static func inlinePayload(_ data: Data) -> SyncPayload {
        SyncPayload(
            hash: SyncWireCodec.sha256(data),
            byteCount: data.count,
            inline: trainingSyncBase64URL(data),
            blobHash: nil
        )
    }

    static func emptyLedger(for binding: TrainingSyncBinding) -> SyncAdapterEnvelope {
        let emptyFrontier = SyncFrontier(positions: [])
        return SyncAdapterEnvelope(
            schemaVersion: SyncContractConstants.schemaVersion,
            storeID: binding.storeID,
            datasetID: binding.datasetID,
            localOriginID: binding.localOriginID,
            epoch: binding.epoch,
            nextSequence: "1",
            received: emptyFrontier,
            applied: emptyFrontier,
            outbox: [],
            inbox: [],
            entities: [],
            conflicts: [],
            acknowledgements: [],
            receivedAcknowledgements: [],
            receipts: [],
            receiptLedgerVersion: 1
        )
    }

    func validate(
        retainedSessions: [TrainingRecordID: TrainingSession],
        receiptsByMutationID: [TrainingRecordID: TrainingReceiptJournalEntry],
        retiredMutationIDs: Set<TrainingRecordID>,
        now: Date
    ) throws {
        // Batch B keeps the adapter ledger empty while the ordered local
        // command journal carries each record through its current post-image.
        do { try binding.validate() } catch { throw TrainingStoreError.corruptLedger }
        guard bootstrapMap.count <= TrainingStoreLimits.maximumReplicationBootstrapEntries,
              pendingIntents.count <= TrainingStoreLimits.maximumReplicationPendingIntents,
              entityKeys.count <= TrainingStoreLimits.maximumReplicationEntityKeys else {
            throw TrainingStoreError.ledgerTooLarge
        }
        guard ledger == Self.emptyLedger(for: binding) else {
            throw TrainingStoreError.corruptLedger
        }

        let retainedSessionIDs = Set(retainedSessions.keys)
        var entityIDByRecordID: [TrainingRecordID: String] = [:]
        for key in entityKeys {
            let canonicalEntityID: String
            do {
                canonicalEntityID = try Self.entityID(for: key.recordID)
            } catch {
                throw TrainingStoreError.corruptLedger
            }
            guard key.entityID == canonicalEntityID,
                  entityIDByRecordID.updateValue(key.entityID, forKey: key.recordID) == nil,
                  TrainingSyncBinding.isSHA256(key.entityID) else {
                throw TrainingStoreError.corruptLedger
            }
        }
        let mappedRecordIDs = Set(entityIDByRecordID.keys)
        guard retainedSessionIDs.isSubset(of: mappedRecordIDs) else {
            throw TrainingStoreError.corruptLedger
        }

        var bootstrapByMutationID: [TrainingRecordID: TrainingBootstrapEntry] = [:]
        var bootstrapByRecordID: [TrainingRecordID: TrainingBootstrapEntry] = [:]
        var bootstrapRecordIDs = Set<TrainingRecordID>()
        for entry in bootstrapMap {
            let canonicalEntityID: String
            do {
                canonicalEntityID = try Self.entityID(for: entry.recordID)
            } catch {
                throw TrainingStoreError.corruptLedger
            }
            guard entry.entityID == canonicalEntityID,
                  TrainingSyncBinding.isSHA256(entry.entityID),
                  TrainingSyncBinding.isSHA256(entry.payloadHash),
                  entityIDByRecordID[entry.recordID] == entry.entityID,
                  bootstrapRecordIDs.insert(entry.recordID).inserted,
                  bootstrapByMutationID.updateValue(entry, forKey: entry.mutationID) == nil,
                  bootstrapByRecordID.updateValue(entry, forKey: entry.recordID) == nil,
                  receiptsByMutationID[entry.mutationID] == nil,
                  !retiredMutationIDs.contains(entry.mutationID) else {
                throw TrainingStoreError.corruptLedger
            }
        }
        guard bootstrapRecordIDs == mappedRecordIDs else {
            throw TrainingStoreError.corruptLedger
        }

        var intentMutationIDs = Set<TrainingRecordID>()
        var bootstrappedRecordIDs = Set<TrainingRecordID>()
        var deletedRecordIDs = Set<TrainingRecordID>()
        var lastSessionByRecordID: [TrainingRecordID: TrainingSession] = [:]
        var lastPayloadBytesByRecordID: [TrainingRecordID: Data] = [:]
        for intent in pendingIntents {
            guard intentMutationIDs.insert(intent.mutationID).inserted,
                  let entityID = entityIDByRecordID[intent.recordID],
                  let entry = bootstrapByRecordID[intent.recordID],
                  entry.entityID == entityID else {
                throw TrainingStoreError.corruptLedger
            }

            switch intent.kind {
            case .bootstrap:
                guard bootstrappedRecordIDs.insert(intent.recordID).inserted,
                      intent.mutationID == entry.mutationID else {
                    throw TrainingStoreError.corruptLedger
                }
                let decoded = try Self.decodeTrainingSession(from: intent.payload, now: now)
                guard decoded.session.id == intent.recordID,
                      entry.payloadHash == intent.payload.hash else {
                    throw TrainingStoreError.corruptLedger
                }
                lastSessionByRecordID[intent.recordID] = decoded.session
                lastPayloadBytesByRecordID[intent.recordID] = decoded.bytes

            case .put:
                guard bootstrappedRecordIDs.contains(intent.recordID),
                      !deletedRecordIDs.contains(intent.recordID),
                      intent.mutationID != entry.mutationID,
                      let previous = lastSessionByRecordID[intent.recordID] else {
                    throw TrainingStoreError.corruptLedger
                }
                let decoded = try Self.decodeTrainingSession(from: intent.payload, now: now)
                guard decoded.session.id == intent.recordID,
                      previous.revision < Int.max - 1,
                      decoded.session.revision == previous.revision + 1 else {
                    throw TrainingStoreError.corruptLedger
                }
                try Self.validateOrdinaryIntentReceipt(
                    mutationID: intent.mutationID,
                    recordID: intent.recordID,
                    revision: decoded.session.revision,
                    receiptsByMutationID: receiptsByMutationID,
                    retiredMutationIDs: retiredMutationIDs
                )
                lastSessionByRecordID[intent.recordID] = decoded.session
                lastPayloadBytesByRecordID[intent.recordID] = decoded.bytes

            case .delete:
                guard bootstrappedRecordIDs.contains(intent.recordID),
                      !deletedRecordIDs.contains(intent.recordID),
                      intent.mutationID != entry.mutationID,
                      let previous = lastSessionByRecordID[intent.recordID],
                      intent.payload == Self.inlinePayload(Data()) else {
                    throw TrainingStoreError.corruptLedger
                }
                try Self.validateOrdinaryIntentReceipt(
                    mutationID: intent.mutationID,
                    recordID: intent.recordID,
                    revision: previous.revision,
                    receiptsByMutationID: receiptsByMutationID,
                    retiredMutationIDs: retiredMutationIDs
                )
                deletedRecordIDs.insert(intent.recordID)

            case .resolve:
                throw TrainingStoreError.corruptLedger
            }
        }

        guard bootstrappedRecordIDs == mappedRecordIDs else {
            throw TrainingStoreError.corruptLedger
        }
        let terminalLiveRecordIDs = Set(lastSessionByRecordID.keys).subtracting(deletedRecordIDs)
        guard terminalLiveRecordIDs == retainedSessionIDs else {
            throw TrainingStoreError.corruptLedger
        }
        for (recordID, session) in retainedSessions {
            guard let terminalBytes = lastPayloadBytesByRecordID[recordID] else {
                throw TrainingStoreError.corruptLedger
            }
            let canonicalCurrentBytes: Data
            do {
                canonicalCurrentBytes = try FitnessPayloadCodec.encode(session, now: now)
            } catch {
                throw TrainingStoreError.corruptLedger
            }
            guard terminalBytes == canonicalCurrentBytes else {
                throw TrainingStoreError.corruptLedger
            }
        }
    }

    private static func decodeTrainingSession(
        from payload: SyncPayload,
        now: Date
    ) throws -> (session: TrainingSession, bytes: Data) {
        do {
            try SyncWireCodec.validate(payload)
            guard payload.blobHash == nil,
                  let inline = payload.inline else {
                throw TrainingStoreError.corruptLedger
            }
            let bytes = try trainingSyncData(fromBase64URL: inline)
            guard trainingSyncBase64URL(bytes) == inline else {
                throw TrainingStoreError.corruptLedger
            }
            let decoded = try FitnessPayloadCodec.decode(bytes, now: now)
            guard let session = decoded.trainingSession else {
                throw TrainingStoreError.corruptLedger
            }
            return (session, bytes)
        } catch {
            throw TrainingStoreError.corruptLedger
        }
    }

    private static func validateOrdinaryIntentReceipt(
        mutationID: TrainingRecordID,
        recordID: TrainingRecordID,
        revision: Int,
        receiptsByMutationID: [TrainingRecordID: TrainingReceiptJournalEntry],
        retiredMutationIDs: Set<TrainingRecordID>
    ) throws {
        if let entry = receiptsByMutationID[mutationID] {
            guard !retiredMutationIDs.contains(mutationID),
                  entry.mutationID == mutationID,
                  entry.receipt.mutationID == mutationID,
                  entry.receipt.outcome == .saved,
                  entry.receipt.recordID == recordID,
                  entry.receipt.revision == revision else {
                throw TrainingStoreError.corruptLedger
            }
        } else if !retiredMutationIDs.contains(mutationID) {
            throw TrainingStoreError.corruptLedger
        }
    }

    private enum CodingKeys: String, CodingKey { case binding, bootstrapMap, pendingIntents, entityKeys, ledger }

    public init(from decoder: Decoder) throws {
        try rejectUnknownTrainingReplicationKeys(
            decoder,
            allowed: ["binding", "bootstrapMap", "pendingIntents", "entityKeys", "ledger"]
        )
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            binding: try c.decode(TrainingSyncBinding.self, forKey: .binding),
            bootstrapMap: try decodeBoundedTrainingStoreArray(
                TrainingBootstrapEntry.self,
                forKey: .bootstrapMap,
                from: c,
                maximum: TrainingStoreLimits.maximumReplicationBootstrapEntries,
                overflow: .ledgerTooLarge
            ),
            pendingIntents: try decodeBoundedTrainingStoreArray(
                TrainingSyncIntent.self,
                forKey: .pendingIntents,
                from: c,
                maximum: TrainingStoreLimits.maximumReplicationPendingIntents,
                overflow: .ledgerTooLarge
            ),
            entityKeys: try decodeBoundedTrainingStoreArray(
                TrainingEntityKey.self,
                forKey: .entityKeys,
                from: c,
                maximum: TrainingStoreLimits.maximumReplicationEntityKeys,
                overflow: .ledgerTooLarge
            ),
            ledger: try c.decode(TrainingEmptySyncAdapterEnvelope.self, forKey: .ledger).value
        )
    }
}

/// Batch B permits only the exact empty adapter envelope. Decode each array as
/// an unkeyed container and reject it while positioned before its first item,
/// so nested operation and frontier objects are never materialized.
private struct TrainingEmptySyncAdapterEnvelope: Decodable {
    let value: SyncAdapterEnvelope

    private enum CodingKeys: String, CodingKey {
        case schemaVersion, storeID, datasetID, localOriginID, epoch, nextSequence
        case received, applied, outbox, inbox, entities, conflicts
        case acknowledgements, receivedAcknowledgements, receipts, receiptLedgerVersion
    }

    init(from decoder: Decoder) throws {
        try rejectUnknownTrainingReplicationKeys(decoder, allowed: [
            "schemaVersion", "storeID", "datasetID", "localOriginID", "epoch", "nextSequence",
            "received", "applied", "outbox", "inbox", "entities", "conflicts",
            "acknowledgements", "receivedAcknowledgements", "receipts", "receiptLedgerVersion"
        ])
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let schemaVersion = try c.decode(Int.self, forKey: .schemaVersion)
        let storeID = try c.decode(String.self, forKey: .storeID)
        let datasetID = try c.decode(String.self, forKey: .datasetID)
        let localOriginID = try c.decode(String.self, forKey: .localOriginID)
        let epoch = try c.decode(String.self, forKey: .epoch)
        let nextSequence = try c.decode(String.self, forKey: .nextSequence)
        let received = try c.decode(TrainingEmptySyncFrontier.self, forKey: .received).value
        let applied = try c.decode(TrainingEmptySyncFrontier.self, forKey: .applied).value

        try rejectTrainingNonemptyArray(c, forKey: .outbox)
        try rejectTrainingNonemptyArray(c, forKey: .inbox)
        try rejectTrainingNonemptyArray(c, forKey: .entities)
        try rejectTrainingNonemptyArray(c, forKey: .conflicts)
        try rejectTrainingNonemptyArray(c, forKey: .acknowledgements)
        if c.contains(.receivedAcknowledgements) {
            try rejectTrainingNonemptyArray(c, forKey: .receivedAcknowledgements)
        }
        if c.contains(.receipts) {
            try rejectTrainingNonemptyArray(c, forKey: .receipts)
        }

        value = SyncAdapterEnvelope(
            schemaVersion: schemaVersion,
            storeID: storeID,
            datasetID: datasetID,
            localOriginID: localOriginID,
            epoch: epoch,
            nextSequence: nextSequence,
            received: received,
            applied: applied,
            outbox: [],
            inbox: [],
            entities: [],
            conflicts: [],
            acknowledgements: [],
            receivedAcknowledgements: [],
            receipts: [],
            receiptLedgerVersion: try c.decodeIfPresent(Int.self, forKey: .receiptLedgerVersion) ?? 0
        )
    }
}

private struct TrainingEmptySyncFrontier: Decodable {
    let value: SyncFrontier

    private enum CodingKeys: String, CodingKey { case schemaVersion, positions }

    init(from decoder: Decoder) throws {
        try rejectUnknownTrainingReplicationKeys(decoder, allowed: ["schemaVersion", "positions"])
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let schemaVersion = try c.decode(Int.self, forKey: .schemaVersion)
        try rejectTrainingNonemptyArray(c, forKey: .positions)
        value = SyncFrontier(schemaVersion: schemaVersion, positions: [])
    }
}

private func rejectTrainingNonemptyArray<Key: CodingKey>(
    _ container: KeyedDecodingContainer<Key>,
    forKey key: Key
) throws {
    let values = try container.nestedUnkeyedContainer(forKey: key)
    guard values.isAtEnd else {
        throw DecodingError.dataCorrupted(.init(
            codingPath: values.codingPath,
            debugDescription: "Batch A training replication state requires empty arrays"
        ))
    }
}

private func rejectUnknownTrainingReplicationKeys(_ decoder: Decoder, allowed: Set<String>) throws {
    let container = try decoder.container(keyedBy: TrainingReplicationAnyCodingKey.self)
    guard Set(container.allKeys.map(\.stringValue)).isSubset(of: allowed) else {
        throw DecodingError.dataCorrupted(.init(
            codingPath: decoder.codingPath,
            debugDescription: "Unknown training replication field"
        ))
    }
}

private struct TrainingReplicationAnyCodingKey: CodingKey {
    let stringValue: String
    let intValue: Int? = nil
    init?(stringValue: String) { self.stringValue = stringValue }
    init?(intValue: Int) { return nil }
}

private func trainingSyncBase64URL(_ data: Data) -> String {
    data.base64EncodedString()
        .replacingOccurrences(of: "+", with: "-")
        .replacingOccurrences(of: "/", with: "_")
        .replacingOccurrences(of: "=", with: "")
}

private func trainingSyncData(fromBase64URL value: String) throws -> Data {
    try SyncContractValidation.requireBase64URL(value)
}
