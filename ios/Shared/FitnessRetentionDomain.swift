import Foundation

// MARK: - Fitness retention contract

/// Fitness retention is a contract and planning boundary only. It never opens
/// a store, removes an asset, or claims that a planned removal happened.
public enum FitnessRetentionValidationError: Error, Equatable, Sendable {
    case invalid(String)
    case unsupportedSchemaVersion(Int)
    case unsafeIdentifier(String)
    case duplicateIdentifier(String)
    case danglingLink(String)
    case contradictoryState(String)
    case invalidTimestamp(String)
    case invalidBounds(String)
    case staleRevision
}

private struct FitnessAnyCodingKey: CodingKey {
    let stringValue: String
    let intValue: Int? = nil

    init?(stringValue: String) { self.stringValue = stringValue }
    init?(intValue: Int) { return nil }
}

private func rejectUnknownFitnessKeys(_ decoder: Decoder, allowed: Set<String>) throws {
    let container = try decoder.container(keyedBy: FitnessAnyCodingKey.self)
    let received = Set(container.allKeys.map(\.stringValue))
    guard received.isSubset(of: allowed) else {
        throw DecodingError.dataCorrupted(
            .init(codingPath: decoder.codingPath,
                  debugDescription: "Unknown Fitness retention field")
        )
    }
}

private func decodeFitnessOptional<T: Decodable, Key: CodingKey>(
    _ type: T.Type,
    forKey key: Key,
    from container: KeyedDecodingContainer<Key>
) throws -> T? {
    guard container.contains(key) else { return nil }
    guard try !container.decodeNil(forKey: key) else {
        throw DecodingError.valueNotFound(
            type,
            .init(codingPath: container.codingPath + [key],
                  debugDescription: "Explicit null is not accepted")
        )
    }
    return try container.decode(type, forKey: key)
}

private enum FitnessValidation {
    static let maximumClockSkew: TimeInterval = 5
    static let maximumRevision = 9_007_199_254_740_991
    static let maximumIDLength = 128
    static let maximumStorageBytes = 1_024 * 1_024 * 1_024 * 1_024
    static let maximumPhotoBytesPerRequest = 20 * 1_024 * 1_024
    static let maximumMeasurements = 32
    static let maximumAssets = 100_000
    static let maximumRecords = 100_000
    static let maximumRollups = 100_000
    static let maximumAuditRecords = 300_000
    static let maximumSourceAssetsPerRollup = 100_000
    static let maximumMetricValue = 1_000_000_000_000.0
    static let targetDerivativeBytes = 500 * 1_024
    static let day: TimeInterval = 24 * 60 * 60
    static let maximumBreakdownBytes = maximumStorageBytes * maximumMeasurements

    static func fail(_ message: String) -> FitnessRetentionValidationError {
        .invalid(message)
    }

    static func validateID(_ value: String, field: String = "id") throws {
        let bytes = Array(value.utf8)
        guard (1...maximumIDLength).contains(bytes.count),
              let first = bytes.first,
              isASCIILetterOrDigit(first),
              bytes.dropFirst().allSatisfy({ isASCIILetterOrDigit($0) || $0 == 45 || $0 == 95 }) else {
            throw FitnessRetentionValidationError.unsafeIdentifier(field)
        }
    }

    private static func isASCIILetterOrDigit(_ byte: UInt8) -> Bool {
        (48...57).contains(byte) || (65...90).contains(byte) || (97...122).contains(byte)
    }

    static func validateRevision(_ value: Int, field: String = "revision") throws {
        guard (0...maximumRevision).contains(value) else {
            throw FitnessRetentionValidationError.invalidBounds(field)
        }
    }

    static func validateBytes(_ value: Int, field: String = "bytes", maximum: Int = maximumStorageBytes) throws {
        guard (0...maximum).contains(value) else {
            throw FitnessRetentionValidationError.invalidBounds(field)
        }
    }

    static func validatePositiveBytes(_ value: Int, field: String = "bytes") throws {
        guard (1...maximumStorageBytes).contains(value) else {
            throw FitnessRetentionValidationError.invalidBounds(field)
        }
    }

    static func validateMetric(_ value: Double, field: String = "metric") throws {
        guard value.isFinite, (-maximumMetricValue...maximumMetricValue).contains(value) else {
            throw FitnessRetentionValidationError.invalidBounds(field)
        }
    }

    static func validateObserved(_ value: Date, field: String, now: Date) throws {
        guard value.timeIntervalSinceReferenceDate.isFinite,
              now.timeIntervalSinceReferenceDate.isFinite,
              value <= now.addingTimeInterval(maximumClockSkew) else {
            throw FitnessRetentionValidationError.invalidTimestamp(field)
        }
    }

    static func validateTimestamp(_ value: Date, field: String) throws {
        guard value.timeIntervalSinceReferenceDate.isFinite else {
            throw FitnessRetentionValidationError.invalidTimestamp(field)
        }
    }

    static func parseTimestamp(_ raw: String, field: String = "timestamp") throws -> Date {
        // Zod's datetime({ offset: true }) requires an explicit timezone and
        // bounds the original wire string to 40 characters.
        guard raw.utf16.count <= 40,
              raw.range(of: #"^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}(?::\d{2}(?:\.\d+)?)?(?:Z|[+-]\d{2}:?\d{2})$"#,
                        options: .regularExpression) != nil else {
            throw FitnessRetentionValidationError.invalidTimestamp(field)
        }
        let body: String
        let zone: String
        if raw.hasSuffix("Z") {
            body = String(raw.dropLast())
            zone = "Z"
        } else if raw.count >= 6 && raw[raw.index(raw.endIndex, offsetBy: -3)] == ":" {
            body = String(raw.dropLast(6))
            zone = String(raw.suffix(6))
        } else {
            body = String(raw.dropLast(5))
            let rawZone = String(raw.suffix(5))
            zone = String(rawZone.prefix(3)) + ":" + rawZone.suffix(2)
        }
        let time = body.split(separator: "T", maxSplits: 1, omittingEmptySubsequences: false).last!
        let normalized = (time.utf8.count == 5 ? body + ":00" : body) + zone
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let standard = ISO8601DateFormatter()
        standard.formatOptions = [.withInternetDateTime]
        guard let date = fractional.date(from: normalized) ?? standard.date(from: normalized),
              date.timeIntervalSinceReferenceDate.isFinite else {
            throw FitnessRetentionValidationError.invalidTimestamp(field)
        }
        return date
    }

    static func decodeTimestamp<Key: CodingKey>(
        forKey key: Key,
        from container: KeyedDecodingContainer<Key>,
        field: String
    ) throws -> Date {
        try parseTimestamp(container.decode(String.self, forKey: key), field: field)
    }

    static func decodeOptionalTimestamp<Key: CodingKey>(
        forKey key: Key,
        from container: KeyedDecodingContainer<Key>,
        field: String
    ) throws -> Date? {
        guard container.contains(key) else { return nil }
        guard try !container.decodeNil(forKey: key) else {
            throw DecodingError.valueNotFound(
                Date.self,
                .init(codingPath: container.codingPath + [key],
                      debugDescription: "Explicit null is not accepted")
            )
        }
        return try decodeTimestamp(forKey: key, from: container, field: field)
    }

    static func encodeTimestamp<Key: CodingKey>(
        _ date: Date,
        forKey key: Key,
        into container: inout KeyedEncodingContainer<Key>
    ) throws {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        try container.encode(formatter.string(from: date), forKey: key)
    }

    static func validateUniqueIDs(_ values: [String], maximum: Int, field: String) throws {
        guard values.count <= maximum else {
            throw FitnessRetentionValidationError.invalidBounds(field)
        }
        var seen = Set<String>()
        for value in values {
            try validateID(value, field: field)
            guard seen.insert(value).inserted else {
                throw FitnessRetentionValidationError.duplicateIdentifier(value)
            }
        }
    }

    static func validateText(_ value: String, maximum: Int, field: String) throws {
        guard !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              value.utf16.count <= maximum else {
            throw FitnessRetentionValidationError.invalid(field)
        }
    }

    static func now(from decoder: Decoder) -> Date {
        decoder.userInfo[.lifeOSNow] as? Date ?? .now
    }
}

public struct FitnessRetentionConstants: Sendable {
    public static let maximumClockSkewMs = 5_000
    public static let maximumRevision = 9_007_199_254_740_991
    public static let maximumStorageBytes = FitnessValidation.maximumStorageBytes
    public static let maximumPhotoBytesPerRequest = FitnessValidation.maximumPhotoBytesPerRequest
    public static let targetDerivativeBytes = FitnessValidation.targetDerivativeBytes

    private init() {}
}

public struct FitnessStorageLimits: Equatable, Sendable {
    public static let warningBytes = 8 * 1_024 * 1_024 * 1_024
    public static let aggressiveCompactionBytes = 9 * 1_024 * 1_024 * 1_024
    public static let hardCapBytes = 10 * 1_024 * 1_024 * 1_024
    public static let targetDerivativeBytes = FitnessValidation.targetDerivativeBytes
    public static let originalRetentionDays = 90
    public static let detailedHistoryRetentionDays = 365

    private init() {}
}

public typealias FitnessRetentionID = String
public typealias StorageClass = FitnessStorageClass

public enum FitnessStorageClass: String, Codable, CaseIterable, Equatable, Sendable {
    case originals
    case sanitizedImages = "sanitized_images"
    case derivatives
    case structuredRecords = "structured_records"
    case detailedHistory = "detailed_history"
    case databasePages = "database_pages"
    case indexes
    case writeAheadLogs = "write_ahead_logs"
    case temporaryFiles = "temporary_files"
    case thumbnails
    case caches
    case diagnosticMetadata = "diagnostic_metadata"
    case rollingBackups = "rolling_backups"
}

public struct FitnessStorageMeasurement: Codable, Equatable, Sendable {
    public let id: String
    public let storageClass: FitnessStorageClass
    public let bytes: Int
    public let measuredAt: Date
    public let revision: Int

    private enum CodingKeys: String, CodingKey { case id, storageClass, bytes, measuredAt, revision }

    public init(id: String, storageClass: FitnessStorageClass, bytes: Int,
                measuredAt: Date, revision: Int) throws {
        self.id = id
        self.storageClass = storageClass
        self.bytes = bytes
        self.measuredAt = measuredAt
        self.revision = revision
        try validate(now: .now)
    }

    public init(from decoder: Decoder) throws {
        try rejectUnknownFitnessKeys(decoder, allowed: [
            "id", "storageClass", "bytes", "measuredAt", "revision"
        ])
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        storageClass = try c.decode(FitnessStorageClass.self, forKey: .storageClass)
        bytes = try c.decode(Int.self, forKey: .bytes)
        measuredAt = try FitnessValidation.decodeTimestamp(forKey: .measuredAt, from: c, field: "measuredAt")
        revision = try c.decode(Int.self, forKey: .revision)
        try validate(now: FitnessValidation.now(from: decoder))
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(storageClass, forKey: .storageClass)
        try c.encode(bytes, forKey: .bytes)
        try FitnessValidation.encodeTimestamp(measuredAt, forKey: .measuredAt, into: &c)
        try c.encode(revision, forKey: .revision)
    }

    public func validate(now: Date = .now) throws {
        try FitnessValidation.validateID(id)
        try FitnessValidation.validateBytes(bytes)
        try FitnessValidation.validateObserved(measuredAt, field: "measuredAt", now: now)
        try FitnessValidation.validateRevision(revision)
    }
}

public struct FitnessStorageBreakdown: Codable, Equatable, Sendable {
    public let measuredAt: Date
    public let revision: Int
    public let measurements: [FitnessStorageMeasurement]
    public let totalBytes: Int

    private enum CodingKeys: String, CodingKey { case measuredAt, revision, measurements, totalBytes }

