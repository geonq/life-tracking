import XCTest
@testable import LifeOS

#if os(iOS) && canImport(HealthKit)
import HealthKit
#endif

/// HK-04 truth tests. These are new tests for gaps not covered by
/// `HealthKitReconciliationTests.swift` and `HealthKitAnchorStoreTests.swift`
/// (both already cover idempotency, deletion tombstoning, ambiguous-empty-read
/// non-fabrication, revision supersession across pages, cross-source
/// conflicts, unit rejection, and corrupt/missing anchor recovery).
///
/// This file focuses on:
///  - same-page (single anchored batch) revision supersession and
///    add+delete interactions, which the existing suite only exercises
///    across separate pages/reconciles
///  - a reported defect in the page-local `insertedCount` accounting
///  - exact-unit rejection at the reconciliation boundary (not just the
///    `HealthKitQuantityValue` initializer already covered in
///    `HealthKitDomainTests`)
final class HealthKitReconciliationTruthTests: XCTestCase {
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
        partial: Bool = false,
        quarantineDiagnostics: [HealthKitQuarantineDiagnostic] = []
    ) throws -> HealthKitMetricSyncInput {
        try HealthKitMetricSyncInput(
            metric: .water,
            additions: additions,
            deletions: deletions,
            nextAnchor: try testAnchor(anchorByte),
            observedAt: observedAt ?? now,
            partial: partial,
            quarantineDiagnostics: quarantineDiagnostics
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

    // MARK: - Defect: page-local insertedCount is corrupted by an unrelated deletion

    /// REAL DEFECT (reported before any fix): in `HealthKitReconciliationCoordinator.reconcilePage`,
    /// after the additions loop the code does:
    ///
    ///     let removed = observationIndex.matchingIndices(for: normalizedIdentity)
    ///         .filter { activeObservationIndices.remove($0) != nil }
    ///         .count
    ///     inserted = max(0, inserted - removed)
    ///
    /// This subtracts `removed` from the page's `inserted` counter for
    /// *every* deletion processed in the page, regardless of whether the
    /// removed observation was one of the additions just inserted in this
    /// same page. The intent (visible from the surrounding comment) is only
    /// to net out an add+delete of the *same* identity within one page.
    /// But when a page contains a genuinely new addition for identity B and,
    /// independently, a deletion of an unrelated pre-existing identity A
    /// (committed in an earlier page), `removed` counts A's removal and
    /// wrongly cancels out B's insertion in the reported `insertedCount`,
    /// even though B is durably present in the committed projection.
    ///
    /// This does not corrupt the durable `observations` array (B is present,
    /// A is gone) -- but it does make the truthfulness contract on the
    /// *reported* insertedCount false: a real insertion is invisibly
    /// swallowed by an unrelated deletion in the same page. Any caller that
    /// treats `insertedCount == 0` as "nothing new arrived this page" (e.g.
    /// to skip a UI refresh or a notification) would silently miss B.
    ///
    /// This test proves the discrepancy directly against the real
    /// production coordinator (no fix applied, per BOUNDARY: production
    /// changes require a defect to be reported first, which this test
    /// documents).
    func testUnrelatedDeletionDoesNotCancelThisPagesInsertCount() async throws {
        let existingUUID = UUID()
        let newUUID = UUID()
        let existing = try observation(uuid: existingUUID, value: 100)
        let deletion = try HealthKitDeletionTombstone(metric: .water, identity: .init(uuid: existingUUID), deletedAt: now)
        let newAddition = try observation(uuid: newUUID, value: 200)

        let client = SequenceHealthKitClient(batches: [
            try input(additions: [existing], anchorByte: 1),
            try input(additions: [newAddition], deletions: [deletion], anchorByte: 2),
        ])
        let store = HealthKitAnchorStore(persistenceURL: nil)
        let coordinator = HealthKitReconciliationCoordinator(client: client, store: store, now: { self.now })

        let firstResult = await coordinator.reconcile(metric: .water)
        XCTAssertEqual(firstResult.insertedCount, 1)

        let secondResult = await coordinator.reconcile(metric: .water)
        let state = await store.snapshot(for: .water)

        // Ground truth: the projection correctly contains only the new
        // observation and correctly drops the deleted one.
        XCTAssertEqual(state.observations.map(\.identity.uuid), [newUUID], "durable projection truth: unaffected by the reported count defect")
        XCTAssertEqual(secondResult.deletedCount, 1)

        // A genuinely new observation landed in this page, so the page must
        // report one insertion. The unrelated deletion in the same page
        // removes an observation committed by an EARLIER page and must not be
        // netted against it.
        XCTAssertEqual(
            secondResult.insertedCount, 1,
            "an unrelated deletion must not cancel an insertion attributed to this page"
        )
    }

    // MARK: - Same-page revision supersession (existing suite only tests cross-page)

    func testSamePageHigherRevisionSupersedesLowerRevisionWithoutDoubleCount() async throws {
        let oldUUID = UUID()
        let newUUID = UUID()
        let old = try observation(uuid: oldUUID, value: 250, syncIdentifier: "stable", revision: try .init(syncVersion: 1))
        let newer = try observation(uuid: newUUID, value: 400, syncIdentifier: "stable", revision: try .init(syncVersion: 2), aliases: [oldUUID])

        // Both revisions of the same logical sample arrive in a single
        // anchored page, in the "old first" order HealthKit could plausibly
        // return them in (insertion order, not revision order).
        let client = SequenceHealthKitClient(batches: [try input(additions: [old, newer])])
        let store = HealthKitAnchorStore(persistenceURL: nil)
        let coordinator = HealthKitReconciliationCoordinator(client: client, store: store, now: { self.now })

        let result = await coordinator.reconcile(metric: .water)
        let state = await store.snapshot(for: .water)

        // insertedCount tracks write events (the initial add, then the
        // in-page revision replacement), not the net document count -- the
        // same accumulation behavior the cross-page
        // testNewUUIDHigherSyncRevisionSupersedesLowerRevisionWithoutDoubleCount
        // exercises as two separate results. The property under test here
        // is durable non-duplication of the underlying document, asserted
        // below via state.observations.count.
        XCTAssertEqual(result.insertedCount, 2)
        XCTAssertEqual(state.observations.count, 1, "no double count within a single page")
        XCTAssertEqual(state.observations.first?.value, .quantity(try HealthKitQuantityValue(metric: .water, value: 400, unit: .milliliters)))
        XCTAssertTrue(state.observations.first?.identity.aliasUUIDs.contains(oldUUID) == true)
    }

    func testSamePageLowerRevisionAfterHigherRevisionDoesNotRegressValue() async throws {
        let oldUUID = UUID()
        let newUUID = UUID()
        // Reversed arrival order: the newer revision arrives first in the
        // page, then a stale replay of the older revision follows.
        let newer = try observation(uuid: newUUID, value: 400, syncIdentifier: "stable", revision: try .init(syncVersion: 2))
        let old = try observation(uuid: oldUUID, value: 250, syncIdentifier: "stable", revision: try .init(syncVersion: 1), aliases: [newUUID])

        let client = SequenceHealthKitClient(batches: [try input(additions: [newer, old])])
        let store = HealthKitAnchorStore(persistenceURL: nil)
        let coordinator = HealthKitReconciliationCoordinator(client: client, store: store, now: { self.now })

        let result = await coordinator.reconcile(metric: .water)
        let state = await store.snapshot(for: .water)

        XCTAssertEqual(state.observations.count, 1, "no double count regardless of in-page arrival order")
        XCTAssertEqual(
            state.observations.first?.value,
            .quantity(try HealthKitQuantityValue(metric: .water, value: 400, unit: .milliliters)),
            "the higher revision's value must win even when the stale replay arrives second in the same page"
        )
        XCTAssertEqual(result.duplicateCount, 1, "the stale in-page replay is counted as a duplicate, not a fresh insertion")
    }

    // MARK: - Same-page add-then-delete of the identical identity nets to nothing durable

    func testSamePageAdditionThenDeletionOfSameIdentityLeavesNoStaleObservation() async throws {
        let uuid = UUID()
        let sample = try observation(uuid: uuid, value: 250)
        let deletion = try HealthKitDeletionTombstone(metric: .water, identity: .init(uuid: uuid), deletedAt: now)

        let client = SequenceHealthKitClient(batches: [try input(additions: [sample], deletions: [deletion])])
        let store = HealthKitAnchorStore(persistenceURL: nil)
        let coordinator = HealthKitReconciliationCoordinator(client: client, store: store, now: { self.now })

        let result = await coordinator.reconcile(metric: .water)
        let state = await store.snapshot(for: .water)

        XCTAssertTrue(state.observations.isEmpty, "an add+delete of the same identity in one page must not leave a stale visible sample")
        XCTAssertEqual(result.deletedCount, 1)
        XCTAssertEqual(state.tombstones.count, 1)
    }

    // MARK: - Units: mismatched unit is rejected at the reconciliation boundary, never reinterpreted

    /// `HealthKitDomainTests.testCanonicalUnitsRejectWrongUnitNonFiniteAndNegativeValues`
    /// already proves `HealthKitQuantityValue.init` rejects a mismatched
    /// unit for a single value. This test proves the boundary one level up:
    /// `HealthKitMetricSyncInput.init` itself refuses to construct a batch
    /// whose declared `metric` does not match every addition/deletion's own
    /// metric (and therefore, transitively, unit) -- so a heart-rate sample
    /// (count-per-minute) can never be smuggled into a water (milliliters)
    /// batch and silently reinterpreted. This is a real construction-time
    /// throw, proven directly against the production initializer rather
    /// than assumed.
    func testMetricMismatchedAdditionIsRejectedNotReinterpreted() throws {
        let source = try HealthKitSourceMetadata(bundleIdentifier: "com.example.source", name: "com.example.source")
        let provenance = try HealthKitProvenance.from(source: source, device: nil, registry: .init(rules: []))
        let heartRateQuantity = try HealthKitQuantityValue(metric: .heartRate, value: 70, unit: .countPerMinute)
        let mismatched = try HealthKitObservation(
            metric: .heartRate,
            identity: .init(uuid: UUID()),
            value: .quantity(heartRateQuantity),
            startDate: now.addingTimeInterval(-60),
            endDate: now.addingTimeInterval(-60),
            provenance: provenance,
            now: now
        )

        XCTAssertThrowsError(try HealthKitMetricSyncInput(
            metric: .water,
            additions: [mismatched],
            deletions: [],
            nextAnchor: try testAnchor(1),
            observedAt: now
        )) { error in
            XCTAssertEqual(error as? HealthKitDomainError, .invalidQuantity, "a metric/unit-mismatched addition must fail closed at construction, never be coerced into the batch's declared metric")
        }
    }

    // MARK: - Denial vs empty must remain indistinguishable from a displayed zero

    func testReadAccessIndeterminateNeverCommitsAZeroProjectionOrAdvancesAnchor() async throws {
        let client = DenyingHealthKitClient()
        let store = HealthKitAnchorStore(persistenceURL: nil)
        let coordinator = HealthKitReconciliationCoordinator(client: client, store: store, now: { self.now })

        let result = await coordinator.reconcile(metric: .water)
        let state = await store.snapshot(for: .water)

        XCTAssertEqual(result.state, .error, "denial must surface as an explicit error state, never as a synced empty/zero result")
        XCTAssertNotEqual(result.state, .synced)
        XCTAssertNil(state.anchor, "denial must not durably advance the anchor as if a real read happened")
        XCTAssertTrue(state.observations.isEmpty)
        XCTAssertNotEqual(state.syncState, .synced)
    }
}

private actor SequenceHealthKitClient: HealthKitReconciliationClient {
    private var batches: [HealthKitMetricSyncInput]

    init(batches: [HealthKitMetricSyncInput] = []) {
        self.batches = batches
    }

    func changes(for metric: HealthKitMetricID, from anchor: HealthKitOpaqueAnchor?) async throws -> HealthKitMetricSyncInput {
        guard let next = batches.isEmpty ? nil : batches.removeFirst() else {
            throw HealthKitReconciliationFailure.client("No fake batch")
        }
        return next
    }
}

private actor DenyingHealthKitClient: HealthKitReconciliationClient {
    func changes(for metric: HealthKitMetricID, from anchor: HealthKitOpaqueAnchor?) async throws -> HealthKitMetricSyncInput {
        throw HealthKitAdapterError.readAccessIndeterminate
    }
}
