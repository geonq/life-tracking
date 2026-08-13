#if os(iOS)
import XCTest
@testable import LifeOS

@MainActor
final class HealthKitFitnessRepositoryTests: XCTestCase {
    private let now = Date(timeIntervalSinceReferenceDate: 1_000_000)

    func testReaderReceivesExactSupportedSetWithoutAlcohol() async {
        var requested: [HealthKitMetricID] = []
        let repository = HealthKitFitnessRepository(testStateReader: { metrics in
            requested = metrics
            return metrics.map(HealthKitStoredMetricState.empty(for:))
        }, now: { self.now })

        await repository.refresh()

        XCTAssertEqual(requested, HealthKitIntegrationController.supportedMetrics)
        XCTAssertFalse(requested.contains(.alcoholicBeverages))
        XCTAssertNotNil(repository.projection)
    }

    func testMissingClientNeverReadsAndRemainsUnavailable() async {
        let repository = HealthKitFitnessRepository(client: nil)

        await repository.refresh()

        XCTAssertNil(repository.projection)
    }

    func testFixtureModeNeverReadsEvenWhenTestReaderIsPresent() async {
        var reads = 0
        let repository = HealthKitFitnessRepository(
            testStateReader: { _ in
                reads += 1
                return []
            },
            usesVisualFixtures: true
        )

        await repository.refresh()

        XCTAssertEqual(reads, 0)
        XCTAssertNil(repository.projection)
    }

    func testStoredStateTruthPassesThroughProjection() async {
        let states = [
            storedState(metric: .restingHeartRate, syncState: .partial),
            storedState(metric: .steps, syncState: .readIndeterminate),
            storedState(metric: .bodyMass, syncState: .stale),
            conflictedState(metric: .activeEnergy),
            storedState(metric: .vo2Max, syncState: .error)
        ]
        let repository = HealthKitFitnessRepository(
            testStateReader: { _ in states },
            now: { self.now }
        )

        await repository.refresh()

        guard let projection = try? XCTUnwrap(repository.projection) else { return }
        XCTAssertEqual(projection.metric(.restingHeartRate).state, .partial)
        XCTAssertEqual(projection.metric(.steps).state, .readIndeterminate)
        XCTAssertEqual(projection.metric(.bodyMass).state, .stale)
        XCTAssertEqual(projection.metric(.activeEnergy).state, .conflict)
        XCTAssertEqual(projection.metric(.vo2Max).state, .error)
    }

    func testProjectionWindowIsBoundedAndRetainsCalendarTimeZone() async throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try XCTUnwrap(TimeZone(identifier: "Europe/Berlin"))
        let quantity = try HealthKitQuantityValue(metric: .steps, value: 7, unit: .count)
        let source = try HealthKitSourceMetadata(bundleIdentifier: "com.example.health", name: "Health")
        let provenance = try HealthKitProvenance.from(
            source: source,
            device: try HealthKitDeviceMetadata(),
            registry: .canonical
        )
        let observation = try HealthKitObservation(
            metric: .steps,
            identity: HealthKitSampleIdentity(uuid: UUID()),
            value: .quantity(quantity),
            startDate: now,
            endDate: now,
            provenance: provenance,
            now: now
        )
        let state = HealthKitStoredMetricState(projection: try HealthKitMetricProjection(
            metric: .steps,
            observations: [observation],
            lastCommittedAt: now,
            syncState: .synced
        ))
        let repository = HealthKitFitnessRepository(
            testStateReader: { _ in [state] },
            calendar: calendar,
            now: { self.now }
        )

        await repository.refresh()

