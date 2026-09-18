import Foundation
import CryptoKit

public enum PlanningStorageLimits {
    public static let canvasBytes = 2 * 1024 * 1024
    public static let markdownBytes = 1 * 1024 * 1024
    public static let bookmarkBytes = 64 * 1024
    public static let pendingMutations = 1_024
    public static let pendingPayloadBytes = 64 * 1024 * 1024
    public static let cleanCacheBytes = 32 * 1024 * 1024
    public static let databaseBytes = 256 * 1024 * 1024
    public static let recoveryBatch = 32
    public static let recoveryPayloadBytes = 16 * 1024 * 1024
    public static let recoveryBudgetNanoseconds: UInt64 = 2_000_000_000
    public static let vaultMarkerBytes = 4 * 1024
    public static let maximumDigestBytes = 64
}

public enum PlanningStorageError: Error, Equatable, LocalizedError, Sendable {
    case invalid(String)
    case corruptDatabase
    case unsupportedSchema(Int)
    case database(String)
    case databaseFull
    case writerBusy
    case mutationIDReused
    case duplicateRequest
    case backpressure(String)
    case notFound
    case invalidState(String)
    case conflict
    case closed
    case unavailable(String)
    case staleAccess

    public var errorDescription: String? {
        switch self {
        case .invalid(let field): return "Invalid planning storage value: \(field)."
        case .corruptDatabase: return "The planning journal is corrupt."
        case .unsupportedSchema(let version): return "The planning journal schema is unsupported (\(version))."
        case .database(let code): return "The planning journal could not complete a database operation (\(code))."
        case .databaseFull: return "The planning journal has reached its storage limit."
        case .writerBusy: return "The planning journal is already owned by another process."
        case .mutationIDReused: return "The mutation identifier was already used for a different request."
        case .duplicateRequest: return "The same mutation request already exists under another identifier."
        case .backpressure(let reason): return "Planning storage is applying backpressure: \(reason)."
        case .notFound: return "The requested planning record was not found."
        case .invalidState(let state): return "The planning record is in an invalid state: \(state)."
        case .conflict: return "The planning operation has an unresolved conflict."
        case .closed: return "The planning journal is closed."
        case .unavailable(let reason): return "Planning storage is temporarily unavailable: \(reason)."
        case .staleAccess: return "The selected planning storage access is stale."
        }
    }
}

private func planningRequireExactKeys<K: CodingKey>(
    _ keys: [K],
    required: Set<String>,
    field: String
) throws {
    let actual = Set(keys.map(\.stringValue))
    guard actual == required else {
        throw PlanningStorageError.invalid("\(field).keys")
    }
}

private func planningRequireKeys<K: CodingKey>(
    _ keys: [K],
    required: Set<String>,
    field: String
) throws {
    let actual = Set(keys.map(\.stringValue))
    guard required.isSubset(of: actual) else {
        throw PlanningStorageError.invalid("\(field).keys")
    }
}

private func planningStorageContainer(
    _ decoder: Decoder
) throws -> KeyedDecodingContainer<PlanningAnyCodingKey> {
    try decoder.container(keyedBy: PlanningAnyCodingKey.self)
}

func planningDigestIsValid(_ digest: String) -> Bool {
    digest.utf8.count == PlanningStorageLimits.maximumDigestBytes
        && digest.unicodeScalars.allSatisfy { scalar in
            switch scalar.value {
            case 48...57, 97...102:
                return true
            default:
                return false
            }
        }
}

func planningRequiredDigest(_ data: Data) throws -> String {
    let version = PlanningContentVersion(data: data)
    try planningValidateContentVersion(version, field: "digest")
    guard case .bytes(let digest, _) = version else {
        throw PlanningStorageError.invalid("digest")
    }
    return digest
}

func planningVersionToken(_ version: PlanningContentVersion) -> String {
    switch version {
    case .absent:
        return "absent"
    case .bytes(let sha256, let byteCount):
        return "bytes:\(sha256):\(byteCount)"
    }
}

func planningValidateContentVersion(
    _ version: PlanningContentVersion,
    maximumByteCount: Int = PlanningStorageLimits.canvasBytes,
    field: String = "contentVersion"
) throws {
    guard maximumByteCount >= 0 else {
        throw PlanningStorageError.invalid(field)
    }
    switch version {
    case .absent:
        return
    case .bytes(let digest, let byteCount):
        guard planningDigestIsValid(digest),
              byteCount >= 0,
              byteCount <= maximumByteCount else {
            throw PlanningStorageError.invalid(field)
        }
    }
}

func planningVersionFromToken(_ token: String) throws -> PlanningContentVersion {
    if token == "absent" {
        return .absent
    }
    let pieces = token.split(separator: ":", omittingEmptySubsequences: false)
    guard pieces.count == 3,
          pieces[0] == "bytes",
          let byteCount = Int(pieces[2]),
          byteCount >= 0,
          planningDigestIsValid(String(pieces[1])) else {
        throw PlanningStorageError.invalid("contentVersion")
    }
    return try PlanningContentVersion(sha256: String(pieces[1]), byteCount: byteCount)
}

public struct PlanningVaultIdentity: Codable, Equatable, Hashable, Sendable {
    public let schemaVersion: Int
    public let vaultID: UUID
    public let lifeOSSubfolder: String

