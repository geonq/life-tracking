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
    private var projectionTask: Task<HealthKitFitnessProjection?, Never>?

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
        self.projectionTask = nil
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
        self.projectionTask = nil
    }

    /// Reads retained states once and publishes a rolling, bounded projection.
    /// The actor-isolated bridge call may suspend; the generation token keeps
    /// an older overlapping response from replacing a newer projection.
    public func refresh() async {
        projectionTask?.cancel()
        generation &+= 1
        let refreshGeneration = generation

        guard !usesVisualFixtures else {
            projection = nil
            return
        }

        let states: [HealthKitStoredMetricState]
        if let client {
            states = await client.storedStates(for: HealthKitIntegrationController.supportedMetrics)
        } else if let testStateReader {
            states = await testStateReader(HealthKitIntegrationController.supportedMetrics)
        } else {
            projection = nil
            return
        }

        guard refreshGeneration == generation else { return }
        guard let window = Self.boundedWindow(now: now(), calendar: calendar) else {
            projection = nil
            return
        }
        guard !Task.isCancelled else { return }

        // Projection is pure but can scan tens of thousands of retained
        // observations. Keep that work off the MainActor so opening the app
        // cannot turn durable HealthKit composition into a watchdog path.
        let projectionCalendar = calendar
        let task = Task.detached(priority: .utility) { [states, window, projectionCalendar] in
            HealthKitFitnessProjection.makeCancellable(
                states: states,
                window: window,
                calendar: projectionCalendar,
                isCancelled: { Task.isCancelled }
            )
        }
        projectionTask = task
        let nextProjection = await withTaskCancellationHandler(
            operation: { await task.value },
            onCancel: { task.cancel() }
        )

        guard refreshGeneration == generation else { return }
        projectionTask = nil
        guard !Task.isCancelled, let nextProjection else { return }
        projection = nextProjection
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
