#if os(iOS)
import Foundation
import Combine

/// The lifecycle state exposed to platform-neutral settings surfaces.
public enum HealthKitIntegrationLifecycle: String, Codable, Sendable {
    case inactive
    case active
}

/// A small, HealthKit-free snapshot that can be passed to shared UI/domain
/// code without making that code import HealthKit or know about HK queries.
public struct HealthKitIntegrationSnapshot: Equatable, Sendable {
    public let authorizationState: HealthKitAuthorizationState
    public let lifecycle: HealthKitIntegrationLifecycle
    public let isRequestInFlight: Bool
    public let explicitRequestCompleted: Bool
    public let lastObserverCompletion: HealthKitObserverCompletion?
    /// Monotonically identifies every accepted observer/reconciliation update
    /// that durably changed at least one projection for the current controller
    /// lifetime. The completion value itself is intentionally retained for
    /// diagnostics, but `.success` is Equatable, so consumers that must react
    /// to every durable update observe this sequence instead.
    public let observerCompletionSequence: UInt64
    public let errorDescription: String?

    public init(
        authorizationState: HealthKitAuthorizationState = .notRequested,
        lifecycle: HealthKitIntegrationLifecycle = .inactive,
        isRequestInFlight: Bool = false,
        explicitRequestCompleted: Bool = false,
        lastObserverCompletion: HealthKitObserverCompletion? = nil,
        observerCompletionSequence: UInt64 = 0,
        errorDescription: String? = nil
    ) {
        self.authorizationState = authorizationState
        self.lifecycle = lifecycle
        self.isRequestInFlight = isRequestInFlight
        self.explicitRequestCompleted = explicitRequestCompleted
        self.lastObserverCompletion = lastObserverCompletion
        self.observerCompletionSequence = observerCompletionSequence
        self.errorDescription = errorDescription
    }

    public var authorization: HealthKitAuthorizationState { authorizationState }
    public var isActive: Bool { lifecycle == .active }
}

/// A narrow seam around the iOS adapter/coordinator. A production bridge can
/// own HKObserverQuery instances and call `onUpdate` after reconciliation;
/// tests can provide a tiny fake without constructing HealthKit objects.
@MainActor
public protocol HealthKitIntegrationClient {
    func availabilityState() -> HealthKitAuthorizationState
    func requestStatus(for metrics: [HealthKitMetricID]) async -> HealthKitAuthorizationReport
    func requestReadAuthorization(for metrics: [HealthKitMetricID]) async -> HealthKitAuthorizationReport
    func startObservers(
        metrics: [HealthKitMetricID],
        onUpdate: @escaping @Sendable (HealthKitObserverCompletion) -> Void
    )
    func stopAllObservers()
}

/// Closure-backed client used by previews, fixtures, and focused tests.
@MainActor
public struct HealthKitIntegrationClientClosures: HealthKitIntegrationClient {
    public typealias ObserverUpdate = @Sendable (HealthKitObserverCompletion) -> Void
    public typealias ObserverStarter = ([HealthKitMetricID], ObserverUpdate) -> Void

    private let availability: () -> HealthKitAuthorizationState
    private let status: ([HealthKitMetricID]) async -> HealthKitAuthorizationReport
    private let request: ([HealthKitMetricID]) async -> HealthKitAuthorizationReport
    private let start: ObserverStarter
    private let stop: () -> Void

    public init(
        availability: @escaping () -> HealthKitAuthorizationState,
        status: @escaping ([HealthKitMetricID]) async -> HealthKitAuthorizationReport,
        request: @escaping ([HealthKitMetricID]) async -> HealthKitAuthorizationReport,
        start: @escaping ObserverStarter,
        stop: @escaping () -> Void
    ) {
        self.availability = availability
        self.status = status
        self.request = request
        self.start = start
        self.stop = stop
    }

    public func availabilityState() -> HealthKitAuthorizationState { availability() }

    public func requestStatus(for metrics: [HealthKitMetricID]) async -> HealthKitAuthorizationReport {
        await status(metrics)
    }

