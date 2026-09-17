import Foundation

/// Adapts the already validated v1 mapping into the provider-neutral native
/// presentation model. It deliberately does not decode or accept a v2 wire
/// payload; that transport migration is a separate tranche.
public enum UsageRegistryAdapter {
    public static func fromLegacy(
        mapping: UsageMappingResult,
        generatedAt: Date?,
        preferences: UsageRegistryPreferencesState = .empty,
        now: Date = .now,
        failure: UsageRegistryPresentationFailure = .none
    ) throws -> UsageRegistryPresentation {
        try preferences.validate()

        var snapshotsByProvider = [Provider: ProviderSnapshot]()
        for snapshot in mapping.providers {
            guard snapshotsByProvider.updateValue(snapshot, forKey: snapshot.provider) == nil else {
                throw UsageRegistryError.duplicateIdentifier(kind: "legacy provider", value: snapshot.provider.rawValue)
            }
        }

        var connections = [UsageRegistryConnection]()
        var windowsByConnection = [UsageConnectionID: [UsageRegistryWindow]]()
        var observations = [UsageRegistryObservation]()
        var estimates = [UsageRegistryEstimate]()
        var completeScopes = Set<UsageRegistrySelection>()
        var legacyDetails = [UsageRegistrySelection: UsageLegacyDetailReference]()

        let legacyProviders = Provider.allCases
        for (index, provider) in legacyProviders.enumerated() {
            let providerID = try UsageRegistryLegacyMapping.providerID(for: provider)
            let connectionID = try UsageRegistryLegacyMapping.connectionID(for: provider)
            let snapshot = snapshotsByProvider[provider]
            let connector = mapping.connectorStates[provider] ?? snapshot?.provenance.connector ?? .unavailable
            let observationWindows = snapshot?.windows.filter {
                $0.usedPercent != nil && $0.provenance?.quality == .observed
            } ?? []
            let availability: UsageAvailability
            if !observationWindows.isEmpty {
                availability = .available
            } else if connector == .disabled {
                availability = .disabled
            } else {
                availability = .unavailable
            }
            let freshness: UsageRegistryFreshness = snapshot.map {
                UsageRegistryFreshness($0.provenance.freshness(now: now))
            } ?? .unavailable
            let authState = authState(for: connector, hasObservedData: !observationWindows.isEmpty)
            let reasonCode: String? = observationWindows.isEmpty ? "no_observation" : nil
            let connection = try UsageRegistryConnection(
                connectionID: connectionID,
                providerID: providerID,
                label: snapshot.map { snapshot in
                    snapshot.accountLabel.isEmpty ? provider.displayName : snapshot.accountLabel
                } ?? provider.displayName,
                planLabel: provider.displayName,
                enabled: true,
                pinned: provider == .codex || provider == .claude,
                sortOrder: index,
                authState: authState,
                availability: availability,
                freshness: freshness,
                reasonCode: reasonCode
            )
            connections.append(connection)

            guard let snapshot else { continue }
            var windows = [UsageRegistryWindow]()
            for sourceWindow in snapshot.windows {
                let windowID = try UsageRegistryLegacyMapping.windowID(
                    for: provider, sourceWindowID: sourceWindow.id
                )
                let window = try UsageRegistryWindow(
                    id: windowID,
                    label: sourceWindow.label,
                    unit: .percentage,
                    durationMinutes: sourceWindow.durationMinutes,
                    resetPolicy: .rolling
                )
                windows.append(window)
                let selection = UsageRegistrySelection(connectionID: connectionID, windowID: windowID)
                completeScopes.insert(selection)
                legacyDetails[selection] = UsageLegacyDetailReference(
                    provider: provider, sourceWindowID: sourceWindow.id
                )

                if let usedPercent = sourceWindow.usedPercent,
                   let provenance = sourceWindow.provenance,
                   provenance.quality == .observed {
                    let evidenceKind: UsageEvidenceKind
                    let official: Bool
                    switch provider {
                    case .codex, .claude:
                        evidenceKind = .providerReported
                        official = true
                    case .glm, .deepseek, .googleAIStudio:
                        evidenceKind = .legacyValidated
                        official = false
                    }
                    observations.append(try UsageRegistryObservation(
                        selection: selection,
                        value: .percentage(usedPercent * 100),
                        resetAt: sourceWindow.resetAt,
                        observedAt: provenance.observedAt,
                        receivedAt: generatedAt ?? provenance.observedAt,
                        source: provenance.source,
                        evidenceKind: evidenceKind,
                        scope: .account,
                        official: official,
                        freshness: UsageRegistryFreshness(provenance.freshness(now: now))
                    ))
                }

                if let projection = sourceWindow.projection {
                    let confidence = projection.sampleSpan?.split(separator: "·").last
                        .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                        ?? "insufficient"
                    estimates.append(try UsageRegistryEstimate(
                        selection: selection,
                        projectedPercentAtReset: projection.percentAtReset.map { $0 * 100 },
                        confidence: confidence,
                        explanation: projection.sampleSpan ?? "Estimate derived from validated local history.",
                        official: false
                    ))
                }
            }
            windowsByConnection[connectionID] = windows
        }

        // These are catalog choices, not authenticated connections. Their
        // rows explain the supported boundary without inventing a quota.
        let subscriptionID = try UsageProviderID("gemini_subscription")
        let apiID = try UsageProviderID("gemini_api")
        let subscriptionConnectionID = try UsageConnectionID("catalog.gemini_subscription")
        let apiConnectionID = try UsageConnectionID("catalog.gemini_api")
        connections.append(try UsageRegistryConnection(
            connectionID: subscriptionConnectionID,
            providerID: subscriptionID,
            label: "Google AI Pro",
            planLabel: "Subscription",
            sortOrder: 100,
            authState: .notRequired,
            availability: .unsupported,
            freshness: .unavailable,
            reasonCode: "automatic_quota_unavailable"
        ))
        connections.append(try UsageRegistryConnection(
            connectionID: apiConnectionID,
            providerID: apiID,
            label: "Gemini API",
            planLabel: "API / project usage",
            sortOrder: 101,
            authState: .disconnected,
            availability: .unsupported,
            freshness: .unavailable,
            reasonCode: "no_automatic_project_meter"
        ))

        return try UsageRegistryPresentation(
            generatedAt: generatedAt,
            connections: connections,
            windowsByConnection: windowsByConnection,
            observations: observations,
            estimates: estimates,
            completeScopes: completeScopes,
            legacyDetails: legacyDetails,
            preferences: preferences,
            failure: failure
        )
    }

    public static func legacyMapping(
        providers: [ProviderSnapshot],
        analytics: [UsageAnalyticsSnapshot] = [],
        connectorStates: [Provider: ConnectorState]? = nil
    ) -> UsageMappingResult {
        var states = connectorStates ?? [:]
        if connectorStates == nil {
            for provider in providers {
                states[provider.provider] = provider.provenance.connector
            }
        }
        return UsageMappingResult(
            providers: providers,
            analytics: analytics,
            connectorStates: states
        )
    }

    private static func authState(for connector: ConnectorState, hasObservedData: Bool) -> UsageAuthState {
        switch connector {
        case .reauthRequired: return .reauthRequired
        case .revoked: return .revoked
        case .disabled, .unavailable, .error: return .disconnected
        case .healthy, .refreshDue, .rateLimited:
            return hasObservedData ? .connected : .disconnected
        }
    }
}
