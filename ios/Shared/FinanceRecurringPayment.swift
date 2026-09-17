import CryptoKit
import Foundation

// MARK: - Local recurring-payment contract

/// The recurring-payment packet is intentionally local and import-only. A
/// value in this file never implies that a live bank observation or a bank
/// mandate was found.
public enum FinanceRecurringPaymentContract {
    public static let schemaVersion = 1
    public static let identityVersion = 1
    public static let normalizationVersion = "merchant-v1"
    public static let detectorVersion = "recurring-v1"
    public static let defaultTimeZoneIdentifier = "Europe/Berlin"
    public static let maximumMerchantKeyBytes = 256
    public static let maximumSourceNamespaceBytes = 64
    public static let maximumTimeZoneBytes = 128
    public static let maximumEvidence = 10_000
    public static let maximumCandidates = 10_000
    public static let maximumExclusionReasons = 64

    public static func supportsNormalizationVersion(_ version: String) -> Bool {
        version == normalizationVersion
    }

    public static func supportsDetectorVersion(_ version: String) -> Bool {
        version == detectorVersion
    }
}

public enum FinanceRecurringValidationError: Error, Equatable, Sendable {
    case invalidKey
    case invalidEvidence
    case invalidAnchor
    case invalidCandidate
    case invalidOverride
    case invalidAssessment
    case invalidCache
    case invalidTimeZone
    case unsupportedVersion
    case tooManyItems
}

public enum FinanceRecurringCadence: String, Codable, CaseIterable, Equatable, Hashable, Sendable {
    case weekly
    case monthly
    case yearly
}

public enum FinanceRecurringConfidence: String, Codable, Equatable, Sendable {
    case high
    case needsReview
}

public enum FinanceRecurringPaymentStatus: String, Codable, CaseIterable, Equatable, Sendable {
    case active
    case paused
    case ignored
}

/// Reasons are deliberately structured so the UI can explain a review state
/// without exposing raw CSV text or relying on keyword-only claims.
public enum FinanceRecurringReasonCode: String, Codable, CaseIterable, Equatable, Hashable, Sendable {
    case insufficientHistory
    case minimumHistoryOnly
    case amountVariance
    case ambiguousCadence
    case scheduleDrift
    case multiplePaymentsInPeriod
    case unsupportedLegacyIdentity
    case missingMappedIdentity
    case missingProvenance
    case unsupportedLiveObservation
    case notNegativeCash
    case investmentOrder
    case income
    case refund
    case transfer
    case emptyMerchant
    case unsupportedCurrency
    case duplicateTransactionID
    case conflictingTransactionID
    case detectorError
}

public enum FinanceRecurringCoverage: String, Codable, Equatable, Sendable {
    case mappedImportsOnly
    case noValidatedMappedImports
}

/// Stable identity for a possible recurring payment. Amount, category,
/// import batch, mapping configuration and detector version are deliberately
/// absent so a reimport, category edit, or detector improvement does not erase
/// a user's local decision.
public struct FinanceRecurringPaymentKey: Codable, Equatable, Hashable, Identifiable, Sendable {
    public let identityVersion: Int
    public let sourceNamespace: String
    public let accountID: UUID
    public let currency: String
    public let normalizedMerchantKey: String
    public let normalizationVersion: String

    public var id: String { stableID }

    public var stableID: String {
        let payload = FinanceRecurringIdentityPayload(
            identityVersion: identityVersion,
            sourceNamespace: sourceNamespace,
            accountID: accountID.uuidString.lowercased(),
            currency: currency,
            normalizedMerchantKey: normalizedMerchantKey,
            normalizationVersion: normalizationVersion
        )
        let encoder = JSONEncoder.lifeOS
        encoder.outputFormatting = [.sortedKeys]
        let data = (try? encoder.encode(payload)) ?? Data()
        return FinanceRecurringPaymentKey.sha256(data)
    }

