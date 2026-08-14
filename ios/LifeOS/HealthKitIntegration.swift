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
    public let backgroundDeliveryState: HealthKitBackgroundDeliveryState
    public let backgroundDeliveryErrorDescription: String?
    public let errorDescription: String?

    public init(
        authorizationState: HealthKitAuthorizationState = .notRequested,
        lifecycle: HealthKitIntegrationLifecycle = .inactive,
        isRequestInFlight: Bool = false,
        explicitRequestCompleted: Bool = false,
        lastObserverCompletion: HealthKitObserverCompletion? = nil,
        observerCompletionSequence: UInt64 = 0,
        backgroundDeliveryState: HealthKitBackgroundDeliveryState = .notConfigured,
        backgroundDeliveryErrorDescription: String? = nil,
        errorDescription: String? = nil
    ) {
        self.authorizationState = authorizationState
        self.lifecycle = lifecycle
        self.isRequestInFlight = isRequestInFlight
        self.explicitRequestCompleted = explicitRequestCompleted
        self.lastObserverCompletion = lastObserverCompletion
        self.observerCompletionSequence = observerCompletionSequence
        self.backgroundDeliveryState = backgroundDeliveryState
        self.backgroundDeliveryErrorDescription = backgroundDeliveryErrorDescription
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
    func configureBackgroundDelivery(
        metrics: [HealthKitMetricID]
    ) async -> HealthKitBackgroundDeliveryReport
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
    private let configureBackground: ([HealthKitMetricID]) async -> HealthKitBackgroundDeliveryReport
    private let start: ObserverStarter
    private let stop: () -> Void

    public init(
        availability: @escaping () -> HealthKitAuthorizationState,
        status: @escaping ([HealthKitMetricID]) async -> HealthKitAuthorizationReport,
        request: @escaping ([HealthKitMetricID]) async -> HealthKitAuthorizationReport,
        configureBackground: @escaping ([HealthKitMetricID]) async -> HealthKitBackgroundDeliveryReport = {
            .enabled($0)
        },
        start: @escaping ObserverStarter,
        stop: @escaping () -> Void
    ) {
        self.availability = availability
        self.status = status
        self.request = request
        self.configureBackground = configureBackground
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

    public func configureBackgroundDelivery(
        metrics: [HealthKitMetricID]
    ) async -> HealthKitBackgroundDeliveryReport {
        await configureBackground(metrics)
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
/// that a request is unnecessary or an explicit prompt has completed. Once
/// that gate opens, observers stay registered across scene backgrounding so
/// HealthKit can reactivate the app. Foreground transitions still request a
/// bounded refresh through the idempotent production bridge.
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
    private var observerCallbackOperationID: UInt64 = 0
    private var statusOperationID: UInt64 = 0
    private var requestOperationID: UInt64 = 0
    private var backgroundDeliveryOperationID: UInt64 = 0
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
    private var backgroundDeliveryTask: Task<HealthKitBackgroundDeliveryReport, Never>?

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

    /// Called from the app initializer so an already-authorized installation
    /// recreates its long-running observer queries during launch, including a
    /// HealthKit background activation where no scene becomes active first.
    /// The status call never prompts and no observer is installed while the
    /// request status still requires authorization.
    public func applicationLaunched() {
        guard !usesVisualFixtures else { return }
        Task { @MainActor [weak self] in
            await self?.refreshStatus()
        }
    }

    /// Marks the app foregrounded. A transition from inactive requests a fresh
    /// bounded reconciliation while the production bridge keeps observer
    /// registration idempotent.
    public func appActive() {
        guard snapshot.lifecycle != .active else { return }
        publish(lifecycle: .active, lastObserverCompletion: .replace(nil))
        startSessionIfEligible(refreshExisting: true)
    }

    public func applicationDidBecomeActive() { appActive() }

    /// Scene inactivity is not observer teardown. HealthKit background
    /// delivery requires the long-running observer queries to survive while
    /// the app is inactive or suspended. Permission requests also remain valid
    /// while the system sheet temporarily inactivates the scene.
    public func appInactive() {
        observerCallbackOperationID &+= 1
        statusOperationID &+= 1
        statusTask?.cancel()
        statusTask = nil
        publish(lifecycle: .inactive, lastObserverCompletion: .replace(nil))
    }

    /// Actual background/teardown invalidates permission and status work so a
    /// late completion cannot mutate the background or a later session.
    public func applicationDidEnterBackground() {
        appInactive()
        requestOperationID &+= 1
        requestTask?.cancel()
        requestTask = nil
        publish(isRequestInFlight: false)
    }

    private func startSessionIfEligible(refreshExisting: Bool = false) {
        guard !usesVisualFixtures,
              executionAuthorizationReady,
              snapshot.authorizationState == .readIndeterminate,
              let client else { return }

        guard !sessionStarted || (refreshExisting && snapshot.lifecycle == .active) else {
            configureBackgroundDeliveryIfNeeded(client: client)
            return
        }

        if !sessionStarted {
            generation &+= 1
            sessionStarted = true
        }
        let token = generation
        let metrics = Self.supportedMetrics
        // Registration remains synchronous, and the production bridge makes
        // repeated active refreshes idempotent at the HKObserverQuery layer.
        observerCallbackOperationID &+= 1
        let callbackOperation = observerCallbackOperationID
        client.startObservers(metrics: metrics) { [weak self] completion in
            Task { @MainActor [weak self] in
                self?.receiveObserverCompletion(
                    completion,
                    generation: token,
                    callbackOperation: callbackOperation
                )
            }
        }
        configureBackgroundDeliveryIfNeeded(client: client)
    }

    private func configureBackgroundDeliveryIfNeeded(
        client: any HealthKitIntegrationClient
    ) {
        guard backgroundDeliveryTask == nil,
              snapshot.backgroundDeliveryState != .enabled else { return }

        let token = generation
        let metrics = Self.supportedMetrics
        publish(
            backgroundDeliveryState: .enabling,
            backgroundDeliveryErrorDescription: .replace(nil)
        )
        backgroundDeliveryOperationID &+= 1
        let currentOperation = backgroundDeliveryOperationID
        let task = Task { @MainActor in
            await client.configureBackgroundDelivery(metrics: metrics)
        }
        backgroundDeliveryTask = task
        Task { @MainActor [weak self] in
            let report = await task.value
            guard let self,
                  currentOperation == self.backgroundDeliveryOperationID,
                  token == self.generation else { return }
            self.backgroundDeliveryTask = nil
            self.publish(
                backgroundDeliveryState: report.state,
                backgroundDeliveryErrorDescription: .replace(report.errorDescription)
            )
        }
    }

    /// Invalidates the current observer generation before stopping the
    /// adapter. A callback already queued by HealthKit must not republish a
    /// stale session after a terminal availability result.
    private func stopSessionIfRunning() {
        guard sessionStarted else { return }
        generation &+= 1
        observerCallbackOperationID &+= 1
        backgroundDeliveryOperationID &+= 1
        sessionStarted = false
        backgroundDeliveryTask?.cancel()
        backgroundDeliveryTask = nil
        client?.stopAllObservers()
    }

    private func receiveObserverCompletion(
        _ completion: HealthKitObserverCompletion,
        generation token: UInt64,
        callbackOperation: UInt64
    ) {
        guard token == generation,
              callbackOperation == observerCallbackOperationID,
              snapshot.lifecycle == .active else { return }
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
        backgroundDeliveryState: HealthKitBackgroundDeliveryState? = nil,
        backgroundDeliveryErrorDescription: OptionalReplacement<String> = .preserve,
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
        let backgroundError: String?
        switch backgroundDeliveryErrorDescription {
        case .preserve: backgroundError = old.backgroundDeliveryErrorDescription
        case .replace(let value): backgroundError = value
        }
        snapshot = HealthKitIntegrationSnapshot(
            authorizationState: authorizationState ?? old.authorizationState,
            lifecycle: lifecycle ?? old.lifecycle,
            isRequestInFlight: isRequestInFlight ?? old.isRequestInFlight,
            explicitRequestCompleted: explicitRequestCompleted ?? old.explicitRequestCompleted,
            lastObserverCompletion: observerCompletion,
            observerCompletionSequence: observerCompletionSequence ?? old.observerCompletionSequence,
            backgroundDeliveryState: backgroundDeliveryState ?? old.backgroundDeliveryState,
            backgroundDeliveryErrorDescription: backgroundError,
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
