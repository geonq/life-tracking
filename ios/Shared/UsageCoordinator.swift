import Foundation
import Combine
#if canImport(WidgetKit)
import WidgetKit
#endif

/// Tells the Usage widgets that their shared App Group snapshot changed.
/// Usage is the only widget family whose provider reads `SharedSnapshotStore`
/// directly rather than `FutureWidgetSnapshotStore`, so its writer owns this
/// explicit reload contract.
public enum UsageWidgetTimelineReloader {
    public static let widgetKinds: [String] = [
        "LifeOSWidget",
        "LifeOSUsageSmallWidget",
        "LifeOSUsageLockScreenWidget"
    ]

    public static func reload() {
#if canImport(WidgetKit)
        for kind in widgetKinds {
            WidgetCenter.shared.reloadTimelines(ofKind: kind)
        }
#endif
    }
}

public enum UsageLoadState: Equatable, Sendable {
    case demo
    case loading
    case observed
    case stale
    case unavailable
}

/// A typed failure channel kept separate from `UsageLoadState` for source
/// compatibility with existing Settings switches. UI surfaces can therefore
/// distinguish a bad payload, transport failure, and history-storage failure
/// without turning an error into a fabricated numeric state.
public enum UsageRefreshFailure: String, Codable, Equatable, Sendable {
    case none
    case transport
    case invalidPayload
    case historyStorage
}

public enum UsagePresentationUpdateKind: Equatable, Sendable {
    case initial
    case loading
    case resolved
    case failed
    case cancelled
    /// A valid source result contains no observed usage, so empty/unavailable
    /// data must not be mistaken for a failed request or synthetic zeros.
    case authoritativeEmpty
}

/// The one coherent handoff for Usage presentation. `generation` is sourced
/// from `UsageCoordinator.refreshGeneration`, so consumers can ignore stale
/// packets without keeping a second history of provider or analytics values.
public struct UsagePresentationPacket: Equatable, Sendable {
    public let generation: Int
    public let providers: [ProviderSnapshot]
    public let analytics: [UsageAnalyticsSnapshot]
    public let loadState: UsageLoadState
    public let failure: UsageRefreshFailure
    public let lastUpdated: Date?
    public let updateKind: UsagePresentationUpdateKind

    public init(generation: Int,
                providers: [ProviderSnapshot],
                analytics: [UsageAnalyticsSnapshot],
                loadState: UsageLoadState,
                failure: UsageRefreshFailure,
                lastUpdated: Date?,
                updateKind: UsagePresentationUpdateKind) {
        self.generation = generation
        self.providers = providers
        self.analytics = analytics
        self.loadState = loadState
        self.failure = failure
        self.lastUpdated = lastUpdated
        self.updateKind = updateKind
    }
}

public protocol UsagePayloadFetching: Sendable {
    func fetchUsage() async throws -> Data
}

extension TailscaleSyncClient: UsagePayloadFetching {}

/// The Usage coordinator owns the legacy Usage widget snapshot path. Keep the
/// store behind a small instance seam so visual-fixture hosts can use a
/// no-op sink without ever resolving the personal App Group container.
protocol UsageWidgetSnapshotPersistence {
    func readLive() -> WidgetSnapshot?
    func write(_ snapshot: WidgetSnapshot) throws
}

struct SharedUsageWidgetSnapshotPersistence: UsageWidgetSnapshotPersistence {
    func readLive() -> WidgetSnapshot? { SharedSnapshotStore.readLive() }

    func write(_ snapshot: WidgetSnapshot) throws {
        try SharedSnapshotStore.write(snapshot)
    }
}

struct NoopUsageWidgetSnapshotPersistence: UsageWidgetSnapshotPersistence {
    func readLive() -> WidgetSnapshot? { nil }
    func write(_ snapshot: WidgetSnapshot) throws {}
}

/// File-backed only for visual-fixture runs. The caller supplies a unique
/// temporary URL; the file is never the production UserDefaults key or App
/// Group snapshot. It keeps fixture reloads deterministic while exercising
/// the same bounded archive validation as the live store.
final class TemporaryUsageHistoryPersistence: UsageHistoryPersistence {
    let fileURL: URL
    private let fileManager: FileManager

    init(fileURL: URL, fileManager: FileManager = .default) {
        self.fileURL = fileURL
        self.fileManager = fileManager
    }

    func load() throws -> Data? {
        guard fileManager.fileExists(atPath: fileURL.path) else { return nil }
        return try Data(contentsOf: fileURL)
    }