    public init(measuredAt: Date, revision: Int, measurements: [FitnessStorageMeasurement],
                totalBytes: Int) throws {
        self.measuredAt = measuredAt
        self.revision = revision
        self.measurements = measurements
        self.totalBytes = totalBytes
        try validate(now: .now)
    }

    public init(from decoder: Decoder) throws {
        try rejectUnknownFitnessKeys(decoder, allowed: ["measuredAt", "revision", "measurements", "totalBytes"])
        let c = try decoder.container(keyedBy: CodingKeys.self)
        measuredAt = try FitnessValidation.decodeTimestamp(forKey: .measuredAt, from: c, field: "measuredAt")
        revision = try c.decode(Int.self, forKey: .revision)
        measurements = try c.decode([FitnessStorageMeasurement].self, forKey: .measurements)
        totalBytes = try c.decode(Int.self, forKey: .totalBytes)
        try validate(now: FitnessValidation.now(from: decoder))
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try FitnessValidation.encodeTimestamp(measuredAt, forKey: .measuredAt, into: &c)
        try c.encode(revision, forKey: .revision)
        try c.encode(measurements, forKey: .measurements)
        try c.encode(totalBytes, forKey: .totalBytes)
    }

    public func validate(now: Date = .now) throws {
        try FitnessValidation.validateObserved(measuredAt, field: "measuredAt", now: now)
        try FitnessValidation.validateRevision(revision)
        guard (1...FitnessValidation.maximumMeasurements).contains(measurements.count) else {
            throw FitnessRetentionValidationError.invalidBounds("measurements")
        }
        try measurements.forEach { try $0.validate(now: now) }
        var ids = Set<String>()
        var classes = Set<FitnessStorageClass>()
        for measurement in measurements {
            guard ids.insert(measurement.id).inserted else {
                throw FitnessRetentionValidationError.duplicateIdentifier(measurement.id)
            }
            guard classes.insert(measurement.storageClass).inserted else {
                throw FitnessRetentionValidationError.duplicateIdentifier(measurement.storageClass.rawValue)
            }
        }
        try FitnessValidation.validateBytes(totalBytes, field: "totalBytes",
                                            maximum: FitnessValidation.maximumBreakdownBytes)
        let sum = measurements.reduce(0) { $0 + $1.bytes }
        guard sum == totalBytes else {
            throw FitnessRetentionValidationError.contradictoryState("storage total must equal class breakdown")
        }
    }
}

public struct FitnessRetentionPolicy: Codable, Equatable, Sendable {
    public let schemaVersion: Int
    public let originalRetentionDays: Int
    public let detailedHistoryRetentionDays: Int
    public let allowOriginalCompaction: Bool
    public let allowDetailedHistoryCompaction: Bool

    private enum CodingKeys: String, CodingKey {
        case schemaVersion, originalRetentionDays, detailedHistoryRetentionDays,
             allowOriginalCompaction, allowDetailedHistoryCompaction
    }

    public init(allowOriginalCompaction: Bool, allowDetailedHistoryCompaction: Bool) {
        schemaVersion = 1
        originalRetentionDays = 90
        detailedHistoryRetentionDays = 365
        self.allowOriginalCompaction = allowOriginalCompaction
        self.allowDetailedHistoryCompaction = allowDetailedHistoryCompaction
    }

    public init(schemaVersion: Int = 1, originalRetentionDays: Int = 90,
                detailedHistoryRetentionDays: Int = 365,
                allowOriginalCompaction: Bool,
                allowDetailedHistoryCompaction: Bool) throws {
        self.schemaVersion = schemaVersion
        self.originalRetentionDays = originalRetentionDays
        self.detailedHistoryRetentionDays = detailedHistoryRetentionDays
        self.allowOriginalCompaction = allowOriginalCompaction
        self.allowDetailedHistoryCompaction = allowDetailedHistoryCompaction
        try validate()
    }

    public init(from decoder: Decoder) throws {
        try rejectUnknownFitnessKeys(decoder, allowed: [
            "schemaVersion", "originalRetentionDays", "detailedHistoryRetentionDays",
            "allowOriginalCompaction", "allowDetailedHistoryCompaction"
        ])
        let c = try decoder.container(keyedBy: CodingKeys.self)
        schemaVersion = try c.decode(Int.self, forKey: .schemaVersion)
        originalRetentionDays = try c.decode(Int.self, forKey: .originalRetentionDays)
        detailedHistoryRetentionDays = try c.decode(Int.self, forKey: .detailedHistoryRetentionDays)
        allowOriginalCompaction = try c.decode(Bool.self, forKey: .allowOriginalCompaction)
        allowDetailedHistoryCompaction = try c.decode(Bool.self, forKey: .allowDetailedHistoryCompaction)
        try validate()
    }

    public func validate() throws {
        guard schemaVersion == 1 else {
            throw FitnessRetentionValidationError.unsupportedSchemaVersion(schemaVersion)
        }
        guard originalRetentionDays == 90, detailedHistoryRetentionDays == 365 else {
            throw FitnessRetentionValidationError.invalidBounds("retentionPolicy")
        }
    }
}

public enum FitnessPreservedRecordKind: String, Codable, CaseIterable, Equatable, Sendable {
    case confirmedMeal = "confirmed_meal"
    case correctionLineage = "correction_lineage"
    case inferenceProvenance = "inference_provenance"
}

public struct FitnessPreservedRecord: Codable, Equatable, Sendable {
    public let id: String
    public let kind: FitnessPreservedRecordKind
    public let revision: Int
    public let updatedAt: Date
    public let auditRecordID: String

    private enum CodingKeys: String, CodingKey { case id, kind, revision, updatedAt, auditRecordID }

    public init(id: String, kind: FitnessPreservedRecordKind, revision: Int,
                updatedAt: Date, auditRecordID: String) throws {
        self.id = id
        self.kind = kind
        self.revision = revision
        self.updatedAt = updatedAt
        self.auditRecordID = auditRecordID
        try validate(now: .now)
    }

    public init(from decoder: Decoder) throws {
        try rejectUnknownFitnessKeys(decoder, allowed: ["id", "kind", "revision", "updatedAt", "auditRecordID"])
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        kind = try c.decode(FitnessPreservedRecordKind.self, forKey: .kind)
        revision = try c.decode(Int.self, forKey: .revision)
        updatedAt = try FitnessValidation.decodeTimestamp(forKey: .updatedAt, from: c, field: "updatedAt")
        auditRecordID = try c.decode(String.self, forKey: .auditRecordID)
        try validate(now: FitnessValidation.now(from: decoder))
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(kind, forKey: .kind)
        try c.encode(revision, forKey: .revision)
        try FitnessValidation.encodeTimestamp(updatedAt, forKey: .updatedAt, into: &c)
        try c.encode(auditRecordID, forKey: .auditRecordID)
    }

    public func validate(now: Date = .now) throws {
        try FitnessValidation.validateID(id)
        try FitnessValidation.validateRevision(revision)
        try FitnessValidation.validateObserved(updatedAt, field: "updatedAt", now: now)
        try FitnessValidation.validateID(auditRecordID, field: "auditRecordID")
    }
}

public enum FitnessRetentionAssetKind: String, Codable, CaseIterable, Equatable, Sendable {
    case originalPhoto = "original_photo"
    case detailedHistory = "detailed_history"
}

public struct FitnessRetentionAsset: Codable, Equatable, Sendable {
    public let id: String
    public let kind: FitnessRetentionAssetKind
    public let storageClass: FitnessStorageClass
    public let bytes: Int
    public let observedAt: Date
    public let revision: Int
    public let updatedAt: Date
    public let pinned: Bool
    public let exported: Bool
    public let structuredRecordID: String?
    public let correctionLineageID: String?
    public let provenanceID: String?
    public let dailyRollupID: String?
    public let weeklyRollupID: String?
    public let auditRecordID: String

    private enum CodingKeys: String, CodingKey {
        case id, kind, storageClass, bytes, observedAt, revision, updatedAt, pinned, exported,
             structuredRecordID, correctionLineageID, provenanceID, dailyRollupID, weeklyRollupID,
             auditRecordID
    }

    public init(id: String, kind: FitnessRetentionAssetKind, storageClass: FitnessStorageClass,
                bytes: Int, observedAt: Date, revision: Int, updatedAt: Date,
                pinned: Bool, exported: Bool, structuredRecordID: String? = nil,
                correctionLineageID: String? = nil, provenanceID: String? = nil,
                dailyRollupID: String? = nil, weeklyRollupID: String? = nil,
                auditRecordID: String) throws {
        self.id = id
        self.kind = kind
        self.storageClass = storageClass
        self.bytes = bytes
        self.observedAt = observedAt
        self.revision = revision
        self.updatedAt = updatedAt
        self.pinned = pinned
        self.exported = exported
        self.structuredRecordID = structuredRecordID
        self.correctionLineageID = correctionLineageID
        self.provenanceID = provenanceID
        self.dailyRollupID = dailyRollupID
        self.weeklyRollupID = weeklyRollupID
        self.auditRecordID = auditRecordID
        try validate(now: .now)
    }

    public init(from decoder: Decoder) throws {
        try rejectUnknownFitnessKeys(decoder, allowed: [
            "id", "kind", "storageClass", "bytes", "observedAt", "revision", "updatedAt",
            "pinned", "exported", "structuredRecordID", "correctionLineageID", "provenanceID",
            "dailyRollupID", "weeklyRollupID", "auditRecordID"
        ])
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        kind = try c.decode(FitnessRetentionAssetKind.self, forKey: .kind)
        storageClass = try c.decode(FitnessStorageClass.self, forKey: .storageClass)
        bytes = try c.decode(Int.self, forKey: .bytes)
        observedAt = try FitnessValidation.decodeTimestamp(forKey: .observedAt, from: c, field: "observedAt")
        revision = try c.decode(Int.self, forKey: .revision)
        updatedAt = try FitnessValidation.decodeTimestamp(forKey: .updatedAt, from: c, field: "updatedAt")
        pinned = try c.decode(Bool.self, forKey: .pinned)
        exported = try c.decode(Bool.self, forKey: .exported)
        structuredRecordID = try decodeFitnessOptional(String.self, forKey: .structuredRecordID, from: c)
        correctionLineageID = try decodeFitnessOptional(String.self, forKey: .correctionLineageID, from: c)
        provenanceID = try decodeFitnessOptional(String.self, forKey: .provenanceID, from: c)
        dailyRollupID = try decodeFitnessOptional(String.self, forKey: .dailyRollupID, from: c)
        weeklyRollupID = try decodeFitnessOptional(String.self, forKey: .weeklyRollupID, from: c)
        auditRecordID = try c.decode(String.self, forKey: .auditRecordID)
        try validate(now: FitnessValidation.now(from: decoder))
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(kind, forKey: .kind)
        try c.encode(storageClass, forKey: .storageClass)
        try c.encode(bytes, forKey: .bytes)
        try FitnessValidation.encodeTimestamp(observedAt, forKey: .observedAt, into: &c)
        try c.encode(revision, forKey: .revision)
        try FitnessValidation.encodeTimestamp(updatedAt, forKey: .updatedAt, into: &c)
        try c.encode(pinned, forKey: .pinned)
        try c.encode(exported, forKey: .exported)
        try c.encodeIfPresent(structuredRecordID, forKey: .structuredRecordID)
        try c.encodeIfPresent(correctionLineageID, forKey: .correctionLineageID)
        try c.encodeIfPresent(provenanceID, forKey: .provenanceID)
        try c.encodeIfPresent(dailyRollupID, forKey: .dailyRollupID)
        try c.encodeIfPresent(weeklyRollupID, forKey: .weeklyRollupID)
        try c.encode(auditRecordID, forKey: .auditRecordID)
    }

