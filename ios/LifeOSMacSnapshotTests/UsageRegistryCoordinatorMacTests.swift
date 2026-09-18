import Foundation
import XCTest
@testable import LifeOSMac

@available(macOS 14.0, *)
final class UsageRegistryCoordinatorMacTests: XCTestCase {
    func testPreferencesPersistAcrossCoordinatorRecreationAndRespectHiddenUnavailableConnections() async throws {
        let now = Date.now
        let codex = CoordinatorUsageFixtures.observedSnapshot(
            provider: .codex,
            observedAt: now,
            usedPercent: 24
        )
        let preferenceStore = InMemoryUsageRegistryPreferencesStore()
        let historyStore = RegistryHistoryStore()
        let coordinator = await MainActor.run {
            UsageCoordinator(
                fetch: { CoordinatorUsageFixtures.emptyPayload(now: now) },
                initialProviders: [codex],
                initialUpdatedAt: now,
                historyPersistence: historyStore,
                registryPreferencesStore: preferenceStore
            )
        }

        let codexID = try UsageConnectionID("legacy.codex")
        let claudeID = try UsageConnectionID("legacy.claude")
        let glmID = try UsageConnectionID("legacy.glm")
        let preferences = try UsageRegistryPreferencesState(
            hiddenConnectionIDs: [codexID],
            pinnedConnectionIDs: [glmID],
            pinningConfigured: true,
            orderedConnectionIDs: [glmID, claudeID, codexID]
        )
        let saved = await MainActor.run {
            coordinator.updateUsageRegistryPreferences(preferences)
        }
        XCTAssertTrue(saved)

        let remounted = await MainActor.run {
            UsageCoordinator(
                fetch: { CoordinatorUsageFixtures.emptyPayload(now: now) },
                initialProviders: [codex],
                initialUpdatedAt: now,
                historyPersistence: historyStore,
                registryPreferencesStore: preferenceStore
            )
        }
        let presentation = await MainActor.run { remounted.registryPresentation }
        XCTAssertEqual(presentation.preferences, preferences)
        XCTAssertFalse(presentation.visibleConnections.contains { $0.connectionID == codexID })
        XCTAssertTrue(
            presentation.visibleConnections.contains {
                $0.connectionID == claudeID && $0.availability == .unavailable
            },
            "An unavailable connection remains selectable until the user hides it."
        )
        XCTAssertTrue(
            presentation.orderedConnections(includeHidden: true).contains {
                $0.connectionID == codexID
            },
            "Hidden connections remain recoverable from management UI."
        )
        XCTAssertEqual(
            presentation.orderedConnections().first?.connectionID,
            glmID,
            "A pinned preference must affect the displayed order after remount."
        )
    }

    func testFailedPreferenceLoadAndSaveNeverReportSuccessOrApplyState() async throws {
        let store = InMemoryUsageRegistryPreferencesStore()
        store.loadError = .loadFailed
        let coordinator = await MainActor.run {
            UsageCoordinator(
                fetch: { CoordinatorUsageFixtures.emptyPayload(now: .now) },
                historyPersistence: RegistryHistoryStore(),
                registryPreferencesStore: store
            )
        }
        let initial = await MainActor.run {
            (coordinator.registryPreferences, coordinator.registryPreferencesError)
        }
        XCTAssertEqual(initial.0, .empty)
        XCTAssertEqual(initial.1, .loadFailed)

        store.loadError = nil
        store.saveError = .saveFailed
        let requested = try UsageRegistryPreferencesState(
            hiddenConnectionIDs: [try UsageConnectionID("legacy.codex")]
        )
        let saved = await MainActor.run {
            coordinator.updateUsageRegistryPreferences(requested)
        }
        let afterFailure = await MainActor.run {
            (coordinator.registryPreferences, coordinator.registryPreferencesError)
        }
        XCTAssertFalse(saved)
        XCTAssertEqual(afterFailure.0, .empty)
        XCTAssertEqual(afterFailure.1, .saveFailed)
    }

