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

    func testAddConfirmedRejectsDuplicateIDsAndDirectLineageInsertion() throws {
        let url = temporaryURL()
        defer { removeStore(at: url) }
        let store = try NutritionMealStore(url: url)
        let original = meal()

        try store.addConfirmed(original)

        XCTAssertThrowsError(try store.addConfirmed(original))

        var invalidCorrection = meal(name: "Invalid correction")
        invalidCorrection.revision = 2
        invalidCorrection.supersedesID = original.id
        XCTAssertThrowsError(try store.addConfirmed(invalidCorrection))

        XCTAssertEqual(try store.load(), [original])
    }

    func testLoadRejectsUnknownEnvelopeFieldsAndDuplicateIDs() throws {
        let url = temporaryURL()
        defer { removeStore(at: url) }
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )

        let store = try NutritionMealStore(url: url)
        try Data(#"{"schemaVersion":1,"meals":[],"unexpected":true}"#.utf8).write(to: url)
        XCTAssertThrowsError(try store.load())

        let duplicate = meal()
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(
            NutritionMealStoreEnvelope(meals: [duplicate, duplicate])
        )
        try data.write(to: url)

        XCTAssertThrowsError(try store.load())
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

    func testPhotoConfirmedMealRequiresAndPersistsSanitizedProposalLineage() throws {
        let url = temporaryURL()
        defer { removeStore(at: url) }
        let store = try NutritionMealStore(url: url)
        let withoutLineage = meal(name: "Photo meal", provenance: .confirmedFromPhoto)
        XCTAssertThrowsError(try store.addConfirmed(withoutLineage))

        let hash = try FoodEstimateImageHashReference(
            imageID: "image-a",
            sha256: String(repeating: "a", count: 64)
        )
        let lineage = try NutritionMealPhotoLineage(
            proposalID: "proposal-photo",
            requestID: "request-photo",
            requestTimestamp: iso(now),
            generatedAt: iso(now),
            provider: "gateway-food-provider",
            modelIdentifier: "food-model",
            modelVersion: "1",
            policyVersion: "nutrition-v1",
            sanitizedImageHashes: [hash]
        )
        let saved = NutritionMeal(
            loggedAt: now,
            timeZoneIdentifier: "Europe/Berlin",
            name: "Photo meal",
            kcal: 400,
            proteinGrams: 30,
            carbGrams: 40,
            fatGrams: 10,
            portionGrams: 250,
            portionUnit: .g,
            provenance: .confirmedFromPhoto,
            createdAt: now,
            photoLineage: lineage
        )
        try store.addConfirmed(saved)

        let loaded = try store.load()
        XCTAssertEqual(loaded, [saved])
        XCTAssertEqual(loaded.first?.photoLineage, lineage)
        XCTAssertEqual(loaded.first?.portionUnit, .g)
        XCTAssertEqual(loaded.first?.portionGrams, 250)
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

    // MARK: 8. Presenter-owned draft and durable save flow

    func testLocalPreviewIsInMemoryUntilDurableSave() throws {
        let url = temporaryURL()
        defer { removeStore(at: url) }
        let store = try NutritionMealStore(url: url)
        var draft = manualDraft(name: "Oats", calories: "400", portionGrams: "250")

        let preview = try draft.applyLocalPreview()
        XCTAssertEqual(preview.id, draft.draftID)
        XCTAssertEqual(preview.name, "Oats")
        XCTAssertEqual(preview.kcal, 400)
        XCTAssertEqual(preview.portionGrams, 250)
        XCTAssertEqual(draft.previewMeal, preview)
        XCTAssertNil(draft.activeMeal)
        XCTAssertNil(draft.durableReceipt)
        XCTAssertTrue(try store.load().isEmpty)

        draft.calories = "450"
        let saved = try FitnessNutritionDurableSave.save(
            draft: &draft,
            to: store,
            now: now.addingTimeInterval(60)
        )
        XCTAssertEqual(saved.kcal, 450)
        XCTAssertEqual(saved.portionGrams, 250)
        XCTAssertNil(draft.previewMeal)
        XCTAssertEqual(draft.activeMeal, saved)
        XCTAssertTrue(draft.isDurablyCurrent)
        XCTAssertEqual(try store.load(), [saved])
    }

    func testInvalidLocalPreviewDoesNotCreatePreviewOrDurableRecord() throws {
        let url = temporaryURL()
        defer { removeStore(at: url) }
        let store = try NutritionMealStore(url: url)
        var draft = manualDraft(name: "Invalid")
        draft.calories = "not-a-number"

        XCTAssertThrowsError(try draft.applyLocalPreview())
        XCTAssertNil(draft.previewMeal)
        XCTAssertTrue(try store.load().isEmpty)
    }

    func testSaveEditSaveAdvancesRevisionAndKeepsOneActiveMeal() throws {
        let url = temporaryURL()
        defer { removeStore(at: url) }
        let store = try NutritionMealStore(url: url)
        var draft = manualDraft(name: "Original", calories: "400")

        let first = try FitnessNutritionDurableSave.save(draft: &draft, to: store, now: now)
        XCTAssertEqual(first.revision, 1)
        XCTAssertNil(first.supersedesID)

        draft.mealName = "Edited once"
        draft.calories = "450"
        XCTAssertTrue(draft.isDirty)
        XCTAssertFalse(draft.isDurablyCurrent)
        let second = try FitnessNutritionDurableSave.save(
            draft: &draft,
            to: store,
            now: now.addingTimeInterval(60)
        )
        XCTAssertNotEqual(second.id, first.id)
        XCTAssertEqual(second.revision, 2)
        XCTAssertEqual(second.supersedesID, first.id)
        XCTAssertEqual(second.name, "Edited once")
        XCTAssertEqual(second.kcal, 450)
        XCTAssertTrue(draft.isDurablyCurrent)

        draft.mealName = "Edited twice"
        draft.protein = "35"
        let third = try FitnessNutritionDurableSave.save(
            draft: &draft,
            to: store,
            now: now.addingTimeInterval(120)
        )
        XCTAssertNotEqual(third.id, second.id)
        XCTAssertEqual(third.revision, 3)
        XCTAssertEqual(third.supersedesID, second.id)
        XCTAssertEqual(third.name, "Edited twice")
        XCTAssertEqual(third.proteinGrams, 35)

        let raw = try store.load()
        XCTAssertEqual(raw.count, 3)
        XCTAssertEqual(raw.filter { !$0.isDeleted }.map(\.id), [third.id])
    }

    func testDuplicateSaveIsIdempotentAndReconcilesAnUncertainInitialWrite() throws {
        let url = temporaryURL()
        defer { removeStore(at: url) }
        let store = try NutritionMealStore(url: url)
        var draft = manualDraft(name: "Retryable", calories: "300")

        let first = try FitnessNutritionDurableSave.save(draft: &draft, to: store, now: now)
        let duplicateTap = try FitnessNutritionDurableSave.save(
            draft: &draft,
            to: store,
            now: now.addingTimeInterval(1)
        )
        XCTAssertEqual(duplicateTap, first)
        XCTAssertEqual(try store.load().filter { !$0.isDeleted }.count, 1)

        let uncertainID = UUID(uuidString: "AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAAA")!
        var retryDraft = manualDraft(
            id: uncertainID,
            name: "Receipt lost",
            calories: "275"
        )
        let candidate = try retryDraft.validatedMeal(createdAt: now)
        try store.addConfirmed(candidate)

        let reconciled = try FitnessNutritionDurableSave.save(
            draft: &retryDraft,
            to: store,
            now: now.addingTimeInterval(30)
        )
        XCTAssertEqual(reconciled, candidate)
        XCTAssertEqual(retryDraft.activeMeal, candidate)
        XCTAssertTrue(retryDraft.isDurablyCurrent)
        XCTAssertEqual(try store.load().filter { !$0.isDeleted }.count, 2)
    }

    func testDirtyDraftIsRetainedAcrossReopenAndOnlyExplicitDiscardResetsIt() throws {
        let selectedDate = now.addingTimeInterval(86_400)
        let otherDate = now.addingTimeInterval(2 * 86_400)
        var draft = FitnessNutritionDraftFlow.startNew(selectedDate: selectedDate)
        draft.mealName = "Keep this edit"
        draft.calories = "510"
        _ = try draft.applyLocalPreview()

        let reopened = FitnessNutritionDraftFlow.reopenOrStart(
            current: draft,
            selectedDate: otherDate
        )
        XCTAssertEqual(reopened, draft)
        XCTAssertEqual(reopened.mealName, "Keep this edit")
        XCTAssertNotNil(reopened.previewMeal)

        let discarded = FitnessNutritionDraftFlow.discard(selectedDate: otherDate)
        XCTAssertNotEqual(discarded.draftID, draft.draftID)
        XCTAssertEqual(discarded.mealName, "Meal")
        XCTAssertTrue(discarded.calories.isEmpty)
        XCTAssertNil(discarded.previewMeal)
        XCTAssertNil(discarded.activeMeal)
        XCTAssertFalse(discarded.isDirty)
        XCTAssertEqual(discarded.loggedAt, FitnessNutritionDraft.new(selectedDate: otherDate).loggedAt)
    }

    func testSelectedHistoricalDaySurvivesPreviewBarcodeTimestampAndSave() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Europe/Berlin")!
        let selectedDate = try XCTUnwrap(calendar.date(from: DateComponents(
            year: 2026, month: 9, day: 3, hour: 19, minute: 42
        )))
        let expectedLoggedAt = try XCTUnwrap(calendar.date(
            bySettingHour: 12,
            minute: 0,
            second: 0,
            of: calendar.startOfDay(for: selectedDate)
        ))

        var draft = FitnessNutritionDraftFlow.startNew(
            selectedDate: selectedDate,
            calendar: calendar
        )
        draft.mealName = "Historical lunch"
        draft.calories = "625"
        draft.barcodeProductName = "Historical package"

        XCTAssertEqual(draft.loggedAt, expectedLoggedAt)
        let barcodeDate = try XCTUnwrap(ISO8601DateFormatter().date(from: draft.barcodeMealAt))
        XCTAssertEqual(barcodeDate, expectedLoggedAt)

        let preview = try draft.applyLocalPreview()
        XCTAssertEqual(preview.loggedAt, expectedLoggedAt)

        let url = temporaryURL()
        defer { removeStore(at: url) }
        let store = try NutritionMealStore(url: url)
        let saved = try FitnessNutritionDurableSave.save(
            draft: &draft,
            to: store,
            now: now.addingTimeInterval(86_400 * 30)
        )
        XCTAssertEqual(saved.loggedAt, expectedLoggedAt)
        XCTAssertEqual(try store.meals(on: selectedDate, calendar: calendar), [saved])
        XCTAssertTrue(try store.meals(on: now, calendar: calendar).isEmpty)
    }

    func testDraftValidationTrimsNamePreservesCommaDecimalsAndDistinguishesNilFromZero() throws {
        let url = temporaryURL()
        defer { removeStore(at: url) }
        let store = try NutritionMealStore(url: url)
        var draft = FitnessNutritionDraft(
            loggedAt: now,
            timeZoneIdentifier: "Europe/Berlin",
            mealName: "  Oats  ",
            calories: "0",
            protein: "",
            carbohydrates: "1,25",
            fat: "0.00"
        )

        let preview = try draft.applyLocalPreview()
        XCTAssertEqual(preview.name, "Oats")
        XCTAssertEqual(preview.kcal, 0)
        XCTAssertNil(preview.proteinGrams)
        XCTAssertEqual(preview.carbGrams, 1)
        XCTAssertEqual(preview.fatGrams, 0)
        XCTAssertNil(preview.portionGrams)

        let saved = try FitnessNutritionDurableSave.save(draft: &draft, to: store, now: now)
        XCTAssertEqual(saved.name, "Oats")
        XCTAssertEqual(try store.load(), [saved])
        XCTAssertEqual(try store.dailyTotals(on: now, calendar: bavarianCalendar).kcal, 0)
        XCTAssertNil(try store.dailyTotals(on: now, calendar: bavarianCalendar).proteinGrams)
    }

    func testInvalidDraftSaveDoesNotWriteOrMutateTheDraft() throws {
        let url = temporaryURL()
        defer { removeStore(at: url) }
        let store = try NutritionMealStore(url: url)
        var draft = manualDraft(name: "Valid", calories: "400")
        draft.calories = "-1"
        let invalidDraft = draft

        XCTAssertThrowsError(try FitnessNutritionDurableSave.save(draft: &draft, to: store, now: now))
        XCTAssertEqual(draft, invalidDraft)
        XCTAssertTrue(try store.load().isEmpty)
    }

    // MARK: - Helpers

    private func manualDraft(
        id: UUID = UUID(),
        name: String,
        calories: String = "400",
        portionGrams: String = ""
    ) -> FitnessNutritionDraft {
        FitnessNutritionDraft(
            draftID: id,
            loggedAt: now,
            timeZoneIdentifier: "Europe/Berlin",
            mealName: name,
            calories: calories,
            protein: "30",
            carbohydrates: "40",
            fat: "10",
            portionGrams: portionGrams
        )
    }

    private var bavarianCalendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Europe/Berlin")!
        return calendar
    }

    private func iso(_ date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.string(from: date)
    }
}
