import SwiftUI
import Charts

// MARK: - Projection chart (02-charts-rings-widgets.md §2) — 4-series model.
//
// Target (neutral dashed) / Actual (blue solid, area fill) / Current estimate (green dashed) /
// Past estimate (metadata dotted, only if a prior-estimate series is actually stored — it is not,
// see DemoUsageAnalytics / UsageAnalyticsSnapshot, so this series is omitted rather than
// fabricated).

// MARK: - Pure inspection reconciliation

/// Identity for one Usage dataset. Observation values and timestamps belong to
/// revisions; account identity is the existing display label until a stable ID
/// is available from the source model.
struct UsageChartDatasetKey: Equatable, Sendable {
    let provider: Provider
    let accountScope: String
    let windowID: String?
    let durationMinutes: Int?
    let metric: String
    let source: String
    let provenanceClass: DataQuality

    init(
        provider: Provider,
        accountScope: String,
        windowID: String?,
        durationMinutes: Int?,
        metric: String,
        source: String,
        provenanceClass: DataQuality
    ) {
        self.provider = provider
        self.accountScope = accountScope
        self.windowID = windowID
        self.durationMinutes = durationMinutes
        self.metric = metric
        self.source = source
        self.provenanceClass = provenanceClass
    }

    init(
        analytics: UsageAnalyticsSnapshot,
        window: UsageWindow?,
        accountScope: String,
        metric: String
    ) {
        self.init(
            provider: analytics.provider,
            accountScope: accountScope,
            windowID: window?.id ?? analytics.windowID,
            durationMinutes: window?.durationMinutes,
            metric: metric,
            source: analytics.provenance.source,
            provenanceClass: analytics.provenance.quality
        )
    }

    init(
        providerSnapshot: ProviderSnapshot,
        analytics: UsageAnalyticsSnapshot,
        window: UsageWindow?,
        metric: String
    ) {
        self.init(
            analytics: analytics,
            window: window,
            accountScope: providerSnapshot.accountLabel,
            metric: metric
        )
    }
}

enum UsageChartResetEpoch: Equatable, Sendable {
    case unknown
    case boundary(Date)
}

/// An inspection viewport is either derived by the chart or an absolute date
/// interval supplied by the user. Invalid explicit values are normalized to
/// automatic by the reducer.
enum UsageChartInspectionViewport: Equatable {
    case automatic
    case explicit(start: Date, end: Date)

    init?(start: Date, end: Date) {
        guard start.timeIntervalSinceReferenceDate.isFinite,
              end.timeIntervalSinceReferenceDate.isFinite,
              end > start else {
            return nil
        }
        self = .explicit(start: start, end: end)
    }

    var absoluteInterval: DateInterval? {
        guard case let .explicit(start, end) = self,
              start.timeIntervalSinceReferenceDate.isFinite,
              end.timeIntervalSinceReferenceDate.isFinite,
              end > start else {
            return nil
        }
        return DateInterval(start: start, end: end)
    }

    var interval: DateInterval? { absoluteInterval }

    var validated: Self {
        absoluteInterval == nil ? .automatic : self
    }
}

/// Resolves the stored absolute viewport against the accepted model. The
/// model's extent is always the outer bound, so a contracted revision cannot
/// leave the chart looking beyond the data it accepted.
enum UsageChartEffectiveDomain {
    static let minimumDuration: TimeInterval = 60

    static func range(
        earliest: Date?,
        latest: Date?,
        viewport: UsageChartInspectionViewport
    ) -> ClosedRange<Date>? {
        guard let earliest,
              let latest,
              earliest.timeIntervalSinceReferenceDate.isFinite,
              latest.timeIntervalSinceReferenceDate.isFinite,
              latest >= earliest else {
            return nil
        }

        let extent = latest.timeIntervalSince(earliest)
        guard extent.isFinite else { return nil }
        guard latest > earliest else {
            // Charts needs a non-zero domain for a singleton. Keep the only
            // accepted point at the right edge and add bounded history space.
            return latest.addingTimeInterval(-minimumDuration)...latest
        }

        switch viewport.validated {
        case .automatic:
            // A short model is truthful as-is; extending it would invent a
            // second endpoint or future blank space.
            return earliest...latest
        case .explicit(let requestedStart, let requestedEnd):
            let clampedStart = min(max(requestedStart, earliest), latest)
            let clampedEnd = min(max(requestedEnd, earliest), latest)
            guard clampedEnd > clampedStart else {
                return extent < minimumDuration
                    ? earliest...latest
                    : latest.addingTimeInterval(-minimumDuration)...latest
            }

            let visibleDuration = clampedEnd.timeIntervalSince(clampedStart)
            guard extent >= minimumDuration, visibleDuration < minimumDuration else {
                return clampedStart...clampedEnd
            }

            if clampedEnd.timeIntervalSince(earliest) >= minimumDuration {
                return clampedEnd.addingTimeInterval(-minimumDuration)...clampedEnd
            }
            return earliest...min(
                latest,
                earliest.addingTimeInterval(minimumDuration)
            )
        }
    }
}

struct UsageChartInspectionUpdate {
    enum Phase {
        case loading
        case resolvedPopulated(UsageProjectionDisplayModel)
        case resolvedAuthoritativeEmpty
        case failed
    }

    let key: UsageChartDatasetKey
    let resetEpoch: UsageChartResetEpoch
    let generation: Int
    let authority: UsagePresentationAuthority
    let phase: Phase

    init(
        key: UsageChartDatasetKey,
        resetEpoch: UsageChartResetEpoch,
        generation: Int,
        phase: Phase,
        authority: UsagePresentationAuthority = .unknown
    ) {
        self.key = key
        self.resetEpoch = resetEpoch
        self.generation = generation
        self.authority = authority
        self.phase = phase
    }
}

/// Pure state transitions for selection and viewport inspection. The existing
/// chart view can adopt this later without changing its rendering contract.
struct UsageChartInspectionState {
    enum Status: Equatable {
        case loading
        case resolved
        case authoritativeEmpty
        case refreshing
        case stale
        case failed
    }

    private(set) var key: UsageChartDatasetKey?
    private(set) var resetEpoch: UsageChartResetEpoch?
    private(set) var generation = 0
    private(set) var presentationAuthority: UsagePresentationAuthority = .unknown
    private(set) var status: Status = .loading
    private(set) var acceptedModel: UsageProjectionDisplayModel?
    private(set) var selectedPointID: String?
    private(set) var viewport: UsageChartInspectionViewport = .automatic
    private var hasAcceptedUpdate = false

    var model: UsageProjectionDisplayModel? { acceptedModel }
    var selectedID: String? { selectedPointID }
    var isRefreshing: Bool { status == .refreshing }
    var isStale: Bool { status == .stale }

    mutating func reduce(_ update: UsageChartInspectionUpdate) {
        guard !hasAcceptedUpdate || update.generation >= generation else { return }

        let sameIdentity = hasAcceptedUpdate
            && key == update.key
            && resetEpoch == update.resetEpoch
        let effectiveAuthority: UsagePresentationAuthority
        if update.authority == .unknown, sameIdentity {
            effectiveAuthority = presentationAuthority
        } else {
            effectiveAuthority = update.authority
        }
        let identityChanged = !sameIdentity
        hasAcceptedUpdate = true
        key = update.key
        resetEpoch = update.resetEpoch
        generation = update.generation
        presentationAuthority = effectiveAuthority

        if identityChanged {
            selectedPointID = nil
            viewport = .automatic
            acceptedModel = nil
            installNewIdentity(phase: update.phase, authority: effectiveAuthority)
            return
        }

        if effectiveAuthority == .authoritativeEmpty {
            acceptedModel = nil
            selectedPointID = nil
            switch update.phase {
            case .loading:
                status = .loading
            case .resolvedAuthoritativeEmpty:
                status = .authoritativeEmpty
            case .failed:
                status = .failed
            case .resolvedPopulated:
                // The authority is stronger than a stale or inconsistent
                // lifecycle label and must never install cached analytics.
                status = .authoritativeEmpty
            }
            return
        }

        switch update.phase {
        case .loading:
            status = acceptedModel == nil ? .loading : .refreshing
        case .resolvedPopulated(let model):
            acceptedModel = model
            status = .resolved
            reconcileSelection()
        case .resolvedAuthoritativeEmpty:
            acceptedModel = nil
            selectedPointID = nil
            status = .authoritativeEmpty
        case .failed:
            status = acceptedModel == nil ? .failed : .stale
        }
    }

