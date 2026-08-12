import XCTest
@testable import LifeOS

final class NutritionBarcodeTests: XCTestCase {
    private let fetchedAt = "2026-08-12T00:00:00Z"

    func testEANNormalizationAcceptsGermanEANAndUPCButRejectsMalformedInput() {
        XCTAssertEqual(NutritionBarcodeNormalizer.normalize(" 30-17620422003 "), "3017620422003")
        XCTAssertEqual(NutritionBarcodeNormalizer.normalize("96385074"), "96385074")
        XCTAssertEqual(NutritionBarcodeNormalizer.normalize("042100005264"), "0042100005264")
        XCTAssertNil(NutritionBarcodeNormalizer.normalize("3017620422004"))
        XCTAssertNil(NutritionBarcodeNormalizer.normalize("3017620422003/evil"))
    }

    func testEditableNutritionParserAcceptsGermanCommaAndRejectsEmptyMalformedOrUnboundedValues() {
        XCTAssertEqual(NutritionBarcodeValueParser.parse(" 12,345 ", maximum: 2_000), 12.345)
        XCTAssertEqual(NutritionBarcodeValueParser.parse("539.5", maximum: 5_000), 539.5)
        XCTAssertNil(NutritionBarcodeValueParser.parse("", maximum: 5_000))
        XCTAssertNil(NutritionBarcodeValueParser.parse("1e2", maximum: 5_000))
        XCTAssertNil(NutritionBarcodeValueParser.parse("-1", maximum: 5_000))
        XCTAssertNil(NutritionBarcodeValueParser.parse("1,2345", maximum: 2_000))
        XCTAssertNil(NutritionBarcodeValueParser.parse("5001", maximum: 5_000))
    }

#if os(iOS)
    func testCameraCaptureNormalizesOnlySupportedChecksumBarcodes() {
        XCTAssertEqual(NutritionBarcodeScannerCoordinator.normalizedCapture("042100005264"), "0042100005264")
        XCTAssertEqual(NutritionBarcodeScannerCoordinator.normalizedCapture("96385074"), "96385074")
        XCTAssertNil(NutritionBarcodeScannerCoordinator.normalizedCapture("3017620422004"))
    }
#endif

    func testGermanProductDecodesWithoutRemoteImageAndPreservesProvenance() throws {
        let lookup = try decode("""
        {
          "schemaVersion": 1, "state": "found", "barcode": "3017620422003",
          "product": {"name": "Haselnusscreme", "brand": "Beispiel", "quantity": "400 g", "servingSize": "15 g", "countriesTags": ["en:germany"]},
          "nutritionState": "complete",
          "per100g": {"kcal": 539, "proteinGrams": 6.3, "carbsGrams": 57.5, "fatGrams": 30.9},
          "perServing": {"kcal": 81, "proteinGrams": 0.95, "carbsGrams": 8.63, "fatGrams": 4.64},
          "provenance": {
            "source": "openfoodfacts", "apiVersion": "v3.6",
            "apiURL": "https://world.openfoodfacts.org/api/v3.6/product/3017620422003.json",
            "productURL": "https://world.openfoodfacts.org/product/3017620422003",
            "fetchedAt": "2026-08-12T00:00:00Z", "databaseLicense": "ODbL-1.0", "contentLicense": "DbCL-1.0",
            "attribution": "Product data from Open Food Facts. Database: ODbL-1.0; contents: DbCL-1.0.",
            "dataQualityWarning": "Open Food Facts data is volunteer-sourced; accuracy, completeness, and reliability are not guaranteed."
          }
        }
        """)
        guard case .found(let value) = lookup else { return XCTFail("expected found") }
        XCTAssertEqual(value.product.name, "Haselnusscreme")
        XCTAssertEqual(value.per100g?.kcal, 539)
        XCTAssertEqual(value.provenance.databaseLicense, "ODbL-1.0")
    }

