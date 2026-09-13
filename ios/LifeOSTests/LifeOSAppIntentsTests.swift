import AppIntents
import XCTest
@testable import LifeOS

final class LifeOSAppIntentsTests: XCTestCase {
    private static let now = Date(timeIntervalSince1970: 1_788_825_600)

    private struct Output: Decodable {
        let schemaVersion: Int
        let action: LifeOSAutomationReport.Action
        let status: LifeOSAutomationReport.Status
        let steps: [LifeOSAutomationReport.Step]
        func step(_ operation: String) throws -> LifeOSAutomationReport.Step {
            try XCTUnwrap(steps.first { $0.operation == operation })
        }
    }

    private func output(_ value: String?) throws -> Output {
        let data = Data(try XCTUnwrap(value).utf8)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(Set(object.keys), ["schemaVersion", "action", "status", "steps"])
        let result = try JSONDecoder().decode(Output.self, from: data)
        XCTAssertEqual(result.schemaVersion, 1)
        for step in try XCTUnwrap(object["steps"] as? [[String: Any]]) {
            XCTAssertEqual(Set(step.keys), ["operation", "status", "code", "message"])
        }
        return result
    }

    private func dependencies() -> LifeOSAutomationDependencies {
        .init(usesVisualFixtures: false,
              isConfigured: { true },
              fetchFinance: { XCTFail("Unexpected finance request"); throw TailscaleSyncError.invalidResponse },
              checkConnection: { XCTFail("Unexpected preflight"); return .invalidResponse },
              signing: { SigningStatus(mode: .unknown, expirationDate: nil, now: Self.now) },
              now: { Self.now }, isMac: false)
    }

    private func fixtureDependencies() -> LifeOSAutomationDependencies {
        var dependencies = dependencies()
        dependencies.usesVisualFixtures = true
        return dependencies
    }

    // Synthetic wire data runs through the real production decoder and freshness
    // assessment. Dates and private sentinel values are fixed, never live accounts.
    private func summary(unavailable: Set<String> = [], age: TimeInterval = 0,
                         privateSource: String = "synthetic-source", includeAccount: Bool = false) throws -> FinanceSummary {
        let date = ISO8601DateFormatter().string(from: Self.now.addingTimeInterval(-age))
        let provenance: [String: Any] = ["source": privateSource, "observedAt": date,
            "freshness": age > 900 ? "stale" : "fresh", "quality": "observed",
            "connectorState": age > 900 ? "refresh_due" : "healthy"]
        var payload: [String: Any] = ["generatedAt": date, "currency": "EUR"]
        for key in ["monthlyIncome", "fixedCosts", "discretionaryBuffer", "spent", "savingsGoal", "saved"] {
            payload[key] = unavailable.contains(key)
                ? ["availability": "unavailable", "provenance": ["source": privateSource,
                    "observedAt": date, "freshness": "unknown", "quality": "unavailable", "connectorState": "unavailable"]]
                : ["availability": "observed", "amountCents": 987654321, "provenance": provenance]
        }
        if includeAccount {
            payload["accounts"] = ["availability": "observed", "provenance": provenance, "accounts": [
                ["availability": "observed", "id": "private-account-sentinel", "name": "private-name-sentinel",
                 "detail": "private-detail-sentinel", "balanceCents": 987654321,
                 "source": privateSource, "provenance": provenance]
            ]]
        }
        return try FinanceSummary.decode(JSONSerialization.data(withJSONObject: payload), now: Self.now)
    }