    public func requestReadAuthorization(for metrics: [HealthKitMetricID]) async -> HealthKitAuthorizationReport {
        await request(metrics)
    }

    public func startObservers(
        metrics: [HealthKitMetricID],
        onUpdate: @escaping ObserverUpdate
    ) {
        start(metrics, onUpdate)
    }

    public func stopAllObservers() { stop() }
}

/// iOS-only permission/lifecycle controller. It deliberately has no sample
/// query in init or status refresh; reads begin only after HealthKit reports
/// that a request is unnecessary or an explicit prompt has completed, and the
/// app is in the foreground.
@MainActor
public final class HealthKitIntegrationController: ObservableObject {
    public static let supportedMetrics: [HealthKitMetricID] = HealthKitMetricID.allCases.filter {
        $0 != .alcoholicBeverages
    }

    public static var defaultPersistenceURL: URL {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
        return support
            .appendingPathComponent("LifeOS", isDirectory: true)
            .appendingPathComponent("healthkit-projection.json", isDirectory: false)
    }

    public let persistenceURL: URL
    public let usesVisualFixtures: Bool
    public var supportedMetrics: [HealthKitMetricID] { Self.supportedMetrics }
    @Published public private(set) var snapshot: HealthKitIntegrationSnapshot

    private let client: (any HealthKitIntegrationClient)?
    private var generation: UInt64 = 0
    private var statusOperationID: UInt64 = 0
    private var requestOperationID: UInt64 = 0
    private var explicitRequestCompleted = false
    /// Execution readiness comes from the current HealthKit availability/
    /// request result, not from the local prompt-history flag. HealthKit does
    /// not disclose per-type read denial, so `.readIndeterminate` remains the
    /// truthful state for allowed reads; an empty result is not treated as a
    /// denial.
    private var executionAuthorizationReady = false
    private var sessionStarted = false
    private var requestTask: Task<HealthKitAuthorizationReport, Never>?
    private var statusTask: Task<HealthKitAuthorizationReport, Never>?

    public init(
        client: (any HealthKitIntegrationClient)? = nil,
        usesVisualFixtures: Bool = false,
        persistenceURL: URL? = nil,
        initialExplicitRequestCompleted: Bool = false
    ) {
        self.client = usesVisualFixtures ? nil : client
        self.usesVisualFixtures = usesVisualFixtures
        self.persistenceURL = persistenceURL ?? Self.defaultPersistenceURL
        self.explicitRequestCompleted = usesVisualFixtures ? false : initialExplicitRequestCompleted
        self.executionAuthorizationReady = false
        self.snapshot = HealthKitIntegrationSnapshot(
            authorizationState: initialExplicitRequestCompleted && !usesVisualFixtures
                ? .readIndeterminate
                : .notRequested,
            explicitRequestCompleted: initialExplicitRequestCompleted && !usesVisualFixtures
        )
    }

    /// Status is intentionally limited to availability and request status.
    /// It never asks HealthKit for samples and never opens the permission UI.
    public func refreshStatus() async {
        guard !usesVisualFixtures, let client else { return }

        statusTask?.cancel()
        let token = generation
        statusOperationID &+= 1
        let currentOperation = statusOperationID
        let metrics = Self.supportedMetrics
        let task = Task { @MainActor in
            let availability = client.availabilityState()
            switch availability {
            case .unavailable, .restricted, .protectedDataUnavailable:
                return HealthKitAuthorizationReport(state: availability)
            default:
                return await client.requestStatus(for: metrics)
            }
        }
        statusTask = task
        let report = await task.value
        guard token == generation, currentOperation == statusOperationID else { return }
        statusTask = nil
        switch report.state {
        case .unavailable, .restricted, .protectedDataUnavailable, .revoked, .error:
            executionAuthorizationReady = false
            stopSessionIfRunning()
            publish(
                authorizationState: report.state,
                lastObserverCompletion: .replace(nil),
                errorDescription: .replace(report.errorDescription)
            )
        case .readIndeterminate:
            // `.readIndeterminate` is the only truthful read state HealthKit
            // exposes. It includes the request-status `.unnecessary` result:
            // no prompt is needed, but read authorization is still not
            // observable per type. Starting observers here is therefore safe
            // and independent of local prompt history.
            executionAuthorizationReady = true
            publish(
                authorizationState: .readIndeterminate,
                errorDescription: .replace(report.errorDescription)
            )
            startSessionIfEligible()
        case .notRequested, .requestRequired, .requestPending,
             .writeNotDetermined, .writeAuthorized, .writeDenied:
            // A request-required/pending result is a hard execution gate. Do
            // not issue HealthKit reads merely because a prior local prompt
            // was recorded as completed.
            executionAuthorizationReady = false
            stopSessionIfRunning()
            publish(
                authorizationState: report.state,
                errorDescription: .replace(report.errorDescription)
            )
        }
    }

