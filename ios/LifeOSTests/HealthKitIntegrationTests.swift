#if os(iOS)
import XCTest
@testable import LifeOS

@MainActor
final class HealthKitIntegrationTests: XCTestCase {
    func testSupportedMetricsExactlyExcludeAlcohol() {
        let expected = HealthKitMetricID.allCases.filter { $0 != .alcoholicBeverages }
        XCTAssertEqual(HealthKitIntegrationController.supportedMetrics, expected)
        XCTAssertFalse(HealthKitIntegrationController.supportedMetrics.contains(.alcoholicBeverages))
    }

    func testFixtureModeNeverCallsClient() async {
        let client = RecordingHealthKitIntegrationClient()
        let controller = HealthKitIntegrationController(client: client, usesVisualFixtures: true)

        await controller.refreshStatus()
        _ = await controller.requestReadAuthorization()
        controller.appActive()
        controller.appInactive()

        XCTAssertEqual(client.availabilityCalls, 0)
        XCTAssertEqual(client.statusCalls, 0)
        XCTAssertEqual(client.authorizationCalls, 0)
        XCTAssertEqual(client.startCalls, 0)
        XCTAssertEqual(client.stopCalls, 0)
    }

    func testPersistedPromptCompletionRestoresIndeterminateTruthAndStartsWhenActive() async {
        let client = RecordingHealthKitIntegrationClient()
        let controller = HealthKitIntegrationController(
            client: client,
            initialExplicitRequestCompleted: true
        )

        XCTAssertEqual(controller.snapshot.authorizationState, .readIndeterminate)
        XCTAssertTrue(controller.snapshot.explicitRequestCompleted)
        XCTAssertEqual(client.startCalls, 0)

        controller.appActive()
        await waitUntil { client.startCalls == 1 }
    }

    func testPersistedPromptDoesNotHideDeviceLevelRestriction() async {
        let client = RecordingHealthKitIntegrationClient()
        client.availabilityResult = .restricted
        let controller = HealthKitIntegrationController(
            client: client,
            initialExplicitRequestCompleted: true
        )

        await controller.refreshStatus()

        XCTAssertEqual(controller.snapshot.authorizationState, .restricted)
        XCTAssertTrue(controller.snapshot.explicitRequestCompleted)
        XCTAssertEqual(client.statusCalls, 0)
    }

    func testPersistedPromptStopsActiveObserversWhenStatusBecomesTerminal() async {
        let client = RecordingHealthKitIntegrationClient()
        let controller = HealthKitIntegrationController(
            client: client,
            initialExplicitRequestCompleted: true
        )

        controller.appActive()
        await waitUntil { client.startCalls == 1 }

        client.availabilityResult = .restricted
        await controller.refreshStatus()

        XCTAssertEqual(controller.snapshot.authorizationState, .restricted)
        XCTAssertTrue(controller.snapshot.isActive)
        XCTAssertEqual(client.stopCalls, 1)
    }

    func testPersistedPromptRestartsObserversAfterTerminalStatusRecovers() async {
        let client = RecordingHealthKitIntegrationClient()
        let controller = HealthKitIntegrationController(
            client: client,
            initialExplicitRequestCompleted: true
        )

        controller.appActive()
        await waitUntil { client.startCalls == 1 }

        client.availabilityResult = .restricted
        await controller.refreshStatus()
        XCTAssertEqual(client.stopCalls, 1)

        client.availabilityResult = .readIndeterminate
        client.statusResult = .init(state: .readIndeterminate)
        await controller.refreshStatus()

        XCTAssertEqual(controller.snapshot.authorizationState, .readIndeterminate)
        XCTAssertTrue(controller.snapshot.explicitRequestCompleted)
        XCTAssertEqual(client.startCalls, 2)
        XCTAssertEqual(client.stopCalls, 1)
    }

    func testPersistedPromptStillRejectsFalseRequestRequiredDowngrade() async {
        let client = RecordingHealthKitIntegrationClient()
        client.statusResult = .init(state: .requestRequired)
        let controller = HealthKitIntegrationController(
            client: client,
            initialExplicitRequestCompleted: true
        )

        await controller.refreshStatus()

        XCTAssertEqual(controller.snapshot.authorizationState, .readIndeterminate)
        XCTAssertTrue(controller.snapshot.explicitRequestCompleted)
    }

    func testFixtureModeIgnoresPersistedPromptCompletion() {
        let client = RecordingHealthKitIntegrationClient()
        let controller = HealthKitIntegrationController(
            client: client,
            usesVisualFixtures: true,
            initialExplicitRequestCompleted: true
        )

        XCTAssertEqual(controller.snapshot.authorizationState, .notRequested)
        XCTAssertFalse(controller.snapshot.explicitRequestCompleted)
        controller.appActive()
        XCTAssertEqual(client.startCalls, 0)
    }