    public init(vaultID: UUID, lifeOSSubfolder: String = "LifeOS") throws {
        guard lifeOSSubfolder == "LifeOS" else {
            throw PlanningStorageError.invalid("vaultIdentity.lifeOSSubfolder")
        }
        self.schemaVersion = 1
        self.vaultID = vaultID
        self.lifeOSSubfolder = lifeOSSubfolder
    }

    public init(from decoder: Decoder) throws {
        let container = try planningStorageContainer(decoder)
        try planningRequireExactKeys(
            container.allKeys,
            required: ["schemaVersion", "vaultID", "lifeOSSubfolder"],
            field: "vaultIdentity"
        )
        let schemaVersion = try container.decode(Int.self, forKey: planningCodingKey("schemaVersion"))
        guard schemaVersion == 1 else {
            throw PlanningStorageError.unsupportedSchema(schemaVersion)
        }
        try self.init(
            vaultID: try container.decode(UUID.self, forKey: planningCodingKey("vaultID")),
            lifeOSSubfolder: try container.decode(String.self, forKey: planningCodingKey("lifeOSSubfolder"))
        )
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: PlanningAnyCodingKey.self)
        try container.encode(schemaVersion, forKey: planningCodingKey("schemaVersion"))
        try container.encode(vaultID, forKey: planningCodingKey("vaultID"))
        try container.encode(lifeOSSubfolder, forKey: planningCodingKey("lifeOSSubfolder"))
    }
}

public struct PlanningFileIdentity: Codable, Equatable, Hashable, Sendable {
    public let device: UInt64
    public let inode: UInt64
    public let fileType: UInt32

    public init(device: UInt64, inode: UInt64, fileType: UInt32) throws {
        guard device > 0, inode > 0 else {
            throw PlanningStorageError.invalid("fileIdentity")
        }
        self.device = device
        self.inode = inode
        self.fileType = fileType
    }

    public var storageToken: String {
        "\(device):\(inode):\(fileType)"
    }

    public init(storageToken: String) throws {
        let fields = storageToken.split(separator: ":", omittingEmptySubsequences: false)
        guard fields.count == 3,
              let device = UInt64(fields[0]),
              let inode = UInt64(fields[1]),
              let fileType = UInt32(fields[2]) else {
            throw PlanningStorageError.invalid("fileIdentity")
        }
        try self.init(device: device, inode: inode, fileType: fileType)
    }

    public init(from decoder: Decoder) throws {
        let container = try planningStorageContainer(decoder)
        try planningRequireExactKeys(
            container.allKeys,
            required: ["device", "inode", "fileType"],
            field: "fileIdentity"
        )
        try self.init(
            device: try container.decode(UInt64.self, forKey: planningCodingKey("device")),
            inode: try container.decode(UInt64.self, forKey: planningCodingKey("inode")),
            fileType: try container.decode(UInt32.self, forKey: planningCodingKey("fileType"))
        )
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: PlanningAnyCodingKey.self)
        try container.encode(device, forKey: planningCodingKey("device"))
        try container.encode(inode, forKey: planningCodingKey("inode"))
        try container.encode(fileType, forKey: planningCodingKey("fileType"))
    }
}

public struct PlanningDeviceVaultGrant: Codable, Equatable, Sendable {
    public let schemaVersion: Int
    public let deviceID: UUID
    public let vaultID: UUID
    public let bookmarkData: Data
    public let selectionGeneration: UUID
    public let lastValidatedRootIdentity: PlanningFileIdentity?

    public init(
        deviceID: UUID,
        vaultID: UUID,
        bookmarkData: Data,
        selectionGeneration: UUID,
        lastValidatedRootIdentity: PlanningFileIdentity? = nil
    ) throws {
        guard bookmarkData.count <= PlanningStorageLimits.bookmarkBytes else {
            throw PlanningStorageError.backpressure("bookmark")
        }
        self.schemaVersion = 1
        self.deviceID = deviceID
        self.vaultID = vaultID
        self.bookmarkData = bookmarkData
        self.selectionGeneration = selectionGeneration
        self.lastValidatedRootIdentity = lastValidatedRootIdentity
    }

    public init(from decoder: Decoder) throws {
        let container = try planningStorageContainer(decoder)
        try planningRequireKeys(
            container.allKeys,
            required: ["schemaVersion", "deviceID", "vaultID", "bookmarkData", "selectionGeneration"],
            field: "vaultGrant"
        )
        let version = try container.decode(Int.self, forKey: planningCodingKey("schemaVersion"))
        guard version == 1 else { throw PlanningStorageError.unsupportedSchema(version) }
        try self.init(
            deviceID: try container.decode(UUID.self, forKey: planningCodingKey("deviceID")),
            vaultID: try container.decode(UUID.self, forKey: planningCodingKey("vaultID")),
            bookmarkData: try container.decode(Data.self, forKey: planningCodingKey("bookmarkData")),
            selectionGeneration: try container.decode(UUID.self, forKey: planningCodingKey("selectionGeneration")),
            lastValidatedRootIdentity: try container.decodeIfPresent(
                PlanningFileIdentity.self,
                forKey: planningCodingKey("lastValidatedRootIdentity")
            )
        )
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: PlanningAnyCodingKey.self)
        try container.encode(schemaVersion, forKey: planningCodingKey("schemaVersion"))
        try container.encode(deviceID, forKey: planningCodingKey("deviceID"))
        try container.encode(vaultID, forKey: planningCodingKey("vaultID"))
        try container.encode(bookmarkData, forKey: planningCodingKey("bookmarkData"))
        try container.encode(selectionGeneration, forKey: planningCodingKey("selectionGeneration"))
        try container.encodeIfPresent(lastValidatedRootIdentity, forKey: planningCodingKey("lastValidatedRootIdentity"))
    }
}

