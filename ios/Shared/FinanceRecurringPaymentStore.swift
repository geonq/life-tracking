import Foundation

// MARK: - Durable local recurring metadata

public enum FinanceRecurringPaymentStoreError: Error, Equatable, Sendable {
    case applicationSupportUnavailable
    case readFailed
    case stateTooLarge
    case invalidEnvelope
    case writeFailed
    case revisionConflict
    case invalidOverride
    case invalidCache
}

extension FinanceRecurringPaymentStoreError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .applicationSupportUnavailable:
            return "Local recurring-payment storage is unavailable."
        case .readFailed:
            return "Local recurring-payment storage could not be read."
        case .stateTooLarge:
            return "Local recurring-payment storage exceeded its safe size limit."
        case .invalidEnvelope:
            return "Local recurring-payment storage is invalid and was not loaded."
        case .writeFailed:
            return "Recurring-payment changes could not be saved."
        case .revisionConflict:
            return "Recurring-payment state changed elsewhere. Reload it before saving."
        case .invalidOverride:
            return "That recurring-payment setting is invalid."
        case .invalidCache:
            return "Recurring-payment evidence could not be cached safely."
        }
    }
}

public struct FinanceRecurringEvidenceCache: Codable, Equatable, Sendable {
    public static let schemaVersion = 1

    public let schemaVersion: Int
    public let inputDigest: String
    public let assessment: FinanceRecurringPaymentAssessment
    public let savedAt: Date

    public init(
        inputDigest: String,
        assessment: FinanceRecurringPaymentAssessment,
        savedAt: Date = .now
    ) throws {
        guard inputDigest.count == 64,
              inputDigest.allSatisfy(\.isHexDigit),
              savedAt.timeIntervalSinceReferenceDate.isFinite,
              assessment.detectorVersion == FinanceRecurringPaymentContract.detectorVersion else {
            throw FinanceRecurringValidationError.invalidCache
        }
        self.schemaVersion = Self.schemaVersion
        self.inputDigest = inputDigest.lowercased()
        self.assessment = assessment
        self.savedAt = Date(timeIntervalSince1970: savedAt.timeIntervalSince1970.rounded(.down))
    }

    private enum CodingKeys: String, CodingKey, CaseIterable {
        case schemaVersion, inputDigest, assessment, savedAt
    }

    public init(from decoder: Decoder) throws {
        try rejectUnknownLifeOSKeys(decoder, allowed: Set(CodingKeys.allCases.map(\.stringValue)))
        let container = try decoder.container(keyedBy: CodingKeys.self)
        guard Set(container.allKeys) == Set(CodingKeys.allCases),
              try container.decode(Int.self, forKey: .schemaVersion) == Self.schemaVersion else {
            throw FinanceRecurringValidationError.invalidCache
        }
        try self.init(
            inputDigest: container.decode(String.self, forKey: .inputDigest),
            assessment: container.decode(FinanceRecurringPaymentAssessment.self, forKey: .assessment),
            savedAt: container.decode(Date.self, forKey: .savedAt)
        )
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(schemaVersion, forKey: .schemaVersion)
        try container.encode(inputDigest, forKey: .inputDigest)
        try container.encode(assessment, forKey: .assessment)
        try container.encode(savedAt, forKey: .savedAt)
    }
}

public struct FinanceRecurringPaymentStoreState: Codable, Equatable, Sendable {
    public static let schemaVersion = 1

    public let schemaVersion: Int
    public let financeTimeZoneIdentifier: String
    public let revision: Int
    public let overrides: [FinanceRecurringPaymentOverride]
    public let evidenceCache: FinanceRecurringEvidenceCache?

    public init(
        financeTimeZoneIdentifier: String = FinanceRecurringPaymentContract.defaultTimeZoneIdentifier,
        revision: Int = 0,
        overrides: [FinanceRecurringPaymentOverride] = [],
        evidenceCache: FinanceRecurringEvidenceCache? = nil
    ) throws {
        let timeZone = financeTimeZoneIdentifier.trimmingCharacters(in: .whitespacesAndNewlines)
        guard revision >= 0,
              revision <= 1_000_000_000,
              !timeZone.isEmpty,
              timeZone.utf8.count <= FinanceRecurringPaymentContract.maximumTimeZoneBytes,
              TimeZone(identifier: timeZone) != nil,
              overrides.count <= FinanceRecurringPaymentContract.maximumCandidates,
              Set(overrides.map(\.key.id)).count == overrides.count,
              overrides.allSatisfy({ $0.anchor?.timeZoneIdentifier == nil || $0.anchor?.timeZoneIdentifier == timeZone }),
              evidenceCache.map({ $0.assessment.timeZoneIdentifier == timeZone }) ?? true else {
            throw FinanceRecurringValidationError.invalidAssessment
        }
        self.schemaVersion = Self.schemaVersion
        self.financeTimeZoneIdentifier = timeZone
        self.revision = revision
        self.overrides = overrides.sorted { $0.key.id < $1.key.id }
        self.evidenceCache = evidenceCache
    }

