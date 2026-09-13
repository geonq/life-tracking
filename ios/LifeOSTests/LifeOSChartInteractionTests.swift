import XCTest
@testable import LifeOS

final class LifeOSChartInteractionTests: XCTestCase {
    func testUsageDatasetKeyUsesOnlyDomainIdentity() {
        let base = Date(timeIntervalSince1970: 1_800_000_000)
        let window = usageWindow(base: base)
        let provider = makeProviderSnapshot(base: base, window: window)
        let initial = makeAnalyticsSnapshot(base: base, activityValues: [(0, 0.20), (3_600, 0.30)])
        let key = makeDatasetKey(provider, initial, window)

        let pointRevision = makeAnalyticsSnapshot(
            base: base.addingTimeInterval(3_600),
            activityValues: [(0, 0.60), (3_600, 0.80)], observedAt: base
        )
        let staleRevision = makeAnalyticsSnapshot(base: base, activityValues: [(0, 0.20)], observedAt: base.addingTimeInterval(-3_600))
        let unhealthyRevision = makeAnalyticsSnapshot(base: base, activityValues: [(0, 0.20)], connector: .error)
        XCTAssertNotEqual(initial.activity, pointRevision.activity)
        XCTAssertNotEqual(initial.activity.map(\.date), pointRevision.activity.map(\.date))
        XCTAssertNotEqual(initial.provenance.observedAt, staleRevision.provenance.observedAt)
        XCTAssertNotEqual(initial.provenance.connector, unhealthyRevision.provenance.connector)
        XCTAssertEqual(initial.provenance.freshness(now: base, staleAfter: 900), .fresh)
        XCTAssertEqual(staleRevision.provenance.freshness(now: base, staleAfter: 900), .stale)
        XCTAssertEqual(unhealthyRevision.provenance.freshness(now: base), .unavailable)
        for revision in [pointRevision, staleRevision, unhealthyRevision] {
            XCTAssertEqual(key, makeDatasetKey(provider, revision, window))
        }

        let claudeWindow = usageWindow(base: base)
        let claudeAnalytics = makeAnalyticsSnapshot(base: base, activityValues: [(0, 0.20)], provider: .claude)
        let sevenDayWindow = usageWindow(base: base, id: "seven_day", durationMinutes: 300)
        let sevenDayAnalytics = makeAnalyticsSnapshot(base: base, activityValues: [(0, 0.20)], windowID: "seven_day")
        let longerWindow = usageWindow(base: base, durationMinutes: 600)
        let changedKeys = [
            makeDatasetKey(makeProviderSnapshot(base: base, accountLabel: "Other", window: window), initial, window),
            makeDatasetKey(makeProviderSnapshot(base: base, provider: .claude, window: claudeWindow), claudeAnalytics, claudeWindow),
            makeDatasetKey(makeProviderSnapshot(base: base, window: sevenDayWindow), sevenDayAnalytics, sevenDayWindow),
            makeDatasetKey(provider, initial, longerWindow),
            makeDatasetKey(provider, makeAnalyticsSnapshot(base: base, activityValues: [(0, 0.20)], source: "Import"), window),
            makeDatasetKey(provider, makeAnalyticsSnapshot(base: base, activityValues: [(0, 0.20)], quality: .estimated), window),
            makeDatasetKey(provider, initial, window, metric: "tokens")
        ]
        changedKeys.forEach { XCTAssertNotEqual(key, $0) }
    }

    func testUsageInspectionPreservesSelectionViewportAcrossSameKeyRevisions() throws {
        let base = Date(timeIntervalSince1970: 1_800_000_000)
        let key = inspectionKey(base: base)
        let epoch = UsageChartResetEpoch.boundary(base.addingTimeInterval(14_400))
        let first = inspectionModel(
            base: base, activityValues: [(0, 0.20), (3_600, 0.30)], estimateOffset: 7_200
        )
        let appended = inspectionModel(
            base: base, activityValues: [(0, 0.25), (3_600, 0.35), (7_200, 0.45)],
            estimateOffset: 7_200
        )
        var state = UsageChartInspectionState()
        state.reduce(UsageChartInspectionUpdate(
            key: key, resetEpoch: epoch, generation: 1, phase: .resolvedPopulated(first)
        ))
        let selectedID = try XCTUnwrap(first.selectablePoints.first?.id)
        state.select(pointID: selectedID)
        let viewport = try XCTUnwrap(
            UsageChartInspectionViewport(start: base, end: base.addingTimeInterval(7_200))
        )
        state.setViewport(viewport)

        state.reduce(UsageChartInspectionUpdate(
            key: key, resetEpoch: epoch, generation: 2, phase: .resolvedPopulated(appended)
        ))
        XCTAssertEqual(state.acceptedModel?.revisionID, appended.revisionID)
        XCTAssertEqual(state.acceptedModel?.actualPoints.count, 3)
        XCTAssertEqual(state.acceptedModel?.actualPoints.first?.usedPercent, 0.25)
        XCTAssertEqual(state.selectedPointID, selectedID)
        XCTAssertEqual(state.viewport, viewport)

        let movedEstimate = inspectionModel(
            base: base, activityValues: [(0, 0.25), (3_600, 0.35), (7_200, 0.45)],
            estimateOffset: 10_800
        )
        state.reduce(UsageChartInspectionUpdate(
            key: key, resetEpoch: epoch, generation: 3, phase: .resolvedPopulated(movedEstimate)
        ))
        XCTAssertEqual(state.acceptedModel?.estimatePoints.last?.date, base.addingTimeInterval(10_800))
        XCTAssertEqual(state.selectedPointID, selectedID)
        XCTAssertEqual(state.viewport, viewport)

        var invalid = state
        invalid.setViewport(.explicit(start: base, end: base))
        XCTAssertEqual(invalid.viewport, .automatic)
        invalid.setViewport(.explicit(start: base.addingTimeInterval(7_200), end: base))
        XCTAssertEqual(invalid.viewport, .automatic)
        let nonfinite = Date(timeIntervalSinceReferenceDate: Double.nan)
        invalid.setViewport(.explicit(start: base, end: nonfinite))
        XCTAssertEqual(invalid.viewport, .automatic)
        XCTAssertNil(UsageChartInspectionViewport(start: base, end: base))
        XCTAssertNil(UsageChartInspectionViewport(
            start: base.addingTimeInterval(7_200), end: base
        ))
        XCTAssertNil(UsageChartInspectionViewport(start: base, end: nonfinite))
        XCTAssertEqual(viewport.absoluteInterval?.start, base)
        XCTAssertEqual(viewport.absoluteInterval?.end, base.addingTimeInterval(7_200))
    }