public enum PlanningVaultSelectionIntent: Codable, Equatable, Sendable {
    case initialize
    case attach(expectedVaultID: UUID)

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        let value = try container.decode(String.self)
        if value == "initialize" {
            self = .initialize
            return
        }
        guard value.hasPrefix("attach:"),
              let id = UUID(uuidString: String(value.dropFirst("attach:".count))) else {
            throw PlanningStorageError.invalid("selectionIntent")
        }
        self = .attach(expectedVaultID: id)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .initialize:
            try container.encode("initialize")
        case .attach(let id):
            try container.encode("attach:\(id.uuidString.lowercased())")
        }
    }
}

public enum PlanningVaultAccessState: String, Codable, Equatable, Sendable {
    case unselected
    case ready
    case needsReselection
    case temporarilyUnavailable
    case failed
}

public struct PlanningStoredPath: Codable, Equatable, Hashable, Sendable {
    public let value: String
    public let collisionKey: String

    public init(_ rawValue: String) throws {
        let relative = try PlanningRelativePath(rawValue)
        let segments = relative.segments
        guard let last = segments.last else {
            throw PlanningStorageError.invalid("storedPath")
        }
        let lower = last.lowercased()
        guard lower.hasSuffix(".md") || lower.hasSuffix(".canvas") else {
            throw PlanningStorageError.invalid("storedPath.extension")
        }
        guard !segments.contains(where: { $0.caseInsensitiveCompare("LifeOS") == .orderedSame }) else {
            throw PlanningStorageError.invalid("storedPath.root")
        }
        guard !segments.contains(where: { segment in
            let lower = segment.lowercased()
            return lower == "conflicts"
                || lower == ".lifeos-vault.json"
                || lower.hasPrefix(".lifeos-stage-")
                || lower.hasPrefix(".lifeos-tmp-")
                || lower == "writer.lock"
                || lower == "journal.sqlite"
        }) else {
            throw PlanningStorageError.invalid("storedPath.reserved")
        }
        let collisionKey = PlanningValidation.normalizedReferencePath(relative.value)
        guard !collisionKey.isEmpty else {
            throw PlanningStorageError.invalid("storedPath.collisionKey")
        }
        self.value = relative.value
        self.collisionKey = collisionKey
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        try self.init(container.decode(String.self))
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(value)
    }

    public var isCanvas: Bool { value.lowercased().hasSuffix(".canvas") }
    public var isMarkdown: Bool { value.lowercased().hasSuffix(".md") }
}

public enum PlanningContentVersion: Codable, Equatable, Hashable, Sendable {
    case absent
    case bytes(sha256: String, byteCount: Int)

    public init(sha256: String, byteCount: Int) throws {
        let candidate = Self.bytes(sha256: sha256, byteCount: byteCount)
        try planningValidateContentVersion(candidate)
        self = candidate
    }

    public init(data: Data) {
        let digest = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        self = .bytes(sha256: digest, byteCount: data.count)
    }

    public func matches(_ data: Data) -> Bool {
        guard (try? planningValidateContentVersion(self)) != nil,
              case .bytes(_, let count) = self,
              count == data.count else { return false }
        return PlanningContentVersion(data: data) == self
    }

    public var byteCount: Int {
        switch self {
        case .absent: return 0
        case .bytes(_, let count): return count
        }
    }

    public var digest: String? {
        switch self {
        case .absent: return nil
        case .bytes(let digest, _): return digest
        }
    }

    public init(from decoder: Decoder) throws {
        let container = try planningStorageContainer(decoder)
        let kind = try container.decode(String.self, forKey: planningCodingKey("kind"))
        switch kind {
        case "absent":
            try planningRequireExactKeys(container.allKeys, required: ["kind"], field: "contentVersion")
            self = .absent
        case "bytes":
            try planningRequireExactKeys(
                container.allKeys,
                required: ["kind", "sha256", "byteCount"],
                field: "contentVersion"
            )
            try self.init(
                sha256: container.decode(String.self, forKey: planningCodingKey("sha256")),
                byteCount: container.decode(Int.self, forKey: planningCodingKey("byteCount"))
            )
        default:
            throw PlanningStorageError.invalid("contentVersion.kind")
        }
    }

    public func encode(to encoder: Encoder) throws {
        try planningValidateContentVersion(self)
        var container = encoder.container(keyedBy: PlanningAnyCodingKey.self)
        switch self {
        case .absent:
            try container.encode("absent", forKey: planningCodingKey("kind"))
        case .bytes(let digest, let count):
            try container.encode("bytes", forKey: planningCodingKey("kind"))
            try container.encode(digest, forKey: planningCodingKey("sha256"))
            try container.encode(count, forKey: planningCodingKey("byteCount"))
        }
    }
}

