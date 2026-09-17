import XCTest
@testable import LifeOSMac

@available(macOS 14.0, *)
final class UsageProviderRegistryMacTests: XCTestCase {
    func testReviewedCatalogRetainsClaudeAndSeparatesGeminiSources() throws {
        let descriptors = UsageProviderCatalog.reviewed
        XCTAssertEqual(descriptors.count, 7)
        XCTAssertEqual(Set(descriptors.map { $0.id.rawValue }), [
            "codex", "claude", "gemini_subscription", "gemini_api", "glm",
            "deepseek", "google_ai_studio"
        ])

        let claude = try XCTUnwrap(descriptors.first { $0.id.rawValue == "claude" })
        XCTAssertEqual(claude.productKind, .subscription)
        XCTAssertTrue(claude.hasOfficialQuota)

        let subscription = try XCTUnwrap(
            descriptors.first { $0.id.rawValue == "gemini_subscription" }
        )
        let api = try XCTUnwrap(descriptors.first { $0.id.rawValue == "gemini_api" })
        let studio = try XCTUnwrap(
            descriptors.first { $0.id.rawValue == "google_ai_studio" }
        )
        XCTAssertEqual(subscription.productKind, .subscription)
        XCTAssertEqual(api.productKind, .api)
        XCTAssertEqual(studio.productKind, .api)
        XCTAssertNotEqual(subscription.id, api.id)
        XCTAssertNotEqual(api.id, studio.id)
        XCTAssertFalse(subscription.hasOfficialQuota)
        XCTAssertFalse(api.hasOfficialQuota)
        XCTAssertFalse(studio.hasOfficialQuota)

        let registry = try UsageRegistryAdapter.fromLegacy(
            mapping: UsageRegistryAdapter.legacyMapping(providers: [], connectorStates: [:]),
            generatedAt: nil
        )
        let subscriptionConnection = try XCTUnwrap(
            registry.connection(id: try UsageConnectionID("catalog.gemini_subscription"))
        )
        let apiConnection = try XCTUnwrap(
            registry.connection(id: try UsageConnectionID("catalog.gemini_api"))
        )
        XCTAssertEqual(subscriptionConnection.label, "Google AI Pro")
        XCTAssertEqual(subscriptionConnection.availability, .unsupported)
        XCTAssertEqual(apiConnection.availability, .unsupported)
        XCTAssertTrue(registry.windows(for: subscriptionConnection.connectionID).isEmpty)
        XCTAssertTrue(registry.windows(for: apiConnection.connectionID).isEmpty)
        XCTAssertTrue(registry.observations.isEmpty)
        XCTAssertTrue(registry.estimates.isEmpty)
    }

