import XCTest
@testable import LifeOS

final class UsageIngestionTests: XCTestCase {
    private let observedAt = Date.now

    private static func connectors(
        codex: ConnectorState,
        claude: ConnectorState,
        glm: ConnectorState = .unavailable,
        deepseek: ConnectorState = .unavailable,
        googleAIStudio: ConnectorState = .unavailable
    ) -> [String: ConnectorState] {
        [
            "codex": codex,
            "claude": claude,
            "glm": glm,
            "deepseek": deepseek,
            "google_ai_studio": googleAIStudio,
        ]
    }

    private func provenance(
        quality: String = "observed",
        official: Bool = true,
        connector: ConnectorState = .healthy,
        freshness: String = "fresh"
    ) -> APIUsageProvenance {
        APIUsageProvenance(source: "codex-local-api", observedAt: observedAt, freshness: freshness,
                           official: official, quality: quality, connectorState: connector)
    }

    private func window(
        provider: Provider = .codex,
        kind: String,
        minutes: Int,
        used: Double? = 42,
        resetAt: Date? = nil,
        availability: String = "observed",
        provenance: APIUsageProvenance? = nil
    ) -> APIUsageWindow {
        APIUsageWindow(provider: provider, window: kind, durationMinutes: minutes, usedPercent: used,
                       resetAt: resetAt, availability: availability, provenance: provenance ?? self.provenance())
    }

    func testObservedCodexWindowsPreserveFiveHourAndSevenDayUnits() throws {
        let payload = APIUsagePayload(generatedAt: observedAt,
            windows: [window(kind: "five_hour", minutes: 300), window(kind: "seven_day", minutes: 10_080)],
            estimates: [], connectors: Self.connectors(codex: .healthy, claude: .unavailable))
        let snapshot = try XCTUnwrap(UsageIngestion.map(payload).providers.first)
        XCTAssertEqual(snapshot.windows.map(\.durationMinutes), [300, 10_080])
        XCTAssertEqual(snapshot.windows.map(\.usedPercent), [0.42, 0.42])
    }

    func testMissingUsedPercentAndResetRemainUnavailable() throws {
        let payload = APIUsagePayload(generatedAt: observedAt,
            windows: [window(kind: "five_hour", minutes: 300, used: nil, availability: "unavailable",
                             provenance: provenance(quality: "unavailable", official: false, connector: .unavailable, freshness: "unknown"))],
            estimates: [], connectors: Self.connectors(codex: .unavailable, claude: .unavailable))
        let mapped = try XCTUnwrap(try XCTUnwrap(UsageIngestion.map(payload).providers.first).windows.first)
        XCTAssertNil(mapped.usedPercent)
        XCTAssertNil(mapped.resetAt)
        XCTAssertNil(mapped.projection)
    }

    func testDuplicateProviderWindowRecordsFailClosed() {
        let duplicate = window(kind: "five_hour", minutes: 300)
        let payload = APIUsagePayload(generatedAt: observedAt, windows: [duplicate, duplicate],
                                      estimates: [], connectors: Self.connectors(codex: .healthy, claude: .unavailable))
        XCTAssertThrowsError(try UsageIngestion.map(payload))
    }

    func testUnavailableWindowRejectsHealthyOrRefreshDueProvenance() {
        for connector in [ConnectorState.healthy, .refreshDue] {
            let payload = APIUsagePayload(generatedAt: observedAt,
                windows: [window(kind: "five_hour", minutes: 300, used: nil, availability: "unavailable",
                                 provenance: provenance(quality: "unavailable", official: false, connector: connector, freshness: "unknown"))],
                estimates: [], connectors: Self.connectors(codex: connector, claude: .unavailable))
            XCTAssertThrowsError(try UsageIngestion.map(payload))
        }
    }

