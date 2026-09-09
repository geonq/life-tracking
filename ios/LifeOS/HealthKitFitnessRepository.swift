#if os(iOS)
import Combine
import Foundation

/// Publishes a bounded projection of the retained HealthKit truth for the
/// iPhone Fitness surface.
///
/// The production initializer accepts the already-owned concrete bridge. It
/// never creates a client or store of its own, so the integration controller
/// and this repository read the same durable `HealthKitAnchorStore` through
/// the same `HealthKitProductionClient` instance.
@MainActor
public final class HealthKitFitnessRepository: ObservableObject {
    public typealias StateReader = ([HealthKitMetricID]) async -> [HealthKitStoredMetricState]

    public let client: HealthKitProductionClient?
    public let usesVisualFixtures: Bool
    @Published public private(set) var projection: HealthKitFitnessProjection?

    private let calendar: Calendar
    private let now: () -> Date
    private let testStateReader: StateReader?
    private var generation: UInt64 = 0
    private var refreshOperationID: UInt64 = 0
    private var activeRefreshOperationID: UInt64?
    private var refreshTask: Task<HealthKitFitnessProjection?, Never>?
    private struct RefreshWaiter {
        let operationID: UInt64
        let continuation: CheckedContinuation<HealthKitFitnessProjection?, Never>
    }
    private var refreshWaiters: [UUID: RefreshWaiter] = [:]

    /// Production wiring. A missing client, including fixture mode, remains
    /// unavailable and never attempts a retained-store read.
    public init(
        client: HealthKitProductionClient?,
        usesVisualFixtures: Bool = false,
        calendar: Calendar = Calendar.current
    ) {
        self.client = client
        self.usesVisualFixtures = usesVisualFixtures
        self.calendar = Self.explicitCalendar(calendar)
        self.now = Date.init
        self.testStateReader = nil
        self.projection = nil
    }

    /// Test-only reader seam. Production cannot use this initializer, and the
    /// production path above remains coupled to the concrete bridge/store
    /// boundary. This keeps projection/window/generation behavior testable
    /// without weakening HealthKit store or security invariants.
    internal init(
        testStateReader: @escaping StateReader,
        usesVisualFixtures: Bool = false,
        calendar: Calendar = Calendar.current,
        now: @escaping () -> Date = Date.init
    ) {
        self.client = nil
        self.usesVisualFixtures = usesVisualFixtures
        self.calendar = Self.explicitCalendar(calendar)
        self.now = now
        self.testStateReader = testStateReader
        self.projection = nil
    }

    /// Reads retained states once and publishes a rolling, bounded projection.
    /// Overlapping callers join the same operation instead of cancelling and
    /// replacing one another. Each caller still has independent cancellation:
    /// a cancelled waiter returns without cancelling work another caller is
    /// using, while the last waiter cancels the shared operation.
    @discardableResult
    public func refresh() async -> HealthKitFitnessProjection? {
        guard !Task.isCancelled else { return nil }

        let operationID: UInt64
        if refreshTask != nil, let activeRefreshOperationID {
            operationID = activeRefreshOperationID
        } else {
            refreshOperationID &+= 1
            operationID = refreshOperationID
            activeRefreshOperationID = operationID
            generation &+= 1
            let refreshGeneration = generation
            let newTask: Task<HealthKitFitnessProjection?, Never> = Task { @MainActor [weak self] in
                guard let self else { return nil }
                return await self.performRefresh(generation: refreshGeneration)
            }
            refreshTask = newTask
            Task { @MainActor [weak self] in
                let result = await newTask.value
                self?.finishRefresh(operationID: operationID, result: result)
            }
        }

        let waiterID = UUID()
        return await withTaskCancellationHandler(operation: {
            await withCheckedContinuation { continuation in
                guard !Task.isCancelled else {
                    continuation.resume(returning: nil)
                    cancelRefreshIfUnobserved(operationID: operationID)
                    return
                }
                refreshWaiters[waiterID] = RefreshWaiter(
                    operationID: operationID,
                    continuation: continuation
                )
            }
        }, onCancel: {
            Task { @MainActor [weak self] in
                self?.cancelRefreshWaiter(waiterID, operationID: operationID)
            }
        })
    }

