import Foundation

#if os(iOS) && canImport(HealthKit)
import HealthKit
#endif

public enum HealthKitAdapterError: Error, Equatable, Sendable {
    case unavailable
    case restricted
    case protectedDataUnavailable
    case readAccessIndeterminate
    case unsupportedMetric(HealthKitMetricID)
    case invalidAnchor
    case invalidSample(String)
    case queryFailed(String)
    case authorizationFailed(String)

    public static func mappedHealthKitError(domain: String, code: Int, description: String) -> HealthKitAdapterError {
        if domain == NSPOSIXErrorDomain,
           let rawPOSIXCode = Int32(exactly: code),
           let posixCode = POSIXErrorCode(rawValue: rawPOSIXCode),
           posixCode == .EPERM || posixCode == .EACCES {
            return .protectedDataUnavailable
        }
#if os(iOS) && canImport(HealthKit)
        guard domain == HKErrorDomain else { return .queryFailed(description) }
        switch HKError.Code(rawValue: code) {
        case .errorHealthDataUnavailable: return .unavailable
        case .errorHealthDataRestricted: return .restricted
        case .errorDatabaseInaccessible: return .protectedDataUnavailable
        // HealthKit does not expose per-type read authorization. A denied,
        // not-determined, required-denied, or no-data query must remain
        // ambiguous rather than being relabeled as zero/no data.
        case .errorAuthorizationDenied,
             .errorAuthorizationNotDetermined,
             .errorRequiredAuthorizationDenied,
             .errorNoData:
            return .readAccessIndeterminate
        default: return .queryFailed(description)
        }
#else
        // HealthKit transport is intentionally iOS-only. Non-iOS targets can
        // preserve the typed error surface but cannot interpret HK codes.
        return .queryFailed(description)
#endif
    }
}

public struct HealthKitAuthorizationReport: Equatable, Sendable {
    public let state: HealthKitAuthorizationState
    public let promptCompleted: Bool?
    public let errorDescription: String?

    public init(state: HealthKitAuthorizationState, promptCompleted: Bool? = nil, errorDescription: String? = nil) {
        self.state = state
        self.promptCompleted = promptCompleted
        self.errorDescription = errorDescription
    }
}

/// The result of one guarded, user-authored HealthKit write. Authorization is
/// reported separately from the save result: a denied or unavailable write is
/// never represented as a successful no-op.
public struct HealthKitWriteReport: Equatable, Sendable {
    public let metric: HealthKitWriteMetric
    public let authorizationState: HealthKitAuthorizationState
    public let didSave: Bool
    public let errorDescription: String?

    public init(
        metric: HealthKitWriteMetric,
        authorizationState: HealthKitAuthorizationState,
        didSave: Bool,
        errorDescription: String? = nil
    ) {
        self.metric = metric
        self.authorizationState = authorizationState
        self.didSave = didSave
        self.errorDescription = errorDescription
    }

    public static func saved(for metric: HealthKitWriteMetric) -> Self {
        Self(metric: metric, authorizationState: .writeAuthorized, didSave: true)
    }

    public static func rejected(
        for metric: HealthKitWriteMetric,
        state: HealthKitAuthorizationState,
        errorDescription: String? = nil
    ) -> Self {
        Self(
            metric: metric,
            authorizationState: state,
            didSave: false,
            errorDescription: errorDescription
        )
    }
}

/// The cadence LifeOS asks HealthKit to use when activating the app for a
/// supported sample type. This is a request to the system, not a delivery SLA:
/// iOS may coalesce updates and enforces a minimum hourly cadence for types
/// such as step count.
public enum HealthKitBackgroundDeliveryCadence: String, Equatable, Sendable {
    case immediate
    case hourly
}

public enum HealthKitBackgroundDeliveryState: String, Equatable, Sendable {
    case notConfigured
    case enabling
    case enabled
    case partial
    case failed
}

/// Sanitized result of configuring HealthKit activation. It carries metric
/// identifiers only; provider errors and HealthKit payloads never cross the
/// production bridge into UI state or logs.
public struct HealthKitBackgroundDeliveryReport: Equatable, Sendable {
    public let state: HealthKitBackgroundDeliveryState
    public let enabledMetrics: [HealthKitMetricID]
    public let failedMetrics: [HealthKitMetricID]
    public let errorDescription: String?

    public init(
        state: HealthKitBackgroundDeliveryState,
        enabledMetrics: [HealthKitMetricID] = [],
        failedMetrics: [HealthKitMetricID] = [],
        errorDescription: String? = nil
    ) {
        self.state = state
        self.enabledMetrics = enabledMetrics
        self.failedMetrics = failedMetrics
        self.errorDescription = errorDescription
    }

    public static func enabled(_ metrics: [HealthKitMetricID]) -> Self {
        Self(state: .enabled, enabledMetrics: metrics)
    }

    public static func failed(_ metrics: [HealthKitMetricID]) -> Self {
        Self(
            state: .failed,
            failedMetrics: metrics,
            errorDescription: "HealthKit background delivery could not be enabled"
        )
    }
}