    public func validate(now: Date = .now) throws {
        try FitnessValidation.validateID(id)
        try FitnessValidation.validatePositiveBytes(bytes)
        try FitnessValidation.validateObserved(observedAt, field: "observedAt", now: now)
        try FitnessValidation.validateRevision(revision)
        try FitnessValidation.validateObserved(updatedAt, field: "updatedAt", now: now)
        try FitnessValidation.validateID(auditRecordID, field: "auditRecordID")
        for (value, field) in [
            (structuredRecordID, "structuredRecordID"), (correctionLineageID, "correctionLineageID"),
            (provenanceID, "provenanceID"), (dailyRollupID, "dailyRollupID"),
            (weeklyRollupID, "weeklyRollupID")
        ] {
            if let value { try FitnessValidation.validateID(value, field: field) }
        }
        switch kind {
        case .originalPhoto:
            guard storageClass == .originals else {
                throw FitnessRetentionValidationError.contradictoryState("original photos require originals storage class")
            }
            guard structuredRecordID != nil, correctionLineageID != nil, provenanceID != nil else {
                throw FitnessRetentionValidationError.danglingLink("original photo preserved record")
            }
            guard dailyRollupID == nil, weeklyRollupID == nil else {
                throw FitnessRetentionValidationError.contradictoryState("original photo cannot link sensor rollups")
            }
        case .detailedHistory:
            guard storageClass == .detailedHistory else {
                throw FitnessRetentionValidationError.contradictoryState("detailed history requires detailed_history storage class")
            }
            guard dailyRollupID != nil, weeklyRollupID != nil else {
                throw FitnessRetentionValidationError.danglingLink("detailed history rollup")
            }
            guard structuredRecordID == nil, correctionLineageID == nil else {
                throw FitnessRetentionValidationError.contradictoryState("detailed history cannot link meal correction records")
            }
        }
    }
}

public enum FitnessRollupGranularity: String, Codable, CaseIterable, Equatable, Sendable {
    case daily
    case weekly
}

public enum FitnessRollupSourceCoverage: String, Codable, CaseIterable, Equatable, Sendable {
    case complete
    case partial
}

public enum FitnessRollupQuality: String, Codable, CaseIterable, Equatable, Sendable {
    case observed
    case estimated
    case partial
    case unavailable
}

public struct FitnessRollup: Codable, Equatable, Sendable {
    public let id: String
    public let granularity: FitnessRollupGranularity
    public let periodStart: Date
    public let periodEnd: Date
    public let sourceAssetIDs: [String]
    public let min: Double
    public let max: Double
    public let mean: Double
    public let sampleCount: Int
    public let sourceCoverage: FitnessRollupSourceCoverage
    public let quality: FitnessRollupQuality
    public let pinnedRawIntervalIDs: [String]
    public let auditRecordID: String
    public let revision: Int
    public let updatedAt: Date

    private enum CodingKeys: String, CodingKey {
        case id, granularity, periodStart, periodEnd, sourceAssetIDs, min, max, mean,
             sampleCount, sourceCoverage, quality, pinnedRawIntervalIDs, auditRecordID,
             revision, updatedAt
    }

    public init(id: String, granularity: FitnessRollupGranularity, periodStart: Date,
                periodEnd: Date, sourceAssetIDs: [String], min: Double, max: Double,
                mean: Double, sampleCount: Int, sourceCoverage: FitnessRollupSourceCoverage,
                quality: FitnessRollupQuality, pinnedRawIntervalIDs: [String],
                auditRecordID: String, revision: Int, updatedAt: Date) throws {
        self.id = id
        self.granularity = granularity
        self.periodStart = periodStart
        self.periodEnd = periodEnd
        self.sourceAssetIDs = sourceAssetIDs
        self.min = min
        self.max = max
        self.mean = mean
        self.sampleCount = sampleCount
        self.sourceCoverage = sourceCoverage
        self.quality = quality
        self.pinnedRawIntervalIDs = pinnedRawIntervalIDs
        self.auditRecordID = auditRecordID
        self.revision = revision
        self.updatedAt = updatedAt
        try validate(now: .now)
    }

    public init(from decoder: Decoder) throws {
        try rejectUnknownFitnessKeys(decoder, allowed: [
            "id", "granularity", "periodStart", "periodEnd", "sourceAssetIDs", "min", "max",
            "mean", "sampleCount", "sourceCoverage", "quality", "pinnedRawIntervalIDs",
            "auditRecordID", "revision", "updatedAt"
        ])
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        granularity = try c.decode(FitnessRollupGranularity.self, forKey: .granularity)
        periodStart = try FitnessValidation.decodeTimestamp(forKey: .periodStart, from: c, field: "periodStart")
        periodEnd = try FitnessValidation.decodeTimestamp(forKey: .periodEnd, from: c, field: "periodEnd")
        sourceAssetIDs = try c.decode([String].self, forKey: .sourceAssetIDs)
        min = try c.decode(Double.self, forKey: .min)
        max = try c.decode(Double.self, forKey: .max)
        mean = try c.decode(Double.self, forKey: .mean)
        sampleCount = try c.decode(Int.self, forKey: .sampleCount)
        sourceCoverage = try c.decode(FitnessRollupSourceCoverage.self, forKey: .sourceCoverage)
        quality = try c.decode(FitnessRollupQuality.self, forKey: .quality)
        pinnedRawIntervalIDs = try c.decode([String].self, forKey: .pinnedRawIntervalIDs)
        auditRecordID = try c.decode(String.self, forKey: .auditRecordID)
        revision = try c.decode(Int.self, forKey: .revision)
        updatedAt = try FitnessValidation.decodeTimestamp(forKey: .updatedAt, from: c, field: "updatedAt")
        try validate(now: FitnessValidation.now(from: decoder))
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(granularity, forKey: .granularity)
        try FitnessValidation.encodeTimestamp(periodStart, forKey: .periodStart, into: &c)
        try FitnessValidation.encodeTimestamp(periodEnd, forKey: .periodEnd, into: &c)
        try c.encode(sourceAssetIDs, forKey: .sourceAssetIDs)
        try c.encode(min, forKey: .min)
        try c.encode(max, forKey: .max)
        try c.encode(mean, forKey: .mean)
        try c.encode(sampleCount, forKey: .sampleCount)
        try c.encode(sourceCoverage, forKey: .sourceCoverage)
        try c.encode(quality, forKey: .quality)
        try c.encode(pinnedRawIntervalIDs, forKey: .pinnedRawIntervalIDs)
        try c.encode(auditRecordID, forKey: .auditRecordID)
        try c.encode(revision, forKey: .revision)
        try FitnessValidation.encodeTimestamp(updatedAt, forKey: .updatedAt, into: &c)
    }

    public func validate(now: Date = .now) throws {
        try FitnessValidation.validateID(id)
        try FitnessValidation.validateObserved(periodStart, field: "periodStart", now: now)
        try FitnessValidation.validateObserved(periodEnd, field: "periodEnd", now: now)
        guard periodEnd > periodStart else {
            throw FitnessRetentionValidationError.contradictoryState("rollup period must end after it starts")
        }
        try FitnessValidation.validateUniqueIDs(sourceAssetIDs,
                                                maximum: FitnessValidation.maximumSourceAssetsPerRollup,
                                                field: "sourceAssetIDs")
        guard !sourceAssetIDs.isEmpty else {
            throw FitnessRetentionValidationError.invalidBounds("sourceAssetIDs")
        }
        try FitnessValidation.validateMetric(min, field: "min")
        try FitnessValidation.validateMetric(max, field: "max")
        try FitnessValidation.validateMetric(mean, field: "mean")
        guard sampleCount > 0, sampleCount <= 100_000_000 else {
            throw FitnessRetentionValidationError.invalidBounds("sampleCount")
        }
        try FitnessValidation.validateUniqueIDs(pinnedRawIntervalIDs,
                                                maximum: FitnessValidation.maximumSourceAssetsPerRollup,
                                                field: "pinnedRawIntervalIDs")
        try FitnessValidation.validateID(auditRecordID, field: "auditRecordID")
        try FitnessValidation.validateRevision(revision)
        try FitnessValidation.validateObserved(updatedAt, field: "updatedAt", now: now)
        guard min <= max else {
            throw FitnessRetentionValidationError.contradictoryState("rollup maximum must be at least minimum")
        }
        guard mean >= min, mean <= max else {
            throw FitnessRetentionValidationError.contradictoryState("rollup mean must be within min/max")
        }
        guard !(sourceCoverage == .complete && quality == .unavailable) else {
            throw FitnessRetentionValidationError.contradictoryState("unavailable rollup cannot claim complete coverage")
        }
    }
}

public enum FitnessAuditEntityKind: String, Codable, CaseIterable, Equatable, Sendable {
    case asset
    case rollup
    case record
}

public enum FitnessAuditState: String, Codable, CaseIterable, Equatable, Sendable {
    case active
    case preserved
    case exported
    case compactionPending = "compaction_pending"
    case compacted
    case restored
    case deletedTombstone = "deleted_tombstone"
}

public struct FitnessAuditRecord: Codable, Equatable, Sendable {
    public let id: String
    public let entityKind: FitnessAuditEntityKind
    public let entityID: String
    public let state: FitnessAuditState
    public let revision: Int
    public let recordedAt: Date

    private enum CodingKeys: String, CodingKey { case id, entityKind, entityID, state, revision, recordedAt }

    public init(id: String, entityKind: FitnessAuditEntityKind, entityID: String,
                state: FitnessAuditState, revision: Int, recordedAt: Date) throws {
        self.id = id
        self.entityKind = entityKind
        self.entityID = entityID
        self.state = state
        self.revision = revision
        self.recordedAt = recordedAt
        try validate(now: .now)
    }

    public init(from decoder: Decoder) throws {
        try rejectUnknownFitnessKeys(decoder, allowed: ["id", "entityKind", "entityID", "state", "revision", "recordedAt"])
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        entityKind = try c.decode(FitnessAuditEntityKind.self, forKey: .entityKind)
        entityID = try c.decode(String.self, forKey: .entityID)
        state = try c.decode(FitnessAuditState.self, forKey: .state)
        revision = try c.decode(Int.self, forKey: .revision)
        recordedAt = try FitnessValidation.decodeTimestamp(forKey: .recordedAt, from: c, field: "recordedAt")
        try validate(now: FitnessValidation.now(from: decoder))
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(entityKind, forKey: .entityKind)
        try c.encode(entityID, forKey: .entityID)
        try c.encode(state, forKey: .state)
        try c.encode(revision, forKey: .revision)
        try FitnessValidation.encodeTimestamp(recordedAt, forKey: .recordedAt, into: &c)
    }

    public func validate(now: Date = .now) throws {
        try FitnessValidation.validateID(id)
        try FitnessValidation.validateID(entityID, field: "entityID")
        try FitnessValidation.validateRevision(revision)
        try FitnessValidation.validateObserved(recordedAt, field: "recordedAt", now: now)
    }
}

public struct FitnessRetentionSnapshot: Codable, Equatable, Sendable {
    public let schemaVersion: Int
    public let revision: Int
    public let observedAt: Date
    public let storage: FitnessStorageBreakdown
    public let retentionPolicy: FitnessRetentionPolicy
    public let assets: [FitnessRetentionAsset]
    public let records: [FitnessPreservedRecord]
    public let rollups: [FitnessRollup]
    public let auditRecords: [FitnessAuditRecord]

    private enum CodingKeys: String, CodingKey {
        case schemaVersion, revision, observedAt, storage, retentionPolicy, assets, records, rollups, auditRecords
    }

    public init(schemaVersion: Int = 1, revision: Int, observedAt: Date,
                storage: FitnessStorageBreakdown, retentionPolicy: FitnessRetentionPolicy,
                assets: [FitnessRetentionAsset], records: [FitnessPreservedRecord],
                rollups: [FitnessRollup], auditRecords: [FitnessAuditRecord]) throws {
        self.schemaVersion = schemaVersion
        self.revision = revision
        self.observedAt = observedAt
        self.storage = storage
        self.retentionPolicy = retentionPolicy
        self.assets = assets
        self.records = records
        self.rollups = rollups
        self.auditRecords = auditRecords
        try validate(now: .now)
    }

