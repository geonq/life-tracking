import Foundation

// MARK: - Durable local storage for manually imported bank-statement transactions

/// Stable, user-visible failures for the local Finance import store. Mirrors
/// `NutritionMealStoreError`: no filesystem paths or decoder details leak
/// into the public error surface.
public enum FinanceImportedTransactionStoreError: Error, Equatable, Sendable {
    case applicationSupportUnavailable
    case readFailed
    case invalidEnvelope
    case writeFailed
    case transactionNotFound
}

/// Result of an import write. A replay is successful but reports duplicate
/// rows explicitly; a source correction with the same stable identity is
/// reported as an update rather than silently discarded.
public struct FinanceImportSaveResult: Equatable, Sendable {
    public let requestedCount: Int
    public let insertedCount: Int
    public let updatedCount: Int
    public let duplicateCount: Int
    public let storedCount: Int

    public init(
        requestedCount: Int,
        insertedCount: Int,
        updatedCount: Int = 0,
        duplicateCount: Int,
        storedCount: Int
    ) {
        self.requestedCount = max(requestedCount, 0)
        self.insertedCount = max(insertedCount, 0)
        self.updatedCount = max(updatedCount, 0)
        self.duplicateCount = max(duplicateCount, 0)
        self.storedCount = max(storedCount, 0)
    }
}

extension FinanceImportedTransactionStoreError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .applicationSupportUnavailable:
            return "Local Finance import storage is unavailable."
        case .readFailed:
            return "Local Finance import storage could not be read."
        case .invalidEnvelope:
            return "Local Finance import storage is invalid and was not loaded."
        case .writeFailed:
            return "Imported transaction changes could not be saved."
        case .transactionNotFound:
            return "The imported transaction to remove was not found."
        }
    }
}

/// Versioned on-disk envelope. An absent file decodes to an honest empty
/// state (no imported transactions); this is not the same as an invalid
/// file, which throws. Mirrors `NutritionMealStoreEnvelope`.
public struct FinanceImportedTransactionStoreEnvelope: Codable, Equatable, Sendable {
    public static let currentSchemaVersion = 1

    public let schemaVersion: Int
    public let transactions: [FinanceImportedTransaction]

    private enum CodingKeys: String, CodingKey {
        case schemaVersion, transactions
    }

    public init(transactions: [FinanceImportedTransaction] = []) {
        self.schemaVersion = Self.currentSchemaVersion
        self.transactions = transactions
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        schemaVersion = try container.decode(Int.self, forKey: .schemaVersion)
        transactions = try container.decodeIfPresent([FinanceImportedTransaction].self, forKey: .transactions) ?? []
    }
}