    public init(
        sourceNamespace: String,
        accountID: UUID,
        currency: String,
        normalizedMerchantKey: String,
        normalizationVersion: String = FinanceRecurringPaymentContract.normalizationVersion,
        identityVersion: Int = FinanceRecurringPaymentContract.identityVersion
    ) throws {
        let source = sourceNamespace.trimmingCharacters(in: .whitespacesAndNewlines)
        let merchant = normalizedMerchantKey.trimmingCharacters(in: .whitespacesAndNewlines)
        let normalizedCurrency = currency.uppercased()
        let normalizedVersion = normalizationVersion.trimmingCharacters(in: .whitespacesAndNewlines)
        guard identityVersion == FinanceRecurringPaymentContract.identityVersion,
              !source.isEmpty,
              source.utf8.count <= FinanceRecurringPaymentContract.maximumSourceNamespaceBytes,
              !merchant.isEmpty,
              merchant.utf8.count <= FinanceRecurringPaymentContract.maximumMerchantKeyBytes,
              !normalizedCurrency.isEmpty,
              normalizedCurrency.utf8.count <= 3,
              normalizedCurrency == "EUR",
              FinanceRecurringPaymentContract.supportsNormalizationVersion(normalizedVersion) else {
            throw FinanceRecurringValidationError.invalidKey
        }
        self.identityVersion = identityVersion
        self.sourceNamespace = source
        self.accountID = accountID
        self.currency = normalizedCurrency
        self.normalizedMerchantKey = merchant
        self.normalizationVersion = normalizedVersion
    }

    private struct FinanceRecurringIdentityPayload: Codable, Sendable {
        let identityVersion: Int
        let sourceNamespace: String
        let accountID: String
        let currency: String
        let normalizedMerchantKey: String
        let normalizationVersion: String
    }

    private enum CodingKeys: String, CodingKey, CaseIterable {
        case identityVersion, sourceNamespace, accountID, currency
        case normalizedMerchantKey, normalizationVersion
    }

    public init(from decoder: Decoder) throws {
        try rejectUnknownLifeOSKeys(decoder, allowed: Set(CodingKeys.allCases.map(\.stringValue)))
        let container = try decoder.container(keyedBy: CodingKeys.self)
        guard Set(container.allKeys) == Set(CodingKeys.allCases) else {
            throw FinanceRecurringValidationError.invalidKey
        }
        try self.init(
            sourceNamespace: container.decode(String.self, forKey: .sourceNamespace),
            accountID: container.decode(UUID.self, forKey: .accountID),
            currency: container.decode(String.self, forKey: .currency),
            normalizedMerchantKey: container.decode(String.self, forKey: .normalizedMerchantKey),
            normalizationVersion: container.decode(String.self, forKey: .normalizationVersion),
            identityVersion: container.decode(Int.self, forKey: .identityVersion)
        )
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(identityVersion, forKey: .identityVersion)
        try container.encode(sourceNamespace, forKey: .sourceNamespace)
        try container.encode(accountID, forKey: .accountID)
        try container.encode(currency, forKey: .currency)
        try container.encode(normalizedMerchantKey, forKey: .normalizedMerchantKey)
        try container.encode(normalizationVersion, forKey: .normalizationVersion)
    }

    public func canonicalData() throws -> Data {
        let encoder = JSONEncoder.lifeOS
        encoder.outputFormatting = [.sortedKeys]
        return try encoder.encode(FinanceRecurringIdentityPayload(
            identityVersion: identityVersion,
            sourceNamespace: sourceNamespace,
            accountID: accountID.uuidString.lowercased(),
            currency: currency,
            normalizedMerchantKey: normalizedMerchantKey,
            normalizationVersion: normalizationVersion
        ))
    }

    private static func sha256(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}

public struct FinanceRecurringEvidenceReference: Codable, Equatable, Hashable, Identifiable, Sendable {
    public let sourceNamespace: String
    public let transactionID: UUID
    public let batchID: UUID?
    public let sourceRowNumber: Int?

    public var id: String { transactionID.uuidString.lowercased() }

    public init(
        sourceNamespace: String,
        transactionID: UUID,
        batchID: UUID? = nil,
        sourceRowNumber: Int? = nil
    ) throws {
        let source = sourceNamespace.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !source.isEmpty,
              source.utf8.count <= FinanceRecurringPaymentContract.maximumSourceNamespaceBytes,
              sourceRowNumber.map({ $0 >= 1 }) ?? true else {
            throw FinanceRecurringValidationError.invalidEvidence
        }
        self.sourceNamespace = source
        self.transactionID = transactionID
        self.batchID = batchID
        self.sourceRowNumber = sourceRowNumber
    }