#if os(iOS) && canImport(HealthKit)
private final class HealthKitAnchoredQueryState<Value: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private let store: HKHealthStore
    private var continuation: CheckedContinuation<Value, Error>?
    private var query: HKAnchoredObjectQuery?
    private var finished = false

    init(store: HKHealthStore) { self.store = store }

    func setContinuation(_ continuation: CheckedContinuation<Value, Error>) {
        lock.lock()
        if finished {
            lock.unlock()
            continuation.resume(throwing: CancellationError())
        } else {
            self.continuation = continuation
            lock.unlock()
        }
    }

    func setQuery(_ query: HKAnchoredObjectQuery) {
        lock.lock()
        if finished {
            lock.unlock()
            store.stop(query)
        } else {
            self.query = query
            lock.unlock()
        }
    }

    func finish(_ result: Result<Value, Error>) {
        lock.lock()
        guard !finished, let continuation else {
            lock.unlock()
            return
        }
        finished = true
        self.continuation = nil
        lock.unlock()
        continuation.resume(with: result)
    }

    func cancel() {
        lock.lock()
        guard !finished else {
            lock.unlock()
            return
        }
        finished = true
        let continuation = self.continuation
        self.continuation = nil
        let query = self.query
        lock.unlock()
        if let query { store.stop(query) }
        continuation?.resume(throwing: CancellationError())
    }
}

private final class HealthKitObserverQueryState: @unchecked Sendable {
    private let lock = NSLock()
    private let store: HKHealthStore
    private var query: HKObserverQuery?
    private var stopped = false
    private var taskState: HealthKitObserverTaskState?
    private var cancellationHandlers: [UUID: @Sendable () -> Void] = [:]

    init(store: HKHealthStore) { self.store = store }

    func setQuery(_ query: HKObserverQuery) {
        lock.lock()
        guard !stopped else {
            lock.unlock()
            store.stop(query)
            return
        }
        self.query = query
        lock.unlock()
    }

    @discardableResult
    func beginCallback() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return !stopped
    }

    func setTaskState(_ taskState: HealthKitObserverTaskState) {
        lock.lock()
        if stopped {
            lock.unlock()
            taskState.cancel()
        } else {
            self.taskState = taskState
            lock.unlock()
        }
    }

    @discardableResult
    func registerCancellation(id: UUID, handler: @escaping @Sendable () -> Void) -> Bool {
        lock.lock()
        if stopped {
            lock.unlock()
            handler()
            return false
        } else {
            cancellationHandlers[id] = handler
            lock.unlock()
            return true
        }
    }

    func unregisterCancellation(id: UUID) {
        lock.lock()
        cancellationHandlers.removeValue(forKey: id)
        lock.unlock()
    }

    func stop() {
        lock.lock()
        guard !stopped else {
            lock.unlock()
            return
        }
        stopped = true
        let query = self.query
        let taskState = self.taskState
        let handlers = Array(cancellationHandlers.values)
        cancellationHandlers.removeAll()
        lock.unlock()
        if let query { store.stop(query) }
        taskState?.cancel()
        handlers.forEach { $0() }
    }
}

private final class HealthKitObserverTaskState: @unchecked Sendable {
    private let lock = NSLock()
    private var task: Task<Void, Never>?

    func set(_ task: Task<Void, Never>) {
        lock.lock()
        self.task = task
        lock.unlock()
    }

    func cancel() {
        lock.lock()
        let task = self.task
        lock.unlock()
        task?.cancel()
    }
}

/// iOS-only HealthKit adapter. It owns one HKHealthStore and exposes bounded
/// reads plus an explicitly typed, user-authored write path. No view or macOS
/// target imports HealthKit through this type; the shared contract above
/// remains platform-neutral.
public final class LifeOSHealthKitAdapter: @unchecked Sendable, HealthKitReconciliationClient {
    /// A finite page keeps an unexpectedly large HealthKit store bounded. The
    /// returned opaque anchor is the continuation point for the next bounded
    /// page; the reconciliation coordinator owns draining those pages.
    public static let defaultQueryLimit = 500

    private struct ObservationConversion {
        let observations: [HealthKitObservation]
        let quarantineDiagnostics: [HealthKitQuarantineDiagnostic]
    }

    public let store: HKHealthStore
    private let evidenceRegistry: HealthKitHelioEvidenceRegistry
    private let queryLimit: Int
    private let observerStatesLock = NSLock()
    private var observerStates: [ObjectIdentifier: HealthKitObserverQueryState] = [:]

    public init(
        store: HKHealthStore = HKHealthStore(),
        evidenceRegistry: HealthKitHelioEvidenceRegistry = .canonical,
        queryLimit: Int = LifeOSHealthKitAdapter.defaultQueryLimit
    ) {
        self.store = store
        // Persisted and newly-adapted provenance must use the same reviewed
        // inventory. The parameter remains source-compatible for callers but
        // cannot smuggle an unreviewed registry into HealthKit observations.
        _ = evidenceRegistry
        self.evidenceRegistry = .canonical
        // HKObjectQueryNoLimit is intentionally not accepted as an unbounded
        // default (or through a corrupted caller value). Keep every request
        // within a finite safety envelope.
        self.queryLimit = min(HealthKitSafetyLimits.maxSyncBatchItems, max(1, queryLimit))
    }

    public static func isSupportedMetric(_ metric: HealthKitMetricID) -> Bool {
        metric != .alcoholicBeverages
    }

    /// High-volume physiological and cumulative signals use an hourly wake
    /// request to bound energy/CPU cost. Discrete user-entered and episode
    /// samples can request immediate activation. Both remain best-effort under
    /// HealthKit's documented scheduling rules.
    public static func backgroundDeliveryCadence(
        for metric: HealthKitMetricID
    ) -> HealthKitBackgroundDeliveryCadence? {
        switch metric {
        case .alcoholicBeverages:
            return nil
        case .water, .caffeine, .bodyMass, .bodyFatPercentage, .leanBodyMass,
             .sleep, .workout:
            return .immediate
        case .heartRate, .restingHeartRate, .heartRateVariabilitySDNN,
             .oxygenSaturation, .vo2Max, .activeEnergy, .steps, .respiratoryRate:
            return .hourly
        }
    }