    mutating func select(pointID: String?) {
        guard let pointID else {
            selectedPointID = nil
            return
        }
        selectedPointID = acceptedModel?.selectionIndex[pointID] == nil ? nil : pointID
    }

    mutating func setViewport(_ viewport: UsageChartInspectionViewport) {
        self.viewport = viewport.validated
    }

    private mutating func installNewIdentity(
        phase: UsageChartInspectionUpdate.Phase,
        authority: UsagePresentationAuthority
    ) {
        if authority == .authoritativeEmpty {
            switch phase {
            case .loading:
                status = .loading
            case .resolvedAuthoritativeEmpty, .resolvedPopulated:
                status = .authoritativeEmpty
            case .failed:
                status = .failed
            }
            return
        }
        switch phase {
        case .loading:
            status = .loading
        case .resolvedPopulated(let model):
            acceptedModel = model
            status = .resolved
        case .resolvedAuthoritativeEmpty:
            status = .authoritativeEmpty
        case .failed:
            status = .failed
        }
    }

    private mutating func reconcileSelection() {
        guard let selectedPointID else { return }
        if acceptedModel?.selectionIndex[selectedPointID] == nil {
            self.selectedPointID = nil
        }
    }
}

enum UsageChartPresentationPolicy {
    static func seedModel(
        for updateKind: UsagePresentationUpdateKind,
        authority: UsagePresentationAuthority,
        analytics: UsageAnalyticsSnapshot,
        window: UsageWindow?
    ) -> UsageProjectionDisplayModel? {
        switch updateKind {
        case .initial:
            guard authority.permitsChartSeed else { return nil }
            let model = UsageProjectionDisplayModel(analytics: analytics, window: window)
            return model.actualPoints.isEmpty ? nil : model
        case .loading, .failed, .cancelled:
            guard authority == .observed else { return nil }
            let model = UsageProjectionDisplayModel(analytics: analytics, window: window)
            return model.actualPoints.isEmpty ? nil : model
        case .resolved, .authoritativeEmpty:
            return nil
        }
    }
}

struct UsageProjectionSegment: Identifiable, Equatable {
    let id: String
    let points: [UsageProjectionPoint]
}

/// One revision-keyed projection model owns sorting, filtering, selection
/// indexing, and chart downsampling. The full arrays remain authoritative for
/// keyboard selection and accessibility; only the rendered arrays are bounded.
struct UsageProjectionDisplayModel {
    static let maximumRenderedSamples = 240
    /// Usage telemetry is emitted hourly. A missing sample or an interval over
    /// 1.5 hours is a real gap and must never be bridged by the chart.
    static let telemetryCadence: TimeInterval = 3_600

    let actualPoints: [UsageProjectionPoint]
    let estimatePoints: [UsageProjectionPoint]
    let targetPoints: [UsageProjectionPoint]
    let renderedActualPoints: [UsageProjectionPoint]
    let renderedEstimatePoints: [UsageProjectionPoint]
    let renderedTargetPoints: [UsageProjectionPoint]
    let renderedActualSegments: [UsageProjectionSegment]
    let renderedEstimateSegments: [UsageProjectionSegment]
    let renderedTargetSegments: [UsageProjectionSegment]
    let selectablePoints: [UsageSelectionPoint]
    let selectionIndex: [String: UsageSelectionPoint]
    let selectionOffsets: [String: Int]
    let earliestDate: Date?
    let latestDate: Date?
    let revisionID: String
    private let selectionSeries: [CachedSelectionSeries]

    init(analytics: UsageAnalyticsSnapshot, window: UsageWindow?) {
        let sortedActivity = Self.stableSortedByDate(analytics.activity, by: { $0.date })
        let activityInWindow: [UsageActivityPoint]
        if let resetAt = window?.resetAt, let durationMinutes = window?.durationMinutes {
            let start = resetAt.addingTimeInterval(-Double(durationMinutes) * 60)
            activityInWindow = sortedActivity.filter { point in
                point.date >= start && point.date <= resetAt
            }
        } else {
            activityInWindow = sortedActivity
        }

        let actualSource: [UsageProjectionPoint]
        if !activityInWindow.isEmpty {
            actualSource = activityInWindow.map {
                UsageProjectionPoint(date: $0.date, usedPercent: $0.usedPercent)
            }
        } else {
            actualSource = Self.stableSortedByDate(
                analytics.history.map {
                    UsageProjectionPoint(date: $0.observedAt, usedPercent: $0.usedPercent / 100)
                },
                by: { $0.date }
            )
        }
        let actualSeries = Self.normalizedSeries(
            for: actualSource,
            expectedCadence: Self.telemetryCadence
        )
        let actual = actualSeries.points

        let estimateSource: [UsageProjectionPoint]
        if !actual.isEmpty, analytics.windowID == window?.id {
            let lastObservedDate = actual.last?.date ?? .distantPast
            estimateSource = Self.stableSortedByDate(
                analytics.projection
                .filter { $0.date >= lastObservedDate }
                .filter { point in
                    guard let resetAt = window?.resetAt else { return true }
                    return point.date <= resetAt
                },
                by: { $0.date }
            )
        } else {
            estimateSource = []
        }
        let estimateSeries = Self.normalizedSeries(
            for: estimateSource,
            expectedCadence: nil
        )
        let estimate = estimateSeries.points

        let targetSource: [UsageProjectionPoint]
        if let start = actual.first,
           let resetAt = window?.resetAt,
           resetAt > start.date {
            let totalSeconds = resetAt.timeIntervalSince(start.date)
            if totalSeconds > 0 {
                targetSource = (0...12).map { step in
                    let fraction = Double(step) / 12
                    let date = start.date.addingTimeInterval(totalSeconds * fraction)
                    let value = start.usedPercent + (1 - start.usedPercent) * fraction
                    return UsageProjectionPoint(date: date, usedPercent: value)
                }
            } else {
                targetSource = []
            }
        } else {
            targetSource = []
        }
        let targetSeries = Self.normalizedSeries(
            for: targetSource,
            expectedCadence: nil
        )
        let target = targetSeries.points

        let selectable = Self.mergeSelectable(actual: actual, estimate: estimate)
        var index: [String: UsageSelectionPoint] = [:]
        index.reserveCapacity(selectable.count)
        var offsets: [String: Int] = [:]
        offsets.reserveCapacity(selectable.count)
        for (offset, point) in selectable.enumerated() {
            index[point.id] = point
            offsets[point.id] = offset
        }

        var earliestDate: Date?
        var latestDate: Date?
        for point in actual + estimate + target {
            earliestDate = earliestDate.map { min($0, point.date) } ?? point.date
            latestDate = latestDate.map { max($0, point.date) } ?? point.date
        }

        let renderedActual = Self.renderedSeries(
            from: actualSeries,
            seriesID: "actual"
        )
        let renderedEstimate = Self.renderedSeries(
            from: estimateSeries,
            seriesID: "estimate"
        )
        let renderedTarget = Self.renderedSeries(
            from: targetSeries,
            seriesID: "target"
        )

        self.actualPoints = actual
        self.estimatePoints = estimate
        self.targetPoints = target
        self.renderedActualPoints = renderedActual.points
        self.renderedEstimatePoints = renderedEstimate.points
        self.renderedTargetPoints = renderedTarget.points
        self.renderedActualSegments = renderedActual.segments
        self.renderedEstimateSegments = renderedEstimate.segments
        self.renderedTargetSegments = renderedTarget.segments
        self.selectablePoints = selectable
        self.selectionIndex = index
        self.selectionOffsets = offsets
        self.earliestDate = earliestDate
        self.latestDate = latestDate
        self.selectionSeries = [
            Self.cachedSelectionSeries(
                from: actualSeries,
                kind: .observed
            ),
            Self.cachedSelectionSeries(
                from: estimateSeries,
                kind: .estimate
            )
        ]
        self.revisionID = [
            window?.id ?? "none",
            analytics.windowID ?? "none",
            Self.signature(actual),
            Self.signature(estimate),
            Self.signature(target)
        ].joined(separator: "|")
    }

