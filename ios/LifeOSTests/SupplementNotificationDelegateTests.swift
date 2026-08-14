import Foundation
import UserNotifications
import XCTest
@testable import LifeOS

final class SupplementNotificationDelegateTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_786_449_600)

    func testWillPresentOnlyAllowsCurrentValidOccurrence() throws {
        let fixture = try makeFixture()
        defer { fixture.cleanup() }
        let fixedNow = now
        let delegate = SupplementNotificationDelegate(store: fixture.store, nowProvider: { fixedNow })
        var validOptions: UNNotificationPresentationOptions?
        delegate.handleWillPresent(
            categoryIdentifier: SupplementNotificationActionIdentifier.category,
            userInfo: fixture.userInfo,
            now: now
        ) { validOptions = $0 }
        XCTAssertEqual(validOptions, [.banner, .sound])

        var malformedOptions: UNNotificationPresentationOptions?
        delegate.handleWillPresent(
            categoryIdentifier: "other.category",
            userInfo: fixture.userInfo,
            now: now
        ) { malformedOptions = $0 }
        XCTAssertEqual(malformedOptions, [])
    }

    func testSnoozePersistsBeforeReconcilerAndCompletion() throws {
        let fixture = try makeFixture()
        defer { fixture.cleanup() }
        let reconciler = RecordingReconciler()
        let fixedNow = now
        let delegate = SupplementNotificationDelegate(
            store: fixture.store,
            reconciler: reconciler,
            nowProvider: { fixedNow }
        )
        var completionCount = 0

        delegate.handleAction(
            actionIdentifier: SupplementNotificationActionIdentifier.snooze,
            categoryIdentifier: SupplementNotificationActionIdentifier.category,
            userInfo: fixture.userInfo
        ) { completionCount += 1 }

        XCTAssertEqual(reconciler.calls, 1)
        XCTAssertEqual(completionCount, 0, "completion must wait for pending reconciliation")
        let durable = try XCTUnwrap(try fixture.store.load(now: now))
        XCTAssertEqual(
            durable.snapshot.occurrences.first(where: { $0.id == fixture.targetOccurrenceID })?.state,
            .snoozed
        )
        XCTAssertEqual(
            reconciler.snapshot?.occurrences.first(where: { $0.id == fixture.targetOccurrenceID })?.state,
            .snoozed
        )

        reconciler.finish(.success(SupplementNotificationReconciliation(
            authorizationStatus: .authorized,
            pendingOutcome: .reconciled
        )))
        XCTAssertEqual(completionCount, 1)
        XCTAssertEqual(delegate.lastActionOutcome, .durableAndReconciled)
    }

    func testSnoozeSchedulingFailureLeavesDurableTruthAndReportsFailureOutcome() throws {
        let fixture = try makeFixture()
        defer { fixture.cleanup() }
        let reconciler = RecordingReconciler()
        let fixedNow = now
        let delegate = SupplementNotificationDelegate(
            store: fixture.store,
            reconciler: reconciler,
            nowProvider: { fixedNow }
        )
        var completionCount = 0

        delegate.handleAction(
            actionIdentifier: SupplementNotificationActionIdentifier.snooze,
            categoryIdentifier: SupplementNotificationActionIdentifier.category,
            userInfo: fixture.userInfo
        ) { completionCount += 1 }
        reconciler.finish(.success(SupplementNotificationReconciliation(
            authorizationStatus: .authorized,
            pendingOutcome: .partialFailure,
            failedIdentifiers: ["replacement"]
        )))

        XCTAssertEqual(completionCount, 1)
        XCTAssertEqual(delegate.lastActionOutcome, .durableReconcileFailed)
        XCTAssertEqual(
            try fixture.store.load(now: now)?.snapshot.occurrences.first(where: {
                $0.id == fixture.targetOccurrenceID
            })?.state,
            .snoozed
        )
    }

    func testSnoozePermissionDeniedOrUnknownIsDurableButNotScheduled() throws {
        for authorizationStatus in [
            SupplementNotificationAuthorizationStatus.denied,
            .notDetermined,
            .unknown(999)
        ] {
            let fixture = try makeFixture()
            let reconciler = RecordingReconciler()
            let fixedNow = now
            let delegate = SupplementNotificationDelegate(
                store: fixture.store,
                reconciler: reconciler,
                nowProvider: { fixedNow }
            )
            var completionCount = 0

            delegate.handleAction(
                actionIdentifier: SupplementNotificationActionIdentifier.snooze,
                categoryIdentifier: SupplementNotificationActionIdentifier.category,
                userInfo: fixture.userInfo
            ) { completionCount += 1 }

            XCTAssertEqual(reconciler.calls, 1)
            XCTAssertEqual(completionCount, 0)
            XCTAssertEqual(
                try fixture.store.load(now: now)?.snapshot.occurrences.first(where: {
                    $0.id == fixture.targetOccurrenceID
                })?.state,
                .snoozed
            )

            reconciler.finish(.success(SupplementNotificationReconciliation(
                authorizationStatus: authorizationStatus,
                pendingOutcome: .notScheduled
            )))

            XCTAssertEqual(completionCount, 1)
            XCTAssertEqual(delegate.lastActionOutcome, .durableNotScheduled)
            fixture.cleanup()
        }
    }

    func testSnoozeReconcilerTimeoutCompletesWithoutLosingDurableTruth() throws {
        let fixture = try makeFixture()
        defer { fixture.cleanup() }
        let reconciler = RecordingReconciler()
        let fixedNow = now
        let delegate = SupplementNotificationDelegate(
            store: fixture.store,
            reconciler: reconciler,
            nowProvider: { fixedNow },
            reconcilerTimeout: 0.01
        )
        let completion = expectation(description: "notification action completion")
        delegate.handleAction(
            actionIdentifier: SupplementNotificationActionIdentifier.snooze,
            categoryIdentifier: SupplementNotificationActionIdentifier.category,
            userInfo: fixture.userInfo
        ) { completion.fulfill() }

        wait(for: [completion], timeout: 1)
        XCTAssertEqual(delegate.lastActionOutcome, .durableReconcileFailed)
        XCTAssertEqual(
            try fixture.store.load(now: now)?.snapshot.occurrences.first(where: {
                $0.id == fixture.targetOccurrenceID
            })?.state,
            .snoozed
        )
    }

    func testTakenAndSkipCompleteAfterDurableWriteWithoutCenterWait() throws {
        for action in [SupplementNotificationActionIdentifier.taken, SupplementNotificationActionIdentifier.skip] {
            let fixture = try makeFixture()
            defer { fixture.cleanup() }
            let reconciler = RecordingReconciler()
            let fixedNow = now
            let delegate = SupplementNotificationDelegate(
                store: fixture.store,
                reconciler: reconciler,
                nowProvider: { fixedNow }
            )
            var completionCount = 0
            delegate.handleAction(
                actionIdentifier: action,
                categoryIdentifier: SupplementNotificationActionIdentifier.category,
                userInfo: fixture.userInfo
            ) { completionCount += 1 }

            XCTAssertEqual(completionCount, 1)
            XCTAssertEqual(reconciler.calls, 0)
            let state = try XCTUnwrap(try fixture.store.load(now: now))
            XCTAssertNotEqual(
                state.snapshot.occurrences.first(where: { $0.id == fixture.targetOccurrenceID })?.state,
                .planned
            )
            XCTAssertEqual(delegate.lastActionOutcome, .durableOnly)
        }
    }

    func testReplayIsIdempotentAndDoesNotDecrementInventoryAgain() throws {
        let fixture = try makeFixture()
        defer { fixture.cleanup() }
        let fixedNow = now
        let delegate = SupplementNotificationDelegate(store: fixture.store, nowProvider: { fixedNow })
        var completionCount = 0

        for _ in 0..<2 {
            delegate.handleAction(
                actionIdentifier: SupplementNotificationActionIdentifier.taken,
                categoryIdentifier: SupplementNotificationActionIdentifier.category,
                userInfo: fixture.userInfo
            ) { completionCount += 1 }
        }

        let state = try XCTUnwrap(try fixture.store.load(now: now))
        XCTAssertEqual(completionCount, 2)
        XCTAssertEqual(state.snapshot.plans.first?.stockUnits, 9)
        XCTAssertEqual(state.snapshot.inventoryEvents.count, 1)
        XCTAssertEqual(state.actionReceipts.count, 1)
        XCTAssertEqual(delegate.lastActionOutcome, .durableOnly)
    }

    func testExactReplayRemainsIdempotentAfterFreshnessWindow() throws {
        let fixture = try makeFixture()
        defer { fixture.cleanup() }
        let occurrence = try XCTUnwrap(
            try fixture.store.load(now: now)?.snapshot.occurrences.first(where: {
                $0.id == fixture.targetOccurrenceID
            })
        )
        let firstActionNow = occurrence.scheduledFor.addingTimeInterval(1)
        let delegate = SupplementNotificationDelegate(
            store: fixture.store,
            nowProvider: { firstActionNow }
        )
        var completionCount = 0

        delegate.handleAction(
            actionIdentifier: SupplementNotificationActionIdentifier.taken,
            categoryIdentifier: SupplementNotificationActionIdentifier.category,
            userInfo: fixture.userInfo
        ) { completionCount += 1 }

        let staleNow = occurrence.scheduledFor.addingTimeInterval(
            FitnessSupplementSession.plannedOccurrenceGraceInterval + 1
        )
        let replayDelegate = SupplementNotificationDelegate(
            store: fixture.store,
            nowProvider: { staleNow }
        )
        replayDelegate.handleAction(
            actionIdentifier: SupplementNotificationActionIdentifier.taken,
            categoryIdentifier: SupplementNotificationActionIdentifier.category,
            userInfo: fixture.userInfo
        ) { completionCount += 1 }

        let state = try XCTUnwrap(try fixture.store.load(now: staleNow))
        XCTAssertEqual(completionCount, 2)
        XCTAssertEqual(state.snapshot.plans.first?.stockUnits, 9)
        XCTAssertEqual(state.snapshot.inventoryEvents.count, 1)
        XCTAssertEqual(state.actionReceipts.count, 1)
        XCTAssertEqual(replayDelegate.lastActionOutcome, .durableOnly)
    }

    func testUnknownActionAndMismatchedPlanAreRejectedWithoutMutation() throws {
        let fixture = try makeFixture()
        defer { fixture.cleanup() }
        let fixedNow = now
        let delegate = SupplementNotificationDelegate(store: fixture.store, nowProvider: { fixedNow })
        var mismatchedPlan = fixture.userInfo
        mismatchedPlan[SupplementNotificationActionIdentifier.planIDKey] = "another-plan"
        var completionCount = 0

        for (action, userInfo) in [
            ("lifeos.supplement.action.unknown.v1", fixture.userInfo),
            (SupplementNotificationActionIdentifier.taken, mismatchedPlan),
        ] {
            delegate.handleAction(
                actionIdentifier: action,
                categoryIdentifier: SupplementNotificationActionIdentifier.category,
                userInfo: userInfo
            ) { completionCount += 1 }
            XCTAssertEqual(delegate.lastActionOutcome, .rejected)
        }

        let state = try XCTUnwrap(try fixture.store.load(now: now))
        XCTAssertEqual(completionCount, 2)
        XCTAssertEqual(state.snapshot.occurrences.first?.state, .planned)
        XCTAssertTrue(state.actionReceipts.isEmpty)
        XCTAssertTrue(state.snapshot.inventoryEvents.isEmpty)
    }

    func testNewPlannedActionsBeforeExpectedFireDateAreRejected() throws {
        let fixture = try makeFixture()
        defer { fixture.cleanup() }
        let occurrence = try XCTUnwrap(
            try fixture.store.load(now: now)?.snapshot.occurrences.first(where: {
                $0.id == fixture.targetOccurrenceID
            })
        )
        let preFireNow = occurrence.scheduledFor.addingTimeInterval(-1)
        let delegate = SupplementNotificationDelegate(
            store: fixture.store,
            nowProvider: { preFireNow }
        )
        var completionCount = 0

        for action in [
            SupplementNotificationActionIdentifier.taken,
            SupplementNotificationActionIdentifier.snooze,
            SupplementNotificationActionIdentifier.skip
        ] {
            delegate.handleAction(
                actionIdentifier: action,
                categoryIdentifier: SupplementNotificationActionIdentifier.category,
                userInfo: fixture.userInfo
            ) { completionCount += 1 }
            XCTAssertEqual(delegate.lastActionOutcome, .rejected)
        }

        let state = try XCTUnwrap(try fixture.store.load(now: preFireNow))
        XCTAssertEqual(completionCount, 3)
        XCTAssertEqual(
            state.snapshot.occurrences.first(where: { $0.id == fixture.targetOccurrenceID })?.state,
            .planned
        )
        XCTAssertTrue(state.actionReceipts.isEmpty)
        XCTAssertTrue(state.snapshot.inventoryEvents.isEmpty)
    }

    func testNewSnoozedActionsBeforeExpectedFireDateAreRejected() throws {
        let fixture = try makeFixture()
        defer { fixture.cleanup() }
        let snoozeUntil = now.addingTimeInterval(60 * 60)
        let userInfo = try makeSnoozedUserInfo(
            for: fixture,
            occurredAt: now,
            snoozeUntil: snoozeUntil
        )
        let fixedNow = now
        let delegate = SupplementNotificationDelegate(
            store: fixture.store,
            nowProvider: { fixedNow }
        )
        var completionCount = 0

        for action in [
            SupplementNotificationActionIdentifier.taken,
            SupplementNotificationActionIdentifier.snooze,
            SupplementNotificationActionIdentifier.skip
        ] {
            delegate.handleAction(
                actionIdentifier: action,
                categoryIdentifier: SupplementNotificationActionIdentifier.category,
                userInfo: userInfo
            ) { completionCount += 1 }
            XCTAssertEqual(delegate.lastActionOutcome, .rejected)
        }

        let state = try XCTUnwrap(try fixture.store.load(now: now))
        XCTAssertEqual(completionCount, 3)
        XCTAssertEqual(
            state.snapshot.occurrences.first(where: { $0.id == fixture.targetOccurrenceID })?.state,
            .snoozed
        )
        XCTAssertEqual(state.actionReceipts.count, 1, "only the setup snooze may be recorded")
        XCTAssertTrue(state.snapshot.inventoryEvents.isEmpty)
    }

    func testPlannedActionPastGraceWindowIsRejectedBeforeMutation() throws {
        let fixture = try makeFixture()
        defer { fixture.cleanup() }
        let occurrence = try XCTUnwrap(
            try fixture.store.load(now: now)?.snapshot.occurrences.first(where: {
                $0.id == fixture.targetOccurrenceID
            })
        )
        let staleNow = occurrence.scheduledFor.addingTimeInterval(
            FitnessSupplementSession.plannedOccurrenceGraceInterval + 1
        )
        let delegate = SupplementNotificationDelegate(store: fixture.store, nowProvider: { staleNow })
        var presentationOptions: UNNotificationPresentationOptions?
        delegate.handleWillPresent(
            categoryIdentifier: SupplementNotificationActionIdentifier.category,
            userInfo: fixture.userInfo,
            now: staleNow
        ) { presentationOptions = $0 }
        var completionCount = 0

        for action in [
            SupplementNotificationActionIdentifier.taken,
            SupplementNotificationActionIdentifier.snooze,
            SupplementNotificationActionIdentifier.skip
        ] {
            delegate.handleAction(
                actionIdentifier: action,
                categoryIdentifier: SupplementNotificationActionIdentifier.category,
                userInfo: fixture.userInfo
            ) { completionCount += 1 }
            XCTAssertEqual(delegate.lastActionOutcome, .rejected)
        }

        let state = try XCTUnwrap(try fixture.store.load(now: staleNow))
        XCTAssertEqual(presentationOptions, [])
        XCTAssertEqual(completionCount, 3)
        XCTAssertEqual(delegate.lastActionOutcome, .rejected)
        XCTAssertEqual(state.snapshot.occurrences.first(where: { $0.id == fixture.targetOccurrenceID })?.state, .planned)
        XCTAssertTrue(state.actionReceipts.isEmpty)
        XCTAssertTrue(state.snapshot.inventoryEvents.isEmpty)
    }

    func testNewSnoozedActionsPastGraceWindowAreRejectedBeforeMutation() throws {
        let fixture = try makeFixture()
        defer { fixture.cleanup() }
        let snoozeUntil = now.addingTimeInterval(60 * 60)
        let userInfo = try makeSnoozedUserInfo(
            for: fixture,
            occurredAt: now,
            snoozeUntil: snoozeUntil
        )
        let staleNow = snoozeUntil.addingTimeInterval(
            FitnessSupplementSession.plannedOccurrenceGraceInterval + 1
        )
        let delegate = SupplementNotificationDelegate(
            store: fixture.store,
            nowProvider: { staleNow }
        )
        var completionCount = 0

        for action in [
            SupplementNotificationActionIdentifier.taken,
            SupplementNotificationActionIdentifier.snooze,
            SupplementNotificationActionIdentifier.skip
        ] {
            delegate.handleAction(
                actionIdentifier: action,
                categoryIdentifier: SupplementNotificationActionIdentifier.category,
                userInfo: userInfo
            ) { completionCount += 1 }
            XCTAssertEqual(delegate.lastActionOutcome, .rejected)
        }

        let state = try XCTUnwrap(try fixture.store.load(now: staleNow))
        XCTAssertEqual(completionCount, 3)
        XCTAssertEqual(
            state.snapshot.occurrences.first(where: { $0.id == fixture.targetOccurrenceID })?.state,
            .snoozed
        )
        XCTAssertEqual(state.actionReceipts.count, 1, "only the setup snooze may be recorded")
        XCTAssertTrue(state.snapshot.inventoryEvents.isEmpty)
    }

    func testStaleTokenIsRejectedWithoutMutation() throws {
        let fixture = try makeFixture()
        defer { fixture.cleanup() }
        let fixedNow = now
        let delegate = SupplementNotificationDelegate(store: fixture.store, nowProvider: { fixedNow })
        var stale = fixture.userInfo
        stale[SupplementNotificationActionIdentifier.fireDateKey] =
            SupplementNotificationActionToken.wireDate(now.addingTimeInterval(3_600))
        var completionCount = 0
        delegate.handleAction(
            actionIdentifier: SupplementNotificationActionIdentifier.taken,
            categoryIdentifier: SupplementNotificationActionIdentifier.category,
            userInfo: stale
        ) { completionCount += 1 }

        XCTAssertEqual(completionCount, 1)
        XCTAssertEqual(delegate.lastActionOutcome, .rejected)
        XCTAssertEqual(try fixture.store.load(now: now)?.snapshot.occurrences.first?.state, .planned)
    }

    private struct Fixture {
        let store: SupplementStore
        let userInfo: [String: String]
        let rootURL: URL

        var targetOccurrenceID: String {
            userInfo[SupplementNotificationActionIdentifier.occurrenceIDKey]!
        }

        func cleanup() {
            try? FileManager.default.removeItem(at: rootURL)
        }
    }

    private func makeSnoozedUserInfo(
        for fixture: Fixture,
        occurredAt: Date,
        snoozeUntil: Date
    ) throws -> [String: String] {
        let state = try XCTUnwrap(try fixture.store.load(now: occurredAt))
        let planID = try XCTUnwrap(
            fixture.userInfo[SupplementNotificationActionIdentifier.planIDKey]
        )
        let occurrenceID = try XCTUnwrap(
            fixture.userInfo[SupplementNotificationActionIdentifier.occurrenceIDKey]
        )
        let request = try SupplementOccurrenceActionRequest(
            actionID: "delegate-test-snooze-setup",
            occurrenceID: occurrenceID,
            planID: planID,
            action: .snooze,
            occurredAt: occurredAt,
            snoozeUntil: snoozeUntil,
            baseRevision: state.snapshot.revision,
            sourceDeviceID: "delegate-test"
        )
        try fixture.store.mutate(now: occurredAt) { state in
            var nextSnapshot = state.snapshot
            var ledger = SupplementActionLedger()
            _ = try SupplementReducer.reduce(
                request,
                in: &nextSnapshot,
                ledger: &ledger,
                now: occurredAt
            )
            let receipt = try SupplementActionReceipt(request: request, now: occurredAt)
            state = try SupplementStoreState(
                snapshot: nextSnapshot,
                actionReceipts: state.actionReceipts + [receipt],
                now: occurredAt
            )
        }

        let updated = try XCTUnwrap(try fixture.store.load(now: occurredAt))
        let expectedFireDate = try XCTUnwrap(
            updated.snapshot.occurrences.first(where: { $0.id == occurrenceID })?.snoozedUntil
        )
        let token = try SupplementNotificationActionToken.make(
            occurrenceID: occurrenceID,
            fireDate: expectedFireDate
        )
        var userInfo = fixture.userInfo
        userInfo[SupplementNotificationActionIdentifier.actionTokenKey] = token
        userInfo[SupplementNotificationActionIdentifier.generationKey] = token
        userInfo[SupplementNotificationActionIdentifier.fireDateKey] =
            SupplementNotificationActionToken.wireDate(expectedFireDate)
        return userInfo
    }

    private func makeFixture() throws -> Fixture {
        let rootURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("lifeos-notification-delegate-\(UUID().uuidString)", isDirectory: true)
        let url = rootURL
            .appendingPathComponent(SupplementStore.fileName)
        let store = try SupplementStore(url: url)
        let record = FitnessSupplement(
            id: "magnesium",
            name: "Magnesium",
            brand: "User-entered product",
            form: .capsule,
            strength: "200 mg",
            servingUnit: "capsule",
            userDose: "1 capsule",
            timing: "11:30",
            timeZoneIdentifier: "Europe/Berlin",
            scheduledDays: Set(1...7),
            stockUnits: 10,
            reorderThreshold: 2
        )
        _ = try FitnessSupplementSession(
            supplements: [record],
            selectedDate: now,
            store: store,
            now: now
        )
        let state = try XCTUnwrap(try store.load(now: now))
        let plan = try SupplementNotificationPlanner(
            now: now,
            lookAheadDays: SupplementNotificationPlanner.defaultLookAheadDays
        ).plan(
            plans: state.snapshot.plans,
            occurrences: state.snapshot.occurrences,
            now: now
        )
        let intent = try XCTUnwrap(plan.intents.first)
        let token = try SupplementNotificationActionToken.make(
            occurrenceID: intent.occurrenceIdentifier,
            fireDate: intent.fireDate
        )
        return Fixture(
            store: store,
            userInfo: [
                SupplementNotificationActionIdentifier.planIDKey: intent.planID,
                SupplementNotificationActionIdentifier.occurrenceIDKey: intent.occurrenceIdentifier,
                SupplementNotificationActionIdentifier.actionTokenKey: token,
                SupplementNotificationActionIdentifier.generationKey: token,
                SupplementNotificationActionIdentifier.fireDateKey:
                    SupplementNotificationActionToken.wireDate(intent.fireDate),
            ],
            rootURL: rootURL
        )
    }
}

private final class RecordingReconciler: SupplementNotificationReconciler {
    var calls = 0
    var snapshot: SupplementSnapshot?
    private var pendingCompletion:
        ((Result<SupplementNotificationReconciliation, SupplementNotificationAdapterError>) -> Void)?

    func reconcile(
        snapshot: SupplementSnapshot,
        now: Date,
        completion: @escaping (Result<SupplementNotificationReconciliation, SupplementNotificationAdapterError>) -> Void
    ) {
        _ = now
        calls += 1
        self.snapshot = snapshot
        pendingCompletion = completion
    }

    func finish(
        _ result: Result<SupplementNotificationReconciliation, SupplementNotificationAdapterError>
    ) {
        let completion = pendingCompletion
        pendingCompletion = nil
        completion?(result)
    }
}
