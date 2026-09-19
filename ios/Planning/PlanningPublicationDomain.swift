import Foundation
import CryptoKit

internal enum PlanningPublicationLimits {
    static let schemaVersion = 2
    static let maximumAttemptsPerMutation = 64
    static let maximumRetainedMutations = 16_384
    static let maximumContextBytes = 4 * 1024
    static let maximumOutcomeBytes = 2 * 1024
    // Data values are base64 encoded by JSONEncoder. The publication encoder
    // disables unnecessary slash escaping, so this is the exact base64 upper
    // bound for the largest valid Canvas payload plus the typed record. Keep
    // the arithmetic checked even though the current limits are small.
    static let maximumResolutionBytes: Int = {
        let fullGroups = PlanningStorageLimits.canvasBytes / 3
        let remainder = PlanningStorageLimits.canvasBytes % 3
        let base64Bytes = fullGroups * 4 + (remainder == 0 ? 0 : 4)
        let (boundedBytes, overflow) = base64Bytes.addingReportingOverflow(16 * 1024)
        precondition(!overflow)
        return boundedBytes
    }()
    static let maximumWitnessBytes = 512
    static let maximumErrorCodeBytes = 256
    static let legacyInspectionReason = "resolvedConflictWithoutDecision"
    static let regularFileType: UInt32 = 1
    static let directoryFileType: UInt32 = 2
}

internal func planningPublicationRequireKeys(
    _ keys: [PlanningAnyCodingKey],
    required: Set<String>,
    field: String
) throws {
    guard required.isSubset(of: Set(keys.map(\.stringValue))) else {
        throw PlanningStorageError.invalid("\(field).keys")
    }
}

internal func planningPublicationRequireExactKeys(
    _ keys: [PlanningAnyCodingKey],
    required: Set<String>,
    field: String
) throws {
    guard Set(keys.map(\.stringValue)) == required else {
        throw PlanningStorageError.invalid("\(field).keys")
    }
}

internal func planningPublicationValidateString(
    _ value: String,
    maximumBytes: Int,
    field: String,
    allowEmpty: Bool = true
) throws {
    guard (allowEmpty || !value.isEmpty), value.utf8.count <= maximumBytes else {
        throw PlanningStorageError.invalid(field)
    }
    guard !value.utf8.contains(0) else {
        throw PlanningStorageError.invalid("\(field).nul")
    }
}

internal func planningPublicationEncodeJSON<T: Encodable>(
    _ value: T,
    maximumBytes: Int,
    field: String
) throws -> Data {
    // Forward slashes are legal JSON characters. Foundation's default
    // encoder may spell each slash in a base64 Data value as `\/`, which can
    // inflate a valid near-limit Canvas record beyond the protocol ceiling.
    // This option is available on every supported iOS/macOS deployment target
    // and keeps the byte representation deterministic and bounded.
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
    let data = try encoder.encode(value)
    guard data.count <= maximumBytes else {
        throw PlanningStorageError.backpressure(field)
    }
    return data
}

internal func planningPublicationDecodeJSON<T: Decodable>(
    _ type: T.Type,
    data: Data,
    maximumBytes: Int,
    field: String
) throws -> T {
    guard data.count <= maximumBytes else {
        throw PlanningStorageError.corruptDatabase
    }
    do {
        return try JSONDecoder().decode(type, from: data)
    } catch let error as PlanningStorageError {
        throw error
    } catch {
        throw PlanningStorageError.corruptDatabase
    }
}

internal func planningPublicationIsFinite(_ value: Double) -> Bool {
    value.isFinite
}

public enum PlanningPublicationPhase: String, Codable, Equatable, Sendable {
    case prepared
    case stageReady
    case publishing
    case published
    case conflicted
    case failed
}

public struct PlanningPublicationContext: Codable, Equatable, Sendable {
    public let selectionGeneration: UUID
    public let rootIdentity: PlanningFileIdentity
    public let observedVersion: PlanningContentVersion
    public let observedIdentity: PlanningFileIdentity?

