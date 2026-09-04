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

public protocol UsagePayloadFetching: Sendable {
    func fetchUsage() async throws -> Data
}

extension TailscaleSyncClient: UsagePayloadFetching {}

@available(iOS 17.0, macOS 14.0, *)
@MainActor
public final class UsageCoordinator: ObservableObject {
    @Published public private(set) var state: UsageLoadState = .unavailable
    @Published public private(set) var providers: [ProviderSnapshot] = []
    @Published public private(set) var analytics: [UsageAnalyticsSnapshot] = []
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
        let loadedHistory = Self.loadHistory(from: historyPersistence)
        self.historyLedger = loadedHistory.ledger
        self.historyStatus = loadedHistory.ledger.isEmpty ? .empty : .available
        self.historyErrorMessage = loadedHistory.errorMessage
        self.failure = loadedHistory.errorMessage == nil ? .none : .historyStorage
        self.providers = initialProviders
        self.analytics = UsageAnalyticsHistoryBuilder.snapshots(
            from: loadedHistory.ledger, providers: initialProviders
        )
        self.lastUpdated = initialUpdatedAt
        if initialProviders.contains(where: { $0.provenance.quality == .observed }) {
            let timestampIsStale = initialUpdatedAt.map { Date.now.timeIntervalSince($0) >= staleAfter } ?? true
            state = timestampIsStale || initialProviders.contains {
                let freshness = $0.provenance.freshness(now: .now, staleAfter: staleAfter)
                return freshness == .stale || freshness == .unavailable
            } ? .stale : .observed
        }
    }

    public init(fetch: @escaping @Sendable () async throws -> APIUsagePayload,
                staleAfter: TimeInterval = 15 * 60,
                initialProviders: [ProviderSnapshot] = [],
                initialUpdatedAt: Date? = nil,
                historyPersistence: UsageHistoryPersistence = UserDefaultsUsageHistoryPersistence()) {
        self.fetchPayload = fetch
        self.staleAfter = staleAfter
        self.historyPersistence = historyPersistence
        let loadedHistory = Self.loadHistory(from: historyPersistence)
        self.historyLedger = loadedHistory.ledger
        self.historyStatus = loadedHistory.ledger.isEmpty ? .empty : .available
        self.historyErrorMessage = loadedHistory.errorMessage
        self.failure = loadedHistory.errorMessage == nil ? .none : .historyStorage
        self.providers = initialProviders
        self.analytics = UsageAnalyticsHistoryBuilder.snapshots(
            from: loadedHistory.ledger, providers: initialProviders
        )
        self.lastUpdated = initialUpdatedAt
        if initialProviders.contains(where: { $0.provenance.quality == .observed }) {
            let timestampIsStale = initialUpdatedAt.map { Date.now.timeIntervalSince($0) >= staleAfter } ?? true
            state = timestampIsStale || initialProviders.contains {
                let freshness = $0.provenance.freshness(now: .now, staleAfter: staleAfter)
                return freshness == .stale || freshness == .unavailable
            } ? .stale : .observed
        }
    }

    public func refresh() async {
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
                self.state = .loading
                self.failure = self.historyErrorMessage == nil ? .none : .historyStorage
                self.errorMessage = self.historyErrorMessage
            }
            do {
                try Task.checkCancellation()
                let payload = try await self.fetchPayload()
                try Task.checkCancellation()
                let mapped = try UsageIngestion.map(payload, now: .now)
                await MainActor.run { self.apply(mapped, generatedAt: payload.generatedAt) }
            } catch is CancellationError {
                // A newer refresh or lifecycle cancellation owns the next truthful state.
            } catch {
                await MainActor.run { self.fail(error) }
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
    }

    private func apply(_ mapped: UsageMappingResult, generatedAt: Date) {
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
    }

    private func fail(_ error: Error) {
        if error is UsageIngestionError || error is DecodingError {
            failure = .invalidPayload
            errorMessage = "Usage payload unavailable"
        } else {
            failure = .transport
            errorMessage = "Usage source unavailable"
        }
        state = providers.contains(where: { $0.provenance.quality == .observed }) ? .stale : .unavailable
        if !providers.isEmpty { publishSnapshot(providers, generatedAt: lastUpdated ?? .now) }
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
        let prior = SharedSnapshotStore.read()
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
            try SharedSnapshotStore.write(snapshot)
            UsageWidgetTimelineReloader.reload()
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

private extension UsageLoadState {
    var label: String {
        switch self { case .demo: return "demo"; case .loading: return "loading"; case .observed: return "observed"; case .stale: return "stale"; case .unavailable: return "unavailable" }
    }
}
