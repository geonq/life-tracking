import Foundation

// MARK: - Durable local meal storage

/// Stable, user-visible failures for the local nutrition meal store. The
/// store intentionally does not expose filesystem paths or decoder details
/// in its public errors, mirroring `SupplementStoreError`.
public enum NutritionMealStoreError: Error, Equatable, Sendable {
    case applicationSupportUnavailable
    case readFailed
    case invalidEnvelope
    case writeFailed
    case mealNotFound
}

extension NutritionMealStoreError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .applicationSupportUnavailable:
            return "Local meal storage is unavailable."
        case .readFailed:
            return "Local meal storage could not be read."
        case .invalidEnvelope:
            return "Local meal storage is invalid and was not loaded."
        case .writeFailed:
            return "Local meal changes could not be saved."
        case .mealNotFound:
            return "The meal to update was not found."
        }
    }
}

/// Versioned on-disk envelope. An absent file decodes to an honest empty
/// state (no meals); this is not the same as an invalid file, which throws.
public struct NutritionMealStoreEnvelope: Codable, Equatable, Sendable {
    public static let currentSchemaVersion = 1

    public let schemaVersion: Int
    public let meals: [NutritionMeal]

    private enum CodingKeys: String, CodingKey {
        case schemaVersion, meals
    }

    public init(meals: [NutritionMeal] = []) {
        self.schemaVersion = Self.currentSchemaVersion
        self.meals = meals
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        schemaVersion = try container.decode(Int.self, forKey: .schemaVersion)
        // `meals` is decoded with `decodeIfPresent` so a minimal/older
        // envelope shape that predates this field still decodes to an empty
        // list rather than throwing.
        meals = try container.decodeIfPresent([NutritionMeal].self, forKey: .meals) ?? []
    }
}

