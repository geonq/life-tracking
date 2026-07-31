import XCTest
@testable import LifeOS

final class UsageAnalyticsTests: XCTestCase {
    func testHeatmapGridItemsHaveStableUniqueIdentifiers() {
        let items = UsageHeatmapGrid.items(cells: [])

        XCTAssertEqual(items.count, 72)
        XCTAssertEqual(Set(items.map(\.id)).count, items.count)
        XCTAssertEqual(items.first?.id, "corner")
        XCTAssertTrue(items.contains { $0.id == "hour-header-0" })
        XCTAssertTrue(items.contains { $0.id == "day-header-1" })
        XCTAssertTrue(items.contains { $0.id == "cell-7-21" })
    }

    func testProjectionUsesHourlyActivityProfileAndEndsAtReset() throws {
        let calendar = Calendar(identifier: .gregorian)
        let now = try XCTUnwrap(calendar.date(from: DateComponents(year: 2026, month: 7, day: 31, hour: 9)))
        let reset = try XCTUnwrap(calendar.date(byAdding: .hour, value: 3, to: now))
        let profile = UsageActivityProfile(hourlyWeights: [
            UsageHourWeight(weekday: 6, hour: 9, weight: 1),
            UsageHourWeight(weekday: 6, hour: 10, weight: 2),
            UsageHourWeight(weekday: 6, hour: 11, weight: 3)
        ])

        let points = UsageProjectionEngine.points(
            currentUsedPercent: 0.40,
            observedAt: now,
            resetAt: reset,
            baselineHourlyIncrease: 0.02,
            profile: profile,
            calendar: calendar
        )

        XCTAssertEqual(try XCTUnwrap(points.first?.usedPercent), 0.40, accuracy: 0.0001)
        XCTAssertEqual(points.last?.date, reset)
        XCTAssertEqual(try XCTUnwrap(points.last?.usedPercent), 0.52, accuracy: 0.0001)
        XCTAssertEqual(points.count, 4)
    }

    func testProjectionClampsAtOneAndRejectsExpiredWindow() throws {
        let now = Date(timeIntervalSince1970: 1_783_000_000)
        let profile = UsageActivityProfile(hourlyWeights: [])

        let clamped = UsageProjectionEngine.points(
            currentUsedPercent: 0.98,
            observedAt: now,
            resetAt: now.addingTimeInterval(7_200),
            baselineHourlyIncrease: 0.20,
            profile: profile
        )
        XCTAssertEqual(try XCTUnwrap(clamped.last?.usedPercent), 1, accuracy: 0.0001)
        XCTAssertTrue(
            UsageProjectionEngine.points(
                currentUsedPercent: 0.5,
                observedAt: now,
                resetAt: now,
                baselineHourlyIncrease: 0.1,
                profile: profile
            ).isEmpty
        )
    }

    func testProjectionIntegratesWeightsAcrossHourBoundaries() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try XCTUnwrap(TimeZone(secondsFromGMT: 0))
        let observedAt = try XCTUnwrap(calendar.date(from: DateComponents(
            year: 2026, month: 7, day: 31, hour: 9, minute: 30
        )))
        let resetAt = try XCTUnwrap(calendar.date(byAdding: .hour, value: 1, to: observedAt))
        let weekday = calendar.component(.weekday, from: observedAt)
        let profile = UsageActivityProfile(hourlyWeights: [
            UsageHourWeight(weekday: weekday, hour: 9, weight: 1),
            UsageHourWeight(weekday: weekday, hour: 10, weight: 3)
        ])

        let points = UsageProjectionEngine.points(
            currentUsedPercent: 0.40,
            observedAt: observedAt,
            resetAt: resetAt,
            baselineHourlyIncrease: 0.10,
            profile: profile,
            calendar: calendar
        )

