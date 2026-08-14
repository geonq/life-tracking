import XCTest
@testable import LifeOS

final class DomainTests: XCTestCase {
    func testDecodesRepresentativeUsagePayloadWithOptionalFields() throws {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let now = Date.now
        let generatedAt = formatter.string(from: now.addingTimeInterval(-30))
        let observedAt = formatter.string(from: now.addingTimeInterval(-300))
        let resetAt = formatter.string(from: now.addingTimeInterval(3 * 3600))
        let exhaustionAt = formatter.string(from: now.addingTimeInterval(24 * 3600))
        let json = """
        {"generatedAt":"\(generatedAt)","windows":[
          {"provider":"codex","window":"five_hour","durationMinutes":300,"usedPercent":42,"resetAt":"\(resetAt)","availability":"observed","provenance":{"source":"codex-official","observedAt":"\(observedAt)","freshness":"fresh","official":true,"quality":"observed","connectorState":"healthy"}},
          {"provider":"claude","window":"five_hour","durationMinutes":300,"availability":"unavailable","provenance":{"source":"claude-connector","observedAt":"\(observedAt)","freshness":"unknown","official":false,"quality":"unavailable","connectorState":"unavailable"}}],
          "estimates":[{"provider":"codex","window":"seven_day","projectedPercentAtReset":41,"estimatedExhaustionAt":"\(exhaustionAt)","velocityPercentPerHour":1.5,"confidence":"medium","sampleSpanHours":24,"explanation":"Observed trend","official":false}],
          "connectors":{"codex":"healthy","claude":"unavailable","glm":"unavailable","deepseek":"unavailable","google_ai_studio":"unavailable"}}
        """.data(using: .utf8)!
        let payload = try APIUsagePayload.decode(json, now: now)
        XCTAssertEqual(payload.windows.first?.usedPercent, 42)
        XCTAssertNotNil(payload.windows.first?.resetAt)
        XCTAssertEqual(payload.windows[1].availability, "unavailable")
        XCTAssertEqual(payload.estimates.first?.projectedPercentAtReset, 41)
        XCTAssertEqual(payload.estimates.first?.confidence, "medium")
    }

    func testMissingWindowDoesNotInventPercentage() {
        XCTAssertNil(DemoDataProvider.claude.windows.first { $0.id == "5h" }?.usedPercent)
        XCTAssertNil(DemoDataProvider.glm.windows.first { $0.id == "5h" }?.usedPercent)
    }

    func testProvidersHaveSeparateCardsAndNoAggregateModel() {
        XCTAssertEqual(DemoDataProvider.providers.map(\.provider), Provider.allCases)
        XCTAssertNotEqual(DemoDataProvider.codex.provider, DemoDataProvider.claude.provider)
        XCTAssertTrue([DemoDataProvider.glm, DemoDataProvider.deepSeek, DemoDataProvider.googleAIStudio].allSatisfy {
            $0.windows.isEmpty && $0.provenance.quality == .unavailable && $0.provenance.connector == .unavailable
        })
    }

    func testProviderWireIdentitiesAndDisplayNamesAreStable() {
        XCTAssertEqual(Provider.allCases.map(\.rawValue), ["codex", "claude", "glm", "deepseek", "google_ai_studio"])
        XCTAssertEqual(Provider.allCases.map(\.displayName), ["Codex", "Claude", "GLM", "DeepSeek", "Google AI Studio"])
    }

    func testEstimatesAreOptionalAndNonOfficial() {
        XCTAssertEqual(DemoDataProvider.codex.windows.last?.projection?.confidence, 0.72)
        XCTAssertEqual(DemoDataProvider.codex.provenance.quality, .demo)
    }

    func testWidgetPrivacyAndBlockedSignals() {
        let snapshot = DemoDataProvider.widget()
        XCTAssertFalse(snapshot.codexStatus.localizedCaseInsensitiveContains("token"))
        XCTAssertFalse(snapshot.providers.contains { $0.accountLabel.localizedCaseInsensitiveContains("email") })
        XCTAssertTrue(snapshot.healthSignal.hasPrefix("Blocked"))
        XCTAssertTrue(snapshot.clipperSignal.hasPrefix("Blocked"))
        XCTAssertTrue(snapshot.financeSignal.hasPrefix("Blocked"))
    }

