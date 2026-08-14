import Foundation

public enum HealthKitReconciliationFailure: Error, Equatable, Sendable {
    case timedOut
    case client(String)
    case store(String)
    case validation(String)
}

public enum HealthKitObserverCompletion: Equatable, Sendable {
    case success
    case failure(String)
    case timedOut
}

public protocol HealthKitReconciliationClient: Sendable {
    func changes(for metric: HealthKitMetricID, from anchor: HealthKitOpaqueAnchor?) async throws -> HealthKitMetricSyncInput
}

public struct HealthKitMetricReconciliationResult: Equatable, Sendable {
    public let metric: HealthKitMetricID
    public let state: HealthKitSyncState
    public let insertedCount: Int
    public let deletedCount: Int
    public let duplicateCount: Int
    public let conflictCount: Int
    public let errorDescription: String?
    public let completion: HealthKitObserverCompletion

    public init(
        metric: HealthKitMetricID,
        state: HealthKitSyncState,
        insertedCount: Int = 0,
        deletedCount: Int = 0,
        duplicateCount: Int = 0,
        conflictCount: Int = 0,
        errorDescription: String? = nil,
        completion: HealthKitObserverCompletion = .success
    ) {
        self.metric = metric
        self.state = state
        self.insertedCount = insertedCount
        self.deletedCount = deletedCount
        self.duplicateCount = duplicateCount
        self.conflictCount = conflictCount
        self.errorDescription = errorDescription
        self.completion = completion
    }

    public var hasDurableCommit: Bool {
        completion == .success && state != .error
    }
}

public struct HealthKitReconciliationReport: Equatable, Sendable {
    public let results: [HealthKitMetricReconciliationResult]

    public init(results: [HealthKitMetricReconciliationResult]) {
        self.results = results
    }

    public var completion: HealthKitObserverCompletion {
        if results.contains(where: { $0.completion == .timedOut }) { return .timedOut }
        if let error = results.compactMap(\.errorDescription).first { return .failure(error) }
        return .success
    }
}

