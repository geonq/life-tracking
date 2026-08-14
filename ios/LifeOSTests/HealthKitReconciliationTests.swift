import XCTest
@testable import LifeOS

#if os(iOS) && canImport(HealthKit)
import HealthKit
#endif

final class HealthKitReconciliationTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_700_000_000)

    private func observation(
        uuid: UUID,
        value: Double = 250,
        bundle: String = "com.example.source",
        at: Date? = nil,
        syncIdentifier: String? = nil,
        revision: HealthKitSampleRevision = .uuidFallback,
        aliases: [UUID] = []
    ) throws -> HealthKitObservation {
        let source = try HealthKitSourceMetadata(bundleIdentifier: bundle, name: bundle)
        let provenance = try HealthKitProvenance.from(source: source, device: nil, registry: .init(rules: []))
        let quantity = try HealthKitQuantityValue(metric: .water, value: value, unit: .milliliters)
        let date = at ?? now.addingTimeInterval(-60)
        return try HealthKitObservation(
            metric: .water,
            identity: .init(uuid: uuid, syncIdentifier: syncIdentifier, aliases: aliases, revision: revision),
            value: .quantity(quantity),
            startDate: date,
            endDate: date,
            provenance: provenance,
            now: now
        )
    }

    private func input(
        additions: [HealthKitObservation],
        deletions: [HealthKitDeletionTombstone] = [],
        anchorByte: UInt8 = 1,
        observedAt: Date? = nil,
        partial: Bool = false
    ) throws -> HealthKitMetricSyncInput {
        try HealthKitMetricSyncInput(
            metric: .water,
            additions: additions,
            deletions: deletions,
            nextAnchor: try testAnchor(anchorByte),
            observedAt: observedAt ?? now,
            partial: partial
        )
    }

    private func testAnchor(_ byte: UInt8) throws -> HealthKitOpaqueAnchor {
#if os(iOS) && canImport(HealthKit)
        let value = HKQueryAnchor(fromValue: Int(byte))
        return try HealthKitOpaqueAnchor(archivedData: NSKeyedArchiver.archivedData(withRootObject: value, requiringSecureCoding: true))
#else
        return try HealthKitOpaqueAnchor(archivedData: Data([byte]))
#endif
    }

    func testRepeatedAnchoredBatchIsIdempotent() async throws {
        let uuid = UUID()
        let batch = try input(additions: [observation(uuid: uuid)])
        let client = SequenceHealthKitClient(batches: [batch, batch])
        let store = HealthKitAnchorStore(persistenceURL: nil)
        let coordinator = HealthKitReconciliationCoordinator(client: client, store: store, now: { self.now })

        let first = await coordinator.reconcile(metric: .water)
        let second = await coordinator.reconcile(metric: .water)
        XCTAssertEqual(first.insertedCount, 1)
        XCTAssertEqual(second.insertedCount, 0)
        XCTAssertEqual(second.duplicateCount, 1)
        let state = await store.snapshot(for: .water)
        XCTAssertEqual(state.observations.count, 1)
    }

    func testDeletionCreatesTombstoneAndRemovesAllRevisionsForUUID() async throws {
        let uuid = UUID()
        let first = try observation(uuid: uuid)
        let deletion = try HealthKitDeletionTombstone(metric: .water, identity: .init(uuid: uuid), deletedAt: now)
        let client = SequenceHealthKitClient(batches: [try input(additions: [first]), try input(additions: [], deletions: [deletion], anchorByte: 2)])
        let store = HealthKitAnchorStore(persistenceURL: nil)
        let coordinator = HealthKitReconciliationCoordinator(client: client, store: store, now: { self.now })
        _ = await coordinator.reconcile(metric: .water)
        let result = await coordinator.reconcile(metric: .water)
        let state = await store.snapshot(for: .water)
        XCTAssertEqual(result.deletedCount, 1)
        XCTAssertTrue(state.observations.isEmpty)
        XCTAssertEqual(state.tombstones, [deletion])
    }

    func testFirstAmbiguousEmptyReadDoesNotClaimSyncedOrAdvanceAnchor() async throws {
        let client = SequenceHealthKitClient(batches: [
            try HealthKitMetricSyncInput(
                metric: .water,
                additions: [],
                deletions: [],
                nextAnchor: try testAnchor(9),
                observedAt: now,
                readability: .emptyIndeterminate
            )
        ])
        let store = HealthKitAnchorStore(persistenceURL: nil)
        let coordinator = HealthKitReconciliationCoordinator(client: client, store: store, now: { self.now })

        let result = await coordinator.reconcile(metric: .water)
        let state = await store.snapshot(for: .water)
        XCTAssertEqual(result.state, .readIndeterminate)
        XCTAssertEqual(state.syncState, .readIndeterminate)
        XCTAssertNil(state.anchor, "an ambiguous first read must not persist its candidate anchor")
        XCTAssertTrue(state.observations.isEmpty)
    }

    func testEstablishedEmptyReadAfterObservedDataCanPersistAnchorAndRemainNonZero() async throws {
        let sample = try observation(uuid: UUID(), value: 250)
        let client = SequenceHealthKitClient(batches: [
            try input(additions: [sample], anchorByte: 1),
            try HealthKitMetricSyncInput(
                metric: .water,
                additions: [],
                deletions: [],
                nextAnchor: try testAnchor(2),
                observedAt: now,
                readability: .established
            )
        ])
        let store = HealthKitAnchorStore(persistenceURL: nil)
        let coordinator = HealthKitReconciliationCoordinator(client: client, store: store, now: { self.now })
        _ = await coordinator.reconcile(metric: .water)
        let result = await coordinator.reconcile(metric: .water)
        let state = await store.snapshot(for: .water)
        XCTAssertEqual(result.state, .synced)
        XCTAssertEqual(state.observations.count, 1)
        XCTAssertEqual(state.observations.first?.value, .quantity(try HealthKitQuantityValue(metric: .water, value: 250, unit: .milliliters)))
        XCTAssertEqual(state.anchor, try testAnchor(2))
    }

    func testNewUUIDHigherSyncRevisionSupersedesLowerRevisionWithoutDoubleCount() async throws {
        let oldUUID = UUID()
        let newUUID = UUID()
        let old = try observation(uuid: oldUUID, value: 250, syncIdentifier: "stable", revision: try .init(syncVersion: 1))
        let newer = try observation(uuid: newUUID, value: 400, syncIdentifier: "stable", revision: try .init(syncVersion: 2), aliases: [oldUUID])
        let replay = try observation(uuid: oldUUID, value: 250, syncIdentifier: "stable", revision: try .init(syncVersion: 1))
        let client = SequenceHealthKitClient(batches: [try input(additions: [old]), try input(additions: [newer]), try input(additions: [replay])])
        let store = HealthKitAnchorStore(persistenceURL: nil)
        let coordinator = HealthKitReconciliationCoordinator(client: client, store: store, now: { self.now })

        let firstResult = await coordinator.reconcile(metric: .water)
        XCTAssertEqual(firstResult.insertedCount, 1)
        let replacementResult = await coordinator.reconcile(metric: .water)
        XCTAssertEqual(replacementResult.insertedCount, 1)
        let replayResult = await coordinator.reconcile(metric: .water)
        XCTAssertEqual(replayResult.duplicateCount, 1)
        let state = await store.snapshot(for: .water)
        XCTAssertEqual(state.observations.count, 1)
        XCTAssertEqual(state.observations.first?.value, .quantity(try HealthKitQuantityValue(metric: .water, value: 400, unit: .milliliters)))
        XCTAssertTrue(state.observations.first?.identity.aliasUUIDs.contains(oldUUID) == true)
    }

    func testDeletionOfOldUUIDAliasRemovesSupersedingRevision() async throws {
        let oldUUID = UUID()
        let newUUID = UUID()
        let old = try observation(uuid: oldUUID, syncIdentifier: "stable", revision: try .init(syncVersion: 1))
        let newer = try observation(uuid: newUUID, value: 400, syncIdentifier: "stable", revision: try .init(syncVersion: 2), aliases: [oldUUID])
        let deletion = try HealthKitDeletionTombstone(metric: .water, identity: .init(uuid: oldUUID), deletedAt: now)
        let client = SequenceHealthKitClient(batches: [try input(additions: [old]), try input(additions: [newer]), try input(additions: [], deletions: [deletion], anchorByte: 3)])
        let store = HealthKitAnchorStore(persistenceURL: nil)
        let coordinator = HealthKitReconciliationCoordinator(client: client, store: store, now: { self.now })
        _ = await coordinator.reconcile(metric: .water)
        _ = await coordinator.reconcile(metric: .water)
        let result = await coordinator.reconcile(metric: .water)
        let state = await store.snapshot(for: .water)
        XCTAssertEqual(result.deletedCount, 1)
        XCTAssertTrue(state.observations.isEmpty)
        XCTAssertTrue(state.tombstones.first?.identity.aliasUUIDs.contains(newUUID) == true)
        XCTAssertTrue(state.sourceIndex.isEmpty, "deleting the only observation removes stale source evidence")
    }

    func testTombstoneAliasesSuppressLateReplay() async throws {
        let uuid = UUID()
        let sample = try observation(uuid: uuid, syncIdentifier: "stable", revision: try .init(syncVersion: 1))
        let deletion = try HealthKitDeletionTombstone(metric: .water, identity: .init(uuid: uuid), deletedAt: now)
        let client = SequenceHealthKitClient(batches: [
            try input(additions: [sample]),
            try input(additions: [], deletions: [deletion], anchorByte: 2),
            try input(additions: [sample], anchorByte: 3)
        ])
        let store = HealthKitAnchorStore(persistenceURL: nil)
        let coordinator = HealthKitReconciliationCoordinator(client: client, store: store, now: { self.now })
        _ = await coordinator.reconcile(metric: .water)
        _ = await coordinator.reconcile(metric: .water)
        let replayResult = await coordinator.reconcile(metric: .water)
        let state = await store.snapshot(for: .water)
        XCTAssertEqual(replayResult.insertedCount, 0)
        XCTAssertEqual(replayResult.duplicateCount, 1)
        XCTAssertTrue(state.observations.isEmpty)
    }

    func testDuplicateIdentityWithDifferentSourceIsConflictAndDoesNotAdvanceNewAnchor() async throws {
        let uuid = UUID()
        let existing = try observation(uuid: uuid, value: 250, bundle: "com.example.a")
        let incoming = try observation(uuid: uuid, value: 400, bundle: "com.example.b")
        let client = SequenceHealthKitClient(batches: [try input(additions: [existing], anchorByte: 1), try input(additions: [incoming], anchorByte: 2)])
        let store = HealthKitAnchorStore(persistenceURL: nil)
        let coordinator = HealthKitReconciliationCoordinator(client: client, store: store, now: { self.now })

        _ = await coordinator.reconcile(metric: .water)
        let result = await coordinator.reconcile(metric: .water)
        let state = await store.snapshot(for: .water)
        XCTAssertEqual(result.state, .conflict)
        XCTAssertEqual(result.conflictCount, 1)
        XCTAssertEqual(state.conflicts.count, 1)
        XCTAssertEqual(state.anchor, try testAnchor(1))
        XCTAssertEqual(state.observations, [existing])
    }

    func testSameUUIDWithDifferentSyncIdentifierIsConflict() async throws {
        let uuid = UUID()
        let existing = try observation(uuid: uuid, value: 250, syncIdentifier: "provider-a", revision: .syncVersion(1))
        let incoming = try observation(uuid: uuid, value: 400, syncIdentifier: "provider-b", revision: .syncVersion(2))
        let client = SequenceHealthKitClient(batches: [try input(additions: [existing], anchorByte: 1), try input(additions: [incoming], anchorByte: 2)])
        let store = HealthKitAnchorStore(persistenceURL: nil)
        let coordinator = HealthKitReconciliationCoordinator(client: client, store: store, now: { self.now })

        _ = await coordinator.reconcile(metric: .water)
        let result = await coordinator.reconcile(metric: .water)
        let state = await store.snapshot(for: .water)
        XCTAssertEqual(result.state, .conflict)
        XCTAssertEqual(result.conflictCount, 1)
        XCTAssertEqual(state.anchor, try testAnchor(1))
    }

    func testPartialAndStaleStatesRemainExplicit() async throws {
        let partial = try input(additions: [observation(uuid: UUID())], partial: true)
        let stale = try input(additions: [], anchorByte: 2, observedAt: now.addingTimeInterval(-60 * 60))
        let client = SequenceHealthKitClient(batches: [partial, stale])
        let store = HealthKitAnchorStore(persistenceURL: nil)
        let coordinator = HealthKitReconciliationCoordinator(client: client, store: store, now: { self.now })
        let partialResult = await coordinator.reconcilePage(metric: .water)
        let partialState = await store.snapshot(for: .water)
        let staleResult = await coordinator.reconcilePage(metric: .water)
        XCTAssertEqual(partialResult.state, .partial)
        XCTAssertEqual(partialState.anchor, try testAnchor(1))
        XCTAssertEqual(staleResult.state, .stale)
    }

    func testMetricsReconciliationDrainsPartialPagesBeforeReporting() async throws {
        let first = try observation(uuid: UUID(), value: 250)
        let second = try observation(uuid: UUID(), value: 400)
        let client = SequenceHealthKitClient(batches: [
            try input(additions: [first], anchorByte: 1, partial: true),
            try input(additions: [second], anchorByte: 2)
        ])
        let store = HealthKitAnchorStore(persistenceURL: nil)
        let coordinator = HealthKitReconciliationCoordinator(client: client, store: store, now: { self.now })

        let report = await coordinator.reconcile(metrics: [.water])
        let state = await store.snapshot(for: .water)
        let callCount = await client.callCount

        XCTAssertEqual(report.results.map(\.state), [.synced])
        XCTAssertEqual(callCount, 2)
        XCTAssertEqual(state.observations.count, 2)
        XCTAssertEqual(state.anchor, try testAnchor(2))
    }

    func testSingleMetricReconciliationDrainsPartialPagesBeforeObserverCompletion() async throws {
        let first = try observation(uuid: UUID(), value: 250)
        let second = try observation(uuid: UUID(), value: 400)
        let client = SequenceHealthKitClient(batches: [
            try input(additions: [first], anchorByte: 1, partial: true),
            try input(additions: [second], anchorByte: 2)
        ])
        let store = HealthKitAnchorStore(persistenceURL: nil)
        let coordinator = HealthKitReconciliationCoordinator(client: client, store: store, now: { self.now })

        let result = await coordinator.reconcile(metric: .water)
        let state = await store.snapshot(for: .water)
        let callCount = await client.callCount

        XCTAssertEqual(result.state, .synced)
        XCTAssertEqual(callCount, 2)
        XCTAssertEqual(state.observations.count, 2)
        XCTAssertEqual(state.anchor, try testAnchor(2))
    }

    func testInitialReconciliationConsumesOnlyOneBoundedPage() async throws {
        let firstPage = try input(
            additions: (0..<4_000).map { index in
                try observation(uuid: UUID(uuidString: String(format: "00000000-0000-0000-0000-%012d", index))!, value: Double(index + 1))
            },
            anchorByte: 1,
            partial: true
        )
        let secondPage = try input(additions: [observation(uuid: UUID())], anchorByte: 2)
        let client = SequenceHealthKitClient(batches: [firstPage, secondPage])
        let store = HealthKitAnchorStore(persistenceURL: nil)
        let coordinator = HealthKitReconciliationCoordinator(client: client, store: store, now: { self.now })

        let report = await coordinator.reconcileInitialPages(metrics: [.water])
        let state = await store.snapshot(for: .water)
        let callCount = await client.callCount

        XCTAssertEqual(report.results.map(\.state), [.partial])
        XCTAssertEqual(callCount, 1)
        XCTAssertEqual(state.observations.count, 4_000)
        XCTAssertEqual(state.anchor, try testAnchor(1))
    }

    func testFutureBatchIsRejectedWithoutChangingProjection() async throws {
        // The observation constructor rejects a future sample itself. A client
        // can still return a future batch timestamp, which reconciliation also
        // rejects before committing it.
        XCTAssertThrowsError(try observation(uuid: UUID(), at: now.addingTimeInterval(60)))
        let valid = try observation(uuid: UUID())
        let futureBatch = try input(additions: [valid], observedAt: now.addingTimeInterval(60))
        let client = SequenceHealthKitClient(batches: [futureBatch])
        let store = HealthKitAnchorStore(persistenceURL: nil)
        let coordinator = HealthKitReconciliationCoordinator(client: client, store: store, now: { self.now })
        let result = await coordinator.reconcile(metric: .water)
        XCTAssertEqual(result.state, .error)
        let state = await store.snapshot(for: .water)
        XCTAssertTrue(state.observations.isEmpty)
    }

    func testFutureTombstoneIsRejectedAtCoordinatorClock() async throws {
        let deletion = try HealthKitDeletionTombstone(
            metric: .water,
            identity: .init(uuid: UUID()),
            deletedAt: now.addingTimeInterval(60)
        )
        let client = SequenceHealthKitClient(batches: [try input(additions: [], deletions: [deletion])])
        let store = HealthKitAnchorStore(persistenceURL: nil)
        let coordinator = HealthKitReconciliationCoordinator(client: client, store: store, now: { self.now })
        let result = await coordinator.reconcile(metric: .water)
        XCTAssertEqual(result.state, .error)
        XCTAssertTrue(result.errorDescription?.contains("future") == true)
        let state = await store.snapshot(for: .water)
        XCTAssertTrue(state.tombstones.isEmpty)
    }

    func testTimeoutConfigurationIsFiniteAndCapped() {
        XCTAssertEqual(HealthKitReconciliationCoordinator.normalizedTimeout(.infinity), 30)
        XCTAssertEqual(HealthKitReconciliationCoordinator.normalizedTimeout(.greatestFiniteMagnitude), 300)
        XCTAssertEqual(HealthKitReconciliationCoordinator.normalizedTimeout(-1), 0.1)
    }

    func testConcurrentReconcilesCannotOverwriteANewerMetricProjection() async throws {
        let first = try observation(uuid: UUID(), value: 250)
        let second = try observation(uuid: UUID(), value: 400)
        let client = SequenceHealthKitClient(batches: [try input(additions: [first]), try input(additions: [second])], delayNanoseconds: 20_000_000)
        let store = HealthKitAnchorStore(persistenceURL: nil)
        let coordinator = HealthKitReconciliationCoordinator(client: client, store: store, now: { self.now })

        async let firstResult = coordinator.reconcile(metric: .water)
        async let secondResult = coordinator.reconcile(metric: .water)
        let results = await [firstResult, secondResult]
        let state = await store.snapshot(for: .water)
        XCTAssertEqual(state.observations.count, 1)
        XCTAssertTrue(results.contains(where: { $0.completion != .success }))
    }

    func testObserverCompletionGateCallsHealthKitCompletionExactlyOnce() {
        let gate = HealthKitObserverCompletionGate(timeout: 1)
        var completionCount = 0
        var reports: [HealthKitObserverCompletion] = []
        let first = gate.finish(.success, completion: { completionCount += 1 }, report: { reports.append($0) })
        let second = gate.finish(.timedOut, completion: { completionCount += 1 }, report: { reports.append($0) })
        XCTAssertTrue(first)
        XCTAssertFalse(second)
        XCTAssertEqual(completionCount, 1)
        XCTAssertEqual(reports, [.success])
    }

    func testReconciliationTimeoutProducesBoundedCompletion() async throws {
        let client = SequenceHealthKitClient(delayNanoseconds: 300_000_000)
        let store = HealthKitAnchorStore(persistenceURL: nil)
        let coordinator = HealthKitReconciliationCoordinator(client: client, store: store, timeout: 0.05, now: { self.now })
        let result = await coordinator.reconcile(metric: .water)
        XCTAssertEqual(result.state, .error)
        XCTAssertEqual(result.completion, .timedOut)
        let state = await store.snapshot(for: .water)
        XCTAssertTrue(state.observations.isEmpty)
    }

    func testInvalidAnchorDurablyRequestsFullResyncWithoutDiscardingProjection() async throws {
        let store = HealthKitAnchorStore(persistenceURL: nil)
        let coordinator = HealthKitReconciliationCoordinator(client: InvalidAnchorHealthKitClient(), store: store, now: { self.now })
        let result = await coordinator.reconcile(metric: .water)
        XCTAssertEqual(result.state, .fullResyncRequired)
        let state = await store.snapshot(for: .water)
        XCTAssertEqual(state.syncState, .fullResyncRequired)
        XCTAssertNil(state.anchor)
    }
}

private actor SequenceHealthKitClient: HealthKitReconciliationClient {
    private var batches: [HealthKitMetricSyncInput]
    private let delayNanoseconds: UInt64
    private(set) var callCount = 0

    init(batches: [HealthKitMetricSyncInput] = [], delayNanoseconds: UInt64 = 0) {
        self.batches = batches
        self.delayNanoseconds = delayNanoseconds
    }

    func changes(for metric: HealthKitMetricID, from anchor: HealthKitOpaqueAnchor?) async throws -> HealthKitMetricSyncInput {
        callCount += 1
        if delayNanoseconds > 0 { try await Task.sleep(nanoseconds: delayNanoseconds) }
        guard let next = batches.isEmpty ? nil : batches.removeFirst() else {
            throw HealthKitReconciliationFailure.client("No fake batch")
        }
        return next
    }
}

private actor InvalidAnchorHealthKitClient: HealthKitReconciliationClient {
    func changes(for metric: HealthKitMetricID, from anchor: HealthKitOpaqueAnchor?) async throws -> HealthKitMetricSyncInput {
        throw HealthKitAdapterError.invalidAnchor
    }
}
