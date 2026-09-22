import Foundation
import os

private let planningDiagnosticReasonAllowlist: Set<String> = [
    "authority.directory", "authority.identity", "authority.url",
    "backpressure", "cache", "cache.absent", "cache.blob", "cache.observation",
    "cacheBytes", "cacheIndex", "cacheRecords", "cacheVisited", "canvasPath",
    "coordination", "coordination.target", "coordination.url", "coordinationTimeout",
    "directory", "directoryName", "directoryPath", "document", "grant", "grantBookmark",
    "initializationIntent.temporaryName", "invalid", "lifeOS.nonEmpty", "manifest",
    "manifest.backupDigest", "manifestCount", "manifest.identity", "manifest.identityType",
    "marker", "path", "pathComponent", "pickerAdapterUnavailable", "pickerBusy",
    "pickerPresenter", "pickerPresenterBusy", "preservation", "preservationArtifacts",
    "preservationBytes", "preservationDepth", "preservationEntries", "preservationFile",
    "preservationReservation", "privateAlias", "privateComponent", "privateDirectory",
    "privateEntries", "privateFile", "privateName", "privateShortWrite", "read",
    "request.proposedBytes", "request.vault", "recovery.vault", "root.directory", "root.url",
    "selection.directory", "selection.nestedLifeOS", "selection.root", "selection.symlink",
    "selection.uni", "selection.url", "shortWrite", "test.cleanupAfterWitness", "test.delete",
    "test.directReplay", "test.recoveryPreservation", "test.replace", "test.sameInode",
    "test.verifiedRecovery", "unsupported", "userSelectedReadWriteUnavailable"
]

internal func planningStableDiagnosticReason(_ reason: String, fallback: String) -> String {
    planningDiagnosticReasonAllowlist.contains(reason) ? reason : fallback
}

public enum PlanningDiagnosticStage: String, Equatable, Sendable {
    case storeRead
    case storeContext
    case sessionRead
    case sessionDecode
    case sessionContext
}

public struct PlanningDiagnostic: Equatable, Sendable {
    public let stage: PlanningDiagnosticStage
    public let code: String

    public init(stage: PlanningDiagnosticStage, code: String) {
        self.stage = stage
        self.code = code
    }
}

internal enum PlanningDiagnostics {
    private static let logger = Logger(subsystem: "LifeOS", category: "Planning")

    static func code(for error: Error) -> String {
        if let error = error as? PlanningFilesystemError {
            return error.stableCode
        }
        if let error = error as? PlanningStorageError {
            return planningFilesystemSafeErrorCode(error)
        }
        if let error = error as? PlanningCanvasSessionError {
            return error.stableCode
        }
        return "unavailable.operation"
    }

    static func emit(_ diagnostic: PlanningDiagnostic) {
        logger.error(
            "planning stage=\(diagnostic.stage.rawValue, privacy: .public) code=\(diagnostic.code, privacy: .public)"
        )
    }
}

/// Errors from the filesystem adapter are deliberately content-free.  Paths,
/// note text, bookmark bytes and provider metadata never appear in their
/// descriptions or stable codes.
public enum PlanningFilesystemError: Error, Equatable, LocalizedError, Sendable {
    case unselected
    case needsReselection
    case providerOffline
    case notDownloaded
    case permissionDenied
    case readOnly
    case diskFull
    case unsupportedFilesystem
    case caseCollision
    case identityChanged
    case changedDuringRead
    case malformedDocument
    case conflict
    case ambiguousPublication
    case corruptEvidence
    case cancelled
    case notFound
    case alreadyExists
    case backpressure(String)
    case invalid(String)
    case unavailable(String)

