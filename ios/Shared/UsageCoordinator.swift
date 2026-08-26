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

    private let fetchPayload: @Sendable () async throws -> APIUsagePayload
    private var refreshTask: Task<Void, Never>?
    private var refreshGeneration = 0
    private let staleAfter: TimeInterval

    public init(client: UsagePayloadFetching = TailscaleSyncClient(),
                staleAfter: TimeInterval = 15 * 60,
                initialProviders: [ProviderSnapshot] = [],
                initialUpdatedAt: Date? = nil) {
        self.fetchPayload = {
            let data = try await client.fetchUsage()
            return try JSONDecoder.lifeOS.decode(APIUsagePayload.self, from: data)
        }
        self.staleAfter = staleAfter
        self.providers = initialProviders
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
                initialUpdatedAt: Date? = nil) {
        self.fetchPayload = fetch
        self.staleAfter = staleAfter
        self.providers = initialProviders
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
            await MainActor.run { self.state = .loading; self.errorMessage = nil }
            do {
                try Task.checkCancellation()
                let payload = try await self.fetchPayload()
                try Task.checkCancellation()
                let mapped = try UsageIngestion.map(payload)
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
        analytics = mapped.analytics
        connectorStates = mapped.connectorStates
        lastUpdated = generatedAt
        let observed = mapped.providers.filter { $0.provenance.quality == .observed }
        let hasStale = !observed.isEmpty && (Date.now.timeIntervalSince(generatedAt) >= staleAfter || observed.contains {
            let freshness = $0.provenance.freshness(now: .now, staleAfter: staleAfter)
            return freshness == .stale || freshness == .unavailable
        })
        state = observed.isEmpty ? .unavailable : (hasStale ? .stale : .observed)
        errorMessage = observed.isEmpty ? "Usage data unavailable" : nil
        publishSnapshot(mapped.providers, generatedAt: generatedAt)
    }

    private func fail(_ error: Error) {
        errorMessage = "Usage data unavailable"
        state = providers.contains(where: { $0.provenance.quality == .observed }) ? .stale : .unavailable
        if !providers.isEmpty { publishSnapshot(providers, generatedAt: lastUpdated ?? .now) }
        _ = error
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
            warning: state == .observed ? nil : "Usage data \(state.label)",
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
