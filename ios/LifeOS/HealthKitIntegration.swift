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
    public let writeAuthorizationState: HealthKitAuthorizationState
    public let lifecycle: HealthKitIntegrationLifecycle
    public let isRequestInFlight: Bool
    public let isWriteRequestInFlight: Bool
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
        writeAuthorizationState: HealthKitAuthorizationState = .writeNotDetermined,
        lifecycle: HealthKitIntegrationLifecycle = .inactive,
        isRequestInFlight: Bool = false,
        isWriteRequestInFlight: Bool = false,
        explicitRequestCompleted: Bool = false,
        lastObserverCompletion: HealthKitObserverCompletion? = nil,
        observerCompletionSequence: UInt64 = 0,
        backgroundDeliveryState: HealthKitBackgroundDeliveryState = .notConfigured,
        backgroundDeliveryErrorDescription: String? = nil,
        errorDescription: String? = nil
    ) {
        self.authorizationState = authorizationState
        self.writeAuthorizationState = writeAuthorizationState
        self.lifecycle = lifecycle
        self.isRequestInFlight = isRequestInFlight
        self.isWriteRequestInFlight = isWriteRequestInFlight
        self.explicitRequestCompleted = explicitRequestCompleted
        self.lastObserverCompletion = lastObserverCompletion
        self.observerCompletionSequence = observerCompletionSequence
        self.backgroundDeliveryState = backgroundDeliveryState
        self.backgroundDeliveryErrorDescription = backgroundDeliveryErrorDescription
        self.errorDescription = errorDescription
    }

    public var authorization: HealthKitAuthorizationState { authorizationState }
    public var writeAuthorization: HealthKitAuthorizationState { writeAuthorizationState }
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
    func requestWriteAuthorization(for metrics: [HealthKitWriteMetric]) async -> HealthKitAuthorizationReport
    func writeAuthorizationStatus(for metric: HealthKitWriteMetric) -> HealthKitAuthorizationState
    func write(_ request: HealthKitWriteRequest) async -> HealthKitWriteReport
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
    private let writeStatus: (HealthKitWriteMetric) -> HealthKitAuthorizationState
    private let writeRequest: ([HealthKitWriteMetric]) async -> HealthKitAuthorizationReport
    private let writeSample: (HealthKitWriteRequest) async -> HealthKitWriteReport
    private let configureBackground: ([HealthKitMetricID]) async -> HealthKitBackgroundDeliveryReport
    private let start: ObserverStarter
    private let stop: () -> Void

    public init(
        availability: @escaping () -> HealthKitAuthorizationState,
        status: @escaping ([HealthKitMetricID]) async -> HealthKitAuthorizationReport,
        request: @escaping ([HealthKitMetricID]) async -> HealthKitAuthorizationReport,
        writeStatus: @escaping (HealthKitWriteMetric) -> HealthKitAuthorizationState = { _ in .writeNotDetermined },
        writeRequest: @escaping ([HealthKitWriteMetric]) async -> HealthKitAuthorizationReport = { _ in
            HealthKitAuthorizationReport(state: .writeNotDetermined)
        },
        write: @escaping (HealthKitWriteRequest) async -> HealthKitWriteReport = { request in
            .rejected(for: request.metric, state: .writeNotDetermined)
        },
        configureBackground: @escaping ([HealthKitMetricID]) async -> HealthKitBackgroundDeliveryReport = {
            .enabled($0)
        },
        start: @escaping ObserverStarter,
        stop: @escaping () -> Void
    ) {
        self.availability = availability
        self.status = status
        self.request = request
        self.writeStatus = writeStatus
        self.writeRequest = writeRequest
        self.writeSample = write
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

    public func requestWriteAuthorization(for metrics: [HealthKitWriteMetric]) async -> HealthKitAuthorizationReport {
        await writeRequest(metrics)
    }

    public func writeAuthorizationStatus(for metric: HealthKitWriteMetric) -> HealthKitAuthorizationState {
        writeStatus(metric)
    }

    public func write(_ request: HealthKitWriteRequest) async -> HealthKitWriteReport {
        await writeSample(request)
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

    /// Only explicit user-authored quantities are writable. Sensor-derived
    /// metrics remain read-only to preserve HealthKit/provider provenance.
    public static let writableMetrics: [HealthKitWriteMetric] = [
        .water,
        .caffeine,
        .bodyMass,
        .bodyFatPercentage,
        .leanBodyMass
    ]

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
    private var writeRequestOperationID: UInt64 = 0
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
    private var writeRequestTask: Task<HealthKitAuthorizationReport, Never>?
    private var statusTask: Task<(HealthKitAuthorizationReport, HealthKitAuthorizationState), Never>?
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
            writeAuthorizationState: usesVisualFixtures ? .unavailable : .writeNotDetermined,
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
                return (HealthKitAuthorizationReport(state: availability), availability)
            default:
                let report = await client.requestStatus(for: metrics)
                let writeState = Self.aggregateWriteAuthorizationStatus(
                    Self.writableMetrics.map { client.writeAuthorizationStatus(for: $0) }
                )
                return (report, writeState)
            }
        }
        statusTask = task
        let (report, writeAuthorizationState) = await task.value
        guard token == generation, currentOperation == statusOperationID else { return }
        statusTask = nil
        switch report.state {
        case .unavailable, .restricted, .protectedDataUnavailable, .revoked, .error:
            executionAuthorizationReady = false
            stopSessionIfRunning()
            publish(
                authorizationState: report.state,
                writeAuthorizationState: writeAuthorizationState,
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
                writeAuthorizationState: writeAuthorizationState,
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
                writeAuthorizationState: writeAuthorizationState,
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

    /// Requests write access as a separate operation from read access. The
    /// default is deliberately non-interactive so lifecycle/setup code cannot
    /// open a write-permission sheet. A reviewed user-authored flow must pass
    /// `userInitiated: true` after its own confirmation step. The returned
    /// status is based on the typed write set and never treats the system
    /// request completion Boolean as proof that sharing was granted.
    @discardableResult
    public func requestWriteAuthorization(userInitiated: Bool = false) async -> HealthKitAuthorizationReport {
        guard !usesVisualFixtures, let client else {
            return HealthKitAuthorizationReport(state: snapshot.writeAuthorizationState)
        }

        let availability = client.availabilityState()
        switch availability {
        case .unavailable, .restricted, .protectedDataUnavailable:
            publish(writeAuthorizationState: availability, isWriteRequestInFlight: false)
            return HealthKitAuthorizationReport(state: availability)
        default:
            break
        }
        guard userInitiated else {
            return HealthKitAuthorizationReport(state: snapshot.writeAuthorizationState)
        }
        if let writeRequestTask {
            return await writeRequestTask.value
        }

        writeRequestOperationID &+= 1
        let currentOperation = writeRequestOperationID
        let metrics = Self.writableMetrics
        let task = Task { @MainActor in
            await client.requestWriteAuthorization(for: metrics)
        }
        writeRequestTask = task
        publish(isWriteRequestInFlight: true)

        let report = await task.value
        guard currentOperation == writeRequestOperationID else { return report }
        writeRequestTask = nil
        let observedState = Self.aggregateWriteAuthorizationStatus(
            metrics.map { client.writeAuthorizationStatus(for: $0) }
        )
        let state = Self.normalizedWriteAuthorizationState(report.state, observed: observedState)
        publish(
            writeAuthorizationState: state,
            isWriteRequestInFlight: false,
            errorDescription: .replace(report.errorDescription)
        )
        return HealthKitAuthorizationReport(
            state: state,
            promptCompleted: report.promptCompleted,
            errorDescription: report.errorDescription
        )
    }

    /// Writes only an already-validated typed request after an explicit user
    /// action, and rechecks the current per-type sharing authorization
    /// immediately before dispatch. The client performs the same guard at the
    /// platform boundary so a status race cannot turn a denied or failed save
    /// into success.
    @discardableResult
    public func write(_ request: HealthKitWriteRequest, userInitiated: Bool = false) async -> HealthKitWriteReport {
        guard !usesVisualFixtures, let client else {
            return .rejected(for: request.metric, state: .unavailable)
        }
        guard userInitiated else {
            return .rejected(
                for: request.metric,
                state: snapshot.writeAuthorizationState,
                errorDescription: "HealthKit writes require an explicit user action"
            )
        }

        let authorization = client.writeAuthorizationStatus(for: request.metric)
        guard authorization == .writeAuthorized else {
            publish(writeAuthorizationState: authorization)
            return .rejected(for: request.metric, state: authorization)
        }

        let report = await client.write(request)
        publish(
            writeAuthorizationState: report.authorizationState,
            errorDescription: .replace(report.errorDescription)
        )
        return report
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

    /// Marks the app foregrounded. A transition from inactive restores the
    /// observer session when the authorization gate is already open. The app
    /// scene coordinator owns the awaited status refresh; starting another
    /// unawaited status task here would race an explicit permission request.
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
        writeRequestOperationID &+= 1
        writeRequestTask?.cancel()
        writeRequestTask = nil
        publish(isRequestInFlight: false, isWriteRequestInFlight: false)
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
        writeAuthorizationState: HealthKitAuthorizationState? = nil,
        lifecycle: HealthKitIntegrationLifecycle? = nil,
        isRequestInFlight: Bool? = nil,
        isWriteRequestInFlight: Bool? = nil,
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
            writeAuthorizationState: writeAuthorizationState ?? old.writeAuthorizationState,
            lifecycle: lifecycle ?? old.lifecycle,
            isRequestInFlight: isRequestInFlight ?? old.isRequestInFlight,
            isWriteRequestInFlight: isWriteRequestInFlight ?? old.isWriteRequestInFlight,
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

    private static func aggregateWriteAuthorizationStatus(
        _ states: [HealthKitAuthorizationState]
    ) -> HealthKitAuthorizationState {
        guard !states.isEmpty else { return .error }
        if states.contains(.unavailable) { return .unavailable }
        if states.contains(.restricted) { return .restricted }
        if states.contains(.protectedDataUnavailable) { return .protectedDataUnavailable }
        if states.contains(.error) { return .error }
        if states.contains(.writeDenied) { return .writeDenied }
        if states.contains(.writeNotDetermined) { return .writeNotDetermined }
        return states.allSatisfy { $0 == .writeAuthorized } ? .writeAuthorized : .error
    }

    private static func normalizedWriteAuthorizationState(
        _ reported: HealthKitAuthorizationState,
        observed: HealthKitAuthorizationState
    ) -> HealthKitAuthorizationState {
        switch reported {
        case .unavailable, .restricted, .protectedDataUnavailable, .error:
            return reported
        case .writeNotDetermined, .writeAuthorized, .writeDenied:
            return observed == .error ? reported : observed
        default:
            return observed
        }
    }
}
#endif