    public init(
        selectionGeneration: UUID,
        rootIdentity: PlanningFileIdentity,
        observedVersion: PlanningContentVersion,
        observedIdentity: PlanningFileIdentity?
    ) throws {
        guard rootIdentity.fileType == PlanningPublicationLimits.directoryFileType else {
            throw PlanningStorageError.invalid("publicationContext.rootIdentity")
        }
        try planningValidateContentVersion(
            observedVersion,
            maximumByteCount: PlanningStorageLimits.canvasBytes,
            field: "publicationContext.observedVersion"
        )
        switch observedVersion {
        case .absent:
            guard observedIdentity == nil else {
                throw PlanningStorageError.invalid("publicationContext.observedIdentity")
            }
        case .bytes:
            guard observedIdentity?.fileType == PlanningPublicationLimits.regularFileType else {
                throw PlanningStorageError.invalid("publicationContext.observedIdentity")
            }
        }
        self.selectionGeneration = selectionGeneration
        self.rootIdentity = rootIdentity
        self.observedVersion = observedVersion
        self.observedIdentity = observedIdentity
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: PlanningAnyCodingKey.self)
        try planningPublicationRequireKeys(
            container.allKeys,
            required: ["selectionGeneration", "rootIdentity", "observedVersion"],
            field: "publicationContext"
        )
        try self.init(
            selectionGeneration: try container.decode(UUID.self, forKey: planningCodingKey("selectionGeneration")),
            rootIdentity: try container.decode(PlanningFileIdentity.self, forKey: planningCodingKey("rootIdentity")),
            observedVersion: try container.decode(
                PlanningContentVersion.self,
                forKey: planningCodingKey("observedVersion")
            ),
            observedIdentity: try container.decodeIfPresent(
                PlanningFileIdentity.self,
                forKey: planningCodingKey("observedIdentity")
            )
        )
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: PlanningAnyCodingKey.self)
        try container.encode(selectionGeneration, forKey: planningCodingKey("selectionGeneration"))
        try container.encode(rootIdentity, forKey: planningCodingKey("rootIdentity"))
        try container.encode(observedVersion, forKey: planningCodingKey("observedVersion"))
        try container.encodeIfPresent(observedIdentity, forKey: planningCodingKey("observedIdentity"))
    }
}

public enum PlanningPublicationOutcomeRecord: Codable, Equatable, Sendable {
    case published(PlanningContentVersion)
    case conflicted
    case failed(code: String, retryable: Bool)

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: PlanningAnyCodingKey.self)
        let kind = try container.decode(String.self, forKey: planningCodingKey("kind"))
        switch kind {
        case "published":
            try planningPublicationRequireExactKeys(
                container.allKeys,
                required: ["kind", "resultVersion"],
                field: "publicationOutcome"
            )
            self = .published(try container.decode(
                PlanningContentVersion.self,
                forKey: planningCodingKey("resultVersion")
            ))
        case "conflicted":
            try planningPublicationRequireExactKeys(
                container.allKeys,
                required: ["kind"],
                field: "publicationOutcome"
            )
            self = .conflicted
        case "failed":
            try planningPublicationRequireExactKeys(
                container.allKeys,
                required: ["kind", "code", "retryable"],
                field: "publicationOutcome"
            )
            let code = try container.decode(String.self, forKey: planningCodingKey("code"))
            try planningPublicationValidateString(
                code,
                maximumBytes: PlanningPublicationLimits.maximumErrorCodeBytes,
                field: "publicationOutcome.code",
                allowEmpty: false
            )
            self = .failed(
                code: code,
                retryable: try container.decode(Bool.self, forKey: planningCodingKey("retryable"))
            )
        default:
            throw PlanningStorageError.invalid("publicationOutcome.kind")
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: PlanningAnyCodingKey.self)
        switch self {
        case .published(let version):
            try container.encode("published", forKey: planningCodingKey("kind"))
            try container.encode(version, forKey: planningCodingKey("resultVersion"))
        case .conflicted:
            try container.encode("conflicted", forKey: planningCodingKey("kind"))
        case .failed(let code, let retryable):
            try planningPublicationValidateString(
                code,
                maximumBytes: PlanningPublicationLimits.maximumErrorCodeBytes,
                field: "publicationOutcome.code",
                allowEmpty: false
            )
            try container.encode("failed", forKey: planningCodingKey("kind"))
            try container.encode(code, forKey: planningCodingKey("code"))
            try container.encode(retryable, forKey: planningCodingKey("retryable"))
        }
    }
}