    private enum CodingKeys: String, CodingKey, CaseIterable {
        case sourceNamespace, transactionID, batchID, sourceRowNumber
    }

    public init(from decoder: Decoder) throws {
        try rejectUnknownLifeOSKeys(decoder, allowed: Set(CodingKeys.allCases.map(\.stringValue)))
        let container = try decoder.container(keyedBy: CodingKeys.self)
        guard Set(container.allKeys).contains(.sourceNamespace),
              Set(container.allKeys).contains(.transactionID),
              Set(container.allKeys).isSubset(of: Set(CodingKeys.allCases)) else {
            throw FinanceRecurringValidationError.invalidEvidence
        }
        try self.init(
            sourceNamespace: container.decode(String.self, forKey: .sourceNamespace),
            transactionID: container.decode(UUID.self, forKey: .transactionID),
            batchID: container.decodeIfPresent(UUID.self, forKey: .batchID),
            sourceRowNumber: container.decodeIfPresent(Int.self, forKey: .sourceRowNumber)
        )
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(sourceNamespace, forKey: .sourceNamespace)
        try container.encode(transactionID, forKey: .transactionID)
        try container.encodeIfPresent(batchID, forKey: .batchID)
        try container.encodeIfPresent(sourceRowNumber, forKey: .sourceRowNumber)
    }
}

public struct FinanceRecurringAnchor: Codable, Equatable, Sendable {
    public let date: Date
    public let timeZoneIdentifier: String

    public init(date: Date, timeZoneIdentifier: String) throws {
        let trimmed = timeZoneIdentifier.trimmingCharacters(in: .whitespacesAndNewlines)
        guard date.timeIntervalSinceReferenceDate.isFinite,
              !trimmed.isEmpty,
              trimmed.utf8.count <= FinanceRecurringPaymentContract.maximumTimeZoneBytes,
              TimeZone(identifier: trimmed) != nil else {
            throw FinanceRecurringValidationError.invalidAnchor
        }
        self.date = date
        self.timeZoneIdentifier = trimmed
    }

    public func calendar() throws -> Calendar {
        guard let timeZone = TimeZone(identifier: timeZoneIdentifier) else {
            throw FinanceRecurringValidationError.invalidTimeZone
        }
        var calendar = Calendar(identifier: .gregorian)
        calendar.locale = Locale(identifier: "en_US_POSIX")
        calendar.timeZone = timeZone
        return calendar
    }

    private enum CodingKeys: String, CodingKey, CaseIterable { case date, timeZoneIdentifier }

    public init(from decoder: Decoder) throws {
        try rejectUnknownLifeOSKeys(decoder, allowed: Set(CodingKeys.allCases.map(\.stringValue)))
        let container = try decoder.container(keyedBy: CodingKeys.self)
        guard Set(container.allKeys) == Set(CodingKeys.allCases) else {
            throw FinanceRecurringValidationError.invalidAnchor
        }
        try self.init(
            date: container.decode(Date.self, forKey: .date),
            timeZoneIdentifier: container.decode(String.self, forKey: .timeZoneIdentifier)
        )
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(date, forKey: .date)
        try container.encode(timeZoneIdentifier, forKey: .timeZoneIdentifier)
    }
}

public struct FinanceRecurringPaymentCandidate: Codable, Equatable, Identifiable, Sendable {
    public let key: FinanceRecurringPaymentKey
    public let supportingEvidence: [FinanceRecurringEvidenceReference]
    public let detectedCadence: FinanceRecurringCadence?
    public let confidence: FinanceRecurringConfidence
    public let reasonCodes: [FinanceRecurringReasonCode]
    public let anchor: FinanceRecurringAnchor
    public let predictedDate: Date?
    /// The latest eligible payment in this stable payment key, including
    /// observations that were not part of the winning cadence run. It is
    /// optional so candidates written before this field was introduced remain
    /// decodable and fail closed at presentation when no boundary is known.
    public let latestEligiblePaymentDate: Date?
    /// The cadence period occupied by the last representative observation.
    /// This is optional for backward-compatible reads of pre-period caches;
    /// newly detected candidates always persist it so an early payment cannot
    /// make presentation predict the already-consumed period again.
    public let lastConsumedPeriodIndex: Int?
    public let detectorVersion: String