    private enum CodingKeys: String, CodingKey, CaseIterable {
        case schemaVersion, financeTimeZoneIdentifier, revision, overrides, evidenceCache
    }

    public init(from decoder: Decoder) throws {
        try rejectUnknownLifeOSKeys(decoder, allowed: Set(CodingKeys.allCases.map(\.stringValue)))
        let container = try decoder.container(keyedBy: CodingKeys.self)
        guard Set(container.allKeys).contains(.schemaVersion),
              Set(container.allKeys).contains(.financeTimeZoneIdentifier),
              Set(container.allKeys).contains(.revision),
              Set(container.allKeys).contains(.overrides),
              Set(container.allKeys).isSubset(of: Set(CodingKeys.allCases)),
              try container.decode(Int.self, forKey: .schemaVersion) == Self.schemaVersion else {
            throw FinanceRecurringValidationError.unsupportedVersion
        }
        try self.init(
            financeTimeZoneIdentifier: container.decode(String.self, forKey: .financeTimeZoneIdentifier),
            revision: container.decode(Int.self, forKey: .revision),
            overrides: container.decode([FinanceRecurringPaymentOverride].self, forKey: .overrides),
            evidenceCache: container.decodeIfPresent(FinanceRecurringEvidenceCache.self, forKey: .evidenceCache)
        )
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(schemaVersion, forKey: .schemaVersion)
        try container.encode(financeTimeZoneIdentifier, forKey: .financeTimeZoneIdentifier)
        try container.encode(revision, forKey: .revision)
        try container.encode(overrides, forKey: .overrides)
        try container.encodeIfPresent(evidenceCache, forKey: .evidenceCache)
    }
}

/// Local-only recurring metadata. It has no network client, outbox, bearer
/// token, or copy of a transaction. Its cache is rebuildable and validated by
/// the detector input digest before a caller treats it as current.
public final class FinanceRecurringPaymentStore: @unchecked Sendable {
    public static let fileName = "finance-recurring-payments.json"
    public static let maximumStateBytes = 4 * 1024 * 1024

    private static let processTransactionLock = NSLock()

    public let fileURL: URL
    private let fileManager: FileManager

    public init(url: URL? = nil, fileManager: FileManager = .default) throws {
        self.fileManager = fileManager
        if let url {
            self.fileURL = url
        } else {
            self.fileURL = try Self.defaultURL(fileManager: fileManager)
        }
    }

    public static func defaultURL(fileManager: FileManager = .default) throws -> URL {
        guard let support = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else {
            throw FinanceRecurringPaymentStoreError.applicationSupportUnavailable
        }
        return support
            .appendingPathComponent("LifeOS", isDirectory: true)
            .appendingPathComponent(fileName, isDirectory: false)
    }

    public func load() throws -> FinanceRecurringPaymentStoreState {
        Self.processTransactionLock.lock()
        defer { Self.processTransactionLock.unlock() }
        return try loadUnlocked()
    }

    @discardableResult
    public func saveOverride(
        _ requestedOverride: FinanceRecurringPaymentOverride,
        expectedRevision: Int
    ) throws -> FinanceRecurringPaymentStoreState {
        Self.processTransactionLock.lock()
        defer { Self.processTransactionLock.unlock() }
        let current = try loadUnlocked()
        guard current.revision == expectedRevision else { throw FinanceRecurringPaymentStoreError.revisionConflict }
        let previous = current.overrides.first { $0.key == requestedOverride.key }
        let storedOverride: FinanceRecurringPaymentOverride
        do {
            storedOverride = try FinanceRecurringPaymentOverride(
                key: requestedOverride.key,
                cadence: requestedOverride.cadence,
                anchor: requestedOverride.anchor,
                status: requestedOverride.status,
                localRevision: (previous?.localRevision ?? 0) + 1,
                updatedAt: requestedOverride.updatedAt
            )
        } catch {
            throw FinanceRecurringPaymentStoreError.invalidOverride
        }
        var overrides = current.overrides.filter { $0.key != requestedOverride.key }
        overrides.append(storedOverride)
        let next = try FinanceRecurringPaymentStoreState(
            financeTimeZoneIdentifier: current.financeTimeZoneIdentifier,
            revision: current.revision + 1,
            overrides: overrides,
            evidenceCache: current.evidenceCache
        )
        try saveUnlocked(next)
        return next
    }