    func testAuthoritativeEmptyPayloadIsNotTransportFailure() async throws {
        let now = Date.now
        let sequence = RegistryPayloadSequence(steps: [
            .payload(CoordinatorUsageFixtures.observedPayload(now: now)),
            .payload(CoordinatorUsageFixtures.emptyPayload(now: now)),
            .failure
        ])
        let coordinator = await MainActor.run {
            UsageCoordinator(
                fetch: { try await sequence.next() },
                historyPersistence: RegistryHistoryStore()
            )
        }

        await coordinator.refresh()
        let observedPacket = await MainActor.run { coordinator.presentationPacket }
        XCTAssertEqual(observedPacket.updateKind, .resolved)
        XCTAssertEqual(observedPacket.failure, .none)

        await coordinator.refresh()
        let emptyPacket = await MainActor.run { coordinator.presentationPacket }
        let codexScope = UsagePresentationScope(provider: .codex, windowID: "five_hour")
        XCTAssertEqual(emptyPacket.updateKind, .authoritativeEmpty)
        XCTAssertEqual(emptyPacket.failure, .none)
        XCTAssertEqual(emptyPacket.authority(for: codexScope), .authoritativeEmpty)

        await coordinator.refresh()
        let failedPacket = await MainActor.run { coordinator.presentationPacket }
        XCTAssertEqual(failedPacket.updateKind, .failed)
        XCTAssertEqual(failedPacket.failure, .transport)
        XCTAssertNotEqual(failedPacket.updateKind, .authoritativeEmpty)
        XCTAssertEqual(failedPacket.authority(for: codexScope), .authoritativeEmpty)
    }

    func testConversionFailureRetainsPriorValuesAndPreferenceUpdateKeepsFailureVisible() async throws {
        let now = Date.now
        let sequence = RegistryPayloadSequence(steps: [
            .payload(CoordinatorUsageFixtures.observedPayload(now: now)),
            .payload(CoordinatorUsageFixtures.observedPayload(
                now: now,
                source: String(repeating: "s", count: 129)
            ))
        ])
        let historyStore = RegistryHistoryStore()
        let coordinator = await MainActor.run {
            UsageCoordinator(
                fetch: { try await sequence.next() },
                historyPersistence: historyStore
            )
        }

        await coordinator.refresh()
        let before = await MainActor.run {
            (coordinator.providers, coordinator.lastUpdated, coordinator.presentationPacket, historyStore.data)
        }

        await coordinator.refresh()
        let afterConversionFailure = await MainActor.run {
            (coordinator.providers, coordinator.lastUpdated, coordinator.presentationPacket, historyStore.data)
        }
        XCTAssertEqual(afterConversionFailure.0, before.0)
        XCTAssertEqual(afterConversionFailure.1, before.1)
        XCTAssertEqual(afterConversionFailure.3, before.3)
        XCTAssertEqual(afterConversionFailure.2.failure, .registryConversion)
        XCTAssertEqual(afterConversionFailure.2.updateKind, .failed)
        XCTAssertEqual(afterConversionFailure.2.registryPresentation.failure, .registryConversion)

        let preferences = try UsageRegistryPreferencesState(
            hiddenConnectionIDs: [try UsageConnectionID("legacy.claude")]
        )
        let saved = await MainActor.run {
            coordinator.updateUsageRegistryPreferences(preferences)
        }
        let afterPreferenceUpdate = await MainActor.run {
            (coordinator.failure, coordinator.presentationPacket)
        }
        XCTAssertTrue(saved)
        XCTAssertEqual(afterPreferenceUpdate.0, .registryConversion)
        XCTAssertEqual(afterPreferenceUpdate.1.updateKind, .failed)
        XCTAssertEqual(afterPreferenceUpdate.1.registryPresentation.failure, .registryConversion)
    }

