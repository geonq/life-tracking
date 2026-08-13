#if os(iOS)
import Foundation

/// Production composition for the accepted HealthKit lifecycle controller.
/// The bridge owns the real adapter, durable app-private store, reconciler,
/// observer registration, and the initial bounded reconciliation task.
@MainActor
public final class HealthKitProductionClient: HealthKitIntegrationClient {
    public typealias ObserverUpdate = @Sendable (HealthKitObserverCompletion) -> Void
    internal typealias StoredStateReader = ([HealthKitMetricID]) async -> [HealthKitStoredMetricState]

    private let availability: () -> HealthKitAuthorizationState
    private let status: ([HealthKitMetricID]) async -> HealthKitAuthorizationReport
    private let request: ([HealthKitMetricID]) async -> HealthKitAuthorizationReport
    private let registerObserver: (HealthKitMetricID, @escaping ObserverUpdate) throws -> Void
    private let stopObservers: () -> Void
    private let reconcile: ([HealthKitMetricID]) async -> HealthKitReconciliationReport
    private let storedStateReader: StoredStateReader

    private var generation: UInt64 = 0
    private var reconciliationTask: Task<Void, Never>?

    public convenience init(persistenceURL: URL? = nil) {
        let adapter = LifeOSHealthKitAdapter()
        let store = HealthKitAnchorStore(
            persistenceURL: persistenceURL ?? HealthKitIntegrationController.defaultPersistenceURL
        )
        let coordinator = HealthKitReconciliationCoordinator(client: adapter, store: store)
        self.init(
            availability: { adapter.availabilityState() },
            status: { metrics in await adapter.requestStatus(for: metrics) },
            request: { metrics in await adapter.requestReadAuthorization(for: metrics) },
            registerObserver: { metric, update in
                _ = try adapter.startObserver(for: metric, reconciler: coordinator, completion: update)
            },
            stopObservers: { adapter.stopAllObservers() },
            reconcile: { metrics in await coordinator.reconcile(metrics: metrics) },
            stateReader: { metrics in
                // The reader and reconciler intentionally capture the same
                // actor. A load failure must remain an error rather than
                // looking like a first-launch empty store.
                guard !(await store.hasLoadFailure()) else {
                    return metrics.map(Self.errorState(for:))
                }
                var states: [HealthKitStoredMetricState] = []
                states.reserveCapacity(metrics.count)
                for metric in metrics {
                    states.append(await store.snapshot(for: metric))
                }
                guard !(await store.hasLoadFailure()) else {
                    return metrics.map(Self.errorState(for:))
                }
                return states
            }
        )
    }

    internal init(
        availability: @escaping () -> HealthKitAuthorizationState,
        status: @escaping ([HealthKitMetricID]) async -> HealthKitAuthorizationReport,
        request: @escaping ([HealthKitMetricID]) async -> HealthKitAuthorizationReport,
        registerObserver: @escaping (HealthKitMetricID, @escaping ObserverUpdate) throws -> Void,
        stopObservers: @escaping () -> Void,
        reconcile: @escaping ([HealthKitMetricID]) async -> HealthKitReconciliationReport,
        stateReader: @escaping StoredStateReader
    ) {
        self.availability = availability
        self.status = status
        self.request = request
        self.registerObserver = registerObserver
        self.stopObservers = stopObservers
        self.reconcile = reconcile
        self.storedStateReader = stateReader
    }

    public func availabilityState() -> HealthKitAuthorizationState { availability() }

    public func requestStatus(for metrics: [HealthKitMetricID]) async -> HealthKitAuthorizationReport {
        guard Self.isExactSupportedMetricSet(metrics) else {
            return Self.configurationRejectedReport()
        }
        return Self.sanitizedAuthorizationReport(await status(metrics), operation: .status)
    }

    public func requestReadAuthorization(for metrics: [HealthKitMetricID]) async -> HealthKitAuthorizationReport {
        guard Self.isExactSupportedMetricSet(metrics) else {
            return Self.configurationRejectedReport()
        }
        return Self.sanitizedAuthorizationReport(await request(metrics), operation: .request)
    }

    /// Returns the bounded durable HealthKit projection in the caller's
    /// requested order. This is deliberately narrower than exposing the
    /// mutable actor store: only the exact app-supported, alcohol-free set can
    /// be read, and malformed reader output fails closed to error states.
    public func storedStates(for metrics: [HealthKitMetricID]) async -> [HealthKitStoredMetricState] {
        guard Self.isExactSupportedMetricSet(metrics) else { return [] }
        let states = await storedStateReader(metrics)
        return Self.orderedStoredStates(states, for: metrics)
    }

