import SwiftUI
import Charts

// MARK: - Projection chart (02-charts-rings-widgets.md §2) — 4-series model.
//
// Target (green dashed) / Actual (blue solid, area fill) / Current estimate (orange dashed) /
// Past estimate (grey dotted, only if a prior-estimate series is actually stored — it is not,
// see DemoUsageAnalytics / UsageAnalyticsSnapshot, so this series is omitted rather than
// fabricated).

struct UsageProjectionChart: View {
    let provider: Provider
    let window: UsageWindow?
    let analytics: UsageAnalyticsSnapshot

    @State private var selectedID: String?
    @State private var pinnedRangeStart: Date?
    @State private var zoomFactor: Double = 1

    // MARK: Series data

    /// Actual = observed activity points in the selected window. The activity transport is
    /// hourly, so a selected 5-hour window must not quietly plot older observations.
    private var actualPoints: [UsageProjectionPoint] {
        let points = analytics.activity
            .sorted { $0.date < $1.date }
            .filter { point in
                guard let resetAt = window?.resetAt, let durationMinutes = window?.durationMinutes else { return true }
                let start = resetAt.addingTimeInterval(-Double(durationMinutes) * 60)
                return point.date >= start && point.date <= resetAt
            }
        if !points.isEmpty {
            return points.map { UsageProjectionPoint(date: $0.date, usedPercent: $0.usedPercent) }
        }

        // The gateway currently exposes quota observations, not token activity.
        // Use the durable observations as the Actual series only when no richer
        // activity feed exists; never relabel them as token volume or estimates.
        return analytics.history
            .sorted { $0.observedAt < $1.observedAt }
            .map { UsageProjectionPoint(date: $0.observedAt, usedPercent: $0.usedPercent / 100) }
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
        guard !actualPoints.isEmpty else { return [] }
        guard let windowID = analytics.windowID, windowID == window?.id else { return [] }
        let lastObservedDate = actualPoints.last?.date ?? .distantPast
        return analytics.projection
            .filter { $0.date >= lastObservedDate }
            .filter { point in
                guard let resetAt = window?.resetAt else { return true }
                return point.date <= resetAt
            }
    }

    /// Target = straight-line ideal pace from the first observed point to 100% at reset.
    private var targetPoints: [UsageProjectionPoint] {
        guard let start = actualPoints.first, let resetAt = window?.resetAt, resetAt > start.date else { return [] }
        let totalSeconds = resetAt.timeIntervalSince(start.date)
        guard totalSeconds > 0 else { return [] }
        let steps = 12
        return (0...steps).map { step in
            let fraction = Double(step) / Double(steps)
            let date = start.date.addingTimeInterval(totalSeconds * fraction)
            let value = start.usedPercent + (1 - start.usedPercent) * fraction
            return UsageProjectionPoint(date: date, usedPercent: value)
        }
    }

    /// Past-estimate / account-history series — GAP. `UsageAnalyticsSnapshot` does not persist
    /// a prior estimate snapshot to compare against, so this series is always empty rather than
    /// fabricated. Flagged in 02 §2 / data-gaps list.
    private var historyPoints: [UsageProjectionPoint] { [] }

    private var allSelectablePoints: [UsageSelectionPoint] {
        (actualPoints.map { UsageSelectionPoint(date: $0.date, usedPercent: $0.usedPercent, isProjected: false) }
            + estimatePoints.map { UsageSelectionPoint(date: $0.date, usedPercent: $0.usedPercent, isProjected: true) }
        )
        .sorted {
            if $0.date == $1.date {
                return !$0.isProjected && $1.isProjected
            }
            return $0.date < $1.date
        }
    }

    private var selectedPoint: UsageSelectionPoint? {
        guard let selectedID else { return nil }
        return allSelectablePoints.first { $0.id == selectedID }
    }

    private var chartDomain: ClosedRange<Date> {
        let dates = (targetPoints + historyPoints + estimatePoints + actualPoints).map(\.date)
        guard let earliest = dates.min(), let latest = dates.max(), latest > earliest else {
            let now = Date.now
            return now.addingTimeInterval(-3_600)...now
        }

        let lowerBound = max(pinnedRangeStart ?? earliest, earliest)
        let availableInterval = max(latest.timeIntervalSince(lowerBound), 60)
        let visibleInterval = availableInterval * zoomFactor
        return latest.addingTimeInterval(-visibleInterval)...latest
    }

