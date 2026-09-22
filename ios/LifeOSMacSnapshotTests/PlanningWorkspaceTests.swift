import Foundation
import XCTest
@testable import LifeOSMac

private actor PlanningWorkspaceTestGate {
    private var entered = false
    private var released = false
    private var entryWaiters: [CheckedContinuation<Void, Never>] = []
    private var releaseWaiters: [CheckedContinuation<Void, Never>] = []

    var hasEntered: Bool { entered }

    func waitForEntry() async {
        if entered { return }
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            if entered {
                continuation.resume()
            } else {
                entryWaiters.append(continuation)
            }
        }
    }

    func wait() async {
        entered = true
        let pendingEntryWaiters = entryWaiters
        entryWaiters.removeAll()
        pendingEntryWaiters.forEach { $0.resume() }
        if released { return }
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            if released {
                continuation.resume()
            } else {
                releaseWaiters.append(continuation)
            }
        }
    }

    func release() {
        released = true
        let pendingReleaseWaiters = releaseWaiters
        releaseWaiters.removeAll()
        pendingReleaseWaiters.forEach { $0.resume() }
    }
}

private final class PlanningWorkspaceScopeCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var starts = 0
    private var stops = 0
    private var active = 0
    private var maximumActive = 0

    func start() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        starts += 1
        active += 1
        maximumActive = max(maximumActive, active)
        return true
    }

    func stop() {
        lock.lock()
        defer { lock.unlock() }
        stops += 1
        active -= 1
    }

    var counts: (starts: Int, stops: Int, active: Int, maximumActive: Int) {
        lock.lock()
        defer { lock.unlock() }
        return (starts, stops, active, maximumActive)
    }
}

private final class PlanningWorkspaceRemovalBarrierFault: @unchecked Sendable {
    private let lock = NSLock()
    private var prefix: String?
    private var count = 0

    func arm(prefix: String) {
        lock.lock()
        defer { lock.unlock() }
        self.prefix = prefix
        count = 0
    }

    func disarm() {
        lock.lock()
        defer { lock.unlock() }
        prefix = nil
    }

    var hits: Int {
        lock.lock()
        defer { lock.unlock() }
        return count
    }

    func check(_ name: String) throws {
        lock.lock()
        defer { lock.unlock() }
        guard let prefix, name.hasPrefix(prefix) else { return }
        count += 1
        throw PlanningFilesystemError.diskFull
    }
}

private final class PlanningWorkspaceSelectionCommitFailure: @unchecked Sendable {
    private let lock = NSLock()
    private var shouldFailBeforeReplacement = false
    private var shouldFailAfterReplacement = false

    func failNextCommit() {
        lock.lock()
        shouldFailBeforeReplacement = true
        lock.unlock()
    }

    func beforeReplacement() throws {
        lock.lock()
        let shouldFail = shouldFailBeforeReplacement
        shouldFailBeforeReplacement = false
        lock.unlock()
        if shouldFail {
            throw PlanningFilesystemError.diskFull
        }
    }

    func failNextAfterReplacement() {
        lock.lock()
        shouldFailAfterReplacement = true
        lock.unlock()
    }

    func afterReplacement() throws {
        lock.lock()
        let shouldFail = shouldFailAfterReplacement
        shouldFailAfterReplacement = false
        lock.unlock()
        if shouldFail {
            throw PlanningFilesystemError.diskFull
        }
    }
}

@MainActor
final class PlanningWorkspaceTests: XCTestCase {
    private struct Fixture {
        let root: URL
        let support: URL
        let selection: PlanningUserSelectedDirectory
        let store: PlanningVaultStore
        let ownerID: UUID
    }