    func testInitAndStatusRefreshNeverPromptOrQuerySamples() async {
        let client = RecordingHealthKitIntegrationClient()
        let controller = HealthKitIntegrationController(client: client)

        XCTAssertEqual(client.authorizationCalls, 0)
        XCTAssertEqual(client.startCalls, 0)
        await controller.refreshStatus()

        XCTAssertEqual(client.availabilityCalls, 1)
        XCTAssertEqual(client.statusCalls, 1)
        XCTAssertEqual(client.authorizationCalls, 0)
        XCTAssertEqual(client.startCalls, 0)
    }

    func testSettingsProjectionPreservesReadIndeterminateTruth() {
        let snapshot = HealthKitIntegrationSnapshot(
            authorizationState: .readIndeterminate,
            lifecycle: .active,
            explicitRequestCompleted: true
        )

        let settings = HealthReadAccessSettings.from(snapshot: snapshot)

        XCTAssertEqual(settings.state, .readIndeterminate)
        XCTAssertEqual(settings.title, "Read request completed")
        XCTAssertTrue(settings.detail.contains("Empty reads"))
    }

    func testExplicitRequestMapsSuccessfulPromptToReadIndeterminate() async {
        let client = RecordingHealthKitIntegrationClient()
        client.authorizationResult = HealthKitAuthorizationReport(
            state: .requestRequired,
            promptCompleted: true
        )
        let controller = HealthKitIntegrationController(client: client)

        let result = await controller.requestReadAuthorization()

        XCTAssertEqual(result.state, .readIndeterminate)
        XCTAssertEqual(result.promptCompleted, true)
        XCTAssertEqual(controller.snapshot.authorizationState, .readIndeterminate)
        XCTAssertTrue(controller.snapshot.explicitRequestCompleted)
        XCTAssertEqual(client.authorizationCalls, 1)
    }

    func testDuplicateExplicitRequestsSuppressPrompt() async {
        let client = RecordingHealthKitIntegrationClient()
        client.holdAuthorization = true
        let controller = HealthKitIntegrationController(client: client)

        let first = Task { @MainActor in await controller.requestReadAuthorization() }
        await waitUntil { client.authorizationCalls == 1 }
        let second = Task { @MainActor in await controller.requestReadAuthorization() }
        await Task.yield()

        XCTAssertEqual(client.authorizationCalls, 1)
        client.finishAuthorization(
            HealthKitAuthorizationReport(state: .requestRequired, promptCompleted: true)
        )
        let firstResult = await first.value
        let secondResult = await second.value

        XCTAssertEqual(firstResult.state, .readIndeterminate)
        XCTAssertEqual(secondResult.state, .readIndeterminate)
        XCTAssertEqual(client.authorizationCalls, 1)
    }

    func testObserversAreActiveOnlyAndRestartAfterBackground() async {
        let client = RecordingHealthKitIntegrationClient()
        client.authorizationResult = HealthKitAuthorizationReport(state: .requestRequired, promptCompleted: true)
        let controller = HealthKitIntegrationController(client: client)

        controller.appActive()
        await Task.yield()
        XCTAssertEqual(client.startCalls, 0)

        _ = await controller.requestReadAuthorization()
        await waitUntil { client.startCalls == 1 }
        controller.appActive()
        await Task.yield()
        XCTAssertEqual(client.startCalls, 1)

        controller.appInactive()
        XCTAssertEqual(client.stopCalls, 1)
        XCTAssertFalse(controller.snapshot.isActive)

        controller.appActive()
        await waitUntil { client.startCalls == 2 }
        XCTAssertTrue(controller.snapshot.isActive)
    }

    func testStaleObserverCompletionIsIgnoredAfterRestart() async {
        let client = RecordingHealthKitIntegrationClient()
        client.authorizationResult = HealthKitAuthorizationReport(state: .requestRequired, promptCompleted: true)
        let controller = HealthKitIntegrationController(client: client)

        controller.appActive()
        _ = await controller.requestReadAuthorization()
        await waitUntil { client.startCalls == 1 && client.callbacks.count == 1 }
        let oldCallback = client.callbacks[0]

        controller.appInactive()
        controller.appActive()
        await waitUntil { client.startCalls == 2 && client.callbacks.count == 2 }
        let currentCallback = client.callbacks[1]

        oldCallback(.success)
        await Task.yield()
        XCTAssertNil(controller.snapshot.lastObserverCompletion)

        currentCallback(.failure("current session"))
        await Task.yield()
        XCTAssertEqual(controller.snapshot.lastObserverCompletion, .failure("current session"))
    }

    func testStaleAuthorizationCompletionIsIgnoredAfterBackground() async {
        let client = RecordingHealthKitIntegrationClient()
        client.holdAuthorization = true
        let controller = HealthKitIntegrationController(client: client)

        let request = Task { @MainActor in await controller.requestReadAuthorization() }
        await waitUntil { client.authorizationCalls == 1 }
        controller.applicationDidEnterBackground()
        XCTAssertFalse(controller.snapshot.isRequestInFlight)

        client.finishAuthorization(
            HealthKitAuthorizationReport(state: .requestRequired, promptCompleted: true)
        )
        _ = await request.value
        await Task.yield()

        XCTAssertEqual(controller.snapshot.authorizationState, .notRequested)
        XCTAssertFalse(controller.snapshot.explicitRequestCompleted)
        XCTAssertEqual(client.startCalls, 0)
    }

