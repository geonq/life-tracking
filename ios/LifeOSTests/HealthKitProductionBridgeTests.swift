#if os(iOS)
import XCTest
#if canImport(HealthKit)
import HealthKit
#endif
@testable import LifeOS

@MainActor
final class HealthKitProductionBridgeTests: XCTestCase {
    func testDelegatesAvailabilityStatusAndRequestWithoutChangingReadTruth() async {
        var statusMetrics: [HealthKitMetricID] = []
        var requestMetrics: [HealthKitMetricID] = []
        let client = makeClient(
            availability: { .restricted },
            status: { statusMetrics = $0; return .init(state: .requestRequired) },
            request: { requestMetrics = $0; return .init(state: .readIndeterminate, promptCompleted: true) }
        )

        XCTAssertEqual(client.availabilityState(), .restricted)
        let statusReport = await client.requestStatus(for: HealthKitIntegrationController.supportedMetrics)
        let requestReport = await client.requestReadAuthorization(for: HealthKitIntegrationController.supportedMetrics)
        XCTAssertEqual(statusReport.state, .requestRequired)
        XCTAssertEqual(requestReport.state, .readIndeterminate)
        XCTAssertEqual(statusMetrics, HealthKitIntegrationController.supportedMetrics)
        XCTAssertEqual(requestMetrics, HealthKitIntegrationController.supportedMetrics)
    }

    func testStartRegistersEverySupportedMetricAndReportsInitialReconciliation() async {
        var registered: [HealthKitMetricID] = []
        var reconciled: [HealthKitMetricID] = []
        var updates: [HealthKitObserverCompletion] = []
        let client = makeClient(
            register: { metric, _ in registered.append(metric) },
            reconcile: { metrics in
                reconciled = metrics
                return HealthKitReconciliationReport(results: [])
            }
        )

        client.startObservers(metrics: HealthKitIntegrationController.supportedMetrics) { updates.append($0) }
        await waitUntil { updates == [.success] }

        XCTAssertEqual(registered, HealthKitIntegrationController.supportedMetrics)
        XCTAssertEqual(reconciled, HealthKitIntegrationController.supportedMetrics)
        XCTAssertFalse(registered.contains(.alcoholicBeverages))
    }

    func testPartialRegistrationFailureStopsEverythingAndRemainsRestartable() async {
        var stopCount = 0
        var shouldFail = true
        var registered: [HealthKitMetricID] = []
        var updates: [HealthKitObserverCompletion] = []
        let client = makeClient(
            register: { metric, _ in
                registered.append(metric)
                if shouldFail && registered.count == 3 { throw HealthKitAdapterError.unavailable }
            },
            stop: { stopCount += 1 }
        )

        client.startObservers(metrics: HealthKitIntegrationController.supportedMetrics) { updates.append($0) }
        XCTAssertEqual(updates, [.failure("HealthKit is unavailable on this device")])
        XCTAssertEqual(stopCount, 2) // pre-start reset + partial-failure cleanup

        shouldFail = false
        registered.removeAll()
        client.startObservers(metrics: HealthKitIntegrationController.supportedMetrics) { updates.append($0) }
        await waitUntil { updates.last == .success }
        XCTAssertEqual(registered, HealthKitIntegrationController.supportedMetrics)
    }

    func testStopCancelsInitialReconcileAndSuppressesLateCompletion() async {
        var stopCount = 0
        var continuation: CheckedContinuation<HealthKitReconciliationReport, Never>?
        var updates: [HealthKitObserverCompletion] = []
        let client = makeClient(
            stop: { stopCount += 1 },
            reconcile: { _ in
                await withCheckedContinuation { continuation = $0 }
            }
        )

        client.startObservers(metrics: HealthKitIntegrationController.supportedMetrics) { updates.append($0) }
        await waitUntil { continuation != nil }
        client.stopAllObservers()
        continuation?.resume(returning: HealthKitReconciliationReport(results: []))
        await Task.yield()

        XCTAssertTrue(updates.isEmpty)
        XCTAssertEqual(stopCount, 2)
    }

    func testInvalidOrAlcoholMetricSetIsRejectedBeforeRegistration() {
        var registered = 0
        var update: HealthKitObserverCompletion?
        let client = makeClient(register: { _, _ in registered += 1 })
        client.startObservers(metrics: [.water, .alcoholicBeverages]) { update = $0 }
        XCTAssertEqual(registered, 0)
        XCTAssertEqual(update, .failure("HealthKit metric configuration was rejected"))
    }

