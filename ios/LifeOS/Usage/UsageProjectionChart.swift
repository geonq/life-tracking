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
        return points.map { UsageProjectionPoint(date: $0.date, usedPercent: $0.usedPercent) }
    }

    /// Current estimate = the forward projection engine's points, only when the analytics
    /// snapshot declares the same window. A range switch must never reuse another window's
    /// estimate, even if the dates happen to overlap.
    ///
    /// Requires at least 2 actual points before rendering: fewer than that gives no observed
    /// velocity to project from, so the honest "Not enough data" state applies instead of a
    /// fabricated line. `UsageProjectionEngine.points` always re-emits an anchor point at the
    /// observed date (equal to `lastObservedDate` in the common continuous-observation case) —
    /// that anchor must be KEPT (`>=`, not `>`) so the estimate line has a starting vertex to
    /// draw forward from. Excluding it left a single trailing point, which `LineMark` cannot
    /// stroke (a lone point draws no visible segment) — that was the root cause of the line
    /// never rendering.
    private var estimatePoints: [UsageProjectionPoint] {
        guard actualPoints.count >= 2 else { return [] }
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

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            legend

            referenceChart
            .chartOverlay { proxy in
                GeometryReader { geometry in
                    if let plotFrame = proxy.plotFrame {
                        let frame = geometry[plotFrame]
                        Rectangle().fill(.clear).contentShape(Rectangle())
#if os(iOS)
                            .gesture(DragGesture(minimumDistance: 0).onChanged { value in
                                let x = value.location.x - frame.origin.x
                                if let date: Date = proxy.value(atX: x) {
                                    selectClosest(to: date)
                                }
                            })
                            .onTapGesture { location in
                                let x = location.x - frame.origin.x
                                if let date: Date = proxy.value(atX: x) {
                                    selectClosest(to: date)
                                }
                            }
#elseif os(macOS)
                            .onContinuousHover(coordinateSpace: .local) { phase in
                                switch phase {
                                case .active(let location):
                                    let x = location.x - frame.origin.x
                                    if let date: Date = proxy.value(atX: x) {
                                        selectClosest(to: date)
                                    }
                                case .ended:
                                    break
                                }
                            }
#endif
                        if let selectedPoint,
                           let x = proxy.position(forX: selectedPoint.date),
                           let y = proxy.position(forY: selectedPoint.usedPercent) {
                            ScrubBubble(x: frame.origin.x + x, y: max(18, frame.origin.y + y - 26)) {
                                Text("\(Int((1 - selectedPoint.usedPercent) * 100))% remaining")
                            }
                            .allowsHitTesting(false)
                        }
                    }
                }
            }
            .frame(height: 190)
            .task(id: selectionDomainID) {
                // Do not invent a default observation. The hero is sourced from the selected
                // window, while analytics can contain a different observation cadence. A scrub
                // point appears only after the user explicitly chooses one.
                selectedID = nil
                pinnedRangeStart = nil
                zoomFactor = 1
            }

            detailRow

            belowChartRows
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
            return "No observed hourly points are available."
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
                // §5.4: no area fill below the 200pt chart-height threshold.

                ForEach(actualPoints) { point in
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
                        .font(LifeOSFont.axis())
                        .foregroundStyle(LifeOSTokens.metadataText)
                }
            }
        }
    }

    private var xAxisMarks: some AxisContent {
        let isShortWindow = window?.durationMinutes == UsageRange.fiveHour.durationMinutes
        return AxisMarks(values: .automatic(desiredCount: isShortWindow ? 5 : 7)) { value in
            AxisValueLabel {
                if let date = value.as(Date.self) {
                    Group {
                        if isShortWindow {
                            Text(date, format: .dateTime.hour().minute())
                        } else {
                            Text(date, format: .dateTime.weekday(.abbreviated).day())
                        }
                    }
                    .font(LifeOSFont.axis())
                    .foregroundStyle(LifeOSTokens.metadataText)
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
            UsageLegendKey(color: LifeOSTokens.Series.target, label: "Target", dashed: true)
            UsageLegendKey(color: LifeOSTokens.Series.actual, label: "Actual")
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
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(selectedPoint.isProjected ? LifeOSTokens.Series.estimate : LifeOSTokens.Series.actual)
                        Text("\(Int((1 - selectedPoint.usedPercent) * 100))% remaining")
                            .font(.caption.weight(.semibold))
                        Text(selectedPoint.date, format: .dateTime.month(.abbreviated).day().hour().minute())
                            .font(.caption)
                            .foregroundStyle(LifeOSTokens.secondaryText)
                    }
                    Text("\(provider.displayName) · \(qualityTag)")
                        .font(.caption2)
                        .foregroundStyle(LifeOSTokens.tertiaryText)
                }
            } else {
                Text(scrubHintText)
                    .font(.caption)
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
        "Drag or tap the chart for exact values."
#else
        "Hover the chart for exact values."
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
        guard !allSelectablePoints.isEmpty else { return }
        let closest = allSelectablePoints.min {
            let leftDistance = abs($0.date.timeIntervalSince(date))
            let rightDistance = abs($1.date.timeIntervalSince(date))
            guard leftDistance == rightDistance else { return leftDistance < rightDistance }
            if $0.isProjected != $1.isProjected {
                return !$0.isProjected
            }
            return $0.date < $1.date
        }
        if let closest, closest.id != selectedID {
            selectedID = closest.id
            ScrubBubble<EmptyView>.snapHaptic()
        }
    }

    // MARK: Below-chart rows (02 §2)

    private var belowChartRows: some View {
        VStack(alignment: .leading, spacing: 8) {
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
            metaRow(label: "Suggested pace", value: "Not enough data")
            metaRow(label: "Runway", value: "Not enough data")
        }
        .padding(.top, 2)
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
        .font(.caption)
    }

    private func iconLabelButton(icon: LifeOSIconName, label: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 5) {
                LifeOSIcon(icon).frame(width: 10, height: 10)
                Text(label)
            }
            .font(.caption)
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
}