    func testLegacyAdapterPreservesObservedEstimateStaleUnavailableAndLegacyReferences() throws {
        let now = Date(timeIntervalSinceReferenceDate: 800_000_000)
        let observedAt = now.addingTimeInterval(-3_600)
        let resetAt = now.addingTimeInterval(2_400)
        let source = Provenance(
            source: "reviewed-codex-source",
            observedAt: observedAt,
            quality: .observed,
            connector: .refreshDue
        )
        let unavailableSource = Provenance(
            source: "claude-not-connected",
            observedAt: now,
            quality: .unavailable,
            connector: .reauthRequired
        )
        let codex = ProviderSnapshot(
            provider: .codex,
            accountLabel: "Personal Codex",
            windows: [
                UsageWindow(
                    id: "five_hour",
                    label: "5-hour",
                    limit: 1,
                    used: 0.42,
                    resetAt: resetAt,
                    projection: Projection(
                        percentAtReset: 0.78,
                        sampleSpan: "12 hours · high"
                    ),
                    durationMinutes: 300,
                    provenance: source
                ),
                UsageWindow(
                    id: "seven_day",
                    label: "7-day",
                    limit: 1,
                    used: nil,
                    resetAt: nil,
                    durationMinutes: 10_080,
                    provenance: Provenance(
                        source: "codex-seven-day-unavailable",
                        observedAt: now,
                        quality: .unavailable,
                        connector: .unavailable
                    )
                )
            ],
            provenance: source
        )
        let claude = ProviderSnapshot(
            provider: .claude,
            accountLabel: "Claude",
            windows: [],
            provenance: unavailableSource
        )
        let mapping = UsageRegistryAdapter.legacyMapping(
            providers: [codex, claude],
            connectorStates: [
                .codex: .refreshDue,
                .claude: .reauthRequired,
                .glm: .unavailable,
                .deepseek: .unavailable,
                .googleAIStudio: .unavailable
            ]
        )

        let registry = try UsageRegistryAdapter.fromLegacy(
            mapping: mapping,
            generatedAt: now,
            now: now
        )
        let codexConnectionID = try UsageConnectionID("legacy.codex")
        let fiveHourID = try UsageWindowID("legacy.codex.five_hour")
        let fiveHourSelection = UsageRegistrySelection(
            connectionID: codexConnectionID,
            windowID: fiveHourID
        )
        let observation = try XCTUnwrap(registry.observation(for: fiveHourSelection))
        XCTAssertEqual(observation.value, .percentage(42))
        XCTAssertEqual(observation.resetAt, resetAt)
        XCTAssertEqual(observation.observedAt, observedAt)
        XCTAssertEqual(observation.receivedAt, now)
        XCTAssertEqual(observation.source, "reviewed-codex-source")
        XCTAssertEqual(observation.freshness, .stale)

        let estimate = try XCTUnwrap(registry.estimate(for: fiveHourSelection))
        XCTAssertEqual(estimate.projectedPercentAtReset, 78)
        XCTAssertEqual(estimate.confidence, "high")
        XCTAssertFalse(estimate.official)

        let legacyReference = try XCTUnwrap(registry.legacyDetail(for: fiveHourSelection))
        XCTAssertEqual(legacyReference.provider, .codex)
        XCTAssertEqual(legacyReference.sourceWindowID, "five_hour")

        let claudeConnection = try XCTUnwrap(
            registry.connection(id: try UsageConnectionID("legacy.claude"))
        )
        XCTAssertEqual(claudeConnection.availability, .unavailable)
        XCTAssertEqual(claudeConnection.authState, .reauthRequired)
        XCTAssertEqual(claudeConnection.freshness, .unavailable)

        XCTAssertTrue(
            registry.observations.allSatisfy {
                $0.selection.connectionID.rawValue.hasPrefix("legacy.")
            }
        )
        XCTAssertTrue(
            registry.estimates.allSatisfy {
                $0.selection.connectionID.rawValue.hasPrefix("legacy.")
            }
        )
        XCTAssertTrue(
            registry.legacyDetails.keys.allSatisfy {
                $0.connectionID.rawValue.hasPrefix("legacy.")
            }
        )
        XCTAssertNil(
            registry.legacyDetail(for: UsageRegistrySelection(
                connectionID: try UsageConnectionID("catalog.gemini_subscription"),
                windowID: try UsageWindowID("catalog.gemini_subscription.month")
            ))
        )
    }

    func testSameDurationWindowsHaveDistinctStableSelections() throws {
        let now = Date(timeIntervalSinceReferenceDate: 800_100_000)
        let provenance = Provenance(
            source: "same-duration-source",
            observedAt: now,
            quality: .observed,
            connector: .healthy
        )
        let snapshot = ProviderSnapshot(
            provider: .codex,
            accountLabel: "Codex",
            windows: [
                UsageWindow(
                    id: "primary",
                    label: "Primary",
                    limit: 1,
                    used: 0.20,
                    durationMinutes: 300,
                    provenance: provenance
                ),
                UsageWindow(
                    id: "secondary",
                    label: "Secondary",
                    limit: 1,
                    used: 0.60,
                    durationMinutes: 300,
                    provenance: provenance
                )
            ],
            provenance: provenance
        )
        let registry = try UsageRegistryAdapter.fromLegacy(
            mapping: UsageRegistryAdapter.legacyMapping(
                providers: [snapshot],
                connectorStates: [.codex: .healthy]
            ),
            generatedAt: now,
            now: now
        )
        let windows = registry.windows(for: try UsageConnectionID("legacy.codex"))
        XCTAssertEqual(windows.compactMap(\.durationMinutes), [300, 300])
        XCTAssertEqual(Set(windows.map(\.id)).count, 2)

        let legacyConnectionID = try UsageConnectionID("legacy.codex")
        let selections = windows.map {
            UsageRegistrySelection(
                connectionID: legacyConnectionID,
                windowID: $0.id
            )
        }
        XCTAssertNotEqual(selections[0].id, selections[1].id)
        XCTAssertEqual(registry.observation(for: selections[0])?.value, .percentage(20))
        XCTAssertEqual(registry.observation(for: selections[1])?.value, .percentage(60))
    }