    func save(_ data: Data) throws {
        guard data.count <= UsageHistoryLedger.maximumArchiveBytes else {
            throw UsageHistoryError.archiveTooLarge
        }
        try fileManager.createDirectory(
            at: fileURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try data.write(to: fileURL, options: .atomic)
    }
}

@available(iOS 17.0, macOS 14.0, *)
@MainActor
public final class UsageCoordinator: ObservableObject {
    @Published public private(set) var state: UsageLoadState = .unavailable
    @Published public private(set) var providers: [ProviderSnapshot] = []
    @Published public private(set) var analytics: [UsageAnalyticsSnapshot] = []
    @Published public private(set) var presentationPacket: UsagePresentationPacket
    @Published public private(set) var connectorStates: [Provider: ConnectorState] = [:]
    @Published public private(set) var errorMessage: String?
    @Published public private(set) var lastUpdated: Date?
    @Published public private(set) var failure: UsageRefreshFailure = .none
    @Published public private(set) var historyStatus: UsageHistoryStatus = .empty
    @Published public private(set) var historyErrorMessage: String?

    private let fetchPayload: @Sendable () async throws -> APIUsagePayload
    private var refreshTask: Task<Void, Never>?
    private var refreshGeneration = 0
    private let staleAfter: TimeInterval
    private let historyPersistence: UsageHistoryPersistence
    private let snapshotPersistence: UsageWidgetSnapshotPersistence
    private let reloadWidgets: () -> Void
    private let allowsRefresh: Bool
    private var historyLedger: UsageHistoryLedger

    public init(client: UsagePayloadFetching = TailscaleSyncClient(),
                staleAfter: TimeInterval = 15 * 60,
                initialProviders: [ProviderSnapshot] = [],
                initialUpdatedAt: Date? = nil,
                historyPersistence: UsageHistoryPersistence = UserDefaultsUsageHistoryPersistence()) {
        self.fetchPayload = {
            let data = try await client.fetchUsage()
            return try JSONDecoder.lifeOS.decode(APIUsagePayload.self, from: data)
        }
        self.staleAfter = staleAfter
        self.historyPersistence = historyPersistence
        self.snapshotPersistence = SharedUsageWidgetSnapshotPersistence()
        self.reloadWidgets = UsageWidgetTimelineReloader.reload
        self.allowsRefresh = true
        let loadedHistory = Self.loadHistory(from: historyPersistence)
        self.historyLedger = loadedHistory.ledger
        self.historyStatus = loadedHistory.ledger.isEmpty ? .empty : .available
        self.historyErrorMessage = loadedHistory.errorMessage
        let initialFailure: UsageRefreshFailure = loadedHistory.errorMessage == nil ? .none : .historyStorage
        self.failure = initialFailure
        self.providers = initialProviders
        let initialAnalytics = UsageAnalyticsHistoryBuilder.snapshots(
            from: loadedHistory.ledger, providers: initialProviders
        )
        self.analytics = initialAnalytics
        self.lastUpdated = initialUpdatedAt
        let initialState = Self.initialState(
            providers: initialProviders, updatedAt: initialUpdatedAt, staleAfter: staleAfter
        )
        self.state = initialState
        self.presentationPacket = UsagePresentationPacket(
            generation: 0,
            providers: initialProviders,
            analytics: initialAnalytics,
            loadState: initialState,
            failure: initialFailure,
            lastUpdated: initialUpdatedAt,
            updateKind: .initial
        )
    }

    public init(fetch: @escaping @Sendable () async throws -> APIUsagePayload,
                staleAfter: TimeInterval = 15 * 60,
                initialProviders: [ProviderSnapshot] = [],
                initialUpdatedAt: Date? = nil,
                historyPersistence: UsageHistoryPersistence = UserDefaultsUsageHistoryPersistence()) {
        self.fetchPayload = fetch
        self.staleAfter = staleAfter
        self.historyPersistence = historyPersistence
        self.snapshotPersistence = SharedUsageWidgetSnapshotPersistence()
        self.reloadWidgets = UsageWidgetTimelineReloader.reload
        self.allowsRefresh = true
        let loadedHistory = Self.loadHistory(from: historyPersistence)
        self.historyLedger = loadedHistory.ledger
        self.historyStatus = loadedHistory.ledger.isEmpty ? .empty : .available
        self.historyErrorMessage = loadedHistory.errorMessage
        let initialFailure: UsageRefreshFailure = loadedHistory.errorMessage == nil ? .none : .historyStorage
        self.failure = initialFailure
        self.providers = initialProviders
        let initialAnalytics = UsageAnalyticsHistoryBuilder.snapshots(
            from: loadedHistory.ledger, providers: initialProviders
        )
        self.analytics = initialAnalytics
        self.lastUpdated = initialUpdatedAt
        let initialState = Self.initialState(
            providers: initialProviders, updatedAt: initialUpdatedAt, staleAfter: staleAfter
        )
        self.state = initialState
        self.presentationPacket = UsagePresentationPacket(
            generation: 0,
            providers: initialProviders,
            analytics: initialAnalytics,
            loadState: initialState,
            failure: initialFailure,
            lastUpdated: initialUpdatedAt,
            updateKind: .initial
        )
    }