    private var chartHeight: CGFloat {
#if os(macOS)
        244
#else
        220
#endif
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if actualPoints.isEmpty {
                UsageEmptyState(
                    title: "No observed usage points",
                    detail: "The gateway has not supplied quota observations for this window, so no chart range or projection is shown."
                )
            } else {
                legend

                referenceChart
                .chartOverlay { proxy in
                    GeometryReader { geometry in
                        if let plotFrame = proxy.plotFrame {
                            let frame = geometry[plotFrame]
#if os(iOS)
                                Rectangle().fill(.clear).contentShape(Rectangle())
                                    .simultaneousGesture(DragGesture(minimumDistance: LifeOSDirectionalClassifier.minimumDistance).onChanged { value in
                                        guard LifeOSDirectionalClassifier.classify(value.translation) == .horizontal,
                                              let date = LifeOSChartKit.timestamp(
                                                  forPlotX: value.location.x,
                                                  in: frame,
                                                  domain: chartDomain
                                              ) else { return }
                                        selectClosest(to: date)
                                    })
                                    .onTapGesture { location in
                                        guard let date = LifeOSChartKit.timestamp(
                                            forPlotX: location.x,
                                            in: frame,
                                            domain: chartDomain
                                        ) else { return }
                                        selectClosest(to: date)
                                    }
#elseif os(macOS)
                                Rectangle().fill(.clear).contentShape(Rectangle())
                                    .onContinuousHover(coordinateSpace: .local) { phase in
                                        switch phase {
                                        case .active(let location):
                                            guard let date = LifeOSChartKit.timestamp(
                                                forPlotX: location.x,
                                                in: frame,
                                                domain: chartDomain
                                            ) else { return }
                                            selectClosest(to: date)
                                        case .ended:
                                            break
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
                .task(id: selectionDomainID) {
                    // Do not invent a default observation. The hero is sourced from the selected
                    // window, while analytics can contain a different observation cadence. A scrub
                    // point appears only after the user explicitly chooses one.
                    selectedID = nil
                    pinnedRangeStart = nil
                    zoomFactor = 1
                }

                detailRow

                keyboardStepper

                belowChartRows
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("\(provider.displayName) usage remaining chart")
        .accessibilityValue(chartAccessibilitySummary)
    }

    private var selectionDomainID: String {
        let pointIDs = allSelectablePoints.map {
            "\($0.date.timeIntervalSinceReferenceDate)-\($0.isProjected)-\($0.usedPercent)"
        }
        return "\(window?.id ?? "none")|\(pointIDs.joined(separator: ","))"
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

                ForEach(actualPoints) { point in
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

                ForEach(targetPoints) { point in
                    LineMark(x: .value("Time", point.date), y: .value("Target", point.usedPercent), series: .value("Series", "Target"))
                        .foregroundStyle(LifeOSTokens.Series.target)
                        .lineStyle(StrokeStyle(lineWidth: 1.25, lineCap: .round, dash: [6, 4]))
                        .interpolationMethod(.catmullRom)
                }

                ForEach(historyPoints) { point in
                    LineMark(x: .value("Time", point.date), y: .value("History", point.usedPercent), series: .value("Series", "History"))
                        .foregroundStyle(LifeOSTokens.Series.history)
                        .lineStyle(StrokeStyle(lineWidth: 1.25, lineCap: .round, dash: [1, 2]))
                        .interpolationMethod(.catmullRom)
                }

                ForEach(estimatePoints) { point in
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
            .chartDrawOn(id: selectionDomainID)
    }

    private var yAxisMarks: some AxisContent {
        AxisMarks(values: [0, 0.25, 0.5, 0.75, 1]) { value in
            AxisGridLine(stroke: StrokeStyle(lineWidth: 0.5)).foregroundStyle(LifeOSTokens.chartGrid)
            AxisValueLabel {
                if let number = value.as(Double.self) {
                    Text(number, format: .percent.precision(.fractionLength(0)))
                        .font(LifeOSFont.axis(13))
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
                    .font(LifeOSFont.axis(13))
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
            if !targetPoints.isEmpty {
                UsageLegendKey(color: LifeOSTokens.Series.target, label: "Target", dashed: true)
            }
            if !actualPoints.isEmpty {
                UsageLegendKey(color: LifeOSTokens.Series.actual, label: "Actual")
            }
            if !estimatePoints.isEmpty {
                UsageLegendKey(color: LifeOSTokens.Series.estimate, label: "Current estimate", dashed: true)
            }
            if !historyPoints.isEmpty {
                UsageLegendKey(color: LifeOSTokens.Series.history, label: "Past estimate", dotted: true)
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
                            .font(LifeOSFont.control(14))
                            .foregroundStyle(selectedPoint.isProjected ? LifeOSTokens.Series.estimate : LifeOSTokens.Series.actual)
                        Text("\(Int((1 - selectedPoint.usedPercent) * 100))% remaining")
                            .font(LifeOSFont.control(14))
                        Text(selectedPoint.date, format: .dateTime.month(.abbreviated).day().hour().minute())
                            .font(LifeOSFont.callout(14))
                            .foregroundStyle(LifeOSTokens.secondaryText)
                    }
                    Text("\(provider.displayName) · \(qualityTag)")
                        .font(LifeOSFont.metadata())
                        .foregroundStyle(LifeOSTokens.tertiaryText)
                }
            } else {
                Text(scrubHintText)
                    .font(LifeOSFont.callout())
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
            selectedID = selection.id
            ScrubBubble<EmptyView>.snapHaptic()
        }
    }

    private var selectableSeries: [LifeOSChartSeries] {
        var result: [LifeOSChartSeries] = []
        if !actualPoints.isEmpty {
            result.append(
                LifeOSChartSeries(
                    id: "actual",
                    label: "Actual",
                    kind: .observed,
                    points: actualPoints.map { LifeOSChartPoint(timestamp: $0.date, value: $0.usedPercent) },
                    source: analytics.provenance.source,
                    provenance: chartProvenance
                )
            )
        }
        if !estimatePoints.isEmpty {
            result.append(
                LifeOSChartSeries(
                    id: "estimate",
                    label: "Estimate",
                    kind: .estimate,
                    points: estimatePoints.map { LifeOSChartPoint(timestamp: $0.date, value: $0.usedPercent) },
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
            .buttonStyle(.plain)
            .disabled(allSelectablePoints.isEmpty)
#if os(macOS)
            .keyboardShortcut(.leftArrow, modifiers: [])
#endif
            .accessibilityLabel("Previous usage chart point")

            Text(selectedPoint.map {
                "\($0.date.formatted(.dateTime.month(.abbreviated).day().hour().minute())) · \(Int((1 - $0.usedPercent) * 100))% remaining"
            } ?? "Select a chart point")
                .font(LifeOSFont.control(13).monospacedDigit())
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
            .buttonStyle(.plain)
            .disabled(allSelectablePoints.isEmpty)
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
            .buttonStyle(.plain)
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
        .font(LifeOSFont.bodyText(13))
    }

    private func iconLabelButton(icon: LifeOSIconName, label: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 5) {
                LifeOSIcon(icon).frame(width: 12, height: 12)
                Text(label)
            }
            .font(LifeOSFont.control(13))
            .foregroundStyle(LifeOSTokens.secondaryText)
        }
        .buttonStyle(.plain)
    }

    private func pinRangeStart() {
        guard let selectedPoint else { return }
        pinnedRangeStart = selectedPoint.date
        zoomFactor = 1
    }

    private func changeZoom(by multiplier: Double) {
        zoomFactor = min(max(zoomFactor * multiplier, 0.25), 1)
    }

    private func stepSelection(by offset: Int) {
        guard !allSelectablePoints.isEmpty else { return }
        let currentIndex = selectedID.flatMap { selected in
            allSelectablePoints.firstIndex { $0.id == selected }
        } ?? (offset < 0 ? allSelectablePoints.count : -1)
        let nextIndex = min(max(currentIndex + offset, 0), allSelectablePoints.count - 1)
        let next = allSelectablePoints[nextIndex]
        if next.id != selectedID { ScrubBubble<EmptyView>.snapHaptic() }
        selectedID = next.id
    }
}