    func testUsageInspectionRetainsModelDuringLoadingAndFailureThenClearsRemovedSelection() throws {
        let base = Date(timeIntervalSince1970: 1_800_000_000)
        let key = inspectionKey(base: base)
        let epoch = UsageChartResetEpoch.boundary(base.addingTimeInterval(14_400))
        let first = inspectionModel(
            base: base, activityValues: [(0, 0.20), (3_600, 0.30)]
        )
        let withoutSelectedPoint = inspectionModel(
            base: base, activityValues: [(0, 0.20)]
        )
        var state = UsageChartInspectionState()
        state.reduce(UsageChartInspectionUpdate(
            key: key, resetEpoch: epoch, generation: 1, phase: .resolvedPopulated(first)
        ))
        let selectedID = try XCTUnwrap(first.selectablePoints.last?.id)
        state.select(pointID: selectedID)
        let viewport = try XCTUnwrap(
            UsageChartInspectionViewport(start: base, end: base.addingTimeInterval(3_600))
        )
        state.setViewport(viewport)

        state.reduce(UsageChartInspectionUpdate(
            key: key, resetEpoch: epoch, generation: 2, phase: .loading
        ))
        XCTAssertEqual(state.status, .refreshing)
        XCTAssertTrue(state.isRefreshing)
        XCTAssertEqual(state.acceptedModel?.revisionID, first.revisionID)
        XCTAssertEqual(state.selectedPointID, selectedID)
        XCTAssertEqual(state.viewport, viewport)

        state.reduce(UsageChartInspectionUpdate(
            key: key, resetEpoch: epoch, generation: 3, phase: .failed
        ))
        XCTAssertEqual(state.selectedPointID, selectedID)
        XCTAssertEqual(state.viewport, viewport)
        XCTAssertEqual(state.status, .stale)
        XCTAssertTrue(state.isStale)
        XCTAssertEqual(state.acceptedModel?.revisionID, first.revisionID)

        state.reduce(UsageChartInspectionUpdate(
            key: key, resetEpoch: epoch, generation: 4,
            phase: .resolvedPopulated(withoutSelectedPoint)
        ))
        XCTAssertEqual(state.status, .resolved)
        XCTAssertEqual(state.acceptedModel?.actualPoints.count, 1)
        XCTAssertNil(state.selectedPointID)
        XCTAssertEqual(state.viewport, viewport)
    }

    func testUsageInspectionDistinguishesAuthoritativeEmptyEpochsAndIgnoresStaleGeneration() throws {
        let base = Date(timeIntervalSince1970: 1_800_000_000)
        let key = inspectionKey(base: base)
        let first = inspectionModel(
            base: base, activityValues: [(0, 0.20), (3_600, 0.30)]
        )
        let viewport = try XCTUnwrap(
            UsageChartInspectionViewport(start: base, end: base.addingTimeInterval(3_600))
        )
        func ready(_ epoch: UsageChartResetEpoch, generation: Int) -> UsageChartInspectionState {
            var state = UsageChartInspectionState()
            state.reduce(UsageChartInspectionUpdate(
                key: key, resetEpoch: epoch, generation: generation, phase: .resolvedPopulated(first)
            ))
            state.select(pointID: first.selectablePoints.first?.id)
            state.setViewport(viewport)
            return state
        }

        var sameWindowEmpty = ready(.boundary(base), generation: 1)
        sameWindowEmpty.reduce(UsageChartInspectionUpdate(
            key: key, resetEpoch: .boundary(base), generation: 2,
            phase: .resolvedAuthoritativeEmpty
        ))
        XCTAssertNil(sameWindowEmpty.acceptedModel)
        XCTAssertNil(sameWindowEmpty.selectedPointID)
        XCTAssertEqual(sameWindowEmpty.viewport, viewport)
        XCTAssertEqual(sameWindowEmpty.status, .authoritativeEmpty)

        var resetEmpty = ready(.boundary(base), generation: 1)
        resetEmpty.reduce(UsageChartInspectionUpdate(
            key: key, resetEpoch: .boundary(base.addingTimeInterval(3_600)), generation: 2,
            phase: .resolvedAuthoritativeEmpty
        ))
        XCTAssertNil(resetEmpty.acceptedModel)
        XCTAssertNil(resetEmpty.selectedPointID)
        XCTAssertEqual(resetEmpty.viewport, .automatic)

        var resetLoading = ready(.boundary(base), generation: 1)
        resetLoading.reduce(UsageChartInspectionUpdate(
            key: key, resetEpoch: .boundary(base.addingTimeInterval(3_600)), generation: 2,
            phase: .loading
        ))
        XCTAssertNil(resetLoading.acceptedModel)
        XCTAssertNil(resetLoading.selectedPointID)
        XCTAssertEqual(resetLoading.status, .loading)
        XCTAssertFalse(resetLoading.isRefreshing)
        XCTAssertEqual(resetLoading.viewport, .automatic)

        let resolved = inspectionModel(
            base: base, activityValues: [(0, 0.25), (3_600, 0.35)]
        )
        var equalGeneration = ready(.boundary(base), generation: 1)
        equalGeneration.reduce(UsageChartInspectionUpdate(
            key: key, resetEpoch: .boundary(base), generation: 2, phase: .loading
        ))
        XCTAssertEqual(equalGeneration.status, .refreshing)
        equalGeneration.reduce(UsageChartInspectionUpdate(
            key: key, resetEpoch: .boundary(base), generation: 2,
            phase: .resolvedPopulated(resolved)
        ))
        XCTAssertEqual(equalGeneration.generation, 2)
        XCTAssertEqual(equalGeneration.status, .resolved)
        XCTAssertEqual(equalGeneration.acceptedModel?.revisionID, resolved.revisionID)

        let otherWindow = usageWindow(base: base, id: "other", durationMinutes: 60)
        let staleKey = makeDatasetKey(
            makeProviderSnapshot(base: base, accountLabel: "Other", provider: .claude, window: otherWindow),
            makeAnalyticsSnapshot(base: base, activityValues: [], provider: .claude, windowID: "other"),
            otherWindow, metric: "tokens"
        )
        equalGeneration.reduce(UsageChartInspectionUpdate(
            key: staleKey, resetEpoch: .boundary(base.addingTimeInterval(7_200)), generation: 1,
            phase: .resolvedAuthoritativeEmpty
        ))
        XCTAssertEqual(equalGeneration.generation, 2)
        XCTAssertEqual(equalGeneration.key, key)
        XCTAssertEqual(equalGeneration.resetEpoch, .boundary(base))
        XCTAssertEqual(equalGeneration.acceptedModel?.revisionID, resolved.revisionID)
        XCTAssertEqual(equalGeneration.selectedPointID, first.selectablePoints.first?.id)
        XCTAssertEqual(equalGeneration.viewport, viewport)
        XCTAssertEqual(equalGeneration.status, .resolved)
    }