/// The only object allowed to move a HealthKit anchor forward. It first asks
/// the adapter for a bounded anchored batch, merges it idempotently, and then
/// asks the actor-isolated store to atomically persist projection, tombstones,
/// source index, and the new anchor together.
public actor HealthKitReconciliationCoordinator {
    /// Keep each reconciliation run finite even if a platform client keeps
    /// reporting partial pages without advancing its opaque anchor. The
    /// default iOS page is 500 objects, so this covers the durable 50,000-item
    /// projection limit while still failing closed for a non-progressing
    /// client.
    private static let maxPaginationPages = 128

    public let store: HealthKitAnchorStore
    private let client: HealthKitReconciliationClient
    private let timeout: TimeInterval
    private let staleAfter: TimeInterval
    private let now: @Sendable () -> Date

    public init(
        client: HealthKitReconciliationClient,
        store: HealthKitAnchorStore,
        timeout: TimeInterval = 30,
        staleAfter: TimeInterval = 15 * 60,
        now: @escaping @Sendable () -> Date = { .now }
    ) {
        self.client = client
        self.store = store
        self.timeout = Self.normalizedTimeout(timeout)
        self.staleAfter = max(1, staleAfter.isFinite ? staleAfter : 15 * 60)
        self.now = now
    }

    public static func normalizedTimeout(_ timeout: TimeInterval) -> TimeInterval {
        // Keep nanosecond conversion bounded even if configuration is read
        // from an untrusted/ corrupted preference value.
        min(5 * 60, max(0.1, timeout.isFinite ? timeout : 30))
    }

    public func reconcile(metrics: [HealthKitMetricID]) async -> HealthKitReconciliationReport {
        var results: [HealthKitMetricReconciliationResult] = []
        for metric in metrics {
            results.append(await reconcile(metric: metric))
        }
        return HealthKitReconciliationReport(results: results)
    }

    public func reconcile(metric: HealthKitMetricID) async -> HealthKitMetricReconciliationResult {
        var result = await reconcilePage(metric: metric)
        var pageCount = 1
        while result.state == .partial,
              pageCount < Self.maxPaginationPages,
              !Task.isCancelled {
            let before = await store.snapshot(for: metric)
            let next = await reconcilePage(metric: metric)
            let after = await store.snapshot(for: metric)
            pageCount += 1
            result = next
            // A partial page without a new durable anchor cannot make
            // progress. Keep its explicit partial truth and wait for a
            // later foreground retry rather than spinning forever.
            guard before.anchorArchive != after.anchorArchive else { break }
        }
        return result
    }

    // Keep the bounded anchored-page primitive available to the test target
    // so it can assert partial/readability semantics without bypassing the
    // production drain used by startup and observer callbacks.
    internal func reconcilePage(metric: HealthKitMetricID) async -> HealthKitMetricReconciliationResult {
        if await store.hasLoadFailure() {
            let message: String
            switch await store.loadFailureState() {
            case .protectedDataUnavailable:
                message = "HealthKit projection is temporarily unavailable while protected data is locked; retry later"
            case .malformedData, .unreadable, .none:
                message = "HealthKit projection load failed; explicit reset is required before reconciliation"
            }
            return HealthKitMetricReconciliationResult(metric: metric, state: .error, errorDescription: message, completion: .failure(message))
        }
        let current = await store.snapshot(for: metric)
        let queryAnchor = current.syncState == .fullResyncRequired ? nil : current.anchor

        let input: HealthKitMetricSyncInput
        do {
            input = try await withTimeout(seconds: timeout) {
                try await self.client.changes(for: metric, from: queryAnchor)
            }
        } catch let failure as HealthKitReconciliationFailure {
            switch failure {
            case .timedOut:
                return HealthKitMetricReconciliationResult(metric: metric, state: .error, errorDescription: "HealthKit reconciliation timed out", completion: .timedOut)
            case .client(let message), .store(let message), .validation(let message):
                return HealthKitMetricReconciliationResult(metric: metric, state: .error, errorDescription: message, completion: .failure(message))
            }
        } catch let adapterError as HealthKitAdapterError {
            if case .invalidAnchor = adapterError {
                do {
                    _ = try await store.markFullResyncRequired(for: metric, committedAt: now())
                } catch {
                    let message = "HealthKit anchor was invalid and full-resync state could not be persisted"
                    return HealthKitMetricReconciliationResult(metric: metric, state: .error, errorDescription: message, completion: .failure(message))
                }
                let message = "HealthKit anchor could not be decoded; a durable full resync is required"
                return HealthKitMetricReconciliationResult(metric: metric, state: .fullResyncRequired, errorDescription: message, completion: .failure(message))
            }
            let message: String
            switch adapterError {
            case .unavailable: message = "HealthKit data is unavailable on this device"
            case .restricted: message = "HealthKit data is restricted on this device"
            case .protectedDataUnavailable: message = "HealthKit data is temporarily unavailable while protected data is locked; retry later"
            case .readAccessIndeterminate: message = "HealthKit read access is indeterminate; an empty read cannot distinguish denial from no data"
            case .unsupportedMetric(let unsupported): message = "HealthKit metric is unsupported: \(unsupported.rawValue)"
            case .invalidSample(let detail), .queryFailed(let detail), .authorizationFailed(let detail): message = detail
            case .invalidAnchor: message = "HealthKit anchor is invalid"
            }
            return HealthKitMetricReconciliationResult(metric: metric, state: .error, errorDescription: message, completion: .failure(message))
        } catch {
            let message = error.localizedDescription
            return HealthKitMetricReconciliationResult(metric: metric, state: .error, errorDescription: message, completion: .failure(message))
        }

        guard input.metric == metric else {
            return HealthKitMetricReconciliationResult(metric: metric, state: .error, errorDescription: "Client returned a different metric", completion: .failure("Client returned a different metric"))
        }

        if Task.isCancelled {
            return HealthKitMetricReconciliationResult(metric: metric, state: .error, errorDescription: "HealthKit reconciliation cancelled", completion: .timedOut)
        }

        let reconciliationNow = now()
        let age = reconciliationNow.timeIntervalSince(input.observedAt)
        guard reconciliationNow.timeIntervalSinceReferenceDate.isFinite,
              age.isFinite,
              age >= 0 else {
            return HealthKitMetricReconciliationResult(metric: metric, state: .error, errorDescription: "HealthKit batch has a future observedAt", completion: .failure("HealthKit batch has a future observedAt"))
        }
        guard input.additions.allSatisfy({ Self.isValidObservation($0, metric: metric, now: reconciliationNow) }),
              input.deletions.allSatisfy({ Self.isValidDeletion($0, metric: metric, now: reconciliationNow) }) else {
            let message = "HealthKit batch contains a future, non-finite, or non-canonical fact"
            return HealthKitMetricReconciliationResult(metric: metric, state: .error, errorDescription: message, completion: .failure(message))
        }

        let isAmbiguousEmptyRead = input.readability == .emptyIndeterminate &&
            input.additions.isEmpty && input.deletions.isEmpty
        if isAmbiguousEmptyRead {
            // HealthKit deliberately does not reveal per-type read denial. An
            // empty first read is therefore not evidence of “no data” and
            // must not advance an anchor or claim synced. Persist the
            // explicit indeterminate state while retaining the old anchor
            // (the store's nil-next-anchor semantics do that atomically).
            do {
                _ = try await store.commit(
                    metric: metric,
                    observations: current.observations,
                    tombstones: current.tombstones,
                    sourceIndex: current.sourceIndex,
                    conflicts: current.conflicts,
                    nextAnchor: nil,
                    syncState: .readIndeterminate,
                    committedAt: reconciliationNow,
                    expectedAnchorArchive: current.anchorArchive,
                    expectedAnchorChecked: true,
                    expectedState: current
                )
                return HealthKitMetricReconciliationResult(
                    metric: metric,
                    state: .readIndeterminate,
                    completion: .success
                )
            } catch {
                let message = "HealthKit indeterminate read state could not be persisted: \(error.localizedDescription)"
                return HealthKitMetricReconciliationResult(metric: metric, state: .error, errorDescription: message, completion: .failure(message))
            }
        }

        var observations = current.observations
        var tombstones = current.tombstones
        var conflicts = current.conflicts
        var inserted = 0
        var duplicates = 0
        var conflictCount = 0

        for incoming in input.additions {
            guard incoming.metric == metric else {
                return HealthKitMetricReconciliationResult(metric: metric, state: .error, errorDescription: "Addition metric mismatch", completion: .failure("Addition metric mismatch"))
            }
            if tombstones.contains(where: {
                !$0.identity.aliasUUIDs.isDisjoint(with: incoming.identity.aliasUUIDs) ||
                $0.identity.matchesStableIdentity(incoming.identity)
            }) {
                // A deleted stable identity remains tombstoned even if an
                // anchored replay delivers its old sample again.
                duplicates += 1
                continue
            }
            if let index = observations.firstIndex(where: { $0.identity.matchesStableIdentity(incoming.identity) }) {
                let existing = observations[index]
                let sharesUUID = !existing.identity.aliasUUIDs.isDisjoint(with: incoming.identity.aliasUUIDs)
                let hasDifferentSyncIdentifiers = existing.identity.syncIdentifier != nil &&
                    incoming.identity.syncIdentifier != nil &&
                    existing.identity.syncIdentifier != incoming.identity.syncIdentifier
                if sharesUUID && hasDifferentSyncIdentifiers {
                    let conflict = HealthKitObservationConflict(metric: metric, identity: incoming.identity, existing: existing, incoming: incoming)
                    if !conflicts.contains(conflict) { conflicts.append(conflict) }
                    conflictCount += 1
                    continue
                }
                if existing.identity.revision == incoming.identity.revision {
                    let mergedIdentity = existing.identity.withMergedAliases(from: incoming.identity)
                    if existing == incoming {
                        if mergedIdentity.syncIdentifier != existing.identity.syncIdentifier ||
                            mergedIdentity.aliases != existing.identity.aliases {
                            do {
                                observations[index] = try HealthKitObservation(
                                    metric: existing.metric,
                                    identity: mergedIdentity,
                                    value: existing.value,
                                    startDate: existing.startDate,
                                    endDate: existing.endDate,
                                    provenance: existing.provenance,
                                    now: reconciliationNow
                                )
                            } catch {
                                let message = "HealthKit observation alias merge failed validation"
                                return HealthKitMetricReconciliationResult(metric: metric, state: .error, errorDescription: message, completion: .failure(message))
                            }
                        }
                        duplicates += 1
                    } else {
                        let conflict = HealthKitObservationConflict(metric: metric, identity: incoming.identity, existing: existing, incoming: incoming)
                        if !conflicts.contains(conflict) { conflicts.append(conflict) }
                        conflictCount += 1
                    }
                } else if incoming.identity.revision.isNewer(than: existing.identity.revision) {
                    let mergedIdentity = incoming.identity.withMergedAliases(from: existing.identity)
                    do {
                        observations[index] = try HealthKitObservation(
                            metric: incoming.metric,
                            identity: mergedIdentity,
                            value: incoming.value,
                            startDate: incoming.startDate,
                            endDate: incoming.endDate,
                            provenance: incoming.provenance,
                            now: reconciliationNow
                        )
                    } catch {
                        let message = "HealthKit observation revision replacement failed validation"
                        return HealthKitMetricReconciliationResult(metric: metric, state: .error, errorDescription: message, completion: .failure(message))
                    }
                    inserted += 1
                } else {
                    // Anchored queries may replay an older revision.  It is
                    // already superseded and must never be double-counted.
                    duplicates += 1
                }
                continue
            }
            observations.append(incoming)
            inserted += 1
        }

        for deletion in input.deletions {
            guard deletion.metric == metric else {
                return HealthKitMetricReconciliationResult(metric: metric, state: .error, errorDescription: "Deletion metric mismatch", completion: .failure("Deletion metric mismatch"))
            }
            let matching = observations.filter { $0.identity.aliasUUIDs.intersection(deletion.identity.aliasUUIDs).isEmpty == false || $0.identity.matchesStableIdentity(deletion.identity) }
            var normalizedIdentity = matching.reduce(deletion.identity) { result, observation in
                result.withMergedAliases(from: observation.identity)
            }
            // A HealthKit deletion normally contains only a UUID. When the
            // UUID belongs to an observation carrying a stable sync
            // identifier, alias normalization can enrich the tombstone with
            // that identifier. Keep the identity valid for persistence by
            // carrying a numeric revision from the matching observation; if
            // no such revision is available, retain the UUID aliases but do
            // not persist an invalid sync-id/uuid-fallback pair.
            if normalizedIdentity.syncIdentifier != nil,
               normalizedIdentity.revision.numericValue == nil {
                let revisionValue = matching
                    .filter { $0.identity.syncIdentifier == normalizedIdentity.syncIdentifier }
                    .compactMap { $0.identity.revision.numericValue }
                    .max()
                if let revisionValue,
                   let revision = try? HealthKitSampleRevision(syncVersion: revisionValue) {
                    normalizedIdentity = HealthKitSampleIdentity(
                        uuid: normalizedIdentity.uuid,
                        syncIdentifier: normalizedIdentity.syncIdentifier,
                        aliases: Array(normalizedIdentity.aliasUUIDs.subtracting([normalizedIdentity.uuid])),
                        revision: revision
                    )
                } else {
                    normalizedIdentity = HealthKitSampleIdentity(
                        uuid: normalizedIdentity.uuid,
                        aliases: Array(normalizedIdentity.aliasUUIDs.subtracting([normalizedIdentity.uuid]))
                    )
                }
            }
            let normalizedDeletion: HealthKitDeletionTombstone
            do {
                normalizedDeletion = try HealthKitDeletionTombstone(metric: metric, identity: normalizedIdentity, deletedAt: deletion.deletedAt)
            } catch {
                let message = "Deletion tombstone validation failed"
                return HealthKitMetricReconciliationResult(metric: metric, state: .error, errorDescription: message, completion: .failure(message))
            }
            if !tombstones.contains(where: { $0.identity.matchesStableIdentity(normalizedDeletion.identity) }) {
                tombstones.append(normalizedDeletion)
            }
            let before = observations.count
            observations.removeAll { observation in
                !observation.identity.aliasUUIDs.intersection(normalizedIdentity.aliasUUIDs).isEmpty || observation.identity.matchesStableIdentity(normalizedIdentity)
            }
            inserted = max(0, inserted - (before - observations.count))
        }

        if Task.isCancelled {
            return HealthKitMetricReconciliationResult(metric: metric, state: .error, errorDescription: "HealthKit reconciliation cancelled", completion: .timedOut)
        }
        let hasSourceConflict = (try? rebuiltSourceIndex(for: observations).values.contains(.conflict)) ?? false
        let hasConflict = conflictCount > 0 || !conflicts.isEmpty || hasSourceConflict
        let syncState: HealthKitSyncState
        if hasConflict {
            syncState = .conflict
        } else if input.partial {
            syncState = .partial
        } else if age > staleAfter {
            syncState = .stale
        } else {
            syncState = .synced
        }

        let sourceIndex: [String: HealthKitSourceMatch]
        do {
            sourceIndex = try rebuiltSourceIndex(for: observations)
        } catch {
            let message = "HealthKit source index validation failed: \(error.localizedDescription)"
            return HealthKitMetricReconciliationResult(metric: metric, state: .error, errorDescription: message, completion: .failure(message))
        }

        do {
            _ = try await store.commit(
                metric: metric,
                observations: observations,
                tombstones: tombstones,
                sourceIndex: sourceIndex,
                conflicts: conflicts,
                nextAnchor: hasConflict ? nil : input.nextAnchor,
                syncState: syncState,
                committedAt: reconciliationNow,
                expectedAnchorArchive: current.anchorArchive,
                expectedAnchorChecked: true,
                expectedState: current
            )
            return HealthKitMetricReconciliationResult(
                metric: metric,
                state: syncState,
                insertedCount: inserted,
                deletedCount: input.deletions.count,
                duplicateCount: duplicates,
                conflictCount: conflictCount,
                completion: .success
            )
        } catch {
            let message = "HealthKit projection commit failed: \(error.localizedDescription)"
            return HealthKitMetricReconciliationResult(metric: metric, state: .error, errorDescription: message, completion: .failure(message))
        }
    }

    private static func isValidObservation(_ observation: HealthKitObservation, metric: HealthKitMetricID, now: Date) -> Bool {
        observation.metric == metric &&
        observation.startDate.timeIntervalSinceReferenceDate.isFinite &&
        observation.endDate.timeIntervalSinceReferenceDate.isFinite &&
        observation.startDate <= observation.endDate &&
        observation.endDate.timeIntervalSince(now) <= HealthKitObservation.defaultFutureTolerance &&
        observation.provenance.matchesCanonicalRegistry &&
        observation.identity.isWithinSafetyBounds &&
        (observation.identity.syncIdentifier == nil || observation.identity.revision.numericValue != nil)
    }

    private static func isValidDeletion(_ deletion: HealthKitDeletionTombstone, metric: HealthKitMetricID, now: Date) -> Bool {
        deletion.metric == metric &&
        deletion.deletedAt.timeIntervalSinceReferenceDate.isFinite &&
        deletion.deletedAt.timeIntervalSince(now) <= HealthKitObservation.defaultFutureTolerance &&
        deletion.identity.isWithinSafetyBounds &&
        (deletion.identity.syncIdentifier == nil || deletion.identity.revision.numericValue != nil)
    }

    private func rebuiltSourceIndex(for observations: [HealthKitObservation]) throws -> [String: HealthKitSourceMatch] {
        try HealthKitSourceIndex.build(observations: observations)
    }

    private func withTimeout<T: Sendable>(seconds: TimeInterval, operation: @escaping @Sendable () async throws -> T) async throws -> T {
        try await HealthKitBoundedOperation.run(seconds: seconds, operation: operation)
    }
}

