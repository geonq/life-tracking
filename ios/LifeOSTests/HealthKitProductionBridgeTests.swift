#if os(iOS)
import XCTest
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

    private func makeClient(
        availability: @escaping () -> HealthKitAuthorizationState = { .readIndeterminate },
        status: @escaping ([HealthKitMetricID]) async -> HealthKitAuthorizationReport = { _ in .init(state: .requestRequired) },
        request: @escaping ([HealthKitMetricID]) async -> HealthKitAuthorizationReport = { _ in .init(state: .readIndeterminate, promptCompleted: true) },
        register: @escaping (HealthKitMetricID, @escaping HealthKitProductionClient.ObserverUpdate) throws -> Void = { _, _ in },
        stop: @escaping () -> Void = {},
        reconcile: @escaping ([HealthKitMetricID]) async -> HealthKitReconciliationReport = { _ in .init(results: []) }
    ) -> HealthKitProductionClient {
        HealthKitProductionClient(
            availability: availability,
            status: status,
            request: request,
            registerObserver: register,
            stopObservers: stop,
            reconcile: reconcile
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
}
#endif