    private struct RenderedSeries {
        let points: [UsageProjectionPoint]
        let segments: [UsageProjectionSegment]
    }

    /// This cache is built with the display model revision. Pointer movement
    /// only performs binary searches over these normalized points; it never
    /// reconstructs a ChartKit series or re-normalizes the full history.
    private struct CachedSelectionSeries {
        let kind: LifeOSChartSeriesKind
        let points: [UsageProjectionPoint]
        let explicitGapTimestamps: Set<Date>
        let explicitGapIntervals: [DateInterval]
        let cadenceBreakIntervals: [DateInterval]

        func noDataReason(at date: Date) -> LifeOSChartSelectionNoDataReason? {
            if explicitGapTimestamps.contains(date)
                || UsageProjectionDisplayModel.contains(explicitGapIntervals, date: date) {
                return .explicitGap
            }
            guard !points.isEmpty else { return .noValidData }
            if UsageProjectionDisplayModel.contains(cadenceBreakIntervals, date: date) {
                return .cadenceBreak
            }
            return nil
        }

        func nearestPoint(to date: Date) -> UsageProjectionPoint? {
            guard !points.isEmpty else { return nil }
            let insertion = UsageProjectionDisplayModel.lowerBound(in: points, for: date)
            if insertion == 0 { return points[0] }
            if insertion == points.count { return points[points.count - 1] }

            let before = points[insertion - 1]
            let after = points[insertion]
            let beforeDistance = abs(before.date.timeIntervalSince(date))
            let afterDistance = abs(after.date.timeIntervalSince(date))
            return beforeDistance <= afterDistance ? before : after
        }
    }

    /// Normalizes and splits the authoritative series before applying the
    /// display budget. Downsampling a regular series first would make its
    /// retained points appear farther apart and could create false cadence
    /// breaks. The flattened point array is derived from the exact rendered
    /// segments so the two render representations cannot drift.
    private static func renderedSeries(
        from normalizedSeries: NormalizedSeries,
        seriesID: String
    ) -> RenderedSeries {
        let normalizedSegments = normalizedSeries.segments
        guard !normalizedSegments.isEmpty else {
            return RenderedSeries(points: [], segments: [])
        }

        let budgets = renderingBudgets(
            for: normalizedSegments,
            maximumCount: maximumRenderedSamples
        )
        var renderedSegments: [UsageProjectionSegment] = []
        renderedSegments.reserveCapacity(normalizedSegments.count)

        for (offset, segment) in normalizedSegments.enumerated() {
            let points = bounded(segment, maximumCount: budgets[offset])
            guard !points.isEmpty else { continue }
            renderedSegments.append(
                UsageProjectionSegment(
                    id: "\(seriesID)-segment-\(offset)",
                    points: points
                )
            )
        }

        return RenderedSeries(
            points: renderedSegments.flatMap(\.points),
            segments: renderedSegments
        )
    }

    /// One linear normalization pass over an already stably sorted source.
    /// The same normalized points feed rendering, selectable points,
    /// selectionIndex, and pointer selection, so a duplicate timestamp cannot
    /// disagree about which source occurrence wins.
    private struct NormalizedSeries {
        let points: [UsageProjectionPoint]
        let segments: [[UsageProjectionPoint]]
        let explicitGapTimestamps: Set<Date>
        let explicitGapIntervals: [DateInterval]
        let cadenceBreakIntervals: [DateInterval]
    }

    private static func normalizedSeries(
        for rawPoints: [UsageProjectionPoint],
        expectedCadence: TimeInterval?
    ) -> NormalizedSeries {
        guard !rawPoints.isEmpty else {
            return NormalizedSeries(
                points: [],
                segments: [],
                explicitGapTimestamps: [],
                explicitGapIntervals: [],
                cadenceBreakIntervals: []
            )
        }

        // Callers provide chronological input. Coalescing in source order
        // gives the last occurrence the same authority as ChartKit's contract
        // without sorting or rebuilding the series a second time.
        var ordered: [UsageProjectionPoint] = []
        ordered.reserveCapacity(rawPoints.count)
        for point in rawPoints where point.date.timeIntervalSinceReferenceDate.isFinite {
            if let lastDate = ordered.last?.date, lastDate == point.date {
                ordered[ordered.count - 1] = point
            } else {
                ordered.append(point)
            }
        }

        var points: [UsageProjectionPoint] = []
        points.reserveCapacity(ordered.count)
        var segments: [[UsageProjectionPoint]] = []
        var currentSegment: [UsageProjectionPoint] = []
        var explicitGapTimestamps = Set<Date>()
        var cadenceBreakIntervals: [DateInterval] = []
        var previousValid: UsageProjectionPoint?
        let cadence = expectedCadence.flatMap { $0 > 0 && $0.isFinite ? $0 : nil }

        for point in ordered {
            guard point.usedPercent.isFinite else {
                explicitGapTimestamps.insert(point.date)
                if !currentSegment.isEmpty {
                    segments.append(currentSegment)
                    currentSegment = []
                }
                previousValid = nil
                continue
            }

            if let previousValid,
               let cadence,
               point.date.timeIntervalSince(previousValid.date) > cadence * 1.5 {
                cadenceBreakIntervals.append(
                    DateInterval(start: previousValid.date, end: point.date)
                )
                if !currentSegment.isEmpty {
                    segments.append(currentSegment)
                    currentSegment = []
                }
            }

            points.append(point)
            currentSegment.append(point)
            previousValid = point
        }
        if !currentSegment.isEmpty {
            segments.append(currentSegment)
        }

        var explicitGapIntervals: [DateInterval] = []
        var index = 0
        while index < ordered.count {
            guard !ordered[index].usedPercent.isFinite else {
                index += 1
                continue
            }

            let gapStart = index
            while index < ordered.count, !ordered[index].usedPercent.isFinite {
                index += 1
            }
            let gapEnd = index
            if gapStart > 0,
               gapEnd < ordered.count,
               ordered[gapStart - 1].usedPercent.isFinite,
               ordered[gapEnd].usedPercent.isFinite {
                explicitGapIntervals.append(
                    DateInterval(
                        start: ordered[gapStart - 1].date,
                        end: ordered[gapEnd].date
                    )
                )
            }
        }
        return NormalizedSeries(
            points: points,
            segments: segments,
            explicitGapTimestamps: explicitGapTimestamps,
            explicitGapIntervals: explicitGapIntervals,
            cadenceBreakIntervals: cadenceBreakIntervals
        )
    }

    private static func cachedSelectionSeries(
        from normalizedSeries: NormalizedSeries,
        kind: LifeOSChartSeriesKind
    ) -> CachedSelectionSeries {
        return CachedSelectionSeries(
            kind: kind,
            points: normalizedSeries.points,
            explicitGapTimestamps: normalizedSeries.explicitGapTimestamps,
            explicitGapIntervals: normalizedSeries.explicitGapIntervals,
            cadenceBreakIntervals: normalizedSeries.cadenceBreakIntervals
        )
    }

    private static func stableSortedByDate<T>(
        _ points: [T],
        by date: (T) -> Date
    ) -> [T] {
        points.enumerated()
            .sorted { left, right in
                let leftDate = date(left.element)
                let rightDate = date(right.element)
                if leftDate != rightDate { return leftDate < rightDate }
                return left.offset < right.offset
            }
            .map(\.element)
    }

    private static func lowerBound(
        in points: [UsageProjectionPoint],
        for date: Date
    ) -> Int {
        var lower = 0
        var upper = points.count
        while lower < upper {
            let middle = lower + (upper - lower) / 2
            if points[middle].date < date {
                lower = middle + 1
            } else {
                upper = middle
            }
        }
        return lower
    }

    private static func contains(
        _ intervals: [DateInterval],
        date: Date
    ) -> Bool {
        var lower = 0
        var upper = intervals.count
        while lower < upper {
            let middle = lower + (upper - lower) / 2
            if intervals[middle].end <= date {
                lower = middle + 1
            } else {
                upper = middle
            }
        }
        guard lower < intervals.count else { return false }
        let interval = intervals[lower]
        return interval.start < date && date < interval.end
    }