public struct PlanningPublicationAttemptSnapshot: Codable, Equatable, Sendable {
    public let attemptID: UUID
    public let mutationID: UUID
    public let ordinal: Int
    public let phase: PlanningPublicationPhase
    public let context: PlanningPublicationContext?
    public let witnessName: String?
    public let stagedIdentity: PlanningFileIdentity?
    public let outcome: PlanningPublicationOutcomeRecord?
    public let retryAfter: Date?
    public let legacyUnverified: Bool

    public init(
        attemptID: UUID,
        mutationID: UUID,
        ordinal: Int,
        phase: PlanningPublicationPhase,
        context: PlanningPublicationContext? = nil,
        witnessName: String? = nil,
        stagedIdentity: PlanningFileIdentity? = nil,
        outcome: PlanningPublicationOutcomeRecord? = nil,
        retryAfter: Date? = nil,
        legacyUnverified: Bool = false
    ) throws {
        guard ordinal > 0, ordinal <= PlanningPublicationLimits.maximumAttemptsPerMutation else {
            throw PlanningStorageError.invalid("publicationAttempt.ordinal")
        }
        if let witnessName {
            try planningPublicationValidateString(
                witnessName,
                maximumBytes: PlanningPublicationLimits.maximumWitnessBytes,
                field: "publicationAttempt.witnessName",
                allowEmpty: false
            )
        }
        if let stagedIdentity, !legacyUnverified {
            guard stagedIdentity.fileType == PlanningPublicationLimits.regularFileType else {
                throw PlanningStorageError.invalid("publicationAttempt.stagedIdentity")
            }
        }
        if let retryAfter {
            guard retryAfter.timeIntervalSince1970.isFinite else {
                throw PlanningStorageError.invalid("publicationAttempt.retryAfter")
            }
        }
        if !legacyUnverified {
            switch phase {
            case .prepared:
                guard outcome == nil, witnessName == nil, stagedIdentity == nil else {
                    throw PlanningStorageError.invalid("publicationAttempt.preparedEvidence")
                }
            case .stageReady:
                guard outcome == nil, witnessName != nil, stagedIdentity != nil else {
                    throw PlanningStorageError.invalid("publicationAttempt.stageReadyEvidence")
                }
            case .publishing:
                guard outcome == nil, context != nil, witnessName != nil else {
                    throw PlanningStorageError.invalid("publicationAttempt.publishingEvidence")
                }
            case .published:
                guard context != nil, witnessName != nil,
                      case .published? = outcome else {
                    throw PlanningStorageError.invalid("publicationAttempt.publishedEvidence")
                }
            case .conflicted:
                guard case .conflicted? = outcome else {
                    throw PlanningStorageError.invalid("publicationAttempt.conflictedEvidence")
                }
            case .failed:
                guard case .failed? = outcome else {
                    throw PlanningStorageError.invalid("publicationAttempt.failedEvidence")
                }
            }
        }
        self.attemptID = attemptID
        self.mutationID = mutationID
        self.ordinal = ordinal
        self.phase = phase
        self.context = context
        self.witnessName = witnessName
        self.stagedIdentity = stagedIdentity
        self.outcome = outcome
        self.retryAfter = retryAfter
        self.legacyUnverified = legacyUnverified
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: PlanningAnyCodingKey.self)
        try planningPublicationRequireKeys(
            container.allKeys,
            required: ["attemptID", "mutationID", "ordinal", "phase", "legacyUnverified"],
            field: "publicationAttempt"
        )
        try self.init(
            attemptID: try container.decode(UUID.self, forKey: planningCodingKey("attemptID")),
            mutationID: try container.decode(UUID.self, forKey: planningCodingKey("mutationID")),
            ordinal: try container.decode(Int.self, forKey: planningCodingKey("ordinal")),
            phase: try container.decode(PlanningPublicationPhase.self, forKey: planningCodingKey("phase")),
            context: try container.decodeIfPresent(
                PlanningPublicationContext.self,
                forKey: planningCodingKey("context")
            ),
            witnessName: try container.decodeIfPresent(String.self, forKey: planningCodingKey("witnessName")),
            stagedIdentity: try container.decodeIfPresent(
                PlanningFileIdentity.self,
                forKey: planningCodingKey("stagedIdentity")
            ),
            outcome: try container.decodeIfPresent(
                PlanningPublicationOutcomeRecord.self,
                forKey: planningCodingKey("outcome")
            ),
            retryAfter: try container.decodeIfPresent(Double.self, forKey: planningCodingKey("retryAfter")).map {
                guard $0.isFinite else { throw PlanningStorageError.invalid("publicationAttempt.retryAfter") }
                return Date(timeIntervalSince1970: $0)
            },
            legacyUnverified: try container.decode(Bool.self, forKey: planningCodingKey("legacyUnverified"))
        )
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: PlanningAnyCodingKey.self)
        try container.encode(attemptID, forKey: planningCodingKey("attemptID"))
        try container.encode(mutationID, forKey: planningCodingKey("mutationID"))
        try container.encode(ordinal, forKey: planningCodingKey("ordinal"))
        try container.encode(phase, forKey: planningCodingKey("phase"))
        try container.encodeIfPresent(context, forKey: planningCodingKey("context"))
        try container.encodeIfPresent(witnessName, forKey: planningCodingKey("witnessName"))
        try container.encodeIfPresent(stagedIdentity, forKey: planningCodingKey("stagedIdentity"))
        try container.encodeIfPresent(outcome, forKey: planningCodingKey("outcome"))
        try container.encodeIfPresent(retryAfter?.timeIntervalSince1970, forKey: planningCodingKey("retryAfter"))
        try container.encode(legacyUnverified, forKey: planningCodingKey("legacyUnverified"))
    }
}

