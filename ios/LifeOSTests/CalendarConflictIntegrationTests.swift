import XCTest
@testable import LifeOS

/// SY-05: "Calendar server ETag/If-Match conflict returns truth; bounded merge
/// retry, no blind PUT."
///
/// These tests drive the real `CalendarCoordinator` + `CalendarStore`
/// read/modify/write path against a stubbed remote transport that speaks the
/// exact `CalendarSyncError.calendarConflict` / `CalendarRemoteResource`
/// contract `TailscaleSyncClient` speaks in production. The coordinator is
/// constructed with its production `calendarRemoteFetch`/`calendarRemotePush`
/// test seams (see `CalendarCoordinator.init`) so the merge/retry/adoption
/// logic under test is the exact code that ships, not a reimplementation.
private actor PersistentConflictRemoteScript {
    struct Observation: Sendable {
        let fetchCount: Int
        let pushCount: Int
        let etagsSent: [String]
        let idempotencyKeys: [String]
    }

    private let initial: CalendarRemoteResource
    /// One distinct, freshly-encoded conflict resource per attempt so a test
    /// can prove the retry loop re-derives its guard from the LATEST
    /// authoritative body/etag rather than replaying a stale one.
    private let conflicts: [CalendarRemoteResource]
    private var fetchCount = 0
    private var pushCount = 0
    private var etagsSent: [String] = []
    private var idempotencyKeys: [String] = []

    init(initial: CalendarRemoteResource, conflicts: [CalendarRemoteResource]) {
        self.initial = initial
        self.conflicts = conflicts
    }

    func fetch() -> CalendarRemoteResource {
        fetchCount += 1
        return initial
    }

    /// Always rejects with a fresh, distinct conflict body/etag. Simulates a
    /// server that some other writer keeps mutating out from under this
    /// client -- the case bounded retry exists to give up on, honestly.
    func push(data: Data, etag: String, idempotencyKey: String) throws -> CalendarRemoteResource {
        etagsSent.append(etag)
        idempotencyKeys.append(idempotencyKey)
        let conflict = conflicts[min(pushCount, conflicts.count - 1)]
        pushCount += 1
        throw CalendarSyncError.calendarConflict(data: conflict.data, etag: conflict.etag)
    }

    func observation() -> Observation {
        Observation(fetchCount: fetchCount, pushCount: pushCount, etagsSent: etagsSent, idempotencyKeys: idempotencyKeys)
    }
}

/// A second script used only to prove the "conflict then recovers" happy
/// path preserves the server's independently-added item (a real merge, not a
/// blind overwrite) while also recording exactly which etag each attempt
/// carried, so a test can assert every attempt after the first used the
/// FRESH conflict etag rather than the original stale one.
private actor RecoveringConflictRemoteScript {
    struct Observation: Sendable {
        let etagsSent: [String]
        let pushCount: Int
    }

    let initial: CalendarRemoteResource
    let conflict: CalendarRemoteResource
    let success: CalendarRemoteResource
    private var pushCount = 0
    private var etagsSent: [String] = []

    init(initial: CalendarRemoteResource, conflict: CalendarRemoteResource, success: CalendarRemoteResource) {
        self.initial = initial
        self.conflict = conflict
        self.success = success
    }

    func fetch() -> CalendarRemoteResource { initial }

    func push(data: Data, etag: String, idempotencyKey: String) throws -> CalendarRemoteResource {
        etagsSent.append(etag)
        pushCount += 1
        if pushCount == 1 {
            throw CalendarSyncError.calendarConflict(data: conflict.data, etag: conflict.etag)
        }
        return success
    }

    func observation() -> Observation { Observation(etagsSent: etagsSent, pushCount: pushCount) }
}

@MainActor
final class CalendarConflictIntegrationTests: XCTestCase {
    private let base = Date(timeIntervalSince1970: 1_700_000_000)

    private func item(_ title: String, offset: TimeInterval) throws -> CalendarItem {
        try CalendarItem(
            title: title,
            start: base.addingTimeInterval(offset),
            end: base.addingTimeInterval(offset + 60),
            createdAt: base,
            updatedAt: base.addingTimeInterval(offset)
        )
    }

