import XCTest
@testable import LifeOS

private actor BarcodeTransportCallCounter {
    private(set) var count = 0

    func recordCall() {
        count += 1
    }
}

private enum HostileBarcodeTransportError: Error {
    case called
}

final class NutritionBarcodeTests: XCTestCase {
    private let fetchedAt = "2026-08-12T00:00:00Z"

    func testVisualFixtureBarcodeActionFailsClosedBeforeHostileTransport() async {
        let counter = BarcodeTransportCallCounter()
        let client = FitnessNutritionBarcodeLookupClient(usesVisualFixtures: true) { _ in
            await counter.recordCall()
            throw HostileBarcodeTransportError.called
        }

        do {
            _ = try await client.fetchNutritionBarcode("3017620422003")
            XCTFail("A visual fixture barcode action must fail closed.")
        } catch let error as FitnessNutritionBarcodeLookupClientError {
            XCTAssertEqual(error, .visualFixtureDisabled)
        } catch {
            XCTFail("Unexpected visual fixture barcode error: \(error)")
        }

        let callCount = await counter.count
        XCTAssertEqual(callCount, 0, "A visual fixture must never invoke the barcode transport.")
    }

    func testVisualFixtureNutritionPersistenceUsesIsolatedTemporaryStores() async throws {
        let fileManager = FileManager.default
        let configuration = FitnessNutritionPersistenceConfiguration.make(
            usesVisualFixtures: true,
            fileManager: fileManager
        )
        defer {
            if let directoryURL = configuration.directoryURL {
                try? fileManager.removeItem(at: directoryURL)
            }
        }

        let productionMealURL = try NutritionMealStore.defaultURL(fileManager: fileManager)
        let productionGoalURL = try NutritionGoalStore.defaultURL(fileManager: fileManager)
        let productionBarcodeURL = NutritionRecordStore.defaultPersistenceURL
        let barcodeStoreURL = await configuration.barcodeStore.url
        let productionMealBefore = fileManager.fileExists(atPath: productionMealURL.path)
            ? try Data(contentsOf: productionMealURL)
            : nil
        let productionGoalBefore = fileManager.fileExists(atPath: productionGoalURL.path)
            ? try Data(contentsOf: productionGoalURL)
            : nil
        let productionBarcodeBefore = fileManager.fileExists(atPath: productionBarcodeURL.path)
            ? try Data(contentsOf: productionBarcodeURL)
            : nil
        XCTAssertTrue(configuration.mealStore?.fileURL.path.hasPrefix(fileManager.temporaryDirectory.path) == true)
        XCTAssertTrue(configuration.goalStore?.fileURL.path.hasPrefix(fileManager.temporaryDirectory.path) == true)
        XCTAssertTrue(barcodeStoreURL.path.hasPrefix(fileManager.temporaryDirectory.path))
        XCTAssertNotEqual(configuration.mealStore?.fileURL, productionMealURL)
        XCTAssertNotEqual(configuration.goalStore?.fileURL, productionGoalURL)
        XCTAssertNotEqual(barcodeStoreURL, productionBarcodeURL)

        let meal = NutritionMeal(
            loggedAt: Date(timeIntervalSince1970: 1_800_300_000),
            timeZoneIdentifier: "Europe/Berlin",
            name: "Fixture meal",
            kcal: 400,
            proteinGrams: 30,
            carbGrams: 40,
            fatGrams: 10,
            provenance: .manual,
            createdAt: Date(timeIntervalSince1970: 1_800_300_000)
        )
        try configuration.mealStore?.addConfirmed(meal)
        XCTAssertTrue(fileManager.fileExists(atPath: configuration.mealStore?.fileURL.path ?? ""))
        XCTAssertEqual(
            productionMealBefore,
            fileManager.fileExists(atPath: productionMealURL.path) ? try Data(contentsOf: productionMealURL) : nil,
            "visual fixture meal writes must leave the production meal store unchanged"
        )
        XCTAssertEqual(
            productionGoalBefore,
            fileManager.fileExists(atPath: productionGoalURL.path) ? try Data(contentsOf: productionGoalURL) : nil,
            "visual fixture nutrition writes must leave the production goal store unchanged"
        )
        XCTAssertEqual(
            productionBarcodeBefore,
            fileManager.fileExists(atPath: productionBarcodeURL.path) ? try Data(contentsOf: productionBarcodeURL) : nil,
            "visual fixture nutrition writes must leave the production barcode store unchanged"
        )
    }