    private func fixture(withCanvas: Bool = true) throws -> Fixture {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("lifeos-p06b-vault-\(UUID().uuidString)", isDirectory: true)
        let support = FileManager.default.temporaryDirectory
            .appendingPathComponent("lifeos-p06b-support-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: support, withIntermediateDirectories: true)

        let vaultID = UUID()
        _ = try PlanningSafeFileIO.initializeLifeOS(at: root, vaultID: vaultID)
        try FileManager.default.createDirectory(
            at: root.appendingPathComponent("LifeOS/Projects", isDirectory: true),
            withIntermediateDirectories: true
        )
        if withCanvas {
            let canvas = #"{"nodes":[{"id":"root","type":"text","x":0,"y":0,"width":200,"height":100,"text":"Plan"}],"edges":[],"custom":"keep"}"#
            try Data(canvas.utf8).write(
                to: root.appendingPathComponent("LifeOS/Projects/Personal.canvas"),
                options: .atomic
            )
        }

        let store = try PlanningVaultStore.makeTesting(
            rootURL: root,
            applicationSupportDirectory: support,
            deviceID: vaultID
        )
        let selection = try PlanningUserSelectedDirectory.testFactory(url: root)
        return Fixture(root: root, support: support, selection: selection, store: store, ownerID: vaultID)
    }

    private func registerTeardown(for fixture: Fixture) {
        addTeardownBlock {
            await fixture.store.close()
            try? FileManager.default.removeItem(at: fixture.root)
            try? FileManager.default.removeItem(at: fixture.support)
        }
    }

    func testAtomicSelectionCommitFailureRestoresPreviousSelectionAfterReopen() async throws {
        let fixture = try fixture()
        registerTeardown(for: fixture)

        let candidateRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("lifeos-p06b-selection-candidate-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: candidateRoot, withIntermediateDirectories: true)
        addTeardownBlock {
            try? FileManager.default.removeItem(at: candidateRoot)
        }
        let candidateID = UUID()
        _ = try PlanningSafeFileIO.initializeLifeOS(at: candidateRoot, vaultID: candidateID)
        let candidateSelection = try PlanningUserSelectedDirectory.testFactory(url: candidateRoot)

        let commitFailure = PlanningWorkspaceSelectionCommitFailure()
        let access = try PlanningVaultAccess.makeTesting(
            rootURL: fixture.root,
            applicationSupportDirectory: fixture.support,
            deviceID: fixture.ownerID,
            selectionCommitHook: { try commitFailure.beforeReplacement() }
        )
        let store = PlanningVaultStore(
            access: access,
            applicationSupportDirectory: fixture.support,
            deviceID: fixture.ownerID
        )
        addTeardownBlock { await store.close() }

        let original = try await store.select(
            selection: fixture.selection,
            intent: .initialize
        )
        commitFailure.failNextCommit()
        do {
            _ = try await store.select(
                selection: candidateSelection,
                intent: .attach(expectedVaultID: candidateID)
            )
            XCTFail("The injected composite commit failure must reject the candidate.")
        } catch let error as PlanningFilesystemError {
            XCTAssertEqual(error, .diskFull)
        }

        XCTAssertEqual(access.snapshot, original)
        await store.close()

        let reopenedAccess = try PlanningVaultAccess.makeTesting(
            rootURL: fixture.root,
            applicationSupportDirectory: fixture.support,
            deviceID: fixture.ownerID
        )
        let reopenedStore = PlanningVaultStore(
            access: reopenedAccess,
            applicationSupportDirectory: fixture.support,
            deviceID: fixture.ownerID
        )
        addTeardownBlock { await reopenedStore.close() }

        let restored = try await reopenedStore.restore()
        XCTAssertEqual(restored.vaultID, original.vaultID)
        XCTAssertEqual(restored.selectionGeneration, original.selectionGeneration)
        XCTAssertEqual(restored.state, .ready)
        let document = try await reopenedStore.read(
            try PlanningStoredPath("Projects/Personal.canvas")
        )
        XCTAssertEqual(
            document.snapshot?.bytes,
            Data(#"{"nodes":[{"id":"root","type":"text","x":0,"y":0,"width":200,"height":100,"text":"Plan"}],"edges":[],"custom":"keep"}"#.utf8)
        )
    }

    func testAfterReplacementSelectionFailureRestoresPreviousSelectionAfterReopen() async throws {
        let fixture = try fixture()
        registerTeardown(for: fixture)

        let candidateRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("lifeos-p06b-selection-after-replacement-candidate-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: candidateRoot, withIntermediateDirectories: true)
        addTeardownBlock {
            try? FileManager.default.removeItem(at: candidateRoot)
        }
        let candidateID = UUID()
        _ = try PlanningSafeFileIO.initializeLifeOS(at: candidateRoot, vaultID: candidateID)
        let candidateSelection = try PlanningUserSelectedDirectory.testFactory(url: candidateRoot)

        let commitFailure = PlanningWorkspaceSelectionCommitFailure()
        let access = try PlanningVaultAccess.makeTesting(
            rootURL: fixture.root,
            applicationSupportDirectory: fixture.support,
            deviceID: fixture.ownerID,
            selectionAfterReplacementHook: { try commitFailure.afterReplacement() }
        )
        let store = PlanningVaultStore(
            access: access,
            applicationSupportDirectory: fixture.support,
            deviceID: fixture.ownerID
        )
        addTeardownBlock { await store.close() }

        let original = try await store.select(
            selection: fixture.selection,
            intent: .initialize
        )
        commitFailure.failNextAfterReplacement()
        do {
            _ = try await store.select(
                selection: candidateSelection,
                intent: .attach(expectedVaultID: candidateID)
            )
            XCTFail("The injected after-replacement failure must reject the candidate.")
        } catch let error as PlanningFilesystemError {
            XCTAssertEqual(error, .diskFull)
        }

        XCTAssertEqual(access.snapshot, original)
        let pendingSelectionURL = fixture.support
            .appendingPathComponent(
                "LifeOS/Planning/vault-selection-pending-\(fixture.ownerID.uuidString.lowercased()).json"
            )
        XCTAssertTrue(FileManager.default.fileExists(atPath: pendingSelectionURL.path))
        await store.close()

        let reopenedAccess = try PlanningVaultAccess.makeTesting(
            rootURL: fixture.root,
            applicationSupportDirectory: fixture.support,
            deviceID: fixture.ownerID
        )
        let reopenedStore = PlanningVaultStore(
            access: reopenedAccess,
            applicationSupportDirectory: fixture.support,
            deviceID: fixture.ownerID
        )
        addTeardownBlock { await reopenedStore.close() }

        let restored = try await reopenedStore.restore()
        XCTAssertEqual(restored.vaultID, original.vaultID)
        XCTAssertEqual(restored.selectionGeneration, original.selectionGeneration)
        XCTAssertNotEqual(restored.vaultID, candidateID)
        XCTAssertEqual(restored.state, .ready)
        XCTAssertFalse(FileManager.default.fileExists(atPath: pendingSelectionURL.path))
    }

    func testCommittedCandidateSurvivesUnlinkBeforeFlushFailure() throws {
        let fixture = try fixture()
        registerTeardown(for: fixture)
        let fault = PlanningWorkspaceRemovalBarrierFault()
        let access = try PlanningVaultAccess.makeTesting(
            rootURL: fixture.root, applicationSupportDirectory: fixture.support,
            deviceID: fixture.ownerID,
            selectionRemovalBarrierHook: { try fault.check($0) })
        defer { access.close() }
        _ = try access.select(selection: fixture.selection, intent: .initialize)
        let candidate = fixture.support.appendingPathComponent("BarrierCandidate", isDirectory: true)
        try FileManager.default.createDirectory(at: candidate, withIntermediateDirectories: true)
        let candidateID = UUID()
        _ = try PlanningSafeFileIO.initializeLifeOS(at: candidate, vaultID: candidateID)
        fault.arm(prefix: "vault-selection-pending-")
        let committed = try access.select(selection: .testFactory(url: candidate),
            intent: .attach(expectedVaultID: candidateID))
        XCTAssertEqual(committed.vaultID, candidateID)
        XCTAssertEqual(fault.hits, 1)
        let pending = fixture.support.appendingPathComponent(
            "LifeOS/Planning/vault-selection-pending-\(fixture.ownerID.uuidString.lowercased()).json")
        XCTAssertFalse(FileManager.default.fileExists(atPath: pending.path), "Hook must run after unlink")
        let reopened = try PlanningVaultAccess.makeTesting(rootURL: candidate,
            applicationSupportDirectory: fixture.support, deviceID: fixture.ownerID)
        defer { reopened.close() }
        let restored = try reopened.restore()
        XCTAssertEqual(restored.vaultID, committed.vaultID)
        XCTAssertEqual(restored.selectionGeneration, committed.selectionGeneration)
        XCTAssertEqual(restored.state, .ready)
    }

    func testRollbackUnlinkBeforeFlushFailureNeverAcceptsCandidate() throws {
        let fixture = try fixture()
        registerTeardown(for: fixture)
        let fault = PlanningWorkspaceRemovalBarrierFault()
        let replacement = PlanningWorkspaceSelectionCommitFailure()
        let access = try PlanningVaultAccess.makeTesting(rootURL: fixture.root,
            applicationSupportDirectory: fixture.support, deviceID: fixture.ownerID,
            selectionAfterReplacementHook: { try replacement.afterReplacement() },
            selectionRemovalBarrierHook: { try fault.check($0) })
        defer { access.close() }
        let original = try access.select(selection: fixture.selection, intent: .initialize)
        let candidate = fixture.support.appendingPathComponent("RollbackCandidate", isDirectory: true)
        try FileManager.default.createDirectory(at: candidate, withIntermediateDirectories: true)
        let candidateID = UUID()
        _ = try PlanningSafeFileIO.initializeLifeOS(at: candidate, vaultID: candidateID)
        replacement.failNextAfterReplacement()
        XCTAssertThrowsError(try access.select(selection: .testFactory(url: candidate),
            intent: .attach(expectedVaultID: candidateID)))
        fault.arm(prefix: "vault-selection-pending-")
        XCTAssertThrowsError(try access.restore())
        XCTAssertEqual(fault.hits, 1)
        XCTAssertFalse(access.snapshot.capabilities.canRead)
        let reopened = try PlanningVaultAccess.makeTesting(rootURL: fixture.root,
            applicationSupportDirectory: fixture.support, deviceID: fixture.ownerID)
        defer { reopened.close() }
        let restored = try reopened.restore()
        XCTAssertEqual(restored.state, .ready)
        XCTAssertEqual(restored.vaultID, original.vaultID)
        XCTAssertEqual(restored.selectionGeneration, original.selectionGeneration)
        XCTAssertNotEqual(restored.vaultID, candidateID)
    }

    func testRevokeRetryRequiresRemovalDirectoryBarrier() throws {
        let fixture = try fixture()
        registerTeardown(for: fixture)
        let fault = PlanningWorkspaceRemovalBarrierFault()
        let access = try PlanningVaultAccess.makeTesting(rootURL: fixture.root,
            applicationSupportDirectory: fixture.support, deviceID: fixture.ownerID,
            selectionRemovalBarrierHook: { try fault.check($0) })
        defer { access.close() }
        _ = try access.select(selection: fixture.selection, intent: .initialize)
        let name = "vault-selection-\(fixture.ownerID.uuidString.lowercased()).json"
        fault.arm(prefix: name)
        XCTAssertFalse(access.revoke())
        XCTAssertFalse(FileManager.default.fileExists(atPath:
            fixture.support.appendingPathComponent("LifeOS/Planning/" + name).path))
        XCTAssertFalse(access.revoke(), "ENOENT must still reach the failing directory barrier")
        XCTAssertEqual(fault.hits, 2)
        XCTAssertEqual(access.snapshot.state, .needsReselection)
        fault.disarm()
        XCTAssertTrue(access.revoke())
        XCTAssertEqual(access.snapshot.state, .unselected)
        let reopened = try PlanningVaultAccess.makeTesting(rootURL: fixture.root,
            applicationSupportDirectory: fixture.support, deviceID: fixture.ownerID)
        defer { reopened.close() }
        XCTAssertEqual(try reopened.restore().state, .unselected)
    }

    func testSelectionTransactionEvidenceValidation() throws {
        for scenario in ["transaction", "device", "orphan"] {
            let fixture = try fixture()
            registerTeardown(for: fixture)
            let access = try PlanningVaultAccess.makeTesting(rootURL: fixture.root,
                applicationSupportDirectory: fixture.support, deviceID: fixture.ownerID)
            defer { access.close() }
            _ = try access.select(selection: fixture.selection, intent: .initialize)
            let directory = fixture.support.appendingPathComponent("LifeOS/Planning")
            let suffix = fixture.ownerID.uuidString.lowercased() + ".json"
            let composite = try Data(contentsOf: directory.appendingPathComponent("vault-selection-" + suffix))
            var candidate = composite
            if scenario == "device" {
                var object = try XCTUnwrap(JSONSerialization.jsonObject(with: composite) as? [String: Any])
                var grant = try XCTUnwrap(object["grant"] as? [String: Any])
                grant["deviceID"] = UUID().uuidString
                object["grant"] = grant
                candidate = try JSONSerialization.data(withJSONObject: object)
            }
            let transactionID = UUID().uuidString
            if scenario != "orphan" {
                try JSONSerialization.data(withJSONObject: [
                    "schemaVersion": 2, "transactionID": transactionID,
                    "previousComposite": composite.base64EncodedString(),
                    "candidateComposite": candidate.base64EncodedString()
                ]).write(to: directory.appendingPathComponent("vault-selection-pending-" + suffix))
            } else {
                // A valid but byte-distinct composite cannot be authorized by an orphan decision.
                let object = try JSONSerialization.jsonObject(with: composite)
                candidate = try JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted])
                XCTAssertNotEqual(candidate, composite)
            }
            try JSONSerialization.data(withJSONObject: [
                "schemaVersion": 1,
                "transactionID": scenario == "transaction" ? UUID().uuidString : transactionID,
                "candidateComposite": candidate.base64EncodedString()
            ]).write(to: directory.appendingPathComponent("vault-selection-decision-" + suffix))
            XCTAssertThrowsError(try access.restore(), scenario) {
                XCTAssertEqual($0 as? PlanningFilesystemError, .corruptEvidence, scenario)
            }
            XCTAssertEqual(access.snapshot.state, .needsReselection, scenario)
            XCTAssertFalse(access.snapshot.capabilities.canRead, scenario)
            XCTAssertFalse(access.snapshot.capabilities.canPublish, scenario)
            XCTAssertThrowsError(try access.withLease { _ in XCTFail("Invalid evidence granted a lease") })
        }
    }

    func testCommittedSelectionSurvivesPostRemovalCleanupFailure() throws {
        let fixture = try fixture()
        registerTeardown(for: fixture)
        let access = try PlanningVaultAccess.makeTesting(
            rootURL: fixture.root, applicationSupportDirectory: fixture.support,
            deviceID: fixture.ownerID,
            selectionPendingCleanupHook: { throw PlanningFilesystemError.diskFull }
        )
        defer { access.close() }
        let committed = try access.select(selection: fixture.selection, intent: .initialize)
        XCTAssertEqual(committed.state, .ready)
        let directory = fixture.support.appendingPathComponent("LifeOS/Planning")
        let suffix = fixture.ownerID.uuidString.lowercased() + ".json"
        XCTAssertFalse(FileManager.default.fileExists(atPath:
            directory.appendingPathComponent("vault-selection-pending-" + suffix).path))
        XCTAssertTrue(FileManager.default.fileExists(atPath:
            directory.appendingPathComponent("vault-selection-decision-" + suffix).path))
        let reopened = try PlanningVaultAccess.makeTesting(
            rootURL: fixture.root, applicationSupportDirectory: fixture.support,
            deviceID: fixture.ownerID)
        defer { reopened.close() }
        let restored = try reopened.restore()
        XCTAssertEqual(restored.vaultID, committed.vaultID)
        XCTAssertEqual(restored.selectionGeneration, committed.selectionGeneration)
        XCTAssertEqual(restored.state, .ready)
    }

    func testRevocationRemovalFailureRequiresReselectionAndCanRestoreGrant() throws {
        let fixture = try fixture()
        registerTeardown(for: fixture)
        let access = try PlanningVaultAccess.makeTesting(
            rootURL: fixture.root, applicationSupportDirectory: fixture.support,
            deviceID: fixture.ownerID,
            selectionPendingCleanupHook: { throw PlanningFilesystemError.diskFull })
        defer { access.close() }
        let original = try access.select(selection: fixture.selection, intent: .initialize)
        let directory = fixture.support.appendingPathComponent("LifeOS/Planning")
        let suffix = fixture.ownerID.uuidString.lowercased() + ".json"
        let composite = try Data(contentsOf: directory.appendingPathComponent("vault-selection-" + suffix))
        // A rollback-only transaction forces remove() through recovery cleanup.
        try FileManager.default.removeItem(at: directory.appendingPathComponent("vault-selection-decision-" + suffix))
        let pending = try JSONSerialization.data(withJSONObject: [
            "schemaVersion": 1, "previousComposite": composite.base64EncodedString()
        ])
        try pending.write(to: directory.appendingPathComponent("vault-selection-pending-" + suffix))

        XCTAssertFalse(access.revoke())
        XCTAssertEqual(access.snapshot.state, .needsReselection)
        XCTAssertFalse(access.snapshot.capabilities.canRead)
        XCTAssertFalse(access.snapshot.capabilities.canPublish)
        XCTAssertNil(access.selectedRootURL)
        XCTAssertThrowsError(try access.withLease { _ in XCTFail("Revoked access granted a lease") })

        let reopened = try PlanningVaultAccess.makeTesting(
            rootURL: fixture.root, applicationSupportDirectory: fixture.support,
            deviceID: fixture.ownerID)
        defer { reopened.close() }
        let restored = try reopened.restore()
        XCTAssertEqual(restored.state, .ready)
        XCTAssertEqual(restored.vaultID, original.vaultID)
        XCTAssertEqual(restored.selectionGeneration, original.selectionGeneration)
    }

    func testSuccessfulRevocationRemovesSelectionAndTransactionMetadata() throws {
        let fixture = try fixture()
        registerTeardown(for: fixture)
        let access = try PlanningVaultAccess.makeTesting(
            rootURL: fixture.root, applicationSupportDirectory: fixture.support,
            deviceID: fixture.ownerID)
        defer { access.close() }
        _ = try access.select(selection: fixture.selection, intent: .initialize)
        let directory = fixture.support.appendingPathComponent("LifeOS/Planning")
        let suffix = fixture.ownerID.uuidString.lowercased() + ".json"
        let composite = try Data(contentsOf: directory.appendingPathComponent("vault-selection-" + suffix))
        let transactionID = UUID().uuidString
        let pending = try JSONSerialization.data(withJSONObject: [
            "schemaVersion": 2, "transactionID": transactionID,
            "previousComposite": composite.base64EncodedString(),
            "candidateComposite": composite.base64EncodedString()
        ])
        let decision = try JSONSerialization.data(withJSONObject: [
            "schemaVersion": 1, "transactionID": transactionID,
            "candidateComposite": composite.base64EncodedString()
        ])
        try pending.write(to: directory.appendingPathComponent("vault-selection-pending-" + suffix))
        try decision.write(to: directory.appendingPathComponent("vault-selection-decision-" + suffix))

        XCTAssertTrue(access.revoke())
        XCTAssertEqual(access.snapshot.state, .unselected)
        for prefix in ["vault-selection-", "vault-selection-pending-", "vault-selection-decision-",
                       "vault-grant-", "authority-", "test-grant-"] {
            XCTAssertFalse(FileManager.default.fileExists(atPath: directory.appendingPathComponent(prefix + suffix).path))
        }
        let reopened = try PlanningVaultAccess.makeTesting(
            rootURL: fixture.root, applicationSupportDirectory: fixture.support,
            deviceID: fixture.ownerID)
        defer { reopened.close() }
        XCTAssertEqual(try reopened.restore().state, .unselected)
    }

    func testMalformedSelectionTransactionInvalidatesReadyAccess() throws {
        let fixture = try fixture()
        registerTeardown(for: fixture)
        let access = try PlanningVaultAccess.makeTesting(
            rootURL: fixture.root, applicationSupportDirectory: fixture.support,
            deviceID: fixture.ownerID)
        defer { access.close() }
        _ = try access.select(selection: fixture.selection, intent: .initialize)
        let pendingURL = fixture.support.appendingPathComponent(
            "LifeOS/Planning/vault-selection-pending-\(fixture.ownerID.uuidString.lowercased()).json")
        try Data(#"{"schemaVersion":2,"transactionID":"invalid","candidateComposite":"AA=="}"#.utf8)
            .write(to: pendingURL, options: .atomic)
        XCTAssertThrowsError(try access.restore()) { error in
            XCTAssertEqual(error as? PlanningFilesystemError, .corruptEvidence)
        }
        XCTAssertEqual(access.snapshot.state, .needsReselection)
        XCTAssertFalse(access.snapshot.capabilities.canRead)
        XCTAssertFalse(access.snapshot.capabilities.canPublish)
        XCTAssertNil(access.selectedVault)
        var leaseWasGranted = false
        XCTAssertThrowsError(try access.withLease { _ in leaseWasGranted = true })
        XCTAssertFalse(leaseWasGranted)
    }

    func testUncertainDecisionAcknowledgmentRequiresRecovery() throws {
        let fixture = try fixture()
        registerTeardown(for: fixture)
        let access = try PlanningVaultAccess.makeTesting(
            rootURL: fixture.root, applicationSupportDirectory: fixture.support,
            deviceID: fixture.ownerID,
            selectionDecisionCommitHook: { throw PlanningFilesystemError.diskFull })
        defer { access.close() }
        XCTAssertThrowsError(try access.select(selection: fixture.selection, intent: .initialize))
        XCTAssertEqual(access.snapshot.state, .needsReselection)
        XCTAssertFalse(access.snapshot.capabilities.canRead)
        let reopened = try PlanningVaultAccess.makeTesting(
            rootURL: fixture.root, applicationSupportDirectory: fixture.support,
            deviceID: fixture.ownerID)
        defer { reopened.close() }
        let restored = try reopened.restore()
        XCTAssertEqual(restored.state, .ready)
        XCTAssertEqual(restored.vaultID, fixture.ownerID)
    }

    func testUncertainAttachCommitReleasesInstalledWriterLock() async throws {
        try await assertUncertainSelectionReleasesInstalledWriterLock(initializing: false)
    }

    func testUncertainInitializeCommitReleasesInstalledWriterLock() async throws {
        try await assertUncertainSelectionReleasesInstalledWriterLock(initializing: true)
    }

    private func assertUncertainSelectionReleasesInstalledWriterLock(initializing: Bool) async throws {
        let fixture = try fixture()
        registerTeardown(for: fixture)
        let commitFailure = PlanningWorkspaceSelectionCommitFailure()
        let access = try PlanningVaultAccess.makeTesting(
            rootURL: fixture.root,
            applicationSupportDirectory: fixture.support,
            deviceID: fixture.ownerID,
            selectionDecisionCommitHook: { try commitFailure.beforeReplacement() }
        )
        let store = PlanningVaultStore(
            access: access,
            applicationSupportDirectory: fixture.support,
            deviceID: fixture.ownerID
        )
        addTeardownBlock { await store.close() }
        let original = try await store.attachExisting(selection: fixture.selection)
        let originalStatus = try await store.status()
        XCTAssertGreaterThan(originalStatus.databaseBytes, 0)
        let path = try PlanningStoredPath("Projects/Personal.canvas")
        let originalDocument = try await store.read(path)

        commitFailure.failNextCommit()
        let intent: PlanningVaultSelectionIntent = initializing
            ? .initialize : .attach(expectedVaultID: fixture.ownerID)
        do {
            _ = try await store.select(selection: fixture.selection, intent: intent)
            XCTFail("An uncertain decision acknowledgment must invalidate access.")
        } catch {
            XCTAssertEqual(error as? PlanningFilesystemError, .unavailable("selectionCommitUncertain"))
        }
        XCTAssertEqual(access.snapshot.state, .needsReselection)
        XCTAssertFalse(access.snapshot.capabilities.canRead)
        let failedStatus = try await store.status()
        XCTAssertEqual(failedStatus.databaseBytes, 0)

        // Keep the failed store alive and unclosed: recovery must not depend
        // on coordinator teardown to release its installed journal writer lock.
        let reopened = try PlanningVaultStore.makeTesting(
            rootURL: fixture.root,
            applicationSupportDirectory: fixture.support,
            deviceID: fixture.ownerID
        )
        addTeardownBlock { await reopened.close() }
        let restored = try await reopened.restore()
        XCTAssertEqual(restored.state, .ready)
        XCTAssertEqual(restored.vaultID, original.vaultID)
        let context = try await reopened.currentCanvasAccessContext()
        XCTAssertEqual(context.vaultID, restored.vaultID)
        XCTAssertEqual(context.selectionGeneration, restored.selectionGeneration)
        let status = try await reopened.status()
        XCTAssertGreaterThan(status.databaseBytes, 0)
        XCTAssertEqual(status.pendingMutationCount, originalStatus.pendingMutationCount)
        XCTAssertEqual(status.openConflictCount, originalStatus.openConflictCount)
        let document = try await reopened.read(path)
        XCTAssertEqual(document.snapshot?.bytes, originalDocument.snapshot?.bytes)
        XCTAssertEqual(document.selectionGeneration, restored.selectionGeneration)
    }

    func testAttachInvalidCandidateLeavesOldWorkspaceReadable() async throws {
        let fixture = try fixture()
        registerTeardown(for: fixture)

        let workspace = PlanningWorkspaceCoordinator(
            store: fixture.store,
            localGrantOwnerID: fixture.ownerID
        )
        await workspace.attach(fixture.selection)
        let original = workspace.accessSnapshot
        XCTAssertEqual(original.state, .ready)

        let candidateRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("lifeos-p06b-invalid-candidate-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: candidateRoot, withIntermediateDirectories: true)
        addTeardownBlock {
            try? FileManager.default.removeItem(at: candidateRoot)
        }
        let candidateSelection = try PlanningUserSelectedDirectory.testFactory(url: candidateRoot)

        await workspace.attach(candidateSelection)

        XCTAssertEqual(workspace.accessSnapshot, original)
        XCTAssertEqual(workspace.accessSnapshot.state, .ready)
        let document = try await fixture.store.read(
            try PlanningStoredPath("Projects/Personal.canvas")
        )
        XCTAssertEqual(
            document.snapshot?.bytes,
            Data(#"{"nodes":[{"id":"root","type":"text","x":0,"y":0,"width":200,"height":100,"text":"Plan"}],"edges":[],"custom":"keep"}"#.utf8)
        )
    }

    func testAttachCorruptCandidateLeavesOldWorkspaceReadyAndReadable() async throws {
        let fixture = try fixture()
        registerTeardown(for: fixture)

        let workspace = PlanningWorkspaceCoordinator(
            store: fixture.store,
            localGrantOwnerID: fixture.ownerID
        )
        await workspace.attach(fixture.selection)
        let original = workspace.accessSnapshot
        XCTAssertEqual(workspace.phase, .ready)

        let candidateRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("lifeos-p06b-corrupt-candidate-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: candidateRoot, withIntermediateDirectories: true)
        addTeardownBlock {
            try? FileManager.default.removeItem(at: candidateRoot)
        }
        let candidateID = UUID()
        _ = try PlanningSafeFileIO.initializeLifeOS(at: candidateRoot, vaultID: candidateID)
        let candidateJournalDirectory = fixture.support
            .appendingPathComponent("LifeOS/Planning/\(candidateID.uuidString.lowercased())", isDirectory: true)
        try FileManager.default.createDirectory(at: candidateJournalDirectory, withIntermediateDirectories: true)
        try Data("corrupt journal".utf8).write(
            to: candidateJournalDirectory.appendingPathComponent("journal.sqlite"),
            options: .atomic
        )
        let candidateSelection = try PlanningUserSelectedDirectory.testFactory(url: candidateRoot)

        await workspace.attach(candidateSelection)

        XCTAssertEqual(workspace.phase, .failed)
        XCTAssertEqual(workspace.accessSnapshot, original)
        XCTAssertEqual(workspace.accessSnapshot.state, .ready)
        let document = try await fixture.store.read(
            try PlanningStoredPath("Projects/Personal.canvas")
        )
        XCTAssertEqual(document.vaultID, original.vaultID)
        XCTAssertEqual(document.selectionGeneration, original.selectionGeneration)
        XCTAssertEqual(document.accessState, .ready)
    }

    func testRestoreJournalFailureDoesNotPublishReadyAccess() async throws {
        let fixture = try fixture()
        registerTeardown(for: fixture)
        let access = try PlanningVaultAccess.makeTesting(
            rootURL: fixture.root,
            applicationSupportDirectory: fixture.support,
            deviceID: fixture.ownerID
        )
        let store = PlanningVaultStore(
            access: access,
            applicationSupportDirectory: fixture.support,
            deviceID: fixture.ownerID
        )
        addTeardownBlock { await store.close() }
        let original = try await store.attachExisting(selection: fixture.selection)
        let path = try PlanningStoredPath("Projects/Personal.canvas")
        _ = try await store.read(path)
        _ = try await store.currentCanvasAccessContext()
        let originalStatus = try await store.status()
        XCTAssertEqual(original.state, .ready)
        XCTAssertGreaterThan(originalStatus.databaseBytes, 0)

        // Retain the resource fields and persisted selection, but force restore
        // to reopen and validate the journal instead of reusing a live handle.
        await store.closeInstalledJournalForTesting()
        let journalURL = fixture.support.appendingPathComponent(
            "LifeOS/Planning/\(fixture.ownerID.uuidString.lowercased())/journal.sqlite"
        )
        try Data("corrupt journal".utf8).write(to: journalURL, options: .atomic)

        do {
            _ = try await store.restore()
            XCTFail("Restore must reject the corrupt journal before publishing readiness.")
        } catch {
            // Resource errors use the access layer's existing error mapping.
            XCTAssertEqual(error as? PlanningFilesystemError, .unavailable("grant"))
        }
        let snapshot = access.snapshot
        XCTAssertEqual(snapshot.state, .needsReselection)
        XCTAssertFalse(snapshot.capabilities.canRead)
        XCTAssertFalse(snapshot.capabilities.canPublish)
        XCTAssertNil(snapshot.vaultID)
        XCTAssertNotEqual(snapshot.selectionGeneration, original.selectionGeneration)
        XCTAssertNil(access.selectedRootURL)
        let storeSnapshot = await store.accessSnapshot()
        XCTAssertEqual(storeSnapshot, snapshot)
        var leaseWasGranted = false
        XCTAssertThrowsError(try access.withLease { _ in leaseWasGranted = true })
        XCTAssertFalse(leaseWasGranted)
        do {
            _ = try await store.currentCanvasAccessContext()
            XCTFail("Failed restore must not expose a canvas context.")
        } catch {
            XCTAssertEqual(error as? PlanningFilesystemError, .needsReselection)
        }
        do {
            _ = try await store.read(path)
            XCTFail("Failed restore must not return a retained cached document.")
        } catch {
            XCTAssertEqual(error as? PlanningFilesystemError, .unselected)
        }
        let status = try await store.status()
        XCTAssertEqual(status.accessState, .needsReselection)
        XCTAssertEqual(status.pendingMutationCount, 0)
        XCTAssertEqual(status.openConflictCount, 0)
        XCTAssertEqual(status.retainedPayloadBytes, 0)
        XCTAssertEqual(status.databaseBytes, 0)
    }

    func testSelectAttachCorruptJournalImmediatelyPreservesOriginalWorkspace() async throws {
        try await assertCorruptCandidatePreservesWorkspace(useAttachExisting: false)
    }

    func testAttachExistingCorruptJournalImmediatelyPreservesOriginalWorkspace() async throws {
        try await assertCorruptCandidatePreservesWorkspace(useAttachExisting: true)
    }

    func testInitializeCorruptJournalImmediatelyPreservesOriginalWorkspace() async throws {
        try await assertCorruptCandidatePreservesWorkspace(useAttachExisting: false, initialize: true)
    }

    func testInitializeInstallsCandidateResourcesAfterCommit() async throws {
        let fixture = try fixture()
        registerTeardown(for: fixture)
        let original = try await fixture.store.attachExisting(selection: fixture.selection)
        let candidate = try self.fixture()
        registerTeardown(for: candidate)

        let selected = try await fixture.store.select(selection: candidate.selection, intent: .initialize)

        XCTAssertEqual(selected.state, .ready)
        XCTAssertEqual(selected.vaultID, candidate.ownerID)
        XCTAssertNotEqual(selected.selectionGeneration, original.selectionGeneration)
        let snapshot = await fixture.store.accessSnapshot()
        XCTAssertEqual(snapshot, selected)
        let context = try await fixture.store.currentCanvasAccessContext()
        let document = try await fixture.store.read(try PlanningStoredPath("Projects/Personal.canvas"))
        XCTAssertEqual(document.vaultID, candidate.ownerID)
        XCTAssertEqual(document.selectionGeneration, selected.selectionGeneration)
        XCTAssertEqual(document.snapshot?.bytes, try Data(contentsOf:
            candidate.root.appendingPathComponent("LifeOS/Projects/Personal.canvas")))
        XCTAssertFalse(document.stale)
        XCTAssertFalse(document.fromCache)
        let status = try await fixture.store.status()
        XCTAssertEqual(status.accessState, .ready)
        XCTAssertGreaterThan(status.databaseBytes, 0)

        let repeated = try await fixture.store.select(selection: candidate.selection, intent: .initialize)
        XCTAssertEqual(repeated, selected)
        let repeatedContext = try await fixture.store.currentCanvasAccessContext()
        XCTAssertEqual(repeatedContext, context)
    }

    private func assertCorruptCandidatePreservesWorkspace(
        useAttachExisting: Bool,
        initialize: Bool = false
    ) async throws {
        let fixture = try fixture()
        registerTeardown(for: fixture)

        let original = try await fixture.store.select(
            selection: fixture.selection,
            intent: .initialize
        )
        let path = try PlanningStoredPath("Projects/Personal.canvas")
        let originalContext = try await fixture.store.currentCanvasAccessContext()
        let originalDocument = try await fixture.store.read(path)
        let originalStatus = try await fixture.store.status()
        let candidateRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("lifeos-p06b-corrupt-configuration-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: candidateRoot, withIntermediateDirectories: true)
        addTeardownBlock {
            try? FileManager.default.removeItem(at: candidateRoot)
        }
        let candidateID = UUID()
        _ = try PlanningSafeFileIO.initializeLifeOS(at: candidateRoot, vaultID: candidateID)
        let candidateJournalDirectory = fixture.support
            .appendingPathComponent("LifeOS/Planning/\(candidateID.uuidString.lowercased())", isDirectory: true)
        try FileManager.default.createDirectory(at: candidateJournalDirectory, withIntermediateDirectories: true)
        try Data("corrupt journal".utf8).write(
            to: candidateJournalDirectory.appendingPathComponent("journal.sqlite"),
            options: .atomic
        )
        let candidateSelection = try PlanningUserSelectedDirectory.testFactory(url: candidateRoot)

        do {
            if initialize {
                _ = try await fixture.store.select(selection: candidateSelection, intent: .initialize)
            } else if useAttachExisting {
                _ = try await fixture.store.attachExisting(selection: candidateSelection)
            } else {
                _ = try await fixture.store.select(
                    selection: candidateSelection,
                    intent: .attach(expectedVaultID: candidateID)
                )
            }
            XCTFail("A corrupt candidate journal must reject configuration.")
        } catch let error as PlanningStorageError {
            XCTAssertEqual(error, .corruptDatabase)
        } catch {
            XCTFail("Unexpected configuration error: \(error)")
        }

        let preserved = await fixture.store.accessSnapshot()
        let context = try await fixture.store.currentCanvasAccessContext()
        XCTAssertEqual(preserved, original)
        XCTAssertEqual(context, originalContext)
        let status = try await fixture.store.status()
        XCTAssertEqual(status.accessState, .ready)
        XCTAssertEqual(status.pendingMutationCount, originalStatus.pendingMutationCount)
        XCTAssertEqual(status.openConflictCount, originalStatus.openConflictCount)
        XCTAssertEqual(status.retainedPayloadBytes, originalStatus.retainedPayloadBytes)
        XCTAssertEqual(status.databaseBytes, originalStatus.databaseBytes)
        // Failed initialization must leave the candidate's existing marker intact.
        let markerLease = try PlanningSafeFileIO.openRoot(candidateRoot, expectedVaultID: candidateID)
        markerLease.close()
        let document = try await fixture.store.read(path)
        XCTAssertEqual(document.snapshot?.bytes, originalDocument.snapshot?.bytes)
        XCTAssertEqual(document.version, originalDocument.version)
        XCTAssertEqual(document.vaultID, original.vaultID)
        XCTAssertEqual(document.selectionGeneration, original.selectionGeneration)
        XCTAssertEqual(document.accessState, .ready)
        XCTAssertFalse(document.stale)
        XCTAssertFalse(document.fromCache)
    }

    func testAttachReplacesClosedMatchingJournalWithoutChangingGeneration() async throws {
        let fixture = try fixture()
        registerTeardown(for: fixture)
        let original = try await fixture.store.attachExisting(selection: fixture.selection)
        let path = try PlanningStoredPath("Projects/Personal.canvas")
        let originalContext = try await fixture.store.currentCanvasAccessContext()
        let originalDocument = try await fixture.store.read(path)
        let originalStatus = try await fixture.store.status()

        // Retain the installed resources and access; close only the journal.
        await fixture.store.closeInstalledJournalForTesting()
        let reattached = try await fixture.store.attachExisting(selection: fixture.selection)

        XCTAssertEqual(reattached, original)
        let context = try await fixture.store.currentCanvasAccessContext()
        XCTAssertEqual(context, originalContext)
        let status = try await fixture.store.status()
        XCTAssertEqual(status.accessState, .ready)
        XCTAssertEqual(status.pendingMutationCount, originalStatus.pendingMutationCount)
        XCTAssertEqual(status.openConflictCount, originalStatus.openConflictCount)
        let document = try await fixture.store.read(path)
        XCTAssertEqual(document.snapshot?.bytes, originalDocument.snapshot?.bytes)
        XCTAssertEqual(document.vaultID, original.vaultID)
        XCTAssertEqual(document.selectionGeneration, original.selectionGeneration)
        XCTAssertFalse(document.stale)
        XCTAssertFalse(document.fromCache)
    }

    func testRejectedReplacementPreservesCommittedAccessAndBalancesCandidateScope() async throws {
        let fixture = try fixture()
        let counter = PlanningWorkspaceScopeCounter()
        let strategy = PlanningSecurityScopeStrategy(
            start: { _ in counter.start() },
            stop: { _ in counter.stop() }
        )
        let access = try PlanningVaultAccess.makeTesting(
            rootURL: fixture.root,
            applicationSupportDirectory: fixture.support,
            deviceID: fixture.ownerID,
            scopeStrategy: strategy
        )
        let store = PlanningVaultStore(
            access: access,
            applicationSupportDirectory: fixture.support,
            deviceID: fixture.ownerID
        )
        addTeardownBlock {
            await store.close()
            try? FileManager.default.removeItem(at: fixture.root)
            try? FileManager.default.removeItem(at: fixture.support)
        }

        let selected = try await store.select(
            selection: fixture.selection,
            intent: .initialize
        )
        let selectedContext = try await store.currentCanvasAccessContext()
        XCTAssertEqual(counter.counts.starts, 1)
        XCTAssertEqual(counter.counts.stops, 0)
        XCTAssertEqual(counter.counts.active, 1)

        let rejectedSelection = try PlanningUserSelectedDirectory.testFactory(url: fixture.root)
        do {
            _ = try await store.select(
                selection: rejectedSelection,
                intent: .attach(expectedVaultID: UUID())
            )
            XCTFail("A replacement with the wrong vault identity must fail.")
        } catch let error as PlanningFilesystemError {
            XCTAssertEqual(error, .identityChanged)
        } catch {
            XCTFail("Unexpected replacement error: \(error)")
        }

        let afterFailure = access.snapshot
        XCTAssertEqual(afterFailure, selected)
        XCTAssertEqual(afterFailure.state, .ready)
        XCTAssertEqual(afterFailure.capabilities, selected.capabilities)
        let contextAfterFailure = try await store.currentCanvasAccessContext()
        XCTAssertEqual(contextAfterFailure, selectedContext)
        let leasedVaultID = try access.withLease { $0.vaultID }
        XCTAssertEqual(leasedVaultID, fixture.ownerID)
        XCTAssertEqual(counter.counts.starts, 2)
        XCTAssertEqual(counter.counts.stops, 1)
        XCTAssertEqual(counter.counts.active, 1)
        XCTAssertEqual(counter.counts.maximumActive, 2)

        await store.close()
        XCTAssertEqual(counter.counts.starts, 2)
        XCTAssertEqual(counter.counts.stops, 2)
        XCTAssertEqual(counter.counts.active, 0)
    }

    func testExistingInspectionDoesNotSelectOrInitialize() throws {
        let fixture = try fixture()
        registerTeardown(for: fixture)

        let access = PlanningVaultAccess(
            applicationSupportDirectory: fixture.support,
            deviceID: UUID()
        )
        let identity = try access.inspectExistingSelection(fixture.selection)

        XCTAssertNotNil(identity.vaultID)
        XCTAssertEqual(access.snapshot.state, .unselected)
        XCTAssertNil(access.snapshot.vaultID)
    }

    func testAttachOpenPreservesCanvasUnknownFieldsAndKeepsProductionReadOnly() async throws {
        let fixture = try fixture()
        registerTeardown(for: fixture)

        let workspace = PlanningWorkspaceCoordinator(
            store: fixture.store,
            localGrantOwnerID: fixture.ownerID
        )
        await workspace.attach(fixture.selection)
        XCTAssertEqual(workspace.phase, .ready)
        XCTAssertEqual(workspace.accessSnapshot.state, .ready)

        await workspace.openCanvas(relativePath: "Projects/Personal.canvas")
        XCTAssertEqual(workspace.phase, .showingCanvas, workspace.lastError ?? "no workspace error")
        XCTAssertEqual(workspace.openedPath?.value, "Projects/Personal.canvas")
        XCTAssertEqual(workspace.project?.document?.unknownFields["custom"], .string("keep"))
        XCTAssertFalse(workspace.project?.allowsEditing ?? true)
        XCTAssertFalse(workspace.project?.canEdit ?? true)
        XCTAssertFalse(workspace.project?.beginNodeDrag(id: "root") ?? true)

        let status = try await fixture.store.status()
        XCTAssertEqual(status.pendingMutationCount, 0)
        XCTAssertEqual(status.openConflictCount, 0)
    }

    func testReadOnlyAdapterRejectsStageAndPublish() async throws {
        let fixture = try fixture()
        registerTeardown(for: fixture)

        let workspace = PlanningWorkspaceCoordinator(
            store: fixture.store,
            localGrantOwnerID: fixture.ownerID
        )
        await workspace.attach(fixture.selection)
        let context = try await fixture.store.currentCanvasAccessContext()
        let path = try PlanningStoredPath("Projects/Personal.canvas")
        let bytes = Data(#"{"nodes":[],"edges":[]}"#.utf8)
        let request = try PlanningMutationRequest(
            vaultID: fixture.ownerID,
            path: path,
            operation: .replace,
            expectedVersion: PlanningContentVersion(data: Data("existing".utf8)),
            proposedBytes: bytes
        )
        let adapter = PlanningReadOnlyCanvasPersistence(store: fixture.store)

        do {
            _ = try await adapter.stage(request, expectedContext: context)
            XCTFail("A read-only workspace must reject staging.")
        } catch let error as PlanningFilesystemError {
            XCTAssertEqual(error, .readOnly)
        }

        do {
            _ = try await adapter.publish(request, expectedContext: context)
            XCTFail("A read-only workspace must reject publication.")
        } catch let error as PlanningFilesystemError {
            XCTAssertEqual(error, .readOnly)
        }
    }

    func testMissingCanvasFailsWithoutFabricatingEmptyDocumentAndPreservesPath() async throws {
        let fixture = try fixture(withCanvas: false)
        registerTeardown(for: fixture)

        let workspace = PlanningWorkspaceCoordinator(
            store: fixture.store,
            localGrantOwnerID: fixture.ownerID
        )
        await workspace.attach(fixture.selection)
        await workspace.openCanvas(relativePath: "Projects/Missing.canvas")

        XCTAssertEqual(workspace.phase, .failed)
        XCTAssertEqual(workspace.pathInput, "Projects/Missing.canvas")
        XCTAssertNil(workspace.project)
        XCTAssertEqual(workspace.lastFailure, .notFound)
        XCTAssertEqual(workspace.lastDiagnostic?.stage, .sessionRead)
        XCTAssertEqual(workspace.lastDiagnostic?.code, PlanningFilesystemError.notFound.stableCode)
    }

    func testMalformedCanvasReportsDecodeFailure() async throws {
        let fixture = try fixture()
        registerTeardown(for: fixture)
        try Data("not a canvas".utf8).write(
            to: fixture.root.appendingPathComponent("LifeOS/Projects/Personal.canvas"),
            options: .atomic
        )

        let workspace = PlanningWorkspaceCoordinator(
            store: fixture.store,
            localGrantOwnerID: fixture.ownerID
        )
        await workspace.attach(fixture.selection)
        await workspace.openCanvas(relativePath: "Projects/Personal.canvas")

        XCTAssertEqual(workspace.phase, .failed)
        XCTAssertEqual(workspace.lastFailure, .decodeFailed)
        XCTAssertEqual(workspace.lastDiagnostic?.stage, .sessionRead)
        XCTAssertEqual(workspace.lastDiagnostic?.code, PlanningFilesystemError.malformedDocument.stableCode)
    }

    func testMarkdownAndTraversalInputsFailBeforeOpening() async throws {
        let fixture = try fixture()
        registerTeardown(for: fixture)

        let workspace = PlanningWorkspaceCoordinator(
            store: fixture.store,
            localGrantOwnerID: fixture.ownerID
        )
        await workspace.attach(fixture.selection)

        await workspace.openCanvas(relativePath: "Projects/Plan.md")
        XCTAssertEqual(workspace.phase, .failed)
        XCTAssertEqual(workspace.lastFailure, .invalidPath)
        XCTAssertNil(workspace.project)

        await workspace.openCanvas(relativePath: "../Projects/Personal.canvas")
        XCTAssertEqual(workspace.phase, .failed)
        XCTAssertEqual(workspace.lastFailure, .invalidPath)
        XCTAssertNil(workspace.project)
    }

    func testStableGrantOwnerIdentifierSurvivesCoordinatorRecreation() {
        let suite = "LifeOS.P06B.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }

        let support = FileManager.default.temporaryDirectory
            .appendingPathComponent("lifeos-p06b-owner-\(UUID().uuidString)", isDirectory: true)
        let first = PlanningWorkspaceCoordinator(
            applicationSupportDirectory: support,
            defaults: defaults
        )
        let second = PlanningWorkspaceCoordinator(
            applicationSupportDirectory: support,
            defaults: defaults
        )

        XCTAssertEqual(first.localGrantOwnerID, second.localGrantOwnerID)
    }

    func testCloseAndSuspendReleasePresentationWithoutChangingCalendarOwnedState() async throws {
        let fixture = try fixture()
        registerTeardown(for: fixture)

        let workspace = PlanningWorkspaceCoordinator(
            store: fixture.store,
            localGrantOwnerID: fixture.ownerID
        )
        await workspace.attach(fixture.selection)
        await workspace.openCanvas(relativePath: "Projects/Personal.canvas")
        XCTAssertEqual(workspace.phase, .showingCanvas, workspace.lastError ?? "no workspace error")

        workspace.closeDocument()
        XCTAssertEqual(workspace.phase, .ready)
        XCTAssertNil(workspace.project)
        XCTAssertNil(workspace.openedPath)

        await workspace.suspend()
        XCTAssertEqual(workspace.phase, .idle)
        XCTAssertEqual(workspace.accessSnapshot.state, .needsReselection)
    }

    func testCancelledOpenCannotPublishAfterSuspendAndCanReattach() async throws {
        let fixture = try fixture()
        registerTeardown(for: fixture)

        let workspace = PlanningWorkspaceCoordinator(
            store: fixture.store,
            localGrantOwnerID: fixture.ownerID
        )
        await workspace.attach(fixture.selection)
        workspace.beforePresentationOpen = {
            try? await Task.sleep(nanoseconds: 5_000_000_000)
        }

        let openTask = Task { await workspace.openCanvas(relativePath: "Projects/Personal.canvas") }
        for _ in 0..<100 where workspace.phase != .opening {
            await Task.yield()
        }
        XCTAssertEqual(workspace.phase, .opening)

        await workspace.suspend()
        await openTask.value
        XCTAssertEqual(workspace.phase, .idle)
        XCTAssertNil(workspace.project)
        XCTAssertNil(workspace.openedPath)

        workspace.beforePresentationOpen = nil
        await workspace.attach(fixture.selection)
        XCTAssertEqual(workspace.phase, .ready)
        await workspace.openCanvas(relativePath: "Projects/Personal.canvas")
        XCTAssertEqual(workspace.phase, .showingCanvas, workspace.lastError ?? "no workspace error")
    }

    func testRetryReopensEditedPathAndKeepsTypedFailure() async throws {
        let fixture = try fixture()
        registerTeardown(for: fixture)

        let workspace = PlanningWorkspaceCoordinator(
            store: fixture.store,
            localGrantOwnerID: fixture.ownerID
        )
        await workspace.attach(fixture.selection)
        await workspace.openCanvas(relativePath: "Projects/Missing.canvas")
        XCTAssertEqual(workspace.lastFailure, .notFound)
        XCTAssertEqual(workspace.pathInput, "Projects/Missing.canvas")

        workspace.pathInput = "Projects/Personal.canvas"
        await workspace.retry()
        XCTAssertEqual(workspace.phase, .showingCanvas, workspace.lastError ?? "no workspace error")
        XCTAssertEqual(workspace.openedPath?.value, "Projects/Personal.canvas")
    }

    func testContextFailureIsTypedAndReleasesWorkspaceLease() async throws {
        let fixture = try fixture()
        registerTeardown(for: fixture)

        let workspace = PlanningWorkspaceCoordinator(
            store: fixture.store,
            localGrantOwnerID: fixture.ownerID
        )
        await workspace.attach(fixture.selection)
        await fixture.store.close()
        await workspace.openCanvas(relativePath: "Projects/Personal.canvas")

        XCTAssertEqual(workspace.phase, .needsReselection)
        XCTAssertEqual(workspace.lastFailure, .needsReselection)
        XCTAssertEqual(workspace.lastDiagnostic?.stage, .storeContext)
        XCTAssertEqual(workspace.lastDiagnostic?.code, PlanningFilesystemError.needsReselection.stableCode)

        await workspace.attach(fixture.selection)
        XCTAssertEqual(workspace.phase, .ready)
    }

    func testLeaseContentionReleasesAfterSuspension() async throws {
        let fixture = try fixture()
        registerTeardown(for: fixture)
        let secondStore = try PlanningVaultStore.makeTesting(
            rootURL: fixture.root,
            applicationSupportDirectory: fixture.support,
            deviceID: fixture.ownerID
        )
        addTeardownBlock { await secondStore.close() }

        let first = PlanningWorkspaceCoordinator(store: fixture.store, localGrantOwnerID: fixture.ownerID)
        let second = PlanningWorkspaceCoordinator(store: secondStore, localGrantOwnerID: fixture.ownerID)
        await first.attach(fixture.selection)
        await second.attach(fixture.selection)
        XCTAssertEqual(second.phase, .unavailable)
        XCTAssertEqual(second.lastFailure, .unavailable)

        await first.suspend()
        await second.attach(fixture.selection)
        XCTAssertEqual(second.phase, .ready)
        await second.suspend()
    }

    func testRetryCannotReopenAfterDismissal() async throws {
        let fixture = try fixture()
        registerTeardown(for: fixture)

        let workspace = PlanningWorkspaceCoordinator(
            store: fixture.store,
            localGrantOwnerID: fixture.ownerID
        )
        await workspace.attach(fixture.selection)
        await workspace.openCanvas(relativePath: "Projects/Missing.canvas")
        XCTAssertEqual(workspace.lastFailure, .notFound)

        let gate = PlanningWorkspaceTestGate()
        workspace.pathInput = "Projects/Personal.canvas"
        workspace.beforeRetryOpen = { await gate.wait() }
        let retryTask = Task { await workspace.retry() }
        for _ in 0..<200 {
            if await gate.hasEntered { break }
            await Task.yield()
        }
        let retryGateEntered = await gate.hasEntered
        XCTAssertTrue(retryGateEntered)

        workspace.requestUnmount()
        await gate.release()
        await retryTask.value
        await workspace.unmount()

        XCTAssertEqual(workspace.phase, .idle)
        XCTAssertNil(workspace.project)
        XCTAssertNil(workspace.openedPath)
    }

    func testRemountWaitsForPendingCleanupBeforeReacquiringLease() async throws {
        let fixture = try fixture()
        registerTeardown(for: fixture)
        let secondStore = try PlanningVaultStore.makeTesting(
            rootURL: fixture.root,
            applicationSupportDirectory: fixture.support,
            deviceID: fixture.ownerID
        )
        addTeardownBlock { await secondStore.close() }

        let first = PlanningWorkspaceCoordinator(store: fixture.store, localGrantOwnerID: fixture.ownerID)
        let second = PlanningWorkspaceCoordinator(store: secondStore, localGrantOwnerID: fixture.ownerID)
        await first.attach(fixture.selection)
        let original = first.accessSnapshot

        let gate = PlanningWorkspaceTestGate()
        first.beforeCleanupClose = { await gate.wait() }
        first.requestUnmount()
        for _ in 0..<200 {
            if await gate.hasEntered { break }
            await Task.yield()
        }
        let cleanupGateEntered = await gate.hasEntered
        XCTAssertTrue(cleanupGateEntered)

        let remountTask = Task { await first.mount() }
        await second.attach(fixture.selection)
        XCTAssertEqual(second.phase, .unavailable)

        await gate.release()
        await remountTask.value
        first.beforeCleanupClose = nil
        XCTAssertEqual(first.phase, .ready)
        XCTAssertEqual(first.accessSnapshot.vaultID, original.vaultID)
        XCTAssertEqual(first.accessSnapshot.selectionGeneration, original.selectionGeneration)

        await first.suspend()
        await second.attach(fixture.selection)
        XCTAssertEqual(second.phase, .ready)
        await second.suspend()
    }

    func testDestroyedCoordinatorRetainsLeaseUntilStoreClose() async throws {
        let fixture = try fixture()
        registerTeardown(for: fixture)
        let secondStore = try PlanningVaultStore.makeTesting(
            rootURL: fixture.root,
            applicationSupportDirectory: fixture.support,
            deviceID: fixture.ownerID
        )
        addTeardownBlock { await secondStore.close() }

        let gate = PlanningWorkspaceTestGate()
        PlanningWorkspaceCoordinator.beforeDeinitStoreClose = { await gate.wait() }
        defer { PlanningWorkspaceCoordinator.beforeDeinitStoreClose = nil }

        var first: PlanningWorkspaceCoordinator? = PlanningWorkspaceCoordinator(
            store: fixture.store,
            localGrantOwnerID: fixture.ownerID
        )
        await first?.attach(fixture.selection)
        first = nil

        for _ in 0..<200 {
            if await gate.hasEntered { break }
            await Task.yield()
        }
        let deinitGateEntered = await gate.hasEntered
        XCTAssertTrue(deinitGateEntered)

        let second = PlanningWorkspaceCoordinator(store: secondStore, localGrantOwnerID: fixture.ownerID)
        await second.attach(fixture.selection)
        XCTAssertEqual(second.phase, .unavailable)

        await gate.release()
        for _ in 0..<200 {
            await second.attach(fixture.selection)
            if second.phase == .ready { break }
            await Task.yield()
        }
        XCTAssertEqual(second.phase, .ready)
        await second.suspend()
    }

    func testDiagnosticCodesDoNotEchoAssociatedInput() {
        XCTAssertEqual(
            PlanningFilesystemError.invalid("/private/user/secret.canvas").stableCode,
            "invalid.request"
        )
        XCTAssertEqual(
            PlanningCanvasSessionError.persistence("/private/user/secret").stableCode,
            "persistence.operation"
        )
    }
}
