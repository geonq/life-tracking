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
    private let reconcileRemainder: (([HealthKitMetricID]) async -> HealthKitReconciliationReport)?
    private let storedStateReader: StoredStateReader

    private var generation: UInt64 = 0
    /// Durable evidence from the current startup session is carried into the
    /// delayed pagination callback. The remainder runs as a fresh coordinator
    /// call, so its result cannot otherwise know that an earlier page already
    /// committed.
    private var sessionHasDurableCommit = false
    private var reconciliationTask: Task<Void, Never>?
    private var reconciliationRemainderTask: Task<Void, Never>?

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
            // Launch work is deliberately one bounded page per metric. Full
            // pagination starts only after the first-frame handoff.
            reconcile: { metrics in await coordinator.reconcileInitialPages(metrics: metrics) },
            reconcileRemainder: { metrics in await coordinator.reconcile(metrics: metrics) },
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
        reconcileRemainder: (([HealthKitMetricID]) async -> HealthKitReconciliationReport)? = nil,
        stateReader: @escaping StoredStateReader
    ) {
        self.availability = availability
        self.status = status
        self.request = request
        self.registerObserver = registerObserver
        self.stopObservers = stopObservers
        self.reconcile = reconcile
        self.reconcileRemainder = reconcileRemainder
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
        sessionHasDurableCommit = false
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
            onUpdate(Self.sanitizedReconciliationCompletion(report))
            self.sessionHasDurableCommit = report.results.contains(where: \.hasDurableCommit)

            guard let reconcileRemainder = self.reconcileRemainder else { return }
            let pendingMetrics = report.results
                .filter { $0.needsContinuation }
                .map(\.metric)
            guard !pendingMetrics.isEmpty else { return }

            // Yield the first frame and let the initial projection settle
            // before draining historical pages. This preserves eventual
            // pagination without putting the launch watchdog path back on the
            // critical foreground sequence.
            self.reconciliationRemainderTask = Task(priority: .utility) { @MainActor [weak self] in
                do {
                    try await Task.sleep(nanoseconds: 2_000_000_000)
                } catch {
                    return
                }
                guard let self,
                      !Task.isCancelled,
                      self.generation == session else { return }
                let priorDurableCommit = self.sessionHasDurableCommit
                let remainder = await reconcileRemainder(pendingMetrics)
                guard !Task.isCancelled, self.generation == session else { return }
                onUpdate(Self.sanitizedReconciliationCompletion(
                    remainder,
                    hasPriorDurableCommit: priorDurableCommit
                ))
                self.sessionHasDurableCommit = priorDurableCommit ||
                    remainder.results.contains(where: \.hasDurableCommit)
            }
        }
    }

    public func stopAllObservers() {
        generation &+= 1
        sessionHasDurableCommit = false
        reconciliationTask?.cancel()
        reconciliationTask = nil
        reconciliationRemainderTask?.cancel()
        reconciliationRemainderTask = nil
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
        // A metric observer callback has no aggregate evidence that another
        // metric committed. Never let an aggregate-only partial outcome leak
        // through this per-metric seam as a durable refresh signal.
        case .partialSuccess: .failure("HealthKit reconciliation failed")
        case .timedOut: .timedOut
        case .failure: .failure("HealthKit reconciliation failed")
        }
    }

    /// Aggregate reconciliation may durably commit some metrics before a
    /// sibling fails or times out.  Keep that durable-change signal visible to
    /// the controller without turning the aggregate failure into an ordinary
    /// success. Per-metric observer callbacks still use the completion-only
    /// sanitizer above and therefore retain their existing semantics.
    private static func sanitizedReconciliationCompletion(
        _ report: HealthKitReconciliationReport,
        hasPriorDurableCommit: Bool = false
    ) -> HealthKitObserverCompletion {
        let completion = report.completion
        guard hasPriorDurableCommit || report.results.contains(where: \.hasDurableCommit) else {
            return sanitizedReconciliationCompletion(completion)
        }

        switch completion {
        case .success:
            return .success
        case .timedOut:
            return .partialSuccess("HealthKit reconciliation timed out after a durable metric commit")
        case .failure:
            return .partialSuccess("HealthKit reconciliation partially failed after a durable metric commit")
        case .partialSuccess:
            return .partialSuccess("HealthKit reconciliation partially completed")
        }
    }
}
#endif
