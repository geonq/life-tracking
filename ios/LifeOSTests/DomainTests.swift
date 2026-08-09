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
          "connectors":{"codex":"healthy","claude":"unavailable"}}
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
        XCTAssertNil(DemoDataProvider.claude.windows.first { $0.id == "5h" }?.usedPercent)
    }

    func testProvidersHaveSeparateCardsAndNoAggregateModel() {
        XCTAssertEqual(DemoDataProvider.providers.map(\.provider), [.codex, .claude])
        XCTAssertNotEqual(DemoDataProvider.codex.provider, DemoDataProvider.claude.provider)
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

    func testCalendarDeepLinkDistinguishesBrowseAndNewEvent() throws {
        XCTAssertEqual(LifeOSDeepLink(url: try XCTUnwrap(URL(string: "lifeos://calendar"))), .calendar)
        XCTAssertEqual(LifeOSDeepLink(url: try XCTUnwrap(URL(string: "lifeos://calendar/new"))), .newCalendarEvent)
        XCTAssertEqual(LifeOSDeepLink(url: try XCTUnwrap(URL(string: "lifeos://usage"))), .usage)
        XCTAssertNil(LifeOSDeepLink(url: try XCTUnwrap(URL(string: "https://calendar/new"))))
    }
}