    func testBarcodeRequestGateRejectsStaleCompletionFromOlderGenerationForDisplayAndConfirm() throws {
        var gate = NutritionBarcodeRequestGate()
        let first = try XCTUnwrap(gate.begin(rawInput: "3017620422003"))
        let second = try XCTUnwrap(gate.begin(rawInput: "96385074"))

        // A transport is allowed to finish the cancelled A request late. Its
        // result must be rejected for both the visible proposal and the save
        // action once B owns the current generation.
        XCTAssertFalse(gate.accepts(first, visibleInput: first.barcode))
        XCTAssertFalse(gate.accepts(first, visibleInput: second.barcode))
        XCTAssertTrue(gate.accepts(second, visibleInput: second.barcode))
    }

    func testBarcodeRequestGateRejectsCompletionAfterDismissal() throws {
        var gate = NutritionBarcodeRequestGate()
        let request = try XCTUnwrap(gate.begin(rawInput: "3017620422003"))

        gate.invalidate() // The review sheet disappeared.

        XCTAssertFalse(gate.accepts(request, visibleInput: request.barcode))
    }

    func testBarcodeDraftRevisionIncludesEveryEditableBarcodeField() throws {
        let loggedAt = try XCTUnwrap(ISO8601DateFormatter().date(from: fetchedAt))
        let base = FitnessNutritionDraft(
            loggedAt: loggedAt,
            barcodeInput: "3017620422003",
            barcodeProductName: "Example",
            barcodeCalories: "500",
            barcodeProtein: "6",
            barcodeCarbohydrates: "50",
            barcodeFat: "25",
            barcodeGrams: "100",
            barcodeValuesEdited: false,
            barcodeBasis: .perServing,
            barcodeMealAt: fetchedAt
        )
        let mutations: [(String, (inout FitnessNutritionDraft) -> Void)] = [
            ("barcode input", { $0.barcodeInput = "96385074" }),
            ("product name", { $0.barcodeProductName = "Edited" }),
            ("calories", { $0.barcodeCalories = "501" }),
            ("protein", { $0.barcodeProtein = "7" }),
            ("carbohydrates", { $0.barcodeCarbohydrates = "51" }),
            ("fat", { $0.barcodeFat = "26" }),
            ("grams", { $0.barcodeGrams = "101" }),
            ("edit intent", { $0.barcodeValuesEdited = true }),
            ("basis", { $0.barcodeBasis = .per100g }),
            ("meal timestamp", { $0.barcodeMealAt = "2026-08-12T01:00:00Z" })
        ]

        for (label, mutate) in mutations {
            var candidate = base
            mutate(&candidate)
            XCTAssertNotEqual(
                base.barcodeDraftRevision,
                candidate.barcodeDraftRevision,
                "The barcode revision must include \(label)."
            )
            XCTAssertNotEqual(
                base.fingerprint,
                candidate.fingerprint,
                "The watched draft fingerprint must include \(label)."
            )
        }
    }

