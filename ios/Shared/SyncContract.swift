import Foundation

public enum SyncContractConstants {
    public static let schemaVersion = 1
    public static let maxPageOperations = 128
    public static let maxBodyBytes = 1_048_576
    public static let maxInlinePayloadBytes = 65_536
    public static let maxBlobBytes: UInt64 = 33_554_432
    public static let maxBlobChunkBytes = 262_144
    public static let maxFrontierPositions = 256
    public static let maxCausalParents = 8
    public static let maxMembers = 8
    public static let maxStores = 32
    public static let maxOperationBytes = 65_536
    public static let maxNonceBytes = 32
}

public enum SyncFailure: String, Error, Codable, Equatable, Sendable {
    case invalidInput
    case unsupportedSchema
    case unauthenticated
    case revoked
    case replay
    case hashMismatch
    case missingParent
    case conflict
    case staleBase
    case membershipMismatch
    case idCollision
    case capacity
    case unsupportedMedia
    case busy
    case offline
    case timedOut
    case diskFull
    case corruptStore
    case cancelled
    case identityUnavailable
    case nonceMismatch
    case responseNonceMismatch
    case responseSignatureInvalid
    case responseReplay
    case responseEpochMismatch
    case endpointNotApproved
    case redirectRejected
    case responseTooLarge
    case malformedResponse
    case operationCancelled
    case staleGeneration
    case capabilityUnavailable
    case bootstrapConflict
    case bootstrapAlreadyActivated
    case receiptAuthorityAlreadyActive
    case bootstrapConfirmationRequired
    case receiptMigrationNeedsSchemaUpgrade
    case receiptMigrationNeedsEvidence
    case receiptMigrationNeedsCursorUpgrade
    case operationReuse
    case sourceChanged
    case deletionInProgress
    case staleTarget
    case invalidVariant
    case phaseMismatch
    case invalidBounds
    case invalidNullability
    case invalidTransition
    case headMismatch
    case receiptIdentityConflict
    case permanentFailure
    case userCancelled
    case restoreInProgress
    case operationUnknown
    case restoreNotSettled
    case restoreNotTerminal
    case restoreControlMismatch
    case administrativeScopeDenied
    case wrongOffset
}

public enum SyncDomain: String, Codable, Sendable {
    case calendar
    case finance
    case fitness
    case planning
    case tax
}

public enum SyncOperationKind: String, Codable, Sendable {
    case put
    case delete
    case resolve
    case bootstrap
}

public enum SyncAckLevel: String, Codable, Sendable {
    case stored
    case applied
    case retainedConflict
}

public enum SyncReplicaRole: String, Codable, Sendable {
    case applying
    case storing
}

public enum SyncOutboxState: String, Codable, Sendable {
    case unsigned
    case ready
    case awaitingAcks
    case blocked
}

public enum SyncErrorCode: String, Codable, Sendable {
    case invalidInput
    case hashMismatch
    case unauthenticated
    case revoked
    case replay
    case missingParent
    case conflict
    case staleBase
    case membershipMismatch
    case idCollision
    case capacity
    case unsupportedMedia
    case unsupportedSchema
    case busy
    case offline
    case identityUnavailable
    case corruptStore
    case timedOut
    case diskFull
    case cancelled
}

public enum SyncDisposition: String, Codable, Sendable {
    case applied
    case retainedConflict
    case alreadyApplied
    case blockedParent
    case rejected
}

public enum SyncContractValidation {
    public static func requireSchema(_ value: Int) throws {
        guard value == SyncContractConstants.schemaVersion else { throw SyncFailure.unsupportedSchema }
    }

    public static func requireUUID(_ value: String) throws {
        guard value.count == 36,
              UUID(uuidString: value) != nil,
              value == value.lowercased(),
              value.unicodeScalars.allSatisfy({ $0.value < 128 }) else {
            throw SyncFailure.invalidInput
        }
    }

    public static func requireHash(_ value: String) throws {
        guard value.count == 64,
              value.unicodeScalars.allSatisfy({ scalar in
                  (scalar.value >= 48 && scalar.value <= 57)
                      || (scalar.value >= 97 && scalar.value <= 102)
              }) else {
            throw SyncFailure.invalidInput
        }
    }

    public static func requireUnsigned(_ value: String, positive: Bool = false) throws -> UInt64 {
        guard !value.isEmpty,
              value == "0" || !value.hasPrefix("0"),
              value.unicodeScalars.allSatisfy({ $0.value >= 48 && $0.value <= 57 }),
              let parsed = UInt64(value),
              !positive || parsed > 0 else {
            throw SyncFailure.invalidInput
        }
        return parsed
    }

    public static func requireIdentifier(_ value: String, maximumUTF8Bytes: Int = 160) throws {
        let bytes = Array(value.utf8)
        guard !bytes.isEmpty, bytes.count <= maximumUTF8Bytes,
              bytes.allSatisfy({
                  ($0 >= 97 && $0 <= 122)
                      || ($0 >= 48 && $0 <= 57)
                      || $0 == 46 || $0 == 95 || $0 == 58 || $0 == 45
              }) else {
            throw SyncFailure.invalidInput
        }
    }

    public static func requireHashOrNil(_ value: String?) throws {
        if let value { try requireHash(value) }
    }

    public static func requireUUIDOrNil(_ value: String?) throws {
        if let value { try requireUUID(value) }
    }

    public static func requireBase64URL(_ value: String, maximumDecodedBytes: Int? = nil) throws -> Data {
        guard !value.contains("="),
              value.unicodeScalars.allSatisfy({
                  ($0.value >= 65 && $0.value <= 90)
                      || ($0.value >= 97 && $0.value <= 122)
                      || ($0.value >= 48 && $0.value <= 57)
                      || $0.value == 45 || $0.value == 95
              }) else {
            throw SyncFailure.invalidInput
        }
        var padded = value
        switch padded.count % 4 {
        case 0: break
        case 2: padded += "=="
        case 3: padded += "="
        default: throw SyncFailure.invalidInput
        }
        guard let data = Data(base64Encoded: padded, options: [.ignoreUnknownCharacters]) else {
            throw SyncFailure.invalidInput
        }
        let roundTrip = data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
        guard roundTrip == value,
              maximumDecodedBytes.map({ data.count <= $0 }) ?? true else {
            throw SyncFailure.capacity
        }
        return data
    }

    public static func requireSortedUnique<T: Comparable>(_ values: [T]) throws {
        guard zip(values, values.dropFirst()).allSatisfy({ $0 < $1 }) else {
            throw SyncFailure.invalidInput
        }
    }

    public static func requireSortedUnique<T: Hashable>(_ values: [T], by key: (T) -> String) throws {
        let keys = values.map(key)
        guard Set(keys).count == keys.count,
              zip(keys, keys.dropFirst()).allSatisfy({ $0 < $1 }) else {
            throw SyncFailure.invalidInput
        }
    }
}

public struct SyncStream: Codable, Equatable, Sendable {
    public let storeID: String
    public let originID: String
    public init(storeID: String, originID: String) {
        self.storeID = storeID
        self.originID = originID
    }
}

public typealias SyncStreamID = SyncStream

public struct SyncPosition: Codable, Equatable, Sendable {
    public let stream: SyncStream
    public let through: String
    public init(stream: SyncStream, through: String) {
        self.stream = stream
        self.through = through
    }
}

public struct SyncFrontier: Codable, Equatable, Sendable {
    public let schemaVersion: Int
    public let positions: [SyncPosition]
    public init(schemaVersion: Int = SyncContractConstants.schemaVersion, positions: [SyncPosition]) {
        self.schemaVersion = schemaVersion
        self.positions = positions
    }
}

public struct SyncPayload: Codable, Equatable, Sendable {
    public let schemaVersion: Int
    public let hash: String
    public let byteCount: Int
    public let inline: String?
    public let blobHash: String?
    public init(schemaVersion: Int = 1, hash: String, byteCount: Int, inline: String?, blobHash: String?) {
        self.schemaVersion = schemaVersion
        self.hash = hash
        self.byteCount = byteCount
        self.inline = inline
        self.blobHash = blobHash
    }
}