    func testMorningNormalReportsSummarySuccessButOverallPartial() async throws {
        let summary = try summary()
        let financeCalls = CallCounter()
        let refreshCalls = CallCounter()
        var deps = dependencies()
        deps.fetchFinance = { await financeCalls.increment(); return summary }
        deps.refreshHealthKit = { await refreshCalls.increment(); return .refreshed }
        let result = try await LifeOSMorningStatusIntent(dependencies: deps).perform()
        let report = try output(result.value)
        XCTAssertEqual(report.action, .morning)
        XCTAssertEqual(report.status, .partial)
        XCTAssertEqual(try report.step("finance").status, .success)
        XCTAssertEqual(try report.step("finance").code, "observed")
        XCTAssertTrue(try report.step("finance").message.contains("completion of a new bank refresh is not confirmed"))
        XCTAssertEqual(try report.step("zepp").status, .unavailable)
        XCTAssertEqual(try report.step("healthKit").status, .success)
        XCTAssertEqual(try report.step("healthKit").code, "refreshed")
        XCTAssertEqual(try report.step("scope").code, "foreground_only")
        let financeCallCount = await financeCalls.value
        let refreshCallCount = await refreshCalls.value
        XCTAssertEqual(financeCallCount, 1)
        XCTAssertEqual(refreshCallCount, 1)
    }

    func testMorningAwaitsInjectedHealthRefreshBeforePublishing() async throws {
        let summary = try summary()
        let gate = RefreshGate()
        var deps = dependencies()
        deps.fetchFinance = { summary }
        deps.refreshHealthKit = {
            await gate.wait()
            await gate.markFinished()
            return .refreshed
        }
        let intent = LifeOSMorningStatusIntent(dependencies: deps)
        let task = Task { try await intent.perform() }

        while !(await gate.started()) { await Task.yield() }
        let finishedBeforeRelease = await gate.finished()
        XCTAssertFalse(finishedBeforeRelease)
        await gate.release()

        let result = try await task.value
        XCTAssertEqual(try output(result.value).step("healthKit").code, "refreshed")
        let finishedAfterRelease = await gate.finished()
        XCTAssertTrue(finishedAfterRelease)
    }

#if os(iOS)
    @MainActor
    func testMorningReportWaitsForSharedRefreshWhenObserverRefreshOverlaps() async throws {
        let summary = try summary()
        let gate = HealthKitRepositoryReadGate()
        let completion = CompletionProbe()
        let automationStarted = CompletionProbe()
        let observerStarted = CompletionProbe()
        let repository = HealthKitFitnessRepository(
            testStateReader: { metrics in await gate.read(metrics) },
            now: { Self.now }
        )
        var deps = dependencies()
        deps.fetchFinance = { summary }
        deps.refreshHealthKit = {
            await automationStarted.markFinished()
            let projection = await repository.refresh()
            return projection == nil ? .unavailable : .refreshed
        }

        let intent = LifeOSMorningStatusIntent(dependencies: deps)
        let reportTask = Task {
            let result = try await intent.perform()
            await completion.markFinished()
            return result
        }

        for _ in 0..<100 {
            if await automationStarted.value { break }
            await Task.yield()
        }
        let didStartAutomation = await automationStarted.value
        XCTAssertTrue(didStartAutomation)
        for _ in 0..<100 {
            if await gate.readCount == 1 { break }
            await Task.yield()
        }
        var readCount = await gate.readCount
        XCTAssertEqual(readCount, 1)

        // This models the observerCompletionSequence handler starting while
        // the automation-owned refresh is still waiting. It must join the
        // same repository operation instead of cancelling and replacing it.
        let observerTask = Task { @MainActor in
            await observerStarted.markFinished()
            return await repository.refresh()
        }
        for _ in 0..<100 {
            if await observerStarted.value { break }
            await Task.yield()
        }
        let didStartObserver = await observerStarted.value
        XCTAssertTrue(didStartObserver)
        for _ in 0..<20 { await Task.yield() }
        readCount = await gate.readCount
        XCTAssertEqual(readCount, 1)
        let completedBeforeRelease = await completion.value
        XCTAssertFalse(completedBeforeRelease)

        await gate.release()
        let report = try await reportTask.value
        _ = await observerTask.value
        let completedAfterRelease = await completion.value
        XCTAssertTrue(completedAfterRelease)
        XCTAssertEqual(try output(report.value).step("healthKit").code, "refreshed")
    }
#endif

