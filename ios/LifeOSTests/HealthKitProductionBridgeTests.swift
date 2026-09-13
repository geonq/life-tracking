#if os(iOS)
import Foundation
import XCTest
#if canImport(HealthKit)
import HealthKit
#endif
@testable import LifeOS

@MainActor
final class HealthKitProductionBridgeTests: XCTestCase {
    func testDelegatesAvailabilityStatusAndRequestWithoutChangingReadTruth() async {
        let statusMetrics = LockedTestValue<[HealthKitMetricID]>([])
        let requestMetrics = LockedTestValue<[HealthKitMetricID]>([])
        let client = makeClient(
            availability: { .restricted },
            status: { metrics in
                statusMetrics.replace(metrics)
                return .init(state: .requestRequired)
            },
            request: { metrics in
                requestMetrics.replace(metrics)
                return .init(state: .readIndeterminate, promptCompleted: true)
            }
        )

        XCTAssertEqual(client.availabilityState(), .restricted)
        let statusReport = await client.requestStatus(for: HealthKitIntegrationController.supportedMetrics)
        let requestReport = await client.requestReadAuthorization(for: HealthKitIntegrationController.supportedMetrics)
        XCTAssertEqual(statusReport.state, .requestRequired)
        XCTAssertEqual(requestReport.state, .readIndeterminate)
        XCTAssertEqual(statusMetrics.read(), HealthKitIntegrationController.supportedMetrics)
        XCTAssertEqual(requestMetrics.read(), HealthKitIntegrationController.supportedMetrics)
    }

    func testTypedWriteAuthorizationAndSavePathUseOnlyReviewedMetrics() async throws {
        let statusMetrics = LockedTestValue<[HealthKitWriteMetric]>([])
        let authorizationMetrics = LockedTestValue<[HealthKitWriteMetric]>([])
        let savedRequest = LockedTestValue<HealthKitWriteRequest?>(nil)
        let client = makeClient(
            writeStatus: { metric in
                statusMetrics.mutate { $0.append(metric) }
                return .writeAuthorized
            },
            writeRequest: { metrics in
                authorizationMetrics.replace(metrics)
                return .init(state: .writeAuthorized, promptCompleted: true)
            },
            write: { request in
                savedRequest.replace(request)
                return .saved(for: request.metric)
            }
        )

        let writable = HealthKitIntegrationController.writableMetrics
        let request = try makeWriteRequest()
        let authorization = await client.requestWriteAuthorization(for: writable)
        let result = await client.write(request)

        XCTAssertEqual(authorization.state, .writeAuthorized)
        XCTAssertEqual(authorizationMetrics.read(), writable)
        XCTAssertEqual(statusMetrics.read(), [.water])
        XCTAssertEqual(savedRequest.read(), request)
        XCTAssertEqual(result, .saved(for: .water))
    }

    func testInvalidWriteMetricSetIsRejectedBeforeAuthorizationClosure() async {
        let calls = LockedTestValue(0)
        let client = makeClient(writeRequest: { _ in
            calls.mutate { $0 += 1 }
            return .init(state: .writeAuthorized, promptCompleted: true)
        })

        let report = await client.requestWriteAuthorization(for: [.water])

        XCTAssertEqual(report.state, .error)
        XCTAssertEqual(report.errorDescription, "HealthKit write metric configuration was rejected")
        XCTAssertEqual(calls.read(), 0)
    }

    func testDeniedWriteIsBlockedBeforeInjectedSaveClosure() async throws {
        let calls = LockedTestValue(0)
        let client = makeClient(
            writeStatus: { _ in .writeDenied },
            write: { _ in
                calls.mutate { $0 += 1 }
                return .saved(for: .water)
            }
        )

        let result = await client.write(try makeWriteRequest())

        XCTAssertEqual(result.authorizationState, .writeDenied)
        XCTAssertFalse(result.didSave)
        XCTAssertEqual(calls.read(), 0)
    }

    func testWriteFailureIsSanitizedAndNeverReportsSuccess() async throws {
        let sentinel = "SECRET_PROVIDER_PAYLOAD"
        let client = makeClient(
            writeStatus: { _ in .writeAuthorized },
            write: { request in
                .rejected(
                    for: request.metric,
                    state: .writeAuthorized,
                    errorDescription: sentinel
                )
            }
        )

        let result = await client.write(try makeWriteRequest())

        XCTAssertFalse(result.didSave)
        XCTAssertEqual(result.errorDescription, "HealthKit write failed")
        XCTAssertFalse(result.errorDescription?.contains(sentinel) ?? true)
    }