    public var isHealthDataAvailable: Bool {
        HKHealthStore.isHealthDataAvailable()
    }

    public func availabilityState() -> HealthKitAuthorizationState {
        isHealthDataAvailable ? .readIndeterminate : .unavailable
    }

    public func requestStatus(for metrics: [HealthKitMetricID]) async -> HealthKitAuthorizationReport {
        guard isHealthDataAvailable else { return HealthKitAuthorizationReport(state: .unavailable) }
        do {
            let status = try await requestStatusValue(for: metrics)
            switch status {
            case .shouldRequest:
                return HealthKitAuthorizationReport(state: .requestRequired)
            case .unnecessary:
                return HealthKitAuthorizationReport(state: .readIndeterminate)
            case .unknown:
                return HealthKitAuthorizationReport(state: .requestPending)
            @unknown default:
                return HealthKitAuthorizationReport(state: .requestPending)
            }
        } catch {
            switch Self.map(error) {
            case .unavailable: return HealthKitAuthorizationReport(state: .unavailable, errorDescription: error.localizedDescription)
            case .restricted: return HealthKitAuthorizationReport(state: .restricted, errorDescription: error.localizedDescription)
            case .protectedDataUnavailable: return HealthKitAuthorizationReport(state: .protectedDataUnavailable, errorDescription: error.localizedDescription)
            case .readAccessIndeterminate: return HealthKitAuthorizationReport(state: .readIndeterminate, errorDescription: error.localizedDescription)
            default: return HealthKitAuthorizationReport(state: .error, errorDescription: error.localizedDescription)
            }
        }
    }

    /// The completion Boolean says only that the request sheet completed. It
    /// is never mapped to per-type read authorization, because HealthKit does
    /// not expose that information to the app.
    public func requestReadAuthorization(for metrics: [HealthKitMetricID]) async -> HealthKitAuthorizationReport {
        guard isHealthDataAvailable else { return HealthKitAuthorizationReport(state: .unavailable) }
        do {
            let types = try objectTypes(for: metrics)
            let success = try await requestAuthorization(read: types, write: [])
            return HealthKitAuthorizationReport(
                state: .readIndeterminate,
                promptCompleted: success,
                errorDescription: nil
            )
        } catch {
            let mapped = Self.map(error)
            let state: HealthKitAuthorizationState
            switch mapped {
            case .unavailable: state = .unavailable
            case .restricted: state = .restricted
            case .protectedDataUnavailable: state = .protectedDataUnavailable
            default: state = .readIndeterminate
            }
            return HealthKitAuthorizationReport(state: state, promptCompleted: false, errorDescription: error.localizedDescription)
        }
    }

    /// Requests write authorization only for the reviewed, user-authored
    /// quantity set. Read authorization is deliberately not inferred from
    /// this request, and HealthKit's completion Boolean is followed by a
    /// per-type `authorizationStatus(for:)` read before returning.
    public func requestWriteAuthorization(for metrics: [HealthKitWriteMetric]) async -> HealthKitAuthorizationReport {
        guard isHealthDataAvailable else { return HealthKitAuthorizationReport(state: .unavailable) }
        guard !metrics.isEmpty, Set(metrics).count == metrics.count else {
            return HealthKitAuthorizationReport(
                state: .error,
                promptCompleted: false,
                errorDescription: "HealthKit write metric configuration was rejected"
            )
        }

        do {
            let types = try writableObjectTypes(for: metrics)
            let success = try await requestAuthorization(read: [], write: types)
            return HealthKitAuthorizationReport(
                state: writeAuthorizationStatus(for: metrics),
                promptCompleted: success,
                errorDescription: nil
            )
        } catch {
            let mapped = Self.map(error)
            return HealthKitAuthorizationReport(
                state: Self.writeAuthorizationState(for: mapped),
                promptCompleted: false,
                errorDescription: error.localizedDescription
            )
        }
    }

    /// Configures background activation only for the read types in LifeOS's
    /// reviewed HealthKit contract. This does not request authorization and it
    /// never asks HealthKit for write access.
    public func configureBackgroundDelivery(
        for metrics: [HealthKitMetricID]
    ) async -> HealthKitBackgroundDeliveryReport {
        guard isHealthDataAvailable else { return .failed(metrics) }

        var enabled: [HealthKitMetricID] = []
        var failed: [HealthKitMetricID] = []
        enabled.reserveCapacity(metrics.count)
        failed.reserveCapacity(metrics.count)

        for metric in metrics {
            guard let cadence = Self.backgroundDeliveryCadence(for: metric),
                  let type = try? objectType(for: metric) else {
                failed.append(metric)
                continue
            }
            do {
                try await store.enableBackgroundDelivery(
                    for: type,
                    frequency: cadence.healthKitFrequency
                )
                enabled.append(metric)
            } catch {
                failed.append(metric)
            }
        }

        if failed.isEmpty {
            return .enabled(enabled)
        }
        return HealthKitBackgroundDeliveryReport(
            state: enabled.isEmpty ? .failed : .partial,
            enabledMetrics: enabled,
            failedMetrics: failed,
            errorDescription: enabled.isEmpty
                ? "HealthKit background delivery could not be enabled"
                : "HealthKit background delivery is unavailable for some data types"
        )
    }

    public func writeAuthorizationStatus(for metric: HealthKitWriteMetric) -> HealthKitAuthorizationState {
        guard isHealthDataAvailable else { return .unavailable }
        guard let type = try? objectType(for: metric.metricID) else { return .error }
        switch store.authorizationStatus(for: type) {
        case .notDetermined: return .writeNotDetermined
        case .sharingAuthorized: return .writeAuthorized
        case .sharingDenied: return .writeDenied
        @unknown default: return .error
        }
    }

