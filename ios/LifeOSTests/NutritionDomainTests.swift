import Foundation
import XCTest
@testable import LifeOS

final class NutritionDomainTests: XCTestCase {
    private let hashA = String(repeating: "a", count: 64)
    private let hashB = String(repeating: "b", count: 64)

    private func iso(_ date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.string(from: date)
    }

    private func canonicalBase64(for byteLength: Int) -> String {
        let encodedLength = ((byteLength + 2) / 3) * 4
        let padding: Int
        switch byteLength % 3 {
        case 1: padding = 2
        case 2: padding = 1
        default: padding = 0
        }
        return String(repeating: "A", count: encodedLength - padding)
            + String(repeating: "=", count: padding)
    }

    private func image(id: String, byteLength: Int = 1, hash: String,
                       width: Int = 3_000, height: Int = 2_000) throws -> FoodPhotoImageDescriptor {
        return try FoodPhotoImageDescriptor(
            imageID: id, mimeType: .jpeg, byteLength: byteLength,
            width: width, height: height, sanitized: true,
            inlineDataBase64: canonicalBase64(for: byteLength), sha256: hash
        )
    }

    private func baseManifest(capturedAt: String) throws -> FoodPhotoManifest {
        try FoodPhotoManifest(
            mealID: "meal-1", requestID: "food-request-1", capturedAt: capturedAt,
            clientTimeZone: "Europe/Berlin", inferenceConsent: true,
            images: [try image(id: "image-a", hash: hashA), try image(id: "image-b", hash: hashB)],
            userContext: try FoodPhotoUserContext(
                plateDiameterMm: 270, knownReference: "standard dinner plate",
                portionWeightGrams: 250, packageLabelContext: "plain Greek yogurt, 2 percent fat",
                note: "Lunch, photographed from above"
            )
        )
    }

    private func range(_ estimate: Double, _ min: Double? = nil, _ max: Double? = nil) throws -> FoodEstimateRange {
        try FoodEstimateRange(estimate: estimate, min: min ?? estimate, max: max ?? estimate)
    }

    private func baseProposal(manifest: FoodPhotoManifest, at timestamp: String) throws -> FoodEstimateProposal {
        let yogurt = try FoodEstimateItem(
            itemID: "item-yogurt", enteredLabel: "Greek yogurt", estimatedLabel: "Greek yogurt",
            labelSource: .recognized, quantity: 1, unit: .serving,
            grams: try range(200, 190, 210), calories: try range(150, 130, 170),
            protein: try range(20, 18, 22), carbs: try range(8, 6, 10), fat: try range(5, 4, 6),
            fiber: try range(0), confidence: .high,
            uncertaintyNotes: ["Brand and portion were user-provided."], alternatives: ["Skyr"],
            flags: [.needsConfirmation]
        )
        let berries = try FoodEstimateItem(
            itemID: "item-berries", estimatedLabel: "Mixed berries", labelSource: .assumed,
            quantity: 1, unit: .portion,
            grams: try range(50, 40, 60), calories: try range(50, 40, 60),
            protein: try range(1, 0.5, 1.5), carbs: try range(12, 10, 14), fat: try range(0, 0, 0.5),
            fiber: try range(3, 2, 4), confidence: .medium,
            uncertaintyNotes: ["Exact fruit mix and portion are uncertain."],
            flags: [.needsConfirmation, .unknownPortion]
        )
        let provenance = try FoodEstimateProvenance(
            provider: "lifeos-food-gateway", modelIdentifier: "gemini-food",
            modelVersion: "2026-08", policyVersion: "nutrition-v1", requestTimestamp: timestamp,
            sanitizedImageHashes: [
                try FoodEstimateImageHashReference(imageID: "image-a", sha256: hashA),
                try FoodEstimateImageHashReference(imageID: "image-b", sha256: hashB),
            ]
        )
        return try FoodEstimateProposal(
            mealID: manifest.mealID, proposalID: "proposal-1", requestID: manifest.requestID,
            generatedAt: timestamp, provenance: provenance, items: [yogurt, berries],
            totals: try FoodEstimateTotals(
                grams: try range(250, 230, 270), calories: try range(200, 170, 230),
                protein: try range(21, 18.5, 23.5), carbs: try range(20, 16, 24),
                fat: try range(5, 4, 6.5), fiber: try range(3, 2, 4)
            ),
            flags: [.needsConfirmation, .unknownPortion],
            uncertaintyNotes: ["Hidden oil and exact portion remain unverified."]
        )
    }

