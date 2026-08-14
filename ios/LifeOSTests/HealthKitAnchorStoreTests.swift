import XCTest
@testable import LifeOS

#if os(iOS) && canImport(HealthKit)
import HealthKit
#endif

private final class HealthKitAnchorReadCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var value = 0

    func increment() {
        lock.lock()
        value += 1
        lock.unlock()
    }

    var count: Int {
        lock.lock()
        defer { lock.unlock() }
        return value
    }
}

final class HealthKitAnchorStoreTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_700_000_000)

    private func observation(uuid: UUID = UUID(), identity: HealthKitSampleIdentity? = nil) throws -> HealthKitObservation {
        let source = try HealthKitSourceMetadata(bundleIdentifier: "com.example.source", name: "Source")
        let provenance = try HealthKitProvenance.from(
            source: source,
            device: nil,
            registry: .init(rules: [])
        )
        let value = try HealthKitQuantityValue(metric: .water, value: 250, unit: .milliliters)
        return try HealthKitObservation(
            metric: .water,
            identity: identity ?? .init(uuid: uuid, revision: .uuidFallback),
            value: .quantity(value),
            startDate: now.addingTimeInterval(-60),
            endDate: now.addingTimeInterval(-60),
            provenance: provenance,
            now: now
        )
    }

    private func oversizedIdentity() -> HealthKitSampleIdentity {
        HealthKitSampleIdentity(
            uuid: UUID(),
            aliases: (0...HealthKitSafetyLimits.maxSampleAliases).map { _ in UUID() },
            revision: .uuidFallback
        )
    }

    private func anchor(_ byte: UInt8 = 1) throws -> HealthKitOpaqueAnchor {
#if os(iOS) && canImport(HealthKit)
        let value = HKQueryAnchor(fromValue: Int(byte))
        return try HealthKitOpaqueAnchor(archivedData: NSKeyedArchiver.archivedData(withRootObject: value, requiringSecureCoding: true))
#else
        return try HealthKitOpaqueAnchor(archivedData: Data([byte, 0x02, 0x03]))
#endif
    }

    func testInitializationDefersEnvelopeReadUntilFirstSnapshot() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("healthkit-anchor-lazy-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let url = root.appendingPathComponent("anchors.json")
        let sample = try observation()
        let projection = try HealthKitMetricProjection(
            metric: .water,
            observations: [sample],
            lastCommittedAt: now,
            syncState: .synced
        )
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(HealthKitAnchorStoreEnvelope(projections: [projection])).write(to: url)

        let reads = HealthKitAnchorReadCounter()
        let store = HealthKitAnchorStore(persistenceURL: url, now: now, dataReader: { url in
            reads.increment()
            return try Data(contentsOf: url)
        })
        XCTAssertEqual(reads.count, 0, "actor initialization must not read the envelope")

        let state = await store.snapshot(for: .water)
        XCTAssertEqual(reads.count, 1, "the first awaited operation must perform the one-shot read")
        XCTAssertEqual(state.observations, [sample])
        _ = await store.snapshot(for: .water)
        XCTAssertEqual(reads.count, 1, "subsequent operations must reuse the loaded envelope")
    }

    func testConcurrentFirstAccessSharesOneEnvelopeRead() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("healthkit-anchor-concurrent-load-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let url = root.appendingPathComponent("anchors.json")
        let sample = try observation()
        let projection = try HealthKitMetricProjection(
            metric: .water,
            observations: [sample],
            lastCommittedAt: now,
            syncState: .synced
        )
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(HealthKitAnchorStoreEnvelope(projections: [projection])).write(to: url)

        let reads = HealthKitAnchorReadCounter()
        let store = HealthKitAnchorStore(persistenceURL: url, now: now, dataReader: { url in
            reads.increment()
            return try Data(contentsOf: url)
        })
        let states = await withTaskGroup(of: HealthKitStoredMetricState.self, returning: [HealthKitStoredMetricState].self) { group in
            for _ in 0..<8 {
                group.addTask { await store.snapshot(for: .water) }
            }
            var values: [HealthKitStoredMetricState] = []
            values.reserveCapacity(8)
            for await state in group {
                values.append(state)
            }
            return values
        }

        XCTAssertEqual(reads.count, 1, "concurrent first callers must share the actor-isolated load")
        XCTAssertEqual(states.count, 8)
        XCTAssertTrue(states.allSatisfy { $0.observations == [sample] })
    }

    func testProtectedLoadFailureIsDeferredAndNeverLooksLikeEmptyTruth() async throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("healthkit-anchor-protected-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: url) }
        let reads = HealthKitAnchorReadCounter()
        let store = HealthKitAnchorStore(persistenceURL: url, now: now, dataReader: { _ in
            reads.increment()
            throw NSError(domain: "NSPOSIXErrorDomain", code: 13)
        })
        XCTAssertEqual(reads.count, 0)

        let state = await store.snapshot(for: .water)
        XCTAssertEqual(reads.count, 1)
        XCTAssertEqual(state.syncState, .error)
        let hasLoadFailure = await store.hasLoadFailure()
        XCTAssertTrue(hasLoadFailure)
        let loadFailureState = await store.loadFailureState()
        XCTAssertEqual(loadFailureState, .protectedDataUnavailable)
        XCTAssertEqual(reads.count, 1)

        do {
            _ = try await store.commit(
                metric: .water,
                observations: [],
                tombstones: [],
                sourceIndex: [:],
                nextAnchor: nil,
                syncState: .synced,
                committedAt: now
            )
            XCTFail("protected load failure must block commit")
        } catch let error as HealthKitAnchorStoreError {
            XCTAssertEqual(error, .protectedDataUnavailable)
        }
        let quarantined = (try FileManager.default.contentsOfDirectory(atPath: url.deletingLastPathComponent().path))
            .contains { $0.contains("quarantine") }
        XCTAssertFalse(quarantined, "protected data must not be quarantined as malformed")
    }

    func testInjectedNoSuchFileForAbsentEnvelopeRemainsFirstLaunchEmpty() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("healthkit-anchor-missing-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let url = root.appendingPathComponent("anchors.json")
        let reads = HealthKitAnchorReadCounter()
        let store = HealthKitAnchorStore(persistenceURL: url, now: now, dataReader: { _ in
            reads.increment()
            throw NSError(domain: NSCocoaErrorDomain, code: CocoaError.fileReadNoSuchFile.rawValue)
        })

        let state = await store.snapshot(for: .water)
        XCTAssertEqual(reads.count, 1)
        XCTAssertEqual(state.syncState, .neverSynced)
        let hasLoadFailure = await store.hasLoadFailure()
        XCTAssertFalse(hasLoadFailure, "a genuinely absent optional envelope is first-launch state")

        _ = try await store.commit(
            metric: .water,
            observations: [],
            tombstones: [],
            sourceIndex: [:],
            nextAnchor: nil,
            syncState: .synced,
            committedAt: now
        )
        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path), "a genuinely absent envelope must allow its first durable create")
    }

    func testInjectedNoSuchFileThroughBlockingParentIsUnreadableFailure() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("healthkit-anchor-blocking-parent-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let blockingParent = root.appendingPathComponent("not-a-directory")
        try Data("block".utf8).write(to: blockingParent)
        let url = blockingParent.appendingPathComponent("anchors.json")
        let store = HealthKitAnchorStore(persistenceURL: url, now: now, dataReader: { _ in
            throw NSError(domain: NSCocoaErrorDomain, code: CocoaError.fileReadNoSuchFile.rawValue)
        })

        let state = await store.snapshot(for: .water)
        XCTAssertEqual(state.syncState, .error, "ENOTDIR must not look like first-launch empty state")
        let hasLoadFailure = await store.hasLoadFailure()
        XCTAssertTrue(hasLoadFailure)
        let loadFailureState = await store.loadFailureState()
        XCTAssertEqual(loadFailureState, .unreadable)
    }

    func testInjectedNoSuchFileForDanglingSymlinkIsUnreadableFailure() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("healthkit-anchor-dangling-symlink-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let url = root.appendingPathComponent("anchors.json")
        let missingTarget = root.appendingPathComponent("missing-target.json")
        try FileManager.default.createSymbolicLink(at: url, withDestinationURL: missingTarget)
        let store = HealthKitAnchorStore(persistenceURL: url, now: now, dataReader: { _ in
            throw NSError(domain: NSCocoaErrorDomain, code: CocoaError.fileReadNoSuchFile.rawValue)
        })

        let state = await store.snapshot(for: .water)
        XCTAssertEqual(state.syncState, .error, "a dangling symlink is not an optional missing envelope")
        let hasLoadFailure = await store.hasLoadFailure()
        XCTAssertTrue(hasLoadFailure)
        let loadFailureState = await store.loadFailureState()
        XCTAssertEqual(loadFailureState, .unreadable)
    }

    func testMissingLoadUsesExclusiveCreateWhenFileAppearsBeforeFirstCommit() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("healthkit-anchor-race-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let url = root.appendingPathComponent("anchors.json")
        let store = HealthKitAnchorStore(persistenceURL: url, now: now, dataReader: { _ in
            throw NSError(domain: NSCocoaErrorDomain, code: CocoaError.fileReadNoSuchFile.rawValue)
        })
        let initial = await store.snapshot(for: .water)
        XCTAssertEqual(initial.syncState, .neverSynced)

        let externalBytes = Data("external-writer".utf8)
        try externalBytes.write(to: url)
        do {
            _ = try await store.commit(
                metric: .water,
                observations: [],
                tombstones: [],
                sourceIndex: [:],
                nextAnchor: nil,
                syncState: .synced,
                committedAt: now
            )
            XCTFail("first persistence after a missing load must not overwrite a raced-in file")
        } catch let error as HealthKitAnchorStoreError {
            XCTAssertEqual(error, .persistenceFailed)
        }
        XCTAssertEqual(try Data(contentsOf: url), externalBytes)
        let state = await store.snapshot(for: .water)
        XCTAssertEqual(state.syncState, .neverSynced, "failed exclusive create must not advance in-memory truth")
    }

    func testCommitPersistsProjectionAndAnchorTogether() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("healthkit-anchor-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("anchors.json")
        let store = HealthKitAnchorStore(persistenceURL: url)
        let sample = try observation()
        _ = try await store.commit(
            metric: .water,
            observations: [sample],
            tombstones: [],
            sourceIndex: ["com.example.source|unknown|unknown": .other],
            nextAnchor: try anchor(),
            syncState: .synced,
            committedAt: now
        )

        let reloaded = HealthKitAnchorStore(persistenceURL: url, now: now)
        let state = await reloaded.snapshot(for: .water)
        XCTAssertEqual(state.observations, [sample])
        XCTAssertEqual(state.anchor, try anchor())
        XCTAssertEqual(state.syncState, .synced)
    }

    func testFailedCommitDoesNotAdvanceAnchorOrProjection() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("healthkit-anchor-failure-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let blockingFile = root.appendingPathComponent("not-a-directory")
        try Data("block".utf8).write(to: blockingFile)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = HealthKitAnchorStore(persistenceURL: blockingFile.appendingPathComponent("anchors.json"), now: now)

        do {
            _ = try await store.commit(
                metric: .water,
                observations: [try observation()],
                tombstones: [],
                sourceIndex: [:],
                nextAnchor: try anchor(9),
                syncState: .synced,
                committedAt: now
            )
            XCTFail("commit should fail when its parent is a file")
        } catch {
            // The previous projection/anchor remains untouched.
        }
        let state = await store.snapshot(for: .water)
        XCTAssertTrue(state.observations.isEmpty)
        XCTAssertNil(state.anchor)
        XCTAssertEqual(state.syncState, .error, "an unreadable existing path must not look like a first-launch empty store")
    }

    func testCorruptAnchorPreservesValidProjectionAndRequestsBoundedFullResync() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("healthkit-anchor-corrupt-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("anchors.json")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let sample = try observation()
        let projection = try HealthKitMetricProjection(
            metric: .water,
            observations: [sample],
            // Base64 syntax alone is not an Apple HKQueryAnchor archive.
            anchorArchive: Data([0x01, 0x02, 0x03]).base64EncodedString(),
            lastCommittedAt: now,
            syncState: .synced
        )
        let envelope = HealthKitAnchorStoreEnvelope(projections: [projection])
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(envelope).write(to: url)

        let store = HealthKitAnchorStore(persistenceURL: url, now: now)
        let state = await store.snapshot(for: .water)
        XCTAssertEqual(state.observations, [sample])
        XCTAssertNil(state.anchor)
        XCTAssertEqual(state.syncState, .fullResyncRequired)
        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path), "valid projection must not be deleted")
        let quarantined = try FileManager.default.contentsOfDirectory(atPath: root.path)
            .contains { $0.contains(".quarantine-anchor-") }
        XCTAssertTrue(quarantined, "the malformed anchor should be quarantined without deleting the source envelope")

        let reloaded = HealthKitAnchorStore(persistenceURL: url, now: now)
        let durableState = await reloaded.snapshot(for: .water)
        XCTAssertEqual(durableState.syncState, .fullResyncRequired)
        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path), "the bad archive is retained in the repaired envelope")

        let cleared = try await store.clearAnchor(for: .water, committedAt: now)
        XCTAssertNil(cleared.anchor)
        XCTAssertEqual(cleared.syncState, .neverSynced)
        XCTAssertNil(cleared.anchor)
    }

    func testCorruptAnchorWithoutPriorCommitTimeIsRepairedAndCleared() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("healthkit-anchor-corrupt-empty-(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let url = root.appendingPathComponent("anchors.json")
        let projection = try HealthKitMetricProjection(
            metric: .water,
            anchorArchive: "not-a-valid-anchor",
            lastCommittedAt: nil,
            syncState: .neverSynced
        )
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(HealthKitAnchorStoreEnvelope(projections: [projection])).write(to: url)

        let store = HealthKitAnchorStore(persistenceURL: url, now: now)
        let repaired = await store.snapshot(for: .water)
        XCTAssertEqual(repaired.syncState, .fullResyncRequired)
        XCTAssertEqual(repaired.lastCommittedAt, now)
        XCTAssertNil(repaired.anchor)
        let cleared = try await store.clearAnchor(for: .water, committedAt: now)
        XCTAssertEqual(cleared.syncState, .neverSynced)
        XCTAssertNil(cleared.anchorArchive)
        XCTAssertEqual(cleared.lastCommittedAt, now)
    }

    func testPersistedConflictDerivesConflictState() throws {
        let sample = try observation()
        let changed = try HealthKitObservation(
            metric: .water,
            identity: sample.identity,
            value: .quantity(try HealthKitQuantityValue(metric: .water, value: 400, unit: .milliliters)),
            startDate: sample.startDate,
            endDate: sample.endDate,
            provenance: sample.provenance,
            now: now
        )
        let conflict = HealthKitObservationConflict(metric: .water, identity: sample.identity, existing: sample, incoming: changed)
        let projection = try HealthKitMetricProjection(
            metric: .water,
            observations: [sample],
            conflicts: [conflict],
            lastCommittedAt: now,
            syncState: .synced
        )
        XCTAssertEqual(projection.syncState, .conflict)
    }

    func testProjectionRejectsOversizedAliasesAtEveryIdentityBoundary() throws {
        let testNow = now
        let oversized = oversizedIdentity()
        let normal = try observation()
        let changed = try HealthKitObservation(
            metric: .water,
            identity: normal.identity,
            value: .quantity(try HealthKitQuantityValue(metric: .water, value: 400, unit: .milliliters)),
            startDate: normal.startDate,
            endDate: normal.endDate,
            provenance: normal.provenance,
            now: testNow
        )
        let oversizedObservation = try observation(identity: oversized)
        let oversizedTombstone = try HealthKitDeletionTombstone(
            metric: .water,
            identity: oversized,
            deletedAt: testNow
        )
        let attempts: [(String, () throws -> Void)] = [
            ("observation identity", {
                _ = try HealthKitMetricProjection(
                    metric: .water,
                    observations: [oversizedObservation],
                    lastCommittedAt: testNow,
                    syncState: .synced
                )
            }),
            ("tombstone identity", {
                _ = try HealthKitMetricProjection(
                    metric: .water,
                    tombstones: [oversizedTombstone],
                    lastCommittedAt: testNow,
                    syncState: .synced
                )
            }),
            ("conflict identity", {
                _ = try HealthKitMetricProjection(
                    metric: .water,
                    observations: [normal],
                    conflicts: [HealthKitObservationConflict(
                        metric: .water,
                        identity: oversized,
                        existing: normal,
                        incoming: changed
                    )],
                    lastCommittedAt: testNow,
                    syncState: .synced
                )
            }),
            ("conflict existing identity", {
                _ = try HealthKitMetricProjection(
                    metric: .water,
                    observations: [normal],
                    conflicts: [HealthKitObservationConflict(
                        metric: .water,
                        identity: normal.identity,
                        existing: oversizedObservation,
                        incoming: changed
                    )],
                    lastCommittedAt: testNow,
                    syncState: .synced
                )
            }),
            ("conflict incoming identity", {
                _ = try HealthKitMetricProjection(
                    metric: .water,
                    observations: [normal],
                    conflicts: [HealthKitObservationConflict(
                        metric: .water,
                        identity: normal.identity,
                        existing: normal,
                        incoming: oversizedObservation
                    )],
                    lastCommittedAt: testNow,
                    syncState: .synced
                )
            })
        ]

        for (label, attempt) in attempts {
            XCTAssertThrowsError(try attempt(), "\(label) must be rejected at the projection boundary")
        }
    }

    func testCommitRejectsOversizedAliasesWithoutMutatingPriorDurableTruth() async throws {
        let normal = try observation()
        let changed = try HealthKitObservation(
            metric: .water,
            identity: normal.identity,
            value: .quantity(try HealthKitQuantityValue(metric: .water, value: 400, unit: .milliliters)),
            startDate: normal.startDate,
            endDate: normal.endDate,
            provenance: normal.provenance,
            now: now
        )
        let oversizedObservation = try observation(identity: oversizedIdentity())
        let oversizedTombstone = try HealthKitDeletionTombstone(
            metric: .water,
            identity: oversizedIdentity(),
            deletedAt: now
        )
        let attempts: [(String, [HealthKitObservation], [HealthKitDeletionTombstone], [HealthKitObservationConflict])] = [
            ("observation identity", [oversizedObservation], [], []),
            ("tombstone identity", [], [oversizedTombstone], []),
            ("conflict identity", [normal], [], [HealthKitObservationConflict(
                metric: .water,
                identity: oversizedIdentity(),
                existing: normal,
                incoming: changed
            )]),
            ("conflict existing identity", [normal], [], [HealthKitObservationConflict(
                metric: .water,
                identity: normal.identity,
                existing: oversizedObservation,
                incoming: changed
            )]),
            ("conflict incoming identity", [normal], [], [HealthKitObservationConflict(
                metric: .water,
                identity: normal.identity,
                existing: normal,
                incoming: oversizedObservation
            )])
        ]

        for (label, observations, tombstones, conflicts) in attempts {
            let root = FileManager.default.temporaryDirectory.appendingPathComponent("healthkit-anchor-bounds-(UUID().uuidString)", isDirectory: true)
            defer { try? FileManager.default.removeItem(at: root) }
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            let url = root.appendingPathComponent("anchors.json")
            let store = HealthKitAnchorStore(persistenceURL: url, now: now)
            _ = try await store.commit(
                metric: .water,
                observations: [normal],
                tombstones: [],
                sourceIndex: [:],
                nextAnchor: nil,
                syncState: .synced,
                committedAt: now
            )
            let before = await store.snapshot(for: .water)

            do {
                _ = try await store.commit(
                    metric: .water,
                    observations: observations,
                    tombstones: tombstones,
                    sourceIndex: [:],
                    conflicts: conflicts,
                    nextAnchor: nil,
                    syncState: .synced,
                    committedAt: now
                )
                XCTFail("\(label) must be rejected at the commit boundary")
            } catch { }

            let after = await store.snapshot(for: .water)
            XCTAssertEqual(after, before, "rejected \(label) commit must not mutate in-memory truth")
            let reloaded = HealthKitAnchorStore(persistenceURL: url, now: now)
            let durable = await reloaded.snapshot(for: .water)
            XCTAssertEqual(durable, before, "rejected \(label) commit must not mutate durable truth")
        }
    }

    func testCommitRejectsProvenanceThatIsNotCanonicalRegistryDerived() async throws {
        let source = try HealthKitSourceMetadata(bundleIdentifier: "com.example.source", name: "Source")
        let forged = try HealthKitProvenance.from(
            source: source,
            device: nil,
            registry: HealthKitHelioEvidenceRegistry(rules: [try HealthKitHelioEvidenceRule(bundleIdentifier: "com.example.source")])
        )
        let quantity = try HealthKitQuantityValue(metric: .water, value: 250, unit: .milliliters)
        let forgedObservation = try HealthKitObservation(
            metric: .water,
            identity: .init(uuid: UUID()),
            value: .quantity(quantity),
            startDate: now.addingTimeInterval(-60),
            endDate: now.addingTimeInterval(-60),
            provenance: forged,
            now: now
        )
        let store = HealthKitAnchorStore(persistenceURL: nil)
        do {
            _ = try await store.commit(
                metric: .water,
                observations: [forgedObservation],
                tombstones: [],
                sourceIndex: [:],
                nextAnchor: nil,
                syncState: .synced,
                committedAt: now
            )
            XCTFail("custom Helio evidence must not cross the durable boundary")
        } catch { }
        let state = await store.snapshot(for: .water)
        XCTAssertTrue(state.observations.isEmpty)
    }

    func testUnknownEnvelopeFieldsAreRejectedWithoutFixtureFallback() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("healthkit-anchor-unknown-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("anchors.json")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try Data("{\"schemaVersion\":1,\"projections\":[],\"fixture\":true}".utf8).write(to: url)
        let store = HealthKitAnchorStore(persistenceURL: url, now: now)
        let hasLoadFailure = await store.hasLoadFailure()
        XCTAssertTrue(hasLoadFailure)
        let state = await store.snapshot(for: .water)
        XCTAssertTrue(state.observations.isEmpty)
        XCTAssertNil(state.anchor)
        XCTAssertEqual(state.syncState, .error, "an unreadable envelope must not look like a first-launch empty projection")
    }

    func testLoadFailureBlocksCommitUntilExplicitReset() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("healthkit-anchor-reset-(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let url = root.appendingPathComponent("anchors.json")
        try Data("not-json".utf8).write(to: url)
        let store = HealthKitAnchorStore(persistenceURL: url, now: now)
        let initialLoadFailure = await store.hasLoadFailure()
        XCTAssertTrue(initialLoadFailure)
        do {
            _ = try await store.commit(metric: .water, observations: [], tombstones: [], sourceIndex: [:], nextAnchor: nil, syncState: .synced, committedAt: now)
            XCTFail("load failure must block commit")
        } catch { }
        do {
            _ = try await store.resetAfterLoadFailure()
        } catch {
            XCTFail("explicit reset should recover the store: \(error)")
        }
        let recovered = await store.hasLoadFailure()
        XCTAssertFalse(recovered)
        _ = try await store.commit(
            metric: .water,
            observations: [],
            tombstones: [],
            sourceIndex: [:],
            nextAnchor: nil,
            syncState: .synced,
            committedAt: now
        )
    }

    func testSourceIndexIsRebuiltFromObservationsAndRejectsInvalidKeys() async throws {
        let store = HealthKitAnchorStore(persistenceURL: nil)
        let sample = try observation()
        _ = try await store.commit(
            metric: .water,
            observations: [sample],
            tombstones: [],
            sourceIndex: ["com.example.source|unknown|unknown": .confirmed],
            nextAnchor: nil,
            syncState: .synced,
            committedAt: now
        )
        let state = await store.snapshot(for: .water)
        XCTAssertEqual(state.sourceIndex["com.example.source|unknown|unknown"], .other)
        do {
            _ = try await store.commit(metric: .water, observations: [sample], tombstones: [], sourceIndex: ["bad": .other], nextAnchor: nil, syncState: .synced, committedAt: now)
            XCTFail("invalid source key must fail closed")
        } catch { }
    }
}