    func testUsageAuthorityBlocksHistorySeedAfterAuthoritativeEmptyAcrossRemount() throws {
        let base = Date(timeIntervalSince1970: 1_800_000_000)
        let window = usageWindow(base: base)
        let analytics = makeAnalyticsSnapshot(
            base: base,
            activityValues: [(0, 0.20), (3_600, 0.30)]
        )
        let model = UsageProjectionDisplayModel(analytics: analytics, window: window)
        let key = makeDatasetKey(
            makeProviderSnapshot(base: base, window: window),
            analytics,
            window
        )
        let resetEpoch = UsageChartResetEpoch.boundary(base.addingTimeInterval(14_400))

        XCTAssertNotNil(UsageChartPresentationPolicy.seedModel(
            for: .loading,
            authority: .observed,
            analytics: analytics,
            window: window
        ))
        XCTAssertNil(UsageChartPresentationPolicy.seedModel(
            for: .loading,
            authority: .authoritativeEmpty,
            analytics: analytics,
            window: window
        ))

        var mounted = UsageChartInspectionState()
        mounted.reduce(UsageChartInspectionUpdate(
            key: key,
            resetEpoch: resetEpoch,
            generation: 1,
            phase: .resolvedPopulated(model),
            authority: .observed
        ))
        mounted.reduce(UsageChartInspectionUpdate(
            key: key,
            resetEpoch: resetEpoch,
            generation: 2,
            phase: .resolvedAuthoritativeEmpty,
            authority: .authoritativeEmpty
        ))
        XCTAssertNil(mounted.acceptedModel)

        // A remount receives retained history with a lifecycle packet. The
        // empty authority must prevent the old model from being seeded again.
        var remounted = UsageChartInspectionState()
        remounted.reduce(UsageChartInspectionUpdate(
            key: key,
            resetEpoch: resetEpoch,
            generation: 3,
            phase: .loading,
            authority: .authoritativeEmpty
        ))
        XCTAssertNil(remounted.acceptedModel)
        XCTAssertEqual(remounted.presentationAuthority, .authoritativeEmpty)

        remounted.reduce(UsageChartInspectionUpdate(
            key: key,
            resetEpoch: resetEpoch,
            generation: 4,
            phase: .failed,
            authority: .authoritativeEmpty
        ))
        XCTAssertNil(remounted.acceptedModel)

        // The explicit authority also wins if a same-key lifecycle packet is
        // inconsistent and carries a populated phase.
        remounted.reduce(UsageChartInspectionUpdate(
            key: key,
            resetEpoch: resetEpoch,
            generation: 5,
            phase: .resolvedPopulated(model),
            authority: .authoritativeEmpty
        ))
        XCTAssertNil(remounted.acceptedModel)
    }

