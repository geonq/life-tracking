import Foundation
import UserNotifications
import XCTest
@testable import LifeOS

final class SupplementNotificationAdapterTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_786_282_800) // 2026-08-09 13:40 UTC / 15:40 Europe/Berlin

    private func berlinCalendar() -> Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Europe/Berlin")!
        return calendar
    }

    private func date(
        _ year: Int,
        _ month: Int,
        _ day: Int,
        _ hour: Int,
        _ minute: Int
    ) -> Date {
        var components = DateComponents()
        components.year = year
        components.month = month
        components.day = day
        components.hour = hour
        components.minute = minute
        return berlinCalendar().date(from: components)!
    }

    private func localParts(_ date: Date) -> (date: String, time: String) {
        let formatter = DateFormatter()
        formatter.calendar = berlinCalendar()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "Europe/Berlin")
        formatter.dateFormat = "yyyy-MM-dd|HH:mm"
        let values = formatter.string(from: date).split(separator: "|", maxSplits: 1)
        return (String(values[0]), String(values[1]))
    }

    private func intent(
        index: Int = 0,
        fireDate: Date? = nil,
        identifier: String? = nil,
        title: String = "Magnesium reminder",
        body: String = "You planned to take Magnesium before lunch.",
        isPrivate: Bool = false
    ) throws -> SupplementNotificationIntent {
        let fireDate = fireDate ?? now.addingTimeInterval(TimeInterval(3600 + index * 60))
        let parts = localParts(fireDate)
        let occurrenceID = SupplementNotificationPlanner.occurrenceIdentifier(
            planID: "magnesium-200",
            localDate: parts.date,
            localTime: parts.time
        )
        return try SupplementNotificationIntent(
            identifier: identifier ?? SupplementNotificationPlanner.occurrenceRequestIdentifier(
                occurrenceID: occurrenceID
            ),
            scheduleIdentifier: SupplementNotificationPlanner.scheduleIdentifier(planID: "magnesium-200"),
            occurrenceIdentifier: occurrenceID,
            planID: "magnesium-200",
            fireDate: fireDate,
            localDate: parts.date,
            localTime: parts.time,
            timeZoneIdentifier: "Europe/Berlin",
            title: title,
            body: body,
            isPrivate: isPrivate,
            resolution: .exactLocalTime
        )
    }

    private func notificationPlan(
        _ intents: [SupplementNotificationIntent],
        maxPendingIntents: Int = 64,
        evaluatedAt: Date? = nil
    ) -> SupplementNotificationPlan {
        SupplementNotificationPlan(
            evaluatedAt: evaluatedAt ?? now,
            intents: intents,
            maxPendingIntents: maxPendingIntents
        )
    }

    private func result(
        _ adapter: SupplementNotificationAdapter,
        plan: SupplementNotificationPlan
    ) -> Result<SupplementNotificationReconciliation, SupplementNotificationAdapterError> {
        var captured: Result<SupplementNotificationReconciliation, SupplementNotificationAdapterError>?
        adapter.reconcile(plan: plan, now: now) { captured = $0 }
        return captured!
    }

    private func successfulReconciliation(
        _ adapter: SupplementNotificationAdapter,
        plan: SupplementNotificationPlan
    ) throws -> SupplementNotificationReconciliation {
        switch result(adapter, plan: plan) {
        case .success(let value): return value
        case .failure(let error): throw error
        }
    }

    func testAuthorizationStatesAreExposedAndUnauthorizedReconcileDoesNotSchedule() throws {
        for status in [
            SupplementNotificationAuthorizationStatus.notDetermined,
            .denied,
            .authorized,
            .provisional,
            .ephemeral,
            .unknown(99),
        ] {
            let center = FakeSupplementNotificationCenter(authorizationStatus: status)
            let adapter = SupplementNotificationAdapter(center: center)
            var observed: SupplementNotificationAuthorizationStatus?
            adapter.authorizationStatus { observed = $0 }
            XCTAssertEqual(observed, status)

            let reconciliation = try successfulReconciliation(adapter, plan: notificationPlan([try intent()]))
            if status.canSchedule {
                XCTAssertNotEqual(reconciliation.pendingOutcome, .notScheduled)
            } else {
                XCTAssertEqual(reconciliation.pendingOutcome, .notScheduled)
                XCTAssertTrue(center.addedRequests.isEmpty)
                XCTAssertTrue(center.removedIdentifiers.isEmpty)
            }
        }
    }

    func testRequestAuthorizationUsesOnlyAlertAndSoundAndReportsGrant() {
        let center = FakeSupplementNotificationCenter(
            authorizationStatus: .notDetermined,
            authorizationRequestResult: .success(true)
        )
        let adapter = SupplementNotificationAdapter(center: center)
        var output: Result<Bool, SupplementNotificationAdapterError>?

        adapter.requestAuthorization { output = $0 }

        XCTAssertEqual(output, .success(true))
        XCTAssertEqual(center.authorizationRequestCount, 1)
        XCTAssertEqual(center.authorizationOptions, [.alert, .sound])
        XCTAssertFalse(center.authorizationOptions?.contains(.badge) == true)
    }

    func testRequestAuthorizationReducesSystemFailureToGenericAdapterError() {
        let center = FakeSupplementNotificationCenter(
            authorizationStatus: .notDetermined,
            authorizationRequestResult: .failure(
                NSError(domain: "private.system.domain", code: 91, userInfo: [NSLocalizedDescriptionKey: "secret detail"])
            )
        )
        let adapter = SupplementNotificationAdapter(center: center)
        var output: Result<Bool, SupplementNotificationAdapterError>?

        adapter.requestAuthorization { output = $0 }

        XCTAssertEqual(output, .failure(.authorizationRequestFailed))
    }

    func testCategoryRegistersTakenSnoozeAndSkipActions() throws {
        let center = FakeSupplementNotificationCenter()
        SupplementNotificationAdapter(center: center).registerActionsAndCategory()

        let category = try XCTUnwrap(center.categories.first {
            $0.identifier == SupplementNotificationActionIdentifier.category
        })
        XCTAssertEqual(
            category.actions.map(\.identifier),
            [
                SupplementNotificationActionIdentifier.taken,
                SupplementNotificationActionIdentifier.snooze,
                SupplementNotificationActionIdentifier.skip,
            ]
        )
        XCTAssertEqual(category.actions.map(\.title), ["Taken", "Snooze", "Skip"])
        XCTAssertEqual(
            category.actions.map(\.options),
            [.authenticationRequired, .authenticationRequired, .authenticationRequired]
        )
    }

    func testReconcileAddsDesiredRemovesOnlyManagedStaleAndPreservesUnrelated() throws {
        let desired = try intent()
        let stale = try intent(index: 1)
        let unrelated = try unrelatedRequest(identifier: "com.other.app.reminder")
        let center = FakeSupplementNotificationCenter(
            pendingRequests: [try request(for: stale), unrelated]
        )
        let reconciliation = try successfulReconciliation(
            SupplementNotificationAdapter(center: center),
            plan: notificationPlan([desired])
        )

        XCTAssertEqual(reconciliation.pendingOutcome, .reconciled)
        XCTAssertEqual(reconciliation.addedIdentifiers, [desired.identifier])
        XCTAssertEqual(reconciliation.removedIdentifiers, [stale.identifier])
        XCTAssertEqual(center.removedIdentifiers, [stale.identifier])
        XCTAssertEqual(
            Set(center.pendingRequests.map(\.identifier)),
            Set([desired.identifier, unrelated.identifier])
        )
    }

    func testEmptyPlanRemovesOnlyManagedPendingRequests() throws {
        let managed = try intent()
        let unrelated = try unrelatedRequest(identifier: "com.other.app.reminder")
        let center = FakeSupplementNotificationCenter(
            pendingRequests: [try request(for: managed), unrelated]
        )

        let reconciliation = try successfulReconciliation(
            SupplementNotificationAdapter(center: center),
            plan: notificationPlan([])
        )

        XCTAssertEqual(reconciliation.pendingOutcome, .reconciled)
        XCTAssertEqual(reconciliation.removedIdentifiers, [managed.identifier])
        XCTAssertEqual(center.removedIdentifiers, [managed.identifier])
        XCTAssertEqual(center.pendingRequests.map(\.identifier), [unrelated.identifier])
    }

    func testReconcileCapsExternallyConstructedPlanAt64() throws {
        let intents = try (0..<70).map { index in
            try intent(index: index, fireDate: now.addingTimeInterval(TimeInterval((index + 1) * 60)))
        }
        let center = FakeSupplementNotificationCenter()
        let reconciliation = try successfulReconciliation(
            SupplementNotificationAdapter(center: center),
            plan: notificationPlan(intents, maxPendingIntents: 999)
        )

        XCTAssertEqual(reconciliation.pendingOutcome, .reconciled)
        XCTAssertEqual(reconciliation.addedIdentifiers.count, 64)
        XCTAssertEqual(center.addedRequests.count, 64)
        XCTAssertEqual(Set(reconciliation.addedIdentifiers).count, 64)
        XCTAssertEqual(
            reconciliation.addedIdentifiers,
            intents.sorted { lhs, rhs in
                if lhs.fireDate != rhs.fireDate { return lhs.fireDate < rhs.fireDate }
                return lhs.identifier < rhs.identifier
            }.prefix(64).map(\.identifier)
        )
    }

    func testOversizedExternallyConstructedPlanIsRejectedBeforeValidationWork() throws {
        let intents = Array(repeating: try intent(), count: SupplementNotificationAdapter.maxInputIntents + 1)
        let output = result(
            SupplementNotificationAdapter(center: FakeSupplementNotificationCenter()),
            plan: notificationPlan(intents, maxPendingIntents: 999)
        )

        XCTAssertEqual(output, .failure(.invalidPlan("intentCount")))
    }

    func testReconcileIsIdempotentWhenPendingRequestMatchesExactly() throws {
        let adapterCenter = FakeSupplementNotificationCenter()
        let adapter = SupplementNotificationAdapter(center: adapterCenter)
        let plan = notificationPlan([try intent()])

        let first = try successfulReconciliation(adapter, plan: plan)
        let firstAddCount = adapterCenter.addedRequests.count
        let second = try successfulReconciliation(adapter, plan: plan)

        XCTAssertEqual(first.pendingOutcome, .reconciled)
        XCTAssertEqual(second.pendingOutcome, .unchanged)
        XCTAssertEqual(adapterCenter.addedRequests.count, firstAddCount)
        XCTAssertTrue(adapterCenter.removedIdentifiers.isEmpty)
        XCTAssertEqual(second.unchangedIdentifiers, [plan.intents[0].identifier])
    }

    func testPartialAddFailureReportsPendingOutcomeWithoutClaimingDelivery() throws {
        let first = try intent(index: 0)
        let second = try intent(index: 1)
        let third = try intent(index: 2)
        let center = FakeSupplementNotificationCenter(
            addFailures: [second.identifier: NSError(domain: "test", code: 7)]
        )
        let reconciliation = try successfulReconciliation(
            SupplementNotificationAdapter(center: center),
            plan: notificationPlan([first, second, third])
        )

        XCTAssertEqual(reconciliation.pendingOutcome, .partialFailure)
        XCTAssertEqual(reconciliation.addedIdentifiers, [first.identifier, third.identifier])
        XCTAssertEqual(reconciliation.failedIdentifiers, [second.identifier])
        XCTAssertEqual(reconciliation.errorMessages.count, 1)
        XCTAssertNotNil(center.pendingRequests.first { $0.identifier == first.identifier })
        XCTAssertNil(center.pendingRequests.first { $0.identifier == second.identifier })
        XCTAssertNotNil(center.pendingRequests.first { $0.identifier == third.identifier })
    }

    func testPendingQueryFailureIsReturnedTruthfully() throws {
        let center = FakeSupplementNotificationCenter(
            pendingError: NSError(domain: "test", code: 9)
        )
        let output = result(
            SupplementNotificationAdapter(center: center),
            plan: notificationPlan([try intent()])
        )

        XCTAssertEqual(output, .failure(.pendingRequestsFailed))
        XCTAssertTrue(center.addedRequests.isEmpty)
        XCTAssertTrue(center.removedIdentifiers.isEmpty)
    }

    func testLostAuthorizationStatusCallbackReturnsUnknownExactlyOnce() {
        let center = FakeSupplementNotificationCenter()
        center.dropAuthorizationStatusCallback = true
        let adapter = SupplementNotificationAdapter(center: center, operationTimeout: 0.01)
        let expectation = expectation(description: "authorization timeout")
        var callbacks = 0
        var status: SupplementNotificationAuthorizationStatus?
        adapter.authorizationStatus {
            callbacks += 1
            status = $0
            expectation.fulfill()
        }

        wait(for: [expectation], timeout: 1)
        XCTAssertEqual(callbacks, 1)
        XCTAssertEqual(status, .unknown(-1))
    }

    func testDuplicateAuthorizationStatusCallbacksAreReducedToOne() {
        let center = FakeSupplementNotificationCenter()
        center.duplicateAuthorizationStatusCallback = true
        let adapter = SupplementNotificationAdapter(center: center, operationTimeout: 0.01)
        var callbacks = 0
        var status: SupplementNotificationAuthorizationStatus?
        adapter.authorizationStatus {
            callbacks += 1
            status = $0
        }

        XCTAssertEqual(callbacks, 1)
        XCTAssertEqual(status, .authorized)
    }

    func testLostAuthorizationRequestCallbackFailsWithoutHanging() {
        let center = FakeSupplementNotificationCenter()
        center.dropAuthorizationRequestCallback = true
        let adapter = SupplementNotificationAdapter(center: center, operationTimeout: 0.01)
        let expectation = expectation(description: "authorization request timeout")
        var output: Result<Bool, SupplementNotificationAdapterError>?
        adapter.requestAuthorization {
            output = $0
            expectation.fulfill()
        }

        wait(for: [expectation], timeout: 1)
        XCTAssertEqual(output, .failure(.operationTimedOut))
    }

    func testLostPendingCallbackFailsWithoutClaimingReconciliation() throws {
        let center = FakeSupplementNotificationCenter()
        center.dropPendingCallback = true
        let adapter = SupplementNotificationAdapter(center: center, operationTimeout: 0.01)
        let expectation = expectation(description: "pending timeout")
        var output: Result<SupplementNotificationReconciliation, SupplementNotificationAdapterError>?
        adapter.reconcile(plan: notificationPlan([try intent()]), now: now) {
            output = $0
            expectation.fulfill()
        }

        wait(for: [expectation], timeout: 1)
        XCTAssertEqual(output, .failure(.operationTimedOut))
    }

    func testLostAddCallbackFailsAndLateOrDuplicateCallbacksCannotClaimSuccess() throws {
        let first = try intent()
        let second = try intent(index: 1)
        let center = FakeSupplementNotificationCenter()
        center.dropAddCallbacks = [first.identifier]
        center.duplicateAddCallbacks = [second.identifier]
        let adapter = SupplementNotificationAdapter(center: center, operationTimeout: 0.01)
        let expectation = expectation(description: "add timeout")
        var callbacks = 0
        var output: Result<SupplementNotificationReconciliation, SupplementNotificationAdapterError>?
        adapter.reconcile(plan: notificationPlan([first, second]), now: now) {
            callbacks += 1
            output = $0
            expectation.fulfill()
        }

        wait(for: [expectation], timeout: 1)
        XCTAssertEqual(callbacks, 1)
        XCTAssertEqual(output, .failure(.operationTimedOut))
    }

    func testDuplicatePendingCallbackProducesExactlyOneFinalCompletion() throws {
        let center = FakeSupplementNotificationCenter()
        center.duplicatePendingCallback = true
        let adapter = SupplementNotificationAdapter(center: center, operationTimeout: 0.05)
        let expectation = expectation(description: "duplicate pending callback")
        var callbacks = 0
        var output: Result<SupplementNotificationReconciliation, SupplementNotificationAdapterError>?
        adapter.reconcile(plan: notificationPlan([try intent()]), now: now) {
            callbacks += 1
            output = $0
            expectation.fulfill()
        }

        wait(for: [expectation], timeout: 1)
        XCTAssertEqual(callbacks, 1)
        guard case .success(let reconciliation)? = output else {
            return XCTFail("expected one successful reconciliation")
        }
        XCTAssertEqual(reconciliation.pendingOutcome, .reconciled)
    }

    func testLateAuthorizationPendingAndAddCallbacksAfterGlobalTimeoutAreIgnored() throws {
        let configurations: [(String, (FakeSupplementNotificationCenter) -> Void)] = [
            ("authorization", { $0.lateAuthorizationStatusCallback = true }),
            ("pending", { $0.latePendingCallback = true }),
            ("add", { $0.lateAddCallbacks = [try! self.intent().identifier] }),
        ]

        for (label, configure) in configurations {
            let center = FakeSupplementNotificationCenter()
            configure(center)
            let adapter = SupplementNotificationAdapter(center: center, operationTimeout: 0.01)
            let expectation = expectation(description: "global timeout \(label)")
            let callbackLock = NSLock()
            var callbacks = 0
            var output: Result<SupplementNotificationReconciliation, SupplementNotificationAdapterError>?
            adapter.reconcile(plan: notificationPlan([try intent()]), now: now) {
                callbackLock.lock()
                callbacks += 1
                output = $0
                callbackLock.unlock()
                expectation.fulfill()
            }

            wait(for: [expectation], timeout: 1)
            Thread.sleep(forTimeInterval: center.lateCallbackDelay * 2)
            callbackLock.lock()
            let finalCallbacks = callbacks
            let finalOutput = output
            callbackLock.unlock()
            XCTAssertEqual(finalCallbacks, 1, label)
            XCTAssertEqual(finalOutput, .failure(.operationTimedOut), label)
        }
    }

    func testGlobalTimeoutAfterPartialMutationNeverClaimsSuccess() throws {
        let intents = try (0..<4).map { try intent(index: $0) }
        let center = FakeSupplementNotificationCenter()
        center.dropAddCallbacks = Set(intents.dropFirst().map(\.identifier))
        let adapter = SupplementNotificationAdapter(center: center, operationTimeout: 0.02)
        let expectation = expectation(description: "partial mutation timeout")
        var callbacks = 0
        var output: Result<SupplementNotificationReconciliation, SupplementNotificationAdapterError>?
        adapter.reconcile(plan: notificationPlan(intents), now: now) {
            callbacks += 1
            output = $0
            expectation.fulfill()
        }

        wait(for: [expectation], timeout: 1)
        XCTAssertEqual(callbacks, 1)
        XCTAssertEqual(output, .failure(.operationTimedOut))
        XCTAssertEqual(center.addedRequests.count, 2, "one successful add and one in-flight add only")
        XCTAssertNotNil(center.pendingRequests.first { $0.identifier == intents[0].identifier })
    }

    func testSixtyFourLostAddsShareOneReconciliationDeadline() throws {
        let intents = try (0..<64).map { try intent(index: $0) }
        let center = FakeSupplementNotificationCenter()
        center.dropAddCallbacks = Set(intents.map(\.identifier))
        let timeout: TimeInterval = 0.02
        let adapter = SupplementNotificationAdapter(center: center, operationTimeout: timeout)
        let expectation = expectation(description: "bounded add chain")
        let started = Date()
        var callbacks = 0
        var output: Result<SupplementNotificationReconciliation, SupplementNotificationAdapterError>?
        adapter.reconcile(plan: notificationPlan(intents), now: now) {
            callbacks += 1
            output = $0
            expectation.fulfill()
        }

        wait(for: [expectation], timeout: 1)
        XCTAssertLessThan(Date().timeIntervalSince(started), 0.3)
        XCTAssertEqual(callbacks, 1)
        XCTAssertEqual(output, .failure(.operationTimedOut))
        XCTAssertLessThanOrEqual(
            center.addedRequests.count,
            1,
            "the shared deadline may expire before the first add starts; at most one add may be in flight"
        )
    }

    func testFiniteOutOfRangeTokenDateIsRejectedWithoutIntegerTrap() {
        let extreme = Date(timeIntervalSinceReferenceDate: Double.greatestFiniteMagnitude)
        XCTAssertThrowsError(
            try SupplementNotificationActionToken.make(
                occurrenceID: "magnesium-200",
                fireDate: extreme
            )
        ) { error in
            XCTAssertEqual(error as? SupplementNotificationActionTokenError, .invalidFireDate)
        }
        XCTAssertThrowsError(
            try SupplementNotificationIntent(
                identifier: "lifeos.supplement.occurrence.magnesium-200.2026-08-09.15-40",
                scheduleIdentifier: "lifeos.supplement.schedule.magnesium-200",
                occurrenceIdentifier: "magnesium-200.2026-08-09.15-40",
                planID: "magnesium-200",
                fireDate: extreme,
                localDate: "2026-08-09",
                localTime: "15:40",
                timeZoneIdentifier: "Europe/Berlin",
                title: "Reminder",
                body: "Take it.",
                isPrivate: true,
                resolution: .exactLocalTime
            )
        )
    }

    func testNonObservedPlanEvaluationIsRejected() throws {
        let output = result(
            SupplementNotificationAdapter(center: FakeSupplementNotificationCenter()),
            plan: notificationPlan(
                [try intent()],
                evaluatedAt: now.addingTimeInterval(6)
            )
        )

        XCTAssertEqual(output, .failure(.invalidPlan("evaluatedAt")))
    }

    func testPrivateCopyIsPassedThroughWithoutReconstructionOrLeakage() throws {
        let privateIntent = try intent(
            title: "Supplement reminder",
            body: "Your private supplement reminder is scheduled for 09:00.",
            isPrivate: true
        )
        let center = FakeSupplementNotificationCenter()
        _ = try successfulReconciliation(
            SupplementNotificationAdapter(center: center),
            plan: notificationPlan([privateIntent])
        )
        let request = try XCTUnwrap(center.addedRequests.first)

        XCTAssertEqual(request.content.title, privateIntent.title)
        XCTAssertEqual(request.content.body, privateIntent.body)
        XCTAssertFalse(request.content.body.contains("Magnesium"))
        XCTAssertFalse(request.content.body.contains("200 mg"))
        XCTAssertFalse(request.content.body.contains("2 capsule"))
    }

    func testInvalidExternallyConstructedIntentIdentifiersAreRejected() throws {
        let malformed = try intent(identifier: "lifeos.supplement.occurrence.not-the-domain-id")
        let output = result(
            SupplementNotificationAdapter(center: FakeSupplementNotificationCenter()),
            plan: notificationPlan([malformed])
        )

        guard case .failure(.invalidIntent) = output else {
            return XCTFail("expected invalid intent identifier")
        }

        XCTAssertThrowsError(
            try SupplementNotificationIntent(
                identifier: "lifeos.supplement.occurrence.unsafe",
                scheduleIdentifier: "lifeos.supplement.schedule.magnesium-200",
                occurrenceIdentifier: "../unsafe",
                planID: "magnesium-200",
                fireDate: date(2026, 8, 9, 9, 0),
                localDate: "2026-08-09",
                localTime: "09:00",
                timeZoneIdentifier: "Europe/Berlin",
                title: "Supplement reminder",
                body: "Private reminder",
                isPrivate: true,
                resolution: .exactLocalTime
            )
        )
    }

    private func request(for intent: SupplementNotificationIntent) throws -> UNNotificationRequest {
        var components = DateComponents()
        components.year = 2026
        components.month = 8
        components.day = 9
        components.hour = 9
        components.minute = 0
        components.timeZone = TimeZone(identifier: "Europe/Berlin")
        let content = UNMutableNotificationContent()
        content.title = intent.title
        content.body = intent.body
        content.categoryIdentifier = SupplementNotificationActionIdentifier.category
        content.userInfo = [
            SupplementNotificationActionIdentifier.planIDKey: intent.planID,
            SupplementNotificationActionIdentifier.occurrenceIDKey: intent.occurrenceIdentifier,
        ]
        return UNNotificationRequest(
            identifier: intent.identifier,
            content: content,
            trigger: UNCalendarNotificationTrigger(dateMatching: components, repeats: false)
        )
    }

    private func unrelatedRequest(identifier: String) throws -> UNNotificationRequest {
        let content = UNMutableNotificationContent()
        content.title = "Unrelated"
        content.body = "Must remain"
        return UNNotificationRequest(identifier: identifier, content: content, trigger: nil)
    }
}