public struct SyncOperation: Codable, Equatable, Sendable {
    public let schemaVersion: Int
    public let datasetID: String
    public let epoch: String
    public let storeID: String
    public let domain: SyncDomain
    public let originID: String
    public let keyID: String
    public let sequence: String
    public let mutationID: String
    public let entityID: String
    public let parents: [String]
    public let baseHash: String?
    public let kind: SyncOperationKind
    public let payload: SyncPayload
    public let signature: String
    public init(
        schemaVersion: Int = 1,
        datasetID: String,
        epoch: String,
        storeID: String,
        domain: SyncDomain,
        originID: String,
        keyID: String,
        sequence: String,
        mutationID: String,
        entityID: String,
        parents: [String],
        baseHash: String?,
        kind: SyncOperationKind,
        payload: SyncPayload,
        signature: String
    ) {
        self.schemaVersion = schemaVersion
        self.datasetID = datasetID
        self.epoch = epoch
        self.storeID = storeID
        self.domain = domain
        self.originID = originID
        self.keyID = keyID
        self.sequence = sequence
        self.mutationID = mutationID
        self.entityID = entityID
        self.parents = parents
        self.baseHash = baseHash
        self.kind = kind
        self.payload = payload
        self.signature = signature
    }
}

public struct SyncAck: Codable, Equatable, Sendable {
    public let schemaVersion: Int
    public let datasetID: String
    public let epoch: String
    public let storeID: String
    public let mutationID: String
    public let operationHash: String
    public let replicaID: String
    public let keyID: String
    public let level: SyncAckLevel
    public let resultHash: String
    public let signature: String
}

public struct SyncMember: Codable, Equatable, Sendable {
    public let deviceID: String
    public let keyID: String
    public let publicKey: String
    public let role: SyncReplicaRole
    public let endpoint: String?
}

public struct SyncStoreDescriptor: Codable, Equatable, Sendable {
    public let storeID: String
    public let domain: SyncDomain
    public let kind: String
    public let payloadVersion: Int
}

public struct SyncMembership: Codable, Equatable, Sendable {
    public let schemaVersion: Int
    public let datasetID: String
    public let epoch: String
    public let previousHash: String?
    public let ownerKeyID: String
    public let members: [SyncMember]
    public let stores: [SyncStoreDescriptor]
    public let signature: String
}

public struct SyncConflict: Codable, Equatable, Sendable {
    public let schemaVersion: Int
    public let conflictID: String
    public let storeID: String
    public let entityID: String
    public let branches: [SyncOperation]
    public let reason: String
    public let resolutionID: String?
}

public struct SyncSignedFrame: Codable, Equatable, Sendable {
    public let schemaVersion: Int
    public let datasetID: String
    public let epoch: String
    public let endpointID: String
    public let senderID: String
    public let keyID: String
    public let requestID: String
    public let nonce: String
    public let method: String
    public let path: String
    public let status: Int
    public let body: String
    public let bodyHash: String
    public let signature: String
}

public struct SyncChallengeRequest: Codable, Equatable, Sendable {
    public let schemaVersion: Int
    public let datasetID: String
    public let senderID: String
}

public struct SyncChallenge: Codable, Equatable, Sendable {
    public let schemaVersion: Int
    public let nonce: String
    public let expiresInSeconds: Int
}

public struct SyncHelloRequest: Codable, Equatable, Sendable {
    public let schemaVersion: Int
    public let membershipHash: String
}

public struct SyncHelloResponse: Codable, Equatable, Sendable {
    public let schemaVersion: Int
    public let membershipHash: String
    public let maximumPageOperations: Int
    public let maximumBodyBytes: Int
}

public struct SyncExchangeRequest: Codable, Equatable, Sendable {
    public let schemaVersion: Int
    public let storeID: String
    public let received: SyncFrontier
    public let upper: SyncFrontier?
    public let operations: [SyncOperation]
    public let acknowledgements: [SyncAck]
    public let limit: Int
}

public struct SyncError: Error, Codable, Equatable, Sendable {
    public let schemaVersion: Int
    public let code: SyncErrorCode
    public let mutationID: String?
    public let retryAfterSeconds: Int?
}

public struct SyncOperationResult: Codable, Equatable, Sendable {
    public let mutationID: String
    public let disposition: String
    public let error: SyncError?
}

public struct SyncExchangeResponse: Codable, Equatable, Sendable {
    public let schemaVersion: Int
    public let storeID: String
    public let results: [SyncOperationResult]
    public let operations: [SyncOperation]
    public let acknowledgements: [SyncAck]
    public let upper: SyncFrontier
    public let more: Bool
}

public struct SyncOutboxEntry: Codable, Equatable, Sendable {
    public let schemaVersion: Int
    public let operation: SyncOperation
    public let state: SyncOutboxState
    public let attempts: Int
    public let lastError: String?
    public let acknowledgements: [SyncAck]
}

public struct SyncAdapterEnvelope: Codable, Equatable, Sendable {
    public let schemaVersion: Int
    public let storeID: String
    public let datasetID: String
    public let localOriginID: String
    public let epoch: String
    public let nextSequence: String
    public let received: SyncFrontier
    public let applied: SyncFrontier
    public let outbox: [SyncOutboxEntry]
    public let inbox: [SyncOperation]
    public let entities: [SyncEntityVersion]
    public let conflicts: [SyncConflict]
    public let acknowledgements: [SyncAck]
}

public struct SyncEntityVersion: Codable, Equatable, Sendable {
    public let entityID: String
    public let heads: [String]
    public let versionHash: String
    public let deleted: Bool
}

public struct SyncCheckpoint: Codable, Equatable, Sendable {
    public let schemaVersion: Int
    public let datasetID: String
    public let epoch: String
    public let storeID: String
    public let frontier: SyncFrontier
    public let archive: SyncPayload
    public let receiptRoot: String
    public let creatorID: String
    public let keyID: String
    public let signature: String
}

public struct SyncCheckpointReceipt: Codable, Equatable, Sendable {
    public let schemaVersion: Int
    public let checkpointHash: String
    public let storeID: String
    public let covered: SyncFrontier
    public let removedOperations: Int
}

public struct SyncCommitReceipt: Codable, Equatable, Sendable {
    public let schemaVersion: Int
    public let mutationID: String
    public let operationHash: String
    public let entityVersion: String
    public let disposition: SyncDisposition
}

public struct BlobChunk: Codable, Equatable, Sendable {
    public let schemaVersion: Int
    public let storeID: String
    public let hash: String
    public let totalBytes: Int
    public let offset: Int
    public let bytes: String
}

public struct BlobRead: Codable, Equatable, Sendable {
    public let schemaVersion: Int
    public let storeID: String
    public let hash: String
    public let offset: Int
}

public struct BlobResult: Codable, Equatable, Sendable {
    public let schemaVersion: Int
    public let storeID: String
    public let hash: String
    public let receivedThrough: Int
    public let complete: Bool
}

public struct SyncPublicError: Codable, Equatable, Sendable {
    public let schemaVersion: Int
    public let code: SyncErrorCode
}

public struct SyncHealth: Codable, Equatable, Sendable {
    public let schemaVersion: Int
    public let status: String
}

public struct SyncCycleReport: Equatable, Sendable {
    public let stored: Int
    public let applied: Int
    public let conflicts: Int
    public let blocked: Int
    public let pending: Int
    public let endpointID: String
    public let completedAt: Date
}

public enum SyncReason: String, Codable, Sendable {
    case foreground
    case manual
    case background
    case localMutation
    case connectivityChanged
}

public struct SyncEndpoint: Codable, Equatable, Sendable {
    public let id: String
    public let origin: URL
    public let datasetID: String
    public let epoch: String
    public let serverKeyID: String
    public let serverPublicKey: String
    public let approvedHost: String
    public init(id: String, origin: URL, datasetID: String, epoch: String, serverKeyID: String, serverPublicKey: String, approvedHost: String) {
        self.id = id
        self.origin = origin
        self.datasetID = datasetID
        self.epoch = epoch
        self.serverKeyID = serverKeyID
        self.serverPublicKey = serverPublicKey
        self.approvedHost = approvedHost
    }
}

