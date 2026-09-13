import Foundation
import XCTest
@testable import LifeOS

final class SupplementStoreTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_786_449_600)

    private func temporaryURL() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("lifeos-supplement-store-\(UUID().uuidString)", isDirectory: true)
            .appendingPathComponent("supplements-v1.json", isDirectory: false)
    }

    private func record(
        id: String = "magnesium",
        stock: Int = 10,
        timing: String = "11:30",
        expiryDate: Date? = Date(timeIntervalSince1970: 1_791_633_600)
    ) -> FitnessSupplement {
        FitnessSupplement(
            id: id,
            name: "Magnesium",
            brand: "User-entered product",
            form: .capsule,
            strength: "200 mg",
            servingUnit: "capsule",
            userDose: "2 capsules",
            inventoryUnitsPerDose: 2,
            timing: timing,
            timeZoneIdentifier: "Europe/Berlin",
            scheduledDays: Set(1...7),
            stockUnits: stock,
            reorderThreshold: 2,
            expectedLeadTimeDays: 7,
            expiryDate: expiryDate,
            supplier: "Local pharmacy"
        )
    }

    private func session(
        store: SupplementStore,
        records: [FitnessSupplement]? = nil,
        selectedDate: Date? = nil,
        now: Date? = nil
    ) throws -> FitnessSupplementSession {
        try FitnessSupplementSession(
            supplements: records ?? [self.record()],
            selectedDate: selectedDate ?? self.now,
            store: store,
            now: now ?? self.now
        )
    }

    private func removeStore(at url: URL) {
        try? FileManager.default.removeItem(at: url.deletingLastPathComponent())
    }

    func testRoundTripReopenAndExactReplayPreservesTakenReceipt() throws {
        let url = temporaryURL()
        defer { removeStore(at: url) }
        let store = try SupplementStore(url: url)
        var firstSession = try session(store: store)

        let first = try firstSession.apply(
            .taken,
            to: "magnesium",
            actionID: "taken-reopen-1",
            occurredAt: now,
            now: now
        )
        XCTAssertFalse(first.idempotent)
        XCTAssertEqual(firstSession.stock(for: "magnesium"), 8)
        XCTAssertEqual(firstSession.actionReceipts.map(\.actionID), ["taken-reopen-1"])

        let reopenedStore = try SupplementStore(url: url)
        var reopened = try session(store: reopenedStore, records: [])
        XCTAssertEqual(reopened.stock(for: "magnesium"), 8)
        XCTAssertEqual(reopened.plan(for: "magnesium")?.expiryDate, record().expiryDate)
        XCTAssertEqual(reopened.state(for: "magnesium"), .taken)
        XCTAssertEqual(reopened.selectedLocalDate, "2026-08-11")
        XCTAssertEqual(reopened.selectedWeekday, 3)
        XCTAssertEqual(
            reopened.occurrence(for: "magnesium")?.scheduledFor,
            firstSession.occurrence(for: "magnesium")?.scheduledFor
        )

        let replay = try reopened.apply(
            .taken,
            to: "magnesium",
            actionID: "taken-reopen-1",
            occurredAt: now,
            now: now
        )
        XCTAssertTrue(replay.idempotent)
        XCTAssertEqual(replay.inventoryDelta, 0)
        XCTAssertEqual(reopened.stock(for: "magnesium"), 8)
        XCTAssertEqual(reopened.snapshot.inventoryEvents.count, 1)
    }

    func testEmptyStockTakenIsDurableAndExactReplayStaysAtZero() throws {
        let url = temporaryURL()
        defer { removeStore(at: url) }
        var first = try session(store: try SupplementStore(url: url), records: [record(stock: 0)])

        let firstResult = try first.apply(
            .taken,
            to: "magnesium",
            actionID: "taken-empty-1",
            occurredAt: now,
            now: now
        )
        XCTAssertEqual(firstResult.inventoryDelta, 0)
        XCTAssertEqual(first.stock(for: "magnesium"), 0)
        XCTAssertTrue(first.snapshot.inventoryEvents.isEmpty)

        var reopened = try session(
            store: try SupplementStore(url: url),
            records: []
        )
        let replay = try reopened.apply(
            .taken,
            to: "magnesium",
            actionID: "taken-empty-1",
            occurredAt: now,
            now: now
        )
        XCTAssertTrue(replay.idempotent)
        XCTAssertEqual(reopened.stock(for: "magnesium"), 0)
        XCTAssertTrue(reopened.snapshot.inventoryEvents.isEmpty)
    }

    func testSnoozeAndSkipPersistWithoutInventoryChanges() throws {
        let url = temporaryURL()
        defer { removeStore(at: url) }
        var value = try session(store: try SupplementStore(url: url))

        _ = try value.apply(
            .snooze,
            to: "magnesium",
            actionID: "snooze-store-1",
            occurredAt: now,
            snoozeUntil: now.addingTimeInterval(300),
            now: now
        )
        let afterSnooze = value.stock(for: "magnesium")
        _ = try value.apply(
            .skip,
            to: "magnesium",
            actionID: "skip-store-1",
            occurredAt: now,
            now: now
        )
        XCTAssertEqual(afterSnooze, 10)
        XCTAssertEqual(value.stock(for: "magnesium"), 10)
        XCTAssertTrue(value.snapshot.inventoryEvents.isEmpty)

        let reopened = try SupplementStore(url: url).load(now: now)
        XCTAssertEqual(reopened?.snapshot.plans.first?.stockUnits, 10)
        XCTAssertEqual(reopened?.actionReceipts.count, 2)
    }

    func testReopenOnNextLocalDayMaterializesPlannedOccurrenceAndPersistsIt() throws {
        let url = temporaryURL()
        defer { removeStore(at: url) }
        let store = try SupplementStore(url: url)
        var first = try session(store: store)
        _ = try first.apply(
            .taken,
            to: "magnesium",
            actionID: "day-one-taken",
            occurredAt: now,
            now: now
        )
        let nextDay = now.addingTimeInterval(86_400)
        let reopened = try session(
            store: try SupplementStore(url: url),
            records: [],
            selectedDate: nextDay
        )

        XCTAssertEqual(reopened.selectedLocalDate, "2026-08-12")
        XCTAssertEqual(reopened.state(for: "magnesium"), .planned)
        // Reopening materializes the complete bounded notification horizon,
        // not only the newly selected day.  The original Aug 11 occurrence
        // remains durable alongside the next-day and future occurrences.
        XCTAssertGreaterThanOrEqual(reopened.snapshot.occurrences.count, 31)
        XCTAssertEqual(reopened.stock(for: "magnesium"), 8)
        XCTAssertEqual(
            try SupplementStore(url: url).load(now: nextDay)?.snapshot.occurrences.count,
            reopened.snapshot.occurrences.count
        )

        var nextDaySession = reopened
        _ = try nextDaySession.apply(
            .taken,
            to: "magnesium",
            actionID: "day-two-taken",
            occurredAt: nextDay,
            now: nextDay
        )
        let finalState = try XCTUnwrap(try SupplementStore(url: url).load(now: nextDay))
        XCTAssertEqual(finalState.snapshot.occurrences.filter { $0.state == .taken }.count, 2)
        XCTAssertEqual(finalState.actionReceipts.map(\.actionID), ["day-one-taken", "day-two-taken"])
    }

    func testReconcileMaterializesFullNotificationHorizonBeforePlanning() throws {
        let url = temporaryURL()
        defer { removeStore(at: url) }
        let store = try SupplementStore(url: url)
        var value = try session(store: store)
        try value.reconcile(
            selectedDate: now,
            now: now,
            lookAheadDays: 6
        )

        let loaded = try XCTUnwrap(try store.load(now: now))
        XCTAssertGreaterThanOrEqual(loaded.snapshot.occurrences.count, 7)
        let plan = try SupplementNotificationPlanner(
            now: now,
            lookAheadDays: 6
        ).plan(
            plans: loaded.snapshot.plans,
            occurrences: loaded.snapshot.occurrences,
            now: now
        )
        XCTAssertFalse(plan.intents.isEmpty)
        XCTAssertTrue(plan.intents.allSatisfy { intent in
            loaded.snapshot.occurrences.contains {
                $0.id == intent.occurrenceIdentifier && $0.planID == intent.planID
            }
        })
    }

    func testConcurrentObserverNeverSeesOneOccurrenceAddGap() throws {
        let url = temporaryURL()
        defer { removeStore(at: url) }
        let writerEntered = DispatchSemaphore(value: 0)
        let allowWriter = DispatchSemaphore(value: 0)
        let replaceLock = NSLock()
        var replaceCount = 0
        let store = try SupplementStore(url: url, beforeReplace: {
            replaceLock.lock()
            replaceCount += 1
            let isAdd = replaceCount == 2
            replaceLock.unlock()
            if isAdd {
                writerEntered.signal()
                _ = allowWriter.wait(timeout: .now() + 2)
            }
        })
        var value = try session(store: store)
        let initial = try XCTUnwrap(store.load(now: now))
        XCTAssertGreaterThanOrEqual(initial.snapshot.occurrences.count, 31)

        let writerGroup = DispatchGroup()
        var addError: Error?
        let errorLock = NSLock()
        writerGroup.enter()
        DispatchQueue.global(qos: .userInitiated).async {
            defer { writerGroup.leave() }
            do {
                try value.add(self.record(id: "vitamin-d"), now: self.now)
            } catch {
                errorLock.lock()
                addError = error
                errorLock.unlock()
            }
        }
        XCTAssertEqual(writerEntered.wait(timeout: .now() + 2), .success)

        let observerGroup = DispatchGroup()
        let observerQueue = DispatchQueue(label: "lifeos.supplement.atomic-observer", attributes: .concurrent)
        let observationsLock = NSLock()
        var observations: [SupplementStoreState] = []
        for _ in 0..<8 {
            observerGroup.enter()
            observerQueue.async {
                defer { observerGroup.leave() }
                do {
                    guard let observed = try store.load(now: self.now) else { return }
                    observationsLock.lock()
                    observations.append(observed)
                    observationsLock.unlock()
                } catch {
                    // The writer is paused before atomic replacement; a
                    // reader must block, not observe a temporary file.
                }
            }
        }
        allowWriter.signal()
        writerGroup.wait()
        observerGroup.wait()

        errorLock.lock()
        let finalAddError = addError
        errorLock.unlock()
        XCTAssertNil(finalAddError)
        XCTAssertFalse(observations.isEmpty)
        XCTAssertTrue(observations.allSatisfy { state in
            state.snapshot.plans.allSatisfy { plan in
                state.snapshot.occurrences.filter { $0.planID == plan.id }.count >= 31
            }
        })
    }

    func testPlannerFailsClosedWhenDurableOccurrenceIsMissing() throws {
        let url = temporaryURL()
        defer { removeStore(at: url) }
        let scheduledPlan = try XCTUnwrap(
            try session(store: try SupplementStore(url: url)).snapshot.plans.first
        )
        let plan = try SupplementNotificationPlanner(
            now: now,
            lookAheadDays: 1
        ).plan(plans: [scheduledPlan], occurrences: [], now: now)
        XCTAssertTrue(plan.intents.isEmpty)
    }

    func testAgingUsesGraceAndNeverAgesCurrentFutureOrSnoozedOccurrences() throws {
        let url = temporaryURL()
        defer { removeStore(at: url) }
        let store = try SupplementStore(url: url)
        var value = try session(store: store)
        try value.reconcile(selectedDate: now, now: now, lookAheadDays: 2)
        let original = try XCTUnwrap(value.snapshot.occurrences.first)
        let graceNow = original.scheduledFor.addingTimeInterval(
            FitnessSupplementSession.plannedOccurrenceGraceInterval - 1
        )
        try value.reconcile(selectedDate: now, now: graceNow, lookAheadDays: 0)
        XCTAssertEqual(value.snapshot.occurrences.first(where: { $0.id == original.id })?.state, .planned)

        let agedNow = original.scheduledFor.addingTimeInterval(
            FitnessSupplementSession.plannedOccurrenceGraceInterval + 1
        )
        try value.reconcile(selectedDate: now, now: agedNow, lookAheadDays: 0)
        XCTAssertEqual(value.snapshot.occurrences.first(where: { $0.id == original.id })?.state, .missed)

        let snoozedURL = temporaryURL()
        defer { removeStore(at: snoozedURL) }
        var snoozedValue = try session(store: try SupplementStore(url: snoozedURL))
        _ = try snoozedValue.apply(
            .snooze,
            to: "magnesium",
            actionID: "aging-snooze",
            occurredAt: now,
            snoozeUntil: agedNow.addingTimeInterval(300),
            now: now
        )
        try snoozedValue.reconcile(
            selectedDate: now,
            now: agedNow.addingTimeInterval(86_400),
            lookAheadDays: 0
        )
        XCTAssertEqual(
            snoozedValue.snapshot.occurrences.first(where: { $0.id == original.id })?.state,
            .snoozed
        )
    }

    func testFractionalActionTimestampReplaysAgainstPersistedPrecision() throws {
        let url = temporaryURL()
        defer { removeStore(at: url) }
        let precise = now.addingTimeInterval(0.000123)
        var first = try session(store: try SupplementStore(url: url))
        _ = try first.apply(
            .taken,
            to: "magnesium",
            actionID: "fractional-1",
            occurredAt: precise,
            now: now
        )

        var reopened = try session(store: try SupplementStore(url: url), records: [])
        let replay = try reopened.apply(
            .taken,
            to: "magnesium",
            actionID: "fractional-1",
            occurredAt: precise,
            now: now
        )
        XCTAssertTrue(replay.idempotent)
        XCTAssertEqual(reopened.actionReceipts[0].occurredAt, first.actionReceipts[0].occurredAt)
    }

    func testSeparateSessionsUseLatestDurableSnapshotWithoutLostUpdates() throws {
        let url = temporaryURL()
        defer { removeStore(at: url) }
        let records = [record(id: "magnesium-a"), record(id: "magnesium-b")]
        var left = try session(store: try SupplementStore(url: url), records: records)
        var right = try session(store: try SupplementStore(url: url), records: [])

        _ = try left.apply(.taken, to: "magnesium-a", actionID: "left-1", occurredAt: now, now: now)
        _ = try right.apply(.taken, to: "magnesium-b", actionID: "right-1", occurredAt: now, now: now)

        let state = try XCTUnwrap(try SupplementStore(url: url).load(now: now))
        XCTAssertEqual(state.snapshot.revision, 2)
        XCTAssertEqual(state.snapshot.plans.first { $0.id == "magnesium-a" }?.stockUnits, 8)
        XCTAssertEqual(state.snapshot.plans.first { $0.id == "magnesium-b" }?.stockUnits, 8)
        XCTAssertEqual(Set(state.actionReceipts.map(\.actionID)), ["left-1", "right-1"])
    }

    func testConcurrentLoadOrCreatePublishesOneInitialEnvelope() throws {
        let url = temporaryURL()
        defer { removeStore(at: url) }
        let queue = DispatchQueue(label: "lifeos.supplement.load-or-create", attributes: .concurrent)
        let group = DispatchGroup()
        let resultLock = NSLock()
        let fixedNow = now
        let fixedRecord = record()
        var values: [SupplementStoreState] = []
        var createCount = 0

        for _ in 0..<8 {
            group.enter()
            queue.async {
                defer { group.leave() }
                do {
                    let store = try SupplementStore(url: url)
                    let state = try store.loadOrCreate(now: fixedNow) {
                        resultLock.lock()
                        createCount += 1
                        resultLock.unlock()
                        let session = try FitnessSupplementSession(
                            supplements: [fixedRecord],
                            selectedDate: fixedNow,
                            now: fixedNow
                        )
                        return try SupplementStoreState(snapshot: session.snapshot, now: fixedNow)
                    }
                    resultLock.lock()
                    values.append(state)
                    resultLock.unlock()
                } catch {
                    XCTFail("loadOrCreate failed: \(error)")
                }
            }
        }
        group.wait()
        XCTAssertEqual(values.count, 8)
        XCTAssertEqual(createCount, 1)
        XCTAssertEqual(Set(values.map { $0.snapshot.plans.map(\.id) }), [["magnesium"]])
    }

    func testReusingReceiptIDWithChangedPayloadIsRejectedAfterRelaunch() throws {
        let url = temporaryURL()
        defer { removeStore(at: url) }
        var value = try session(store: try SupplementStore(url: url))
        _ = try value.apply(
            .taken,
            to: "magnesium",
            actionID: "collision-1",
            occurredAt: now,
            now: now
        )

        var reopened = try session(store: try SupplementStore(url: url), records: [])
        XCTAssertThrowsError(
            try reopened.apply(
                .skip,
                to: "magnesium",
                actionID: "collision-1",
                occurredAt: now,
                now: now
            )
        ) { error in
            XCTAssertEqual(
                error as? FitnessSupplementSessionError,
                .actionIDCollision("collision-1")
            )
        }
        XCTAssertEqual(reopened.stock(for: "magnesium"), 8)
    }

    func testFailedAtomicWriteKeepsPreviousDurableFile() throws {
        let url = temporaryURL()
        defer { removeStore(at: url) }
        let stableStore = try SupplementStore(url: url)
        let stableSession = try session(store: stableStore)
        let oldData = try Data(contentsOf: url)

        let failingStore = try SupplementStore(
            url: url,
            beforeReplace: {
                throw NSError(domain: "test.write", code: 1)
            }
        )
        var changedSnapshot = stableSession.snapshot
        changedSnapshot.generatedAt = now
        XCTAssertThrowsError(
            try failingStore.save(snapshot: changedSnapshot, now: now)
        ) { error in
            XCTAssertEqual(error as? SupplementStoreError, .writeFailed)
        }
        XCTAssertEqual(try Data(contentsOf: url), oldData)
        XCTAssertEqual(try stableStore.load(now: now)?.snapshot, stableSession.snapshot)
    }

    func testSessionPublishesNothingWhenDurableActionWriteFails() throws {
        let url = temporaryURL()
        defer { removeStore(at: url) }
        let stableStore = try SupplementStore(url: url)
        var stable = try session(store: stableStore)
        let before = stable

        let failingStore = try SupplementStore(
            url: url,
            beforeReplace: {
                throw NSError(domain: "test.write", code: 2)
            }
        )
        var candidate = try session(store: failingStore, records: [])
        let beforeCandidate = candidate
        XCTAssertThrowsError(
            try candidate.apply(
                .taken,
                to: "magnesium",
                actionID: "failed-publish-1",
                occurredAt: now,
                now: now
            )
        ) { error in
            XCTAssertEqual(error as? FitnessSupplementSessionError, .persistenceFailed)
        }
        XCTAssertEqual(candidate, beforeCandidate)
        XCTAssertEqual(try stableStore.load(now: now)?.snapshot, before.snapshot)
        XCTAssertEqual(stable, before)
    }

    func testEnvelopeRejectsMalformedUnknownDuplicateAndDanglingRecords() throws {
        let url = temporaryURL()
        defer { removeStore(at: url) }
        let store = try SupplementStore(url: url)
        var value = try session(store: store)
        _ = try value.apply(
            .taken,
            to: "magnesium",
            actionID: "strict-1",
            occurredAt: now,
            now: now
        )
        let original = try XCTUnwrap(
            JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any]
        )

        try Data("{".utf8).write(to: url, options: [.atomic])
        XCTAssertThrowsError(try store.load(now: now))

        var unknown = original
        unknown["unknown"] = true
        try write(unknown, to: url)
        XCTAssertThrowsError(try store.load(now: now))

        var duplicate = original
        let receipts = try XCTUnwrap(original["actionReceipts"] as? [[String: Any]])
        duplicate["actionReceipts"] = receipts + receipts
        try write(duplicate, to: url)
        XCTAssertThrowsError(try store.load(now: now))

        var dangling = original
        var danglingReceipts = receipts
        danglingReceipts[0]["planID"] = "missing-plan"
        dangling["actionReceipts"] = danglingReceipts
        try write(dangling, to: url)
        XCTAssertThrowsError(try store.load(now: now))

        var malformed = original
        malformed["schemaVersion"] = 99
        try write(malformed, to: url)
        XCTAssertThrowsError(try store.load(now: now))

        var didNotAdvance = original
        var didNotAdvanceReceipts = receipts
        didNotAdvanceReceipts[0]["baseRevision"] = 1
        didNotAdvance["actionReceipts"] = didNotAdvanceReceipts
        try write(didNotAdvance, to: url)
        XCTAssertThrowsError(try store.load(now: now))

        var wrongState = original
        var wrongStateReceipts = receipts
        wrongStateReceipts[0]["action"] = "skip"
        wrongState["actionReceipts"] = wrongStateReceipts
        try write(wrongState, to: url)
        XCTAssertThrowsError(try store.load(now: now))
    }

    func testEnvelopeRejectsInterleavedReceiptChainTampering() throws {
        let url = temporaryURL()
        defer { removeStore(at: url) }
        let store = try SupplementStore(url: url)
        var first = try session(store: store, records: [record(id: "magnesium-a"), record(id: "magnesium-b")])
        _ = try first.apply(.taken, to: "magnesium-a", actionID: "interleave-a", occurredAt: now, now: now)
        _ = try first.apply(.taken, to: "magnesium-b", actionID: "interleave-b", occurredAt: now, now: now)
        let original = try XCTUnwrap(
            JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any]
        )
        var tampered = original
        var receipts = try XCTUnwrap(original["actionReceipts"] as? [[String: Any]])
        receipts[1]["baseRevision"] = receipts[0]["baseRevision"]
        tampered["actionReceipts"] = receipts
        try write(tampered, to: url)
        XCTAssertThrowsError(try store.load(now: now))
    }

    func testExpiryRefillAndActionReceiptsRoundTripWithoutInference() throws {
        let url = temporaryURL()
        defer { removeStore(at: url) }
        let store = try SupplementStore(url: url)
        let value = try session(store: store)
        var snapshot = value.snapshot
        let expiry = try XCTUnwrap(snapshot.plans[0].expiryDate)
        snapshot.plans[0].stockUnits = 15
        snapshot.plans[0].revision = 1
        let refill = try InventoryEvent(
            id: "refill-1",
            planID: "magnesium",
            kind: .refill,
            delta: 5,
            stockAfter: 15,
            occurredAt: now,
            batch: "batch-b",
            expiry: expiry,
            now: now
        )
        snapshot.inventoryEvents = [refill]
        snapshot.revision = 1
        snapshot.generatedAt = now
        try store.save(snapshot: snapshot, now: now)

        let loaded = try XCTUnwrap(store.load(now: now))
        XCTAssertEqual(loaded.snapshot.plans[0].stockUnits, 15)
        XCTAssertEqual(loaded.snapshot.plans[0].expiryDate, expiry)
        XCTAssertEqual(loaded.snapshot.inventoryEvents, [refill])
    }

    func testClockTimingRehydratesAndFreeFormTimingNeverSchedules() throws {
        let url = temporaryURL()
        defer { removeStore(at: url) }
        let store = try SupplementStore(url: url)
        let records = [
            record(id: "clock", timing: "11:30"),
            record(id: "note", timing: "Before lunch", expiryDate: nil),
        ]
        _ = try session(store: store, records: records)

        let loaded = try XCTUnwrap(store.load(now: now))
        let clockPlan = try XCTUnwrap(loaded.snapshot.plans.first { $0.id == "clock" })
        let notePlan = try XCTUnwrap(loaded.snapshot.plans.first { $0.id == "note" })
        XCTAssertEqual(clockPlan.schedule.localTime, "11:30")
        XCTAssertNil(clockPlan.schedule.timingNote)
        XCTAssertTrue(clockPlan.reminderEnabled)
        XCTAssertEqual(notePlan.schedule.localTime, "00:00")
        XCTAssertEqual(notePlan.schedule.timingNote, "Before lunch")
        XCTAssertFalse(notePlan.reminderEnabled)
        let notificationPlan = try SupplementNotificationPlanner(now: now, lookAheadDays: 1).plan(
                plans: loaded.snapshot.plans,
                occurrences: loaded.snapshot.occurrences,
                now: now
            )
        XCTAssertFalse(notificationPlan.intents.isEmpty)
        XCTAssertTrue(notificationPlan.intents.allSatisfy { $0.planID == "clock" })
        let rehydrated = try session(store: try SupplementStore(url: url), records: [])
        XCTAssertEqual(rehydrated.records.first { $0.id == "note" }?.timing, "Before lunch")
        XCTAssertEqual(rehydrated.records.first { $0.id == "note" }?.reminderStatus, .localOnly)
    }

    func testVisualFixtureRecordsDoNotWriteAStore() throws {
        let url = temporaryURL()
        defer { removeStore(at: url) }
        let store = try SupplementStore(url: url)
        _ = try session(store: store)
        let before = try Data(contentsOf: url)
        XCTAssertTrue(FitnessSupplement.demo.allSatisfy(\.isVisualFixture))
        _ = try FitnessSupplementSession(
            supplements: FitnessSupplement.demo,
            selectedDate: now,
            now: now
        )
        XCTAssertEqual(try Data(contentsOf: url), before)

        XCTAssertThrowsError(
            try FitnessSupplementSession(
                supplements: [FitnessSupplement.demo[0]],
                selectedDate: now,
                store: store,
                now: now
            )
        ) { error in
            XCTAssertEqual(error as? FitnessSupplementSessionError, .visualFixturePersistenceForbidden)
        }

        var production = try session(store: store)
        XCTAssertThrowsError(try production.add(FitnessSupplement.demo[0], now: now)) { error in
            XCTAssertEqual(error as? FitnessSupplementSessionError, .visualFixturePersistenceForbidden)
        }
    }

    private func write(_ object: [String: Any], to url: URL) throws {
        let data = try JSONSerialization.data(withJSONObject: object, options: [])
        try data.write(to: url, options: [.atomic])
    }
}