    public func writeAuthorizationStatus(for metrics: [HealthKitWriteMetric]) -> HealthKitAuthorizationState {
        guard !metrics.isEmpty, Set(metrics).count == metrics.count else { return .error }
        return Self.aggregateWriteAuthorizationStatus(metrics.map { writeAuthorizationStatus(for: $0) })
    }

    /// Compatibility overload for callers that already hold a LifeOS metric.
    /// Unsupported/imported metrics cannot be written through this boundary.
    public func writeAuthorizationStatus(for metric: HealthKitMetricID) -> HealthKitAuthorizationState {
        guard let writableMetric = HealthKitWriteMetric(metric: metric) else { return .error }
        return writeAuthorizationStatus(for: writableMetric)
    }

    /// Saves one validated, explicit user-authored quantity after rechecking
    /// the current HealthKit sharing authorization. A status race or platform
    /// error remains a failed report; it is never converted into success.
    public func write(_ request: HealthKitWriteRequest) async -> HealthKitWriteReport {
        guard isHealthDataAvailable else {
            return .rejected(for: request.metric, state: .unavailable)
        }

        let authorization = writeAuthorizationStatus(for: request.metric)
        guard authorization == .writeAuthorized else {
            return .rejected(for: request.metric, state: authorization)
        }

        do {
            guard let type = try objectType(for: request.metric.metricID) as? HKQuantityType else {
                return .rejected(
                    for: request.metric,
                    state: .error,
                    errorDescription: "HealthKit write type was unsupported"
                )
            }
            let quantity = try healthKitQuantity(for: request)
            let sample = HKQuantitySample(
                type: type,
                quantity: quantity,
                start: request.startDate,
                end: request.endDate
            )
            try await save(sample)
            return .saved(for: request.metric)
        } catch {
            return Self.writeFailure(for: request.metric, error: error)
        }
    }

    public func changes(for metric: HealthKitMetricID, from anchor: HealthKitOpaqueAnchor?) async throws -> HealthKitMetricSyncInput {
        guard isHealthDataAvailable else { throw HealthKitAdapterError.unavailable }
        let type = try objectType(for: metric)
        let hkAnchor = try unarchive(anchor)
        let queryStartedAt = Date()
        // The first unanchored read is a bounded seed. Once HealthKit has
        // issued an anchor, continuation queries intentionally use no date
        // predicate: the anchor is the provider's change-log cursor and must
        // continue to surface deletions/updates for retained objects even if
        // their original sample date has crossed the rolling boundary.
        let predicate: NSPredicate?
        if anchor == nil {
            let startDate = queryStartedAt.addingTimeInterval(-HealthKitSafetyLimits.healthObservationRetention)
            predicate = HKQuery.predicateForSamples(withStart: startDate, end: nil, options: [])
        } else {
            predicate = nil
        }
        let queryState = HealthKitAnchoredQueryState<HealthKitMetricSyncInput>(store: store)
        return try await withTaskCancellationHandler(operation: {
            try await withCheckedThrowingContinuation { continuation in
                queryState.setContinuation(continuation)
                let query = HKAnchoredObjectQuery(
                    type: type,
                    predicate: predicate,
                    anchor: hkAnchor,
                    limit: queryLimit
                ) { [weak self, weak queryState] _, samples, deleted, newAnchor, error in
                    guard let queryState else { return }
                    guard let self else {
                        queryState.finish(.failure(HealthKitAdapterError.queryFailed("Adapter was released")))
                        return
                    }
                    if let error {
                        queryState.finish(.failure(Self.map(error)))
                        return
                    }
                    let queryCompletedAt = Date()
                    Task {
                        do {
                            let conversion = self.observations(metric: metric, samples: samples ?? [], now: queryCompletedAt)
                            let additions = conversion.observations
                            let deletions = try self.tombstones(metric: metric, deleted: deleted ?? [], deletedAt: queryCompletedAt)
                            let objectCount = (samples?.count ?? 0) + (deleted?.count ?? 0)
                            let partial = objectCount >= self.queryLimit
                            // HealthKit defines this as the anchor to pass to
                            // the next anchored query. Persisting it for a
                            // partial page lets reconciliation continue from
                            // this page without replaying the entire store.
                            let nextAnchor = try self.archive(newAnchor)
                            let readability: HealthKitReadability =
                                objectCount == 0 && anchor == nil ? .emptyIndeterminate : .established
                            let input = try HealthKitMetricSyncInput(
                                metric: metric,
                                additions: additions,
                                deletions: deletions,
                                nextAnchor: nextAnchor,
                                queryCompletedAt: queryCompletedAt,
                                partial: partial,
                                readability: readability,
                                quarantineDiagnostics: conversion.quarantineDiagnostics
                            )
                            queryState.finish(.success(input))
                        } catch {
                            queryState.finish(.failure(error))
                        }
                    }
                }
                queryState.setQuery(query)
                self.store.execute(query)
            }
        }, onCancel: {
            queryState.cancel()
        })
    }