    func testObservedProvenanceDiffersFromEstimateAndEstimateMatchesOnlyItsWindow() throws {
        let reset = observedAt.addingTimeInterval(3600)
        let payload = APIUsagePayload(generatedAt: observedAt,
            windows: [window(kind: "five_hour", minutes: 300, resetAt: reset), window(kind: "seven_day", minutes: 10_080)],
            estimates: [APIUsageEstimate(provider: .codex, window: "five_hour", projectedPercentAtReset: 78,
                estimatedExhaustionAt: nil, velocityPercentPerHour: 4, confidence: "high", sampleSpanHours: 12,
                explanation: "Observed activity", official: false)], connectors: Self.connectors(codex: .healthy, claude: .unavailable))
        let snapshot = try XCTUnwrap(UsageIngestion.map(payload).providers.first)
        XCTAssertEqual(snapshot.provenance.quality, .observed)
        XCTAssertEqual(snapshot.windows.first?.projection?.percentAtReset, 0.78)
        XCTAssertNil(snapshot.windows.last?.projection)
    }

    func testConnectorStatesAndStaleTimestampArePreserved() throws {
        let staleObservedAt = observedAt.addingTimeInterval(-3600)
        let staleProvenance = APIUsageProvenance(source: "cached-codex", observedAt: staleObservedAt,
            freshness: "stale", official: true, quality: "observed", connectorState: .refreshDue)
        let payload = APIUsagePayload(generatedAt: observedAt,
            windows: [window(kind: "five_hour", minutes: 300, provenance: staleProvenance)],
            estimates: [], connectors: Self.connectors(codex: .reauthRequired, claude: .unavailable))
        let result = try UsageIngestion.map(payload)
        XCTAssertEqual(result.providers.first?.provenance.connector, ConnectorState.reauthRequired)
        XCTAssertEqual(result.connectorStates[Provider.codex], ConnectorState.reauthRequired)
        XCTAssertEqual(result.providers.first?.provenance.freshness(now: observedAt.addingTimeInterval(7200)), Freshness.unavailable)
    }

    func testAnalyticsAreAbsentWhenContractHasNoAnalytics() throws {
        let payload = APIUsagePayload(generatedAt: observedAt, windows: [window(kind: "five_hour", minutes: 300)], estimates: [], connectors: Self.connectors(codex: .healthy, claude: .unavailable))
        XCTAssertTrue(try UsageIngestion.map(payload).analytics.isEmpty)
    }

    func testConnectorOnlyProviderRemainsVisibleButUnavailable() throws {
        let payload = APIUsagePayload(generatedAt: observedAt, windows: [], estimates: [],
                                      connectors: Self.connectors(codex: .unavailable, claude: .reauthRequired))
        let result = try UsageIngestion.map(payload)
        let claude = try XCTUnwrap(result.providers.first { $0.provider == .claude })
        XCTAssertTrue(claude.windows.isEmpty)
        XCTAssertEqual(claude.provenance.quality, .unavailable)
        XCTAssertEqual(claude.provenance.connector, .reauthRequired)
        XCTAssertEqual(result.connectorStates[.claude], .reauthRequired)
        XCTAssertEqual(result.providers.map(\.provider), Provider.allCases)
        for provider in [.glm, .deepseek, .googleAIStudio] as [Provider] {
            let snapshot = try XCTUnwrap(result.providers.first { $0.provider == provider })
            XCTAssertTrue(snapshot.windows.isEmpty)
            XCTAssertEqual(snapshot.provenance.quality, .unavailable)
            XCTAssertEqual(snapshot.provenance.connector, .unavailable)
        }
    }

    func testEachWindowRetainsItsOwnProvenance() throws {
        let fiveHourSource = APIUsageProvenance(source: "live-five-hour", observedAt: observedAt,
            freshness: "fresh", official: true, quality: "observed", connectorState: .healthy)
        let sevenDaySource = APIUsageProvenance(source: "cached-seven-day", observedAt: observedAt.addingTimeInterval(-60),
            freshness: "fresh", official: true, quality: "observed", connectorState: .healthy)
        let payload = APIUsagePayload(generatedAt: observedAt, windows: [
            window(kind: "five_hour", minutes: 300, provenance: fiveHourSource),
            window(kind: "seven_day", minutes: 10_080, provenance: sevenDaySource)
        ], estimates: [], connectors: Self.connectors(codex: .healthy, claude: .unavailable))
        let snapshot = try XCTUnwrap(UsageIngestion.map(payload).providers.first)
        XCTAssertEqual(snapshot.windows[0].provenance?.source, "live-five-hour")
        XCTAssertEqual(snapshot.windows[1].provenance?.source, "cached-seven-day")
        XCTAssertEqual(snapshot.provenance.source, "Multiple provider observations")
    }