    public var stableCode: String {
        switch self {
        case .unselected: return "unselected"
        case .needsReselection: return "needsReselection"
        case .providerOffline: return "providerOffline"
        case .notDownloaded: return "notDownloaded"
        case .permissionDenied: return "permissionDenied"
        case .readOnly: return "readOnly"
        case .diskFull: return "diskFull"
        case .unsupportedFilesystem: return "unsupportedFilesystem"
        case .caseCollision: return "caseCollision"
        case .identityChanged: return "identityChanged"
        case .changedDuringRead: return "changedDuringRead"
        case .malformedDocument: return "malformedDocument"
        case .conflict: return "conflict"
        case .ambiguousPublication: return "ambiguousPublication"
        case .corruptEvidence: return "corruptEvidence"
        case .cancelled: return "cancelled"
        case .notFound: return "notFound"
        case .alreadyExists: return "alreadyExists"
        case .backpressure(let reason):
            return "backpressure." + planningStableDiagnosticReason(reason, fallback: "operation")
        case .invalid(let reason):
            return "invalid." + planningStableDiagnosticReason(reason, fallback: "request")
        case .unavailable(let reason):
            return "unavailable." + planningStableDiagnosticReason(reason, fallback: "operation")
        }
    }

    public var errorDescription: String? {
        switch self {
        case .unselected: return "No planning vault is selected."
        case .needsReselection: return "The selected planning vault needs to be selected again."
        case .providerOffline: return "The planning provider is temporarily offline."
        case .notDownloaded: return "The planning file is not downloaded."
        case .permissionDenied: return "The planning vault denied access."
        case .readOnly: return "The planning vault is read-only."
        case .diskFull: return "The planning vault is out of space."
        case .unsupportedFilesystem: return "This filesystem cannot provide the required safe publication operations."
        case .caseCollision: return "The planning vault contains colliding names."
        case .identityChanged: return "The selected planning vault changed identity."
        case .changedDuringRead: return "The planning file changed while it was being read."
        case .malformedDocument: return "The planning document is malformed."
        case .conflict: return "The planning document has a conflict."
        case .ambiguousPublication: return "The planning publication needs reconciliation."
        case .corruptEvidence: return "The planning publication evidence is corrupt."
        case .cancelled: return "The planning operation was cancelled."
        case .notFound: return "The planning file was not found."
        case .alreadyExists: return "The planning destination already exists."
        case .backpressure: return "The planning filesystem is applying backpressure."
        case .invalid: return "The planning filesystem request is invalid."
        case .unavailable: return "The planning filesystem is temporarily unavailable."
        }
    }
}

public enum PlanningFilesystemLimits {
    public static let maximumPathBytes = 1_024
    public static let maximumDepth = 64
    public static let maximumDirectoryEntries = 4_096
    public static let maximumVisitedEntries = 16_384
    public static let maximumDirectoryNameBytes = 255
    public static let maximumMarkerBytes = PlanningStorageLimits.vaultMarkerBytes
    public static let maximumManifestBytes = 16 * 1024
    public static let maximumManifestCount = 1_024
    /// A grant record contains at most a 64 KiB bookmark plus bounded JSON
    /// framing/base64 overhead.  This ceiling is applied to the file before
    /// any grant bytes are materialized or decoded.
    public static let maximumGrantBytes = 128 * 1024
    public static let maximumAuthorityBytes = 16 * 1024
    public static let maximumPreservedBytes = 64 * 1024 * 1024
    public static let maximumPreservedArtifacts = 256
    public static let maximumCacheIndexBytes = 512 * 1024
    public static let maximumCacheRecords = 256
    public static let maximumCacheBytes = PlanningStorageLimits.cleanCacheBytes
    public static let ioChunkBytes = 64 * 1024
    public static let maximumRecoveryEntries = PlanningStorageLimits.recoveryBatch
}

/// The identity pinned when a user selects a vault.  `PlanningFileIdentity`
/// remains the journal's compact device/inode/file-type identity; this local
/// identity adds the metadata that the platform exposes for authority checks.
internal struct PlanningStableDirectoryIdentity: Codable, Equatable, Sendable {
    let device: UInt64
    let inode: UInt64
    let mode: UInt32
    let owner: UInt32
    let group: UInt32
    let providerIdentifier: String?