    /// Installs a background observer. Each callback performs at most one
    /// bounded page and durable commit before calling HealthKit's completion.
    /// If more pages remain, they drain on a utility task after the system has
    /// been released. The once-only gate still covers error/timeout races.
    @discardableResult
    public func startObserver(
        for metric: HealthKitMetricID,
        reconciler: HealthKitReconciliationCoordinator,
        timeout: TimeInterval = 10,
        completion: @escaping @Sendable (HealthKitObserverCompletion) -> Void
    ) throws -> HKObserverQuery {
        guard isHealthDataAvailable else { throw HealthKitAdapterError.unavailable }
        let type = try objectType(for: metric)
        let normalizedTimeout = HealthKitReconciliationCoordinator.normalizedTimeout(timeout)
        let queryState = HealthKitObserverQueryState(store: store)
        let query = HKObserverQuery(sampleType: type, predicate: nil) { [weak self, weak reconciler, queryState] _, healthKitCompletion, error in
            guard queryState.beginCallback() else {
                // A stopped observer may still deliver a platform callback.
                // Complete this callback without starting reconciliation.
                healthKitCompletion()
                return
            }
            let gate = HealthKitObserverCompletionGate(timeout: normalizedTimeout)
            if let error {
                gate.finish(.failure(error.localizedDescription), completion: healthKitCompletion, report: completion)
                return
            }
            guard self != nil, let reconciler else {
                gate.finish(.failure("Adapter was released"), completion: healthKitCompletion, report: completion)
                return
            }
            let taskState = HealthKitObserverTaskState()
            let callbackID = UUID()
            let reconciliationTask = Task {
                let report = await reconciler.reconcileInitialPages(metrics: [metric])
                queryState.unregisterCancellation(id: callbackID)
                gate.finish(report.completion, completion: healthKitCompletion, report: completion)

                let pendingMetrics = report.results
                    .filter(\.needsContinuation)
                    .map(\.metric)
                guard !pendingMetrics.isEmpty,
                      !Task.isCancelled,
                      queryState.beginCallback() else { return }

                let remainderID = UUID()
                let remainderTask = Task(priority: .utility) {
                    let remainder = await reconciler.reconcile(metrics: pendingMetrics)
                    queryState.unregisterCancellation(id: remainderID)
                    guard !Task.isCancelled, queryState.beginCallback() else { return }
                    completion(remainder.completion)
                }
                queryState.registerCancellation(id: remainderID) {
                    remainderTask.cancel()
                }
            }
            taskState.set(reconciliationTask)
            queryState.setTaskState(taskState)
            queryState.registerCancellation(id: callbackID) {
                reconciliationTask.cancel()
            }
            Task {
                try? await Task.sleep(nanoseconds: UInt64(normalizedTimeout * 1_000_000_000))
                gate.finish(
                    .timedOut,
                    completion: healthKitCompletion,
                    report: completion,
                    onFirst: {
                        queryState.unregisterCancellation(id: callbackID)
                        taskState.cancel()
                        queryState.stop()
                        self?.unregisterObserver(queryState)
                    }
                )
            }
        }
        queryState.setQuery(query)
        registerObserver(queryState, for: query)
        return query
    }

    public func stopObserver(_ query: HKObserverQuery) {
        if let state = unregisterObserver(query) {
            state.stop()
        } else {
            store.stop(query)
        }
    }

    /// Idempotently stops every observer and cancels any reconciliation or
    /// timeout task associated with its callback. It is safe to call from
    /// lifecycle teardown while a callback is concurrently being delivered.
    public func stopAllObservers() {
        observerStatesLock.lock()
        let states = Array(observerStates.values)
        observerStates.removeAll()
        observerStatesLock.unlock()
        states.forEach { $0.stop() }
    }

    private func registerObserver(_ state: HealthKitObserverQueryState, for query: HKObserverQuery) {
        observerStatesLock.lock()
        observerStates[ObjectIdentifier(query)] = state
        // Serialize registration with stopAll/stopObserver so a teardown
        // cannot stop a query between registration and execute().
        store.execute(query)
        observerStatesLock.unlock()
    }

    @discardableResult
    private func unregisterObserver(_ query: HKObserverQuery) -> HealthKitObserverQueryState? {
        observerStatesLock.lock()
        let state = observerStates.removeValue(forKey: ObjectIdentifier(query))
        observerStatesLock.unlock()
        return state
    }

    private func unregisterObserver(_ state: HealthKitObserverQueryState) {
        observerStatesLock.lock()
        observerStates = observerStates.filter { $0.value !== state }
        observerStatesLock.unlock()
    }

    private func objectTypes(for metrics: [HealthKitMetricID]) throws -> Set<HKObjectType> {
        Set(try metrics.map { try objectType(for: $0) })
    }

    private func writableObjectTypes(for metrics: [HealthKitWriteMetric]) throws -> Set<HKSampleType> {
        Set(try metrics.map { try objectType(for: $0.metricID) })
    }

    private static func map(_ error: Error) -> HealthKitAdapterError {
        if let error = error as? HealthKitAdapterError { return error }
        let nsError = error as NSError
        return HealthKitAdapterError.mappedHealthKitError(domain: nsError.domain, code: nsError.code, description: nsError.localizedDescription)
    }

    private func objectType(for metric: HealthKitMetricID) throws -> HKSampleType {
        switch metric {
        case .sleep:
            guard let type = HKObjectType.categoryType(forIdentifier: .sleepAnalysis) else { throw HealthKitAdapterError.unsupportedMetric(metric) }
            return type
        case .workout:
            return HKObjectType.workoutType()
        default:
            let identifier: HKQuantityTypeIdentifier
            switch metric {
            case .water: identifier = .dietaryWater
            case .caffeine: identifier = .dietaryCaffeine
            case .alcoholicBeverages: throw HealthKitAdapterError.unsupportedMetric(metric)
            case .heartRate: identifier = .heartRate
            case .restingHeartRate: identifier = .restingHeartRate
            case .heartRateVariabilitySDNN: identifier = .heartRateVariabilitySDNN
            case .oxygenSaturation: identifier = .oxygenSaturation
            case .vo2Max: identifier = .vo2Max
            case .activeEnergy: identifier = .activeEnergyBurned
            case .steps: identifier = .stepCount
            case .respiratoryRate: identifier = .respiratoryRate
            case .bodyMass: identifier = .bodyMass
            case .bodyFatPercentage: identifier = .bodyFatPercentage
            case .leanBodyMass: identifier = .leanBodyMass
            case .sleep, .workout: throw HealthKitAdapterError.unsupportedMetric(metric)
            }
            guard let type = HKObjectType.quantityType(forIdentifier: identifier) else { throw HealthKitAdapterError.unsupportedMetric(metric) }
            return type
        }
    }