    private func confirmedMeal(manifest: FoodPhotoManifest, proposal: FoodEstimateProposal, at timestamp: String) throws -> FoodConfirmationRequest {
        let item = try FoodConfirmedItem(
            itemID: "item-yogurt", label: "Greek yogurt", quantity: 1, unit: .serving,
            grams: 200, calories: 150, protein: 20, carbs: 8, fat: 5, fiber: 0
        )
        return try FoodConfirmationRequest(
            mealID: manifest.mealID, requestID: manifest.requestID, proposalID: proposal.proposalID,
            action: .confirm, mealName: "Greek yogurt with berries", mealAt: timestamp,
            items: [item], totals: try FoodConfirmedTotals(
                grams: 200, calories: 150, protein: 20, carbs: 8, fat: 5, fiber: 0
            ), confirmedAt: timestamp
        )
    }

    private func jsonObject<T: Encodable>(_ value: T) throws -> [String: Any] {
        let data = try JSONEncoder().encode(value)
        return try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    private func decode<T: Decodable>(_ type: T.Type, object: [String: Any]) throws -> T {
        let data = try JSONSerialization.data(withJSONObject: object)
        return try JSONDecoder().decode(type, from: data)
    }

    func testHappyPathBindsManifestProposalAndEditableConfirmation() throws {
        let capture = Date(timeIntervalSinceNow: -120)
        let generated = Date(timeIntervalSinceNow: -60)
        let manifest = try baseManifest(capturedAt: iso(capture))
        let proposal = try baseProposal(manifest: manifest, at: iso(generated))

        XCTAssertNoThrow(try validateFoodEstimateProposalAgainstManifest(proposal, manifest))
        let confirmation = try confirmedMeal(manifest: manifest, proposal: proposal, at: iso(Date(timeIntervalSinceNow: -30)))
        XCTAssertEqual(try validateFoodConfirmationAgainstProposal(confirmation, proposal).action, .confirm)

        let edited = try FoodConfirmationRequest(
            mealID: confirmation.mealID, requestID: confirmation.requestID, proposalID: confirmation.proposalID,
            action: .editAndConfirm, mealName: confirmation.mealName, mealAt: confirmation.mealAt,
            items: confirmation.items, totals: confirmation.totals, confirmedAt: confirmation.confirmedAt,
            correctionNotes: "Adjusted portion from the package label."
        )
        XCTAssertEqual(try validateFoodConfirmationAgainstProposal(edited, proposal).action, .editAndConfirm)
    }

    func testManifestRejectsTransferWithoutOptInAndUnsafeOrOversizedPhotos() throws {
        let timestamp = iso(Date(timeIntervalSinceNow: -60))
        let manifest = try baseManifest(capturedAt: timestamp)
        var object = try jsonObject(manifest)

        object["inferenceConsent"] = false
        XCTAssertThrowsError(try decode(FoodPhotoManifest.self, object: object))

        object = try jsonObject(manifest)
        var images = try XCTUnwrap(object["images"] as? [[String: Any]])
        images[0]["filename"] = "meal.jpg"
        object["images"] = images
        XCTAssertThrowsError(try decode(FoodPhotoManifest.self, object: object))

        object = try jsonObject(manifest)
        images = try XCTUnwrap(object["images"] as? [[String: Any]])
        images[0]["inlineDataBase64"] = "data:image/jpeg;base64,AA=="
        object["images"] = images
        XCTAssertThrowsError(try decode(FoodPhotoManifest.self, object: object))

        object = try jsonObject(manifest)
        images = try XCTUnwrap(object["images"] as? [[String: Any]])
        images[0]["byteLength"] = 20 * 1_024 * 1_024 + 1
        object["images"] = images
        XCTAssertThrowsError(try decode(FoodPhotoManifest.self, object: object))

        var future = try jsonObject(manifest)
        future["capturedAt"] = iso(Date(timeIntervalSinceNow: 60))
        XCTAssertThrowsError(try decode(FoodPhotoManifest.self, object: future))

        var unsafeZone = try jsonObject(manifest)
        unsafeZone["clientTimeZone"] = "Europe/../Berlin"
        XCTAssertThrowsError(try decode(FoodPhotoManifest.self, object: unsafeZone))

        XCTAssertThrowsError(try FoodPhotoManifest(
            mealID: manifest.mealID, requestID: manifest.requestID, capturedAt: timestamp,
            clientTimeZone: manifest.clientTimeZone, inferenceConsent: true,
            images: [try image(id: "image-a", hash: hashA), try image(id: "image-a", hash: hashB)]
        ))
        XCTAssertThrowsError(try FoodPhotoManifest(
            mealID: manifest.mealID, requestID: manifest.requestID, capturedAt: timestamp,
            clientTimeZone: manifest.clientTimeZone, inferenceConsent: true,
            images: [
                try image(id: "image-a", hash: hashA), try image(id: "image-b", hash: hashB),
                try image(id: "image-c", hash: String(repeating: "c", count: 64)),
                try image(id: "image-d", hash: String(repeating: "d", count: 64)),
            ]
        ))
        let threeImageManifest = try FoodPhotoManifest(
            mealID: manifest.mealID, requestID: manifest.requestID, capturedAt: timestamp,
            clientTimeZone: manifest.clientTimeZone, inferenceConsent: true,
            images: [
                try image(id: "image-a", hash: hashA), try image(id: "image-b", hash: hashB),
                try image(id: "image-c", hash: String(repeating: "c", count: 64)),
            ]
        )
        XCTAssertEqual(threeImageManifest.images.count, 3)

        let tenMiB = 10 * 1_024 * 1_024
        let exactLimit = try FoodPhotoManifest(
            mealID: manifest.mealID, requestID: manifest.requestID, capturedAt: timestamp,
            clientTimeZone: manifest.clientTimeZone, inferenceConsent: true,
            images: [
                try image(id: "large-a", byteLength: tenMiB, hash: hashA, width: 1_000, height: 1_000),
                try image(id: "large-b", byteLength: tenMiB, hash: hashB, width: 1_000, height: 1_000),
            ]
        )
        XCTAssertEqual(exactLimit.images.reduce(0) { $0 + $1.byteLength }, 20 * 1_024 * 1_024)
        XCTAssertThrowsError(try FoodPhotoManifest(
            mealID: manifest.mealID, requestID: manifest.requestID, capturedAt: timestamp,
            clientTimeZone: manifest.clientTimeZone, inferenceConsent: true,
            images: [
                try image(id: "large-a", byteLength: tenMiB + 1, hash: hashA, width: 1_000, height: 1_000),
                try image(id: "large-b", byteLength: tenMiB, hash: hashB, width: 1_000, height: 1_000),
            ]
        ))
    }

    func testManifestRejectsUnknownTimeZoneIdentifier() throws {
        let timestamp = iso(Date(timeIntervalSinceNow: -60))
        let manifest = try baseManifest(capturedAt: timestamp)
        var object = try jsonObject(manifest)
        object["clientTimeZone"] = "Europe/NotARealZone"

        XCTAssertThrowsError(try decode(FoodPhotoManifest.self, object: object))
    }

    func testManifestAndProposalRejectCredentialOrAdviceTextAndBadRanges() throws {
        let timestamp = iso(Date(timeIntervalSinceNow: -60))
        let manifest = try baseManifest(capturedAt: timestamp)
        var manifestObject = try jsonObject(manifest)
        var context = try XCTUnwrap(manifestObject["userContext"] as? [String: Any])
        context["note"] = "Bearer abc123"
        manifestObject["userContext"] = context
        XCTAssertThrowsError(try decode(FoodPhotoManifest.self, object: manifestObject))

        let proposal = try baseProposal(manifest: manifest, at: timestamp)
        var proposalObject = try jsonObject(proposal)
        proposalObject["accuracyClaim"] = "at least 80% per meal"
        XCTAssertThrowsError(try decode(FoodEstimateProposal.self, object: proposalObject))

        var provenance = try XCTUnwrap(proposalObject["provenance"] as? [String: Any])
        provenance["provider"] = "apiKey=secret"
        proposalObject["provenance"] = provenance
        XCTAssertThrowsError(try decode(FoodEstimateProposal.self, object: proposalObject))

        var items = try XCTUnwrap(proposalObject["items"] as? [[String: Any]])
        items[0]["calories"] = ["estimate": 1_000, "min": 1_000, "max": 1_000]
        proposalObject["items"] = items
        XCTAssertThrowsError(try decode(FoodEstimateProposal.self, object: proposalObject))

        proposalObject = try jsonObject(proposal)
        items = try XCTUnwrap(proposalObject["items"] as? [[String: Any]])
        proposalObject["items"] = [items[0], items[0]]
        XCTAssertThrowsError(try decode(FoodEstimateProposal.self, object: proposalObject))
    }

    func testProposalLineageRequiresExactHashSetAndOrder() throws {
        let capture = Date(timeIntervalSinceNow: -120)
        let generated = Date(timeIntervalSinceNow: -60)
        let manifest = try baseManifest(capturedAt: iso(capture))
        let proposal = try baseProposal(manifest: manifest, at: iso(generated))
        XCTAssertNoThrow(try validateFoodEstimateProposalAgainstManifest(proposal, manifest))

        let swapped = try FoodEstimateProvenance(
            provider: proposal.provenance.provider, modelIdentifier: proposal.provenance.modelIdentifier,
            modelVersion: proposal.provenance.modelVersion, policyVersion: proposal.provenance.policyVersion,
            requestTimestamp: proposal.provenance.requestTimestamp,
            sanitizedImageHashes: [proposal.provenance.sanitizedImageHashes[1], proposal.provenance.sanitizedImageHashes[0]]
        )
        let swappedProposal = try FoodEstimateProposal(
            mealID: proposal.mealID, proposalID: proposal.proposalID, requestID: proposal.requestID,
            generatedAt: proposal.generatedAt, provenance: swapped, items: proposal.items,
            totals: proposal.totals, flags: proposal.flags, uncertaintyNotes: proposal.uncertaintyNotes
        )
        XCTAssertThrowsError(try validateFoodEstimateProposalAgainstManifest(swappedProposal, manifest))

        let altered = try FoodEstimateProvenance(
            provider: proposal.provenance.provider, modelIdentifier: proposal.provenance.modelIdentifier,
            modelVersion: proposal.provenance.modelVersion, policyVersion: proposal.provenance.policyVersion,
            requestTimestamp: proposal.provenance.requestTimestamp,
            sanitizedImageHashes: [try FoodEstimateImageHashReference(imageID: "image-a", sha256: hashB), proposal.provenance.sanitizedImageHashes[1]]
        )
        let alteredProposal = try FoodEstimateProposal(
            mealID: proposal.mealID, proposalID: proposal.proposalID, requestID: proposal.requestID,
            generatedAt: proposal.generatedAt, provenance: altered, items: proposal.items,
            totals: proposal.totals, flags: proposal.flags, uncertaintyNotes: proposal.uncertaintyNotes
        )
        XCTAssertThrowsError(try validateFoodEstimateProposalAgainstManifest(alteredProposal, manifest))
    }

    func testConfirmationIsMandatoryAndRejectCarriesNoMeal() throws {
        let timestamp = iso(Date(timeIntervalSinceNow: -60))
        let manifest = try baseManifest(capturedAt: timestamp)
        let proposal = try baseProposal(manifest: manifest, at: timestamp)
        let rejected = try FoodConfirmationRequest(
            mealID: manifest.mealID, requestID: manifest.requestID, proposalID: proposal.proposalID,
            action: .reject, rejectedAt: timestamp, reason: "Portion was not clear."
        )
        XCTAssertEqual(try validateFoodConfirmationAgainstProposal(rejected, proposal).action, .reject)
        XCTAssertNil(rejected.items)
        XCTAssertNil(rejected.totals)

        XCTAssertThrowsError(try FoodConfirmationRequest(
            mealID: manifest.mealID, requestID: manifest.requestID, proposalID: proposal.proposalID,
            action: .reject, items: [], rejectedAt: timestamp
        ))
        XCTAssertThrowsError(try FoodConfirmationRequest(
            mealID: manifest.mealID, requestID: manifest.requestID, proposalID: proposal.proposalID,
            action: .confirm, mealAt: timestamp, items: [], totals: try FoodConfirmedTotals(
                grams: 1, calories: 1, protein: 0, carbs: 0, fat: 0
            ), confirmedAt: timestamp
        ))
    }

    func testConfirmationEditsNeedCorrectTotalsAndPreserveLineage() throws {
        let capture = Date(timeIntervalSinceNow: -120)
        let generated = Date(timeIntervalSinceNow: -60)
        let manifest = try baseManifest(capturedAt: iso(capture))
        let proposal = try baseProposal(manifest: manifest, at: iso(generated))
        let confirmation = try confirmedMeal(manifest: manifest, proposal: proposal, at: iso(Date(timeIntervalSinceNow: -30)))

        var object = try jsonObject(confirmation)
        var totals = try XCTUnwrap(object["totals"] as? [String: Any])
        totals["calories"] = 151
        object["totals"] = totals
        XCTAssertThrowsError(try decode(FoodConfirmationRequest.self, object: object))

        object = try jsonObject(confirmation)
        object["mealID"] = "other-meal"
        let mismatched = try decode(FoodConfirmationRequest.self, object: object)
        XCTAssertThrowsError(try validateFoodConfirmationAgainstProposal(mismatched, proposal))

        object = try jsonObject(confirmation)
        object["action"] = "edit_and_confirm"
        XCTAssertThrowsError(try decode(FoodConfirmationRequest.self, object: object))

        object = try jsonObject(confirmation)
        object["diagnosis"] = "not allowed"
        XCTAssertThrowsError(try decode(FoodConfirmationRequest.self, object: object))
    }

    func testWidgetNutritionRedactionAndConnectorConsentFailClosed() {
        let observedAt = Date(timeIntervalSinceNow: -60)
        let fixture = WidgetSafeNutritionSummary.demo(at: observedAt)
        let redacted = FutureWidgetSnapshot(
            generatedAt: observedAt,
            privacyMode: .redacted,
            nutrition: fixture
        )
        XCTAssertEqual(redacted.nutritionDisplayState(at: observedAt), .redacted)
        XCTAssertNil(redacted.nutrition.caloriesEaten.value)
        XCTAssertNil(redacted.nutrition.qualityLabel)
        XCTAssertNil(redacted.nutrition.provenanceLabel)

        let observedMetric = WidgetNutritionMetric(
            value: 1_860,
            state: .fresh,
            observedAt: observedAt,
            sourceLabel: "DEMO · NOT LIVE"
        )
        let denied = WidgetSafeNutritionSummary(
            connector: .connected,
            consent: .notGranted,
            caloriesEaten: observedMetric,
            provenanceLabel: "DEMO · NOT LIVE"
        )
        XCTAssertNil(denied.caloriesEaten.value)
        XCTAssertNil(denied.provenanceLabel)
        XCTAssertEqual(denied.displayState(at: observedAt), .unavailable)

        let disconnected = WidgetSafeNutritionSummary(
            connector: .unavailable,
            consent: .granted,
            caloriesEaten: observedMetric
        )
        XCTAssertNil(disconnected.caloriesEaten.value)
    }

    func testWidgetNutritionMetricsRemainIndependentlyStaleAndUnavailable() {
        let now = Date(timeIntervalSinceNow: -60)
        let old = now.addingTimeInterval(-(futureWidgetFreshnessWindow + 1))
        let fresh = WidgetNutritionMetric(value: 1_860, state: .fresh, observedAt: now, sourceLabel: "DEMO · NOT LIVE")
        let stale = WidgetNutritionMetric(value: 194, state: .fresh, observedAt: old, sourceLabel: "DEMO · NOT LIVE")
        let summary = WidgetSafeNutritionSummary(
            connector: .connected,
            consent: .granted,
            caloriesEaten: fresh,
            calorieGoal: .unavailable(),
            carbsGrams: stale,
            qualityScore: .redacted()
        )
        XCTAssertEqual(summary.caloriesEaten.state(at: now), .fresh)
        XCTAssertEqual(summary.calorieGoal.state(at: now), .unavailable)
        XCTAssertEqual(summary.carbsGrams.state(at: now), .stale)
        XCTAssertEqual(summary.qualityScore.state(at: now), .redacted)
    }

    func testWidgetNutritionStrictDecodingRejectsUnsafeMetricPayloads() throws {
        let generatedAt = Date(timeIntervalSinceNow: -60)
        let snapshot = FutureWidgetSnapshot(
            generatedAt: generatedAt,
            privacyMode: .summaryAllowed,
            nutrition: .demo(at: generatedAt)
        )
        let encoded = try JSONEncoder.lifeOS.encode(snapshot)

        var unknown = try XCTUnwrap(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        unknown["mealName"] = "must not cross widget boundary"
        XCTAssertNil(FutureWidgetSnapshotStore.decode(try JSONSerialization.data(withJSONObject: unknown), now: generatedAt))

        var qualityOutOfRange = try XCTUnwrap(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        var nutrition = try XCTUnwrap(qualityOutOfRange["nutrition"] as? [String: Any])
        var quality = try XCTUnwrap(nutrition["qualityScore"] as? [String: Any])
        quality["value"] = 101
        nutrition["qualityScore"] = quality
        qualityOutOfRange["nutrition"] = nutrition
        XCTAssertNil(FutureWidgetSnapshotStore.decode(try JSONSerialization.data(withJSONObject: qualityOutOfRange), now: generatedAt))

        var mismatchedState = try XCTUnwrap(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        nutrition = try XCTUnwrap(mismatchedState["nutrition"] as? [String: Any])
        var fat = try XCTUnwrap(nutrition["fatGrams"] as? [String: Any])
        fat["state"] = "fresh"
        fat.removeValue(forKey: "value")
        fat.removeValue(forKey: "observedAt")
        fat.removeValue(forKey: "sourceLabel")
        nutrition["fatGrams"] = fat
        mismatchedState["nutrition"] = nutrition
        XCTAssertNil(FutureWidgetSnapshotStore.decode(try JSONSerialization.data(withJSONObject: mismatchedState), now: generatedAt))

        var futureObservation = try XCTUnwrap(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        nutrition = try XCTUnwrap(futureObservation["nutrition"] as? [String: Any])
        var calories = try XCTUnwrap(nutrition["caloriesEaten"] as? [String: Any])
        calories["observedAt"] = "2999-01-01T00:00:00Z"
        nutrition["caloriesEaten"] = calories
        futureObservation["nutrition"] = nutrition
        XCTAssertNil(FutureWidgetSnapshotStore.decode(try JSONSerialization.data(withJSONObject: futureObservation), now: generatedAt))

        var mixedOldAndFuture = try XCTUnwrap(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        nutrition = try XCTUnwrap(mixedOldAndFuture["nutrition"] as? [String: Any])
        var mixedCalories = try XCTUnwrap(nutrition["caloriesEaten"] as? [String: Any])
        var mixedCarbs = try XCTUnwrap(nutrition["carbsGrams"] as? [String: Any])
        mixedCalories["observedAt"] = iso(generatedAt.addingTimeInterval(1))
        mixedCarbs["observedAt"] = iso(generatedAt.addingTimeInterval(-(futureWidgetFreshnessWindow + 1)))
        nutrition["caloriesEaten"] = mixedCalories
        nutrition["carbsGrams"] = mixedCarbs
        mixedOldAndFuture["nutrition"] = nutrition
        XCTAssertNil(
            FutureWidgetSnapshotStore.decode(
                try JSONSerialization.data(withJSONObject: mixedOldAndFuture),
                now: generatedAt
            ),
            "A summary with an old metric and a future metric must fail closed"
        )
    }

    func testPhotoLineageAndRetentionPolicyKeepDeletionExplicit() throws {
        let now = Date(timeIntervalSinceNow: -60)
        let hash = try FoodEstimateImageHashReference(
            imageID: "image-a",
            sha256: String(repeating: "a", count: 64)
        )
        let lineage = try NutritionMealPhotoLineage(
            proposalID: "proposal-1",
            requestID: "request-1",
            requestTimestamp: iso(now.addingTimeInterval(-60)),
            generatedAt: iso(now.addingTimeInterval(-30)),
            provider: "gateway-food-provider",
            modelIdentifier: "food-model",
            modelVersion: "1",
            policyVersion: "nutrition-v1",
            sanitizedImageHashes: [hash]
        )
        let roundTrip = try JSONDecoder().decode(
            NutritionMealPhotoLineage.self,
            from: JSONEncoder().encode(lineage)
        )
        XCTAssertEqual(roundTrip, lineage)

        XCTAssertEqual(
            NutritionPhotoRetentionPolicy.storageState(totalBytes: 0),
            .normal
        )
        XCTAssertEqual(
            NutritionPhotoRetentionPolicy.storageState(totalBytes: NutritionPhotoRetentionPolicy.warningStorageBytes),
            .warning
        )
        XCTAssertEqual(
            NutritionPhotoRetentionPolicy.storageState(totalBytes: NutritionPhotoRetentionPolicy.criticalStorageBytes),
            .critical
        )
        XCTAssertEqual(
            NutritionPhotoRetentionPolicy.storageState(totalBytes: NutritionPhotoRetentionPolicy.ingestGateStorageBytes),
            .ingestBlocked
        )
        XCTAssertNoThrow(try NutritionPhotoRetentionPolicy.validateAsset(
            kind: .derivative,
            byteCount: NutritionPhotoRetentionPolicy.maximumDerivativeBytes,
            imageCount: 3
        ))
        XCTAssertThrowsError(try NutritionPhotoRetentionPolicy.validateAsset(
            kind: .derivative,
            byteCount: NutritionPhotoRetentionPolicy.maximumDerivativeBytes + 1,
            imageCount: 1
        ))
        XCTAssertThrowsError(try NutritionPhotoRetentionPolicy.validateAsset(
            kind: .original,
            byteCount: 1,
            imageCount: 1,
            totalStorageBytes: NutritionPhotoRetentionPolicy.ingestGateStorageBytes
        ))

        XCTAssertEqual(
            NutritionPhotoRetentionPolicy.decision(
                for: .original,
                capturedAt: now,
                now: now.addingTimeInterval(NutritionPhotoRetentionPolicy.originalRetention),
                byteCount: 1,
                imageCount: 1
            ),
            .eligibleForDeletion
        )
        XCTAssertEqual(
            NutritionPhotoRetentionPolicy.decision(
                for: .detail,
                capturedAt: now,
                now: now.addingTimeInterval(NutritionPhotoRetentionPolicy.detailRetention - 1),
                byteCount: 1,
                imageCount: 1
            ),
            .retain
        )
        XCTAssertEqual(
            NutritionPhotoRetentionPolicy.decision(
                for: .detail,
                capturedAt: now,
                now: now.addingTimeInterval(NutritionPhotoRetentionPolicy.detailRetention),
                byteCount: 1,
                imageCount: 1
            ),
            .eligibleForDeletion
        )
    }
}