        XCTAssertEqual(try XCTUnwrap(points.last?.usedPercent), 0.60, accuracy: 0.0001)
    }

    func testSmallestObservedWindowWinsForWidgetAndDashboardSummary() {
        let snapshot = ProviderSnapshot(
            provider: .codex,
            accountLabel: "Test",
            windows: [
                UsageWindow(id: "7d", label: "Weekly", limit: 1, used: 0.2, durationMinutes: 10_080),
                UsageWindow(id: "5h", label: "5-hour", limit: 1, used: 0.4, durationMinutes: 300)
            ],
            provenance: Provenance(source: "Test", observedAt: .now, quality: .observed, connector: .healthy)
        )

        XCTAssertEqual(snapshot.smallestObservedWindow?.id, "5h")
    }

    func testWidgetSummaryUsesRemainingPercentageAndWindowIndicator() throws {
        let summary = try XCTUnwrap(UsageWidgetSummary(snapshot: DemoDataProvider.codex))
        XCTAssertEqual(summary.provider, .codex)
        XCTAssertEqual(summary.windowIndicator, "5hr")
        XCTAssertEqual(summary.remainingPercent, 0.58, accuracy: 0.0001)
    }

    func testWidgetSummaryFallsBackToWeeklyWhenShortWindowIsUnavailable() throws {
        let summary = try XCTUnwrap(UsageWidgetSummary(snapshot: DemoDataProvider.claude))
        XCTAssertEqual(summary.windowIndicator, "w")
        XCTAssertEqual(summary.remainingPercent, 0.69, accuracy: 0.0001)
    }

    func testWidgetSummaryFormatsActualShortWindowInsteadOfCallingEverythingFiveHours() throws {
        let observedAt = Date(timeIntervalSince1970: 1_783_000_000)
        let snapshot = ProviderSnapshot(
            provider: .codex,
            accountLabel: "Test",
            windows: [
                UsageWindow(id: "15m", label: "15-minute", limit: 1, used: 0.25, durationMinutes: 15),
                UsageWindow(id: "1h", label: "1-hour", limit: 1, used: 0.50, durationMinutes: 60)
            ],
            provenance: Provenance(source: "Test", observedAt: observedAt, quality: .observed, connector: .healthy)
        )

        let summary = try XCTUnwrap(UsageWidgetSummary(snapshot: snapshot))
        XCTAssertEqual(summary.windowIndicator, "15m")
        XCTAssertEqual(summary.remainingPercent, 0.75, accuracy: 0.0001)
    }

    func testSelectionFindsNearestPointAcrossObservedAndProjectedSeries() throws {
        let base = Date(timeIntervalSince1970: 1_783_000_000)
        let observed = [
            UsageProjectionPoint(date: base, usedPercent: 0.2),
            UsageProjectionPoint(date: base.addingTimeInterval(3_600), usedPercent: 0.3)
        ]
        let projected = [
            UsageProjectionPoint(date: base.addingTimeInterval(7_200), usedPercent: 0.4)
        ]

        let selected = try XCTUnwrap(UsageSelection.closestPoint(
            to: base.addingTimeInterval(6_500),
            observed: observed,
            projected: projected
        ))
        XCTAssertEqual(selected.date, projected[0].date)
        XCTAssertTrue(selected.isProjected)
        XCTAssertEqual(selected.usedPercent, 0.4, accuracy: 0.0001)
    }

    func testRadarSelectionMapsTopAndRightGesturesToAdjacentCategories() {
        let center = CGPoint(x: 100, y: 100)
        XCTAssertEqual(UsageSelection.radarCategoryIndex(at: CGPoint(x: 100, y: 20), center: center, count: 5), 0)
        XCTAssertEqual(UsageSelection.radarCategoryIndex(at: CGPoint(x: 180, y: 100), center: center, count: 5), 1)
        XCTAssertNil(UsageSelection.radarCategoryIndex(at: center, center: center, count: 5))
    }

    func testRadarSelectionUsesStableHalfOpenSectors() {
        let center = CGPoint(x: 100, y: 100)
        let radius = 80.0
        let sector = 2 * Double.pi / 5
        func point(clockwiseFromTop angle: Double) -> CGPoint {
            CGPoint(x: center.x + radius * sin(angle), y: center.y - radius * cos(angle))
        }

        XCTAssertEqual(UsageSelection.radarCategoryIndex(
            at: point(clockwiseFromTop: sector * 0.75), center: center, count: 5
        ), 0)
        XCTAssertEqual(UsageSelection.radarCategoryIndex(
            at: point(clockwiseFromTop: sector * 1.25), center: center, count: 5
        ), 1)
    }

    func testDemoAnalyticsCannotBeMatchedToObservedProviderSnapshot() {
        let observed = ProviderSnapshot(
            provider: .codex,
            accountLabel: "Connected account",
            windows: [],
            provenance: Provenance(
                source: "Live connector",
                observedAt: .now,
                quality: .observed,
                connector: .healthy
            )
        )

        XCTAssertNil(UsageAnalyticsResolver.matching(
            snapshot: observed,
            candidates: DemoUsageAnalytics.snapshots
        ))
        XCTAssertNotNil(UsageAnalyticsResolver.matching(
            snapshot: DemoDataProvider.codex,
            candidates: DemoUsageAnalytics.snapshots
        ))
    }

    func testModelBreakdownTotalIncludesEveryUsageCategory() {
        let model = UsageModelBreakdown(
            model: "gpt-5.6-sol",
            inputTokens: 100,
            outputTokens: 50,
            reasoningTokens: 25,
            toolTokens: 10,
            imageTokens: 5
        )
        XCTAssertEqual(model.totalTokens, 190)
    }

    func testDemoAnalyticsRemainExplicitlyDemoAndProviderSpecific() {
        XCTAssertEqual(DemoUsageAnalytics.snapshots.map(\.provider), [.codex, .claude])
        XCTAssertTrue(DemoUsageAnalytics.snapshots.allSatisfy { $0.provenance.quality == .demo })
        XCTAssertTrue(DemoUsageAnalytics.snapshots.allSatisfy { !$0.activity.isEmpty })
        XCTAssertTrue(DemoUsageAnalytics.snapshots.allSatisfy { !$0.modelBreakdowns.isEmpty })
    }
}
