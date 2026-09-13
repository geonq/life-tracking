import Foundation

// MARK: - Durable manually/photo/barcode-confirmed meal domain

/// Where a durable `NutritionMeal` came from. The store never assigns this
/// value itself: only the caller knows whether a meal reached persistence
/// through the manual entry form or an explicit photo/barcode confirmation
/// action, so provenance is always supplied by the caller of
/// `NutritionMealStore.addConfirmed`.
public enum NutritionMealProvenance: String, Codable, CaseIterable, Hashable, Sendable {
    case manual
    case confirmedFromPhoto
    case confirmedFromBarcode
}

/// A single durable, user-confirmed meal record.
///
/// `NutritionMeal` intentionally carries no implicit persistence behavior;
/// it is a plain value type. Only `NutritionMealStore` decides what is
/// written to disk, and only through `addConfirmed`/`correct`.
///
/// Correction lineage uses a single forward pointer (`supersedesID`) rather
/// than a corrections array: `correct` creates a new active meal whose
/// `supersedesID` points at the meal it replaces, and the store soft-deletes
/// the original. This is sufficient to reconstruct history by following
/// `supersedesID` backward while keeping `meals(on:)`/`dailyTotals(on:)`
/// simple set operations over "not deleted."
public struct NutritionMeal: Codable, Equatable, Sendable, Identifiable {
    public let id: UUID
    /// When the meal was eaten. User-set, and may differ from `createdAt`
    /// (e.g. logging breakfast at lunchtime).
    public var loggedAt: Date
    /// The device timezone identifier at the time this meal was logged, if
    /// known. `nil` is a real, honest state ("unknown timezone") rather than
    /// a silent default to `TimeZone.current.identifier` — the caller
    /// decides whether and how to resolve a timezone before constructing
    /// this value.
    public var timeZoneIdentifier: String?
    public var name: String
    /// Whole kilocalories. `nil` means unavailable/unknown and is excluded
    /// from `dailyTotals`; an explicit `0` is a real observed value and is
    /// included in sums as zero. This mirrors
    /// `FitnessNutritionSnapshot.includingLocalBarcodeRecords`'s handling of
    /// explicit-zero vs missing kcal.
    public var kcal: Int?
    public var proteinGrams: Int?
    public var carbGrams: Int?
    public var fatGrams: Int?
    /// Optional portion metadata. The unit is retained instead of silently
    /// treating a provider serving as grams.
    public var portionGrams: Double?
    public var portionUnit: FoodUnit?
    public var journalNote: String?
    public var provenance: NutritionMealProvenance
    public let createdAt: Date
    /// Starts at 1 for an original meal. A correction increments this on the
    /// new active meal.
    public var revision: Int
    /// `nil` for an original meal. Set to the id of the meal this one
    /// replaces when created via `correct`.
    public var supersedesID: UUID?
    /// Soft-delete marker. `correct` sets this on the meal being replaced;
    /// `softDelete` sets it directly. A non-nil value excludes the meal from
    /// `meals(on:)` and `dailyTotals(on:)`.
    public var deletedAt: Date?
    /// Present for every durable photo-confirmed meal. Photo bytes are never
    /// retained in this record; only the audit-safe lineage is kept.
    public var photoLineage: NutritionMealPhotoLineage?

    public init(
        id: UUID = UUID(),
        loggedAt: Date,
        timeZoneIdentifier: String? = nil,
        name: String,
        kcal: Int? = nil,
        proteinGrams: Int? = nil,
        carbGrams: Int? = nil,
        fatGrams: Int? = nil,
        portionGrams: Double? = nil,
        portionUnit: FoodUnit? = nil,
        journalNote: String? = nil,
        provenance: NutritionMealProvenance,
        createdAt: Date = .now,
        revision: Int = 1,
        supersedesID: UUID? = nil,
        deletedAt: Date? = nil,
        photoLineage: NutritionMealPhotoLineage? = nil
    ) {
        self.id = id
        self.loggedAt = loggedAt
        self.timeZoneIdentifier = timeZoneIdentifier
        self.name = name
        self.kcal = kcal
        self.proteinGrams = proteinGrams
        self.carbGrams = carbGrams
        self.fatGrams = fatGrams
        self.portionGrams = portionGrams
        self.portionUnit = portionUnit
        self.journalNote = journalNote
        self.provenance = provenance
        self.createdAt = createdAt
        self.revision = revision
        self.supersedesID = supersedesID
        self.deletedAt = deletedAt
        self.photoLineage = photoLineage
    }