public struct PlanningFileObservation: Codable, Equatable, Sendable {
    public let path: PlanningStoredPath
    public let version: PlanningContentVersion
    public let identity: PlanningFileIdentity?
    public let byteCount: Int
    public let observedAt: Date

    public init(
        path: PlanningStoredPath,
        version: PlanningContentVersion,
        identity: PlanningFileIdentity?,
        byteCount: Int,
        observedAt: Date = Date()
    ) throws {
        try planningValidateContentVersion(
            version,
            maximumByteCount: path.isCanvas ? PlanningStorageLimits.canvasBytes : PlanningStorageLimits.markdownBytes,
            field: "fileObservation.version"
        )
        guard byteCount >= 0, byteCount == version.byteCount else {
            throw PlanningStorageError.invalid("fileObservation.byteCount")
        }
        self.path = path
        self.version = version
        self.identity = identity
        self.byteCount = byteCount
        self.observedAt = observedAt
    }

    public init(from decoder: Decoder) throws {
        let container = try planningStorageContainer(decoder)
        try planningRequireKeys(
            container.allKeys,
            required: ["path", "version", "byteCount", "observedAt"],
            field: "fileObservation"
        )
        try self.init(
            path: try container.decode(PlanningStoredPath.self, forKey: planningCodingKey("path")),
            version: try container.decode(PlanningContentVersion.self, forKey: planningCodingKey("version")),
            identity: try container.decodeIfPresent(
                PlanningFileIdentity.self,
                forKey: planningCodingKey("identity")
            ),
            byteCount: try container.decode(Int.self, forKey: planningCodingKey("byteCount")),
            observedAt: try container.decode(Date.self, forKey: planningCodingKey("observedAt"))
        )
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: PlanningAnyCodingKey.self)
        try container.encode(path, forKey: planningCodingKey("path"))
        try container.encode(version, forKey: planningCodingKey("version"))
        try container.encodeIfPresent(identity, forKey: planningCodingKey("identity"))
        try container.encode(byteCount, forKey: planningCodingKey("byteCount"))
        try container.encode(observedAt, forKey: planningCodingKey("observedAt"))
    }
}

public struct PlanningDocumentSnapshot: Codable, Equatable, Sendable {
    public let path: PlanningStoredPath
    public let bytes: Data
    public let version: PlanningContentVersion
    public let observation: PlanningFileObservation

    public init(
        path: PlanningStoredPath,
        bytes: Data,
        version: PlanningContentVersion? = nil,
        observation: PlanningFileObservation? = nil
    ) throws {
        let limit = path.isCanvas ? PlanningStorageLimits.canvasBytes : PlanningStorageLimits.markdownBytes
        guard bytes.count <= limit else { throw PlanningStorageError.backpressure("document") }
        let resolvedVersion = version ?? PlanningContentVersion(data: bytes)
        try planningValidateContentVersion(
            resolvedVersion,
            maximumByteCount: limit,
            field: "documentSnapshot.version"
        )
        if case .absent = resolvedVersion {
            guard bytes.isEmpty else { throw PlanningStorageError.invalid("documentSnapshot.version") }
        } else {
            guard resolvedVersion.matches(bytes) else {
                throw PlanningStorageError.invalid("documentSnapshot.digest")
            }
            try PlanningMutationRequest.validateDocumentBytes(bytes, for: path, allowEmptyMarkdown: true)
        }
        let resolvedObservation = try observation ?? PlanningFileObservation(
            path: path,
            version: resolvedVersion,
            identity: nil,
            byteCount: bytes.count
        )
        guard resolvedObservation.path == path,
              resolvedObservation.version == resolvedVersion,
              resolvedObservation.byteCount == bytes.count else {
            throw PlanningStorageError.invalid("documentSnapshot.observation")
        }
        self.path = path
        self.bytes = bytes
        self.version = resolvedVersion
        self.observation = resolvedObservation
    }

    public init(from decoder: Decoder) throws {
        let container = try planningStorageContainer(decoder)
        try planningRequireExactKeys(
            container.allKeys,
            required: ["path", "bytes", "version", "observation"],
            field: "documentSnapshot"
        )
        try self.init(
            path: try container.decode(PlanningStoredPath.self, forKey: planningCodingKey("path")),
            bytes: try container.decode(Data.self, forKey: planningCodingKey("bytes")),
            version: try container.decode(PlanningContentVersion.self, forKey: planningCodingKey("version")),
            observation: try container.decode(PlanningFileObservation.self, forKey: planningCodingKey("observation"))
        )
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: PlanningAnyCodingKey.self)
        try container.encode(path, forKey: planningCodingKey("path"))
        try container.encode(bytes, forKey: planningCodingKey("bytes"))
        try container.encode(version, forKey: planningCodingKey("version"))
        try container.encode(observation, forKey: planningCodingKey("observation"))
    }
}

public enum PlanningMutationOperation: String, Codable, Equatable, Sendable {
    case create
    case replace
    case delete
}

public struct PlanningMutationRequest: Codable, Equatable, Sendable {
    public let mutationID: UUID
    public let vaultID: UUID
    public let path: PlanningStoredPath
    public let operation: PlanningMutationOperation
    public let expectedVersion: PlanningContentVersion
    public let proposedBytes: Data?