    func testInvalidMetricSetIsRejectedBeforeStatusOrAuthorization() async {
        var statusCalls = 0
        var requestCalls = 0
        let client = makeClient(
            status: { _ in statusCalls += 1; return .init(state: .requestRequired) },
            request: { _ in requestCalls += 1; return .init(state: .readIndeterminate, promptCompleted: true) }
        )

        let invalid: [HealthKitMetricID] = [.water, .alcoholicBeverages]
        let status = await client.requestStatus(for: invalid)
        let request = await client.requestReadAuthorization(for: invalid)

        XCTAssertEqual(statusCalls, 0)
        XCTAssertEqual(requestCalls, 0)
        XCTAssertEqual(status.state, .error)
        XCTAssertEqual(request.state, .error)
        XCTAssertEqual(status.errorDescription, "HealthKit metric configuration was rejected")
        XCTAssertEqual(request.errorDescription, "HealthKit metric configuration was rejected")
    }

    func testStoredStatesUsesInjectedReaderAndReturnsRequestedOrder() async {
        var readerMetrics: [HealthKitMetricID] = []
        let expected = HealthKitIntegrationController.supportedMetrics
            .map(HealthKitStoredMetricState.empty(for:))
        let client = makeClient(stateReader: { metrics in
            readerMetrics = metrics
            return Array(expected.reversed())
        })

        let states = await client.storedStates(for: expected.map(\.metric))

        XCTAssertEqual(readerMetrics, expected.map(\.metric))
        XCTAssertEqual(states.map(\.metric), expected.map(\.metric))
        XCTAssertEqual(states, expected)
    }

    func testStoredStatesRejectsInvalidAndAlcoholSetsWithoutReading() async {
        var readerCalls = 0
        let client = makeClient(stateReader: { _ in
            readerCalls += 1
            return []
        })

        let invalid: [HealthKitMetricID] = [.water, .alcoholicBeverages]
        let states = await client.storedStates(for: invalid)

        XCTAssertTrue(states.isEmpty)
        XCTAssertEqual(readerCalls, 0)
    }

    func testStoredStatesPreservesErrorAndEmptyTruth() async {
        let metrics = HealthKitIntegrationController.supportedMetrics
        let errorProjection = try! HealthKitMetricProjection(
            metric: metrics[0],
            lastCommittedAt: Date(timeIntervalSinceReferenceDate: 0),
            syncState: .error
        )
        let errorState = HealthKitStoredMetricState(projection: errorProjection)
        var provided = metrics.map(HealthKitStoredMetricState.empty(for:))
        provided[0] = errorState
        let client = makeClient(stateReader: { _ in provided })

        let states = await client.storedStates(for: metrics)

        XCTAssertEqual(states[0].syncState, .error)
        XCTAssertTrue(states[0].observations.isEmpty)
        XCTAssertEqual(states[1...].allSatisfy { $0.syncState == .neverSynced }, true)
        XCTAssertTrue(states[1...].allSatisfy { $0.observations.isEmpty })
    }

    func testStoredStatesFailsClosedForMissingDuplicateOrUnexpectedReaderStates() async {
        let metrics = HealthKitIntegrationController.supportedMetrics
        let emptyStates = metrics.map(HealthKitStoredMetricState.empty(for:))
        let malformedOutputs: [[HealthKitStoredMetricState]] = [
            Array(emptyStates.dropLast()),
            Array(emptyStates.dropLast()) + [.empty(for: metrics[0])],
            Array(emptyStates.dropLast()) + [.empty(for: .alcoholicBeverages)]
        ]

        for malformed in malformedOutputs {
            let client = makeClient(stateReader: { _ in malformed })
            let states = await client.storedStates(for: metrics)

            XCTAssertEqual(states.map(\.metric), metrics)
            XCTAssertTrue(states.allSatisfy { $0.syncState == .error })
            XCTAssertTrue(states.allSatisfy { $0.observations.isEmpty })
        }
    }

    func testImmediateStopPreventsInitialReconciliationFromStarting() async {
        var reconciliationCalls = 0
        var updates: [HealthKitObserverCompletion] = []
        let client = makeClient(reconcile: { _ in
            reconciliationCalls += 1
            return .init(results: [])
        })

        client.startObservers(metrics: HealthKitIntegrationController.supportedMetrics) { updates.append($0) }
        client.stopAllObservers()
        await Task.yield()

        XCTAssertEqual(reconciliationCalls, 0)
        XCTAssertTrue(updates.isEmpty)
    }

