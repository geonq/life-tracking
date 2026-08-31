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
        client.statusResult = .init(state: .readIndeterminate)
        let controller = HealthKitIntegrationController(
            client: client,
            initialExplicitRequestCompleted: true
        )

        XCTAssertEqual(controller.snapshot.authorizationState, .readIndeterminate)
        XCTAssertTrue(controller.snapshot.explicitRequestCompleted)
        XCTAssertEqual(client.startCalls, 0)

        controller.appActive()
        XCTAssertEqual(client.startCalls, 0)
        await controller.refreshStatus()
        await waitUntil { client.startCalls == 1 }
    }

    func testRequestNotNeededStartsIngestionWithoutPromptHistory() async {
        let client = RecordingHealthKitIntegrationClient()
        client.statusResult = .init(state: .readIndeterminate)
        let controller = HealthKitIntegrationController(client: client)

        controller.appActive()
        await controller.refreshStatus()

        XCTAssertFalse(controller.snapshot.explicitRequestCompleted)
        XCTAssertEqual(controller.snapshot.authorizationState, .readIndeterminate)
        await waitUntil { client.startCalls == 1 }
    }

    func testLaunchStatusInstallsAuthorizedObserversBeforeSceneBecomesActive() async {
        let client = RecordingHealthKitIntegrationClient()
        client.statusResult = .init(state: .readIndeterminate)
        let controller = HealthKitIntegrationController(client: client)

        controller.applicationLaunched()
        await waitUntil {
            client.startCalls == 1 &&
                controller.snapshot.backgroundDeliveryState == .enabled
        }

        XCTAssertFalse(controller.snapshot.isActive)
        XCTAssertEqual(client.authorizationCalls, 0)
        XCTAssertEqual(client.backgroundConfigurationCalls, 1)
    }

    func testRequestRequiredRemainsGatedWithoutStartingObservers() async {
        let client = RecordingHealthKitIntegrationClient()
        client.statusResult = .init(state: .requestRequired)
        let controller = HealthKitIntegrationController(client: client)

        controller.appActive()
        await controller.refreshStatus()

        XCTAssertEqual(controller.snapshot.authorizationState, .requestRequired)
        XCTAssertEqual(client.startCalls, 0)
        XCTAssertEqual(client.callbacks.count, 0)
    }

    func testReadAndWriteAuthorizationRemainSeparate() async {
        let client = RecordingHealthKitIntegrationClient()
        client.statusResult = .init(state: .readIndeterminate)
        client.writeAuthorizationResult = .writeAuthorized
        let controller = HealthKitIntegrationController(client: client)

        await controller.refreshStatus()

        XCTAssertEqual(controller.snapshot.authorizationState, .readIndeterminate)
        XCTAssertEqual(controller.snapshot.writeAuthorizationState, .writeAuthorized)
        XCTAssertEqual(client.writeStatusCalls, HealthKitIntegrationController.writableMetrics.count)
        XCTAssertEqual(client.authorizationCalls, 0)
        XCTAssertEqual(client.writeAuthorizationCalls, 0)
    }

    func testWriteAuthorizationDoesNotPromptWithoutExplicitUserAction() async {
        let client = RecordingHealthKitIntegrationClient()
        client.writeAuthorizationResult = .writeAuthorized
        client.writeAuthorizationReport = .init(state: .writeAuthorized, promptCompleted: true)
        let controller = HealthKitIntegrationController(client: client)

        let report = await controller.requestWriteAuthorization()

        XCTAssertEqual(report.state, .writeNotDetermined)
        XCTAssertEqual(controller.snapshot.writeAuthorizationState, .writeNotDetermined)
        XCTAssertEqual(client.writeAuthorizationCalls, 0)
    }

    func testWriteAuthorizationRequestUsesOnlyTypedWritableMetrics() async {
        let client = RecordingHealthKitIntegrationClient()
        client.writeAuthorizationResult = .writeAuthorized
        client.writeAuthorizationReport = .init(state: .writeAuthorized, promptCompleted: true)
        let controller = HealthKitIntegrationController(client: client)

        let report = await controller.requestWriteAuthorization(userInitiated: true)

        XCTAssertEqual(report.state, .writeAuthorized)
        XCTAssertEqual(report.promptCompleted, true)
        XCTAssertEqual(controller.snapshot.authorizationState, .notRequested)
        XCTAssertEqual(controller.snapshot.writeAuthorizationState, .writeAuthorized)
        XCTAssertEqual(client.writeAuthorizationMetrics, HealthKitIntegrationController.writableMetrics)
        XCTAssertEqual(client.writeAuthorizationCalls, 1)
    }

    func testWriteAuthorizationDenialRemainsDenied() async {
        let client = RecordingHealthKitIntegrationClient()
        client.writeAuthorizationResult = .writeDenied
        client.writeAuthorizationReport = .init(state: .writeDenied, promptCompleted: true)
        let controller = HealthKitIntegrationController(client: client)

        let report = await controller.requestWriteAuthorization(userInitiated: true)

        XCTAssertEqual(report.state, .writeDenied)
        XCTAssertEqual(controller.snapshot.writeAuthorizationState, .writeDenied)
    }

    func testUnavailableHealthKitDoesNotRequestOrWrite() async throws {
        let client = RecordingHealthKitIntegrationClient()
        client.availabilityResult = .unavailable
        client.writeAuthorizationResult = .unavailable
        let controller = HealthKitIntegrationController(client: client)

        await controller.refreshStatus()
        let authorization = await controller.requestWriteAuthorization()
        let result = await controller.write(try makeWriteRequest(), userInitiated: true)

        XCTAssertEqual(authorization.state, .unavailable)
        XCTAssertEqual(result.authorizationState, .unavailable)
        XCTAssertFalse(result.didSave)
        XCTAssertEqual(client.writeAuthorizationCalls, 0)
        XCTAssertEqual(client.writeCalls, 0)
    }

    func testAuthorizedWriteIsReportedOnlyWhenClientSaves() async throws {
        let client = RecordingHealthKitIntegrationClient()
        client.writeAuthorizationResult = .writeAuthorized
        client.writeResult = .saved(for: .water)
        let controller = HealthKitIntegrationController(client: client)

        let result = await controller.write(try makeWriteRequest(), userInitiated: true)

        XCTAssertEqual(result, .saved(for: .water))
        XCTAssertEqual(client.writeCalls, 1)
    }

    func testWriteFailureNeverFabricatesSuccess() async throws {
        let client = RecordingHealthKitIntegrationClient()
        client.writeAuthorizationResult = .writeAuthorized
        client.writeResult = .rejected(
            for: .water,
            state: .writeAuthorized,
            errorDescription: "HealthKit write failed"
        )
        let controller = HealthKitIntegrationController(client: client)

        let result = await controller.write(try makeWriteRequest(), userInitiated: true)

        XCTAssertFalse(result.didSave)
        XCTAssertEqual(result.authorizationState, .writeAuthorized)
        XCTAssertEqual(result.errorDescription, "HealthKit write failed")
        XCTAssertEqual(client.writeCalls, 1)
    }

    func testDeniedWriteIsBlockedBeforeClientSave() async throws {
        let client = RecordingHealthKitIntegrationClient()
        client.writeAuthorizationResult = .writeDenied
        let controller = HealthKitIntegrationController(client: client)

        let result = await controller.write(try makeWriteRequest(), userInitiated: true)

        XCTAssertFalse(result.didSave)
        XCTAssertEqual(result.authorizationState, .writeDenied)
        XCTAssertEqual(client.writeCalls, 0)
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
        client.statusResult = .init(state: .readIndeterminate)
        let controller = HealthKitIntegrationController(
            client: client,
            initialExplicitRequestCompleted: true
        )

        controller.appActive()
        await controller.refreshStatus()
        await waitUntil { client.startCalls == 1 }

        client.availabilityResult = .restricted
        await controller.refreshStatus()

        XCTAssertEqual(controller.snapshot.authorizationState, .restricted)
        XCTAssertTrue(controller.snapshot.isActive)
        XCTAssertEqual(client.stopCalls, 1)
    }

    func testPersistedPromptRestartsObserversAfterTerminalStatusRecovers() async {
        let client = RecordingHealthKitIntegrationClient()
        client.statusResult = .init(state: .readIndeterminate)
        let controller = HealthKitIntegrationController(
            client: client,
            initialExplicitRequestCompleted: true
        )

        controller.appActive()
        await controller.refreshStatus()
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

    func testPersistedPromptCannotOverrideRequestRequiredStatus() async {
        let client = RecordingHealthKitIntegrationClient()
        client.statusResult = .init(state: .requestRequired)
        let controller = HealthKitIntegrationController(
            client: client,
            initialExplicitRequestCompleted: true
        )

        await controller.refreshStatus()

        XCTAssertEqual(controller.snapshot.authorizationState, .requestRequired)
        XCTAssertTrue(controller.snapshot.explicitRequestCompleted)
        XCTAssertEqual(client.startCalls, 0)
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

    func testObserversPersistAcrossBackgroundAndForegroundRefreshesAgain() async {
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
        XCTAssertEqual(client.stopCalls, 0)
        XCTAssertFalse(controller.snapshot.isActive)

        controller.appActive()
        await waitUntil { client.startCalls == 2 }
        XCTAssertTrue(controller.snapshot.isActive)
        XCTAssertEqual(client.backgroundConfigurationCalls, 1)
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
        XCTAssertEqual(controller.snapshot.observerCompletionSequence, 0)

        currentCallback(.failure("current session"))
        await Task.yield()
        XCTAssertEqual(controller.snapshot.lastObserverCompletion, .failure("current session"))
        XCTAssertEqual(controller.snapshot.observerCompletionSequence, 0)
    }

    func testConsecutiveSuccessfulObserverCompletionsAdvanceSequence() async {
        let client = RecordingHealthKitIntegrationClient()
        client.statusResult = .init(state: .readIndeterminate)
        let controller = HealthKitIntegrationController(client: client)

        controller.appActive()
        await controller.refreshStatus()
        await waitUntil { client.callbacks.count == 1 }

        client.callbacks[0](.success)
        await waitUntil { controller.snapshot.observerCompletionSequence == 1 }
        client.callbacks[0](.success)
        await waitUntil { controller.snapshot.observerCompletionSequence == 2 }

        XCTAssertEqual(controller.snapshot.lastObserverCompletion, .success)
    }

    func testPartialObserverCompletionAdvancesSequenceAndPreservesError() async {
        let client = RecordingHealthKitIntegrationClient()
        client.statusResult = .init(state: .readIndeterminate)
        let controller = HealthKitIntegrationController(client: client)

        controller.appActive()
        await controller.refreshStatus()
        await waitUntil { client.callbacks.count == 1 }

        client.callbacks[0](.partialSuccess("HealthKit reconciliation partially failed after a durable metric commit"))
        await waitUntil { controller.snapshot.observerCompletionSequence == 1 }

        XCTAssertEqual(
            controller.snapshot.lastObserverCompletion,
            .partialSuccess("HealthKit reconciliation partially failed after a durable metric commit")
        )
        XCTAssertEqual(
            controller.snapshot.errorDescription,
            "HealthKit reconciliation partially failed after a durable metric commit"
        )
    }

    func testFailureCannotMaskAcceptedSuccessSequence() async {
        let client = RecordingHealthKitIntegrationClient()
        client.statusResult = .init(state: .readIndeterminate)
        let controller = HealthKitIntegrationController(client: client)

        controller.appActive()
        await controller.refreshStatus()
        await waitUntil { client.callbacks.count == 1 }

        // Deliver both completions before yielding to model SwiftUI observing
        // the published snapshot after a success has already been followed by
        // a failure. The success signal must remain observable exactly once.
        client.callbacks[0](.success)
        client.callbacks[0](.failure("late observer failure"))
        await waitUntil {
            controller.snapshot.lastObserverCompletion == .failure("late observer failure")
        }

        XCTAssertEqual(controller.snapshot.observerCompletionSequence, 1)
    }

    func testAuthorizationInvalidatesSuspendedPrePromptStatus() async {
        let client = RecordingHealthKitIntegrationClient()
        client.holdStatus = true
        client.statusResult = .init(state: .requestRequired)
        client.authorizationResult = .init(state: .requestRequired, promptCompleted: true)
        let controller = HealthKitIntegrationController(client: client)
        controller.appActive()

        let status = Task { @MainActor in await controller.refreshStatus() }
        await waitUntil { client.statusCalls == 1 }

        let authorization = Task { @MainActor in await controller.requestReadAuthorization() }
        await waitUntil { client.authorizationCalls == 1 }
        let authorizationResult = await authorization.value
        XCTAssertEqual(authorizationResult.state, .readIndeterminate)
        XCTAssertEqual(controller.snapshot.authorizationState, .readIndeterminate)
        XCTAssertEqual(client.startCalls, 1)

        client.finishStatus(.init(state: .requestRequired))
        _ = await status.value
        await Task.yield()

        XCTAssertEqual(controller.snapshot.authorizationState, .readIndeterminate)
        XCTAssertTrue(controller.snapshot.explicitRequestCompleted)
        XCTAssertEqual(client.startCalls, 1)
        XCTAssertEqual(client.stopCalls, 0)
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
        XCTAssertEqual(controller.snapshot.observerCompletionSequence, 0)
    }

    func testInactiveSystemSheetCompletionInstallsBackgroundObserversImmediately() async {
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
        await waitUntil { client.startCalls == 1 }
        XCTAssertFalse(controller.snapshot.isActive)

        controller.appActive()
        await waitUntil { client.startCalls == 2 }
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

    func testRequestRequiredNeverRegistersOrConfiguresBackgroundDelivery() async {
        let client = RecordingHealthKitIntegrationClient()
        client.statusResult = .init(state: .requestRequired)
        let controller = HealthKitIntegrationController(client: client)

        controller.appActive()
        await controller.refreshStatus()
        await Task.yield()

        XCTAssertEqual(client.startCalls, 0)
        XCTAssertEqual(client.backgroundConfigurationCalls, 0)
        XCTAssertEqual(controller.snapshot.backgroundDeliveryState, .notConfigured)
    }

    func testBackgroundDeliveryFailureIsReportedAndRetriedOnNextActivation() async {
        let client = RecordingHealthKitIntegrationClient()
        client.statusResult = .init(state: .readIndeterminate)
        client.backgroundDeliveryResult = .failed(HealthKitIntegrationController.supportedMetrics)
        let controller = HealthKitIntegrationController(client: client)

        controller.appActive()
        await controller.refreshStatus()
        await waitUntil { controller.snapshot.backgroundDeliveryState == .failed }

        XCTAssertEqual(
            controller.snapshot.backgroundDeliveryErrorDescription,
            "HealthKit background delivery could not be enabled"
        )
        XCTAssertEqual(client.backgroundConfigurationCalls, 1)

        client.backgroundDeliveryResult = .enabled(HealthKitIntegrationController.supportedMetrics)
        controller.appInactive()
        controller.appActive()
        await waitUntil { controller.snapshot.backgroundDeliveryState == .enabled }

        XCTAssertEqual(client.backgroundConfigurationCalls, 2)
        XCTAssertNil(controller.snapshot.backgroundDeliveryErrorDescription)
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
}

@MainActor
private final class RecordingHealthKitIntegrationClient: HealthKitIntegrationClient {
    var availabilityResult: HealthKitAuthorizationState = .readIndeterminate
    var statusResult: HealthKitAuthorizationReport = .init(state: .requestRequired)
    var authorizationResult: HealthKitAuthorizationReport = .init(state: .requestRequired)
    var holdStatus = false
    var holdAuthorization = false
    var availabilityCalls = 0
    var statusCalls = 0
    var authorizationCalls = 0
    var writeAuthorizationCalls = 0
    var writeStatusCalls = 0
    var writeCalls = 0
    var writeAuthorizationMetrics: [HealthKitWriteMetric] = []
    var writeAuthorizationResult: HealthKitAuthorizationState = .writeNotDetermined
    var writeAuthorizationReport: HealthKitAuthorizationReport = .init(state: .writeNotDetermined)
    var writeResult: HealthKitWriteReport = .rejected(for: .water, state: .writeNotDetermined)
    var backgroundConfigurationCalls = 0
    var startCalls = 0
    var stopCalls = 0
    var callbacks: [(HealthKitObserverCompletion) -> Void] = []
    var backgroundDeliveryResult = HealthKitBackgroundDeliveryReport.enabled(
        HealthKitIntegrationController.supportedMetrics
    )
    private var authorizationContinuation: CheckedContinuation<HealthKitAuthorizationReport, Never>?
    private var statusContinuation: CheckedContinuation<HealthKitAuthorizationReport, Never>?

    func availabilityState() -> HealthKitAuthorizationState {
        availabilityCalls += 1
        return availabilityResult
    }

    func requestStatus(for metrics: [HealthKitMetricID]) async -> HealthKitAuthorizationReport {
        XCTAssertEqual(metrics, HealthKitIntegrationController.supportedMetrics)
        statusCalls += 1
        if holdStatus {
            return await withCheckedContinuation { continuation in
                statusContinuation = continuation
            }
        }
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

    func requestWriteAuthorization(for metrics: [HealthKitWriteMetric]) async -> HealthKitAuthorizationReport {
        XCTAssertEqual(metrics, HealthKitIntegrationController.writableMetrics)
        writeAuthorizationCalls += 1
        writeAuthorizationMetrics = metrics
        return writeAuthorizationReport
    }

    func writeAuthorizationStatus(for metric: HealthKitWriteMetric) -> HealthKitAuthorizationState {
        writeStatusCalls += 1
        return writeAuthorizationResult
    }

    func write(_ request: HealthKitWriteRequest) async -> HealthKitWriteReport {
        XCTAssertEqual(request.metric, .water)
        writeCalls += 1
        return writeResult
    }

    func configureBackgroundDelivery(
        metrics: [HealthKitMetricID]
    ) async -> HealthKitBackgroundDeliveryReport {
        XCTAssertEqual(metrics, HealthKitIntegrationController.supportedMetrics)
        backgroundConfigurationCalls += 1
        return backgroundDeliveryResult
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

    func finishStatus(_ result: HealthKitAuthorizationReport) {
        statusContinuation?.resume(returning: result)
        statusContinuation = nil
    }
}
#endif