    public func startObservers(
        metrics: [HealthKitMetricID],
        onUpdate: @escaping ObserverUpdate
    ) {
        stopAllObservers()
        guard Self.isExactSupportedMetricSet(metrics) else {
            onUpdate(.failure("HealthKit metric configuration was rejected"))
            return
        }

        generation &+= 1
        let session = generation
        do {
            for metric in metrics {
                try registerObserver(metric) { [weak self] completion in
                    Task { @MainActor [weak self] in
                        guard let self, self.generation == session else { return }
                        onUpdate(Self.sanitizedReconciliationCompletion(completion))
                    }
                }
            }
        } catch {
            // Registration is all-or-nothing. A partially installed observer
            // set must never survive as an apparently connected source.
            generation &+= 1
            stopObservers()
            onUpdate(.failure(Self.sanitizedRegistrationFailure(error)))
            return
        }

        reconciliationTask = Task { @MainActor [weak self] in
            guard let self else { return }
            guard !Task.isCancelled, self.generation == session else { return }
            let report = await self.reconcile(metrics)
            guard !Task.isCancelled, self.generation == session else { return }
            onUpdate(Self.sanitizedReconciliationCompletion(report.completion))
        }
    }

    public func stopAllObservers() {
        generation &+= 1
        reconciliationTask?.cancel()
        reconciliationTask = nil
        stopObservers()
    }

    private static func isExactSupportedMetricSet(_ metrics: [HealthKitMetricID]) -> Bool {
        metrics.count == HealthKitIntegrationController.supportedMetrics.count &&
            metrics == HealthKitIntegrationController.supportedMetrics &&
            !metrics.contains(.alcoholicBeverages)
    }

    private static func orderedStoredStates(
        _ states: [HealthKitStoredMetricState],
        for metrics: [HealthKitMetricID]
    ) -> [HealthKitStoredMetricState] {
        guard states.count == metrics.count else {
            return metrics.map(errorState(for:))
        }

        var byMetric: [HealthKitMetricID: HealthKitStoredMetricState] = [:]
        byMetric.reserveCapacity(states.count)
        for state in states {
            guard metrics.contains(state.metric),
                  byMetric[state.metric] == nil,
                  isBoundedStoredState(state) else {
                return metrics.map(errorState(for:))
            }
            byMetric[state.metric] = state
        }

        guard byMetric.count == metrics.count else {
            return metrics.map(errorState(for:))
        }
        return metrics.compactMap { byMetric[$0] }
    }

    private static func isBoundedStoredState(_ state: HealthKitStoredMetricState) -> Bool {
        state.observations.count <= HealthKitSafetyLimits.maxProjectionItems &&
            state.tombstones.count <= HealthKitSafetyLimits.maxProjectionItems &&
            state.sourceIndex.count <= HealthKitSafetyLimits.maxSourceIndexItems &&
            state.conflicts.count <= HealthKitSafetyLimits.maxConflictItems &&
            state.observations.allSatisfy { $0.metric == state.metric } &&
            state.tombstones.allSatisfy { $0.metric == state.metric } &&
            state.conflicts.allSatisfy { $0.metric == state.metric }
    }

    private static func errorState(for metric: HealthKitMetricID) -> HealthKitStoredMetricState {
        // A finite commit date is required for a persisted `.error` state;
        // the value is diagnostic only and never represents observed data.
        guard let projection = try? HealthKitMetricProjection(
            metric: metric,
            lastCommittedAt: Date(timeIntervalSinceReferenceDate: 0),
            syncState: .error
        ) else {
            return .empty(for: metric)
        }
        return HealthKitStoredMetricState(projection: projection)
    }

    private static func sanitizedRegistrationFailure(_ error: Error) -> String {
        switch error as? HealthKitAdapterError {
        case .unavailable: "HealthKit is unavailable on this device"
        case .restricted: "HealthKit is restricted on this device"
        case .protectedDataUnavailable: "Health data is unavailable while the device is locked"
        default: "HealthKit observers could not start"
        }
    }

    private enum AuthorizationOperation {
        case status
        case request
    }

    private static func configurationRejectedReport() -> HealthKitAuthorizationReport {
        HealthKitAuthorizationReport(
            state: .error,
            promptCompleted: false,
            errorDescription: "HealthKit metric configuration was rejected"
        )
    }

    private static func sanitizedAuthorizationReport(
        _ report: HealthKitAuthorizationReport,
        operation: AuthorizationOperation
    ) -> HealthKitAuthorizationReport {
        guard report.errorDescription != nil else { return report }
        let message: String
        switch report.state {
        case .unavailable:
            message = "HealthKit is unavailable on this device"
        case .restricted:
            message = "HealthKit is restricted on this device"
        case .protectedDataUnavailable:
            message = "Health data is unavailable while the device is locked"
        case .readIndeterminate:
            message = "HealthKit read access is indeterminate"
        default:
            message = operation == .status
                ? "HealthKit authorization status could not be checked"
                : "HealthKit authorization could not be completed"
        }
        return HealthKitAuthorizationReport(
            state: report.state,
            promptCompleted: report.promptCompleted,
            errorDescription: message
        )
    }

    private static func sanitizedReconciliationCompletion(
        _ completion: HealthKitObserverCompletion
    ) -> HealthKitObserverCompletion {
        switch completion {
        case .success: .success
        case .timedOut: .timedOut
        case .failure: .failure("HealthKit reconciliation failed")
        }
    }
}
#endif