    func testRegistryRejectsCrossConnectionScopesAndUnitMismatches() throws {
        let connectionA = try UsageRegistryConnection(
            connectionID: UsageConnectionID("test.codex"),
            providerID: UsageProviderID("codex"),
            label: "Codex",
            sortOrder: 0,
            authState: .connected,
            availability: .available
        )
        let connectionB = try UsageRegistryConnection(
            connectionID: UsageConnectionID("test.claude"),
            providerID: UsageProviderID("claude"),
            label: "Claude",
            sortOrder: 1,
            authState: .connected,
            availability: .available
        )
        let percentageWindow = try UsageRegistryWindow(
            id: UsageWindowID("test.percent"),
            label: "Percent",
            unit: .percentage,
            durationMinutes: 300,
            resetPolicy: .rolling
        )
        let counterWindow = try UsageRegistryWindow(
            id: UsageWindowID("test.counter"),
            label: "Counter",
            unit: .counter,
            durationMinutes: 300,
            resetPolicy: .rolling
        )
        let crossConnectionSelection = UsageRegistrySelection(
            connectionID: connectionB.connectionID,
            windowID: percentageWindow.id
        )

        XCTAssertThrowsError(
            try UsageRegistryPresentation(
                generatedAt: nil,
                connections: [connectionA, connectionB],
                windowsByConnection: [connectionA.connectionID: [percentageWindow]],
                completeScopes: [crossConnectionSelection]
            )
        )

        let now = Date(timeIntervalSinceReferenceDate: 800_200_000)
        let percentageObservation = try UsageRegistryObservation(
            selection: UsageRegistrySelection(
                connectionID: connectionA.connectionID,
                windowID: counterWindow.id
            ),
            value: .percentage(50),
            observedAt: now,
            receivedAt: now,
            source: "unit-test",
            evidenceKind: .providerReported,
            scope: .account,
            official: true,
            freshness: .fresh
        )
        XCTAssertThrowsError(
            try UsageRegistryPresentation(
                generatedAt: now,
                connections: [connectionA],
                windowsByConnection: [connectionA.connectionID: [counterWindow]],
                observations: [percentageObservation]
            )
        )

        let counterObservation = try UsageRegistryObservation(
            selection: UsageRegistrySelection(
                connectionID: connectionA.connectionID,
                windowID: percentageWindow.id
            ),
            value: .counter(used: 2, limit: 10),
            observedAt: now,
            receivedAt: now,
            source: "unit-test",
            evidenceKind: .providerReported,
            scope: .account,
            official: true,
            freshness: .fresh
        )
        XCTAssertThrowsError(
            try UsageRegistryPresentation(
                generatedAt: now,
                connections: [connectionA],
                windowsByConnection: [connectionA.connectionID: [percentageWindow]],
                observations: [counterObservation]
            )
        )
    }

    func testMixedLegacyProvidersRemainConvertibleWithoutGeminiObservations() throws {
        let now = Date(timeIntervalSinceReferenceDate: 800_300_000)
        let source = Provenance(
            source: "legacy-provider-source",
            observedAt: now,
            quality: .observed,
            connector: .healthy
        )
        let providers: [Provider] = [.codex, .claude, .glm, .deepseek, .googleAIStudio]
        let snapshots = providers.map { provider in
            ProviderSnapshot(
                provider: provider,
                accountLabel: provider.displayName,
                windows: [
                    UsageWindow(
                        id: "five_hour",
                        label: "5-hour",
                        limit: 1,
                        used: 0.25,
                        durationMinutes: 300,
                        provenance: source
                    )
                ],
                provenance: source
            )
        }
        let states = Dictionary(uniqueKeysWithValues: providers.map { ($0, ConnectorState.healthy) })
        let registry = try UsageRegistryAdapter.fromLegacy(
            mapping: UsageRegistryAdapter.legacyMapping(
                providers: snapshots,
                connectorStates: states
            ),
            generatedAt: now,
            now: now
        )

        for provider in providers {
            let selection = UsageRegistrySelection(
                connectionID: try UsageConnectionID("legacy.\(provider.rawValue)"),
                windowID: try UsageWindowID("legacy.\(provider.rawValue).five_hour")
            )
            let observation = try XCTUnwrap(registry.observation(for: selection))
            if provider == .codex || provider == .claude {
                XCTAssertEqual(observation.evidenceKind, .providerReported)
                XCTAssertTrue(observation.official)
            } else {
                XCTAssertEqual(observation.evidenceKind, .legacyValidated)
                XCTAssertFalse(observation.official)
            }
        }
        XCTAssertTrue(registry.observations.allSatisfy { $0.selection.connectionID.rawValue.hasPrefix("legacy.") })
        XCTAssertFalse(registry.observations.contains { $0.selection.connectionID.rawValue.contains("catalog.gemini") })
    }