    func testPartialFinancePreservesItsOwnOutcome() async throws {
        let summary = try summary(unavailable: ["saved"])
        var deps = dependencies()
        deps.fetchFinance = { summary }
        let result = try await LifeOSMorningStatusIntent(dependencies: deps).perform()
        let report = try output(result.value)
        XCTAssertEqual(report.status, .partial)
        XCTAssertEqual(try report.step("finance").status, .partial)
        XCTAssertEqual(try report.step("finance").code, "partial")
        XCTAssertEqual(try report.step("healthKit").code, "unavailable")
    }

    func testHealthRefreshFailureDegradesToSanitizedUnavailable() async throws {
        let summary = try summary()
        var deps = dependencies()
        deps.fetchFinance = { summary }
        deps.refreshHealthKit = {
            throw NSError(
                domain: "private-health-provider",
                code: 42,
                userInfo: [NSLocalizedDescriptionKey: "private-token health-sample-123"]
            )
        }

        let result = try await LifeOSMorningStatusIntent(dependencies: deps).perform()
        let report = try output(result.value)
        XCTAssertEqual(try report.step("healthKit").status, .unavailable)
        XCTAssertEqual(try report.step("healthKit").code, "unavailable")
        XCTAssertFalse(try XCTUnwrap(result.value).contains("private-token"))
        XCTAssertFalse(try XCTUnwrap(result.value).contains("health-sample-123"))
    }

    func testHealthRefreshNoDataAndPartialStatesRemainCoarse() async throws {
        let summary = try summary()
        for state in [LifeOSAutomationHealthRefreshState.unavailable, .partial] {
            var deps = dependencies()
            deps.fetchFinance = { summary }
            deps.refreshHealthKit = { state }

            let result = try await LifeOSMorningStatusIntent(dependencies: deps).perform()
            let health = try output(result.value).step("healthKit")
            XCTAssertEqual(health.code, state.rawValue)
            XCTAssertEqual(health.status, state == .partial ? .partial : .unavailable)
        }
    }

    func testMacHealthRefreshReportsUnsupportedWithoutAnOwner() async throws {
        let summary = try summary()
        var deps = dependencies()
        deps.isMac = true
        deps.fetchFinance = { summary }

        let result = try await LifeOSMorningStatusIntent(dependencies: deps).perform()
        let health = try output(result.value).step("healthKit")
        XCTAssertEqual(health.code, "unavailable")
        XCTAssertTrue(health.message.contains("unavailable in the Mac build"))
        XCTAssertTrue(health.message.contains("no iOS HealthKit refresh was attempted"))
    }

    func testHealthRefreshCancellationPropagates() async throws {
        let summary = try summary()
        var deps = dependencies()
        deps.fetchFinance = { summary }
        deps.refreshHealthKit = { throw CancellationError() }
        let intent = LifeOSMorningStatusIntent(dependencies: deps)

        await assertCancelled {
            _ = try await intent.perform()
        }
    }

    func testStaleAtExactBoundaryNeverClaimsFreshRefresh() async throws {
        for age in [899.0, 900.0, 3600.0] {
            let summary = try summary(age: age)
            var deps = dependencies()
            deps.fetchFinance = { summary }
            let result = try await LifeOSMorningStatusIntent(dependencies: deps).perform()
            let finance = try output(result.value).step("finance")
            XCTAssertEqual(finance.code, age < 900 ? "observed" : "stale")
            XCTAssertEqual(finance.status, age < 900 ? .success : .partial)
        }
    }

    func testUnavailableFinanceDoesNotTurnMissingValuesIntoSuccess() async throws {
        let summary = try summary(unavailable: ["monthlyIncome", "fixedCosts", "discretionaryBuffer", "spent", "savingsGoal", "saved"])
        var deps = dependencies()
        deps.fetchFinance = { summary }
        let result = try await LifeOSMorningStatusIntent(dependencies: deps).perform()
        let report = try output(result.value)
        XCTAssertEqual(report.status, .unavailable)
        XCTAssertEqual(try report.step("finance").code, "unavailable")
    }