/// Atomic, Application-Support-backed local nutrition meal storage.
///
/// Structurally mirrors `SupplementStore`: an in-process transaction lock
/// guards read-modify-write cycles, writes go through a temp file plus
/// `replaceItemAt`/`moveItem`, and iOS writes request
/// `.completeFileProtection`. The URL is injectable only for deterministic
/// tests; the default path has no temporary-directory or home-directory
/// fallback — if Application Support cannot be resolved, initialization
/// fails closed.
public final class NutritionMealStore: @unchecked Sendable {
    public static let fileName = "nutrition-meals.json"
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
            throw NutritionMealStoreError.applicationSupportUnavailable
        }
        return support
            .appendingPathComponent("LifeOS", isDirectory: true)
            .appendingPathComponent(fileName, isDirectory: false)
    }

    /// Loads all durable meals, including soft-deleted ones. An absent file
    /// returns an empty array rather than throwing or fabricating data.
    public func load() throws -> [NutritionMeal] {
        Self.processTransactionLock.lock()
        defer { Self.processTransactionLock.unlock() }
        return try loadUnlocked()
    }

    /// Appends a new durable meal. The caller must already have set
    /// `provenance` (`.manual`, `.confirmedFromPhoto`, or
    /// `.confirmedFromBarcode`); the store does not infer or override it.
    public func addConfirmed(_ meal: NutritionMeal) throws {
        Self.processTransactionLock.lock()
        defer { Self.processTransactionLock.unlock() }
        var meals = try loadUnlocked()
        meals.append(meal)
        try saveUnlocked(meals)
    }

    /// Creates a new revision of an existing active meal. The original is
    /// soft-deleted (`deletedAt` set) and a new meal is appended with a new
    /// `id`, `revision = original.revision + 1`, and
    /// `supersedesID = original.id`. Soft-deleting the original (rather than
    /// adding a separate `supersededBy` field) is sufficient to keep
    /// `meals(on:)`/`dailyTotals(on:)` correct: both already filter on
    /// "not deleted," so the replaced meal simply stops contributing while
    /// its lineage remains inspectable via `supersedesID` on the new meal.
    @discardableResult
    public func correct(id: UUID, now: Date = .now, applying edit: (inout NutritionMeal) -> Void) throws -> NutritionMeal {
        Self.processTransactionLock.lock()
        defer { Self.processTransactionLock.unlock() }
        var meals = try loadUnlocked()
        guard let index = meals.firstIndex(where: { $0.id == id && !$0.isDeleted }) else {
            throw NutritionMealStoreError.mealNotFound
        }
        let original = meals[index]
        var draft = original
        edit(&draft)
        let corrected = NutritionMeal(
            id: UUID(),
            loggedAt: draft.loggedAt,
            timeZoneIdentifier: draft.timeZoneIdentifier,
            name: draft.name,
            kcal: draft.kcal,
            proteinGrams: draft.proteinGrams,
            carbGrams: draft.carbGrams,
            fatGrams: draft.fatGrams,
            journalNote: draft.journalNote,
            provenance: draft.provenance,
            createdAt: now,
            revision: original.revision + 1,
            supersedesID: original.id,
            deletedAt: nil
        )

        meals[index].deletedAt = now
        meals.append(corrected)
        try saveUnlocked(meals)
        return corrected
    }

    /// Soft-deletes the matching active meal by setting `deletedAt`. No-op
    /// (throws `.mealNotFound`) if no matching active meal exists.
    public func softDelete(id: UUID, now: Date = .now) throws {
        Self.processTransactionLock.lock()
        defer { Self.processTransactionLock.unlock() }
        var meals = try loadUnlocked()
        guard let index = meals.firstIndex(where: { $0.id == id && !$0.isDeleted }) else {
            throw NutritionMealStoreError.mealNotFound
        }
        meals[index].deletedAt = now
        try saveUnlocked(meals)
    }

    /// Non-deleted meals whose `loggedAt` falls on the given calendar day,
    /// sorted by `loggedAt` ascending.
    public func meals(on date: Date, calendar: Calendar = .current) throws -> [NutritionMeal] {
        let all = try load()
        return all
            .filter { !$0.isDeleted && calendar.isDate($0.loggedAt, inSameDayAs: date) }
            .sorted { $0.loggedAt < $1.loggedAt }
    }

    /// Sums kcal/protein/carb/fat across non-deleted meals for the given
    /// calendar day. Each summed field is `nil` if zero contributing meals
    /// had that field set — a total is never silently reported as zero when
    /// nothing was ever recorded.
    public func dailyTotals(on date: Date, calendar: Calendar = .current) throws -> NutritionMealDailyTotals {
        let dayMeals = try meals(on: date, calendar: calendar)
        func sum(_ values: [Int]) -> Int? { values.isEmpty ? nil : values.reduce(0, +) }
        return NutritionMealDailyTotals(
            kcal: sum(dayMeals.compactMap(\.kcal)),
            proteinGrams: sum(dayMeals.compactMap(\.proteinGrams)),
            carbGrams: sum(dayMeals.compactMap(\.carbGrams)),
            fatGrams: sum(dayMeals.compactMap(\.fatGrams))
        )
    }

    private func loadUnlocked() throws -> [NutritionMeal] {
        guard fileManager.fileExists(atPath: fileURL.path) else { return [] }
        let data: Data
        do {
            data = try Data(contentsOf: fileURL)
        } catch {
            throw NutritionMealStoreError.readFailed
        }
        do {
            let envelope = try JSONDecoder.nutritionMeal.decode(NutritionMealStoreEnvelope.self, from: data)
            guard envelope.schemaVersion == NutritionMealStoreEnvelope.currentSchemaVersion else {
                throw NutritionMealStoreError.invalidEnvelope
            }
            return envelope.meals
        } catch {
            throw NutritionMealStoreError.invalidEnvelope
        }
    }

    private func saveUnlocked(_ meals: [NutritionMeal]) throws {
        let data: Data
        do {
            data = try JSONEncoder.nutritionMeal.encode(NutritionMealStoreEnvelope(meals: meals))
        } catch {
            throw NutritionMealStoreError.invalidEnvelope
        }
        do {
            try atomicReplace(data)
        } catch {
            throw NutritionMealStoreError.writeFailed
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
    static let nutritionMeal: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }()
}

private extension JSONEncoder {
    static let nutritionMeal: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }()
}