    func testUnknownAuthorityDoesNotCrossProviderWindowOrAccountIdentity() throws {
        let base = Date(timeIntervalSince1970: 1_800_000_000)
        let oldWindow = usageWindow(base: base)
        let oldAnalytics = makeAnalyticsSnapshot(
            base: base,
            activityValues: [(0, 0.20), (3_600, 0.30)]
        )
        let oldProvider = makeProviderSnapshot(base: base, window: oldWindow)
        let oldKey = makeDatasetKey(oldProvider, oldAnalytics, oldWindow)
        let oldModel = UsageProjectionDisplayModel(analytics: oldAnalytics, window: oldWindow)
        let oldEpoch = UsageChartResetEpoch.boundary(oldWindow.resetAt!)

        var state = UsageChartInspectionState()
        state.reduce(UsageChartInspectionUpdate(
            key: oldKey,
            resetEpoch: oldEpoch,
            generation: 1,
            phase: .resolvedPopulated(oldModel),
            authority: .observed
        ))
        state.reduce(UsageChartInspectionUpdate(
            key: oldKey,
            resetEpoch: oldEpoch,
            generation: 2,
            phase: .resolvedAuthoritativeEmpty,
            authority: .authoritativeEmpty
        ))

        let newWindow = usageWindow(base: base, id: "seven_day", durationMinutes: 10_080)
        let newAnalytics = makeAnalyticsSnapshot(
            base: base,
            activityValues: [(0, 0.40)],
            provider: .claude,
            windowID: "seven_day"
        )
        let newProvider = makeProviderSnapshot(
            base: base,
            provider: .claude,
            window: newWindow
        )
        let newKey = makeDatasetKey(newProvider, newAnalytics, newWindow)
        let newModel = UsageProjectionDisplayModel(analytics: newAnalytics, window: newWindow)

        // The new provider/window must not inherit Codex's authoritative-empty
        // marker when the packet omits an authority field.
        state.reduce(UsageChartInspectionUpdate(
            key: newKey,
            resetEpoch: .boundary(newWindow.resetAt!),
            generation: 3,
            phase: .resolvedPopulated(newModel)
        ))
        XCTAssertEqual(state.presentationAuthority, .unknown)
        XCTAssertEqual(state.acceptedModel?.revisionID, newModel.revisionID)

        let accountProvider = makeProviderSnapshot(
            base: base,
            accountLabel: "Claude secondary account",
            provider: .claude,
            window: newWindow
        )
        let accountKey = makeDatasetKey(accountProvider, newAnalytics, newWindow)
        state.reduce(UsageChartInspectionUpdate(
            key: accountKey,
            resetEpoch: .boundary(newWindow.resetAt!),
            generation: 4,
            phase: .resolvedPopulated(newModel)
        ))
        XCTAssertEqual(state.presentationAuthority, .unknown)
        XCTAssertEqual(state.acceptedModel?.revisionID, newModel.revisionID)
    }

    func testUsageEffectiveDomainClampsContractedViewportAndEnforcesMinimum() throws {
        let base = Date(timeIntervalSince1970: 1_800_000_000)
        let viewport = try XCTUnwrap(
            UsageChartInspectionViewport(
                start: base.addingTimeInterval(-3_600),
                end: base.addingTimeInterval(7_200)
            )
        )
        let contracted = try XCTUnwrap(UsageChartEffectiveDomain.range(
            earliest: base.addingTimeInterval(1_800),
            latest: base.addingTimeInterval(3_600),
            viewport: viewport
        ))
        XCTAssertEqual(contracted.lowerBound, base.addingTimeInterval(1_800))
        XCTAssertEqual(contracted.upperBound, base.addingTimeInterval(3_600))

        let shortViewport = try XCTUnwrap(
            UsageChartInspectionViewport(
                start: base.addingTimeInterval(1_800),
                end: base.addingTimeInterval(1_830)
            )
        )
        let minimum = try XCTUnwrap(UsageChartEffectiveDomain.range(
            earliest: base.addingTimeInterval(1_800),
            latest: base.addingTimeInterval(3_600),
            viewport: shortViewport
        ))
        XCTAssertEqual(
            minimum.upperBound.timeIntervalSince(minimum.lowerBound),
            UsageChartEffectiveDomain.minimumDuration,
            accuracy: 0.0001
        )
        XCTAssertEqual(minimum.lowerBound, base.addingTimeInterval(1_800))
        XCTAssertLessThanOrEqual(minimum.upperBound, base.addingTimeInterval(3_600))
    }

    func testUsageEffectiveDomainKeepsShortAndSingletonModelsTruthful() throws {
        let base = Date(timeIntervalSince1970: 1_800_000_000)
        let short = try XCTUnwrap(UsageChartEffectiveDomain.range(
            earliest: base,
            latest: base.addingTimeInterval(30),
            viewport: .automatic
        ))
        XCTAssertEqual(short.lowerBound, base)
        XCTAssertEqual(short.upperBound, base.addingTimeInterval(30))

        let singleton = try XCTUnwrap(UsageChartEffectiveDomain.range(
            earliest: base,
            latest: base,
            viewport: .automatic
        ))
        XCTAssertEqual(singleton.upperBound, base)
        XCTAssertEqual(
            singleton.upperBound.timeIntervalSince(singleton.lowerBound),
            UsageChartEffectiveDomain.minimumDuration,
            accuracy: 0.0001
        )
        XCTAssertLessThanOrEqual(singleton.upperBound, base)
    }

    private func inspectionModel(base: Date, activityValues: [(TimeInterval, Double)], estimateOffset: TimeInterval? = nil) -> UsageProjectionDisplayModel {
        UsageProjectionDisplayModel(analytics: makeAnalyticsSnapshot(base: base, activityValues: activityValues, estimateOffset: estimateOffset), window: usageWindow(base: base))
    }

    private func inspectionKey(base: Date) -> UsageChartDatasetKey {
        let window = usageWindow(base: base)
        return makeDatasetKey(makeProviderSnapshot(base: base, window: window), makeAnalyticsSnapshot(base: base, activityValues: []), window)
    }

    private func makeDatasetKey(_ providerSnapshot: ProviderSnapshot, _ analytics: UsageAnalyticsSnapshot, _ window: UsageWindow?, metric: String = "used_percent") -> UsageChartDatasetKey {
        UsageChartDatasetKey(providerSnapshot: providerSnapshot, analytics: analytics, window: window, metric: metric)
    }