    func testContradictorySuccessfulWriteIsRejected() async throws {
        let client = makeClient(
            writeStatus: { _ in .writeAuthorized },
            write: { request in
                HealthKitWriteReport(
                    metric: request.metric,
                    authorizationState: .writeAuthorized,
                    didSave: true,
                    errorDescription: "provider error"
                )
            }
        )

        let result = await client.write(try makeWriteRequest())

        XCTAssertFalse(result.didSave)
        XCTAssertEqual(result.authorizationState, HealthKitAuthorizationState.error)
        XCTAssertEqual(result.errorDescription, "HealthKit write failed")
    }

    func testStartRegistersEverySupportedMetricAndReportsInitialReconciliation() async {
        let registered = LockedTestValue<[HealthKitMetricID]>([])
        let reconciled = LockedTestValue<[HealthKitMetricID]>([])
        let updates = LockedTestValue<[HealthKitObserverCompletion]>([])
        let client = makeClient(
            register: { metric, _ in registered.mutate { $0.append(metric) } },
            reconcile: { metrics in
                reconciled.replace(metrics)
                return HealthKitReconciliationReport(results: [])
            }
        )

        client.startObservers(metrics: HealthKitIntegrationController.supportedMetrics) { completion in
            updates.mutate { $0.append(completion) }
        }
        await waitUntil { updates.read() == [.success] }

        XCTAssertEqual(registered.read(), HealthKitIntegrationController.supportedMetrics)
        XCTAssertEqual(reconciled.read(), HealthKitIntegrationController.supportedMetrics)
        XCTAssertFalse(registered.read().contains(.alcoholicBeverages))
    }

    func testPartialRegistrationFailureStopsEverythingAndRemainsRestartable() async {
        let stopCount = LockedTestValue(0)
        let shouldFail = LockedTestValue(true)
        let registered = LockedTestValue<[HealthKitMetricID]>([])
        let updates = LockedTestValue<[HealthKitObserverCompletion]>([])
        let client = makeClient(
            register: { metric, _ in
                let registrationCount = registered.mutate {
                    $0.append(metric)
                    return $0.count
                }
                if shouldFail.read() && registrationCount == 3 {
                    throw HealthKitAdapterError.unavailable
                }
            },
            stop: { stopCount.mutate { $0 += 1 } }
        )

        client.startObservers(metrics: HealthKitIntegrationController.supportedMetrics) { completion in
            updates.mutate { $0.append(completion) }
        }
        XCTAssertEqual(updates.read(), [.failure("HealthKit is unavailable on this device")])
        XCTAssertEqual(stopCount.read(), 1) // partial-failure cleanup

        shouldFail.replace(false)
        registered.replace([])
        client.startObservers(metrics: HealthKitIntegrationController.supportedMetrics) { completion in
            updates.mutate { $0.append(completion) }
        }
        await waitUntil { updates.read().last == .success }
        XCTAssertEqual(registered.read(), HealthKitIntegrationController.supportedMetrics)
    }

    func testStopCancelsInitialReconcileAndSuppressesLateCompletion() async {
        let stopCount = LockedTestValue(0)
        let continuation = LockedTestValue<CheckedContinuation<HealthKitReconciliationReport, Never>?>(nil)
        let updates = LockedTestValue<[HealthKitObserverCompletion]>([])
        let client = makeClient(
            stop: { stopCount.mutate { $0 += 1 } },
            reconcile: { _ in
                await withCheckedContinuation { continuation.replace($0) }
            }
        )

        client.startObservers(metrics: HealthKitIntegrationController.supportedMetrics) { completion in
            updates.mutate { $0.append(completion) }
        }
        await waitUntil { continuation.read() != nil }
        client.stopAllObservers()
        continuation.read()?.resume(returning: HealthKitReconciliationReport(results: []))
        await Task.yield()

        XCTAssertTrue(updates.read().isEmpty)
        XCTAssertEqual(stopCount.read(), 1)
    }

    func testInvalidOrAlcoholMetricSetIsRejectedBeforeRegistration() {
        let registered = LockedTestValue(0)
        let update = LockedTestValue<HealthKitObserverCompletion?>(nil)
        let client = makeClient(register: { _, _ in registered.mutate { $0 += 1 } })
        client.startObservers(metrics: [.water, .alcoholicBeverages]) { update.replace($0) }
        XCTAssertEqual(registered.read(), 0)
        XCTAssertEqual(update.read(), .failure("HealthKit metric configuration was rejected"))
    }