    public var isDeleted: Bool { deletedAt != nil }

    /// Validates the boundary immediately before a meal enters durable local
    /// storage. The initializer stays non-throwing for previews and drafts;
    /// persistence is where malformed values must fail closed.
    public func validateForPersistence() throws {
        guard loggedAt.timeIntervalSinceReferenceDate.isFinite,
              createdAt.timeIntervalSinceReferenceDate.isFinite else {
            throw NutritionValidationError.invalidTimestamp("meal date")
        }
        if let deletedAt, !deletedAt.timeIntervalSinceReferenceDate.isFinite {
            throw NutritionValidationError.invalidTimestamp("deletedAt")
        }
        if let timeZoneIdentifier {
            guard timeZoneIdentifier.utf16.count <= 64,
                  !timeZoneIdentifier.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  TimeZone(identifier: timeZoneIdentifier) != nil else {
                throw NutritionValidationError.invalidBounds("timeZoneIdentifier")
            }
        }
        guard !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              name.utf16.count <= 200 else {
            throw NutritionValidationError.invalidText("meal.name")
        }
        if let journalNote, journalNote.utf16.count > 1_000 {
            throw NutritionValidationError.invalidText("meal.journalNote")
        }
        guard revision >= 1 else {
            throw NutritionValidationError.invalidBounds("meal.revision")
        }
        if let supersedesID, supersedesID == id {
            throw NutritionValidationError.invalidLineage("meal cannot supersede itself")
        }
        if let kcal, !(0...5_000).contains(kcal) {
            throw NutritionValidationError.invalidBounds("meal.kcal")
        }
        for (value, field) in [
            (proteinGrams, "meal.proteinGrams"),
            (carbGrams, "meal.carbGrams"),
            (fatGrams, "meal.fatGrams")
        ] {
            if let value, !(0...2_000).contains(value) {
                throw NutritionValidationError.invalidBounds(field)
            }
        }
        guard (portionGrams == nil) == (portionUnit == nil) else {
            throw NutritionValidationError.contradictoryState(
                "portion grams and unit must be supplied together"
            )
        }
        if let portionGrams {
            guard portionGrams.isFinite, portionGrams > 0, portionGrams <= 1_000_000 else {
                throw NutritionValidationError.invalidBounds("meal.portionGrams")
            }
        }
        try photoLineage?.validate()
        switch provenance {
        case .confirmedFromPhoto:
            guard photoLineage != nil else {
                throw NutritionValidationError.invalidLineage(
                    "photo-confirmed meal is missing proposal lineage"
                )
            }
        case .manual, .confirmedFromBarcode:
            guard photoLineage == nil else {
                throw NutritionValidationError.invalidLineage(
                    "non-photo meal cannot carry photo lineage"
                )
            }
        }
    }
}

/// Sums across a set of non-deleted meals for one calendar day. Mirrors the
/// "unavailable vs. zero" honesty already established for nutrition totals
/// elsewhere in LifeOS: a field is `nil` when zero contributing meals had it
/// set, not when the sum happens to be zero.
public struct NutritionMealDailyTotals: Equatable, Sendable {
    public let kcal: Int?
    public let proteinGrams: Int?
    public let carbGrams: Int?
    public let fatGrams: Int?

    public init(kcal: Int?, proteinGrams: Int?, carbGrams: Int?, fatGrams: Int?) {
        self.kcal = kcal
        self.proteinGrams = proteinGrams
        self.carbGrams = carbGrams
        self.fatGrams = fatGrams
    }

    public static let empty = NutritionMealDailyTotals(kcal: nil, proteinGrams: nil, carbGrams: nil, fatGrams: nil)
}