    public init(from decoder: Decoder) throws {
        try rejectUnknownFitnessKeys(decoder, allowed: [
            "schemaVersion", "revision", "observedAt", "storage", "retentionPolicy",
            "assets", "records", "rollups", "auditRecords"
        ])
        let c = try decoder.container(keyedBy: CodingKeys.self)
        schemaVersion = try c.decode(Int.self, forKey: .schemaVersion)
        revision = try c.decode(Int.self, forKey: .revision)
        observedAt = try FitnessValidation.decodeTimestamp(forKey: .observedAt, from: c, field: "observedAt")
        storage = try c.decode(FitnessStorageBreakdown.self, forKey: .storage)
        retentionPolicy = try c.decode(FitnessRetentionPolicy.self, forKey: .retentionPolicy)
        assets = try c.decode([FitnessRetentionAsset].self, forKey: .assets)
        records = try c.decode([FitnessPreservedRecord].self, forKey: .records)
        rollups = try c.decode([FitnessRollup].self, forKey: .rollups)
        auditRecords = try c.decode([FitnessAuditRecord].self, forKey: .auditRecords)
        try validate(now: FitnessValidation.now(from: decoder))
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(schemaVersion, forKey: .schemaVersion)
        try c.encode(revision, forKey: .revision)
        try FitnessValidation.encodeTimestamp(observedAt, forKey: .observedAt, into: &c)
        try c.encode(storage, forKey: .storage)
        try c.encode(retentionPolicy, forKey: .retentionPolicy)
        try c.encode(assets, forKey: .assets)
        try c.encode(records, forKey: .records)
        try c.encode(rollups, forKey: .rollups)
        try c.encode(auditRecords, forKey: .auditRecords)
    }

    public static func decode(_ data: Data, now: Date = .now) throws -> Self {
        let decoder = JSONDecoder()
        decoder.userInfo[.lifeOSNow] = now
        return try decoder.decode(Self.self, from: data)
    }

    public func validate(now: Date = .now) throws {
        guard schemaVersion == 1 else {
            throw FitnessRetentionValidationError.unsupportedSchemaVersion(schemaVersion)
        }
        try FitnessValidation.validateRevision(revision)
        try FitnessValidation.validateObserved(observedAt, field: "observedAt", now: now)
        try storage.validate(now: now)
        try retentionPolicy.validate()
        guard assets.count <= FitnessValidation.maximumAssets,
              records.count <= FitnessValidation.maximumRecords,
              rollups.count <= FitnessValidation.maximumRollups,
              auditRecords.count <= FitnessValidation.maximumAuditRecords else {
            throw FitnessRetentionValidationError.invalidBounds("snapshot arrays")
        }
        try assets.forEach { try $0.validate(now: now) }
        try records.forEach { try $0.validate(now: now) }
        try rollups.forEach { try $0.validate(now: now) }
        try auditRecords.forEach { try $0.validate(now: now) }

        var assetIDs = Set<String>()
        var recordIDs = Set<String>()
        var rollupIDs = Set<String>()
        var auditIDs = Set<String>()
        for asset in assets { guard assetIDs.insert(asset.id).inserted else { throw FitnessRetentionValidationError.duplicateIdentifier(asset.id) } }
        for record in records { guard recordIDs.insert(record.id).inserted else { throw FitnessRetentionValidationError.duplicateIdentifier(record.id) } }
        for rollup in rollups { guard rollupIDs.insert(rollup.id).inserted else { throw FitnessRetentionValidationError.duplicateIdentifier(rollup.id) } }
        for audit in auditRecords { guard auditIDs.insert(audit.id).inserted else { throw FitnessRetentionValidationError.duplicateIdentifier(audit.id) } }

        let measuredClasses = Set(storage.measurements.map(\.storageClass))
        guard assets.allSatisfy({ measuredClasses.contains($0.storageClass) }) else {
            throw FitnessRetentionValidationError.danglingLink("asset storage class measurement")
        }
        func ensureNotAfterSnapshot(_ date: Date, _ field: String) throws {
            guard date <= observedAt.addingTimeInterval(FitnessValidation.maximumClockSkew) else {
                throw FitnessRetentionValidationError.invalidTimestamp("\(field) postdates snapshot")
            }
        }
        try ensureNotAfterSnapshot(storage.measuredAt, "storage.measuredAt")
        for (index, measurement) in storage.measurements.enumerated() {
            try ensureNotAfterSnapshot(measurement.measuredAt, "storage.measurements[\(index)].measuredAt")
        }
        for (index, asset) in assets.enumerated() {
            try ensureNotAfterSnapshot(asset.observedAt, "assets[\(index)].observedAt")
            try ensureNotAfterSnapshot(asset.updatedAt, "assets[\(index)].updatedAt")
        }
        for (index, record) in records.enumerated() {
            try ensureNotAfterSnapshot(record.updatedAt, "records[\(index)].updatedAt")
        }
        for (index, rollup) in rollups.enumerated() {
            try ensureNotAfterSnapshot(rollup.periodStart, "rollups[\(index)].periodStart")
            try ensureNotAfterSnapshot(rollup.periodEnd, "rollups[\(index)].periodEnd")
            try ensureNotAfterSnapshot(rollup.updatedAt, "rollups[\(index)].updatedAt")
        }
        for (index, audit) in auditRecords.enumerated() {
            try ensureNotAfterSnapshot(audit.recordedAt, "auditRecords[\(index)].recordedAt")
        }

        let recordsByID = Dictionary(uniqueKeysWithValues: records.map { ($0.id, $0) })
        let assetsByID = Dictionary(uniqueKeysWithValues: assets.map { ($0.id, $0) })
        let rollupsByID = Dictionary(uniqueKeysWithValues: rollups.map { ($0.id, $0) })
        let auditsByID = Dictionary(uniqueKeysWithValues: auditRecords.map { ($0.id, $0) })
        func requireRecord(_ id: String?, kind: FitnessPreservedRecordKind) throws {
            guard let id else { return }
            guard let record = recordsByID[id] else { throw FitnessRetentionValidationError.danglingLink("preserved record \(id)") }
            guard record.kind == kind else { throw FitnessRetentionValidationError.contradictoryState("preserved record kind") }
        }
        func requireAudit(_ id: String, entityKind: FitnessAuditEntityKind, entityID: String) throws -> FitnessAuditRecord {
            guard let audit = auditsByID[id] else { throw FitnessRetentionValidationError.danglingLink("audit record \(id)") }
            guard audit.entityKind == entityKind, audit.entityID == entityID else {
                throw FitnessRetentionValidationError.contradictoryState("audit record target")
            }
            return audit
        }
        for record in records {
            let audit = try requireAudit(record.auditRecordID, entityKind: .record, entityID: record.id)
            guard audit.state != .deletedTombstone else {
                throw FitnessRetentionValidationError.contradictoryState("present record has deletion tombstone")
            }
        }
        for asset in assets {
            let audit = try requireAudit(asset.auditRecordID, entityKind: .asset, entityID: asset.id)
            guard audit.state != .compacted, audit.state != .deletedTombstone else {
                throw FitnessRetentionValidationError.contradictoryState("present asset is compacted or tombstoned")
            }
            if audit.state == .compactionPending {
                guard !asset.pinned, !asset.exported else {
                    throw FitnessRetentionValidationError.contradictoryState("protected asset is compaction-pending")
                }
            }
            if audit.state == .exported && !asset.exported {
                throw FitnessRetentionValidationError.contradictoryState("exported audit state requires exported asset state")
            }
            switch asset.kind {
            case .originalPhoto:
                try requireRecord(asset.structuredRecordID, kind: .confirmedMeal)
                try requireRecord(asset.correctionLineageID, kind: .correctionLineage)
                try requireRecord(asset.provenanceID, kind: .inferenceProvenance)
            case .detailedHistory:
                guard let dailyID = asset.dailyRollupID, let weeklyID = asset.weeklyRollupID,
                      let daily = rollupsByID[dailyID], let weekly = rollupsByID[weeklyID] else {
                    throw FitnessRetentionValidationError.danglingLink("asset rollup")
                }
                guard daily.granularity == .daily, daily.sourceAssetIDs.contains(asset.id),
                      weekly.granularity == .weekly, weekly.sourceAssetIDs.contains(asset.id) else {
                    throw FitnessRetentionValidationError.contradictoryState("asset rollup link")
                }
            }
        }
        for rollup in rollups {
            let audit = try requireAudit(rollup.auditRecordID, entityKind: .rollup, entityID: rollup.id)
            guard audit.state != .deletedTombstone else {
                throw FitnessRetentionValidationError.contradictoryState("present rollup has deletion tombstone")
            }
            for sourceID in rollup.sourceAssetIDs {
                guard let source = assetsByID[sourceID], source.kind == .detailedHistory else {
                    throw FitnessRetentionValidationError.danglingLink("rollup source \(sourceID)")
                }
                let backlink = rollup.granularity == .daily ? source.dailyRollupID : source.weeklyRollupID
                guard backlink == rollup.id else {
                    throw FitnessRetentionValidationError.contradictoryState("rollup source backlink")
                }
            }
            for pinnedID in rollup.pinnedRawIntervalIDs {
                guard let source = assetsByID[pinnedID], source.kind == .detailedHistory,
                      source.pinned, rollup.sourceAssetIDs.contains(pinnedID) else {
                    throw FitnessRetentionValidationError.contradictoryState("pinned raw interval link")
                }
            }
        }
        for audit in auditRecords {
            let exists: Bool
            switch audit.entityKind {
            case .asset: exists = assetIDs.contains(audit.entityID)
            case .rollup: exists = rollupIDs.contains(audit.entityID)
            case .record: exists = recordIDs.contains(audit.entityID)
            }
            guard exists || audit.state == .deletedTombstone else {
                throw FitnessRetentionValidationError.danglingLink("audit entity \(audit.entityID)")
            }
        }
    }
}

public struct FitnessCompactionRequest: Codable, Equatable, Sendable {
    public let snapshot: FitnessRetentionSnapshot
    public let planID: String
    public let requestedPhotoBytes: Int?

    public var schemaVersion: Int { snapshot.schemaVersion }
    public var revision: Int { snapshot.revision }
    public var observedAt: Date { snapshot.observedAt }
    public var storage: FitnessStorageBreakdown { snapshot.storage }
    public var retentionPolicy: FitnessRetentionPolicy { snapshot.retentionPolicy }
    public var assets: [FitnessRetentionAsset] { snapshot.assets }
    public var records: [FitnessPreservedRecord] { snapshot.records }
    public var rollups: [FitnessRollup] { snapshot.rollups }
    public var auditRecords: [FitnessAuditRecord] { snapshot.auditRecords }

    private enum CodingKeys: String, CodingKey {
        case schemaVersion, revision, observedAt, storage, retentionPolicy, assets, records,
             rollups, auditRecords, planID, requestedPhotoBytes
    }

    public init(planID: String, revision: Int, observedAt: Date,
                storage: FitnessStorageBreakdown, retentionPolicy: FitnessRetentionPolicy,
                assets: [FitnessRetentionAsset], records: [FitnessPreservedRecord],
                rollups: [FitnessRollup], auditRecords: [FitnessAuditRecord],
                requestedPhotoBytes: Int? = nil, schemaVersion: Int = 1) throws {
        let snapshot = try FitnessRetentionSnapshot(schemaVersion: schemaVersion, revision: revision,
                                                    observedAt: observedAt, storage: storage,
                                                    retentionPolicy: retentionPolicy, assets: assets,
                                                    records: records, rollups: rollups,
                                                    auditRecords: auditRecords)
        self.snapshot = snapshot
        self.planID = planID
        self.requestedPhotoBytes = requestedPhotoBytes
        try validate(now: .now)
    }