    public func refreshAuthorizationStatus() async { await refreshStatus() }

    /// Requests read access exactly once while a prompt is in flight. A true
    /// completion only means the sheet completed; read access stays
    /// indeterminate because HealthKit does not reveal per-type read denial.
    @discardableResult
    public func requestReadAuthorization() async -> HealthKitAuthorizationReport {
        guard !usesVisualFixtures, let client else {
            return HealthKitAuthorizationReport(state: snapshot.authorizationState)
        }
        if let requestTask { return Self.normalizedPromptReport(await requestTask.value) }

        // A status request can be suspended while the system permission sheet
        // is presented. Invalidate it before starting the new authorization
        // operation so a late pre-prompt `.requestRequired` result cannot
        // overwrite the completed prompt's `.readIndeterminate` state.
        statusOperationID &+= 1
        statusTask?.cancel()
        statusTask = nil
        requestOperationID &+= 1
        let currentOperation = requestOperationID
        let metrics = Self.supportedMetrics
        let task = Task { @MainActor in
            await client.requestReadAuthorization(for: metrics)
        }
        requestTask = task
        publish(isRequestInFlight: true)

        let report = await task.value
        let normalized = Self.normalizedPromptReport(report)
        guard currentOperation == requestOperationID else { return normalized }
        requestTask = nil
        if report.promptCompleted == true { explicitRequestCompleted = true }
        switch normalized.state {
        case .readIndeterminate:
            // A completed system sheet is an explicit HealthKit signal that
            // reads may begin. A failed/incomplete request keeps the previous
            // readiness only when an earlier status/request already allowed
            // reads; it cannot create readiness from a local history flag.
            executionAuthorizationReady = executionAuthorizationReady || report.promptCompleted == true
        case .unavailable, .restricted, .protectedDataUnavailable, .revoked, .error,
             .notRequested, .requestRequired, .requestPending,
             .writeNotDetermined, .writeAuthorized, .writeDenied:
            executionAuthorizationReady = false
            stopSessionIfRunning()
        }
        publish(
            authorizationState: normalized.state,
            isRequestInFlight: false,
            explicitRequestCompleted: explicitRequestCompleted,
            errorDescription: .replace(normalized.errorDescription)
        )
        startSessionIfEligible()
        return normalized
    }

    @discardableResult
    public func requestAuthorization() async -> HealthKitAuthorizationReport {
        await requestReadAuthorization()
    }

    @discardableResult
    public func requestPermission() async -> HealthKitAuthorizationReport {
        await requestReadAuthorization()
    }

    /// Marks the app foregrounded. Repeated active notifications do not
    /// create another observer/reconciliation session.
    public func appActive() {
        guard snapshot.lifecycle != .active else { return }
        generation &+= 1
        statusOperationID &+= 1
        publish(lifecycle: .active, lastObserverCompletion: .replace(nil))
        startSessionIfEligible()
    }

    public func applicationDidBecomeActive() { appActive() }

    /// Stops foreground observation while preserving an in-flight permission
    /// request. iOS makes a scene inactive while its system authorization
    /// sheet is visible; treating that transition as background would discard
    /// the user's response.
    public func appInactive() {
        generation &+= 1
        statusOperationID &+= 1
        statusTask?.cancel()
        statusTask = nil
        sessionStarted = false
        if !usesVisualFixtures { client?.stopAllObservers() }
        publish(lifecycle: .inactive, lastObserverCompletion: .replace(nil))
    }