    private func usageWindow(base: Date, id: String = "five_hour", durationMinutes: Int? = 300) -> UsageWindow {
        UsageWindow(id: id, label: "Usage", resetAt: base.addingTimeInterval(14_400), durationMinutes: durationMinutes)
    }

    private func makeProviderSnapshot(base: Date, accountLabel: String = "Codex account", provider: Provider = .codex, window: UsageWindow) -> ProviderSnapshot {
        ProviderSnapshot(provider: provider, accountLabel: accountLabel, windows: [window], provenance: Provenance(source: "Gateway", observedAt: base, quality: .observed, connector: .healthy))
    }

    private func makeAnalyticsSnapshot(base: Date, activityValues: [(TimeInterval, Double)], estimateOffset: TimeInterval? = nil, provider: Provider = .codex, windowID: String? = "five_hour", source: String = "Gateway", observedAt: Date? = nil, quality: DataQuality = .observed, connector: ConnectorState = .healthy) -> UsageAnalyticsSnapshot {
        let activity = activityValues.map { UsageActivityPoint(date: base.addingTimeInterval($0.0), tokens: 1, usedPercent: $0.1) }
        let projection = estimateOffset.map { [UsageProjectionPoint(date: base.addingTimeInterval($0), usedPercent: 0.70)] } ?? []
        return UsageAnalyticsSnapshot(provider: provider, windowID: windowID, activity: activity, projection: projection, modelBreakdowns: [], heatmap: [], provenance: Provenance(source: source, observedAt: observedAt ?? base, quality: quality, connector: connector))
    }

    func testNormalizationSortsKeepsLastDuplicateAndPreservesGaps() {
        let base = Date(timeIntervalSince1970: 1_800_000_000)
        let series = LifeOSChartSeries(
            id: "observed",
            label: "Observed",
            kind: .observed,
            points: [
                LifeOSChartPoint(timestamp: base.addingTimeInterval(10_800), value: 4),
                LifeOSChartPoint(timestamp: base.addingTimeInterval(7_200), value: nil),
                LifeOSChartPoint(timestamp: base.addingTimeInterval(3_600), value: 2),
                LifeOSChartPoint(timestamp: base, value: 1),
                LifeOSChartPoint(timestamp: base.addingTimeInterval(3_600), value: 3),
            ],
            source: "Test source",
            provenance: .observed
        )

        let normalized = LifeOSChartKit.normalizedPoints(
            for: series,
            expectedCadence: 3_600
        )

        XCTAssertEqual(normalized.map(\.timestamp), [
            base,
            base.addingTimeInterval(3_600),
            base.addingTimeInterval(7_200),
            base.addingTimeInterval(10_800),
        ])
        XCTAssertEqual(normalized[1].value, 3, "The last source occurrence wins deterministically")
        XCTAssertTrue(normalized[2].isGap)
        XCTAssertTrue(normalized[3].startsNewSegment)
        XCTAssertEqual(LifeOSChartKit.segments(from: normalized).count, 2)
        XCTAssertEqual(LifeOSChartKit.segments(from: normalized).map(\.count), [2, 1])
    }

    func testNearestSelectionUsesTimestampAndObservedTieBreak() throws {
        let base = Date(timeIntervalSince1970: 1_800_000_000)
        let target = LifeOSChartSeries(
            id: "target",
            label: "Target",
            kind: .target,
            points: [LifeOSChartPoint(timestamp: base.addingTimeInterval(-10), value: 0.2)],
            source: "Target plan",
            provenance: .estimated
        )
        let observed = LifeOSChartSeries(
            id: "observed",
            label: "Observed",
            kind: .observed,
            points: [LifeOSChartPoint(timestamp: base.addingTimeInterval(10), value: 0.4)],
            source: "Live source",
            provenance: .observed
        )

        let selected = try XCTUnwrap(
            LifeOSChartKit.nearestSelection(in: [target, observed], to: base)
        )

        XCTAssertEqual(selected.kind, .observed)
        XCTAssertEqual(selected.point.timestamp, base.addingTimeInterval(10))
        XCTAssertEqual(selected.provenanceLabel, "Observed · Live source")
    }

    func testUsageSelectionIdentitySeparatesObservedAndProjectedPoints() {
        let base = Date(timeIntervalSince1970: 1_800_000_000)
        let observed = UsageSelectionPoint(date: base, usedPercent: 0.4, isProjected: false)
        let projected = UsageSelectionPoint(date: base, usedPercent: 0.6, isProjected: true)

        XCTAssertNotEqual(observed.id, projected.id)
        XCTAssertEqual(
            UsageSelection.closestPoint(to: base, observed: [observed].map {
                UsageProjectionPoint(date: $0.date, usedPercent: $0.usedPercent)
            }, projected: [projected].map {
                UsageProjectionPoint(date: $0.date, usedPercent: $0.usedPercent)
            })?.id,
            observed.id
        )
    }

    func testUsageProjectionSegmentsPreserveHourlyCadenceBreaksAndValues() {
        let base = Date(timeIntervalSince1970: 1_800_000_000)
        let snapshot = UsageAnalyticsSnapshot(
            provider: .codex,
            activity: [
                UsageActivityPoint(date: base, tokens: 1, usedPercent: 0.2),
                UsageActivityPoint(date: base.addingTimeInterval(3_600), tokens: 2, usedPercent: 0.35),
                UsageActivityPoint(date: base.addingTimeInterval(10_800), tokens: 3, usedPercent: 0.8)
            ],
            projection: [],
            modelBreakdowns: [],
            heatmap: [],
            provenance: Provenance(
                source: "Gateway",
                observedAt: base,
                quality: .observed,
                connector: .healthy
            )
        )

        let displayModel = UsageProjectionDisplayModel(analytics: snapshot, window: nil)

        XCTAssertEqual(displayModel.renderedActualSegments.map { $0.points.count }, [2, 1])
        XCTAssertEqual(
            displayModel.renderedActualSegments.flatMap(\.points).map(\.usedPercent),
            [0.2, 0.35, 0.8]
        )
    }

