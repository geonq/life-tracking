import Foundation
import XCTest
@testable import LifeOS

final class NutritionMealStoreTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_786_449_600)

    private func temporaryURL() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("lifeos-nutrition-meal-store-\(UUID().uuidString)", isDirectory: true)
            .appendingPathComponent("nutrition-meals.json", isDirectory: false)
    }

    private func removeStore(at url: URL) {
        try? FileManager.default.removeItem(at: url.deletingLastPathComponent())
    }

    private func meal(
        name: String = "Breakfast",
        loggedAt: Date? = nil,
        kcal: Int? = 400,
        protein: Int? = 30,
        carb: Int? = 40,
        fat: Int? = 10,
        provenance: NutritionMealProvenance = .manual
    ) -> NutritionMeal {
        NutritionMeal(
            loggedAt: loggedAt ?? now,
            timeZoneIdentifier: "Europe/Berlin",
            name: name,
            kcal: kcal,
            proteinGrams: protein,
            carbGrams: carb,
            fatGrams: fat,
            provenance: provenance,
            createdAt: now
        )
    }

    // MARK: 1. Persistence round-trip + reload-after-relaunch

    func testPersistenceRoundTripSurvivesRelaunch() throws {
        let url = temporaryURL()
        defer { removeStore(at: url) }
        let store = try NutritionMealStore(url: url)
        let original = meal(name: "Oats")
        try store.addConfirmed(original)

        let relaunched = try NutritionMealStore(url: url)
        let loaded = try relaunched.load()
        XCTAssertEqual(loaded.count, 1)
        XCTAssertEqual(loaded.first?.id, original.id)
        XCTAssertEqual(loaded.first?.name, "Oats")
        XCTAssertEqual(loaded.first?.kcal, 400)
    }

    // MARK: 2. Confirmation creates a durable meal

    func testAddConfirmedPersistsAndIsQueryable() throws {
        let url = temporaryURL()
        defer { removeStore(at: url) }
        let store = try NutritionMealStore(url: url)
        let saved = meal(name: "Lunch", provenance: .confirmedFromBarcode)
        try store.addConfirmed(saved)

        let loaded = try store.load()
        XCTAssertEqual(loaded.map(\.id), [saved.id])

        let dayMeals = try store.meals(on: now, calendar: bavarianCalendar)
        XCTAssertEqual(dayMeals.map(\.id), [saved.id])
        XCTAssertEqual(dayMeals.first?.provenance, .confirmedFromBarcode)
    }

    // MARK: 3. Ephemeral proposal not persisted

    func testConstructingAMealInMemoryDoesNotPersistIt() throws {
        let url = temporaryURL()
        defer { removeStore(at: url) }
        let store = try NutritionMealStore(url: url)
        _ = meal(name: "Never saved")

        let loaded = try store.load()
        XCTAssertTrue(loaded.isEmpty)
        let dayMeals = try store.meals(on: now, calendar: bavarianCalendar)
        XCTAssertTrue(dayMeals.isEmpty)
    }

    // MARK: 4. Correction keeps lineage

    func testCorrectCreatesNewRevisionAndSoftDeletesOriginal() throws {
        let url = temporaryURL()
        defer { removeStore(at: url) }
        let store = try NutritionMealStore(url: url)
        let original = meal(name: "Salad", kcal: 300)
        try store.addConfirmed(original)

        let corrected = try store.correct(id: original.id, now: now.addingTimeInterval(60)) { draft in
            draft.name = "Salad, corrected"
            draft.kcal = 350
        }

        XCTAssertEqual(corrected.supersedesID, original.id)
        XCTAssertEqual(corrected.revision, original.revision + 1)
        XCTAssertEqual(corrected.name, "Salad, corrected")
        XCTAssertEqual(corrected.kcal, 350)

        let active = try store.meals(on: now, calendar: bavarianCalendar)
        XCTAssertEqual(active.map(\.id), [corrected.id])
        XCTAssertFalse(active.contains { $0.id == original.id })

        // The original is still present in the raw envelope, soft-deleted.
        let raw = try store.load()
        XCTAssertEqual(raw.count, 2)
        let originalRaw = raw.first { $0.id == original.id }
        XCTAssertNotNil(originalRaw?.deletedAt)
        XCTAssertTrue(originalRaw?.isDeleted ?? false)
    }

    // MARK: 5. Soft-delete excludes from totals

    func testSoftDeleteExcludesFromTotalsAndMealsList() throws {
        let url = temporaryURL()
        defer { removeStore(at: url) }
        let store = try NutritionMealStore(url: url)
        let keep = meal(name: "Keep", kcal: 500, protein: 20, carb: 50, fat: 15)
        let drop = meal(name: "Drop", kcal: 200, protein: 10, carb: 20, fat: 5)
        try store.addConfirmed(keep)
        try store.addConfirmed(drop)

        try store.softDelete(id: drop.id, now: now.addingTimeInterval(30))

        let active = try store.meals(on: now, calendar: bavarianCalendar)
        XCTAssertEqual(active.map(\.id), [keep.id])

        let totals = try store.dailyTotals(on: now, calendar: bavarianCalendar)
        XCTAssertEqual(totals.kcal, 500)
        XCTAssertEqual(totals.proteinGrams, 20)
        XCTAssertEqual(totals.carbGrams, 50)
        XCTAssertEqual(totals.fatGrams, 15)
    }

    // MARK: 6. Daily totals math with mixed present/nil macro fields

    func testDailyTotalsSumsPresentFieldsAndReportsNilForNoContribution() throws {
        let url = temporaryURL()
        defer { removeStore(at: url) }
        let store = try NutritionMealStore(url: url)
        // Only kcal and protein are set; carb/fat are nil on every meal.
        let a = meal(name: "A", loggedAt: now, kcal: 300, protein: 20, carb: nil, fat: nil)
        let b = meal(name: "B", loggedAt: now.addingTimeInterval(3_600), kcal: 250, protein: nil, carb: nil, fat: nil)
        try store.addConfirmed(a)
        try store.addConfirmed(b)

        let totals = try store.dailyTotals(on: now, calendar: bavarianCalendar)
        XCTAssertEqual(totals.kcal, 550)
        XCTAssertEqual(totals.proteinGrams, 20)
        XCTAssertNil(totals.carbGrams)
        XCTAssertNil(totals.fatGrams)
    }

    // MARK: 7. Backward-compatible decode of a pre-field/empty file

    func testMissingFileDecodesToHonestEmptyState() throws {
        let url = temporaryURL()
        defer { removeStore(at: url) }
        let store = try NutritionMealStore(url: url)
        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path) == false)
        let loaded = try store.load()
        XCTAssertTrue(loaded.isEmpty)
    }

    func testMinimalEnvelopeJSONDecodesWithoutThrowing() throws {
        let url = temporaryURL()
        defer { removeStore(at: url) }
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let json = #"{"schemaVersion":1,"meals":[]}"#
        try json.data(using: .utf8)!.write(to: url)

        let store = try NutritionMealStore(url: url)
        let loaded = try store.load()
        XCTAssertTrue(loaded.isEmpty)
    }

    // MARK: - Helpers

    private var bavarianCalendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Europe/Berlin")!
        return calendar
    }
}
