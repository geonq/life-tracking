import Foundation
import XCTest
@testable import LifeOS

@MainActor
final class FoodPhotoPreparationCoordinatorTests: XCTestCase {
    func testInitialAndResetStatesRevokeConsent() async throws {
        let descriptor = try descriptor(id: "first")
        let coordinator = makeCoordinator(descriptors: [descriptor])

        XCTAssertEqual(coordinator.state, .idle)
        XCTAssertFalse(coordinator.explicitConsent)
        coordinator.beginSelection()
        XCTAssertEqual(coordinator.state, .preparing)
        XCTAssertFalse(coordinator.explicitConsent)

        coordinator.prepare(inputs: [try input("first")])
        await waitUntilSettled(coordinator)
        coordinator.setExplicitConsent(true)
        XCTAssertTrue(coordinator.explicitConsent)

        coordinator.clear()
        XCTAssertEqual(coordinator.state, .idle)
        XCTAssertFalse(coordinator.explicitConsent)
        XCTAssertEqual(coordinator.sanitizedImageCount, 0)
        XCTAssertEqual(coordinator.sanitizedByteCount, 0)
    }

    func testManifestBlockedUntilReadyAndConsent() async throws {
        let descriptor = try descriptor(id: "first")
        let coordinator = makeCoordinator(descriptors: [descriptor])

        XCTAssertThrowsError(try coordinator.makeManifest()) { error in
            XCTAssertEqual(error as? FoodPhotoPreparationError, .manifestUnavailable)
        }

        coordinator.prepare(inputs: [try input("first")])
        await waitUntilSettled(coordinator)
        XCTAssertEqual(coordinator.state, .ready)
        XCTAssertThrowsError(try coordinator.makeManifest()) { error in
            XCTAssertEqual(error as? FoodPhotoPreparationError, .manifestUnavailable)
        }

        coordinator.setExplicitConsent(true)
        let manifest = try coordinator.makeManifest()
        XCTAssertTrue(manifest.inferenceConsent)
        XCTAssertEqual(manifest.images, [descriptor])
    }

    func testSuccessPublishesExactDescriptorsAndSizes() async throws {
        let first = try descriptor(id: "first", bytes: [1, 2, 3])
        let second = try descriptor(id: "second", bytes: [4, 5])
        let coordinator = makeCoordinator(descriptors: [first, second])

        coordinator.prepare(inputs: [try input("first"), try input("second")])
        await waitUntilSettled(coordinator)

        XCTAssertEqual(coordinator.state, .ready)
        XCTAssertEqual(coordinator.sanitizedImageCount, 2)
        XCTAssertEqual(coordinator.sanitizedByteCount, first.byteLength + second.byteLength)
        coordinator.setExplicitConsent(true)
        XCTAssertEqual(try coordinator.makeManifest().images, [first, second])
    }

    func testNewSelectionRevokesConsentBeforeAndAfterPreparation() async throws {
        let first = try descriptor(id: "first")
        let second = try descriptor(id: "second")
        let coordinator = makeCoordinator(descriptors: [first, second])

        coordinator.prepare(inputs: [try input("first")])
        await waitUntilSettled(coordinator)
        coordinator.setExplicitConsent(true)
        XCTAssertTrue(coordinator.explicitConsent)

        coordinator.prepare(inputs: [try input("second")])
        XCTAssertEqual(coordinator.state, .preparing)
        XCTAssertFalse(coordinator.explicitConsent)
        await waitUntilSettled(coordinator)
        XCTAssertEqual(coordinator.state, .ready)
        XCTAssertFalse(coordinator.explicitConsent)
        XCTAssertEqual(coordinator.sanitizedImageCount, 1)
    }