    func testUsageProjectionDuplicateTimestampUsesLastValueEverywhere() throws {
        let base = Date(timeIntervalSince1970: 1_800_000_000)
        let estimateDate = base.addingTimeInterval(7_200)
        let snapshot = UsageAnalyticsSnapshot(
            provider: .codex,
            activity: [
                UsageActivityPoint(date: base, tokens: 1, usedPercent: 0.2),
                UsageActivityPoint(date: base, tokens: 2, usedPercent: 0.8),
                UsageActivityPoint(
                    date: base.addingTimeInterval(3_600),
                    tokens: 3,
                    usedPercent: 0.9
                )
            ],
            projection: [
                UsageProjectionPoint(date: estimateDate, usedPercent: 0.3),
                UsageProjectionPoint(date: estimateDate, usedPercent: 0.7)
            ],
            modelBreakdowns: [],
            heatmap: [],
            provenance: Provenance(
                source: "Gateway",
                observedAt: base,
                quality: .observed,
                connector: .healthy
            )
        )

        let displayModel = UsageProjectionDisplayModel(analytics: snapshot, window: nil)
        let selected = try XCTUnwrap(displayModel.nearestSelection(to: base))
        let projected = try XCTUnwrap(displayModel.nearestSelection(to: estimateDate))

        XCTAssertEqual(displayModel.actualPoints.map(\.date), [base, base.addingTimeInterval(3_600)])
        XCTAssertEqual(displayModel.actualPoints[0].usedPercent, 0.8)
        XCTAssertEqual(displayModel.renderedActualPoints[0].usedPercent, 0.8)
        XCTAssertEqual(selected.usedPercent, 0.8)
        XCTAssertEqual(displayModel.selectionIndex[selected.id]?.usedPercent, 0.8)
        XCTAssertEqual(
            displayModel.selectablePoints.filter { $0.date == base }.map(\.usedPercent),
            [0.8]
        )
        XCTAssertEqual(displayModel.estimatePoints.map(\.usedPercent), [0.7])
        XCTAssertEqual(displayModel.renderedEstimatePoints.map(\.usedPercent), [0.7])
        XCTAssertTrue(projected.isProjected)
        XCTAssertEqual(projected.usedPercent, 0.7)
        XCTAssertEqual(displayModel.selectionIndex[projected.id]?.usedPercent, 0.7)
    }

    func testLongRegularHourlyHistoryDownsamplesAfterSegmentation() throws {
        let base = Date(timeIntervalSince1970: 1_800_000_000)
        let activity = (0..<480).map { index in
            UsageActivityPoint(
                date: base.addingTimeInterval(Double(index) * 3_600),
                tokens: index + 1,
                usedPercent: 0.1 + (Double(index) / 479) * 0.7
            )
        }
        let snapshot = UsageAnalyticsSnapshot(
            provider: .codex,
            activity: activity,
            projection: [],
            modelBreakdowns: [],
            heatmap: [],
            provenance: Provenance(
                source: "Gateway",
                observedAt: base,
                quality: .observed,
                connector: .healthy
            )
        )

        let displayModel = UsageProjectionDisplayModel(analytics: snapshot, window: nil)
        let rendered = displayModel.renderedActualSegments.flatMap(\.points)

        XCTAssertEqual(displayModel.renderedActualSegments.count, 1)
        XCTAssertEqual(rendered.count, UsageProjectionDisplayModel.maximumRenderedSamples)
        XCTAssertLessThanOrEqual(rendered.count, UsageProjectionDisplayModel.maximumRenderedSamples)
        XCTAssertEqual(displayModel.renderedActualPoints, rendered)

        let first = try XCTUnwrap(rendered.first)
        let last = try XCTUnwrap(rendered.last)
        XCTAssertEqual(first.date, activity[0].date)
        XCTAssertEqual(first.usedPercent, activity[0].usedPercent)
        XCTAssertEqual(last.date, activity[479].date)
        XCTAssertEqual(last.usedPercent, activity[479].usedPercent)

        let selected = try XCTUnwrap(
            displayModel.nearestSelection(to: base.addingTimeInterval(4_500))
        )
        XCTAssertFalse(selected.isProjected)
        XCTAssertEqual(selected.date, base.addingTimeInterval(3_600))
    }

    func testTightBudgetRetainsWholeCadenceSegmentsAndLatestObservation() throws {
        let base = Date(timeIntervalSince1970: 1_800_000_000)
        let activity = (0..<121).flatMap { index -> [UsageActivityPoint] in
            let segmentStart = base.addingTimeInterval(Double(index) * 10_800)
            let firstValue = 0.1 + Double(index) * 0.001
            return [
                UsageActivityPoint(
                    date: segmentStart,
                    tokens: index * 2 + 1,
                    usedPercent: firstValue
                ),
                UsageActivityPoint(
                    date: segmentStart.addingTimeInterval(3_600),
                    tokens: index * 2 + 2,
                    usedPercent: firstValue + 0.0005
                )
            ]
        }
        let snapshot = UsageAnalyticsSnapshot(
            provider: .codex,
            activity: activity,
            projection: [],
            modelBreakdowns: [],
            heatmap: [],
            provenance: Provenance(
                source: "Gateway",
                observedAt: base,
                quality: .observed,
                connector: .healthy
            )
        )

        let displayModel = UsageProjectionDisplayModel(analytics: snapshot, window: nil)
        let renderedSegments = displayModel.renderedActualSegments
        let renderedPoints = renderedSegments.flatMap(\.points)

        XCTAssertEqual(renderedSegments.count, 120)
        XCTAssertTrue(renderedSegments.allSatisfy { $0.points.count == 2 })
        XCTAssertLessThanOrEqual(
            renderedPoints.count,
            UsageProjectionDisplayModel.maximumRenderedSamples
        )
        XCTAssertEqual(renderedPoints.count, 240)
        XCTAssertEqual(renderedPoints.first?.date, activity.first?.date)
        XCTAssertEqual(renderedPoints.last?.date, activity.last?.date)
        XCTAssertEqual(renderedPoints.last?.usedPercent, activity.last?.usedPercent)

        let sourceByStartDate = Dictionary(
            uniqueKeysWithValues: stride(from: 0, to: activity.count, by: 2).map { index in
                (activity[index].date, Array(activity[index..<(index + 2)]))
            }
        )
        XCTAssertTrue(renderedSegments.allSatisfy { segment in
            guard let first = segment.points.first,
                  let source = sourceByStartDate[first.date] else {
                return false
            }
            return segment.points.map(\.date) == source.map(\.date)
                && segment.points.map(\.usedPercent) == source.map(\.usedPercent)
        })
    }

