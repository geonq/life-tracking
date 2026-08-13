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