    private func makeDirectory() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
    }

    /// The load-bearing test for "bounded merge retry" and "a conflict
    /// returns truth, never a false success, never a silently lost local
    /// edit". A server that conflicts on every single attempt must cause
    /// `syncNow()` to make EXACTLY `maximumRemoteMutationAttempts` (3) push
    /// attempts -- not fewer (that would be giving up early) and not more
    /// (that would be the unbounded retry SY-05 forbids) -- report `.failure`
    /// (never `.success`), and leave the local durable edit intact on disk.
    func testPersistentConflictMakesExactlyThreeAttemptsReportsFailureAndPreservesLocalEdit() async throws {
        let directory = makeDirectory()
        let url = directory.appendingPathComponent("calendar.json")
        defer { try? FileManager.default.removeItem(at: directory) }

        let remote = try item("remote", offset: 0)
        let local = try item("local-edit-must-survive", offset: 240)
        let initialResource = CalendarRemoteResource(
            data: try JSONEncoder.calendar.encode(CalendarSnapshot(items: [remote])),
            etag: #""calendar-v1-initial"#
        )
        // Three distinct conflict bodies/etags: a real server would not keep
        // handing back the identical stale revision on every 412.
        let conflictResources = try (0..<5).map { index -> CalendarRemoteResource in
            CalendarRemoteResource(
                data: try JSONEncoder.calendar.encode(CalendarSnapshot(items: [remote])),
                etag: "\"calendar-v1-conflict-\(index)\""
            )
        }
        let script = PersistentConflictRemoteScript(initial: initialResource, conflicts: conflictResources)
        let coordinator = CalendarCoordinator(
            storeURL: url,
            calendarRemoteFetch: { await script.fetch() },
            calendarRemotePush: { data, etag, key in try await script.push(data: data, etag: etag, idempotencyKey: key) }
        )

        let localSaveResult = await coordinator.save(local)
        XCTAssertEqual(localSaveResult, .success)

        let syncResult = await coordinator.syncNow()
        guard case .failure(let message) = syncResult else {
            XCTFail("A persistently conflicting server must never be reported as a successful sync; got \(syncResult)")
            return
        }
        XCTAssertFalse(message.isEmpty)

        let observation = await script.observation()
        XCTAssertEqual(observation.pushCount, 3, "Retry must be bounded to exactly maximumRemoteMutationAttempts, no more and no fewer")
        XCTAssertEqual(observation.fetchCount, 1, "Only the initial GET re-reads; subsequent attempts re-derive their guard from the conflict response itself")
        XCTAssertEqual(Set(observation.idempotencyKeys).count, 1, "All bounded attempts must reuse the single idempotency key created for this sync operation")
        XCTAssertEqual(
            observation.etagsSent,
            [initialResource.etag, conflictResources[0].etag, conflictResources[1].etag],
            "Each retry must carry the etag from the MOST RECENT conflict response, never a stale replay of the original guard"
        )

        // The local edit must still be exactly present and untouched on disk.
        // Nothing in the failed remote path may have adopted, dropped, or
        // otherwise mutated it.
        let onDisk = try await coordinator.store.load()
        XCTAssertEqual(onDisk, CalendarSnapshot(items: [local]), "A persistent conflict must never blindly overwrite or silently drop the local edit")
        XCTAssertEqual(coordinator.snapshot, CalendarSnapshot(items: [local]))
        XCTAssertNotNil(coordinator.syncWarning, "A conflict that exhausts retries must be surfaced honestly, not swallowed")
    }

    /// Companion to the exhaustion test: proves the FIRST attempt of any
    /// sync is itself conditional (carries the etag from the read that
    /// preceded it), i.e. there is no code path where `syncNow()` issues a
    /// PUT before it has ever read a revision to guard against.
    func testFirstPushAttemptAlwaysCarriesTheEtagFromThePrecedingRead() async throws {
        let directory = makeDirectory()
        let url = directory.appendingPathComponent("calendar.json")
        defer { try? FileManager.default.removeItem(at: directory) }

        let remote = try item("remote", offset: 0)
        let local = try item("local", offset: 240)
        let initialResource = CalendarRemoteResource(
            data: try JSONEncoder.calendar.encode(CalendarSnapshot(items: [remote])),
            etag: #""calendar-v1-only-read"#
        )
        let script = PersistentConflictRemoteScript(initial: initialResource, conflicts: [initialResource])
        let coordinator = CalendarCoordinator(
            storeURL: url,
            calendarRemoteFetch: { await script.fetch() },
            calendarRemotePush: { data, etag, key in try await script.push(data: data, etag: etag, idempotencyKey: key) }
        )
        _ = await coordinator.save(local)
        _ = await coordinator.syncNow()

        let observation = await script.observation()
        XCTAssertEqual(observation.etagsSent.first, initialResource.etag, "The very first PUT must carry the etag this client actually read, never an empty/blind guard")
    }

    /// Recovery path: proves a mid-retry conflict is merged as server truth
    /// (the independently-added remote item survives) rather than the local
    /// candidate blindly clobbering it, AND that the retry that succeeds used
    /// the fresh conflict etag rather than the stale original.
    func testConflictThenRecoveryMergesServerTruthAndUsesFreshGuardOnRetry() async throws {
        let directory = makeDirectory()
        let url = directory.appendingPathComponent("calendar.json")
        defer { try? FileManager.default.removeItem(at: directory) }

        let remote = try item("remote", offset: 0)
        let remoteAddedDuringConflict = try item("added-by-someone-else", offset: 120)
        let local = try item("local", offset: 240)

        let initialResource = CalendarRemoteResource(
            data: try JSONEncoder.calendar.encode(CalendarSnapshot(items: [remote])),
            etag: #""calendar-v1-r1"#
        )
        let conflictResource = CalendarRemoteResource(
            data: try JSONEncoder.calendar.encode(CalendarSnapshot(items: [remote, remoteAddedDuringConflict])),
            etag: #""calendar-v1-r2"#
        )
        let successResource = CalendarRemoteResource(
            data: try JSONEncoder.calendar.encode(CalendarSnapshot(items: [remote, remoteAddedDuringConflict, local])),
            etag: #""calendar-v1-r3"#
        )
        let script = RecoveringConflictRemoteScript(initial: initialResource, conflict: conflictResource, success: successResource)
        let coordinator = CalendarCoordinator(
            storeURL: url,
            calendarRemoteFetch: { await script.fetch() },
            calendarRemotePush: { data, etag, key in try await script.push(data: data, etag: etag, idempotencyKey: key) }
        )

        _ = await coordinator.save(local)
        let syncResult = await coordinator.syncNow()
        XCTAssertEqual(syncResult, .success)

        let observation = await script.observation()
        XCTAssertEqual(observation.pushCount, 2)
        XCTAssertEqual(observation.etagsSent, [initialResource.etag, conflictResource.etag], "The second attempt must carry the FRESH conflict etag, not the stale initial one")

        let onDisk = try await coordinator.store.load()
        XCTAssertEqual(Set(onDisk.items.map(\.id)), Set([remote.id, remoteAddedDuringConflict.id, local.id]), "A recovered sync must contain the concurrently-added remote item, proving the write was a merge, not a blind overwrite")
    }
}