    func testLiveHistoryProjectionStaysContinuousAndSelectionRemainsGapSafe() throws {
        let base = Date(timeIntervalSince1970: 1_800_000_000)
        let latestObserved = base.addingTimeInterval(10_800)
        let resetAt = base.addingTimeInterval(18_000)
        let history = [
            UsageHistoryEntry(
                provider: .codex,
                window: "five_hour",
                durationMinutes: 300,
                usedPercent: 20,
                resetAt: resetAt,
                observedAt: base,
                source: "Gateway",
                connectorState: .healthy
            ),
            UsageHistoryEntry(
                provider: .codex,
                window: "five_hour",
                durationMinutes: 300,
                usedPercent: 35,
                resetAt: resetAt,
                observedAt: latestObserved,
                source: "Gateway",
                connectorState: .healthy
            )
        ]
        let snapshot = UsageAnalyticsSnapshot(
            provider: .codex,
            windowID: "five_hour",
            activity: [],
            projection: [
                UsageProjectionPoint(date: latestObserved, usedPercent: 0.35),
                UsageProjectionPoint(date: resetAt, usedPercent: 0.65)
            ],
            modelBreakdowns: [],
            heatmap: [],
            provenance: Provenance(
                source: "Gateway",
                observedAt: latestObserved,
                quality: .observed,
                connector: .healthy
            ),
            history: history
        )
        let window = UsageWindow(
            id: "five_hour",
            label: "5-hour",
            resetAt: resetAt,
            durationMinutes: 300
        )

        // This mirrors UsageAnalyticsHistoryBuilder's live shape: activity is
        // empty, history is observed, and projection is anchor plus endpoint.
        let displayModel = UsageProjectionDisplayModel(analytics: snapshot, window: window)

        XCTAssertEqual(displayModel.renderedActualSegments.map { $0.points.count }, [1, 1])
        XCTAssertEqual(displayModel.renderedEstimateSegments.map { $0.points.count }, [2])
        XCTAssertEqual(
            displayModel.renderedEstimateSegments.flatMap(\.points).map(\.usedPercent),
            [0.35, 0.65]
        )

        let estimateSelection = try XCTUnwrap(
            displayModel.nearestSelection(to: latestObserved.addingTimeInterval(6_600))
        )
        XCTAssertTrue(estimateSelection.isProjected)
        XCTAssertEqual(estimateSelection.date, resetAt)

        let observedTieSelection = try XCTUnwrap(
            displayModel.nearestSelection(to: latestObserved.addingTimeInterval(3_600))
        )
        XCTAssertFalse(observedTieSelection.isProjected)
        XCTAssertEqual(observedTieSelection.date, latestObserved)

        XCTAssertNil(
            displayModel.nearestSelection(to: base.addingTimeInterval(5_400)),
            "An observed cadence gap must not fall through to the estimate series."
        )
    }

    func testSelectionReturnsNoDataInsideExplicitGap() {
        let base = Date(timeIntervalSince1970: 1_800_000_000)
        let series = LifeOSChartSeries(
            id: "observed",
            label: "Observed",
            kind: .observed,
            points: [
                LifeOSChartPoint(timestamp: base, value: 1),
                LifeOSChartPoint(timestamp: base.addingTimeInterval(3_600), value: nil),
                LifeOSChartPoint(timestamp: base.addingTimeInterval(7_200), value: 3),
            ],
            source: "Gateway",
            provenance: .observed
        )

        let result = LifeOSChartKit.selectionResult(
            in: [series],
            to: base.addingTimeInterval(5_400),
            expectedCadence: 3_600
        )

        XCTAssertEqual(result.noDataSelection?.reason, .explicitGap)
        XCTAssertNil(result.selectedDatum)
    }

    func testSelectionReturnsNoDataInsideCadenceBreak() {
        let base = Date(timeIntervalSince1970: 1_800_000_000)
        let series = LifeOSChartSeries(
            id: "observed",
            label: "Observed",
            kind: .observed,
            points: [
                LifeOSChartPoint(timestamp: base, value: 1),
                LifeOSChartPoint(timestamp: base.addingTimeInterval(7_200), value: 3),
            ],
            source: "Gateway",
            provenance: .observed
        )

        let result = LifeOSChartKit.selectionResult(
            in: [series],
            to: base.addingTimeInterval(3_600),
            expectedCadence: 3_600
        )

        XCTAssertEqual(result.noDataSelection?.reason, .cadenceBreak)
        XCTAssertNil(result.selectedDatum)
    }