public struct SyncTrustRecord: Codable, Equatable, Sendable {
    public let datasetID: String
    public let epoch: String
    public let endpointID: String
    public let serverKeyID: String
    public let serverPublicKey: String
    public let members: [SyncMember]
    public let observationAccess: ObservationAccess20?
    public init(datasetID: String, epoch: String, endpointID: String, serverKeyID: String, serverPublicKey: String, members: [SyncMember], observationAccess: ObservationAccess20? = nil) {
        self.datasetID = datasetID
        self.epoch = epoch
        self.endpointID = endpointID
        self.serverKeyID = serverKeyID
        self.serverPublicKey = serverPublicKey
        self.members = members
        self.observationAccess = observationAccess
    }
}

public struct SyncAckRecord: Equatable, Sendable {
    public let acknowledgement: SyncAck
    public let durable: Bool
}

public struct SyncPage: Equatable, Sendable {
    public let operations: [SyncOperation]
    public let acknowledgements: [SyncAck]
    public let cursor: SyncFrontier
    public let hasMore: Bool
    public init(operations: [SyncOperation], acknowledgements: [SyncAck], cursor: SyncFrontier, hasMore: Bool) {
        self.operations = operations
        self.acknowledgements = acknowledgements
        self.cursor = cursor
        self.hasMore = hasMore
    }
}

public protocol SyncFrontierStore: Sendable {
    func loadFrontier() async throws -> SyncFrontier
    func persist(_ frontier: SyncFrontier) async throws
}

public protocol SyncDomainAdapter: Sendable {
    var storeID: String { get }
    var domain: SyncDomain { get }
    func recover() async throws
    func pendingPage(after: SyncFrontier?, limit: Int) async throws -> SyncPage
    func applyRemote(_ operation: SyncOperation) async throws -> SyncCommitReceipt
    func recordAcknowledgement(_ acknowledgement: SyncAck) async throws
    func checkpoint(_ frontier: SyncFrontier) async throws -> SyncCheckpointReceipt
}

// MARK: - Closed data-management registry

public enum LifeOSDataStoreID: String, Codable, CaseIterable, Sendable {
    case calendar
    case financeImports
    case financeRecurring
    case financeInvestments
    case financeBudgets
    case financeAllocations
    case financePreferences
    case financeTravel
    case training
    case trainingTemplates
    case meals
    case nutritionGoals
    case supplements
    case journal
    case lifestyle
    case barcodeRecords
    case planningJournal
    case planningFiles
    case taxSanitized
    case taxRaw
    case usageLocal
    case clipperLocal
    case replicationTrust
    case widgetSnapshot
    case nutritionPhotoOriginals
    case recoveryImports
}

public enum LifeOSDataHost: Int, Codable, Sendable {
    case apple = 1
    case windows = 2
}

public enum LifeOSDataRepresentation: String, Codable, Sendable {
    case bytes
    case keyValue
    case manifestOnly
}

public enum LifeOSDataSyncPolicy: String, Codable, Sendable {
    case never
    case metadataOnly
    case replicated
}

public enum LifeOSDataPolicy: Int, Codable, Sendable {
    case replace = 1
    case preserve = 2
    case regenerate = 3
}

public enum LifeOSDataOutcome: Int, Codable, Sendable {
    case applied = 1
    case empty = 2
    case preserved = 3
    case regenerated = 4
}

public struct LifeOSDataRestoreUnit19: Codable, Equatable, Sendable {
    public let storeID: LifeOSDataStoreID
    public let host: LifeOSDataHost
    public let targetHostID: String
    public let packHash: String
    public let sourceHash: String
    public let policy: LifeOSDataPolicy
}

public struct DataRestoreUnit19: Codable, Equatable, Sendable {
    public let storeID: LifeOSDataStoreID
    public let host: LifeOSDataHost
    public let targetHostID: String
    public let packHash: String
    public let sourceHash: String
    public let policy: LifeOSDataPolicy
}

public struct DataStateEntry19: Codable, Equatable, Sendable {
    public let relativePath: String
    public let byteCount: UInt64
    public let sha256: String
}

public struct DataStoreState19: Codable, Equatable, Sendable {
    public let contentHash: String
    public let scopeVersion: UInt64
}

public struct RestorePrepareInput19: Codable, Equatable, Sendable {
    public let receiptID: String
    public let operationID: String
    public let preparedArtifactID: String
    public let authorityID: String
    public let workPlanHash: String
    public let unit: DataRestoreUnit19
}

public struct RestorePrepared19: Codable, Equatable, Sendable {
    public let inputHash: String
    public let beforeHash: String
    public let scopeVersion: UInt64
}

public struct RestoreApplyContext19: Codable, Equatable, Sendable {
    public let input: RestorePrepareInput19
    public let prepared: RestorePrepared19
}

public struct DataCompletionProof19: Codable, Equatable, Sendable {
    public let schemaVersion: Int
    public let authorityID: String
    public let receiptID: String
    public let operationID: String
    public let preparedArtifactID: String
    public let workPlanHash: String
    public let storeID: LifeOSDataStoreID
    public let host: LifeOSDataHost
    public let targetHostID: String
    public let packHash: String
    public let sourceHash: String
    public let policy: LifeOSDataPolicy
    public let outcome: LifeOSDataOutcome
    public let beforeHash: String
    public let afterHash: String
    public let scopeVersion: UInt64
    public let adapterVersion: UInt16
    public let proofHash: String
    public let signerKeyID: String
    public let signature: String
}

public struct LifeOSReceiptWorkPlanV8: Codable, Equatable, Sendable {
    public let operationKind: Int
    public let workPlanHash: String
    public let unitHashes: [String]
    public let targetKeys: [LifeOSDeletionTargetKeyV8]
    public let restoreUnits: [DataRestoreUnit19]
    public let restoreFencePolicy: RestoreFencePolicy20?
}

public struct LifeOSDeletionTargetKeyV8: Codable, Equatable, Sendable {
    public let storeID: String
    public let entityID: String
}

public struct RestoreFencePolicy20: Codable, Equatable, Sendable {
    public let fenceID: String
    public let sourceDescriptors: [RemotePackSource20]
}

public struct DeletionPrepareInput19: Codable, Equatable, Sendable {
    public let receiptID: String
    public let operationID: String
    public let authorityID: String
    public let fenceID: String
    public let workPlanHash: String
    public let targetIndex: UInt32
    public let target: LifeOSDeletionTargetKeyV8
    public let targetKey: String
}

public struct DeletionPrepared19: Codable, Equatable, Sendable {
    public let inputHash: String
    public let beforeHash: String
    public let scopeVersion: UInt64
    public let preparationHash: String
}

public struct DeletionApplyContext19: Codable, Equatable, Sendable {
    public let input: DeletionPrepareInput19
    public let prepared: DeletionPrepared19
}

public enum DeletionInspectionState: Int, Codable, Sendable {
    case before = 1
    case applied = 2
    case changed = 3
}

public struct DeletionAppliedV8: Codable, Equatable, Sendable {
    public let targetKey: String
    public let beforeHash: String
    public let afterHash: String
    public let markerHash: String
}

public struct DeletionInspection19: Codable, Equatable, Sendable {
    public let state: DeletionInspectionState
    public let applied: DeletionAppliedV8?
}

public struct DeletionProofV8: Codable, Equatable, Sendable {
    public let targetKey: String
    public let beforeHash: String
    public let afterHash: String
    public let markerHash: String
}

public enum LifeOSReceiptOperationKind: Int, Codable, Sendable {
    case recoveryImport = 1
    case dataExport = 2
    case dataRestore = 3
    case dataDeletion = 4
}

