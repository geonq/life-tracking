import Foundation
import UserNotifications
import XCTest
@testable import LifeOS

@MainActor
final class SupplementNotificationPermissionCoordinatorTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_786_449_600) // 2026-08-11 00:00 UTC

    func testMapperPreservesEverySystemPermissionState() {
        let cases: [(SupplementNotificationAuthorizationStatus, SupplementNotificationPermissionState)] = [
            (.notDetermined, .notDetermined),
            (.denied, .denied),
            (.authorized, .authorized),
            (.provisional, .provisional),
            (.ephemeral, .ephemeral),
            (.unknown(404), .unknown),
        ]

        for (status, expected) in cases {
            XCTAssertEqual(SupplementNotificationPermissionStateMapper.map(status), expected)
        }
    }

    func testPermissionRequestRequiresAnActionableClockSchedule() {
        XCTAssertTrue(
            SupplementNotificationPermissionStateMapper.canRequestPermission(
                for: .notDetermined,
                hasActionableSchedule: true
            )
        )
        XCTAssertFalse(
            SupplementNotificationPermissionStateMapper.canRequestPermission(
                for: .notDetermined,
                hasActionableSchedule: false
            )
        )
        XCTAssertFalse(
            SupplementNotificationPermissionStateMapper.canRequestPermission(
                for: .authorized,
                hasActionableSchedule: true
            )
        )
    }

    func testRefreshQueriesStatusWithoutRequestingPermission() async {
        let center = PermissionFakeNotificationCenter(authorizationStatus: .notDetermined)
        let coordinator = SupplementNotificationPermissionCoordinator(
            adapter: SupplementNotificationAdapter(center: center)
        )

        coordinator.refresh()
        await drainMainActorTasks()

        XCTAssertEqual(coordinator.state, .notDetermined)
        XCTAssertEqual(center.authorizationRequestCount, 0)
        XCTAssertEqual(center.categoryRegistrationCount, 0)
    }

    func testExplicitRequestUsesGrantResultAndRegistersCategoryWithoutScheduling() async {
        let center = PermissionFakeNotificationCenter(
            authorizationStatus: .notDetermined,
            authorizationRequestResult: .success(true)
        )
        let coordinator = SupplementNotificationPermissionCoordinator(
            adapter: SupplementNotificationAdapter(center: center)
        )

        coordinator.refresh()
        await drainMainActorTasks()
        coordinator.requestPermission()
        await drainMainActorTasks()

        XCTAssertEqual(coordinator.state, .authorized)
        XCTAssertEqual(center.authorizationRequestCount, 1)
        XCTAssertEqual(center.authorizationOptions, [.alert, .sound])
        XCTAssertEqual(center.categoryRegistrationCount, 1)
        XCTAssertTrue(center.addedRequests.isEmpty)
        XCTAssertTrue(center.pendingRequests.isEmpty)
    }

    func testDeniedRequestDoesNotRegisterCategoryAndExposesDeniedState() async {
        let center = PermissionFakeNotificationCenter(
            authorizationStatus: .notDetermined,
            authorizationRequestResult: .success(false)
        )
        let coordinator = SupplementNotificationPermissionCoordinator(
            adapter: SupplementNotificationAdapter(center: center)
        )

        coordinator.refresh()
        await drainMainActorTasks()
        coordinator.requestPermission()
        await drainMainActorTasks()

        XCTAssertEqual(coordinator.state, .denied)
        XCTAssertEqual(center.authorizationRequestCount, 1)
        XCTAssertEqual(center.categoryRegistrationCount, 0)
    }

    func testAuthorizationFailureIsGenericAndDoesNotRegisterCategory() async {
        let center = PermissionFakeNotificationCenter(
            authorizationStatus: .notDetermined,
            authorizationRequestResult: .failure(
                NSError(domain: "private.system.domain", code: 8)
            )
        )
        let coordinator = SupplementNotificationPermissionCoordinator(
            adapter: SupplementNotificationAdapter(center: center)
        )

        coordinator.refresh()
        await drainMainActorTasks()
        coordinator.requestPermission()
        await drainMainActorTasks()

        XCTAssertEqual(coordinator.state, .error)
        XCTAssertEqual(center.categoryRegistrationCount, 0)
    }

    func testUnauthorizedSnapshotReconcilePerformsNoNotificationWrites() async throws {
        let center = PermissionFakeNotificationCenter(authorizationStatus: .notDetermined)
        let session = try makeSession(timing: "11:30")
        let coordinator = makeCoordinator(center: center)

        coordinator.reconcile(snapshot: session.snapshot, now: now)
        await drainMainActorTasks()

        XCTAssertEqual(coordinator.schedulingState, .notScheduled)
        XCTAssertTrue(center.addedRequests.isEmpty)
        XCTAssertTrue(center.pendingRequests.isEmpty)
        XCTAssertTrue(center.removedIdentifiers.isEmpty)
        XCTAssertEqual(center.categoryRegistrationCount, 0)
    }

    func testAuthorizedExplicitClockAddsRealRedactedPendingRequest() async throws {
        let center = PermissionFakeNotificationCenter(authorizationStatus: .authorized)
        let session = try makeSession(timing: "11:30")
        let coordinator = makeCoordinator(center: center)

        coordinator.reconcile(snapshot: session.snapshot, now: now)
        await drainMainActorTasks()

        guard case .reconciled(let added, _, let pending) = coordinator.schedulingState else {
            return XCTFail("expected reconciled pending state")
        }
        XCTAssertEqual(added, 1)
        XCTAssertEqual(pending, 1)
        let request = try XCTUnwrap(center.addedRequests.first)
        XCTAssertEqual(request.content.title, "Supplement reminder")
        XCTAssertEqual(request.content.body, "Your private supplement reminder is scheduled for 11:30.")
        XCTAssertFalse(request.content.body.contains("Magnesium"))
        XCTAssertFalse(request.content.body.contains("200 mg"))
        XCTAssertNotNil(request.trigger as? UNCalendarNotificationTrigger)
    }

    func testFreeFormTimingRemainsInformationalAndAddsNoRequest() async throws {
        let center = PermissionFakeNotificationCenter(authorizationStatus: .authorized)
        let session = try makeSession(timing: "Before lunch")
        let coordinator = makeCoordinator(center: center)

        coordinator.reconcile(snapshot: session.snapshot, now: now)
        await drainMainActorTasks()

        XCTAssertEqual(coordinator.schedulingState, .unchanged(pendingCount: 0))
        XCTAssertTrue(center.addedRequests.isEmpty)
        XCTAssertTrue(center.pendingRequests.isEmpty)
    }

    func testRepeatedReconcileIsIdempotent() async throws {
        let center = PermissionFakeNotificationCenter(authorizationStatus: .authorized)
        let session = try makeSession(timing: "11:30")
        let coordinator = makeCoordinator(center: center)

        coordinator.reconcile(snapshot: session.snapshot, now: now)
        await drainMainActorTasks()
        let firstAddCount = center.addedRequests.count
        coordinator.reconcile(snapshot: session.snapshot, now: now)
        await drainMainActorTasks()

        XCTAssertEqual(firstAddCount, 1)
        XCTAssertEqual(center.addedRequests.count, firstAddCount)
        XCTAssertEqual(coordinator.schedulingState, .unchanged(pendingCount: 1))
    }

    func testTakenRemovesAndSnoozeMovesTheSameOccurrenceRequest() async throws {
        let center = PermissionFakeNotificationCenter(authorizationStatus: .authorized)
        var session = try makeSession(timing: "11:30")
        let coordinator = makeCoordinator(center: center)

        coordinator.reconcile(snapshot: session.snapshot, now: now)
        await drainMainActorTasks()
        let original = try XCTUnwrap(center.pendingRequests.first)
        let originalTrigger = try XCTUnwrap(original.trigger as? UNCalendarNotificationTrigger)

        _ = try session.apply(
            .snooze,
            to: "magnesium",
            actionID: "snooze-coordinator",
            occurredAt: now,
            snoozeUntil: now.addingTimeInterval(3_600),
            now: now
        )
        coordinator.reconcile(snapshot: session.snapshot, now: now)
        await drainMainActorTasks()

        let snoozed = try XCTUnwrap(center.pendingRequests.first)
        let snoozedTrigger = try XCTUnwrap(snoozed.trigger as? UNCalendarNotificationTrigger)
        XCTAssertEqual(snoozed.identifier, original.identifier)
        XCTAssertNotEqual(snoozedTrigger.dateComponents, originalTrigger.dateComponents)
        XCTAssertEqual(coordinator.schedulingState, .reconciled(addedCount: 1, removedCount: 0, pendingCount: 1))

        _ = try session.apply(
            .taken,
            to: "magnesium",
            actionID: "taken-coordinator",
            occurredAt: now,
            now: now
        )
        coordinator.reconcile(snapshot: session.snapshot, now: now)
        await drainMainActorTasks()

        XCTAssertTrue(center.pendingRequests.isEmpty)
        XCTAssertEqual(coordinator.schedulingState, .reconciled(addedCount: 0, removedCount: 1, pendingCount: 0))
    }

    private func makeSession(timing: String) throws -> FitnessSupplementSession {
        let record = FitnessSupplement(
            id: "magnesium",
            name: "Magnesium",
            brand: "User-entered product",
            form: .capsule,
            strength: "200 mg",
            servingUnit: "capsule",
            userDose: "2 capsules",
            timing: timing,
            timeZoneIdentifier: "Europe/Berlin",
            scheduledDays: [4],
            stockUnits: 10,
            reorderThreshold: 2,
            expectedLeadTimeDays: 7
        )
        return try FitnessSupplementSession(
            supplements: [record],
            selectedDate: now.addingTimeInterval(86_400),
            now: now
        )
    }

    private func makeCoordinator(
        center: PermissionFakeNotificationCenter
    ) -> SupplementNotificationPermissionCoordinator {
        let fixedNow = now
        return SupplementNotificationPermissionCoordinator(
            adapter: SupplementNotificationAdapter(center: center),
            planner: SupplementNotificationPlanner(
                now: now,
                lookAheadDays: 1,
                maxPendingIntents: 64
            ),
            nowProvider: { fixedNow }
        )
    }

    private func drainMainActorTasks() async {
        for _ in 0..<4 {
            await Task.yield()
        }
    }
}