    func testFailureIsAtomicAndGeneric() async throws {
        let goodDescriptor = try descriptor(id: "first", bytes: [1, 2, 3])
        let coordinator = FoodPhotoPreparationCoordinator(sanitize: { _ in [goodDescriptor] })
        coordinator.prepare(inputs: [try input("first")])
        await waitUntilSettled(coordinator)
        coordinator.setExplicitConsent(true)
        XCTAssertTrue(coordinator.explicitConsent)

        let failing = FoodPhotoPreparationCoordinator(sanitize: { _ in
            throw NSError(domain: "private.imageio", code: 7, userInfo: [
                NSLocalizedDescriptionKey: "private image detail"
            ])
        })

        failing.prepare(inputs: [try input("first")])
        XCTAssertEqual(failing.selectedImageCount, 1)
        XCTAssertEqual(failing.selectedByteCount, 1)
        await waitUntilSettled(failing)

        XCTAssertEqual(failing.state, .error)
        XCTAssertFalse(failing.explicitConsent)
        XCTAssertEqual(failing.selectedImageCount, 0)
        XCTAssertEqual(failing.selectedByteCount, 0)
        XCTAssertEqual(failing.sanitizedImageCount, 0)
        XCTAssertEqual(failing.sanitizedByteCount, 0)
        XCTAssertThrowsError(try failing.makeManifest()) { error in
            XCTAssertEqual(error as? FoodPhotoPreparationError, .manifestUnavailable)
        }
    }

    func testInvalidPrepareClearsBothCountersAndConsent() async throws {
        let descriptor = try descriptor(id: "first")
        let coordinator = makeCoordinator(descriptors: [descriptor])
        coordinator.prepare(inputs: [try input("first")])
        await waitUntilSettled(coordinator)
        coordinator.setExplicitConsent(true)

        let tooMany = try ["a", "b", "c", "d"].map { try input($0) }
        coordinator.prepare(inputs: tooMany)

        XCTAssertEqual(coordinator.state, .error)
        XCTAssertFalse(coordinator.explicitConsent)
        XCTAssertEqual(coordinator.selectedImageCount, 0)
        XCTAssertEqual(coordinator.selectedByteCount, 0)
        XCTAssertEqual(coordinator.sanitizedImageCount, 0)
        XCTAssertEqual(coordinator.sanitizedByteCount, 0)
    }

    func testOutputMustMatchManifestOrderAndAggregateBound() async throws {
        let first = try descriptor(id: "first", bytes: [1, 2, 3])
        let second = try descriptor(id: "second", bytes: [4, 5])
        let coordinator = FoodPhotoPreparationCoordinator(sanitize: { _ in [second, first] })
        coordinator.prepare(inputs: [try input("first"), try input("second")])
        await waitUntilSettled(coordinator)
        XCTAssertEqual(coordinator.state, .error)
        XCTAssertEqual(coordinator.sanitizedImageCount, 0)
        XCTAssertEqual(coordinator.sanitizedByteCount, 0)

        let exact = try descriptor(id: "exact", byteCount: FoodPhotoSanitizer.maximumOutputBytes)
        let exactCoordinator = FoodPhotoPreparationCoordinator(sanitize: { _ in [exact] })
        exactCoordinator.prepare(inputs: [try input("exact")])
        await waitUntilSettled(exactCoordinator)
        XCTAssertEqual(exactCoordinator.state, .ready)
        XCTAssertEqual(exactCoordinator.sanitizedImageCount, 1)
        XCTAssertEqual(exactCoordinator.sanitizedByteCount, FoodPhotoSanitizer.maximumOutputBytes)

        let firstLarge = try descriptor(id: "large-first", byteCount: 11 * 1_024 * 1_024)
        let secondLarge = try descriptor(id: "large-second", byteCount: 10 * 1_024 * 1_024)
        let boundCoordinator = FoodPhotoPreparationCoordinator(sanitize: { _ in
            [firstLarge, secondLarge]
        })
        boundCoordinator.prepare(inputs: [try input("large-first"), try input("large-second")])
        await waitUntilSettled(boundCoordinator)
        XCTAssertEqual(boundCoordinator.state, .error)
        XCTAssertEqual(boundCoordinator.sanitizedImageCount, 0)
        XCTAssertEqual(boundCoordinator.sanitizedByteCount, 0)
    }