    public init(snapshot: FitnessRetentionSnapshot, planID: String,
                requestedPhotoBytes: Int? = nil) throws {
        self.snapshot = snapshot
        self.planID = planID
        self.requestedPhotoBytes = requestedPhotoBytes
        try validate(now: .now)
    }

    public init(from decoder: Decoder) throws {
        try rejectUnknownFitnessKeys(decoder, allowed: [
            "schemaVersion", "revision", "observedAt", "storage", "retentionPolicy",
            "assets", "records", "rollups", "auditRecords", "planID", "requestedPhotoBytes"
        ])
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let schemaVersion = try c.decode(Int.self, forKey: .schemaVersion)
        let revision = try c.decode(Int.self, forKey: .revision)
        let observedAt = try FitnessValidation.decodeTimestamp(forKey: .observedAt, from: c, field: "observedAt")
        let storage = try c.decode(FitnessStorageBreakdown.self, forKey: .storage)
        let retentionPolicy = try c.decode(FitnessRetentionPolicy.self, forKey: .retentionPolicy)
        let assets = try c.decode([FitnessRetentionAsset].self, forKey: .assets)
        let records = try c.decode([FitnessPreservedRecord].self, forKey: .records)
        let rollups = try c.decode([FitnessRollup].self, forKey: .rollups)
        let auditRecords = try c.decode([FitnessAuditRecord].self, forKey: .auditRecords)
        self.snapshot = try FitnessRetentionSnapshot(
            schemaVersion: schemaVersion, revision: revision, observedAt: observedAt,
            storage: storage, retentionPolicy: retentionPolicy, assets: assets,
            records: records, rollups: rollups, auditRecords: auditRecords
        )
        planID = try c.decode(String.self, forKey: .planID)
        requestedPhotoBytes = try decodeFitnessOptional(Int.self, forKey: .requestedPhotoBytes, from: c)
        try validate(now: FitnessValidation.now(from: decoder))
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(snapshot.schemaVersion, forKey: .schemaVersion)
        try c.encode(snapshot.revision, forKey: .revision)
        try FitnessValidation.encodeTimestamp(snapshot.observedAt, forKey: .observedAt, into: &c)
        try c.encode(snapshot.storage, forKey: .storage)
        try c.encode(snapshot.retentionPolicy, forKey: .retentionPolicy)
        try c.encode(snapshot.assets, forKey: .assets)
        try c.encode(snapshot.records, forKey: .records)
        try c.encode(snapshot.rollups, forKey: .rollups)
        try c.encode(snapshot.auditRecords, forKey: .auditRecords)
        try c.encode(planID, forKey: .planID)
        try c.encodeIfPresent(requestedPhotoBytes, forKey: .requestedPhotoBytes)
    }

    public static func decode(_ data: Data, now: Date = .now) throws -> Self {
        let decoder = JSONDecoder()
        decoder.userInfo[.lifeOSNow] = now
        return try decoder.decode(Self.self, from: data)
    }

    public func validate(now: Date = .now) throws {
        try snapshot.validate(now: now)
        try FitnessValidation.validateID(planID, field: "planID")
        if let requestedPhotoBytes {
            try FitnessValidation.validateBytes(requestedPhotoBytes, field: "requestedPhotoBytes",
                                                maximum: FitnessValidation.maximumPhotoBytesPerRequest)
        }
    }
}

public enum FitnessStoragePressure: String, Codable, CaseIterable, Equatable, Sendable {
    case normal
    case warning
    case aggressiveCompaction = "aggressive_compaction"
    case hardIngestionGate = "hard_ingestion_gate"
}

public enum FitnessIngestionMode: String, Codable, CaseIterable, Equatable, Sendable {
    case persistentPhotoAllowed = "persistent_photo_allowed"
    case structuredOnlyTransientPhoto = "structured_only_transient_photo"
    case manualOnlyNoPhotoRetention = "manual_only_no_photo_retention"
}

public enum FitnessCompactionEligibility: String, Codable, CaseIterable, Equatable, Sendable {
    case originalOlderThan90Days = "original_older_than_90_days"
    case historyOlderThan365Days = "history_older_than_365_days"
}

public enum FitnessCompactionStep: String, Codable, CaseIterable, Equatable, Sendable {
    case writeReplacement = "write_replacement"
    case validateReplacement = "validate_replacement"
    case verifyExportAndProvenance = "verify_export_and_provenance"
    case removeSourceAfterCommit = "remove_source_after_commit"
}

public struct FitnessPreservationSet: Codable, Equatable, Sendable {
    public var structuredRecordIDs: [String]
    public var correctionLineageIDs: [String]
    public var provenanceIDs: [String]
    public var dailyRollupIDs: [String]
    public var weeklyRollupIDs: [String]
    public var auditRecordIDs: [String]

    private enum CodingKeys: String, CodingKey {
        case structuredRecordIDs, correctionLineageIDs, provenanceIDs, dailyRollupIDs,
             weeklyRollupIDs, auditRecordIDs
    }

    public init(structuredRecordIDs: [String] = [], correctionLineageIDs: [String] = [],
                provenanceIDs: [String] = [], dailyRollupIDs: [String] = [],
                weeklyRollupIDs: [String] = [], auditRecordIDs: [String] = []) throws {
        self.structuredRecordIDs = structuredRecordIDs
        self.correctionLineageIDs = correctionLineageIDs
        self.provenanceIDs = provenanceIDs
        self.dailyRollupIDs = dailyRollupIDs
        self.weeklyRollupIDs = weeklyRollupIDs
        self.auditRecordIDs = auditRecordIDs
        try validate()
    }

    public init(from decoder: Decoder) throws {
        try rejectUnknownFitnessKeys(decoder, allowed: [
            "structuredRecordIDs", "correctionLineageIDs", "provenanceIDs", "dailyRollupIDs",
            "weeklyRollupIDs", "auditRecordIDs"
        ])
        let c = try decoder.container(keyedBy: CodingKeys.self)
        structuredRecordIDs = try c.decode([String].self, forKey: .structuredRecordIDs)
        correctionLineageIDs = try c.decode([String].self, forKey: .correctionLineageIDs)
        provenanceIDs = try c.decode([String].self, forKey: .provenanceIDs)
        dailyRollupIDs = try c.decode([String].self, forKey: .dailyRollupIDs)
        weeklyRollupIDs = try c.decode([String].self, forKey: .weeklyRollupIDs)
        auditRecordIDs = try c.decode([String].self, forKey: .auditRecordIDs)
        try validate()
    }

    public func validate() throws {
        try FitnessValidation.validateUniqueIDs(structuredRecordIDs,
                                                maximum: FitnessValidation.maximumRecords,
                                                field: "structuredRecordIDs")
        try FitnessValidation.validateUniqueIDs(correctionLineageIDs,
                                                maximum: FitnessValidation.maximumRecords,
                                                field: "correctionLineageIDs")
        try FitnessValidation.validateUniqueIDs(provenanceIDs,
                                                maximum: FitnessValidation.maximumRecords,
                                                field: "provenanceIDs")
        try FitnessValidation.validateUniqueIDs(dailyRollupIDs,
                                                maximum: FitnessValidation.maximumRollups,
                                                field: "dailyRollupIDs")
        try FitnessValidation.validateUniqueIDs(weeklyRollupIDs,
                                                maximum: FitnessValidation.maximumRollups,
                                                field: "weeklyRollupIDs")
        try FitnessValidation.validateUniqueIDs(auditRecordIDs,
                                                maximum: FitnessValidation.maximumAuditRecords,
                                                field: "auditRecordIDs")
        let all = structuredRecordIDs + correctionLineageIDs + provenanceIDs
            + dailyRollupIDs + weeklyRollupIDs + auditRecordIDs
        guard Set(all).count == all.count else {
            throw FitnessRetentionValidationError.duplicateIdentifier("preservation link")
        }
    }

    public static let empty = try! FitnessPreservationSet()
}

public struct FitnessCompactionSourceRemoval: Codable, Equatable, Sendable {
    public let action: String
    public let requiresExplicitPolicy: Bool
    public let auditEventID: String

    private enum CodingKeys: String, CodingKey { case action, requiresExplicitPolicy, auditEventID }

    public init(auditEventID: String) throws {
        action = "remove_source_after_validated_commit"
        requiresExplicitPolicy = true
        self.auditEventID = auditEventID
        try validate()
    }

    public init(from decoder: Decoder) throws {
        try rejectUnknownFitnessKeys(decoder, allowed: ["action", "requiresExplicitPolicy", "auditEventID"])
        let c = try decoder.container(keyedBy: CodingKeys.self)
        action = try c.decode(String.self, forKey: .action)
        requiresExplicitPolicy = try c.decode(Bool.self, forKey: .requiresExplicitPolicy)
        auditEventID = try c.decode(String.self, forKey: .auditEventID)
        try validate()
    }

    public func validate() throws {
        guard action == "remove_source_after_validated_commit", requiresExplicitPolicy else {
            throw FitnessRetentionValidationError.contradictoryState("source removal semantics")
        }
        try FitnessValidation.validateID(auditEventID, field: "auditEventID")
    }
}

/// Target fields are optional only because the TypeScript discriminated union
/// carries a different target object for each operation kind. Validation makes
/// the required/forbidden fields exact for the selected operation kind.
public struct FitnessCompactionTarget: Codable, Equatable, Sendable {
    public let thumbnailID: String?
    public let maximumThumbnailBytes: Int?
    public let dailyRollupID: String?
    public let weeklyRollupID: String?

    private enum CodingKeys: String, CodingKey {
        case thumbnailID, maximumThumbnailBytes, dailyRollupID, weeklyRollupID
    }

    public init(thumbnailID: String, maximumThumbnailBytes: Int) throws {
        self.thumbnailID = thumbnailID
        self.maximumThumbnailBytes = maximumThumbnailBytes
        dailyRollupID = nil
        weeklyRollupID = nil
        try validate(kind: .originalPhoto)
    }

    public init(dailyRollupID: String, weeklyRollupID: String) throws {
        thumbnailID = nil
        maximumThumbnailBytes = nil
        self.dailyRollupID = dailyRollupID
        self.weeklyRollupID = weeklyRollupID
        try validate(kind: .detailedHistory)
    }

    private init(thumbnailID: String?, maximumThumbnailBytes: Int?,
                 dailyRollupID: String?, weeklyRollupID: String?) {
        self.thumbnailID = thumbnailID
        self.maximumThumbnailBytes = maximumThumbnailBytes
        self.dailyRollupID = dailyRollupID
        self.weeklyRollupID = weeklyRollupID
    }

    public init(from decoder: Decoder) throws {
        try rejectUnknownFitnessKeys(decoder, allowed: [
            "thumbnailID", "maximumThumbnailBytes", "dailyRollupID", "weeklyRollupID"
        ])
        let c = try decoder.container(keyedBy: CodingKeys.self)
        thumbnailID = try decodeFitnessOptional(String.self, forKey: .thumbnailID, from: c)
        maximumThumbnailBytes = try decodeFitnessOptional(Int.self, forKey: .maximumThumbnailBytes, from: c)
        dailyRollupID = try decodeFitnessOptional(String.self, forKey: .dailyRollupID, from: c)
        weeklyRollupID = try decodeFitnessOptional(String.self, forKey: .weeklyRollupID, from: c)
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encodeIfPresent(thumbnailID, forKey: .thumbnailID)
        try c.encodeIfPresent(maximumThumbnailBytes, forKey: .maximumThumbnailBytes)
        try c.encodeIfPresent(dailyRollupID, forKey: .dailyRollupID)
        try c.encodeIfPresent(weeklyRollupID, forKey: .weeklyRollupID)
    }