    private func requestStatusValue(for metrics: [HealthKitMetricID]) async throws -> HKAuthorizationRequestStatus {
        let types = try objectTypes(for: metrics)
        return try await withCheckedThrowingContinuation { continuation in
            store.getRequestStatusForAuthorization(toShare: [], read: types) { status, error in
                if let error { continuation.resume(throwing: Self.map(error)) }
                else { continuation.resume(returning: status) }
            }
        }
    }

    private func requestAuthorization(
        read types: Set<HKObjectType>,
        write typesToShare: Set<HKSampleType>
    ) async throws -> Bool {
        try await withCheckedThrowingContinuation { continuation in
            store.requestAuthorization(toShare: typesToShare, read: types) { success, error in
                if let error { continuation.resume(throwing: Self.map(error)) }
                else { continuation.resume(returning: success) }
            }
        }
    }

    private func healthKitQuantity(for request: HealthKitWriteRequest) throws -> HKQuantity {
        let unit: HKUnit
        let value: Double
        switch request.metric {
        case .water: unit = HKUnit(from: "mL"); value = request.value.value
        case .caffeine: unit = HKUnit(from: "mg"); value = request.value.value
        case .bodyMass, .leanBodyMass:
            unit = .gramUnit(with: .kilo)
            value = request.value.value
        case .bodyFatPercentage:
            unit = .percent()
            value = request.value.value / 100
        }
        guard value.isFinite, value >= 0 else {
            throw HealthKitAdapterError.invalidSample("Invalid HealthKit write quantity")
        }
        return HKQuantity(unit: unit, doubleValue: value)
    }

