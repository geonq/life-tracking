import Foundation
import XCTest
@testable import LifeOS

final class PlanningFilesystemTests: XCTestCase {
    private func temporaryRoot(_ label: String) throws -> URL {
        let root = FileManager.default.temporaryDirectory.resolvingSymlinksInPath()
            .appendingPathComponent("lifeos-packet-c-ios-\(UUID().uuidString)-\(label)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    private func markdown(_ text: String = "Body") -> Data {
        Data("---\ntitle: Packet C\n---\n\(text)\n".utf8)
    }

    func testSelectionAuthorityAndBookmarks() throws {
        let root = try temporaryRoot("selection")
        defer { try? FileManager.default.removeItem(at: root) }
        let support = try temporaryRoot("support")
        defer { try? FileManager.default.removeItem(at: support) }

        try FileManager.default.createDirectory(
            at: root.appendingPathComponent("Uni", isDirectory: true),
            withIntermediateDirectories: true
        )
        XCTAssertThrowsError(try PlanningUserSelectedDirectory.testFactory(
            url: root.appendingPathComponent("Uni", isDirectory: true)
        ))

        let selection = try PlanningUserSelectedDirectory.testFactory(url: root)
        let access = try PlanningVaultAccess.makeTesting(
            rootURL: root,
            applicationSupportDirectory: support
        )
        let initialized = try access.select(selection: selection, intent: .initialize)
        XCTAssertEqual(initialized.state, .ready)
        XCTAssertEqual(initialized.capabilities.canPublish, true)
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: root.appendingPathComponent("LifeOS/.lifeos-vault.json").path
        ))
        access.revoke()
        XCTAssertEqual(access.snapshot.state, .unselected)
    }

    func testForeignNonEmptyInitializationFailsClosed() throws {
        let root = try temporaryRoot("foreign")
        defer { try? FileManager.default.removeItem(at: root) }
        let support = try temporaryRoot("support")
        defer { try? FileManager.default.removeItem(at: support) }
        let lifeOS = root.appendingPathComponent("LifeOS", isDirectory: true)
        try FileManager.default.createDirectory(at: lifeOS, withIntermediateDirectories: true)
        try Data("foreign".utf8).write(
            to: lifeOS.appendingPathComponent("foreign.txt"),
            options: [.atomic]
        )
        let access = try PlanningVaultAccess.makeTesting(
            rootURL: root,
            applicationSupportDirectory: support
        )
        let selection = try PlanningUserSelectedDirectory.testFactory(url: root)
        XCTAssertThrowsError(try access.select(selection: selection, intent: .initialize))
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: root.appendingPathComponent("LifeOS/.lifeos-vault.json").path
        ))
    }

    func testDescriptorContainmentAndCoordination() throws {
        let path = try PlanningStoredPath("Notes/Plan.md")
        XCTAssertThrowsError(try PlanningStoredPath("../Plan.md"))
        XCTAssertThrowsError(try PlanningStoredPath("LifeOS/Plan.md"))
        XCTAssertEqual(path.collisionKey, try PlanningStoredPath("Notes/plan.md").collisionKey)
        XCTAssertEqual(
            try PlanningStoredPath("Notes/café.md").collisionKey,
            try PlanningStoredPath("Notes/café.md").collisionKey
        )
        XCTAssertEqual(
            planningFilesystemCollisionKey("café.md"),
            planningFilesystemCollisionKey("café.md")
        )
        let token = PlanningCoordinationToken()
        token.cancel()
        XCTAssertTrue(token.isCancelled)
        let capabilities = PlanningFilesystemCapabilities.unavailableSignedApp
        XCTAssertFalse(capabilities.canPublish)
        XCTAssertFalse(capabilities.signedAppAccessAvailable)
    }

    func testRawVersionsBoundsAndOfflineCache() throws {
        let support = try temporaryRoot("cache")
        defer { try? FileManager.default.removeItem(at: support) }
        let cache = PlanningVaultCache(directory: support.appendingPathComponent("cache", isDirectory: true))
        let path = try PlanningStoredPath("Notes/cache.md")
        let snapshot = try PlanningDocumentSnapshot(path: path, bytes: markdown())
        let vaultID = UUID()
        let generation = UUID()
        try cache.store(snapshot, vaultID: vaultID, selectionGeneration: generation)
        let loaded = try cache.load(
            vaultID: vaultID,
            selectionGeneration: generation,
            path: path,
            version: snapshot.version
        )
        XCTAssertEqual(loaded?.path, snapshot.path)
        XCTAssertEqual(loaded?.bytes, snapshot.bytes)
        XCTAssertEqual(loaded?.version, snapshot.version)
        XCTAssertNotEqual(
            PlanningContentVersion(data: Data("---\ntitle: Packet C\n---\nBody\r\n".utf8)),
            snapshot.version
        )
        try cache.evictClean()
    }

    func testAtomicPublicationAndInterference() async throws {
        let root = try temporaryRoot("publish")
        defer { try? FileManager.default.removeItem(at: root) }
        let support = try temporaryRoot("publish-support")
        defer { try? FileManager.default.removeItem(at: support) }
        let store = try PlanningVaultStore.makeTesting(
            rootURL: root,
            applicationSupportDirectory: support
        )
        let selection = try PlanningUserSelectedDirectory.testFactory(url: root)
        let selected = try await store.select(selection: selection, intent: .initialize)
        let vaultID = try XCTUnwrap(selected.vaultID)
        let path = try PlanningStoredPath("Notes/today.md")
        let bytes = markdown()
        let request = try PlanningMutationRequest(
            vaultID: vaultID,
            path: path,
            operation: .create,
            expectedVersion: .absent,
            proposedBytes: bytes
        )
        _ = try await store.stage(request)
        let published = try await store.publish(request)
        XCTAssertEqual(published.status, .published)
        let read = try await store.read(path)
        XCTAssertEqual(read.snapshot?.bytes, bytes)
    }

    func testCrashRecoveryAndJournalCompatibility() async throws {
        let root = try temporaryRoot("recovery")
        defer { try? FileManager.default.removeItem(at: root) }
        let support = try temporaryRoot("recovery-support")
        defer { try? FileManager.default.removeItem(at: support) }
        let first = try PlanningVaultStore.makeTesting(rootURL: root, applicationSupportDirectory: support)
        let selection = try PlanningUserSelectedDirectory.testFactory(url: root)
        let selected = try await first.select(selection: selection, intent: .initialize)
        let vaultID = try XCTUnwrap(selected.vaultID)
        let path = try PlanningStoredPath("Notes/restart.md")
        let request = try PlanningMutationRequest(
            vaultID: vaultID,
            path: path,
            operation: .create,
            expectedVersion: .absent,
            proposedBytes: markdown("restart")
        )
        _ = try await first.stage(request)
        let report = try await first.publishPendingPage()
        XCTAssertEqual(report.examined, 1)
        XCTAssertEqual(report.blocked, 0)
        await first.close()
        XCTAssertEqual(try? FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil).count, 1)
    }
}