    func testCancellationPublishesCancelledStateAndDoesNotBecomeFailure() async throws {
        let now = Date.now
        let gate = RegistryFetchGate()
        let initial = CoordinatorUsageFixtures.observedSnapshot(
            provider: .codex,
            observedAt: now,
            usedPercent: 20
        )
        let coordinator = await MainActor.run {
            UsageCoordinator(
                fetch: {
                    await gate.wait()
                    return CoordinatorUsageFixtures.observedPayload(now: now)
                },
                initialProviders: [initial],
                initialUpdatedAt: now,
                historyPersistence: RegistryHistoryStore()
            )
        }

        let refreshTask = Task { await coordinator.refresh() }
        for _ in 0..<500 {
            if await gate.hasStarted() { break }
            await Task.yield()
        }
        let started = await gate.hasStarted()
        XCTAssertTrue(started)

        await MainActor.run { coordinator.cancel() }
        let cancelledPacket = await MainActor.run { coordinator.presentationPacket }
        XCTAssertEqual(cancelledPacket.updateKind, .cancelled)
        XCTAssertEqual(cancelledPacket.failure, .none)
        XCTAssertEqual(cancelledPacket.loadState, .stale)

        await gate.release()
        await refreshTask.value
        let afterCancelledOperation = await MainActor.run { coordinator.presentationPacket }
        XCTAssertEqual(afterCancelledOperation.updateKind, .cancelled)
        XCTAssertEqual(afterCancelledOperation.failure, .none)
    }

    func testLegacySelectionIDsSurviveRemountAndOldArchiveShapeRemainsReadable() throws {
        let now = Date.now
        let source = Provenance(
            source: "legacy-source",
            observedAt: now,
            quality: .observed,
            connector: .healthy
        )
        let firstSnapshot = ProviderSnapshot(
            provider: .codex,
            accountLabel: "Codex",
            windows: [
                UsageWindow(
                    id: "five_hour",
                    label: "5-hour",
                    limit: 1,
                    used: 0.30,
                    durationMinutes: 300,
                    provenance: source
                ),
                UsageWindow(
                    id: "seven_day",
                    label: "7-day",
                    limit: 1,
                    used: 0.40,
                    durationMinutes: 10_080,
                    provenance: source
                )
            ],
            provenance: source
        )
        let secondSnapshot = ProviderSnapshot(
            provider: .codex,
            accountLabel: "Codex",
            windows: Array(firstSnapshot.windows.reversed()),
            provenance: source
        )
        let firstRegistry = try UsageRegistryAdapter.fromLegacy(
            mapping: UsageRegistryAdapter.legacyMapping(
                providers: [firstSnapshot],
                connectorStates: [.codex: .healthy]
            ),
            generatedAt: now,
            now: now
        )
        let remountedRegistry = try UsageRegistryAdapter.fromLegacy(
            mapping: UsageRegistryAdapter.legacyMapping(
                providers: [secondSnapshot],
                connectorStates: [.codex: .healthy]
            ),
            generatedAt: now,
            now: now
        )
        let selection = UsageRegistrySelection(
            connectionID: try UsageConnectionID("legacy.codex"),
            windowID: try UsageWindowID("legacy.codex.five_hour")
        )
        XCTAssertEqual(
            firstRegistry.observation(for: selection)?.value,
            remountedRegistry.observation(for: selection)?.value
        )
        XCTAssertEqual(
            remountedRegistry.legacyDetail(for: selection)?.sourceWindowID,
            "five_hour"
        )

        let entry = UsageHistoryEntry(
            provider: .codex,
            window: "five_hour",
            durationMinutes: 300,
            usedPercent: 30,
            resetAt: now.addingTimeInterval(3_600),
            observedAt: now,
            source: "legacy-source",
            connectorState: .healthy
        )
        let archive = UsageHistoryArchive(entries: [entry])
        let encoded = try JSONEncoder.lifeOS.encode(archive)
        var oldObject = try XCTUnwrap(
            JSONSerialization.jsonObject(with: encoded) as? [String: Any]
        )
        oldObject.removeValue(forKey: "authoritativeEmptyScopes")
        let oldData = try JSONSerialization.data(withJSONObject: oldObject)
        let decoded = try JSONDecoder.lifeOS.decode(UsageHistoryArchive.self, from: oldData)
        XCTAssertTrue(decoded.authoritativeEmptyScopes.isEmpty)
        let ledger = try UsageHistoryLedger(archive: decoded, now: now)
        XCTAssertEqual(ledger.entries, [entry])
    }

