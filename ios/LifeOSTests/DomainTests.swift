import XCTest
@testable import LifeOS

final class DomainTests: XCTestCase {
    func testDecodesRepresentativeUsagePayloadWithOptionalFields() throws {
        let json = """
        {"generatedAt":"2026-07-28T12:00:00+00:00","windows":[
          {"provider":"codex","window":"five_hour","durationMinutes":300,"usedPercent":42,"resetAt":"2026-07-28T15:00:00+00:00","availability":"observed","provenance":{"source":"codex-official","observedAt":"2026-07-28T11:55:00+00:00","freshness":"fresh","official":true,"quality":"observed","connectorState":"healthy"}},
          {"provider":"claude","window":"five_hour","durationMinutes":300,"availability":"unavailable","provenance":{"source":"claude-connector","observedAt":"2026-07-28T11:55:00+00:00","freshness":"unknown","official":false,"quality":"unavailable","connectorState":"unavailable"}}],
          "estimates":[{"provider":"codex","window":"seven_day","projectedPercentAtReset":41,"estimatedExhaustionAt":"2026-07-29T12:00:00+00:00","velocityPercentPerHour":1.5,"confidence":"medium","sampleSpanHours":24,"explanation":"Observed trend","official":false}],
          "connectors":{"codex":"healthy","claude":"unavailable"}}
        """.data(using: .utf8)!
        let payload = try JSONDecoder.lifeOS.decode(APIUsagePayload.self, from: json)
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

    func testAppGroupStoreFailsClosedForPlaceholder() {
        XCTAssertNil(AppGroupConfiguration.validatedIdentifier("$(APP_GROUP_IDENTIFIER)"))
        XCTAssertNil(SharedSnapshotStore.url(appGroupIdentifier: "$(APP_GROUP_IDENTIFIER)"))
    }
}