    func testPartialAndUnreliableStatesAreStrictAndProviderWarningsAreVisible() throws {
        let partial = try decode(baseFound(nutritionState: "partial", metrics: #"{"kcal": 100}"#))
        guard case .found(let partialValue) = partial else { return XCTFail("expected found") }
        XCTAssertEqual(partialValue.nutritionState, .partial)
        XCTAssertNil(partialValue.per100g?.proteinGrams)

        let unreliable = try decode(baseFound(nutritionState: "unreliable", metrics: #"{"kcal": 100}"#, qualityFlags: #"["provider_quality_warning"]"#))
        guard case .found(let unreliableValue) = unreliable else { return XCTFail("expected found") }
        XCTAssertEqual(unreliableValue.nutritionState, .unreliable)
        XCTAssertEqual(unreliableValue.qualityFlags, [.providerQualityWarning])

        XCTAssertThrowsError(try decode(baseFound(nutritionState: "complete", metrics: #"{"kcal": 100, "proteinGrams": 5, "carbsGrams": 10}"#)))
        XCTAssertThrowsError(try decode(baseFound(nutritionState: "unreliable", metrics: #"{"kcal": 100}"#)))
        XCTAssertThrowsError(try decode(baseFound(nutritionState: "complete", metrics: #"{"kcal": 5001, "proteinGrams": 5, "carbsGrams": 10, "fatGrams": 2}"#, basis: "perServing")))
    }

    func testProvenanceMirrorsServerBoundsAndTimestampValidation() {
        let longAttribution = String(repeating: "x", count: 501)
        XCTAssertThrowsError(try decode(baseFound(nutritionState: "partial", metrics: #"{"kcal": 100}"#)
            .replacingOccurrences(of: "Product data from Open Food Facts.", with: longAttribution)))
        XCTAssertThrowsError(try decode(baseFound(nutritionState: "partial", metrics: #"{"kcal": 100}"#)
            .replacingOccurrences(of: "\"fetchedAt\":\"\(fetchedAt)\"", with: "\"fetchedAt\":\"not-a-timestamp\"")))
        let longURL = "https://world.openfoodfacts.org/" + String(repeating: "a", count: 2_048)
        XCTAssertThrowsError(try decode(baseFound(nutritionState: "partial", metrics: #"{"kcal": 100}"#)
            .replacingOccurrences(of: "https://world.openfoodfacts.org/api/v3.6/product/3017620422003.json", with: longURL)))
    }

    func testConfirmationIsEditableAndOnlyExplicitStoreSavePersistsRecord() async throws {
        let lookup = try decode(baseFound(nutritionState: "complete", metrics: #"{"kcal": 539, "proteinGrams": 6.3, "carbsGrams": 57.5, "fatGrams": 30.9}"#))
        let proposal = try NutritionBarcodeProposal(proposalID: "proposal-1", lookup: lookup)
        let confirmation = NutritionBarcodeConfirmation(
            proposalID: proposal.proposalID, barcode: proposal.barcode, basis: .per100g,
            mealAt: fetchedAt, productName: "Edited name", grams: 100, kcal: 500,
            proteinGrams: 6, carbsGrams: 50, fatGrams: 25, confirmedAt: fetchedAt
        )
        let now = try XCTUnwrap(ISO8601DateFormatter().date(from: fetchedAt))
        let record = try NutritionBarcodeFlow.confirm(confirmation, for: proposal, now: now)
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let store = NutritionRecordStore(url: directory.appendingPathComponent("nutrition.json"))
        let before = try await store.load()
        XCTAssertEqual(before, [])
        try await store.save(record)
        try await store.save(record)
        let after = try await store.load()
        XCTAssertEqual(after, [record])

        let emptyConfirmation = NutritionBarcodeConfirmation(
            proposalID: proposal.proposalID, barcode: proposal.barcode, basis: .per100g,
            mealAt: fetchedAt, productName: "Edited name", grams: 100,
            kcal: nil, proteinGrams: nil, carbsGrams: nil, fatGrams: nil, confirmedAt: fetchedAt
        )
        XCTAssertThrowsError(try NutritionBarcodeFlow.confirm(emptyConfirmation, for: proposal, now: now))

        let corruptURL = directory.appendingPathComponent("corrupt.json")
        try Data("[{\"not\":\"a nutrition record\"}]".utf8).write(to: corruptURL, options: .atomic)
        let corruptStore = NutritionRecordStore(url: corruptURL)
        do {
            _ = try await corruptStore.load()
            XCTFail("corrupt records must fail closed")
        } catch {
            // Expected: malformed or unvalidated persisted records are rejected.
        }
    }

    func testRetryWithFreshRecordForSameProposalAndMealReplacesInsteadOfDuplicating() async throws {
        let lookup = try decode(baseFound(nutritionState: "complete", metrics: #"{"kcal": 539, "proteinGrams": 6.3, "carbsGrams": 57.5, "fatGrams": 30.9}"#))
        let proposal = try NutritionBarcodeProposal(proposalID: "proposal-retry", lookup: lookup)
        let confirmation = NutritionBarcodeConfirmation(
            proposalID: proposal.proposalID, barcode: proposal.barcode, basis: .per100g,
            mealAt: fetchedAt, productName: "First label", grams: 100, kcal: 500,
            proteinGrams: 6, carbsGrams: 50, fatGrams: 25, confirmedAt: fetchedAt
        )
        let now = try XCTUnwrap(ISO8601DateFormatter().date(from: fetchedAt))
        let first = try NutritionBarcodeFlow.confirm(confirmation, for: proposal, now: now)
        let revised = NutritionBarcodeConfirmation(
            proposalID: proposal.proposalID, barcode: proposal.barcode, basis: .per100g,
            mealAt: fetchedAt, productName: "Revised label", grams: 100, kcal: 480,
            proteinGrams: 7, carbsGrams: 45, fatGrams: 22, confirmedAt: fetchedAt
        )
        let second = try NutritionBarcodeFlow.confirm(revised, for: proposal, now: now)
        XCTAssertNotEqual(first.id, second.id, "The store must prove logical idempotency, not rely on UUID reuse.")

        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).appendingPathComponent("nutrition.json")
        let store = NutritionRecordStore(url: url)
        try await store.save(first)
        try await store.save(second)
        let records = try await store.load()
        XCTAssertEqual(records.count, 1)
        XCTAssertEqual(records.first, second)
    }

    func testMalformedUnknownPersistedFieldFailsClosed() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent("nutrition.json")
        let malformed = "[{\"id\":\"00000000-0000-0000-0000-000000000001\",\"proposalID\":\"p\",\"barcode\":\"3017620422003\",\"basis\":\"per100g\",\"mealAt\":\"2026-08-12T00:00:00Z\",\"confirmedAt\":\"2026-08-12T00:00:00Z\",\"extra\":true}]"
        try Data(malformed.utf8).write(to: url, options: .atomic)
        do {
            _ = try await NutritionRecordStore(url: url).load()
            XCTFail("unknown persisted fields must fail closed")
        } catch {
            // Expected: malformed or unvalidated local records are rejected.
        }
    }

    func testPersistedProposalIDRejectsUnsafeCharacters() async throws {
        let lookup = try decode(baseFound(nutritionState: "complete", metrics: #"{"kcal": 539, "proteinGrams": 6.3, "carbsGrams": 57.5, "fatGrams": 30.9}"#))
        let proposal = try NutritionBarcodeProposal(proposalID: "proposal-safe", lookup: lookup)
        let confirmation = NutritionBarcodeConfirmation(
            proposalID: proposal.proposalID, barcode: proposal.barcode, basis: .per100g,
            mealAt: fetchedAt, productName: "Unsafe ID fixture", grams: 100, kcal: 500,
            proteinGrams: 6, carbsGrams: 50, fatGrams: 25, confirmedAt: fetchedAt
        )
        let now = try XCTUnwrap(ISO8601DateFormatter().date(from: fetchedAt))
        let record = try NutritionBarcodeFlow.confirm(confirmation, for: proposal, now: now)
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode([record])) as? [[String: Any]])
        object[0]["proposalID"] = "bad$id"
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let url = directory.appendingPathComponent("nutrition.json")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try JSONSerialization.data(withJSONObject: object).write(to: url, options: .atomic)
        do {
            _ = try await NutritionRecordStore(url: url).load()
            XCTFail("unsafe persisted proposal IDs must fail closed")
        } catch {
            // Expected: persisted IDs must use the same restricted contract as
            // newly-created proposals.
        }
    }

    func testFailedWriteLeavesExistingPathUntouched() async throws {
        let lookup = try decode(baseFound(nutritionState: "complete", metrics: #"{"kcal": 539, "proteinGrams": 6.3, "carbsGrams": 57.5, "fatGrams": 30.9}"#))
        let proposal = try NutritionBarcodeProposal(proposalID: "proposal-failure", lookup: lookup)
        let confirmation = NutritionBarcodeConfirmation(
            proposalID: proposal.proposalID, barcode: proposal.barcode, basis: .per100g,
            mealAt: fetchedAt, productName: "Failure fixture", grams: 100, kcal: 500,
            proteinGrams: 6, carbsGrams: 50, fatGrams: 25, confirmedAt: fetchedAt
        )
        let now = try XCTUnwrap(ISO8601DateFormatter().date(from: fetchedAt))
        let record = try NutritionBarcodeFlow.confirm(confirmation, for: proposal, now: now)

        let blockedParent = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let marker = Data("keep this marker".utf8)
        try marker.write(to: blockedParent, options: .atomic)
        let store = NutritionRecordStore(url: blockedParent.appendingPathComponent("nutrition.json"))
        do {
            try await store.save(record)
            XCTFail("a file cannot be used as the record directory")
        } catch {
            // Expected: the write is rejected before an existing path can be
            // replaced, and the review UI can surface a retry.
        }
        XCTAssertEqual(try Data(contentsOf: blockedParent), marker)
    }

    func testConfirmedBarcodeRecordsFlowIntoSelectedDayMealsAndTotals() throws {
        let lookup = try decode(baseFound(nutritionState: "complete", metrics: #"{"kcal": 539, "proteinGrams": 6.3, "carbsGrams": 57.5, "fatGrams": 30.9}"#))
        let proposal = try NutritionBarcodeProposal(proposalID: "proposal-totals", lookup: lookup)
        let confirmation = NutritionBarcodeConfirmation(
            proposalID: proposal.proposalID, barcode: proposal.barcode, basis: .per100g,
            mealAt: fetchedAt, productName: "Hazelnut spread", grams: 100, kcal: 500,
            proteinGrams: 6, carbsGrams: 50, fatGrams: 25, confirmedAt: fetchedAt
        )
        let now = try XCTUnwrap(ISO8601DateFormatter().date(from: fetchedAt))
        let record = try NutritionBarcodeFlow.confirm(confirmation, for: proposal, now: now)
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let base = FitnessNutritionSnapshot(
            calorieTarget: 2_000, caloriesConsumed: 200, sourceSupportedExpenditure: nil,
            macroValues: [
                FitnessMacroValue(name: "Protein", value: 10, target: 150, hue: .blue),
                FitnessMacroValue(name: "Carbs", value: 20, target: 250, hue: .orange),
                FitnessMacroValue(name: "Fat", value: 5, target: 70, hue: .pink)
            ], meals: [], hydrationMilliliters: nil, hydrationTargetMilliliters: nil,
            caffeineMilligrams: nil, alcoholUnits: nil
        )
        let merged = base.includingLocalBarcodeRecords([record], for: now, calendar: calendar)
        XCTAssertEqual(merged.caloriesConsumed, 700)
        XCTAssertEqual(merged.macroValues.first(where: { $0.name == "Protein" })?.value, 16)
        XCTAssertEqual(merged.macroValues.first(where: { $0.name == "Carbs" })?.value, 70)
        XCTAssertEqual(merged.macroValues.first(where: { $0.name == "Fat" })?.value, 30)
        XCTAssertEqual(merged.meals.count, 1)
        XCTAssertEqual(merged.meals.first?.source, .package)
        XCTAssertTrue(merged.meals.first?.detail.contains("sync pending") == true)
        XCTAssertTrue(merged.meals.first?.detail.contains("Open Food Facts") == true)

        let macroOnlyConfirmation = NutritionBarcodeConfirmation(
            proposalID: proposal.proposalID, barcode: proposal.barcode, basis: .per100g,
            mealAt: fetchedAt, productName: "Macro-only label", grams: 100, kcal: nil,
            proteinGrams: 6, carbsGrams: nil, fatGrams: nil, confirmedAt: fetchedAt
        )
        let macroOnly = try NutritionBarcodeFlow.confirm(macroOnlyConfirmation, for: proposal, now: now)
        let unknownCaloriesBase = FitnessNutritionSnapshot(
            calorieTarget: nil, caloriesConsumed: nil, sourceSupportedExpenditure: nil,
            macroValues: [FitnessMacroValue(name: "Protein", value: nil, target: nil, hue: .blue)],
            meals: [], hydrationMilliliters: nil, hydrationTargetMilliliters: nil,
            caffeineMilligrams: nil, alcoholUnits: nil
        )
        let macroOnlyMerged = unknownCaloriesBase.includingLocalBarcodeRecords([macroOnly], for: now, calendar: calendar)
        XCTAssertNil(macroOnlyMerged.caloriesConsumed, "Macro-only records must not invent a zero calorie total.")
        XCTAssertEqual(macroOnlyMerged.macroValues.first?.value, 6)
    }

    private func decode(_ json: String) throws -> NutritionBarcodeLookup {
        try JSONDecoder().decode(NutritionBarcodeLookup.self, from: Data(json.utf8))
    }

    private func baseFound(nutritionState: String, metrics: String, qualityFlags: String? = nil, basis: String = "per100g") -> String {
        let second = basis == "perServing" ? "\"perServing\":\(metrics)" : "\"per100g\":\(metrics)"
        let flags = qualityFlags.map { ", \"qualityFlags\":\($0)" } ?? ""
        return """
        {"schemaVersion":1,"state":"found","barcode":"3017620422003","product":{"name":"Example"},"nutritionState":"\(nutritionState)",\(second)\(flags),"provenance":{"source":"openfoodfacts","apiVersion":"v3.6","apiURL":"https://world.openfoodfacts.org/api/v3.6/product/3017620422003.json","fetchedAt":"\(fetchedAt)","databaseLicense":"ODbL-1.0","contentLicense":"DbCL-1.0","attribution":"Product data from Open Food Facts.","dataQualityWarning":"Open Food Facts data is volunteer-sourced; accuracy, completeness, and reliability are not guaranteed."}}
        """
    }
}