    /// Creates the dependency graph used by screenshot and visual-fixture
    /// hosts. The fixture coordinator cannot refresh, has no live transport,
    /// reads only a unique temporary history file, and cannot publish to the
    /// user's App Group. The injectable fetch is internal so regression tests
    /// can prove that the hard gate prevents even an instrumented transport
    /// from being called.
    static func visualFixture(
        fetch: @escaping @Sendable () async throws -> APIUsagePayload = {
            throw UsageFixtureError.refreshDisabled
        },
        fileManager: FileManager = .default,
        snapshotPersistence: UsageWidgetSnapshotPersistence = NoopUsageWidgetSnapshotPersistence(),
        reloadWidgets: @escaping () -> Void = {}
    ) -> UsageCoordinator {
        let directory = fileManager.temporaryDirectory
            .appendingPathComponent("LifeOS", isDirectory: true)
            .appendingPathComponent("UsageFixtures", isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let historyPersistence = TemporaryUsageHistoryPersistence(
            fileURL: directory.appendingPathComponent("usage-history.json"),
            fileManager: fileManager
        )
        return UsageCoordinator(
            fetchPayload: fetch,
            staleAfter: 15 * 60,
            initialProviders: [],
            initialUpdatedAt: nil,
            historyPersistence: historyPersistence,
            snapshotPersistence: snapshotPersistence,
            reloadWidgets: reloadWidgets,
            allowsRefresh: false
        )
    }

    private init(
        fetchPayload: @escaping @Sendable () async throws -> APIUsagePayload,
        staleAfter: TimeInterval,
        initialProviders: [ProviderSnapshot],
        initialUpdatedAt: Date?,
        historyPersistence: UsageHistoryPersistence,
        snapshotPersistence: UsageWidgetSnapshotPersistence,
        reloadWidgets: @escaping () -> Void,
        allowsRefresh: Bool
    ) {
        self.fetchPayload = fetchPayload
        self.staleAfter = staleAfter
        self.historyPersistence = historyPersistence
        self.snapshotPersistence = snapshotPersistence
        self.reloadWidgets = reloadWidgets
        self.allowsRefresh = allowsRefresh
        let loadedHistory = Self.loadHistory(from: historyPersistence)
        self.historyLedger = loadedHistory.ledger
        self.historyStatus = loadedHistory.ledger.isEmpty ? .empty : .available
        self.historyErrorMessage = loadedHistory.errorMessage
        let initialFailure: UsageRefreshFailure = loadedHistory.errorMessage == nil ? .none : .historyStorage
        self.failure = initialFailure
        self.providers = initialProviders
        let initialAnalytics = UsageAnalyticsHistoryBuilder.snapshots(
            from: loadedHistory.ledger, providers: initialProviders
        )
        self.analytics = initialAnalytics
        self.lastUpdated = initialUpdatedAt
        let initialState = Self.initialState(
            providers: initialProviders, updatedAt: initialUpdatedAt, staleAfter: staleAfter
        )
        self.state = initialState
        self.presentationPacket = UsagePresentationPacket(
            generation: 0,
            providers: initialProviders,
            analytics: initialAnalytics,
            loadState: initialState,
            failure: initialFailure,
            lastUpdated: initialUpdatedAt,
            updateKind: .initial
        )
    }

    public func refresh() async {
        guard allowsRefresh else { return }
        refreshGeneration &+= 1
        let generation = refreshGeneration
        if let previous = refreshTask {
            previous.cancel()
            await previous.value
        }
        guard generation == refreshGeneration else { return }

        let operation = Task { [weak self] in
            guard let self else { return }
            await MainActor.run {
                guard generation == self.refreshGeneration else { return }
                self.state = .loading
                self.failure = self.historyErrorMessage == nil ? .none : .historyStorage
                self.errorMessage = self.historyErrorMessage
                self.publishPresentationPacket(generation: generation, updateKind: .loading)
            }
            do {
                try Task.checkCancellation()
                let payload = try await self.fetchPayload()
                try Task.checkCancellation()
                let mapped = try UsageIngestion.map(payload, now: .now)
                await MainActor.run {
                    self.apply(mapped, generatedAt: payload.generatedAt, generation: generation)
                }
            } catch is CancellationError {
                // A newer refresh or lifecycle cancellation owns the next truthful state.
            } catch {
                await MainActor.run { self.fail(error, generation: generation) }
            }
        }
        refreshTask = operation
        await operation.value
        if generation == refreshGeneration { refreshTask = nil }
    }

    public func cancel() {
        refreshGeneration &+= 1
        refreshTask?.cancel()
        state = providers.contains(where: { $0.provenance.quality == .observed }) ? .stale : .unavailable
        publishPresentationPacket(
            generation: refreshGeneration,
            updateKind: .cancelled
        )
    }

    private func apply(_ mapped: UsageMappingResult, generatedAt: Date, generation: Int) {
        guard generation == refreshGeneration else { return }
        providers = mapped.providers
        connectorStates = mapped.connectorStates
        lastUpdated = generatedAt

        let incoming = mapped.providers.flatMap { provider in
            provider.windows.compactMap { window -> UsageHistoryEntry? in
                guard let usedPercent = window.usedPercent,
                      let provenance = window.provenance,
                      provenance.quality == .observed,
                      let durationMinutes = window.durationMinutes else { return nil }
                return UsageHistoryEntry(
                    provider: provider.provider,
                    window: window.id,
                    durationMinutes: durationMinutes,
                    usedPercent: usedPercent * 100,
                    resetAt: window.resetAt,
                    observedAt: provenance.observedAt,
                    source: provenance.source,
                    connectorState: provenance.connector
                )
            }
        }

        if !incoming.isEmpty {
            do {
                let key = UsageHistoryDigest.idempotencyKey(for: incoming)
                _ = try historyLedger.append(incoming, idempotencyKey: key, now: .now)
                try persistHistory()
                historyStatus = historyLedger.isEmpty ? .empty : .available
                historyErrorMessage = nil
                failure = .none
            } catch {
                // Current gateway values remain usable; only the durable
                // history capability is unavailable. Do not turn that into a
                // zero-length or synthetic history series.
                historyStatus = .storageError
                historyErrorMessage = "Usage history unavailable"
                failure = .historyStorage
            }
        }

        analytics = mergedAnalytics(
            mapped.analytics,
            history: UsageAnalyticsHistoryBuilder.snapshots(from: historyLedger, providers: mapped.providers)
        )
        let observed = mapped.providers.filter { $0.provenance.quality == .observed }
        let hasStale = !observed.isEmpty && (Date.now.timeIntervalSince(generatedAt) >= staleAfter || observed.contains {
            let freshness = $0.provenance.freshness(now: .now, staleAfter: staleAfter)
            return freshness == .stale || freshness == .unavailable
        })
        state = observed.isEmpty ? .unavailable : (hasStale ? .stale : .observed)
        errorMessage = historyErrorMessage ?? (observed.isEmpty ? "Usage data unavailable" : nil)
        publishSnapshot(mapped.providers, generatedAt: generatedAt)
        publishPresentationPacket(
            generation: generation,
            updateKind: observed.isEmpty ? .authoritativeEmpty : .resolved
        )
    }

    private func fail(_ error: Error, generation: Int) {
        guard generation == refreshGeneration else { return }
        if error is UsageIngestionError || error is DecodingError {
            failure = .invalidPayload
            errorMessage = "Usage payload unavailable"
        } else {
            failure = .transport
            errorMessage = "Usage source unavailable"
        }
        state = providers.contains(where: { $0.provenance.quality == .observed }) ? .stale : .unavailable
        if !providers.isEmpty { publishSnapshot(providers, generatedAt: lastUpdated ?? .now) }
        publishPresentationPacket(generation: generation, updateKind: .failed)
    }

    private func publishPresentationPacket(
        generation: Int,
        updateKind: UsagePresentationUpdateKind
    ) {
        guard generation == refreshGeneration else { return }
        let snapshot = UsagePresentationPacket(
            generation: generation,
            providers: providers,
            analytics: analytics,
            loadState: state,
            failure: failure,
            lastUpdated: lastUpdated,
            updateKind: updateKind
        )
        presentationPacket = snapshot
    }

    private static func initialState(
        providers: [ProviderSnapshot],
        updatedAt: Date?,
        staleAfter: TimeInterval
    ) -> UsageLoadState {
        guard providers.contains(where: { $0.provenance.quality == .observed }) else {
            return .unavailable
        }
        let timestampIsStale = updatedAt.map { Date.now.timeIntervalSince($0) >= staleAfter } ?? true
        let providerIsStale = providers.contains {
            let freshness = $0.provenance.freshness(now: .now, staleAfter: staleAfter)
            return freshness == .stale || freshness == .unavailable
        }
        return timestampIsStale || providerIsStale ? .stale : .observed
    }

    private func persistHistory() throws {
        let archive = try historyLedger.archive().validated(now: .now)
        let encoded = try JSONEncoder.lifeOS.encode(archive)
        guard encoded.count <= UsageHistoryLedger.maximumArchiveBytes else {
            throw UsageHistoryError.archiveTooLarge
        }
        try historyPersistence.save(encoded)
    }

    private func mergedAnalytics(_ supplied: [UsageAnalyticsSnapshot],
                                 history: [UsageAnalyticsSnapshot]) -> [UsageAnalyticsSnapshot] {
        var result = supplied
        for record in history {
            if let index = result.firstIndex(where: {
                $0.provider == record.provider && $0.windowID == record.windowID
            }) {
                // A durable observation record is the stronger local source
                // for the history field; retain supplied model/heatmap data if
                // a future wire revision provides it.
                let existing = result[index]
                result[index] = UsageAnalyticsSnapshot(
                    provider: record.provider,
                    windowID: record.windowID,
                    activity: existing.activity,
                    projection: existing.projection.isEmpty ? record.projection : existing.projection,
                    modelBreakdowns: existing.modelBreakdowns,
                    heatmap: existing.heatmap,
                    provenance: existing.provenance,
                    history: record.history
                )
            } else {
                result.append(record)
            }
        }
        return result
    }

    private static func loadHistory(from persistence: UsageHistoryPersistence) ->
        (ledger: UsageHistoryLedger, errorMessage: String?) {
        do {
            guard let data = try persistence.load() else { return (UsageHistoryLedger(), nil) }
            guard data.count <= UsageHistoryLedger.maximumArchiveBytes else {
                throw UsageHistoryError.archiveTooLarge
            }
            let archive = try JSONDecoder.lifeOS.decode(UsageHistoryArchive.self, from: data)
            return (try UsageHistoryLedger(archive: archive), nil)
        } catch {
            return (UsageHistoryLedger(), "Usage history unavailable")
        }
    }

    private func publishSnapshot(_ providers: [ProviderSnapshot], generatedAt: Date) {
        let prior = snapshotPersistence.readLive()
        let observed = providers.filter { $0.provenance.quality == .observed }
        let observedAt = observed.map(\.provenance.observedAt).max() ?? generatedAt
        let aggregateProvenance = Provenance(
            source: observed.isEmpty ? "No connected usage source" : "Provider-specific usage observations",
            observedAt: observedAt,
            quality: observed.isEmpty ? .unavailable : .observed,
            connector: observed.isEmpty ? .unavailable :
                (observed.allSatisfy { $0.provenance.connector == .healthy } ? .healthy : .refreshDue)
        )
        let providerFreshness = observed.map { $0.provenance.freshness(now: .now, staleAfter: staleAfter) }
        let freshness: Freshness
        if observed.isEmpty || providerFreshness.contains(.unavailable) { freshness = .unavailable }
        else if providerFreshness.contains(.stale) { freshness = .stale }
        else if providerFreshness.contains(.aging) { freshness = .aging }
        else { freshness = .fresh }
        let snapshot = WidgetSnapshot(
            providers: providers,
            codexStatus: status(for: .codex),
            clipperSignal: prior?.clipperSignal ?? "Unavailable",
            healthSignal: prior?.healthSignal ?? "Unavailable",
            financeSignal: prior?.financeSignal ?? "Unavailable",
            updatedAt: generatedAt,
            freshness: freshness,
            warning: failure == .historyStorage
                ? "Usage history unavailable"
                : (state == .observed ? nil : "Usage data \(state.label)"),
            provenance: aggregateProvenance
        )
        do {
            try snapshotPersistence.write(snapshot)
            reloadWidgets()
        } catch {
            // The last good App Group snapshot remains the honest widget
            // fallback. A later foreground/background refresh can retry it.
        }
    }

    private func status(for provider: Provider) -> String {
        switch connectorStates[provider] ?? .unavailable {
        case .healthy: return "Connected"
        case .refreshDue: return "Refresh due"
        case .reauthRequired: return "Re-auth required"
        case .rateLimited: return "Rate limited"
        case .revoked, .disabled, .unavailable, .error: return "Unavailable"
        }
    }
}

private enum UsageFixtureError: Error {
    case refreshDisabled
}

private extension UsageLoadState {
    var label: String {
        switch self { case .demo: return "demo"; case .loading: return "loading"; case .observed: return "observed"; case .stale: return "stale"; case .unavailable: return "unavailable" }
    }
}