    /// Actual background/teardown invalidates permission and status work so a
    /// late completion cannot mutate the background or a later session.
    public func applicationDidEnterBackground() {
        appInactive()
        generation &+= 1
        requestOperationID &+= 1
        requestTask?.cancel()
        requestTask = nil
        publish(isRequestInFlight: false)
    }

    private func startSessionIfEligible() {
        guard !usesVisualFixtures,
              snapshot.lifecycle == .active,
              executionAuthorizationReady,
              snapshot.authorizationState == .readIndeterminate,
              !sessionStarted,
              let client else { return }

        sessionStarted = true
        let token = generation
        let metrics = Self.supportedMetrics
        // Registration is deliberately synchronous and bounded. This makes
        // stop-on-inactive atomic: no ignored Task cancellation can register
        // a stale observer after `stopAllObservers()` returns. Only observer
        // reconciliation callbacks are asynchronous.
        client.startObservers(metrics: metrics) { [weak self] completion in
            Task { @MainActor [weak self] in
                self?.receiveObserverCompletion(completion, generation: token)
            }
        }
    }

    /// Invalidates the current observer generation before stopping the
    /// adapter. A callback already queued by HealthKit must not republish a
    /// stale session after a terminal availability result.
    private func stopSessionIfRunning() {
        guard sessionStarted else { return }
        generation &+= 1
        sessionStarted = false
        client?.stopAllObservers()
    }

    private func receiveObserverCompletion(_ completion: HealthKitObserverCompletion, generation token: UInt64) {
        guard token == generation, snapshot.lifecycle == .active else { return }
        let error: String?
        switch completion {
        case .failure(let message), .partialSuccess(let message):
            error = message
        case .success, .timedOut:
            error = nil
        }
        let successSequence: UInt64?
        switch completion {
        case .success, .partialSuccess:
            successSequence = snapshot.observerCompletionSequence &+ 1
        case .failure, .timedOut:
            successSequence = nil
        }
        publish(
            lastObserverCompletion: .replace(completion),
            observerCompletionSequence: successSequence,
            errorDescription: .replace(error)
        )
    }

    private enum OptionalReplacement<Value> {
        case preserve
        case replace(Value?)
    }

    private func publish(
        authorizationState: HealthKitAuthorizationState? = nil,
        lifecycle: HealthKitIntegrationLifecycle? = nil,
        isRequestInFlight: Bool? = nil,
        explicitRequestCompleted: Bool? = nil,
        lastObserverCompletion: OptionalReplacement<HealthKitObserverCompletion> = .preserve,
        observerCompletionSequence: UInt64? = nil,
        errorDescription: OptionalReplacement<String> = .preserve
    ) {
        let old = snapshot
        let observerCompletion: HealthKitObserverCompletion?
        switch lastObserverCompletion {
        case .preserve: observerCompletion = old.lastObserverCompletion
        case .replace(let value): observerCompletion = value
        }
        let error: String?
        switch errorDescription {
        case .preserve: error = old.errorDescription
        case .replace(let value): error = value
        }
        snapshot = HealthKitIntegrationSnapshot(
            authorizationState: authorizationState ?? old.authorizationState,
            lifecycle: lifecycle ?? old.lifecycle,
            isRequestInFlight: isRequestInFlight ?? old.isRequestInFlight,
            explicitRequestCompleted: explicitRequestCompleted ?? old.explicitRequestCompleted,
            lastObserverCompletion: observerCompletion,
            observerCompletionSequence: observerCompletionSequence ?? old.observerCompletionSequence,
            errorDescription: error
        )
    }

    private static func normalizedPromptReport(_ report: HealthKitAuthorizationReport) -> HealthKitAuthorizationReport {
        guard report.promptCompleted == true else { return report }
        return HealthKitAuthorizationReport(
            state: .readIndeterminate,
            promptCompleted: true,
            errorDescription: report.errorDescription
        )
    }
}
#endif