    func testBarcodeSaveStateRejectsDoubleActivationAndStaleCompletionWhileRetainingExactRetry() throws {
        let lookup = try decode(baseFound(
            nutritionState: "complete",
            metrics: #"{"kcal": 500, "proteinGrams": 6, "carbsGrams": 50, "fatGrams": 25}"#,
            basis: "perServing"
        ))
        let proposal = try NutritionBarcodeProposal(proposalID: "proposal-save-state", lookup: lookup)
        let confirmation = NutritionBarcodeConfirmation(
            proposalID: proposal.proposalID,
            barcode: proposal.barcode,
            basis: .perServing,
            mealAt: fetchedAt,
            productName: "Example",
            grams: 100,
            kcal: 500,
            proteinGrams: 6,
            carbsGrams: 50,
            fatGrams: 25,
            confirmedAt: fetchedAt
        )
        let now = try XCTUnwrap(ISO8601DateFormatter().date(from: fetchedAt))
        let record = try NutritionBarcodeFlow.confirm(confirmation, for: proposal, now: now)

        var state = FitnessNutritionBarcodeSaveState()
        let first = try XCTUnwrap(state.begin(draftRevision: "revision-1", record: record))
        XCTAssertTrue(state.isSaving)
        XCTAssertNil(state.begin(draftRevision: "revision-1", record: record), "A second activation must not start another write.")
        XCTAssertFalse(state.accepts(first, currentDraftRevision: "revision-2"), "A completion for an older revision must not be accepted for a newer edit.")

        state.invalidateActiveAttempt()
        let second = try XCTUnwrap(state.begin(draftRevision: "revision-2", record: record))
        XCTAssertFalse(state.accepts(first, currentDraftRevision: "revision-1"), "An older completion must lose ownership.")
        XCTAssertFalse(state.finish(first), "An older completion must not finish the newer write.")
        XCTAssertTrue(state.accepts(second, currentDraftRevision: "revision-2"))

        XCTAssertTrue(state.finish(second, retryable: true))
        let retry = try XCTUnwrap(state.retryableAttempt(for: "revision-2"))
        XCTAssertEqual(
            retry.record,
            record,
            "A failed attempt must retain the exact immutable payload for retry."
        )
        XCTAssertNil(state.retryableAttempt(for: "revision-1"), "An edited draft must not reuse the failed payload.")

        var successfulState = FitnessNutritionBarcodeSaveState()
        let successfulAttempt = try XCTUnwrap(successfulState.begin(draftRevision: "revision-success", record: record))
        XCTAssertTrue(successfulState.finish(successfulAttempt))
        XCTAssertNil(successfulState.retryableAttempt(for: "revision-success"), "A successful write must not expose a retry-only payload.")
    }

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

    func testPer100gNutritionScalesToTheAmountEaten() throws {
        let per100g = try NutritionBarcodeMacros(
            kcal: 539,
            proteinGrams: 6.3,
            carbsGrams: 57.5,
            fatGrams: 30.9
        )
        let eaten = try per100g.scaledFromPer100g(forGrams: 15)
        XCTAssertEqual(eaten.kcal!, 80.85, accuracy: 0.001)
        XCTAssertEqual(eaten.proteinGrams!, 0.945, accuracy: 0.001)
        XCTAssertEqual(eaten.carbsGrams!, 8.625, accuracy: 0.001)
        XCTAssertEqual(eaten.fatGrams!, 4.635, accuracy: 0.001)
        XCTAssertThrowsError(try per100g.scaledFromPer100g(forGrams: 5_000))
    }