    @discardableResult
    public func clearOverride(
        for key: FinanceRecurringPaymentKey,
        expectedRevision: Int
    ) throws -> FinanceRecurringPaymentStoreState {
        Self.processTransactionLock.lock()
        defer { Self.processTransactionLock.unlock() }
        let current = try loadUnlocked()
        guard current.revision == expectedRevision else { throw FinanceRecurringPaymentStoreError.revisionConflict }
        guard current.overrides.contains(where: { $0.key == key }) else { return current }
        let next = try FinanceRecurringPaymentStoreState(
            financeTimeZoneIdentifier: current.financeTimeZoneIdentifier,
            revision: current.revision + 1,
            overrides: current.overrides.filter { $0.key != key },
            evidenceCache: current.evidenceCache
        )
        try saveUnlocked(next)
        return next
    }

    /// Stores only a rebuildable assessment cache. The expected revision keeps
    /// a detection result from overwriting a user's newer override.
    @discardableResult
    public func saveAssessment(
        _ assessment: FinanceRecurringPaymentAssessment,
        inputDigest: String,
        expectedRevision: Int
    ) throws -> FinanceRecurringPaymentStoreState {
        Self.processTransactionLock.lock()
        defer { Self.processTransactionLock.unlock() }
        let current = try loadUnlocked()
        guard current.revision == expectedRevision else { throw FinanceRecurringPaymentStoreError.revisionConflict }
        let cache: FinanceRecurringEvidenceCache
        do {
            cache = try FinanceRecurringEvidenceCache(inputDigest: inputDigest, assessment: assessment)
        } catch {
            throw FinanceRecurringPaymentStoreError.invalidCache
        }
        let next = try FinanceRecurringPaymentStoreState(
            financeTimeZoneIdentifier: assessment.timeZoneIdentifier,
            revision: current.revision + 1,
            overrides: current.overrides,
            evidenceCache: cache
        )
        try saveUnlocked(next)
        return next
    }

    private func loadUnlocked() throws -> FinanceRecurringPaymentStoreState {
        guard fileManager.fileExists(atPath: fileURL.path) else {
            return try FinanceRecurringPaymentStoreState()
        }
        let data = try readBoundedData()
        do {
            let state = try JSONDecoder.lifeOS.decode(FinanceRecurringPaymentStoreState.self, from: data)
            guard state.schemaVersion == FinanceRecurringPaymentStoreState.schemaVersion else {
                throw FinanceRecurringPaymentStoreError.invalidEnvelope
            }
            return state
        } catch let error as FinanceRecurringPaymentStoreError {
            throw error
        } catch {
            throw FinanceRecurringPaymentStoreError.invalidEnvelope
        }
    }

    private func readBoundedData() throws -> Data {
        let handle: FileHandle
        do {
            handle = try FileHandle(forReadingFrom: fileURL)
        } catch {
            throw FinanceRecurringPaymentStoreError.readFailed
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
            throw FinanceRecurringPaymentStoreError.readFailed
        }
        guard data.count <= Self.maximumStateBytes else {
            throw FinanceRecurringPaymentStoreError.stateTooLarge
        }
        return data
    }

    private func saveUnlocked(_ state: FinanceRecurringPaymentStoreState) throws {
        let data: Data
        do {
            let encoder = JSONEncoder.lifeOS
            encoder.outputFormatting = [.sortedKeys]
            data = try encoder.encode(state)
        } catch {
            throw FinanceRecurringPaymentStoreError.invalidEnvelope
        }
        guard data.count <= Self.maximumStateBytes else {
            throw FinanceRecurringPaymentStoreError.stateTooLarge
        }
        do {
            try atomicReplace(data)
        } catch {
            throw FinanceRecurringPaymentStoreError.writeFailed
        }
    }

    private func atomicReplace(_ data: Data) throws {
        let directory = fileURL.deletingLastPathComponent()
        try fileManager.createDirectory(
            at: directory,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        let temporary = directory.appendingPathComponent(
            ".\(fileURL.lastPathComponent).\(UUID().uuidString).tmp",
            isDirectory: false
        )
        defer {
            if fileManager.fileExists(atPath: temporary.path) {
                try? fileManager.removeItem(at: temporary)
            }
        }

#if os(iOS)
        try data.write(to: temporary, options: [.atomic, .completeFileProtection])
#else
        try data.write(to: temporary, options: [.atomic])
#endif
        try? fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: temporary.path)

        if fileManager.fileExists(atPath: fileURL.path) {
            _ = try fileManager.replaceItemAt(fileURL, withItemAt: temporary)
        } else {
            try fileManager.moveItem(at: temporary, to: fileURL)
        }
        try? fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: fileURL.path)
    }
}