    func testInvalidMetricSetIsRejectedBeforeStatusOrAuthorization() async {
        let statusCalls = LockedTestValue(0)
        let requestCalls = LockedTestValue(0)
        let client = makeClient(
            status: { _ in
                statusCalls.mutate { $0 += 1 }
                return .init(state: .requestRequired)
            },
            request: { _ in
                requestCalls.mutate { $0 += 1 }
                return .init(state: .readIndeterminate, promptCompleted: true)
            }
        )

        let invalid: [HealthKitMetricID] = [.water, .alcoholicBeverages]
        let status = await client.requestStatus(for: invalid)
        let request = await client.requestReadAuthorization(for: invalid)

        XCTAssertEqual(statusCalls.read(), 0)
        XCTAssertEqual(requestCalls.read(), 0)
        XCTAssertEqual(status.state, .error)
        XCTAssertEqual(request.state, .error)
        XCTAssertEqual(status.errorDescription, "HealthKit metric configuration was rejected")
        XCTAssertEqual(request.errorDescription, "HealthKit metric configuration was rejected")
    }

    func testStoredStatesUsesInjectedReaderAndReturnsRequestedOrder() async {
        let readerMetrics = LockedTestValue<[HealthKitMetricID]>([])
        let expected = HealthKitIntegrationController.supportedMetrics
            .map(HealthKitStoredMetricState.empty(for:))
        let client = makeClient(stateReader: { metrics in
            readerMetrics.replace(metrics)
            return Array(expected.reversed())
        })

        let states = await client.storedStates(for: expected.map(\.metric))

        XCTAssertEqual(readerMetrics.read(), expected.map(\.metric))
        XCTAssertEqual(states.map(\.metric), expected.map(\.metric))
        XCTAssertEqual(states, expected)
    }

    func testStoredStatesRejectsInvalidAndAlcoholSetsWithoutReading() async {
        let readerCalls = LockedTestValue(0)
        let client = makeClient(stateReader: { _ in
            readerCalls.mutate { $0 += 1 }
            return []
        })

        let invalid: [HealthKitMetricID] = [.water, .alcoholicBeverages]
        let states = await client.storedStates(for: invalid)

        XCTAssertTrue(states.isEmpty)
        XCTAssertEqual(readerCalls.read(), 0)
    }

    func testStoredStatesPreservesErrorAndEmptyTruth() async {
        let metrics = HealthKitIntegrationController.supportedMetrics
        let errorProjection = try! HealthKitMetricProjection(
            metric: metrics[0],
            lastCommittedAt: Date(timeIntervalSinceReferenceDate: 0),
            syncState: .error
        )
        let errorState = HealthKitStoredMetricState(projection: errorProjection)
        let provided = metrics.enumerated().map { index, metric in
            index == 0 ? errorState : .empty(for: metric)
        }
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
        let reconciliationCalls = LockedTestValue(0)
        let updates = LockedTestValue<[HealthKitObserverCompletion]>([])
        let client = makeClient(reconcile: { _ in
            reconciliationCalls.mutate { $0 += 1 }
            return .init(results: [])
        })

        client.startObservers(metrics: HealthKitIntegrationController.supportedMetrics) { completion in
            updates.mutate { $0.append(completion) }
        }
        client.stopAllObservers()
        await Task.yield()

        XCTAssertEqual(reconciliationCalls.read(), 0)
        XCTAssertTrue(updates.read().isEmpty)
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

        let updates = LockedTestValue<[HealthKitObserverCompletion]>([])
        client.startObservers(metrics: HealthKitIntegrationController.supportedMetrics) { completion in
            updates.mutate { $0.append(completion) }
        }
        await waitUntil { !updates.read().isEmpty }
        XCTAssertEqual(updates.read(), [.failure("HealthKit reconciliation failed")])
    }

    func testMixedAggregateKeepsSanitizedFailureWhileReportingDurablePartialSuccess() async {
        let client = try! makeCoordinatorBackedClient(failingMetrics: [.caffeine])

        let updates = LockedTestValue<[HealthKitObserverCompletion]>([])
        client.startObservers(metrics: HealthKitIntegrationController.supportedMetrics) { completion in
            updates.mutate { $0.append(completion) }
        }
        await waitUntil { !updates.read().isEmpty }

        XCTAssertEqual(
            updates.read(),
            [.partialSuccess("HealthKit reconciliation partially failed after a durable metric commit")]
        )
        XCTAssertFalse(updates.read().description.contains("SECRET_PROVIDER_PAYLOAD"))
    }