    func testCoordinatorRetainsConnectorStateAndDoesNotCallUnavailableObserved() async throws {
        let payload = APIUsagePayload(generatedAt: Date.now, windows: [], estimates: [],
                                      connectors: Self.connectors(codex: .unavailable, claude: .reauthRequired))
        let coordinator = await MainActor.run { UsageCoordinator(fetch: { payload }) }
        await coordinator.refresh()
        let result = await MainActor.run { (coordinator.state, coordinator.connectorStates[.claude]) }
        XCTAssertEqual(result.0, .unavailable)
        XCTAssertEqual(result.1, .reauthRequired)
    }

    func testCurrentConnectorFailureMakesCachedObservationStale() async throws {
        let source = APIUsageProvenance(source: "cached-codex", observedAt: Date.now,
            freshness: "fresh", official: true, quality: "observed", connectorState: .healthy)
        let payload = APIUsagePayload(generatedAt: Date.now,
            windows: [window(kind: "five_hour", minutes: 300, provenance: source)],
            estimates: [], connectors: Self.connectors(codex: .unavailable, claude: .unavailable))
        let coordinator = await MainActor.run { UsageCoordinator(fetch: { payload }) }
        await coordinator.refresh()
        let result = await MainActor.run { (coordinator.state, coordinator.providers.first?.provenance.connector) }
        XCTAssertEqual(result.0, .stale)
        XCTAssertEqual(result.1, .unavailable)
    }

    func testCoordinatorCancelsAndAwaitsPreviousRefreshBeforeStartingAnother() async throws {
        let lock = RefreshLock()
        let coordinator = await MainActor.run {
            UsageCoordinator(fetch: {
                await lock.enter()
                do {
                    try await Task.sleep(nanoseconds: 100_000_000)
                } catch {
                    await lock.leave()
                    throw error
                }
                await lock.leave()
                let now = Date.now
                let source = APIUsageProvenance(source: "test", observedAt: now, freshness: "fresh", official: true, quality: "observed", connectorState: .healthy)
                let usage = APIUsageWindow(provider: .codex, window: "five_hour", durationMinutes: 300, usedPercent: 20, resetAt: nil, availability: "observed", provenance: source)
                return APIUsagePayload(generatedAt: now, windows: [usage], estimates: [], connectors: Self.connectors(codex: .healthy, claude: .unavailable))
            })
        }
        let first = Task { await coordinator.refresh() }
        while await lock.activeCount == 0 { await Task.yield() }
        let second = Task { await coordinator.refresh() }
        await first.value
        await second.value
        let state = await MainActor.run { coordinator.state }
        let maximum = await lock.maximum
        let active = await lock.activeCount
        XCTAssertEqual(state, UsageLoadState.observed)
        XCTAssertEqual(maximum, 1)
        XCTAssertEqual(active, 0)
    }

    func testCachedSnapshotRetainsItsTimestampAndStartsStale() async throws {
        let payload = APIUsagePayload(generatedAt: observedAt,
            windows: [window(kind: "five_hour", minutes: 300)], estimates: [], connectors: Self.connectors(codex: .healthy, claude: .unavailable))
        let providers = try UsageIngestion.map(payload).providers
        let cachedAt = Date.now.addingTimeInterval(-7200)
        let coordinator = await MainActor.run {
            UsageCoordinator(fetch: { payload }, staleAfter: 3600,
                             initialProviders: providers, initialUpdatedAt: cachedAt)
        }
        let result = await MainActor.run { (coordinator.state, coordinator.lastUpdated) }
        XCTAssertEqual(result.0, .stale)
        XCTAssertEqual(result.1, cachedAt)
    }

    func testInvalidBaseURLFailsClosed() async {
        let defaults = UserDefaults(suiteName: "UsageIngestionTests.invalid-url")!
        defaults.removePersistentDomain(forName: "UsageIngestionTests.invalid-url")
        defaults.set("http://example.invalid", forKey: TailscaleSyncClient.serverURLDefaultsKey)
        let client = TailscaleSyncClient(defaults: defaults)
        do {
            _ = try await client.fetchUsage()
            XCTFail("invalid non-HTTPS URL must fail closed")
        } catch let error as TailscaleSyncError {
            XCTAssertEqual(error, TailscaleSyncError.invalidServerURL)
        } catch { XCTFail("unexpected error: \(error)") }
    }