/// Unlike a structured task group, this small unstructured race can return
/// at the deadline even if a platform callback never resumes its continuation.
/// The late HealthKit callback is ignored after the first result and therefore
/// cannot double-resume the caller.
private final class HealthKitBoundedOperation<Value: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var finished = false
    private var continuation: CheckedContinuation<Value, Error>?
    private var operationTask: Task<Void, Never>?
    private var timeoutTask: Task<Void, Never>?

    static func run(
        seconds: TimeInterval,
        operation: @escaping @Sendable () async throws -> Value
    ) async throws -> Value {
        let box = HealthKitBoundedOperation<Value>()
        return try await withTaskCancellationHandler(operation: {
            try await withCheckedThrowingContinuation { continuation in
                box.setContinuation(continuation)
                box.start(seconds: seconds, operation: operation)
            }
        }, onCancel: {
            box.cancel()
        })
    }

    private func setContinuation(_ continuation: CheckedContinuation<Value, Error>) {
        lock.lock()
        if finished {
            lock.unlock()
            continuation.resume(throwing: CancellationError())
        } else {
            self.continuation = continuation
            lock.unlock()
        }
    }

    private func start(seconds: TimeInterval, operation: @escaping @Sendable () async throws -> Value) {
        lock.lock()
        guard !finished else {
            lock.unlock()
            return
        }
        lock.unlock()

        let operationTask = Task {
            do { self.resolve(.success(try await operation())) }
            catch { self.resolve(.failure(error)) }
        }
        setOperationTask(operationTask)

        let safeSeconds = HealthKitReconciliationCoordinator.normalizedTimeout(seconds)
        let timeoutTask = Task {
            try? await Task.sleep(nanoseconds: UInt64(safeSeconds * 1_000_000_000))
            self.resolve(.failure(HealthKitReconciliationFailure.timedOut))
        }
        setTimeoutTask(timeoutTask)
    }

    private func resolve(_ result: Result<Value, Error>) {
        lock.lock()
        guard !finished else {
            lock.unlock()
            return
        }
        finished = true
        let continuation = self.continuation
        self.continuation = nil
        let operationTask = self.operationTask
        let timeoutTask = self.timeoutTask
        lock.unlock()

        operationTask?.cancel()
        timeoutTask?.cancel()
        continuation?.resume(with: result)
    }

    private func cancel() {
        resolve(.failure(CancellationError()))
    }

    private func setOperationTask(_ task: Task<Void, Never>) {
        lock.lock()
        if finished {
            lock.unlock()
            task.cancel()
        } else {
            operationTask = task
            lock.unlock()
        }
    }

    private func setTimeoutTask(_ task: Task<Void, Never>) {
        lock.lock()
        if finished {
            lock.unlock()
            task.cancel()
        } else {
            timeoutTask = task
            lock.unlock()
        }
    }
}

/// HealthKit requires the observer completion closure to be called after
/// processing. This lock-backed gate makes the once-only guarantee explicit
/// and lets a timeout/error race with the normal reconciliation safely.
public final class HealthKitObserverCompletionGate: @unchecked Sendable {
    private let lock = NSLock()
    private var finished = false

    public init(timeout: TimeInterval = 30) {
        _ = timeout
    }

    @discardableResult
    public func finish(
        _ result: HealthKitObserverCompletion,
        completion: @escaping () -> Void,
        report: @escaping (HealthKitObserverCompletion) -> Void,
        onFirst: @escaping () -> Void = {}
    ) -> Bool {
        lock.lock()
        guard !finished else {
            lock.unlock()
            return false
        }
        finished = true
        lock.unlock()
        onFirst()
        report(result)
        completion()
        return true
    }
}