    func testTimedOutAggregateWithDurableCommitIsPartialAndSanitized() async {
        let client = try! makeCoordinatorBackedClient(delaysByMetric: [.caffeine: [300_000_000]])

        let updates = LockedTestValue<[HealthKitObserverCompletion]>([])
        client.startObservers(metrics: HealthKitIntegrationController.supportedMetrics) { completion in
            updates.mutate { $0.append(completion) }
        }
        await waitUntil { !updates.read().isEmpty }

        XCTAssertEqual(
            updates.read(),
            [.partialSuccess("HealthKit reconciliation timed out after a durable metric commit")]
        )
    }

    func testInitialDurablePageMakesLaterRemainderFailurePartial() async {
        let client = try! makeCoordinatorBackedClient(
            partialMetric: .water,
            delaysByMetric: [.water: [0, 300_000_000]]
        )

        let updates = LockedTestValue<[HealthKitObserverCompletion]>([])
        client.startObservers(metrics: HealthKitIntegrationController.supportedMetrics) { completion in
            updates.mutate { $0.append(completion) }
        }
        await waitUntil { updates.read() == [.success] }
        try? await Task.sleep(nanoseconds: 2_100_000_000)
        await waitUntil { updates.read().count == 2 }

        XCTAssertEqual(
            updates.read()[1],
            .partialSuccess("HealthKit reconciliation timed out after a durable metric commit")
        )
    }

    func testObserverCallbackErrorIsSanitized() async {
        let sentinel = "SECRET_PROVIDER_PAYLOAD"
        let observerUpdate = LockedTestValue<HealthKitProductionClient.ObserverUpdate?>(nil)
        let updates = LockedTestValue<[HealthKitObserverCompletion]>([])
        let client = makeClient(register: { _, update in observerUpdate.replace(update) })

        client.startObservers(metrics: HealthKitIntegrationController.supportedMetrics) { completion in
            updates.mutate { $0.append(completion) }
        }
        observerUpdate.read()?(.failure(sentinel))
        await waitUntil { updates.read().contains(.failure("HealthKit reconciliation failed")) }

        XCTAssertFalse(updates.read().contains(.failure(sentinel)))
    }

    func testObserverCallbackCannotTurnMetricPartialOutcomeIntoDurableRefresh() async {
        let observerUpdate = LockedTestValue<HealthKitProductionClient.ObserverUpdate?>(nil)
        let updates = LockedTestValue<[HealthKitObserverCompletion]>([])
        let client = makeClient(register: { _, update in observerUpdate.replace(update) })

        client.startObservers(metrics: HealthKitIntegrationController.supportedMetrics) { completion in
            updates.mutate { $0.append(completion) }
        }
        observerUpdate.read()?(.partialSuccess("SECRET_PROVIDER_PAYLOAD"))
        await waitUntil { updates.read().contains(.failure("HealthKit reconciliation failed")) }

        XCTAssertFalse(updates.read().contains { if case .partialSuccess = $0 { return true } else { return false } })
        XCTAssertFalse(updates.read().contains { if case .failure(let message) = $0 { return message.contains("SECRET_PROVIDER_PAYLOAD") } else { return false } })
    }

    func testRepeatedStartKeepsOneObserverSetAndRefreshesAgain() async {
        let registrations = LockedTestValue<[HealthKitMetricID]>([])
        let reconciliationCalls = LockedTestValue(0)
        let client = makeClient(
            register: { metric, _ in registrations.mutate { $0.append(metric) } },
            reconcile: { _ in
                reconciliationCalls.mutate { $0 += 1 }
                return .init(results: [])
            }
        )

        client.startObservers(metrics: HealthKitIntegrationController.supportedMetrics) { _ in }
        await waitUntil { reconciliationCalls.read() == 1 }
        client.startObservers(metrics: HealthKitIntegrationController.supportedMetrics) { _ in }
        await waitUntil { reconciliationCalls.read() == 2 }

        XCTAssertEqual(registrations.read(), HealthKitIntegrationController.supportedMetrics)
    }

    func testTimedOutObserverInvalidatesPartialSetAndNextStartReinstallsAll() async {
        let registrations = LockedTestValue<[HealthKitMetricID]>([])
        let observerCallbacks = LockedTestValue<[HealthKitProductionClient.ObserverUpdate]>([])
        let stopCount = LockedTestValue(0)
        let client = makeClient(
            register: { metric, callback in
                registrations.mutate { $0.append(metric) }
                observerCallbacks.mutate { $0.append(callback) }
            },
            stop: { stopCount.mutate { $0 += 1 } }
        )

        client.startObservers(metrics: HealthKitIntegrationController.supportedMetrics) { _ in }
        observerCallbacks.read()[0](.timedOut)
        await waitUntil { stopCount.read() == 1 }

        XCTAssertEqual(stopCount.read(), 1)
        registrations.replace([])
        client.startObservers(metrics: HealthKitIntegrationController.supportedMetrics) { _ in }

        XCTAssertEqual(registrations.read(), HealthKitIntegrationController.supportedMetrics)
    }