    public init(
        mutationID: UUID = UUID(),
        vaultID: UUID,
        path: PlanningStoredPath,
        operation: PlanningMutationOperation,
        expectedVersion: PlanningContentVersion,
        proposedBytes: Data?
    ) throws {
        try planningValidateContentVersion(
            expectedVersion,
            maximumByteCount: path.isCanvas ? PlanningStorageLimits.canvasBytes : PlanningStorageLimits.markdownBytes,
            field: "mutation.expectedVersion"
        )
        switch operation {
        case .create:
            guard expectedVersion == .absent, proposedBytes != nil else {
                throw PlanningStorageError.invalid("mutation.create")
            }
            if let proposedBytes {
                try Self.validateDocumentBytes(proposedBytes, for: path, allowEmptyMarkdown: true)
            }
        case .replace:
            guard case .bytes = expectedVersion, proposedBytes != nil else {
                throw PlanningStorageError.invalid("mutation.replace")
            }
            if let proposedBytes {
                try Self.validateDocumentBytes(proposedBytes, for: path, allowEmptyMarkdown: true)
            }
        case .delete:
            guard case .bytes = expectedVersion, proposedBytes == nil else {
                throw PlanningStorageError.invalid("mutation.delete")
            }
        }
        guard path.collisionKey == PlanningValidation.normalizedReferencePath(path.value) else {
            throw PlanningStorageError.invalid("mutation.pathIdentity")
        }
        self.mutationID = mutationID
        self.vaultID = vaultID
        self.path = path
        self.operation = operation
        self.expectedVersion = expectedVersion
        self.proposedBytes = proposedBytes
    }

    static func validateDocumentBytes(
        _ data: Data,
        for path: PlanningStoredPath,
        allowEmptyMarkdown: Bool
    ) throws {
        let limit = path.isCanvas ? PlanningStorageLimits.canvasBytes : PlanningStorageLimits.markdownBytes
        guard data.count <= limit, !data.contains(0) else {
            throw PlanningStorageError.backpressure("mutationPayload")
        }
        if path.isCanvas {
            _ = try PlanningCanvasCodec.decode(data)
        } else if !data.isEmpty || !allowEmptyMarkdown {
            _ = try PlanningMarkdownCodec.decode(relativePath: path.value, data: data)
        }
    }

    static func validateConflictBytes(_ data: Data, for path: PlanningStoredPath) throws {
        try validateDocumentBytes(data, for: path, allowEmptyMarkdown: true)
    }

    static func makeForResolution(
        mutationID: UUID,
        conflict: PlanningConflict,
        expectedObservedVersion: PlanningContentVersion,
        bytes: Data?
    ) throws -> PlanningMutationRequest {
        guard expectedObservedVersion == conflict.observedVersion else {
            throw PlanningStorageError.conflict
        }
        let operation: PlanningMutationOperation
        switch (conflict.operation, expectedObservedVersion, bytes) {
        case (.delete, .bytes, nil):
            operation = .delete
        case (.create, .absent, .some), (.replace, .absent, .some):
            operation = .create
        case (.create, .bytes, .some), (.replace, .bytes, .some):
            operation = .replace
        default:
            throw PlanningStorageError.invalid("conflictResolution.operation")
        }
        return try PlanningMutationRequest(
            mutationID: mutationID,
            vaultID: conflict.vaultID,
            path: conflict.path,
            operation: operation,
            expectedVersion: expectedObservedVersion,
            proposedBytes: bytes
        )
    }

    public var fingerprint: String {
        var data = Data([1])
        data.append(contentsOf: Self.uuidBytes(vaultID))
        data.append(operation.rawValue == "create" ? 1 : operation.rawValue == "replace" ? 2 : 3)
        Self.appendLengthPrefixed(path.value, to: &data)
        Self.appendLengthPrefixed(planningVersionToken(expectedVersion), to: &data)
        if let proposedBytes {
            data.append(1)
            Self.appendLengthPrefixed(proposedBytes, to: &data)
        } else {
            data.append(0)
        }
        return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    private static func uuidBytes(_ value: UUID) -> Data {
        withUnsafeBytes(of: value.uuid) { Data($0) }
    }

    private static func appendLengthPrefixed(_ value: String, to data: inout Data) {
        appendLengthPrefixed(Data(value.utf8), to: &data)
    }

    private static func appendLengthPrefixed(_ value: Data, to data: inout Data) {
        var length = UInt64(value.count).bigEndian
        withUnsafeBytes(of: &length) { data.append(contentsOf: $0) }
        data.append(value)
    }

    public init(from decoder: Decoder) throws {
        let container = try planningStorageContainer(decoder)
        try planningRequireKeys(
            container.allKeys,
            required: ["mutationID", "vaultID", "path", "operation", "expectedVersion"],
            field: "mutationRequest"
        )
        try self.init(
            mutationID: try container.decode(UUID.self, forKey: planningCodingKey("mutationID")),
            vaultID: try container.decode(UUID.self, forKey: planningCodingKey("vaultID")),
            path: try container.decode(PlanningStoredPath.self, forKey: planningCodingKey("path")),
            operation: try container.decode(PlanningMutationOperation.self, forKey: planningCodingKey("operation")),
            expectedVersion: try container.decode(PlanningContentVersion.self, forKey: planningCodingKey("expectedVersion")),
            proposedBytes: try container.decodeIfPresent(Data.self, forKey: planningCodingKey("proposedBytes"))
        )
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: PlanningAnyCodingKey.self)
        try container.encode(mutationID, forKey: planningCodingKey("mutationID"))
        try container.encode(vaultID, forKey: planningCodingKey("vaultID"))
        try container.encode(path, forKey: planningCodingKey("path"))
        try container.encode(operation, forKey: planningCodingKey("operation"))
        try container.encode(expectedVersion, forKey: planningCodingKey("expectedVersion"))
        try container.encodeIfPresent(proposedBytes, forKey: planningCodingKey("proposedBytes"))
    }
}