public struct PlanningPublicationRecoveryCursor: Codable, Equatable, Sendable {
    public let vaultID: UUID
    public let maximumSequence: Int64
    public let lastExaminedSequence: Int64

    public init(vaultID: UUID, maximumSequence: Int64, lastExaminedSequence: Int64) throws {
        guard maximumSequence >= 0,
              lastExaminedSequence >= 0,
              lastExaminedSequence <= maximumSequence else {
            throw PlanningStorageError.invalid("publicationRecovery.cursor")
        }
        self.vaultID = vaultID
        self.maximumSequence = maximumSequence
        self.lastExaminedSequence = lastExaminedSequence
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: PlanningAnyCodingKey.self)
        try planningPublicationRequireKeys(
            container.allKeys,
            required: ["vaultID", "maximumSequence", "lastExaminedSequence"],
            field: "publicationRecovery.cursor"
        )
        try self.init(
            vaultID: try container.decode(UUID.self, forKey: planningCodingKey("vaultID")),
            maximumSequence: try container.decode(Int64.self, forKey: planningCodingKey("maximumSequence")),
            lastExaminedSequence: try container.decode(
                Int64.self,
                forKey: planningCodingKey("lastExaminedSequence")
            )
        )
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: PlanningAnyCodingKey.self)
        try container.encode(vaultID, forKey: planningCodingKey("vaultID"))
        try container.encode(maximumSequence, forKey: planningCodingKey("maximumSequence"))
        try container.encode(lastExaminedSequence, forKey: planningCodingKey("lastExaminedSequence"))
    }
}