    func testInactiveSystemSheetPreservesAuthorizationCompletionUntilActive() async {
        let client = RecordingHealthKitIntegrationClient()
        client.holdAuthorization = true
        let controller = HealthKitIntegrationController(client: client)
        controller.appActive()

        let request = Task { @MainActor in await controller.requestReadAuthorization() }
        await waitUntil { client.authorizationCalls == 1 }
        controller.appInactive()
        XCTAssertTrue(controller.snapshot.isRequestInFlight)

        client.finishAuthorization(
            HealthKitAuthorizationReport(state: .requestRequired, promptCompleted: true)
        )
        _ = await request.value
        XCTAssertTrue(controller.snapshot.explicitRequestCompleted)
        XCTAssertEqual(controller.snapshot.authorizationState, .readIndeterminate)
        XCTAssertEqual(client.startCalls, 0)

        controller.appActive()
        await waitUntil { client.startCalls == 1 }
    }

    func testSuccessfulAuthorizationRetryClearsPriorError() async {
        let client = RecordingHealthKitIntegrationClient()
        client.authorizationResult = HealthKitAuthorizationReport(
            state: .readIndeterminate,
            promptCompleted: false,
            errorDescription: "temporary failure"
        )
        let controller = HealthKitIntegrationController(client: client)

        _ = await controller.requestReadAuthorization()
        XCTAssertEqual(controller.snapshot.errorDescription, "temporary failure")

        client.authorizationResult = HealthKitAuthorizationReport(
            state: .requestRequired,
            promptCompleted: true
        )
        _ = await controller.requestReadAuthorization()
        XCTAssertNil(controller.snapshot.errorDescription)
        XCTAssertTrue(controller.snapshot.explicitRequestCompleted)
    }

    func testRestartClearsPriorObserverCompletion() async {
        let client = RecordingHealthKitIntegrationClient()
        client.authorizationResult = HealthKitAuthorizationReport(state: .requestRequired, promptCompleted: true)
        let controller = HealthKitIntegrationController(client: client)

        controller.appActive()
        _ = await controller.requestReadAuthorization()
        await waitUntil { client.callbacks.count == 1 }
        client.callbacks[0](.failure("old session"))
        await Task.yield()
        XCTAssertEqual(controller.snapshot.lastObserverCompletion, .failure("old session"))

        controller.appInactive()
        XCTAssertNil(controller.snapshot.lastObserverCompletion)
        controller.appActive()
        XCTAssertNil(controller.snapshot.lastObserverCompletion)
    }

    func testDefaultPersistenceURLIsAppPrivateLifeOSProjectionPath() {
        let controller = HealthKitIntegrationController()
        let url = controller.persistenceURL

        XCTAssertEqual(url.lastPathComponent, "healthkit-projection.json")
        XCTAssertEqual(url.deletingLastPathComponent().lastPathComponent, "LifeOS")
        XCTAssertFalse(url.path.contains("group.com"))
        if let applicationSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first {
            XCTAssertTrue(url.path.hasPrefix(applicationSupport.path))
        }
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

@MainActor
private final class RecordingHealthKitIntegrationClient: HealthKitIntegrationClient {
    var availabilityResult: HealthKitAuthorizationState = .readIndeterminate
    var statusResult: HealthKitAuthorizationReport = .init(state: .requestRequired)
    var authorizationResult: HealthKitAuthorizationReport = .init(state: .requestRequired)
    var holdAuthorization = false
    var availabilityCalls = 0
    var statusCalls = 0
    var authorizationCalls = 0
    var startCalls = 0
    var stopCalls = 0
    var callbacks: [(HealthKitObserverCompletion) -> Void] = []
    private var authorizationContinuation: CheckedContinuation<HealthKitAuthorizationReport, Never>?

    func availabilityState() -> HealthKitAuthorizationState {
        availabilityCalls += 1
        return availabilityResult
    }

    func requestStatus(for metrics: [HealthKitMetricID]) async -> HealthKitAuthorizationReport {
        XCTAssertEqual(metrics, HealthKitIntegrationController.supportedMetrics)
        statusCalls += 1
        return statusResult
    }

    func requestReadAuthorization(for metrics: [HealthKitMetricID]) async -> HealthKitAuthorizationReport {
        XCTAssertEqual(metrics, HealthKitIntegrationController.supportedMetrics)
        authorizationCalls += 1
        if holdAuthorization {
            return await withCheckedContinuation { continuation in
                authorizationContinuation = continuation
            }
        }
        return authorizationResult
    }

    func startObservers(
        metrics: [HealthKitMetricID],
        onUpdate: @escaping @Sendable (HealthKitObserverCompletion) -> Void
    ) {
        XCTAssertEqual(metrics, HealthKitIntegrationController.supportedMetrics)
        startCalls += 1
        callbacks.append(onUpdate)
    }

    func stopAllObservers() { stopCalls += 1 }

    func finishAuthorization(_ result: HealthKitAuthorizationReport) {
        authorizationContinuation?.resume(returning: result)
        authorizationContinuation = nil
    }
}
#endif