    /// Allocates the global display budget without ever merging separate
    /// cadence segments. Two points per segment are reserved first when the
    /// budget allows it, which preserves both endpoints; remaining capacity is
    /// distributed proportionally in a deterministic pair of linear passes.
    private static func renderingBudgets(
        for segments: [[UsageProjectionPoint]],
        maximumCount: Int
    ) -> [Int] {
        guard maximumCount > 0, !segments.isEmpty else {
            return Array(repeating: 0, count: segments.count)
        }

        let counts = segments.map(\.count)
        let totalCount = counts.reduce(0, +)
        let budget = min(maximumCount, totalCount)
        guard budget > 0 else { return Array(repeating: 0, count: segments.count) }

        let endpointMinimums = counts.map { min(2, $0) }
        let endpointMinimumTotal = endpointMinimums.reduce(0, +)
        if endpointMinimumTotal <= budget {
            return allocate(
                minimums: endpointMinimums,
                counts: counts,
                budget: budget
            )
        }

        // A cadence segment is atomic once the budget is tight: rendering one
        // endpoint of a multi-point segment hides its latest value and makes
        // the segment misleading. Select whole endpoint pairs (or original
        // singletons) and distribute the retained segments chronologically.
        return wholeSegmentBudgets(counts: counts, budget: budget)
    }

    private static func wholeSegmentBudgets(
        counts: [Int],
        budget: Int
    ) -> [Int] {
        let costs = counts.map { min(2, $0) }
        var allocations = Array(repeating: 0, count: counts.count)
        var remaining = budget

        // Reserve both chronological boundaries whenever they fit. The latest
        // segment is reserved first so a tight budget never drops fresh data.
        let latestIndex = counts.count - 1
        if costs[latestIndex] <= remaining {
            allocations[latestIndex] = costs[latestIndex]
            remaining -= costs[latestIndex]
        }
        if latestIndex > 0, costs[0] <= remaining {
            allocations[0] = costs[0]
            remaining -= costs[0]
        }

        guard remaining > 0 else { return allocations }

        var availableSingletons = 0
        var availablePairs = 0
        for index in counts.indices where allocations[index] == 0 {
            if costs[index] == 1 {
                availableSingletons += 1
            } else {
                availablePairs += 1
            }
        }

        let singletonCount = min(availableSingletons, remaining)
        let pairCount: Int
        if singletonCount == availableSingletons {
            pairCount = min(availablePairs, (remaining - singletonCount) / 2)
        } else {
            pairCount = 0
        }

        selectEvenly(
            cost: 1,
            desiredCount: singletonCount,
            costs: costs,
            allocations: &allocations
        )
        selectEvenly(
            cost: 2,
            desiredCount: pairCount,
            costs: costs,
            allocations: &allocations
        )
        return allocations
    }

    /// Selects an exact number of candidates with evenly spaced ordinal ranks.
    /// The pass is linear and excludes the already reserved first/latest
    /// segments without searching the array repeatedly.
    private static func selectEvenly(
        cost: Int,
        desiredCount: Int,
        costs: [Int],
        allocations: inout [Int]
    ) {
        guard desiredCount > 0 else { return }

        var candidateCount = 0
        for index in costs.indices {
            if costs[index] == cost, allocations[index] == 0 {
                candidateCount += 1
            }
        }
        guard desiredCount <= candidateCount else { return }

        var seen = 0
        var selected = 0
        for index in costs.indices where selected < desiredCount {
            guard costs[index] == cost, allocations[index] == 0 else { continue }
            let targetRank: Int
            if desiredCount == 1 {
                targetRank = (candidateCount - 1) / 2
            } else {
                targetRank = (
                    selected * (candidateCount - 1) + (desiredCount - 1) / 2
                ) / (desiredCount - 1)
            }
            if seen == targetRank {
                allocations[index] = cost
                selected += 1
            }
            seen += 1
        }
    }

    private static func allocate(
        minimums: [Int],
        counts: [Int],
        budget: Int
    ) -> [Int] {
        var allocations = minimums
        let minimumTotal = allocations.reduce(0, +)
        let remaining = budget - minimumTotal
        guard remaining > 0 else { return allocations }

        let capacities = counts.indices.map { counts[$0] - allocations[$0] }
        let totalCapacity = capacities.reduce(0, +)
        guard totalCapacity > 0 else { return allocations }

        var assigned = 0
        for index in counts.indices {
            let capacity = capacities[index]
            guard capacity > 0 else { continue }
            let share = Double(remaining) * Double(capacity) / Double(totalCapacity)
            let extra = min(capacity, Int(share.rounded(.down)))
            allocations[index] += extra
            assigned += extra
        }

        // The proportional floors leave fewer than one unassigned point per
        // segment. A second pass removes that rounding remainder without a
        // repeated search or quadratic allocation loop.
        var remainder = remaining - assigned
        for index in counts.indices where remainder > 0 {
            guard allocations[index] < counts[index] else { continue }
            allocations[index] += 1
            remainder -= 1
        }
        return allocations
    }

    private static func bounded(
        _ points: [UsageProjectionPoint],
        maximumCount: Int = maximumRenderedSamples
    ) -> [UsageProjectionPoint] {
        guard maximumCount > 0, !points.isEmpty else { return [] }
        guard points.count > maximumCount else { return points }
        guard maximumCount > 1 else { return [points[0]] }

        let lastIndex = points.count - 1
        return (0..<maximumCount).map { index in
            let sourceIndex = Int(
                (Double(index) * Double(lastIndex) / Double(maximumCount - 1)).rounded()
            )
            return points[sourceIndex]
        }
    }

    /// Selects from observed and derived series with the cadence contract
    /// applied per series. An observed gap suppresses all fallback candidates,
    /// while a sparse estimate remains selectable between its anchor and reset
    /// endpoint.
    func nearestSelection(to date: Date) -> UsageSelectionPoint? {
        var candidates: [SelectionCandidate] = []
        candidates.reserveCapacity(selectionSeries.count)

        for (seriesIndex, series) in selectionSeries.enumerated() {
            if let reason = series.noDataReason(at: date),
               reason == .explicitGap || reason == .cadenceBreak {
                if series.kind == .observed { return nil }
                continue
            }
            guard let point = series.nearestPoint(to: date) else { continue }
            candidates.append(
                SelectionCandidate(
                    point: UsageSelectionPoint(
                        date: point.date,
                        usedPercent: point.usedPercent,
                        isProjected: series.kind == .estimate
                    ),
                    distance: abs(point.date.timeIntervalSince(date)),
                    seriesIndex: seriesIndex
                )
            )
        }

        return candidates.min(by: Self.isEarlierSelectionCandidate)?.point
    }

    private struct SelectionCandidate {
        let point: UsageSelectionPoint
        let distance: TimeInterval
        let seriesIndex: Int
    }

    private static func isEarlierSelectionCandidate(
        _ lhs: SelectionCandidate,
        _ rhs: SelectionCandidate
    ) -> Bool {
        if lhs.distance != rhs.distance { return lhs.distance < rhs.distance }
        if lhs.point.isProjected != rhs.point.isProjected {
            return !lhs.point.isProjected
        }
        if lhs.point.date != rhs.point.date {
            return lhs.point.date < rhs.point.date
        }
        return lhs.seriesIndex < rhs.seriesIndex
    }

    private static func mergeSelectable(
        actual: [UsageProjectionPoint],
        estimate: [UsageProjectionPoint]
    ) -> [UsageSelectionPoint] {
        var result: [UsageSelectionPoint] = []
        result.reserveCapacity(actual.count + estimate.count)
        var actualIndex = 0
        var estimateIndex = 0
        var seen = Set<String>()

        while actualIndex < actual.count || estimateIndex < estimate.count {
            let useActual: Bool
            if estimateIndex == estimate.count {
                useActual = true
            } else if actualIndex == actual.count {
                useActual = false
            } else {
                useActual = actual[actualIndex].date <= estimate[estimateIndex].date
            }
            let point: UsageSelectionPoint
            if useActual {
                let source = actual[actualIndex]
                actualIndex += 1
                point = UsageSelectionPoint(date: source.date, usedPercent: source.usedPercent, isProjected: false)
            } else {
                let source = estimate[estimateIndex]
                estimateIndex += 1
                point = UsageSelectionPoint(date: source.date, usedPercent: source.usedPercent, isProjected: true)
            }
            if seen.insert(point.id).inserted {
                result.append(point)
            }
        }
        return result
    }