    public var id: String { key.id }

    public init(
        key: FinanceRecurringPaymentKey,
        supportingEvidence: [FinanceRecurringEvidenceReference],
        detectedCadence: FinanceRecurringCadence?,
        confidence: FinanceRecurringConfidence,
        reasonCodes: [FinanceRecurringReasonCode],
        anchor: FinanceRecurringAnchor,
        predictedDate: Date?,
        latestEligiblePaymentDate: Date? = nil,
        lastConsumedPeriodIndex: Int? = nil,
        detectorVersion: String = FinanceRecurringPaymentContract.detectorVersion
    ) throws {
        guard !supportingEvidence.isEmpty,
              supportingEvidence.count <= FinanceRecurringPaymentContract.maximumEvidence,
              Set(supportingEvidence.map(\.id)).count == supportingEvidence.count,
              Set(reasonCodes).count == reasonCodes.count,
              supportingEvidence.allSatisfy({ $0.sourceNamespace == key.sourceNamespace }),
              FinanceRecurringPaymentContract.supportsDetectorVersion(detectorVersion),
              anchor.timeZoneIdentifier == FinanceRecurringPaymentContract.defaultTimeZoneIdentifier ||
                TimeZone(identifier: anchor.timeZoneIdentifier) != nil,
              latestEligiblePaymentDate?.timeIntervalSinceReferenceDate.isFinite ?? true,
              lastConsumedPeriodIndex.map({ $0 >= 0 }) ?? true,
              predictedDate?.timeIntervalSinceReferenceDate.isFinite ?? true else {
            throw FinanceRecurringValidationError.invalidCandidate
        }
        if confidence == .high {
            guard detectedCadence != nil,
                  supportingEvidence.count >= 4,
                  reasonCodes.isEmpty else {
                throw FinanceRecurringValidationError.invalidCandidate
            }
        }
        self.key = key
        self.supportingEvidence = supportingEvidence
        self.detectedCadence = detectedCadence
        self.confidence = confidence
        self.reasonCodes = reasonCodes
        self.anchor = anchor
        self.predictedDate = predictedDate
        self.latestEligiblePaymentDate = latestEligiblePaymentDate
        self.lastConsumedPeriodIndex = lastConsumedPeriodIndex
        self.detectorVersion = detectorVersion
    }

    private enum CodingKeys: String, CodingKey, CaseIterable {
        case key, supportingEvidence, detectedCadence, confidence, reasonCodes
        case anchor, predictedDate, latestEligiblePaymentDate
        case lastConsumedPeriodIndex, detectorVersion
    }

    public init(from decoder: Decoder) throws {
        try rejectUnknownLifeOSKeys(decoder, allowed: Set(CodingKeys.allCases.map(\.stringValue)))
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let required: Set<CodingKeys> = [.key, .supportingEvidence, .confidence, .reasonCodes, .anchor, .detectorVersion]
        guard required.isSubset(of: Set(container.allKeys)),
              Set(container.allKeys).isSubset(of: Set(CodingKeys.allCases)) else {
            throw FinanceRecurringValidationError.invalidCandidate
        }
        try self.init(
            key: container.decode(FinanceRecurringPaymentKey.self, forKey: .key),
            supportingEvidence: container.decode([FinanceRecurringEvidenceReference].self, forKey: .supportingEvidence),
            detectedCadence: container.decodeIfPresent(FinanceRecurringCadence.self, forKey: .detectedCadence),
            confidence: container.decode(FinanceRecurringConfidence.self, forKey: .confidence),
            reasonCodes: container.decode([FinanceRecurringReasonCode].self, forKey: .reasonCodes),
            anchor: container.decode(FinanceRecurringAnchor.self, forKey: .anchor),
            predictedDate: container.decodeIfPresent(Date.self, forKey: .predictedDate),
            latestEligiblePaymentDate: container.decodeIfPresent(Date.self, forKey: .latestEligiblePaymentDate),
            lastConsumedPeriodIndex: container.decodeIfPresent(Int.self, forKey: .lastConsumedPeriodIndex),
            detectorVersion: container.decode(String.self, forKey: .detectorVersion)
        )
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(key, forKey: .key)
        try container.encode(supportingEvidence, forKey: .supportingEvidence)
        try container.encodeIfPresent(detectedCadence, forKey: .detectedCadence)
        try container.encode(confidence, forKey: .confidence)
        try container.encode(reasonCodes, forKey: .reasonCodes)
        try container.encode(anchor, forKey: .anchor)
        try container.encodeIfPresent(predictedDate, forKey: .predictedDate)
        try container.encodeIfPresent(latestEligiblePaymentDate, forKey: .latestEligiblePaymentDate)
        try container.encodeIfPresent(lastConsumedPeriodIndex, forKey: .lastConsumedPeriodIndex)
        try container.encode(detectorVersion, forKey: .detectorVersion)
    }
}

public struct FinanceRecurringPaymentOverride: Codable, Equatable, Sendable {
    public let key: FinanceRecurringPaymentKey
    public let cadence: FinanceRecurringCadence?
    public let anchor: FinanceRecurringAnchor?
    public let status: FinanceRecurringPaymentStatus
    public let localRevision: Int
    public let updatedAt: Date

