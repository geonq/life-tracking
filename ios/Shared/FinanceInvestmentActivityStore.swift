import Foundation

// MARK: - Durable local investment ledger storage

public enum FinanceInvestmentActivityStoreError: Error, Equatable, Sendable {
    case applicationSupportUnavailable
    case readFailed
    case invalidEnvelope
    case stateTooLarge
    case writeFailed
    case revisionConflict
    case invalidImport
    case snapshotConflict
}

extension FinanceInvestmentActivityStoreError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .applicationSupportUnavailable: return "Local investment storage is unavailable."
        case .readFailed: return "Local investment storage could not be read."
        case .invalidEnvelope: return "Local investment storage is invalid and was not loaded."
        case .stateTooLarge: return "Local investment storage exceeded its safe size limit."
        case .writeFailed: return "The investment ledger could not be saved."
        case .revisionConflict: return "Investment state changed elsewhere. Reload it before saving."
        case .invalidImport: return "The investment import could not be stored safely."
        case .snapshotConflict: return "That investment snapshot conflicts with existing account evidence."
        }
    }
}

public struct FinanceInvestmentActivityStoreState: Codable, Equatable, Sendable {
    public static let schemaVersion = 1

    public let schemaVersion: Int
    public let revision: Int
    public let ledger: FinanceInvestmentLedger

    public init(
        revision: Int = 0,
        ledger: FinanceInvestmentLedger? = nil
    ) throws {
        guard revision >= 0, revision < FinanceInvestmentContract.maximumRevision else {
            throw FinanceInvestmentActivityStoreError.invalidEnvelope
        }
        self.schemaVersion = Self.schemaVersion
        self.revision = revision
        self.ledger = try ledger ?? FinanceInvestmentLedger()
    }

    private enum CodingKeys: String, CodingKey, CaseIterable {
        case schemaVersion, revision, ledger
    }