    func testFirstRunPinsCanBeExplicitlyReplacedOrCleared() throws {
        let firstRun = try UsageRegistryAdapter.fromLegacy(
            mapping: UsageRegistryAdapter.legacyMapping(providers: [], connectorStates: [:]),
            generatedAt: nil
        )
        let codexID = try UsageConnectionID("legacy.codex")
        let claudeID = try UsageConnectionID("legacy.claude")
        XCTAssertEqual(firstRun.effectivePinnedConnectionIDs, Set([codexID, claudeID]))

        let explicit = try UsageRegistryPreferencesState(
            pinnedConnectionIDs: [try UsageConnectionID("legacy.glm")],
            pinningConfigured: true
        )
        let customized = try UsageRegistryAdapter.fromLegacy(
            mapping: UsageRegistryAdapter.legacyMapping(providers: [], connectorStates: [:]),
            generatedAt: nil,
            preferences: explicit
        )
        XCTAssertEqual(
            customized.effectivePinnedConnectionIDs,
            Set([try UsageConnectionID("legacy.glm")])
        )

        let cleared = try UsageRegistryPreferencesState(pinningConfigured: true)
        let unpinned = try UsageRegistryAdapter.fromLegacy(
            mapping: UsageRegistryAdapter.legacyMapping(providers: [], connectorStates: [:]),
            generatedAt: nil,
            preferences: cleared
        )
        XCTAssertTrue(unpinned.effectivePinnedConnectionIDs.isEmpty)
    }

    func testOversizedPreferenceDataIsRejectedBeforeDecode() throws {
        let suiteName = "LifeOS.UsageRegistryPreferencesTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        defaults.set(
            Data(repeating: 0, count: 32 * 1024 + 1),
            forKey: UserDefaultsUsageRegistryPreferencesStore.key
        )
        let store = UserDefaultsUsageRegistryPreferencesStore(defaults: defaults)

        XCTAssertThrowsError(try store.load()) { error in
            XCTAssertEqual(error as? UsageRegistryPreferencesError, .loadFailed)
        }
    }

    func testResetDraftIgnoresSavedPreferencesAndUsesEnabledMetadataDefaults() throws {
        let codexID = try UsageConnectionID("test.codex")
        let claudeID = try UsageConnectionID("test.claude")
        let glmID = try UsageConnectionID("test.glm")
        let deepSeekID = try UsageConnectionID("test.deepseek")
        let disabledID = try UsageConnectionID("test.disabled")
        let codex = try UsageRegistryConnection(
            connectionID: codexID,
            providerID: UsageProviderID("codex"),
            label: "Codex",
            enabled: true,
            pinned: true,
            sortOrder: 20,
            authState: .connected,
            availability: .available
        )
        let claude = try UsageRegistryConnection(
            connectionID: claudeID,
            providerID: UsageProviderID("claude"),
            label: "Claude",
            enabled: true,
            pinned: true,
            sortOrder: 10,
            authState: .connected,
            availability: .available
        )
        let glm = try UsageRegistryConnection(
            connectionID: glmID,
            providerID: UsageProviderID("glm"),
            label: "GLM",
            enabled: true,
            pinned: false,
            sortOrder: 30,
            authState: .disconnected,
            availability: .unavailable
        )
        let deepSeek = try UsageRegistryConnection(
            connectionID: deepSeekID,
            providerID: UsageProviderID("deepseek"),
            label: "DeepSeek",
            enabled: true,
            pinned: false,
            sortOrder: 30,
            authState: .disconnected,
            availability: .unavailable
        )
        let disabled = try UsageRegistryConnection(
            connectionID: disabledID,
            providerID: UsageProviderID("google_ai_studio"),
            label: "Disabled",
            enabled: false,
            pinned: true,
            sortOrder: 0,
            authState: .disconnected,
            availability: .disabled
        )
        let corruptSavedState = try UsageRegistryPreferencesState(
            hiddenConnectionIDs: [claudeID],
            pinnedConnectionIDs: [deepSeekID],
            pinningConfigured: true,
            orderedConnectionIDs: [deepSeekID, codexID, claudeID]
        )
        let presentation = try UsageRegistryPresentation(
            generatedAt: .now,
            connections: [codex, claude, glm, deepSeek, disabled],
            windowsByConnection: [:],
            preferences: corruptSavedState
        )

        let reset = try UsageConnectionsView.firstRunPreferences(for: presentation)

        XCTAssertEqual(reset.orderedConnectionIDs, [claudeID, codexID, deepSeekID, glmID])
        XCTAssertTrue(reset.hiddenConnectionIDs.isEmpty)
        XCTAssertEqual(reset.pinnedConnectionIDs, Set([claudeID, codexID]))
        XCTAssertFalse(reset.pinningConfigured)
    }
}