    func testUnconfiguredActionsSkipNetworkAndStillGiveManualSteps() async throws {
        var deps = dependencies()
        deps.isConfigured = { false }
        let morning = try await LifeOSMorningStatusIntent(dependencies: deps).perform()
        let usb = try await LifeOSUSBRefreshStatusIntent(dependencies: deps, navigation: {}).perform()
        XCTAssertEqual(try output(morning.value).step("finance").code, "configuration_required")
        let report = try output(usb.value)
        XCTAssertEqual(report.status, .unavailable)
        XCTAssertEqual(try report.step("gateway").code, "configuration_required")
        XCTAssertEqual(try report.step("usb").code, "cable_event_not_observed")
    }

    func testTransportAndAuthErrorsProduceCoarseUnavailableResults() async throws {
        let cases: [(Error, String)] = [
            (TailscaleSyncError.httpError(401), "authentication_rejected"),
            (TailscaleSyncError.httpError(403), "authentication_rejected"),
            (TailscaleSyncError.httpError(503), "server_unavailable"),
            (TailscaleSyncError.httpError(429), "server_unavailable"),
            (URLError(.timedOut), "server_unavailable"),
            (URLError(.notConnectedToInternet), "network_unavailable"),
            (TailscaleSyncError.invalidResponse, "invalid_response"),
            (TailscaleSyncError.responseTooLarge, "invalid_response")
        ]
        for (error, expected) in cases {
            var deps = dependencies()
            deps.fetchFinance = { throw error }
            let result = try await LifeOSMorningStatusIntent(dependencies: deps).perform()
            let report = try output(result.value)
            XCTAssertEqual(report.status, .unavailable)
            XCTAssertEqual(try report.step("finance").code, expected)
        }
    }

    func testReauthenticationChecksGatewayAndLocalMetadataOnly() async throws {
        let calls = CallCounter()
        var deps = dependencies()
        deps.checkConnection = { await calls.increment(); return .reachable }
        deps.isMac = true
        deps.signing = { .init(mode: .personalTeam, expirationDate: Self.now.addingTimeInterval(7 * 86400), now: Self.now) }
        let result = try await LifeOSUSBRefreshStatusIntent(dependencies: deps, navigation: {}).perform()
        let report = try output(result.value)
        XCTAssertEqual(report.action, .reauthentication)
        XCTAssertEqual(report.status, .partial)
        XCTAssertEqual(try report.step("gateway").status, .success)
        XCTAssertEqual(try report.step("signing").status, .success)
        XCTAssertTrue(try report.step("signing").message.contains("This Mac build only, not the connected iPhone"))
        XCTAssertEqual(try report.step("reauthentication").status, .unavailable)
        XCTAssertEqual(try report.step("usb").status, .unavailable)
        let count = await calls.value
        XCTAssertEqual(count, 1)
    }

    func testReauthenticationAllGatewayFailuresRetainSigningResult() async throws {
        for state in [TailscaleConnectionPreflightState.configurationRequired, .authenticationRejected,
                      .serverUnavailable, .networkUnavailable, .invalidResponse] {
            var deps = dependencies()
            deps.checkConnection = { state }
            deps.signing = { .init(mode: .personalTeam, expirationDate: Self.now.addingTimeInterval(86400), now: Self.now) }
            let result = try await LifeOSUSBRefreshStatusIntent(dependencies: deps, navigation: {}).perform()
            let report = try output(result.value)
            XCTAssertEqual(report.status, .partial)
            XCTAssertEqual(try report.step("gateway").code, state.rawValue)
            XCTAssertEqual(try report.step("signing").code, "expiring_soon")
        }
    }

