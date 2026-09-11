import SwiftUI
import Charts

// MARK: - Projection chart (02-charts-rings-widgets.md §2) — 4-series model.
//
// Target (green dashed) / Actual (blue solid, area fill) / Current estimate (green dashed) /
// Past estimate (metadata dotted, only if a prior-estimate series is actually stored — it is not,
// see DemoUsageAnalytics / UsageAnalyticsSnapshot, so this series is omitted rather than
// fabricated).

struct UsageChartViewport: Equatable {
    var pinnedRangeStart: Date?
    var zoomFactor: Double = 1

    mutating func reconcile(windowChanged: Bool, hasObservations: Bool) {
        guard windowChanged || !hasObservations else { return }
        pinnedRangeStart = nil
        zoomFactor = 1
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

    @State private var displayModel: UsageProjectionDisplayModel
    @State private var selectedID: String?
    @State private var motion = LifeOSMotionLifecycle()
    @GestureState private var dragIsActive = false
    @State private var viewport = UsageChartViewport()

    init(provider: Provider, window: UsageWindow?, analytics: UsageAnalyticsSnapshot) {
        self.provider = provider
        self.window = window
        self.analytics = analytics
        _displayModel = State(initialValue: UsageProjectionDisplayModel(analytics: analytics, window: window))
    }

    // MARK: Series data

    /// Actual = observed activity points in the selected window. The activity transport is
    /// hourly, so a selected 5-hour window must not quietly plot older observations.
    private var actualPoints: [UsageProjectionPoint] {
        displayModel.actualPoints
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
        displayModel.estimatePoints
    }

    /// Target = straight-line ideal pace from the first observed point to 100% at reset.
    private var targetPoints: [UsageProjectionPoint] {
        displayModel.targetPoints
    }

    private var allSelectablePoints: [UsageSelectionPoint] {
        displayModel.selectablePoints
    }

    private var selectedPoint: UsageSelectionPoint? {
        guard let selectedID else { return nil }
        return displayModel.selectionIndex[selectedID]
    }

    private var chartDomain: ClosedRange<Date> {
        guard let earliest = displayModel.earliestDate,
              let latest = displayModel.latestDate,
              latest > earliest else {
            let now = Date.now
            return now.addingTimeInterval(-3_600)...now
        }

        let lowerBound = max(viewport.pinnedRangeStart ?? earliest, earliest)
        let availableInterval = max(latest.timeIntervalSince(lowerBound), 60)
        let visibleInterval = availableInterval * viewport.zoomFactor
        return latest.addingTimeInterval(-visibleInterval)...latest
    }

    private var chartHeight: CGFloat {
#if os(macOS)
        280
#else
        220
#endif
    }

    private func strokeStyle(for kind: LifeOSChartSeriesKind) -> StrokeStyle {
        let style = kind.style
        return StrokeStyle(
            lineWidth: style.lineWidth,
            lineCap: .round,
            lineJoin: .round,
            dash: style.dashPattern
        )
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            VStack(alignment: .leading, spacing: 12) {
                legend

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
                                Rectangle().fill(.clear).contentShape(Rectangle())
                                    .gesture(DragGesture(minimumDistance: 0)
                        .updating($dragIsActive) { _, active, _ in active = true }
                                        .onChanged { value in
                                            motion.send(.scrub)
                                            select(at: value.location.x, frame: frame)
                                        }
                                        .onEnded { _ in finishScrub(cancelled: false) })
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
                .frame(height: chartHeight)


                detailRow

                keyboardStepper

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
        .onChange(of: analytics) { _, newAnalytics in
            updateDisplayModel(
                analytics: newAnalytics,
                window: window,
                resetViewport: false
            )
        }
        .onChange(of: window) { _, newWindow in
            updateDisplayModel(
                analytics: analytics,
                window: newWindow,
                resetViewport: true
            )
        }
        .onChange(of: selectionDomainID) { _, _ in
            if let selectedID, displayModel.selectionIndex[selectedID] == nil {
                LifeOSMotion.withoutAnimation { self.selectedID = nil }
            }
        }
        .onChange(of: dragIsActive) { _, active in
            if !active { finishScrub(cancelled: true) }
        }
        .onDisappear { finishScrub(cancelled: true) }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("\(provider.displayName) usage remaining chart")
        .accessibilityValue(chartAccessibilitySummary)
    }

    private func updateDisplayModel(
        analytics: UsageAnalyticsSnapshot,
        window: UsageWindow?,
        resetViewport: Bool
    ) {
        let nextModel = UsageProjectionDisplayModel(analytics: analytics, window: window)
        guard resetViewport || !nextModel.actualPoints.isEmpty else {
            // A same-window refresh can briefly have no transport points. Keep
            // the last observed model mounted so the user never sees a blank
            // chart or an invented zero while the coordinator reconciles it.
            return
        }
        LifeOSMotion.withoutAnimation {
            finishScrub(cancelled: true)
            selectedID = nil
            displayModel = nextModel
            viewport.reconcile(windowChanged: resetViewport, hasObservations: !nextModel.actualPoints.isEmpty)
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
        displayModel.revisionID
    }

    private var chartAvailabilityIdentity: String {
        "\(provider.rawValue)|\(window?.id ?? "none")"
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
                ForEach(displayModel.renderedActualSegments) { segment in
                    observedSegmentMarks(for: segment)
                }

                ForEach(displayModel.renderedTargetSegments) { segment in
                    ForEach(segment.points) { point in
                        LineMark(
                            x: .value("Time", point.date),
                            y: .value("Target", point.usedPercent),
                            series: .value("Series", segment.id)
                        )
                        .foregroundStyle(LifeOSChartSeriesKind.target.color)
                        .lineStyle(strokeStyle(for: .target))
                        .interpolationMethod(.catmullRom)
                    }
                }

                ForEach(displayModel.renderedEstimateSegments) { segment in
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
        LazyVGrid(
            columns: [GridItem(.adaptive(minimum: 130, maximum: 240), alignment: .leading)],
            alignment: .leading,
            spacing: 8
        ) {
            if !displayModel.targetPoints.isEmpty {
                UsageProjectionLegendKey(kind: .target, label: "Target pace")
            }
            if !displayModel.actualPoints.isEmpty {
                UsageProjectionLegendKey(kind: .observed, label: "Actual")
            }
            if !displayModel.estimatePoints.isEmpty {
                UsageProjectionLegendKey(kind: .estimate, label: "Current estimate")
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: Scrub detail row (02 §2 "Scrub bubble row")

    private var detailRow: some View {
        HStack(alignment: .center, spacing: 10) {
            if let selectedPoint {
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Text(selectedPoint.isProjected ? "Estimate" : "Actual")
                            .lifeOSTypography(.button)
                            .foregroundStyle(selectedPoint.isProjected ? LifeOSTokens.Series.estimate : LifeOSTokens.Series.actual)
                        Text("\(Int((1 - selectedPoint.usedPercent) * 100))% remaining")
                            .lifeOSTypography(.button)
                        Text(selectedPoint.date, format: .dateTime.month(.abbreviated).day().hour().minute())
                            .lifeOSTypography(.body)
                            .foregroundStyle(LifeOSTokens.secondaryText)
                    }
                    Text("\(provider.displayName) · \(qualityTag)")
                        .lifeOSTypography(.metadata)
                        .foregroundStyle(LifeOSTokens.tertiaryText)
                }
            } else {
                Text(scrubHintText)
                    .lifeOSTypography(.body)
                    .foregroundStyle(LifeOSTokens.secondaryText)
            }
            Spacer(minLength: 8)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(LifeOSTokens.primaryText.opacity(0.045), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
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

    private func selectClosest(to date: Date) {
        guard let selection = displayModel.nearestSelection(to: date) else {
            // Moving from a valid point into an observed gap must remove the
            // old marker and tooltip immediately; otherwise stale data remains
            // visible while the pointer is over a no-data interval.
            guard selectedID != nil else { return }
            LifeOSMotion.withoutAnimation { selectedID = nil }
            return
        }
        if selection.id != selectedID {
            LifeOSMotion.withoutAnimation { selectedID = selection.id }
            ScrubBubble<EmptyView>.snapHaptic()
        }
    }

    // MARK: Below-chart rows (02 §2)

    private var belowChartRows: some View {
        VStack(alignment: .leading, spacing: 10) {
            Divider().opacity(0.3)
            metaRow(
                label: "Set range start",
                value: selectedPoint.map { $0.date.formatted(.dateTime.month(.abbreviated).day().hour().minute()) } ?? "Choose a point",
                action: pinRangeStart
            )
            HStack(spacing: 16) {
                iconLabelButton(icon: .zoomIn, label: "Zoom in") { changeZoom(by: 0.6) }
                iconLabelButton(icon: .zoomOut, label: "Zoom out") { changeZoom(by: 1 / 0.6) }
            }
            metaRow(label: "Reset", value: resetText)
            metaRow(label: "Suggested pace", value: "Not available")
            metaRow(label: "Runway", value: "Not available")
        }
        .padding(.top, 2)
    }

    private var keyboardStepper: some View {
        HStack(spacing: 8) {
            Button { stepSelection(by: -1) } label: {
                LifeOSIcon(.chevronLeft).frame(width: 11, height: 11)
            }
            .buttonStyle(FinanceMotionControlStyle())
            .disabled(displayModel.selectablePoints.isEmpty)
#if os(macOS)
            .keyboardShortcut(.leftArrow, modifiers: [])
#endif
            .accessibilityLabel("Previous usage chart point")

            Text(selectedPoint.map {
                "\($0.date.formatted(.dateTime.month(.abbreviated).day().hour().minute())) · \(Int((1 - $0.usedPercent) * 100))% remaining"
            } ?? "Select a chart point")
                .lifeOSTypography(.button).monospacedDigit()
                .foregroundStyle(LifeOSTokens.secondaryText)
                .lineLimit(2)
                .minimumScaleFactor(0.8)
                .frame(minWidth: 150, alignment: .center)
                .accessibilityLabel(selectedPoint.map {
                    "Selected \($0.isProjected ? "projected" : "observed") usage point, \(Int((1 - $0.usedPercent) * 100)) percent remaining at \($0.date.formatted(.dateTime.month(.abbreviated).day().hour().minute()))"
                } ?? "No usage chart point selected")

            Button { stepSelection(by: 1) } label: {
                LifeOSIcon(.chevronRight).frame(width: 11, height: 11)
            }
            .buttonStyle(FinanceMotionControlStyle())
            .disabled(displayModel.selectablePoints.isEmpty)
#if os(macOS)
            .keyboardShortcut(.rightArrow, modifiers: [])
#endif
            .accessibilityLabel("Next usage chart point")
        }
        .foregroundStyle(LifeOSTokens.secondaryText)
        .padding(.horizontal, 9)
        .padding(.vertical, 6)
        .background(LifeOSTokens.primaryText.opacity(0.045), in: Capsule())
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Usage chart point stepper")
    }

    private var resetText: String {
        guard let resetAt = window?.resetAt else { return "Not available" }
        return resetAt.formatted(.dateTime.month(.abbreviated).day().year().hour().minute())
    }

    @ViewBuilder
    private func metaRow(label: String, value: String, action: (() -> Void)? = nil) -> some View {
        if let action {
            Button(action: action) {
                metaRowContent(label: label, value: value)
            }
            .buttonStyle(FinanceMotionControlStyle())
            .disabled(selectedPoint == nil)
        } else {
            metaRowContent(label: label, value: value)
        }
    }

    private func metaRowContent(label: String, value: String) -> some View {
        HStack {
            Text(label).foregroundStyle(LifeOSTokens.secondaryText)
            Spacer()
            Text(value).foregroundStyle(LifeOSTokens.primaryText)
        }
        .lifeOSTypography(.body)
    }

    private func iconLabelButton(icon: LifeOSIconName, label: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 5) {
                LifeOSIcon(icon).frame(width: 12, height: 12)
                Text(label)
            }
            .lifeOSTypography(.button)
            .foregroundStyle(LifeOSTokens.secondaryText)
        }
        .buttonStyle(FinanceMotionControlStyle())
    }

    private func pinRangeStart() {
        guard let selectedPoint else { return }
        viewport.pinnedRangeStart = selectedPoint.date
        viewport.zoomFactor = 1
    }

    private func changeZoom(by multiplier: Double) {
        viewport.zoomFactor = min(max(viewport.zoomFactor * multiplier, 0.25), 1)
    }

    private func stepSelection(by offset: Int) {
        guard !displayModel.selectablePoints.isEmpty else { return }
        let currentIndex = selectedID.flatMap { selected in
            displayModel.selectionOffsets[selected]
        } ?? (offset < 0 ? displayModel.selectablePoints.count : -1)
        let nextIndex = min(max(currentIndex + offset, 0), displayModel.selectablePoints.count - 1)
        let next = displayModel.selectablePoints[nextIndex]
        if next.id != selectedID { ScrubBubble<EmptyView>.snapHaptic() }
        LifeOSMotion.withoutAnimation { selectedID = next.id }
    }
}

private struct UsageProjectionLegendKey: View {
    let kind: LifeOSChartSeriesKind
    let label: String

    var body: some View {
        let style = kind.style

        HStack(spacing: 5) {
            if style.lineStyle == .solid {
                Capsule()
                    .fill(kind.color)
                    .frame(width: 14, height: max(2, style.lineWidth))
            } else {
                UsageProjectionLegendLine()
                    .stroke(
                        kind.color,
                        style: StrokeStyle(
                            lineWidth: style.lineWidth,
                            lineCap: .round,
                            dash: style.dashPattern
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