    func testUneditedPer100gConfirmationIsScaledInsideTheConfirmationFlow() throws {
        let lookup = try decode(baseFound(
            nutritionState: "complete",
            metrics: #"{"kcal": 539, "proteinGrams": 6.3, "carbsGrams": 57.5, "fatGrams": 30.9}"#
        ))
        let proposal = try NutritionBarcodeProposal(proposalID: "proposal-scaled", lookup: lookup)
        let confirmation = NutritionBarcodeConfirmation(
            proposalID: proposal.proposalID,
            barcode: proposal.barcode,
            basis: .per100g,
            mealAt: fetchedAt,
            productName: "Reference values",
            grams: 15,
            // These are the untouched provider values. The explicit edit
            // state tells the flow to derive the amount eaten from grams.
            kcal: 539,
            proteinGrams: 6.3,
            carbsGrams: 57.5,
            fatGrams: 30.9,
            confirmedAt: fetchedAt,
            valuesAreEdited: false
        )
        let now = try XCTUnwrap(ISO8601DateFormatter().date(from: fetchedAt))
        let record = try NutritionBarcodeFlow.confirm(confirmation, for: proposal, now: now)
        XCTAssertEqual(record.kcal!, 80.85, accuracy: 0.001)
        XCTAssertEqual(record.proteinGrams!, 0.945, accuracy: 0.001)
        XCTAssertEqual(record.carbsGrams!, 8.625, accuracy: 0.001)
        XCTAssertEqual(record.fatGrams!, 4.635, accuracy: 0.001)
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

        let missingGrams = NutritionBarcodeConfirmation(
            proposalID: proposal.proposalID, barcode: proposal.barcode, basis: .per100g,
            mealAt: fetchedAt, productName: "Edited name", grams: nil,
            kcal: 500, proteinGrams: 6, carbsGrams: 50, fatGrams: 25, confirmedAt: fetchedAt
        )
        XCTAssertThrowsError(try NutritionBarcodeFlow.confirm(missingGrams, for: proposal, now: now))

        let zeroGrams = NutritionBarcodeConfirmation(
            proposalID: proposal.proposalID, barcode: proposal.barcode, basis: .per100g,
            mealAt: fetchedAt, productName: "Edited name", grams: 0,
            kcal: 500, proteinGrams: 6, carbsGrams: 50, fatGrams: 25, confirmedAt: fetchedAt
        )
        XCTAssertThrowsError(try NutritionBarcodeFlow.confirm(zeroGrams, for: proposal, now: now))

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
        let lookup = try decode(baseFoundWithBothBases())
        let proposal = try NutritionBarcodeProposal(proposalID: "proposal-retry", lookup: lookup)
        let confirmation = NutritionBarcodeConfirmation(
            proposalID: proposal.proposalID, barcode: proposal.barcode, basis: .per100g,
            mealAt: fetchedAt, productName: "First label", grams: 100, kcal: 500,
            proteinGrams: 6, carbsGrams: 50, fatGrams: 25, confirmedAt: fetchedAt
        )
        let now = try XCTUnwrap(ISO8601DateFormatter().date(from: fetchedAt))
        let first = try NutritionBarcodeFlow.confirm(
            confirmation,
            for: proposal,
            now: now,
            recordID: UUID(uuidString: "AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAAA")
        )
        let revised = NutritionBarcodeConfirmation(
            proposalID: proposal.proposalID, barcode: proposal.barcode, basis: .perServing,
            mealAt: fetchedAt, productName: "Revised label", grams: 15, kcal: 81,
            proteinGrams: 0.95, carbsGrams: 8.63, fatGrams: 4.64, confirmedAt: fetchedAt
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

    func testBarcodeDraftCorrectionKeepsOneRecordAndClearsDirtyStateForSavedRevision() async throws {
        let lookup = try decode(baseFoundWithBothBases())
        let proposal = try NutritionBarcodeProposal(proposalID: "proposal-draft-correction", lookup: lookup)
        let now = try XCTUnwrap(ISO8601DateFormatter().date(from: fetchedAt))
        var draft = FitnessNutritionDraft(
            loggedAt: now,
            barcodeInput: proposal.barcode,
            barcodeProductName: "Example",
            barcodeCalories: "81",
            barcodeProtein: "0.95",
            barcodeCarbohydrates: "8.63",
            barcodeFat: "4.64",
            barcodeGrams: "15",
            barcodeValuesEdited: true,
            barcodeBasis: .perServing,
            barcodeMealAt: fetchedAt
        )
        let first = try NutritionBarcodeFlow.confirm(
            NutritionBarcodeConfirmation(
                proposalID: proposal.proposalID,
                barcode: proposal.barcode,
                basis: .perServing,
                mealAt: fetchedAt,
                productName: "Example",
                grams: 15,
                kcal: 81,
                proteinGrams: 0.95,
                carbsGrams: 8.63,
                fatGrams: 4.64,
                confirmedAt: fetchedAt
            ),
            for: proposal,
            now: now,
            recordID: UUID(uuidString: "BBBBBBBB-BBBB-BBBB-BBBB-BBBBBBBBBBBB")
        )
        let firstRevision = draft.barcodeDraftRevision
        draft.markBarcodeDurablySaved(first, draftRevision: firstRevision)
        XCTAssertTrue(draft.isBarcodeDurablyCurrent)
        XCTAssertFalse(draft.isDirty, "A successful barcode save must make the parent draft clean.")

        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let store = NutritionRecordStore(url: directory.appendingPathComponent("nutrition.json"))
        try await store.save(first)

        draft.barcodeBasis = .per100g
        draft.barcodeGrams = "100"
        draft.barcodeCalories = "500"
        draft.barcodeProtein = "6"
        draft.barcodeCarbohydrates = "50"
        draft.barcodeFat = "25"
        XCTAssertTrue(draft.isDirty, "Changing the basis or values must invalidate the saved revision.")

        let second = try NutritionBarcodeFlow.confirm(
            NutritionBarcodeConfirmation(
                proposalID: proposal.proposalID,
                barcode: proposal.barcode,
                basis: .per100g,
                mealAt: fetchedAt,
                productName: "Example",
                grams: 100,
                kcal: 500,
                proteinGrams: 6,
                carbsGrams: 50,
                fatGrams: 25,
                confirmedAt: fetchedAt
            ),
            for: proposal,
            now: now,
            recordID: try XCTUnwrap(draft.barcodeRecordID)
        )
        XCTAssertEqual(second.id, first.id, "A correction must retain the parent-owned record identity.")
        try await store.save(second)
        draft.markBarcodeDurablySaved(second, draftRevision: draft.barcodeDraftRevision)

        XCTAssertTrue(draft.isBarcodeDurablyCurrent)
        XCTAssertFalse(draft.isDirty, "The draft must be clean for the exact saved correction revision.")
        let records = try await store.load()
        XCTAssertEqual(records.count, 1)
        XCTAssertEqual(records.first?.id, first.id)
        XCTAssertEqual(records.first?.basis, .per100g)
        XCTAssertEqual(records.first?.kcal, 500)

        let reopened = FitnessNutritionDraftFlow.reopenOrStart(
            current: draft,
            selectedDate: now.addingTimeInterval(86_400)
        )
        XCTAssertNotEqual(reopened.draftID, draft.draftID, "A clean saved draft should not reopen as an unsaved meal.")

        draft.barcodeCalories = "501"
        XCTAssertTrue(draft.isDirty)
        XCTAssertEqual(
            FitnessNutritionDraftFlow.reopenOrStart(current: draft, selectedDate: now),
            draft,
            "A changed saved draft must remain available when the sheet is reopened."
        )

        var freshLookup = draft
        freshLookup.beginNewBarcodeLookup()
        XCTAssertNil(freshLookup.barcodeRecordID)
        XCTAssertNil(freshLookup.barcodeDurableReceipt)
    }

    func testNewBarcodeLookupKeepsExplicitMealsSeparateWithoutDeletingUnrelatedRecords() async throws {
        let lookup = try decode(baseFoundWithBothBases())
        let firstProposal = try NutritionBarcodeProposal(proposalID: "proposal-first-lookup", lookup: lookup)
        let secondProposal = try NutritionBarcodeProposal(proposalID: "proposal-second-lookup", lookup: lookup)
        let now = try XCTUnwrap(ISO8601DateFormatter().date(from: fetchedAt))
        let confirmation = { (proposal: NutritionBarcodeProposal, name: String) in
            NutritionBarcodeConfirmation(
                proposalID: proposal.proposalID,
                barcode: proposal.barcode,
                basis: .perServing,
                mealAt: self.fetchedAt,
                productName: name,
                grams: 15,
                kcal: 81,
                proteinGrams: 0.95,
                carbsGrams: 8.63,
                fatGrams: 4.64,
                confirmedAt: self.fetchedAt
            )
        }
        let first = try NutritionBarcodeFlow.confirm(confirmation(firstProposal, "First"), for: firstProposal, now: now)
        let corrected = try NutritionBarcodeFlow.confirm(confirmation(firstProposal, "Corrected"), for: firstProposal, now: now)
        let newLookup = try NutritionBarcodeFlow.confirm(confirmation(secondProposal, "Separate"), for: secondProposal, now: now)
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).appendingPathComponent("nutrition.json")
        let store = NutritionRecordStore(url: url)

        try await store.save(first)
        try await store.save(corrected)
        try await store.save(newLookup)

        let records = try await store.load()
        XCTAssertEqual(records.count, 2)
        XCTAssertEqual(Set(records.map(\.proposalID)), Set([firstProposal.proposalID, secondProposal.proposalID]))
        XCTAssertTrue(records.contains(where: { $0.productName == "Corrected" }))
        XCTAssertTrue(records.contains(where: { $0.productName == "Separate" }))
    }

    func testFreshBarcodeRequestGatesCreateDistinctProposalsAndPersistBothMeals() async throws {
        let lookup = try decode(baseFoundWithBothBases())
        let barcode = "3017620422003"

        // Model two independent review sheets.  Both gates begin at the same
        // local generation, so a proposal ID derived from either gate would
        // collide.  The production proposal initializer must provide the
        // cross-sheet/process identity instead.
        var firstGate = NutritionBarcodeRequestGate()
        let firstRequest = try XCTUnwrap(firstGate.begin(rawInput: barcode))
        var secondGate = NutritionBarcodeRequestGate()
        let secondRequest = try XCTUnwrap(secondGate.begin(rawInput: barcode))
        XCTAssertTrue(firstGate.accepts(firstRequest, visibleInput: barcode))
        XCTAssertTrue(secondGate.accepts(secondRequest, visibleInput: barcode))

        let firstProposal = try NutritionBarcodeProposal(lookup: lookup)
        let secondProposal = try NutritionBarcodeProposal(lookup: lookup)
        XCTAssertNotEqual(firstProposal.proposalID, secondProposal.proposalID)

        let now = try XCTUnwrap(ISO8601DateFormatter().date(from: fetchedAt))
        let confirmation: (NutritionBarcodeProposal, String) -> NutritionBarcodeConfirmation = { proposal, name in
            NutritionBarcodeConfirmation(
                proposalID: proposal.proposalID,
                barcode: proposal.barcode,
                basis: .perServing,
                mealAt: self.fetchedAt,
                productName: name,
                grams: 15,
                kcal: 81,
                proteinGrams: 0.95,
                carbsGrams: 8.63,
                fatGrams: 4.64,
                confirmedAt: self.fetchedAt
            )
        }
        let first = try NutritionBarcodeFlow.confirm(
            confirmation(firstProposal, "First sheet"),
            for: firstProposal,
            now: now
        )
        let second = try NutritionBarcodeFlow.confirm(
            confirmation(secondProposal, "Second sheet"),
            for: secondProposal,
            now: now
        )
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathComponent("nutrition.json")
        let store = NutritionRecordStore(url: url)

        try await store.save(first)
        try await store.save(second)

        let records = try await store.load()
        XCTAssertEqual(records.count, 2)
        XCTAssertEqual(Set(records.map(\.proposalID)), Set([firstProposal.proposalID, secondProposal.proposalID]))
        XCTAssertEqual(Set(records.map(\.id)).count, 2)
        XCTAssertEqual(Set(records.compactMap(\.productName)), Set(["First sheet", "Second sheet"]))
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
        XCTAssertTrue(merged.meals.first?.detail.contains("confirmed locally") == true)
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

    private func baseFoundWithBothBases() -> String {
        """
        {"schemaVersion":1,"state":"found","barcode":"3017620422003","product":{"name":"Example"},"nutritionState":"complete","per100g":{"kcal":539,"proteinGrams":6.3,"carbsGrams":57.5,"fatGrams":30.9},"perServing":{"kcal":81,"proteinGrams":0.95,"carbsGrams":8.63,"fatGrams":4.64},"provenance":{"source":"openfoodfacts","apiVersion":"v3.6","apiURL":"https://world.openfoodfacts.org/api/v3.6/product/3017620422003.json","fetchedAt":"\(fetchedAt)","databaseLicense":"ODbL-1.0","contentLicense":"DbCL-1.0","attribution":"Product data from Open Food Facts.","dataQualityWarning":"Open Food Facts data is volunteer-sourced; accuracy, completeness, and reliability are not guaranteed."}}
        """
    }
}
