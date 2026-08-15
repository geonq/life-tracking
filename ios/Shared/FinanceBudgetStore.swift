import Foundation

// MARK: - Durable local storage for monthly category budgets

/// Stable, user-visible failures for the local Finance budget store. Mirrors
/// `NutritionGoalStoreError`: no filesystem paths or decoder details leak
/// into the public error surface.
public enum FinanceBudgetStoreError: Error, Equatable, Sendable {
    case applicationSupportUnavailable
    case readFailed
    case invalidEnvelope
    case writeFailed
    case notBudgetable
}

extension FinanceBudgetStoreError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .applicationSupportUnavailable:
            return "Local Finance budget storage is unavailable."
        case .readFailed:
            return "Local Finance budget storage could not be read."
        case .invalidEnvelope:
            return "Local Finance budget storage is invalid and was not loaded."
        case .writeFailed:
            return "Budget changes could not be saved."
        case .notBudgetable:
            return "Income is not a spending category and cannot carry a budget."
        }
    }
}

/// Versioned on-disk envelope. An absent file decodes to an honest empty
/// state (no budgets); this is not the same as an invalid file, which
/// throws. Mirrors `NutritionGoalStoreEnvelope`.
public struct FinanceBudgetStoreEnvelope: Codable, Equatable, Sendable {
    public static let currentSchemaVersion = 1

    public let schemaVersion: Int
    public let budgets: [FinanceCategoryBudget]

    private enum CodingKeys: String, CodingKey {
        case schemaVersion, budgets
    }

    public init(budgets: [FinanceCategoryBudget] = []) {
        self.schemaVersion = Self.currentSchemaVersion
        self.budgets = budgets
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        schemaVersion = try container.decode(Int.self, forKey: .schemaVersion)
        budgets = try container.decodeIfPresent([FinanceCategoryBudget].self, forKey: .budgets) ?? []
    }
}

/// Atomic, Application-Support-backed local storage for monthly category
/// budgets.
///
/// Structurally mirrors `NutritionGoalStore`: an in-process transaction lock
/// guards read-modify-write cycles, writes go through a temp file plus
/// `replaceItemAt`/`moveItem`, and iOS writes request
/// `.completeFileProtection`. The URL is injectable only for deterministic
/// tests; the default path has no temporary-directory or home-directory
/// fallback — if Application Support cannot be resolved, initialization
/// fails closed.
///
/// Budgets are never mutated in place: `setBudget` always appends, so the
/// full dated history remains inspectable via `history()`, and
/// `currentBudgets(on:)` resolves "the budget in effect per category" purely
/// by picking, for each category independently, the latest entry whose
/// `effectiveFrom` is on or before the requested day.
public final class FinanceBudgetStore: @unchecked Sendable {
    public static let fileName = "finance-budgets.json"
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
            throw FinanceBudgetStoreError.applicationSupportUnavailable
        }
        return support
            .appendingPathComponent("LifeOS", isDirectory: true)
            .appendingPathComponent(fileName, isDirectory: false)
    }

    /// Loads the full dated budget history, unsorted-guaranteed only insofar
    /// as insertion order; callers that need chronological order should use
    /// `history()`. An absent file returns an empty array rather than
    /// throwing or fabricating data.
    public func load() throws -> [FinanceCategoryBudget] {
        Self.processTransactionLock.lock()
        defer { Self.processTransactionLock.unlock() }
        return try loadUnlocked()
    }

    /// Appends a new dated budget for `budget.category`. This is the only
    /// way to change a limit: existing entries are never edited or removed,
    /// preserving the full history of what was in effect on any given day.
    /// Throws `.notBudgetable` for `.income` rather than silently accepting
    /// it — income is not a spending category.
    public func setBudget(_ budget: FinanceCategoryBudget) throws {
        guard budget.category.isBudgetable else {
            throw FinanceBudgetStoreError.notBudgetable
        }
        Self.processTransactionLock.lock()
        defer { Self.processTransactionLock.unlock() }
        var budgets = try loadUnlocked()
        budgets.append(budget)
        try saveUnlocked(budgets)
    }

    /// The full dated budget history, sorted by `effectiveFrom` ascending.
    public func history() throws -> [FinanceCategoryBudget] {
        try load().sorted { $0.effectiveFrom < $1.effectiveFrom }
    }

    /// The budget in effect on the given day, per category: for each
    /// category with at least one qualifying entry, the latest one (by
    /// `effectiveFrom`) whose `effectiveFrom` is on or before the end of
    /// that calendar day. Categories with no qualifying entry are simply
    /// absent from the result — an honest "no budget set," never a
    /// fabricated zero-limit entry. Result is keyed by category with at
    /// most one entry each.
    public func currentBudgets(on date: Date, calendar: Calendar = .current) throws -> [FinanceTransactionCategory: FinanceCategoryBudget] {
        guard let endOfDay = calendar.date(byAdding: DateComponents(day: 1, second: -1), to: calendar.startOfDay(for: date)) else {
            return [:]
        }
        let eligible = try load().filter { $0.effectiveFrom <= endOfDay }
        var latestByCategory: [FinanceTransactionCategory: FinanceCategoryBudget] = [:]
        for budget in eligible {
            if let existing = latestByCategory[budget.category] {
                if budget.effectiveFrom > existing.effectiveFrom {
                    latestByCategory[budget.category] = budget
                }
            } else {
                latestByCategory[budget.category] = budget
            }
        }
        return latestByCategory
    }

    /// Removes every historical entry for `category`, leaving it with an
    /// honest "no budget set" state. This is a full removal, not a dated
    /// append of a zero-limit entry — a zero limit is a real value distinct
    /// from "unset."
    public func remove(category: FinanceTransactionCategory) throws {
        Self.processTransactionLock.lock()
        defer { Self.processTransactionLock.unlock() }
        var budgets = try loadUnlocked()
        budgets.removeAll { $0.category == category }
        try saveUnlocked(budgets)
    }

    private func loadUnlocked() throws -> [FinanceCategoryBudget] {
        guard fileManager.fileExists(atPath: fileURL.path) else { return [] }
        let data: Data
        do {
            data = try Data(contentsOf: fileURL)
        } catch {
            throw FinanceBudgetStoreError.readFailed
        }
        do {
            let envelope = try JSONDecoder.financeBudget.decode(FinanceBudgetStoreEnvelope.self, from: data)
            guard envelope.schemaVersion == FinanceBudgetStoreEnvelope.currentSchemaVersion else {
                throw FinanceBudgetStoreError.invalidEnvelope
            }
            return envelope.budgets
        } catch {
            throw FinanceBudgetStoreError.invalidEnvelope
        }
    }

    private func saveUnlocked(_ budgets: [FinanceCategoryBudget]) throws {
        let data: Data
        do {
            data = try JSONEncoder.financeBudget.encode(FinanceBudgetStoreEnvelope(budgets: budgets))
        } catch {
            throw FinanceBudgetStoreError.invalidEnvelope
        }
        do {
            try atomicReplace(data)
        } catch {
            throw FinanceBudgetStoreError.writeFailed
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
    static let financeBudget: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }()
}

private extension JSONEncoder {
    static let financeBudget: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }()
}
