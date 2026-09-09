import SwiftUI
import Charts

// MARK: - Projection chart (02-charts-rings-widgets.md §2) — 4-series model.
//
// Target (neutral dotted) / Actual (blue solid, area fill) / Current estimate (green dashed) /
// Past estimate (grey dotted, only if a prior-estimate series is actually stored — it is not,
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

/// One revision-keyed projection model owns sorting, filtering, selection
/// indexing, and chart downsampling. The full arrays remain authoritative for
/// keyboard selection and accessibility; only the rendered arrays are bounded.
struct UsageProjectionDisplayModel {
    static let maximumRenderedSamples = 240

    let actualPoints: [UsageProjectionPoint]
    let estimatePoints: [UsageProjectionPoint]
    let targetPoints: [UsageProjectionPoint]
    let renderedActualPoints: [UsageProjectionPoint]
    let renderedEstimatePoints: [UsageProjectionPoint]
    let renderedTargetPoints: [UsageProjectionPoint]
    let selectablePoints: [UsageSelectionPoint]
    let selectionIndex: [String: UsageSelectionPoint]
    let selectionOffsets: [String: Int]
    let earliestDate: Date?
    let latestDate: Date?
    let revisionID: String

    init(analytics: UsageAnalyticsSnapshot, window: UsageWindow?) {
        let sortedActivity = analytics.activity.sorted { $0.date < $1.date }
        let activityInWindow: [UsageActivityPoint]
        if let resetAt = window?.resetAt, let durationMinutes = window?.durationMinutes {
            let start = resetAt.addingTimeInterval(-Double(durationMinutes) * 60)
            activityInWindow = sortedActivity.filter { point in
                point.date >= start && point.date <= resetAt
            }
        } else {
            activityInWindow = sortedActivity
        }

        let actual: [UsageProjectionPoint]
        if !activityInWindow.isEmpty {
            actual = activityInWindow.map {
                UsageProjectionPoint(date: $0.date, usedPercent: $0.usedPercent)
            }
        } else {
            actual = analytics.history
                .sorted { $0.observedAt < $1.observedAt }
                .map {
                    UsageProjectionPoint(date: $0.observedAt, usedPercent: $0.usedPercent / 100)
                }
        }

        let estimate: [UsageProjectionPoint]
        if !actual.isEmpty, analytics.windowID == window?.id {
            let lastObservedDate = actual.last?.date ?? .distantPast
            estimate = analytics.projection
                .filter { $0.date >= lastObservedDate }
                .filter { point in
                    guard let resetAt = window?.resetAt else { return true }
                    return point.date <= resetAt
                }
                .sorted { $0.date < $1.date }
        } else {
            estimate = []
        }

        let target: [UsageProjectionPoint]
        if let start = actual.first,
           let resetAt = window?.resetAt,
           resetAt > start.date {
            let totalSeconds = resetAt.timeIntervalSince(start.date)
            if totalSeconds > 0 {
                target = (0...12).map { step in
                    let fraction = Double(step) / 12
                    let date = start.date.addingTimeInterval(totalSeconds * fraction)
                    let value = start.usedPercent + (1 - start.usedPercent) * fraction
                    return UsageProjectionPoint(date: date, usedPercent: value)
                }
            } else {
                target = []
            }
        } else {
            target = []
        }

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

        self.actualPoints = actual
        self.estimatePoints = estimate
        self.targetPoints = target
        self.renderedActualPoints = Self.bounded(actual, maximumCount: Self.maximumRenderedSamples)
        self.renderedEstimatePoints = Self.bounded(estimate, maximumCount: Self.maximumRenderedSamples)
        self.renderedTargetPoints = Self.bounded(target, maximumCount: Self.maximumRenderedSamples)
        self.selectablePoints = selectable
        self.selectionIndex = index
        self.selectionOffsets = offsets
        self.earliestDate = earliestDate
        self.latestDate = latestDate
        self.revisionID = [
            window?.id ?? "none",
            analytics.windowID ?? "none",
            Self.signature(actual),
            Self.signature(estimate),
            Self.signature(target)
        ].joined(separator: "|")
    }