    private func performRefresh(generation refreshGeneration: UInt64) async -> HealthKitFitnessProjection? {
        guard !Task.isCancelled else { return nil }
        guard !usesVisualFixtures else {
            projection = nil
            return nil
        }

        let states: [HealthKitStoredMetricState]
        if let client {
            states = await client.storedStates(for: HealthKitIntegrationController.supportedMetrics)
        } else if let testStateReader {
            states = await testStateReader(HealthKitIntegrationController.supportedMetrics)
        } else {
            projection = nil
            return nil
        }

        guard !Task.isCancelled, refreshGeneration == generation else { return nil }
        guard let window = Self.boundedWindow(now: now(), calendar: calendar) else {
            projection = nil
            return nil
        }

        // Projection is pure but can scan tens of thousands of retained
        // observations. Keep that work off the MainActor so opening the app
        // cannot turn durable HealthKit composition into a watchdog path.
        let projectionCalendar = calendar
        let worker = Task.detached(priority: .utility) { [states, window, projectionCalendar] in
            HealthKitFitnessProjection.makeCancellable(
                states: states,
                window: window,
                calendar: projectionCalendar,
                isCancelled: { Task.isCancelled }
            )
        }
        let nextProjection = await withTaskCancellationHandler(
            operation: { await worker.value },
            onCancel: { worker.cancel() }
        )

        guard !Task.isCancelled,
              refreshGeneration == generation,
              let nextProjection else { return nil }
        projection = nextProjection
        return nextProjection
    }

    private func cancelRefreshWaiter(_ waiterID: UUID, operationID: UInt64) {
        guard let waiter = refreshWaiters.removeValue(forKey: waiterID),
              waiter.operationID == operationID else { return }
        waiter.continuation.resume(returning: nil)
        cancelRefreshIfUnobserved(operationID: operationID)
    }

    private func cancelRefreshIfUnobserved(operationID: UInt64) {
        guard activeRefreshOperationID == operationID,
              !refreshWaiters.values.contains(where: { $0.operationID == operationID }) else { return }
        // Retire the cancelled operation immediately. A new caller arriving
        // before an uncooperative reader returns must start a fresh operation,
        // and the generation change prevents the old operation from
        // publishing when it eventually unwinds.
        generation &+= 1
        refreshTask?.cancel()
        activeRefreshOperationID = nil
        refreshTask = nil
    }

    private func finishRefresh(operationID: UInt64, result: HealthKitFitnessProjection?) {
        guard activeRefreshOperationID == operationID else { return }
        activeRefreshOperationID = nil
        refreshTask = nil
        let waiters = refreshWaiters.filter { $0.value.operationID == operationID }
        for (waiterID, waiter) in waiters {
            refreshWaiters.removeValue(forKey: waiterID)
            waiter.continuation.resume(returning: result)
        }
    }

    private static func explicitCalendar(_ calendar: Calendar) -> Calendar {
        var copy = calendar
        // Calendar carries its time zone by value. Assigning it explicitly
        // keeps the bucket contract visible at this boundary and stable in
        // tests instead of relying on a later implicit default.
        copy.timeZone = calendar.timeZone
        return copy
    }

    private static func boundedWindow(now: Date, calendar: Calendar) -> DateInterval? {
        guard now.timeIntervalSinceReferenceDate.isFinite,
              let start = calendar.date(byAdding: .day, value: -365, to: now),
              start.timeIntervalSinceReferenceDate.isFinite,
              now > start else {
            return nil
        }

        let end = now.addingTimeInterval(1)
        guard end.timeIntervalSinceReferenceDate.isFinite else {
            return nil
        }

        let window = DateInterval(start: start, end: end)
        guard window.duration <= HealthKitFitnessProjection.maximumWindow else {
            return nil
        }
        return window
    }
}
#endif