    func testManualReadingSaveBuildsRegistryAndStoreFailureKeepsVisibleState() async throws {
        let now = Date(timeIntervalSinceReferenceDate: 800_000_000)
        let store = InMemoryUsageManualReadingStore()
        let coordinator = await MainActor.run {
            UsageCoordinator(
                fetch: { CoordinatorUsageFixtures.emptyPayload(now: now) },
                initialUpdatedAt: now,
                historyPersistence: RegistryHistoryStore(),
                manualReadingStore: store,
                clock: { now }
            )
        }
        let reading = try UsageManualReading(
            providerID: try UsageProviderID(UsageManualReading.supportedProviderID),
            adapterID: UsageManualReading.supportedAdapterID,
            window: .fiveHour,
            usedPercent: 42,
            observedAt: now.addingTimeInterval(-60),
            resetAt: now.addingTimeInterval(2_400),
            now: now
        )

        let saved = await MainActor.run { coordinator.saveUsageManualReading(reading) }
        XCTAssertTrue(saved)
        let subscriptionID = try UsageConnectionID("catalog.gemini_subscription")
        let windowID = try UsageWindowID("catalog.gemini_subscription.five_hour")
        let selection = UsageRegistrySelection(connectionID: subscriptionID, windowID: windowID)
        let visible = await MainActor.run {
            (
                coordinator.manualReadings,
                coordinator.registryPresentation.connection(id: subscriptionID),
                coordinator.registryPresentation.observation(for: selection)?.value
            )
        }
        XCTAssertEqual(visible.0, [reading])
        XCTAssertEqual(visible.1?.availability, .available)
        XCTAssertEqual(visible.2, .percentage(42))

        let replacement = try UsageManualReading(
            providerID: try UsageProviderID(UsageManualReading.supportedProviderID),
            adapterID: UsageManualReading.supportedAdapterID,
            window: .fiveHour,
            usedPercent: 80,
            observedAt: now.addingTimeInterval(-30),
            resetAt: now.addingTimeInterval(2_400),
            now: now
        )
        store.saveError = .saveFailed
        let failed = await MainActor.run { coordinator.saveUsageManualReading(replacement) }
        XCTAssertFalse(failed)
        let afterFailure = await MainActor.run {
            (
                coordinator.manualReadings,
                coordinator.registryPresentation.observation(for: selection)?.value,
                coordinator.manualReadingErrorMessage
            )
        }
        XCTAssertEqual(afterFailure.0, [reading])
        XCTAssertEqual(afterFailure.1, .percentage(42))
        XCTAssertNotNil(afterFailure.2)

        store.saveError = nil
        let deleted = await MainActor.run { coordinator.deleteUsageManualReadings() }
        XCTAssertTrue(deleted)
        let afterDelete = await MainActor.run {
            (
                coordinator.manualReadings,
                coordinator.registryPresentation.connection(id: subscriptionID)?.availability,
                coordinator.registryPresentation.windows(for: subscriptionID)
            )
        }
        XCTAssertTrue(afterDelete.0.isEmpty)
        XCTAssertEqual(afterDelete.1, .unsupported)
        XCTAssertTrue(afterDelete.2.isEmpty)
    }

    func testManualReadingLoadFailureIsExposedForRecovery() async {
        let store = InMemoryUsageManualReadingStore()
        store.loadError = .invalidEnvelope
        let coordinator = await MainActor.run {
            UsageCoordinator(
                fetch: { CoordinatorUsageFixtures.emptyPayload(now: .now) },
                historyPersistence: RegistryHistoryStore(),
                manualReadingStore: store
            )
        }

        let errorMessage = await MainActor.run { coordinator.manualReadingErrorMessage }
        XCTAssertEqual(errorMessage, "Manual usage readings unavailable")
    }