    fileprivate func validate(kind: FitnessRetentionAssetKind) throws {
        switch kind {
        case .originalPhoto:
            guard let thumbnailID, let maximumThumbnailBytes,
                  dailyRollupID == nil, weeklyRollupID == nil,
                  maximumThumbnailBytes == FitnessValidation.targetDerivativeBytes else {
                throw FitnessRetentionValidationError.contradictoryState("original compaction target")
            }
            try FitnessValidation.validateID(thumbnailID, field: "thumbnailID")
        case .detailedHistory:
            guard let dailyRollupID, let weeklyRollupID,
                  thumbnailID == nil, maximumThumbnailBytes == nil else {
                throw FitnessRetentionValidationError.contradictoryState("history compaction target")
            }
            try FitnessValidation.validateID(dailyRollupID, field: "dailyRollupID")
            try FitnessValidation.validateID(weeklyRollupID, field: "weeklyRollupID")
        }
    }
}

public struct FitnessCompactionOperation: Codable, Equatable, Sendable {
    public let operationID: String
    public let sourceAssetID: String
    public let sourceBytes: Int
    public let reclaimableBytes: Int
    public let eligibility: FitnessCompactionEligibility
    public let transactionSteps: [FitnessCompactionStep]
    public let sourceDisposition: String
    public let sourceRemoval: FitnessCompactionSourceRemoval
    public let kind: FitnessRetentionAssetKind
    public let target: FitnessCompactionTarget
    public let preserve: FitnessPreservationSet

    private enum CodingKeys: String, CodingKey {
        case operationID, sourceAssetID, sourceBytes, reclaimableBytes, eligibility,
             transactionSteps, sourceDisposition, sourceRemoval, kind, target, preserve
    }

    public init(operationID: String, sourceAssetID: String, sourceBytes: Int,
                reclaimableBytes: Int, eligibility: FitnessCompactionEligibility,
                transactionSteps: [FitnessCompactionStep] = [
                    .writeReplacement, .validateReplacement,
                    .verifyExportAndProvenance, .removeSourceAfterCommit
                ],
                sourceDisposition: String = "retain_until_commit",
                sourceRemoval: FitnessCompactionSourceRemoval, kind: FitnessRetentionAssetKind,
                target: FitnessCompactionTarget, preserve: FitnessPreservationSet) throws {
        self.operationID = operationID
        self.sourceAssetID = sourceAssetID
        self.sourceBytes = sourceBytes
        self.reclaimableBytes = reclaimableBytes
        self.eligibility = eligibility
        self.transactionSteps = transactionSteps
        self.sourceDisposition = sourceDisposition
        self.sourceRemoval = sourceRemoval
        self.kind = kind
        self.target = target
        self.preserve = preserve
        try validate()
    }

    public init(from decoder: Decoder) throws {
        try rejectUnknownFitnessKeys(decoder, allowed: [
            "operationID", "sourceAssetID", "sourceBytes", "reclaimableBytes", "eligibility",
            "transactionSteps", "sourceDisposition", "sourceRemoval", "kind", "target", "preserve"
        ])
        let c = try decoder.container(keyedBy: CodingKeys.self)
        operationID = try c.decode(String.self, forKey: .operationID)
        sourceAssetID = try c.decode(String.self, forKey: .sourceAssetID)
        sourceBytes = try c.decode(Int.self, forKey: .sourceBytes)
        reclaimableBytes = try c.decode(Int.self, forKey: .reclaimableBytes)
        eligibility = try c.decode(FitnessCompactionEligibility.self, forKey: .eligibility)
        transactionSteps = try c.decode([FitnessCompactionStep].self, forKey: .transactionSteps)
        sourceDisposition = try c.decode(String.self, forKey: .sourceDisposition)
        sourceRemoval = try c.decode(FitnessCompactionSourceRemoval.self, forKey: .sourceRemoval)
        kind = try c.decode(FitnessRetentionAssetKind.self, forKey: .kind)
        target = try c.decode(FitnessCompactionTarget.self, forKey: .target)
        preserve = try c.decode(FitnessPreservationSet.self, forKey: .preserve)
        try validate()
    }

    public func validate() throws {
        try FitnessValidation.validateID(operationID, field: "operationID")
        try FitnessValidation.validateID(sourceAssetID, field: "sourceAssetID")
        try FitnessValidation.validateBytes(sourceBytes, field: "sourceBytes")
        try FitnessValidation.validateBytes(reclaimableBytes, field: "reclaimableBytes")
        guard reclaimableBytes <= sourceBytes else {
            throw FitnessRetentionValidationError.invalidBounds("reclaimableBytes")
        }
        guard transactionSteps == [
            .writeReplacement, .validateReplacement,
            .verifyExportAndProvenance, .removeSourceAfterCommit
        ] else {
            throw FitnessRetentionValidationError.contradictoryState("transaction steps")
        }
        guard sourceDisposition == "retain_until_commit" else {
            throw FitnessRetentionValidationError.contradictoryState("source disposition")
        }
        try sourceRemoval.validate()
        try target.validate(kind: kind)
        try preserve.validate()
        switch kind {
        case .originalPhoto:
            guard eligibility == .originalOlderThan90Days else {
                throw FitnessRetentionValidationError.contradictoryState("original eligibility")
            }
        case .detailedHistory:
            guard eligibility == .historyOlderThan365Days else {
                throw FitnessRetentionValidationError.contradictoryState("history eligibility")
            }
        }
    }
}

public enum FitnessCompactionStatus: String, Codable, CaseIterable, Equatable, Sendable {
    case planned
    case staging
    case validated
    case committed
    case failed
}

public struct FitnessCompactionPlan: Codable, Equatable, Sendable {
    public let schemaVersion: Int
    public let planID: String
    public let baseRevision: Int
    public let revision: Int
    public let createdAt: Date
    public let updatedAt: Date
    public let asOf: Date
    public let storagePressure: FitnessStoragePressure
    public let ingestionMode: FitnessIngestionMode
    public let requestedPhotoBytes: Int
    public let measuredTotalBytes: Int
    public let projectedTotalBytes: Int
    public let operations: [FitnessCompactionOperation]
    public let estimatedReclaimableBytes: Int
    public let protectedBytes: Int
    public let preserve: FitnessPreservationSet
    public let execution: String
    public let status: FitnessCompactionStatus
    public let stagedAt: Date?
    public let validatedAt: Date?
    public let validatedOperationIDs: [String]?
    public let exportVerifiedOperationIDs: [String]?
    public let committedAt: Date?
    public let failedAt: Date?
    public let failureReason: String?

    private enum CodingKeys: String, CodingKey {
        case schemaVersion, planID, baseRevision, revision, createdAt, updatedAt, asOf,
             storagePressure, ingestionMode, requestedPhotoBytes, measuredTotalBytes,
             projectedTotalBytes, operations, estimatedReclaimableBytes, protectedBytes,
             preserve, execution, status, stagedAt, validatedAt, validatedOperationIDs,
             exportVerifiedOperationIDs, committedAt, failedAt, failureReason
    }

    public init(schemaVersion: Int = 1, planID: String, baseRevision: Int, revision: Int,
                createdAt: Date, updatedAt: Date, asOf: Date,
                storagePressure: FitnessStoragePressure, ingestionMode: FitnessIngestionMode,
                requestedPhotoBytes: Int, measuredTotalBytes: Int, projectedTotalBytes: Int,
                operations: [FitnessCompactionOperation], estimatedReclaimableBytes: Int,
                protectedBytes: Int, preserve: FitnessPreservationSet,
                execution: String = "plan_only_no_deletion", status: FitnessCompactionStatus = .planned,
                stagedAt: Date? = nil, validatedAt: Date? = nil,
                validatedOperationIDs: [String]? = nil, exportVerifiedOperationIDs: [String]? = nil,
                committedAt: Date? = nil, failedAt: Date? = nil, failureReason: String? = nil) throws {
        self.schemaVersion = schemaVersion
        self.planID = planID
        self.baseRevision = baseRevision
        self.revision = revision
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.asOf = asOf
        self.storagePressure = storagePressure
        self.ingestionMode = ingestionMode
        self.requestedPhotoBytes = requestedPhotoBytes
        self.measuredTotalBytes = measuredTotalBytes
        self.projectedTotalBytes = projectedTotalBytes
        self.operations = operations
        self.estimatedReclaimableBytes = estimatedReclaimableBytes
        self.protectedBytes = protectedBytes
        self.preserve = preserve
        self.execution = execution
        self.status = status
        self.stagedAt = stagedAt
        self.validatedAt = validatedAt
        self.validatedOperationIDs = validatedOperationIDs
        self.exportVerifiedOperationIDs = exportVerifiedOperationIDs
        self.committedAt = committedAt
        self.failedAt = failedAt
        self.failureReason = failureReason
        try validate(now: .now)
    }

    public init(from decoder: Decoder) throws {
        try rejectUnknownFitnessKeys(decoder, allowed: [
            "schemaVersion", "planID", "baseRevision", "revision", "createdAt", "updatedAt",
            "asOf", "storagePressure", "ingestionMode", "requestedPhotoBytes",
            "measuredTotalBytes", "projectedTotalBytes", "operations", "estimatedReclaimableBytes",
            "protectedBytes", "preserve", "execution", "status", "stagedAt", "validatedAt",
            "validatedOperationIDs", "exportVerifiedOperationIDs", "committedAt", "failedAt",
            "failureReason"
        ])
        let c = try decoder.container(keyedBy: CodingKeys.self)
        schemaVersion = try c.decode(Int.self, forKey: .schemaVersion)
        planID = try c.decode(String.self, forKey: .planID)
        baseRevision = try c.decode(Int.self, forKey: .baseRevision)
        revision = try c.decode(Int.self, forKey: .revision)
        createdAt = try FitnessValidation.decodeTimestamp(forKey: .createdAt, from: c, field: "createdAt")
        updatedAt = try FitnessValidation.decodeTimestamp(forKey: .updatedAt, from: c, field: "updatedAt")
        asOf = try FitnessValidation.decodeTimestamp(forKey: .asOf, from: c, field: "asOf")
        storagePressure = try c.decode(FitnessStoragePressure.self, forKey: .storagePressure)
        ingestionMode = try c.decode(FitnessIngestionMode.self, forKey: .ingestionMode)
        requestedPhotoBytes = try c.decode(Int.self, forKey: .requestedPhotoBytes)
        measuredTotalBytes = try c.decode(Int.self, forKey: .measuredTotalBytes)
        projectedTotalBytes = try c.decode(Int.self, forKey: .projectedTotalBytes)
        operations = try c.decode([FitnessCompactionOperation].self, forKey: .operations)
        estimatedReclaimableBytes = try c.decode(Int.self, forKey: .estimatedReclaimableBytes)
        protectedBytes = try c.decode(Int.self, forKey: .protectedBytes)
        preserve = try c.decode(FitnessPreservationSet.self, forKey: .preserve)
        execution = try c.decode(String.self, forKey: .execution)
        status = try c.decode(FitnessCompactionStatus.self, forKey: .status)
        stagedAt = try FitnessValidation.decodeOptionalTimestamp(forKey: .stagedAt, from: c, field: "stagedAt")
        validatedAt = try FitnessValidation.decodeOptionalTimestamp(forKey: .validatedAt, from: c, field: "validatedAt")
        validatedOperationIDs = try decodeFitnessOptional([String].self, forKey: .validatedOperationIDs, from: c)
        exportVerifiedOperationIDs = try decodeFitnessOptional([String].self, forKey: .exportVerifiedOperationIDs, from: c)
        committedAt = try FitnessValidation.decodeOptionalTimestamp(forKey: .committedAt, from: c, field: "committedAt")
        failedAt = try FitnessValidation.decodeOptionalTimestamp(forKey: .failedAt, from: c, field: "failedAt")
        failureReason = try decodeFitnessOptional(String.self, forKey: .failureReason, from: c)
        try validate(now: FitnessValidation.now(from: decoder))
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(schemaVersion, forKey: .schemaVersion)
        try c.encode(planID, forKey: .planID)
        try c.encode(baseRevision, forKey: .baseRevision)
        try c.encode(revision, forKey: .revision)
        try FitnessValidation.encodeTimestamp(createdAt, forKey: .createdAt, into: &c)
        try FitnessValidation.encodeTimestamp(updatedAt, forKey: .updatedAt, into: &c)
        try FitnessValidation.encodeTimestamp(asOf, forKey: .asOf, into: &c)
        try c.encode(storagePressure, forKey: .storagePressure)
        try c.encode(ingestionMode, forKey: .ingestionMode)
        try c.encode(requestedPhotoBytes, forKey: .requestedPhotoBytes)
        try c.encode(measuredTotalBytes, forKey: .measuredTotalBytes)
        try c.encode(projectedTotalBytes, forKey: .projectedTotalBytes)
        try c.encode(operations, forKey: .operations)
        try c.encode(estimatedReclaimableBytes, forKey: .estimatedReclaimableBytes)
        try c.encode(protectedBytes, forKey: .protectedBytes)
        try c.encode(preserve, forKey: .preserve)
        try c.encode(execution, forKey: .execution)
        try c.encode(status, forKey: .status)
        try c.encodeIfPresent(stagedAt.map(fitnessTimestamp), forKey: .stagedAt)
        try c.encodeIfPresent(validatedAt.map(fitnessTimestamp), forKey: .validatedAt)
        try c.encodeIfPresent(validatedOperationIDs, forKey: .validatedOperationIDs)
        try c.encodeIfPresent(exportVerifiedOperationIDs, forKey: .exportVerifiedOperationIDs)
        try c.encodeIfPresent(committedAt.map(fitnessTimestamp), forKey: .committedAt)
        try c.encodeIfPresent(failedAt.map(fitnessTimestamp), forKey: .failedAt)
        try c.encodeIfPresent(failureReason, forKey: .failureReason)
    }