    func testUnapprovedHostFailsClosedBeforeNetworkRequest() async {
        let defaults = UserDefaults(suiteName: "UsageIngestionTests.unapproved-host")!
        defaults.removePersistentDomain(forName: "UsageIngestionTests.unapproved-host")
        defaults.set("https://unapproved.example-tailnet.ts.net", forKey: TailscaleSyncClient.serverURLDefaultsKey)
        let client = TailscaleSyncClient(defaults: defaults)
        do {
            _ = try await client.fetchUsage()
            XCTFail("unapproved host must fail closed")
        } catch let error as TailscaleSyncError {
            XCTAssertEqual(error, .invalidServerURL)
        } catch { XCTFail("unexpected error: \(error)") }
    }

    func testServerURLRejectsUnexpectedPortsAndPaths() {
        let approved: Set<String> = ["lifeos-server.example.ts.net"]
        XCTAssertNotNil(TailscaleSyncClient.validatedServerURL("https://lifeos-server.example.ts.net:8420", approvedHosts: approved))
        XCTAssertNil(TailscaleSyncClient.validatedServerURL("https://lifeos-server.example.ts.net:9443", approvedHosts: approved))
        XCTAssertNil(TailscaleSyncClient.validatedServerURL("https://lifeos-server.example.ts.net/private", approvedHosts: approved))
    }