    func testManualReadingBatchReplacementFailurePreservesStoredAndVisibleReadings() async throws {
        let now = Date(timeIntervalSinceReferenceDate: 800_000_000)
        let store = InMemoryUsageManualReadingStore()
        let coordinator = await MainActor.run {
            UsageCoordinator(
                fetch: { CoordinatorUsageFixtures.emptyPayload(now: now) },
                initialUpdatedAt: now,
                historyPersistence: RegistryHistoryStore(),
                manualReadingStore: store,
                clock: { now }
            )
        }
        let providerID = try UsageProviderID(UsageManualReading.supportedProviderID)
        let first = try UsageManualReading(
            providerID: providerID,
            adapterID: UsageManualReading.supportedAdapterID,
            window: .fiveHour,
            usedPercent: 24,
            observedAt: now.addingTimeInterval(-60),
            resetAt: now.addingTimeInterval(2_400),
            now: now
        )
        let second = try UsageManualReading(
            providerID: providerID,
            adapterID: UsageManualReading.supportedAdapterID,
            window: .weekly,
            usedPercent: 41,
            observedAt: now.addingTimeInterval(-90),
            resetAt: now.addingTimeInterval(7_200),
            now: now
        )

        let initialSave = await MainActor.run {
            coordinator.saveUsageManualReadings([first, second])
        }
        XCTAssertTrue(initialSave)

        let firstSelection = UsageRegistrySelection(
            connectionID: try UsageConnectionID("catalog.gemini_subscription"),
            windowID: try UsageWindowID("catalog.gemini_subscription.five_hour")
        )
        let secondSelection = UsageRegistrySelection(
            connectionID: try UsageConnectionID("catalog.gemini_subscription"),
            windowID: try UsageWindowID("catalog.gemini_subscription.weekly")
        )
        let replacementFirst = try UsageManualReading(
            providerID: providerID,
            adapterID: UsageManualReading.supportedAdapterID,
            window: .fiveHour,
            usedPercent: 82,
            observedAt: now.addingTimeInterval(-30),
            resetAt: now.addingTimeInterval(2_400),
            now: now
        )
        let replacementSecond = try UsageManualReading(
            providerID: providerID,
            adapterID: UsageManualReading.supportedAdapterID,
            window: .weekly,
            usedPercent: 73,
            observedAt: now.addingTimeInterval(-45),
            resetAt: now.addingTimeInterval(7_200),
            now: now
        )
        store.saveError = .saveFailed
        let failedReplacement = await MainActor.run {
            coordinator.saveUsageManualReadings([replacementFirst, replacementSecond])
        }
        let afterFailure = await MainActor.run {
            (
                coordinator.manualReadings,
                coordinator.registryPresentation.observation(for: firstSelection)?.value,
                coordinator.registryPresentation.observation(for: secondSelection)?.value,
                coordinator.manualReadingErrorMessage
            )
        }

        XCTAssertFalse(failedReplacement)
        XCTAssertEqual(store.readings, [first, second])
        XCTAssertEqual(afterFailure.0, [first, second])
        XCTAssertEqual(afterFailure.1, .percentage(24))
        XCTAssertEqual(afterFailure.2, .percentage(41))
        XCTAssertNotNil(afterFailure.3)
    }

    func testManualReadingSaveUsesTheCurrentInjectedClock() async throws {
        let initialTime = Date(timeIntervalSinceReferenceDate: 800_000_000)
        let clock = MutableUsageClock(initialTime)
        let store = InMemoryUsageManualReadingStore()
        let coordinator = await MainActor.run {
            UsageCoordinator(
                fetch: { CoordinatorUsageFixtures.emptyPayload(now: initialTime) },
                initialUpdatedAt: initialTime,
                historyPersistence: RegistryHistoryStore(),
                manualReadingStore: store,
                clock: { clock.value }
            )
        }
        let observedAt = initialTime.addingTimeInterval(30)
        let reading = try UsageManualReading(
            providerID: try UsageProviderID(UsageManualReading.supportedProviderID),
            adapterID: UsageManualReading.supportedAdapterID,
            window: .fiveHour,
            usedPercent: 36,
            observedAt: observedAt,
            resetAt: observedAt.addingTimeInterval(2_400),
            now: observedAt
        )

        let beforeClockAdvance = await MainActor.run {
            coordinator.saveUsageManualReadings([reading])
        }
        XCTAssertTrue(store.readings.isEmpty)
        clock.value = observedAt
        let afterClockAdvance = await MainActor.run {
            coordinator.saveUsageManualReadings([reading])
        }

        XCTAssertFalse(beforeClockAdvance)
        XCTAssertTrue(afterClockAdvance)
        XCTAssertEqual(store.readings, [reading])
    }
}