    init(
        device: UInt64,
        inode: UInt64,
        mode: UInt32,
        owner: UInt32,
        group: UInt32,
        providerIdentifier: String?
    ) throws {
        guard device > 0, inode > 0,
              (mode & 0o170000) == 0o040000,
              (providerIdentifier?.utf8.count ?? 0) <= 256 else {
            throw PlanningFilesystemError.invalid("authority.identity")
        }
        self.device = device
        self.inode = inode
        self.mode = mode
        self.owner = owner
        self.group = group
        self.providerIdentifier = providerIdentifier
    }
}

internal struct PlanningPreservationInventory: Equatable, Sendable {
    let bytes: Int
    let artifacts: Int
    let visitedEntries: Int

    init(bytes: Int = 0, artifacts: Int = 0, visitedEntries: Int = 0) {
        self.bytes = bytes
        self.artifacts = artifacts
        self.visitedEntries = visitedEntries
    }

    func reserving(bytes additionalBytes: Int, artifacts additionalArtifacts: Int) throws {
        guard additionalBytes >= 0, additionalArtifacts >= 0 else {
            throw PlanningFilesystemError.invalid("preservationReservation")
        }
        let (nextBytes, byteOverflow) = bytes.addingReportingOverflow(additionalBytes)
        let (nextArtifacts, artifactOverflow) = artifacts.addingReportingOverflow(additionalArtifacts)
        guard !byteOverflow, !artifactOverflow,
              nextBytes <= PlanningFilesystemLimits.maximumPreservedBytes,
              nextArtifacts <= PlanningFilesystemLimits.maximumPreservedArtifacts else {
            throw PlanningFilesystemError.backpressure("preservation")
        }
    }
}

public struct PlanningFilesystemCapabilities: Codable, Equatable, Sendable {
    public let signedAppAccessAvailable: Bool
    public let canRead: Bool
    public let canPublish: Bool
    public let supportsDescriptorTraversal: Bool
    public let supportsExclusiveRename: Bool
    public let supportsSwapRename: Bool
    public let supportsDirectoryFlush: Bool
    public let providerIdentifier: String?
    public let reasonCode: String?

    public init(
        signedAppAccessAvailable: Bool,
        canRead: Bool,
        canPublish: Bool,
        supportsDescriptorTraversal: Bool,
        supportsExclusiveRename: Bool,
        supportsSwapRename: Bool,
        supportsDirectoryFlush: Bool,
        providerIdentifier: String? = nil,
        reasonCode: String? = nil
    ) {
        self.signedAppAccessAvailable = signedAppAccessAvailable
        self.canRead = canRead
        self.canPublish = canPublish
        self.supportsDescriptorTraversal = supportsDescriptorTraversal
        self.supportsExclusiveRename = supportsExclusiveRename
        self.supportsSwapRename = supportsSwapRename
        self.supportsDirectoryFlush = supportsDirectoryFlush
        self.providerIdentifier = providerIdentifier
        self.reasonCode = reasonCode
    }

    public static let unavailableSignedApp = PlanningFilesystemCapabilities(
        signedAppAccessAvailable: false,
        canRead: false,
        canPublish: false,
        supportsDescriptorTraversal: false,
        supportsExclusiveRename: false,
        supportsSwapRename: false,
        supportsDirectoryFlush: false,
        reasonCode: "userSelectedReadWriteUnavailable"
    )
}

public struct PlanningVaultReadResult: Sendable, Equatable {
    public let snapshot: PlanningDocumentSnapshot?
    public let version: PlanningContentVersion
    public let vaultID: UUID?
    public let selectionGeneration: UUID?
    public let stale: Bool
    public let accessState: PlanningVaultAccessState
    public let fromCache: Bool