    private func save(_ sample: HKQuantitySample) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            store.save(sample) { success, error in
                if let error {
                    continuation.resume(throwing: Self.map(error))
                } else if success {
                    continuation.resume(returning: ())
                } else {
                    continuation.resume(throwing: HealthKitAdapterError.authorizationFailed("HealthKit write failed"))
                }
            }
        }
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

    private static func writeAuthorizationState(
        for error: HealthKitAdapterError
    ) -> HealthKitAuthorizationState {
        switch error {
        case .unavailable: .unavailable
        case .restricted: .restricted
        case .protectedDataUnavailable: .protectedDataUnavailable
        case .readAccessIndeterminate, .authorizationFailed: .writeDenied
        default: .error
        }
    }

    private static func writeFailure(
        for metric: HealthKitWriteMetric,
        error: Error
    ) -> HealthKitWriteReport {
        let mapped = map(error)
        switch mapped {
        case .unavailable:
            return .rejected(for: metric, state: .unavailable)
        case .restricted:
            return .rejected(for: metric, state: .restricted)
        case .protectedDataUnavailable:
            return .rejected(for: metric, state: .protectedDataUnavailable)
        case .readAccessIndeterminate:
            return .rejected(
                for: metric,
                state: .writeDenied,
                errorDescription: "HealthKit write access was denied"
            )
        default:
            return .rejected(
                for: metric,
                state: .writeAuthorized,
                errorDescription: "HealthKit write failed"
            )
        }
    }

    private func archive(_ anchor: HKQueryAnchor?) throws -> HealthKitOpaqueAnchor? {
        guard let anchor else { return nil }
        do {
            let data = try NSKeyedArchiver.archivedData(withRootObject: anchor, requiringSecureCoding: true)
            return try HealthKitOpaqueAnchor(archivedData: data)
        } catch {
            throw HealthKitAdapterError.invalidAnchor
        }
    }

    private func unarchive(_ anchor: HealthKitOpaqueAnchor?) throws -> HKQueryAnchor? {
        guard let anchor else { return nil }
        do {
            return try NSKeyedUnarchiver.unarchivedObject(ofClass: HKQueryAnchor.self, from: anchor.archivedData)
        } catch {
            throw HealthKitAdapterError.invalidAnchor
        }
    }

    private func observations(metric: HealthKitMetricID, samples: [HKSample], now: Date) -> ObservationConversion {
        var observations: [HealthKitObservation] = []
        observations.reserveCapacity(samples.count)
        var counts: [String: (reason: HealthKitQuarantineReason, provenance: HealthKitSourceMatch, count: Int)] = [:]

        func quarantine(_ sample: HKSample, error: Error) {
            let provenanceMatch = (try? self.provenance(for: sample).helioMatch) ?? .unattributed
            let reason = Self.quarantineReason(for: error)
            let key = "\(reason.rawValue)|\(provenanceMatch.rawValue)"
            if let current = counts[key] {
                counts[key] = (current.reason, current.provenance, current.count + 1)
            } else {
                counts[key] = (reason, provenanceMatch, 1)
            }
        }

        for sample in samples {
            do {
                let identity = try sampleIdentity(for: sample)
                let provenance = try provenance(for: sample)
                let value: HealthKitObservationValue
                switch metric {
                case .sleep:
                    guard let category = sample as? HKCategorySample else {
                        throw HealthKitAdapterError.invalidSample("Sleep sample is not a category sample")
                    }
                    let timeZone = sample.metadata?[HKMetadataKeyTimeZone] as? String
                    value = .sleep(try HealthKitSleepValue(stage: HealthKitSleepStage(rawValue: category.value), timeZoneIdentifier: timeZone))
                case .workout:
                    guard let workout = sample as? HKWorkout else {
                        throw HealthKitAdapterError.invalidSample("Workout sample is not a workout")
                    }
                    let energy: Double?
                    if let totalEnergyBurned = workout.totalEnergyBurned {
                        energy = totalEnergyBurned.doubleValue(for: .kilocalorie())
                    } else {
                        energy = nil
                    }
                    value = .workout(try HealthKitWorkoutValue(
                        activityTypeRawValue: Int(workout.workoutActivityType.rawValue),
                        durationSeconds: workout.duration,
                        activeEnergyKilocalories: energy
                    ))
                default:
                    guard let quantitySample = sample as? HKQuantitySample else {
                        throw HealthKitAdapterError.invalidSample("Quantity sample is not a quantity sample")
                    }
                    let quantity = try canonicalQuantity(metric: metric, sample: quantitySample)
                    value = .quantity(quantity)
                }
                do {
                    let observation = try HealthKitObservation(
                        metric: metric,
                        identity: identity,
                        value: value,
                        startDate: sample.startDate,
                        endDate: sample.endDate,
                        provenance: provenance,
                        now: now
                    )
                    observations.append(observation)
                } catch {
                    throw HealthKitAdapterError.invalidSample(String(describing: error))
                }
            } catch {
                // One malformed provider object is quarantined, not allowed to
                // discard valid siblings or strand the page anchor.
                quarantine(sample, error: error)
            }
        }

        let diagnostics = counts.values.compactMap { item in
            try? HealthKitQuarantineDiagnostic(
                metric: metric,
                reason: item.reason,
                provenance: item.provenance,
                count: item.count
            )
        }.sorted {
            if $0.reason.rawValue != $1.reason.rawValue { return $0.reason.rawValue < $1.reason.rawValue }
            return $0.provenance.rawValue < $1.provenance.rawValue
        }
        return ObservationConversion(observations: observations, quarantineDiagnostics: Array(diagnostics.prefix(HealthKitSafetyLimits.maxQuarantineDiagnostics)))
    }

    private static func quarantineReason(for error: Error) -> HealthKitQuarantineReason {
        if let adapterError = error as? HealthKitAdapterError {
            switch adapterError {
            case .unsupportedMetric: return .unsupportedSampleType
            case .invalidAnchor: return .conversionFailed
            case .invalidSample(let detail):
                let lower = detail.lowercased()
                if lower.contains("sample is not") || lower.contains("not a category sample") || lower.contains("not a quantity sample") {
                    return .unsupportedSampleType
                }
                if lower.contains("future") { return .futureObservation }
                if lower.contains("interval") || lower.contains("date") { return .invalidInterval }
                if lower.contains("identifier") || lower.contains("version") { return .invalidIdentity }
                if lower.contains("quantity") || lower.contains("workout") || lower.contains("stage") || lower.contains("value") {
                    return .invalidValue
                }
                if lower.contains("provenance") || lower.contains("source") { return .invalidProvenance }
                return .conversionFailed
            default:
                return .conversionFailed
            }
        }
        switch error as? HealthKitDomainError {
        case .futureDate: return .futureObservation
        case .invalidInterval: return .invalidInterval
        case .invalidQuantity, .invalidWorkout, .invalidSleepStage: return .invalidValue
        case .invalidRevision: return .invalidIdentity
        case .invalidSourceMetadata: return .invalidProvenance
        default: return .conversionFailed
        }
    }

    private func tombstones(metric: HealthKitMetricID, deleted: [HKDeletedObject], deletedAt: Date) throws -> [HealthKitDeletionTombstone] {
        try deleted.map { deletedObject in
            // HKDeletedObject metadata is optional and may be incomplete.
            // A deletion must never discard the whole page merely because a
            // provider omitted sync identifier/version metadata; UUID is the
            // documented stable tombstone identity available in that case.
            try HealthKitDeletionTombstone(
                metric: metric,
                identity: tombstoneIdentity(uuid: deletedObject.uuid, metadata: deletedObject.metadata),
                deletedAt: deletedAt
            )
        }
    }

    private func sampleIdentity(for sample: HKSample) throws -> HealthKitSampleIdentity {
        try sampleIdentity(uuid: sample.uuid, metadata: sample.metadata)
    }

    internal func sampleIdentity(uuid: UUID, metadata: [String: Any]?) throws -> HealthKitSampleIdentity {
        let syncIdentifier: String?
        if let raw = metadata?[HKMetadataKeySyncIdentifier] {
            guard let value = raw as? String else { throw HealthKitAdapterError.invalidSample("Sync identifier is not a string") }
            let clean = value.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !clean.isEmpty, clean.count <= 512 else { throw HealthKitAdapterError.invalidSample("Sync identifier is invalid") }
            syncIdentifier = clean
        } else {
            syncIdentifier = nil
        }

        let revision: HealthKitSampleRevision
        if let raw = metadata?[HKMetadataKeySyncVersion] {
            if let number = raw as? NSNumber {
                let value = number.doubleValue
                guard value.isFinite, value >= 0, value.rounded() == value, value <= Double(Int64.max) else {
                    throw HealthKitAdapterError.invalidSample("Sync version is not a non-negative integer")
                }
                revision = try HealthKitSampleRevision(syncVersion: number.int64Value)
            } else {
                throw HealthKitAdapterError.invalidSample("Sync version is not numeric")
            }
        } else {
            revision = .uuidFallback
        }
        guard syncIdentifier == nil || revision.numericValue != nil else {
            throw HealthKitAdapterError.invalidSample("Sync identifier requires a numeric sync version")
        }
        return HealthKitSampleIdentity(uuid: uuid, syncIdentifier: syncIdentifier, revision: revision)
    }

    internal func tombstoneIdentity(uuid: UUID, metadata: [String: Any]?) -> HealthKitSampleIdentity {
        (try? sampleIdentity(uuid: uuid, metadata: metadata)) ?? HealthKitSampleIdentity(uuid: uuid)
    }

    private func provenance(for sample: HKSample) throws -> HealthKitProvenance {
        let revision = sample.sourceRevision
        let source = try HealthKitSourceMetadata(
            bundleIdentifier: revision.source.bundleIdentifier,
            name: revision.source.name,
            version: revision.version,
            productType: revision.productType,
            operatingSystemVersion: Self.osString(revision.operatingSystemVersion)
        )
        let device: HealthKitDeviceMetadata?
        if let hkDevice = sample.device {
            device = try HealthKitDeviceMetadata(
                name: hkDevice.name,
                manufacturer: hkDevice.manufacturer,
                model: hkDevice.model,
                hardwareVersion: hkDevice.hardwareVersion,
                firmwareVersion: hkDevice.firmwareVersion,
                softwareVersion: hkDevice.softwareVersion,
                localIdentifier: hkDevice.localIdentifier
            )
        } else {
            device = nil
        }
        return try HealthKitProvenance.from(source: source, device: device, registry: evidenceRegistry)
    }

    private func canonicalQuantity(metric: HealthKitMetricID, sample: HKQuantitySample) throws -> HealthKitQuantityValue {
        let unit: HKUnit
        switch metric {
        case .water: unit = HKUnit(from: "mL")
        case .caffeine: unit = HKUnit(from: "mg")
        case .alcoholicBeverages: throw HealthKitAdapterError.unsupportedMetric(metric)
        case .heartRate, .restingHeartRate, .respiratoryRate: unit = HKUnit(from: "count/min")
        case .heartRateVariabilitySDNN: unit = HKUnit(from: "ms")
        case .oxygenSaturation, .bodyFatPercentage: unit = .percent()
        case .vo2Max: unit = HKUnit(from: "mL/kg/min")
        case .activeEnergy: unit = .kilocalorie()
        case .steps: unit = .count()
        case .bodyMass, .leanBodyMass: unit = .gramUnit(with: .kilo)
        case .sleep, .workout: throw HealthKitAdapterError.unsupportedMetric(metric)
        }
        var value = sample.quantity.doubleValue(for: unit)
        if metric == .oxygenSaturation || metric == .bodyFatPercentage { value *= 100 }
        guard let canonical = metric.canonicalUnit else { throw HealthKitAdapterError.unsupportedMetric(metric) }
        do { return try HealthKitQuantityValue(metric: metric, value: value, unit: canonical) }
        catch { throw HealthKitAdapterError.invalidSample(String(describing: error)) }
    }

    private static func osString(_ version: OperatingSystemVersion) -> String {
        "\(version.majorVersion).\(version.minorVersion).\(version.patchVersion)"
    }
}