    private static func signature(_ points: [UsageProjectionPoint]) -> String {
        points
            .map { "\($0.date.timeIntervalSinceReferenceDate):\($0.usedPercent)" }
            .joined(separator: ",")
    }
}

struct UsageProjectionChart: View {
    let provider: Provider
    let window: UsageWindow?
    let analytics: UsageAnalyticsSnapshot
    let accountScope: String
    let generation: Int
    let presentationAuthority: UsagePresentationAuthority
    let updateKind: UsagePresentationUpdateKind

    @State private var inspectionState: UsageChartInspectionState
    @State private var motion = LifeOSMotionLifecycle()
    @GestureState private var dragIsActive = false

    init(
        provider: Provider,
        window: UsageWindow?,
        analytics: UsageAnalyticsSnapshot,
        accountScope: String = "",
        generation: Int = 0,
        presentationAuthority: UsagePresentationAuthority = .unknown,
        updateKind: UsagePresentationUpdateKind = .resolved
    ) {
        self.provider = provider
        self.window = window
        self.analytics = analytics
        self.accountScope = accountScope
        self.generation = generation
        self.presentationAuthority = presentationAuthority
        self.updateKind = updateKind

        var initialState = UsageChartInspectionState()
        let key = Self.datasetKey(
            accountScope: accountScope,
            analytics: analytics,
            window: window
        )
        let resetEpoch = Self.resetEpoch(for: window)
        if let seedModel = UsageChartPresentationPolicy.seedModel(
            for: updateKind,
            authority: presentationAuthority,
            analytics: analytics,
            window: window
        ) {
            initialState.reduce(
                UsageChartInspectionUpdate(
                    key: key,
                    resetEpoch: resetEpoch,
                    generation: generation,
                    phase: .resolvedPopulated(seedModel),
                    authority: presentationAuthority
                )
            )
        }
        initialState.reduce(
            UsageChartInspectionUpdate(
                key: key,
                resetEpoch: resetEpoch,
                generation: generation,
                phase: Self.inspectionPhase(
                    for: updateKind,
                    authority: presentationAuthority,
                    analytics: analytics,
                    window: window
                ),
                authority: presentationAuthority
            )
        )
        _inspectionState = State(initialValue: initialState)
    }

    private struct InputRevision: Equatable {
        let analytics: UsageAnalyticsSnapshot
        let window: UsageWindow?
        let accountScope: String
        let generation: Int
        let presentationAuthority: UsagePresentationAuthority
        let updateKind: UsagePresentationUpdateKind
    }

    private var inputRevision: InputRevision {
        InputRevision(
            analytics: analytics,
            window: window,
            accountScope: accountScope,
            generation: generation,
            presentationAuthority: presentationAuthority,
            updateKind: updateKind
        )
    }

    private static func datasetKey(
        accountScope: String,
        analytics: UsageAnalyticsSnapshot,
        window: UsageWindow?
    ) -> UsageChartDatasetKey {
        UsageChartDatasetKey(
            analytics: analytics,
            window: window,
            accountScope: accountScope,
            metric: "used_percent"
        )
    }

    private static func resetEpoch(for window: UsageWindow?) -> UsageChartResetEpoch {
        guard let resetAt = window?.resetAt,
              resetAt.timeIntervalSinceReferenceDate.isFinite else {
            return .unknown
        }
        return .boundary(resetAt)
    }

    private static func inspectionPhase(
        for updateKind: UsagePresentationUpdateKind,
        authority: UsagePresentationAuthority,
        analytics: UsageAnalyticsSnapshot,
        window: UsageWindow?
    ) -> UsageChartInspectionUpdate.Phase {
        switch updateKind {
        case .resolved:
            guard authority != .authoritativeEmpty else { return .resolvedAuthoritativeEmpty }
            return .resolvedPopulated(UsageProjectionDisplayModel(analytics: analytics, window: window))
        case .authoritativeEmpty:
            return authority == .authoritativeEmpty ? .resolvedAuthoritativeEmpty : .loading
        case .failed:
            return .failed
        case .loading, .initial:
            if authority == .authoritativeEmpty {
                return .resolvedAuthoritativeEmpty
            }
            // These lifecycle packets contain no source result. Loading is the
            // reducer phase that retains an accepted model without installing
            // the packet's current values as resolved data.
            return .loading
        case .cancelled:
            // Cancellation is terminal for this request. The reducer retains
            // an accepted model as stale instead of showing endless refresh.
            return .failed
        }
    }

    private var acceptedModel: UsageProjectionDisplayModel? {
        inspectionState.acceptedModel
    }

    private var selectedID: String? {
        inspectionState.selectedID
    }

    // MARK: Series data

    /// Actual = observed activity points in the selected window. The activity transport is
    /// hourly, so a selected 5-hour window must not quietly plot older observations.
    private var actualPoints: [UsageProjectionPoint] {
        acceptedModel?.actualPoints ?? []
    }

    /// Current estimate = the forward projection engine's points, only when the analytics
    /// snapshot declares the same window. A range switch must never reuse another window's
    /// estimate, even if the dates happen to overlap.
    ///
    /// Requires at least one actual point before rendering: the projection already carries its
    /// bounded forward estimate, so a single observed anchor is enough to display that real
    /// gateway-derived series. `UsageProjectionEngine.points` always re-emits an anchor point at the
    /// observed date (equal to `lastObservedDate` in the common continuous-observation case) —
    /// that anchor must be KEPT (`>=`, not `>`) so the estimate line has a starting vertex to
    /// draw forward from. Excluding it left a single trailing point, which `LineMark` cannot
    /// stroke (a lone point draws no visible segment) — that was the root cause of the line
    /// never rendering.
    private var estimatePoints: [UsageProjectionPoint] {
        acceptedModel?.estimatePoints ?? []
    }

    /// Target = straight-line ideal pace from the first observed point to 100% at reset.
    private var targetPoints: [UsageProjectionPoint] {
        acceptedModel?.targetPoints ?? []
    }

    private var allSelectablePoints: [UsageSelectionPoint] {
        acceptedModel?.selectablePoints ?? []
    }

    private var selectedPoint: UsageSelectionPoint? {
        guard let selectedID else { return nil }
        return acceptedModel?.selectionIndex[selectedID]
    }

    private var chartDomain: ClosedRange<Date> {
        if let domain = UsageChartEffectiveDomain.range(
            earliest: acceptedModel?.earliestDate,
            latest: acceptedModel?.latestDate,
            viewport: inspectionState.viewport
        ) {
            return domain
        }
        let now = Date.now
        return now.addingTimeInterval(-UsageChartEffectiveDomain.minimumDuration)...now
    }

    private var chartHeight: CGFloat {
#if os(macOS)
        224
#else
        200
#endif
    }

    private func strokeStyle(for kind: LifeOSChartSeriesKind) -> StrokeStyle {
        if kind == .target {
            return StrokeStyle(
                lineWidth: 1,
                lineCap: .round,
                lineJoin: .round,
                dash: [2, 4]
            )
        }
        let style = kind.style
        return StrokeStyle(
            lineWidth: style.lineWidth,
            lineCap: .round,
            lineJoin: .round,
            dash: style.dashPattern
        )
    }