/// Atomic, Application-Support-backed local storage for manually imported
/// bank-statement transactions. Structurally mirrors `NutritionMealStore`:
/// an in-process transaction lock guards read-modify-write cycles, writes go
/// through a temp file plus `replaceItemAt`/`moveItem`, and iOS writes
/// request `.completeFileProtection`. The URL is injectable only for
/// deterministic tests; the default path has no temporary-directory or
/// home-directory fallback — if Application Support cannot be resolved,
/// initialization fails closed.
public final class FinanceImportedTransactionStore: @unchecked Sendable {
    public static let fileName = "finance-imported-transactions.json"
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
        guard let support = fileManager.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first else {
            throw FinanceImportedTransactionStoreError.applicationSupportUnavailable
        }
        return support
            .appendingPathComponent("LifeOS", isDirectory: true)
            .appendingPathComponent(fileName, isDirectory: false)
    }

    /// Loads all durable imported transactions. An absent file returns an
    /// empty array rather than throwing or fabricating data.
    public func all() throws -> [FinanceImportedTransaction] {
        Self.processTransactionLock.lock()
        defer { Self.processTransactionLock.unlock() }
        return try loadUnlocked()
    }

    /// Adds the given transactions (already parsed and confirmed by the user
    /// via the import preview) to the durable store. Stable importer IDs make
    /// retrying the same CSV idempotent while allowing source corrections to
    /// replace the old observation. Existing user category overrides survive
    /// an incoming row that has no explicit category.
    @discardableResult
    public func add(_ transactions: [FinanceImportedTransaction]) throws -> FinanceImportSaveResult {
        guard !transactions.isEmpty else {
            return FinanceImportSaveResult(
                requestedCount: 0,
                insertedCount: 0,
                duplicateCount: 0,
                storedCount: try all().count
            )
        }
        Self.processTransactionLock.lock()
        defer { Self.processTransactionLock.unlock() }
        var existing = try loadUnlocked()
        var indexByID: [UUID: Int] = [:]
        for (index, transaction) in existing.enumerated() {
            indexByID[transaction.id] = index
        }
        var seenIncomingIDs = Set<UUID>()
        var additions: [FinanceImportedTransaction] = []
        var updatedCount = 0
        var duplicateCount = 0
        var changed = false

        for incoming in transactions {
            guard seenIncomingIDs.insert(incoming.id).inserted else {
                duplicateCount += 1
                continue
            }
            if let index = indexByID[incoming.id] {
                var candidate = incoming
                if candidate.category == nil {
                    candidate.category = existing[index].category
                }
                if existing[index].hasSameSourceObservation(as: candidate),
                   existing[index].category == candidate.category {
                    duplicateCount += 1
                } else {
                    existing[index] = candidate
                    updatedCount += 1
                    changed = true
                }
            } else {
                indexByID[incoming.id] = existing.count + additions.count
                additions.append(incoming)
                changed = true
            }
        }
        let result = FinanceImportSaveResult(
            requestedCount: transactions.count,
            insertedCount: additions.count,
            updatedCount: updatedCount,
            duplicateCount: duplicateCount,
            storedCount: existing.count + additions.count
        )
        guard changed else { return result }
        existing.append(contentsOf: additions)
        try saveUnlocked(existing)
        return result
    }

    /// Removes a single imported transaction by id.
    public func remove(id: UUID) throws {
        Self.processTransactionLock.lock()
        defer { Self.processTransactionLock.unlock() }
        var existing = try loadUnlocked()
        guard let index = existing.firstIndex(where: { $0.id == id }) else {
            throw FinanceImportedTransactionStoreError.transactionNotFound
        }
        existing.remove(at: index)
        try saveUnlocked(existing)
    }

    /// Persists a canonical category override for one imported transaction.
    /// Passing `nil` clears the override and restores the parsed provider
    /// category (then the normal heuristic fallback). The enum boundary
    /// prevents an arbitrary provider label from becoming a saved LifeOS
    /// category.
    public func setCategory(_ category: FinanceTransactionCategory?, for id: UUID) throws {
        Self.processTransactionLock.lock()
        defer { Self.processTransactionLock.unlock() }
        var existing = try loadUnlocked()
        guard let index = existing.firstIndex(where: { $0.id == id }) else {
            throw FinanceImportedTransactionStoreError.transactionNotFound
        }
        existing[index].category = category?.rawValue
        try saveUnlocked(existing)
    }

    /// Explicit spelling for the destructive part of category editing. It
    /// clears only the user override; a parsed provider category remains
    /// available to the precedence resolver.
    public func clearCategoryOverride(for id: UUID) throws {
        try setCategory(nil, for: id)
    }

    /// Removes every imported transaction, leaving an honest empty store.
    public func clearAll() throws {
        Self.processTransactionLock.lock()
        defer { Self.processTransactionLock.unlock() }
        try saveUnlocked([])
    }

    /// Imported transactions whose `bookedAt` falls within `interval`, sorted
    /// by `bookedAt` ascending. `nil` interval returns every transaction.
    public func transactions(in interval: DateInterval?) throws -> [FinanceImportedTransaction] {
        let existing = try all()
        let filtered = interval.map { range in existing.filter { range.contains($0.bookedAt) } } ?? existing
        return filtered.sorted { $0.bookedAt < $1.bookedAt }
    }

    private func loadUnlocked() throws -> [FinanceImportedTransaction] {
        guard fileManager.fileExists(atPath: fileURL.path) else { return [] }
        let data: Data
        do {
            data = try Data(contentsOf: fileURL)
        } catch {
            throw FinanceImportedTransactionStoreError.readFailed
        }
        do {
            let envelope = try JSONDecoder.financeImportedTransaction.decode(FinanceImportedTransactionStoreEnvelope.self, from: data)
            guard envelope.schemaVersion == FinanceImportedTransactionStoreEnvelope.currentSchemaVersion else {
                throw FinanceImportedTransactionStoreError.invalidEnvelope
            }
            return envelope.transactions
        } catch {
            throw FinanceImportedTransactionStoreError.invalidEnvelope
        }
    }

    private func saveUnlocked(_ transactions: [FinanceImportedTransaction]) throws {
        let data: Data
        do {
            data = try JSONEncoder.financeImportedTransaction.encode(FinanceImportedTransactionStoreEnvelope(transactions: transactions))
        } catch {
            throw FinanceImportedTransactionStoreError.invalidEnvelope
        }
        do {
            try atomicReplace(data)
        } catch {
            throw FinanceImportedTransactionStoreError.writeFailed
        }
    }

    private func atomicReplace(_ data: Data) throws {
        let directory = fileURL.deletingLastPathComponent()
        try fileManager.createDirectory(
            at: directory,
            withIntermediateDirectories: true,
            attributes: nil
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

        if fileManager.fileExists(atPath: fileURL.path) {
            _ = try fileManager.replaceItemAt(fileURL, withItemAt: temporary)
        } else {
            try fileManager.moveItem(at: temporary, to: fileURL)
        }
    }
}

private extension JSONDecoder {
    static let financeImportedTransaction: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }()
}

private extension JSONEncoder {
    static let financeImportedTransaction: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }()
}