    public init(
        key: FinanceRecurringPaymentKey,
        cadence: FinanceRecurringCadence? = nil,
        anchor: FinanceRecurringAnchor? = nil,
        status: FinanceRecurringPaymentStatus = .active,
        localRevision: Int = 0,
        updatedAt: Date = .now
    ) throws {
        guard localRevision >= 0,
              localRevision <= 1_000_000_000,
              updatedAt.timeIntervalSinceReferenceDate.isFinite,
              (cadence == nil) == (anchor == nil) else {
            throw FinanceRecurringValidationError.invalidOverride
        }
        self.key = key
        self.cadence = cadence
        self.anchor = anchor
        self.status = status
        self.localRevision = localRevision
        self.updatedAt = Date(timeIntervalSince1970: updatedAt.timeIntervalSince1970.rounded(.down))
    }

    private enum CodingKeys: String, CodingKey, CaseIterable {
        case key, cadence, anchor, status, localRevision, updatedAt
    }

    public init(from decoder: Decoder) throws {
        try rejectUnknownLifeOSKeys(decoder, allowed: Set(CodingKeys.allCases.map(\.stringValue)))
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let required: Set<CodingKeys> = [.key, .status, .localRevision, .updatedAt]
        guard required.isSubset(of: Set(container.allKeys)),
              Set(container.allKeys).isSubset(of: Set(CodingKeys.allCases)) else {
            throw FinanceRecurringValidationError.invalidOverride
        }
        try self.init(
            key: container.decode(FinanceRecurringPaymentKey.self, forKey: .key),
            cadence: container.decodeIfPresent(FinanceRecurringCadence.self, forKey: .cadence),
            anchor: container.decodeIfPresent(FinanceRecurringAnchor.self, forKey: .anchor),
            status: container.decode(FinanceRecurringPaymentStatus.self, forKey: .status),
            localRevision: container.decode(Int.self, forKey: .localRevision),
            updatedAt: container.decode(Date.self, forKey: .updatedAt)
        )
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(key, forKey: .key)
        try container.encodeIfPresent(cadence, forKey: .cadence)
        try container.encodeIfPresent(anchor, forKey: .anchor)
        try container.encode(status, forKey: .status)
        try container.encode(localRevision, forKey: .localRevision)
        try container.encode(updatedAt, forKey: .updatedAt)
    }
}

public struct FinanceRecurringExclusion: Codable, Equatable, Sendable {
    public let reason: FinanceRecurringReasonCode
    public let count: Int

    public init(reason: FinanceRecurringReasonCode, count: Int) throws {
        guard count > 0 else { throw FinanceRecurringValidationError.invalidAssessment }
        self.reason = reason
        self.count = count
    }

    private enum CodingKeys: String, CodingKey, CaseIterable { case reason, count }