    func testSigningUnknownExpiredAndSoonRemainTruthful() async throws {
        let cases: [(ProvisioningMode, TimeInterval?, String, LifeOSAutomationReport.Status)] = [
            (.unknown, nil, "unknown", .unavailable), (.unknown, 86400, "unknown", .unavailable),
            (.personalTeam, nil, "unknown", .unavailable), (.personalTeam, -1, "expired", .partial),
            (.personalTeam, 0, "expired", .partial), (.personalTeam, 86400, "expiring_soon", .partial)
        ]
        for (mode, remaining, code, status) in cases {
            var deps = dependencies()
            deps.isConfigured = { false }
            let signing = SigningStatus(mode: mode, expirationDate: remaining.map { Self.now.addingTimeInterval($0) }, now: Self.now)
            deps.signing = { signing }
            let result = try await LifeOSUSBRefreshStatusIntent(dependencies: deps, navigation: {}).perform()
            let step = try output(result.value).step("signing")
            XCTAssertEqual(step.code, code)
            XCTAssertEqual(step.status, status)
            XCTAssertTrue(step.message.contains("This iPhone build only"))
            XCTAssertTrue(step.message.contains("successful renewal are not verified"))
        }
    }

    func testZeppIntentReturnsStructuredManualGuidanceWithoutURLAction() async throws {
        let navigationCalls = CallCounter()
        let result = try await LifeOSOpenZeppForSyncIntent(navigation: {
            await navigationCalls.increment()
        }).perform()
        let report = try output(result.value)
        XCTAssertEqual(report.status, .unavailable)
        XCTAssertEqual(report.action, .zeppGuidance)
        XCTAssertEqual(try report.step("zepp").message, LifeOSAutomationStatus.openZeppDialog)
        XCTAssertTrue(try report.step("zepp").message.contains("does not open Zepp, start sync, or confirm sync completion"))
        XCTAssertFalse(try XCTUnwrap(result.value).contains("://"))
        let navigationCallCount = await navigationCalls.value
        XCTAssertEqual(navigationCallCount, 1)
    }

    func testFixtureDetectionMatchesAppHosts() {
        XCTAssertTrue(LifeOSAutomationDependencies.fixturesEnabled(arguments: ["-LifeOSVisualFixtures"], environment: [:]))
        XCTAssertTrue(LifeOSAutomationDependencies.fixturesEnabled(arguments: [], environment: ["LIFEOS_VISUAL_FIXTURES": "1"]))
        XCTAssertFalse(LifeOSAutomationDependencies.fixturesEnabled(arguments: [], environment: ["LIFEOS_VISUAL_FIXTURES": "0"]))
    }

    func testFixtureInvocationsTouchNoLiveDependencies() async throws {
        var deps = dependencies()
        deps.usesVisualFixtures = true
        deps.isConfigured = { XCTFail("Fixture configured a live client"); return true }
        deps.refreshHealthKit = {
            XCTFail("Fixture checked health")
            return .refreshed
        }
        deps.signing = { XCTFail("Fixture checked signing"); return .init(mode: .unknown, expirationDate: nil) }
        let morning = try await LifeOSMorningStatusIntent(dependencies: deps).perform()
        let usb = try await LifeOSUSBRefreshStatusIntent(dependencies: deps, navigation: {}).perform()
        for value in [morning.value, usb.value] {
            let report = try output(value)
            XCTAssertEqual(report.status, .unavailable)
            XCTAssertEqual(report.steps.count, 1)
            XCTAssertEqual(report.steps.first?.code, "fixtures_enabled")
        }
    }

#if DEBUG
    func testFixtureIntentsCreateNoNetworkTasks() async throws {
        // Inject the isolated fixture context directly. The production intent
        // perform path still runs, while every live dependency is a hard fail.
        let dependencies = fixtureDependencies()
        let before = LifeOSNetworkTaskAudit.shared.createdTaskCount
        let morning = try await LifeOSMorningStatusIntent(dependencies: dependencies).perform()
        let usb = try await LifeOSUSBRefreshStatusIntent(dependencies: dependencies, navigation: {}).perform()
        XCTAssertEqual(try output(morning.value).steps.first?.code, "fixtures_enabled")
        XCTAssertEqual(try output(usb.value).steps.first?.code, "fixtures_enabled")
        XCTAssertEqual(LifeOSNetworkTaskAudit.shared.createdTaskCount, before)
    }

#endif

