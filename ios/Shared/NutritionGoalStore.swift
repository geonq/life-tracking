import Foundation

// MARK: - Durable local nutrition goal storage

/// Stable, user-visible failures for the local nutrition goal store. The
/// store intentionally does not expose filesystem paths or decoder details
/// in its public errors, mirroring `NutritionMealStoreError`.
public enum NutritionGoalStoreError: Error, Equatable, Sendable {
    case applicationSupportUnavailable
    case readFailed
    case invalidEnvelope
    case writeFailed
}

extension NutritionGoalStoreError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .applicationSupportUnavailable:
            return "Local goal storage is unavailable."
        case .readFailed:
            return "Local goal storage could not be read."
        case .invalidEnvelope:
            return "Local goal storage is invalid and was not loaded."
        case .writeFailed:
            return "Local goal changes could not be saved."
        }
    }
}

/// Versioned on-disk envelope. An absent file decodes to an honest empty
/// state (no goals); this is not the same as an invalid file, which throws.
public struct NutritionGoalStoreEnvelope: Codable, Equatable, Sendable {
    public static let currentSchemaVersion = 1

    public let schemaVersion: Int
    public let goals: [NutritionGoal]

    private enum CodingKeys: String, CodingKey {
        case schemaVersion, goals
    }

    public init(goals: [NutritionGoal] = []) {
        self.schemaVersion = Self.currentSchemaVersion
        self.goals = goals
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        schemaVersion = try container.decode(Int.self, forKey: .schemaVersion)
        // `goals` is decoded with `decodeIfPresent` so a minimal/older
        // envelope shape that predates this field still decodes to an empty
        // list rather than throwing.
        goals = try container.decodeIfPresent([NutritionGoal].self, forKey: .goals) ?? []
    }
}

/// Atomic, Application-Support-backed local nutrition goal storage.
///
/// Structurally mirrors `NutritionMealStore`: an in-process transaction lock
/// guards read-modify-write cycles, writes go through a temp file plus
/// `replaceItemAt`/`moveItem`, and iOS writes request
/// `.completeFileProtection`. The URL is injectable only for deterministic
/// tests; the default path has no temporary-directory or home-directory
/// fallback — if Application Support cannot be resolved, initialization
/// fails closed.
///
/// Goals are never mutated in place: `setGoal` always appends, so the full
/// dated history remains inspectable via `history()`, and `currentGoal(on:)`
/// resolves "the goal in effect" purely by picking the latest entry whose
/// `effectiveFrom` is on or before the requested day.
public final class NutritionGoalStore: @unchecked Sendable {
    public static let fileName = "nutrition-goals.json"
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
            throw NutritionGoalStoreError.applicationSupportUnavailable
        }
        return support
            .appendingPathComponent("LifeOS", isDirectory: true)
            .appendingPathComponent(fileName, isDirectory: false)
    }

    /// Loads the full dated goal history, unsorted-guaranteed only insofar
    /// as insertion order; callers that need chronological order should use
    /// `history()`. An absent file returns an empty array rather than
    /// throwing or fabricating data.
    public func load() throws -> [NutritionGoal] {
        Self.processTransactionLock.lock()
        defer { Self.processTransactionLock.unlock() }
        return try loadUnlocked()
    }

    /// Appends a new dated goal. This is the only way to change a target:
    /// existing entries are never edited or removed, preserving the full
    /// history of what was in effect on any given day.
    public func setGoal(_ goal: NutritionGoal) throws {
        Self.processTransactionLock.lock()
        defer { Self.processTransactionLock.unlock() }
        var goals = try loadUnlocked()
        goals.append(goal)
        try saveUnlocked(goals)
    }

    /// The full dated goal history, sorted by `effectiveFrom` ascending.
    public func history() throws -> [NutritionGoal] {
        try load().sorted { $0.effectiveFrom < $1.effectiveFrom }
    }

    /// The goal in effect on the given day: the latest entry (by
    /// `effectiveFrom`) whose `effectiveFrom` is on or before the end of
    /// that calendar day. Returns `nil` (honest "no goal set") if no entry
    /// qualifies — never a fabricated default.
    public func currentGoal(on date: Date, calendar: Calendar = .current) throws -> NutritionGoal? {
        guard let endOfDay = calendar.date(byAdding: DateComponents(day: 1, second: -1), to: calendar.startOfDay(for: date)) else {
            return nil
        }
        let eligible = try load().filter { $0.effectiveFrom <= endOfDay }
        return eligible.max { $0.effectiveFrom < $1.effectiveFrom }
    }

    private func loadUnlocked() throws -> [NutritionGoal] {
        guard fileManager.fileExists(atPath: fileURL.path) else { return [] }
        let data: Data
        do {
            data = try Data(contentsOf: fileURL)
        } catch {
            throw NutritionGoalStoreError.readFailed
        }
        do {
            let envelope = try JSONDecoder.nutritionGoal.decode(NutritionGoalStoreEnvelope.self, from: data)
            guard envelope.schemaVersion == NutritionGoalStoreEnvelope.currentSchemaVersion else {
                throw NutritionGoalStoreError.invalidEnvelope
            }
            return envelope.goals
        } catch {
            throw NutritionGoalStoreError.invalidEnvelope
        }
    }

    private func saveUnlocked(_ goals: [NutritionGoal]) throws {
        let data: Data
        do {
            data = try JSONEncoder.nutritionGoal.encode(NutritionGoalStoreEnvelope(goals: goals))
        } catch {
            throw NutritionGoalStoreError.invalidEnvelope
        }
        do {
            try atomicReplace(data)
        } catch {
            throw NutritionGoalStoreError.writeFailed
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
    static let nutritionGoal: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }()
}

private extension JSONEncoder {
    static let nutritionGoal: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }()
}