public enum LifeOSReceiptPhaseV8: Int, Codable, Sendable {
    case staging = 10
    case manifestFinalized = 20
    case emitting = 30
    case deleting = 35
    case sinkFinalized = 40
    case bound = 50
    case committed = 60
    case failed = 90
    case cancelled = 91
}

public enum LifeOSReceiptCursorKindV8: Int, Codable, Sendable {
    case staging = 1
    case manifestFinalized = 2
    case emission = 3
    case deletion = 4
    case terminal = 5
}

public enum LifeOSReceiptOutcomeV8: Int, Codable, Sendable {
    case sinkFinalized = 40
    case bound = 50
    case committed = 60
    case failed = 90
    case cancelled = 91
}

public struct LifeOSReceiptCursorV8: Codable, Equatable, Sendable {
    public let schemaVersion: Int
    public let receiptID: String
    public let operationKind: LifeOSReceiptOperationKind
    public let kind: LifeOSReceiptCursorKindV8
    public let payload: String
}

public struct LifeOSReceiptIdentityV8: Codable, Equatable, Sendable {
    public let operationID: String
    public let preparedArtifactID: String
    public let targetID: String
    public let sourceManifestHash: String?
    public let parentReceiptID: String?
    public let parentTransitionHash: String?
}

public struct LifeOSPreEmissionFinalizationV8: Codable, Equatable, Sendable {
    public let schemaVersion: Int
    public let finalizationID: String
    public let receiptID: String
    public let operationKind: LifeOSReceiptOperationKind
    public let archiveID: String
    public let packCount: UInt16
    public let fileCount: UInt32
    public let manifestCount: UInt32
    public let planHash: String
    public let archiveHash: String
    public let manifestRootHash: String
    public let createdAt: Int64
    public let preEmissionFinalizationHash: String
}

public struct LifeOSReceiptSnapshotV8: Codable, Equatable, Sendable {
    public let phase: LifeOSReceiptPhaseV8
    public let cursor: LifeOSReceiptCursorV8
    public let preEmissionFinalization: LifeOSPreEmissionFinalizationV8?
    public let finalizationHash: String?
    public let bindingRecordHash: String?
    public let errorCode: String?
}

public struct LifeOSReceiptCommitResultV8: Codable, Equatable, Sendable {
    public let receiptID: String
    public let operationID: String
    public let action: String
    public let phase: LifeOSReceiptPhaseV8
    public let sequence: UInt64
    public let headHash: String
    public let cursor: LifeOSReceiptCursorV8
}

public struct LifeOSRemoteServerPin20: Codable, Equatable, Sendable {
    public let targetHostID: String
    public let keyID: String
    public let publicKey: String
    public let epoch: UInt64
}

public struct RemoteDeletionClosure20: Codable, Equatable, Sendable {
    public let schemaVersion: Int
    public let datasetID: String
    public let targetHostID: String
    public let receiptID: String
    public let operationID: String
    public let fenceID: String
    public let workPlanHash: String
    public let disposition: String
    public let completedTargetKeys: [String]
    public let appliedProofs: [RemoteDeletionApplied20]
    public let pending: String?
    public let collectorsDisabled: Bool
    public let memberKeyID: String
    public let epoch: UInt64
    public let recordHash: String
    public let signerKeyID: String
    public let signature: String
}

public struct RemoteDeletionApplied20: Codable, Equatable, Sendable {
    public let context: DeletionApplyContext19
    public let applied: DeletionAppliedV8
}

public struct CredentialRetirementProof20: Codable, Equatable, Sendable {
    public let schemaVersion: Int
    public let receiptID: String
    public let operationID: String
    public let fenceID: String
    public let workPlanHash: String
    public let remoteClosureRoot: String
    public let trustTargetKey: String
    public let markerHash: String
    public let proofHash: String
}

public enum CredentialRetirementState20: Int, Codable, Sendable {
    case notStarted = 0
    case intended = 1
    case retired = 2
}

public struct CredentialRetirement20: Codable, Equatable, Sendable {
    public let state: CredentialRetirementState20
    public let intentHash: String?
    public let proof: CredentialRetirementProof20?
}

public struct DeletionCompletion20: Codable, Equatable, Sendable {
    public let schemaVersion: Int
    public let authorityID: String
    public let receiptID: String
    public let operationID: String
    public let attempt: UInt16
    public let fenceID: String
    public let workPlanHash: String
    public let setupHash: String
    public let targetCount: UInt32
    public let lastTargetProofHash: String
    public let remoteClosureRoot: String
    public let credentialRetirementProofHash: String?
    public let proofRoot: String
    public let journalHash: String
    public let fenceClosed: Bool
    public let completionHash: String
    public let signerKeyID: String
    public let signature: String
}

public struct DeletionSetup20: Codable, Equatable, Sendable {
    public let schemaVersion: Int
    public let identity: String
    public let receiptID: String
    public let operationID: String
    public let attempt: UInt16
    public let authorityID: String
    public let fenceID: String
    public let workPlan: LifeOSReceiptWorkPlanV8
    public let remoteServerPins: [LifeOSRemoteServerPin20]
    public let setupHash: String
}

public struct RestoreAdmission20: Codable, Equatable, Sendable {
    public let schemaVersion: Int
    public let datasetID: String
    public let authorityID: String
    public let receiptID: String
    public let operationID: String
    public let preparedArtifactID: String
    public let fenceID: String
    public let workPlanHash: String
    public let units: [DataRestoreUnit19]
    public let sources: [RemotePackSource20]
    public let admissionHash: String
}

public enum RestoreFenceState20: Int, Codable, Sendable {
    case admitted = 1
    case holding = 2
    case settling = 3
    case settled = 4
    case releasing = 5
    case released = 6
}

public struct ProducerFlags20: Codable, Equatable, Sendable {
    public let usageEnabled: Bool
    public let clipperEnabled: Bool
}

public struct RestoreSettle20: Codable, Equatable, Sendable {
    public let receiptID: String
    public let operationID: String
    public let fenceID: String
    public let admissionHash: String
    public let disposition: String
    public let unitProofHashes: [String]
}

public struct RestoreRelease20: Codable, Equatable, Sendable {
    public let receiptID: String
    public let operationID: String
    public let fenceID: String
    public let admissionHash: String
    public let settlementHash: String
    public let terminalPhase: UInt8
    public let terminalHeadHash: String
}

public struct LocalRestoreSettlement20: Codable, Equatable, Sendable {
    public let schemaVersion: Int
    public let receiptID: String
    public let operationID: String
    public let fenceID: String
    public let admissionHash: String
    public let disposition: String
    public let proofHashes: [String]
    public let remoteSettlementHash: String
    public let pending: String?
    public let settlementHash: String
}

public struct RemoteRestoreAdmission20: Codable, Equatable, Sendable {
    public let schemaVersion: Int
    public let datasetID: String
    public let targetHostID: String
    public let receiptID: String
    public let operationID: String
    public let fenceID: String
    public let workPlanHash: String
    public let admissionHash: String
    public let memberKeyID: String
    public let epoch: UInt64
    public let priorFlags: ProducerFlags20
    public let recordHash: String
    public let signerKeyID: String
    public let signature: String
}

public struct RemoteRestoreSettlement20: Codable, Equatable, Sendable {
    public let schemaVersion: Int
    public let receiptID: String
    public let operationID: String
    public let fenceID: String
    public let admissionHash: String
    public let disposition: String
    public let unitProofHashes: [String]
    public let pending: String?
    public let collectorsDisabled: Bool
    public let recordHash: String
    public let signerKeyID: String
    public let signature: String
}

public struct RemoteRestoreRelease20: Codable, Equatable, Sendable {
    public let schemaVersion: Int
    public let receiptID: String
    public let operationID: String
    public let fenceID: String
    public let admissionHash: String
    public let settlementHash: String
    public let terminalPhase: UInt8
    public let terminalHeadHash: String
    public let enabledFlags: ProducerFlags20
    public let recordHash: String
    public let signerKeyID: String
    public let signature: String
}

public struct AdminScope20: Codable, Equatable, Sendable {
    public let namespace: String
    public let datasetID: String
    public let operationID: String
    public let fenceID: String
    public let targetHostID: String
    public let storeID: LifeOSDataStoreID
}