private final class FakeSupplementNotificationCenter: SupplementNotificationCenter {
    var authorizationStatus: SupplementNotificationAuthorizationStatus
    var authorizationRequestResult: Result<Bool, Error>
    private(set) var authorizationOptions: UNAuthorizationOptions?
    private(set) var authorizationRequestCount = 0
    var categories: Set<UNNotificationCategory> = []
    var pendingRequests: [UNNotificationRequest]
    var pendingError: Error?
    var addFailures: [String: Error]
    var dropAuthorizationStatusCallback = false
    var duplicateAuthorizationStatusCallback = false
    var lateAuthorizationStatusCallback = false
    var dropAuthorizationRequestCallback = false
    var dropPendingCallback = false
    var duplicatePendingCallback = false
    var latePendingCallback = false
    var dropAddCallbacks: Set<String> = []
    var duplicateAddCallbacks: Set<String> = []
    var lateAddCallbacks: Set<String> = []
    let lateCallbackDelay: TimeInterval = 0.05
    private(set) var addedRequests: [UNNotificationRequest] = []
    private(set) var removedIdentifiers: [String] = []

    init(
        authorizationStatus: SupplementNotificationAuthorizationStatus = .authorized,
        authorizationRequestResult: Result<Bool, Error> = .success(true),
        pendingRequests: [UNNotificationRequest] = [],
        pendingError: Error? = nil,
        addFailures: [String: Error] = [:]
    ) {
        self.authorizationStatus = authorizationStatus
        self.authorizationRequestResult = authorizationRequestResult
        self.pendingRequests = pendingRequests
        self.pendingError = pendingError
        self.addFailures = addFailures
    }