public struct PlanningPublicationRecoveryEntry: Sendable, Equatable {
    /// The durable mutation sequence used to advance recovery without
    /// rewinding over entries that were already examined.
    public let sequence: Int64
    public let recovery: PlanningRecoveryEntry
    public let attempt: PlanningPublicationAttemptSnapshot?

    public init(
        recovery: PlanningRecoveryEntry,
        attempt: PlanningPublicationAttemptSnapshot?,
        sequence: Int64 = 0
    ) {
        self.sequence = sequence
        self.recovery = recovery
        self.attempt = attempt
    }
}

public struct PlanningPublicationRecoveryPage: Sendable, Equatable {
    public let entries: [PlanningPublicationRecoveryEntry]
    public let nextCursor: PlanningPublicationRecoveryCursor
    public let endOfPass: Bool

    public init(
        entries: [PlanningPublicationRecoveryEntry],
        nextCursor: PlanningPublicationRecoveryCursor,
        endOfPass: Bool
    ) throws {
        guard entries.count <= PlanningStorageLimits.recoveryBatch else {
            throw PlanningStorageError.invalid("publicationRecovery.entries")
        }
        var previousSequence: Int64 = 0
        for entry in entries {
            guard entry.sequence > 0,
                  entry.sequence > previousSequence,
                  entry.sequence <= nextCursor.maximumSequence else {
                throw PlanningStorageError.invalid("publicationRecovery.sequence")
            }
            previousSequence = entry.sequence
        }
        guard entries.last.map({ $0.sequence <= nextCursor.lastExaminedSequence }) ?? true else {
            throw PlanningStorageError.invalid("publicationRecovery.cursorBoundary")
        }
        let materialized = entries.reduce(0) { partialResult, entry in
            partialResult + (entry.recovery.request.proposedBytes?.count ?? 0)
        }
        guard materialized <= PlanningStorageLimits.recoveryPayloadBytes else {
            throw PlanningStorageError.invalid("publicationRecovery.payloadBytes")
        }
        self.entries = entries
        self.nextCursor = nextCursor
        self.endOfPass = endOfPass
    }
}

public struct PlanningDurableResolutionRecord: Codable, Equatable, Sendable {
    public let conflictID: UUID
    public let decisionFingerprint: String
    public let resolution: PlanningConflictResolution
    public let childMutationID: UUID?
    /// The parent mutation continued in place. This is deliberately separate
    /// from childMutationID so repeated historical continuations do not reuse
    /// the conflict_resolutions.child_mutation_id UNIQUE key.
    public let continuationMutationID: UUID?

    public init(
        conflictID: UUID,
        decisionFingerprint: String,
        resolution: PlanningConflictResolution,
        childMutationID: UUID?,
        continuationMutationID: UUID? = nil
    ) throws {
        guard planningDigestIsValid(decisionFingerprint),
              decisionFingerprint.contains(where: { $0 != "0" }),
              !(childMutationID != nil && continuationMutationID != nil) else {
            throw PlanningStorageError.invalid("durableResolution.decisionFingerprint")
        }
        self.conflictID = conflictID
        self.decisionFingerprint = decisionFingerprint
        self.resolution = resolution
        self.childMutationID = childMutationID
        self.continuationMutationID = continuationMutationID
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: PlanningAnyCodingKey.self)
        try planningPublicationRequireKeys(
            container.allKeys,
            required: ["conflictID", "decisionFingerprint", "resolution"],
            field: "durableResolution"
        )
        try self.init(
            conflictID: try container.decode(UUID.self, forKey: planningCodingKey("conflictID")),
            decisionFingerprint: try container.decode(
                String.self,
                forKey: planningCodingKey("decisionFingerprint")
            ),
            resolution: try container.decode(
                PlanningConflictResolution.self,
                forKey: planningCodingKey("resolution")
            ),
            childMutationID: try container.decodeIfPresent(
                UUID.self,
                forKey: planningCodingKey("childMutationID")
            ),
            continuationMutationID: try container.decodeIfPresent(
                UUID.self,
                forKey: planningCodingKey("continuationMutationID")
            )
        )
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: PlanningAnyCodingKey.self)
        try container.encode(conflictID, forKey: planningCodingKey("conflictID"))
        try container.encode(decisionFingerprint, forKey: planningCodingKey("decisionFingerprint"))
        try container.encode(resolution, forKey: planningCodingKey("resolution"))
        try container.encodeIfPresent(childMutationID, forKey: planningCodingKey("childMutationID"))
        try container.encodeIfPresent(
            continuationMutationID,
            forKey: planningCodingKey("continuationMutationID")
        )
    }
}