public struct AdminBlobRef20: Codable, Equatable, Sendable {
    public let index: UInt16
    public let blobHash: String
    public let byteCount: UInt64
}

public struct RemotePackSource20: Codable, Equatable, Sendable {
    public let schemaVersion: Int
    public let namespace: String
    public let datasetID: String
    public let operationID: String
    public let fenceID: String
    public let targetHostID: String
    public let storeID: LifeOSDataStoreID
    public let packHash: String
    public let sourceHash: String
    public let manifestFormat: String
    public let manifestHash: String
    public let manifestByteCount: UInt64
    public let bundleHash: String
    public let byteCount: UInt64
    public let segments: [AdminBlobRef20]
}

public struct AdminBlobPut20: Codable, Equatable, Sendable {
    public let schemaVersion: Int
    public let scope: AdminScope20
    public let blobHash: String
    public let totalBytes: UInt64
    public let offset: UInt64
    public let chunkHash: String
    public let bytesBase64URL: String
    public let isFinal: Bool
}

public struct AdminBlobPutResult20: Codable, Equatable, Sendable {
    public let schemaVersion: Int
    public let blobHash: String
    public let nextOffset: UInt64
    public let complete: Bool
}

public struct AdminBlobRead20: Codable, Equatable, Sendable {
    public let schemaVersion: Int
    public let scope: AdminScope20
    public let blobHash: String
    public let offset: UInt64
    public let limit: UInt32
}

public struct AdminBlobReadResult20: Codable, Equatable, Sendable {
    public let schemaVersion: Int
    public let blobHash: String
    public let totalBytes: UInt64
    public let offset: UInt64
    public let bytesBase64URL: String
    public let chunkHash: String
    public let isFinal: Bool
}

public struct ObservationAccess20: Codable, Equatable, Sendable {
    public let schemaVersion: Int
    public let datasetID: String
    public let epoch: UInt64
    public let originID: String
    public let originKeyID: String
    public let readerKeyIDs: [String]
    public let ownerKeyID: String
    public let signature: String
}

public struct SignedHealthObservation: Codable, Equatable, Sendable {
    public let schemaVersion: Int
    public let datasetID: String
    public let originID: String
    public let keyID: String
    public let sequence: String
    public let body: String
    public let bodyHash: String
    public let signature: String
    public init(schemaVersion: Int, datasetID: String, originID: String, keyID: String, sequence: String, body: String, bodyHash: String, signature: String) {
        self.schemaVersion = schemaVersion
        self.datasetID = datasetID
        self.originID = originID
        self.keyID = keyID
        self.sequence = sequence
        self.body = body
        self.bodyHash = bodyHash
        self.signature = signature
    }
}

public struct ObservationPut20: Codable, Equatable, Sendable {
    public let schemaVersion: Int
    public let datasetID: String
    public let observation: SignedHealthObservation
}

public struct ObservationRead20: Codable, Equatable, Sendable {
    public let schemaVersion: Int
    public let datasetID: String
    public let originID: String
}

public struct ObservationResult20: Codable, Equatable, Sendable {
    public let schemaVersion: Int
    public let datasetID: String
    public let originID: String
    public let observation: SignedHealthObservation?
}

public struct SyncHTTPEnvelopeV6<Payload: Codable & Sendable>: Codable, Sendable {
    public let schemaVersion: Int
    public let tag: String
    public let sessionID: UUID
    public let requestID: UUID
    public let requestNonce: String
    public let epoch: UInt64
    public let payload: Payload

    public init(schemaVersion: Int, tag: String, sessionID: UUID, requestID: UUID, requestNonce: String, epoch: UInt64, payload: Payload) {
        self.schemaVersion = schemaVersion
        self.tag = tag
        self.sessionID = sessionID
        self.requestID = requestID
        self.requestNonce = requestNonce
        self.epoch = epoch
        self.payload = payload
    }

    private enum CodingKeys: String, CodingKey { case schemaVersion, tag, sessionID, requestID, requestNonce, epoch, payload }
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        schemaVersion = try container.decode(Int.self, forKey: .schemaVersion)
        tag = try container.decode(String.self, forKey: .tag)
        sessionID = try container.decode(UUID.self, forKey: .sessionID)
        requestID = try container.decode(UUID.self, forKey: .requestID)
        requestNonce = try container.decode(String.self, forKey: .requestNonce)
        let value = try container.decode(String.self, forKey: .epoch)
        guard let epoch = UInt64(value), String(epoch) == value else { throw DecodingError.dataCorruptedError(forKey: .epoch, in: container, debugDescription: "canonical unsigned epoch required") }
        self.epoch = epoch
        payload = try container.decode(Payload.self, forKey: .payload)
    }
    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(schemaVersion, forKey: .schemaVersion)
        try container.encode(tag, forKey: .tag)
        try container.encode(sessionID, forKey: .sessionID)
        try container.encode(requestID, forKey: .requestID)
        try container.encode(requestNonce, forKey: .requestNonce)
        try container.encode(String(epoch), forKey: .epoch)
        try container.encode(payload, forKey: .payload)
    }
}

public struct SyncHTTPResponseEnvelopeV6<Payload: Codable & Sendable>: Codable, Sendable {
    public let schemaVersion: Int
    public let tag: String
    public let sessionID: UUID
    public let requestID: UUID
    public let requestNonce: String
    public let nextNonce: String
    public let epoch: UInt64
    public let payload: Payload

    public init(schemaVersion: Int, tag: String, sessionID: UUID, requestID: UUID, requestNonce: String, nextNonce: String, epoch: UInt64, payload: Payload) {
        self.schemaVersion = schemaVersion
        self.tag = tag
        self.sessionID = sessionID
        self.requestID = requestID
        self.requestNonce = requestNonce
        self.nextNonce = nextNonce
        self.epoch = epoch
        self.payload = payload
    }

    private enum CodingKeys: String, CodingKey { case schemaVersion, tag, sessionID, requestID, requestNonce, nextNonce, epoch, payload }
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        schemaVersion = try container.decode(Int.self, forKey: .schemaVersion)
        tag = try container.decode(String.self, forKey: .tag)
        sessionID = try container.decode(UUID.self, forKey: .sessionID)
        requestID = try container.decode(UUID.self, forKey: .requestID)
        requestNonce = try container.decode(String.self, forKey: .requestNonce)
        nextNonce = try container.decode(String.self, forKey: .nextNonce)
        let value = try container.decode(String.self, forKey: .epoch)
        guard let epoch = UInt64(value), String(epoch) == value else { throw DecodingError.dataCorruptedError(forKey: .epoch, in: container, debugDescription: "canonical unsigned epoch required") }
        self.epoch = epoch
        payload = try container.decode(Payload.self, forKey: .payload)
    }
    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(schemaVersion, forKey: .schemaVersion)
        try container.encode(tag, forKey: .tag)
        try container.encode(sessionID, forKey: .sessionID)
        try container.encode(requestID, forKey: .requestID)
        try container.encode(requestNonce, forKey: .requestNonce)
        try container.encode(nextNonce, forKey: .nextNonce)
        try container.encode(String(epoch), forKey: .epoch)
        try container.encode(payload, forKey: .payload)
    }
}

public struct SyncDetachedSignatureCarrierV6: Codable, Equatable, Sendable {
    public let algorithm: String
    public let keyID: String
    public let signedBytesHash: String
    public let signatureBase64URL: String
}

public struct VerifiedHTTPFrameV6: Sendable {
    public let method: String
    public let route: String
    public let sessionID: UUID
    public let requestID: UUID
    public let nonce: String
    public let epoch: UInt64
    public let body: Data
    public let memberKeyID: String
}

public struct SyncChallengeRequestV6: Codable, Equatable, Sendable {
    public let datasetID: String
    public let originID: String
}

public struct SyncChallengeResponseV6: Codable, Equatable, Sendable {
    public let sessionID: UUID
    public let nonce: String
    public let expiresAt: Int64
}