public enum PlanningMutationState: String, Codable, Equatable, Sendable {
    case staged
    case prepared
    case stageReady
    case publishing
    case published
    case conflicted
    case resolved
    case cancelled
    case failed
}

public struct PlanningMutationReceipt: Codable, Equatable, Sendable {
    public let mutationID: UUID
    public let fingerprint: String
    public let state: PlanningMutationState
    public let resultVersion: PlanningContentVersion?
    public let errorCode: String?
    public let updatedAt: Date

    public init(
        mutationID: UUID,
        fingerprint: String,
        state: PlanningMutationState,
        resultVersion: PlanningContentVersion? = nil,
        errorCode: String? = nil,
        updatedAt: Date = Date()
    ) throws {
        guard planningDigestIsValid(fingerprint) else {
            throw PlanningStorageError.invalid("mutationReceipt.fingerprint")
        }
        if let resultVersion {
            try planningValidateContentVersion(resultVersion, field: "mutationReceipt.resultVersion")
        }
        self.mutationID = mutationID
        self.fingerprint = fingerprint
        self.state = state
        self.resultVersion = resultVersion
        self.errorCode = errorCode
        self.updatedAt = updatedAt
    }

    public init(from decoder: Decoder) throws {
        let container = try planningStorageContainer(decoder)
        try planningRequireKeys(
            container.allKeys,
            required: ["mutationID", "fingerprint", "state", "updatedAt"],
            field: "mutationReceipt"
        )
        try self.init(
            mutationID: try container.decode(UUID.self, forKey: planningCodingKey("mutationID")),
            fingerprint: try container.decode(String.self, forKey: planningCodingKey("fingerprint")),
            state: try container.decode(PlanningMutationState.self, forKey: planningCodingKey("state")),
            resultVersion: try container.decodeIfPresent(
                PlanningContentVersion.self,
                forKey: planningCodingKey("resultVersion")
            ),
            errorCode: try container.decodeIfPresent(String.self, forKey: planningCodingKey("errorCode")),
            updatedAt: try container.decode(Date.self, forKey: planningCodingKey("updatedAt"))
        )
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: PlanningAnyCodingKey.self)
        try container.encode(mutationID, forKey: planningCodingKey("mutationID"))
        try container.encode(fingerprint, forKey: planningCodingKey("fingerprint"))
        try container.encode(state, forKey: planningCodingKey("state"))
        try container.encodeIfPresent(resultVersion, forKey: planningCodingKey("resultVersion"))
        try container.encodeIfPresent(errorCode, forKey: planningCodingKey("errorCode"))
        try container.encode(updatedAt, forKey: planningCodingKey("updatedAt"))
    }
}

public enum PlanningConflictState: String, Codable, Equatable, Sendable {
    case open
    case resolved
}

public struct PlanningConflict: Codable, Equatable, Sendable {
    public let conflictID: UUID
    public let mutationID: UUID
    public let vaultID: UUID
    public let path: PlanningStoredPath
    public let operation: PlanningMutationOperation
    public let reason: String
    public let baseVersion: PlanningContentVersion
    public let localBytes: Data?
    public let observedVersion: PlanningContentVersion
    public let observedBytes: Data?
    public let state: PlanningConflictState

    public init(
        conflictID: UUID = UUID(),
        mutationID: UUID,
        vaultID: UUID,
        path: PlanningStoredPath,
        operation: PlanningMutationOperation,
        reason: String,
        baseVersion: PlanningContentVersion,
        localBytes: Data?,
        observedVersion: PlanningContentVersion,
        observedBytes: Data?,
        state: PlanningConflictState = .open
    ) throws {
        guard !reason.isEmpty, reason.utf8.count <= 512 else {
            throw PlanningStorageError.invalid("conflict.reason")
        }
        let maximumByteCount = path.isCanvas ? PlanningStorageLimits.canvasBytes : PlanningStorageLimits.markdownBytes
        try planningValidateContentVersion(
            baseVersion,
            maximumByteCount: maximumByteCount,
            field: "conflict.baseVersion"
        )
        try planningValidateContentVersion(
            observedVersion,
            maximumByteCount: maximumByteCount,
            field: "conflict.observedVersion"
        )
        switch (operation, baseVersion, localBytes) {
        case (.create, .absent, .some), (.replace, .bytes, .some), (.delete, .bytes, nil):
            break
        default:
            throw PlanningStorageError.invalid("conflict.operation")
        }
        if let localBytes {
            try PlanningMutationRequest.validateConflictBytes(localBytes, for: path)
        }
        if let observedBytes {
            guard observedVersion.matches(observedBytes) else {
                throw PlanningStorageError.invalid("conflict.observedDigest")
            }
        } else {
            guard observedVersion == .absent else {
                throw PlanningStorageError.invalid("conflict.observedBytes")
            }
        }
        guard path.collisionKey == PlanningValidation.normalizedReferencePath(path.value) else {
            throw PlanningStorageError.invalid("conflict.pathIdentity")
        }
        self.conflictID = conflictID
        self.mutationID = mutationID
        self.vaultID = vaultID
        self.path = path
        self.operation = operation
        self.reason = reason
        self.baseVersion = baseVersion
        self.localBytes = localBytes
        self.observedVersion = observedVersion
        self.observedBytes = observedBytes
        self.state = state
    }