    func testStaleResultCannotOverwriteNewerPreparation() async throws {
        let old = try descriptor(id: "old")
        let newer = try descriptor(id: "new")
        let coordinator = FoodPhotoPreparationCoordinator(sanitize: { inputs in
            if inputs.first?.imageID == "old" {
                try await Task.sleep(nanoseconds: 120_000_000)
                return [old]
            }
            return [newer]
        })

        coordinator.prepare(inputs: [try input("old")])
        try await Task.sleep(nanoseconds: 20_000_000)
        coordinator.prepare(inputs: [try input("new")])
        await waitUntilSettled(coordinator, maxNanoseconds: 250_000_000)

        XCTAssertEqual(coordinator.state, .ready)
        XCTAssertEqual(try coordinator.makeManifestAfterConsent().images, [newer])
    }

    func testClearCancelsReadinessAndConsent() async throws {
        let descriptor = try descriptor(id: "first")
        let coordinator = makeCoordinator(descriptors: [descriptor])
        coordinator.prepare(inputs: [try input("first")])
        await waitUntilSettled(coordinator)
        coordinator.setExplicitConsent(true)

        coordinator.clear()

        XCTAssertEqual(coordinator.state, .idle)
        XCTAssertFalse(coordinator.explicitConsent)
        XCTAssertEqual(coordinator.selectedImageCount, 0)
        XCTAssertEqual(coordinator.selectedByteCount, 0)
    }

    private func makeCoordinator(
        descriptors: [FoodPhotoImageDescriptor]
    ) -> FoodPhotoPreparationCoordinator {
        FoodPhotoPreparationCoordinator(sanitize: { inputs in
            try inputs.map { input in
                guard let descriptor = descriptors.first(where: { $0.imageID == input.imageID }) else {
                    throw FoodPhotoPreparationError.preparationFailed
                }
                return descriptor
            }
        })
    }

    private func input(_ id: String) throws -> FoodPhotoSanitizerInput {
        try FoodPhotoSanitizerInput(imageID: id, data: Data([0x01]))
    }

    private func descriptor(
        id: String,
        bytes: [UInt8] = [0x01]
    ) throws -> FoodPhotoImageDescriptor {
        try FoodPhotoImageDescriptor(
            imageID: id,
            mimeType: .png,
            byteLength: bytes.count,
            width: 1,
            height: 1,
            sanitized: true,
            inlineDataBase64: Data(bytes).base64EncodedString(),
            sha256: String(repeating: "0", count: 64)
        )
    }

    private func descriptor(id: String, byteCount: Int) throws -> FoodPhotoImageDescriptor {
        try FoodPhotoImageDescriptor(
            imageID: id,
            mimeType: .png,
            byteLength: byteCount,
            width: 1,
            height: 1,
            sanitized: true,
            inlineDataBase64: Data(repeating: 0, count: byteCount).base64EncodedString(),
            sha256: String(repeating: "0", count: 64)
        )
    }

    private func waitUntilSettled(
        _ coordinator: FoodPhotoPreparationCoordinator,
        maxNanoseconds: UInt64 = 100_000_000
    ) async {
        let deadline = DispatchTime.now().uptimeNanoseconds + maxNanoseconds
        while coordinator.state == .preparing,
              DispatchTime.now().uptimeNanoseconds < deadline {
            await Task.yield()
            try? await Task.sleep(nanoseconds: 1_000_000)
        }
    }
}

private extension FoodPhotoPreparationCoordinator {
    func makeManifestAfterConsent() throws -> FoodPhotoManifest {
        setExplicitConsent(true)
        return try makeManifest(
            mealID: "meal",
            requestID: "request",
            capturedAt: ISO8601DateFormatter().string(from: Date.now.addingTimeInterval(-1)),
            clientTimeZone: "Europe/Berlin"
        )
    }

    func makeManifest() throws -> FoodPhotoManifest {
        try makeManifest(
            mealID: "meal",
            requestID: "request",
            capturedAt: ISO8601DateFormatter().string(from: Date.now.addingTimeInterval(-1)),
            clientTimeZone: "Europe/Berlin"
        )
    }
}