private final class PermissionFakeNotificationCenter: SupplementNotificationCenter {
    var authorizationStatus: SupplementNotificationAuthorizationStatus
    var authorizationRequestResult: Result<Bool, Error>
    private(set) var authorizationOptions: UNAuthorizationOptions?
    private(set) var authorizationRequestCount = 0
    private(set) var categoryRegistrationCount = 0
    private(set) var pendingRequests: [UNNotificationRequest] = []
    private(set) var addedRequests: [UNNotificationRequest] = []
    private(set) var removedIdentifiers: [String] = []

    init(
        authorizationStatus: SupplementNotificationAuthorizationStatus,
        authorizationRequestResult: Result<Bool, Error> = .success(true)
    ) {
        self.authorizationStatus = authorizationStatus
        self.authorizationRequestResult = authorizationRequestResult
    }

    func getAuthorizationStatus(
        completion: @escaping (SupplementNotificationAuthorizationStatus) -> Void
    ) {
        let status = authorizationStatus
        completion(status)
    }

    func requestAuthorization(
        options: UNAuthorizationOptions,
        completion: @escaping (Result<Bool, Error>) -> Void
    ) {
        authorizationRequestCount += 1
        authorizationOptions = options
        let result = authorizationRequestResult
        if case .success(true) = result {
            authorizationStatus = .authorized
        } else if case .success(false) = result {
            authorizationStatus = .denied
        }
        completion(result)
    }

    func setNotificationCategories(_ categories: Set<UNNotificationCategory>) {
        categoryRegistrationCount += 1
    }

    func getPendingNotificationRequests(
        completion: @escaping (Result<[UNNotificationRequest], Error>) -> Void
    ) {
        completion(.success(pendingRequests))
    }

    func add(_ request: UNNotificationRequest, completion: @escaping (Error?) -> Void) {
        addedRequests.append(request)
        pendingRequests.removeAll { $0.identifier == request.identifier }
        pendingRequests.append(request)
        completion(nil)
    }

    func removePendingNotificationRequests(withIdentifiers identifiers: [String]) {
        let identifiers = Set(identifiers)
        removedIdentifiers.append(contentsOf: identifiers.sorted())
        pendingRequests.removeAll { identifiers.contains($0.identifier) }
    }
}