    public init(
        snapshot: PlanningDocumentSnapshot?,
        version: PlanningContentVersion,
        vaultID: UUID? = nil,
        selectionGeneration: UUID? = nil,
        stale: Bool,
        accessState: PlanningVaultAccessState,
        fromCache: Bool
    ) {
        self.snapshot = snapshot
        self.version = version
        self.vaultID = vaultID
        self.selectionGeneration = selectionGeneration
        self.stale = stale
        self.accessState = accessState
        self.fromCache = fromCache
    }
}

public enum PlanningFilesystemPublicationStatus: String, Codable, Equatable, Sendable {
    case staged
    case published
    case conflicted
    case queued
    case reconciled
    case blocked
}

public struct PlanningFilesystemPublishResult: Sendable, Equatable {
    public let status: PlanningFilesystemPublicationStatus
    public let receipt: PlanningMutationReceipt?
    public let version: PlanningContentVersion?
    public let errorCode: String?

    public init(
        status: PlanningFilesystemPublicationStatus,
        receipt: PlanningMutationReceipt? = nil,
        version: PlanningContentVersion? = nil,
        errorCode: String? = nil
    ) {
        self.status = status
        self.receipt = receipt
        self.version = version
        self.errorCode = errorCode
    }
}

public enum PlanningFilesystemAttemptPhase: String, Codable, Equatable, Sendable {
    case intent
    case verified
    case cleanupPending
}

/// Private filesystem evidence.  This is intentionally separate from the
/// journal's logical state machine.  It never contains a bookmark or an
/// absolute path.
public struct PlanningFilesystemAttemptRecord: Codable, Equatable, Sendable {
    public let schemaVersion: Int
    public let vaultID: UUID
    public let deviceID: UUID
    public let selectionGeneration: UUID
    public let mutationID: UUID
    public let mutationFingerprint: String
    public let attemptID: UUID
    public let operation: PlanningMutationOperation
    public let path: PlanningStoredPath
    public let expectedVersion: PlanningContentVersion
    public let proposedVersion: PlanningContentVersion
    public let rootIdentity: PlanningFileIdentity
    public let parentChain: [PlanningFileIdentity]
    public let stageIdentity: PlanningFileIdentity?
    public let backupIdentity: PlanningFileIdentity?
    public let witnessName: String
    public let backupVersion: PlanningContentVersion?
    public let backupDigest: String?
    public let phase: PlanningFilesystemAttemptPhase
    public let verifiedOutcome: PlanningPublicationOutcomeRecord?
    public let errorCode: String?
    public let createdAt: Date
    public let updatedAt: Date