private extension HealthKitBackgroundDeliveryCadence {
    var healthKitFrequency: HKUpdateFrequency {
        switch self {
        case .immediate: .immediate
        case .hourly: .hourly
        }
    }
}

#else

/// macOS and non-iOS builds deliberately expose an unavailable adapter rather
/// than importing HealthKit or presenting a fixture as a live source.
public final class LifeOSHealthKitAdapter: @unchecked Sendable, HealthKitReconciliationClient {
    public init(evidenceRegistry: HealthKitHelioEvidenceRegistry = .canonical) { _ = evidenceRegistry }

    public static func isSupportedMetric(_ metric: HealthKitMetricID) -> Bool {
        metric != .alcoholicBeverages
    }

    public static func backgroundDeliveryCadence(
        for metric: HealthKitMetricID
    ) -> HealthKitBackgroundDeliveryCadence? {
        metric == .alcoholicBeverages ? nil : .hourly
    }

    public var isHealthDataAvailable: Bool { false }
    public func availabilityState() -> HealthKitAuthorizationState { .unavailable }
    public func requestStatus(for metrics: [HealthKitMetricID]) async -> HealthKitAuthorizationReport { HealthKitAuthorizationReport(state: .unavailable) }
    public func requestReadAuthorization(for metrics: [HealthKitMetricID]) async -> HealthKitAuthorizationReport { HealthKitAuthorizationReport(state: .unavailable) }
    public func requestWriteAuthorization(for metrics: [HealthKitWriteMetric]) async -> HealthKitAuthorizationReport { HealthKitAuthorizationReport(state: .unavailable) }
    public func configureBackgroundDelivery(for metrics: [HealthKitMetricID]) async -> HealthKitBackgroundDeliveryReport { .failed(metrics) }
    public func writeAuthorizationStatus(for metric: HealthKitWriteMetric) -> HealthKitAuthorizationState { .unavailable }
    public func writeAuthorizationStatus(for metrics: [HealthKitWriteMetric]) -> HealthKitAuthorizationState { .unavailable }
    public func writeAuthorizationStatus(for metric: HealthKitMetricID) -> HealthKitAuthorizationState { .unavailable }
    public func write(_ request: HealthKitWriteRequest) async -> HealthKitWriteReport {
        .rejected(for: request.metric, state: .unavailable)
    }
    public func changes(for metric: HealthKitMetricID, from anchor: HealthKitOpaqueAnchor?) async throws -> HealthKitMetricSyncInput { throw HealthKitAdapterError.unavailable }

    public func stopAllObservers() {}
}

#endif
