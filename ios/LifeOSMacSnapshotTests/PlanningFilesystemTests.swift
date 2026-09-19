import Foundation
import XCTest
@testable import LifeOSMac

#if canImport(Darwin)
import Darwin
#endif

@available(macOS 14.0, *)
final class PlanningFilesystemTests: XCTestCase {
    private func temporaryRoot(_ label: String) throws -> URL {
        let root = FileManager.default.temporaryDirectory.resolvingSymlinksInPath()
            .appendingPathComponent("lifeos-packet-c-mac-\(UUID().uuidString)-\(label)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    private func markdown(_ text: String = "Body") -> Data {
        Data("---\ntitle: Packet C\n---\n\(text)\n".utf8)
    }

    private func testingStore(
        root: URL,
        support: URL
    ) throws -> (PlanningVaultStore, PlanningUserSelectedDirectory) {
        let store = try PlanningVaultStore.makeTesting(
            rootURL: root,
            applicationSupportDirectory: support
        )
        let selection = try PlanningUserSelectedDirectory.testFactory(url: root)
        return (store, selection)
    }

    private func filesystemDirectory(support: URL, vaultID: UUID) -> URL {
        support
            .appendingPathComponent("LifeOS", isDirectory: true)
            .appendingPathComponent("Planning", isDirectory: true)
            .appendingPathComponent(vaultID.uuidString.lowercased(), isDirectory: true)
            .appendingPathComponent("filesystem", isDirectory: true)
    }

    func testSelectionAuthorityAndBookmarks() throws {
        let root = try temporaryRoot("selection")
        defer { try? FileManager.default.removeItem(at: root) }
        let support = try temporaryRoot("support")
        defer { try? FileManager.default.removeItem(at: support) }
        let selection = try PlanningUserSelectedDirectory.testFactory(url: root)
        let access = try PlanningVaultAccess.makeTesting(
            rootURL: root,
            applicationSupportDirectory: support
        )
        let result = try access.select(selection: selection, intent: .initialize)
        XCTAssertEqual(result.state, .ready)
        XCTAssertEqual(result.capabilities.canPublish, true)
        XCTAssertTrue(result.capabilities.supportsDescriptorTraversal)
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: root.appendingPathComponent("LifeOS/.lifeos-vault.json").path
        ))
        let attached = try PlanningUserSelectedDirectory.testFactory(url: root)
        let otherAccess = try PlanningVaultAccess.makeTesting(
            rootURL: root,
            applicationSupportDirectory: temporaryRoot("other-support")
        )
        XCTAssertThrowsError(try otherAccess.select(selection: attached, intent: .attach(expectedVaultID: UUID())))
        access.revoke()
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
            atPath: lifeOS.appendingPathComponent(".lifeos-vault.json").path
        ))
    }

    func testDescriptorContainmentAndCoordination() throws {
        let root = try temporaryRoot("containment")
        defer { try? FileManager.default.removeItem(at: root) }
        let support = try temporaryRoot("support")
        defer { try? FileManager.default.removeItem(at: support) }
        let access = try PlanningVaultAccess.makeTesting(rootURL: root, applicationSupportDirectory: support)
        let selection = try PlanningUserSelectedDirectory.testFactory(url: root)
        _ = try access.select(selection: selection, intent: .initialize)
        let path = try PlanningStoredPath("Notes/Plan.md")
        try access.withLease { lease in
            let parent = try PlanningSafeFileIO.openParent(lease, path: path, createMissing: true)
            defer { parent.close() }
            _ = try PlanningSafeFileIO.createExclusive(parent, name: parent.leafName, data: markdown())
            let outside = root.appendingPathComponent("outside.md")
            try Data("outside".utf8).write(to: outside)
#if canImport(Darwin)
            let symlinkURL = root.appendingPathComponent("LifeOS/Notes/Symlink.md")
            try FileManager.default.createSymbolicLink(
                atPath: symlinkURL.path,
                withDestinationPath: outside.path
            )
            XCTAssertThrowsError(try PlanningSafeFileIO.readBounded(
                lease,
                path: try PlanningStoredPath("Notes/Symlink.md")
            ))
            let hardURL = root.appendingPathComponent("LifeOS/Notes/Hard.md")
            XCTAssertEqual(link(outside.path, hardURL.path), 0)
            XCTAssertThrowsError(try PlanningSafeFileIO.readBounded(
                lease,
                path: try PlanningStoredPath("Notes/Hard.md")
            ))
#endif
            XCTAssertThrowsError(try PlanningStoredPath("../escape.md"))
            XCTAssertThrowsError(try PlanningStoredPath("LifeOS/escape.md"))
        }
    }

    func testCancellationBeforeMissingParentCreation() throws {
        let root = try temporaryRoot("cancel-parent")
        defer { try? FileManager.default.removeItem(at: root) }
        let support = try temporaryRoot("cancel-parent-support")
        defer { try? FileManager.default.removeItem(at: support) }
        let access = try PlanningVaultAccess.makeTesting(
            rootURL: root,
            applicationSupportDirectory: support
        )
        _ = try access.select(
            selection: try PlanningUserSelectedDirectory.testFactory(url: root),
            intent: .initialize
        )
        let path = try PlanningStoredPath("Missing/Deeper/file.md")
        var checks = 0
        XCTAssertThrowsError(
            try access.withLease { lease in
                try PlanningSafeFileIO.openParent(
                    lease,
                    path: path,
                    createMissing: true,
                    checkCancellation: {
                        checks += 1
                        throw PlanningFilesystemError.cancelled
                    }
                )
            }
        ) { error in
            XCTAssertEqual(
                planningFilesystemSafeErrorCode(error),
                PlanningFilesystemError.cancelled.stableCode
            )
        }
        XCTAssertEqual(checks, 1)
        XCTAssertFalse(
            FileManager.default.fileExists(
                atPath: root.appendingPathComponent("LifeOS/Missing", isDirectory: true).path
            )
        )
    }

    func testRawVersionsBoundsAndOfflineCache() throws {
        let root = try temporaryRoot("raw")
        defer { try? FileManager.default.removeItem(at: root) }
        let support = try temporaryRoot("support")
        defer { try? FileManager.default.removeItem(at: support) }
        let access = try PlanningVaultAccess.makeTesting(rootURL: root, applicationSupportDirectory: support)
        let selection = try PlanningUserSelectedDirectory.testFactory(url: root)
        _ = try access.select(selection: selection, intent: .initialize)
        let cache = PlanningVaultCache(directory: support.appendingPathComponent("cache", isDirectory: true))
        let path = try PlanningStoredPath("Notes/raw.md")
        let bytes = markdown("one")
        let snapshot = try PlanningDocumentSnapshot(path: path, bytes: bytes)
        try cache.store(snapshot, vaultID: try XCTUnwrap(access.snapshot.vaultID), selectionGeneration: try XCTUnwrap(access.snapshot.selectionGeneration))
        let loaded = try cache.load(
            vaultID: try XCTUnwrap(access.snapshot.vaultID),
            selectionGeneration: try XCTUnwrap(access.snapshot.selectionGeneration),
            path: path,
            version: snapshot.version
        )
        XCTAssertEqual(loaded?.path, snapshot.path)
        XCTAssertEqual(loaded?.bytes, snapshot.bytes)
        XCTAssertEqual(loaded?.version, snapshot.version)
        let crlf = try PlanningDocumentSnapshot(path: path, bytes: markdown("one\r\n"))
        XCTAssertNotEqual(crlf.version, snapshot.version)
        try access.withLease { lease in
            let huge = try PlanningStoredPath("Notes/huge.md")
            let parent = try PlanningSafeFileIO.openParent(lease, path: huge, createMissing: true)
            defer { parent.close() }
            let oversized = Data(repeating: 65, count: PlanningStorageLimits.markdownBytes + 1)
            _ = try PlanningSafeFileIO.createExclusive(parent, name: parent.leafName, data: oversized)
            XCTAssertThrowsError(try PlanningSafeFileIO.readBounded(lease, path: huge))
        }
    }

    func testAtomicPublicationAndInterference() async throws {
        let root = try temporaryRoot("publication")
        defer { try? FileManager.default.removeItem(at: root) }
        let support = try temporaryRoot("support")
        defer { try? FileManager.default.removeItem(at: support) }
        let (store, selection) = try testingStore(root: root, support: support)
        let selected = try await store.select(selection: selection, intent: .initialize)
        let vaultID = try XCTUnwrap(selected.vaultID)
        let path = try PlanningStoredPath("Notes/atomic.md")
        let firstBytes = markdown("first")
        let first = try PlanningMutationRequest(
            vaultID: vaultID,
            path: path,
            operation: .create,
            expectedVersion: .absent,
            proposedBytes: firstBytes
        )
        _ = try await store.stage(first)
        let firstResult = try await store.publish(first)
        let firstErrorCode = firstResult.errorCode
        XCTAssertNil(
            firstErrorCode,
            "first publish errorCode=\(String(describing: firstErrorCode))"
        )
        let firstReceipt = try XCTUnwrap(firstResult.receipt)
        XCTAssertEqual(firstReceipt.state, .published)
        XCTAssertEqual(firstReceipt.resultVersion, PlanningContentVersion(data: firstBytes))
        XCTAssertEqual(firstResult.status, .published)
        let secondBytes = markdown("second")
        let second = try PlanningMutationRequest(
            vaultID: vaultID,
            path: path,
            operation: .replace,
            expectedVersion: PlanningContentVersion(data: firstBytes),
            proposedBytes: secondBytes
        )
        _ = try await store.stage(second)
        let secondResult = try await store.publish(second)
        XCTAssertEqual(secondResult.status, .published)
        let deletion = try PlanningMutationRequest(
            vaultID: vaultID,
            path: path,
            operation: .delete,
            expectedVersion: PlanningContentVersion(data: secondBytes),
            proposedBytes: nil
        )
        _ = try await store.stage(deletion)
        let deletionResult = try await store.publish(deletion)
        XCTAssertEqual(deletionResult.status, .published)
        let read = try await store.read(path)
        XCTAssertEqual(read.version, .absent)
    }

    func testRequestIdentityReplayCannotRetargetPendingMutation() async throws {
        let root = try temporaryRoot("request-identity")
        defer { try? FileManager.default.removeItem(at: root) }
        let support = try temporaryRoot("request-identity-support")
        defer { try? FileManager.default.removeItem(at: support) }
        let (store, selection) = try testingStore(root: root, support: support)
        let selected = try await store.select(selection: selection, intent: .initialize)
        let vaultID = try XCTUnwrap(selected.vaultID)
        let firstPath = try PlanningStoredPath("Notes/identity-first.md")
        let replayPath = try PlanningStoredPath("Notes/identity-replay.md")
        let first = try PlanningMutationRequest(
            mutationID: UUID(),
            vaultID: vaultID,
            path: firstPath,
            operation: .create,
            expectedVersion: .absent,
            proposedBytes: markdown("first")
        )
        _ = try await store.stage(first)
        let replay = try PlanningMutationRequest(
            mutationID: first.mutationID,
            vaultID: vaultID,
            path: replayPath,
            operation: .create,
            expectedVersion: .absent,
            proposedBytes: markdown("replay")
        )

        do {
            _ = try await store.publish(replay)
            XCTFail("a mutation ID replay was accepted")
        } catch let error as PlanningStorageError {
            XCTAssertEqual(error, .mutationIDReused)
        } catch {
            XCTFail("unexpected replay error: \(error)")
        }

        let firstBeforePublish = try await store.read(firstPath)
        let replayBeforePublish = try await store.read(replayPath)
        XCTAssertEqual(firstBeforePublish.version, .absent)
        XCTAssertEqual(replayBeforePublish.version, .absent)
        let pendingStatus = try await store.status()
        XCTAssertEqual(pendingStatus.pendingMutationCount, 1)
        let published = try await store.publish(first)
        XCTAssertEqual(published.status, .published)
        let firstAfterPublish = try await store.read(firstPath)
        XCTAssertEqual(firstAfterPublish.snapshot?.bytes, first.proposedBytes)
    }

    func testCrashRecoveryAndJournalCompatibility() async throws {
        let root = try temporaryRoot("recovery")
        defer { try? FileManager.default.removeItem(at: root) }
        let support = try temporaryRoot("support")
        defer { try? FileManager.default.removeItem(at: support) }
        let (store, selection) = try testingStore(root: root, support: support)
        let selected = try await store.select(selection: selection, intent: .initialize)
        let vaultID = try XCTUnwrap(selected.vaultID)
        let path = try PlanningStoredPath("Notes/recovery.md")
        let request = try PlanningMutationRequest(
            vaultID: vaultID,
            path: path,
            operation: .create,
            expectedVersion: .absent,
            proposedBytes: markdown("recover")
        )
        _ = try await store.stage(request)
        let stagedStatus = try await store.status()
        XCTAssertEqual(stagedStatus.pendingMutationCount, 1)
        let first = try await store.publishPendingPage()
        XCTAssertEqual(first.examined, 1)
        XCTAssertEqual(first.reconciled, 1)
        XCTAssertEqual(first.blocked, 0)
        XCTAssertTrue(first.errorCodes.isEmpty)
        let recovered = try await store.read(path)
        XCTAssertEqual(recovered.version, PlanningContentVersion(data: markdown("recover")))
        let reconciledStatus = try await store.status()
        XCTAssertEqual(reconciledStatus.pendingMutationCount, 0)
        let filesystemDirectory = support
            .appendingPathComponent("LifeOS", isDirectory: true)
            .appendingPathComponent("Planning", isDirectory: true)
            .appendingPathComponent(vaultID.uuidString.lowercased(), isDirectory: true)
            .appendingPathComponent("filesystem", isDirectory: true)
        let privateEntries = try FileManager.default.contentsOfDirectory(
            at: filesystemDirectory,
            includingPropertiesForKeys: nil
        )
        XCTAssertFalse(privateEntries.contains { $0.pathExtension == "json" })
        let backupEntries = try FileManager.default.contentsOfDirectory(
            at: filesystemDirectory.appendingPathComponent("backups", isDirectory: true),
            includingPropertiesForKeys: nil
        )
        XCTAssertTrue(backupEntries.isEmpty)
        let second = try await store.publishPendingPage(after: first.nextCursor)
        XCTAssertEqual(second.examined, 0)
        XCTAssertEqual(second.reconciled, 0)
        XCTAssertEqual(second.blocked, 0)
        XCTAssertTrue(second.errorCodes.isEmpty)
        XCTAssertTrue(second.endOfPass)
        let status = try await store.status()
        XCTAssertEqual(status.openConflictCount, 0)
    }

    func testParentSubstitutionPreservesOutsideSentinel() throws {
        let root = try temporaryRoot("parent-substitution")
        defer { try? FileManager.default.removeItem(at: root) }
        let support = try temporaryRoot("support")
        defer { try? FileManager.default.removeItem(at: support) }
        let access = try PlanningVaultAccess.makeTesting(
            rootURL: root,
            applicationSupportDirectory: support
        )
        let selection = try PlanningUserSelectedDirectory.testFactory(url: root)
        _ = try access.select(selection: selection, intent: .initialize)
        let outside = root.appendingPathComponent("outside", isDirectory: true)
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        let sentinel = outside.appendingPathComponent("sentinel.txt")
        let sentinelBytes = Data("sentinel".utf8)
        try sentinelBytes.write(to: sentinel, options: [.atomic])
        let path = try PlanningStoredPath("Notes/parent.md")

        try access.withLease { lease in
            let parent = try PlanningSafeFileIO.openParent(lease, path: path, createMissing: true)
            defer { parent.close() }
            let notes = root.appendingPathComponent("LifeOS/Notes", isDirectory: true)
            let moved = root.appendingPathComponent("LifeOS/Notes-moved", isDirectory: true)
            try FileManager.default.moveItem(at: notes, to: moved)
            try FileManager.default.createSymbolicLink(
                atPath: notes.path,
                withDestinationPath: outside.path
            )
            XCTAssertThrowsError(
                try PlanningSafeFileIO.verifyParentChain(
                    lease,
                    path: path,
                    expected: parent.parentChain
                )
            )
        }
        XCTAssertEqual(try Data(contentsOf: sentinel), sentinelBytes)
    }

    func testCleanupIsIdempotentAfterWitnessRemoval() async throws {
        let root = try temporaryRoot("cleanup-witness")
        defer { try? FileManager.default.removeItem(at: root) }
        let support = try temporaryRoot("cleanup-witness-support")
        defer { try? FileManager.default.removeItem(at: support) }
        let deviceID = UUID()
        let path = try PlanningStoredPath("Notes/cleanup.md")
        let firstBytes = markdown("first")
        let secondBytes = markdown("second")

        let initial = try PlanningVaultStore.makeTesting(
            rootURL: root,
            applicationSupportDirectory: support,
            deviceID: deviceID
        )
        let selection = try PlanningUserSelectedDirectory.testFactory(url: root)
        let selected = try await initial.select(selection: selection, intent: .initialize)
        let vaultID = try XCTUnwrap(selected.vaultID)
        let create = try PlanningMutationRequest(
            vaultID: vaultID,
            path: path,
            operation: .create,
            expectedVersion: .absent,
            proposedBytes: firstBytes
        )
        _ = try await initial.stage(create)
        let createResult = try await initial.publish(create)
        XCTAssertEqual(createResult.status, .published)
        await initial.close()

        let interrupted = try PlanningVaultStore.makeTesting(
            rootURL: root,
            applicationSupportDirectory: support,
            deviceID: deviceID,
            testBarrier: { point in
                if point == .cleanupAfterWitness {
                    throw PlanningFilesystemError.unavailable("test.cleanupAfterWitness")
                }
            }
        )
        _ = try await interrupted.select(
            selection: try PlanningUserSelectedDirectory.testFactory(url: root),
            intent: .attach(expectedVaultID: vaultID)
        )
        let replace = try PlanningMutationRequest(
            vaultID: vaultID,
            path: path,
            operation: .replace,
            expectedVersion: PlanningContentVersion(data: firstBytes),
            proposedBytes: secondBytes
        )
        _ = try await interrupted.stage(replace)
        let interruptedResult = try await interrupted.publish(replace)
        XCTAssertEqual(interruptedResult.status, .published)
        XCTAssertEqual(interruptedResult.errorCode, "cleanupPending")
        await interrupted.close()

        let resumed = try PlanningVaultStore.makeTesting(
            rootURL: root,
            applicationSupportDirectory: support,
            deviceID: deviceID
        )
        _ = try await resumed.select(
            selection: try PlanningUserSelectedDirectory.testFactory(url: root),
            intent: .attach(expectedVaultID: vaultID)
        )
        let report = try await resumed.publishPendingPage()
        XCTAssertEqual(report.blocked, 0, "cleanup errorCodes=\(report.errorCodes)")
        XCTAssertTrue(report.errorCodes.isEmpty)
        let read = try await resumed.read(path)
        XCTAssertEqual(read.snapshot?.bytes, secondBytes)

        let filesystem = filesystemDirectory(support: support, vaultID: vaultID)
        let filesystemEntries = try FileManager.default.contentsOfDirectory(
            at: filesystem,
            includingPropertiesForKeys: nil
        )
        XCTAssertEqual(filesystemEntries.map(\.lastPathComponent), ["backups"])
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(
            at: filesystem.appendingPathComponent("backups", isDirectory: true),
            includingPropertiesForKeys: nil
        ).isEmpty)
        let notes = root.appendingPathComponent("LifeOS/Notes", isDirectory: true)
        let witnesses = try FileManager.default.contentsOfDirectory(at: notes, includingPropertiesForKeys: nil)
            .filter { $0.lastPathComponent.hasPrefix(".lifeos-stage-") }
        XCTAssertTrue(witnesses.isEmpty)
        await resumed.close()
    }

    func testSameInodeRecoveryPreservesChangedWitness() async throws {
        let root = try temporaryRoot("same-inode")
        defer { try? FileManager.default.removeItem(at: root) }
        let support = try temporaryRoot("support")
        defer { try? FileManager.default.removeItem(at: support) }
        let deviceID = UUID()
        let sameBytes = markdown("same")
        var firstStore: PlanningVaultStore?
        firstStore = try PlanningVaultStore.makeTesting(
            rootURL: root,
            applicationSupportDirectory: support,
            deviceID: deviceID,
            testBarrier: { point in
                guard point == .p3 else { return }
                let lifeOS = root.appendingPathComponent("LifeOS/Notes", isDirectory: true)
                let staged = try FileManager.default.contentsOfDirectory(
                    at: lifeOS,
                    includingPropertiesForKeys: nil,
                    options: []
                ).first { $0.lastPathComponent.hasPrefix(".lifeos-stage-") }
                guard let staged else { throw PlanningFilesystemError.corruptEvidence }
                let handle = try FileHandle(forWritingTo: staged)
                defer { try? handle.close() }
                try handle.seek(toOffset: 0)
                try handle.write(contentsOf: Data(repeating: 0x58, count: sameBytes.count))
                try handle.synchronize()
                throw PlanningFilesystemError.unavailable("test.sameInode")
            }
        )
        let selection = try PlanningUserSelectedDirectory.testFactory(url: root)
        let selected = try await firstStore!.select(selection: selection, intent: .initialize)
        let vaultID = try XCTUnwrap(selected.vaultID)
        let path = try PlanningStoredPath("Notes/same-inode.md")
        let bytes = sameBytes
        let request = try PlanningMutationRequest(
            vaultID: vaultID,
            path: path,
            operation: .create,
            expectedVersion: .absent,
            proposedBytes: bytes
        )
        _ = try await firstStore!.stage(request)
        let firstResult = try await firstStore!.publish(request)
        XCTAssertEqual(firstResult.status, .blocked)
        await firstStore!.close()

        let restarted = try PlanningVaultStore.makeTesting(
            rootURL: root,
            applicationSupportDirectory: support,
            deviceID: deviceID
        )
        _ = try await restarted.select(
            selection: try PlanningUserSelectedDirectory.testFactory(url: root),
            intent: .attach(expectedVaultID: vaultID)
        )
        let recovery = try await restarted.publishPendingPage()
        XCTAssertEqual(recovery.examined, 1)
        XCTAssertEqual(recovery.reconciled, 0)
        XCTAssertEqual(recovery.blocked, 1)
        XCTAssertTrue(recovery.errorCodes.contains("conflict"))
        let read = try await restarted.read(path)
        XCTAssertEqual(read.version, .absent)
        let notes = root.appendingPathComponent("LifeOS/Notes", isDirectory: true)
        let witnesses = try FileManager.default.contentsOfDirectory(at: notes, includingPropertiesForKeys: nil)
            .filter { $0.lastPathComponent.hasPrefix(".lifeos-stage-") }
        XCTAssertEqual(witnesses.count, 1)
        XCTAssertEqual(try Data(contentsOf: XCTUnwrap(witnesses.first)), Data(repeating: 0x58, count: bytes.count))
    }

    func testDiskFullInjectionQueuesWithoutMutation() async throws {
        let root = try temporaryRoot("disk-full")
        defer { try? FileManager.default.removeItem(at: root) }
        let support = try temporaryRoot("support")
        defer { try? FileManager.default.removeItem(at: support) }
        let store = try PlanningVaultStore.makeTesting(
            rootURL: root,
            applicationSupportDirectory: support,
            testBarrier: { point in
                if point == .p1 { throw PlanningFilesystemError.diskFull }
            }
        )
        let selected = try await store.select(
            selection: try PlanningUserSelectedDirectory.testFactory(url: root),
            intent: .initialize
        )
        let vaultID = try XCTUnwrap(selected.vaultID)
        let path = try PlanningStoredPath("Notes/disk-full.md")
        let request = try PlanningMutationRequest(
            vaultID: vaultID,
            path: path,
            operation: .create,
            expectedVersion: .absent,
            proposedBytes: markdown("disk-full")
        )
        _ = try await store.stage(request)
        let result = try await store.publish(request)
        XCTAssertEqual(result.status, .queued)
        XCTAssertEqual(result.errorCode, PlanningFilesystemError.diskFull.stableCode)
        let read = try await store.read(path)
        XCTAssertEqual(read.version, .absent)
    }

    func testRetryableRecoveryWaitsForBackoffThenPublishes() async throws {
        let root = try temporaryRoot("retryable-recovery")
        defer { try? FileManager.default.removeItem(at: root) }
        let support = try temporaryRoot("retryable-recovery-support")
        defer { try? FileManager.default.removeItem(at: support) }
        var now = Date(timeIntervalSince1970: 10_000)
        var failNext = true
        let store = try PlanningVaultStore.makeTesting(
            rootURL: root,
            applicationSupportDirectory: support,
            testBarrier: { point in
                if point == .p1, failNext {
                    failNext = false
                    throw PlanningFilesystemError.diskFull
                }
            },
            clock: { now }
        )
        let selected = try await store.select(
            selection: try PlanningUserSelectedDirectory.testFactory(url: root),
            intent: .initialize
        )
        let vaultID = try XCTUnwrap(selected.vaultID)
        let path = try PlanningStoredPath("Notes/retryable.md")
        let bytes = markdown("retryable")
        let request = try PlanningMutationRequest(
            vaultID: vaultID,
            path: path,
            operation: .create,
            expectedVersion: .absent,
            proposedBytes: bytes
        )
        _ = try await store.stage(request)

        let first = try await store.publishPendingPage()
        XCTAssertEqual(first.examined, 1)
        XCTAssertEqual(first.reconciled, 0)
        XCTAssertEqual(first.blocked, 0)
        XCTAssertTrue(first.errorCodes.contains(PlanningFilesystemError.diskFull.stableCode))
        let firstStatus = try await store.status()
        XCTAssertEqual(firstStatus.pendingMutationCount, 1)

        let directEarly = try await store.publish(request)
        XCTAssertEqual(directEarly.status, .queued)
        XCTAssertEqual(directEarly.errorCode, PlanningFilesystemError.diskFull.stableCode)
        let directEarlyStatus = try await store.status()
        XCTAssertEqual(directEarlyStatus.pendingMutationCount, 1)

        let early = try await store.publishPendingPage()
        XCTAssertEqual(early.examined, 1)
        XCTAssertEqual(early.reconciled, 0)
        XCTAssertEqual(early.blocked, 0)
        let earlyStatus = try await store.status()
        XCTAssertEqual(earlyStatus.pendingMutationCount, 1)
        let earlyRead = try await store.read(path)
        XCTAssertEqual(earlyRead.version, .absent)

        now = now.addingTimeInterval(5)
        let recovered = try await store.publishPendingPage()
        XCTAssertEqual(recovered.examined, 1)
        XCTAssertEqual(recovered.reconciled, 1)
        XCTAssertEqual(recovered.blocked, 0)
        XCTAssertTrue(recovered.errorCodes.isEmpty)
        let recoveredStatus = try await store.status()
        XCTAssertEqual(recoveredStatus.pendingMutationCount, 0)
        let recoveredRead = try await store.read(path)
        XCTAssertEqual(recoveredRead.snapshot?.bytes, bytes)
    }

    func testDirectReplayReconcilesPublishingAttempt() async throws {
        let root = try temporaryRoot("direct-replay-recovery")
        defer { try? FileManager.default.removeItem(at: root) }
        let support = try temporaryRoot("direct-replay-recovery-support")
        defer { try? FileManager.default.removeItem(at: support) }
        let store = try PlanningVaultStore.makeTesting(
            rootURL: root,
            applicationSupportDirectory: support,
            testBarrier: { point in
                if point == .p4 {
                    throw PlanningFilesystemError.unavailable("test.directReplay")
                }
            }
        )
        let selected = try await store.select(
            selection: try PlanningUserSelectedDirectory.testFactory(url: root),
            intent: .initialize
        )
        let vaultID = try XCTUnwrap(selected.vaultID)
        let path = try PlanningStoredPath("Notes/direct-replay.md")
        let bytes = markdown("direct-replay")
        let request = try PlanningMutationRequest(
            vaultID: vaultID,
            path: path,
            operation: .create,
            expectedVersion: .absent,
            proposedBytes: bytes
        )
        _ = try await store.stage(request)
        let first = try await store.publish(request)
        XCTAssertEqual(first.status, .blocked)

        let replay = try await store.publish(request)
        XCTAssertEqual(replay.status, .reconciled)
        let read = try await store.read(path)
        XCTAssertEqual(read.snapshot?.bytes, bytes)
        let replayStatus = try await store.status()
        XCTAssertEqual(replayStatus.pendingMutationCount, 0)
    }

    func testVerifiedRecoveryPreservesLaterEdit() async throws {
        let root = try temporaryRoot("verified-recovery")
        defer { try? FileManager.default.removeItem(at: root) }
        let support = try temporaryRoot("verified-recovery-support")
        defer { try? FileManager.default.removeItem(at: support) }
        let deviceID = UUID()
        let first = try PlanningVaultStore.makeTesting(
            rootURL: root,
            applicationSupportDirectory: support,
            deviceID: deviceID,
            testBarrier: { point in
                if point == .p6 {
                    throw PlanningFilesystemError.unavailable("test.verifiedRecovery")
                }
            }
        )
        let selection = try PlanningUserSelectedDirectory.testFactory(url: root)
        let selected = try await first.select(selection: selection, intent: .initialize)
        let vaultID = try XCTUnwrap(selected.vaultID)
        let path = try PlanningStoredPath("Notes/verified-recovery.md")
        let publishedBytes = markdown("published")
        let request = try PlanningMutationRequest(
            vaultID: vaultID,
            path: path,
            operation: .create,
            expectedVersion: .absent,
            proposedBytes: publishedBytes
        )
        _ = try await first.stage(request)
        let interrupted = try await first.publish(request)
        XCTAssertEqual(interrupted.status, .blocked)
        await first.close()

        let editedBytes = markdown("later edit")
        let target = root.appendingPathComponent("LifeOS", isDirectory: true)
            .appendingPathComponent(path.value, isDirectory: false)
        try editedBytes.write(to: target, options: [.atomic])

        let recovery = try PlanningVaultStore.makeTesting(
            rootURL: root,
            applicationSupportDirectory: support,
            deviceID: deviceID
        )
        _ = try await recovery.select(
            selection: try PlanningUserSelectedDirectory.testFactory(url: root),
            intent: .attach(expectedVaultID: vaultID)
        )
        let report = try await recovery.publishPendingPage()
        XCTAssertEqual(report.reconciled, 1)
        XCTAssertEqual(report.blocked, 0)
        XCTAssertTrue(report.errorCodes.isEmpty, "unexpected recovery errors: \(report.errorCodes)")
        let read = try await recovery.read(path)
        XCTAssertEqual(read.snapshot?.bytes, editedBytes)
        let recoveryStatus = try await recovery.status()
        XCTAssertEqual(recoveryStatus.pendingMutationCount, 0)
        await recovery.close()
    }

    func testCacheReclaimsOwnedOrphansAndRejectsSymlinkBlobs() throws {
        let support = try temporaryRoot("cache-integrity")
        defer { try? FileManager.default.removeItem(at: support) }
        let cacheDirectory = support.appendingPathComponent("cache", isDirectory: true)
        let cache = PlanningVaultCache(directory: cacheDirectory)
        let path = try PlanningStoredPath("Notes/cache.md")
        let vaultID = UUID()
        let generation = UUID()
        let snapshot = try PlanningDocumentSnapshot(path: path, bytes: markdown("cache"))
        try cache.store(snapshot, vaultID: vaultID, selectionGeneration: generation)
        let updated = try PlanningDocumentSnapshot(path: path, bytes: markdown("updated"))
        try cache.store(updated, vaultID: vaultID, selectionGeneration: generation)
        XCTAssertEqual(
            try cache.loadLatest(vaultID: vaultID, selectionGeneration: generation, path: path)?.bytes,
            updated.bytes
        )
        let blobs = cacheDirectory.appendingPathComponent("blobs", isDirectory: true)
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: blobs.appendingPathComponent(snapshot.version.digest ?? "").path
        ))
        let orphanData = Data("orphan".utf8)
        let orphanName = try XCTUnwrap(PlanningContentVersion(data: orphanData).digest)
        try orphanData.write(to: blobs.appendingPathComponent(orphanName), options: [.atomic])
        try cache.evictClean()
        XCTAssertFalse(FileManager.default.fileExists(atPath: blobs.appendingPathComponent(orphanName).path))