    public init(from decoder: Decoder) throws {
        let container = try planningStorageContainer(decoder)
        try planningRequireKeys(
            container.allKeys,
            required: ["conflictID", "mutationID", "vaultID", "path", "operation", "reason", "baseVersion", "observedVersion", "state"],
            field: "conflict"
        )
        try self.init(
            conflictID: try container.decode(UUID.self, forKey: planningCodingKey("conflictID")),
            mutationID: try container.decode(UUID.self, forKey: planningCodingKey("mutationID")),
            vaultID: try container.decode(UUID.self, forKey: planningCodingKey("vaultID")),
            path: try container.decode(PlanningStoredPath.self, forKey: planningCodingKey("path")),
            operation: try container.decode(PlanningMutationOperation.self, forKey: planningCodingKey("operation")),
            reason: try container.decode(String.self, forKey: planningCodingKey("reason")),
            baseVersion: try container.decode(PlanningContentVersion.self, forKey: planningCodingKey("baseVersion")),
            localBytes: try container.decodeIfPresent(Data.self, forKey: planningCodingKey("localBytes")),
            observedVersion: try container.decode(PlanningContentVersion.self, forKey: planningCodingKey("observedVersion")),
            observedBytes: try container.decodeIfPresent(Data.self, forKey: planningCodingKey("observedBytes")),
            state: try container.decode(PlanningConflictState.self, forKey: planningCodingKey("state"))
        )
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: PlanningAnyCodingKey.self)
        try container.encode(conflictID, forKey: planningCodingKey("conflictID"))
        try container.encode(mutationID, forKey: planningCodingKey("mutationID"))
        try container.encode(vaultID, forKey: planningCodingKey("vaultID"))
        try container.encode(path, forKey: planningCodingKey("path"))
        try container.encode(operation, forKey: planningCodingKey("operation"))
        try container.encode(reason, forKey: planningCodingKey("reason"))
        try container.encode(baseVersion, forKey: planningCodingKey("baseVersion"))
        try container.encodeIfPresent(localBytes, forKey: planningCodingKey("localBytes"))
        try container.encode(observedVersion, forKey: planningCodingKey("observedVersion"))
        try container.encodeIfPresent(observedBytes, forKey: planningCodingKey("observedBytes"))
        try container.encode(state, forKey: planningCodingKey("state"))
    }
}

public struct PlanningConflictEvidence: Sendable, Equatable {
    public let conflict: PlanningConflict
    public let attemptedPublication: Bool
    public let displacedVersion: PlanningContentVersion?

    public init(
        conflict: PlanningConflict,
        attemptedPublication: Bool,
        displacedVersion: PlanningContentVersion? = nil
    ) {
        self.conflict = conflict
        self.attemptedPublication = attemptedPublication
        self.displacedVersion = displacedVersion
    }

    init(
        validating conflict: PlanningConflict,
        attemptedPublication: Bool,
        displacedVersion: PlanningContentVersion? = nil
    ) throws {
        if let displacedVersion {
            try planningValidateContentVersion(
                displacedVersion,
                maximumByteCount: conflict.path.isCanvas ? PlanningStorageLimits.canvasBytes : PlanningStorageLimits.markdownBytes,
                field: "conflictEvidence.displacedVersion"
            )
        }
        self.init(
            conflict: conflict,
            attemptedPublication: attemptedPublication,
            displacedVersion: displacedVersion
        )
    }
}

public enum PlanningConflictResolution: Codable, Equatable, Sendable {
    case keepObserved
    case applyLocal(expectedObservedVersion: PlanningContentVersion)
    case keepBoth
    case applyMerged(bytes: Data, expectedObservedVersion: PlanningContentVersion)