    func testPrecancelledIntentsThrowBeforeDoingWork() async {
        let deps = dependencies()
        await assertCancelled {
            withUnsafeCurrentTask { $0?.cancel() }
            _ = try await LifeOSMorningStatusIntent(dependencies: deps).perform()
        }
        await assertCancelled {
            withUnsafeCurrentTask { $0?.cancel() }
            _ = try await LifeOSUSBRefreshStatusIntent(dependencies: deps, navigation: {}).perform()
        }
        await assertCancelled {
            withUnsafeCurrentTask { $0?.cancel() }
            _ = try await LifeOSOpenZeppForSyncIntent(navigation: {}).perform()
        }
    }

    func testAllTransportCancellationFormsPropagate() async {
        let errors: [Error] = [CancellationError(), URLError(.cancelled),
            NSError(domain: NSURLErrorDomain, code: NSURLErrorCancelled,
                    userInfo: [NSLocalizedDescriptionKey: "private-cancellation-sentinel"])]
        for error in errors {
            var deps = dependencies()
            deps.fetchFinance = { throw error }
            let intent = LifeOSMorningStatusIntent(dependencies: deps)
            await assertCancelled { _ = try await intent.perform() }
        }
    }

    func testCancellationDuringConfigurationSkipsLaterOperations() async {
        var deps = dependencies()
        deps.isConfigured = { withUnsafeCurrentTask { $0?.cancel() }; return true }
        let morning = LifeOSMorningStatusIntent(dependencies: deps)
        let usb = LifeOSUSBRefreshStatusIntent(dependencies: deps, navigation: {})
        await assertCancelled { _ = try await morning.perform() }
        await assertCancelled { _ = try await usb.perform() }
    }

    func testCancelledFetchReturningSuccessStillCannotPublish() async throws {
        let summary = try summary()
        var deps = dependencies()
        deps.fetchFinance = { withUnsafeCurrentTask { $0?.cancel() }; return summary }
        let intent = LifeOSMorningStatusIntent(dependencies: deps)
        await assertCancelled { _ = try await intent.perform() }
    }

    func testNilAndCancelledGatewayPreflightCannotPublishSigning() async {
        for cancel in [false, true] {
            var deps = dependencies()
            deps.checkConnection = {
                if cancel { withUnsafeCurrentTask { $0?.cancel() }; return .reachable }
                return nil
            }
            deps.signing = { XCTFail("Signing checked after cancellation"); return .init(mode: .unknown, expirationDate: nil) }
            let intent = LifeOSUSBRefreshStatusIntent(dependencies: deps, navigation: {})
            await assertCancelled { _ = try await intent.perform() }
        }
    }

    func testSuccessDoesNotReturnRawBankingFieldsOrIdentifiers() async throws {
        let summary = try summary(privateSource: "private-provider-sentinel", includeAccount: true)
        var deps = dependencies()
        deps.fetchFinance = { summary }
        let result = try await LifeOSMorningStatusIntent(dependencies: deps).perform()
        let report = try output(result.value)
        XCTAssertEqual(try report.step("finance").status, .success)
        let reportText = try XCTUnwrap(result.value) + report.steps.map(\.message).joined()
        for sentinel in ["private-account-sentinel", "private-provider-sentinel", "private-name-sentinel",
                         "private-detail-sentinel", "987654321", "amountCents", "balanceCents", "observedAt"] {
            XCTAssertFalse(reportText.contains(sentinel))
        }
    }