/// Evidence retained when a v1 journal had a resolved conflict but no v2
/// decision record. It is deliberately not a resolution: it cannot authorize
/// publication, create a child mutation, or be replayed as a user decision.
public struct PlanningLegacyConflictInspection: Codable, Equatable, Sendable {
    public let conflictID: UUID
    public let sourceSchemaVersion: Int
    public let reason: String

    public init(
        conflictID: UUID,
        sourceSchemaVersion: Int = 1,
        reason: String = "resolvedConflictWithoutDecision"
    ) throws {
        guard sourceSchemaVersion == 1,
              reason == PlanningPublicationLimits.legacyInspectionReason else {
            throw PlanningStorageError.invalid("legacyConflictInspection.evidence")
        }
        try planningPublicationValidateString(
            reason,
            maximumBytes: PlanningPublicationLimits.maximumErrorCodeBytes,
            field: "legacyConflictInspection.reason",
            allowEmpty: false
        )
        self.conflictID = conflictID
        self.sourceSchemaVersion = sourceSchemaVersion
        self.reason = reason
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: PlanningAnyCodingKey.self)
        try planningPublicationRequireKeys(
            container.allKeys,
            required: ["conflictID", "sourceSchemaVersion", "reason"],
            field: "legacyConflictInspection"
        )
        try self.init(
            conflictID: try container.decode(UUID.self, forKey: planningCodingKey("conflictID")),
            sourceSchemaVersion: try container.decode(Int.self, forKey: planningCodingKey("sourceSchemaVersion")),
            reason: try container.decode(String.self, forKey: planningCodingKey("reason"))
        )
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: PlanningAnyCodingKey.self)
        try container.encode(conflictID, forKey: planningCodingKey("conflictID"))
        try container.encode(sourceSchemaVersion, forKey: planningCodingKey("sourceSchemaVersion"))
        try container.encode(reason, forKey: planningCodingKey("reason"))
    }
}

internal func planningPublicationDecisionFingerprint(
    conflictID: UUID,
    resolution: PlanningConflictResolution
) -> String {
    var data = Data([1])
    withUnsafeBytes(of: conflictID.uuid) { data.append(contentsOf: $0) }
    func append(_ value: String) {
        var length = UInt64(value.utf8.count).bigEndian
        withUnsafeBytes(of: &length) { data.append(contentsOf: $0) }
        data.append(contentsOf: value.utf8)
    }
    func append(_ value: Data) {
        var length = UInt64(value.count).bigEndian
        withUnsafeBytes(of: &length) { data.append(contentsOf: $0) }
        data.append(value)
    }
    switch resolution {
    case .keepObserved:
        append("keepObserved")
    case .keepBoth:
        append("keepBoth")
    case .applyLocal(let expectedObservedVersion):
        append("applyLocal")
        append(planningVersionToken(expectedObservedVersion))
    case .applyMerged(let bytes, let expectedObservedVersion):
        append("applyMerged")
        append(planningVersionToken(expectedObservedVersion))
        append(bytes)
    }
    return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
}
