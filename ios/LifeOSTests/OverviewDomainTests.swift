import XCTest
@testable import LifeOS

final class OverviewDomainTests: XCTestCase {
    func testDemoOverviewContainsRequestedCompactCardsWithoutPretendingToBeLive() {
        let overview = DemoDataProvider.overview
        XCTAssertEqual(overview.sections.map(\.kind), [.llm, .clipper, .health, .finance])
        XCTAssertTrue(overview.sections.allSatisfy { $0.provenance.quality == .demo })
        XCTAssertEqual(overview.sections.first { $0.kind == .llm }?.metrics.map(\.label), ["Codex", "Claude", "GLM", "DeepSeek", "Google AI Studio", "Banked resets"])
        XCTAssertEqual(overview.sections.first { $0.kind == .clipper }?.metrics.map(\.label), ["Views today", "Subscribers today", "Revenue this month"])
        XCTAssertEqual(overview.sections.first { $0.kind == .clipper }?.metrics.map(\.icon), [.views, .subscribers, .revenue])
        XCTAssertEqual(overview.sections.first { $0.kind == .finance }?.metrics.map(\.icon), [.savings, .budget])
    }

    func testUnavailableValuesStayUnavailableInsteadOfInventingMetrics() {
        let metric = OverviewMetric(label: "Resting heart rate", value: nil, unit: "bpm", icon: .heartRate)
        XCTAssertNil(metric.displayValue)
    }

    func testProductionOverviewFallbackContainsNoSyntheticValues() {
        let generatedAt = Date(timeIntervalSince1970: 1_800_000_000)
        let overview = OverviewSnapshot.unavailable(at: generatedAt)

        XCTAssertEqual(overview.generatedAt, generatedAt)
        XCTAssertEqual(overview.sections.map(\.kind), [.llm, .clipper, .health, .finance])
        XCTAssertTrue(overview.sections.allSatisfy { section in
            section.provenance.quality == .unavailable
                && section.provenance.connector == .unavailable
                && section.metrics.allSatisfy { $0.value == nil }
        })
    }

    func testProductionOverviewRetainsTypedClipperPayloadForDetailRendering() {
        let generatedAt = Date(timeIntervalSince1970: 1_800_000_000)
        let clipper = ClipperSnapshot.unavailable(at: generatedAt)
        let overview = OverviewSnapshot.production(clipper: clipper, at: generatedAt)

        XCTAssertEqual(overview.clipperSnapshot, clipper)
    }

    func testPartialClipperQualityRemainsExplicitInOverviewProjection() throws {
        let clipper = try makeClipperSnapshot(quality: "partial", amountCents: 8_420)
        let section = OverviewSection.clipperSummary(from: clipper)

        XCTAssertEqual(section.provenance.quality, .observed)
        XCTAssertEqual(section.state, .partial)
        XCTAssertEqual(section.provenance.source, "reviewed-clipper-connector")
    }

    func testClipperRevenueFormattingHandlesTheFullSafeIntegerCentsBound() throws {
        let clipper = try makeClipperSnapshot(amountCents: 9_007_199_254_740_991)
        let section = OverviewSection.clipperSummary(from: clipper)

        XCTAssertEqual(section.metric(containing: "Revenue")?.value, "€90071992547409.91")
    }

    func testUsageSummaryAdaptsAcrossAllProvidersWithoutInventingValues() {
        let section = OverviewSection.usageSummary(from: DemoDataProvider.providers)
        XCTAssertEqual(section.metrics.map(\.label), ["Codex", "Claude", "GLM", "DeepSeek", "Google AI Studio", "Banked resets"])
        XCTAssertEqual(section.metrics.first { $0.label == "Codex" }?.value, "58")
        XCTAssertEqual(section.metrics.first { $0.label == "Claude" }?.value, "69")
        for name in ["GLM", "DeepSeek", "Google AI Studio"] {
            let metric = section.metrics.first { $0.label == name }
            XCTAssertNil(metric?.value)
            XCTAssertEqual(metric?.unit, "% left")
        }
    }

    func testUnavailableClipperContractKeepsDetailMetricsEmpty() throws {
        let overview = OverviewSnapshot.unavailable(at: Date(timeIntervalSince1970: 1_800_000_000))
        let clipper = try XCTUnwrap(overview.sections.first { $0.kind == .clipper })

        XCTAssertEqual(clipper.metrics.map(\.label), ["Views today", "Subscribers today", "Revenue this month"])
        XCTAssertTrue(clipper.metrics.allSatisfy { $0.displayValue == nil })
        XCTAssertEqual(clipper.provenance.quality, .unavailable)
        XCTAssertEqual(clipper.provenance.connector, .unavailable)
    }

    func testOverviewSectionMetricLookupIsCaseInsensitiveAndDoesNotInventHistory() throws {
        let finance = try XCTUnwrap(DemoDataProvider.overview.sections.first { $0.kind == .finance })

        XCTAssertEqual(finance.metric(containing: "BUDGET")?.value, "45")
        XCTAssertNil(finance.metric(containing: "history"))
    }