    static func bounded(
        _ points: [UsageProjectionPoint],
        maximumCount: Int = maximumRenderedSamples
    ) -> [UsageProjectionPoint] {
        guard maximumCount > 1, points.count > maximumCount else { return points }
        let lastIndex = points.count - 1
        return (0..<maximumCount).map { index in
            let sourceIndex = Int(
                (Double(index) * Double(lastIndex) / Double(maximumCount - 1)).rounded()
            )
            return points[sourceIndex]
        }
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
        244
#else
        220
#endif
    }

    /// Target pace is a neutral reference line. Green is reserved for the
    /// current estimate so the two meanings cannot be confused at a glance.
    private var targetColor: Color { LifeOSTokens.tertiaryText }

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
                // §5.4: only Actual receives the restrained area fill.

                ForEach(displayModel.renderedActualPoints) { point in
                    AreaMark(
                        x: .value("Time", point.date),
                        yStart: .value("Baseline", 0),
                        yEnd: .value("Actual", point.usedPercent)
                    )
                    .foregroundStyle(
                        LinearGradient(
                            colors: [LifeOSTokens.Series.actual.opacity(0.22), .clear],
                            startPoint: .top,
                            endPoint: .bottom
                        )
                    )
                    .interpolationMethod(.catmullRom)

                    LineMark(
                        x: .value("Time", point.date),
                        y: .value("Actual", point.usedPercent),
                        series: .value("Series", "Actual")
                    )
                    .foregroundStyle(LifeOSTokens.Series.actual)
                    .lineStyle(StrokeStyle(lineWidth: 2, lineCap: .round, lineJoin: .round))
                    .interpolationMethod(.catmullRom)
                }

                ForEach(displayModel.renderedTargetPoints) { point in
                    LineMark(x: .value("Time", point.date), y: .value("Target", point.usedPercent), series: .value("Series", "Target"))
                        .foregroundStyle(targetColor)
                        .lineStyle(StrokeStyle(lineWidth: 1.25, lineCap: .round, dash: [1, 3]))
                        .interpolationMethod(.catmullRom)
                }

                ForEach(displayModel.renderedEstimatePoints) { point in
                    LineMark(x: .value("Time", point.date), y: .value("Estimate", point.usedPercent), series: .value("Series", "Estimate"))
                        .foregroundStyle(LifeOSTokens.Series.estimate)
                        .lineStyle(StrokeStyle(lineWidth: 1.5, lineCap: .round, dash: [3, 3]))
                        .interpolationMethod(.catmullRom)
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
                UsageLegendKey(color: targetColor, label: "Target pace", dotted: true)
            }
            if !displayModel.actualPoints.isEmpty {
                UsageLegendKey(color: LifeOSTokens.Series.actual, label: "Actual")
            }
            if !displayModel.estimatePoints.isEmpty {
                UsageLegendKey(color: LifeOSTokens.Series.estimate, label: "Current estimate", dashed: true)
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
        guard let closest = LifeOSChartKit.nearestSelection(in: selectableSeries, to: date) else { return }
        let selection = UsageSelectionPoint(
            date: closest.point.timestamp,
            usedPercent: closest.point.value ?? 0,
            isProjected: closest.kind == .estimate
        )
        if selection.id != selectedID {
            LifeOSMotion.withoutAnimation { selectedID = selection.id }
            ScrubBubble<EmptyView>.snapHaptic()
        }
    }

    private var selectableSeries: [LifeOSChartSeries] {
        var result: [LifeOSChartSeries] = []
        if !displayModel.renderedActualPoints.isEmpty {
            result.append(
                LifeOSChartSeries(
                    id: "actual",
                    label: "Actual",
                    kind: .observed,
                    points: displayModel.renderedActualPoints.map { LifeOSChartPoint(timestamp: $0.date, value: $0.usedPercent) },
                    source: analytics.provenance.source,
                    provenance: chartProvenance
                )
            )
        }
        if !displayModel.renderedEstimatePoints.isEmpty {
            result.append(
                LifeOSChartSeries(
                    id: "estimate",
                    label: "Estimate",
                    kind: .estimate,
                    points: displayModel.renderedEstimatePoints.map { LifeOSChartPoint(timestamp: $0.date, value: $0.usedPercent) },
                    source: analytics.provenance.source,
                    provenance: .estimated
                )
            )
        }
        return result
    }

    private var chartProvenance: LifeOSChartProvenance {
        switch analytics.provenance.quality {
        case .observed: .observed
        case .estimated: .estimated
        case .demo: .demo
        case .unavailable: .unavailable
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