    public init(from decoder: Decoder) throws {
        let container = try planningStorageContainer(decoder)
        let kind = try container.decode(String.self, forKey: planningCodingKey("kind"))
        switch kind {
        case "keepObserved", "keepBoth":
            try planningRequireExactKeys(container.allKeys, required: ["kind"], field: "conflictResolution")
            self = kind == "keepObserved" ? .keepObserved : .keepBoth
        case "applyLocal":
            try planningRequireExactKeys(
                container.allKeys,
                required: ["kind", "expectedObservedVersion"],
                field: "conflictResolution"
            )
            self = .applyLocal(
                expectedObservedVersion: try container.decode(
                    PlanningContentVersion.self,
                    forKey: planningCodingKey("expectedObservedVersion")
                )
            )
        case "applyMerged":
            try planningRequireExactKeys(
                container.allKeys,
                required: ["kind", "expectedObservedVersion", "bytes"],
                field: "conflictResolution"
            )
            let bytes = try container.decode(Data.self, forKey: planningCodingKey("bytes"))
            guard bytes.count <= PlanningStorageLimits.canvasBytes else {
                throw PlanningStorageError.backpressure("mergedPayload")
            }
            self = .applyMerged(
                bytes: bytes,
                expectedObservedVersion: try container.decode(
                    PlanningContentVersion.self,
                    forKey: planningCodingKey("expectedObservedVersion")
                )
            )
        default:
            throw PlanningStorageError.invalid("conflictResolution.kind")
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: PlanningAnyCodingKey.self)
        switch self {
        case .keepObserved:
            try container.encode("keepObserved", forKey: planningCodingKey("kind"))
        case .applyLocal(let version):
            try container.encode("applyLocal", forKey: planningCodingKey("kind"))
            try container.encode(version, forKey: planningCodingKey("expectedObservedVersion"))
        case .keepBoth:
            try container.encode("keepBoth", forKey: planningCodingKey("kind"))
        case .applyMerged(let bytes, let version):
            try container.encode("applyMerged", forKey: planningCodingKey("kind"))
            try container.encode(bytes, forKey: planningCodingKey("bytes"))
            try container.encode(version, forKey: planningCodingKey("expectedObservedVersion"))
        }
    }
}

public enum PlanningConflictDecision: Sendable, Equatable {
    case keepObserved(conflictID: UUID)
    case applyLocal(PlanningMutationRequest)
    case keepBoth(conflictID: UUID, bytes: Data)
    case applyMerged(PlanningMutationRequest)
}

public enum PlanningPublicationOutcome: Sendable, Equatable {
    case published(PlanningContentVersion)
    case conflicted
    case failed(code: String, retryable: Bool)
}

public struct PlanningRecoveryEntry: Sendable, Equatable {
    public let mutationID: UUID
    public let state: PlanningMutationState
    public let request: PlanningMutationRequest
    public let attemptID: UUID?

    public init(
        mutationID: UUID,
        state: PlanningMutationState,
        request: PlanningMutationRequest,
        attemptID: UUID?
    ) {
        self.mutationID = mutationID
        self.state = state
        self.request = request
        self.attemptID = attemptID
    }
}

public struct PlanningConflictResolutionReceipt: Sendable, Equatable {
    public let conflictID: UUID
    public let state: PlanningConflictState
    public let newMutationReceipt: PlanningMutationReceipt?

    public init(conflictID: UUID, state: PlanningConflictState, newMutationReceipt: PlanningMutationReceipt?) {
        self.conflictID = conflictID
        self.state = state
        self.newMutationReceipt = newMutationReceipt
    }
}

public struct PlanningStoreStatus: Codable, Equatable, Sendable {
    public let accessState: PlanningVaultAccessState
    public let pendingMutationCount: Int
    public let openConflictCount: Int
    public let retainedPayloadBytes: Int
    public let databaseBytes: Int
    public let lastErrorCode: String?

    public init(
        accessState: PlanningVaultAccessState,
        pendingMutationCount: Int,
        openConflictCount: Int,
        retainedPayloadBytes: Int,
        databaseBytes: Int,
        lastErrorCode: String? = nil
    ) throws {
        guard pendingMutationCount >= 0,
              openConflictCount >= 0,
              retainedPayloadBytes >= 0,
              databaseBytes >= 0 else {
            throw PlanningStorageError.invalid("storeStatus")
        }
        self.accessState = accessState
        self.pendingMutationCount = pendingMutationCount
        self.openConflictCount = openConflictCount
        self.retainedPayloadBytes = retainedPayloadBytes
        self.databaseBytes = databaseBytes
        self.lastErrorCode = lastErrorCode
    }

    public init(from decoder: Decoder) throws {
        let container = try planningStorageContainer(decoder)
        try planningRequireKeys(
            container.allKeys,
            required: ["accessState", "pendingMutationCount", "openConflictCount", "retainedPayloadBytes", "databaseBytes"],
            field: "storeStatus"
        )
        try self.init(
            accessState: try container.decode(PlanningVaultAccessState.self, forKey: planningCodingKey("accessState")),
            pendingMutationCount: try container.decode(Int.self, forKey: planningCodingKey("pendingMutationCount")),
            openConflictCount: try container.decode(Int.self, forKey: planningCodingKey("openConflictCount")),
            retainedPayloadBytes: try container.decode(Int.self, forKey: planningCodingKey("retainedPayloadBytes")),
            databaseBytes: try container.decode(Int.self, forKey: planningCodingKey("databaseBytes")),
            lastErrorCode: try container.decodeIfPresent(String.self, forKey: planningCodingKey("lastErrorCode"))
        )
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: PlanningAnyCodingKey.self)
        try container.encode(accessState, forKey: planningCodingKey("accessState"))
        try container.encode(pendingMutationCount, forKey: planningCodingKey("pendingMutationCount"))
        try container.encode(openConflictCount, forKey: planningCodingKey("openConflictCount"))
        try container.encode(retainedPayloadBytes, forKey: planningCodingKey("retainedPayloadBytes"))
        try container.encode(databaseBytes, forKey: planningCodingKey("databaseBytes"))
        try container.encodeIfPresent(lastErrorCode, forKey: planningCodingKey("lastErrorCode"))
    }
}