    public init(from decoder: Decoder) throws {
        try rejectUnknownLifeOSKeys(decoder, allowed: Set(CodingKeys.allCases.map(\.stringValue)))
        let container = try decoder.container(keyedBy: CodingKeys.self)
        guard Set(container.allKeys) == Set(CodingKeys.allCases),
              try container.decode(Int.self, forKey: .schemaVersion) == Self.schemaVersion else {
            throw FinanceInvestmentActivityStoreError.invalidEnvelope
        }
        do {
            try self.init(
                revision: container.decode(Int.self, forKey: .revision),
                ledger: container.decode(FinanceInvestmentLedger.self, forKey: .ledger)
            )
        } catch let error as FinanceInvestmentActivityStoreError {
            throw error
        } catch {
            throw FinanceInvestmentActivityStoreError.invalidEnvelope
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(schemaVersion, forKey: .schemaVersion)
        try container.encode(revision, forKey: .revision)
        try container.encode(ledger, forKey: .ledger)
    }
}

/// Local-only storage. It has no network outbox and no relationship to
/// `FinanceImportedTransactionStore`; merging an activity result cannot alter
/// bank transactions or bank-account totals.
public final class FinanceInvestmentActivityStore: @unchecked Sendable {
    public static let fileName = "finance-investment-activity.json"
    public static let maximumStateBytes = 8 * 1024 * 1024

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
            throw FinanceInvestmentActivityStoreError.applicationSupportUnavailable
        }
        return support
            .appendingPathComponent("LifeOS", isDirectory: true)
            .appendingPathComponent(fileName, isDirectory: false)
    }

    public func load() throws -> FinanceInvestmentActivityStoreState {
        Self.processTransactionLock.lock()
        defer { Self.processTransactionLock.unlock() }
        return try loadUnlocked()
    }

    /// Merges a verified import by stable activity identity. Re-importing the
    /// same file is a no-op, including revision and receipt count.
    @discardableResult
    public func merge(
        _ result: FinanceRobinhoodImportResult,
        expectedRevision: Int? = nil
    ) throws -> FinanceInvestmentActivityStoreState {
        Self.processTransactionLock.lock()
        defer { Self.processTransactionLock.unlock() }
        let current = try loadUnlocked()
        if let expectedRevision, expectedRevision != current.revision {
            throw FinanceInvestmentActivityStoreError.revisionConflict
        }
        let receipt: FinanceInvestmentImportReceipt
        do {
            receipt = try FinanceInvestmentImportReceipt(
                evidence: result.evidence,
                activities: result.activities
            )
        } catch {
            throw FinanceInvestmentActivityStoreError.invalidImport
        }
        if current.ledger.importReceipts.contains(where: { $0.id == receipt.id }) {
            return current
        }

        var activitiesByID = Dictionary(uniqueKeysWithValues: current.ledger.activities.map { ($0.id, $0) })
        for activity in result.activities {
            if let existing = activitiesByID[activity.id], existing != activity {
                throw FinanceInvestmentActivityStoreError.invalidImport
            }
            activitiesByID[activity.id] = activity
        }
        let receipts = current.ledger.importReceipts + [receipt]
        let ledger: FinanceInvestmentLedger
        do {
            ledger = try FinanceInvestmentLedger(
                activities: Array(activitiesByID.values),
                accountSnapshots: current.ledger.accountSnapshots,
                importReceipts: receipts
            )
        } catch {
            throw FinanceInvestmentActivityStoreError.invalidImport
        }
        guard !current.revision.addingReportingOverflow(1).overflow else {
            throw FinanceInvestmentActivityStoreError.invalidEnvelope
        }
        let next: FinanceInvestmentActivityStoreState
        do {
            next = try FinanceInvestmentActivityStoreState(
                revision: current.revision + 1,
                ledger: ledger
            )
        } catch {
            throw FinanceInvestmentActivityStoreError.invalidImport
        }
        try saveUnlocked(next)
        return next
    }

    /// Stores a separately verified account snapshot. This is intentionally a
    /// distinct operation from activity import because a CSV activity row is
    /// not evidence of cash or holdings valuation.
    @discardableResult
    public func upsertAccountSnapshot(
        _ snapshot: FinanceInvestmentAccountSnapshot,
        expectedRevision: Int? = nil
    ) throws -> FinanceInvestmentActivityStoreState {
        Self.processTransactionLock.lock()
        defer { Self.processTransactionLock.unlock() }
        let current = try loadUnlocked()
        if let expectedRevision, expectedRevision != current.revision {
            throw FinanceInvestmentActivityStoreError.revisionConflict
        }
        if let existing = current.ledger.accountSnapshots.first(where: {
            $0.source == snapshot.source && $0.observedAt == snapshot.observedAt
        }) {
            if existing == snapshot { return current }
            throw FinanceInvestmentActivityStoreError.snapshotConflict
        }
        var snapshots = current.ledger.accountSnapshots.filter {
            !($0.source == snapshot.source && $0.observedAt == snapshot.observedAt)
        }
        snapshots.append(snapshot)
        let ledger: FinanceInvestmentLedger
        do {
            ledger = try FinanceInvestmentLedger(
                activities: current.ledger.activities,
                accountSnapshots: snapshots,
                importReceipts: current.ledger.importReceipts
            )
        } catch {
            throw FinanceInvestmentActivityStoreError.snapshotConflict
        }
        guard !current.revision.addingReportingOverflow(1).overflow else {
            throw FinanceInvestmentActivityStoreError.invalidEnvelope
        }
        let next: FinanceInvestmentActivityStoreState
        do {
            next = try FinanceInvestmentActivityStoreState(
                revision: current.revision + 1,
                ledger: ledger
            )
        } catch {
            throw FinanceInvestmentActivityStoreError.snapshotConflict
        }
        try saveUnlocked(next)
        return next
    }

    private func loadUnlocked() throws -> FinanceInvestmentActivityStoreState {
        guard fileManager.fileExists(atPath: fileURL.path) else {
            do { return try FinanceInvestmentActivityStoreState() }
            catch { throw FinanceInvestmentActivityStoreError.invalidEnvelope }
        }
        let data = try readBoundedData()
        do {
            return try JSONDecoder.lifeOS.decode(FinanceInvestmentActivityStoreState.self, from: data)
        } catch let error as FinanceInvestmentActivityStoreError {
            throw error
        } catch {
            throw FinanceInvestmentActivityStoreError.invalidEnvelope
        }
    }

    private func readBoundedData() throws -> Data {
        let handle: FileHandle
        do { handle = try FileHandle(forReadingFrom: fileURL) }
        catch { throw FinanceInvestmentActivityStoreError.readFailed }
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
            throw FinanceInvestmentActivityStoreError.readFailed
        }
        guard data.count <= Self.maximumStateBytes else {
            throw FinanceInvestmentActivityStoreError.stateTooLarge
        }
        return data
    }

    private func saveUnlocked(_ state: FinanceInvestmentActivityStoreState) throws {
        let data: Data
        do {
            let encoder = JSONEncoder.lifeOS
            encoder.outputFormatting = [.sortedKeys]
            data = try encoder.encode(state)
        } catch {
            throw FinanceInvestmentActivityStoreError.invalidEnvelope
        }
        guard data.count <= Self.maximumStateBytes else {
            throw FinanceInvestmentActivityStoreError.stateTooLarge
        }
        do { try atomicReplace(data) }
        catch { throw FinanceInvestmentActivityStoreError.writeFailed }
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
            if fileManager.fileExists(atPath: temporary.path) { try? fileManager.removeItem(at: temporary) }
        }
#if os(iOS)
        try data.write(to: temporary, options: [.atomic, .completeFileProtection])
#else
        try data.write(to: temporary, options: [.atomic])
#endif
        try fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: temporary.path)
        if fileManager.fileExists(atPath: fileURL.path) {
            _ = try fileManager.replaceItemAt(fileURL, withItemAt: temporary)
        } else {
            try fileManager.moveItem(at: temporary, to: fileURL)
        }
        try fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: fileURL.path)
    }
}