#if canImport(Darwin)
        let outside = support.appendingPathComponent("outside.txt")
        let sentinel = Data("cache-sentinel".utf8)
        try sentinel.write(to: outside, options: [.atomic])
        let symlinkName = try XCTUnwrap(PlanningContentVersion(data: Data("symlink".utf8)).digest)
        try FileManager.default.createSymbolicLink(
            atPath: blobs.appendingPathComponent(symlinkName).path,
            withDestinationPath: outside.path
        )
        XCTAssertThrowsError(try cache.evictClean())
        XCTAssertEqual(try Data(contentsOf: outside), sentinel)
        try? FileManager.default.removeItem(at: blobs.appendingPathComponent(symlinkName))
#endif
    }

    func testCacheEvictsCleanEntriesBeforeRecordAdmission() throws {
        let support = try temporaryRoot("cache-record-cap")
        defer { try? FileManager.default.removeItem(at: support) }
        let cache = PlanningVaultCache(
            directory: support.appendingPathComponent("cache", isDirectory: true)
        )
        let vaultID = UUID()
        let generation = UUID()
        for index in 0...PlanningFilesystemLimits.maximumCacheRecords {
            let path = try PlanningStoredPath("Notes/cache-\(index).md")
            let snapshot = try PlanningDocumentSnapshot(
                path: path,
                bytes: markdown("entry-\(index)")
            )
            try cache.store(snapshot, vaultID: vaultID, selectionGeneration: generation)
        }
        let firstPath = try PlanningStoredPath("Notes/cache-0.md")
        let lastPath = try PlanningStoredPath(
            "Notes/cache-\(PlanningFilesystemLimits.maximumCacheRecords).md"
        )
        XCTAssertNil(try cache.loadLatest(
            vaultID: vaultID,
            selectionGeneration: generation,
            path: firstPath
        ))
        XCTAssertNotNil(try cache.loadLatest(
            vaultID: vaultID,
            selectionGeneration: generation,
            path: lastPath
        ))
    }

    func testCombinedPreservationBudgetRejectsBeforeWitness() async throws {
        let root = try temporaryRoot("preservation-cap")
        defer { try? FileManager.default.removeItem(at: root) }
        let support = try temporaryRoot("preservation-cap-support")
        defer { try? FileManager.default.removeItem(at: support) }
        let store = try PlanningVaultStore.makeTesting(
            rootURL: root,
            applicationSupportDirectory: support
        )
        let selected = try await store.select(
            selection: try PlanningUserSelectedDirectory.testFactory(url: root),
            intent: .initialize
        )
        let vaultID = try XCTUnwrap(selected.vaultID)
        let lifeOS = root.appendingPathComponent("LifeOS", isDirectory: true)
        for index in 0..<PlanningFilesystemLimits.maximumPreservedArtifacts {
            try Data("orphan".utf8).write(
                to: lifeOS.appendingPathComponent(".lifeos-orphan-\(index)"),
                options: [.atomic]
            )
        }
        let path = try PlanningStoredPath("Notes/cap.md")
        let request = try PlanningMutationRequest(
            vaultID: vaultID,
            path: path,
            operation: .create,
            expectedVersion: .absent,
            proposedBytes: markdown("capacity")
        )
        _ = try await store.stage(request)
        do {
            _ = try await store.publish(request)
            XCTFail("combined preservation capacity was not enforced")
        } catch {
            XCTAssertEqual(
                planningFilesystemSafeErrorCode(error),
                PlanningFilesystemError.backpressure("preservation").stableCode
            )
        }
        let names = try FileManager.default.contentsOfDirectory(
            at: lifeOS,
            includingPropertiesForKeys: nil
        ).map(\.lastPathComponent)
        XCTAssertFalse(names.contains { $0.hasPrefix(".lifeos-stage-") })
    }

    func testRecoveryPreservationBudgetRejectsBeforeDeleteWitness() async throws {
        let root = try temporaryRoot("recovery-preservation-cap")
        defer { try? FileManager.default.removeItem(at: root) }
        let support = try temporaryRoot("recovery-preservation-cap-support")
        defer { try? FileManager.default.removeItem(at: support) }
        let deviceID = UUID()
        let path = try PlanningStoredPath("Notes/recovery-cap.md")
        let originalBytes = markdown("original")
        let initial = try PlanningVaultStore.makeTesting(
            rootURL: root,
            applicationSupportDirectory: support,
            deviceID: deviceID
        )
        let selected = try await initial.select(
            selection: try PlanningUserSelectedDirectory.testFactory(url: root),
            intent: .initialize
        )
        let vaultID = try XCTUnwrap(selected.vaultID)
        let create = try PlanningMutationRequest(
            vaultID: vaultID,
            path: path,
            operation: .create,
            expectedVersion: .absent,
            proposedBytes: originalBytes
        )
        _ = try await initial.stage(create)
        let createdResult = try await initial.publish(create)
        XCTAssertEqual(createdResult.status, .published)
        await initial.close()

        let interrupted = try PlanningVaultStore.makeTesting(
            rootURL: root,
            applicationSupportDirectory: support,
            deviceID: deviceID,
            testBarrier: { point in
                if point == .p3 {
                    throw PlanningFilesystemError.unavailable("test.recoveryPreservation")
                }
            }
        )
        _ = try await interrupted.select(
            selection: try PlanningUserSelectedDirectory.testFactory(url: root),
            intent: .attach(expectedVaultID: vaultID)
        )
        let deletion = try PlanningMutationRequest(
            vaultID: vaultID,
            path: path,
            operation: .delete,
            expectedVersion: PlanningContentVersion(data: originalBytes),
            proposedBytes: nil
        )
        _ = try await interrupted.stage(deletion)
        let interruptedResult = try await interrupted.publish(deletion)
        XCTAssertEqual(interruptedResult.status, .blocked)
        await interrupted.close()

        let lifeOS = root.appendingPathComponent("LifeOS", isDirectory: true)
        for index in 0..<PlanningFilesystemLimits.maximumPreservedArtifacts {
            try Data("orphan".utf8).write(
                to: lifeOS.appendingPathComponent(".lifeos-orphan-\(index)"),
                options: [.atomic]
            )
        }

        let recovery = try PlanningVaultStore.makeTesting(
            rootURL: root,
            applicationSupportDirectory: support,
            deviceID: deviceID
        )
        _ = try await recovery.select(
            selection: try PlanningUserSelectedDirectory.testFactory(url: root),
            intent: .attach(expectedVaultID: vaultID)
        )
        let report = try await recovery.publishPendingPage()
        XCTAssertEqual(report.examined, 1)
        XCTAssertEqual(report.reconciled, 0)
        XCTAssertEqual(report.blocked, 1)
        XCTAssertTrue(report.errorCodes.contains(
            PlanningFilesystemError.backpressure("preservation").stableCode
        ))
        let recoveryRead = try await recovery.read(path)
        XCTAssertEqual(recoveryRead.snapshot?.bytes, originalBytes)
        let recoveryStatus = try await recovery.status()
        XCTAssertEqual(recoveryStatus.pendingMutationCount, 1)
        let names = try FileManager.default.contentsOfDirectory(
            at: lifeOS,
            includingPropertiesForKeys: nil
        ).map(\.lastPathComponent)
        XCTAssertFalse(names.contains { $0.hasPrefix(".lifeos-stage-") })
        await recovery.close()
    }

    func testRecoveryPassReopensAfterEndCursor() async throws {
        let root = try temporaryRoot("recovery-cursor")
        defer { try? FileManager.default.removeItem(at: root) }
        let support = try temporaryRoot("recovery-cursor-support")
        defer { try? FileManager.default.removeItem(at: support) }
        let store = try PlanningVaultStore.makeTesting(
            rootURL: root,
            applicationSupportDirectory: support
        )
        let selected = try await store.select(
            selection: try PlanningUserSelectedDirectory.testFactory(url: root),
            intent: .initialize
        )
        let vaultID = try XCTUnwrap(selected.vaultID)
        let firstPath = try PlanningStoredPath("Notes/cursor-first.md")
        let first = try PlanningMutationRequest(
            vaultID: vaultID,
            path: firstPath,
            operation: .create,
            expectedVersion: .absent,
            proposedBytes: markdown("first")
        )
        _ = try await store.stage(first)
        let firstPass = try await store.publishPendingPage()
        XCTAssertEqual(firstPass.reconciled, 1)
        XCTAssertTrue(firstPass.endOfPass)

        let secondPath = try PlanningStoredPath("Notes/cursor-second.md")
        let second = try PlanningMutationRequest(
            vaultID: vaultID,
            path: secondPath,
            operation: .create,
            expectedVersion: .absent,
            proposedBytes: markdown("second")
        )
        _ = try await store.stage(second)
        let secondPass = try await store.publishPendingPage()
        XCTAssertEqual(secondPass.examined, 1)
        XCTAssertEqual(secondPass.reconciled, 1)
        let secondRead = try await store.read(secondPath)
        XCTAssertEqual(secondRead.snapshot?.bytes, second.proposedBytes)
    }

    func testRecoveryCursorAdvancesPastSlowEntry() async throws {
        let root = try temporaryRoot("recovery-cursor-starvation")
        defer { try? FileManager.default.removeItem(at: root) }
        let support = try temporaryRoot("recovery-cursor-starvation-support")
        defer { try? FileManager.default.removeItem(at: support) }
        var sleepOnce = true
        let store = try PlanningVaultStore.makeTesting(
            rootURL: root,
            applicationSupportDirectory: support,
            testBarrier: { point in
                guard point == .p1, sleepOnce else { return }
                sleepOnce = false
                Thread.sleep(forTimeInterval: 2.1)
                throw PlanningFilesystemError.diskFull
            }
        )
        let selected = try await store.select(
            selection: try PlanningUserSelectedDirectory.testFactory(url: root),
            intent: .initialize
        )
        let vaultID = try XCTUnwrap(selected.vaultID)
        let firstPath = try PlanningStoredPath("Notes/slow-first.md")
        let secondPath = try PlanningStoredPath("Notes/slow-second.md")
        let first = try PlanningMutationRequest(
            vaultID: vaultID,
            path: firstPath,
            operation: .create,
            expectedVersion: .absent,
            proposedBytes: markdown("slow-first")
        )
        let second = try PlanningMutationRequest(
            vaultID: vaultID,
            path: secondPath,
            operation: .create,
            expectedVersion: .absent,
            proposedBytes: markdown("slow-second")
        )
        _ = try await store.stage(first)
        _ = try await store.stage(second)

        let firstPass = try await store.publishPendingPage()
        XCTAssertEqual(firstPass.examined, 1)
        XCTAssertEqual(firstPass.reconciled, 0)
        XCTAssertEqual(firstPass.blocked, 0)
        XCTAssertFalse(firstPass.endOfPass)
        XCTAssertGreaterThan(firstPass.nextCursor?.lastExaminedSequence ?? 0, 0)
        let secondBeforePublish = try await store.read(secondPath)
        XCTAssertEqual(secondBeforePublish.version, .absent)

        let secondPass = try await store.publishPendingPage()
        XCTAssertEqual(secondPass.examined, 1)
        XCTAssertEqual(secondPass.reconciled, 1)
        XCTAssertEqual(secondPass.blocked, 0)
        XCTAssertTrue(secondPass.endOfPass)
        let secondAfterPublish = try await store.read(secondPath)
        XCTAssertEqual(secondAfterPublish.snapshot?.bytes, second.proposedBytes)
        let cursorStatus = try await store.status()
        XCTAssertEqual(cursorStatus.pendingMutationCount, 1)
    }

    func testPrivateStoreCreatesAbsentDirectoryAndAppliesBudget() async throws {
        let root = try temporaryRoot("private-store")
        defer { try? FileManager.default.removeItem(at: root) }
        let support = try temporaryRoot("private-store-support")
        defer { try? FileManager.default.removeItem(at: support) }
        let (store, selection) = try testingStore(root: root, support: support)
        let selected = try await store.select(selection: selection, intent: .initialize)
        let vaultID = try XCTUnwrap(selected.vaultID)
        let privateDirectory = filesystemDirectory(support: support, vaultID: vaultID)
        XCTAssertFalse(FileManager.default.fileExists(atPath: privateDirectory.path))

        let firstPath = try PlanningStoredPath("Notes/private-first.md")
        let first = try PlanningMutationRequest(
            vaultID: vaultID,
            path: firstPath,
            operation: .create,
            expectedVersion: .absent,
            proposedBytes: markdown("first")
        )
        _ = try await store.stage(first)
        let firstResult = try await store.publish(first)
        XCTAssertEqual(firstResult.status, .published)
        XCTAssertTrue(FileManager.default.fileExists(atPath: privateDirectory.path))

        let oversizedTemporary = privateDirectory.appendingPathComponent(
            ".lifeos-private-tmp-budget",
            isDirectory: false
        )
        try Data(repeating: 0x41, count: PlanningFilesystemLimits.maximumManifestBytes + 1)
            .write(to: oversizedTemporary, options: [.atomic])
        let secondPath = try PlanningStoredPath("Notes/private-second.md")
        let second = try PlanningMutationRequest(
            vaultID: vaultID,
            path: secondPath,
            operation: .create,
            expectedVersion: .absent,
            proposedBytes: markdown("second")
        )
        _ = try await store.stage(second)
        do {
            _ = try await store.publish(second)
            XCTFail("oversized private temporary was accepted")
        } catch {
            XCTAssertEqual(
                planningFilesystemSafeErrorCode(error),
                PlanningFilesystemError.backpressure("privateFile").stableCode
            )
        }
    }

    func testReplaceAndDeleteRecoveryAfterNamespaceBarrier() async throws {
        let root = try temporaryRoot("replace-delete-recovery")
        defer { try? FileManager.default.removeItem(at: root) }
        let support = try temporaryRoot("replace-delete-support")
        defer { try? FileManager.default.removeItem(at: support) }
        let deviceID = UUID(uuidString: "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE")!
        let path = try PlanningStoredPath("Notes/recover.md")
        let firstBytes = markdown("first")
        let secondBytes = markdown("second")
        let initial = try PlanningVaultStore.makeTesting(
            rootURL: root,
            applicationSupportDirectory: support,
            deviceID: deviceID
        )
        let selection = try PlanningUserSelectedDirectory.testFactory(url: root)
        let selected = try await initial.select(selection: selection, intent: .initialize)
        let vaultID = try XCTUnwrap(selected.vaultID)
        let first = try PlanningMutationRequest(
            vaultID: vaultID,
            path: path,
            operation: .create,
            expectedVersion: .absent,
            proposedBytes: firstBytes
        )
        _ = try await initial.stage(first)
        let firstResult = try await initial.publish(first)
        XCTAssertEqual(firstResult.status, .published)
        await initial.close()

        let replaceStore = try PlanningVaultStore.makeTesting(
            rootURL: root,
            applicationSupportDirectory: support,
            deviceID: deviceID,
            testBarrier: { point in
                if point == .p4 { throw PlanningFilesystemError.unavailable("test.replace") }
            }
        )
        _ = try await replaceStore.select(
            selection: try PlanningUserSelectedDirectory.testFactory(url: root),
            intent: .attach(expectedVaultID: vaultID)
        )
        let replace = try PlanningMutationRequest(
            vaultID: vaultID,
            path: path,
            operation: .replace,
            expectedVersion: PlanningContentVersion(data: firstBytes),
            proposedBytes: secondBytes
        )
        _ = try await replaceStore.stage(replace)
        let replaceResult = try await replaceStore.publish(replace)
        XCTAssertEqual(replaceResult.status, .blocked)
        await replaceStore.close()

        let replaceRecovery = try PlanningVaultStore.makeTesting(
            rootURL: root,
            applicationSupportDirectory: support,
            deviceID: deviceID
        )
        _ = try await replaceRecovery.select(
            selection: try PlanningUserSelectedDirectory.testFactory(url: root),
            intent: .attach(expectedVaultID: vaultID)
        )
        let replaceReport = try await replaceRecovery.publishPendingPage()
        XCTAssertEqual(
            replaceReport.reconciled,
            1,
            "replace recovery reconciled=\(replaceReport.reconciled) blocked=\(replaceReport.blocked) errors=\(replaceReport.errorCodes)"
        )
        let replaced = try await replaceRecovery.read(path)
        XCTAssertEqual(replaced.snapshot?.bytes, secondBytes)
        await replaceRecovery.close()

        let deleteStore = try PlanningVaultStore.makeTesting(
            rootURL: root,
            applicationSupportDirectory: support,
            deviceID: deviceID,
            testBarrier: { point in
                if point == .p4 { throw PlanningFilesystemError.unavailable("test.delete") }
            }
        )
        _ = try await deleteStore.select(
            selection: try PlanningUserSelectedDirectory.testFactory(url: root),
            intent: .attach(expectedVaultID: vaultID)
        )
        let deletion = try PlanningMutationRequest(
            vaultID: vaultID,
            path: path,
            operation: .delete,
            expectedVersion: PlanningContentVersion(data: secondBytes),
            proposedBytes: nil
        )
        do {
            _ = try await deleteStore.stage(deletion)
        } catch {
            XCTFail("delete stage failed: \(planningFilesystemSafeErrorCode(error))")
            return
        }
        let deleteResult = try await deleteStore.publish(deletion)
        XCTAssertEqual(deleteResult.status, .blocked)
        await deleteStore.close()

        let deleteRecovery = try PlanningVaultStore.makeTesting(
            rootURL: root,
            applicationSupportDirectory: support,
            deviceID: deviceID
        )
        _ = try await deleteRecovery.select(
            selection: try PlanningUserSelectedDirectory.testFactory(url: root),
            intent: .attach(expectedVaultID: vaultID)
        )
        let deleteReport = try await deleteRecovery.publishPendingPage()
        XCTAssertEqual(deleteReport.reconciled, 1)
        let deleted = try await deleteRecovery.read(path)
        XCTAssertEqual(deleted.version, .absent)
        await deleteRecovery.close()
    }

    func testCancellationAtP3PreventsNamespaceMutation() async throws {
        let root = try temporaryRoot("cancel-p3")
        defer { try? FileManager.default.removeItem(at: root) }
        let support = try temporaryRoot("cancel-p3-support")
        defer { try? FileManager.default.removeItem(at: support) }
        let deviceID = UUID()
        let coordination = PlanningCoordinatedAccess()
        let store = try PlanningVaultStore.makeTesting(
            rootURL: root,
            applicationSupportDirectory: support,
            deviceID: deviceID,
            coordination: coordination,
            testBarrier: { point in
                if point == .p3 {
                    coordination.cancel()
                }
            }
        )
        let selected = try await store.select(
            selection: try PlanningUserSelectedDirectory.testFactory(url: root),
            intent: .initialize
        )
        let vaultID = try XCTUnwrap(selected.vaultID)
        let path = try PlanningStoredPath("Notes/cancelled.md")
        let request = try PlanningMutationRequest(
            vaultID: vaultID,
            path: path,
            operation: .create,
            expectedVersion: .absent,
            proposedBytes: markdown("cancelled")
        )
        _ = try await store.stage(request)

        do {
            _ = try await store.publish(request)
            XCTFail("publication should stop when coordination is cancelled at p3")
        } catch {
            XCTAssertEqual(
                planningFilesystemSafeErrorCode(error),
                PlanningFilesystemError.cancelled.stableCode
            )
        }

        let target = root.appendingPathComponent("LifeOS/Notes/cancelled.md")
        XCTAssertFalse(FileManager.default.fileExists(atPath: target.path))
        let read = try await store.read(path)
        XCTAssertEqual(read.version, .absent)
        await store.close()

        let vault = try PlanningVaultIdentity(vaultID: vaultID)
        let journal = PlanningMutationJournal(
            applicationSupportDirectory: support,
            vault: vault,
            deviceID: deviceID
        )
        try journal.openValidated()
        defer { journal.close() }
        let receipt = try XCTUnwrap(try journal.receipt(for: request.mutationID))
        XCTAssertNotEqual(receipt.state, .published)
    }

    func testPublicationCancellationDuringParentCreationRecoversPreparedAttempt() async throws {
        let root = try temporaryRoot("cancel-parent-publication")
        defer { try? FileManager.default.removeItem(at: root) }
        let support = try temporaryRoot("cancel-parent-publication-support")
        defer { try? FileManager.default.removeItem(at: support) }
        let deviceID = UUID()
        let coordination = PlanningCoordinatedAccess()
        let first = try PlanningVaultStore.makeTesting(
            rootURL: root,
            applicationSupportDirectory: support,
            deviceID: deviceID,
            coordination: coordination,
            testBarrier: { point in
                if point == .beforeParentCreation {
                    coordination.cancel()
                }
            }
        )
        let selected = try await first.select(
            selection: try PlanningUserSelectedDirectory.testFactory(url: root),
            intent: .initialize
        )
        let vaultID = try XCTUnwrap(selected.vaultID)
        let path = try PlanningStoredPath("Missing/Deeper/recovered.md")
        let bytes = markdown("recovered")
        let request = try PlanningMutationRequest(
            vaultID: vaultID,
            path: path,
            operation: .create,
            expectedVersion: .absent,
            proposedBytes: bytes
        )
        _ = try await first.stage(request)

        do {
            _ = try await first.publish(request)
            XCTFail("publication should stop during missing-parent creation")
        } catch {
            XCTAssertEqual(
                planningFilesystemSafeErrorCode(error),
                PlanningFilesystemError.cancelled.stableCode
            )
        }
        XCTAssertFalse(
            FileManager.default.fileExists(
                atPath: root.appendingPathComponent("LifeOS/Missing", isDirectory: true).path
            )
        )
        await first.close()

        let reopened = try PlanningVaultStore.makeTesting(
            rootURL: root,
            applicationSupportDirectory: support,
            deviceID: deviceID
        )
        _ = try await reopened.select(
            selection: try PlanningUserSelectedDirectory.testFactory(url: root),
            intent: .attach(expectedVaultID: vaultID)
        )
        let report = try await reopened.publishPendingPage()
        XCTAssertEqual(report.reconciled, 1, "recovery errors=\(report.errorCodes)")
        XCTAssertEqual(report.blocked, 0, "recovery errors=\(report.errorCodes)")
        XCTAssertTrue(report.errorCodes.isEmpty)
        let read = try await reopened.read(path)
        XCTAssertEqual(read.snapshot?.bytes, bytes)
        await reopened.close()
    }

    func testCancellationBetweenBackupAndManifestCleanupPreservesRecovery() async throws {
        let root = try temporaryRoot("cancel-cleanup")
        defer { try? FileManager.default.removeItem(at: root) }
        let support = try temporaryRoot("cancel-cleanup-support")
        defer { try? FileManager.default.removeItem(at: support) }
        let deviceID = UUID()
        let path = try PlanningStoredPath("Notes/cleanup-cancel.md")
        let firstBytes = markdown("first")
        let secondBytes = markdown("second")

        let initial = try PlanningVaultStore.makeTesting(
            rootURL: root,
            applicationSupportDirectory: support,
            deviceID: deviceID
        )
        let selected = try await initial.select(
            selection: try PlanningUserSelectedDirectory.testFactory(url: root),
            intent: .initialize
        )
        let vaultID = try XCTUnwrap(selected.vaultID)
        let create = try PlanningMutationRequest(
            vaultID: vaultID,
            path: path,
            operation: .create,
            expectedVersion: .absent,
            proposedBytes: firstBytes
        )
        _ = try await initial.stage(create)
        let createResult = try await initial.publish(create)
        XCTAssertEqual(createResult.status, .published)
        await initial.close()

        let coordination = PlanningCoordinatedAccess()
        let interrupted = try PlanningVaultStore.makeTesting(
            rootURL: root,
            applicationSupportDirectory: support,
            deviceID: deviceID,
            coordination: coordination,
            testBarrier: { point in
                if point == .cleanupAfterBackup {
                    coordination.cancel()
                }
            }
        )
        _ = try await interrupted.select(
            selection: try PlanningUserSelectedDirectory.testFactory(url: root),
            intent: .attach(expectedVaultID: vaultID)
        )
        let replace = try PlanningMutationRequest(
            vaultID: vaultID,
            path: path,
            operation: .replace,
            expectedVersion: PlanningContentVersion(data: firstBytes),
            proposedBytes: secondBytes
        )
        _ = try await interrupted.stage(replace)
        let interruptedResult = try await interrupted.publish(replace)
        XCTAssertEqual(interruptedResult.status, .published)
        XCTAssertEqual(interruptedResult.errorCode, "cleanupPending")
        await interrupted.close()

        let resumed = try PlanningVaultStore.makeTesting(
            rootURL: root,
            applicationSupportDirectory: support,
            deviceID: deviceID
        )
        _ = try await resumed.select(
            selection: try PlanningUserSelectedDirectory.testFactory(url: root),
            intent: .attach(expectedVaultID: vaultID)
        )
        let report = try await resumed.publishPendingPage()
        XCTAssertEqual(report.blocked, 0, "cleanup errorCodes=\(report.errorCodes)")
        XCTAssertTrue(report.errorCodes.isEmpty)
        let read = try await resumed.read(path)
        XCTAssertEqual(read.snapshot?.bytes, secondBytes)
        await resumed.close()
    }

    func testCoordinationRejectsSubstitutionAndCancellation() throws {
        let root = try temporaryRoot("coordination")
        defer { try? FileManager.default.removeItem(at: root) }
        let target = root.appendingPathComponent("target", isDirectory: false)
        let other = root.deletingLastPathComponent().appendingPathComponent("other", isDirectory: false)
        let coordination = PlanningCoordinatedAccess()
        XCTAssertThrowsError(
            try coordination.write(parentURL: root, targetURL: other) { _, _ in true }
        ) { error in
            XCTAssertEqual(planningFilesystemSafeErrorCode(error), "invalid.coordination.target")
        }
        let token = PlanningCoordinationToken()
        token.cancel()
        XCTAssertThrowsError(
            try coordination.read(targetURL: target, token: token) { _ in true }
        ) { error in
            XCTAssertEqual(planningFilesystemSafeErrorCode(error), PlanningFilesystemError.cancelled.stableCode)
        }
    }
}