public struct SyncHelloRequestV6: Codable, Equatable, Sendable {
    public let datasetID: String
    public let originID: String
    public let storeEncoding: String
    public let aliasTableHash: String
    public let supportedSchemas: [Int]
    public let capabilities: [String]
}

public struct SyncHelloResponseV6: Codable, Equatable, Sendable {
    public let sessionID: UUID
    public let serverOriginID: String
    public let epoch: String
    public let aliasTableHash: String
    public let expiresAt: Int64
    public let capabilities: [String]
}

public struct SyncExchangeRequestV6: Codable, Equatable, Sendable {
    public let streamID: String
    public let after: SyncFrontier?
    public let limit: UInt16
    public let submit: [SyncOperation]
}

public struct SyncOperationAdmissionV6: Codable, Equatable, Sendable {
    public let operationHash: String
    public let mutationID: UUID
    public let disposition: String
    public let receiptID: UUID?
}

public struct SyncExchangeResponseV6: Codable, Equatable, Sendable {
    public let accepted: [SyncOperationAdmissionV6]
    public let operations: [SyncOperation]
    public let next: SyncFrontier?
    public let hasMore: Bool
}

public struct SyncAckRequestV6: Codable, Equatable, Sendable {
    public let ack: SyncAck
}

public struct SyncAckResponseV6: Codable, Equatable, Sendable {
    public let ack: SyncAck
    public let acceptedAt: Int64
}

public struct SyncBlobPutRequestV6: Codable, Equatable, Sendable {
    public let storeID: String
    public let blobHash: String
    public let totalBytes: UInt64
    public let offset: UInt64
    public let chunkHash: String
    public let bytesBase64URL: String
    public let isFinal: Bool
}

public struct SyncBlobPutResponseV6: Codable, Equatable, Sendable {
    public let blobHash: String
    public let nextOffset: UInt64
    public let complete: Bool
}

public struct SyncBlobReadRequestV6: Codable, Equatable, Sendable {
    public let storeID: String
    public let blobHash: String
    public let offset: UInt64
    public let limit: UInt32
}

public struct SyncBlobReadResponseV6: Codable, Equatable, Sendable {
    public let blobHash: String
    public let offset: UInt64
    public let bytesBase64URL: String
    public let chunkHash: String
    public let isFinal: Bool
}

public struct SyncHealthResponseV6: Codable, Equatable, Sendable {
    public let schemaVersion: Int
    public let status: String
}

public struct SyncHTTPHeader: Codable, Equatable, Sendable {
    public let name: String
    public let value: String
    public init(name: String, value: String) {
        self.name = name
        self.value = value
    }
}

public struct SyncHTTPRequestStateV6: Sendable {
    public let sessionID: UUID
    public let requestID: UUID
    public let requestNonce: String
    public let epoch: UInt64
    public let route: String
    public let bodyHash: String
}

public struct SyncSessionNonceStateV6: Codable, Sendable {
    public let sessionID: UUID
    public let currentNonce: String
    public let epoch: UInt64
    public let expiresAt: Int64
    public let lastRequestID: UUID?
}

public enum SyncHTTPRoute: String, Codable, Equatable, Sendable {
    case challenge = "/replication/v1/challenge"
    case hello = "/replication/v1/hello"
    case exchange = "/replication/v1/exchange"
    case ack = "/replication/v1/ack"
    case blob = "/replication/v1/blob"
    case blobRead = "/replication/v1/blob/read"
    case dataManage = "/replication/v1/data/manage"
    case observation = "/replication/v1/observation"
    case observationRead = "/replication/v1/observation/read"
    case health = "/replication/v1/health"
}

public enum SyncHTTPMethod: String, Codable, Sendable {
    case post = "POST"
    case get = "GET"
}

public struct SyncHTTPResponseV6: Codable, Sendable {
    public let status: Int
    public let headers: [SyncHTTPHeader]
    public let body: Data
    public init(status: Int, headers: [SyncHTTPHeader], body: Data) {
        self.status = status
        self.headers = headers
        self.body = body
    }
}