    func testObservedGapBlocksDistantCrossSeriesFallback() {
        let base = Date(timeIntervalSince1970: 1_800_000_000)
        let observed = LifeOSChartSeries(
            id: "observed",
            label: "Observed",
            kind: .observed,
            points: [
                LifeOSChartPoint(timestamp: base, value: 1),
                LifeOSChartPoint(timestamp: base.addingTimeInterval(3_600), value: nil),
                LifeOSChartPoint(timestamp: base.addingTimeInterval(7_200), value: 3),
            ],
            source: "Gateway",
            provenance: .observed
        )
        let target = LifeOSChartSeries(
            id: "target",
            label: "Target",
            kind: .target,
            points: [
                LifeOSChartPoint(timestamp: base.addingTimeInterval(-86_400), value: 0),
                LifeOSChartPoint(timestamp: base.addingTimeInterval(86_400), value: 4),
            ],
            source: "Plan",
            provenance: .estimated
        )

        let result = LifeOSChartKit.selectionResult(
            in: [observed, target],
            to: base.addingTimeInterval(5_400),
            expectedCadence: 3_600
        )

        XCTAssertEqual(result.noDataSelection?.reason, .explicitGap)
        XCTAssertNil(result.selectedDatum)
    }

    func testSeriesStylesMatchSharedVisualContract() {
        let observed = LifeOSChartSeriesKind.observed.style
        XCTAssertEqual(observed.lineStyle, .solid)
        XCTAssertEqual(observed.lineWidth, 2.25, accuracy: 0.0001)
        XCTAssertEqual(observed.areaOpacity, 0.14, accuracy: 0.0001)
        XCTAssertEqual(observed.dashPattern.map(Double.init), [])

        let target = LifeOSChartSeriesKind.target.style
        XCTAssertEqual(target.lineStyle, .dashed)
        XCTAssertEqual(target.lineWidth, 1.25, accuracy: 0.0001)
        XCTAssertEqual(target.dashPattern.map(Double.init), [6, 4])
        XCTAssertEqual(LifeOSChartSeriesKind.target.color, LifeOSTokens.Series.target)

        let estimate = LifeOSChartSeriesKind.estimate.style
        XCTAssertEqual(estimate.lineStyle, .dashed)
        XCTAssertEqual(estimate.lineWidth, 1.75, accuracy: 0.0001)
        XCTAssertEqual(estimate.dashPattern.map(Double.init), [3, 3])
        XCTAssertEqual(LifeOSChartSeriesKind.estimate.color, LifeOSTokens.Series.estimate)

        let history = LifeOSChartSeriesKind.history.style
        XCTAssertEqual(history.lineStyle, .dotted)
        XCTAssertEqual(history.lineWidth, 1.25, accuracy: 0.0001)
        XCTAssertEqual(history.dashPattern.map(Double.init), [1, 3])
    }

    func testTooltipFrameStaysInsidePlotInset() {
        let bounds = CGRect(x: 0, y: 0, width: 200, height: 100)
        let frame = LifeOSChartKit.boundedTooltipFrame(
            anchor: CGPoint(x: 198, y: 2),
            size: CGSize(width: 90, height: 40),
            in: bounds
        )

        XCTAssertTrue(bounds.insetBy(dx: 8, dy: 8).contains(frame))
    }

    func testTimestampMappingClampsOverlayToExplicitDomain() throws {
        let start = Date(timeIntervalSince1970: 1_800_000_000)
        let end = start.addingTimeInterval(3_600)
        let plot = CGRect(x: 20, y: 10, width: 180, height: 120)

        let before = try XCTUnwrap(
            LifeOSChartKit.timestamp(forPlotX: 0, in: plot, domain: start...end)
        )
        let middle = try XCTUnwrap(
            LifeOSChartKit.timestamp(forPlotX: plot.midX, in: plot, domain: start...end)
        )
        let after = try XCTUnwrap(
            LifeOSChartKit.timestamp(forPlotX: 400, in: plot, domain: start...end)
        )

        XCTAssertEqual(before, start)
        XCTAssertEqual(middle, start.addingTimeInterval(1_800))
        XCTAssertEqual(after, end)
    }

    func testNearestPointUsesSharedTimestampSelectionForSimpleSeries() throws {
        let base = Date(timeIntervalSince1970: 1_800_000_000)
        let selected = try XCTUnwrap(
            LifeOSChartKit.nearestPoint(
                in: [
                    LifeOSChartPoint(timestamp: base, value: 1),
                    LifeOSChartPoint(timestamp: base.addingTimeInterval(600), value: 2)
                ],
                to: base.addingTimeInterval(450)
            )
        )

        XCTAssertEqual(selected.timestamp, base.addingTimeInterval(600))
        XCTAssertEqual(selected.value, 2)
    }

    func testTooltipFrameFitsEvenWhenInsetExceedsTinyBounds() {
        let bounds = CGRect(x: 0, y: 0, width: 10, height: 10)
        let frame = LifeOSChartKit.boundedTooltipFrame(
            anchor: CGPoint(x: 5, y: 5),
            size: CGSize(width: 80, height: 40),
            in: bounds,
            inset: 20
        )

        XCTAssertTrue(bounds.contains(frame))
        XCTAssertEqual(frame.size, .zero)
    }

    func testAccessibilitySummaryKeepsProvenanceVisible() {
        let summary = LifeOSChartAccessibilitySummary(
            title: "Usage",
            unit: "%",
            source: "Gateway",
            provenance: .demo,
            value: "58",
            timestamp: Date(timeIntervalSince1970: 1_800_000_000)
        )

        XCTAssertTrue(summary.spokenSummary.contains("DEMO · NOT LIVE"))
        XCTAssertTrue(summary.spokenSummary.contains("Source Gateway"))
    }
}