    public init(
        vaultID: UUID,
        deviceID: UUID,
        selectionGeneration: UUID,
        mutationID: UUID,
        mutationFingerprint: String,
        attemptID: UUID,
        operation: PlanningMutationOperation,
        path: PlanningStoredPath,
        expectedVersion: PlanningContentVersion,
        proposedVersion: PlanningContentVersion,
        rootIdentity: PlanningFileIdentity,
        parentChain: [PlanningFileIdentity],
        stageIdentity: PlanningFileIdentity? = nil,
        backupIdentity: PlanningFileIdentity? = nil,
        witnessName: String,
        backupVersion: PlanningContentVersion? = nil,
        backupDigest: String? = nil,
        phase: PlanningFilesystemAttemptPhase = .intent,
        verifiedOutcome: PlanningPublicationOutcomeRecord? = nil,
        errorCode: String? = nil,
        createdAt: Date = Date(),
        updatedAt: Date = Date()
    ) throws {
        guard planningDigestIsValid(mutationFingerprint),
              mutationFingerprint.contains(where: { $0 != "0" }),
              !witnessName.isEmpty,
              witnessName.utf8.count <= 255,
              witnessName.hasPrefix(".lifeos-stage-") else {
            throw PlanningFilesystemError.invalid("manifest.identity")
        }
        guard parentChain.count <= PlanningFilesystemLimits.maximumDepth + 1 else {
            throw PlanningFilesystemError.backpressure("manifest.parentChain")
        }
        try planningValidateContentVersion(
            expectedVersion,
            maximumByteCount: path.isCanvas ? PlanningStorageLimits.canvasBytes : PlanningStorageLimits.markdownBytes,
            field: "manifest.expectedVersion"
        )
        try planningValidateContentVersion(
            proposedVersion,
            maximumByteCount: path.isCanvas ? PlanningStorageLimits.canvasBytes : PlanningStorageLimits.markdownBytes,
            field: "manifest.proposedVersion"
        )
        if let backupVersion {
            try planningValidateContentVersion(
                backupVersion,
                maximumByteCount: path.isCanvas ? PlanningStorageLimits.canvasBytes : PlanningStorageLimits.markdownBytes,
                field: "manifest.backupVersion"
            )
        }
        if let backupDigest {
            guard planningDigestIsValid(backupDigest) else {
                throw PlanningFilesystemError.invalid("manifest.backupDigest")
            }
        }
        guard rootIdentity.fileType == 2,
              parentChain.allSatisfy({ $0.fileType == 2 }) else {
            throw PlanningFilesystemError.invalid("manifest.identityType")
        }
        if let stageIdentity, stageIdentity.fileType != 1 {
            throw PlanningFilesystemError.invalid("manifest.identityType")
        }
        if let backupIdentity, backupIdentity.fileType != 1 {
            throw PlanningFilesystemError.invalid("manifest.identityType")
        }
        self.schemaVersion = 1
        self.vaultID = vaultID
        self.deviceID = deviceID
        self.selectionGeneration = selectionGeneration
        self.mutationID = mutationID
        self.mutationFingerprint = mutationFingerprint
        self.attemptID = attemptID
        self.operation = operation
        self.path = path
        self.expectedVersion = expectedVersion
        self.proposedVersion = proposedVersion
        self.rootIdentity = rootIdentity
        self.parentChain = parentChain
        self.stageIdentity = stageIdentity
        self.backupIdentity = backupIdentity
        self.witnessName = witnessName
        self.backupVersion = backupVersion
        self.backupDigest = backupDigest
        self.phase = phase
        self.verifiedOutcome = verifiedOutcome
        self.errorCode = errorCode
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: PlanningAnyCodingKey.self)
        let version = try c.decode(Int.self, forKey: planningCodingKey("schemaVersion"))
        guard version == 1 else { throw PlanningFilesystemError.corruptEvidence }
        try self.init(
            vaultID: try c.decode(UUID.self, forKey: planningCodingKey("vaultID")),
            deviceID: try c.decode(UUID.self, forKey: planningCodingKey("deviceID")),
            selectionGeneration: try c.decode(UUID.self, forKey: planningCodingKey("selectionGeneration")),
            mutationID: try c.decode(UUID.self, forKey: planningCodingKey("mutationID")),
            mutationFingerprint: try c.decode(String.self, forKey: planningCodingKey("mutationFingerprint")),
            attemptID: try c.decode(UUID.self, forKey: planningCodingKey("attemptID")),
            operation: try c.decode(PlanningMutationOperation.self, forKey: planningCodingKey("operation")),
            path: try c.decode(PlanningStoredPath.self, forKey: planningCodingKey("path")),
            expectedVersion: try c.decode(PlanningContentVersion.self, forKey: planningCodingKey("expectedVersion")),
            proposedVersion: try c.decode(PlanningContentVersion.self, forKey: planningCodingKey("proposedVersion")),
            rootIdentity: try c.decode(PlanningFileIdentity.self, forKey: planningCodingKey("rootIdentity")),
            parentChain: try c.decode([PlanningFileIdentity].self, forKey: planningCodingKey("parentChain")),
            stageIdentity: try c.decodeIfPresent(PlanningFileIdentity.self, forKey: planningCodingKey("stageIdentity")),
            backupIdentity: try c.decodeIfPresent(PlanningFileIdentity.self, forKey: planningCodingKey("backupIdentity")),
            witnessName: try c.decode(String.self, forKey: planningCodingKey("witnessName")),
            backupVersion: try c.decodeIfPresent(PlanningContentVersion.self, forKey: planningCodingKey("backupVersion")),
            backupDigest: try c.decodeIfPresent(String.self, forKey: planningCodingKey("backupDigest")),
            phase: try c.decode(PlanningFilesystemAttemptPhase.self, forKey: planningCodingKey("phase")),
            verifiedOutcome: try c.decodeIfPresent(PlanningPublicationOutcomeRecord.self, forKey: planningCodingKey("verifiedOutcome")),
            errorCode: try c.decodeIfPresent(String.self, forKey: planningCodingKey("errorCode")),
            createdAt: try c.decode(Date.self, forKey: planningCodingKey("createdAt")),
            updatedAt: try c.decode(Date.self, forKey: planningCodingKey("updatedAt"))
        )
    }
}

