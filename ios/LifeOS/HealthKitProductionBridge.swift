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
    private let writeStatus: (HealthKitWriteMetric) -> HealthKitAuthorizationState
    private let writeRequest: ([HealthKitWriteMetric]) async -> HealthKitAuthorizationReport
    private let writeSample: (HealthKitWriteRequest) async -> HealthKitWriteReport
    private let configureBackground: ([HealthKitMetricID]) async -> HealthKitBackgroundDeliveryReport
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
    private var observersRegistered = false
    private var observerUpdate: ObserverUpdate?
    private var cachedBackgroundDeliveryReport: HealthKitBackgroundDeliveryReport?
    private var backgroundDeliveryTask: Task<HealthKitBackgroundDeliveryReport, Never>?
    private var backgroundDeliveryOperationID: UInt64 = 0
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
            writeStatus: { metric in adapter.writeAuthorizationStatus(for: metric) },
            writeRequest: { metrics in await adapter.requestWriteAuthorization(for: metrics) },
            write: { request in await adapter.write(request) },
            configureBackground: { metrics in
                await adapter.configureBackgroundDelivery(for: metrics)
            },
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
        registerObserver: @escaping (HealthKitMetricID, @escaping ObserverUpdate) throws -> Void,
        stopObservers: @escaping () -> Void,
        reconcile: @escaping ([HealthKitMetricID]) async -> HealthKitReconciliationReport,
        reconcileRemainder: (([HealthKitMetricID]) async -> HealthKitReconciliationReport)? = nil,
        stateReader: @escaping StoredStateReader
    ) {
        self.availability = availability
        self.status = status
        self.request = request
        self.writeStatus = writeStatus
        self.writeRequest = writeRequest
        self.writeSample = write
        self.configureBackground = configureBackground
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

    public func writeAuthorizationStatus(for metric: HealthKitWriteMetric) -> HealthKitAuthorizationState {
        guard Self.writableMetrics.contains(metric) else { return .error }
        return writeStatus(metric)
    }

    public func requestWriteAuthorization(for metrics: [HealthKitWriteMetric]) async -> HealthKitAuthorizationReport {
        guard Self.isExactWritableMetricSet(metrics) else {
            return Self.configurationRejectedWriteReport()
        }
        return Self.sanitizedAuthorizationReport(await writeRequest(metrics), operation: .writeRequest)
    }

    public func write(_ request: HealthKitWriteRequest) async -> HealthKitWriteReport {
        let authorization = writeAuthorizationStatus(for: request.metric)
        guard authorization == .writeAuthorized else {
            return .rejected(for: request.metric, state: authorization)
        }
        return Self.sanitizedWriteReport(await writeSample(request), requested: request)
    }

    public func configureBackgroundDelivery(
        metrics: [HealthKitMetricID]
    ) async -> HealthKitBackgroundDeliveryReport {
        guard Self.isExactSupportedMetricSet(metrics) else {
            return .failed(metrics)
        }
        if let cachedBackgroundDeliveryReport,
           cachedBackgroundDeliveryReport.state == .enabled {
            return cachedBackgroundDeliveryReport
        }
        if let backgroundDeliveryTask {
            return await backgroundDeliveryTask.value
        }

        backgroundDeliveryOperationID &+= 1
        let currentOperation = backgroundDeliveryOperationID
        let task = Task { @MainActor in
            await configureBackground(metrics)
        }
        backgroundDeliveryTask = task
        let rawReport = await task.value
        guard currentOperation == backgroundDeliveryOperationID else {
            return .failed(metrics)
        }
        backgroundDeliveryTask = nil
        let report = Self.sanitizedBackgroundDeliveryReport(rawReport, requested: metrics)
        if report.state == .enabled {
            cachedBackgroundDeliveryReport = report
        }
        return report
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
        guard Self.isExactSupportedMetricSet(metrics) else {
            onUpdate(.failure("HealthKit metric configuration was rejected"))
            return
        }

        observerUpdate = onUpdate
        if !observersRegistered {
            generation &+= 1
            let registrationSession = generation
            do {
                for metric in metrics {
                    try registerObserver(metric) { [weak self] completion in
                        Task { @MainActor [weak self] in
                            guard let self,
                                  self.observersRegistered,
                                  self.generation == registrationSession else { return }
                            self.receiveRegisteredObserverCompletion(completion)
                        }
                    }
                }
                observersRegistered = true
            } catch {
                // Registration is all-or-nothing. A partially installed
                // observer set must never survive as an apparently connected
                // source, and a later authorized activation may retry.
                generation &+= 1
                observersRegistered = false
                observerUpdate = nil
                stopObservers()
                onUpdate(.failure(Self.sanitizedRegistrationFailure(error)))
                return
            }
        }

        let session = generation
        sessionHasDurableCommit = false
        reconciliationTask?.cancel()
        reconciliationRemainderTask?.cancel()
        reconciliationRemainderTask = nil
        reconciliationTask = Task { @MainActor [weak self] in
            guard let self else { return }
            guard !Task.isCancelled, self.generation == session else { return }
            let report = await self.reconcile(metrics)
            guard !Task.isCancelled, self.generation == session else { return }
            self.observerUpdate?(Self.sanitizedReconciliationCompletion(report))
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
                self.observerUpdate?(Self.sanitizedReconciliationCompletion(
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
        observersRegistered = false
        observerUpdate = nil
        backgroundDeliveryOperationID &+= 1
        backgroundDeliveryTask?.cancel()
        backgroundDeliveryTask = nil
        reconciliationTask?.cancel()
        reconciliationTask = nil
        reconciliationRemainderTask?.cancel()
        reconciliationRemainderTask = nil
        stopObservers()
    }

    private func receiveRegisteredObserverCompletion(
        _ completion: HealthKitObserverCompletion
    ) {
        let update = observerUpdate
        let sanitized = Self.sanitizedReconciliationCompletion(completion)
        if case .timedOut = sanitized {
            // The adapter tears down a timed-out HKObserverQuery. Invalidate
            // the whole all-or-nothing set so the next foreground activation
            // recreates every metric instead of trusting a partial set.
            generation &+= 1
            sessionHasDurableCommit = false
            observersRegistered = false
            reconciliationTask?.cancel()
            reconciliationTask = nil
            reconciliationRemainderTask?.cancel()
            reconciliationRemainderTask = nil
            stopObservers()
        }
        update?(sanitized)
    }

    private static func isExactSupportedMetricSet(_ metrics: [HealthKitMetricID]) -> Bool {
        metrics.count == HealthKitIntegrationController.supportedMetrics.count &&
            metrics == HealthKitIntegrationController.supportedMetrics &&
            !metrics.contains(.alcoholicBeverages)
    }

    private static var writableMetrics: [HealthKitWriteMetric] {
        HealthKitIntegrationController.writableMetrics
    }

    private static func isExactWritableMetricSet(_ metrics: [HealthKitWriteMetric]) -> Bool {
        metrics.count == writableMetrics.count &&
            metrics == writableMetrics &&
            Set(metrics).count == metrics.count
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

    private static func sanitizedBackgroundDeliveryReport(
        _ report: HealthKitBackgroundDeliveryReport,
        requested metrics: [HealthKitMetricID]
    ) -> HealthKitBackgroundDeliveryReport {
        let enabled = report.enabledMetrics
        let failed = report.failedMetrics
        let enabledSet = Set(enabled)
        let failedSet = Set(failed)
        let requestedSet = Set(metrics)
        guard enabled.count == enabledSet.count,
              failed.count == failedSet.count,
              enabledSet.isDisjoint(with: failedSet),
              enabledSet.union(failedSet) == requestedSet,
              enabledSet.isSubset(of: requestedSet),
              failedSet.isSubset(of: requestedSet) else {
            return .failed(metrics)
        }

        if failed.isEmpty {
            return .enabled(metrics)
        }
        return HealthKitBackgroundDeliveryReport(
            state: enabled.isEmpty ? .failed : .partial,
            enabledMetrics: metrics.filter(enabledSet.contains),
            failedMetrics: metrics.filter(failedSet.contains),
            errorDescription: enabled.isEmpty
                ? "HealthKit background delivery could not be enabled"
                : "HealthKit background delivery is unavailable for some data types"
        )
    }

    private enum AuthorizationOperation {
        case status
        case request
        case writeRequest
    }

    private static func configurationRejectedReport() -> HealthKitAuthorizationReport {
        HealthKitAuthorizationReport(
            state: .error,
            promptCompleted: false,
            errorDescription: "HealthKit metric configuration was rejected"
        )
    }

    private static func configurationRejectedWriteReport() -> HealthKitAuthorizationReport {
        HealthKitAuthorizationReport(
            state: .error,
            promptCompleted: false,
            errorDescription: "HealthKit write metric configuration was rejected"
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
        case .writeNotDetermined:
            message = "HealthKit write access has not been requested"
        case .writeDenied:
            message = "HealthKit write access was denied"
        case .writeAuthorized:
            message = "HealthKit write authorization could not be completed"
        default:
            switch operation {
            case .status:
                message = "HealthKit authorization status could not be checked"
            case .request:
                message = "HealthKit authorization could not be completed"
            case .writeRequest:
                message = "HealthKit write authorization could not be completed"
            }
        }
        return HealthKitAuthorizationReport(
            state: report.state,
            promptCompleted: report.promptCompleted,
            errorDescription: message
        )
    }

    private static func sanitizedWriteReport(
        _ report: HealthKitWriteReport,
        requested: HealthKitWriteRequest
    ) -> HealthKitWriteReport {
        guard report.metric == requested.metric else {
            return .rejected(
                for: requested.metric,
                state: .error,
                errorDescription: "HealthKit write failed"
            )
        }
        guard report.didSave else {
            let message: String?
            switch report.authorizationState {
            case .unavailable:
                message = "HealthKit is unavailable on this device"
            case .restricted:
                message = "HealthKit is restricted on this device"
            case .protectedDataUnavailable:
                message = "Health data is unavailable while the device is locked"
            case .writeNotDetermined:
                message = "HealthKit write access has not been requested"
            case .writeDenied:
                message = "HealthKit write access was denied"
            case .writeAuthorized:
                message = "HealthKit write failed"
            default:
                message = "HealthKit write failed"
            }
            return .rejected(
                for: requested.metric,
                state: report.authorizationState,
                errorDescription: message
            )
        }
        guard report.errorDescription == nil else {
            return .rejected(
                for: requested.metric,
                state: .error,
                errorDescription: "HealthKit write failed"
            )
        }
        guard report.authorizationState == .writeAuthorized else {
            return .rejected(
                for: requested.metric,
                state: report.authorizationState,
                errorDescription: "HealthKit write failed"
            )
        }
        return .saved(for: requested.metric)
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