    func testErrorsCannotLeakSecretsOrRawBankingHealthIdentifiers() async throws {
        let privateText = "Bearer private-token bank-account-123 health-sample-456 https://user:password@private.ts.net"
        for domain in ["private-error-domain", NSURLErrorDomain] {
            var deps = dependencies()
            deps.fetchFinance = { throw NSError(domain: domain, code: -1, userInfo: [
                NSLocalizedDescriptionKey: privateText, NSURLErrorFailingURLStringErrorKey: privateText]) }
            let result = try await LifeOSMorningStatusIntent(dependencies: deps).perform()
            let report = try output(result.value)
            let reportText = try XCTUnwrap(result.value) + report.steps.map(\.message).joined()
            for sentinel in privateText.split(separator: " ") {
                XCTAssertFalse(reportText.contains(sentinel))
            }
            XCTAssertEqual(report.status, .unavailable)
        }
    }

    func testGuidanceIntentsUseExistingFitnessAndSettingsRoutes() async throws {
        XCTAssertTrue(LifeOSMorningStatusIntent.openAppWhenRun)
        XCTAssertTrue(LifeOSUSBRefreshStatusIntent.openAppWhenRun)
        XCTAssertTrue(LifeOSOpenZeppForSyncIntent.openAppWhenRun)
        XCTAssertEqual(LifeOSMorningStatusIntent.authenticationPolicy, .requiresLocalDeviceAuthentication)
        XCTAssertEqual(LifeOSUSBRefreshStatusIntent.authenticationPolicy, .requiresLocalDeviceAuthentication)
        XCTAssertEqual(LifeOSOpenZeppForSyncIntent.authenticationPolicy, .requiresLocalDeviceAuthentication)

        XCTAssertEqual(LifeOSNavigationRoute(url: LifeOSAutomationNavigation.fitnessURL).module, .fitness)
        XCTAssertEqual(LifeOSNavigationRoute(url: LifeOSAutomationNavigation.settingsURL).module, .settings)

        let fitnessCalls = CallCounter()
        _ = try await LifeOSOpenZeppForSyncIntent(navigation: {
            await fitnessCalls.increment()
        }).perform()
        let fitnessCallCount = await fitnessCalls.value
        XCTAssertEqual(fitnessCallCount, 1)

        var dependencies = dependencies()
        dependencies.isConfigured = { false }
        let settingsCalls = CallCounter()
        _ = try await LifeOSUSBRefreshStatusIntent(dependencies: dependencies, navigation: {
            await settingsCalls.increment()
        }).perform()
        let settingsCallCount = await settingsCalls.value
        XCTAssertEqual(settingsCallCount, 1)
    }

    private func assertCancelled(_ operation: @escaping @Sendable () async throws -> Void,
                                 file: StaticString = #filePath, line: UInt = #line) async {
        let task = Task {
            do {
                try await operation()
                XCTFail("Cancellation must not return a success or unavailable report", file: file, line: line)
            } catch is CancellationError {
                // Expected: no raw error or successful Shortcut result escapes.
            } catch { XCTFail("Expected sanitized CancellationError", file: file, line: line) }
        }
        await task.value
    }
}

private actor CallCounter {
    private(set) var value = 0
    func increment() { value += 1 }
}

private actor RefreshGate {
    private var didStart = false
    private var didFinish = false
    private var released = false
    private var continuation: CheckedContinuation<Void, Never>?

    func wait() async {
        didStart = true
        guard !released else { return }
        await withCheckedContinuation { continuation in
            self.continuation = continuation
        }
    }

    func release() {
        released = true
        continuation?.resume()
        continuation = nil
    }

    func markFinished() { didFinish = true }
    func started() -> Bool { didStart }
    func finished() -> Bool { didFinish }
}

#if os(iOS)
private actor HealthKitRepositoryReadGate {
    private(set) var readCount = 0
    private var continuation: CheckedContinuation<[HealthKitStoredMetricState], Never>?

    func read(_ metrics: [HealthKitMetricID]) async -> [HealthKitStoredMetricState] {
        readCount += 1
        return await withCheckedContinuation { continuation in
            self.continuation = continuation
        }
    }

    func release() {
        continuation?.resume(returning: [])
        continuation = nil
    }
}

private actor CompletionProbe {
    private var didFinish = false

    func markFinished() { didFinish = true }
    var value: Bool { didFinish }
}
#endif