    public init(from decoder: Decoder) throws {
        try rejectUnknownLifeOSKeys(decoder, allowed: Set(CodingKeys.allCases.map(\.stringValue)))
        let container = try decoder.container(keyedBy: CodingKeys.self)
        guard Set(container.allKeys) == Set(CodingKeys.allCases) else {
            throw FinanceRecurringValidationError.invalidAssessment
        }
        try self.init(
            reason: container.decode(FinanceRecurringReasonCode.self, forKey: .reason),
            count: container.decode(Int.self, forKey: .count)
        )
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(reason, forKey: .reason)
        try container.encode(count, forKey: .count)
    }
}

public struct FinanceRecurringPaymentAssessment: Codable, Equatable, Sendable {
    public let schemaVersion: Int
    public let candidates: [FinanceRecurringPaymentCandidate]
    public let exclusions: [FinanceRecurringExclusion]
    public let coverage: FinanceRecurringCoverage
    public let timeZoneIdentifier: String
    public let detectorVersion: String
    public let generatedAt: Date

    public init(
        candidates: [FinanceRecurringPaymentCandidate],
        exclusions: [FinanceRecurringExclusion],
        coverage: FinanceRecurringCoverage,
        timeZoneIdentifier: String,
        detectorVersion: String = FinanceRecurringPaymentContract.detectorVersion,
        generatedAt: Date = .now
    ) throws {
        let trimmedTimeZone = timeZoneIdentifier.trimmingCharacters(in: .whitespacesAndNewlines)
        guard candidates.count <= FinanceRecurringPaymentContract.maximumCandidates,
              Set(candidates.map(\.id)).count == candidates.count,
              exclusions.count <= FinanceRecurringPaymentContract.maximumExclusionReasons,
              Set(exclusions.map(\.reason)).count == exclusions.count,
              !trimmedTimeZone.isEmpty,
              TimeZone(identifier: trimmedTimeZone) != nil,
              trimmedTimeZone.utf8.count <= FinanceRecurringPaymentContract.maximumTimeZoneBytes,
              FinanceRecurringPaymentContract.supportsDetectorVersion(detectorVersion),
              candidates.allSatisfy({ candidate in
                  candidate.detectorVersion == detectorVersion
                      && candidate.anchor.timeZoneIdentifier == trimmedTimeZone
                      && candidate.key.normalizationVersion == FinanceRecurringPaymentContract.normalizationVersion
              }),
              generatedAt.timeIntervalSinceReferenceDate.isFinite else {
            throw FinanceRecurringValidationError.invalidAssessment
        }
        self.schemaVersion = FinanceRecurringPaymentContract.schemaVersion
        self.candidates = candidates
        self.exclusions = exclusions
        self.coverage = coverage
        self.timeZoneIdentifier = trimmedTimeZone
        self.detectorVersion = detectorVersion
        self.generatedAt = Date(timeIntervalSince1970: generatedAt.timeIntervalSince1970.rounded(.down))
    }

    private enum CodingKeys: String, CodingKey, CaseIterable {
        case schemaVersion, candidates, exclusions, coverage
        case timeZoneIdentifier, detectorVersion, generatedAt
    }

    public init(from decoder: Decoder) throws {
        try rejectUnknownLifeOSKeys(decoder, allowed: Set(CodingKeys.allCases.map(\.stringValue)))
        let container = try decoder.container(keyedBy: CodingKeys.self)
        guard Set(container.allKeys) == Set(CodingKeys.allCases) else {
            throw FinanceRecurringValidationError.invalidAssessment
        }
        guard try container.decode(Int.self, forKey: .schemaVersion) == FinanceRecurringPaymentContract.schemaVersion else {
            throw FinanceRecurringValidationError.unsupportedVersion
        }
        try self.init(
            candidates: container.decode([FinanceRecurringPaymentCandidate].self, forKey: .candidates),
            exclusions: container.decode([FinanceRecurringExclusion].self, forKey: .exclusions),
            coverage: container.decode(FinanceRecurringCoverage.self, forKey: .coverage),
            timeZoneIdentifier: container.decode(String.self, forKey: .timeZoneIdentifier),
            detectorVersion: container.decode(String.self, forKey: .detectorVersion),
            generatedAt: container.decode(Date.self, forKey: .generatedAt)
        )
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(schemaVersion, forKey: .schemaVersion)
        try container.encode(candidates, forKey: .candidates)
        try container.encode(exclusions, forKey: .exclusions)
        try container.encode(coverage, forKey: .coverage)
        try container.encode(timeZoneIdentifier, forKey: .timeZoneIdentifier)
        try container.encode(detectorVersion, forKey: .detectorVersion)
        try container.encode(generatedAt, forKey: .generatedAt)
    }
}