    func testAuthorizationAndReconciliationErrorsAreSanitized() async {
        let sentinel = "SECRET_PROVIDER_PAYLOAD"
        let client = makeClient(
            status: { _ in .init(state: .error, errorDescription: sentinel) },
            request: { _ in .init(state: .error, promptCompleted: false, errorDescription: sentinel) },
            reconcile: { metrics in
                .init(results: [
                    .init(
                        metric: metrics[0],
                        state: .error,
                        errorDescription: sentinel,
                        completion: .failure(sentinel)
                    )
                ])
            }
        )

        let status = await client.requestStatus(for: HealthKitIntegrationController.supportedMetrics)
        let request = await client.requestReadAuthorization(for: HealthKitIntegrationController.supportedMetrics)
        XCTAssertEqual(status.errorDescription, "HealthKit authorization status could not be checked")
        XCTAssertEqual(request.errorDescription, "HealthKit authorization could not be completed")
        XCTAssertFalse(status.errorDescription?.contains(sentinel) ?? true)
        XCTAssertFalse(request.errorDescription?.contains(sentinel) ?? true)

        var updates: [HealthKitObserverCompletion] = []
        client.startObservers(metrics: HealthKitIntegrationController.supportedMetrics) { updates.append($0) }
        await waitUntil { !updates.isEmpty }
        XCTAssertEqual(updates, [.failure("HealthKit reconciliation failed")])
    }

    func testMixedAggregateKeepsSanitizedFailureWhileReportingDurablePartialSuccess() async {
        let client = try! makeCoordinatorBackedClient(failingMetrics: [.caffeine])

        var updates: [HealthKitObserverCompletion] = []
        client.startObservers(metrics: HealthKitIntegrationController.supportedMetrics) { updates.append($0) }
        await waitUntil { !updates.isEmpty }

        XCTAssertEqual(
            updates,
            [.partialSuccess("HealthKit reconciliation partially failed after a durable metric commit")]
        )
        XCTAssertFalse(updates.description.contains("SECRET_PROVIDER_PAYLOAD"))
    }

    func testTimedOutAggregateWithDurableCommitIsPartialAndSanitized() async {
        let client = try! makeCoordinatorBackedClient(delaysByMetric: [.caffeine: [300_000_000]])

        var updates: [HealthKitObserverCompletion] = []
        client.startObservers(metrics: HealthKitIntegrationController.supportedMetrics) { updates.append($0) }
        await waitUntil { !updates.isEmpty }

        XCTAssertEqual(
            updates,
            [.partialSuccess("HealthKit reconciliation timed out after a durable metric commit")]
        )
    }

    func testInitialDurablePageMakesLaterRemainderFailurePartial() async {
        let client = try! makeCoordinatorBackedClient(
            partialMetric: .water,
            delaysByMetric: [.water: [0, 300_000_000]]
        )

        var updates: [HealthKitObserverCompletion] = []
        client.startObservers(metrics: HealthKitIntegrationController.supportedMetrics) { updates.append($0) }
        await waitUntil { updates == [.success] }
        try? await Task.sleep(nanoseconds: 2_100_000_000)
        await waitUntil { updates.count == 2 }

        XCTAssertEqual(
            updates[1],
            .partialSuccess("HealthKit reconciliation timed out after a durable metric commit")
        )
    }

    func testObserverCallbackErrorIsSanitized() async {
        let sentinel = "SECRET_PROVIDER_PAYLOAD"
        var observerUpdate: HealthKitProductionClient.ObserverUpdate?
        var updates: [HealthKitObserverCompletion] = []
        let client = makeClient(register: { _, update in observerUpdate = update })

        client.startObservers(metrics: HealthKitIntegrationController.supportedMetrics) { updates.append($0) }
        observerUpdate?(.failure(sentinel))
        await waitUntil { updates.contains(.failure("HealthKit reconciliation failed")) }

        XCTAssertFalse(updates.contains(.failure(sentinel)))
    }

    func testObserverCallbackCannotTurnMetricPartialOutcomeIntoDurableRefresh() async {
        var observerUpdate: HealthKitProductionClient.ObserverUpdate?
        var updates: [HealthKitObserverCompletion] = []
        let client = makeClient(register: { _, update in observerUpdate = update })

        client.startObservers(metrics: HealthKitIntegrationController.supportedMetrics) { updates.append($0) }
        observerUpdate?(.partialSuccess("SECRET_PROVIDER_PAYLOAD"))
        await waitUntil { updates.contains(.failure("HealthKit reconciliation failed")) }

        XCTAssertFalse(updates.contains { if case .partialSuccess = $0 { return true } else { return false } })
        XCTAssertFalse(updates.contains { if case .failure(let message) = $0 { return message.contains("SECRET_PROVIDER_PAYLOAD") } else { return false } })
    }