private extension Data {
    var syncBase64URL: String {
        base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    init(syncBase64URL value: String) throws {
        guard !value.contains("="), value.unicodeScalars.allSatisfy({
            ($0.value >= 65 && $0.value <= 90)
                || ($0.value >= 97 && $0.value <= 122)
                || ($0.value >= 48 && $0.value <= 57)
                || $0.value == 45 || $0.value == 95
        }) else { throw SyncFailure.invalidInput }
        let padded = value.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
            + String(repeating: "=", count: (4 - value.count % 4) % 4)
        guard let decoded = Data(base64Encoded: padded), decoded.syncBase64URL == value else { throw SyncFailure.invalidInput }
        self = decoded
    }
}

public enum LifeOSReceiptDomainV6: String, Codable, Equatable, Sendable {
    case recovery
    case data
    case deletion
}

public struct LifeOSLegacySourceFingerprintV9: Codable, Equatable, Sendable {
    public let sourceID: UUID
    public let domain: LifeOSReceiptDomainV6
    public let relativePath: String
    public let existed: Bool
    public let fileHash: String?
    public let byteCount: UInt64
    public let receiptHeadHash: String?
    public let observedEpoch: UInt64
}

public struct LifeOSInventoryV9: Codable, Equatable, Sendable {
    public let domain: LifeOSReceiptDomainV6
    public let relativePath: String
    public let fileHash: String?
    public let byteCount: UInt64
    public let writeSequence: UInt64
    public let migrationEpoch: UInt64
    public let receiptHeadHash: String
    public let terminalHeadHash: String
    public let terminalCount: UInt32
}

public enum LifeOSFileOperationV9: UInt8, Codable, Equatable, Sendable {
    case create = 1
    case append = 2
    case compact = 3
    case prune = 4
    case migrate = 5
}

public struct LifeOSFileIntentV9: Codable, Equatable, Sendable {
    public let intentID: UUID
    public let receiptID: UUID?
    public let domain: LifeOSReceiptDomainV6
    public let relativePath: String
    public let operation: LifeOSFileOperationV9
    public let retirementProofHash: String?
    public let retirementProofSequence: UInt64?
    public let expectedInventoryHash: String
    public let oldEntry: LifeOSInventoryV9
    public let newEntry: LifeOSInventoryV9
    public let candidateName: String
    public let intentHash: String
}

public struct LifeOSFileCommitV9: Codable, Equatable, Sendable {
    public let intent: LifeOSFileIntentV9
    public let resultInventoryHash: String
    public let observedEntry: LifeOSInventoryV9
}

public struct LifeOSLegacyIntentV9: Codable, Equatable, Sendable {
    public let schemaVersion: Int
    public let authorityID: UUID
    public let migrationEpoch: UInt64
    public let intentID: UUID
    public let sourceID: UUID
    public let relativePath: String
    public let expectedSourceHash: String?
    public let sourceFingerprintHash: String
    public let expectedInventoryHash: String
    public let createdAt: Int64
    public let intentHash: String
    public let signerKeyID: String
    public let signature: Data
}

public struct LifeOSLegacyProofV9: Codable, Equatable, Sendable {
    public let schemaVersion: Int
    public let authorityID: UUID
    public let migrationEpoch: UInt64
    public let intentID: UUID
    public let sourceID: UUID
    public let relativePath: String
    public let expectedSourceHash: String?
    public let postState: UInt8
    public let parentSyncToken: UUID
    public let proofHash: String
    public let signerKeyID: String
    public let signature: Data
}

public struct LifeOSLegacyRetirementDispositionV9: Codable, Equatable, Sendable {
    public let sourceID: UUID
    public let fingerprintHash: String
    public let disposition: String
    public let intent: LifeOSLegacyIntentV9
    public let proof: LifeOSLegacyProofV9
}

public struct LifeOSRetirementProofV9: Codable, Equatable, Sendable {
    public let schemaVersion: Int
    public let authorityID: UUID
    public let migrationEpoch: UInt64
    public let retirementDispositions: [LifeOSLegacyRetirementDispositionV9]
    public let canonicalInventory: [LifeOSInventoryV9]
    public let canonicalInventoryHash: String
    public let lastRecordHash: String
    public let proofHash: String
    public let signerKeyID: String
    public let signature: Data
}

public struct LifeOSTerminalHeadV9: Codable, Equatable, Sendable {
    public let domain: LifeOSReceiptDomainV6
    public let count: UInt32
    public let rootHash: String
}

public struct LifeOSAuthorityFenceV9: Codable, Equatable, Sendable {
    public let migrationEpoch: UInt64
    public let expectedInventoryHash: String
    public let fenceRecordHash: String
    public let open: Bool
}

public struct LifeOSAuthorityCheckpointV9: Codable, Equatable, Sendable {
    public let schemaVersion: Int
    public let authorityID: UUID
    public let migrationEpoch: UInt64
    public let authorityFileHash: String
    public let bootstrapFence: LifeOSAuthorityMutationV9
    public let baseSequence: UInt64
    public let baseHeadHash: String
    public let retirementProof: LifeOSRetirementProofV9
    public let retirementProofHash: String
    public let retirementProofSequence: UInt64
    public let currentInventory: [LifeOSInventoryV9]
    public let resultInventoryHash: String
    public let terminalHeads: [LifeOSTerminalHeadV9]
    public let activeIntents: [LifeOSFileIntentV9]
    public let fence: LifeOSAuthorityFenceV9
    public let checkpointHash: String
    public let signerKeyID: String
    public let signature: Data
}

public enum LifeOSAuthorityMutationKindV9: UInt8, Codable, Equatable, Sendable {
    case fenceOpen = 1
    case canonicalReplaceIntent = 2
    case canonicalReplaceCommit = 3
    case canonicalVerified = 4
    case legacyRetireIntent = 5
    case legacyRetireCommit = 6
    case retirementProof = 7
    case postRetirementCanonicalIntent = 8
    case postRetirementCanonicalCommit = 9
    case checkpoint = 10
    case canonicalAbort = 11
}

public struct LifeOSFenceOpenPayloadV9: Codable, Equatable, Sendable {
    public let sourceInventory: [LifeOSLegacySourceFingerprintV9]
    public let initialInventory: [LifeOSInventoryV9]
    public let bootstrapToken: UUID
}

public struct LifeOSCanonicalVerifiedPayloadV9: Codable, Equatable, Sendable {
    public let inventory: [LifeOSInventoryV9]
    public let inventoryHash: String
}

public struct LifeOSLegacyRetireCommitPayloadV9: Codable, Equatable, Sendable {
    public let intent: LifeOSLegacyIntentV9
    public let proof: LifeOSLegacyProofV9
}

public enum LifeOSAbortReasonV9: UInt8, Codable, Equatable, Sendable {
    case missingCandidate = 1
    case explicitCancel = 2
}

public struct LifeOSCanonicalAbortPayloadV9: Codable, Equatable, Sendable {
    public let intentID: UUID
    public let intentHash: String
    public let unchangedInventoryHash: String
    public let reason: LifeOSAbortReasonV9
}

public indirect enum LifeOSAuthorityMutationPayloadV9: Codable, Equatable, Sendable {
    case fenceOpen(LifeOSFenceOpenPayloadV9)
    case canonicalReplaceIntent(LifeOSFileIntentV9)
    case canonicalReplaceCommit(LifeOSFileCommitV9)
    case canonicalVerified(LifeOSCanonicalVerifiedPayloadV9)
    case legacyRetireIntent(LifeOSLegacyIntentV9)
    case legacyRetireCommit(LifeOSLegacyRetireCommitPayloadV9)
    case retirementProof(LifeOSRetirementProofV9)
    case postRetirementCanonicalIntent(LifeOSFileIntentV9)
    case postRetirementCanonicalCommit(LifeOSFileCommitV9)
    case checkpoint(LifeOSAuthorityCheckpointV9)
    case canonicalAbort(LifeOSCanonicalAbortPayloadV9)

    public func encode(to encoder: Encoder) throws {
        switch self {
        case .fenceOpen(let value): try value.encode(to: encoder)
        case .canonicalReplaceIntent(let value), .postRetirementCanonicalIntent(let value): try value.encode(to: encoder)
        case .canonicalReplaceCommit(let value), .postRetirementCanonicalCommit(let value): try value.encode(to: encoder)
        case .canonicalVerified(let value): try value.encode(to: encoder)
        case .legacyRetireIntent(let value): try value.encode(to: encoder)
        case .legacyRetireCommit(let value): try value.encode(to: encoder)
        case .retirementProof(let value): try value.encode(to: encoder)
        case .checkpoint(let value): try value.encode(to: encoder)
        case .canonicalAbort(let value): try value.encode(to: encoder)
        }
    }

    public init(from decoder: Decoder) throws {
        throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath, debugDescription: "mutation payload requires its closed kind"))
    }
}

public struct UnsignedAuthorityMutationV9: Codable, Equatable, Sendable {
    public let schemaVersion: UInt16
    public let authorityID: UUID
    public let migrationEpoch: UInt64
    public let sequence: UInt64
    public let mutationID: UUID
    public let kind: LifeOSAuthorityMutationKindV9
    public let previousRecordHash: String?
    public let payload: LifeOSAuthorityMutationPayloadV9
    public let recordHash: String
    public let signerKeyID: String

    public init(schemaVersion: UInt16, authorityID: UUID, migrationEpoch: UInt64, sequence: UInt64, mutationID: UUID, kind: LifeOSAuthorityMutationKindV9, previousRecordHash: String?, payload: LifeOSAuthorityMutationPayloadV9, recordHash: String, signerKeyID: String) {
        self.schemaVersion = schemaVersion
        self.authorityID = authorityID
        self.migrationEpoch = migrationEpoch
        self.sequence = sequence
        self.mutationID = mutationID
        self.kind = kind
        self.previousRecordHash = previousRecordHash
        self.payload = payload
        self.recordHash = recordHash
        self.signerKeyID = signerKeyID
    }

    private enum CodingKeys: String, CodingKey { case schemaVersion, authorityID, migrationEpoch, sequence, mutationID, kind, previousRecordHash, payload, recordHash, signerKeyID }
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        schemaVersion = try container.decode(UInt16.self, forKey: .schemaVersion)
        authorityID = try container.decode(UUID.self, forKey: .authorityID)
        migrationEpoch = try container.decode(UInt64.self, forKey: .migrationEpoch)
        sequence = try container.decode(UInt64.self, forKey: .sequence)
        mutationID = try container.decode(UUID.self, forKey: .mutationID)
        kind = try container.decode(LifeOSAuthorityMutationKindV9.self, forKey: .kind)
        previousRecordHash = try container.decodeIfPresent(String.self, forKey: .previousRecordHash)
        let payloadDecoder = try container.superDecoder(forKey: .payload)
        payload = try Self.decodePayload(kind: kind, from: payloadDecoder)
        recordHash = try container.decode(String.self, forKey: .recordHash)
        signerKeyID = try container.decode(String.self, forKey: .signerKeyID)
    }
    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(schemaVersion, forKey: .schemaVersion)
        try container.encode(authorityID, forKey: .authorityID)
        try container.encode(migrationEpoch, forKey: .migrationEpoch)
        try container.encode(sequence, forKey: .sequence)
        try container.encode(mutationID, forKey: .mutationID)
        try container.encode(kind, forKey: .kind)
        try container.encode(previousRecordHash, forKey: .previousRecordHash)
        try payload.encode(to: container.superEncoder(forKey: .payload))
        try container.encode(recordHash, forKey: .recordHash)
        try container.encode(signerKeyID, forKey: .signerKeyID)
    }
    fileprivate static func decodePayload(kind: LifeOSAuthorityMutationKindV9, from decoder: Decoder) throws -> LifeOSAuthorityMutationPayloadV9 {
        switch kind {
        case .fenceOpen: return .fenceOpen(try LifeOSFenceOpenPayloadV9(from: decoder))
        case .canonicalReplaceIntent: return .canonicalReplaceIntent(try LifeOSFileIntentV9(from: decoder))
        case .canonicalReplaceCommit: return .canonicalReplaceCommit(try LifeOSFileCommitV9(from: decoder))
        case .canonicalVerified: return .canonicalVerified(try LifeOSCanonicalVerifiedPayloadV9(from: decoder))
        case .legacyRetireIntent: return .legacyRetireIntent(try LifeOSLegacyIntentV9(from: decoder))
        case .legacyRetireCommit: return .legacyRetireCommit(try LifeOSLegacyRetireCommitPayloadV9(from: decoder))
        case .retirementProof: return .retirementProof(try LifeOSRetirementProofV9(from: decoder))
        case .postRetirementCanonicalIntent: return .postRetirementCanonicalIntent(try LifeOSFileIntentV9(from: decoder))
        case .postRetirementCanonicalCommit: return .postRetirementCanonicalCommit(try LifeOSFileCommitV9(from: decoder))
        case .checkpoint: return .checkpoint(try LifeOSAuthorityCheckpointV9(from: decoder))
        case .canonicalAbort: return .canonicalAbort(try LifeOSCanonicalAbortPayloadV9(from: decoder))
        }
    }
}