public struct PlanningFilesystemRecoveryReport: Sendable, Equatable {
    public let examined: Int
    public let reconciled: Int
    public let blocked: Int
    public let nextCursor: PlanningPublicationRecoveryCursor?
    public let endOfPass: Bool
    public let errorCodes: [String]

    public init(
        examined: Int,
        reconciled: Int,
        blocked: Int,
        nextCursor: PlanningPublicationRecoveryCursor?,
        endOfPass: Bool,
        errorCodes: [String] = []
    ) {
        self.examined = examined
        self.reconciled = reconciled
        self.blocked = blocked
        self.nextCursor = nextCursor
        self.endOfPass = endOfPass
        self.errorCodes = Array(errorCodes.prefix(PlanningFilesystemLimits.maximumRecoveryEntries))
    }
}

public struct PlanningRawFileRead: Sendable, Equatable {
    public let data: Data
    public let identity: PlanningFileIdentity
    public let parentChain: [PlanningFileIdentity]

    public init(data: Data, identity: PlanningFileIdentity, parentChain: [PlanningFileIdentity]) {
        self.data = data
        self.identity = identity
        self.parentChain = parentChain
    }
}

internal func planningFilesystemCollisionKey(_ component: String) -> String {
    component.folding(
        options: [.caseInsensitive, .diacriticInsensitive],
        locale: Locale(identifier: "en_US_POSIX")
    )
}

internal func planningFilesystemDocumentLimit(for path: PlanningStoredPath) -> Int {
    path.isCanvas ? PlanningStorageLimits.canvasBytes : PlanningStorageLimits.markdownBytes
}

internal func planningFilesystemSafeErrorCode(_ error: Error) -> String {
    if let error = error as? PlanningFilesystemError { return error.stableCode }
    if let error = error as? PlanningStorageError {
        switch error {
        case .databaseFull: return PlanningFilesystemError.diskFull.stableCode
        case .staleAccess: return PlanningFilesystemError.needsReselection.stableCode
        case .backpressure(let reason):
            return "backpressure." + planningStableDiagnosticReason(reason, fallback: "operation")
        case .invalid: return "storage.invalid"
        case .corruptDatabase: return "storage.corruptDatabase"
        case .unsupportedSchema: return "storage.unsupportedSchema"
        case .database: return "storage.database"
        case .writerBusy: return "storage.writerBusy"
        case .mutationIDReused: return "storage.mutationIDReused"
        case .duplicateRequest: return "storage.duplicateRequest"
        case .notFound: return PlanningFilesystemError.notFound.stableCode
        case .invalidState: return "storage.invalidState"
        case .conflict: return PlanningFilesystemError.conflict.stableCode
        case .closed: return "storage.closed"
        case .unavailable: return "storage.unavailable"
        }
    }
    return "unavailable.operation"
}