    func getAuthorizationStatus(
        completion: @escaping (SupplementNotificationAuthorizationStatus) -> Void
    ) {
        if lateAuthorizationStatusCallback {
            let status = authorizationStatus
            DispatchQueue.global().asyncAfter(deadline: .now() + lateCallbackDelay) {
                completion(status)
            }
            return
        }
        guard !dropAuthorizationStatusCallback else { return }
        completion(authorizationStatus)
        if duplicateAuthorizationStatusCallback {
            completion(authorizationStatus)
        }
    }

    func requestAuthorization(
        options: UNAuthorizationOptions,
        completion: @escaping (Result<Bool, Error>) -> Void
    ) {
        authorizationRequestCount += 1
        authorizationOptions = options
        guard !dropAuthorizationRequestCallback else { return }
        completion(authorizationRequestResult)
    }

    func setNotificationCategories(_ categories: Set<UNNotificationCategory>) {
        self.categories = categories
    }

    func getPendingNotificationRequests(
        completion: @escaping (Result<[UNNotificationRequest], Error>) -> Void
    ) {
        if latePendingCallback {
            let pending = pendingRequests
            DispatchQueue.global().asyncAfter(deadline: .now() + lateCallbackDelay) {
                completion(.success(pending))
            }
            return
        }
        guard !dropPendingCallback else { return }
        if let pendingError {
            completion(.failure(pendingError))
        } else {
            completion(.success(pendingRequests))
        }
        if duplicatePendingCallback {
            completion(.success(pendingRequests))
        }
    }

    func add(_ request: UNNotificationRequest, completion: @escaping (Error?) -> Void) {
        addedRequests.append(request)
        if lateAddCallbacks.contains(request.identifier) {
            pendingRequests.removeAll { $0.identifier == request.identifier }
            pendingRequests.append(request)
            DispatchQueue.global().asyncAfter(deadline: .now() + lateCallbackDelay) {
                completion(nil)
            }
            return
        }
        if dropAddCallbacks.contains(request.identifier) {
            pendingRequests.removeAll { $0.identifier == request.identifier }
            pendingRequests.append(request)
            return
        }
        if let error = addFailures[request.identifier] {
            completion(error)
            if duplicateAddCallbacks.contains(request.identifier) {
                completion(error)
            }
            return
        }
        pendingRequests.removeAll { $0.identifier == request.identifier }
        pendingRequests.append(request)
        completion(nil)
        if duplicateAddCallbacks.contains(request.identifier) {
            completion(nil)
        }
    }

    func removePendingNotificationRequests(withIdentifiers identifiers: [String]) {
        removedIdentifiers.append(contentsOf: identifiers)
        let identifiers = Set(identifiers)
        pendingRequests.removeAll { identifiers.contains($0.identifier) }
    }
}