    func testBackgroundDeliveryConfigurationIsValidatedSanitizedAndCached() async {
        let calls = LockedTestValue(0)
        let metrics = HealthKitIntegrationController.supportedMetrics
        let client = makeClient(configureBackground: { requested in
            calls.mutate { $0 += 1 }
            return .enabled(requested)
        })

        let first = await client.configureBackgroundDelivery(metrics: metrics)
        let second = await client.configureBackgroundDelivery(metrics: metrics)

        XCTAssertEqual(first, .enabled(metrics))
        XCTAssertEqual(second, first)
        XCTAssertEqual(calls.read(), 1)
    }

    func testMalformedOrUnsupportedBackgroundDeliveryReportFailsClosed() async {
        let metrics = HealthKitIntegrationController.supportedMetrics
        let calls = LockedTestValue(0)
        let client = makeClient(configureBackground: { _ in
            calls.mutate { $0 += 1 }
            return HealthKitBackgroundDeliveryReport(
                state: .enabled,
                enabledMetrics: [.alcoholicBeverages]
            )
        })

        let malformed = await client.configureBackgroundDelivery(metrics: metrics)
        let unsupported = await client.configureBackgroundDelivery(metrics: [.alcoholicBeverages])

        XCTAssertEqual(malformed, .failed(metrics))
        XCTAssertEqual(unsupported, .failed([.alcoholicBeverages]))
        XCTAssertEqual(calls.read(), 1)
    }

    private func makeClient(
        availability: @escaping () -> HealthKitAuthorizationState = { .readIndeterminate },
        status: @escaping ([HealthKitMetricID]) async -> HealthKitAuthorizationReport = { _ in .init(state: .requestRequired) },
        request: @escaping ([HealthKitMetricID]) async -> HealthKitAuthorizationReport = { _ in .init(state: .readIndeterminate, promptCompleted: true) },
        writeStatus: @escaping (HealthKitWriteMetric) -> HealthKitAuthorizationState = { _ in .writeNotDetermined },
        writeRequest: @escaping ([HealthKitWriteMetric]) async -> HealthKitAuthorizationReport = { _ in .init(state: .writeNotDetermined) },
        write: @escaping (HealthKitWriteRequest) async -> HealthKitWriteReport = { request in .rejected(for: request.metric, state: .writeNotDetermined) },
        configureBackground: @escaping ([HealthKitMetricID]) async -> HealthKitBackgroundDeliveryReport = {
            .enabled($0)
        },
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
            writeStatus: writeStatus,
            writeRequest: writeRequest,
            write: write,
            configureBackground: configureBackground,
            registerObserver: register,
            stopObservers: stop,
            reconcile: reconcile,
            reconcileRemainder: reconcileRemainder,
            stateReader: stateReader
        )
    }

    private func makeWriteRequest() throws -> HealthKitWriteRequest {
        let now = Date(timeIntervalSinceReferenceDate: 700_000_000)
        return try HealthKitWriteRequest(
            metric: .water,
            value: 250,
            startDate: now,
            endDate: now,
            now: now
        )
    }

    private func waitUntil(
        _ predicate: @escaping @MainActor () -> Bool,
        timeout: Duration = .seconds(2),
        file: StaticString = #filePath,
        line: UInt = #line
    ) async {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: timeout)
        while clock.now < deadline {
            if predicate() { return }
            try? await Task.sleep(for: .milliseconds(1))
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

/// Synchronous, lock-protected state for callbacks that are allowed to run
/// concurrently with the main-actor test method. Capturing this reference in
/// an injected `@Sendable` callback is safe; the mutable value never escapes
/// without holding the lock.
private final class LockedTestValue<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Value

    init(_ value: Value) {
        self.value = value
    }

    func read() -> Value {
        lock.lock()
        defer { lock.unlock() }
        return value
    }

    func replace(_ value: Value) {
        lock.lock()
        self.value = value
        lock.unlock()
    }

    @discardableResult
    func mutate<Result>(_ mutation: (inout Value) -> Result) -> Result {
        lock.lock()
        defer { lock.unlock() }
        return mutation(&value)
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