        let projection = try XCTUnwrap(repository.projection)
        XCTAssertEqual(projection.bucketCalendarIdentifier, calendar.identifier)
        XCTAssertEqual(projection.bucketTimeZoneIdentifier, calendar.timeZone.identifier)
        XCTAssertEqual(projection.windowEnd, now.addingTimeInterval(1))
        XCTAssertGreaterThan(projection.windowEnd, now)
        XCTAssertLessThanOrEqual(projection.dailyTotals.count, 367)
        XCTAssertEqual(projection.dailyTotal(for: .steps, on: now)?.total?.value, 7)
        XCTAssertGreaterThan(projection.windowStart, now.addingTimeInterval(-HealthKitFitnessProjection.maximumWindow - 1))
        XCTAssertLessThanOrEqual(projection.windowEnd.timeIntervalSince(projection.windowStart), HealthKitFitnessProjection.maximumWindow)
    }

    func testOlderOverlappingRefreshCannotOverwriteNewerProjection() async {
        let gate = ReadGate()
        let older = [storedState(metric: .bodyMass, syncState: .partial)]
        let newer = [storedState(metric: .bodyMass, syncState: .error)]
        let repository = HealthKitFitnessRepository(
            testStateReader: { metrics in await gate.read(metrics) },
            now: { self.now }
        )

        let first = Task { @MainActor in await repository.refresh() }
        await waitUntil { await gate.count == 1 }
        let second = Task { @MainActor in await repository.refresh() }
        await waitUntil { await gate.count == 2 }

        await gate.resume(position: 1, states: newer)
        await second.value
        XCTAssertEqual(repository.projection?.metric(.bodyMass).state, .error)

        await gate.resume(position: 0, states: older)
        await first.value
        XCTAssertEqual(repository.projection?.metric(.bodyMass).state, .error)
    }

    private func storedState(
        metric: HealthKitMetricID,
        syncState: HealthKitSyncState
    ) -> HealthKitStoredMetricState {
        let projection = try! HealthKitMetricProjection(
            metric: metric,
            lastCommittedAt: now,
            syncState: syncState
        )
        return HealthKitStoredMetricState(projection: projection)
    }

    private func conflictedState(metric: HealthKitMetricID) -> HealthKitStoredMetricState {
        let identity = HealthKitSampleIdentity(uuid: UUID())
        let source = try! HealthKitSourceMetadata(bundleIdentifier: "com.example.health", name: "Health")
        let provenance = try! HealthKitProvenance.from(
            source: source,
            device: try! HealthKitDeviceMetadata(),
            registry: .canonical
        )
        let existing = try! HealthKitObservation(
            metric: metric,
            identity: identity,
            value: .quantity(try! HealthKitQuantityValue(metric: metric, value: 100, unit: metric.canonicalUnit!)),
            startDate: now,
            endDate: now,
            provenance: provenance,
            now: now
        )
        let incoming = try! HealthKitObservation(
            metric: metric,
            identity: identity,
            value: .quantity(try! HealthKitQuantityValue(metric: metric, value: 101, unit: metric.canonicalUnit!)),
            startDate: now,
            endDate: now,
            provenance: provenance,
            now: now
        )
        let conflict = HealthKitObservationConflict(
            metric: metric,
            identity: identity,
            existing: existing,
            incoming: incoming
        )
        let projection = try! HealthKitMetricProjection(
            metric: metric,
            observations: [existing],
            conflicts: [conflict],
            lastCommittedAt: now,
            syncState: .synced
        )
        return HealthKitStoredMetricState(projection: projection)
    }

    private func waitUntil(
        _ predicate: @escaping () async -> Bool,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async {
        for _ in 0..<100 {
            if await predicate() { return }
            await Task.yield()
        }
        XCTFail("Timed out waiting for condition", file: file, line: line)
    }
}

private actor ReadGate {
    private var pending: [CheckedContinuation<[HealthKitStoredMetricState], Never>] = []

    var count: Int { pending.count }

    func read(_ metrics: [HealthKitMetricID]) async -> [HealthKitStoredMetricState] {
        await withCheckedContinuation { continuation in
            pending.append(continuation)
        }
    }

    func resume(position: Int, states: [HealthKitStoredMetricState]) {
        let continuation = pending.remove(at: position)
        continuation.resume(returning: states)
    }
}
#endif