    func testStrictUsageDecodeAcceptsBothISOVariantsAndRejectsUnknownFields() throws {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let observed = formatter.string(from: Date.now.addingTimeInterval(-60))
        let payload = """
        {"generatedAt":"\(observed)","windows":[{"provider":"codex","window":"five_hour","durationMinutes":300,"usedPercent":25,"availability":"observed","provenance":{"source":"codex-app-server","observedAt":"\(observed)","freshness":"fresh","official":true,"quality":"observed","connectorState":"healthy"}}],"estimates":[],"connectors":{"codex":"healthy","claude":"unavailable","glm":"unavailable","deepseek":"unavailable","google_ai_studio":"unavailable"}}
        """
        XCTAssertNoThrow(try APIUsagePayload.decode(Data(payload.utf8)))
        let unknown = payload.replacingOccurrences(of: "\"generatedAt\":", with: "\"unexpected\":true,\"generatedAt\":")
        XCTAssertThrowsError(try APIUsagePayload.decode(Data(unknown.utf8)))

        let standard = observed.replacingOccurrences(of: #"\.\d+Z$"#, with: "Z", options: .regularExpression)
        XCTAssertNoThrow(try APIUsagePayload.decode(Data(payload.replacingOccurrences(of: observed, with: standard).utf8)))
    }

    func testUsageRejectsIncompleteConnectorsFutureObservationsAndConnectorContradictions() {
        let missing = APIUsagePayload(generatedAt: observedAt, windows: [], estimates: [], connectors: ["codex": .healthy])
        XCTAssertThrowsError(try UsageIngestion.map(missing))

        let future = observedAt.addingTimeInterval(60)
        let futureProvenance = APIUsageProvenance(source: "codex-app-server", observedAt: future,
            freshness: "fresh", official: true, quality: "observed", connectorState: .healthy)
        let futurePayload = APIUsagePayload(generatedAt: observedAt,
            windows: [window(kind: "five_hour", minutes: 300, provenance: futureProvenance)], estimates: [],
            connectors: Self.connectors(codex: .healthy, claude: .unavailable))
        XCTAssertThrowsError(try UsageIngestion.map(futurePayload, now: observedAt))

        let unavailableConnector = provenance(connector: .unavailable)
        let contradictory = APIUsagePayload(generatedAt: observedAt,
            windows: [window(kind: "five_hour", minutes: 300, provenance: unavailableConnector)], estimates: [],
            connectors: Self.connectors(codex: .unavailable, claude: .unavailable))
        XCTAssertThrowsError(try UsageIngestion.map(contradictory, now: observedAt))
        XCTAssertEqual(Provenance(source: "future", observedAt: future, quality: .observed, connector: .healthy)
            .freshness(now: observedAt), .unavailable)
    }

    func testClockSkewBoundAppliesToObservedAndUnavailableWindows() throws {
        let withinSkew = observedAt.addingTimeInterval(2)
        let observedSource = APIUsageProvenance(source: "codex-app-server", observedAt: withinSkew,
            freshness: "fresh", official: true, quality: "observed", connectorState: .healthy)
        let observedPayload = APIUsagePayload(generatedAt: observedAt,
            windows: [window(kind: "five_hour", minutes: 300, provenance: observedSource)], estimates: [],
            connectors: Self.connectors(codex: .healthy, claude: .unavailable))
        XCTAssertNoThrow(try UsageIngestion.map(observedPayload, now: observedAt))

        let unavailableSource = APIUsageProvenance(source: "no-observation", observedAt: withinSkew,
            freshness: "unknown", official: false, quality: "unavailable", connectorState: .unavailable)
        let unavailablePayload = APIUsagePayload(generatedAt: observedAt,
            windows: [window(kind: "five_hour", minutes: 300, used: nil, availability: "unavailable",
                            provenance: unavailableSource)], estimates: [],
            connectors: Self.connectors(codex: .unavailable, claude: .unavailable))
        XCTAssertNoThrow(try UsageIngestion.map(unavailablePayload, now: observedAt))

        let futureSource = APIUsageProvenance(source: "no-observation", observedAt: observedAt.addingTimeInterval(60),
            freshness: "unknown", official: false, quality: "unavailable", connectorState: .unavailable)
        let futurePayload = APIUsagePayload(generatedAt: observedAt,
            windows: [window(kind: "five_hour", minutes: 300, used: nil, availability: "unavailable",
                            provenance: futureSource)], estimates: [],
            connectors: Self.connectors(codex: .unavailable, claude: .unavailable))
        XCTAssertThrowsError(try UsageIngestion.map(futurePayload, now: observedAt))
    }

    func testUnavailableWindowRejectsConnectorStatesOutsideSharedContract() {
        for connector in [ConnectorState.disabled, .error] {
            let source = APIUsageProvenance(source: "no-observation", observedAt: observedAt,
                freshness: "unknown", official: false, quality: "unavailable", connectorState: connector)
            let payload = APIUsagePayload(generatedAt: observedAt,
                windows: [window(kind: "five_hour", minutes: 300, used: nil, availability: "unavailable",
                                provenance: source)], estimates: [],
                connectors: Self.connectors(codex: .unavailable, claude: .unavailable))
            XCTAssertThrowsError(try UsageIngestion.map(payload, now: observedAt))
        }
    }

    func testEveryEstimateIsValidatedEvenWithoutMatchingWindow() {
        let invalid = [
            APIUsageEstimate(provider: .codex, window: "unsupported", projectedPercentAtReset: 50,
                estimatedExhaustionAt: nil, velocityPercentPerHour: 1, confidence: "medium",
                sampleSpanHours: 1, explanation: "orphan", official: false),
            APIUsageEstimate(provider: .codex, window: "seven_day", projectedPercentAtReset: 50,
                estimatedExhaustionAt: nil, velocityPercentPerHour: 1, confidence: "medium",
                sampleSpanHours: 1, explanation: "official", official: true),
        ]
        for estimate in invalid {
            let payload = APIUsagePayload(generatedAt: observedAt, windows: [], estimates: [estimate],
                connectors: Self.connectors(codex: .unavailable, claude: .unavailable))
            XCTAssertThrowsError(try UsageIngestion.map(payload, now: observedAt))
        }
    }

    func testCoordinatorDefaultUsesSharedFifteenMinuteFreshnessThreshold() async {
        let now = Date.now
        let old = now.addingTimeInterval(-20 * 60)
        let provenance = Provenance(source: "codex-app-server", observedAt: old,
                                    quality: .observed, connector: .healthy)
        let usage = UsageWindow(id: "five_hour", label: "5-hour", limit: 1, used: 0.25,
                                durationMinutes: 300, provenance: provenance)
        let provider = ProviderSnapshot(provider: .codex, accountLabel: "Codex",
                                        windows: [usage], provenance: provenance)
        let coordinator = await MainActor.run {
            UsageCoordinator(fetch: { throw URLError(.notConnectedToInternet) },
                             initialProviders: [provider], initialUpdatedAt: now)
        }
        let state = await MainActor.run { coordinator.state }
        XCTAssertEqual(state, .stale)
    }

    func testNativeFreshnessUsesTheSharedFifteenMinuteThreshold() {
        let twentyMinutesOld = observedAt.addingTimeInterval(-20 * 60)
        let provenance = Provenance(source: "codex-app-server", observedAt: twentyMinutesOld,
                                    quality: .observed, connector: .refreshDue)
        XCTAssertEqual(provenance.freshness(now: observedAt), .stale)
    }

    func testSettingsProviderMappingKeepsObservedPartialStaleAndUnavailableDistinct() {
        let now = Date.now
        let observedProvenance = Provenance(
            source: "https://evil.example/provider?bearer=must-not-render",
            observedAt: now.addingTimeInterval(-30),
            quality: .observed,
            connector: .healthy
        )
        let unavailableWindowProvenance = Provenance(
            source: "claude-no-observation",
            observedAt: now,
            quality: .unavailable,
            connector: .unavailable
        )
        let observed = ProviderSnapshot(
            provider: .codex,
            accountLabel: "Codex",
            windows: [
                UsageWindow(
                    id: "five_hour",
                    label: "5-hour",
                    limit: 1,
                    used: 0.2,
                    durationMinutes: 300,
                    provenance: observedProvenance
                )
            ],
            provenance: observedProvenance
        )
        let partialProvenance = Provenance(
            source: "raw-error-body: https://evil.example/claude?token=must-not-render",
            observedAt: now.addingTimeInterval(-30),
            quality: .observed,
            connector: .healthy
        )
        let partial = ProviderSnapshot(
            provider: .claude,
            accountLabel: "Claude",
            windows: [
                UsageWindow(
                    id: "five_hour",
                    label: "5-hour",
                    limit: 1,
                    used: 0.3,
                    durationMinutes: 300,
                    provenance: partialProvenance
                ),
                UsageWindow(
                    id: "seven_day",
                    label: "7-day",
                    durationMinutes: 10_080,
                    provenance: unavailableWindowProvenance
                )
            ],
            provenance: partialProvenance
        )
        let staleProvenance = Provenance(
            source: "secret-source://glm-cache",
            observedAt: now.addingTimeInterval(-20 * 60),
            quality: .observed,
            connector: .refreshDue
        )
        let stale = ProviderSnapshot(
            provider: .glm,
            accountLabel: "GLM",
            windows: [
                UsageWindow(
                    id: "five_hour",
                    label: "5-hour",
                    limit: 1,
                    used: 0.4,
                    durationMinutes: 300,
                    provenance: staleProvenance
                )
            ],
            provenance: staleProvenance
        )
        let settings = UsageSettingsSnapshot(
            state: .observed,
            providerSnapshots: [observed, partial, stale],
            connectorStates: [
                .codex: .healthy,
                .claude: .healthy,
                .glm: .refreshDue,
                .deepseek: .reauthRequired
            ],
            lastUpdated: now,
            errorMessage: nil,
            now: now
        )

        XCTAssertEqual(settings.providers.first { $0.provider == .codex }?.state, .observed)
        XCTAssertEqual(
            settings.providers.first { $0.provider == .codex }?.source,
            "Windows Hermes · Codex observation"
        )
        XCTAssertEqual(
            settings.providers.first { $0.provider == .claude }?.source,
            "Windows Hermes · Claude observation"
        )
        XCTAssertEqual(settings.providers.first { $0.provider == .claude }?.state, .partial)
        XCTAssertEqual(settings.providers.first { $0.provider == .glm }?.state, .stale)
        XCTAssertEqual(settings.providers.first { $0.provider == .deepseek }?.state, .unavailable)
        XCTAssertTrue(settings.providers.allSatisfy { !$0.source.contains("evil.example") })
        XCTAssertTrue(settings.providers.allSatisfy { !$0.source.contains("token") })
        XCTAssertEqual(settings.readiness, .stale)
    }

    func testSettingsReadinessNeverRendersHostAndSeparatesLocalGates() {
        let approvedHosts: Set<String> = ["lifeos-server.example.ts.net"]
        let ready = SyncSettingsReadiness.resolve(
            serverURL: "https://lifeos-server.example.ts.net",
            approvedHosts: approvedHosts
        )
        XCTAssertEqual(ready.urlState, .valid)
        XCTAssertTrue(ready.canAttemptConnection)
        XCTAssertEqual(ready.title, "Ready for Tailscale identity preflight")

        let invalidURL = SyncSettingsReadiness.resolve(
            serverURL: "https://private-secret.invalid/path?token=must-not-render",
            approvedHosts: approvedHosts
        )
        XCTAssertEqual(invalidURL.urlState, .invalid)
        XCTAssertFalse(invalidURL.canAttemptConnection)
        XCTAssertFalse(String(describing: invalidURL).contains("private-secret.invalid"))
        XCTAssertFalse(String(describing: invalidURL).contains("must-not-render"))

        let noSignedHost = SyncSettingsReadiness.resolve(
            serverURL: "",
            approvedHosts: []
        )
        XCTAssertEqual(noSignedHost.title, "Approved signed host missing")
    }

    func testSettingsPrivacyMappingDistinguishesAppGroupGates() {
        XCTAssertEqual(
            AppGroupSettingsSnapshot.resolve(
                rawIdentifier: "$(APP_GROUP_IDENTIFIER)",
                sharedContainerAvailable: false
            ).state,
            .placeholder
        )
        XCTAssertEqual(
            AppGroupSettingsSnapshot.resolve(
                rawIdentifier: "group.com.hermes.lifeos.team",
                sharedContainerAvailable: true
            ).state,
            .configured
        )
#if DEBUG
        XCTAssertEqual(
            AppGroupSettingsSnapshot.resolve(
                rawIdentifier: "group.com.hermes.lifeos.\(AppGroupConfiguration.releasePlaceholder)",
                sharedContainerAvailable: true
            ).state,
            .configured
        )
#else
        XCTAssertEqual(
            AppGroupSettingsSnapshot.resolve(
                rawIdentifier: "group.com.hermes.lifeos.\(AppGroupConfiguration.releasePlaceholder)",
                sharedContainerAvailable: true
            ).state,
            .unavailable
        )
#endif
        XCTAssertEqual(
            AppGroupSettingsSnapshot.resolve(
                rawIdentifier: nil,
                sharedContainerAvailable: false
            ).state,
            .unavailable
        )
    }

    func testSettingsFinanceMappingUsesSummaryProvenanceWithoutBankInference() throws {
        let now = Date.now
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let timestamp = formatter.string(from: now.addingTimeInterval(-30))
        let metric: [String: Any] = [
            "availability": "observed",
            "amountCents": 100_000,
            "provenance": [
                "source": "raw-error-body: https://evil.example/finance?token=must-not-render",
                "observedAt": timestamp,
                "freshness": "fresh",
                "quality": "observed",
                "connectorState": "healthy"
            ]
        ]
        let payload: [String: Any] = [
            "generatedAt": formatter.string(from: now),
            "currency": "EUR",
            "monthlyIncome": metric,
            "fixedCosts": metric,
            "discretionaryBuffer": metric,
            "spent": metric,
            "savingsGoal": metric,
            "saved": metric
        ]
        let summary = try FinanceSummary.decode(
            JSONSerialization.data(withJSONObject: payload),
            now: now
        )
        let settings = FinanceSettingsSnapshot(
            state: .observed,
            summary: summary,
            now: now
        )

        XCTAssertEqual(settings.readiness, .observed)
        XCTAssertEqual(settings.observedSources, ["Windows finance gateway observation"])
        XCTAssertNil(settings.transactionsAvailability)
        XCTAssertTrue(settings.transactionDetail.contains("does not expose"))
        XCTAssertFalse(settings.summaryDetail.contains("evil.example"))
        XCTAssertFalse(settings.summaryDetail.contains("must-not-render"))
    }
}

private actor RefreshLock {
    private var active = 0
    private(set) var maximum = 0
    var activeCount: Int { active }
    func enter() { active += 1; maximum = max(maximum, active) }
    func leave() { active -= 1 }
}
