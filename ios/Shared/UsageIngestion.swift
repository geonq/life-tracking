import Foundation

public struct UsageMappingResult: Equatable, Sendable {
    public let providers: [ProviderSnapshot]
    public let analytics: [UsageAnalyticsSnapshot]
    public let connectorStates: [Provider: ConnectorState]

    public init(providers: [ProviderSnapshot], analytics: [UsageAnalyticsSnapshot], connectorStates: [Provider: ConnectorState]) {
        self.providers = providers
        self.analytics = analytics
        self.connectorStates = connectorStates
    }
}

public enum UsageIngestionError: Error, Equatable, Sendable {
    case invalidWindow
    case invalidProvenance
    case invalidEstimate
}

public enum UsageIngestion {
    private static let maximumClockSkew: TimeInterval = 5

    public static func map(_ payload: APIUsagePayload, now: Date = .now) throws -> UsageMappingResult {
        guard payload.generatedAt <= now.addingTimeInterval(maximumClockSkew),
              Set(payload.connectors.keys) == Set(Provider.allCases.map(\.rawValue)),
              payload.connectors.values.allSatisfy({ [.healthy, .refreshDue, .reauthRequired, .revoked, .rateLimited, .unavailable].contains($0) }) else {
            throw UsageIngestionError.invalidProvenance
        }
        var windowKeys = Set<String>()
        for window in payload.windows {
            let key = "\(window.provider.rawValue):\(window.window)"
            guard windowKeys.insert(key).inserted else { throw UsageIngestionError.invalidWindow }
        }
        var estimateKeys = Set<String>()
        for estimate in payload.estimates {
            guard ["five_hour", "seven_day"].contains(estimate.window),
                  estimate.official == false,
                  ["low", "medium", "high", "insufficient"].contains(estimate.confidence),
                  estimate.sampleSpanHours.isFinite, estimate.sampleSpanHours >= 0,
                  estimate.projectedPercentAtReset.map({ $0.isFinite && (0...100).contains($0) }) ?? true,
                  estimate.velocityPercentPerHour.map({ $0.isFinite && $0 >= 0 }) ?? true else {
                throw UsageIngestionError.invalidEstimate
            }
            let key = "\(estimate.provider.rawValue):\(estimate.window)"
            guard estimateKeys.insert(key).inserted else { throw UsageIngestionError.invalidEstimate }
        }

        var states: [Provider: ConnectorState] = [:]
        for provider in Provider.allCases {
            states[provider] = payload.connectors[provider.rawValue]
        }

        var snapshots: [ProviderSnapshot] = []
        for provider in Provider.allCases {
            let apiWindows = payload.windows.filter { $0.provider == provider }
            let estimates = payload.estimates.filter { $0.provider == provider }
            let windows = try apiWindows.map { try mapWindow($0, estimates: estimates, now: now) }
            let shouldExposeProvider = payload.connectors[provider.rawValue] != nil || !windows.isEmpty
            guard shouldExposeProvider else { continue }

            let observedProvenances = windows.compactMap(\.provenance).filter { $0.quality == .observed }
            let connector = states[provider] ?? .unavailable
            let summary: Provenance
            if let newest = observedProvenances.max(by: { $0.observedAt < $1.observedAt }) {
                let sources = Set(observedProvenances.map(\.source))
                summary = Provenance(
                    source: sources.count == 1 ? newest.source : "Multiple provider observations",
                    observedAt: newest.observedAt,
                    quality: .observed,
                    connector: connector
                )
            } else {
                summary = Provenance(
                    source: "No validated \(providerName(provider)) observation",
                    observedAt: payload.generatedAt,
                    quality: .unavailable,
                    connector: connector
                )
            }
            snapshots.append(ProviderSnapshot(
                provider: provider,
                accountLabel: providerName(provider),
                windows: windows.sorted { ($0.durationMinutes ?? .max) < ($1.durationMinutes ?? .max) },
                provenance: summary
            ))
        }

        return UsageMappingResult(providers: snapshots, analytics: [], connectorStates: states)
    }

    private static func mapWindow(_ api: APIUsageWindow, estimates: [APIUsageEstimate], now: Date) throws -> UsageWindow {
        let expectedMinutes: Int
        let label: String
        switch api.window {
        case "five_hour": expectedMinutes = 300; label = "5-hour"
        case "seven_day": expectedMinutes = 10_080; label = "7-day"
        default: throw UsageIngestionError.invalidWindow
        }
        guard api.durationMinutes == expectedMinutes,
              !api.provenance.source.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              ["fresh", "stale", "unknown"].contains(api.provenance.freshness) else {
            throw UsageIngestionError.invalidProvenance
        }
        let age = now.timeIntervalSince(api.provenance.observedAt)
        guard age >= -maximumClockSkew else { throw UsageIngestionError.invalidProvenance }

        if api.availability == "unavailable" {
            guard api.usedPercent == nil, api.resetAt == nil,
                  api.provenance.official == false,
                  api.provenance.quality == "unavailable",
                  api.provenance.freshness == "unknown",
                  [.reauthRequired, .revoked, .rateLimited, .unavailable].contains(api.provenance.connectorState) else {
                throw UsageIngestionError.invalidWindow
            }
            let provenance = Provenance(source: api.provenance.source, observedAt: api.provenance.observedAt,
                                        quality: .unavailable, connector: api.provenance.connectorState)
            return UsageWindow(id: api.window, label: label, durationMinutes: expectedMinutes, provenance: provenance)
        }

        guard api.availability == "observed", let used = api.usedPercent,
              used.isFinite, (0...100).contains(used),
              api.provenance.official, api.provenance.quality == "observed" else {
            throw UsageIngestionError.invalidWindow
        }
        let expectedFreshness = age <= 15 * 60 ? "fresh" : "stale"
        let expectedConnector: ConnectorState = expectedFreshness == "stale" ? .refreshDue : (used >= 100 ? .rateLimited : .healthy)
        guard api.provenance.freshness == expectedFreshness,
              api.provenance.connectorState == expectedConnector else {
            throw UsageIngestionError.invalidProvenance
        }
        let provenance = Provenance(source: api.provenance.source, observedAt: api.provenance.observedAt,
                                    quality: .observed, connector: api.provenance.connectorState)
        let matching = estimates.first { $0.window == api.window }
        let projection: Projection?
        if let matching {
            guard matching.official == false,
                  matching.provider == api.provider, matching.window == api.window,
                  ["low", "medium", "high", "insufficient"].contains(matching.confidence),
                  matching.sampleSpanHours.isFinite, matching.sampleSpanHours >= 0,
                  matching.projectedPercentAtReset.map({ $0.isFinite && (0...100).contains($0) }) ?? true,
                  matching.velocityPercentPerHour.map({ $0.isFinite && $0 >= 0 }) ?? true else {
                throw UsageIngestionError.invalidEstimate
            }
            projection = matching.projectedPercentAtReset.map {
                Projection(percentAtReset: $0 / 100,
                           sampleSpan: "\(matching.sampleSpanHours) hours · \(matching.confidence)")
            }
        } else {
            projection = nil
        }
        return UsageWindow(id: api.window, label: label, limit: 1, used: used / 100,
                           resetAt: api.resetAt, projection: projection,
                           durationMinutes: expectedMinutes, provenance: provenance)
    }

    private static func providerName(_ provider: Provider) -> String {
        provider == .codex ? "Codex" : "Claude"
    }
}