    func testUsageRemainingProjectionIsSortedBoundedAndUsesLastDuplicate() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let window = UsageWindow(
            id: "5h",
            label: "5-hour",
            limit: 1,
            used: 0.4,
            resetAt: now.addingTimeInterval(3_600),
            durationMinutes: 300
        )
        let analytics = UsageAnalyticsSnapshot(
            provider: .codex,
            windowID: "5h",
            activity: [
                UsageActivityPoint(date: now.addingTimeInterval(4_000), tokens: 4, usedPercent: 0.99),
                UsageActivityPoint(date: now.addingTimeInterval(1_800), tokens: 3, usedPercent: 0.40),
                UsageActivityPoint(date: now, tokens: 2, usedPercent: 0.20),
                UsageActivityPoint(date: now, tokens: 1, usedPercent: 0.10)
            ],
            projection: [],
            modelBreakdowns: [],
            heatmap: [],
            provenance: DemoDataProvider.provenance
        )

        let points = OverviewChartProjection.usageRemaining(from: analytics, window: window)

        XCTAssertEqual(points.map(\.date), [now, now.addingTimeInterval(1_800)])
        XCTAssertEqual(points.map(\.value), [0.9, 0.6])
    }

    func testClipperTrendSelectionPrefersViewsAndRequiresTwoObservedPoints() throws {
        let now = Date()
        let clipper = try makeClipperSnapshot(trends: [
            makeTrend(at: now.addingTimeInterval(-3_600), views: 100, subscribers: 10, revenueCents: 500),
            makeTrend(at: now.addingTimeInterval(-1_800), views: 240, subscribers: 12, revenueCents: 700)
        ])

        let selection = try XCTUnwrap(OverviewChartProjection.preferredClipperTrend(from: clipper.trends ?? []))

        XCTAssertEqual(selection.metric, .views)
        XCTAssertEqual(selection.points.map(\.value), [100, 240])
    }

    func testClipperTrendSelectionFallsBackToSubscribersAndRejectsOnePoint() throws {
        let now = Date()
        let onlyOneView = makeTrend(at: now.addingTimeInterval(-3_600), views: 100, subscribers: 10, revenueCents: 500)
        let noView = makeTrend(at: now.addingTimeInterval(-1_800), views: nil, subscribers: 12, revenueCents: 700)
        let clipper = try makeClipperSnapshot(trends: [onlyOneView, noView])

        let selection = try XCTUnwrap(OverviewChartProjection.preferredClipperTrend(from: clipper.trends ?? []))

        XCTAssertEqual(selection.metric, .subscribers)
        XCTAssertEqual(selection.points.count, 2)
        XCTAssertNil(OverviewChartProjection.preferredClipperTrend(from: [try XCTUnwrap(clipper.trends?.first)]))
    }

    func testClipperTrendProjectionUsesLastSourceOccurrenceForDuplicateTimestamp() throws {
        let now = Date()
        let first = makeTrend(at: now.addingTimeInterval(-3_600), views: 100, subscribers: 10, revenueCents: 500)
        let last = makeTrend(at: now.addingTimeInterval(-3_600), views: 220, subscribers: 10, revenueCents: 500)
        let later = makeTrend(at: now.addingTimeInterval(-1_800), views: 240, subscribers: 12, revenueCents: 700)
        let clipper = try makeClipperSnapshot(trends: [first, last, later])

        let selection = try XCTUnwrap(OverviewChartProjection.preferredClipperTrend(from: clipper.trends ?? []))

        XCTAssertEqual(selection.metric, .views)
        XCTAssertEqual(selection.points.map(\.value), [220, 240])
    }

    func testOverviewChartAxisUsesTimeForSubDayAndDayForLongerWindows() {
        let start = Date(timeIntervalSince1970: 1_800_000_000)
        let short = [
            OverviewChartPoint(date: start, value: 0.8),
            OverviewChartPoint(date: start.addingTimeInterval(3_600), value: 0.7)
        ]
        let long = [
            OverviewChartPoint(date: start, value: 0.8),
            OverviewChartPoint(date: start.addingTimeInterval(24 * 60 * 60), value: 0.7)
        ]

        XCTAssertEqual(OverviewChartAxis.labelMode(for: short), .time)
        XCTAssertEqual(OverviewChartAxis.labelMode(for: long), .day)
    }

    func testOverviewStatusPolicyScopesWarningsAndPreservesHealthIntegrityDetail() {
        let healthSource = FitnessSourceState(
            status: .unavailable,
            title: "HealthKit fitness source · Conflict",
            detail: "Conflict · observed heart-rate values disagree",
            freshness: "Current"
        )

        XCTAssertFalse(OverviewHomeStatusPolicy.isWarning(
            section: .llm,
            quality: .observed,
            connector: .healthy,
            sectionState: .complete,
            clipperState: .unavailable,
            healthState: .stale,
            healthIntegrityIssue: false,
            financeState: .stale
        ))
        XCTAssertTrue(OverviewHomeStatusPolicy.isWarning(
            section: .health,
            quality: .unavailable,
            connector: .unavailable,
            sectionState: .complete,
            clipperState: .unavailable,
            healthState: .unavailable,
            healthIntegrityIssue: true,
            financeState: .unavailable
        ))
        XCTAssertNotNil(OverviewHomeStatusPolicy.healthIntegrityStatus(source: healthSource, hasObservedMetrics: true))
        XCTAssertNil(OverviewHomeStatusPolicy.healthIntegrityStatus(source: healthSource, hasObservedMetrics: false))
    }

    func testOverviewSnapshotStatusFlagsHealthIntegrityReviewBeforeUnavailable() {
        let unavailableSections = Array(repeating: DataQuality.unavailable, count: 4)

        XCTAssertEqual(
            OverviewHomeStatusPolicy.snapshotStatusLabel(
                qualities: unavailableSections,
                healthState: .unavailable,
                healthIntegrityIssue: true,
                financeState: .unavailable,
                financeHasObservedValue: false,
                clipperState: .unavailable,
                hasRefreshDueSection: false
            ),
            "PARTIAL DATA · REVIEW SOURCE"
        )
        XCTAssertEqual(
            OverviewHomeStatusPolicy.snapshotStatusLabel(
                qualities: unavailableSections,
                healthState: .unavailable,
                healthIntegrityIssue: false,
                financeState: .unavailable,
                financeHasObservedValue: false,
                clipperState: .unavailable,
                hasRefreshDueSection: false
            ),
            "DATA UNAVAILABLE"
        )
    }

    func testOverviewCurrencyFormatterUsesLocaleAwareDecimalEUR() {
        XCTAssertEqual(
            OverviewCurrencyFormatter.eur(cents: 8_420, locale: Locale(identifier: "en_US")),
            "€84.20"
        )
    }

    func testUsageTrendPresentationNeverCallsEstimatedOrDemoObserved() {
        XCTAssertEqual(OverviewUsageTrendPresentation.label(for: .observed), "Observed trend")
        XCTAssertEqual(OverviewUsageTrendPresentation.label(for: .demo), "Demo fixture · not live")
        XCTAssertEqual(OverviewUsageTrendPresentation.label(for: .estimated), "Estimated activity")
        XCTAssertFalse(OverviewUsageTrendPresentation.isRenderable(for: .unavailable))
    }

    private func makeClipperSnapshot(quality: String = "observed", amountCents: Int = 8_420,
                                     trends: [[String: Any]] = []) throws -> ClipperSnapshot {
        let now = Date()
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let timestamp = formatter.string(from: now)
        let provenance: [String: Any] = [
            "source": "reviewed-clipper-connector", "observedAt": timestamp,
            "freshness": "fresh", "quality": "observed", "connectorState": "healthy",
        ]
        let metrics: [String: Any] = [
            "views": ["availability": "observed", "value": 42_000, "provenance": provenance],
            "subscribers": ["availability": "observed", "value": 1_240, "provenance": provenance],
            "revenue": ["availability": "observed", "amountCents": amountCents, "currency": "EUR", "provenance": provenance],
        ]
        let payload: [String: Any] = [
            "schemaVersion": 1, "availability": "observed", "generatedAt": timestamp,
            "currency": "EUR", "metrics": metrics, "accounts": [], "trends": trends, "breakdowns": [],
            "provenance": [
                "source": "reviewed-clipper-connector", "observedAt": timestamp,
                "freshness": "fresh", "quality": quality, "connectorState": "healthy",
            ],
        ]
        return try ClipperSnapshot.decode(JSONSerialization.data(withJSONObject: payload), now: now)
    }

    private func makeTrend(at date: Date, views: Int?, subscribers: Int, revenueCents: Int) -> [String: Any] {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let observedAt = formatter.string(from: Date())
        let observedProvenance: [String: Any] = [
            "source": "reviewed-clipper-connector", "observedAt": observedAt,
            "freshness": "fresh", "quality": "observed", "connectorState": "healthy"
        ]
        let unavailableProvenance: [String: Any] = [
            "source": "no-authorized-clipper-source", "observedAt": observedAt,
            "freshness": "unknown", "quality": "unavailable", "connectorState": "unavailable"
        ]
        let viewsMetric: [String: Any] = views.map {
            ["availability": "observed", "value": $0, "provenance": observedProvenance]
        } ?? ["availability": "unavailable", "provenance": unavailableProvenance]
        let metrics: [String: Any] = [
            "views": viewsMetric,
            "subscribers": ["availability": "observed", "value": subscribers, "provenance": observedProvenance],
            "revenue": ["availability": "observed", "amountCents": revenueCents, "currency": "EUR", "provenance": observedProvenance]
        ]
        return ["at": formatter.string(from: date), "metrics": metrics]
    }
}