public struct LifeOSAuthorityMutationV9: Codable, Equatable, Sendable {
    public let schemaVersion: UInt16
    public let authorityID: UUID
    public let migrationEpoch: UInt64
    public let sequence: UInt64
    public let mutationID: UUID
    public let kind: LifeOSAuthorityMutationKindV9
    public let previousRecordHash: String?
    public let payload: LifeOSAuthorityMutationPayloadV9
    public let recordHash: String
    public let signerKeyID: String
    public let signature: Data

    public init(schemaVersion: UInt16, authorityID: UUID, migrationEpoch: UInt64, sequence: UInt64, mutationID: UUID, kind: LifeOSAuthorityMutationKindV9, previousRecordHash: String?, payload: LifeOSAuthorityMutationPayloadV9, recordHash: String, signerKeyID: String, signature: Data) {
        self.schemaVersion = schemaVersion
        self.authorityID = authorityID
        self.migrationEpoch = migrationEpoch
        self.sequence = sequence
        self.mutationID = mutationID
        self.kind = kind
        self.previousRecordHash = previousRecordHash
        self.payload = payload
        self.recordHash = recordHash
        self.signerKeyID = signerKeyID
        self.signature = signature
    }

    private enum CodingKeys: String, CodingKey { case schemaVersion, authorityID, migrationEpoch, sequence, mutationID, kind, previousRecordHash, payload, recordHash, signerKeyID, signature }
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        schemaVersion = try container.decode(UInt16.self, forKey: .schemaVersion)
        authorityID = try container.decode(UUID.self, forKey: .authorityID)
        migrationEpoch = try container.decode(UInt64.self, forKey: .migrationEpoch)
        sequence = try container.decode(UInt64.self, forKey: .sequence)
        mutationID = try container.decode(UUID.self, forKey: .mutationID)
        kind = try container.decode(LifeOSAuthorityMutationKindV9.self, forKey: .kind)
        previousRecordHash = try container.decodeIfPresent(String.self, forKey: .previousRecordHash)
        payload = try UnsignedAuthorityMutationV9.decodePayload(kind: kind, from: container.superDecoder(forKey: .payload))
        recordHash = try container.decode(String.self, forKey: .recordHash)
        signerKeyID = try container.decode(String.self, forKey: .signerKeyID)
        signature = try Data(syncBase64URL: container.decode(String.self, forKey: .signature))
    }
    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(schemaVersion, forKey: .schemaVersion)
        try container.encode(authorityID, forKey: .authorityID)
        try container.encode(migrationEpoch, forKey: .migrationEpoch)
        try container.encode(sequence, forKey: .sequence)
        try container.encode(mutationID, forKey: .mutationID)
        try container.encode(kind, forKey: .kind)
        try container.encode(previousRecordHash, forKey: .previousRecordHash)
        try payload.encode(to: container.superEncoder(forKey: .payload))
        try container.encode(recordHash, forKey: .recordHash)
        try container.encode(signerKeyID, forKey: .signerKeyID)
        try container.encode(signature.syncBase64URL, forKey: .signature)
    }
}

public struct ReceiptPublicIdentity19: Codable, Equatable, Sendable {
    public let authorityID: String
    public let signerKeyID: String
    public let publicKey: String
}

public struct SignedBootstrapFence20: Sendable {
    public let record: LifeOSAuthorityMutationV9
    internal init(record: LifeOSAuthorityMutationV9) {
        self.record = record
    }
}

public struct ReceiptSignature19: Codable, Equatable, Sendable {
    public let signerKeyID: String
    public let signature: String
}

public struct BootstrapReservation20: Codable, Equatable, Sendable {
    public let schemaVersion: Int
    public let installationID: String
    public let authorityID: String
    public let migrationEpoch: UInt64
    public let bootstrapToken: String
    public let ownerKeyID: String
    public let deviceKeyID: String
    public let fenceHash: String
    public let fence: LifeOSAuthorityMutationV9
    public let status: UInt8
}

public struct VerifiedBootstrapPublication20: Sendable {
    public let authorityID: String
    public let authorityFileHash: String
    public let bootstrapToken: String
    public let fenceHash: String
    public let logHeadHash: String
    public let logHeadSequence: UInt64
    public init(authorityID: String, authorityFileHash: String, bootstrapToken: String, fenceHash: String, logHeadHash: String, logHeadSequence: UInt64) {
        self.authorityID = authorityID
        self.authorityFileHash = authorityFileHash
        self.bootstrapToken = bootstrapToken
        self.fenceHash = fenceHash
        self.logHeadHash = logHeadHash
        self.logHeadSequence = logHeadSequence
    }
}

public struct VerifiedBootstrapAbsence20: Sendable {
    public let installationID: String
    public let authorityID: String
    public let bootstrapToken: String
    public let parentHash: String
    public init(installationID: String, authorityID: String, bootstrapToken: String, parentHash: String) {
        self.installationID = installationID
        self.authorityID = authorityID
        self.bootstrapToken = bootstrapToken
        self.parentHash = parentHash
    }
}

public struct ReceiptBootstrapAuthorization19: Sendable {
    let installationID: String
    let authorityID: String
    let migrationEpoch: UInt64
    let bootstrapToken: String
    let deviceKeyID: String
    let ownerKeyID: String
    let expectedExistingAuthorityHash: String?
    let authorizationID: String
    internal init(installationID: String, authorityID: String, migrationEpoch: UInt64, bootstrapToken: String, deviceKeyID: String, ownerKeyID: String, expectedExistingAuthorityHash: String?, authorizationID: String) {
        self.installationID = installationID
        self.authorityID = authorityID
        self.migrationEpoch = migrationEpoch
        self.bootstrapToken = bootstrapToken
        self.deviceKeyID = deviceKeyID
        self.ownerKeyID = ownerKeyID
        self.expectedExistingAuthorityHash = expectedExistingAuthorityHash
        self.authorizationID = authorizationID
    }
}

public struct ReceiptMutationAuthorization19: Sendable {
    let authorityID: String
    let epoch: UInt64
    let sequence: UInt64
    let expectedPreviousHash: String?
    let authorizationID: String
    internal init(authorityID: String, epoch: UInt64, sequence: UInt64, expectedPreviousHash: String?, authorizationID: String) {
        self.authorityID = authorityID
        self.epoch = epoch
        self.sequence = sequence
        self.expectedPreviousHash = expectedPreviousHash
        self.authorizationID = authorizationID
    }
}

public struct VerifiedDeletionSigning20: Sendable {
    let authorityID: String
    let receiptID: String
    let operationID: String
    let completionHash: String
    internal init(authorityID: String, receiptID: String, operationID: String, completionHash: String) {
        self.authorityID = authorityID
        self.receiptID = receiptID
        self.operationID = operationID
        self.completionHash = completionHash
    }
}