    private func makeClient(
        availability: @escaping () -> HealthKitAuthorizationState = { .readIndeterminate },
        status: @escaping ([HealthKitMetricID]) async -> HealthKitAuthorizationReport = { _ in .init(state: .requestRequired) },
        request: @escaping ([HealthKitMetricID]) async -> HealthKitAuthorizationReport = { _ in .init(state: .readIndeterminate, promptCompleted: true) },
        register: @escaping (HealthKitMetricID, @escaping HealthKitProductionClient.ObserverUpdate) throws -> Void = { _, _ in },
        stop: @escaping () -> Void = {},
        reconcile: @escaping ([HealthKitMetricID]) async -> HealthKitReconciliationReport = { _ in .init(results: []) },
        reconcileRemainder: (([HealthKitMetricID]) async -> HealthKitReconciliationReport)? = nil,
        stateReader: @escaping HealthKitProductionClient.StoredStateReader = { metrics in
            metrics.map(HealthKitStoredMetricState.empty(for:))
        }
    ) -> HealthKitProductionClient {
        HealthKitProductionClient(
            availability: availability,
            status: status,
            request: request,
            registerObserver: register,
            stopObservers: stop,
            reconcile: reconcile,
            reconcileRemainder: reconcileRemainder,
            stateReader: stateReader
        )
    }

    private func waitUntil(
        _ predicate: @escaping @MainActor () -> Bool,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async {
        for _ in 0..<100 {
            if predicate() { return }
            await Task.yield()
        }
        XCTFail("Timed out waiting for condition", file: file, line: line)
    }

    private func makeCoordinatorBackedClient(
        partialMetric: HealthKitMetricID? = nil,
        failingMetrics: Set<HealthKitMetricID> = [],
        delaysByMetric: [HealthKitMetricID: [UInt64]] = [:]
    ) throws -> HealthKitProductionClient {
        let now = Date(timeIntervalSinceReferenceDate: 700_000_000)
        var pages: [HealthKitMetricID: [HealthKitMetricSyncInput]] = [:]
        for (index, metric) in HealthKitIntegrationController.supportedMetrics.enumerated() {
            pages[metric] = [try bridgeTestInput(
                metric: metric,
                anchorByte: UInt8((index % 200) + 1),
                queryCompletedAt: now,
                partial: metric == partialMetric
            )]
        }
        let fake = BridgeSequenceHealthKitClient(
            pages: pages,
            failingMetrics: failingMetrics,
            delaysByMetric: delaysByMetric
        )
        let store = HealthKitAnchorStore(persistenceURL: nil)
        let coordinator = HealthKitReconciliationCoordinator(
            client: fake,
            store: store,
            timeout: 0.05,
            now: { now }
        )
        return makeClient(
            reconcile: { metrics in await coordinator.reconcileInitialPages(metrics: metrics) },
            reconcileRemainder: { metrics in await coordinator.reconcile(metrics: metrics) }
        )
    }

    private func bridgeTestInput(
        metric: HealthKitMetricID,
        anchorByte: UInt8,
        queryCompletedAt: Date,
        partial: Bool = false
    ) throws -> HealthKitMetricSyncInput {
        try HealthKitMetricSyncInput(
            metric: metric,
            additions: [],
            deletions: [],
            nextAnchor: try bridgeTestAnchor(anchorByte),
            queryCompletedAt: queryCompletedAt,
            partial: partial,
            readability: .established
        )
    }

    private func bridgeTestAnchor(_ byte: UInt8) throws -> HealthKitOpaqueAnchor {
#if canImport(HealthKit)
        let value = HKQueryAnchor(fromValue: Int(byte))
        return try HealthKitOpaqueAnchor(
            archivedData: NSKeyedArchiver.archivedData(withRootObject: value, requiringSecureCoding: true)
        )
#else
        return try HealthKitOpaqueAnchor(archivedData: Data([byte]))
#endif
    }
}

private actor BridgeSequenceHealthKitClient: HealthKitReconciliationClient {
    private var pages: [HealthKitMetricID: [HealthKitMetricSyncInput]]
    private let failingMetrics: Set<HealthKitMetricID>
    private let delaysByMetric: [HealthKitMetricID: [UInt64]]
    private var callCounts: [HealthKitMetricID: Int] = [:]

    init(
        pages: [HealthKitMetricID: [HealthKitMetricSyncInput]],
        failingMetrics: Set<HealthKitMetricID>,
        delaysByMetric: [HealthKitMetricID: [UInt64]]
    ) {
        self.pages = pages
        self.failingMetrics = failingMetrics
        self.delaysByMetric = delaysByMetric
    }

    func changes(
        for metric: HealthKitMetricID,
        from anchor: HealthKitOpaqueAnchor?
    ) async throws -> HealthKitMetricSyncInput {
        let index = callCounts[metric, default: 0]
        callCounts[metric] = index + 1
        let delay = delaysByMetric[metric].flatMap { $0.indices.contains(index) ? $0[index] : nil } ?? 0
        if delay > 0 {
            try await Task.sleep(nanoseconds: delay)
        }
        if failingMetrics.contains(metric) {
            throw HealthKitReconciliationFailure.client("SECRET_PROVIDER_PAYLOAD")
        }
        guard let metricPages = pages[metric], metricPages.indices.contains(index) else {
            throw HealthKitReconciliationFailure.client("SECRET_PROVIDER_PAYLOAD")
        }
        return metricPages[index]
    }
}
#endif