    private func seriesColor(for kind: LifeOSChartSeriesKind) -> Color {
        kind == .target ? LifeOSTokens.secondaryText : kind.color
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            VStack(alignment: .leading, spacing: 8) {
                sizedReferenceChart

                legend

                inspectionRow

                belowChartRows
            }
            .chartAvailability(
                isEmpty: actualPoints.isEmpty,
                identity: chartAvailabilityIdentity
            ) {
                UsageEmptyState(
                    title: "No observed usage points",
                    detail: "The gateway has not supplied quota observations for this window, so no chart range or projection is shown."
                )
            }
        }
        // This owner stays mounted even when the plot has no observations.
        .onAppear { reconcileInspectionState() }
        .onChange(of: inputRevision) { _, _ in
            reconcileInspectionState()
        }
        .onChange(of: dragIsActive) { _, active in
            if !active { finishScrub(cancelled: true) }
        }
        .onDisappear { finishScrub(cancelled: true) }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("\(provider.displayName) usage remaining chart")
        .accessibilityValue(chartAccessibilitySummary)
    }

    private var sizedReferenceChart: some View {
#if os(macOS)
        ViewThatFits(in: .horizontal) {
            interactiveReferenceChart
                .frame(minWidth: 960)
                .frame(height: 256)
            interactiveReferenceChart
                .frame(height: chartHeight)
        }
#else
        interactiveReferenceChart
            .frame(height: chartHeight)
#endif
    }

    private var interactiveReferenceChart: some View {
        referenceChart
            .chartOverlay { proxy in
                GeometryReader { geometry in
                    if let plotFrame = proxy.plotFrame {
                        let frame = geometry[plotFrame]
#if os(iOS)
                        FinanceDirectionalScrubOverlay(
                            onTap: { x in select(at: x, frame: frame) },
                            onChanged: { x in
                                motion.send(.scrub)
                                select(at: x, frame: frame)
                            },
                            onFinished: { cancelled in finishScrub(cancelled: cancelled) }
                        )
#elseif os(macOS)
                        Rectangle()
                            .fill(.clear)
                            .contentShape(Rectangle())
                            .gesture(
                                DragGesture(minimumDistance: 0)
                                    .updating($dragIsActive) { _, active, _ in active = true }
                                    .onChanged { value in
                                        motion.send(.scrub)
                                        select(at: value.location.x, frame: frame)
                                    }
                                    .onEnded { _ in finishScrub(cancelled: false) }
                            )
                            .onContinuousHover(coordinateSpace: .local) { phase in
                                switch phase {
                                case .active(let location):
                                    guard motion.phase != .scrubbing else { return }
                                    motion.send(.hover(true))
                                    guard let date = LifeOSChartKit.timestamp(
                                        forPlotX: location.x,
                                        in: frame,
                                        domain: chartDomain
                                    ) else { return }
                                    selectClosest(to: date)
                                case .ended:
                                    motion.send(.hover(false))
                                }
                            }
#endif
                        if let selectedPoint,
                           let x = proxy.position(forX: selectedPoint.date),
                           let y = proxy.position(forY: selectedPoint.usedPercent) {
                            ScrubBubble(
                                x: frame.origin.x + x,
                                y: frame.origin.y + y,
                                bounds: frame
                            ) {
                                Text("\(Int((1 - selectedPoint.usedPercent) * 100))% remaining")
                            }
                            .allowsHitTesting(false)
                        }
                    }
                }
            }
    }

    private func reconcileInspectionState() {
        finishScrub(cancelled: true)
        LifeOSMotion.withoutAnimation {
            let key = Self.datasetKey(
                accountScope: accountScope,
                analytics: analytics,
                window: window
            )
            let resetEpoch = Self.resetEpoch(for: window)
            let identityChanged = inspectionState.key != key
                || inspectionState.resetEpoch != resetEpoch
            if identityChanged,
               let seedModel = UsageChartPresentationPolicy.seedModel(
                   for: updateKind,
                   authority: presentationAuthority,
                   analytics: analytics,
                   window: window
               ) {
                // A provider/window change must adopt only the matching packet
                // model before applying its lifecycle status. The reducer's
                // identity transition still clears the previous dataset.
                inspectionState.reduce(
                    UsageChartInspectionUpdate(
                        key: key,
                        resetEpoch: resetEpoch,
                        generation: generation,
                        phase: .resolvedPopulated(seedModel),
                        authority: presentationAuthority
                    )
                )
            }
            inspectionState.reduce(
                UsageChartInspectionUpdate(
                    key: key,
                    resetEpoch: resetEpoch,
                    generation: generation,
                    phase: Self.inspectionPhase(
                        for: updateKind,
                        authority: presentationAuthority,
                        analytics: analytics,
                        window: window
                    ),
                    authority: presentationAuthority
                )
            )
        }
    }

    private func select(at x: CGFloat, frame: CGRect) {
        guard let date = LifeOSChartKit.timestamp(forPlotX: x, in: frame, domain: chartDomain) else { return }
        LifeOSMotion.withoutAnimation { selectClosest(to: date) }
    }

    private func finishScrub(cancelled: Bool) {
        LifeOSMotion.withoutAnimation {
            motion.send(cancelled ? .cancel : .end)
            if let id = motion.settlementID { motion.send(.settled(id)) }
        }
    }

    private var selectionDomainID: String {
        acceptedModel?.revisionID
            ?? [
                provider.rawValue,
                accountScope,
                window?.id ?? "none",
                String(generation),
                String(describing: presentationAuthority),
                String(describing: updateKind)
            ].joined(separator: "|")
    }

    private var chartAvailabilityIdentity: String {
        "\(provider.rawValue)|\(accountScope)|\(window?.id ?? "none")|\(String(describing: inspectionState.resetEpoch ?? .unknown))|\(String(describing: presentationAuthority))"
    }

    private var chartAccessibilitySummary: String {
        guard let latest = actualPoints.last else {
            return "No observed quota points are available."
        }
        let remaining = Int(((1 - latest.usedPercent) * 100).rounded())
        let timestamp = latest.date.formatted(.dateTime.month(.abbreviated).day().hour().minute())
        if let estimate = estimatePoints.last {
            let estimateTimestamp = estimate.date.formatted(.dateTime.month(.abbreviated).day().hour().minute())
            return "Latest observed value: \(remaining) percent remaining at \(timestamp). Current estimate reaches \(Int((estimate.usedPercent * 100).rounded())) percent used by \(estimateTimestamp)."
        }
        return "Latest observed value: \(remaining) percent remaining at \(timestamp). No estimate is available for this window."
    }

    private var referenceChart: some View {
        Chart {
                // Actual telemetry is hourly; each segment gets its own Charts
                // series ID so a missing sample or cadence break is never bridged.
                ForEach(acceptedModel?.renderedActualSegments ?? []) { segment in
                    observedSegmentMarks(for: segment)
                }

                ForEach(acceptedModel?.renderedTargetSegments ?? []) { segment in
                    ForEach(segment.points) { point in
                        LineMark(
                            x: .value("Time", point.date),
                            y: .value("Target", point.usedPercent),
                            series: .value("Series", segment.id)
                        )
                        .foregroundStyle(seriesColor(for: .target))
                        .lineStyle(strokeStyle(for: .target))
                        .interpolationMethod(.catmullRom)
                    }
                }

                ForEach(acceptedModel?.renderedEstimateSegments ?? []) { segment in
                    ForEach(segment.points) { point in
                        LineMark(
                            x: .value("Time", point.date),
                            y: .value("Estimate", point.usedPercent),
                            series: .value("Series", segment.id)
                        )
                        .foregroundStyle(LifeOSChartSeriesKind.estimate.color)
                        .lineStyle(strokeStyle(for: .estimate))
                        .interpolationMethod(.catmullRom)
                    }
                }

                if let selectedPoint {
                    RuleMark(x: .value("Selected", selectedPoint.date))
                        .foregroundStyle(LifeOSTokens.primaryText.opacity(0.18))
                        .lineStyle(StrokeStyle(lineWidth: 0.75))
                    PointMark(x: .value("Selected time", selectedPoint.date), y: .value("Selected usage", selectedPoint.usedPercent))
                        .symbolSize(46)
                        .foregroundStyle(LifeOSTokens.surface)
                        .annotation(position: .overlay) {
                            Circle()
                                .fill(selectedPoint.isProjected ? LifeOSTokens.Series.estimate : LifeOSTokens.Series.actual)
                                .frame(width: 7, height: 7)
                        }
                }
            }
            .chartYScale(domain: 0...1)
            .chartXScale(domain: chartDomain)
            .chartYAxis { yAxisMarks }
            .chartXAxis { xAxisMarks }
            .chartPlotStyle { plot in
                // Read the draw progress inside the Chart plot subtree. A
                // parent view cannot capture a child-modified environment
                // value while building its own body.
                LifeOSChartDrawReveal(content: plot)
            }
            // Replacing observations or changing the viewport must not interpolate
            // data coordinates. The draw-on modifier owns only its reveal mask.
            .animation(nil, value: selectionDomainID)
            .animation(nil, value: chartDomain)
            .chartDrawOn(id: selectionDomainID, interacting: motion.phase == .scrubbing || motion.phase == .hover || selectedID != nil)
    }

    @ChartContentBuilder
    private func observedSegmentMarks(for segment: UsageProjectionSegment) -> some ChartContent {
        if segment.points.count == 1, let point = segment.points.first {
            PointMark(
                x: .value("Time", point.date),
                y: .value("Actual", point.usedPercent)
            )
            .foregroundStyle(LifeOSChartSeriesKind.observed.color)
            .symbolSize(22)
        } else {
            ForEach(segment.points) { point in
                AreaMark(
                    x: .value("Time", point.date),
                    yStart: .value("Baseline", 0),
                    yEnd: .value("Actual", point.usedPercent),
                    series: .value("Series", segment.id)
                )
                .foregroundStyle(
                    LinearGradient(
                        colors: [
                            LifeOSChartSeriesKind.observed.color.opacity(
                                LifeOSChartSeriesKind.observed.style.areaOpacity
                            ),
                            .clear
                        ],
                        startPoint: .top,
                        endPoint: .bottom
                    )
                )
                .interpolationMethod(.catmullRom)

                LineMark(
                    x: .value("Time", point.date),
                    y: .value("Actual", point.usedPercent),
                    series: .value("Series", segment.id)
                )
                .foregroundStyle(LifeOSChartSeriesKind.observed.color)
                .lineStyle(strokeStyle(for: .observed))
                .interpolationMethod(.catmullRom)
            }
        }
    }

    private var yAxisMarks: some AxisContent {
        AxisMarks(values: [0, 0.25, 0.5, 0.75, 1]) { value in
            AxisGridLine(stroke: StrokeStyle(lineWidth: 0.5)).foregroundStyle(LifeOSTokens.chartGrid)
            AxisValueLabel {
                if let number = value.as(Double.self) {
                    Text(number, format: .percent.precision(.fractionLength(0)))
                        .lifeOSTypography(.metadata)
                        .foregroundStyle(LifeOSTokens.metadataText)
                        .lineLimit(1)
                        .minimumScaleFactor(0.75)
                        .allowsTightening(true)
                        .frame(minWidth: 34, alignment: .trailing)
                }
            }
        }
    }

    private var xAxisMarks: some AxisContent {
        let isShortWindow = window?.durationMinutes == UsageRange.fiveHour.durationMinutes
        return AxisMarks(values: .automatic(desiredCount: isShortWindow ? 4 : 6)) { value in
            AxisGridLine(stroke: StrokeStyle(lineWidth: 0.35)).foregroundStyle(LifeOSTokens.chartGrid.opacity(0.55))
            AxisValueLabel {
                if let date = value.as(Date.self) {
                    Group {
                        if isShortWindow {
                            Text(date, format: .dateTime.hour().minute())
                        } else {
                            Text(date, format: .dateTime.month(.abbreviated).day())
                        }
                    }
                    .lifeOSTypography(.metadata)
                    .foregroundStyle(LifeOSTokens.metadataText)
                    .lineLimit(1)
                    .minimumScaleFactor(0.75)
                    .allowsTightening(true)
                    .multilineTextAlignment(.center)
                    .frame(minWidth: 44)
                }
            }
        }
    }

    private var legend: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 16) {
                legendItems
            }
            LazyVGrid(
                columns: [GridItem(.adaptive(minimum: 130, maximum: 240), alignment: .leading)],
                alignment: .leading,
                spacing: 8
            ) {
                legendItems
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder
    private var legendItems: some View {
        if !targetPoints.isEmpty {
            UsageProjectionLegendKey(kind: .target, label: "Target pace")
        }
        if !actualPoints.isEmpty {
            UsageProjectionLegendKey(kind: .observed, label: "Actual")
        }
        if !estimatePoints.isEmpty {
            UsageProjectionLegendKey(kind: .estimate, label: "Current estimate")
        }
    }

    // MARK: Inspection row (02 §2 "Scrub bubble row")

    private var inspectionRow: some View {
        HStack(alignment: .center, spacing: 8) {
            stepButton(direction: -1, icon: .chevronLeft, label: "Previous usage chart point")

            Group {
                if let selectedPoint {
                    ViewThatFits(in: .horizontal) {
                        VStack(alignment: .leading, spacing: 2) {
                            HStack(spacing: 6) {
                                Text(selectedPoint.isProjected ? "Estimate" : "Actual")
                                    .lifeOSTypography(.button)
                                    .foregroundStyle(selectedPoint.isProjected ? LifeOSTokens.Series.estimate : LifeOSTokens.Series.actual)
                                Text("\(Int((1 - selectedPoint.usedPercent) * 100))% remaining")
                                    .lifeOSTypography(.button)
                                Text(selectedPoint.date, format: .dateTime.month(.abbreviated).day().hour().minute())
                                    .lifeOSTypography(.metadata)
                                    .foregroundStyle(LifeOSTokens.secondaryText)
                            }
                            Text(accountLabel)
                                .lifeOSTypography(.metadata)
                                .foregroundStyle(LifeOSTokens.tertiaryText)
                                .lineLimit(1)
                                .truncationMode(.tail)
                            Text(qualityTag)
                                .lifeOSTypography(.metadata)
                                .foregroundStyle(LifeOSTokens.tertiaryText)
                                .lineLimit(1)
                                .truncationMode(.tail)
                        }
                        .fixedSize(horizontal: true, vertical: false)
                        VStack(alignment: .leading, spacing: 2) {
                            HStack(spacing: 6) {
                                Text(selectedPoint.isProjected ? "Estimate" : "Actual")
                                    .lifeOSTypography(.button)
                                    .foregroundStyle(selectedPoint.isProjected ? LifeOSTokens.Series.estimate : LifeOSTokens.Series.actual)
                                Text("\(Int((1 - selectedPoint.usedPercent) * 100))% remaining")
                                    .lifeOSTypography(.button)
                            }
                            Text(selectedPoint.date, format: .dateTime.month(.abbreviated).day().hour().minute())
                                .lifeOSTypography(.metadata)
                                .foregroundStyle(LifeOSTokens.secondaryText)
                                .fixedSize(horizontal: false, vertical: true)
                            Text(accountLabel)
                                .lifeOSTypography(.metadata)
                                .foregroundStyle(LifeOSTokens.tertiaryText)
                                .lineLimit(2)
                                .truncationMode(.tail)
                                .fixedSize(horizontal: false, vertical: true)
                            Text(qualityTag)
                                .lifeOSTypography(.metadata)
                                .foregroundStyle(LifeOSTokens.tertiaryText)
                                .lineLimit(2)
                                .truncationMode(.tail)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                } else {
                    Text(scrubHintText)
                        .lifeOSTypography(.metadata)
                        .foregroundStyle(LifeOSTokens.secondaryText)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            stepButton(direction: 1, icon: .chevronRight, label: "Next usage chart point")
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .frame(minHeight: inspectionRowHeight)
        .background(LifeOSTokens.primaryText.opacity(0.045), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Usage chart point inspection")
    }

    private var inspectionRowHeight: CGFloat {
#if os(macOS)
        36
#else
        44
#endif
    }

    private var compactControlSize: CGFloat {
#if os(iOS)
        44
#else
        32
#endif
    }

    private func canStep(direction: Int) -> Bool {
        guard !allSelectablePoints.isEmpty else { return false }
        guard let selectedID,
              let index = acceptedModel?.selectionOffsets[selectedID] else {
            // With no selected point, the previous and next controls establish
            // the first selection from opposite ends of the series.
            return true
        }
        if direction < 0 {
            return index > 0
        }
        return index < allSelectablePoints.count - 1
    }

    private func stepButton(direction: Int, icon: LifeOSIconName, label: String) -> some View {
        Button { stepSelection(by: direction) } label: {
            LifeOSIcon(icon)
                .frame(width: compactControlSize, height: compactControlSize)
                .contentShape(Rectangle())
        }
        .buttonStyle(FinanceMotionControlStyle())
        .disabled(!canStep(direction: direction))
#if os(macOS)
        .keyboardShortcut(direction < 0 ? .leftArrow : .rightArrow, modifiers: [])
#endif
        .accessibilityLabel(label)
        .help(label)
    }

    private var scrubHintText: String {
#if os(iOS)
        "Drag or tap the chart for exact values, or use the point stepper."
#else
        "Hover the chart for exact values, or use the point stepper."
#endif
    }

    private var qualityTag: String {
        switch analytics.provenance.quality {
        case .observed: "Observed"
        case .estimated: "Derived estimate · Low confidence"
        case .demo: "Demo fixtures · not live"
        case .unavailable: "Unavailable"
        }
    }

    private var accountLabel: String {
        accountScope.isEmpty ? provider.displayName : accountScope
    }

    private func selectClosest(to date: Date) {
        guard let model = acceptedModel,
              let selection = model.nearestSelection(to: date) else {
            // Moving from a valid point into an observed gap must remove the
            // old marker and tooltip immediately; otherwise stale data remains
            // visible while the pointer is over a no-data interval.
            guard selectedID != nil else { return }
            LifeOSMotion.withoutAnimation { inspectionState.select(pointID: nil) }
            return
        }
        if selection.id != selectedID {
            LifeOSMotion.withoutAnimation { inspectionState.select(pointID: selection.id) }
            ScrubBubble<EmptyView>.snapHaptic()
        }
    }

    // MARK: Below-chart rows (02 §2)

    private var belowChartRows: some View {
        VStack(alignment: .leading, spacing: 10) {
            Divider().opacity(0.3)
            ViewThatFits(in: .horizontal) {
                HStack(alignment: .center, spacing: 8) {
                    rangeStartControl
                    Spacer(minLength: 0)
                    zoomControls
                }
                VStack(alignment: .leading, spacing: 8) {
                    rangeStartControl
                    zoomControls
                }
            }
        }
        .padding(.top, 2)
    }

    private var rangeStartControl: some View {
        Button(action: pinRangeStart) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Range start")
                    .lifeOSTypography(.metadata, weight: .medium)
                    .foregroundStyle(LifeOSTokens.primaryText)
                Text(
                    effectiveRangeStart?.formatted(.dateTime.month(.abbreviated).day().hour().minute())
                        ?? (selectedPoint == nil ? "Choose a point" : "Needs more history")
                )
                    .lifeOSTypography(.metadata)
                    .foregroundStyle(LifeOSTokens.secondaryText)
                    .lineLimit(1)
            }
            .frame(minWidth: compactControlSize, minHeight: compactControlSize, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(FinanceMotionControlStyle())
        .disabled(!canPinRangeStart)
        .accessibilityLabel(effectiveRangeStart.map {
            "Set chart range start to \($0.formatted(.dateTime.month(.abbreviated).day().hour().minute()))"
        } ?? (selectedPoint == nil
            ? "Set chart range start, choose a point first"
            : "Set chart range start, more history is required"))
    }

    private var zoomControls: some View {
        HStack(spacing: 8) {
            iconLabelButton(icon: .zoomIn, label: "Zoom in", isDisabled: !canZoomIn) { changeZoom(by: 0.6) }
            iconLabelButton(icon: .zoomOut, label: "Zoom out", isDisabled: !canZoomOut) { changeZoom(by: 1 / 0.6) }
        }
    }

    private func iconLabelButton(
        icon: LifeOSIconName,
        label: String,
        isDisabled: Bool = false,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            LifeOSIcon(icon)
                .frame(width: compactControlSize, height: compactControlSize)
                .contentShape(Rectangle())
                .foregroundStyle(LifeOSTokens.secondaryText)
        }
        .buttonStyle(FinanceMotionControlStyle())
        .disabled(isDisabled)
        .accessibilityLabel(label)
        .help(label)
    }

    private var effectiveRangeStart: Date? {
        guard canPinRangeStart,
              let selectedPoint,
              let earliest = acceptedModel?.earliestDate,
              let latest = acceptedModel?.latestDate else { return nil }
        let latestValidStart = latest.addingTimeInterval(-UsageChartEffectiveDomain.minimumDuration)
        return min(max(selectedPoint.date, earliest), latestValidStart)
    }

    private var canPinRangeStart: Bool {
        selectedPoint != nil && chartExtent != nil
    }

    private var chartExtent: TimeInterval? {
        guard let earliest = acceptedModel?.earliestDate,
              let latest = acceptedModel?.latestDate else { return nil }
        let duration = latest.timeIntervalSince(earliest)
        return duration.isFinite && duration >= UsageChartEffectiveDomain.minimumDuration ? duration : nil
    }

    private var visibleChartDuration: TimeInterval {
        max(chartDomain.upperBound.timeIntervalSince(chartDomain.lowerBound), UsageChartEffectiveDomain.minimumDuration)
    }

    private var canZoomIn: Bool {
        guard let chartExtent else { return false }
        return visibleChartDuration > min(chartExtent, UsageChartEffectiveDomain.minimumDuration) * 1.001
    }

    private var canZoomOut: Bool {
        guard let chartExtent else { return false }
        return visibleChartDuration < chartExtent * 0.999
    }

    private func pinRangeStart() {
        guard let earliest = acceptedModel?.earliestDate,
              let latest = acceptedModel?.latestDate,
              latest.timeIntervalSince(earliest) >= UsageChartEffectiveDomain.minimumDuration,
              let start = effectiveRangeStart else { return }
        guard let nextViewport = UsageChartInspectionViewport(
            start: start,
            end: latest
        ) else { return }
        inspectionState.setViewport(nextViewport)
    }

    private func changeZoom(by multiplier: Double) {
        guard multiplier > 0,
              multiplier.isFinite,
              let earliest = acceptedModel?.earliestDate,
              let latest = acceptedModel?.latestDate else { return }
        if multiplier < 1, !canZoomIn { return }
        if multiplier > 1, !canZoomOut { return }
        let maximumDuration = latest.timeIntervalSince(earliest)
        guard maximumDuration >= UsageChartEffectiveDomain.minimumDuration else { return }
        let current = chartDomain
        let currentDuration = min(
            max(
                current.upperBound.timeIntervalSince(current.lowerBound),
                UsageChartEffectiveDomain.minimumDuration
            ),
            maximumDuration
        )
        let nextDuration = min(
            max(currentDuration * multiplier, UsageChartEffectiveDomain.minimumDuration),
            maximumDuration
        )
        let start = latest.addingTimeInterval(-nextDuration)
        guard let nextViewport = UsageChartInspectionViewport(
            start: start,
            end: latest
        ) else { return }
        inspectionState.setViewport(nextViewport)
    }

    private func stepSelection(by offset: Int) {
        guard let model = acceptedModel, !model.selectablePoints.isEmpty else { return }
        let currentIndex = selectedID.flatMap { selected in
            model.selectionOffsets[selected]
        } ?? (offset < 0 ? model.selectablePoints.count : -1)
        let nextIndex = min(max(currentIndex + offset, 0), model.selectablePoints.count - 1)
        let next = model.selectablePoints[nextIndex]
        if next.id != selectedID { ScrubBubble<EmptyView>.snapHaptic() }
        LifeOSMotion.withoutAnimation { inspectionState.select(pointID: next.id) }
    }
}

private struct UsageProjectionLegendKey: View {
    let kind: LifeOSChartSeriesKind
    let label: String

    private var lineColor: Color {
        kind == .target ? LifeOSTokens.secondaryText : kind.color
    }

    var body: some View {
        let style = kind.style
        let lineWidth = kind == .target ? 1.0 : style.lineWidth

        HStack(spacing: 5) {
            if style.lineStyle == .solid {
                Capsule()
                    .fill(lineColor)
                    .frame(width: 14, height: max(2, lineWidth))
            } else {
                UsageProjectionLegendLine()
                    .stroke(
                        lineColor,
                        style: StrokeStyle(
                            lineWidth: lineWidth,
                            lineCap: .round,
                            dash: kind == .target ? [2, 4] : style.dashPattern
                        )
                    )
                    .frame(width: 14, height: 4)
            }
            Text(label)
                .lifeOSTypography(.metadata)
                .foregroundStyle(LifeOSTokens.secondaryText)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct UsageProjectionLegendLine: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        path.move(to: CGPoint(x: rect.minX, y: rect.midY))
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.midY))
        return path
    }
}