    public static func decode(_ data: Data, now: Date = .now) throws -> Self {
        let decoder = JSONDecoder()
        decoder.userInfo[.lifeOSNow] = now
        return try decoder.decode(Self.self, from: data)
    }

    public func validate(now: Date = .now) throws {
        guard schemaVersion == 1 else { throw FitnessRetentionValidationError.unsupportedSchemaVersion(schemaVersion) }
        try FitnessValidation.validateID(planID, field: "planID")
        try FitnessValidation.validateRevision(baseRevision, field: "baseRevision")
        try FitnessValidation.validateRevision(revision)
        try FitnessValidation.validateObserved(createdAt, field: "createdAt", now: now)
        try FitnessValidation.validateObserved(updatedAt, field: "updatedAt", now: now)
        try FitnessValidation.validateObserved(asOf, field: "asOf", now: now)
        try FitnessValidation.validateBytes(requestedPhotoBytes, field: "requestedPhotoBytes",
                                            maximum: FitnessValidation.maximumPhotoBytesPerRequest)
        try FitnessValidation.validateBytes(measuredTotalBytes, field: "measuredTotalBytes",
                                            maximum: FitnessValidation.maximumBreakdownBytes)
        try FitnessValidation.validateBytes(projectedTotalBytes, field: "projectedTotalBytes",
                                            maximum: FitnessValidation.maximumBreakdownBytes + FitnessValidation.maximumPhotoBytesPerRequest)
        guard operations.count <= FitnessValidation.maximumAssets else { throw FitnessRetentionValidationError.invalidBounds("operations") }
        try operations.forEach { try $0.validate() }
        try FitnessValidation.validateBytes(estimatedReclaimableBytes, field: "estimatedReclaimableBytes",
                                            maximum: FitnessValidation.maximumBreakdownBytes)
        try FitnessValidation.validateBytes(protectedBytes, field: "protectedBytes",
                                            maximum: FitnessValidation.maximumBreakdownBytes)
        try preserve.validate()
        guard execution == "plan_only_no_deletion" else {
            throw FitnessRetentionValidationError.contradictoryState("execution")
        }
        var operationIDs = Set<String>()
        var sourceIDs = Set<String>()
        var totalReclaimable = 0
        for operation in operations {
            guard operationIDs.insert(operation.operationID).inserted else { throw FitnessRetentionValidationError.duplicateIdentifier(operation.operationID) }
            guard sourceIDs.insert(operation.sourceAssetID).inserted else { throw FitnessRetentionValidationError.duplicateIdentifier(operation.sourceAssetID) }
            totalReclaimable += operation.reclaimableBytes
        }
        guard totalReclaimable == estimatedReclaimableBytes else {
            throw FitnessRetentionValidationError.contradictoryState("reclaimable bytes")
        }
        let allPreserved = preserve.structuredRecordIDs + preserve.correctionLineageIDs + preserve.provenanceIDs
            + preserve.dailyRollupIDs + preserve.weeklyRollupIDs + preserve.auditRecordIDs
        guard Set(allPreserved).count == allPreserved.count else {
            throw FitnessRetentionValidationError.duplicateIdentifier("plan preservation link")
        }
        guard revision >= baseRevision else { throw FitnessRetentionValidationError.staleRevision }
        func chronological(_ earlier: Date, _ later: Date?, _ field: String) throws {
            if let later, later < earlier { throw FitnessRetentionValidationError.contradictoryState("\(field) precedes prior plan state") }
        }
        try chronological(createdAt, updatedAt, "updatedAt")
        try chronological(createdAt, stagedAt, "stagedAt")
        try chronological(stagedAt ?? createdAt, validatedAt, "validatedAt")
        try chronological(validatedAt ?? stagedAt ?? createdAt, committedAt, "committedAt")
        try chronological(validatedAt ?? stagedAt ?? createdAt, failedAt, "failedAt")
        try chronological(committedAt ?? failedAt ?? validatedAt ?? stagedAt ?? createdAt, updatedAt, "updatedAt")
        if let validatedOperationIDs {
            try FitnessValidation.validateUniqueIDs(validatedOperationIDs, maximum: FitnessValidation.maximumAssets, field: "validatedOperationIDs")
        }
        if let exportVerifiedOperationIDs {
            try FitnessValidation.validateUniqueIDs(exportVerifiedOperationIDs, maximum: FitnessValidation.maximumAssets, field: "exportVerifiedOperationIDs")
        }
        if let failureReason { try FitnessValidation.validateText(failureReason, maximum: 500, field: "failureReason") }
        switch status {
        case .planned:
            guard stagedAt == nil, validatedAt == nil, committedAt == nil, failedAt == nil,
                  failureReason == nil, validatedOperationIDs == nil, exportVerifiedOperationIDs == nil else {
                throw FitnessRetentionValidationError.contradictoryState("planned compaction state")
            }
        case .staging:
            guard stagedAt != nil, validatedAt == nil, committedAt == nil, failedAt == nil, failureReason == nil else {
                throw FitnessRetentionValidationError.contradictoryState("staging compaction state")
            }
        case .validated:
            guard stagedAt != nil, validatedAt != nil, committedAt == nil, failedAt == nil,
                  failureReason == nil, validatedOperationIDs != nil, exportVerifiedOperationIDs != nil else {
                throw FitnessRetentionValidationError.contradictoryState("validated compaction state")
            }
        case .committed:
            guard stagedAt != nil, validatedAt != nil, committedAt != nil, failedAt == nil,
                  failureReason == nil, validatedOperationIDs != nil, exportVerifiedOperationIDs != nil else {
                throw FitnessRetentionValidationError.contradictoryState("committed compaction state")
            }
        case .failed:
            guard failedAt != nil, failureReason != nil, committedAt == nil else {
                throw FitnessRetentionValidationError.contradictoryState("failed compaction state")
            }
        }
    }
}

private func fitnessTimestamp(_ date: Date) -> String {
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    return formatter.string(from: date)
}

public enum FitnessCompactionTransitionEvent: String, Codable, CaseIterable, Equatable, Sendable {
    case begin
    case validate
    case commit
    case fail
    case retry
}

public struct FitnessCompactionTransition: Codable, Equatable, Sendable {
    public let transitionID: String
    public let planID: String
    public let expectedRevision: Int
    public let event: FitnessCompactionTransitionEvent
    public let occurredAt: Date
    public let validatedOperationIDs: [String]?
    public let exportVerifiedOperationIDs: [String]?
    public let failureReason: String?

    private enum CodingKeys: String, CodingKey {
        case transitionID, planID, expectedRevision, event, occurredAt,
             validatedOperationIDs, exportVerifiedOperationIDs, failureReason
    }

    public init(transitionID: String, planID: String, expectedRevision: Int,
                event: FitnessCompactionTransitionEvent, occurredAt: Date,
                validatedOperationIDs: [String]? = nil,
                exportVerifiedOperationIDs: [String]? = nil,
                failureReason: String? = nil) throws {
        self.transitionID = transitionID
        self.planID = planID
        self.expectedRevision = expectedRevision
        self.event = event
        self.occurredAt = occurredAt
        self.validatedOperationIDs = validatedOperationIDs
        self.exportVerifiedOperationIDs = exportVerifiedOperationIDs
        self.failureReason = failureReason
        try validate(now: .now)
    }

    public init(from decoder: Decoder) throws {
        try rejectUnknownFitnessKeys(decoder, allowed: [
            "transitionID", "planID", "expectedRevision", "event", "occurredAt",
            "validatedOperationIDs", "exportVerifiedOperationIDs", "failureReason"
        ])
        let c = try decoder.container(keyedBy: CodingKeys.self)
        transitionID = try c.decode(String.self, forKey: .transitionID)
        planID = try c.decode(String.self, forKey: .planID)
        expectedRevision = try c.decode(Int.self, forKey: .expectedRevision)
        event = try c.decode(FitnessCompactionTransitionEvent.self, forKey: .event)
        occurredAt = try FitnessValidation.decodeTimestamp(forKey: .occurredAt, from: c, field: "occurredAt")
        validatedOperationIDs = try decodeFitnessOptional([String].self, forKey: .validatedOperationIDs, from: c)
        exportVerifiedOperationIDs = try decodeFitnessOptional([String].self, forKey: .exportVerifiedOperationIDs, from: c)
        failureReason = try decodeFitnessOptional(String.self, forKey: .failureReason, from: c)
        try validate(now: FitnessValidation.now(from: decoder))
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(transitionID, forKey: .transitionID)
        try c.encode(planID, forKey: .planID)
        try c.encode(expectedRevision, forKey: .expectedRevision)
        try c.encode(event, forKey: .event)
        try FitnessValidation.encodeTimestamp(occurredAt, forKey: .occurredAt, into: &c)
        try c.encodeIfPresent(validatedOperationIDs, forKey: .validatedOperationIDs)
        try c.encodeIfPresent(exportVerifiedOperationIDs, forKey: .exportVerifiedOperationIDs)
        try c.encodeIfPresent(failureReason, forKey: .failureReason)
    }

    public func validate(now: Date = .now) throws {
        try FitnessValidation.validateID(transitionID, field: "transitionID")
        try FitnessValidation.validateID(planID, field: "planID")
        try FitnessValidation.validateRevision(expectedRevision, field: "expectedRevision")
        try FitnessValidation.validateObserved(occurredAt, field: "occurredAt", now: now)
        if let validatedOperationIDs {
            try FitnessValidation.validateUniqueIDs(validatedOperationIDs,
                                                    maximum: FitnessValidation.maximumAssets,
                                                    field: "validatedOperationIDs")
        }
        if let exportVerifiedOperationIDs {
            try FitnessValidation.validateUniqueIDs(exportVerifiedOperationIDs,
                                                    maximum: FitnessValidation.maximumAssets,
                                                    field: "exportVerifiedOperationIDs")
        }
        if let failureReason { try FitnessValidation.validateText(failureReason, maximum: 500, field: "failureReason") }
        switch event {
        case .validate:
            guard validatedOperationIDs != nil, exportVerifiedOperationIDs != nil,
                  failureReason == nil else {
                throw FitnessRetentionValidationError.contradictoryState("validate transition fields")
            }
        case .fail:
            guard failureReason != nil, validatedOperationIDs == nil,
                  exportVerifiedOperationIDs == nil else {
                throw FitnessRetentionValidationError.contradictoryState("fail transition fields")
            }
        case .begin, .commit, .retry:
            guard validatedOperationIDs == nil, exportVerifiedOperationIDs == nil,
                  failureReason == nil else {
                throw FitnessRetentionValidationError.contradictoryState("transition fields")
            }
        }
    }
}