private final class MutableUsageClock: @unchecked Sendable {
    var value: Date

    init(_ value: Date) {
        self.value = value
    }
}

private enum CoordinatorUsageFixtures {
    static func connectors(
        codex: ConnectorState,
        claude: ConnectorState = .unavailable,
        glm: ConnectorState = .unavailable,
        deepseek: ConnectorState = .unavailable,
        googleAIStudio: ConnectorState = .unavailable
    ) -> [String: ConnectorState] {
        [
            "codex": codex,
            "claude": claude,
            "glm": glm,
            "deepseek": deepseek,
            "google_ai_studio": googleAIStudio
        ]
    }

    static func observedSnapshot(
        provider: Provider,
        observedAt: Date,
        usedPercent: Double
    ) -> ProviderSnapshot {
        let provenance = Provenance(
            source: "coordinator-test-source",
            observedAt: observedAt,
            quality: .observed,
            connector: .healthy
        )
        return ProviderSnapshot(
            provider: provider,
            accountLabel: provider.displayName,
            windows: [
                UsageWindow(
                    id: "five_hour",
                    label: "5-hour",
                    limit: 1,
                    used: usedPercent / 100,
                    resetAt: observedAt.addingTimeInterval(3_600),
                    durationMinutes: 300,
                    provenance: provenance
                )
            ],
            provenance: provenance
        )
    }

    static func observedPayload(
        now: Date,
        source: String = "coordinator-test-source"
    ) -> APIUsagePayload {
        let provenance = APIUsageProvenance(
            source: source,
            observedAt: now,
            freshness: "fresh",
            official: true,
            quality: "observed",
            connectorState: .healthy
        )
        return APIUsagePayload(
            generatedAt: now,
            windows: [
                APIUsageWindow(
                    provider: .codex,
                    window: "five_hour",
                    durationMinutes: 300,
                    usedPercent: 42,
                    resetAt: now.addingTimeInterval(3_600),
                    availability: "observed",
                    provenance: provenance
                )
            ],
            estimates: [],
            connectors: connectors(codex: .healthy)
        )
    }

    static func emptyPayload(now: Date) -> APIUsagePayload {
        APIUsagePayload(
            generatedAt: now,
            windows: [],
            estimates: [],
            connectors: connectors(codex: .unavailable)
        )
    }
}

private final class RegistryHistoryStore: UsageHistoryPersistence {
    private(set) var data: Data?

    func load() throws -> Data? { data }
    func save(_ data: Data) throws { self.data = data }
}

private actor RegistryPayloadSequence {
    enum Step: Sendable {
        case payload(APIUsagePayload)
        case failure
    }

    private var steps: [Step]

    init(steps: [Step]) {
        self.steps = steps
    }

    func next() throws -> APIUsagePayload {
        guard !steps.isEmpty else { throw RegistryCoordinatorTestError.exhausted }
        switch steps.removeFirst() {
        case .payload(let payload): return payload
        case .failure: throw RegistryCoordinatorTestError.transport
        }
    }
}

private actor RegistryFetchGate {
    private var started = false
    private var released = false
    private var continuations: [CheckedContinuation<Void, Never>] = []

    func wait() async {
        started = true
        if released { return }
        await withCheckedContinuation { continuations.append($0) }
    }

    func hasStarted() -> Bool { started }

    func release() {
        released = true
        let pending = continuations
        continuations.removeAll()
        pending.forEach { $0.resume() }
    }
}

private enum RegistryCoordinatorTestError: Error, Sendable {
    case exhausted
    case transport
}