    func testUnavailableWidgetSnapshotFailsClosedWithoutSyntheticProviders() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let snapshot = WidgetSnapshot.unavailable(at: now)

        XCTAssertTrue(snapshot.providers.isEmpty)
        XCTAssertEqual(snapshot.updatedAt, now)
        XCTAssertEqual(snapshot.freshness, .unavailable)
        XCTAssertEqual(snapshot.provenance.quality, .unavailable)
        XCTAssertEqual(snapshot.provenance.connector, .unavailable)
        XCTAssertEqual(snapshot.warning, "Usage data unavailable")
    }

    func testDemoFixturesUseAStableReferenceDate() {
        XCTAssertEqual(DemoDataProvider.observedAt, Date(timeIntervalSince1970: 1_785_283_200))
        XCTAssertEqual(DemoUsageAnalytics.snapshots.first?.provenance.observedAt, DemoDataProvider.observedAt)
    }

    func testAppGroupStoreFailsClosedForPlaceholder() {
        XCTAssertNil(AppGroupConfiguration.validatedIdentifier("$(APP_GROUP_IDENTIFIER)"))
        XCTAssertNil(SharedSnapshotStore.url(appGroupIdentifier: "$(APP_GROUP_IDENTIFIER)"))
    }

    func testAppGroupStoreRejectsMalformedIdentifiersBeforeContainerLookup() {
        for value in [
            "group.",
            "group.com.example lifeos",
            "group.com.example/lifeos",
            "group.com..example",
            "group.com.example.$(APP_GROUP_IDENTIFIER)"
        ] {
            XCTAssertNil(AppGroupConfiguration.validatedIdentifier(value), value)
            XCTAssertThrowsError(try CalendarStoreURL.appGroupURL(identifier: value), value) { error in
                XCTAssertEqual(error as? CalendarStoreError, .invalidAppGroupIdentifier)
            }
        }
    }

    func testCalendarDeepLinkDistinguishesBrowseAndNewEvent() throws {
        XCTAssertEqual(LifeOSDeepLink(url: try XCTUnwrap(URL(string: "lifeos://calendar"))), .calendar)
        XCTAssertEqual(LifeOSDeepLink(url: try XCTUnwrap(URL(string: "lifeos://calendar/new"))), .newCalendarEvent)
        XCTAssertEqual(LifeOSDeepLink(url: try XCTUnwrap(URL(string: "lifeos://usage"))), .usage)
        XCTAssertNil(LifeOSDeepLink(url: try XCTUnwrap(URL(string: "https://calendar/new"))))
    }

    func testNutritionWidgetDeepLinksRemainDistinctAndRouteIntoAppFlows() throws {
        let routes: [(String, LifeOSDeepLink, FitnessNutritionEntryPoint)] = [
            ("lifeos://fitness/nutrition/import", .fitnessNutritionImport, .capture(.photoLibrary)),
            ("lifeos://fitness/nutrition/camera", .fitnessNutritionCamera, .capture(.camera)),
            ("lifeos://fitness/nutrition/barcode", .fitnessNutritionBarcode, .capture(.barcode)),
            ("lifeos://fitness/nutrition/ai-proposal", .fitnessNutritionAIProposal, .capture(.aiProposal)),
            ("lifeos://fitness/nutrition/search", .fitnessNutritionSearch, .capture(.search)),
            ("lifeos://fitness/nutrition/goals", .fitnessNutritionGoals, .goals),
            ("lifeos://fitness/net-energy", .fitnessNetEnergy, .netEnergy)
        ]
        for (rawURL, expectedRoute, expectedEntryPoint) in routes {
            let route = try XCTUnwrap(LifeOSDeepLink(url: URL(string: rawURL)!))
            XCTAssertEqual(route, expectedRoute, rawURL)
            XCTAssertEqual(route.module, .fitness)
            XCTAssertEqual(route.nutritionEntryPoint, expectedEntryPoint)
        }
        XCTAssertNil(LifeOSDeepLink(url: URL(string: "https://fitness/nutrition/camera")!))
    }

    func testFitnessWidgetDeepLinksRemainDistinctAndRouteIntoAppFlows() throws {
        let routes: [(String, LifeOSDeepLink, FitnessWidgetEntryPoint)] = [
            ("lifeos://fitness/daily-overview", .fitnessDailyOverview, .dailyOverview),
            ("lifeos://fitness/strain", .fitnessStrain, .strain),
            ("lifeos://fitness/recovery", .fitnessRecovery, .recovery),
            ("lifeos://fitness/sleep", .fitnessSleep, .sleep),
            ("lifeos://fitness/health", .fitnessHealthMonitor, .healthMonitor),
            ("lifeos://fitness/health/respiration", .fitnessRespiration, .healthMetric(.respiration)),
            ("lifeos://fitness/health/heart-rate", .fitnessHeartRate, .healthMetric(.heartRate)),
            ("lifeos://fitness/health/hrv", .fitnessHRV, .healthMetric(.hrv)),
            ("lifeos://fitness/health/spo2", .fitnessSpO2, .healthMetric(.spo2)),
            ("lifeos://fitness/health/temperature", .fitnessTemperature, .healthMetric(.temperature)),
            ("lifeos://fitness/health/sleep-duration", .fitnessSleepDuration, .healthMetric(.sleepDuration)),
            ("lifeos://fitness/stress", .fitnessStress, .stress),
            ("lifeos://fitness/energy-reserve", .fitnessEnergyReserve, .energyReserve)
        ]
        for (rawURL, expectedRoute, expectedEntryPoint) in routes {
            let route = try XCTUnwrap(LifeOSDeepLink(url: URL(string: rawURL)!))
            XCTAssertEqual(route, expectedRoute, rawURL)
            XCTAssertEqual(route.module, .fitness)
            XCTAssertEqual(route.fitnessEntryPoint, expectedEntryPoint)
        }
        XCTAssertTrue(FitnessHealthMetric.heartRate.matches(metricTitle: "Resting heart rate"))
        XCTAssertTrue(FitnessHealthMetric.spo2.matches(metricTitle: "Blood oxygen"))
        XCTAssertTrue(FitnessHealthMetric.sleepDuration.matches(metricTitle: "Sleep"))
        let demo = WidgetSafeFitnessWidgetsSummary.demo(at: Date(timeIntervalSinceNow: -60))
        XCTAssertTrue(demo.isDemoFixture)
        let liveMetric = WidgetFitnessMetric(
            value: 72,
            unit: .beatsPerMinute,
            state: .fresh,
            observedAt: Date(timeIntervalSinceNow: -60),
            sourceLabel: "Validated source"
        )
        XCTAssertFalse(WidgetSafeFitnessWidgetsSummary(
            connector: .connected,
            consent: .granted,
            heartRate: liveMetric
        ).isDemoFixture)
    }

    func testStressDetailScrubMapsToAggregateBucketsAndClamps() {
        XCTAssertEqual(FitnessStressScrubModel.index(locationX: 0, width: 100, bucketCount: 5), 0)
        XCTAssertEqual(FitnessStressScrubModel.index(locationX: 50, width: 100, bucketCount: 5), 2)
        XCTAssertEqual(FitnessStressScrubModel.index(locationX: 100, width: 100, bucketCount: 5), 4)
        XCTAssertEqual(FitnessStressScrubModel.index(locationX: -20, width: 100, bucketCount: 5), 0)
        XCTAssertEqual(FitnessStressScrubModel.index(locationX: 200, width: 100, bucketCount: 5), 4)
    }

    func testReleaseNavigationKeepsHiddenDeepLinksOnVisibleHosts() {
        XCTAssertEqual(LifeOSDeepLink.usage.module, .home)
        XCTAssertEqual(LifeOSDeepLink.tasks.module, .calendar)
        XCTAssertEqual(LifeOSModule.macPrimaryModules, [.home, .calendar, .finance, .fitness, .tax, .settings])
        XCTAssertEqual(LifeOSModule.moreGroups.flatMap(\.modules), [.tax, .settings])

        let primary = LifeOSModule.macPrimaryModules
        XCTAssertLessThanOrEqual(primary.count, 6)
        XCTAssertEqual(Set(primary).count, primary.count, "Primary destinations must be unique")
        XCTAssertTrue(primary.allSatisfy(\.hasWorkingView), "Primary navigation cannot expose dead module shells")

        let more = LifeOSModule.moreGroups.flatMap(\.modules)
        XCTAssertTrue(more.allSatisfy(\.hasWorkingView), "More cannot expose speculative/dead module shells")
        XCTAssertEqual(LifeOSDeepLink.usage.module, .home, "Usage detail has one Home-owned route")
    }
}
