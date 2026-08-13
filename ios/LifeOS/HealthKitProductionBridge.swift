#if os(iOS)
import Foundation

/// Production composition for the accepted HealthKit lifecycle controller.
/// The bridge owns the real adapter, durable app-private store, reconciler,
/// observer registration, and the initial bounded reconciliation task.
@MainActor
public final class HealthKitProductionClient: HealthKitIntegrationClient {
    public typealias ObserverUpdate = @Sendable (HealthKitObserverCompletion) -> Void

    private let availability: () -> HealthKitAuthorizationState
    private let status: ([HealthKitMetricID]) async -> HealthKitAuthorizationReport
    private let request: ([HealthKitMetricID]) async -> HealthKitAuthorizationReport
    private let registerObserver: (HealthKitMetricID, @escaping ObserverUpdate) throws -> Void
    private let stopObservers: () -> Void
    private let reconcile: ([HealthKitMetricID]) async -> HealthKitReconciliationReport

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
            reconcile: { metrics in await coordinator.reconcile(metrics: metrics) }
        )
    }

    internal init(
        availability: @escaping () -> HealthKitAuthorizationState,
        status: @escaping ([HealthKitMetricID]) async -> HealthKitAuthorizationReport,
        request: @escaping ([HealthKitMetricID]) async -> HealthKitAuthorizationReport,
        registerObserver: @escaping (HealthKitMetricID, @escaping ObserverUpdate) throws -> Void,
        stopObservers: @escaping () -> Void,
        reconcile: @escaping ([HealthKitMetricID]) async -> HealthKitReconciliationReport
    ) {
        self.availability = availability
        self.status = status
        self.request = request
        self.registerObserver = registerObserver
        self.stopObservers = stopObservers
        self.reconcile = reconcile
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
        metrics == HealthKitIntegrationController.supportedMetrics &&
            !metrics.contains(.alcoholicBeverages)
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