private func fitnessStableTag(_ value: String) -> String {
    var hash: UInt32 = 2_166_136_261
    for byte in value.utf8 {
        hash ^= UInt32(byte)
        hash = hash &* 16_777_619
    }
    return String(format: "%08x", hash)
}

private func fitnessDerivedID(_ prefix: String, _ parts: String...) -> String {
    "\(prefix)-\(fitnessStableTag(parts.joined(separator: "|")))"
}

private func fitnessStoragePressure(_ totalBytes: Int) -> FitnessStoragePressure {
    if totalBytes >= FitnessStorageLimits.hardCapBytes { return .hardIngestionGate }
    if totalBytes >= FitnessStorageLimits.aggressiveCompactionBytes { return .aggressiveCompaction }
    if totalBytes >= FitnessStorageLimits.warningBytes { return .warning }
    return .normal
}

private func fitnessIngestionMode(_ totalBytes: Int) -> FitnessIngestionMode {
    if totalBytes >= FitnessStorageLimits.hardCapBytes { return .manualOnlyNoPhotoRetention }
    if totalBytes >= FitnessStorageLimits.aggressiveCompactionBytes { return .structuredOnlyTransientPhoto }
    return .persistentPhotoAllowed
}

private func fitnessSameIDs(_ left: [String]?, _ right: [String]) -> Bool {
    guard let left, left.count == right.count else { return false }
    return right.allSatisfy { left.contains($0) }
}

private func fitnessNextRevision(_ current: Int) throws -> Int {
    guard current < FitnessValidation.maximumRevision else {
        throw FitnessRetentionValidationError.invalidBounds("compaction plan revision exhausted")
    }
    return current + 1
}

/// Purely plans due work against a validated snapshot. No thumbnail, rollup,
/// export, tombstone, or source-removal side effect is performed.
public func planFitnessCompaction(
    _ input: FitnessCompactionRequest,
    now: Date = .now
) throws -> FitnessCompactionPlan {
    try input.validate(now: now)
    let requestedPhotoBytes = input.requestedPhotoBytes ?? 0
    let projectedTotalBytes = input.storage.totalBytes + requestedPhotoBytes
    let pressure = fitnessStoragePressure(projectedTotalBytes)
    let ingestionMode = fitnessIngestionMode(projectedTotalBytes)
    var preserve = try FitnessPreservationSet()
    var operations: [FitnessCompactionOperation] = []

    func addUnique(_ value: String, to values: inout [String]) {
        if !values.contains(value) { values.append(value) }
    }

    for asset in input.assets {
        let age = input.observedAt.timeIntervalSince(asset.observedAt)
        let originalDue = asset.kind == .originalPhoto
            && input.retentionPolicy.allowOriginalCompaction
            && age >= TimeInterval(input.retentionPolicy.originalRetentionDays) * FitnessValidation.day
        let historyDue = asset.kind == .detailedHistory
            && input.retentionPolicy.allowDetailedHistoryCompaction
            && age >= TimeInterval(input.retentionPolicy.detailedHistoryRetentionDays) * FitnessValidation.day
        guard originalDue || historyDue, !asset.pinned, !asset.exported else { continue }

        let operationID = fitnessDerivedID("fitness-op", input.planID, asset.id)
        let auditEventID = fitnessDerivedID("fitness-audit", input.planID, asset.id)
        let removal = try FitnessCompactionSourceRemoval(auditEventID: auditEventID)
        let eligibility: FitnessCompactionEligibility = originalDue
            ? .originalOlderThan90Days : .historyOlderThan365Days
        let reclaimable = originalDue
            ? max(0, asset.bytes - FitnessValidation.targetDerivativeBytes) : asset.bytes
        let steps: [FitnessCompactionStep] = [
            .writeReplacement, .validateReplacement,
            .verifyExportAndProvenance, .removeSourceAfterCommit
        ]
        if asset.kind == .originalPhoto {
            let operationPreserve = try FitnessPreservationSet(
                structuredRecordIDs: [asset.structuredRecordID!],
                correctionLineageIDs: [asset.correctionLineageID!],
                provenanceIDs: [asset.provenanceID!],
                auditRecordIDs: [asset.auditRecordID]
            )
            let operation = try FitnessCompactionOperation(
                operationID: operationID, sourceAssetID: asset.id,
                sourceBytes: asset.bytes, reclaimableBytes: reclaimable,
                eligibility: eligibility, transactionSteps: steps,
                sourceRemoval: removal, kind: .originalPhoto,
                target: try FitnessCompactionTarget(
                    thumbnailID: fitnessDerivedID("fitness-thumb", asset.id),
                    maximumThumbnailBytes: FitnessValidation.targetDerivativeBytes
                ),
                preserve: operationPreserve
            )
            operations.append(operation)
            addUnique(asset.structuredRecordID!, to: &preserve.structuredRecordIDs)
            addUnique(asset.correctionLineageID!, to: &preserve.correctionLineageIDs)
            addUnique(asset.provenanceID!, to: &preserve.provenanceIDs)
            addUnique(asset.auditRecordID, to: &preserve.auditRecordIDs)
        } else {
            let operationPreserve = try FitnessPreservationSet(
                dailyRollupIDs: [asset.dailyRollupID!],
                weeklyRollupIDs: [asset.weeklyRollupID!],
                auditRecordIDs: [asset.auditRecordID]
            )
            let operation = try FitnessCompactionOperation(
                operationID: operationID, sourceAssetID: asset.id,
                sourceBytes: asset.bytes, reclaimableBytes: reclaimable,
                eligibility: eligibility, transactionSteps: steps,
                sourceRemoval: removal, kind: .detailedHistory,
                target: try FitnessCompactionTarget(
                    dailyRollupID: asset.dailyRollupID!,
                    weeklyRollupID: asset.weeklyRollupID!
                ),
                preserve: operationPreserve
            )
            operations.append(operation)
            addUnique(asset.dailyRollupID!, to: &preserve.dailyRollupIDs)
            addUnique(asset.weeklyRollupID!, to: &preserve.weeklyRollupIDs)
            addUnique(asset.auditRecordID, to: &preserve.auditRecordIDs)
        }
    }

    let estimated = operations.reduce(0) { $0 + $1.reclaimableBytes }
    let protectedBytes = input.assets.filter { $0.pinned || $0.exported }
        .reduce(0) { $0 + $1.bytes }
    return try FitnessCompactionPlan(
        planID: input.planID, baseRevision: input.revision, revision: input.revision,
        createdAt: input.observedAt, updatedAt: input.observedAt, asOf: input.observedAt,
        storagePressure: pressure, ingestionMode: ingestionMode,
        requestedPhotoBytes: requestedPhotoBytes,
        measuredTotalBytes: input.storage.totalBytes,
        projectedTotalBytes: projectedTotalBytes,
        operations: operations, estimatedReclaimableBytes: estimated,
        protectedBytes: protectedBytes, preserve: preserve
    )
}

/// Pure optimistic-concurrency-safe transaction state transition. It only
/// returns the next plan value; execution remains the responsibility of a
/// future transactional store.
public func advanceFitnessCompactionPlan(
    _ planInput: FitnessCompactionPlan,
    _ transitionInput: FitnessCompactionTransition,
    now: Date = .now
) throws -> FitnessCompactionPlan {
    try planInput.validate(now: now)
    try transitionInput.validate(now: now)
    guard transitionInput.planID == planInput.planID else {
        throw FitnessRetentionValidationError.contradictoryState("transition targets a different plan")
    }
    guard transitionInput.expectedRevision == planInput.revision else {
        throw FitnessRetentionValidationError.staleRevision
    }
    guard transitionInput.occurredAt >= planInput.updatedAt else {
        throw FitnessRetentionValidationError.contradictoryState("transition predates current plan")
    }
    let operationIDs = planInput.operations.map(\.operationID)
    let nextRevision = try fitnessNextRevision(planInput.revision)
    var next = planInput
    // The plan is immutable by design. Build the next state through the
    // internal initializer so every returned value is validated before use.
    func make(
        status: FitnessCompactionStatus,
        stagedAt: Date? = next.stagedAt,
        validatedAt: Date? = next.validatedAt,
        validatedOperationIDs: [String]? = next.validatedOperationIDs,
        exportVerifiedOperationIDs: [String]? = next.exportVerifiedOperationIDs,
        committedAt: Date? = next.committedAt,
        failedAt: Date? = next.failedAt,
        failureReason: String? = next.failureReason
    ) throws -> FitnessCompactionPlan {
        try FitnessCompactionPlan(
            schemaVersion: next.schemaVersion, planID: next.planID,
            baseRevision: next.baseRevision, revision: nextRevision,
            createdAt: next.createdAt, updatedAt: transitionInput.occurredAt,
            asOf: next.asOf, storagePressure: next.storagePressure,
            ingestionMode: next.ingestionMode,
            requestedPhotoBytes: next.requestedPhotoBytes,
            measuredTotalBytes: next.measuredTotalBytes,
            projectedTotalBytes: next.projectedTotalBytes,
            operations: next.operations,
            estimatedReclaimableBytes: next.estimatedReclaimableBytes,
            protectedBytes: next.protectedBytes, preserve: next.preserve,
            execution: next.execution, status: status, stagedAt: stagedAt,
            validatedAt: validatedAt, validatedOperationIDs: validatedOperationIDs,
            exportVerifiedOperationIDs: exportVerifiedOperationIDs,
            committedAt: committedAt, failedAt: failedAt,
            failureReason: failureReason
        )
    }

    switch transitionInput.event {
    case .begin:
        guard planInput.status == .planned else {
            throw FitnessRetentionValidationError.contradictoryState("begin is only valid for planned compaction")
        }
        next = try make(status: .staging, stagedAt: transitionInput.occurredAt)
    case .validate:
        guard planInput.status == .staging else {
            throw FitnessRetentionValidationError.contradictoryState("validate is only valid while staging")
        }
        guard fitnessSameIDs(transitionInput.validatedOperationIDs, operationIDs),
              fitnessSameIDs(transitionInput.exportVerifiedOperationIDs, operationIDs) else {
            throw FitnessRetentionValidationError.contradictoryState("validation must cover every operation")
        }
        next = try make(status: .validated, validatedAt: transitionInput.occurredAt,
                        validatedOperationIDs: operationIDs,
                        exportVerifiedOperationIDs: operationIDs)
    case .commit:
        guard planInput.status == .validated,
              fitnessSameIDs(planInput.validatedOperationIDs, operationIDs),
              fitnessSameIDs(planInput.exportVerifiedOperationIDs, operationIDs) else {
            throw FitnessRetentionValidationError.contradictoryState("commit requires complete validation proofs")
        }
        next = try make(status: .committed, committedAt: transitionInput.occurredAt)
    case .fail:
        guard planInput.status != .committed, planInput.status != .failed else {
            throw FitnessRetentionValidationError.contradictoryState("committed or failed compaction cannot fail again")
        }
        next = try make(status: .failed, failedAt: transitionInput.occurredAt,
                        failureReason: transitionInput.failureReason)
    case .retry:
        guard planInput.status == .failed else {
            throw FitnessRetentionValidationError.contradictoryState("retry is only valid after failed compaction")
        }
        next = try make(status: .staging, stagedAt: transitionInput.occurredAt,
                        validatedAt: nil, validatedOperationIDs: nil,
                        exportVerifiedOperationIDs: nil, committedAt: nil,
                        failedAt: nil, failureReason: nil)
    }
    return next
}
